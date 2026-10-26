# ui/behavior_script_editor_panel.gd
# 「编辑行为」页面：管理 res://behaviors 下的行为脚本（与事件链编辑器同级的英文名目录）。
#
# 左侧：脚本列表（点选载入 / 新建 / 删除）。
# 右侧：编辑选中脚本的 behaviors 列表（顺序=优先级，可 ▲上移 ▼下移 ✕删除），
#       并可「添加预设行为」或「添加脚本引用」（挂载其它脚本），最后 保存 写盘。
#
# 行为脚本结构见 ui/behavior_file.gd：{ "version", "name", "behaviors": [...] }。
class_name BehaviorScriptEditorPanel
extends Control

const WIDTH: float = 640.0
const HEIGHT: float = 480.0
const TITLE_H: float = 34.0
const PAD: float = 10.0
const FORM_FONT: int = 14
const LIST_W: float = 200.0

signal closed

var _dim: ColorRect
var _bg: UIPanel
var _title_label: Label
var _close_btn: UIBtn
var _list_scroll: ScrollContainer
var _list_box: VBoxContainer
var _name_input: LineEdit
var _del_btn: UIBtn
var _edit_scroll: ScrollContainer
var _edit_box: VBoxContainer
var _preset_add: OptionButton
var _script_add: OptionButton
var _custom_edit: LineEdit = null   # 自定义行为规格输入（支持组合节点）

var _selected: String = ""                 # 当前编辑的脚本名
var _edit_behaviors: PackedStringArray = [] # 当前编辑的 behaviors 工作副本


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(WIDTH, HEIGHT)
	_build_ui()
	_refresh_list()
	_center()


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
	_title_label.text = "编辑行为（res://behaviors）"
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

	# ---- 左侧：脚本列表 ----
	_list_scroll = ScrollContainer.new()
	_list_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_list_scroll.offset_left = PAD
	_list_scroll.offset_right = -(WIDTH - PAD - LIST_W)
	_list_scroll.offset_top = TITLE_H + PAD
	_list_scroll.offset_bottom = -PAD - 36.0
	_list_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_list_scroll)
	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", 4)
	_list_scroll.add_child(_list_box)

	var new_btn := UIBtn.new()
	new_btn.set_id("new")
	new_btn.set_label("＋ 新建脚本")
	new_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_btn.custom_minimum_size = Vector2(LIST_W, UIStyle.BTN_HEIGHT)
	new_btn.position = Vector2(PAD, HEIGHT - PAD - 30.0)
	new_btn.pressed_id.connect(_on_new_pressed)
	add_child(new_btn)

	# ---- 右侧：编辑区 ----
	var rx := PAD + LIST_W + PAD
	var rw := WIDTH - rx - PAD
	_name_input = LineEdit.new()
	_name_input.placeholder_text = "脚本名（英文，不含扩展名）"
	_name_input.position = Vector2(rx, TITLE_H + PAD)
	_name_input.size = Vector2(rw - 90.0, UIStyle.BTN_HEIGHT)
	_name_input.add_theme_color_override("font_color", Color.WHITE)
	_name_input.add_theme_color_override("placeholder_color", Color(1, 1, 1, 0.5))
	_name_input.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_name_input)

	_del_btn = UIBtn.new()
	_del_btn.set_id("delete")
	_del_btn.set_label("删除")
	_del_btn.position = Vector2(rx + rw - 86.0, TITLE_H + PAD)
	_del_btn.size = Vector2(86.0, UIStyle.BTN_HEIGHT)
	_del_btn.pressed_id.connect(_on_delete_pressed)
	add_child(_del_btn)

	var list_label := Label.new()
	list_label.text = "行为列表（前=高优先级；▲上移 ▼下移 ✕删除）"
	list_label.position = Vector2(rx, TITLE_H + PAD + 34.0)
	list_label.size = Vector2(rw, 22.0)
	list_label.add_theme_color_override("font_color", Color(0.75, 0.92, 1.0))
	add_child(list_label)

	_edit_scroll = ScrollContainer.new()
	_edit_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_edit_scroll.offset_left = rx
	_edit_scroll.offset_right = -(PAD)
	_edit_scroll.offset_top = TITLE_H + PAD + 58.0
	_edit_scroll.offset_bottom = -(PAD + 96.0)
	_edit_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_edit_scroll)
	_edit_box = VBoxContainer.new()
	_edit_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit_box.add_theme_constant_override("separation", 4)
	_edit_scroll.add_child(_edit_box)

	# 底部：添加预设 / 添加脚本引用 / 保存
	var footer := HBoxContainer.new()
	footer.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	footer.anchor_left = 1.0
	footer.anchor_right = 1.0
	footer.anchor_top = 1.0
	footer.anchor_bottom = 1.0
	footer.offset_left = -rw
	footer.offset_right = -PAD
	footer.offset_top = -(PAD + 60.0)
	footer.offset_bottom = -PAD
	footer.add_theme_constant_override("separation", 6)
	_bg.add_child(footer)

	_preset_add = OptionButton.new()
	_preset_add.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_add.add_item("＋ 添加预设行为")
	for spec in BlockBehaviors.PRESETS:
		_preset_add.add_item(BlockBehaviors.display_name(spec))
	_preset_add.item_selected.connect(_on_preset_selected)
	footer.add_child(_preset_add)

	_script_add = OptionButton.new()
	_script_add.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_script_add.add_item("＋ 添加脚本引用")
	_script_add.item_selected.connect(_on_script_selected)
	footer.add_child(_script_add)

	var save := UIBtn.new()
	save.set_id("save")
	save.set_label("保存")
	save.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save.custom_minimum_size = Vector2(80.0, UIStyle.BTN_HEIGHT)
	save.pressed_id.connect(_on_save_pressed)
	footer.add_child(save)

	# 自定义行为规格输入（支持直接输入组合节点，如 sel(if_tag(警报,hold_position),random_patrol)）
	var custom_row := HBoxContainer.new()
	custom_row.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	custom_row.anchor_left = 1.0
	custom_row.anchor_right = 1.0
	custom_row.anchor_top = 1.0
	custom_row.anchor_bottom = 1.0
	custom_row.offset_left = -rw
	custom_row.offset_right = -PAD
	custom_row.offset_top = -(PAD + 92.0)
	custom_row.offset_bottom = -(PAD + 64.0)
	custom_row.add_theme_constant_override("separation", 6)
	_bg.add_child(custom_row)
	var clab := Label.new()
	clab.text = "自定义："
	clab.add_theme_color_override("font_color", Color(0.75, 0.92, 1.0))
	custom_row.add_child(clab)
	_custom_edit = LineEdit.new()
	_custom_edit.placeholder_text = "输入行为规格（含组合节点），回车或点添加"
	_custom_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_custom_edit.text_submitted.connect(_on_custom_script_submitted)
	custom_row.add_child(_custom_edit)
	var cadd2 := UIBtn.new()
	cadd2.set_id("add_custom")
	cadd2.set_label("添加")
	cadd2.custom_minimum_size = Vector2(60.0, UIStyle.BTN_HEIGHT)
	cadd2.pressed_id.connect(_on_custom_script_add_pressed)
	custom_row.add_child(cadd2)


# ==================== 公开 ====================

func close() -> void:
	visible = false
	if is_inside_tree():
		get_viewport().gui_release_focus()
	closed.emit()
	queue_free()


func is_open() -> bool:
	return visible


# ==================== 列表 ====================

func _refresh_list() -> void:
	for c in _list_box.get_children():
		_list_box.remove_child(c)
		c.queue_free()
	var scripts := BehaviorFile.list_scripts()
	if scripts.is_empty():
		var none := Label.new()
		none.text = "（暂无脚本）"
		none.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
		_list_box.add_child(none)
	else:
		for s in scripts:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 4)
			var lab := UIBtn.new()
			lab.set_id("open")
			lab.set_label(s)
			lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			lab.custom_minimum_size = Vector2(0, UIStyle.BTN_HEIGHT)
			lab.pressed_id.connect(_on_open_pressed.bind(s))
			row.add_child(lab)
			_list_box.add_child(row)
	# 刷新「添加脚本引用」下拉（排除当前脚本）
	_script_add.clear()
	_script_add.add_item("＋ 添加脚本引用")
	for s in scripts:
		if s != _selected:
			_script_add.add_item(s)


# ==================== 编辑列表 ====================

func _rebuild_edit_list() -> void:
	for c in _edit_box.get_children():
		_edit_box.remove_child(c)
		c.queue_free()
	if _selected.is_empty():
		var hint := Label.new()
		hint.text = "（左侧点选一个脚本，或点「新建脚本」）"
		hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
		_edit_box.add_child(hint)
		return
	if _edit_behaviors.is_empty():
		var none := Label.new()
		none.text = "（空：用下方下拉添加行为）"
		none.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
		_edit_box.add_child(none)
		return
	for i in _edit_behaviors.size():
		_edit_box.add_child(_behavior_row(_edit_behaviors[i], i))


func _behavior_row(spec: String, i: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lab := Label.new()
	lab.text = "%d. %s" % [i + 1, BlockBehaviors.display_name(spec)]
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lab.add_theme_color_override("font_color", Color.WHITE)
	row.add_child(lab)
	if i > 0:
		row.add_child(_ob("▲", spec, "up"))
	if i < _edit_behaviors.size() - 1:
		row.add_child(_ob("▼", spec, "down"))
	row.add_child(_ob("✕", spec, "del"))
	return row


func _ob(label: String, spec: String, action: String) -> UIBtn:
	var b := UIBtn.new()
	b.set_id(action)
	b.set_label(label)
	b.custom_minimum_size = Vector2(28.0, 24.0)
	b.size = Vector2(28.0, 24.0)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.pressed_id.connect(_on_behavior_reorder.bind(spec, action))
	return b


# ==================== 事件 ====================

func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		close()


func _on_close_pressed(_id: String) -> void:
	close()


func _on_new_pressed(_id: String) -> void:
	var name := _name_input.text.strip_edges()
	if name.is_empty():
		name = "behavior_%d" % (BehaviorFile.list_scripts().size() + 1)
		name = name.replace(" ", "_")
	if BehaviorFile.script_exists(name):
		_name_input.text = name
		_name_input.placeholder_text = "脚本名已存在，换一个"
		return
	BehaviorFile.write_script(name, PackedStringArray())
	_selected = name
	_edit_behaviors = PackedStringArray()
	_name_input.text = name
	_refresh_list()
	_rebuild_edit_list()


func _on_open_pressed(_id: String, name: String) -> void:
	_selected = name
	_name_input.text = name
	_edit_behaviors = BehaviorFile.read_behaviors(name)
	_refresh_list()
	_rebuild_edit_list()


func _on_delete_pressed(_id: String) -> void:
	if _selected.is_empty():
		return
	BehaviorFile.delete_script(_selected)
	_selected = ""
	_edit_behaviors = PackedStringArray()
	_name_input.text = ""
	_refresh_list()
	_rebuild_edit_list()


func _on_save_pressed(_id: String) -> void:
	var name := _name_input.text.strip_edges()
	if name.is_empty():
		return
	_selected = name
	BehaviorFile.write_script(name, _edit_behaviors)
	_refresh_list()
	print("[BehaviorScriptEditor] 已保存脚本: %s (%d 个行为)" % [name, _edit_behaviors.size()])


func _on_preset_selected(index: int) -> void:
	if index <= 0:
		return
	var spec: String = BlockBehaviors.PRESETS[index - 1]
	_edit_behaviors.append(spec)
	_rebuild_edit_list()
	_preset_add.select(0)


func _on_behavior_reorder(_id: String, spec: String, action: String) -> void:
	var idx := _edit_behaviors.find(spec)
	if idx < 0:
		return
	if action == "up" and idx > 0:
		_edit_behaviors.insert(idx - 1, _edit_behaviors[idx])
		_edit_behaviors.remove_at(idx + 1)
	elif action == "down" and idx < _edit_behaviors.size() - 1:
		_edit_behaviors.insert(idx + 2, _edit_behaviors[idx])
		_edit_behaviors.remove_at(idx)
	elif action == "del":
		_edit_behaviors.remove_at(idx)
	_rebuild_edit_list()


func _on_script_selected(index: int) -> void:
	if index <= 0:
		return
	var name: String = _script_add.get_item_text(index)
	_edit_behaviors.append(BlockBehaviors.SCRIPT_PREFIX + name)
	_rebuild_edit_list()
	_script_add.select(0)


func _on_custom_script_submitted(_t: String) -> void:
	_add_custom_behavior()


func _on_custom_script_add_pressed(_id: String) -> void:
	_add_custom_behavior()


# 添加自定义规格（支持顶层逗号分隔的多个，兼容组合节点内部逗号）。
# 仅在已选中某脚本时生效；不去重校验合法性（标签/组合节点可任意，运行时惰性解析）。
func _add_custom_behavior() -> void:
	if not is_instance_valid(_custom_edit) or _selected.is_empty():
		return
	var raw := _custom_edit.text.strip_edges()
	if raw.is_empty():
		return
	for p in BlockBehaviors.split_top_level(raw):
		var t := str(p).strip_edges()
		if not t.is_empty() and not (t in _edit_behaviors):
			_edit_behaviors.append(t)
	_custom_edit.text = ""
	_rebuild_edit_list()


# ==================== 内部 ====================

func _center() -> void:
	var vp := UIStyle.canvas_viewport_size(self)
	size = Vector2(WIDTH, HEIGHT)
	position = (vp - size) * 0.5
	queue_redraw()
