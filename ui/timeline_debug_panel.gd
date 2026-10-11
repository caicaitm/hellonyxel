# ui/timeline_debug_panel.gd
# 「时间轴」调试面板（由调试面板里的 toggle 打开）。
# 提供计划时间轴系统的可视化调试：
#   · 检查周期（秒，运行时调整）
#   · 当前计划列表（时间 / 属性 / 内容）
#   · 立即检查 / 追加一条 / 清空
# 挂载于独立 CanvasLayer，样式与其它面板统一。
class_name TimelineDebugPanel
extends Control

const W := 460.0
const H := 520.0
const PAD := 12.0

var _panel: UIPanel
var _list: VBoxContainer
var _interval_input: SpinBox
var _status: Label

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	if TimelineManager != null:
		TimelineManager.timeline_changed.connect(_refresh)
	_refresh()


# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build() -> void:
	_panel = UIPanel.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.set_corner_radius(UIStyle.CORNER_RADIUS)
	_panel.set_fill_color(UIStyle.FILL_DEFAULT)
	_panel.set_border_color(UIStyle.BORDER)
	_panel.set_border_width(UIStyle.BORDER_WIDTH)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	var top := HBoxContainer.new()
	top.position = Vector2(PAD, PAD)
	top.size = Vector2(W - PAD * 2.0, 28.0)
	add_child(top)
	var title := Label.new()
	title.text = "时间轴（计划）调试"
	title.add_theme_font_override("font", UIStyle.get_cjk_font())
	title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 3)
	title.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	# 拖动把柄：排在最小化左侧 → 「移动 | 最小化 | 关闭」
	var handle := UIDragHandle.new()
	handle.setup(self)
	handle.tooltip_text = "拖动以移动面板"
	top.add_child(handle)
	var close_btn := UIBtn.new()
	close_btn.custom_minimum_size = Vector2(64.0, 28.0)
	close_btn.set_label("关闭")
	close_btn.pressed_id.connect(func(_id): close())
	_min_btn = UIMinimize.attach(top, func(): set_minimized(not _minimized))
	top.add_child(close_btn)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(PAD, PAD + 36.0)
	scroll.size = Vector2(W - PAD * 2.0, H - PAD - 36.0 - 96.0)
	add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_list)

	# 底部操作区
	var bottom_pos := PAD + 36.0 + (H - PAD - 36.0 - 96.0)
	var ctl := VBoxContainer.new()
	ctl.position = Vector2(PAD, bottom_pos + 8.0)
	ctl.size = Vector2(W - PAD * 2.0, 84.0)
	add_child(ctl)

	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 6)
	var lb := Label.new()
	lb.text = "检查周期(秒)"
	lb.add_theme_font_override("font", UIStyle.get_cjk_font())
	lb.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	lb.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	lb.custom_minimum_size = Vector2(88.0, 30.0)
	row1.add_child(lb)
	_interval_input = SpinBox.new()
	_interval_input.min_value = 1
	_interval_input.max_value = 86400
	_interval_input.step = 1
	_interval_input.value = float(TimelineManager.check_interval_sec) if TimelineManager != null else 300.0
	_interval_input.custom_minimum_size = Vector2(0.0, 30.0)
	_interval_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_interval_input.add_theme_font_override("font", UIStyle.get_cjk_font())
	_interval_input.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	row1.add_child(_interval_input)
	var set_btn := UIBtn.new()
	set_btn.custom_minimum_size = Vector2(56.0, 30.0)
	set_btn.set_label("设置")
	set_btn.pressed_id.connect(func(_id): _apply_interval())
	row1.add_child(set_btn)
	var check_btn := UIBtn.new()
	check_btn.custom_minimum_size = Vector2(70.0, 30.0)
	check_btn.set_label("立即检查")
	check_btn.pressed_id.connect(func(_id):
		TimelineManager.check_now() if TimelineManager != null else null
		_refresh())
	row1.add_child(check_btn)
	ctl.add_child(row1)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	var lb2 := Label.new()
	lb2.text = "触发上限"
	lb2.add_theme_font_override("font", UIStyle.get_cjk_font())
	lb2.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	lb2.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	lb2.custom_minimum_size = Vector2(88.0, 30.0)
	row2.add_child(lb2)
	var max_spin := SpinBox.new()
	max_spin.min_value = 1
	max_spin.max_value = 999
	max_spin.step = 1
	max_spin.value = float(TimelineManager.get_max_simultaneous()) if TimelineManager != null else 10.0
	max_spin.custom_minimum_size = Vector2(0.0, 30.0)
	max_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	max_spin.add_theme_font_override("font", UIStyle.get_cjk_font())
	max_spin.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	max_spin.value_changed.connect(func(v): TimelineManager.set_max_simultaneous(int(v)) if TimelineManager != null else null)
	row2.add_child(max_spin)
	ctl.add_child(row2)

	_status = Label.new()
	_status.add_theme_font_override("font", UIStyle.get_cjk_font())
	_status.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	_status.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_status.text = ""
	ctl.add_child(_status)

	size = Vector2(W, H)
	_center()

func _apply_interval() -> void:
	if TimelineManager != null:
		TimelineManager.check_interval_sec = float(_interval_input.value)

func _refresh() -> void:
	# ★★ 2026-10-05（与 context_menu._clear 同一崩溃取证结论）：**不要在信号派发链里同步 free()**。
	#   本函数有两条「信号内触发」的入口 —— 上面「立即检查」按钮的 pressed_id 回调、
	#   以及 TimelineManager.timeline_changed（check_now() 里就会发）。同步析构刚被点过/
	#   正被 hover 的 Control 正是本项目反复踩到的 native signal 11 制造方式。
	#   子节点先 remove_child → 当场离树，之后 get_children()/计数看到的已是空列表，
	#   不存在"旧行与新行并存"的问题；再 queue_free 让引擎在自己安全的时机析构。
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	if TimelineManager == null:
		_status.text = "（TimelineManager 未就绪）"
		return
	var evs: Array = TimelineManager.events
	if evs.is_empty():
		_status.text = "计划为空"
		var e := Label.new()
		e.text = "（空）"
		e.add_theme_font_override("font", UIStyle.get_cjk_font())
		e.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
		e.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
		_list.add_child(e)
		return
	for e in evs:
		var props: Dictionary = e.get("props", {})
		_status.text = "共 %d 条 · 检查周期 %.0fs · 上限 %d" % [
			evs.size(), TimelineManager.check_interval_sec, TimelineManager.get_max_simultaneous()]
		var row := Label.new()
		var c := str(e.get("content", ""))
		var pstr := ""
		for k in props:
			pstr += "%s=%s " % [k, props[k]]
		row.text = "%s  (%s) → %s" % [e.get("time_str", "?"), pstr.strip_edges(), c]
		row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_theme_font_override("font", UIStyle.get_cjk_font())
		row.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
		row.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
		row.tooltip_text = e.get("raw", "")
		_list.add_child(row)

func _center() -> void:
	var vp: Vector2 = UIStyle.canvas_viewport_size(self)
	position = (vp - size) / 2.0
	# ★ is_instance_valid：_panel 可能已被释放（`if _panel:` 对已释放实例仍可能为真 → use-after-free）。
	if is_instance_valid(_panel):
		_panel.size = size

func close() -> void:
	if TimelineManager != null:
		TimelineManager.timeline_changed.disconnect(_refresh)
	queue_free()

## 最小化 / 还原：折叠只隐藏内容，顶栏（标题 + 拖动把柄 + 最小化 + 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.apply(self, _min_btn, v, _min_btn.get_parent() if is_instance_valid(_min_btn) else null)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
