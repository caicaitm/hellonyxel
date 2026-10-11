# bottom_dialogue_panel.gd
# 底部对话面板（Control）—— 纯「台词表演」显示界面。
# 4 个栏：左侧头像栏（上）、头像栏下的角色名称栏（贴底）、中心的台词栏、右侧的按钮选择栏。
#   「重播语音」扬声器按钮贴在台词栏与按钮选择栏之间（**贴顶**）。
#
# 设计原则：本面板 **只负责显示** DialogueManager 的当前值，不含任何输入控件。
#   写值由事件链脚本（或调试面板的「修改」按钮）通过 DialogueManager 完成。
#   面板显隐由 DialogueManager.bottom_visible 控制。
#
# 位置/高度：贴视口底部、全宽；高度 PANEL_H（= 原 152 的两倍）。
#   ★ 窗口铺满整个屏幕（**含任务栏**）→ 贴底会被任务栏盖住，故底部再让出一个
#     「任务栏厚度」（sysinfo 的 taskbar，见 DesktopShell.get_taskbar_thickness），
#     使面板最底部正好落在任务栏上沿之上。
#
# ★★ 布局随 UI 缩放重排（2026-09-30 修复）：
#   本面板挂在 ui_layer（scale = UI 缩放）上，而 position/size 是**画布坐标**。
#   缩放变了必须**重排**，否则旧值乘上新倍率 = 面板按倍率飘出屏幕
#   （实测 1.5× 时底边从 1527 跑到 2290，直接出屏）。因此除 size_changed 外，
#   还必须订阅 SaveManager.ui_scale_changed 与 DesktopShell.geometry_changed。
#
# ★★ 栏宽与贴边（2026-09-30 细化，用户指定）：
#   · 左栏（头像+角色名）宽 = 右栏（按钮栏）宽 = **面板高 × 3/4**（COL_W = 228）
#   · 头像 = COL_W × COL_W 正方形（不再是小方图），贴左/贴顶内边距
#   · **角色名栏贴底**（底边 = 面板高 − PAD）
#   · **重播按钮贴顶**（y = PAD，不再垂直居中）
#   · 正文栏占「左栏右缘 → 重播按钮左缘」的剩余宽度
#
# 历史说明：本面板曾一度把台词栏改成「LineEdit + 长文本按钮」，现按要求回退为只读显示
#   （RichTextLabel，可渲染 (修饰) 样式）；长文本输入窗（UILongTextInputPanel）只在调试面板使用。
#
# 台词音效（本次新增）：
#   · 台词栏显示 DialogueManager.line_source() 渲染后的文本（引号/停顿剥掉，$变量→变量值），
#     且 (修饰) 会真正上样式（颜色/字号/透明度/对齐/换行）——台词栏是 RichTextLabel + BBCode。
#   · 面板内嵌一个 SpeakerButton（自绘扬声器图标）＝「重播语音」：按下即停止当前音频、从头重播。
#     位置在右侧（按钮选择栏左边）。
#   · 播放规则见 DialogueVoice / DialogueVoicePlayer：voice=auto → 逐字/逐词泡泡声；
#     voice=auto:相对路径 → 逐字/逐词，但泡泡声换成该文件；
#     voice=声音文件相对路径 → 只播该文件（整段）；voice 为空 → 不发声。
#
# 「冒泡对话」预留：本面板暂不处理冒泡，仅预留接口（未来新增冒泡子面板时复用此布局）。
class_name BottomDialoguePanel
extends Control

const NAME_H: float = 22.0
const BTN_H: float = 30.0
const BTN_GAP: float = 6.0
const PAD: float = 10.0
const CENTER_GAP: float = 12.0
const PANEL_H: float = 304.0   # 面板高度 = 原 152 的**两倍**
const SPK_SIZE: float = 26.0     # 扬声器（重播语音）按钮边长
const SPK_GAP: float = 6.0       # 扬声器与台词栏的间距
const LOG_BTN_W: float = 84.0    # 「台词记录」按钮宽（重播按钮左侧）
# ★★ 左栏（头像+角色名）与右栏（按钮栏）的**统一宽度** = 面板高 × 3/4。
#   用户要求：两栏宽度都取「底部对话栏整体高度」的 3/4（= 304 × 0.75 = 228）。
#   头像不再是先前的小方块（96），而是与角色名同宽的 228×228 大图。
const COL_RATIO: float = 0.75
const COL_W: float = PANEL_H * COL_RATIO   # = 228.0

var _avatar: TextureRect
var _name_label: Label
var _line_label: RichTextLabel
var _buttons_box: VBoxContainer
var _font: FontFile
var _speaker: SpeakerButton = null        # 「重播语音」扬声器按钮（自绘图标）
var _voice: DialogueVoicePlayer = null    # 台词语音播放器（泡泡声 / 语音文件）
var _voice_dirty := false                 # 本帧有新台词 → 在 _process 里合并成一次播放
var _renderer := TextRenderer.new()       # (修饰) → BBCode
var _log_btn: UIBtn = null          # 「台词记录」打开按钮（重播按钮左侧）
var _log_panel: Control = null      # 已打开的台词记录查看页（避免重复开）
## 台词栏的外框（_layout 算出）；RichTextLabel 无「垂直居中」属性 → 按内容高度在框内居中
var _line_box: Rect2 = Rect2()
## ★★ 台词栏的**点击承接层**（批次 93）—— 一个铺满 `_line_box` 的透明 Control。
##   为什么不能直接点 `_line_label`：`_center_lines()` 把它的高度**收缩到内容高度**再垂直居中，
##   于是「有效点击范围」= 有字的那几行（同一行的右侧空白点不动）——用户实测：
##   正文效果（底部）只有对话框里有文字的部分才响应。
##   现在把**渲染**与**命中**拆开：
##     · `_line_label`（RichTextLabel）继续收缩+居中 → 观感一字不变，且 mouse_filter=IGNORE；
##     · `_line_hit`（本层）铺满整个文字框、MOUSE_FILTER_STOP + gui_input → 命中范围**固定**
##       为整个台词文字框，与文字多少/几行无关。
##   ★ 命中层必须先于 `_line_label` add_child（在它下面），靠 Label 的 IGNORE 把事件让下来。
var _line_hit: Control = null


func _ready() -> void:
	_font = UIStyle.get_cjk_font()

	# 背景面板（填充 + 荧光蓝边框，沿用旧版风格）
	var bg := UIPanel.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	bg.set_fill_color(UIStyle.FILL_DEFAULT)
	bg.set_border_color(UIStyle.BORDER)
	bg.set_border_width(UIStyle.BORDER_WIDTH)
	add_child(bg)

	# 左侧头像栏（位置/尺寸由 _layout 按面板高度居中算出）
	_avatar = TextureRect.new()
	_avatar.name = "Avatar"
	_avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(_avatar)

	# 头像栏下的角色名称栏（位置/尺寸同样由 _layout 算）
	_name_label = Label.new()
	_name_label.name = "Name"
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_name_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_font):
		_name_label.add_theme_font_override("font", _font)
	add_child(_name_label)

	# 台词栏点击承接层（★ 必须建在 _line_label **之前** → 排在它下面；
	#   _line_label 设为 IGNORE，事件自然落到本层。见 _line_hit 的说明）
	_line_hit = Control.new()
	_line_hit.name = "LineHit"
	_line_hit.mouse_filter = Control.MOUSE_FILTER_STOP
	_line_hit.gui_input.connect(_on_line_gui_input)
	add_child(_line_hit)

	# 中心台词栏（只读 RichTextLabel；自动换行，可显示多行长台词；(修饰) 生效）
	# ★ 用 RichTextLabel 而非 Label：Label 只能整段单色，(修饰) 的颜色/字号/对齐无法表达。
	_line_label = RichTextLabel.new()
	_line_label.name = "Line"
	_line_label.bbcode_enabled = true
	_line_label.scroll_active = false
	_line_label.fit_content = false
	_line_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_line_label.add_theme_color_override("default_color", UIStyle.TEXT_DEFAULT)
	_line_label.add_theme_font_size_override("normal_font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_font):
		_line_label.add_theme_font_override("normal_font", _font)
	# ★★ 台词点击的执行入口**不在这里**（批次 93）：本控件被 _center_lines() 收缩成
	#   「只有文字那几行」的高度，点击范围会随文字多少变化。命中统一交给铺满文字框的
	#   `_line_hit`（见上）→ 这里只要 IGNORE，把事件让给下面的命中层。
	_line_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_line_label)

	# 右侧按钮选择栏（容器撑满内高；alignment=CENTER 让按钮整体垂直居中 —— 栏变高后不贴顶边）
	_buttons_box = VBoxContainer.new()
	_buttons_box.name = "Buttons"
	_buttons_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_buttons_box.add_theme_constant_override("separation", int(BTN_GAP))
	add_child(_buttons_box)

	# 「重播语音」扬声器按钮（图标由控件自己绘制）
	_speaker = SpeakerButton.new()
	_speaker.name = "ReplayVoice"
	_speaker.tooltip_text = TranslationManager.t("重播语音")
	_speaker.pressed.connect(_on_replay_pressed)
	add_child(_speaker)

	# 「台词记录」打开按钮（重播按钮**左侧**）：打开 DialogueLogPanel 查看历史台词 / 按钮
	_log_btn = UIBtn.new()
	_log_btn.name = "OpenLog"
	_log_btn.set_id("open_dialogue_log")
	_log_btn.set_label(TranslationManager.t("台词记录"))
	_log_btn.tooltip_text = TranslationManager.t("打开台词记录")
	_log_btn.pressed_id.connect(_on_open_log)
	add_child(_log_btn)

	# 台词语音播放器（voice=auto → 逐字/逐词泡泡声；auto:路径 → 换声源；路径 → 整段播该文件）
	_voice = DialogueVoicePlayer.new()
	_voice.name = "VoicePlayer"
	add_child(_voice)

	# 监听全局变量
	DialogueManager.variable_changed.connect(_on_var_changed)
	DialogueManager.panel_visibility_changed.connect(_on_vis_changed)
	DialogueManager.dialogue_button_pressed.connect(_on_dialogue_button)
	if not TranslationManager.language_changed.is_connected(_on_language_changed):
		TranslationManager.language_changed.connect(_on_language_changed)

	_refresh_all()
	_layout()
	visible = DialogueManager.bottom_visible
	set_process(true)
	get_viewport().size_changed.connect(_on_size_changed)
	# ★★ UI 缩放变化 → 必须重排：本面板在 ui_layer（随缩放）上，而 position/size 是
	#    **画布坐标**。缩放变了却不重排 → 面板会按倍率飘出屏幕（改 1.5 倍时底边跑到
	#    屏幕外 763px）。之前只监听 size_changed（视口尺寸），缩放变化不触发它 → 漏掉。
	if not SaveManager.ui_scale_changed.is_connected(_on_ui_scale_changed):
		SaveManager.ui_scale_changed.connect(_on_ui_scale_changed)
	# 任务栏/桌面几何变化（缩放、分辨率、任务栏改边）也要重排底部让位量。
	# ★ 用独立包装：geometry_changed 带 1 个 Vector2i 实参，与 size_changed 的 0 参不同，
	#   直接连 _on_size_changed 会因实参个数不匹配而**永不触发**。
	if not DesktopShell.geometry_changed.is_connected(_on_geometry_changed):
		DesktopShell.geometry_changed.connect(_on_geometry_changed)


func _on_geometry_changed(_size: Vector2i) -> void:
	_layout()


func _on_ui_scale_changed(_f: float) -> void:
	# 缩放刚变、层变换可能要到本帧末才生效 → 下一帧再排一次，确保读到新画布尺寸。
	_layout()
	_re_layout_deferred()


func _re_layout_deferred() -> void:
	# ★ 跨帧 → 必须先确认自己还活着（面板可能已被 free；await 恢复时对象已释放）。
	if not is_inside_tree():
		return
	await get_tree().process_frame
	if not is_instance_valid(self) or not is_inside_tree():
		return
	_layout()
	## ★ 缩放后字体测量结果会变（同一段文本在不同缩放下的 content_height 不同）
	##   → 再对一次，保证多行台词仍垂直居中。
	_center_lines()
	_center_lines.call_deferred()


func _on_size_changed() -> void:
	_layout()
	## 视口宽变了 → 换行不同 → 内容高度变 → 再对一次居中
	_center_lines.call_deferred()


# 根据视口尺寸把面板贴到「任务栏上沿」、全宽。
# 横向排布（左→右）：左栏（头像 + 角色名） | 台词栏（正文） | 重播语音按钮 | 按钮选择栏
# ★★ 各栏尺寸（用户指定）：
#   · 左栏宽 = 右栏（按钮栏）宽 = 面板高 × 3/4（COL_W = 228）
#   · 头像 = 228×228 方块贴左；**角色名栏贴底**（其底边 = 面板底边 − PAD）
#   · 重播按钮**贴顶**（y = PAD，不再垂直居中）
#   · 正文占据「左栏右缘 → 重播按钮左缘」之间的剩余宽度，左栏内空隙仍在
# ★ 本窗口铺满整个屏幕（**含任务栏区域**）→ 直接贴视口底会被任务栏盖住，
#   所以底部再让出一个「任务栏厚度」，让面板最底部正好落在任务栏上沿之上。
func _layout() -> void:
	var vp := UIStyle.canvas_viewport_size(self)
	var inset := _bottom_inset()
	position = Vector2(0.0, maxf(0.0, vp.y - inset - PANEL_H))
	size = Vector2(vp.x, PANEL_H)

	# —— 左栏：头像（上）+ 角色名（贴底）——
	# 头像正方形 = COL_W 边长（宽高同取 3/4 面板高）；贴左内边距、贴顶内边距。
	_avatar.position = Vector2(PAD, PAD)
	_avatar.size = Vector2(COL_W, COL_W)
	# ★ 角色名栏**贴底**：底边落在「面板高 − PAD」处，而不是跟在头像下面。
	_name_label.size = Vector2(COL_W, NAME_H)
	_name_label.position = Vector2(PAD, PANEL_H - PAD - NAME_H)

	# —— 右栏：按钮栏（宽 = COL_W，贴右内边距、撑满内高）——
	# 容器撑满内高，靠 alignment=CENTER 让按钮整体垂直居中。
	var right_x := vp.x - PAD - COL_W
	_buttons_box.position = Vector2(right_x, PAD)
	_buttons_box.size = Vector2(COL_W, PANEL_H - PAD * 2.0)

	# —— 重播按钮：**贴顶**（不再垂直居中）——
	var spk_x := right_x - SPK_GAP - SPK_SIZE
	if _speaker != null and is_instance_valid(_speaker):
		_speaker.size = Vector2(SPK_SIZE, SPK_SIZE)
		_speaker.position = Vector2(spk_x, PAD)

	# —— 台词记录打开按钮（重播按钮**左侧**）——
	var log_x := spk_x - SPK_GAP - LOG_BTN_W
	if _log_btn != null and is_instance_valid(_log_btn):
		_log_btn.size = Vector2(LOG_BTN_W, SPK_SIZE)
		_log_btn.position = Vector2(log_x, PAD)

	# —— 正文栏：占满「左栏右缘 → 台词记录按钮左缘」之间的剩余宽度，竖向撑满内高 ——
	var center_x := PAD + COL_W + CENTER_GAP
	var center_w: float = max(40.0, log_x - CENTER_GAP - center_x)
	_line_box = Rect2(Vector2(center_x, PAD), Vector2(center_w, PANEL_H - PAD * 2.0))
	# ★★ 点击承接层**固定**铺满整个台词文字框（与文字多少/几行无关）——见 _line_hit 说明。
	#   必须在 _line_box 算完之后摆，且不受 _center_lines() 影响（那是 Label 自己的事）。
	if _line_hit != null and is_instance_valid(_line_hit):
		_line_hit.position = _line_box.position
		_line_hit.size = _line_box.size
	_center_lines()


# 底部安全边距：下方是任务栏时让出任务栏厚度（否则返回 0）。
# 数据来自 DesktopShell.sysinfo 的 taskbar 段（SysInfo 采集的 屏幕尺寸 - 工作区尺寸）。
# 侧边 / 顶部任务栏不占底边 → 不需要让位。
func _bottom_inset() -> float:
	if DesktopShell == null:
		return 0.0
	if DesktopShell.get_taskbar_edge() != "bottom":
		return 0.0
	# ★ 任务栏厚度来自 SysInfo（屏幕像素），而本面板按**画布坐标**排布（层跟随 UI 缩放）
	#   → 换算成画布坐标；否则缩放 ≠ 1 时面板会飘在任务栏上方或压住它。
	return DesktopShell.get_taskbar_thickness() / maxf(UIStyle.ui_scale(), 0.0001)


## RichTextLabel 没有「垂直居中」属性（原 Label 有）→ 按内容高度把控件在台词栏框内居中。
## 单行时效果与原 Label 一致；多行台词也能整体居中。
func _center_lines() -> void:
	if _line_label == null or not is_instance_valid(_line_label):
		return
	if _line_box.size.y <= 0.0:
		return
	var h: float = _line_label.get_content_height()
	if h <= 0.0:
		## 尚未完成排版/测高失败 → 保持整框高度。
		## 若此时把高度设成 0，RichTextLabel 会把内容全裁掉（表现为「台词看不见」）。
		h = _line_box.size.y
	h = minf(h, _line_box.size.y)
	_line_label.position = _line_box.position + Vector2(0.0, (_line_box.size.y - h) * 0.5)
	_line_label.size = Vector2(_line_box.size.x, h)


func _refresh_all() -> void:
	_apply_avatar(DialogueManager.avatar_path)
	_name_label.text = DialogueManager.character_name
	_refresh_line()
	_rebuild_buttons(DialogueManager.bottom_buttons)


# 台词栏显示：DialogueVoice 按台词语法求值（引号/停顿剥掉、$变量换值），
# 再由 TextRenderer 把 (修饰) 翻译成 BBCode → 颜色/字号/透明度/对齐/换行真正生效。
func _refresh_line() -> void:
	var src := DialogueManager.line_source()
	var parsed: Dictionary = DialogueVoice.parse(src, TranslationManager.current_lang)
	var blocks: Array = parsed.get("blocks", [])
	_line_label.text = _renderer.bbcode_from_blocks(blocks)
	_center_lines()
	_refresh_line_clickable()
	## 本帧布局可能还没算完 → 下一帧再对一次，保证多行台词垂直居中
	_center_lines.call_deferred()


func _apply_avatar(path: String) -> void:
	# ★ 走 TextureCache：既支持 res:// 已导入图，也支持玩家素材目录的绝对路径图
	#   （原来直接 ResourceLoader.exists，只认项目内已导入的图）。
	if path != "":
		_avatar.texture = TextureCache.fetch(path)
	else:
		_avatar.texture = null


func _rebuild_buttons(arr: Array) -> void:
	for c in _buttons_box.get_children():
		c.queue_free()
	for entry in arr:
		if entry is Dictionary and entry.has("label"):
			var btn := UIBtn.new()
			btn.set_id(entry.get("id", ""))
			# ★★ 按钮文字与正文**同源**：都是 (修饰)[内容] / "字符串" / $变量 定义串
			#   → 必须走同一条富文本管线，否则会把 "(#ffffffL)[“下一句”]" 连同修饰原样显示。
			#   （历史 bug：这里直接 set_label 原文给 Label。）
			#   没写修饰的（rich=false）仍走普通 Label → 保持历史居中观感、不多挂节点。
			var lab := DialogueVoice.render_button_label(str(entry.get("label", "?")),
				TranslationManager.current_lang)
			if bool(lab.get("rich", false)):
				btn.set_label_bbcode(str(lab.get("bbcode", "")), str(lab.get("plain", "")))
			else:
				btn.set_label(str(lab.get("plain", "")))
			# ★ 按钮宽度跟随按钮栏宽度（= 面板高 × 3/4）
			btn.custom_minimum_size = Vector2(COL_W, BTN_H)
			btn.size = Vector2(COL_W, BTN_H)
			btn.pressed_id.connect(_on_btn_pressed)
			_buttons_box.add_child(btn)


func _on_btn_pressed(id: String) -> void:
	DialogueManager.emit_button("bottom", id)
	# 记录玩家按下的按钮（显示文本从当前按钮列表里按 id 查）
	var label := _button_label(id, DialogueManager.bottom_buttons)
	if not DialogueManager.is_restating():
		DialogueLog.record_button("bottom", id, label)


# 从按钮列表里按 id 查**显示文本**：把定义串渲染成纯文本（查不到 / 空 → 用 id 兜底）
func _button_label(id: String, arr: Array) -> String:
	for e in arr:
		if e is Dictionary and str(e.get("id", "")) == id:
			var def := str(e.get("label", "")).strip_edges()
			if def.is_empty():
				return id
			return str(DialogueVoice.to_display(def, TranslationManager.current_lang).get("display", ""))
	return id


# 把当前底部台词（去修饰后的纯文本）记入台词记录
func _record_current_line() -> void:
	var src := DialogueManager.line_source()
	var plain: String = DialogueVoice.parse(src, TranslationManager.current_lang).get("display", "")
	DialogueLog.record_line("bottom", plain)


# 「台词记录」按钮：打开 / 聚焦查看页
func _on_open_log(_id: String) -> void:
	_open_log_panel()


func _open_log_panel() -> void:
	if is_instance_valid(_log_panel) and _log_panel.is_inside_tree():
		_log_panel.jump_to_last_page()
		return
	var panel := DialogueLogPanel.new()
	_log_panel = panel
	panel.tree_exited.connect(_on_log_panel_closed)
	var parent := get_parent()
	if parent != null and is_instance_valid(parent):
		parent.add_child(panel)
	else:
		get_tree().root.add_child(panel)


func _on_log_panel_closed() -> void:
	_log_panel = null


func _on_var_changed(name: String, _value: Variant) -> void:
	match name:
		"avatar_path":
			_apply_avatar(DialogueManager.avatar_path)
		"character_name":
			_name_label.text = DialogueManager.character_name
		"line_text":
			_refresh_line()
			# ★ 事件链推进写台词（set_line_definition 会同时发 line_text_def 与 line_text）
			#   → 只在 line_text（已解析纯文本）这里记一次，避免同一句记两遍。
			# ★ 但「切语言重贴」不是新说了一句 → 那段时间里不记（见 DialogueManager.is_restating）。
			if not DialogueManager.is_restating():
				_record_current_line()
			_voice_dirty = true     # 同一帧内多次变化 → 只在 _process 里播一次
		"line_text_def":
			_refresh_line()
		"voice":
			_voice_dirty = true     # 换了语音配置 → 用新配置重播
		"line_effect":
			_refresh_line_clickable()
		"bottom_buttons":
			_rebuild_buttons(DialogueManager.bottom_buttons)


func _on_vis_changed(panel: String, vis: bool) -> void:
	if panel == "bottom":
		visible = vis
		if vis:
			_voice_dirty = true     # 面板刚显示 → 从头播一次
		elif _voice != null and is_instance_valid(_voice):
			_voice.stop()


# 台词变化 / 面板显示 → 延迟到帧末统一播放（合并同帧的多次信号）
func _process(_delta: float) -> void:
	if not _voice_dirty:
		return
	_voice_dirty = false
	if not visible or _voice == null or not is_instance_valid(_voice):
		return
	_voice.play(DialogueManager.voice, DialogueManager.line_source(), TranslationManager.current_lang)


# 扬声器按钮：停止当前音频并从头重播
func _on_replay_pressed() -> void:
	_voice_dirty = false     # 避免紧接着的 _process 再播一次
	if _voice != null and is_instance_valid(_voice):
		_voice.play(DialogueManager.voice, DialogueManager.line_source(), TranslationManager.current_lang)


# 玩家切语言 → 播放方式（按字 / 按词）与显示都要跟着变
func _on_language_changed(_lang: String) -> void:
	_refresh_line()
	# ★ 按钮文字也要跟着语言变：事件链执行器会先把 bottom_buttons 换成新语言的
	#   （它先于本面板收到 language_changed，见 project.godot 的 autoload 顺序）；
	#   这里再重排一次是为了「按钮列表不是事件链写的」时（调试面板手动设值）也能生效。
	_rebuild_buttons(DialogueManager.bottom_buttons)
	if visible:
		_voice_dirty = true


# 预留：未来事件链接管对话面板按钮
func _on_dialogue_button(_panel: String, _id: String) -> void:
	pass


# 点击台词 → 执行 DialogueManager.line_effect（与按钮 effect 同源的 DSL 串）；
# 结果回写控制台（与手敲命令同路径）+ 日志 print，保证三处写入/输出一致。
func _on_line_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:
		return
	var eff := DialogueManager.line_effect.strip_edges()
	if eff.is_empty():
		return
	var res = ConsoleCommand.exec(eff)
	ConsolePanel.log_lines(res.lines, not res.ok)
	for line in res.lines:
		print("[BottomDialogue] ▶ 台词效果: " + line)
	if not res.ok:
		push_warning("[BottomDialogue] 台词效果执行存在错误（见上方日志）")


# 台词有「正文效果」时把鼠标设为手型，提示可点击
# ★ 光标画在**命中层**上（批次 93）：命中层铺满整个文字框 → 整框都是手型，
#   而不是只有文字那几行是手型、周围空白是箭头。
func _refresh_line_clickable() -> void:
	if _line_hit == null or not is_instance_valid(_line_hit):
		return
	_line_hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND \
		if not DialogueManager.line_effect.strip_edges().is_empty() else Control.CURSOR_ARROW
