# ui/folder_button.gd
# 「文件夹」图标按钮 —— 图标由 _draw() 矢量绘制（不是字体符号 / 不是图片资源）。
# 用途：配置面板里的「在资源管理器里选择文件」按钮（按下 = 弹出系统文件选择框）。
#
# 视觉与项目其它按钮一致：圆角底 + 荧光蓝边框；default / hover / pressed 三态。
# 结构与 ui/speaker_button.gd 完全同源（自绘图标按钮，先重绘再发信号）。
class_name FolderButton
extends Control

signal pressed

const ICON_RATIO: float = 0.62     # 图标边长占按钮边长的比例
const ICON_COLOR: Color = Color(1, 1, 1, 1)

var _hover := false
var _down := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(24.0, 24.0)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)


func _on_mouse_entered() -> void:
	_hover = true
	queue_redraw()


func _on_mouse_exited() -> void:
	_hover = false
	_down = false
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_down = true
			queue_redraw()
			accept_event()
		else:
			# ★ 先重绘、再发信号：处理函数可能随后隐藏/释放本按钮（同 UIBtn 的教训）。
			_down = false
			queue_redraw()
			accept_event()
			pressed.emit()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	# 底：圆角 + 边框（液态玻璃：圆角抗锯齿 + 纯白半透明填充）
	var sb := UIStyle.glass_box(
		UIStyle.FILL_PRESSED if _down else (UIStyle.FILL_HOVER if _hover else UIStyle.FILL_DEFAULT),
		UIStyle.BORDER, 4, 1)
	draw_style_box(sb, r)

	var k: float = minf(size.x, size.y) * ICON_RATIO
	var cx: float = size.x * 0.5
	var cy: float = size.y * 0.5
	var col := ICON_COLOR

	var w: float = k
	var h: float = k * 0.82
	var left: float = cx - w * 0.5
	var top: float = cy - h * 0.5

	# 文件夹剪影（单个多边形）：左上标签页 → 斜肩 → 右侧主体 → 底边
	draw_colored_polygon(PackedVector2Array([
		Vector2(left, top),
		Vector2(left + w * 0.42, top),
		Vector2(left + w * 0.52, top + h * 0.20),
		Vector2(left + w, top + h * 0.20),
		Vector2(left + w, top + h),
		Vector2(left, top + h),
	]), col)
