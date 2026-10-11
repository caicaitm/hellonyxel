# ui/inventory_panel.gd
# 背包 UI 面板 —— 从 abandon 版 scripts/ui/inventory_panel.gd 迁移，适应当前项目。
#
# 与 abandon 版差异：
#   · 不使用 TextureLibrary：物品目前无图片，格子显示 名称 / 种类 / ×数量（无图兜底为名称首字）。
#   · **所有物品都可拖动**（不再要求 placeable 标签）。
#   · 松手放置走「构建」约定（判定见 Inventory.build_info）：物品带**数字物品**标签且含
#     「构建」变量（`attrs.build = {type, mod}`，或旧式标签 `构建_<类别>{<修饰>}`）时，
#     在桌面松开 → 调 desktop.place_inventory_item 生成 build.type 积木（build.mod 作属性
#     覆盖），并把该物品数量 -1；
#     ★★ 非数字物品 / 无构建变量 / 类型未注册 → 什么也不生成，数量也不减。
#   · 打开入口：桌面/open_inventory()。
#
# 布局（body = HBox，共 3 栏）：
#   左栏：按种类筛选侧栏（可显隐，与中列同层）｜ 中列（标题「背包」+ 拖动把柄 + × / 筛选行 /
#         4行×6列=24格 / ◀上一页 N页 ▶下一页）｜ 右列：数据仓库
#   ★ 中列里**没有**自由文字行：原来的「设备：…（共 N）」行文本长度会顶宽整个中列 → 已移除（批次 30）。
#   ★ 筛选内容位于**物品栏左侧**，且它是 **`body` 的第一个子节点**（不是塞进中列里）。
#   ★★ **屏幕锚点 = 中列（物品栏）本身**（见 _relayout）：面板宽度怎么变，中列在屏幕上都不动 ——
#     · 左栏「筛选」展开 → 面板**向左**加宽（x 减去 侧栏宽+separation）；
#     · 右列「数据仓库」展开/折叠 → 面板只改**右缘**（x 完全不动）。
#     ⇒「筛选」按钮 + 物品栏 + 四个按钮（折叠 / 下一页 / 移动页面 / 关闭页面）**永不位移**；
#      数据仓库折叠后整列隐藏，面板右缘就贴在物品栏右缘旁（只差一个内边距）。
class_name InventoryPanel
extends Control

signal closed

const COLS: int = 6
const ROWS: int = 4
const PER_PAGE: int = COLS * ROWS   # 24
const SLOT_SIZE: float = 78.0
const GRID_GAP: float = 6.0
const PADDING: float = 12.0
const FORM_FONT: int = 13
const BTN_H: float = 28.0
const DISK_W: float = 300.0         # 右侧「数据仓库」栏宽度（一行三个读数要放得下）
const FILTER_W: float = 190.0       # 左侧「按种类筛选」栏宽度（选项 1 列 + 排序按钮竖排）

const _SORT_LABELS: Dictionary = {
	"name": "按名称",
	"count": "按数量",
	"category": "按种类",
}

# 设备管理页的设备（整机电脑 / 网络器材）由 Devices 单例独立管理（devices.json），
# 不属于背包物品（inventory.json）——迁移时曾刻意把「电脑」从背包物品里删掉（见 devices.gd）。
# 本面板把设备「聚合展示」为现实物品：设备转成的展示项带 DEVICE_ID_PREFIX 前缀 + TAG_DEVICE 标记，
# 使其**只读**（不可回收 / 编辑 / 拖拽生成积木），改动仍只在设备管理页发生。
const DEVICE_ID_PREFIX := "device:"
const TAG_DEVICE := "device"

var _bg: UIPanel
var _content: VBoxContainer             # 中列（标题 / 筛选行 / 格子 / 翻页）
var _title: Label
var _close_btn: UIBtn
var _drag_handle: UIDragHandle
var _filter_btn: UIBtn
var _grid: GridContainer
var _slots: Array = []
var _prev_btn: UIBtn
var _next_btn: UIBtn
var _page_label: Label

var _ctx_menu: ContextMenu = null           # 物品右键菜单
var _sort_by: String = "name"
var _sort_asc: bool = true
var _page: int = 0

# 「按种类筛选」：**body 左栏的侧栏**（点「筛选」就地展开/收起，不是浮层）。
# 观感对齐右侧「数据仓库」列：标题 + 内容 + 分隔线；与中列同层 ⇒ 展开只让面板**向左**变宽。
var _filter_block: VBoxContainer = null   # 侧栏（常建、按需显隐）
var _filter_block_title: Label = null
var _filter_sort_title: Label = null
var _filter_checks_grid: GridContainer = null   # 勾选项 1 列网格（打开时重建，兼容调试模式变化）
var _sort_btns: Dictionary = {}           # 排序键 -> UIBtn（就地改 ▲▼ 文案，绝不重建）
var _filter_open: bool = false
## 上一次 _relayout 时「中列左侧」的占位宽度（筛选侧栏贡献）→ 用于只补偿左侧增删，
## 让中列（物品栏）的屏幕位置在**任何**展开/折叠下都保持恒定。
var _last_filter_w: float = 0.0

# 右侧「数据仓库」：机械 / 固态 两个条状数值栏（左下「已使用」/ 中间「剩余」/ 右侧「总容量」）
#   + 展开/折叠按钮（控制这一块是否常显） + 「文件搬迁」按钮。
var _body: HBoxContainer = null          # 主体 HBox（左列 | 数据仓库列），重排尺寸要用
var _disk_col: VBoxContainer = null
var _disk_title_row: HBoxContainer = null  # 「数据仓库」标题行（折叠时随整列一起隐藏）
var _disk_title: Label = null
var _disk_toggle_btn: UIBtn = null       # 展开 / 折叠
var _disk_body: VBoxContainer = null     # 可折叠部分（分隔线 + 两条数值栏 + 提示 + 文件搬迁）
var _disk_meters: Dictionary = {}       # "hdd" / "ssd" -> DiskMeter
var _disk_hint: Label = null            # 统计口径说明 / 容量不足提示
var _disk_expanded: bool = true

# 按种类筛选（勾选项）：数字物品 / 现实物品 / 在回收站中 / （调试）已删除。
# · 数字物品 / 现实物品 / 设备硬件 为「或」关系（都不勾 → 不过滤种类）。
# · 「在回收站中」为独占视图：勾选后只显示回收站物品，隐藏一切普通物品（含电脑文件）；
#   取消勾选则回收站物品隐藏、普通物品恢复显示。
# · 已删除物品（必带 in_recycle_bin）在调试模式下可勾选「已删除」单独查看，右键可恢复。
var _filter_digital: bool = false
var _filter_real: bool = false
var _filter_pc: bool = false
var _filter_recycle: bool = false
var _filter_deleted: bool = false
var _filtered_total: int = 0

# 物品拖拽放置
var _dragging_item: bool = false
var _drag_item_id: String = ""
var _drag_ghost: Control = null

# 编辑物品面板（调试模式下右键物品 / 空栏打开）
var _edit_panel: EditItemPanel = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	gui_input.connect(_on_panel_gui_input)
	_build_ui()
	if not TranslationManager.language_changed.is_connected(_on_lang_changed):
		TranslationManager.language_changed.connect(_on_lang_changed)
	if not Inventory.changed.is_connected(_on_inventory_changed):
		Inventory.changed.connect(_on_inventory_changed)
	if not Devices.changed.is_connected(_on_devices_changed):
		Devices.changed.connect(_on_devices_changed)
	visible = false


func open() -> void:
	visible = true
	_dragging_item = false
	_page = 0
	_close_item_menu()
	# ★ 顺序：先 _refresh()（内部含 _relayout → 按**真实内容**算出尺寸），再 _center()。
	#   反过来的话，首次打开会在「仓库读数 / 格子文字还是空文本」时定尺寸 → 背景比内容小（见 _refresh）。
	_refresh()
	_center()
	move_to_front()


## 双击「回收站」积木入口：打开背包页面，并把种类筛选设为「仅勾选在回收站中」
## （其余种类勾选项全部取消；同时展开筛选侧栏，让用户看到勾选状态）。
## 按现有筛选语义：勾选「在回收站中」会**揭示**回收站物品（常态隐藏），普通物品始终显示。
func open_recycle_only() -> void:
	visible = true
	_dragging_item = false
	_page = 0
	_close_item_menu()
	_filter_digital = false
	_filter_real = false
	_filter_pc = false
	_filter_recycle = true
	_filter_deleted = false
	_set_filter_open(true)   # 展开 + 重建勾选项（反映新状态）
	_refresh()
	_center()
	move_to_front()


func close() -> void:
	visible = false
	_close_item_menu()
	_dragging_item = false
	set_process(false)
	if _drag_ghost != null and is_instance_valid(_drag_ghost):
		_drag_ghost.queue_free()
	_drag_ghost = null
	get_viewport().gui_release_focus()
	closed.emit()


func is_open() -> bool:
	return visible


## 居中：**以「中列（物品栏）」为锚**，基准宽 = 「筛选收起 + 数据仓库展开」。
## ⇒ 无论筛选是否展开、数据仓库是否折叠，甚至**关掉再打开**，中列（物品栏）的屏幕 x 都相同；
##   筛选展开只向**左**长、数据仓库展开只向**右**长。
func _center() -> void:
	var vp: Vector2 = UIStyle.canvas_viewport_size(self)
	var ref_w: float = _reference_width()
	var base_pos: Vector2 = (vp - Vector2(ref_w, size.y)) / 2.0
	# 基准布局里「中列」左缘的屏幕 x（基准 = 筛选收起 ⇒ 中列左缘 = 面板左缘 + 内边距）
	var anchor_x: float = base_pos.x + PADDING
	# 实际面板左缘 = 中列锚点 − 内边距 − 中列左侧占位（筛选侧栏）
	position = Vector2(anchor_x - PADDING - _filter_side_width(), base_pos.y)


## 面板的**基准宽度** = 「筛选收起 + 数据仓库展开」时的宽度。
## 三种状态（筛选展开 / 仓库折叠）都拿它做居中基准 ⇒ 中列（物品栏）屏幕 x 恒定。
func _reference_width() -> float:
	var w: float = size.x - _filter_side_width()
	if not _disk_expanded:
		w += DISK_W + _body_sep()
	return w


## **中列左侧**的占位宽度：筛选侧栏展开时 = 侧栏宽 + body 的 separation，其余情况 = 0。
## ★ 容器**不布局隐藏的子节点**（连 separation 也不计）—— 用「visible」而不是「_filter_open」
##   单条件，避免 visible 与状态位短时不一致时算错补偿量。
func _filter_side_width() -> float:
	if not _filter_open:
		return 0.0
	if _filter_block == null or not is_instance_valid(_filter_block) or not _filter_block.visible:
		return 0.0
	return FILTER_W + _body_sep()


func _body_sep() -> float:
	if _body == null or not is_instance_valid(_body):
		return 0.0
	return float(_body.get_theme_constant("separation"))


# ============================ 构建 UI ============================


# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build_ui() -> void:
	# 背景
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

	# 主体：左栏「按种类筛选」 | 中列（标题/筛选行/格子/翻页） | 右列（数据仓库）
	var body := HBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", int(GRID_GAP) * 2)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(body)
	_body = body

	# ★ 左侧「按种类筛选」侧栏 = body 的**第一个子节点**（在中列左边，而不是塞进中列里）。
	#   关键：侧栏是 body 的兄弟 ⇒ 展开/收起只改变**面板宽度**（配合 _relayout 只补偿左侧占位），
	#   中列 `_content` 的屏幕位置完全不动 ⇒「筛选」按钮 / 物品栏 / 数据仓库 / 右侧四个按钮**全部原地不动**。
	_filter_block = _build_filter_block()
	_filter_block.visible = false
	body.add_child(_filter_block)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", int(GRID_GAP))
	_content.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	body.add_child(_content)

	# 顶栏：标题 + 拖动把柄 + × 关闭（把柄在 × 左边）
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	_title = _make_label("", 16, Color.WHITE)
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

	# 筛选行（顶栏「关闭 / 移动页面位置」的**下一行**）：筛选 ▾ ……… 展开 / 折叠
	# ★ 「展开/折叠」按钮原先挂在右列「数据仓库」标题行上，现按需求挂在「筛选」行的**最右端**
	#   （中间弹性占位撑开 → 按钮右边缘与左列右缘/格子末列对齐，正对右列「数据仓库」）；
	#   右列标题行因此只剩标题（折叠时整列收起，见 _set_disk_expanded / _relayout）。
	var sort_row := HBoxContainer.new()
	sort_row.add_theme_constant_override("separation", GRID_GAP)
	_filter_btn = _make_btn("", "filter_toggle")
	_filter_btn.custom_minimum_size = Vector2(88, 28)
	sort_row.add_child(_filter_btn)
	var sort_gap := Control.new()
	sort_gap.name = "SortSpacer"
	sort_gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sort_gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sort_row.add_child(sort_gap)
	_disk_toggle_btn = _make_btn(TranslationManager.t("折叠"), "disk_toggle")
	_disk_toggle_btn.custom_minimum_size = Vector2(72, 28)
	_disk_toggle_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sort_row.add_child(_disk_toggle_btn)
	_content.add_child(sort_row)

	# 物品栏：格子网格 → 翻页行（直接挂在 `_content` 下，与左侧侧栏同层、互不影响）
	# ★★ 批次 30：此处**不再有**「设备：我的笔记本、我的台式机、…（共 7）」这一行。
	#   原因：该 Label 的**文本长度**会顶宽整个中列（`_content` 最小宽度被它从 498 撑到 561），
	#   连带把面板、四个按钮、格子宽度全部带偏（格子被拉宽到 87.5/格）。已按需求清除该行文本，
	#   连行本身一起去掉（只清文本的话 _refresh_device_label 每次刷新都会再写回去）。

	# 格子网格 6 列 → 24 格 4 行
	_grid = GridContainer.new()
	_grid.columns = COLS
	_grid.add_theme_constant_override("h_separation", int(GRID_GAP))
	_grid.add_theme_constant_override("v_separation", int(GRID_GAP))
	for i in range(PER_PAGE):
		var slot := _make_slot()
		_slots.append(slot)
		_grid.add_child(slot)
	_content.add_child(_grid)

	# 翻页行
	var page_row := HBoxContainer.new()
	page_row.add_theme_constant_override("separation", GRID_GAP)
	_prev_btn = _make_btn("", "prev")
	_prev_btn.custom_minimum_size = Vector2(88, 28)
	_page_label = Label.new()
	_page_label.text = "1 / 1"
	_page_label.add_theme_color_override("font_color", Color.WHITE)
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_page_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_next_btn = _make_btn("", "next")
	_next_btn.custom_minimum_size = Vector2(88, 28)
	page_row.add_child(_prev_btn)
	page_row.add_child(_page_label)
	page_row.add_child(_next_btn)
	_content.add_child(page_row)

	# 右列：数据仓库（机械 / 固态 两条数值栏 + 展开折叠 + 文件搬迁）
	_disk_col = _build_disk_column()
	body.add_child(_disk_col)

	# 自适应尺寸：两侧合起来的最小尺寸 + padding
	_relayout()

	_apply_lang()


## 重排面板尺寸（筛选栏展开/收起、数据仓库展开/折叠都会走到这里）。
##   · 数据仓库折叠 → 右列最小宽度归 0（数值栏已隐藏，不参与容器最小尺寸）→ 面板收窄。
##   · 筛选栏展开   → 左侧侧栏参与最小尺寸 → 面板变宽。
## ★★ 屏幕锚点 = **中列（物品栏）**，不是「面板右缘」：
##   面板宽度变化只有在**中列左边**增删了东西（筛选侧栏）时才需要挪 position.x；
##   右列「数据仓库」展开/折叠只改**右缘**（x 分毫不动）。
##   ⇒ 物品栏与「筛选 / 折叠 / 下一页 / 移动页面 / 关闭页面」的屏幕位置**永远不变**
##     （旧写法「右缘固定」会让折叠数据仓库时整个中列向右跳 DISK_W 那么多）。
func _relayout() -> void:
	if _disk_col != null and is_instance_valid(_disk_col):
		_disk_col.custom_minimum_size = Vector2(DISK_W if _disk_expanded else 0.0, 0.0)
	if _body == null or not is_instance_valid(_body):
		return
	# ★ 不要在这里 `_body.reset_size()`：那会先把 body 缩到（**过期的**）最小尺寸，
	#   再把子节点宽度压小 → 自动换行 Label 按「窄宽度」重排 → 读到的 min 虚高。直接读即可。
	_sync_hint_width()
	var cmin: Vector2 = _body.get_combined_minimum_size()
	var old: Vector2 = size
	var new_size := Vector2(cmin.x + PADDING * 2.0, cmin.y + PADDING * 2.0)
	size = new_size
	var f_now: float = _filter_side_width()
	position.x -= f_now - _last_filter_w     # 只补偿「中列左侧」占位的变化 ⇒ 中列屏幕位置恒定
	_last_filter_w = f_now
	position.y += (old.y - new_size.y) * 0.5  # 竖直保持居中


## 「数据仓库」口径提示 `_disk_hint` 是**自动换行** Label：它的最小高度取决于它**当前宽度**。
## 刚设完文本时容器往往还没按新尺寸排过版（宽度还是刚建出来的 1）→ 直接读 min 会得到
## 「一行一个字」的虚高高度（实测 DiskBody min 191 → 807，面板被撑高 384px = 下方一大片空白）。
## 测量前把宽度摆到真实列宽即可（折叠态设 1 无副作用：整块已隐藏，不参与最小尺寸）。
func _sync_hint_width() -> void:
	if _disk_hint == null or not is_instance_valid(_disk_hint):
		return
	var want: float = DISK_W if _disk_expanded else 1.0
	if not is_equal_approx(_disk_hint.size.x, want):
		_disk_hint.size = Vector2(want, _disk_hint.size.y)


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


func _make_slot() -> Control:
	var slot := Control.new()
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	slot.size = Vector2(SLOT_SIZE, SLOT_SIZE)

	var sp := UIPanel.new()
	sp.set_anchors_preset(Control.PRESET_FULL_RECT)
	sp.set_corner_radius(UIStyle.CORNER_RADIUS * 0.6)
	sp.set_fill_color(Color(UIStyle.FILL_DEFAULT.r, UIStyle.FILL_DEFAULT.g, UIStyle.FILL_DEFAULT.b, 0.32))
	sp.set_border_color(UIStyle.BORDER)
	sp.set_border_width(1.0)
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(sp)

	# 物品图标（texture_path）：铺在名称与数量之间的中间区域。
	# 之前背包**从不读 texture_path**，填了路径也只显示文字 —— 这里补上渲染。
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 10.0
	icon.offset_right = -10.0
	icon.offset_top = 19.0
	icon.offset_bottom = -19.0
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.visible = false
	slot.add_child(icon)

	var name_l := _make_label("", 12, Color.WHITE)
	name_l.name = "Name"
	name_l.set_anchors_preset(Control.PRESET_TOP_WIDE)
	name_l.offset_top = 5.0
	name_l.offset_left = 3.0
	name_l.offset_right = -3.0
	name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	slot.add_child(name_l)

	var cat_l := _make_label("", 10, Color(0.80, 0.92, 1.0, 0.9))
	cat_l.name = "Cat"
	cat_l.set_anchors_preset(Control.PRESET_FULL_RECT)
	cat_l.offset_left = 3.0
	cat_l.offset_right = -3.0
	cat_l.offset_top = SLOT_SIZE * 0.42
	cat_l.offset_bottom = -SLOT_SIZE * 0.40
	cat_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cat_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cat_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	slot.add_child(cat_l)

	var cnt_l := _make_label("", 13, Color(1.0, 0.95, 0.6, 1.0))
	cnt_l.name = "Count"
	cnt_l.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	cnt_l.offset_left = SLOT_SIZE * 0.45
	cnt_l.offset_right = -4.0
	cnt_l.offset_top = -24.0
	cnt_l.offset_bottom = -3.0
	cnt_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cnt_l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	slot.add_child(cnt_l)

	slot.gui_input.connect(
		func(ev: InputEvent):
			_on_slot_gui_input(ev, slot)
	)
	return slot


# ============================ 刷新/渲染 ============================

func _on_lang_changed(_lang: String) -> void:
	_apply_lang()
	_refresh()


## 背包数据变化（增删改 / 从磁盘载入）→ 面板开着就刷新（关着不刷新，省开销）
func _on_inventory_changed() -> void:
	if is_open():
		_refresh()


func _on_devices_changed() -> void:
	if is_open():
		_refresh()


func _apply_lang() -> void:
	_title.text = TranslationManager.t("背包")
	_refresh_filter_toggle()
	if _filter_block_title != null and is_instance_valid(_filter_block_title):
		_filter_block_title.text = TranslationManager.t("按种类筛选")
	if _filter_sort_title != null and is_instance_valid(_filter_sort_title):
		_filter_sort_title.text = TranslationManager.t("排序")
	# 勾选项文案随语言变 → 仅在区块展开时重建（收起时下次展开会重建）
	if _filter_open:
		_rebuild_filter_checks()
		_refresh_sort_buttons()
	_prev_btn.set_label("◀ " + TranslationManager.t("上一页"))
	_next_btn.set_label(TranslationManager.t("下一页") + " ▶")


func _refresh() -> void:
	# ★ 背包数据源 = Inventory 物品 + Devices 设备（聚合展示为现实物品）。
	#   设备由 Devices 单例独立管理，不在 Inventory 里；勾选「现实物品」时本应看到它们。
	var base: Array = Inventory.get_sorted(_sort_by, _sort_asc)
	base.append_array(_devices_as_inventory_items())
	var all: Array = _apply_filter(base)
	_filtered_total = all.size()
	var total: int = _filtered_total
	var pages: int = _page_count()
	_page = clampi(_page, 0, pages - 1)
	var start_i: int = _page * PER_PAGE
	for i in range(PER_PAGE):
		var idx: int = start_i + i
		_fill_slot(_slots[i], idx if idx < total else -1, all)
	_page_label.text = "%d / %d" % [_page + 1, pages]
	_refresh_filter_toggle()
	_refresh_disk_meters()
	# ★ 内容（仓库读数 / 格子文字）会改变容器最小尺寸 → 这里必须重算面板尺寸。
	#   否则首次打开时面板是按「文本还空着」定的尺寸，偏小 → 背景比内容小（要第二次打开才正常）。
	_relayout()


# 筛选规则：
#   · 数字物品 / 现实物品 / 设备硬件 勾选项为「或」关系（都不勾 → 不过滤种类，全显示）。
#   · 「在回收站中」是**独占视图**：勾选后只显示带 in_recycle_bin 的物品，隐藏一切普通物品
#     （数字 / 现实 / 设备硬件 / 电脑文件 等）；取消勾选则恢复普通物品显示、回收站物品隐藏。
#   · 带 deleted（已删除）的物品必然同时带 in_recycle_bin；调试模式下勾选「已删除」
#     可把它们单独放出来查看（右键「恢复」可回到背包）。
func _apply_filter(items: Array) -> Array:
	var out: Array = []
	var any_kind: bool = _filter_digital or _filter_real or _filter_pc
	for it in items:
		var tags = it.get("tags", [])
		if not (tags is Array):
			continue
		var in_bin: bool = _tag_has(tags, Inventory.TAG_IN_RECYCLE)
		var deleted: bool = _tag_has(tags, Inventory.TAG_DELETED)
		var show: bool = true
		if in_bin:
			# 回收站物品：仅在勾选「在回收站中」时显示（或调试模式勾选「已删除」查看删除态）。
			if not _filter_recycle and not (deleted and _filter_deleted):
				show = false
		else:
			# 普通物品（数字 / 现实 / 设备硬件 / 电脑文件 等）：勾选「在回收站中」= 独占视图，
			# 隐藏一切普通物品，只留下回收站里的东西；取消勾选才恢复普通物品显示。
			if _filter_recycle:
				show = false
		if show and any_kind:
			var ok_kind: bool = false
			if _filter_digital and _tag_has(tags, Inventory.TAG_DIGITAL):
				ok_kind = true
			if _filter_real and _tag_has(tags, Inventory.TAG_REAL):
				ok_kind = true
			if _filter_pc and _tag_has(tags, Inventory.TAG_PC_HARDWARE):
				ok_kind = true
			if not ok_kind:
				show = false
		if show:
			out.append(it)
	return out


func _tag_has(tags: Array, tag: String) -> bool:
	for t in tags:
		if str(t) == tag:
			return true
	return false


## 把 Devices 里的整机设备（电脑 / 网络器材）转成背包风格的展示项。
## 它们**不是** Inventory 物品（不会被落盘 / 不会被回收 / 编辑 / 拖拽），只是聚合展示。
## 带 TAG_REAL → 勾选「现实物品」时自然显示；带 TAG_DEVICE + DEVICE_ID_PREFIX 前缀 →
## 右键 / 编辑 / 拖拽等背包操作对其一律跳过（见 _on_slot_gui_input / _open_item_menu / _open_edit_item）。
## Devices 未就绪（理论上不会，autoload 先于面板）→ 返回空数组，不影响原背包逻辑。
func _devices_as_inventory_items() -> Array:
	var out: Array = []
	if Devices == null:
		return out
	for dev in Devices.get_devices():
		if not (dev is Dictionary):
			continue
		var id := str(dev.get("id", ""))
		if id == "":
			continue
		var attrs: Dictionary = dev.get("attrs", {})
		if not (attrs is Dictionary):
			attrs = {}
		# 设备种类中文（电脑 / 交换机 / 路由器 …），缺省「设备」
		var kind: String = str(attrs.get("device_kind", ""))
		var cat := "设备"
		if kind != "":
			var kz: String = PCHardware.kind_zh(kind)
			if kz != "":
				cat = kz
		out.append({
			"id": DEVICE_ID_PREFIX + id,
			"name": str(dev.get("name", "")),
			"count": 1,
			"category": cat,
			"tags": [Inventory.TAG_REAL, TAG_DEVICE],
			"description": "",
			"attrs": attrs,
			"texture_path": "",
			"online": bool(dev.get("online", false)),
		})
	return out


func _fill_slot(slot: Control, idx: int, all: Array) -> void:
	var name_l: Label = slot.get_node("Name")
	var cat_l: Label = slot.get_node("Cat")
	var cnt_l: Label = slot.get_node("Count")
	var icon: TextureRect = slot.get_node("Icon") as TextureRect
	if idx < 0 or idx >= all.size():
		name_l.text = ""
		cat_l.text = ""
		cnt_l.text = ""
		if icon != null:
			icon.texture = null
			icon.visible = false
		cat_l.visible = true
		slot.set_meta("item_id", "")
		return
	var item: Dictionary = all[idx]
	name_l.text = str(item.get("name", ""))
	# 种类文字 + 数字物品的容量 / 需高速存储 标记
	var cat_txt := str(item.get("category", ""))
	var itags = item.get("tags", [])
	var iattrs: Dictionary = item.get("attrs", {})
	if iattrs is Dictionary:
		var cap: float = Inventory.size_gb_of_attrs(iattrs)
		if _tag_has(itags, Inventory.TAG_DIGITAL) and cap > 0.0:
			cat_txt += " · %sGB" % _fmt_gb(cap)
	if _tag_has(itags, Inventory.TAG_NEEDS_HIGH_SPEED_STORAGE):
		cat_txt += " · 需高速存储"
	cat_l.text = cat_txt
	cnt_l.text = "×%d" % int(item.get("count", 0))
	# 图标：有贴图就显示并让出中间区域（隐藏种类文字，避免叠在图上）；
	#       没贴图 / 路径无效 → 退回原来的纯文字样式。
	var tp := str(item.get("texture_path", ""))
	var tex: Texture2D = null
	if tp != "":
		tex = TextureCache.fetch(tp)
	if icon != null:
		icon.texture = tex
		icon.visible = (tex != null)
	cat_l.visible = (tex == null)
	slot.set_meta("item_id", str(item.get("id", "")))


func _page_count() -> int:
	return maxi(1, ceili(float(_filtered_total) / float(PER_PAGE)))


# ============================ 种类筛选：body 左栏侧栏（CheckBox 风格）============================
#
# 历史：SubMenu +「✓ 前缀文本」→ CheckBox 浮层（跨帧定尺 + 代际守卫 + 点外部关闭）
#       → 内嵌区块（物品栏**上方**）→ 内嵌区块（物品栏**左侧**，塞在 _content 里）
#       → 现为 **body 的第一个子节点**（与中列同层）。
# 现状：常驻 body 左栏；点「筛选」就地展开/收起。因为它与中列同层 + _relayout 以**中列**为锚，
#       展开时只让面板**向左**变宽，中列（物品栏/按钮）与右列（数据仓库）屏幕位置都不动。
# 观感对齐右侧「数据仓库」列：标题 + 内容 + 分隔线。
#
# 勾选项：数字物品 / 现实物品 / 设备硬件 / 在回收站中（常显）；已删除（仅调试模式 Debug.debug_mode）。

## 构建筛选侧栏（只建一次；显隐由 _set_filter_open 控制）。
## ★ 挂在 `body` 左栏（固定宽 FILTER_W）：勾选项 1 列、排序按钮竖排 → 窄栏也不挤。
func _build_filter_block() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "FilterBlock"
	box.add_theme_constant_override("separation", 6)
	box.custom_minimum_size = Vector2(FILTER_W, 0.0)
	box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	box.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	_filter_block_title = _make_label(TranslationManager.t("按种类筛选"), FORM_FONT, Color(0.75, 0.92, 1.0))
	box.add_child(_filter_block_title)

	_filter_checks_grid = GridContainer.new()
	_filter_checks_grid.name = "FilterChecks"
	_filter_checks_grid.columns = 1
	_filter_checks_grid.add_theme_constant_override("h_separation", 14)
	_filter_checks_grid.add_theme_constant_override("v_separation", 4)
	_filter_checks_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_filter_checks_grid)

	box.add_child(HSeparator.new())

	_filter_sort_title = _make_label(TranslationManager.t("排序"), FORM_FONT - 1, Color(0.72, 0.80, 0.95))
	box.add_child(_filter_sort_title)

	# 排序按钮**竖排**（左侧栏较窄，横排三个按钮文字会被压扁 / 裁掉）
	var srow := VBoxContainer.new()
	srow.name = "FilterSortRow"
	srow.add_theme_constant_override("separation", GRID_GAP)
	box.add_child(srow)
	for key in ["name", "count", "category"]:
		var b := UIBtn.new()
		b.set_id("sort_" + str(key))
		# ★ UIBtn 继承 BaseButton 且**不带默认尺寸**（最小尺寸为 0）→ 不显式给高度会被压成 0 高。
		b.custom_minimum_size = Vector2(0.0, BTN_H)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed_id.connect(_on_sort_btn_pressed)
		srow.add_child(b)
		_sort_btns[key] = b

	_rebuild_filter_checks()
	_refresh_sort_buttons()
	return box


## 重建勾选项网格：**只在「筛选」展开 / 语言切换时**调用（勾选本身不重建）。
## 需要重建是因为「已删除」项的有无取决于 Debug.debug_mode。
func _rebuild_filter_checks() -> void:
	if _filter_checks_grid == null or not is_instance_valid(_filter_checks_grid):
		return
	# ★ 重建容器务必 remove_child 再 queue_free，否则帧末前旧子节点仍在树里 → 同名新节点被自动改名。
	for ch in _filter_checks_grid.get_children():
		_filter_checks_grid.remove_child(ch)
		ch.queue_free()

	var kinds: Array = [
		{ "id": "digital", "tag": Inventory.TAG_DIGITAL, "zh": TranslationManager.t("数字物品"), "on": _filter_digital },
		{ "id": "real", "tag": Inventory.TAG_REAL, "zh": TranslationManager.t("现实物品"), "on": _filter_real },
		{ "id": "pc", "tag": Inventory.TAG_PC_HARDWARE, "zh": TranslationManager.t("设备硬件"), "on": _filter_pc },
		{ "id": "recycle", "tag": Inventory.TAG_IN_RECYCLE, "zh": TranslationManager.t("在回收站中"), "on": _filter_recycle },
	]
	if Debug.debug_mode:
		kinds.append({ "id": "deleted", "tag": Inventory.TAG_DELETED, "zh": TranslationManager.t("已删除"), "on": _filter_deleted })

	var fnt = UIStyle.get_cjk_font()
	for k in kinds:
		var kind: Dictionary = k
		var cell := HBoxContainer.new()
		cell.add_theme_constant_override("separation", 6)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# ★ bind() 的实参里**不能出现嵌套逗号**（会把静态实参个数审计脚本数错）→ 先取到局部变量
		var kid: String = str(kind.get("id", ""))
		var ck := CheckBox.new()
		ck.text = str(kind.get("zh", ""))
		ck.button_pressed = bool(kind.get("on", false))
		ck.add_theme_font_size_override("font_size", FORM_FONT)
		if is_instance_valid(fnt):
			ck.add_theme_font_override("font", fnt)
		ck.toggled.connect(_on_kind_toggled.bind(kid))
		cell.add_child(ck)
		var en := _make_label(str(kind.get("tag", "")), FORM_FONT - 2, Color(0.6, 0.68, 0.82))
		en.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		cell.add_child(en)
		_filter_checks_grid.add_child(cell)


## 刷新排序按钮文案（▲/▼ 标记）——就地改 label，不重建控件。
func _refresh_sort_buttons() -> void:
	for key in _sort_btns.keys():
		var b = _sort_btns[key]
		if b == null or not is_instance_valid(b):
			continue
		var arrow := "" if str(key) != _sort_by else (" ▲" if _sort_asc else " ▼")
		(b as UIBtn).set_label(str(_SORT_LABELS[key]) + arrow)


func _toggle_filter_block() -> void:
	_set_filter_open(not _filter_open)


## 展开 / 收起筛选侧栏。展开时重建勾选项（兜住调试模式切换）+ 刷新排序标记。
## 侧栏在 body 左栏 ⇒ 这里只需切 visible + _relayout（_relayout 只补偿左侧占位 → 中列/右列都不移位）。
func _set_filter_open(on: bool) -> void:
	_filter_open = on
	if _filter_block != null and is_instance_valid(_filter_block):
		if on:
			_rebuild_filter_checks()
			_refresh_sort_buttons()
		_filter_block.visible = on
	_refresh_filter_toggle()
	_relayout()


func _on_kind_toggled(on: bool, kind_id: String) -> void:
	match kind_id:
		"digital":
			_filter_digital = on
		"real":
			_filter_real = on
		"pc":
			_filter_pc = on
		"recycle":
			_filter_recycle = on
		"deleted":
			_filter_deleted = on
	_page = 0
	_refresh()


# 排序按钮：换排序键 / 切升降序；**就地刷新 ▲▼ 文案**（不再重建任何控件）
func _on_sort_btn_pressed(id: String) -> void:
	var key: String = str(id).replace("sort_", "")
	if key == _sort_by:
		_sort_asc = not _sort_asc
	else:
		_sort_by = key
		_sort_asc = true
	_page = 0
	_refresh()
	_refresh_sort_buttons()


func _refresh_filter_toggle() -> void:
	if _filter_btn != null and is_instance_valid(_filter_btn):
		var arrow := " ▴" if _filter_open else " ▾"
		_filter_btn.set_label(TranslationManager.t("筛选") + arrow)


## 右侧「数据仓库」栏：标题（展开/折叠按钮已挪到左列「筛选」行）+ 可折叠主体
##   （分隔线 + 机械/固态两条数值栏 + 统计口径提示 + 「文件搬迁」按钮）。
func _build_disk_column() -> VBoxContainer:
	var col := VBoxContainer.new()
	col.name = "DiskColumn"
	col.add_theme_constant_override("separation", 10)
	col.custom_minimum_size = Vector2(DISK_W, 0.0)
	col.size_flags_horizontal = Control.SIZE_SHRINK_END
	col.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	# 标题行：只剩标题（「展开 / 折叠」按钮已挪到左列「筛选」行最右端，见 _build_ui）
	var title_row := HBoxContainer.new()
	title_row.name = "DiskTitleRow"
	title_row.add_theme_constant_override("separation", 6)
	_disk_title = _make_label(TranslationManager.t("数据仓库"), 16, Color(0.88, 0.94, 1.0))
	_disk_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_disk_title)
	col.add_child(title_row)
	_disk_title_row = title_row

	# 可折叠主体
	_disk_body = VBoxContainer.new()
	_disk_body.name = "DiskBody"
	_disk_body.add_theme_constant_override("separation", 10)
	col.add_child(_disk_body)
	_disk_body.add_child(HSeparator.new())

	# ★ 顺序固定：机械在上、固态在下
	for pair in [["hdd", "机械硬盘"], ["ssd", "固态硬盘"]]:
		var key := str(pair[0])
		var m := DiskMeter.new()
		m.setup(TranslationManager.t(str(pair[1])))
		_disk_body.add_child(m)
		_disk_meters[key] = m

	_disk_hint = _make_label("", 10, Color(0.74, 0.80, 0.92, 0.95))
	_disk_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_disk_body.add_child(_disk_hint)

	# 「文件搬迁」：重新计算所有数字物品的落盘位置（机械优先装满，溢出到固态）
	var migrate_btn := UIBtn.new()
	migrate_btn.set_id("migrate_storage")
	migrate_btn.set_label(TranslationManager.t("文件搬迁"))
	migrate_btn.custom_minimum_size = Vector2(0.0, BTN_H)
	migrate_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	migrate_btn.pressed_id.connect(_on_btn_pressed)
	_disk_body.add_child(migrate_btn)
	return col


## 展开 / 折叠「数据仓库」：折叠时**整列收起**（标题 + 主体一起隐藏，面板随之收窄），
## 只剩左列「筛选」行右端的「展开」按钮作为再展开入口。
## ★★ 连 `_disk_col` 本身一起隐藏：只藏内部子节点的话，它仍算 `body` 的一个子节点 →
##    HBox 仍会为它留一份 separation，面板右缘就比物品栏右缘多出 12px，看起来「离得太远」。
func _set_disk_expanded(on: bool) -> void:
	_disk_expanded = on
	if _disk_body != null and is_instance_valid(_disk_body):
		_disk_body.visible = on
	# ★ 「数据仓库」标题也必须跟着收起：以前只隐藏主体，标题残留 → 用户看到「文本没有正确折叠」。
	#   标题行隐藏后 _disk_col 的最小宽度归 0（叠加 _relayout 的 custom_minimum_size=0）→ 面板收窄。
	if _disk_title_row != null and is_instance_valid(_disk_title_row):
		_disk_title_row.visible = on
	if _disk_col != null and is_instance_valid(_disk_col):
		_disk_col.visible = on
	if _disk_toggle_btn != null and is_instance_valid(_disk_toggle_btn):
		_disk_toggle_btn.set_label(TranslationManager.t("折叠") if on else TranslationManager.t("展开"))
	_relayout()


## 右侧「数据仓库」读数：总容量取**在线设备**合计，已使用取背包数字物品占用
## （归属见 Inventory.used_storage_gb：`attrs.disk` 优先，「需高速存储」标签兜底）。
## 剩余 = max(0, 总 − 已用)；使用率 > 90% → 条与读数变红（见 DiskMeter）。
func _refresh_disk_meters() -> void:
	if _disk_title != null:
		_disk_title.text = TranslationManager.t("数据仓库")
	if _disk_toggle_btn != null and is_instance_valid(_disk_toggle_btn):
		_disk_toggle_btn.set_label(TranslationManager.t("折叠") if _disk_expanded else TranslationManager.t("展开"))
	var total: Dictionary = Devices.total_storage_capacity()
	var used: Dictionary = Inventory.used_storage_gb()
	var over := 0.0
	var sum_used := 0.0
	for key in ["hdd", "ssd"]:
		var m = _disk_meters.get(key, null)
		if m == null or not is_instance_valid(m):
			continue
		var t: float = maxf(0.0, float(total.get(key, 0)))
		var u: float = maxf(0.0, float(used.get(key, 0)))
		sum_used += u
		(m as DiskMeter).set_values(u, maxf(0.0, t - u), t,
			TranslationManager.t("机械硬盘" if key == "hdd" else "固态硬盘"))
		if u > t:
			over += u - t
	if _disk_hint != null:
		if over > 0.0:
			_disk_hint.text = "⚠ " + TranslationManager.t("容量不足，超出 %sGB（可点「文件搬迁」重排）" % _fmt_gb(over))
			_disk_hint.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
		else:
			_disk_hint.text = TranslationManager.t("口径：容量取【在线】设备合计；已使用 = 背包数字物品「文件大小」×数量（需高速存储的算固态）")
			_disk_hint.add_theme_color_override("font_color", Color(0.74, 0.80, 0.92, 0.95))


## GB 数值显示：整数不带小数，否则保留两位（0.01GB 精度）
func _fmt_gb(v: float) -> String:
	if absf(v - roundf(v)) < 0.005:
		return str(int(roundf(v)))
	return "%.2f" % v


## 「文件搬迁」：把可搬的数字物品重新分配到机械硬盘（机械优先装满，溢出到固态）。
func _migrate_storage() -> void:
	var r: Dictionary = Inventory.migrate_storage()
	var moved: int = int(r.get("moved", 0))
	if moved <= 0:
		_toast(TranslationManager.t("文件搬迁：没有需要移动的文件（机械已按容量装满）"))
	else:
		_toast(TranslationManager.t("文件搬迁：%d 个文件已重新分配 · 机械 %sGB / 固态 %sGB" % [
			moved, _fmt_gb(float(r.get("hdd", 0.0))), _fmt_gb(float(r.get("ssd", 0.0)))]))
	_refresh()


## 设备列表行：**批次 30 起取消**。
## 原来把「设备：A、B、…（共 N）」写在一行 Label 上，而该 Label 的文本长度会顶宽整个中列
## （`_content` 最小宽度 498 → 561），把面板 / 四个按钮 / 格子宽度全带偏。现该行已从布局移除。
## 需要看背包里有哪些设备时走设备管理页（双击桌面「设备管理」积木）。


# 左键点面板空白处 → 收起右键菜单。
# ★ 必须**先判断落点是否在自己的矩形内**：菜单是本面板的子节点，点它内部同样会冒泡到本面板；
#   若不排除，点菜单条目会先把菜单关掉，条目永远点不到。
# ★ 「筛选」现在是**内嵌区块**（不是浮层）→ 不再有点外部自动关闭的逻辑。
func _on_panel_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var gp: Vector2 = get_global_mouse_position()
	if _ctx_menu != null and is_instance_valid(_ctx_menu) and _ctx_menu.is_open():
		var cr := Rect2(_ctx_menu.global_position, _ctx_menu.size)
		if not cr.has_point(gp):
			_close_item_menu()


# ============================ 按钮 ============================

func _on_btn_pressed(id: String) -> void:
	match id:
		"close":
			close()   # 真正隐藏面板（close() 内部会发 closed 信号）
		"filter_toggle":
			_toggle_filter_block()
		"prev":
			var pages: int = _page_count()
			_page = (_page - 1 + pages) % pages
			_refresh()
		"next":
			var pages: int = _page_count()
			_page = (_page + 1) % pages
			_refresh()
		"disk_toggle":
			_set_disk_expanded(not _disk_expanded)
		"migrate_storage":
			_migrate_storage()


# ============================ 物品右键菜单 ============================

## 右键物品格 → 展开右键菜单。条目按物品状态变化：
##   · 打开编辑物品界面 —— 仅调试模式（Debug.debug_mode）可见。
##   · 移入回收站      —— 常显；给**数字物品**加 in_recycle_bin 标签，
##                        带 undeletable（不可删除）标签的物品被跳过。
##   · 恢复            —— 已在回收站的物品：去掉 in_recycle_bin
##                        （若带 deleted 一并去掉 → 回到背包常态视图）。
##   · 彻底删除        —— 已在回收站且尚未删除：加 deleted 标签（**软删除**，不是真删除）。
func _open_item_menu(item_id: String) -> void:
	if item_id == "":
		return
	_close_item_menu()
	var items: Array = _build_item_menu_items(item_id)
	if items.is_empty():
		return

	var menu := ContextMenu.new()
	add_child(menu)
	menu.item_selected.connect(_on_item_menu_selected.bind(item_id))
	_ctx_menu = menu
	menu.open(get_global_mouse_position(), items)


## 按物品当前状态决定右键菜单条目（纯函数，便于探针直接断言）：
##   · 调试模式                       → 「打开编辑物品界面」
##   · 已在回收站（in_recycle_bin）   → 「恢复」；未 deleted 时再给「彻底删除」
##   · 否则（常态物品）               → 「移入回收站」
func _build_item_menu_items(item_id: String) -> Array:
	var it: Dictionary = Inventory.get_item(item_id)
	if it.is_empty():
		return []
	var tags = it.get("tags", [])
	if not (tags is Array):
		tags = []
	var in_bin: bool = _tag_has(tags, Inventory.TAG_IN_RECYCLE)
	var deleted: bool = _tag_has(tags, Inventory.TAG_DELETED)
	var undeletable: bool = _tag_has(tags, Inventory.TAG_UNDELETABLE)

	var items: Array = []
	if Debug.debug_mode:
		items.append({ "label": TranslationManager.t("打开编辑物品界面"), "id": "edit" })
	# 不可删除：只保留查看入口，不提供回收站 / 彻底删除
	if undeletable:
		return items
	if in_bin:
		items.append({ "label": TranslationManager.t("恢复"), "id": "restore" })
		if not deleted:
			items.append({ "label": TranslationManager.t("彻底删除"), "id": "soft_delete" })
	else:
		items.append({ "label": TranslationManager.t("移入回收站"), "id": "to_recycle" })
	return items


func _close_item_menu() -> void:
	if _ctx_menu != null and is_instance_valid(_ctx_menu):
		_ctx_menu.close()
		_ctx_menu = null


func _on_item_menu_selected(id: String, _full_path: PackedStringArray, item_id: String) -> void:
	match id:
		"edit":
			_open_edit_item(item_id)
		"to_recycle":
			_recycle_item(item_id)
		"restore":
			_restore_item(item_id)
		"soft_delete":
			_soft_delete_item(item_id)


## 移入回收站：数字物品加 in_recycle_bin；undeletable（不可删除）则跳过。
func _recycle_item(item_id: String) -> void:
	if Inventory.has_tag(item_id, Inventory.TAG_UNDELETABLE):
		_toast(TranslationManager.t("该物品不可删除（带 undeletable 标签）"))
		return
	if not Inventory.has_tag(item_id, Inventory.TAG_DIGITAL):
		_toast(TranslationManager.t("只有数字物品可移入回收站"))
		return
	Inventory.add_tag(item_id, Inventory.TAG_IN_RECYCLE)
	_refresh()


## 恢复：去掉 deleted（若有）+ in_recycle_bin → 物品回到背包常态视图。
func _restore_item(item_id: String) -> void:
	Inventory.remove_tag(item_id, Inventory.TAG_DELETED)
	Inventory.remove_tag(item_id, Inventory.TAG_IN_RECYCLE)
	_refresh()


## 彻底删除（软删除）：只加 deleted 标签，**不真正移除**。不可删除物品直接跳过。
func _soft_delete_item(item_id: String) -> void:
	if Inventory.has_tag(item_id, Inventory.TAG_UNDELETABLE):
		_toast(TranslationManager.t("该物品不可删除（带 undeletable 标签）"))
		return
	Inventory.add_tag(item_id, Inventory.TAG_DELETED)
	_refresh()


## 面板底部短暂提示（1.6 秒自动消失）
func _toast(text: String) -> void:
	var t := _make_label(text, FORM_FONT, Color(1.0, 0.85, 0.45, 1.0))
	t.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	t.offset_top = -30.0
	t.offset_bottom = -8.0
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(t)
	var timer := Timer.new()
	timer.wait_time = 1.6
	timer.one_shot = true
	timer.timeout.connect(func():
		if is_instance_valid(t):
			t.queue_free()
	)
	add_child(timer)
	timer.start()


# ============================ 物品拖拽放置 ============================

func _on_slot_gui_input(event: InputEvent, slot: Control) -> void:
	if _dragging_item:
		return
	# 右键物品格 → 展开右键菜单；右键空栏（调试模式）→ 直接打开新建物品面板
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		var item_id: String = str(slot.get_meta("item_id", "")) if (slot != null and is_instance_valid(slot)) else ""
		# ★ 设备展示项只读：不弹背包右键菜单（设备管理页才是其操作入口）
		if item_id != "" and not item_id.begins_with(DEVICE_ID_PREFIX):
			_open_item_menu(item_id)
		elif item_id == "" and Debug.debug_mode:
			_open_edit_item("")
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if slot == null or not is_instance_valid(slot):
			return
		var item_id: String = str(slot.get_meta("item_id", ""))
		if item_id == "":
			return
		# ★ 设备展示项不可拖拽生成积木（拖了也不会落桌，见 _drop_item_at 对未知 id 的处理）
		if item_id.begins_with(DEVICE_ID_PREFIX):
			get_viewport().set_input_as_handled()
			return
		_begin_item_drag(slot, item_id)
		get_viewport().set_input_as_handled()


func _begin_item_drag(slot: Control, item_id: String) -> void:
	_dragging_item = true
	_drag_item_id = item_id
	_drag_ghost = _make_ghost(slot)
	add_child(_drag_ghost)
	_drag_ghost.global_position = get_global_mouse_position() - Vector2(SLOT_SIZE * 0.5, SLOT_SIZE * 0.5)
	set_process(true)
	print("[InventoryPanel] 开始拖拽物品: %s" % item_id)


func _make_ghost(slot: Control) -> Control:
	var g := Control.new()
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	g.size = Vector2(SLOT_SIZE, SLOT_SIZE)

	var sp := UIPanel.new()
	sp.set_anchors_preset(Control.PRESET_FULL_RECT)
	sp.set_corner_radius(UIStyle.CORNER_RADIUS * 0.6)
	sp.set_fill_color(Color(UIStyle.FILL_DEFAULT.r, UIStyle.FILL_DEFAULT.g, UIStyle.FILL_DEFAULT.b, 0.55))
	sp.set_border_color(UIStyle.BORDER)
	sp.set_border_width(1.0)
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.add_child(sp)

	# 拖拽残影：有贴图就跟着显示图标，否则退回原来的「名称首字」兜底
	var src_icon: TextureRect = slot.get_node("Icon") as TextureRect
	if src_icon != null and src_icon.visible and src_icon.texture != null:
		var gi := TextureRect.new()
		gi.set_anchors_preset(Control.PRESET_FULL_RECT)
		gi.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		gi.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		gi.texture = src_icon.texture
		gi.mouse_filter = Control.MOUSE_FILTER_IGNORE
		g.add_child(gi)
	else:
		var ph := _make_label("", 28, Color.WHITE)
		ph.set_anchors_preset(Control.PRESET_CENTER)
		ph.text = str(slot.get_node("Name").text).substr(0, 1) if str(slot.get_node("Name").text) != "" else "?"
		g.add_child(ph)
	return g


func _process(_delta: float) -> void:
	if not _dragging_item or _drag_ghost == null:
		return
	_drag_ghost.global_position = get_global_mouse_position() - Vector2(SLOT_SIZE * 0.5, SLOT_SIZE * 0.5)


func _input(event: InputEvent) -> void:
	if not _dragging_item:
		return
	if event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_end_item_drag()
		get_viewport().set_input_as_handled()


func _end_item_drag() -> void:
	_dragging_item = false
	set_process(false)
	if _drag_ghost != null and is_instance_valid(_drag_ghost):
		_drag_ghost.queue_free()
	_drag_ghost = null

	var item_id: String = _drag_item_id
	_drag_item_id = ""
	if item_id == "":
		return
	_drop_item_at(item_id, get_global_mouse_position())


## 在 mouse（ui_layer 画布坐标）处松手放下物品。
## 返回 place_inventory_item 的结果串；返回 "" = 根本没发生放置
## （落回面板内 / 物品不存在 / 不可构建）→ 数量不变。
## ★ 「判定 + 派发」集中在这里，`_end_item_drag()` 只做收尾（清残影、恢复状态）
##   再把手里的鼠标位置交给它 —— 落点由调用方给出，逻辑本身与鼠标无关。
func _drop_item_at(item_id: String, mouse: Vector2) -> String:
	# 落在面板矩形内 → 视为取消（拖回），不消耗
	if get_global_rect().has_point(mouse):
		print("[InventoryPanel] 拖拽取消（落回面板）: %s" % item_id)
		return ""

	var item: Dictionary = Inventory.get_item(item_id)
	if item.is_empty():
		return ""
	# ★★ 是否可构建由 Inventory.build_info() 独家判定：物品必须带「数字物品」标签
	#    且含「构建」变量（attrs.build / 旧式 构建_XXX{} 标签）。
	#    非数字物品即便有 build 变量 → 不生成积木、数量也不减（这里直接返回）。
	var info := Inventory.build_info(item)
	if not info.ok:
		print("[InventoryPanel] 物品不可构建（%s），仅拖出未生成: %s" % [str(info.reason), item_id])
		return ""

	var desktop = get_tree().current_scene
	if desktop == null or not desktop.has_method("place_inventory_item"):
		push_warning("[InventoryPanel] 主场景缺少 place_inventory_item，放置取消")
		return ""
	var res: String = desktop.place_inventory_item(item_id, str(info.type), str(info.modifiers), mouse)
	print("[InventoryPanel] 放置结果: " + res)
	_refresh()   # 数量已减一（未生成积木时 place_inventory_item 也不会减，_refresh 只是同步显示）
	return res


# ============================ 编辑物品面板（右键）============================

## 调试模式下右键背包物品 / 空栏打开编辑物品面板。
## item_id 为空 = 新建（id 可填）；否则载入该物品数据（id 锁定）。
func _open_edit_item(item_id: String) -> void:
	# ★ 设备展示项是只读聚合，不是 Inventory 物品：编辑面板不能载入 / 落盘它，
	#   否则会在背包凭空造出一个 DEVICE_ID_PREFIX 开头的假物品。
	if item_id.begins_with(DEVICE_ID_PREFIX):
		return
	# 已开一个 → 先关掉再开新的
	if _edit_panel != null and is_instance_valid(_edit_panel):
		_edit_panel.queue_free()
		_edit_panel = null
	var layer = get_parent()
	if layer == null or not (layer is CanvasLayer):
		layer = get_tree().current_scene
	var panel := EditItemPanel.new()
	layer.add_child(panel)
	_edit_panel = panel
	panel.closed.connect(_on_edit_panel_closed)
	panel.applied.connect(_on_edit_panel_applied)
	panel.template_saved.connect(_on_edit_panel_template_saved)
	var item: Dictionary = {}
	if item_id != "":
		item = Inventory.get_item(item_id)
	panel.open(item, item_id)


func _on_edit_panel_closed() -> void:
	_close_edit_panel()


func _on_edit_panel_applied(item: Dictionary) -> void:
	if item.is_empty():
		return
	Inventory.apply_item(item)
	_refresh()


func _on_edit_panel_template_saved(_id: String) -> void:
	# 模板已落盘到 res://items_types/；面板保持打开，方便继续编辑
	pass


func _close_edit_panel() -> void:
	if _edit_panel != null and is_instance_valid(_edit_panel):
		_edit_panel.queue_free()
		_edit_panel = null


# ============================ 「数据仓库」条状数值栏 ============================
#
# 一条数值栏 = 标题（机械硬盘 / 固态硬盘）+ 自绘进度条 + 一行三个读数：
#   左下「已使用 xxxGB」 · 中间「剩余 xxxGB」 · 右侧「总容量 xxxGB」
# 已使用部分画成绿色；使用率 > 90% 时整条与「已使用」读数变红（只做状态示意，不追求精度）。

class _MeterBar extends Control:
	const BAR_H := 14.0
	const TRACK_COLOR := Color(0.13, 0.17, 0.23, 0.92)    # 槽底色
	const BORDER_COLOR := Color(0.42, 0.52, 0.64, 0.95)   # 描边
	const FILL_OK := Color(0.30, 0.85, 0.40)              # 已使用 ≤ 90%：绿
	const FILL_WARN := Color(0.92, 0.30, 0.30)            # 已使用 > 90%：红
	const MIN_FILL_W := 3.0                               # 有一点点占用也画得出来

	var ratio: float = 0.0     # 已使用占比 0..1
	var warn: bool = false

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		if w <= 0.0 or h <= 0.0:
			return
		draw_rect(Rect2(0.0, 0.0, w, h), TRACK_COLOR, true)
		draw_rect(Rect2(0.0, 0.0, w, h), BORDER_COLOR, false, 1.0)
		var r: float = clampf(ratio, 0.0, 1.0)
		if r <= 0.0:
			return
		var inner_w: float = maxf(0.0, w - 2.0)
		var fw: float = clampf(inner_w * r, minf(MIN_FILL_W, inner_w), inner_w)
		draw_rect(Rect2(1.0, 1.0, fw, maxf(0.0, h - 2.0)), FILL_WARN if warn else FILL_OK, true)


class DiskMeter extends VBoxContainer:
	const WARN_RATIO := 0.9    # 使用率超过这个值 → 变红

	var used_gb: float = 0.0
	var remain_gb: float = 0.0
	var total_gb: float = 0.0
	var ratio: float = 0.0

	var _name_l: Label = null
	var _used_l: Label = null
	var _remain_l: Label = null
	var _total_l: Label = null
	var _bar: _MeterBar = null

	## 建结构。disk_name 走参数传入（语言切换时由 set_values 再刷一次）。
	func setup(disk_name: String) -> void:
		add_theme_constant_override("separation", 4)
		_name_l = _mk_label(disk_name, 13, Color(0.86, 0.92, 1.0))
		add_child(_name_l)

		_bar = _MeterBar.new()
		_bar.custom_minimum_size = Vector2(0.0, _MeterBar.BAR_H)
		_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_bar)

		# 一行三读数：左 = 已使用 / 中 = 剩余 / 右 = 总容量
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		_used_l = _mk_label("", 10, Color(0.80, 0.88, 0.98))
		_remain_l = _mk_label("", 10, Color(0.74, 0.82, 0.93))
		_total_l = _mk_label("", 10, Color(0.88, 0.94, 1.0))
		_used_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		_remain_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_total_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		for l in [_used_l, _remain_l, _total_l]:
			(l as Label).size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(_used_l)
		row.add_child(_remain_l)
		row.add_child(_total_l)
		add_child(row)
		set_values(0.0, 0.0, 0.0, disk_name)

	## 刷新数值与配色。disk_name 非空时同时刷新标题（供语言切换复用）。
	func set_values(used: float, remain: float, total: float, disk_name: String = "") -> void:
		used_gb = used
		remain_gb = remain
		total_gb = total
		# 总容量为 0 时：没有占用 → 空条；有占用 → 视为爆满（红）
		if total > 0.0:
			ratio = clampf(used / total, 0.0, 1.0)
		else:
			ratio = 1.0 if used > 0.0 else 0.0
		if disk_name != "" and _name_l != null:
			_name_l.text = disk_name
		var warn: bool = ratio > WARN_RATIO
		if _used_l != null:
			_used_l.text = "%s %sGB" % [TranslationManager.t("已使用"), _fmt(used_gb)]
			_used_l.add_theme_color_override("font_color",
				(_MeterBar.FILL_WARN if warn else Color(0.80, 0.88, 0.98)))
		if _remain_l != null:
			_remain_l.text = "%s %sGB" % [TranslationManager.t("剩余"), _fmt(remain_gb)]
		if _total_l != null:
			_total_l.text = "%s %sGB" % [TranslationManager.t("总容量"), _fmt(total_gb)]
		if _name_l != null:
			_name_l.add_theme_color_override("font_color",
				(_MeterBar.FILL_WARN if warn else Color(0.86, 0.92, 1.0)))
		if _bar != null and is_instance_valid(_bar):
			_bar.ratio = ratio
			_bar.warn = warn
			_bar.queue_redraw()

	## GB 数值：整数不带小数，否则两位小数（文件大小可精确到 0.01GB）
	static func _fmt(v: float) -> String:
		if absf(v - roundf(v)) < 0.005:
			return str(int(roundf(v)))
		return "%.2f" % v

	## 小工具：内层类不能调外层实例方法，这里自带一份建 Label 的逻辑。
	static func _mk_label(text: String, font_size: int, color: Color) -> Label:
		var l := Label.new()
		l.text = text
		l.add_theme_color_override("font_color", color)
		l.add_theme_font_size_override("font_size", font_size)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var fnt := UIStyle.get_cjk_font()
		if is_instance_valid(fnt):
			l.add_theme_font_override("font", fnt)
		return l

## 最小化 / 还原：折叠只隐藏内容，顶栏（标题 + 拖动把柄 + 最小化 + 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	# ★★ 顺序要紧：**先折叠、再改尺寸**。
	#   本页主体是三列：左「按种类筛选」侧栏 | 中列 `_content` | 右「数据仓库」，都挂在 `_body` 下。
	#   三列并排的**最小宽（≈1036）比面板本身（834）还大** → 若先算尺寸，外层 MarginContainer
	#   会被自己的最小宽顶住、根本缩不下去，顶栏按钮随之漂到边框外（探针实测 BTN_DRIFT_X 304）。
	#   先把正文折掉，容器最小宽随之塌回标题行宽，尺寸才算得准。
	#   `_content` 是侧栏/数据仓库的**兄弟**（不在它内部）→ 必须单独再折一层，只折内层会漏。
	if is_instance_valid(_body) and is_instance_valid(_content):
		UIMinimize.fold_below(_content, v)
	UIMinimize.apply(self, _min_btn, v, _min_btn.get_parent() if is_instance_valid(_min_btn) else null)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
