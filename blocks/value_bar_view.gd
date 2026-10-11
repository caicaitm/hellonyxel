# value_bar_view.gd
# 积木数值条的「视图节点」——数值条显示的完全节点化版本（仿 text_box_view.gd）。
#
# 每个数值条 = 一个真实子节点（本类，Control），挂在 Block 之下，
# 自动继承积木的位置/旋转/缩放；渲染用节点自带 _draw，不再依赖 Block._draw。
#
# 坐标：data.center_offset 是「相对积木中心」的偏移。
#   position = center_offset - size/2   （Control 的 position 是左上角）
#
# 渲染：
#   - 连续条：先画「消耗色」整条底，再叠「激活色」填充（占比 = 当前/最大）；隔断画分割线。
#   - 图标：把条均分成 max 个格子，填充格画激活图标；消耗格按消耗模式画（空 / auto 黑剪影 / 指定图标）。
#   - 横向：0 在最左 → 填充向右增长；纵向：0 在最下 → 填充向上增长。
#   - 文字标签：中心显示「当前/最大」或「xx%」。
#
# 变量绑定：current_var / max_var 指向全局变量（autoload/GlobalVars），
#   全局变量变化 → 本视图实时重算比例并重绘（见 _on_global_var_changed）。
class_name ValueBarView
extends Control

const SEG_COLOR: Color = Color(0, 0, 0, 0.55)   # 隔断线颜色
const SEG_W: float = 1.0                         # 隔断线宽
const LABEL_FONT_SIZE: int = 12
# ★ 图标放大上限（批次 20）：格子比纹理大时按此上限放大，避免极端参数把图撑成巨幅。
const MAX_ICON_SCALE: float = 4.0

var data: ValueBar = null
# 拥有者积木（不写 Block 类型，避免循环类引用；用动态访问读 block.tags / block.rotation）
var block = null

var _label: Label
var _active_tex: Texture2D = null
var _consumed_tex: Texture2D = null
var _active_path_cache: String = ""
var _consumed_path_cache: String = ""

var _gv_connected: bool = false


func _ready() -> void:
	_build()
	_apply()


func setup(bar: ValueBar, owner_block) -> void:
	# 切换数据源时断开旧的全局变量连接、清缓存
	_disconnect_gv()
	data = bar
	block = owner_block
	_active_path_cache = ""
	_consumed_path_cache = ""
	_build()
	_apply()
	_connect_gv()


func _build() -> void:
	if _label != null:
		return
	# 本控件不接收鼠标：保证积木的拖动 / 右键仍然生效
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label = Label.new()
	_label.name = "Label"
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 3)
	_label.add_theme_font_size_override("font_size", LABEL_FONT_SIZE)
	var f := UIStyle.get_cjk_font()
	if f != null:
		_label.add_theme_font_override("normal_font", f)
	add_child(_label)


# ---- 全局变量绑定（当前/最大值变化 → 实时刷新）----
func _connect_gv() -> void:
	if _gv_connected:
		return
	if GlobalVars != null and GlobalVars.has_signal("changed"):
		GlobalVars.changed.connect(_on_global_var_changed)
		_gv_connected = true

func _disconnect_gv() -> void:
	if _gv_connected and GlobalVars != null and GlobalVars.has_signal("changed"):
		GlobalVars.changed.disconnect(_on_global_var_changed)
	_gv_connected = false


func _on_global_var_changed(var_name: String, _value: Variant) -> void:
	if data == null:
		return
	# 绑的是局部变量时，比例不走全局变量 → 这里无需响应（改值由 Block 显式 refresh 触发）
	if _local_var() != null:
		return
	# 只有本条锚定的变量变化才刷新（空名视为不锚定，跳过）
	var n := _bind_name()
	if n != "" and var_name == n:
		_refresh()
	elif data.max_var != "" and var_name == data.max_var:
		_refresh()


# ---- 变量解析 ----
# ★★ 批次 19：单一「对应变量」求值链 —— **局部变量优先，回退全局变量**。
#   1) bind_var 指向本积木的局部变量（见 local_var.gd）→ 直接读它的 current/max；
#   2) 找不到同名局部变量 → 回退全局变量（autoload/GlobalVars），兼容旧档 / 旧写法；
#   3) 都没有 → 分子 0 / 分母 1（比例 0）。
#   为什么局部变量优先：它是积木私有的，语义上比全局共享变量更贴近「这块积木的血量」。
func _local_var() -> LocalVar:
	if block == null or not is_instance_valid(block):
		return null
	if not (block.has_method("find_local_var")):
		return null
	var nm := _bind_name()
	if nm == "":
		return null
	var lv = block.find_local_var(nm)
	if lv is LocalVar:
		return lv
	return null


## 本条绑定的变量名（bind_var 优先；为空则回退旧 current_var —— 老档兼容）。
func _bind_name() -> String:
	if data == null:
		return ""
	var n := data.bind_var.strip_edges()
	if n != "":
		return n
	# 老档只有 current_var：若它同时存在 max_var，则视作旧的「全局变量对」用法，
	# 分子取 current_var；若只有 current_var 单个名字，也照样拿它当分子（分母仍走 max_var）。
	return data.current_var.strip_edges()


# ---- 变量解析（全局变量，autoload/GlobalVars）----
func _resolve_var(name: String, default_val: float) -> float:
	if name == "":
		return default_val
	if GlobalVars != null and GlobalVars.has_method("get_var"):
		var v = GlobalVars.get_var(name, null)
		if v != null and (v is float or v is int):
			return float(v)
	return default_val


func _current() -> float:
	var lv := _local_var()
	if lv != null:
		return lv.current_value
	# 回退：旧写法 current_var（全局变量）/ bind_var 当全局变量名也能用
	return _resolve_var(_bind_name(), 0.0)


func _max() -> float:
	var lv := _local_var()
	if lv != null:
		# ★ 局部变量的「最大值」就是分母；<=0 时 ratio() 会退化为 0
		return lv.max_value
	# 回退：旧写法 max_var 优先；没有则拿绑定名当最大值（老档里 current/max 常常同值）
	var n := _bind_name()
	if data != null and data.max_var.strip_edges() != "":
		return _resolve_var(data.max_var, 1.0)
	return _resolve_var(n, 1.0)

func _ratio() -> float:
	var m: float = _max()
	if m <= 0.0:
		return 0.0
	return clampf(_current() / m, 0.0, 1.0)


func _consumed_mode() -> int:
	var s: String = data.icon_consumed_path.strip_edges()
	if s == "auto":
		return 2   # auto = 激活图标的黑色剪影
	if s != "":
		return 1   # 指定图标
	return 0      # 空 = 消耗位不显示


# ---- 把数据完整应用到本视图（尺寸 / 位置 / 显隐 / 文字 / 重绘）----
func _apply() -> void:
	if data == null:
		size = Vector2(1.0, 1.0)
		return
	size = Vector2(maxf(1.0, data.width), maxf(1.0, data.height))
	position = data.center_offset - size * 0.5
	# 纹理缓存：路径变化才重新加载
	_reload_textures()
	_refresh()


# 完整重新应用（尺寸/样式/变量都可能变）
func refresh() -> void:
	_apply()


# 仅重算显隐（标签变化时由 Block 调用）
func refresh_visibility() -> void:
	_apply_visibility()


func _apply_visibility() -> void:
	var visible_ok: bool = true
	if block != null:
		visible_ok = (BlockTags.SHOW in block.tags)
	visible = visible_ok and data != null


func _refresh() -> void:
	if data == null:
		return
	_draw_label()
	queue_redraw()
	_apply_visibility()


func _draw_label() -> void:
	if _label == null:
		return
	# ★ 批次 21：**图标样式不显示文字** —— 一串图标本身已足够表达「有多少/还剩多少」，
	#   再叠一行 "5/30" 反而把图标压住、读数不清（弹药条这类尤其明显）。
	#   需求：依靠图片表示数值的条（Style.ICON）只留图片。
	if int(data.style) == ValueBar.Style.ICON:
		_label.visible = false
		_label.text = ""
		return
	_label.visible = true
	match int(data.show_mode):
		ValueBar.ShowMode.PERCENT:
			var pct: int = int(round(_ratio() * 100.0))
			_label.text = "%d%%" % pct
		_:
			_label.text = "%s/%s" % [_fmt_num(_current()), _fmt_num(_max())]

func _fmt_num(v: float) -> String:
	if absf(v - roundf(v)) < 0.001:
		return str(int(roundf(v)))
	return str(snapped(v, 0.01))


func _reload_textures() -> void:
	var ap: String = data.icon_active_path.strip_edges()
	var cp: String = data.icon_consumed_path.strip_edges()
	var need_reload: bool = (ap != _active_path_cache) or (cp != _consumed_path_cache)
	if not need_reload and (_active_tex != null or _consumed_tex != null):
		return
	_active_path_cache = ap
	_consumed_path_cache = cp
	_active_tex = _load_tex(ap)
	if _consumed_mode() == 1:
		_consumed_tex = _load_tex(cp)
	else:
		_consumed_tex = null


func _load_tex(path: String) -> Texture2D:
	if path == "":
		return null
	# ★ 走 TextureCache：既支持 res:// 已导入图，也支持玩家素材目录的绝对路径图。
	var tex := TextureCache.fetch(path)
	if tex != null:
		return tex
	# 兼容：纯相对路径（未带 res://）时补前缀再试一次
	if not path.begins_with("res://") and not path.begins_with("user://"):
		return TextureCache.fetch("res://" + path)
	push_warning("[ValueBarView] 无法加载图标纹理: %s" % path)
	return null


func _draw() -> void:
	if data == null:
		return
	match int(data.style):
		ValueBar.Style.ICON:
			_draw_bar_icon()
		_:
			_draw_bar_continuous()


func _draw_bar_continuous() -> void:
	var w: float = size.x
	var h: float = size.y
	# 底：消耗色（能量条消耗色为透明 → 底不可见，仅填充可见）
	draw_rect(Rect2(0, 0, w, h), data.consumed_color)
	var ratio: float = _ratio()
	var seg: int = maxi(1, int(data.segments))
	if data.orientation == ValueBar.Orientation.HORIZONTAL:
		var fw: float = w * ratio
		if fw > 0.0:
			draw_rect(Rect2(0, 0, fw, h), data.active_color)
		if seg > 1:
			for i in range(1, seg):
				var x: float = w * float(i) / float(seg)
				draw_line(Vector2(x, 0), Vector2(x, h), SEG_COLOR, SEG_W)
	else:
		var fh: float = h * ratio
		if fh > 0.0:
			draw_rect(Rect2(0, h - fh, w, fh), data.active_color)
		if seg > 1:
			for i in range(1, seg):
				var y: float = h * float(i) / float(seg)
				draw_line(Vector2(0, y), Vector2(w, y), SEG_COLOR, SEG_W)


func _draw_bar_icon() -> void:
	var w: float = size.x
	var h: float = size.y
	var max_n: int = maxi(1, int(round(_max())))
	var filled: int = clampi(int(floor(_current())), 0, max_n)
	if data.orientation == ValueBar.Orientation.HORIZONTAL:
		var cell: float = w / float(max_n)
		for i in range(max_n):
			var rect := Rect2(i * cell, 0, cell, h)
			_draw_icon_cell(rect, i < filled)
	else:
		var cell: float = h / float(max_n)
		for i in range(max_n):
			# 0 在最下 → 第 i 格位于底部起第 i+1 格
			var rect := Rect2(0, h - (i + 1) * cell, w, cell)
			_draw_icon_cell(rect, i < filled)


func _draw_icon_cell(cell: Rect2, is_filled: bool) -> void:
	if is_filled:
		if _active_tex != null:
			draw_texture_rect(_active_tex, _fit_dst(_active_tex, cell), false, Color(1, 1, 1, 1))
		else:
			draw_rect(cell, data.active_color)   # 无纹理兜底：用激活色块
	else:
		match _consumed_mode():
			2:   # auto：激活图标黑色剪影
				if _active_tex != null:
					draw_texture_rect(_active_tex, _fit_dst(_active_tex, cell), false, Color(0, 0, 0, 1))
				else:
					draw_rect(cell, Color(0, 0, 0, 1))
			1:   # 指定消耗图标
				if _consumed_tex != null:
					draw_texture_rect(_consumed_tex, _fit_dst(_consumed_tex, cell), false, Color(1, 1, 1, 1))
			0:   # 空：消耗位不显示
				pass


# 在格子内居中、等比适配地放纹理
# ★ 批次 20：**双向等比适配** —— 格子比纹理大也照常放大。
#   原来这里有一句 `s = minf(s, 1.0)`（怕放大糊），导致「格子比图片大时图片不放大」，
#   而「格子比图片小时会缩小」—— 缩放行为不对称，看起来是 bug。
#   现取宽比/高比中的**较小者**（contain 适配，整张图都在格子里、不裁切）：
#   格子大 → 放大到撑满（上限 MAX_ICON_SCALE 防止极端参数把图撑爆）；格子小 → 缩小。
#   图标类素材（如 bullet.png）本就按格数均分格子，放大是正常需求。
func _fit_dst(tex: Texture2D, cell: Rect2) -> Rect2:
	var tw: float = tex.get_width()
	var th: float = tex.get_height()
	if tw <= 0 or th <= 0:
		return cell
	# 取「宽比」与「高比」的较小者 = contain 适配（保证整张图都在格子里，不裁切）
	var s: float = minf(cell.size.x / tw, cell.size.y / th)
	# 上限 4x：格子被拉得极大时别把像素图撑成巨幅（观感与性能都失控）
	s = minf(s, MAX_ICON_SCALE)
	var dw: float = tw * s
	var dh: float = th * s
	var x: float = cell.position.x + (cell.size.x - dw) * 0.5
	var y: float = cell.position.y + (cell.size.y - dh) * 0.5
	return Rect2(x, y, dw, dh)


func _exit_tree() -> void:
	_disconnect_gv()
