# ui/level_group_panel.gd
# 关卡组生成器面板（由调试面板「关卡组生成器」开关打开）。
# 输入：组名 / 种子 / 各类型关卡数量 / 总数 → 点「生成关卡组」→ 调 LevelGroupGenerator
# 组装 → 交给 LevelPage.project_data 投影到关卡页面试看。仅生成不保存。
class_name LevelGroupPanel
extends Control

const W := 480.0
const H := 560.0
const PAD := 12.0

var _panel: UIPanel
var _top: HBoxContainer
var _name_input: LineEdit
var _seed_input: LineEdit
var _spin_trap: SpinBox
var _spin_reward: SpinBox
var _spin_normal: SpinBox
var _spin_challenge: SpinBox
var _total_input: LineEdit
var _summary: Label

signal closed

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()


func _build() -> void:
	_panel = UIPanel.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.set_corner_radius(UIStyle.CORNER_RADIUS)
	_panel.set_fill_color(UIStyle.FILL_DEFAULT)
	_panel.set_border_color(UIStyle.BORDER)
	_panel.set_border_width(UIStyle.BORDER_WIDTH)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	_top = HBoxContainer.new()
	_top.position = Vector2(PAD, PAD)
	_top.size = Vector2(W - PAD * 2.0, 28.0)
	add_child(_top)
	var title := Label.new()
	title.text = "关卡组生成器"
	title.add_theme_font_override("font", UIStyle.get_cjk_font())
	title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 3)
	title.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_top.add_child(title)
	var handle := UIDragHandle.new()
	handle.setup(self)
	handle.tooltip_text = "拖动以移动面板"
	_top.add_child(handle)
	var close_btn := UIBtn.new()
	close_btn.custom_minimum_size = Vector2(64.0, 28.0)
	close_btn.set_label("关闭")
	close_btn.pressed_id.connect(func(_id): close())
	UIMinimize.attach(_top, func(): set_minimized(not _minimized))
	_top.add_child(close_btn)

	var vbox := VBoxContainer.new()
	vbox.position = Vector2(PAD, PAD + 36.0)
	vbox.size = Vector2(W - PAD * 2.0, H - PAD - 36.0 - PAD)
	vbox.add_theme_constant_override("separation", 8)
	add_child(vbox)

	# 组名
	var r_name := _labeled_row("组名")
	_name_input = LineEdit.new()
	_name_input.placeholder_text = "关卡组名称"
	_name_input.text = "测试关卡组"
	_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r_name.add_child(_name_input)
	vbox.add_child(r_name)

	# 种子
	var r_seed := _labeled_row("种子")
	_seed_input = LineEdit.new()
	_seed_input.placeholder_text = "整数；相同种子 → 相同布局"
	_seed_input.text = "0"
	_seed_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r_seed.add_child(_seed_input)
	var rand_btn := UIBtn.new()
	rand_btn.custom_minimum_size = Vector2(64.0, 30.0)
	rand_btn.set_label("随机")
	rand_btn.pressed_id.connect(func(_id):
		_seed_input.text = str(randi() % 1000000))
	r_seed.add_child(rand_btn)
	vbox.add_child(r_seed)

	vbox.add_child(_sep())

	var hint := Label.new()
	hint.text = "中间关卡数量（入口关卡 / 出口关卡各固定 1 个）："
	hint.add_theme_font_override("font", UIStyle.get_cjk_font())
	hint.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	hint.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(hint)

	var r_mid1 := HBoxContainer.new()
	r_mid1.add_theme_constant_override("separation", 6)
	vbox.add_child(r_mid1)
	_spin_trap = _count_spin("陷阱", r_mid1)
	_spin_reward = _count_spin("奖励", r_mid1)

	var r_mid2 := HBoxContainer.new()
	r_mid2.add_theme_constant_override("separation", 6)
	vbox.add_child(r_mid2)
	_spin_normal = _count_spin("普通", r_mid2)
	_spin_challenge = _count_spin("挑战", r_mid2)

	var r_total := _labeled_row("总数(可选)")
	_total_input = LineEdit.new()
	_total_input.placeholder_text = "留空=用上面之和；更大则随机补足"
	_total_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r_total.add_child(_total_input)
	vbox.add_child(r_total)

	vbox.add_child(_sep())

	var gen_btn := UIBtn.new()
	gen_btn.custom_minimum_size = Vector2(0.0, 36.0)
	gen_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gen_btn.set_label("生成关卡组")
	gen_btn.pressed_id.connect(func(_id): _on_generate())
	vbox.add_child(gen_btn)

	_summary = Label.new()
	_summary.text = "输入参数后点「生成关卡组」。生成结果直接投影到关卡页面试看（不写文件）。"
	_summary.add_theme_font_override("font", UIStyle.get_cjk_font())
	_summary.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	_summary.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_summary)


func _labeled_row(label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lb := Label.new()
	lb.text = label_text
	lb.add_theme_font_override("font", UIStyle.get_cjk_font())
	lb.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	lb.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	lb.custom_minimum_size = Vector2(80.0, 30.0)
	row.add_child(lb)
	return row


func _count_spin(label_text: String, parent: HBoxContainer) -> SpinBox:
	var lb := Label.new()
	lb.text = label_text
	lb.add_theme_font_override("font", UIStyle.get_cjk_font())
	lb.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	lb.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	lb.custom_minimum_size = Vector2(40.0, 30.0)
	parent.add_child(lb)
	var sp := SpinBox.new()
	sp.min_value = 0
	sp.max_value = 99
	sp.step = 1
	sp.value = 0
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.add_theme_font_override("font", UIStyle.get_cjk_font())
	sp.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	parent.add_child(sp)
	return sp


func _sep() -> HSeparator:
	return HSeparator.new()


# 最小化支持：折叠时仅保留顶栏（标题 + 最小化/关闭）。
var _minimized: bool = false
func set_minimized(v: bool) -> void:
	_minimized = v
	for c in get_children():
		if c == _panel or c == _top:
			continue
		if c is CanvasItem:
			(c as CanvasItem).visible = not v


func close() -> void:
	closed.emit()
	queue_free()


func _on_generate() -> void:
	if LevelGroupGenerator == null:
		_summary.text = "✗ LevelGroupGenerator 不可用"
		return
	var group_name: String = _name_input.text.strip_edges()
	if group_name.is_empty():
		group_name = "level_group"
	var seed_value: int = 0
	if _seed_input.text.is_valid_int():
		seed_value = _seed_input.text.to_int()
	else:
		seed_value = _seed_input.text.hash()
	var counts := {
		"trap": int(_spin_trap.value),
		"reward": int(_spin_reward.value),
		"normal": int(_spin_normal.value),
		"challenge": int(_spin_challenge.value),
	}
	var total := -1
	var total_text := _total_input.text.strip_edges()
	if not total_text.is_empty() and total_text.is_valid_int():
		total = total_text.to_int()
	var cfg := {"group_name": group_name, "seed": seed_value, "counts": counts, "total": total}
	var merged := LevelGroupGenerator.generate(cfg)
	if merged.is_empty():
		_summary.text = "✗ 生成失败：关卡池不足（需要 env 含 entrance_level 的入口关卡、exit_level 的出口关卡，以及各种类型关卡）。"
		return
	var page = LevelManager.level_page if LevelManager != null else null
	if page == null or not page.has_method("project_data"):
		_summary.text = "✗ 关卡面板未就绪"
		return
	if page.project_data(merged):
		var n: int = merged.get("blocks", []).size()
		var seq: Array = merged.get("_sequence_types", [])
		_summary.text = "✓ 已生成「%s」（种子=%d）\n关卡顺序：%s\n合并积木数：%d" % [
			group_name, seed_value, str(seq), n]
	else:
		_summary.text = "✗ 投影失败"
