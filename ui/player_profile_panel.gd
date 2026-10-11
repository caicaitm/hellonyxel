# ui/player_profile_panel.gd
# 「玩家画像」页 —— 由调试面板的「玩家画像」按钮打开。
#
# ★ 与「其它状态页」(ui/state_view_panel.gd) 的区别：画像**不是**一坨原始 JSON，
#   而是按数据模型结构化展示：
#     · 身份信息：姓名 / 生日 / 地址（直接记录）
#     · 性别权重：男 / 女 / 其他（进度条 + 点数）
#     · 年龄权重：8-12 / 12-16 / 16-18 / 18+（进度条 + 点数）
#     · 近期提交：每次填表给对应选项加了几点
#     · 综合结论 + 可展开的原始 JSON
#
# 数据来源 = `PlayerProfile` 单例（读 %文档%/HelloNyxel/Temp/player_profile.json）。
# 契约与 StateViewPanel 一致：configure(title, file) → add_child → closed。
#
# ★ 本脚本**不需要 class_name**：debug_manager 通过 STATE_VIEWS 里的 "panel" 字段按路径实例化。
extends Control

signal closed

const PANEL_W: float = 640.0
const PANEL_H: float = 580.0
const TITLE_H: float = 28.0
const BAR_H: float = 18.0
const HISTORY_SHOWN: int = 6

# 入树前由 configure() 注入
var _title_text: String = "玩家画像"
var _file_name: String = ""

var _bg: UIPanel
var _title_label: Label
var _path_label: Label
var _scroll: ScrollContainer
var _content: VBoxContainer
var _status: Label
var _reset_btn: UIBtn
var _cjk: FontFile

var _profile: Dictionary = {}
var _missing: bool = false
var _raw_open: bool = false
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
	if PlayerProfile != null and PlayerProfile.has_signal("changed"):
		PlayerProfile.changed.connect(_on_profile_changed)
	reload()


func _exit_tree() -> void:
	if PlayerProfile != null and PlayerProfile.has_signal("changed") \
			and PlayerProfile.changed.is_connected(_on_profile_changed):
		PlayerProfile.changed.disconnect(_on_profile_changed)


func _process(dt: float) -> void:
	# 「重置」两步确认：3 秒内没有再点就自动撤销武装状态
	if _reset_armed:
		_reset_arm_timer -= dt
		if _reset_arm_timer <= 0.0:
			_reset_armed = false
			if _reset_btn != null and is_instance_valid(_reset_btn):
				_reset_btn.set_label("重置")


# 画像文件路径（与 StateViewPanel 同款：%文档%/HelloNyxel/Temp/<文件名>）
func resolve_path() -> String:
	var dir := "D:/Documents/HelloNyxel/Temp"
	if SaveManager != null and SaveManager.has_method("get_temp_dir"):
		dir = str(SaveManager.get_temp_dir())
	if _file_name.is_empty():
		return dir.path_join("player_profile.json")
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
	# ★ 限宽：页面名较长时不要压到右侧按钮上（此时顶栏按钮均已建好、锚定位置已解析）
	UIMinimize.clamp_title_width(self, _title_label)

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
	_content.add_theme_constant_override("separation", 4)
	_scroll.add_child(_content)

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


# ---- 数据 -----------------------------------------------------------------

func reload() -> void:
	_profile = PlayerProfile.read_from_disk() if PlayerProfile != null else {}
	_missing = not FileAccess.file_exists(resolve_path())
	if _path_label != null and is_instance_valid(_path_label):
		_path_label.text = "文件: %s" % resolve_path()
	_rebuild_content()
	if _missing:
		_set_status("未找到画像文件（尚未填写）")
	elif int(_profile.get("submit_count", 0)) <= 0:
		_set_status("文件存在但还没有提交记录")
	else:
		_set_status("提交 %d 次 · 更新于 %s" % [
			int(_profile.get("submit_count", 0)), str(_profile.get("updated_at", "?"))])


func _on_profile_changed(_p: Dictionary) -> void:
	reload()


func _rebuild_content() -> void:
	# ★ 先 remove_child 再 queue_free（只 queue_free 的旧节点帧末才真离树 → 会与新节点撞名）
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()

	var genders := _gender_options()
	var buckets := _age_buckets()

	_add_section("身份信息（直接记录）")
	_add_kv("姓名", str(_profile.get("name", "")), "（未填写）")
	_add_kv("生日", str(_profile.get("birthday", "")), "（未填写）")
	_add_kv("地址", str(_profile.get("address", "")), "（未填写）")

	_add_section("性别权重（男 / 女 / 其他）")
	_add_weight_group(_profile.get("gender_weights", {}), genders)
	_add_hint("填表所选：%s → 计入「%s」" % [
		_blank_or(str(_profile.get("gender_input", "")), "（未填写）"),
		_blank_or(str(_profile.get("gender_bucket", "")), "（未判定）")])

	_add_section("年龄权重（8-12 / 12-16 / 16-18 / 18+）")
	_add_weight_group(_profile.get("age_weights", {}), buckets)
	var age := int(_profile.get("age", -1))
	_add_hint("由生日算得年龄：%s → 计入「%s」" % [
		("%d 岁" % age) if age >= 0 else "（无法计算）",
		_blank_or(str(_profile.get("age_bucket", "")), "（未判定）")])

	_add_section("综合结论")
	_add_kv("性别倾向", _top_label(_profile.get("gender_weights", {}), genders), "（暂无权重）")
	_add_kv("年龄段", _top_label(_profile.get("age_weights", {}), buckets), "（暂无权重）")
	_add_hint("每次提交给对应选项 +%d 点权重；权重最高者即当前倾向。" % int(_profile.get("weight_step", 3)))

	_add_section("近期提交")
	var hist: Array = _profile.get("history", [])
	if hist.is_empty():
		_add_hint("（暂无提交记录）")
	else:
		var start: int = maxi(0, hist.size() - HISTORY_SHOWN)
		for i in range(hist.size() - 1, start - 1, -1):
			var h: Dictionary = hist[i]
			_add_hint("%s · 性别 %s→%s · 年龄 %s · +%d" % [
				str(h.get("at", "?")),
				_blank_or(str(h.get("gender_input", "")), "?"),
				_blank_or(str(h.get("gender_bucket", "")), "?"),
				_blank_or(str(h.get("age_bucket", "")), "?"),
				int(h.get("weight", 0))])

	_add_section("原始数据")
	var raw_btn := UIBtn.new()
	raw_btn.set_id("raw")
	raw_btn.set_label("隐藏原始 JSON" if _raw_open else "查看原始 JSON")
	raw_btn.custom_minimum_size = Vector2(0.0, UIStyle.BTN_HEIGHT)
	raw_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	raw_btn.pressed_id.connect(_on_raw_pressed)
	_content.add_child(raw_btn)
	if _raw_open:
		var raw := _mk_label(JSON.stringify(_profile, "  "), -1, Color(0.85, 0.92, 1.0, 0.9))
		raw.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		raw.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_content.add_child(raw)


func _add_section(title: String) -> void:
	var l := _mk_label(title, 1, Color(0.70, 0.95, 1.0))
	l.custom_minimum_size = Vector2(0.0, 22.0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_content.add_child(l)
	_content.add_child(HSeparator.new())


func _add_hint(text: String) -> void:
	var l := _mk_label(text, -1, Color(0.80, 0.89, 0.99, 0.75))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(l)


func _add_kv(key: String, value: String, placeholder: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var k := _mk_label(key, 0, Color(0.78, 0.86, 0.95, 0.85))
	k.custom_minimum_size = Vector2(72.0, 22.0)
	row.add_child(k)
	var filled := not value.strip_edges().is_empty()
	var v := _mk_label(value if filled else placeholder, 0,
		Color(1, 1, 1, 1) if filled else Color(1, 1, 1, 0.45))
	v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(v)
	_content.add_child(row)


func _add_weight_group(weights: Variant, options: Array) -> void:
	var w: Dictionary = weights if weights is Dictionary else {}
	var max_v := 0
	for o in options:
		max_v = maxi(max_v, int(w.get(str(o), 0)))
	for o in options:
		_content.add_child(_make_weight_row(str(o), int(w.get(str(o), 0)), max_v))


func _make_weight_row(option: String, value: int, max_v: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var lab := _mk_label(option, 0, Color(0.92, 0.96, 1.0, 0.95))
	lab.custom_minimum_size = Vector2(64.0, BAR_H)
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lab)

	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.min_value = 0.0
	bar.max_value = float(maxi(1, max_v))
	bar.value = float(value)
	bar.custom_minimum_size = Vector2(0.0, BAR_H)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_theme_stylebox_override("background", _bar_style(Color(0.04, 0.14, 0.24, 0.85)))
	bar.add_theme_stylebox_override("fill", _bar_style(Color(0.20, 0.75, 1.0, 0.95)))
	row.add_child(bar)

	var num := _mk_label("%d 点" % value, 0, Color(1, 1, 1, 1) if value > 0 else Color(1, 1, 1, 0.45))
	num.custom_minimum_size = Vector2(56.0, BAR_H)
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(num)
	return row


func _bar_style(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(4)
	return sb


func _blank_or(s: String, fallback: String) -> String:
	return s if not s.strip_edges().is_empty() else fallback


# 选项列表统一从 PlayerProfile 取（单一真源）；取不到时用兜底副本
func _gender_options() -> Array:
	if PlayerProfile != null and PlayerProfile.has_method("gender_options"):
		return PlayerProfile.gender_options()
	return ["男", "女", "其他"]


func _age_buckets() -> Array:
	if PlayerProfile != null and PlayerProfile.has_method("age_buckets"):
		return PlayerProfile.age_buckets()
	return ["8-12", "12-16", "16-18", "18+"]


func _top_label(weights: Variant, options: Array) -> String:
	var w: Dictionary = weights if weights is Dictionary else {}
	var best := ""
	var best_v := 0
	for o in options:
		var v := int(w.get(str(o), 0))
		if v > best_v:
			best_v = v
			best = str(o)
	if best.is_empty():
		return ""
	return "%s（%d 点）" % [best, best_v]


func _set_status(t: String) -> void:
	if _status != null and is_instance_valid(_status):
		_status.text = t


# ---- 交互 -----------------------------------------------------------------

func _on_refresh_pressed(_id: String) -> void:
	if PlayerProfile != null:
		PlayerProfile.reload()
	reload()


func _on_raw_pressed(_id: String) -> void:
	_raw_open = not _raw_open
	_rebuild_content()


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
	if PlayerProfile != null:
		PlayerProfile.reset()   # 会发 changed → _on_profile_changed → reload()


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
