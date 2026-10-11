# color_picker_panel.gd
# 取色盘窗口 —— 在积木属性面板的颜色输入框旁按「色盘」打开，双向联动「#RRGGBBAA」。
#
# ★ 用**内联 ColorPicker**（普通 Control），不用 ColorPickerButton / 内置 Window 弹窗：
#   内置 Window 类弹窗是子视口，不吃项目自绘样式，且按屏幕绝对坐标弹（见 level_page.gd 关于
#   ConfirmationDialog 的说明）；内联 ColorPicker 可直接进本面板布局 —— 与
#   long_text_input_panel.gd 里已有的取色盘是同一套做法。
# ★ 双向联动：拖动色盘 → 回填 RGB 码到输入框；手改输入框 → 色盘跟着走。
# ★ 关掉三块本面板用不到的部件（色板预设 / 自带十六进制框〈本面板另有 RGB 码输入框〉/
#   色彩模式切换按钮）：它们会把取色盘最小尺寸撑到 298×607，关掉后 298×467。
#
# 使用:
#   var panel := UIColorPickerPanel.new()
#   ui_layer.add_child(panel)
#   panel.open(source_edit, "边框色")     # source_edit 为属性面板的颜色 LineEdit
# 信号:
#   closed
extends Control
class_name UIColorPickerPanel

signal closed

const TITLE_H: float = 34.0
const FOOTER_H: float = 44.0
const PAD: float = 10.0
const ROW_H: float = 26.0
const HEX_LABEL_W: float = 138.0
const DEFAULT_W: float = 360.0     # 面板宽度下限（取色盘自身约 298 宽）
const SIDE_GAP: float = 8.0        # 与「积木属性」面板之间的间距（左/右贴边打开时）
const TITLE_X: float = 44.0        # 标题起点 x（让开左侧拖动把柄：PAD + UIDragHandle.SIZE + 6）

var _dim: ColorRect
var _bg: UIPanel
var _title_label: Label
var _drag_handle: UIDragHandle     # 移动把柄：拖动整个面板平移
var _close_btn: UIBtn
var _picker: ColorPicker
var _hex_input: LineEdit
var _preview: Panel
var _source_edit: LineEdit = null
var _loading: bool = false         # 回填中：切断双向联动，避免互相触发


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	visible = false


func _build_ui() -> void:
	# 半透明遮罩：点击空白 = 取消
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

	# 移动把柄（项目通用 UIDragHandle，同积木属性面板/关卡页面）：拖动平移整个面板。
	# 它自带边界保护（至少留 25% 标题栏在视口内），所以拖不丢。
	_drag_handle = UIDragHandle.new()
	_drag_handle.name = "DragHandle"
	_drag_handle.setup(self)
	_drag_handle.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_drag_handle.offset_left = PAD
	_drag_handle.offset_top = (TITLE_H - UIDragHandle.SIZE) * 0.5
	_drag_handle.offset_right = PAD + UIDragHandle.SIZE
	_drag_handle.offset_bottom = (TITLE_H - UIDragHandle.SIZE) * 0.5 + UIDragHandle.SIZE
	add_child(_drag_handle)

	_title_label = Label.new()
	_title_label.text = "选择颜色"
	_title_label.position = Vector2(TITLE_X, 4.0)
	_title_label.size = Vector2(DEFAULT_W - TITLE_X - PAD - 28.0, TITLE_H)
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
	_close_btn.pressed_id.connect(_on_footer_pressed)
	add_child(_close_btn)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = PAD
	box.offset_right = -PAD
	box.offset_top = TITLE_H
	box.offset_bottom = -FOOTER_H
	box.add_theme_constant_override("separation", 6)
	add_child(box)

	# 取色盘（内联 Control，非 Window 弹窗）
	_picker = ColorPicker.new()
	_picker.name = "ColorPicker"
	_picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_picker.presets_visible = false
	_picker.hex_visible = false
	_picker.color_modes_visible = false
	# 积木颜色是 #RRGGBBAA（带 alpha）→ 必须能编辑透明度。
	_picker.edit_alpha = true
	_picker.color_changed.connect(_on_color_changed)
	box.add_child(_picker)

	# RGB 码输入行（与色盘双向联动）+ 色块预览
	var hex_row := HBoxContainer.new()
	hex_row.add_theme_constant_override("separation", 6)
	box.add_child(hex_row)
	var lb := Label.new()
	lb.text = "RGB码(#RRGGBBAA)"
	lb.custom_minimum_size = Vector2(HEX_LABEL_W, ROW_H)
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lb.add_theme_color_override("font_color", Color(0.75, 0.92, 1.0))
	lb.add_theme_font_size_override("font_size", int(UIStyle.FONT_SIZE))
	lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_instance_valid(fnt):
		lb.add_theme_font_override("font", fnt)
	hex_row.add_child(lb)
	_hex_input = LineEdit.new()
	_hex_input.custom_minimum_size = Vector2(150.0, ROW_H)
	_hex_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.apply_line_edit_style(_hex_input)
	_hex_input.text_changed.connect(_on_hex_edited)
	hex_row.add_child(_hex_input)
	_preview = Panel.new()
	_preview.custom_minimum_size = Vector2(48.0, ROW_H)
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hex_row.add_child(_preview)

	# 底部按钮行
	var footer := HBoxContainer.new()
	footer.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	footer.anchor_left = 1.0
	footer.anchor_right = 1.0
	footer.anchor_top = 1.0
	footer.anchor_bottom = 1.0
	footer.offset_left = -160.0
	footer.offset_right = -PAD
	footer.offset_top = -FOOTER_H + 6.0
	footer.offset_bottom = -6.0
	footer.add_theme_constant_override("separation", 10)
	add_child(footer)

	var ok_btn := UIBtn.new()
	ok_btn.set_id("ok")
	ok_btn.set_label("确定")
	ok_btn.custom_minimum_size = Vector2(70.0, 30.0)
	ok_btn.pressed_id.connect(_on_footer_pressed)
	footer.add_child(ok_btn)

	var cancel_btn := UIBtn.new()
	cancel_btn.set_id("cancel")
	cancel_btn.set_label("取消")
	cancel_btn.custom_minimum_size = Vector2(70.0, 30.0)
	cancel_btn.pressed_id.connect(_on_footer_pressed)
	footer.add_child(cancel_btn)


# 打开：source = 属性面板里对应的颜色 LineEdit（如「边框色」）；title = 窗口标题；
#        anchor = 要贴边停靠的面板（积木属性面板），传 null 则退回归中。
# 同步完成（不 await）：避免关闭后滞后的协程继续恢复、把已关的窗再弹出来（同 TagPickerPanel）。
func open(source: LineEdit, title: String = "选择颜色", anchor: Control = null) -> void:
	_source_edit = source
	if not title.is_empty():
		_title_label.text = title
	var initial: String = source.text.strip_edges() if (source != null and is_instance_valid(source)) else ""
	if initial.is_empty():
		initial = "#FFFFFFFF"
	_loading = true
	_picker.color = BlockProperty.hex_to_color(initial)
	_hex_input.text = initial
	_sync_preview(_picker.color)
	_loading = false
	# 尺寸按取色盘**自身**的最小尺寸推导（不写死数字，避免引擎版本差异把取色盘裁掉）；
	# 拿不到（尚未布局，返回 0）时用已知下限兜底。
	var pm: Vector2 = _picker.get_combined_minimum_size()
	if pm.x < 100.0:
		pm.x = 298.0
	if pm.y < 100.0:
		pm.y = 467.0
	var w: float = maxf(DEFAULT_W, pm.x + PAD * 2.0)
	var h: float = TITLE_H + pm.y + ROW_H + 18.0 + FOOTER_H + PAD * 2.0
	var vp: Vector2 = UIStyle.canvas_viewport_size(self)
	h = clampf(h, 220.0, maxf(220.0, vp.y - 40.0))
	w = minf(w, maxf(240.0, vp.x - 40.0))
	size = Vector2(w, h)
	_title_label.size = Vector2(maxf(60.0, w - TITLE_X - PAD - 28.0), TITLE_H)
	# ★ 打开位置：贴在「积木属性」面板的**左侧或右侧**（不居中 —— 居中会盖住属性面板），
	#   且任何情况下都夹在视口内，绝不跑出屏幕。
	if anchor != null and is_instance_valid(anchor):
		_place_beside(anchor, vp)
	else:
		position = (vp - size) * 0.5
	queue_redraw()
	visible = true
	print("[ColorPicker] 打开 标题=%s 初值=%s 位置=%s" % [title, initial, str(position)])


# 贴边停靠：右边优先 → 右边放不下改左边 → 两边都放不下则夹回视口（保证不出屏）。
# vp 为画布坐标下的视口尺寸（与 anchor.position 同一坐标空间：两者同在 ui_layer）。
func _place_beside(anchor: Control, vp: Vector2) -> void:
	var max_x: float = maxf(0.0, vp.x - size.x)
	var max_y: float = maxf(0.0, vp.y - size.y)
	# 竖直：与锚定面板顶部对齐（再夹进视口）
	var y: float = clampf(anchor.position.y, 0.0, max_y)
	var right_x: float = anchor.position.x + anchor.size.x + SIDE_GAP   # 右侧：锚定面板右缘 + 间距
	var left_x: float = anchor.position.x - size.x - SIDE_GAP           # 左侧：锚定面板左缘 - 本面板宽 - 间距
	var x: float = right_x
	if right_x > max_x:
		if left_x >= 0.0:
			x = left_x                # 右边放不下 → 放左边
		else:
			x = clampf(right_x, 0.0, max_x)   # 两边都放不下 → 夹进视口
	position = Vector2(x, y)


# 关闭（不写回）：取消 / 点遮罩 / ESC / 属性面板被关闭 都走这里
func close() -> void:
	visible = false
	if is_inside_tree():
		get_viewport().gui_release_focus()
	closed.emit()
	queue_free()


func is_open() -> bool:
	return visible


# ---- 双向联动 ----
func _on_color_changed(c: Color) -> void:
	if _loading:
		return
	_loading = true
	_hex_input.text = BlockProperty.color_to_hex(c)
	_sync_preview(c)
	_loading = false


func _on_hex_edited(t: String) -> void:
	if _loading:
		return
	var s := t.strip_edges()
	if not BlockProperty.is_valid_hex_color(s):
		return
	_loading = true
	var c: Color = BlockProperty.hex_to_color(s)
	_picker.color = c
	_sync_preview(c)
	_loading = false


# 色块预览：Panel 没有 bg_color → 用 StyleBoxFlat 上色
func _sync_preview(c: Color) -> void:
	if _preview == null or not is_instance_valid(_preview):
		return
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(3)
	_preview.add_theme_stylebox_override("panel", sb)
	_preview.tooltip_text = BlockProperty.color_to_hex(c)


# ---- 确定 / 关闭 ----
func _apply() -> void:
	var t: String = _hex_input.text.strip_edges()
	if not BlockProperty.is_valid_hex_color(t):
		return
	if _source_edit != null and is_instance_valid(_source_edit) and _source_edit is LineEdit:
		_source_edit.text = t
		_source_edit.queue_redraw()
	print("[ColorPicker] 确定回填 color=%s" % t)


func _on_footer_pressed(id: String) -> void:
	match id:
		"ok":
			_apply()
			close()
		"cancel", "close":
			close()


func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()
