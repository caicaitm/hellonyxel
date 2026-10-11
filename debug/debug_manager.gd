# 调试面板管理器（全局单例）。
#
# ★ 访问方式：本脚本是名为 `Debug` 的 autoload 单例（见 project.godot 的 [autoload]）。
#   所有外部访问都用 `Debug.xxx`，例如：
#       Debug.debug_mode = true
#       Debug.field_value_requested.emit("line_text", "新台词")
#
# ★ 注意（踩过的坑）：本脚本 **故意不写 class_name**。
#   若写了 `class_name DebugManager`，GDScript 会把裸名 `DebugManager` 解析成「类类型」，
#   于是 `DebugManager.debug_mode` 会报 Parse Error: Cannot find member "debug_mode" in base "DebugManager"。
#   这与 dialogue_manager.gd 里 DialogueManager 的情况同理（那边是靠 autoload 名与裸名一致来避免）。
#
# 提供全局变量「debug_mode」用来控制和判断当前是否处于调试模式；
# 按 ~ 键（KEY_QUOTELEFT）切换；调试模式开启时显示调试面板。
#
# v3：调试面板在原有系统信息之外增加
#   - 底部/弹窗对话面板的显隐开关按钮（操作 DialogueManager.bottom_visible / popup_visible）
#   - 8 个栏变量 + 冒泡预留变量的输入框
# v4：每个输入框行尾加「修改」按钮 —— 只有按下它才发 field_value_requested 信号写值，
#     去掉回车/失焦自动提交（隐式同步既费性能又难追踪）；事件链脚本可 emit 同一信号。
# v5：信息栏去掉「性能: CPU/内存/显存」那一行，改为显示**忙闲状态**
#     （读 BusyState 单例：在忙/空闲 + 来源「定时时段/手动切换/分数自动」）。
#     性能数值仍可在「性能忙闲判断」面板里看，不再挤占调试面板信息栏。
# v6：移除面板上的两个区块入口按钮 ——「性能忙闲判断」与「暗网入口」。
#     · 性能忙闲判断面板改由**系统托盘右键菜单**打开
#       （TrayRunner.perf_busy_requested → desktop._open_perf_busy → Debug._toggle_perf_busy；
#        本页 _toggle_perf_busy / _on_perf_busy_closed 仍保留，面板实现 ui/perf_busy_panel.gd 不变）。
#     · 暗网入口页改由桌面上的**「虚视跳转器」双击**打开（desktop.gd::_open_darknet_entry）。
extends Node

# 显式 preload 时间轴调试面板脚本（避免依赖全局类缓存对新类的即时扫描）
const TimelineDebugPanelScript := preload("res://ui/timeline_debug_panel.gd")
# 显式 preload 控制台面板脚本（统一命令语言交互入口）
const ConsolePanelScript := preload("res://ui/console_panel.gd")
# 显式 preload 性能忙闲判断面板脚本（加权分数判断玩家是否在忙）
const PerfBusyPanelScript := preload("res://ui/perf_busy_panel.gd")
# 显式 preload 对话调试面板脚本（底部/弹窗/冒泡对话 + 对话变量 + 右下角提醒）
const DialogueDebugPanelScript := preload("res://debug/dialogue_debug_panel.gd")
# 显式 preload 自测量面板脚本（批次 1：帧率/渲染/物理/进程树 + 子系统每帧耗时 + 快照导出）
const SelfProfilePanelScript := preload("res://ui/self_profile_panel.gd")
# 显式 preload 状态页查看器脚本（批次 47：读取 %文档%/HelloNyxel/Temp/<文件>.json 并展示）
const StateViewPanelScript := preload("res://ui/state_view_panel.gd")

# 状态页表（批次 47 / 48）：key / 标题 / Temp 目录下的 json 文件名 / 可选的自定义面板脚本。
# ★ 这些状态系统大多尚未开发 → 文件不存在属正常，页面仍需能正常打开（显示占位提示 + 预期路径）。
# ★ 文件名一旦约定，后续系统落盘即按此命名（改这里即可整体改名）。
# ★ 可选键 "panel"：给出该页专用的查看器脚本（须与 StateViewPanel 同契约：
#   configure(title, file) / closed 信号 / close()）；不写则用通用 JSON 查看器。
const STATE_VIEWS: Array = [
	{"key": "player_profile", "title": "玩家画像", "file": "player_profile.json",
		"panel": "res://ui/player_profile_panel.gd"},
	{"key": "nyxel_story_state", "title": "荧惑剧情状态", "file": "nyxel_story_state.json"},
	{"key": "nyxel_daily_state", "title": "荧惑日常状态", "file": "nyxel_daily_state.json",
		"panel": "res://ui/nyxel_daily_state_panel.gd"},
	{"key": "world_state", "title": "世界状态", "file": "world_state.json"},
	{"key": "story_state", "title": "剧情状态", "file": "story_state.json"},
]
# 状态页承载层起始索引（136 已被自测量面板占用；5 个状态页各占一层，可同时打开）。
const STATE_VIEW_LAYER_BASE: int = 137
# 状态页按钮 id 前缀（_on_toggle_pressed 里按前缀路由到 _toggle_state_view）
const STATE_VIEW_ID_PREFIX: String = "state:"

# 内部存储（避免在属性 setter 内递归赋值同名属性）
var _debug_mode: bool = false

# 全局开关：是否处于调试模式（外部可读写：Debug.debug_mode = true / if Debug.debug_mode）
var debug_mode: bool:
	get:
		return _debug_mode
	set(v):
		_debug_mode = v
		mode_changed.emit(v)

# 调试模式变化信号（开 / 关）
signal mode_changed(on: bool)

# 调试开关：是否强制显示所有积木的边框（用于排查布局；即便积木自身无 border 标签也画一圈高亮边框）
# ★ 默认关闭：启动时不额外画边框，各积木按自身 border 标签渲染；需要排查布局时在调试面板开启。
var _force_border: bool = false
var _border_overlay: Node2D = null   # 全局顶层边框覆盖层（强制显示时挂到当前场景）
var force_border: bool:
	get:
		return _force_border
	set(v):
		if _force_border == v:
			return
		_force_border = v
		force_border_changed.emit(v)
		_ensure_border_overlay()
		if _border_overlay != null and is_instance_valid(_border_overlay):
			_border_overlay.visible = v
			if v:
				_border_overlay.queue_redraw()

# 强制边框开关变化信号
signal force_border_changed(on: bool)

# ★ 栏位写值请求（统一入口）
# 设计：调试面板的输入框 **不再** 回车/失焦即写回（隐式同步既费性能又难追踪），
# 只有按下该行右侧的「修改」按钮才会发出本信号，由内部处理函数真正写入 DialogueManager。
# 未来事件链脚本可以 **直接 emit 本信号** 来修改这 8 个栏位 + 冒泡预留字段，
# 与手动点「修改」等价 —— 这就是「事件链发信号改栏位」的接口：
#     Debug.field_value_requested.emit("line_text", "新的台词")
#     Debug.field_value_requested.emit("bottom_buttons", [{"label": "继续", "id": "go"}])
signal field_value_requested(var_name: String, value: Variant)

# 面板布局常量（自 abandon 版调试面板标题栏迁移）
const PANEL_POS: Vector2 = Vector2(12, 12)
# 宽度：每个输入框行现在是「标签 + 输入框 + [长文本] + 修改」四段；
# 460 保证输入框有可用宽度且不挤出横向滚动条（ID 下拉项文本较长，已用 fit_to_longest_item=false 约束）。
const PANEL_W: float = 460.0
# 面板加高到能装下全部内容（系统信息 + 开关 + 8 栏 + 冒泡对话区块的 选择ID/输入ID/状态/冒泡文本 四行）。
# 内容最小高度约 728px；视口 = PANEL_H - 标题栏 - 内边距，故取 800 让「冒泡对话」区块（含
# 输入ID / 定位状态 / 冒泡文本）直接可见、无需滚动到底才能找到（避免被误认为"输入框丢失"）。
const PANEL_H: float = 800.0
const TITLE_BAR_H: float = 28.0   # 标题栏高度（与最小化按钮同高）
# 「退出调试」按钮宽度 + 与最小化按钮的间距（标题栏右上角横向排列：退出调试 | − 最小化）
const EXIT_BTN_W: float = 64.0
const TITLE_BTN_GAP: float = 4.0

var _panel: CanvasLayer
var _bg: UIPanel
var _title_label: Label
var _min_btn: UIBtn
var _exit_btn: UIBtn
var _content: ScrollContainer
var _info_label: Label          # 系统信息（分辨率/语言/时区），每帧刷新
var _minimized: bool = false

# 对话调试控件引用
var _toggle_html_poll: UIBtn     # HTML 命令轮询开关


# 系统开关控件引用（全局环境行为：桌面穿透 / 窗口置顶）
var _toggle_passthrough: UIBtn
var _toggle_topmost: UIBtn
var _toggle_force_border: UIBtn   # 强制显示积木边框开关
var _toggle_level_page: UIBtn     # 关卡页面开关
var _event_editor: EventChainEditorPanel = null   # 事件链编辑器（独立层）
var _timeline_panel: Control = null               # 时间轴调试面板（独立层）
var _console_panel: Control = null                # 控制台面板（独立层）
var _perf_busy_panel: Control = null              # 性能忙闲判断面板（独立层）
var _dialogue_panel: DialogueDebugPanel = null    # 对话调试面板（独立层；含底部/弹窗/冒泡对话 + 右下角提醒）
var _self_profile_panel: Control = null           # 自测量面板（独立层 136；默认关闭 = 零开销）
var _state_panels: Dictionary = {}                # 状态页（批次 47）：key -> StateViewPanel（各自的独立层）


# 系统信息刷新节流：原实现每帧调用 DisplayServer/Time 并重建字符串，属无谓开销。
# 改为 0.5s 一次；面板关闭时直接 set_process(false)，完全不跑。
const INFO_REFRESH_INTERVAL: float = 0.5
var _info_timer: float = 0.0

# 鼠标坐标行的刷新间隔（10Hz）。
# ★ 为什么不用 DisplayServer.mouse_get_position() 每帧读：
#   它是一个**系统调用**，每帧调用（60+fps）纯属浪费；而"位置"人眼 10Hz 已完全够看。
# ★ 为什么也不用 Input.get_last_mouse_velocity() 自适应：
#   快速划动时会把频率推回每帧（等于没省）、边界噪声又让它频繁切档，收益不确定 →
#   直接定 0.1s（用户指定区间"0.1s ~ 不能太低、别挤占性能"的中间值），实现更简单可预期。
const MOUSE_REFRESH_INTERVAL: float = 0.1
var _mouse_timer: float = 0.0
var _mouse_label: Label = null      # 鼠标坐标行（独立 Label，10Hz 刷新，与 0.5s 的系统信息行分开）

# ★★ 鼠标坐标显示开关：**默认关闭**。
#   理由 = 省性能：关闭时连 DisplayServer.mouse_get_position()（系统调用）都不调、
#   连计时器都不走，等于零开销。打开后按 MOUSE_REFRESH_INTERVAL（10Hz）刷新。
#   ★ 这是"运行时开关"，不落盘（调试面板的开关一向如此，重启即回默认值）。
var _mouse_track_enabled: bool = false
var _toggle_mouse_coords: UIBtn = null

# ★ 为什么单独一行 Label 而不是塞进 _collect()：
#   系统信息（分辨率/语言/时区/置顶/穿透/忙闲）都是**低频**量，0.5s 刷新已足够；
#   鼠标坐标要 10Hz —— 若混在一起，等于把 DisplayServer/Time/BusyState 整套系统调用也提到 10Hz。
#   拆开后：低频的照旧 0.5s，高频的只有一行字符串拼接。
# ★ 取坐标用 DisplayServer.mouse_get_position()（= 真实屏幕像素），**不是** get_global_mouse_position()：
#   后者含 CanvasLayer 的 UI 缩放（见 MEMORY <UI 缩放/坐标空间>），拿到的是画布坐标，不是屏坐标。



func _ready() -> void:
	_build_panel()
	# 调试模式切换时同步面板显隐（否则按 ~ 后面板仍不可见）
	mode_changed.connect(_on_mode_changed)
	# ★ 栏位写值信号 → 真正写入（按钮与事件链共用这一条路径）
	field_value_requested.connect(_on_field_value_requested)
	# 全局变量变化时同步调试输入框（仅作「显示当前值」，不代表用户已修改）
	DialogueManager.variable_changed.connect(_on_dialogue_var_changed)
	DialogueManager.panel_visibility_changed.connect(_on_dialogue_vis_changed)
	# HTML 命令轮询状态变化（含 JSON 命令里 set_poll 触发的）→ 同步按钮文案
	if HtmlBridge != null and HtmlBridge.has_signal("poll_state_changed"):
		HtmlBridge.poll_state_changed.connect(_refresh_toggle_labels)
	# 系统开关状态变化 → 刷新按钮上的开启/关闭文案
	MousePassRunner.enabled_changed.connect(_on_system_state_changed)
	DesktopShell.always_on_top_changed.connect(_on_system_state_changed)
	# 强制边框：默认关闭（此处仅为「上次开启过」的兜底），场景就绪后挂上全局覆盖层（current_scene 此时才可用，故 defer）
	if _force_border:
		call_deferred("_ensure_border_overlay")
	set_process(_debug_mode)


# 建一个「承载面板」的 CanvasLayer：按设置里的 UI 缩放施加缩放并订阅变化。
# ★ 统一走这里，避免每个开关各自 new 之后忘记接缩放（漏一个就是「这个面板不跟着缩放」）。
func _make_layer(layer_index: int) -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.layer = layer_index
	add_child(layer)
	UIStyle.watch_ui_scale(layer)
	return layer


# 用代码构建最上层 CanvasLayer 调试面板，统一旧版 UI 风格（天蓝半透明 + 荧光蓝边框）
# 结构：标题栏（标题 + − 最小化） + 滚动内容区（系统信息 + 对话调试控件）
func _build_panel() -> void:
	_panel = _make_layer(128)
	_bg = UIPanel.new()
	_bg.position = PANEL_POS
	_bg.size = Vector2(PANEL_W, PANEL_H)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	_panel.add_child(_bg)
	var cjk_font := UIStyle.get_cjk_font()

	# 标题栏
	_title_label = Label.new()
	_title_label.text = "调试面板"
	_title_label.position = Vector2(UIStyle.PANEL_PADDING + 2.0, UIStyle.PANEL_PADDING)
	_title_label.size = Vector2(PANEL_W - (TITLE_BAR_H + TITLE_BTN_GAP + EXIT_BTN_W + TITLE_BTN_GAP)
		- UIStyle.PANEL_PADDING * 2.0, TITLE_BAR_H)
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_title_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(cjk_font):
		_title_label.add_theme_font_override("font", cjk_font)
	_bg.add_child(_title_label)

	# 最小化按钮（标题栏右上；− 最小化 / □ 还原）
	_min_btn = UIBtn.new()
	_min_btn.set_id("debug_minimize")
	_min_btn.set_label("−")
	_min_btn.custom_minimum_size = Vector2(TITLE_BAR_H, TITLE_BAR_H)
	_min_btn.size = Vector2(TITLE_BAR_H, TITLE_BAR_H)
	_min_btn.position = Vector2(PANEL_W - TITLE_BAR_H - UIStyle.PANEL_PADDING, UIStyle.PANEL_PADDING)
	_min_btn.pressed_id.connect(_on_min_btn_pressed)
	_bg.add_child(_min_btn)

	# 「退出调试」按钮（标题栏右上，**最小化按钮左侧**）。
	# 语义 = 关掉调试模式：mode_changed → _on_mode_changed(false) 会隐藏本面板并连带
	# 关掉对话调试 / 自测量等子面板（它们挂在独立 CanvasLayer，不受本面板显隐影响）。
	# 此前只能按 ~ 或走托盘右键菜单才能退出。
	_exit_btn = UIBtn.new()
	_exit_btn.set_id("debug_exit")
	_exit_btn.set_label(TranslationManager.t("退出调试"))
	_exit_btn.tooltip_text = TranslationManager.t("退出调试模式")
	_exit_btn.custom_minimum_size = Vector2(EXIT_BTN_W, TITLE_BAR_H)
	_exit_btn.size = Vector2(EXIT_BTN_W, TITLE_BAR_H)
	_exit_btn.position = Vector2(_min_btn.position.x - TITLE_BTN_GAP - EXIT_BTN_W, UIStyle.PANEL_PADDING)
	_exit_btn.pressed_id.connect(_on_exit_btn_pressed)
	_bg.add_child(_exit_btn)

	# 滚动内容区
	_content = ScrollContainer.new()
	_content.position = Vector2(0.0, TITLE_BAR_H + UIStyle.PANEL_PADDING)
	_content.size = Vector2(PANEL_W, PANEL_H - TITLE_BAR_H - UIStyle.PANEL_PADDING * 2.0)
	_content.mouse_filter = Control.MOUSE_FILTER_STOP
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 4)
	_content.add_child(vbox)
	_bg.add_child(_content)

	# 系统信息
	_info_label = Label.new()
	_info_label.clip_text = true   # 信息文本较长时不顶宽、不触发横向滚动条
	_info_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_info_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(cjk_font):
		_info_label.add_theme_font_override("font", cjk_font)
	vbox.add_child(_info_label)

	# 鼠标坐标（独立一行，10Hz 刷新；与上面 0.5s 的系统信息分开，理由见 MOUSE_REFRESH_INTERVAL）
	_mouse_label = Label.new()
	_mouse_label.clip_text = true
	_mouse_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_mouse_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(cjk_font):
		_mouse_label.add_theme_font_override("font", cjk_font)
	vbox.add_child(_mouse_label)

	# 鼠标坐标显示开关（默认关闭 → 省性能；放在坐标行正下方，就近控制）
	_toggle_mouse_coords = _make_toggle("toggle_mouse_coords", "鼠标坐标显示")
	vbox.add_child(_toggle_mouse_coords)

	# 分隔
	vbox.add_child(_sep())

	# 系统开关 区块（全局环境行为）
	_toggle_passthrough = _make_toggle("toggle_passthrough", "桌面穿透")
	vbox.add_child(_toggle_passthrough)
	_toggle_topmost = _make_toggle("toggle_topmost", "窗口置顶")
	vbox.add_child(_toggle_topmost)

	# 强制显示积木边框（调试用：即便积木无 border 标签也画一圈高亮边框，便于排查布局）
	_toggle_force_border = _make_toggle("toggle_force_border", "强制显示边框")
	vbox.add_child(_toggle_force_border)

	vbox.add_child(_sep())

	# 关卡页面 区块（开关的预留入口：未来其它方式可同样调用 desktop.toggle_level_page）
	_toggle_level_page = _make_toggle("toggle_level_page", "关卡页面")
	vbox.add_child(_toggle_level_page)

	# ★ 「关卡摄像头锚定的目标」输入行已**迁移到关卡页面的关卡配置面板**
	#   （blocks/level_page.gd::_build_cam_row / _on_cam_apply）—— 关卡的事归关卡页面管，
	#   这里不再重复提供入口。

	vbox.add_child(_sep())

	# 事件链编辑器 区块：点开可视化编辑事件脚本（事件链名/事件名/关闭/正文/按钮/打开）
	var ev_btn := _make_toggle("event_editor", "事件链编辑器")
	vbox.add_child(ev_btn)

	vbox.add_child(_sep())

	# 时间轴（计划）调试 区块：检查周期 / 计划列表 / 立即检查
	var tl_btn := _make_toggle("timeline_debug", "时间轴调试")
	vbox.add_child(tl_btn)

	vbox.add_child(_sep())

	# 控制台 区块：统一命令语言交互入口（/create_block、/set_var …）
	var cc_btn := _make_toggle("console", "控制台")
	vbox.add_child(cc_btn)

	# HTML 命令轮询 区块：开启后游戏轮询 Temp 目录的标志文件并执行 HTML 下发的命令
	_toggle_html_poll = _make_toggle("html_poll", "HTML命令轮询")
	vbox.add_child(_toggle_html_poll)

	vbox.add_child(_sep())

	# 对话调试 区块：底部/弹窗/冒泡对话面板开关 + 8 个对话变量 + 冒泡文本 + 右下角提醒，
	# 已全部拆到独立页面 DialogueDebugPanel（避免主调试面板臃肿），此处只留一个开关按钮。
	vbox.add_child(_make_toggle("dialogue_panel", "对话调试面板"))

	# 自测量 区块（批次 1）：帧率/帧时间/渲染与物理计数/本进程树内存/子系统每帧耗时 + 快照导出。
	# ★ 默认关闭 —— 面板不开时所有计时闸门为 false，连一次时钟读取都不发（零开销）。
	vbox.add_child(_make_toggle("self_profile", "自测量面板"))

	vbox.add_child(_sep())

	# 状态页 区块（批次 47）：打开后读取 %文档%/HelloNyxel/Temp/<文件>.json 并展示。
	# ★ 这些状态大多尚未开发 —— 打开即见占位提示与预期路径（"能打开页面就行"）。
	var st_head := Label.new()
	st_head.text = "状态页面"
	st_head.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	st_head.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(cjk_font):
		st_head.add_theme_font_override("font", cjk_font)
	vbox.add_child(st_head)
	for sv in STATE_VIEWS:
		var sv_btn := _make_toggle(STATE_VIEW_ID_PREFIX + str(sv["key"]), str(sv["title"]))
		vbox.add_child(sv_btn)

	_panel.visible = _debug_mode
	_refresh_toggle_labels()


# 分隔线
func _sep() -> HSeparator:
	var s := HSeparator.new()
	s.add_theme_constant_override("separation", 2)
	return s


# 显隐开关按钮
# 宽度用 SIZE_EXPAND_FILL 交给容器算，不要写死 PANEL_W - padding
# （写死会略超 ScrollContainer 的可用宽度，触发没必要的横向滚动条）
func _make_toggle(id: String, label: String) -> UIBtn:
	var btn := UIBtn.new()
	btn.set_id(id)
	btn.set_label(label)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size = Vector2(0.0, UIStyle.BTN_HEIGHT)
	btn.pressed_id.connect(_on_toggle_pressed)
	return btn


# ★ 「关卡摄像头锚定的目标」输入行 + 「确定」按钮已**迁移到关卡页面的关卡配置面板**
#   （blocks/level_page.gd::_build_cam_row / _on_cam_apply）—— 关卡的事归关卡页面管，
#   这里不再重复提供一个入口，避免两处控件互相打架。


# ~ 键切换调试模式（物理按键 ` 的 keycode 为 KEY_QUOTELEFT，按 Shift 即 ~）。
# ★ 用 _input 而非 _unhandled_input：_unhandled_input 只在「GUI 未消费」时触发，
#   一旦调试面板里任意输入框（LineEdit/TextEdit）持有键盘焦点，~ 会被当成文本输入吃掉，
#   再也关不掉调试模式（即"按 ~ 打开后再次按无法退出"的根因）。_input 在 GUI 之前触发，
#   拦截后 set_input_as_handled()，保证 ~ 恒能开关，与焦点状态无关。
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_QUOTELEFT:
			debug_mode = not debug_mode
			get_viewport().set_input_as_handled()


func _process(dt: float) -> void:
	if not _debug_mode:
		return
	if _info_label == null or _minimized:
		return
	# 鼠标坐标行：默认关闭 → 关闭时**连计时器都不走、连系统调用都不发**（零开销）。
	# 开启后按 10Hz 刷新（与系统信息行分开节流，理由见 MOUSE_REFRESH_INTERVAL 上方注释）。
	if _mouse_track_enabled and _mouse_label != null:
		_mouse_timer -= dt
		if _mouse_timer <= 0.0:
			_mouse_timer = MOUSE_REFRESH_INTERVAL
			_mouse_label.text = _mouse_coords_line()
	# 系统信息行：0.5Hz
	_info_timer -= dt
	if _info_timer > 0.0:
		return
	_info_timer = INFO_REFRESH_INTERVAL
	_info_label.text = _collect()


# 鼠标坐标行（10Hz）。用 DisplayServer.mouse_get_position() = 真实屏幕像素。
# ★ headless 下 DisplayServer 没有真实鼠标 → 明确标注，避免"读到 (0,0) 以为是 bug"。
func _mouse_coords_line() -> String:
	if DisplayServer.get_name() == "headless":
		return "鼠标: 无（headless 无真实光标）"
	var p := DisplayServer.mouse_get_position()
	var win_ul := DisplayServer.window_get_position()          # 游戏窗口左上角（屏幕坐标）
	var win_sz := DisplayServer.window_get_size()
	return "鼠标: (%d, %d)  窗口内: (%d, %d)  窗口 %d×%d @ (%d, %d)" % [
		p.x, p.y, p.x - win_ul.x, p.y - win_ul.y,
		win_sz.x, win_sz.y, win_ul.x, win_ul.y]


# 鼠标坐标显示开关：关闭时不刷新（并清掉旧文本，避免残留一个"过时坐标"误导人）。
func _set_mouse_track_enabled(on: bool) -> void:
	_mouse_track_enabled = on
	if _mouse_label != null and is_instance_valid(_mouse_label):
		if on:
			# 打开就立刻显示一次，不等 0.1s（避免"开了却还是空白"的观感）
			_mouse_label.text = _mouse_coords_line()
		else:
			_mouse_label.text = "鼠标: 显示已关闭"
	_mouse_timer = 0.0
	_refresh_toggle_labels()


# 公开 API：当前是否在跟踪鼠标坐标（探针 / 事件链可用）
func is_mouse_track_enabled() -> bool:
	return _mouse_track_enabled


func _collect() -> String:
	var sz := DisplayServer.screen_get_size(0)
	var lang := OS.get_locale()
	# 返回 Dictionary，键为 name(String) 与 bias(int，相对 UTC 的分钟偏移，例如中国=+480)
	var tz := Time.get_time_zone_from_system()
	var bias: int = int(tz.bias)
	var oh: int = bias / 60
	var om: int = abs(bias) % 60
	var offset_str := "UTC%+d:%02d" % [oh, om]
	# 原生置顶的真实落盘状态（WS_EX_TOPMOST 是否在位）
	var top := "开" if DesktopShell.is_always_on_top() else "关"
	top += "（原生%s）" % ("OK" if DesktopShell.is_topmost_verified() else "校验中/失败")
	var pass_desktop := "开" if MousePassRunner.is_enabled() else "关"
	# 忙闲状态（BusyState 单例 = 唯一权威；来源字符串见 busy_state.gd 的 SOURCE_*）
	var busy_line := _busy_line()
	return "调试模式 ON\n分辨率: %d x %d\n语言: %s\n时区: %s (%s)\n置顶: %s\n穿透: %s\n%s" % [
		sz.x, sz.y, lang, tz.name, offset_str, top, pass_desktop, busy_line]


# 忙闲状态行：在忙 / 空闲（附来源，便于排查「为什么现在是在忙」）
func _busy_line() -> String:
	if BusyState == null or not BusyState.has_method("is_busy"):
		return "忙闲: 不可用"
	var state := "在忙" if BusyState.is_busy() else "空闲"
	var tag := "分数自动"                          # SOURCE_AUTO
	match str(BusyState.state_source()):
		"schedule":                                # SOURCE_SCHEDULE
			tag = "定时时段"
		"manual":                                  # SOURCE_MANUAL
			tag = "手动切换"
	if tag == "手动切换" and BusyState.has_method("is_manual_locked") and BusyState.is_manual_locked():
		tag = "手动切换·本时段已锁定"
	return "忙闲: %s（%s）" % [state, tag]


# 最小化按钮回调
func _on_min_btn_pressed(_id: String) -> void:
	set_minimized(not _minimized)


# 「退出调试」按钮回调：关掉调试模式（面板随之关闭，各调试子页面也一并收掉）
func _on_exit_btn_pressed(_id: String) -> void:
	debug_mode = false


# 公开 API：最小化（仅保留标题栏）/ 还原调试面板
func set_minimized(v: bool) -> void:
	_minimized = v
	if _bg == null or _content == null or _min_btn == null:
		return
	_content.visible = not _minimized
	_min_btn.set_label("□" if _minimized else "−")
	var h: float = TITLE_BAR_H + UIStyle.PANEL_PADDING * 2.0
	if not _minimized:
		h = PANEL_H
		# 还原后立刻刷一次（最小化期间 _process 早退）
		_info_timer = 0.0
		_mouse_timer = 0.0
	_bg.size = Vector2(PANEL_W, h)


# 公开 API：当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized


# 调试模式变化回调：同步面板的显隐，并按需开关每帧处理
func _on_mode_changed(on: bool) -> void:
	if _panel != null:
		_panel.visible = on
	# 面板关闭时完全不跑 _process（系统信息无需刷新）
	set_process(on)
	if on:
		_info_timer = 0.0
		# 进入调试模式时积木已就绪：若对话调试页面开着，刷新其「选择ID」下拉
		if _dialogue_panel != null and is_instance_valid(_dialogue_panel):
			_dialogue_panel._refresh_id_list()
	else:
		# ★ 退出调试模式：**连带关掉「对话调试面板」**。
		#   它挂在独立的 CanvasLayer(135) 上，不受 `_panel.visible` 影响（旧实现下它会继续
		#   留在屏幕上，且每帧重建「选择ID」列表 = 非调试模式还在干活）。
		#   用户要求：「调试面板里，罗列积木ID 的窗口，在不打开调试模式下也要停止」。
		#   close() 会发 closed → _on_dialogue_panel_closed 释放承载层并置 null。
		if _dialogue_panel != null and is_instance_valid(_dialogue_panel):
			_dialogue_panel.close()
			_dialogue_panel = null
		# ★ 同理关掉「自测量面板」：它挂在独立层(136)，且开着就会一直计时
		#   （PerfMonitor/Block 的闸门）。退出调试模式必须让闸门回到 false，否则
		#   非调试模式仍在采样 —— 与用户「不打开调试模式就停止」的要求一致。
		if _self_profile_panel != null and is_instance_valid(_self_profile_panel):
			_self_profile_panel.close()
			_self_profile_panel = null
		# ★ 同理关掉所有「状态页」（批次 47）：各自挂在独立层(137+)，不关会留在屏幕上。
		#   注意：close() 会发 closed → _on_state_view_closed 顺手 erase，故这里先取 keys() 快照
		#   （Godot 的 Dictionary.keys() 返回新数组，迭代安全）。
		for k in _state_panels.keys():
			var sp: Control = _state_panels[k]
			if sp != null and is_instance_valid(sp):
				sp.close()
		_state_panels.clear()


# 显隐开关按下
func _on_toggle_pressed(id: String) -> void:
	match id:
		"toggle_passthrough":
			MousePassRunner.set_enabled(not MousePassRunner.is_enabled())
		"toggle_topmost":
			DesktopShell.set_always_on_top(not DesktopShell.is_always_on_top())
		"toggle_force_border":
			force_border = not force_border
		"toggle_mouse_coords":
			_set_mouse_track_enabled(not _mouse_track_enabled)
		"toggle_level_page":
			_toggle_level_page_pressed()
		"event_editor":
			_toggle_event_editor()
		"timeline_debug":
			_toggle_timeline_debug()
		"console":
			_toggle_console()
		"dialogue_panel":
			_toggle_dialogue_panel()
		"self_profile":
			_toggle_self_profile()
		"html_poll":
			HtmlBridge.set_polling(not HtmlBridge.polling)
		"toggle_bottom":
			DialogueManager.bottom_visible = not DialogueManager.bottom_visible
		"toggle_popup":
			DialogueManager.popup_visible = not DialogueManager.popup_visible
		"toggle_bubble":
			DialogueManager.bubble_visible = not DialogueManager.bubble_visible
		_:
			# 状态页按钮（批次 47）：id 形如 "state:<key>" → 按前缀路由（表驱动，避免写 5 个 case）
			if id.begins_with(STATE_VIEW_ID_PREFIX):
				_toggle_state_view(id.substr(STATE_VIEW_ID_PREFIX.length()))
	# 统一刷新所有开关按钮文案：穿透/置顶有状态信号会自动刷新，
	# 但强制边框、底部/弹窗对话面板等没有信号，必须在此处显式刷新，否则文案不会变。
	_refresh_toggle_labels()


# 关卡页面开关：调桌面场景的统一入口（预留接口，未来其它触发方式可走 desktop.toggle_level_page）
func _toggle_level_page_pressed() -> void:
	var scene = get_tree().current_scene
	if scene != null and scene.has_method("toggle_level_page"):
		scene.toggle_level_page()
	_refresh_toggle_labels()


# 时间轴调试面板开关：按一次打开，再按一次关闭
func _toggle_timeline_debug() -> void:
	if _timeline_panel != null and is_instance_valid(_timeline_panel):
		_timeline_panel.close()
		_timeline_panel = null
		return
	_timeline_panel = TimelineDebugPanelScript.new()
	var layer := _make_layer(132)
	layer.add_child(_timeline_panel)


# 控制台面板开关：按一次打开，再按一次关闭
func _toggle_console() -> void:
	if _console_panel != null and is_instance_valid(_console_panel):
		_console_panel.close()
		_console_panel = null
		return
	_console_panel = ConsolePanelScript.new()
	var layer := _make_layer(133)
	layer.add_child(_console_panel)
	_console_panel.closed.connect(_on_console_closed.bind(layer))


# 控制台面板关闭：释放其承载层
func _on_console_closed(layer: CanvasLayer) -> void:
	if layer != null and is_instance_valid(layer):
		layer.queue_free()
	_console_panel = null


# 性能忙闲判断面板开关：按一次打开，再按一次关闭
# ★ 入口 = 系统托盘右键菜单「性能忙闲判断」（desktop._open_perf_busy）；
#   调试面板上的按钮已移除（v6），但本函数保留，供托盘路径复用。
func _toggle_perf_busy() -> void:
	if _perf_busy_panel != null and is_instance_valid(_perf_busy_panel):
		_perf_busy_panel.close()
		_perf_busy_panel = null
		return
	_perf_busy_panel = PerfBusyPanelScript.new()
	var layer := _make_layer(134)
	layer.add_child(_perf_busy_panel)
	_perf_busy_panel.closed.connect(_on_perf_busy_closed.bind(layer))


# 性能忙闲判断面板关闭：释放其承载层
func _on_perf_busy_closed(layer: CanvasLayer) -> void:
	if layer != null and is_instance_valid(layer):
		layer.queue_free()
	_perf_busy_panel = null


# 对话调试面板开关：按一次打开，再按一次关闭
# （底部/弹窗/冒泡对话面板开关、8 个对话变量、冒泡文本、右下角提醒都在这个独立页面里）
func _toggle_dialogue_panel() -> void:
	if _dialogue_panel != null and is_instance_valid(_dialogue_panel):
		_dialogue_panel.close()
		_dialogue_panel = null
		return
	_dialogue_panel = DialogueDebugPanelScript.new()
	var layer := _make_layer(135)
	layer.add_child(_dialogue_panel)
	_dialogue_panel.closed.connect(_on_dialogue_panel_closed.bind(layer))


# 对话调试面板关闭：释放其承载层
func _on_dialogue_panel_closed(layer: CanvasLayer) -> void:
	if layer != null and is_instance_valid(layer):
		layer.queue_free()
	_dialogue_panel = null


# 自测量面板开关（批次 1）：按一次打开，再按一次关闭。
# ★ 面板本身负责开/关计时闸门（PerfMonitor.begin/end_profiling + Block.profile_on），
#   这里只做层与生命周期管理。
func _toggle_self_profile() -> void:
	if _self_profile_panel != null and is_instance_valid(_self_profile_panel):
		_self_profile_panel.close()
		_self_profile_panel = null
		return
	_self_profile_panel = SelfProfilePanelScript.new()
	var layer := _make_layer(136)
	layer.add_child(_self_profile_panel)
	_self_profile_panel.closed.connect(_on_self_profile_closed.bind(layer))


# 自测量面板关闭：释放其承载层（面板的 _exit_tree 会再次关闸，幂等）
func _on_self_profile_closed(layer: CanvasLayer) -> void:
	if layer != null and is_instance_valid(layer):
		layer.queue_free()
	_self_profile_panel = null


# ---------- 状态页（批次 47）----------
# 按 key 查状态页配置（表驱动：见文件顶部 STATE_VIEWS）
func _state_view_config(key: String) -> Dictionary:
	for sv in STATE_VIEWS:
		if str(sv["key"]) == key:
			return sv
	return {}


func _state_view_index(key: String) -> int:
	for i in STATE_VIEWS.size():
		if str(STATE_VIEWS[i]["key"]) == key:
			return i
	return -1


# 状态页开关：按一次打开，再按一次关闭（每个状态页各占一个独立层，可同时打开）
func _toggle_state_view(key: String) -> void:
	var cur: Control = _state_panels.get(key, null)
	if cur != null and is_instance_valid(cur):
		cur.close()
		_state_panels.erase(key)
		return
	var cfg := _state_view_config(key)
	var idx := _state_view_index(key)
	if cfg.is_empty() or idx < 0:
		return
	# 该页可以有自己的专用查看器脚本（同契约）；没有就用通用 JSON 查看器
	var script_res: GDScript = StateViewPanelScript
	if cfg.has("panel"):
		var custom: Variant = load(str(cfg["panel"]))
		if custom is GDScript:
			script_res = custom
		else:
			push_warning("[Debug] 状态页 %s 的自定义面板脚本加载失败: %s" % [key, str(cfg["panel"])])
	var panel = script_res.new()
	# ★ configure() 必须在入树前调用 —— 面板 _ready() 里才据它建 UI / 读文件
	panel.configure(str(cfg["title"]), str(cfg["file"]))
	var layer := _make_layer(STATE_VIEW_LAYER_BASE + idx)
	layer.add_child(panel)
	panel.closed.connect(_on_state_view_closed.bind(key, layer))
	_state_panels[key] = panel


# 状态页关闭：释放其承载层
func _on_state_view_closed(key: String, layer: CanvasLayer) -> void:
	if layer != null and is_instance_valid(layer):
		layer.queue_free()
	_state_panels.erase(key)


# 公开 API：某状态页是否打开（探针 / 控制台可用）
func is_state_view_open(key: String) -> bool:
	var p: Control = _state_panels.get(key, null)
	return p != null and is_instance_valid(p)


# 公开 API：自测量面板是否打开（控制台 /perf 与探针用）
func is_self_profile_open() -> bool:
	return _self_profile_panel != null and is_instance_valid(_self_profile_panel)


# 公开 API：打开/关闭自测量面板（幂等；控制台 /perf 与自动化用）
func set_self_profile_open(on: bool) -> void:
	if is_self_profile_open() == on:
		return
	_toggle_self_profile()


# 公开 API：导出一次自测量快照。返回落盘路径（失败为空串）。
#
# ★ 面板没开时**先打开**再导出 —— 因为「子系统耗时」和「进程树」两项必须有面板在采样
#   才有值。若像早先那样临时 new 一个不进场景树的实例，导出的是没有 span、没有进程树
#   的"半空"快照（键都在、值全空），是个静默的质量陷阱。
#   代价：首次调用时 span 还是空的（要 60 帧才结算），提示语里已说明。
func export_self_profile_snapshot() -> String:
	if not is_self_profile_open():
		set_self_profile_open(true)
	if _self_profile_panel != null and is_instance_valid(_self_profile_panel):
		return _self_profile_panel.export_snapshot()
	return ""


# 事件链编辑器开关：按一次打开，再按一次关闭（未保存直接关 = 丢弃暂存）
func _toggle_event_editor() -> void:
	if _event_editor != null and is_instance_valid(_event_editor):
		_event_editor.close()
		_event_editor = null
		return
	_event_editor = EventChainEditorPanel.new()
	# 复用面板自身 CanvasLayer 需挂在编辑器下：这里给它一个宿主层
	var layer := _make_layer(131)
	layer.add_child(_event_editor)
	_refresh_toggle_labels()


func _refresh_toggle_labels(_on: bool = false) -> void:
	if _toggle_passthrough != null:
		_toggle_passthrough.set_label("桌面穿透: %s" % ("开启" if MousePassRunner.is_enabled() else "关闭"))
	if _toggle_topmost != null:
		_toggle_topmost.set_label("窗口置顶: %s" % ("开启" if DesktopShell.is_always_on_top() else "关闭"))
	if _toggle_force_border != null:
		_toggle_force_border.set_label("强制显示边框: %s" % ("开启" if force_border else "关闭"))
	if _toggle_mouse_coords != null:
		_toggle_mouse_coords.set_label("鼠标坐标显示: %s" % ("开启" if _mouse_track_enabled else "关闭"))
	if _toggle_level_page != null:
		var scene = get_tree().current_scene
		var vis: bool = scene != null and scene.has_method("level_page_is_visible") and scene.level_page_is_visible()
		_toggle_level_page.set_label("关卡页面: %s" % ("显示" if vis else "隐藏"))
	if _toggle_html_poll != null and HtmlBridge != null:
		_toggle_html_poll.set_label("HTML命令轮询: %s" % ("开启" if HtmlBridge.polling else "关闭"))


# 强制边框覆盖层：首次需要时创建并挂到当前场景（桌面）下，置于最高渲染层级。
# 仅创建一次；显隐由 force_border setter 控制。current_scene 在 autoload _ready 时可能尚未就绪，
# 故通过 call_deferred 延迟到场景树建好后再挂。
func _ensure_border_overlay() -> void:
	if _border_overlay != null and is_instance_valid(_border_overlay):
		return
	var scene = get_tree().current_scene if get_tree() != null else null
	if scene == null:
		return
	var ov = load("res://debug/force_border_overlay.gd").new()
	ov.name = "ForceBorderOverlay"
	_border_overlay = ov
	scene.add_child(ov)
	ov.visible = _force_border


# 桌面穿透 / 窗口置顶 状态变化 → 更新按钮文案（信号带一个 bool 参数，这里忽略）
func _on_system_state_changed(_value: bool) -> void:
	_refresh_toggle_labels()


func _on_dialogue_vis_changed(_panel: String, _vis: bool) -> void:
	_refresh_toggle_labels()




# 信号接收端：真正写入 DialogueManager（按钮与事件链脚本共用）
func _on_field_value_requested(var_name: String, value: Variant) -> void:
	DialogueManager.set_value(var_name, value)
	print("[DebugManager] 已修改: %s = %s" % [var_name, str(value)])




# 全局变量变化 → 转发给对话调试页面同步输入框（仅更新显示；用户正在编辑该框时不覆盖）
func _on_dialogue_var_changed(name: String, value: Variant) -> void:
	if _dialogue_panel != null and is_instance_valid(_dialogue_panel):
		_dialogue_panel.sync_field(name, value)
