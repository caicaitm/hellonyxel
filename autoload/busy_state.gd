# autoload/busy_state.gd
# 「在忙 / 空闲」全局状态单例（autoload 名：BusyState）。
#
# 为什么需要单独一个单例：
#   性能忙闲判断面板只把「分数 vs 阈值」算出来**显示**，状态本身不落地；
#   而系统托盘是独立进程、游戏内其它系统也要读状态 → 需要一个唯一权威来源。
#
# 状态来源优先级（高 → 低）：
#   1) 定时时段（perf_busy.json 的 schedule）：时段内一律「在忙」；
#      时段内允许手动切换**一次**（立刻生效），之后本次时段锁定、不能再切。
#   2) 手动：托盘「现在在忙 / 现在空闲」设定，忽略分数/阈值。
#      ★ 遇时段开始或结束即被清除（回到分数判定）——手动值不会长期压住自动判定。
#   3) 自动：PerfMonitor 的「电脑性能使用分数 > 分数判断阈值」（公式与忙闲面板一致）。
#
# 托盘是独立进程、读不到 Godot 的内存状态：
#   本单例每次状态变化都把 "busy|locked" / "idle|unlocked" 写进 TrayRunner 的状态文件；
#   托盘右键菜单**展开时**读它，只显示与当前状态**相反**的那一项（在忙 → 显示「现在空闲」），
#   锁定时置灰并注明。反向：托盘点击写出「现在在忙 / 现在空闲」请求文件
#   → TrayRunner 轮询 → set_manual()。
#
# 对外 API：
#   is_busy() / state_source() / is_manual_locked() / set_manual(busy) /
#   reload() / apply_settings(data) / score_busy() / compute_score()
#   signal state_changed(busy, source)
# 纯函数（便于断言）：parse_hhmm / format_hhmm / resolve_window / compute_state

extends Node

## 状态变化（忙闲值或来源变了才发）
signal state_changed(busy: bool, source: String)

const SOURCE_AUTO := "auto"          # 分数/阈值自动判定
const SOURCE_MANUAL := "manual"      # 托盘手动设定
const SOURCE_SCHEDULE := "schedule"  # 定时时段

## 时段边界检查周期（秒）：秒级足够，时段精度只到分钟
const TICK_INTERVAL: float = 1.0
## 分数判断阈值缺省值（与忙闲面板的默认一致；面板保存后会覆盖）
const SCORE_THRESHOLD_DEFAULT: float = 30.0

## ★★ 批次 70：进程「属性」→ 中文名（与 ui/perf_busy_panel.gd 的 ACTIVITY_KINDS 真值一致）。
## 用途见 current_activity()：在「在忙 / 在闲」之上进一步判断玩家在干什么。
## ★ 批次 94：新增 休闲 / 学习 / 社区。
const ACTIVITY_LABELS := {
	"game": "游戏", "work": "工作", "chat": "聊天", "music": "音乐",
	"leisure": "休闲", "study": "学习", "community": "社区", "other": "其他",
}

## ★★ 批次 94（权威活动属性表）：[真值, 中文名]，顺序 = 界面下拉顺序。
## ★ 与 ui/perf_busy_panel.gd 的 ACTIVITY_KINDS 必须逐项一致（两处同步改）。
## ★ 集合类接口（activity_weights 等）以本表为准 → 条件编辑器/事件谓词不依赖面板层。
const ACTIVITY_KINDS: Array = [
	["game", "游戏"],
	["work", "工作"],
	["chat", "聊天"],
	["music", "音乐"],
	["leisure", "休闲"],
	["study", "学习"],
	["community", "社区"],
	["other", "其他"],
]

var _busy: bool = false
var _source: String = SOURCE_AUTO
var _locked: bool = false              # 当前是否禁止手动切换
var _manual_active: bool = false       # 手动覆盖生效中
var _manual_value: bool = false        # 手动设定的值
var _manual_in_window: bool = false    # 本次手动切换发生在「当前时段内」
var _window_key: String = ""           # 当前生效时段的标识；"" = 时段外
var _settings: Dictionary = {}         # perf_busy.json 快照（阈值/权重/进程/时段）
var _last_payload: String = ""         # 上次写给托盘的状态串（变化才写盘）
var _tick: Timer = null


func _ready() -> void:
	reload()
	_hook_perf_monitor()
	_tick = Timer.new()
	_tick.name = "BusyStateTick"
	_tick.wait_time = TICK_INTERVAL
	_tick.one_shot = false
	_tick.timeout.connect(_on_tick)
	add_child(_tick)
	_tick.start()


# ---------------- 对外查询 ----------------

func is_busy() -> bool:
	return _busy


func state_source() -> String:
	return _source


## 当前是否禁止手动切换（时段内已手动切换过一次 → 本次时段锁定）
func is_manual_locked() -> bool:
	return _locked


func active_window_key() -> String:
	return _window_key


func manual_active() -> bool:
	return _manual_active


## ★★ 批次 70：在「在忙 / 在闲」之上进一步判断玩家在干什么。
## 据 perf_busy.json 里各进程的 kind（活动属性）与 PerfMonitor.is_process_running 汇总：
##   返回 { kinds: Array[String]（命中的属性真值，按权重降序）, total: float（命中权重合计）,
##          label: String（最高权重属性的中文名，并列用「/」连接） }。
## 无配置 / 数据不可用 / 未命中 → kinds 为空、label 为 ""。
func current_activity() -> Dictionary:
	var out := { "kinds": [], "total": 0.0, "label": "" }
	var pm = get_node_or_null("/root/PerfMonitor")
	if pm == null or not bool(pm.last_sample_ok):
		return out
	var hits: Dictionary = {}
	for row in _proc_rows():
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = row
		var nm := str(d.get("name", "")).strip_edges()
		if nm.is_empty():
			continue
		if bool(pm.is_process_running(nm)):
			var kind := str(d.get("kind", "other"))
			if kind.is_empty():
				kind = "other"
			hits[kind] = float(hits.get(kind, 0.0)) + float(d.get("weight", 1.0))
	if hits.is_empty():
		return out
	# 按权重降序 → kinds；取最高者作为 label
	var pairs: Array = []
	for k in hits:
		pairs.append([k, float(hits[k])])
	pairs.sort_custom(func(a, b): return a[1] > b[1])
	var kinds: Array = []
	for p in pairs:
		kinds.append(str(p[0]))
	var best := float(pairs[0][1])
	var tops: Array = []
	for p in pairs:
		if absf(float(p[1]) - best) < 0.0001:
			tops.append(ACTIVITY_LABELS.get(str(p[0]), str(p[0])))
	tops.sort()
	out["kinds"] = kinds
	out["total"] = best
	out["label"] = " / ".join(tops)
	return out


## ★★ 批次 94：各活动属性的**运行权重**（键集合恒为全量，未命中的值为 0.0）。
##   返回 { kind:String -> weight:float }；键集合 = ACTIVITY_KINDS 全部 + 配置里出现过的未知属性。
## ★ 与 current_activity() 的区别：后者**只返回命中的**（未命中属性被丢弃），
##   所以「权重最低」这类需要全量比较的判断不能复用它 —— 这里给全量表。
## ★ 只做「原样汇总」，排序交给调用方（避免排序 bug 伪装成数据 bug）。
func activity_weights() -> Dictionary:
	var out: Dictionary = {}
	for pair in ACTIVITY_KINDS:
		out[str(pair[0])] = 0.0
	var rows := _proc_rows()
	for row in rows:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = row
		var kind := str(d.get("kind", "other"))
		if kind.is_empty():
			kind = "other"
		if not out.has(kind):
			out[kind] = 0.0
	var pm = get_node_or_null("/root/PerfMonitor")
	if pm == null or not bool(pm.last_sample_ok):
		return out
	for row in rows:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = row
		var nm := str(d.get("name", "")).strip_edges()
		if nm.is_empty():
			continue
		if not bool(pm.is_process_running(nm)):
			continue
		var kind := str(d.get("kind", "other"))
		if kind.is_empty():
			kind = "other"
		out[kind] = float(out.get(kind, 0.0)) + float(d.get("weight", 1.0))
	return out


## ★★ 批次 94：玩家当前是否**在跑某类活动**（该属性权重 > 0 = 至少一个该属性的进程在运行）。
## ★ 未登记的属性恒 false；kind 为空恒 false。
func activity_active(kind: String) -> bool:
	var k := kind.strip_edges()
	if k.is_empty():
		return false
	return float(activity_weights().get(k, 0.0)) > 0.0


## ★★ 批次 94：权重最高 / 最低的**当前活动属性**（只在权重 > 0 的属性间比较）。
## ★ 无任何命中 → 返回 ""（此时「最高/最低」无意义，调用方按 false 处理）。
## ★ 只有一个属性命中时「最高 == 最低 == 该属性」，这是预期语义，不做特判。
## ★ 并列时取 ACTIVITY_KINDS 里靠前者（字典插入序 = 表顺序，结果确定）。
func activity_extreme(highest: bool) -> String:
	var w := activity_weights()
	var best := ""
	var best_w := 0.0
	for k in w:
		var f := float(w[k])
		if f <= 0.0:
			continue
		if best.is_empty() or (highest and f > best_w) or ((not highest) and f < best_w):
			best = str(k)
			best_w = f
	return best


## ★★ 批次 94：权重最高的活动属性真值（无命中 → ""）。见 activity_extreme()。
func activity_top() -> String:
	return activity_extreme(true)


## ★★ 批次 94：权重最低的活动属性真值（无命中 → ""）。见 activity_extreme()。
func activity_low() -> String:
	return activity_extreme(false)


## ★★ 批次 94：活动属性真值 → 中文名（未知真值原样返回，便于诊断）。
func activity_label(kind: String) -> String:
	return str(ACTIVITY_LABELS.get(kind, kind))


# ---------------- 对外操作 ----------------

## 手动切换忙闲（托盘「现在在忙 / 现在空闲」）。返回是否被接受。
## 时段内已手动切换过一次 → 本次时段锁定，拒绝（见 is_manual_locked）。
func set_manual(busy: bool) -> bool:
	if _locked:
		print("[BusyState] 手动切换被拒绝：本时段已手动切换过（window=%s）" % _window_key)
		return false
	_manual_active = true
	_manual_value = busy
	_manual_in_window = not _window_key.is_empty()
	_apply()
	print("[BusyState] 手动切换 → %s（%s）" % [
		"在忙" if busy else "空闲",
		"时段内，本次时段内不再允许切换" if _manual_in_window else "时段外",
	])
	return true


## 重新读 perf_busy.json（启动时、以及外部改了文件时）
func reload() -> void:
	var d: Dictionary = {}
	var sm = get_node_or_null("/root/SaveManager")
	if sm != null and sm.has_method("load_perf_busy_settings"):
		var got: Variant = sm.load_perf_busy_settings()
		if typeof(got) == TYPE_DICTIONARY:
			d = got
	_settings = d
	_apply()


## 忙闲面板改动后直接推入（避免每拖一次滑块都读盘）
func apply_settings(data: Dictionary) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	_settings = (data as Dictionary).duplicate(true)
	_apply()


## 「分数 > 阈值」自动判定；数据不可用 → false（保守，不误判为在忙）
func score_busy() -> bool:
	var score := compute_score()
	if score < 0.0:
		return false
	return score > _score_threshold()


## 电脑性能使用分数（公式与忙闲面板一致：Σ 超线部分×权重 + 检测到的进程权重）；
## -1.0 = 数据不可用。
func compute_score() -> float:
	var pm = get_node_or_null("/root/PerfMonitor")
	if pm == null:
		return -1.0
	if not bool(pm.last_sample_ok):
		return -1.0
	var score: float = float(pm.compute_busy_score(_sub_dict("thresholds"), _sub_dict("weights")))
	score = maxf(score, 0.0)
	for row in _proc_rows():
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = row
		var nm := str(d.get("name", "")).strip_edges()
		if nm.is_empty():
			continue
		if bool(pm.is_process_running(nm)):
			score += float(d.get("weight", 1.0))
	return score


# ---------------- 纯函数（可断言） ----------------

## 解析 "H:MM" / "HH:MM" → 当天分钟数；非法返回 -1
func parse_hhmm(text: String) -> int:
	var t := str(text).strip_edges()
	if t.is_empty():
		return -1
	var parts: PackedStringArray = t.split(":")
	if parts.size() != 2:
		return -1
	var hs: String = parts[0].strip_edges()
	var ms: String = parts[1].strip_edges()
	if not hs.is_valid_int() or not ms.is_valid_int():
		return -1
	var h := int(hs)
	var m := int(ms)
	if h < 0 or h > 23 or m < 0 or m > 59:
		return -1
	return h * 60 + m


## 分钟数 → "HH:MM"
func format_hhmm(minutes: int) -> String:
	var m: int = clampi(minutes, 0, 1439)
	return "%02d:%02d" % [m / 60, m % 60]


## 时段表 → 当前生效时段的标识；无则空串。
## 时段格式：{ "days": [1..7]（1=周一…7=周日）, "start": "HH:MM", "end": "HH:MM" }
## 语义：勾选日的 start ≤ 现在 < end 为「在忙」；
##       end ≤ start 视为**跨夜**（到次日 end 结束，星期按开始那天算）；
##       start == end 视为**全天**。days 为空 / 时间非法的条目直接忽略。
## ★ days 一律用 has_day() 比较（见那里的说明：JSON 读回会让数字退化成 float）。
func resolve_window(periods: Array, weekday: int, minutes: int) -> String:
	for i in periods.size():
		if typeof(periods[i]) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = periods[i]
		var start := parse_hhmm(str(d.get("start", "")))
		var end := parse_hhmm(str(d.get("end", "")))
		if start < 0 or end < 0:
			continue
		var days_v: Variant = d.get("days", [])
		if typeof(days_v) != TYPE_ARRAY:
			continue
		var days: Array = days_v
		if days.is_empty():
			continue
		var prev_day: int = weekday - 1 if weekday > 1 else 7
		if start == end:
			# 全天：今天勾选即生效
			if has_day(days, weekday):
				return _window_key_of(i, start, end, weekday)
		elif end > start:
			# 当天内区间（左闭右开）
			if has_day(days, weekday) and minutes >= start and minutes < end:
				return _window_key_of(i, start, end, weekday)
		else:
			# 跨夜：今天开始（已过 start）或昨天开始（还没到 end）
			if has_day(days, weekday) and minutes >= start:
				return _window_key_of(i, start, end, weekday)
			if has_day(days, prev_day) and minutes < end:
				return _window_key_of(i, start, end, prev_day)
	return ""


## days 里是否包含某个星期（weekday：1=周一…7=周日）。
## ★★ 必须按 int 归一化比较：JSON 没有整数类型，写盘 `[3]` 读回一定是 `[3.0]`（float），
##    而 Godot 4 的 `Array.has(3)` 对 float 元素返回 **false** ——
##    直接用 days.has(weekday) 会让「勾了星期」的时段永远不生效。
##    days 元素允许 int / float / 数字字符串。
func has_day(days: Array, weekday: int) -> bool:
	for d in days:
		if int(d) == weekday:
			return true
	return false


## 纯函数：由「时段 / 手动 / 分数」推导最终状态（便于断言）
##   window_key      当前生效时段标识（"" = 时段外）
##   manual_active   手动覆盖是否生效
##   manual_value    手动设定的值
##   manual_in_window 手动切换是否发生在当前时段内
##   score_busy      分数自动判定的结果
func compute_state(window_key: String, manual_active: bool, manual_value: bool,
		manual_in_window: bool, score_busy: bool) -> Dictionary:
	var busy := false
	var source := SOURCE_AUTO
	var locked := false
	if not window_key.is_empty():
		if manual_active and manual_in_window:
			# 时段内已手动切换过一次：本次时段按手动值走，并且锁定
			busy = manual_value
			source = SOURCE_MANUAL
			locked = true
		else:
			# 时段内一律在忙（还允许再手动切换一次）
			busy = true
			source = SOURCE_SCHEDULE
			locked = false
	elif manual_active:
		busy = manual_value
		source = SOURCE_MANUAL
	else:
		busy = score_busy
		source = SOURCE_AUTO
	return { "busy": busy, "source": source, "locked": locked }


# ---------------- 内部 ----------------

func _on_tick() -> void:
	_apply()


func _on_perf_updated(_snapshot: Dictionary) -> void:
	# 采样到新数据 → 自动判定可能翻面，立刻重算（不用等下一秒 tick）
	_apply()


func _hook_perf_monitor() -> void:
	var pm = get_node_or_null("/root/PerfMonitor")
	if pm == null:
		return
	if pm.has_signal("perf_updated") and not pm.perf_updated.is_connected(_on_perf_updated):
		pm.perf_updated.connect(_on_perf_updated)


func _apply() -> void:
	var now := _now_parts()
	var weekday: int = now["weekday"]
	var minutes: int = now["minutes"]
	var wk := resolve_window(_periods(), weekday, minutes)
	if wk != _window_key:
		# ★ 时段边界（开始或结束）：手动覆盖一律清除 → 回到分数判定
		if _manual_active:
			print("[BusyState] 时段边界（%s → %s）→ 清除手动状态" % [_window_key, wk])
		_window_key = wk
		_manual_active = false
		_manual_in_window = false
	var st := compute_state(_window_key, _manual_active, _manual_value, _manual_in_window, score_busy())
	var busy: bool = st["busy"]
	var source: String = st["source"]
	var changed: bool = (busy != _busy) or (source != _source)
	_busy = busy
	_source = source
	_locked = st["locked"]
	_push_tray_state()
	if changed:
		print("[BusyState] 状态 → %s（来源=%s%s）" % [
			"在忙" if busy else "空闲", source, "，本时段已锁定" if _locked else ""])
		state_changed.emit(busy, source)


## 当前本地时间 → { "weekday": 1..7（周一=1）, "minutes": 0..1439 }
func _now_parts() -> Dictionary:
	var t := Time.get_datetime_dict_from_system(false)
	# Time 的 weekday：0=周日、1=周一…6=周六；这里统一成 ISO（1=周一…7=周日）
	var wd: int = int(t["weekday"])
	var iso: int = 7 if wd == 0 else wd
	return { "weekday": iso, "minutes": int(t["hour"]) * 60 + int(t["minute"]) }


func _window_key_of(index: int, start: int, end: int, start_weekday: int) -> String:
	return "%d|%d|%d|%d" % [index, start, end, start_weekday]


func _periods() -> Array:
	var v: Variant = _settings.get("schedule", [])
	return v if typeof(v) == TYPE_ARRAY else []


func _proc_rows() -> Array:
	var v: Variant = _settings.get("proc_rows", [])
	return v if typeof(v) == TYPE_ARRAY else []


func _sub_dict(key: String) -> Dictionary:
	var v: Variant = _settings.get(key, {})
	return v if typeof(v) == TYPE_DICTIONARY else {}


func _score_threshold() -> float:
	var f := float(_settings.get("score_threshold", SCORE_THRESHOLD_DEFAULT))
	if f != f:   # NaN → 兜底
		return SCORE_THRESHOLD_DEFAULT
	return f


## 把 "busy|locked" 写给托盘（内容没变不重复写盘）
func _push_tray_state() -> void:
	var payload := "%s|%s" % ["busy" if _busy else "idle", "locked" if _locked else "unlocked"]
	if payload == _last_payload:
		return
	_last_payload = payload
	var tr = get_node_or_null("/root/TrayRunner")
	if tr != null and tr.has_method("write_busy_state"):
		tr.write_busy_state(_busy, _locked)
