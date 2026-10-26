# ui/notification_panel.gd
# 通知面板 —— 右下角（任务栏上方）弹出的低打扰提示。
# 用途：喝水/带伞/换衣服等日常提醒，以及主线少数沉浸感事件。
# 内容：一段文字 + 0~2 个按钮 + 一个关闭按钮；无移动/缩放按钮。
# 行为：超时自动淡出消失，也可手动关闭，或点任意按钮后关闭。
# 定位数据源：sysinfo.json 的 taskbar 段（edge / height_px），确保不遮挡任务栏。
class_name NotificationPanel
extends Control

signal closed
signal button_pressed(button_id: String)

const W := 320.0            # 面板固定宽度
const PAD := 12.0
const CLOSE_SIZE := 24.0
const CLOSE_MARGIN := 6.0   # 关闭按钮到面板右/上沿的距离
const GAP := 8.0            # 文字与按钮之间 / 按钮间距
const BTN_H := 26.0
const BTN_MIN_W := 96.0
const FADE_IN_SEC := 0.22
const FADE_OUT_SEC := 0.4
const EDGE_MARGIN := 16.0   # 面板到屏幕边缘 / 任务栏的间距

var timeout := 5.0          # 超时自动消失秒数（<=0 表示不自动消失）

var _pending_text := ""
var _pending_buttons: Array = []
var _has_closed := false   # 防止 dismiss / 关闭按钮 / 超时回调重复触发

var _bg: UIPanel
var _text_label: Label
var _buttons_box: HBoxContainer
var _close_btn: UIBtn


# 通过配置后加入场景树（加树前调用），超时默认 5 秒
func init(text: String, buttons: Array = [], timeout_sec: float = 5.0) -> NotificationPanel:
	_pending_text = text
	_pending_buttons = buttons
	timeout = timeout_sec
	return self


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_children()
	_text_label.text = _pending_text
	_rebuild_buttons(_pending_buttons)
	_layout()
	_fade_in()
	_start_timeout()


func _build_children() -> void:
	var fnt := UIStyle.get_cjk_font()

	_bg = UIPanel.new()
	_bg.bind_page_dark_bg()
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	_text_label = Label.new()
	_text_label.name = "Text"
	_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_text_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_text_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_text_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		_text_label.add_theme_font_override("font", fnt)
	add_child(_text_label)

	_buttons_box = HBoxContainer.new()
	_buttons_box.name = "Buttons"
	_buttons_box.add_theme_constant_override("separation", int(GAP))
	add_child(_buttons_box)

	_close_btn = UIBtn.new()
	_close_btn.name = "CloseBtn"
	_close_btn.set_id("close")
	_close_btn.set_label("✕")
	_close_btn.pressed_id.connect(_on_close_pressed)
	add_child(_close_btn)


func _rebuild_buttons(arr: Array) -> void:
	for entry in arr:
		if entry is Dictionary:
			var btn := UIBtn.new()
			btn.custom_minimum_size = Vector2(BTN_MIN_W, BTN_H)
			btn.size = Vector2(BTN_MIN_W, BTN_H)
			btn.set_id(str(entry.get("id", "")))
			btn.set_label(str(entry.get("label", "?")))
			btn.pressed_id.connect(_on_button_pressed)
			_buttons_box.add_child(btn)


func _layout() -> void:
	var text_w := W - PAD * 2.0
	var fnt := UIStyle.get_cjk_font()
	var text_h := 22.0
	if is_instance_valid(fnt):
		var sz := fnt.get_string_size(_pending_text, HORIZONTAL_ALIGNMENT_LEFT, text_w, UIStyle.FONT_SIZE)
		text_h = maxf(1.0, sz.y)

	var has_btns := _buttons_box.get_child_count() > 0
	var btn_row_h := (GAP * 0.5 + BTN_H + GAP * 0.5) if has_btns else 0.0
	var h := PAD + CLOSE_SIZE + GAP * 0.5 + text_h + btn_row_h + PAD
	size = Vector2(W, h)

	_close_btn.position = Vector2(W - CLOSE_SIZE - CLOSE_MARGIN, CLOSE_MARGIN)
	_close_btn.size = Vector2(CLOSE_SIZE, CLOSE_SIZE)

	_text_label.position = Vector2(PAD, PAD + CLOSE_SIZE + GAP * 0.5)
	_text_label.size = Vector2(text_w, text_h)

	if has_btns:
		var n := _buttons_box.get_child_count()
		var total_w := BTN_MIN_W * n + GAP * (n - 1)
		var btns_y := PAD + CLOSE_SIZE + GAP * 0.5 + text_h + GAP * 0.5
		_buttons_box.position = Vector2((W - total_w) * 0.5, btns_y)
		_buttons_box.size = Vector2(total_w, BTN_H)

	_position_on_screen(h)


# 定位到右下角（任务栏上方，紧贴任务栏上沿）
# 任务栏几何统一走 DesktopShell 的访问器（与底部对话面板同一份规则）。
# ★ 紧贴规则：面板贴任务栏那一侧**不留缝**（底边 = 画布底 - 任务栏厚度），
#   只在屏幕侧（右/下）保留 EDGE_MARGIN。这样消息无论多长，底边始终和任务栏上边贴合。
func _position_on_screen(panel_h: float) -> void:
	# ★ 本面板按**画布坐标**排布（所在 CanvasLayer 会跟随 UI 缩放）；
	#   而任务栏几何来自操作系统，是**屏幕像素** → 厚度要换算成画布坐标，否则缩放后离任务栏一条缝。
	var vp := UIStyle.canvas_viewport_size(self)
	var edge := DesktopShell.get_taskbar_edge()
	var th := DesktopShell.get_taskbar_thickness() / maxf(UIStyle.ui_scale(), 0.0001)
	var pos := Vector2.ZERO
	match edge:
		"top":
			pos = Vector2(vp.x - W - EDGE_MARGIN, th)
		"left":
			pos = Vector2(th, vp.y - panel_h - EDGE_MARGIN)
		"right":
			pos = Vector2(vp.x - W - th, vp.y - panel_h - EDGE_MARGIN)
		_:  # bottom（默认）
			pos = Vector2(vp.x - W - EDGE_MARGIN, vp.y - panel_h - th)
	# ★★ 兜底夹取：任务栏厚度取不到 / 视口尺寸异常时，宁可贴在边缘也**绝不**把面板推到可见区之外
	#   （批次 64：曾经因为厚度恒 0 而整条通知沉到屏幕最底、被任务栏盖住）。
	pos.x = clampf(pos.x, 0.0, maxf(0.0, vp.x - W))
	pos.y = clampf(pos.y, 0.0, maxf(0.0, vp.y - panel_h))
	position = pos


func _fade_in() -> void:
	modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, FADE_IN_SEC)


func _start_timeout() -> void:
	if timeout > 0.0:
		var tw := create_tween()
		tw.tween_interval(timeout)
		tw.tween_property(self, "modulate:a", 0.0, FADE_OUT_SEC)
		tw.tween_callback(_finish_close)


# 公开 API：立即关闭（供事件链执行器关闭持久通知等用途）
func dismiss() -> void:
	_finish_close()


func _on_close_pressed(_id: String) -> void:
	_finish_close()


func _on_button_pressed(id: String) -> void:
	button_pressed.emit(id)
	_finish_close()


func _finish_close() -> void:
	if _has_closed:
		return
	_has_closed = true
	closed.emit()
	queue_free()