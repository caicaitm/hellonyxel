# ui/behavior_picker_panel.gd
# 行为选择窗：仿 ui/tag_picker_panel.gd 的手动定位风格。
#
# 列出「预设行为」与「已存行为脚本（res://behaviors）」，勾选即加入本积木的 behaviors 列表；
# 列表顺序 = 优先级（前高后低）。提供「已选顺序」列表，可 ▲上移 / ▼下移 / ✕删除 调整优先级。
# 确定后把逗号列表回填源 LineEdit。
class_name BehaviorPickerPanel
extends Control

const WIDTH: float = 580.0
const TITLE_H: float = 34.0
const FOOTER_H: float = 44.0
const PAD: float = 10.0
const FORM_FONT: int = 14

signal closed

var _dim: ColorRect
var _bg: UIPanel
var _title_label: Label
var _close_btn: UIBtn
var _scroll: ScrollContainer
var _content: VBoxContainer
var _source_edit: LineEdit = null
var _current: Array[String] = []          # 已选行为规格（顺序 = 优先级，前高后低）
var _custom_box: VBoxContainer = null     # 持久化「自定义规格」输入区（重建列表时不销毁）
var _custom_edit: LineEdit = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(WIDTH, 200.0)
	_build_ui()
	visible = false


func _build_ui() -> void:
	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 0.42)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.gui_input.connect(_on_dim_input)
	add_child(_dim)

	_bg = UIPanel.new()
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	var fnt = UIStyle.get_cjk_font()

	_title_label = Label.new()
	_title_label.text = "行为选择（勾选=启用；列表顺序=优先级，前高后低）"
	_title_label.position = Vector2(PAD, 4.0)
	_title_label.size = Vector2(WIDTH - PAD * 2.0 - 40.0, TITLE_H)
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", Color(0.75, 0.92, 1.0))
	_title_label.add_theme_font_size_override("font_size", int(UIStyle.FONT_SIZE) + 1)
	if is_instance_valid(fnt):
		_title_label.add_theme_font_override("font", fnt)
	add_child(_title_label)

	_close_btn = UIBtn.new()
	_close_btn.set_id("close")
	_close_btn.set_label("×")
	_close_btn.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_close_btn.anchor_left = 1.0
	_close_btn.anchor_right = 1.0
	_close_btn.offset_left = -(TITLE_H + 2.0)
	_close_btn.offset_top = 3.0
	_close_btn.offset_right = -PAD
	_close_btn.offset_bottom = TITLE_H + 3.0
	_close_btn.pressed_id.connect(_on_close_pressed)
	add_child(_close_btn)

	_scroll = ScrollContainer.new()
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.offset_left = PAD
	_scroll.offset_right = -PAD
	_scroll.offset_top = TITLE_H
	_scroll.offset_bottom = -FOOTER_H
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 6)
	_scroll.add_child(_content)

	# 持久化「自定义行为规格」输入区（支持直接输入组合节点，如 sel(if_tag(警报,hold_position),random_patrol)）
	_custom_box = VBoxContainer.new()
	_custom_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_custom_box.add_theme_constant_override("separation", 4)
	_custom_box.add_child(_section_label("自定义行为规格（支持组合节点，如 sel(if_tag(警报,hold_position),random_patrol)）"))
	var crow := HBoxContainer.new()
	crow.add_theme_constant_override("separation", 6)
	_custom_edit = LineEdit.new()
	_custom_edit.placeholder_text = "输入行为规格（回车或点添加；可含组合节点）"
	_custom_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_custom_edit.text_submitted.connect(_on_custom_submitted)
	crow.add_child(_custom_edit)
	var cadd := UIBtn.new()
	cadd.set_id("add_custom")
	cadd.set_label("添加")
	cadd.custom_minimum_size = Vector2(60.0, UIStyle.BTN_HEIGHT)
	cadd.pressed_id.connect(_on_custom_add_pressed)
	crow.add_child(cadd)
	_custom_box.add_child(crow)

	# 底部按钮行：确定 / 取消
	var footer := HBoxContainer.new()
	footer.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	footer.anchor_left = 1.0
	footer.anchor_right = 1.0
	footer.anchor_top = 1.0
	footer.anchor_bottom = 1.0
	footer.offset_left = -260.0
	footer.offset_right = -PAD
	footer.offset_top = -FOOTER_H + 4.0
	footer.offset_bottom = -4.0
	footer.add_theme_constant_override("separation", 8)
	_bg.add_child(footer)
	var cancel := UIBtn.new()
	cancel.set_id("cancel")
	cancel.set_label("取消")
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.custom_minimum_size = Vector2(0, UIStyle.BTN_HEIGHT)
	cancel.pressed_id.connect(_on_close_pressed)
	footer.add_child(cancel)
	var ok := UIBtn.new()
	ok.set_id("ok")
	ok.set_label("确定")
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ok.custom_minimum_size = Vector2(0, UIStyle.BTN_HEIGHT)
	ok.pressed_id.connect(_on_ok_pressed)
	footer.add_child(ok)


# ==================== 公开方法 ====================

func open(source: LineEdit) -> void:
	_source_edit = source
	_current = _specs_from_text(source.text if source else "")
	if is_instance_valid(_custom_edit):
		_custom_edit.text = ""
	_rebuild()
	var vp := UIStyle.canvas_viewport_size(self)
	var natural := _content.get_combined_minimum_size()
	var h: float = clampf(natural.y + TITLE_H + FOOTER_H + PAD * 2.0 + 8.0, 200.0, vp.y - 40.0)
	size = Vector2(WIDTH, h)
	position = (vp - size) * 0.5
	queue_redraw()
	visible = true


func close() -> void:
	visible = false
	if is_inside_tree():
		get_viewport().gui_release_focus()
	closed.emit()
	queue_free()


func is_open() -> bool:
	return visible


# ==================== 内部：构建 ====================

func _rebuild() -> void:
	for c in _content.get_children():
		if c == _custom_box:
			continue   # 持久输入区不销毁
		_content.remove_child(c)
		c.queue_free()

	# 预设行为
	_content.add_child(_section_label("预设行为（勾选=启用）"))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 4)
	_content.add_child(grid)
	for spec in BlockBehaviors.PRESETS:
		grid.add_child(_check(spec))

	# 已存脚本
	_content.add_child(_section_label("已存行为脚本（挂载到本积木）"))
	var sgrid := GridContainer.new()
	sgrid.columns = 2
	sgrid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sgrid.add_theme_constant_override("h_separation", 14)
	sgrid.add_theme_constant_override("v_separation", 4)
	_content.add_child(sgrid)
	var scripts := BehaviorFile.list_scripts()
	if scripts.is_empty():
		var hint := Label.new()
		hint.text = "（暂无；可在调试面板「编辑积木行为脚本」里新建）"
		hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
		sgrid.add_child(hint)
	else:
		for s in scripts:
			sgrid.add_child(_check(BlockBehaviors.SCRIPT_PREFIX + s))

	# 已选（优先级）
	_content.add_child(_section_label("已选顺序（前=高优先级；▲上移 ▼下移 ✕删除）"))
	var order_box := VBoxContainer.new()
	order_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	order_box.add_theme_constant_override("separation", 4)
	_content.add_child(order_box)
	if _current.is_empty():
		var none := Label.new()
		none.text = "（未选）"
		none.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
		order_box.add_child(none)
	else:
		for i in _current.size():
			order_box.add_child(_order_row(_current[i], i))

	# 自定义输入区固定置于列表末尾
	if is_instance_valid(_custom_box) and _custom_box.get_parent() == _content:
		_content.move_child(_custom_box, -1)


func _check(spec: String) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = BlockBehaviors.display_name(spec)
	cb.button_pressed = (spec in _current)
	cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cb.toggled.connect(_on_check_toggled.bind(spec))
	return cb


func _order_row(spec: String, i: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lab := Label.new()
	lab.text = "%d. %s" % [i + 1, BlockBehaviors.display_name(spec)]
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lab.add_theme_color_override("font_color", Color.WHITE)
	row.add_child(lab)
	if i > 0:
		row.add_child(_order_btn("▲", spec, "up"))
	if i < _current.size() - 1:
		row.add_child(_order_btn("▼", spec, "down"))
	row.add_child(_order_btn("✕", spec, "del"))
	return row


func _order_btn(label: String, spec: String, action: String) -> UIBtn:
	var b := UIBtn.new()
	b.set_id(action)
	b.set_label(label)
	b.custom_minimum_size = Vector2(28.0, 24.0)
	b.size = Vector2(28.0, 24.0)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.pressed_id.connect(_on_order_pressed.bind(spec, action))
	return b


func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.75, 0.92, 1.0))
	l.add_theme_font_size_override("font_size", int(UIStyle.FONT_SIZE))
	var fnt = UIStyle.get_cjk_font()
	if is_instance_valid(fnt):
		l.add_theme_font_override("font", fnt)
	return l


# ==================== 内部：事件 ====================

func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		close()


func _on_close_pressed(_id: String) -> void:
	close()


func _on_ok_pressed(_id: String) -> void:
	if _source_edit != null and is_instance_valid(_source_edit):
		_source_edit.text = ",".join(_current)
	close()


func _on_check_toggled(on: bool, spec: String) -> void:
	if on:
		if not (spec in _current):
			_current.append(spec)
	else:
		var idx := _current.find(spec)
		if idx >= 0:
			_current.remove_at(idx)
	_rebuild()


func _on_order_pressed(_id: String, spec: String, action: String) -> void:
	var idx := _current.find(spec)
	if idx < 0:
		return
	if action == "up" and idx > 0:
		_current.insert(idx - 1, _current[idx])
		_current.remove_at(idx + 1)
	elif action == "down" and idx < _current.size() - 1:
		_current.insert(idx + 2, _current[idx])
		_current.remove_at(idx)
	elif action == "del":
		_current.remove_at(idx)
	_rebuild()


# ==================== 内部：文本解析 ====================

# 顶层逗号切分（用 BlockBehaviors.split_top_level，兼容组合节点 sel(a,b) 内部的逗号）。
func _specs_from_text(s: String) -> Array[String]:
	var out: Array[String] = []
	for part in BlockBehaviors.split_top_level(s):
		var t := str(part).strip_edges()
		if not t.is_empty() and not (t in out):
			out.append(t)
	return out


# ==================== 内部：自定义规格输入 ====================

func _on_custom_submitted(_t: String) -> void:
	_add_custom()


func _on_custom_add_pressed(_id: String) -> void:
	_add_custom()


func _add_custom() -> void:
	if not is_instance_valid(_custom_edit):
		return
	var raw := _custom_edit.text.strip_edges()
	if raw.is_empty():
		return
	# 支持一次粘贴多个（顶层逗号分隔，兼容组合节点内部逗号）
	for p in BlockBehaviors.split_top_level(raw):
		var t := str(p).strip_edges()
		if not t.is_empty() and not (t in _current):
			_current.append(t)
	_custom_edit.text = ""
	_rebuild()
