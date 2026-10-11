# desktop_icon_boundary.gd
# 「桌面图标边界」—— 在每个桌面图标的「选中框」四边各生成一条 1~3px 碰撞墙，
# 把图标"围"起来，防止积木盖住 / 进入图标区域。
#
# 数据来源：已从 sysinfo.json 移除 → 改为由 desktop.gd 运行时的「内存枚举」
# （enumerate_scene.ps1 → JSON → JSON.parse_string）直接给到 spawn_all：
#   icon_cell_spacing（间距）与 items[]，items 里的 x/y/w/h 是图标的**整项矩形**
#   （LVM_GETITEMRECT + LVIR_BOUNDS：图标 + 文字标签的整体，即"选中图标后出现的框"）
#   在桌面像素坐标下的 左上角 与 宽高。
#
# 几何（场景坐标 == 屏幕像素）：四条墙的中心线正好落在选择框的四条边上，
#   围住的区域 == 选择框（"积木围住的地方正好是选中图标后框的范围"）：
#   · 统一尺寸：名字过长的图标会使矩形变宽/变高 → 取全体 items 中出现次数最多的
#     w、h（众数）作为标准尺寸，所有图标一律按它处理（"默认都当大小一样的处理"）。
#   · 横向按各图标自身中心对齐（cx = x + w/2，框从 cx - std_w/2 开始），这样长名字
#     图标的框也不会横向跑偏；纵向按各图标自身的 y（行顶）对齐。
#   · w/h 全部缺失时退回 1×icon_cell_spacing 的方形旧基准（cell 兜底）。
#
# ★ 分层与标签（本轮变更）：
#   · 碰撞图层 = [默认, 桌面图标]（BlockLayers.DEFAULT + DESKTOP_ICON）—— 为日后"分层"铺路：
#     桌面（含图标）恒在最下面，普通积木因自带默认层仍会与其碰撞（行为不变）。
#   · 标签 = 碰撞 + 桌面图标边界 + 系统自动生成（BlockTags.AUTO_GENERATED）：
#     未来存档系统不保存系统自动生成的积木；框选/编辑/删除也忽略它们。
#   · 从「隐形墙」改为「可见」：带 show + fill，用半透明浅红填充，方便玩家直观看到这些墙。
class_name DesktopIconBoundary
extends RefCounted

# 墙厚（像素）—— 需求指定 1，但为了"进入游戏就能看清"，做成 3px 起，仍保留碰撞薄感。
# 仅用于计算墙的尺寸/位置（几何），不决定任何其它属性。
const THICKNESS := 3.0

# 积木类型名（落盘到 res://block_types/icon_boundary.json；保存位置=本体，可经 JSON 编辑生效）。
# ★ 所有「非尺寸/位置」属性（fill_color / collision_layer / tags / display_layer …）以 JSON 为准（用户改即生效）；
#   下方 _wall_def() 仅作 JSON 不存在时的内存回退模板；JSON 仅在创建时读取、保存时写盘（见 BlockTypes）。
const TYPE := "icon_boundary"


# 登记「图标边界」内置类型的默认模板（仅内存，绝不写盘；JSON 仅在创建时读取、保存时写盘）。
# 几何（width/height）按每个图标在 spawn_all 时计算覆写，不进 JSON。
static func ensure_type() -> void:
	BlockTypes.ensure_builtin_type(TYPE, _wall_def())


# 图标边界共用的标签：可见 + 只碰撞 + 标记"图标边界/系统生成"，**可绘制**
static func tags() -> PackedStringArray:
	var t: PackedStringArray = []
	t.append(BlockTags.SHOW)
	t.append(BlockTags.FILL)
	t.append(BlockTags.COLLISION)
	t.append(BlockTags.DESKTOP_ICON_BOUNDARY)
	t.append(BlockTags.AUTO_GENERATED)
	return t


# 一条图标边界墙的公共定义（尺寸由 _wall 按图标算好后覆写）
static func _wall_def() -> Dictionary:
	var t := tags()
	return {
		"name": "icon_boundary",
		"display_layer": 0,               # 与普通积木同层：图标边界可见但不下压其它内容
		"collision_layer": BlockLayers.icon_boundary_layers(),
		"border_width": 1.0,
		"border_color": "#00000000",
		"fill_color": "#FF666600",
		"tags": t,
		"fill_path": "",
		"fill_mode": 0,
		"fill_anim": 0,
		"rotation_deg": 0.0,
		"text_boxes": [],
		"parent_id": 0,
		"child_ids": [],
	}


# 按桌面图标数据生成全部图标边界墙，加入 host。
#   icon_cell_spacing: 图标网格间距（像素）—— 仅作 w/h 全缺失时的兜底尺寸。
#   items: [{name,x,y,w,h}, ...]，x/y/w/h 为图标整项矩形（选中框）的左上角与宽高。
# 每条墙分配字符串 ID：图标名(x,y)U/D/L/R —— 如 "收藏夹(560,120)U"。
#   （x,y 取枚举到的整项矩形左上角、四舍五入取整；U/D/L/R = 上/下/左/右。）
# 返回生成的 Block 列表（供释放 / 差量同步）。
static func spawn_all(host: Node, icon_cell_spacing: Variant, items: Variant) -> Array:
	var out: Array = []
	if host == null or items == null or not (items is Array):
		return out
	var cell := maxf(float(icon_cell_spacing), THICKNESS)
	var std := _uniform_size(items, cell)   # 全体统一的选择框尺寸 [w, h]
	# 静态属性（颜色/标签/碰撞层/边框）改由 JSON 类型驱动：优先读 BlockTypes（用户编辑生效），
	# 文件缺失/未注册时回退到代码默认 _wall_def()，保证健壮性。
	var def := BlockTypes.get_def(TYPE)
	if def.is_empty():
		def = _wall_def()
	for it in items:
		if not (it is Dictionary):
			continue
		var x := float(it.get("x", 0.0))
		var y := float(it.get("y", 0.0))
		var w := float(it.get("w", 0.0))
		# 横向按自身中心对齐（长名字图标框更宽也不跑偏）；纵向按自身行顶对齐
		var box := _box_for(x, y, w, std)
		var left := box.position.x
		var right := box.end.x
		var top := box.position.y
		var bottom := box.end.y
		var cx := left + std.x * 0.5
		var cy := top + std.y * 0.5
		# 字符串 ID 基名：图标名(整数坐标)
		var base := "%s(%d,%d)" % [String(it.get("name", "")), int(round(x)), int(round(y))]
		# 四条墙中心线落在选择框四边上（长度各加一个 THICKNESS 盖住四角缝隙）
		out.append(_wall(host, def, cx, top, std.x + THICKNESS, THICKNESS, base + "U"))     # top
		out.append(_wall(host, def, cx, bottom, std.x + THICKNESS, THICKNESS, base + "D"))  # bottom
		out.append(_wall(host, def, left, cy, THICKNESS, std.y + THICKNESS, base + "L"))    # left
		out.append(_wall(host, def, right, cy, THICKNESS, std.y + THICKNESS, base + "R"))   # right
	return out


# 单个图标的「选择框」矩形：横向按自身中心对齐 std.x（长名字图标框更宽也不跑偏），
# 纵向按自身行顶对齐 std.y。
# ★ spawn_all 与 box_rects() 共用本函数 —— 图标选择框的几何**只有这一处定义**，
#   改这里两处同时生效（避免"围墙"与"避让区"各算一套、悄悄漂移）。
static func _box_for(x: float, y: float, w: float, std: Vector2) -> Rect2:
	return Rect2(x + w * 0.5 - std.x * 0.5, y, std.x, std.y)


# 全体桌面图标的「选择框」矩形（与 spawn_all 生成的四条墙所围区域**完全一致**）。
# 用途：给「挑空白落点」搜索当**避让区** —— 虚视跳转器 / 回收站这类自动放置的常驻积木
#   若落在某个图标的选择框里，就会被那个图标的四条边界墙围住，后果是：
#     · 除"拖动"外（拖动会临时切到 dragging 层）其它移动（重力/受控/命令）都进不去 ——
#       对以"能被进入"为存在意义的积木（如检测区「回收站」）是致命的；
#     · 那四条墙本身会落在积木范围内（被判"进入检测区"等），产生莫名其妙的副作用。
# ★ 几何必须与 spawn_all 同步：两者都走 _uniform_size + _box_for + 同一个 cell 兜底。
static func box_rects(items: Variant, icon_cell_spacing: Variant) -> Array[Rect2]:
	var out: Array[Rect2] = []
	if items == null or not (items is Array):
		return out
	var cell := maxf(float(icon_cell_spacing), THICKNESS)
	var std := _uniform_size(items, cell)
	for it in items:
		if not (it is Dictionary):
			continue
		out.append(_box_for(float(it.get("x", 0.0)), float(it.get("y", 0.0)),
			float(it.get("w", 0.0)), std))
	return out


# 统一尺寸：取 items 中出现次数最多的 w / h（众数）→ 所有图标按同一尺寸处理。
# 全部缺失（<=0）时用 cell 作方形兜底（旧基准）。返回 Vector2(标准宽, 标准高)。
static func _uniform_size(items: Variant, cell: float) -> Vector2:
	var wc := {}
	var hc := {}
	if items is Array:
		for it in items:
			if not (it is Dictionary):
				continue
			var w := int(it.get("w", 0))
			var h := int(it.get("h", 0))
			if w > 0:
				wc[w] = int(wc.get(w, 0)) + 1
			if h > 0:
				hc[h] = int(hc.get(h, 0)) + 1
	return Vector2(_mode_of(wc, cell), _mode_of(hc, cell))


# 对外暴露：返回「图标选择框」统一尺寸（std.w × std.h），即「围住图标的四个边组成的空间」。
# 供其它系统（如虚视跳转器对齐图标盒子）复用，避免重复众数计算逻辑。
static func uniform_size(items: Variant, cell: float) -> Vector2:
	return _uniform_size(items, cell)


# ==================== 桌面图标网格吸附（批次 58） ====================
#
# 需求：桌面上的「伪装图标」积木（虚视跳转器 / 回收站 / 此电脑 …，标签 BlockTags.DESKTOP_ICON）
#   拖动松手后要**自动对齐到桌面图标会在的位置**，这样它们看起来才像真的桌面图标；
#   按住 Ctrl 拖动则自由摆放、松开也不对齐。
#
# ★ 为什么不是「吸附到最近的已有图标」：那样把积木拖到桌面右下角空白处时会被拽回左上角
#   的某个图标，视觉上"跳很远"。所以这里用**网格推算**：只要知道左上角那个图标的中心与
#   相邻列/行的间距，就能算出全屏所有"图标会出现的位置"，没有图标的地方同样可以对齐。
#
# 网格来源 = 与图标边界墙同一份数据（items 的图标选择框 + icon_cell_spacing）：
#   · 原点 = 所有图标选择框中心的 min(x) / min(y)（即左上角那个图标）；
#   · 单元 = 相邻两列的 x 差 / 相邻两行的 y 差；只有一列/一行时退回 icon_cell_spacing。
# 无数据 / 退化数据 → 原样返回 p（调用方据此判断"没对齐"）。
static func grid_snap(p: Vector2, items: Variant, icon_cell_spacing: Variant) -> Vector2:
	if not (items is Array) or (items as Array).is_empty():
		return p
	var cell_fallback := maxf(float(icon_cell_spacing), THICKNESS)
	var std := _uniform_size(items, cell_fallback)
	var centers: Array = []
	for it in items:
		if it is Dictionary:
			centers.append(_box_for(float(it.get("x", 0.0)), float(it.get("y", 0.0)),
				float(it.get("w", 0.0)), std).get_center())
	if centers.is_empty():
		return p
	var xs := _unique_axis(centers, true)
	var ys := _unique_axis(centers, false)
	var ox := float(xs[0])
	var oy := float(ys[0])
	var cw := cell_fallback
	if xs.size() >= 2:
		cw = float(xs[1]) - ox
	var ch := cell_fallback
	if ys.size() >= 2:
		ch = float(ys[1]) - oy
	if cw <= 0.5:
		cw = cell_fallback
	if ch <= 0.5:
		ch = cell_fallback
	var qx := roundf((p.x - ox) / cw)
	var qy := roundf((p.y - oy) / ch)
	return Vector2(ox + qx * cw, oy + qy * ch)


# 取各中心点的 x（use_x=true）或 y 坐标，去重（容差 1px 视为同一列/行）后升序。
static func _unique_axis(centers: Array, use_x: bool) -> Array:
	var out: Array = []
	for c in centers:
		var vv: Vector2 = c
		var v: float = vv.x if use_x else vv.y
		var dup := false
		for e in out:
			if absf(float(e) - v) <= 1.0:
				dup = true
				break
		if not dup:
			out.append(v)
	out.sort()
	return out


# 字典 {值: 次数} → 众数（并列时取较小值）；空/全无效 → fallback。
static func _mode_of(counts: Dictionary, fallback: float) -> float:
	var best := -1
	var best_n := 0
	for k in counts:
		var n := int(counts[k])
		if n > best_n or (n == best_n and int(k) < best):
			best = int(k)
			best_n = n
	return float(best) if best > 0 else fallback


# 由 desktop_icons 段算一个轻量签名，供 desktop.gd 判断"图标是否变化了才重排"
static func signature(icon_cell_spacing: Variant, items: Variant) -> String:
	var parts := PackedStringArray()
	parts.append(str(icon_cell_spacing))
	if items is Array:
		for it in items:
			if it is Dictionary:
				parts.append("%s|%s|%s|%s|%s" % [
					it.get("name", ""), it.get("x", 0), it.get("y", 0),
					it.get("w", 0), it.get("h", 0)])
	parts.sort()
	return "%d|%s" % [parts.size(), "|".join(parts)]


# 生成单条墙：结构 + 尺寸 + 中心 + 字符串 ID（碰撞判定全程用 global_position，见 Block._can_move_to）
static func _wall(host: Node, def: Dictionary, cx: float, cy: float, w: float, h: float, sid: String) -> Block:
	var b := Block.new()
	BlockProperty.apply_to_block(b, def)   # 与"按类型生成"完全同一条路径
	b.width = w
	b.height = h
	b.global_position = Vector2(cx, cy)
	host.add_child(b)                      # 入树后才有 ID / 文本框视图
	if not sid.is_empty() and not BlockManager.set_string_id(b, sid):
		push_warning("[DesktopIconBoundary] 字符串 ID '%s' 分配失败（可能是重名图标）" % sid)
	return b


# 释放全部图标边界墙（仅供重排/测试）。先注销（数字 + 字符串 ID），再释放。
static func destroy(walls: Array) -> void:
	for w in walls:
		if is_instance_valid(w) and w is Block:
			BlockManager.unregister(w)
			w.queue_free()
	walls.clear()