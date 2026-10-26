# ui/mod_list_panel.gd
# MOD 列表页（占位）—— 由系统托盘右键菜单「打开MOD列表」打开。
#
# 目前仅作占位：标题栏（拖动把柄 + 标题 + 关闭按钮）+ 空白列表区 + 右下角调整大小把柄。
# 与设置 / 存档 / 天气 / AI 页一致：常驻实例，open()/close() 只切显隐（不销毁）。
# 后续接入真实 MOD 列表时，把 _hint 换成列表容器即可。
class_name ModListPanel
extends Control

const PANEL_W: float = 520.0
const PANEL_H: float = 380.0
const TITLE_H: float = 28.0

var _bg: UIPanel
var _title_label: Label
var _hint: Label
var _drag_handle: UIDragHandle
var _resize_handle: UIDragResizeHandle
var _cjk: FontFile


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_cjk = UIStyle.get_cjk_font()
	_build_ui()
	visible = false



# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏控件整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build_ui() -> void:
	# 入树前（headless 探针 / 极端时机）get_viewport() 为 null → 给安全尺寸，别报错
	var vp := get_viewport()
	var vs := UIStyle.canvas_viewport_size(self) if vp != null else Vector2(1280.0, 720.0)
	size = Vector2(PANEL_W, PANEL_H)
	position = Vector2(maxf(40.0, (vs.x - PANEL_W) * 0.5), maxf(60.0, (vs.y - PANEL_H) * 0.35))

	_bg = UIPanel.new()
	_bg.bind_page_dark_bg()
	_bg.name = "Bg"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	# ★ 边框用「深色区」配套色（STAGE_BORDER，深蓝 alpha 0.95）：默认的 BORDER 是亮白蓝
	#   alpha 0.65，画在亮色玻璃填充上几乎融掉 → 用户反馈「MOD 列表不论是否最小化都看不到边框」。
	_bg.set_border_color(UIStyle.STAGE_BORDER)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	# 关闭按钮（右上角，锚定）
	var close_btn := UIBtn.new()
	close_btn.name = "CloseBtn"
	close_btn.set_id("close")
	close_btn.set_label("×")
	close_btn.anchor_left = 1.0
	close_btn.anchor_top = 0.0
	close_btn.anchor_right = 1.0
	close_btn.anchor_bottom = 0.0
	close_btn.offset_left = -(TITLE_H + UIStyle.PANEL_PADDING)
	close_btn.offset_top = UIStyle.PANEL_PADDING
	close_btn.offset_right = -UIStyle.PANEL_PADDING
	close_btn.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING
	close_btn.pressed_id.connect(_on_close_pressed)
	add_child(close_btn)
	_min_btn = UIMinimize.attach_anchored(self, close_btn, func(): set_minimized(not _minimized))

	# 拖动把柄（关闭按钮左侧，锚定右上角）
	_drag_handle = UIDragHandle.new()
	_drag_handle.name = "DragHandle"
	_drag_handle.setup(self)
	_drag_handle.anchor_left = 1.0
	_drag_handle.anchor_top = 0.0
	_drag_handle.anchor_right = 1.0
	_drag_handle.anchor_bottom = 0.0
	_drag_handle.offset_left = -(TITLE_H * 2.0 + UIStyle.PANEL_PADDING + 4.0)
	_drag_handle.offset_top = UIStyle.PANEL_PADDING
	_drag_handle.offset_right = -(TITLE_H + UIStyle.PANEL_PADDING + 4.0)
	_drag_handle.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING
	add_child(_drag_handle)

	# 标题（左上角）
	_title_label = Label.new()
	_title_label.text = "MOD 列表"
	_title_label.position = Vector2(UIStyle.PANEL_PADDING + 2.0, UIStyle.PANEL_PADDING)
	_title_label.custom_minimum_size = Vector2(0.0, TITLE_H)
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", Color(0.8, 0.94, 1.0))
	_title_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 1)
	if is_instance_valid(_cjk):
		_title_label.add_theme_font_override("font", _cjk)
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_title_label)

	# 空白列表区（占位提示，随面板拉伸居中）
	_hint = Label.new()
	_hint.text = "（暂无 MOD · 占位页面）"
	_hint.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hint.offset_left = UIStyle.PANEL_PADDING
	_hint.offset_top = TITLE_H + UIStyle.PANEL_PADDING
	_hint.offset_right = -UIStyle.PANEL_PADDING
	_hint.offset_bottom = -(TITLE_H + UIStyle.PANEL_PADDING)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint.add_theme_color_override("font_color", Color(0.8, 0.89, 0.99, 0.7))
	_hint.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_cjk):
		_hint.add_theme_font_override("font", _cjk)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hint)

	# 调整大小把柄（右下角，锚定）
	_resize_handle = UIDragResizeHandle.new()
	_resize_handle.name = "ResizeHandle"
	_resize_handle.setup(self)
	_resize_handle.anchor_left = 1.0
	_resize_handle.anchor_top = 1.0
	_resize_handle.anchor_right = 1.0
	_resize_handle.anchor_bottom = 1.0
	_resize_handle.offset_left = -(TITLE_H + 4.0)
	_resize_handle.offset_top = -(TITLE_H + 4.0)
	_resize_handle.offset_right = -4.0
	_resize_handle.offset_bottom = -4.0
	add_child(_resize_handle)


# 打开（显示）—— 托盘菜单唯一入口；常驻实例只切显隐。
func open() -> void:
	visible = true
	move_to_front()


# 关闭（隐藏）—— 不销毁，下次 open() 复用。
func close() -> void:
	visible = false


func is_open() -> bool:
	return visible


func _on_close_pressed(_id: String) -> void:
	close()


## 最小化 / 还原：折叠只隐藏内容，标题栏控件（标题 / 把柄 / 最小化 / 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.set_label(_min_btn, v)
	UIMinimize.fold_top_strip(self, v)
	UIMinimize.apply_size(self, v)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
