# autoload/timeline_manager.gd
# 「计划时间轴」调度器（autoload 名：TimelineManager）。
#
# 数据模型（参考《短期规划设计库 / 计划时间轴.txt》）：
#   计划文件位于 %Documents%\HelloNyxel\Temp\timeline.txt，按行记录一个事件：
#       [2026.09.21.10:32:00](键值对){触发内容}
#   []  = 触发时间（YYYY.MM.DD.HH:MM:SS，24h）
#   ()  = 属性（分号分隔 k=v 键值对；兼容草案的单标签写法 → 自动视为 tag 键）
#         常用键：
#           tag          —— 事件标签（可选，仅供归类/排查）
#           ignore       —— 是否忽略「同时触发上限」；（1/true 表示即使到达上限也强制触发）
#           skip         —— 被忽略次数（运行时累计，写回文件；0/缺省）
#           max_skip     —— 最多忽略次数上限：当 skip >= max_skip 时，下次检查无条件直接触发
#           delay        —— 载入存档后触发延迟（秒）：读档后的这段时间内该事件不会触发
#   {}  = 触发内容。以 "命令:" 前缀分派：
#           event:链名/事件名   → 调用 EventChainRunner.run_event 播放事件脚本
#           其它 / 裸文本       → 发全局信号 timeline_fired(entry)，由外部系统自行接管（预留命令能力）
#
# 行为：
#   - 进入游戏 / 读档后把文件读入内存、按时间升序排序。
#   - 每__检查周期__（默认 5 分钟，可在调试面板运行时调整）扫描「已到点」的事件：
#       ① 若该事件设了 delay 且载入缓冲未过 → 跳过（本次不触发也不删）
#       ② 若本次检查已触发数量达到「同时触发上限」且事件未设 ignore → 被忽略：skip+1 写回；
#          若 skip >= max_skip → 下次检查无条件直接触发
#       ③ 否则 → 触发（分派命令 / 发信号），并从计划中删除
#   - 触发后重写文件（删除触发行）。
#   - 读档恢复：由 SaveManager 读档后调用 timeline_present_loading()/resume 完成迟到事件的动作；
#     本脚本不依赖存档内容，只对「与 save 同目录的 temp/timeline.txt」负责。
extends Node

# 计划文件名（相对 Temp 目录）
const FILE_NAME := "timeline.txt"

# 同时触发数量上限（默认；设置面板可改，落盘 settings）
const DEFAULT_MAX_SIMULTANEOUS := 10
# 检查周期默认秒（5 分钟，调试面板可改，不落盘）
const DEFAULT_CHECK_INTERVAL := 300.0

# 触发内容的事件链前缀
const CMD_EVENT := "event:"

signal timeline_fired(entry: Dictionary)
# 计划发生变化（新增/删除/改写），供外部（如调试面板）刷新显示
signal timeline_changed

# 绝对文件路径
var _path: String = ""
# 检查周期（秒）：运行时可变，不落盘（草案要求放调试面板）
var check_interval_sec := DEFAULT_CHECK_INTERVAL
# 同时触发上限（个/次检查）：落盘（设置面板）
var max_simultaneous := DEFAULT_MAX_SIMULTANEOUS

# 内存计划：Array[Dictionary]。每项：
#   { time_str, time_unix, props:Dictionary, content, raw }
var events: Array = []

# 计时累积
var _accum := 0.0
# 载入存档时刻（相对 now 的进程内时间戳，用于 delay 缓冲）
var _load_ts := 0.0
# 本次检查已触发计数
var _fired_this_check := 0
# ★ 批次 94：同刻多条事件的稳定次序键（自增，见 _cmp_entry）
var _next_seq := 0


func _ready() -> void:
	_resolve_path()
	_load_events()
	_load_settings()
	_load_ts = _unix_now()
	_accum = 0.0
	print("[Timeline] 就绪 文件=%s（计划 %d 条，上限 %d，检查周期 %.0fs）" % [
		_path, events.size(), max_simultaneous, check_interval_sec])


func _process(delta: float) -> void:
	_accum += delta
	if check_interval_sec > 0.0 and _accum >= check_interval_sec:
		_accum = 0.0
		check_now()


# ================= 对外接口 =================

## 当前系统秒级时间戳（本地）
func unix_now() -> float:
	return _unix_now()


## 手动触发一次检查（调试面板可调用）
func check_now() -> void:
	if events.is_empty():
		return
	var now := _unix_now()
	_fired_this_check = 0
	var changed := false
	# 单次线性扫描：从最早到点开始逐条判定（触发→删除；超上限→忽略 skip+1）。
	# 不跨轮重扫，避免同一检查周期内已判定的条目被重复处理。
	var i := 0
	while i < events.size():
		var e: Dictionary = events[i]
		var et: float = float(e.get("time_unix", 0.0))
		if et > now:
			i += 1
			continue  # 还没到点
		var props: Dictionary = e.get("props", {})
		if not _load_buffer_ok(e):
			i += 1
			continue  # 仍在载入 delay 缓冲内 → 本次不触发不移除
		var ignore: bool = _props_true(props, "ignore")
		var max_skip: int = int(props.get("max_skip", 0))
		var skip: int = int(props.get("skip", 0))
		var force := max_skip > 0 and skip >= max_skip
		if _fired_this_check >= max_simultaneous and not ignore and not force:
			# 超上限且未忽略且未达强制阈值 → 本次被忽略：skip+1 写回，但不删除
			props["skip"] = skip + 1
			events[i]["props"] = props
			events[i]["raw"] = _reconstruct(e)
			changed = true
			i += 1
			continue
		# —— 触发 ——
		_fire(e)
		events.remove_at(i)  # 删除后 i 不前进（下一条顶上）
		changed = true
		_fired_this_check += 1
	if changed:
		_save_events()
		timeline_changed.emit()


## 向时间轴追加一个事件（外部写入统一入口）
##   time_str: "2026.09.21.10:32:00"（本地墙钟）；props: 键值对 Dictionary；content: 触发内容
func append_event(time_str: String, props: Dictionary = {}, content: String = "") -> bool:
	var e := _parse_time(time_str)
	if e < 0.0:
		push_warning("[Timeline] 追加失败：时间格式不正确 %s" % time_str)
		return false
	var entry := {
		"time_str": time_str,
		"time_unix": e,
		"props": props.duplicate(true),
		"content": content,
		"raw": "",
		"seq": _alloc_seq(),
	}
	entry["raw"] = _reconstruct(entry)
	events.append(entry)
	_sort_events()
	_save_events()
	timeline_changed.emit()
	print("[Timeline] 已追加 %s  →  %s" % [time_str, content])
	return true


## ★ 批次 94：按**相对时间**追加（/add_timeline 用）。
##   seconds = 从现在起多少秒后；返回真正写入的**预计时刻**串（失败 → ""）。
## ★ 时间轴有「同时触发上限 / 载入延迟」等机制，实际触发可能晚于该时刻 → 界面上称「预计时间」。
func append_after(seconds: float, props: Dictionary = {}, content: String = "") -> String:
	var sec := seconds if seconds > 0.0 else 0.0
	var s := format_time(_unix_now() + sec)
	if s.is_empty() or not append_event(s, props, content):
		return ""
	return s


## ★ 批次 94：同刻多条事件的稳定次序键（自增）。见 _cmp_entry。
func _alloc_seq() -> int:
	_next_seq += 1
	return _next_seq


## 删除指定下标的计划项（调试面板「手动清掉某条」用）
func remove_event(idx: int) -> bool:
	if idx < 0 or idx >= events.size():
		return false
	events.remove_at(idx)
	_save_events()
	timeline_changed.emit()
	return true


## 清空整个时间轴
func clear_all() -> void:
	events.clear()
	_save_events()
	timeline_changed.emit()


## 读档后调用：重置载入缓冲时刻（使 delay 迟到的判定从此刻重新计时）
func on_save_loaded() -> void:
	_load_ts = _unix_now()
	print("[Timeline] 读档完成，载入缓冲已重置（到期事件按 delay/上限规则处理）")
	check_now()


# ================= 触发分派 =================

func _fire(entry: Dictionary) -> void:
	var content := str(entry.get("content", "")).strip_edges()
	print("[Timeline] ▶ 触发 %s  （%s）" % [entry.get("time_str", ""), content])
	# 以 / 开头 → 视为统一命令语言（DSL），直接交给 ConsoleCommand 执行
	# （与「控制台 / 事件链按钮」同一套写法；/create_block、/set_var、/remove_block … 均可触发）
	if content.begins_with("/"):
		var res = ConsoleCommand.exec(content)
		for line in res.lines:
			print("[Timeline] ▶ " + line)
		if not res.ok:
			push_warning("[Timeline] 触发内容执行存在错误（见上方日志）")
		return
	if content.begins_with(CMD_EVENT):
		var arg := content.trim_prefix(CMD_EVENT).strip_edges()
		var parts := arg.split("/")
		if parts.size() >= 2 and not parts[0].is_empty() and not parts[1].is_empty():
			# null-safe 取事件链执行器（避免裸 autoload 名在脱离 autoload 的单测环境编译失败）
			var runner = get_node_or_null("/root/EventChainRunner")
			if runner != null:
				runner.run_event(parts[0].strip_edges(), parts[1].strip_edges())
				return
	timeline_fired.emit(entry)


# ================= 载入缓冲 =================

func _load_buffer_ok(e: Dictionary) -> bool:
	var props: Dictionary = e.get("props", {})
	var delay: float = float(props.get("delay", 0.0))
	if delay <= 0.0:
		return true
	# 事件到点时刻距「载入时刻」不足 delay → 仍在缓冲内，不触发
	var et: float = float(e.get("time_unix", 0.0))
	return _load_ts + delay <= _unix_now() or et > _load_ts


# ================= 读写 =================

func _resolve_path() -> void:
	var d := ""
	if get_node_or_null("/root/SaveManager") != null:
		d = get_node("/root/SaveManager").get_temp_dir()
	if d.is_empty():
		var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
		if docs.is_empty():
			docs = OS.get_environment("USERPROFILE")
		d = docs.path_join("HelloNyxel/Temp")
	_path = d.path_join(FILE_NAME)


func _load_events() -> void:
	events.clear()
	if not FileAccess.file_exists(_path):
		return
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		push_warning("[Timeline] 计划文件打不开 %s" % _path)
		return
	var txt := f.get_as_text()
	f.close()
	for line in txt.split("\n"):
		var e := _parse_line(line)
		if not e.is_empty():
			# ★ 文件按排序后的顺序写出 → 读回时按行序分配 seq，可完整保序
			e["seq"] = _alloc_seq()
			events.append(e)
	_sort_events()


func _parse_line(line: String) -> Dictionary:
	var s := line.strip_edges()
	if s.is_empty() or not s.begins_with("["):
		return {}
	var cb := s.find("]")
	if cb < 0:
		return {}
	var time_str := s.substr(1, cb - 1).strip_edges()
	var t := _parse_time(time_str)
	if t < 0.0:
		return {}
	var rest := s.substr(cb + 1).strip_edges()
	var props: Dictionary = {}
	if rest.begins_with("("):
		var pr := rest.find(")")
		if pr < 0:
			return {}
		props = _parse_props(rest.substr(1, pr - 1))
		rest = rest.substr(pr + 1).strip_edges()
	var content := ""
	if rest.begins_with("{"):
		var brace := rest.find("}")
		if brace >= 0:
			content = rest.substr(1, brace - 1).strip_edges()
		else:
			content = rest.substr(1).strip_edges()
	return {
		"time_str": time_str,
		"time_unix": t,
		"props": props,
		"content": content,
		"raw": line.strip_edges(),
	}


func _save_events() -> void:
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		push_warning("[Timeline] 计划文件写入失败 %s" % _path)
		return
	var lines: Array = []
	for e in events:
		lines.append(e.get("raw", _reconstruct(e)))
	f.store_string("\n".join(lines) + "\n")
	f.close()


# 重建一行文本（跳过/追加时使用）
func _reconstruct(e: Dictionary) -> String:
	var props_str := _serialize_props(e.get("props", {}))
	var pre := "[" + str(e.get("time_str", "")) + "]"
	if not props_str.is_empty():
		pre += "(" + props_str + ")"
	return pre + "{" + str(e.get("content", "")) + "}"


func _sort_events() -> void:
	events.sort_custom(_cmp_entry)


## ★ 批次 94：排序比较 —— 先按时间，**同刻再按 seq**。
## ★ 为什么必须加第二关键字：Godot 的 sort_custom **不保证稳定**，只按时间排会让
##   「同一时刻写入的『效果』与『触发事件』」次序随机 → 用户会看到时有时无的先后颠倒。
##   seq 在写入时自增（先写的先执行）。
static func _cmp_entry(a: Dictionary, b: Dictionary) -> bool:
	var ta := float(a.get("time_unix", 0.0))
	var tb := float(b.get("time_unix", 0.0))
	if ta != tb:
		return ta < tb
	return int(a.get("seq", 0)) < int(b.get("seq", 0))


# ================= 属性解析 =================

# "k=v;tag;k2=v2" → {k:v, tag:"", k2:v2}；纯 tag 项视为 tag=""（或用当前值）
func _parse_props(s: String) -> Dictionary:
	var out: Dictionary = {}
	for part in str(s).split(";"):
		var p := part.strip_edges()
		if p.is_empty():
			continue
		var eq := p.find("=")
		if eq < 0:
			# 纯标签 → 落到 tag（兼容草案单标签写法）
			out["tag"] = p
		else:
			out[p.substr(0, eq).strip_edges()] = p.substr(eq + 1).strip_edges()
	return out


func _serialize_props(props: Dictionary) -> String:
	if props.is_empty():
		return ""
	var parts: Array = []
	for k in props:
		var v := str(props[k])
		parts.append(str(k) if v == "" else "%s=%s" % [k, v])
	return ";".join(parts)


func _props_true(props: Dictionary, key: String) -> bool:
	var v := str(props.get(key, "")).strip_edges().to_lower()
	if v == "1" or v == "true" or v == "yes" or v == "on":
		return true
	# ★ 批次 94：兼容「数值写法」—— 手写/工具写进文件的 ignore=1.0、2 等，非零即真。
	#   （不加这条，"1.0" 会被判成假 → 「忽略同时触发上限」静默失效。）
	if v.is_valid_float():
		return not is_zero_approx(float(v))
	return false


# ================= 时间与设置 =================

func _unix_now() -> float:
	return float(Time.get_unix_time_from_system())


## 本机时区相对 UTC 的偏移（秒，东八区 = +28800）。
## ★ 为什么需要：Time.get_unix_time_from_datetime_dict() 把入参字典当 **UTC** 解释，
##   而 _unix_now() 返回的是真实纪元秒 → 计划文件里手写的「本地墙钟时刻」会整体偏一个时区
##   （东八区偏 8 小时，事件会提前 8 小时触发）。这里统一按**本地墙钟**读写：
##     解析 = UTC 解释结果 - bias；格式化 = 先 +bias 再取 UTC 字典。
##   两者互为逆运算，且与人对文件的直觉一致。
func _tz_bias_sec() -> float:
	var tz := Time.get_time_zone_from_system()
	return float(tz.get("bias", 0.0)) * 60.0


## ★ 批次 94：unix 秒 → 计划文件时刻串 "YYYY.MM.DD.HH:MM:SS"（**本地墙钟**，与 _parse_time 互逆）。
func format_time(t: float) -> String:
	var d := Time.get_datetime_dict_from_unix_time(int(floor(t + _tz_bias_sec())))
	return "%04d.%02d.%02d.%02d:%02d:%02d" % [
		int(d.get("year", 1970)), int(d.get("month", 1)), int(d.get("day", 1)),
		int(d.get("hour", 0)), int(d.get("minute", 0)), int(d.get("second", 0))]


# "YYYY.MM.DD.HH:MM:SS"（本地墙钟）→ unix 秒；解析失败返回 -1
func _parse_time(s: String) -> float:
	var pat := RegEx.create_from_string("^(\\d{4})\\.(\\d{2})\\.(\\d{2})\\.(\\d{2}):(\\d{2}):(\\d{2})$")
	var m := pat.search(s.strip_edges())
	if m == null:
		return -1.0
	var dt := {
		"year": int(m.get_string(1)),
		"month": int(m.get_string(2)),
		"day": int(m.get_string(3)),
		"hour": int(m.get_string(4)),
		"minute": int(m.get_string(5)),
		"second": int(m.get_string(6)),
	}
	return float(Time.get_unix_time_from_datetime_dict(dt)) - _tz_bias_sec()


# ---- 设置落盘 ----
const SETTINGS_PATH := "HelloNyxel/settings/settings.json"

func _load_settings() -> void:
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs.is_empty():
		docs = OS.get_environment("USERPROFILE")
	var p := docs.path_join(SETTINGS_PATH)
	if not FileAccess.file_exists(p):
		return
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return
	var parser := JSON.new()
	if parser.parse(f.get_as_text()) != OK:
		f.close()
		return
	f.close()
	var data: Variant = parser.data
	if data is Dictionary:
		# 从已有设置文件读取历史并存的最小字段：新写时合并回写，不互相覆盖
		if (data as Dictionary).has("timeline_max_simultaneous"):
			max_simultaneous = maxi(1, int(data["timeline_max_simultaneous"]))


func set_max_simultaneous(n: int) -> void:
	max_simultaneous = maxi(1, n)
	_save_settings()


func get_max_simultaneous() -> int:
	return max_simultaneous


func _save_settings() -> void:
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs.is_empty():
		docs = OS.get_environment("USERPROFILE")
	var p := docs.path_join(SETTINGS_PATH)
	var data: Dictionary = {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f != null:
		var parser := JSON.new()
		if parser.parse(f.get_as_text()) == OK and parser.data is Dictionary:
			data = parser.data
		f.close()
	data["timeline_max_simultaneous"] = max_simultaneous
	var w := FileAccess.open(p, FileAccess.WRITE)
	if w != null:
		w.store_string(JSON.stringify(data, "\t"))
		w.close()