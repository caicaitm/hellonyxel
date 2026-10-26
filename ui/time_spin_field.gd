# ui/time_spin_field.gd
# 时间选择器（滚轮式 · 无限循环）：
#   时(0..23) / 分(0..59) 两个竖向滚轮，数值**循环**（23→0、59→0）。
#   滚动是连续动画而非瞬跳：
#     - 左键按住上下拖动 → 跟手滚动，带惯性；松手补间吸附到最近整数后才落值。
#     - 鼠标滚轮 → ±1 步进，同样补间滑过去。
#     - 循环：越过 23/0、59/0 边界时数字带无缝续滚（渲染按「逻辑下标」取模）。
#   ★ 防误触：滚轮事件**必须先左键单击选中本控件**才生效；未选中时滚轮原样透传
#     给外层滚动容器（鼠标停在时间框上照常滚页面）。指针移出控件即解除选中
#     （拖动过程中除外）。选中期间中心带高亮描边 + 上下三角增亮作视觉反馈。
#   拖动期间**不触发** time_changed（避免连续写盘）；仅松手吸附/步进/set_time 落值时触发。
# API（与旧版一致，调用方无需改动）:
#   set_time(hour, minute) / get_time() -> {"hour":int,"minute":int}
#   set_time_str("HH:MM") / get_time_str() -> "HH:MM"
#   time_changed(hour, minute)
#   set_density(item_h, visible)   # 紧凑行用 set_density(24, 3)；主控默认 (30, 5)
extends Control
class_name TimeSpinField

signal time_changed(hour: int, minute: int)

const WHEEL_W: float = 64.0        # 单滚轮宽（"23" 在 FONT_SIZE+6 下放得下）
const COLON_W: float = 18.0        # 冒号区宽
const SIDE_PAD: float = 2.0
const HOUR_N: int = 24
const MIN_N: int = 60

# 动画参数
const SNAP_SEC: float = 0.18           # 吸附基准时长
const SNAP_SEC_PER_ITEM: float = 0.045 # 吸附距离越远滑得越久
const SNAP_SEC_MAX: float = 0.38
const FLICK_SEC: float = 0.26          # 惯性投影时长（秒）
const FLICK_MAX_ITEMS: float = 6.0     # 惯性最多滑几项
const STEP_SEC: float = 0.13           # 滚轮步进时长
const VEL_IDLE_SEC: float = 0.10       # 松手前静置超过此时长则不计惯性

var _hour: int = 8
var _minute: int = 0

# 滚轮视觉位置：浮点「逻辑下标」。中心项的值 = wrapi(round(_pos), 0, N)。
# 渲染按 idx 连续取（不按值域），所以跨边界天然无缝循环。
var _pos_h: float = 8.0
var _pos_m: float = 0.0

# 密度（可被 set_density 调整）
var _item_h: float = 30.0
var _visible: int = 5

# 拖动状态（按下在 _gui_input 记录；移动/松手走 _input，指针可移出本控件）
var _drag_unit: String = ""
var _drag_active: bool = false
var _drag_start_pos: float = 0.0
var _drag_start_vp_y: float = 0.0
var _drag_last_vp_y: float = 0.0
var _drag_last_t_msec: int = 0
var _drag_vel: float = 0.0        # 本地像素/秒，正 = 向上拖
var _drag_scale: float = 1.0      # 画布缩放（视口像素 → 本地像素）

# 单击选中态：只有选中后滚轮才改时间（防悬停误触）；指针移出即解除
var _armed: bool = false
var _ptr_inside: bool = false   # 指针是否在本控件内（拖动中 _gui_input 仍收 motion 即可判内）

var _tween_h: Tween = null
var _tween_m: Tween = null

var _hover_unit: String = ""
var _font: Font = null
var _sb_trough: StyleBoxFlat = null
var _sb_band: StyleBoxFlat = null
var _sb_band_armed: StyleBoxFlat = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	_font = UIStyle.get_cjk_font()
	if _font == null:
		_font = ThemeDB.fallback_font
	_sb_trough = UIStyle.glass_box(UIStyle.FILL_SURFACE, UIStyle.BORDER, 8, 1)
	_sb_band = UIStyle.glass_box(UIStyle.FILL_HOVER, Color(0.80, 0.92, 1.0, 0.75), 8, 1)
	# 选中（armed）态：中心带换高亮描边，明确告诉用户「滚轮现在归我管」
	_sb_band_armed = UIStyle.glass_box(UIStyle.FILL_HOVER, Color(0.45, 0.85, 1.0, 0.95), 8, 2)
	tooltip_text = "单击选中后，滚轮 / 拖动可调整时间"
	_update_min_size()
	queue_redraw()


func set_density(item_h: float, visible: int) -> void:
	_item_h = maxf(18.0, item_h)
	_visible = clampi(visible, 3, 9)
	_update_min_size()
	queue_redraw()


func _update_min_size() -> void:
	custom_minimum_size = Vector2(WHEEL_W * 2.0 + COLON_W + SIDE_PAD * 2.0, _item_h * float(_visible))


# ---------- 公开 API ----------

func set_time(hour: int, minute: int) -> void:
	_hour = clampi(int(hour), 0, 23)
	_minute = clampi(int(minute), 0, 59)
	_animate_to("hour", float(_hour), STEP_SEC)
	_animate_to("minute", float(_minute), STEP_SEC)
	time_changed.emit(_hour, _minute)


func set_time_str(s: String) -> void:
	var parts := str(s).split(":")
	if parts.size() != 2:
		return
	if not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return
	var h := int(parts[0])
	var m := int(parts[1])
	if h < 0 or h > 23 or m < 0 or m > 59:
		return
	set_time(h, m)


func get_time() -> Dictionary:
	return {"hour": _hour, "minute": _minute}


func get_time_str() -> String:
	return "%02d:%02d" % [_hour, _minute]


# ---------- 滚轮位置 / 补间 ----------

func _unit_at(local_pos: Vector2) -> String:
	if local_pos.x < SIDE_PAD + WHEEL_W:
		return "hour"
	if local_pos.x >= size.x - SIDE_PAD - WHEEL_W:
		return "minute"
	return ""


func _pos_of(unit: String) -> float:
	return _pos_h if unit == "hour" else _pos_m


func _set_pos(unit: String, p: float) -> void:
	if unit == "hour":
		_pos_h = p
	else:
		_pos_m = p
	queue_redraw()


func _kill_tween(unit: String) -> void:
	var tw: Tween = _tween_h if unit == "hour" else _tween_m
	if tw != null and tw.is_valid():
		tw.kill()
	if unit == "hour":
		_tween_h = null
	else:
		_tween_m = null


func _animate_to(unit: String, target: float, sec: float) -> void:
	if not is_inside_tree():
		# 未入树（构建期 set_time_str）：直接落位，不补间
		_set_pos(unit, target)
		_finalize(unit, target)
		return
	_kill_tween(unit)
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_CUBIC)
	tw.set_ease(Tween.EASE_OUT)
	if unit == "hour":
		_tween_h = tw
	else:
		_tween_m = tw
	# ★ 4.7.2 坑：tween_method 对 .bind() 绑定 Callable 静默不调用 setter（calls=0），
	#   tween_callback 带 bind 却正常 → setter 必须用 lambda 显式带参。
	tw.tween_method(func(p): _set_pos(unit, p), _pos_of(unit), target, sec)
	tw.tween_callback(func(): _finalize(unit, target))


func _finalize(unit: String, pos: float) -> void:
	var n := HOUR_N if unit == "hour" else MIN_N
	var v := wrapi(int(roundf(pos)), 0, n)
	if unit == "hour":
		if v != _hour:
			_hour = v
			time_changed.emit(_hour, _minute)
	else:
		if v != _minute:
			_minute = v
			time_changed.emit(_hour, _minute)


func _step(unit: String, dir: int) -> void:
	var base := roundf(_pos_of(unit))
	_animate_to(unit, base + float(dir), STEP_SEC)


func _release_drag() -> void:
	var unit := _drag_unit
	if unit.is_empty():
		return
	# 静置太久 → 速度作废（避免「按住停一会再松」还飞出去）
	var idle := float(Time.get_ticks_msec() - _drag_last_t_msec) * 0.001
	var vel := _drag_vel if idle < VEL_IDLE_SEC else 0.0
	var pos := _pos_of(unit)
	var proj := clampf(pos + vel * FLICK_SEC / _item_h, pos - FLICK_MAX_ITEMS, pos + FLICK_MAX_ITEMS)
	var target := roundf(proj)
	var sec: float = clampf(SNAP_SEC + absf(target - pos) * SNAP_SEC_PER_ITEM, SNAP_SEC, SNAP_SEC_MAX)
	_animate_to(unit, target, sec)


# ---------- 输入 ----------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if not _armed:
				return   # ★ 未单击选中 → 滚轮透传外层滚动容器（防悬停误改时间）
			var wu := _unit_at(mb.position)
			if wu.is_empty():
				return   # 冒号区不接滚轮 → 事件继续传给外层滚动容器
			_step(wu, 1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
			get_viewport().set_input_as_handled()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var u := _unit_at(mb.position)
				if u.is_empty():
					return
				_drag_unit = u
				_drag_active = true
				_armed = true   # 单击即选中：此后滚轮才改本控件
				_ptr_inside = true
				queue_redraw()
				_drag_start_pos = _pos_of(u)
				_drag_start_vp_y = get_viewport().get_mouse_position().y
				_drag_last_vp_y = _drag_start_vp_y
				_drag_last_t_msec = Time.get_ticks_msec()
				_drag_vel = 0.0
				var s := get_canvas_transform().get_scale().y
				_drag_scale = s if absf(s) > 0.001 else 1.0
				_kill_tween(u)
			else:
				if _drag_active:
					_release_drag()
				_drag_unit = ""
				_drag_active = false
			get_viewport().set_input_as_handled()
			return
		return
	if event is InputEventMouseMotion:
		_ptr_inside = true   # 还能收到 motion ⇒ 指针在本控件内（拖动中同样成立）
		if _drag_active:
			return   # 拖动中的移动由 _input 统一收（指针可移出本控件）
		var u := _unit_at((event as InputEventMouseMotion).position)
		if u != _hover_unit:
			_hover_unit = u
			queue_redraw()
		return


func _input(event: InputEvent) -> void:
	if not _drag_active:
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var dy_vp := mm.position.y - _drag_last_vp_y
		var dy_local := dy_vp / _drag_scale
		var now := Time.get_ticks_msec()
		var dt := float(now - _drag_last_t_msec) * 0.001
		if dt > 0.004:
			var v := -dy_local / dt   # 向上拖 → 正
			_drag_vel = lerpf(_drag_vel, v, 0.6) if _drag_vel != 0.0 else v
		_drag_last_vp_y = mm.position.y
		_drag_last_t_msec = now
		var total_local := (_drag_start_vp_y - mm.position.y) / _drag_scale
		_set_pos(_drag_unit, _drag_start_pos + total_local / _item_h)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_release_drag()
			_drag_unit = ""
			_drag_active = false
			# 在控件外松手 → 一并解除选中（指针还在外，不该继续响应滚轮）
			if not _ptr_inside:
				_armed = false
			get_viewport().set_input_as_handled()


# ---------- 绘制 ----------

func _draw() -> void:
	if _font == null:
		return
	var w := size.x
	var h := size.y
	var cy := h * 0.5
	var hx := SIDE_PAD + WHEEL_W * 0.5
	var mx := w - SIDE_PAD - WHEEL_W * 0.5

	# 两个滚轮底板（玻璃槽）+ 中心选中带
	if _sb_trough != null:
		draw_style_box(_sb_trough, Rect2(SIDE_PAD, 1.0, WHEEL_W, h - 2.0))
		draw_style_box(_sb_trough, Rect2(w - SIDE_PAD - WHEEL_W, 1.0, WHEEL_W, h - 2.0))
	var band: StyleBoxFlat = _sb_band_armed if (_armed and _sb_band_armed != null) else _sb_band
	if band != null:
		draw_style_box(band, Rect2(SIDE_PAD + 3.0, cy - _item_h * 0.5, WHEEL_W - 6.0, _item_h))
		draw_style_box(band, Rect2(w - SIDE_PAD - WHEEL_W + 3.0, cy - _item_h * 0.5, WHEEL_W - 6.0, _item_h))

	_draw_wheel(hx, cy, _pos_h, HOUR_N, _hover_unit == "hour")
	_draw_wheel(mx, cy, _pos_m, MIN_N, _hover_unit == "minute")

	# 冒号
	var cfs := UIStyle.FONT_SIZE + 4
	var ccol := UIStyle.TEXT_DEFAULT
	ccol.a = 0.85
	var csz := _font.get_string_size(":", HORIZONTAL_ALIGNMENT_CENTER, -1.0, cfs)
	draw_string(_font, Vector2(w * 0.5 - csz.x * 0.5, cy - _font.get_height(cfs) * 0.5 + _font.get_ascent(cfs)),
		":", HORIZONTAL_ALIGNMENT_CENTER, -1.0, cfs, ccol)


func _draw_wheel(cx: float, cy: float, pos: float, n: int, hovered: bool) -> void:
	var half := _item_h * float(_visible) * 0.5
	var first := int(floorf(pos - float(_visible) * 0.5))
	var last := int(ceilf(pos + float(_visible) * 0.5))
	for idx in range(first, last + 1):
		var y := cy + (float(idx) - pos) * _item_h
		var dy := absf(y - cy)
		if dy > half:
			continue
		# 距中心越近越亮越大；边缘淡出（跨边界的循环项也走同一条淡出）
		var t := clampf(1.0 - dy / (_item_h * 2.2), 0.0, 1.0)
		var col := UIStyle.TEXT_DEFAULT
		col.a = lerpf(0.32, 1.0, t)
		var fs := int(round(lerpf(float(UIStyle.FONT_SIZE - 3), float(UIStyle.FONT_SIZE + 6), t)))
		var txt := "%02d" % wrapi(idx, 0, n)
		var lh := _font.get_height(fs)
		var asc := _font.get_ascent(fs)
		var sz := _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_CENTER, -1.0, fs)
		draw_string(_font, Vector2(cx - sz.x * 0.5, y - lh * 0.5 + asc), txt,
			HORIZONTAL_ALIGNMENT_CENTER, -1.0, fs, col)
	# 上下沿小三角：提示「可上/下滚」，悬停/选中时更亮
	var ay := 5.0
	var ah := 4.5
	var acol := UIStyle.TEXT_DEFAULT
	acol.a = 0.80 if (hovered or _armed) else 0.38
	draw_colored_polygon(PackedVector2Array([
		Vector2(cx - ah, ay + ah * 0.8), Vector2(cx + ah, ay + ah * 0.8), Vector2(cx, ay)]), acol)
	draw_colored_polygon(PackedVector2Array([
		Vector2(cx - ah, size.y - ay - ah * 0.8), Vector2(cx + ah, size.y - ay - ah * 0.8), Vector2(cx, size.y - ay)]), acol)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT:
		if _hover_unit != "":
			_hover_unit = ""
		_ptr_inside = false
		# 指针移出即解除选中（拖动过程中除外：松手走 _input，指针可能在控件外）
		if not _drag_active:
			_armed = false
		queue_redraw()
