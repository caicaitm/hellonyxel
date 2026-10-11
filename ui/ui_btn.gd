# ui_btn.gd
# 通用 UI 按钮（从 abandon 版 0.1.2 迁移，统一新视觉风格）
# 行为：
#   - 鼠标按下 → 立即触发 pressed_id 信号（不等 release）
#   - 视觉：default / hover / pressed 三态（由 UIPanel 承载）
extends BaseButton
class_name UIBtn

signal pressed_id(id: String)  # 按下时立即发

var _id: String = ""
var _label_text: String = "Button"
var sfx_enabled := true          # 按下时是否播「点击音效」；默认开（个别按钮可关）

# ★★ 批次 70：hover / down 改为**状态驱动**（原来靠 get_global_mouse_position() 现场判定）。
#   旧实现的 bug：「鼠标移到按钮上不亮」。原因是 _apply_visual() 用
#   get_global_rect().has_point(get_global_mouse_position()) 判 hover —— 而 mouse_entered
#   触发的那一刻，get_global_mouse_position() 往往还是「进入前」的位置
#   （信号派发早于鼠标位置更新；ui_layer 带缩放时更明显）→ 判成 default；
#   此后鼠标在按钮内移动**不会再发 mouse_entered** → 永远停在 default，永不点亮。
#   （同一 bug 也会让 mouse_exited 时鼠标仍在矩形内 → 颜色不回落。）
#   现改为：mouse_entered/exited 与 button_down/up 只维护 _hover/_down，_apply_visual() 只读状态。
#   ★ 与 ui_drag_handle / ui_drag_resize_handle（_hovered 状态驱动）保持同一模型。
var _hover: bool = false
var _down: bool = false

var panel: UIPanel
var label_node: Label

# ★★ 批次 91：富文本标签模式。
#   为什么需要：对话面板的按钮文字和正文同源，是 (#ffffffL)[“下一句”] 这种**定义串**。
#   直接塞给 Label 会把修饰连同括号原样显示出来（用户实测：「修饰没生效」）。
#   这里在不破坏既有用法的前提下加一条渲染路径：
#     · 默认（set_label）→ 原来的 Label，一字未改（既有上百处调用零回归）；
#     · set_label_bbcode → 懒挂一个 RichTextLabel 渲染 BBCode，原 Label 隐藏。
var rich_node: RichTextLabel = null      # 懒创建：只有真用富文本时才挂
var _label_bbcode: String = ""           # 富文本模式的 BBCode 正文
var _rich_wanted: bool = false           # true = 走 RichTextLabel
var _rich_retry: bool = false            # 内容高度首次测不出来时只重试一次

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_ensure_children()
	_apply_visual()
	_apply_label_text()
	button_down.connect(_on_button_down)
	button_up.connect(_on_button_up)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

func set_id(id: String) -> void:
	_id = id

func get_id() -> String:
	return _id

## 纯文本标签（默认路径；与历史行为完全一致）。
func set_label(text: String) -> void:
	_rich_wanted = false
	_label_text = text
	if is_inside_tree():
		_apply_label_text()

## 富文本标签：直接给 **BBCode**（颜色/透明度/字号/对齐/换行真正生效）。
## plain = 纯文本形式（台词记录 / 日志用）；留空则退回用 bbcode 本身兜底。
## ★ 调用方负责把定义串渲染成 BBCode（对话面板走 DialogueVoice.to_bbcode）。
func set_label_bbcode(bbcode: String, plain: String = "") -> void:
	_rich_wanted = true
	_label_bbcode = bbcode
	_label_text = plain if not plain.is_empty() else bbcode
	if is_inside_tree():
		_apply_label_text()

func get_label() -> String:
	return _label_text

## 当前是否处于富文本标签模式
func is_rich_label() -> bool:
	return _rich_wanted

func _apply_label_text() -> void:
	if _rich_wanted:
		var rl := _ensure_rich()
		if rl != null:
			rl.text = _label_bbcode
			rl.visible = true
			if is_instance_valid(label_node):
				label_node.visible = false
			_layout_rich()
			return
	# —— 纯文本路径（历史行为，一字未改）——
	if is_instance_valid(rich_node):
		rich_node.visible = false
	if is_instance_valid(label_node):
		label_node.visible = true
		label_node.text = _label_text

func _ensure_children() -> void:
	if not has_node("UIPanel"):
		var p := UIPanel.new()
		p.name = "UIPanel"
		p.set_anchors_preset(Control.PRESET_FULL_RECT)
		p.set_corner_radius(UIStyle.CORNER_RADIUS)
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(p)
	if not has_node("Label"):
		var l := Label.new()
		l.name = "Label"
		l.set_anchors_preset(Control.PRESET_FULL_RECT)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var fnt = UIStyle.get_cjk_font()
		if fnt != null:
			l.add_theme_font_override("font", fnt)
		l.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(l)
	# ★ 兜底：add_child 到本帧末之间节点可能处于「半死」状态（has_node 为真但取到的引用已失效），
	#   用 is_instance_valid 过滤，避免把失效引用写进 panel/label_node（后续 _apply_visual 会用到）。
	var pn: Node = get_node_or_null("UIPanel")
	panel = pn as UIPanel if is_instance_valid(pn) else null
	var ln: Node = get_node_or_null("Label")
	label_node = ln as Label if is_instance_valid(ln) else null


# ---------------- 富文本标签（批次 91） ----------------

## 懒创建 RichTextLabel（只有 set_label_bbcode 过的按钮才会有这一个子节点）。
func _ensure_rich() -> RichTextLabel:
	if is_instance_valid(rich_node):
		return rich_node
	var rl := RichTextLabel.new()
	rl.name = "RichLabel"
	rl.bbcode_enabled = true
	rl.scroll_active = false
	rl.fit_content = false
	rl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rl.add_theme_color_override("default_color", UIStyle.TEXT_DEFAULT)
	rl.add_theme_font_size_override("normal_font_size", UIStyle.FONT_SIZE)
	var fnt = UIStyle.get_cjk_font()
	if fnt != null:
		rl.add_theme_font_override("normal_font", fnt)
	add_child(rl)
	rich_node = rl
	if not resized.is_connected(_layout_rich):
		resized.connect(_layout_rich)
	_layout_rich.call_deferred()
	return rl


## ★ RichTextLabel **没有**「垂直居中」属性（Label 有）→ 按内容高度在本按钮内居中。
##   横向必须拉满按钮宽度：定义串里的 L / C / R（左 / 中 / 右对齐）才有意义
##   （BBCode 的 [center]/[right] 只影响「行在段落里的位置」，段落本身要够宽）。
##   与 bottom_dialogue_panel._center_lines 同一套做法。
func _layout_rich() -> void:
	if not _rich_wanted or not is_instance_valid(rich_node) or not is_inside_tree():
		return
	var w: float = maxf(size.x, 1.0)
	var full_h: float = maxf(size.y, 1.0)
	# 先把宽度定下来，get_content_height() 才是「按这个宽度换行后」的高度
	rich_node.position = Vector2.ZERO
	rich_node.size = Vector2(w, full_h)
	var h: float = rich_node.get_content_height()
	if h <= 0.0:
		# 刚 add_child / 刚 set_text，排版还没算完 → 先占满，下一帧再量一次（只重试一次）。
		h = full_h
		if not _rich_retry:
			_rich_retry = true
			_layout_rich.call_deferred()
	else:
		_rich_retry = false
	h = minf(h, full_h)
	rich_node.position = Vector2(0.0, (full_h - h) * 0.5)
	rich_node.size = Vector2(w, h)


func _force_size(s: Vector2) -> void:
	size = s
	# ★ 用 is_instance_valid 而非 `if panel:`：panel 若已被释放，`if panel:` 仍可能为真，
	#   对已释放节点设 size 是 use-after-free（可致 native signal 11）。见 context_menu.open 的代际守卫。
	if is_instance_valid(panel):
		panel.size = s
	_layout_rich()

func _get_self_size() -> Vector2:
	return size

func _on_mouse_entered() -> void:
	_hover = true
	_apply_visual()

func _on_mouse_exited() -> void:
	_hover = false
	# 鼠标移出时按下的状态一并清掉（避免在按钮外松手后仍停在 pressed 观感）
	_down = false
	_apply_visual()

func _on_button_down() -> void:
	# ★ 先刷新视觉、**再**发信号：pressed_id 的处理函数常会 close()/queue_free() 掉本按钮所在的面板，
	#   若先发信号，后面的 _apply_visual() 就会作用在一个已脱离场景树的节点上
	#   → `get_global_mouse_position()` 因 viewport 为 null 报错（崩溃日志里刷屏的正是这条），
	#   且属于「对游离节点取全局坐标」的危险操作。先刷新可彻底避开。
	_down = true
	_apply_visual()
	if sfx_enabled:
		ButtonSfx.play_click()
	pressed_id.emit(_id)

func _on_button_up() -> void:
	# ★ button_up 时必须复位 _down：BaseButton 非 toggle 模式下 button_pressed 一旦松开即为 false，
	#   但旧实现没有连 button_up → 视觉可能一直停在"按下"态直到下次 mouse_entered/exited。
	#   （本函数在 pressed_id 处理函数里被 queue_free 的按钮上可能不触发，但那时节点已释放、无害。）
	_down = false
	_apply_visual()

func _apply_visual() -> void:
	# 不在场景树内（被移除 / 正在释放）时直接跳过：get_global_mouse_position 需要有效 viewport。
	# ★ panel 用 is_instance_valid 兜底（可能已被释放）。
	if not is_instance_valid(panel) or not is_inside_tree():
		return
	# 三态：按下 > 悬停 > 常规。**只读 _down / _hover 状态**，不再现场查鼠标位置（见顶部说明）。
	# ★ 批次 58：悬停同时点亮「填充 + 描边」—— 原来只改填充，在磨砂玻璃上几乎看不出变化。
	if _down:
		panel.set_fill_color(UIStyle.FILL_PRESSED)
		panel.set_border_width(UIStyle.BORDER_WIDTH)
		panel.set_border_color(UIStyle.BORDER)
	elif _hover:
		panel.set_fill_color(UIStyle.FILL_HOVER)
		panel.set_border_width(UIStyle.BORDER_WIDTH_HOVER)
		panel.set_border_color(UIStyle.BORDER_HOVER)
	else:
		panel.set_fill_color(UIStyle.FILL_DEFAULT)
		panel.set_border_width(UIStyle.BORDER_WIDTH)
		panel.set_border_color(UIStyle.BORDER)
	if is_instance_valid(label_node):
		if _down:
			label_node.add_theme_color_override("font_color", UIStyle.TEXT_PRESSED)
		else:
			label_node.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	# 富文本模式：BBCode 里的颜色由定义串决定（改不了），这里只同步「无颜色标签时的兜底色」。
	if is_instance_valid(rich_node):
		rich_node.add_theme_color_override("default_color",
			UIStyle.TEXT_PRESSED if _down else UIStyle.TEXT_DEFAULT)