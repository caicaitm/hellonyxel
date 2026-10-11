# ui/calendar_panel.gd
# 「日历 / 日记 / 备忘录」单页系统（无二级菜单）。
#
# 一个页面内包含三个互相关联的部分：
#   1) 日历：7 列网格（每列一天）。「周一在前 / 周日在前」可切（落 settings.json）。
#   2) 备忘录：点选日期后，日历**下方**出现备忘录编辑器——玩家每天可写一条；
#      同时本模块预留外部写入接口（事件链系统等走 CalendarNotes.set_memo）。
#   3) 日记：页面**左上角**折叠按钮控制显隐。日记内容 = 设备日历事件（只读，来自
#      CalendarInfo）+ 游戏内日记条目（玩家 / 事件链系统等可写，来自 CalendarNotes）。
#     玩家一般不直接写，但页面也预留了「追加日记」输入。
#
# ★ 设计约束（与 settings_panel / state_view_panel 一致）：
#   - class_name CalendarPanel extends Control；signal closed；
#   - open()/close()/is_open() 三件套；close() 内 closed.emit()；
#   - 入树后由 desktop.gd 实例化并挂到 ui_layer（CanvasLayer，layer=100）。
class_name CalendarPanel extends Control

signal closed

const PANEL_W: float = 720.0
const PANEL_H: float = 640.0
const TITLE_H: float = 28.0
const CELL: Vector2 = Vector2(92.0, 60.0)
const GRID_COLS: int = 7

# 星期表（中文单字）
const WEEK_MONDAY_FIRST: Array[String] = ["一", "二", "三", "四", "五", "六", "日"]
const WEEK_SUNDAY_FIRST: Array[String] = ["日", "一", "二", "三", "四", "五", "六"]

var _bg: UIPanel
var _title_label: Label
var _close_btn: UIBtn
var _state_label: Label

# 控制行
var _fold_btn: UIBtn
var _prev_btn: UIBtn
var _next_btn: UIBtn
var _month_label: Label
var _refresh_btn: UIBtn
var _week_toggle: UIBtn

# 滚动内容
var _scroll: ScrollContainer
var _content: VBoxContainer
var _week_header: GridContainer
var _grid: GridContainer

# 日期区（选中后展示）
var _sel_label: Label
var _memo_edit: TextEdit
var _memo_save_btn: UIBtn
var _memo_status: Label
var _diary_block: VBoxContainer
var _diary_events_label: Label
var _diary_list_label: Label
var _diary_input: TextEdit
var _diary_add_btn: UIBtn

var _day_buttons: Array = []     # 仅当天格子按钮（用于刷新标记）

var _view_year: int = 2000
var _view_month: int = 1
var _selected_date: String = ""
var _diary_open: bool = true
var _week_starts_monday: bool = true
var _ever_centered: bool = false
var _open: bool = false
var _cjk: FontFile


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_cjk = UIStyle.get_cjk_font()
	var t := Time.get_datetime_dict_from_system()
	_view_year = int(t.get("year", 2000))
	_view_month = int(t.get("month", 1))
	if SaveManager != null and SaveManager.has_method("get_calendar_week_starts_monday"):
		_week_starts_monday = bool(SaveManager.get_calendar_week_starts_monday())
	_build_ui()
	_rebuild_grid()
	_refresh_date_section()
	_connect_signals()
	visible = false


func _connect_signals() -> void:
	if CalendarInfo != null and CalendarInfo.has_method("updated") and not CalendarInfo.updated.is_connected(_on_calendar_updated):
		CalendarInfo.updated.connect(_on_calendar_updated)
	if CalendarNotes != null and CalendarNotes.has_method("changed") and not CalendarNotes.changed.is_connected(_on_notes_changed):
		CalendarNotes.changed.connect(_on_notes_changed)



# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏控件整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build_ui() -> void:
	var vs: Vector2 = UIStyle.canvas_viewport_size(self) if get_viewport() != null else Vector2(1280.0, 720.0)
	size = Vector2(PANEL_W, PANEL_H)
	position = Vector2(maxf(40.0, (vs.x - PANEL_W) * 0.5), maxf(50.0, (vs.y - PANEL_H) * 0.4))

	_bg = UIPanel.new()
	_bg.name = "Bg"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	# ★ 边框用「深色区」配套色（STAGE_BORDER，深蓝 alpha 0.95），不用默认的 BORDER：
	#   BORDER 是**亮白蓝 alpha 0.65**，画在亮色玻璃填充上几乎融掉 → 液态玻璃主题下看不见边框。
	#   深色描边在任何主题（玻璃/纯色/全息）下都能与背景明确分离。
	_bg.set_border_color(UIStyle.STAGE_BORDER)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
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

	_title_label = Label.new()
	_title_label.name = "TitleLabel"
	_title_label.text = "日历"
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
	_state_label.text = ""
	_state_label.clip_text = true
	_state_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_state_label.offset_left = UIStyle.PANEL_PADDING
	_state_label.offset_top = TITLE_H + UIStyle.PANEL_PADDING
	_state_label.offset_right = -UIStyle.PANEL_PADDING
	_state_label.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING + 18.0
	_state_label.add_theme_color_override("font_color", Color(0.78, 0.86, 0.95, 0.8))
	_state_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		_state_label.add_theme_font_override("font", _cjk)
	_state_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_state_label)

	# 主体滚动区
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

	# 控制行
	var ctrl := HBoxContainer.new()
	ctrl.name = "CtrlRow"
	ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ctrl.add_theme_constant_override("separation", 6)
	_content.add_child(ctrl)

	_fold_btn = UIBtn.new()
	_fold_btn.set_id("fold")
	_fold_btn.set_label(_fold_text())
	_fold_btn.custom_minimum_size = Vector2(96.0, 28.0)
	_fold_btn.pressed_id.connect(_on_fold_pressed)
	ctrl.add_child(_fold_btn)

	_prev_btn = UIBtn.new()
	_prev_btn.set_id("prev")
	_prev_btn.set_label("‹")
	_prev_btn.custom_minimum_size = Vector2(28.0, 28.0)
	_prev_btn.pressed_id.connect(_on_prev_pressed)
	ctrl.add_child(_prev_btn)

	_month_label = Label.new()
	_month_label.name = "MonthLabel"
	_month_label.text = ""
	_month_label.custom_minimum_size = Vector2(120.0, 28.0)
	_month_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_month_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_month_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_month_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_cjk):
		_month_label.add_theme_font_override("font", _cjk)
	ctrl.add_child(_month_label)

	_next_btn = UIBtn.new()
	_next_btn.set_id("next")
	_next_btn.set_label("›")
	_next_btn.custom_minimum_size = Vector2(28.0, 28.0)
	_next_btn.pressed_id.connect(_on_next_pressed)
	ctrl.add_child(_next_btn)

	_refresh_btn = UIBtn.new()
	_refresh_btn.set_id("refresh")
	_refresh_btn.set_label("刷新本机日历")
	_refresh_btn.custom_minimum_size = Vector2(120.0, 28.0)
	_refresh_btn.pressed_id.connect(_on_refresh_pressed)
	ctrl.add_child(_refresh_btn)

	_week_toggle = UIBtn.new()
	_week_toggle.set_id("week")
	_week_toggle.set_label(_week_toggle_text())
	_week_toggle.custom_minimum_size = Vector2(120.0, 28.0)
	_week_toggle.pressed_id.connect(_on_week_toggle_pressed)
	ctrl.add_child(_week_toggle)

	# 星期表头
	_week_header = GridContainer.new()
	_week_header.name = "WeekHeader"
	_week_header.columns = GRID_COLS
	_week_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_week_header.add_theme_constant_override("h_separation", 2)
	_week_header.add_theme_constant_override("v_separation", 2)
	_content.add_child(_week_header)
	_rebuild_week_header()

	# 日历网格
	_grid = GridContainer.new()
	_grid.name = "Grid"
	_grid.columns = GRID_COLS
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 2)
	_grid.add_theme_constant_override("v_separation", 2)
	_content.add_child(_grid)

	# 选中日期区
	_content.add_child(_build_date_section())


func _build_date_section() -> VBoxContainer:
	var sec := VBoxContainer.new()
	sec.name = "DateSection"
	sec.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sec.add_theme_constant_override("separation", 6)

	_sel_label = Label.new()
	_sel_label.name = "SelLabel"
	_sel_label.text = "未选择日期"
	_sel_label.custom_minimum_size = Vector2(0.0, 24.0)
	_sel_label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	_sel_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_cjk):
		_sel_label.add_theme_font_override("font", _cjk)
	sec.add_child(_sel_label)

	# 备忘录
	var memo_title := Label.new()
	memo_title.text = "备忘录（每天一条，玩家可写；事件链系统等也可写入）"
	memo_title.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	memo_title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		memo_title.add_theme_font_override("font", _cjk)
	sec.add_child(memo_title)

	_memo_edit = TextEdit.new()
	_memo_edit.name = "MemoEdit"
	_memo_edit.placeholder_text = "今天有什么要记的？写在这里…"
	_memo_edit.custom_minimum_size = Vector2(0.0, 70.0)
	UIStyle.apply_text_edit_style(_memo_edit)
	sec.add_child(_memo_edit)

	_memo_save_btn = UIBtn.new()
	_memo_save_btn.set_id("memo_save")
	_memo_save_btn.set_label("保存备忘录")
	_memo_save_btn.custom_minimum_size = Vector2(110.0, 28.0)
	_memo_save_btn.pressed_id.connect(_on_memo_save_pressed)
	sec.add_child(_memo_save_btn)

	_memo_status = Label.new()
	_memo_status.name = "MemoStatus"
	_memo_status.text = ""
	_memo_status.custom_minimum_size = Vector2(0.0, 18.0)
	_memo_status.add_theme_color_override("font_color", Color(0.78, 0.86, 0.95, 0.8))
	_memo_status.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		_memo_status.add_theme_font_override("font", _cjk)
	sec.add_child(_memo_status)

	# 日记（可折叠）
	_diary_block = VBoxContainer.new()
	_diary_block.name = "DiaryBlock"
	_diary_block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_diary_block.add_theme_constant_override("separation", 4)
	_diary_block.visible = _diary_open
	sec.add_child(_diary_block)

	var diary_title := Label.new()
	diary_title.text = "日记（设备日历事件 + 游戏内写入；玩家也可追加）"
	diary_title.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	diary_title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		diary_title.add_theme_font_override("font", _cjk)
	_diary_block.add_child(diary_title)

	_diary_events_label = Label.new()
	_diary_events_label.name = "DiaryEvents"
	_diary_events_label.text = ""
	_diary_events_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_diary_events_label.custom_minimum_size = Vector2(0.0, 20.0)
	_diary_events_label.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0, 0.95))
	_diary_events_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		_diary_events_label.add_theme_font_override("font", _cjk)
	_diary_block.add_child(_diary_events_label)

	_diary_list_label = Label.new()
	_diary_list_label.name = "DiaryList"
	_diary_list_label.text = ""
	_diary_list_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_diary_list_label.custom_minimum_size = Vector2(0.0, 20.0)
	_diary_list_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_diary_list_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		_diary_list_label.add_theme_font_override("font", _cjk)
	_diary_block.add_child(_diary_list_label)

	_diary_input = TextEdit.new()
	_diary_input.name = "DiaryInput"
	_diary_input.placeholder_text = "追加一条日记（玩家）…"
	_diary_input.custom_minimum_size = Vector2(0.0, 56.0)
	UIStyle.apply_text_edit_style(_diary_input)
	_diary_block.add_child(_diary_input)

	_diary_add_btn = UIBtn.new()
	_diary_add_btn.set_id("diary_add")
	_diary_add_btn.set_label("追加日记（玩家）")
	_diary_add_btn.custom_minimum_size = Vector2(130.0, 28.0)
	_diary_add_btn.pressed_id.connect(_on_diary_add_pressed)
	_diary_block.add_child(_diary_add_btn)

	return sec


# ============ 文本 / 标签助手 ============

func _fold_text() -> String:
	return ("▾ 日记" if _diary_open else "▸ 日记")


func _week_toggle_text() -> String:
	return ("周一在前" if _week_starts_monday else "周日在前")


func _month_text() -> String:
	return "%04d 年 %02d 月" % [_view_year, _view_month]


# ============ 网格 ============

func _rebuild_week_header() -> void:
	for c in _week_header.get_children():
		c.queue_free()
	var names: Array[String] = WEEK_MONDAY_FIRST if _week_starts_monday else WEEK_SUNDAY_FIRST
	for n in names:
		var lab := Label.new()
		lab.text = n
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lab.custom_minimum_size = CELL
		lab.add_theme_color_override("font_color", Color(0.6, 0.9, 1.0))
		lab.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
		if is_instance_valid(_cjk):
			lab.add_theme_font_override("font", _cjk)
		_week_header.add_child(lab)


func _rebuild_grid() -> void:
	for c in _grid.get_children():
		c.queue_free()
	_day_buttons = []
	_month_label.text = _month_text()

	var first_dow := _day_of_week(_view_year, _view_month, 1)   # 0=周日
	var leading: int = (first_dow + 6) % 7 if _week_starts_monday else first_dow
	var dim := _days_in_month(_view_year, _view_month)
	var today := _today_key()

	for i in range(leading):
		var blank := Control.new()
		blank.custom_minimum_size = CELL
		blank.size = CELL
		_grid.add_child(blank)

	for d in range(1, dim + 1):
		var date := _date_key(_view_year, _view_month, d)
		var btn := UIBtn.new()
		btn.set_id(date)
		var label := str(d)
		if date == today:
			label = "★" + label
		if CalendarNotes != null and CalendarNotes.day_has_memo(date):
			label += "·"
		if CalendarInfo != null and CalendarInfo.day_has_events(date):
			label += "○"
		btn.set_label(label)
		btn.custom_minimum_size = CELL
		btn.size = CELL
		btn.pressed_id.connect(_on_day_pressed)
		_grid.add_child(btn)
		_day_buttons.append(btn)


func _refresh_grid_markers() -> void:
	# 仅刷新标记（避免整表重建导致拖动/焦点丢失）
	var idx := 0
	var first_dow := _day_of_week(_view_year, _view_month, 1)
	var leading: int = (first_dow + 6) % 7 if _week_starts_monday else first_dow
	var dim := _days_in_month(_view_year, _view_month)
	var today := _today_key()
	for d in range(1, dim + 1):
		var date := _date_key(_view_year, _view_month, d)
		if idx >= _day_buttons.size():
			break
		var btn: Node = _day_buttons[idx]
		idx += 1
		if not (btn is UIBtn):
			continue
		var label := str(d)
		if date == today:
			label = "★" + label
		if CalendarNotes != null and CalendarNotes.day_has_memo(date):
			label += "·"
		if CalendarInfo != null and CalendarInfo.day_has_events(date):
			label += "○"
		(btn as UIBtn).set_label(label)


# ============ 日期选择 ============

func _on_day_pressed(date: String) -> void:
	_selected_date = date
	_refresh_date_section()


func _refresh_date_section() -> void:
	if _selected_date.is_empty():
		_sel_label.text = "未选择日期（点上方某一天）"
		if _memo_edit != null and is_instance_valid(_memo_edit):
			_memo_edit.text = ""
		if _diary_events_label != null and is_instance_valid(_diary_events_label):
			_diary_events_label.text = ""
		if _diary_list_label != null and is_instance_valid(_diary_list_label):
			_diary_list_label.text = ""
		return
	_sel_label.text = "已选日期：%s（%s）" % [_selected_date, _weekday_cn(_day_of_week_str(_selected_date))]
	if CalendarNotes != null:
		if _memo_edit != null and is_instance_valid(_memo_edit):
			_memo_edit.text = CalendarNotes.get_memo(_selected_date)
	if _diary_events_label != null and is_instance_valid(_diary_events_label):
		_diary_events_label.text = _device_events_text()
	if _diary_list_label != null and is_instance_valid(_diary_list_label):
		_diary_list_label.text = _diary_list_text()


func _device_events_text() -> String:
	if CalendarInfo == null:
		return "（设备日历不可用）"
	if not CalendarInfo.available():
		return "（本机日历读取受限：未以打包应用运行，Windows 不会授权访问设备日历。事件链系统等仍可写入下方游戏内日记。）"
	var evs := CalendarInfo.events_on_date(_selected_date)
	if evs.is_empty():
		return "（本日无设备日历事件）"
	var lines: Array[String] = []
	for e in evs:
		if not (e is Dictionary):
			continue
		var s := str((e as Dictionary).get("subject", ""))
		var st := str((e as Dictionary).get("start", "")).substr(11, 5)
		var loc := str((e as Dictionary).get("location", ""))
		var cal := str((e as Dictionary).get("calendar_name", ""))
		var line := "• %s %s" % [st, s]
		if not loc.is_empty():
			line += " @ %s" % loc
		if not cal.is_empty():
			line += " [%s]" % cal
		lines.append(line)
	return "设备日历：\n" + ("\n".join(lines))


func _diary_list_text() -> String:
	if CalendarNotes == null:
		return "（游戏内日记不可用）"
	var entries := CalendarNotes.get_diary(_selected_date)
	if entries.is_empty():
		return "（游戏内暂无日记；事件链系统等或玩家可追加）"
	var lines: Array[String] = []
	for e in entries:
		if not (e is Dictionary):
			continue
		var src := str((e as Dictionary).get("source", "player"))
		var txt := str((e as Dictionary).get("text", ""))
		var at := str((e as Dictionary).get("at", ""))
		lines.append("[%s] %s  （%s）" % [src, txt, at])
	return "游戏内日记：\n" + ("\n".join(lines))


# ============ 控制按钮 ============

func _on_fold_pressed(_id: String) -> void:
	_diary_open = not _diary_open
	if _fold_btn != null and is_instance_valid(_fold_btn):
		_fold_btn.set_label(_fold_text())
	if _diary_block != null and is_instance_valid(_diary_block):
		_diary_block.visible = _diary_open
		if _diary_open:
			_refresh_date_section()


func _on_prev_pressed(_id: String) -> void:
	_view_month -= 1
	if _view_month < 1:
		_view_month = 12
		_view_year -= 1
	_rebuild_grid()


func _on_next_pressed(_id: String) -> void:
	_view_month += 1
	if _view_month > 12:
		_view_month = 1
		_view_year += 1
	_rebuild_grid()


func _on_refresh_pressed(_id: String) -> void:
	if CalendarInfo == null:
		_set_state("设备日历模块不可用")
		return
	CalendarInfo.refresh_now(true)
	_set_state("正在读取设备日历…")


func _on_week_toggle_pressed(_id: String) -> void:
	_week_starts_monday = not _week_starts_monday
	if SaveManager != null and SaveManager.has_method("set_calendar_week_starts_monday"):
		SaveManager.set_calendar_week_starts_monday(_week_starts_monday)
	if _week_toggle != null and is_instance_valid(_week_toggle):
		_week_toggle.set_label(_week_toggle_text())
	_rebuild_week_header()
	_rebuild_grid()


func _on_memo_save_pressed(_id: String) -> void:
	if CalendarNotes == null or _selected_date.is_empty():
		return
	CalendarNotes.set_memo(_selected_date, _memo_edit.text, CalendarNotes.SOURCE_PLAYER)
	_set_memo_status("已保存 %s 的备忘录" % _selected_date)


func _on_diary_add_pressed(_id: String) -> void:
	if CalendarNotes == null or _selected_date.is_empty():
		return
	var body := _diary_input.text.strip_edges()
	if body.is_empty():
		_set_memo_status("日记内容为空，未写入")
		return
	CalendarNotes.append_diary(_selected_date, body, CalendarNotes.SOURCE_PLAYER)
	_diary_input.text = ""
	_set_memo_status("已追加一条玩家日记")


func _on_close_pressed(_id: String) -> void:
	close()


# ============ 信号 ============

func _on_calendar_updated() -> void:
	_refresh_grid_markers()
	if not _selected_date.is_empty() and _diary_open:
		if _diary_events_label != null and is_instance_valid(_diary_events_label):
			_diary_events_label.text = _device_events_text()
	_set_state("")


func _on_notes_changed(_notes: Dictionary) -> void:
	_refresh_grid_markers()
	# ★ 不回写 _memo_edit：玩家正在输入，信号会由自己的 set_memo 触发，
	#   回写会清掉光标。只刷新网格标记 + 日记列表（外部/事件链写入可见）。
	if not _selected_date.is_empty() and _diary_open:
		if _diary_list_label != null and is_instance_valid(_diary_list_label):
			_diary_list_label.text = _diary_list_text()


# ============ 状态行 ============

func _set_state(t: String) -> void:
	if _state_label != null and is_instance_valid(_state_label):
		_state_label.text = t


func _set_memo_status(t: String) -> void:
	if _memo_status != null and is_instance_valid(_memo_status):
		_memo_status.text = t


# ============ 打开 / 关闭 ============

func open() -> void:
	if not _ever_centered:
		var vs: Vector2 = UIStyle.canvas_viewport_size(self) if get_viewport() != null else Vector2(1280.0, 720.0)
		position = Vector2(maxf(40.0, (vs.x - PANEL_W) * 0.5), maxf(50.0, (vs.y - PANEL_H) * 0.4))
		_ever_centered = true
	_open = true
	visible = true
	move_to_front()
	# 打开即按需刷新设备日历（无头环境 refresh_now 内部会自动 no-op）
	if CalendarInfo != null and CalendarInfo.is_stale():
		CalendarInfo.refresh_now(false)
		_set_state("正在读取设备日历…")
	else:
		_set_state("")


func close() -> void:
	_open = false
	visible = false
	if get_viewport() != null:
		get_viewport().gui_release_focus()
	closed.emit()


func is_open() -> bool:
	return _open


# ============ 日期工具 ============

func _today_key() -> String:
	var t := Time.get_datetime_dict_from_system()
	return _date_key(int(t.get("year", 2000)), int(t.get("month", 1)), int(t.get("day", 1)))


func _date_key(y: int, m: int, d: int) -> String:
	return "%04d-%02d-%02d" % [y, m, d]


## day-of-week（0=周日 .. 6=周六）—— Sakamoto 算法
func _day_of_week(y: int, m: int, d: int) -> int:
	var t := [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
	var yy: int = y
	if m < 3:
		yy -= 1
	var v: int = int(yy + int(yy / 4) - int(yy / 100) + int(yy / 400) + t[m - 1] + d) % 7
	if v < 0:
		v += 7
	return v


## 给 "yyyy-MM-dd" 返回星期中文（日/一/…）
func _day_of_week_str(date: String) -> int:
	var parts := date.split("-")
	if parts.size() < 3:
		return 0
	return _day_of_week(int(parts[0]), int(parts[1]), int(parts[2]))


func _weekday_cn(dow: int) -> String:
	var arr: Array[String] = ["日", "一", "二", "三", "四", "五", "六"]
	if dow < 0 or dow > 6:
		return ""
	return arr[dow]


func _days_in_month(y: int, m: int) -> int:
	if m == 2:
		var leap := (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)
		return 29 if leap else 28
	if m in [1, 3, 5, 7, 8, 10, 12]:
		return 31
	return 30


## 最小化 / 还原：折叠只隐藏内容，标题栏控件（标题 / 把柄 / 最小化 / 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.set_label(_min_btn, v)
	UIMinimize.fold_top_strip(self, v)
	UIMinimize.apply_size(self, v)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
