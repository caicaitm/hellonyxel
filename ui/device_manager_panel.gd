# ui/device_manager_panel.gd
# 设备管理页 —— 管理多台设备（电脑）。仿照「此电脑」积木的入口，双击「设备管理」积木打开。
#
# 数据全在 Devices 单例（devices.json）；本面板只做展示与操作：
#   · 左列列出所有设备，点击选中；顶部「新建设备」先选外壳再建空设备。
#   · 右详情：命名输入框 + 重命名按钮、上线/下线开关、拆解按钮（确认后零件退回背包）。
#   · 实时属性：占用功率（在线设备）/ 散热 / 算力 / 容量 / 在线 / 告警。
#   · 各槽位：安装 / 替换 / 移除，安装从背包备件里取一份内嵌进设备（并扣减背包）。
#
# 入口：desktop.open_device_manager()
extends Control
class_name DeviceManagerPanel

signal closed

const PADDING := 12.0
const FORM_FONT := 13
const TITLE_FONT := 15
const BTN_H := 26.0
const LIST_W := 240.0
const STATS_W := 190.0
const PANEL_W := 1000.0
const PANEL_H := 660.0

# 「插槽」区：按槽位类型分行（每类独占一排，排首是类型名标签，格内只显示零件名称）
const SLOT_MAX_PER_ROW := 5      # 一排最多放几格；某类槽位超过这个数时，该类自己续排到下一排
const SLOT_LABEL_W := 52.0       # 排首类型名标签宽度（续排用等宽空白占位，保持格子对齐）
const SLOT_CELL_W := 86.0
const SLOT_CELL_H := 44.0
# ★ 「对外接口」那一行（只读）：主板自带 + 已装外设卡提供的对外口，按种类列成格子。
#   外设卡（USB 3.0 扩展卡 / Type-C 扩展卡 / 网口卡）装进「外设」槽后，这里的格子会随之变多。
const PORT_BORDER := Color(0.42, 0.86, 0.98)   # 与普通槽位（浅色边）/ 拓展接口（黄色边）都区分开
# ★ 「已链接设备」格子：绿色边框 —— 表示该口已经连上了某台设备。
const LINK_BORDER := Color(0.45, 0.95, 0.60)

# 插槽展示顺序：先「外壳」提供的槽位（主板 / 电源 / 散热），再「主板」提供的槽位
# （CPU / 显卡 / 内存 / 存储 / 网卡 / 外设）。每类独占一排。
# ★ 没有「拓展」槽位：转接卡 / 拓展坞 / 显卡坞按规格+协议插进上面的普通槽位。
const SLOT_ORDER: Array[String] = [
	PCHardware.SLOT_MAINBOARD, PCHardware.SLOT_PSU, PCHardware.SLOT_COOLER,
	PCHardware.SLOT_CPU, PCHardware.SLOT_GPU, PCHardware.SLOT_MEMORY,
	PCHardware.SLOT_STORAGE, PCHardware.SLOT_NIC, PCHardware.SLOT_PERIPHERAL,
]
# ★ 拓展接口（转接卡/拓展坞/显卡坞提供的槽位）用黄色边框，与普通接口区分
const DOCK_BORDER := Color(0.98, 0.82, 0.25)

var _bg: UIPanel
var _content: VBoxContainer
var _title: Label
var _drag_handle: UIDragHandle
var _close_btn: UIBtn

var _list_container: DeviceListBox      # 左侧设备列表（动态重建，支持拖动排序）
var _new_btn: UIBtn                    # 新建设备
var _perf_inner: VBoxContainer         # 上方区域「设备性能」（可滚动）
var _slot_inner: VBoxContainer         # 下方区域「插槽」（可滚动，仿背包格子）
var _stats_col: VBoxContainer          # 右侧总览统计栏（所有设备的总功耗 / 总算力）

var _name_edit: LineEdit = null        # 命名输入框
var _online_btn: UIBtn = null          # 上线/下线

var _selected_id: String = ""
var _drag_row: DeviceRow = null        # 正在拖动的行（手动拖动排序，见 _on_row_drag_start）
var _drop_gap: int = -1                # 拖动时的插入**缝隙**索引（0..n，n=末尾；-1=不显示）
var _refresh_queued := false           # 延迟刷新合并标志（见 _request_refresh）
var _picker: Control = null            # 安装选择器弹层
var _picker_gen: int = 0
var _confirm: Control = null           # 拆解确认弹层
var _ctx_menu: ContextMenu = null      # 插槽格右键菜单
var _dev_menu: ContextMenu = null      # ★ 设备列表行右键菜单（上线 / 下线）
## ★ 配置草稿：dev_id -> { 槽位键: 内嵌零件 dict }。
## 安装 / 替换 / 卸下都只改草稿，点「应用并保存」才写进设备（并联动背包）。
## 按设备分别保存草稿，切换设备不会丢掉未保存的更改。
var _drafts := {}

var _fnt = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	if not TranslationManager.language_changed.is_connected(_on_lang_changed):
		TranslationManager.language_changed.connect(_on_lang_changed)
	if not Devices.changed.is_connected(_on_devices_changed):
		Devices.changed.connect(_on_devices_changed)
	if not Inventory.changed.is_connected(_on_inventory_changed):
		Inventory.changed.connect(_on_inventory_changed)
	visible = false



# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build_ui() -> void:
	_fnt = UIStyle.get_cjk_font()

	_bg = UIPanel.new()
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
	_content.add_theme_constant_override("separation", 8)
	margin.add_child(_content)

	# 顶栏
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	_title = _label("", TITLE_FONT, Color.WHITE)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_title)
	_drag_handle = UIDragHandle.new()
	top.add_child(_drag_handle)
	_drag_handle.setup(self)
	_close_btn = _btn("×", "close")
	_close_btn.custom_minimum_size = Vector2(28, 28)
	_min_btn = UIMinimize.attach(top, func(): set_minimized(not _minimized))
	top.add_child(_close_btn)
	_content.add_child(top)

	# 主体：左列（设备列表） | 中（详情） | 右（总览统计）
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(body)

	var h := HSplitContainer.new()
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.size_flags_vertical = Control.SIZE_EXPAND_FILL
	h.split_offset = int(LIST_W)
	body.add_child(h)

	# 左列：新建设备按钮 + 设备列表（滚动）
	var list_col := VBoxContainer.new()
	list_col.add_theme_constant_override("separation", 6)
	list_col.custom_minimum_size = Vector2(LIST_W, 0)
	list_col.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	h.add_child(list_col)

	_new_btn = _btn(TranslationManager.t("新建设备"), "new")
	_new_btn.custom_minimum_size = Vector2(LIST_W - 8, BTN_H)
	_new_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_col.add_child(_new_btn)

	var list_sc := ScrollContainer.new()
	list_sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list_col.add_child(list_sc)
	_list_container = DeviceListBox.new()
	_list_container.add_theme_constant_override("separation", 4)
	_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_sc.add_child(_list_container)

	# 中间竖排两块区域：上「设备性能」/ 下「插槽」（各自可滚动）
	# ★ 整块「设备信息」区加深色背景（与右侧「总览」一致：FILL_LEVEL_STAGE + STAGE_BORDER）。
	#   用 PanelContainer（真·容器，会上报最小尺寸）承载，避免 UIPanel 直接挂 VBox 被压 0 高。
	var mid_panel := PanelContainer.new()
	var mid_sb := StyleBoxFlat.new()
	mid_sb.bg_color = UIStyle.FILL_LEVEL_STAGE
	mid_sb.border_color = UIStyle.STAGE_BORDER
	mid_sb.set_border_width_all(1)
	mid_sb.set_corner_radius_all(int(UIStyle.CORNER_RADIUS * 0.6))
	mid_sb.content_margin_left = 10.0
	mid_sb.content_margin_right = 10.0
	mid_sb.content_margin_top = 8.0
	mid_sb.content_margin_bottom = 8.0
	mid_panel.add_theme_stylebox_override("panel", mid_sb)
	mid_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	h.add_child(mid_panel)

	var mid := VBoxContainer.new()
	mid.add_theme_constant_override("separation", 10)
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid_panel.add_child(mid)

	# 上：设备性能
	var perf_sc := ScrollContainer.new()
	perf_sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	perf_sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	perf_sc.size_flags_stretch_ratio = 0.42
	mid.add_child(perf_sc)
	_perf_inner = VBoxContainer.new()
	_perf_inner.add_theme_constant_override("separation", 8)
	_perf_inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# ★ 垂直方向不要 EXPAND：保持「用自身最小高度」，内容超出 perf_sc 视口时才出滚动条
	#   （否则 EXPAND 把 inner 拉满视口，永远不溢出 → 永远不滚，底部文字被挡）。
	_perf_inner.size_flags_vertical = Control.SIZE_FILL
	perf_sc.add_child(_perf_inner)

	# 下：插槽（仿背包格子的网格）
	var slot_sc := ScrollContainer.new()
	slot_sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slot_sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	slot_sc.size_flags_stretch_ratio = 0.58
	mid.add_child(slot_sc)
	_slot_inner = VBoxContainer.new()
	_slot_inner.add_theme_constant_override("separation", 6)
	_slot_inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slot_sc.add_child(_slot_inner)

	# 右侧总览统计栏：所有设备的总功耗 / 总算力（设备增删改或上下线时重算）
	_stats_col = VBoxContainer.new()
	_stats_col.add_theme_constant_override("separation", 6)
	_stats_col.custom_minimum_size = Vector2(STATS_W, 0)
	_stats_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_stats_col)

	size = Vector2(PANEL_W, PANEL_H)
	_apply_lang()


# ============================ 公开接口 ============================

func open() -> void:
	visible = true
	_build_list()
	if _selected_id == "" or Devices.get_device(_selected_id).is_empty():
		var devs := Devices.get_devices()
		if not devs.is_empty():
			_selected_id = str(devs[0].get("id", ""))
	_build_detail()
	_build_overview()
	_center()
	move_to_front()


func close() -> void:
	visible = false
	_close_picker()
	_close_confirm()
	_close_ctx_menu()
	_close_dev_menu()
	_drafts.clear()          # 面板是临时入口，关闭即放弃所有未保存的草稿
	closed.emit()


func is_open() -> bool:
	return visible


# ============================ 左侧列表 ============================

func _build_list() -> void:
	_clear_container(_list_container)
	var devs := Devices.get_devices()
	if devs.is_empty():
		var empty := _label(TranslationManager.t("暂无设备，点上方「新建设备」"), FORM_FONT, Color(0.7, 0.7, 0.7))
		_list_container.add_child(empty)
		return
	for d in devs:
		var id := str(d.get("id", ""))
		var nm := str(d.get("name", id))
		# ★ 状态方框三态：绿=在线且状态正常 / 黄=**上线了但状态不佳**（散热不足、功耗超限）/ 红=离线
		var lvl: String = PCHardware.status_level(d)
		var online: bool = lvl != "offline"
		var suffix := "（在线）" if online else "（离线）"
		if lvl == "degraded":
			suffix = TranslationManager.t("（在线·状态不佳）")
		var row := DeviceRow.new()
		row.panel = self
		row.device_id = id
		row.setup(nm + suffix, lvl, id == _selected_id, _fnt, Devices.is_main_device(id))
		row.custom_minimum_size = Vector2(LIST_W - 8, BTN_H)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_list_container.add_child(row)


# ============================ 配置草稿 ============================

## 当前选中设备的配置草稿（首次访问时从设备快照一份）。
## ★ 所有安装 / 替换 / 卸下都作用在这里；点「应用并保存」才真正写进设备并联动背包。
func _draft() -> Dictionary:
	if _selected_id == "":
		return {}
	if not _drafts.has(_selected_id):
		_drafts[_selected_id] = Devices.snapshot_config(_selected_id)
	return _drafts[_selected_id] as Dictionary


## 草稿相对设备当前配置是否有未保存的更改
func _draft_dirty() -> bool:
	if _selected_id == "" or not _drafts.has(_selected_id):
		return false
	if Devices.get_device(_selected_id).is_empty():
		return false
	return JSON.stringify(_drafts[_selected_id]) != JSON.stringify(Devices.snapshot_config(_selected_id))


func _discard_draft() -> void:
	if _selected_id != "":
		_drafts.erase(_selected_id)


## 「草稿版设备」：外壳属性取自设备，config 用草稿 —— 槽位布局 / 统计都基于它计算，
## 这样草稿里的改动（比如刚插上的显卡坞）能立刻在插槽区反映出来。
func _draft_dev() -> Dictionary:
	var dev: Dictionary = Devices.get_device(_selected_id)
	if dev.is_empty():
		return {}
	var d: Dictionary = dev.duplicate(true)
	var ca: Dictionary = d.get("attrs", {})
	ca["config"] = _draft()
	d["attrs"] = ca
	return d


## 草稿里某零件 id 已被占用几份（用于算「背包可用份数」）
func _staged_use(part_id: String) -> int:
	var n := 0
	for k in _draft().keys():
		var p = _draft()[k]
		if p is Dictionary and str((p as Dictionary).get("id", "")) == part_id:
			n += 1
	return n


## 某零件当前还能装几份 = 背包数量 − 草稿里已占用（同槽位替换时算回一份）
func _available_of(part_id: String, slot_key: String) -> int:
	var n: int = Inventory.get_count(part_id) - _staged_use(part_id)
	var cur = _draft().get(slot_key, null)
	if cur is Dictionary and str((cur as Dictionary).get("id", "")) == part_id:
		n += 1
	return n


## 卸下某拓展件时，把它提供的拓展接口上的零件一并从草稿里删掉。
## ★ owner 必须是**改草稿之前**算出来的归属表（因为改完后归属就查不到了）。
func _cascade_dock_in_draft(dock_key: String, owner: Dictionary) -> int:
	var draft := _draft()
	var removed := 0
	for k in owner.keys():
		if str(owner[k]) == dock_key and draft.has(str(k)):
			draft.erase(str(k))
			removed += 1
	return removed


func _apply_save() -> void:
	if _selected_id == "":
		return
	var res: Dictionary = Devices.commit_config(_selected_id, _draft())
	if not bool(res.get("ok", false)):
		_toast(str(res.get("reason", "保存失败")))
		_build_detail()
		return
	_drafts.erase(_selected_id)
	var msg := str(res.get("reason", "已应用并保存"))
	if int(res.get("returned", 0)) > 0 or int(res.get("consumed", 0)) > 0:
		msg += "（退回 %d / 消耗 %d）" % [int(res.get("returned", 0)), int(res.get("consumed", 0))]
	_toast(msg)
	_build_list()
	_build_detail()
	_build_overview()


# ============================ 中部详情（上：性能 / 下：插槽）============================

func _build_detail() -> void:
	_close_ctx_menu()
	_clear_container(_perf_inner)
	_clear_container(_slot_inner)
	if _selected_id == "":
		_perf_inner.add_child(_label(TranslationManager.t("请选择左侧的一台设备"), FORM_FONT, Color(0.7, 0.7, 0.7)))
		return
	var dev: Dictionary = Devices.get_device(_selected_id)
	if dev.is_empty():
		_selected_id = ""
		_perf_inner.add_child(_label(TranslationManager.t("设备不存在"), FORM_FONT, Color(0.7, 0.7, 0.7)))
		return
	var ddev: Dictionary = _draft_dev()
	# 上方区域：设备性能
	_perf_inner.add_child(_section_title(TranslationManager.t("设备性能")))
	_build_header(dev, ddev)
	_build_stats(ddev)
	# 下方区域：插槽（按类型分行；拓展接口为黄边）
	_slot_inner.add_child(_section_title(TranslationManager.t("插槽")))
	_build_slots(ddev)


## 区域小标题（标题 + 分隔线）
func _section_title(text: String) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.add_child(_label(text, 15, Color(0.88, 0.94, 1.0)))
	v.add_child(HSeparator.new())
	return v


## 清空容器。★ 先 `remove_child` 再 `queue_free`：单纯 queue_free 的旧节点要到**帧末**才消失，
## 期间它仍在树里 → 同名新节点会被自动改名、几何断言也会读到旧节点（幽灵节点）。
func _clear_container(c: Node) -> void:
	if c == null or not is_instance_valid(c):
		return
	for ch in c.get_children():
		c.remove_child(ch)
		ch.queue_free()


func _build_header(dev: Dictionary, ddev: Dictionary) -> void:
	var name: String = str(dev.get("name", ""))
	var online: bool = bool(dev.get("online", false))
	var dev_id := str(dev.get("id", ""))
	var is_main := Devices.is_main_device(dev_id)
	# ★ 主力设备专属：网络器材不能当主力（不显示设为主力按钮）
	var can_be_main: bool = not PCHardware.is_net_kind(PCHardware.device_kind(dev))

	# 第一行：命名输入框 + 重命名
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 6)
	_name_edit = LineEdit.new()
	_name_edit.text = name
	_name_edit.placeholder_text = TranslationManager.t("设备名称")
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.custom_minimum_size = Vector2(160, 28)
	_apply_font_to(_name_edit)
	_name_edit.text_submitted.connect(_on_name_submitted)
	row1.add_child(_name_edit)
	var ren_btn := _btn(TranslationManager.t("重命名"), "rename")
	ren_btn.custom_minimum_size = Vector2(72, 28)
	row1.add_child(ren_btn)
	_perf_inner.add_child(row1)

	# 第二行：★ 四个操作按钮排成**一排**（上线/下线 · 拆解 · 应用并保存 · 放弃更改）
	#   上线条件 / 警告提示仍留在**下一排**（见本函数末尾）。
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	# ★ 上线/下线按钮：文字前加一个圆点 —— 上线=绿点，下线=红点。
	#   圆点由 `_add_state_dot()` 用**自绘控件**画（能按状态变色）；文字里**不写「●」字符**，
	#   否则会出现「字符圆点 + 自绘圆点」两个点。
	_online_btn = _btn(TranslationManager.t("下线") if online else TranslationManager.t("上线"),
		"toggle_online")
	_online_btn.custom_minimum_size = Vector2(96, 28)
	row2.add_child(_online_btn)
	var dis_btn := _btn(TranslationManager.t("拆解"), "disassemble")
	dis_btn.custom_minimum_size = Vector2(72, 28)
	row2.add_child(dis_btn)
	var apply_btn := _btn(TranslationManager.t("应用并保存"), "apply_save")
	apply_btn.custom_minimum_size = Vector2(112, 28)
	row2.add_child(apply_btn)
	var disc_btn := _btn(TranslationManager.t("放弃更改"), "discard")
	disc_btn.custom_minimum_size = Vector2(92, 28)
	row2.add_child(disc_btn)

	# ★ 主力设备：不能下线、不能拆解 → 把这两个按钮置灰并给出 tooltip（数据层也有硬闸门）。
	if is_main:
		_online_btn.disabled = true
		_online_btn.tooltip_text = TranslationManager.t("主力设备不能下线")
		dis_btn.disabled = true
		dis_btn.tooltip_text = TranslationManager.t("主力设备不能拆解")

	var dirty := _draft_dirty()
	var hint := _label(TranslationManager.t("● 有未保存的更改") if dirty else TranslationManager.t("配置已保存"),
		12, Color(1.0, 0.86, 0.45) if dirty else Color(0.62, 0.78, 0.66))
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(hint)
	_perf_inner.add_child(row2)
	# ★ 圆点要在按钮**入树之后**补：UIBtn 的 Label 子节点是 _ready 里建的，要拿它让出位置
	_add_state_dot(_online_btn,
		DeviceRow.STATUS_OFFLINE if online else DeviceRow.STATUS_ONLINE)

	# 提示排（第二排）：上线条件 / 状态不佳说明
	if not online:
		var req: Dictionary = PCHardware.online_requirement(ddev)
		if bool(req.get("ok", false)):
			var ok_l := _label("✓ " + TranslationManager.t("已满足上线条件，可上线"),
				12, Color(0.65, 0.95, 0.70))
			ok_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			ok_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_perf_inner.add_child(ok_l)
		else:
			var no_l := _label("⚠ " + TranslationManager.t("无法上线：") + str(req.get("reason", "")),
				12, Color(1.0, 0.68, 0.50))
			no_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			no_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_perf_inner.add_child(no_l)
	else:
		var lvl := PCHardware.status_level(ddev)
		var wst: Dictionary = PCHardware.computer_stat(ddev)
		var warns: Array = wst.get("warnings", [])
		var bad: Array = []
		for w in warns:
			bad.append(str(w))
		if lvl == "degraded" or not bad.is_empty():
			var bw_l := _label("⚠ " + "；".join(bad), 12, Color(1.0, 0.68, 0.50))
			bw_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			bw_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_perf_inner.add_child(bw_l)

	# ★ 「连接到全球网络」开关（**仅交换机**有）。
	#   需求：这个按钮**无论是否在调试模式下都可见** → 这里**不加**任何 Debug 守卫。
	#   状态落在 devices.json 的 attrs.global_net，并经由 GlobalNet 暴露给其它系统检测。
	if PCHardware.device_kind(dev) == PCHardware.KIND_SWITCH:
		var on_global: bool = Devices.global_net_state(str(dev.get("id", "")))
		var g_row := HBoxContainer.new()
		g_row.name = "GlobalNetRow"
		g_row.add_theme_constant_override("separation", 6)
		var g_btn := _btn(TranslationManager.t("断开全球网络") if on_global else TranslationManager.t("连接到全球网络"),
			"toggle_global_net")
		g_btn.custom_minimum_size = Vector2(150, 28)
		g_row.add_child(g_btn)
		var g_lab := _label(
			TranslationManager.t("已接入全球网络") if on_global else TranslationManager.t("未接入全球网络"),
			12, Color(0.62, 0.95, 0.72) if on_global else Color(0.72, 0.78, 0.88))
		g_lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		g_row.add_child(g_lab)
		_perf_inner.add_child(g_row)

	# ★ 「主力设备」标记行（仅电脑类：笔记本 / 台式机 / 工作站）。
	#   · 主力设备不可下线 / 不可拆解（上方按钮已置灰，数据层也有硬闸门）。
	#   · 其它设备必须与主力设备直接或间接链接才能上线。
	if can_be_main:
		var m_row := HBoxContainer.new()
		m_row.name = "MainDeviceRow"
		m_row.add_theme_constant_override("separation", 6)
		if is_main:
			var m_lab := _label("★ " + TranslationManager.t("主力设备（不可下线 · 不可拆解）"),
				12, Color(1.0, 0.82, 0.20))
			m_lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			m_row.add_child(m_lab)
			var unmain_btn := _btn(TranslationManager.t("取消主力"), "unset_main")
			unmain_btn.custom_minimum_size = Vector2(96, 28)
			m_row.add_child(unmain_btn)
		else:
			var setmain_btn := _btn(TranslationManager.t("设为主力设备"), "set_main")
			setmain_btn.custom_minimum_size = Vector2(120, 28)
			m_row.add_child(setmain_btn)
			var m_tip := ""
			if Devices.main_device_id() != "":
				var mn := str(Devices.get_device(Devices.main_device_id()).get("name", ""))
				m_tip = TranslationManager.t("其他设备需与主力设备「%s」直接或间接链接才能上线") % mn
			else:
				m_tip = TranslationManager.t("设为主力设备后，其他设备需与它直接或间接链接才能上线")
			var tip_l := _label(m_tip, 12, Color(0.72, 0.78, 0.88))
			tip_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			tip_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			m_row.add_child(tip_l)
		_perf_inner.add_child(m_row)
	elif PCHardware.is_net_kind(PCHardware.device_kind(dev)):
		# 网络器材不能当主力设备 → 明确说明
		var nm_l := _label(TranslationManager.t("网络器材不能设为主力设备（仅笔记本 / 台式机 / 工作站可以）"),
			12, Color(0.70, 0.76, 0.86))
		nm_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nm_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_perf_inner.add_child(nm_l)


## 给按钮文字前加一个「绿/红点」状态指示。
## 做法：按钮内加一个自绘圆点子控件（锚在左侧居中），并把按钮内部 Label 右移让出位置。
## ★ Label 是 _ready() 里建的，所以必须在按钮入树后再调；未就绪则等 ready。
func _add_state_dot(btn: UIBtn, col: Color) -> void:
	if btn == null or not is_instance_valid(btn):
		return
	if btn.has_meta("state_dot"):
		return
	if btn.label_node == null or not is_instance_valid(btn.label_node):
		btn.ready.connect(func() -> void: _add_state_dot(btn, col))
		return
	btn.set_meta("state_dot", true)
	btn.label_node.offset_left = 16.0
	var dot := _StateDot.new()
	dot.color = col
	dot.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	dot.offset_left = 9.0
	dot.offset_right = 19.0
	dot.offset_top = -5.0
	dot.offset_bottom = 5.0
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(dot)
	dot.queue_redraw()


## 上/下线按钮前的小圆点
class _StateDot extends Control:
	var color: Color = Color.WHITE

	func _draw() -> void:
		var r: float = minf(size.x, size.y) * 0.5
		draw_circle(size * 0.5, r, color)


func _build_stats(dev: Dictionary) -> void:
	var st: Dictionary = PCHardware.computer_stat(dev)
	# ★ 先建 MarginContainer（真·Container，能把自己最小尺寸上报给外层 VBox），再把 UIPanel 当
	#   FULL_RECT 子节点塞进去填充 —— 反之若把 UIPanel 直接挂 VBox，它不报最小尺寸会被压成 0 高，
	#   内部文字溢出、被下层内容遮挡，且 ScrollContainer 永远不滚。
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 10)
	pad.add_theme_constant_override("margin_right", 10)
	pad.add_theme_constant_override("margin_top", 8)
	pad.add_theme_constant_override("margin_bottom", 8)
	var box := UIPanel.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.set_corner_radius(UIStyle.CORNER_RADIUS * 0.6)
	box.set_fill_color(Color(UIStyle.FILL_DEFAULT.r, UIStyle.FILL_DEFAULT.g, UIStyle.FILL_DEFAULT.b, 0.30))
	box.set_border_color(UIStyle.BORDER)
	box.set_border_width(1.0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(box)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	pad.add_child(v)

	var online: bool = bool(st.get("online", false))
	var power_ok: bool = st.get("power_ok", true)
	var kind := str(st.get("device_kind", PCHardware.KIND_COMPUTER))
	var is_net := PCHardware.is_net_kind(kind)
	v.add_child(_stat_line("设备种类", PCHardware.kind_zh(kind), true))
	if is_net:
		# 网络器材不做零件 → 不显示 功耗/散热/算力/容量 这些电脑硬件指标。
		var links: Array = PCHardware.port_links(dev)
		v.add_child(_stat_line("已链接设备", "%d 台" % links.size(), true))
		if kind == PCHardware.KIND_SWITCH:
			var on_g: bool = Devices.global_net_state(str(dev.get("id", "")))
			var reach: bool = GlobalNet.is_on_global_network(str(dev.get("id", "")))
			v.add_child(_stat_line("全球网络",
				TranslationManager.t("已接入") if on_g else TranslationManager.t("未接入"), reach))
	else:
		# 在线设备：功耗即「占用功率」；离线则标「功耗（设备已下线）」
		var power_label := "占用功率" if online else "功耗"
		v.add_child(_stat_line(power_label, "%dW / 额定 %dW%s" % [
			int(st.get("power_used", 0)), int(st.get("power_cap", 0)),
			"" if power_ok else " ⚠超限"], power_ok))
		var cool := int(st.get("cooling_total", 0))
		v.add_child(_stat_line("散热", "%d%s" % [cool, ("（+" + str(st.get("cooling_bonus_pct", 0)) + "%算力）") if cool > 0 else ""], cool >= 0))
		v.add_child(_stat_line("算力", "%d → %d（散热加成后）" % [int(st.get("compute_raw", 0)), int(st.get("compute_final", 0))], true))
		v.add_child(_stat_line("固态容量", "%d GB" % int(st.get("ssd_capacity", 0)), true))
		v.add_child(_stat_line("机械容量", "%d GB" % int(st.get("hdd_capacity", 0)), true))
	v.add_child(_stat_line("对外接口", str(st.get("ports_text", "（无）")), true))
	v.add_child(_stat_line("在线", ("是" if online else "否"), online))
	# ★ 主力设备标记 + 连通状态（设了主力设备后才显示）
	var dev_id := str(dev.get("id", ""))
	if not PCHardware.is_net_kind(kind):
		if Devices.is_main_device(dev_id):
			v.add_child(_stat_line("主力设备", TranslationManager.t("是（不可下线 · 不可拆解）"), true))
		elif Devices.main_device_id() != "":
			var mname := str(Devices.get_device(Devices.main_device_id()).get("name", ""))
			var linked := Devices.linked_to_main(dev_id)
			v.add_child(_stat_line("与主力设备链接",
				TranslationManager.t("已连接（%s）") % mname if linked
					else TranslationManager.t("未连接（%s）") % mname, linked))

	var warns: Array = st.get("warnings", [])
	if not warns.is_empty():
		var wl := _label("⚠ " + "；".join(warns), 12, Color(1.0, 0.65, 0.55))
		wl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		wl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.add_child(wl)

	_perf_inner.add_child(pad)


## 单条属性行（label + 值；bad=红）
func _stat_line(label: String, value: String, good: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_label(label + "：", 12, Color(0.75, 0.85, 0.95)))
	var val := _label(value, 12, Color(0.7, 1.0, 0.75) if good else Color(1.0, 0.6, 0.55))
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	val.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(val)
	return row


## 大号统计块：小标题 + 大号醒目数值（用于「总览」）
func _big_stat(label: String, value: String, value_color: Color) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.add_child(_label(label, 14, Color(0.86, 0.93, 1.0)))
	box.add_child(_label(value, 24, value_color))
	return box


## 右侧总览统计栏：所有设备（不限在线）的总功耗与总算力分数。
func _build_overview() -> void:
	if _stats_col == null or not is_instance_valid(_stats_col):
		return
	for c in _stats_col.get_children():
		_stats_col.remove_child(c)
		c.queue_free()

	# ★ 深色背景（参考关卡页「舞台」底）：FILL_LEVEL_STAGE（深蓝近黑）+ STAGE_BORDER，
	#   比面板天蓝底深得多，托住「总览」读数。结构同 _build_stats：MarginContainer 先建、UIPanel 填充。
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 10)
	pad.add_theme_constant_override("margin_right", 10)
	pad.add_theme_constant_override("margin_top", 8)
	pad.add_theme_constant_override("margin_bottom", 8)
	var box := UIPanel.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.set_corner_radius(UIStyle.CORNER_RADIUS * 0.6)
	box.set_fill_color(UIStyle.FILL_LEVEL_STAGE)
	box.set_border_color(UIStyle.STAGE_BORDER)
	box.set_border_width(1.0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(box)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	pad.add_child(v)

	var devs := Devices.get_devices()
	var power := 0
	var compute := 0
	var online := 0
	for d in devs:
		var st: Dictionary = PCHardware.computer_stat(d)
		power += int(st.get("power_used", 0))
		compute += int(st.get("compute_final", 0))
		if bool(d.get("online", false)):
			online += 1

	# ★ 字号加大 + 高对比亮色，保证「总览」读数清晰醒目
	v.add_child(_label(TranslationManager.t("总览"), 20, Color(1.0, 1.0, 1.0)))
	v.add_child(_label("设备总数 %d（在线 %d）" % [devs.size(), online], 13, Color(0.82, 0.92, 1.0)))
	v.add_child(HSeparator.new())
	v.add_child(_big_stat("总功耗", "%d W" % power, Color(1.0, 0.88, 0.45)))
	v.add_child(_big_stat("总算力", str(compute), Color(0.55, 0.96, 1.0)))
	_stats_col.add_child(pad)


## 插槽区：**按槽位类型分行** —— 每类独占一排，排首是类型名标签，格内**只显示零件名称**。
## 某类槽位本身超过一排宽度（SLOT_MAX_PER_ROW）时，该类接着排到下一排（续排左侧留等宽空白对齐）。
## ★ 由转接卡 / 拓展坞 / 显卡坞提供的「拓展接口」格子使用**黄色边框**，与普通接口区分。
## ★ 末行「对外接口」（青色边框，只读）：主板自带 + 已装外设卡提供的对外口按种类列成格子。
## 交互：左键 安装/替换（弹选择器，含「卸下」）；右键 菜单（安装… / 替换… / 移除）。
func _build_slots(dev: Dictionary) -> void:
	var fill: Dictionary = PCHardware.slot_fill(dev)
	var owner: Dictionary = PCHardware.dock_layout(dev)
	var rows := VBoxContainer.new()
	rows.name = "SlotRows"
	rows.add_theme_constant_override("separation", 4)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slot_inner.add_child(rows)
	var made_row := false
	for st in SLOT_ORDER:
		var f = fill.get(st, { "total": 0, "used": 0 })
		var total: int = int(f.get("total", 0))
		if total <= 0:
			continue
		var keys: Array = []
		for i in range(total):
			keys.append(st + str(i))
		var idx := 0
		var first_chunk := true
		while idx < keys.size():
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 6)
			rows.add_child(row)
			# 排首类型名标签；续排用等宽空白占位，保证格子纵向对齐
			var lab := _label(PCHardware.slot_zh(st) if first_chunk else "", 12, Color(0.80, 0.92, 1.0))
			lab.custom_minimum_size = Vector2(SLOT_LABEL_W, SLOT_CELL_H)
			lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			row.add_child(lab)
			var n := 0
			while idx < keys.size() and n < SLOT_MAX_PER_ROW:
				var key: String = str(keys[idx])
				var cell := _make_slot_cell(owner.has(key))
				_fill_slot_cell(cell, dev, st, key, PCHardware.get_installed(dev, key))
				row.add_child(cell)
				idx += 1
				n += 1
			first_chunk = false
			made_row = true
	if not made_row:
		# 网络器材不做零件 → 说清楚是「按设计没有插槽」，而不是「忘了装主板」。
		if PCHardware.is_net_kind(PCHardware.device_kind(dev)):
			_slot_inner.add_child(_label(
				TranslationManager.t("网络器材：按设计不安装零件（不需要主板）"), FORM_FONT, Color(0.7, 0.82, 0.9)))
		else:
			_slot_inner.add_child(_label(TranslationManager.t("暂无插槽（先安装主板）"), FORM_FONT, Color(0.7, 0.7, 0.7)))
	# ★ 末行「对外接口」：只读展示整机对外口（主板自带 + 已装外设卡 + 自带）——
	#   装「USB 3.0 扩展卡」等外设卡后，这里会多出 / 变大对应格子，用户能直接看到「扩展出来的口」。
	_build_ports_row(rows, dev)
	# ★ 再下一行「已链接设备」：每建立一条「链接」就多一个格子，显示对端设备名（点击 → 断开/更换）。
	_build_link_row(rows, dev)


## 「对外接口」一行（格子内容：网口×2 / USB×4 / 无线网×∞）。
## ★ 可点性：**设备自带**的接口种类（网络器材自带 / 装了网卡多出来的无线网）可以点 → 打开「链接」选择页；
##   纯由零件扩展出来的种类（主板 I/O、外设卡）保持只读外观 —— 与改动前一致。
## ★ 自带接口显示的是**空闲数**（点一次链接就 −1），零件提供的显示总数。
func _build_ports_row(rows: VBoxContainer, dev: Dictionary) -> void:
	var tot: Dictionary = PCHardware.external_port_totals(dev)
	var free_t: Dictionary = PCHardware.port_free_totals(dev)
	var owned: Array = PCHardware.device_port_kinds(dev)
	var order := _port_order(tot)
	for k in free_t.keys():                    # 兜底：只在 free_t 里出现的种类也要排进去
		if not order.has(str(k)):
			order.append(str(k))
	var row := HBoxContainer.new()
	row.name = "PortRow"
	row.add_theme_constant_override("separation", 6)
	rows.add_child(row)
	var lab := _label(TranslationManager.t("对外接口"), 12, Color(0.80, 0.92, 1.0))
	lab.custom_minimum_size = Vector2(SLOT_LABEL_W, SLOT_CELL_H)
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lab)
	var made := false
	for kind in order:
		var sk := str(kind)
		var d: Dictionary = tot.get(sk, {})
		var cnt := int(d.get("count", 0))
		var speed := int(d.get("speed_max", 0))
		var linkable := owned.has(sk)
		if linkable and free_t.has(sk):
			cnt = int((free_t[sk] as Dictionary).get("free", cnt))
			speed = int((free_t[sk] as Dictionary).get("speed_max", speed))
		var cell := _make_port_cell(sk, cnt, speed, linkable)
		if linkable:
			cell.gui_input.connect(func(ev: InputEvent): _on_port_cell_input(ev, sk, ""))
		row.add_child(cell)
		made = true
	if not made:
		var none := _label(TranslationManager.t("（无）"), 12, Color(0.60, 0.72, 0.84))
		none.custom_minimum_size = Vector2(SLOT_CELL_W, SLOT_CELL_H)
		none.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(none)


## 「已链接设备」一行：每条链接一个格子，显示对端设备名。点击 → 「链接」选择页（含「断开」）。
func _build_link_row(rows: VBoxContainer, dev: Dictionary) -> void:
	var links: Array = PCHardware.port_links(dev)
	if links.is_empty():
		return
	var row := HBoxContainer.new()
	row.name = "LinkRow"
	row.add_theme_constant_override("separation", 6)
	rows.add_child(row)
	var lab := _label(TranslationManager.t("已链接"), 12, Color(0.70, 0.98, 0.80))
	lab.custom_minimum_size = Vector2(SLOT_LABEL_W, SLOT_CELL_H)
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lab)
	for lk in links:
		var l: Dictionary = lk
		var peer_id := str(l.get("peer_id", ""))
		var peer: Dictionary = Devices.get_device(peer_id)
		var nm := str(peer.get("name", ""))
		if nm == "":
			nm = TranslationManager.t("（设备已不在）")
		var kind := str(l.get("kind", ""))
		var port_key := str(l.get("port_key", ""))
		var cell := _make_link_cell(nm, kind, port_key)
		cell.gui_input.connect(func(ev: InputEvent): _on_port_cell_input(ev, kind, port_key))
		row.add_child(cell)


## 对外口展示顺序：网口 → 无线网 → USB → Type-C → 音频，其余种类按名字兜底追加（顺序稳定）。
func _port_order(tot: Dictionary) -> Array:
	var out: Array = []
	for k in ["eth", "wireless", "usb", "typec", "audio"]:
		if tot.has(k):
			out.append(k)
	var rest: Array = []
	for k in tot.keys():
		if not out.has(k):
			rest.append(str(k))
	rest.sort()
	return out + rest


func _make_port_cell(kind: String, count: int, speed: int, linkable: bool = false) -> Control:
	var cell := Control.new()
	cell.mouse_filter = Control.MOUSE_FILTER_STOP if linkable else Control.MOUSE_FILTER_IGNORE
	cell.custom_minimum_size = Vector2(SLOT_CELL_W, SLOT_CELL_H)
	cell.size = Vector2(SLOT_CELL_W, SLOT_CELL_H)
	var sp := UIPanel.new()
	sp.set_anchors_preset(Control.PRESET_FULL_RECT)
	sp.set_corner_radius(UIStyle.CORNER_RADIUS * 0.6)
	sp.set_fill_color(Color(UIStyle.FILL_DEFAULT.r, UIStyle.FILL_DEFAULT.g, UIStyle.FILL_DEFAULT.b, 0.32))
	sp.set_border_color(PORT_BORDER)
	sp.set_border_width(2.0 if linkable else 1.0)
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(sp)
	var ctxt := "∞" if count < 0 else str(count)
	var txt := "%s×%s" % [PCHardware.port_zh(kind), ctxt]
	if speed > 0:
		txt += "\n%dMbps" % speed
	var l := _label(txt, 11, Color(0.78, 0.94, 1.0))
	l.name = "PortText"
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.offset_left = 4.0
	l.offset_right = -4.0
	l.offset_top = 3.0
	l.offset_bottom = -3.0
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cell.add_child(l)
	cell.set_meta("linkable", linkable)
	cell.set_meta("port_kind", kind)
	if linkable:
		cell.tooltip_text = TranslationManager.t("对外接口（显示空闲数）\n左键 → 链接到其他设备")
	else:
		cell.tooltip_text = TranslationManager.t("整机对外接口（零件提供，只读）")
	return cell


## 「已链接设备」格子：绿色边框 + 对端设备名（点击 → 断开 / 更换）。
func _make_link_cell(peer_name: String, kind: String, port_key: String) -> Control:
	var cell := Control.new()
	cell.mouse_filter = Control.MOUSE_FILTER_STOP
	cell.custom_minimum_size = Vector2(SLOT_CELL_W, SLOT_CELL_H)
	cell.size = Vector2(SLOT_CELL_W, SLOT_CELL_H)
	var sp := UIPanel.new()
	sp.set_anchors_preset(Control.PRESET_FULL_RECT)
	sp.set_corner_radius(UIStyle.CORNER_RADIUS * 0.6)
	sp.set_fill_color(Color(UIStyle.FILL_DEFAULT.r, UIStyle.FILL_DEFAULT.g, UIStyle.FILL_DEFAULT.b, 0.32))
	sp.set_border_color(LINK_BORDER)
	sp.set_border_width(2.0)
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(sp)
	var l := _label(peer_name, 11, Color(0.80, 1.0, 0.86))
	l.name = "LinkName"
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.offset_left = 4.0
	l.offset_right = -4.0
	l.offset_top = 3.0
	l.offset_bottom = -3.0
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cell.add_child(l)
	cell.set_meta("link_port_key", port_key)
	cell.set_meta("port_kind", kind)
	cell.tooltip_text = "%s：%s\n左键 → 断开 / 更换" % [PCHardware.port_zh(kind), peer_name]
	return cell


## 建一个空格子（结构同背包格：UIPanel 底 + 居中名称）。
## is_dock = true → 该格是拓展零件提供的「拓展接口」，边框画成黄色。
func _make_slot_cell(is_dock: bool) -> Control:
	var cell := Control.new()
	cell.mouse_filter = Control.MOUSE_FILTER_STOP
	cell.custom_minimum_size = Vector2(SLOT_CELL_W, SLOT_CELL_H)
	cell.size = Vector2(SLOT_CELL_W, SLOT_CELL_H)
	var sp := UIPanel.new()
	sp.set_anchors_preset(Control.PRESET_FULL_RECT)
	sp.set_corner_radius(UIStyle.CORNER_RADIUS * 0.6)
	sp.set_fill_color(Color(UIStyle.FILL_DEFAULT.r, UIStyle.FILL_DEFAULT.g, UIStyle.FILL_DEFAULT.b, 0.32))
	sp.set_border_color(DOCK_BORDER if is_dock else UIStyle.BORDER)
	sp.set_border_width(2.0 if is_dock else 1.0)
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(sp)
	cell.set_meta("is_dock", is_dock)
	var name_l := _label("", 12, Color.WHITE)
	name_l.name = "SlotName"
	name_l.set_anchors_preset(Control.PRESET_FULL_RECT)
	name_l.offset_left = 4.0
	name_l.offset_right = -4.0
	name_l.offset_top = 3.0
	name_l.offset_bottom = -3.0
	name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cell.add_child(name_l)
	cell.gui_input.connect(func(ev: InputEvent): _on_slot_cell_input(ev, cell))
	return cell


## 填格子：已装 → 只显示零件名称（白）；空槽 → **显示该槽位的规格 / 协议**（暗青，不再留白）。
func _fill_slot_cell(cell: Control, dev: Dictionary, slot_type: String, slot_key: String, inst: Dictionary) -> void:
	var name_l: Label = cell.get_node("SlotName")
	var has_part := not inst.is_empty()
	cell.set_meta("slot_key", slot_key)
	cell.set_meta("slot_type", slot_type)
	cell.set_meta("has_part", has_part)
	var is_dock := bool(cell.get_meta("is_dock", false))
	var slot_name := "%s%d" % [PCHardware.slot_zh(slot_type), int(slot_key.substr(slot_type.length()))]
	if is_dock:
		slot_name += TranslationManager.t("（拓展接口）")
	if has_part:
		name_l.text = str(inst.get("name", slot_key))
		name_l.add_theme_font_size_override("font_size", 12)
		name_l.add_theme_color_override("font_color", Color.WHITE)
		cell.tooltip_text = "%s\n已装：%s\n左键更换/卸下 · 右键菜单" % [slot_name, str(inst.get("name", ""))]
	else:
		# ★ 空槽位显示「规格 + 协议」（如 DDR5 / M.2_NVMe / PCIe4x16 / LGA1700 / ≤ATX）
		var spec := PCHardware.slot_spec_text(dev, slot_key)
		cell.set_meta("spec_text", spec)
		name_l.text = spec
		name_l.add_theme_font_size_override("font_size", 11)
		name_l.add_theme_color_override("font_color", Color(0.60, 0.72, 0.84))
		cell.tooltip_text = "%s（空 %s）\n左键安装 · 右键菜单" % [slot_name, spec]


func _on_slot_cell_input(event: InputEvent, cell: Control) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	if cell == null or not is_instance_valid(cell):
		return
	var slot_key := str(cell.get_meta("slot_key", ""))
	var has_part := bool(cell.get_meta("has_part", false))
	if event.button_index == MOUSE_BUTTON_RIGHT:
		_open_slot_menu(slot_key, has_part)
		get_viewport().set_input_as_handled()
	elif event.button_index == MOUSE_BUTTON_LEFT:
		if has_part:
			_on_btn_pressed("replace_" + slot_key)
		else:
			_on_btn_pressed("install_" + str(cell.get_meta("slot_type", "")) + "|" + slot_key)
		get_viewport().set_input_as_handled()


# ============================ 设备列表行右键菜单 ============================

## 右键设备列表的某一行 → 弹出「上线 / 下线」菜单。
## ★ 需求：右键「设备名称栏目」后通过菜单控制上线/下线。
func _open_device_menu(dev_id: String, at: Vector2) -> void:
	_close_dev_menu()
	var dev: Dictionary = Devices.get_device(dev_id)
	if dev.is_empty():
		return
	var online := bool(dev.get("online", false))
	var items: Array = []
	if online:
		items.append({ "label": TranslationManager.t("下线"), "id": "offline" })
	else:
		items.append({ "label": TranslationManager.t("上线"), "id": "online" })
	var menu := ContextMenu.new()
	add_child(menu)
	menu.item_selected.connect(_on_device_menu_selected.bind(dev_id))
	_dev_menu = menu
	menu.open(at, items)


func _on_device_menu_selected(id: String, _full_path: PackedStringArray, dev_id: String) -> void:
	_close_dev_menu()
	match id:
		"online":
			_set_device_online(dev_id, true)
		"offline":
			_set_device_online(dev_id, false)


func _close_dev_menu() -> void:
	if _dev_menu != null and is_instance_valid(_dev_menu):
		_dev_menu.close()
		_dev_menu.queue_free()
	_dev_menu = null


## 上/下线某设备（供右键菜单与「主力设备」规则共用）。会给出具体失败原因。
func _set_device_online(dev_id: String, on: bool) -> void:
	if dev_id == "":
		return
	var dev: Dictionary = Devices.get_device(dev_id)
	if dev.is_empty():
		return
	var online := bool(dev.get("online", false))
	if on and not online:
		var block := Devices.online_block_reason(dev_id)
		if block != "":
			_toast(TranslationManager.t("无法上线：") + block)
			return
	if not on and online:
		var oblock := _offline_block_reason(dev_id)
		if oblock != "":
			_toast(TranslationManager.t("无法下线：") + oblock)
			return
	if not Devices.set_online(dev_id, on):
		if not on:
			_toast(TranslationManager.t("无法下线：") + _offline_block_reason(dev_id))
	# ★ 走延迟刷新：绝不在 gui_input / 菜单回调里同步重建列表（会释放正被右键的行 → signal 11）。
	#   _do_refresh 会一并重建 列表 + 详情 + 总览。
	_request_refresh()


## 下线被拒的原因（主力设备 / 最后一台在线）
func _offline_block_reason(dev_id: String) -> String:
	if Devices.is_main_device(dev_id):
		return TranslationManager.t("主力设备不能下线")
	if Devices.online_count() <= 1 and bool(Devices.get_device(dev_id).get("online", false)):
		return TranslationManager.t("至少保留一台设备在线")
	return ""


# ============================ 插槽右键菜单 ============================

func _open_slot_menu(slot_key: String, has_part: bool) -> void:
	_close_ctx_menu()
	if slot_key == "":
		return
	var items: Array = []
	if has_part:
		items.append({ "label": TranslationManager.t("替换…"), "id": "pick" })
		items.append({ "label": TranslationManager.t("移除"), "id": "remove" })
	else:
		items.append({ "label": TranslationManager.t("安装…"), "id": "pick" })
	var menu := ContextMenu.new()
	add_child(menu)
	menu.item_selected.connect(_on_slot_menu_selected.bind(slot_key))
	_ctx_menu = menu
	menu.open(get_global_mouse_position(), items)


func _on_slot_menu_selected(id: String, _full_path: PackedStringArray, slot_key: String) -> void:
	_close_ctx_menu()
	match id:
		"pick":
			_open_picker(PCHardware._slot_type_of(slot_key), slot_key)
		"remove":
			_do_remove(slot_key)


func _close_ctx_menu() -> void:
	if _ctx_menu != null and is_instance_valid(_ctx_menu):
		_ctx_menu.close()
		_ctx_menu.queue_free()
	_ctx_menu = null


## 移除槽位零件（草稿版见文件后段 _do_remove）
# ============================ 安装选择器 ============================

func _open_picker(slot_type: String, slot_key: String) -> void:
	_close_picker()
	_picker_gen += 1
	var my_gen: int = _picker_gen
	# ★ 用「草稿版设备」判定兼容性：刚插上的拓展件所提供的接口，立刻能选出适配零件
	var dev: Dictionary = _draft_dev()
	if dev.is_empty():
		return
	var comps: Array = PCHardware.list_compatible(dev, slot_type, slot_key)
	# ★ 已装零件时即使没有兼容备件也要开（否则没法从这里「卸下」）
	var cur: Dictionary = {}
	var raw = _draft().get(slot_key, null)
	if raw is Dictionary:
		cur = raw

	var popup := Control.new()
	popup.mouse_filter = Control.MOUSE_FILTER_STOP
	popup.visible = false
	var bg := UIPanel.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	bg.set_fill_color(UIStyle.FILL_DEFAULT)
	bg.set_border_color(UIStyle.BORDER)
	bg.set_border_width(UIStyle.BORDER_WIDTH)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	popup.add_child(bg)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 10)
	m.add_theme_constant_override("margin_right", 10)
	m.add_theme_constant_override("margin_top", 6)
	m.add_theme_constant_override("margin_bottom", 10)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	popup.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	m.add_child(v)

	# ---- 顶栏：标题 | 拖动把柄（移动页面位置）| × 关闭（直接复用已有的两个控件）----
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	var title := _label("选择要安装的%s" % PCHardware.slot_zh(slot_type), FORM_FONT, Color(0.8, 0.92, 1.0))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var handle := UIDragHandle.new()
	head.add_child(handle)
	handle.setup(popup)                       # 复用已有的拖动把柄：拖动整个弹层
	var cls := _btn("×", "close_picker")
	cls.custom_minimum_size = Vector2(28, 28)
	head.add_child(cls)                       # 复用已有的 × 关闭按钮样式
	v.add_child(head)

	# 已装零件时：显示当前零件 + 「卸下」按钮（★ 需求：次级菜单除了适配零件，还要有卸下）
	if not cur.is_empty():
		var cur_row := HBoxContainer.new()
		cur_row.add_theme_constant_override("separation", 6)
		var cur_lab := _label("当前：%s" % str(cur.get("name", "")), 12, Color(0.86, 0.94, 1.0))
		cur_lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cur_lab.clip_text = true
		cur_row.add_child(cur_lab)
		var un_btn := _btn(TranslationManager.t("卸下"), "unload_" + slot_key)
		un_btn.custom_minimum_size = Vector2(72, BTN_H)
		cur_row.add_child(un_btn)
		v.add_child(cur_row)

	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(300, 260)
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(sc)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 4)
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(inner)

	if comps.is_empty():
		inner.add_child(_label(TranslationManager.t("没有兼容的备件"), 12, Color(0.7, 0.7, 0.7)))
	for it in comps:
		var id := str(it.get("id", ""))
		var pa: Dictionary = it.get("attrs", {})
		var note := ""
		if pa.has("compute_score"):
			note += " 算力%d" % int(pa.get("compute_score", 0))
		if pa.has("power_w"):
			note += " %dW" % int(pa.get("power_w", 0))
		if pa.has("storage_capacity_gb"):
			note += " %dGB" % int(pa.get("storage_capacity_gb", 0))
		# 显示「可用份数」（背包数量 − 草稿里已占用），避免同一份零件被草稿重复占用
		var avail: int = _available_of(id, slot_key)
		note += "  ×%d" % maxi(0, avail)
		var label := str(it.get("name", id)) + note
		if avail <= 0:
			label += TranslationManager.t("（无可用备件）")
		var b := _btn(label, "pick_" + id + "|" + slot_key)
		b.custom_minimum_size = Vector2(280, BTN_H)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		inner.add_child(b)

	add_child(popup)
	_picker = popup
	await get_tree().process_frame
	if my_gen != _picker_gen or not is_instance_valid(popup) or _picker != popup:
		return
	var cmin: Vector2 = m.get_combined_minimum_size()
	popup.custom_minimum_size = cmin
	popup.size = cmin
	var at := Vector2(global_position.x + size.x - cmin.x - 8, global_position.y + 40.0)
	var vp: Vector2 = UIStyle.canvas_viewport_size(self)
	if at.x + cmin.x > vp.x:
		at.x = maxf(4.0, vp.x - cmin.x - 4.0)
	if at.y + cmin.y > vp.y:
		at.y = maxf(4.0, vp.y - cmin.y - 4.0)
	popup.global_position = at
	popup.visible = true


func _close_picker() -> void:
	if _picker != null and is_instance_valid(_picker):
		_picker.queue_free()
		_picker = null


# ============================ 对外接口「链接」选择页 ============================
#
# 需求：点击**没有链接其他设备**的对外接口 → 打开一个「类似更换零件」的页面，列出**接口兼容**
#       （同类接口有空位）的其他设备；点选后该接口占用的数量 −1，并在插槽区「已链接」行
#       出现一个显示对端设备的新格子。
#       · 已链接的接口点进来 → 显示「当前：X」+【断开】（本页「卸下」按钮文案按需求改成「断开」）。
#       · 链接是**双向占用**：两端各占 1 个同类接口（对端没空口就不列进候选）。

func _on_port_cell_input(event: InputEvent, kind: String, port_key: String) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	_open_link_picker(kind, port_key)
	get_viewport().set_input_as_handled()


func _open_link_picker(kind: String, port_key: String) -> void:
	_close_picker()
	_picker_gen += 1
	var my_gen: int = _picker_gen
	var dev: Dictionary = Devices.get_device(_selected_id)
	if dev.is_empty():
		return
	var cur: Dictionary = {}
	if port_key != "":
		cur = Devices._find_link(dev, port_key)
	var comps: Array = Devices.link_candidates(_selected_id, kind)

	var popup := Control.new()
	popup.mouse_filter = Control.MOUSE_FILTER_STOP
	popup.visible = false
	var bg := UIPanel.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	bg.set_fill_color(UIStyle.FILL_DEFAULT)
	bg.set_border_color(UIStyle.BORDER)
	bg.set_border_width(UIStyle.BORDER_WIDTH)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	popup.add_child(bg)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 10)
	m.add_theme_constant_override("margin_right", 10)
	m.add_theme_constant_override("margin_top", 6)
	m.add_theme_constant_override("margin_bottom", 10)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	popup.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	m.add_child(v)

	# 顶栏：标题 | 拖动把柄 | × 关闭（复用已有控件）
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	var free_n := PCHardware.port_free_count(dev, kind)
	var free_txt := "∞" if free_n < 0 else str(free_n)
	var title := _label("%s（空闲 %s）→ 选择要链接的设备" % [
		PCHardware.port_zh(kind), free_txt], FORM_FONT, Color(0.8, 0.92, 1.0))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var handle := UIDragHandle.new()
	head.add_child(handle)
	handle.setup(popup)
	var cls := _btn("×", "close_picker")
	cls.custom_minimum_size = Vector2(28, 28)
	head.add_child(cls)
	v.add_child(head)

	# 已链接 → 显示当前对端 + 【断开】（需求：本页「卸下」按钮文案改成「断开」）
	if not cur.is_empty():
		var peer: Dictionary = Devices.get_device(str(cur.get("device_id", "")))
		var pnm := str(peer.get("name", ""))
		if pnm == "":
			pnm = TranslationManager.t("（设备已不在）")
		var cur_row := HBoxContainer.new()
		cur_row.add_theme_constant_override("separation", 6)
		var cur_lab := _label("当前：%s（%s）" % [pnm, port_key], 12, Color(0.86, 0.94, 1.0))
		cur_lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cur_lab.clip_text = true
		cur_row.add_child(cur_lab)
		var un_btn := _btn(TranslationManager.t("断开"), "unlink_" + port_key)
		un_btn.custom_minimum_size = Vector2(72, BTN_H)
		cur_row.add_child(un_btn)
		v.add_child(cur_row)

	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(300, 240)
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(sc)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 4)
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(inner)

	if comps.is_empty():
		inner.add_child(_label(TranslationManager.t("没有可链接的设备（需要对方也有空闲的同类接口）"),
			12, Color(0.7, 0.7, 0.7)))
	for c in comps:
		var cd: Dictionary = c
		var cid := str(cd.get("id", ""))
		var fn := int(cd.get("free", 0))
		var ftxt := "∞" if fn < 0 else str(fn)
		var b := _btn("%s （空闲%s×%s）" % [str(cd.get("name", cid)), PCHardware.port_zh(kind), ftxt],
			"link_" + cid + "|" + kind)
		b.custom_minimum_size = Vector2(280, BTN_H)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		inner.add_child(b)

	add_child(popup)
	_picker = popup
	await get_tree().process_frame
	if my_gen != _picker_gen or not is_instance_valid(popup) or _picker != popup:
		return
	var cmin: Vector2 = m.get_combined_minimum_size()
	popup.custom_minimum_size = cmin
	popup.size = cmin
	var at := Vector2(global_position.x + size.x - cmin.x - 8, global_position.y + 40.0)
	var vp: Vector2 = UIStyle.canvas_viewport_size(self)
	if at.x + cmin.x > vp.x:
		at.x = maxf(4.0, vp.x - cmin.x - 4.0)
	if at.y + cmin.y > vp.y:
		at.y = maxf(4.0, vp.y - cmin.y - 4.0)
	popup.global_position = at
	popup.visible = true


## 建立链接（立即生效，不进草稿 —— 链接是设备之间的拓扑关系，不是「配置」）
func _do_link(kind: String, peer_id: String) -> void:
	if _selected_id == "":
		return
	var peer: Dictionary = Devices.get_device(peer_id)
	var r: Dictionary = Devices.link_devices(_selected_id, kind, peer_id)
	if bool(r.get("ok", false)):
		_toast(TranslationManager.t("已链接到「%s」（双方各占用 1 个%s）") % [
			str(peer.get("name", peer_id)), PCHardware.port_zh(kind)])
	else:
		_toast(TranslationManager.t("链接失败：") + str(r.get("reason", "")))
	# 成功时 Devices.changed → _request_refresh（帧末重建列表/详情）；失败也要刷新状态位
	_build_detail()


func _do_unlink(port_key: String) -> void:
	if _selected_id == "":
		return
	var r: Dictionary = Devices.unlink_port(_selected_id, port_key)
	if bool(r.get("ok", false)):
		_toast(TranslationManager.t("已断开链接"))
	else:
		_toast(TranslationManager.t("断开失败：") + str(r.get("reason", "")))
	_build_detail()


# ============================ 新建设备：选外壳 ============================

func _open_chassis_picker() -> void:
	_close_picker()
	var popup := Control.new()
	popup.mouse_filter = Control.MOUSE_FILTER_STOP
	popup.visible = false
	var bg := UIPanel.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	bg.set_fill_color(UIStyle.FILL_DEFAULT)
	bg.set_border_color(UIStyle.BORDER)
	bg.set_border_width(UIStyle.BORDER_WIDTH)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	popup.add_child(bg)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 10)
	m.add_theme_constant_override("margin_right", 10)
	m.add_theme_constant_override("margin_top", 6)
	m.add_theme_constant_override("margin_bottom", 10)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	popup.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	m.add_child(v)
	# 顶栏：标题 | 拖动把柄（移动页面位置）| × 关闭（复用已有控件）
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	var ctitle := _label(TranslationManager.t("选择外壳"), FORM_FONT, Color(0.8, 0.92, 1.0))
	ctitle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(ctitle)
	var chandle := UIDragHandle.new()
	head.add_child(chandle)
	chandle.setup(popup)
	var ccls := _btn("×", "close_picker")
	ccls.custom_minimum_size = Vector2(28, 28)
	head.add_child(ccls)
	v.add_child(head)
	var options: Array = [
		{ "id": "chassis_laptop", "zh": PCHardware.chassis_zh("laptop") },
		{ "id": "chassis_desktop", "zh": PCHardware.chassis_zh("desktop") },
		{ "id": "chassis_workstation", "zh": PCHardware.chassis_zh("workstation") },
		# ★ 网络器材（不做零件，自带对外接口）——「新建设备」里一并可选。
		{ "id": "kind_scanner", "zh": "%s（%s）" % [PCHardware.kind_zh(PCHardware.KIND_SCANNER), TranslationManager.t("自带 2 个网口")] },
		{ "id": "kind_switch", "zh": "%s（%s）" % [PCHardware.kind_zh(PCHardware.KIND_SWITCH), TranslationManager.t("自带 8 个网口")] },
		{ "id": "kind_ap", "zh": "%s（%s）" % [PCHardware.kind_zh(PCHardware.KIND_AP), TranslationManager.t("无限个无线网口")] },
	]
	for o in options:
		var opt: Dictionary = o
		var b := _btn(str(opt.get("zh", "")), str(opt.get("id", "")))
		b.custom_minimum_size = Vector2(200, BTN_H)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.add_child(b)

	add_child(popup)
	_picker = popup
	await get_tree().process_frame
	if not is_instance_valid(popup) or _picker != popup:
		return
	var cmin: Vector2 = m.get_combined_minimum_size()
	popup.custom_minimum_size = cmin
	popup.size = cmin
	var at := Vector2(global_position.x + (size.x - cmin.x) * 0.5, global_position.y + 60.0)
	popup.global_position = at
	popup.visible = true


# ============================ 拆解确认 ============================

func _open_confirm_disassemble() -> void:
	_close_confirm()
	var popup := Control.new()
	popup.mouse_filter = Control.MOUSE_FILTER_STOP
	popup.visible = false
	var bg := UIPanel.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	bg.set_fill_color(UIStyle.FILL_DEFAULT)
	bg.set_border_color(UIStyle.BORDER)
	bg.set_border_width(UIStyle.BORDER_WIDTH)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	popup.add_child(bg)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 12)
	m.add_theme_constant_override("margin_right", 12)
	m.add_theme_constant_override("margin_top", 12)
	m.add_theme_constant_override("margin_bottom", 12)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	popup.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	m.add_child(v)
	v.add_child(_label(TranslationManager.t("确认拆解？已安装零件将退回背包"), FORM_FONT, Color(1.0, 0.8, 0.6)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var yes := _btn(TranslationManager.t("确认拆解"), "confirm_disassemble")
	yes.custom_minimum_size = Vector2(110, BTN_H)
	row.add_child(yes)
	var no := _btn(TranslationManager.t("取消"), "cancel_disassemble")
	no.custom_minimum_size = Vector2(90, BTN_H)
	row.add_child(no)
	v.add_child(row)

	add_child(popup)
	_confirm = popup
	await get_tree().process_frame
	if not is_instance_valid(popup) or _confirm != popup:
		return
	var cmin: Vector2 = m.get_combined_minimum_size()
	popup.custom_minimum_size = cmin
	popup.size = cmin
	var at := Vector2(global_position.x + (size.x - cmin.x) * 0.5, global_position.y + (size.y - cmin.y) * 0.5)
	popup.global_position = at
	popup.visible = true


func _close_confirm() -> void:
	if _confirm != null and is_instance_valid(_confirm):
		_confirm.queue_free()
		_confirm = null


# ============================ 输入 ============================

func _on_btn_pressed(id: String) -> void:
	if id == "close":
		close()
		return
	if id.begins_with("sel_"):
		_selected_id = id.trim_prefix("sel_")
		_close_picker()
		_build_detail()
		return
	if id == "new":
		_open_chassis_picker()
		return
	if id == "close_picker":
		_close_picker()
		return
	if id == "apply_save":
		_apply_save()
		return
	if id == "discard":
		_discard_draft()
		_toast(TranslationManager.t("已放弃未保存的更改"))
		_build_detail()
		return
	if id.begins_with("chassis_"):
		var chassis: String = id.trim_prefix("chassis_")
		_close_picker()
		var new_id := Devices.create_device(chassis)
		_selected_id = new_id
		_build_list()
		_build_detail()
		return
	if id.begins_with("kind_"):
		# 网络器材（扫描重构器 / 交换机 / 无线网络发生器）：不做零件，自带对外接口。
		var kind: String = id.trim_prefix("kind_")
		_close_picker()
		var nid := Devices.create_device("", kind)
		_selected_id = nid
		_build_list()
		_build_detail()
		return
	if id.begins_with("unlink_"):
		# 链接选择页里的「断开」
		_close_picker()
		_do_unlink(id.trim_prefix("unlink_"))
		return
	if id.begins_with("link_"):
		var rest := id.trim_prefix("link_")
		var lparts: PackedStringArray = rest.split("|", false, 1)
		_close_picker()
		if lparts.size() >= 2:
			_do_link(lparts[1], lparts[0])
		return
	if id == "rename":
		_do_rename()
		return
	if id == "toggle_online":
		_toggle_online()
		return
	if id == "set_main":
		_set_main_device(_selected_id)
		return
	if id == "unset_main":
		_set_main_device("")
		return
	if id == "toggle_global_net":
		# 「连接到全球网络」开关（仅交换机；任何模式下都可见）
		if _selected_id == "":
			return
		var cur_on: bool = Devices.global_net_state(_selected_id)
		if GlobalNet.set_switch(_selected_id, not cur_on):
			_toast(TranslationManager.t("已断开全球网络") if cur_on else TranslationManager.t("已接入全球网络"))
		else:
			_toast(TranslationManager.t("该设备没有「全球网络」开关（仅交换机）"))
		_build_detail()
		return
	if id == "disassemble":
		# ★ 主力设备不可拆解 → 按钮已置灰，这里再兜一层
		if Devices.is_main_device(_selected_id):
			_toast(TranslationManager.t("主力设备不能拆解"))
			return
		_open_confirm_disassemble()
		return
	if id == "confirm_disassemble":
		_close_confirm()
		if Devices.is_main_device(_selected_id):
			_toast(TranslationManager.t("主力设备不能拆解"))
			return
		var dv: Dictionary = Devices.get_device(_selected_id)
		if bool(dv.get("online", false)) and Devices.online_count() <= 1:
			_toast(TranslationManager.t("至少保留一台设备在线，无法拆解"))
			return
		_drafts.erase(_selected_id)
		Devices.disassemble(_selected_id)
		_selected_id = ""
		_build_list()
		_build_detail()
		return
	if id == "cancel_disassemble":
		_close_confirm()
		return
	if id.begins_with("install_"):
		var rest := id.trim_prefix("install_")
		var parts: PackedStringArray = rest.split("|", false, 1)
		_open_picker(parts[0], parts[1])
		return
	if id.begins_with("replace_"):
		var slot_key: String = id.trim_prefix("replace_")
		var st: String = PCHardware._slot_type_of(slot_key)
		_open_picker(st, slot_key)
		return
	if id.begins_with("remove_"):
		_do_remove(id.trim_prefix("remove_"))
		return
	if id.begins_with("unload_"):
		# 选择器里的「卸下」：关掉弹层再从**草稿**里移除（保存时统一生效）
		_close_picker()
		_do_remove(id.trim_prefix("unload_"))
		return
	if id.begins_with("pick_"):
		var rest := id.trim_prefix("pick_")
		var parts: PackedStringArray = rest.split("|", false, 1)
		var item_id: String = parts[0]
		var slot_key: String = parts[1]
		_close_picker()
		_do_install(slot_key, item_id)


func _on_name_submitted(_new_text: String) -> void:
	_do_rename()


func _do_rename() -> void:
	if _selected_id == "" or _name_edit == null or not is_instance_valid(_name_edit):
		return
	var nm := _name_edit.text.strip_edges()
	if nm == "":
		nm = "未命名设备"
	Devices.rename(_selected_id, nm)
	_build_list()


func _toggle_online() -> void:
	if _selected_id == "":
		return
	var dev: Dictionary = Devices.get_device(_selected_id)
	if dev.is_empty():
		return
	# ★ 有未保存的配置更改时先别上下线：上下线判定用的是设备**已保存**的配置，
	#   草稿里的改动还没生效，容易让人误判。
	if _draft_dirty():
		_toast(TranslationManager.t("请先「应用并保存」配置更改，再上下线"))
		return
	_set_device_online(_selected_id, not bool(dev.get("online", false)))


## 设 / 取消主力设备（dev_id 传空串 = 取消）。
func _set_main_device(dev_id: String) -> void:
	var id := str(dev_id)
	if id == "":
		# 取消：把当前主力设备让出来
		if Devices.main_device_id() == "":
			return
		var old_name := str(Devices.get_device(Devices.main_device_id()).get("name", ""))
		var reason := Devices.set_main_device("")
		if reason != "":
			_toast(reason)
			return
		_toast(TranslationManager.t("已取消「%s」的主力设备标记") % old_name)
		# set_main_device 已 emit changed → _request_refresh 帧末重建 列表/详情/总览
		_request_refresh()
		return
	var dev: Dictionary = Devices.get_device(id)
	if dev.is_empty():
		return
	var reason2 := Devices.set_main_device(id)
	if reason2 != "":
		_toast(reason2)
		return
	_toast(TranslationManager.t("「%s」已设为主力设备（不可下线 · 不可拆解）") % str(dev.get("name", id)))
	_request_refresh()


## 往**草稿**里安装零件（点「应用并保存」才真正扣背包、写设备）
func _do_install(slot_key: String, item_id: String) -> void:
	if _selected_id == "":
		return
	var target := slot_key
	if target == "":
		target = PCHardware.first_free_slot(_draft_dev(), PCHardware._slot_type_of(slot_key))
	if target == "":
		_toast(TranslationManager.t("该槽位已满"))
		_build_detail()
		return
	if _available_of(item_id, target) <= 0:
		_toast(TranslationManager.t("背包里已没有可用的该零件"))
		return
	var part: Dictionary = Inventory.get_item(item_id)
	if part.is_empty():
		_toast(TranslationManager.t("背包里没有该零件"))
		return
	var draft := _draft()
	# ★ 换掉一个拓展件时，旧拓展件提供的接口上的零件一并卸下（草稿内级联）
	var old = draft.get(target, null)
	if PCHardware._is_dock_item(old) and str((old as Dictionary).get("id", "")) != item_id:
		var owner: Dictionary = PCHardware.dock_layout(_draft_dev())
		var n := _cascade_dock_in_draft(target, owner)
		if n > 0:
			_toast(TranslationManager.t("已同时卸下原拓展件接口上的 %d 个零件") % n)
	draft[target] = part.duplicate(true)
	_build_detail()


## 从**草稿**里卸下零件（保存时才退回背包）
func _do_remove(slot_key: String) -> void:
	if _selected_id == "" or slot_key == "":
		return
	var draft := _draft()
	if not draft.has(slot_key):
		_toast(TranslationManager.t("该槽位是空的"))
		_build_detail()
		return
	# ★ 先取「改之前」的归属表，卸下拓展件后还能找到它提供的接口
	var owner: Dictionary = PCHardware.dock_layout(_draft_dev())
	var was_dock := PCHardware._is_dock_item(draft.get(slot_key, null))
	draft.erase(slot_key)
	if was_dock:
		var n := _cascade_dock_in_draft(slot_key, owner)
		if n > 0:
			_toast(TranslationManager.t("已同时卸下拓展接口上的 %d 个零件") % n)
	_build_detail()


# ============================ 列表交互（选中 / 拖动排序） ============================

func _select_device(id: String) -> void:
	if id == "":
		return
	_selected_id = id
	_close_picker()
	# ★ 只就地刷新选中态，**绝不重建列表**：重建会 queue_free 掉「正被按下/拖动」的那一行，
	#   GUI 输入系统随后访问已释放 Control → native signal 11 崩溃。
	for c in _list_container.get_children():
		var row := c as DeviceRow
		if row != null:
			row.set_selected(row.device_id == id)
	_build_detail()


## 拖动排序：把 from_id 移动到「第 gap 条缝隙」处（gap = 0..n，n 表示放到末尾）。
## ★ 缝隙语义：插到第 gap 行的**前面**；gap == n 表示插到末尾。
##   from 自己被拿掉后，它之后的索引会整体前移一格 → gap > fi 时要 -1。
func _drop_at(from_id: String, gap: int) -> void:
	if from_id == "" or gap < 0:
		return
	var ids: Array = []
	for d in Devices.get_devices():
		ids.append(str(d.get("id", "")))
	var fi := ids.find(from_id)
	if fi < 0:
		return
	ids.remove_at(fi)
	var ti := gap
	if ti > fi:
		ti -= 1
	ti = clampi(ti, 0, ids.size())
	ids.insert(ti, from_id)
	var cur: Array = []
	for d in Devices.get_devices():
		cur.append(str(d.get("id", "")))
	if cur == ids:
		return
	Devices.reorder(ids)


# ---------- 手动拖动排序（自持状态机，不走 Godot 内建 DnD）----------
# 为什么不用内建 DnD：① 它由引擎在「按住+移动超阈值」时自行发起，阈值判定依赖真实鼠标状态，
# 自动化探针无法驱动（实测 gui_get_drag_data() 恒为 null），出问题也难排查；
# ② 引擎 DnD 会跨帧持有行引用，一旦期间重建列表就访问已释放对象（正是之前 signal 11 的来源）。
# 这里改为：把柄按下 → 该行进入拖动态；后续 motion/release 由该行（按住期间鼠标聚焦）继续接收。

func _rows_of_list() -> Array:
	var out: Array = []
	for c in _list_container.get_children():
		var row := c as DeviceRow
		if row != null:
			out.append(row)
	return out


## 命中测试：指针落在第几条**缝隙**（0..n）。判据 = 与每一行的**纵向中点**比较：
## 指针在某行中点之上 → 插到该行前面。这比「命中某一行」更贴合「插到两台设备中间」的语义。
func _gap_for_drop(gpos: Vector2) -> int:
	var rows := _rows_of_list()
	if rows.is_empty():
		return -1
	for i in range(rows.size()):
		var rr := rows[i] as DeviceRow
		if gpos.y < rr.get_global_rect().get_center().y:
			return i
	return rows.size()


## 行（把柄）按下：进入拖动态，并在原地选中该设备（不重建列表，安全）。
func _on_row_drag_start(row: DeviceRow) -> void:
	if row == null or not is_instance_valid(row):
		return
	_drag_row = row
	_drop_gap = -1
	row.set_dragging(true)
	_select_device(row.device_id)


## 拖动中：高亮「松手后会插入的那条缝隙」（而不是高亮某一行）。
func _on_row_drag_move(gpos: Vector2) -> void:
	if _drag_row == null or not is_instance_valid(_drag_row):
		return
	var gap := _gap_for_drop(gpos)
	if gap == _drop_gap:
		return
	_drop_gap = gap
	if is_instance_valid(_list_container):
		_list_container.set_gap(gap)


## 松开：先彻底清理拖动状态与所有行引用，再改数据（reorder → changed → 延迟重建列表）。
## ★ 顺序很关键：绝不让「数据变更触发的列表重建」发生在仍持有行引用的时候。
func _on_row_drag_end(gpos: Vector2) -> void:
	var drag_id := ""
	if _drag_row != null and is_instance_valid(_drag_row):
		drag_id = _drag_row.device_id
	_drag_row = null
	for r in _rows_of_list():
		var rr := r as DeviceRow
		rr.set_dragging(false)
	var gap := _gap_for_drop(gpos)
	_drop_gap = -1
	if is_instance_valid(_list_container):
		_list_container.set_gap(-1)
	if drag_id == "" or gap < 0:
		return
	_drop_at(drag_id, gap)



# ============================ 事件 ============================

## 列表/详情/总览统一刷新入口。★ 一律 **延迟到帧末**执行：设备变更可能在拖动/落点处理过程中
## 触发（如拖动排序 → Devices.reorder → changed），同步重建会释放正被拖放系统引用的行 → 崩溃。
func _request_refresh() -> void:
	if _refresh_queued:
		return
	_refresh_queued = true
	call_deferred("_do_refresh")


func _do_refresh() -> void:
	_refresh_queued = false
	if not is_open():
		return
	_build_list()
	_build_detail()
	_build_overview()


func _on_devices_changed() -> void:
	if is_open():
		_request_refresh()


func _on_inventory_changed() -> void:
	if is_open():
		_build_detail()


func _on_lang_changed(_lang: String) -> void:
	_apply_lang()
	if is_open():
		_request_refresh()


func _apply_lang() -> void:
	_title.text = TranslationManager.t("设备管理")
	if _new_btn != null and is_instance_valid(_new_btn):
		_new_btn.set_label(TranslationManager.t("新建设备"))


func _center() -> void:
	var vp: Vector2 = UIStyle.canvas_viewport_size(self)
	position = (vp - size) / 2.0


# ============================ 小工具 ============================

func _label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", font_size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_instance_valid(_fnt):
		l.add_theme_font_override("font", _fnt)
	return l


func _btn(label: String, id: String) -> UIBtn:
	var b := UIBtn.new()
	b.set_label(label)
	b.set_id(id)
	b.pressed_id.connect(_on_btn_pressed)
	return b


func _apply_font_to(le: LineEdit) -> void:
	if is_instance_valid(_fnt):
		le.add_theme_font_override("font", _fnt)
	le.add_theme_font_size_override("font_size", FORM_FONT)


func _toast(text: String) -> void:
	var t := _label(text, FORM_FONT, Color(1.0, 0.85, 0.45, 1.0))
	t.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	t.offset_top = -30.0
	t.offset_bottom = -8.0
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(t)
	var timer := Timer.new()
	timer.wait_time = 1.8
	timer.one_shot = true
	timer.timeout.connect(func():
		if is_instance_valid(t):
			t.queue_free()
	)
	add_child(timer)
	timer.start()


# ============================ 设备列表行（可选中 / 可拖动排序） ============================

# 设备列表行：布局 [拖动把柄(3 条横杠) | 上线状态方框 | 设备名]。
# · 在把柄区（最左侧 GRIP_W 像素）按住 → 进入拖动态，上下拖动可排序，松手插入目标位置。
# · 把柄以外的区域点击 → 选中该设备。
# ★ 选中/拖动过程中**绝不重建本行**（重建会释放正被按住的行 → GUI 崩溃 signal 11）；
#   拖动为自持状态机（见面板 _on_row_drag_*），**不使用**引擎内建 DnD。
# ============================ 左侧列表容器 ============================

## 设备列表容器：拖动排序时**自绘一条「插入缝隙」高亮**（画在第 gap 行上方，
## 表示「松手后会落到这两台设备之间」），而不是把某一行整体高亮。
## gap = 0..n：0 = 插到第一行之前，n = 插到最后一行之后（末尾），-1 = 不显示。
class DeviceListBox extends VBoxContainer:
	const GAP_H := 3.0                       # 缝隙条厚度
	const GAP_CAP_W := 3.0                   # 两端小竖条（突出「这是一条缝隙」）
	const GAP_CAP_H := 9.0
	const GAP_COLOR := Color(0.45, 1.0, 0.70, 1.0)

	var gap: int = -1

	func set_gap(g: int) -> void:
		if gap == g:
			return
		gap = g
		queue_redraw()

	## 缝隙条的画线 y（容器本地坐标）
	func gap_y() -> float:
		var rows: Array = []
		for c in get_children():
			if c is Control and (c as Control).visible:
				rows.append(c)
		if rows.is_empty():
			return 0.0
		if gap >= rows.size():
			var last := rows[rows.size() - 1] as Control
			return last.position.y + last.size.y + 2.0
		return (rows[gap] as Control).position.y - 2.0

	func _draw() -> void:
		if gap < 0:
			return
		var y := gap_y()
		var w := size.x
		draw_rect(Rect2(0.0, y - GAP_H * 0.5, w, GAP_H), GAP_COLOR, true)
		draw_rect(Rect2(0.0, y - GAP_CAP_H * 0.5, GAP_CAP_W, GAP_CAP_H), GAP_COLOR, true)
		draw_rect(Rect2(w - GAP_CAP_W, y - GAP_CAP_H * 0.5, GAP_CAP_W, GAP_CAP_H), GAP_COLOR, true)


class DeviceRow extends Control:
	const GRIP_W := 22.0                                  # 拖动把柄宽度（与 _draw 中横杠 x 范围一致）
	const STATUS_ONLINE := Color(0.30, 0.85, 0.40)        # 绿 = 在线且状态正常
	const STATUS_DEGRADED := Color(0.95, 0.80, 0.25)      # 黄 = 在线但状态不佳（散热不足 / 功耗超限）
	const STATUS_OFFLINE := Color(0.90, 0.32, 0.32)       # 红 = 离线

	var panel: Node = null          # DeviceManagerPanel
	var device_id: String = ""
	var _lab: Label = null
	var _star: Label = null          # ★ 主力设备的黄色星星（名称前）
	var _selected := false
	var _level := "offline"         # "online" / "degraded" / "offline"
	var _dragging := false          # 是否正处于拖动中
	var _press_in_grip := false     # 本次按下是否落在把柄区
	var is_main := false            # ★ 是否为主力设备（名称前加黄色星星）

	func setup(text: String, level: String, selected: bool, fnt, main := false) -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		_level = level
		_selected = selected
		is_main = main
		# ★ 黄色星星（仅主力设备显示，绘制在设备名前面）
		_star = Label.new()
		_star.text = "★"
		_star.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_star.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_star.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_star.add_theme_font_size_override("font_size", 14)
		_star.add_theme_color_override("font_color", Color(1.0, 0.82, 0.20))
		_star.visible = is_main
		if fnt != null and is_instance_valid(fnt):
			_star.add_theme_font_override("font", fnt)
		add_child(_star)
		_lab = Label.new()
		_lab.text = text
		_lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		_lab.clip_text = true
		_lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_lab.add_theme_font_size_override("font_size", 13)
		_lab.add_theme_color_override("font_color",
			Color(0.76, 0.80, 0.86) if level == "offline" else Color.WHITE)
		if fnt != null and is_instance_valid(fnt):
			_lab.add_theme_font_override("font", fnt)
		add_child(_lab)
		_layout()
		resized.connect(_layout)
		queue_redraw()

	func set_selected(sel: bool) -> void:
		if _selected == sel:
			return
		_selected = sel
		queue_redraw()

	func set_dragging(v: bool) -> void:
		if _dragging == v:
			return
		_dragging = v
		modulate = Color(1.0, 1.0, 1.0, 0.55) if v else Color(1.0, 1.0, 1.0, 1.0)
		queue_redraw()

	## 状态方框颜色（三态）
	func status_color() -> Color:
		match _level:
			"online": return STATUS_ONLINE
			"degraded": return STATUS_DEGRADED
		return STATUS_OFFLINE

	func _layout() -> void:
		# ★ 主力设备：名称前留出一格放黄色星星（否则名字右移 18px）
		if _star != null:
			_star.position = Vector2(44.0, 0.0)
			_star.size = Vector2(18.0, size.y)
			_star.visible = is_main
		if _lab != null:
			var name_x: float = 64.0 if is_main else 46.0
			_lab.position = Vector2(name_x, 0.0)
			_lab.size = Vector2(maxf(0.0, size.x - name_x - 4.0), size.y)

	func _draw() -> void:
		# 背景（选中高亮 / 常态）
		if _selected:
			draw_rect(Rect2(Vector2.ZERO, size), Color(0.24, 0.42, 0.68, 0.85), true)
			draw_rect(Rect2(Vector2.ZERO, size), Color(0.55, 0.78, 1.0, 1.0), false, 1.0)
		else:
			draw_rect(Rect2(Vector2.ZERO, size), Color(0.16, 0.20, 0.26, 0.60), true)
			draw_rect(Rect2(Vector2.ZERO, size), Color(0.35, 0.42, 0.52, 0.80), false, 1.0)
		# ★ 拖动排序时**不高亮某一行**：插入位置由列表容器画「缝隙高亮」（见 DeviceListBox）
		# 拖动把柄：3 条横杠（x∈[5,19]）
		var bar_col := Color(0.55, 1.0, 0.80, 1.0) if _dragging else Color(0.85, 0.90, 0.98, 0.95)
		var by := size.y * 0.5 - 5.0
		for i in 3:
			draw_rect(Rect2(5.0, by + float(i) * 4.0, 14.0, 2.0), bar_col, true)
		# 上线状态方框（x∈[23,38]）：绿=在线良好，黄=在线但状态不佳，红=离线
		var box_col: Color = status_color()
		var byy := (size.y - 14.0) * 0.5
		draw_rect(Rect2(23.0, byy, 14.0, 14.0), box_col, true)
		draw_rect(Rect2(23.0, byy, 14.0, 14.0), Color(1, 1, 1, 0.55), false, 1.0)

	# 按下 → 判定是否落在把柄；松开 → 结束拖动（若在拖动态）。
	# ★ 按住期间本行始终持有鼠标焦点，motion/release 会持续送到这里（即使指针已移出本行）。
	func _gui_input(event: InputEvent) -> void:
		# ★ 右键设备名称行 → 弹出「上线 / 下线」菜单（把柄区与名称区都算「设备名称栏目」）
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed and panel != null:
				panel._open_device_menu(device_id, _event_gpos(event))
				get_viewport().set_input_as_handled()
			return
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_in_grip = event.position.x <= GRIP_W
				if panel == null:
					return
				if _press_in_grip:
					panel._on_row_drag_start(self)
				else:
					panel._select_device(device_id)
			else:
				_press_in_grip = false
				if _dragging and panel != null:
					panel._on_row_drag_end(_event_gpos(event))
				elif _dragging:
					set_dragging(false)
		elif event is InputEventMouseMotion and _dragging and panel != null:
			panel._on_row_drag_move(_event_gpos(event))

	# 把「行内局部坐标」的事件位置换算到与 get_global_rect() 同一坐标系。
	# ★ 不要用 get_global_mouse_position()：它读系统鼠标位置，与「事件自身位置」可能不一致
	#   （自动化注入合成事件时真实光标不会移动 → 排序会落到错误位置）。事件位置才是权威。
	func _event_gpos(event: InputEvent) -> Vector2:
		var me := event as InputEventMouse
		if me == null:
			return get_global_rect().get_center()
		return get_global_transform() * me.position


## 最小化 / 还原：折叠只隐藏内容，顶栏（标题 + 拖动把柄 + 最小化 + 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.apply(self, _min_btn, v, _min_btn.get_parent() if is_instance_valid(_min_btn) else null)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
