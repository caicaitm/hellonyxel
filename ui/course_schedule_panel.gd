# ui/course_schedule_panel.gd
# 课程表 v3 面板：左侧两列调整时段（主时段 + 穿插的分时段 / 课），右侧 7 列星期。
# 交互：
#   - 单元格 / 时段均通过**右键菜单**进入编辑（也支持左键直接打开）。
#   - 时间编辑使用 TimeSpinField（时/分双滚轮，无限循环 + 拖动惯性/吸附动画）。
#   - 周数：顶部设「学期总周数」与「当前周」；单元格通过右键编辑「本节课在哪些周有」。
# 依赖：CourseSchedule（autoload，v3 模型）、UIBtn / UIPanel / UIStyle / ContextMenu / UIMinimize / TimeSpinField。
class_name CourseSchedulePanel extends Control

signal closed

const PANEL_W: float = 1010.0
const PANEL_H: float = 760.0
const TITLE_H: float = 28.0
const MAIN_W: float = 86.0
# 时段/节次标签列宽：与左侧主时段列（MAIN_W）保持一致（用户需求：分时段列太宽）。
# ★ 左两列（MAIN_W / SLOT_W）在各自 HBox 里必须设 SIZE_SHRINK_BEGIN **不参与拉伸**，
#   否则 VBox/HBox 会把余量摊给所有 FILL 子节点 → 标签列被撑宽、与主时段列错位。
#   日格用 SIZE_EXPAND_FILL 吸收全部余量（等宽），保证网格右缘始终与面板对齐。
const SLOT_W: float = 86.0
const DAY_W: float = 104.0
const CELL_H: float = 64.0
const HEADER_H: float = 26.0
const DATE_H: float = 22.0            # 日期行高度（星期表头之下）
const GRID_SEP: float = 3.0

# 高亮色：今天列（金）/ 今天列描边（冰蓝）/ 当前课程描边（亮金）
const HL_TODAY: Color = Color(1.0, 0.82, 0.35)
const HL_TODAY_BORDER: Color = Color(0.45, 0.85, 1.0)
const HL_NOW_BORDER: Color = Color(1.0, 0.72, 0.25)

# 课程编辑器「独立页」尺寸（与主面板分离的浮动页）
const EDITOR_W: float = 560.0
const EDITOR_H: float = 640.0

# 星期名（按「数据星期下标」0=周一..6=周日 的标准名）。列的**显示顺序**不在这里，
# 而由 _weekday_display_order() 依 SaveManager.calendar_week_starts_monday 决定（与日历页共用）。
const WEEKDAY_NAMES: Array[String] = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

var _bg: PanelContainer
var _title_label: Label
var _state_label: Label
var _close_btn: UIBtn
var _min_btn: UIBtn = null
var _minimized: bool = false

var _scroll: ScrollContainer
var _content: VBoxContainer
var _ctrl_row: HBoxContainer
var _semester_edit: LineEdit
var _week_toggle: UIBtn
## 「上课时为忙」开关按钮（批次 549；与性能忙闲判断页共同控制 class_busy_enabled）
var _class_busy_btn: UIBtn = null
var _current_label: Label
var _periods_vbox: VBoxContainer

# 右键菜单
var _ctx_menu: ContextMenu
var _ctx: Dictionary = {}
var _ctx_pos: Vector2 = Vector2.ZERO

# 课程编辑器「独立页」：面板的**兄弟节点**（挂到同一 ui_layer），自带 背景/标题/拖拽/最小化/关闭，
# 打开时不再遮挡课程表内容（课程表 _scroll 始终可见）。
var _editor_layer: Control
var _cell_editor: Control            # 单元格编辑页（编辑器页的内容子页）
var _period_editor: ScrollContainer  # 时段编辑页（编辑器页的内容子页）
var _editor_title: Label             # 编辑器页标题（随子页切换）
var _editor_min_btn: UIBtn = null    # 编辑器页最小化按钮
var _editor_minimized: bool = false
var _editor_centered: bool = false
var _return_to_cell: bool = false    # 从单元格页进入时段编辑后，返回时回到单元格页

# 单元格编辑器控件
var _cell_subject: LineEdit
var _cell_teacher: LineEdit          # 批次546：教学老师（可空，空=课程格不显示老师行）
var _cell_weeks_box: GridContainer
var _cell_all_weeks_cb: CheckBox
var _cell_week_cbs: Array = []
var _cell_status: Label
var _edit_ctx: Dictionary = {}

# 时段编辑器状态
var _edit_mp: int = -1

var _cjk: FontFile
var _open: bool = false
var _ever_centered: bool = false

# 「今天 / 当前课」高亮：20s 定时器比对签名，仅在跨日 / 换课时重建课程表
var _highlight_timer: Timer = null
var _last_highlight_sig: String = ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_cjk = UIStyle.get_cjk_font()
	_build_ui()
	_build_ctrl_row()
	_build_timetable_container()
	_build_editors()
	_connect_signals()
	_setup_highlight_timer()
	visible = false


func _connect_signals() -> void:
	if CourseSchedule != null and not CourseSchedule.changed.is_connected(_on_cs_changed):
		CourseSchedule.changed.connect(_on_cs_changed)
	# 「周起始」变化：与日历页共用同一设置，任一页切换都让两页同步刷新。
	if SaveManager != null and SaveManager.has_signal("calendar_week_start_changed") \
			and not SaveManager.calendar_week_start_changed.is_connected(_on_week_start_changed):
		SaveManager.calendar_week_start_changed.connect(_on_week_start_changed)
	# 「上课时为忙」开关变化（批次 549）：与性能忙闲判断页共同控制，任一页切换都同步文案。
	if BusyState != null and BusyState.has_signal("class_busy_changed") \
			and not BusyState.class_busy_changed.is_connected(_on_class_busy_changed):
		BusyState.class_busy_changed.connect(_on_class_busy_changed)


func _build_ui() -> void:
	var vs: Vector2 = UIStyle.canvas_viewport_size(self) if get_viewport() != null else Vector2(1280.0, 720.0)
	size = Vector2(PANEL_W, PANEL_H)
	position = Vector2(maxf(40.0, (vs.x - PANEL_W) * 0.5), maxf(40.0, (vs.y - PANEL_H) * 0.4))

	# ★ 深色背景：与「设备管理」页「设备性能」块**完全同款**（PanelContainer + StyleBoxFlat：
	#   FILL_LEVEL_STAGE 深蓝近黑 + STAGE_BORDER 1px + 0.6*CORNER_RADIUS 圆角 + 10/10/8/8 内容边距）。
	#   单元格/表头作为浅色玻璃砖浮在纯净深色底上，对比更强、也更耐看（批次11 起深色、
	#   批次548 换成设备性能块同款结构）。
	#   ★ 不用 UIPanel：玻璃主题下它挂 glass_blur 磨砂着色器（SCREEN_TEXTURE 模糊 + 顶部
	#     高光 + 外发光 + 渐变），填充色再深也是「磨砂玻璃」观感，与设备性能块的纯净深面板不同。
	_bg = PanelContainer.new()
	_bg.name = "Bg"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg_sb := StyleBoxFlat.new()
	bg_sb.bg_color = UIStyle.FILL_LEVEL_STAGE
	bg_sb.border_color = UIStyle.STAGE_BORDER
	bg_sb.set_border_width_all(1)
	bg_sb.set_corner_radius_all(int(UIStyle.CORNER_RADIUS * 0.6))
	bg_sb.content_margin_left = 10.0
	bg_sb.content_margin_right = 10.0
	bg_sb.content_margin_top = 8.0
	bg_sb.content_margin_bottom = 8.0
	_bg.add_theme_stylebox_override("panel", bg_sb)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	var drag := UIDragHandle.new()
	drag.name = "DragHandle"
	drag.setup(self)
	drag.anchor_left = 1.0
	drag.anchor_top = 0.0
	drag.anchor_right = 1.0
	drag.anchor_bottom = 0.0
	drag.offset_left = -(TITLE_H * 2.0 + UIStyle.PANEL_PADDING + 4.0)
	drag.offset_top = UIStyle.PANEL_PADDING
	drag.offset_right = -(TITLE_H + UIStyle.PANEL_PADDING + 4.0)
	drag.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING
	add_child(drag)

	_title_label = Label.new()
	_title_label.name = "TitleLabel"
	_title_label.text = "课程表"
	_title_label.position = Vector2(UIStyle.PANEL_PADDING + 2.0, UIStyle.PANEL_PADDING)
	_title_label.custom_minimum_size = Vector2(0.0, TITLE_H)
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", Color(0.8, 0.94, 1.0))
	_title_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 1)
	if is_instance_valid(_cjk):
		_title_label.add_theme_font_override("font", _cjk)
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_title_label)

	_state_label = Label.new()
	_state_label.name = "StateLabel"
	_state_label.text = "右键单元格 / 时段可编辑；左侧两列调整时段结构"
	_state_label.clip_text = true
	_state_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_state_label.offset_left = UIStyle.PANEL_PADDING
	_state_label.offset_top = TITLE_H + UIStyle.PANEL_PADDING
	_state_label.offset_right = -UIStyle.PANEL_PADDING
	_state_label.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING + 18.0
	_state_label.add_theme_color_override("font_color", Color(0.78, 0.86, 0.95, 0.85))
	_state_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		_state_label.add_theme_font_override("font", _cjk)
	_state_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_state_label)

	_scroll = ScrollContainer.new()
	_scroll.name = "BodyScroll"
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.offset_left = UIStyle.PANEL_PADDING
	_scroll.offset_top = TITLE_H + UIStyle.PANEL_PADDING + 22.0
	_scroll.offset_right = -UIStyle.PANEL_PADDING
	_scroll.offset_bottom = -UIStyle.PANEL_PADDING
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_scroll)

	_content = VBoxContainer.new()
	_content.name = "Content"
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 6)
	_scroll.add_child(_content)

	_close_btn = UIBtn.new()
	_close_btn.name = "CloseBtn"
	_close_btn.set_id("close")
	_close_btn.set_label("×")
	_close_btn.anchor_left = 1.0
	_close_btn.anchor_top = 0.0
	_close_btn.anchor_right = 1.0
	_close_btn.anchor_bottom = 0.0
	_close_btn.offset_left = -(TITLE_H + UIStyle.PANEL_PADDING)
	_close_btn.offset_top = UIStyle.PANEL_PADDING
	_close_btn.offset_right = -UIStyle.PANEL_PADDING
	_close_btn.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING
	_close_btn.pressed_id.connect(_on_close_pressed)
	add_child(_close_btn)
	_min_btn = UIMinimize.attach_anchored(self, _close_btn, func(): set_minimized(not _minimized))


func _build_ctrl_row() -> void:
	_ctrl_row = HBoxContainer.new()
	_ctrl_row.name = "CtrlRow"
	_ctrl_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ctrl_row.add_theme_constant_override("separation", 8)

	# 学期总周数：改用输入框（回车 / 失焦提交），不再用 ± 按钮
	var sw_title := Label.new()
	sw_title.name = "SemesterTitle"
	sw_title.text = "学期总周数"
	sw_title.custom_minimum_size = Vector2(72.0, 28.0)
	sw_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sw_title.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	sw_title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_cjk):
		sw_title.add_theme_font_override("font", _cjk)
	_ctrl_row.add_child(sw_title)

	_semester_edit = LineEdit.new()
	_semester_edit.name = "SemesterEdit"
	_semester_edit.custom_minimum_size = Vector2(56.0, 28.0)
	_semester_edit.size = Vector2(56.0, 28.0)
	_semester_edit.placeholder_text = "周数"
	_semester_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_semester_edit.max_length = 2
	_semester_edit.text = str(CourseSchedule.get_semester_weeks())
	UIStyle.apply_line_edit_style(_semester_edit)
	if is_instance_valid(_cjk):
		_semester_edit.add_theme_font_override("font", _cjk)
	_semester_edit.text_submitted.connect(_on_semester_submitted)
	_semester_edit.focus_exited.connect(_on_semester_focus_exited)
	_ctrl_row.add_child(_semester_edit)
	# 「保存」按钮：显式提交，确保总周数立即刷新（回车 / 失焦之外的确定路径）
	var sw_save := _mk_btn("sem_save", "保存", 60.0)
	sw_save.pressed_id.connect(_on_semester_save)
	_ctrl_row.add_child(sw_save)

	var cw_minus := _mk_btn("cw_minus", "当前周 −", 90.0)
	cw_minus.pressed_id.connect(_on_current_pressed.bind(-1))
	_ctrl_row.add_child(cw_minus)
	_current_label = Label.new()
	_current_label.name = "CurrentLabel"
	_current_label.custom_minimum_size = Vector2(72.0, 28.0)
	_current_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_current_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_current_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	if is_instance_valid(_cjk):
		_current_label.add_theme_font_override("font", _cjk)
	_ctrl_row.add_child(_current_label)
	var cw_plus := _mk_btn("cw_plus", "当前周 +", 90.0)
	cw_plus.pressed_id.connect(_on_current_pressed.bind(1))
	_ctrl_row.add_child(cw_plus)

	# 「周起始」开关：与日历页共用 SaveManager.calendar_week_starts_monday。
	# 任一页的按钮都写入同一设置，再由信号让两页同步刷新 —— 保证两页「周一/周日在前」始终一致。
	_week_toggle = UIBtn.new()
	_week_toggle.set_id("week_start")
	_week_toggle.set_label(_week_toggle_text())
	_week_toggle.custom_minimum_size = Vector2(120.0, 28.0)
	_week_toggle.pressed_id.connect(_on_week_toggle_pressed)
	_ctrl_row.add_child(_week_toggle)

	# 「上课时为忙」开关（批次 549）：与性能忙闲判断页按钮**共同控制**同一设置
	#   （perf_busy.json 的 class_busy_enabled，经 BusyState.set_class_busy 保存并即刻生效）。
	#   开启后：上课时间且有课程的时间段自动进入「在忙」，直到下课。
	#   任一页的按钮都写同一设置 → BusyState.class_busy_changed 信号让两页文案实时同步。
	_class_busy_btn = UIBtn.new()
	_class_busy_btn.set_id("class_busy")
	_class_busy_btn.set_label(_class_busy_text())
	_class_busy_btn.custom_minimum_size = Vector2(120.0, 28.0)
	_class_busy_btn.pressed_id.connect(_on_class_busy_pressed)
	_ctrl_row.add_child(_class_busy_btn)

	_content.add_child(_ctrl_row)

	# 提示文字**独立成行**（批次 550 修「页面宽度不足放不下所有格子」）：
	#   CtrlRow 控件多（学期周数/保存/当前周±/周起始/上课时为忙 ≈ 742px），hint 文字长
	#   （且 TranslationManager 机翻后会更长，实测 ~338px）——合在一行时整行最小宽被撑到
	#   1080 > BodyScroll 视口 1002 → 整个 Content 横向溢出 78px，右侧日格要横向滚动才看见。
	#   拆出后 CtrlRow 最小宽降到 ~742；hint 单独一行再长也 < 1002（clip 省略号兜底）。
	var hint := Label.new()
	hint.name = "HintLabel"
	hint.text = "（右键格编辑科目/老师/周次；右键时段列编辑结构）"
	hint.clip_text = true
	hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hint.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	hint.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_instance_valid(_cjk):
		hint.add_theme_font_override("font", _cjk)
	_content.add_child(hint)


func _build_timetable_container() -> void:
	_periods_vbox = VBoxContainer.new()
	_periods_vbox.name = "PeriodsVBox"
	_periods_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_periods_vbox.add_theme_constant_override("separation", 3)
	_content.add_child(_periods_vbox)


func _mk_btn(id: String, label: String, w: float) -> UIBtn:
	var b := UIBtn.new()
	b.set_id(id)
	b.set_label(label)
	b.custom_minimum_size = Vector2(w, 28.0)
	return b


# ============ 课程表构建 ============

func _rebuild_timetable() -> void:
	if _periods_vbox == null or not is_instance_valid(_periods_vbox):
		return
	# ★★ 必须先 remove_child 再 queue_free：queue_free 是**帧末延迟删除**，旧子节点当帧仍在树里，
	#   直接 add_child 同名新节点会被引擎自动改名（Header/DateRow/MainBlock_i → @HBoxContainer@NNN，
	#   名字永久丢失），且那一帧旧内容与新内容同屏渲染（闪烁）。先摘树即刻释放同名槽。
	for c in _periods_vbox.get_children():
		if is_instance_valid(c):
			_periods_vbox.remove_child(c)
			c.queue_free()
	# 今天对应的「数据星期下标」（0=周一..6=周日）：表头 / 日期行 / 今天列高亮共用
	var today_wd := _today_data_wd()
	# 表头
	var header := HBoxContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", GRID_SEP)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(MAIN_W, HEADER_H)
	spacer.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN   # 固定 MAIN_W，不参与拉伸
	header.add_child(spacer)
	var slot_hdr := Label.new()
	slot_hdr.text = "时段 / 节次"
	slot_hdr.custom_minimum_size = Vector2(SLOT_W, HEADER_H)
	slot_hdr.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN   # 固定 SLOT_W（与 MAIN_W 一致）
	slot_hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	slot_hdr.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	slot_hdr.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	slot_hdr.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_cjk):
		slot_hdr.add_theme_font_override("font", _cjk)
	header.add_child(slot_hdr)
	var order: Array = _weekday_display_order()
	for col in range(WEEKDAYS_COUNT()):
		var data_wd: int = order[col]
		var dh := Label.new()
		dh.text = WEEKDAY_NAMES[data_wd]
		dh.custom_minimum_size = Vector2(DAY_W, HEADER_H)
		dh.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # 日格吸收余量，与正文课程格对齐
		dh.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		dh.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		# 今天这一列的表头 → 金色（与日期行金色文本 / 冰蓝列描边呼应）
		dh.add_theme_color_override("font_color", HL_TODAY if data_wd == today_wd else UIStyle.TEXT_DEFAULT)
		dh.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
		if is_instance_valid(_cjk):
			dh.add_theme_font_override("font", _cjk)
		header.add_child(dh)
	_periods_vbox.add_child(header)

	# 日期行：星期表头之下，显示「本周」各星期对应的日期（周起点与日历页共用设置 → 两页联动）
	var date_row := HBoxContainer.new()
	date_row.name = "DateRow"
	date_row.add_theme_constant_override("separation", GRID_SEP)
	var dspacer := Control.new()
	dspacer.custom_minimum_size = Vector2(MAIN_W, DATE_H)
	dspacer.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN   # 固定 MAIN_W，不参与拉伸
	date_row.add_child(dspacer)
	var date_cap := Label.new()
	date_cap.text = "日期"
	date_cap.custom_minimum_size = Vector2(SLOT_W, DATE_H)
	date_cap.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN   # 固定 SLOT_W（与 MAIN_W 一致）
	date_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	date_cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	date_cap.add_theme_color_override("font_color", Color(0.62, 0.72, 0.84, 0.85))
	date_cap.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 2)
	if is_instance_valid(_cjk):
		date_cap.add_theme_font_override("font", _cjk)
	date_row.add_child(date_cap)
	for col in range(WEEKDAYS_COUNT()):
		var data_wd2: int = order[col]
		date_row.add_child(_make_date_cell(data_wd2, data_wd2 == today_wd))
	_periods_vbox.add_child(date_row)

	var mps := CourseSchedule.get_main_periods()
	for mpi in range(mps.size()):
		_periods_vbox.add_child(_build_main_block(mpi, mps[mpi], today_wd))
	# 记录本次高亮状态签名：供 20s 定时器判断「跨日 / 换课」是否需要重建
	_last_highlight_sig = _highlight_sig()


func WEEKDAYS_COUNT() -> int:
	return 7


## 当前「周起始」设置（与日历页共用，true=周一在前 / false=周日在前）。
func _week_starts_monday() -> bool:
	if SaveManager != null and SaveManager.has_method("get_calendar_week_starts_monday"):
		return bool(SaveManager.get_calendar_week_starts_monday())
	return true


## 星期列显示顺序：返回各「显示列」对应的「数据星期下标」(0=周一..6=周日)。
## 周一在前 → [0,1,2,3,4,5,6]；周日在前 → [6,0,1,2,3,4,5]。
## ★ 返回**无类型 Array**：Godot 4.7 会把「三元 + 数组字面量」静态推断成无类型 Array，
##   若声明 -> Array[int]，调用处 `var order: Array[int] = _weekday_display_order()`
##   会在运行期抛「Trying to assign an array of type Array to Array[int]」（本批探针实测）。
func _weekday_display_order() -> Array:
	if _week_starts_monday():
		return [0, 1, 2, 3, 4, 5, 6]
	return [6, 0, 1, 2, 3, 4, 5]


func _week_toggle_text() -> String:
	return ("周一在前" if _week_starts_monday() else "周日在前")


## 「上课时为忙」按钮文案（批次 549；实时读 BusyState，不缓存 → 另一页改设置后重开即最新）。
func _class_busy_text() -> String:
	var on: bool = BusyState != null and BusyState.class_busy_enabled()
	return "上课时为忙：%s" % ("开" if on else "关")


## 本页按钮：切换「上课时为忙」（写 perf_busy.json + 即刻生效；信号同步两页文案）。
func _on_class_busy_pressed(_id: String) -> void:
	if BusyState != null and BusyState.has_method("set_class_busy"):
		BusyState.set_class_busy(not (BusyState != null and BusyState.class_busy_enabled()))
	_refresh_class_busy_label()


## 另一页（性能忙闲判断）或外部改了开关 → 同步本页文案。
func _on_class_busy_changed(_enabled: bool) -> void:
	_refresh_class_busy_label()


func _refresh_class_busy_label() -> void:
	if _class_busy_btn != null and is_instance_valid(_class_busy_btn):
		_class_busy_btn.set_label(_class_busy_text())


## 日期行单元格：本周该「数据星期」对应的日期（如 "10/24"）。今天 → 金色文本。
## 周起点遵循共享的「周起始」设置（与日历页同一口径）：周一在前 → 周一为周首；
## 周日在前 → 周日为周首。两页切换任一按钮都会重排本行 → 「日期行」联动。
func _make_date_cell(data_wd: int, is_today: bool) -> UIPanel:
	var p := UIPanel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.custom_minimum_size = Vector2(DAY_W, DATE_H)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # 吸收余量，与正文课程格对齐
	p.set_corner_radius(UIStyle.CORNER_RADIUS * 0.6)
	p.set_fill_color(Color(0.09, 0.15, 0.24, 0.92))   # 深色玻璃条（浮在 FILL_LEVEL_STAGE 深底上）
	p.set_border_color(UIStyle.STAGE_BORDER)
	p.set_border_width(1.0)
	var l := Label.new()
	l.text = _week_date_label(data_wd)
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", HL_TODAY if is_today else Color(0.72, 0.82, 0.94, 0.95))
	l.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 2)
	if is_instance_valid(_cjk):
		l.add_theme_font_override("font", _cjk)
	p.add_child(l)
	return p


## 本周该「数据星期」对应的日期文本（"月/日"）。
## 今天距周首的天数：周一在前 → (sys_dow+6)%7；周日在前 → sys_dow（0=周日..6=周六）。
## 周首之后该星期的偏移：周一在前 → data_wd；周日在前 → (data_wd+1)%7。
func _week_date_label(data_wd: int) -> String:
	var t := Time.get_datetime_dict_from_system()
	var today_unix := Time.get_unix_time_from_datetime_dict(t)
	var sys_dow := _dow(int(t.get("year", 2000)), int(t.get("month", 1)), int(t.get("day", 1)))
	var days_since: int = (sys_dow + 6) % 7 if _week_starts_monday() else sys_dow
	var offset: int = data_wd if _week_starts_monday() else (data_wd + 1) % 7
	var du := Time.get_date_dict_from_unix_time(today_unix - days_since * 86400 + offset * 86400)
	return "%d/%d" % [int(du.get("month", 1)), int(du.get("day", 1))]


## 今天对应的「数据星期下标」(0=周一..6=周日)：系统星期 0=周日..6=周六 → (sys+6)%7。
func _today_data_wd() -> int:
	var t := Time.get_date_dict_from_system()
	return (_dow(int(t.get("year", 2000)), int(t.get("month", 1)), int(t.get("day", 1))) + 6) % 7


## day-of-week（0=周日 .. 6=周六）—— Sakamoto 算法（与日历页 _day_of_week 同一口径）。
func _dow(y: int, m: int, d: int) -> int:
	var tbl := [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
	var yy: int = y
	if m < 3:
		yy -= 1
	var v: int = int(yy + int(yy / 4) - int(yy / 100) + int(yy / 400) + tbl[m - 1] + d) % 7
	if v < 0:
		v += 7
	return v


## 当前时刻（分钟，0..1439）。
func _now_min() -> int:
	var t := Time.get_time_dict_from_system()
	return int(t.get("hour", 0)) * 60 + int(t.get("minute", 0))


## "HH:MM" → 分钟；非法 → -1。
func _parse_hhmm_min(hhmm: String) -> int:
	var parts := hhmm.split(":")
	if parts.size() < 2:
		return -1
	if not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return -1
	return int(parts[0]) * 60 + int(parts[1])


## 该时段的起止时间是否包含当前时刻（[start, end)）。
func _slot_contains_now(mp: int, entry: int) -> bool:
	var tm: Variant = CourseSchedule.get_slot_time(mp, entry)
	if not (tm is Dictionary):
		return false
	var s := _parse_hhmm_min(str((tm as Dictionary).get("start", "")))
	var e := _parse_hhmm_min(str((tm as Dictionary).get("end", "")))
	if s < 0 or e < 0 or e <= s:
		return false
	var n := _now_min()
	return n >= s and n < e


## 单元格高亮应用：is_now → 亮金描边 + 暖金底（当前正在上的课，进一步高亮）；
##   仅 is_today_col → 冰蓝描边 + 玻璃高光底（今天这一列）。
func _apply_cell_highlight(p: UIPanel, is_today_col: bool, is_now: bool) -> void:
	if is_now:
		p.set_fill_color(Color(1.0, 0.80, 0.32, 0.42))
		p.set_border_color(HL_NOW_BORDER)
		p.set_border_width(UIStyle.BORDER_WIDTH_HOVER)
	elif is_today_col:
		p.set_fill_color(UIStyle.FILL_HOVER)
		p.set_border_color(HL_TODAY_BORDER)
		p.set_border_width(UIStyle.BORDER_WIDTH_HOVER)


## 高亮状态签名：仅在「跨日 / 当前课变化」时值得重建。格式 "今天星期|当前课(mp:entry 或 -)"。
func _highlight_sig() -> String:
	if CourseSchedule == null:
		return ""
	var today_wd := _today_data_wd()
	var now_slot := "-"
	var mps: Array = CourseSchedule.get_main_periods()
	for mpi in range(mps.size()):
		if not (mps[mpi] is Dictionary):
			continue
		var lay: Array = (mps[mpi] as Dictionary).get("layout", [])
		for ei in range(lay.size()):
			if str(lay[ei]) != "class":
				continue
			if not _slot_contains_now(mpi, ei):
				continue
			var cell: Variant = CourseSchedule.get_cell(today_wd, mpi, ei)
			if not (cell is Dictionary):
				continue
			if str((cell as Dictionary).get("subject", "")).is_empty():
				continue
			if not CourseSchedule.is_cell_active_today(cell):
				continue
			now_slot = "%d:%d" % [mpi, ei]
			break
	return "%d|%s" % [today_wd, now_slot]


## 高亮刷新定时器：20s 一次比对高亮签名；仅在「跨日 / 换课」时重建课程表（保留滚动位置）。
## 关闭 / 最小化 / 编辑器打开时跳过（open() 与 _rebuild_timetable 会自愈签名）。
func _setup_highlight_timer() -> void:
	if CourseSchedule == null:
		return
	_highlight_timer = Timer.new()
	_highlight_timer.name = "HighlightTimer"
	_highlight_timer.wait_time = 20.0
	_highlight_timer.one_shot = false
	_highlight_timer.autostart = false
	add_child(_highlight_timer)
	_highlight_timer.timeout.connect(_on_highlight_tick)
	# 常开运行：tick 内部按 _open / 最小化 / 编辑器状态自门控（关闭时为空转，开销仅一次签名计算）
	_highlight_timer.start()


func _on_highlight_tick() -> void:
	if not _open or _minimized:
		return
	if _editor_layer != null and is_instance_valid(_editor_layer) and _editor_layer.visible:
		return
	var sig := _highlight_sig()
	if sig == _last_highlight_sig:
		return
	_last_highlight_sig = sig
	var keep := 0.0
	if _scroll != null and is_instance_valid(_scroll):
		keep = _scroll.scroll_vertical
	_rebuild_timetable()
	if keep > 0.0 and _scroll != null and is_instance_valid(_scroll):
		await get_tree().process_frame
		_scroll.scroll_vertical = keep


func _build_main_block(mp: int, mp_dict: Dictionary, today_wd: int) -> HBoxContainer:
	var block := HBoxContainer.new()
	block.name = "MainBlock_%d" % mp
	block.add_theme_constant_override("separation", GRID_SEP)
	block.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var name := str(mp_dict.get("name", "时段"))
	var lay: Array = mp_dict.get("layout", [])

	# 列1：主时段名（点击 / 右键 → 编辑时段）
	var name_panel := UIPanel.new()
	name_panel.name = "MainName"
	name_panel.custom_minimum_size = Vector2(MAIN_W, CELL_H * float(lay.size()) + GRID_SEP * float(maxi(0, lay.size() - 1)))
	name_panel.set_corner_radius(UIStyle.CORNER_RADIUS)
	name_panel.set_fill_color(UIStyle.FILL_HOVER)
	name_panel.set_border_color(UIStyle.BORDER_HOVER)
	name_panel.set_border_width(UIStyle.BORDER_WIDTH)
	name_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	name_panel.gui_input.connect(_on_main_gui_input.bind(mp))
	var nl := Label.new()
	nl.text = name
	nl.set_anchors_preset(Control.PRESET_FULL_RECT)
	nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nl.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	nl.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if is_instance_valid(_cjk):
		nl.add_theme_font_override("font", _cjk)
	name_panel.add_child(nl)
	block.add_child(name_panel)

	# 列2 + 7 列星期：按「行」组织（VBox of HBox）。几何与旧 GridContainer 等价
	#   （同行 separation=GRID_SEP、行间 separation=GRID_SEP、单元格尺寸不变），
	#   但**没课分时段**可把 7 个课程格合并为一个通栏单元格（GridContainer 无跨列能力）。
	var grid := VBoxContainer.new()
	grid.name = "MainGrid"
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("separation", GRID_SEP)

	var class_idx := 0
	for ei in range(lay.size()):
		var es := str(lay[ei])
		var is_class := (es == "class")
		var sub_name := "" if is_class else es.substr(4)
		var editable := is_class or CourseSchedule.sub_has_classes(mp, sub_name)
		var row := HBoxContainer.new()
		row.name = "SlotRow_%d" % ei
		row.add_theme_constant_override("separation", GRID_SEP)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# 列2：slot 标签（点击 / 右键 → 编辑时段）
		var slot_label := _make_slot_label(mp, ei, is_class, sub_name, class_idx)
		slot_label.custom_minimum_size = Vector2(SLOT_W, CELL_H)
		slot_label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN   # 固定 SLOT_W（与 MAIN_W 一致），不抢日格余量
		row.add_child(slot_label)
		if not is_class and not editable:
			# 没课分时段：7 个课程格合并为一整行（通栏单元格）
			row.add_child(_make_merged_noclass_cell(mp, ei, sub_name))
		else:
			# 7 列星期（按共享的「周起始」设置排序列序；data_wd 仍是数据下标 0=周一..6=周日）
			var order: Array = _weekday_display_order()
			for col in range(WEEKDAYS_COUNT()):
				var data_wd: int = order[col]
				var cell := _make_day_cell(data_wd, mp, ei, is_class, sub_name, editable, today_wd)
				cell.custom_minimum_size = Vector2(DAY_W, CELL_H)
				cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # 日格吸收余量（等宽），网格右缘贴齐面板
				row.add_child(cell)
		grid.add_child(row)
		if is_class:
			class_idx += 1
	block.add_child(grid)
	return block


## 没课分时段的通栏单元格：原 7 个「纯时间块」合并为一个整行单元格（用户需求）。
## 尺寸 = 7×DAY_W + 6×GRID_SEP（与 7 列 + 列间分隔等价）；保留右键「编辑时段」。
func _make_merged_noclass_cell(mp: int, entry: int, sub_name: String) -> UIPanel:
	var p := UIPanel.new()
	p.name = "MergedNoClass"
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.set_corner_radius(UIStyle.CORNER_RADIUS)
	p.set_fill_color(Color(0.32, 0.38, 0.46, 0.45))   # 与「纯时间块」同色
	p.set_border_color(UIStyle.BORDER)
	p.set_border_width(UIStyle.BORDER_WIDTH)
	p.custom_minimum_size = Vector2(DAY_W * float(WEEKDAYS_COUNT()) + GRID_SEP * float(WEEKDAYS_COUNT() - 1), CELL_H)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # 通栏格吸收余量：始终横跨整行
	p.gui_input.connect(_on_cell_gui_input.bind(-1, mp, entry, false, false, sub_name))
	var l := Label.new()
	l.name = "MergedLabel"
	l.text = "没课"
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", Color(0.78, 0.85, 0.93, 0.7))
	l.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		l.add_theme_font_override("font", _cjk)
	p.add_child(l)
	return p


## 列2 slot 标签：t1 = 「第 N 节」/「分：XXX」，t2 = 起止两行。
## ★ 时间字号 FONT_SIZE（原 FONT_SIZE-3 太小，用户需求放大）；本列宽已收到 MAIN_W，
##   垂直 margins 收到 2 给「13px 标题 + 2×14px 时间」留足 64px 格高。
func _make_slot_label(mp: int, entry: int, is_class: bool, sub_name: String, class_idx: int) -> UIPanel:
	var p := UIPanel.new()
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.set_corner_radius(UIStyle.CORNER_RADIUS)
	p.set_fill_color(UIStyle.FILL_DEFAULT)
	p.set_border_color(UIStyle.BORDER)
	p.set_border_width(UIStyle.BORDER_WIDTH)
	p.gui_input.connect(_on_slot_gui_input.bind(mp, entry))
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", 2)
	v.add_theme_constant_override("margin_left", 4)
	v.add_theme_constant_override("margin_top", 2)
	v.add_theme_constant_override("margin_right", 4)
	v.add_theme_constant_override("margin_bottom", 2)
	p.add_child(v)
	var t1 := Label.new()
	if is_class:
		t1.text = "第 %d 节" % (class_idx + 1)
	else:
		t1.text = "分：" + sub_name
	t1.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t1.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	t1.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		t1.add_theme_font_override("font", _cjk)
	v.add_child(t1)
	var tm := CourseSchedule.get_slot_time(mp, entry)
	var t2 := Label.new()
	t2.text = "%s\n%s" % [str(tm.get("start", "")), str(tm.get("end", ""))]
	t2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t2.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	t2.add_theme_color_override("font_color", Color(0.75, 0.83, 0.92, 0.9))
	t2.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)   # 批次546：时间字号放大（原 -3）
	if is_instance_valid(_cjk):
		t2.add_theme_font_override("font", _cjk)
	v.add_child(t2)
	return p


## 课程格（class 行 / 有课分时段行的日格）。
## 批次546：①移除「起止时间」行（时间已在列2 slot 标签展示，格内重复）②新增「教学老师」行
##   （cell.teacher 为空 → 不建 Label = 整行隐藏）③内容组垂直居中（科目不再贴顶）。
## ★ 原「纯时间块（无课）」分支随 545 合并通栏后已不可达（没课分时段一律走
##   _make_merged_noclass_cell），本函数只会收到 is_class=true 或 editable=true，故移除。
func _make_day_cell(wd: int, mp: int, entry: int, is_class: bool, sub_name: String, editable: bool, today_wd: int) -> UIPanel:
	var p := UIPanel.new()
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.set_corner_radius(UIStyle.CORNER_RADIUS)
	p.set_border_color(UIStyle.BORDER)
	p.set_border_width(UIStyle.BORDER_WIDTH)
	p.set_fill_color(UIStyle.FILL_DEFAULT)
	# 今天这一列：冰蓝描边 + 玻璃高光底（整列视觉连贯）
	if wd == today_wd:
		_apply_cell_highlight(p, true, false)
	p.gui_input.connect(_on_cell_gui_input.bind(wd, mp, entry, editable, is_class, sub_name))

	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.alignment = BoxContainer.ALIGNMENT_CENTER   # 批次546：内容组垂直居中 → 科目往中间移
	v.add_theme_constant_override("separation", 1)
	v.add_theme_constant_override("margin_left", 3)
	v.add_theme_constant_override("margin_top", 3)
	v.add_theme_constant_override("margin_right", 3)
	v.add_theme_constant_override("margin_bottom", 3)
	p.add_child(v)

	var cell: Variant = CourseSchedule.get_cell(wd, mp, entry)
	var subject := ""
	var teacher := ""
	var weeks: Array = []
	if cell is Dictionary:
		subject = str((cell as Dictionary).get("subject", ""))
		teacher = str((cell as Dictionary).get("teacher", ""))
		weeks = (cell as Dictionary).get("weeks", [])
	var active := CourseSchedule.is_cell_active_today(cell)
	# 当前正在上的课（今天列 + 本节课 + 本周有效 + 此刻落在起止内）→ 进一步高亮
	if wd == today_wd and is_class and active and not subject.is_empty() and _slot_contains_now(mp, entry):
		_apply_cell_highlight(p, true, true)
	var sl := Label.new()
	sl.name = "SubjectLabel"
	sl.text = subject if not subject.is_empty() else "—"
	sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sl.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT if active else Color(0.6, 0.66, 0.72, 0.6))
	sl.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_cjk):
		sl.add_theme_font_override("font", _cjk)
	v.add_child(sl)
	# 教学老师（批次546：不填时不建 Label = 整行隐藏；随「非本周」一起变暗）
	if not teacher.is_empty():
		var tch := Label.new()
		tch.name = "TeacherLabel"
		tch.text = teacher
		tch.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tch.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		tch.add_theme_color_override("font_color", Color(0.72, 0.82, 0.92, 0.9) if active else Color(0.6, 0.66, 0.72, 0.6))
		tch.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 2)
		if is_instance_valid(_cjk):
			tch.add_theme_font_override("font", _cjk)
		v.add_child(tch)
	if not active:
		var wl := Label.new()
		wl.text = "（非本周）"
		wl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		wl.add_theme_color_override("font_color", Color(0.9, 0.7, 0.7, 0.8))
		wl.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 4)
		if is_instance_valid(_cjk):
			wl.add_theme_font_override("font", _cjk)
		v.add_child(wl)
	return p


# ============ 右键 / 左键 交互 ============

func _on_cell_gui_input(event: InputEvent, wd: int, mp: int, entry: int, editable: bool, is_class: bool, sub_name: String) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_ctx = {"kind": "cell", "wd": wd, "mp": mp, "entry": entry, "editable": editable}
			_ctx_pos = mb.global_position
			_open_cell_menu(editable)
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and editable:
			_open_cell_editor(wd, mp, entry)


func _on_slot_gui_input(event: InputEvent, mp: int, entry: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_ctx = {"kind": "slot", "mp": mp, "entry": entry}
			_ctx_pos = mb.global_position
			_open_context([{"label": "编辑时段...", "id": "edit_period"}], [])
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_open_period_editor(mp)


func _on_main_gui_input(event: InputEvent, mp: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_ctx = {"kind": "main", "mp": mp}
			_ctx_pos = mb.global_position
			var items := [
				{"label": "编辑时段...", "id": "edit_period"},
				{"separator": true},
				{"label": "上移时段", "id": "main_up"},
				{"label": "下移时段", "id": "main_down"},
			]
			_open_context(items, [])
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_open_period_editor(mp)


func _open_cell_menu(editable: bool) -> void:
	var items: Array = []
	if editable:
		items.append({"label": "编辑这节课...", "id": "edit_cell"})
		items.append({"label": "清空", "id": "clear_cell"})
		items.append({"separator": true})
	items.append({"label": "编辑时段...", "id": "edit_period"})
	_open_context(items, [])


# 上下文菜单挂到「本面板所在的 CanvasLayer」（即 ui_layer，与 desktop 的 menu 同层），
# 不能挂到本面板下：本面板在 ui_layer 树序里排在 popup_dlg / bottom_dlg 之前，
# 菜单作为面板子节点会被更上层的全屏弹层盖住 → 真机里「菜单创建了、visible=true、落点也对，
# 但被上层弹层遮掉，肉眼看不见」（headless 只查 visible 标志查不出，所以探针一直 PASS）。
# desktop 的菜单加到 ui_layer 才一直正常，这里对齐。找不到 CanvasLayer 时退回挂本面板。
func _ctx_layer() -> Node:
	var n: Node = self
	while n != null:
		if n is CanvasLayer:
			return n
		n = n.get_parent()
	return self

func _open_context(items: Array, _sub: Array) -> void:
	if _ctx_menu == null or not is_instance_valid(_ctx_menu):
		_ctx_menu = ContextMenu.new()
		_ctx_layer().add_child(_ctx_menu)
		_ctx_menu.item_selected.connect(_on_ctx_selected)
	# ★★ `_ctx_pos` 来自 `mb.global_position`（**屏幕像素**），但 `ContextMenu.open()` 把入参当
	#    「菜单所在画布」坐标用（其内部 `global_position` / 夹取都按画布空间算）。本面板挂在
	#    ui_layer（CanvasLayer，带 UI 缩放）下，缩放 ≠ 1 时若直接传屏幕像素，菜单会被摆到
	#    「屏幕坐标 × 缩放」处（往往飞出屏幕 → 表现为点不开）。必须先换算到画布坐标。
	_ctx_menu.open(UIStyle.screen_to_canvas(self, _ctx_pos), items)


func _on_ctx_selected(id: String, _path: PackedStringArray) -> void:
	if not _ctx.has("kind"):
		return
	var kind := str(_ctx["kind"])
	if id == "edit_period":
		var mp := int(_ctx.get("mp", -1))
		_open_period_editor(mp)
		return
	if id.begins_with("addsub:"):
		var sname := id.substr(7)
		var mp_dict: Variant = CourseSchedule.get_main_period(_edit_mp)
		if mp_dict is Dictionary:
			var lay: Array = (mp_dict as Dictionary).get("layout", [])
			CourseSchedule.insert_layout_entry(_edit_mp, lay.size(), "sub:" + sname)
			_rebuild_period_editor()
		return
	if id == "noop":
		return
	if id == "edit_cell":
		var wd := int(_ctx.get("wd", 0))
		var mp := int(_ctx.get("mp", -1))
		var entry := int(_ctx.get("entry", -1))
		_open_cell_editor(wd, mp, entry)
		return
	if id == "clear_cell":
		var wd := int(_ctx.get("wd", 0))
		var mp := int(_ctx.get("mp", -1))
		var entry := int(_ctx.get("entry", -1))
		CourseSchedule.clear_cell(wd, mp, entry)
		return
	if id == "main_up":
		var mp := int(_ctx.get("mp", -1))
		if mp > 0:
			CourseSchedule.move_main_period(mp, mp - 1)
		return
	if id == "main_down":
		var mp := int(_ctx.get("mp", -1))
		var n := CourseSchedule.get_main_count()
		if mp >= 0 and mp < n - 1:
			CourseSchedule.move_main_period(mp, mp + 1)
		return


# ============ 编辑器层 ============

func _build_editors() -> void:
	# ★ 编辑器改为「独立页」：作为课程表面板的**兄弟节点**挂到同一 CanvasLayer（ui_layer），
	#   自带 背景 + 标题栏（拖动移动 / 最小化 / 关闭）—— 打开时不再遮挡课程表内容，
	#   课程表 _scroll 始终可见。（_ready 时面板已在树中，get_parent() 即 ui_layer）
	_editor_layer = Control.new()
	_editor_layer.name = "CourseEditorPage"
	_editor_layer.size = Vector2(EDITOR_W, EDITOR_H)
	_editor_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	_editor_layer.visible = false
	var host: Node = get_parent()
	if host == null:
		host = self
	host.add_child(_editor_layer)

	# 页面背景：与「设备管理」页「设备性能」块**完全同款**（PanelContainer + StyleBoxFlat：
	# FILL_LEVEL_STAGE + STAGE_BORDER 1px + 0.6*CORNER_RADIUS 圆角 + 10/10/8/8 内容边距；批次547
	# 由白玻璃改深色、批次548 换成同款结构）。编辑器内文字密集，纯净深色底托住浅色输入框。
	# ★ 不用 UIPanel：玻璃主题下它挂 glass_blur 磨砂着色器，观感与设备性能块的纯净深面板不同。
	var bg := PanelContainer.new()
	bg.name = "PageBg"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg_sb := StyleBoxFlat.new()
	bg_sb.bg_color = UIStyle.FILL_LEVEL_STAGE
	bg_sb.border_color = UIStyle.STAGE_BORDER
	bg_sb.set_border_width_all(1)
	bg_sb.set_corner_radius_all(int(UIStyle.CORNER_RADIUS * 0.6))
	bg_sb.content_margin_left = 10.0
	bg_sb.content_margin_right = 10.0
	bg_sb.content_margin_top = 8.0
	bg_sb.content_margin_bottom = 8.0
	bg.add_theme_stylebox_override("panel", bg_sb)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_editor_layer.add_child(bg)

	# 拖动移动把柄（复用项目页面位置移动按钮）
	var drag := UIDragHandle.new()
	drag.name = "DragHandle"
	drag.setup(_editor_layer)
	drag.anchor_left = 1.0
	drag.anchor_top = 0.0
	drag.anchor_right = 1.0
	drag.anchor_bottom = 0.0
	drag.offset_left = -(TITLE_H * 2.0 + UIStyle.PANEL_PADDING + 4.0)
	drag.offset_top = UIStyle.PANEL_PADDING
	drag.offset_right = -(TITLE_H + UIStyle.PANEL_PADDING + 4.0)
	drag.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING
	_editor_layer.add_child(drag)

	# 标题（随子页切换）
	_editor_title = Label.new()
	_editor_title.name = "TitleLabel"
	_editor_title.text = "编辑"
	_editor_title.position = Vector2(UIStyle.PANEL_PADDING + 2.0, UIStyle.PANEL_PADDING)
	_editor_title.custom_minimum_size = Vector2(0.0, TITLE_H)
	_editor_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_editor_title.add_theme_color_override("font_color", Color(0.8, 0.94, 1.0))
	_editor_title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 1)
	if is_instance_valid(_cjk):
		_editor_title.add_theme_font_override("font", _cjk)
	_editor_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_editor_layer.add_child(_editor_title)

	# 关闭按钮
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
	close_btn.pressed_id.connect(_close_editors)
	_editor_layer.add_child(close_btn)
	# 最小化按钮（复用项目页面最小化按钮）
	_editor_min_btn = UIMinimize.attach_anchored(_editor_layer, close_btn, func(): _set_editor_minimized(not _editor_minimized))

	# 内容子页：单元格编辑页 + 时段编辑页（标题栏之下，切换显隐）
	_cell_editor = Control.new()
	_cell_editor.name = "CellEditorPage"
	_cell_editor.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cell_editor.offset_left = UIStyle.PANEL_PADDING
	_cell_editor.offset_top = TITLE_H + UIStyle.PANEL_PADDING
	_cell_editor.offset_right = -UIStyle.PANEL_PADDING
	_cell_editor.offset_bottom = -UIStyle.PANEL_PADDING
	_cell_editor.mouse_filter = Control.MOUSE_FILTER_STOP
	_cell_editor.visible = false
	_editor_layer.add_child(_cell_editor)
	_build_cell_editor()

	_period_editor = ScrollContainer.new()
	_period_editor.name = "PeriodEditor"
	_period_editor.set_anchors_preset(Control.PRESET_FULL_RECT)
	_period_editor.offset_left = UIStyle.PANEL_PADDING
	_period_editor.offset_top = TITLE_H + UIStyle.PANEL_PADDING
	_period_editor.offset_right = -UIStyle.PANEL_PADDING
	_period_editor.offset_bottom = -UIStyle.PANEL_PADDING
	_period_editor.mouse_filter = Control.MOUSE_FILTER_STOP
	_period_editor.visible = false
	_editor_layer.add_child(_period_editor)


func _build_cell_editor() -> void:
	# 表单滚动区（单元格编辑页内容；页面级 背景/标题/拖拽/最小化/关闭 由 _editor_layer 独立页提供）
	var scroll := ScrollContainer.new()
	scroll.name = "FormScroll"
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	_cell_editor.add_child(scroll)

	var v := VBoxContainer.new()
	v.name = "CellEditorBody"
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 8)
	scroll.add_child(v)

	var sub_row := HBoxContainer.new()
	sub_row.add_theme_constant_override("separation", 6)
	var sub_lbl := Label.new()
	sub_lbl.text = "科目："
	sub_lbl.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	if is_instance_valid(_cjk):
		sub_lbl.add_theme_font_override("font", _cjk)
	sub_row.add_child(sub_lbl)
	_cell_subject = LineEdit.new()
	_cell_subject.placeholder_text = "输入科目名"
	_cell_subject.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var fnt = UIStyle.get_cjk_font()
	if fnt != null:
		_cell_subject.add_theme_font_override("font", fnt)
	_cell_subject.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	sub_row.add_child(_cell_subject)
	v.add_child(sub_row)

	# 教学老师（批次546：可空；空 = 课程格不显示老师行）
	var tch_row := HBoxContainer.new()
	tch_row.add_theme_constant_override("separation", 6)
	var tch_lbl := Label.new()
	tch_lbl.text = "教学老师："
	tch_lbl.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	if is_instance_valid(_cjk):
		tch_lbl.add_theme_font_override("font", _cjk)
	tch_row.add_child(tch_lbl)
	_cell_teacher = LineEdit.new()
	_cell_teacher.placeholder_text = "输入老师姓名（可不填）"
	_cell_teacher.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if fnt != null:
		_cell_teacher.add_theme_font_override("font", fnt)
	_cell_teacher.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	tch_row.add_child(_cell_teacher)
	v.add_child(tch_row)

	var wk_lbl := Label.new()
	wk_lbl.text = "在哪些周有（不勾 = 每周都上）："
	wk_lbl.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	if is_instance_valid(_cjk):
		wk_lbl.add_theme_font_override("font", _cjk)
	v.add_child(wk_lbl)

	_cell_week_cbs = []
	_cell_weeks_box = GridContainer.new()
	_cell_weeks_box.columns = 10
	_cell_weeks_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_cell_weeks_box)

	_cell_all_weeks_cb = CheckBox.new()
	_cell_all_weeks_cb.text = "每周都上"
	_cell_all_weeks_cb.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	if is_instance_valid(_cjk):
		_cell_all_weeks_cb.add_theme_font_override("font", _cjk)
	_cell_weeks_box.add_child(_cell_all_weeks_cb)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	var save_btn := _mk_btn("cell_save", "保存", 90.0)
	save_btn.pressed_id.connect(_on_cell_save)
	btn_row.add_child(save_btn)
	var del_btn := _mk_btn("cell_del", "清空此格", 110.0)
	del_btn.pressed_id.connect(_on_cell_delete)
	btn_row.add_child(del_btn)
	var period_btn := _mk_btn("cell_period", "编辑时段...", 120.0)
	period_btn.pressed_id.connect(_on_edit_period_from_cell)
	btn_row.add_child(period_btn)
	var back_btn := _mk_btn("cell_back", "返回课程表", 120.0)
	back_btn.pressed_id.connect(_close_editors)
	btn_row.add_child(back_btn)
	v.add_child(btn_row)

	_cell_status = Label.new()
	_cell_status.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	if is_instance_valid(_cjk):
		_cell_status.add_theme_font_override("font", _cjk)
	v.add_child(_cell_status)


func _open_cell_editor(wd: int, mp: int, entry: int) -> void:
	if not _is_slot_editable(mp, entry):
		return
	_edit_ctx = {"wd": wd, "mp": mp, "entry": entry}
	var slot: Variant = CourseSchedule.lookup_slot(mp, entry)
	var slot_text := "第 %d 节" % (CourseSchedule.class_index_in_main(mp, entry) + 1) if (slot != null and str(slot.get("kind", "")) == "class") else ("分：" + str(slot.get("sub_name", "")) if slot != null else "")
	if _editor_title != null and is_instance_valid(_editor_title):
		_editor_title.text = "编辑这节课 · %s · %s" % [WEEKDAY_NAMES[wd], slot_text]
	var cell: Variant = CourseSchedule.get_cell(wd, mp, entry)
	var subject := ""
	var teacher := ""
	var weeks: Array = []
	if cell is Dictionary:
		subject = str((cell as Dictionary).get("subject", ""))
		teacher = str((cell as Dictionary).get("teacher", ""))
		weeks = (cell as Dictionary).get("weeks", [])
	_cell_subject.text = subject
	_cell_teacher.text = teacher
	_rebuild_week_checks(weeks)
	_cell_status.text = ""
	_show_editor(_cell_editor)


func _rebuild_week_checks(selected: Array) -> void:
	for c in _cell_weeks_box.get_children():
		if is_instance_valid(c) and c != _cell_all_weeks_cb:
			c.queue_free()
	_cell_week_cbs = []
	var n := CourseSchedule.get_semester_weeks()
	_cell_all_weeks_cb.button_pressed = selected.is_empty()
	for i in range(n):
		var cb := CheckBox.new()
		cb.text = "%d" % (i + 1)
		cb.button_pressed = (i + 1) in selected
		cb.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
		if is_instance_valid(_cjk):
			cb.add_theme_font_override("font", _cjk)
		_cell_weeks_box.add_child(cb)
		_cell_week_cbs.append(cb)


func _on_cell_save(_id: String) -> void:
	if not _edit_ctx.has("wd"):
		return
	var wd := int(_edit_ctx["wd"])
	var mp := int(_edit_ctx["mp"])
	var entry := int(_edit_ctx["entry"])
	var weeks: Array = []
	if not _cell_all_weeks_cb.button_pressed:
		for i in range(_cell_week_cbs.size()):
			if _cell_week_cbs[i].button_pressed:
				weeks.append(i + 1)
	CourseSchedule.set_cell(wd, mp, entry, _cell_subject.text, weeks, _cell_teacher.text)
	_cell_status.text = "已保存"
	# 保存后返回
	_close_editors()


func _on_cell_delete(_id: String) -> void:
	if not _edit_ctx.has("wd"):
		return
	var wd := int(_edit_ctx["wd"])
	var mp := int(_edit_ctx["mp"])
	var entry := int(_edit_ctx["entry"])
	CourseSchedule.clear_cell(wd, mp, entry)
	_close_editors()


## 单元格页「编辑时段...」：跳到该主时段的时段编辑（返回时回到单元格页）。
func _on_edit_period_from_cell(_id: String) -> void:
	if not _edit_ctx.has("mp"):
		return
	_return_to_cell = true
	_open_period_editor(int(_edit_ctx["mp"]))


## 时段编辑页返回：若从单元格页进入则回到单元格页，否则回到课程表。
func _on_period_back(_id: String) -> void:
	if _return_to_cell and _edit_ctx.has("wd"):
		_return_to_cell = false
		_open_cell_editor(int(_edit_ctx["wd"]), int(_edit_ctx["mp"]), int(_edit_ctx["entry"]))
	else:
		_close_editors()


func _is_slot_editable(mp: int, entry: int) -> bool:
	return CourseSchedule.is_slot_editable(mp, entry)


# ============ 时段编辑器 ============

func _open_period_editor(mp: int) -> void:
	if mp < 0 or mp >= CourseSchedule.get_main_count():
		return
	_edit_mp = mp
	if _editor_title != null and is_instance_valid(_editor_title):
		_editor_title.text = "编辑时段"
	_rebuild_period_editor()
	_show_editor(_period_editor)


func _rebuild_period_editor() -> void:
	# 同 _rebuild_timetable 纪律：先 remove_child 再 queue_free（帧末延迟删除 + 同名自动改名）
	for c in _period_editor.get_children():
		if is_instance_valid(c):
			_period_editor.remove_child(c)
			c.queue_free()
	var mp_dict: Variant = CourseSchedule.get_main_period(_edit_mp)
	if mp_dict == null or not (mp_dict is Dictionary):
		return
	var fnt := UIStyle.get_cjk_font()
	var v := VBoxContainer.new()
	v.name = "PeriodEditorBody"
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 12)
	_period_editor.add_child(v)

	var title := Label.new()
	title.text = "编辑时段：「%s」" % str(mp_dict.get("name", ""))
	title.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 1)
	if is_instance_valid(_cjk):
		title.add_theme_font_override("font", _cjk)
	v.add_child(title)

	# 主时段名
	_gap(v, 2)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 10)
	name_row.alignment = BoxContainer.ALIGNMENT_CENTER
	var nl_lbl := Label.new()
	nl_lbl.text = "名称："
	nl_lbl.custom_minimum_size = Vector2(0.0, 30.0)
	nl_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nl_lbl.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	if is_instance_valid(_cjk):
		nl_lbl.add_theme_font_override("font", _cjk)
	name_row.add_child(nl_lbl)
	var name_edit := LineEdit.new()
	name_edit.text = str(mp_dict.get("name", ""))
	name_edit.custom_minimum_size = Vector2(0.0, 30.0)
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if fnt != null:
		name_edit.add_theme_font_override("font", fnt)
	name_edit.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	UIStyle.apply_line_edit_style(name_edit)
	name_edit.text_submitted.connect(func(t): CourseSchedule.rename_main_period(_edit_mp, t))
	name_row.add_child(name_edit)
	v.add_child(name_row)

	# 整体起止（大滚轮；起 / 止各自带 caption，间距拉开）
	_section_title(v, "整体起止")
	var time_row := HBoxContainer.new()
	time_row.add_theme_constant_override("separation", 20)
	time_row.alignment = BoxContainer.ALIGNMENT_CENTER
	time_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var sbox := VBoxContainer.new()
	sbox.add_theme_constant_override("separation", 4)
	sbox.alignment = BoxContainer.ALIGNMENT_CENTER
	sbox.add_child(_mini_label("起始"))
	var start_ts := TimeSpinField.new()
	start_ts.set_time_str(str(mp_dict.get("start", "08:00")))
	start_ts.time_changed.connect(func(h, m): _set_main_period_start(_edit_mp, _hhmm(h, m)))
	sbox.add_child(start_ts)
	time_row.add_child(sbox)
	var tilde_big := _tilde_label(true)
	tilde_big.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	time_row.add_child(tilde_big)
	var ebox := VBoxContainer.new()
	ebox.add_theme_constant_override("separation", 4)
	ebox.alignment = BoxContainer.ALIGNMENT_CENTER
	ebox.add_child(_mini_label("结束"))
	var end_ts := TimeSpinField.new()
	end_ts.set_time_str(str(mp_dict.get("end", "12:00")))
	end_ts.time_changed.connect(func(h, m): _set_main_period_end(_edit_mp, _hhmm(h, m)))
	ebox.add_child(end_ts)
	time_row.add_child(ebox)
	v.add_child(time_row)

	# 穿插顺序
	_section_title(v, "穿插顺序（课 / 分时段）")

	var lay: Array = mp_dict.get("layout", [])
	for ei in range(lay.size()):
		var es := str(lay[ei])
		var is_class := (es == "class")
		var sub_name := "" if is_class else es.substr(4)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		var badge := Label.new()
		badge.text = "课" if is_class else ("分:" + sub_name)
		badge.custom_minimum_size = Vector2(72.0, 30.0)
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		badge.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
		if is_instance_valid(_cjk):
			badge.add_theme_font_override("font", _cjk)
		row.add_child(badge)
		var up := _mk_btn("lay_up_%d" % ei, "↑", 34.0)
		up.pressed_id.connect(_on_layout_move.bind(ei, -1))
		row.add_child(up)
		var down := _mk_btn("lay_down_%d" % ei, "↓", 34.0)
		down.pressed_id.connect(_on_layout_move.bind(ei, 1))
		row.add_child(down)
		var rm := _mk_btn("lay_rm_%d" % ei, "×", 34.0)
		rm.pressed_id.connect(_on_layout_remove.bind(ei))
		row.add_child(rm)
		v.add_child(row)

	var lay_btn_row := HBoxContainer.new()
	lay_btn_row.add_theme_constant_override("separation", 8)
	lay_btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	var add_class := _mk_btn("add_class", "+ 加一节课", 110.0)
	add_class.pressed_id.connect(_on_layout_add_class)
	lay_btn_row.add_child(add_class)
	var add_sub := _mk_btn("add_sub_entry", "+ 加分时段到穿插", 150.0)
	add_sub.pressed_id.connect(_on_layout_add_sub_menu)
	lay_btn_row.add_child(add_sub)
	v.add_child(lay_btn_row)

	# 分时段管理
	_section_title(v, "分时段（归属本主时段）")

	var subs: Dictionary = mp_dict.get("subs", {})
	for sname in subs.keys():
		_build_sub_row(v, sname, subs[sname])

	var sub_add_row := HBoxContainer.new()
	sub_add_row.add_theme_constant_override("separation", 8)
	sub_add_row.alignment = BoxContainer.ALIGNMENT_CENTER
	var sub_name_edit := LineEdit.new()
	sub_name_edit.placeholder_text = "新分时段名"
	sub_name_edit.custom_minimum_size = Vector2(150.0, 30.0)
	sub_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if fnt != null:
		sub_name_edit.add_theme_font_override("font", fnt)
	sub_name_edit.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	UIStyle.apply_line_edit_style(sub_name_edit)
	sub_add_row.add_child(sub_name_edit)
	var sub_hc := CheckBox.new()
	sub_hc.text = "有课"
	sub_hc.button_pressed = false
	sub_hc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sub_hc.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	if is_instance_valid(_cjk):
		sub_hc.add_theme_font_override("font", _cjk)
	sub_add_row.add_child(sub_hc)
	var sub_add := _mk_btn("sub_add", "+ 新建分时段", 120.0)
	sub_add.pressed_id.connect(_on_sub_add.bind(sub_name_edit, sub_hc))
	sub_add_row.add_child(sub_add)
	v.add_child(sub_add_row)

	# 每节课时间 + 批量
	_section_title(v, "每节课时间（按穿插顺序）")

	var class_times: Array = mp_dict.get("class_times", [])
	var cidx := 0
	for ei in range(lay.size()):
		if str(lay[ei]) != "class":
			continue
		var ct: Dictionary = class_times[cidx] if cidx < class_times.size() and (class_times[cidx] is Dictionary) else {"start": "08:00", "end": "08:45"}
		_build_class_time_row(v, cidx, ct)
		cidx += 1

	# 批量填充
	_section_title(v, "批量设置（从第 1 节起）")
	var batch_row := HBoxContainer.new()
	batch_row.add_theme_constant_override("separation", 8)
	batch_row.alignment = BoxContainer.ALIGNMENT_CENTER
	batch_row.add_child(_mini_label("起始"))
	var bs_ts := TimeSpinField.new()
	bs_ts.set_density(24.0, 3)
	bs_ts.set_time_str("08:00")
	batch_row.add_child(bs_ts)
	batch_row.add_child(_mini_label("每节(分)"))
	var dur_edit := LineEdit.new()
	dur_edit.text = "45"
	dur_edit.custom_minimum_size = Vector2(52.0, 30.0)
	if fnt != null:
		dur_edit.add_theme_font_override("font", fnt)
	dur_edit.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	UIStyle.apply_line_edit_style(dur_edit)
	batch_row.add_child(dur_edit)
	batch_row.add_child(_mini_label("课间(分)"))
	var gap_edit := LineEdit.new()
	gap_edit.text = "10"
	gap_edit.custom_minimum_size = Vector2(52.0, 30.0)
	if fnt != null:
		gap_edit.add_theme_font_override("font", fnt)
	gap_edit.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	UIStyle.apply_line_edit_style(gap_edit)
	batch_row.add_child(gap_edit)
	var batch_btn := _mk_btn("batch_fill", "一键填充", 100.0)
	batch_btn.pressed_id.connect(func(_id): _on_batch_fill(bs_ts, dur_edit, gap_edit))
	batch_row.add_child(batch_btn)
	v.add_child(batch_row)

	# 返回
	_gap(v, 6)
	var back := _mk_btn("period_back", "返回课程表", 120.0)
	back.pressed_id.connect(_on_period_back)
	v.add_child(back)


func _hhmm(h: int, m: int) -> String:
	return "%02d:%02d" % [clampi(int(h), 0, 23), clampi(int(m), 0, 59)]


# ============ 时段编辑页：布局小件 + 实时写回 ============
# ★ 编辑器打开期间底层课程表**不重建**（避免打断拖拽），所以时间回调一律**实时读**
#   CourseSchedule 再写：捕构建期快照会把另一端冲掉（先改「止」再改「起」→ 止 回退）。

## 行间距占位（VBox 里统一 separation 之外的额外呼吸空间）。
func _gap(v: VBoxContainer, h: float) -> void:
	var g := Control.new()
	g.custom_minimum_size = Vector2(0.0, h)
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(g)


## 分节标题（上方留间距 + 冰蓝色）。
func _section_title(v: VBoxContainer, text: String) -> void:
	_gap(v, 4)
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.78, 0.90, 1.0))
	l.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 1)
	if is_instance_valid(_cjk):
		l.add_theme_font_override("font", _cjk)
	v.add_child(l)


## 小标签（滚轮 caption / 行内标签，垂直居中）。
func _mini_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	l.add_theme_color_override("font_color", Color(0.72, 0.85, 0.96))
	l.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		l.add_theme_font_override("font", _cjk)
	return l


## 起止之间的「~」。
func _tilde_label(big: bool = false) -> Label:
	var l := Label.new()
	l.text = "~"
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	l.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + (8 if big else 2))
	if is_instance_valid(_cjk):
		l.add_theme_font_override("font", _cjk)
	return l


## 造一对「起 ~ 止」滚轮（compact=True 用紧凑密度 24/3）。set_time_str 先于 connect，
## 避免构建期回显触发写库。
func _mk_time_pair(compact: bool, start_str: String, end_str: String, on_start: Callable, on_end: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var s := TimeSpinField.new()
	if compact:
		s.set_density(24.0, 3)
	s.set_time_str(start_str)
	s.time_changed.connect(on_start)
	row.add_child(s)
	row.add_child(_tilde_label())
	var e := TimeSpinField.new()
	if compact:
		e.set_density(24.0, 3)
	e.set_time_str(end_str)
	e.time_changed.connect(on_end)
	row.add_child(e)
	return row


func _set_main_period_start(mp: int, start: String) -> void:
	var d: Variant = CourseSchedule.get_main_period(mp)
	var end := "12:00"
	if d is Dictionary:
		end = str((d as Dictionary).get("end", end))
	CourseSchedule.set_main_period_times(mp, start, end)


func _set_main_period_end(mp: int, end: String) -> void:
	var d: Variant = CourseSchedule.get_main_period(mp)
	var start := "08:00"
	if d is Dictionary:
		start = str((d as Dictionary).get("start", start))
	CourseSchedule.set_main_period_times(mp, start, end)


## 第 ci 节课起/止（实时读当前值再写）。
func _set_class_time_bound(mp: int, ci: int, is_start: bool, hhmm: String) -> void:
	var d: Variant = CourseSchedule.get_main_period(mp)
	var start := "08:00"
	var end := "08:45"
	if d is Dictionary:
		var times: Array = (d as Dictionary).get("class_times", [])
		if ci >= 0 and ci < times.size() and (times[ci] is Dictionary):
			start = str((times[ci] as Dictionary).get("start", start))
			end = str((times[ci] as Dictionary).get("end", end))
	if is_start:
		start = hhmm
	else:
		end = hhmm
	CourseSchedule.set_class_time(mp, ci, start, end)


## 分时段起/止（实时读当前值再写，保留 has_classes）。
func _set_sub_bound(mp: int, sname: String, is_start: bool, hhmm: String) -> void:
	var d: Variant = CourseSchedule.get_main_period(mp)
	var start := "10:00"
	var end := "10:20"
	var has := false
	if d is Dictionary and (d as Dictionary).has("subs"):
		var subs: Dictionary = (d as Dictionary)["subs"]
		if subs.has(sname) and (subs[sname] is Dictionary):
			start = str((subs[sname] as Dictionary).get("start", start))
			end = str((subs[sname] as Dictionary).get("end", end))
			has = bool((subs[sname] as Dictionary).get("has_classes", false))
	if is_start:
		start = hhmm
	else:
		end = hhmm
	CourseSchedule.set_sub(mp, sname, start, end, has)


## 分时段「有课」开关（保留起止）。
func _set_sub_active(mp: int, sname: String, on: bool) -> void:
	var d: Variant = CourseSchedule.get_main_period(mp)
	var start := "10:00"
	var end := "10:20"
	if d is Dictionary and (d as Dictionary).has("subs"):
		var subs: Dictionary = (d as Dictionary)["subs"]
		if subs.has(sname) and (subs[sname] is Dictionary):
			start = str((subs[sname] as Dictionary).get("start", start))
			end = str((subs[sname] as Dictionary).get("end", end))
	CourseSchedule.set_sub(mp, sname, start, end, on)


## 子时段编辑行（抽出为方法，sname/sd 作为参数绑定，避免循环闭包陷阱）。
func _build_sub_row(v: VBoxContainer, sname: String, sd: Dictionary) -> void:
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 10)
	srow.alignment = BoxContainer.ALIGNMENT_CENTER
	var sn_edit := LineEdit.new()
	sn_edit.text = str(sd.get("name", sname))
	sn_edit.custom_minimum_size = Vector2(96.0, 30.0)
	sn_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sn_edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sn_edit.text_submitted.connect(func(t): CourseSchedule.rename_sub(_edit_mp, sname, t))
	UIStyle.apply_line_edit_style(sn_edit)
	srow.add_child(sn_edit)
	srow.add_child(_mk_time_pair(true,
		str(sd.get("start", "10:00")), str(sd.get("end", "10:20")),
		func(h, m): _set_sub_bound(_edit_mp, sname, true, _hhmm(h, m)),
		func(h, m): _set_sub_bound(_edit_mp, sname, false, _hhmm(h, m))))
	var hc := CheckBox.new()
	hc.text = "有课"
	hc.button_pressed = bool(sd.get("has_classes", false))
	hc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hc.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	if is_instance_valid(_cjk):
		hc.add_theme_font_override("font", _cjk)
	hc.toggled.connect(func(on): _set_sub_active(_edit_mp, sname, on))
	srow.add_child(hc)
	var srm := _mk_btn("sub_rm_" + sname, "×", 34.0)
	srm.pressed_id.connect(_on_sub_remove.bind(sname))
	srow.add_child(srm)
	v.add_child(srow)


## 每节课时间编辑行（ci/ct 作为参数绑定，避免循环闭包陷阱）。
func _build_class_time_row(v: VBoxContainer, ci: int, ct: Dictionary) -> void:
	var crow := HBoxContainer.new()
	crow.add_theme_constant_override("separation", 10)
	crow.alignment = BoxContainer.ALIGNMENT_CENTER
	var cl := Label.new()
	cl.text = "第 %d 节" % (ci + 1)
	cl.custom_minimum_size = Vector2(58.0, 30.0)
	cl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cl.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	if is_instance_valid(_cjk):
		cl.add_theme_font_override("font", _cjk)
	crow.add_child(cl)
	crow.add_child(_mk_time_pair(true,
		str(ct.get("start", "08:00")), str(ct.get("end", "08:45")),
		func(h, m): _set_class_time_bound(_edit_mp, ci, true, _hhmm(h, m)),
		func(h, m): _set_class_time_bound(_edit_mp, ci, false, _hhmm(h, m))))
	v.add_child(crow)


func _on_layout_move(_id: String, ei: int, dir: int) -> void:
	var to := ei + dir
	CourseSchedule.move_layout_entry(_edit_mp, ei, to)
	_rebuild_period_editor()


func _on_layout_remove(_id: String, ei: int) -> void:
	CourseSchedule.remove_layout_entry(_edit_mp, ei)
	_rebuild_period_editor()


func _on_layout_add_class(_id: String) -> void:
	var mp_dict: Variant = CourseSchedule.get_main_period(_edit_mp)
	if mp_dict == null:
		return
	var lay: Array = (mp_dict as Dictionary).get("layout", [])
	CourseSchedule.insert_layout_entry(_edit_mp, lay.size(), "class")
	_rebuild_period_editor()


func _on_layout_add_sub_menu(_id: String) -> void:
	var mp_dict: Variant = CourseSchedule.get_main_period(_edit_mp)
	if mp_dict == null:
		return
	var subs: Dictionary = (mp_dict as Dictionary).get("subs", {})
	var sub_items: Array = []
	for sname in subs.keys():
		sub_items.append({"label": "加分：" + str(sname), "id": "addsub:" + str(sname)})
	sub_items.append({"label": "（先去下方新建分时段）", "id": "noop"})
	if _ctx_menu == null or not is_instance_valid(_ctx_menu):
		_ctx_menu = ContextMenu.new()
		_ctx_layer().add_child(_ctx_menu)
		_ctx_menu.item_selected.connect(_on_ctx_selected)
	# 同上：把屏幕像素换算到本面板所在画布坐标，避免缩放层下菜单飞出屏幕。
	_ctx_menu.open(UIStyle.screen_to_canvas(self, get_viewport().get_mouse_position()), sub_items)


func _on_sub_add(_id: String, sub_name_edit: LineEdit, sub_hc: CheckBox) -> void:
	var nm := sub_name_edit.text.strip_edges()
	if nm.is_empty():
		return
	CourseSchedule.add_sub(_edit_mp, nm, "10:00", "10:20", sub_hc.button_pressed)
	_rebuild_period_editor()


func _on_sub_remove(_id: String, sname: String) -> void:
	CourseSchedule.remove_sub(_edit_mp, sname)
	_rebuild_period_editor()


func _on_batch_fill(bs_ts: TimeSpinField, dur_edit: LineEdit, gap_edit: LineEdit) -> void:
	var t := bs_ts.get_time()
	var dur := int(dur_edit.text) if dur_edit.text.is_valid_int() else 45
	var gap := int(gap_edit.text) if gap_edit.text.is_valid_int() else 10
	CourseSchedule.set_class_times_bulk(_edit_mp, t["hour"] * 60 + t["minute"], dur, gap)
	_rebuild_period_editor()


# ============ 编辑器显隐 ============

func _show_editor(which: Control) -> void:
	_cell_editor.visible = (which == _cell_editor)
	_period_editor.visible = (which == _period_editor)
	# 首次打开：把独立页居中到画布（与主面板同一坐标系）
	if not _editor_centered:
		var vs: Vector2 = UIStyle.canvas_viewport_size(_editor_layer) if get_viewport() != null else Vector2(1280.0, 720.0)
		_editor_layer.position = Vector2(maxf(20.0, (vs.x - _editor_layer.size.x) * 0.5),
			maxf(30.0, (vs.y - _editor_layer.size.y) * 0.35))
		_editor_centered = true
	_editor_layer.visible = true
	_editor_layer.move_to_front()
	# 若之前被最小化，重新打开时还原展开，保证表单可见
	if _editor_minimized:
		_set_editor_minimized(false)


## 课程编辑器独立页的最小化（复用 UIMinimize：折叠内容 + 收高度 + 按钮文案）。
func _set_editor_minimized(v: bool) -> void:
	_editor_minimized = v
	UIMinimize.set_label(_editor_min_btn, v)
	UIMinimize.fold_top_strip(_editor_layer, v)
	UIMinimize.apply_size(_editor_layer, v)


func _close_editors(_id: String = "") -> void:
	_editor_layer.visible = false
	_cell_editor.visible = false
	_period_editor.visible = false
	# ★ 不再隐藏/还原 _scroll：编辑器已是独立页，课程表内容始终可见
	if _scroll != null and is_instance_valid(_scroll):
		_scroll.visible = true
	_edit_ctx = {}
	_edit_mp = -1
	_return_to_cell = false
	_rebuild_timetable()


# ============ 顶部周数控制 ============

## 学期总周数输入框：回车提交
func _on_semester_submitted(text: String) -> void:
	_apply_semester_text(text)


## 学期总周数「保存」按钮：显式提交输入框当前值，确保总周数立即刷新。
func _on_semester_save(_id: String) -> void:
	if _semester_edit != null and is_instance_valid(_semester_edit):
		_apply_semester_text(_semester_edit.text)


## 学期总周数输入框：失焦提交（点别处即生效）
func _on_semester_focus_exited() -> void:
	if _semester_edit != null and is_instance_valid(_semester_edit):
		_apply_semester_text(_semester_edit.text)


## 学期总周数输入提交：空 / 非法还原为当前值；合法则 clamp 到 [1,60] 写入。
func _apply_semester_text(t: String) -> void:
	var s := t.strip_edges()
	if s.is_empty() or not s.is_valid_int():
		# 非法 → 还原为当前值（不写数据）
		if _semester_edit != null and is_instance_valid(_semester_edit):
			_semester_edit.text = str(CourseSchedule.get_semester_weeks())
		return
	var v := int(s)
	if v < 1:
		v = 1
	# set_semester_weeks 内部已 clamp 到 [1,60]，并 emit changed → _refresh_ctrl_labels 回写规范值
	CourseSchedule.set_semester_weeks(v)


func _on_current_pressed(_id: String, delta: int) -> void:
	CourseSchedule.set_current_week(CourseSchedule.get_current_week() + delta)


## 「周起始」切换：写共享设置（由信号同步刷新本页与日历页）
func _on_week_toggle_pressed(_id: String) -> void:
	if SaveManager != null and SaveManager.has_method("set_calendar_week_starts_monday"):
		SaveManager.set_calendar_week_starts_monday(not _week_starts_monday())


## 收到「周起始」变化（来自本页或日历页的按钮）→ 更新按钮文案并重排课程表。
func _on_week_start_changed(_on: bool) -> void:
	if _week_toggle != null and is_instance_valid(_week_toggle):
		_week_toggle.set_label(_week_toggle_text())
	_rebuild_timetable()


func _refresh_ctrl_labels() -> void:
	if _semester_edit != null and is_instance_valid(_semester_edit):
		var cur := str(CourseSchedule.get_semester_weeks())
		if _semester_edit.text != cur:
			_semester_edit.text = cur
	if _current_label != null and is_instance_valid(_current_label):
		_current_label.text = "第 %d / %d 周" % [CourseSchedule.get_current_week(), CourseSchedule.get_semester_weeks()]


# ============ 变化响应 ============

func _on_cs_changed(_data: Dictionary) -> void:
	_refresh_ctrl_labels()
	# 编辑器打开时，不重建底层课程表（避免打断编辑 / 拖拽 TimeSpinField）
	if _editor_layer != null and _editor_layer.visible:
		return
	_rebuild_timetable()


# ============ 打开 / 关闭 ============

func open() -> void:
	if not _ever_centered:
		var vs: Vector2 = UIStyle.canvas_viewport_size(self) if get_viewport() != null else Vector2(1280.0, 720.0)
		position = Vector2(maxf(40.0, (vs.x - PANEL_W) * 0.5), maxf(40.0, (vs.y - PANEL_H) * 0.4))
		_ever_centered = true
	_open = true
	visible = true
	move_to_front()
	_refresh_ctrl_labels()
	# 打开时按最新共享设置回显周起始按钮文案（避免本页关闭期间被日历页改动）
	if _week_toggle != null and is_instance_valid(_week_toggle):
		_week_toggle.set_label(_week_toggle_text())
	# 「上课时为忙」同样回显最新开关态（避免本页关闭期间被性能忙闲页改动）
	_refresh_class_busy_label()
	_rebuild_timetable()


func close() -> void:
	_open = false
	visible = false
	# 关闭面板时一并收起编辑器独立页（避免残留孤儿窗口）
	if _editor_layer != null and is_instance_valid(_editor_layer) and _editor_layer.visible:
		_close_editors()
	if get_viewport() != null:
		get_viewport().gui_release_focus()
	closed.emit()


func is_open() -> bool:
	return _open


func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.set_label(_min_btn, v)
	UIMinimize.fold_top_strip(self, v)
	UIMinimize.apply_size(self, v)


func is_minimized() -> bool:
	return _minimized


func _on_close_pressed(_id: String) -> void:
	close()
