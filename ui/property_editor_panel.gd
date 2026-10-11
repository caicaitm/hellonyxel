# property_editor_panel.gd
# 积木属性编辑面板（从 abandon 版 0.1.5 重做，适配新版 Block 模型）
# 右键菜单 → “编辑积木属性” / “新建积木类型” / “另存为新类型” → 弹本面板
#
# 数据模型（prop dict，字段与 BlockProperty 互转）：
#   width, height, display_layer, collision_layer(PackedStringArray/逗号分隔集合), border_color(hex), border_width,
#   fill_color(hex), tags(PackedStringArray 文本), fill_path, fill_mode(int), fill_anim(int),
#   rotation_deg, text_boxes(Array[dict]), parent_id(int), child_ids(Array[int])
#
# 父子级锚定（ID 绑定，参考已废弃版本的父子级系统）：
#   「父级ID(0=无)」「子级ID(逗号分隔)」两行直接读写积木 ID；
#   父级移动时，带 child_follow 标签的子级一并位移；子级移动不影响父级。
#
# 长文本：
#   「标签」行 与 文本框的「文本(修饰)[内容]」行 末尾各有一个「长文本」按钮，
#   按下后用复用的 UILongTextInputPanel 打开大窗口书写，内容实时回填到本行 LineEdit。
#
# signal applied(action, payload)
#   action: "apply_to_block" | "spawn_new" | "save_as_type"
#   payload: { "block": Block, "prop": dict } | { "type_name": String, "prop": dict } | { "name": String, "prop": dict }
extends Control
class_name PropertyEditorPanel

signal applied(action: String, payload: Dictionary)

const PANEL_PADDING: float = 6.0
const LABEL_W: float = 110.0
const FIELD_W: float = 170.0
const ROW_H: float = 20.0
const BTN_H: float = 22.0
const BTN_GAP: float = 6.0
const FORM_FONT: int = 13
const TITLE_FONT: int = 14
const TITLE_BAR_H: float = 28.0   # 标题栏高度（拖动把柄 / × 关闭按钮同高）
const LONG_BTN_W: float = 52.0    # 行内「长文本」按钮宽度
const TAG_ADJUST_BTN_W: float = 68.0   # 行内「调整标签」按钮宽度
const COLOR_BTN_W: float = 52.0   # 行内「色盘」按钮宽度
const HELP_BTN_W: float = 26.0    # 行内「?」说明按钮宽度

var _built: bool = false

var _initial_dict: Dictionary = {}
var _target_action: String = ""
var _context: Dictionary = {}

# 标题栏控件（自 abandon 版迁移复用：拖动把柄 + × 关闭）
var _drag_handle: UIDragHandle
var _close_btn: UIBtn
var _user_pos: Vector2 = Vector2.ZERO   # 用户拖动后的位置（下次打开时保留）
var _has_user_pos: bool = false

# 控件
var _root_vbox: VBoxContainer
var _scroll: ScrollContainer
var _form: VBoxContainer
var _name_input: LineEdit
var _width_input: LineEdit
var _height_input: LineEdit
var _display_layer_input: LineEdit
var _collision_layer_input: LineEdit
var _border_width_input: LineEdit
var _border_color_input: LineEdit
var _fill_color_input: LineEdit
var _tags_input: LineEdit
var _fill_path_input: LineEdit
var _fill_mode_select: OptionButton
var _fill_anim_select: OptionButton
var _save_loc_select: OptionButton   # 「保存位置」下拉：MOD(默认) / DLC(仅占位) / 本体(仅生效)
var _rotation_input: LineEdit
var _facing_input: LineEdit
var _base_attack_input: LineEdit
var _parent_id_input: LineEdit
var _child_ids_input: LineEdit
var _id_input: LineEdit
var _id_editable: bool = false
var _string_id_input: LineEdit
var _string_id_editable: bool = false
var _tb_list: VBoxContainer
var _tb_editors: Array = []   # Array[Dictionary(控件引用)]
var _preset_select: OptionButton = null   # 「预留文本框」下拉：选中类型后由「添加文本框」按钮创建
var _selected_preset: String = ""         # 下拉当前选中的预设 key（"" = 空 / 全空文本框）
var _ab_list: VBoxContainer
var _ab_editors: Array = []               # Array[Dictionary(控件引用)] 攻击判定框
var _ab_preset_select: OptionButton = null
var _selected_ab_preset: String = ""
# 数值条列表（动态，仿文本框 / 攻击判定框）
var _vb_list: VBoxContainer
var _vb_editors: Array = []               # Array[Dictionary(控件引用)] 数值条
var _vb_preset_select: OptionButton = null
var _selected_vb_preset: String = ""
# 局部变量列表（批次 19 新增，结构与数值条列表同构）
var _lv_list: VBoxContainer
var _lv_editors: Array = []               # Array[Dictionary(控件引用)] 局部变量
var _lv_preset_select: OptionButton = null
var _selected_lv_preset: String = ""
var _error_label: Label

# 「?」说明按钮 + 说明框（需求 K）：
#   文本框 / 数值条 / 攻击判定框 三个区各有一块很长的说明文字，原先由 _add_hint_row 直接铺在
#   主表单 _form 里（始终占位、把面板撑得很高）。现改为默认隐藏的「说明框」，
#   在各自板块标题行放一个「?」按钮切换：点「?」打开、再点（或点框体）关闭。
#   ★ 说明框宽度随内容变化 → visible 切换即改 min size，ScrollContainer 会自动出/收竖向滚动条，
#     面板窗口尺寸在 _build_ui 时已定且不改（内容超高只滚动），故不需要手动重排尺寸。
var _help_boxes: Array = []                       # 全部说明框（供统一收起）
var _open_help_box: PanelContainer = null          # 当前打开的说明框（同屏最多一个）

# 长文本输入窗（复用 UILongTextInputPanel）。挂在 CanvasLayer 上，保证浮在属性面板之上、
# 且自身 position 以视口为原点；属性面板关闭时一并关闭。
var _long_text_panel: UILongTextInputPanel = null

# 标签选择窗（复用 TagPickerPanel）：勾选标签方便地增删，确认后回填到「标签」输入框
var _tag_picker: TagPickerPanel = null

# 取色盘窗（复用 UIColorPickerPanel）：拖色盘选 RGB 码，确认后回填到来源颜色输入框
var _color_panel: UIColorPickerPanel = null

# 积木运动窗（复用 BlockMotionPanel）：调整 可飞行 / 水平最大速度·加速度 / 飞行上升最大速度·加速度；
# 关闭后把结果回填到 _motion_data，最终随「确定」一起写进 prop dict（见 _collect_prop_dict）。
var _motion_panel: BlockMotionPanel = null
var _motion_btn: Button = null
var _motion_summary: Label = null
var _motion_data: Dictionary = {}

# 「类型名 / 保存位置」整行与「另存为新类型」按钮：仅“新建积木类型 / 另存为新类型”模式显示；
# 编辑已有积木(apply_to_block)时隐藏——类型名是“模板”概念，仅在“生成 / 另存”时参与，不占用单块属性页。
var _type_name_row: Control = null
var _save_loc_row: Control = null
var _save_loc_hint_row: Control = null
var _save_as_type_btn: Button = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	if not TranslationManager.language_changed.is_connected(_on_lang_changed):
		TranslationManager.language_changed.connect(_on_lang_changed)
	# 默认隐藏：只有 open() 被调用（右键菜单触发）时才显示。
	# 否则一进入游戏就会挂着一个不指向任何积木的属性面板。
	visible = false


# 全局语言改变 → 整棵树重译（含动态添加的文本框/判定框编辑器）
func _on_lang_changed(_lang: String) -> void:
	TranslationManager.retranslate_tree(self)



# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false
## 本页的**可见盒子**是下面这个 PanelContainer（玻璃底），它不是 UIPanel、也不叫 `_bg` →
##   UIMinimize 收窄的是 `self`（一个尺寸恒等于盒子的空壳 Control），盒子不会自己跟随
##   → 最小化按钮位置差一截（探针实测 BTN_DRIFT_X -20.0）。由 set_minimized 同步它。
var _box: PanelContainer = null

func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2.ZERO
	_box = panel

	# 液态玻璃面板底：半透明纯白 + 冰蓝描边 + 外发光
	var sb := UIStyle.glass_box(UIStyle.FILL_DEFAULT, UIStyle.BORDER, int(UIStyle.CORNER_RADIUS), int(UIStyle.BORDER_WIDTH), true)
	sb.content_margin_left = PANEL_PADDING
	sb.content_margin_right = PANEL_PADDING
	sb.content_margin_top = PANEL_PADDING
	sb.content_margin_bottom = PANEL_PADDING
	panel.add_theme_stylebox_override("panel", sb)

	# 外层竖排：标题栏（固定不滚动）+ 滚动内容区
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 0)
	panel.add_child(outer)

	# 标题栏：标题 + 拖动把柄 + × 关闭（自 abandon 版 v0.1.8+ 迁移复用）
	var title_bar := HBoxContainer.new()
	title_bar.add_theme_constant_override("separation", 4)
	outer.add_child(title_bar)
	var title := Label.new()
	title.text = "积木属性"
	title.custom_minimum_size = Vector2(0, TITLE_BAR_H)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_font_size_override("font_size", TITLE_FONT)
	var fnt = UIStyle.get_cjk_font()
	if fnt != null:
		title.add_theme_font_override("font", fnt)
	title_bar.add_child(title)
	_drag_handle = UIDragHandle.new()
	_drag_handle.setup(self)
	_drag_handle.drag_ended.connect(_on_drag_ended)
	title_bar.add_child(_drag_handle)
	_close_btn = UIBtn.new()
	_close_btn.set_id("close")
	_close_btn.set_label("×")
	_close_btn.custom_minimum_size = Vector2(TITLE_BAR_H, TITLE_BAR_H)
	_close_btn.pressed_id.connect(_on_close_btn_pressed)
	_min_btn = UIMinimize.attach(title_bar, func(): set_minimized(not _minimized))
	title_bar.add_child(_close_btn)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 0)
	margin.add_theme_constant_override("margin_right", 0)
	margin.add_theme_constant_override("margin_top", 0)
	margin.add_theme_constant_override("margin_bottom", 0)
	outer.add_child(margin)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	margin.add_child(_scroll)

	_root_vbox = VBoxContainer.new()
	_root_vbox.add_theme_constant_override("separation", 6)
	_root_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_root_vbox)

	_form = VBoxContainer.new()
	_form.add_theme_constant_override("separation", 3)
	_form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root_vbox.add_child(_form)

	_name_input = _add_text_row("类型名(留空=不入库)", "")
	_type_name_row = _name_input.get_parent()
	# 保存位置：MOD(默认) / DLC(仅占位) / 本体(仅本体生效)
	_save_loc_select = OptionButton.new()
	_save_loc_select.custom_minimum_size = Vector2(FIELD_W, ROW_H)
	_save_loc_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_loc_select.mouse_filter = Control.MOUSE_FILTER_STOP
	_save_loc_select.add_theme_font_size_override("font_size", FORM_FONT)
	_save_loc_select.add_item("MOD")
	_save_loc_select.add_item("DLC")
	_save_loc_select.add_item("本体")
	_save_loc_select.select(0)   # 默认选中 MOD
	var sl_row := HBoxContainer.new()
	sl_row.add_theme_constant_override("separation", 6)
	sl_row.add_child(_label("保存位置"))
	sl_row.add_child(_save_loc_select)
	_form.add_child(sl_row)
	_save_loc_row = sl_row
	_save_loc_hint_row = _add_hint_row("保存位置：仅「本体」位置的积木类型会在游戏中生效；\nMOD 为默认、DLC 为占位预留，二者本阶段暂不生效。")
	_width_input = _add_text_row("宽(width,像素)", "120")
	_height_input = _add_text_row("高(height,像素)", "120")
	_display_layer_input = _add_text_row("显示图层", "0")
	_collision_layer_input = _add_text_row("碰撞图层(逗号分隔)", "default")
	# 图层提示（复用需求 K 的「?」）：两个积木只有图层集合有公共元素时才会互相阻挡
	# 注意：说明框内**不用自动换行**（autowrap 在容器里量不准高度，会和下一行重叠），
	#       改为手工断行且每行都短于可用宽度，高度即等于行数 × 行高，必定不重叠。
	_help_for_row(_collision_layer_input.get_parent(),
		"内置图层：\n" +
		" default = 默认\n" +
		" dragging = 被拖动中\n" +
		"另有编号图层 1~30，直接写数字。\n" +
		"被拖动的积木会临时切到 dragging 层，\n" +
		"普通积木挡不住它（图层无交集），\n" +
		"图层带 dragging 的积木能挡住它。")
	_border_width_input = _add_text_row("边框宽度", "3")
	# ★ 颜色行带「色盘」按钮：打开取色盘选 RGB 码（双向联动写回本行输入框）
	_border_color_input = _add_color_row("边框色(#RRGGBBAA)", "#FFFFFFFF")
	_fill_color_input = _add_color_row("填充色(#RRGGBBAA)", "#4090F0FF")
	_tags_input = _add_tag_row()   # 标签行：输入框 + 「长文本」按钮 + 「调整标签」按钮
	# 检测标签提示（复用需求 K 的「?」）：成对出现、键可自由替换；被检测方会自动增删 detected_XXX
	_help_for_row(_tags_input.get_parent(),
		"动态检测标签（XXX 可替换，两边成对）：\n" +
		" to_detect_XXX = 检测区(待检测_XXX)\n" +
		" detected_XXX = 检测到_XXX\n" +
		"中心点进入检测区的积木自动获得\n" +
		"detected_XXX，离开即移除。\n" +
		"受控积木另有 detected_vertical_move\n" +
		"（检测到_竖直移动）才能用 W/S/↑/↓。")
	_rotation_input = _add_text_row("旋转角度(度)", "0")
	_facing_input = _add_text_row("朝向(1右/-1左)", "1")
	_facing_input.editable = true
	_base_attack_input = _add_text_row("基础攻击力", "1")
	_base_attack_input.editable = true

	# 积木运动：按钮打开「积木运动」面板，细化受控移动参数（可飞行 / 最大速度 / 加速度）
	var motion_row := HBoxContainer.new()
	motion_row.add_theme_constant_override("separation", 6)
	_form.add_child(motion_row)
	motion_row.add_child(_label("积木运动"))
	_motion_btn = _styled_button("调整运动...", "motion")
	_motion_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_motion_btn.custom_minimum_size = Vector2(96.0, ROW_H)
	_motion_btn.pressed.connect(_on_motion_pressed)
	motion_row.add_child(_motion_btn)
	_motion_summary = Label.new()
	_motion_summary.clip_text = true
	_motion_summary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_motion_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_motion_summary.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_motion_summary.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	_motion_summary.add_theme_font_size_override("font_size", maxi(FORM_FONT - 2, 9))
	var _motion_fnt = UIStyle.get_cjk_font()
	if _motion_fnt != null:
		_motion_summary.add_theme_font_override("font", _motion_fnt)
	motion_row.add_child(_motion_summary)

	# 积木ID（仅单块编辑可改：显示当前 ID；修改后由 BlockManager 重分配并同步父/子级引用）
	_id_input = _add_text_row("积木ID", "0")
	_id_input.editable = false   # 默认不可编辑；仅单块编辑(apply_to_block)时 open() 开启

	# 字符串ID（与数字ID并存；可选，系统积木按固定规则命名用途；仅单块编辑可改）
	_string_id_input = _add_text_row("字符串ID(可空)", "")
	_string_id_input.editable = false   # 默认不可编辑；仅单块编辑(apply_to_block)时 open() 开启

	# 父子级锚定（ID 绑定，参考废弃版父子级系统）：
	#   父级移动时，带 child_follow 标签的子级一并位移；子级移动不影响父级。
	_parent_id_input = _add_text_row("父级ID(0=无)", "0")
	_child_ids_input = _add_text_row("子级ID(逗号分隔)", "")

	# 填充：图片/动图/骨骼 来源
	_fill_path_input = _add_text_row("填充图片路径", "")
	_fill_path_input.placeholder_text = "res://textures/（图片相对路径）"
	# 右侧文件夹按钮：系统对话框选图 → 回填 res:// 相对路径（默认目录 res://textures/）
	UIPathPicker.attach(_fill_path_input, UIPathPicker.DIR_TEXTURES,
		{"exts": UIPathPicker.IMG_EXTS, "label": "图片", "title": "选择填充图片"})
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 6)
	_form.add_child(mode_row)
	mode_row.add_child(_label("填充模式"))
	_fill_mode_select = OptionButton.new()
	_fill_mode_select.custom_minimum_size = Vector2(FIELD_W, ROW_H)
	_fill_mode_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fill_mode_select.mouse_filter = Control.MOUSE_FILTER_STOP
	_fill_mode_select.add_theme_font_size_override("font_size", FORM_FONT)
	_fill_mode_select.add_item("最大原比例", BlockFill.Mode.KEEP_MAX_RATIO)
	_fill_mode_select.add_item("拉伸铺满", BlockFill.Mode.FILL)
	_fill_mode_select.add_item("居中", BlockFill.Mode.CENTER)
	_fill_mode_select.add_item("平铺", BlockFill.Mode.TILE)
	_fill_mode_select.add_item("原尺寸", BlockFill.Mode.ORIGINAL)
	mode_row.add_child(_fill_mode_select)

	var anim_row := HBoxContainer.new()
	anim_row.add_theme_constant_override("separation", 6)
	_form.add_child(anim_row)
	anim_row.add_child(_label("动画类型"))
	_fill_anim_select = OptionButton.new()
	_fill_anim_select.custom_minimum_size = Vector2(FIELD_W, ROW_H)
	_fill_anim_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fill_anim_select.mouse_filter = Control.MOUSE_FILTER_STOP
	_fill_anim_select.add_theme_font_size_override("font_size", FORM_FONT)
	_fill_anim_select.add_item("静态图", BlockFill.AnimType.STATIC)
	_fill_anim_select.add_item("动图(预留)", BlockFill.AnimType.ANIMATED)
	_fill_anim_select.add_item("骨骼(预留)", BlockFill.AnimType.SKELETON)
	anim_row.add_child(_fill_anim_select)

	# 文本框列表
	var tb_title_row := HBoxContainer.new()
	tb_title_row.add_theme_constant_override("separation", 6)
	_root_vbox.add_child(tb_title_row)
	var tb_title := Label.new()
	tb_title.text = "文本框列表"
	tb_title.add_theme_color_override("font_color", Color(0.8, 0.92, 1.0))
	tb_title.add_theme_font_size_override("font_size", FORM_FONT)
	tb_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tb_title_row.add_child(tb_title)
	# 「?」说明按钮（需求 K）：原来铺在表单里的「预留文本框」长说明改收进说明框，默认隐藏
	var tb_help_box := _make_help_box("预留文本框（下拉选类型，按「添加文本框」创建）：\n" +
		" 内部显示框 = 与积木同宽高、随旋转\n" +
		" 顶部/底部 = 宽2倍高1倍、不随旋转\n" +
		" 冒泡对话框 = 宽3倍高1倍、黑边白底\n" +
		" 除冒泡框外，边框与填充均透明。\n" +
		" 不允许创建两个同名文本框（含空名）。")
	tb_title_row.add_child(_help_btn(tb_help_box))
	# 预留文本框预设下拉：选一项即按积木当前宽高快速创建对应文本框
	_preset_select = OptionButton.new()
	_preset_select.custom_minimum_size = Vector2(200.0, ROW_H)
	_preset_select.mouse_filter = Control.MOUSE_FILTER_STOP
	_preset_select.add_theme_font_size_override("font_size", FORM_FONT)
	_preset_select.add_item("空（全空文本框）", 0)
	_preset_select.add_item("内部显示框", 1)
	_preset_select.add_item("顶部显示框", 2)
	_preset_select.add_item("底部显示框", 3)
	_preset_select.add_item("冒泡对话框", 4)
	_preset_select.select(0)   # 默认选中「空」
	_preset_select.item_selected.connect(_on_preset_selected)
	tb_title_row.add_child(_preset_select)
	# 说明框紧跟标题行、位于文本框列表上方（容器按 add_child 顺序排布；必须在 _tb_list 之前加入）
	_root_vbox.add_child(tb_help_box)

	_tb_list = VBoxContainer.new()
	_tb_list.add_theme_constant_override("separation", 4)
	_root_vbox.add_child(_tb_list)

	# 预设说明（需求 K）已收进上方标题行的「?」说明框，不再内联占位。

	var add_tb_btn := _styled_button("添加文本框", "add_tb")
	add_tb_btn.pressed.connect(_on_add_tb_pressed)
	_root_vbox.add_child(add_tb_btn)

	_build_attack_section()

	# 数值条列表
	var vb_title_row := HBoxContainer.new()
	vb_title_row.add_theme_constant_override("separation", 6)
	_root_vbox.add_child(vb_title_row)
	var vb_title := Label.new()
	vb_title.text = "数值条列表"
	vb_title.add_theme_color_override("font_color", Color(0.8, 0.92, 1.0))
	vb_title.add_theme_font_size_override("font_size", FORM_FONT)
	vb_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb_title_row.add_child(vb_title)
	# 「?」说明按钮（需求 K）：原来铺在表单里的「预留数值条」长说明改收进说明框，默认隐藏
	var vb_help_box := _make_help_box("预留数值条（下拉选类型，按「添加数值条」创建）：\n" +
		" 血条 = 横向、积木正上方、连续条、红/黑、10 段、显数值\n" +
		" 能量条 = 横向、积木正上方、连续条、天蓝/透明、显数值\n" +
		" 体力条 = 纵向、积木正左方、连续条、黄/黑、显百分比\n" +
		" 弹药条 = 纵向、积木正左方、图标(bullet.png)、消耗=auto 黑剪影\n" +
		" 尺寸/偏移以积木当前宽高为基准即时快照。\n" +
		" ★ 「对应变量」填一个名字即可：优先匹配本积木的**局部变量**\n" +
		"   （比例 = 现有值/最大值），没有同名局部变量则回退**全局变量**\n" +
		"   （autoload/GlobalVars）。预制各绑到同名局部变量（血条→HP 等）。\n" +
		" 图标路径默认填写 res:// 相对路径。\n" +
		" 不允许创建两个同名数值条（含空名）。")
	vb_title_row.add_child(_help_btn(vb_help_box))
	_vb_preset_select = OptionButton.new()
	_vb_preset_select.custom_minimum_size = Vector2(200.0, ROW_H)
	_vb_preset_select.mouse_filter = Control.MOUSE_FILTER_STOP
	_vb_preset_select.add_theme_font_size_override("font_size", FORM_FONT)
	_vb_preset_select.add_item("空（全空数值条）", 0)
	_vb_preset_select.add_item("血条", 1)
	_vb_preset_select.add_item("能量条", 2)
	_vb_preset_select.add_item("体力条", 3)
	_vb_preset_select.add_item("弹药条", 4)
	_vb_preset_select.select(0)   # 默认选中「空」
	_vb_preset_select.item_selected.connect(_on_vb_preset_selected)
	vb_title_row.add_child(_vb_preset_select)
	# 说明框紧跟标题行、位于数值条列表上方（必须在 _vb_list 之前加入）
	_root_vbox.add_child(vb_help_box)

	_vb_list = VBoxContainer.new()
	_vb_list.add_theme_constant_override("separation", 4)
	_root_vbox.add_child(_vb_list)

	# 预设说明（需求 K）已收进上方标题行的「?」说明框，不再内联占位。

	var add_vb_btn := _styled_button("添加数值条", "add_vb")
	add_vb_btn.pressed.connect(_on_add_vb_pressed)
	_root_vbox.add_child(add_vb_btn)

	# ============ 局部变量列表（批次 19 新增，仿「数值条列表」区块）============
	var lv_title_row := HBoxContainer.new()
	lv_title_row.add_theme_constant_override("separation", 6)
	_root_vbox.add_child(lv_title_row)
	var lv_title := Label.new()
	lv_title.text = "局部变量列表"
	lv_title.add_theme_color_override("font_color", Color(0.8, 0.92, 1.0))
	lv_title.add_theme_font_size_override("font_size", FORM_FONT)
	lv_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lv_title_row.add_child(lv_title)
	var lv_help_box := _make_help_box("局部变量（积木私有的可变数值，数值条可绑定）：\n" +
		" 每个变量含五个数值：最小值 / 最大值 / 现有值 / 恢复频率 / 回复量。\n" +
		" 恢复频率 = 每隔多少秒恢复一次；回复量 = 每次恢复多少点（可负 = 持续流失）。\n" +
		" 恢复频率 <= 0 表示不自动恢复。\n" +
		" 数值条的「对应变量」填这里的变量名 → 比例 = 现有值/最大值；\n" +
		" 填不到同名局部变量时会回退到同名全局变量（autoload/GlobalVars）。\n" +
		" 预制：弹药 0~30（每秒回1）/ 体力 0~100（每5秒回2）/\n" +
		"       能量 0~100（每3秒回5）/ HP 0~100（每10秒回1）。\n" +
		" 不允许创建两个同名局部变量（含空名）。")
	lv_title_row.add_child(_help_btn(lv_help_box))
	_lv_preset_select = OptionButton.new()
	_lv_preset_select.custom_minimum_size = Vector2(200.0, ROW_H)
	_lv_preset_select.mouse_filter = Control.MOUSE_FILTER_STOP
	_lv_preset_select.add_theme_font_size_override("font_size", FORM_FONT)
	_lv_preset_select.add_item("空（全空局部变量）", 0)
	_lv_preset_select.add_item("弹药", 1)
	_lv_preset_select.add_item("体力", 2)
	_lv_preset_select.add_item("能量", 3)
	_lv_preset_select.add_item("HP", 4)
	_lv_preset_select.select(0)   # 默认选中「空」
	_lv_preset_select.item_selected.connect(_on_lv_preset_selected)
	lv_title_row.add_child(_lv_preset_select)
	# 说明框紧跟标题行、位于局部变量列表上方（必须在 _lv_list 之前加入）
	_root_vbox.add_child(lv_help_box)

	_lv_list = VBoxContainer.new()
	_lv_list.add_theme_constant_override("separation", 4)
	_root_vbox.add_child(_lv_list)

	var add_lv_btn := _styled_button("添加局部变量", "add_lv")
	add_lv_btn.pressed.connect(_on_add_lv_pressed)
	_root_vbox.add_child(add_lv_btn)

	_error_label = Label.new()
	_error_label.text = ""
	_error_label.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
	_error_label.add_theme_font_size_override("font_size", FORM_FONT)
	_root_vbox.add_child(_error_label)

	var sep := HSeparator.new()
	_root_vbox.add_child(sep)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", int(BTN_GAP))
	_root_vbox.add_child(btn_row)
	var ok_btn := _styled_button("确定", "ok")
	ok_btn.pressed.connect(_on_ok_pressed)
	btn_row.add_child(ok_btn)
	_save_as_type_btn = _styled_button("另存为新类型", "save_as_type")
	_save_as_type_btn.pressed.connect(_on_save_as_type_pressed)
	btn_row.add_child(_save_as_type_btn)
	var cancel_btn := _styled_button("取消", "cancel")
	cancel_btn.pressed.connect(_on_cancel_pressed)
	btn_row.add_child(cancel_btn)
	var copy_cmd_btn := _styled_button("复制为命令", "copy_cmd")
	copy_cmd_btn.tooltip_text = "把当前属性生成 /create_block { ... } 文本并复制到剪贴板，可在控制台粘贴回放"
	copy_cmd_btn.pressed.connect(_on_copy_as_command_pressed)
	btn_row.add_child(copy_cmd_btn)

	await get_tree().process_frame
	await get_tree().process_frame
	var natural: Vector2 = _root_vbox.get_combined_minimum_size()
	var vp_size: Vector2 = UIStyle.canvas_viewport_size(self)
	var max_h: float = vp_size.y * 0.9
	# 内容最小宽度 500：保证「标签」行（长文本 + 调整标签 两个按钮）与文本框编辑器各行都不被挤压。
	var scroll_w: float = max(natural.x, 500.0)
	var scroll_h: float = min(natural.y, max(160.0, max_h - TITLE_BAR_H - PANEL_PADDING * 2.0))
	_scroll.size = Vector2(scroll_w, scroll_h)
	_scroll.custom_minimum_size = Vector2(scroll_w, scroll_h)
	var total := Vector2(scroll_w + PANEL_PADDING * 2.0, TITLE_BAR_H + scroll_h + PANEL_PADDING * 2.0)
	custom_minimum_size = total
	size = total
	_built = true


# ---- 行构造助手 ----
func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_font_size_override("font_size", FORM_FONT)
	l.custom_minimum_size = Vector2(LABEL_W, ROW_H)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var fnt = UIStyle.get_cjk_font()
	if fnt != null:
		l.add_theme_font_override("font", fnt)
	return l


# 文本行：标签 + 输入框（可选：行尾加「长文本」按钮，打开长文本输入窗编辑同一输入框）
func _add_text_row(label_text: String, default_text: String, with_long_text: bool = false) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_form.add_child(row)
	row.add_child(_label(label_text))
	var field := LineEdit.new()
	field.custom_minimum_size = Vector2(FIELD_W, ROW_H)
	field.add_theme_font_size_override("font_size", FORM_FONT)
	field.text = default_text
	field.add_theme_color_override("font_color", Color.WHITE)
	field.add_theme_color_override("placeholder_color", Color(1, 1, 1, 0.5))
	field.mouse_filter = Control.MOUSE_FILTER_STOP
	field.caret_blink = true
	if with_long_text:
		field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	if with_long_text:
		row.add_child(_long_text_btn(field))
	return field


# 行内「长文本」按钮：按下 → 打开长文本输入窗（source = 本行输入框）
func _long_text_btn(source: LineEdit) -> UIBtn:
	var b := UIBtn.new()
	b.set_id("long_text")
	b.set_label("长文本")
	b.custom_minimum_size = Vector2(LONG_BTN_W, ROW_H)
	b.size = Vector2(LONG_BTN_W, ROW_H)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.pressed_id.connect(_on_long_text_pressed.bind(source))
	return b


# 「标签」专用行：输入框（可手写逗号分隔）+「长文本」按钮 +「调整标签」按钮
func _add_tag_row() -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_form.add_child(row)
	row.add_child(_label("标签(逗号分隔)"))
	var field := LineEdit.new()
	field.custom_minimum_size = Vector2(FIELD_W, ROW_H)
	field.add_theme_font_size_override("font_size", FORM_FONT)
	field.text = "show,border,fill,text"
	field.add_theme_color_override("font_color", Color.WHITE)
	field.add_theme_color_override("placeholder_color", Color(1, 1, 1, 0.5))
	field.mouse_filter = Control.MOUSE_FILTER_STOP
	field.caret_blink = true
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	row.add_child(_long_text_btn(field))
	row.add_child(_tag_adjust_btn(field))
	return field


# 行内「调整标签」按钮：按下 → 打开标签选择窗（source = 本行输入框）
func _tag_adjust_btn(source: LineEdit) -> UIBtn:
	var b := UIBtn.new()
	b.set_id("adjust_tags")
	b.set_label("调整标签")
	b.custom_minimum_size = Vector2(TAG_ADJUST_BTN_W, ROW_H)
	b.size = Vector2(TAG_ADJUST_BTN_W, ROW_H)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.pressed_id.connect(_on_adjust_tags_pressed.bind(source))
	return b


# 颜色行：标签 + 输入框 + 「色盘」按钮（按下打开取色盘，确认后回填本行）
func _add_color_row(label_text: String, default_text: String) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_form.add_child(row)
	row.add_child(_label(label_text))
	var field := LineEdit.new()
	field.custom_minimum_size = Vector2(FIELD_W, ROW_H)
	field.add_theme_font_size_override("font_size", FORM_FONT)
	field.text = default_text
	field.add_theme_color_override("font_color", Color.WHITE)
	field.add_theme_color_override("placeholder_color", Color(1, 1, 1, 0.5))
	field.mouse_filter = Control.MOUSE_FILTER_STOP
	field.caret_blink = true
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	row.add_child(_color_btn(field, label_text))
	return field


# 行内「色盘」按钮：按下 → 打开取色盘窗口（source = 本行输入框）
func _color_btn(source: LineEdit, title: String) -> UIBtn:
	var b := UIBtn.new()
	b.set_id("pick_color")
	b.set_label("色盘")
	b.custom_minimum_size = Vector2(COLOR_BTN_W, ROW_H)
	b.size = Vector2(COLOR_BTN_W, ROW_H)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.pressed_id.connect(_on_pick_color_pressed.bind(source, title))
	return b


# 提示行：与输入行左边缘对齐的浅色小字（只作说明，不可编辑）
# 仅用手工 \n 断行、不启用 autowrap：容器内 autowrap 的高度测量不可靠（会与下一行重叠）。
func _add_hint_row(text: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_form.add_child(row)
	var spacer := Control.new()          # 占掉左侧标签位，与输入行左边缘对齐
	spacer.custom_minimum_size = Vector2(LABEL_W, 1)
	row.add_child(spacer)
	var l := Label.new()
	l.text = text
	l.clip_text = true
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	l.add_theme_font_size_override("font_size", maxi(FORM_FONT - 3, 9))
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fnt = UIStyle.get_cjk_font()
	if fnt != null:
		l.add_theme_font_override("font", fnt)
	row.add_child(l)
	return row


# ---- 「?」说明按钮 + 说明框（需求 K）----
# 背景：文本框 / 数值条 / 攻击判定框三块预设说明很长，原先用 _add_hint_row 常驻在表单里，
#       把面板撑得很高。现改为「按需展开」：标题行一个「?」按钮 + 一个默认隐藏的说明框。
# 交互：点「?」→ 打开（同时收起其它已打开的框）→ 再点「?」或点框体任意位置 → 关闭。

# 「?」按钮：按下即切换对应说明框的显隐
func _help_btn(box: PanelContainer) -> UIBtn:
	var b := UIBtn.new()
	b.set_id("help")
	b.set_label("?")
	b.custom_minimum_size = Vector2(HELP_BTN_W, ROW_H)
	b.size = Vector2(HELP_BTN_W, ROW_H)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.tooltip_text = "显示 / 隐藏说明"
	b.pressed_id.connect(_on_help_pressed.bind(box))
	return b


# 说明框：浅色小字方框，默认隐藏（隐藏时容器不计入 min size → 不占地方）。
# 与 _add_hint_row 同样**不启用 autowrap**（容器内 autowrap 高度测量不可靠，会与下一行重叠），
# 文本自带手工 \n 断行；行宽按面板内容宽（≥500）书写，换行位置无需重算。
func _make_help_box(text: String) -> PanelContainer:
	var box := PanelContainer.new()
	box.visible = false
	box.mouse_filter = Control.MOUSE_FILTER_STOP   # 接住点击 → 点框体即关闭
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 文本框：液态玻璃冰白底（半透明纯白轻纱），替代原先的纯黑底
	var sb := UIStyle.glass_box(Color(1.0, 1.0, 1.0, 0.10), UIStyle.BORDER, int(UIStyle.CORNER_RADIUS), 1)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	box.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 让点击穿透到框体
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	l.add_theme_font_size_override("font_size", maxi(FORM_FONT - 3, 9))
	var fnt = UIStyle.get_cjk_font()
	if fnt != null:
		l.add_theme_font_override("font", fnt)
	box.add_child(l)
	box.gui_input.connect(_on_help_box_input.bind(box))
	_help_boxes.append(box)
	return box


func _on_help_pressed(_id: String, box: PanelContainer) -> void:
	if not is_instance_valid(box):
		return
	if box.visible:
		box.visible = false
		if _open_help_box == box:
			_open_help_box = null
		return
	_close_help_box()          # 同屏只留一个说明框
	box.visible = true
	_open_help_box = box


# 点击说明框体 → 关闭
# ★★ 必须排除滚轮：滚轮事件同样是 `InputEventMouseButton` 且 `pressed == true`，
#    若一并当作「点击」处理，用户滚动页面时鼠标一划过说明框就会把它关掉（本次修复）。
# ★ 也**不要**调 `accept_event()`：不吞事件，滚轮继续冒泡给 ScrollContainer 照常翻页。
func _on_help_box_input(ev: InputEvent, box: PanelContainer) -> void:
	if not (ev is InputEventMouseButton):
		return
	var mb: InputEventMouseButton = ev
	if not mb.pressed:
		return
	if mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN,
			MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
		return   # 滚轮：不关闭、不拦截 → 交给 ScrollContainer 正常滚动
	if is_instance_valid(box):
		box.visible = false
	if _open_help_box == box:
		_open_help_box = null


func _close_help_box() -> void:
	if _open_help_box != null and is_instance_valid(_open_help_box):
		_open_help_box.visible = false
	_open_help_box = null


# 给**已建好的行**补上「?」按钮 + 说明框（复用需求 K 的按钮/框机制）：
# 按钮追加到行尾，说明框插到该行正下方（同一容器），视觉上就在这一行下面。
# ↑ 与「板块标题行」用法一致，区别只在于这里的说明挂在某个具体属性行上（碰撞图层 / 标签）。
func _help_for_row(row: Control, text: String) -> PanelContainer:
	var box := _make_help_box(text)
	row.add_child(_help_btn(box))
	var parent: Node = row.get_parent()
	parent.add_child(box)
	parent.move_child(box, row.get_index() + 1)   # 显式挪到该行正下方（不依赖 add 顺序）
	return box


func _hide_all_help_boxes() -> void:
	for b in _help_boxes:
		if is_instance_valid(b):
			b.visible = false
	_open_help_box = null


func _styled_button(text: String, btn_id: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, BTN_H)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.set_meta("btn_id", btn_id)
	var sb_default := UIStyle.glass_box(UIStyle.FILL_DEFAULT, UIStyle.BORDER, int(UIStyle.CORNER_RADIUS), 1)
	sb_default.content_margin_left = 6
	sb_default.content_margin_right = 6
	sb_default.content_margin_top = 4
	sb_default.content_margin_bottom = 4
	var sb_hover := sb_default.duplicate()
	sb_hover.bg_color = UIStyle.FILL_HOVER
	var sb_pressed := sb_default.duplicate()
	sb_pressed.bg_color = UIStyle.FILL_PRESSED
	btn.add_theme_stylebox_override("normal", sb_default)
	btn.add_theme_stylebox_override("hover", sb_hover)
	btn.add_theme_stylebox_override("pressed", sb_pressed)
	btn.add_theme_stylebox_override("focus", sb_default)
	btn.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	btn.add_theme_color_override("font_hover_color", UIStyle.TEXT_PRESSED)
	btn.add_theme_color_override("font_pressed_color", UIStyle.TEXT_PRESSED)
	btn.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	var fnt = UIStyle.get_cjk_font()
	if fnt != null:
		btn.add_theme_font_override("font", fnt)
	return btn


# ---- 文本框编辑器（动态）----
# 「添加文本框」：按下拉当前选择创建。
#   - 选中某预设 → 创建该预设文本框；
#   - 选中「空」(默认) → 旧行为：创建全空文本框。
# 同名（含空名）冲突一律拒绝，不自动改名。
func _on_add_tb_pressed() -> void:
	if _error_label != null and is_instance_valid(_error_label):
		_error_label.text = ""
	if _selected_preset != "":
		_add_preset_tb(_selected_preset)
		return
	# 空（默认）：旧行为，创建全空文本框
	_try_create_tb({
		"name": "", "width": 200.0, "height": 48.0, "cx": 0.0, "cy": 0.0,
		"border_color": "#FFFFFFFF", "fill_color": "#3399FFFF",
		"fill_source": 0, "fill_image_path": "", "rotation_deg": 0.0,
		"follow_block_rotation": true, "text_def": "", "hide_when_empty": false,
	})


# 下拉选中：只记录选中的预设 key，不直接创建；
# 真正的创建由「添加文本框」按钮触发（同一次打开里可连续添加不同类型）。
func _on_preset_selected(idx: int) -> void:
	match idx:
		1: _selected_preset = "internal"
		2: _selected_preset = "top"
		3: _selected_preset = "bottom"
		4: _selected_preset = "bubble"
		_: _selected_preset = ""


# 按预留预设生成一份文本框数据并创建编辑器（带同名冲突检测）。
# 尺寸 / 偏移以「文本框列表里积木当前显示的宽高」为基准（即时快照，见 text_box.gd 的 PRESETS）。
func _add_preset_tb(key: String) -> void:
	var w: float = _fnum(_width_input.text, 120.0)
	var h: float = _fnum(_height_input.text, 120.0)
	var d: Dictionary = TextBox.preset_dict(key, w, h)
	if d.is_empty():
		return
	_try_create_tb(d)


# 创建文本框编辑器（统一入口）：同名冲突则拒绝并以错误标签提示，否则创建并把下拉复位到「空」。
func _try_create_tb(d: Dictionary) -> void:
	var nm: String = str(d.get("name", "")).strip_edges()
	if _has_name_conflict(nm):
		_show_error("已存在同名文本框：%s" % (nm if nm != "" else "（空名）"))
		return
	_make_tb_editor(d)
	if _preset_select != null and is_instance_valid(_preset_select):
		_preset_select.select(0)   # select() 不会重发 item_selected 信号
	_selected_preset = ""


# 同名冲突检测：与已有文本框编辑器的名字（含空名）完全一致才算冲突。
func _has_name_conflict(name: String) -> bool:
	var nm: String = name.strip_edges()
	for c in _tb_editors:
		if c.has("name") and is_instance_valid(c["name"]):
			if c["name"].text.strip_edges() == nm:
				return true
	return false


func _make_tb_editor(data: Dictionary) -> void:
	var outer := PanelContainer.new()
	outer.mouse_filter = Control.MOUSE_FILTER_STOP
	# 液态玻璃小节框：半透明纯白轻纱 + 冰蓝描边
	var box := UIStyle.glass_box(Color(1.0, 1.0, 1.0, 0.09), UIStyle.BORDER, 4, 1)
	box.content_margin_left = 4
	box.content_margin_right = 4
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	outer.add_theme_stylebox_override("panel", box)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 3)
	outer.add_child(root)

	var ctrls := {}
	ctrls["root"] = outer

	ctrls["name"] = _tb_row(root, "文本框名", str(data.get("name", "")), 90.0)
	var wh := HBoxContainer.new()
	wh.add_theme_constant_override("separation", 6)
	root.add_child(wh)
	wh.add_child(_label("宽"))
	ctrls["width"] = _tb_num(wh, str(data.get("width", 200.0)))
	wh.add_child(_label("高"))
	ctrls["height"] = _tb_num(wh, str(data.get("height", 48.0)))
	var cc := HBoxContainer.new()
	cc.add_theme_constant_override("separation", 6)
	root.add_child(cc)
	cc.add_child(_label("中心X"))
	ctrls["cx"] = _tb_num(cc, str(data.get("cx", 0.0)))
	cc.add_child(_label("中心Y"))
	ctrls["cy"] = _tb_num(cc, str(data.get("cy", 0.0)))
	var rc := HBoxContainer.new()
	rc.add_theme_constant_override("separation", 6)
	root.add_child(rc)
	rc.add_child(_label("旋转"))
	ctrls["rotation"] = _tb_num(rc, str(data.get("rotation_deg", 0.0)))
	var follow := CheckBox.new()
	follow.text = "随积木旋转"
	follow.button_pressed = bool(data.get("follow_block_rotation", true))
	follow.add_theme_font_size_override("font_size", FORM_FONT)
	follow.add_theme_color_override("font_color", Color.WHITE)
	follow.mouse_filter = Control.MOUSE_FILTER_STOP
	rc.add_child(follow)
	ctrls["follow"] = follow
	ctrls["border_color"] = _tb_row(root, "边框色", str(data.get("border_color", "#FFFFFFFF")), 90.0, false, true)
	ctrls["fill_color"] = _tb_row(root, "填充色", str(data.get("fill_color", "#3399FFFF")), 90.0, false, true)
	var src_row := HBoxContainer.new()
	src_row.add_theme_constant_override("separation", 6)
	root.add_child(src_row)
	src_row.add_child(_label("填充来源"))
	var src_sel := OptionButton.new()
	src_sel.custom_minimum_size = Vector2(120.0, ROW_H)
	src_sel.mouse_filter = Control.MOUSE_FILTER_STOP
	src_sel.add_theme_font_size_override("font_size", FORM_FONT)
	src_sel.add_item("纯色", TextBox.FillSource.SOLID)
	src_sel.add_item("图片", TextBox.FillSource.IMAGE)
	var sid := int(data.get("fill_source", 0))
	for i in src_sel.item_count:
		if src_sel.get_item_id(i) == sid:
			src_sel.select(i)
			break
	src_row.add_child(src_sel)
	ctrls["fill_source"] = src_sel
	ctrls["fill_image_path"] = _tb_row(root, "图片路径", str(data.get("fill_image_path", "")), 90.0)
	ctrls["fill_image_path"].placeholder_text = "res://textures/（图片相对路径）"
	# 右侧文件夹按钮：选图 → 回填 res:// 相对路径
	UIPathPicker.attach(ctrls["fill_image_path"], UIPathPicker.DIR_TEXTURES,
		{"exts": UIPathPicker.IMG_EXTS, "label": "图片", "title": "选择文本框填充图片"})
	ctrls["text_def"] = _tb_row(root, "文本(修饰)[内容]", str(data.get("text_def", "")), 90.0, true)   # 行尾带「长文本」按钮
	# 「内容为空时是否隐藏」：文本（经变量求值后）与填充图片都为空 → 整个文本框不显示。
	# 该变量亦可在运行时由事件链修改：block.set_text_box_var(文本框名, "hide_when_empty", true)
	var hide_empty := CheckBox.new()
	hide_empty.text = "内容为空时隐藏(无文本且无图片)"
	hide_empty.button_pressed = bool(data.get("hide_when_empty", false))
	hide_empty.add_theme_font_size_override("font_size", FORM_FONT)
	hide_empty.add_theme_color_override("font_color", Color.WHITE)
	hide_empty.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(hide_empty)
	ctrls["hide_empty"] = hide_empty
	var del := _styled_button("删除此文本框", "del_tb")
	del.custom_minimum_size = Vector2(0, 18.0)
	del.pressed.connect(_on_del_tb_pressed.bind(ctrls))
	root.add_child(del)

	_tb_list.add_child(outer)
	_tb_editors.append(ctrls)


func _tb_row(parent: Container, label_text: String, default_text: String, lbl_w: float, with_long_text: bool = false, with_color: bool = false) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var l := Label.new()
	l.text = label_text
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_font_size_override("font_size", FORM_FONT)
	l.custom_minimum_size = Vector2(lbl_w, ROW_H)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	var field := LineEdit.new()
	field.custom_minimum_size = Vector2(180.0, ROW_H)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.add_theme_font_size_override("font_size", FORM_FONT)
	field.text = default_text
	field.add_theme_color_override("font_color", Color.WHITE)
	field.add_theme_color_override("placeholder_color", Color(1, 1, 1, 0.5))
	field.mouse_filter = Control.MOUSE_FILTER_STOP
	field.caret_blink = true
	row.add_child(field)
	if with_long_text:
		row.add_child(_long_text_btn(field))
	if with_color:
		row.add_child(_color_btn(field, label_text))
	return field


func _tb_num(parent: Container, default_text: String) -> LineEdit:
	var field := LineEdit.new()
	field.custom_minimum_size = Vector2(70.0, ROW_H)
	field.add_theme_font_size_override("font_size", FORM_FONT)
	field.text = default_text
	field.add_theme_color_override("font_color", Color.WHITE)
	field.mouse_filter = Control.MOUSE_FILTER_STOP
	field.caret_blink = true
	parent.add_child(field)
	return field


# ---- 长文本输入窗（复用 UILongTextInputPanel）----
# 复用旧版「长文本按钮 + 长文本输入页」：按钮按下 → 打开大窗口书写，
# 内容实时回填到本行 LineEdit（确定后 _collect_* 读的就是回填后的文本）。
func _on_long_text_pressed(_id: String, source: LineEdit) -> void:
	if source == null or not is_instance_valid(source):
		return
	# 已有窗口 → 先正常关闭（会把内容回填给原输入框），再开新的
	if _long_text_panel != null and is_instance_valid(_long_text_panel):
		_long_text_panel.close()
	var layer := _ui_layer()
	if layer == null:
		push_warning("[PropertyEditor] 未找到 CanvasLayer，长文本窗无法显示")
		return
	_long_text_panel = UILongTextInputPanel.new()
	layer.add_child(_long_text_panel)
	_long_text_panel.closed.connect(_on_long_text_closed)
	_long_text_panel.open(source, source.text)


func _on_long_text_closed() -> void:
	_long_text_panel = null


# 「调整标签」按钮：打开标签选择窗，勾选标签 → 确定后回填到「标签」输入框
func _on_adjust_tags_pressed(_id: String, source: LineEdit) -> void:
	if source == null or not is_instance_valid(source):
		return
	# 已有窗口 → 先关闭再开新的
	if _tag_picker != null and is_instance_valid(_tag_picker):
		_tag_picker.close()
		_tag_picker = null
	var layer := _ui_layer()
	if layer == null:
		push_warning("[PropertyEditor] 未找到 CanvasLayer，标签选择窗无法显示")
		return
	_tag_picker = TagPickerPanel.new()
	layer.add_child(_tag_picker)
	_tag_picker.closed.connect(_on_tag_picker_closed)
	# ★ 积木模式：只列积木标签（BlockTags.ALL），物品标签不出现在这里；标题末尾标（积木）。
	_tag_picker.open(source, TagPickerPanel.Mode.BLOCK)


func _on_tag_picker_closed() -> void:
	_tag_picker = null


# 「色盘」按钮：打开取色盘窗口（源 = 本行颜色输入框），确认后回填
func _on_pick_color_pressed(_id: String, source: LineEdit, title: String) -> void:
	if source == null or not is_instance_valid(source):
		return
	# 已有窗口 → 先关闭再开新的
	if _color_panel != null and is_instance_valid(_color_panel):
		_color_panel.close()
		_color_panel = null
	var layer := _ui_layer()
	if layer == null:
		push_warning("[PropertyEditor] 未找到 CanvasLayer，取色盘无法显示")
		return
	_color_panel = UIColorPickerPanel.new()
	layer.add_child(_color_panel)
	_color_panel.closed.connect(_on_color_panel_closed)
	# ★ 传 self 作锚点：取色盘贴在本属性面板的左/右侧打开（不居中，避免盖住属性面板）
	_color_panel.open(source, title, self)


func _on_color_panel_closed() -> void:
	_color_panel = null


# ---- 积木运动（细化运动参数）----
# 「调整运动...」按钮：打开「积木运动」面板，参数在 _motion_data 里；关闭时取回。
func _on_motion_pressed() -> void:
	# 已有窗口 → 先关闭（会回填）再开新的
	if _motion_panel != null and is_instance_valid(_motion_panel):
		_motion_panel.close()
	var layer := _ui_layer()
	if layer == null:
		push_warning("[PropertyEditor] 未找到 CanvasLayer，积木运动面板无法显示")
		return
	_motion_panel = BlockMotionPanel.new()
	layer.add_child(_motion_panel)
	_motion_panel.closed.connect(_on_motion_closed)
	_motion_panel.open(_motion_data.duplicate())


func _on_motion_closed() -> void:
	# 取消时 get_values() 返回的就是打开时的原值 → 等于无改动
	if _motion_panel != null and is_instance_valid(_motion_panel):
		_motion_data = _motion_panel.get_values()
	_motion_panel = null
	_refresh_motion_summary()


# 回填 / 刷新「积木运动」行右侧的摘要（当前参数一览）
func _refresh_motion_summary() -> void:
	if _motion_summary == null or not is_instance_valid(_motion_summary):
		return
	var fly: String = "可飞行" if bool(_motion_data.get("can_fly", false)) else "不可飞行"
	var t := "%s | 水平 %s/%s | 上升 %s/%s" % [
		fly,
		_fmt_brief(_motion_data.get("horiz_max_speed", 240.0)),
		_fmt_brief(_motion_data.get("horiz_accel", 0.0)),
		_fmt_brief(_motion_data.get("fly_up_max_speed", 240.0)),
		_fmt_brief(_motion_data.get("fly_up_accel", 0.0)),
	]
	_motion_summary.text = t
	_motion_summary.tooltip_text = "可飞行 | 水平 最大速度/加速度 | 上升 最大速度/加速度\n" + t


# 整数值去掉小数点，方便摘要显示
func _fmt_brief(v) -> String:
	var f := float(v)
	return str(int(f)) if f == floor(f) else str(f)


# 向上查找 CanvasLayer：长文本窗必须挂在 CanvasLayer 下，
# 这样它的 position 才以视口为原点（open() 用视口尺寸居中），且浮在属性面板之上。
func _ui_layer() -> CanvasLayer:
	var n: Node = get_parent()
	while n != null:
		if n is CanvasLayer:
			return n
		n = n.get_parent()
	return null


func _on_del_tb_pressed(ctrls: Dictionary) -> void:
	var root = ctrls.get("root")
	if root != null and is_instance_valid(root):
		root.queue_free()
	var idx := _tb_editors.find(ctrls)
	if idx >= 0:
		_tb_editors.remove_at(idx)


func _collect_textboxes() -> Array:
	var out: Array = []
	for ctrls in _tb_editors:
		out.append({
			"name": ctrls["name"].text,
			"width": _fnum(ctrls["width"].text, 200.0),
			"height": _fnum(ctrls["height"].text, 48.0),
			"cx": _fnum(ctrls["cx"].text, 0.0),
			"cy": _fnum(ctrls["cy"].text, 0.0),
			"border_color": ctrls["border_color"].text.strip_edges(),
			"fill_color": ctrls["fill_color"].text.strip_edges(),
			"fill_source": int(ctrls["fill_source"].get_selected_id()),
			"fill_image_path": ctrls["fill_image_path"].text.strip_edges(),
			"rotation_deg": _fnum(ctrls["rotation"].text, 0.0),
			"follow_block_rotation": bool(ctrls["follow"].button_pressed),
			"text_def": ctrls["text_def"].text,
			"hide_when_empty": bool(ctrls["hide_empty"].button_pressed),
		})
	return out


# ---- 攻击判定框（动态，仿文本框）----
func _build_attack_section() -> void:
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	_root_vbox.add_child(title_row)
	var title := Label.new()
	title.text = "攻击判定框列表（近战）"
	title.add_theme_color_override("font_color", Color(0.8, 0.92, 1.0))
	title.add_theme_font_size_override("font_size", FORM_FONT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	_ab_preset_select = OptionButton.new()
	_ab_preset_select.custom_minimum_size = Vector2(200.0, ROW_H)
	_ab_preset_select.mouse_filter = Control.MOUSE_FILTER_STOP
	_ab_preset_select.add_theme_font_size_override("font_size", FORM_FONT)
	_ab_preset_select.add_item("空（全空判定框）", 0)
	_ab_preset_select.add_item("水平普攻", 1)
	_ab_preset_select.add_item("下落攻击框", 2)
	_ab_preset_select.select(0)   # 默认选中「空」
	_ab_preset_select.item_selected.connect(_on_ab_preset_selected)
	title_row.add_child(_ab_preset_select)
	# 「?」说明按钮（需求 K）：原来铺在表单里的「预留攻击判定框」长说明改收进说明框，默认隐藏
	var ab_help_box := _make_help_box("预留攻击判定框（下拉选类型，按「添加判定框」创建）：\n" +
		" 水平普攻 = 中心在积木右侧1.5倍宽处、\n" +
		"   宽2倍高2倍；朝向为右时启用；攻击=基础攻击力*1\n" +
		" 下落攻击框 = 中心在积木正下方1倍高处、\n" +
		"   宽3倍高1倍；恒启用；攻击=基础攻击力*3\n" +
		" 尺寸/偏移以积木当前宽高为基准即时快照。\n" +
		" 不允许创建两个同名判定框（含空名）。")
	title_row.add_child(_help_btn(ab_help_box))
	# 说明框紧跟标题行、位于判定框列表上方（必须在 _ab_list 之前加入）
	_root_vbox.add_child(ab_help_box)

	_ab_list = VBoxContainer.new()
	_ab_list.add_theme_constant_override("separation", 4)
	_root_vbox.add_child(_ab_list)

	# 预设说明（需求 K）已收进上方标题行的「?」说明框，不再内联占位。

	var add_ab_btn := _styled_button("添加判定框", "add_ab")
	add_ab_btn.pressed.connect(_on_add_ab_pressed)
	_root_vbox.add_child(add_ab_btn)


func _on_ab_preset_selected(idx: int) -> void:
	match idx:
		1: _selected_ab_preset = "horizontal"
		2: _selected_ab_preset = "fall"
		_: _selected_ab_preset = ""


func _on_add_ab_pressed() -> void:
	if _error_label != null and is_instance_valid(_error_label):
		_error_label.text = ""
	if _selected_ab_preset != "":
		_add_preset_ab(_selected_ab_preset)
		return
	# 空（默认）：创建全空判定框
	_try_create_ab({
		"name": "", "width": 120.0, "height": 120.0,
		"cx": 0.0, "cy": 0.0, "enable_condition": "", "attack_power": "",
	})


func _add_preset_ab(key: String) -> void:
	var w: float = _fnum(_width_input.text, 120.0)
	var h: float = _fnum(_height_input.text, 120.0)
	var d: Dictionary = AttackBox.preset_dict(key, w, h)
	if d.is_empty():
		return
	_try_create_ab(d)


func _try_create_ab(d: Dictionary) -> void:
	var nm: String = str(d.get("name", "")).strip_edges()
	if _has_ab_name_conflict(nm):
		_show_error("已存在同名判定框：%s" % (nm if nm != "" else "（空名）"))
		return
	_make_ab_editor(d)
	if _ab_preset_select != null and is_instance_valid(_ab_preset_select):
		_ab_preset_select.select(0)   # select() 不重发 item_selected 信号
	_selected_ab_preset = ""


func _has_ab_name_conflict(name: String) -> bool:
	var nm: String = name.strip_edges()
	for c in _ab_editors:
		if c.has("name") and is_instance_valid(c["name"]):
			if c["name"].text.strip_edges() == nm:
				return true
	return false


func _make_ab_editor(data: Dictionary) -> void:
	var outer := PanelContainer.new()
	outer.mouse_filter = Control.MOUSE_FILTER_STOP
	# 液态玻璃小节框：半透明纯白轻纱 + 冰蓝描边
	var box := UIStyle.glass_box(Color(1.0, 1.0, 1.0, 0.09), UIStyle.BORDER, 4, 1)
	box.content_margin_left = 4
	box.content_margin_right = 4
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	outer.add_theme_stylebox_override("panel", box)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 3)
	outer.add_child(root)

	var ctrls := {}
	ctrls["root"] = outer

	ctrls["name"] = _tb_row(root, "框名", str(data.get("name", "")), 90.0)
	var wh := HBoxContainer.new()
	wh.add_theme_constant_override("separation", 6)
	root.add_child(wh)
	wh.add_child(_label("宽"))
	ctrls["width"] = _tb_num(wh, str(data.get("width", 120.0)))
	wh.add_child(_label("高"))
	ctrls["height"] = _tb_num(wh, str(data.get("height", 120.0)))
	var cc := HBoxContainer.new()
	cc.add_theme_constant_override("separation", 6)
	root.add_child(cc)
	cc.add_child(_label("中心X"))
	ctrls["cx"] = _tb_num(cc, str(data.get("cx", 0.0)))
	cc.add_child(_label("中心Y"))
	ctrls["cy"] = _tb_num(cc, str(data.get("cy", 0.0)))
	ctrls["enable"] = _tb_row(root, "启用条件", str(data.get("enable_condition", "")), 90.0, true)   # 行尾带「长文本」按钮
	ctrls["attack"] = _tb_row(root, "攻击力函数", str(data.get("attack_power", "")), 90.0, true)
	var del := _styled_button("删除此判定框", "del_ab")
	del.custom_minimum_size = Vector2(0, 18.0)
	del.pressed.connect(_on_del_ab_pressed.bind(ctrls))
	root.add_child(del)

	_ab_list.add_child(outer)
	_ab_editors.append(ctrls)


func _on_del_ab_pressed(ctrls: Dictionary) -> void:
	var root = ctrls.get("root")
	if root != null and is_instance_valid(root):
		root.queue_free()
	var idx := _ab_editors.find(ctrls)
	if idx >= 0:
		_ab_editors.remove_at(idx)


func _collect_attack_boxes() -> Array:
	var out: Array = []
	for ctrls in _ab_editors:
		out.append({
			"name": ctrls["name"].text,
			"width": _fnum(ctrls["width"].text, 120.0),
			"height": _fnum(ctrls["height"].text, 120.0),
			"cx": _fnum(ctrls["cx"].text, 0.0),
			"cy": _fnum(ctrls["cy"].text, 0.0),
			"enable_condition": ctrls["enable"].text,
			"attack_power": ctrls["attack"].text,
		})
	return out


func _clear_ab_editors() -> void:
	for c in _ab_editors:
		if c.has("root") and is_instance_valid(c["root"]):
			c["root"].queue_free()
	_ab_editors.clear()


# ---- 数值条编辑器（动态，仿文本框 / 攻击判定框）----
func _on_vb_preset_selected(idx: int) -> void:
	match idx:
		1: _selected_vb_preset = "health"
		2: _selected_vb_preset = "energy"
		3: _selected_vb_preset = "stamina"
		4: _selected_vb_preset = "ammo"
		_: _selected_vb_preset = ""


func _on_add_vb_pressed() -> void:
	if _error_label != null and is_instance_valid(_error_label):
		_error_label.text = ""
	if _selected_vb_preset != "":
		_add_preset_vb(_selected_vb_preset)
		return
	_try_create_vb({
		"name": "", "orientation": 0, "cx": 0.0, "cy": -60.0,
		"width": 100.0, "height": 8.0, "show_mode": 0,
		"bind_var": "",
		"style": 0, "active_color": "#FF0000FF", "consumed_color": "#000000FF", "segments": 1,
		"icon_active_path": "", "icon_consumed_path": "",
	})


func _add_preset_vb(key: String) -> void:
	var w: float = _fnum(_width_input.text, 120.0)
	var h: float = _fnum(_height_input.text, 120.0)
	var d: Dictionary = ValueBar.preset_dict(key, w, h)
	if d.is_empty():
		return
	_try_create_vb(d)


func _try_create_vb(d: Dictionary) -> void:
	var nm: String = str(d.get("name", "")).strip_edges()
	if _has_vb_name_conflict(nm):
		_show_error("已存在同名数值条：%s" % (nm if nm != "" else "（空名）"))
		return
	_make_vb_editor(d)
	if _vb_preset_select != null and is_instance_valid(_vb_preset_select):
		_vb_preset_select.select(0)
	_selected_vb_preset = ""


func _has_vb_name_conflict(name: String) -> bool:
	var nm: String = name.strip_edges()
	for c in _vb_editors:
		if c.has("name") and is_instance_valid(c["name"]):
			if c["name"].text.strip_edges() == nm:
				return true
	return false


func _make_vb_editor(data: Dictionary) -> void:
	var outer := PanelContainer.new()
	outer.mouse_filter = Control.MOUSE_FILTER_STOP
	# 液态玻璃小节框：半透明纯白轻纱 + 冰蓝描边
	var box := UIStyle.glass_box(Color(1.0, 1.0, 1.0, 0.09), UIStyle.BORDER, 4, 1)
	box.content_margin_left = 4
	box.content_margin_right = 4
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	outer.add_theme_stylebox_override("panel", box)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 3)
	outer.add_child(root)

	var ctrls := {}
	ctrls["root"] = outer

	ctrls["name"] = _tb_row(root, "数值条名", str(data.get("name", "")), 90.0)

	var orow := HBoxContainer.new()
	orow.add_theme_constant_override("separation", 6)
	root.add_child(orow)
	orow.add_child(_label("朝向"))
	var osel := OptionButton.new()
	osel.custom_minimum_size = Vector2(110.0, ROW_H)
	osel.mouse_filter = Control.MOUSE_FILTER_STOP
	osel.add_theme_font_size_override("font_size", FORM_FONT)
	osel.add_item("横向", ValueBar.Orientation.HORIZONTAL)
	osel.add_item("纵向", ValueBar.Orientation.VERTICAL)
	_select_by_id(osel, int(data.get("orientation", 0)))
	orow.add_child(osel)
	ctrls["orientation"] = osel

	var wh := HBoxContainer.new()
	wh.add_theme_constant_override("separation", 6)
	root.add_child(wh)
	wh.add_child(_label("宽"))
	ctrls["width"] = _tb_num(wh, str(data.get("width", 100.0)))
	wh.add_child(_label("高"))
	ctrls["height"] = _tb_num(wh, str(data.get("height", 8.0)))
	var cc := HBoxContainer.new()
	cc.add_theme_constant_override("separation", 6)
	root.add_child(cc)
	cc.add_child(_label("中心X"))
	ctrls["cx"] = _tb_num(cc, str(data.get("cx", 0.0)))
	cc.add_child(_label("中心Y"))
	ctrls["cy"] = _tb_num(cc, str(data.get("cy", 0.0)))

	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 6)
	root.add_child(srow)
	srow.add_child(_label("显示"))
	var ssel := OptionButton.new()
	ssel.custom_minimum_size = Vector2(110.0, ROW_H)
	ssel.mouse_filter = Control.MOUSE_FILTER_STOP
	ssel.add_theme_font_size_override("font_size", FORM_FONT)
	ssel.add_item("数值(当前/最大)", ValueBar.ShowMode.VALUE)
	ssel.add_item("百分比", ValueBar.ShowMode.PERCENT)
	_select_by_id(ssel, int(data.get("show_mode", 0)))
	srow.add_child(ssel)
	ctrls["show_mode"] = ssel

	# ★ 批次 19：原来的「当前变量」+「最大变量」两个输入框**已移除**，
	#   改为单一「对应变量」框 —— 填一个名字即可（局部变量优先，回退全局变量）。
	#   ★ `_tb_row` 自己会加标签，所以这里**不要**再 `crow.add_child(_label(...))`（会重复）。
	ctrls["bind_var"] = _tb_row(root, "对应变量", str(data.get("bind_var", "")), 90.0)
	ctrls["bind_var"].placeholder_text = "局部变量名（优先）/ 全局变量名"

	var strow := HBoxContainer.new()
	strow.add_theme_constant_override("separation", 6)
	root.add_child(strow)
	strow.add_child(_label("样式"))
	var stsel := OptionButton.new()
	stsel.custom_minimum_size = Vector2(110.0, ROW_H)
	stsel.mouse_filter = Control.MOUSE_FILTER_STOP
	stsel.add_theme_font_size_override("font_size", FORM_FONT)
	stsel.add_item("连续条", ValueBar.Style.CONTINUOUS)
	stsel.add_item("图标", ValueBar.Style.ICON)
	_select_by_id(stsel, int(data.get("style", 0)))
	strow.add_child(stsel)
	ctrls["style"] = stsel

	ctrls["active_color"] = _tb_row(root, "激活色(#RRGGBBAA)", str(data.get("active_color", "#FF0000FF")), 90.0, false, true)
	ctrls["consumed_color"] = _tb_row(root, "消耗色(#RRGGBBAA)", str(data.get("consumed_color", "#000000FF")), 90.0, false, true)
	ctrls["segments"] = _tb_row(root, "隔断段数", str(data.get("segments", 1)), 90.0)
	ctrls["icon_active_path"] = _tb_row(root, "激活图标路径(res://)", str(data.get("icon_active_path", "")), 90.0)
	ctrls["icon_active_path"].placeholder_text = "res://textures/value_bars/bullet.png"
	ctrls["icon_consumed_path"] = _tb_row(root, "消耗图标路径(空/auto/路径)", str(data.get("icon_consumed_path", "")), 90.0)
	ctrls["icon_consumed_path"].placeholder_text = "空=不显示；auto=激活图标黑剪影；或 res://路径"
	# 两个图标路径各接一个文件夹按钮（默认目录 res://textures/value_bars/）。
	# ★ 选中文件会**整体替换**该框内容（原内容若是 auto/空，会被选中的路径取代）。
	for _ic_key in ["icon_active_path", "icon_consumed_path"]:
		UIPathPicker.attach(ctrls[_ic_key], UIPathPicker.DIR_VALUE_BARS,
			{"exts": UIPathPicker.IMG_EXTS, "label": "图片", "title": "选择图标"})

	var del := _styled_button("删除此数值条", "del_vb")
	del.custom_minimum_size = Vector2(0, 18.0)
	del.pressed.connect(_on_del_vb_pressed.bind(ctrls))
	root.add_child(del)

	_vb_list.add_child(outer)
	_vb_editors.append(ctrls)


func _on_del_vb_pressed(ctrls: Dictionary) -> void:
	var root = ctrls.get("root")
	if root != null and is_instance_valid(root):
		root.queue_free()
	var idx := _vb_editors.find(ctrls)
	if idx >= 0:
		_vb_editors.remove_at(idx)


func _collect_value_bars() -> Array:
	var out: Array = []
	for ctrls in _vb_editors:
		out.append({
			"name": ctrls["name"].text,
			"orientation": int(ctrls["orientation"].get_selected_id()),
			"cx": _fnum(ctrls["cx"].text, 0.0),
			"cy": _fnum(ctrls["cy"].text, 0.0),
			"width": _fnum(ctrls["width"].text, 100.0),
			"height": _fnum(ctrls["height"].text, 8.0),
			"show_mode": int(ctrls["show_mode"].get_selected_id()),
			"bind_var": ctrls["bind_var"].text.strip_edges(),
			"style": int(ctrls["style"].get_selected_id()),
			"active_color": ctrls["active_color"].text.strip_edges(),
			"consumed_color": ctrls["consumed_color"].text.strip_edges(),
			"segments": maxi(1, _inum(ctrls["segments"].text, 1)),
			"icon_active_path": ctrls["icon_active_path"].text.strip_edges(),
			"icon_consumed_path": ctrls["icon_consumed_path"].text.strip_edges(),
		})
	return out


func _clear_vb_editors() -> void:
	for c in _vb_editors:
		if c.has("root") and is_instance_valid(c["root"]):
			c["root"].queue_free()
	_vb_editors.clear()


# ============ 局部变量（批次 19 新增，结构与数值条同构）============

func _on_lv_preset_selected(idx: int) -> void:
	match idx:
		1: _selected_lv_preset = "ammo"
		2: _selected_lv_preset = "stamina"
		3: _selected_lv_preset = "energy"
		4: _selected_lv_preset = "hp"
		_: _selected_lv_preset = ""


func _on_add_lv_pressed() -> void:
	if _error_label != null and is_instance_valid(_error_label):
		_error_label.text = ""
	if _selected_lv_preset != "":
		_add_preset_lv(_selected_lv_preset)
		return
	_try_create_lv({
		"name": "", "min_value": 0.0, "max_value": 100.0,
		"current_value": 100.0, "recover_rate": 0.0, "recover_amount": 0.0,
	})


func _add_preset_lv(key: String) -> void:
	var d: Dictionary = LocalVar.preset_dict(key)
	if d.is_empty():
		return
	_try_create_lv(d)


func _try_create_lv(d: Dictionary) -> void:
	var nm: String = str(d.get("name", "")).strip_edges()
	if _has_lv_name_conflict(nm):
		_show_error("已存在同名局部变量：%s" % (nm if nm != "" else "（空名）"))
		return
	_make_lv_editor(d)
	if _lv_preset_select != null and is_instance_valid(_lv_preset_select):
		_lv_preset_select.select(0)
	_selected_lv_preset = ""


func _has_lv_name_conflict(name: String) -> bool:
	var nm := name.strip_edges()
	for c in _lv_editors:
		if c.has("name") and is_instance_valid(c["name"]):
			if c["name"].text.strip_edges() == nm:
				return true
	return false


func _make_lv_editor(data: Dictionary) -> void:
	var outer := PanelContainer.new()
	outer.mouse_filter = Control.MOUSE_FILTER_STOP
	# 液态玻璃小节框：半透明纯白轻纱 + 冰蓝描边
	var box := UIStyle.glass_box(Color(1.0, 1.0, 1.0, 0.09), UIStyle.BORDER, 4, 1)
	box.content_margin_left = 4
	box.content_margin_right = 4
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	outer.add_theme_stylebox_override("panel", box)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 3)
	outer.add_child(root)

	var ctrls := {}
	ctrls["root"] = outer

	ctrls["name"] = _tb_row(root, "变量名", str(data.get("name", "")), 90.0)

	# 需求指定的五个数值：最小值 / 最大值 / 现有值 / 恢复频率 / 回复量
	ctrls["min_value"] = _tb_num_row(root, "最小值", str(data.get("min_value", 0.0)))
	ctrls["max_value"] = _tb_num_row(root, "最大值", str(data.get("max_value", 100.0)))
	ctrls["current_value"] = _tb_num_row(root, "现有值", str(data.get("current_value", 100.0)))
	ctrls["recover_rate"] = _tb_num_row(root, "恢复频率(秒)", str(data.get("recover_rate", 0.0)))
	ctrls["recover_amount"] = _tb_num_row(root, "回复量", str(data.get("recover_amount", 0.0)))

	var del := _styled_button("删除此局部变量", "del_lv")
	del.custom_minimum_size = Vector2(0, 18.0)
	del.pressed.connect(_on_del_lv_pressed.bind(ctrls))
	root.add_child(del)

	_lv_list.add_child(outer)
	_lv_editors.append(ctrls)


## 「标签 + 数字输入框」一行（标签宽 90，与 _tb_row 同款观感；字段窄一些，五个字段并排更紧凑）。
func _tb_num_row(parent: Container, label_text: String, default_text: String) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var l := Label.new()
	l.text = label_text
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_font_size_override("font_size", FORM_FONT)
	l.custom_minimum_size = Vector2(90, ROW_H)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	var field := LineEdit.new()
	field.custom_minimum_size = Vector2(120.0, ROW_H)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.add_theme_font_size_override("font_size", FORM_FONT)
	field.text = default_text
	field.add_theme_color_override("font_color", Color.WHITE)
	field.add_theme_color_override("placeholder_color", Color(1, 1, 1, 0.5))
	field.mouse_filter = Control.MOUSE_FILTER_STOP
	field.caret_blink = true
	row.add_child(field)
	return field


func _on_del_lv_pressed(ctrls: Dictionary) -> void:
	var root = ctrls.get("root")
	if root != null and is_instance_valid(root):
		root.queue_free()
	var idx := _lv_editors.find(ctrls)
	if idx >= 0:
		_lv_editors.remove_at(idx)


func _collect_local_vars() -> Array:
	var out: Array = []
	for ctrls in _lv_editors:
		var mn := _fnum(ctrls["min_value"].text, 0.0)
		var mx := _fnum(ctrls["max_value"].text, 100.0)
		# 最小值不得大于最大值（用户在两个框里乱填也不该产出非法区间）
		if mn > mx:
			var t := mn
			mn = mx
			mx = t
		var cur := _fnum(ctrls["current_value"].text, mx)
		out.append({
			"name": ctrls["name"].text.strip_edges(),
			"min_value": mn,
			"max_value": mx,
			# 现有值夹到 [min,max]：与 LocalVar.set_current 的语义一致
			"current_value": clampf(cur, mn, mx),
			"recover_rate": _fnum(ctrls["recover_rate"].text, 0.0),
			"recover_amount": _fnum(ctrls["recover_amount"].text, 0.0),
		})
	return out


func _clear_lv_editors() -> void:
	for c in _lv_editors:
		if c.has("root") and is_instance_valid(c["root"]):
			c["root"].queue_free()
	_lv_editors.clear()


# ---- 数值助手 ----
func _fnum(s: String, default_val: float) -> float:
	var t := s.strip_edges()
	if t.is_empty() or not t.is_valid_float():
		return default_val
	return float(t)


func _inum(s: String, default_val: int) -> int:
	var t := s.strip_edges()
	if t.is_empty() or not t.is_valid_int():
		return default_val
	return int(t)


# ---- 打开 / 关闭 ----
func open(at_pos: Vector2, initial_dict: Dictionary, target_action: String, context: Dictionary = {}) -> void:
	_initial_dict = initial_dict.duplicate(true)
	_target_action = target_action
	_context = context
	# 填基础字段
	_width_input.text = str(float(_initial_dict.get("width", 120.0)))
	_height_input.text = str(float(_initial_dict.get("height", 120.0)))
	_display_layer_input.text = str(float(_initial_dict.get("display_layer", 0)))
	_collision_layer_input.text = _tags_to_str(Array(_initial_dict.get("collision_layer", [])))
	_border_width_input.text = str(float(_initial_dict.get("border_width", 3.0)))
	_border_color_input.text = str(_initial_dict.get("border_color", "#FFFFFFFF"))
	_fill_color_input.text = str(_initial_dict.get("fill_color", "#4090F0FF"))
	_tags_input.text = _tags_to_str(Array(_initial_dict.get("tags", [])))
	_rotation_input.text = str(float(_initial_dict.get("rotation_deg", 0.0)))
	_facing_input.text = str(int(_initial_dict.get("facing", 1)))
	_fill_path_input.text = str(_initial_dict.get("fill_path", ""))
	# 父子级（ID 绑定）
	_parent_id_input.text = str(int(_initial_dict.get("parent_id", 0)))
	_child_ids_input.text = _ids_to_str(Array(_initial_dict.get("child_ids", [])))
	# 积木ID：仅单块编辑(apply_to_block)时显示当前 ID 并可改；批量/新建类型不提供
	var blk = _context.get("block", null)
	if _target_action == "apply_to_block" and blk != null:
		_id_input.editable = true
		_id_input.text = str(int(blk.id))
		_id_input.placeholder_text = "积木ID(正整数)"
		_id_editable = true
	else:
		_id_input.editable = false
		_id_input.text = ""
		_id_input.placeholder_text = "（仅单块编辑可改）"
		_id_editable = false
	# 字符串ID：与数字ID同规则（仅单块编辑可改；空 = 清除该积木的字符串ID）
	# ★ 注意：必须同步 _string_id_editable 开关，否则 _collect_prop_dict() 里
	#   `if _string_id_editable:` 恒为 false → 输入的字符串 ID 被静默丢弃。
	_string_id_editable = _id_editable
	_string_id_input.editable = _id_editable
	_string_id_input.text = str(blk.string_id) if (_id_editable and blk != null) else _initial_dict.get("string_id", "")
	_string_id_input.placeholder_text = "字符串ID(可空,仅单块可改)" if not _id_editable else "字符串ID(可空)"
	_select_by_id(_fill_mode_select, int(_initial_dict.get("fill_mode", 0)))
	_select_by_id(_fill_anim_select, int(_initial_dict.get("fill_anim", 0)))
	# 文本框
	for c in _tb_editors:
		if c.has("root") and is_instance_valid(c["root"]):
			c["root"].queue_free()
	_tb_editors.clear()
	for tbd in _initial_dict.get("text_boxes", []):
		_make_tb_editor(tbd)
	# 预留文本框下拉复位到「空」：每次打开都从全空文本框开始
	if _preset_select != null and is_instance_valid(_preset_select):
		_preset_select.select(0)
	_selected_preset = ""
	# 基础攻击力（预留变量）
	_base_attack_input.text = str(float(_initial_dict.get("base_attack", 1.0)))
	# 运动参数（积木运动面板）：从初始 dict 读入，缺键用默认；刷新行内摘要
	_motion_data = {
		"can_fly": bool(_initial_dict.get("can_fly", false)),
		"horiz_max_speed": float(_initial_dict.get("horiz_max_speed", 240.0)),
		"horiz_accel": float(_initial_dict.get("horiz_accel", 0.0)),
		"fly_up_max_speed": float(_initial_dict.get("fly_up_max_speed", 240.0)),
		"fly_up_accel": float(_initial_dict.get("fly_up_accel", 0.0)),
	}
	_refresh_motion_summary()
	# 攻击判定框：与文本框同规则，从现有积木/类型读取并重建编辑器
	_clear_ab_editors()
	for abd in _initial_dict.get("attack_boxes", []):
		_make_ab_editor(abd)
	# 预留判定框下拉复位到「空」
	if _ab_preset_select != null and is_instance_valid(_ab_preset_select):
		_ab_preset_select.select(0)
	_selected_ab_preset = ""
	# 数值条：与文本框同规则，从现有积木/类型读取并重建编辑器
	_clear_vb_editors()
	for vbd in _initial_dict.get("value_bars", []):
		_make_vb_editor(vbd)
	# 预留数值条下拉复位到「空」
	if _vb_preset_select != null and is_instance_valid(_vb_preset_select):
		_vb_preset_select.select(0)
	_selected_vb_preset = ""
	# 局部变量：与数值条同规则读取并重建编辑器
	_clear_lv_editors()
	for lvd in _initial_dict.get("local_vars", []):
		_make_lv_editor(lvd)
	# 预留局部变量下拉复位到「空」
	if _lv_preset_select != null and is_instance_valid(_lv_preset_select):
		_lv_preset_select.select(0)
	_selected_lv_preset = ""
	# 名字框
	_name_input.text = str(context.get("existing_type_name", ""))
	# 保存位置：编辑已有类型（其 prop 含 save_location）时回填；新建类型默认 MOD（下拉已 select(0)）
	var sl := str(_initial_dict.get("save_location", "MOD"))
	var sl_idx := 0
	for i in _save_loc_select.item_count:
		if _save_loc_select.get_item_text(i) == sl:
			sl_idx = i
			break
	_save_loc_select.select(sl_idx)
	# ★ 类型名 / 保存位置 / 另存按钮：仅“新建积木类型 / 另存为新类型”模式显示；
	#   编辑已有积木(apply_to_block)时隐藏——类型名是“模板”概念，仅在生成 / 另存时参与，不占用单块属性页。
	var is_type_mode := _target_action == "spawn_new" or _target_action == "save_as_type"
	if _type_name_row != null:
		_type_name_row.visible = is_type_mode
	if _save_loc_row != null:
		_save_loc_row.visible = is_type_mode
	if _save_loc_hint_row != null:
		_save_loc_hint_row.visible = is_type_mode
	if _save_as_type_btn != null:
		_save_as_type_btn.visible = is_type_mode
	_error_label.text = ""
	# 等 UI 构建完成再显示；给个上限，避免个别帧出错导致 _built 永不置位时永久死等。
	var waited := 0
	while not _built and waited < 120:
		await get_tree().process_frame
		waited += 1
	if not _built:
		push_warning("[PropertyEditor] 面板构建未完成（超时），本次不做打开")
		return
	# 用户拖动过面板 → 保留拖动后的位置；否则居中
	if _has_user_pos:
		position = _user_pos
	else:
		position = _center_pos()
	# 按当前全局语言整树重译一次（面板可能是中文硬编码构建的）
	TranslationManager.retranslate_tree(self)
	# 需求 K：每次打开都把「?」说明框收起，避免上次留下的展开状态
	_hide_all_help_boxes()
	visible = true


func _center_pos() -> Vector2:
	var vp_size: Vector2 = UIStyle.canvas_viewport_size(self)
	var p := (vp_size - size) * 0.5
	p.x = clamp(p.x, 4.0, max(4.0, vp_size.x - size.x - 4.0))
	p.y = clamp(p.y, 4.0, max(4.0, vp_size.y - size.y - 4.0))
	return p


func close() -> void:
	# 先置隐藏、再做子窗收尾：即使子窗 close() 抛错也必须保证「关掉了」。
	visible = false
	# 释放焦点：若焦点仍停在某个输入框/长文本窗上，隐藏后会导致后续点击"像卡死"一样不起作用。
	get_viewport().gui_release_focus()
	_hide_all_help_boxes()   # 需求 K：收起「?」说明框
	if _long_text_panel != null and is_instance_valid(_long_text_panel):
		_long_text_panel.close()   # close() 内部会回填并 queue_free
		_long_text_panel = null
	if _tag_picker != null and is_instance_valid(_tag_picker):
		_tag_picker.close()
		_tag_picker = null
	if _color_panel != null and is_instance_valid(_color_panel):
		_color_panel.close()
		_color_panel = null
	if _motion_panel != null and is_instance_valid(_motion_panel):
		_motion_panel.close()   # close() 内部会回填 _motion_data 并 queue_free
		_motion_panel = null


func is_open() -> bool:
	return visible


# ---- 标题栏回调 ----
func _on_drag_ended() -> void:
	# 拖动结束：记住当前位置，下次打开时不再强制居中
	_user_pos = position
	_has_user_pos = true


func _on_close_btn_pressed(_id: String) -> void:
	close()


func _select_by_id(sel: OptionButton, id: int) -> void:
	for i in sel.item_count:
		if sel.get_item_id(i) == id:
			sel.select(i)
			return


func _tags_to_str(arr: Array) -> String:
	var parts: Array[String] = []
	for t in arr:
		parts.append(str(t))
	return ",".join(parts)


# ID 列表 → 逗号分隔文本（父子级用）
func _ids_to_str(arr: Array) -> String:
	var parts: Array[String] = []
	for v in arr:
		var n: int = int(v)
		if n > 0:
			parts.append(str(n))
	return ",".join(parts)


# 逗号分隔文本 → 去重 ID 列表（父子级用；非正整数一律丢弃）
func _ids_from_text(s: String) -> Array:
	var out: Array = []
	for part in s.split(","):
		var t := str(part).strip_edges()
		if t.is_empty() or not t.is_valid_int():
			continue
		var n: int = int(t)
		if n > 0 and not (n in out):
			out.append(n)
	return out


# 碰撞图层：逗号分隔文本 → 去重集合（与标签解析同构）
func _layers_from_text(s: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for part in s.split(","):
		var t := str(part).strip_edges()
		if not t.is_empty() and not (t in out):
			out.append(t)
	return out


# ---- 收集 prop dict（校验失败返回 {}）----
func _collect_prop_dict() -> Dictionary:
	var w: float = _fnum(_width_input.text, -1.0)
	var h: float = _fnum(_height_input.text, -1.0)
	if w < 1.0 or w > 4096.0:
		_show_error("宽必须在 1..4096 之间")
		return {}
	if h < 1.0 or h > 4096.0:
		_show_error("高必须在 1..4096 之间")
		return {}
	var bc: String = _border_color_input.text.strip_edges()
	if not bc.is_empty() and not BlockProperty.is_valid_hex_color(bc):
		_show_error("边框色必须是 #RRGGBB 或 #RRGGBBAA")
		return {}
	var fc: String = _fill_color_input.text.strip_edges()
	if not fc.is_empty() and not BlockProperty.is_valid_hex_color(fc):
		_show_error("填充色必须是 #RRGGBB 或 #RRGGBBAA")
		return {}

	# 朝向：仅接受 1(右) 或 -1(左)
	var facing_val: int = _inum(_facing_input.text, 0)
	if facing_val != 1 and facing_val != -1:
		_show_error("朝向必须是 1(右) 或 -1(左)")
		return {}

	var tags: Array[String] = []
	for part in _tags_input.text.split(","):
		var t := str(part).strip_edges()
		if not t.is_empty() and not (t in tags):
			tags.append(t)

	# 父子级（ID 绑定）：父级不能是自己；子级里去掉自己（成环在 Block 侧还会再兜一层）
	var pid: int = _inum(_parent_id_input.text, 0)
	if pid < 0:
		pid = 0
	var this_block = _context.get("block", null)
	var this_id: int = int(this_block.id) if this_block != null else 0
	if pid > 0 and this_id > 0 and pid == this_id:
		_show_error("父级不能是自己")
		return {}
	var cids: Array = _ids_from_text(_child_ids_input.text)
	if this_id > 0:
		cids.erase(this_id)

	# 积木ID（仅单块编辑可改；占用检查在应用前拦截）
	var new_id: int = 0
	if _id_editable:
		new_id = _inum(_id_input.text, 0)
		if new_id < 1:
			_show_error("积木ID必须为正整数")
			return {}
		var cur_block = _context.get("block", null)
		var occ = BlockManager.get_block(new_id)
		if occ != null and occ != cur_block:
			_show_error("积木ID %d 已被其它积木占用" % new_id)
			return {}

	# 字符串ID（仅单块编辑可改；空 = 清除；占用检查由 BlockManager 的 set_string_id 兜底，此处先预检）
	var sid: String = ""
	if _string_id_editable:
		sid = _string_id_input.text.strip_edges()
		if not sid.is_empty():
			var holder = BlockManager.get_block_by_string_id(sid)
			var cur_blk = _context.get("block", null)
			if holder != null and holder != cur_blk:
				_show_error("字符串ID '%s' 已被其它积木占用" % sid)
				return {}

	var out: Dictionary = {
		"width": w,
		"height": h,
		"display_layer": _fnum(_display_layer_input.text, 0.0),
		"collision_layer": _layers_from_text(_collision_layer_input.text),
		"border_width": _fnum(_border_width_input.text, 3.0),
		"border_color": bc,
		"fill_color": fc,
		"tags": PackedStringArray(tags),
		"fill_path": _fill_path_input.text.strip_edges(),
		"fill_mode": int(_fill_mode_select.get_selected_id()),
		"fill_anim": int(_fill_anim_select.get_selected_id()),
		"rotation_deg": _fnum(_rotation_input.text, 0.0),
		"facing": facing_val,
		"base_attack": _fnum(_base_attack_input.text, 1.0),
		"text_boxes": _collect_textboxes(),
		"attack_boxes": _collect_attack_boxes(),
		"value_bars": _collect_value_bars(),
		"local_vars": _collect_local_vars(),
		# 运动参数（来自「积木运动」面板）
		"can_fly": bool(_motion_data.get("can_fly", false)),
		"horiz_max_speed": float(_motion_data.get("horiz_max_speed", 240.0)),
		"horiz_accel": float(_motion_data.get("horiz_accel", 0.0)),
		"fly_up_max_speed": float(_motion_data.get("fly_up_max_speed", 240.0)),
		"fly_up_accel": float(_motion_data.get("fly_up_accel", 0.0)),
		"parent_id": pid,
		"child_ids": cids,
		"id": new_id,
		"save_location": _save_loc_select.get_item_text(_save_loc_select.selected),
	}
	if _string_id_editable:
		out["string_id"] = sid   # 空串 = 清除；仅单块编辑时提交，避免批量误清
	return out


func _show_error(msg: String) -> void:
	_error_label.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
	_error_label.text = msg
	print("[PropertyEditor] 错误: %s" % msg)


# ---- 按钮 ----
func _on_ok_pressed() -> void:
	var prop: Dictionary = _collect_prop_dict()
	if prop.is_empty():
		return
	if _target_action == "apply_to_block":
		# 批量上下文：context 传 {"blocks": [Block,...]} → payload 带上 blocks，逐个应用；
		# 单块上下文：{"block": Block} → payload 只带 block。由 desktop._on_editor_applied 分发。
		var blocks: Variant = _context.get("blocks", null)
		if blocks is Array and not blocks.is_empty():
			var valid: Array = []
			for bx in blocks:
				if is_instance_valid(bx) and bx is Block:
					valid.append(bx)
			if valid.is_empty():
				_show_error("内部错误: 批量上下文里没有有效积木")
				return
			applied.emit("apply_to_block", { "blocks": valid, "prop": prop })
			close()
			return
		var b = _context.get("block", null)
		if b == null:
			_show_error("内部错误: 缺少 block 上下文")
			return
		applied.emit("apply_to_block", { "block": b, "prop": prop })
		close()
		return
	elif _target_action == "spawn_new":
		var name_text: String = _name_input.text.strip_edges()
		if name_text.is_empty():
			_show_error("新建积木类型时,必须起名字")
			return
		var err: String = BlockProperty.validate_name(name_text)
		if not err.is_empty():
			_show_error(err)
			return
		applied.emit("spawn_new", { "type_name": name_text, "prop": prop })
		close()
		return
	elif _target_action == "save_as_type":
		var name_text: String = _name_input.text.strip_edges()
		if name_text.is_empty():
			_show_error("另存为新类型时,名字不能为空")
			return
		var err: String = BlockProperty.validate_name(name_text)
		if not err.is_empty():
			_show_error(err)
			return
		applied.emit("save_as_type", { "name": name_text, "prop": prop })
		close()
		return
	else:
		_show_error("未知 target_action: %s" % _target_action)
		return


func _on_save_as_type_pressed() -> void:
	var prop: Dictionary = _collect_prop_dict()
	if prop.is_empty():
		return
	var name_text: String = _name_input.text.strip_edges()
	if name_text.is_empty():
		_show_error("另存为新类型时,名字不能为空")
		return
	var err: String = BlockProperty.validate_name(name_text)
	if not err.is_empty():
		_show_error(err)
		return
	applied.emit("save_as_type", { "name": name_text, "prop": prop })
	close()


func _on_cancel_pressed() -> void:
	close()


func _on_copy_as_command_pressed() -> void:
	var prop: Dictionary = _collect_prop_dict()
	if prop.is_empty():
		return
	var blk = _context.get("block", null)
	var cmd: String = BlockProperty.prop_to_command(prop, blk)
	DisplayServer.clipboard_set(cmd)
	_error_label.add_theme_color_override("font_color", Color(0.55, 1.0, 0.55))
	_error_label.text = "已复制创建命令到剪贴板（可在控制台 / 粘贴回放）"
	print("[PropertyEditor] 已复制创建命令到剪贴板：\n" + cmd)


## 最小化 / 还原：折叠只隐藏内容，顶栏（标题 + 拖动把柄 + 最小化 + 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.apply(self, _min_btn, v, _min_btn.get_parent() if is_instance_valid(_min_btn) else null)
	# ★ 让玻璃盒子跟上 `self` 的尺寸：收窄时盒子=折叠尺寸（顶栏按钮因此保持原位），
	#   还原时 `self` 已恢复原尺寸 → 盒子也回到原尺寸。
	if is_instance_valid(_box):
		_box.size = size
		_box.position = Vector2.ZERO


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
