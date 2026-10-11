# ui/block_motion_panel.gd
# 「积木运动」面板 —— 在积木属性面板里按「调整运动...」打开，细化积木的受控移动参数。
#
# 字段：
#   可飞行（勾选框）            开启后积木不受重力（悬停），可按住 W/↑ 上升、S/↓ 下降（仍需 controlled 标签）
#   水平最大速度（像素/秒）
#   水平加速度（像素/秒²）      0 = 瞬时到位（保留旧手感）
#   飞行上升最大速度（像素/秒）
#   飞行上升加速度（像素/秒²）  0 = 瞬时到位
#
# 数值框用 SpinBox：可直接输入，也可滚轮 / 上下箭头增减（“可滚动填写框”）。
#
# 数据流向（对齐 TagPickerPanel / 长文本窗的「子面板回写」模式）：
#   open(data) 读入 → 界面调整 → 按「确定」把当前值存入 _values；按「取消」/× 保持原值不变。
#   调用方（属性面板）在收到 closed 信号后 get_values() 取回 —— 取消时取回的就是初始值（= 无改动）。
#   属性面板再把这份值写进自己的 prop dict，最终随「确定」一起 apply_to_block。
#
# 样式与其它 UI 一致（天蓝半透明底 + 荧光蓝边框），顶栏复用 UIDragHandle 拖动把柄。
class_name BlockMotionPanel
extends Control

signal closed

# ---------------- 尺寸 / 常量 ----------------
const PAD := 12.0
const TITLE_H := 30.0
const ROW_H := 28.0
const PANEL_W := 440.0
const PANEL_H := 330.0
const DEFAULT_PANEL_W := 1152.0
const DEFAULT_PANEL_H := 648.0
# 小号字（说明文字）。不能用 UIStyle.FONT_SIZE - 2 当 const：static var 不是常量表达式。
const SMALL_FONT := 12

# 数值框上下限（给足余量，不限制玩家配置）
const V_MAX := 100000.0

# 默认值（与 Block / BlockProperty 保持一致）
const DEFAULTS: Dictionary = {
	"can_fly": false,
	"horiz_max_speed": 240.0,
	"horiz_accel": 0.0,
	"fly_up_max_speed": 240.0,
	"fly_up_accel": 0.0,
}

# ---------------- 内部引用 ----------------
var _panel: UIPanel
var _title: Label
var _fly_check: CheckBox
var _horiz_speed: SpinBox
var _horiz_accel: SpinBox
var _fly_speed: SpinBox
var _fly_accel: SpinBox

# ---------------- 状态 ----------------
var _values: Dictionary = {}     # 权威数据：open 时读入，确定时覆盖
var _open: bool = false
var _ever_centered: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	visible = false


# ==================== 构建 ====================

func _build_ui() -> void:
	# 背景：与其它 UI 一致的浅天蓝半透明 + 荧光蓝边框
	_panel = UIPanel.new()
	_panel.name = "UIPanel"
	_panel.set_corner_radius(UIStyle.CORNER_RADIUS)
	_panel.set_fill_color(UIStyle.FILL_DEFAULT)
	_panel.set_border_color(UIStyle.BORDER)
	_panel.set_border_width(UIStyle.BORDER_WIDTH)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	# ★ 先入树、再设锚点：在树外设「不对等锚点」会被 Godot 警告。
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)

	# 整体可滚动：内容长于面板时（小屏 / 大字号）也能看到全部字段
	var sc := ScrollContainer.new()
	sc.name = "Body"
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(sc)
	sc.set_anchors_preset(Control.PRESET_FULL_RECT)
	sc.offset_left = PAD
	sc.offset_top = PAD
	sc.offset_right = -PAD
	sc.offset_bottom = -PAD

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 6)
	sc.add_child(vbox)

	vbox.add_child(_build_title_row())
	vbox.add_child(_hint("细化受控移动。可飞行需配合 `controlled` 标签才响应键盘。\n加速度填 0 = 瞬时达到最大速度（保留旧版手感）。"))
	vbox.add_child(_build_fly_row())
	var r_hs := _spin_row("水平最大速度", "(像素/秒)")
	_horiz_speed = r_hs["spin"]
	vbox.add_child(r_hs["row"])
	var r_ha := _spin_row("水平加速度", "(像素/秒²)")
	_horiz_accel = r_ha["spin"]
	vbox.add_child(r_ha["row"])
	var r_fs := _spin_row("飞行上升最大速度", "(像素/秒)")
	_fly_speed = r_fs["spin"]
	vbox.add_child(r_fs["row"])
	var r_fa := _spin_row("飞行上升加速度", "(像素/秒²)")
	_fly_accel = r_fa["spin"]
	vbox.add_child(r_fa["row"])
	vbox.add_child(_hint("飞行下降复用「飞行上升」的速度与加速度。"))
	vbox.add_child(_build_footer())

	# ★ 不要再给 _panel 手动 size：它挂的是 FULL_RECT 锚点，尺寸自动跟随本 Control。
	size = Vector2(PANEL_W, PANEL_H)



# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏控件整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build_title_row() -> HBoxContainer:
	var top := HBoxContainer.new()
	top.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.custom_minimum_size = Vector2(0.0, TITLE_H)

	_title = Label.new()
	_title.text = "积木运动"
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_apply_font(_title, 2)
	top.add_child(_title)

	# 拖动把柄（复用 UIDragHandle：按住移动整个面板）
	var handle := UIDragHandle.new()
	handle.setup(self)
	handle.tooltip_text = "拖动以移动面板"
	top.add_child(handle)

	# 右上 × 关闭（= 取消）
	var x_btn := UIBtn.new()
	x_btn.set_id("close")
	x_btn.set_label("×")
	x_btn.custom_minimum_size = Vector2(TITLE_H, TITLE_H)
	x_btn.pressed_id.connect(_on_footer_pressed)
	top.add_child(x_btn)
	# ★ 本页顶栏是 HBox（标题 | 移动把柄 | × 关闭）→ 最小化插到 × **之前**，
	#   排布即「移动 | 最小化 | 关闭」。误用 attach_anchored 会按绝对偏移摆位。
	_min_btn = UIMinimize.attach_before(top, x_btn, func(): set_minimized(not _minimized))
	return top


func _build_fly_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)
	row.add_child(_label("可飞行", 150.0))
	_fly_check = CheckBox.new()
	_fly_check.text = "开启（不受重力，可上升/下降）"
	_fly_check.mouse_filter = Control.MOUSE_FILTER_STOP
	_apply_font(_fly_check, 0)
	row.add_child(_fly_check)
	return row


# 数值行：标签 + SpinBox（可滚动填写框）。返回 { "row": HBoxContainer, "spin": SpinBox }
func _spin_row(label_text: String, unit_text: String) -> Dictionary:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)
	row.add_child(_label(label_text, 150.0))

	var spin := SpinBox.new()
	spin.name = label_text
	spin.min_value = 0.0
	spin.max_value = V_MAX
	spin.step = 1.0
	spin.custom_arrow_step = 10.0
	spin.allow_greater = false
	spin.allow_lesser = false
	spin.suffix = " " + unit_text
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.custom_minimum_size = Vector2(150.0, ROW_H)
	spin.mouse_filter = Control.MOUSE_FILTER_STOP
	# SpinBox 内部是一个 LineEdit —— 套用本项目 LineEdit 统一样式
	var le := spin.get_line_edit()
	if le != null:
		le.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
		if is_instance_valid(UIStyle.get_cjk_font()):
			le.add_theme_font_override("font", UIStyle.get_cjk_font())
		UIStyle.apply_line_edit_style(le)
	row.add_child(spin)

	return { "row": row, "spin": spin }


func _build_footer() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 10)

	var ok_btn := UIBtn.new()
	ok_btn.set_id("ok")
	ok_btn.set_label("确定")
	ok_btn.custom_minimum_size = Vector2(80.0, 30.0)
	ok_btn.pressed_id.connect(_on_footer_pressed)
	row.add_child(ok_btn)

	var cancel_btn := UIBtn.new()
	cancel_btn.set_id("cancel")
	cancel_btn.set_label("取消")
	cancel_btn.custom_minimum_size = Vector2(80.0, 30.0)
	cancel_btn.pressed_id.connect(_on_footer_pressed)
	row.add_child(cancel_btn)
	return row


# ---------------- 复用的行零件 ----------------

func _label(text: String, min_w: float) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.clip_text = true
	if min_w > 0.0:
		l.custom_minimum_size = Vector2(min_w, ROW_H)
	_apply_font(l, 0)
	return l


func _hint(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_color_override("font_color", Color(0.82, 0.88, 0.94, 0.85))
	l.add_theme_font_size_override("font_size", SMALL_FONT)
	if is_instance_valid(UIStyle.get_cjk_font()):
		l.add_theme_font_override("font", UIStyle.get_cjk_font())
	return l


func _apply_font(c: Control, size_bonus: int) -> void:
	c.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	c.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + size_bonus)
	if is_instance_valid(UIStyle.get_cjk_font()):
		c.add_theme_font_override("font", UIStyle.get_cjk_font())


# ==================== 打开 / 关闭 ====================

# 打开：以 data 为初始值（缺键用默认）。同步完成，不 await。
func open(data: Dictionary) -> void:
	_values = _normalize(data)
	_fly_check.button_pressed = bool(_values["can_fly"])
	_horiz_speed.value = float(_values["horiz_max_speed"])
	_horiz_accel.value = float(_values["horiz_accel"])
	_fly_speed.value = float(_values["fly_up_max_speed"])
	_fly_accel.value = float(_values["fly_up_accel"])
	if not _ever_centered:
		_center()
		_ever_centered = true
	visible = true
	move_to_front()
	_open = true
	print("[BlockMotion] 打开 can_fly=%s 水平%s/%s 上升%s/%s" % [
		str(_values["can_fly"]), str(_values["horiz_max_speed"]), str(_values["horiz_accel"]),
		str(_values["fly_up_max_speed"]), str(_values["fly_up_accel"])])


# 当前值（确定后=界面值；取消后= open 时传入的初始值）
func get_values() -> Dictionary:
	return _values.duplicate()


func close() -> void:
	_open = false
	visible = false
	# 可能已被移除出场景树（父面板先关）→ get_viewport() 会返回 null，先判断再释放焦点。
	if is_inside_tree() and get_viewport() != null:
		get_viewport().gui_release_focus()
	closed.emit()
	queue_free()


func is_open() -> bool:
	return _open


func _on_footer_pressed(id: String) -> void:
	match id:
		"ok":
			_values = _collect()
			print("[BlockMotion] 确定 can_fly=%s 水平%s/%s 上升%s/%s" % [
				str(_values["can_fly"]), str(_values["horiz_max_speed"]), str(_values["horiz_accel"]),
				str(_values["fly_up_max_speed"]), str(_values["fly_up_accel"])])
			close()
		"cancel", "close":
			close()


func _collect() -> Dictionary:
	return {
		"can_fly": _fly_check.button_pressed,
		"horiz_max_speed": float(_horiz_speed.value),
		"horiz_accel": float(_horiz_accel.value),
		"fly_up_max_speed": float(_fly_speed.value),
		"fly_up_accel": float(_fly_accel.value),
	}


# 补全 / 收敛输入：缺键用默认，负数收敛到 0（面板下限即为 0）
func _normalize(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	out["can_fly"] = bool(d.get("can_fly", DEFAULTS["can_fly"]))
	for k in ["horiz_max_speed", "horiz_accel", "fly_up_max_speed", "fly_up_accel"]:
		out[k] = maxf(0.0, float(d.get(k, DEFAULTS[k])))
	return out


func _center() -> void:
	var vp := Vector2(DEFAULT_PANEL_W, DEFAULT_PANEL_H)
	if is_inside_tree() and get_viewport() != null:
		vp = UIStyle.canvas_viewport_size(self)
	# 略向右下错开，避免与下方的属性面板完全重叠
	var p := (vp - size) * 0.5 + Vector2(60.0, -20.0)
	p.x = clampf(p.x, 4.0, maxf(4.0, vp.x - size.x - 4.0))
	p.y = clampf(p.y, 4.0, maxf(4.0, vp.y - size.y - 4.0))
	position = p.floor()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()


## 最小化 / 还原：折叠只隐藏内容，标题栏控件（标题 / 把柄 / 最小化 / 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.apply(self, _min_btn, v, _min_btn.get_parent() if is_instance_valid(_min_btn) else null)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
