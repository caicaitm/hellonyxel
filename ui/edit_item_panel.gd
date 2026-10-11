# ui/edit_item_panel.gd
# 编辑物品面板（调试工具）
#
# 打开方式：调试模式(Debug.debug_mode)下右键背包内的物品 / 空物品栏。
#   · 右键物品    → 载入该物品数据（id = 该物品既有 id，不可改）。
#   · 右键空栏    → 全空白；保存时 id 取自定义名称（新建 / 存为模板）。
#
# 可编辑字段：
#   · 名称            —— 主名称（显示在背包里的名字）。
#   · 多语言名称      —— 下拉选语言 → 右侧输入框自动填入该语言的名字
#                        （无则显示占位符 "NONE_NAME"）；点「应用」把输入覆盖到「名称」栏。
#                        各语言名字写进模板 JSON 的 names 字段（**预留 UI**，当前背包不按语言切换显示）。
#   · 数量            —— 可编辑（保存到背包时生效；存为模板时不写入）。
#   · 文件大小(GB)    —— **仅当标签含「数字物品」时出现**；float，可精确到 0.01GB，
#                        写入 `attrs.capacity`。同时按标签决定落盘位置 `attrs.disk`：
#                        勾「需要高速存储」→ 只放固态；否则优先机械（机械装不下才固态）。
#   · 构建            —— **仅当标签含「数字物品」时出现**（两行：积木类型 / 修饰）。
#                        写入 `attrs.build = { type, mod }`。详见下面「拖放构建」段。
#   · 变量（键 = 值）  —— 自由增删改的 attrs 键值行。★ 这一区**原在标签选择（物品）页**，
#                        因那窗会被长出来的键值行撑爆而整体迁到这里（2026-10-05）。
#   · 硬件属性        —— **仅当标签含「设备硬件」时出现**：这里只显示属性摘要；
#                        硬件类型勾选框与「接口」在「调整标签」窗（标签选择（物品）页）里，
#                        其余 attrs 键改在下面「变量（键 = 值）」区。
#   · 标签            —— 逗号分隔；带「长文本」按钮（复用 UILongTextInputPanel）与
#                        「调整标签」按钮（TagPickerPanel 的**物品模式**，只列物品标签；
#                         与积木那套标签分开，标题末尾标（物品））。
#
# 拖放构建（InventoryPanel 拖出 → desktop.place_inventory_item）：
#   物品带「数字物品」标签 **且** `attrs.build.type` 非空 → 拖到桌面上生成该类型的积木，
#   并把 `attrs.build.mod`（属性覆盖串，`键=值` 用 `;` 分隔）套在类型定义之上；数量 -1。
#   ★★ 「构建」**只对数字物品生效**：非数字物品即便有 build 变量也不构建、数量也不减
#      （门禁唯一实现点是 Inventory.build_info()，本面板保存时也会把非数字物品的
#        build 键擦掉，两侧一致）。
#   · 贴图路径        —— LineEdit + 文件夹图标按钮（UIPathPicker，默认 res://textures/）。
#   · 描述            —— 与「名称」相同的实现：下拉选语言 → 输入框自动填入该语言描述
#                        （无则占位符 "NONE_NAME"）→ 点「应用」覆盖到「描述」栏；
#                        各语言描述写进模板 JSON 的 descriptions 字段（预留 UI）。
#
# 已移除：物品ID 输入框（id 由既有物品 id 或名称派生）、种类输入框（种类单纯由标签判断）。
#
# 动作：
#   · 保存为模板  → 写 res://items_types/<id>.json（**不含 count、不含 category**），发 template_saved。
#                   ★ 模板目录是 `items_types/`；原 `items/` 目录留给**实现玩法的脚本**
#                     （如 items/pc_hardware/pc_catalog.gd），两者不要再混放。
#   · 保存到背包  → 把当前字段（含 count / attrs）整条应用到 Inventory，发 applied。
#   · 取消 / ×    → 关闭，发 closed。
#
# 依赖（均为全局 class_name）：UIPanel / UIBtn / UIDragHandle / UIStyle /
#   UILongTextInputPanel / UIPathPicker / TranslationManager / Inventory。
extends Control
class_name EditItemPanel

signal closed
signal applied(item: Dictionary)        # 保存到背包：完整物品字典（含 count）
signal template_saved(id: String)       # 保存为模板：已写入的 id

const PADDING := 12.0
const LABEL_W := 96.0
const FIELD_W := 180.0
const ROW_H := 22.0
const BTN_H := 26.0
const LONG_BTN_W := 52.0
const TAG_ADJUST_BTN_W := 68.0
const APPLY_BTN_W := 52.0
const FORM_FONT := 13
const TITLE_FONT := 15
const TITLE_BAR_H := 28.0

const NONE_NAME := "NONE_NAME"

## 「保存为模板」的落盘目录。★ 只放**模板 JSON**；`items/` 留给玩法脚本。
const TEMPLATE_DIR := "res://items_types/"

var _bg: UIPanel
var _content: VBoxContainer
var _title: Label
var _drag_handle: UIDragHandle
var _close_btn: UIBtn

var _scroll: ScrollContainer
var _form: VBoxContainer

var _name_field: LineEdit
var _lang_select: OptionButton
var _lang_input: LineEdit
var _names_dict: Dictionary = {}   # lang_code -> String（多语言名称，预留）

var _count_field: LineEdit
var _tags_field: LineEdit
var _texture_field: LineEdit

# 「文件大小(GB)」行（数字物品专用，随标签显隐）
var _size_row: HBoxContainer = null
var _size_field: LineEdit = null
# 「构建」两行（数字物品专用，随标签显隐）：积木类型 + 修饰串
var _build_row: HBoxContainer = null
var _build_type_field: LineEdit = null
var _build_status: Label = null            # 类型名右侧「已注册 / 未注册」实时提示
var _build_mod_row: HBoxContainer = null
var _build_mod_field: LineEdit = null
# 「硬件属性」摘要行（设备硬件专用，随标签显隐）
var _hw_hint: Label = null

# 「变量（键 = 值，可自由增删改）」区（从标签选择（物品）页整体迁来）
var _attr_head: HBoxContainer = null
var _attr_list: VBoxContainer = null
var _attr_holders: Array = []               # Array[[key:String]]（改名时同步用）

# 编辑中的 attrs 副本：开面板时从物品载入，可被「文件大小」与标签选择窗的硬件属性区改写
var _editing_attrs: Dictionary = {}

var _desc_field: LineEdit
var _desc_lang_select: OptionButton
var _desc_lang_input: LineEdit
var _descs_dict: Dictionary = {}   # lang_code -> String（多语言描述，预留）

var _long_text_panel: UILongTextInputPanel = null
var _tag_picker: TagPickerPanel = null
var _msg_label: Label

var _editing_id: String = ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	visible = false


# ============================ 构建 UI ============================


# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build_ui() -> void:
	_bg = UIPanel.new()
	_bg.name = "Bg"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", int(PADDING))
	margin.add_theme_constant_override("margin_right", int(PADDING))
	margin.add_theme_constant_override("margin_top", int(PADDING))
	margin.add_theme_constant_override("margin_bottom", int(PADDING))
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 6)
	margin.add_child(_content)

	# 顶栏：标题 + 拖动把柄 + × 关闭
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	_title = _make_label("编辑物品", TITLE_FONT, Color.WHITE)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_title)
	_drag_handle = UIDragHandle.new()
	top.add_child(_drag_handle)
	_drag_handle.setup(self)
	_close_btn = _make_btn("×", "close")
	_close_btn.custom_minimum_size = Vector2(28, 28)
	_min_btn = UIMinimize.attach(top, func(): set_minimized(not _minimized))
	top.add_child(_close_btn)
	_content.add_child(top)

	# 滚动区 + 表单
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_content.add_child(_scroll)

	_form = VBoxContainer.new()
	_form.add_theme_constant_override("separation", 6)
	_scroll.add_child(_form)

	_add_name_section()                       # 名称 + 多语言名称（下拉）
	_count_field = _add_text_row("数量", "1", false)
	_tags_field = _add_tag_row()              # 标签（长文本 + 调整标签）
	_add_size_row()                           # 文件大小(GB)（仅「数字物品」时可见）
	_add_build_rows()                         # 构建：类型 + 修饰（仅「数字物品」时可见）
	_add_hw_hint()                            # 硬件属性摘要（仅「设备硬件」时可见）
	_add_attr_section()                       # 变量（键 = 值，可自由增删改）
	_texture_field = _add_folder_row("贴图路径", "", UIPathPicker.DIR_TEXTURES,
		{ "exts": UIPathPicker.IMG_EXTS, "label": "图片", "title": "选择贴图" })
	_add_desc_section()                       # 描述 + 多语言描述（下拉）
	# 标签栏改动 → 依赖行（文件大小 / 硬件属性）跟着显隐
	_tags_field.text_changed.connect(_on_tags_text_changed)

	# 底部：保存为模板 / 保存到背包 / 取消
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	var save_tpl := _make_btn("保存为模板", "save_template")
	save_tpl.custom_minimum_size = Vector2(0, BTN_H)
	save_tpl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(save_tpl)
	var save_bag := _make_btn("保存到背包", "apply")
	save_bag.custom_minimum_size = Vector2(0, BTN_H)
	save_bag.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(save_bag)
	var cancel := _make_btn("取消", "cancel")
	cancel.custom_minimum_size = Vector2(0, BTN_H)
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(cancel)
	_content.add_child(btn_row)

	_msg_label = Label.new()
	_msg_label.text = ""
	_msg_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7, 1.0))
	_msg_label.add_theme_font_size_override("font_size", 11)
	_msg_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fnt := UIStyle.get_cjk_font()
	if is_instance_valid(fnt):
		_msg_label.add_theme_font_override("font", fnt)
	_content.add_child(_msg_label)

	_content.reset_size()
	var cmin: Vector2 = _content.get_combined_minimum_size()
	var w: float = maxf(cmin.x + PADDING * 2.0, 380.0)
	var h: float = clampf(cmin.y + PADDING * 2.0, 360.0, 560.0)
	size = Vector2(w, h)
	custom_minimum_size = Vector2(w, h)


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", font_size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fnt := UIStyle.get_cjk_font()
	if is_instance_valid(fnt):
		l.add_theme_font_override("font", fnt)
	return l


func _make_btn(label: String, id: String) -> UIBtn:
	var b := UIBtn.new()
	b.set_label(label)
	b.set_id(id)
	b.pressed_id.connect(_on_btn_pressed)
	return b


# 小按钮（应用等），不连 _on_btn_pressed，由调用方单独连。
func _small_btn(label: String, id: String) -> UIBtn:
	var b := UIBtn.new()
	b.set_label(label)
	b.set_id(id)
	b.custom_minimum_size = Vector2(APPLY_BTN_W, ROW_H)
	b.size = Vector2(APPLY_BTN_W, ROW_H)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return b


func _add_text_row(label_text: String, default_text: String, with_long_text: bool = false) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_form.add_child(row)
	var lab := _make_label(label_text, FORM_FONT, Color.WHITE)
	lab.custom_minimum_size = Vector2(LABEL_W, ROW_H)
	row.add_child(lab)
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


# 名称段：主名称输入框 + 多语言下拉（选语言→填入该语言名→应用覆盖到名称）
func _add_name_section() -> void:
	_name_field = _add_text_row("名称", "", false)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_form.add_child(row)
	_lang_select = OptionButton.new()
	_lang_select.custom_minimum_size = Vector2(LABEL_W, ROW_H)
	_lang_select.size = Vector2(LABEL_W, ROW_H)
	_lang_select.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for lang in TranslationManager.LANG_CODES:
		_lang_select.add_item(TranslationManager.get_lang_name(lang))
	_lang_select.item_selected.connect(_on_lang_selected)
	row.add_child(_lang_select)
	_lang_input = LineEdit.new()
	_lang_input.custom_minimum_size = Vector2(FIELD_W, ROW_H)
	_lang_input.add_theme_font_size_override("font_size", FORM_FONT)
	_lang_input.add_theme_color_override("font_color", Color.WHITE)
	_lang_input.add_theme_color_override("placeholder_color", Color(1, 1, 1, 0.5))
	_lang_input.mouse_filter = Control.MOUSE_FILTER_STOP
	_lang_input.caret_blink = true
	_lang_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lang_input.placeholder_text = NONE_NAME
	row.add_child(_lang_input)
	var apply_btn := _small_btn("应用", "lang_apply")
	apply_btn.pressed_id.connect(_on_lang_apply_pressed)
	row.add_child(apply_btn)


# 描述段：与名称相同实现（下拉选语言→填入该语言描述→应用覆盖到描述）
func _add_desc_section() -> void:
	_desc_field = _add_text_row("描述", "", true)   # true → 附带「长文本」按钮
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_form.add_child(row)
	_desc_lang_select = OptionButton.new()
	_desc_lang_select.custom_minimum_size = Vector2(LABEL_W, ROW_H)
	_desc_lang_select.size = Vector2(LABEL_W, ROW_H)
	_desc_lang_select.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for lang in TranslationManager.LANG_CODES:
		_desc_lang_select.add_item(TranslationManager.get_lang_name(lang))
	_desc_lang_select.item_selected.connect(_on_desc_lang_selected)
	row.add_child(_desc_lang_select)
	_desc_lang_input = LineEdit.new()
	_desc_lang_input.custom_minimum_size = Vector2(FIELD_W, ROW_H)
	_desc_lang_input.add_theme_font_size_override("font_size", FORM_FONT)
	_desc_lang_input.add_theme_color_override("font_color", Color.WHITE)
	_desc_lang_input.add_theme_color_override("placeholder_color", Color(1, 1, 1, 0.5))
	_desc_lang_input.mouse_filter = Control.MOUSE_FILTER_STOP
	_desc_lang_input.caret_blink = true
	_desc_lang_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_desc_lang_input.placeholder_text = NONE_NAME
	row.add_child(_desc_lang_input)
	var apply_btn := _small_btn("应用", "desc_apply")
	apply_btn.pressed_id.connect(_on_desc_lang_apply_pressed)
	row.add_child(apply_btn)


func _add_tag_row() -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_form.add_child(row)
	var lab := _make_label("标签(逗号分隔)", FORM_FONT, Color.WHITE)
	lab.custom_minimum_size = Vector2(LABEL_W, ROW_H)
	row.add_child(lab)
	var field := LineEdit.new()
	field.custom_minimum_size = Vector2(FIELD_W, ROW_H)
	field.add_theme_font_size_override("font_size", FORM_FONT)
	field.text = ""
	field.add_theme_color_override("font_color", Color.WHITE)
	field.add_theme_color_override("placeholder_color", Color(1, 1, 1, 0.5))
	field.mouse_filter = Control.MOUSE_FILTER_STOP
	field.caret_blink = true
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	row.add_child(_long_text_btn(field))
	row.add_child(_tag_adjust_btn(field))
	return field


## 「文件大小(GB)」行 —— 数字物品专用（非数字物品时整行隐藏）。
## 值写入 `attrs.capacity`，精度 0.01GB。
func _add_size_row() -> void:
	_size_row = HBoxContainer.new()
	_size_row.add_theme_constant_override("separation", 6)
	_form.add_child(_size_row)
	var lab := _make_label("文件大小(GB)", FORM_FONT, Color.WHITE)
	lab.custom_minimum_size = Vector2(LABEL_W, ROW_H)
	_size_row.add_child(lab)
	_size_field = LineEdit.new()
	_size_field.custom_minimum_size = Vector2(FIELD_W, ROW_H)
	_size_field.add_theme_font_size_override("font_size", FORM_FONT)
	_size_field.text = "0.00"
	_size_field.add_theme_color_override("font_color", Color.WHITE)
	_size_field.add_theme_color_override("placeholder_color", Color(1, 1, 1, 0.5))
	_size_field.mouse_filter = Control.MOUSE_FILTER_STOP
	_size_field.caret_blink = true
	_size_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_size_row.add_child(_size_field)
	# ★ 提示必须**短**：本行是「标签」行之下新增的一行，行最小宽度会参与整个表单的
	#   最小宽度计算；写长了会把表单撑宽 → 同一列里「标签」行的「调整标签」按钮被挤出面板
	#   （实测 552 > 面板 422）。详细说明挂在 tooltip 上。
	var tip := _make_label("0.01GB 精度", FORM_FONT - 2, Color(0.62, 0.72, 0.88))
	tip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tip.mouse_filter = Control.MOUSE_FILTER_PASS
	tip.tooltip_text = "文件大小单位 GB，可精确到 0.01GB。勾「需要高速存储」→ 只算固态硬盘；"
	tip.tooltip_text += "不勾 → 优先放机械硬盘，机械装满才放固态。"
	_size_row.add_child(tip)
	_size_row.tooltip_text = tip.tooltip_text
	_size_row.visible = false


## 「构建」两行 —— 数字物品专用（非数字物品整行隐藏；拖放端 build_info 同样按此门禁）。
##   类型：积木类型名（自由输入，右侧实时提示「已注册 / 未注册」）
##   修饰：属性覆盖串，`键=值` 多个用 `;` 分隔（白名单见 Inventory.BUILD_MOD_KEYS）
## 值写进 `attrs.build = { type, mod }`（类型留空 → 删键）。
## ★ 行最小宽度必须 ≤ 「标签」行（96+180+52+68=396）—— 否则会把「调整标签」按钮挤出面板。
func _add_build_rows() -> void:
	_build_row = HBoxContainer.new()
	_build_row.add_theme_constant_override("separation", 6)
	_form.add_child(_build_row)
	var lab := _make_label("构建", FORM_FONT, Color.WHITE)
	lab.custom_minimum_size = Vector2(LABEL_W, ROW_H)
	lab.tooltip_text = "拖到桌面时生成的积木类型（留空 = 不构建）"
	_build_row.add_child(lab)
	_build_type_field = LineEdit.new()
	_build_type_field.custom_minimum_size = Vector2(FIELD_W, ROW_H)
	_build_type_field.add_theme_font_size_override("font_size", FORM_FONT)
	_build_type_field.add_theme_color_override("font_color", Color.WHITE)
	_build_type_field.add_theme_color_override("placeholder_color", Color(1, 1, 1, 0.5))
	_build_type_field.mouse_filter = Control.MOUSE_FILTER_STOP
	_build_type_field.caret_blink = true
	_build_type_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build_type_field.placeholder_text = "积木类型名"
	_build_row.add_child(_build_type_field)
	_build_status = _make_label("", FORM_FONT - 2, Color(0.62, 0.72, 0.88))
	_build_status.custom_minimum_size = Vector2(48.0, ROW_H)
	_build_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_build_row.add_child(_build_status)
	_build_row.visible = false

	_build_mod_row = HBoxContainer.new()
	_build_mod_row.add_theme_constant_override("separation", 6)
	_form.add_child(_build_mod_row)
	var lab2 := _make_label("构建修饰", FORM_FONT, Color.WHITE)
	lab2.custom_minimum_size = Vector2(LABEL_W, ROW_H)
	_build_mod_row.add_child(lab2)
	_build_mod_field = LineEdit.new()
	_build_mod_field.custom_minimum_size = Vector2(FIELD_W, ROW_H)
	_build_mod_field.add_theme_font_size_override("font_size", FORM_FONT)
	_build_mod_field.add_theme_color_override("font_color", Color.WHITE)
	_build_mod_field.add_theme_color_override("placeholder_color", Color(1, 1, 1, 0.5))
	_build_mod_field.mouse_filter = Control.MOUSE_FILTER_STOP
	_build_mod_field.caret_blink = true
	_build_mod_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build_mod_field.placeholder_text = "width=200;fill_color=#FF0000"
	_build_mod_row.add_child(_build_mod_field)
	var tip := _make_label("属性覆盖", FORM_FONT - 2, Color(0.62, 0.72, 0.88))
	tip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tip.mouse_filter = Control.MOUSE_FILTER_PASS
	tip.tooltip_text = "修饰用「键=值」写，多个用 ; 分隔（例：width=200;fill_color=#FF0000;tags=fill,border）。\n"
	tip.tooltip_text += "允许的键：" + ",".join(Inventory.BUILD_MOD_KEYS)
	_build_mod_row.add_child(tip)
	_build_mod_row.tooltip_text = tip.tooltip_text
	_build_mod_row.visible = false
	# 逐键同步进 attrs 副本（保证「调整标签」窗回写时不会把 build 冲掉）
	_build_type_field.text_changed.connect(_on_build_changed)
	_build_mod_field.text_changed.connect(_on_build_changed)


## 「变量（键 = 值，可自由增删改）」区 —— 从标签选择（物品）页整体迁来。
## ★ 面板自有行负责写入的键（capacity / disk / build）不在这里显示，避免两处打架：
##   它们分别由上方的「文件大小」与「构建」行说了算（见 _managed_attr_keys）。
func _add_attr_section() -> void:
	_attr_head = HBoxContainer.new()
	_attr_head.add_theme_constant_override("separation", 8)
	_form.add_child(_attr_head)
	var lab := _make_label("变量（键 = 值）", FORM_FONT, Color(0.78, 0.88, 1.0))
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lab.tooltip_text = ("物品 attrs 的自由键值；直接在行内改，× 删除整行。" +
		"（capacity / disk / build 三个键由上面各自的行管理，不在这里显示）")
	_attr_head.add_child(lab)
	var add_btn := _make_btn("+ 添加变量", "add_attr")
	add_btn.custom_minimum_size = Vector2(104.0, ROW_H)
	_attr_head.add_child(add_btn)
	_attr_list = VBoxContainer.new()
	_attr_list.add_theme_constant_override("separation", 4)
	_attr_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_form.add_child(_attr_list)


## 「硬件属性」摘要行 —— 设备硬件专用（非设备硬件时隐藏）。
## 硬件类型勾选与「接口」在「调整标签」打开的标签选择（物品）页里；
## 其余 attrs 键在本面板下方的「变量（键 = 值）」区改。
func _add_hw_hint() -> void:
	_hw_hint = _make_label("", FORM_FONT - 2, Color(0.70, 0.86, 1.0))
	_hw_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hw_hint.tooltip_text = ("硬件类型勾选框与「接口」在「调整标签」窗里改；" +
		"其余属性键可在下方「变量（键 = 值）」区增删改。")
	_form.add_child(_hw_hint)
	_hw_hint.visible = false


func _add_folder_row(label_text: String, default_text: String, default_dir: String, opts: Dictionary) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_form.add_child(row)
	var lab := _make_label(label_text, FORM_FONT, Color.WHITE)
	lab.custom_minimum_size = Vector2(LABEL_W, ROW_H)
	row.add_child(lab)
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
	UIPathPicker.attach(field, default_dir, opts)
	return field


func _long_text_btn(source: LineEdit) -> UIBtn:
	var b := UIBtn.new()
	b.set_id("long_text")
	b.set_label("长文本")
	b.custom_minimum_size = Vector2(LONG_BTN_W, ROW_H)
	b.size = Vector2(LONG_BTN_W, ROW_H)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.pressed_id.connect(_on_long_text_pressed.bind(source))
	return b


func _tag_adjust_btn(source: LineEdit) -> UIBtn:
	var b := UIBtn.new()
	b.set_id("adjust_tags")
	b.set_label("调整标签")
	b.custom_minimum_size = Vector2(TAG_ADJUST_BTN_W, ROW_H)
	b.size = Vector2(TAG_ADJUST_BTN_W, ROW_H)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.pressed_id.connect(_on_adjust_tags_pressed.bind(source))
	return b


# ============================ 公开方法 ============================

func open(item: Dictionary, item_id: String) -> void:
	_editing_id = item_id
	_name_field.text = str(item.get("name", ""))

	_names_dict = item.get("names", {})
	if not (_names_dict is Dictionary):
		_names_dict = {}
	if _lang_select != null and is_instance_valid(_lang_select):
		_lang_select.selected = 0
		_on_lang_selected(0)

	_count_field.text = str(int(item.get("count", 1)))

	var tags = item.get("tags", [])
	if tags is Array:
		var parts: PackedStringArray = PackedStringArray()
		for t in tags:
			parts.append(str(t))
		_tags_field.text = ",".join(parts)
	else:
		_tags_field.text = ""

	# attrs 副本：文件大小 / 硬件属性的编辑都落在这里，保存时整份写回
	var attrs = item.get("attrs", {})
	_editing_attrs = (attrs as Dictionary).duplicate(true) if (attrs is Dictionary) else {}
	if _size_field != null and is_instance_valid(_size_field):
		_size_field.text = "%.2f" % Inventory.size_gb_of_attrs(_editing_attrs)
	# 「构建」两行 + 「变量」行都从 _editing_attrs 回填（字段是复用的，必须每次重置，
	# 否则上一个物品填过的构建类型会留在框里，看起来像这个物品也有构建）
	_refresh_build_fields()
	_rebuild_attr_rows()

	_texture_field.text = str(item.get("texture_path", ""))

	_desc_field.text = str(item.get("description", ""))
	_descs_dict = item.get("descriptions", {})
	if not (_descs_dict is Dictionary):
		_descs_dict = {}
	if _desc_lang_select != null and is_instance_valid(_desc_lang_select):
		_desc_lang_select.selected = 0
		_on_desc_lang_selected(0)

	_set_msg("", false)
	_refresh_dynamic_rows()
	visible = true
	move_to_front()
	_center()


func _center() -> void:
	var vp: Vector2 = UIStyle.canvas_viewport_size(self)
	position = (vp - size) / 2.0


# ============================ 按钮 ============================

func _on_btn_pressed(id: String) -> void:
	match id:
		"close", "cancel":
			closed.emit()
		"save_template":
			_on_save_template_pressed()
		"apply":
			_on_apply_pressed()
		"add_attr":
			_add_attr_row("", "")


func _on_save_template_pressed() -> void:
	var data := _collect_common(false)
	var id := str(data.get("id", ""))
	if id == "":
		_set_msg("名称不能为空，无法保存模板（新建物品时 ID 取自定义名称）", true)
		return
	var res_path := "%s%s.json" % [TEMPLATE_DIR, id]
	var abs_path: String = ProjectSettings.globalize_path(res_path)
	var dir_abs: String = ProjectSettings.globalize_path(TEMPLATE_DIR)
	if not DirAccess.dir_exists_absolute(dir_abs):
		DirAccess.make_dir_recursive_absolute(dir_abs)
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		_set_msg("保存失败：无法写入 %s" % res_path, true)
		push_error("[EditItemPanel] 模板写入失败: %s" % res_path)
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	_set_msg("已保存模板：%s（不含数量/种类）" % res_path, false)
	print("[EditItemPanel] 模板已保存: %s" % res_path)
	template_saved.emit(id)


func _on_apply_pressed() -> void:
	var data := _collect_common(true)
	var id := str(data.get("id", ""))
	if id == "":
		_set_msg("名称不能为空，无法保存到背包（新建物品时 ID 取自定义名称）", true)
		return
	applied.emit(data)
	_set_msg("已应用到背包：%s" % id, false)
	print("[EditItemPanel] 已应用到背包: %s" % id)


# ============================ 依赖标签的显隐行 ============================

func _on_tags_text_changed(_t: String) -> void:
	_refresh_dynamic_rows()


## 按当前「标签」栏内容切换依赖行：
##   · 数字物品 → 显示「文件大小(GB)」+「构建」两行
##   · 设备硬件 → 显示硬件属性摘要
## ★ 这里**不重建**「变量」行（那会打断正在输入的行）；变量区由
##   open() / _on_hw_attrs_changed() / _on_tag_picker_closed() 各自显式刷新。
func _refresh_dynamic_rows() -> void:
	if _tags_field == null or not is_instance_valid(_tags_field):
		return
	var tags := _tag_list()
	var is_digital: bool = tags.has(Inventory.TAG_DIGITAL)
	if _size_row != null and is_instance_valid(_size_row):
		_size_row.visible = is_digital
	# ★★ 「构建」只对数字物品生效 → 非数字物品连行都不给（与拖放端 build_info 的门禁一致）
	if _build_row != null and is_instance_valid(_build_row):
		_build_row.visible = is_digital
	if _build_mod_row != null and is_instance_valid(_build_mod_row):
		_build_mod_row.visible = is_digital
	if _hw_hint != null and is_instance_valid(_hw_hint):
		var is_hw: bool = tags.has(Inventory.TAG_PC_HARDWARE)
		_hw_hint.visible = is_hw
		if is_hw:
			_hw_hint.text = _hw_attrs_text()


# ============================ 构建（拖放生成积木）============================

## 「构建」两行 → 同步进 attrs 工作副本（类型留空 → 删键）。
## 逐键调用：保证「调整标签」窗把整份 attrs 回写时不会把 build 冲回旧值。
func _sync_build_attr() -> void:
	var ty := _build_type_text()
	if ty.is_empty():
		_editing_attrs.erase(Inventory.BUILD_KEY)
		return
	var bd: Dictionary = {}
	bd[Inventory.MOD_BUILD_TYPE] = ty
	bd[Inventory.MOD_BUILD_MOD] = _build_mod_text()
	_editing_attrs[Inventory.BUILD_KEY] = bd


func _on_build_changed(_t: String) -> void:
	_sync_build_attr()
	_refresh_build_status()


## 类型名右侧「已注册 / 未注册」实时提示（决定拖到桌面时能否真的生成积木）
func _refresh_build_status() -> void:
	if _build_status == null or not is_instance_valid(_build_status):
		return
	var ty := _build_type_text()
	if ty.is_empty():
		_build_status.text = ""
		return
	if BlockTypes.has(ty):
		_build_status.text = "已注册"
		_build_status.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7, 1.0))
	else:
		_build_status.text = "未注册"
		_build_status.add_theme_color_override("font_color", Color(1.0, 0.62, 0.55, 1.0))


## 把 attrs.build 回填到两行（打开面板 / 标签选择窗回写后调用）。
## ★ 非数字物品：「构建」不生效 → 两行一律留空（既不让隐藏的框里残留上一件物品的值，
##   也不让「现实物品带了 build 变量」看起来像有效配置；保存时该键本来就会被擦掉）。
func _refresh_build_fields() -> void:
	if _build_type_field == null or not is_instance_valid(_build_type_field):
		return
	var bv: Dictionary = {}
	if _tag_list().has(Inventory.TAG_DIGITAL):
		bv = Inventory.build_var_of_attrs(_editing_attrs)
	_build_type_field.text = str(bv.get(Inventory.MOD_BUILD_TYPE, ""))
	if _build_mod_field != null and is_instance_valid(_build_mod_field):
		_build_mod_field.text = str(bv.get(Inventory.MOD_BUILD_MOD, ""))
	_refresh_build_status()


func _build_type_text() -> String:
	if _build_type_field == null or not is_instance_valid(_build_type_field):
		return ""
	return _build_type_field.text.strip_edges()


func _build_mod_text() -> String:
	if _build_mod_field == null or not is_instance_valid(_build_mod_field):
		return ""
	return _build_mod_field.text.strip_edges()


# ============================ 变量（键 = 值）============================

## 面板自有行负责写入的 attrs 键 —— 不在自由键值区显示 / 不允许在这里改名占用
func _managed_attr_keys() -> Array:
	return ["capacity", "disk", Inventory.BUILD_KEY]


## 按 _editing_attrs 重建自由键值行（跳过专属键；键按字典序）
func _rebuild_attr_rows() -> void:
	if _attr_list == null or not is_instance_valid(_attr_list):
		return
	for c in _attr_list.get_children():
		_attr_list.remove_child(c)
		c.queue_free()
	_attr_holders.clear()
	var skip: Array = _managed_attr_keys()
	var keys: Array = []
	for k in _editing_attrs.keys():
		var ks := str(k)
		if skip.has(ks):
			continue
		keys.append(ks)
	keys.sort()
	for k in keys:
		_add_attr_row(str(k), Inventory.fmt_attr_value(_editing_attrs[k]))


## 追加一行「键 = 值」；key 为空表示新行（等用户填键名）
func _add_attr_row(key: String, value: String) -> void:
	if _attr_list == null or not is_instance_valid(_attr_list):
		return
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var ke := LineEdit.new()
	ke.text = key
	ke.placeholder_text = "键名"
	ke.custom_minimum_size = Vector2(120.0, ROW_H)
	ke.add_theme_font_size_override("font_size", FORM_FONT)
	ke.add_theme_color_override("font_color", Color.WHITE)
	ke.add_theme_color_override("placeholder_color", Color(1, 1, 1, 0.5))
	ke.mouse_filter = Control.MOUSE_FILTER_STOP
	ke.caret_blink = true
	row.add_child(ke)
	var ve := LineEdit.new()
	ve.text = value
	ve.placeholder_text = "值"
	ve.custom_minimum_size = Vector2(120.0, ROW_H)
	ve.add_theme_font_size_override("font_size", FORM_FONT)
	ve.add_theme_color_override("font_color", Color.WHITE)
	ve.add_theme_color_override("placeholder_color", Color(1, 1, 1, 0.5))
	ve.mouse_filter = Control.MOUSE_FILTER_STOP
	ve.caret_blink = true
	ve.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ve)
	var rm := _make_btn("×", "rm_attr")
	rm.custom_minimum_size = Vector2(24.0, ROW_H)
	row.add_child(rm)
	_attr_list.add_child(row)

	var holder: Array = [key]        # [key]，供两个回调共享（改名时同步）
	_attr_holders.append(holder)
	ke.text_changed.connect(func(txt: String): _on_attr_key_changed(txt, holder, ke, ve))
	ve.text_changed.connect(func(txt: String): _on_attr_value_changed(txt, holder))
	rm.pressed_id.connect(func(_id): _remove_attr_row(holder))
	# 已有键名的行（从 _editing_attrs 展开而来）→ 立刻把初值写回工作副本，保证「保存」时值不丢
	if key != "":
		_editing_attrs[key] = Inventory.parse_attr_value(value)


func _on_attr_key_changed(new_key: String, holder: Array, ke: LineEdit, ve: LineEdit) -> void:
	var old := str(holder[0])
	var nk := new_key.strip_edges()
	# 专属键（capacity / disk / build）不许在这里占用 —— 直接弹回原键名
	if nk != "" and _managed_attr_keys().has(nk):
		_set_msg("「%s」由上方对应栏位管理，这里改不了" % nk, true)
		if ke != null and is_instance_valid(ke):
			ke.text = old
			ke.caret_column = old.length()
		return
	if old != "" and old != nk:
		_editing_attrs.erase(old)
	holder[0] = nk
	if nk != "":
		_editing_attrs[nk] = Inventory.parse_attr_value(ve.text if is_instance_valid(ve) else "")


func _on_attr_value_changed(txt: String, holder: Array) -> void:
	var k := str(holder[0])
	if k != "":
		_editing_attrs[k] = Inventory.parse_attr_value(txt)


func _remove_attr_row(holder: Array) -> void:
	var k := str(holder[0])
	if k != "":
		_editing_attrs.erase(k)
	_rebuild_attr_rows()


## 「标签」栏当前标签集（去重、去空）
func _tag_list() -> Array:
	var out: Array = []
	if _tags_field == null or not is_instance_valid(_tags_field):
		return out
	for part in _tags_field.text.split(","):
		var t := str(part).strip_edges()
		if t != "" and not out.has(t):
			out.append(t)
	return out


## 「文件大小」栏 → float（GB，0.01 精度）
func _read_size_gb() -> float:
	if _size_field == null or not is_instance_valid(_size_field):
		return 0.0
	var raw := _size_field.text.strip_edges()
	if not raw.is_valid_float():
		return 0.0
	return maxf(0.0, snappedf(raw.to_float(), 0.01))


## 硬件属性摘要（键按字典序，数组/字典用 JSON 展示）。
## ★ 跳过 build（它是本面板「构建」两行的事，而且是个嵌套字典，摊开只会淹没摘要）。
func _hw_attrs_text() -> String:
	var keys: Array = []
	for k in _editing_attrs.keys():
		if str(k) == Inventory.BUILD_KEY:
			continue
		keys.append(str(k))
	if keys.is_empty():
		return TranslationManager.t("硬件属性：（空）—— 点「调整标签」在标签选择（物品）页里填写")
	keys.sort()
	var parts: PackedStringArray = []
	for k in keys:
		var v = _editing_attrs[k]
		var s: String = JSON.stringify(v) if (v is Dictionary or v is Array) else str(v)
		parts.append("%s=%s" % [k, s])
	return TranslationManager.t("硬件属性（接口在标签窗改）") + "：" + "  ".join(parts)


## 标签选择（物品）页里改完硬件属性（硬件类型 / 接口）→ 回写到本面板的 attrs 副本。
## ★ 该窗不再管自由键值，但它把**整份 attrs** 回写 → 必须把「构建 / 变量」两处 UI 重新对齐，
##   否则用户刚填的行会在这里被旧副本覆盖掉。
func _on_hw_attrs_changed(attrs: Dictionary) -> void:
	_editing_attrs = attrs.duplicate(true)
	_sync_build_attr()          # 以面板当前两行的内容为准（窗里改不到 build）
	if _hw_hint != null and is_instance_valid(_hw_hint):
		_hw_hint.text = _hw_attrs_text()
	_rebuild_attr_rows()
	_set_msg("硬件属性已更新（点「保存到背包」写入）", false)


# ============================ 多语言名称 ============================

func _on_lang_selected(index: int) -> void:
	var lang := _lang_at(index)
	var nm := str(_names_dict.get(lang, ""))
	if nm != "":
		_lang_input.text = nm
		_lang_input.placeholder_text = ""
	else:
		_lang_input.text = ""
		_lang_input.placeholder_text = NONE_NAME


func _on_lang_apply_pressed(_id: String) -> void:
	var lang := _current_lang()
	var txt := _lang_input.text.strip_edges()
	if txt == "":
		_set_msg("请先在输入框填写 %s 的名称再应用" % TranslationManager.get_lang_name(lang), false)
		return
	_name_field.text = txt
	_names_dict[lang] = txt
	_set_msg("已应用 %s 名称到「名称」栏" % TranslationManager.get_lang_name(lang), false)


func _current_lang() -> String:
	var idx := 0
	if _lang_select != null and is_instance_valid(_lang_select):
		idx = _lang_select.selected
	return _lang_at(idx)


# ============================ 多语言描述 ============================

func _on_desc_lang_selected(index: int) -> void:
	var lang := _lang_at(index)
	var ds := str(_descs_dict.get(lang, ""))
	if ds != "":
		_desc_lang_input.text = ds
		_desc_lang_input.placeholder_text = ""
	else:
		_desc_lang_input.text = ""
		_desc_lang_input.placeholder_text = NONE_NAME


func _on_desc_lang_apply_pressed(_id: String) -> void:
	var lang := _current_desc_lang()
	var txt := _desc_lang_input.text.strip_edges()
	if txt == "":
		_set_msg("请先在输入框填写 %s 的描述再应用" % TranslationManager.get_lang_name(lang), false)
		return
	_desc_field.text = txt
	_descs_dict[lang] = txt
	_set_msg("已应用 %s 描述到「描述」栏" % TranslationManager.get_lang_name(lang), false)


func _current_desc_lang() -> String:
	var idx := 0
	if _desc_lang_select != null and is_instance_valid(_desc_lang_select):
		idx = _desc_lang_select.selected
	return _lang_at(idx)


func _lang_at(index: int) -> String:
	var codes: Array = TranslationManager.LANG_CODES
	var i := clampi(index, 0, codes.size() - 1)
	return str(codes[i])


# ============================ 长文本 / 标签 ============================

func _on_long_text_pressed(_id: String, source: LineEdit) -> void:
	if source == null or not is_instance_valid(source):
		return
	if _long_text_panel != null and is_instance_valid(_long_text_panel):
		_long_text_panel.close()
	var layer := _ui_layer()
	if layer == null:
		push_warning("[EditItemPanel] 未找到 CanvasLayer，长文本窗无法显示")
		return
	_long_text_panel = UILongTextInputPanel.new()
	layer.add_child(_long_text_panel)
	_long_text_panel.closed.connect(_on_long_text_closed)
	_long_text_panel.open(source, source.text)


func _on_long_text_closed() -> void:
	_long_text_panel = null


# 「调整标签」按钮：打开标签选择窗（复用积木属性面板同款 TagPickerPanel）。
# 勾选框清单来自 BlockTags.ALL（含 digital_item / real_item / in_recycle_bin /
# undeletable / deleted 等背包标签）∪ 当前输入框里的自定义标签；确定后回填到源输入框。
func _on_adjust_tags_pressed(_id: String, source: LineEdit) -> void:
	if source == null or not is_instance_valid(source):
		return
	if _tag_picker != null and is_instance_valid(_tag_picker):
		_tag_picker.close()
		_tag_picker = null
	var layer := _ui_layer()
	if layer == null:
		_set_msg("未找到 CanvasLayer，无法打开标签选择窗", true)
		push_warning("[EditItemPanel] 未找到 CanvasLayer，标签选择窗无法显示")
		return
	_tag_picker = TagPickerPanel.new()
	layer.add_child(_tag_picker)
	_tag_picker.closed.connect(_on_tag_picker_closed)
	# ★ 物品模式：只列物品自己的标签（数字物品/现实物品/在回收站中/不可删除/已删除/设备硬件/需要高速存储），
	#   与积木那套标签分开，标题末尾标（物品）。
	#   ★ 一并把 attrs 交给它：勾了「设备硬件」时，它会在页内长出硬件类型勾选框 +
	#     接口 / 属性输入框（变量完全开放修改），确定时原样回写。
	_tag_picker.open(source, TagPickerPanel.Mode.ITEM, _editing_attrs, _on_hw_attrs_changed)
	_set_msg("标签选择窗已打开：勾选后点「确定」回填到「标签」框", false)


func _on_tag_picker_closed() -> void:
	_tag_picker = null
	# ★ 标签窗是**直接写**源输入框的（LineEdit.text 赋值不会发 text_changed）→
	#   必须在这里主动重算一次依赖行的显隐，否则勾掉「数字物品」后「文件大小」还挂着。
	_refresh_dynamic_rows()
	# 取消关闭时不会走 _on_hw_attrs_changed → 这里也对齐一次（幂等，只是把 UI 拉回副本真值）
	_refresh_build_fields()
	_rebuild_attr_rows()


# 向上查找 CanvasLayer：长文本窗必须挂在 CanvasLayer 下，position 才以视口为原点。
func _ui_layer() -> CanvasLayer:
	var n: Node = get_parent()
	while n != null:
		if n is CanvasLayer:
			return n
		n = n.get_parent()
	return null


# ============================ 收集数据 ============================

# id：编辑已有物品 → 既有 id；新建 → 名称（去空格）。
# 模板（save_count=false）不含 count、不含 category（种类由标签判断）。
func _collect_common(save_count: bool) -> Dictionary:
	var d: Dictionary = {}
	if _editing_id != "":
		d["id"] = _editing_id
	else:
		d["id"] = _name_field.text.strip_edges()

	d["name"] = _name_field.text

	# 同步当前语言输入到 names 字典（即使未点应用也不丢）
	var nlang := _current_lang()
	var ntxt := _lang_input.text.strip_edges()
	if ntxt != "":
		_names_dict[nlang] = ntxt
	d["names"] = _names_dict

	var tags: Array = []
	for part in _tags_field.text.split(","):
		var t := str(part).strip_edges()
		if t != "" and not tags.has(t):
			tags.append(t)
	d["tags"] = tags

	d["description"] = _desc_field.text

	var dlang := _current_desc_lang()
	var dtxt := _desc_lang_input.text.strip_edges()
	if dtxt != "":
		_descs_dict[dlang] = dtxt
	d["descriptions"] = _descs_dict

	# attrs：以「开面板时载入 + 期间被标签选择窗/文件大小改过」的副本为底，
	# 再叠加「文件大小」与落盘归属（数字物品才有）。
	# ★ 编辑已有物品时**绝不能清空 attrs**，否则硬件物品的计算/功耗/尺寸等属性会被整批抹掉。
	var attrs: Dictionary = _editing_attrs.duplicate(true)
	if tags.has(Inventory.TAG_DIGITAL):
		var size := _read_size_gb()
		attrs["capacity"] = size
		var high: bool = tags.has(Inventory.TAG_NEEDS_HIGH_SPEED_STORAGE)
		# 需高速 → 只放固态；否则**优先机械**（机械装不下才固态）。
		# 估算时要先把自己已有的占用从「已用」里剔掉，否则自己挤自己。
		attrs["disk"] = Inventory.suggest_disk(size, high, _editing_id)
		# 「构建」：以面板两行为准（类型留空 → 不写该键）
		var bty := _build_type_text()
		if bty.is_empty():
			attrs.erase(Inventory.BUILD_KEY)
		else:
			var bd: Dictionary = {}
			bd[Inventory.MOD_BUILD_TYPE] = bty
			bd[Inventory.MOD_BUILD_MOD] = _build_mod_text()
			attrs[Inventory.BUILD_KEY] = bd
	else:
		attrs.erase("capacity")
		attrs.erase("disk")
		# ★★ 非数字物品：「构建」一律作废（与 Inventory.build_info 的门禁一致），
		#    否则「先勾数字物品填构建、再取消数字物品标签」会残留一个能构建的变量。
		attrs.erase(Inventory.BUILD_KEY)
	d["attrs"] = attrs
	d["texture_path"] = _texture_field.text.strip_edges()

	if save_count:
		var raw := _count_field.text.strip_edges()
		var c: int = 1
		if raw.is_valid_int():
			c = raw.to_int()
		d["count"] = c
	return d


func _set_msg(text: String, is_error: bool) -> void:
	if _msg_label == null:
		return
	_msg_label.text = text
	_msg_label.add_theme_color_override("font_color",
		Color(1.0, 0.5, 0.5, 1.0) if is_error else Color(0.6, 1.0, 0.7, 1.0))


## 最小化 / 还原：折叠只隐藏内容，顶栏（标题 + 拖动把柄 + 最小化 + 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.apply(self, _min_btn, v, _min_btn.get_parent() if is_instance_valid(_min_btn) else null)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
