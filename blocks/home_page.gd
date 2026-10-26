# home_page.gd
# 「家园」页面 —— 仿照「关卡」（LevelPage）的投影页面，但积木**随存档保存**
# （落盘到 Saves/<存档名>/home.json，由 HomeManager + SaveManager 接管）。
#
# ★ 与 LevelPage 的关系（详见 autoload/home_manager.gd 头注释）：
#   · 二者 UI / 投影机制一致（面板窗口 + 舞台 + 摄像头平移/缩放 + 右拖平移）；
#   · 差异只在**持久化后端**：关卡写 res://levels/<名>.json，家园写进存档；
#   · 家园是**单一场景**（没有「多关卡名 / 载入下拉 / 保存位置下拉」），全局只有一个 home_page；
#   · 因此砍掉了关卡的「名称输入 / 载入下拉 / 本体-MOD-DLC 保存条 / 关卡环境标签 / 摄像头锚定界面」
#     —— 这些要么是多关卡管理所需、要么是仅标注/调试用，对家园无意义。
#   · 家园的"保存"是**自动**的：桌面存档时 SaveManager 调 HomeManager.save_to_disk 把当前
#     家园布局写进存档；读取存档时 HomeManager.load_from_disk 把数据喂回，页面可见即投影。
#
# 层级：由 desktop 挂在**独立 CanvasLayer(99)**（与关卡页同一层，低于浮层 ui_layer=100），
# 页面是「世界表面」，**不跟随设置里的 UI 缩放**。
class_name HomePage
extends Control

# ★ 家园页在「可拖动背景」上判定为**右键单击**（位移未超拖动阈值）时发出，桌面据此补弹右键菜单。
#   理由同 LevelPage.right_click_at（右键在可拖动背景上按下时无法区分"单击 / 拖动"）。
signal right_click_at(screen_pos: Vector2)

# 面板大小上下限（与 LevelPage 同口径：最小 = 分辨率 × 0.5）。
const MIN_SCREEN_RATIO: float = 0.5
const MIN_W_FLOOR: float = 240.0
const MIN_H_FLOOR: float = 160.0
const MAX_W_FLOOR: float = 1400.0
const MAX_H_FLOOR: float = 900.0
const PADDING: float = 12.0

var title_var: String = "home_title"  # 家园标题绑定的全局变量名
var _visible := false                  # 面板是否显示（由「打开家园」信号切换）

# UI 部件
var _bg: UIPanel = null
var _title_label: Label = null
var _drag_handle: UIDragHandle = null
var _resize_handle: UIResizeHandle = null

# ============ 舞台区（深色背景 + 裁剪）============
var _body: UIPanel = null
var _stage_view: Control = null
var _top_bar: Control = null
var _blocked: Array[Block] = []   # 当前「在深色背景之外」的积木（占位用，无覆盖层）

# 家园投影：`_stage` 是承载家园积木的 Node2D 舞台（坐标原点 = 面板左上角）。
var _stage: Node2D = null
var _home_blocks: Array[Block] = []   # 当前投影到面板上的家园积木
var current_home_name: String = "home"   # 家园是单一场景，固定 "home"
# 桌面世界节点（由 desktop 注入）：家园积木被传送门送出家园时退回这里（见 release_block）。
var desktop_world: Node = null

# ============ 摄像头（自由平移 + 缩放）============
# ★ 家园**不做**「锚定某块积木」：那是关卡的玩法功能，家园用不到 → 只保留自由平移。
var _free_center: Vector2 = Vector2.ZERO  # 视口中心（家园坐标）
var _cam_center: Vector2 = Vector2.ZERO   # 实际拿去投影的相机中心（平滑跟随时滞后于目标）
var _cam_snap: bool = true                # 下一次更新直接吸附到目标（避免首帧"飞入"）
const CAM_FOLLOW_RATE_NEAR: float = 9.0
const CAM_FOLLOW_RATE_FAR: float = 2.2
const CAM_LAG_DIST: float = 140.0
const CAM_MAX_LAG_FRAC: float = 0.9
var _panning := false
const DRAG_THRESHOLD := 6.0
var _rdrag_pending := false
var _rdrag_start_screen := Vector2.ZERO

# ============ 缩放（滚轮）============
const ZOOM_STEP := 1.1
const ZOOM_MIN := 0.2
const ZOOM_MAX := 5.0
var _zoom: float = 1.0

# origin 与 Control.position 互通：桌面按场景坐标给页面定位
var origin: Vector2:
	set(v):
		position = v
	get:
		return position


func _ready() -> void:
	# 同 LevelPage：必须 IGNORE，否则页面区域内的鼠标事件在 GUI 阶段被吞掉 → 点不了积木 / 没菜单。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


# ---------------- 面板尺寸上下限（随分辨率动态算）----------------
func min_page_size() -> Vector2:
	var s := _screen_size()
	return Vector2(maxf(s.x * MIN_SCREEN_RATIO, MIN_W_FLOOR), maxf(s.y * MIN_SCREEN_RATIO, MIN_H_FLOOR))


func max_page_size() -> Vector2:
	var s := _screen_size()
	return Vector2(maxf(s.x, MAX_W_FLOOR), maxf(s.y, MAX_H_FLOOR))


func _screen_size() -> Vector2:
	var s := DisplayServer.screen_get_size()
	var f := UIStyle.canvas_scale(self)
	return Vector2(float(s.x) / maxf(f.x, 0.0001), float(s.y) / maxf(f.y, 0.0001))


func _clamp_size(v: Vector2) -> Vector2:
	var mn := min_page_size()
	var mx := max_page_size()
	return Vector2(clampf(v.x, mn.x, mx.x), clampf(v.y, mn.y, mx.y))


# 搭起页面：铺面板 + 放控件 + 接线。title_var_name 指定家园标题绑定的全局变量名。
func build(title_var_name: String = "home_title") -> void:
	title_var = title_var_name
	_clear()
	_build_ui()
	size = _clamp_size(size)
	_layout_body()
	_refresh_title()
	if not GlobalVars.changed.is_connected(_on_var_changed):
		GlobalVars.changed.connect(_on_var_changed)
	print("[HomePage] 家园页面已生成 pos=%s size=%s 标题变量=%s" % [str(position), str(size), title_var])


func is_page_visible() -> bool:
	return _visible


func set_page_visible(on: bool) -> void:
	_visible = on
	visible = on
	if not on:
		# 页面隐藏前把当前最新布局喂给 HomeManager，保证下次桌面存档能落盘最新家园。
		HomeManager.store_layout(serialize_home())
	if MousePassRunner.is_enabled():
		MousePassRunner.force_refresh()
	print("[HomePage] 家园页面 → %s" % ("显示" if on else "隐藏"))


func toggle_page_visible() -> void:
	set_page_visible(not _visible)


# ============ 对外开关入口（事件链 / 控制台统一走这里）============

# 打开家园页面：若还没有投影，则按 HomeManager 缓存的家园布局投影出来（重开即见已存的家园）。
func open_home() -> bool:
	if not _visible:
		if _home_blocks.is_empty():
			project_home()
		set_page_visible(true)
	return _visible


# 关闭家园页面（积木保留在舞台上，下次打开还在；关闭前已把布局存进 HomeManager）。
func close_home() -> void:
	set_page_visible(false)


# ============ 家园投影 ============

# 把 HomeManager 缓存的家园布局"投影"到本面板上：清旧 → 实例化积木（原生坐标）→ 相机居中。
# 返回是否成功。标题变量设为"家园"。
func project_home() -> bool:
	_clear_home_blocks()
	var data: Variant = HomeManager.get_layout()
	var defs: Array = []
	if typeof(data) == TYPE_DICTIONARY:
		defs = data.get("blocks", [])
	# 空家园：仍建舞台、相机居中，标题置"家园"。
	if defs.is_empty():
		_ensure_stage()
		_free_center = Vector2.ZERO
		_zoom = 1.0
		_panning = false
		_rdrag_pending = false
		_apply_camera()
		current_home_name = "home"
		GlobalVars.set_var(title_var, "家园")
		HomeManager.store_layout(serialize_home())
		print("[HomePage] 已投影家园（空）")
		return true
	var bounds := _bounds_of(defs)
	var cam: Variant = data.get("camera", {})
	if typeof(cam) == TYPE_DICTIONARY and cam.has("x") and cam.has("y"):
		_free_center = Vector2(float(cam["x"]), float(cam["y"]))
	else:
		_free_center = bounds.get_center()
	_ensure_stage()
	_home_blocks = HomeManager.instantiate_blocks(data, _stage, Vector2.ZERO)
	current_home_name = "home"
	GlobalVars.set_var(title_var, "家园")
	_zoom = 1.0
	_panning = false
	_rdrag_pending = false
	_apply_camera()
	_update_blocked()
	HomeManager.store_layout(serialize_home())
	print("[HomePage] 已投影家园 积木=%d 面板size=%s 视口中心=%s" % [
		_home_blocks.size(), str(size), str(_free_center)])
	return true


# 一组积木定义的外接矩形（局部坐标，供投影居中使用）。
func _bounds_of(defs: Array) -> Rect2:
	var bounds := Rect2()
	for d in defs:
		if not (d is Dictionary):
			continue
		var x := float(d.get("x", 0.0))
		var y := float(d.get("y", 0.0))
		var w := float(d.get("width", 80.0))
		var h := float(d.get("height", 80.0))
		var r := Rect2(x - w / 2.0, y - h / 2.0, w, h)
		if defs.find(d) == 0:
			bounds = r
		else:
			bounds = bounds.merge(r)
	return bounds


# ---------------- 就地新建积木（右键「新建积木」时归入家园）----------------

# 该**页面画布**坐标点是否落在本家园页面矩形内（页面显示时才可能为真）。
func page_contains_global_point(global_pos: Vector2) -> bool:
	if not _visible:
		return false
	var local := get_global_transform().affine_inverse() * global_pos
	return Rect2(Vector2.ZERO, size).has_point(local)


func _reparent(n: Node, new_parent: Node) -> void:
	if n == null or not is_instance_valid(n) or new_parent == null:
		return
	if n.is_queued_for_deletion():
		return
	if n == new_parent or new_parent.is_ancestor_of(n):
		return
	var old := n.get_parent()
	if old == new_parent:
		return
	if old != null:
		old.remove_child(n)
	new_parent.add_child(n)


func _reparent_keep_screen(n: Node2D, new_parent: Node) -> void:
	if n == null or not is_instance_valid(n):
		return
	var screen_pos: Vector2 = n.get_canvas_transform() * n.global_position
	_reparent(n, new_parent)
	if not is_instance_valid(n):
		return
	n.global_position = n.get_canvas_transform().affine_inverse() * screen_pos


func _desktop_world() -> Node:
	if desktop_world != null and is_instance_valid(desktop_world):
		return desktop_world
	var tree := get_tree()
	if tree != null and tree.current_scene != null:
		return tree.current_scene
	return null


# 把关园积木挂进**家园舞台**（位置换算成舞台局部 = 家园原生坐标），登记进 _home_blocks。
func add_home_block(blk: Block, global_pos: Vector2) -> bool:
	if blk == null or blk.is_queued_for_deletion() or not page_contains_global_point(global_pos):
		return false
	_ensure_stage()
	if _stage == null or not is_instance_valid(_stage):
		return false
	_reparent(blk, _stage)
	blk.position = _stage.to_local(global_pos)
	if not _home_blocks.has(blk):
		_home_blocks.append(blk)
	_update_blocked()
	HomeManager.store_layout(serialize_home())
	print("[HomePage] 已新建家园积木 id=%d pos=%s（归入家园，不落桌面）" % [blk.id, str(blk.position)])
	return true


# ---------------- 传送门：跨场景搬运（归属切换）----------------

func adopt_block(blk: Block) -> bool:
	if blk == null or not is_instance_valid(blk) or blk.is_queued_for_deletion():
		return false
	_ensure_stage()
	if _stage == null or not is_instance_valid(_stage):
		return false
	_reparent_keep_screen(blk, _stage)
	if not is_instance_valid(blk):
		return false
	if not _home_blocks.has(blk):
		_home_blocks.append(blk)
	_update_blocked()
	HomeManager.store_layout(serialize_home())
	print("[HomePage] 积木 id=%d 已收进家园（跨场景传送），坐标=%s" % [blk.id, str(blk.position)])
	return true


func forget_block(blk: Block) -> void:
	if blk == null:
		return
	if _home_blocks.has(blk):
		_home_blocks.erase(blk)
		_update_blocked()


# 把关园积木「退回」桌面世界：脱离 _home_blocks + 换父到桌面世界（保持屏幕位置）。
func release_block(blk: Block) -> bool:
	if blk == null or not is_instance_valid(blk) or blk.is_queued_for_deletion():
		return false
	forget_block(blk)
	var world := _desktop_world()
	if world == null:
		push_warning("[HomePage] 找不到桌面世界节点，积木 id=%d 留在家园里" % blk.id)
		return false
	var g: Vector2 = blk.global_position
	_reparent_keep_screen(blk, world)
	HomeManager.store_layout(serialize_home())
	print("[HomePage] 积木 id=%d 已退回桌面世界（跨场景传送），屏幕位置=%s" % [
		blk.id, str(blk.get_canvas_transform() * blk.global_position)])
	return true


# ---------------- 摄像头 ----------------

func _apply_camera(delta: float = -1.0) -> void:
	if _stage == null:
		return
	var target: Vector2 = _free_center
	if _cam_snap or delta < 0.0:
		_cam_center = target
		_cam_snap = false
	else:
		_cam_center = _cam_center.lerp(target, _cam_follow_alpha(_cam_center.distance_to(target), delta))
		_cam_center = _clamp_camera_lag(target, null)
	_stage.scale = Vector2(_zoom, _zoom)
	_stage.position = size * 0.5 - _cam_center * _zoom


func _cam_follow_alpha(dist: float, delta: float) -> float:
	var t := clampf(dist / CAM_LAG_DIST, 0.0, 1.0)
	var rate := lerpf(CAM_FOLLOW_RATE_NEAR, CAM_FOLLOW_RATE_FAR, t)
	return 1.0 - exp(-rate * delta)


func _clamp_camera_lag(target: Vector2, a: Block) -> Vector2:
	var half := size * 0.5
	if a != null and is_instance_valid(a):
		half -= Vector2(a.width, a.height) * 0.5
	half *= CAM_MAX_LAG_FRAC
	if half.x <= 0.0 or half.y <= 0.0:
		return _cam_center
	half /= maxf(_zoom, 0.001)
	var off := _cam_center - target
	return target + Vector2(clampf(off.x, -half.x, half.x), clampf(off.y, -half.y, half.y))


func _ensure_stage() -> void:
	if _stage == null:
		_stage = Node2D.new()
		_stage.name = "Stage"
	if _stage_view != null and _stage.get_parent() != _stage_view:
		_stage_view.add_child(_stage)


func _camera_center() -> Vector2:
	return _free_center


# ---------------- 深色背景 / 阻挡 ----------------

func _body_rect() -> Rect2:
	if _body == null:
		return Rect2(Vector2.ZERO, size)
	return Rect2(_body.position, _body.size)


func _update_blocked() -> void:
	_blocked.clear()
	# 家园无覆盖层：占位用，不绘制任何提示。


func _layout_body() -> void:
	if _body == null:
		return
	var want := _top_h() + PADDING
	if absf(_body.offset_top - want) > 0.5:
		_body.offset_top = want
		_stage_view.offset_top = want
		_update_blocked()


func _top_h() -> float:
	if _top_bar != null and is_instance_valid(_top_bar) and _top_bar.size.y > 0.0:
		return _top_bar.size.y
	return 34.0


func _process(_delta: float) -> void:
	_layout_body()


func _physics_process(dt: float) -> void:
	if not _visible or _stage == null:
		return
	_apply_camera(dt)
	_update_blocked()


# 摄像头输入：① 滚轮缩放；② 中键拖动平移；③ 右键拖动平移（阈值内抬起 = 单击 → 补弹菜单）。
# ★ 家园不做关卡环境门槛：缩放 / 右拖**始终允许**（家园是玩家自由布置的个人空间）。
func _unhandled_input(event: InputEvent) -> void:
	if not _visible or _stage == null:
		return

	if event is InputEventMouseButton:
		var wb := event as InputEventMouseButton
		if wb.pressed and (wb.button_index == MOUSE_BUTTON_WHEEL_UP or wb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var wl: Vector2 = (make_input_local(wb) as InputEventMouseButton).position
			if not _body_rect().has_point(wl):
				return
			var f: float = ZOOM_STEP if wb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / ZOOM_STEP
			_zoom_by(f, wl)
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var is_mid: bool = mb.button_index == MOUSE_BUTTON_MIDDLE
		var is_right: bool = mb.button_index == MOUSE_BUTTON_RIGHT
		if not is_mid and not is_right:
			return
		if mb.pressed:
			if not _body_rect().has_point(make_input_local(mb).position):
				return
			if is_right:
				_rdrag_pending = true
				_rdrag_start_screen = mb.position
				get_viewport().set_input_as_handled()
				return
			_panning = true
			get_viewport().set_input_as_handled()
		elif _panning:
			_panning = false
			get_viewport().set_input_as_handled()
		elif _rdrag_pending:
			_rdrag_pending = false
			right_click_at.emit(mb.position)
			get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _panning:
			_free_center -= mm.relative / maxf(_zoom, 0.001)
			get_viewport().set_input_as_handled()
		elif _rdrag_pending:
			var d: Vector2 = mm.position - _rdrag_start_screen
			if d.length() > DRAG_THRESHOLD:
				_rdrag_pending = false
				_panning = true
				_free_center -= d / maxf(_zoom, 0.001)
				get_viewport().set_input_as_handled()


func _zoom_by(factor: float, p_local: Vector2) -> void:
	if _stage == null:
		return
	var z0 := _zoom
	var z1 := clampf(z0 * factor, ZOOM_MIN, ZOOM_MAX)
	if absf(z1 - z0) < 0.0001:
		return
	var d := _stage_view_local(p_local) - size * 0.5
	_free_center += d * (1.0 / z0 - 1.0 / z1)
	_zoom = z1
	_apply_camera()


func _stage_view_local(p_local: Vector2) -> Vector2:
	if _stage_view == null or not is_instance_valid(_stage_view):
		return p_local
	return p_local - _stage_view.position


# 桌面右键询问入口：这次右键是否该由本页「拖动场景」接手？家园**始终允许**右拖平移。
func wants_right_drag_at(screen_pos: Vector2) -> bool:
	if not _visible or _stage == null:
		return false
	if _body == null or not is_instance_valid(_body):
		return false
	return _body.get_global_rect().has_point(screen_pos)


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		_panning = false
		_rdrag_pending = false


# ---------------- 序列化（落盘进存档）----------------

# 把当前投影积木序列化成家园 JSON（与 LevelPage._serialize_level 同款，但 name 固定 "home"）。
func serialize_home() -> Dictionary:
	var blocks: Array = []
	for b in _home_blocks:
		if b == null or not is_instance_valid(b):
			continue
		var rec: Dictionary = {
			"x": b.position.x,
			"y": b.position.y,
			"width": b.width,
			"height": b.height,
		}
		if b.tags != HomeManager.DEFAULT_TAGS:
			var tags: Array = []
			for t in b.tags:
				tags.append(str(t))
			rec["tags"] = tags
		if not b.string_id.is_empty():
			rec["string_id"] = b.string_id
		blocks.append(rec)
	var c := _camera_center()
	var out: Dictionary = {"name": "home", "blocks": blocks, "camera": {"x": c.x, "y": c.y}}
	return out


# ============ 构建 UI ============

func _clear() -> void:
	_clear_home_blocks()
	for c in get_children():
		remove_child(c)
		c.queue_free()


func _build_ui() -> void:
	_bg = UIPanel.new()
	_bg.name = "Bg"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	_body = UIPanel.new()
	_body.name = "StageBody"
	_body.set_frosted(false)
	_body.set_anchors_preset(Control.PRESET_FULL_RECT)
	_body.offset_left = PADDING
	_body.offset_right = -PADDING
	_body.offset_top = PADDING
	_body.offset_bottom = -PADDING
	_body.set_corner_radius(0.0)
	_body.set_fill_color(UIStyle.FILL_LEVEL_STAGE)
	_body.set_border_color(UIStyle.STAGE_BORDER)
	_body.set_border_width(1.0)
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_body)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", int(PADDING))
	margin.add_theme_constant_override("margin_right", int(PADDING))
	margin.add_theme_constant_override("margin_top", int(PADDING))
	margin.add_theme_constant_override("margin_bottom", int(PADDING))
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(PADDING))
	margin.add_child(vbox)

	var top := _build_top_bar()
	top.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	vbox.add_child(top)
	_top_bar = top

	_stage_view = Control.new()
	_stage_view.name = "StageView"
	_stage_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stage_view.offset_left = PADDING
	_stage_view.offset_right = -PADDING
	_stage_view.offset_top = PADDING
	_stage_view.offset_bottom = -PADDING
	_stage_view.clip_contents = true
	_stage_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stage_view)
	_ensure_stage()

	_resize_handle = UIResizeHandle.new()
	_resize_handle.name = "Resize"
	_resize_handle.set_move_callback(_on_resize_increment)
	add_child(_resize_handle)
	_resize_handle.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_resize_handle.offset_right = -6.0
	_resize_handle.offset_bottom = -6.0
	_resize_handle.offset_left = -(UIDragHandle.SIZE + 6.0)
	_resize_handle.offset_top = -(UIDragHandle.SIZE + 6.0)


# 顶栏：移动把柄 + 家园标题（家园无名称输入 / 载入 / 保存条）。
func _build_top_bar() -> HBoxContainer:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)

	_drag_handle = UIDragHandle.new()
	_drag_handle.setup(self)
	top.add_child(_drag_handle)

	_title_label = _make_label("", 16, Color.WHITE)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_title_label)
	return top


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", font_size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fnt := UIStyle.get_cjk_font()
	if is_instance_valid(fnt):
		l.add_theme_font_override("font", fnt)
	return l


# 卸载当前投影（清空舞台积木）。舞台保留。
func _clear_home_blocks() -> void:
	if _stage == null:
		_home_blocks.clear()
		return
	for b in _home_blocks:
		if b == null or not is_instance_valid(b):
			continue
		if BlockManager != null and BlockManager.has_method("unregister"):
			BlockManager.unregister(b)
		b.queue_free()
	_home_blocks.clear()


func _on_resize_increment(inc: Vector2) -> void:
	if inc == Vector2.ZERO:
		return
	size = _clamp_size(size + inc)


func _current_title() -> String:
	return str(GlobalVars.get_var(title_var, ""))


func _refresh_title() -> void:
	if _title_label != null and is_instance_valid(_title_label):
		_title_label.text = _current_title()


func _on_var_changed(var_name: String, _value: Variant) -> void:
	if var_name == title_var:
		_refresh_title()


# 释放接线与子节点（退出 / 重搭时用）
func destroy() -> void:
	if GlobalVars.changed.is_connected(_on_var_changed):
		GlobalVars.changed.disconnect(_on_var_changed)
	_clear()
