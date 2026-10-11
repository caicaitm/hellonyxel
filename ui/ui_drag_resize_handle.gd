# ui_drag_resize_handle.gd
# UI 拖动窗口大小把柄（从 abandon 版 v0.1.x 迁移复用，适配新版 UIPanel/UIStyle）
# 风格沿用 × 关闭按钮与 UIDragHandle：UIPanel 矩形圆角边框 + 蓝边半透明填充。
#
# 鼠标悬停时切换为对角箭头光标；按下左键进入缩放手势，沿对角拖动可
# 改变 target_control 的宽高（最小 120×120）。
#
# 用法:
#   var h := UIDragResizeHandle.new()
#   h.setup(target_control)
#   panel.add_child(h)    # 放在面板右下角
extends Control
class_name UIDragResizeHandle

signal resize_started
signal resize_ended

const SIZE: float = 28.0
const MIN_SIZE: float = 120.0
const ARROW_COLOR: Color = Color.WHITE

var _target: Control = null
var _resizing: bool = false
var _start_pos: Vector2 = Vector2.ZERO
var _start_size: Vector2 = Vector2.ZERO
var _bg: UIPanel
var _hovered: bool = false
# 最小尺寸（默认 MIN_SIZE 见方）。调用方可用 set_min_size 抬到「至少放得下自身内容/按钮」。
var _min_size: Vector2 = Vector2(MIN_SIZE, MIN_SIZE)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(SIZE, SIZE)
	size = Vector2(SIZE, SIZE)
	_bg = UIPanel.new()
	_bg.name = "Bg"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	_bg.set_border_width(1.0)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)
	queue_redraw()
	set_process(false)
	gui_input.connect(_on_gui_input)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)


func setup(target: Control) -> void:
	_target = target


## 覆盖最小尺寸（默认 120×120）。调用方（如事件链编辑器）传「内容自然最小尺寸」，
## 使把柄无法把面板缩到放不下按钮。
func set_min_size(v: Vector2) -> void:
	_min_size = Vector2(maxf(v.x, MIN_SIZE), maxf(v.y, MIN_SIZE))


func _draw() -> void:
	var cx: float = size.x * 0.5
	var cy: float = size.y * 0.5
	var s: float = 4.5    # 箭头半径
	var c := ARROW_COLOR

	## 对角线 ↙→↗（从左上到右下）：两个箭头分别指↖和↘
	_draw_diagonal_arrow(cx, cy, -1.0, -1.0, s, c)   # ↖ 箭头（左上端）
	_draw_diagonal_arrow(cx, cy,  1.0,  1.0, s, c)   # ↘ 箭头（右下端）

	## 对角线 ↘→↙（从右上到左下）：两个箭头分别指↗和↙
	_draw_diagonal_arrow(cx, cy, -1.0,  1.0, s, c)   # ↗ 箭头（右上端）
	_draw_diagonal_arrow(cx, cy,  1.0, -1.0, s, c)   # ↙ 箭头（左下端）


func _draw_diagonal_arrow(
		cx: float, cy: float,
		dir_x: float, dir_y: float,
		s: float,
		c: Color
) -> void:
	## 箭头顶点在距中心 9px 处，沿 (dir_x, dir_y) 方向延伸
	var tip_x: float = cx + dir_x * 9.0
	var tip_y: float = cy + dir_y * 9.0
	## 箭头基底垂直于方向的偏移
	var perp_x: float = -dir_y
	var perp_y:  float =  dir_x
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(tip_x + dir_x * s,         tip_y + dir_y * s),
			Vector2(tip_x + perp_x * s * 0.5,  tip_y + perp_y * s * 0.5),
			Vector2(tip_x - perp_x * s * 0.5,  tip_y - perp_y * s * 0.5),
		]), c
	)


func _apply_visual() -> void:
	if _bg == null:
		return
	if _resizing:
		_bg.set_fill_color(UIStyle.FILL_PRESSED)
	elif _hovered:
		_bg.set_fill_color(UIStyle.FILL_HOVER)
	else:
		_bg.set_fill_color(UIStyle.FILL_DEFAULT)


func _on_mouse_entered() -> void:
	_hovered = true
	_apply_visual()
	Input.set_default_cursor_shape(Input.CursorShape.CURSOR_FDIAGSIZE)


func _on_mouse_exited() -> void:
	_hovered = false
	_apply_visual()
	Input.set_default_cursor_shape(Input.CursorShape.CURSOR_ARROW)


func _begin_resize() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	_resizing = true
	_start_pos = get_global_mouse_position()
	_start_size = _target.size
	_apply_visual()
	set_process(true)
	resize_started.emit()


func _end_resize() -> void:
	if not _resizing:
		return
	_resizing = false
	set_process(false)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	resize_ended.emit()
	print("[UIDragResizeHandle] 调整大小结束 target=%s size=%s" % [_target.name, _target.size])


func _process(_delta: float) -> void:
	if not _resizing or _target == null or not is_instance_valid(_target):
		return
	var dv: Vector2 = get_global_mouse_position() - _start_pos
	var new_w: float = clampf(_start_size.x + dv.x, _min_size.x, 2000.0)
	var new_h: float = clampf(_start_size.y + dv.y, _min_size.y, 2000.0)
	_target.size = Vector2(new_w, new_h)


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_begin_resize()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _resizing:
			_end_resize()
			get_viewport().set_input_as_handled()
			return
