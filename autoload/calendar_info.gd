# autoload/calendar_info.gd
# 「设备日历」——玩家本机（Windows 设备日历）日历事件的唯一权威。
#
# 职责（与 autoload/local_weather.gd 同款「单一权威 + 信号广播」风格）：
#   1) 采集：起一个 PowerShell 子进程跑 addons/hellonyxel_sysinfo/get_calendar.ps1
#      （调 WinRT AppointmentStore 读本机日历 → 写 device_calendar.json）。
#   2) 数据：get_data() / events()（每条含 subject / start / end / location / details /
#      busy_status / sensitivity / calendar_name / reminder_min / all_day）。
#   3) 无头（headless 冒烟）下不拉子进程——日历采集要 WinRT + 进程外 COM，无头没有意义。
#
# 与「备忘录/日记」(calendar_notes.gd) 的区别：
#   本模块只读**玩家设备上的真实日历**（外部、不可由游戏改写）；
#   备忘录/日记是游戏内数据（玩家与事件链系统可写），存于 Temp 目录。
#   日记面板把这两者并排展示：左/上是设备日历事件（只读），游戏内写入进 memo/diary。
extends Node

const SCRIPT_PATH := "res://addons/hellonyxel_sysinfo/get_calendar.ps1"
const REFRESH_TIMEOUT_SEC := 60.0    # 子进程最长容忍时间

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
var _last_error := ""


func _ready() -> void:
	# 不阻塞启动：数据要等面板/其它消费者第一次问的时候再读
	set_process(true)


func _process(_delta: float) -> void:
	_poll_refresh()


# ============ 采集 ============

func is_busy() -> bool:
	return _busy


func last_error() -> String:
	return _last_error


## 请求刷新。manual=true 来自面板「刷新本机日历」；false 来自按需自动刷新。
## 返回是否真的起了子进程（忙碌中 / 无头 / 缺文件 → false）。
func refresh_now(manual: bool = true) -> bool:
	if _busy:
		return false
	if SaveManager == null:
		return false
	if DisplayServer.get_name() == "headless":
		# 无头（headless 冒烟）下不拉子进程：脚本本身要 WinRT + 进程外环境
		_finish(false, "当前环境不支持读取设备日历（无头模式）")
		return false
	var out_path := SaveManager.get_device_calendar_path()
	if out_path.is_empty():
		_finish(false, "SaveManager 未就绪")
		return false
	var script_path := ProjectSettings.globalize_path(SCRIPT_PATH)
	if not FileAccess.file_exists(script_path):
		_finish(false, "找不到采集脚本：%s" % script_path)
		return false
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
	print("[CalendarInfo] 开始采集设备日历（%s）" % ("手动" if manual else "按需"))
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
		elif available():
			_finish(true, "")
		else:
			# 设备日历不可用（非打包进程）→ 仍算「成功拿到结果」，只是 events 为空
			_finish(true, "")
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
		var n := events().size()
		if available():
			print("[CalendarInfo] 设备日历已更新：%d 条事件" % n)
		else:
			print("[CalendarInfo] 设备日历不可用（非打包进程）：events=%d，按空处理" % n)
		updated.emit()
	refresh_finished.emit(ok, reason)


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


# ============ 数据 ============

## 采集结果（device_calendar.json 全量）。未采过 → 空字典。
func get_data() -> Dictionary:
	if not _loaded:
		reload()
	return _data


func reload() -> void:
	_loaded = true
	_data = {}
	if SaveManager == null:
		return
	var p := SaveManager.get_device_calendar_path()
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


## 设备日历是否可用（脚本成功拿到 store）。非打包进程下恒为 false（events 为空）。
func available() -> bool:
	var v: Variant = get_data().get("available", false)
	return bool(v) if v != null else false


## 是否采到过事件（events 数量 > 0）
func has_data() -> bool:
	return events().size() > 0


## 全部事件（Array[Dictionary]，未采过 → 空数组）。
func events() -> Array:
	var v: Variant = get_data().get("events", [])
	if v is Array:
		return v
	return []


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


## 超过 24 小时视为过期 → 面板打开时值得刷新一次
func is_stale() -> bool:
	return age_seconds() > 86400.0


## 某一天（"yyyy-MM-dd"）的设备日历事件（按 start 升序）。
func events_on_date(date: String) -> Array:
	var out: Array = []
	var prefix := date + "T"
	for ev in events():
		if not (ev is Dictionary):
			continue
		if str((ev as Dictionary).get("start", "")).begins_with(prefix):
			out.append(ev)
	out.sort_custom(func(a, b): return str((a as Dictionary).get("start", "")) < str((b as Dictionary).get("start", "")))
	return out


## 某一天是否有设备日历事件（面板用来在格子上打标记）。
func day_has_events(date: String) -> bool:
	return events_on_date(date).size() > 0


func _q(path: String) -> String:
	return "\"%s\"" % path
