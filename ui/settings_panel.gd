# ui/settings_panel.gd
# 「设置」页面：由系统托盘图标的右键二级菜单「设置 → 打开设置」打开（见 TrayRunner / TrayIcon.cs）。
#
# 与其它 UI 统一样式（天蓝半透明底 + 荧光蓝边框），支持：
#   · 整页套 ScrollContainer —— 未来的语言/滑块条目再多也不会撑破面板，可滚动查看
#   · 语言选择：固定标题「中/En」+ 一个「下拉」按钮，点击弹 SubMenu 列出全部语言
#       （标题恒定不随语言变化；具体语言用下拉单独挑）
#   · 「确定修改」按钮：页面里所有改动是**暂存**态——只有按下「确定」才真正生效。
#      否则关闭页面（× / 关闭 / 失焦）时，设置恢复成打开之前的状态。
#   · 5 条声音滑条仍是 UI 占位（取值暂存在面板内，未接声音系统）。
#   · **UI 缩放比例（⚠️实验性内容）已真正生效**：按下「确定修改」后整体缩放所有 UI 面板
#     （含通知/确认框/调试面板），落盘 settings.json 的 `ui_scale`，重启保留。
#     实现载体 = 承载面板的 CanvasLayer 的 scale，见 desktop.set_ui_scale 的接线与
#     UIStyle 里那段「UI 缩放 + 坐标语义」说明。
class_name SettingsPanel
extends Control

signal closed

const W := 520.0
const H := 520.0
const PAD := 16.0
const TITLE_H := 40.0
const ROW_H := 40.0
const LABEL_W := 96.0
const FOOTER_H := 56.0
# 右侧下拉按钮（语言 / 第二语言）的固定宽度。
# ★ 两行必须用**同一个常量**，否则会因为左侧标题文字长度不同（「中/En」vs「第二语言」）
#   导致 HBox 里剩余空间的分配不同 → 两个按钮宽度/左缘对不齐（用户曾报此问题）。
const DROPDOWN_W := 200.0
const DROPDOWN_H := 30.0
# ★★ 内容区右侧「滚动条避让带」：
#   `ScrollContainer` 的竖向滚动条是**浮在内容之上**的（会盖住滑条右端 / 下拉按钮），
#   所以正文可用宽度必须在它左边就结束。这里的值 = 预留条宽(14) + 视觉余量(6) = 20。
#   → 正文可用宽 = W − PAD*2 − SCROLL_GUTTER。
const SCROLLBAR_W := 14.0
const SCROLL_GUTTER := SCROLLBAR_W + 6.0

# 声音滑条组（占位；将来每个键对应一个音量通道）
const SOUND_ROWS := [
	["主音量", 0.0, 1.0, 0.75],
	["音乐音量", 0.0, 1.0, 0.60],
	["音效音量", 0.0, 1.0, 0.80],
	["环境音量", 0.0, 1.0, 0.50],
	["语音音量", 0.0, 1.0, 0.85],
]

# 语言选择标题：恒定显示「中/En」，不随当前语言变化（具体语言用下拉挑）
const LANG_TITLE := "中/En"

# 第二语言（预留，暂无实际作用）：标题同样恒定；语言清单与主语言共用同一张翻译表
# （TranslationManager.LANG_CODES / LANG_NAMES），只读表、不写表。
# 提供了一个「无」选项（SECOND_LANG_NONE）表示未选第二语言。
const LANG2_TITLE := "第二语言"
const SECOND_LANG_NONE := ""

# 语言控件索引 → 代码（与每行滑条的 key 无关，仅用于滑块行）
var _panel: UIPanel
var _title: Label
var _scroll: ScrollContainer
var _drag_handle: UIDragHandle
var _confirm_btn: UIBtn
var _close_btn: UIBtn

# 是否已居中过一次：首次 open 居中，之后允许用拖动把柄改位置（拖动位置保留）
var _ever_centered: bool = false

# 各控件引用（用于快照 / 应用）
var _volume_sliders: Dictionary = {}   # key(音量通道名) -> HSlider
var _ui_scale_slider: HSlider = null
var _ui_scale_hint: Label = null       # UI 缩放行的「⚠️实验性内容」提示（含当前倍率）
var _lang_btn: UIBtn                  # 语言下拉触发器
var _lang_submenu: SubMenu = null
# —— 第二语言（预留：可挑、可存、可还原，但**不产生任何实际效果**）——
var _lang2_btn: UIBtn = null              # 第二语言下拉触发器
var _lang2_submenu: SubMenu = null
var _lang2_current: String = SECOND_LANG_NONE   # 当前选中的第二语言代码（"" = 无）
var _desktop_interval_opt: OptionButton = null  # 桌面自动存档间隔
var _world_interval_opt: OptionButton = null    # 世界自动存档间隔
var _auto_limit_desktop_opt: OptionButton = null  # 桌面自动存档上限（0 = 不限制）
var _auto_limit_world_opt: OptionButton = null    # 世界自动存档上限（0 = 不限制）
var _fps_opt: OptionButton = null               # 帧率上限（0 = 不限制）
var _theme_opt: OptionButton = null             # 界面主题（透明液态玻璃 / 半透明纯色）
var _theme_color_opt: OptionButton = null       # 「半透明纯色」的主题色
var _theme_color_hint: Label = null             # 主题色行的说明文字
var _timeline_max_input: SpinBox = null         # 时间轴同时触发数量上限
var _quit_auto_check: CheckButton = null        # 退出游戏时自动存档开关
var _autostart_check: CheckButton = null        # 开机自启动开关（真实状态 = 注册表 Run 键）
var _autoload_check: CheckButton = null          # 自动载入存档开关（开启时启动即载入最新存档）
var _tray_debug_check: CheckButton = null        # 是否在托盘右键菜单显示「进入/退出调试模式」项

# ============ 快照 / 暂存机制 ============
var _snapshot_volumes: Dictionary = {}  # key -> float（打开时各滑条值快照）
var _snapshot_ui_scale: float = 1.0
var _snapshot_lang: String = ""         # 打开时当前语言
var _snapshot_lang2: String = ""        # 打开时第二语言（预留项）
var _snapshot_desktop_interval: int = 0 # 打开时桌面自动存档间隔（分钟，0=关）
var _snapshot_world_interval: int = 0   # 打开时世界自动存档间隔（小时，0=关）
var _snapshot_auto_limit_desktop: int = 10  # 打开时桌面自动存档上限（0=不限制）
var _snapshot_auto_limit_world: int = 10    # 打开时世界自动存档上限（0=不限制）
var _snapshot_max_fps: int = 60         # 打开时帧率上限（0=不限制）
var _snapshot_timeline_max: int = 0     # 打开时时间轴同时触发数量上限
var _snapshot_quit_auto: bool = false   # 打开时退出自动存档开关
var _snapshot_autostart: bool = false   # 打开时开机自启动状态（= 注册表当前状态）
var _snapshot_autoload: bool = false     # 打开时自动载入存档开关
var _snapshot_tray_debug: bool = true    # 打开时「显示调试模式按钮」开关
var _snapshot_theme_mode: String = "glass"   # 打开时界面主题（glass / solid）
var _snapshot_theme_color: String = "ice"    # 打开时「半透明纯色」的主题色键
# —— 主题「预览」作用域（批次 56）——
#   下拉一改：只把设置页自身刷成新主题（预览）；「确定修改」才全局生效。
var _base_theme: Theme = null               # 预览前设置页用的共享主题（结束预览时换回）
var _preview_theme: Theme = null            # 预览主题副本（按当前下拉值着色）
# ★ 本会话用过的**全部**预览副本：每改一次下拉都会现造一份新的（旧的那份 StyleBox 还是旧色，
#   不能再用），所以"换回共享主题"必须按"是不是历史预览副本之一"来判断，只比对最新那份会漏。
var _preview_themes: Array = []
var _theme_previewing: bool = false         # 是否正处于预览态
var _pending_lang: String = ""          # 面板里暂存的语言（未确认）
var _committed: bool = false            # 本次打开周期内是否按过「确定修改」

# 判断面板是否显示
var _open: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	_load_settings()
	if not TranslationManager.language_changed.is_connected(_on_lang_changed):
		TranslationManager.language_changed.connect(_on_lang_changed)
	visible = false


# 显示：打开时记录快照。首次打开居中，之后允许用拖动把柄改位置（拖动位置保留）。
func open() -> void:
	# ★ 防御：先把上次可能残留的主题预览撤干净（正常路径由 close() 撤，这里是兜底）。
	_end_theme_preview()
	_capture_snapshot()
	# ★★ 「暂存型」控件（下拉 / 勾选 / 数值输入）在**每次打开时**都要回到"已生效值"。
	#   为什么：apply() 会把 _committed 置 true，而 close() 只在 `not _committed` 时才走
	#   _restore_snapshot()。于是「按过确定 → 又改了控件 → 关闭（未再按确定）」这条路径下
	#   控件会停在那个**从未生效**的档位；下次打开若不同步，屏幕上显示的就是错的档位
	#   （实际生效值在 SaveManager 里）。滑条类（音量 / UI 缩放）有"松手即预览"语义，
	#   它们本身就是实时生效的，不在同步范围内。
	_sync_staged_widgets()
	_pending_lang = _snapshot_lang
	_committed = false
	_open = true
	visible = true
	if not _ever_centered:
		_center()
		_ever_centered = true
	move_to_front()


# 把「暂存型」控件的显示值同步成 SaveManager / TimelineManager 里的**已生效值**。
func _sync_staged_widgets() -> void:
	if SaveManager == null:
		return
	_set_interval(_desktop_interval_opt, SaveManager.get_desktop_interval_minutes())
	_set_interval(_world_interval_opt, SaveManager.get_world_interval_hours())
	_set_interval(_auto_limit_desktop_opt, SaveManager.get_auto_limit_desktop())
	_set_interval(_auto_limit_world_opt, SaveManager.get_auto_limit_world())
	_fps_select(SaveManager.get_max_fps())
	_theme_select(SaveManager.get_ui_theme_mode())
	_theme_color_select(SaveManager.get_ui_theme_color())
	if _timeline_max_input != null and is_instance_valid(_timeline_max_input):
		_timeline_max_input.value = int(TimelineManager.get_max_simultaneous()) if TimelineManager != null else 10
	if _quit_auto_check != null and is_instance_valid(_quit_auto_check):
		_quit_auto_check.button_pressed = bool(SaveManager.get_quit_auto_save())
	if _autoload_check != null and is_instance_valid(_autoload_check):
		_autoload_check.button_pressed = bool(SaveManager.get_auto_load_save())
	if _tray_debug_check != null and is_instance_valid(_tray_debug_check):
		_tray_debug_check.button_pressed = _tray_debug_default()


func close() -> void:
	# 未按下「确定修改」→ 恢复打开前的状态；按过确定则保留生效改动
	if not _committed:
		_restore_snapshot()
	# 无论走哪条路，都要撤掉主题预览：换回共享主题、并按「已生效值」重算设置页自身。
	#（未确定的主题改动本就从未全局生效，撤销预览后一切照旧。）
	_end_theme_preview()
	_open = false
	visible = false
	_close_lang_submenu()
	_close_lang2_submenu()
	get_viewport().gui_release_focus()
	closed.emit()


func _exit_tree() -> void:
	# 面板被直接释放（未走 close()）时也要撤掉预览覆盖与作用域 meta，避免残留影响其它面板。
	_end_theme_preview()


func is_open() -> bool:
	return _open


# 应用「确定修改」：把暂存的语言真正切过去，并把控件当前值记为新的基准快照，
# 同时把整页设置写回 settings.json（与具体存档无关，所有存档通用）。
func apply() -> void:
	# ★ 先撤掉「只作用于设置页自身」的主题预览（设置页换回共享主题、按已生效值重算）；
	#   下面的 SaveManager 广播才是**全局**生效那一步。
	_end_theme_preview()
	if not _pending_lang.is_empty():
		# 真正切换全局语言（会广播 language_changed → 所有面板重译）
		TranslationManager.set_lang(_pending_lang)
	_pending_lang = ""
	_committed = true
	# 真正写入时间轴同时触发数量上限
	if TimelineManager != null and _timeline_max_input != null:
		TimelineManager.set_max_simultaneous(int(_timeline_max_input.value))
	# 把整页设置落到全局 settings.json（含音量 / 缩放 / 语言 / 自动存档间隔 / 退出自动存档）
	if SaveManager != null:
		var vols := {}
		for key in _volume_sliders:
			vols[key] = _volume_sliders[key].value
		var new_scale: float = _ui_scale_slider.value if _ui_scale_slider != null else 1.0
		var patch := {
			"volumes": vols,
			"lang": TranslationManager.current_lang,
			"lang2": _lang2_current,
			"desktop_minutes": _interval_value(_desktop_interval_opt),
			"world_hours": _interval_value(_world_interval_opt),
			"auto_limit_desktop": _interval_value(_auto_limit_desktop_opt),
			"auto_limit_world": _interval_value(_auto_limit_world_opt),
			"timeline_max": int(_timeline_max_input.value) if _timeline_max_input != null else 10,
			"quit_auto_save": _quit_auto_check.button_pressed if _quit_auto_check != null else false,
			"auto_load_save": _autoload_check.button_pressed if _autoload_check != null else false,
			"tray_debug_button": _tray_debug_check.button_pressed if _tray_debug_check != null else true,
			"max_fps": _fps_value(),
			"ui_theme_mode": _theme_value(),
			"ui_theme_color": _theme_color_value(),
		}
		SaveManager.save_app_settings(patch)
		# ★ 自动存档上限调小后**立即清理一次**：patch 已同步内部上限变量，此刻
		#   "数量已超过新阈值" 就已经成立，不必等到下一次自动存档。
		#   （不超限时是空操作，不发起 PowerShell 调用。）
		SaveManager.prune_auto_saves_all()
		# ★ 「显示调试模式按钮」变化 → 立刻把新值下发给常驻托盘进程（写状态文件，菜单下次展开即生效）。
		if TrayRunner != null and TrayRunner.has_method("refresh_debug_button_visibility"):
			TrayRunner.refresh_debug_button_visibility()
		# ★ 帧率上限必须**运行时立刻生效**（FrameLimiter 订阅了 max_fps_changed）。
		#   patch 已经负责落盘 → 这里传 persist=false，避免重复写一次文件。
		SaveManager.set_max_fps(_fps_value(), false)
		# ★ 界面主题 / 主题色必须**运行时立刻生效**（UIPanel / GlassTheme 都订阅了
		#   ui_theme_changed）：patch 已经负责落盘 → 这里传 persist=false，避免重复写文件。
		#   ★ 这两行才是「全局生效」——之前的下拉改动只是设置页自身的预览（已在上方撤销）。
		SaveManager.set_ui_theme_mode(_theme_value(), false)
		SaveManager.set_ui_theme_color(_theme_color_value(), false)
		_refresh_theme_color_hint()
		# ★ 开机自启动：状态以注册表为唯一权威（不进 settings.json）。
		#   开：没有 → 全套创建；有 → 仅确保指向当前程序（路径变了会自动修复）；完全一致 → 不动。
		#   关：有 → 删除；没有 → 不动。
		#   写/删失败则回滚按钮并告警。
		if _autostart_check != null and is_instance_valid(_autostart_check):
			var want: bool = _autostart_check.button_pressed
			var need_apply := false
			if want:
				need_apply = (not _autostart_enabled()) \
					or (_autostart_command() != _autostart_expected_command())
			else:
				need_apply = _autostart_enabled()
			if need_apply:
				if _set_autostart(want):
					print("[Settings] 开机自启动已%s" % ("开启" if want else "关闭"))
				else:
					_autostart_check.set_pressed_no_signal(not want)
					push_warning("[Settings] 开机自启动设置失败（注册表写入/删除被拒）")
		# ★ UI 缩放真正生效：夹到合法区间 → 落盘 settings.json 的 ui_scale（唯一权威）→
		#   广播给承载面板的各 CanvasLayer。若刚才松手时已预览过，这里值相同 → 直接返回。
		var s0 := SaveManager.get_ui_scale()
		SaveManager.set_ui_scale(new_scale)
		if not is_equal_approx(s0, SaveManager.get_ui_scale()):
			_keep_screen_center(s0, SaveManager.get_ui_scale())
	# 以当前控件值作为新的基准（此后改动的滑条 / 缩放都算"已生效状态"）
	_capture_snapshot()
	_refresh_lang_btn()


# ---------------- 构建 UI ----------------


# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏控件整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build_ui() -> void:
	# 背景：与其它 UI 一致的浅天蓝半透明 + 荧光蓝边框
	_panel = UIPanel.new()
	_panel.name = "UIPanel"
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.set_corner_radius(UIStyle.CORNER_RADIUS)
	_panel.set_fill_color(UIStyle.FILL_DEFAULT)
	_panel.set_border_color(UIStyle.BORDER)
	_panel.set_border_width(UIStyle.BORDER_WIDTH)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	# 顶栏：标题 + 右侧拖动把柄（复用 UIDragHandle，拖拽可改整个面板位置）
	var top := _hbox()
	# ★★ 顶栏改用「顶部通宽」锚点（而非写死 488 宽）：折叠时面板宽度收紧，
	#   顶栏随之变窄、标题与按钮重新排布在收窄后的边框内 —— 否则固定宽度的顶栏会
	#   戳出边框外，导致「最小化后边框丢失」的观感（最小化按钮也落在边框外面）。
	top.anchor_left = 0.0
	top.anchor_top = 0.0
	top.anchor_right = 1.0
	top.anchor_bottom = 0.0
	top.offset_left = PAD
	top.offset_top = PAD
	top.offset_right = -PAD
	top.offset_bottom = PAD + 30.0
	add_child(top)

	_title = _label(TranslationManager.t("设置"))
	_title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 6)
	_title.custom_minimum_size = Vector2(0.0, 30.0)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_title)

	_drag_handle = UIDragHandle.new()
	top.add_child(_drag_handle)
	_drag_handle.setup(self)

	# 内容区：套 ScrollContainer，条目太多时可滚动
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.position = Vector2(PAD, PAD + TITLE_H)
	# ★★ 竖向滚动条**浮在内容之上**（会盖住滑条右端 / 下拉按钮）→
	#   正文宽度必须提前在左侧收住：可用宽 = W − PAD*2 − SCROLL_GUTTER。
	#   （W 本身也已加大，保证收窄后仍比原来的 440 宽。）
	var inner_w: float = W - PAD * 2.0 - SCROLL_GUTTER
	_scroll.size = Vector2(inner_w, H - PAD - TITLE_H - FOOTER_H)
	add_child(_scroll)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.custom_minimum_size = Vector2(inner_w, 0.0)
	body.add_theme_constant_override("separation", 8)
	_scroll.add_child(body)

	# —— 声音设置滑条 ——
	for row in SOUND_ROWS:
		body.add_child(_slider_row(str(row[0]), float(row[1]), float(row[2]), float(row[3])))

	body.add_child(_sep())

	# —— 语言选择：固定标题「中/En」+ 下拉按钮 ——
	var lang_row := _row_box()
	lang_row.add_child(_label(LANG_TITLE))
	lang_row.add_child(_spacer())
	_lang_btn = UIBtn.new()
	# ★ 固定宽度（不是 EXPAND_FILL）：见 DROPDOWN_W 注释 —— 两行共用同一宽度才能左右对齐。
	_lang_btn.custom_minimum_size = Vector2(DROPDOWN_W, DROPDOWN_H)
	_lang_btn.set_label(_current_lang_label())
	_lang_btn.pressed_id.connect(_on_lang_btn_pressed)
	lang_row.add_child(_lang_btn)
	body.add_child(_end_row(lang_row))

	# —— 第二语言（预留）：结构完全照搬「语言」行 ——
	#   ★ 只做预留：可选、可存进 settings.json（lang2）、可随「关闭未确定」还原，
	#     但**不切换任何界面文字**（不调 set_lang / retranslate）。
	#   ★ 语言清单直接读 TranslationManager 的翻译表（LANG_CODES / LANG_NAMES），
	#     表里加语言这里自动多一项，无需改代码。
	var lang2_row := _row_box()
	lang2_row.add_child(_label(LANG2_TITLE))
	lang2_row.add_child(_spacer())
	_lang2_btn = UIBtn.new()
	# ★ 与「语言」行**逐字同宽**（DROPDOWN_W / DROPDOWN_H）。
	_lang2_btn.custom_minimum_size = Vector2(DROPDOWN_W, DROPDOWN_H)
	_lang2_btn.set_label(_lang2_label())
	_lang2_btn.pressed_id.connect(_on_lang2_btn_pressed)
	lang2_row.add_child(_lang2_btn)
	body.add_child(_end_row(lang2_row))

	body.add_child(_sep())

	# —— 界面主题：透明液态玻璃 / 半透明纯色 ——
	#   落盘 settings.json 的 ui_theme_mode。★ 语义（批次 56）：
	#   改了**先只把设置页自身刷成新主题**给用户看效果（预览），
	#   按「确定修改」才真正全局生效 + 落盘；未确定就关闭 → 预览自动撤销。
	var theme_row := _row_box()
	theme_row.add_child(_label(TranslationManager.t("界面主题")))
	theme_row.add_child(_spacer())
	_theme_opt = OptionButton.new()
	_theme_opt.custom_minimum_size = Vector2(DROPDOWN_W, DROPDOWN_H)
	_theme_opt.add_theme_font_override("font", UIStyle.get_cjk_font())
	_theme_opt.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	_theme_opt.tooltip_text = "透明液态玻璃：磨砂模糊 + 折射/虹彩/高光；半透明纯色：平板纯色，无模糊；量子全息：无边框荧光蓝，中心实、边缘虚"
	theme_row.add_child(_theme_opt)
	body.add_child(_end_row(theme_row))
	_build_theme_options()
	if not _theme_opt.item_selected.is_connected(_on_theme_item_selected):
		_theme_opt.item_selected.connect(_on_theme_item_selected)

	# —— 主题色：仅「半透明纯色」主题生效 ——
	var tcol_row := _row_box()
	tcol_row.add_child(_label(TranslationManager.t("主题色")))
	tcol_row.add_child(_spacer())
	_theme_color_opt = OptionButton.new()
	_theme_color_opt.custom_minimum_size = Vector2(DROPDOWN_W, DROPDOWN_H)
	_theme_color_opt.add_theme_font_override("font", UIStyle.get_cjk_font())
	_theme_color_opt.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	_theme_color_opt.tooltip_text = "「半透明纯色」主题下面板的颜色"
	tcol_row.add_child(_theme_color_opt)
	body.add_child(_end_row(tcol_row))
	_build_theme_color_options()
	if not _theme_color_opt.item_selected.is_connected(_on_theme_color_item_selected):
		_theme_color_opt.item_selected.connect(_on_theme_color_item_selected)
	# 说明行：手工断行、不开 autowrap（面板宽度固定，autowrap 会撑出多余高度）。
	_theme_color_hint = _label("")
	_theme_color_hint.add_theme_font_size_override("font_size", maxi(10, UIStyle.FONT_SIZE - 3))
	_theme_color_hint.clip_text = true
	body.add_child(_theme_color_hint)
	_refresh_theme_color_hint()

	body.add_child(_sep())

	# —— UI 缩放比例（⚠️实验性内容：真的会缩放所有 UI 面板）——
	body.add_child(_slider_row(TranslationManager.t("UI 缩放"), 0.5, 2.0, 1.0, 0.05, "ui_scale"))
	# 提示行：明确标注实验性 + 显示当前倍率（拖动时实时更新）。
	# ★ 手工断行、不开 autowrap：面板宽度固定（W - PAD*2），autowrap 会撑出多余高度（见项目约定）。
	_ui_scale_hint = _label("")
	_ui_scale_hint.add_theme_font_size_override("font_size", maxi(10, UIStyle.FONT_SIZE - 3))
	_ui_scale_hint.clip_text = true
	body.add_child(_ui_scale_hint)
	if _ui_scale_slider != null:
		# 拖动中只更新提示文字（不动面板几何，避免滑条跟着面板缩放抖动）；
		# 松手才整体预览一次缩放，给用户即时反馈（与「语言」下拉的临时预览同一套暂存语义）。
		if not _ui_scale_slider.value_changed.is_connected(_on_ui_scale_value_changed):
			_ui_scale_slider.value_changed.connect(_on_ui_scale_value_changed)
		if not _ui_scale_slider.drag_ended.is_connected(_on_ui_scale_drag_ended):
			_ui_scale_slider.drag_ended.connect(_on_ui_scale_drag_ended)
	_refresh_ui_scale_hint()

	# —— 帧率上限（默认 60；下限 15，可选「不限制」）——
	# ★ 为什么值得单独做一行：本窗口是**铺满全屏的逐像素透明覆盖层**，即使桌面完全静止，
	#   引擎每帧仍要整屏重绘 + 交给 DWM 合成（gl_compatibility 没有局部重绘）。
	#   实测默认会跑满屏幕刷新率（165Hz）→ godot 进程 0.9~1.4 核、GPU 8~11%、风扇明显起转；
	#   限帧 30 → 0.22 核，限帧 15 → 0.17 核。
	var fps_row := _row_box()
	fps_row.add_child(_label(TranslationManager.t("帧率上限")))
	fps_row.add_child(_spacer())
	_fps_opt = OptionButton.new()
	# 与「语言 / 第二语言」下拉同宽，保持右侧一列对齐
	_fps_opt.custom_minimum_size = Vector2(DROPDOWN_W, DROPDOWN_H)
	_fps_opt.add_theme_font_override("font", UIStyle.get_cjk_font())
	_fps_opt.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	fps_row.add_child(_fps_opt)
	body.add_child(_end_row(fps_row))
	_build_fps_options()
	# 提示行：两行手工断行、不开 autowrap（面板宽度固定，autowrap 会撑出多余高度）。
	# 第一行是用户指定的原文，逐字保留。
	for hint_text in [
		"过高的帧率会影响设备性能，且几乎不会带来观感上的提升",
		"空闲时会自动降到 15 帧，有操作时按上面的设置运行。",
	]:
		var h := _label(TranslationManager.t(hint_text))
		h.add_theme_font_size_override("font_size", maxi(10, UIStyle.FONT_SIZE - 3))
		h.clip_text = true
		body.add_child(h)

	body.add_child(_sep())

	# —— 自动存档间隔：桌面（分钟）/ 世界（小时）——
	_desktop_interval_opt = _interval_row(body, TranslationManager.t("桌面自动存档间隔"),
		SaveManager.DESKTOP_MINUTES_OPTIONS if SaveManager != null else [5, 10, 15, 20, 30, 60],
		TranslationManager.t("分钟"), "desktop")
	_world_interval_opt = _interval_row(body, TranslationManager.t("世界自动存档间隔"),
		SaveManager.WORLD_HOURS_OPTIONS if SaveManager != null else [1, 2, 3, 4],
		TranslationManager.t("小时"), "world")

	# —— 自动存档上限：桌面 / 世界各一份 ——
	#   超过上限时把**最旧的自动存档**移入系统回收站（只数自动存档，手动存档不受影响）。
	#   落盘 settings.json（auto_limit_desktop / auto_limit_world），重启保留。
	_auto_limit_desktop_opt = _limit_row(body, TranslationManager.t("桌面自动存档上限"),
		SaveManager.AUTO_LIMIT_OPTIONS if SaveManager != null else [3, 5, 10, 20, 50],
		SaveManager.get_auto_limit_desktop() if SaveManager != null else 10)
	_auto_limit_world_opt = _limit_row(body, TranslationManager.t("世界自动存档上限"),
		SaveManager.AUTO_LIMIT_OPTIONS if SaveManager != null else [3, 5, 10, 20, 50],
		SaveManager.get_auto_limit_world() if SaveManager != null else 10)
	# 说明行：手工断行、不开 autowrap（面板宽度固定，autowrap 会撑出多余高度）。
	var limit_hint := _label(TranslationManager.t("超过上限时，最旧的自动存档会被移入回收站。"))
	limit_hint.add_theme_font_size_override("font_size", maxi(10, UIStyle.FONT_SIZE - 3))
	limit_hint.clip_text = true
	body.add_child(limit_hint)

	# —— 时间轴同时触发事件数量上限 ——
	var tl_row := _row_box()
	var tl_label := _label(TranslationManager.t("时间轴同时触发上限"))
	tl_label.custom_minimum_size = Vector2(LABEL_W, 30.0)
	tl_row.add_child(tl_label)
	_timeline_max_input = SpinBox.new()
	_timeline_max_input.min_value = 1
	_timeline_max_input.max_value = 999
	_timeline_max_input.step = 1
	_timeline_max_input.value = int(TimelineManager.get_max_simultaneous()) if TimelineManager != null else 10
	_timeline_max_input.custom_minimum_size = Vector2(0.0, 30.0)
	_timeline_max_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_timeline_max_input.add_theme_font_override("font", UIStyle.get_cjk_font())
	_timeline_max_input.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	tl_row.add_child(_timeline_max_input)
	body.add_child(_end_row(tl_row))

	# —— 退出游戏时自动存档开关 ——
	var quit_row := _row_box()
	var quit_label := _label(TranslationManager.t("退出自动存档"))
	quit_label.custom_minimum_size = Vector2(LABEL_W, 30.0)
	quit_row.add_child(quit_label)
	_quit_auto_check = CheckButton.new()
	_quit_auto_check.button_pressed = bool(SaveManager.get_quit_auto_save()) if SaveManager != null else false
	_quit_auto_check.custom_minimum_size = Vector2(0.0, 30.0)
	_quit_auto_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_quit_auto_check.add_theme_font_override("font", UIStyle.get_cjk_font())
	_quit_auto_check.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	quit_row.add_child(_quit_auto_check)
	body.add_child(_end_row(quit_row))

	# —— 开机自启动开关 ——
	# ★ 真实状态以 Windows 注册表 Run 键为唯一权威（不落 settings.json）：
	#   开 = 写入 HKCU\...\CurrentVersion\Run 的 HelloNyxel 启动命令，关 = 删除该键值。
	var auto_row := _row_box()
	var auto_label := _label(TranslationManager.t("开机自启动"))
	auto_label.custom_minimum_size = Vector2(LABEL_W, 30.0)
	auto_row.add_child(auto_label)
	_autostart_check = CheckButton.new()
	_autostart_check.button_pressed = _autostart_enabled()
	_autostart_check.custom_minimum_size = Vector2(0.0, 30.0)
	_autostart_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_autostart_check.tooltip_text = "开机时自动启动 HelloNyxel（写入注册表 HKCU 的 Run 键，仅当前用户生效）"
	_autostart_check.add_theme_font_override("font", UIStyle.get_cjk_font())
	_autostart_check.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	auto_row.add_child(_autostart_check)
	body.add_child(_end_row(auto_row))

	# —— 显示调试模式按钮开关（控制托盘右键菜单里的「进入/退出调试模式」项是否显示）——
	#   落盘 settings.json 的 tray_debug_button；托盘是常驻独立进程，开关变化时由
	#   TrayRunner.refresh_debug_button_visibility() 把新值写进状态文件 → 菜单下次展开即生效。
	var tdbg_row := _row_box()
	var tdbg_label := _label(TranslationManager.t("显示调试模式按钮"))
	tdbg_label.custom_minimum_size = Vector2(LABEL_W, 30.0)
	tdbg_row.add_child(tdbg_label)
	_tray_debug_check = CheckButton.new()
	_tray_debug_check.button_pressed = _tray_debug_default()
	_tray_debug_check.custom_minimum_size = Vector2(0.0, 30.0)
	_tray_debug_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tray_debug_check.tooltip_text = "是否在系统托盘右键菜单里显示「进入/退出调试模式」按钮"
	_tray_debug_check.add_theme_font_override("font", UIStyle.get_cjk_font())
	_tray_debug_check.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	tdbg_row.add_child(_tray_debug_check)
	body.add_child(_end_row(tdbg_row))

	# —— 自动载入存档开关 ——
	#   开启时游戏启动即自动载入「最新存档」（list_saves 按 created_at 倒序的第一条）；默认关。
	#   落盘 settings.json，重启保留（与具体存档无关，所有存档通用）。
	var al_row := _row_box()
	var al_label := _label(TranslationManager.t("自动载入存档"))
	al_label.custom_minimum_size = Vector2(LABEL_W, 30.0)
	al_row.add_child(al_label)
	_autoload_check = CheckButton.new()
	_autoload_check.button_pressed = bool(SaveManager.get_auto_load_save()) if SaveManager != null else false
	_autoload_check.custom_minimum_size = Vector2(0.0, 30.0)
	_autoload_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_autoload_check.tooltip_text = "开启后，每次启动游戏会自动载入最新的一份存档"
	_autoload_check.add_theme_font_override("font", UIStyle.get_cjk_font())
	_autoload_check.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	al_row.add_child(_autoload_check)
	body.add_child(_end_row(al_row))

	body.add_child(_sep())

	# —— 底部：确定修改 + 关闭 ——
	_confirm_btn = UIBtn.new()
	_confirm_btn.set_label(TranslationManager.t("确定修改"))
	_confirm_btn.position = Vector2(PAD, H - PAD - 32.0)
	_confirm_btn.size = Vector2(110.0, 32.0)
	_confirm_btn.pressed_id.connect(_on_confirm)
	add_child(_confirm_btn)

	_close_btn = UIBtn.new()
	_close_btn.set_label(TranslationManager.t("关闭"))
	_close_btn.position = Vector2(W - PAD - 96.0, H - PAD - 32.0)
	_close_btn.size = Vector2(88.0, 32.0)
	_close_btn.pressed_id.connect(_on_close)
	add_child(_close_btn)
	# ★ 本页顶栏是 HBox（标题 + 移动把柄），而**关闭按钮在底部**——
	#   用attach_anchored 会按绝对偏移摆位（参考不到顶栏控件）→ 与把柄错位。
	#   故改为挂进顶栏行尾，排布即「移动 | 最小化」。
	_min_btn = UIMinimize.attach(top, func(): set_minimized(not _minimized))

	# 连接语言改变：重译 + 刷新下拉语言显示
	if not TranslationManager.language_changed.is_connected(_on_lang_changed):
		TranslationManager.language_changed.connect(_on_lang_changed)


func _on_lang_changed(_lang: String) -> void:
	TranslationManager.retranslate_tree(self)
	_refresh_lang_btn()
	# 「无」的文案也随语言变 → 第二语言按钮文案一并刷新
	_refresh_lang2_btn()


# 语言下拉按钮被按下 → 弹出 SubMenu
func _on_lang_btn_pressed(_id: String) -> void:
	if _lang_submenu != null and is_instance_valid(_lang_submenu):
		_close_lang_submenu()
		return
	var items: Array = []
	for i in TranslationManager.LANG_CODES.size():
		var code: String = str(TranslationManager.LANG_CODES[i])
		var name: String = str(TranslationManager.LANG_NAMES[i])
		var mark := " ✓" if code == _pending_lang else ""
		items.append({ "label": name + mark, "id": "lang_" + code })
	var at_pos := _lang_btn.global_position + Vector2(0.0, _lang_btn.size.y + 4.0)
	_lang_submenu = SubMenu.new()
	add_child(_lang_submenu)
	_lang_submenu.item_selected.connect(_on_lang_selected)
	_lang_submenu.open(at_pos, items)


func _on_lang_selected(id: String, _path: PackedStringArray) -> void:
	if id.begins_with("lang_"):
		_pending_lang = str(id.trim_prefix("lang_"))
		# 仅临时预览：把面板文字换成目标语言，但不改全局语言（按「确定」才真正切换）
		TranslationManager.retranslate_tree_lang(self, _pending_lang)
	_refresh_lang_btn()
	_close_lang_submenu()


func _close_lang_submenu() -> void:
	if _lang_submenu != null and is_instance_valid(_lang_submenu):
		_lang_submenu.close()
	_lang_submenu = null


func _current_lang_label() -> String:
	return "(%s) ▾" % TranslationManager.get_lang_name(_pending_lang if not _pending_lang.is_empty() else TranslationManager.current_lang)


func _refresh_lang_btn() -> void:
	if _lang_btn != null and is_instance_valid(_lang_btn):
		_lang_btn.set_label(_current_lang_label())


# ---------------- 第二语言（预留：可挑可存，但无实际作用）----------------
#
# 与「语言」下拉的差别：
#   · 选中后**只**改面板内的 `_lang2_current`，不调 TranslationManager.set_lang、
#     不做临时预览、不重译任何界面（"暂无实际作用"）；
#   · 由「确定修改」落盘 settings.json 的 `lang2`，未确定关闭则随快照还原；
#   · 多一个「无」选项（= SECOND_LANG_NONE）表示清空。
#
# 语言清单直接取自翻译表的 LANG_CODES / LANG_NAMES（"仍然读取翻译表格文件"）。

func _on_lang2_btn_pressed(_id: String) -> void:
	if _lang2_submenu != null and is_instance_valid(_lang2_submenu):
		_close_lang2_submenu()
		return
	var items: Array = []
	var none_mark := " ✓" if _lang2_current == SECOND_LANG_NONE else ""
	items.append({ "label": TranslationManager.t("无") + none_mark, "id": "lang2__none" })
	for i in TranslationManager.LANG_CODES.size():
		var code: String = str(TranslationManager.LANG_CODES[i])
		var name: String = str(TranslationManager.LANG_NAMES[i])
		var mark := " ✓" if code == _lang2_current else ""
		items.append({ "label": name + mark, "id": "lang2_" + code })
	var at_pos := _lang2_btn.global_position + Vector2(0.0, _lang2_btn.size.y + 4.0)
	_lang2_submenu = SubMenu.new()
	add_child(_lang2_submenu)
	_lang2_submenu.item_selected.connect(_on_lang2_selected)
	_lang2_submenu.open(at_pos, items)


func _on_lang2_selected(id: String, _path: PackedStringArray) -> void:
	if id == "lang2__none":
		_lang2_current = SECOND_LANG_NONE
	elif id.begins_with("lang2_"):
		_lang2_current = str(id.trim_prefix("lang2_"))
	# ★ 刻意不调用任何翻译相关 API —— 本项只做预留
	_refresh_lang2_btn()
	_close_lang2_submenu()


func _close_lang2_submenu() -> void:
	if _lang2_submenu != null and is_instance_valid(_lang2_submenu):
		_lang2_submenu.close()
	_lang2_submenu = null


# 按钮文案：未选 →「(无) ▾」；已选 →「(语言名) ▾」
func _lang2_label() -> String:
	if _lang2_current == SECOND_LANG_NONE:
		return "(%s) ▾" % TranslationManager.t("无")
	return "(%s) ▾" % TranslationManager.get_lang_name(_lang2_current)


func _refresh_lang2_btn() -> void:
	if _lang2_btn != null and is_instance_valid(_lang2_btn):
		_lang2_btn.set_label(_lang2_label())


# 供外部 / 探针读取当前第二语言设置
func get_second_lang() -> String:
	return _lang2_current


func _on_confirm(_id: String) -> void:
	apply()
	_refresh_lang_btn()


func _on_close(_id: String) -> void:
	close()


# ---------------- UI 缩放（⚠️实验性内容）----------------
#
# 交互语义（与「语言」下拉同款：可临时预览，但只有「确定修改」才落盘）：
#   · 拖动滑条：只更新提示文字里的倍率（不改几何，避免滑条随面板缩放抖动）；
#   · 松开滑条：立刻把缩放**预览**应用到所有 UI 面板（layer.scale），并保持本面板屏幕中心不变；
#   · 「确定修改」：把当前倍率落盘 settings.json（重启保留）；
#   · 直接关闭（未确定）：还原成打开前的倍率。

const UI_SCALE_HINT_FMT := "⚠️实验性内容：整体缩放所有 UI 面板（当前 %.2f×），过大可能超出屏幕。"


func _on_ui_scale_value_changed(_v: float) -> void:
	_refresh_ui_scale_hint()


func _on_ui_scale_drag_ended(value_changed: bool) -> void:
	if not value_changed or _ui_scale_slider == null:
		return
	_preview_ui_scale(_ui_scale_slider.value)


func _refresh_ui_scale_hint() -> void:
	if _ui_scale_hint == null or not is_instance_valid(_ui_scale_hint):
		return
	var v: float = _ui_scale_slider.value if _ui_scale_slider != null else 1.0
	_ui_scale_hint.text = UI_SCALE_HINT_FMT % v


# 预览：施加缩放（不落盘）+ 保持面板在屏幕上的中心不漂移
func _preview_ui_scale(v: float) -> void:
	if SaveManager == null:
		return
	var s0 := SaveManager.get_ui_scale()
	if is_equal_approx(s0, v):
		return
	SaveManager.set_ui_scale(v, false)   # persist=false：预览不落盘
	_keep_screen_center(s0, v)


# 缩放是围绕 CanvasLayer 原点施加的（面板的 position 是画布坐标）→ 直接改缩放会让面板在屏幕上
# 往右下漂（缩放 > 1 时甚至漂出屏幕）。这里按「屏幕中心不变」反解新位置：
#   屏幕中心 = s * (position + size/2) 恒定 ⇒ position' = (s0/s1) * (position + size/2) - size/2
func _keep_screen_center(s0: float, s1: float) -> void:
	if s0 <= 0.0 or s1 <= 0.0:
		return
	var c := position + size * 0.5
	position = c * (s0 / s1) - size * 0.5


# ---------------- 快照 / 恢复 ----------------

# 记录当前所有控件的值作为「基准快照」（打开时 / 按确定后）
func _capture_snapshot() -> void:
	_snapshot_volumes.clear()
	for key in _volume_sliders:
		_snapshot_volumes[key] = _volume_sliders[key].value
	# 基准取「**已生效**的倍率」（SaveManager 是唯一权威）；滑条值在 _load_settings / _restore_snapshot 与其同步
	_snapshot_ui_scale = SaveManager.get_ui_scale() if SaveManager != null else 1.0
	_snapshot_lang = TranslationManager.current_lang
	_snapshot_lang2 = _lang2_current
	if SaveManager != null:
		_snapshot_desktop_interval = SaveManager.get_desktop_interval_minutes()
		_snapshot_world_interval = SaveManager.get_world_interval_hours()
		_snapshot_auto_limit_desktop = SaveManager.get_auto_limit_desktop()
		_snapshot_auto_limit_world = SaveManager.get_auto_limit_world()
	_snapshot_timeline_max = int(TimelineManager.get_max_simultaneous()) if TimelineManager != null else 10
	_snapshot_quit_auto = bool(SaveManager.get_quit_auto_save()) if SaveManager != null else false
	_snapshot_autoload = bool(SaveManager.get_auto_load_save()) if SaveManager != null else false
	_snapshot_autostart = _autostart_enabled()
	_snapshot_tray_debug = _tray_debug_default()
	_snapshot_max_fps = SaveManager.get_max_fps() if SaveManager != null else 60
	_snapshot_theme_mode = SaveManager.get_ui_theme_mode() if SaveManager != null else UIStyle.THEME_MODE_DEFAULT
	_snapshot_theme_color = SaveManager.get_ui_theme_color() if SaveManager != null else UIStyle.SOLID_COLOR_DEFAULT


# 恢复快照：滑条 / 缩放 / 语言 / 自动存档间隔 全部回到打开前的值（关闭且未确定时调用）
func _restore_snapshot() -> void:
	for key in _volume_sliders:
		if _snapshot_volumes.has(key):
			_volume_sliders[key].value = float(_snapshot_volumes[key])
	if _ui_scale_slider:
		_ui_scale_slider.value = _snapshot_ui_scale
	# ★ 松手预览可能已经把整层缩放了 → 还原成打开前的倍率（不落盘）。顺序不能反：
	#   先把滑条值同步回去，再按「打开前的值」还原层缩放。
	if SaveManager != null:
		var cur := SaveManager.get_ui_scale()
		if not is_equal_approx(cur, _snapshot_ui_scale):
			SaveManager.set_ui_scale(_snapshot_ui_scale, false)
			_keep_screen_center(cur, _snapshot_ui_scale)
	_refresh_ui_scale_hint()
	_set_interval(_desktop_interval_opt, _snapshot_desktop_interval)
	_set_interval(_world_interval_opt, _snapshot_world_interval)
	_set_interval(_auto_limit_desktop_opt, _snapshot_auto_limit_desktop)
	_set_interval(_auto_limit_world_opt, _snapshot_auto_limit_world)
	# 帧率上限：未点「确定修改」就关闭 → 回到打开前的选择（不落盘、不改 Engine.max_fps）
	_fps_select(_snapshot_max_fps)
	# 界面主题 / 主题色：未点「确定修改」就关闭 → 重选回打开前的档位
	#（预览效果由 close() 里的 _end_theme_preview() 撤销；此处只管把下拉复位）
	_theme_select(_snapshot_theme_mode)
	_theme_color_select(_snapshot_theme_color)
	if _timeline_max_input != null and is_instance_valid(_timeline_max_input):
		_timeline_max_input.value = _snapshot_timeline_max
	if _quit_auto_check != null and is_instance_valid(_quit_auto_check):
		_quit_auto_check.button_pressed = _snapshot_quit_auto
	if _autoload_check != null and is_instance_valid(_autoload_check):
		_autoload_check.button_pressed = _snapshot_autoload
	if _tray_debug_check != null and is_instance_valid(_tray_debug_check):
		_tray_debug_check.button_pressed = _snapshot_tray_debug
	# 开机自启动：注册表在未确认时绝不动 → 按钮回显打开前的真实状态即可
	if _autostart_check != null and is_instance_valid(_autostart_check):
		_autostart_check.button_pressed = _autostart_enabled()
	if not _snapshot_lang.is_empty() and _snapshot_lang != TranslationManager.current_lang:
		TranslationManager.set_lang(_snapshot_lang)
	_pending_lang = _snapshot_lang
	_refresh_lang_btn()
	# 第二语言（预留）：未确定关闭 → 还原成打开前的选择
	_lang2_current = _snapshot_lang2
	_refresh_lang2_btn()
	# 未按确定时面板文字可能停在预览语言 → 重译回当前全局语言（= 打开前语言）
	TranslationManager.retranslate_tree_lang(self, TranslationManager.current_lang)


# 启动时从全局 settings.json 读取并应用各控件值（与具体存档无关，所有存档通用）。
# 文件缺失或键缺失时保持控件默认/已加载值。
# ---------------- 托盘「进入/退出调试模式」按钮显隐开关 ----------------
# 落盘 settings.json 的 tray_debug_button（默认 true = 显示）。读盘统一走 SaveManager。

## 读「显示调试模式按钮」开关（默认 true）。
func _tray_debug_default() -> bool:
	if SaveManager == null:
		return true
	var s: Variant = SaveManager.get_app_settings()
	if typeof(s) != TYPE_DICTIONARY:
		return true
	var d: Dictionary = s as Dictionary
	if not d.has("tray_debug_button"):
		return true
	return bool(d["tray_debug_button"])


# ---------------- 开机自启动（Windows 注册表 Run 键）----------------
# 唯一权威 = HKCU\Software\Microsoft\Windows\CurrentVersion\Run 的 HelloNyxel 键值。
# 开：写入「exe 路径（+ --path 工程目录）」；关：删除键值。不落 settings.json。
# ★ 读写一律走 PowerShell（Get-ItemProperty / Set-ItemProperty / Remove-ItemProperty）：
#   ① 启动命令路径带空格需要内嵌双引号，reg 的 /d 经命令行转义后不认内嵌引号（实测报"无效语法"）；
#      PS 脚本里用 [char]34 构造引号（脚本零字面双引号 → 不受 Godot→CreateProcess→PS 两层解析吃字符影响）。
#   ② ★ 读取同样不能用 reg.exe：本环境里 reg 被安全策略拦截（OS.execute 恒 code=-1）→ 会恒读成"未启用"。

# reg.exe 形式的键路径（仅作文档参考；实际调用请用下面的 PSDrive 形式）
const AUTOSTART_REG_KEY := "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"
# PowerShell 访问注册表要走 PSDrive 路径（HKCU: 带冒号）；reg.exe 则不带冒号
const AUTOSTART_REG_KEY_PS := "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"
const AUTOSTART_REG_NAME := "HelloNyxel"

## 当前本机是否已注册开机自启动（查询注册表；查询本身失败视为未启用）
##
## ★★ 读取必须走 PowerShell，**不能**用 `reg.exe query`（2026-10-08 修复）：
##   本项目运行环境里 reg.exe 会被安全策略拦截（实测 `OS.execute("reg", ...)` 恒返回
##   code=-1，out 为空），于是旧实现 `code == 0` 永远为假 → `_autostart_enabled()` 恒 false
##   → 设置页开关永远显示"关"（用户感知为"打开后没生效"，但注册表其实已写对）。
##   改用 PowerShell 读，与 `_set_autostart` 的写入路径同源，读写一致。
func _autostart_enabled() -> bool:
	if OS.get_name() != "Windows":
		return false
	return not _read_autostart_value().is_empty()


## 本机当前的启动命令（未启用 / 读取失败 → 空串）。用于检测"注册表里有但指向旧位置"的失效值。
func _autostart_command() -> String:
	return _read_autostart_value()


## 用 PowerShell 读 Run 键下本游戏的值；键/值不存在 → 空串。
## ★ 不先做 Test-Path 探存在性（那样要多起一次 PowerShell 宿主）——直接用
##   Get-ItemProperty + -ErrorAction SilentlyContinue，取不到就是 $null → 返回空串。
func _read_autostart_value() -> String:
	var out: Array = []
	# ★ % 只作用于紧邻的一个字符串字面量：多段字符串拼接后再格式化必须整体加括号，
	#   否则 `"a" + "b" % [..]` 会被解析成 `"a" + ("b" % [..])`（"b" 里没有 %s → 报
	#   "not all arguments converted during string formatting"）。
	var script := (
		"$v = (Get-ItemProperty -Path '%s' -Name '%s' -ErrorAction SilentlyContinue).'%s'; "
		+ "if ($null -ne $v) { [Console]::Out.Write([string]$v) }"
	) % [AUTOSTART_REG_KEY_PS, AUTOSTART_REG_NAME, AUTOSTART_REG_NAME]
	OS.execute("powershell.exe", PackedStringArray([
		"-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script]), out, false)
	return "\n".join(out).strip_edges()


## 本设备应有的启动命令（与 _set_autostart 写入的值完全一致）
func _autostart_expected_command() -> String:
	var cmd := "\"%s\"" % OS.get_executable_path()
	# 编辑器内运行 → 启动命令必须带 --path 指到工程目录；导出版直接启动 exe 即可
	if OS.has_feature("editor"):
		cmd += " --path \"%s\"" % ProjectSettings.globalize_path("res://")
	return cmd


## 开启 / 关闭开机自启动。返回是否成功（以"回读注册表确认"为准，不只是命令返回码）。
##
## ★ 开启是**自足 + 幂等**的（换设备直接可用）：
##   1) 先查注册表里有没有本游戏的自启动内容；
##   2) 没有 → 自动创建所需的一切（Run 键不存在则连键一起建 + 写键值）；
##      有   → 仅仅是开启（Set-ItemProperty 原地覆写；旧值指向已移动的 exe 也会被修复成当前路径）；
##   3) 写完回读，确认值与预期一致才算成功。
func _set_autostart(enable: bool) -> bool:
	if OS.get_name() != "Windows":
		push_warning("[Settings] 开机自启动仅支持 Windows")
		return false
	var out: Array = []
	if enable:
		var exe := OS.get_executable_path().replace("'", "''")
		var val_expr := "$q + '%s' + $q" % exe
		if OS.has_feature("editor"):
			var proj := ProjectSettings.globalize_path("res://").replace("'", "''")
			val_expr = "$q + '%s' + $q + ' --path ' + $q + '%s' + $q" % [exe, proj]
		# PS 脚本（零字面双引号，引号由 $q=[char]34 拼出）：
		#   ① 查现有值 ② Run 键不存在则连键创建（New-Item -Force 幂等）③ 写值 ④ 回读输出
		var script := (
			"$n='%s'; $key='%s'; $q=[char]34; " % [AUTOSTART_REG_NAME, AUTOSTART_REG_KEY_PS]
			+ "$existed = Test-Path ($key + '\\' + $n); "
			+ "if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }; "
			+ "Set-ItemProperty -Path $key -Name $n -Value (%s); " % val_expr
			+ "'EXISTED=' + $existed; 'VALUE=' + (Get-ItemProperty -Path $key -Name $n).$n"
		)
		var code := OS.execute("powershell.exe", PackedStringArray([
			"-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script]), out, false)
		if code != 0:
			return false
		# 回读校验：输出必须包含与本机预期一致的启动命令
		var text := "\n".join(out)
		return text.contains("VALUE=") and text.contains(_autostart_expected_command())
	# 关闭：删除键值（本就不存在也视为成功），以回读确认
	OS.execute("powershell.exe", PackedStringArray([
		"-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
		"Remove-ItemProperty -Path '%s' -Name '%s' -ErrorAction SilentlyContinue" % [
			AUTOSTART_REG_KEY_PS, AUTOSTART_REG_NAME]]), out, false)
	return not _autostart_enabled()


func _load_settings() -> void:
	if SaveManager == null:
		return
	var s: Variant = SaveManager.get_app_settings()
	if typeof(s) != TYPE_DICTIONARY or (s as Dictionary).is_empty():
		return
	var d: Dictionary = s as Dictionary
	# 音量滑条
	if d.has("volumes") and typeof(d["volumes"]) == TYPE_DICTIONARY:
		var vols: Dictionary = d["volumes"]
		for key in _volume_sliders:
			if vols.has(key):
				_volume_sliders[key].value = float(vols[key])
	# UI 缩放：**已生效值**在 SaveManager（唯一权威，各 CanvasLayer 也读它）；
	# 这里只把滑条同步过去，让面板显示的就是当前真实倍率。
	if _ui_scale_slider != null:
		_ui_scale_slider.value = SaveManager.get_ui_scale()
		_refresh_ui_scale_hint()
	# 自动存档间隔
	if d.has("desktop_minutes"):
		_set_interval(_desktop_interval_opt, int(d["desktop_minutes"]))
	if d.has("world_hours"):
		_set_interval(_world_interval_opt, int(d["world_hours"]))
	# 自动存档上限（0 = 不限制）
	if d.has("auto_limit_desktop"):
		_set_interval(_auto_limit_desktop_opt, int(d["auto_limit_desktop"]))
	if d.has("auto_limit_world"):
		_set_interval(_auto_limit_world_opt, int(d["auto_limit_world"]))
	# 时间轴同时触发上限
	if d.has("timeline_max") and _timeline_max_input != null:
		_timeline_max_input.value = int(d["timeline_max"])
	# 退出自动存档开关
	if d.has("quit_auto_save") and _quit_auto_check != null:
		_quit_auto_check.button_pressed = bool(d["quit_auto_save"])
	if d.has("auto_load_save") and _autoload_check != null:
		_autoload_check.button_pressed = bool(d["auto_load_save"])
	if _tray_debug_check != null:
		_tray_debug_check.button_pressed = _tray_debug_default()
	# 帧率上限（0 = 不限制）：以 SaveManager 的**已生效值**为准（它做过合法性夹取）
	_fps_select(SaveManager.get_max_fps())
	# 界面主题 / 主题色：同样以 SaveManager 的已生效值为准
	_theme_select(SaveManager.get_ui_theme_mode())
	_theme_color_select(SaveManager.get_ui_theme_color())
	# 语言：启动即应用已保存语言（设置页打开时也作为预览基准）
	if d.has("lang") and not str(d["lang"]).is_empty():
		var saved_lang: String = str(d["lang"])
		_pending_lang = saved_lang
		TranslationManager.set_lang(saved_lang)
	# 第二语言（预留）：只恢复到控件与状态，**不切换界面语言**
	if d.has("lang2"):
		var saved2: String = str(d["lang2"])
		_lang2_current = saved2 if (saved2.is_empty() or saved2 in TranslationManager.LANG_CODES) else SECOND_LANG_NONE
	_refresh_lang2_btn()


func _center() -> void:
	var vp: Vector2 = UIStyle.canvas_viewport_size(self)
	size = Vector2(W, H)
	position = (vp - size) / 2.0
	# ★ is_instance_valid：_panel 可能已被释放（`if _panel:` 对已释放实例仍可能为真 → use-after-free）。
	if is_instance_valid(_panel):
		_panel.size = size


# ---------------- 构建小工具 ----------------

func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fnt = UIStyle.get_cjk_font()
	if fnt != null:
		l.add_theme_font_override("font", fnt)
	l.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	l.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	return l


func _hbox() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	return h


# 设置行的水平容器：与 `_hbox()` 相同，但**右侧留出滚动条避让带**。
# ★ 为什么不在 body 上统一留：body 的 `custom_minimum_size.x` 决定滚动视口宽，
#   而滑条 / 下拉按钮都带 `SIZE_EXPAND_FILL`，会把 body 撑到正好等于视口宽 →
#   右边距为 0，滚动条就压在控件上。
# ★★ 垫片必须在**行内最后一个**（调用方填完内容后再 `_end_row()`）——
#   若一开始就 add_child 进去，它会被后面的 EXPAND 控件挤成 0 宽（本次踩过）。
func _row_box() -> HBoxContainer:
	return _hbox()


# 给一行收尾：追加「滚动条避让带」垫片。
func _end_row(h: HBoxContainer) -> HBoxContainer:
	var tail := Control.new()
	tail.name = "ScrollGutter"
	tail.custom_minimum_size = Vector2(SCROLL_GUTTER, 0.0)
	tail.size_flags_horizontal = Control.SIZE_SHRINK_END
	tail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(tail)
	return h


func _spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


func _sep() -> HSeparator:
	var s := HSeparator.new()
	s.add_theme_color_override("separator", Color(0.35, 0.55, 0.7, 0.6))
	return s


# 一行：左侧固定宽度标签 + 右侧滑条
# row_key 为该行在快照里的标识：音量为 "主音量" 之类；UI 缩放用 "ui_scale"。
func _slider_row(label_text: String, mn: float, mx: float, val: float, step: float = 0.01, row_key: String = "") -> Control:
	var h := _row_box()
	var lb := _label(label_text)
	lb.custom_minimum_size = Vector2(LABEL_W, 30.0)
	h.add_child(lb)

	# ★ UI 缩放滑条：禁用鼠标滚轮改值（避免面板滚动时误改缩放）。
	#   用 Slider.scrollable = false（Godot 4.7 官方属性：true = 可用滚轮改值）。
	#   拖动把手 / 点击轨道 / 方向键不受 scrollable 影响，仍照常可用。
	var key := row_key if not row_key.is_empty() else label_text
	var s := HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = step
	s.value = val
	if key == "ui_scale":
		s.scrollable = false
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size = Vector2(0.0, 30.0)
	s.add_theme_color_override("grabber_color", Color(0.55, 0.93, 1.0))
	s.add_theme_color_override("grabber_area_color", Color(0.35, 0.75, 0.95))
	s.add_theme_color_override("slider_color", Color(0.3, 0.5, 0.7))
	s.add_theme_color_override("slider_icon", Color(0.9, 0.98, 1.0))
	h.add_child(s)

	if key == "ui_scale":
		_ui_scale_slider = s
	else:
		_volume_sliders[key] = s
	return _end_row(h)


# 自动存档间隔行：左侧标签 + 右侧下拉框（第 0 项 = 关闭[0]，其后为各可选间隔）。
# 返回下拉框（调用方存入 _desktop_interval_opt / _world_interval_opt）。
func _interval_row(body: VBoxContainer, label_text: String, options: Array, unit: String, kind: String) -> OptionButton:
	var h := _row_box()
	var lb := _label(label_text)
	lb.custom_minimum_size = Vector2(LABEL_W, 30.0)
	h.add_child(lb)
	var ob := OptionButton.new()
	ob.custom_minimum_size = Vector2(0.0, 30.0)
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ob.add_theme_font_override("font", UIStyle.get_cjk_font())
	ob.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	h.add_child(ob)
	body.add_child(_end_row(h))
	# 关闭项（值 0）+ 各间隔项
	ob.add_item(TranslationManager.t("不自动存档"))
	ob.set_item_metadata(0, 0)
	for v in options:
		ob.add_item("%d %s" % [int(v), unit])
		ob.set_item_metadata(ob.item_count - 1, int(v))
	# 按当前生效值预选
	var cur := SaveManager.get_desktop_interval_minutes() if kind == "desktop" else SaveManager.get_world_interval_hours()
	ob.select(_index_of_interval(ob, cur))
	return ob


# 取下拉框当前选中项对应的间隔值（0 = 关闭）
func _interval_value(ob: OptionButton) -> int:
	if ob == null or ob.selected < 0:
		return 0
	return int(ob.get_item_metadata(ob.selected))


# 自动存档上限行：左侧标签 + 右侧下拉框（第 0 项 = 「不限制」[0]，其后为各上限值）。
# 与 _interval_row 同构（值存 item_metadata、文本只负责显示，可被语言切换重译）；
# 复用 _set_interval / _index_of_interval 这套按 metadata 匹配的通用工具。
func _limit_row(body: VBoxContainer, label_text: String, options: Array, current: int) -> OptionButton:
	var h := _row_box()
	var lb := _label(label_text)
	lb.custom_minimum_size = Vector2(LABEL_W, 30.0)
	h.add_child(lb)
	var ob := OptionButton.new()
	ob.custom_minimum_size = Vector2(0.0, 30.0)
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ob.add_theme_font_override("font", UIStyle.get_cjk_font())
	ob.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	h.add_child(ob)
	body.add_child(_end_row(h))
	ob.add_item(TranslationManager.t("不限制"))
	ob.set_item_metadata(0, SaveManager.AUTO_LIMIT_UNLIMITED if SaveManager != null else 0)
	for v in options:
		ob.add_item(str(int(v)))
		ob.set_item_metadata(ob.item_count - 1, int(v))
	ob.select(_index_of_interval(ob, int(current)))
	return ob


# 把下拉框预选到指定间隔值（快照恢复用）
func _set_interval(ob: OptionButton, value: int) -> void:
	if ob == null:
		return
	ob.select(_index_of_interval(ob, int(value)))


func _index_of_interval(ob: OptionButton, value: int) -> int:
	for i in ob.item_count:
		if int(ob.get_item_metadata(i)) == value:
			return i
	return 0

# ---------------- 帧率上限（下拉框） ----------------
# 条目来源 = SaveManager.MAX_FPS_OPTIONS；值 0 表示「不限制」。
# 与「自动存档间隔」下拉同构：值存 item_metadata，文本只负责显示（可被语言切换重译）。
func _build_fps_options() -> void:
	if _fps_opt == null or not is_instance_valid(_fps_opt):
		return
	var options: Array = SaveManager.MAX_FPS_OPTIONS if SaveManager != null else [15, 30, 45, 60, 90, 120, 0]
	_fps_opt.clear()
	for v in options:
		var val: int = int(v)
		_fps_opt.add_item(_fps_item_text(val))
		_fps_opt.set_item_metadata(_fps_opt.item_count - 1, val)
	_fps_opt.select(_fps_index_of(SaveManager.get_max_fps() if SaveManager != null else 60))


# 条目文案：0 → 「不限制」；其余 → 「N 帧」（单位走翻译表，语言切换后仍正确）
func _fps_item_text(val: int) -> String:
	if val == 0:
		return TranslationManager.t("不限制")
	return "%d %s" % [val, TranslationManager.t("帧")]


# 取下拉框当前选中项对应的帧率（0 = 不限制）
func _fps_value() -> int:
	if _fps_opt == null or _fps_opt.selected < 0:
		return SaveManager.MAX_FPS_DEFAULT if SaveManager != null else 60
	return int(_fps_opt.get_item_metadata(_fps_opt.selected))


# 把下拉框预选到指定帧率（载入 / 快照恢复用）
func _fps_select(value: int) -> void:
	if _fps_opt == null or not is_instance_valid(_fps_opt):
		return
	_fps_opt.select(_fps_index_of(int(value)))


func _fps_index_of(value: int) -> int:
	if _fps_opt == null or not is_instance_valid(_fps_opt):
		return 0
	for i in _fps_opt.item_count:
		if int(_fps_opt.get_item_metadata(i)) == value:
			return i
	return 0


# ---------------- 界面主题（透明液态玻璃 / 半透明纯色） ----------------
# 条目来源 = UIStyle 的主题枚举；值（"glass" / "solid"）存 item_metadata，文本只负责显示。
#
# ★ 语义（批次 56）：改下拉 → **只预览到设置页自身**（_begin_theme_preview）；
#   按「确定修改」→ 全局生效 + 落盘；未按确定就关闭 → 预览随 _end_theme_preview 撤销、
#   下拉随快照复位（由 _restore_snapshot 重选回打开前的档位）。

func _theme_item_text(mode: String) -> String:
	if mode == UIStyle.THEME_MODE_SOLID:
		return TranslationManager.t("半透明纯色")
	if mode == UIStyle.THEME_MODE_HOLO:
		return TranslationManager.t("量子全息")
	return TranslationManager.t("透明液态玻璃")


func _build_theme_options() -> void:
	if _theme_opt == null or not is_instance_valid(_theme_opt):
		return
	_theme_opt.clear()
	# 条目来源 = UIStyle.theme_mode_list()（新增主题只改 UIStyle 即可，这里自动跟随）。
	for mode in UIStyle.theme_mode_list():
		_theme_opt.add_item(_theme_item_text(str(mode)))
		_theme_opt.set_item_metadata(_theme_opt.item_count - 1, str(mode))
	_theme_opt.select(_theme_index_of(_theme_value()))


func _theme_value() -> String:
	if _theme_opt == null or _theme_opt.selected < 0:
		return UIStyle.THEME_MODE_DEFAULT
	return str(_theme_opt.get_item_metadata(_theme_opt.selected))


func _theme_select(mode: String) -> void:
	if _theme_opt == null or not is_instance_valid(_theme_opt):
		return
	_theme_opt.select(_theme_index_of(mode))
	_refresh_theme_color_hint()


func _theme_index_of(mode: String) -> int:
	if _theme_opt == null or not is_instance_valid(_theme_opt):
		return 0
	for i in _theme_opt.item_count:
		if str(_theme_opt.get_item_metadata(i)) == mode:
			return i
	return 0


func _on_theme_item_selected(_idx: int) -> void:
	# ★ 只做「设置页自身」的预览（换主题副本 + 重算子树），**不**碰全局。
	#   真正全局生效在「确定修改」（见 apply()）。
	_begin_theme_preview()
	_refresh_theme_color_hint()


func _on_theme_color_item_selected(_idx: int) -> void:
	_begin_theme_preview()


# ---------------- 主题预览作用域（只作用于「设置页自身」） ----------------
#
# ★ 需求：下拉一改，先让用户**在设置页里看到**新主题的样子；「确定修改」才全局生效。
#
# ★ 为什么不能只改全局值（像 UIStyle.restyle_all_boxes 那样原地改色）：
#   GlassTheme 的默认控件样式来自**全局唯一一份 Theme**，且被挂到了几乎所有 Control 的
#   `.theme` 上；StyleBox 更是控件共用的同一实例 → 就地改色等于全局改色，做不出"只预览设置页"。
#   所以预览的做法是：给设置页整棵子树换上「按预览主题现造的 Theme 副本」，
#   并**只**刷新子树内的 UIPanel（面板背景自绘，不走 Theme）。
#
# ★ 三件套（缺一不可）：
#   ① UIStyle.set_theme_preview(下拉值) —— 让本子树的"现算颜色"读到预览主题；
#   ② 子树 .theme 换成预览副本 —— 覆盖按钮/下拉/标签/滚动条等默认控件样式；
#   ③ 子树 UIPanel.refresh_theme() —— 覆盖面板背景与磨砂开关。
#   结束预览时按**相反顺序**撤销（先清覆盖，再换回共享主题并重算），否则重算会读到预览值。

func _begin_theme_preview() -> void:
	if not _theme_previewing:
		_base_theme = theme          # 记下共享主题（可能是 null：没被挂过主题的环境）
		_theme_previewing = true
		# 打标记：预览期间新加入本子树的节点不要挂共享主题（见 glass_theme.gd 的 _in_preview_scope）
		set_meta("ui_theme_preview_root", true)
	# ① 打开预览覆盖
	UIStyle.set_theme_preview(_theme_value(), _theme_color_value())
	# ② 现造预览主题副本（必须在①之后造，造出来的 StyleBox 才会按预览主题着色）
	#    ★ 每改一次下拉都要**重造**：旧副本里的 StyleBox 是构建期按旧主题烘焙的
	#      （它们是自更新 GlassBox，但只有"全局重算"才会刷新，而预览期间恰恰不能全局重算）。
	var gt: Node = get_node_or_null("/root/GlassTheme")
	var new_theme: Theme = null
	if gt != null and gt.has_method("build_theme_now"):
		new_theme = gt.call("build_theme_now")
	if new_theme != null:
		_preview_theme = new_theme
		if not _preview_themes.has(new_theme):
			_preview_themes.append(new_theme)
	else:
		push_warning("[Settings] 预览主题生成失败，仅预览面板背景")
	# ③ 切换子树主题 + 重算子树面板
	_apply_theme_scope(true)


func _end_theme_preview() -> void:
	if not _theme_previewing:
		# 未处于预览态：只做一次防御性清理（避免上一次异常留下的覆盖）
		UIStyle.clear_theme_preview()
		return
	# ★ 顺序：先撤覆盖（此后重算读的是"已生效值"），再换回共享主题并重算子树。
	UIStyle.clear_theme_preview()
	_theme_previewing = false
	if has_meta("ui_theme_preview_root"):
		remove_meta("ui_theme_preview_root")
	_apply_theme_scope(false)
	_preview_theme = null
	_preview_themes.clear()


## 遍历设置页整棵子树：把 .theme 在「共享主题 / 预览副本」之间切换，并重算子树内的 UIPanel。
## preview=true → 换成当前预览副本；preview=false → 换回共享主题。
func _apply_theme_scope(preview: bool) -> void:
	var stack: Array = [self]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		# ★ is_queued_for_deletion：refresh_theme() 会建/拆磨砂层（增删子节点），
		#   刚被 queue_free 的节点本轮不要再去动（否则是对"半死"节点操作）。
		if n == null or not is_instance_valid(n) or n.is_queued_for_deletion():
			continue
		# 只有自带 theme 属性的节点需要换（Control / Window；PopupMenu 属于 Window）
		if n is Control or n is Window:
			var t = n.get("theme")
			if preview:
				# 判据含"历史预览副本"：改下拉会换新副本，旧副本上的节点也要一并换过来。
				if _preview_theme != null and (t == _base_theme or _preview_themes.has(t)):
					n.set("theme", _preview_theme)
			elif _preview_themes.has(t):
				n.set("theme", _base_theme)
		# 面板背景自绘（不走 Theme）→ 要主动让它按当前主题重取色 + 重定磨砂
		if n is UIPanel and is_instance_valid(n):
			(n as UIPanel).refresh_theme()
		for ch in n.get_children():
			stack.append(ch)


# ---------------- 主题色（仅「半透明纯色」生效） ----------------
# 条目来源 = UIStyle.SOLID_COLOR_KEYS / SOLID_COLOR_NAMES；值为 ASCII 键（落盘稳定）。

func _build_theme_color_options() -> void:
	if _theme_color_opt == null or not is_instance_valid(_theme_color_opt):
		return
	_theme_color_opt.clear()
	for key in UIStyle.SOLID_COLOR_KEYS:
		var k := str(key)
		_theme_color_opt.add_item(TranslationManager.t(UIStyle.solid_color_name(k)))
		_theme_color_opt.set_item_metadata(_theme_color_opt.item_count - 1, k)
	_theme_color_opt.select(_theme_color_index_of(_theme_color_value()))


func _theme_color_value() -> String:
	if _theme_color_opt == null or _theme_color_opt.selected < 0:
		return UIStyle.SOLID_COLOR_DEFAULT
	return str(_theme_color_opt.get_item_metadata(_theme_color_opt.selected))


func _theme_color_select(key: String) -> void:
	if _theme_color_opt == null or not is_instance_valid(_theme_color_opt):
		return
	_theme_color_opt.select(_theme_color_index_of(key))


func _theme_color_index_of(key: String) -> int:
	if _theme_color_opt == null or not is_instance_valid(_theme_color_opt):
		return 0
	for i in _theme_color_opt.item_count:
		if str(_theme_color_opt.get_item_metadata(i)) == key:
			return i
	return 0


func _refresh_theme_color_hint() -> void:
	if _theme_color_hint == null or not is_instance_valid(_theme_color_hint):
		return
	if _theme_value() == UIStyle.THEME_MODE_SOLID:
		_theme_color_hint.text = TranslationManager.t("当前为「半透明纯色」：此颜色应用到所有面板，点「确定修改」后生效。")
	elif _theme_value() == UIStyle.THEME_MODE_HOLO:
		_theme_color_hint.text = TranslationManager.t("「量子全息」固定为荧光蓝，不使用主题色。")
	else:
		_theme_color_hint.text = TranslationManager.t("仅在界面主题为「半透明纯色」时生效。")

## 最小化 / 还原：折叠只隐藏内容，标题栏控件（标题 / 把柄 / 最小化 / 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.apply(self, _min_btn, v, _min_btn.get_parent() if is_instance_valid(_min_btn) else null)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
