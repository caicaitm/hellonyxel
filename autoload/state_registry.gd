# autoload/state_registry.gd
# 临时状态文件「注册表」—— 把 %文档%/HelloNyxel/Temp 下的各 JSON 文件用友好中文名登记，
# 供「效果编辑器」下拉选择：选「玩家画像」自动翻译为 player_profile.json，
# 并列出该文件内「已知变量 + 文件实际键」合并后的变量名。
#
# ★ 本脚本是 autoload 单例（名 StateRegistry），故**不声明 class_name**（同名会撞）。
#
# ★★ 批次 96：新增**状态标签**的读写。
#   背景：条件编辑器能写 `has_tag("剧情状态","得到钥匙")`，可效果编辑器当年只会写「变量」——
#   而 /set_var 的右侧**不支持数组字面量**，于是「加标签」这件事在效果侧根本表达不出来。
#   现在补齐：/add_tag · /remove_tag · /clear_tags 三个命令 + 本文件的标签读写接口。
#   ★ 判定口径与 EventExpr.has_tag 完全一致：**该状态 JSON 里任一「字符串数组」字段含此标签**。
#   ★ 状态 JSON 是「单一真源」：条件求值每次现读文件 → 写完标签，条件立刻生效，无需广播。
extends Node

# 注册项：{ file, desc, vars }。
# vars = 已知顶层变量名（脚本层面已知的键）；文件实际键会在 effective_vars_of 里再合并一次。
const _REGISTRY: Dictionary = {
	"玩家画像": {
		"file": "player_profile.json",
		"desc": "玩家身份与画像：姓名/生日/地址 + 性别桶/年龄桶权重 + 提交历史",
		"vars": ["name", "birthday", "address", "age", "age_bucket",
			"gender_input", "gender_bucket", "gender_weights", "age_weights",
			"submit_count", "updated_at", "history"],
	},
	"荧惑剧情状态": {
		"file": "nyxel_story_state.json",
		"desc": "荧惑主线剧情进度与分支状态",
		"vars": [],
	},
	"荧惑日常状态": {
		"file": "nyxel_daily_state.json",
		"desc": "荧惑每日/日常循环状态：饱食度/精力/体力/清醒度（0~100）+ 心情/欲望标签集",
		"vars": ["satiety", "energy", "stamina", "alertness", "mood", "desire", "updated_at", "version"],
	},
	"世界状态": {
		"file": "world_state.json",
		"desc": "世界/场景级状态变量",
		"vars": [],
	},
	"剧情状态": {
		"file": "story_state.json",
		"desc": "通用剧情状态（章节/flag）",
		"vars": [],
	},
	"设备清单": {
		"file": "devices.json",
		"desc": "玩家设备与硬件零件清单（devices 数组）",
		"vars": ["devices"],
	},
	"背包清单": {
		"file": "inventory.json",
		"desc": "背包物品清单（items 数组）",
		"vars": ["catalog_stripped", "items", "version"],
	},
}

# ---- 状态标签：每个已注册状态「允许写标签的字段」（批次 96）----
#   · Array[String] 非空 → **只允许这些字段**（荧惑日常状态 = 它自己的两个「标签集」，
#     有归一化 / 条数上限 / 变更广播 → 必须走 NyxelDailyState 的 API，不能直写文件）；
#   · Array[String] 空   → 该状态顶层**没有**可当标签用的字段 → 只允许新建 "tags"
#     （玩家画像 / 设备清单 / 背包清单：字段由各自系统按模型重建，直写别的键会被抹掉）；
#   · "*"                → 该状态顶层任意「字符串数组」字段都可以，没有则新建 "tags"
#     （荧惑剧情状态 / 世界状态 / 剧情状态：自由字典，只有本命令会往里写数组）。
# ★ 未登记的状态（含 calendar_notes.json）一律不参与标签。
const TAG_FIELDS: Dictionary = {
	"荧惑日常状态": ["mood", "desire"],
	"荧惑剧情状态": "*",
	"世界状态": "*",
	"剧情状态": "*",
	"玩家画像": [],
	"设备清单": [],
	"背包清单": [],
}

# 新建标签字段时用的键名（"*" 型状态顶层没有任何字符串数组字段 / 空数组型状态）
const DEFAULT_TAG_FIELD: String = "tags"


# ================= 查询接口 =================

## 全部已注册友好名（升序），供目标下拉。
func registered_friendly() -> Array[String]:
	var out: Array[String] = []
	for k in _REGISTRY:
		out.append(str(k))
	out.sort()
	return out


## 友好名 → 文件名（如「玩家画像」→ player_profile.json）。找不到返回空串。
func file_of(friendly: String) -> String:
	var e = _REGISTRY.get(friendly, null)
	if e is Dictionary:
		return str((e as Dictionary).get("file", ""))
	return ""


## 文件名 → 友好名（反向查）。找不到返回空串。
func friendly_of_file(file: String) -> String:
	for k in _REGISTRY:
		var e = _REGISTRY[k]
		if str((e as Dictionary).get("file", "")) == file:
			return str(k)
	return ""


## 友好名 → 状态 JSON 文件的绝对路径（供 EventExpr.has_tag / state_field 读取）。找不到 → 空串。
func path_of(friendly: String) -> String:
	var file: String = file_of(friendly)
	if file == "":
		return ""
	return _file_path(file)


## 友好名 → 说明文案。
func desc_of(friendly: String) -> String:
	var e = _REGISTRY.get(friendly, null)
	if e is Dictionary:
		return str((e as Dictionary).get("desc", ""))
	return ""


## 友好名 → 注册时已知的变量名（不含文件实际键）。
func declared_vars_of(friendly: String) -> Array[String]:
	var e = _REGISTRY.get(friendly, null)
	if e is Dictionary:
		var v = (e as Dictionary).get("vars", [])
		if v is Array:
			var out: Array[String] = []
			for x in v:
				out.append(str(x))
			return out
	var empty: Array[String] = []
	return empty


## 友好名 → 「注册变量 + 文件实际键」合并去重。
## 文件不存在则返回注册变量（下拉仍可用；用户也可在编辑器里手动输入变量名）。
func effective_vars_of(friendly: String) -> Array[String]:
	var out: Array[String] = declared_vars_of(friendly)
	var file: String = file_of(friendly)
	if file != "":
		for k in _actual_keys(file):
			if not (k in out):
				out.append(str(k))
	return out


# ================= 状态标签：查询（批次 96）=================
# ★ 与 EventExpr.has_tag 同一口径：标签 = 该状态 JSON 里某个「字符串数组」字段的一个元素。


## 哪些已注册状态可以写标签（升序）——供命令报错提示与编辑器下拉。
func tag_writable_friendly() -> Array[String]:
	var out: Array[String] = []
	for k in _REGISTRY:
		if TAG_FIELDS.has(str(k)):
			out.append(str(k))
	out.sort()
	return out


## 该状态是否参与「状态标签」（只有已登记且声明过字段的状态可以）。
func tag_writable(friendly: String) -> bool:
	return _REGISTRY.has(friendly) and TAG_FIELDS.has(friendly)


## 该状态顶层「值为字符串数组」的键（升序）。文件不存在 / 不可解析 → 空。
func array_field_names_of(friendly: String) -> Array[String]:
	var out: Array[String] = []
	var d := _read_state_dict(friendly)
	for k in d:
		if _is_str_array(d[k]):
			out.append(str(k))
	out.sort()
	return out


## 该状态「可写标签的字段」候选（供下拉）：
##   · 声明了字段清单 → 就用清单；
##   · "*" 型 → 文件里实际存在的字符串数组字段，一个都没有 → ["tags"]；
##   · 空清单型 → ["tags"]（表示「新建一个 tags 字段」）。
func tag_fields_of(friendly: String) -> Array[String]:
	var out: Array[String] = []
	if not tag_writable(friendly):
		return out
	var spec = TAG_FIELDS[friendly]
	if spec is Array:
		for x in (spec as Array):
			out.append(str(x))
		if out.is_empty():
			out.append(DEFAULT_TAG_FIELD)
		return out
	for k in array_field_names_of(friendly):
		out.append(k)
	if out.is_empty():
		out.append(DEFAULT_TAG_FIELD)
	return out


## 该状态某字段的标签（字符串数组副本；字段不存在 / 不是数组 → 空）。
func tags_of(friendly: String, field: String) -> Array[String]:
	var out: Array[String] = []
	var d := _read_state_dict(friendly)
	if not d.has(field):
		return out
	var v = d[field]
	if not (v is Array):
		return out
	for x in (v as Array):
		out.append(str(x))
	return out


## 该状态**所有**字符串数组字段里出现过的标签（去重升序）。
## ★ 条件编辑器就靠它给「标签名」下拉 → 与 has_tag 的判定范围严格一致（否则会漏标签）。
func all_tags_of(friendly: String) -> Array[String]:
	var out: Array[String] = []
	var d := _read_state_dict(friendly)
	for k in d:
		if _is_str_array(d[k]):
			for x in (d[k] as Array):
				var t := str(x)
				if not (t in out):
					out.append(t)
	out.sort()
	return out


# ================= 状态标签：写入（批次 96）=================
# 统一返回 { ok:bool, err:String, field:String, tags:Array, changed:bool }。


## 加一条标签（已存在 = 成功且 changed=false）。field 省略 → 见 _auto_tag_field 的自动规则。
func add_tag(friendly: String, tag: String, field: String = "") -> Dictionary:
	return _tag_op("add", friendly, tag, field)


## 移除一条标签（不存在 = 成功且 changed=false，不算错误）。
func remove_tag(friendly: String, tag: String, field: String = "") -> Dictionary:
	return _tag_op("remove", friendly, tag, field)


## 清空某字段的全部标签。
func clear_tags(friendly: String, field: String = "") -> Dictionary:
	return _tag_op("clear", friendly, "", field)


# ================= 内部 =================

func _tag_op(op: String, friendly: String, tag: String, field: String) -> Dictionary:
	var res := { "ok": false, "err": "", "field": "", "tags": [], "changed": false }
	if not _REGISTRY.has(friendly):
		res["err"] = "未注册的状态「%s」（可用：%s）" % [friendly, ", ".join(registered_friendly())]
		return res
	if not tag_writable(friendly):
		res["err"] = "「%s」是不可写标签的状态文件" % friendly
		return res
	var fld: String = field.strip_edges()
	if fld == "":
		var auto := _auto_tag_field(friendly)
		if str(auto.get("err", "")) != "":
			res["err"] = str(auto["err"])
			return res
		fld = str(auto["field"])
	if not _is_valid_field_name(fld):
		res["err"] = "字段名「%s」不合法（须是字母/数字/下划线开头，可含点）" % fld
		return res
	if not _tag_field_allowed(friendly, fld):
		res["err"] = "状态「%s」只允许这些标签字段：%s（实际给了「%s」）" % [
			friendly, ", ".join(tag_fields_of(friendly)), fld]
		return res
	var t: String = tag.strip_edges()
	if op != "clear" and t == "":
		res["err"] = "标签不能为空"
		return res
	# ★ 荧惑日常状态的 mood/desire 是它自己的「标签集」：有归一化 / 条数上限 / 变更广播，
	#   必须走后门（直写文件会被 owner 的下一次保存原样覆盖）。
	if friendly == "荧惑日常状态":
		return _tag_op_daily(op, fld, t, res)
	return _tag_op_generic(op, friendly, fld, t, res)


## field 省略时的自动规则（绝不猜）：
##   候选 = 1 个 → 用它；候选 = 0 个不可能（tag_fields_of 至少给 "tags"）；候选 > 1 个 → 报错要求写明。
func _auto_tag_field(friendly: String) -> Dictionary:
	var cands := tag_fields_of(friendly)
	if cands.size() == 1:
		return { "field": cands[0], "err": "" }
	return { "field": "", "err": "状态「%s」有多个标签字段 %s → 请用 field 指定要写哪一个" % [
		friendly, ", ".join(cands)] }


func _tag_field_allowed(friendly: String, field: String) -> bool:
	var spec = TAG_FIELDS.get(friendly, [])
	if spec is Array:
		var list: Array = spec
		if list.is_empty():
			# 空清单型：只允许新建标签字段（避免直写被 owner 重建掉的键）
			return field == DEFAULT_TAG_FIELD
		for x in list:
			if str(x) == field:
				return true
		return false
	return true


## 荧惑日常状态：走 NyxelDailyState 自己的标签集 API（唯一真源，别绕过它）。
func _tag_op_daily(op: String, fld: String, tag: String, res: Dictionary) -> Dictionary:
	var nd := _autoload("NyxelDailyState")
	if nd == null:
		res["err"] = "荧惑日常状态不可用（NyxelDailyState 未加载）"
		return res
	var cur := tags_of("荧惑日常状态", fld)
	match op:
		"add":
			if not (tag in cur):
				nd.add_set_item(fld, tag)
				res["changed"] = true
		"remove":
			if tag in cur:
				nd.remove_set_item(fld, tag)
				res["changed"] = true
		"clear":
			if not cur.is_empty():
				nd.clear_set(fld)
				res["changed"] = true
	res["ok"] = true
	res["field"] = fld
	res["tags"] = tags_of("荧惑日常状态", fld)
	return res


## 通用路径（其余 6 个状态）：原始 JSON 读 → 改该字段 → 写回 → 让 owner 重新读盘。
## ★ 整份读、整份写，**保留原有全部键**（不像 /set_var 只动一个引用），绝不顺手删别的字段。
func _tag_op_generic(op: String, friendly: String, fld: String, tag: String, res: Dictionary) -> Dictionary:
	var file: String = file_of(friendly)
	var path: String = _file_path(file)
	var d := _read_raw_dict(path)
	if d.has(fld):
		var v = d[fld]
		if not (v is Array):
			res["err"] = "状态「%s」的字段「%s」已存在且不是数组 → 拒绝覆盖，请换一个字段名" % [friendly, fld]
			return res
		if not _is_str_array(v):
			res["err"] = "状态「%s」的字段「%s」不是「字符串数组」（元素是对象 / 数字）→ 拒绝写入，请换一个字段名" % [friendly, fld]
			return res
	var cur: Array = []
	if d.has(fld):
		for x in (d[fld] as Array):
			cur.append(str(x))
	var changed := false
	match op:
		"add":
			if not (tag in cur):
				cur.append(tag)
				changed = true
		"remove":
			var idx := cur.find(tag)
			if idx >= 0:
				cur.remove_at(idx)
				changed = true
		"clear":
			if not cur.is_empty():
				cur.clear()
				changed = true
	if changed:
		d[fld] = cur
		if not _write_raw_dict(path, d):
			res["err"] = "写入失败：%s" % path
			return res
		# ★★ owner 覆盖坑：写盘后必须让「持有该文件的系统」重新读盘，
		#    否则它内存里那份旧数据会在下一次保存时把刚写进去的标签抹掉。
		#    前提：这几个 owner 的 read_from_disk / load_from_disk **保留未知顶层键**（批次 96 补齐）。
		_reload_owner(file)
	res["ok"] = true
	res["field"] = fld
	res["tags"] = cur
	res["changed"] = changed
	return res


## 写完状态文件后，让持有该文件的系统重新读盘（没有 owner 的 3 份通用状态为空操作）。
func _reload_owner(file: String) -> void:
	match file:
		"player_profile.json":
			var pp := _autoload("PlayerProfile")
			if pp != null and pp.has_method("reload"):
				pp.reload()
		"devices.json":
			var dv := _autoload("Devices")
			if dv != null and dv.has_method("load_from_disk"):
				dv.load_from_disk()
		"inventory.json":
			var iv := _autoload("Inventory")
			if iv != null and iv.has_method("load_from_disk"):
				iv.load_from_disk()


## 取 autoload 节点。★ 不直接写全局名：单测 / 探针里没有这些 autoload 时本文件也能编译。
func _autoload(nm: String) -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null(NodePath(nm))


func _read_state_dict(friendly: String) -> Dictionary:
	var file: String = file_of(friendly)
	if file == "":
		return {}
	return _read_raw_dict(_file_path(file))


func _read_raw_dict(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var txt := FileAccess.get_file_as_string(path)
	if txt.strip_edges().is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(txt)
	if parsed is Dictionary:
		return parsed
	return {}


func _write_raw_dict(path: String, d: Dictionary) -> bool:
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(d, "  "))
	f.close()
	return true


## 该值是否「字符串数组」（空数组也算 —— 空 = 还没放标签，正等着被写）。
static func _is_str_array(v: Variant) -> bool:
	if not (v is Array):
		return false
	for x in (v as Array):
		if not (x is String):
			return false
	return true


## 字段名合法性：ASCII 标识符（允许点，便于 tags.xxx 这类命名习惯）。
## ★ 必须校验：字段名会被写进 JSON 的顶层键，也是下一条命令的查找依据，不能让空格/冒号混进来。
static func _is_valid_field_name(s: String) -> bool:
	if s.is_empty():
		return false
	var c0: String = s[0]
	if c0 >= "0" and c0 <= "9":
		return false
	for i in s.length():
		var c: String = s[i]
		var ok := ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z")
			or (c >= "0" and c <= "9") or c == "_" or c == ".")
		if not ok:
			return false
	return true


func _actual_keys(file: String) -> Array[String]:
	var path := _file_path(file)
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var txt := f.get_as_text()
	f.close()
	var p := JSON.new()
	if p.parse(txt) != OK:
		return []
	if p.data is Dictionary:
		var out: Array[String] = []
		for k in (p.data as Dictionary):
			out.append(str(k))
		return out
	if p.data is Array:
		# 数组文件：给几个下标提示（编辑器里再按实际长度校正）
		return ["[0]", "[1]", "[2]"]
	return []


func _file_path(file: String) -> String:
	if SaveManager != null and SaveManager.has_method("get_temp_dir"):
		var d: String = SaveManager.get_temp_dir()
		if not d.is_empty():
			return d.path_join(file)
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs.is_empty():
		docs = OS.get_environment("USERPROFILE")
	return docs.path_join("HelloNyxel/Temp").path_join(file)
