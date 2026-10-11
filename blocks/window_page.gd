# window_page.gd
# 「程序页面」积木 —— 每个可见程序窗口对应若干系统生成的积木：
#   · 4 条「边框」积木（碰撞图层 = [默认, 程序页面(边框)]）：积木能落在页面的边框上而不下落；
#   · 1 块「覆盖」积木（碰撞图层 = [程序页面(覆盖)]，与默认无交集 → 不阻挡普通积木）：
#     默认全透明、显示层高于桌面内容 → 只承担碰撞/分层占位，不画罩层（想要罩层改 JSON 的 fill_color alpha）。
#
# 几何来源：实时窗口枚举（enumerate_scene.ps1 → JSON → 内存解析），非落盘的 sysinfo.json。
#   每轮拿到完整窗口列表后调用 sync()，用窗口句柄做**差量更新**：
#     窗口还开着 → 只更新几个积木的尺寸/中心；新开的 → 新建；关/最小化的 → 释放。
#   这样开/关/最小化窗口时不会整批重建、也不闪。
#
# 分层约定：桌面（含图标边界）恒在最下层；各程序页面的覆盖积木在其上，且越靠前的窗口封面越靠上。
class_name WindowPage
extends RefCounted

# 边框厚度（像素）。仅用于计算边框积木的尺寸/位置（几何），不决定任何其它属性。
const FRAME_THICKNESS := 4.0

# ★★ 覆盖积木显示层的**安全上限**：覆盖积木带 cutout（镂空遮罩）——它会「镂掉」所有**比它先绘制**
#   的积木（display_layer 更低者）在覆盖矩形内的像素（MUL 打洞），是「窗口盖住桌面文件」的正确语义。
#   但运行时显示层 = JSON 基数(默认 32) + 窗口 z 序，而 **z 是枚举序号、会随打开的窗口数无上限增长**：
#     实测：只开 4 个窗口时 cover=32+z(33..35) 尚低于玩家积木(64)；
#           一旦系统顶层窗口数 ≥ 33，cover 就会升到 ≥65 → **开始把玩家新建的积木整块镂掉**
#           （用户看到的「桌面新建积木 → 有残影但本体消失」）；≥59 时连页面边框(90)也会被镂掉。
#   因此把覆盖积木的显示层**夹在 [32, 63]**：始终高于桌面层(0)、低于玩家积木(64)，多窗口叠放顺序保留。
const COVER_LAYER_MIN := 32.0
const COVER_LAYER_MAX := 63.0

# ★ 所有「非尺寸/位置」的属性（display_layer / fill_color / border_color / collision_layer / tags …）
#   全部以 res://block_types/page_frame.json、page_cover.json 的 JSON 为准（用户改 JSON 即生效）。
#   下方 _frame_def() / _cover_def_default() 仅作为「JSON 文件不存在时的内存回退模板」，
#   文件一旦存在就以 JSON 内容为准；JSON 仅在创建该类型积木时读取，仅在保存积木种类时写盘
#   （见 BlockTypes.get_def / register；ensure_builtin_type 现在只登记内存默认、绝不写盘）。
#   覆盖积木运行时显示层 = JSON 的 display_layer 基数 + 窗口 z 序（多窗口叠放顺序由 JSON 决定，脚本不再硬编码基数）。

# 积木类型名（落盘到 res://block_types/page_frame.json、page_cover.json；保存位置=本体，可经 JSON 编辑生效）
const FRAME_TYPE := "page_frame"
const COVER_TYPE := "page_cover"


# 登记「页面边框 / 页面覆盖」两类内置类型的默认模板（仅内存，绝不写盘）。
# JSON 文件在创建对应积木时按需读取（用户改 JSON 即生效），仅在保存积木种类时写盘。
# 覆盖积木的显示层按窗口 z 序在 sync 时动态覆写（见 _sync_cover），JSON 里只存基础层。
static func ensure_types() -> void:
	BlockTypes.ensure_builtin_type(FRAME_TYPE, _frame_def())
	BlockTypes.ensure_builtin_type(COVER_TYPE, _cover_def_default())


# 边框积木的标签：可见 + 只碰撞 + 标记"程序页面边框 / 系统生成"
static func frame_tags() -> PackedStringArray:
	var t: PackedStringArray = []
	t.append(BlockTags.SHOW)
	t.append(BlockTags.FILL)
	t.append(BlockTags.COLLISION)
	t.append(BlockTags.PROGRAM_PAGE_BORDER)
	t.append(BlockTags.AUTO_GENERATED)
	return t


# 覆盖积木的标签：可见 + 标记"程序页面覆盖 / 系统生成"（不参与碰撞）
#   ★ 带「始终不可选」：覆盖积木常铺满整个窗口、容易挡操作，即使调试模式也不可被选中
#     （需要调试它时，用调试面板「选择ID」旁的「调试」按钮强制打开其属性窗）。
#   ★★ 带 cutout（镂空遮罩）：把洞内的下层内容抹掉 = 「窗口盖住桌面文件」的正确语义；
#     同时也是**输入侧闸门**的依据（Block.is_point_covered 只认 cutout + 显示层更高的积木）——
#     没有它，被盖住的桌面图标虽然看不见却仍能被点中/拖动。
#     （磁盘上的 page_cover.json 一直带着 cutout；本处是 JSON 缺失时的内存回退模板，必须与之一致。）
static func cover_tags() -> PackedStringArray:
	var t: PackedStringArray = []
	t.append(BlockTags.SHOW)
	t.append(BlockTags.FILL)
	t.append(BlockTags.PROGRAM_PAGE_COVER)
	t.append(BlockTags.AUTO_GENERATED)
	t.append(BlockTags.ALWAYS_UNSELECTABLE)
	t.append(BlockTags.CUTOUT)
	return t


static func _frame_def() -> Dictionary:
	# 仅首次落盘模板；运行时以 JSON（page_frame.json）为准。display_layer 模板值 90.0 对应"低于覆盖层"的默认。
	return {
		"name": "page_frame",
		"display_layer": 90.0,
		"collision_layer": BlockLayers.program_page_border_layers(),
		"border_width": 1.0,
		"border_color": "#00000000",
		"fill_color": "#33E6FF00",
		"tags": frame_tags(),
		"fill_path": "",
		"fill_mode": 0,
		"fill_anim": 0,
		"rotation_deg": 0.0,
		"text_boxes": [],
		"parent_id": 0,
		"child_ids": [],
	}


static func _cover_def_default() -> Dictionary:
	var t := cover_tags()
	# 仅首次落盘模板；运行时以 JSON（page_cover.json）为准。display_layer 模板值 32.0 为「基数」，
	# 运行时再叠加窗口 z 序（见 _sync_cover）；想改整体层级直接改 JSON 的 display_layer。
	return {
		"name": COVER_TYPE,
		"display_layer": 32.0,
		"collision_layer": BlockLayers.program_page_cover_layers(),
		"border_width": 1.0,
		"border_color": "#00000000",
		"fill_color": "#9EA3BF00",
		"tags": t,
		"fill_path": "",
		"fill_mode": 0,
		"fill_anim": 0,
		"rotation_deg": 0.0,
		"text_boxes": [],
		"parent_id": 0,
		"child_ids": [],
	}


# 用一条边框的公共结构定义生成单个 Block；尺寸与中心由 _sync_geometry 写入
static func _new_block(host: Node, def: Dictionary) -> Block:
	var b := Block.new()
	BlockProperty.apply_to_block(b, def)
	host.add_child(b)
	return b


# 把窗口矩形套到某个角/边的积木上（中心 + 尺寸），碰撞/绘制都是它的 AABB
static func _set_bar(b: Block, cx: float, cy: float, w: float, h: float) -> void:
	b.width = w
	b.height = h
	b.global_position = Vector2(cx, cy)


# 差量同步一个窗口的 4 条边框（不存在则新建）。coords = {x,y,w,h}（窗口左上角 + 宽高）
static func _sync_frames(host: Node, wd: Dictionary, entry: Dictionary, coords: Dictionary) -> void:
	# 静态属性（颜色/标签/碰撞层/边框）改由 JSON 类型驱动：优先读 BlockTypes（用户编辑生效），
	# 文件缺失/未注册时回退到代码默认 _frame_def()，保证健壮性。
	var frame_def := BlockTypes.get_def(FRAME_TYPE)
	if frame_def.is_empty():
		frame_def = _frame_def()
	if not entry.has("frames"):
		entry["frames"] = [
			_new_block(host, frame_def),
			_new_block(host, frame_def),
			_new_block(host, frame_def),
			_new_block(host, frame_def),
		]
	var frames: Array = entry["frames"]
	var T := FRAME_THICKNESS
	var x: float = coords.x
	var y: float = coords.y
	var w: float = coords.w
	var h: float = coords.h
	var right := x + w
	var bottom := y + h
	# 上下横条宽 = 窗口宽；左右竖条高 = 窗口高 - 2*T（去四角重叠）
	_set_bar(frames[0], x + w * 0.5, y, w, T)                    # top
	_set_bar(frames[1], x + w * 0.5, bottom, w, T)               # bottom
	_set_bar(frames[2], x, y + h * 0.5, T, h - 2.0 * T)          # left
	_set_bar(frames[3], right, y + h * 0.5, T, h - 2.0 * T)      # right


# 差量同步一个窗口的覆盖积木（不存在则新建；layer 决定多窗口重叠时的遮挡顺序）
static func _sync_cover(host: Node, wd: Dictionary, entry: Dictionary, coords: Dictionary) -> void:
	# 所有静态属性（颜色/标签/碰撞层/边框/显示层基数）均由 JSON 类型驱动（用户改 page_cover.json 即生效）。
	# 显示层 = JSON 的 display_layer 基数 + 窗口 z 序（多窗口叠放顺序完全由 JSON 基数决定，脚本不再硬编码）。
	# ★★ 显示层**每次 sync 都重算并夹到 [COVER_LAYER_MIN, COVER_LAYER_MAX]**（不再只在首次创建时设一次）：
	#   · 每次重算 → 窗口 z 序变化后层级即时跟随（旧实现只在创建时算，之后 z 变了层级也不再更新）；
	#   · 夹紧上限 → 无论系统开了多少窗口，覆盖积木都不会爬到玩家积木(64)之上把新建积木镂掉。
	if not entry.has("cover"):
		entry["cover"] = _new_block(host, _cover_def_for(wd))
	var c: Block = entry["cover"]
	if c != null and is_instance_valid(c):
		c.display_layer = _cover_layer_for(wd)
	_set_bar(c, coords.x + coords.w * 0.5, coords.y + coords.h * 0.5, coords.w, coords.h)


# 覆盖积木的显示层：JSON 基数 + 窗口 z 序，再夹到 [COVER_LAYER_MIN, COVER_LAYER_MAX]。
static func _cover_layer_for(wd: Dictionary) -> float:
	var base := 32.0
	var d := BlockTypes.get_def(COVER_TYPE)
	if d.has("display_layer"):
		base = float(d.get("display_layer", 32.0))
	return clampf(base + float(wd.get("z", 0)), COVER_LAYER_MIN, COVER_LAYER_MAX)


# 覆盖积木的类型定义（含显示层已按当前窗口 z 算好）
static func _cover_def_for(wd: Dictionary) -> Dictionary:
	var d := BlockTypes.get_def(COVER_TYPE)
	if d.is_empty():
		d = _cover_def_default()
	d = d.duplicate()
	d["display_layer"] = _cover_layer_for(wd)
	return d


# 差量同步：把『当前枚举到的窗口列表』套到 state 上并同步积木。
#   host     —— 挂节点（通常为 desktop）
#   windows  —— [{hwnd, z, x, y, w, h, title, cls, pid}...]
#   state    —— Dictionary：窗口句柄 -> {frames:[..], cover:Block}
# 返回 (state, changed:bool)。changed 表示有积木新建/移除/几何发生变化（供穿透层刷新）。
static func sync(host: Node, windows: Variant, state: Dictionary) -> Dictionary:
	var out := state
	if windows == null or not (windows is Array):
		return { "state": out, "changed": false }

	var seen := {}
	var changed := false
	var n := 0
	for wd_raw in windows:
		if not (wd_raw is Dictionary):
			continue
		var wd: Dictionary = wd_raw
		var w := float(wd.get("w", 0.0))
		var h := float(wd.get("h", 0.0))
		if w <= 0.0 or h <= 0.0:
			continue
		var x := float(wd.get("x", 0.0))
		var y := float(wd.get("y", 0.0))
		var key := str(wd.get("hwnd", ""))
		if key.is_empty():
			key = "w%02d" % n
		n += 1
		var coords := { "x": x, "y": y, "w": w, "h": h }
		if not out.has(key):
			out[key] = {}
			changed = true
		var entry: Dictionary = out[key]
		_sync_frames(host, wd, entry, coords)
		_sync_cover(host, wd, entry, coords)
		seen[key] = true

	# 释放已不存在的窗口对应积木
	var stale := []
	for key in out.keys():
		if not seen.has(key):
			stale.append(key)
	for key in stale:
		_free_entry(out[key])
		out.erase(key)
		changed = true
	return { "state": out, "changed": changed }


static func _free_entry(entry: Dictionary) -> void:
	var frames: Array = entry.get("frames", [])
	for f in frames:
		if is_instance_valid(f) and f is Block:
			f.queue_free()
	var c: Variant = entry.get("cover", null)
	if is_instance_valid(c) and c is Block:
		c.queue_free()


# 释放全部程序页面积木（host 重排 / 退出时用）
static func destroy_all(state: Dictionary) -> void:
	for key in state.keys():
		_free_entry(state[key])
	state.clear()