# ui/condition_editor_panel.gd
# 「编辑条件」可视化条件编辑器：递归规则构建器。
# ★ 原名「显示要求」编辑器（display_requirement_panel.gd / DisplayRequirementPanel），
#   批次 94 改名并统一为**通用条件编辑器** —— 事件链的「触发条件」「显示要求」等
#   同一套 EventExpr 语法的字段，都用这一页编辑（scope 决定提示语）。
#
# ★ 用途：事件链编辑器里按钮「显示要求(show)」/ 链配置「触发条件」字段的
#   「编辑」按钮打开的独立页面。整句表达式为真时才成立。
#
# ★ 模型（Dictionary 树）：
#   - 根 / 分组 group：{ "kind":"group", "op":"and"|"or", "neg":bool, "children":[节点...] }
#   - 状态标签 tag    ：{ "kind":"tag", "state":友好名, "neg":bool(无标签), "tag":标签 }
#   - 数值比较 cmp    ：{ "kind":"cmp", "src":"global"|"state", "state":友好名, "name":变量/字段,
#                          "op":">"|"<"|">="|"<="|"=="|"!=", "val":值, "valtype":"num"|"str" }
#   - 玩家状态 player ：{ "kind":"player", "what":见 PS_KINDS, "act":活动属性真值,
#                          "op":运算符, "val":值, "valtype":..., "neg":bool }
#   序列化到 EventExpr 语法：
#     tag 有标签   → has_tag("状态","标签")       无标签 → !has_tag("状态","标签")
#     cmp 全局变量 → <变量> <op> <值>
#     cmp 状态字段 → state_field("状态","字段") <op> <值>
#     player 在忙  → player_busy()                在闲 → !player_busy()
#            在运行 → activity_active("game")     未运行 → !activity_active("game")
#            最高/最低 → activity_top() == "game" / activity_low() != "game"
#            权重   → activity_weight("game") > 1  取反 → !( ... )
#     分组         → ( 子句 and/or 子句 )         取反 → !( 子句 and/or 子句 )
#
# ★ 往返不丢数据：打开时把源串解析回模型；解析失败（编辑器表达不了的表达式）→
#   进入「原始文本」模式原样保留，关闭时写回原始串，绝不静默丢内容。
#
# ★★ 批次 96：标签名不再是「手打」——改成「下拉该状态**现有**的标签 + 可手填新标签」。
#   标签 = 某状态 JSON 里某个「字符串数组」字段的一个元素（判定见 EventExpr.has_tag），
#   由 StateRegistry.all_tags_of 列出；写标签的入口在效果编辑器（add_tag / remove_tag）。
#
# ★★ 显示文本 ≠ 真值（批次 67 根因）：所有下拉「真值」存 item_metadata，显示文本走翻译。
class_name ConditionEditorPanel
extends Control

const PANEL_W: float = 860.0
const PANEL_H: float = 600.0
const TITLE_BAR_H: float = 28.0

# 比较运算符：[真值, 翻译 key]
const OPS: Array = [
	[">", "大于"], ["<", "小于"], [">=", "大于等于"],
	["<=", "小于等于"], ["==", "等于"], ["!=", "不等于"],
]
# 来源：[真值, 翻译 key]
const SRC_KINDS: Array = [
	["global", "全局变量"], ["state", "状态数值字段"],
]
# 谓词类型：[真值, 翻译 key]
# ★ 新增项一律**追加在末尾**（批次 91 硬规则：靠前的索引常量不能被打乱）。
const PRED_KINDS: Array = [
	["tag", "状态标签"], ["cmp", "数值比较"], ["player", "玩家状态"],
]
# 有/无标签：[真值, 翻译 key]
const TAG_NEG: Array = [
	["false", "有标签"], ["true", "无标签"],
]
# 标签名下拉的哨兵真值（不是合法标签，故可安全当判据）
const TAG_SENTINEL: String = "(选择标签)"
# ★ 批次 94：玩家状态子类型：[真值, 翻译 key]
const PS_KINDS: Array = [
	["busy", "在忙"],
	["idle", "在闲"],
	["active", "正在运行某类活动"],
	["inactive", "未运行某类活动"],
	["top", "权重最高的活动是"],
	["low", "权重最低的活动是"],
	["weight", "某活动权重"],
]
# 玩家状态的「是 / 不是」比较（用于 权重最高/最低 与活动属性比较）
const EQ_OPS: Array = [
	["==", "是"], ["!=", "不是"],
]
# 函数名白名单（词法分析用；不含这些名字的标识符一律当全局变量名）
const FUNC_NAMES: Array = [
	"has_tag", "state_field",
	"player_busy", "activity_active", "activity_weight", "activity_top", "activity_low",
]
# 活动属性兜底表（与 autoload/busy_state.gd 的 ACTIVITY_KINDS 一致）：
# 万一取不到 BusyState（顺序/测试环境）也不至于空下拉。
const ACTIVITY_FALLBACK: Array = [
	["game", "游戏"], ["work", "工作"], ["chat", "聊天"], ["music", "音乐"],
	["leisure", "休闲"], ["study", "学习"], ["community", "社区"], ["other", "其他"],
]

signal closed

var _bg: UIPanel
var _rows_box: VBoxContainer
var _preview_label: Label
var _source_le: LineEdit = null
var _fnt: FontFile
var _drag: UIDragHandle
var _closed_emitted: bool = false
# 语义范围："show"（显示要求）/"trigger"（触发条件）/其它 → 通用提示语
var _scope: String = "show"

# 模型：根分组
var _model: Dictionary = {}
var _raw_mode: bool = false
var _raw_text: String = ""

# 解析器瞬时状态
var _ptoks: Array = []
var _ppi: int = 0
var _perr: bool = false


## scope 决定提示语；省略 = "show"（向后兼容旧调用）。
func open(title: String, source_le: LineEdit, scope: String = "show") -> void:
	_source_le = source_le
	_scope = scope
	_build(title)
	_parse_source()
	_rebuild_ui()


# ================= 构建 =================


# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build(title: String) -> void:
	_fnt = UIStyle.get_cjk_font()
	_bg = UIPanel.new()
	_bg.position = Vector2(440.0, 60.0)
	_bg.size = Vector2(PANEL_W, PANEL_H)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	add_child(_bg)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 6)
	_bg.add_child(root)

	# 标题栏
	var title_row := HBoxContainer.new()
	title_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title_label := Label.new()
	title_label.text = title
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	title_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_fnt):
		title_label.add_theme_font_override("font", _fnt)
	title_row.add_child(title_label)
	_drag = UIDragHandle.new()
	_drag.setup(_bg)
	title_row.add_child(_drag)
	var close_btn := UIBtn.new()
	close_btn.set_id("dr_close")
	close_btn.set_label("×")
	close_btn.custom_minimum_size = Vector2(TITLE_BAR_H, TITLE_BAR_H)
	close_btn.size = Vector2(TITLE_BAR_H, TITLE_BAR_H)
	close_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	close_btn.pressed_id.connect(func(_id: String) -> void: close())
	_min_btn = UIMinimize.attach(title_row, func(): set_minimized(not _minimized))
	title_row.add_child(close_btn)
	root.add_child(title_row)

	# 实时预览
	_preview_label = Label.new()
	_preview_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_preview_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	_preview_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if is_instance_valid(_fnt):
		_preview_label.add_theme_font_override("font", _fnt)
	root.add_child(_preview_label)

	# 可滚动规则区
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_rows_box)
	root.add_child(scroll)

	# 底部：完成
	var btn_row := HBoxContainer.new()
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var done := UIBtn.new()
	done.set_id("dr_done")
	done.set_label(TranslationManager.t("完成"))
	done.custom_minimum_size = Vector2(100.0, UIStyle.BTN_HEIGHT)
	done.pressed_id.connect(func(_id: String) -> void: close())
	btn_row.add_child(done)
	root.add_child(btn_row)

	if not TranslationManager.language_changed.is_connected(_on_language_changed):
		TranslationManager.language_changed.connect(_on_language_changed)
	TranslationManager.retranslate_tree(self)
	_refresh_tooltips()


func _on_language_changed(_lang: String) -> void:
	if is_instance_valid(self):
		TranslationManager.retranslate_tree(self)
		_refresh_tooltips()


func _refresh_tooltips() -> void:
	if is_instance_valid(_drag):
		_drag.tooltip_text = TranslationManager.t("拖动以移动条件编辑器")


# ================= 解析源串 =================

func _parse_source() -> void:
	var src := ""
	if _source_le != null:
		src = _source_le.text.strip_edges()
	if src == "":
		_model = _new_group()
		_raw_mode = false
		return
	var m := _parse_expr_to_model(src)
	if m.is_empty() or _perr:
		_raw_mode = true
		_raw_text = src
		_model = {}
	else:
		_raw_mode = false
		if m.get("kind", "") != "group":
			_model = {"kind": "group", "op": "and", "neg": false, "children": [m]}
		else:
			_model = m


# ================= UI 重建 =================

func _rebuild_ui() -> void:
	if _rows_box == null:
		return
	for c in _rows_box.get_children():
		c.queue_free()
	if _raw_mode:
		_render_raw()
	else:
		_rows_box.add_child(_label(_hint_text()))
		_render_node(_model, _rows_box, true)
	_update_preview()


## 顶部提示语随用途变化（scope 由调用方给出）。
func _hint_text() -> String:
	if _scope == "trigger":
		return TranslationManager.t("满足以下条件时触发（空 = 不限制）")
	return TranslationManager.t("满足以下条件时显示按钮（空 = 始终显示）")


func _render_raw() -> void:
	var te := TextEdit.new()
	te.text = _raw_text
	te.size_flags_vertical = Control.SIZE_EXPAND_FILL
	te.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	te.custom_minimum_size = Vector2(0.0, 220.0)
	if is_instance_valid(_fnt):
		te.add_theme_font_override("font", _fnt)
	te.text_changed.connect(func() -> void:
		_raw_text = te.text
		_update_preview())
	_rows_box.add_child(te)
	_rows_box.add_child(_label(TranslationManager.t("原始文本（无法用可视化编辑器解析，已原样保留；可手动编辑）")))


func _render_node(node: Dictionary, container: Control, is_root: bool) -> void:
	var k := str(node.get("kind", ""))
	if k == "group":
		_render_group(node, container, is_root)
	elif k == "tag":
		_render_tag(node, container)
	elif k == "cmp":
		_render_cmp(node, container)
	elif k == "player":
		_render_player(node, container)


func _render_group(node: Dictionary, container: Control, is_root: bool) -> void:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 4)

	# 头部：且/或 + 取反 + （非根）删除
	var hdr := HBoxContainer.new()
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_theme_constant_override("separation", 4)

	var op_ob := _mk_option()
	for p in [["and", "且"], ["or", "或"]]:
		op_ob.add_item(TranslationManager.t(p[1]))
		op_ob.set_item_metadata(op_ob.item_count - 1, p[0])
	_select_by_meta(op_ob, str(node.get("op", "and")))
	op_ob.item_selected.connect(func(_i: int) -> void:
		node["op"] = _meta_of(op_ob)
		_on_model_changed())
	hdr.add_child(op_ob)

	var neg_cb := CheckBox.new()
	neg_cb.text = TranslationManager.t("取反")
	neg_cb.button_pressed = bool(node.get("neg", false))
	neg_cb.toggled.connect(func(v: bool) -> void:
		node["neg"] = v
		_on_model_changed())
	hdr.add_child(neg_cb)

	if not is_root:
		var del := _mk_del_btn()
		del.pressed_id.connect(func(_id: String) -> void:
			_remove_node(node)
			_rebuild_ui())
		hdr.add_child(del)
	vbox.add_child(hdr)

	# 子节点容器
	var child_box := VBoxContainer.new()
	child_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	child_box.add_theme_constant_override("separation", 4)
	vbox.add_child(child_box)
	node["_child_box"] = child_box

	# 添加按钮
	var add_row := HBoxContainer.new()
	add_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_row.add_theme_constant_override("separation", 4)
	var add_cmp := UIBtn.new()
	add_cmp.set_id("dr_add_tag")
	add_cmp.set_label("＋ " + TranslationManager.t("添加条件"))
	add_cmp.custom_minimum_size = Vector2(160.0, UIStyle.BTN_HEIGHT)
	add_cmp.pressed_id.connect(func(_id: String) -> void:
		_add_child(node, {"kind": "tag", "state": _first_state(), "neg": false, "tag": ""}))
	add_row.add_child(add_cmp)
	var add_pl := UIBtn.new()
	add_pl.set_id("dr_add_player")
	add_pl.set_label("＋ " + TranslationManager.t("添加玩家状态"))
	add_pl.custom_minimum_size = Vector2(160.0, UIStyle.BTN_HEIGHT)
	add_pl.pressed_id.connect(func(_id: String) -> void:
		_add_child(node, _new_player()))
	add_row.add_child(add_pl)
	var add_grp := UIBtn.new()
	add_grp.set_id("dr_add_grp")
	add_grp.set_label("＋ " + TranslationManager.t("添加分组"))
	add_grp.custom_minimum_size = Vector2(160.0, UIStyle.BTN_HEIGHT)
	add_grp.pressed_id.connect(func(_id: String) -> void:
		_add_child(node, _new_group()))
	add_row.add_child(add_grp)
	vbox.add_child(add_row)

	container.add_child(vbox)
	for ch in node.get("children", []):
		_render_node(ch, child_box, false)


func _render_tag(node: Dictionary, container: Control) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 4)

	var type_ob := _mk_option()
	for p in PRED_KINDS:
		type_ob.add_item(TranslationManager.t(p[1]))
		type_ob.set_item_metadata(type_ob.item_count - 1, p[0])
	_select_by_meta(type_ob, "tag")
	type_ob.item_selected.connect(func(_i: int) -> void: _convert_node(node, _meta_of(type_ob)))
	row.add_child(type_ob)

	# ★★ 批次 96：「标签名」从**手打**改为「下拉该状态现有标签 + 可手填」。
	#    理由：标签是「状态里某个字符串数组字段的一个元素」，手打时没人知道到底有哪些 —
	#    写错一个字符，条件就永远不成立，而且看不出错在哪。下拉直接列出现有标签（口径同 has_tag）。
	#    ★ 两个控件先建，再建状态下拉 —— 状态下拉的换值回调要**重建标签下拉**，
	#      所以 tag_ob / tag_le 必须先存在于作用域内。
	var tag_ob := _mk_option()
	var tag_le := _mk_line(TranslationManager.t("或手填新标签"))
	_fill_tag_options(tag_ob, str(node.get("state", "")), str(node.get("tag", "")))
	tag_ob.item_selected.connect(func(_i: int) -> void:
		node["tag"] = _read_tag(tag_ob, tag_le)
		_on_model_changed())
	tag_le.text_changed.connect(func(_t: String) -> void:
		node["tag"] = _read_tag(tag_ob, tag_le)
		_on_model_changed())

	var st_ob := _mk_option()
	for fr in _friendly_names():
		st_ob.add_item(TranslationManager.t(fr))
		st_ob.set_item_metadata(st_ob.item_count - 1, fr)
	_select_by_meta(st_ob, str(node.get("state", "")))
	st_ob.item_selected.connect(func(_i: int) -> void:
		node["state"] = _meta_of(st_ob)
		# 换状态 → 标签下拉换一批；当前标签若不在新状态里会临时补一项（往返不丢标签）
		_fill_tag_options(tag_ob, str(node["state"]), str(node.get("tag", "")))
		_on_model_changed())
	row.add_child(st_ob)

	var neg_ob := _mk_option()
	for p in TAG_NEG:
		neg_ob.add_item(TranslationManager.t(p[1]))
		neg_ob.set_item_metadata(neg_ob.item_count - 1, p[0])
	_select_by_meta(neg_ob, str(bool(node.get("neg", false))))
	neg_ob.item_selected.connect(func(_i: int) -> void:
		node["neg"] = (_meta_of(neg_ob) == "true")
		_on_model_changed())
	row.add_child(neg_ob)

	row.add_child(_compound_pair(tag_ob, tag_le))
	row.add_child(_del_btn_for(node))
	container.add_child(row)


# 两个控件并排（下拉 + 手填框）
func _compound_pair(a: Control, b: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_theme_constant_override("separation", 4)
	h.add_child(a)
	h.add_child(b)
	return h


## 标签下拉：列出**该状态现有**的标签（口径同 EventExpr.has_tag：扫该状态所有字符串数组字段）。
## ★ OptionButton.clear() 不复位 selected → 清空后必须显式 select(0)。
## ★ 当前标签不在列表里（刚被移除 / 手工写的）→ 临时补一项，绝不静默丢标签。
func _fill_tag_options(ob: OptionButton, state: String, cur: String) -> void:
	ob.clear()
	ob.add_item(TranslationManager.t(TAG_SENTINEL))
	ob.set_item_metadata(0, TAG_SENTINEL)
	for t in _state_tags(state):
		ob.add_item(str(t))
		ob.set_item_metadata(ob.item_count - 1, str(t))
	if cur != "" and not _has_meta(ob, cur):
		ob.add_item(cur)
		ob.set_item_metadata(ob.item_count - 1, cur)
	if cur == "" or not _select_by_meta(ob, cur):
		ob.select(0)


# 手填框优先（用户显式填了新的），否则用下拉里选的。
func _read_tag(ob: OptionButton, le: LineEdit) -> String:
	var t := le.text.strip_edges()
	if t != "":
		return t
	var v := _meta_of(ob)
	return "" if v == TAG_SENTINEL else v


# 该状态下已有的标签（StateRegistry 提供；不可用时退回空 = 旧的手打行为）
func _state_tags(friendly: String) -> Array[String]:
	if StateRegistry != null and StateRegistry.has_method("all_tags_of"):
		return StateRegistry.all_tags_of(friendly)
	var empty: Array[String] = []
	return empty


func _render_cmp(node: Dictionary, container: Control) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 4)

	var type_ob := _mk_option()
	for p in PRED_KINDS:
		type_ob.add_item(TranslationManager.t(p[1]))
		type_ob.set_item_metadata(type_ob.item_count - 1, p[0])
	_select_by_meta(type_ob, "cmp")
	type_ob.item_selected.connect(func(_i: int) -> void: _convert_node(node, _meta_of(type_ob)))
	row.add_child(type_ob)

	var src_ob := _mk_option()
	for p in SRC_KINDS:
		src_ob.add_item(TranslationManager.t(p[1]))
		src_ob.set_item_metadata(src_ob.item_count - 1, p[0])
	_select_by_meta(src_ob, str(node.get("src", "global")))
	src_ob.item_selected.connect(func(_i: int) -> void:
		node["src"] = _meta_of(src_ob)
		if node["src"] == "state" and str(node.get("state", "")) == "":
			node["state"] = _first_state()
		_rebuild_ui())
	row.add_child(src_ob)

	if str(node.get("src", "global")) == "state":
		var st_ob := _mk_option()
		for fr in _friendly_names():
			st_ob.add_item(TranslationManager.t(fr))
			st_ob.set_item_metadata(st_ob.item_count - 1, fr)
		_select_by_meta(st_ob, str(node.get("state", "")))
		st_ob.item_selected.connect(func(_i: int) -> void:
			node["state"] = _meta_of(st_ob)
			_rebuild_ui())
		row.add_child(st_ob)

		var fld_ob := _mk_option()
		for v in _state_fields(str(node.get("state", ""))):
			fld_ob.add_item(v)
			fld_ob.set_item_metadata(fld_ob.item_count - 1, v)
		var want := str(node.get("name", ""))
		if want != "" and not _has_meta(fld_ob, want):
			fld_ob.add_item(want)
			fld_ob.set_item_metadata(fld_ob.item_count - 1, want)
		_select_by_meta(fld_ob, want)
		fld_ob.item_selected.connect(func(_i: int) -> void:
			node["name"] = _meta_of(fld_ob)
			_on_model_changed())
		row.add_child(fld_ob)
	else:
		var name_le := _mk_line(TranslationManager.t("变量名"))
		name_le.text = str(node.get("name", ""))
		name_le.text_changed.connect(func(t: String) -> void:
			node["name"] = t
			_on_model_changed())
		row.add_child(name_le)

	var op_ob := _mk_option()
	for p in OPS:
		op_ob.add_item(TranslationManager.t(p[1]))
		op_ob.set_item_metadata(op_ob.item_count - 1, p[0])
	_select_by_meta(op_ob, str(node.get("op", ">")))
	op_ob.item_selected.connect(func(_i: int) -> void:
		node["op"] = _meta_of(op_ob)
		_on_model_changed())
	row.add_child(op_ob)

	var val_le := _mk_line(TranslationManager.t("数值"))
	val_le.text = str(node.get("val", ""))
	val_le.text_changed.connect(func(t: String) -> void:
		if str(node.get("valtype", "num")) == "num":
			node["val"] = float(t) if t.is_valid_float() else 0.0
		else:
			node["val"] = t
		_on_model_changed())
	row.add_child(val_le)

	var vt_ob := _mk_option()
	for p in [["num", "数值"], ["str", "文本"]]:
		vt_ob.add_item(TranslationManager.t(p[1]))
		vt_ob.set_item_metadata(vt_ob.item_count - 1, p[0])
	_select_by_meta(vt_ob, str(node.get("valtype", "num")))
	vt_ob.item_selected.connect(func(_i: int) -> void:
		node["valtype"] = _meta_of(vt_ob)
		_rebuild_ui())
	row.add_child(vt_ob)

	row.add_child(_del_btn_for(node))
	container.add_child(row)


# ★ 批次 94：玩家状态行。
# 一行内按 what 动态显隐：活动属性下拉（active/inactive/top/low/weight）
# + 运算符（top/low 用「是/不是」，weight 用数值比较）+ 数值框（仅 weight）。
func _render_player(node: Dictionary, container: Control) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 4)

	var type_ob := _mk_option()
	for p in PRED_KINDS:
		type_ob.add_item(TranslationManager.t(p[1]))
		type_ob.set_item_metadata(type_ob.item_count - 1, p[0])
	_select_by_meta(type_ob, "player")
	type_ob.item_selected.connect(func(_i: int) -> void: _convert_node(node, _meta_of(type_ob)))
	row.add_child(type_ob)

	var what_ob := _mk_option()
	for p in PS_KINDS:
		what_ob.add_item(TranslationManager.t(p[1]))
		what_ob.set_item_metadata(what_ob.item_count - 1, p[0])
	_select_by_meta(what_ob, str(node.get("what", "busy")))
	what_ob.item_selected.connect(func(_i: int) -> void:
		node["what"] = _meta_of(what_ob)
		if _need_activity(str(node.get("what", "busy"))) and str(node.get("act", "")) == "":
			node["act"] = _first_activity()
		_rebuild_ui())
	row.add_child(what_ob)

	var what := str(node.get("what", "busy"))

	if _need_activity(what):
		var act_ob := _mk_option()
		for p in _activity_pairs():
			var pair: Array = p
			act_ob.add_item(TranslationManager.t(str(pair[1])))
			act_ob.set_item_metadata(act_ob.item_count - 1, str(pair[0]))
		var want_act := str(node.get("act", ""))
		if want_act != "" and not _has_meta(act_ob, want_act):
			act_ob.add_item(want_act)     # 未知真值原样保留，绝不静默丢
			act_ob.set_item_metadata(act_ob.item_count - 1, want_act)
		_select_by_meta(act_ob, want_act)
		act_ob.item_selected.connect(func(_i: int) -> void:
			node["act"] = _meta_of(act_ob)
			_on_model_changed())
		row.add_child(act_ob)

	if what == "top" or what == "low":
		var eq_ob := _mk_option()
		for p in EQ_OPS:
			eq_ob.add_item(TranslationManager.t(p[1]))
			eq_ob.set_item_metadata(eq_ob.item_count - 1, p[0])
		_select_by_meta(eq_ob, str(node.get("op", "==")))
		eq_ob.item_selected.connect(func(_i: int) -> void:
			node["op"] = _meta_of(eq_ob)
			_on_model_changed())
		row.add_child(eq_ob)
	elif what == "weight":
		var op_ob := _mk_option()
		for p in OPS:
			op_ob.add_item(TranslationManager.t(p[1]))
			op_ob.set_item_metadata(op_ob.item_count - 1, p[0])
		_select_by_meta(op_ob, str(node.get("op", ">")))
		op_ob.item_selected.connect(func(_i: int) -> void:
			node["op"] = _meta_of(op_ob)
			_on_model_changed())
		row.add_child(op_ob)

		var val_le := _mk_line(TranslationManager.t("权重数值"))
		val_le.text = str(node.get("val", 0))
		val_le.text_changed.connect(func(t: String) -> void:
			node["val"] = float(t) if t.is_valid_float() else 0.0
			_on_model_changed())
		row.add_child(val_le)

	row.add_child(_del_btn_for(node))
	container.add_child(row)


# ================= 模型操作 =================

func _new_group() -> Dictionary:
	return {"kind": "group", "op": "and", "neg": false, "children": []}


## ★ 批次 94：新建玩家状态节点（默认「在忙」）。
func _new_player() -> Dictionary:
	return {"kind": "player", "what": "busy", "act": _first_activity(),
		"op": ">", "val": 1.0, "valtype": "num", "neg": false}


func _add_child(parent: Dictionary, node: Dictionary) -> void:
	if not parent.has("children"):
		parent["children"] = []
	(parent["children"] as Array).append(node)
	_rebuild_ui()


func _remove_node(target: Dictionary) -> void:
	_remove_from(_model, target)


func _remove_from(node: Dictionary, target: Dictionary) -> bool:
	if str(node.get("kind", "")) == "group":
		var ch: Array = node.get("children", [])
		for i in ch.size():
			if ch[i] == target:
				ch.remove_at(i)
				return true
			if _remove_from(ch[i], target):
				return true
	return false


func _convert_node(node: Dictionary, new_kind: String) -> void:
	node.clear()
	if new_kind == "tag":
		node["kind"] = "tag"
		node["state"] = _first_state()
		node["neg"] = false
		node["tag"] = ""
	elif new_kind == "player":
		node["kind"] = "player"
		node["what"] = "busy"
		node["act"] = _first_activity()
		node["op"] = ">"
		node["val"] = 1.0
		node["valtype"] = "num"
		node["neg"] = false
	else:
		node["kind"] = "cmp"
		node["src"] = "global"
		node["state"] = ""
		node["name"] = ""
		node["op"] = ">"
		node["val"] = 0.0
		node["valtype"] = "num"
	_rebuild_ui()


## 该玩家状态子类型是否需要「活动属性」下拉。
func _need_activity(what: String) -> bool:
	return what == "active" or what == "inactive" or what == "top" or what == "low" or what == "weight"


## 活动属性 [真值, 显示名] 表：优先取 BusyState 的权威表，取不到用内置兜底。
func _activity_pairs() -> Array:
	if BusyState != null:
		var a: Variant = BusyState.ACTIVITY_KINDS
		if a is Array and not (a as Array).is_empty():
			return a
	return ACTIVITY_FALLBACK


func _first_activity() -> String:
	var pl := _activity_pairs()
	if pl.is_empty():
		return "game"
	var first: Variant = pl[0]
	if first is Array and not (first as Array).is_empty():
		return str((first as Array)[0])
	return "game"


func _first_state() -> String:
	if StateRegistry != null and StateRegistry.has_method("registered_friendly"):
		var fl: Array[String] = StateRegistry.registered_friendly()
		if fl.size() > 0:
			return fl[0]
	return "荧惑日常状态"


func _friendly_names() -> Array[String]:
	if StateRegistry != null and StateRegistry.has_method("registered_friendly"):
		return StateRegistry.registered_friendly()
	var empty: Array[String] = []
	return empty


func _state_fields(friendly: String) -> Array[String]:
	if StateRegistry != null and StateRegistry.has_method("effective_vars_of"):
		return StateRegistry.effective_vars_of(friendly)
	var empty: Array[String] = []
	return empty


# ================= 序列化 =================

## 数值字面量 → DSL 文本：整数值不带小数尾巴（2.0 → 2）。
## ★ 否则「数值比较」往返会写成 a > 2.0，看着像被改过（数值等价，但人眼别扭）。
func _num_str(v: Variant) -> String:
	var f := float(v)
	if is_equal_approx(f, roundf(f)) and absf(f) < 1000000000000000.0:
		return str(int(roundf(f)))
	return str(f)


func _serialize_node(node: Variant, is_root: bool = false) -> String:
	if node is Dictionary:
		var k := str((node as Dictionary).get("kind", ""))
		if k == "group":
			return _serialize_group(node as Dictionary, is_root)
		if k == "tag":
			var nd: Dictionary = node as Dictionary
			var e := 'has_tag("%s","%s")' % [str(nd.get("state", "")), str(nd.get("tag", ""))]
			if bool(nd.get("neg", false)):
				return "!" + e
			return e
		if k == "cmp":
			var nd: Dictionary = node as Dictionary
			var lhs: String
			if str(nd.get("src", "global")) == "state":
				lhs = 'state_field("%s","%s")' % [str(nd.get("state", "")), str(nd.get("name", ""))]
			else:
				lhs = str(nd.get("name", ""))
			var rhs: String
			if str(nd.get("valtype", "num")) == "num":
				rhs = _num_str(nd.get("val", 0))
			else:
				rhs = '"%s"' % str(nd.get("val", ""))
			return "%s %s %s" % [lhs, str(nd.get("op", ">")), rhs]
		if k == "player":
			return _serialize_player(node as Dictionary)
	return ""


## ★ 批次 94：玩家状态 → EventExpr 语法。
## ★ 「在忙/在闲」「是/否」这类能在表达式内直接表达的取反就地翻转（见 _flip_player）；
##   只有权重数值比较才需要整体套 !( )。
func _serialize_player(nd: Dictionary) -> String:
	var what := str(nd.get("what", "busy"))
	var act := str(nd.get("act", ""))
	var s := ""
	match what:
		"busy":
			s = "player_busy()"
		"idle":
			s = "!player_busy()"
		"active":
			s = 'activity_active("%s")' % act
		"inactive":
			s = '!activity_active("%s")' % act
		"top":
			s = 'activity_top() %s "%s"' % [str(nd.get("op", "==")), act]
		"low":
			s = 'activity_low() %s "%s"' % [str(nd.get("op", "==")), act]
		"weight":
			var rhs := _num_str(nd.get("val", 0))
			if str(nd.get("valtype", "num")) != "num":
				rhs = '"%s"' % str(nd.get("val", ""))
			s = 'activity_weight("%s") %s %s' % [act, str(nd.get("op", ">")), rhs]
		_:
			return ""
	if what == "weight" and bool(nd.get("neg", false)):
		return "!(" + s + ")"
	return s


func _serialize_group(g: Dictionary, is_root: bool = false) -> String:
	var parts: Array[String] = []
	for c in g.get("children", []):
		var s := _serialize_node(c)
		if s != "":
			parts.append(s)
	if parts.is_empty():
		return ""
	# ★ 根分组只有一个子句时不必套括号（子句自身该有括号时已经带了，无优先级歧义）
	#   → 避免「写 player_busy() 被改写成 ( player_busy() )」这种噪音往返。
	if is_root and parts.size() == 1 and str(g.get("op", "and")) == "and" and not bool(g.get("neg", false)):
		return parts[0]
	var inner := (" " + str(g.get("op", "and")) + " ").join(parts)
	if bool(g.get("neg", false)):
		return "!( " + inner + " )"
	return "( " + inner + " )"


# ================= 解析（模型 <— 表达式） =================

func _tokenize(s: String) -> Array:
	var toks: Array = []
	var i := 0
	var n := s.length()
	while i < n:
		var c := s[i]
		if c == " " or c == "\t" or c == "\n" or c == "\r":
			i += 1
			continue
		if c == "(":
			toks.append({"t": "lp", "v": "("}); i += 1; continue
		if c == ")":
			toks.append({"t": "rp", "v": ")"}); i += 1; continue
		if c == ",":
			toks.append({"t": "comma", "v": ","}); i += 1; continue
		if c == "'" or c == "\"":
			var quote := c
			var j := i + 1
			var sb := ""
			while j < n:
				if s[j] == quote:
					break
				if s[j] == "\\" and j + 1 < n:
					sb += s[j + 1]; j += 2; continue
				sb += s[j]; j += 1
			if j >= n:
				return []
			toks.append({"t": "str", "v": sb}); i = j + 1; continue
		if c == ">" or c == "<" or c == "=" or c == "!":
			var two := s.substr(i, 2)
			if two == "==" or two == "<=" or two == ">=" or two == "!=":
				toks.append({"t": "op", "v": two}); i += 2; continue
			if c == "!":
				toks.append({"t": "not", "v": "!"}); i += 1; continue
			if c == "=":
				return []
			toks.append({"t": "op", "v": c}); i += 1; continue
		if c == "+" or c == "-" or c == "*" or c == "/":
			return []   # 算术：可视化编辑器不支持，交原始模式
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_":
			var j := i
			while j < n and ((s[j] >= "a" and s[j] <= "z") or (s[j] >= "A" and s[j] <= "Z") or (s[j] >= "0" and s[j] <= "9") or s[j] == "_"):
				j += 1
			var word := s.substr(i, j - i)
			var lw := word.to_lower()
			if lw == "and" or lw == "or":
				toks.append({"t": "logic", "v": lw})
			elif FUNC_NAMES.has(lw):
				toks.append({"t": "func", "v": word})
			else:
				toks.append({"t": "ident", "v": word})
			i = j; continue
		if (c >= "0" and c <= "9") or (c == "." and i + 1 < n and s[i + 1] >= "0" and s[i + 1] <= "9"):
			var j := i
			while j < n and ((s[j] >= "0" and s[j] <= "9") or s[j] == "."):
				j += 1
			toks.append({"t": "num", "v": s.substr(i, j - i)}); i = j; continue
		return []
	return toks


func _parse_expr_to_model(src: String) -> Dictionary:
	_perr = false
	_ptoks = _tokenize(src)
	if _ptoks.is_empty():
		if src.strip_edges() == "":
			return _new_group()
		return {}
	_ppi = 0
	if _ppi >= _ptoks.size():
		return _new_group()
	var node := _p_or()
	if _perr or _ppi < _ptoks.size():
		return {}
	return node


func _peek(t: String) -> bool:
	if _ppi >= _ptoks.size():
		return false
	return (_ptoks[_ppi] as Dictionary)["t"] == t


func _peek_logic(v: String) -> bool:
	if _ppi >= _ptoks.size():
		return false
	var tk: Dictionary = _ptoks[_ppi]
	return tk["t"] == "logic" and tk["v"] == v


func _peek_op() -> bool:
	if _ppi >= _ptoks.size():
		return false
	return (_ptoks[_ppi] as Dictionary)["t"] == "op"


func _p_or() -> Dictionary:
	var children: Array = [_p_and()]
	while not _perr and _peek_logic("or"):
		_ppi += 1
		children.append(_p_and())
	if children.size() == 1:
		return children[0]
	return {"kind": "group", "op": "or", "neg": false, "children": children}


func _p_and() -> Dictionary:
	var children: Array = [_p_not()]
	while not _perr and _peek_logic("and"):
		_ppi += 1
		children.append(_p_not())
	if children.size() == 1:
		return children[0]
	return {"kind": "group", "op": "and", "neg": false, "children": children}


func _p_not() -> Dictionary:
	if _peek("not"):
		_ppi += 1
		var inner := _p_not()
		var k := str(inner.get("kind", ""))
		if k == "group" or k == "tag":
			inner["neg"] = not bool(inner.get("neg", false))
			return inner
		if k == "player":
			_flip_player(inner)
			return inner
		return {"kind": "group", "op": "and", "neg": true, "children": [inner]}
	return _p_primary()


## 玩家状态节点取反：能在自身表达式里直接翻转的就地翻，其余走 neg（序列化成 !( )）。
func _flip_player(n: Dictionary) -> void:
	match str(n.get("what", "busy")):
		"busy":
			n["what"] = "idle"
		"idle":
			n["what"] = "busy"
		"active":
			n["what"] = "inactive"
		"inactive":
			n["what"] = "active"
		"top", "low":
			n["op"] = "!=" if str(n.get("op", "==")) == "==" else "=="
		_:
			n["neg"] = not bool(n.get("neg", false))


func _p_primary() -> Dictionary:
	var a: Variant = _p_atom()
	if _perr:
		return {}
	if a is Dictionary and (a as Dictionary).has("__lhs"):
		var ad: Dictionary = a as Dictionary
		if not _peek_op():
			_perr = true
			return {}
		var op: String = (_ptoks[_ppi] as Dictionary)["v"]
		_ppi += 1
		var rhs := _p_rhs()
		if _perr:
			return {}
		# ★ 玩家状态的「可比较左侧」（权重 / 最高 / 最低）→ player 节点
		if bool(ad.get("__player", false)):
			var what := str(ad.get("what", "weight"))
			var act := str(ad.get("act", ""))
			# ★ 最高/最低的活动属性写在**比较右侧**（activity_top() == "game"）→ 从这里取，
			#   否则会把 activity_top() == "game" 反序列化成 activity_top() == ""
			if act == "":
				act = str(rhs["val"])
			return {"kind": "player", "what": what, "act": act, "op": op,
				"val": rhs["val"], "valtype": rhs["vt"], "neg": false}
		return {"kind": "cmp", "src": ad.get("src", "global"), "state": ad.get("state", ""),
			"name": ad.get("name", ""), "op": op, "val": rhs["val"], "valtype": rhs["vt"]}
	var pred: Dictionary = a as Dictionary
	if _peek_op():
		_perr = true
		return {}
	return pred


func _p_atom() -> Variant:
	if _ppi >= _ptoks.size():
		_perr = true
		return {}
	var tk: Dictionary = _ptoks[_ppi]
	if tk["t"] == "lp":
		_ppi += 1
		var node := _p_or()
		if _perr:
			return {}
		if not _peek("rp"):
			_perr = true
			return {}
		_ppi += 1
		return node
	if tk["t"] == "func":
		var name: String = tk["v"]
		_ppi += 1
		if not _peek("lp"):
			_perr = true
			return {}
		_ppi += 1
		# ★ 批次 94：参数个数改为**按实际读取**（旧实现写死 2 个，容不下 0/1 参函数）
		var args: Array = []
		if not _peek("rp"):
			args.append(_p_arg())
			while not _perr and _peek("comma"):
				_ppi += 1
				args.append(_p_arg())
		if _perr:
			return {}
		if not _peek("rp"):
			_perr = true
			return {}
		_ppi += 1
		return _func_to_model(name, args)
	if tk["t"] == "ident":
		_ppi += 1
		return {"__lhs": true, "src": "global", "name": tk["v"]}
	_perr = true
	return {}


## 函数调用 → 模型节点。参数个数不符 → _perr（整句交原始模式，绝不丢内容）。
func _func_to_model(name: String, args: Array) -> Variant:
	match name:
		"has_tag":
			if args.size() != 2:
				_perr = true
				return {}
			return {"kind": "tag", "state": str(args[0]), "neg": false, "tag": str(args[1])}
		"state_field":
			if args.size() != 2:
				_perr = true
				return {}
			return {"__lhs": true, "src": "state", "state": str(args[0]), "name": str(args[1])}
		"player_busy":
			if not args.is_empty():
				_perr = true
				return {}
			return {"kind": "player", "what": "busy", "act": "", "op": ">",
				"val": 0.0, "valtype": "num", "neg": false}
		"activity_active":
			if args.size() != 1:
				_perr = true
				return {}
			return {"kind": "player", "what": "active", "act": str(args[0]), "op": ">",
				"val": 0.0, "valtype": "num", "neg": false}
		"activity_weight":
			if args.size() != 1:
				_perr = true
				return {}
			return {"__lhs": true, "__player": true, "what": "weight", "act": str(args[0])}
		"activity_top":
			if not args.is_empty():
				_perr = true
				return {}
			return {"__lhs": true, "__player": true, "what": "top", "act": ""}
		"activity_low":
			if not args.is_empty():
				_perr = true
				return {}
			return {"__lhs": true, "__player": true, "what": "low", "act": ""}
	_perr = true
	return {}


func _p_arg() -> Variant:
	if _ppi >= _ptoks.size():
		_perr = true
		return ""
	var tk: Dictionary = _ptoks[_ppi]
	if tk["t"] == "str" or tk["t"] == "num":
		_ppi += 1
		return tk["v"]
	_perr = true
	return ""


func _p_rhs() -> Dictionary:
	if _ppi >= _ptoks.size():
		_perr = true
		return {"val": 0.0, "vt": "num"}
	var tk: Dictionary = _ptoks[_ppi]
	if tk["t"] == "num":
		_ppi += 1
		return {"val": float(tk["v"]), "vt": "num"}
	if tk["t"] == "str":
		_ppi += 1
		return {"val": tk["v"], "vt": "str"}
	_perr = true
	return {"val": 0.0, "vt": "num"}


# ================= 写回 / 关闭 =================

func _on_model_changed() -> void:
	_write_back()
	_update_preview()


func _write_back() -> void:
	if _source_le == null:
		return
	if _raw_mode:
		_source_le.text = _raw_text
	else:
		_source_le.text = _serialize_node(_model, true)


func _update_preview() -> void:
	if _preview_label == null:
		return
	if _raw_mode:
		_preview_label.text = TranslationManager.t("预览") + "：\n" + _raw_text
		return
	var txt := _serialize_node(_model, true)
	if txt == "":
		_preview_label.text = TranslationManager.t("预览") + "：\n（空 = 始终显示）"
	else:
		var ok := EventExpr.is_well_formed(txt)
		var mark := TranslationManager.t("语法有效") if ok else TranslationManager.t("语法错误")
		_preview_label.text = TranslationManager.t("预览") + "：\n" + txt + "\n[ " + mark + " ]"


func close() -> void:
	if _closed_emitted:
		return
	_closed_emitted = true
	_write_back()
	closed.emit()
	queue_free()


# ================= 小工具 =================

func _mk_option() -> OptionButton:
	var ob := OptionButton.new()
	if is_instance_valid(_fnt):
		ob.add_theme_font_override("font", _fnt)
	ob.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return ob


func _mk_line(placeholder: String) -> LineEdit:
	var le := LineEdit.new()
	le.placeholder_text = placeholder
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if is_instance_valid(_fnt):
		le.add_theme_font_override("font", _fnt)
	UIStyle.apply_line_edit_style(le)
	return le


func _mk_del_btn() -> UIBtn:
	var del := UIBtn.new()
	del.set_id("del_node")
	del.set_label("−")
	del.custom_minimum_size = Vector2(TITLE_BAR_H, UIStyle.BTN_HEIGHT)
	del.size = Vector2(TITLE_BAR_H, UIStyle.BTN_HEIGHT)
	del.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return del


func _del_btn_for(node: Dictionary) -> UIBtn:
	var del := _mk_del_btn()
	del.pressed_id.connect(func(_id: String) -> void:
		_remove_node(node)
		_rebuild_ui())
	return del


func _label(text: String) -> Label:
	var lb := Label.new()
	lb.text = text
	lb.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	lb.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_fnt):
		lb.add_theme_font_override("font", _fnt)
	return lb


func _meta_of(ob: OptionButton) -> String:
	if ob == null or ob.selected < 0:
		return ""
	return str(ob.get_item_metadata(ob.selected))


func _select_by_meta(ob: OptionButton, value: String) -> bool:
	for i in ob.item_count:
		if str(ob.get_item_metadata(i)) == value:
			ob.select(i)
			return true
	return false


func _has_meta(ob: OptionButton, value: String) -> bool:
	for i in ob.item_count:
		if str(ob.get_item_metadata(i)) == value:
			return true
	return false


## ★ 批次 94：多开时层叠错开 —— 把整页相对默认位置再偏移一点（页面视觉就是 _bg）。
func set_origin_offset(off: Vector2) -> void:
	if is_instance_valid(_bg):
		_bg.position += off


## 最小化 / 还原：折叠只隐藏内容，顶栏（标题 + 拖动把柄 + 最小化 + 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.apply(self, _min_btn, v, _min_btn.get_parent() if is_instance_valid(_min_btn) else null)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
