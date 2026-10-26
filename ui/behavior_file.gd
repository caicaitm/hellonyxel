# ui/behavior_file.gd
# 行为脚本 · 数据模型与落盘（仿 ui/event_file.gd，纯静态工具）。
#
# 目录约定（res://behaviors = 与 res://events 同级的「行为脚本」根目录，英文名）：
#   res://behaviors/<脚本名>.json       一个行为脚本（顺序 = 优先级）
#
# 脚本结构：
#   { "version": 1, "name": "<脚本名>", "behaviors": [ "<行为规格>", ... ] }
#   behaviors 里的元素与 Block.behaviors 同格式（预设关键字 或 script:<其它脚本名>）。
#
# 原则：json 只写「逻辑名」（不含扩展名）；运行时按名组出 <名>.json。
class_name BehaviorFile
extends RefCounted

const ROOT := "res://behaviors"
const JSON_EXT := ".json"


# ---------------- 路径 / 目录 ----------------

static func script_path(name: String) -> String:
	return ROOT.path_join(name + JSON_EXT)


static func script_exists(name: String) -> bool:
	return not name.is_empty() and FileAccess.file_exists(script_path(name))


## 若根目录不存在则递归创建（首次写脚本时调用）。
static func ensure_root() -> void:
	if not DirAccess.dir_exists_absolute(ROOT):
		DirAccess.make_dir_recursive_absolute(ROOT)


# ---------------- 枚举（编辑器下拉 / 列表用）----------------

## 列出所有行为脚本名（res://behaviors 下的 *.json 去扩展名，跳过隐藏文件），按名称排序；
## 目录不存在 / 无文件 → 空数组。
static func list_scripts() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(ROOT)
	if dir == null:
		return out
	for f in dir.get_files():
		if not f.ends_with(JSON_EXT) or f.begins_with("."):
			continue
		out.append(f.substr(0, f.length() - JSON_EXT.length()))
	out.sort()
	return out


# ---------------- 读写 ----------------

## 读行为脚本：返回 Dictionary { "version", "name", "behaviors": Array }；
## 文件不存在 / 解析失败 / 非字典 → null。
static func read_script(name: String) -> Variant:
	if name.is_empty():
		return null
	var p := script_path(name)
	if not FileAccess.file_exists(p):
		return null
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return null
	var txt := f.get_as_text()
	f.close()
	var parser := JSON.new()
	if parser.parse(txt) != OK:
		return null
	if typeof(parser.data) != TYPE_DICTIONARY:
		return null
	return parser.data


## 读行为脚本的 behaviors 列表（PackedStringArray）；脚本不存在 / 缺键 → 空数组。
static func read_behaviors(name: String) -> PackedStringArray:
	var d: Variant = read_script(name)
	if d == null or not (d is Dictionary):
		return PackedStringArray()
	var arr: Variant = d.get("behaviors", [])
	if arr is Array:
		var out: PackedStringArray = []
		for e in arr:
			var s := str(e).strip_edges()
			if not s.is_empty():
				out.append(s)
		return out
	return PackedStringArray()


## 写（覆盖）行为脚本：behaviors 为行为规格列表（顺序 = 优先级）；
## 返回 OK 或错误码。
static func write_script(name: String, behaviors: PackedStringArray) -> Error:
	if name.is_empty():
		return ERR_INVALID_PARAMETER
	ensure_root()
	var data := { "version": 1, "name": name, "behaviors": Array(behaviors) }
	var bytes := (JSON.stringify(data, "\t") + "\n").to_utf8_buffer()
	var f := FileAccess.open(script_path(name), FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(bytes)
	f.close()
	return OK


## 删除行为脚本；不存在 → ERR_DOES_NOT_EXIST。
static func delete_script(name: String) -> Error:
	if name.is_empty():
		return ERR_INVALID_PARAMETER
	var p := script_path(name)
	if not FileAccess.file_exists(p):
		return ERR_DOES_NOT_EXIST
	return DirAccess.remove_absolute(p)
