# the words/earth_tile_layer.gd
# 地球近景「瓦片高清补丁」层（第二十六轮）。
#
# ★ 为什么需要它：地表底图是 8192×4096 的 8K 等距圆柱图（≈ 4.9 km/px）。相机拉近到 1.1R 以内时，
#   屏幕上的地面已经细到 ≈ 2~4 km/px ⇒ 底图被放大成糊块。素材库里另有一整套 NASA GIBS Blue Marble
#   瓦片（Level 6 = 80 列 × 40 行，每格 4.5°、512px ≈ 1 km/px）恰好能补这块清晰度。
#
# ★ 关键结论（勿重新推导）：8K 底图的**陆地**与这套瓦片是**同一套影像**，只有海洋被填成了蓝色
#   ⇒ 只把「相机脚下的那一小块陆地」换成瓦片即可无缝，绝不能整体替换底图（海洋会变）；
#   海洋照旧走 8K 底图（shader 里用 tex_spec 的「水=白」掩码把瓦片只贴在陆地上）。
#
# ★ 本层只做一件事：按「相机脚下的地面点」选一个瓦片块，拼成一张 atlas ImageTexture，
#   交给 world_earth_surface.gdshader 做**块内取 atlas 高清 / 块外取 8K 底图**的软过渡。
#   · 块尺寸 = **(G+2) 列 × G 行** —— 东、西各比中间**多补一列**：屏幕横向可视范围比纵向宽，
#     块的东西边缘最容易先露出「糊边」，横向多一列正好把这条边推出视野。G 随距离自适应（3 / 5 / 7）。
#   · 只在相机距 ≤ enable_ratio×半径 时启用（再远 8K 底图本身就够清晰，没必要白解码）。
#   · 瓦片解码走 WorkerThreadPool 并行；块移动时只补**新增的行 / 列**；解码结果进 LRU 缓存。
class_name EarthTileLayer
extends RefCounted

## 东西两侧额外多补的列数（每侧 1 列 ⇒ 总列数 = G + 2×这个值）。
const EXTRA_COLS := 1
const MAX_CACHE := 96          # 已解码瓦片缓存上限（512² RGBA ≈ 1 MB/张 ⇒ ≈ 96 MB 上限；
                               # ★ 必须 ≥ 一个块的总张数（G=7 时 (7+2)×7 = 63），否则块平移时
                               #   会被 LRU 立刻挤掉、每移一格都重新解码一遍）
const DECODE_THREADS := -1     # -1 = 线程池自动决定并行度

var dir: String = ""           # 瓦片目录（绝对路径，以 / 结尾）
var cols: int = 80             # 经度方向瓦片列数
var rows: int = 40             # 纬度方向瓦片行数（r0 = 90N → r39 = 90S）
var tile_px: int = 512         # 单张瓦片边长（px）
var enable_ratio: float = 1.3  # 相机距 ≤ 该倍率 × 半径 才启用

var _mat: ShaderMaterial = null     # 目标材质（world_earth_surface.gdshader）
var _atlas: Image = null            # G×G 瓦片拼图
var _atlas_tex: ImageTexture = null
var _grid: int = 0                  # 当前 atlas 的 G（0 = 还没建）
var _cell_key: PackedStringArray = PackedStringArray()  # 每个 atlas 格当前存的瓦片 key
var _filled: int = 0                # 已落进 atlas 的格数
var _ready: bool = false            # atlas 首次铺满过 ⇒ 才可以开始 blend（避免半张图/灰块）

var _cache: Dictionary = {}         # key("r,c") -> Image（LRU）
var _cache_order: Array = []

var _pending: Array = []            # 本轮要解码的瓦片 key（供线程池按 index 取）
var _slots: Array = []              # 与 _pending 平行：每项 {idx,i,j,key}（解码完往哪落）
var _decoded: Dictionary = {}       # key -> Image（线程写入，主线程读出）
var _mutex := Mutex.new()
var _job_id: int = 0


## 绑定材质 + 读配置（`tile_surface` 块）。
func setup(mat: ShaderMaterial, cfg: Dictionary) -> void:
	_mat = mat
	dir = str(cfg.get("dir", ""))
	cols = maxi(int(cfg.get("cols", 80)), 1)
	rows = maxi(int(cfg.get("rows", 40)), 1)
	tile_px = maxi(int(cfg.get("tile_px", 512)), 16)
	enable_ratio = float(cfg.get("enable_ratio", 1.3))
	if not dir.is_empty() and not dir.ends_with("/") and not dir.ends_with("\\"):
		dir += "/"
	if _mat != null:
		_mat.set_shader_parameter("detail_blend", 0.0)
		_mat.set_shader_parameter("detail_rect", Vector4(0, 0, 0, 0))
		_mat.set_shader_parameter("detail_grid", Vector2(3.0, 3.0))


## 每帧调用（由 WorldNode.update_tile_detail 转发）。
## `cam_local` = 相机在**本星体局部系**（球心为原点，边长单位 = 世界单位）里的位置（**未归一化**，
##   其长度就是相机到球心的距离）；`shell_r` = 地表壳半径（本地图半径 = 1 ⇒ 通常 = radius）。
func update_detail(cam_local: Vector3, shell_r: float) -> void:
	if _mat == null or dir.is_empty() or shell_r <= 0.0:
		return
	var d := cam_local.length()
	if d < 1e-9:
		return
	var ratio := d / shell_r
	if ratio > enable_ratio:
		# 离开近景 ⇒ 关掉细节层（底图 8K 本身够清晰），并让 atlas 保持现状以备下次回来
		_mat.set_shader_parameter("detail_blend", 0.0)
		return

	# ① 先把上一批线程解码的结果落地（还没完就先不动块选择，保持画面稳定）
	if _job_id != 0:
		if not WorkerThreadPool.is_group_task_completed(_job_id):
			return
		WorkerThreadPool.wait_for_group_task_completion(_job_id)
		_job_id = 0
		if _commit() and _atlas_tex != null:
			_atlas_tex.update(_atlas)

	# ② 选块：相机脚下的地面点 → 经纬度 → 中心瓦片 → 块（东、西各多补一列）
	# ★ 不变量：走到这里 _job_id 一定为 0（上面要么没任务，要么已 wait 完并重置），
	#   所以 `_ensure_grid` 不会因为「还有任务在跑」而跳过 ⇒ atlas 尺寸永远与 g 一致。
	#   _plan / _commit / _blit_cell 里仍保留越界防御：宁可少贴一格也不写坏堆内存。
	var g := _grid_for(ratio)
	var gw := g + 2 * EXTRA_COLS          # atlas 的列数（行数仍是 g）
	var latlon := CityIndex.dir_to_latlon(cam_local / d)
	# 等距圆柱约定（与 city_index.gd 一致）：u = 0.5 + lon/360，v = 0.5 - lat/180
	var col_c := int(floor((0.5 + latlon.y / 360.0) * float(cols)))
	var row_c := int(floor((0.5 - latlon.x / 180.0) * float(rows)))
	col_c = _wrap(col_c, cols)
	row_c = clampi(row_c, 0, rows - 1)
	var half := (g - 1) / 2
	# ★ 横向：列范围 = col_c − half − EXTRA_COLS … col_c + half + EXTRA_COLS（共 gw 列，中心仍是 col_c）
	var col_min := col_c - half - EXTRA_COLS
	# 纬度方向不做环绕（极点处夹住，块贴住北/南端）
	var row_min := clampi(row_c - half, 0, maxi(rows - g, 0))
	var rect := Vector4(fposmod(float(col_min) / float(cols), 1.0),
		float(row_min) / float(rows), float(gw) / float(cols), float(g) / float(rows))

	# ③ 保证 atlas 尺寸与 G 一致（仅在没有在跑的线程任务时重建）
	_ensure_grid(g)
	# ④ 补块：缓存里有的直接落，缺的排进本轮线程任务（块只平移一格时只需补一行/列）
	if _plan(g, col_min, row_min) and _atlas_tex != null:
		_atlas_tex.update(_atlas)
	if _pending.size() > 0 and _job_id == 0:
		_job_id = WorkerThreadPool.add_group_task(_decode_worker, _pending.size(), DECODE_THREADS, false,
			"earth_tile_decode")

	# ⑤ 推 uniform（首次铺满前不 blend，避免半张图 / 灰块闪现）
	if not _ready:
		_mat.set_shader_parameter("detail_blend", 0.0)
		return
	_mat.set_shader_parameter("detail_grid", Vector2(float(gw), float(g)))
	_mat.set_shader_parameter("detail_rect", rect)
	_mat.set_shader_parameter("detail_blend", 1.0)


## G 随距离自适应：越近块越大，保证「看得见的那一块」尽量都落在高清块里。
func _grid_for(ratio: float) -> int:
	if ratio > 1.20:
		return 3
	if ratio > 1.10:
		return 5
	return 7


func _ensure_grid(g: int) -> void:
	if g == _grid:
		return
	if _job_id != 0:
		return   # 有线程任务在跑，等它落完再换尺寸（避免线程写进旧 atlas 的落点表）
	_grid = g
	var gw := g + 2 * EXTRA_COLS
	_atlas = Image.create_empty(gw * tile_px, g * tile_px, false, Image.FORMAT_RGBA8)
	_atlas_tex = ImageTexture.create_from_image(_atlas)
	_mat.set_shader_parameter("tex_detail", _atlas_tex)
	_cell_key = PackedStringArray()
	_cell_key.resize(gw * g)
	_cell_key.fill("")
	_filled = 0
	_ready = false
	_pending.clear()
	_slots.clear()
	_decoded.clear()


## 把 (G+2)×G 块铺进 atlas：命中缓存的立刻落，缺的排进线程任务。返回 true = 这一帧 atlas 有更新。
func _plan(g: int, col_min: int, row_min: int) -> bool:
	var changed := false
	var gw := g + 2 * EXTRA_COLS
	var miss: Array = []
	for j in range(g):
		for i in range(gw):
			var idx := j * gw + i
			if idx < 0 or idx >= _cell_key.size():
				continue          # 防御：网格与 atlas 不一致时绝不越界（正常路径由 update_detail 拦住）
			var key := "%d,%d" % [_wrap(row_min + j, rows), _wrap(col_min + i, cols)]
			if _cell_key[idx] == key:
				continue
			if _cache.has(key):
				_blit_cell(idx, i, j, _cache[key])
				_cell_key[idx] = key
				changed = true
			else:
				miss.append({"idx": idx, "i": i, "j": j, "key": key})
	if miss.size() > 0 and _job_id == 0:
		_pending.clear()
		_slots.clear()
		for m in miss:
			_pending.append(m.key)
			_slots.append(m)
	return changed


## 把线程解码完成的结果落进 atlas，并写进 LRU 缓存。
func _commit() -> bool:
	_mutex.lock()
	var dec := _decoded.duplicate()
	_decoded.clear()
	_mutex.unlock()
	var changed := false
	for m in _slots:
		var key: String = m.key
		if m.idx < 0 or m.idx >= _cell_key.size():
			continue
		if dec.has(key) and dec[key] != null:
			_blit_cell(m.idx, m.i, m.j, dec[key])
			_cell_key[m.idx] = key
			changed = true
			_cache_put(key, dec[key])
	_slots.clear()
	_pending.clear()
	if _filled >= (_grid + 2 * EXTRA_COLS) * _grid:
		_ready = true
	return changed


## 线程池回调：按 index 取一张瓦片的 key，解码成 Image 放进 _decoded（互斥保护）。
func _decode_worker(idx: int) -> void:
	if idx < 0 or idx >= _pending.size():
		return
	var key: String = _pending[idx]
	var img := _load_tile(key)
	_mutex.lock()
	_decoded[key] = img
	_mutex.unlock()


## 读一张瓦片：`r{r:02}_c{c:02}.jpg`，统一成 tile_px 的 RGBA8（好 blit）。
func _load_tile(key: String) -> Image:
	var parts := key.split(",")
	if parts.size() != 2:
		return null
	var path := "%sr%02d_c%02d.jpg" % [dir, int(parts[0]), int(parts[1])]
	var img := Image.new()
	if img.load(path) != OK:
		return null
	if img.get_width() != tile_px or img.get_height() != tile_px:
		img.resize(tile_px, tile_px, Image.INTERPOLATE_LANCZOS)
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img


## 把一张瓦片图贴到 atlas 的第 (i, j) 格（i = 列、j = 行，行列**与瓦片块同序** ⇒ 无需翻转：
## 瓦片 r 越小越靠北，atlas 从左上（v 小 = 北）摆放，正好与 v = 0 在北一致）。
func _blit_cell(idx: int, i: int, j: int, img: Image) -> void:
	if _atlas == null or img == null:
		return
	# 防御：目标格必须完整落在 atlas 内（尺寸不一致时宁可不贴，也不能越界写坏堆内存）
	if (i + 1) * tile_px > _atlas.get_width() or (j + 1) * tile_px > _atlas.get_height():
		return
	_atlas.blit_rect(img, Rect2i(0, 0, tile_px, tile_px), Vector2i(i * tile_px, j * tile_px))
	if _cell_key.size() > idx and _cell_key[idx] == "":
		_filled += 1


func _cache_put(key: String, img: Image) -> void:
	if img == null or _cache.has(key):
		return
	_cache[key] = img
	_cache_order.append(key)
	while _cache_order.size() > MAX_CACHE:
		var old: String = _cache_order.pop_front()
		_cache.erase(old)


func _wrap(v: int, m: int) -> int:
	return ((v % m) + m) % m


## 释放：把可能在跑的瓦片解码线程任务**等完**再走。
## ★ 必须调用：WorkerThreadPool 的 group task 若在程序退出时还没被 wait 掉，Godot 会在
##   `~PagedAllocator` 报「Pages in use exist at exit」错误（实测踩到）。由 WorldNode._exit_tree 调。
func release() -> void:
	if _job_id != 0:
		WorkerThreadPool.wait_for_group_task_completion(_job_id)
		_job_id = 0
	_mutex.lock()
	_decoded.clear()
	_mutex.unlock()
	_pending.clear()
	_slots.clear()
