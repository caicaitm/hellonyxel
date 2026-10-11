# desktop_barrier.gd
# 「桌面屏障」—— 屏幕外的那圈 1px 边界阻挡积木，**防止积木掉出屏幕外**。
#
# 需求（本次）：
#   启动游戏时，在屏幕外 1 个像素处分别创建：
#     · 屏幕宽 × 1 像素高  → 类型名 BedRockX（贴住屏幕的**上边**与**下边**）
#     · 1 像素宽 × 屏幕高  → 类型名 BedRockY（贴住屏幕的**左边**与**右边**）
#   标签加「桌面屏障」（BlockTags.DESKTOP_BARRIER = "desktop_barrier"）；
#   碰撞图层包含 编号层 1~30 + 默认(default) + 被拖动中(dragging) + 检测区(detect_zone)
#   （BlockLayers.barrier_layers()；检测区积木刻意不带 default，故必须显式列入，
#   否则带重力的检测区积木会穿出屏幕）。
#
# 几何（场景坐标，见 DesktopShell）：场景坐标 == 屏幕像素，桌面矩形原点在 (0,0)。
#   设矩形为 Rect2(0, 0, W, H)、厚度 T = 1：
#     top    上边：中心 (W/2,     -T/2)     占 y ∈ [-T, 0]
#     bottom 下边：中心 (W/2,  H + T/2)     占 y ∈ [H, H+T]
#     left   左边：中心 (-T/2,     H/2)     占 x ∈ [-T, 0]
#     right  右边：中心 (W + T/2,  H/2)     占 x ∈ [W, W+T]
#   即「屏障的内沿恰好贴着桌面边缘，整体落在屏幕之外 1 像素」。
#
# ★ 为什么这样就能挡住：碰撞判定是**绝对判据**（目的地若与屏障重叠即拒绝，见 Block._can_move_to），
#   积木的每一步位移都被夹在 [0, W] × [0, H] 之内，不可能越界。
#   子步最大约 7px（MOVE_SUBSTEPS=4、屏幕内自由落体 ~1.8s 时 vy≈1.8k px/s），
#   远小于任何正常积木的高度，所以 1px 厚也不会被"穿"过去。
#
# ★ 不绘制：标签里**没有** show（也没有 border / fill）→ Block._draw() 直接返回，
#   它是"看不见的墙"。同时它位于屏幕外，MousePassRunner 会把带 desktop_barrier 标签的
#   积木排除在桌面穿透区域之外（否则会在屏幕边缘多出一圈"不可穿透"的窄条）。
#
# ★ 类型注册：BedRockX / BedRockY 会写进 BlockTypes（"我的积木类型"里可见），
#   属于**系统保留类型** —— 每次启动都会按当前屏幕尺寸重写它们的定义（见 DesktopBarrier.register_types）。
class_name DesktopBarrier
extends RefCounted

# ---- 类型名（需求指定）----
const TYPE_X := "BedRockX"   # 横向屏障：屏幕宽 × 1px
const TYPE_Y := "BedRockY"   # 纵向屏障：1px × 屏幕高

# 屏障厚度（像素）—— 需求指定 1
const THICKNESS := 1.0

# ---- 四条边的角色 ----
const ROLE_TOP := "top"
const ROLE_BOTTOM := "bottom"
const ROLE_LEFT := "left"
const ROLE_RIGHT := "right"
const ROLES := [ROLE_TOP, ROLE_BOTTOM, ROLE_LEFT, ROLE_RIGHT]

# ---- 固定字符串 ID（需求指定；进入游戏创建时即分配）----
const SID_TOP := "BedRockXU"        # 上边（类型 X）
const SID_BOTTOM := "BedRockXD"     # 下边（类型 X）
const SID_LEFT := "BedRockYL"       # 左边（类型 Y）
const SID_RIGHT := "BedRockYR"      # 右边（类型 Y）
const SID_TASKBAR := "BedRockXC"    # 任务栏上表面屏障

# 屏障用的碰撞图层：编号层 1~30 + 默认 + 被拖动中 + 检测区
# ★ 注意：实际生成时优先用 res://block_types/BedRockX.json / BedRockY.json 里的
#   collision_layer（见 spawn_all，JSON 可被用户编辑）；本函数是"无 JSON 时"的回退，
#   改这里的同时必须同步那两个 JSON，否则改动不会生效（已踩过）。
static func layers() -> PackedStringArray:
	return BlockLayers.barrier_layers()


# 屏障共用的标签：只碰撞 + 标记「桌面屏障」，**不含 show** → 不绘制
static func tags() -> PackedStringArray:
	var t: PackedStringArray = []
	t.append(BlockTags.COLLISION)
	t.append(BlockTags.DESKTOP_BARRIER)
	return t


# ---- 类型定义（供 BlockTypes.register 使用）----

# BedRockX 的定义：宽 = 桌面宽，高 = 1px
static func make_def_x(width: float) -> Dictionary:
	var d := _base_def(TYPE_X)
	d["width"] = maxf(width, THICKNESS)
	d["height"] = THICKNESS
	return d


# BedRockY 的定义：宽 = 1px，高 = 桌面高
static func make_def_y(height: float) -> Dictionary:
	var d := _base_def(TYPE_Y)
	d["width"] = THICKNESS
	d["height"] = maxf(height, THICKNESS)
	return d


static func _base_def(type_name: String) -> Dictionary:
	return {
		"name": type_name,
		"display_layer": -100,          # 不绘制；给个很低的值，语义上"垫在所有东西之下"
		"collision_layer": layers(),
		"border_width": 1.0,
		"border_color": "#00000000",
		"fill_color": "#00000000",
		"tags": tags(),
		"fill_path": "",
		"fill_mode": 0,
		"fill_anim": 0,
		"rotation_deg": 0.0,
		"text_boxes": [],
		"parent_id": 0,
		"child_ids": [],
	}


# ---- 生成 / 重排 ----

# 生成 4 块屏障（上/下 → BedRockX，左/右 → BedRockY），加入 host，并摆好位置。
# 每块同时分配固定字符串 ID（BedRockXU/XD/YL/YR）。
# 返回 { role -> Block }。调用方负责先注册类型（见 desktop._register_barrier_types）。
# ★ 静态属性（颜色/标签/碰撞层等）来自 BlockTypes 注册的类型定义（即 JSON，可被编辑）；
#   几何尺寸始终以当前桌面矩形为准（_place 覆盖），保证屏障永远贴住屏幕边缘。
static func spawn_all(host: Node, rect: Rect2) -> Dictionary:
	var out: Dictionary = {}
	if host == null:
		return out
	for role in ROLES:
		var tname := type_name_of(role)
		var def: Dictionary
		if BlockTypes.has(tname):
			def = BlockTypes.get_def(tname).duplicate(true)   # 以 JSON 定义为准（可被用户改）
		else:
			def = make_def_x(rect.size.x) if is_x(role) else make_def_y(rect.size.y)
		var b := Block.new()
		BlockProperty.apply_to_block(b, def)   # 与"按类型生成"完全同一条路径
		host.add_child(b)                      # 入树后才有 ID / 文本框视图
		_place(b, role, rect)                  # 几何尺寸始终以当前桌面矩形为准
		if not BlockManager.set_string_id(b, sid_of(role)):
			push_warning("[DesktopBarrier] 字符串 ID '%s' 分配失败（role=%s）" % [sid_of(role), role])
		out[role] = b
	return out


# 该角色的固定字符串 ID（上/下 X，左/右 Y）
static func sid_of(role: String) -> String:
	match role:
		ROLE_TOP:
			return SID_TOP
		ROLE_BOTTOM:
			return SID_BOTTOM
		ROLE_LEFT:
			return SID_LEFT
		ROLE_RIGHT:
			return SID_RIGHT
	return ""


# 按新的桌面矩形重排已生成的屏障（"场景大小可动" → 尺寸变了跟着变）
static func apply_rect(blocks: Dictionary, rect: Rect2) -> void:
	for role in ROLES:
		var b: Variant = blocks.get(role, null)
		if is_instance_valid(b) and b is Block:
			_place(b, role, rect)


# 释放全部屏障（仅供重排/测试）。先注销（数字 + 字符串 ID），再释放。
static func destroy(blocks: Dictionary) -> void:
	for role in ROLES:
		var b: Variant = blocks.get(role, null)
		if is_instance_valid(b) and b is Block:
			BlockManager.unregister(b)
			b.queue_free()
	blocks.clear()


# 该角色用横向类型（BedRockX）吗？上/下用 X，左/右用 Y
static func is_x(role: String) -> bool:
	return role == ROLE_TOP or role == ROLE_BOTTOM


# 该角色的类型名
static func type_name_of(role: String) -> String:
	return TYPE_X if is_x(role) else TYPE_Y


# 摆放单块屏障：尺寸 + 中心（内沿贴桌面边缘，整体在桌面外 1px）
# 用 global_position（碰撞判定全程用 global_position，见 Block._aabb_at / _can_move_to）
static func _place(b: Block, role: String, rect: Rect2) -> void:
	if b == null:
		return
	var w := maxf(rect.size.x, THICKNESS)
	var h := maxf(rect.size.y, THICKNESS)
	var t := THICKNESS
	var ox := rect.position.x
	var oy := rect.position.y
	match role:
		ROLE_TOP:
			b.width = w
			b.height = t
			b.global_position = Vector2(ox + w * 0.5, oy - t * 0.5)
		ROLE_BOTTOM:
			b.width = w
			b.height = t
			b.global_position = Vector2(ox + w * 0.5, oy + h + t * 0.5)
		ROLE_LEFT:
			b.width = t
			b.height = h
			b.global_position = Vector2(ox - t * 0.5, oy + h * 0.5)
		ROLE_RIGHT:
			b.width = t
			b.height = h
			b.global_position = Vector2(ox + w + t * 0.5, oy + h * 0.5)
	if b.has_method("queue_redraw"):
		b.queue_redraw()


# ---- 任务栏屏障 ----
# 在任务栏上表面（top/bottom）或侧边内沿（left/right）生成一条 1px 阻挡积木，
# 防止积木落入任务栏。taskbar = sysinfo 里的 {"edge": "bottom", "height_px": 72}。
# 与屏幕四边屏障同款：不可见、只碰撞、不计入穿透（标签用 DESKTOP_TASKBAR）。

# 生成一条任务栏屏障，加入 host 并摆好位置；taskbar 无效（无 height_px）则返回 null。
static func spawn_taskbar(host: Node, rect: Rect2, taskbar: Dictionary) -> Block:
	if host == null:
		return null
	var edge := str(taskbar.get("edge", ROLE_BOTTOM))
	var th := float(taskbar.get("height_px", 0.0))
	if th <= 0.0:
		push_warning("[DesktopBarrier] 无有效的任务栏高度，跳过任务栏屏障: %s" % str(taskbar))
		return null
	var horizontal := edge == ROLE_BOTTOM or edge == "top"
	# 静态属性（display_layer / 颜色等）优先读 JSON 类型定义（BedRockX/Y.json，用户可编辑生效）；
	# 文件缺失时回退到代码默认 _base_def()。尺寸/位置仍由 _place_taskbar 按任务栏几何计算。
	var tname := TYPE_X if horizontal else TYPE_Y
	var def: Dictionary = BlockTypes.get_def(tname)
	if def.is_empty():
		def = _base_def(tname)
	var t := def.duplicate(true)
	t["name"] = tname
	t["tags"] = _taskbar_tags()
	var b := Block.new()
	BlockProperty.apply_to_block(b, t)   # 与"按类型生成"完全同一条路径
	host.add_child(b)
	if not BlockManager.set_string_id(b, SID_TASKBAR):
		push_warning("[DesktopBarrier] 任务栏屏障字符串 ID '%s' 分配失败" % SID_TASKBAR)
	_place_taskbar(b, rect, edge, th)
	return b


static func _taskbar_tags() -> PackedStringArray:
	var t: PackedStringArray = []
	t.append(BlockTags.COLLISION)
	t.append(BlockTags.DESKTOP_TASKBAR)
	return t


# 按任务栏信息重排已生成的任务栏屏障（"场景大小可动" → 尺寸变了跟着变）
static func apply_taskbar(b: Variant, rect: Rect2, taskbar: Dictionary) -> void:
	# ★ 先 is_instance_valid 再 `is Block`：对已释放实例执行 `is` 会抛
	#   「Left operand of 'is' is a previously freed instance.」（见 portal_manager）。
	if not is_instance_valid(b) or not (b is Block):
		return
	var edge := str(taskbar.get("edge", ROLE_BOTTOM))
	var th := float(taskbar.get("height_px", 0.0))
	if th <= 0.0:
		return
	_place_taskbar(b, rect, edge, th)


# 摆放任务栏屏障：1px 厚，贴着任务栏内侧。
static func _place_taskbar(b: Block, rect: Rect2, edge: String, th: float) -> void:
	var w := maxf(rect.size.x, THICKNESS)
	var h := maxf(rect.size.y, THICKNESS)
	var ox := rect.position.x
	var oy := rect.position.y
	match edge:
		ROLE_BOTTOM:
			b.width = w
			b.height = THICKNESS
			b.global_position = Vector2(ox + w * 0.5, oy + h - th - THICKNESS * 0.5)
		"top":
			b.width = w
			b.height = THICKNESS
			b.global_position = Vector2(ox + w * 0.5, oy + th + THICKNESS * 0.5)
		ROLE_LEFT:
			b.width = THICKNESS
			b.height = h
			b.global_position = Vector2(ox + th - THICKNESS * 0.5, oy + h * 0.5)
		ROLE_RIGHT:
			b.width = THICKNESS
			b.height = h
			b.global_position = Vector2(ox + w - th + THICKNESS * 0.5, oy + h * 0.5)
	if b.has_method("queue_redraw"):
		b.queue_redraw()


# 调试用：一块屏障的摘要
static func describe(b: Block) -> String:
	if b == null or not is_instance_valid(b):
		return "null"
	return "sid=%s id=%d pos=%s size=%sx%s layers=%d tags=%s" % [
		b.string_id, b.id, str(b.position), str(b.width), str(b.height),
		b.collision_layer.size(), str(b.tags)]
