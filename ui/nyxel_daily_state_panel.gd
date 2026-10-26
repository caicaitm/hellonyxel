# ui/nyxel_daily_state_panel.gd
# 「荧惑日常状态」页 —— 由调试面板的「荧惑日常状态」按钮打开。
#
# ★ 与「通用 JSON 状态页」(ui/state_view_panel.gd) 的区别：日常状态**不是**一坨原始 JSON，
#   而是按数据模型结构化展示：
#     · 状态条：饱食度 / 精力 / 体力 / 清醒度（0~100，各自配色，过低转红警示）
#     · 集合类文本框：心情 / 欲望（可增删的文本标签集，逐个渲染成「标签片」）
#     · 原始数据：可展开的原始 JSON
#
# 数据来源 = `NyxelDailyState` 单例（读 %文档%/HelloNyxel/Temp/nyxel_daily_state.json）。
# 契约与 StateViewPanel 一致：configure(title, file) → add_child → closed。
#
# ★ 本脚本**不需要 class_name**：debug_manager 通过 STATE_VIEWS 里的 "panel" 字段按路径实例化。
extends Control

signal closed

const PANEL_W: float = 660.0
const PANEL_H: float = 620.0
const TITLE_H: float = 28.0
const BAR_H: float = 20.0
const BAR_LABEL_W: float = 76.0
const BAR_VALUE_W: float = 52.0
# 低于该值 → 状态条转「警示红」
const LOW_THRESHOLD: float = 20.0

# 各状态条配色（键 → 主色）。键来自 NyxelDailyState.BAR_KEYS（单一真源，这里只提供配色）。
const BAR_COLORS: Dictionary = {
	"satiety": Color(1.00, 0.68, 0.30),     # 饱食度：暖橙
	"energy": Color(1.00, 0.86, 0.38),      # 精力：金黄
	"stamina": Color(0.48, 0.88, 0.55),     # 体力：草绿
	"alertness": Color(0.44, 0.82, 1.00),   # 清醒度：冰蓝
}
# 各标签集配色（键 → 主色）
const SET_COLORS: Dictionary = {
	"mood": Color(1.00, 0.64, 0.80),        # 心情：暖粉
	"desire": Color(0.74, 0.65, 1.00),      # 欲望：紫罗兰
}
const LOW_COLOR: Color = Color(1.00, 0.36, 0.36)

# 入树前由 configure() 注入
var _title_text: String = "荧惑日常状态"
var _file_name: String = ""

var _bg: UIPanel
var _title_label: Label
var _path_label: Label
var _scroll: ScrollContainer
var _content: VBoxContainer
var _status: Label
var _reset_btn: UIBtn
var _cjk: FontFile

# 状态条控件引用（键 → ProgressBar / 数值 Label）
var _bar_bars: Dictionary = {}
var _bar_values: Dictionary = {}
# 标签集控件引用（键 → HFlowContainer / 空提示 Label / 计数 Label / 输入框）
var _set_flows: Dictionary = {}
var _set_empty: Dictionary = {}
var _set_counts: Dictionary = {}
var _set_inputs: Dictionary = {}

var _raw_label: Label = null
var _raw_btn: UIBtn = null
var _raw_open: bool = false

var _state: Dictionary = {}
var _missing: bool = false
var _reset_armed: bool = false
var _reset_arm_timer: float = 0.0
const RESET_ARM_SECONDS: float = 3.0


# 必须在 add_child 之前调用（_ready 里才据此建 UI）
func configure(title: String, file_name: String) -> void:
	_title_text = title
	_file_name = file_name


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_cjk = UIStyle.get_cjk_font()
	_build_ui()
	if _singleton() != null and _singleton().has_signal("changed"):
		_singleton().changed.connect(_on_state_changed)
	reload()


func _exit_tree() -> void:
	var s := _singleton()
	if s != null and s.has_signal("changed") and s.changed.is_connected(_on_state_changed):
		s.changed.disconnect(_on_state_changed)


func _process(dt: float) -> void:
	# 「重置」两步确认：3 秒内没有再点就自动撤销武装状态
	if _reset_armed:
		_reset_arm_timer -= dt
		if _reset_arm_timer <= 0.0:
			_reset_armed = false
			if is_instance_valid(_reset_btn):
				_reset_btn.set_label("重置")


# ---- 单例访问 ---------------------------------------------------------------

func _singleton() -> Node:
	return get_node_or_null("/root/NyxelDailyState")


# 状态文件路径（与 StateViewPanel 同款：%文档%/HelloNyxel/Temp/<文件名>）
func resolve_path() -> String:
	var s := _singleton()
	if s != null and s.has_method("resolve_path"):
		return str(s.resolve_path())
	var dir := "D:/Documents/HelloNyxel/Temp"
	if SaveManager != null and SaveManager.has_method("get_temp_dir"):
		dir = str(SaveManager.get_temp_dir())
	if _file_name.is_empty():
		return dir.path_join("nyxel_daily_state.json")
	return dir.path_join(_file_name)


func get_file_name() -> String:
	return _file_name


# ---- UI -------------------------------------------------------------------


# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏控件整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build_ui() -> void:
	var vp := get_viewport()
	var vs: Vector2 = UIStyle.canvas_viewport_size(self) if vp != null else Vector2(1280.0, 720.0)
	size = Vector2(PANEL_W, PANEL_H)
	position = Vector2(maxf(40.0, (vs.x - PANEL_W) * 0.5), maxf(40.0, (vs.y - PANEL_H) * 0.4))

	_bg = UIPanel.new()
	_bg.bind_page_dark_bg()
	_bg.name = "Bg"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
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

	# 关闭
	var close_btn := UIBtn.new()
	close_btn.name = "CloseBtn"
	close_btn.set_id("close")
	close_btn.set_label("×")
	_anchor_top_right(close_btn, -(TITLE_H + UIStyle.PANEL_PADDING), -UIStyle.PANEL_PADDING)
	close_btn.pressed_id.connect(_on_close_pressed)
	add_child(close_btn)
	_min_btn = UIMinimize.attach_anchored(self, close_btn, func(): set_minimized(not _minimized))

	# 刷新
	var refresh_btn := UIBtn.new()
	refresh_btn.name = "RefreshBtn"
	refresh_btn.set_id("refresh")
	refresh_btn.set_label("刷新")
	_anchor_top_right(refresh_btn, -(TITLE_H * 3.0 + UIStyle.PANEL_PADDING + 8.0 + 56.0),
		-(TITLE_H * 2.0 + UIStyle.PANEL_PADDING + 12.0))
	refresh_btn.pressed_id.connect(_on_refresh_pressed)
	add_child(refresh_btn)

	# 重置（两步确认）
	_reset_btn = UIBtn.new()
	_reset_btn.name = "ResetBtn"
	_reset_btn.set_id("reset")
	_reset_btn.set_label("重置")
	_anchor_top_right(_reset_btn, -(TITLE_H * 3.0 + UIStyle.PANEL_PADDING + 8.0 + 56.0 * 2.0 + 6.0),
		-(TITLE_H * 3.0 + UIStyle.PANEL_PADDING + 12.0 + 56.0))
	_reset_btn.pressed_id.connect(_on_reset_pressed)
	add_child(_reset_btn)

	_title_label = Label.new()
	_title_label.name = "TitleLabel"
	_title_label.text = _title_text
	_title_label.position = Vector2(UIStyle.PANEL_PADDING + 2.0, UIStyle.PANEL_PADDING)
	_title_label.custom_minimum_size = Vector2(0.0, TITLE_H)
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", Color(0.8, 0.94, 1.0))
	_title_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 1)
	if is_instance_valid(_cjk):
		_title_label.add_theme_font_override("font", _cjk)
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_title_label)

	_path_label = Label.new()
	_path_label.name = "PathLabel"
	_path_label.text = ""
	_path_label.clip_text = true
	_path_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_path_label.offset_left = UIStyle.PANEL_PADDING
	_path_label.offset_top = TITLE_H + UIStyle.PANEL_PADDING
	_path_label.offset_right = -UIStyle.PANEL_PADDING
	_path_label.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING + 20.0
	_path_label.add_theme_color_override("font_color", Color(0.78, 0.86, 0.95, 0.75))
	_path_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		_path_label.add_theme_font_override("font", _cjk)
	_path_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_path_label)

	var body_top := TITLE_H + UIStyle.PANEL_PADDING + 22.0
	_scroll = ScrollContainer.new()
	_scroll.name = "BodyScroll"
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.offset_left = UIStyle.PANEL_PADDING
	_scroll.offset_top = body_top
	_scroll.offset_right = -UIStyle.PANEL_PADDING
	_scroll.offset_bottom = -(UIStyle.PANEL_PADDING + 24.0)
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_scroll)

	_content = VBoxContainer.new()
	_content.name = "Content"
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 5)
	_scroll.add_child(_content)

	_build_content()

	_status = Label.new()
	_status.name = "StatusLabel"
	_status.text = ""
	_status.clip_text = true
	_status.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_status.offset_left = UIStyle.PANEL_PADDING
	_status.offset_top = -(UIStyle.PANEL_PADDING + 20.0)
	_status.offset_right = -UIStyle.PANEL_PADDING
	_status.offset_bottom = -UIStyle.PANEL_PADDING
	_status.add_theme_color_override("font_color", Color(0.78, 0.86, 0.95, 0.8))
	_status.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		_status.add_theme_font_override("font", _cjk)
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_status)


# 静态结构只建一次（状态条 + 标签集框 + 原始数据区），刷新时**只更新值** ——
# 这样标签集的输入框不会被重建，用户正在输入的内容与焦点都能保住。
func _build_content() -> void:
	var s := _singleton()
	var bar_keys: Array = s.bar_keys() if (s != null and s.has_method("bar_keys")) else ["satiety", "energy", "stamina", "alertness"]
	var set_keys: Array = s.set_keys() if (s != null and s.has_method("set_keys")) else ["mood", "desire"]

	_add_section("状态条")
	for k in bar_keys:
		_content.add_child(_make_bar_row(str(k)))

	_content.add_child(_spacer(6))

	for k in set_keys:
		_content.add_child(_make_set_box(str(k)))

	_content.add_child(_spacer(6))

	# —— 原始数据 ——
	_add_section("原始数据")
	_raw_btn = UIBtn.new()
	_raw_btn.set_id("raw")
	_raw_btn.set_label("查看原始 JSON")
	_raw_btn.custom_minimum_size = Vector2(0.0, UIStyle.BTN_HEIGHT)
	_raw_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_raw_btn.pressed_id.connect(_on_raw_pressed)
	_content.add_child(_raw_btn)

	_raw_label = _mk_label("", -1, Color(0.85, 0.92, 1.0, 0.9))
	_raw_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_raw_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_raw_label.visible = false
	_content.add_child(_raw_label)


# 一行状态条：标签 + 进度条 + 数值
func _make_bar_row(key: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var s := _singleton()
	var label_text: String = str(s.bar_label(key)) if (s != null and s.has_method("bar_label")) else key
	var lab := _mk_label(label_text, 0, Color(0.92, 0.96, 1.0, 0.95))
	lab.custom_minimum_size = Vector2(BAR_LABEL_W, BAR_H)
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lab)

	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.min_value = 0.0
	bar.max_value = 100.0
	bar.value = 0.0
	bar.custom_minimum_size = Vector2(0.0, BAR_H)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_theme_stylebox_override("background", _bar_bg_style())
	row.add_child(bar)

	var val := _mk_label("0", 0, Color(1, 1, 1, 1))
	val.custom_minimum_size = Vector2(BAR_VALUE_W, BAR_H)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(val)

	_bar_bars[key] = bar
	_bar_values[key] = val
	return row


# 一个标签集展示框（标题 + 计数 + 空提示 + 标签片流式容器 + 添加行）
func _make_set_box(key: String) -> Control:
	var s := _singleton()
	var label_text: String = str(s.set_label(key)) if (s != null and s.has_method("set_label")) else key
	var accent: Color = SET_COLORS.get(key, Color(0.7, 0.85, 1.0))

	var box := PanelContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_stylebox_override("panel", UIStyle.glass_box(Color(1, 1, 1, 0.08), accent.lerp(Color(1, 1, 1, 1), 0.25), 8, 1))

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	box.add_child(col)

	# 头部：标题 + 计数
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	var title := _mk_label(label_text, 1, accent)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(title)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	var count := _mk_label("0 项", -1, Color(0.82, 0.90, 1.0, 0.7))
	count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(count)
	col.add_child(head)

	# 空提示
	var empty := _mk_label("（暂无%s标签）" % label_text, -1, Color(0.82, 0.90, 1.0, 0.55))
	empty.visible = false
	col.add_child(empty)

	# 标签片容器（自动换行）
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 6)
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(flow)

	# 添加行：输入框 + 添加按钮
	var add_row := HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 6)
	var inp := LineEdit.new()
	inp.placeholder_text = "输入新的%s标签后回车/点添加" % label_text
	inp.custom_minimum_size = Vector2(0.0, UIStyle.BTN_HEIGHT)
	inp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inp.max_length = 24
	UIStyle.apply_line_edit_style(inp)
	if is_instance_valid(_cjk):
		inp.add_theme_font_override("font", _cjk)
		inp.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	add_row.add_child(inp)
	var add_btn := UIBtn.new()
	add_btn.set_id("add:" + key)
	add_btn.set_label("添加")
	add_btn.custom_minimum_size = Vector2(64.0, UIStyle.BTN_HEIGHT)
	add_btn.pressed_id.connect(_on_add_pressed)
	add_row.add_child(add_btn)
	col.add_child(add_row)

	_set_flows[key] = flow
	_set_empty[key] = empty
	_set_counts[key] = count
	_set_inputs[key] = inp
	return box


# 一个标签片：底色玻璃 + 文本 + 小 × 删除
func _make_chip(key: String, text: String) -> Control:
	var accent: Color = SET_COLORS.get(key, Color(0.7, 0.85, 1.0))
	var chip := PanelContainer.new()
	chip.add_theme_stylebox_override("panel", UIStyle.glass_box(accent.darkened(0.55).lerp(Color(1, 1, 1, 1), 0.35), accent, 8, 1))

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	chip.add_child(h)

	var lab := _mk_label(text, -1, Color(1, 1, 1, 0.98))
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(lab)

	var del := Button.new()
	del.text = "×"
	del.flat = true
	del.custom_minimum_size = Vector2(18.0, 16.0)
	del.focus_mode = Control.FOCUS_NONE
	# ★ flat=true 只抑制「常态」背景；悬停/按下仍会画主题里的 hover/pressed 框 → 会在标签片上
	#   突然冒出一个大方块。这里把三态都置空，只靠文字变色表达悬停。
	del.add_theme_stylebox_override("hover", StyleBoxEmpty.new())
	del.add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
	del.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	del.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	del.add_theme_color_override("font_hover_color", Color(1, 0.55, 0.55, 1.0))
	del.add_theme_color_override("font_pressed_color", Color(1, 0.45, 0.45, 1.0))
	if is_instance_valid(_cjk):
		del.add_theme_font_override("font", _cjk)
	del.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	del.tooltip_text = "移除「%s」" % text
	del.pressed.connect(_on_chip_delete.bind(key, text))
	h.add_child(del)
	return chip


func _anchor_top_right(btn: UIBtn, left_off: float, right_off: float) -> void:
	btn.anchor_left = 1.0
	btn.anchor_top = 0.0
	btn.anchor_right = 1.0
	btn.anchor_bottom = 0.0
	btn.offset_left = left_off
	btn.offset_top = UIStyle.PANEL_PADDING
	btn.offset_right = right_off
	btn.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING


func _mk_label(text: String, size_delta: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + size_delta)
	l.add_theme_color_override("font_color", color)
	if is_instance_valid(_cjk):
		l.add_theme_font_override("font", _cjk)
	return l


func _add_section(title: String) -> void:
	var l := _mk_label(title, 1, Color(0.70, 0.95, 1.0))
	l.custom_minimum_size = Vector2(0.0, 22.0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_content.add_child(l)
	_content.add_child(HSeparator.new())


func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0.0, h)
	return c


func _bar_bg_style() -> StyleBoxFlat:
	var sb := UIStyle.glass_box(Color(0.04, 0.12, 0.22, 0.60), Color(1, 1, 1, 0.10), 6, 1)
	return sb


func _bar_fill_style(color: Color) -> StyleBoxFlat:
	return UIStyle.glass_box(color, color.darkened(0.25), 6, 1)


# ---- 数据 -----------------------------------------------------------------

func reload() -> void:
	var s := _singleton()
	_state = s.read_from_disk() if (s != null and s.has_method("read_from_disk")) else {}
	_missing = not FileAccess.file_exists(resolve_path())
	if _path_label != null and is_instance_valid(_path_label):
		_path_label.text = "文件: %s" % resolve_path()
	_refresh_bars()
	_refresh_sets()
	_refresh_raw()
	_update_status()


func _on_state_changed(_st: Dictionary) -> void:
	# 单例已改（增删标签 / 改数值 / 重置）→ 以磁盘为准重读一次，保证显示与实际落盘一致
	reload()


func _refresh_bars() -> void:
	for key in _bar_bars:
		var bar: ProgressBar = _bar_bars[key]
		var val: Label = _bar_values[key]
		if not (is_instance_valid(bar) and is_instance_valid(val)):
			continue
		var v: float = float(_state.get(key, 0.0))
		bar.value = v
		var accent: Color = BAR_COLORS.get(key, Color(0.6, 0.85, 1.0))
		var low := v <= LOW_THRESHOLD
		var fill := LOW_COLOR if low else accent
		bar.add_theme_stylebox_override("fill", _bar_fill_style(fill))
		val.text = "%d" % int(round(v))
		val.add_theme_color_override("font_color", LOW_COLOR if low else Color(1, 1, 1, 1))


func _refresh_sets() -> void:
	for key in _set_flows:
		var flow: HFlowContainer = _set_flows[key]
		if not is_instance_valid(flow):
			continue
		_clear_children(flow)
		var items: Array = _state.get(key, [])
		if not (items is Array):
			items = []
		var empty: Label = _set_empty[key]
		var count: Label = _set_counts[key]
		if is_instance_valid(empty):
			empty.visible = items.is_empty()
		if is_instance_valid(count):
			count.text = "%d 项" % items.size()
		for t in items:
			flow.add_child(_make_chip(str(key), str(t)))


func _refresh_raw() -> void:
	if _raw_label != null and is_instance_valid(_raw_label):
		_raw_label.text = JSON.stringify(_state, "  ")
		_raw_label.visible = _raw_open
	if _raw_btn != null and is_instance_valid(_raw_btn):
		_raw_btn.set_label("隐藏原始 JSON" if _raw_open else "查看原始 JSON")


func _update_status() -> void:
	var mood: Array = _state.get("mood", [])
	var desire: Array = _state.get("desire", [])
	var mood_n: int = mood.size() if mood is Array else 0
	var desire_n: int = desire.size() if desire is Array else 0
	var updated := str(_state.get("updated_at", ""))
	if _missing:
		_set_status("未找到状态文件（显示默认满状态） · 心情 %d · 欲望 %d" % [mood_n, desire_n])
	elif updated.is_empty():
		_set_status("已读取 · 心情 %d 项 · 欲望 %d 项" % [mood_n, desire_n])
	else:
		_set_status("更新于 %s · 心情 %d 项 · 欲望 %d 项" % [updated, mood_n, desire_n])


func _set_status(t: String) -> void:
	if _status != null and is_instance_valid(_status):
		_status.text = t


func _clear_children(n: Node) -> void:
	# ★ 先 remove_child 再 queue_free（只 queue_free 的旧节点帧末才真离树 → 会与新节点撞名）
	for c in n.get_children():
		n.remove_child(c)
		c.queue_free()


# ---- 交互 -----------------------------------------------------------------

func _on_add_pressed(id: String) -> void:
	if not id.begins_with("add:"):
		return
	var key := id.substr(4)
	var inp: LineEdit = _set_inputs.get(key, null)
	if inp == null or not is_instance_valid(inp):
		return
	var text := inp.text.strip_edges()
	if text.is_empty():
		return
	var s := _singleton()
	if s != null and s.has_method("add_set_item"):
		s.add_set_item(key, text)   # 落盘 + changed → reload()
	inp.text = ""
	inp.grab_focus()


func _on_chip_delete(key: String, text: String) -> void:
	var s := _singleton()
	if s != null and s.has_method("remove_set_item"):
		s.remove_set_item(key, text)   # 落盘 + changed → reload()


func _on_refresh_pressed(_id: String) -> void:
	var s := _singleton()
	if s != null and s.has_method("reload"):
		s.reload()   # 会发 changed → reload()
	else:
		reload()


func _on_raw_pressed(_id: String) -> void:
	_raw_open = not _raw_open
	_refresh_raw()


func _on_reset_pressed(_id: String) -> void:
	if not _reset_armed:
		_reset_armed = true
		_reset_arm_timer = RESET_ARM_SECONDS
		if is_instance_valid(_reset_btn):
			_reset_btn.set_label("确认重置?")
		return
	_reset_armed = false
	if is_instance_valid(_reset_btn):
		_reset_btn.set_label("重置")
	var s := _singleton()
	if s != null and s.has_method("reset"):
		s.reset()   # 会发 changed → reload()


func _on_close_pressed(_id: String) -> void:
	close()


func close() -> void:
	closed.emit()


## 最小化 / 还原：折叠只隐藏内容，标题栏控件（标题 / 把柄 / 最小化 / 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.set_label(_min_btn, v)
	UIMinimize.fold_top_strip(self, v)
	UIMinimize.apply_size(self, v)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
