# autoload/course_schedule.gd
# 课程表数据层（v3：主时段 + 分时段 + 穿插 layout + 每节单设时间 + 学期周数/当前周）。
#
# 落盘：%文档%/HelloNyxel/Temp/course_schedule.json
#
# ★ 数据模型（version = 3）：
#   {
#     "version": 3,
#     "semester_weeks": 20,                 # 本学期总周数（1..60）
#     "current_week": 1,                    # 当前周（1..semester_weeks）
#     "main_periods": [                     # 主时段有序数组
#       {
#         "name": "上午",                    # 主时段名
#         "start": "08:00",                  # 主时段整体起止（展示用）
#         "end": "12:00",
#         "layout": ["sub:早读","class","sub:课间操","class","class"],  # 穿插序列
#         "subs": {                          # 该主时段下的分时段（按名索引）
#           "早读":   { "name":"早读",   "start":"07:30","end":"08:00","has_classes":true  },
#           "课间操": { "name":"课间操", "start":"10:00","end":"10:20","has_classes":false }
#         },
#         "class_times": [                   # 每节课时间，长度 = layout 中 "class" 个数
#           {"start":"08:00","end":"08:45"},
#           {"start":"10:20","end":"11:05"},
#           {"start":"11:15","end":"12:00"}
#         ]
#       },
#       ...
#     ],
#     "grid": {                              # 按 slot key "mp:entry" 存 cell
#       "0:1": { "subject":"语文", "weeks":[1,3] },   # weeks：1-based 周序号；空=每周都上
#       "0:2": { "subject":"数学", "teacher":"王老师", "weeks":[] },  # teacher：教学老师（可省/空=不显示）
#       ...
#     }
#   }
#
# ★ 穿插序列 layout：每个元素是 "class"（一节课槽）或 "sub:<分时段名>"（分时段块）。
# ★ 分时段 has_classes=false → 只显示时间块（不填科目）；has_classes=true → 也能填科目。
# ★ 一节（class 槽）的时间来自 main_period.class_times[classIndex]（classIndex = 该主时段内第几个 class）。
# ★ 分时段块的时间来自 main_period.subs[名].start/end。
# ★ 学期周数/当前周：cell.weeks 为空=每周都上；否则本节课仅在 current_week ∈ weeks 时显示在课程表。
# ★ 时令（summer/winter）在 v3 中**不再区分**——每节课/分时段只存单一起止时间。
#
# ★ 本脚本是 autoload 单例（名 CourseSchedule），不声明 class_name。外部访问一律走方法。
extends Node

const VERSION: int = 3
const WEEKDAYS: int = 7
const MIN_SEMESTER_WEEKS: int = 1
const MAX_SEMESTER_WEEKS: int = 60
const MAX_MAIN_PERIODS: int = 16
const MAX_SUBS_PER_MAIN: int = 16
const MAX_LAYOUT_ENTRIES: int = 48

# 默认主时段名（有序）
const DEFAULT_MAIN_NAMES: Array[String] = ["上午", "中午", "下午", "晚上"]
# 默认分时段名（玩家可新建/归属到任意主时段）
const DEFAULT_SUB_NAMES: Array[String] = ["早读", "课间操", "活动课", "社团活动"]

# 数据变化（单元格增删改 / 周数·当前周变化 / 时段·穿插·时间变化 / 重新读盘）—— 面板据此实时刷新
signal changed(data: Dictionary)

var _data: Dictionary = {}
var _loaded: bool = false


# 惰性加载：不在 _ready 里读盘
func load_data() -> Dictionary:
	if not _loaded:
		_data = read_from_disk()
		_loaded = true
	return _data


func read_from_disk() -> Dictionary:
	var out := empty_data()
	var path := resolve_path()
	if not FileAccess.file_exists(path):
		return out
	var txt := FileAccess.get_file_as_string(path)
	if txt.strip_edges().is_empty():
		return out
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		push_warning("[CourseSchedule] 课程表 JSON 无法解析为对象: " + path)
		return out
	var d: Dictionary = parsed
	if d.has("main_periods") and (d["main_periods"] is Array):
		# —— v3 直接读取 ——
		if d.has("semester_weeks") and _is_num(d["semester_weeks"]):
			out["semester_weeks"] = int(d["semester_weeks"])
		if d.has("current_week") and _is_num(d["current_week"]):
			out["current_week"] = int(d["current_week"])
		out["main_periods"] = d["main_periods"]
		if d.has("grid") and (d["grid"] is Dictionary):
			out["grid"] = d["grid"]
	elif d.has("segments") or d.has("periods"):
		# —— v2（单总表 + 节次级时间）→ v3 迁移 ——
		out = _migrate_v2(d)
	else:
		# 未知 / 残缺 → 空 v3（_normalize 兜底）
		pass
	_normalize(out)
	return out


# v2→v3：保留科目与每节时间，重建主/分时段 + 穿插 + 学期周数。
# v2 的 week_count（循环周期）= 旧语义，不能直接当学期周数 → 落默认 20 周；cell.weeks 旧为 0-based 循环周 → 迁移后统一置空（每周都上）。
func _migrate_v2(d: Dictionary) -> Dictionary:
	var out := empty_data()
	var old_grid: Variant = d.get("grid", [])
	var old_periods: Variant = d.get("periods", [])
	var rc := int(d.get("row_count", DEFAULT_MAIN_NAMES.size())) if _is_num(d.get("row_count", DEFAULT_MAIN_NAMES.size())) else DEFAULT_MAIN_NAMES.size()
	# 全局 class 槽序号 → (mp, entry) 映射（仅 v3 默认结构的 class 槽）
	var class_slots: Array = []   # 每个元素 { "mp":int, "entry":int }
	var mps: Array = out["main_periods"]
	for mpi in range(mps.size()):
		var mp: Dictionary = mps[mpi]
		var lay: Array = mp.get("layout", [])
		for ei in range(lay.size()):
			if str(lay[ei]) == "class":
				class_slots.append({"mp": mpi, "entry": ei})
	# 旧 v2 grid[wd][r]：r 对应全局第 r 个 class 槽
	if old_grid is Array:
		for wd in range(min(WEEKDAYS, (old_grid as Array).size())):
			var dayv: Variant = (old_grid as Array)[wd]
			if not (dayv is Array):
				continue
			var day_arr: Array = dayv
			for r in range(min(rc, day_arr.size())):
				var c: Variant = day_arr[r]
				if c == null or not (c is Dictionary):
					continue
				var subj := str((c as Dictionary).get("subject", "")).strip_edges()
				if subj.is_empty():
					continue
				if r < class_slots.size():
					var slot: Dictionary = class_slots[r]
					var key := "%d:%d:%d" % [wd, int(slot["mp"]), int(slot["entry"])]
					(out["grid"] as Dictionary)[key] = _make_cell_dict(subj, [])
	# 旧 v2 每节时间 → 映射到全局第 r 个 class 槽的 class_times
	if old_periods is Array:
		for r in range(min(rc, (old_periods as Array).size())):
			var p: Variant = (old_periods as Array)[r]
			if not (p is Dictionary):
				continue
			if r >= class_slots.size():
				break
			var slot: Dictionary = class_slots[r]
			var mp: Dictionary = (out["main_periods"] as Array)[int(slot["mp"])]
			var cidx := 0
			var lay: Array = mp.get("layout", [])
			for ei in range(int(slot["entry"])):
				if str(lay[ei]) == "class":
					cidx += 1
			var times: Array = mp.get("class_times", [])
			while times.size() <= cidx:
				times.append(_default_class_time(8 * 60 + times.size() * 55, 45))
			var sm: Variant = p.get("summer", {})
			var st := "08:00"
			var en := "08:45"
			if sm is Dictionary and (not str((sm as Dictionary).get("start", "")).is_empty()):
				st = str((sm as Dictionary).get("start", "08:00"))
				en = str((sm as Dictionary).get("end", "08:45"))
			times[cidx] = {"start": st, "end": en}
			mp["class_times"] = times
	return out


func reload() -> Dictionary:
	_data = read_from_disk()
	_loaded = true
	changed.emit(_data)
	return _data


func empty_data() -> Dictionary:
	var d := {
		"version": VERSION,
		"semester_weeks": 20,
		"current_week": 1,
		"main_periods": [],
		"grid": {},
	}
	_populate_default_periods(d)
	return d


# 用默认主/分时段 + 穿插 + 每节时间填充 d["main_periods"]。
func _populate_default_periods(d: Dictionary) -> void:
	var mps: Array = []
	# 上午：早读 + 3 节课（含课间操穿插）
	mps.append(_make_main("上午", "07:30", "12:00",
		["sub:早读", "class", "sub:课间操", "class", "class"],
		{"早读": _make_sub("早读", "07:30", "08:00", true),
		 "课间操": _make_sub("课间操", "10:00", "10:20", false)},
		[ _dt(8*60, 45), _dt(10*60+20, 45), _dt(11*60+15, 45) ]))
	# 中午：1 节课
	mps.append(_make_main("中午", "12:00", "14:00",
		["class"], {}, [ _dt(12*60, 45) ]))
	# 下午：3 节课（含活动课穿插）
	mps.append(_make_main("下午", "14:00", "18:00",
		["class", "class", "sub:活动课", "class"],
		{"活动课": _make_sub("活动课", "16:00", "16:40", true)},
		[ _dt(14*60, 45), _dt(14*60+55, 45), _dt(16*60+40, 45) ]))
	# 晚上：2 节课（含社团活动穿插）
	mps.append(_make_main("晚上", "18:00", "21:00",
		["class", "sub:社团活动", "class"],
		{"社团活动": _make_sub("社团活动", "19:00", "19:40", true)},
		[ _dt(18*60, 45), _dt(19*60+40, 45) ]))
	d["main_periods"] = mps


func _make_main(name: String, start: String, end: String, layout: Array, subs: Dictionary, class_times: Array) -> Dictionary:
	return {
		"name": name,
		"start": start,
		"end": end,
		"layout": layout,
		"subs": subs,
		"class_times": class_times,
	}


func _make_sub(name: String, start: String, end: String, has_classes: bool) -> Dictionary:
	return {"name": name, "start": start, "end": end, "has_classes": has_classes}


func _dt(start_min: int, dur_min: int) -> Dictionary:
	return {"start": _hhmm(start_min), "end": _hhmm(start_min + dur_min)}


func _default_class_time(start_min: int, dur_min: int) -> Dictionary:
	return _dt(start_min, dur_min)


# ============ 规范化 ============

func _normalize(d: Dictionary) -> void:
	var sw := int(d.get("semester_weeks", 20))
	if sw < MIN_SEMESTER_WEEKS:
		sw = MIN_SEMESTER_WEEKS
	if sw > MAX_SEMESTER_WEEKS:
		sw = MAX_SEMESTER_WEEKS
	d["semester_weeks"] = sw
	var cw := int(d.get("current_week", 1))
	if cw < 1:
		cw = 1
	if cw > sw:
		cw = sw
	d["current_week"] = cw

	var mps: Variant = d.get("main_periods", [])
	if not (mps is Array) or (mps as Array).is_empty():
		_populate_default_periods(d)
		mps = d["main_periods"]
	var mpa: Array = mps
	if mpa.size() > MAX_MAIN_PERIODS:
		mpa.resize(MAX_MAIN_PERIODS)
	for i in range(mpa.size()):
		if not (mpa[i] is Dictionary):
			mpa[i] = _make_main("时段%d" % (i + 1), "08:00", "12:00", ["class"], {}, [_dt(8*60, 45)])
		_normalize_main(mpa[i] as Dictionary)
	d["main_periods"] = mpa

	# grid：只保留 key 合法且 slot 可编辑的 cell
	var grid: Variant = d.get("grid", {})
	if not (grid is Dictionary):
		grid = {}
	var gdict: Dictionary = grid
	var valid_keys: Dictionary = {}
	for wd in range(WEEKDAYS):
		for slot in slots_from(d):
			valid_keys[cell_key(wd, int(slot["mp"]), int(slot["entry"]))] = true
	for key in gdict.keys():
		if not valid_keys.has(key):
			gdict.erase(key)
	d["grid"] = gdict


# 规范化单个主时段（缺省兜底，保证字段齐全、layout 与 class_times 自洽）。
func _normalize_main(mp: Dictionary) -> void:
	if not mp.has("name") or str(mp.get("name", "")).strip_edges().is_empty():
		mp["name"] = "时段"
	mp["name"] = str(mp["name"]).strip_edges()
	if not mp.has("start") or not _valid_hhmm(str(mp.get("start", ""))):
		mp["start"] = "08:00"
	if not mp.has("end") or not _valid_hhmm(str(mp.get("end", ""))):
		mp["end"] = "12:00"
	if not mp.has("subs") or not (mp["subs"] is Dictionary):
		mp["subs"] = {}
	var subs: Dictionary = mp["subs"]
	for k in subs.keys():
		var s: Variant = subs[k]
		if not (s is Dictionary):
			subs[k] = _make_sub(str(k), "10:00", "10:20", false)
		var sd: Dictionary = subs[k]
		if not sd.has("name") or str(sd.get("name", "")).is_empty():
			sd["name"] = str(k)
		if not sd.has("start") or not _valid_hhmm(str(sd.get("start", ""))):
			sd["start"] = "10:00"
		if not sd.has("end") or not _valid_hhmm(str(sd.get("end", ""))):
			sd["end"] = "10:20"
		sd["has_classes"] = bool(sd.get("has_classes", false))
	if not mp.has("layout") or not (mp["layout"] is Array):
		mp["layout"] = ["class"]
	var lay: Array = mp["layout"]
	if lay.is_empty():
		lay.append("class")
	# 校验 layout 每一项；缺省 sub 引用则补建
	var cleaned: Array = []
	for e in lay:
		var es := str(e)
		if es == "class":
			cleaned.append("class")
		elif es.begins_with("sub:"):
			var sname := es.substr(4)
			if sname.is_empty():
				cleaned.append("class")
			else:
				if not subs.has(sname):
					subs[sname] = _make_sub(sname, "10:00", "10:20", false)
				cleaned.append("sub:" + sname)
		else:
			cleaned.append("class")
	if cleaned.size() > MAX_LAYOUT_ENTRIES:
		cleaned.resize(MAX_LAYOUT_ENTRIES)
	mp["layout"] = cleaned
	# class_times 长度 = class 个数（保留已有，缺补默认，多裁剪）
	var class_count := 0
	for e in cleaned:
		if str(e) == "class":
			class_count += 1
	var times: Variant = mp.get("class_times", [])
	if not (times is Array):
		times = []
	var ta: Array = times
	while ta.size() < class_count:
		ta.append(_default_class_time(8*60 + ta.size()*55, 45))
	if ta.size() > class_count:
		ta.resize(class_count)
	mp["class_times"] = ta


# ============ 读取 ============

func get_semester_weeks() -> int:
	return int(load_data().get("semester_weeks", 20))


func get_current_week() -> int:
	return int(load_data().get("current_week", 1))


func get_main_periods() -> Array:
	return (load_data().get("main_periods", []) as Array).duplicate(true)


func get_main_period(mp: int) -> Variant:
	var mps: Array = load_data().get("main_periods", [])
	if mp < 0 or mp >= mps.size():
		return null
	return mps[mp]


func get_main_count() -> int:
	return int((load_data().get("main_periods", []) as Array).size())


## 把 d 中的 main_periods 拍平成有序 slot 列表。
## slot = { "mp":int, "entry":int, "kind":"class"|"sub", "sub_name":String, "mp_name":String }
func slots_from(d: Dictionary) -> Array:
	var out: Array = []
	var mps: Array = d.get("main_periods", [])
	for mpi in range(mps.size()):
		var mp: Dictionary = mps[mpi]
		var lay: Array = mp.get("layout", [])
		var mp_name := str(mp.get("name", "时段"))
		for ei in range(lay.size()):
			var es := str(lay[ei])
			if es == "class":
				out.append({"mp": mpi, "entry": ei, "kind": "class", "sub_name": "", "mp_name": mp_name})
			elif es.begins_with("sub:"):
				out.append({"mp": mpi, "entry": ei, "kind": "sub", "sub_name": es.substr(4), "mp_name": mp_name})
	return out


## 拍平「当前已加载数据」的 slot 列表。
func slots() -> Array:
	return slots_from(load_data())


func slot_key(mp: int, entry: int) -> String:
	return "%d:%d" % [mp, entry]


## 取某 (星期, slot) 的 cell 键（grid 按此存储）。
func cell_key(wd: int, mp: int, entry: int) -> String:
	return "%d:%d:%d" % [wd, mp, entry]


## 取某 (星期, slot) 的 cell（仅可编辑槽有效；不可编辑槽恒返回 null）。
func get_cell(wd: int, mp: int, entry: int) -> Variant:
	if wd < 0 or wd >= WEEKDAYS:
		return null
	var slot: Dictionary = _lookup_slot(mp, entry)
	if slot == null:
		return null
	if str(slot["kind"]) == "sub" and not _sub_has_classes(mp, str(slot["sub_name"])):
		return null
	var grid: Dictionary = load_data().get("grid", {})
	var key := cell_key(wd, mp, entry)
	if grid.has(key):
		return grid[key]
	return null


func _lookup_slot(mp: int, entry: int) -> Variant:
	var mps: Array = load_data().get("main_periods", [])
	if mp < 0 or mp >= mps.size():
		return null
	var mp_dict: Dictionary = mps[mp]
	var lay: Array = mp_dict.get("layout", [])
	if entry < 0 or entry >= lay.size():
		return null
	var es := str(lay[entry])
	if es == "class":
		return {"mp": mp, "entry": entry, "kind": "class", "sub_name": "", "mp_name": str(mp_dict.get("name", ""))}
	return {"mp": mp, "entry": entry, "kind": "sub", "sub_name": es.substr(4), "mp_name": str(mp_dict.get("name", ""))}


func _sub_has_classes(mp: int, name: String) -> bool:
	var mps: Array = load_data().get("main_periods", [])
	if mp < 0 or mp >= mps.size():
		return false
	var mp_dict: Dictionary = mps[mp]
	var subs: Dictionary = mp_dict.get("subs", {})
	if subs.has(name) and (subs[name] is Dictionary):
		return bool((subs[name] as Dictionary).get("has_classes", false))
	return false


## 某 slot 是否可填科目（class 槽，或 has_classes 的分时段槽）。
func is_slot_editable(mp: int, entry: int) -> bool:
	var slot: Dictionary = _lookup_slot(mp, entry)
	if slot == null:
		return false
	if str(slot["kind"]) == "class":
		return true
	return _sub_has_classes(mp, str(slot["sub_name"]))


## 公开：分时段是否有课（按名查询）。
func sub_has_classes(mp: int, name: String) -> bool:
	return _sub_has_classes(mp, name)


## 公开：查询某 (mp, entry) 的 slot 描述。
func lookup_slot(mp: int, entry: int) -> Variant:
	return _lookup_slot(mp, entry)


## 公开：某 entry 在主时段内是第几节课（class 序号，0-based）。
func class_index_in_main(mp: int, entry: int) -> int:
	return _class_index_in_main(mp, entry)


## 某 slot 的起止时间（class 槽取自 class_times；sub 槽取自 subs）。
func get_slot_time(mp: int, entry: int) -> Dictionary:
	var slot: Dictionary = _lookup_slot(mp, entry)
	if slot == null:
		return {"start": "", "end": ""}
	if str(slot["kind"]) == "class":
		var cidx := _class_index_in_main(mp, entry)
		var mp_dict: Dictionary = (load_data().get("main_periods", []) as Array)[mp]
		var times: Array = mp_dict.get("class_times", [])
		if cidx >= 0 and cidx < times.size() and (times[cidx] is Dictionary):
			var t: Dictionary = times[cidx]
			return {"start": str(t.get("start", "")), "end": str(t.get("end", ""))}
		return {"start": "", "end": ""}
	var sname := str(slot["sub_name"])
	var mp_dict: Dictionary = (load_data().get("main_periods", []) as Array)[mp]
	var subs: Dictionary = mp_dict.get("subs", {})
	if subs.has(sname) and (subs[sname] is Dictionary):
		var s: Dictionary = subs[sname]
		return {"start": str(s.get("start", "")), "end": str(s.get("end", ""))}
	return {"start": "", "end": ""}


func _class_index_in_main(mp: int, entry: int) -> int:
	var mps: Array = load_data().get("main_periods", [])
	if mp < 0 or mp >= mps.size():
		return -1
	var lay: Array = (mps[mp] as Dictionary).get("layout", [])
	var idx := 0
	for ei in range(entry):
		if str(lay[ei]) == "class":
			idx += 1
	return idx


## 某主时段内 class 槽个数。
func class_count_of(mp: int) -> int:
	var mps: Array = load_data().get("main_periods", [])
	if mp < 0 or mp >= mps.size():
		return 0
	var lay: Array = (mps[mp] as Dictionary).get("layout", [])
	var n := 0
	for e in lay:
		if str(e) == "class":
			n += 1
	return n


# ============ 周数 / 当前周 计算 ============

## 这节课在「当前周」是否生效。weeks 为空（=[]）→ 每周都上。
func is_cell_active_today(cell: Variant) -> bool:
	if not (cell is Dictionary):
		return false
	var wks: Variant = cell.get("weeks", [])
	if not (wks is Array) or (wks as Array).is_empty():
		return true
	return int(load_data().get("current_week", 1)) in (wks as Array)


# ============ 「上课时为忙」：当前是否处在有课时段（批次 549） ============

## 纯函数：给定课程表数据 + 星期 + 分钟 + 当前周 → 当前是否处在「有课时段」。
## 供 BusyState 每秒 tick 调用（性能忙闲 ↔ 课程表联动），也可注入任意时间断言。
##
## weekday_iso: 1=周一…7=周日（与 BusyState._now_parts 同口径）；minutes: 0..1439；
## week: 当前周（1-based，仅用于 cell.weeks 过滤；空 weeks = 每周都上）。
##
## 命中条件（全部满足）：
##   · 该 (星期, slot) 可填科目（class 槽，或 has_classes=true 的分时段槽）；
##   · 该格填了科目（subject 非空）；
##   · 本周生效（weeks 空 = 每周；否则 week ∈ weeks）；
##   · start ≤ now < end（end < start 视为跨夜：now ≥ start 或 now < end）；
##     start == end 视为**不命中**（课程时段不会「全天」，避免 00:00-00:00 误伤）。
##
## 返回 { active, key, subject, start, end, mp, entry }；未命中 active=false、key="".
## key = "wd:mp:entry"（同格唯一；同时命中多格时取 mp/entry 最前者，状态只是 bool 无歧义）。
func class_window_from(d: Dictionary, weekday_iso: int, minutes: int, week: int) -> Dictionary:
	var out := {"active": false, "key": "", "subject": "", "start": -1, "end": -1, "mp": -1, "entry": -1}
	var wd: int = weekday_iso - 1
	if wd < 0 or wd >= WEEKDAYS:
		return out
	var mps: Array = d.get("main_periods", [])
	var grid: Dictionary = d.get("grid", {})
	if not (grid is Dictionary):
		return out
	for slot in slots_from(d):
		var mp: int = int(slot["mp"])
		var entry: int = int(slot["entry"])
		if not _slot_editable_in(mps, mp, entry):
			continue
		var cell: Variant = (grid as Dictionary).get(cell_key(wd, mp, entry), null)
		if not (cell is Dictionary):
			continue
		var subj := str((cell as Dictionary).get("subject", "")).strip_edges()
		if subj.is_empty():
			continue
		if not _weeks_active((cell as Dictionary).get("weeks", []), week):
			continue
		var t: Dictionary = _slot_time_in(mps, mp, entry)
		var smin: int = _hhmm_to_min(str(t.get("start", "")))
		var emin: int = _hhmm_to_min(str(t.get("end", "")))
		if smin < 0 or emin < 0:
			continue
		var hit := false
		if emin > smin:
			hit = minutes >= smin and minutes < emin
		elif emin < smin:
			# 跨夜：今晚开始（已过 start）或昨晚开始（还没到 end）
			hit = minutes >= smin or minutes < emin
		if not hit:
			continue
		out["active"] = true
		out["key"] = cell_key(wd, mp, entry)
		out["subject"] = subj
		out["start"] = smin
		out["end"] = emin
		out["mp"] = mp
		out["entry"] = entry
		return out
	return out


## 实例版：用当前系统时间 + current_week 判定（BusyState 调用入口）。
func class_window_now() -> Dictionary:
	var t := Time.get_datetime_dict_from_system(false)
	var wd: int = int(t["weekday"])
	var iso: int = 7 if wd == 0 else wd
	return class_window_from(load_data(), iso, int(t["hour"]) * 60 + int(t["minute"]), get_current_week())


## weeks 是否包含指定周（逐元素 int() 归一化；空数组 = 每周都上）。
## ★ 不用 `week in weeks`：JSON 读回的数字是 float，混类型比较不可靠。
func _weeks_active(wks: Variant, week: int) -> bool:
	if not (wks is Array) or (wks as Array).is_empty():
		return true
	for w in wks as Array:
		if int(w) == week:
			return true
	return false


## 「传入数据」版 slot 可填性（class_window_from 自包含，不读 load_data）。
func _slot_editable_in(mps: Array, mp: int, entry: int) -> bool:
	if mp < 0 or mp >= mps.size():
		return false
	var lay: Array = (mps[mp] as Dictionary).get("layout", [])
	if entry < 0 or entry >= lay.size():
		return false
	var es := str(lay[entry])
	if es == "class":
		return true
	if not es.begins_with("sub:"):
		return false
	var subs: Dictionary = (mps[mp] as Dictionary).get("subs", {})
	var sname := es.substr(4)
	if subs.has(sname) and (subs[sname] is Dictionary):
		return bool((subs[sname] as Dictionary).get("has_classes", false))
	return false


## 「传入数据」版 slot 起止时间（class 取 class_times[classIndex]；sub 取 subs[name]）。
func _slot_time_in(mps: Array, mp: int, entry: int) -> Dictionary:
	if mp < 0 or mp >= mps.size():
		return {"start": "", "end": ""}
	var mp_dict: Dictionary = mps[mp]
	var lay: Array = mp_dict.get("layout", [])
	if entry < 0 or entry >= lay.size():
		return {"start": "", "end": ""}
	var es := str(lay[entry])
	if es == "class":
		var cidx := 0
		for ei in range(entry):
			if str(lay[ei]) == "class":
				cidx += 1
		var times: Array = mp_dict.get("class_times", [])
		if cidx >= 0 and cidx < times.size() and (times[cidx] is Dictionary):
			var t: Dictionary = times[cidx]
			return {"start": str(t.get("start", "")), "end": str(t.get("end", ""))}
		return {"start": "", "end": ""}
	if not es.begins_with("sub:"):
		return {"start": "", "end": ""}
	var subs: Dictionary = mp_dict.get("subs", {})
	var sname := es.substr(4)
	if subs.has(sname) and (subs[sname] is Dictionary):
		var s: Dictionary = subs[sname]
		return {"start": str(s.get("start", "")), "end": str(s.get("end", ""))}
	return {"start": "", "end": ""}


## "HH:MM" → 当天分钟数；非法返回 -1。
func _hhmm_to_min(s: String) -> int:
	var parts: PackedStringArray = s.strip_edges().split(":")
	if parts.size() != 2:
		return -1
	if not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return -1
	var h := int(parts[0])
	var m := int(parts[1])
	if h < 0 or h > 23 or m < 0 or m > 59:
		return -1
	return h * 60 + m


# ============ 写入：单元格 ============

## 写一格（仅可编辑槽）。subject 字符串；weeks 为 1-based 周序号数组（空数组=每周）；
## teacher 为教学老师（可空；空则不写入该键，课程格对应行隐藏）。
func set_cell(wd: int, mp: int, entry: int, subject: String, weeks: Array, teacher: String = "") -> void:
	if wd < 0 or wd >= WEEKDAYS:
		return
	if not is_slot_editable(mp, entry):
		return
	var d := load_data()
	var n := int(d.get("semester_weeks", 20))
	var grid: Dictionary = d.get("grid", {})
	grid[cell_key(wd, mp, entry)] = _make_cell_dict(subj_string(subject), _norm_weeks(weeks, n), subj_string(teacher))
	d["grid"] = grid
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


## 清空一格
func clear_cell(wd: int, mp: int, entry: int) -> void:
	if wd < 0 or wd >= WEEKDAYS:
		return
	if not is_slot_editable(mp, entry):
		return
	var d := load_data()
	var grid: Dictionary = d.get("grid", {})
	grid.erase(cell_key(wd, mp, entry))
	d["grid"] = grid
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


func _norm_weeks(arr: Variant, n: int) -> Array:
	if not (arr is Array):
		return []
	var seen: Dictionary = {}
	var out: Array = []
	for v in (arr as Array):
		var i := int(v)
		if i < 1 or i > n:
			continue
		if not seen.has(i):
			seen[i] = true
			out.append(i)
	out.sort()
	if out.size() == 0 or out.size() == n:
		return []
	return out


## cell 字典：teacher 非空才写键（空 = 课程格不显示老师行）。
func _make_cell_dict(subject: String, weeks: Array, teacher: String = "") -> Dictionary:
	var d := {"subject": subj_string(subject), "weeks": _norm_weeks(weeks, int(load_data().get("semester_weeks", 20)))}
	var t := subj_string(teacher)
	if not t.is_empty():
		d["teacher"] = t
	return d


func subj_string(s: Variant) -> String:
	return str(s).strip_edges()


# ============ 写入：学期周数 / 当前周 ============

func set_semester_weeks(n: int) -> void:
	var d := load_data()
	var sw := int(n)
	if sw < MIN_SEMESTER_WEEKS:
		sw = MIN_SEMESTER_WEEKS
	if sw > MAX_SEMESTER_WEEKS:
		sw = MAX_SEMESTER_WEEKS
	d["semester_weeks"] = sw
	if int(d.get("current_week", 1)) > sw:
		d["current_week"] = sw
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


func set_current_week(n: int) -> void:
	var d := load_data()
	var sw := int(d.get("semester_weeks", 20))
	var cw := int(n)
	if cw < 1:
		cw = 1
	if cw > sw:
		cw = sw
	d["current_week"] = cw
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


# ============ 写入：主时段 ============

func add_main_period(name: String) -> int:
	var d := load_data()
	var mps: Array = d.get("main_periods", [])
	if len(mps) >= MAX_MAIN_PERIODS:
		return -1
	var nm := subj_string(name)
	if nm.is_empty():
		nm = "新时段"
	var mp := _make_main(nm, "08:00", "12:00", ["class"], {}, [_dt(8*60, 45)])
	mps.append(mp)
	d["main_periods"] = mps
	_normalize(d)
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)
	return mps.size() - 1


func rename_main_period(idx: int, new_name: String) -> void:
	var d := load_data()
	var mps: Array = d.get("main_periods", [])
	if idx < 0 or idx >= mps.size():
		return
	var nn := subj_string(new_name)
	if nn.is_empty():
		return
	(mps[idx] as Dictionary)["name"] = nn
	d["main_periods"] = mps
	_normalize(d)
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


func remove_main_period(idx: int) -> void:
	var d := load_data()
	var mps: Array = d.get("main_periods", [])
	if idx < 0 or idx >= mps.size() or mps.size() <= 1:
		return
	mps.remove_at(idx)
	d["main_periods"] = mps
	# 清掉该主时段相关的 grid key（键格式 "wd:mp:entry"）
	var grid: Dictionary = d.get("grid", {})
	for key in grid.keys():
		var parts: PackedStringArray = key.split(":")
		if parts.size() >= 3 and int(parts[1]) == idx:
			grid.erase(key)
	d["grid"] = grid
	_normalize(d)
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


func move_main_period(from: int, to: int) -> void:
	var d := load_data()
	var mps: Array = d.get("main_periods", [])
	if from < 0 or from >= mps.size() or to < 0 or to >= mps.size() or from == to:
		return
	var v: Variant = mps[from]
	mps.remove_at(from)
	mps.insert(to, v)
	d["main_periods"] = mps
	_normalize(d)
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


func set_main_period_times(idx: int, start: String, end: String) -> void:
	var d := load_data()
	var mps: Array = d.get("main_periods", [])
	if idx < 0 or idx >= mps.size():
		return
	var mp: Dictionary = mps[idx]
	if _valid_hhmm(start):
		mp["start"] = _norm_hhmm(start)
	if _valid_hhmm(end):
		mp["end"] = _norm_hhmm(end)
	d["main_periods"] = mps
	_normalize(d)
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


# ============ 写入：分时段（位于某主时段内） ============

func add_sub(mp_idx: int, name: String, start: String, end: String, has_classes: bool) -> void:
	var d := load_data()
	var mps: Array = d.get("main_periods", [])
	if mp_idx < 0 or mp_idx >= mps.size():
		return
	var nm := subj_string(name)
	if nm.is_empty():
		return
	var mp: Dictionary = mps[mp_idx]
	var subs: Dictionary = mp.get("subs", {})
	if subs.has(nm):
		return
	if subs.size() >= MAX_SUBS_PER_MAIN:
		return
	subs[nm] = _make_sub(nm, _norm_hhmm(start) if _valid_hhmm(start) else "10:00",
		_norm_hhmm(end) if _valid_hhmm(end) else "10:20", has_classes)
	mp["subs"] = subs
	# 新建分时段默认插到 layout 末尾，使其立即可见
	var lay: Array = mp.get("layout", [])
	if lay.size() < MAX_LAYOUT_ENTRIES:
		lay.append("sub:" + nm)
		mp["layout"] = lay
	d["main_periods"] = mps
	_normalize(d)
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


func rename_sub(mp_idx: int, old_name: String, new_name: String) -> void:
	var d := load_data()
	var mps: Array = d.get("main_periods", [])
	if mp_idx < 0 or mp_idx >= mps.size():
		return
	var on := subj_string(old_name)
	var nn := subj_string(new_name)
	if on.is_empty() or nn.is_empty() or (nn == on):
		return
	var mp: Dictionary = mps[mp_idx]
	var subs: Dictionary = mp.get("subs", {})
	if not subs.has(on) or subs.has(nn):
		return
	var s: Dictionary = subs[on]
	subs.erase(on)
	s["name"] = nn
	subs[nn] = s
	# layout 里的 "sub:on" 改成 "sub:nn"
	var lay: Array = mp.get("layout", [])
	for i in range(lay.size()):
		if str(lay[i]) == ("sub:" + on):
			lay[i] = "sub:" + nn
	mp["subs"] = subs
	mp["layout"] = lay
	d["main_periods"] = mps
	_normalize(d)
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


func set_sub(mp_idx: int, name: String, start: String, end: String, has_classes: bool) -> void:
	var d := load_data()
	var mps: Array = d.get("main_periods", [])
	if mp_idx < 0 or mp_idx >= mps.size():
		return
	var nm := subj_string(name)
	var mp: Dictionary = mps[mp_idx]
	var subs: Dictionary = mp.get("subs", {})
	if not subs.has(nm):
		return
	var s: Dictionary = subs[nm]
	if _valid_hhmm(start):
		s["start"] = _norm_hhmm(start)
	if _valid_hhmm(end):
		s["end"] = _norm_hhmm(end)
	s["has_classes"] = bool(has_classes)
	subs[nm] = s
	mp["subs"] = subs
	d["main_periods"] = mps
	_normalize(d)
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


func remove_sub(mp_idx: int, name: String) -> void:
	var d := load_data()
	var mps: Array = d.get("main_periods", [])
	if mp_idx < 0 or mp_idx >= mps.size():
		return
	var nm := subj_string(name)
	var mp: Dictionary = mps[mp_idx]
	var subs: Dictionary = mp.get("subs", {})
	if not subs.has(nm):
		return
	subs.erase(nm)
	# 从 layout 移除所有 "sub:nm"
	var lay: Array = mp.get("layout", [])
	var cleaned: Array = []
	for e in lay:
		if str(e) != ("sub:" + nm):
			cleaned.append(e)
	mp["subs"] = subs
	mp["layout"] = cleaned
	d["main_periods"] = mps
	_normalize(d)
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


# ============ 写入：穿插 layout ============

func set_layout(mp_idx: int, layout: Array) -> void:
	var d := load_data()
	var mps: Array = d.get("main_periods", [])
	if mp_idx < 0 or mp_idx >= mps.size():
		return
	var mp: Dictionary = mps[mp_idx]
	var lay: Array = []
	for e in layout:
		var es := str(e)
		if es == "class":
			lay.append("class")
		elif es.begins_with("sub:"):
			var sname := es.substr(4)
			if not sname.is_empty():
				lay.append("sub:" + sname)
	if lay.is_empty():
		lay.append("class")
	if lay.size() > MAX_LAYOUT_ENTRIES:
		lay.resize(MAX_LAYOUT_ENTRIES)
	mp["layout"] = lay
	d["main_periods"] = mps
	_normalize(d)
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


func insert_layout_entry(mp_idx: int, pos: int, entry: String) -> void:
	var d := load_data()
	var mps: Array = d.get("main_periods", [])
	if mp_idx < 0 or mp_idx >= mps.size():
		return
	var mp: Dictionary = mps[mp_idx]
	var lay: Array = mp.get("layout", [])
	if lay.size() >= MAX_LAYOUT_ENTRIES:
		return
	var es := str(entry)
	if es != "class" and not es.begins_with("sub:"):
		return
	if es.begins_with("sub:"):
		var sname := es.substr(4)
		if sname.is_empty():
			return
		var subs: Dictionary = mp.get("subs", {})
		if not subs.has(sname):
			subs[sname] = _make_sub(sname, "10:00", "10:20", false)
			mp["subs"] = subs
	var p := int(pos)
	if p < 0:
		p = 0
	if p > lay.size():
		p = lay.size()
	lay.insert(p, es)
	mp["layout"] = lay
	d["main_periods"] = mps
	_normalize(d)
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


func remove_layout_entry(mp_idx: int, pos: int) -> void:
	var d := load_data()
	var mps: Array = d.get("main_periods", [])
	if mp_idx < 0 or mp_idx >= mps.size():
		return
	var mp: Dictionary = mps[mp_idx]
	var lay: Array = mp.get("layout", [])
	if pos < 0 or pos >= lay.size() or lay.size() <= 1:
		return
	lay.remove_at(pos)
	mp["layout"] = lay
	d["main_periods"] = mps
	_normalize(d)
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


func move_layout_entry(mp_idx: int, from: int, to: int) -> void:
	var d := load_data()
	var mps: Array = d.get("main_periods", [])
	if mp_idx < 0 or mp_idx >= mps.size():
		return
	var mp: Dictionary = mps[mp_idx]
	var lay: Array = mp.get("layout", [])
	if from < 0 or from >= lay.size() or to < 0 or to >= lay.size() or from == to:
		return
	var v: Variant = lay[from]
	lay.remove_at(from)
	lay.insert(to, v)
	mp["layout"] = lay
	d["main_periods"] = mps
	_normalize(d)
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


# ============ 写入：每节课时间 ============

## 设置某主时段内第 class_index 节课的时间。
func set_class_time(mp_idx: int, class_index: int, start: String, end: String) -> void:
	var d := load_data()
	var mps: Array = d.get("main_periods", [])
	if mp_idx < 0 or mp_idx >= mps.size():
		return
	var mp: Dictionary = mps[mp_idx]
	var times: Array = mp.get("class_times", [])
	if class_index < 0 or class_index >= times.size():
		return
	if not (times[class_index] is Dictionary):
		times[class_index] = {}
	(times[class_index] as Dictionary)["start"] = _norm_hhmm(start) if _valid_hhmm(start) else "08:00"
	(times[class_index] as Dictionary)["end"] = _norm_hhmm(end) if _valid_hhmm(end) else "08:45"
	mp["class_times"] = times
	d["main_periods"] = mps
	_normalize(d)
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


## 批量设置某主时段每节课时间：从 start_min 起，每节 dur 分钟、课间 gap 分钟。
func set_class_times_bulk(mp_idx: int, start_min: int, dur_min: int, gap_min: int) -> void:
	var d := load_data()
	var mps: Array = d.get("main_periods", [])
	if mp_idx < 0 or mp_idx >= mps.size():
		return
	var mp: Dictionary = mps[mp_idx]
	var n := class_count_of(mp_idx)
	if n <= 0:
		return
	var times: Array = []
	var cursor := int(start_min)
	for i in range(n):
		times.append(_dt(cursor, int(dur_min)))
		cursor += int(dur_min) + int(gap_min)
	mp["class_times"] = times
	d["main_periods"] = mps
	_normalize(d)
	_data = d
	_loaded = true
	persist()
	changed.emit(_data)


# ============ 持久化 ============

func persist() -> Error:
	var path := resolve_path()
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		var err := FileAccess.get_open_error()
		push_error("[CourseSchedule] 无法写入课程表: %s (err=%d)" % [path, err])
		return err
	f.store_string(JSON.stringify(_data, "  "))
	f.close()
	print("[CourseSchedule] 已写入课程表 -> " + path)
	return OK


func ensure_file() -> bool:
	var path := resolve_path()
	var need := true
	if FileAccess.file_exists(path):
		var txt := FileAccess.get_file_as_string(path)
		if not txt.strip_edges().is_empty():
			var parsed: Variant = JSON.parse_string(txt)
			if parsed is Dictionary:
				need = not _data_intact(parsed as Dictionary)
	if not need:
		return false
	_data = read_from_disk()
	_loaded = true
	persist()
	print("[CourseSchedule] 课程表文件缺失/残缺 → 已重建修复 -> " + path)
	return true


## 判据**保守**：semester_weeks/current_week 是数字、main_periods 是数组即认为完整。
static func _data_intact(d: Dictionary) -> bool:
	return d.has("semester_weeks") and _is_num(d["semester_weeks"]) \
		and d.has("current_week") and _is_num(d["current_week"]) \
		and d.has("main_periods") and (d["main_periods"] is Array)


## 数字判据（JSON 整型读回为 float，故不能只判 is int）
static func _is_num(v: Variant) -> bool:
	return (v is int) or (v is float)


# ============ 时间工具 ============

## "HH:MM" → 分钟数（非法返回 -1）
static func _parse_hhmm(s: String) -> int:
	var parts := s.split(":")
	if parts.size() != 2:
		return -1
	var h: int = int(parts[0])
	var m: int = int(parts[1])
	if h < 0 or h > 23 or m < 0 or m > 59:
		return -1
	return h * 60 + m


static func _hhmm(minutes: int) -> String:
	var mm: int = int(minutes)
	if mm < 0:
		mm = 0
	var h: int = int(mm / 60)
	var m: int = mm % 60
	return "%02d:%02d" % [h, m]


func _valid_hhmm(s: String) -> bool:
	return _parse_hhmm(str(s)) >= 0


func _norm_hhmm(s: String) -> String:
	var p := _parse_hhmm(str(s))
	if p < 0:
		return "08:00"
	return _hhmm(p)


# 当前数据（已确保加载）
func get_data() -> Dictionary:
	return load_data()


# 课程表文件绝对路径
func resolve_path() -> String:
	var p := "D:/Documents/HelloNyxel/Temp/course_schedule.json"
	if SaveManager != null and SaveManager.has_method("get_course_schedule_path"):
		p = str(SaveManager.get_course_schedule_path())
	return p
