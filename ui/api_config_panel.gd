# ui/api_config_panel.gd
# 「接入外部 API」配置页面 —— 天气 / 人工智能 共用同一个类，用 config_kind 区分字段集。
#
# 当前阶段（用户要求）：**不做实际功能，但把设置的记录功能做出来**。
#   也就是说：界面上的输入能填、能选文件、能写盘；真正联网/生效留到以后。
#
# 字段：
#   ai（接入人工智能）      API、提示词（超大多行框 + 滚动条）、
#                          允许AI读取的个人信息文件 / 拒绝AI读取的个人信息文件（可多选文件）
#   weather（配置天气）     定位（右侧有「获取设备定位」按钮）、API
#
# 「获取设备定位」（仅天气面板）：
#   按下 → 起 get_location.ps1 子进程（设备经纬度 + IP 定位，互不阻塞主线程）
#        → 结果落盘 settings/location.json
#        → 读回该文件里的 location_text（国家/省份/城市，**以 IP 定位为准**）填进定位栏。
#
# 落盘：%文档%/HelloNyxel/settings/ 下的 ai.json / weather.json / location.json（见 SaveManager）。
#   面板底部会显示对应 JSON 的完整路径，方便玩家直接去看文件内容。
#
# 样式与其它 UI 一致（天蓝半透明底 + 荧光蓝边框），顶栏复用 UIDragHandle 拖动把柄。
class_name ApiConfigPanel
extends Control

signal closed

# ---------------- 尺寸 / 常量 ----------------
const PAD := 12.0
const TITLE_H := 30.0
const ROW_H := 28.0
const ICON_BTN := 28.0        # 文件夹按钮边长
const FILE_LIST_H := 78.0     # 文件列表滚动区高度
const PROMPT_H := 240.0       # 提示词输入框高度（约一页内容，超出自己滚）
# 小号字（说明文字）。不能用 UIStyle.FONT_SIZE - 2 当 const：static var 不是常量表达式。
const SMALL_FONT := 12

# 宽度：必须 ≥ 深色天气容器最小宽 480（逐日行 460 + 容器左右边距 20）
#   再加左右内边距 2*PAD=24 与竖向滚动条 ~12 → 530 保证总滚动条完整落在面板内、内容不被裁。
const WEATHER_W := 530.0
# ★ 604 → 628：给「来源位置」这行大字腾地方。原来内容高 590、可视只有 580 —— 加了大字行后
#   "关闭"按钮被顶到折线以下（要滚一下才够得着）。Body = WEATHER_H - 2*PAD，实测 604 时可视 580。
const WEATHER_H := 628.0
# （WEEK_LIST_H 已废弃：逐日列表改为按内容自然撑开，不再有固定高度 / 内部滚动条）
# 「来源位置」关键字号。★ 不能用 UIStyle.FONT_SIZE + 4 当 const（static var 不是常量表达式）。
#   取值口径：说明文字 12 < 正文 14 < 本行 18 < 面板标题 20 —— 要一眼能跳出来，但不抢标题。
const LOCAL_LOC_FONT := 18
const AI_W := 600.0
const AI_H := 700.0

# 「获取设备定位」调用的 PowerShell 脚本（设备经纬度 + IP 定位 → settings/location.json）
const LOCATION_SCRIPT := "res://addons/hellonyxel_sysinfo/get_location.ps1"
# 等待定位脚本产物的上限（秒）。脚本自身各阶段都有超时（设备 5s + 每个接口 5s），
# 这里取更宽的值兜底 —— 实测偶尔会碰上系统侧对「首次拉起子进程」的扫描，可拖到十几秒。
const LOCATE_TIMEOUT_SEC := 45.0
const LOCATE_BTN_W := 104.0

# 定位状态行配色
const LOCATE_COLOR_OK: Color = Color(0.5, 1.0, 0.55)
const LOCATE_COLOR_WARN: Color = Color(1.0, 0.55, 0.5)
const LOCATE_COLOR_PENDING: Color = Color(1.0, 0.86, 0.5)

const KIND_AI := "ai"
const KIND_WEATHER := "weather"

# 文件选择框的过滤项（个人信息文件多为文档/图片；保留「所有文件」兜底）
# ★ 用 Array 字面量当常量；PackedStringArray(...) 是构造调用，不能做 const 初始化。
const FILE_FILTERS: Array = [
	"*.txt, *.md, *.json, *.csv, *.log ; 文本 / 数据",
	"*.doc, *.docx, *.pdf, *.rtf ; 文档",
	"*.png, *.jpg, *.jpeg, *.bmp, *.gif ; 图片",
	"*.* ; 所有文件",
]

# ---------------- 对外配置（desktop.gd 在 add_child 之前设置）----------------
var config_kind: String = KIND_AI    # "ai" | "weather"
var config_title: String = "配置"

# ---------------- 内部引用 ----------------
var _panel: UIPanel
var _title: Label
var _close_btn: UIBtn
var _path_hint: Label

# AI 字段
var _api_edit: LineEdit = null
var _verify_btn: UIBtn = null
var _conn_label: Label = null
var _prompt_edit: TextEdit = null
var _allow_row_btn: FolderButton = null
var _deny_row_btn: FolderButton = null
var _allow_list: VBoxContainer = null
var _deny_list: VBoxContainer = null
var _allow_files: Array = []
var _deny_files: Array = []

# 天气字段
var _loc_edit: LineEdit = null
var _weather_api_edit: LineEdit = null
var _locate_btn: UIBtn = null          # 「获取设备定位」按钮（定位栏右侧）
var _locate_status: Label = null       # 定位状态行（获取中 / 已获取 / 失败原因）
var _manual_box: VBoxContainer = null  # 「手动定位」整组（开关开启时被本机天气取代 → 整组置灰禁用）

# ---- 读取本机天气（Windows/MSN，见 autoload/local_weather.gd）----
var _local_check: CheckButton = null   # 「读取本机天气」开关
var _local_refresh_btn: UIBtn = null   # 「即刻刷新」
var _local_loc: Label = null           # ★「来源位置」大字行（关键信息：这份天气是哪里的）
var _local_status: Label = null        # 其余细节小字（开关态 / 坐标 / 采集时间 / 当前 / 保留天数）
var _local_src_btn: OptionButton = null  # ★「采用来源」下拉：本机可能同时有多个位置的天气
var _week_list: VBoxContainer = null   # 逐日列表（含「昨天→前一周」的历史保留行）
# ★ 批次 25：当前展开逐小时的日期（手风琴，同一时刻只有一天；"" = 全折叠）。
#   记日期而不是索引 —— 列表会因采集刷新而增删行，用索引会张冠李戴。
var _expanded_date := ""

# 定位采集的异步状态（用「子进程 + 轮询产物文件」实现，不用 Thread：
# ★ 后台 Thread 若没 join 就随场景一起拆，会与同步 OS.execute 子进程同拆 → native signal 11。
#   子进程是独立进程，Godot 不等待它，退出时不存在 join 竞态。）
var _locating: bool = false
var _locate_pid: int = 0
var _locate_start_ms: int = 0

# 文件选择框（首次点按钮时才建；无头环境不建）
var _file_dialog: FileDialog = null
var _dialog_target: String = ""

var _loading: bool = false           # 载入中 → 抑制回写（避免读档即覆盖）
var _ever_centered: bool = false     # 首次 open 居中，之后保留拖动位置
var _open: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	_load_state()
	_ensure_config_file()
	visible = false
	# 本机天气：订阅采集结果 / 起止事件（面板关着也在采集，重开时要看到最新）
	if config_kind == KIND_WEATHER and LocalWeather != null:
		if not LocalWeather.updated.is_connected(_on_local_updated):
			LocalWeather.updated.connect(_on_local_updated)
		if not LocalWeather.refresh_started.is_connected(_on_local_refresh_started):
			LocalWeather.refresh_started.connect(_on_local_refresh_started)
		if not LocalWeather.refresh_finished.is_connected(_on_local_refresh_finished):
			LocalWeather.refresh_finished.connect(_on_local_refresh_finished)
		_refresh_local_view()


# ==================== 构建 ====================

func _build_ui() -> void:
	var w := _panel_width()
	var h := _panel_height()

	# 背景：与其它 UI 一致的浅天蓝半透明 + 荧光蓝边框
	_panel = UIPanel.new()
	_panel.name = "UIPanel"
	_panel.set_corner_radius(UIStyle.CORNER_RADIUS)
	_panel.set_fill_color(UIStyle.FILL_DEFAULT)
	_panel.set_border_color(UIStyle.BORDER)
	_panel.set_border_width(UIStyle.BORDER_WIDTH)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	# ★ 先入树、再设锚点：在树外设「不对等锚点」会被 Godot 警告
	#   "Nodes with non-equal opposite anchors will have their size overridden after _ready()"。
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)

	# 整体可滚动：内容长于面板时（小屏）也能看到全部字段。
	# ★ 标题行（标题 / 拖动把柄 / ×）在滚动区**外面**：滚动时标题栏固定不动。
	var title_row := _build_title_row()
	_panel.add_child(title_row)
	title_row.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title_row.offset_left = PAD
	title_row.offset_right = -PAD
	title_row.offset_top = PAD - 2.0
	title_row.offset_bottom = PAD - 2.0 + TITLE_H

	var sc := ScrollContainer.new()
	sc.name = "Body"
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(sc)
	sc.set_anchors_preset(Control.PRESET_FULL_RECT)
	sc.offset_left = PAD
	sc.offset_top = PAD + TITLE_H + 2.0
	sc.offset_right = -PAD
	sc.offset_bottom = -PAD

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 6)
	sc.add_child(vbox)

	if config_kind == KIND_WEATHER:
		_build_weather_body(vbox)
	else:
		_build_ai_body(vbox)
	vbox.add_child(_build_footer())

	# 首次构建时把面板 Control 自身尺寸设好（_center 会再摆位置）
	# ★ 不要再给 _panel 手动 size：它挂的是 FULL_RECT 锚点，尺寸自动跟随本 Control；
	#   手动设 size 会触发 Godot 警告 "…non-equal opposite anchors…"。
	size = Vector2(w, h)



# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏控件整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build_title_row() -> HBoxContainer:
	var top := HBoxContainer.new()
	top.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.custom_minimum_size = Vector2(0.0, TITLE_H)

	_title = Label.new()
	_title.text = config_title
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_font(_title, 6)
	top.add_child(_title)

	# 拖动把柄（复用 UIDragHandle：按住移动整个面板）
	var handle := UIDragHandle.new()
	handle.setup(self)
	handle.tooltip_text = "拖动以移动面板"
	top.add_child(handle)

	# 右上 × 关闭：**不应用**本次改动（回滚到磁盘上的值再关；应用请按底部「应用并关闭」）
	var x_btn := UIBtn.new()
	x_btn.set_id("api_config_close_x")
	x_btn.set_label("×")
	x_btn.custom_minimum_size = Vector2(TITLE_H, TITLE_H)
	x_btn.pressed_id.connect(_on_discard_pressed)
	top.add_child(x_btn)
	# ★ 本页顶栏是 HBox（标题 | 移动把柄 | × 关闭）→ 最小化插到 × **之前**，
	#   排布即「移动 | 最小化 | 关闭」。误用 attach_anchored 会按绝对偏移摆位。
	_min_btn = UIMinimize.attach_before(top, x_btn, func(): set_minimized(not _minimized))
	return top


# ---------------- 人工智能 ----------------

func _build_ai_body(vbox: VBoxContainer) -> void:
	# ① API + 验证连通
	var api_row := HBoxContainer.new()
	api_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	api_row.add_theme_constant_override("separation", 6)
	api_row.add_child(_label("API", 44.0))

	_api_edit = LineEdit.new()
	_api_edit.name = "ApiEdit"
	_api_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_api_edit.placeholder_text = "填入 API 地址 / 密钥，例如 https://api.example.com/v1"
	_api_edit.custom_minimum_size = Vector2(120.0, ROW_H)
	_api_edit.custom_maximum_size = Vector2(10000.0, 10000.0)
	_apply_edit_style(_api_edit)
	api_row.add_child(_api_edit)

	_verify_btn = UIBtn.new()
	_verify_btn.set_id("ai_verify_api")
	_verify_btn.set_label("验证连通")
	_verify_btn.custom_minimum_size = Vector2(84.0, ROW_H)
	_verify_btn.pressed_id.connect(_on_verify_pressed)
	api_row.add_child(_verify_btn)

	_conn_label = _label("未验证", 62.0)
	_conn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_conn_label.add_theme_color_override("font_color", Color(0.82, 0.86, 0.9))
	api_row.add_child(_conn_label)
	vbox.add_child(api_row)

	vbox.add_child(_hint("（实际联网检测尚未实现：现在点「验证连通」一律反馈「联通失败」；接通后会自动显示「已联通」）"))

	# ② 提示词：超大多行输入框 + 自带滚动条（因此不再做「长文本按钮」）
	var prompt_title := _label("提示词", 0.0)
	prompt_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(prompt_title)

	_prompt_edit = TextEdit.new()
	_prompt_edit.name = "PromptEdit"
	_prompt_edit.custom_minimum_size = Vector2(0.0, PROMPT_H)
	_prompt_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_prompt_edit.placeholder_text = "在这里写交给人工智能的提示词（可放一整页内容，超出用右侧滚动条）"
	_prompt_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_prompt_edit.scroll_fit_content_height = false
	UIStyle.apply_text_edit_style(_prompt_edit)
	if is_instance_valid(UIStyle.get_cjk_font()):
		_prompt_edit.add_theme_font_override("font", UIStyle.get_cjk_font())
	_prompt_edit.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	vbox.add_child(_prompt_edit)

	# ③④ 个人信息文件（允许 / 拒绝）：标题行 + 文件夹按钮 + 可滚动列表
	var allow := _build_file_section(
		"允许AI读取的个人信息文件",
		"（点右侧文件夹按钮，在资源管理器里选择要允许的文件）",
		"allow")
	_allow_row_btn = allow["btn"]
	_allow_list = allow["list"]
	vbox.add_child(allow["root"])

	var deny := _build_file_section(
		"拒绝AI读取的个人信息文件",
		"（点右侧文件夹按钮，在资源管理器里选择要拒绝的文件）",
		"deny")
	_deny_row_btn = deny["btn"]
	_deny_list = deny["list"]
	vbox.add_child(deny["root"])


# ---------------- 天气 ----------------

func _build_weather_body(vbox: VBoxContainer) -> void:
	# ---------- ① 读取本机天气（开关 + 即刻刷新）----------
	# ★ 整块「天气显示区」加深色背景（与设备管理页「设备信息 / 总览」同款：
	#   FILL_LEVEL_STAGE 深蓝近黑 + STAGE_BORDER），让天气数据从面板天蓝底里"沉"出来。
	var dark := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = UIStyle.FILL_LEVEL_STAGE
	sb.border_color = UIStyle.STAGE_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(int(UIStyle.CORNER_RADIUS * 0.6))
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	dark.add_theme_stylebox_override("panel", sb)
	dark.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(dark)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 6)
	dark.add_child(box)
	# ★ 放在最上面：它决定下面「手动定位」那一组是否还生效（开启后被取代）。
	var local_row := HBoxContainer.new()
	local_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	local_row.add_theme_constant_override("separation", 6)
	local_row.add_child(_label("读取本机天气", 96.0))

	_local_check = CheckButton.new()
	_local_check.name = "ReadLocalWeather"
	_local_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_local_check.custom_minimum_size = Vector2(0.0, ROW_H)
	_local_check.tooltip_text = "读取本机（Windows / MSN）天气并保存；开启后按整点自动获取，也可点右侧「即刻刷新」"
	if is_instance_valid(UIStyle.get_cjk_font()):
		_local_check.add_theme_font_override("font", UIStyle.get_cjk_font())
	_local_check.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	_local_check.toggled.connect(_on_local_toggled)
	local_row.add_child(_local_check)

	_local_refresh_btn = UIBtn.new()
	_local_refresh_btn.set_id("weather_local_refresh")
	_local_refresh_btn.set_label("即刻刷新")
	_local_refresh_btn.custom_minimum_size = Vector2(LOCATE_BTN_W, ROW_H)
	_local_refresh_btn.tooltip_text = "立刻采集一次本机天气（不等整点）"
	_local_refresh_btn.pressed_id.connect(_on_local_refresh_pressed)
	local_row.add_child(_local_refresh_btn)
	box.add_child(local_row)

	box.add_child(_hint("开启后：每整点自动读取一次本机天气，数据存 settings/local_weather.json；"
		+ "「昨天 → 前一周」的预报会保留下来用于对比趋势。"))

	# 状态块。
	# ★★ 「来源位置」单独拎出来放大：它回答「这份天气是哪里的」，也是整套数据里最容易让玩家
	#    误会的一条（开了代理/VPN 时走 IP 兜底会指向出口城市）。混在 12 号说明小字里极易被看漏。
	_local_loc = Label.new()
	_local_loc.name = "LocalWeatherLocation"
	_local_loc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_local_loc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_local_loc.add_theme_font_size_override("font_size", LOCAL_LOC_FONT)
	if is_instance_valid(UIStyle.get_cjk_font()):
		_local_loc.add_theme_font_override("font", UIStyle.get_cjk_font())
	_local_loc.visible = false          # 空行不占位：BoxContainer 会跳过不可见子节点
	box.add_child(_local_loc)

	# 其余细节（开关态 / 坐标 / 采集时间 / 当前天气 / 历史保留）继续用说明小字
	_local_status = _hint("（尚未采集：打开开关或点「即刻刷新」。）")
	_local_status.name = "LocalWeatherStatus"
	box.add_child(_local_status)

	# ★★ 采用来源：本机可能同时采到多个位置的天气（设备定位 / IP 兜底，代理/VPN 会指向不同城市），
	#   全部列出，玩家手动选一条采用。下拉项 = location_text + 来源标注；选中项存 weather.json。
	var src_row := HBoxContainer.new()
	src_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	src_row.add_theme_constant_override("separation", 6)
	src_row.add_child(_label("采用来源", 96.0))
	_local_src_btn = OptionButton.new()
	_local_src_btn.name = "LocalSourceSelect"
	_local_src_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_local_src_btn.custom_minimum_size = Vector2(0.0, ROW_H)
	_local_src_btn.tooltip_text = "本机可能同时有多个位置的天气（设备定位 / IP 兜底），选一条采用"
	if is_instance_valid(UIStyle.get_cjk_font()):
		_local_src_btn.add_theme_font_override("font", UIStyle.get_cjk_font())
	_local_src_btn.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	_local_src_btn.item_selected.connect(_on_local_source_selected)
	src_row.add_child(_local_src_btn)
	box.add_child(src_row)

	# 逐日列表（今天及未来预报 + 已过去但被保留的历史）
	# ★ 不给固定高度：列表按内容自然撑开（整页滚动看全部），不再有列表内部滚动条。
	var week_title := _label("本机天气 · 逐日（※ = 已过去、保留用于对比的预报）", 0.0)
	week_title.custom_minimum_size = Vector2(0.0, 18.0)
	box.add_child(week_title)
	var week_sc := ScrollContainer.new()
	week_sc.name = "LocalWeekScroll"
	week_sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	week_sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	week_sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_week_list = VBoxContainer.new()
	_week_list.name = "LocalWeekList"
	_week_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_week_list.add_theme_constant_override("separation", 2)
	week_sc.add_child(_week_list)
	box.add_child(week_sc)

	vbox.add_child(_sep())

	# ---------- ② 手动定位（本机天气开启时整组被取代 → 置灰禁用）----------
	_manual_box = VBoxContainer.new()
	_manual_box.name = "ManualLocationBox"
	_manual_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_manual_box.add_theme_constant_override("separation", 6)

	var loc_row := HBoxContainer.new()
	loc_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	loc_row.add_theme_constant_override("separation", 6)
	loc_row.add_child(_label("定位", 56.0))
	_loc_edit = LineEdit.new()
	_loc_edit.name = "LocationEdit"
	_loc_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_loc_edit.placeholder_text = "城市 / 区县，或经纬度，如 北京 或 39.90,116.40"
	_loc_edit.custom_minimum_size = Vector2(120.0, ROW_H)
	_loc_edit.custom_maximum_size = Vector2(10000.0, 10000.0)
	_apply_edit_style(_loc_edit)
	loc_row.add_child(_loc_edit)

	# 定位栏右侧：「获取设备定位」——读本机定位，落盘 settings/location.json，再回填本栏
	_locate_btn = UIBtn.new()
	_locate_btn.set_id("weather_locate")
	_locate_btn.set_label("获取设备定位")
	_locate_btn.custom_minimum_size = Vector2(LOCATE_BTN_W, ROW_H)
	_locate_btn.tooltip_text = "读取本机定位（设备经纬度 + IP 定位），写入 settings/location.json，并把定位填到左边的栏里"
	_locate_btn.pressed_id.connect(_on_locate_pressed)
	loc_row.add_child(_locate_btn)
	_manual_box.add_child(loc_row)

	# 定位状态行：获取中 / 已获取（含来源） / 失败原因
	_locate_status = _hint("（点右侧「获取设备定位」：读取本机定位 → 写入 settings/location.json → 回填本栏）")
	_locate_status.name = "LocateStatus"
	_manual_box.add_child(_locate_status)

	var api_row := HBoxContainer.new()
	api_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	api_row.add_theme_constant_override("separation", 6)
	api_row.add_child(_label("API", 56.0))
	_weather_api_edit = LineEdit.new()
	_weather_api_edit.name = "WeatherApiEdit"
	_weather_api_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_weather_api_edit.placeholder_text = "天气数据来源的 API 地址 / 密钥"
	_weather_api_edit.custom_minimum_size = Vector2(120.0, ROW_H)
	_weather_api_edit.custom_maximum_size = Vector2(10000.0, 10000.0)
	_apply_edit_style(_weather_api_edit)
	api_row.add_child(_weather_api_edit)
	_manual_box.add_child(api_row)

	_manual_box.add_child(_hint("（手动定位：仅当「读取本机天气」关闭时生效；填好后写进 weather.json）"))
	vbox.add_child(_manual_box)


# ---------------- 读取本机天气（Windows / MSN，见 autoload/local_weather.gd）----------------
#
# 交互语义：
#   · 开关 = weather.json 的 read_local_weather（LocalWeather 是唯一权威，这里只做显示/触发）；
#   · 开启 → 立刻采集一次（否则要等到下一个整点），之后每整点自动采集；
#   · 「即刻刷新」→ 立刻采集一次（不等整点）；
#   · 开启期间「手动定位」整组被取代 → 置灰禁用（关掉开关即恢复，栏里的值不会丢）。
#
# 天气说法（MSN/Foreca）是英文，这里只做**显示用**翻译；JSON 里保留原文。

const COND_ZH := {
	"Sunny": "晴", "Clear": "晴", "Mostly clear": "晴间多云", "Mostly sunny": "晴间多云",
	"Partly sunny": "晴间多云", "Partly cloudy": "多云", "Mostly cloudy": "多云转阴",
	"Cloudy": "阴", "Overcast": "阴", "Hazy": "霾", "Fog": "雾", "Mist": "薄雾",
	"Light rain": "小雨", "Rain": "中雨", "Heavy rain": "大雨", "Light drizzle": "毛毛雨",
	"Drizzle": "毛毛雨", "Light rain showers": "小阵雨", "Rain showers": "阵雨",
	"Scattered showers": "零星阵雨", "Thunderstorm": "雷阵雨", "Thundershower": "雷阵雨",
	"Light snow": "小雪", "Snow": "雪", "Heavy snow": "大雪", "Snow showers": "阵雪",
	"Sleet": "雨夹雪", "Rain and snow": "雨夹雪", "Freezing rain": "冻雨",
	"Light freezing rain": "冻雨", "Windy": "大风", "Breezy": "微风",
}


func _on_local_toggled(on: bool) -> void:
	if _loading or LocalWeather == null:
		return
	# LocalWeather 负责落盘 + 开启时立刻采集；本面板只跟显示
	LocalWeather.set_enabled(on)
	_apply_manual_enabled(not on)
	_refresh_local_view()
	_notify("已开启：读取本机天气" if on else "已关闭：恢复手动定位")


func _on_local_refresh_pressed(_id: String) -> void:
	if LocalWeather == null:
		return
	if LocalWeather.is_busy():
		_notify("正在采集，请稍候")
		return
	if not LocalWeather.refresh_now(true):
		_refresh_local_view()   # 起不来（无头 / 缺脚本）→ 把原因显示到状态行


func _on_local_refresh_started(_manual: bool) -> void:
	_refresh_local_status()


func _on_local_updated() -> void:
	_refresh_local_view()


func _on_local_refresh_finished(_ok: bool, _reason: String) -> void:
	_refresh_local_view()


## 手动定位整组的可用性：本机天气开启时被取代 → 置灰禁用（真禁用，不只是看着灰）
func _apply_manual_enabled(manual_enabled: bool) -> void:
	if _loc_edit != null and is_instance_valid(_loc_edit):
		_loc_edit.editable = manual_enabled
	if _weather_api_edit != null and is_instance_valid(_weather_api_edit):
		_weather_api_edit.editable = manual_enabled
	if _locate_btn != null and is_instance_valid(_locate_btn):
		_locate_btn.disabled = not manual_enabled
	if _manual_box != null and is_instance_valid(_manual_box):
		_manual_box.modulate = Color(1, 1, 1, 1.0) if manual_enabled else Color(1, 1, 1, 0.45)


## 刷新「本机天气」整块显示（开关态 + 状态行 + 逐日列表）
func _refresh_local_view() -> void:
	if _local_check != null and is_instance_valid(_local_check) and LocalWeather != null:
		var on := LocalWeather.is_enabled()
		if _local_check.button_pressed != on:
			_local_check.set_pressed_no_signal(on)
		_apply_manual_enabled(not on)
	_rebuild_source_options()
	_rebuild_week_list()
	_refresh_local_status()


func _refresh_local_status() -> void:
	if _local_status == null or not is_instance_valid(_local_status):
		return
	if LocalWeather == null:
		_set_local_loc("")
		_local_status.text = "（LocalWeather 未就绪）"
		return
	if LocalWeather.is_busy():
		_set_local_loc("")
		_local_status.text = "正在采集本机天气…（首次会拉起 PowerShell，可能要十几秒）"
		_local_status.add_theme_color_override("font_color", LOCATE_COLOR_PENDING)
		return
	var err := LocalWeather.last_error()
	var on := LocalWeather.is_enabled()
	if not LocalWeather.has_data():
		_set_local_loc("")
		if on:
			_local_status.text = "尚无本机天气数据" + ("：%s" % err if not err.is_empty() else "（点「即刻刷新」）")
			_local_status.add_theme_color_override("font_color", LOCATE_COLOR_WARN if not err.is_empty() else LOCATE_COLOR_PENDING)
		else:
			_local_status.text = "「读取本机天气」未开启：下方「手动定位」生效。" \
				+ ("（上次采集失败：%s）" % err if not err.is_empty() else "")
			_local_status.add_theme_color_override("font_color", Color(0.82, 0.88, 0.94, 0.85))
		return
	# ★ 一旦有数据就显示，与开关开没开无关：开关只决定本机天气是否**取代**手动定位，
	#   而「昨天 → 前一周」被保留下来的数据本身就是给玩家对比趋势用的，藏起来就白存了。
	# ★★ 「来源位置」= 这套数据里最关键、也最容易被误会的一条 —— 单独用大字显示
	#    （值就是 MSN 自己反解出的地名，不是我们在猜）。
	_set_local_loc("来源位置：%s" % LocalWeather.location_text())
	if _local_loc != null and is_instance_valid(_local_loc):
		_local_loc.add_theme_color_override("font_color",
			LOCATE_COLOR_OK if on else Color(0.88, 0.93, 0.98, 0.95))
	var data := LocalWeather.get_data()
	# ★ 当前显示的是「选中来源」那一条（多来源时与下拉选择一致）
	var e := LocalWeather.selected_entry()
	var cur: Variant = e.get("current", {})
	var loc: Variant = e.get("location", {})
	var ret: Variant = e.get("retain", {})
	var lines: Array = [
		"读取本机天气：已开启（下方「手动定位」已被取代）" if on
			else "读取本机天气：未开启（下方「手动定位」生效 · 以下是最近一次采集到的本机天气）",
	]
	var src := "设备定位 Windows Location Service" if LocalWeather.coord_source() == "device" else "IP 定位"
	if loc is Dictionary:
		lines.append("　　坐标：%.4f, %.4f（%s，由 MSN 反解）" % [
			float((loc as Dictionary).get("latitude", 0.0)),
			float((loc as Dictionary).get("longitude", 0.0)), src])
	lines.append("采集时间：%s（%s）" % [
		str(data.get("updated_at", "")), _ago_text(LocalWeather.age_seconds())])
	if cur is Dictionary:
		var c := cur as Dictionary
		lines.append("当前：%s %s°C（体感 %s°C）· 湿度 %s%% · 风 %s m/s · AQI %s" % [
			_cond_zh(str(c.get("cap", ""))), _num_text(c.get("temp")), _num_text(c.get("feels")),
			_num_text(c.get("rh")), _num_text(c.get("wind_spd")), _num_text(c.get("aqi"))])
	if ret is Dictionary:
		var r := ret as Dictionary
		lines.append("保留天数：%s 天（%s → %s）" % [
			_num_text(r.get("days")), str(r.get("first_date", "")), str(r.get("last_date", ""))])
	# ★ 多来源提示：本机同时采到多个位置 → 提醒玩家去下拉里切换
	var n := LocalWeather.locations().size()
	if n > 1:
		lines.append("可用来源：%d 条（在上方「采用来源」里手动切换，当前显示第 %d 条）" % [n, LocalWeather.selected_index() + 1])
	if not err.is_empty():
		lines.append("上次失败：%s" % err)
	_local_status.text = "\n".join(lines)
	# 关键行已单独承载「状态色」，这里就统一用说明小字的暗色，别两处抢眼
	_local_status.add_theme_color_override("font_color", Color(0.82, 0.88, 0.94, 0.85))


## 「来源位置」大字行：空字符串 → 隐藏（BoxContainer 会跳过不可见子节点，不占位）
func _set_local_loc(text: String) -> void:
	if _local_loc == null or not is_instance_valid(_local_loc):
		return
	_local_loc.text = text
	_local_loc.visible = not text.is_empty()


## 重建「采用来源」下拉：列出全部 locations，标注设备/IP；选中项 = 当前采用来源。
## 无数据 → 禁用下拉并给占位项。
func _rebuild_source_options() -> void:
	if _local_src_btn == null or not is_instance_valid(_local_src_btn) or LocalWeather == null:
		return
	_local_src_btn.clear()
	var locs := LocalWeather.locations()
	if locs.is_empty():
		_local_src_btn.add_item("（采集后可选来源）")
		_local_src_btn.select(0)
		_local_src_btn.disabled = true
		return
	_local_src_btn.disabled = false
	var sel := LocalWeather.selected_source()
	var idx := -1
	for i in locs.size():
		var en: Variant = locs[i]
		if not (en is Dictionary):
			continue
		var lt := str((en as Dictionary).get("location_text", "")).strip_edges()
		var cs := str((en as Dictionary).get("coord_source", ""))
		var tag := "（设备定位）" if cs == "device" else "（IP 定位）"
		_local_src_btn.add_item(lt + tag)
		if lt == sel:
			idx = i
	if idx < 0:
		idx = LocalWeather.selected_index()   # 未选 → 回落 device / 第一条
	_local_src_btn.select(idx)


## 玩家在下拉里切换采用来源 → 落盘 weather.json（LocalWeather 广播 updated → 整块刷新）。
func _on_local_source_selected(index: int) -> void:
	if LocalWeather == null:
		return
	var locs := LocalWeather.locations()
	if index < 0 or index >= locs.size():
		return
	var en: Variant = locs[index]
	if not (en is Dictionary):
		return
	var lt := str((en as Dictionary).get("location_text", "")).strip_edges()
	if lt.is_empty():
		return
	LocalWeather.set_selected_source(lt)
	_notify("已采用来源：%s" % lt)


func _ago_text(sec: float) -> String:
	if sec >= 1.0e8:
		return "从未采集"
	if sec < 60.0:
		return "刚刚"
	if sec < 3600.0:
		return "%d 分钟前" % int(sec / 60.0)
	if sec < 86400.0:
		return "%d 小时前" % int(sec / 3600.0)
	return "%d 天前" % int(sec / 86400.0)


func _num_text(v: Variant) -> String:
	if v == null:
		return "--"
	match typeof(v):
		TYPE_FLOAT, TYPE_INT:
			return "%.0f" % float(v)
	return str(v)


## 「本机天气 · 逐日」列表：今天及未来预报 + 已过去但被保留的历史（行首带 ※）
##
## ★ 逐小时是**折叠**的（批次 25）：每天行尾有一个 ▼/▶ 按钮，点开才显示那天的小时明细。
##   手风琴语义——展开某一天时，其余已展开的自动折叠（同一时刻最多开一天），
##   状态记在 _expanded_date；再次点同一天则折叠回去。
##   没有逐小时数据的日子不给按钮（精度不支持时界面自然只剩逐日，不会出现死按钮）。
func _rebuild_week_list() -> void:
	if _week_list == null or not is_instance_valid(_week_list):
		return
	for c in _week_list.get_children():
		_week_list.remove_child(c)
		c.queue_free()
	if LocalWeather == null:
		return
	var rows: Array = LocalWeather.days()
	if rows.is_empty():
		_week_list.add_child(_hint("（暂无数据：打开开关或点「即刻刷新」）"))
		return
	var hourly_dates: Array = LocalWeather.hourly_dates()
	var has_hourly := LocalWeather.has_hourly()
	# 精度说明：只在真有逐小时数据时提示一句，避免"没数据"看起来像坏了
	if has_hourly:
		_week_list.add_child(_hint("点每行末尾的 ▼ 展开当天逐小时（共 %d 条）" % LocalWeather.hourly_count()))
	_week_list.add_child(_week_row("日期", "白天", "夜间", "高 / 低", true))
	var today := LocalWeather.today_key()
	for e in rows:
		var dict := e as Dictionary
		var date := str(dict.get("date", ""))
		var mark := "※ " if date < today else ""
		var hi: Variant = dict.get("hi")
		var lo: Variant = dict.get("lo")
		var temps := "-- / --"
		if hi != null and lo != null:
			temps = "%s / %s" % [_num_text(hi), _num_text(lo)]
		var can_expand := has_hourly and hourly_dates.has(date)
		var expanded := can_expand and _expanded_date == date
		_week_list.add_child(_week_row(
			mark + date, _cond_zh(str(dict.get("cap", ""))),
			_cond_zh(str(dict.get("night_cap", ""))), temps, false, date, can_expand, expanded))
		# 展开态：紧跟该日行之后插入小时明细
		if expanded:
			for hv in LocalWeather.hours_of_date(date):
				_week_list.add_child(_hour_row(hv as Dictionary))


## 点折叠按钮：展开该天 / 收起该天；展开别的一天时其余自动折叠（手风琴）。
##
## ★ `_id` 是 UIBtn.pressed_id 信号**自带的那个参数**，不是多余的占位符：
##   信号实参 = 信号自带的 id + .bind(date) 追加的 date ⇒ 实际传两个。
##   形参必须写成「必填 2 个」(_id, date)，只写 1 个则处理函数永远不会被调用
##   （audit_signal_arity.py 会判成「实参个数不可能匹配」；★ 直调方法的探针测不出来，
##   必须查审计器或走真实点击）。
func _on_toggle_hour(_id: String, date: String) -> void:
	if _expanded_date == date:
		_expanded_date = ""
	else:
		_expanded_date = date
	# 整表重建（行数不多，且重建能保证「只开一天」不会漏掉旧的那天）
	_rebuild_week_list()


## 某个小时的一行：时刻 / 天气 / 温度 / 降水概率
func _hour_row(hv: Dictionary) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_theme_constant_override("separation", 6)
	var v := str(hv.get("valid", ""))
	# "2026-10-05T01" -> "01:00"
	var hhmm := "--:--"
	if v.length() >= 13:
		hhmm = v.substr(11, 2) + ":00"
	var temp := "--"
	var tv: Variant = hv.get("temp")
	if tv != null:
		temp = _num_text(tv) + "°"
	var precip := "--"
	var pv: Variant = hv.get("precip")
	if pv != null:
		precip = _num_text(pv) + "%"
	# ★ 列宽：小时行只 4 列（时刻 / 天气 / 温度 / 降水），总宽 118+100+92+92=402 必须 ≤ 逐日行的
	#   412（面板 WEATHER_W=500 时内容区 ~464，逐日行最小 460 恰好放下，见 WEATHER_W 注释）。
	#   超过逐日行总宽会让小时行把列表撑出横向裁切。
	var cols: Array = [["　" + hhmm, 118.0], [_cond_zh(str(hv.get("cap", ""))), 100.0], [temp, 92.0], [precip, 92.0]]
	for i in cols.size():
		var col: Array = cols[i]
		var l := _label(str(col[0]), float(col[1]))
		l.custom_minimum_size = Vector2(float(col[1]), 16.0)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.add_theme_font_size_override("font_size", SMALL_FONT)
		# 时刻/天气用弱化色，温度/降水（后两列）用主色 —— 一眼能扫到关键数字
		if i >= 3:
			l.add_theme_color_override("font_color", Color(0.78, 0.86, 0.95, 0.95))
		else:
			l.add_theme_color_override("font_color", Color(0.66, 0.72, 0.80, 0.85))
		h.add_child(l)
	return h


func _week_row(a: String, b: String, c: String, t: String, is_head: bool,
		date: String = "", can_expand: bool = false, expanded: bool = false) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_theme_constant_override("separation", 6)
	var cols: Array = [[a, 118.0], [b, 104.0], [c, 104.0], [t, 86.0]]
	for col in cols:
		var l := _label(str(col[0]), float(col[1]))
		l.custom_minimum_size = Vector2(float(col[1]), 16.0)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.add_theme_font_size_override("font_size", SMALL_FONT)
		if is_head:
			l.add_theme_color_override("font_color", Color(0.70, 0.80, 0.92, 0.9))
		h.add_child(l)
	# 行尾折叠按钮：▼ 展开中 / ▶ 已折叠；不支持逐小时的日子留空占位，保持列对齐
	var tail: Control
	if can_expand:
		var b2 := UIBtn.new()
		b2.name = "HourToggle"
		b2.set_id("hour_toggle")
		b2.set_label("▼" if expanded else "▶")
		b2.custom_minimum_size = Vector2(24.0, 16.0)
		b2.size = Vector2(24.0, 16.0)
		b2.pressed_id.connect(_on_toggle_hour.bind(date))
		tail = b2
	else:
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(24.0, 16.0)
		tail = spacer
	h.add_child(tail)
	return h


## 天气说法 → 中文（**仅显示用**；JSON 里保留 MSN 原文）。
## 未登记的说法按关键词粗分，认不出就原样显示（不编造）。
func _cond_zh(cap: String) -> String:
	var t := cap.strip_edges()
	if t.is_empty():
		return "--"
	if COND_ZH.has(t):
		return str(COND_ZH[t])
	var low := t.to_lower()
	if low.contains("thunder"):
		return "雷阵雨"
	if low.contains("snow") and low.contains("rain"):
		return "雨夹雪"
	if low.contains("snow"):
		return "雪"
	if low.contains("shower"):
		return "阵雨"
	if low.contains("rain") or low.contains("drizzle"):
		return "雨"
	if low.contains("fog"):
		return "雾"
	if low.contains("haz"):
		return "霾"
	if low.contains("cloud") or low.contains("overcast"):
		return "多云"
	if low.contains("sun") or low.contains("clear"):
		return "晴"
	return t


# ---------------- 复用的行零件 ----------------

# 文件分区：标题行（说明 + 文件夹选择按钮）+ 可滚动文件列表
func _build_file_section(title_text: String, hint_text: String, kind: String) -> Dictionary:
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 3)

	var head := HBoxContainer.new()
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_theme_constant_override("separation", 6)
	var t := _label(title_text, 0.0)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)

	var btn := FolderButton.new()
	btn.name = "Pick_%s" % kind
	btn.tooltip_text = "在资源管理器里选择文件"
	btn.custom_minimum_size = Vector2(ICON_BTN, ICON_BTN)
	btn.pressed.connect(_on_pick_files_pressed.bind(kind))
	head.add_child(btn)
	root.add_child(head)

	root.add_child(_hint(hint_text))

	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0.0, FILE_LIST_H)
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 2)
	sc.add_child(list)
	root.add_child(sc)

	return { "root": root, "btn": btn, "list": list }


func _build_footer() -> VBoxContainer:
	var foot := VBoxContainer.new()
	foot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_theme_constant_override("separation", 6)

	# 记录位置提示：让玩家知道设置被写在哪个文件里
	_path_hint = _hint("")
	_path_hint.name = "PathHint"
	_path_hint.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	foot.add_child(_path_hint)

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.alignment = BoxContainer.ALIGNMENT_END
	# 应用并关闭：把面板当前内容写进 JSON 再关（× 关闭则**不应用**，见 close_discard）
	_close_btn = UIBtn.new()
	_close_btn.set_id("api_config_close")
	_close_btn.set_label("应用并关闭")
	_close_btn.custom_minimum_size = Vector2(96.0, 32.0)
	_close_btn.pressed_id.connect(_on_close_pressed)
	row.add_child(_close_btn)
	foot.add_child(row)
	return foot


## 分隔线（与设置面板同款）
func _sep() -> HSeparator:
	var s := HSeparator.new()
	s.add_theme_color_override("separator", Color(0.35, 0.55, 0.7, 0.6))
	return s


func _label(text: String, min_w: float) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.clip_text = true
	if min_w > 0.0:
		l.custom_minimum_size = Vector2(min_w, ROW_H)
	_apply_font(l, 0)
	return l


func _hint(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", Color(0.82, 0.88, 0.94, 0.85))
	l.add_theme_font_size_override("font_size", SMALL_FONT)
	if is_instance_valid(UIStyle.get_cjk_font()):
		l.add_theme_font_override("font", UIStyle.get_cjk_font())
	return l


func _apply_font(l: Label, size_bonus: int) -> void:
	l.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	l.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + size_bonus)
	if is_instance_valid(UIStyle.get_cjk_font()):
		l.add_theme_font_override("font", UIStyle.get_cjk_font())


func _apply_edit_style(le: LineEdit) -> void:
	le.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(UIStyle.get_cjk_font()):
		le.add_theme_font_override("font", UIStyle.get_cjk_font())
	UIStyle.apply_line_edit_style(le)


func _panel_width() -> float:
	return WEATHER_W if config_kind == KIND_WEATHER else AI_W


func _panel_height() -> float:
	return WEATHER_H if config_kind == KIND_WEATHER else AI_H


# ==================== 打开 / 关闭 ====================

func open() -> void:
	_open = true
	visible = true
	if config_kind == KIND_WEATHER:
		_refresh_local_view()   # 面板关着时也可能整点采集过 → 打开即显示最新
	if not _ever_centered:
		_center()
		_ever_centered = true
	move_to_front()


func close() -> void:
	_save_state()          # 「应用并关闭」：先落盘再关
	_open = false
	visible = false
	if is_inside_tree() and get_viewport() != null:
		get_viewport().gui_release_focus()
	closed.emit()


## 公开 API：不应用本次改动直接关闭（× 按钮）。
## 面板上的编辑只在按「应用并关闭」时落盘 → 这里从磁盘重载，把未应用的编辑回滚掉。
func close_discard() -> void:
	_load_state()          # 字段恢复为磁盘上的值（撤销未应用的改动）
	_open = false
	visible = false
	if is_inside_tree() and get_viewport() != null:
		get_viewport().gui_release_focus()
	closed.emit()


func is_open() -> bool:
	return _open


## 「应用并关闭」按钮：保存 + 关闭
func _on_close_pressed(_id: String) -> void:
	close()


## × 按钮：放弃本次改动关闭（不落盘）
func _on_discard_pressed(_id: String) -> void:
	close_discard()


func _center() -> void:
	var vp := Vector2(1152.0, 648.0)
	if is_inside_tree() and get_viewport() != null:
		vp = UIStyle.canvas_viewport_size(self)
	size = Vector2(_panel_width(), _panel_height())
	position = (vp - size) / 2.0


# ==================== 交互：验证连通 ====================

func _on_verify_pressed(_id: String) -> void:
	var api := _api_edit.text.strip_edges() if _api_edit != null else ""
	if api.is_empty():
		_set_conn_state("未填写", Color(1.0, 0.86, 0.5))
		_notify("请先填写 API")
		return
	if _probe_api(api):
		_set_conn_state("已联通", Color(0.5, 1.0, 0.55))
		_notify("已联通")
	else:
		_set_conn_state("联通失败", Color(1.0, 0.55, 0.5))
		_notify("联通失败")


## 预留：真正的联通性探测（发一次 HTTP 请求 / 握手 / 鉴权校验）。
## ★ 现在还没做实际接入功能 → 固定返回 false，于是界面反馈「联通失败」。
##   将来把这里换成真实探测即可，外层 UI / 落盘逻辑都不用改。
func _probe_api(_api: String) -> bool:
	return false


func _set_conn_state(text: String, color: Color) -> void:
	if _conn_label == null:
		return
	_conn_label.text = text
	_conn_label.add_theme_color_override("font_color", color)


func _notify(text: String) -> void:
	if NotificationManager == null or not is_inside_tree() or get_tree() == null:
		return
	NotificationManager.show(text, [], 3.0)


# ==================== 交互：获取设备定位（仅天气面板） ====================

## 定位结果 JSON 的绝对路径（%文档%/HelloNyxel/settings/location.json）
func _location_json_path() -> String:
	if SaveManager == null:
		return ""
	return SaveManager.get_location_path()


## 命令行参数加引号（路径可能含空格）
func _q(path: String) -> String:
	return "\"%s\"" % path


func _set_locate_status(text: String, color: Color) -> void:
	if _locate_status == null:
		return
	_locate_status.text = text
	_locate_status.add_theme_color_override("font_color", color)


## 按下「获取设备定位」：起一个 PowerShell 子进程去采集（不阻塞主线程），
## 完成后由 _process 轮询产物文件 location.json 再回填。
func _on_locate_pressed(_id: String) -> void:
	if _locating:
		return
	if DisplayServer.get_name() == "headless":
		_set_locate_status("当前环境不支持定位（无头模式）", LOCATE_COLOR_WARN)
		_notify("当前环境不支持定位")
		return
	var out_path := _location_json_path()
	if out_path.is_empty():
		_set_locate_status("SaveManager 未就绪，无法定位", LOCATE_COLOR_WARN)
		return
	var script_path := ProjectSettings.globalize_path(LOCATION_SCRIPT)
	if not FileAccess.file_exists(script_path):
		_set_locate_status("找不到定位脚本：%s" % script_path, LOCATE_COLOR_WARN)
		return
	# ★ 先清掉上一轮产物：之后才能用「文件出现」判定本轮完成（脚本写 .tmp 再改名，故不会读到半截文件）
	#   先判存在再删：对不存在的路径调 remove_absolute 会往日志里打错误行。
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(out_path)
	if FileAccess.file_exists(out_path + ".tmp"):
		DirAccess.remove_absolute(out_path + ".tmp")
	var args := PackedStringArray([
		"-NoProfile", "-STA", "-ExecutionPolicy", "Bypass",
		"-File", _q(script_path),
		"-OutPath", _q(out_path),
	])
	_locate_pid = OS.create_process("powershell.exe", args, false)
	if _locate_pid <= 0:
		_locate_pid = 0
		_set_locate_status("启动定位进程失败（powershell.exe 不可用？）", LOCATE_COLOR_WARN)
		return
	_locating = true
	_locate_start_ms = Time.get_ticks_msec()
	_set_locate_status("获取中…（读取设备经纬度与 IP 定位，请稍候）", LOCATE_COLOR_PENDING)


func _process(_delta: float) -> void:
	if not _locating:
		return
	var out_path := _location_json_path()
	if out_path.is_empty():
		_finish_locate(false, "SaveManager 未就绪")
		return
	if FileAccess.file_exists(out_path):
		_apply_location_result(SaveManager.load_location_data())
		return
	if Time.get_ticks_msec() - _locate_start_ms > int(LOCATE_TIMEOUT_SEC * 1000.0):
		_finish_locate(false, "获取超时（%d 秒无结果）" % int(LOCATE_TIMEOUT_SEC))


## 读到的 location.json → 回填定位栏 + 落盘 weather.json。
## ★ 以 IP 定位（location_text）为准；IP 失败但拿到了设备经纬度时退化为「纬度,经度」。
func _apply_location_result(d: Dictionary) -> void:
	if _loc_edit == null:
		_finish_locate(false, "面板已失效")
		return
	var text := str(d.get("location_text", "")).strip_edges()
	var used := "ip"
	if text.is_empty():
		var dev: Variant = d.get("device", {})
		var lat: Variant = null
		var lon: Variant = null
		if dev is Dictionary and bool((dev as Dictionary).get("available", false)):
			lat = (dev as Dictionary).get("latitude")
			lon = (dev as Dictionary).get("longitude")
		if lat != null and lon != null:
			text = "%.4f,%.4f" % [float(lat), float(lon)]
			used = "device"
	if text.is_empty():
		var err := str(d.get("error", "")).strip_edges()
		_finish_locate(false, err if not err.is_empty() else "未取到定位")
		return
	_locate_pid = 0
	_locating = false
	_loc_edit.text = text
	_save_state()          # 定位栏内容 → weather.json
	var src := "IP 定位" if used == "ip" else "设备经纬度"
	var ip_obj: Variant = d.get("ip", {})
	var ip_src := ""
	if ip_obj is Dictionary:
		ip_src = str((ip_obj as Dictionary).get("source", ""))
	if not ip_src.is_empty():
		src = "%s / %s" % [src, ip_src]
	var dev_note := ""
	var dev2: Variant = d.get("device", {})
	if dev2 is Dictionary and bool((dev2 as Dictionary).get("available", false)):
		dev_note = "；已同时保存设备经纬度"
	_set_locate_status("已获取：%s（来源：%s%s）" % [text, src, dev_note], LOCATE_COLOR_OK)
	_notify("定位已获取：%s" % text)


func _finish_locate(ok: bool, reason: String) -> void:
	_locating = false
	_locate_pid = 0
	if not ok:
		_set_locate_status("获取失败：%s" % reason, LOCATE_COLOR_WARN)
		_notify("获取定位失败：%s" % reason)


func _exit_tree() -> void:
	# 面板被释放时若定位子进程还在跑 → 收掉，避免留一个孤儿 PowerShell。
	# ★ 先清 _locating 标志，避免 _process 在同一帧内又去读文件。
	if not _locating:
		return
	_locating = false
	var pid := _locate_pid
	_locate_pid = 0
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)


# ==================== 交互：个人信息文件 ====================

func _on_pick_files_pressed(kind: String) -> void:
	if DisplayServer.get_name() == "headless":
		_notify("当前环境不支持文件选择")
		return
	_dialog_target = kind
	if _file_dialog == null:
		_file_dialog = FileDialog.new()
		_file_dialog.name = "FilePicker"
		_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES   # 可多选
		_file_dialog.use_native_dialog = true                      # 用系统「资源管理器」样式
		_file_dialog.title = "选择个人信息文件"
		_file_dialog.filters = PackedStringArray(FILE_FILTERS)
		_file_dialog.files_selected.connect(_on_files_selected)
		add_child(_file_dialog)
	_file_dialog.popup_centered_ratio(0.65)


func _on_files_selected(paths: PackedStringArray) -> void:
	var kind := _dialog_target if not _dialog_target.is_empty() else "allow"
	for p in paths:
		add_personal_file(kind, str(p))


## 把某个文件加入「允许 / 拒绝 AI 读取」清单（已存在则忽略）→ 立即落盘。
func add_personal_file(kind: String, path: String) -> void:
	var p := path.strip_edges()
	if p.is_empty():
		return
	var arr: Array = _allow_files if kind == "allow" else _deny_files
	if arr.has(p):
		return
	arr.append(p)
	_rebuild_file_list(kind)
	_save_state()


func remove_personal_file(kind: String, path: String) -> void:
	var arr: Array = _allow_files if kind == "allow" else _deny_files
	var idx := arr.find(path)
	if idx == -1:
		return
	arr.remove_at(idx)
	_rebuild_file_list(kind)
	_save_state()


func get_personal_files(kind: String) -> Array:
	return _allow_files if kind == "allow" else _deny_files


func _on_remove_file_pressed(_id: String, kind: String, path: String) -> void:
	remove_personal_file(kind, path)


func _file_list_node(kind: String) -> VBoxContainer:
	return _allow_list if kind == "allow" else _deny_list


func _rebuild_file_list(kind: String) -> void:
	var box := _file_list_node(kind)
	if box == null:
		return
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	for p in get_personal_files(kind):
		box.add_child(_make_file_row(kind, str(p)))


func _make_file_row(kind: String, path: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 4)

	var lab := Label.new()
	lab.text = path
	lab.tooltip_text = path
	lab.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY   # 长路径自动折行（不做长文本按钮也能看全）
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lab.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	lab.add_theme_font_size_override("font_size", SMALL_FONT)
	if is_instance_valid(UIStyle.get_cjk_font()):
		lab.add_theme_font_override("font", UIStyle.get_cjk_font())
	row.add_child(lab)

	var rm := UIBtn.new()
	rm.set_id("api_config_rm_file")
	rm.set_label("×")
	rm.custom_minimum_size = Vector2(24.0, 24.0)
	rm.pressed_id.connect(_on_remove_file_pressed.bind(kind, path))
	row.add_child(rm)
	return row


# ==================== 持久化 ====================
# ★ 输入框不再"失焦/回车即保存"——面板编辑统一由底部「应用并关闭」落盘；
#   × 关闭 = 放弃改动（close_discard 从磁盘回滚字段）。
#   （程序性写入仍即时落盘：定位流程 / 文件列表增删 / 来源切换 / 开关切换。）


## 收集当前面板内容 → 写进 settings 目录下对应的 JSON（ai.json / weather.json）。
func _save_state() -> void:
	if _loading or SaveManager == null:
		return
	if config_kind == KIND_WEATHER:
		# ★ 开关一起写：_save_state 是「整份重写」，漏了就会把开关状态抹掉
		# ★ local_weather_source 也要带上：否则「整份重写」会把 set_selected_source 写进去的
		#   采用来源清空（save_weather_config 是全量覆盖，不是合并写）。
		SaveManager.save_weather_config({
			"location": _loc_edit.text if _loc_edit != null else "",
			"api": _weather_api_edit.text if _weather_api_edit != null else "",
			"read_local_weather": _local_check.button_pressed if _local_check != null else false,
			"local_weather_source": LocalWeather.selected_source() if LocalWeather != null else "",
		})
	else:
		SaveManager.save_ai_config({
			"api": _api_edit.text if _api_edit != null else "",
			"prompt": _prompt_edit.text if _prompt_edit != null else "",
			"allow_files": _allow_files.duplicate(),
			"deny_files": _deny_files.duplicate(),
		})
	_refresh_path_hint()


## 启动时按 config_kind 从对应 JSON 读回（文件缺失 / 键缺失 → 保留空值）。
func _load_state() -> void:
	_loading = true
	var d: Dictionary = {}
	if SaveManager != null:
		d = SaveManager.load_weather_config() if config_kind == KIND_WEATHER else SaveManager.load_ai_config()
	if config_kind == KIND_WEATHER:
		if _loc_edit != null:
			_loc_edit.text = str(d.get("location", ""))
		if _weather_api_edit != null:
			_weather_api_edit.text = str(d.get("api", ""))
		# 「读取本机天气」开关：用 no_signal 设置（载入不是玩家操作 → 不触发采集）
		if _local_check != null and is_instance_valid(_local_check):
			_local_check.set_pressed_no_signal(bool(d.get("read_local_weather", false)))
			_apply_manual_enabled(not _local_check.button_pressed)
	else:
		if _api_edit != null:
			_api_edit.text = str(d.get("api", ""))
		if _prompt_edit != null:
			_prompt_edit.text = str(d.get("prompt", ""))
		_allow_files.clear()
		_deny_files.clear()
		var allow: Variant = d.get("allow_files", [])
		if allow is Array:
			for p in allow:
				_allow_files.append(str(p))
		var deny: Variant = d.get("deny_files", [])
		if deny is Array:
			for p in deny:
				_deny_files.append(str(p))
		_rebuild_file_list("allow")
		_rebuild_file_list("deny")
	_loading = false
	_refresh_path_hint()


## 这份设置对应的 JSON 文件绝对路径（ai.json / weather.json）
func config_path() -> String:
	if SaveManager == null:
		return ""
	return SaveManager.get_weather_config_path() if config_kind == KIND_WEATHER else SaveManager.get_ai_config_path()


## 首次启动（或文件被删）时把默认结构落盘 —— 让玩家能立刻在 settings 目录里看到这份文件。
## 文件已存在则绝不动它（不覆盖玩家手改过的内容）。
func _ensure_config_file() -> void:
	var p := config_path()
	if p.is_empty() or FileAccess.file_exists(p):
		return
	_save_state()


## 底部提示：这份设置记录在哪个文件里（玩家可直接去查看内容）
func _refresh_path_hint() -> void:
	if _path_hint == null:
		return
	var p := config_path()
	_path_hint.text = "设置记录文件：%s" % (p if not p.is_empty() else "（SaveManager 未就绪）")


## 最小化 / 还原：本页顶栏是 HBox 容器 → 折叠隐藏顶栏的兄弟节点，
## 顶栏本身（标题 / 把柄 / 最小化 / × 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.apply(self, _min_btn, v, _min_btn.get_parent() if is_instance_valid(_min_btn) else null)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
