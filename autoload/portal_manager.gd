# autoload/portal_manager.gd
# 「传送门」标签系统单例（autoload 名：PortalManager）。
#
# 标签约定（前缀 + 连接符 + 组字符串，组字符串建议英文，如 portal_a）：
#   portal_entrance_<组>     —— 带此标签的积木成为「入口」；积木中心即入口位置。
#   portal_exit_<组>         —— 带此标签的积木成为「出口」；积木中心即落点位置。
#   teleportable_<组>        —— 带此标签的积木具备「可传送」身份。
#
# 规则：
#   1) 可传送积木的**中心点**一旦「进入」**同场景**、同组入口积木的范围，即传送：
#      落点 = 出口中心 + 「积木相对入口的偏移」，再沿最小穿透轴推出出口块外沿
#      （不这么做的话，同尺寸积木会整块陷在出口积木里被它盖住 = 看上去"消失了"）。
#      ★★ 判据 = 中心点落在入口积木的矩形内，**不再是 AABB 重叠**：重叠判定下积木只要
#        蹭到入口的一角就会被传走，玩家在画面上根本看不出"已经踩进门口了"；
#        改判中心点后，「走进门口里面」与「真的被传送」在视觉上同步
#        （与 block.gd 检测标签的"中心点入区"是同一条几何规则）。
#      ★★ **入口必须与可传送积木同场景**（都在桌面 / 都在同一个关卡页面）：
#        否则移动关卡页面时，关卡积木的全局坐标会随页面平移、扫过桌面上静止的入口块 →
#        AABB 一重叠就「被蹭着误传送」。跨场景由**出口**表达（入口在本场景、出口在别处），
#        搬运交给 _move_to_scene()；入口本身绝不跨场景触发。
#   2) 出口选择：先按「就近」——选距可传送积木最近的出口；
#      再按「同场景优先」——同场景（同一关卡面板 / 桌面）里有出口时，只在同场景内就近选；
#      仅当同场景内没有任何出口，才允许选其它场景的出口。传送门因此能跨场景（桌面上 → 关卡里，反之亦然）。
#   3) 防卡死：若某积木「自身同时是入口和出口」，作为入口被进入时，会从出口候选中**剔除自己**，
#      传送到除自己外最近的出口；可传送积木自身也不会把自己当出口。
#   4) 可传送积木每次传送后进入短暂冷却，避免站在入口上被连续重复传送。传送会把速度清零。
#
# 跨越场景：关卡积木与桌面积木用同一套屏幕坐标，AABB 直接用 global_position 判重，
#   所以「桌面上 → 关卡里」的传送只差一次坐标搬运。
# ★ 但坐标搬完还**必须搬归属**（换父节点）：桌面积木挂在桌面世界（绘制在关卡面板**之下**），
#   关卡积木挂在关卡舞台（被 _stage_view 裁剪）。只改坐标不换父节点时，积木虽然到了出口位置，
#   却会被面板盖住 / 被面板裁掉 → 表现为「传过去就消失、没从出口出现」。
#   换父见 _move_to_scene()：进关卡 → LevelPage.adopt_block()，出关卡 → LevelPage.release_block()。
# ★ 注意：故意不写 class_name（同 Debug / LevelManager 既有约定），否则裸名 PortalManager
#   会被解析成「类类型」，`PortalManager.xxx` 会报 Cannot find member。
extends Node

const ENTRANCE_PRE := "portal_entrance_"
const EXIT_PRE := "portal_exit_"
const TELEPORTABLE_PRE := "teleportable_"

const REFRESH_INTERVAL: float = 0.25   # 注册表重建间隔（秒）：积木增删 / 换标签在 ~0.25s 内生效
const TP_COOLDOWN: float = 0.4         # 单块传送后冷却（秒），防入口上重复传送

var _refresh_t: float = 0.0
# 组字符串 -> { "entrances": [Block], "exits": [Block], "teleportables": [Block] }
var _registry: Dictionary = {}
# 可传送积木 instance_id -> 冷却截止（秒，Time 基准）；传送口此处清零
var _last_tp: Dictionary = {}


func _physics_process(delta: float) -> void:
	_refresh_t -= delta
	if _refresh_t <= 0.0:
		_refresh_registry()
		_refresh_t = REFRESH_INTERVAL
	_try_teleports()


# 手动触发一次「重建注册表 + 尝试传送」（测试 / 调试用）
func force_check() -> void:
	_refresh_registry()
	_try_teleports()


# 重建注册表：扫描全局 group "block"，按标签归类。
func _refresh_registry() -> void:
	_registry.clear()
	var tree := get_tree()
	if tree == null:
		return
	for n in tree.get_nodes_in_group("block"):
		# ★ 先 is_instance_valid 再 `is Block`（同 _try_teleports）：组里可能残留已释放节点。
		if not is_instance_valid(n) or not (n is Block):
			continue
		var blk: Block = n
		for tag in blk.tags:
			var g: String = _group_string(tag)
			if g.is_empty():
				continue
			if tag.begins_with(ENTRANCE_PRE):
				_reg(g, "entrances", blk)
			elif tag.begins_with(EXIT_PRE):
				_reg(g, "exits", blk)
			elif tag.begins_with(TELEPORTABLE_PRE):
				_reg(g, "teleportables", blk)


func _reg(group: String, key: String, blk: Block) -> void:
	if not _registry.has(group):
		_registry[group] = { "entrances": [], "exits": [], "teleportables": [] }
	var arr: Array = _registry[group][key]
	if not arr.has(blk):
		arr.append(blk)


# 尝试执行传送：对每个可传送积木，找它重叠的同组入口，命中则送到出口。
# ★ 自测量（批次 6）：本函数每物理帧（60Hz）都跑，加 span 量一下真实单价。
func _try_teleports() -> void:
	if PerfMonitor.profiling:
		var t0 := Time.get_ticks_usec()
		_try_teleports_impl()
		PerfMonitor.add_span("portal_tp", Time.get_ticks_usec() - t0)
		return
	_try_teleports_impl()


func _try_teleports_impl() -> void:
	if _registry.is_empty():
		return
	var now: float = Time.get_ticks_msec() * 0.001
	for group in _registry:
		var grp: Dictionary = _registry[group]
		var entrances: Array = grp["entrances"]
		var exits: Array = grp["exits"]
		if entrances.is_empty() or exits.is_empty():
			continue
		for tp in grp["teleportables"]:
			# ★ 必须**先** is_instance_valid 再判 `is Block`：注册表每 0.25s 才重建一次，
			#   期间被释放的积木（漏档 / 关卡清场 / 传送搬运）仍留在数组里 ——
			#   对一个已释放实例执行 `tp is Block` 会抛
			#   「Left operand of 'is' is a previously freed instance.」硬脚本错误。
			if not is_instance_valid(tp) or not (tp is Block):
				continue
			var tid: int = tp.get_instance_id()
			if _last_tp.has(tid) and now < _last_tp[tid]:
				continue
			var tp_scene: Node = _scene_of(tp)
			for en in entrances:
				if not is_instance_valid(en) or not (en is Block):
					continue
				# ★★ **入口必须与可传送积木同场景**（都在桌面，或都在**同一个**关卡页面），否则不触发。
				#   否则：移动关卡页面时，关卡积木的全局坐标会随页面平移，一旦扫过桌面上一块静止的
				#   `portal_entrance_*`，`_center_in`（纯全局坐标判点）就为真 → 被「蹭」一下就误传送。
				#   ★ 跨场景传送的正确表达是「入口在本场景、**出口**在别的场景」——由 _do_teleport 的
				#   `_move_to_scene()` 负责把积木搬过去；入口本身不允许跨场景触发。
				if _scene_of(en) != tp_scene:
					continue
				# ★ 判据：可传送积木的**中心点**落在入口积木内（见文件头规则 1）。
				if not _center_in(tp, en):
					continue
				if _do_teleport(tp, en, exits):
					_last_tp[tid] = now + TP_COOLDOWN
				break


# 把可传送积木送到合适的出口。返回是否真的传送了。
# 出口池：同组出口，剔除触发入口（防「自身既入口又出口」卡住）与自身。
# ★ 调用前提：`_scene_of(entrance) == _scene_of(tp)`（见 _try_teleports 的同场景闸门）。
func _do_teleport(tp: Block, entrance: Block, exits: Array) -> bool:
	var en_scene: Node = _scene_of(entrance)
	var tp_scene: Node = _scene_of(tp)
	# 兜底复检（防将来有人绕过 _try_teleports 直接调本函数）：入口跨场景一律不传。
	if en_scene != tp_scene:
		return false
	var pool: Array[Block] = []
	for x in exits:
		# ★ 先 is_instance_valid 再 `is Block`（见 _try_teleports 同名说明）：多个出口时
		#   出口池里可能残留已释放实例 → 直接 `x is Block` 会抛「previously freed instance」。
		if not is_instance_valid(x) or not (x is Block):
			continue
		if x == entrance or x == tp:
			continue
		pool.append(x)
	if pool.is_empty():
		return false
	# 同场景优先：入口所在场景里若有出口，只在这种出口里就近选
	var same: Array[Block] = []
	for x in pool:
		if _scene_of(x) == en_scene:
			same.append(x)
	var candidates: Array[Block] = same if not same.is_empty() else pool
	# 就近选
	var best: Block = candidates[0]
	var best_d: float = tp.global_position.distance_squared_to(best.global_position)
	for x in candidates:
		var d: float = tp.global_position.distance_squared_to(x.global_position)
		if d < best_d:
			best = x
			best_d = d
	# ---- 落点 ----
	# ① 保留「积木相对入口的偏移」：从入口左上角进去 → 就从出口左上角出来（传送门手感）；
	# ② 再沿最小穿透轴推出出口块外沿：**必须做**。若直接落到出口中心，同尺寸积木会整块
	#    陷在出口积木里、被出口完全盖住 —— 看上去就是「传过去就消失了」。
	var landing: Vector2 = best.global_position + (tp.global_position - entrance.global_position)
	landing = _push_out_of(landing, tp, best)
	# ---- 归属：搬到「出口所在场景」----
	# 桌面积木 → 关卡：收进关卡舞台；关卡积木 → 桌面：退回桌面世界。
	# ★ 坐标对了也必须搬：绘制层不对照样看不见 —— 桌面世界画在关卡面板**之下**（进关卡后被面板盖住），
	#   关卡积木则被 _stage_view 裁剪（出关卡后被裁掉）。两种都表现为「积木消失、没从出口出现」。
	_move_to_scene(tp, tp_scene, _scene_of(best))
	tp.global_position = landing
	tp._gravity_velocity = Vector2.ZERO
	tp._move_velocity = Vector2.ZERO
	# 正被鼠标拖着时先结束拖动：否则下一帧拖动逻辑会把积木拉回鼠标处（等于传送被撤销）。
	if tp._is_dragging:
		tp._stop_drag()
	print("[Portal] 积木 %s 传送：入口(%s) → 出口(%s) 落点=%s 目标场景=%s" % [
		str(tp.id), str(entrance.global_position), str(best.global_position),
		str(landing), ("关卡" if _scene_of(best) != null else "桌面")])
	return true


# 落点若与出口块重叠 → 沿「最小穿透轴」推到刚好贴住出口外沿（再留 1px 缝）。
# 目的：不让积木落在出口积木**内部**被它盖住（同尺寸时 = 完全看不见）。
func _push_out_of(pos: Vector2, tp: Block, other: Block) -> Vector2:
	if other == null or not is_instance_valid(other):
		return pos
	var half_sum := Vector2((tp.width + other.width) * 0.5, (tp.height + other.height) * 0.5)
	var d: Vector2 = pos - other.global_position
	var ox: float = half_sum.x - absf(d.x)
	var oy: float = half_sum.y - absf(d.y)
	if ox <= 0.0 or oy <= 0.0:
		return pos   # 两轴都不重叠 → 落点没被出口盖住，原样使用
	if ox <= oy:
		pos.x += (ox + 1.0) * (1.0 if d.x >= 0.0 else -1.0)
	else:
		pos.y += (oy + 1.0) * (1.0 if d.y >= 0.0 else -1.0)
	return pos


# 把积木搬到「出口所在场景」：
#   dest 是关卡面板 → 收进该关卡（LevelPage.adopt_block）；dest 是桌面 → 从关卡退回桌面世界。
# 同场景（都在桌面 / 都在同一关卡）什么都不做。
func _move_to_scene(tp: Block, src_scene: Node, dest_scene: Node) -> void:
	if tp == null or not is_instance_valid(tp):
		return
	if src_scene == dest_scene:
		return
	# 积木挂在别的积木下面（Node 父子兼容写法）→ 不搬，避免拆散整棵子树
	var p := tp.get_parent()
	if p != null and is_instance_valid(p) and p is Block:
		return
	# ★ 正在排队删除的积木不搬：把它 add_child 到别的父节点会「复活」一个本节末就要被释放的节点，
	#   之后它仍会被 free → 桌面世界里留下一个悬空 / 半死节点（表现为卡死或下一帧 hard error）。
	#   关卡清场（project_level / _clear_level_blocks 的 queue_free）与传送同帧发生时会命中这里。
	if tp.is_queued_for_deletion():
		return
	if dest_scene != null:
		# 目标关卡面板没显示时不收：收进去会整块看不见（面板 hidden）；
		# 留在桌面世界照样能按出口坐标看到它。
		if dest_scene.has_method("is_page_visible") and not dest_scene.is_page_visible():
			return
		# 跨关卡（A 关 → B 关）：先让源关卡忘掉它，否则 A 关保存/清场还会算上它
		if src_scene != null and src_scene.has_method("forget_block"):
			src_scene.forget_block(tp)
		if dest_scene.has_method("adopt_block"):
			dest_scene.adopt_block(tp)
	elif src_scene != null and src_scene.has_method("release_block"):
		src_scene.release_block(tp)


# 可传送积木 tp 的**中心点**是否落在入口积木 en 的范围内（判定要不要传送）。
# ★ 必须用 en 自己的 _aabb_at（尺寸取自 en）：写成 tp._aabb_at(en.global_position) 会得到
#   一个"以入口位置为中心、却用可传送积木尺寸"的矩形 → 两块尺寸不同时判据就错了（已踩过）。
# ★ 贴边视为「未进入」（Rect2.has_point 的右/下边界是开区间）—— 与旧 AABB 判定
#   `intersects(..., true)` 的"贴边不算重叠"保持同一取向。
func _center_in(tp: Block, en: Block) -> bool:
	return en._aabb_at(en.global_position).has_point(tp.global_position)


# 积木所属「场景」：沿祖先找到最近的关卡面板（LevelPage）即属于该场景；否则为桌面（返回 null）。
func _scene_of(block: Node) -> Node:
	var n: Node = block
	while n != null:
		# ★ 必须先 is_instance_valid 再 `is LevelPage`：传送途中祖先链上可能有
		#   已被释放的节点（关卡面板被重建 / 桌面拆场景 / 积木被清场），
		#   对已释放实例执行 `is` 会抛「Left operand of 'is' is a previously freed instance.」硬脚本错误。
		if not is_instance_valid(n):
			return null
		if n is LevelPage:
			return n
		n = n.get_parent()
	return null


# 从标签里取组字符串：前缀命中返回去掉前缀的剩余部分，否则空串。
func _group_string(tag: String) -> String:
	if tag.begins_with(ENTRANCE_PRE):
		return tag.substr(ENTRANCE_PRE.length())
	if tag.begins_with(EXIT_PRE):
		return tag.substr(EXIT_PRE.length())
	if tag.begins_with(TELEPORTABLE_PRE):
		return tag.substr(TELEPORTABLE_PRE.length())
	return ""


# 调试辅助：列出当前注册的传送门结构
func dump() -> void:
	for g in _registry:
		var grp: Dictionary = _registry[g]
		print("[Portal] 组=%s 入口=%d 出口=%d 可传送=%d" % [
			g, grp["entrances"].size(), grp["exits"].size(), grp["teleportables"].size()])