# ui/event_chain_editor_panel.gd
# 事件链 · 可视化编辑器（阶段一）。
#
# 布局（自上而下，行不等高，仅示意排布）：
#   · 顶栏：事件链名 / 事件名 / [读取][保存] / 保存到(本体|DLC|MOD)
#   · 1) 关闭的目标     —— 多选目标（弹窗/底部/通知/积木ID/关卡），存 json.close
#   · 2) 正文          —— 语言下拉 + 面板类型下拉 + 该面板的修改内容(含正文 txt)
#   · 3) 按钮条目      —— [+]
#   · 4) 打开的目标     —— 同 1)，存 json.open；「自动(正文对应)」= 打开【2】正文里选的那个对话框，
#                          默认就带这一条；删掉它 = 本次事件不打开任何面板（正文仍写进面板缓存）
# 按钮字段：id / 文字内容(label) / 效果(effect) / 显示要求(show)，均支持长文本编辑
#   （id 与文字解耦 → 允许"文本相同、效果不同"的按钮并存）。
#
# 目标条目两种形态：
#   · 字符串（"popup"/"bottom"/"notification"）= 点名的面板；
#   · 带参数（积木ID → int；关卡 → { "level": "<关卡名>" }）= 下拉选类型 + 旁边输入框填值。
#
# 落盘规则（见计划书 §2）：res://events/<链名>/<事件名>.json + <逻辑名>_<语言>.txt。
class_name EventChainEditorPanel
extends Control

const PANEL_W: float = 880.0   # 顶栏新增「事件链名 / 事件名」两个下拉后加宽，避免两个输入框被挤窄
# 页面初始高度 = 内容自然高度 × 此倍数。
#   （调整大小把柄已移除 → 不再让用户拖拽，直接把初始高度给到原来的 2 倍。）
const HEIGHT_SCALE: float = 2.0
const PAD: float = 12.0
const TITLE_H: float = 28.0
const ROW_GAP: float = 4.0
const LONG_BTN_W: float = 56.0
const WIDE_EDIT_W: float = 150.0
const SMALL_EDIT_W: float = 72.0

# 顶栏下拉哨兵：index 0 恒为「（无选择）」——
#   既是"没有选任何项"的默认显示，也是"清空输入框"的入口。
#   没有它时第一个条目会落在 index 0，而 `selected` 恰好也是 0 → 造成"默认选中第一项"的假象。
const MENU_NONE_LABEL: String = "（无选择）"
const MENU_NONE_INDEX: int = 0

# 目标类型（close/open 共用）下拉 → 值
const TARGET_ITEMS: Array = ["弹窗", "底部", "通知", "积木ID", "关卡"]
const TARGET_VALUES: Array = ["popup", "bottom", "notification", "", "level"]  # 末两项=带输入框的参数型
const TARGET_BLOCK: int = 3
const TARGET_LEVEL: int = 4

# ★「打开」列表在末尾**追加**一项 auto（值 = EventFile.TARGET_AUTO），「关闭」列表没有它 ——
#   关掉"正文对应的面板"没有意义（正文步骤刚把内容写进去）。
#   追加到**末尾** → 前 5 项的索引一个不动，TARGET_BLOCK / TARGET_LEVEL 仍然有效。
#   语义（见 EventFile.TARGET_AUTO）：打开【2】正文里选的那个对话框；
#   删掉它 = 本次事件不打开任何面板（正文仍写进面板缓存，但面板保持原样）。
const TARGET_AUTO_LABEL: String = "自动(正文对应)"

# 面板类型（正文）下拉 → 值
#   ★ 第一项「无修改」是**默认值**：该事件不改动任何正文/面板 ——
#     不写 content 的正文参数、不打开/不覆盖任何面板、不碰台词 txt。
#     很多事件只做「关闭/打开目标 + 按钮条目」，本来就没有台词反馈。
const PTYPE_NONE := ""
const PTYPE_ITEMS: Array = ["无修改", "弹窗", "底部", "冒泡", "通知"]
const PTYPE_VALUES: Array = ["", "popup", "bottom", "bubble", "notification"]
const PTYPE_NONE_IDX: int = 0

# 声音（底部台词播放）默认值：auto = 逐字/逐词泡泡声
#   auto            → 逐字/逐词泡泡声
#   auto:相对路径   → 同上，但把「一声」的声源换成该音频
#   相对路径        → 整段播该文件
#   留空            → 不发声
const VOICE_DEFAULT := "auto"

# ★ 批次 95 去重：按钮条目的「效果」行与正文的「正文效果(底部)」行**是同一个页面**。
#   两处都由 EffectEditorPanel 承载、编辑同一种效果 DSL，所以标题也只留这一个常量 ——
#   不再有「正文效果编辑」这种第二名字（同页两个名字会让人以为是两套东西）。
const EFFECT_PAGE_TITLE: String = "效果编辑"

var _bg: UIPanel
var _scroll: ScrollContainer
var _vbox: VBoxContainer
var _close_btn: UIBtn
var _drag_handle: UIDragHandle   # 顶栏拖动把柄（复用 UIDragHandle，× 左侧）
var _cjk: FontFile

# 顶栏控件
var _chain_edit: LineEdit        # 事件链名
var _name_edit: LineEdit         # 事件名
var _chain_option: OptionButton  # 事件链名下拉（点开时遍历 res://events 下的目录）
var _name_option: OptionButton   # 事件名下拉（点开时遍历该链下的 *.json）
var _save_opt: OptionButton      # 保存到(本体/DLC/MOD)

# 目标列表
var _close_list: VBoxContainer   # 关闭的对话框
var _open_list: VBoxContainer    # 打开的对话框

# 正文区
var _lang_opt: OptionButton      # 语言
var _lang_label: Label           # 「语言」标签（无修改时一并收起）
var _ptype_opt: OptionButton     # 面板类型
var _content_hint: Label         # 「无修改」提示（仅该类型显示）
var _tf_row: Control             # 正文文件名行（无修改时收起）
var _content_row: Control        # 正文内容行（含「长文本」按钮；无修改时收起）
var _title_row: Control
var _title_edit: LineEdit
var _image_row: Control
var _image_edit: LineEdit
var _bg_image_row: Control       # 头像背景层（仅底部；头像透明处透出；空 = 不绘制背景）
var _bg_image_edit: LineEdit
var _block_row: Control
var _block_edit: LineEdit
var _wait_row: Control
var _wait_check: CheckBox
var _voice_row: Control
var _voice_edit: LineEdit        # 声音(底部)：默认 auto（逐字/逐词泡泡声）
var _effect_row: Control         # 正文效果(底部)：点击台词执行（与按钮 effect 同源）
var _effect_edit: LineEdit
var _text_file_edit: LineEdit    # 正文文件名(不含语言)
var _content_edit: LineEdit      # 正文内容(当前语言 txt) + 长文本
# ★ 编辑框里这份内容**属于哪个语言**（切语言时必须按这个写回）。
#   不能读 _lang_opt.selected —— item_selected 触发时 selected 已经是**新**语言了，
#   那样会把旧语言的正文/按钮文字写进新语言 txt，直接覆盖掉那份翻译（历史 bug）。
var _lang_shown: String = ""

# 按钮条目
var _buttons_box: VBoxContainer

# 页面头
var _header_label: Label

# 事件链配置（**内联**在本页【1】上方）—— 触发事件 / 触发条件 / 权重
var _trigger_option: OptionButton     # 触发事件下拉（当前事件链内的事件名）
var _cfg_cond_edit: LineEdit          # 触发条件
var _cfg_weight_edit: LineEdit        # 权重
var _cfg_read_btn: UIBtn
var _cfg_save_btn: UIBtn
var _cfg_status: Label
var _cfg_trigger: String = ""         # 触发事件的**真源**（下拉只是选择入口）

# 长文本面板 / 占位编辑页
var _popup_layer: CanvasLayer
var _active_long: UILongTextInputPanel = null
# ★ 批次 94：改成**列表**（每项 {kind, le, panel}）→ 效果页 / 条件页可同时多开、各绑不同字段。
var _placeholder_panels: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_cjk = UIStyle.get_cjk_font()
	_build_ui()
	_build_top_bar()
	_build_chain_config_section()   # ★ 事件链配置**内联**在本页【1】关闭的目标之上
	_build_close_section()
	_build_content_section()
	_build_buttons_section()
	_build_open_section()
	_apply_ptype(_ptype_opt.selected)
	_refresh_current_lang_txt()
	# ★ 高度 = 内容自然高度 × HEIGHT_SCALE(2)，仅受屏幕高度约束（超高则滚动）。
	#   调整大小把柄已移除，用户在设置里改不了高度 → 初始就给足。
	call_deferred("_fit_to_content")


# 让面板高度 = 内容自然高度的 HEIGHT_SCALE(2) 倍（含顶栏 + 四周边距），仅夹在屏幕可容纳高度内。
# 必须在所有 section 构建完、且子树布局过一帧后再量，min size 才有意义。
func _fit_to_content() -> void:
	if not is_instance_valid(_vbox) or not is_instance_valid(_scroll):
		return
	var vp := get_viewport()
	var vs := UIStyle.canvas_viewport_size(self) if vp != null else Vector2(1280.0, 720.0)
	var ch: float = _vbox.get_combined_minimum_size().y
	var base := TITLE_H + UIStyle.PANEL_PADDING * 2.0 + ch
	var want := base * HEIGHT_SCALE
	var cap := vs.y - 80.0
	size.y = maxf(200.0, minf(want, cap))
	_scroll.size.y = maxf(0.0, size.y - TITLE_H - UIStyle.PANEL_PADDING * 2.0)
	position.y = maxf(40.0, (vs.y - size.y) * 0.3)


# ---------------- 基础构建 ----------------


# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏控件整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build_ui() -> void:
	_layout_root()
	_bg = UIPanel.new()
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	_close_btn = UIBtn.new()
	_close_btn.set_id("close")
	_close_btn.set_label("×")
	_close_btn.custom_minimum_size = Vector2(TITLE_H, TITLE_H)
	_close_btn.size = Vector2(TITLE_H, TITLE_H)
	_close_btn.position = Vector2(PANEL_W - TITLE_H - UIStyle.PANEL_PADDING, UIStyle.PANEL_PADDING)
	_close_btn.pressed_id.connect(_on_close_pressed)
	add_child(_close_btn)
	_min_btn = UIMinimize.attach_anchored(self, _close_btn, func(): set_minimized(not _minimized))

	# 移动页面按钮：复用 UIDragHandle（四向箭头拖动把柄），放在 × 关闭按钮左侧，
	# 按住可拖动整个编辑器面板（与属性面板 / 长文本面板同款交互）
	_drag_handle = UIDragHandle.new()
	_drag_handle.setup(self)
	_drag_handle.position = Vector2(
		PANEL_W - TITLE_H * 2.0 - UIStyle.PANEL_PADDING - 4.0, UIStyle.PANEL_PADDING)
	add_child(_drag_handle)

	# 页面头：固定标题「事件链编辑器」（位于左上角，不随正文滚动）
	_header_label = Label.new()
	_header_label.text = "事件链编辑器"
	_header_label.position = Vector2(UIStyle.PANEL_PADDING + 2.0, UIStyle.PANEL_PADDING)
	_header_label.custom_minimum_size = Vector2(0.0, TITLE_H)
	_header_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_header_label.add_theme_color_override("font_color", Color(0.8, 0.94, 1.0))
	_header_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 3)
	if is_instance_valid(_cjk):
		_header_label.add_theme_font_override("font", _cjk)
	_header_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_header_label)

	_scroll = ScrollContainer.new()
	_scroll.position = Vector2(UIStyle.PANEL_PADDING, TITLE_H + UIStyle.PANEL_PADDING)
	_scroll.size = Vector2(PANEL_W - UIStyle.PANEL_PADDING * 2.0, size.y - TITLE_H - UIStyle.PANEL_PADDING * 2.0)
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_scroll)

	_vbox = VBoxContainer.new()
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_theme_constant_override("separation", ROW_GAP)
	_scroll.add_child(_vbox)

	# ★ 「调整页面大小」把柄已**移除** —— 初始高度改为内容自然高度的 HEIGHT_SCALE(2) 倍（见 _fit_to_content）。
	# 保留 resized → 滚动区高度跟随（面板尺寸由代码设定时同样生效）。
	resized.connect(_on_panel_resized)


# 面板尺寸变化 → 正文滚动区高度跟随（顶栏工具行 + 上下内边距之外都归滚动区）
func _on_panel_resized() -> void:
	if not is_instance_valid(_scroll):
		return
	_scroll.size.y = maxf(0.0, size.y - TITLE_H - UIStyle.PANEL_PADDING * 2.0)


func _layout_root() -> void:
	# 尚未入树时（headless 探针 / 极端时机）get_viewport() 为 null → 给个安全尺寸，别报错
	var vp := get_viewport()
	var vs := UIStyle.canvas_viewport_size(self) if vp != null else Vector2(1280.0, 720.0)
	size = Vector2(PANEL_W, minf(760.0, vs.y - 80.0))
	position = Vector2(maxf(16.0, vs.x - PANEL_W - 24.0), maxf(40.0, (vs.y - size.y) * 0.3))


# ---------------- 分区与折叠（批次 116，用户需求）----------------
#
# 需求：事件链配置等内容较长的分区要能**折叠**，收起后不再占高度。
# 手法与 blocks/level_page.gd 的「▼ 配置」一致 —— **标题本身就是按钮**：点它切换 ▼/▶，
# 并让该分区的内容容器（body）的 visible 跟着变。
#   每个分区 = 【标题行：折叠按钮 + 该分区自己的按钮】 + 【body：VBoxContainer】，
#   两者都直接挂在 _vbox 上（body 不另起缩进层级，层级靠标题前的箭头表达）。
#
# ★ 折叠**不重算面板高度**：高度由 _fit_to_content()（建树时算一次 = 内容自然高 × HEIGHT_SCALE(2)）
#   定下；折叠只让 body 不占高度 → 下面的内容整体上移、底部留白（本来就有 2 倍余量，够用）。
#   ★★ 刻意**不**在折叠时重跑 _fit_to_content()：那个函数还会重设 position.y，
#   会把用户用拖动把柄挪到别处的面板**拽回原位**（每点一次折叠就跳一下）。
var _sections: Dictionary = {}       # key -> { btn:UIBtn, body:VBoxContainer, title:String, open:bool }
var _sec_head: HBoxContainer = null  # 最近一次 _add_section 建出的标题行（供该分区追加自己的按钮）


## 折叠按钮的宽度：**必须显式给**。
## ★★ UIBtn 是 BaseButton，内部 Label 用 PRESET_FULL_RECT 锚定 → **不计入按钮的最小尺寸**
##   ⇒ `custom_minimum_size` 只给高、宽度给 0 时，按钮实际宽 = 0：
##     文字照画（Label 不裁剪、溢出父框）却**点不到**（探针 116 v5 实测 size=(0,28)，
##     截图里看到的那个小方框其实是紧接着的 `[+]` 按钮）。
##   本项目所有 UIBtn 都显式给宽（64 / 72 / 96 / 120…），这里按**文字实测宽**给，
##   取 ▼/▶ 两种箭头里的较宽者 + 左右内边距，保证折叠前后框宽一致、文字不外溢。
func _toggle_width(title: String) -> float:
	var w := 0.0
	if is_instance_valid(_cjk):
		for arrow in ["▼ ", "▶ "]:
			var m := _cjk.get_string_size(arrow + title, HORIZONTAL_ALIGNMENT_LEFT, -1, UIStyle.FONT_SIZE)
			w = maxf(w, m.x)
	if w <= 0.0:
		w = 120.0
	return maxf(88.0, w + 22.0)   # +22 = 左右内边距（UIBtn 的 Label 居中对齐）


## 建一个可折叠分区，返回**内容容器**（body）—— 调用方把该分区的控件全加进 body。
## 标题行（含折叠按钮）由本函数挂到 _vbox，并记进 _sec_head。
func _add_section(key: String, title: String, open: bool = true) -> VBoxContainer:
	var head := HBoxContainer.new()
	head.name = "SecHead_" + key
	head.add_theme_constant_override("separation", 8)
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var btn := UIBtn.new()
	btn.name = "SecToggle_" + key
	btn.set_id("collapse_" + key)
	# ★ 宽必须与「标题文字」一起算出来（见 _toggle_width）：0 宽 = 看得到、点不到
	btn.custom_minimum_size = Vector2(_toggle_width(title), UIStyle.BTN_HEIGHT)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	# ★ 用 lambda 捕获 key（而不是 .bind）：实参个数与 pressed_id(id) 严格 1:1，
	#   过门④（信号形参审计）时无需额外解释。
	btn.pressed_id.connect(func(_id: String) -> void: _toggle_section(key))
	head.add_child(btn)
	_vbox.add_child(head)

	var body := VBoxContainer.new()
	body.name = "SecBody_" + key
	body.add_theme_constant_override("separation", ROW_GAP)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_child(body)

	_sections[key] = {"btn": btn, "body": body, "title": title, "open": open}
	_sec_head = head
	_apply_section_state(key)
	return body


## 点折叠按钮：翻转该分区的开合状态
func _toggle_section(key: String) -> void:
	if not _sections.has(key):
		return
	var d: Dictionary = _sections[key]
	d["open"] = not bool(d["open"])
	_apply_section_state(key)


## 按 _sections[key]["open"] 同步 body 可见性与标题箭头
func _apply_section_state(key: String) -> void:
	if not _sections.has(key):
		return
	var d: Dictionary = _sections[key]
	var open := bool(d["open"])
	var title := str(d["title"])
	var body := d["body"] as Control
	if body != null and is_instance_valid(body):
		body.visible = open
	var btn := d["btn"] as UIBtn
	if btn != null and is_instance_valid(btn):
		btn.set_label(("▼ " if open else "▶ ") + title)
		btn.tooltip_text = ("收起／展开：" + title)


## 该分区当前是否展开（探针 / future 用；无此 key → false）
func is_section_open(key: String) -> bool:
	if not _sections.has(key):
		return false
	return bool((_sections[key] as Dictionary)["open"])


## 当前所有分区的 key（顺序 = 构建顺序）
func section_keys() -> Array:
	return _sections.keys()


func _label(text: String, w: float = 0.0) -> Label:
	var l := Label.new()
	l.text = text
	if w > 0.0:
		l.custom_minimum_size = Vector2(w, 0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	l.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_cjk):
		l.add_theme_font_override("font", _cjk)
	return l


func _edit(placeholder: String, expand: bool = true, w: float = 0.0) -> LineEdit:
	var le := LineEdit.new()
	le.placeholder_text = placeholder
	if expand:
		le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		le.custom_minimum_size = Vector2(w, 0)
	le.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_cjk):
		le.add_theme_font_override("font", _cjk)
	UIStyle.apply_line_edit_style(le)
	return le


# 统一风格的下拉选项（CJK 字体 + 字号），供「事件链名 / 事件名」复用。
func _menu_option(node_name: String) -> OptionButton:
	var opt := OptionButton.new()
	opt.name = node_name
	opt.fit_to_longest_item = false
	if is_instance_valid(_cjk):
		opt.add_theme_font_override("font", _cjk)
	opt.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	opt.custom_minimum_size = Vector2(SMALL_EDIT_W, 0)
	opt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return opt


# 生成带「长文本」按钮的字段行：返回 [LineEdit(expand), HBox(edit+longbtn)] 里的 HBox
func _field_with_long(le: LineEdit) -> HBoxContainer:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 4)
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(le)
	var lb := UIBtn.new()
	lb.set_id("long")
	lb.set_label("长文本")
	lb.custom_minimum_size = Vector2(LONG_BTN_W, UIStyle.BTN_HEIGHT)
	lb.size = Vector2(LONG_BTN_W, UIStyle.BTN_HEIGHT)
	lb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lb.pressed_id.connect(_open_long.bind(le))
	hb.add_child(lb)
	return hb


# 在「长文本」按钮后追加一枚「编辑」按钮：打开该字段对应的独立可视化编辑页。
# ★ 批次 94：kind 三种 —— "effect"（效果编辑页）/ "show"（显示要求）/ "trigger"（触发条件）；
#   show 与 trigger 共用**同一个**「编辑条件」页（ConditionEditorPanel），只是提示语不同。
# ★ 批次 95：正文的「正文效果(底部)」行也走 kind="effect"（见 _build_content_section），
#   即「效果」这个词全域只有**一个**编辑页。
func _field_with_long_edit(le: LineEdit, kind: String) -> HBoxContainer:
	var hb := _field_with_long(le)
	var ed := UIBtn.new()
	ed.set_id("edit")
	ed.set_label("编辑")
	ed.custom_minimum_size = Vector2(LONG_BTN_W, UIStyle.BTN_HEIGHT)
	ed.size = Vector2(LONG_BTN_W, UIStyle.BTN_HEIGHT)
	ed.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ed.pressed_id.connect(func(_id: String) -> void: _open_placeholder_editor(kind, le))
	hb.add_child(ed)
	return hb


# ---------------- 顶栏 ----------------

func _build_top_bar() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_child(row)

	_chain_edit = _edit("事件链名")
	row.add_child(_chain_edit)
	# 事件链名下拉：点开时才遍历 res://events 下的目录（懒加载）
	_chain_option = _menu_option("ChainMenu")
	_chain_option.add_item(MENU_NONE_LABEL)
	_chain_option.select(MENU_NONE_INDEX)
	_chain_option.get_popup().about_to_popup.connect(_reload_chain_menu)
	_chain_option.item_selected.connect(_on_chain_menu_selected)
	row.add_child(_chain_option)

	_name_edit = _edit("事件名")
	row.add_child(_name_edit)
	# 事件名下拉：点开时（或选过链名后）遍历对应事件链下的事件名
	_name_option = _menu_option("NameMenu")
	_name_option.add_item(MENU_NONE_LABEL)
	_name_option.select(MENU_NONE_INDEX)
	_name_option.get_popup().about_to_popup.connect(_reload_name_menu)
	_name_option.item_selected.connect(_on_name_menu_selected)
	row.add_child(_name_option)

	var read_btn := UIBtn.new()
	read_btn.set_id("read")
	read_btn.set_label("读取")
	read_btn.custom_minimum_size = Vector2(64.0, UIStyle.BTN_HEIGHT)
	read_btn.pressed_id.connect(_on_read_pressed)
	row.add_child(read_btn)

	var save_btn := UIBtn.new()
	save_btn.set_id("save")
	save_btn.set_label("保存")
	save_btn.custom_minimum_size = Vector2(64.0, UIStyle.BTN_HEIGHT)
	save_btn.pressed_id.connect(_on_save_pressed)
	row.add_child(save_btn)

	var run_btn := UIBtn.new()
	run_btn.set_id("run")
	run_btn.set_label("运行")
	run_btn.custom_minimum_size = Vector2(64.0, UIStyle.BTN_HEIGHT)
	run_btn.pressed_id.connect(_on_run_pressed)
	row.add_child(run_btn)

	row.add_child(_label("保存到", 48))
	_save_opt = OptionButton.new()
	_save_opt.add_item("本体")
	_save_opt.add_item("DLC")
	_save_opt.add_item("MOD")
	_save_opt.selected = 2   # 默认 MOD
	_save_opt.select(_save_opt.selected)
	if is_instance_valid(_cjk):
		_save_opt.add_theme_font_override("font", _cjk)
	_save_opt.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	_save_opt.custom_minimum_size = Vector2(WIDE_EDIT_W, 0)
	row.add_child(_save_opt)


# ---------------- 顶栏下拉：事件链 / 事件名 ----------------
# ★ 条目在「点开下拉的那一刻」才生成（_reload_*），避免启动时就遍历磁盘。
# ★★ 必须挂 PopupMenu 的 about_to_popup，**不能**挂 OptionButton.pressed：
#   OptionButton 内部 _pressed() 会先把自己的条目灌进 PopupMenu 并立刻弹窗，之后才派发 pressed；
#   此时再 clear() 会把刚弹出的菜单清空 → 下拉"一点就收、展不开"。
#   about_to_popup 在菜单显示之前发出，此刻重建条目正好赶上。

# 生成/刷新「已有事件链」下拉：遍历 res://events 下的目录。
func _reload_chain_menu() -> void:
	if _chain_option == null or not is_instance_valid(_chain_option):
		return
	var pop := _chain_option.get_popup()
	if pop.visible:
		pop.hide()
	_chain_option.clear()
	# ★ index 0 恒为「无选择」：clear() 不复位 selected，重建后手动复位。
	_chain_option.add_item(MENU_NONE_LABEL)
	var chains: Array[String] = EventFile.list_chains()
	if chains.is_empty():
		_chain_option.add_item("（events/ 下暂无事件链）")
		_chain_option.set_item_disabled(1, true)
		_chain_option.select(MENU_NONE_INDEX)
		return
	for c in chains:
		_chain_option.add_item(str(c))
	# 输入框里现有的链名若在列表里 → 高亮（预览当前值）；否则回到「无选择」
	var cur := _chain()
	for i in chains.size():
		if str(chains[i]) == cur:
			_chain_option.select(i + 1)   # ★ 偏移 1（index 0 是「无选择」）
			return
	_chain_option.select(MENU_NONE_INDEX)


# 选择了事件链：把链名填进输入框，并**立即**按该链遍历事件名（预填事件名下拉）。
# 不清空事件名输入框（用户可能想沿用当前名字）。清空交给「无选择」。
func _on_chain_menu_selected(idx: int) -> void:
	if _chain_option == null or not is_instance_valid(_chain_option):
		return
	if idx < 0 or idx >= _chain_option.get_item_count():
		return
	var t := _chain_option.get_item_text(idx)
	# 「无选择」/ 提示项：清空链名输入框并把下拉复位。★ 判据用双条件（只靠 index 布局变会误判，
	# 只靠文案怕事件链名恰好以「（」开头）。
	if (idx == MENU_NONE_INDEX and t == MENU_NONE_LABEL) or t.is_empty() or t.begins_with("（"):
		_chain_option.select(MENU_NONE_INDEX)
		if _chain_edit != null and is_instance_valid(_chain_edit):
			_chain_edit.text = ""
		_reload_name_menu()
		_load_chain_config()   # 换链 → 同步刷新内联的事件链配置
		return
	if _chain_edit != null and is_instance_valid(_chain_edit):
		_chain_edit.text = t
	_reload_name_menu()
	_load_chain_config()       # 换链 → 同步刷新内联的事件链配置


# 生成/刷新「事件名」下拉：遍历当前事件链下的 *.json。
func _reload_name_menu() -> void:
	if _name_option == null or not is_instance_valid(_name_option):
		return
	var pop := _name_option.get_popup()
	if pop.visible:
		pop.hide()
	_name_option.clear()
	_name_option.add_item(MENU_NONE_LABEL)
	var chain := _chain()
	if chain.is_empty():
		_name_option.add_item("（请先选择 / 填写事件链）")
		_name_option.set_item_disabled(1, true)
		_name_option.select(MENU_NONE_INDEX)
		return
	if not EventFile.chain_exists(chain):
		_name_option.add_item("（该事件链不存在）")
		_name_option.set_item_disabled(1, true)
		_name_option.select(MENU_NONE_INDEX)
		return
	var names: Array[String] = EventFile.list_event_names(chain)
	if names.is_empty():
		_name_option.add_item("（该事件链下暂无事件）")
		_name_option.set_item_disabled(1, true)
		_name_option.select(MENU_NONE_INDEX)
		return
	for n in names:
		_name_option.add_item(str(n))
	var cur := _name()
	for i in names.size():
		if str(names[i]) == cur:
			_name_option.select(i + 1)
			return
	_name_option.select(MENU_NONE_INDEX)


# 选择了事件名：把名字填进输入框（不自动读取，读取交给「读取」按钮）。
func _on_name_menu_selected(idx: int) -> void:
	if _name_option == null or not is_instance_valid(_name_option):
		return
	if idx < 0 or idx >= _name_option.get_item_count():
		return
	var t := _name_option.get_item_text(idx)
	if (idx == MENU_NONE_INDEX and t == MENU_NONE_LABEL) or t.is_empty() or t.begins_with("（"):
		_name_option.select(MENU_NONE_INDEX)
		if _name_edit != null and is_instance_valid(_name_edit):
			_name_edit.text = ""
		return
	if _name_edit != null and is_instance_valid(_name_edit):
		_name_edit.text = t


# ---------------- 事件链配置（内联在本页） ----------------
# 位于【1】关闭的目标**上方**：配置该事件链的「触发事件 / 触发条件 / 权重」。
# 配置以 JSON 落盘到**事件链目录**下（res://events/<链名>/config.json），供其他系统检测。

func _build_chain_config_section() -> void:
	# ★ 批次 116：本分区带折叠按钮（用户需求）
	var sec := _add_section("chain_config", "事件链配置")

	# 触发事件：下拉选择「当前事件链内的某个事件」
	# （与「事件名」下拉同款：点开才遍历该链下的 *.json）
	var r1 := HBoxContainer.new()
	r1.add_theme_constant_override("separation", 6)
	r1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r1.add_child(_label("触发事件", 84))
	_trigger_option = _menu_option("TriggerMenu")
	_trigger_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_trigger_option.add_item(MENU_NONE_LABEL)
	_trigger_option.select(MENU_NONE_INDEX)
	_trigger_option.get_popup().about_to_popup.connect(_reload_trigger_menu)
	_trigger_option.item_selected.connect(_on_trigger_menu_selected)
	r1.add_child(_trigger_option)
	sec.add_child(r1)

	# 触发条件（可长文本；★ 批次 94：加「编辑」按钮 → 打开统一后的「编辑条件」页）
	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 6)
	r2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r2.add_child(_label("触发条件", 84))
	_cfg_cond_edit = _edit("触发条件（可空）")
	r2.add_child(_field_with_long_edit(_cfg_cond_edit, "trigger"))
	sec.add_child(r2)

	# 权重
	var r3 := HBoxContainer.new()
	r3.add_theme_constant_override("separation", 6)
	r3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r3.add_child(_label("权重", 84))
	_cfg_weight_edit = _edit("数字，默认 1", false, 120.0)
	r3.add_child(_cfg_weight_edit)
	r3.add_child(_label("（数字，默认 1）", 0))
	sec.add_child(r3)

	# 读取 / 保存配置
	var r4 := HBoxContainer.new()
	r4.add_theme_constant_override("separation", 8)
	r4.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cfg_read_btn = UIBtn.new()
	_cfg_read_btn.set_id("cfg_read")
	_cfg_read_btn.set_label("读取配置")
	_cfg_read_btn.custom_minimum_size = Vector2(96.0, UIStyle.BTN_HEIGHT)
	_cfg_read_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_cfg_read_btn.pressed_id.connect(_on_cfg_read_pressed)
	r4.add_child(_cfg_read_btn)
	_cfg_save_btn = UIBtn.new()
	_cfg_save_btn.set_id("cfg_save")
	_cfg_save_btn.set_label("保存配置")
	_cfg_save_btn.custom_minimum_size = Vector2(96.0, UIStyle.BTN_HEIGHT)
	_cfg_save_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_cfg_save_btn.pressed_id.connect(_on_cfg_save_pressed)
	r4.add_child(_cfg_save_btn)
	sec.add_child(r4)

	# 状态提示（独占一行，避免把按钮挤窄）
	_cfg_status = _label("", 0)
	_cfg_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_cfg_status.add_theme_color_override("font_color", Color(0.80, 0.89, 0.99, 0.85))
	sec.add_child(_cfg_status)


# 触发事件下拉：点开时才遍历当前事件链下的事件名（懒加载）。
func _reload_trigger_menu() -> void:
	if _trigger_option == null or not is_instance_valid(_trigger_option):
		return
	var pop := _trigger_option.get_popup()
	if pop.visible:
		pop.hide()
	_trigger_option.clear()
	_trigger_option.add_item(MENU_NONE_LABEL)
	var chain := _chain()
	if chain.is_empty():
		_trigger_option.add_item("（请先选择 / 填写事件链）")
		_trigger_option.set_item_disabled(1, true)
		_trigger_option.select(MENU_NONE_INDEX)
		return
	if not EventFile.chain_exists(chain):
		_trigger_option.add_item("（该事件链不存在）")
		_trigger_option.set_item_disabled(1, true)
		_trigger_option.select(MENU_NONE_INDEX)
		return
	var names: Array[String] = EventFile.list_event_names(chain)
	if names.is_empty():
		_trigger_option.add_item("（该事件链下暂无事件）")
		_trigger_option.set_item_disabled(1, true)
		_trigger_option.select(MENU_NONE_INDEX)
		return
	for n in names:
		_trigger_option.add_item(str(n))
	# 高亮当前触发事件（真源 = _cfg_trigger）
	for i in names.size():
		if str(names[i]) == _cfg_trigger:
			_trigger_option.select(i + 1)
			return
	_trigger_option.select(MENU_NONE_INDEX)


# 下拉选中某个事件 → 记进 _cfg_trigger（不自动保存）。
func _on_trigger_menu_selected(idx: int) -> void:
	if _trigger_option == null or not is_instance_valid(_trigger_option):
		return
	if idx < 0 or idx >= _trigger_option.get_item_count():
		return
	var t := _trigger_option.get_item_text(idx)
	# 「无选择」/ 提示项 → 清空（双条件判据，同「事件名」下拉）。
	if (idx == MENU_NONE_INDEX and t == MENU_NONE_LABEL) or t.is_empty() or t.begins_with("（"):
		_trigger_option.select(MENU_NONE_INDEX)
		_cfg_trigger = ""
		return
	_cfg_trigger = t


# 载入当前事件链的配置（换链时自动调用；「读取配置」按钮同走这里）。
func _load_chain_config() -> void:
	var chain := _chain()
	if chain.is_empty():
		_cfg_trigger = ""
		_cfg_cond_edit.text = ""
		_cfg_weight_edit.text = "1"
		_reload_trigger_menu()
		_set_cfg_status("（未指定事件链）")
		return
	var d := EventFile.read_chain_config(chain)
	_cfg_trigger = str(d.get("trigger_event", ""))
	_cfg_cond_edit.text = str(d.get("trigger_condition", ""))
	_cfg_weight_edit.text = _fmt_cfg_weight(d.get("weight", 1.0))
	# ★ 触发事件下拉是懒加载的，若不预先重建条目，已保存的触发事件显示不出来。
	_reload_trigger_menu()
	_set_cfg_status("已载入：events/%s/config.json" % chain)


func _on_cfg_read_pressed(_id: String) -> void:
	if _chain().is_empty():
		_set_cfg_status("未指定事件链，无法读取")
		return
	_load_chain_config()


func _on_cfg_save_pressed(_id: String) -> void:
	var chain := _chain()
	if chain.is_empty():
		_set_cfg_status("未指定事件链，已取消保存")
		return
	var data := {
		"version": EventFile.CHAIN_CONFIG_VERSION,
		"chain": chain,
		"trigger_event": _cfg_trigger,
		"trigger_condition": _cfg_cond_edit.text,
		"weight": _parse_cfg_weight(),
	}
	var err := EventFile.write_chain_config(chain, data)
	if err == OK:
		_set_cfg_status("已保存：events/%s/config.json" % chain)
	else:
		_set_cfg_status("保存失败(err=%d)" % err)


# 权重：合法数字 → 该值；非法 / 空 → 1。
func _parse_cfg_weight() -> float:
	var t := _cfg_weight_edit.text.strip_edges()
	if t.is_valid_float():
		return float(t)
	return 1.0


# 权重显示：整数值不带小数点（1.0 → "1"），其余原样。
func _fmt_cfg_weight(w) -> String:
	var f := float(w)
	if is_equal_approx(f, roundf(f)):
		return str(int(roundf(f)))
	return str(f)


func _set_cfg_status(text: String) -> void:
	if is_instance_valid(_cfg_status):
		_cfg_status.text = text


# ---------------- 1) 关闭 / 4) 打开的对话框 ----------------

func _build_close_section() -> void:
	# ★ 批次 116：本分区可折叠
	var sec := _add_section("close", "【1】关闭的目标")
	_close_list = VBoxContainer.new()
	_close_list.add_theme_constant_override("separation", ROW_GAP)
	sec.add_child(_close_list)
	sec.add_child(_add_target_button("add_close", "关闭"))

func _build_open_section() -> void:
	# ★ 批次 116：本分区可折叠
	var sec := _add_section("open", "【4】打开的目标")
	_open_list = VBoxContainer.new()
	_open_list.add_theme_constant_override("separation", ROW_GAP)
	sec.add_child(_open_list)
	# ★ 默认就带一条「自动(正文对应)」：打开【2】正文里选的那个对话框。
	#   老行为（有正文就弹面板）由它保住；把它删掉 = 明确声明本次事件不打开任何面板。
	_open_list.add_child(_make_target_row(true, TARGET_ITEMS.size()))
	sec.add_child(_add_target_button("add_open", "打开"))
	# 格式提示（与【3】同款）：auto 的含义与「删掉就不弹」的语义最容易搞错
	var hint := Label.new()
	hint.text = "「自动(正文对应)」= 打开【2】正文里选的那个对话框（弹窗/底部）；\n"
	hint.text += "删掉它 = 本次事件不打开任何面板 —— 正文仍会写进面板缓存，但面板保持原样不弹。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", maxi(UIStyle.FONT_SIZE - 2, 10))
	hint.add_theme_color_override("font_color", Color(0.80, 0.89, 0.99))
	if is_instance_valid(_cjk):
		hint.add_theme_font_override("font", _cjk)
	sec.add_child(hint)


func _add_target_button(btn_id: String, label_text: String) -> UIBtn:
	var b := UIBtn.new()
	b.set_id(btn_id)
	b.set_label("+ 添加" + label_text)
	# 不再横向撑满整行（原为 EXPAND_FILL → 太宽），只占标签所需宽度
	b.custom_minimum_size = Vector2(120.0, UIStyle.BTN_HEIGHT)
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.pressed_id.connect(_on_add_target)
	return b


# 建一行目标。
# with_auto  true → 下拉末尾多一项「自动(正文对应)」（只有打开列表用）。
# default_idx 初始选中项（默认 0 = 弹窗；打开列表的初始行传 auto 的索引）。
# ★ 每行自带一份「显示名 → 值」表（row meta "t_values"）：打开/关闭两个列表的选项个数不同，
#   收集时不能再用全局 TARGET_VALUES 按下标取值（下标 5 是 auto，全局表里没有）。
func _make_target_row(with_auto := false, default_idx := 0) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var items: Array = TARGET_ITEMS.duplicate()
	var values: Array = TARGET_VALUES.duplicate()
	if with_auto:
		items.append(TARGET_AUTO_LABEL)
		values.append(EventFile.TARGET_AUTO)
	row.set_meta("t_values", values)

	var opt := OptionButton.new()
	opt.name = "Type"
	for it in items:
		opt.add_item(it)
	opt.selected = clampi(default_idx, 0, items.size() - 1)
	opt.select(opt.selected)
	if is_instance_valid(_cjk):
		opt.add_theme_font_override("font", _cjk)
	opt.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	opt.item_selected.connect(_on_target_type_selected.bind(row))
	row.add_child(opt)

	var val := LineEdit.new()
	val.name = "Val"
	val.placeholder_text = "积木ID"
	val.custom_minimum_size = Vector2(WIDE_EDIT_W, 0)
	val.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_cjk):
		val.add_theme_font_override("font", _cjk)
	UIStyle.apply_line_edit_style(val)
	val.visible = false
	row.add_child(val)

	var del := UIBtn.new()
	del.set_id("del")
	del.set_label("−")
	del.custom_minimum_size = Vector2(TITLE_H, UIStyle.BTN_HEIGHT)
	del.size = Vector2(TITLE_H, UIStyle.BTN_HEIGHT)
	del.pressed_id.connect(func(_id: String) -> void: _on_del_target(row))
	row.add_child(del)
	return row


func _on_add_target(btn_id: String) -> void:
	# 「打开」列表的下拉里多一项 auto（关闭列表没有）→ 建行时按列表区分
	var row := _make_target_row(btn_id == "add_open")
	if btn_id == "add_close":
		_close_list.add_child(row)
	else:
		_open_list.add_child(row)


func _on_target_type_selected(idx: int, row: HBoxContainer) -> void:
	_apply_target_type(row, idx)


# 按类型显隐/改文案输入框：
#   · 积木ID → 输入积木 ID（数字）；
#   · 关卡   → 输入关卡名（★ 关卡名就是 levels/ 下的文件名，留空 = 只开/关页面不换关卡）；
#   · 弹窗 / 底部 / 通知 → 本身已指明目标，不需要附加输入。
func _apply_target_type(row: HBoxContainer, idx: int) -> void:
	var val: LineEdit = row.get_node("Val")
	val.visible = idx == TARGET_BLOCK or idx == TARGET_LEVEL
	if idx == TARGET_LEVEL:
		val.placeholder_text = "关卡名（= levels/ 下的文件名）"
	else:
		val.placeholder_text = "积木ID"


func _on_del_target(row: HBoxContainer) -> void:
	row.queue_free()


func _collect_targets(box: VBoxContainer) -> Array:
	var out: Array = []
	for row in box.get_children():
		var opt: OptionButton = row.get_node("Type")
		var val: LineEdit = row.get_node("Val")
		# 值表按行取（打开列表比关闭列表多一项 auto，下标不能对全局表硬编码）
		var values: Array = row.get_meta("t_values", TARGET_VALUES)
		if opt.selected == TARGET_BLOCK:
			var v := val.text.strip_edges()
			if v.is_valid_int():
				out.append(int(v))
		elif opt.selected == TARGET_LEVEL:
			# 关卡目标写成 { "level": "<关卡名>" }：与"弹窗/底部/通知"这类纯字符串
			# 目标区分开，且不怕关卡名恰好叫 popup / bottom。
			out.append({ "level": val.text.strip_edges() })
		elif opt.selected >= 0 and opt.selected < values.size():
			out.append(str(values[opt.selected]))
	return out


# 回填一条「关卡」目标（供 _fill_targets 用）
func _add_level_target_row(box: VBoxContainer, level_name: String, with_auto := false) -> void:
	var row := _make_target_row(with_auto)
	var opt: OptionButton = row.get_node("Type")
	opt.selected = TARGET_LEVEL
	opt.select(TARGET_LEVEL)
	var val: LineEdit = row.get_node("Val")
	val.text = level_name
	_apply_target_type(row, TARGET_LEVEL)
	box.add_child(row)


# ---------------- 2) 正文 ----------------

func _build_content_section() -> void:
	# ★ 批次 116：本分区可折叠
	var sec := _add_section("content", "【2】正文")

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sec.add_child(row)

	_lang_label = _label("语言", 44)
	row.add_child(_lang_label)
	_lang_opt = OptionButton.new()
	for i in range(TranslationManager.LANG_CODES.size()):
		_lang_opt.add_item(str(TranslationManager.LANG_NAMES[i]), i)
	_lang_opt.selected = TranslationManager.LANG_CODES.find(TranslationManager.current_lang)
	_lang_opt.select(_lang_opt.selected if _lang_opt.selected >= 0 else 0)
	if is_instance_valid(_cjk):
		_lang_opt.add_theme_font_override("font", _cjk)
	_lang_opt.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	_lang_opt.item_selected.connect(_on_lang_selected)
	row.add_child(_lang_opt)

	row.add_child(_label("面板类型", 64))
	_ptype_opt = OptionButton.new()
	for it in PTYPE_ITEMS:
		_ptype_opt.add_item(it)
	_ptype_opt.selected = PTYPE_NONE_IDX
	_ptype_opt.select(PTYPE_NONE_IDX)
	if is_instance_valid(_cjk):
		_ptype_opt.add_theme_font_override("font", _cjk)
	_ptype_opt.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	_ptype_opt.item_selected.connect(_on_ptype_selected)
	row.add_child(_ptype_opt)

	# 「无修改」提示：仅该类型显示（其余类型隐藏）
	_content_hint = Label.new()
	_content_hint.text = "无修改：该事件不改动正文 / 面板（不写 content、不打开面板、不碰台词 txt）"
	_content_hint.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	_content_hint.add_theme_color_override("font_color", Color(0.80, 0.89, 0.99))
	if is_instance_valid(_cjk):
		_content_hint.add_theme_font_override("font", _cjk)
	sec.add_child(_content_hint)

	# 标题 / 配图（弹窗：标题+配图；底部：角色名+头像）
	_title_row = _make_plain_row("标题(弹窗)", _title_edit, true)
	_title_edit = _title_row.get_node("Val")
	sec.add_child(_title_row)
	# ★ 同一行按面板类型改文案：弹窗 = 配图路径 / 底部 = 头像路径 → 两者都是图片，同一个「选图」按钮
	_image_row = _make_plain_row("配图路径(弹窗)", _image_edit, true)
	_image_edit = _image_row.get_node("Val")
	UIPathPicker.attach(_image_edit, UIPathPicker.DIR_TEXTURES,
		{"exts": UIPathPicker.IMG_EXTS, "label": "图片", "title": "选择配图 / 头像图片"})
	sec.add_child(_image_row)

	# 头像背景层（仅底部）：独立字段 c["bg_image"]；与头像同框重叠，头像透明处透出背景。
	# ★ 不复用 _image_row（那是弹窗配图 / 底部头像共用的单一字段），避免污染弹窗支线。
	_bg_image_row = _make_plain_row("头像背景路径(底部)", _bg_image_edit, true)
	_bg_image_edit = _bg_image_row.get_node("Val")
	UIPathPicker.attach(_bg_image_edit, UIPathPicker.DIR_TEXTURES,
		{"exts": UIPathPicker.IMG_EXTS, "label": "图片", "title": "选择头像背景图片"})
	sec.add_child(_bg_image_row)

	# 冒泡：积木ID
	_block_row = _make_plain_row("积木ID(冒泡)", _block_edit, true)
	_block_edit = _block_row.get_node("Val")
	_block_edit.placeholder_text = "积木ID(冒泡对话框)"
	sec.add_child(_block_row)

	# 通知：等待关闭
	_wait_row = HBoxContainer.new()
	_wait_row.add_theme_constant_override("separation", 6)
	_wait_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_wait_check = CheckBox.new()
	_wait_check.text = "等待(持久) — 不自动消失，手动关闭"
	_wait_check.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	_wait_check.add_theme_color_override("font_color", Color.WHITE)
	_wait_check.custom_minimum_size = Vector2(0.0, UIStyle.BTN_HEIGHT)
	if is_instance_valid(_cjk):
		_wait_check.add_theme_font_override("font", _cjk)
	_wait_row.add_child(_wait_check)
	sec.add_child(_wait_row)

	# 声音（底部台词播放）—— 默认 auto：逐字/逐词泡泡声
	_voice_row = _make_plain_row("声音(底部)", _voice_edit, true)
	_voice_edit = _voice_row.get_node("Val")
	_voice_edit.text = VOICE_DEFAULT
	_voice_edit.placeholder_text = "auto（逐字泡泡声）/ auto:res://audio/x.wav（换成该音频）/ res://audio/x.wav（整段播放）；留空=不发声"
	# 右侧文件夹按钮：选音频 → 回填 res:// 相对路径（默认目录 res://audio/）
	UIPathPicker.attach(_voice_edit, UIPathPicker.DIR_AUDIO,
		{"exts": UIPathPicker.AUDIO_EXTS, "label": "音频", "title": "选择声音文件"})
	sec.add_child(_voice_row)

	# 正文效果（仅底部）：点击台词时执行（与按钮 effect 同源的 DSL 串）
	# ★ 批次 95 去重：「编辑」按钮与按钮条目的「效果」行**走同一条路径、开同一个页** ——
	#   同一个 EffectEditorPanel、同一个标题（EFFECT_PAGE_TITLE）、kind 同为 "effect"；
	#   唯一的区别只是它绑定的 LineEdit 是 _effect_edit 而不是按钮条目里的 EffEdit。
	_effect_row = _make_plain_row("正文效果(底部)", _effect_edit, true)
	_effect_edit = _effect_row.get_node("Val")
	_effect_edit.placeholder_text = "点击台词时执行的效果（DSL）；可按「编辑」可视化配置"
	var eff_edit_btn := UIBtn.new()
	eff_edit_btn.set_id("edit_content_effect")
	eff_edit_btn.set_label("编辑")
	eff_edit_btn.custom_minimum_size = Vector2(LONG_BTN_W, UIStyle.BTN_HEIGHT)
	eff_edit_btn.size = Vector2(LONG_BTN_W, UIStyle.BTN_HEIGHT)
	eff_edit_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	eff_edit_btn.pressed_id.connect(func(_id: String) -> void: _open_placeholder_editor("effect", _effect_edit))
	_effect_row.add_child(eff_edit_btn)
	sec.add_child(_effect_row)

	# 正文文件名 + 内容（「无修改」时两行连同右侧「长文本」按钮一并收起）
	var tf_row := HBoxContainer.new()
	tf_row.add_theme_constant_override("separation", 6)
	tf_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tf_row.add_child(_label("正文文件名", 84))
	_text_file_edit = _edit("不含语言/扩展名，如 greeting")
	tf_row.add_child(_text_file_edit)
	sec.add_child(tf_row)
	_tf_row = tf_row

	var content_row := HBoxContainer.new()
	content_row.add_theme_constant_override("separation", 6)
	content_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_row.add_child(_label("正文内容", 84))
	_content_edit = _edit("当前语言 txt 正文 ((修饰)[文本])；按钮文字写在同文件 @button 小节")
	content_row.add_child(_field_with_long(_content_edit))
	sec.add_child(content_row)
	_content_row = content_row


func _make_plain_row(label_text: String, _out_edit: LineEdit, expand: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var lab := _label(label_text, 84)
	lab.set_meta("label_text", label_text)   # 供切换时改文案
	row.add_child(lab)
	var le := LineEdit.new()
	le.name = "Val"
	le.custom_minimum_size = Vector2(0.0, 0)
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_cjk):
		le.add_theme_font_override("font", _cjk)
	UIStyle.apply_line_edit_style(le)
	row.add_child(le)
	return row


func _on_ptype_selected(idx: int) -> void:
	_apply_ptype(idx)


func _apply_ptype(idx: int) -> void:
	var pt: String = PTYPE_VALUES[idx]
	var none: bool = pt == PTYPE_NONE
	# 「无修改」：整块正文编辑区（正文文件名 / 正文内容 + 右侧「长文本」按钮）收起，
	# 「语言」也无意义（它只是挑哪一份 txt）→ 一并收起，只剩提示文案。
	_content_hint.visible = none
	_lang_label.visible = not none
	_lang_opt.visible = not none
	_tf_row.visible = not none
	_content_row.visible = not none
	# 弹窗/底部共用 title+image 行，仅改文案
	var title_on: bool = pt == "popup" or pt == "bottom"
	var popup: bool = pt == "popup"
	_title_row.visible = title_on
	_image_row.visible = title_on
	if title_on:
		_title_row.get_child(0).text = "标题(弹窗)" if popup else "角色名(底部)"
		_image_row.get_child(0).text = "配图路径(弹窗)" if popup else "头像路径(底部)"
	_block_row.visible = pt == "bubble"
	_wait_row.visible = pt == "notification"
	# 声音只在「底部」显示：只有底部对话面板有语音播放器（弹窗/冒泡/通知不发声）
	_voice_row.visible = pt == "bottom"
	# 正文效果只在「底部」显示：点击底部台词才执行（与按钮 effect 同源）
	_effect_row.visible = pt == "bottom"
	# 头像背景层只在「底部」显示（弹窗/冒泡/通知无头像背景）
	_bg_image_row.visible = pt == "bottom"


# 当前选的是不是「无修改」
func _ptype_none() -> bool:
	var idx: int = _ptype_opt.selected if _ptype_opt != null else PTYPE_NONE_IDX
	return PTYPE_VALUES[idx] == PTYPE_NONE


func _on_lang_selected(_idx: int) -> void:
	# 切换语言：先把**当前显示语言**的内容写回它自己的 txt，再载入新语言 txt。
	# ★ 必须用 _lang_shown（见其声明处的说明），否则会写错文件、覆盖别人的翻译。
	_save_current_lang_txt(_shown_lang())
	_refresh_current_lang_txt()


func _current_lang() -> String:
	var idx: int = _lang_opt.selected if _lang_opt != null else 0
	return str(TranslationManager.LANG_CODES[idx])


# 编辑框内容所属语言（未知时退回下拉当前值）
func _shown_lang() -> String:
	return _lang_shown if not _lang_shown.is_empty() else _current_lang()


# 把关：写回哪个语言。lang 为空 → 用「编辑框当前所属语言」。
func _save_current_lang_txt(lang: String = "") -> void:
	# 「无修改」= 不碰正文：不写 txt。（注意：也不据此删除已有 txt —— 保存永不自动删文件）
	if _ptype_none():
		return
	var chain := _chain_edit.text.strip_edges()
	var logical := _text_file_edit.text.strip_edges()
	if chain.is_empty() or logical.is_empty():
		return
	var lg := lang if not lang.is_empty() else _shown_lang()
	# ★ 按钮文字也一起写进这份 txt（跟在正文后面的 @button 行）——
	#   只有这样才能「跟着语言变」：json 里那份 label 是不分语言的单份。
	EventFile.write_localized(EventFile.chain_dir(chain), logical, lg,
		_content_edit.text, _collect_button_labels())
	_lang_shown = lg


# 读当前语言 txt → 正文写进编辑框、按钮文字回填到**已建好的**按钮行。
func _refresh_current_lang_txt() -> void:
	var chain := _chain_edit.text.strip_edges()
	var logical := _text_file_edit.text.strip_edges()
	if chain.is_empty() or logical.is_empty():
		return
	var lg := _current_lang()
	var loc := EventFile.read_localized(EventFile.chain_dir(chain), logical, lg)
	_content_edit.text = str(loc.get("body", ""))
	_apply_txt_button_labels(loc.get("buttons", {}))
	_lang_shown = lg


# ---------------- 3) 按钮条目 ----------------

func _build_buttons_section() -> void:
	# ★ 批次 116：本分区可折叠。折叠按钮**就是标题**，放在标题行里；
	#   「[+] 新建按钮」跟在标题后（用 _sec_head 拿到刚建出的标题行）。
	var sec := _add_section("buttons", "【3】按钮条目")
	var head := _sec_head
	var add := UIBtn.new()
	add.set_id("add_btn")
	add.set_label("[+]")
	# 不再横向撑满整行（原为 EXPAND_FILL → 太宽），只占一个小按钮宽度
	add.custom_minimum_size = Vector2(56.0, UIStyle.BTN_HEIGHT)
	add.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	add.pressed_id.connect(func(_id: String) -> void: _on_add_button())
	head.add_child(add)

	_buttons_box = VBoxContainer.new()
	_buttons_box.add_theme_constant_override("separation", ROW_GAP)
	# ★ 格式提示（本次新增）：按钮文字存哪儿、能不能随语言变，是使用者最容易搞错的一点。
	var hint := Label.new()
	hint.text = "「文字内容」= 按钮上显示什么，写进【正文文件名_语言.txt】的 @button 小节（不是 json）→\n"
	hint.text += "这样切语言时按钮文字才会跟着变。留空 = 该按钮回退用 json 里的 label（不分语言）。\n"
	hint.text += "写法与正文相同：(修饰)[内容]，如 (#ffffffL)[“下一句”]（#RRGGBB 颜色 / @字号 / %透明度 / R·C·L 对齐 / \\n 换行）。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", maxi(UIStyle.FONT_SIZE - 2, 10))
	hint.add_theme_color_override("font_color", Color(1.0, 0.85, 0.55))
	if is_instance_valid(_cjk):
		hint.add_theme_font_override("font", _cjk)
	sec.add_child(hint)
	sec.add_child(_buttons_box)


func _next_button_id() -> String:
	var m: int = 0
	for entry in _buttons_box.get_children():
		var id_edit := entry.find_child("IdEdit", true, false) as LineEdit
		if id_edit == null:
			continue
		var t := id_edit.text.strip_edges()
		if t.begins_with("b"):
			var n := t.substr(1)
			if n.is_valid_int():
				m = maxi(m, int(n))
	return "b%d" % (m + 1)


func _on_add_button() -> void:
	_buttons_box.add_child(_make_button_row(_next_button_id(), "", "", ""))


# 一个按钮条目 = 一个多行 VBox（每行不等宽）：
#   行1：[id] [文字内容 + 长文本]                                   [−]
#   行2：效果     [输入框 + 长文本 + 编辑]
#   行3：显示要求 [输入框 + 长文本 + 编辑]
# 「编辑」打开该字段的独立占位编辑页（见 _open_placeholder_editor）。
func _make_button_row(p_id: String, p_label: String, p_effect: String, p_show: String) -> VBoxContainer:
	var entry := VBoxContainer.new()
	entry.name = "Entry"
	entry.add_theme_constant_override("separation", 3)
	entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# 行 1：id + 文字内容 + 长文本 + 删除
	var r1 := HBoxContainer.new()
	r1.add_theme_constant_override("separation", 4)
	r1.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var id_edit := LineEdit.new()
	id_edit.name = "IdEdit"
	id_edit.text = p_id
	id_edit.custom_minimum_size = Vector2(SMALL_EDIT_W, 0)
	id_edit.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_cjk):
		id_edit.add_theme_font_override("font", _cjk)
	UIStyle.apply_line_edit_style(id_edit)
	r1.add_child(id_edit)

	var label_edit := _edit("按钮文字：(修饰)[内容]，如 (#ffffffL)[“下一句”]")
	label_edit.name = "LabelEdit"
	label_edit.text = p_label
	r1.add_child(_field_with_long(label_edit))

	var del := UIBtn.new()
	del.set_id("del")
	del.set_label("−")
	del.custom_minimum_size = Vector2(TITLE_H, UIStyle.BTN_HEIGHT)
	del.size = Vector2(TITLE_H, UIStyle.BTN_HEIGHT)
	del.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	del.pressed_id.connect(func(_id: String) -> void: _on_del_button(entry))
	r1.add_child(del)
	entry.add_child(r1)

	# 行 2 / 行 3：效果、显示要求（各带「长文本」+「编辑」）
	entry.add_child(_make_button_field_row("效果", "EffEdit", p_effect, "效果", "effect"))
	entry.add_child(_make_button_field_row("显示要求", "ShowEdit", p_show, "显示要求(可空)", "show"))
	return entry


# 按钮条目里的一行「标签 + 输入框 + 长文本 + 编辑」
func _make_button_field_row(label_text: String, edit_name: String, value: String,
		placeholder: String, kind: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_label(label_text, 64))
	var le := _edit(placeholder)
	le.name = edit_name
	le.text = value
	row.add_child(_field_with_long_edit(le, kind))
	return row


func _on_del_button(entry: Control) -> void:
	entry.queue_free()


func _collect_buttons() -> Array:
	var out: Array = []
	for entry in _buttons_box.get_children():
		var id_edit := entry.find_child("IdEdit", true, false) as LineEdit
		var label_le := entry.find_child("LabelEdit", true, false) as LineEdit
		var eff_le := entry.find_child("EffEdit", true, false) as LineEdit
		var show_le := entry.find_child("ShowEdit", true, false) as LineEdit
		if id_edit == null or label_le == null or eff_le == null or show_le == null:
			continue
		out.append({
			"id": id_edit.text.strip_edges(),
			"label": label_le.text,
			"effect": eff_le.text,
			"show": show_le.text.strip_edges(),
		})
	return out


# 当前按钮行里的 id → 文字内容定义（写进 txt 的 @button 小节）。
# 空 id / 空文字都跳过（txt 里那一行没有意义）。
# ★ 只取**单行**：@button 一行的格式就是「@button id = 定义」，定义里不许有真实换行
#   （要换行请用修饰里的 \n 转义）。
func _collect_button_labels() -> Dictionary:
	var out: Dictionary = {}
	for entry in _buttons_box.get_children():
		var id_edit := entry.find_child("IdEdit", true, false) as LineEdit
		var label_le := entry.find_child("LabelEdit", true, false) as LineEdit
		if id_edit == null or label_le == null:
			continue
		var bid := id_edit.text.strip_edges()
		var ldef := label_le.text.strip_edges().replace("\r", "").replace("\n", "\\n")
		if bid.is_empty() or ldef.is_empty():
			continue
		out[bid] = ldef
	return out


# 把 txt 里 @button 小节的文字**回填**到已建好的按钮行。
# ★ txt 里没写这个 id 的行**保持原样** —— 那是 json 里的 label，作回退值。
# ★ 因此调用顺序必须是「先建行 → 再回填」，反过来会找不到行（_load_from_dict 已按此排）。
func _apply_txt_button_labels(btns: Dictionary) -> void:
	if btns.is_empty():
		return
	for entry in _buttons_box.get_children():
		var id_edit := entry.find_child("IdEdit", true, false) as LineEdit
		var label_le := entry.find_child("LabelEdit", true, false) as LineEdit
		if id_edit == null or label_le == null:
			continue
		var bid := id_edit.text.strip_edges()
		if btns.has(bid):
			label_le.text = str(btns[bid])


# ---------------- 长文本 ----------------

func _ensure_popup_layer() -> CanvasLayer:
	if _popup_layer == null or not is_instance_valid(_popup_layer):
		_popup_layer = CanvasLayer.new()
		_popup_layer.layer = 132
		add_child(_popup_layer)
		# 长文本窗也是「面板」：跟随设置里的 UI 缩放
		UIStyle.watch_ui_scale(_popup_layer)
	return _popup_layer


func _open_long(_id: String, le: LineEdit) -> void:
	if _active_long != null and is_instance_valid(_active_long):
		_active_long.close()
	_active_long = UILongTextInputPanel.new()
	_ensure_popup_layer().add_child(_active_long)
	_active_long.closed.connect(func() -> void:
		_active_long = null)
	_active_long.open(le, le.text)


# 打开某字段的独立编辑页（kind: "effect" / "show" / "trigger"）。
# "effect" → 可视化「效果编辑」页（加号 + 下拉）；"show"/"trigger" → 可视化「编辑条件」页。
# ★ 批次 95 去重：按钮条目的「效果」行与正文的「正文效果(底部)」行**共用这一条路径**
#   （面板类、标题、kind 全相同，只有绑定的 LineEdit 不同）。旧实现另有一条 _open_effect_editor()
#   分支，除了把标题写成「正文效果编辑」之外与这里逐行等价 —— 已删除，避免同页两名。
# 每个字段各自一页：**同一字段**重复点击只保留一页（先关旧的）；
# ★ 批次 94：**不同字段可以同时多开**（各指向各自的 LineEdit），层叠错开显示。
func _open_placeholder_editor(kind: String, le: LineEdit) -> void:
	_close_panel_for_le(le)
	if kind == "effect":
		var panel := EffectEditorPanel.new()
		_ensure_popup_layer().add_child(panel)
		panel.closed.connect(func() -> void: _forget_panel(panel))
		panel.open(EFFECT_PAGE_TITLE, le)
		_panel_origin(panel)
		_remember_panel(kind, le, panel)
		return
	var panel := ConditionEditorPanel.new()
	_ensure_popup_layer().add_child(panel)
	panel.closed.connect(func() -> void: _forget_panel(panel))
	panel.open("编辑条件", le, "trigger" if kind == "trigger" else "show")
	_panel_origin(panel)
	_remember_panel(kind, le, panel)


# ---------------- 多开管理（批次 94）----------------
# ★ 旧实现是「每个 kind 只留一页」的字典记忆 → 同一时刻只能开一个效果页 / 一个条件页。
#   时间轴本质是「定时执行命令」，效果页与条件页经常要对着不同目标同时改，
#   于是改成**列表**：不同字段各一页并可同屏多开；同一字段重复点击只保留一页。

## 关掉「正绑着同一个 LineEdit」的旧面板（同字段重开 = 复位，不会叠出重复页）。
func _close_panel_for_le(le: LineEdit) -> void:
	for rec in _placeholder_panels.duplicate():
		if not (rec is Dictionary):
			continue
		var d: Dictionary = rec
		if d.get("le", null) == le and is_instance_valid(d.get("panel", null)):
			(d["panel"] as Node).call("close")


## 记住一个新开的面板（连同它绑定的字段）。
func _remember_panel(kind: String, le: LineEdit, panel: Node) -> void:
	_placeholder_panels.append({"kind": kind, "le": le, "panel": panel})


## 面板自关（× / 完成）后把它从列表里摘掉。
func _forget_panel(panel: Node) -> void:
	for i in range(_placeholder_panels.size() - 1, -1, -1):
		var rec: Variant = _placeholder_panels[i]
		if rec is Dictionary and (rec as Dictionary).get("panel", null) == panel:
			_placeholder_panels.remove_at(i)


## 层叠错开：新面板相对面板默认位置偏移 (24,24) × 当前已开页数，避免完全重叠。
func _panel_origin(panel: Node) -> void:
	if not is_instance_valid(panel):
		return
	var n := 0
	for rec in _placeholder_panels:
		if rec is Dictionary and is_instance_valid((rec as Dictionary).get("panel", null)):
			n += 1
	var off := Vector2(24.0, 24.0) * float(n % 6)
	if panel.has_method("set_origin_offset"):
		panel.call("set_origin_offset", off)


# ---------------- 读取 / 保存 ----------------

func _chain() -> String:
	return _chain_edit.text.strip_edges()

func _name() -> String:
	return _name_edit.text.strip_edges()


func _on_read_pressed(_id: String) -> void:
	var chain := _chain()
	var name := _name()
	if chain.is_empty() or name.is_empty():
		print("[事件链编辑] 输入错误：请填写事件链名与事件名")
		return
	var data: Variant = EventFile.read_script(chain, name)
	if data == null or not (data is Dictionary):
		print("[事件链编辑] 输入错误：事件链 < %s > 下不存在事件 < %s >（须精确匹配）" % [chain, name])
		return
	_load_from_dict(data)
	_load_chain_config()   # 读到事件 → 该链的配置一并载入内联区
	print("[事件链编辑] 已读取：%s / %s" % [chain, name])


func _on_save_pressed(_id: String) -> void:
	var chain := _chain()
	var name := _name()
	if chain.is_empty() or name.is_empty():
		print("[事件链编辑] 输入错误：请填写事件链名与事件名")
		return
	# 权限：当前仅"本体"生效
	if _save_opt.selected != 0:
		print("[事件链编辑] 提示：当前仅「本体」生效，已按本体路径保存（DLC/MOD 仅占位）")
	var d := _collect_dict()
	var verr := EventFile.validate(d)
	if verr != "":
		print("[事件链编辑] 保存中止：%s" % verr)
		return
	# 按钮 id 唯一性
	var ids: Array = []
	for b in d["buttons"]:
		if ids.has(b["id"]) and b["id"] != "":
			print("[事件链编辑] 保存中止：按钮 id 重复 = %s（需唯一）" % b["id"])
			return
		ids.append(b["id"])
	var err := EventFile.write_script(chain, name, d)
	_save_current_lang_txt()
	if err != OK:
		print("[事件链编辑] 保存失败(err=%d)：%s / %s" % [err, chain, name])
	else:
		print("[事件链编辑] 已保存：%s / %s" % [chain, name])


# 试运行当前事件：**直接用编辑器里的内容跑，不要求先保存**（改了什么就跑什么，方便边改边测）。
#   · 脚本结构（close/open/content/buttons）取自当前表单 _collect_dict()；
#   · 正文取自当前语言的 _content_edit（同样不必先写回 txt）；
#   · 校验不通过也照跑，只告警——测试时不该被校验挡住，但要把问题打出来。
# 注意：这会覆盖同名事件当前的运行上下文；要跑**已保存**的版本请先点「读取」再运行。
func _on_run_pressed(_id: String) -> void:
	var chain := _chain()
	var name := _name()
	if chain.is_empty() or name.is_empty():
		print("[事件链编辑] 输入错误：请填写事件链名与事件名")
		return
	if EventChainRunner == null:
		print("[事件链编辑] 执行器未就绪")
		return
	var d := _collect_dict()
	var verr := EventFile.validate(d)
	if verr != "":
		print("[事件链编辑] 校验未通过（仍按编辑器内容运行，仅供测试）：%s" % verr)
	# 「无修改」没有正文可覆盖 —— 传 null 让执行器走它自己的「不改动面板」分支
	var text_override = null
	if not _ptype_none():
		text_override = _content_edit.text
	# ★ 按钮文字同样用编辑器里**未保存**的这一份：否则试运行会拿 txt / json 里的旧文字，
	#   改了按钮却看不出效果（正文与按钮必须成对覆盖）。
	var buttons_override: Array = d.get("buttons", [])
	var ok: bool = EventChainRunner.run_dict(chain, name, d, text_override, buttons_override)
	print("[事件链编辑] 试运行%s：%s / %s（未保存，仅编辑器内容）" % [
		"成功" if ok else "失败", chain, name])


func _collect_dict() -> Dictionary:
	var pt: String = PTYPE_VALUES[_ptype_opt.selected]
	# ★「无修改」：content 只写 panel_type=""，不带 text_file/title/... ——
	#   运行器据此不打开、不覆盖任何面板（正文对本次事件无意义）。
	var c: Dictionary
	if pt == PTYPE_NONE:
		c = { "panel_type": PTYPE_NONE }
	else:
		c = {
			"panel_type": pt,
			"text_file": _text_file_edit.text.strip_edges(),
		}
		if pt == "popup" or pt == "bottom":
			c["title"] = _title_edit.text
			c["image"] = _image_edit.text
			# 声音：只有底部面板会播（弹窗/冒泡/通知无语音播放器），故只给底部写这一项
			if pt == "bottom" and _voice_edit != null:
				c["voice"] = _voice_edit.text.strip_edges()
			# 正文效果：点击底部台词时执行（与按钮 effect 同源）；仅底部写
			if pt == "bottom" and _effect_edit != null:
				c["effect"] = _effect_edit.text.strip_edges()
			# 头像背景层：仅底部写；空 = 不绘制背景
			if pt == "bottom" and _bg_image_edit != null:
				c["bg_image"] = _bg_image_edit.text.strip_edges()
		elif pt == "bubble":
			var bv := _block_edit.text.strip_edges()
			c["block_id"] = int(bv) if bv.is_valid_int() else 0
		elif pt == "notification":
			c["notification_buttons"] = _wait_check.button_pressed
	return {
		"version": 1,
		"chain": _chain(),
		"name": _name(),
		"close": _collect_targets(_close_list),
		"open": _collect_targets(_open_list),
		"content": c,
		"buttons": _collect_buttons(),
	}


func _load_from_dict(data: Dictionary) -> void:
	_chain_edit.text = str(data.get("chain", _chain()))
	_name_edit.text = str(data.get("name", _name()))

	# 目标列表
	_fill_targets(_close_list, data.get("close", []))
	# ★ 打开列表：老脚本没有 open 键 → EventFile.open_targets 给 ["auto"]
	#   （= 打开正文对应的对话框，与改动前的运行行为一致）；显式写 "open": [] → 空列表，
	#   编辑器里就是「一条都没有」= 本次事件不打开任何面板。
	_fill_targets(_open_list, EventFile.open_targets(data), true)

	# 正文
	var c: Dictionary = data.get("content", {})
	# 缺省 = 「无修改」（老事件若本来就没写 panel_type，不该被当成弹窗）
	var pt: String = str(c.get("panel_type", PTYPE_NONE))
	var pidx: int = PTYPE_VALUES.find(pt)
	_ptype_opt.selected = pidx if pidx >= 0 else PTYPE_NONE_IDX
	_ptype_opt.select(_ptype_opt.selected)
	_text_file_edit.text = str(c.get("text_file", ""))
	_title_edit.text = str(c.get("title", ""))
	_image_edit.text = str(c.get("image", ""))
	# 头像背景层：老事件没有这一项 → 空（不绘制背景）
	if _bg_image_edit != null:
		_bg_image_edit.text = str(c.get("bg_image", ""))
	_block_edit.text = str(c.get("block_id", ""))
	_wait_check.button_pressed = bool(c.get("notification_buttons", false))
	# 声音：老事件没有这一项 → 显示默认 auto（保存时会写进 content.voice）
	if _voice_edit != null:
		_voice_edit.text = str(c.get("voice", VOICE_DEFAULT))
	# 正文效果：老事件没有这一项 → 空（底部台词点击不执行效果）
	if _effect_edit != null:
		_effect_edit.text = str(c.get("effect", ""))
	_apply_ptype(_ptype_opt.selected)

	# 按钮
	_clear_rows(_buttons_box)
	for b in data.get("buttons", []):
		if b is Dictionary:
			_buttons_box.add_child(_make_button_row(
				str(b.get("id", "")),
				str(b.get("label", "")),
				str(b.get("effect", "")),
				str(b.get("show", "")),
			))
	# ★★ 正文 + 按钮文字都从**当前语言** txt 载入 —— 必须放在「建按钮行」**之后**：
	#   _refresh_current_lang_txt 会把 txt 里的 @button 文字回填进这些行，顺序反了就找不到行
	#   → 读回来仍是 json 里的老语言 label（这就是「按钮文字不随语言变」的一半原因）。
	_refresh_current_lang_txt()


# 同步清空一个容器：remove_child 立刻摘除（queue_free 只标记，本帧内还挂在树上，
# 紧随其后的重建/收集会把旧行算进去），再交给 queue_free 稍后释放。
func _clear_rows(box: VBoxContainer) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()


func _fill_targets(box: VBoxContainer, arr: Array, with_auto := false) -> void:
	_clear_rows(box)
	for item in arr:
		# 关卡目标：{ "level": "<关卡名>" }（带输入框的参数型目标）
		if item is Dictionary and (item as Dictionary).has("level"):
			_add_level_target_row(box, str((item as Dictionary).get("level", "")), with_auto)
			continue
		var row := _make_target_row(with_auto)
		if item is int:
			var opt: OptionButton = row.get_node("Type")
			opt.selected = TARGET_BLOCK
			opt.select(TARGET_BLOCK)
			var val: LineEdit = row.get_node("Val")
			val.text = str(item)
			val.visible = true
		elif item is String:
			# 值表按行取 → 打开列表里的 "auto"（值 EventFile.TARGET_AUTO）也能正确回选
			var values: Array = row.get_meta("t_values", TARGET_VALUES)
			var idx: int = values.find(str(item))
			var opt2: OptionButton = row.get_node("Type")
			opt2.selected = maxi(idx, 0)
			opt2.select(opt2.selected)
		box.add_child(row)


func _on_close_pressed(_id: String) -> void:
	close()


# 公开关闭：先关长文本 / 占位编辑子窗再释放面板（未保存改动直接丢弃）
func close() -> void:
	if _active_long != null and is_instance_valid(_active_long):
		_active_long.close()
	var panels: Array = _placeholder_panels.duplicate()
	_placeholder_panels = []
	for rec in panels:
		if not (rec is Dictionary):
			continue
		var p = (rec as Dictionary).get("panel", null)
		if p != null and is_instance_valid(p):
			p.close()
	queue_free()

## 最小化 / 还原：折叠只隐藏内容，标题栏控件（标题 / 把柄 / 最小化 / 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.set_label(_min_btn, v)
	UIMinimize.fold_top_strip(self, v)
	UIMinimize.apply_size(self, v)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
