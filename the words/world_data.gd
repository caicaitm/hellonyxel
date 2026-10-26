# the words/world_data.gd
# 「世界」数据层：读取世界定义 JSON → 建出世界节点树（WorldNode）。
#
# ★★ JSON 只记录世界的**初始状态**：世界会随玩家的行动与时间自行演化，
#   运行期的变化一律留在内存（未来由存档系统另存），**不回写**这份初始定义。
#
# 建树流程（顺序无关、允许任意层级）：
#   ① 先按 sid 建出全部节点（都先挂在世界根 WorldView 下）；
#   ② 再按 parent 把节点重挂到父节点下（parent 为空 / 找不到父 → 留在世界根）；
#   ③ 按初始相位角摆位；④ 画尾迹（挂在父节点下，只覆盖公转方向**身后**一段，渐隐）。
#   ⇒ 「改父节点即移动归属」，天然支持跨级归属与后续的卫星（level 2）。
class_name WorldData
extends RefCounted

## 世界定义 JSON（初始状态唯一数据源）。
const DEFAULT_JSON := "res://the words/data/solar_system.json"

## 世界数据目录（与 solar_system.json 同目录）：节点里的 `cities` 字段按**相对本目录**解析。
const DATA_DIR := "res://the words/data/"

## 贴图素材目录（当前用素材库里的地球贴图）；JSON 根字段 `texture_base` 可覆盖。
const FALLBACK_TEXTURE_BASE := "D:/.0MyProject/《你好，荧惑（Hello,Nyxel）》设计草案/素材库/"

## ---- 第二十四轮：「本体」编辑（节点属性窗口改的东西落在这里）----
## ★ 为什么单独一个文件、而不是改写源数据：全量城市表是 `tools/build_city_bulk.py` 的**生成物**
##   （重跑脚本会把改动冲掉），人工名单也不想被程序改写 ⇒ 「源数据 + 叠加一层编辑」。
##   ★ 它放在 `res://the words/data/` 里 ⇒ 属于**游戏自身的数据**（= 用户要的「本体 / 初始状态」），
##     与关卡页写 `res://levels/` 是同一套约定（★ 导出的正式包 res:// 只读 ⇒ 那时写盘会失败并告警）。
const EDITS_JSON := "res://the words/data/world_edits.json"

static var _edits_cache: Dictionary = {}
static var _edits_loaded: bool = false


## 读「本体」编辑（一次读、之后走缓存）。结构：
## { "cities": { "<星体sid>": { "<gnid>": { "names": {语言码: 名}, "lat": …, "lon": …, "tier": … } } },
##   "nodes":  { "<sid>": { "name": … } } }
static func load_edits() -> Dictionary:
	if _edits_loaded:
		return _edits_cache
	_edits_loaded = true
	# ★ 首次运行时这个文件还不存在（由「节点属性」窗口第一次「应用」时才创建）⇒ 静默返回空，
	#   别每次开世界页都刷一条「世界定义不存在」的警告。
	if not FileAccess.file_exists(EDITS_JSON):
		_edits_cache = {}
		return _edits_cache
	_edits_cache = load_data(EDITS_JSON)
	return _edits_cache


## 某颗星体的城市编辑（键 = GeoNamesID 的字符串形式）。
static func city_edits(host_sid: String) -> Dictionary:
	var e := load_edits()
	var cs: Variant = e.get("cities", {})
	if not (cs is Dictionary):
		return {}
	var one: Variant = (cs as Dictionary).get(host_sid, {})
	return one if one is Dictionary else {}


## 某个星体节点自身的编辑（现阶段只有 name）。
static func node_edit(sid: String) -> Dictionary:
	var e := load_edits()
	var ns: Variant = e.get("nodes", {})
	if not (ns is Dictionary):
		return {}
	var one: Variant = (ns as Dictionary).get(sid, {})
	return one if one is Dictionary else {}


## 写一条城市编辑 → 立刻落盘（编辑是低频人工操作 ⇒ 每次重写整份可接受）。成功返回 true。
static func save_city_edit(host_sid: String, gnid_key: String, patch: Dictionary) -> bool:
	return _save_edit("cities", host_sid, gnid_key, patch)


static func save_node_edit(sid: String, patch: Dictionary) -> bool:
	return _save_edit("nodes", "", sid, patch)


static func _save_edit(section: String, host_sid: String, key: String, patch: Dictionary) -> bool:
	var e := load_edits()
	if not e.has("_说明"):
		e["_说明"] = ("「本体」编辑（第二十四轮 · 节点属性窗口写入）：源数据不动，本文件在加载时**叠加**在"
			+ "源数据之上（城市按 GeoNamesID 定位到 <星体sid>/<gnid>，星体按 sid）。删除对应键即回退。")
	var sec: Variant = e.get(section, {})
	if not (sec is Dictionary):
		sec = {}
	var into: Dictionary = sec
	if not host_sid.is_empty():
		var sub: Variant = into.get(host_sid, {})
		if not (sub is Dictionary):
			sub = {}
		into = sub
	var one: Variant = into.get(key, {})
	if not (one is Dictionary):
		one = {}
	(one as Dictionary).merge(patch, true)
	into[key] = one
	if not host_sid.is_empty():
		(sec as Dictionary)[host_sid] = into
	e[section] = sec

	var f := FileAccess.open(EDITS_JSON, FileAccess.WRITE)
	if f == null:
		push_warning("[WorldData] 「本体」编辑写不进 %s（正式导出的包 res:// 只读）" % EDITS_JSON)
		return false
	f.store_string(JSON.stringify(e, "  "))
	f.close()
	_edits_cache = e
	return true


## 读世界定义。失败（不存在 / 打不开 / 不是 JSON 对象）→ 返回 {}。
static func load_data(path: String = DEFAULT_JSON) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("[WorldData] 世界定义不存在：%s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("[WorldData] 世界定义打不开：%s" % path)
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		push_warning("[WorldData] 世界定义不是 JSON 对象：%s" % path)
		return {}
	return parsed


## 贴图素材基址（保证以 / 结尾）。
static func texture_base(data: Dictionary) -> String:
	var b := str(data.get("texture_base", "")).strip_edges()
	if b.is_empty():
		b = FALLBACK_TEXTURE_BASE
	if not b.ends_with("/") and not b.ends_with("\\"):
		b += "/"
	return b


## 贴图名 → 可直读路径（TextureCache 通道②：绝对路径 / user:// 运行期直读，无需 Godot 导入）。
## 空 = 不贴图；已是绝对路径 / res:// / user:// 则原样返回，其余按基址拼接。
static func resolve_texture(base_dir: String, tex_name: String) -> String:
	var t := tex_name.strip_edges()
	if t.is_empty():
		return ""
	if t.begins_with("res://") or t.begins_with("user://") or t.begins_with("/") or t.begins_with("\\"):
		return t
	if t.length() >= 2 and t.substr(1, 1) == ":":
		return t.replace("\\", "/")
	return base_dir + t


## 读**城市定义**：返回 `cities` 数组（每项一个 Dictionary：name/intl/lat/lon/tier/...）。
## ★ 城市**单独一个 JSON**（第十九轮）：地球的星体字段已经很多，城市是另一类数据、将来会扩到几百条；
##   由星体节点的 `cities` 字段给出文件名（相对 DATA_DIR，也可直接给 res:// 绝对路径）。
## ★ 任何失败（文件不在 / 打不开 / 不是 JSON 对象 / 没有 cities 数组）都只**警告并返回空数组** ——
##   绝不能因为城市数据坏了就整个世界建不出来。
static func load_cities(name: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var n := name.strip_edges()
	if n.is_empty():
		return out
	var path := n if n.begins_with("res://") else DATA_DIR + n
	if not FileAccess.file_exists(path):
		push_warning("[WorldData] 城市定义不存在：%s" % path)
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("[WorldData] 城市定义打不开：%s" % path)
		return out
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		push_warning("[WorldData] 城市定义不是 JSON 对象：%s" % path)
		return out
	var data: Dictionary = parsed
	var arr: Variant = data.get("cities", [])
	if not (arr is Array):
		push_warning("[WorldData] 城市定义里没有 cities 数组：%s" % path)
		return out
	for c in (arr as Array):
		if c is Dictionary:
			out.append(c)
	return out


## 建树：返回建出的全部节点（顺序 = JSON 里的顺序）。
static func build_tree(view: Node3D, data: Dictionary) -> Array[WorldNode]:
	var base := texture_base(data)
	var nodes: Array[WorldNode] = []
	var by_sid: Dictionary = {}

	var recs: Array = data.get("nodes", [])
	for r in recs:
		if not (r is Dictionary):
			continue
		var n := WorldNode.new()
		n.set_from_record(r, base)
		# ★ 第二十四轮：星体节点的「本体」编辑（现阶段只有名字）叠加上去
		var ne := node_edit(n.sid)
		var ne_name := str(ne.get("name", "")).strip_edges()
		if not ne_name.is_empty():
			n.display_name = ne_name
		if n.sid.is_empty():
			push_warning("[WorldData] 跳过没有 sid 的世界节点")
			continue
		if by_sid.has(n.sid):
			push_warning("[WorldData] 重复 sid=%s → 跳过" % n.sid)
			continue
		by_sid[n.sid] = n
		nodes.append(n)
		view.add_child(n)          # 先挂世界根；下面按 parent 重挂
		n.build_visual()

	# 按 parent 重挂（parent 为空 / 找不到父 → 留在世界根 = 总节点）
	for n in nodes:
		var p: WorldNode = by_sid.get(n.parent_sid, null)
		if p == null:
			n.parent_sid = ""
			continue
		_reparent_under(n, p)
		n.parent_node = p
		p.child_nodes.append(n)

	for n in nodes:
		n.place_orbit()
	for n in nodes:
		n.build_trail()
	return nodes


static func _reparent_under(n: WorldNode, p: WorldNode) -> void:
	var old: Node = n.get_parent()
	if old != null and old != p:
		old.remove_child(n)
	if n.get_parent() != p:
		p.add_child(n)
