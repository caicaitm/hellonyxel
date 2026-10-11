# ui/perf_busy_panel.gd
# 「性能忙闲判断」面板：辅助判断玩家是否「在忙」（机器是否处于高负载）。
#
# 读取 PerfMonitor 采到的 CPU / 内存 / 显存 总占用 %，按下面的加权模型打分：
#   对每项资源：当前% 超过「判断线(滑块)」的部分，乘以「权重(输入框)」；
#   三项相加 = 「电脑性能使用分数」。
#   只要分数 > 「分数判断阈值(顶部输入框)」，即判定玩家「在忙」。
#
# 打开方式（唯一入口）：
#   - 系统托盘右键菜单「性能忙闲判断」（TrayRunner.perf_busy_requested
#     → desktop._open_perf_busy → Debug._toggle_perf_busy）。
#     ★ 调试面板上的「性能忙闲判断」按钮已移除（2026-09-30）。
#
# 布局：标题栏(拖动把柄 + × 关闭) + 滚动内容；顶部分数判断阈值输入框；
#   三项资源各一行（当前% / 判断线滑块 / 权重输入框 / 本项得分）；
#   进程辅助判断区（底部「＋ 添加进程」按钮，可重复加多行：进程名 + 权重 + 检测状态 + 删除×）；
#   底部总分与状态（在忙 / 空闲 / 数据不可用）。
# 数据每 0.4s 刷新一次（PerfMonitor 每分钟采样一次，这里只是把最新值显示出来）。
extends Control

const PANEL_W: float = 460.0
const PANEL_H: float = 600.0
const TITLE_BAR_H: float = 28.0

# 三项资源的内部键（顺序即显示顺序）
const KEYS := ["cpu", "mem", "vram"]
const KEY_LABELS := {"cpu": "CPU", "mem": "内存", "vram": "显存"}

signal closed

var _bg: UIPanel
var _title_label: Label
var _close_btn: UIBtn

# 顶部：分数判断阈值
var _score_threshold_input: LineEdit
var _score_threshold: float = 30.0
const SCORE_THRESHOLD_DEFAULT: float = 30.0

# 默认值（首次打开时使用；用户调整后仅本次会话有效）
const THR_DEFAULTS := {"cpu": 70.0, "mem": 80.0, "vram": 85.0}
const WEIGHT_DEFAULTS := {"cpu": 1.0, "mem": 1.0, "vram": 1.0}

# 每项 UI 引用（按 key 索引）
var _cur_labels: Dictionary = {}       # 当前占用%
var _sliders: Dictionary = {}          # 判断线滑块
var _thr_labels: Dictionary = {}       # 判断线数值
var _weight_inputs: Dictionary = {}    # 权重输入框
var _contrib_labels: Dictionary = {}   # 本项得分

var _total_label: Label
var _status_label: Label

# 进程辅助判断：动态行容器与行数据
var _proc_list: VBoxContainer = null
var _proc_rows: Array = []   # 每项 {name_edit, weight_edit, kind_opt, status_label, container}

# ★★ 批次 70：进程「属性」—— 在「在忙 / 在闲」之上进一步判断玩家在干什么。
#   每个进程可标注它属于哪类活动（游戏/工作/聊天/音乐/其他）；检测到该进程运行时，
#   把活动类型计入「当前活动」统计，面板底部据此给出「玩家可能正在：XXX」的推断。
#   [真值, 显示名]：真值写进 perf_busy.json 的 kind 字段，显示名只用于界面。
##   ★ 批次 94：新增 休闲 / 学习 / 社区。新增项一律**插在 other 之前**，
##     保证 other 始终是最后一项 —— 旧存档里没写 kind 的进程会落到下拉第一项，
##     而「其他」作为兜底项必须能被 _select_kind_meta 的索引回退命中。
const ACTIVITY_KINDS: Array = [
	["game", "游戏"],
	["work", "工作"],
	["chat", "聊天"],
	["music", "音乐"],
	["leisure", "休闲"],
	["study", "学习"],
	["community", "社区"],
	["other", "其他"],
]
const ACTIVITY_LABELS := {
	"game": "游戏", "work": "工作", "chat": "聊天", "music": "音乐",
	"leisure": "休闲", "study": "学习", "community": "社区", "other": "其他",
}
# 底部「当前活动」推断标签（显示玩家可能正在做什么）
var _activity_label: Label = null

# 定时切换忙闲状态：动态时段行
#   checks 索引 0..6 → ISO 星期 1..7（周一…周日），与 BusyState.resolve_window 的 days 字段一致
var _schedule_list: VBoxContainer = null
var _schedule_rows: Array = []   # 每项 {checks: Array, start_edit: LineEdit, end_edit: LineEdit, container: VBoxContainer}

const WEEK_LABELS := ["一", "二", "三", "四", "五", "六", "日"]     # 勾选框显示的单字
const WEEK_NAMES := ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]   # tooltip 用
const TIME_HINT := "HH:MM"

var _refresh_timer: Timer = null
var _loading: bool = false   # 加载期间抑制 _save_state（避免读档即回写）


func _ready() -> void:
	_build()
	_score_threshold_input.text = "%.1f" % SCORE_THRESHOLD_DEFAULT
	for k in KEYS:
		_sliders[k].value = THR_DEFAULTS[k]
		_weight_inputs[k].text = "%.1f" % WEIGHT_DEFAULTS[k]
	_load_state()   # 应用已保存的设置（文件缺失则保留上方默认值）
	_recompute()
	# 每 0.4s 把 PerfMonitor 最新值刷到面板（采样是每分钟一次，这里只做显示刷新）
	_refresh_timer = Timer.new()
	_refresh_timer.name = "PerfBusyRefresh"
	_refresh_timer.wait_time = 0.4
	_refresh_timer.one_shot = false
	_refresh_timer.timeout.connect(_on_refresh_tick)
	add_child(_refresh_timer)
	_refresh_timer.start()


# 默认打开位置 = 窗口正中（原来固定在左上角 60,60）。
# 写法与 api_config_panel._center() 一致：优先取本视口的可见矩形，取不到再退回 1152x648。
func _center_bg() -> void:
	if _bg == null:
		return
	var vp := Vector2(1152.0, 648.0)
	if is_inside_tree() and get_viewport() != null:
		vp = UIStyle.canvas_viewport_size(self)
	var sz := Vector2(PANEL_W, PANEL_H)
	_bg.position = ((vp - sz) * 0.5).max(Vector2.ZERO).floor()



# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build() -> void:
	_bg = UIPanel.new()
	_bg.size = Vector2(PANEL_W, PANEL_H)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	add_child(_bg)
	_center_bg()   # ★ 居中打开（用户拖动后由 UIDragHandle 接管，不再自动归位）
	var fnt := UIStyle.get_cjk_font()

	var sc := ScrollContainer.new()
	sc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_bg.add_child(sc)
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 4)
	sc.add_child(vbox)

	# 标题栏
	var title_row := HBoxContainer.new()
	title_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label = Label.new()
	_title_label.text = "性能忙闲判断"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_title_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		_title_label.add_theme_font_override("font", fnt)
	title_row.add_child(_title_label)
	# 拖动把柄（复用已有 UIDragHandle：按住移动整个面板）
	var drag_handle := UIDragHandle.new()
	drag_handle.setup(_bg)
	drag_handle.tooltip_text = "拖动以移动面板"
	title_row.add_child(drag_handle)
	_close_btn = UIBtn.new()
	_close_btn.set_id("perf_busy_close")
	_close_btn.set_label("×")
	_close_btn.custom_minimum_size = Vector2(TITLE_BAR_H, TITLE_BAR_H)
	_close_btn.size = Vector2(TITLE_BAR_H, TITLE_BAR_H)
	_close_btn.pressed_id.connect(_on_close)
	_min_btn = UIMinimize.attach(title_row, func(): set_minimized(not _minimized))
	title_row.add_child(_close_btn)
	vbox.add_child(title_row)

	# 顶部：分数判断阈值
	var thr_row := HBoxContainer.new()
	thr_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	thr_row.add_theme_constant_override("separation", 4)
	var thr_lab := Label.new()
	thr_lab.text = "分数判断阈值"
	thr_lab.custom_minimum_size = Vector2(110.0, 0)
	thr_lab.clip_text = true
	thr_lab.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	thr_lab.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		thr_lab.add_theme_font_override("font", fnt)
	thr_row.add_child(thr_lab)
	_score_threshold_input = LineEdit.new()
	_score_threshold_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_score_threshold_input.placeholder_text = "总分超过此值即判定在忙"
	_score_threshold_input.custom_maximum_size = Vector2(10000.0, 10000.0)
	_score_threshold_input.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		_score_threshold_input.add_theme_font_override("font", fnt)
	UIStyle.apply_line_edit_style(_score_threshold_input)
	_score_threshold_input.text_submitted.connect(_on_score_threshold_changed)
	thr_row.add_child(_score_threshold_input)
	vbox.add_child(thr_row)

	var hint := Label.new()
	hint.text = "每项：当前占用% 超过「判断线」的部分 ×「权重」，三项相加为总分"
	# ★ 长说明文字必须换行：否则 Label 最小宽度=整行文字宽 → 撑宽 VBox/ScrollContainer →
	#   顶栏按钮被推到 _bg 之外（用户反馈「文字过长时按钮和文字跑到页面外」）。
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9))
	hint.add_theme_font_size_override("font_size", 11)
	if is_instance_valid(fnt):
		hint.add_theme_font_override("font", fnt)
	vbox.add_child(hint)

	vbox.add_child(_sep())

	# 三项资源
	for k in KEYS:
		vbox.add_child(_build_metric(k, fnt))
		vbox.add_child(_sep())

	# 进程辅助判断（检测到指定进程名即把其权重加到总分）
	var proc_title := Label.new()
	proc_title.text = "进程辅助判断（检测到进程即 +权重到总分）"
	proc_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	proc_title.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	proc_title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		proc_title.add_theme_font_override("font", fnt)
	vbox.add_child(proc_title)

	var proc_hint := Label.new()
	proc_hint.text = "「属性」= 该进程属于哪类活动；据运行中的进程推断玩家在干什么"
	proc_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	proc_hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	proc_hint.add_theme_font_size_override("font_size", maxi(10, UIStyle.FONT_SIZE - 1))
	if is_instance_valid(fnt):
		proc_hint.add_theme_font_override("font", fnt)
	vbox.add_child(proc_hint)

	_proc_list = VBoxContainer.new()
	_proc_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_proc_list.add_theme_constant_override("separation", 2)
	vbox.add_child(_proc_list)

	# 底部「＋ 添加进程」按钮（可重复添加多行）
	var add_row := HBoxContainer.new()
	add_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var plus_btn := UIBtn.new()
	plus_btn.set_id("perf_busy_add_proc")
	plus_btn.set_label("＋ 添加进程")
	plus_btn.custom_minimum_size = Vector2(120.0, 26.0)
	plus_btn.pressed_id.connect(_on_add_proc_pressed)
	add_row.add_child(plus_btn)
	vbox.add_child(add_row)

	# 「当前活动」推断标签：据运行中的进程及其属性，判断玩家可能正在干什么
	_activity_label = Label.new()
	_activity_label.text = "当前活动: —"
	_activity_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_activity_label.add_theme_color_override("font_color", Color(0.75, 0.9, 1.0))
	_activity_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		_activity_label.add_theme_font_override("font", fnt)
	vbox.add_child(_activity_label)

	vbox.add_child(_sep())

	# ---- 定时切换忙闲状态 ----
	# 每条时段 = 星期勾选 + 进入(忙)时间 + 退出(忙)时间；时段内一律「在忙」，忽略分数与阈值。
	# 语义与 BusyState.resolve_window 一致（跨夜 / 全天两条边界都支持）。
	var sch_title := Label.new()
	sch_title.text = "定时切换忙闲状态（时段内一律在忙，忽略分数与阈值）"
	sch_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sch_title.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	sch_title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		sch_title.add_theme_font_override("font", fnt)
	vbox.add_child(sch_title)

	_schedule_list = VBoxContainer.new()
	_schedule_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_schedule_list.add_theme_constant_override("separation", 6)
	vbox.add_child(_schedule_list)

	var sch_hint := Label.new()
	sch_hint.text = "退出 ≤ 进入 = 跨夜（到次日退出时间为止）；两者相同 = 全天"
	sch_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sch_hint.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9))
	sch_hint.add_theme_font_size_override("font_size", 11)
	if is_instance_valid(fnt):
		sch_hint.add_theme_font_override("font", fnt)
	vbox.add_child(sch_hint)

	var add_sch_row := HBoxContainer.new()
	add_sch_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var add_sch_btn := UIBtn.new()
	add_sch_btn.set_id("perf_busy_add_schedule")
	add_sch_btn.set_label("＋ 添加时段")
	add_sch_btn.custom_minimum_size = Vector2(120.0, 26.0)
	add_sch_btn.pressed_id.connect(_on_add_schedule_pressed)
	add_sch_row.add_child(add_sch_btn)
	vbox.add_child(add_sch_row)
	vbox.add_child(_sep())

	# 总分 + 状态
	_total_label = Label.new()
	_total_label.text = "电脑性能使用分数: 0.0"
	_total_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_total_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 1)
	if is_instance_valid(fnt):
		_total_label.add_theme_font_override("font", fnt)
	vbox.add_child(_total_label)

	_status_label = Label.new()
	_status_label.text = "状态: 数据不可用"
	_status_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 1)
	if is_instance_valid(fnt):
		_status_label.add_theme_font_override("font", fnt)
	vbox.add_child(_status_label)


func _build_metric(key: String, fnt: Font) -> VBoxContainer:
	var blk := VBoxContainer.new()
	blk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blk.add_theme_constant_override("separation", 2)

	# 行1：资源名 + 当前%
	var row1 := HBoxContainer.new()
	row1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_theme_constant_override("separation", 4)
	var name_lab := Label.new()
	name_lab.text = KEY_LABELS.get(key, key)
	name_lab.custom_minimum_size = Vector2(56.0, 0)
	name_lab.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	name_lab.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		name_lab.add_theme_font_override("font", fnt)
	row1.add_child(name_lab)
	var cur := Label.new()
	cur.text = "—"
	cur.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cur.add_theme_color_override("font_color", Color(0.85, 0.92, 1.0))
	cur.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		cur.add_theme_font_override("font", fnt)
	row1.add_child(cur)
	_cur_labels[key] = cur
	blk.add_child(row1)

	# 行2：判断线滑块 + 数值
	var row2 := HBoxContainer.new()
	row2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_theme_constant_override("separation", 4)
	var sl_lab := Label.new()
	sl_lab.text = "判断线"
	sl_lab.custom_minimum_size = Vector2(56.0, 0)
	sl_lab.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	sl_lab.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		sl_lab.add_theme_font_override("font", fnt)
	row2.add_child(sl_lab)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.value = THR_DEFAULTS[key]
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_slider_changed.bind(key))
	row2.add_child(slider)
	_sliders[key] = slider
	var sl_val := Label.new()
	sl_val.text = "%.0f" % THR_DEFAULTS[key]
	sl_val.custom_minimum_size = Vector2(34.0, 0)
	sl_val.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	sl_val.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		sl_val.add_theme_font_override("font", fnt)
	row2.add_child(sl_val)
	_thr_labels[key] = sl_val
	blk.add_child(row2)

	# 行3：权重输入框 + 本项得分
	var row3 := HBoxContainer.new()
	row3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row3.add_theme_constant_override("separation", 4)
	var w_lab := Label.new()
	w_lab.text = "权重"
	w_lab.custom_minimum_size = Vector2(56.0, 0)
	w_lab.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	w_lab.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		w_lab.add_theme_font_override("font", fnt)
	row3.add_child(w_lab)
	var w_in := LineEdit.new()
	w_in.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	w_in.placeholder_text = "权重"
	w_in.custom_maximum_size = Vector2(10000.0, 10000.0)
	w_in.text = "%.1f" % WEIGHT_DEFAULTS[key]
	w_in.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		w_in.add_theme_font_override("font", fnt)
	UIStyle.apply_line_edit_style(w_in)
	w_in.text_submitted.connect(_on_weight_changed.bind(key))
	row3.add_child(w_in)
	_weight_inputs[key] = w_in
	var contrib := Label.new()
	contrib.text = "本项 +0.0"
	contrib.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	contrib.add_theme_color_override("font_color", Color(0.8, 0.95, 0.82))
	contrib.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		contrib.add_theme_font_override("font", fnt)
	row3.add_child(contrib)
	_contrib_labels[key] = contrib
	blk.add_child(row3)

	return blk


func _sep() -> HSeparator:
	var s := HSeparator.new()
	s.add_theme_constant_override("separation", 2)
	return s


# ---------------- 交互 ----------------

func _on_close(_id: String) -> void:
	closed.emit()


func close() -> void:
	_save_state()
	closed.emit()


func _on_refresh_tick() -> void:
	_recompute()


func _on_slider_changed(_value: float, key: String) -> void:
	_recompute()
	_save_state()


func _on_weight_changed(_text: String, key: String) -> void:
	_recompute()
	_save_state()


func _on_score_threshold_changed(_text: String) -> void:
	_recompute()
	_save_state()


# 「＋ 添加进程」：新增一行（进程名输入 + 权重输入 + 检测状态 + 删除×）
func _on_add_proc_pressed(_id: String) -> void:
	_add_proc_row("", "1.0", "other")
	_save_state()


func _on_remove_proc_pressed(_id: String, row: HBoxContainer) -> void:
	for i in range(_proc_rows.size()):
		if _proc_rows[i]["container"] == row:
			_proc_rows.remove_at(i)
			break
	if is_instance_valid(row):
		row.queue_free()
	_recompute()
	_save_state()


func _on_proc_name_changed(_text: String) -> void:
	_recompute()
	_save_state()


func _on_proc_weight_changed(_text: String) -> void:
	_recompute()
	_save_state()


func _add_proc_row(name: String, weight: String, kind: String = "other") -> void:
	if _proc_list == null:
		return
	var fnt := UIStyle.get_cjk_font()
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 4)

	var name_edit := LineEdit.new()
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.placeholder_text = "进程名，如 chrome / explorer"
	name_edit.text = name
	name_edit.custom_maximum_size = Vector2(10000.0, 10000.0)
	name_edit.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		name_edit.add_theme_font_override("font", fnt)
	UIStyle.apply_line_edit_style(name_edit)
	name_edit.text_submitted.connect(_on_proc_name_changed)
	row.add_child(name_edit)

	# ★ 属性下拉：标注该进程属于哪类活动（真值存 item metadata，与批次 67/69 同规）
	var kind_opt := OptionButton.new()
	kind_opt.custom_minimum_size = Vector2(78.0, 0)
	kind_opt.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		kind_opt.add_theme_font_override("font", fnt)
	_fill_kind_options(kind_opt)
	_select_kind_meta(kind_opt, kind)
	kind_opt.item_selected.connect(_on_proc_kind_changed)
	row.add_child(kind_opt)

	var w_edit := LineEdit.new()
	w_edit.custom_minimum_size = Vector2(56.0, 0)
	w_edit.placeholder_text = "权重"
	w_edit.text = weight
	w_edit.custom_maximum_size = Vector2(10000.0, 10000.0)
	w_edit.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		w_edit.add_theme_font_override("font", fnt)
	UIStyle.apply_line_edit_style(w_edit)
	w_edit.text_submitted.connect(_on_proc_weight_changed)
	row.add_child(w_edit)

	var status := Label.new()
	status.text = "（未填）"
	status.custom_minimum_size = Vector2(96.0, 0)
	status.clip_text = true
	status.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	status.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		status.add_theme_font_override("font", fnt)
	row.add_child(status)

	var rm := UIBtn.new()
	rm.set_id("perf_busy_rm_proc")
	rm.set_label("×")
	rm.custom_minimum_size = Vector2(26.0, 26.0)
	rm.pressed_id.connect(_on_remove_proc_pressed.bind(row))
	row.add_child(rm)

	_proc_list.add_child(row)
	_proc_rows.append({
		"name_edit": name_edit, "weight_edit": w_edit, "kind_opt": kind_opt,
		"status_label": status, "container": row,
	})
	_recompute()


# 填充属性下拉的选项（显示名进文本，真值进 metadata）。
func _fill_kind_options(opt: OptionButton) -> void:
	opt.clear()
	for pair in ACTIVITY_KINDS:
		opt.add_item(str(pair[1]))
		opt.set_item_metadata(opt.item_count - 1, str(pair[0]))


## 按真值选中属性下拉项（找不到则落到「其他」）。
func _select_kind_meta(opt: OptionButton, value: String) -> void:
	for i in opt.item_count:
		if str(opt.get_item_metadata(i)) == value:
			opt.select(i)
			return
	if opt.item_count > 0:
		opt.select(0)


## 读取某进程行的属性真值（metadata）。
func _proc_kind(row: Dictionary) -> String:
	var opt: OptionButton = row.get("kind_opt")
	if opt == null or not is_instance_valid(opt) or opt.selected < 0:
		return "other"
	return str(opt.get_item_metadata(opt.selected))


func _on_proc_kind_changed(_idx: int) -> void:
	_recompute()
	_save_state()


# ---------------- 定时切换忙闲状态 ----------------

func _on_add_schedule_pressed(_id: String) -> void:
	_add_schedule_row([], "08:00", "12:00")
	_save_state()


func _on_remove_schedule_pressed(_id: String, block: VBoxContainer) -> void:
	for i in range(_schedule_rows.size()):
		if _schedule_rows[i]["container"] == block:
			_schedule_rows.remove_at(i)
			break
	if is_instance_valid(block):
		block.queue_free()
	_save_state()


## 用户正在编辑时间 → 实时标红非法项 + 落盘（未填完整的条目在收集时会被跳过）
func _on_schedule_time_edited() -> void:
	_validate_schedule_times()
	_save_state()


## 回车确认：把 "8:00" 这类写法规范化成 "08:00"（只改合法项，非法项保留原样由标红提示）
func _on_schedule_time_submitted() -> void:
	for row in _schedule_rows:
		for key in ["start_edit", "end_edit"]:
			var le: LineEdit = row[key]
			var m: int = BusyState.parse_hhmm(str(le.text)) if BusyState != null else -1
			if m >= 0:
				le.text = BusyState.format_hhmm(m)
	_validate_schedule_times()
	_save_state()


## 新增一个时段行：星期勾选（一二三四五六日）+ 进入(忙)时间 + 退出(忙)时间 + 删除×
## days 用 ISO 编号（1=周一…7=周日），与 BusyState.resolve_window 的 days 字段一致。
func _add_schedule_row(days: Array, start: String, end: String) -> void:
	if _schedule_list == null:
		return
	var fnt := UIStyle.get_cjk_font()
	var block := VBoxContainer.new()
	block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	block.add_theme_constant_override("separation", 2)

	# 第 1 行：星期勾选 + 删除×
	var row1 := HBoxContainer.new()
	row1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_theme_constant_override("separation", 2)
	var checks: Array = []
	for i in WEEK_LABELS.size():
		var ck := CheckBox.new()
		ck.text = WEEK_LABELS[i]
		ck.tooltip_text = WEEK_NAMES[i]
		ck.button_pressed = _has_day(days, i + 1)     # 加载期由 _loading 抑制回写
		ck.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
		if is_instance_valid(fnt):
			ck.add_theme_font_override("font", fnt)
		ck.toggled.connect(func(_on: bool) -> void: _save_state())
		row1.add_child(ck)
		checks.append(ck)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_child(spacer)
	var rm := UIBtn.new()
	rm.set_id("perf_busy_rm_schedule")
	rm.set_label("×")
	rm.custom_minimum_size = Vector2(26.0, 26.0)
	rm.pressed_id.connect(_on_remove_schedule_pressed.bind(block))
	row1.add_child(rm)
	block.add_child(row1)

	# 第 2 行：进入(忙) → 退出(忙)
	var row2 := HBoxContainer.new()
	row2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_theme_constant_override("separation", 4)
	var start_edit := _mk_time_edit("进入", start, row2, fnt)
	var end_edit := _mk_time_edit("退出", end, row2, fnt)
	block.add_child(row2)

	_schedule_list.add_child(block)
	_schedule_rows.append({"checks": checks, "start_edit": start_edit, "end_edit": end_edit, "container": block})
	_validate_schedule_times()


## 「标签 + 时间输入框」一行；返回输入框（供收集/校验用）
func _mk_time_edit(label: String, value: String, row: HBoxContainer, fnt: Font) -> LineEdit:
	var lab := Label.new()
	lab.text = label
	lab.custom_minimum_size = Vector2(34.0, 0)
	lab.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	lab.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		lab.add_theme_font_override("font", fnt)
	row.add_child(lab)
	var le := LineEdit.new()
	le.text = value                      # ★ LineEdit.text = x 不触发 text_changed → 加载不会误回写
	le.placeholder_text = TIME_HINT
	le.custom_minimum_size = Vector2(72.0, 0)
	le.custom_maximum_size = Vector2(10000.0, 10000.0)
	le.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		le.add_theme_font_override("font", fnt)
	UIStyle.apply_line_edit_style(le)
	le.text_changed.connect(func(_t: String) -> void: _on_schedule_time_edited())
	le.text_submitted.connect(func(_t: String) -> void: _on_schedule_time_submitted())
	row.add_child(le)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(6.0, 0)
	row.add_child(gap)
	return le


func _validate_schedule_times() -> void:
	for row in _schedule_rows:
		_mark_time_valid(row["start_edit"])
		_mark_time_valid(row["end_edit"])


## days 是否含某星期（1=周一…7=周日）。
## ★ 必须按 int 归一化：JSON 读回的数字是 float（[3] → [3.0]），
##   而 Godot 4 的 `Array.has(3)` 对 float 元素返回 false → 勾选框会「读回后不勾选」。
func _has_day(days: Array, weekday: int) -> bool:
	if BusyState != null and BusyState.has_method("has_day"):
		return BusyState.has_day(days, weekday)
	for d in days:
		if int(d) == weekday:
			return true
	return false


func _mark_time_valid(le: LineEdit) -> void:
	var ok := _is_valid_time(str(le.text))
	le.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT if ok else Color(1.0, 0.45, 0.4))


func _is_valid_time(text: String) -> bool:
	var s := str(text).strip_edges()
	if s.is_empty():
		return false
	if BusyState != null and BusyState.has_method("parse_hhmm"):
		return BusyState.parse_hhmm(s) >= 0
	var parts := s.split(":")
	if parts.size() != 2:
		return false
	if not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return false
	var h := int(parts[0])
	var m := int(parts[1])
	return h >= 0 and h <= 23 and m >= 0 and m <= 59


## 收集时段 → [{ "days":[1..7], "start":"HH:MM", "end":"HH:MM" }, ...]
## 没勾任何星期、或两个时间有任一非法的条目**直接跳过**（没填完的时段本就不该生效）。
func _collect_schedule() -> Array:
	var out := []
	for row in _schedule_rows:
		var days := []
		var checks: Array = row["checks"]
		for i in checks.size():
			if checks[i].button_pressed:
				days.append(i + 1)
		var sm: int = BusyState.parse_hhmm(str(row["start_edit"].text)) if BusyState != null else -1
		var em: int = BusyState.parse_hhmm(str(row["end_edit"].text)) if BusyState != null else -1
		if days.is_empty() or sm < 0 or em < 0:
			continue
		out.append({ "days": days, "start": BusyState.format_hhmm(sm), "end": BusyState.format_hhmm(em) })
	return out


# 解析权重：非法输入兜底 1.0（不阻断整体计算）
func _parse_weight(text: String) -> float:
	var t := str(text).strip_edges()
	if t.is_empty():
		return 1.0
	var f := float(t)
	if f != f or f < 0.0:   # NaN 或负数 → 兜底 1.0
		return 1.0
	return f


func _parse_score_threshold() -> float:
	var t := _score_threshold_input.text.strip_edges()
	if t.is_empty():
		return SCORE_THRESHOLD_DEFAULT
	var f := float(t)
	if f != f:   # NaN → 兜底默认
		return SCORE_THRESHOLD_DEFAULT
	return f


# 重新计算并显示：当前% / 判断线 / 本项得分 / 总分 / 状态
func _recompute() -> void:
	if PerfMonitor == null:
		return
	var ok := PerfMonitor.last_sample_ok
	_score_threshold = _parse_score_threshold()
	var thresholds := {}
	var weights := {}
	for k in KEYS:
		var thr: float = _sliders[k].value
		var w: float = _parse_weight(_weight_inputs[k].text)
		thresholds[k] = thr
		weights[k] = w
		var cur: float = PerfMonitor.metric_percent(k)
		var over: float = cur - thr
		var contrib := 0.0
		if ok and over > 0.0:
			contrib = over * w
		if ok:
			_cur_labels[k].text = "%.1f%%" % cur
		else:
			_cur_labels[k].text = "不可用"
		_thr_labels[k].text = "%.0f" % thr
		_contrib_labels[k].text = ("本项 +%.1f" % contrib) if ok else "—"

	var score := 0.0
	if ok:
		score = PerfMonitor.compute_busy_score(thresholds, weights)
		score = max(score, 0.0)

	# 进程辅助：检测到指定进程名即把其权重加到总分；并按「属性」汇总当前活动
	var proc_total := 0.0
	var kind_hits: Dictionary = {}    # kind → 命中权重合计
	for row in _proc_rows:
		var nm: String = str(row["name_edit"].text).strip_edges()
		var w: float = _parse_weight(row["weight_edit"].text)
		var kind: String = _proc_kind(row)
		var st: Label = row["status_label"]
		if nm.is_empty():
			st.text = "（未填）"
			st.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
			continue
		if not ok:
			st.text = "未采样"
			st.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
			continue
		if PerfMonitor.is_process_running(nm):
			proc_total += w
			kind_hits[kind] = float(kind_hits.get(kind, 0.0)) + w
			st.text = "[%s] ✓ +%.1f" % [str(ACTIVITY_LABELS.get(kind, kind)), w]
			st.add_theme_color_override("font_color", Color(0.5, 1.0, 0.55))
		else:
			st.text = "未检测到"
			st.add_theme_color_override("font_color", Color(0.85, 0.6, 0.6))
	if ok:
		score += proc_total
	_total_label.text = "电脑性能使用分数: %.1f" % score

	_update_activity(kind_hits, ok)

	if not ok:
		_status_label.text = "状态: 数据不可用"
		_status_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	elif score > _score_threshold:
		_status_label.text = "状态: 在忙！(分数 %.1f > 阈值 %.1f)" % [score, _score_threshold]
		_status_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.45))
	else:
		_status_label.text = "状态: 空闲 (分数 %.1f ≤ 阈值 %.1f)" % [score, _score_threshold]
		_status_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.55))


## 据「检测到的进程及其属性」推断玩家可能正在干什么。
##   kind_hits: { kind → 命中权重合计 }；仅当数据可用且至少命中一个进程时给出结论。
##   推断规则：取命中权重最高的活动类型为主；若并列，全部列出（用「/」连接）。
func _update_activity(kind_hits: Dictionary, ok: bool) -> void:
	if _activity_label == null or not is_instance_valid(_activity_label):
		return
	if not ok:
		_activity_label.text = "当前活动: 数据不可用"
		_activity_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
		return
	if kind_hits.is_empty():
		_activity_label.text = "当前活动: —（未检测到已配置的进程）"
		_activity_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		return
	# 找最高权重
	var best := 0.0
	for k in kind_hits:
		best = maxf(best, float(kind_hits[k]))
	var tops: Array = []
	for k in kind_hits:
		if absf(float(kind_hits[k]) - best) < 0.0001:
			tops.append(str(ACTIVITY_LABELS.get(k, k)))
	tops.sort()
	_activity_label.text = "当前活动: %s（权重 %.1f）" % [" / ".join(tops), best]
	_activity_label.add_theme_color_override("font_color", Color(0.6, 0.95, 1.0))


# ---------------- 持久化（与具体存档无关，存于 settings 目录的 perf_busy.json） ----------------

## 收集当前面板设置并写回 perf_busy.json。加载期间(_loading)不回写。
func _save_state() -> void:
	if _loading:
		return
	if SaveManager == null:
		return
	var thresholds := {}
	var weights := {}
	for k in KEYS:
		thresholds[k] = _sliders[k].value
		weights[k] = _parse_weight(_weight_inputs[k].text)
	var procs := []
	for row in _proc_rows:
		var nm: String = str(row["name_edit"].text).strip_edges()
		procs.append({
			"name": nm,
			"weight": _parse_weight(row["weight_edit"].text),
			"kind": _proc_kind(row),
		})
	var data := {
		"score_threshold": _parse_score_threshold(),
		"thresholds": thresholds,
		"weights": weights,
		"proc_rows": procs,
		"schedule": _collect_schedule(),
	}
	SaveManager.save_perf_busy_settings(data)
	# ★ 忙闲状态单例立刻吃下新设置（时段边界/阈值刚变）→ 不必等下一秒 tick 才生效
	if BusyState != null and BusyState.has_method("apply_settings"):
		BusyState.apply_settings(data)


## 启动时从 perf_busy.json 读取并应用（文件缺失或键缺失则保留默认值）。
func _load_state() -> void:
	_loading = true
	var d: Dictionary = SaveManager.load_perf_busy_settings() if SaveManager != null else {}
	if typeof(d) == TYPE_DICTIONARY and not d.is_empty():
		if d.has("score_threshold"):
			_score_threshold_input.text = "%.1f" % float(d["score_threshold"])
		var thr: Variant = d.get("thresholds", {})
		var wts: Variant = d.get("weights", {})
		if typeof(thr) == TYPE_DICTIONARY:
			for k in KEYS:
				if (thr as Dictionary).has(k):
					_sliders[k].value = float((thr as Dictionary)[k])
		if typeof(wts) == TYPE_DICTIONARY:
			for k in KEYS:
				if (wts as Dictionary).has(k):
					_weight_inputs[k].text = "%.1f" % float((wts as Dictionary)[k])
		if d.has("proc_rows") and typeof(d["proc_rows"]) == TYPE_ARRAY:
			for row in d["proc_rows"]:
				if typeof(row) != TYPE_DICTIONARY:
					continue
				var nm: String = str(row.get("name", "")).strip_edges()
				if nm.is_empty():
					continue   # 跳过空名行（历史遗留或误存）
				_add_proc_row(nm, "%.1f" % float(row.get("weight", 1.0)), str(row.get("kind", "other")))
		var sch: Variant = d.get("schedule", [])
		if typeof(sch) == TYPE_ARRAY:
			for item in sch:
				if typeof(item) != TYPE_DICTIONARY:
					continue
				var it: Dictionary = item
				var days_v: Variant = it.get("days", [])
				var days: Array = days_v if typeof(days_v) == TYPE_ARRAY else []
				_add_schedule_row(days, str(it.get("start", "")), str(it.get("end", "")))
	_loading = false


## 最小化 / 还原：折叠只隐藏内容，顶栏（标题 + 拖动把柄 + 最小化 + 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	# ★★ 本页的可见盒子是 **_bg**（手动定位/定尺寸，panel 本身尺寸恒为 0）。
	#   折叠必须作用在 _bg 上——早前作用在 self（不可见）→ 内容消失了但框没收。
	UIMinimize.set_label(_min_btn, v)
	if is_instance_valid(_min_btn):
		UIMinimize.fold_below(_min_btn.get_parent(), v)
		var basis: Array = []
		var row := _min_btn.get_parent()
		if row is Container:
			basis.append(row)
		UIMinimize.apply_size(_bg, v, UIMinimize.DEFAULT_MIN_H, basis)
		if _bg != null:
			_bg.visible = true      # 背景永远保留（边框就在它身上）


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
