# debug/dialogue_debug_panel.gd
# 「对话调试」独立页面（由调试面板里的「对话调试面板」按钮开关）。
# 从 debug_manager.gd 拆出，收纳全部对话相关调试控件，避免主调试面板臃肿：
#   · 底部对话面板 / 弹窗对话面板 / 冒泡对话面板 —— 显隐开关
#   · 8 个对话全局变量（台词栏 / 头像路径 / 角色名称 / 按钮 …）编辑行
#   · 冒泡对话：按积木 ID 选择 → 编辑该积木「冒泡对话框」的文本
#   · 右下角提醒（通知管理器）：发送测试提醒（自定义文案 / 按钮组 / 超时）
# 挂载于独立 CanvasLayer（layer 135），样式与其它调试子面板统一。
class_name DialogueDebugPanel
extends Control


signal closed

const W := 470.0
const H := 660.0
const PAD := 12.0
const TITLE_H := 28.0

# 右下角提醒（通知）调试控件
var _notify_text_input: LineEdit = null
var _notify_buttons_input: LineEdit = null
var _notify_timeout: SpinBox = null
var _notify_status: Label = null

var _fields: Dictionary = {}    # var_name -> LineEdit
var _toggle_bottom: UIBtn
var _toggle_popup: UIBtn
# 冒泡对话（按积木 ID 编辑该积木的「冒泡对话框」文本框）
var _id_select: OptionButton = null      # 「选择ID」下拉（当前页最多 10 个；翻页项集成进菜单顶部）
var _bubble_text_input: LineEdit = null  # 「冒泡文本」输入框
var _selected_block_id: int = -1         # 当前选中的积木 ID（下拉 item_id 直读，-1 = 未选）
var _id_page: int = 0                    # 当前页（0 基；翻页环绕）
const ID_PAGE_SIZE: int = 10             # 每页 10 个，超过则需翻页
const ID_PAGE_PREV: int = -1001          # 下拉菜单内「上一页」项的 item_id（负数区别于真实积木 ID）
const ID_PAGE_NEXT: int = -1002          # 下拉菜单内「下一页」项的 item_id
# ★ 下拉 item_id 只能存 int32：Godot 的 PopupMenu.add_item(label, id) 的 id 是 32 位，
#   而时间基积木 ID 是 14~16 位（约 2e15），直接存会被截断成垃圾值
#   （实测 2026091820085811 → 1127739955 = id mod 2^32），导致 get_selected_id() 拿不到真 ID。
#   因此改为：item_id 存「本页内下标」，真实 ID 存在 _id_page_ids，选中时按下标反查。
var _id_page_ids: Array[int] = []        # 当前页各下拉项对应的真实积木 ID（与菜单项一一对应）
var _id_jump_input: LineEdit = null      # 「输入ID」定位框：输入已知 ID 直接跳到该项
var _id_status_lab: Label = null         # 「输入ID」下方的状态行：定位成功/失败**可见**反馈（不再只 print）
var _seen_registry_version: int = -1     # 上次刷新时 BlockManager 的注册表版本（变化 → 自动重刷下拉）
# 「选择ID」弹窗是否展开。★ 必须用 about_to_popup / popup_hide 信号维护：
#   Godot 4 嵌入式 Window 既不被 get_children() 枚举，其 visible 也不可靠（headless 实测恒为 true），
#   用 visible 判断会把「弹窗是否展开」判错 → 自动重刷被永久挡住 / 在可见状态下重建菜单导致点不动。
var _id_popup_open: bool = false
# 「选择ID」列表内容已过期、待重刷。
# 弹窗展开期间**不立刻重建**（重建会清空命中表 → 点不动），只置脏，等下面三个出口之一：
#   ① 弹窗已关闭            → 立刻刷（正常路径）
#   ② 下拉当前只显示占位「（无积木）」而来源其实非空 → 立刻刷（明显陈旧，且没有选择需要保留）
#   ③ 弹窗"展开"但实际不可见 / 超时 → 视为标志卡死，复位后强制刷
var _id_list_dirty: bool = false
var _id_dirty_time: float = 0.0          # 置脏后经过的时间（秒），用于超时强制重刷
# ★ 超时阈值：popup_hide 信号一旦因异常（弹窗被强制关闭 / 命中表过期）没送达，
#   _id_popup_open 会永久停在 true → 自动重刷被永久挡住 → 下拉永远停在旧内容。
#   实测已出现「桌上明明有积木，下拉却一直显示『（无积木）』」这一类症状，故加硬超时。
#   注：该超时只在无法用 popup.visible 交叉验证的环境（headless）下生效，见 _process。
const ID_LIST_DIRTY_TIMEOUT: float = 2.0
# 是否已就「注册表为空但场景内有积木」告警过一次（避免每次重刷都刷屏）
var _warned_registry_fallback: bool = false
var _toggle_bubble: UIBtn    # 冒泡对话面板显隐开关
# 长文本编辑（复用 abandon 版 UILongTextInputPanel）
# 台词栏 / 事件内容 是长文本字段 → 这两行额外挂「长文本」按钮
const LONG_TEXT_FIELDS: Array = ["line_text", "event_content", "line_effect"]
const LONG_BTN_W: float = 56.0
# 「修改」按钮宽度（每个输入框右侧各一个；只有按下它才写回栏位）
const APPLY_BTN_W: float = 46.0
# 输入框最大宽度（面板加宽后不把输入框拉得过长）
const INPUT_MAX_W: float = 300.0
# 字段行左侧标签列宽（各行统一，保证输入框左端对齐）
const LABEL_W: float = 88.0
# 数组型栏位（输入框内容按 JSON 解析）
const ARRAY_FIELDS: Array = ["bottom_buttons", "popup_buttons"]
# 文件路径类栏位 → [默认目录, 扩展名过滤, 类型名, 对话框标题]（右侧挂文件夹按钮，选中回填 res:// 相对路径）
const PATH_FIELDS := {
	"avatar_path": [UIPathPicker.DIR_TEXTURES, UIPathPicker.IMG_EXTS, "图片", "选择头像图片"],
	"event_image_path": [UIPathPicker.DIR_TEXTURES, UIPathPicker.IMG_EXTS, "图片", "选择事件配图"],
	"voice": [UIPathPicker.DIR_AUDIO, UIPathPicker.AUDIO_EXTS, "音频", "选择声音文件"],
}
var _popup_layer: CanvasLayer       # 承载长文本窗（独立层，不受调试面板显隐影响）
var _long_text_panel: UILongTextInputPanel = null
# 栏变量在调试面板里的展示顺序与是否数组（前 BOTTOM_BAR_COUNT 个 = 底部对话面板）
const _BAR_FIELDS: Array = [
	# [var_name, 显示名, 是否数组]
	["line_text", "台词栏", false],
	["avatar_path", "头像路径", false],
	["character_name", "角色名称", false],
	["voice", "语音", false],
	["line_effect", "台词效果", false],
	["bottom_buttons", "按钮(JSON)", true],
	["event_name", "事件名称", false],
	["event_image_path", "事件配图路径", false],
	["event_content", "事件内容", false],
	["popup_buttons", "按钮(JSON)", true],
]
# 底部对话面板占前几条（其余 = 弹窗对话面板）
const BOTTOM_BAR_COUNT: int = 6


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_layout_root()
	_build()
	# 全局变量被外部（事件链 / 控制台）改动 → 同步输入框显示
	if DialogueManager != null and DialogueManager.has_signal("variable_changed"):
		if not DialogueManager.variable_changed.is_connected(_on_dialogue_var_changed):
			DialogueManager.variable_changed.connect(_on_dialogue_var_changed)
	# 面板最小化期间不跑 _process（注册表变化置脏后由 _process 出口重刷）
	# ★ 非调试模式下同样不跑（见 _process 开头的守卫）
	set_process(Debug == null or Debug.debug_mode)


# ★ 根节点必须显式给 size / position：本页挂在独立 CanvasLayer 下，Control 默认尺寸 0×0，
#   背景 UIPanel 又是 PRESET_FULL_RECT（锚定父矩形）→ 不设就会连背景一起变 0，
#   只剩一堆悬空控件叠在主调试面板上（表现为「显示了两层 / 透明页面」）。
#   位置放在主调试面板右侧（主面板 12,12 宽 460），避免两层重叠。
func _layout_root() -> void:
	var vp := UIStyle.canvas_viewport_size(self)
	size = Vector2(W, minf(H, maxf(320.0, vp.y - 80.0)))
	position = Vector2(minf(488.0, maxf(12.0, vp.x - W - 16.0)), 12.0)



# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build() -> void:
	var bg := UIPanel.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	bg.set_fill_color(UIStyle.FILL_DEFAULT)
	bg.set_border_color(UIStyle.BORDER)
	bg.set_border_width(UIStyle.BORDER_WIDTH)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var top := HBoxContainer.new()
	top.position = Vector2(PAD, PAD)
	top.size = Vector2(W - PAD * 2.0, TITLE_H)
	add_child(top)
	var title := Label.new()
	title.text = "对话调试"
	title.add_theme_font_override("font", UIStyle.get_cjk_font())
	title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 3)
	title.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	# 移动页面把柄（复用 UIDragHandle，与事件链编辑器 / 属性面板同款）：按住可拖动本页
	var drag_handle := UIDragHandle.new()
	drag_handle.setup(self)
	drag_handle.tooltip_text = "拖动以移动面板"
	top.add_child(drag_handle)
	var close_btn := UIBtn.new()
	close_btn.set_id("close")
	close_btn.set_label("×")
	close_btn.custom_minimum_size = Vector2(TITLE_H, TITLE_H)
	close_btn.pressed_id.connect(func(_id): close())
	_min_btn = UIMinimize.attach(top, func(): set_minimized(not _minimized))
	top.add_child(close_btn)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(PAD, PAD + TITLE_H + 8.0)
	scroll.size = Vector2(W - PAD * 2.0, size.y - PAD * 2.0 - TITLE_H - 8.0)
	scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(scroll)
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 4)
	scroll.add_child(vbox)

	# ---- 底部对话面板 ----
	_toggle_bottom = _make_toggle("toggle_bottom", "底部对话面板")
	vbox.add_child(_toggle_bottom)
	for f in _BAR_FIELDS.slice(0, BOTTOM_BAR_COUNT):
		vbox.add_child(_make_field(f[0], f[1], f[2]))
	vbox.add_child(_sep())

	# ---- 弹窗对话面板 ----
	_toggle_popup = _make_toggle("toggle_popup", "弹窗对话面板")
	vbox.add_child(_toggle_popup)
	for f in _BAR_FIELDS.slice(BOTTOM_BAR_COUNT, _BAR_FIELDS.size()):
		vbox.add_child(_make_field(f[0], f[1], f[2]))
	vbox.add_child(_sep())

	# ---- 冒泡对话面板（此前只有开关逻辑、没有按钮，属"未制作"的调试功能）----
	_toggle_bubble = _make_toggle("toggle_bubble", "冒泡对话面板")
	vbox.add_child(_toggle_bubble)
	vbox.add_child(_sep())

	# ---- 冒泡对话：按积木 ID 编辑该积木的「冒泡对话框」文本 ----
	_add_bubble_section(vbox)
	vbox.add_child(_sep())

	# ---- 右下角提醒（通知）----
	_add_notification_section(vbox)

	_refresh_toggle_labels()


# 分隔线
func _sep() -> HSeparator:
	var s := HSeparator.new()
	s.add_theme_constant_override("separation", 2)
	return s


# 显隐开关按钮（宽度交给容器算，避免写死宽度触发横向滚动条）
func _make_toggle(id: String, label: String) -> UIBtn:
	var btn := UIBtn.new()
	btn.set_id(id)
	btn.set_label(label)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size = Vector2(0.0, UIStyle.BTN_HEIGHT)
	btn.pressed_id.connect(_on_toggle_pressed)
	return btn


# ---- 右下角提醒（通知管理器）调试区块 ----
# 文案 + 按钮组（JSON 数组，最多 2 个 {id,label}）+ 超时秒数 → 发送测试提醒
func _add_notification_section(vbox: VBoxContainer) -> void:
	var fnt := UIStyle.get_cjk_font()
	var title := Label.new()
	title.text = "右下角提醒"
	title.add_theme_color_override("font_color", Color(0.8, 0.92, 1.0))
	title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		title.add_theme_font_override("font", fnt)
	vbox.add_child(title)

	_notify_text_input = _make_input("提醒文案（如：该喝水了）")
	vbox.add_child(_row("文案", _notify_text_input))

	_notify_buttons_input = _make_input('[{"id":"ok","label":"知道了"}]')
	# 预填一个示例按钮组，打开即可直接发送（清空则发无按钮提醒）
	_notify_buttons_input.text = '[{"id":"ok","label":"知道了"}]'
	vbox.add_child(_row("按钮(JSON)", _notify_buttons_input))

	_notify_timeout = SpinBox.new()
	_notify_timeout.min_value = 0.0
	_notify_timeout.max_value = 60.0
	_notify_timeout.step = 1.0
	_notify_timeout.value = 5.0
	_notify_timeout.custom_minimum_size = Vector2(90.0, UIStyle.BTN_HEIGHT)
	vbox.add_child(_row("超时秒", _notify_timeout))

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var send := UIBtn.new()
	send.set_id("notify_send")
	send.set_label("发送提醒")
	send.custom_minimum_size = Vector2(96.0, UIStyle.BTN_HEIGHT)
	send.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	send.pressed_id.connect(_on_toggle_pressed)
	btn_row.add_child(send)
	var close_all := UIBtn.new()
	close_all.set_id("notify_close_all")
	close_all.set_label("关闭全部")
	close_all.custom_minimum_size = Vector2(96.0, UIStyle.BTN_HEIGHT)
	close_all.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_all.pressed_id.connect(_on_toggle_pressed)
	btn_row.add_child(close_all)
	vbox.add_child(btn_row)

	_notify_status = Label.new()
	_notify_status.text = ""
	_notify_status.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		_notify_status.add_theme_font_override("font", fnt)
	_notify_status.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	vbox.add_child(_notify_status)


func _make_input(placeholder: String) -> LineEdit:
	var le := LineEdit.new()
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.custom_maximum_size = Vector2(INPUT_MAX_W, 10000.0)
	le.placeholder_text = placeholder
	le.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	var fnt := UIStyle.get_cjk_font()
	if is_instance_valid(fnt):
		le.add_theme_font_override("font", fnt)
	UIStyle.apply_line_edit_style(le)
	return le


func _row(label_text: String, control: Control) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var lab := Label.new()
	lab.text = label_text
	lab.custom_minimum_size = Vector2(LABEL_W, 0)
	lab.clip_text = true
	lab.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	lab.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	var fnt := UIStyle.get_cjk_font()
	if is_instance_valid(fnt):
		lab.add_theme_font_override("font", fnt)
	row.add_child(lab)
	row.add_child(control)
	return row


# 发送测试提醒：调用 NotificationManager.show()，并把按钮点击回显到状态行
func _send_notification() -> void:
	if NotificationManager == null:
		_set_notify_status("✗ NotificationManager 不可用", false)
		return
	var text: String = _notify_text_input.text.strip_edges() if _notify_text_input != null else ""
	if text.is_empty():
		text = "（调试）这是一条测试提醒"
	var btns: Array = []
	if _notify_buttons_input != null:
		var raw: String = _notify_buttons_input.text.strip_edges()
		if not raw.is_empty():
			var j := JSON.new()
			if j.parse(raw) == OK and j.data is Array:
				btns = j.data
			else:
				btns = [{"id": "ok", "label": raw}]
	var timeout: float = float(_notify_timeout.value) if _notify_timeout != null else 5.0
	var panel := NotificationManager.show(text, btns, timeout)
	if panel != null:
		panel.button_pressed.connect(func(bid: String): _set_notify_status("✓ 按钮被点击: %s" % bid, true))
	_set_notify_status("✓ 已发送提醒（超时 %.0fs，按钮 %d 个）" % [timeout, btns.size()], true)


func _set_notify_status(msg: String, ok: bool) -> void:
	if _notify_status == null or not is_instance_valid(_notify_status):
		return
	_notify_status.text = msg
	_notify_status.add_theme_color_override("font_color",
		Color(0.45, 1.0, 0.55) if ok else Color(1.0, 0.62, 0.45))


# 开关 / 通知按钮统一入口
func _on_toggle_pressed(id: String) -> void:
	match id:
		"toggle_bottom":
			DialogueManager.bottom_visible = not DialogueManager.bottom_visible
		"toggle_popup":
			DialogueManager.popup_visible = not DialogueManager.popup_visible
		"toggle_bubble":
			DialogueManager.bubble_visible = not DialogueManager.bubble_visible
		"notify_send":
			_send_notification()
		"notify_close_all":
			if NotificationManager != null:
				NotificationManager.close_all()
			_set_notify_status("✓ 已关闭全部提醒", true)
	_refresh_toggle_labels()


func _refresh_toggle_labels() -> void:
	if _toggle_bottom != null:
		_toggle_bottom.set_label("底部对话面板: %s" % ("显示" if DialogueManager.bottom_visible else "隐藏"))
	if _toggle_popup != null:
		_toggle_popup.set_label("弹窗对话面板: %s" % ("显示" if DialogueManager.popup_visible else "隐藏"))
	if _toggle_bubble != null:
		_toggle_bubble.set_label("冒泡对话面板: %s" % ("显示" if DialogueManager.bubble_visible else "隐藏"))


# 外部（事件链 / 控制台）改动对话变量 → 同步本页输入框显示
func _on_dialogue_var_changed(name: String, value: Variant) -> void:
	sync_field(name, value)


# 同步单个输入框（用户正在编辑该框时不覆盖）
func sync_field(name: String, value: Variant) -> void:
	if not _fields.has(name):
		return
	var le: LineEdit = _fields[name]
	if is_instance_valid(le) and not le.has_focus():
		if name in ARRAY_FIELDS:
			le.text = JSON.stringify(value)
		else:
			le.text = str(value)


func close() -> void:
	if _long_text_panel != null and is_instance_valid(_long_text_panel):
		_long_text_panel.close()
		_long_text_panel = null
	closed.emit()
	queue_free()


# 变量输入框（Label + LineEdit + [长文本] + 修改 一行）
# 注意：LineEdit 不再自动写回（无 text_submitted / focus_exited 提交），
#       必须在行尾按下「修改」按钮才会发信号写值。
func _make_field(var_name: String, label_text: String, is_array: bool) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var lab := Label.new()
	lab.text = label_text
	# 固定标签列宽，保证各行输入框左端对齐；clip_text 防止更长的标签把布局顶宽
	lab.custom_minimum_size = Vector2(LABEL_W, 0)
	lab.clip_text = true
	lab.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	lab.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	var fnt := UIStyle.get_cjk_font()
	if is_instance_valid(fnt):
		lab.add_theme_font_override("font", fnt)
	var le := LineEdit.new()
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 输入框宽度上限：防止面板加宽后输入框被拉得过长（超出可用阅读宽度）
	# ★ 踩过的坑：custom_maximum_size 的 **y=0 不等于"不限"**，Godot 会真的把高度钳成 0，
	#   于是输入框彻底看不见（实测 y=(300,0)→高0，(300,28)→高28，不设→高31）。
	#   所以纵向必须给一个足够大的上限，不能写 0。
	le.custom_maximum_size = Vector2(INPUT_MAX_W, 10000.0)
	# 文件路径类字段：占位提示默认填写相对路径（res:// 项目相对）
	match var_name:
		"avatar_path": le.placeholder_text = "res://textures/（头像图片相对路径）"
		"event_image_path": le.placeholder_text = "res://textures/（事件配图相对路径）"
		"voice": le.placeholder_text = "auto = 逐字/逐词泡泡声；auto:res://audio/x.wav = 同样的逐字/逐词但换成该音频；或 res://audio/（声音文件相对路径，整段播放）"
		"line_effect": le.placeholder_text = "点击台词时执行的效果（DSL，如 /add_var player_profile.json:tags = \"正义\"）"
		_: le.placeholder_text = label_text
	le.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		le.add_theme_font_override("font", fnt)
	UIStyle.apply_line_edit_style(le)
	if is_array:
		le.text = JSON.stringify(DialogueManager.get_value(var_name))
	else:
		le.text = str(DialogueManager.get_value(var_name))
	row.add_child(lab)
	row.add_child(le)
	# 文件路径类栏位：右侧挂文件夹按钮（系统对话框选文件 → 回填 res:// 相对路径）
	if PATH_FIELDS.has(var_name):
		var pd: Array = PATH_FIELDS[var_name]
		UIPathPicker.attach(le, String(pd[0]), {
			"exts": String(pd[1]), "label": String(pd[2]), "title": String(pd[3]),
		})
	_fields[var_name] = le
	# 长文本字段（台词栏 / 事件内容）→ 追加「长文本」按钮，打开长文本输入窗
	# （该窗只把内容写回 LineEdit，仍需按「修改」才写值）
	if var_name in LONG_TEXT_FIELDS:
		var lb := UIBtn.new()
		lb.name = "LongText_" + var_name
		lb.set_id("long_" + var_name)
		lb.set_label("长文本")
		lb.custom_minimum_size = Vector2(LONG_BTN_W, UIStyle.BTN_HEIGHT)
		lb.size = Vector2(LONG_BTN_W, UIStyle.BTN_HEIGHT)
		lb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		lb.pressed_id.connect(_on_long_text_pressed.bind(var_name, le))
		row.add_child(lb)
	# 「修改」按钮（每个输入框都有）：按下 → 发 field_value_requested 信号 → 写值
	var ab := UIBtn.new()
	ab.name = "Apply_" + var_name
	ab.set_id("apply_" + var_name)
	ab.set_label("修改")
	ab.custom_minimum_size = Vector2(APPLY_BTN_W, UIStyle.BTN_HEIGHT)
	ab.size = Vector2(APPLY_BTN_W, UIStyle.BTN_HEIGHT)
	ab.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ab.pressed_id.connect(_on_apply_pressed.bind(var_name, is_array, le))
	row.add_child(ab)
	return row


# ---- 长文本编辑窗（复用 UILongTextInputPanel）----
# 独立 CanvasLayer（layer 130）：长文本窗需要浮在调试面板之上，且不受调试面板显隐影响
func _ensure_popup_layer() -> CanvasLayer:
	if _popup_layer == null or not is_instance_valid(_popup_layer):
		_popup_layer = CanvasLayer.new()
		_popup_layer.name = "DebugPopupLayer"
		_popup_layer.layer = 130
		add_child(_popup_layer)
		# 长文本窗也是「面板」：跟随设置里的 UI 缩放
		UIStyle.watch_ui_scale(_popup_layer)
	return _popup_layer


func _on_long_text_pressed(_id: String, var_name: String, le: LineEdit) -> void:
	# 已有窗口 → 先关闭（只把内容写回 LineEdit，不写值），再开新的
	if _long_text_panel != null and is_instance_valid(_long_text_panel):
		_long_text_panel.close()
	_long_text_panel = UILongTextInputPanel.new()
	_ensure_popup_layer().add_child(_long_text_panel)
	_long_text_panel.closed.connect(_on_long_text_closed.bind(var_name, le))
	print("[DebugManager] 打开长文本编辑: %s" % var_name)
	_long_text_panel.open(le, str(DialogueManager.get_value(var_name)))


func _on_long_text_closed(var_name: String, le: LineEdit) -> void:
	_long_text_panel = null
	# 长文本窗已把内容写回 LineEdit；按新规则 **不自动写值**，
	# 需要用户确认后按该行「修改」按钮才会写进 DialogueManager。
	if is_instance_valid(le):
		print("[DebugManager] 长文本已回填输入框，待按「修改」写值: %s (len=%d)" % [var_name, le.text.length()])


# ---- 写值：唯一入口是 field_value_requested 信号 ----

# 「修改」按钮按下 → 解析文本并发信号（不直接写 DialogueManager）
func _on_apply_pressed(_id: String, var_name: String, is_array: bool, le: LineEdit) -> void:
	if not is_instance_valid(le):
		return
	var text: String = le.text
	if is_array:
		# 用 JSON.new().parse() 而非 JSON.parse_string()：
		# 后者解析失败会往 Output 抛引擎 ERROR（红字），这里属「用户输入不合法」的正常分支，
		# 只需自己提示，不应污染引擎日志。
		var json := JSON.new()
		var err: int = json.parse(text)
		if err != OK:
			print("[DebugManager] JSON 解析失败（第 %d 行）: %s = %s" % [json.get_error_line(), var_name, text])
			return
		if not (json.data is Array):
			print("[DebugManager] 需要 JSON 数组，未修改: %s = %s" % [var_name, text])
			return
		Debug.field_value_requested.emit(var_name, json.data)
	else:
		Debug.field_value_requested.emit(var_name, text)


# ===================== 冒泡对话（按积木 ID 编辑该积木的「冒泡对话框」）=====================
# 设计：调试面板里「选择ID」下拉列出场景内所有积木 ID（每页 10 个，翻页环绕）；
# 选中 ID 后，「冒泡文本」输入框按「修改」即写入该积木名为「冒泡对话框」的文本框的 text_def。
# 若该积木尚无冒泡对话框，先按 text_box.gd 的 bubble 预设创建，再写入文本。

# 构建「冒泡对话」区块：标题 + 选择ID 行（下拉 + 上/下页）+ 冒泡文本 行（输入框 + 修改）
func _add_bubble_section(vbox: VBoxContainer) -> void:
	var fnt := UIStyle.get_cjk_font()

	var title := Label.new()
	title.text = "冒泡对话"
	title.add_theme_color_override("font_color", Color(0.8, 0.92, 1.0))
	title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		title.add_theme_font_override("font", fnt)
	vbox.add_child(title)

	# 选择ID 行：下拉（当前页 10 个）+ 上/下页按钮
	var id_row := HBoxContainer.new()
	id_row.add_theme_constant_override("separation", 4)
	id_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var id_lab := Label.new()
	id_lab.text = "选择ID"
	id_lab.custom_minimum_size = Vector2(LABEL_W, 0)
	id_lab.clip_text = true
	id_lab.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	id_lab.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		id_lab.add_theme_font_override("font", fnt)
	id_row.add_child(id_lab)

	_id_select = OptionButton.new()
	_id_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_id_select.mouse_filter = Control.MOUSE_FILTER_STOP
	# 项文本含完整数字 ID（+字符串 ID），较长；关掉\"按最长项自适应宽度\"，
	# 否则下拉会被最长项撑宽、把整行挤出面板。
	_id_select.fit_to_longest_item = false
	_id_select.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		_id_select.add_theme_font_override("font", fnt)
	_id_select.item_selected.connect(_on_id_selected)
	id_row.add_child(_id_select)

	# 桌面穿透模式下下拉展开会被 SetWindowRgn 裁切，注册到 MousePassRunner，
	# 使其展开期间临时满屏(整窗可绘制)、关闭后恢复，避免下拉超出面板被裁没。
	var pop := _id_select.get_popup()
	# 用信号（而非 visible / 遍历树）跟踪「弹窗是否展开」——见 _id_popup_open 说明
	pop.about_to_popup.connect(_on_id_popup_opened)
	pop.popup_hide.connect(_on_id_popup_closed)
	MousePassRunner.suspend_passthrough_for_popup(pop)

	# 「调试」按钮：打开下拉所选 ID 积木的「积木属性」菜单
	# （对带「始终不可选」等的积木也有效——绕过选中闸门，避免无法调试铺满全屏的覆盖积木）
	var dbg_btn := UIBtn.new()
	dbg_btn.set_id("debug_id")
	dbg_btn.set_label("调试")
	dbg_btn.custom_minimum_size = Vector2(APPLY_BTN_W, UIStyle.BTN_HEIGHT)
	dbg_btn.size = Vector2(APPLY_BTN_W, UIStyle.BTN_HEIGHT)
	dbg_btn.pressed_id.connect(_on_id_debug_pressed)
	id_row.add_child(dbg_btn)

	# 翻页按钮已集成进下拉菜单（见 _refresh_id_list），此处不再单独列出
	vbox.add_child(id_row)

	# 输入ID 行：直接输入已知积木 ID 并定位（回车 或 「定位」按钮）
	var jump_row := HBoxContainer.new()
	jump_row.add_theme_constant_override("separation", 4)
	jump_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var jump_lab := Label.new()
	jump_lab.text = "输入ID"
	jump_lab.custom_minimum_size = Vector2(LABEL_W, 0)
	jump_lab.clip_text = true
	jump_lab.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	jump_lab.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		jump_lab.add_theme_font_override("font", fnt)
	jump_row.add_child(jump_lab)

	_id_jump_input = LineEdit.new()
	_id_jump_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_id_jump_input.placeholder_text = "输入ID定位(数字或BedRockXU等)"
	_id_jump_input.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		_id_jump_input.add_theme_font_override("font", fnt)
	UIStyle.apply_line_edit_style(_id_jump_input)
	_id_jump_input.text_submitted.connect(_on_id_jump_submitted)
	jump_row.add_child(_id_jump_input)

	var jb := UIBtn.new()
	jb.set_id("jump_id")
	jb.set_label("定位")
	jb.custom_minimum_size = Vector2(APPLY_BTN_W, UIStyle.BTN_HEIGHT)
	jb.size = Vector2(APPLY_BTN_W, UIStyle.BTN_HEIGHT)
	jb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	jb.pressed_id.connect(_on_jump_id_pressed)
	jump_row.add_child(jb)
	vbox.add_child(jump_row)

	# 定位状态行（可见反馈）：成功「✓ 已定位到 …」/ 失败「✗ 不存在 …」。
	# 手工换行、不 autowrap（autowrap 会让高度测不准导致行重叠）。
	_id_status_lab = Label.new()
	_id_status_lab.text = ""
	_id_status_lab.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		_id_status_lab.add_theme_font_override("font", fnt)
	_id_status_lab.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	vbox.add_child(_id_status_lab)

	# 冒泡文本 行：输入框 + 修改
	var tb_row := HBoxContainer.new()
	tb_row.add_theme_constant_override("separation", 4)
	tb_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tb_lab := Label.new()
	tb_lab.text = "冒泡文本"
	tb_lab.custom_minimum_size = Vector2(LABEL_W, 0)
	tb_lab.clip_text = true
	tb_lab.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	tb_lab.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		tb_lab.add_theme_font_override("font", fnt)
	tb_row.add_child(tb_lab)

	_bubble_text_input = LineEdit.new()
	_bubble_text_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bubble_text_input.placeholder_text = "冒泡对话框文本内容"
	_bubble_text_input.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		_bubble_text_input.add_theme_font_override("font", fnt)
	UIStyle.apply_line_edit_style(_bubble_text_input)
	tb_row.add_child(_bubble_text_input)

	var ab := UIBtn.new()
	ab.set_id("apply_bubble_text")
	ab.set_label("修改")
	ab.custom_minimum_size = Vector2(APPLY_BTN_W, UIStyle.BTN_HEIGHT)
	ab.size = Vector2(APPLY_BTN_W, UIStyle.BTN_HEIGHT)
	ab.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ab.pressed_id.connect(_on_bubble_text_apply)
	tb_row.add_child(ab)
	vbox.add_child(tb_row)


# 小按钮（固定宽度）已弃用：翻页按钮集成进下拉菜单，不再需要独立小按钮


# 「选择ID」列表的 ID 来源：**注册表优先，场景树兜底**。
# ★ 为什么要有兜底：BlockManager._registry 与场景树可能脱同步（积木明明在桌上、
#   注册表却是空的），此时原实现会让下拉显示「（无积木）」，看起来像"积木全没了"。
#   直接按场景树（group "block" + 有效 + id>0）收集即可列出真实存在的积木。
func _id_list_source() -> Array[int]:
	var ids: Array[int] = BlockManager.get_all_ids()
	if not ids.is_empty():
		_warned_registry_fallback = false
		return ids
	var from_tree := _collect_ids_from_tree()
	if not from_tree.is_empty() and not _warned_registry_fallback:
		_warned_registry_fallback = true
		push_warning("[DebugManager] BlockManager 注册表为空，但场景内有 %d 块积木 → 「选择ID」已改为按场景树列出" % from_tree.size())
	return from_tree


# 直接从场景树收集积木 ID（升序）。仅作注册表不可用时的兜底来源。
func _collect_ids_from_tree() -> Array[int]:
	var out: Array[int] = []
	if get_tree() == null:
		return out
	for b in get_tree().get_nodes_in_group("block"):
		if is_instance_valid(b) and b is Block and int(b.id) > 0:
			out.append(int(b.id))
	out.sort()
	return out


# 下拉当前是否停在「（无积木）」占位（或压根没填充），而来源其实**非空**。
# 这种情况只可能是"陈旧内容"（重刷被卡住），补刷不会丢用户选择 → 可无视展开标志直接重建。
func _is_placeholder_stale() -> bool:
	if _id_select == null or not is_instance_valid(_id_select):
		return false
	if _id_select.item_count > 0 and not _id_select.get_item_text(0).contains("无积木"):
		return false   # 当前显示的是真实 ID，属"真展开"，不动它
	return not _id_list_source().is_empty()


# 计算当前按 ID 枚举的总页数（0 个积木 → 0 页）
func _id_page_count() -> int:
	var total: int = _id_list_source().size()
	if total <= 0:
		return 0
	return int(ceil(total / float(ID_PAGE_SIZE)))


# 刷新 ID 下拉：按当前页填充 OptionButton（最多 10 项）；
# 翻页项（上一页/下一页）集成进下拉菜单顶部，item_id 用负数与真实积木 ID 区分；
# ★ 只在「弹窗已关闭」时重建：可见状态下 clear()/add_item() 会让 PopupMenu 的尺寸与命中表
#   过期 → 下拉能打开但点任何项都没反应、无法翻页（“卡住”）。故开头的弹窗若可见先 hide()。
# ★ 保留原有选中积木（它仍在当前页时继续选中），避免自动重刷把用户的选择冲掉。
func _refresh_id_list() -> void:
	if _id_select == null or not is_instance_valid(_id_select):
		return
	if _id_popup_open:
		# 先关弹窗：可见状态下 clear()/add_item() 会让 PopupMenu 的命中表过期（点不动的“卡住”）
		_id_select.get_popup().hide()
		_id_popup_open = false
	# 本次重建即完成「补刷」，清掉脏标记（超时计时一并归零）
	_id_list_dirty = false
	_id_dirty_time = 0.0
	var prev_sel: int = _selected_block_id
	# ★ 统一来源：注册表优先，为空时退回场景树（见 _id_list_source 说明）
	var ids: Array[int] = _id_list_source()
	_seen_registry_version = BlockManager.registry_version
	var total: int = ids.size()
	# 页数直接用本次拿到的 ids 算，避免同一次刷新里两次取值不一致
	var pages: int = 0 if total <= 0 else int(ceil(total / float(ID_PAGE_SIZE)))
	_id_page = clampi(_id_page, 0, pages - 1) if pages > 0 else 0
	_id_select.clear()
	_id_page_ids.clear()
	if total == 0:
		_id_select.add_item("（无积木）", -1)
		_selected_block_id = -1
		if _bubble_text_input != null:
			_bubble_text_input.text = ""
		# 只在「真的一块积木都没有」时才走到这里；把判定依据打进控制台，便于事后定位
		print("[DialogueDebugPanel] 「选择ID」为空：注册表=%d 场景积木组=%d 当前场景=%s"
			% [BlockManager.count(), get_tree().get_nodes_in_group("block").size(),
				str(get_tree().current_scene)])
		return
	var has_pages: bool = pages > 1
	# 翻页项集成进下拉菜单（仅多页时出现；item_id 负数，区别于真实积木 ID）
	if has_pages:
		_id_select.add_item("← 上一页 (第 %d/%d 页)" % [_id_page + 1, pages], ID_PAGE_PREV)
		_id_select.add_item("下一页 → (第 %d/%d 页)" % [_id_page + 1, pages], ID_PAGE_NEXT)
		_id_select.add_separator()
	var start: int = _id_page * ID_PAGE_SIZE
	var end: int = mini(start + ID_PAGE_SIZE, total)
	for i in range(start, end):
		# item 文本：数字 ID 必显示（「输入ID」定位时用户靠它核对是否跳对）；
		# 有字符串 ID（BedRockXU / 收藏夹(560,120)U 等）时追加在括号内，便于两种 ID 都能对上号。
		var b: Block = BlockManager.get_block(ids[i])
		var label: String = str(ids[i])
		if b != null and b.string_id != "":
			label = "%s (%s)" % [label, b.string_id]
		# item_id 存本页内下标（真实 ID 超 int32 会被截断，见 _id_page_ids 说明）
		_id_page_ids.append(ids[i])
		_id_select.add_item(label, _id_page_ids.size() - 1)
	# 选中项：优先保留之前选中的积木（仍在当前页时）；否则退回本页首个。
	var local: int = -1
	if prev_sel > 0:
		var gi: int = ids.find(prev_sel)
		if gi >= start and gi < end:
			local = gi - start
	if local < 0:
		local = 0
	_selected_block_id = ids[start + local]
	# 跳过顶部翻页项 + 分隔项（共 3 项）
	_id_select.select(local + (3 if has_pages else 0))
	# 只有选中项真的变了才回填冒泡文本，避免自动重刷把用户正在编辑的内容冲掉
	if _selected_block_id != prev_sel:
		_load_bubble_text_into_input(_selected_block_id)


# 下拉选择变化：翻页项 → 调整页码并立即重开弹窗（见 _goto_page，使翻页不关闭下拉）；
# 真实积木 ID 项 → 记录选中积木 ID，并载入其当前冒泡文本到输入框。
func _on_id_selected(_idx: int) -> void:
	if _id_select == null or not is_instance_valid(_id_select):
		return
	var sel: int = _id_select.get_selected_id()
	if sel == ID_PAGE_PREV:
		call_deferred("_goto_page", -1)
		return
	if sel == ID_PAGE_NEXT:
		call_deferred("_goto_page", 1)
		return
	# sel = 本页内下标（非真实 ID）→ 从 _id_page_ids 反查真实积木 ID
	if sel < 0 or sel >= _id_page_ids.size():
		return
	_selected_block_id = _id_page_ids[sel]
	# ★ 把所选积木的 ID 回写到「输入ID」定位框，方便用户核对/再次定位同一积木。
	if _id_jump_input != null and is_instance_valid(_id_jump_input):
		_id_jump_input.text = _id_label_for(_selected_block_id)
	_load_bubble_text_into_input(_selected_block_id)


# 从「选择ID」下拉当前选中项取真实积木 ID（item_id 是本页内下标，需反查 _id_page_ids）；
# 未选中 / 选中翻页项 / 下标越界 → 返回 0。
func _current_selected_id() -> int:
	if _id_select == null or not is_instance_valid(_id_select):
		return 0
	var sel: int = _id_select.get_selected_id()
	if sel < 0 or sel >= _id_page_ids.size():
		return 0
	return _id_page_ids[sel]


# 「调试」按钮：对下拉选中的积木 ID，强制打开其「积木属性」菜单（绕过选中闸门）
# 注意：不能直接用 _id_select.get_selected_id() 当积木 ID —— 下拉 item_id 存的是「本页内下标」
# （真实时间基 ID 超 int32 会被截断），且后台枚举刷新后 popup 内部选中会与真实注册 id 脱同步
# → 返回过期/截断值 → get_block 为 null → 打不开。改用显式维护的 _selected_block_id。
func _on_id_debug_pressed(_id: String) -> void:
	var sel_id: int = _selected_block_id
	if sel_id <= 0:
		# 兜底：从下拉当前选中项（item_id = 本页内下标）反查真实 ID
		sel_id = _current_selected_id()
	if sel_id <= 0:
		print("[DebugManager] 调试：请先在「选择ID」选一个积木")
		return
	# 列出可能已被后台枚举回收（选中 id 过期）→ 重建列表后再取一次
	if BlockManager.get_block(sel_id) == null:
		_refresh_id_list()
		sel_id = _selected_block_id
		if BlockManager.get_block(sel_id) == null:
			print("[DebugManager] 调试：ID %d 对应的积木不存在（可能已被后台枚举移除）" % sel_id)
			return
	var scene := get_tree().current_scene
	if scene != null and scene.has_method("open_block_editor_by_id"):
		scene.open_block_editor_by_id(sel_id)


# 翻页并重刷下拉；重建后**重新打开**弹窗，使「翻页」不关闭已展开的下拉。
# 重建前 _refresh_id_list 会先 hide()（可见状态下 clear/add_item 会让命中表过期 → 点不动的“卡住”），
# 故这里在重建后再 show_popup()。
# delta=-1 上一页 / +1 下一页；页码环绕（末页下页→首页，首页上页→末页）。
func _goto_page(delta: int) -> void:
	var pages: int = _id_page_count()
	if pages <= 0:
		return
	_id_page = (_id_page + delta + pages) % pages
	_refresh_id_list()
	if _id_select != null and is_instance_valid(_id_select):
		call_deferred("_reopen_id_popup")


# 重新展开「选择ID」弹窗（翻页后调用）。若弹窗已经开着则不动，避免重复 popup。
func _reopen_id_popup() -> void:
	if _id_select == null or not is_instance_valid(_id_select):
		return
	if _id_popup_open:
		return
	_id_select.show_popup()


func _on_id_popup_opened() -> void:
	_id_popup_open = true


func _on_id_popup_closed() -> void:
	_id_popup_open = false


# 把选中积木的当前冒泡对话框文本载入输入框（无积木 / 无冒泡框 → 清空）
func _load_bubble_text_into_input(id: int) -> void:
	if _bubble_text_input == null or not is_instance_valid(_bubble_text_input):
		return
	var block = BlockManager.get_block(id)
	if block == null:
		_bubble_text_input.text = ""
		return
	var tb = block.find_text_box("冒泡对话框")
	_bubble_text_input.text = tb.text_def if tb != null else ""


# 输入已知 ID 直接定位（支持两种）：
#   数字 ID（时间基，如 20260916205039）→ 校验存在后跳到所在页并选中该项；
#   字符串 ID（如 BedRockXU / 收藏夹(560,120)U）→ 反查对应积木后同样跳页选中。
# 成功/失败都会写入「输入ID」下方的状态行（**可见**反馈；错误不再只 print 到控制台）。
# ★ 反查与页码都走 **注册表优先、场景树兜底** 的同一来源（与「选择ID」下拉一致），
#   避免 BlockManager 注册表与场景树脱同步（积木在桌但注册表为空，见 _id_list_source 说明）
#   时出现「下拉看得到、定位却报『不在注册表』」。
func _jump_to_id() -> void:
	if _id_jump_input == null or not is_instance_valid(_id_jump_input):
		return
	var text: String = _id_jump_input.text.strip_edges()
	if text.is_empty():
		_set_id_status("请输入 ID（数字或字符串）", false)
		print("[DebugManager] 定位ID：请输入数字 ID 或字符串 ID（如 BedRockXU）")
		return
	# 先按数字 ID 解析；不是数字再按字符串 ID 反查。注册表查不到时退回场景树。
	var block := _find_block_any(text)
	if block == null:
		var hint: String = "场景内没有这个数字 ID 的积木" if text.is_valid_int() else "没有字符串 ID 为 %s 的积木" % text
		_set_id_status("✗ 定位失败：%s" % hint, false)
		print("[DebugManager] 定位ID：'%s' 不存在（%s）" % [text, hint])
		return
	var id: int = block.id
	# 页码在 **同一来源**（注册表优先、场景树兜底）里算，保证与下拉显示一致
	var ids: Array[int] = _id_list_source()
	var idx: int = ids.find(id)
	if idx < 0:
		_set_id_status("✗ 定位失败：ID %s 未在注册表中" % text, false)
		return
	# 目标页 + 目标选中：先写 _selected_block_id，由 _refresh_id_list 保留并选中它
	_id_page = int(idx / ID_PAGE_SIZE)
	_selected_block_id = id
	_refresh_id_list()
	# 下拉若正开着会被 _refresh_id_list 收起（定位的是上方下拉的显示项，不需要展开遮挡）
	_load_bubble_text_into_input(id)
	var show_txt: String = str(id)
	if block.string_id != "":
		show_txt = "%s (%s)" % [str(id), block.string_id]
	_set_id_status("✓ 已定位到 %s（第 %d/%d 页）" % [show_txt, _id_page + 1, _id_page_count()], true)
	print("[DebugManager] 定位ID：已跳到 '%s'（第 %d 页）" % [text, _id_page + 1])


# 生成「输入ID」框的显示文本：有字符串 ID 用字符串 ID（更直观且可定位），否则用数字 ID。
func _id_label_for(id: int) -> String:
	var b: Block = BlockManager.get_block(id)
	if b != null and b.string_id != "":
		return b.string_id
	return str(id)


# 按用户输入反查积木：先查注册表（数字 ID / 字符串 ID），查不到再退回场景树枚举。
func _find_block_any(text: String) -> Block:
	if text.is_valid_int():
		var b: Block = BlockManager.get_block(int(text))
		if b != null:
			return b
		return _find_in_tree_by_numeric(int(text))
	var b2: Block = BlockManager.get_block_by_string_id(text)
	if b2 != null:
		return b2
	return _find_in_tree_by_string(text)


# 场景树兜底 1：按数字 ID 找积木
func _find_in_tree_by_numeric(id: int) -> Block:
	if get_tree() == null:
		return null
	for b in get_tree().get_nodes_in_group("block"):
		if is_instance_valid(b) and b is Block and int(b.id) == id:
			return b
	return null


# 场景树兜底 2：按字符串 ID 找积木
func _find_in_tree_by_string(sid: String) -> Block:
	if get_tree() == null:
		return null
	for b in get_tree().get_nodes_in_group("block"):
		if is_instance_valid(b) and b is Block and b.string_id == sid:
			return b
	return null


# 写「输入ID」下方状态行（ok=true 绿、false 红）。手工换行、每行 ≤20 中字，避免高度测不准。
func _set_id_status(msg: String, ok: bool) -> void:
	if _id_status_lab == null or not is_instance_valid(_id_status_lab):
		return
	_id_status_lab.text = msg
	_id_status_lab.add_theme_color_override("font_color",
		Color(0.45, 1.0, 0.55) if ok else Color(1.0, 0.52, 0.42))


func _on_id_jump_submitted(_text: String) -> void:
	_jump_to_id()


func _on_jump_id_pressed(_id: String) -> void:
	_jump_to_id()


# 翻页逻辑已并入下拉菜单（见 _refresh_id_list / _on_id_selected），不再有独立按钮


# 冒泡文本「修改」：写入选中积木的「冒泡对话框」文本框；
# 积木无冒泡对话框时，先按 bubble 预设创建，再写文本。
func _on_bubble_text_apply(_id: String) -> void:
	if _bubble_text_input == null or not is_instance_valid(_bubble_text_input):
		return
	var id: int = _selected_block_id
	if id <= 0:
		print("[DebugManager] 冒泡文本：未选择积木 ID（先在「选择ID」里选一个）")
		return
	var block = BlockManager.get_block(id)
	if block == null:
		print("[DebugManager] 冒泡文本：ID %d 对应的积木不存在（可能已销毁）" % id)
		return
	var tb = block.find_text_box("冒泡对话框")
	if tb == null:
		# 创建冒泡对话框后再写文本
		var d: Dictionary = TextBox.preset_dict("bubble", block.width, block.height)
		if d.is_empty():
			print("[DebugManager] 冒泡文本：预设 'bubble' 缺失，无法创建")
			return
		tb = TextBox.new()
		tb.name = str(d["name"])
		tb.width = float(d["width"])
		tb.height = float(d["height"])
		tb.center_offset = Vector2(float(d["cx"]), float(d["cy"]))
		tb.border_color = _hex_color(str(d["border_color"]))
		tb.fill_color = _hex_color(str(d["fill_color"]))
		tb.fill_source = int(d["fill_source"])
		tb.fill_image_path = str(d["fill_image_path"])
		tb.rotation_deg = float(d["rotation_deg"])
		tb.follow_block_rotation = bool(d["follow_block_rotation"])
		tb.text_def = str(d["text_def"])
		tb.hide_when_empty = bool(d["hide_when_empty"])
		block.add_text_box(tb)
		print("[DebugManager] 冒泡文本：为积木 %d 创建冒泡对话框（%dx%d，黑边白底）" % [id, int(tb.width), int(tb.height)])
	tb.text_def = _bubble_text_input.text
	block.refresh_text_boxes()
	_bubble_text_input.text = tb.text_def
	print("[DebugManager] 冒泡文本：已写入积木 %d 的冒泡对话框：%s" % [id, tb.text_def])


# 颜色字符串（#RRGGBBAA / #RRGGBB）→ Color；解析失败兜底白。
func _hex_color(s: String, fallback: Color = Color.WHITE) -> Color:
	return Color(s.strip_edges())

# 「选择ID」下拉自动重刷：注册表变化 → 置脏 → 在下面几个安全出口之一重建
func _process(dt: float) -> void:
	# ★★ 非调试模式 → 直接不干活。
	#   本页虽然挂在**独立的 CanvasLayer（135）**上、不受主调试面板 `_panel.visible` 影响，
	#   但它是彻头彻尾的调试工具：「选择ID」列表每次重建都要 `BlockManager.get_all_ids()`
	#   + 遍历场景树收集 + 重填下拉，而注册表版本在图标/屏障周期性重建时**会一直变**。
	#   旧实现只在 debug_manager 侧 `set_process(on)`，这个独立页面在非调试模式下照样每帧跑
	#   → 用户要求的「不打开调试模式下也要停止」。
	if Debug != null and not Debug.debug_mode:
		return
	# 积木注册表发生变化（桌面图标/屏障会周期性重建、积木增删）→ 自动重刷「选择ID」下拉。
	# 不刷的话下拉里会残留已销毁的 ID，点选后「没反应」、也无法换项（用户报的"卡住"之一）。
	# ★ 这里只**置脏**，不在弹窗真展开时重建（重建会清空命中表 → 点不动）；
	#   真正的重建统一走下面这个出口，保证任何情况下都不会永久停在旧内容。
	if BlockManager.registry_version != _seen_registry_version:
		if not _id_list_dirty:
			_id_dirty_time = 0.0   # 只在「干净→脏」时归零，避免持续变更把超时计时器一直喂回 0
		_id_list_dirty = true
	if _id_list_dirty:
		var verifiable: bool = DisplayServer.get_name() != "headless"
		var really_open: bool = _id_popup_open
		if verifiable and _id_popup_open and _id_select != null and is_instance_valid(_id_select):
			# 真机下 PopupMenu.visible 可靠 → 用它交叉验证标志，标志卡死时立刻发现
			really_open = _id_select.get_popup().visible
		# ② 下拉当前只显示占位「（无积木）」/从未填充，而来源其实非空 → 陈旧，立刻补刷
		var stale_placeholder: bool = _id_popup_open and _is_placeholder_stale()
		if stale_placeholder or (not _id_popup_open) or (not really_open):
			if _id_popup_open:
				if not really_open:
					push_warning("[DebugManager] 「选择ID」展开标志为 true 但下拉实际未展开 → 视为标志卡死，复位并重刷")
				_id_popup_open = false
			_refresh_id_list()
		else:
			# ③ 弹窗确实开着：不动它（避免打断用户选择），只在测不准的环境下用超时兜底
			_id_dirty_time += dt
			if not verifiable and _id_dirty_time >= ID_LIST_DIRTY_TIMEOUT:
				push_warning("[DebugManager] 「选择ID」弹窗展开标志超过 %.1fs 未闭合，强制重刷下拉（popup_hide 可能丢失）"
					% ID_LIST_DIRTY_TIMEOUT)
				_id_popup_open = false
				_refresh_id_list()


## 最小化 / 还原：折叠只隐藏内容，顶栏（标题 + 拖动把柄 + 最小化 + 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.apply(self, _min_btn, v, _min_btn.get_parent() if is_instance_valid(_min_btn) else null)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
