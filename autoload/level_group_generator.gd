# autoload/level_group_generator.gd
# 随机生成「关卡组」：把关卡按「前关出口→后关入口」锚点重合的方式拼接成一条长关卡。
#
# 设计要点（2026-10-14）：
#   · 单关的「入口/出口」由带 level_entrance / level_exit 标签的积木中心判定；
#     单关应恰有 1 个入口 + 1 个出口（多岔路会导致关卡重叠 / 路线难汇合）。
#   · 关卡类型由关卡级 env 标签决定（entrance_level / exit_level / trap_level /
#     reward_level / normal_level / challenge_level），按类型分池。
#   · 组装顺序：1 个入口关卡 + N 个中间关卡（按 counts/total 由种子随机）+ 1 个出口关卡。
#   · 相邻两关用「上一关 exit 中心」与「下一关 entrance 中心」重合的方式平移对齐。
#   · ★ 仅生成不保存：返回合并后的内存 dict（同关卡 JSON 结构，name/blocks/env/brief），
#     由调用方（控制台 / 调试面板）交给 LevelPage.project_data 投影试看。
# 注意：本脚本刻意不写 class_name —— 其 autoload 名已为 LevelGroupGenerator，
# 再声明同名 class_name 会触发「Class "LevelGroupGenerator" hides an autoload singleton」。
extends Node

# 关卡类型 → 关卡级 env 标签
const ENV_TYPE_TAGS := {
	"entrance": BlockTags.LEVEL_ENV_ENTRANCE_LEVEL,
	"exit": BlockTags.LEVEL_ENV_EXIT_LEVEL,
	"trap": BlockTags.LEVEL_ENV_TRAP_LEVEL,
	"reward": BlockTags.LEVEL_ENV_REWARD_LEVEL,
	"normal": BlockTags.LEVEL_ENV_NORMAL_LEVEL,
	"challenge": BlockTags.LEVEL_ENV_CHALLENGE_LEVEL,
}

# 生成配置（由控制台 / 面板构造后传入）：
#   cfg = {
#     "group_name": String,
#     "seed": int,
#     "counts": {"trap":int, "reward":int, "normal":int, "challenge":int},
#     "total": int   # -1 = 用 counts 之和；更大则随机补足剩余槽位
#   }
# 返回合并后的关卡 dict（同 JSON 结构）；关卡池不足 / 组装失败返回 {}。
func generate(cfg: Dictionary) -> Dictionary:
	var seed_value: int = int(cfg.get("seed", 0))
	var group_name: String = str(cfg.get("group_name", "level_group"))
	var counts: Dictionary = cfg.get("counts", {})
	var total: int = int(cfg.get("total", -1))

	var pools := _collect_pools()
	var seq := _build_sequence(pools, counts, total, seed_value)
	if seq.is_empty():
		push_warning("[LevelGroupGenerator] 生成失败：关卡池不足（需要 entrance/exit 关卡及各类中间关卡）")
		return {}

	var merged := _assemble(seq, group_name, seed_value)
	if merged.is_empty():
		push_warning("[LevelGroupGenerator] 组装失败")
		return {}
	# 调试用：每关类型序列（project_data / instantiate_blocks 会忽略未知键）
	merged["_sequence_types"] = _sequence_types(seq)
	return merged


# 收集所有关卡，按 env 类型分池（一个关卡只归其 env 中第一个命中的类型）。
func _collect_pools() -> Dictionary:
	var pools := { "entrance": [], "exit": [], "trap": [], "reward": [], "normal": [], "challenge": [] }
	if LevelManager == null:
		push_warning("[LevelGroupGenerator] LevelManager 不可用，无法收集关卡池")
		return pools
	for name in LevelManager.list_level_names():
		var data := LevelManager.load_level(name)
		if data == null or data.is_empty():
			continue
		var env: Array = data.get("env", [])
		for key in ENV_TYPE_TAGS.keys():
			if ENV_TYPE_TAGS[key] in env:
				pools[key].append(data)
				break
	return pools


# 按种子构建关卡序列：入口 + 中间(各类型数量, total 可补足) + 出口。
func _build_sequence(pools: Dictionary, counts: Dictionary, total: int, seed_value: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var seq: Array = []
	var entrance_pool: Array = pools["entrance"]
	if entrance_pool.is_empty():
		push_warning("[LevelGroupGenerator] 没有「入口关卡」（env 含 entrance_level）")
		return []
	seq.append(_pick(entrance_pool, rng))

	var middle_counts := {}
	var sum := 0
	for k in ["trap", "reward", "normal", "challenge"]:
		var n: int = int(counts.get(k, 0))
		middle_counts[k] = n
		sum += n
	# 若指定了 total 且比显式数量之和更大，则在有池子的类型里随机补足剩余槽位。
	if total > sum:
		var extra := total - sum
		var types := ["trap", "reward", "normal", "challenge"]
		for i in extra:
			var avail := []
			for t in types:
				if not pools[t].is_empty():
					avail.append(t)
			if avail.is_empty():
				break
			var t: String = avail[rng.randi_range(0, avail.size() - 1)]
			middle_counts[t] += 1

	for k in ["trap", "reward", "normal", "challenge"]:
		var pool: Array = pools[k]
		var need: int = middle_counts[k]
		if need <= 0:
			continue
		if pool.is_empty():
			push_warning("[LevelGroupGenerator] 类型「%s」没有可用关卡，需求 %d 未满足" % [k, need])
			continue
		for i in need:
			seq.append(_pick(pool, rng))

	var exit_pool: Array = pools["exit"]
	if exit_pool.is_empty():
		push_warning("[LevelGroupGenerator] 没有「出口关卡」（env 含 exit_level）")
		return []
	seq.append(_pick(exit_pool, rng))
	return seq


func _pick(pool: Array, rng: RandomNumberGenerator) -> Dictionary:
	return pool[rng.randi_range(0, pool.size() - 1)]


# 用平移 offset 把相邻关卡的 exit→entrance 对齐，合并所有积木到一个 dict。
func _assemble(seq: Array, group_name: String, seed_value: int) -> Dictionary:
	var merged_blocks: Array = []
	var cur_offset := Vector2.ZERO
	var prev_exit_world := Vector2.ZERO
	var first := true
	for data in seq:
		var ent := _anchor_point(data, BlockTags.LEVEL_BLOCK_ENTRANCE)
		var ext := _anchor_point(data, BlockTags.LEVEL_BLOCK_EXIT)
		if first:
			# 让第一关入口落在世界原点（任意起点均可，这里从原点开始平铺）
			cur_offset = -ent
			first = false
		else:
			# 上一关 exit（世界）与本次 entrance（世界）重合：
			#   cur_offset + ent == prev_exit_world  →  cur_offset = prev_exit_world - ent
			cur_offset = prev_exit_world - ent
		prev_exit_world = cur_offset + ext
		var lname: String = str(data.get("name", ""))
		for d in data.get("blocks", []):
			if not (d is Dictionary):
				continue
			merged_blocks.append(_clone_block(d, cur_offset, lname))
	var merged := {
		"name": group_name,
		"brief": "随机生成的关卡组（种子=%d，关卡数=%d）" % [seed_value, seq.size()],
		"blocks": merged_blocks,
		"env": [],
	}
	return merged


# 取单关中带指定锚点标签的积木中心（关卡局部坐标）；找不到返回原点。
func _anchor_point(data: Dictionary, tag: String) -> Vector2:
	for d in data.get("blocks", []):
		if d is Dictionary and (tag in d.get("tags", [])):
			return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
	return Vector2.ZERO


# 深拷贝积木并应用平移 offset；有 string_id 则加关卡名前缀，避免跨关冲突。
func _clone_block(d: Dictionary, offset: Vector2, level_name: String) -> Dictionary:
	var nd: Dictionary = d.duplicate(true)
	nd["x"] = float(d.get("x", 0.0)) + offset.x
	nd["y"] = float(d.get("y", 0.0)) + offset.y
	if nd.has("string_id"):
		nd["string_id"] = level_name + "__" + str(nd["string_id"])
	return nd


# 由关卡序列还原每关的类型名（用于概要输出）。
func _sequence_types(seq: Array) -> Array[String]:
	var out: Array[String] = []
	for data in seq:
		var env: Array = data.get("env", [])
		var t := "?"
		for key in ENV_TYPE_TAGS.keys():
			if ENV_TYPE_TAGS[key] in env:
				t = key
				break
		out.append(t)
	return out
