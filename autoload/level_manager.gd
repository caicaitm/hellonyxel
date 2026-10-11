# autoload/level_manager.gd
# 「关卡」数据的注册与加载单例（autoload 名：LevelManager）。
#
# 职责（只做"数据 + 实例化 + 落盘"，UI 与投影定位归 LevelPage 管）：
#   - 枚举 levels/ 目录下的关卡 JSON（**文件名即关卡名**，如 测试1.json → "测试1"）
#   - 解析关卡 JSON（{ name, brief, blocks:[ {x,y,width,height,...} ] }）
#   - 把关卡描述实例化成积木（Block）挂到指定父节点下 —— 关卡积木与桌面积木同款，
#     因此桌面的交互逻辑（拖动 / 碰撞 / 受控 / 双击按钮…）在关卡里同样适用。
#
# ★★ 关卡名 = 文件名（去掉 .json），这是**唯一权威来源**：
#   · JSON 里的 "name" 只是冗余记录，读写都以文件名为准（load_level 一律改写它、
#     save_level 一律强制它等于文件名）；
#   · 查找关卡**只认文件名**，不再按 JSON 里的 name 反查 —— 旧实现允许"输入显示名反查文件"，
#     于是两个文件写同一个 name 时会互相抢占（重复 + 错配的根源），现已彻底去掉；
#   · 启动时 normalize_names() 把存量文件里写错的 name 就地修正（只改那一行的值，保留排版）；
#   · 重命名保存（save_level 传 old_name）会删掉旧文件，不会留下一份重复内容。
#
# 关卡目录与 events/ 同级：res://levels/（见任务约定「关卡场景存放在和 events 同级的一个目录下」）。
# 关卡使用 JSON 保存而非 Godot 的 .tscn。坐标是"关卡本地坐标"（围绕一组积木的视觉中心），
# 具体投影到大世界上哪个位置由 LevelPage 决定。
extends Node

const LEVELS_DIR := "res://levels"
const LEVEL_EXT := ".json"

# 关卡名要当文件名用 → 禁止 Windows 非法字符（跨平台安全）。
const ILLEGAL_NAME_CHARS: PackedStringArray = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]

# 关卡面板（投影目标）。由 desktop 创建 LevelPage 后登记到这里，控制台 /load_level 据此定位。
var level_page: Node = null

## 关卡默认积木（空积木）的展示样式：显边框 + 纯色填充 + 参与碰撞，无文字/图片/重力/受控。
## ★ 含 selectable（可被选中）：关卡积木是**玩家能操作的内容**，不带它就用不了框选/单选
##   （选中与否的唯一闸门就是 selectable 标签，见 blocks/block_tags.gd）。instantiate_blocks
##   还会对 JSON 自定义标签的积木强制补上它。
const DEFAULT_TAGS: PackedStringArray = [&"show", &"border", &"fill", &"collision", &"selectable"]


func _ready() -> void:
	var fixed := normalize_names()
	print("[LevelManager] 就绪 关卡目录=%s 关卡=%s%s" % [
		LEVELS_DIR, str(list_level_names()),
		"" if fixed == 0 else "（已把 %d 个文件里的 name 对齐成文件名）" % fixed])


## ★ 关卡名规范化 = 文件名（去掉 .json、去掉首尾空白）。唯一权威的"关卡名"标准。
##   传进来带不带 .json 都接受；其余字符原样保留（中文关卡名照常可用）。
func canonical_name(name: String) -> String:
	var n := name.strip_edges()
	if n.to_lower().ends_with(LEVEL_EXT):
		n = n.substr(0, n.length() - LEVEL_EXT.length())
	return n.strip_edges()


## 关卡文件路径（始终 = levels/<关卡名>.json）。名字为空返回 ""；
## 文件不存在时也返回**预期路径**，供「是否覆盖」这类判断使用。
func level_path(name: String) -> String:
	var n := canonical_name(name)
	if n.is_empty():
		return ""
	return LEVELS_DIR.path_join(n + LEVEL_EXT)


## 关卡名能否当文件名用（非空、不含路径分隔符与通配符、不是 . / ..）。
func is_valid_level_name(name: String) -> bool:
	var n := canonical_name(name)
	if n.is_empty() or n == "." or n == "..":
		return false
	for ch in ILLEGAL_NAME_CHARS:
		if n.contains(ch):
			return false
	return true


## levels/ 下全部关卡名（文件名去掉 .json，升序）
func list_level_names() -> Array[String]:
	var dir := DirAccess.open(LEVELS_DIR)
	if dir == null:
		return []
	var out: Array[String] = []
	for f in dir.get_files():
		if f.ends_with(LEVEL_EXT):
			out.append(f.substr(0, f.length() - LEVEL_EXT.length()))
	out.sort()
	return out


## 关卡是否存在（接受带/不带 .json 的名称）
func has_level(name: String) -> bool:
	return not _path_for(name).is_empty()


## 加载关卡 JSON。失败返回空 Dictionary；成功返回 { name, brief?, layout?, blocks: Array }
func load_level(name: String) -> Dictionary:
	var path := _path_for(name)
	if path.is_empty():
		push_warning("[LevelManager] 未找到关卡「%s」（可用：%s）" % [name, str(list_level_names())])
		return {}
	if not FileAccess.file_exists(path):
		push_warning("[LevelManager] 关卡文件不存在：%s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("[LevelManager] 无法打开关卡文件：%s" % path)
		return {}
	var txt := f.get_as_text()
	f.close()
	var p := JSON.new()
	if p.parse(txt) != OK:
		push_warning("[LevelManager] 关卡 JSON 解析失败（%s）：%s" % [path, p.get_error_message()])
		return {}
	if not (p.data is Dictionary):
		push_warning("[LevelManager] 关卡 JSON 顶层应为对象：%s" % path)
		return {}
	var data: Dictionary = p.data
	if not data.has("blocks"):
		push_warning("[LevelManager] 关卡 JSON 缺少 blocks 数组：%s" % path)
	# ★ 关卡名一律取**文件名**（JSON 里的 name 只是冗余记录）：
	#   这样"文件名 ≠ 关卡名"在数据层就不可能成立，连带杜绝了按 name 反查时的互相抢占。
	var stem := path.get_file().get_basename()
	var declared := str(data.get("name", "")).strip_edges()
	if not declared.is_empty() and declared != stem:
		push_warning("[LevelManager] 关卡「%s」文件内 name=「%s」与文件名不符，已以文件名为准（保存后自动修正）" % [stem, declared])
	data["name"] = stem
	return data


## 把关卡写回 levels/<关卡名>.json。返回 OK 或错误码。
## ★ 文件名即关卡名：写入前**强制** data["name"] = 文件名。
## ★ 不删任何文件：换名字保存 = 「另存为新关卡」，原关卡仍然存在（关卡身份就是文件名，
##   两个文件是两个关卡，不会出现"同名重复"）。谁要删，显式调 delete_level()。
##   source_name 只用于日志（告诉玩家这次是从哪个关卡另存的）。
func save_level(name: String, data: Dictionary, source_name: String = "") -> Error:
	if not is_valid_level_name(name):
		push_warning("[LevelManager] 保存关卡失败：关卡名非法（%s）" % str(name))
		return ERR_INVALID_PARAMETER
	var n := canonical_name(name)
	# 已存在同名文件 → 写到那个**真实文件名**上（大小写以磁盘为准，避免大小写不同写成两份）
	var path := _path_for(n)
	if path.is_empty():
		path = level_path(n)
	var out: Dictionary = data.duplicate(true)
	out["name"] = path.get_file().get_basename()
	if not (out.get("blocks") is Array):
		out["blocks"] = []
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[LevelManager] 无法写入关卡文件：%s" % path)
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(out, "\t") + "\n")
	f.close()
	var src := canonical_name(source_name)
	if not src.is_empty() and src != n:
		print("[LevelManager] 已另存为关卡「%s」（由「%s」而来；原关卡文件保留）" % [n, src])
	return OK


## 删除关卡文件（不存在返回 false）。
func delete_level(name: String) -> bool:
	var path := _path_for(name)
	if path.is_empty():
		return false
	var err := DirAccess.remove_absolute(path)
	if err != OK:
		push_warning("[LevelManager] 删除关卡失败(err=%d)：%s" % [err, path])
		return false
	return true


## 校正存量文件：把每个关卡 JSON 里记录的 name 对齐成文件名（文件名即关卡名）。
## 返回被修正的文件数。只改"确实不一致"的那一处值，**保留文件原有排版**。
func normalize_names() -> int:
	var fixed := 0
	for stem in list_level_names():
		if _sync_name_field(level_path(stem), stem):
			fixed += 1
			print("[LevelManager] 已把关卡文件 %s%s 里记录的 name 修正为「%s」" % [stem, LEVEL_EXT, stem])
	return fixed


# 把文件里**顶层** "name" 字段的值改成 stem（保留其余排版）。
# 没有该字段 / 已经一致 / 写不了 → 一律返回 false（文件名才是权威，不补写也能正确工作）。
func _sync_name_field(path: String, stem: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var txt := f.get_as_text()
	f.close()
	var re := RegEx.new()
	if re.compile("(?m)^[ \\t]*\"name\"[ \\t]*:[ \\t]*\"([^\"]*)\"") != OK:
		return false
	var m := re.search(txt)          # 第一处 = 顶层 name（blocks 数组里的块记录没有 name 字段）
	if m == null or m.get_string(1) == stem:
		return false
	var w := FileAccess.open(path, FileAccess.WRITE)
	if w == null:
		return false
	w.store_string(txt.substr(0, m.get_start(1)) + stem + txt.substr(m.get_end(1)))
	w.close()
	return true


## 按关卡名实例化积木（Clone 数据的干净方式）：把关卡 JSON 里每个 block 变成一块积木，
## 依次 add 到 parent，位置 = offset + (x,y)。返回创建出的 Block 列表。
## 每块都按「空积木」默认样式，并可用 block 字段里的键覆盖（width/height/tags/fill 等）。
func instantiate_blocks(data: Dictionary, parent: Node, offset: Vector2 = Vector2.ZERO) -> Array[Block]:
	var made: Array[Block] = []
	var defs: Array = data.get("blocks", [])
	for i in defs.size():
		var d: Dictionary = defs[i]
		if not (d is Dictionary):
			push_warning("[LevelManager] 第 %d 块积木不是对象，已跳过" % i)
			continue
		var b: Block = Block.new()
		b.width = float(d.get("width", 80.0))
		b.height = float(d.get("height", 80.0))
		var tags: PackedStringArray = DEFAULT_TAGS
		if d.has("tags"):
			var raw = d["tags"]
			var arr: PackedStringArray = PackedStringArray()
			for t in raw:
				arr.append(str(t))
			if not arr.is_empty():
				tags = arr
		# ★ 关卡积木一律可选中：上面若没写（或漏写）selectable，这里补上。
		#   always_unselectable 优先，仍不可选（除非关卡故意让它不可选）。
		if not (BlockTags.ALWAYS_UNSELECTABLE in tags) and not (BlockTags.SELECTABLE in tags):
			tags.append(BlockTags.SELECTABLE)
		b.tags = tags
		if d.has("border_color"):
			b.border_color = _color_from(d["border_color"], b.border_color)
		if d.has("border_width"):
			b.border_width = float(d["border_width"])
		if d.has("fill_color"):
			b.fill_color = _color_from(d["fill_color"], b.fill_color)
		if d.has("display_layer"):
			b.display_layer = float(d["display_layer"])
		# ★ 字符串 ID 只在这里**读出**，真正赋值延后到入树之后（见下方 add_child 处）——
		#   必须经 BlockManager 注册，否则 get_block_by_string_id() 查不到关卡积木。
		var sid: String = ""
		if d.has("string_id"):
			sid = str(d["string_id"]).strip_edges()
		b.position = offset + Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
		parent.add_child(b)     # _ready 自动向 BlockManager 申请唯一 ID
		# ★★ 字符串 ID 必须**入树之后**、且**走 BlockManager** 设置（与属性面板改名是同一条路）：
		#   只写 `b.string_id` 字段会漏掉 `_string_registry` → `get_block_by_string_id()` 返回 null
		#   → 关卡页的「摄像头锚定（字符串 ID）」、事件链按名字定位、属性面板查重全部失效。
		#   同名已被其它有效积木占用时 set_string_id 会 push_warning 并返回 false（该块退回无名字）。
		if not sid.is_empty() and BlockManager != null and BlockManager.has_method("set_string_id"):
			BlockManager.set_string_id(b, sid)
		made.append(b)
	return made


## 计算一组积木的外接矩形（局部坐标，供投影居中使用）。无积木返回 Rect2()(空)。
func blocks_bounds(data: Dictionary) -> Rect2:
	var bounds := Rect2()
	var defs: Array = data.get("blocks", [])
	for d in defs:
		if not (d is Dictionary):
			continue
		var x := float(d.get("x", 0.0))
		var y := float(d.get("y", 0.0))
		var w := float(d.get("width", 80.0))
		var h := float(d.get("height", 80.0))
		var r := Rect2(x - w / 2.0, y - h / 2.0, w, h)
		if defs.find(d) == 0:
			bounds = r
		else:
			bounds = bounds.merge(r)
	return bounds


# ---------------- 内部 ----------------

# 把关卡名解析成对应的文件路径。★ 只认**文件名**（不再按 JSON 里的 name 反查）：
# 在"磁盘上真实存在的文件名"里查，先精确、再大小写不敏感。
# ★ 必须从 list_level_names() 取名字，不能拿用户输入的大小写去 file_exists ——
#   Windows 文件系统不区分大小写，`DEBUG_LEVELS2.json` 会"命中"真实文件，
#   于是关卡名会被污染成用户输入的 `DEBUG_LEVELS2`。返回空串 = 关卡不存在。
func _path_for(name: String) -> String:
	var n := canonical_name(name)
	if n.is_empty():
		return ""
	var ci := ""
	for existing in list_level_names():
		if existing == n:
			return level_path(existing)
		if ci.is_empty() and existing.to_lower() == n.to_lower():
			ci = existing
	if not ci.is_empty():
		return level_path(ci)
	return ""


# JSON 里的颜色可以是 [r,g,b,a] 数组(0-1) 或形如 "#RRGGBBAA" 的字符串；解析失败返回 fallback。
func _color_from(v: Variant, fallback: Color) -> Color:
	if v is Array:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
	if v is String and String(v).begins_with("#"):
		var c := Color(String(v))
		if c.a > 0.0 or String(v).length() >= 7:
			return c
	return fallback