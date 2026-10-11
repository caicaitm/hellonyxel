# ui_drag_handle.gd
# UI 拖动把柄（从 abandon 版 v0.1.8+ 迁移复用，适配新版 UIPanel/UIStyle）
extends Control
class_name UIDragHandle

## 一个 28×28 方形按钮,内画"4 向十字箭头"(▲◀▼▶ 围绕中心)。
## 风格沿用 ×关闭按钮:UIPanel 矩形圆角边框 + 蓝边半透明填充,
## 鼠标悬停/按下/默认三态切换。
##
## 按下左键进入拖动态,父 Control(整个 UI 面板)跟着鼠标移动;松开后停下。
##
## 用法:
##   var h := UIDragHandle.new()
##   h.setup(target_control)        # target_control 是要被拖动的 UI 容器
##   panel.add_child(h)             # 作为 panel 子节点(放在顶栏 × 关闭按钮左侧)
##
## 边界保护:拖动时把 target_control.position 限制在视口内,
## 至少留 25% 的标题栏在视口里(用户能看到自己在拖什么)。
##
## 与 UIBtn 不同:本控件不是 BaseButton,不会被 BaseButton 的 release 行为
## 影响;直接监听 gui_input + _input 全局 mouse up,确保松手不丢失。

signal drag_started
signal drag_ended

const SIZE: float = 28.0
const ARROW_SIZE: float = 4.5    # 4 向三角形箭头的"半径"
const ARROW_COLOR: Color = Color.WHITE

var _target: Control = null
var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO
var _bg: UIPanel
var _hovered: bool = false
# 可选"增量回调"模式：设置了 _move_cb 后，拖动不再改 _target.position，
# 而是每帧把鼠标位移的增量交给回调（用于平移非 Control 的目标，如关卡页的一组积木）。
var _move_cb: Callable = Callable()
var _last_mouse: Vector2 = Vector2.ZERO


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
	# 4 向箭头用 _draw 自绘(不依赖字体字形)
	queue_redraw()
	# 处理输入
	gui_input.connect(_on_gui_input)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	set_process(false)


## 配置拖动目标(要拖的 UI 容器)
func setup(target: Control) -> void:
	_target = target
	_move_cb = Callable()


## 用"增量回调"替代 target 拖动：拖动态每帧把鼠标位移增量交给 cb(Vector2)。
## 适用于目标不是 Control 的场景（如把柄在 CanvasLayer、但要平移一组积木）。
func set_move_callback(cb: Callable) -> void:
	_move_cb = cb
	_target = null


## _draw 4 向十字箭头:
##   ▲ 在 (cx,           cy - 9)
##   ▼ 在 (cx,           cy + 9)
##   ◀ 在 (cx - 9,       cy)
##   ▶ 在 (cx + 9,       cy)
func _draw() -> void:
	var cx: float = size.x * 0.5
	var cy: float = size.y * 0.5
	var s: float = ARROW_SIZE
	var c := ARROW_COLOR
	# 上 ▲(三角形,顶点指上)
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(cx,         cy - 9.0 - s),
			Vector2(cx - s,     cy - 9.0 + s * 0.5),
			Vector2(cx + s,     cy - 9.0 + s * 0.5),
		]), c
	)
	# 下 ▼
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(cx,         cy + 9.0 + s),
			Vector2(cx - s,     cy + 9.0 - s * 0.5),
			Vector2(cx + s,     cy + 9.0 - s * 0.5),
		]), c
	)
	# 左 ◀
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(cx - 9.0 - s, cy),
			Vector2(cx - 9.0 + s * 0.5, cy - s),
			Vector2(cx - 9.0 + s * 0.5, cy + s),
		]), c
	)
	# 右 ▶
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(cx + 9.0 + s, cy),
			Vector2(cx + 9.0 - s * 0.5, cy - s),
			Vector2(cx + 9.0 - s * 0.5, cy + s),
		]), c
	)


func _apply_visual() -> void:
	if _bg == null:
		return
	if _dragging:
		_bg.set_fill_color(UIStyle.FILL_PRESSED)
	elif _hovered:
		_bg.set_fill_color(UIStyle.FILL_HOVER)
	else:
		_bg.set_fill_color(UIStyle.FILL_DEFAULT)


func _on_mouse_entered() -> void:
	_hovered = true
	_apply_visual()


func _on_mouse_exited() -> void:
	_hovered = false
	_apply_visual()


func _begin_drag() -> void:
	# 回调模式不依赖 target 的 position 基准，直接以按下时的鼠标位置为增量起点
	if _move_cb.is_valid():
		_last_mouse = get_global_mouse_position()
		_dragging = true
		_apply_visual()
		set_process(true)
		drag_started.emit()
		return
	if _target == null or not is_instance_valid(_target):
		return
	_dragging = true
	# CanvasLayer 内 Control 的 position == global_position(CanvasLayer 原点在 0,0)
	_drag_offset = _target.position - get_global_mouse_position()
	_apply_visual()
	set_process(true)
	drag_started.emit()


func _end_drag() -> void:
	if not _dragging:
		return
	_dragging = false
	set_process(false)
	# 拖动结束后,_hovered 可能已经过期(鼠标可能已经移开)
	# 重置:不依赖 _hovered 状态,让 _on_mouse_exited 在下一次鼠标移动时刷新
	if _bg:
		_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	drag_ended.emit()


## 拖动态:每帧把 target 移到 mouse + offset,并限制在视口内；
## 回调模式下则把鼠标增量交给 cb（由目标自己决定如何移动）。
func _process(_delta: float) -> void:
	if not _dragging:
		return
	# 回调模式：把这一帧相对上一次的鼠标位移交给回调
	if _move_cb.is_valid():
		var cur: Vector2 = get_global_mouse_position()
		var inc: Vector2 = cur - _last_mouse
		_last_mouse = cur
		if inc != Vector2.ZERO:
			_move_cb.call(inc)
		return
	if _target == null or not is_instance_valid(_target):
		return
	# ★ 本控件与 _target 都在画布坐标里（position / size / get_global_mouse_position() 同空间）
	#   → 夹取范围必须也用画布坐标下的可见矩形；用 get_visible_rect() 会在 UI 缩放 ≠ 1 时差一档。
	var vp_rect: Rect2 = UIStyle.canvas_viewport_rect(self)
	var mouse: Vector2 = get_global_mouse_position()
	var new_pos: Vector2 = mouse + _drag_offset
	# 边界保护:允许 75% 滑出屏幕外,保证至少 25% 标题栏在视口内
	var min_x: float = -_target.size.x * 0.75
	var max_x: float = vp_rect.size.x - _target.size.x * 0.25
	var min_y: float = -_target.size.y * 0.75
	var max_y: float = vp_rect.size.y - _target.size.y * 0.25
	new_pos.x = clampf(new_pos.x, min_x, max_x)
	new_pos.y = clampf(new_pos.y, min_y, max_y)
	# target 在 CanvasLayer 内 → 它的 position 就是 CanvasLayer 局部坐标
	_target.position = new_pos


## 本控件上的输入处理
func _on_gui_input(event: InputEvent) -> void:
	# 按下左键 → 进入拖动
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_begin_drag()
		get_viewport().set_input_as_handled()
		return
	# 在本控件上松开左键(鼠标没拖出去) → 退出拖动
	if event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _dragging:
			_end_drag()
			get_viewport().set_input_as_handled()
			return


## 拖动中:监听全局 mouse up,这样即使鼠标已经拖出本控件范围也能正确停止
## 用 _input 而非 _unhandled_input — 优先捕获,避免被面板内的其它按钮/次级菜单截走
func _input(event: InputEvent) -> void:
	if not _dragging:
		return
	if event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_end_drag()
		get_viewport().set_input_as_handled()
		return
