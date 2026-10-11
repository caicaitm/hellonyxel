# autoload/calendar_notes.gd
# 日历系统的「备忘录 / 日记」存储——游戏内可写数据的唯一权威。
#
# 落盘：%文档%/HelloNyxel/Temp/calendar_notes.json
#
# ★ 数据模型：
#   · memo（备忘录）：每天**一条**文本（玩家主写；也预留外部系统写入接口）。
#       memo: { "2026-10-07": "今天记得…", ... }   —— 文本为空串表示「无备忘录」，对应键会被移除。
#   · diary（日记）：每天**一组条目**（玩家 / 事件链系统 / 其它系统都能追加）。
#       diary: { "2026-10-07": [ { "source": "player", "text": "…", "at": "…" }, ... ], ... }
#       每一条带 source 字段，标记是谁写的（"player" / "event_chain" / "system" / ...），
#       日记面板据此显示来源标签，事件链系统等参与编辑时一目了然。
#
# ★ 与 CalendarInfo（设备日历）的区别：本模块存的是**游戏内**数据（玩家与系统可写）；
#   设备日历是**只读**的外部真实日历，由 CalendarInfo 负责采集。两者在日历页并排展示。
#
# ★ 本脚本是 autoload 单例（名 CalendarNotes），故**不声明 class_name**（同名会撞）。
#   外部访问一律走方法（不依赖「实例访问常量」），与 PlayerProfile 同款约束。
extends Node

const NOTES_FILE := "calendar_notes.json"
const VERSION: int = 1

# 预定义的来源标签（事件链系统等外部写入者应当用这里声明的来源之一，便于面板着色/显示）
const SOURCE_PLAYER := "player"
const SOURCE_EVENT_CHAIN := "event_chain"
const SOURCE_SYSTEM := "system"

# 日记每条最多保留字数（防御性，避免单条无限增长）
const DIARY_TEXT_LIMIT := 4000
const MEMO_TEXT_LIMIT := 4000

# 数据变化（提交 / 重置 / 外部写入 / 重新读盘）—— 日历页据此实时刷新
signal changed(notes: Dictionary)

var _notes: Dictionary = {}
var _loaded: bool = false
var _diary_seq: int = 0   # 日记条目唯一序号（保证同一秒写入多条也能靠 id 区分）


# 惰性加载：不在 _ready 里读盘（SaveManager 就绪顺序 + 启动零开销）
func load_notes() -> Dictionary:
	if not _loaded:
		_notes = read_from_disk()
		_loaded = true
	return _notes


# 从磁盘读一份（纯读，不动缓存；面板也用这个）
func read_from_disk() -> Dictionary:
	var out := empty_notes()
	var path := resolve_path()
	if not FileAccess.file_exists(path):
		return out
	var txt := FileAccess.get_file_as_string(path)
	if txt.strip_edges().is_empty():
		return out
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		push_warning("[CalendarNotes] 笔记 JSON 无法解析为对象: " + path)
		return out
	var d: Dictionary = parsed
	if d.has("memo") and (d["memo"] is Dictionary):
		out["memo"] = d["memo"]
	if d.has("diary") and (d["diary"] is Dictionary):
		out["diary"] = d["diary"]
	out["version"] = VERSION
	# 合法性兜底：memo 必须 dict，diary 必须 dict of Array
	if not (out["memo"] is Dictionary):
		out["memo"] = {}
	if not (out["diary"] is Dictionary):
		out["diary"] = {}
	for k in out["diary"].keys():
		if not (out["diary"][k] is Array):
			out["diary"][k] = []
	return out


# 重新读盘并广播（面板「刷新」/ 外部系统用）
func reload() -> Dictionary:
	_notes = read_from_disk()
	_loaded = true
	changed.emit(_notes)
	return _notes


# ============ 备忘录（memo）============
# 每天一条文本。玩家主写；外部系统也可 set_memo 写入（覆盖当天旧值，语义同「更新当天备忘录」）。

## 取某天备忘录（无 → 空串）
func get_memo(date: String) -> String:
	var d := normalize_date(date)
	var m: Variant = load_notes().get("memo", {})
	if m is Dictionary and (m as Dictionary).has(d):
		return str((m as Dictionary)[d])
	return ""


## 某天是否写了备忘录
func day_has_memo(date: String) -> bool:
	return not get_memo(date).is_empty()


## 写/改某天备忘录。text 为空 → 移除该天备忘录。source 标记写入者（默认 player）。
func set_memo(date: String, text: String, source: String = SOURCE_PLAYER) -> void:
	var d := normalize_date(date)
	var n := load_notes()
	var m: Dictionary = n.get("memo", {})
	if not (m is Dictionary):
		m = {}
	var t := str(text).strip_edges().substr(0, MEMO_TEXT_LIMIT)
	if t.is_empty():
		m.erase(d)
	else:
		m[d] = t
	n["memo"] = m
	n["updated_at"] = Time.get_datetime_string_from_system(false, true)
	_notes = n
	_loaded = true
	persist()
	changed.emit(_notes)


# ============ 日记（diary）============
# 每天一组条目。玩家与事件链系统等都能追加（append_diary），每条带 source 标签。

## 取某天日记条目列表（Array[Dictionary]；无 → 空数组）
func get_diary(date: String) -> Array:
	var d := normalize_date(date)
	var dy: Variant = load_notes().get("diary", {})
	if dy is Dictionary and (dy as Dictionary).has(d):
		var v: Variant = (dy as Dictionary)[d]
		if v is Array:
			return v
	return []


## 某天是否写了日记
func day_has_diary(date: String) -> bool:
	return get_diary(date).size() > 0


## 追加一条日记（玩家或外部系统）。返回写入的条目 dict。
## source 缺省 player；事件链系统应传 SOURCE_EVENT_CHAIN / 自定义来源标签。
## 每条带唯一 id（at + 序号），移除/比对时按 id 而非 at（避免同一秒写入多条互相误删）。
func append_diary(date: String, text: String, source: String = SOURCE_PLAYER) -> Dictionary:
	var d := normalize_date(date)
	var body := str(text).strip_edges().substr(0, DIARY_TEXT_LIMIT)
	var at := Time.get_datetime_string_from_system(false, true)
	_diary_seq += 1
	var entry := {
		"id": "%s_%d" % [at, _diary_seq],
		"source": str(source).strip_edges() if not str(source).strip_edges().is_empty() else SOURCE_PLAYER,
		"text": body,
		"at": at,
	}
	if body.is_empty():
		# 空文本不入档（防御：事件链系统误调也不留垃圾）
		return entry
	var n := load_notes()
	var dy: Dictionary = n.get("diary", {})
	if not (dy is Dictionary):
		dy = {}
	var lst: Array = dy.get(d, [])
	if not (lst is Array):
		lst = []
	lst.append(entry)
	dy[d] = lst
	n["diary"] = dy
	n["updated_at"] = at
	_notes = n
	_loaded = true
	persist()
	changed.emit(_notes)
	return entry


## 删除某天日记里 id 匹配的那一条（玩家编辑用；按唯一 id 定位，避免同一秒写入互相误删）。
## 返回是否真删到。
func remove_diary_entry(date: String, id: String) -> bool:
	var d := normalize_date(date)
	var n := load_notes()
	var dy: Dictionary = n.get("diary", {})
	if not (dy is Dictionary) or not dy.has(d):
		return false
	var lst: Array = dy[d]
	if not (lst is Array):
		return false
	var removed := false
	var kept: Array = []
	for e in lst:
		if e is Dictionary and str((e as Dictionary).get("id", "")) == str(id):
			removed = true
			continue
		kept.append(e)
	dy[d] = kept
	if kept.is_empty():
		dy.erase(d)
	n["diary"] = dy
	_notes = n
	_loaded = true
	persist()
	changed.emit(_notes)
	return removed


# ============ 持久化 ============

func persist() -> Error:
	var path := resolve_path()
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		var err := FileAccess.get_open_error()
		push_error("[CalendarNotes] 无法写入笔记: %s (err=%d)" % [path, err])
		return err
	f.store_string(JSON.stringify(_notes, "  "))
	f.close()
	print("[CalendarNotes] 已写入笔记 -> " + path)
	return OK


# ---- 自检：文件残缺 → 按默认值重建 -------------------------------------------
# ★ 由 SaveManager.ensure_temp_files() 在「进入游戏前 / 载入存档前」调用。
# 「残缺」= 文件不存在 / 文本为空 / 无法解析为对象 / memo 或 diary 不是字典。
# 修复时**不丢已有合法字段**（read_from_disk() 已逐键过滤 + 类型兜底）。
# 返回是否真的写盘（true = 补建或修复过）。
func ensure_file() -> bool:
	var path := resolve_path()
	var need := true
	if FileAccess.file_exists(path):
		var txt := FileAccess.get_file_as_string(path)
		if not txt.strip_edges().is_empty():
			var parsed: Variant = JSON.parse_string(txt)
			if parsed is Dictionary:
				need = not _notes_intact(parsed as Dictionary)
	if not need:
		return false
	_notes = read_from_disk()
	_loaded = true
	persist()
	print("[CalendarNotes] 笔记文件残缺 → 已按默认值重建 -> " + path)
	return true


# memo 与 diary 必须都是字典（缺任一即视为残缺）
static func _notes_intact(d: Dictionary) -> bool:
	return d.has("memo") and (d["memo"] is Dictionary) and d.has("diary") and (d["diary"] is Dictionary)


# ============ 工具 ============

## 把任意输入规整成 "yyyy-MM-dd"。长度不够/非法 → 原样返回（调用方按原串兜底）。
static func normalize_date(s: String) -> String:
	var v := str(s).strip_edges()
	if v.length() >= 10:
		return v.substr(0, 10)
	return v


## 来源是否预定义（面板据此给未登记来源一个「其它」样式）
func is_known_source(src: String) -> bool:
	return src == SOURCE_PLAYER or src == SOURCE_EVENT_CHAIN or src == SOURCE_SYSTEM


## 当前数据（缓存；已确保加载过）
func get_notes() -> Dictionary:
	return load_notes()


func empty_notes() -> Dictionary:
	return {
		"version": VERSION,
		"memo": {},
		"diary": {},
		"updated_at": "",
	}


# 笔记文件绝对路径（= %文档%/HelloNyxel/Temp/calendar_notes.json）
# ★ SaveManager.get_calendar_notes_path() 返回的就是**完整文件路径**（已含文件名），
#   不要再用 NOTES_FILE 拼一次，否则会变成 calendar_notes.json/calendar_notes.json（落盘失败）。
func resolve_path() -> String:
	var p := "D:/Documents/HelloNyxel/Temp/calendar_notes.json"
	if SaveManager != null and SaveManager.has_method("get_calendar_notes_path"):
		p = str(SaveManager.get_calendar_notes_path())
	return p
