# the words/world_view.gd
# 「世界」3D 视图（挂在 SubViewport 下）：建世界环境 / 唯一相机 / 世界节点树，
# 并负责 ① 级别过滤（仅观察 0~N 级）② 镜头锚定与切换（锚定后 = **卫星视角**：相机始终对准该星体，
# 只绕它转、滚轮只改距离，可贴到球面外 0.35×半径 处而不穿模；松手惯性随放大倍数递减）
# ③ **抓取拖动**：按住处跟着光标走（"鼠标按住的地方不变"）；抓取点被拖到星体轮廓之外时
#   退回按像素速率的旋转（维持操作惯性，不跳南北极）；松开时按残余速度**继续滑一会儿**（惯性）
# ④ 自由平移 / 滚轮缩放 ⑤ 星体拾取。
#
# ★ 世界根 = 本节点（Node3D）：太阳是它的子节点，行星又是太阳的子节点
#   ⇒ 场景树父子 = 世界归属（决策 3）。
# ★ 星体位置 / 朝向由 WorldTime 按**现实时间 tick**驱动（第十六轮）：行星每月 1 号、卫星每月 2/12/22 号
#   **一次性跳**到新位置，自转每小时更新一次；tick 之间冻结 ⇒ 场景基本静态（不做逐帧轨道动画）。
#   JSON 里的 orbit_angle_deg 是 **epoch 时刻**的初始相位，重算基准见 world_time.gd。
class_name WorldView
extends Node3D

## 节点树建好（世界页面据此生成左侧「世界节点」列表）。
signal tree_built(nodes: Array)
## 镜头锚定目标变化（空串 = 解除锚定）。
signal anchor_changed(sid: String)

const CAM_FOLLOW_RATE := 6.0        # 镜头跟随速率（每秒；指数插值，帧率无关）
const ZOOM_STEP := 1.15             # 每格滚轮的拉近/推远倍率（远距离）
## ★ 第二十八轮续 5：贴地时 1.15/格太大 —— 1.16R 一格就 clamp 到最近 1.01R，观感是「一下就贴脸」。
##   视距进入 [最近, WHEEL_FINE_RATIO × 半径] 后，倍率平滑过渡到 WHEEL_FINE_STEP：
##   越近越细（1.16R 附近每格约 3%），从 1.16R 走到 1.01R 需要 5~6 格。
const WHEEL_FINE_RATIO := 1.50
const WHEEL_FINE_STEP := 1.02
## ★ 以下尺度相关的量**全部由数据推**：世界改成真实比例后尺寸到「十万单位」级，
##   写死的绝对数值（最近可贴距离、最远距离、近远裁剪面、拾取射线长）全会失效。
## ★ 第二十轮把最近距离从 1.35 拉到 **1.08**（球面外 0.08R ≈ 510 km）：用户要求「**最近距离时要有
##   从天上观察地面的感觉**」。1.35 时屏幕上的可见地表约跨 12°（能看见整颗球 + 明显的地平曲率），
##   观感仍是「在看一颗球」；1.08 时可见地表只剩 ~5°、**地平线完全出画、地面铺满画面**，就是俯视取景。
## ★ 第二十六轮再拉到 **1.02**；第二十八轮续 3 再压到 **1.01**（球面外 0.01R ≈ 64 km）：
##   配合近景瓦片高清补丁（earth_tile_layer.gd）能贴到地面更近处看细节。
## ★ 安全边界（必须成对改）：near 面 = `_dist × CAM_NEAR_RATIO(0.005)`
##   ⇒ 1.01 时 = 0.00505R ≈ 32 km，而脚下地面在 0.01R ≈ 64 km ⇒ **不会被近裁剪面切掉**；
##   （旧值是 MIN 1.02 + NEAR 0.01：near=0.0102R 刚好越过 0.02R 下方的地面，1.01 会切地面）
##   云壳 fade_in_ratio = 3.0 ⇒ 3R 内已淡出，贴脸时不会糊住画面；球面分面 256×128（每段 ~1.4°）
##   在 1.01R 下仍远小于 1px，不会露多边形棱边。
const MIN_DIST_RATIO := 1.01        # 卫星视角：相机距星体**球心**的最小距离 = 半径 × 该值（球面外 0.01R，不穿模）
## ★ 第二十八轮续 5：凹面内壁（反地面）的**可见面是远侧内壁** —— 站在球外只能隔着（被
##   cull_front 剔除的）近侧壁看对面，视线到可见面的距离 = (d + R)。所以 1.005R 时远侧壁仍在
##   2.005R 之外，再往里滚几乎没有「变近」的观感。
##   ⇒ 允许相机**进入内壁球内**：0.05R（距球心 5% 半径）时正前方内壁 = 1.05R，与普通星体
##     贴地（1.01R）的手感相当，能真正凑近看内壁细节。
##   ★ 不能再低：远裁剪面 = 视距 × CAM_FAR_RATIO(60)，d < R/59 时远侧内壁会越过远裁剪面被切掉。
const INNER_MIN_DIST_RATIO := 0.05
## 右下角竖直视距条的分段（第二十八轮续 4，全部 × 锚定星体半径）：
##   [最近, 1.10R] 占滑条**上半截**（顶端最近），[1.10R, 7R] 占**下半截**；7R 以外只用滚轮。
## ★ 为什么是这两段：2.05R 已能完整显示地球，7R 包住地球静止轨道（轨道高度约 6.6R）；
##   而贴地看细节时 1.01R~1.10R 的每一小段都值得一个像素 —— 线性分段比全范围对数更符合直觉。
const SLIDER_MID_RATIO := 1.10
const SLIDER_FAR_RATIO := 7.0
## 锚定反地面时的**默认**视距（× 该半径）：普通星体是 12R（先看全貌），但反地面是一整片
## 铺满视野的内壁 —— 2.3R 时它在屏幕上只占一小块，要滚很久才「进入地心世界」。
## ★ 1.3R 时其角半径 asin(1/1.3) ≈ 50.3°，大于 16:9 窗口的**对角**半视场（≈49.7°）
##   ⇒ 一锚定就让内壁连四角一起铺满屏幕，不会在边缘露出一圈地壳纯色。
const INNER_ANCHOR_DIST_RATIO := 1.3
const ZOOM_OUT_RATIO := 1.6         # 最远距离 = 全景视距 × 该值（要能一眼看到冥王星轨道）
const RAY_LEN_RATIO := 8.0          # 拾取射线长 = 最远距离 × 该值（要能横跨整个太阳系）
const CAM_NEAR_RATIO := 0.005       # 近裁剪面 = 当前视距 × 该值（随视距动态；1.01R 贴地时 near≈0.005R < 地面距 0.01R）
const CAM_FAR_RATIO := 60.0         # 远裁剪面 = 当前视距 × 该值
const ANCHOR_APPROACH_RATIO := 12.0 # 锚定时距离若远超过「半径 × 该值」→ 直接拉近到该值（真实比例下光靠滚轮要点上百次）
const ANCHOR_FLY_DURATION := 1.0    # 锚定切换「由远及近」飞入时长（秒）
const ANCHOR_FLY_START_MULT := 30.0 # 飞入起点距离 = 目标距离 × 该倍数（上限；起点更远 = 更慢更晕）
## 飞入起点距离的**下限** = 新目标直径 × 该倍数（第十六轮新增）。
## ★ 原来起点 = clamp(当前距离, 目标, 目标×30)；而「当前距离」可能已经**很接近目标**
##   （例如刚看过一颗大小差不多的星体）⇒ 几乎没有「由远及近」的效果。
##   现在起点钉在「新目标直径的固定倍率」处，每次切换都看得见镜头从远处收进来
##   （起点可以比当前距离更远 ⇒ 先微微推远、再拉近，这正是用户要的效果）。
const ANCHOR_FLY_START_DIAM_MULT := 30.0
const PIXEL_SENS_MIN_DEG := 0.0005  # 「1px = 多少度」的下限（贴到极近时不再继续变小）
const ORBIT_SENS_DEG := 0.35        # **没抓到实体**时的「1px = 多少度」上限（拖动太空 → 保持旧手感）
## ★ 第二十轮续新增：**抓到实体**时的上限倍率（× 盘心 1:1 速率）。
##   为什么要跟上面分开：用户要求「鼠标移动多少、地图就滚动多少」，而 1:1 速率在中远景会**大于** 0.35
##   （6R 时 0.50、12R 时 1.11）⇒ 被 0.35 砍掉 30%~68%，表现正是「鼠标比地图滚得多」。
##   ★ 但也不能不封顶：抓取点越靠近**地平线**，1:1 速率越大（那里每度只带动很少像素）——
##   封顶太松（如 8°/px）会让一次快速拖动把画面**甩飞**（实测 2.5R 边缘处 100px 直接反向 42px）。
##   所以封顶取「盘心速率 × 该倍率」，既保证盘面中央严格 1:1、又给地平线附近留了合理上限。
const GRAB_SENS_MAX_MUL := 2.0
## ★ 第二十八轮续 6：牛顿解的单帧转角上限倍率（× 1:1 速率 × 像素位移）。
##   超出 ⇒ 抓取点已滑到球的边缘（屏幕位移对转角非线性），此时硬解会把镜头甩向极点；
##   改为回滚并转入**锁定像素速率**模式（每像素角度恒定），保证速度不飙升。
const GRAB_ANGLE_SLACK := 2.5
const INERTIA_DAMP_MIN := 0.02      # 松手惯性的最小阻尼（贴到极近时惯性缩到基准的 2%）
const TRAIL_HIDE_RATIO := 3.0       # 相机到行星的距离 < 半径 × 该值 → 隐藏该行星的尾迹（贴脸看星体时尾迹会糊住画面）
const ORBIT_ELEV_MIN := -80.0       # 卫星视角仰角下限（度）
const ORBIT_ELEV_MAX := 85.0        # 卫星视角仰角上限（度）
const CAM_AZIM_DEG := 90.0          # 初始方位角
const CAM_ELEV_DEG := 33.5          # 初始仰角（与原来的固定斜俯视等价）

var nodes: Array[WorldNode] = []     # 世界全部节点（JSON 顺序）
var world_name: String = "世界"
var max_visible_level: int = 1       # 仅观察 0~N 级（默认 1 = 太阳 + 行星）
var default_max_visible_level: int = 1
## 视图模式：0 = 俯瞰视图（默认）/ 1 = 时区视图 / 2 = 人口密度 / 3 = 气候分布。
var view_mode: int = 0

var _data: Dictionary = {}
var _by_sid: Dictionary = {}
var _camera: Camera3D = null
## 批量投影的缓存（见 prepare_projection / project_point_fast）：每帧开头刷一次
var _proj_inv: Basis = Basis()
var _proj_pos: Vector3 = Vector3.ZERO
var _proj_focal: float = 0.0
var _proj_half: Vector2 = Vector2.ZERO
var _sun_light: OmniLight3D = null       # 太阳光源（世界根原点，attenuation=0；见 _build_environment）
var _cam_pivot: Node3D = null            # 相机枢轴：恒钉在全局原点，见 setup / _process 的注释
var _focus: Vector3 = Vector3.ZERO       # 实际注视点（平滑跟随锚定目标）
var _free_focus: Vector3 = Vector3.ZERO  # 自由平移时的注视点
var _dist: float = 1600.0
var _default_dist: float = 1600.0        # 全景视距（能装下整个太阳系；由数据算，setup 里定）
var _zoom_max: float = 2560.0            # 最远距离（= 全景视距 × ZOOM_OUT_RATIO）
var _anchor_sid: String = ""
var _cam_snap: bool = true               # 下一次更新直接吸附（换锚定 / 弱化首帧"飞入"）
var _azimuth_deg: float = CAM_AZIM_DEG   # 相机绕注视点的方位角（自由/卫星视角共用）
var _elevation_deg: float = CAM_ELEV_DEG # 相机仰角
## ★ 锚定切换的「由远及近」飞入（第十五轮）：注视点**立刻吸附**到新星体，只有**距离**从远处收进来。
##   _fly_active 期间 _process 每帧按 ease-out 把 _dist 从 _fly_from 推到 _fly_to；滚轮/拖动/解锚/隐藏页面都会打断。
var _fly_active: bool = false
var _fly_t: float = 0.0                  # 飞入进度 0~1
var _fly_from: float = 0.0               # 飞入起点距离
var _fly_to: float = 0.0                 # 飞入目标距离
## 「反转滚轮」：滚轮上下方向对调（由设置页·世界页写入，见 WorldPage._read_invert_wheel）
var invert_wheel: bool = false
## 「反转鼠标」：拖动方向对调（默认 = 已按用户反馈翻转；打开此开关 = 回到旧的拖动方向）
var invert_mouse: bool = false


## 建世界：环境 + 相机 + 节点树 + 相机初始机位。
func setup(json_path: String = WorldData.DEFAULT_JSON) -> void:
	_data = WorldData.load_data(json_path)
	world_name = str(_data.get("name", "世界"))
	_build_environment()

	_camera = Camera3D.new()
	_camera.name = "WorldCamera"
	_camera.fov = 60.0
	# near/far 不在这里写死：真实比例下它们必须**随视距**变（见 _update_camera 末尾），
	# 写死的绝对面值会在贴脸看小星体 / 远景看全太阳系时分别失效。
	# ★★ 相机不能直接挂在本节点（世界根）下 ★★
	#   浮动原点（_process 里 position -= 锚点全局坐标）会把世界根整体平移到 -92.7 万
	#   （冥王星轨道），相机若挂在它下面，**局部坐标**就被撑到同一量级 →
	#   单精度在 9.3e5 处的量化步长 ≈ 0.0625，而卫星视角拖动 1px 的期望位移只有 ≈ 0.0137
	#   →「拖好几个像素才跳一格」的一顿一顿（滚轮贴到近处同理）。
	#   ⇒ 中间加一层**相机枢轴**：枢轴局部坐标 = 世界根坐标的相反数（两者精确抵消 ⇒ 枢轴恒在
	#     全局原点），相机挂在枢轴下 ⇒ 相机局部坐标 = 全局坐标 ≈ 个位数，全程精确。
	#   （枢轴在 world_view 内部 add_child，不像挂视口那样会撞上「父节点正在装配子节点」）
	_cam_pivot = Node3D.new()
	_cam_pivot.name = "CamPivot"
	add_child(_cam_pivot)
	_cam_pivot.add_child(_camera)

	nodes = WorldData.build_tree(self, _data)
	for n in nodes:
		_by_sid[n.sid] = n

	default_max_visible_level = clampi(int(_data.get("max_visible_level", 1)), 0, 99)
	max_visible_level = default_max_visible_level
	_dist = _default_distance()
	_default_dist = _dist
	_zoom_max = maxf(_default_dist * ZOOM_OUT_RATIO, 1.0)
	_dist = _default_dist
	_free_focus = _root_focus()
	_focus = _free_focus
	_cam_snap = true
	_apply_max_visible_level()

	# ★ 太阳灯的范围 = 最远轨道 × 2（要盖住整个太阳系；★ 范围外的片元光会掉 0 ⇒ 必须够大）。
	if _sun_light != null:
		_sun_light.omni_range = maxf(_farthest_orbit() * 2.0, 1000.0)

	# ★ 建世界时立刻按现实时间 tick 一次（玩家离线期间该更新的会一次补齐 —— 防穿帮，见 WorldTime）。
	refresh_celestial()
	_update_camera()
	_update_trails()

	tree_built.emit(nodes)
	print("[WorldView] 世界已建：%s 节点=%d 相机距离=%.0f（最远=%.0f）可见级别=0~%d"
		% [world_name, nodes.size(), _dist, _zoom_max, max_visible_level])


# ---------------- 镜头 ----------------

func _process(delta: float) -> void:
	if _camera == null:
		return
	_step_inertia(delta)
	# ★ 浮动原点：锚定某星体时把世界根平移成「锚点 = 原点」。
	#   真实比例下「冥王星轨道 ≈ 92.7 万单位」而「地球半径 = 1 单位」，Godot 用单精度渲染，
	#   大坐标处的小物体顶点会被量化糊掉（要贴脸看的锚点星体正是这类）→ 把相机附近的坐标压到
	#   小数值上；远处那些大家伙被量化也看不出来。position -= anchor.global_position 是幂等的
	#   （已归零时再减 0 不变）。
	if not _anchor_sid.is_empty():
		var a0 := node_by_sid(_anchor_sid)
		if a0 != null:
			position -= a0.global_position
	# ★ 相机枢轴恒钉在**全局原点**：局部坐标 = 世界根坐标的相反数（两者精确抵消 → 枢轴全局 = 0），
	#   相机是它的子节点 ⇒ 相机局部坐标 = 全局坐标 ≈ 个位数。若省掉这层，相机就得把「世界根那
	#   92.7 万的位移」扛进自己的局部坐标里，单精度的 0.0625 量化会把 1px≈0.0137 的拖动变成
	#   「几像素才跳一格」的一顿一顿。
	_cam_pivot.position = -global_position
	var target := _free_focus
	if not _anchor_sid.is_empty():
		var a := node_by_sid(_anchor_sid)
		if a != null:
			target = a.global_position
		else:
			_anchor_sid = ""
			anchor_changed.emit("")
	if _cam_snap:
		_focus = target
		_cam_snap = false
	else:
		_focus = _focus.lerp(target, 1.0 - exp(-CAM_FOLLOW_RATE * delta))
	# ★ 锚定切换的「由远及近」飞入（第十五轮）：注视点已经吸附到新星体（上面 _cam_snap 那段），
	#   这里只把**距离**从远处收到目标 —— 于是画面上就是「星体先很小、随后被镜头拉近到占屏」。
	if _fly_active:
		_fly_t += delta / maxf(ANCHOR_FLY_DURATION, 0.01)
		if _fly_t >= 1.0:
			_fly_t = 1.0
			_fly_active = false
			_dist = _fly_to
		else:
			# ease-out 立方：起步快、末段减速 ⇒ 落点稳、不会"冲过头再回弹"
			_dist = lerpf(_fly_from, _fly_to, 1.0 - pow(1.0 - _fly_t, 3.0))
	_update_camera()
	_update_trails()


## 松手惯性：按残余速度继续旋转/平移，并逐帧衰减 → 快速大范围甩动后镜头还会自己滑一会。
func _step_inertia(delta: float) -> void:
	if _inertia_vel == Vector2.ZERO:
		return
	# ★ 若本轮拖动早已转入「每像素恒定角度」模式，惯性也沿用同一锁定速率 —— 否则惯性
	#   会按**当前**几何重新算速率，接在锁定速率后面造成速度突变（表现为松手一瞬被甩一下）。
	_apply_drag_px(_inertia_vel * delta * 60.0, _grab_free_dpp if _grab_free else -1.0)
	_inertia_vel *= pow(INERTIA_DECAY, delta * 60.0)
	if _inertia_vel.length() < INERTIA_STOP_PX:
		_inertia_vel = Vector2.ZERO


## 锚定到某个星体（sid 空 = 解除）。锚定后镜头 look_at 它并平滑跟随。
func set_camera_anchor_sid(sid: String) -> void:
	if sid.is_empty():
		clear_camera_anchor()
		return
	var a := node_by_sid(sid)
	if a == null:
		push_warning("[WorldView] 锚定失败：没有 sid=%s 的世界节点" % sid)
		return
	_anchor_sid = sid
	_cam_snap = true
	# ★ 真实比例下「全景视距 ≈ 百万单位」而「一颗行星的半径 ≈ 1 单位」，光靠滚轮从全景贴到
	#   行星要滚上百次 → 锚定时若当前距离远超过该星体的舒适视距（半径 × ANCHOR_APPROACH_RATIO）
	#   就收到舒适视距；只拉近不推远（本来就更近的话不动）。
	# ★ 凹面内壁（反地面）不是「一颗要绕着看的球」，而是一整片铺满视野的地面 ——
	#   若沿用 12R 的舒适视距，锚定后它只是屏幕中央的一小块，还得手动滚很多格。
	#   所以给它一个更近的默认距离（1.6R，内壁刚好铺满屏幕），并且**允许从当前更远处飞进来**。
	var comfort := a.radius * (INNER_ANCHOR_DIST_RATIO if a.inner_surface else ANCHOR_APPROACH_RATIO)
	var target := clampf(minf(_dist, comfort), _min_distance(), _zoom_max)
	_cancel_fly()
	if _dist > target * 1.15:
		# ★ 第十五轮「由远及近」：本来这里是一步硬切到 target（全景视距下画面直接从"空星空"变"贴脸"），
		#   现在改成播一段飞入 —— 起点 = 当前距离，但**封顶在「目标 × ANCHOR_FLY_START_MULT」**
		#   （全景视距是百万级，不封顶的话飞入时长会随起点距离失控）；
		#   只在「要拉近」时播（要推远时照旧瞬移，与上面的「只拉近不推远」一致）。
		_fly_active = true
		_fly_t = 0.0
		# ★ 起点下限 = 新目标直径 × 该倍数（与当前距离无关，第十六轮改）：即使当前距离已经很接近
		#   目标，也能看到「由远及近」；上限仍是 target × ANCHOR_FLY_START_MULT（防全景视距下时长失控）。
		_fly_from = clampf(_dist, a.radius * 2.0 * ANCHOR_FLY_START_DIAM_MULT, target * ANCHOR_FLY_START_MULT)
		_fly_to = target
		_dist = _fly_from
	else:
		_dist = target
	_apply_interior_visibility()
	anchor_changed.emit(sid)
	print("[WorldView] 镜头锚定 → %s（半径=%.1f 最近可贴距离=%.1f 当前距离=%.1f%s）"
		% [sid, a.radius, _min_distance(), _dist, " 飞入中→%.1f" % _fly_to if _fly_active else ""])


## 解除锚定：回到自由视角（注视点从当前位置继续，不跳）。
func clear_camera_anchor() -> void:
	_cancel_fly()
	if _anchor_sid.is_empty():
		return
	_anchor_sid = ""
	_free_focus = _focus
	_cam_snap = false
	_apply_interior_visibility()
	anchor_changed.emit("")
	print("[WorldView] 镜头锚定已解除")


## ★ 掐掉「由远及近」飞入（第十五轮）：滚轮 / 按住拖动 / 解锚 / 页面隐藏都会调它。
##   飞入只是"入场演出"，用户一动手就必须立刻交还控制权（不然滚轮会被动画压着走）。
func _cancel_fly() -> void:
	_fly_active = false


func get_camera_anchor_sid() -> String:
	return _anchor_sid


func node_by_sid(sid: String) -> WorldNode:
	return _by_sid.get(sid, null)


## 「地心世界」的外表隐藏（第二十八轮）：锚定到某个节点时，若它声明了 `interior_of = <宿主 sid>`，
## 就隐藏那个宿主的**外层**（地表壳 / 云层 / 内壁），把里面的世界露出来；解锚 / 锚到别处时恢复。
## ★ 同时处理 `hide_when_anchored` 列出的节点（锚定反地面时把地心太阳一起藏起来）——
##   它们同样只是「本帧不该被看见」，用同一套 `set_outer_hidden` 切换可见性即可。
## ★ 数据驱动：shader/引擎里不写死 "earth" 这个字符串 —— 将来别的星球也能有「内部世界」。
func _apply_interior_visibility() -> void:
	var a := node_by_sid(_anchor_sid) if not _anchor_sid.is_empty() else null
	var host := str(a.interior_of) if a != null else ""
	var hide_list: Array = a.hide_when_anchored if a != null else []
	for n in nodes:
		var hide := (not host.is_empty() and n.sid == host) or hide_list.has(n.sid)
		n.set_outer_hidden(hide)


## 拉近 / 推远（改相机与注视点的距离，有上下限）。
## ★ 锚定时最近距离 = 该星体半径 × MIN_DIST_RATIO → 能贴到星体跟前，但绝不穿模。
func zoom_by(factor: float) -> void:
	_cancel_fly()
	_dist = clampf(_dist * factor, _min_distance(), _zoom_max)


## 当前视距（相机到注视点的距离，世界单位）。
func get_zoom_distance() -> float:
	return _dist


## 当前视距 ÷ 锚定星体半径（未锚定时 ÷ 世界根半径）—— 给缩放条读数用（如 "1.02R"）。
func get_zoom_distance_ratio() -> float:
	return _dist / maxf(_zoom_anchor_radius(), 1e-6)


## 缩放条专用半径：锚定星体，未锚定用世界根。
func _zoom_anchor_radius() -> float:
	var a := node_by_sid(_anchor_sid) if not _anchor_sid.is_empty() else null
	return a.radius if a != null else _root_radius()


## 缩放条的分段端点（x = 最近 ÷ 半径，y = 1.10，z = 7.0）。
## ★ 极小星体（如 radius=0.0006 的卫星）会被 `_min_distance()` 的 1e-3 下限顶到 >1.10R，
##   此时 1.10R 的分段点已经落在最近点以内 ⇒ 退化为「最近点 ~ 7R 的中点」，保证滑条仍然可用。
func _zoom_slider_ratios() -> Vector3:
	var r := maxf(_zoom_anchor_radius(), 1e-6)
	var lo := _min_distance() / r
	var far := maxf(SLIDER_FAR_RATIO, lo * 1.5)
	var mid := SLIDER_MID_RATIO if lo < SLIDER_MID_RATIO else (lo + far) * 0.5
	return Vector3(lo, mid, far)


## 归一化视距（**0 = 最近，1 = 最远**）：给世界页右下角的竖直缩放条用。
## ★ 两段**线性**（不是全范围对数）：
##   [最近, 1.10R] 占上半截（0~0.5），[1.10R, 7R] 占下半截（0.5~1）；
##   7R 以外只用滚轮 ⇒ 滑条永远停在底端，读数仍显示真实距离。
##   ⇒ 贴地时每像素只走 ~0.0007R（≈4.5 km），而 2.05R / 6.6R 这类关键位置都落在下半截里。
func get_zoom_fraction() -> float:
	var e := _zoom_slider_ratios()
	var q := get_zoom_distance_ratio()
	if q <= e.x:
		return 0.0
	if q <= e.y:
		return 0.5 * (q - e.x) / maxf(e.y - e.x, 1e-6)
	return 0.5 + 0.5 * clampf((q - e.y) / maxf(e.z - e.y, 1e-6), 0.0, 1.0)


## 按归一化视距设置相机距离（0 = 最近，1 = 最远；与 get_zoom_fraction 互逆）。
## ★ 用户一拖滑条就打断「由远及近」飞入，交还手动控制权（与滚轮 / 拖动同一套规矩）。
func set_zoom_fraction(f: float) -> void:
	_cancel_fly()
	var e := _zoom_slider_ratios()
	var r := maxf(_zoom_anchor_radius(), 1e-6)
	var q := 0.0
	var t := clampf(f, 0.0, 1.0)
	if t <= 0.5:
		q = e.x + (e.y - e.x) * (t / 0.5)
	else:
		q = e.y + (e.z - e.y) * ((t - 0.5) / 0.5)
	_dist = clampf(q * r, _min_distance(), _zoom_max)


## 最近距离下限：锚定某个星体时按它的半径算（贴得很近但不进球体）；未锚定用总节点（太阳）半径算。
func _min_distance() -> float:
	var a := node_by_sid(_anchor_sid) if not _anchor_sid.is_empty() else null
	var r := a.radius if a != null else _root_radius()
	var ratio := INNER_MIN_DIST_RATIO if a != null and a.inner_surface else MIN_DIST_RATIO
	return maxf(r * ratio, 1e-3)


## 拾取射线长：真实比例下「冥王星轨道 ≈ 92.7 万单位」，射线必须能横跨整个太阳系。
func _ray_len() -> float:
	return maxf(_zoom_max * RAY_LEN_RATIO, 1.0)


## 滚轮缩放：**向上 = 拉近**（距离变小）；「反转滚轮」开关打开时上下对调。
func zoom_wheel(up: bool) -> void:
	var zoom_in := up
	if invert_wheel:
		zoom_in = not up
	# ★ 贴地区间改用精细倍率（见 WHEEL_FINE_* 注释）：t² 过渡 ⇒ 越近越细，
	#   远景仍是一格 15%，不会把「拉近看细节」和「快速推远」的手感混在一起。
	var r := maxf(_zoom_anchor_radius(), 1e-6)
	var lo := _min_distance() / r
	var t := clampf((get_zoom_distance_ratio() - lo)
		/ maxf(WHEEL_FINE_RATIO - lo, 1e-6), 0.0, 1.0)
	var step := lerpf(WHEEL_FINE_STEP, ZOOM_STEP, t * t)
	zoom_by(1.0 / step if zoom_in else step)


func is_anchored() -> bool:
	return not _anchor_sid.is_empty()


# ---------------- 抓取拖动：鼠标按住处不变 ----------------

const INERTIA_MIN_START_PX := 4.0    # 松手时「速度」低于此值 → 不产生惯性（有效像素/帧）
const INERTIA_DECAY := 0.92          # 惯性每帧衰减系数（60fps 下约半秒衰减完）
const INERTIA_STOP_PX := 0.15        # 惯性速度低于此值 → 归零
const INERTIA_GAP_MS := 120          # 松手距上一次移动超过这么久 → 视为已停稳，不产生惯性
const SILHOUETTE_SLACK := 1.0        # 「光标在星体屏幕轮廓内」的判定余量（1.0 = 恰好轮廓）

var _grab_active: bool = false
var _grab_valid: bool = false             # 按下时是否抓到了一颗星体的表面点
var _grab_node: WorldNode = null          # 按住时抓到的那颗星体（判「是否拖出它的屏幕轮廓」）
var _grab_world: Vector3 = Vector3.ZERO   # 被按住的那个**世界坐标**点
var _grab_press_px: Vector2 = Vector2.ZERO
var _grab_last_px: Vector2 = Vector2.ZERO
var _vel_ema: Vector2 = Vector2.ZERO      # 拖动中「有效像素速度」的滑动平均（像素/事件）
var _last_move_ms: int = 0                # 上一次 update_grab 的时刻（毫秒）
var _inertia_vel: Vector2 = Vector2.ZERO  # 松手后的残余速度（有效像素/帧），逐帧衰减
## ★ 出轮廓后的「像素速率」模式：一旦本轮拖动离开可见轮廓（或牛顿解不可达），就**锁定**到
##   恒定角速度，直到松开。这样不会在「解→兜底→解」之间来回切换，速度也不会突变。
var _grab_free: bool = false
var _grab_free_dpp: float = 0.0            # 锁定的角速度（度/有效像素）
## 上一帧**成功跟手**时的角速度（度/有效像素）：转入兜底时沿用它，保证速度连续。
var _last_solve_dpp: float = -1.0


## 开始拖动：记录光标按下处对应的**世界点**（射线打到的星体表面点）。★ 一按下就掐掉残余惯性。
func begin_grab(cursor_px: Vector2) -> void:
	_cancel_fly()   # 用户按下了 → 立刻停飞入（见 _cancel_fly）
	_grab_active = true
	_grab_press_px = cursor_px
	_grab_last_px = cursor_px
	_vel_ema = Vector2.ZERO
	_last_move_ms = Time.get_ticks_msec()
	_inertia_vel = Vector2.ZERO
	_grab_free = false
	_grab_free_dpp = 0.0
	_last_solve_dpp = -1.0
	var hit: Variant = _pick_surface_point(cursor_px)
	# ★ 抓取点改用**解析求交**（见 _pick_surface_point 的注释）；物理射线只当「没解析到」时的兜底。
	if hit != null:
		_grab_node = hit["node"]
		_grab_world = hit["point"]
		_grab_valid = true
	else:
		_grab_node = pick_node_at(cursor_px)
		_grab_valid = false
		_grab_world = Vector3.ZERO


## 结束拖动。with_inertia=true 且刚刚还在快速移动 → 把残余速度交给惯性继续滚一会。
## ★ 残余速度还要乘「放大倍数阻尼」（_inertia_damp）：放得越大惯性越小（贴脸时几乎立刻停住）。
func end_grab(with_inertia: bool = true) -> void:
	if _grab_active and with_inertia:
		var gap := Time.get_ticks_msec() - _last_move_ms
		if gap <= INERTIA_GAP_MS and _vel_ema.length() >= INERTIA_MIN_START_PX:
			_inertia_vel = _vel_ema * _inertia_damp()
	_grab_active = false
	_grab_valid = false
	_grab_node = null
	_vel_ema = Vector2.ZERO


## 显式掐掉惯性（页面隐藏 / 需要立即停住时用）。
func cancel_inertia() -> void:
	_inertia_vel = Vector2.ZERO
	_cancel_fly()   # 页面隐藏 / 强制收手时，飞入也一并停（见 _cancel_fly）


## 拖动方向是否反转（只由「反转鼠标」开关决定）。
## ★ 反地面（inner_surface）**不再**在这里额外反转：内壁可见面在**远侧**，同一个相机轨道
##   角速度下，远侧内容的屏幕位移本就与近侧相反（见 `_pixel_geom_flip`）。若这里再镜像一次
##   `target`，两层反转正好抵消 —— 实测右拖时「反地面」与「地球」的球壳视觉旋转方向**相同**
##   （都逆时针），而用户要求「从北极上空看反地面顺时针、与地壳相反」。
##   ⇒ 拖动方向统一走「跟手」语义（右拖 = 内容向右），内壁的远侧几何符号由 `_apply_drag_px`
##     的 `_pixel_geom_flip()` 负责；牛顿解的目标也是**光标本身**，与像素兜底/惯性一致。
func _drag_inverted() -> bool:
	return invert_mouse


## 拖动中：始终把「按住的点」钉在光标下（不论拖多远都不漂）。
##   · 锚定（卫星视角）+ 抓到实体 + 光标仍在**该星体的屏幕轮廓内** → 解出 方位角/仰角，
##     让该点的投影回到光标处（数值牛顿迭代，像素级精确）；
##   · **拖到星体显示范围之外**（或解不可达：雅可比退化 / 单步过大 / 仰角越界）→ 不再硬解，
##     退回**按像素速率的旋转**（★ 维持操作惯性 —— 旧实现里牛顿解在轮廓外爆炸，会把相机
##     一把甩到南极/北极并来回抽搐）；
##   · 未锚定 / 没抓到实体 → 按像素平移或旋转（内容跟着光标走）。
## ★「反转鼠标」= 目标取"以按下点为镜面的对称点"，于是整体拖动方向反转。
func update_grab(cursor_px: Vector2) -> void:
	if not _grab_active:
		return
	var inverted := _drag_inverted()
	var m := -1.0 if inverted else 1.0
	var eff := (cursor_px - _grab_last_px) * m   # 有效像素位移（已折进反转因子）
	var target := cursor_px
	if inverted:
		target = _grab_press_px * 2.0 - cursor_px
	var solved := false
	# ★ 一旦离开轮廓 / 牛顿解不可达，本轮拖动就**锁定**为像素速率模式（不再尝试硬解）：
	#   否则会在「解 ↔ 兜底」之间反复切换 —— 表现为速度忽快忽慢、靠近极点时抽搐。
	if not _grab_free and _grab_valid and not _anchor_sid.is_empty() \
			and _inside_silhouette(target):
		var az0 := _azimuth_deg
		var el0 := _elevation_deg
		var dpp0 := maxf(_orbit_sens_deg(), PIXEL_SENS_MIN_DEG)
		solved = _solve_orbit_to(target)
		# ★ 硬解出来的**转角**必须与该帧像素位移相称：若牛顿解为了把点拉到目标上，
		#   转出的角度远超「1:1 速率 × 像素」，说明抓取点已经滑到球的边缘/背面
		#   （屏幕位移对转角不再线性）—— 继续硬解就会把镜头甩向南极/北极并来回抽。
		#   这种情形回滚本帧、转入锁定像素速率（每像素恒定角度），速度不会突然飙升。
		if solved:
			var moved := Vector2(_azimuth_deg - az0, _elevation_deg - el0).length()
			var px_len := maxf(eff.length(), 1e-6)
			if moved > dpp0 * px_len * GRAB_ANGLE_SLACK:
				_azimuth_deg = az0
				_elevation_deg = el0
				solved = false
				# ★ 锁定「上一步成功跟手时的每像素角度」：这样转入兜底后画面转速与
				#   离开硬解前的最后一步**连续**，不会突然变慢或变快（用户要求「速度维持」）。
				_fix_free_dpp(_last_solve_dpp)
			else:
				_last_solve_dpp = moved / px_len
	if not solved and not _grab_free:
		_enter_free_drag()
	if not solved:
		# ★ 用**锁定**的角速度：内容不再跟手时，至少保持「每像素转多少度」恒定。
		_apply_drag_px(eff, _grab_free_dpp)
	_vel_ema = _vel_ema.lerp(eff, 0.4)
	_last_move_ms = Time.get_ticks_msec()
	_grab_last_px = cursor_px


## 进入「像素速率」模式：把离开瞬间的 1:1 角速度锁死，之后不再随抓取点 θ / 轮廓变化。
func _enter_free_drag() -> void:
	if _grab_free:
		return
	_fix_free_dpp(_last_solve_dpp)


## 锁定「1 有效像素 = 多少度」（出轮廓 / 解不可达后的恒定速率）。
## `hint` = 离开前最后一步实际所需的每像素角度（未知则传 ≤0，按当前几何算）。
## 统一夹到 [PIXEL_SENS_MIN_DEG, 盘心速率 × GRAB_SENS_MAX_MUL / ORBIT_SENS_DEG 上限]，
## 避免在切线附近解出的天文角速度被锁死后一路狂转。
func _fix_free_dpp(hint: float = -1.0) -> void:
	var cap := maxf(_one_to_one_deg() * GRAB_SENS_MAX_MUL, ORBIT_SENS_DEG)
	var v := hint if hint > 0.0 else _orbit_sens_deg()
	_grab_free = true
	_grab_free_dpp = clampf(v, PIXEL_SENS_MIN_DEG, cap)


## 目标像素是否落在**被抓取星体**的屏幕轮廓内。
## ★ 这是「鼠标移到星体显示的范围外」的判据：出圈即停止硬解、改按像素速率（维持操作惯性）。
## ★ 第二十轮续修：轮廓半径改用 `_limb_radius_of`（**真实切点半径**）—— 原来用 `screen_radius_of`
##   在贴脸时只有真实值的一半不到（1.08R：526 vs 1393）⇒ 光标一往画面边上移就被判成「出圈」、
##   硬解被关掉、退化成近似速率 —— 那正是「鼠标移动得比地图多」的来源。
func _inside_silhouette(target: Vector2) -> bool:
	if _camera == null or _grab_node == null or not is_instance_valid(_grab_node):
		return false
	# ★ 内壁（反地面）：相机进入球内后，内壁铺满整个视野，不存在「轮廓之外」⇒ 始终允许硬解。
	#   （`_limb_radius_of` 在相机位于球内时按定义返回 0，会让硬解永远关掉 → 拖动退化。）
	if _grab_node.inner_surface:
		var d_in := (_camera.global_position - _grab_node.global_position).length()
		if d_in <= _grab_node.radius * 1.0001:
			return true
	var r := _limb_radius_of(_grab_node)
	if r <= 0.0:
		return false
	var c: Vector2 = _camera.unproject_position(_grab_node.global_position)
	return target.distance_to(c) <= r * SILHOUETTE_SLACK


## 星体在屏幕上的**真实轮廓半径**（= 地平线/切点那一圈的投影半径，px）。
## ★ 与 `screen_radius_of` 的区别：那个量的是「球心 + 垂直于视线偏移 radius」的点，它对应 **θ = 90°**，
##   贴到球跟前时早就跑到球的**背面**去了 ⇒ 只在远处才 ≈ k·R/D；而真正的切点在 θ = acos(R/D)，
##   投影半径 = k·R/√(D²−R²)。两者在贴脸时能差 2 倍以上（1.08R：**1393 vs 526**）。
## ★ 为什么另起一个而不是改 `screen_radius_of`：后者还被铭牌 / 尾迹 / 城市门控在用，
##   那些阈值是按「k·R/D」调出来的，改了会把它们一起挪动。
func _limb_radius_of(n: WorldNode) -> float:
	if _camera == null or n == null or not is_instance_valid(n):
		return 0.0
	var center := n.global_position
	if _is_behind(center):
		return 0.0
	var d := (_camera.global_position - center).length()
	var r := maxf(n.radius, 1e-6)
	if d <= r * 1.0001:
		return 0.0
	return _px_per_radian() * r / sqrt(d * d - r * r)


# ---------------- 屏幕投影查询（给 WorldPage 的「星体铭牌」浮层用） ----------------
#
# ★ 坐标 1:1 的前提：相机属于**内嵌 SubViewport**，而 SubViewportContainer 是 `stretch = true` +
#   PRESET_FULL_RECT ⇒ SubViewport 尺寸 = 容器尺寸、容器在舞台内偏移为 0 ⇒
#   `unproject_position()` 返回的视口坐标 **就是**舞台 Control 的局部坐标，可直接拿来摆浮层。
# （这也是 WorldPage._on_stage_gui_input 里 mb.position 同属一套坐标的原因。）

## 世界点 → 舞台/视口像素坐标。
func project_point(p: Vector3) -> Vector2:
	if _camera == null:
		return Vector2.ZERO
	return _camera.unproject_position(p)


## ★ 第二十二轮：城市层每帧要投影**几千个点**，而 `Camera3D.unproject_position()` 是引擎调用
##   （每个点约 1 µs ⇒ 5000 个点就是 5 ms）。这里把「相机逆变换 + 焦距 + 半屏」**每帧缓存一次**，
##   循环里就只剩几次乘加。口径与 `project_point` 完全一致（同一套 fov / 视口尺寸 / keep_aspect）。
##   用法：一帧开头调一次 `prepare_projection()`，之后随便调 `project_point_fast()`。
func prepare_projection() -> void:
	if _camera == null:
		return
	_proj_inv = _camera.global_transform.basis.inverse()
	_proj_pos = _camera.global_position
	_proj_focal = _px_per_radian()
	var vp := get_viewport()
	_proj_half = Vector2(vp.size) * 0.5 if vp != null else Vector2.ZERO


## 快速投影（与 `project_point` 同口径）。
## ★ 返回 `Vector2.INF` = 该点**在相机背后**（投影无意义）⇒ 调用方直接跳过。
func project_point_fast(p: Vector3) -> Vector2:
	var l := _proj_inv * (p - _proj_pos)
	if l.z > -1.0e-6:
		return Vector2.INF
	var inv := 1.0 / -l.z
	return Vector2(_proj_half.x + _proj_focal * l.x * inv, _proj_half.y - _proj_focal * l.y * inv)


## 世界点是否在相机背后（背后的投影无意义 ⇒ 调用方直接隐藏它的铭牌）。
func is_point_behind(p: Vector3) -> bool:
	return _is_behind(p)


## 星体在屏幕上的**轮廓半径**（像素）：球心沿「垂直于视线的方向」偏移 radius 后再投影，
## 两点的像素距离即半径。★ 与 `_inside_silhouette` 共用这一份实现（原来写在它里面，本轮抽出来
## 给铭牌复用，避免两份算法日后漂移）；退化（点在相机背后 / 视线方向无解）→ 返回 0。
## `radius_scale` 给铭牌用（含星环的行星要按**可见半径**往下挪，否则名称框会压在环上）；
## 默认 1.0 ⇒ `_inside_silhouette`（第五轮定好的抓取判据）行为**完全不变**。
func screen_radius_of(n: WorldNode, radius_scale: float = 1.0) -> float:
	if _camera == null or n == null or not is_instance_valid(n):
		return 0.0
	var center_w := n.global_position
	if _is_behind(center_w):
		return 0.0
	var axis := _camera.global_position - center_w
	if axis.length_squared() < 1e-6:
		return 0.0
	var side := axis.normalized().cross(Vector3.UP)
	if side.length_squared() < 1e-6:
		side = axis.normalized().cross(Vector3.RIGHT)
	if side.length_squared() < 1e-6:
		return 0.0
	var c: Vector2 = _camera.unproject_position(center_w)
	var edge: Vector2 = _camera.unproject_position(
		center_w + side.normalized() * n.radius * maxf(radius_scale, 0.0))
	var r := c.distance_to(edge)
	return r if r > 0.5 else 0.0


## 相机的全局坐标（铭牌「离相机由近到远」的占位排序用）。
func camera_position() -> Vector3:
	return _camera.global_position if _camera != null else Vector3.ZERO


## 让抓取点投影到 target（屏幕像素）：对 (方位角, 仰角) 求屏幕位置的数值雅可比，做牛顿迭代。
## ★ 返回 true = 已钉住（或已足够接近）；返回 false = **解不可达**（抓取点已被拖到星体轮廓之外 /
##   雅可比退化 / 单步过大 / 所需仰角越界）—— 此时**回滚**本帧已试的旋转并交调用方按像素速率兜底，
##   避免牛顿解在轮廓边缘爆炸成「跳到南北极」的抽搐。
func _solve_orbit_to(target: Vector2) -> bool:
	const H := 0.5              # 求偏导的扰动步长（度）
	const MAX_STEP_DEG := 45.0  # 单步允许的最大角度变化（超过 = 解不可达）
	var az0 := _azimuth_deg
	var el0 := _elevation_deg
	for i in range(6):
		_update_camera()
		if _is_behind(_grab_world):
			_azimuth_deg = az0
			_elevation_deg = el0
			return false
		var sp := _camera.unproject_position(_grab_world)
		var err := target - sp
		if err.length_squared() < 0.25:   # 误差 < 0.5px 就算钉住了
			return true
		var sda := _screen_slope(H, 0.0, sp, H)   # d(屏幕)/d(方位角)
		var sde := _screen_slope(0.0, H, sp, H)   # d(屏幕)/d(仰角)
		var det := sda.x * sde.y - sde.x * sda.y
		# 条件数退化检查：det 相对两个偏导向量模长之积太小 → 抓取点已在轮廓边缘，解会爆炸
		if absf(det) < 1e-3 * maxf(sda.length() * sde.length(), 1e-6):
			_azimuth_deg = az0
			_elevation_deg = el0
			return false
		var d_az := (err.x * sde.y - err.y * sde.x) / det
		var d_el := (sda.x * err.y - sda.y * err.x) / det
		var el_new := _elevation_deg + d_el
		# 单步过大、或所需仰角越过可用范围（[ORBIT_ELEV_MIN, ORBIT_ELEV_MAX]）→ 解不可达。
		# ★ 旧的 clampf 会在此时把仰角硬吸到边界（表现为「贴到南北极」）→ 改为交给调用方兜底。
		if absf(d_az) > MAX_STEP_DEG or absf(d_el) > MAX_STEP_DEG \
				or el_new < ORBIT_ELEV_MIN or el_new > ORBIT_ELEV_MAX:
			_azimuth_deg = az0
			_elevation_deg = el0
			return false
		_azimuth_deg += d_az
		_elevation_deg = el_new
	_update_camera()
	# ★ 跑满 6 次仍未收敛（残差 >2px）⇒ 视为解不可达：回滚本帧，交给调用方进锁定兜底。
	#   旧写法直接 `return true` 会把「差得很远」的机位当成已钉住 —— 下一帧再从那儿硬解，
	#   表现为边缘/极点附近来回抽动。
	if _is_behind(_grab_world) \
			or _camera.unproject_position(_grab_world).distance_to(target) > 2.0:
		_azimuth_deg = az0
		_elevation_deg = el0
		return false
	return true


## 数值雅可比：把 a/e 各扰动一次，量出屏幕位移（像素/度），只用于求导不动真值。
func _screen_slope(da: float, de: float, base_sp: Vector2, h: float) -> Vector2:
	_azimuth_deg += da
	_elevation_deg += de
	_update_camera()
	var sp := _camera.unproject_position(_grab_world)
	_azimuth_deg -= da
	_elevation_deg -= de
	return (sp - base_sp) / h


func _is_behind(p: Vector3) -> bool:
	var fwd := -_camera.global_transform.basis.z
	return (p - _camera.global_position).dot(fwd) <= 0.0


## 光标下的世界点：射线命中星体碰撞体 → 返回命中位置（表面点）；否则 null。
func _pick_world_point(cursor_px: Vector2) -> Variant:
	if _camera == null:
		return null
	var from := _camera.project_ray_origin(cursor_px)
	var to := from + _camera.project_ray_normal(cursor_px) * _ray_len()
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = false
	q.collide_with_bodies = true
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return null
	var n: Node = hit.get("collider")
	while n != null:
		if n is WorldNode:
			if (n as WorldNode).level <= max_visible_level:
				return hit.get("position")
			return null
		n = n.get_parent()
	return null


## 解析求交：把光标射线与**每颗可见星体的表面球（半径 = radius）**求交，返回 { node, point } 或 null。
## ★ 为什么不能用物理射线：星体的拾取体是「半径 × 1.2」的 SphereShape3D，而相机贴到球跟前时
##   （相机距球心 < 1.2R）**相机就落在拾取体内部**，而 `intersect_ray` 的 `hit_from_inside` 默认 false
##   ⇒ 射线根本打不到这颗星体 ⇒ `_grab_valid` 永远是 false ⇒ 拖动退化成「按像素速率」的近似，
##   鼠标与地图就不再 1:1（正是用户反馈的「鼠标移动得比地图多」）。
##   解析求交既不受「起点在内部」影响，又精确命中**可见表面**（而不是 1.2R 的拾取体）。
func _pick_surface_point(cursor_px: Vector2) -> Variant:
	if _camera == null:
		return null
	var o := _camera.project_ray_origin(cursor_px)
	var dir := _camera.project_ray_normal(cursor_px)
	var best_t := INF
	var best: WorldNode = null
	for n in nodes:
		if n.radius <= 0.0 or not n.visible or n.level > max_visible_level:
			continue
		# ★ 外层被隐藏的节点（锚定反地面时的地球 / `hide_when_anchored` 的地心太阳）虽然
		#   `visible` 仍为 true，但画面上是**看不见**的 —— 若参与解析求交，屏幕中央的射线会先撞上
		#   球心那颗早已藏起来的小太阳，导致抓取点、拖动速率全部按错误的球体计算。
		if n.outer_hidden:
			continue
		var oc := o - n.global_position
		var b := oc.dot(dir)
		var disc := b * b - (oc.length_squared() - n.radius * n.radius)
		if disc < 0.0:
			continue
		var sq := sqrt(disc)
		# ★ 内壁（反地面）可见的是**远侧**球面（近侧被 cull_front 剔除了）⇒ 必须取远交点。
		#   取近交点会抓到镜头与内壁之间那层「看不见的近侧壁」：它 θ≈0，1:1 速率趋近 0
		#   （贴到 1R 时被夹到 0.0005°/px）⇒ 表现为「镜头几乎拖不动」。
		var t := (-b + sq) if n.inner_surface else (-b - sq)
		if t <= 0.0:
			t = (-b - sq) if n.inner_surface else (-b + sq)
		if t > 0.0 and t < best_t:
			best_t = t
			best = n
	if best == null:
		return null
	return { "node": best, "point": o + dir * best_t }


## 拖动（按像素的速率映射）：**已折进「反转鼠标」因子** —— 外部入口。
## ★ 方向 = 「抓取」：鼠标右移 → 场景右移、鼠标下移 → 场景下移（按住处跟着光标走）。
func drag_by(px: Vector2) -> void:
	_apply_drag_px(px * (-1.0 if _drag_inverted() else 1.0))


## 把「有效像素位移」（**不含**反转因子，反转已在调用处折进）作用到镜头上：
##   ① 已锚定（**卫星视角**）→ 绕锚定星体转：只改方位角/仰角，相机始终 look_at 它，不平移；
##   ② 未锚定 → 自由平移（注视点在 XZ 平面上移动）。
## 拖动兜底与松手惯性都走这里（惯性只衰减，不再过反转开关）。
## `dpp_override` > 0 = 用锁定角速度（出轮廓模式 / 惯性），否则按当前几何实时算。
func _apply_drag_px(px: Vector2, dpp_override: float = -1.0) -> void:
	if _anchor_sid.is_empty():
		pan_by(px)
		return
	# ★ 符号必须与牛顿解一致：「抓取点」在屏幕上的移动方向 = 光标移动方向。
	#   （一正一负的写法会让像素兜底 / 松手惯性整体反向 → 表现为「拖到太空、从太空拖动、
	#     松手惯性」三个场景的拖动方向都跟光标反着走。）
	# ★ 第二十轮续：**拆成 ≤16px 的小步**再累加。原因是 1:1 速率是按**线性化**推出来的
	#   （dr/dθ 在一步之内视为常数），一步跨 100px 时误差可观（实测 6R 时只剩 78%）；
	#   拆小步、每步按**当前**几何重算速率，累积误差就降到可忽略 —— 真实鼠标事件本来也是小步。
	const MAX_SUB_PX := 16.0
	# ★ 内壁的几何符号：可见面在**远侧**，方位角/仰角增大时内容往**反方向**走。
	#   像素兜底与松手惯性是按「外侧球面」的直觉写的，这里必须乘上几何翻转，
	#   否则它们会抵消掉 `_drag_inverted()`（表现为：拖动/惯性方向仍与光标一致，没有反转）。
	var flip := _pixel_geom_flip()
	var rest := px
	while rest.length_squared() > 1e-9:
		var step := rest
		if step.length() > MAX_SUB_PX:
			step = step.normalized() * MAX_SUB_PX
		# ★ 出轮廓后的锁定模式用 `dpp_override`：每像素角度**恒定**，不再随抓取点 θ / 轮廓变化。
		var dpp := (dpp_override if dpp_override > 0.0 else _orbit_sens_deg()) * flip
		_azimuth_deg += step.x * dpp
		_elevation_deg = clampf(_elevation_deg + step.y * dpp, ORBIT_ELEV_MIN, ORBIT_ELEV_MAX)
		rest -= step
		_update_camera()   # 下一步的速率要基于更新后的几何


## 像素位移 → 角度的**几何符号**：可见面是内壁（远侧）时，**外侧**球面的直觉是反的
##   —— 方位角 +δ 会让近侧内容向右、而远侧内壁内容向左。
## ★ 只给像素兜底 / 松手惯性的角度换算用；牛顿解自己会把点钉到目标上，不需要它。
func _pixel_geom_flip() -> float:
	var n: WorldNode = null
	if _grab_node != null and is_instance_valid(_grab_node):
		n = _grab_node
	elif not _anchor_sid.is_empty():
		n = node_by_sid(_anchor_sid)
	return -1.0 if n != null and n.inner_surface else 1.0


## ★ 卫星视角下「正对镜头那一面」的**精确 1:1 抓取速率**（度/px）—— 让抓取点完全跟手所需的角速度。
##   推导：让抓取点横移 r·δ（世界单位），它到相机的距离 ≈ (D − r)，屏幕位移 = k·r·δ/(D − r) 像素
##        ⇒ 令屏幕位移 = 1px → δ = (D − r)·180 / (π·k·r) 度/px。（k = 每弧度的像素数，见 _px_per_radian）
##   ★ 视距 D 越小（放大倍数越大）该值越小 ⇒ 一切走它的量都自动跟着放大倍数缩小。
func _one_to_one_deg() -> float:
	var a := node_by_sid(_anchor_sid) if not _anchor_sid.is_empty() else null
	if a == null or _camera == null:
		return ORBIT_SENS_DEG
	var r := maxf(a.radius, 1e-6)
	# ★ 内壁（反地面）看到的是**远侧壁**：相机到可见面的距离 = 视距 + 半径（而不是 − 半径）。
	#   沿用它会得到「贴到 1.005R 时 gap 仅 0.005R」⇒ 1:1 速率趋近 0 ⇒ 画面几乎拖不动。
	var gap := (_dist + r) if a.inner_surface else maxf(_dist - r, r * 0.01)
	return gap * 180.0 / (PI * maxf(_px_per_radian() * r, 1e-6))


## 像素兜底拖动 / 松手惯性走的「1 有效像素 = 多少度」。
## ★ 第二十轮续修：**优先用抓取点自己那个位置**的 1:1 速率（`_local_one_to_one_deg`）。
##   拖动时抓取点往往不在盘心，而「每度带动的像素数」在盘边更小（透视压缩）⇒ 拿盘心的速率去拖盘边的点，
##   那个点就只走一半（实测 1.08R 时画面角上差 ~20%、2R 时近地平线差 ~43%）—— 这就是用户说的
##   「鼠标移动得比地图多」。抓不到点时才退回盘心速率，最后统一夹到 [MIN, ORBIT_SENS_DEG]。
func _orbit_sens_deg() -> float:
	if _grab_valid:
		# ★ 抓到了实体 ⇒ **严格 1:1**（用抓取点自己那处的速率），上限 = 盘心速率的 GRAB_SENS_MAX_MUL 倍
		var center := _one_to_one_deg()
		return clampf(_local_one_to_one_deg(), PIXEL_SENS_MIN_DEG,
			maxf(center * GRAB_SENS_MAX_MUL, ORBIT_SENS_DEG))
	# 没抓到（按在空处 / 拖到星体轮廓之外且解析求交也没命中）⇒ 退回盘心速率 + 旧上限（保持旧手感）
	return clampf(_one_to_one_deg(), PIXEL_SENS_MIN_DEG, ORBIT_SENS_DEG)


## 抓取点处的 1:1 速率（度/px）。闭式：屏幕半径 r(θ) = k·R·sinθ/(D − R·cosθ)
##   ⇒ dr/dθ = k·R·(D·cosθ − R)/(D − R·cosθ)²  ⇒ 1px 对应的角度 = 180/(π · dr/dθ)。
## ★ θ = 抓取点相对「球心 → 相机」那条轴的夹角。θ 越靠切点，dr/dθ → 0 ⇒ 速率 → ∞，
##   会被上层夹到 ORBIT_SENS_DEG 封顶（等价于旧的「贴到轮廓边缘就退回旧手感」）。
func _local_one_to_one_deg() -> float:
	var a := node_by_sid(_anchor_sid) if not _anchor_sid.is_empty() else null
	if a == null or _camera == null:
		return _one_to_one_deg()
	var c := a.global_position
	var axis := _camera.global_position - c
	var d := axis.length()
	var r := maxf(a.radius, 1e-6)
	var v := _grab_world - c
	var vl := v.length()
	if d <= r * 1.0001 or vl <= 1e-9:
		return _one_to_one_deg()
	var cos_t := clampf(v.dot(axis) / (vl * d), -1.0, 1.0)
	var denom := d - r * cos_t
	var slope := _px_per_radian() * r * (d * cos_t - r) / maxf(denom * denom, 1e-9)
	# ★ 取绝对值：内壁（远侧）的 cosθ < 0 ⇒ slope < 0；旧写法 max(slope, 1e-6) 会把它
	#   夹到 1e-6 ⇒ 算出天量角速度（再被上层封顶）⇒ 拖动忽快忽慢。
	return 180.0 / (PI * maxf(absf(slope), 1e-6))


## ★ 松手惯性的**阻尼系数**（0~1）：**放大倍数越大该值越小**。
##   为什么不直接用 1:1 速率当惯性：惯性在**屏幕上滑过的距离** ≈ 起始速度 × 衰减帧数 × (速率 × 屏幕灵敏度)，
##   而屏幕灵敏度 ∝ 1/视距差、1:1 速率 ∝ 视距差 ⇒ 两者相乘恒为常数 ⇒ 滑过的像素数与放大倍数**无关**
##   （贴脸 215px、远景也是 215px）—— 用户反馈的「跑到离目标很远」在贴脸时不会消失。
##   所以取 damp ∝ (1:1 速率 / 基准)² ⇒ 滑过距离 ∝ 视距差，**视距越小（放得越大）滑得越少**，
##   贴到最近时缩到 2%（几乎立刻停住）；全景/远景则封顶为 1（保持旧惯性手感）。
func _inertia_damp() -> float:
	var k := _one_to_one_deg() / maxf(ORBIT_SENS_DEG, 1e-6)
	return clampf(k * k, INERTIA_DAMP_MIN, 1.0)


## 每弧度对应的屏幕像素数：k = (视口高/2) / tan(fov/2)（与 pan_by 的换算同源）。
func _px_per_radian() -> float:
	var vp := get_viewport()
	var h := float(vp.size.y) if vp != null and vp.size.y > 0 else 800.0
	var fov := _camera.fov if _camera != null else 60.0
	return (h * 0.5) / maxf(tan(deg_to_rad(fov * 0.5)), 1e-3)


## 自由平移：把注视点在 XZ 平面上移动（拖动屏幕像素 → 世界单位按当前距离换算）。
func pan_by(px: Vector2) -> void:
	_cancel_fly()   # 平移也是"用户在动手" → 立刻停飞入（见 _cancel_fly）
	if _camera == null:
		return
	var vp := get_viewport()
	var vh := float(vp.size.y) if vp != null and vp.size.y > 0 else 800.0
	var units_per_px := 2.0 * _dist * tan(deg_to_rad(_camera.fov * 0.5)) / vh
	var b := _camera.global_transform.basis
	var right := Vector3(b.x.x, 0.0, b.x.z).normalized()
	var fwd := Vector3(-b.z.x, 0.0, -b.z.z).normalized()
	# 让内容跟着鼠标走：鼠标右移 → 注视点左移；鼠标下移 → 注视点沿屏幕上方（相机前方）移。
	_free_focus -= right * px.x * units_per_px
	_free_focus += fwd * px.y * units_per_px


## 星体拾取：射线命中碰撞体后，向上找最近的 WorldNode。
## ★ 级别过滤掉（不可见）的节点不参与拾取。
func pick_node_at(pos: Vector2) -> WorldNode:
	if _camera == null:
		return null
	var from := _camera.project_ray_origin(pos)
	var to := from + _camera.project_ray_normal(pos) * _ray_len()
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = false
	q.collide_with_bodies = true
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return null
	var n: Node = hit.get("collider")
	while n != null:
		if n is WorldNode:
			var wn := n as WorldNode
			if wn.level <= max_visible_level:
				return wn
			return null
		n = n.get_parent()
	return null


# ---------------- 级别过滤 ----------------

## 仅观察 0~N 级：level > N 的节点整体不渲染。
## ★ 尾迹挂在**父节点**下（不随本节点隐藏），所以尾迹的显隐由 _update_trails 每帧另行判定。
func set_max_visible_level(n: int) -> void:
	max_visible_level = n
	_apply_max_visible_level()
	_update_trails()
	print("[WorldView] 可见级别 → 0~%d" % max_visible_level)


## 视图模式（与 WorldPage 右上角「视图模式」下拉一一对应）：
##   0 = 俯瞰视图（默认，不做任何叠加）/ 1 = 时区视图 / 2 = 人口密度 / 3 = 气候分布
## ★ 叠加全靠地球地表壳的 `world_earth_surface.gdshader`（`view_mode` uniform）；
##   其它星体没有那条 pipeline，选了也不会有变化。
func set_view_mode(m: int) -> void:
	view_mode = m
	for node in nodes:
		if node.surface_mat != null:
			node.surface_mat.set_shader_parameter("view_mode", m)


func _apply_max_visible_level() -> void:
	for node in nodes:
		node.visible = node.level <= max_visible_level


## 尾迹的可见性（每帧判）：
##   ① 级别过滤掉（level > max_visible_level）的节点不显示其尾迹；
##   ② **相机贴到该行星跟前**（距离 < 半径 × TRAIL_HIDE_RATIO）→ 隐藏该行星的尾迹
##      （近看星体时一条贯穿画面的长线会糊住画面）；远景则让顶点 alpha 自然渐隐即可。
func _update_trails() -> void:
	if _camera == null:
		return
	var cp := _camera.global_position
	for n in nodes:
		# ★ 崩溃防护：对象若已被释放（例如重建 / 退出过程中），绝不能对着悬空引用调方法 ——
		#   release 构建下这会在进入脚本函数之前就段错误，GDScript 栈里连函数名都看不到。
		if n == null or not is_instance_valid(n):
			continue
		if n.trail != null and is_instance_valid(n.trail):
			var show := n.level <= max_visible_level
			if show:
				show = cp.distance_to(n.global_position) >= n.radius * TRAIL_HIDE_RATIO
			n.trail.visible = show
		# ★ 云层壳的显示门（第十八轮）：**离得远才显示云**，贴近地表时淡出。
		#   搭在这一次逐节点遍历里做 ⇒ 零额外遍历开销（update_shells 对无云层的节点立即返回）。
		n.update_shells(cp)
		# ★ 近景瓦片细节层（第二十六轮，地球专用）：同样搭在这趟遍历里，逐帧按相机位置更新。
		n.update_tile_detail(cp)


# ---------------- 内部 ----------------

func _update_camera() -> void:
	if _camera == null:
		return
	# 相机位置 = 注视点 + 球坐标偏移（方位角/仰角 + 距离）→ look_at 注视点。
	var ce := cos(deg_to_rad(_elevation_deg))
	var se := sin(deg_to_rad(_elevation_deg))
	var a := deg_to_rad(_azimuth_deg)
	var off := Vector3(cos(a) * ce, se, sin(a) * ce) * _dist
	_camera.global_position = _focus + off
	_camera.look_at(_focus, Vector3.UP)
	# ★ 近/远裁剪面**随视距动态**：真实比例下视距从「半径级（贴脸 0.2 单位）」跨到「十万单位（看全太阳系）」，
	#   写死的绝对面值要么在贴脸时把小星体裁掉、要么在远景时深度精度塌掉。按视距比例给面 → 两头都稳。
	_camera.near = maxf(_dist * CAM_NEAR_RATIO, 0.001)
	_camera.far = maxf(_dist * CAM_FAR_RATIO, _camera.near * 1000.0)


## 从全局设置读「反转滚轮」（settings.json 的 world_invert_wheel，默认关）。
static func read_invert_wheel_setting() -> bool:
	if SaveManager == null:
		return false
	return SaveManager.get_world_invert_wheel()


## 从全局设置读「反转鼠标」（settings.json 的 world_invert_mouse，默认关）。
static func read_invert_mouse_setting() -> bool:
	if SaveManager == null:
		return false
	return SaveManager.get_world_invert_mouse()


func _build_environment() -> void:
	var env := Environment.new()
	# ★ 背景优先用**天空盒**：世界 JSON 的 `skybox` 字段 = 等距圆柱全天图（宽:高 = 2:1）。
	#   取不到（字段为空 / 图解码失败）就回落纯色背景，不会「开天窗」。
	var sky_tex := TextureCache.fetch(str(_data.get("skybox", "")))
	if sky_tex != null:
		var pano := PanoramaSkyMaterial.new()
		pano.panorama = sky_tex
		var sky := Sky.new()
		sky.sky_material = pano
		env.sky = sky
		env.background_mode = Environment.BG_SKY
	else:
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.02, 0.035, 0.07, 1.0)
	# ★ 环境光取**固定色**、不取「天空盒」（星空近乎全黑，照它算会让星体背光面黑得不干净）；
	#   ★★ 第十六轮把能量**降到 0**：需求是「背对太阳的半球纯黑，黑到几乎看不清表面」——
	#   留一点环境光的话，背光面就会被「没有来光方向」的均匀光提亮，N·L 的纯黑噪点也在。
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.66, 0.78, 1.0)
	env.ambient_light_energy = 0.0
	var we := WorldEnvironment.new()
	we.name = "WorldEnv"
	we.environment = env
	add_child(we)

	# ★★ 光照（第十六轮重做）：删掉原来那盏「固定朝向、与太阳无关」的 DirectionalLight3D，
	#   改成**太阳本身就是光源** —— 在世界根原点挂一盏 OmniLight3D：
	#   · `omni_attenuation = 0`：不随距离衰减 ⇒ 等效「从太阳射出的平行光」，但**逐星体的来光方向是正确的**
	#     （片元的 L = 归一化(片元位置 − 太阳位置)）⇒ 火星从太阳看、海王星也从太阳看，各自背光面各自黑；
	#   · `shadow_enabled = false`：不投影 —— 免得（半透明的）太阳把自己身后的行星挡黑；
	#   · `omni_range` 这里先给占位值，setup() 里按「最远轨道 × 2」放大（范围外光会掉 0，必须盖住全系）。
	#   ★ 太阳在 WorldView 根的局部原点（orbit_radius = 0 ⇒ position = 0）；浮动原点整体平移世界根，
	#     本灯与世界根同步平移 ⇒ 光照方向恒不变。
	var light := OmniLight3D.new()
	light.name = "SunLight"
	light.light_energy = 1.2
	light.omni_attenuation = 0.0
	light.omni_range = 1000.0
	light.shadow_enabled = false
	add_child(light)
	_sun_light = light


## 初始相机距离：按最外层轨道半径估（保证一屏能看全）。★ 真实比例下该值到「百万单位」级，
## 不能再夹任何写死的绝对下限（那会让「看全太阳系」直接被截掉）。
func _default_distance() -> float:
	var far := _farthest_orbit()
	if far <= 0.0:
		far = _root_radius() * 6.0   # 无轨道（孤立星体）→ 按自身半径估一个视距
	return far * 1.15


## 离太阳最远的「星体 + 自身半径」距离（太阳灯范围 / 全景视距都用它）。
func _farthest_orbit() -> float:
	var far := 0.0
	for n in nodes:
		far = maxf(far, n.orbit_radius + n.radius * 2.0)
	return far


## 按**现实时间**把星体刷新到应有的位置 / 朝向（公转 tick 一次性跳 + 自转每小时），并把更新状态落盘。
## ★ 触发点：① 建世界（setup）；② 每次打开世界页；③ 页面可见期间每 ~60s 兜一次（见 WorldPage）
##   —— 最后一条是防「页面一直开着跨过整点 / 跨月」而位置停在旧处（穿帮）。
func refresh_celestial() -> void:
	if nodes.is_empty():
		return
	var epoch_utc := str(_data.get("epoch_utc", ""))
	if WorldTime.refresh(self, epoch_utc):
		print("[WorldView] 星体位置 / 朝向已按现实时间刷新（WorldTime）")
	# ★ 位置刷新后重算光照方向（第十八轮）：地球的公转位置逐月变 ⇒ 「地球 → 太阳」方向必须跟着变，
	#   否则地表的昼夜分界、海面镜面高光、云层向阳面都会锁在旧方向上（穿帮）。
	_apply_sun_dirs()


## 把「本节点 → 太阳」的世界空间方向写给**所有带壳的节点**（地表昼夜混合 / 海面镜面 / 云层向阳面）。
## ★ 直接用世界坐标之差：浮动原点只**平移**世界根、世界根 basis 恒为单位阵 ⇒ 方向与翻滚无关。
func _apply_sun_dirs() -> void:
	var sun := _root_node()
	if sun == null:
		return
	for n in nodes:
		if n.shells.is_empty():
			continue
		n.apply_sun_dir(sun.global_position - n.global_position)


## 总节点（level 0，太阳）：光照方向 / 尺度的基准。
func _root_node() -> WorldNode:
	for n in nodes:
		if n.parent_node == null:
			return n
	return null


## 初始注视点 = 总节点（level 0，即太阳）的位置。
func _root_focus() -> Vector3:
	for n in nodes:
		if n.parent_node == null:
			return n.position
	return Vector3.ZERO


## 总节点（太阳）的半径：所有尺度相关量的基准（最近可贴距离、视距标定、孤立视距）。
func _root_radius() -> float:
	for n in nodes:
		if n.parent_node == null:
			return maxf(n.radius, 1e-6)
	var r := 0.0
	for n in nodes:
		r = maxf(r, n.radius)
	return maxf(r, 1e-6)
