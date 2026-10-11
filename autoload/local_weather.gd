# autoload/local_weather.gd
# 「读取本机天气」——本机（Windows/MSN）天气的唯一权威。
#
# 职责（与 autoload/busy_state.gd 同款「单一权威 + 信号广播」风格）：
#   1) 开关：weather.json 的 read_local_weather（bool）。开 → 本机天气取代「手动定位的天气」。
#   2) 采集：起一个 PowerShell 子进程跑 addons/hellonyxel_sysinfo/get_local_weather.ps1
#      （本机坐标：设备定位优先、IP 兜底 → 调 MSN overview 接口 → 累加进 local_weather.json）。
#   3) 自动刷新：**整点**自动跑一次（数据没过 1 小时就不白跑）；手动走 refresh_now()。
#   4) 数据：get_data() / 来源位置 / 当前天气 / 逐日（含「昨天→前一周」的历史保留）
#      / 逐小时（设备接口支持时才有：hours() / has_hourly() / hours_of_date()）。
#
# 文件分工（故意分开，避免两个写入者互相覆盖）：
#   weather.json       —— 玩家配置（manual 定位 / api / read_local_weather）
#   local_weather.json —— 采集结果（脚本产出：locations[]，每条含 location_text / coord_source /
#                         current / days 历史 / hours 逐小时）
#
# ★ 与「获取设备定位」(location.json) 的区别：那一个是**手动**按钮 + 只存坐标；
#   本模块在开关开启时按整点持续采集天气，并把源位置交给 MSN 自己反解（source.location），
#   所以「这份天气到底是哪里的」由数据本身回答，不靠猜。
extends Node

const SCRIPT_PATH := "res://addons/hellonyxel_sysinfo/get_local_weather.ps1"
const REFRESH_TIMEOUT_SEC := 90.0    # 子进程最长容忍时间（含首次冷启动 ~19s）
const STALE_SEC := 3600.0            # 数据超过 1 小时视为过期 → 该刷了
# ★ 批次 6：整点检测的时钟查询间隔（原来每帧都查）。最坏晚这么久才发现跨了整点，无所谓。
const HOUR_CHECK_INTERVAL := 5.0

# 数据变了（面板据此刷新显示）
signal updated
# 开始 / 结束一次采集（manual=true 表示手动「即刻刷新」）
signal refresh_started(manual: bool)
signal refresh_finished(ok: bool, reason: String)

var _data: Dictionary = {}
var _loaded := false

var _busy := false
var _pid := 0
var _start_ms := 0
var _manual := false

var _last_tick_hour := -1        # 上一次「小时」变化检测到的小时
var _auto_pending := false       # 有一次整点自动采集还没能真正发起（跨整点那刻正忙 → 不丢掉）
var _last_error := ""
var _hour_check_t := 0.0         # ★ 批次 6：距下次「查一次时钟」的剩余秒数（见 _tick_auto_impl）


func _ready() -> void:
	# 不阻塞启动：数据要等面板/其它消费者第一次问的时候再读
	set_process(true)


func _process(delta: float) -> void:
	_poll_refresh()
	_tick_auto(delta)


## 整点自动采集：跨整点的那一刻记一笔「这次整点还没做」，之后每帧重试直到真正发起。
##
## ★ 为什么不能一跨整点就把「本小时已尝试」钉死：那一刻可能正有手动「即刻刷新」在跑，
##   refresh_now() 会直接返回 false —— 钉死就等于把这个整点整个丢掉（要再等一小时）。
##   改成 pending 标志后，等子进程空闲了照样会把这次的整点补上。
## ★ 只自动尝试一次：真正发起过（或非忙碌原因起不来）就清掉 pending，
##   失败不会变成每帧狂试；下一次机会是下一个整点。
func _tick_auto(delta: float) -> void:
	# ★ 自测量（批次 6）：量一下本函数的真实单价（改造后应降到接近 0）。
	if PerfMonitor.profiling:
		var t0 := Time.get_ticks_usec()
		_tick_auto_impl(delta)
		PerfMonitor.add_span("weather_tick", Time.get_ticks_usec() - t0)
		return
	_tick_auto_impl(delta)


func _tick_auto_impl(delta: float) -> void:
	# ★★ 批次 6：原来**每帧**调 Time.get_datetime_dict_from_system()（每帧分配一个 Dictionary），
	#   而它唯一的用途是"检测小时是否变了"。改成每 HOUR_CHECK_INTERVAL 秒查一次 ——
	#   最坏情况下整点采集晚 5 秒发起，对天气数据毫无意义，但省掉了每秒 ~50 次无谓分配。
	_hour_check_t -= delta
	if _hour_check_t <= 0.0:
		_hour_check_t = HOUR_CHECK_INTERVAL
		var h: int = int(Time.get_datetime_dict_from_system().get("hour", 0))
		if h != _last_tick_hour:
			_last_tick_hour = h
			_auto_pending = true
	if not _auto_pending:
		return
	if not is_enabled() or not is_stale():
		_auto_pending = false
		return
	if refresh_now(false):
		_auto_pending = false
	elif not is_busy():
		# 起不来（无头 / 缺脚本 / SaveManager 未就绪）→ 本小时不再空转重试
		_auto_pending = false


# ============ 开关 ============

## 「读取本机天气」当前是否开启（存 weather.json，唯一出处）。
func is_enabled() -> bool:
	if SaveManager == null:
		return false
	return bool(SaveManager.load_weather_config().get("read_local_weather", false))


## 设置开关（落盘 weather.json，不动同文件里的手动定位 / api）。
## 开启时立刻采集一次（否则玩家要等到下一个整点才看到数据）。
func set_enabled(on: bool, refresh_when_on: bool = true) -> void:
	if SaveManager == null:
		return
	if is_enabled() == on:
		return
	SaveManager.patch_weather_config({ "read_local_weather": on })
	print("[LocalWeather] 读取本机天气 → %s" % ("开启" if on else "关闭"))
	if on and refresh_when_on:
		refresh_now(false)
	updated.emit()


# ============ 数据 ============

## 采集结果（local_weather.json 全量）。未采过 → 空字典。
func get_data() -> Dictionary:
	if not _loaded:
		reload()
	return _data


func reload() -> void:
	_loaded = true
	_data = {}
	if SaveManager == null:
		return
	var p := SaveManager.get_local_weather_path()
	if p.is_empty() or not FileAccess.file_exists(p):
		return
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var d: Variant = JSON.parse_string(txt)
	if d is Dictionary:
		_data = d
	updated.emit()


## 数据是否可用（至少采到了一条来源）
func has_data() -> bool:
	return locations().size() > 0


# ============ 多来源（locations[]）============
# 采集结果现在是一个数组：每个元素是一条「独立坐标来源」的天气
# （device = Windows 定位服务；ip = IP 兜底，二者可能因代理/VPN 指向不同城市）。
# 玩家在天气面板手动选择采用哪一条（selected_source 存 weather.json）。
#
# ★ 向后兼容：location_text() / coord_source() / days() 全部改为返回「选中来源」的那一条，
#   所以旧面板代码无需改动即可继续显示选中的天气。

## 全部采集到的来源（Array[Dictionary]，按 device → ip 顺序）。未采过 → 空数组。
func locations() -> Array:
	var v: Variant = get_data().get("locations", [])
	if v is Array:
		return v
	return []


## 玩家「采用来源」选择的位置文本（location_text），存于 weather.json 的 local_weather_source。
## 空字符串 = 尚未选择（用回落规则）。
func selected_source() -> String:
	if SaveManager == null:
		return ""
	return str(SaveManager.load_weather_config().get("local_weather_source", "")).strip_edges()


## 设置采用来源（落盘 weather.json；不动同文件其它键）。emit updated → 面板刷新显示。
func set_selected_source(loc_text: String) -> void:
	if SaveManager == null:
		return
	SaveManager.patch_weather_config({ "local_weather_source": loc_text })
	print("[LocalWeather] 采用来源 → %s" % loc_text)
	updated.emit()


## 选中来源在 locations[] 中的下标：
##   ① 先按 selected_source() 文本精确匹配；
##   ② 没匹配（首次 / 选择的位置已不存在）→ 回落 device 来源；
##   ③ 再不行 → 0；空 → -1。
func selected_index() -> int:
	var locs := locations()
	if locs.is_empty():
		return -1
	var sel := selected_source()
	if not sel.is_empty():
		for i in locs.size():
			var e: Variant = locs[i]
			if e is Dictionary and str((e as Dictionary).get("location_text", "")).strip_edges() == sel:
				return i
	for i in locs.size():
		var en: Variant = locs[i]
		if en is Dictionary and str((en as Dictionary).get("coord_source", "")) == "device":
			return i
	return 0


## 选中来源的整条数据（含 location_text / coord_source / location / current / days / retain）。
## 无效 → 空字典。
func selected_entry() -> Dictionary:
	var i := selected_index()
	if i < 0:
		return {}
	var locs := locations()
	if i >= 0 and i < locs.size():
		var e: Variant = locs[i]
		if e is Dictionary:
			return e
	return {}


## 本机天气的「源头位置」文本（MSN 反解出的地名，如 "Zhangjiawan, Hubei, CN"）。
## ★ 返回「选中来源」的那一条（未选 → 回落 device / 第一条）。
func location_text() -> String:
	var e := selected_entry()
	if not e.is_empty():
		return str(e.get("location_text", "")).strip_edges()
	return ""


## 这份天气是用哪种坐标采到的："device"（Windows 定位服务）/ "ip"（IP 兜底）/ ""
## ★ 返回「选中来源」的那一条。
func coord_source() -> String:
	var e := selected_entry()
	if not e.is_empty():
		return str(e.get("coord_source", ""))
	return ""


## 采集时间（本机时区 unix 秒；没采过 → 0）
func updated_epoch() -> int:
	var v: Variant = get_data().get("updated_epoch", 0)
	return int(v) if v != null else 0


## 数据年龄（秒）；never fetched → 一个很大的值
func age_seconds() -> float:
	var e := updated_epoch()
	if e <= 0:
		return 1.0e9
	return maxf(0.0, float(Time.get_unix_time_from_system()) - float(e))


func is_stale() -> bool:
	return age_seconds() > STALE_SEC


## 逐日数据（按日期升序的 Array[Dictionary]）：含今天及未来预报 + 「昨天→前一周」的历史。
## 元素字段：date / hi / lo / cap / night_cap / precip / uv / wind_max / icon /
##           first_seen / last_seen / updates
## ★ 返回「选中来源」那一条的 days（每条来源各自保留自己的历史）。
func days() -> Array:
	var out: Array = []
	var e := selected_entry()
	if e.is_empty():
		return out
	var d: Variant = e.get("days", {})
	if not (d is Dictionary):
		return out
	var keys: Array = []
	for k in (d as Dictionary).keys():
		keys.append(str(k))
	keys.sort()
	for k in keys:
		var ev: Variant = (d as Dictionary).get(k, {})
		if ev is Dictionary:
			var item: Dictionary = (ev as Dictionary).duplicate()
			item["date"] = k
			out.append(item)
	return out


## 今天在 days 里的那一条（没有 → 空字典）
func today_entry() -> Dictionary:
	var t := today_key()
	for e in days():
		if str(e.get("date", "")) == t:
			return e
	return {}


# ============ 逐小时（精度提升）============
# ★ 数据来自 MSN 响应里**按天嵌套**的 forecast.days[i].hourly（不是 forecast.hourly——
#   后者根本不存在）。所以采集端把每天的小时摊平成一个 hours 对象，键 "yyyy-MM-ddTHH"。
# ★ 精度是「设备接口支持才有」：若某次响应不含 hourly 数组，采集端 hours 为空，
#   这里 has_hourly() 返回 false、hours() 返回空数组 → 界面自然退回逐日，不会报错。
# ★ 今天只拿得到**剩余**的小时（MSN 不给已过去的钟点），属正常，非数据缺失。

## 选中来源是否带逐小时数据（false → 该来源只支持逐日精度）
func has_hourly() -> bool:
	return hours().size() > 0


## 选中来源的逐小时数据（按 valid 升序的 Array[Dictionary]）。
## 元素字段：valid（"yyyy-MM-ddTHH"）/ temp / feels / cap / precip / uv /
##           wind_spd / wind_dir / rh / icon
func hours() -> Array:
	var out: Array = []
	var e := selected_entry()
	if e.is_empty():
		return out
	var h: Variant = e.get("hours", {})
	if not (h is Dictionary):
		return out
	var keys: Array = []
	for k in (h as Dictionary).keys():
		keys.append(str(k))
	keys.sort()
	for k in keys:
		var ev: Variant = (h as Dictionary).get(k, {})
		if ev is Dictionary:
			var item: Dictionary = (ev as Dictionary).duplicate()
			item["valid"] = k
			out.append(item)
	return out


## 某一天（"yyyy-MM-dd"）的逐小时数据；按小时升序。默认今天。
func hours_of_date(date: String) -> Array:
	var out: Array = []
	var prefix := date + "T"
	for hv in hours():
		var d: Dictionary = hv
		if str(d.get("valid", "")).begins_with(prefix):
			out.append(d)
	return out


## 逐小时总条数（0 → 只有逐日精度）
func hourly_count() -> int:
	return hours().size()


## 覆盖的日期列表（"yyyy-MM-dd"，升序、已去重）—— 决定界面里哪些天能展开。
func hourly_dates() -> Array:
	var seen: Dictionary = {}
	for hv in hours():
		var d: Dictionary = hv
		var v := str(d.get("valid", ""))
		if v.length() >= 10:
			seen[v.substr(0, 10)] = true
	var out: Array = []
	for k in seen.keys():
		out.append(str(k))
	out.sort()
	return out


func today_key() -> String:
	var t := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d" % [int(t.get("year", 0)), int(t.get("month", 1)), int(t.get("day", 1))]


## ★「取代手动定位的天气」的唯一出口：开关开着且拿到了本机数据 → 用本机天气的源位置；
## 否则回落到 weather.json 里的手动定位。将来的天气消费方（显示 / 事件链）只调这一个。
func authoritative_location() -> String:
	if is_enabled():
		var t := location_text()
		if not t.is_empty():
			return t
	if SaveManager == null:
		return ""
	return str(SaveManager.load_weather_config().get("location", "")).strip_edges()


func authoritative_is_local() -> bool:
	return is_enabled() and not location_text().is_empty()


# ============ 采集 ============

func is_busy() -> bool:
	return _busy


func last_error() -> String:
	return _last_error


## 请求刷新。manual=true 来自面板「即刻刷新」；false 来自整点自动。
## 返回是否真的起了子进程（忙碌中 / 无头 / 缺文件 → false）。
func refresh_now(manual: bool = true) -> bool:
	if _busy:
		return false
	if SaveManager == null:
		return false
	if DisplayServer.get_name() == "headless":
		# 无头（headless 冒烟）下不拉子进程：脚本本身要网络 + 定位服务
		_finish(false, "当前环境不支持读取本机天气（无头模式）")
		return false
	var out_path := SaveManager.get_local_weather_path()
	if out_path.is_empty():
		_finish(false, "SaveManager 未就绪")
		return false
	var script_path := ProjectSettings.globalize_path(SCRIPT_PATH)
	if not FileAccess.file_exists(script_path):
		_finish(false, "找不到采集脚本：%s" % script_path)
		return false
	# ★ 不删旧产物：脚本要读旧文件做「历史合并」，删了就丢了「昨天→前一周」的保留
	var args := PackedStringArray([
		"-NoProfile", "-STA", "-ExecutionPolicy", "Bypass",
		"-File", _q(script_path),
		"-OutPath", _q(out_path),
	])
	_pid = OS.create_process("powershell.exe", args, false)
	if _pid <= 0:
		_pid = 0
		_finish(false, "启动采集进程失败（powershell.exe 不可用？）")
		return false
	_busy = true
	_manual = manual
	_start_ms = Time.get_ticks_msec()
	_last_error = ""
	refresh_started.emit(manual)
	print("[LocalWeather] 开始采集本机天气（%s）" % ("手动" if manual else "整点自动"))
	return true


func _poll_refresh() -> void:
	if not _busy:
		return
	if not OS.is_process_running(_pid):
		_pid = 0
		if SaveManager != null:
			reload()
		var err := str(get_data().get("error", "")).strip_edges()
		if not err.is_empty():
			_finish(false, err)
		elif locations().size() > 0:
			_finish(true, "")
		else:
			_finish(false, "采集结束但没有拿到数据")
		return
	if Time.get_ticks_msec() - _start_ms > int(REFRESH_TIMEOUT_SEC * 1000.0):
		_kill_child()
		_finish(false, "采集超时（%d 秒无结果）" % int(REFRESH_TIMEOUT_SEC))


func _finish(ok: bool, reason: String) -> void:
	_busy = false
	_pid = 0
	_manual = false
	_last_error = "" if ok else reason
	if ok:
		var loc := location_text()
		print("[LocalWeather] 本机天气已更新：%s（来源=%s）" % [loc, coord_source()])
		updated.emit()
	refresh_finished.emit(ok, reason)


## 强杀还在跑的采集子进程（面板关闭 / 退出时调用，避免留孤儿 PowerShell）。
## ★ 不写 _last_error：这是**调用方主动中止**，不是采集失败。写进去会让面板一直挂着一条
##   「上次失败：已取消」的假失败（上一次真实错误也不该被它顶掉，故原样保留）。
## ★ 发 updated 让已订阅的视图重画：否则状态行会一直停在「正在采集本机天气…」。
func cancel() -> void:
	if not _busy:
		return
	_busy = false
	_kill_child()
	updated.emit()


func _kill_child() -> void:
	if _pid <= 0:
		return
	if OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = 0


func _exit_tree() -> void:
	_kill_child()


func _q(path: String) -> String:
	return "\"%s\"" % path
