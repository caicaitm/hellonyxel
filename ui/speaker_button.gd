# ui/speaker_button.gd
# 「扬声器」图标按钮 —— 图标由 _draw() 矢量绘制（不是字体符号 / 不是图片资源）。
# 用途：底部对话面板的「重播语音」按钮（按下 = 停止当前音频并从头播）。
#
# 视觉与项目其它按钮一致：圆角底 + 荧光蓝边框；default / hover / pressed 三态。
class_name SpeakerButton
extends Control

signal pressed

const ICON_RATIO: float = 0.60     # 图标边长占按钮边长的比例
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
	var cx: float = size.x * 0.5 - k * 0.08   # 整体略左移，给右侧声波留位置
	var cy: float = size.y * 0.5
	var col := ICON_COLOR

	# ① 喇叭「箱体」
	draw_rect(Rect2(Vector2(cx - k * 0.36, cy - k * 0.13), Vector2(k * 0.16, k * 0.26)), col, true)
	# ② 喇叭「锥」
	draw_colored_polygon(PackedVector2Array([
		Vector2(cx - k * 0.20, cy - k * 0.13),
		Vector2(cx + k * 0.02, cy - k * 0.33),
		Vector2(cx + k * 0.02, cy + k * 0.33),
		Vector2(cx - k * 0.20, cy + k * 0.13),
	]), col)
	# ③ 两道声波弧（向右张开）
	var origin := Vector2(cx + k * 0.04, cy)
	draw_arc(origin, k * 0.20, -PI * 0.33, PI * 0.33, 14, col, 1.3, true)
	draw_arc(origin, k * 0.34, -PI * 0.33, PI * 0.33, 18, col, 1.3, true)
