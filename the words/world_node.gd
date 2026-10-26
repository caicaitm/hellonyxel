# the words/world_node.gd
# 「世界」里的一个节点（星体）。节点记录自己的**级别 level**（太阳 0 / 行星 1 …），
# 并靠场景树的**父子关系**表达归属 —— ★ Godot 场景树本身就是世界节点树（决策 3）：
#   太阳是总节点（level 0），行星挂太阳下面（level 1）→ 未来「仅观察 0~N 级」时，
#   更深的次级节点整体不渲染（见 WorldView.set_max_visible_level）。
# 表现：球体网格（贴图取素材）+ 拾取体（供镜头拾取）+ 尾迹（画在**父节点**下，只覆盖公转轨迹的**身后**一段）。
# ★ 继承 StaticBody3D（而非裸 Node3D）：CollisionShape3D 只有挂在 CollisionObject3D 下才会生成
#   **真实物理体**，射线（左键点星体锚定 / 右键抓取拖动）才打得中；StaticBody3D 本身也是 Node3D，
#   场景树父子 = 世界归属的语义不变。
class_name WorldNode
extends StaticBody3D

const TRAIL_SPAN_DEG := 60.0  # 尾迹覆盖的角度范围（°）：只画行星**身后**这一段（公转方向的反侧）
const TRAIL_SEGMENTS := 48    # 尾迹分段数（不追求圆润，够看出弧即可）
## 多球壳网格的分段数（第十九轮是 96×48 —— 那时最近距离 1.35R，可见地表跨 ~12° 也还读得出球面）。
## ★ 为什么第二十轮要提到 256×128：最近距离放到 1.08R 后，屏幕上可见的地表只剩约 5°（≈ 890 km），
##   而 96 段 = 每段 3.75° ⇒ **整块可见地面都落在同一个四边形里**，会被当平面拉伸。
##   256×128（每段 ~1.4°）⇒ 可见地面跨 3~4 段，接缝与线性插值误差都远小于 1px。
##   ★ 球面本身的「平坦度」在这个尺度只有亚像素级（贴地俯视本来就是一块平面），所以不用再往上加。
const SHELL_RADIAL := 256
const SHELL_RINGS := 128
const RING_SEGMENTS := 128    # 星环圆环的圆周分段数（环贴图沿半径方向，圆周段数只影响轮廓圆滑度）

## 多球壳用的两个 shader（第十八轮·地球）：地表壳（昼夜混合 + 海面镜面）与云层壳（半透明）。
const EARTH_SURFACE_SHADER := preload("res://the words/world_earth_surface.gdshader")
const EARTH_CLOUD_SHADER := preload("res://the words/world_cloud_shell.gdshader")
## 「地心世界」反地面（凹面内壁）的 shader（第二十八轮）：只画背面 + 无光照 + 距离雾。
const INNER_GROUND_SHADER := preload("res://the words/world_inner_ground.gdshader")
## 云层壳的淡入淡出距离门（倍率 × 本节点半径）：相机距 ≤ 前者 → 云完全隐藏；≥ 后者 → 完全显示；
## 两者之间线性 ramp。★ 用 ramp 而非硬切：硬切在拉近 / 推远时画面会「啪」地闪一下。
const CLOUD_FADE_IN_RATIO := 3.0
const CLOUD_FADE_FULL_RATIO := 4.5
## 海拔栅格的编码上限（米）：与 world_earth_surface.gdshader 的 `height_max_m` 默认值一致。
## 栅格是 8 位灰度（0..1 → 0..6000 m，海面 = 0），「节点内容」里的海拔参考值就按这个上限换算。
const HEIGHT_MAX_M := 6000.0

# ---- 节点数据（JSON 初始状态里的字段）----
var sid: String = ""                  # 稳定字符串 ID（如 sun / earth）→ 镜头锚定用它
var display_name: String = ""         # 显示名（如「地球」）
var level: int = 0                    # 级别：太阳 0、行星/矮行星/小行星 1、卫星 2
var template: String = ""             # 模板 id（star / planet / dwarf / asteroid / moon）
var parent_sid: String = ""           # 父节点 sid（空 = 世界根）
var tags: Array = []                  # 字符串标签（未接 EventExpr 求值）
var props: Dictionary = {}            # 数值属性（本次仅存储）
var radius: float = 10.0              # 表现半径（★ 真实比例：1 单位 = 地球平均半径 6371 km）
var orbit_radius: float = 0.0         # 距**父节点**的轨道半径（0 = 不绕行）
## **当前**相位角（°）。JSON 里记的是 epoch 时刻的初始值（见 `orbit_angle_init_deg`）；
## 之后由 WorldTime 按 tick **一次性跳**到新值（不做连续动画，tick 之间冻结）。
var orbit_angle_deg: float = 0.0
## epoch 时刻的初始相位角（= JSON 原值，**永不改动**）：公转角度「每次从 epoch 重算」的基准。
## ★ 为什么不能拿 `orbit_angle_deg` 当基准：它每次 tick 都会被改写，累加会舍入漂移。
var orbit_angle_init_deg: float = 0.0
## 轨道周期（小时，**带符号**：负 = 相位角减小）。0 = 省略 ——
## 日心天体由 `props.orbit_au` 按开普勒第三定律推；卫星省略则**不动**（所以卫星必须显式给）。
var orbit_period_h: float = 0.0
## 自转周期（小时，带符号：负 = 逆行，如金星 / 天王星 / 冥王星）。0 = 不自转。
var rotation_period_h: float = 0.0
var rotation_phase_deg: float = 0.0   # epoch 时刻的初始自转朝向（无可辨认地标时可留 0）
## 自转是否「跟着太阳直射经度」对齐（地球专用）：见 WorldTime.earth_spin_deg。
## ★ 为什么用数据开关而不是写死 sid：世界 JSON 是通用的，引擎不该认「earth」这个特殊字符串。
var spin_align_sun: bool = false
var alpha: float = 1.0                # 不透明度（< 1 = 半透明；太阳用，让背后星体透出来）
var emission_energy: float = 0.7      # 自发光能量倍数（恒星用）
var orbit_incline_deg: float = 0.0    # 轨道平面相对**父节点轨道平面**的倾角（0 = 共面）
var orbit_node_deg: float = 0.0       # 升交点经度（只决定「往哪边倾」，不影响真实感）
var color: Color = Color.WHITE        # 实例色（无贴图时兜底）
var texture_path: String = ""         # 解析后的贴图路径（空 = 不贴图）
var emissive: bool = false            # 自发光（恒星）
## 自发光算子：false = MULTIPLY（色 × 贴图，默认；色调生效、层次保留），
## true = ADD（色 + 贴图，会整体冲亮 ⇒ 用来做「白热」的恒星，如第二十八轮的地心太阳）。
var emission_add: bool = false
## 列表排序用的「离太阳距离」（**仅 UI 列表定序**，3D 里不用它）：默认 = orbit_radius。
## ★ 为什么要单独一个字段：容器节点（「小行星带」）自身**不绕行**（orbit_radius = 0，位置必须钉在
##   太阳原点，带内小行星的 orbit_radius 才能直接表示「离太阳多远」），但它要出现在轨道上正确的位置
##   （火星与木星之间）⇒ 用本字段显式给一个代表值。
var sort_radius: float = 0.0
## 赤道面倾角（°）：本节点的**赤道面**（= 星环平面 + 赤道卫星的轨道面）相对参考面（世界根的 XZ 面）的倾角。
## ★ 为什么要这个字段：引擎不建行星自转轴的**朝向**，但「星环与赤道卫星共面」这件事必须对得上
##   —— 否则环按自己的倾角躺着、卫星却共面在参考面里，看上去就是两块错开的板子（第十三轮修正）。
##   ⇒ 用它当**唯一来源**：`_build_ring()` 拿它当环的倾角；子节点的 `orbit_basis()` 也先按它把整个卫星系统倾斜。
##   ★ 只给「有赤道卫星 / 有星环」的行星用（土星 = 26.73°，真实轴倾角）；月球那种**相对黄道**定倾角的
##     卫星不要给（地球给 0 ⇒ 月球照旧按 5.15° 相对黄道倾斜）。
var equatorial_tilt_deg: float = 0.0
## 星环定义（JSON 的 ring 块；空字典 = 无环）：
##   texture = 相对 texture_base 的环贴图（**横向条带图**：u 从环内缘 → 环外缘，v 为环厚度方向）；
##   inner_ratio / outer_ratio = 环内/外半径 ÷ 本节点 radius。
##   ★ 环的倾角不在这里给 —— 环就躺在行星赤道面里，倾角取本节点的 `equatorial_tilt_deg`。
var ring: Dictionary = {}
var ring_texture_path: String = ""    # 解析后的星环贴图路径
## **多球壳**定义（第十八轮，地球专用；由 JSON 的 `shells` 块给出，空字典 = 走普通单球体路径）：
##   surface = { radius_ratio, texture_day/night/normal/spec（+ 各 `*_path` 解析后的路径）}；
##   cloud   = { radius_ratio, texture（+ `texture_path`）, fade_in_ratio, fade_full_ratio }。
## ★ 为什么要多壳：一张贴图同时表达不了「向阳面白昼 / 背阳面夜景 / 海面镜面反射 / 云层」四件事，
##   拆成同心壳后每层各管一件事（云层还能按相机距离单独淡入淡出）。
var shells: Dictionary = {}

## **近景瓦片高清补丁**（第二十六轮，地球专用；由 JSON 的 `tile_surface` 块给出，空 = 不用瓦片）：
##   dir = 瓦片目录（绝对路径）、cols / rows / tile_px = 网格与单张像素、enable_ratio = 相机距 ÷ 半径 的启用门槛。
## ★ 只补**陆地**：8K 底图的陆地与素材瓦片是同一套影像，shader 用 tex_spec 掩码把瓦片只贴在陆地上
##   （见 the words/earth_tile_layer.gd 与 world_earth_surface.gdshader 的 detail 段）。
var tile_surface: Dictionary = {}
var _tile_layer: EarthTileLayer = null

## **地心世界**（第二十八轮）：
## `inner_surface = true` ⇒ 本节点是「凹面内壁」（反地面）：球只画**背面**，从内部看整片贴图铺满视野。
## `interior_of = <宿主 sid>` ⇒ 镜头锚定本节点时，**隐藏宿主的外表**（地表壳 + 云层），
##   否则地球的亮面会把里面的世界整个挡住（也顺手把这座星体的城市标识 / 铭牌关掉）。
var inner_surface: bool = false
var interior_of: String = ""
## 锚定本节点时要**额外隐藏**的节点 sid 列表（第二十八轮）：反地面锚定时要把地心太阳藏起来
## —— 否则那颗小球会卡在反地面球心，看起来像「反地面中间漏了个洞」。
var hide_when_anchored: Array[String] = []
## 拾取体是否要建（false = 不可点中）。★ 反地面半径接近地球表面，1.2×半径的拾取球会**包住地球**
##   ⇒ 从外面点地球时会先撞上它；所以给它 `no_pick`，改从「世界节点」列表锚定。
var no_pick: bool = false
## 外层（地表壳 / 云层）当前是否被隐藏（由 WorldView 在锚定变化时置位）。
var outer_hidden: bool = false
## 地壳（「地球表面 → 反地面」之间的厚填充）：**只在外层被隐藏时显示**，见 _build_crust()。
var crust_mi: MeshInstance3D = null

# ---- 关系（建树后填）----
var parent_node: WorldNode = null
var child_nodes: Array[WorldNode] = []
var trail: MeshInstance3D = null      # 尾迹弧线（渐隐；可见性由 WorldView._update_trails 每帧按相机距离决定）
var body_mi: MeshInstance3D = null    # 球体网格（★ 自转就是转**它**，绝不能转本节点 —— 那会把卫星与星环一起带着转）
var shell_mis: Array[MeshInstance3D] = []  # 全部壳网格（地表 + 云层）—— 自转时**一起转**，云才不会与地表错开
var surface_mat: ShaderMaterial = null     # 地表壳材质（接 sun_dir：昼夜混合 + 海面镜面）
var cloud_mat: ShaderMaterial = null       # 云层壳材质（接 sun_dir / shell_alpha）
var cloud_mi: MeshInstance3D = null        # 云层壳网格（可见性 / 透明度由 update_shells 按相机距离每帧定）
var _sun_dir: Vector3 = Vector3.RIGHT      # 「本节点 → 太阳」的世界空间方向（由 WorldView 写入，见 apply_sun_dir）

## **城市索引**（第二十轮）：由 `cities`（人工名单 JSON）与 `cities_bulk`（脚本生成的全量 TSV）合成，
## 见 city_index.gd。空 = 本星体没有城市。
## ★ 为什么不像星体那样「每城一个 Node3D 锚点」：全量有 4.5 万座，节点开销不可接受 ⇒ 只存类型化数组，
##   取世界坐标时做一次**壳变换**（自转照样自动成立，因为用的就是壳的变换）。
var city_index: CityIndex = null
## 城市所在壳的半径（= radius × 地表壳 radius_ratio）：取世界坐标时乘它。
var _city_shell_r: float = 0.0
## 海拔栅格（懒加载）：仅「节点内容」需要按经纬度取一个参考海拔时读一次，缓存常驻。
var _height_img: Image = null
var _height_img_tried := false
## 人口密度 / 气候分类栅格（懒加载，同上）：键 = JSON 里的贴图字段名（texture_pop / texture_climate_code）。
var _raster_imgs: Dictionary = {}
var _raster_tried: Dictionary = {}
## 人口密度栅格的编码上限（人/km²）：与转换脚本及 shader 一致，v = log10(1+d)/log10(1+上限)。
const POP_MAX_DENSITY := 100000.0
## Köppen-Geiger 类别码 → 中文名（1..31 陆地，32 = 海洋）；顺序与素材库 Map_KG-Global.R 一致。
const CLIMATE_NAMES := [
	"", "热带雨林气候", "热带季风气候", "热带草原气候（夏干）", "热带草原气候（冬干）",
	"热带半干旱气候", "温带半干旱气候", "热带沙漠气候", "温带沙漠气候",
	"亚热带湿润气候", "温带海洋性气候", "亚寒带海洋性气候", "地中海气候（夏干·热）",
	"地中海气候（夏干·暖）", "地中海气候（夏干·冷）", "亚热带季风气候", "温带季风气候",
	"亚寒带季风气候", "温带大陆性气候（夏热）", "温带大陆性气候（夏暖）",
	"亚寒带大陆性气候", "极地大陆性气候", "地中海性大陆气候（夏干·热）",
	"地中海性大陆气候（夏干·暖）", "地中海性大陆气候（夏干·冷）", "地中海性大陆气候（夏干·极冷）",
	"温带季风性大陆气候（夏雨·热）", "温带季风性大陆气候（夏雨·暖）",
	"亚寒带季风性大陆气候（夏雨）", "极地季风性大陆气候（夏雨·极冷）",
	"极地冰原气候", "极地苔原气候", "海洋",
]


## 从 JSON 记录填字段（模板提供缺省值，记录里的字段优先）。
func set_from_record(rec: Dictionary, base_dir: String) -> void:
	var tpl: Dictionary = WorldTemplates.get_template(str(rec.get("template", WorldTemplates.T_PLANET)))
	sid = str(rec.get("sid", ""))
	display_name = str(rec.get("name", sid))
	template = str(tpl.get("id", WorldTemplates.T_PLANET))
	level = int(rec.get("level", tpl.get("level", 1)))
	parent_sid = str(rec.get("parent", ""))
	radius = float(rec.get("radius", tpl.get("radius", 10.0)))
	orbit_radius = float(rec.get("orbit_radius", 0.0))
	orbit_angle_deg = float(rec.get("orbit_angle_deg", 0.0))
	orbit_angle_init_deg = orbit_angle_deg   # ★ 记住 epoch 初始相位（公转重算的基准，此后本字段不再改）
	orbit_period_h = float(rec.get("orbit_period_h", 0.0))
	rotation_period_h = float(rec.get("rotation_period_h", 0.0))
	rotation_phase_deg = float(rec.get("rotation_phase_deg", 0.0))
	spin_align_sun = bool(rec.get("spin_align_sun", false))
	alpha = float(rec.get("alpha", tpl.get("alpha", 1.0)))
	emission_energy = float(rec.get("emission_energy", tpl.get("emission_energy", 0.7)))
	orbit_incline_deg = float(rec.get("orbit_incline_deg", 0.0))
	orbit_node_deg = float(rec.get("orbit_node_deg", 0.0))
	equatorial_tilt_deg = float(rec.get("equatorial_tilt_deg", 0.0))
	sort_radius = float(rec.get("sort_radius", orbit_radius))
	emissive = bool(rec.get("emissive", tpl.get("emissive", false)))
	emission_add = bool(rec.get("emission_add", false))
	color = Color(str(rec.get("color", tpl.get("color", "#FFFFFF"))))
	texture_path = WorldData.resolve_texture(base_dir, str(rec.get("texture", tpl.get("texture", ""))))
	var rv: Variant = rec.get("ring", {})
	ring = rv if rv is Dictionary else {}
	ring_texture_path = WorldData.resolve_texture(base_dir, str(ring.get("texture", "")))
	var shv: Variant = rec.get("shells", {})
	shells = _parse_shells(shv, base_dir)
	# ★ 近景瓦片块（第二十六轮）：原样存下（dir 已是绝对路径，无需 resolve）。
	var tv: Variant = rec.get("tile_surface", {})
	tile_surface = tv if tv is Dictionary else {}
	# ★ 地心世界（第二十八轮）：凹面内壁 / 锚定时要隐藏哪个宿主的外表 / 是否可拾取。
	# ★ 第二十八轮：`inner_surface`（反地面）走「凹面内壁」路径 —— 只画背面、无光照、带距离雾。
	inner_surface = bool(rec.get("inner_surface", false))
	interior_of = str(rec.get("interior_of", ""))
	no_pick = bool(rec.get("no_pick", false))
	hide_when_anchored.clear()
	var hw: Variant = rec.get("hide_when_anchored", [])
	if hw is Array:
		for x in (hw as Array):
			hide_when_anchored.append(str(x))
	# ★ 城市：`cities` = 人工名单 JSON 文件名、`cities_bulk` = 脚本生成的全量 TSV（都可省略）。
	#   两个文件在 CityIndex 里合成一份只读索引（类型化数组 + 5° 网格，见 city_index.gd）。
	# ★ **只在真的给了城市数据时才建**：`CityIndex.build` 要读全量文件，79 个节点里只有地球有城市，
	#   不能给每个节点都白跑一遍（还会刷 79 条日志）。
	var cities_file := str(rec.get("cities", "")).strip_edges()
	var bulk_file := str(rec.get("cities_bulk", "")).strip_edges()
	if cities_file.is_empty() and bulk_file.is_empty():
		city_index = null
	else:
		city_index = CityIndex.build(WorldData.load_cities(cities_file), bulk_file,
			WorldData.city_edits(sid))   # ★ 第二十四轮：「本体」编辑叠加上去（键 = GeoNamesID）
	var tarr: Array = rec.get("tags", tpl.get("tags", []))
	tags = []
	for t in tarr:
		tags.append(str(t))
	var p: Variant = rec.get("props", {})
	props = p if p is Dictionary else {}
	name = sid   # 节点名 = sid → 场景树里一眼能看出世界结构


## 建表现：球体网格 + 材质（贴图/自发光）+ 拾取体 + 星环。
## ★ radius ≤ 0 = **纯容器节点**（如「小行星带」）：不建球体、不建拾取体 —— 它自身不可见、不可拾取，
##   只作为列表里的分组行与带内小行星的父节点。
func build_visual() -> void:
	if radius <= 0.0:
		return
	# ★ 第十八轮：给了 `shells` 的节点（地球）走**多球壳**路径，其余星体仍是普通单球体。
	# ★ 第二十八轮：`inner_surface`（反地面）走「凹面内壁」路径 —— 只画背面、无光照、带距离雾。
	if inner_surface:
		_build_inner_surface_body()
	elif shells.is_empty():
		_build_simple_body()
	else:
		_build_shell_bodies()
	# ★ 城市所在壳半径的兜底（无 `shells` 的单球体路径）：多球壳路径已在 _build_shell_bodies 里设过。
	if _city_shell_r <= 0.0:
		_city_shell_r = radius

	# 拾取体：镜头射线命中它 → 向上找最近的 WorldNode（见 WorldView.pick_node_at）
	# ★ 半径必须**相对本体半径**给（真实比例下水星半径 0.383，写死的 6.0 是它的 16 倍，
	#   会让整片星空都变成「可点中水星」）；又必须 **小于卫星视角的最近可贴距离**
	#   （WorldView.MIN_DIST_RATIO = 1.35×半径）—— 否则相机贴脸时会落进拾取球内部，
	#   从球内出发的射线打不中，左键锚定与右键抓取会一起哑掉。取 1.2×半径：
	#   比可见圆面略大（好瞄准），又稳稳留在 1.35×半径以内。
	# ★ `no_pick`：内壁半径接近宿主表面时，1.2×半径的拾取球会**包住宿主**（点地球会先撞上它）⇒ 不建。
	if not no_pick:
		var cs := CollisionShape3D.new()
		cs.name = "PickShape"
		var sph := SphereShape3D.new()
		sph.radius = maxf(radius * 1.2, 1e-3)
		cs.shape = sph
		add_child(cs)

	_build_ring()


## 普通单球体：SphereMesh + StandardMaterial3D（贴图 / 自发光 / 半透明）。太阳与所有行星 / 卫星走这条。
func _build_simple_body() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Body"
	mi.mesh = _make_sphere_mesh(radius, 48, 24)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.95
	mat.metallic = 0.0
	# ★ 半透明（太阳）：alpha < 1 ⇒ ALPHA 混合，让**背后**的行星 / 星空透出来（球心另有一盏光源，
	#   但光源本身不可见 —— 「半透明球 + 球心光源」的组合就是用户要的更真实的太阳）。
	#   不透明物体（行星）在 Godot 里先于透明物体绘制 ⇒ 从太阳背后看过去，行星会正常显示。
	# ★ 第十七轮：**球壳背面不画**（用户反馈「让太阳被阻挡面不去显示」）—— 一度为造「从内发光」开过
	#   CULL_DISABLED（双面），但那会把**背对镜头的那层壳**也画出来（叠出重影 / 空壳感），已回退默认
	#   的 CULL_BACK（只画朝向镜头的正面）。「从内发光」现在靠**自发光带同一张贴图**实现（见 emission_texture）。
	#   ★ 注意：太阳贴的是**球面**、球心那盏 OmniLight 的光对所有表面都是「从背后照来」(N·L ≤ 0)，
	#     所以太阳表面**几乎只靠自发光**发亮 ⇒ `emission_energy` 要够（见 world_templates.gd T_STAR）。
	if alpha < 0.999:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	if not texture_path.is_empty():
		var tex: Texture2D = TextureCache.fetch(texture_path)
		if tex != null:
			mat.albedo_texture = tex
		else:
			push_warning("[WorldNode] sid=%s 贴图取不到（用实例色兜底）：%s" % [sid, texture_path])
	if emissive:
		mat.emission_enabled = true
		mat.emission = color
		# ★ 第十七轮：自发光**也吃这张表面贴图**。只给纯色的话，高能量自发光会把贴图细节冲平
		#   （看起来就像「贴图被去掉了」）；带上贴图 ⇒ 亮部发光、暗部/米粒组织仍看得见。
		# ★★ 关键：`emission_operator` 必须显式设成 **MULTIPLY**。Godot 的默认是 **ADD**
		#   （EMISSION = 色×能量 + 贴图×能量）—— 那等于把贴图**加到**色调上，黄色贴图会直接把
		#   R/G 两个通道顶到饱和（实测日面 R=G=140 恒定、色相变黄，橙色 tint 形同虚设）；
		#   改成 MULTIPLY 后 EMISSION = 色 × 能量 × 贴图 ⇒ 色调真正生效，且贴图仍提供明暗层次。
		mat.emission_operator = (BaseMaterial3D.EMISSION_OP_ADD if emission_add
			else BaseMaterial3D.EMISSION_OP_MULTIPLY)
		mat.emission_texture = mat.albedo_texture
		mat.emission_energy_multiplier = emission_energy
	mi.material_override = mat
	add_child(mi)
	body_mi = mi


## 多球壳（第十八轮·地球）：① 地表壳（半径 = R × surface.radius_ratio，默认 1.0）
## ② 云层壳（半径 = R × cloud.radius_ratio，默认 1.015 ⇒ **贴近地面但不与地面重合**）。
## ★ 两壳同心、共轴 ⇒ 自转时一起转（见 set_spin_deg），云不会与地表错开。
## ★ 地表壳**不是** StandardMaterial3D：昼夜混合 / 海面镜面必须手算，见 world_earth_surface.gdshader。
func _build_shell_bodies() -> void:
	var sv: Dictionary = shells.get("surface", {})
	var smat := ShaderMaterial.new()
	smat.shader = EARTH_SURFACE_SHADER
	smat.set_shader_parameter("tex_day", _fetch_shell_tex(sv, "texture_day_path"))
	smat.set_shader_parameter("tex_night", _fetch_shell_tex(sv, "texture_night_path"))
	smat.set_shader_parameter("tex_normal", _fetch_shell_tex(sv, "texture_normal_path"))
	smat.set_shader_parameter("tex_spec", _fetch_shell_tex(sv, "texture_spec_path"))
	# ★ 第二十七轮：近景地势起伏用的海拔栅格（等距圆柱 8 位灰度）。取不到 = 用不到地形明暗，其余照旧。
	smat.set_shader_parameter("tex_height", _fetch_shell_tex(sv, "texture_height_path"))
	# ★ 第二十九轮：视图叠加用的栅格 —— 人口密度（8 位对数索引）/ 气候分类（Köppen 配色图）。
	smat.set_shader_parameter("tex_pop", _fetch_shell_tex(sv, "texture_pop_path"))
	smat.set_shader_parameter("tex_climate", _fetch_shell_tex(sv, "texture_climate_path"))
	smat.set_shader_parameter("sun_dir", _sun_dir)
	var mir := MeshInstance3D.new()
	mir.name = "Body"
	mir.mesh = _make_sphere_mesh(radius * float(sv.get("radius_ratio", 1.0)), SHELL_RADIAL, SHELL_RINGS)
	mir.material_override = smat
	add_child(mir)
	body_mi = mir
	surface_mat = smat
	shell_mis.append(mir)
	# ★ 近景瓦片层（第二十六轮）：给了 tile_surface 才建（目前只有地球）——
	#   它按「相机脚下的地面点」把素材瓦片拼成 atlas，交给 shader 的 detail 段只贴在陆地上。
	if not tile_surface.is_empty():
		_tile_layer = EarthTileLayer.new()
		_tile_layer.setup(smat, tile_surface)
	# ★ 城市所在壳的半径：城市的世界坐标 = **壳变换 × (局部方向 × 这个半径)**。
	#   第二十轮改成这样（不再逐城建 Node3D 锚点）：全量 4.5 万座用节点不可行，见 city_index.gd。
	_city_shell_r = radius * float(sv.get("radius_ratio", 1.0))
	_build_crust()

	var cv: Dictionary = shells.get("cloud", {})
	if cv.is_empty():
		return
	var cmat := ShaderMaterial.new()
	cmat.shader = EARTH_CLOUD_SHADER
	cmat.set_shader_parameter("tex_clouds", _fetch_shell_tex(cv, "texture_path"))
	cmat.set_shader_parameter("sun_dir", _sun_dir)
	cmat.set_shader_parameter("shell_alpha", 1.0)
	var cmi := MeshInstance3D.new()
	cmi.name = "CloudShell"
	# ★ 分段数与地表壳一致，且半径更大 ⇒ 云壳的分面偏差永远不会「陷进」地表壳里。
	cmi.mesh = _make_sphere_mesh(radius * float(cv.get("radius_ratio", 1.015)), SHELL_RADIAL, SHELL_RINGS)
	cmi.material_override = cmat
	add_child(cmi)
	cloud_mi = cmi
	cloud_mat = cmat
	shell_mis.append(cmi)


## 「地壳」填充（第二十八轮续）：**外层被隐藏时才出现**的一层厚壁，用来表达「地面有厚度」。
##   · 半径 = 地球半径 × `crust.radius_ratio`（默认 0.72）⇒ 从里面看是一圈暗色岩壁，
##     把「地球表面 → 反地面」之间的空档填出一段实体，而不是让地球凭空消失。
##   · 与反地面同一套 shader（只画背面 + 无光照 + 距离雾）：它同样只应被**从内向外**看到，
##     从球外看则是「远侧内壁」，正好是一张剖面图。
##   · ★ 不进 shell_mis：shell_mis 是「外层」，本层恰恰要在外层隐藏时**显示**（见 set_outer_hidden）。
func _build_crust() -> void:
	var rv: Dictionary = shells.get("crust", {})
	if rv.is_empty():
		return
	var rr := radius * float(rv.get("radius_ratio", 0.72))
	var mi := MeshInstance3D.new()
	mi.name = "Crust"
	mi.mesh = _make_sphere_mesh(rr, SHELL_RADIAL, SHELL_RINGS)
	var mat := ShaderMaterial.new()
	mat.shader = INNER_GROUND_SHADER
	var tex_path := str(rv.get("texture_path", ""))
	# ★ 没给贴图 ⇒ 纯色填充（第二十八轮续）：地表与反地面之间就是整块实心色块，不再有岩石纹理。
	mat.set_shader_parameter("use_texture", not tex_path.is_empty())
	mat.set_shader_parameter("tex_ground", TextureCache.fetch(tex_path))
	mat.set_shader_parameter("tint", Color(str(rv.get("tint", "#6B5540"))))
	mat.set_shader_parameter("gain", float(rv.get("gain", 1.0)))
	mat.set_shader_parameter("radius", rr)
	mat.set_shader_parameter("haze_color", Color(str(rv.get("haze_color", "#4A3A2C"))))
	# ★ 第二十八轮续：地壳 = **实心**地表层，紧贴被隐藏的地表之下（0.995R），而且**完全不透明**。
	#   之前放在 0.72R + 距离雾 ⇒ 看起来就是一张飘在空中的「地面内侧贴片」；
	#   紧贴地表 + 去掉雾之后，从外面看是一个实心岩球（中心嵌着反地面），从里面看是紧实的岩壁。
	mat.set_shader_parameter("haze_start", 1.6)
	mat.set_shader_parameter("haze_end", 3.4)
	mat.set_shader_parameter("haze_max", 0.0)
	mi.material_override = mat
	# ★ 绕 Z 转 90°：等距圆柱贴图的 UV 在两极会「收成一个点」（贴脸上看就是一个星芒状挤压）。
	#   把两极转到**左右两侧**，正视时那条挤压落到画面边缘，不再糊在视野正中。
	mi.rotation.z = PI * 0.5
	mi.visible = false          # 只在外层被隐藏时才露面
	add_child(mi)
	crust_mi = mi


## 经纬度 → 球面**局部**单位方向的**唯一实现**在 CityIndex.latlon_dir（那里有完整的「实测定标」说明），
## 这里只做转发 —— 同一个约定绝不写两份，免得将来只改了一处、两条线悄悄分叉。
static func latlon_dir(lat_deg: float, lon_deg: float) -> Vector3:
	return CityIndex.latlon_dir(lat_deg, lon_deg)


## 第 i 个城市**此刻的世界坐标**（2D 投影用）。
## ★ 第二十轮起**不再有逐城的 Node3D 锚点**（全量 4.5 万座，节点开销不可接受）⇒ 直接用**地表壳的变换**
##   把「局部方向 × 壳半径」转到世界空间：自转照样自动成立（自转本来就是给壳设 basis），
##   城市与贴图也仍然是**同一个 basis**，不会互相跑偏。
##   越界 / 壳还没建 → 退回球心（那个位置投影出来没意义，所以**调用方必须先判断 `city_index.total`**）。
func city_world_pos(i: int) -> Vector3:
	if city_index == null or i < 0 or i >= city_index.total:
		return global_position
	if body_mi == null or not is_instance_valid(body_mi):
		return global_position
	return body_mi.global_transform * (city_index.dirs[i] * _city_shell_r)


## 第 i 个城市的**世界空间外法线**（= 球心 → 城市）：用于「城市是否在地球朝向镜头那一面」的剔除。
func city_world_normal(i: int) -> Vector3:
	var d := city_world_pos(i) - global_position
	return d.normalized() if d.length_squared() > 1e-12 else Vector3.UP


func _parse_shells(rv: Variant, base_dir: String) -> Dictionary:
	var out := {}
	if not (rv is Dictionary):
		return out
	var src: Dictionary = rv
	var su: Variant = src.get("surface", {})
	if su is Dictionary:
		var s: Dictionary = su
		if not s.is_empty():
			s = s.duplicate()
			for k in ["texture_day", "texture_night", "texture_normal", "texture_spec", "texture_height",
					"texture_pop", "texture_climate", "texture_climate_code"]:
				s[k + "_path"] = WorldData.resolve_texture(base_dir, str(s.get(k, "")))
			out["surface"] = s
	var cu: Variant = src.get("cloud", {})
	if cu is Dictionary:
		var c: Dictionary = cu
		if not c.is_empty():
			c = c.duplicate()
			c["texture_path"] = WorldData.resolve_texture(base_dir, str(c.get("texture", "")))
			out["cloud"] = c
	# ★ 第二十八轮续：地壳（「地球表面 → 反地面」之间那层有厚度的填充）。
	#   它在地球外表被隐藏时才出现，所以单独一块、不进 shell_mis。
	var ru: Variant = src.get("crust", {})
	if ru is Dictionary:
		var r: Dictionary = ru
		if not r.is_empty():
			r = r.duplicate()
			r["texture_path"] = WorldData.resolve_texture(base_dir, str(r.get("texture", "")))
			out["crust"] = r
	return out


## 球体网格（半径 / 圆周段数 / 环数）。★ 多球壳用更高分段（96×48）—— 壳间只有 1.5% 半径的间隙，
## 分面偏差（≈ 0.0004R）必须远小于它，云壳才不会「陷进」地表壳造成穿帮。
func _make_sphere_mesh(r: float, radial: int, rings: int) -> SphereMesh:
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = radial
	sm.rings = rings
	return sm


## 取壳贴图（取不到 = 返回 null，shader 里的采样会退化成白/黑 —— 至少球还在）。
func _fetch_shell_tex(d: Dictionary, key: String) -> Texture2D:
	var p := str(d.get(key, ""))
	if p.is_empty():
		return null
	var t: Texture2D = TextureCache.fetch(p)
	if t == null:
		push_warning("[WorldNode] sid=%s 壳贴图取不到：%s" % [sid, p])
	return t


## 城市海拔**参考值**（米）：直接从地表壳的「海拔栅格」（等距圆柱 8 位灰度）取样。
## ★ 约定与 `CityIndex.latlon_dir` / shader 的 UV **完全一致**：
##   u = 0.5 + 经度/360（u=0.5 是格林尼治）、v = (90 − 纬度)/180（v=0 是北极）。
## ★ 不需要精确：栅格本身 ~9 km/px，返回值只作「这个城市大概在多高」的参考。
##   取不到栅格（没有 texture_height / 读图失败）→ 返回 NAN，UI 显示「—」。
func sample_elevation_m(lat_deg: float, lon_deg: float) -> float:
	_ensure_height_image()
	if _height_img == null:
		return NAN
	var w := _height_img.get_width()
	var h := _height_img.get_height()
	if w <= 0 or h <= 0:
		return NAN
	var u := fposmod(0.5 + lon_deg / 360.0, 1.0)
	var v := clampf((90.0 - lat_deg) / 180.0, 0.0, 1.0)
	# 经度取模（东西经 ±180 处环绕），纬度夹到首末行（极点没有「更北」的一行）
	var x := int(u * float(w)) % w
	var y := clampi(int(v * float(h - 1)), 0, h - 1)
	return _height_img.get_pixel(x, y).r * HEIGHT_MAX_M


## 城市「人口密度」参考值（人/km²）：直接从地表壳的人口密度栅格（8 位对数索引）取样。
## ★ 编码：v = log10(1+d)/log10(1+POP_MAX_DENSITY) ⇒ d = 10^(v·log10(1+上限))−1；
##   用对数是为了让 1 人/km² 的荒野与 3 万人/km² 的都市共用 8 位而不被压成一片 0。
## ★ 取 3×3 邻域**最大值**：4K 栅格一格 ≈ 9 km，城市点常落在公园 / 水面 / 河上
##   （东京皇居、纽约中央公园、上海黄浦江），只看中心像素会把大都市读成空城。
func sample_population_density(lat_deg: float, lon_deg: float) -> float:
	var img := _raster_image("texture_pop_path")
	if img == null:
		return NAN
	var v := _sample_raster_window(img, lat_deg, lon_deg, 1).r
	# ★ 反解用 (1+上限)^v：转换脚本的编码是 log10 比值，等价于以 10 为底；
	#   GDScript 的 log() 是自然对数，直接 v·log(上限) 会放大成几百倍（实测上海读出 6 亿人/km²）。
	return pow(1.0 + POP_MAX_DENSITY, v) - 1.0


## 城市「气候分类」类别码（1..31 陆地、32 = 海洋）；取不到栅格 → −1。
## 气候是块状分布，取中心像素即可（邻域最大会把城市边缘的沙漠读成草原）。
func sample_climate_code(lat_deg: float, lon_deg: float) -> int:
	var img := _raster_image("texture_climate_code_path")
	if img == null:
		return -1
	return int(roundf(_sample_raster_window(img, lat_deg, lon_deg, 0).r * 255.0))


## 类别码 → 中文名（未知码/取不到 → 「—」）。
func climate_display_name(code: int) -> String:
	if code < 0 or code >= CLIMATE_NAMES.size():
		return "—"
	return str(CLIMATE_NAMES[code])


## 按经纬度取栅格颜色：与海拔 / shader 同一套等距圆柱 UV 约定（u=0.5 是格林尼治、v=0 是北极）。
## `win > 0` 时在 (2·win+1)² 邻域内逐通道取最大值（经度环绕、纬度夹边界）。
func _sample_raster_window(img: Image, lat_deg: float, lon_deg: float, win: int) -> Color:
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		return Color(0.0, 0.0, 0.0, 0.0)
	var u := fposmod(0.5 + lon_deg / 360.0, 1.0)
	var v := clampf((90.0 - lat_deg) / 180.0, 0.0, 1.0)
	var x := int(u * float(w)) % w
	var y := clampi(int(v * float(h - 1)), 0, h - 1)
	if win <= 0:
		return img.get_pixel(x, y)
	var best := img.get_pixel(x, y)
	for dy in range(-win, win + 1):
		for dx in range(-win, win + 1):
			var c := img.get_pixel((x + dx + w) % w, clampi(y + dy, 0, h - 1))
			if c.r > best.r:
				best = c
	return best


## 懒加载一张栅格（键 = surface 里的贴图字段名，如 texture_pop_path）；失败只警告一次。
func _raster_image(key: String) -> Image:
	if _raster_imgs.has(key):
		return _raster_imgs[key]
	if bool(_raster_tried.get(key, false)):
		return null
	_raster_tried[key] = true
	var sv: Dictionary = shells.get("surface", {})
	var p := str(sv.get(key, ""))
	if p.is_empty():
		return null
	var img: Image = null
	if ResourceLoader.exists(p):
		var tex: Texture2D = load(p)
		if tex != null:
			img = tex.get_image()
	if img == null and FileAccess.file_exists(p):
		img = Image.load_from_file(p)
	if img == null:
		push_warning("[WorldNode] sid=%s 栅格读不到：%s" % [sid, p])
		return null
	if img.is_compressed():
		img.decompress()
	_raster_imgs[key] = img
	return img


func _ensure_height_image() -> void:
	if _height_img_tried:
		return
	_height_img_tried = true
	var sv: Dictionary = shells.get("surface", {})
	var p := str(sv.get("texture_height_path", ""))
	if p.is_empty():
		return
	var img: Image = null
	# ★ 优先走**导入后的纹理**（与 shader 用的同一份数据）；取不到图再直接读源文件。
	#   `get_image()` 对「非 VRAM 压缩」的导入纹理会返回解压后的 Image；万一仍是压缩图就再解压一次。
	if ResourceLoader.exists(p):
		var tex: Texture2D = load(p)
		if tex != null:
			img = tex.get_image()
	if img == null and FileAccess.file_exists(p):
		img = Image.load_from_file(p)
	if img == null:
		push_warning("[WorldNode] sid=%s 海拔栅格读不到：%s" % [sid, p])
		return
	if img.is_compressed():
		img.decompress()
	_height_img = img


## 写入「本节点 → 太阳」的世界空间方向（地表昼夜混合 / 海面镜面 / 云层向阳面都用它）。
## ★ 时机：建树后 + **每次公转 tick 之后**（见 WorldView.refresh_celestial）——
##   地球位置逐月变，方向必须跟着变；自转不改位置 ⇒ 不必重写。
func apply_sun_dir(dir: Vector3) -> void:
	if dir.length_squared() < 1e-12:
		return
	_sun_dir = dir.normalized()
	if surface_mat != null:
		surface_mat.set_shader_parameter("sun_dir", _sun_dir)
	if cloud_mat != null:
		cloud_mat.set_shader_parameter("sun_dir", _sun_dir)


## 云层壳的显示门（WorldView 逐帧带相机位置调）：**离得远才显示云**，贴近地表时淡出 ——
## 否则云会把地表细节糊掉。用线性 ramp 而非硬切（硬切在拉近 / 推远时画面会「啪」地闪一下）。
func update_shells(cam_pos: Vector3) -> void:
	if cloud_mi == null or not is_instance_valid(cloud_mi):
		return
	# ★ 外层被隐藏时（锚定在地心世界）不要再按距离把云层点亮 —— 否则它会在隐藏后又被改回 visible。
	if outer_hidden:
		cloud_mi.visible = false
		return
	var cv: Dictionary = shells.get("cloud", {})
	var d := cam_pos.distance_to(global_position)
	var near_r := float(cv.get("fade_in_ratio", CLOUD_FADE_IN_RATIO)) * radius
	var full_r := float(cv.get("fade_full_ratio", CLOUD_FADE_FULL_RATIO)) * radius
	var a := 1.0
	if d <= near_r:
		a = 0.0
	elif d < full_r:
		a = (d - near_r) / maxf(full_r - near_r, 1e-6)
	var show := a > 0.001
	cloud_mi.visible = show
	if show and cloud_mat != null:
		cloud_mat.set_shader_parameter("shell_alpha", a)


## 「地心世界」反地面（第二十八轮）：**凹面内壁**。
##   · 只画背面（cull_front）⇒ 从球内看，整片地面就是天空；从球外看，看到的是远侧内壁（剖面观感）。
##   · 无光照（unshaded）：地心太阳在球心，对每块内壁都是垂直入射，不存在方向性明暗。
##   · 分段数用与地表壳相同的 SHELL_RADIAL×SHELL_RINGS：贴脸时内壁跨度很大，太少会看出多边形边。
func _build_inner_surface_body() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Body"
	mi.mesh = _make_sphere_mesh(radius, SHELL_RADIAL, SHELL_RINGS)
	var mat := ShaderMaterial.new()
	mat.shader = INNER_GROUND_SHADER
	var tex: Texture2D = TextureCache.fetch(texture_path) if not texture_path.is_empty() else null
	if tex == null:
		push_warning("[WorldNode] sid=%s 内壁贴图取不到：%s" % [sid, texture_path])
	mat.set_shader_parameter("tex_ground", tex)
	mat.set_shader_parameter("tint", color)
	mat.set_shader_parameter("radius", radius)
	mi.material_override = mat
	add_child(mi)
	body_mi = mi
	shell_mis.append(mi)


## 隐藏 / 恢复本节点的**外层**（地表壳 + 云层 + 内壁）。由 WorldView 在「锚定到某个
## `interior_of` 指向自己的节点」时调用 —— 不隐藏的话，地球的亮面会把地心世界整个挡住。
## ★ 只动 mesh 的 visible，不动本节点的 visible（级别过滤仍由 set_max_visible_level 管）。
func set_outer_hidden(on: bool) -> void:
	if outer_hidden == on:
		return
	outer_hidden = on
	for m in shell_mis:
		if m != null and is_instance_valid(m):
			m.visible = not on
	# ★ 无壳的节点（地心太阳这类单球体）：body_mi 不在 shell_mis 里，必须单独管
	#   （`hide_when_anchored` 正是靠本函数把地心太阳藏起来）。
	if body_mi != null and is_instance_valid(body_mi) and not shell_mis.has(body_mi):
		body_mi.visible = not on
	# ★ 地壳填充与外层**正好相反**：外层藏起来（人在里面）时它才露面，把「地面 → 反地面」
	#   之间填出厚度；回到外面看地球时它必须消失，否则会挡住真正的地表。
	if crust_mi != null and is_instance_valid(crust_mi):
		crust_mi.visible = on


## 近景细节的逐帧更新（第二十六轮瓦片 + 第二十七轮地势起伏）。由 WorldView 每帧带相机世界坐标调用
## （与 update_shells 搭同一趟逐节点遍历，零额外遍历开销）。
## ★ 本方法把相机换算到**本节点局部系**（球心为原点、边长单位 = 世界单位）后交给地球瓦片层；
##   只有带 `tile_surface` 的节点（地球）真正干活，其余节点只做一次距离判断。
func update_tile_detail(cam_world: Vector3) -> void:
	if body_mi == null or not is_instance_valid(body_mi):
		return
	# ★ 外层被隐藏时（镜头在地心世界里）不必再解码瓦片 / 更新地形权重。
	if outer_hidden:
		return
	var shell_r := _city_shell_r if _city_shell_r > 0.0 else radius
	var lp := body_mi.global_transform.affine_inverse() * cam_world
	# ★ 第二十七轮：地势起伏的**近景权重**（按相机距 ÷ 半径）。1.35R 及以内全开、2.6R 以外完全关：
	#   再远时可见地面跨度太大（上千 km），海拔栅格（~9 km/px）的坡度已经读不出单个山脊，
	#   只会给整片大陆添一层脏阴影 ⇒ 交给 8K 贴图自带的明暗即可。
	if surface_mat != null:
		var ratio := lp.length() / maxf(shell_r, 1e-6)
		surface_mat.set_shader_parameter("height_blend",
			1.0 - smoothstep(1.35, 2.6, ratio))
	if _tile_layer == null:
		return
	_tile_layer.update_detail(lp, shell_r)


## ★ 用 NOTIFICATION_PREDELETE（真正删除时才触发）而**不是 _exit_tree()**：
##   `WorldData.build_tree` 建完节点后会按 parent **重挂**（`remove_child` + `add_child`），
##   `remove_child` 会触发 `_exit_tree()` —— 若在那里释放瓦片层，建树阶段就会把它清掉，
##   结果「瓦片层永远为 null、近景永远糊」（第二十六轮踩到的大坑）。
##   这里只在对象真被删除前把解码线程任务**等完**，避免退出时 WorkerThreadPool 泄漏报错。
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _tile_layer != null:
		_tile_layer.release()
		_tile_layer = null


## 星环（如土星环）：把**横向条带环贴图**（u = 环内缘 → 环外缘）铺在一个**扁平圆环**网格上。
##   · 圆环是自建的 ArrayMesh 环（Godot 没有内置 annulus）：内外圈各一圈顶点，TRIANGLE_STRIP。
##   · 材质 = **无光照**（环是薄片，放心让它按贴图原色显示）+ **双面（CULL_DISABLED）**
##     + **ALPHA 混合**（贴图带透明通道 ⇒ 环缝自然透过去）。
##   · 环平面绕 X 轴倾斜 `equatorial_tilt_deg`（= 行星赤道面相对参考面的倾角；真实土星 26.73°）
##     —— 与赤道卫星的轨道面**同一个来源**，所以环必然和土卫一…土卫六这些卫星共面。
func _build_ring() -> void:
	if ring.is_empty():
		return
	var inner := maxf(float(ring.get("inner_ratio", 1.15)) * radius, radius * 0.01)
	var outer := maxf(float(ring.get("outer_ratio", 2.35)) * radius, inner * 1.01)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if not ring_texture_path.is_empty():
		var tex: Texture2D = TextureCache.fetch(ring_texture_path)
		if tex != null:
			mat.albedo_texture = tex
		else:
			push_warning("[WorldNode] sid=%s 星环贴图取不到：%s" % [sid, ring_texture_path])

	var mi := MeshInstance3D.new()
	mi.name = "Ring"
	mi.mesh = _make_annulus(inner, outer, RING_SEGMENTS)
	mi.material_override = mat
	# 环平面默认躺在 XZ 平面（法线 +Y）→ 绕 X 轴倾斜「赤道面倾角」，让它落在**行星赤道面**里
	# （= 土星环真实的位置：与赤道卫星的轨道面共面）。
	mi.rotation_degrees = Vector3(equatorial_tilt_deg, 0.0, 0.0)
	add_child(mi)


## 扁平圆环网格（内半径 inner → 外半径 outer）：UV 的 u 沿半径方向 0→1（对齐条带环贴图），
## v 沿圆周方向（只用来让贴图不出现整条拉伸）。首尾各多一圈顶点以「缝合」缺口。
func _make_annulus(inner: float, outer: float, segments: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in range(segments + 1):
		var t := float(i) / float(segments)
		var a := t * TAU
		var dir := Vector3(cos(a), 0.0, sin(a))
		st.set_uv(Vector2(0.0, t))
		st.set_normal(Vector3.UP)
		st.add_vertex(dir * inner)
		st.set_uv(Vector2(1.0, t))
		st.set_normal(Vector3.UP)
		st.add_vertex(dir * outer)
	return st.commit()

## 轨道平面 → 父节点局部坐标系的基变换：
##   ① 先绕 X 轴（= 升交点方向的起点）倾斜 orbit_incline_deg ⇒ 轨道离开父节点的 XZ 平面；
##   ② 再绕参考面法线（Y 轴）转 orbit_node_deg ⇒ 决定「往哪边倾」（升交点经度）。
## ★ 逆行轨道（如土卫九 175.2°、海卫一 156.9°）靠倾角 > 90° 表达，无需额外字段。
## ★★ 父节点若给了「赤道面倾角」（土星 26.73°，见 equatorial_tilt_deg）：**整个卫星系统**先一起绕 X 轴
##    倾斜 —— 赤道卫星（土卫一…土卫六、以及环缝里的牧羊星）本来就在赤道面里跑，而赤道面相对参考面是斜的。
##    不这么做的话，星环（横在赤道面里）与卫星（共面在参考面里）就是两块错开的板子。
func orbit_basis() -> Basis:
	var b := Basis(Vector3.UP, deg_to_rad(orbit_node_deg)) * Basis(Vector3.RIGHT, deg_to_rad(orbit_incline_deg))
	if parent_node != null and not is_zero_approx(parent_node.equatorial_tilt_deg):
		b = Basis(Vector3.RIGHT, deg_to_rad(parent_node.equatorial_tilt_deg)) * b
	return b


## 轨道上的一个点（**父节点局部坐标**）：a_deg = 相位角（°）。
## ★ place_orbit() 与 build_trail() 必须共用本函数 —— 否则星体与尾迹会分处两个平面（第八轮踩过的坑）。
func orbit_point(a_deg: float) -> Vector3:
	var a := deg_to_rad(a_deg)
	return orbit_basis() * Vector3(cos(a) * orbit_radius, 0.0, sin(a) * orbit_radius)


## 按**当前**相位角摆位（倾角 ≠ 0 时轨道面不再与父节点轨道面共面）。
## ★ 世界位置由 WorldTime 按现实时间 tick **一次性跳**（见 set_orbit_angle），本函数只负责「按角度摆」。
func place_orbit() -> void:
	position = orbit_point(orbit_angle_deg)


## 有效轨道周期（小时，带符号；0 = 不动）。供 WorldTime 读。
##   · 显式给了 `orbit_period_h` → 直接用它（★ 卫星**必须**显式给：绕太阳的开普勒公式对卫星是错的，
##     月球会被算成 ~1 小时）；
##   · 日心天体（父节点是太阳 / 小行星带）省略时 → 由 `props.orbit_au` 按开普勒第三定律推：
##     P = 365.25 × 24 × a_AU^1.5（行星误差 < 0.5%，够用）。
func effective_orbit_period_h() -> float:
	if not is_zero_approx(orbit_period_h):
		return orbit_period_h
	var p := parent_node
	if p == null:
		return 0.0
	var helio := p.level == 0 or p.template == WorldTemplates.T_BELT
	if not helio:
		return 0.0                              # 卫星省略周期 ⇒ 不动（避免用错公式）
	var a := float(props.get("orbit_au", 0.0))
	if a <= 0.0:
		return 0.0
	return 365.25 * 24.0 * pow(a, 1.5)


## 把公转相位角跳到 a（°），并按新角度重摆位置、**重建尾迹**。
## ★ 尾迹是按角度建的死网格 —— 星体一动就必须重建，否则尾迹会与本体错位（第八轮踩过的坑）。
func set_orbit_angle(a: float) -> void:
	orbit_angle_deg = fposmod(a, 360.0)
	place_orbit()
	rebuild_trail()


## 尾迹是按角度建的死网格 ⇒ 公转一更新就必须重建（先 free 旧的，再按新角度建）。
func rebuild_trail() -> void:
	if trail != null and is_instance_valid(trail):
		var c := trail.get_parent()
		if c != null:
			c.remove_child(trail)
		trail.queue_free()
		trail = null
	build_trail()


## 自转：绕**本节点赤道轴**转 Body 网格（★ 不能转本节点本身 —— 那会把卫星与星环一起带着转）。
## 赤道轴 = Y 轴按 `equatorial_tilt_deg` 倾斜（与星环 / 赤道卫星的参考面同一来源），
## 这样土星的球面自转轴与它的环面是**同一个朝向**，不会出现「球在竖着转、环横躺着」的割裂。
func set_spin_deg(deg: float) -> void:
	if body_mi == null or not is_instance_valid(body_mi):
		return
	var axis := Vector3.UP
	if not is_zero_approx(equatorial_tilt_deg):
		axis = Basis(Vector3.RIGHT, deg_to_rad(equatorial_tilt_deg)) * Vector3.UP
	var b := Basis(axis, deg_to_rad(deg))
	# ★ 多球壳（地球）：地表壳与云层壳**同一轴、同一角**一起转 ⇒ 云不会与地表错开；
	#   两壳同心，转多少都不会互相「陷进去」。
	if shell_mis.is_empty():
		body_mi.basis = b
	else:
		for m in shell_mis:
			if m != null and is_instance_valid(m):
				m.basis = b


## 尾迹（替代原来的整圈「轨道线」）：只画行星**身后**一段的渐隐弧线。
##   · 公转方向 = 相位角**增大**方向 ⇒ 尾迹覆盖 [orbit_angle_deg - TRAIL_SPAN_DEG, orbit_angle_deg]，
##     行星当前位置就是弧的**终点**；公转方向的前方（"未来的轨道处"）不画任何东西。
##   · 弧挂在**父节点**下 ⇒ 圆心 = 公转中心，且与行星处在**同一个局部坐标系**，
##     弧终点 = 行星位置 —— 天然「从星球上出发」，不会再出现星球与轨道错位。
##   · 弧与星体共用 orbit_point() ⇒ 倾角（不共面轨道）同样成立。
##   · 透明度：行星端不透明，越远离行星越透明（顶点色 alpha 沿弧长 1 → 0 线性渐隐）。
##   · 不追求圆润（TRAIL_SEGMENTS 只取 48 段）。
func build_trail() -> void:
	if orbit_radius <= 0.0:
		return
	var center: Node = parent_node if parent_node != null else get_parent()
	if center == null:
		return

	var span := TRAIL_SPAN_DEG                           # 尾迹跨度（°）
	# ★ 尾迹永远画在**身后**：相位角增大（周期 > 0）⇒ 身后是 [angle−span, angle]；
	#   周期 < 0（自转 / 轨道逆行取负）⇒ 相位角在减小，身后是 [angle, angle+span]。
	var dir := -1.0 if effective_orbit_period_h() < 0.0 else 1.0
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(TRAIL_SEGMENTS + 1):
		var t := float(i) / float(TRAIL_SEGMENTS)  # t：0 = 最远端（最透明）→ 1 = 行星端（不透明）
		var a := orbit_angle_deg - dir * span * (1.0 - t)
		im.surface_set_color(Color(color.r, color.g, color.b, t))
		im.surface_add_vertex(orbit_point(a))
	im.surface_end()

	var mi := MeshInstance3D.new()
	mi.name = "Trail_" + sid
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color.WHITE                 # 颜色（含 alpha 渐变）全部来自顶点色
	mi.material_override = mat
	mi.mesh = im
	center.add_child(mi)
	trail = mi
