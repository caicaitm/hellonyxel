# the words/city_index.gd
# 城市**空间索引**（第二十轮）：把「人工名单 20 城」与「脚本生成的全量 ~4.5 万城」合成一份
# 只读索引，并提供「只访问可见区域」的候选查询，供 WorldPage 每帧取该画哪些城市。
#
# ★ 为什么必须这么做（4.5 万这个量级）：
#   ① **不能每城一个 Node3D 锚点** —— 4.5 万个节点光节点开销就是几十 MB，且会拖慢场景树；
#      ⇒ 只存**类型化数组**（名字 / 球面局部方向 / 档位），取世界坐标时做一次壳变换即可。
#   ② **不能每帧遍历全部 4.5 万条** —— GDScript 里那就是几毫秒起步；
#      ⇒ ①首都/特大（本轮 227 座）与②大（78 座）**各自另存一份下标表**，遍历它们几乎零成本；
#        只有③小（4.5 万座）才走 **5°×5° 经纬网格**，且只访问「小的可见帽」覆盖到的 cell。
#        ★ 本轮实测：小档帽取 22° ⇒ 每帧只碰到 ~1600 座，而不是 4.5 万座。
#
# ★ 档位（tier）用**整数**，既省内存又直接当渲染优先级：
#   0 = 首都（★）/ 1 = 特大（◎）/ 2 = 大（⊙）/ 3 = 小（○）
class_name CityIndex
extends RefCounted

const TIER_CAPITAL := 0
const TIER_METRO := 1
const TIER_MEDIUM := 2
const TIER_SMALL := 3

const CELL_DEG := 5.0     # 网格粒度（纬度、经度都用它）
const LAT_CELLS := 36     # 180 / 5
const LON_CELLS := 72     # 360 / 5

var names := PackedStringArray()        # 每城的显示名
var dirs := PackedVector3Array()        # 每城的**球面局部单位方向**（建索引时算一次）
var tiers := PackedByteArray()          # 每城的档位（0~3）
var total := 0                          # 总城数
var tier_counts := [0, 0, 0, 0]         # 四档计数（自检用）
var always_idx := PackedInt32Array()    # 常显档（tier ≤ 1）的下标表
var medium_idx := PackedInt32Array()    # 大档（tier == 2）的下标表
## 网格：`_cells[lat_cell * LON_CELLS + lon_cell]` = 该 5°×5° 格里的城市下标（只供小档查询走）。
var _cells: Array = []

## ---- 第二十四轮：**多语言名**（空串 = 该语言**没有译本**，不是缺数据）----
## ★ 为什么是**一条扁平数组**而不是「每个语言一条 PackedStringArray」：
##   GDScript 的 PackedStringArray / Array 都是**写时复制**的 —— 从字典里取出来再 append，
##   每次都会整条拷贝（4.5 万 × 17 列 ⇒ O(n²) 直接卡死）；而对着**成员变量**直接 append 时
##   引用计数为 1 ⇒ 原址追加，O(n)。
##   每城占 `lang_n + 2` 列：[0..lang_n-1] = 各语言（顺序 = TranslationManager.LANG_CODES）
##                           + [lang_n] = 当地语言名（语言不定） + [lang_n+1] = 原文名
var names_flat := PackedStringArray()
var gnids := PackedInt32Array()        # GeoNamesID（0 = 无）—— 「本体编辑」按它定位到具体那一条
var lang_n: int = 0                    # 语言列数（= TranslationManager.LANG_CODES.size()）
var _lang_idx: Dictionary = {}         # 语言码 → 列号
## 显示名缓存：按**当前语言**懒解析（只对真正上屏的城市算一次；换语言时整体作废重解析）
var _disp_cache := PackedStringArray()
var _disp_done := PackedByteArray()
var _disp_lang: String = ""


func _init() -> void:
	lang_n = TranslationManager.LANG_CODES.size()
	for j in range(lang_n):
		_lang_idx[str(TranslationManager.LANG_CODES[j])] = j


# ---------------- 经纬度 ↔ 球面局部方向（本工程**唯一**的约定，实测定标） ----------------

## 经纬度（WGS84 十进制度，北纬 / 东经为正）→ 球面**局部**单位方向。
## ★ 这条约定必须与「等距圆柱贴图 / 地球自转」**完全一致**，且**由实测确定、不靠推导**：
##   读地表网格（SphereMesh 96×48）的顶点与 UV0，对若干已知方向取最近顶点：
##     方向 … 实测 UV0
##     (0,0,−1)（= 格林尼治）  → (0.500, 0.490)
##     (1,0,0)                 → (0.250, 0.490)   ⇒ 贴图经度 −90°（90°W）
##     (−1,0,0)                → (0.750, 0.490)   ⇒ 贴图经度 +90°（90°E）
##     (0,0,+1)                → (0.000, 0.490)   ⇒ 贴图经度 180°
##     (0,+1,0)                → (0.000, 0.000)   ⇒ 北极在 v = 0
##   ⇒ 由 u 反解 direction(u) = (sin 2πu, 0, cos 2πu)，贴图经度 λ 在 u = 0.5 + λ/360
##     ⇒ **经度 λ 的局部方向 = (−sin λ, 0, −cos λ)**（★ X 分量是**负** sin，不是正 sin！
##       第十九轮曾按正 sin 写，结果整批城市在经度上**整体镜像**，靠这条实测才查出来）。
##   补上纬度（+Y = 北极）即得 ⇒ (−sin lon·cos lat, sin lat, −cos lon·cos lat)。
static func latlon_dir(lat_deg: float, lon_deg: float) -> Vector3:
	var la := deg_to_rad(lat_deg)
	var lo := deg_to_rad(lon_deg)
	return Vector3(-sin(lo) * cos(la), sin(la), -cos(lo) * cos(la))


## 局部方向 → 经纬度（度）。`latlon_dir` 的逆运算（小档查询要用）。
static func dir_to_latlon(d: Vector3) -> Vector2:
	var n := d.normalized()
	var lat := rad_to_deg(asin(clampf(n.y, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(-n.x, -n.z))
	return Vector2(lat, lon)


## 档位字符串（人工名单用）→ 整数档位。
static func tier_from_string(s: String) -> int:
	match s.strip_edges().to_lower():
		"capital":
			return TIER_CAPITAL
		"metro":
			return TIER_METRO
		"medium":
			return TIER_MEDIUM
		_:
			return TIER_SMALL


# ---------------- 构建 ----------------

## 建索引：`curated` = 人工名单（earth_cities.json 的 cities 数组）；`bulk_path` = 脚本生成的全量 TSV
## （空串 = 不收全量）；`edits` = 「本体」编辑（键 = GeoNamesID 字符串，见 WorldData.city_edits）。
## 失败只会少数据，不会让建树整体失败。
static func build(curated: Array[Dictionary], bulk_path: String, edits: Dictionary = {}) -> CityIndex:
	var ci := CityIndex.new()
	ci._cells.resize(LAT_CELLS * LON_CELLS)
	for i in range(ci._cells.size()):
		ci._cells[i] = PackedInt32Array()
	for c in curated:
		ci._add_curated(c)
	ci._add_from_tsv(bulk_path)
	ci._apply_edits(edits)
	ci._finish()
	return ci


## 把「本体」编辑叠加上去（键 = GeoNamesID 的字符串形式）。★ 顺序讲究：名称 → 经纬度 → 档位
## （档位会被塞进 5° 网格 ⇒ 必须用**新的经纬度**算格子）。
func _apply_edits(edits: Dictionary) -> void:
	if edits.is_empty() or total <= 0:
		return
	var n := 0
	for k in edits:
		var i := gnids.find(int(str(k)))
		if i < 0:
			continue
		var p: Variant = edits[k]
		if not (p is Dictionary):
			continue
		var patch: Dictionary = p
		var nm: Variant = patch.get("names", {})
		if nm is Dictionary:
			for lang in (nm as Dictionary):
				set_name(i, str(lang), str((nm as Dictionary)[lang]))
		if patch.has("lat") and patch.has("lon"):
			set_latlon(i, float(patch["lat"]), float(patch["lon"]))
		if patch.has("tier"):
			set_tier(i, int(patch["tier"]))
		n += 1
	print("[CityIndex] 「本体」编辑已叠加：%d 条" % n)


## 人工名单（earth_cities.json 的 cities 数组）一条 → 索引一条。
## ★ 第二十四轮：名称从单语 `name` 升级为多语言 `names: {语言码: 名}`；
##   为兼容旧格式（只有 `name` / `intl` 的 mod 文件）留了一条回退。
func _add_curated(c: Dictionary) -> void:
	var nm_by_lang: Dictionary = c.get("names", {})
	if nm_by_lang.is_empty():
		nm_by_lang = { "zh_CN": str(c.get("name", "")), "en": str(c.get("intl", "")) }
	_add(nm_by_lang, str(c.get("local", "")), str(c.get("native", "")), int(c.get("gnid", 0)),
		float(c.get("lat", 0.0)), float(c.get("lon", 0.0)),
		tier_from_string(str(c.get("tier", "small"))))


func _add(nm_by_lang: Dictionary, local: String, native: String, gnid: int,
		lat: float, lon: float, tier: int) -> void:
	var d := latlon_dir(lat, lon)
	var i := total
	# 名称：按语言表顺序摊平成一行（空 = 该语言无译本）
	var nm := ""
	for code in TranslationManager.LANG_CODES:
		var v := str(nm_by_lang.get(str(code), ""))
		if nm.is_empty() and not v.is_empty():
			nm = v
		names_flat.append(v)
	names_flat.append(local)
	names_flat.append(native)
	gnids.append(gnid)
	# `names` 保留「第一个非空语言名」= 默认名（溯源 / 编辑器默认值用；显示一律走 display_name）
	names.append(nm)
	dirs.append(d)
	tiers.append(tier)
	tier_counts[tier] += 1
	total += 1
	if tier <= TIER_METRO:
		always_idx.append(i)
	elif tier == TIER_MEDIUM:
		medium_idx.append(i)
	if tier == TIER_SMALL:
		# 只有小档要网格（常显档与大档有自己的下标表，走网格反而更慢）
		# 纬度夹取到 0..35、经度取模 —— 极点处经度无意义，夹到边界即可。
		var y := int(clampf(floor((lat + 90.0) / CELL_DEG), 0.0, float(LAT_CELLS - 1)))
		var x := int(posmod(floor((lon + 180.0) / CELL_DEG), float(LON_CELLS)))
		var arr: PackedInt32Array = _cells[y * LON_CELLS + x]
		arr.append(i)
		_cells[y * LON_CELLS + x] = arr


## 读脚本生成的全量 TSV；'#' 开头是注释行。
## ★ 列：`lat<TAB>lon<TAB>pop<TAB>tier<TAB>gnid<TAB>各语言名…<TAB>local<TAB>native`
##   （语言的顺序由表头 `# 列：` 那行写死 = `build_city_bulk.py` 的 LANG_CODES，
##     但在下面**用列号换算**而不是假设顺序 ⇒ 脚本将来调列序也不会读错。）
## ★ 用 `get_line()` **流式**读：4.5 万行只要几十毫秒，也**不造中间对象**。
func _add_from_tsv(path_in: String) -> void:
	var p := path_in.strip_edges()
	if p.is_empty():
		return
	if not (p.begins_with("res://") or p.begins_with("user://") or p.begins_with("/") \
			or p.begins_with("\\") or (p.length() >= 2 and p.substr(1, 1) == ":")):
		p = WorldData.DATA_DIR + p
	if not FileAccess.file_exists(p):
		push_warning("[CityIndex] 全量城市文件不存在：%s" % p)
		return
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		push_warning("[CityIndex] 全量城市文件打不开：%s" % p)
		return
	var n := 0
	var n_bad := 0
	var need := 5 + lang_n + 2
	# ★ Godot 4 的 FileAccess **没有 `eof()`**（只有 `eof_reached()` —— 那是「读过界之后」才为真，
	#   会多读一行空串）⇒ 用「**位置 < 长度**」当循环条件，读得干净、不吞行也不补空行。
	var total_len := f.get_length()
	while f.get_position() < total_len:
		var line := f.get_line()
		if line.is_empty() or line.begins_with("#"):
			continue
		var c := line.split("\t")
		if c.size() < need:
			n_bad += 1
			continue
		var lat := float(c[0])
		var lon := float(c[1])
		if lat < -90.0 or lat > 90.0 or lon < -180.0 or lon > 180.0:
			n_bad += 1
			continue
		var nm_by_lang := {}
		var ok := false
		for j in range(lang_n):
			var v := c[5 + j]
			if not v.is_empty():
				nm_by_lang[str(TranslationManager.LANG_CODES[j])] = v
				ok = true
		var local := c[5 + lang_n]
		var native := c[5 + lang_n + 1]
		if not ok and local.is_empty() and native.is_empty():
			n_bad += 1
			continue
		_add(nm_by_lang, local, native, int(c[4]), lat, lon, clampi(int(c[3]), 0, 3))
		n += 1
	f.close()
	print("[CityIndex] 全量城市已载入：%d 行（坏行 %d；%s）" % [n, n_bad, p])


func _finish() -> void:
	print("[CityIndex] 城市索引就绪：总 %d（首都 %d / 特大 %d / 大 %d / 小 %d）常显档 %d 多语言列 %d"
		% [total, tier_counts[0], tier_counts[1], tier_counts[2], tier_counts[3],
		   always_idx.size(), lang_n])


# ---------------- 名称（第二十四轮：多语言 + 按玩家语言取显示名）----------------

## 该城在**指定语言**下的名（空 = 没有该语言的译本；**不做翻译**，只如实返回）。
func name_in(i: int, lang: String) -> String:
	var j := int(_lang_idx.get(lang, -1))
	if i < 0 or i >= total or j < 0:
		return ""
	return names_flat[i * (lang_n + 2) + j]


## 该城**当前该显示**的名（按玩家语言 + 回退链）：
##   玩家语言 → 同语族（繁↔简）→ en → zh_CN → 当地语言名 → 原文名 → 任一非空语言列。
## ★ 懒解析 + 缓存：只对真正上屏的城市算一次；换语言时整体作废（见 _ensure_disp_lang）。
func display_name(i: int) -> String:
	if i < 0 or i >= total:
		return ""
	_ensure_disp_lang()
	if _disp_done[i] == 0:
		_disp_cache[i] = _resolve_display(i)
		_disp_done[i] = 1
	return _disp_cache[i]


func _ensure_disp_lang() -> void:
	var cur := TranslationManager.current_lang
	if cur == _disp_lang and _disp_cache.size() == total:
		return
	if _disp_cache.size() != total:
		_disp_cache.resize(total)
		_disp_done.resize(total)
	_disp_done.fill(0)
	_disp_lang = cur


func _resolve_display(i: int) -> String:
	var base := i * (lang_n + 2)
	var j := int(_lang_idx.get(_disp_lang, -1))
	if j >= 0 and not names_flat[base + j].is_empty():
		return names_flat[base + j]
	# 同语族：繁体 ↔ 简体（没有对应译本时至少还是中文）
	var sib := "zh_CN" if _disp_lang == "zh_TW" else ("zh_TW" if _disp_lang == "zh_CN" else "")
	if not sib.is_empty():
		var js := int(_lang_idx.get(sib, -1))
		if js >= 0 and not names_flat[base + js].is_empty():
			return names_flat[base + js]
	# 通用回退：en → zh_CN → 当地语言名 → 原文名 → 任一非空语言列
	for code in ["en", "zh_CN"]:
		var jc := int(_lang_idx.get(code, -1))
		if jc >= 0 and not names_flat[base + jc].is_empty():
			return names_flat[base + jc]
	if not names_flat[base + lang_n].is_empty():
		return names_flat[base + lang_n]
	if not names_flat[base + lang_n + 1].is_empty():
		return names_flat[base + lang_n + 1]
	for jj in range(lang_n):
		if not names_flat[base + jj].is_empty():
			return names_flat[base + jj]
	return ""


## 编辑：写某城某语言的名（空串 = 删掉该语言的译本）。只作废**该城**的显示名缓存。
func set_name(i: int, lang: String, v: String) -> void:
	var j := int(_lang_idx.get(lang, -1))
	if i < 0 or i >= total or j < 0:
		return
	names_flat[i * (lang_n + 2) + j] = v.strip_edges()
	_disp_done[i] = 0


## 编辑：改经纬度（**必须**走 latlon_dir 这条唯一约定，见文件头）。
func set_latlon(i: int, lat: float, lon: float) -> void:
	if i < 0 or i >= total:
		return
	dirs[i] = latlon_dir(lat, lon)


## 编辑：改档位。★ 档位不只是个数字 —— 它同时决定「常显表 / 大档表 / 小档网格」三处归属，
## 所以要**从旧档的容器里摘掉、再塞进新档的容器**（否则会出现「首都却不常显」这种自相矛盾的状态）。
func set_tier(i: int, t: int) -> void:
	if i < 0 or i >= total or t < 0 or t > TIER_SMALL or tiers[i] == t:
		return
	var old := tiers[i]
	tiers[i] = t
	tier_counts[old] -= 1
	tier_counts[t] += 1
	if old <= TIER_METRO:
		always_idx.erase(i)
	elif old == TIER_MEDIUM:
		medium_idx.erase(i)
	else:
		_remove_from_cells(i)
	if t <= TIER_METRO:
		always_idx.append(i)
	elif t == TIER_MEDIUM:
		medium_idx.append(i)
	else:
		_add_to_cells(i)


## 把城市从 5°×5° 网格里摘掉（改档位时用；网格里的表长很小，线性摘即可）。
func _remove_from_cells(i: int) -> void:
	var ll := dir_to_latlon(dirs[i])
	var y := int(clampf(floor((ll.x + 90.0) / CELL_DEG), 0.0, float(LAT_CELLS - 1)))
	var x := int(posmod(floor((ll.y + 180.0) / CELL_DEG), float(LON_CELLS)))
	var key := y * LON_CELLS + x
	var arr: PackedInt32Array = _cells[key]
	var at := arr.find(i)
	if at >= 0:
		arr.remove_at(at)
		_cells[key] = arr


func _add_to_cells(i: int) -> void:
	var ll := dir_to_latlon(dirs[i])
	var y := int(clampf(floor((ll.x + 90.0) / CELL_DEG), 0.0, float(LAT_CELLS - 1)))
	var x := int(posmod(floor((ll.y + 180.0) / CELL_DEG), float(LON_CELLS)))
	var key := y * LON_CELLS + x
	var arr: PackedInt32Array = _cells[key]
	arr.append(i)
	_cells[key] = arr


# ---------------- 查询 ----------------

## 常显档（首都 + 特大）在可见帽内的下标 → `out`（遍历 227 条的表，零成本）。
func collect_always(cam_dir: Vector3, cap_deg: float, out: PackedInt32Array) -> void:
	_collect_list(always_idx, cam_dir, cap_deg, out)


## 大档（tier == 2）在帽内的下标 → `out`（78 条的表，零成本）。
func collect_medium(cam_dir: Vector3, cap_deg: float, out: PackedInt32Array) -> void:
	_collect_list(medium_idx, cam_dir, cap_deg, out)


func _collect_list(list: PackedInt32Array, cam_dir: Vector3, cap_deg: float, out: PackedInt32Array) -> void:
	out.clear()
	var cos_cap := cos(deg_to_rad(cap_deg))
	for i in list:
		if dirs[i].dot(cam_dir) >= cos_cap:
			out.append(i)


## 小档（tier == 3，4.5 万座）在帽内的下标 → `out`。**只走网格**，且只访问帽子覆盖到的 cell。
## ★ 小档的帽必须**收得很小**（本轮取 14°）—— 它才是「量」的所在，帽一大就又回到几万座。
##
## ★ 第二十一轮修掉**漏城 bug**：原来每行只用「**格中心纬度**」的经度半宽 Δλ 扫网格 ——
##   而帽子的 Δλ(φ) 随纬度变化很大（峰值在 sinφ = sinφ₀/cos(cap)，略偏极侧），格中心比格内
##   靠近视点的城市**允许的经度跨度更小** ⇒ 靠近帽子边缘的城市所在格被整格跳过、
##   连精确点乘都轮不上。实测 (70N,10E) 帽内 547 座漏 71 座（圣彼得堡一带整片消失）——
##   表现就是「应该显示出的城市不出现 / 出现比预想要迟」（视角挪到 Δlon 收进半宽内才冒出来）。
##   改成每行取 **[行下界, 行上界] ∪ 峰值纬度** 三处 Δλ 的最大值当半宽 ⇒ 是帽子的**超集**，
##   再由下面逐城 `dot ≥ cos_cap` 精确切边 ⇒ 不漏也不多收。每行只多两次三角函数，开销可忽略。
##
## ★ 逐纬度行扫、行内 x0→x1；极点附近 Δλ = 180° ⇒ 整行都扫。格中心经纬度当代表点，误差 ≤ 0.7 格。
func collect_small(cam_dir: Vector3, cap_deg: float, out: PackedInt32Array) -> void:
	out.clear()
	if total <= 0:
		return
	var ll := dir_to_latlon(cam_dir)
	var lat0 := ll.x
	var lon0 := ll.y
	var cos_cap := cos(deg_to_rad(cap_deg))
	var sin_p0 := sin(deg_to_rad(lat0))
	var cos_p0 := cos(deg_to_rad(lat0))
	var y0 := int(clampf(floor((lat0 - cap_deg + 90.0) / CELL_DEG), 0.0, float(LAT_CELLS - 1)))
	var y1 := int(clampf(floor((lat0 + cap_deg + 90.0) / CELL_DEG), 0.0, float(LAT_CELLS - 1)))
	# Δλ 的峰值纬度：d(Δλ)/dφ = 0 ⇒ sinφ = sinφ₀ / cos(cap)（始终略偏**极侧**）
	var phi_peak := NAN
	if absf(cos_cap) > 1e-6:
		var sp := sin_p0 / cos_cap
		if absf(sp) <= 1.0:
			phi_peak = rad_to_deg(asin(sp))
	for y in range(y0, y1 + 1):
		var lat_lo := -90.0 + CELL_DEG * float(y)
		var lat_hi := lat_lo + CELL_DEG
		# 本行的半宽 = 两端点 +（若落在本行的）峰值纬度处 Δλ 的最大值
		var half := maxf(_lon_half(cos_cap, sin_p0, cos_p0, lat_lo),
			_lon_half(cos_cap, sin_p0, cos_p0, lat_hi))
		if not is_nan(phi_peak) and phi_peak > lat_lo and phi_peak < lat_hi:
			half = maxf(half, _lon_half(cos_cap, sin_p0, cos_p0, phi_peak))
		if half <= 0.0:
			continue  # 帽子够不到这一纬度行
		var x0 := int(floor((lon0 - half + 180.0) / CELL_DEG))
		var x1 := int(floor((lon0 + half + 180.0) / CELL_DEG))
		if half >= 180.0:
			x0 = 0
			x1 = LON_CELLS - 1
		for x in range(x0, x1 + 1):
			var arr: PackedInt32Array = _cells[y * LON_CELLS + int(posmod(float(x), float(LON_CELLS)))]
			for i in arr:
				if dirs[i].dot(cam_dir) >= cos_cap:
					out.append(i)


## 帽子在纬度 `phi` 处的经度半宽 Δλ（度）：cos cap = sinφ₀·sinφ + cosφ₀·cosφ·cosΔλ 反解。
## 越界钳制：cap 够不到该纬度 ⇒ 0；整条纬线都在帽内 ⇒ 180。
static func _lon_half(cap_cos: float, sin_p0: float, cos_p0: float, phi: float) -> float:
	if absf(cos_p0) < 1e-6:
		return 180.0   # 视点在极点：经度失去意义，整行扫
	var pr := deg_to_rad(phi)
	var cosp := cos(pr)
	if absf(cosp) < 1e-4:
		return 180.0   # 该纬度贴近极点：同上
	var q := (cap_cos - sin_p0 * sin(pr)) / (cos_p0 * cosp)
	if q >= 1.0:
		return 0.0
	if q <= -1.0:
		return 180.0
	return rad_to_deg(acos(q))
