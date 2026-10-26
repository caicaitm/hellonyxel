# long_text_input_panel.gd
# 长文本输入窗（从 abandon 版 v0.2.0 迁移复用，适配新版 UIPanel/UIStyle/UIBtn）
#
# 使用自定义贪婪折行实现自动换行（本版本 Godot 的 TextEdit.autowrap_mode 实测不生效，
# 故手动按控件宽度折行；用户硬回车统一视为可断行点）。
# - 文本实时同步回源输入框（LineEdit）
# - 顶栏：拖动把柄 + 标题 + 关闭按钮（锚定在背景角落）
# - 右下角：调整大小把柄（UIDragResizeHandle），拖动可改变窗口大小
#
# 用法:
#   var panel := UILongTextInputPanel.new()
#   panel.open(source_edit, "示例文本")   # source_edit 为 LineEdit
#   ui_layer.add_child(panel)
#
# 信号:
#   closed
#
# ── 修饰编辑区（右侧竖列）───────────────────────────────────
# 「(修饰)[内容]」富文本定义可在此可视化编辑：
#   第 1 行：下拉框选择「第几个修饰」
#   第 2 行：对齐按钮(L/C/R 替换) + 换行勾选
#   第 3 行：字号(@)、透明度(%)
#   第 4 行：RGB(#RRGGBB) 输入框 + 色块，下方取色盘双向联动
#   下拉选项数 = 定义中带 "()" 修饰的片段数；为 0 时整段修饰编辑区隐藏
# ★ 修饰区固定在**面板右侧竖列**（原先占顶部横带）：不再压住顶栏的关闭按钮与
#   右下角调整把柄；显示时正文书写框只从右侧让出宽度，面板同步加宽以免挤扁正文。
# （长文本视图中片段按括号/引号正确边界切分，标签输入等无 "()" 的正文不会显示该区）
#
# ── 「(」自动补全 ────────────────────────────────────────────
# 在书写框里敲下第一个「(」时，自动补成「(默认修饰)[]」，并把光标落进 [] 内继续写字
# （修饰交给右侧可视化编辑区，别让用户手打一长串 "#RRGGBB@字号%透明度对齐"）：
#   · 默认修饰走 TextRenderer.new_segment() → build_modifier()，即「项目默认字色/16 号/
#     不透明/左对齐」（当前为 #FFFFFFL）——渲染器默认值改了这里自动跟随，不写死字符串。
#   · 两种情形**不补全**：
#       ① 该「(」被 [] 包裹（位于 [内容] 内部）→ 那是正文字面括号，不是修饰头；
#       ② 该「(」不在片段开头（前面除空白外既不是 "+" 也不是文本开头）→
#          补出来的 "(… )[]" 本来就不会被 split_plus/parse 当成修饰段。
#   · 判别方式：与上一帧原始文本比对，确认「本次只是在光标左侧插入了一个 (」，
#     再用光标位置定位候选点（不用逐字符扫，长文本下 GDScript 逐字符扫很慢）。
extends Control
class_name UILongTextInputPanel

signal closed

# ============================================================
# 成员节点
# ============================================================

var _bg: UIPanel
var _top_bar: HBoxContainer
var _close_btn: UIBtn
var _drag_handle: UIDragHandle
var _resize_handle: UIDragResizeHandle
var _text_edit: TextEdit
var _title_label: Label

# 修饰编辑区
var _decor_col: ScrollContainer
var _decor_root: VBoxContainer
var _seg_select: OptionButton
var _align_l: UIBtn
var _align_c: UIBtn
var _align_r: UIBtn
var _newline_cb: CheckBox
var _size_input: LineEdit
var _alpha_input: LineEdit
var _rgb_input: LineEdit
var _swatch: Panel
var _color_picker: ColorPicker

# ============================================================
# 回填目标
# ============================================================

var _source_edit: LineEdit = null

# 重新折行时的递归保护(设置 text 会再次触发 text_changed)
var _reflowing: bool = false
# 修饰编辑更新(加载/写回)时的递归保护
var _loading: bool = false

var _renderer := TextRenderer.new()
var _tokens: PackedStringArray = []
var _decor_positions: Array[int] = []
var _decor_visible: bool = false
var _align_val: String = "L"
var _align_group := ButtonGroup.new()

# 上一次「回灌到修饰输入框」的修饰串（★ 用于避免每次按键都覆盖用户正在输入的修饰框）
var _loaded_mod: String = ""
# 上一次的原始逻辑文本（无折行换行符）——「(」自动补全靠它比对出「本次只插入了一个 (」
var _last_raw: String = ""
# 尺寸自动补足的重入保护（resized → _on_panel_resized 链上可能再次触发）
var _sizing: bool = false
# 折行用的字符宽度缓存（同一字号下复用；长文本每帧要量上万个字形，缓存后同字不重复塑形）
var _char_w_cache: Dictionary = {}
var _char_w_cache_fs: int = -1
# 超长文本跳过自动折行的告警只报一次
var _cap_warned: bool = false

# ============================================================
# 尺寸常量
# ============================================================

const DEFAULT_WIDTH: float = 480.0
const DEFAULT_HEIGHT: float = 320.0
const DEFAULT_HEIGHT_DECOR: float = 700.0
const MIN_WIDTH: float = 280.0
const MIN_HEIGHT: float = 180.0
const MIN_HEIGHT_DECOR: float = 460.0
const TITLE_BAR_HEIGHT: float = 36.0
## 修饰编辑区（右侧竖列）：列宽按面板宽度自适应 + 内外边距 + 有修饰区时的默认/最小面板宽度
## ★ DECOR_COL_MIN 取 304：取色盘自身最小宽 298，低于它会被横向挤扁
const DECOR_COL_RATIO: float = 0.38
const DECOR_COL_MIN: float = 304.0
const DECOR_COL_MAX: float = 320.0
const DECOR_GAP: float = 8.0
const DEFAULT_WIDTH_DECOR: float = 820.0
const MIN_WIDTH_DECOR: float = 620.0
## 面板与屏幕边缘至少留出的空隙（自动尺寸/位置时用）
const PANEL_EDGE: float = 32.0
const FONT_SIZE: int = 14
## 自动折行的长度上限：折行要逐字量宽度（O(n) 次字形塑形），
## 几十万字符时单次折行会到秒级，把整个编辑器卡死 → 超过上限就不再自动折行（保留手动编辑）。
const MAX_AUTOWRAP_LEN: int = 200000
const RESIZE_HANDLE_SIZE: float = 28.0   # ★ 与 UIDragHandle（移动把柄）/UIDragResizeHandle 家族默认一致
const RESIZE_HANDLE_INSET: float = 6.0
const BUTTON_SIZE: float = 28.0
const INPUT_W: float = 56.0
const ALIGN_BTN_W: float = 30.0
const SWATCH_W: float = 46.0

# ============================================================
# _ready
# ============================================================

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(MIN_WIDTH, MIN_HEIGHT)
	_build_ui()
	visible = false

# ============================================================
# 构建 UI
# ============================================================


# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏控件整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build_ui() -> void:
	## 1. 背景面板（比内容区大，底部留出把柄空间）
	_bg = UIPanel.new()
	_bg.name = "Bg"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.anchor_bottom = 1.0
	## 底部多留出把柄区域（把柄顶边与背景底边贴合）
	_bg.offset_bottom = -int(RESIZE_HANDLE_INSET) + 4
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	## 2. 顶栏（固定高度，锚定顶部）
	_top_bar = HBoxContainer.new()
	_top_bar.name = "TopBar"
	_top_bar.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_top_bar.anchor_bottom = 0.0
	_top_bar.offset_bottom = TITLE_BAR_HEIGHT
	_top_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_top_bar)

	## 3. 拖动把柄（左上角）
	_drag_handle = UIDragHandle.new()
	_drag_handle.name = "DragHandle"
	_drag_handle.setup(self)
	_top_bar.add_child(_drag_handle)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top_bar.add_child(spacer)

	## 4. 标题
	_title_label = Label.new()
	_title_label.name = "Title"
	_title_label.text = "长文本编辑"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_title_label.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0, 1.0))
	_title_label.add_theme_font_size_override("font_size", int(UIStyle.FONT_SIZE) + 1)
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top_bar.add_child(_title_label)

	## 5. 关闭按钮（右上角，锚定在背景角落）
	_close_btn = UIBtn.new()
	_close_btn.name = "CloseBtn"
	_close_btn.set_label("×")
	_close_btn.set_id("close")
	## 锚定在右上角，按钮向右下延伸（尺寸由锚点+偏移决定，不调用 set_size）
	_close_btn.anchor_left = 1.0
	_close_btn.anchor_top = 0.0
	_close_btn.anchor_right = 1.0
	_close_btn.anchor_bottom = 0.0
	_close_btn.offset_left = -BUTTON_SIZE
	_close_btn.offset_top = 4.0
	_close_btn.offset_right = -4.0
	_close_btn.offset_bottom = BUTTON_SIZE + 4.0
	_close_btn.pressed_id.connect(_on_btn_pressed)
	add_child(_close_btn)
	_min_btn = UIMinimize.attach_anchored(self, _close_btn, func(): set_minimized(not _minimized))

	## 6. 修饰编辑区（顶栏下方，含片段下拉/对齐/字号/透明度/RGB+取色盘；按 "()" 数量显隐）
	_build_decor_editor()

	## 7. 文本编辑区（使用内置自动换行 + 手动折行兜底）
	_text_edit = TextEdit.new()
	_text_edit.name = "TextEdit"
	_text_edit.set_anchors_preset(Control.PRESET_FULL_RECT)
	## 顶部留出标题栏与修饰编辑区，底部留出把柄区域
	_text_edit.offset_top = int(TITLE_BAR_HEIGHT)
	_text_edit.offset_bottom = -int(RESIZE_HANDLE_INSET + RESIZE_HANDLE_SIZE + 2.0)
	_text_edit.custom_minimum_size = Vector2(MIN_WIDTH, MIN_HEIGHT - TITLE_BAR_HEIGHT - RESIZE_HANDLE_INSET - RESIZE_HANDLE_SIZE)
	_text_edit.add_theme_font_size_override("font_size", FONT_SIZE)
	## 显式注入 CJK 字体，保证中文按字符宽度正确折行（否则 get_theme_font 可能为空导致不折行）
	var cjk := UIStyle.get_cjk_font()
	if cjk != null:
		_text_edit.add_theme_font_override("font", cjk)
	# 统一书写框外观（与各面板输入框一致，避免默认主题 StyleBox 尺寸不匹配）
	_text_edit.add_theme_stylebox_override("normal", UIStyle.line_edit_stylebox(false))
	_text_edit.add_theme_stylebox_override("focus", UIStyle.line_edit_stylebox(true))
	_text_edit.add_theme_stylebox_override("read_only", UIStyle.line_edit_stylebox(false))
	_text_edit.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_text_edit.add_theme_color_override("caret_color", UIStyle.TEXT_DEFAULT)
	_text_edit.add_theme_color_override("selection_color", Color(0.30, 0.75, 1.0, 0.45))
	_text_edit.placeholder_text = "在此输入长文本，内容会实时同步到原输入框…"
	## 关掉 scroll_fit_content_width，确保书写框宽度只由页面(FULL_RECT)决定，不随文本长度变化
	_text_edit.scroll_fit_content_width = false
	_text_edit.text_changed.connect(_on_text_changed)
	add_child(_text_edit)
	## 隐藏内部横向滚动条(纵向保留用于长文滚动)
	_hide_scrollbars(_text_edit)
	## 面板尺寸变化(拖拽把柄)时重新折行，书写框宽度只随页面变化
	resized.connect(_on_panel_resized)

	## 7. 调整大小把柄（右下角，锚定在背景角落）—— 复用 abandon 版「调整页面大小」按钮
	_resize_handle = UIDragResizeHandle.new()
	_resize_handle.name = "ResizeHandle"
	_resize_handle.setup(self)
	_resize_handle.anchor_left = 1.0
	_resize_handle.anchor_top = 1.0
	_resize_handle.anchor_right = 1.0
	_resize_handle.anchor_bottom = 1.0
	## 把柄向右下延伸
	_resize_handle.offset_left = -RESIZE_HANDLE_SIZE - 4.0
	_resize_handle.offset_top = -RESIZE_HANDLE_SIZE - RESIZE_HANDLE_INSET
	_resize_handle.offset_right = -4.0
	## 把柄底边与背景底边贴合（offset_bottom = -INSET → 底边在 y=314）
	_resize_handle.offset_bottom = -RESIZE_HANDLE_INSET
	_resize_handle.custom_minimum_size = Vector2(RESIZE_HANDLE_SIZE, RESIZE_HANDLE_SIZE)
	_resize_handle.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_resize_handle)


# ============================================================
# 修饰编辑区
# ============================================================

func _build_decor_editor() -> void:
	## ★ 右侧竖列外层用滚动容器：修饰区内容（取色盘最小高 ~600px）比面板高是常态，
	##   直接当竖列会**溢出面板外**压住下方按钮 → 由滚动条接管，永远不越界。
	_decor_col = ScrollContainer.new()
	_decor_col.name = "DecorColumn"
	_decor_col.anchor_left = 1.0
	_decor_col.anchor_right = 1.0
	_decor_col.anchor_top = 0.0
	_decor_col.anchor_bottom = 1.0
	_decor_col.offset_left = -(DECOR_COL_MAX + DECOR_GAP)
	_decor_col.offset_right = -DECOR_GAP
	_decor_col.offset_top = TITLE_BAR_HEIGHT + 2.0
	_decor_col.offset_bottom = -(RESIZE_HANDLE_INSET + RESIZE_HANDLE_SIZE + 2.0)
	_decor_col.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_decor_col.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_decor_col.visible = false
	add_child(_decor_col)

	_decor_root = VBoxContainer.new()
	_decor_root.name = "DecorEditor"
	_decor_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_decor_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_decor_root.add_theme_constant_override("separation", 4)
	_decor_col.add_child(_decor_root)

	## 第一行：片段选择 + 对齐(L/C/R 替换) + 换行
	var row_a := HBoxContainer.new()
	row_a.add_theme_constant_override("separation", 6)
	_decor_root.add_child(row_a)
	row_a.add_child(_decor_label("修饰", 0))
	_seg_select = OptionButton.new()
	_seg_select.custom_minimum_size = Vector2(110.0, 26.0)
	_seg_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seg_select.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_seg_select.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	var cf := UIStyle.get_cjk_font()
	if cf != null:
		_seg_select.add_theme_font_override("font", cf)
	_seg_select.item_selected.connect(_on_segment_selected)
	row_a.add_child(_seg_select)

	## 第二行：对齐(L/C/R 替换) + 换行
	var row_b := HBoxContainer.new()
	row_b.add_theme_constant_override("separation", 6)
	_decor_root.add_child(row_b)
	row_b.add_child(_decor_label("对齐", 34))
	_align_l = _align_btn("L", "align_L")
	_align_c = _align_btn("C", "align_C")
	_align_r = _align_btn("R", "align_R")
	row_b.add_child(_align_l)
	row_b.add_child(_align_c)
	row_b.add_child(_align_r)
	_newline_cb = CheckBox.new()
	_newline_cb.text = "换行(\\n)"
	_newline_cb.custom_minimum_size = Vector2(86.0, 26.0)
	_newline_cb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_newline_cb.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	_newline_cb.add_theme_color_override("font_color", Color.WHITE)
	_newline_cb.toggled.connect(_on_decor_toggled)
	row_b.add_child(_newline_cb)

	## 第三行：字号 + 透明度
	var row_c := HBoxContainer.new()
	row_c.add_theme_constant_override("separation", 6)
	_decor_root.add_child(row_c)
	row_c.add_child(_decor_label("字号@", 34))
	_size_input = _decor_input(INPUT_W)
	_size_input.text_changed.connect(_on_decor_edited)
	row_c.add_child(_size_input)
	row_c.add_child(_decor_label("透明度%", 34))
	_alpha_input = _decor_input(INPUT_W)
	_alpha_input.text_changed.connect(_on_decor_edited)
	row_c.add_child(_alpha_input)

	## 第四行：RGB 输入框 + 色块
	var row_d := HBoxContainer.new()
	row_d.add_theme_constant_override("separation", 6)
	_decor_root.add_child(row_d)
	row_d.add_child(_decor_label("RGB", 34))
	_rgb_input = _decor_input(130)
	_rgb_input.placeholder_text = "#RRGGBB"
	_rgb_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rgb_input.text_changed.connect(_on_rgb_edited)
	row_d.add_child(_rgb_input)
	_swatch = Panel.new()
	_swatch.custom_minimum_size = Vector2(SWATCH_W, 26.0)
	_swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row_d.add_child(_swatch)

	## 取色盘（占满剩余空间，双向联动）
	_color_picker = ColorPicker.new()
	_color_picker.name = "ColorPicker"
	_color_picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_color_picker.custom_minimum_size = Vector2(0, 150.0)
	## ★ 关掉三块本面板用不到的部件：它们让取色盘最小尺寸涨到 298×607
	##   （色板预设 / 自带十六进制框〈本面板另有 RGB 输入框〉/ 色彩模式切换按钮）
	##   → 关掉后 298×467，竖列里放得下，不必滚动。
	_color_picker.presets_visible = false
	_color_picker.hex_visible = false
	_color_picker.color_modes_visible = false
	_color_picker.color_changed.connect(_on_color_changed)
	_decor_root.add_child(_color_picker)


func _decor_label(text: String, w: float) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(w, 26.0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", Color(0.75, 0.9, 1.0, 1.0))
	l.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cf := UIStyle.get_cjk_font()
	if cf != null:
		l.add_theme_font_override("font", cf)
	return l


func _decor_input(w: float) -> LineEdit:
	var le := LineEdit.new()
	le.custom_minimum_size = Vector2(w, 26.0)
	le.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	UIStyle.apply_line_edit_style(le)
	return le


func _align_btn(text: String, id: String) -> UIBtn:
	var b := UIBtn.new()
	b.set_id(id)
	b.set_label(text)
	b.custom_minimum_size = Vector2(ALIGN_BTN_W, 26.0)
	b.size = Vector2(ALIGN_BTN_W, 26.0)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.toggle_mode = true
	b.button_group = _align_group
	## ★ 不能写成 _on_align_pressed.bind(id)：pressed_id 本身已经带 id，
	##   再 bind 一次 = 实参 2 个 → 「Method expected 1 argument(s), but called with 2」→ 按钮彻底失效
	b.pressed_id.connect(_on_align_pressed)
	return b


func _set_align_button(al: String) -> void:
	_align_l.button_pressed = al == "L"
	_align_c.button_pressed = al == "C"
	_align_r.button_pressed = al == "R"


func _set_decor_visible(v: bool) -> void:
	_decor_visible = v
	if _decor_col:
		_decor_col.visible = v
	## 书写框恒定从标题栏下方开始；显示修饰区时**只从右侧**让出宽度（不再压到下方）
	if _text_edit:
		_text_edit.offset_top = int(TITLE_BAR_HEIGHT)
	_apply_decor_layout()


## 修饰区列宽：随面板宽度自适应（窄面板不至于把正文挤没，宽面板也不浪费）
func _decor_col_width() -> float:
	return clampf(size.x * DECOR_COL_RATIO, DECOR_COL_MIN, DECOR_COL_MAX)


## 把「修饰竖列宽度」写进修饰列与书写框的锚点偏移（面板缩放/显隐变化后都要刷）
func _apply_decor_layout() -> void:
	if _decor_col:
		var col_w: float = _decor_col_width()
		_decor_col.offset_left = -(col_w + DECOR_GAP)
		_decor_col.offset_right = -DECOR_GAP
	if _text_edit:
		if _decor_visible:
			_text_edit.offset_right = -(_decor_col_width() + DECOR_GAP * 2.0)
		else:
			_text_edit.offset_right = -DECOR_GAP


## 正文书写框可用宽度（由面板宽度与修饰区显隐直接推出，不依赖子节点布局时机）
func _text_area_width() -> float:
	var sub: float = (_decor_col_width() + DECOR_GAP * 2.0) if _decor_visible else DECOR_GAP
	return maxf(self.size.x - sub, 80.0)


## 面板出现修饰片段却还没加宽时补足尺寸（避免修饰竖列溢出面板外、盖住下方按钮）
func _ensure_size_for_decor() -> void:
	## ★ 重入保护：本函数会改 size → 触发 resized → _on_panel_resized → 重折行；
	##   而它自己又是从 text_changed 链（_refresh_segments）上被调用的，容易叠成布局递归。
	if _sizing:
		return
	_sizing = true
	## 修饰竖列有最小宽度 → 面板下限也必须跟着抬到「列宽 + 正文最小宽」，
	## 否则拖小面板时正文书写框会被挤成负宽度
	custom_minimum_size = Vector2(MIN_WIDTH_DECOR, MIN_HEIGHT_DECOR)
	var vp := get_viewport()
	var vs: Vector2 = UIStyle.canvas_viewport_size(self) if vp != null else Vector2(1280.0, 720.0)
	var want := Vector2(maxf(size.x, DEFAULT_WIDTH_DECOR), maxf(size.y, DEFAULT_HEIGHT_DECOR))
	want.x = minf(want.x, maxf(MIN_WIDTH_DECOR, vs.x - PANEL_EDGE))
	want.y = minf(want.y, maxf(MIN_HEIGHT_DECOR, vs.y - PANEL_EDGE))
	if want != size:
		size = want
		position = Vector2(clampf(position.x, 0.0, maxf(0.0, vs.x - size.x)),
			clampf(position.y, 0.0, maxf(0.0, vs.y - size.y)))
	_sizing = false


func _refresh_segments() -> void:
	if not is_inside_tree():
		return
	var prev_sel: int = _seg_select.selected
	_tokens = _renderer.split_plus(_raw_text())
	_decor_positions.clear()
	for i in _tokens.size():
		if _tokens[i].strip_edges().begins_with("("):
			_decor_positions.append(i)
	var count: int = _decor_positions.size()
	_loading = true
	if _seg_select.item_count != count:
		_seg_select.clear()
		for k in count:
			_seg_select.add_item("修饰 %d" % (k + 1))
		if count > 0:
			_seg_select.select(clampi(prev_sel, 0, count - 1))
	_set_decor_visible(count > 0)
	if count > 0:
		## 运行中才出现修饰片段（面板原先是没加宽的小窗）→ 补足尺寸，别让修饰竖列溢出面板
		_ensure_size_for_decor()
		## ★ 只有「当前片段的修饰串真的变了」才把值回灌到修饰输入框，且光标在修饰区内时绝不回灌。
		##   原先每敲一个键都无条件回灌 → 用户刚输一半的字号/透明度会被旧值覆盖，且每次都白刷一遍控件。
		var mod_now: String = _segment_modifier(_seg_select.selected)
		if mod_now != _loaded_mod and not _decor_input_has_focus():
			_load_decor_values(_seg_select.selected)
	_loading = false


## 取第 idx 个修饰片段的修饰串（"(...)" 内的内容）；越界 / 无括号 → 空串
func _segment_modifier(idx: int) -> String:
	if idx < 0 or idx >= _decor_positions.size():
		return ""
	var tk: String = _tokens[_decor_positions[idx]]
	var op: int = tk.find("(")
	var ep: int = tk.find(")")
	if op == -1 or ep == -1 or ep <= op:
		return ""
	return tk.substr(op + 1, ep - op - 1)


## 焦点是否在修饰编辑区里（在则不覆盖用户正在输入的内容）
func _decor_input_has_focus() -> bool:
	var vp := get_viewport()
	if vp == null:
		return false
	var fo := vp.gui_get_focus_owner()
	if fo == null or _decor_col == null:
		return false
	return fo == _decor_col or _decor_col.is_ancestor_of(fo)


func _load_decor_values(sel_index: int) -> void:
	if sel_index < 0 or sel_index >= _decor_positions.size():
		return
	var tk: String = _tokens[_decor_positions[sel_index]]
	var op: int = tk.find("(")
	var ep: int = tk.find(")")
	if op == -1 or ep == -1 or ep <= op:
		return
	var mod: String = tk.substr(op + 1, ep - op - 1)
	_loaded_mod = mod
	var seg: TextRenderer.TextSegment = _renderer.new_segment()
	_renderer.apply_modifier(seg, mod)
	var disp_a: float = clampf(seg.alpha * seg.fill_color.a, 0.0, 1.0)
	_rgb_input.text = "#" + Color(seg.fill_color.r, seg.fill_color.g, seg.fill_color.b).to_html(false)
	_alpha_input.text = "%d" % roundi(disp_a * 100.0)
	_size_input.text = str(seg.font_size)
	_newline_cb.button_pressed = seg.newline
	var col: Color = _color_of_controls()
	_color_picker.color = col
	_sync_swatch(col)
	var al: String = seg.align
	_align_val = al
	_set_align_button(al)


func _apply_decor_to_def() -> void:
	if _loading or _decor_positions.is_empty():
		return
	var sel: int = _seg_select.selected
	if sel < 0 or sel >= _decor_positions.size():
		return
	var pos: int = _decor_positions[sel]
	var tk: String = _tokens[pos]
	var op: int = tk.find("(")
	var ep: int = tk.find(")")
	if op == -1 or ep == -1:
		return
	var seg: TextRenderer.TextSegment = _renderer.new_segment()
	var rgbc: Variant = _parse_rgb(_rgb_input.text)
	if rgbc != null:
		seg.fill_color = Color(rgbc.r, rgbc.g, rgbc.b, 1.0)
	seg.alpha = _parse_alpha(_alpha_input.text)
	seg.font_size = _parse_size(_size_input.text)
	seg.newline = _newline_cb.button_pressed
	seg.align = _current_align()
	var new_mod: String = _renderer.build_modifier(seg)
	var new_tk: String = tk.substr(0, op) + "(" + new_mod + ")" + tk.substr(ep + 1)
	_tokens[pos] = new_tk
	_loaded_mod = new_mod
	var new_def: String = ""
	for k in _tokens.size():
		if k > 0:
			new_def += "+"
		new_def += _tokens[k]
	_loading = true
	_text_edit.text = _reflow(new_def)
	## 写回也算「文本已变」：同步自动补全的比对基线，否则下一次按键的比对会失真
	_last_raw = new_def
	if _source_edit != null and is_instance_valid(_source_edit) and _source_edit is LineEdit:
		_source_edit.text = new_def
	_loading = false


# ---- 修饰编辑区信号 ----

func _on_segment_selected(idx: int) -> void:
	if _loading or _decor_positions.is_empty():
		return
	_loading = true
	_load_decor_values(idx)
	_loading = false


func _on_decor_edited(_new_text: String = "") -> void:
	if _loading:
		return
	_apply_decor_to_def()


func _on_decor_toggled(_pressed: bool) -> void:
	_on_decor_edited()


func _on_align_pressed(id: String) -> void:
	if _loading:
		return
	var al: String = "R" if id == "align_R" else ("C" if id == "align_C" else "L")
	_align_val = al
	_set_align_button(al)
	_apply_decor_to_def()


func _on_rgb_edited(_new_text: String = "") -> void:
	if _loading:
		return
	var c: Variant = _parse_rgb(_rgb_input.text)
	if c != null:
		_loading = true
		var col := _color_of_controls()
		_color_picker.color = col
		_sync_swatch(col)
		_loading = false
	_apply_decor_to_def()


func _on_color_changed(c: Color) -> void:
	if _loading:
		return
	_loading = true
	_rgb_input.text = "#" + Color(c.r, c.g, c.b).to_html(false)
	_alpha_input.text = "%d" % roundi(clampf(c.a, 0.0, 1.0) * 100.0)
	_sync_swatch(c)
	_loading = false
	_apply_decor_to_def()


# ---- 修饰解析/序列化辅助 ----

func _raw_text() -> String:
	return _text_edit.text.replace("\n", "")


func _count_mod_segments(def: String) -> int:
	var toks: PackedStringArray = _renderer.split_plus(def)
	var c: int = 0
	for t in toks:
		if t.strip_edges().begins_with("("):
			c += 1
	return c


func _current_align() -> String:
	return _align_val


func _color_of_controls() -> Color:
	var v = _parse_rgb(_rgb_input.text)
	var c: Color = Color(1, 1, 1, 1) if v == null else v
	c.a = _parse_alpha(_alpha_input.text)
	return c


func _parse_rgb(t: String) -> Variant:
	t = t.strip_edges()
	if t.begins_with("#"):
		var hex := t.substr(1)
		if hex.length() == 6 and Color.html_is_valid(t):
			return Color(t)
		return null
	if "," in t:
		var parts := t.split(",")
		if parts.size() >= 3:
			var nums: Array[float] = []
			for k in mini(parts.size(), 3):
				var p := parts[k].strip_edges()
				if not p.is_valid_int():
					return null
				nums.append(clampf(float(int(p)) / 255.0, 0.0, 1.0))
			var cc := Color(nums[0], nums[1], nums[2])
			if parts.size() >= 4:
				var pa := parts[3].strip_edges()
				if pa.is_valid_int():
					cc.a = clampf(float(int(pa)) / 255.0, 0.0, 1.0)
			return cc
	return null


func _parse_alpha(t: String) -> float:
	t = t.strip_edges()
	if not t.is_valid_int():
		return 1.0
	return clampf(float(int(t)) / 100.0, 0.0, 1.0)


func _parse_size(t: String) -> int:
	t = t.strip_edges()
	if not t.is_valid_int():
		return 16
	return clampi(int(t), 6, 120)


func _sync_swatch(col: Color) -> void:
	if _swatch == null:
		return
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.border_color = Color(1, 1, 1, 0.65)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	_swatch.add_theme_stylebox_override("panel", sb)


# ============================================================
# 公开方法
# ============================================================

func open(source: LineEdit, initial_text: String = "") -> void:
	_source_edit = source
	## 视口兜底：尚未入树（异常路径/无头探针）时也不拿 0 尺寸去居中
	var vp := get_viewport()
	var vp_size: Vector2 = UIStyle.canvas_viewport_size(self) if vp != null else Vector2(1280.0, 720.0)
	var has_decor: bool = _count_mod_segments(initial_text) > 0
	## 有修饰片段 → 面板更宽（左侧正文 + 右侧修饰竖列），并保证不超出屏幕
	var want_w: float = DEFAULT_WIDTH_DECOR if has_decor else DEFAULT_WIDTH
	var want_h: float = DEFAULT_HEIGHT_DECOR if has_decor else DEFAULT_HEIGHT
	want_w = minf(want_w, maxf(MIN_WIDTH, vp_size.x - PANEL_EDGE))
	want_h = minf(want_h, maxf(MIN_HEIGHT, vp_size.y - PANEL_EDGE))
	var panel_size: Vector2 = Vector2(want_w, want_h)
	## 居中定位（本节点需挂在 CanvasLayer/视口空间下，position(0,0)=视口左上角）
	position = ((vp_size - panel_size) * 0.5).floor()
	size = panel_size
	custom_minimum_size = Vector2(MIN_WIDTH_DECOR if has_decor else MIN_WIDTH,
		MIN_HEIGHT_DECOR if has_decor else MIN_HEIGHT)
	_apply_decor_layout()
	## 设置初始文本(先按宽度折行, 保证长行不溢出)
	_text_edit.text = _reflow(initial_text)
	## 自动补全的比对基线：初始文本即「上一次的原始文本」（折行只加换行，逻辑文本不变）
	_last_raw = initial_text
	## 显式同步回源: text_changed 在初始赋值时未必触发, 这里直接写入原始逻辑文本(无换行)
	if _source_edit != null and is_instance_valid(_source_edit) and _source_edit is LineEdit:
		_source_edit.text = initial_text
	visible = true
	## 依据定义中 "()" 修饰片段数刷新下拉与修饰编辑区显隐
	_refresh_segments()
	_text_edit.grab_focus()
	queue_redraw()
	print("[UILongTextInputPanel] 打开  source=%s text_len=%d has_decor=%s" % [
		source.name if source else "null", initial_text.length(), has_decor])

func close() -> void:
	if _source_edit != null and is_instance_valid(_source_edit) and _source_edit is LineEdit:
		## 回填时去掉折行换行符，还原原始逻辑文本（逗号分隔的标签等）
		_source_edit.text = _text_edit.text.replace("\n", "")
		_source_edit.queue_redraw()
		print("[UILongTextInputPanel] 已回填: source=%s  len=%d" % [
			_source_edit.name, _text_edit.text.length()])
	_source_edit = null
	visible = false
	closed.emit()
	queue_free()

# ============================================================
# 信号处理
# ============================================================

func _on_text_changed() -> void:
	if _reflowing or _loading:
		return
	_reflowing = true
	# 记录光标在"原始文本"(去掉折行换行符)中的绝对位置
	var caret_raw: int = _caret_raw_index(_text_edit)
	# 原始文本 = 当前显示文本去掉换行符(本实现不保留用户硬回车，统一自动折行)
	var raw: String = _text_edit.text.replace("\n", "")
	## ★ 敲下第一个 "( " → 自动补成 "(默认修饰)[]"，光标落进 [] 内（见文件头「(」自动补全）
	var ac: Dictionary = _autocomplete_paren(raw, caret_raw)
	var completed: bool = ac.get("ok", false)
	if completed:
		raw = str(ac["text"])
		caret_raw = int(ac["caret"])
	var wrapped: String = _reflow(raw)
	if wrapped != _text_edit.text:
		_text_edit.text = wrapped
	## 光标按「原始文本绝对索引」重新定位：补全挪位 / set_text 把光标打回行首，都要在这一步纠正
	_restore_caret_from_raw(_text_edit, caret_raw)
	# 实时同步回源输入框(去掉换行，保持原始逻辑文本)
	if _source_edit != null and is_instance_valid(_source_edit) and _source_edit is LineEdit:
		_source_edit.text = raw
	_last_raw = raw
	_reflowing = false
	# 文本变了可能使修饰片段数量/内容变化 → 刷新修饰编辑区
	_refresh_segments()
	## ★★ 光标必须在 _refresh_segments() **之后**再校正一次：
	##   首次出现修饰片段时 _ensure_size_for_decor() 会把面板加宽 → 触发 resized →
	##   重折行又一次 set_text → Godot 的 set_text 会把光标打回行首。
	##   少了这一步，用户在窄面板里敲下 "(" 后面板一变宽，光标就跳到开头。
	_restore_caret_from_raw(_text_edit, caret_raw)

func _on_btn_pressed(id: String) -> void:
	if id == "close":
		close()

# ============================================================
# 「(」自动补全修饰
# ============================================================

## 默认修饰串：与渲染器「空片段」的默认样式一致（项目默认字色 / 16 号 / 不透明 / 左对齐）
func _default_modifier() -> String:
	return _renderer.build_modifier(_renderer.new_segment())


## 位置 i 之前未闭合的 "[" 数；> 0 表示该处位于 [内容] 内部
func _bracket_depth_at(raw: String, i: int) -> int:
	var depth: int = 0
	var lim: int = clampi(i, 0, raw.length())
	for k in lim:
		var ch: String = raw[k]
		if ch == "[":
			depth += 1
		elif ch == "]":
			depth = maxi(depth - 1, 0)
	return depth


## 位置 i 是否处在「片段开头」（前面除空白外只有 "+"，或就是文本开头）。
## 只有片段开头的 "(" 才会被 split_plus/parse 认成修饰头，写在正文中间的不是。
func _is_segment_head(raw: String, i: int) -> bool:
	var k: int = i - 1
	while k >= 0:
		var ch: String = raw[k]
		if ch == " " or ch == "\t":
			k -= 1
			continue
		return ch == "+"
	return true


## 本次输入是否恰好是「在 prev 的 index 处插入了一个 "("」？是则返回该索引，否则 -1。
## ★ 用光标位置做候选点（打字后光标就在插入字符的右侧），再用前后缀切片比对确认：
##   长文本下不能逐字符扫（GDScript 字符串索引慢），substr 是 C++ 级的复制+比较。
func _inserted_paren_at(prev: String, cur: String, i: int) -> int:
	if cur.length() != prev.length() + 1:
		return -1
	if i < 0 or i >= cur.length():
		return -1
	if cur[i] != "(":
		return -1
	if cur.substr(0, i) != prev.substr(0, i):
		return -1
	if cur.substr(i + 1) != prev.substr(i):
		return -1
	return i


## 该位置的 "(" 是否应该自动补全（判据见文件头「(」自动补全）
func _should_autocomplete_paren(raw: String, i: int) -> bool:
	if _bracket_depth_at(raw, i) > 0:
		return false          # 被 [] 包裹 → 正文字面括号，不补
	if not _is_segment_head(raw, i):
		return false          # 不在片段开头 → 补出来也不是修饰段
	if i + 1 < raw.length() and raw[i + 1] == ")":
		return false          # 右侧已有 ")" → 用户在自己写括号对，别插手
	return true


## 自动补全：把 "(" 补成 "(默认修饰)[]"，光标落进 [] 内。
## 返回 { ok:bool, text:String, caret:int }；ok=false 时调用方保持原文不动。
func _autocomplete_paren(raw: String, caret_raw: int) -> Dictionary:
	var i: int = _inserted_paren_at(_last_raw, raw, caret_raw - 1)
	if i < 0 or not _should_autocomplete_paren(raw, i):
		return { "ok": false }
	var mod: String = _default_modifier()
	return {
		"ok": true,
		"text": raw.substr(0, i + 1) + mod + ")[]" + raw.substr(i + 1),
		"caret": i + 1 + mod.length() + 2,
	}

# ============================================================
# 手动折行(TextEdit.autowrap_mode 在本版本 Godot 不生效，故自实现)
# ============================================================

## 按书写框可用宽度把原始文本(无换行)折行，返回带换行符的显示文本
func _reflow(raw: String) -> String:
	if raw == "":
		return ""
	## ★ 超长文本直接不折行：折行是 O(n) 次字形度量，几十万字符时单次就能到秒级，
	##   而 text_changed / resized 每帧都会调它 → 整个编辑器（乃至整个游戏）卡死。
	if raw.length() > MAX_AUTOWRAP_LEN:
		if not _cap_warned:
			_cap_warned = true
			push_warning("[UILongTextInputPanel] 文本长度 %d 超过自动折行上限 %d，已停止自动折行（仍可正常编辑）"
				% [raw.length(), MAX_AUTOWRAP_LEN])
		return raw
	## ★ 用**书写框自身**宽度算（显示修饰竖列时书写框只占左侧，不能再拿整个面板宽度算）
	var avail: float = _text_area_width() - 24.0
	if avail < 40.0:
		avail = 40.0
	var font: Font = _text_edit.get_theme_font("font")
	var fs: int = _text_edit.get_theme_font_size("font_size")
	if font == null:
		return raw
	return _wrap_greedy(raw, avail, font, fs)


## 单字符宽度（带缓存）：同一字号下同字只塑形一次。
## 中文长文本重复字多、字数大，缓存后折行开销从「每帧 N 次字形塑形」降到 N 次字典查表。
func _char_width(ch: String, font: Font, fs: int) -> float:
	if fs != _char_w_cache_fs:
		_char_w_cache.clear()
		_char_w_cache_fs = fs
	if _char_w_cache.has(ch):
		return _char_w_cache[ch]
	var w: float = font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	_char_w_cache[ch] = w
	return w


## 贪婪折行：优先在空格/逗号/句号等分隔符处断行，否则在任意字符处断行（记事本效果）
func _wrap_greedy(text: String, max_w: float, font: Font, fs: int) -> String:
	var result: String = ""
	var line: String = ""
	var line_w: float = 0.0
	var break_at: int = -1
	for i in text.length():
		var ch: String = text[i]
		if ch == "\n":
			result += line + "\n"
			line = ""
			line_w = 0.0
			break_at = -1
			continue
		var cw: float = _char_width(ch, font, fs)
		if line_w + cw > max_w and line.length() > 0:
			if break_at >= 0:
				result += line.substr(0, break_at + 1) + "\n"
				line = line.substr(break_at + 1) + ch
				line_w = font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				break_at = _last_break(line)
			else:
				result += line + "\n"
				line = ch
				line_w = cw
				break_at = -1
		else:
			if _is_break_char(ch):
				break_at = line.length()
			line += ch
			line_w += cw
	result += line
	return result

func _is_break_char(ch: String) -> bool:
	return ch == " " or ch == "," or ch == "，" or ch == "、" or ch == "；" or ch == "。" or ch == "\t"

## 返回字符串中最后一个可断行分隔符的索引(空格/逗号/中文逗号)，没有则 -1
func _last_break(s: String) -> int:
	var best: int = -1
	var c: int = s.rfind(" ")
	if c > best:
		best = c
	c = s.rfind(",")
	if c > best:
		best = c
	c = s.rfind("，")
	if c > best:
		best = c
	return best

## 当前光标在"原始文本"(去换行)中的绝对字符索引
## 注意：Godot 4 的 TextEdit 没有 caret_line/caret_column 属性，用方法访问
func _caret_raw_index(te: TextEdit) -> int:
	var abs_idx: int = 0
	var cl: int = te.get_caret_line()
	for li in cl:
		abs_idx += te.get_line(li).length() + 1
	abs_idx += te.get_caret_column()
	return abs_idx - cl

## 把原始文本绝对索引映射回折行后显示的 (line, col) 并还原光标
func _restore_caret_from_raw(te: TextEdit, raw_idx: int) -> void:
	var remaining: int = raw_idx
	var line: int = 0
	while line < te.get_line_count():
		var ll: int = te.get_line(line).length()
		if remaining <= ll:
			te.set_caret_line(line, false)
			te.set_caret_column(remaining)
			return
		remaining -= ll
		line += 1
	te.set_caret_line(max(0, te.get_line_count() - 1), false)
	te.set_caret_column(te.get_line(te.get_line_count() - 1).length())

## 面板尺寸变化(拖拽调整把柄)后重新折行，保持书写框只随页面宽度变化
func _on_panel_resized() -> void:
	## 列宽与书写框宽度都随面板宽度变 → 先重算偏移，再折行
	_apply_decor_layout()
	if _reflowing:
		return
	_reflowing = true
	## ★ set_text 会把光标打回行首 → 折行前后都要按「原始文本绝对索引」保住光标，
	##   否则拖一下面板 / 修饰区展开，正在编辑的光标就跳回开头（继续打字会打错地方）
	var caret_raw: int = _caret_raw_index(_text_edit)
	var raw: String = _text_edit.text.replace("\n", "")
	var wrapped: String = _reflow(raw)
	if wrapped != _text_edit.text:
		_text_edit.text = wrapped
		_restore_caret_from_raw(_text_edit, caret_raw)
	_reflowing = false

# ============================================================
# 工具函数
# ============================================================

# 只隐藏横向滚动条(手动折行后本不应出现)；纵向滚动条保留用于长文滚动。
# 参数用 Node：TextEdit 的子节点不一定是 TextEdit（如 ScrollBar），
# 若把参数写成 TextEdit，递归调用会在运行时抛类型错误。
func _hide_scrollbars(node: Node) -> void:
	if node is ScrollBar and not (node as ScrollBar).vertical:
		(node as ScrollBar).visible = false
	for child in node.get_children():
		_hide_scrollbars(child)

# ============================================================
# 键盘
# ============================================================

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
	UIMinimize.set_label(_min_btn, v)
	UIMinimize.fold_top_strip(self, v)
	UIMinimize.apply_size(self, v)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
