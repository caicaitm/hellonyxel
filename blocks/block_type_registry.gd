# block_type_registry.gd
# 自动加载单例：积木“类型”的注册与复用。
# 注册方式见 project.godot：[autoload] BlockTypes="*res://blocks/block_type_registry.gd"
# 注意：本脚本作为 autoload 单例，全局名已是 "BlockTypes"，故不再声明 class_name（避免重名）。
extends Node

# 积木类型 JSON 目录：与 events 同级（res://events 的同级目录）。
# 每种类型一个 .json 文件，方便版本管理、按种类单独编辑，以及 MOD / DLC / 本体 三类保存位置区分。
const DIR: String = "res://block_types"

# 每个类型 JSON 里标记「保存位置」的字段名。
const SAVE_LOC_KEY: String = "save_location"
# 保存位置取值
const LOC_MOD := "MOD"
const LOC_DLC := "DLC"
const LOC_BASE := "本体"

# 「空白积木」类型名：右键空白处「新建积木(空白)」与 /create_block（不给 block_type）
# 都走这里，属性完全由 res://block_types/Blank.json 决定 —— 改这个 JSON，新建的空白积木就不同。
# 仅在 Blank.json 缺失时回退到内存默认模板（见 _ready）。
const BLANK_TYPE := "Blank"
# 不出现在「我的积木类型」菜单里的内部模板类型（ Blank 是内部模板，用户入口是「新建积木(空白)」）
const HIDDEN_TYPES: PackedStringArray = ["Blank"]

# 内置类型的「内存默认模板」工厂表：name -> Callable() -> Dictionary。
# 仅在该类型没有 JSON 文件（用户从未保存过）时作为回退；绝不落盘，也绝不覆盖用户已编辑的 JSON。
var _builtin_factories: Dictionary = {}
# 内置类型的「创建时强制覆盖字段」：name -> Dictionary（如几何尺寸）。
# 即便 JSON 里改了这些字段，创建积木时也以代码为准（符合「除尺寸/位置外，其余属性全部靠 JSON」）。
var _builtin_overrides: Dictionary = {}


func _ready() -> void:
	# ★ 启动期不做任何文件读写：
	#   · 类型 JSON 仅在「创建指定类型积木」时按需读取（见 get_def / create_block）；
	#   · 类型 JSON 仅在「保存积木种类」时写盘（见 register）；
	#   · 内置类型仅在此登记内存默认模板（供缺 JSON 时回退），不触碰磁盘。
	# 「空白积木」的内置默认模板（Blank.json 缺失时的回退；JSON 存在时以 JSON 为准）。
	ensure_builtin_type(BLANK_TYPE, BlockProperty.default_for_new())


## 类型名 → 安全的文件名（保留原名，仅做最小净化，避免路径穿越）
func _file_for(name: String) -> String:
	var safe := name.replace("/", "_").replace("\\", "_").replace(":", "_").strip_edges()
	if safe.is_empty():
		safe = "type"
	return DIR + "/" + safe + ".json"


## 确保目录存在（Godot 4 的 DirAccess.make_dir_recursive 为实例方法，需先 open 父目录）
static func _ensure_dir() -> void:
	var d := DirAccess.open("res://")
	if d != null:
		d.make_dir_recursive("block_types")


## 目录是否存在
static func _dir_exists(path: String) -> bool:
	return DirAccess.open(path) != null


## 列出目录里所有 .json（不论保存位置）
func _list_files() -> PackedStringArray:
	var out: PackedStringArray = []
	if not _dir_exists(DIR):
		return out
	var dir := DirAccess.open(DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".json"):
			out.append(DIR + "/" + f)
		f = dir.get_next()
	dir.list_dir_end()
	return out


## 注册「内置类型」的默认模板（纯内存，绝不写盘）。
##   - default_def：该类型在没有 JSON 文件时的回退定义（脚本里写死的默认）。
##   - overrides：创建该类型积木时永远强制覆盖的字段（如几何尺寸 width/height），
##     即便 JSON 里被改也不生效（尺寸/位置由代码在创建时按实时数据计算）。
## 注意：本函数不再「确保 JSON 文件存在 / 不存在则写默认」。文件只由 register() 在用户显式保存时创建。
func ensure_builtin_type(name: String, default_def: Dictionary, overrides: Dictionary = {}) -> void:
	var d := default_def.duplicate(true)
	for k in overrides:
		d[k] = overrides[k]
	_builtin_factories[name] = func() -> Dictionary: return d.duplicate(true)
	_builtin_overrides[name] = overrides.duplicate(true)


## 取类型定义（不存在返回空字典）。
## 读取时机 == 创建该类型积木时（create_block / get_def 的所有调用点）；本函数绝不写盘。
## 优先级：磁盘 JSON（本体）→ 内置默认模板（内存）→ 空。
func get_def(name: String) -> Dictionary:
	var path := _file_for(name)
	if FileAccess.file_exists(path):
		var parsed = _read_json(path)
		if parsed is Dictionary and parsed.has("name"):
			if str(parsed.get(SAVE_LOC_KEY, LOC_BASE)) != LOC_BASE:
				# MOD / DLC 类型仅落盘占位，本阶段不生效、不可用于创建积木
				return {}
			return _apply_builtin_overrides(name, parsed)
		# 文件存在但解析损坏：绝不静默写回默认（那会吞掉用户的手工编辑），
		# 仅告警并回退到内置默认；磁盘原文件保持不动，等用户修复。
		push_warning("BlockTypes: 类型 '%s' 的 JSON 损坏，回退到内置默认（未改写磁盘文件，请检查）" % name)
	if _builtin_factories.has(name):
		return _builtin_factories[name].call()
	return {}


## 对内置类型，创建时把代码强制字段（几何尺寸等）覆盖到读取到的 def 上。
func _apply_builtin_overrides(name: String, def: Dictionary) -> Dictionary:
	if not _builtin_overrides.has(name) or _builtin_overrides[name].is_empty():
		return def
	var out := def.duplicate(true)
	for k in _builtin_overrides[name]:
		out[k] = _builtin_overrides[name][k]
	return out


func has(name: String) -> bool:
	if _builtin_factories.has(name):
		return true
	var path := _file_for(name)
	if FileAccess.file_exists(path):
		var parsed = _read_json(path)
		if parsed is Dictionary and parsed.has("name"):
			return str(parsed.get(SAVE_LOC_KEY, LOC_BASE)) == LOC_BASE
	return false


## 注册 / 覆盖一个积木类型，持久化为独立 JSON 文件（唯一写盘点）。
##   - def 必须含足够字段；函数会强制写入 "name"。
##   - def 可含 SAVE_LOC_KEY（"MOD"/"DLC"/"本体"）；缺省按 MOD 处理（仅落盘占位，不生效）。
##   - 同名 = 覆盖（直接写同一个文件）。
func register(name: String, def: Dictionary) -> void:
	_ensure_dir()
	var d := def.duplicate(true)
	d["name"] = name
	if not d.has(SAVE_LOC_KEY) or str(d[SAVE_LOC_KEY]).is_empty():
		d[SAVE_LOC_KEY] = LOC_MOD
	_write_json(_file_for(name), d)


## 删除一个类型（同时删磁盘 JSON；内存表不缓存，无需清理）
func remove(name: String) -> void:
	var p := _file_for(name)
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


## 列出所有「可创建（本体）」类型名：内置工厂 + 磁盘上本体 JSON。
## 仅在用户主动打开「我的积木类型」菜单时调用（读操作，非启动期）。
func list_names() -> PackedStringArray:
	var out: PackedStringArray = []
	for k in _builtin_factories.keys():
		if k in HIDDEN_TYPES or out.has(k):
			continue
		out.append(k)
	for path in _list_files():
		var parsed = _read_json(path)
		if parsed is Dictionary and parsed.has("name"):
			if str(parsed.get(SAVE_LOC_KEY, LOC_BASE)) == LOC_BASE:
				var n := str(parsed["name"])
				if (n in HIDDEN_TYPES) or out.has(n):
					continue
				out.append(n)
	return out


## 按类型名生成一个配置好的 Block 实例（不自动加入场景，调用方负责 add_child 与定位）
func create_block(name: String) -> Block:
	var def: Dictionary = get_def(name)
	if def.is_empty():
		push_warning("BlockTypes: 未找到类型 '%s'（仅「本体」保存位置的类型会生效）" % name)
		return null
	var b := Block.new()
	BlockProperty.apply_to_block(b, def)
	return b


## 创建一块「空白积木」（右键空白处「新建积木(空白)」与 /create_block 不给 block_type 时共用）。
## ★ 属性全部来自 res://block_types/Blank.json —— 改这个 JSON，之后新建的空白积木就跟着变。
## 仅在 Blank.json 缺失时回退到内置默认模板；执行前无需入树（位置由调用方指定）。
func create_blank_block() -> Block:
	return create_block(BLANK_TYPE)


func _write_json(path: String, d: Dictionary) -> void:
	_ensure_dir()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("BlockTypes: 无法写入 " + path)
		return
	f.store_string(JSON.stringify(d, "\t"))
	f.close()


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var txt := f.get_as_text()
	f.close()
	return JSON.parse_string(txt)
