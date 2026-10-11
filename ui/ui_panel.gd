# ui_panel.gd
# 通用 UI 面板背景：液态玻璃 / 半透明纯色 / 量子全息（批次 52 玻璃；批次 55 双主题；批次 59 三主题）。
#
# 三条渲染路径（由「界面主题」决定）：
#   · 磨砂路径（玻璃主题）：挂一个 ColorRect + glass_blur ShaderMaterial，采样 SCREEN_TEXTURE
#     做轻量模糊，叠加垂直渐变着色 + 顶部镜面高光 + 荧光冰蓝描边 + 外发光。
#     窗口背后的画面被「磨砂化透出」，是液态玻璃的标志性观感。
#   · 全息路径（量子全息主题，批次 59）：挂 ColorRect + holo_panel ShaderMaterial，
#     **不采样屏幕** → 画一层荧光蓝薄纱，alpha 按椭圆径向衰减（中心实、边缘虚），
#     不画任何描边亮线 → 「无边框 + 纯净透明荧光蓝」。
#   · 平板路径（纯色主题 / 被强制 set_frosted(false) / 着色器不可用）：用 _draw() 画一层
#     「半透明纯色」填充 + 同色系描边，不模糊、不发光、无高光 —— 即「半透明纯色」。
#
# ★ 批次 55：颜色不再存死值，而是按「角色 + 透明度比例」记忆（见 UIStyle.classify_fill）。
#   这样「玻璃 ↔ 纯色 ↔ 全息」与「主题色」变更时可**无损重映射**并**运行时即时生效**
#   （本实例订阅 SaveManager.ui_theme_changed → refresh_theme()）。
#   自定义色（关卡舞台深底、端口/连线色等）角色为空 → 原样保留，不随主题变。
#
# 所有「窗口」与按钮（UIBtn 内嵌 UIPanel）都走这里 → 改这一处即全窗口统一。

class_name UIPanel
extends Control

const _GLASS_SHADER_PATH := "res://theme/glass_blur.gdshader"
const _HOLO_SHADER_PATH := "res://theme/holo_panel.gdshader"

# 着色器只加载一次（所有实例共享）
static var _glass_shader: Shader = null
static var _holo_shader: Shader = null

# —— 填充 / 描边：角色 + 调用方自己的透明度比例（角色为空 = 自定义色，原样保留）——
var _fill_role: String = "default"
var _fill_ratio: float = 1.0
var _fill_color: Color = UIStyle.FILL_DEFAULT

var _border_role: String = "border"
var _border_ratio: float = 1.0
var _border_color: Color = UIStyle.BORDER

var _corner_radius: float = 0.0
var _border_width: float = UIStyle.BORDER_WIDTH

var _frosted: bool = true
# 磨砂开关覆盖：-1 = 跟随主题（默认）；0 = 强制关（如关卡舞台，恒实心平板）；
# 1 = 强制开玻璃磨砂（仍会被 headless / 着色器缺失降级）。
var _frosted_override: int = -1

var _glass: ColorRect = null   # 面板背景着色器层（玻璃 或 全息，由 _bg_kind 区分）
var _bg_kind: String = ""      # "" = 无着色器层；"glass" / "holo" = 当前挂的着色器种类


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # 默认不接收鼠标（按钮自己接）
	resized.connect(_on_resized)
	add_to_group("uis_theme_panel")
	# 订阅主题变化：玻璃 ↔ 纯色切换、主题色变更时本实例即时换肤。
	var sm := UIStyle._save_manager()
	if sm != null and sm.has_signal("ui_theme_changed") and not sm.ui_theme_changed.is_connected(_on_ui_theme_changed):
		sm.ui_theme_changed.connect(_on_ui_theme_changed)
	refresh_theme()


func _on_ui_theme_changed(_mode: String, _color_key: String) -> void:
	refresh_theme()


## 按当前主题（模式 + 主题色）重取填充/描边 + 重定渲染路径，并刷新渲染。
## 幂等；面板构建途中/之后调用都安全。
func refresh_theme() -> void:
	if not _fill_role.is_empty():
		_fill_color = UIStyle.theme_fill(_fill_role, _fill_ratio)
	if not _border_role.is_empty():
		_border_color = UIStyle.theme_border(_border_ratio)
	_sync_render()


## 依据「覆盖值 + 当前主题 + 渲染后端」决定面板背景用哪条渲染路径，并建/拆/换着色器层。
##   玻璃主题 → "glass"（磨砂，采样 SCREEN_TEXTURE）
##   全息主题 → "holo"（荧光蓝径向薄纱，不采样屏幕）
##   其余（纯色 / 强制平板 / 着色器缺失 / headless 下的玻璃）→ ""（_draw 平板色兜底）
func _sync_render() -> void:
	var want := ""
	if _frosted_override == 0:
		want = ""                                  # 强制平板（关卡舞台等）
	elif _frosted_override == 1:
		want = "glass"
	else:
		var m := UIStyle.theme_mode()
		if m == UIStyle.THEME_MODE_HOLO:
			want = "holo"
		elif m == UIStyle.THEME_MODE_GLASS:
			want = "glass"
	# ★ headless（dummy 渲染器）编译不了 SCREEN_TEXTURE 着色器 → 玻璃降级为平板色。
	#   全息着色器不采样屏幕 → headless 下照常可用，不降级。
	if want == "glass" and _is_headless_render():
		want = ""
	_frosted = (want == "glass")
	if want.is_empty():
		_teardown_bg()
		queue_redraw()     # 让 _draw() 的平板色生效
		return
	_ensure_bg(want)


## 拆掉背景着色器层（平板路径 / 降级时调用）。
func _teardown_bg() -> void:
	if _glass != null and is_instance_valid(_glass):
		_glass.queue_free()
		_glass = null
	_bg_kind = ""


func _on_resized() -> void:
	# 面板尺寸变化时同步给着色器（圆角 SDF 需要精确尺寸）
	if _glass != null and is_instance_valid(_glass):
		_update_glass()


## headless / 无真实渲染后端时，SCREEN_TEXTURE 不可用，强制走纯色兜底。
## 真实窗口运行（Vulkan/OpenGL 驱动）才用磨砂模糊路径。
## 依据：headless 下 DisplayServer.get_name() == "headless"（本构建验证）。
static func _is_headless_render() -> bool:
	return DisplayServer.get_name().to_lower().contains("headless")


## 按需建立 / 换用背景着色器层（kind = "glass" | "holo"）；着色器不可用时退回平板路径。
func _ensure_bg(kind: String) -> void:
	var sh := _load_bg_shader(kind)
	if sh == null:
		_frosted = false  # 着色器缺失/加载失败 → 退回平板色，不阻断界面
		_bg_kind = ""
		queue_redraw()
		return
	if _glass == null or not is_instance_valid(_glass):
		var cr := ColorRect.new()
		cr.set_anchors_preset(Control.PRESET_FULL_RECT)
		cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 注：Godot 4 的 CanvasItem/ColorRect 无 transparent 属性；画布 alpha 由着色器
		# 输出的 COLOR.a 自动混合（与原 _draw 玻璃一致），无需手动开启。
		var mat := ShaderMaterial.new()
		mat.shader = sh
		cr.material = mat
		add_child(cr)
		move_child(cr, 0)  # 置于最底层，内容画在其上
		# ★★ 兜底：着色器边框 SDF 依赖 `panel_size` uniform，必须与「实际绘制的矩形」同步。
		#   尺寸改完那一帧子控件锚定重排的时序不保证，单靠 UIPanel.resized 偶发拿到旧尺寸
		#   → 边框画在错误（过小）的 SDF 上、面板边缘没了线 → 最小化/还原后「边框丢失」。
		#   改连 ColorRect 自身的 resized（它才是真正被画的矩形），尺寸一变立即重传 panel_size。
		if not cr.is_connected("resized", _update_glass):
			cr.resized.connect(_update_glass)
		_glass = cr
	else:
		var mat := _glass.material as ShaderMaterial
		if mat == null:
			mat = ShaderMaterial.new()
			_glass.material = mat
		if mat.shader != sh:
			# 玻璃 ↔ 全息：同一个 ColorRect，换 shader（uniform 名不同，故换完要重传参）
			mat.shader = sh
	_bg_kind = kind
	_update_glass()


## 取指定种类的背景着色器（首次用时加载并缓存；失败返回 null）。
func _load_bg_shader(kind: String) -> Shader:
	if kind == "holo":
		if _holo_shader == null and ResourceLoader.exists(_HOLO_SHADER_PATH):
			_holo_shader = load(_HOLO_SHADER_PATH) as Shader
		return _holo_shader
	if _glass_shader == null and ResourceLoader.exists(_GLASS_SHADER_PATH):
		_glass_shader = load(_GLASS_SHADER_PATH) as Shader
	return _glass_shader



func _update_glass() -> void:
	if _glass == null or not is_instance_valid(_glass):
		return
	var mat := _glass.material as ShaderMaterial
	if mat == null:
		return
	if size.x <= 0.0 or size.y <= 0.0:
		return
	if _bg_kind == "holo":
		_update_holo(mat)
		return
	mat.set_shader_parameter("tint", _fill_color)
	mat.set_shader_parameter("border_color", _border_color)
	mat.set_shader_parameter("corner_radius", _corner_radius)
	mat.set_shader_parameter("border_width", _border_width)
	mat.set_shader_parameter("blur_radius", UIStyle.GLASS_BLUR_RADIUS)
	# ★ 用「真正被画出来的 ColorRect」的尺寸，而不是 UIPanel 自身的 size —— 二者在 FULL_RECT
	#   下恒等，但用 ColorRect 尺寸可彻底规避「尺寸改完那一帧顺序不对」导致的 panel_size 陈旧。
	mat.set_shader_parameter("panel_size", _glass.size)
	mat.set_shader_parameter("highlight_strength", 0.16)
	mat.set_shader_parameter("glow_color", UIStyle.GLASS_GLOW)
	mat.set_shader_parameter("glow_width", 3.0)
	mat.set_shader_parameter("refract_pixels", UIStyle.GLASS_REFRACT)
	mat.set_shader_parameter("dispersion", UIStyle.GLASS_DISPERSION)
	mat.set_shader_parameter("iridescence", UIStyle.GLASS_IRIDESCENCE)
	mat.set_shader_parameter("scatter_strength", UIStyle.GLASS_SCATTER)
	mat.set_shader_parameter("film_strength", UIStyle.GLASS_FILM)
	mat.set_shader_parameter("film_thickness", UIStyle.GLASS_FILM_THICKNESS)
	mat.set_shader_parameter("specular_strength", UIStyle.GLASS_SPECULAR)
	mat.set_shader_parameter("light_dir", Vector2(0.55, -0.82))


## 量子全息面板参数（批次 59）：荧光蓝 + 椭圆径向 alpha（中心实、边缘虚）+ 无描边。
func _update_holo(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("tint", Color(UIStyle.HOLO_BLUE.r, UIStyle.HOLO_BLUE.g, UIStyle.HOLO_BLUE.b, 1.0))
	mat.set_shader_parameter("panel_size", size)
	mat.set_shader_parameter("corner_radius", _corner_radius)
	mat.set_shader_parameter("center_alpha", UIStyle.HOLO_CENTER_ALPHA)
	mat.set_shader_parameter("edge_alpha", UIStyle.HOLO_EDGE_ALPHA)
	mat.set_shader_parameter("core_power", UIStyle.HOLO_CORE_POWER)
	mat.set_shader_parameter("core_scale", UIStyle.HOLO_CORE_SCALE)
	mat.set_shader_parameter("glow_strength", UIStyle.HOLO_GLOW)


# ===================== 公开接口（与旧版兼容） =====================

func set_frosted(v: bool) -> void:
	# 记为「覆盖」：此后不再跟随主题（关卡舞台恒实心就靠这个）。
	_frosted_override = 1 if v else 0
	_sync_render()


func set_fill_color(c: Color) -> void:
	# 归类：命中主题调色板 → 记角色 + 透明度比例（换主题可无损重映射）；
	# 自定义色（如关卡舞台深底）→ 角色置空、原样保存，不随主题变。
	_fill_role = UIStyle.classify_fill(c)
	if _fill_role.is_empty():
		_fill_color = c
	else:
		_fill_ratio = UIStyle.fill_alpha_ratio(_fill_role, c.a)
		_fill_color = UIStyle.theme_fill(_fill_role, _fill_ratio)
	_after_color_changed()


func set_border_color(c: Color) -> void:
	_border_role = UIStyle.classify_border(c)
	if _border_role.is_empty():
		_border_color = c
	else:
		_border_ratio = UIStyle.border_alpha_ratio(c.a)
		_border_color = UIStyle.theme_border(_border_ratio)
	_after_color_changed()


func _after_color_changed() -> void:
	if _glass != null and is_instance_valid(_glass):
		_update_glass()
	queue_redraw()


func set_corner_radius(r: float) -> void:
	_corner_radius = max(0.0, r)
	if _glass != null and is_instance_valid(_glass):
		_update_glass()
	else:
		queue_redraw()


func set_border_width(w: float) -> void:
	_border_width = max(0.5, w)
	if _glass != null and is_instance_valid(_glass):
		_update_glass()
	else:
		queue_redraw()


# ===================== 绘制 =====================

func _draw() -> void:
	# 磨砂路径下，玻璃（填充/渐变/高光/描边/光晕）全部由着色器绘制，_draw 无需再画。
	if _glass != null and is_instance_valid(_glass):
		return
	_draw_gradient_glass()


## 无着色器层时的填充绘制：
##   · 纯色主题 → 一层「半透明纯色」平板 + 同色系描边（不发光、无顶部高光）；
##   · 量子全息兜底（着色器缺失 / 被强制平板）→ 一层荧光蓝薄纱，**无边框**；
##   · 玻璃主题兜底（着色器不可用）→ 半透明渐变玻璃观感（外发光 + 顶部高光 + 描边）。
func _draw_gradient_glass() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	if UIStyle.is_solid_mode():
		if _corner_radius > 0.0:
			_draw_rounded_rect(rect, _corner_radius, _fill_color, true)
			_draw_rounded_rect(rect, _corner_radius, _border_color, false, _border_width)
		else:
			draw_rect(rect, _fill_color, true)
			draw_rect(rect, _border_color, false, _border_width)
		return
	if UIStyle.is_holo_mode():
		# 全息兜底：荧光蓝薄纱 + 无描边（真正的径向渐变需要着色器，此处只保证"无边框 + 蓝"）。
		if _corner_radius > 0.0:
			_draw_rounded_rect(rect, _corner_radius, _fill_color, true)
		else:
			draw_rect(rect, _fill_color, true)
		return
	if _corner_radius > 0.0:
		_draw_rounded_rect(rect.grow(3.0), _corner_radius + 3.0, UIStyle.GLASS_GLOW, false, 3.0)
		_draw_rounded_rect(rect, _corner_radius, _fill_color, true)
	else:
		draw_rect(rect.grow(3.0), UIStyle.GLASS_GLOW, false, 3.0)
		draw_rect(rect, _fill_color, true)
	_draw_top_highlight(rect)
	if _corner_radius > 0.0:
		_draw_rounded_rect(rect, _corner_radius, _border_color, false, _border_width)
	else:
		draw_rect(rect, _border_color, false, _border_width)


## 顶部镜面高光：贴着上边缘的一条细亮带
func _draw_top_highlight(rect: Rect2) -> void:
	var h := mini(6.0, maxf(2.0, rect.size.y * 0.18))
	var hl := Rect2(rect.position.x + _border_width, rect.position.y + _border_width * 0.5,
		maxf(0.0, rect.size.x - _border_width * 2.0), h)
	if _corner_radius > 0.0:
		_draw_rounded_rect(hl, maxf(0.0, _corner_radius - 3.0), UIStyle.GLASS_HIGHLIGHT, true)
	else:
		draw_rect(hl, UIStyle.GLASS_HIGHLIGHT, true)


## 圆角矩形（多边形近似）
## filled = true 时填充；false 时仅描边（width 控制线宽）
func _draw_rounded_rect(rect: Rect2, radius: float, color: Color, filled: bool, width: float = 1.0) -> void:
	if radius <= 0.0:
		if filled:
			draw_rect(rect, color, true)
		else:
			draw_rect(rect, color, false, width)
		return
	var r: float = min(radius, min(rect.size.x, rect.size.y) * 0.5)
	var pts: PackedVector2Array = PackedVector2Array()
	var segs_per_corner: int = 6

	pts.append(rect.position + Vector2(0, r))
	for i in segs_per_corner + 1:
		var t: float = PI + PI * 0.5 * float(i) / float(segs_per_corner)
		pts.append(rect.position + Vector2(r, r) + Vector2(cos(t) * r, sin(t) * r))
	pts.append(rect.position + Vector2(rect.size.x - r, 0))
	for i in segs_per_corner + 1:
		var t: float = -PI * 0.5 + PI * 0.5 * float(i) / float(segs_per_corner)
		pts.append(rect.position + Vector2(rect.size.x - r, r) + Vector2(cos(t) * r, sin(t) * r))
	pts.append(rect.position + Vector2(rect.size.x, rect.size.y - r))
	for i in segs_per_corner + 1:
		var t: float = 0.0 + PI * 0.5 * float(i) / float(segs_per_corner)
		pts.append(rect.position + Vector2(rect.size.x - r, rect.size.y - r) + Vector2(cos(t) * r, sin(t) * r))
	pts.append(rect.position + Vector2(r, rect.size.y))
	for i in segs_per_corner + 1:
		var t: float = PI * 0.5 + PI * 0.5 * float(i) / float(segs_per_corner)
		pts.append(rect.position + Vector2(r, rect.size.y - r) + Vector2(cos(t) * r, sin(t) * r))
	pts.append(rect.position + Vector2(0, r))

	if filled:
		draw_colored_polygon(pts, color)
	else:
		for i in pts.size():
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[(i + 1) % pts.size()]
			draw_line(a, b, color, width)
