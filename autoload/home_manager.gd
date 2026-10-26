# autoload/home_manager.gd
# 「家园」数据的注册与加载单例（autoload 名：HomeManager）。
#
# ★ 与「关卡（LevelManager）」的关系：二者 UI 投影层几乎一致（HomePage 镜像 LevelPage），
#   但**持久化后端不同**——这正是用户需求的差异点：
#     · 关卡积木落盘在 res://levels/<名>.json（与存档无关，换存档不丢、不随存档走）；
#     · 家园积木必须随**存档**保存 —— 写到 Saves/<存档名>/home.json，
#       由 SaveManager 在 save / load_save 时统一 hook（见 save_manager.gd）。
#
# 家园是**单一场景**（没有「多关卡名 / 载入下拉」的概念），全局只有一个 home_page。
#
# 职责（只做"数据 + 实例化 + 落盘"，UI 与投影定位归 HomePage 管）：
#   - 缓存当前家园布局 home_data（HomePage 投影/编辑时写回、SaveManager 落盘时读出）
#   - 把家园布局实例化成积木（委托 LevelManager.instantiate_blocks，家园与关卡积木同款）
#   - 把家园布局写进存档目录 / 从存档目录读出
#
# ★ 不写 class_name：与 LevelManager / SaveManager 一致，只靠 project.godot 的 autoload 名引用。
extends Node

const HOME_FILE := "home.json"

# 家园面板（投影目标）。由 desktop 创建 HomePage 后登记到这里，控制台 /open_home 据此定位。
var home_page: Node = null

# 当前家园布局缓存。HomePage.serialize_home() 写入；save_to_disk 写出；load_from_disk 读出。
var home_data: Dictionary = {}

## 家园默认积木（空积木）的展示样式：与关卡同款（显边框 + 纯色填充 + 碰撞 + 可选中）。
const DEFAULT_TAGS: PackedStringArray = [&"show", &"border", &"fill", &"collision", &"selectable"]


func _ready() -> void:
	print("[HomeManager] 就绪 家园文件=%s" % HOME_FILE)


## 缓存当前家园布局（HomePage 投影/编辑时调用；落盘前也可直接喂最新数据）。
func store_layout(data: Dictionary) -> void:
	home_data = data.duplicate(true) if data else {}


## 取出当前缓存的家园布局（HomePage 在打开/投影时调用）。
func get_layout() -> Dictionary:
	return home_data


## 委托 LevelManager 实例化积木（家园与关卡积木同款，复用同一套默认标签/字符串 ID 注册逻辑）。
func instantiate_blocks(data: Dictionary, parent: Node, offset: Vector2 = Vector2.ZERO) -> Array[Block]:
	if LevelManager != null and LevelManager.has_method("instantiate_blocks"):
		return LevelManager.instantiate_blocks(data, parent, offset)
	push_warning("[HomeManager] LevelManager 不可用，无法实例化家园积木")
	return []


## 把当前家园布局写到存档目录 folder 下的 home.json。
## ★ 优先取 home_page 实时数据（玩家可能正开着家园编辑）；否则用缓存 home_data。
## ★ 即使家园为空也写一份骨架（保证存档目录里有 home.json，可被后续读取且不报错）。
func save_to_disk(folder: String) -> Error:
	var data := home_data
	if home_page != null and home_page.has_method("serialize_home"):
		data = home_page.serialize_home()
	if typeof(data) != TYPE_DICTIONARY or data.is_empty():
		data = { "name": "home", "blocks": [] }
	data["name"] = "home"
	if not (data.get("blocks") is Array):
		data["blocks"] = []
	var path := folder.path_join(HOME_FILE)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[HomeManager] 无法写入家园文件：%s（err=%d）" % [path, FileAccess.get_open_error()])
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(data, "\t") + "\n")
	f.close()
	print("[HomeManager] 已写入家园布局 → %s（积木 %d 块）" % [path, (data["blocks"] as Array).size()])
	return OK


## 从存档目录 folder 下读 home.json 到 home_data 缓存。
## ★ 若 home_page 已可见（玩家开着家园），立刻投影出来（按最新存档重建积木）。
func load_from_disk(folder: String) -> Error:
	var path := folder.path_join(HOME_FILE)
	if not FileAccess.file_exists(path):
		home_data = { "name": "home", "blocks": [] }
		print("[HomeManager] 存档目录无 home.json，家园置空：%s" % folder)
		return OK
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("[HomeManager] 无法读取家园文件：%s（err=%d）" % [path, FileAccess.get_open_error()])
		return FileAccess.get_open_error()
	var txt := f.get_as_text()
	f.close()
	var p := JSON.new()
	if p.parse(txt) != OK:
		push_warning("[HomeManager] 家园 JSON 解析失败（%s）：%s" % [path, p.get_error_message()])
		return ERR_PARSE_ERROR
	if not (p.data is Dictionary):
		push_warning("[HomeManager] 家园 JSON 顶层应为对象：%s" % path)
		return ERR_INVALID_DATA
	home_data = p.data
	home_data["name"] = "home"
	print("[HomeManager] 已读取家园布局 ← %s（积木 %d 块）"
		% [path, (home_data.get("blocks", []) as Array).size()])
	if home_page != null and home_page.has_method("project_home") and home_page.is_visible_in_tree():
		home_page.project_home()
	return OK
