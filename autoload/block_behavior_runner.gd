# autoload/block_behavior_runner.gd
# 积木行为运行时：每 TICK_INTERVAL 秒遍历带 behaviors 的积木，按优先级（前→后）
# 取首个「生效」的行为驱动移动；并维护队伍系统（队员跟随最近同队队长、模仿其行为，
# 队长全亡则随机队员晋升为队长并继承前队长行为）。
#
# 行为规格见 blocks/block_behaviors.gd；移动复用 Block.behavior_move_to（直线趋近 + 碰撞校验）。
extends Node

const TICK_INTERVAL := 0.4          # 决策节拍（秒）；到位前不重复决策，避免抖动

# 顺序巡逻：每个积木当前所在序号（instance_id -> int，下一次要去的槽位下标）
var _ordered_index: Dictionary = {}
# 坚守岗位：每个积木记录的首个岗位坐标（instance_id -> Vector2）
var _home_positions: Dictionary = {}
# 队伍：最近一次见到的队长 behaviors（队名 -> PackedStringArray），用于晋升继承
var _last_captain_behaviors: Dictionary = {}

# 本 tick 的方块快照（避免反复 group 查询）
var _tick_blocks: Array = []


func _ready() -> void:
	var timer := Timer.new()
	timer.name = "BehaviorTick"
	timer.wait_time = TICK_INTERVAL
	timer.one_shot = false
	timer.autostart = true
	timer.timeout.connect(_on_tick)
	add_child(timer)


func _on_tick() -> void:
	var tree := get_tree()
	if tree == null:
		return
	_tick_blocks = tree.get_nodes_in_group("block")
	_tick_teams(_tick_blocks)
	for b in _tick_blocks:
		if not (is_instance_valid(b) and b is Block):
			continue
		_tick_block(b)


# ==================== 队伍系统 ====================

func _tick_teams(blocks: Array) -> void:
	# ① 重建「各队队长行为」缓存（仅存活队长计入）
	var seen_teams := {}
	for b in blocks:
		if not (is_instance_valid(b) and b is Block):
			continue
		for tag in b.tags:
			var g := BlockBehaviors.captain_group(str(tag))
			if not g.is_empty():
				seen_teams[g] = true
				_last_captain_behaviors[g] = PackedStringArray(b.behaviors)
	# ② 队长全亡但仍有队员 → 随机队员晋升，继承前队长行为
	for team in _last_captain_behaviors.keys():
		if not seen_teams.has(team):
			var members := _team_members(team)
			if not members.is_empty():
				_promote_to_captain(members[randi() % members.size()], team)
			_last_captain_behaviors.erase(team)


func _promote_to_captain(member, team: String) -> void:
	var new_tags: PackedStringArray = []
	for t in member.tags:
		var s := str(t)
		if BlockBehaviors.member_group(s) == team:
			continue   # 去掉旧 队员_队名
		new_tags.append(s)
	new_tags.append(BlockBehaviors.CAPTAIN_PREFIX + team)
	member.tags = new_tags
	if _last_captain_behaviors.has(team):
		member.behaviors = PackedStringArray(_last_captain_behaviors[team])
	print("[BlockBehaviorRunner] 队伍 %s 队长全亡，队员 %d 晋升为队长并继承行为" % [team, int(member.id)])


func _team_captains(team: String) -> Array:
	var out: Array = []
	for b in _tick_blocks:
		if not (is_instance_valid(b) and b is Block):
			continue
		for tag in b.tags:
			if BlockBehaviors.captain_group(str(tag)) == team:
				out.append(b)
				break
	return out


func _team_members(team: String) -> Array:
	var out: Array = []
	for b in _tick_blocks:
		if not (is_instance_valid(b) and b is Block):
			continue
		for tag in b.tags:
			if BlockBehaviors.member_group(str(tag)) == team:
				out.append(b)
				break
	return out


# ==================== 单积木决策 ====================

func _tick_block(b) -> void:
	# 队员且存在同队活队长 → 跟随队长（模仿行为：移动到队长附近，实时跟随）
	var my_team := ""
	for tag in b.tags:
		var g := BlockBehaviors.member_group(str(tag))
		if not g.is_empty():
			my_team = g
			break
	if not my_team.is_empty():
		var caps := _team_captains(my_team)
		if not caps.is_empty():
			_follow(b, _nearest(b, caps))
			return
	# 否则按自身 behaviors 执行（支持组合节点 sel/if_tag/if_not_tag/repeat + 脚本互引用）
	var res := _resolve_all(b)
	if str(res["spec"]).is_empty():
		return
	# repeat 包裹的行为每 tick 重新驱动（即使正在移动中也持续重下单）；
	# 其余行为等到位（移动停止）再决策，避免抖动。
	if b.is_behavior_moving() and not res["repeat"]:
		return
	_apply_behavior(b, res["spec"])


# 解出本次要执行的「生效」行为叶规格（预设字符串）与是否循环驱动。
# 递归处理：组合节点（sel/if_tag/if_not_tag/repeat）+ 脚本引用（一层展开，深度保护防互引用死循环）。
# 返回 { "spec": String, "repeat": bool }；spec 为空表示本 tick 无生效行为。
func _resolve_all(b) -> Dictionary:
	for spec in b.behaviors:
		var r := _resolve_one(b, spec, 0)
		if not str(r["spec"]).is_empty():
			return r
	return { "spec": "", "repeat": false }


func _resolve_one(b, spec: String, depth: int) -> Dictionary:
	if depth > 16:
		return { "spec": "", "repeat": false }
	var s := str(spec).strip_edges()
	if s.is_empty():
		return { "spec": "", "repeat": false }
	var p := BlockBehaviors.parse(s)
	var kind: String = p.get("kind", "")
	if kind == "composite":
		match str(p["op"]):
			"sel":
				for child in p["args"]:
					var r := _resolve_one(b, str(child), depth + 1)
					if not str(r["spec"]).is_empty():
						return r
				return { "spec": "", "repeat": false }
			"if_tag":
				if p["args"].size() >= 2 and _block_has_tag(b, str(p["args"][0])):
					return _resolve_one(b, str(p["args"][1]), depth + 1)
				return { "spec": "", "repeat": false }
			"if_not_tag":
				if p["args"].size() >= 2 and not _block_has_tag(b, str(p["args"][0])):
					return _resolve_one(b, str(p["args"][1]), depth + 1)
				return { "spec": "", "repeat": false }
			"repeat":
				if p["args"].size() >= 1:
					var r := _resolve_one(b, str(p["args"][0]), depth + 1)
					r["repeat"] = true
					return r
				return { "spec": "", "repeat": false }
			_:
				return { "spec": "", "repeat": false }
	elif kind == "script":
		var sub := BehaviorFile.read_behaviors(str(p["name"]))
		for ss in sub:
			var r := _resolve_one(b, ss, depth + 1)
			if not str(r["spec"]).is_empty():
				return r
		return { "spec": "", "repeat": false }
	elif kind == "preset":
		return { "spec": s, "repeat": false }
	return { "spec": "", "repeat": false }


func _block_has_tag(b, tag: String) -> bool:
	for t in b.tags:
		if str(t) == tag:
			return true
	return false


func _apply_behavior(b, spec: String) -> bool:
	var p := BlockBehaviors.parse(spec)
	if p.get("kind", "") != "preset":
		return false
	var name := str(p["name"])
	var param := str(p["param"])
	match name:
		BlockBehaviors.HOLD_POSITION:
			return _do_hold(b)
		BlockBehaviors.RANDOM_PATROL:
			return _do_random_patrol(b, param)
		BlockBehaviors.ORDERED_PATROL:
			return _do_ordered_patrol(b, param)
		BlockBehaviors.AREA_PATROL:
			return _do_area_patrol(b, param)
	return false


# 队员跟随队长：每 tick 实时追踪队长位置（固定稳定偏移，避免完全重叠）。
# ★ 旧实现「正在移动就 return」→ 队长一动、队员要等到位才追，滞后一拍。
# 现改为：仅当目标明显偏移（队长移动）或本积木漂移时才重下单，
# 既实时跟随、又避免每个 tick 重置命令状态（保留碰撞卡死自恢复 / 速度）。
func _follow(b, cap) -> void:
	if cap == null:
		return
	var seed_f := float(b.get_instance_id())
	var off := Vector2(cos(seed_f) * 36.0, sin(seed_f) * 36.0)
	var want: Vector2 = cap.global_position + off
	if b.is_behavior_moving():
		if b.get_command_target().distance_to(want) < 4.0:
			return   # 已在朝该点移动，无需重置命令状态
	else:
		if b.global_position.distance_to(want) < 4.0:
			return   # 已停在跟随点，无需下单
	b.behavior_move_to(want)


# ==================== 预设行为实现 ====================

func _do_hold(b) -> bool:
	var iid: int = b.get_instance_id()
	if not _home_positions.has(iid):
		_home_positions[iid] = b.global_position
	var home: Vector2 = _home_positions[iid]
	if b.global_position.distance_to(home) > 8.0 and not b.is_behavior_moving():
		b.behavior_move_to(home)
	return true   # 坚守岗位总是「接管」该积木（优先级最高时即生效）


func _do_random_patrol(b, param: String) -> bool:
	if b.is_behavior_moving():
		return true   # 正在移动中（repeat 模式）：不重选目标，避免抖动
	var group := param
	if group.is_empty():
		group = _first_patrol_group(b)
	if group.is_empty():
		return false
	var cands := _patrol_targets(b, group)
	if cands.is_empty():
		return false
	var target = cands[randi() % cands.size()]
	b.behavior_move_to(target.global_position)
	return true


func _do_ordered_patrol(b, param: String) -> bool:
	if b.is_behavior_moving():
		return true   # 正在移动中（repeat 模式）：不重选目标，避免抖动
	var group := param
	if group.is_empty():
		group = _first_patrol_group(b)
	if group.is_empty():
		return false
	# 收集 巡逻_组_数字 的目标，按数字升序
	var slots := []
	for other in _tick_blocks:
		if not (is_instance_valid(other) and other is Block):
			continue
		for tag in other.tags:
			var info := BlockBehaviors.ordered_patrol_info(str(tag))
			if info["group"] == group and info["number"] >= 1:
				slots.append({ "n": info["number"], "block": other })
				break
	if slots.is_empty():
		return false
	slots.sort_custom(func(a, c): return a["n"] < c["n"])
	var iid: int = b.get_instance_id()
	var idx := 0
	if _ordered_index.has(iid):
		idx = int(_ordered_index[iid])
	if idx >= slots.size():
		idx = 0
	b.behavior_move_to(slots[idx]["block"].global_position)
	_ordered_index[iid] = (idx + 1) % slots.size()
	return true


func _do_area_patrol(b, param: String) -> bool:
	if b.is_behavior_moving():
		return true   # 正在移动中（repeat 模式）：不重选目标，避免抖动
	var group := param
	if group.is_empty():
		group = _first_area_group(b)
	if group.is_empty():
		return false
	var center: Vector2 = Vector2.ZERO
	var radius: float = -1.0
	for other in _tick_blocks:
		if not (is_instance_valid(other) and other is Block):
			continue
		for tag in other.tags:
			var reg := BlockBehaviors.area_region(str(tag))
			if reg["group"] == group and reg["radius"] > 0:
				center = other.global_position
				radius = reg["radius"]
				break
		if radius > 0:
			break
	if radius <= 0:
		return false
	var ang := randf() * TAU
	var r := sqrt(randf()) * radius
	b.behavior_move_to(center + Vector2(cos(ang), sin(ang)) * r)
	return true


# ==================== 工具 ====================

func _first_patrol_group(b) -> String:
	for tag in b.tags:
		var g := BlockBehaviors.patrol_group(str(tag))
		if not g.is_empty():
			return g
	return ""


func _first_area_group(b) -> String:
	for tag in b.tags:
		var reg := BlockBehaviors.area_region(str(tag))
		if reg["group"] != "" and reg["radius"] > 0:
			return reg["group"]
	return ""


func _patrol_targets(b, group: String) -> Array:
	var out: Array = []
	var want := BlockBehaviors.PATROL_PREFIX + group
	for other in _tick_blocks:
		if not (is_instance_valid(other) and other is Block):
			continue
		if other == b:
			continue
		for tag in other.tags:
			if str(tag) == want:
				out.append(other)
				break
	return out


func _nearest(b, arr: Array):
	var best = null
	var best_d := INF
	for c in arr:
		if not (is_instance_valid(c) and c is Block):
			continue
		var d: float = b.global_position.distance_to(c.global_position)
		if d < best_d:
			best_d = d
			best = c
	return best
