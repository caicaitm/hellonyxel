# ui/console_panel.gd
# 调试面板的「控制台」组件：统一命令语言（ConsoleCommand）的交互入口。
#
# 交互（参照 MC / 群星 等游戏控制台，按程序员习惯设计）：
#   - 输入框 + 右侧「执行」按钮；回车也可执行。
#   - 输入框上方二级菜单：
#       · 空输入时显示历史指令（最近在前）；
#       · 有输入时显示按前缀匹配的候选命令（/xxx）。
#   - Tab：把高亮候选补全进输入框。
#   - ↑ / ↓：在候选（或空输入时的历史）间移动高亮。
#   - 点击候选：填回输入框（命令类补 `/name `，历史类补完整文本），再回车执行。
#   - 标题栏上的「拖动把柄」（4 向箭头按钮）按住可移动整个控制台面板位置。
#   - 每次执行把「命令 + 结果」回显到输出区。
#
# 所有命令与「事件链按钮效果」「时间轴触发内容」同一套 DSL（见 console_command.gd）。
class_name ConsolePanel
extends Control

const ConsoleCommandScript := preload("res://autoload/console_command.gd")

const PANEL_W: float = 600.0
const PANEL_H: float = 400.0
const TITLE_BAR_H: float = 28.0
const INPUT_H: float = 32.0
const SUGGEST_LIMIT: int = 8          # 候选最多显示条数（避免把面板顶高）

signal closed

# 当前实例（供事件链按钮效果 / 台词点击效果把执行结果回写到同一控制台输出）。
static var current: ConsolePanel = null

var _bg: UIPanel
var _title_label: Label
var _close_btn: UIBtn
var _log_scroll: ScrollContainer
var _log_vbox: VBoxContainer
var _suggest_box: VBoxContainer
var _input: LineEdit
var _exec_btn: UIBtn

var _history: Array[String] = []
var _suggest_items: Array[Button] = []   # 候选按钮（与 _suggest_apply 顺序一致）
var _suggest_apply: Array[String] = []    # 选中某候选后填入输入框的文本
var _suggest_idx: int = -1

var _hl_style: StyleBoxFlat


func _ready() -> void:
	current = self
	_build()
	# 输入行高亮：液态玻璃冰白（半透明纯白轻纱，与面板一致）
	_hl_style = UIStyle.glass_box(Color(1.0, 1.0, 1.0, 0.12), Color(1.0, 1.0, 1.0, 0.0), 4, 0)
	_print_line("[控制台] 输入 /help 查看命令；Tab 补全、↑↓ 选候选、回车/「执行」运行。")
	_refresh_suggestions()


## 把一段命令执行结果回写到控制台输出（与手敲命令同路径）。
## 供 EventChainRunner 按钮效果 / 底部台词点击效果调用，保证「写入与输出一致」。
static func log_lines(lines: Array[String], is_error: bool = false) -> void:
	if current != null and is_instance_valid(current):
		for line in lines:
			current._print_line(line, is_error)



# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build() -> void:
	_bg = UIPanel.new()
	_bg.bind_page_dark_bg()
	_bg.position = Vector2(520.0, 60.0)
	_bg.size = Vector2(PANEL_W, PANEL_H)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	add_child(_bg)
	var fnt := UIStyle.get_cjk_font()

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 4)
	_bg.add_child(root)

	# 标题栏
	var title_row := HBoxContainer.new()
	title_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label = Label.new()
	_title_label.text = "控制台 (Console)"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_title_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		_title_label.add_theme_font_override("font", fnt)
	title_row.add_child(_title_label)
	# 拖动把柄（复用已有 UIDragHandle：带 4 向箭头，按住拖动整个面板）
	var drag_handle := UIDragHandle.new()
	drag_handle.setup(_bg)
	drag_handle.tooltip_text = "拖动以移动控制台"
	title_row.add_child(drag_handle)
	_close_btn = UIBtn.new()
	_close_btn.set_id("console_close")
	_close_btn.set_label("×")
	_close_btn.custom_minimum_size = Vector2(TITLE_BAR_H, TITLE_BAR_H)
	_close_btn.size = Vector2(TITLE_BAR_H, TITLE_BAR_H)
	_close_btn.pressed_id.connect(_on_close)
	_min_btn = UIMinimize.attach(title_row, func(): set_minimized(not _minimized))
	title_row.add_child(_close_btn)
	root.add_child(title_row)

	# 输出日志区
	_log_scroll = ScrollContainer.new()
	_log_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	_log_vbox = VBoxContainer.new()
	_log_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_vbox.add_theme_constant_override("separation", 2)
	_log_scroll.add_child(_log_vbox)
	root.add_child(_log_scroll)

	# 候选 / 历史 列表（位于输入框上方）
	_suggest_box = VBoxContainer.new()
	_suggest_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_suggest_box.add_theme_constant_override("separation", 1)
	_suggest_box.visible = false
	root.add_child(_suggest_box)

	# 输入行：输入框 + 执行按钮
	var input_row := HBoxContainer.new()
	input_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_row.add_theme_constant_override("separation", 4)
	_input = LineEdit.new()
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.placeholder_text = "输入命令，如 /create_block { string_id=\"x\", position=(100,200) }"
	_input.custom_minimum_size = Vector2(0, INPUT_H)
	_input.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		_input.add_theme_font_override("font", fnt)
	UIStyle.apply_line_edit_style(_input)
	_input.text_changed.connect(_on_text_changed)
	_input.text_submitted.connect(_on_submit)
	_input.gui_input.connect(_on_input_gui)
	input_row.add_child(_input)
	_exec_btn = UIBtn.new()
	_exec_btn.set_id("console_exec")
	_exec_btn.set_label("执行")
	_exec_btn.custom_minimum_size = Vector2(64.0, INPUT_H)
	_exec_btn.size = Vector2(64.0, INPUT_H)
	_exec_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_exec_btn.pressed_id.connect(_on_exec_pressed)
	input_row.add_child(_exec_btn)
	root.add_child(input_row)


# ================= 输出 =================

func _print_line(text: String, is_error: bool = false) -> void:
	var lab := Label.new()
	lab.text = text
	lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lab.add_theme_color_override("font_color", Color(1.0, 0.6, 0.55) if is_error else UIStyle.TEXT_DEFAULT)
	lab.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	var fnt := UIStyle.get_cjk_font()
	if is_instance_valid(fnt):
		lab.add_theme_font_override("font", fnt)
	_log_vbox.add_child(lab)
	# 限制日志行数（避免无限增长拖慢）
	while _log_vbox.get_child_count() > 400:
		var c = _log_vbox.get_child(0)
		_log_vbox.remove_child(c)
		c.queue_free()
	_log_scroll.scroll_vertical = 1000000   # 钳到最大 → 滚到底


# ================= 候选 / 历史 =================

func _refresh_suggestions() -> void:
	var text := _input.text.strip_edges()
	if text.is_empty():
		# 空输入：显示历史（最近在前，且去重）
		var disp: Array[String] = []
		var seen: Dictionary = {}
		for i in range(_history.size() - 1, -1, -1):
			var h := _history[i]
			if not seen.has(h):
				seen[h] = true
				disp.append(h)
		_show_suggestions(disp, disp)
	else:
		# 有输入：按前缀匹配命令名（去掉可能的 / 前缀）
		var prefix := text
		if prefix.begins_with("/"):
			prefix = prefix.substr(1)
		var names: Array[String] = ConsoleCommandScript.match_commands(prefix)
		var disp: Array[String] = []
		var app: Array[String] = []
		for n in names:
			disp.append("/" + n)
			app.append("/" + n + " ")
		_show_suggestions(disp, app)


func _show_suggestions(disp: Array[String], app: Array[String]) -> void:
	for c in _suggest_box.get_children():
		c.queue_free()
	_suggest_items.clear()
	_suggest_apply.clear()
	if disp.is_empty():
		_suggest_box.visible = false
		_suggest_idx = -1
		return
	_suggest_box.visible = true
	var limit := mini(disp.size(), SUGGEST_LIMIT)
	for i in limit:
		var btn := Button.new()
		btn.text = disp[i]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.flat = false
		btn.custom_minimum_size = Vector2(0, 22)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
		var fnt := UIStyle.get_cjk_font()
		if is_instance_valid(fnt):
			btn.add_theme_font_override("font", fnt)
		btn.pressed.connect(_on_suggest_pressed.bind(i))
		_suggest_box.add_child(btn)
		_suggest_items.append(btn)
		_suggest_apply.append(app[i])
	_suggest_idx = 0
	_highlight(0)


func _highlight(idx: int) -> void:
	for b in _suggest_items:
		b.remove_theme_stylebox_override("normal")
	if idx >= 0 and idx < _suggest_items.size():
		_suggest_items[idx].add_theme_stylebox_override("normal", _hl_style)


# ================= 交互 =================

func _on_text_changed(_text: String) -> void:
	_refresh_suggestions()


func _on_input_gui(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB:
			get_viewport().set_input_as_handled()
			_apply_suggestion(_suggest_idx)
		elif event.keycode == KEY_UP:
			if _suggest_items.size() > 0:
				get_viewport().set_input_as_handled()
				_highlight((_suggest_idx - 1 + _suggest_items.size()) % _suggest_items.size())
		elif event.keycode == KEY_DOWN:
			if _suggest_items.size() > 0:
				get_viewport().set_input_as_handled()
				_highlight((_suggest_idx + 1) % _suggest_items.size())


func _apply_suggestion(idx: int) -> void:
	if idx < 0 or idx >= _suggest_apply.size():
		return
	_input.text = _suggest_apply[idx]
	_input.caret_column = _input.text.length()
	_input.grab_focus()
	_refresh_suggestions()


func _on_suggest_pressed(idx: int) -> void:
	_apply_suggestion(idx)


func _on_submit(_text: String) -> void:
	_execute()


func _on_exec_pressed(_id: String) -> void:
	_execute()


func _execute() -> void:
	var cmd := _input.text.strip_edges()
	if cmd.is_empty():
		return
	_print_line("> " + cmd)
	if _history.is_empty() or _history.back() != cmd:
		_history.append(cmd)
	var res = ConsoleCommandScript.exec(cmd)
	for line in res.lines:
		_print_line(line, not res.ok)
	_input.text = ""
	_refresh_suggestions()
	_input.grab_focus()
	if res.clear_requested:
		_log_vbox_free_children()


func _log_vbox_free_children() -> void:
	for c in _log_vbox.get_children():
		c.queue_free()


func _on_close(_id: String) -> void:
	closed.emit()


func close() -> void:
	if current == self:
		current = null
	closed.emit()


## 最小化 / 还原：折叠只隐藏内容，顶栏（标题 + 拖动把柄 + 最小化 + 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.apply(self, _min_btn, v, _min_btn.get_parent() if is_instance_valid(_min_btn) else null)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
