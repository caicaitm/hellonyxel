# ui/scan_reconfigure_panel.gd
# 「扫描重构」页面 —— 双击桌面「扫描重构器」积木打开。
#
# 两个框的样式取自背包页面的「物品栏」格子（UIPanel + FILL_DEFAULT@0.32 + BORDER + 圆角 0.6×），
# 只是**放大了若干倍**（SLOT_SIZE 78 → BOX 260）。两个框与各按钮**暂时没有实际用处**（纯展示）。
#
# 布局（自上而下）：
#   标题「扫描重构」+ 拖动把柄 + × 关闭
#   「预期结束时间」信息栏   ← ★ 仅在黄灯「设备工作中」亮起时显示
#   指示灯行：●设备离线(红) ●设备在线(绿) ●设备工作中(黄)   ← 当前状态高亮，其余变暗
#   输入框 → 长箭头 → 输出框   （输入框下挂「清除选择」、输出框下挂「保存」，二者暂未实现）
#   「扫描重构」按钮（居中，位于箭头下方）
#   信息栏：「所需时间」+「预期文件大小」（预留显示位）
# 入口：desktop.open_scan_reconfigure()
class_name ScanReconfigurePanel
extends Control

signal closed

const PADDING: float = 12.0
const TITLE_FONT: int = 15
const FORM_FONT: int = 13
const BTN_H: float = 26.0
const PANEL_W: float = 900.0
const PANEL_H: float = 700.0
# 最小化后的高度 = 顶栏（标题/拖动把柄/最小化/关闭，高 28）+ 上下内边距。
# ★ 与 popup_dialogue_panel 的 MIN_H 同款算法。
const MIN_H: float = 52.0

# ★ 两个框的边长：背包格子(SLOT_SIZE=78)的放大版。
#   格子样式（UIPanel + FILL_DEFAULT@0.32 + BORDER + 圆角 0.6×）与 ui/inventory_panel.gd::_make_slot 同款。
const BOX_SIZE: float = 260.0
# 框内标题（居中，上下留白）
const BOX_TITLE_FONT: int = 16

# 箭头：横杆 + 箭头三角（用自绘 Control 画，避免额外资源）
const ARROW_LEN: float = 220.0
const ARROW_THICK: float = 14.0

# 指示灯三色（与设备管理页 DeviceRow.STATUS_* 同款色系）
const LAMP_OFFLINE := Color(0.90, 0.32, 0.32)      # 红：设备离线
const LAMP_ONLINE := Color(0.30, 0.85, 0.40)       # 绿：设备在线
const LAMP_WORKING := Color(0.98, 0.80, 0.22)      # 黄：设备工作中
# 未点亮的灯：同色但压暗（保留"这里有一盏灯"的提示，而不是整行消失）
const LAMP_DIM := 0.28

# 设备状态（三个指示灯互斥，点亮其中一盏）
enum Status { OFFLINE, ONLINE, WORKING }

var _bg: UIPanel
var _content: VBoxContainer
var _title: Label
var _drag_handle: UIDragHandle
var _min_btn: UIBtn
var _close_btn: UIBtn
var _minimized: bool = false

# ★ 三个主体控件：输入框 / 箭头 / 输出框。名字给探针用（结构性查找）。
var _in_box: Control = null
var _arrow: Control = null
var _out_box: Control = null

# 「预期结束时间」信息栏（★ 仅黄灯「设备工作中」时可见）
var _eta_row: HBoxContainer = null
# 三个指示灯：Status -> _LampDot
var _lamps: Dictionary = {}
var _status: int = Status.OFFLINE

# 底部信息栏的取值 Label（预留位，暂不填真实数据）
var _eta_value: Label = null
var _cost_time_value: Label = null
var _file_size_value: Label = null

var _fnt = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	visible = false


# ============================ 公开接口 ============================

func open() -> void:
	visible = true
	_center()
	move_to_front()


func close() -> void:
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


## 公开 API：最小化（仅保留顶栏）/ 还原。
## ★ 顶栏（标题 + **拖动把柄** + 最小化 + **关闭**）是 `_content` 的第 0 个孩子，
##   本函数只隐藏第 1 个起的**内容行** → 折叠后仍能拖走页面、也能关闭。
## 与调试面板 / 弹窗对话面板同款：按钮文案「− 最小化」⇄「□ 还原」。
func set_minimized(v: bool) -> void:
	_minimized = v
	# 统一走 UIMinimize：按钮文案 + 折叠内容行（第 1 个起）+ 收窄到「顶栏刚好放下」+ 高度收到 MIN_H。
	# 顶栏（标题 + 拖动把柄 + 最小化 + 关闭）是 _content 的第 0 个孩子 → fold_below 会整排保留它。
	UIMinimize.apply(self, _min_btn, v,
		_min_btn.get_parent() if is_instance_valid(_min_btn) else null, MIN_H)


## 公开 API：当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized


# ============================ 构建 ============================

func _build_ui() -> void:
	_fnt = UIStyle.get_cjk_font()

	_bg = UIPanel.new()
	_bg.bind_page_dark_bg()
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	# ★ 深色背景：取关卡页「舞台」与设备页「总览」同款配色（FILL_LEVEL_STAGE + STAGE_BORDER），
	#   不用默认的半透明玻璃底 —— 本页是「机器在工作」的界面，深底更贴主题也更易读。
	_bg.set_fill_color(UIStyle.FILL_LEVEL_STAGE)
	_bg.set_border_color(UIStyle.STAGE_BORDER)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
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

	# 顶栏：标题 | 拖动把柄 | × 关闭
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	_title = _label(TranslationManager.t("扫描重构"), TITLE_FONT, Color.WHITE)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_title)
	_drag_handle = UIDragHandle.new()
	top.add_child(_drag_handle)
	_drag_handle.setup(self)
	# 最小化按钮（调试面板同款：− 最小化 / □ 还原）。
	# ★ 放在拖动把柄与 × 之间 → 折叠后「拖动把柄 / 最小化 / 关闭」三个都还在顶栏里。
	_min_btn = _btn("−", "minimize")
	_min_btn.custom_minimum_size = Vector2(28, 28)
	_min_btn.tooltip_text = TranslationManager.t("最小化")
	top.add_child(_min_btn)
	_close_btn = _btn("×", "close")
	_close_btn.custom_minimum_size = Vector2(28, 28)
	top.add_child(_close_btn)
	_content.add_child(top)

	# ★ ①「预期结束时间」信息栏 —— **仅黄灯「设备工作中」亮起时显示**（见 _apply_status）。
	_eta_row = _make_info_row("EtaRow", TranslationManager.t("预期结束时间"))
	_eta_value = _eta_row.get_meta("value_label")
	_eta_row.visible = false          # 默认「设备离线」→ 不显示
	_content.add_child(_eta_row)

	# ★ ② 指示灯行：红灯「设备离线」/ 绿灯「设备在线」/ 黄灯「设备工作中」。
	#   三盏灯常驻，当前状态的那盏点亮、其余压暗（不隐藏，保留"这里有三档状态"的提示）。
	var lamps := HBoxContainer.new()
	lamps.name = "LampRow"
	lamps.alignment = BoxContainer.ALIGNMENT_CENTER
	lamps.add_theme_constant_override("separation", 24)
	_content.add_child(lamps)
	_add_lamp(lamps, Status.OFFLINE, TranslationManager.t("设备离线"), LAMP_OFFLINE)
	_add_lamp(lamps, Status.ONLINE, TranslationManager.t("设备在线"), LAMP_ONLINE)
	_add_lamp(lamps, Status.WORKING, TranslationManager.t("设备工作中"), LAMP_WORKING)

	# ★ ③ 主体一行：输入框 → 长箭头 → 输出框（居中）
	var body := HBoxContainer.new()
	body.name = "ScanBody"
	body.alignment = BoxContainer.ALIGNMENT_CENTER
	body.add_theme_constant_override("separation", 16)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(body)

	# 输入框（下面挂「清除选择」按钮）
	var in_col := VBoxContainer.new()
	in_col.name = "InColumn"
	in_col.add_theme_constant_override("separation", 8)
	body.add_child(in_col)
	_in_box = _make_box(TranslationManager.t("输入"), "InputBox")
	in_col.add_child(_in_box)
	var clear_btn := _btn(TranslationManager.t("清除选择"), "clear_input")
	clear_btn.custom_minimum_size = Vector2(BOX_SIZE, BTN_H)
	in_col.add_child(clear_btn)

	_arrow = _Arrow.new()
	_arrow.name = "Arrow"
	_arrow.length = ARROW_LEN
	_arrow.thickness = ARROW_THICK
	_arrow.vertical = true
	_arrow.color = Color(0.55, 0.96, 1.0)
	_arrow.custom_minimum_size = Vector2(ARROW_LEN, BOX_SIZE)
	_arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	body.add_child(_arrow)

	# 输出框（下面挂「保存」按钮）
	var out_col := VBoxContainer.new()
	out_col.name = "OutColumn"
	out_col.add_theme_constant_override("separation", 8)
	body.add_child(out_col)
	_out_box = _make_box(TranslationManager.t("输出"), "OutputBox")
	out_col.add_child(_out_box)
	var save_btn := _btn(TranslationManager.t("保存"), "save_output")
	save_btn.custom_minimum_size = Vector2(BOX_SIZE, BTN_H)
	out_col.add_child(save_btn)

	# ★ ④「扫描重构」按钮（居中，位于箭头下方）
	var scan_row := HBoxContainer.new()
	scan_row.name = "ScanButtonRow"
	scan_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_content.add_child(scan_row)
	var scan_btn := _btn(TranslationManager.t("扫描重构"), "scan")
	scan_btn.custom_minimum_size = Vector2(180, BTN_H + 4.0)
	scan_row.add_child(scan_btn)

	# ★ ⑤ 底部信息栏：「所需时间」+「预期文件大小」（两个预留显示位）
	var info := HBoxContainer.new()
	info.name = "InfoRow"
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_theme_constant_override("separation", 40)
	_content.add_child(info)
	var t_row := _make_info_row("CostTimeRow", TranslationManager.t("所需时间"))
	_cost_time_value = t_row.get_meta("value_label")
	info.add_child(t_row)
	var s_row := _make_info_row("FileSizeRow", TranslationManager.t("预期文件大小"))
	_file_size_value = s_row.get_meta("value_label")
	info.add_child(s_row)

	# 初始状态：设备离线（红灯亮，「预期结束时间」隐藏）
	_apply_status()

	size = Vector2(PANEL_W, PANEL_H)


## 造一个「标签 + 取值」的信息栏行。取值 Label 存进 meta("value_label") 供外部/探针写入。
func _make_info_row(row_name: String, label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = row_name
	row.add_theme_constant_override("separation", 8)
	var lab := _label(label_text + "：", 13, Color(0.82, 0.90, 1.0))
	row.add_child(lab)
	var val := _label(TranslationManager.t("—"), 13, Color(1.0, 0.88, 0.55))
	val.name = "Value"
	row.add_child(val)
	row.set_meta("value_label", val)
	return row


## 加一盏指示灯（灯 + 文本）。灯存进 _lamps[status]。
func _add_lamp(parent: HBoxContainer, status: int, text: String, color: Color) -> void:
	var item := HBoxContainer.new()
	item.name = "Lamp%d" % status
	item.add_theme_constant_override("separation", 6)
	var dot := _LampDot.new()
	dot.color = color
	dot.custom_minimum_size = Vector2(14, 14)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.add_child(dot)
	var lab := _label(text, 13, Color.WHITE)
	item.add_child(lab)
	parent.add_child(item)
	_lamps[status] = {"dot": dot, "label": lab, "color": color}


## 切换设备状态：点亮对应指示灯、压暗其余两盏，并按需求显隐「预期结束时间」栏。
## ★ 只有 WORKING（黄灯「设备工作中」）才显示该栏 —— 这是需求硬性要求。
func _apply_status() -> void:
	for k in _lamps.keys():
		var st: int = int(k)
		var e: Dictionary = _lamps[st]
		var on := (st == _status)
		var dot := e["dot"] as _LampDot
		var lab := e["label"] as Label
		var base: Color = e["color"]
		if on:
			dot.color = base
			lab.add_theme_color_override("font_color", Color.WHITE)
		else:
			dot.color = Color(base.r * LAMP_DIM, base.g * LAMP_DIM, base.b * LAMP_DIM, 0.85)
			lab.add_theme_color_override("font_color", Color(0.55, 0.60, 0.68))
		dot.queue_redraw()
	if _eta_row != null:
		_eta_row.visible = (_status == Status.WORKING)


## 公开：设置设备状态（供将来的扫描流程调用；当前按钮都是占位）。
func set_status(st: int) -> void:
	_status = st
	_apply_status()


## 公开：读设备状态。
func get_status() -> int:
	return _status


## 造一个「放大的背包物品栏格子」。样式与 inventory_panel._make_slot 同款，只是尺寸放大。
## ★ 结构：Control(壳) + UIPanel(FULL_RECT 底) + Label(标题，居中) —— 三个都要进容器，
##   所以壳用固定 `custom_minimum_size` 承担尺寸，UIPanel 与 Label 走 anchors(FULL_RECT)。
func _make_box(title: String, node_name: String) -> Control:
	var box := Control.new()
	box.name = node_name
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	box.custom_minimum_size = Vector2(BOX_SIZE, BOX_SIZE)

	var sp := UIPanel.new()
	sp.set_anchors_preset(Control.PRESET_FULL_RECT)
	sp.set_corner_radius(UIStyle.CORNER_RADIUS * 0.6)
	sp.set_fill_color(Color(UIStyle.FILL_DEFAULT.r, UIStyle.FILL_DEFAULT.g, UIStyle.FILL_DEFAULT.b, 0.32))
	sp.set_border_color(UIStyle.BORDER)
	sp.set_border_width(1.0)
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(sp)

	var lab := _label(title, BOX_TITLE_FONT, Color(0.86, 0.94, 1.0))
	lab.set_anchors_preset(Control.PRESET_FULL_RECT)
	lab.offset_top = BOX_SIZE * 0.5 - 24.0
	lab.offset_bottom = BOX_SIZE * 0.5 + 24.0
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	box.add_child(lab)

	return box


func _center() -> void:
	var vp: Vector2 = UIStyle.canvas_viewport_size(self)
	position = (vp - size) * 0.5


# ============================ 事件 ============================

func _on_btn_pressed(id: String) -> void:
	if id == "close":
		close()
		return
	if id == "minimize":
		set_minimized(not _minimized)
		return
	# ★ 以下三个按钮按需求「暂时不需要有实际功能」，先只给一个占位提示。
	if id == "clear_input":
		_toast(TranslationManager.t("「清除选择」尚未实现"))
		return
	if id == "save_output":
		_toast(TranslationManager.t("「保存」尚未实现"))
		return
	if id == "scan":
		_toast(TranslationManager.t("「扫描重构」尚未实现"))
		return


## 底部轻提示（1.8 s 后自动消失）。与设备管理页同款做法。
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


# ============================ 指示灯（自绘） ============================

## 一盏圆灯：纯色圆点 + 白色描边（描边让"压暗的灯"在深色底上仍看得出轮廓）。
## 与设备管理页 `_StateDot` 同款做法。
class _LampDot extends Control:
	var color: Color = Color.WHITE

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var ctr := size * 0.5
		var r: float = minf(size.x, size.y) * 0.5
		draw_circle(ctr, r, color)
		draw_arc(ctr, r, 0.0, TAU, 20, Color(1, 1, 1, 0.55), 1.0)


# ============================ 长箭头（自绘） ============================

## 一根指向右侧的长箭头：横杆 + 右侧实心三角。自绘（`_draw`）避免额外资源依赖。
class _Arrow extends Control:
	var length: float = 220.0
	var thickness: float = 14.0
	var color: Color = Color(0.55, 0.96, 1.0)
	var vertical: bool = false     # true = 水平放置（箭头指向右）

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	## 三角形顶点（局部坐标）
	func _head() -> PackedVector2Array:
		var h: float = thickness * 2.0
		var x0: float = length
		var y0: float = size.y * 0.5
		if vertical:
			return PackedVector2Array([
				Vector2(x0, y0),
				Vector2(x0 - h, y0 - h * 0.5),
				Vector2(x0 - h, y0 + h * 0.5),
			])
		# 竖向（备用）：箭头指向上
		return PackedVector2Array([
			Vector2(size.x * 0.5, 0.0),
			Vector2(size.x * 0.5 - h * 0.5, h),
			Vector2(size.x * 0.5 + h * 0.5, h),
		])

	func _draw() -> void:
		if vertical:
			# 横杆：从 x=0 到三角起点
			var y0: float = size.y * 0.5
			var bar_end: float = length - thickness * 2.0
			draw_rect(Rect2(0.0, y0 - thickness * 0.5, bar_end, thickness), color, true)
			var pts := _head()
			draw_colored_polygon(pts, color)
		else:
			var x0: float = size.x * 0.5
			var bar_end: float = thickness * 2.0
			draw_rect(Rect2(x0, 0.0, thickness, size.y - bar_end), color, true)
			var pts2 := _head()
			draw_colored_polygon(pts2, color)
