# dialogue_log.gd
# 台词记录单例（autoload）。
#
# 记录「事件链行进时」各对话栏的更新（底部台词 / 弹窗事件内容）以及玩家按下的按钮。
# 每条记录：{ t: unix秒, type: "line"|"button", panel: "bottom"|"popup", text: String, id: String }。
# 记录按时间升序；查看页 DialogueLogPanel 每页 100 条（PER_PAGE），超出翻页。
# 持久化到 Temp/dialogue_log.json（与背包 inventory.json 同目录）。
#
# ★★ 不要在此声明 class_name：DialogueLog 已是 autoload 单例名，
#   若再声明同名 class_name，GDScript 会把裸名解析成「类类型」而非单例实例
#   （与 DialogueManager 同坑，见 dialogue_manager.gd 顶部注释）。
extends Node

const LOG_FILE := "dialogue_log.json"
const PER_PAGE := 100
const MAX_ENTRIES := 10000   # 防止文件无限膨胀，超出丢弃最旧

signal changed()   # 新增记录 / 加载完成后触发，查看页据此刷新

var _entries: Array = []     # 升序（最旧在前）
var _path: String = ""
var _dirty := false
var _save_timer: Timer = null


func _ready() -> void:
	_path = SaveManager.get_temp_dir().path_join(LOG_FILE)
	_load()
	_save_timer = Timer.new()
	_save_timer.name = "SaveTimer"
	_save_timer.wait_time = 0.5
	_save_timer.one_shot = true
	_save_timer.timeout.connect(_flush)
	add_child(_save_timer)
	changed.emit()   # 加载完成，通知查看页刷新（若已打开）


func _load() -> void:
	_entries = []
	if not FileAccess.file_exists(_path):
		return
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	if txt.strip_edges().is_empty():
		return
	var parsed = JSON.parse_string(txt)
	if parsed is Array:
		_entries = parsed


func _schedule_save() -> void:
	_dirty = true
	if _save_timer != null and is_instance_valid(_save_timer):
		_save_timer.start()   # 重置计时：多次记录合并为一次写盘


func _flush() -> void:
	if not _dirty:
		return
	_dirty = false
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		push_warning("[DialogueLog] 无法写入 " + _path)
		return
	f.store_string(JSON.stringify(_entries))
	f.close()


# ---------------- 记录 ----------------

# 记录一句台词（panel: "bottom" / "popup"，text 已是去修饰的纯文本）
func record_line(panel: String, text: String) -> void:
	text = text.strip_edges()
	if text.is_empty():
		return
	# 连续去重：与最后一条「同面板同类型同文本」合并，避免语言切换 / _refresh_all 重复刷
	var n := _entries.size()
	if n > 0:
		var last: Dictionary = _entries[n - 1]
		if last.get("type", "") == "line" and last.get("panel", "") == panel and last.get("text", "") == text:
			return
	_append("line", panel, text, "")


# 记录一次按钮按下（panel: "bottom"/"popup"，id 按钮 id，label 按钮显示文本）
func record_button(panel: String, id: String, label: String) -> void:
	label = label.strip_edges()
	if label.is_empty():
		label = id
	_append("button", panel, label, id)


func _append(type: String, panel: String, text: String, id: String) -> void:
	_entries.append({
		"t": Time.get_unix_time_from_system(),
		"type": type,
		"panel": panel,
		"text": text,
		"id": id,
	})
	while _entries.size() > MAX_ENTRIES:
		_entries.remove_at(0)
	_schedule_save()
	changed.emit()


# ---------------- 查询 / 分页 ----------------

func total() -> int:
	return _entries.size()


func page_count(per_page: int = PER_PAGE) -> int:
	if _entries.is_empty():
		return 1
	return ceili(float(_entries.size()) / float(per_page))


# 返回某一页记录（升序）；page 从 1 开始，超出范围夹取
func get_page(page: int, per_page: int = PER_PAGE) -> Array:
	var pc := page_count(per_page)
	page = clampi(page, 1, pc)
	var start := (page - 1) * per_page
	var end := mini(start + per_page, _entries.size())
	var out: Array = []
	for i in range(start, end):
		out.append(_entries[i])
	return out


# 最后一页页码（查看页默认打开到此）
func last_page(per_page: int = PER_PAGE) -> int:
	return page_count(per_page)


# 清空全部记录（写盘 + 通知）
func clear() -> void:
	_entries = []
	_dirty = true
	_schedule_save()
	changed.emit()
