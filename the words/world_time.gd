# the words/world_time.gd
# 「世界」时间系统（第十六轮）：把星体的**公转 / 自转**挂到现实时间上，并落盘更新状态。
#
# ★ 三条口径（用户拍板）：
#   ① **公转不做连续动画**：只在 tick 到时**一次性跳**到新位置与朝向，tick 之间冻结（场景基本静态）。
#      · 日心天体（行星 / 矮行星 / 小行星 / 小行星带内成员）= **每月 1 号**（本地日期）更新一次；
#      · 卫星 = **每月 2 / 12 / 22 号**（本地日期）更新一次。
#   ② **自转 = 每小时**更新一次（截到整点）。所有带 `rotation_period_h` 的节点都自转；
#      地球另走「让现实里太阳直射的那条经线**正对太阳**」的对齐路径（`spin_align_sun`）。
#   ③ 更新状态记在 `Temp/world_state.json`（随存档备份）⇒ 玩家上线时「该更新了就**补更新**」，防穿帮。
#
# ★ 角度**每次从 epoch 重算、不做累加**：玩家离线 3 个月 = 跳过 3 次行星 tick；
#   逐次累加会因舍入漂移，重算则**一次跳到最新 tick 的真实位置**（这正是「防穿帮」的本意）。
#
# ★ ★ 逆行的两种表达（务必分清，别双重取反）★ ★
#   · **轨道逆行**（土卫九 175.2°、海卫一 156.9°）—— 由节点已有的 `orbit_incline_deg > 90°` 表达：
#     倾角 > 90° 的轨道，其相位角**增大**时在世界上就是**逆向**走的，`orbit_period_h` 无需取负；
#   · **自转逆行**（金星 / 天王星 / 冥王星）—— 由 `rotation_period_h` **取负**表达（相位角减小）。
#   （`orbit_period_h` 取负的语义 = 相位角减小，留给「倾角 ≤ 90° 但确实逆行」的场合。）
class_name WorldTime
extends RefCounted

## epoch 兜底：JSON 根没写 / 写坏时用它。★ 各节点的 `orbit_angle_deg` / `rotation_phase_deg`
## 都是**这一刻**的初始相位（延续「JSON 只记初始状态」的约定，现在补一句「初始状态指 epoch 时刻」）。
const EPOCH_FALLBACK := "2026-01-01T00:00:00Z"
const EPOCH_FALLBACK_UNIX := 1767225600   # 上面那串对应的 unix 秒

## 地球贴图朝向的**标定常数**（°）：把「Godot SphereMesh 的 u=0 接缝落在哪条经线」与
## 「等距圆柱贴图 u=0 ↔ 经度 −180°」两条约定折成一个常数。按几何解析推导应为 0；
## 用带窗口截图复核（地球正午那条经线该正对太阳），不对再微调这里。
const EARTH_UV_OFFSET := 0.0

const PLANET_TICK_DAY := 1                 # 日心天体：每月 1 号更新
const MOON_TICK_DAYS := [2, 12, 22]        # 卫星：每月 2 / 12 / 22 号更新

## 状态文件（SaveManager 已登记为「无 owner 的通用状态」，随存档备份 / 恢复）。
const STATE_FILE := "world_state.json"
const STATE_KEY := "celestial"             # 状态文件里的顶层键（不与 StateRegistry 的标签字段冲突）


# ---------------- 角度 / 经度 ----------------

## 归一化到 [0, 360)。
static func wrap360(a: float) -> float:
	return fposmod(a, 360.0)


## 经度归一到 (−180, 180]。
static func normalize_lon(deg: float) -> float:
	var v := fposmod(deg, 360.0)
	return v - 360.0 if v > 180.0 else v


## 相位角：**从 epoch 重算**（不累加）。`period_h` 带符号（负 = 相位角减小 = 逆行）；0 = 不动。
static func angle_deg(initial: float, period_h: float, epoch_unix: int, now_unix: int) -> float:
	if absf(period_h) < 1e-6:
		return wrap360(initial)
	return wrap360(initial + 360.0 * float(now_unix - epoch_unix) / (period_h * 3600.0))


## 现实时刻的**太阳直射经度**（°）：`λ = 15° × (12 − UTC 小时)`，归一到 (−180, 180]。
## 物理上只由 UTC 决定（UTC 12:00 ⇒ 0° = 格林尼治正午），与本地时区无关。
static func sun_longitude_deg(utc_hour: float) -> float:
	return normalize_lon(15.0 * (12.0 - utc_hour))


## 让「太阳直射的那条经线」正对太阳时，地球 Body 需要绕赤道轴转的角度（°）。
## 几何推导（等距圆柱贴图，经度 λ 的表面点在 Body 局部坐标）：
##   贴图经度 λ ⇒ 局部方向 d₀(λ) = **(−sin λ, 0, −cos λ)** —— 记 u(a) = (sin a, 0, −cos a)，
##   则 d₀(λ) = u(−λ)。★ 这个**负号**是第十九轮实测网格顶点/UV0 定下来的（见 world_node.latlon_dir
##   的注释：原本按正 sin 写，结果整批城市在经度上整体镜像）；
##   绕 Y 转 θ 后 ⇒ d(λ) = u(−λ−θ)；
##   要求 d(λ_sun) = ŝ = u(β)（ŝ = 从地球指向太阳的单位向量，水平；β = atan2(ŝ.x, −ŝ.z) 是它的世界方位角）
##   ⇒ **−λ_sun − θ = β ⇒ θ = −(λ_sun + β)**。
## ★ 为什么不能沿用早先的 θ = λ_sun − β：那个式子是在「d₀(λ) = (sin λ, 0, −cos λ)」这条**镜像**约定下推的；
##   约定一翻，θ 的符号也跟着翻（否则白天会落在**镜像**的那条经线上：UTC 0/12 点看不出来，6/18 点差 180°）。
## ★ β 随地球**轨道位置**变（每月 tick 变一次），不能写成编译期常数。
static func earth_spin_deg(sun_dir: Vector3, lam_sun: float) -> float:
	var beta := rad_to_deg(atan2(sun_dir.x, -sun_dir.z))
	return wrap360(EARTH_UV_OFFSET - lam_sun - beta)


# ---------------- tick 日期（本地日期口径）----------------

static func is_leap_year(y: int) -> bool:
	return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0


static func days_in_month(y: int, m: int) -> int:
	match m:
		1, 3, 5, 7, 8, 10, 12:
			return 31
		4, 6, 9, 11:
			return 30
		2:
			return 29 if is_leap_year(y) else 28
	return 30


## 日心天体的 tick = ≤ now 的最近一个「1 号」（本地日期）。
static func planet_tick_key(local_date: Dictionary) -> String:
	return "%04d-%02d-01" % [int(local_date.get("year", 1970)), int(local_date.get("month", 1))]


## 卫星的 tick = ≤ now 的最近一个 {2, 12, 22} 号（本地日期；今天 < 2 号 ⇒ 上个月的 22 号）。
static func moon_tick_key(local_date: Dictionary) -> String:
	var y := int(local_date.get("year", 1970))
	var m := int(local_date.get("month", 1))
	var d := int(local_date.get("day", 1))
	var pick := 0
	for p in MOON_TICK_DAYS:
		if d >= int(p):
			pick = int(p)          # MOON_TICK_DAYS 升序 ⇒ 最后一个满足的 = 「≤ 今天 的最大 tick」
	if pick > 0:
		return "%04d-%02d-%02d" % [y, m, pick]
	m -= 1
	if m < 1:
		m = 12
		y -= 1
	return "%04d-%02d-22" % [y, m]


## 本地日期串（"YYYY-MM-DD"）的**本地零点**对应的 unix 秒。
## ★ Time.get_unix_time_from_datetime_dict 把传进去的字典当 UTC ⇒ 要减掉时区偏移（bias 分钟）。
static func local_midnight_unix(key: String, bias_min: int) -> int:
	var parts := key.split("-")
	if parts.size() != 3:
		return 0
	var wall := {
		"year": int(parts[0]), "month": int(parts[1]), "day": int(parts[2]),
		"hour": 0, "minute": 0, "second": 0,
	}
	return Time.get_unix_time_from_datetime_dict(wall) - bias_min * 60


# ---------------- 时刻快照 ----------------

## epoch 串（"YYYY-MM-DDTHH:MM:SSZ"）→ unix 秒。空 / 解析失败 → 兜底常量。
static func epoch_unix(epoch_utc: String) -> int:
	var s := epoch_utc.strip_edges()
	if s.is_empty():
		return EPOCH_FALLBACK_UNIX
	if s.ends_with("Z") or s.ends_with("z"):
		s = s.substr(0, s.length() - 1)
	var u := Time.get_unix_time_from_datetime_string(s)
	if u <= 0:
		return EPOCH_FALLBACK_UNIX
	return u


## 取系统当前时刻的 tick 快照。
static func now_snapshot(epoch_utc: String = "", now_unix: int = -1) -> Dictionary:
	if now_unix < 0:
		now_unix = int(Time.get_unix_time_from_system())
	var bias_min := 0
	var tz: Variant = Time.get_time_zone_from_system()
	if tz is Dictionary:
		bias_min = int((tz as Dictionary).get("bias", 0))
	return snapshot_from(
		Time.get_datetime_dict_from_system(false),
		Time.get_datetime_dict_from_system(true),
		now_unix, epoch_utc, bias_min)


## 由给定的本地 / UTC 时间字典组装 tick 快照（**探针注入合成日期**走这里，见计划书 §6.1）。
static func snapshot_from(local_dt: Dictionary, utc_dt: Dictionary, now_unix: int,
		epoch_utc: String = "", bias_min: int = 0) -> Dictionary:
	var p_key := planet_tick_key(local_dt)
	var m_key := moon_tick_key(local_dt)
	var spin_unix := now_unix - (now_unix % 3600)          # 自转：截到整点
	return {
		"epoch_unix": epoch_unix(epoch_utc),
		"planet_tick": p_key,
		"planet_unix": local_midnight_unix(p_key, bias_min),
		"moon_tick": m_key,
		"moon_unix": local_midnight_unix(m_key, bias_min),
		"spin_tick": "%04d-%02d-%02dT%02d:00Z" % [
			int(utc_dt.get("year", 1970)), int(utc_dt.get("month", 1)),
			int(utc_dt.get("day", 1)), int(utc_dt.get("hour", 0))],
		"spin_unix": spin_unix,
		"lam_sun": sun_longitude_deg(float(utc_dt.get("hour", 0))),
	}


# ---------------- 应用更新 ----------------

## 该 tick 是否需要更新：没记录过（空）或「due 比记录的新」。
## ★ 记录比 due 新（时钟回拨）⇒ **不动**（不回退，免得位置来回跳）。
static func tick_due(recorded: String, due: String) -> bool:
	if due.is_empty():
		return false
	if recorded.is_empty():
		return true
	return due > recorded


## 节点绕什么公转：日心天体（"planet"）/ 卫星（"moon"）/ 不绕行（"none"）。
static func tick_kind(n: WorldNode) -> String:
	if n == null or n.orbit_radius <= 0.0:
		return "none"
	var p := n.parent_node
	if p == null:
		return "none"
	if p.level == 0:
		return "planet"                       # 绕太阳 = 日心天体
	if p.template == WorldTemplates.T_BELT:
		return "planet"                       # 小行星带内成员：轨道半径就是离太阳距离
	if p.level >= 1:
		return "moon"                         # 绕行星 = 卫星
	return "none"


## 按 tick 把世界刷新到 now 对应的真实位置 / 朝向；`state` 就地更新（调用方负责落盘）。
## ★ `view` 须是 WorldView（提供 `.nodes` / `.node_by_sid()`）—— 参数不写类型，免得两个 class_name 互相引用。
## 返回 true = 本次确实更新了（至少一项 tick 触发）。
static func apply(view, state: Dictionary, now: Dictionary) -> bool:
	if view == null or not ("nodes" in view):
		return false
	var epoch := int(now.get("epoch_unix", EPOCH_FALLBACK_UNIX))
	var celestial: Dictionary = {}
	var cur: Variant = state.get(STATE_KEY, {})
	if cur is Dictionary:
		celestial = (cur as Dictionary)

	var p_tick := str(now.get("planet_tick", ""))
	var m_tick := str(now.get("moon_tick", ""))
	var s_tick := str(now.get("spin_tick", ""))
	var do_planet := tick_due(str(celestial.get("planet_tick", "")), p_tick)
	var do_moon := tick_due(str(celestial.get("moon_tick", "")), m_tick)
	var do_spin := tick_due(str(celestial.get("earth_tick", "")), s_tick)
	# ★★ 第十九轮修的坑：**不管到期与否都必须重算并施加**。
	#   原写法是「三项都不到期 ⇒ 直接 return false」，而「不到期」意味着玩家**刚刚才更新过**
	#   （状态文件里记的就是本次 tick）—— 于是**每次重新启动游戏**都变成「什么都没施加」：
	#   地球停在 JSON 的 epoch 轨道相位、且**完全不转**（本进程的 body basis 还是单位阵）⇒ 严重穿帮。
	#   「tick 之间冻结」的正确语义是「停在**上一次 tick 时刻**的姿态」，所以：
	#     到期 ⇒ 用本次 tick 的时刻；不到期 ⇒ 用**状态里记录的那一次**的时刻。
	#   （迁移兼容：旧状态没记 unix，此时退回 now 的同名值 —— 而「不到期」时两者指向**同一个 tick**，数值相同。）
	var p_unix := int(now.get("planet_unix", 0))
	var m_unix := int(now.get("moon_unix", 0))
	var s_unix := int(now.get("spin_unix", 0))
	if not do_planet:
		p_unix = int(celestial.get("planet_unix", p_unix))
	if not do_moon:
		m_unix = int(celestial.get("moon_unix", m_unix))
	if not do_spin:
		s_unix = int(celestial.get("spin_unix", s_unix))

	var nodes: Array = view.nodes
	# ① 公转：先把该动的天体**一次跳到**目标位置（先做，后面的地球对齐才拿得到新的日心方向）
	for item in nodes:
		var wn := item as WorldNode
		if wn == null:
			continue
		var kind := tick_kind(wn)
		if kind == "planet":
			wn.set_orbit_angle(angle_deg(wn.orbit_angle_init_deg,
				wn.effective_orbit_period_h(), epoch, p_unix))
		elif kind == "moon":
			wn.set_orbit_angle(angle_deg(wn.orbit_angle_init_deg,
				wn.effective_orbit_period_h(), epoch, m_unix))

	# ② 自转：地球 = 直射经线对太阳；其余 = 按 rotation_period_h
	var lam := float(now.get("lam_sun", 0.0))
	for item2 in nodes:
		var wn2 := item2 as WorldNode
		if wn2 == null:
			continue
		if wn2.spin_align_sun:
			var star: WorldNode = wn2.parent_node
			var dir := Vector3.ZERO
			if star != null:
				dir = (star.global_position - wn2.global_position).normalized()
			wn2.set_spin_deg(earth_spin_deg(dir, lam))
		elif not is_zero_approx(wn2.rotation_period_h):
			wn2.set_spin_deg(angle_deg(wn2.rotation_phase_deg,
				wn2.rotation_period_h, epoch, s_unix))

	# ③ 落状态（只动 celestial 这一节，其余顶层键原样保留 —— 别踩 StateRegistry 写的标签字段）
	celestial["planet_tick"] = p_tick
	celestial["moon_tick"] = m_tick
	celestial["earth_tick"] = s_tick
	# ★ 记下三条 tick 的**时刻**（unix）：下次「不到期」时要靠它把姿态重算回「上一次 tick 的状态」。
	celestial["planet_unix"] = p_unix
	celestial["moon_unix"] = m_unix
	celestial["spin_unix"] = s_unix
	state[STATE_KEY] = celestial
	return true


## 一步到位：取时刻快照 → 读状态 → 应用 → 落盘。返回 true = 有更新。
static func refresh(view, epoch_utc: String = "", state_path: String = "") -> bool:
	var now := now_snapshot(epoch_utc)
	var state := read_state(state_path)
	if not apply(view, state, now):
		return false
	write_state(state, state_path)
	return true


# ---------------- 更新状态：落盘 / 读盘 ----------------

## 状态文件路径：`state_path` 非空则用它（探针用）；否则用 SaveManager 的 Temp 目录。
## 无 SaveManager（探针 / 单测）→ 空串 ⇒ 读写都变空操作，绝不误写真实存档。
static func _resolve_path(state_path: String) -> String:
	var p := state_path.strip_edges()
	if not p.is_empty():
		return p
	if SaveManager == null or not SaveManager.has_method("get_temp_dir"):
		return ""
	return str(SaveManager.get_temp_dir()).path_join(STATE_FILE)


static func read_state(state_path: String = "") -> Dictionary:
	var p := _resolve_path(state_path)
	if p.is_empty() or not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		return {}
	return parsed


static func write_state(state: Dictionary, state_path: String = "") -> bool:
	var p := _resolve_path(state_path)
	if p.is_empty():
		return false
	var dir := p.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		push_warning("[WorldTime] 状态写盘失败：%s" % p)
		return false
	f.store_string(JSON.stringify(state, "\t"))
	f.close()
	return true
