# blocks/ysm_projector.gd
# YSM（是，史蒂夫 / Yes Steve's Model）未加密模型包 → 2D 正交前视贴图烘焙器。
#
# 目标：让 2D 积木的「贴图/填充色」兼容 YSM 未加密模型包。
# 做法：纯 CPU 正交投影（无需 GPU，可 headless 验证），把 Bedrock 几何
#   （bone/cube 层级 + 逐面 UV 矩形）解析为 3D 盒，正交前视投影成 2D，
#   按面采样图集、深度排序（画家算法），烘焙成 ImageTexture 交给 BlockFill 当填充。
#
# 朝向约定：
#   - 闲时：角色正面朝屏幕。Minecraft/Bedrock 角色正面在 -Z（north 面），
#     故相机置于 -Z 看向 +Z，渲染 normal.z < 0 的面（front_negative_z = true）。
#   - 左右移动：复用积木现有 facing 水平镜像（block.gd 的 _should_flip_visual），
#     本烘焙只产出一张正面图，由积木自身镜像处理左/右。
#
# 兼容性：
#   - 包输入：目录（含 ysm.json）/ .zip（运行期解压到项目外缓存）/ 直接给 ysm.json 或 main.json。
#   - 退化：缺 ysm.json 时直接找 main.json + 任意 png 当图集。
#   - 仅支持未加密包；加密 .ysm 返回 null（积木退回纯色兜底）。

class_name YSMProjector
extends RefCounted

const DEG2RAD := PI / 180.0

# ===================== 权威映射表（Blockbench master, js/outliner/types/cube.js） =====================
# ★★ 不要自己推导这两张表。批次 558 教训：自推的「面角点顺序 + UV 轴向」看似合理，
#    实际与 Bedrock/Blockbench 的约定不符，结果是整只模型贴图错位、像碎纸片。
#
# 8 个顶点的顺序（Blockbench addVertices）：
#   每项 [ux,uy,uz]，1 = 取 to（= origin + size，即 max 角），0 = 取 from（= origin，min 角）。
const VERT_SEL := [
	[1, 1, 1],  # 0
	[1, 1, 0],  # 1
	[1, 0, 1],  # 2
	[1, 0, 0],  # 3
	[0, 1, 0],  # 4
	[0, 1, 1],  # 5
	[0, 0, 0],  # 6
	[0, 0, 1],  # 7
]

# CubeFace.getVertexIndices()：每个面取哪 4 个顶点（顺序 = 该面 4 个 UV 角的顺序）。
const FACE_VIDX := {
	"north": [1, 4, 6, 3],
	"east":  [0, 1, 3, 2],
	"south": [5, 0, 2, 7],
	"west":  [4, 5, 7, 6],
	"up":    [4, 1, 0, 5],
	"down":  [7, 2, 3, 6],
}

# 该 4 个顶点依次对应的 UV 角（Blockbench 逐顶点赋值顺序）：
#   0 → (u0,v0) 左上、1 → (u1,v0) 右上、2 → (u0,v1) 左下、3 → (u1,v1) 右下。
# 也就是说面的 4 个顶点与 (u0,v0)/(u1,v0)/(u0,v1)/(u1,v1) 一一对应，不需要任何「轴向表」。
#
# ★ 该 4 顶点顺序的绕序是「从外侧看顺时针」（Blockbench 渲染时用三角形索引 0,2,1 / 2,3,1
#   把绕序反过来）。故朝外法线 = (p2-p0) × (p1-p0)，bake() 里按此判断可见性。

# ===================== 数据持有 =====================
class YSMFace:
	var pts: PackedVector3Array   # 4 个世界坐标点（与 uvs 同序：对应 uv 矩形四角）
	var uvs: PackedVector2Array   # 4 个图集像素坐标（Y 向下，原点左上）
	var bone: String = ""         # 所属骨名（调试上色用）

class YSMModel:
	var atlas: Image = null      # 选中的图集
	var faces: Array = []         # YSMFace[]

# ===================== 缓存 =====================
static var _tex_cache: Dictionary = {}
static var _model_cache: Dictionary = {}
static var _extract_cache: Dictionary = {}
# 是否应用几何里的「静止位旋转」（骨/cube 的 rotation）。
# ★ 必须为 true：YSM 模型的静止姿势（A-pose 手臂 ±15°、裙摆 -97°、猫耳 ±12°）
#   全靠这些旋转摆到位。关掉后这些零件会停在「未旋转」的原始朝向上——
#   竖直裙片变横条、耳朵飞出去，整只模型看起来支离破碎（批次 556 根因）。
static var apply_rotations := true
# Bedrock / Blockbench 的欧拉顺序为 ZYX（R = Rz·Ry·Rx）。Godot 默认是 YXZ，
# 对单轴旋转没差别，但像 [0,90,-16.5] 这种双轴零件会歪，故显式指定。
static var euler_order := EULER_ORDER_ZYX
# 跳过 YSM 自发光/特效图层（骨名含 glow）：那些面是叠加发光层，
# 当普通不透明几何画出来就是一堆白块/彩色块，让主体看起来脏且碎。
static var skip_glow := true
# 跳过「道具挂点 + 武器/刀剑/枪械」骨。YSM 把玩家手持武器（刀/枪/剑）作为独立骨挂在
# 手上或背上，游戏里靠动画按手持物显示/隐藏；静止态它们会以默认偏移糊在身上，
# 2D 正视图里变成横穿身体的巨大斜板 —— 这是「看起来支离破碎」的主要来源之一。
static var skip_props := true
const PROP_PAT := ["locator", "dao", "qiang", "gun", "blade", "weapon",
	"sword", "rifle", "pistol", "_connect", "chixiao", "knife"]
# 剔除「远距离展示道具 / 背景板」：这类骨在游戏里被动画移到角色几十格外
# （Ak_Chen 的 `long` 有 152 个方块、gui 姿态 position=[14,15,51]，离身 55 格），
# 或本身就是一块背景板（`beijing`，单边 53 格）。2D 正视图里它们会把包围盒
# 撑大好几倍 → 角色被缩成一条，看起来「碎」。
static var drop_parked := true
const PARKED_BONE_PAT := ["beijing", "background", "bg_"]
# 姿态位移超过这个距离（模型单位）视为「被 park 出去」
const PARKED_DIST := 24.0
# 调试用：只烘焙骨名包含该子串的骨头（空=不过滤）。
static var debug_bone_filter := ""
# UV 缩放覆盖：0 = 自动（图集尺寸 / 几何声明 texture_size）。
# 有些包 geometry 写的 texture_width 与实际图集分辨率不一致（声明 256 实际 512），
# 自动值会采错区域，可用这里强制成 1.0 / 2.0 验证。
static var uv_scale_override := 0.0
# 调试用：全局翻转 UV 的 u/v（排查「图集 v 轴朝上/朝下」这类约定不一致）。
static var uv_flip_u := false
static var uv_flip_v := false
# 正视图绕 Y 轴的额外旋转（度）。0 = 模型默认朝向（Bedrock 正面为 -Z）。
# 少数包把角色朝 +Z 做的，可设 180 把正面转出来。
static var view_yaw := 0.0

# ===================== 姿态动画 =====================
# ★★ 这三个包的「几何静止态」都不是它在游戏里的样子：
#   - 手臂是 T-pose（横向外伸）→ 正视图画布被撑宽、比例失真；
#   - 武器/备用服装本体在几何里完全可见，靠动画把该骨的 `scale` 置 0 隐藏
#     （Ak_Chen 的 gui 姿态里 dao4/dao5/Ltdao/Rtdao/gun2/shuipao* 十几个骨都是 scale=0）。
# 不套姿态动画 = 手臂横伸 + 一堆本该隐藏的刀枪衣服糊在身上 → 看起来「支离破碎」。
# 故烘焙前先按姿态动画摆一次骨（rotation 覆盖、position 叠加、scale=0 视作隐藏）。
static var apply_pose := true
# 指定动画名；空 = 自动（gui → 模型选择 → idle）。
static var pose_animation := ""
# 采样时间（秒）。姿态类动画多为定值，取 0 即可。
static var pose_time := 0.0
# 忽略「根骨」上的 position/rotation：GUI/转盘动画会用它把整只模型转 52.5°、
# 平移一段来摆进预览框，套到正视图里只会让角色歪掉（scale 仍保留，用于隐藏）。
static var pose_skip_root_motion := true

## 丢弃某个包路径的缓存（玩家换包/换图后调用）。
static func forget(path: String) -> void:
	var p := str(path).strip_edges()
	_tex_cache.erase(p)
	_model_cache.erase(p)
	_extract_cache.erase(p)

## 主入口：包路径 → 烘焙好的 ImageTexture（缓存；每包只烘焙一次）。
static func get_texture(pkg_path: String, front_negative_z: bool = true) -> Texture2D:
	var p := str(pkg_path).strip_edges()
	if p == "":
		return null
	var key := p + ("|N" if front_negative_z else "|P")
	if _tex_cache.has(key):
		return _tex_cache[key]
	var model := _load_model(p)
	if model == null:
		_tex_cache[key] = null
		return null
	var img := bake(model, 512, front_negative_z)
	if img == null:
		_tex_cache[key] = null
		return null
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex

## 调试用：把烘焙结果直接存成 PNG（供目检）。
static func debug_bake(pkg_path: String, out_path: String, front_negative_z: bool = true) -> bool:
	var model := _load_model(pkg_path)
	if model == null:
		push_error("[YSMProjector] 无法加载模型包：%s" % pkg_path)
		return false
	var img := bake(model, 512, front_negative_z)
	if img == null:
		return false
	return img.save_png(out_path) == OK


# ===================== 包加载 =====================
static func _load_model(pkg_path: String) -> YSMModel:
	if _model_cache.has(pkg_path):
		return _model_cache[pkg_path]
	var pkg_dir: String
	if pkg_path.ends_with(".zip"):
		pkg_dir = _extract_zip(pkg_path)
		if pkg_dir == "":
			return null
	elif pkg_path.get_file() == "ysm.json" or pkg_path.get_file() == "main.json" \
			or pkg_path.ends_with(".YSM") or pkg_path.ends_with(".ysm"):
		pkg_dir = pkg_path.get_base_dir()
	else:
		pkg_dir = pkg_path

	var ysm_path = _find_file(pkg_dir, "ysm.json")
	var model_main_path: String = ""
	var atlas_paths: Array = []
	var default_tex: String = ""
	var ws := 1.0
	var hs := 1.0

	if ysm_path != "":
		var yd = _parse_json(ysm_path)
		if yd == null or not (yd is Dictionary) or not yd.has("files"):
			return null
		var player: Dictionary = yd["files"].get("player", {})
		if not (player is Dictionary):
			return null
		var model: Dictionary = player.get("model", {})
		var main_rel: String = model.get("main", "")
		if main_rel == "":
			return null
		model_main_path = pkg_dir.path_join(main_rel)
		var props: Dictionary = yd.get("properties", {})
		if props is Dictionary:
			default_tex = str(props.get("default_texture", ""))
			ws = float(props.get("width_scale", 1.0))
			hs = float(props.get("height_scale", 1.0))
		var tex_list = player.get("texture", [])
		for t in tex_list:
			if t is String:
				atlas_paths.append(pkg_dir.path_join(t))
			elif t is Dictionary:
				var u: String = t.get("uv", "")
				if u != "":
					atlas_paths.append(pkg_dir.path_join(u))
	else:
		var m := _find_file(pkg_dir, "main.json")
		if m == "":
			return null
		model_main_path = m
		var pngs := _find_files_by_ext(pkg_dir, "png")
		if default_tex != "":
			for pp in pngs:
				if pp.get_file().get_basename() == default_tex:
					atlas_paths.append(pp)
					break
		if atlas_paths.is_empty() and not pngs.is_empty():
			atlas_paths.append(pngs[0])

	# 选默认图集：优先 default_texture 同名，否则第一张
	var atlas_path: String = ""
	if default_tex != "":
		for ap in atlas_paths:
			if ap.get_file().get_basename() == default_tex:
				atlas_path = ap
				break
	if atlas_path == "" and not atlas_paths.is_empty():
		atlas_path = atlas_paths[0]
	if atlas_path == "" or model_main_path == "":
		return null

	var atlas := Image.new()
	if atlas.load(atlas_path) != OK:
		push_error("[YSMProjector] 图集加载失败：%s" % atlas_path)
		return null

	var geo = _parse_json(model_main_path)
	if geo == null:
		return null
	var pose: Dictionary = {}
	if apply_pose:
		pose = _load_pose(pkg_dir, ysm_path)
	var model := _build_model(geo, atlas, Vector3(ws, hs, ws), pose)
	if model == null:
		return null
	model.atlas = atlas
	_model_cache[pkg_path] = model
	return model


# ===================== 姿态动画解析 =====================
# 返回 {骨名: {"rotation": Vector3(度), "position": Vector3, "scale": Vector3}}，
# 只含姿态动画里确实有通道的骨。取不到动画时返回空字典（退回纯静止态）。
static func _load_pose(pkg_dir: String, ysm_path: String) -> Dictionary:
	var anim_paths: Array = []
	var preview_anim := ""
	if ysm_path != "":
		var yd = _parse_json(ysm_path)
		if yd is Dictionary and yd.has("files"):
			# ★ 包里自带的预览姿态（ysm.json properties.preview_animation）才是
			#   「作者希望这只模型怎么摆给人看」的权威答案（Ak_Chen=gui、
			#   Ak_Bitey=模型选择）。硬编码 ["gui","模型选择","idle"] 会挑错。
			var pr0 = yd.get("properties", {})
			if pr0 is Dictionary:
				preview_anim = str(pr0.get("preview_animation", ""))
			var player = yd["files"].get("player", {})
			if player is Dictionary:
				var an = player.get("animation", {})
				if an is Dictionary:
					for k in an.keys():
						var rel := str(an[k])
						if rel != "":
							anim_paths.append(pkg_dir.path_join(rel))
	if anim_paths.is_empty():
		for f in _find_files_by_ext(pkg_dir, "json"):
			if f.ends_with(".animation.json"):
				anim_paths.append(f)

	var wanted := pose_animation
	var cand: Array = []
	if wanted != "":
		cand.append(wanted)
	if preview_anim != "":
		cand.append(preview_anim)
	cand.append_array(["gui", "模型选择", "idle"])

	var anim = null
	var chosen_name := ""
	for c in cand:
		for p in anim_paths:
			if not FileAccess.file_exists(p):
				continue
			var d = _parse_json(p)
			if not (d is Dictionary):
				continue
			var an = d.get("animations", {})
			if an is Dictionary and an.has(c):
				anim = an[c]
				chosen_name = str(c)
				break
		if anim != null:
			break
	if not (anim is Dictionary):
		return {}

	var out := _anim_to_pose(anim)

	# ★★ 合并「预览动画」的隐藏判定（只取 scale≈0，不取旋转/位移）。
	# YSM 习惯把备用装备的隐藏写在**预览动画**里（Ak_Chen 在 `gui` 里把雨披
	# shuipao*/刀 dao*/帽子 maozi2 共 11 根骨设成 scale=0），而世界动画（`idle`）
	# 不复述这些通道。只按当前动画算隐藏 → 用 idle 摆姿时雨披会整件画出来
	# （`y-shuipao` 宽 12 格，躯干只有 ±6），与游戏内实际外观不符。
	# 规则：隐藏取并集，姿态（rotation/position）仍用当前动画。
	if preview_anim != "" and preview_anim != chosen_name:
		var pv_anim = _find_anim(anim_paths, preview_anim)
		if pv_anim is Dictionary:
			var hp := _anim_to_pose(pv_anim)
			for hb in hp.keys():
				var hr: Dictionary = hp[hb]
				if not hr.has("scale"):
					continue
				var hs: Vector3 = hr["scale"]
				if absf(hs.x) >= 0.01 and absf(hs.y) >= 0.01 and absf(hs.z) >= 0.01:
					continue
				if out.has(hb):
					var keep: Dictionary = out[hb]
					keep["scale"] = Vector3.ZERO
					out[hb] = keep
				else:
					out[hb] = {"scale": Vector3.ZERO}
	return out


# 在若干动画文件里按名字找一段动画（返回 animations[name] 原始 dict，找不到 → {}）。
static func _find_anim(anim_paths: Array, name: String) -> Dictionary:
	for p in anim_paths:
		if not FileAccess.file_exists(p):
			continue
		var d = _parse_json(p)
		if not (d is Dictionary):
			continue
		var an = d.get("animations", {})
		if an is Dictionary and an.has(name):
			var a = an[name]
			if a is Dictionary:
				return a
	return {}


# 一段动画 → {骨名: {rotation/position/scale: Vector3}}。
static func _anim_to_pose(anim: Dictionary) -> Dictionary:
	var out := {}
	var bones = anim.get("bones", {})
	if not (bones is Dictionary):
		return out
	for bn in bones.keys():
		var ch = bones[bn]
		if not (ch is Dictionary):
			continue
		var rec := {}
		if ch.has("rotation"):
			var r := _sample_channel(ch["rotation"], 3)
			if r.size() == 3:
				rec["rotation"] = Vector3(float(r[0]), float(r[1]), float(r[2]))
		if ch.has("position"):
			var pv := _sample_channel(ch["position"], 3)
			if pv.size() == 3:
				rec["position"] = Vector3(float(pv[0]), float(pv[1]), float(pv[2]))
		if ch.has("scale"):
			var sv := _sample_channel(ch["scale"], 3)
			if sv.size() == 3:
				rec["scale"] = Vector3(float(sv[0]), float(sv[1]), float(sv[2]))
		if not rec.is_empty():
			out[str(bn)] = rec
	return out


# 采样一个动画通道在 pose_time 处的值 → 长度 n 的 Array；无法解析（含 molang 表达式）→ []。
# 支持三种写法：标量（1.5）/ 3 数组 / 关键帧字典（键为时间字符串，
# 值可能是数组、数字，或 {"pre":..,"post":..}）。
static func _sample_channel(v: Variant, n: int) -> Array:
	if v is float or v is int:
		return _fill_scalar(float(v), n)
	if v is Array:
		return _vec_of(v, n)
	if v is Dictionary:
		var dv: Dictionary = v
		if dv.has("post"):
			return _sample_channel(dv["post"], n)
		if dv.has("pre"):
			return _sample_channel(dv["pre"], n)
		# 关键帧字典：按时间取最接近 pose_time 的帧（先取 <= pose_time 的最后一帧）
		var best_key := ""
		var best_t := -INF
		for k in dv.keys():
			var ks := str(k)
			if not ks.is_valid_float():
				continue
			var t := float(ks)
			if t <= pose_time + 1e-6 and t > best_t:
				best_t = t
				best_key = ks
		if best_key == "":
			# 所有帧都在 pose_time 之后 → 取最早一帧
			var earliest := INF
			for k in dv.keys():
				var ks2 := str(k)
				if not ks2.is_valid_float():
					continue
				var t2 := float(ks2)
				if t2 < earliest:
					earliest = t2
					best_key = ks2
		if best_key == "":
			return []
		return _sample_channel(dv[best_key], n)
	return []


static func _fill_scalar(f: float, n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(f)
	return out


static func _vec_of(a: Array, n: int) -> Array:
	if a.is_empty():
		return []
	if a.size() == 1:
		if a[0] is float or a[0] is int:
			return _fill_scalar(float(a[0]), n)
		return []
	if a.size() < n:
		return []
	var out: Array = []
	for i in n:
		var x = a[i]
		if x is float or x is int:
			out.append(float(x))
		else:
			return []
	return out


# ===================== 几何解析 =====================
static func _build_model(geo: Variant, atlas: Image, scale: Vector3,
		pose: Dictionary = {}) -> YSMModel:
	if not (geo is Dictionary):
		return null
	var geoms = geo.get("minecraft:geometry", [])
	if not (geoms is Array) or geoms.is_empty():
		return null
	var g = geoms[0] if (geoms[0] is Dictionary) else {}
	var bones = g.get("bones", [])
	if not (bones is Array):
		return null

	var model := YSMModel.new()
	var aw := float(atlas.get_width())
	var ah := float(atlas.get_height())

	# 几何里声明的贴图尺寸（texture_width/height）可能与实际图集分辨率不同
	# （很多 YSM 包把 256 皮肤放大成 512 图集）。UV 坐标写在「声明尺寸」空间里，
	# 必须按 实际图集/声明尺寸 缩放，否则所有面只采样到图集左上角一小块 → 颜色错乱。
	var desc: Dictionary = g.get("description", {})
	var tw: float = float(desc.get("texture_width", aw))
	var th: float = float(desc.get("texture_height", ah))
	var uscale := aw / tw
	var vscale := ah / th
	if uv_scale_override > 0.0:
		uscale = uv_scale_override
		vscale = uv_scale_override

	var bone_map := {}
	for b in bones:
		if b is Dictionary and b.has("name"):
			bone_map[str(b["name"])] = b

	# 根骨剪枝：YSM 包常把「装饰道具 / 背景板」挂在独立根骨上、并 park 到离身体很远的地方
	# （游戏里靠动画隐藏/显示）。烘焙 2D 正视图时它们会把包围盒撑到几倍大，
	# 导致主体被缩小、还多出半个场景 → 看起来「支离破碎」（批次 556 第二个根因）。
	# 规则：只保留立方体数量占主导（≥ 最大根骨的 25%）的根骨子树。
	var root_of := {}
	for b in bones:
		if b is Dictionary and b.has("name"):
			root_of[str(b["name"])] = _root_name(str(b["name"]), bone_map)
	var root_cubes := {}
	for nm in root_of.keys():
		var r: String = root_of[nm]
		var cnt: int = 0
		var bs = bone_map[nm].get("cubes", [])
		if bs is Array:
			cnt = bs.size()
		root_cubes[r] = int(root_cubes.get(r, 0)) + cnt
	var max_root_cubes := 0
	for r in root_cubes.keys():
		max_root_cubes = maxi(max_root_cubes, int(root_cubes[r]))
	var keep_roots := {}
	for r in root_cubes.keys():
		if max_root_cubes <= 0 or int(root_cubes[r]) * 4 >= max_root_cubes:
			keep_roots[r] = true

	# ★★ 「隐藏一棵子树」是统一规则：只要某根骨被判定要藏，它的全部后代也必须藏。
	# 只判「骨自身」会漏掉后代 —— 三份 YSM 包都靠父骨带一套子骨（shuipao3 →
	# w-shuipao3/y-shuipao3、chixiao → 刀身子骨、maozi → 帽檐……），
	# 父骨被跳过但子骨照画，子骨又被父骨的几何旋转甩到体外 → 满屏斜板 + 横甩的刀，
	# 整只模型「支离破碎」。触发隐藏的四种来源：
	#   ① 姿态 scale≈0（YSM 藏备用装备）② 道具/武器骨 ③ glow 发光层 ④ 背景板/被 park 的展示件
	var hidden_sub: Dictionary = {}
	var children_of: Dictionary = {}
	for b in bones:
		if not (b is Dictionary):
			continue
		var cn := str(b.get("name", ""))
		var cp := str(b.get("parent", ""))
		if cp != "":
			if not children_of.has(cp):
				children_of[cp] = []
			children_of[cp].append(cn)
	var hide_seeds: Array = []
	for b in bones:
		if not (b is Dictionary):
			continue
		var hn := str(b.get("name", ""))
		var hln := hn.to_lower()
		if skip_glow and hln.find("glow") >= 0:
			hide_seeds.append(hn)
			continue
		if skip_props and _is_prop_bone(hn):
			hide_seeds.append(hn)
			continue
		if pose.has(hn):
			var hr: Dictionary = pose[hn]
			if hr.has("scale"):
				var hs: Vector3 = hr["scale"]
				if absf(hs.x) < 0.01 or absf(hs.y) < 0.01 or absf(hs.z) < 0.01:
					hide_seeds.append(hn)
					continue
			if drop_parked and _is_parked_bone(hn, hr):
				hide_seeds.append(hn)
				continue
		elif drop_parked and _is_parked_bone(hn, {}):
			hide_seeds.append(hn)
	for seed_nm in hide_seeds:
		var stack: Array = [str(seed_nm)]
		while not stack.is_empty():
			var cur: String = stack.pop_back()
			if hidden_sub.has(cur):
				continue
			hidden_sub[cur] = true
			var kk = children_of.get(cur, [])
			if kk is Array:
				for c2 in kk:
					stack.append(str(c2))

	var memo: Dictionary = {}

	for b in bones:
		if not (b is Dictionary):
			continue
		var bname := str(b.get("name", ""))
		# 该骨（或其某个祖先）被判定隐藏 → 整棵子树都不画。
		if hidden_sub.has(bname):
			continue
		if debug_bone_filter != "" and bname.find(debug_bone_filter) < 0:
			continue
		if not keep_roots.has(str(root_of.get(bname, ""))):
			continue
		var Wb := _bone_world(b, bone_map, memo, pose, root_of)
		var cubes = b.get("cubes", [])
		if not (cubes is Array):
			continue
		for cube in cubes:
			if not (cube is Dictionary):
				continue
			var origin := _vec3(cube.get("origin", [0, 0, 0]))
			var size := _vec3(cube.get("size", [0, 0, 0]))
			# inflate：Bedrock 的「外扩量」，盒在六面各向外长 inflate（帽子/衣物常用）。
			# 等价于 Blockbench 的 center ± (halfSize + inflate)：
			#   from = origin - inflate，to = origin + size + inflate。
			# ★ cube 没写 inflate 时继承骨上的 inflate（Blockbench: `s.inflate ?? bone.inflate`）。
			var inflate := float(cube.get("inflate", float(b.get("inflate", 0.0))))
			var from_p := origin - Vector3(inflate, inflate, inflate)
			var to_p := origin + size + Vector3(inflate, inflate, inflate)
			# ★ 零厚度薄片（贴片/睫毛/裙摆）不能直接丢弃：Bedrock 规范是
			#   `if (from[i] === to[i]) to[i] += 0.001`，给它 1/1000 的厚度，
			#   这样正面仍然可见。之前直接 continue 会丢掉三份包里 95 个薄片
			#   （Ak_Chen: z 35 / y 19 / x 41），角色少一堆细节 → 看起来「碎」。
			if to_p.x - from_p.x < 1e-4:
				to_p.x = from_p.x + 0.001
			if to_p.y - from_p.y < 1e-4:
				to_p.y = from_p.y + 0.001
			if to_p.z - from_p.z < 1e-4:
				to_p.z = from_p.z + 0.001
			# ★★ cube 的 rotation 默认绕【立方体自身中心】转（Bedrock 规范：pivot 未写
			#   时取 origin + size/2）。曾误用「所在骨头的 pivot」当默认 —— 骨 pivot
			#   常在离方块十几格远的地方（Ak_Bitey UpperBody pivot y=11，方块在 y=3~6），
			#   22° 就能把它甩出半个身体 → 模型看起来像爆炸的碎板。
			#   YSM 包里带 rotation 却几乎不写 pivot，所以这条默认值必须对。
			var cpivot := origin + size * 0.5
			var cpivot_arr = cube.get("pivot", null)
			if cpivot_arr is Array:
				cpivot = _vec3(cpivot_arr)
			var crot := _vec3(cube.get("rotation", [0, 0, 0]))
			if not apply_rotations:
				crot = Vector3.ZERO
			var cbasis := Basis.from_euler(crot * DEG2RAD, euler_order)
			var cube_local := Transform3D(cbasis, cpivot) * Transform3D(Basis.IDENTITY, -cpivot)

			# 8 角按 Blockbench 的固定顺序（VERT_SEL）→ 局部 → cube 旋转 → 骨世界
			var world8 := PackedVector3Array()
			for sel in VERT_SEL:
				var v_local := Vector3(
					to_p.x if int(sel[0]) == 1 else from_p.x,
					to_p.y if int(sel[1]) == 1 else from_p.y,
					to_p.z if int(sel[2]) == 1 else from_p.z)
				var v_after := cube_local * v_local
				var v_world := Wb * v_after
				v_world.x *= scale.x
				v_world.y *= scale.y
				v_world.z *= scale.z
				world8.append(v_world)

			# 6 个面
			var mirror := bool(cube.get("mirror", false))
			var uv_spec = cube.get("uv", null)
			for kind in ["north", "south", "east", "west", "up", "down"]:
				# [u0, v0, w, h]（声明贴图空间；w/h 带符号，负 = 该方向翻转）
				var rect := _face_uv_rect(uv_spec, kind, size)
				if rect.is_empty():
					continue
				var u0: float = float(rect[0]) * uscale
				var v0: float = float(rect[1]) * vscale
				var w: float = float(rect[2]) * uscale
				var hh: float = float(rect[3]) * vscale
				if absf(w) < 0.05 or absf(hh) < 0.05:
					continue
				# mirror（Bedrock cube 级）：翻转 u 方向（uv_size.x 取负）
				if mirror:
					u0 += w
					w = -w
				if uv_flip_u:
					u0 += w
					w = -w
				if uv_flip_v:
					v0 += hh
					hh = -hh
				# 采样到「纹素中心」：矩形跨 |w| 个像素，中心在 u0±0.5 到 u0+w∓0.5。
				# 直接用端点会在边缘多采一个像素 → 密集图集上相邻面互相串色（一串条纹）。
				var du := 0.5 if w > 0.0 else -0.5
				var dv := 0.5 if hh > 0.0 else -0.5
				var ua := u0 + du
				var ub := u0 + w - du
				var va := v0 + dv
				var vb := v0 + hh - dv
				# 该面 4 角 UV，严格对应 pts 的顶点顺序。
				# ★★ pts（FACE_VIDX 顺序）从外侧看是「左上 → 右上 → 右下 → 左下」，
				#   所以 UV 必须是 (u0,v0) (u1,v0) (u1,v1) (u0,v1)。
				#   曾误写成 (u0,v0)(u1,v0)(u0,v1)(u1,v1) —— 底边两个 UV 互换，
				#   面内纹理被沿对角线镜射 → 脸/衣服全被拉成斜带，
				#   而 UV 中心均值不变 → 「UV 中心平涂」诊断图看起来正常，极易漏判。
				var uvs := PackedVector2Array([
					Vector2(ua, va), Vector2(ub, va), Vector2(ub, vb), Vector2(ua, vb)])
				# 逐面 UV 旋转（0/90/180/270）：Blockbench 每 90° 做一次角点置换 [0]←[2]←[3]←[1]←[0]
				var fuv = null
				if uv_spec is Dictionary:
					fuv = uv_spec.get(kind, null)
				if fuv is Dictionary:
					var frot := int(fuv.get("rotation", 0))
					var steps := int(round(float(frot) / 90.0)) % 4
					if steps < 0:
						steps += 4
					for _s in steps:
						uvs = PackedVector2Array([uvs[2], uvs[0], uvs[3], uvs[1]])
				var vidx: Array = FACE_VIDX[kind]
				var pts := PackedVector3Array()
				for k in 4:
					pts.append(world8[int(vidx[k])])
				var face := YSMFace.new()
				face.pts = pts
				face.uvs = uvs
				face.bone = bname
				model.faces.append(face)

	if model.faces.is_empty():
		return null
	return model


# 骨名是否属于「道具/武器挂点」（见 skip_props）。
static func _is_prop_bone(bname: String) -> bool:
	var ln := bname.to_lower()
	for pk in PROP_PAT:
		if ln.find(pk) >= 0:
			return true
	return false


# 是否是「背景板 / 被动画 park 到远处」的展示件（见 drop_parked）。
static func _is_parked_bone(bname: String, pose_rec: Dictionary) -> bool:
	var ln := bname.to_lower()
	for pk in PARKED_BONE_PAT:
		if ln.find(pk) >= 0:
			return true
	if pose_rec.has("position"):
		var off: Vector3 = pose_rec["position"]
		if off.length() > PARKED_DIST:
			return true
	return false


# 沿 parent 链找根骨名（带环保护）。
static func _root_name(name: String, bone_map: Dictionary) -> String:
	var cur := name
	var guard := 0
	while guard < 128:
		guard += 1
		if not bone_map.has(cur):
			return cur
		var p := str(bone_map[cur].get("parent", ""))
		if p == "" or not bone_map.has(p):
			return cur
		cur = p
	return cur


# 骨的模型空间变换（绕自身 pivot 旋转，再沿父链复合）。
# 姿态动画叠加规则（与 Blockbench/Minecraft 一致）：
#   rotation → **绝对值覆盖**几何里的静止旋转（不是相加）；
#   position → 平移叠加到 pivot；
#   scale    → 只用于判定隐藏（scale≈0），不做非均匀缩放（正交正视图里会剪切变形）。
static func _bone_world(bone: Dictionary, bone_map: Dictionary, memo: Dictionary,
		pose: Dictionary = {}, root_of: Dictionary = {}) -> Transform3D:
	var name: String = str(bone.get("name", ""))
	if memo.has(name):
		return memo[name] as Transform3D
	var pivot := _vec3(bone.get("pivot", [0, 0, 0]))
	var rotdeg := _vec3(bone.get("rotation", [0, 0, 0]))
	var pos_off := Vector3.ZERO
	var pr: Dictionary = pose.get(name, {}) if pose.has(name) else {}
	if pr.has("rotation"):
		rotdeg = pr["rotation"]
	if pr.has("position"):
		pos_off = pr["position"]
	# 根骨上的旋转/平移属于「摆进预览框」的相机式调整（Ak_Chen gui: Root 转 52.5°、
	# 平移 [-3,-20,-9]），套进正视图只会让角色歪掉/偏移，故默认忽略。
	if pose_skip_root_motion and parent_of(bone_map, name) == "":
		pos_off = Vector3.ZERO
		if not pr.is_empty():
			rotdeg = _vec3(bone.get("rotation", [0, 0, 0]))
	if not apply_rotations:
		rotdeg = Vector3.ZERO
		pos_off = Vector3.ZERO
	var rot := Basis.from_euler(rotdeg * DEG2RAD, euler_order)
	# 绕 pivot 旋转，并叠加动画位移：T(pivot+off)·Rot·T(-pivot)
	var bl := Transform3D(rot, pivot + pos_off) * Transform3D(Basis.IDENTITY, -pivot)
	var parent_name: String = str(bone.get("parent", ""))
	var wt: Transform3D
	if parent_name != "" and bone_map.has(parent_name):
		wt = _bone_world(bone_map[parent_name], bone_map, memo, pose, root_of) * bl
	else:
		wt = bl
	memo[name] = wt
	return wt


static func parent_of(bone_map: Dictionary, name: String) -> String:
	if not bone_map.has(name):
		return ""
	var p := str(bone_map[name].get("parent", ""))
	if p != "" and bone_map.has(p):
		return p
	return ""


# 取某个面的 UV 矩形 → [u0, v0, w, h]（坐标在「声明贴图尺寸」空间，w/h 带符号）。
# 支持三种写法：
#   ① 逐面对象 {"north":{"uv":[u,v],"uv_size":[w,h]}, ...}（YSM 主流；uv_size 可为负 = 翻转）
#   ② cube 级数组 "uv":[u,v] → box-UV 自动展开六面（老式/部分部件仍在用，如 Ak_Chen 的 152 个）
#   ③ 逐面直接给 4 数组 "north":[u,v,w,h]（少数导出器）
# ★ 负 uv_size 直接保留符号交给调用方处理，不要再转成 flip 标记 + 归一化尺寸
#   （那会丢掉「翻转」和「尺寸」的耦合，up/down 脸上必然错）。
static func _face_uv_rect(uv_spec: Variant, kind: String, size: Vector3) -> Array:
	if uv_spec is Dictionary:
		var fuv = uv_spec.get(kind, null)
		if fuv is Array and (fuv as Array).size() >= 4:
			return [float(fuv[0]), float(fuv[1]), float(fuv[2]), float(fuv[3])]
		if not (fuv is Dictionary):
			return []
		var uv_arr = fuv.get("uv", null)
		var sz_arr = fuv.get("uv_size", null)
		if not (uv_arr is Array) or not (sz_arr is Array):
			return []
		if uv_arr.size() < 2 or sz_arr.size() < 2:
			return []
		var ru := float(uv_arr[0])
		var rv := float(uv_arr[1])
		var rw := float(sz_arr[0])
		var rh := float(sz_arr[1])
		# ★ Blockbench parseCube 对 up/down 的逐面 UV 做了 180° 反置：
		#     if (key == 'up' || key == 'down') face.uv = [uv[2],uv[3],uv[0],uv[1]]
		#   即把矩形从对角反向（等价于绕矩形中心转 180°）。漏掉这一步，
		#   顶/底面（帽檐、裙摆上下面）朝向翻转，贴图上下左右颠倒。
		if kind == "up" or kind == "down":
			ru += rw
			rv += rh
			rw = -rw
			rh = -rh
		return [ru, rv, rw, rh]
	elif uv_spec is Array and (uv_spec as Array).size() >= 2:
		return _box_uv_rect(kind, float(uv_spec[0]), float(uv_spec[1]), size.x, size.y, size.z)
	return []


# box-UV（cube 级 "uv":[u,v]）展开布局 —— 原样照抄 Blockbench 的 face_list（权威）：
#   east : from=[0,        sz]      size=[sz, sy]
#   west : from=[sz+sx,    sz]      size=[sz, sy]
#   up   : from=[sz+sx,    sz]      size=[-sx, -sz]   ← 负尺寸，别归一化
#   down : from=[sz+2*sx,  0 ]      size=[-sx,  sz]   ← 负尺寸
#   south: from=[2*sz+sx,  sz]      size=[sx, sy]
#   north: from=[sz,       sz]      size=[sx, sy]
# 尺寸记号：sx=size.x（宽）sy=size.y（高）sz=size.z（厚）。
static func _box_uv_rect(kind: String, u: float, v: float, sx: float, sy: float, sz: float) -> Array:
	match kind:
		"east":  return [u + 0.0,          v + sz,        sz,        sy]
		"west":  return [u + sz + sx,      v + sz,        sz,        sy]
		"up":    return [u + sz + sx,      v + sz,        -sx,       -sz]
		"down":  return [u + sz + sx * 2.0, v + 0.0,      -sx,       sz]
		"south": return [u + sz * 2.0 + sx, v + sz,       sx,        sy]
		"north": return [u + sz,           v + sz,        sx,        sy]
	return []


static func _vec3(arr: Variant) -> Vector3:
	if arr is Array and arr.size() >= 3:
		return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	return Vector3.ZERO


# ===================== 烘焙（CPU 正交投影） =====================
# 性能关键：循环内绝不调用 Image.get_pixel/set_pixel（GDScript 逐像素调用极慢），
# 改为直接操作 PackedByteArray（get_data/set_data），512 目标从「超时挂死」降到毫秒级。
# debug_normal：用面法线着色（不采样图集），用于诊断「几何散架 vs 贴图错乱」。
# debug_uv_center：每面用其 UV 矩形中心颜色平涂（不做仿射），用于区分「UV 矩形错」还是「角点映射错」。
static func bake(model: YSMModel, target_max: int, front_negative_z: bool = true,
		debug_normal: bool = false, debug_uv_center: bool = false,
		debug_bone_color: bool = false,
		keep_main_blob: bool = true) -> Image:
	var faces = model.faces
	if faces.is_empty() or model.atlas == null:
		return null
	var atlas := model.atlas
	# 统一转 RGBA8（4 字节/像素），便于按原始字节采样
	if atlas.get_format() != Image.FORMAT_RGBA8:
		atlas.convert(Image.FORMAT_RGBA8)
	var aw := atlas.get_width()
	var ah := atlas.get_height()
	var atlas_data := atlas.get_data()

	# 视点绕 Y 轴旋转（可选）：把每个面的 4 个点先转到相机坐标系再投影。
	var use_yaw := absf(view_yaw) > 0.01
	var ya := cos(deg_to_rad(view_yaw))
	var yb := sin(deg_to_rad(view_yaw))
	var rpts: Array = []
	if use_yaw:
		for f in faces:
			var arr := PackedVector3Array()
			for pt in f.pts:
				arr.append(Vector3(pt.x * ya + pt.z * yb, pt.y, -pt.x * yb + pt.z * ya))
			rpts.append(arr)

	# 包围盒
	var minx := INF; var maxx := -INF
	var miny := INF; var maxy := -INF
	for fi in faces.size():
		var src: PackedVector3Array = rpts[fi] if use_yaw else (faces[fi] as YSMFace).pts
		for pt in src:
			minx = minf(minx, pt.x); maxx = maxf(maxx, pt.x)
			miny = minf(miny, pt.y); maxy = maxf(maxy, pt.y)
	var spanx := maxx - minx
	var spany := maxy - miny
	if spanx <= 0.0 or spany <= 0.0:
		return null

	var scale := float(target_max) / maxf(spanx, spany)
	var pad := 2.0
	var W := int(ceil(spanx * scale)) + int(pad * 2.0)
	var H := int(ceil(spany * scale)) + int(pad * 2.0)
	if W <= 0 or H <= 0:
		return null

	var img := Image.new()
	img.create(W, H, false, Image.FORMAT_RGBA8)
	# 自管 RGBA8 字节缓冲（不依赖 get_data 的返回长度，避免某些构造路径下
	# 返回的 buffer 短于 W*H*4 导致越界）
	var out_data := PackedByteArray()
	var need := W * H * 4
	out_data.resize(need)   # 全 0 = 透明黑

	# 投影 + 可见性 + 收集
	var rows := []   # [z_avg, img_pts(4), uvs(4), n3d, bone_color, z0, z1, z2]
	for fi in faces.size():
		var f: YSMFace = faces[fi]
		var src: PackedVector3Array = rpts[fi] if use_yaw else f.pts
		# ★ FACE_VIDX 的 4 顶点顺序从外侧看是「顺时针」（Blockbench 用三角形索引
		#   0,2,1 / 2,3,1 反绕序），故朝外法线 = (p2-p0) × (p1-p0)。
		#   写成 (p1-p0)×(p2-p0) 会得到朝内法线 → 把背面当正面渲染（批次 557 那种「没脸」）。
		var n: Vector3 = (src[2] - src[0]).cross(src[1] - src[0])
		var facing_ok: bool
		if front_negative_z:
			facing_ok = n.z < -1e-4
		else:
			facing_ok = n.z > 1e-4
		if not facing_ok:
			continue
		var ipts := PackedVector2Array()
		var zsum := 0.0
		for pt in src:
			# X 镜像：相机在 -Z 看向 +Z 时，世界 -X 落在观察者右侧，
			# 故 front_negative_z 把 X 轴翻转，使正面视图左右正确（不镜像角色）。
			var ix: float = (pt.x - minx) * scale + pad
			if front_negative_z:
				ix = (maxx - pt.x) * scale + pad
			ipts.append(Vector2(ix, (maxy - pt.y) * scale + pad))
			zsum += pt.z
		# 调试：按骨名散列成不同色相（同一骨骼同一颜色）→ 一眼看出「几何散架 vs 贴图错」
		var bcol := Color(1, 1, 1, 1)
		if debug_bone_color:
			var hh2 := float(absi(hash(f.bone)) % 360) / 360.0
			bcol = Color.from_hsv(hh2, 0.7, 0.95)
		rows.append([zsum / 4.0, ipts, f.uvs, n, bcol, src[0].z, src[1].z, src[2].z])

	if rows.is_empty():
		return null

	# ★ 逐像素 z-buffer（不用画家算法）：YSM 模型常有几千个薄片/decal 层层叠在一起，
	#   按「面平均 z」排序必然画错层（本该在后面的贴片盖住前面、边缘忽明忽暗），
	#   整只模型看起来像被撕碎。z-buffer 按真实深度逐像素比较，彻底消除该问题。
	var zbuf := PackedFloat32Array()
	zbuf.resize(W * H)
	var z_near_sign := 1.0   # 相机在 -Z：z 越小越近
	if front_negative_z:
		zbuf.fill(INF)
	else:
		zbuf.fill(-INF)
		z_near_sign = -1.0

	for row in rows:
		var ipts: PackedVector2Array = row[1]
		var uvs: PackedVector2Array = row[2]
		var n3d: Vector3 = row[3] as Vector3
		var bone_c: Color = row[4] as Color
		var coeffs := _affine(ipts[0], ipts[1], ipts[2], uvs[0], uvs[1], uvs[2])
		var ca := coeffs[0] as float
		var cb := coeffs[1] as float
		var cc := coeffs[2] as float
		var cd := coeffs[3] as float
		var ce := coeffs[4] as float
		var cf := coeffs[5] as float
		# 深度也按同样的 3 点仿射插值（平面内 z 是 (px,py) 的线性函数）
		var m3: Array = [
			Vector3(ipts[0].x, ipts[0].y, 1.0),
			Vector3(ipts[1].x, ipts[1].y, 1.0),
			Vector3(ipts[2].x, ipts[2].y, 1.0),
		]
		var zc := _solve3(m3, [float(row[5]), float(row[6]), float(row[7])])
		# 调试着色：面法线 → 颜色（不采样图集）
		var dbg_c := Color(1, 1, 1, 1)
		if debug_normal:
			dbg_c = Color(clampf(abs(n3d.x), 0.0, 1.0) * 0.8 + 0.2,
				clampf(abs(n3d.y), 0.0, 1.0) * 0.8 + 0.2,
				clampf(abs(n3d.z), 0.0, 1.0) * 0.8 + 0.2, 1.0)
		# UV 中心平涂色（诊断用）
		var uvcenter_c := Color(1, 1, 1, 1)
		if debug_uv_center:
			var cu := 0.0; var cv := 0.0
			for uvc in uvs:
				cu += uvc.x; cv += uvc.y
			cu /= float(uvs.size()); cv /= float(uvs.size())
			uvcenter_c = _sample_atlas_raw(atlas_data, aw, ah, cu, cv)
		# 包围盒
		var minpx := INF; var maxpx := -INF
		var minpy := INF; var maxpy := -INF
		for p in ipts:
			minpx = minf(minpx, p.x); maxpx = maxf(maxpx, p.x)
			minpy = minf(minpy, p.y); maxpy = maxf(maxpy, p.y)
		var x0 := int(maxf(0.0, floor(minpx)))
		var x1 := int(minf(float(W - 1), ceil(maxpx)))
		var y0 := int(maxf(0.0, floor(minpy)))
		var y1 := int(minf(float(H - 1), ceil(maxpy)))
		for py in range(y0, y1 + 1):
			var row_base := py * W
			for px in range(x0, x1 + 1):
				if not _point_in_quad(float(px), float(py), ipts):
					continue
				var c: Color
				if debug_bone_color:
					c = bone_c
				elif debug_normal:
					c = dbg_c
				elif debug_uv_center:
					c = uvcenter_c
				else:
					var u: float = ca * float(px) + cc * float(py) + ce
					var v: float = cb * float(px) + cd * float(py) + cf
					c = _sample_atlas_raw(atlas_data, aw, ah, u, v)
				if c.a <= 0.003:
					continue
				var zi := row_base + px
				var zf: float = zc.x * float(px) + zc.y * float(py) + zc.z
				if (zf - zbuf[zi]) * z_near_sign >= 0.0:
					continue
				zbuf[zi] = zf
				# z-buffer 已经保证这一层是最近的，直接覆盖（不再做 alpha 混合，
				# 否则半透明贴片会把下层颜色透出来搅成脏色）
				var idx := zi * 4
				out_data[idx]   = int(c.r * 255.0)
				out_data[idx+1] = int(c.g * 255.0)
				out_data[idx+2] = int(c.b * 255.0)
				out_data[idx+3] = int(c.a * 255.0)

	img.set_data(W, H, false, Image.FORMAT_RGBA8, out_data)
	if keep_main_blob:
		var cropped := _keep_main_blob(img)
		if cropped != null:
			return cropped
	return img


# 裁到不透明像素的包围盒（只裁边，不删任何像素）。
# ★ 早期版本按 8 邻域连通域「只留最大块」——那会连带删掉真实部件
#   （悬空的发梢、手臂、裙摆与主体只在对角/间隔处相接），
#   实际把整只角色削掉一圈，看起来更像「碎了」。这里只做裁剪。
static func _keep_main_blob(img: Image) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var data := img.get_data()
	var minx := w; var maxx := -1; var miny := h; var maxy := -1
	for y in h:
		var base := y * w
		for x in w:
			if data[(base + x) * 4 + 3] > 8:
				if x < minx: minx = x
				if x > maxx: maxx = x
				if y < miny: miny = y
				if y > maxy: maxy = y
	if maxx < minx or maxy < miny:
		return null
	var cw := maxx - minx + 1
	var ch := maxy - miny + 1
	if cw == w and ch == h:
		return img
	var out := Image.new()
	out.create(cw, ch, false, Image.FORMAT_RGBA8)
	var sb := PackedByteArray()
	sb.resize(cw * ch * 4)
	for y in ch:
		var src0 := ((miny + y) * w + minx) * 4
		var dst0 := y * cw * 4
		for b in cw * 4:
			sb[dst0 + b] = data[src0 + b]
	out.set_data(cw, ch, false, Image.FORMAT_RGBA8, sb)
	return out


# 3 点仿射（image→uv）
static func _affine(p0: Vector2, p1: Vector2, p2: Vector2,
		q0: Vector2, q1: Vector2, q2: Vector2) -> Array:
	var M := [
		[p0.x, p0.y, 1.0],
		[p1.x, p1.y, 1.0],
		[p2.x, p2.y, 1.0]
	]
	var ru := [q0.x, q1.x, q2.x]
	var rv := [q0.y, q1.y, q2.y]
	var au := _solve3(M, ru)
	var av := _solve3(M, rv)
	return [au.x, av.x, au.y, av.y, au.z, av.z]


static func _solve3(M: Array, r: Array) -> Vector3:
	var det := _det3(M)
	if abs(det) < 1e-9:
		return Vector3.ZERO
	var M0 := [[r[0], M[0][1], M[0][2]], [r[1], M[1][1], M[1][2]], [r[2], M[2][1], M[2][2]]]
	var M1 := [[M[0][0], r[0], M[0][2]], [M[1][0], r[1], M[1][2]], [M[2][0], r[2], M[2][2]]]
	var M2 := [[M[0][0], M[0][1], r[0]], [M[1][0], M[1][1], r[1]], [M[2][0], M[2][1], r[2]]]
	return Vector3(_det3(M0) / det, _det3(M1) / det, _det3(M2) / det)


static func _det3(M: Array) -> float:
	return M[0][0] * (M[1][1] * M[2][2] - M[1][2] * M[2][1]) \
		- M[0][1] * (M[1][0] * M[2][2] - M[1][2] * M[2][0]) \
		+ M[0][2] * (M[1][0] * M[2][1] - M[1][1] * M[2][0])


static func _point_in_quad(qx: float, qy: float, p: PackedVector2Array) -> bool:
	var sign := 0
	for i in 4:
		var a := p[i]
		var b := p[(i + 1) % 4]
		var cx := (b.x - a.x) * (qy - a.y) - (b.y - a.y) * (qx - a.x)
		if cx != 0.0:
			var s := 1 if cx > 0.0 else -1
			if sign == 0:
				sign = s
			elif sign != s:
				return false
	return true


# 从 RGBA8 原始字节取像素（避免 Image.get_pixel 的 API 开销）
static func _get_px(data: PackedByteArray, w: int, x: int, y_base: int) -> Color:
	var idx := (y_base + x) * 4
	var r := float(data[idx])   / 255.0
	var g := float(data[idx+1]) / 255.0
	var b := float(data[idx+2]) / 255.0
	var a := float(data[idx+3]) / 255.0
	return Color(r, g, b, a)

# 双线性采样图集（直接操作字节数组）
static func _sample_atlas_raw(data: PackedByteArray, aw: int, ah: int, u: float, v: float) -> Color:
	u = clampf(u, 0.0, float(aw) - 1.0)
	v = clampf(v, 0.0, float(ah) - 1.0)
	var x0 := int(floor(u)); var y0 := int(floor(v))
	var x1 := int(mini(x0 + 1, aw - 1))
	var y1 := int(mini(y0 + 1, ah - 1))
	var fx := u - float(x0)
	var fy := v - float(y0)
	var c00 := _get_px(data, aw, x0, y0 * aw)
	var c01 := _get_px(data, aw, x1, y0 * aw)
	var c10 := _get_px(data, aw, x0, y1 * aw)
	var c11 := _get_px(data, aw, x1, y1 * aw)
	return c00 * ((1.0 - fx) * (1.0 - fy)) + c01 * (fx * (1.0 - fy)) \
		+ c10 * ((1.0 - fx) * fy) + c11 * (fx * fy)


static func _over(dst: Color, src: Color) -> Color:
	var a := src.a + dst.a * (1.0 - src.a)
	if a <= 0.0:
		return Color(0, 0, 0, 0)
	var r := (src.r * src.a + dst.r * dst.a * (1.0 - src.a)) / a
	var g := (src.g * src.a + dst.g * dst.a * (1.0 - src.a)) / a
	var b := (src.b * src.a + dst.b * dst.a * (1.0 - src.a)) / a
	return Color(r, g, b, a)


# ===================== 文件工具 =====================
static func _parse_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var txt := f.get_as_text()
	f.close()
	var res = JSON.parse_string(txt)
	if res is Dictionary or res is Array:
		return res
	return null


static func _find_file(dir: String, name: String) -> String:
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	d.list_dir_begin()
	var fn := d.get_next()
	while fn != "":
		if fn == "." or fn == "..":
			fn = d.get_next()
			continue
		if d.current_is_dir():
			var r := _find_file(dir.path_join(fn), name)
			if r != "":
				d.list_dir_end()
				return r
		elif fn == name:
			d.list_dir_end()
			return dir.path_join(fn)
		fn = d.get_next()
	d.list_dir_end()
	return ""


static func _find_files_by_ext(dir: String, ext: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var fn := d.get_next()
	while fn != "":
		if fn == "." or fn == "..":
			fn = d.get_next()
			continue
		if d.current_is_dir():
			out.append_array(_find_files_by_ext(dir.path_join(fn), ext))
		elif fn.get_extension() == ext:
			out.append(dir.path_join(fn))
		fn = d.get_next()
	d.list_dir_end()
	return out


static func _ensure_dir(dir_path: String) -> void:
	dir_path = dir_path.replace("\\", "/")
	var parts := dir_path.split("/", false)
	if parts.is_empty():
		return
	var acc := parts[0] + "/"
	for i in range(1, parts.size()):
		acc = acc.path_join(parts[i])
		if DirAccess.open(acc) != null:
			continue
		var parent := acc.get_base_dir()
		var pd := DirAccess.open(parent)
		if pd != null:
			pd.make_dir(parts[i])


static func _extract_zip(zip_path: String) -> String:
	if _extract_cache.has(zip_path):
		return _extract_cache[zip_path]
	var out_dir := "D:/.0MyProject/ysm_cache/".path_join(zip_path.get_file().get_basename())
	# ★ 类名是全大写 ZIPReader（不是 ZipReader，大小写错了 class_exists 恒 false → 误判"不支持"）。
	#   用 ClassDB 动态实例化，避免依赖编译期符号（精简构建缺该类时也不会编译失败）。
	if not ClassDB.class_exists("ZIPReader"):
		push_error("[YSMProjector] 当前 Godot 不支持 ZIPReader，无法解压 .zip 包：%s" % zip_path)
		_extract_cache[zip_path] = ""
		return ""
	var zr = ClassDB.instantiate("ZIPReader")
	if zr == null or zr.open(zip_path) != OK:
		push_error("[YSMProjector] ZIPReader 打开失败：%s" % zip_path)
		_extract_cache[zip_path] = ""
		return ""
	var files: PackedStringArray = zr.get_files()
	for fname in files:
		var data: PackedByteArray = zr.read_file(fname)
		var dest := out_dir.path_join(fname)
		_ensure_dir(dest.get_base_dir())
		var wf := FileAccess.open(dest, FileAccess.WRITE)
		if wf != null:
			wf.store_buffer(data)
			wf.close()
	zr.close()
	_extract_cache[zip_path] = out_dir
	return out_dir
