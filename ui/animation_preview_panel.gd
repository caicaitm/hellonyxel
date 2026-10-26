# ui/animation_preview_panel.gd
# 调试面板「动画预览」页：离屏播放 res://textures/cats/walk_rig/cat_walk_rig.tscn，
# 提供动画选择 / 播放暂停 / 重播 / 循环 / 速度控制。
#
# 骨骼场景由 tools/build_cat_walk_rig.gd 从 PSD 分层生成：
#   Body（重心起伏）→ LegL/LegR（髋关节）、ArmL/ArmR（肩关节）、Head（颈关节，含头发/五官）。
#   walk：原版 Sprite2D 分层动画；walk.1：四肢整张贴图网格蒙皮，肘/膝可弯曲；
#   walk.2 - walk.6：不同抬腿高度/摆幅/重心变化的步态版本。
# 同一场景也可直接填进积木的「骨骼动画」填充（blocks/block_fill.gd :: AnimType.SKELETON）。
extends Control

const RIG_SCENE_PATH := "res://textures/cats/walk_rig/cat_walk_rig.tscn"

const PANEL_W: float = 560.0
const PANEL_H: float = 664.0
const TITLE_BAR_H: float = 28.0
const PAD: float = 10.0
const VIEW_W: float = 540.0
const VIEW_H: float = 440.0
const STAGE_MARGIN: float = 10.0

# 角色在 PSD 画布里的包围盒（用于把骨骼场景适配进预览视口）
const CHAR_BOUNDS := Rect2(243.0, 58.0, 498.0, 891.0)
const PREVIEW_SCALE: float = 0.46

const SPEED_MIN := 0.25
const SPEED_MAX := 2.0
const SPEED_DEFAULT := 1.0

signal closed

var _bg: UIPanel
var _title_row: HBoxContainer
var _min_btn: UIBtn
var _close_btn: UIBtn

var _anim_pick: OptionButton
var _btn_play: UIBtn
var _btn_replay: UIBtn
var _btn_loop: UIBtn
var _speed_slider: HSlider
var _speed_label: Label
var _status_label: Label

var _holder: Control
var _viewport: SubViewport
var _stage: Node2D
var _rig: Node = null
var _player: AnimationPlayer = null
var _anim_names: Array[String] = []
var _current_anim: String = ""
var _loop_enabled: bool = true
var _speed: float = SPEED_DEFAULT
var _minimized: bool = false
var _status_timer: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	_spawn_rig()


func _process(dt: float) -> void:
	if _minimized or _player == null or not is_instance_valid(_player):
		return
	_status_timer -= dt
	if _status_timer > 0.0:
		return
	_status_timer = 0.1
	_refresh_status()


# ---------------- 布局 ----------------

func _build() -> void:
	var fnt := UIStyle.get_cjk_font()
	_bg = UIPanel.new()
	var vs := UIStyle.canvas_viewport_size(self)
	_bg.position = ((vs - Vector2(PANEL_W, PANEL_H)) * 0.5).max(Vector2(8.0, 8.0))
	_bg.size = Vector2(PANEL_W, PANEL_H)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	add_child(_bg)

	_title_row = HBoxContainer.new()
	_title_row.position = Vector2(PAD, PAD - 2.0)
	_title_row.size = Vector2(PANEL_W - PAD * 2.0, TITLE_BAR_H)
	_title_row.add_theme_constant_override("separation", 4)
	_bg.add_child(_title_row)

	var title := Label.new()
	title.text = "动画预览"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", fnt)
	title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 2)
	title.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_title_row.add_child(title)

	var drag := UIDragHandle.new()
	drag.setup(_bg)
	drag.tooltip_text = "拖动以移动面板"
	_title_row.add_child(drag)

	_min_btn = UIMinimize.attach(_title_row, func() -> void: set_minimized(not _minimized))
	_close_btn = _make_button("×", "anim_preview_close")
	_close_btn.custom_minimum_size = Vector2(TITLE_BAR_H, TITLE_BAR_H)
	_close_btn.pressed_id.connect(func(_id: String) -> void: close())
	_title_row.add_child(_close_btn)

	# 动画选择行
	var pick_row := HBoxContainer.new()
	pick_row.position = Vector2(PAD, PAD + TITLE_BAR_H + 6.0)
	pick_row.size = Vector2(PANEL_W - PAD * 2.0, 30.0)
	pick_row.add_theme_constant_override("separation", 8)
	_bg.add_child(pick_row)

	pick_row.add_child(_make_label("动画", fnt))
	_anim_pick = OptionButton.new()
	_anim_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_anim_pick.add_theme_font_override("font", fnt)
	_anim_pick.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	_anim_pick.item_selected.connect(_on_anim_selected)
	pick_row.add_child(_anim_pick)

	_btn_replay = _make_button("重播", "anim_preview_replay")
	_btn_replay.custom_minimum_size = Vector2(64.0, 30.0)
	_btn_replay.pressed_id.connect(func(_id: String) -> void: _replay())
	pick_row.add_child(_btn_replay)

	# 预览视口
	_holder = Control.new()
	_holder.position = Vector2(PAD, PAD + TITLE_BAR_H + 42.0)
	_holder.size = Vector2(VIEW_W, VIEW_H)
	_holder.clip_contents = true
	_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg.add_child(_holder)

	var backdrop := ColorRect.new()
	backdrop.position = Vector2.ZERO
	backdrop.size = Vector2(VIEW_W, VIEW_H)
	backdrop.color = Color(0.035, 0.055, 0.09, 0.62)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_holder.add_child(backdrop)

	var cont := SubViewportContainer.new()
	cont.position = Vector2.ZERO
	cont.size = Vector2(VIEW_W, VIEW_H)
	cont.stretch = true
	cont.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_holder.add_child(cont)

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(int(VIEW_W), int(VIEW_H))
	_viewport.transparent_bg = true
	_viewport.world_2d = World2D.new()
	_viewport.disable_3d = true
	_viewport.gui_disable_input = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	cont.add_child(_viewport)

	# 控制行
	var ctrl_row := HBoxContainer.new()
	ctrl_row.position = Vector2(PAD, _holder.position.y + VIEW_H + 8.0)
	ctrl_row.size = Vector2(PANEL_W - PAD * 2.0, 30.0)
	ctrl_row.add_theme_constant_override("separation", 8)
	_bg.add_child(ctrl_row)

	_btn_play = _make_button("暂停", "anim_preview_play")
	_btn_play.custom_minimum_size = Vector2(74.0, 30.0)
	_btn_play.pressed_id.connect(func(_id: String) -> void: _toggle_play())
	ctrl_row.add_child(_btn_play)

	_btn_loop = _make_button("循环: 开", "anim_preview_loop")
	_btn_loop.custom_minimum_size = Vector2(88.0, 30.0)
	_btn_loop.pressed_id.connect(func(_id: String) -> void: _toggle_loop())
	ctrl_row.add_child(_btn_loop)

	ctrl_row.add_child(_make_label("速度", fnt))
	_speed_slider = HSlider.new()
	_speed_slider.min_value = SPEED_MIN
	_speed_slider.max_value = SPEED_MAX
	_speed_slider.step = 0.05
	_speed_slider.value = SPEED_DEFAULT
	_speed_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_speed_slider.custom_minimum_size = Vector2(150.0, 30.0)
	_speed_slider.value_changed.connect(_on_speed_changed)
	ctrl_row.add_child(_speed_slider)
	_speed_label = _make_label("%.2fx" % SPEED_DEFAULT, fnt)
	_speed_label.custom_minimum_size = Vector2(48.0, 30.0)
	ctrl_row.add_child(_speed_label)

	# 状态行
	_status_label = _make_label("", fnt)
	_status_label.position = Vector2(PAD, ctrl_row.position.y + 36.0)
	_status_label.size = Vector2(PANEL_W - PAD * 2.0, 22.0)
	_status_label.clip_text = true
	_bg.add_child(_status_label)

	var hint := _make_label("walk: 原版 · .1: 蒙皮弯曲 · .2-.6: 不同抬腿/摆臂步态", fnt)
	hint.position = Vector2(PAD, ctrl_row.position.y + 60.0)
	hint.size = Vector2(PANEL_W - PAD * 2.0, 20.0)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	hint.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 2)
	_bg.add_child(hint)


func _make_label(text: String, fnt: Font) -> Label:
	var lb := Label.new()
	lb.text = text
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lb.add_theme_font_override("font", fnt)
	lb.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	lb.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	return lb


func _make_button(text: String, id: String) -> UIBtn:
	var b := UIBtn.new()
	b.set_id(id)
	b.set_label(text)
	b.custom_minimum_size = Vector2(0.0, 30.0)
	return b


# ---------------- 骨骼场景 ----------------

func _spawn_rig() -> void:
	if not ResourceLoader.exists(RIG_SCENE_PATH):
		_status_label.text = "找不到骨骼场景: %s" % RIG_SCENE_PATH
		return
	var packed := load(RIG_SCENE_PATH) as PackedScene
	if packed == null:
		_status_label.text = "骨骼场景不是 PackedScene: %s" % RIG_SCENE_PATH
		return

	# 地面参考线先加入，绘制在角色下方
	var stage_y := _stage_position().y
	var ground_y := CHAR_BOUNDS.end.y * PREVIEW_SCALE + stage_y
	var line := Line2D.new()
	line.points = PackedVector2Array([
		Vector2(STAGE_MARGIN, ground_y), Vector2(VIEW_W - STAGE_MARGIN, ground_y)])
	line.width = 1.5
	line.default_color = Color(0.68, 0.84, 1.0, 0.32)
	_viewport.add_child(line)

	_stage = Node2D.new()
	_stage.scale = Vector2.ONE * PREVIEW_SCALE
	_stage.position = _stage_position()
	_viewport.add_child(_stage)

	_rig = packed.instantiate()
	_stage.add_child(_rig)
	_player = _find_animation_player(_rig)
	if _player == null:
		_status_label.text = "骨骼场景里没有 AnimationPlayer"
		return

	# 复制一份动画库：预览里切换循环模式会改 Animation 资源，不能波及同样引用
	# 该 .tscn 的积木骨骼填充实例。
	var shared_lib := _player.get_animation_library("")
	if shared_lib != null:
		var local_lib := shared_lib.duplicate(true) as AnimationLibrary
		_player.remove_animation_library("")
		_player.add_animation_library("", local_lib)

	for anim_name in _player.get_animation_list():
		var n := str(anim_name)
		if n == "RESET":
			continue
		_anim_names.append(n)
		_anim_pick.add_item(n)
	if _anim_names.is_empty():
		_status_label.text = "骨骼场景里没有动画"
		return

	_player.animation_finished.connect(_on_animation_finished)
	# 默认展示抬腿抬臂版（walk.2）；原版 walk 与 walk.1 仍保留在下拉里可切换对比。
	var default_index := _anim_names.find("walk.2")
	if default_index < 0:
		default_index = _anim_names.find("walk.1")
	if default_index < 0:
		default_index = 0
	_current_anim = _anim_names[default_index]
	_anim_pick.select(default_index)
	_apply_loop_mode()
	_player.speed_scale = _speed
	_player.play(_current_anim)
	_btn_play.set_label("暂停")
	_refresh_status()


func _stage_position() -> Vector2:
	var center_x := (CHAR_BOUNDS.position.x + CHAR_BOUNDS.size.x * 0.5) * PREVIEW_SCALE
	var top := (VIEW_H - CHAR_BOUNDS.size.y * PREVIEW_SCALE) * 0.5 - CHAR_BOUNDS.position.y * PREVIEW_SCALE
	return Vector2(VIEW_W * 0.5 - center_x, top)


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var ap := _find_animation_player(child)
		if ap != null:
			return ap
	return null


# ---------------- 播放控制 ----------------

func _toggle_play() -> void:
	if _player == null:
		return
	if _player.is_playing():
		_player.pause()
		_btn_play.set_label("播放")
	else:
		if _player.current_animation != _current_anim:
			_player.play(_current_anim)
		else:
			_player.play()
		_btn_play.set_label("暂停")
	_refresh_status()


func _replay() -> void:
	if _player == null or _current_anim.is_empty():
		return
	_player.stop()
	_player.play(_current_anim)
	_btn_play.set_label("暂停")
	_refresh_status()


func _on_anim_selected(index: int) -> void:
	if _player == null or index < 0 or index >= _anim_names.size():
		return
	_current_anim = _anim_names[index]
	_apply_loop_mode()
	_player.play(_current_anim)
	_btn_play.set_label("暂停")
	_refresh_status()


func _toggle_loop() -> void:
	_loop_enabled = not _loop_enabled
	_apply_loop_mode()
	_btn_loop.set_label("循环: %s" % ("开" if _loop_enabled else "关"))


func _apply_loop_mode() -> void:
	if _player == null or _current_anim.is_empty() or not _player.has_animation(_current_anim):
		return
	var anim := _player.get_animation(_current_anim)
	if anim != null:
		anim.loop_mode = Animation.LOOP_LINEAR if _loop_enabled else Animation.LOOP_NONE


func _on_speed_changed(v: float) -> void:
	_speed = v
	_speed_label.text = "%.2fx" % v
	if _player != null:
		_player.speed_scale = v


func _on_animation_finished(_name: StringName) -> void:
	if not _loop_enabled:
		_btn_play.set_label("播放")
	_refresh_status()


func _refresh_status() -> void:
	if _player == null or _current_anim.is_empty():
		return
	var length := _player.current_animation_length
	var pos := _player.current_animation_position
	var state := "播放中" if _player.is_playing() else "暂停"
	_status_label.text = "动画: %s  ·  %s  ·  %.2fs / %.2fs  ·  速度 %.2fx" % [
		_current_anim, state, pos, length, _speed]


# ---------------- 生命周期 ----------------

func set_minimized(v: bool) -> void:
	_minimized = v
	for child in _bg.get_children():
		if child == _title_row:
			continue
		if child is CanvasItem:
			(child as CanvasItem).visible = not v
	_bg.size = Vector2(PANEL_W, TITLE_BAR_H + PAD * 2.0 if v else PANEL_H)
	_min_btn.set_label("□" if v else "−")
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED if v else SubViewport.UPDATE_ALWAYS


func close() -> void:
	if _player != null and _player.is_playing():
		_player.pause()
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	closed.emit()
