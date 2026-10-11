# tag_picker_panel.gd
# 标签选择窗 —— 在积木属性面板「标签」输入框旁按「调整标签」打开。
#
# 两部分：
#   1) 标准 / 自定义标签（值均为英文）：用勾选框方便地增删。
#      ★ 与玩法无关的系统派生标签（桌面屏障 / 任务栏屏障 / 图标边界 / 图标层 / 页面边框 /
#        页面覆盖 / 关卡页面 / 系统自动生成 —— 见 BlockTags.PICKER_HIDDEN）**不再列出**：
#        玩家既不参与添加，也没有频繁增删的需要。但积木身上**已经带着**的仍会列出来
#        （可查看 / 可移除），否则会出现"标签挂在积木上、选择页却看不到也删不掉"。
#   2) 动态标签族（前缀开放、后缀自由填）：传送门入口 / 传送门出口 / 可传送 / 按钮 / 待检测 / 检测到。
#      这些标签"需要后缀配合"，在「标签选择页」里**不做勾选框**，改成一个「+」按钮：
#      按一下往当前标签集追加一个**带默认后缀**的族标签（如 portal_entrance_1、portal_entrance_2 …），
#      每按一次多添一个；后缀可在旁边的小输入框里直接改（改名不重建 UI，避免丢焦点）。
#      ★ 后缀必须非空：族标签的语义 = 「前缀 + 组名」，空后缀会让消费端（如 PortalManager 的组名）
#        解析为空 → 标签形同虚设（"标签没成功添加"）。已存在的族标签以「前缀 + 输入框 + ×」形式列出，点 × 即移除。
#
# 标签值一律英文（避免中文标识符 / 存档跨平台兼容问题）；UI 中文仅作展示。
#
# 使用:
#   var panel := TagPickerPanel.new()
#   panel.open(source_edit)                          # 默认积木模式
#   panel.open(source_edit, TagPickerPanel.Mode.ITEM) # 物品模式
#   panel.open(source_edit, TagPickerPanel.Mode.ITEM, attrs, on_attrs_changed)  # 物品模式 + 硬件属性回写
#   ui_layer.add_child(panel)
#
# ★ 两套标签**分开**：物品标签（Inventory.ITEM_TAGS：数字物品 / 现实物品 / 在回收站中 /
#   不可删除 / 已删除 / 设备硬件 / 需要高速存储）与积木标签（BlockTags.ALL）互不相干，各显示各的清单。
#   标题末尾用括号标注来源：（积木）/（物品）。
#   · 积木模式：标准/自定义勾选框 + 动态标签族（传送门 / 按钮 / 待检测 / 检测到，按 + 添加）。
#   · 物品模式：**只有勾选框**（动态族是积木概念，与物品无关，整段隐藏）
#     ★ 外加「硬件属性区」：标签集里勾了「设备硬件」时出现 —— 硬件类型勾选框
#       （CPU / 显卡 / 网卡 / 内存 / 存储 …）+ 「接口」字段名与值 + 「变量（键=值）」自由增删改，
#       变量完全开放修改；点「确定」通过回调把 attrs 回写给编辑物品面板。
# 信号:
#   closed
extends Control
class_name TagPickerPanel

signal closed

# 标签清单来源：积木 / 物品 / 关卡环境
#   · BLOCK —— BlockTags.ALL（积木的能力型标签；含动态标签族区）
#   · ITEM  —— Inventory.ITEM_TAGS（物品标签；含「设备硬件」属性区）
#   · LEVEL —— BlockTags.LEVEL_ENV_TAGS（**关卡**标签：单元 / 起点 / 终点 / 奖励箱，
#               当前仅作标注。关卡不是积木，故动态标签族与硬件属性区都不出现）
enum Mode { BLOCK, ITEM, LEVEL }

const WIDTH: float = 560.0
const TITLE_H: float = 34.0
const FOOTER_H: float = 44.0
const PAD: float = 10.0
const COLUMNS: int = 2
const FORM_FONT: int = 14

var _dim: ColorRect
var _bg: UIPanel
var _title_label: Label
var _drag_handle: UIDragHandle
var _close_btn: UIBtn
var _scroll: ScrollContainer
var _content: VBoxContainer
var _grid: GridContainer
var _dyn_sep: HSeparator = null           # 「动态标签」区（仅积木模式可见）
var _dyn_label: Label = null
var _family_box: VBoxContainer

var _mode: int = Mode.BLOCK
var _source_edit: LineEdit = null
var _current: Array = []                        # 当前已选标签集（权威数据源；确定时直接连回源输入框）
var _rows: Array = []                           # Array[{tag:String, check:CheckBox}]（仅标准/自定义勾选框）

# ---- 物品模式 + 「设备硬件」标签时出现的硬件属性区（变量完全开放修改）----
var _hw_sep: HSeparator = null
var _hw_label: Label = null
var _hw_box: VBoxContainer = null
var _hw_grid: GridContainer = null
var _hw_type_rows: Array = []                   # Array[{tag:String, check:CheckBox}]
var _if_key_sel: OptionButton = null            # 「接口」字段名（socket / gpu_if / storage_if …）
var _if_val_edit: LineEdit = null               # 「接口」值
# ★ 「变量（键 = 值）」编辑器**已迁到编辑物品页面**（ui/edit_item_panel.gd）：
#   本窗只负责「标签勾选 + 硬件类型 + 接口」，不再长出一片自由键值行。
var _attrs: Dictionary = {}                     # 工作副本（由 EditItemPanel 传入；确定时回写）
var _attrs_cb: Callable = Callable()            # 回写回调（参数：Dictionary）


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(WIDTH, 200.0)
	_build_ui()
	visible = false



# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏控件整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build_ui() -> void:
	# 半透明全屏遮罩：点击空白处 = 取消
	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 0.42)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.gui_input.connect(_on_dim_input)
	add_child(_dim)

	_bg = UIPanel.new()
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	var fnt = UIStyle.get_cjk_font()

	# 标题栏
	_title_label = Label.new()
	_title_label.text = ""   # 实际标题由 _refresh_title() 按模式拼（末尾带（积木）/（物品））
	_title_label.position = Vector2(PAD, 4.0)
	# 右侧要给「拖动把柄 + × 关闭」留位置，否则标题文字会压到把柄下面
	_title_label.size = Vector2(WIDTH - PAD * 3.0 - 28.0 - UIDragHandle.SIZE - 4.0, TITLE_H)
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", Color(0.75, 0.92, 1.0))
	_title_label.add_theme_font_size_override("font_size", int(UIStyle.FONT_SIZE) + 1)
	if is_instance_valid(fnt):
		_title_label.add_theme_font_override("font", fnt)
	add_child(_title_label)

	# 拖动把柄（× 关闭按钮左侧）：★ 本窗是手动定位（非 VBox 布局），
	#   把柄必须显式给 position/size —— 它自带 28×28，但父节点不是容器，不会自动摆放。
	_drag_handle = UIDragHandle.new()
	_drag_handle.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_drag_handle.anchor_left = 1.0
	_drag_handle.anchor_right = 1.0
	_drag_handle.offset_left = -(TITLE_H + 2.0 + UIDragHandle.SIZE + 4.0)
	_drag_handle.offset_right = -(TITLE_H + 2.0 + 4.0)
	# 垂直居中于标题栏（标题栏 y=4..38，把柄 28 高 → top=6,bottom=34）
	_drag_handle.offset_top = 6.0
	_drag_handle.offset_bottom = 6.0 + UIDragHandle.SIZE
	_drag_handle.setup(self)
	add_child(_drag_handle)

	_close_btn = UIBtn.new()
	_close_btn.set_id("close")
	_close_btn.set_label("×")
	_close_btn.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_close_btn.anchor_left = 1.0
	_close_btn.anchor_right = 1.0
	_close_btn.offset_left = -(TITLE_H + 2.0)
	_close_btn.offset_top = 3.0
	_close_btn.offset_right = -PAD
	_close_btn.offset_bottom = TITLE_H + 3.0
	_close_btn.pressed_id.connect(_on_footer_pressed)
	add_child(_close_btn)
	_min_btn = UIMinimize.attach_anchored(self, _close_btn, func(): set_minimized(not _minimized))

	# 滚动区（勾选框 + 动态标签族 都在里面，整体可滚）
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.offset_left = PAD
	_scroll.offset_right = -PAD
	_scroll.offset_top = TITLE_H
	_scroll.offset_bottom = -FOOTER_H
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 6)
	_scroll.add_child(_content)

	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 14)
	_grid.add_theme_constant_override("v_separation", 4)
	_content.add_child(_grid)

	# 分隔线 + 动态标签标题（★ 仅积木模式可见；物品模式整段隐藏）
	var sep := HSeparator.new()
	_content.add_child(sep)
	_dyn_sep = sep
	var dyn := Label.new()
	dyn.text = TranslationManager.t("动态标签（按 + 添加，后缀自由填；点 × 移除）")
	dyn.add_theme_color_override("font_color", Color(0.75, 0.92, 1.0))
	dyn.add_theme_font_size_override("font_size", int(UIStyle.FONT_SIZE))
	if is_instance_valid(fnt):
		dyn.add_theme_font_override("font", fnt)
	_content.add_child(dyn)
	_dyn_label = dyn

	_family_box = VBoxContainer.new()
	_family_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_family_box.add_theme_constant_override("separation", 6)
	_content.add_child(_family_box)

	_build_hw_section(fnt)

	# 底部按钮行
	var footer := HBoxContainer.new()
	footer.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	footer.anchor_left = 1.0
	footer.anchor_right = 1.0
	footer.anchor_top = 1.0
	footer.anchor_bottom = 1.0
	footer.offset_left = -160.0
	footer.offset_right = -PAD
	footer.offset_top = -FOOTER_H + 6.0
	footer.offset_bottom = -6.0
	footer.add_theme_constant_override("separation", 10)
	add_child(footer)

	var ok_btn := UIBtn.new()
	ok_btn.set_id("ok")
	ok_btn.set_label(TranslationManager.t("确定"))
	ok_btn.custom_minimum_size = Vector2(70.0, 30.0)
	ok_btn.pressed_id.connect(_on_footer_pressed)
	footer.add_child(ok_btn)

	var cancel_btn := UIBtn.new()
	cancel_btn.set_id("cancel")
	cancel_btn.set_label(TranslationManager.t("取消"))
	cancel_btn.custom_minimum_size = Vector2(70.0, 30.0)
	cancel_btn.pressed_id.connect(_on_footer_pressed)
	footer.add_child(cancel_btn)


# ==================== 硬件属性区（物品模式 + 「设备硬件」标签时可见）====================
#
# 需求：物品带「设备硬件」标签时，标签选择（物品）页要出现
#   ① 硬件类型勾选框（CPU / 显卡 / 网卡 / 内存 / 存储 …）
#   ② 「接口」输入框（按硬件类型自动选默认字段名，如 gpu_if / storage_if / socket）
# 内容全部落在 `_attrs` 里，点「确定」时通过 `_attrs_cb` 回写给编辑物品面板。
# ★★ 原先的 ③「其它变量：键 = 值 自由增删改」已**整体迁到编辑物品页面**
#    （ui/edit_item_panel.gd 的「变量（键 = 值，可自由增删改）」区）——理由是那片自由键值
#    行会随 attrs 增长，把本窗（560 宽、内容靠 `_resize_to_content` 撑高）撑得很难用，
#    而属性本来就该在「编辑物品」里改。本窗只保留「勾标签 + 硬件类型 + 接口」。

func _build_hw_section(fnt) -> void:
	_hw_sep = HSeparator.new()
	_content.add_child(_hw_sep)
	_hw_label = Label.new()
	_hw_label.text = TranslationManager.t("硬件属性（勾硬件类型；接口可直接改）")
	_hw_label.add_theme_color_override("font_color", Color(0.75, 0.92, 1.0))
	_hw_label.add_theme_font_size_override("font_size", int(UIStyle.FONT_SIZE))
	if is_instance_valid(fnt):
		_hw_label.add_theme_font_override("font", fnt)
	_content.add_child(_hw_label)

	_hw_box = VBoxContainer.new()
	_hw_box.add_theme_constant_override("separation", 6)
	_hw_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(_hw_box)

	# ① 硬件类型勾选框
	_hw_grid = GridContainer.new()
	_hw_grid.columns = 3
	_hw_grid.add_theme_constant_override("h_separation", 14)
	_hw_grid.add_theme_constant_override("v_separation", 4)
	_hw_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hw_box.add_child(_hw_grid)
	for t in Inventory.HW_PART_TAGS:
		var tag := str(t)
		var cell := HBoxContainer.new()
		cell.add_theme_constant_override("separation", 6)
		var ck := CheckBox.new()
		ck.text = Inventory.item_tag_display_name(tag)
		ck.button_pressed = _current.has(tag)
		ck.add_theme_font_size_override("font_size", FORM_FONT)
		if is_instance_valid(fnt):
			ck.add_theme_font_override("font", fnt)
		ck.toggled.connect(func(on: bool): _set_tag(tag, on))
		cell.add_child(ck)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_hw_grid.add_child(cell)
		_hw_type_rows.append({ "tag": tag, "check": ck })

	# ② 接口：字段名下拉 + 值
	var if_row := HBoxContainer.new()
	if_row.add_theme_constant_override("separation", 6)
	var if_lab := Label.new()
	if_lab.text = TranslationManager.t("接口")
	if_lab.custom_minimum_size = Vector2(64.0, 0.0)
	if_lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if_lab.add_theme_color_override("font_color", Color(0.78, 0.88, 1.0))
	if_lab.add_theme_font_size_override("font_size", FORM_FONT)
	if is_instance_valid(fnt):
		if_lab.add_theme_font_override("font", fnt)
	if_row.add_child(if_lab)
	_if_key_sel = OptionButton.new()
	_if_key_sel.custom_minimum_size = Vector2(150.0, 24.0)
	for k in Inventory.HW_IF_KEYS:
		_if_key_sel.add_item(str(k))
	_if_key_sel.item_selected.connect(_on_if_key_selected)
	if_row.add_child(_if_key_sel)
	_if_val_edit = LineEdit.new()
	_if_val_edit.custom_minimum_size = Vector2(120.0, 24.0)
	_if_val_edit.placeholder_text = TranslationManager.t("接口值")
	_if_val_edit.add_theme_font_size_override("font_size", FORM_FONT)
	_if_val_edit.mouse_filter = Control.MOUSE_FILTER_STOP
	_if_val_edit.caret_blink = true
	_if_val_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_if_val_edit.text_changed.connect(_on_if_value_changed)
	if_row.add_child(_if_val_edit)
	_hw_box.add_child(if_row)

	_set_hw_visible(false)


func _set_hw_visible(on: bool) -> void:
	if _hw_sep != null and is_instance_valid(_hw_sep):
		_hw_sep.visible = on
	if _hw_label != null and is_instance_valid(_hw_label):
		_hw_label.visible = on
	if _hw_box != null and is_instance_valid(_hw_box):
		_hw_box.visible = on


## 是否该显示硬件属性区：物品模式 且 标签集里有「设备硬件」
func _refresh_hw_section() -> void:
	var show: bool = (_mode == Mode.ITEM) and _current.has(Inventory.TAG_PC_HARDWARE)
	_set_hw_visible(show)
	if not show:
		return
	# 同步硬件类型勾选框（标签可能在别处被改动过）
	for row in _hw_type_rows:
		var ck: CheckBox = row["check"]
		if is_instance_valid(ck):
			var want: bool = _current.has(str(row["tag"]))
			if ck.button_pressed != want:
				ck.set_pressed_no_signal(want)
	# 「接口」默认字段名按当前已勾的硬件类型推
	var def_key: String = _default_if_key()
	if _if_key_sel != null and is_instance_valid(_if_key_sel):
		var idx: int = Inventory.HW_IF_KEYS.find(def_key)
		if idx >= 0:
			_if_key_sel.select(idx)
	if _if_val_edit != null and is_instance_valid(_if_val_edit):
		var cur_key: String = _current_if_key()
		_if_val_edit.text = Inventory.fmt_attr_value(_attrs.get(cur_key, ""))
	_resize_to_content()


## 内容变化后重算窗高（硬件属性区展开/收起时用；内容超出则靠滚动条）
func _resize_to_content() -> void:
	if not is_inside_tree():
		return
	var vp := UIStyle.canvas_viewport_size(self)
	var natural := _content.get_combined_minimum_size()
	var h: float = natural.y + TITLE_H + FOOTER_H + PAD * 2.0 + 8.0
	size = Vector2(WIDTH, clampf(h, 200.0, vp.y - 40.0))


## 当前「接口」下拉选中的字段名
func _current_if_key() -> String:
	if _if_key_sel == null or not is_instance_valid(_if_key_sel):
		return ""
	var i: int = clampi(_if_key_sel.selected, 0, Inventory.HW_IF_KEYS.size() - 1)
	return str(Inventory.HW_IF_KEYS[i])


## 按已勾的硬件类型推默认接口字段名（没勾到已知类型 → 空）
func _default_if_key() -> String:
	for t in _current:
		var k := str(Inventory.HW_DEFAULT_IF.get(str(t), ""))
		if k != "":
			return k
	return ""


func _on_if_key_selected(_idx: int) -> void:
	# 换了字段名 → 值框跟着换（该字段的值可能已存在，带出来免得看起来像丢了）
	if _if_val_edit != null and is_instance_valid(_if_val_edit):
		_if_val_edit.text = Inventory.fmt_attr_value(_attrs.get(_current_if_key(), ""))


func _on_if_value_changed(txt: String) -> void:
	var k := _current_if_key()
	if k == "":
		return
	_attrs[k] = Inventory.parse_attr_value(txt)


# ==================== 公开方法 ====================

# 打开：以 source（「标签」LineEdit）当前逗号分隔文本为初始标签集。
# mode=ITEM 且带 attrs/cb 时，勾「设备硬件」会在页内长出硬件属性区（接口 + 变量完全开放）；
# 点「确定」通过 attrs_cb 把改完的 attrs 回写给调用方（编辑物品面板）。
# 同步完成（不 await）：避免在关闭后滞后的协程继续恢复、把已关的窗再弹出来。
func open(source: LineEdit, mode: int = Mode.BLOCK, attrs: Dictionary = {},
		attrs_cb: Callable = Callable()) -> void:
	_source_edit = source
	_mode = mode
	_current = _tags_from_text(source.text if source else "")
	_attrs = attrs.duplicate(true) if (attrs is Dictionary) else {}
	_attrs_cb = attrs_cb
	_apply_mode()
	_rebuild_rows()
	var vp := UIStyle.canvas_viewport_size(self)
	var natural := _content.get_combined_minimum_size()
	var h: float = natural.y + TITLE_H + FOOTER_H + PAD * 2.0 + 8.0
	h = clampf(h, 200.0, vp.y - 40.0)
	size = Vector2(WIDTH, h)
	position = (vp - size) * 0.5
	queue_redraw()
	visible = true
	print("[TagPicker] 打开 已启用=%d" % _current.size())


## 按模式切换：标题（末尾括号标注 积木/物品）+ 动态标签族区显隐 + 重建勾选框
func _apply_mode() -> void:
	var is_block: bool = (_mode == Mode.BLOCK)
	_refresh_title()
	if _dyn_sep != null and is_instance_valid(_dyn_sep):
		_dyn_sep.visible = is_block
	if _dyn_label != null and is_instance_valid(_dyn_label):
		_dyn_label.visible = is_block
	if _family_box != null and is_instance_valid(_family_box):
		_family_box.visible = is_block
	if is_block:
		_rebuild_family_rows()
	# ★ 勾/取消「设备硬件」都要当场切换硬件属性区的显隐
	_refresh_hw_section()


## 标题：标签选择 + 用法提示 + **末尾括号标注来源**（积木 / 物品 / 关卡环境）
func _refresh_title() -> void:
	if _title_label == null or not is_instance_valid(_title_label):
		return
	var hint := TranslationManager.t("（勾选=启用；动态标签按 + 添加）") if _mode == Mode.BLOCK \
		else TranslationManager.t("（勾选=启用）")
	var suffix := TranslationManager.t("（积木）")
	if _mode == Mode.ITEM:
		suffix = TranslationManager.t("（物品）")
	elif _mode == Mode.LEVEL:
		suffix = TranslationManager.t("（关卡环境）")
	_title_label.text = TranslationManager.t("标签选择") + hint + suffix


# 关闭（不写回）：取消 / 点遮罩 / 属性面板被关闭 / ESC 都会走到这里
func close() -> void:
	visible = false
	# 可能已被移除出场景树（父面板先关）→ get_viewport() 会返回 null，先判断再释放焦点。
	if is_inside_tree():
		get_viewport().gui_release_focus()
	closed.emit()
	queue_free()


func is_open() -> bool:
	return visible


# ==================== 内部：勾选框（标准 / 自定义非族标签）====================

func _rebuild_rows() -> void:
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	_rows.clear()
	# 勾选框标签 = 标准标签(ALL) ∪ 当前集里的自定义非族标签。
	# ★ 展示顺序：**按字母（字典序）排序**，不再按「标准标签在前 + 添加先后」。
	#   大小写统一按小写比较，保证稳定；同小写时再按原串比较兜底。
	# ★ ALL 里的 PICKER_HIDDEN（系统派生标签：桌面屏障 / 页面边框 / 页面覆盖 / 系统自动生成 …）
	#   **不进勾选框** —— 它们与玩法功能无关，也不是玩家会频繁增删的东西，列出来只会淹掉
	#   真正可用的能力型标签。但「当前集里已有」的它们仍会被下面第二轮列出（可看 / 可删）。
	var is_block: bool = (_mode == Mode.BLOCK)
	var items: Array[String] = []
	var seen := {}
	for t in _standard_tags():
		if is_block and t in BlockTags.PICKER_HIDDEN:
			continue
		if not seen.has(t):
			items.append(t)
			seen[t] = true
	for t in _current:
		var s := str(t)
		if seen.has(s):
			continue
		# 动态族标签（传送门/按钮/待检测/检测到）是积木概念，积木模式下交给下方「+ 按钮」区；
		# 物品模式没有那个区，所以一律进勾选框（否则物品上的自定义标签会看不见也删不掉）。
		if is_block and BlockTags.is_family_tag(s):
			continue
		items.append(s)
		seen[s] = true
	items.sort_custom(func(a: String, b: String) -> bool:
		var la := a.to_lower()
		var lb := b.to_lower()
		if la == lb:
			return a < b
		return la < lb)
	var fnt = UIStyle.get_cjk_font()
	for t in items:
		var tag: String = t   # 每轮独立绑定，避免 lambda 捕获到循环变量末尾值
		var cell := HBoxContainer.new()
		cell.add_theme_constant_override("separation", 6)
		var ck := CheckBox.new()
		ck.text = tag
		ck.button_pressed = (tag in _current)
		ck.add_theme_font_size_override("font_size", FORM_FONT)
		if is_instance_valid(fnt):
			ck.add_theme_font_override("font", fnt)
		ck.toggled.connect(func(on: bool): _set_tag(tag, on))
		cell.add_child(ck)
		# 本地化显示名作辅助（非标准标签无条目则跳过）
		var zh := _display_name(tag)
		if zh != tag and not zh.is_empty():
			var lb := Label.new()
			lb.text = zh
			lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			lb.add_theme_color_override("font_color", Color(0.65, 0.72, 0.85))
			lb.add_theme_font_size_override("font_size", FORM_FONT - 2)
			if is_instance_valid(fnt):
				lb.add_theme_font_override("font", fnt)
			cell.add_child(lb)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_grid.add_child(cell)
		_rows.append({"tag": tag, "check": ck})


func _set_tag(tag: String, on: bool) -> void:
	var idx := _current.find(tag)
	if on and idx < 0:
		_current.append(tag)
	elif not on and idx >= 0:
		_current.remove_at(idx)
	# 「设备硬件」一勾/一取消 → 硬件属性区（硬件类型 + 接口 + 变量）当场显隐
	if tag == Inventory.TAG_PC_HARDWARE:
		_refresh_hw_section()
	# ★ 勾上某个硬件类型（CPU / 显卡 / 网卡 …）→ 「接口」字段名跟着切到该类零件该用的字段
	#   （gpu → gpu_if、nic → nic_if、cpu → socket …），省得用户自己去下拉里找。
	elif on and Inventory.HW_PART_TAGS.has(tag):
		_select_if_key(str(Inventory.HW_DEFAULT_IF.get(tag, "")))


## 切换「接口」字段名并带出该字段当前值（不触发 item_selected，避免递归）
func _select_if_key(k: String) -> void:
	if k == "" or _if_key_sel == null or not is_instance_valid(_if_key_sel):
		return
	var idx: int = Inventory.HW_IF_KEYS.find(k)
	if idx < 0 or _if_key_sel.selected == idx:
		return
	_if_key_sel.select(idx)
	if _if_val_edit != null and is_instance_valid(_if_val_edit):
		_if_val_edit.text = Inventory.fmt_attr_value(_attrs.get(k, ""))


# ---- 模式相关的取值：标准标签清单 / 中文显示名 ----

## 当前模式的标准标签清单（积木 → BlockTags.ALL；物品 → Inventory.ITEM_TAGS；
## 关卡环境 → BlockTags.LEVEL_ENV_TAGS（单元/起点/终点/奖励箱，仅作标注））
func _standard_tags() -> Array:
	if _mode == Mode.ITEM:
		return Inventory.ITEM_TAGS
	if _mode == Mode.LEVEL:
		return BlockTags.LEVEL_ENV_TAGS
	return BlockTags.ALL


## 当前模式的中文显示名（非标准标签原样返回）
func _display_name(tag: String) -> String:
	if _mode == Mode.ITEM:
		return Inventory.item_tag_display_name(tag)
	return BlockTags.display_name(tag)


# ==================== 内部：动态标签族（+ 按钮）====================

func _rebuild_family_rows() -> void:
	for c in _family_box.get_children():
		_family_box.remove_child(c)
		c.queue_free()
	var fnt = UIStyle.get_cjk_font()
	for fam in BlockTags.TAG_FAMILIES:
		var prefix: String = fam["prefix"]
		var label: String = fam["label"]
		var p: String = prefix   # 独立绑定，供 lambda 使用
		var frow := VBoxContainer.new()
		frow.add_theme_constant_override("separation", 3)
		frow.mouse_filter = Control.MOUSE_FILTER_STOP

		# 表头：族名 + 「+」按钮
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 6)
		var lb := Label.new()
		lb.text = label
		lb.custom_minimum_size = Vector2(96.0, 0)
		lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lb.add_theme_color_override("font_color", Color(0.75, 0.92, 1.0))
		lb.add_theme_font_size_override("font_size", FORM_FONT)
		if is_instance_valid(fnt):
			lb.add_theme_font_override("font", fnt)
		head.add_child(lb)
		var add := UIBtn.new()
		add.set_id("add")
		add.set_label("+")
		add.custom_minimum_size = Vector2(26.0, 24.0)
		add.pressed_id.connect(func(_id): _add_family(p))
		head.add_child(add)
		frow.add_child(head)

		# 已存在的族标签：前缀 + 小输入框（直接填后缀）+ ×（点 × 移除）
		var chips := HFlowContainer.new()
		chips.add_theme_constant_override("separation", 4)
		var fam_tags: Array = []
		for t in _current:
			if BlockTags.family_prefix(str(t)) == p:
				fam_tags.append(str(t))
		if fam_tags.is_empty():
			var empty := Label.new()
			empty.text = TranslationManager.t("（暂无，按 + 添加）")
			empty.add_theme_color_override("font_color", Color(0.5, 0.56, 0.66))
			empty.add_theme_font_size_override("font_size", FORM_FONT - 2)
			if is_instance_valid(fnt):
				empty.add_theme_font_override("font", fnt)
			chips.add_child(empty)
		else:
			for t in fam_tags:
				var holder: Array = [str(t)]   # 可变持有：该标签的当前完整串（供输入框/删除按钮引用）
				var chip := HBoxContainer.new()
				chip.add_theme_constant_override("separation", 2)
				# 前缀（只读提示，如 portal_entrance_）
				var pre := Label.new()
				pre.text = p
				pre.add_theme_color_override("font_color", Color(0.6, 0.68, 0.82))
				pre.add_theme_font_size_override("font_size", FORM_FONT - 1)
				if is_instance_valid(fnt):
					pre.add_theme_font_override("font", fnt)
				chip.add_child(pre)
				# 小输入框：直接填后缀（标签 = 前缀 + 输入内容）。改名时**不重建**，避免输入焦点丢失。
				var le := LineEdit.new()
				le.text = str(holder[0]).substr(p.length())
				le.placeholder_text = TranslationManager.t("后缀")
				le.custom_minimum_size = Vector2(96.0, 20.0)
				le.add_theme_font_size_override("font_size", FORM_FONT - 1)
				le.mouse_filter = Control.MOUSE_FILTER_STOP
				le.caret_blink = true
				le.text_changed.connect(func(txt: String):
					var nt := p + _sanitize_suffix(txt)
					_replace_tag(holder[0], nt)
					holder[0] = nt)
				chip.add_child(le)
				# 删除按钮（×）
				var rm := UIBtn.new()
				rm.set_id("rm")
				rm.set_label("×")
				rm.custom_minimum_size = Vector2(20.0, 20.0)
				rm.pressed_id.connect(func(_id): _remove_tag(holder[0]))
				chip.add_child(rm)
				chips.add_child(chip)
		frow.add_child(chips)
		_family_box.add_child(frow)


# 后缀清洗：去掉空白与逗号（逗号是标签分隔符，会破坏回填格式）
func _sanitize_suffix(s: String) -> String:
	return s.strip_edges().replace(" ", "").replace(",", "")


# 就地替换 _current 里的一条标签（输入框改名用）。不重建 UI（保焦点）；重复项去重。
# ★ 后缀被清空（new_tag == 族前缀）时**保留**这条（不删）：否则用户清空后想再输入时，
#   输入框的 holder[0] 已不在 _current 里 → 后续输入全部丢失。空后缀标签统一在 _apply() 时丢弃。
func _replace_tag(old_tag: String, new_tag: String) -> void:
	var i := _current.find(old_tag)
	if i < 0 or new_tag == old_tag:
		return
	_current[i] = new_tag
	for j in range(_current.size() - 1, -1, -1):
		if j != i and str(_current[j]) == new_tag:
			_current.remove_at(j)
	queue_redraw()


# 按 + ：追加一个**带可用默认后缀**的族标签（如 teleportable_1），点一次多添一个。
# ★ 后缀必须**非空**：这些族标签（传送门入口/出口/可传送/按钮/待检测/检测到）的语义全靠
#   「前缀 + 组名」，「空后缀」= 组名为空 → 消费端（如 PortalManager._group_string 返回 ""）
#   一律 `continue` → 标签**形同虚设**（用户表现为"标签没成功添加"）。
#   所以这里从 1 开始编号（teleportable_1、teleportable_2…），用户可在小输入框里改成想要的名字。
#   已存在的同名（含手改过的）会跳过，保证唯一。
func _add_family(prefix: String) -> void:
	var i := 1
	while (prefix + str(i)) in _current:
		i += 1
	_current.append(prefix + str(i))
	_rebuild_family_rows()
	queue_redraw()


func _remove_tag(tag: String) -> void:
	var idx := _current.find(tag)
	if idx >= 0:
		_current.remove_at(idx)
	_rebuild_family_rows()
	queue_redraw()


# ==================== 确定 / 关闭 ====================

# 确定：把当前标签集（去重、保序）逗号拼接回填到源输入框。
# ★ 丢掉「空后缀的族标签」（如 teleportable_）：它们会让消费端解析出空组名 → 形同虚设，
#   留着只会让用户以为"加了标签却没生效"。用户在输入框里清空了后缀即等于删除该标签。
func _apply() -> void:
	var parts: Array[String] = []
	for t in _current:
		var s := str(t)
		if _is_empty_suffix_family(s):
			continue
		if not (s in parts):
			parts.append(s)
	var joined := ",".join(parts)
	if _source_edit != null and is_instance_valid(_source_edit) and _source_edit is LineEdit:
		_source_edit.text = joined
		_source_edit.queue_redraw()
	# 物品模式：把（可能改过的）硬件属性回写给调用方（编辑物品面板）
	if _attrs_cb.is_valid():
		_attrs_cb.call(_attrs)
	print("[TagPicker] 确定回填 tags=%s" % joined)


# 族标签但后缀为空（族名本身）→ 无效
func _is_empty_suffix_family(tag: String) -> bool:
	var p: String = BlockTags.family_prefix(tag)
	return not p.is_empty() and tag == p


func _on_footer_pressed(id: String) -> void:
	match id:
		"ok":
			_apply()
			close()
		"cancel", "close":
			close()


func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close()


func _tags_from_text(s: String) -> Array:
	var out: Array = []
	for part in s.split(","):
		var t := str(part).strip_edges()
		if not t.is_empty() and not (t in out):
			out.append(t)
	return out


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
