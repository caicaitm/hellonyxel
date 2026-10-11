# ui/confirm_panel.gd
# 通用「确认」模态框（项目自绘，替代原生 ConfirmationDialog）。
#
# ★ 为什么不用 ConfirmationDialog（这是原来的两个问题根源）：
#   1. 它是 Window（独立子视口），**不走本项目的 UIPanel/UIBtn 主题** →
#      永远是 Godot 默认灰色样式，和设置页/背包/关卡页完全不是一套视觉。
#   2. Window 的位置是**屏幕绝对坐标**，而 `show()` 不会居中 → 默认停在 (0,0)，
#      所以原来那个覆盖确认框弹在屏幕左上角。
#   3. 它也不受 CanvasLayer 层序管，盖得住谁、被谁盖都不确定。
#   本类改成「铺满视口的 Control + 自绘卡片」，样式沿用 UIPanel/UIBtn/UIStyle，
#   并挂在自己的高层 CanvasLayer 上 → 恒居中、恒在最上层、且天然模态（挡住背后输入）。
#
# 用法（自建宿主层，**不需要**手动 add_child；close 后自己销毁）：
#   var c := UIConfirmPanel.new()
#   c.confirmed.connect(_on_yes)
#   c.canceled.connect(_on_no)
#   c.open("覆盖确认", "关卡「测试1」已存在。\n覆盖它？", "覆盖", "取消")
#
# 信号：
#   confirmed —— 点「确认」/ 回车
#   canceled  —— 点「取消」/ Esc / 关闭
class_name UIConfirmPanel
extends Control

signal confirmed
signal canceled

# 宿主层号：高于桌面 ui_layer(100)、调试面板(130/135)、通知(150)，保证确认框永远在最上面。
const HOST_LAYER: int = 200

const CARD_W: float = 420.0
const PAD: float = 18.0
const TITLE_H: float = 26.0
const DIV_GAP: float = 10.0      # 标题 → 分隔线
const DIV_AFTER: float = 14.0    # 分隔线 → 正文
const DIV_H: float = 1.0         # 分隔线粗细
const MSG_GAP: float = 18.0      # 正文 → 按钮行
const BTN_W: float = 100.0
const BTN_GAP: float = 10.0
const MIN_MSG_H: float = 26.0    # 正文最小高度（一行）
const MAX_MSG_H: float = 260.0   # 正文最大高度（超出就截断，不再撑高卡片）
const EDGE_KEEP: float = 24.0    # 卡片与视口边缘至少留的间距

var _layer: CanvasLayer = null
var _own_layer := false           # 宿主层是本类自己建的（销毁时一并回收）

var _dim: ColorRect = null        # 全屏压暗层（挡住背后 + 视觉聚焦）
var _card: UIPanel = null
var _title: Label = null
var _divider: ColorRect = null
var _message: Label = null
var _ok_btn: UIBtn = null
var _cancel_btn: UIBtn = null

var _built := false
var _done := false                # 本次弹窗是否已出结果（防重复触发）

var _title_text := ""
var _message_text := ""
var _ok_text := "确定"
var _cancel_text := "取消"


# ---------------- 对外 API ----------------

# 弹出确认框。title/message 为显示文本（支持 \n 换行）；ok_text/cancel_text 为按钮文字。
func open(title: String, message: String, ok_text: String = "确定",
		cancel_text: String = "取消") -> void:
	_title_text = title
	_message_text = message
	_ok_text = ok_text
	_cancel_text = cancel_text
	_ensure_host()
	_build()
	_apply_texts()
	_layout()
	_done = false
	visible = true
	set_process_input(true)
	# 桌面穿透（MousePassRunner）开着时，新出现的可见控件必须刷一次"接收区"，
	# 否则本确认框会被判定为可穿透区域 → 按钮点不动。
	_refresh_passthrough()
	if _ok_btn != null and is_instance_valid(_ok_btn) and _ok_btn.is_inside_tree():
		_ok_btn.grab_focus()
	print("[UIConfirmPanel] 弹出确认框：%s（%s）" % [_title_text, _message_text.replace("\n", " / ")])


# 外部强制收起（按结果结算）；一般由按钮 / 键盘触发，无需手动调。
func close(ok: bool = false) -> void:
	_finish(ok)


func is_open() -> bool:
	return _built and visible


# 显示中的确认框文本（供调试/探针读取）
func debug_state() -> Dictionary:
	return {
		"title": _title_text,
		"message": _message_text,
		"ok": _ok_text,
		"cancel": _cancel_text,
		"visible": visible,
		"card_pos": _card.position if _card != null else Vector2.ZERO,
		"card_size": _card.size if _card != null else Vector2.ZERO,
		"viewport": _viewport_size(),
	}


# ---------------- 宿主层 ----------------

# 把自身挂到一个独立高层 CanvasLayer 上（调用方只 new、不 add_child）。
func _ensure_host() -> void:
	# ★ 用 get_parent() 判重而非 is_inside_tree()：后者在极端环境（探针）下可能为假，
	#   会导致重复 add_child → "already has a parent" 报错。
	if get_parent() != null or is_inside_tree():
		return
	var root := _root_window()
	if root == null:
		push_warning("[UIConfirmPanel] 无场景树，确认框无法显示")
		return
	_layer = CanvasLayer.new()
	_layer.name = "ConfirmLayer"
	_layer.layer = HOST_LAYER
	root.add_child(_layer)
	# ★ 确认框也是「面板」：跟随设置里的 UI 缩放（与 ui_layer 内各面板同一套机制）
	UIStyle.watch_ui_scale(_layer)
	_layer.add_child(self)
	_own_layer = true


func _root_window() -> Window:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root
	return null


# 桌面穿透开启时刷新控件接收区（否则确认框的点击会被穿透到桌面，按钮点不动）。
# ★ 用运行时取节点而非 autoload 全局名：后者在 `--script` 探针里编译不过。
func _refresh_passthrough() -> void:
	var root := _root_window()
	if root == null:
		return
	var mpr: Node = root.get_node_or_null("MousePassRunner")
	if mpr == null:
		return
	if mpr.has_method("is_enabled") and bool(mpr.call("is_enabled")) \
			and mpr.has_method("force_refresh"):
		mpr.call("force_refresh")


# ---------------- 构建 ----------------

func _build() -> void:
	if _built:
		return
	_built = true
	# 本节点铺满视口：STOP → 弹出期间鼠标事件不再落到桌面/积木（模态）
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)

	_dim = ColorRect.new()
	_dim.name = "Dim"
	_dim.color = Color(0.0, 0.02, 0.05, 0.42)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)

	_card = UIPanel.new()
	_card.name = "Card"
	_card.set_corner_radius(UIStyle.CORNER_RADIUS)
	_card.set_fill_color(UIStyle.FILL_DEFAULT)
	_card.set_border_color(UIStyle.BORDER)
	_card.set_border_width(UIStyle.BORDER_WIDTH)
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_card)

	_title = _make_label(UIStyle.FONT_SIZE + 4)
	_title.name = "Title"
	_card.add_child(_title)

	_divider = ColorRect.new()
	_divider.name = "Divider"
	_divider.color = Color(1.0, 1.0, 1.0, 0.22)
	_divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(_divider)

	_message = _make_label(UIStyle.FONT_SIZE)
	_message.name = "Message"
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_card.add_child(_message)

	_cancel_btn = UIBtn.new()
	_cancel_btn.name = "CancelBtn"
	_cancel_btn.set_id("cancel")
	_cancel_btn.pressed_id.connect(_on_btn)
	_card.add_child(_cancel_btn)

	_ok_btn = UIBtn.new()
	_ok_btn.name = "OkBtn"
	_ok_btn.set_id("ok")
	_ok_btn.pressed_id.connect(_on_btn)
	_card.add_child(_ok_btn)


func _make_label(font_size: int) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fnt := UIStyle.get_cjk_font()
	if fnt != null:
		l.add_theme_font_override("font", fnt)
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	return l


func _apply_texts() -> void:
	if _title != null and is_instance_valid(_title):
		_title.text = _title_text
	if _message != null and is_instance_valid(_message):
		_message.text = _message_text
	if _ok_btn != null and is_instance_valid(_ok_btn):
		_ok_btn.set_label(_ok_text)
	if _cancel_btn != null and is_instance_valid(_cancel_btn):
		_cancel_btn.set_label(_cancel_text)


# ---------------- 布局 ----------------

func _viewport_size() -> Vector2:
	# ★ 本卡片在**画布坐标**里手工摆位（卡片是手动 position/size，不是锚点铺满的内层），
	#   而确认框所在 CanvasLayer 会跟随 UI 缩放 → 取画布坐标下的可见尺寸
	#   （直接读 get_visible_rect() 会在缩放 ≠ 1 时把卡片摆偏）。
	if is_inside_tree() and get_viewport() != null:
		return UIStyle.canvas_viewport_size(self)
	# 尚未入树（异常路径 / 探针环境）→ 回落根视口，避免 0 尺寸卡片
	var root := _root_window()
	if root != null:
		return root.get_visible_rect().size
	return Vector2(1280.0, 720.0)


# 卡片恒定居中；高度按正文实际折行高度算（不用 await 等布局，headless 也稳定）。
func _layout() -> void:
	var vs := _viewport_size()
	# ★ 不手动设 self.size：本节点是 FULL_RECT 锚点（父级非 Control → 自动铺满视口），
	#   手动设尺寸会触发 "non-equal opposite anchors" 警告（项目约定：先入树再设锚点、不手动设尺寸）。
	var card_w: float = minf(CARD_W, maxf(120.0, vs.x - EDGE_KEEP * 2.0))
	var inner_w: float = maxf(80.0, card_w - PAD * 2.0)

	var msg_h: float = _measure_message(inner_w)
	var card_h: float = PAD + TITLE_H + DIV_GAP + DIV_H + DIV_AFTER \
		+ msg_h + MSG_GAP + UIStyle.BTN_HEIGHT + PAD
	card_h = minf(card_h, maxf(80.0, vs.y - EDGE_KEEP * 2.0))

	_card.size = Vector2(card_w, card_h)
	_card.position = ((vs - _card.size) * 0.5).floor()

	var x := PAD
	var y := PAD
	_title.position = Vector2(x, y)
	_title.size = Vector2(inner_w, TITLE_H)
	y += TITLE_H + DIV_GAP
	_divider.position = Vector2(x, y)
	_divider.size = Vector2(inner_w, DIV_H)
	y += DIV_H + DIV_AFTER
	_message.position = Vector2(x, y)
	_message.size = Vector2(inner_w, msg_h)

	# 按钮行：贴卡片底部右对齐 → [取消] [确认]
	var btn_y: float = card_h - PAD - UIStyle.BTN_HEIGHT
	var ok_x: float = card_w - PAD - BTN_W
	var cancel_x: float = ok_x - BTN_GAP - BTN_W
	_cancel_btn.position = Vector2(cancel_x, btn_y)
	_cancel_btn.size = Vector2(BTN_W, UIStyle.BTN_HEIGHT)
	_ok_btn.position = Vector2(ok_x, btn_y)
	_ok_btn.size = Vector2(BTN_W, UIStyle.BTN_HEIGHT)


# 正文折行后所需高度：用字体量（不依赖容器的下一帧布局，headless 下同样准确）。
func _measure_message(inner_w: float) -> float:
	if _message == null or not is_instance_valid(_message):
		return MIN_MSG_H
	var f: Font = _message.get_theme_font("font")
	var fs: int = _message.get_theme_font_size("font_size")
	if f == null:
		return MIN_MSG_H
	var need: Vector2 = f.get_multiline_string_size(
		_message_text, HORIZONTAL_ALIGNMENT_LEFT, inner_w, fs)
	return clampf(ceilf(need.y) + 4.0, MIN_MSG_H, MAX_MSG_H)


# ---------------- 交互 ----------------

func _on_btn(id: String) -> void:
	_finish(id == "ok")


func _input(event: InputEvent) -> void:
	if not visible:
		return
	var vp := get_viewport()
	if event.is_action_pressed("ui_cancel"):
		if vp != null:
			vp.set_input_as_handled()
		_finish(false)
		return
	if event.is_action_pressed("ui_accept"):
		if vp != null:
			vp.set_input_as_handled()
		_finish(true)


func _finish(ok: bool) -> void:
	if _done:
		return
	_done = true
	visible = false
	set_process_input(false)
	if ok:
		confirmed.emit()
	else:
		canceled.emit()
	# 结果派发完再回收（宿主层是本类建的 → 连层一起收，不留常驻节点）
	if _own_layer and _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	else:
		queue_free()
	_refresh_passthrough()
