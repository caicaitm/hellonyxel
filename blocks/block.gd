# block.gd
# 「桌面」场景的积木单位（本次开发第一版）。
#
# 变量与机制（按本次对话约定）：
#   - id / ID分配（由 autoload 单例「BlockManager」分配）
#   - 宽 / 高
#   - 位置坐标（由 Node2D.position 承载，即积木中心的世界坐标）
#   - 标签集合（控制各组属性是否生效）
#   - 显示图层（渲染层级）
#   - 碰撞图层（集合：含相同元素的两个积木才会发生碰撞）
#   - 边框色（RGB + 透明度）
#   - 填充（纯色 与 图片/动图/骨骼 互斥，后者预留）
#   - 父/子级锚定（按 ID 绑定，参考已废弃版本的父子级系统；
#       父级移动 → 子级一并位移，子级移动不影响父级；
#       子级被挡住时只能走"能走的那部分"，相对位置随阻挡改变）
#   - 文本框（独立子组件，见 text_box.gd / text_box_view.gd）
#       文本框变量可由事件链修改：block.set_text_box_var(名, 变量, 值)
#       （文本框自带 hide_when_empty = 内容为空时是否隐藏）
#   - 受控状态（标签 `controlled`）：带该标签的积木响应键盘 ——
#       WASD / 四个方向键 = 移动，空格 = 起跳（跳跃另需 gravity 标签）。
#       空格**按住不放**时会连续跳跃：每次底部重新接触其他积木（落地）即再次起跳。
#       ★ 竖直方向（W/S/↑/↓）另需 `detected_vertical_move`（检测到_竖直移动）标签 **或** 可飞行。
#       开关 API：is_controlled() / set_controlled(on)；
#       右键菜单（调试模式）的「控制积木 / 解除控制」即增删这个标签元素
#       （两者按当前状态**二选一**显示：已受控只显示「解除控制」，未受控只显示「控制积木」）。
#   - 拖动（标签 `draggable`）：按下拖动期间，碰撞图层临时覆盖为 [dragging]（「被拖动中」，
#       见 block_layers.gd），松开后**恢复拖动前的图层**。
#       因此拖动时默认不再被普通积木阻挡（它们不含 dragging 层），
#       而图层里带 dragging 的积木仍能挡住被拖动的积木 —— 需要"挡"还是"不挡"按积木配置。
#   - 命令移动（标签 `commandable`）：**被选中**时右键点空白处 → 菜单「移到此处」下令，
#       积木沿**直线**奔向该点（走 _try_move → 碰撞照旧生效；抵达 或 连续若干帧没能靠近目标
#       即结束）。★ 只做直线，不做绕行 / 寻路。
#       ★ 位移由「运动参数」驱动（见下条），不再用独立速度常量：
#         · 可飞行 → 水平/竖直都直接飞过去（两轴独立趋近）；
#         · 不可飞行 → 水平照常走，**竖直目标靠跳跃达成**（地面起跳 → 空中水平靠近 → 落地再跳）。
#       开关 API：command_move_to(target) / cancel_command_move() / is_command_moving()。
#       ★ 「移到此处」菜单项不受调试模式限制（见 desktop.gd build_menu_items）。
#   - 运动参数（「积木运动」面板，见 ui/block_motion_panel.gd）：把原本写死的 MOVE_SPEED 细化为每块可配 ——
#       可飞行 / 水平最大速度 / 水平加速度 / 飞行上升最大速度 / 飞行上升加速度。
#       可飞行 = 不受重力（悬停） + 可按住 W/↑ 上升、S/↓ 下降（仍需 controlled 标签）。
#       加速度 <= 0 视为「瞬时到位」，即默认行为与旧版一致（不改变存量积木手感）。
class_name Block
extends Node2D

# YSM（是，史蒂夫）未加密模型包烘焙器：用 preload 显式依赖，
# 避免依赖全局 class_name 注册（headless 校验环境全局类缓存可能滞后）。
const YSMProjector = preload("res://blocks/ysm_projector.gd")

# 按钮信号：积木带「button_XXX」标签（BlockTags.BUTTON_PREFIX）且被**双击**（两次点击的
# 间隔与距离均 ≤ 阈值）→ 发出本信号。后续行动 / 事件链脚本可连接做响应，例如：
#   block.button_activated.connect(func(name: String): print("被按下，信号=", name))
signal button_activated(signal_name: String)

# ============ ID（由「BlockManager」单例分配）============
var id: int = 0

# ============ 字符串 ID（可选；与数字 ID 并存）============
# 用途：系统生成的积木按**固定规则**命名，便于事件链 / 脚本按名字直接定位。
#   · 桌面屏障：BedRockXU / BedRockXD（上下）、BedRockYL / BedRockYR（左右）、BedRockXC（任务栏）
#   · 图标边界墙：图标名(x,y)U/D/L/R，如 "收藏夹(560,120)U"
# 注册 / 查询 / 注销统一走 BlockManager（set_string_id / get_block_by_string_id）。
var string_id: String = ""

# ============ 朝向（左/右）============
# 值只有 FACING_LEFT / FACING_RIGHT 两种；默认朝右。
# 可变：受控时跟随 A/D/←/→ 的**上一次按下**(边沿)变化；带 lock_facing 标签时固定不变。
# 朝左时填充等视觉内容水平镜像；带 fill_flip 标签则极性反转（详见 _should_flip_visual）。
const FACING_RIGHT: int = 1
const FACING_LEFT: int = -1

var _facing: int = FACING_RIGHT
var facing: int:
	get:
		return _facing
	set(v):
		var nv := FACING_LEFT if v == FACING_LEFT else FACING_RIGHT
		if nv == _facing:
			return
		_facing = nv
		queue_redraw()   # 朝向变化 → 重绘以触发镜像

# ============ 攻击判定框 ============
# 仿照文本框：AttackBox 数组（近战判定区）。执行判定在本阶段之后，这里只做数据模型。
# 预留变量「基础攻击力」：攻击力函数里以 base_attack 引用，默认 1。
var base_attack: float = 1.0
var _attack_boxes: Array[AttackBox] = []
@export var attack_boxes: Array[AttackBox] = []:
	get:
		return _attack_boxes
	set(value):
		_attack_boxes = value
		queue_redraw()

# ============ 尺寸 ============
@export var width: float = 120.0
@export var height: float = 120.0

# ============ 形状（矩形 / 球 / 椭圆 / 三角形）============
# 形状只改变「碰撞多边形」与「绘制轮廓」，尺寸仍由 width/height 给出：
#   · RECT：四角矩形（历史行为，零回归）
#   · CIRCLE：圆，半径 = min(width,height)/2（内切，保证是真圆）
#   · ELLIPSE：椭圆，半轴 = (width/2, height/2)
#   · TRI_*：三角形，外接于 width×height 包围盒；shape_dir 控制朝向
# 碰撞统一走 SAT（见 _obb_corners → _shape_polygon），圆/椭圆用 24 边形近似（凸多边形可直接 SAT）。
enum Shape {
	RECT = 0,
	CIRCLE = 1,
	ELLIPSE = 2,
	TRI_ISOSCELES = 3,
	TRI_EQUILATERAL = 4,
	TRI_RIGHT = 5,
}
@export var shape: int = Shape.RECT
# 三角形朝向：0=上 1=右 2=下 3=左（仅三角形有意义；其它形状忽略）
@export var shape_dir: int = 0

# ============ 位置坐标 ============
# 直接使用 Node2D.position（积木中心的世界/场景坐标）。
# 相对父级偏移同理用 position；无需额外字段以免与引擎冲突。

# ============ 内部状态 ============
# 这些 backing 变量必须声明在下方对应的 @export 属性之前，
# 以保证属性初始化时 setter 依赖的字段已经存在。
var _display_layer: float = 0.0
# Block 是「积木」实体，物理上默认就参与碰撞：
#   · 不带 collision 标签 → _has_collision()=false → 屏障/其他积木都挡不住它（实测：可掉出屏幕外 6408px）
#   · 默认带 collision 标签 → 屏障（bedrock_x/bedrock_y）能挡住，避免「新建积木就掉出屏幕」
#   · 想做「纯装饰、不参与物理」的积木，把 collision 标签去掉即可
var _tags: PackedStringArray = PackedStringArray(["show", "border", "fill", "text", "collision"])
var _text_boxes: Array[TextBox] = []
# 文本框视图子节点（完全重做：每个文本框是一个真实节点，见 text_box_view.gd）
var _tb_views: Array[TextBoxView] = []
# 数值条数据 + 视图子节点（见 value_bar.gd / value_bar_view.gd，与文本框同构）
var _value_bars: Array[ValueBar] = []
var _value_bar_views: Array = []
# 局部变量数据（Array[LocalVar]；无视图，见 local_vars 的 @export 说明）
var _local_vars: Array[LocalVar] = []

# ============ 标签（控制各组属性是否生效）============
# backing + setter：标签变化时同步「文本框视图」的显隐（文本框现在是真实子节点）
@export var tags: PackedStringArray = PackedStringArray(["show", "border", "fill", "text", "collision"]):
	get:
		return _tags
	set(value):
		_tags = value
		sync_text_box_visibility()
		sync_value_bar_visibility()
		queue_redraw()   # 标签变化影响绘制（fill / border / cutout 透明等），立即重绘本积木
		_sync_cutout_items()   # cutout 标签增删 → 建/删「打洞」子画布

# ============ 行为（积木自主行动；按列表顺序优先级递减）============
# 每个元素是「行为规格」字符串（见 blocks/block_behaviors.gd 的解析）：
#   · 预设：random_patrol[:组] / ordered_patrol[:组] / area_patrol[:组] / hold_position
#   · 挂载脚本：script:<脚本名>（res://behaviors/<脚本名>.json 里的 behaviors 列表）
# 由 autoload BlockBehaviorRunner 每 tick 解释执行；写在前面的优先级更高。
var _behaviors: PackedStringArray = PackedStringArray()
@export var behaviors: PackedStringArray = PackedStringArray():
	get:
		return _behaviors
	set(value):
		_behaviors = value

# ============ 显示图层（渲染层级，决定绘制先后）============
# 用 backing 变量 + setter 同步 z_index，确保「初始值」与「运行时修改（属性面板 apply）」
# 都立即反映到渲染层级。否则仅 _ready 里设过一次 z_index，运行时改 display_layer 不会重排，
# 同级 z_index 积木按场景树顺序绘制 → 出现"显示图层=1 却被图层=0 覆盖"的偶发现象。
@export var display_layer: float = 0.0:
	get:
		return _display_layer
	set(value):
		_display_layer = value
		z_index = int(round(value))
		queue_redraw()   # 图层变化影响渲染排序（打洞画布随父节点 z 排序自动重排）

# ============ 碰撞图层（集合：含相同元素的两个积木才会发生碰撞；默认层见 BlockLayers.DEFAULT）============
@export var collision_layer: PackedStringArray = ["default"]

# ============ 边框色（RGB + 透明度）============
@export var border_color: Color = Color(1.0, 1.0, 1.0, 1.0)
@export var border_width: float = 3.0

# ============ 填充 ============
# 纯色填充 与 图片/动图/骨骼填充 互斥：
#   标签含「fill_image」且 填充来源.有效() 为真 → 走图片/动图/骨骼路径；
#   否则走纯色填充。两者不会同时绘制。
@export var fill_color: Color = Color(0.25, 0.55, 0.95, 1.0)
@export var fill: BlockFill = null

# ★ 骨骼动画填充：每块用一个 SubViewport 离屏渲染 .tscn 场景，再按填充模式贴进积木矩形。
#   纯色 / 静态图完全不创建这些节点，只有 SKELETON 才付出离屏渲染开销。
const SKELETON_SS: float = 2.0        # 离屏画布相对积木尺寸的超采样倍数（缩放后更清晰）
const SKELETON_VP_MAX: int = 2048    # 离屏画布单边像素上限，防止超大积木吃满显存
var _skel_viewport: SubViewport = null
var _skel_wrapper: Node2D = null
var _skel_scene: Node = null
var _skel_anim: AnimationPlayer = null
var _skel_anim_name: String = ""
var _skel_tex: ViewportTexture = null
var _skel_bounds: Rect2 = Rect2()
var _skel_vp_size: Vector2i = Vector2i.ZERO
var _skel_ok: bool = false
var _skel_failed: bool = false
var _skel_rebuild_queued: bool = false

# ============ 文本框（独立子组件，见 text_box.gd / text_box_view.gd）============
# backing + setter：任何赋值（代码 / 属性面板 apply / 场景文件）都会立即重建子节点视图，
# 从根本上避免「数据已更新但画面没变」这类问题。
@export var text_boxes: Array[TextBox] = []:
	get:
		return _text_boxes
	set(value):
		_text_boxes = value
		rebuild_text_boxes()

# ============ 数值条（独立子组件，见 value_bar.gd / value_bar_view.gd）============
# 与文本框同构：任何赋值（代码 / 属性面板 apply / 场景文件）都会立即重建子节点视图，
# 从根本上避免「数据已更新但画面没变」这类问题。积木默认没有数值条（_value_bars 为空）。
@export var value_bars: Array[ValueBar] = []:
	get:
		return _value_bars
	set(value):
		_value_bars = value
		rebuild_value_bars()

# ============ 局部变量（独立数据，见 local_var.gd）============
# 与数值条同构的一组「积木私有可变数值」（弹药/体力/能量/HP…）。
# ★ 本组件**没有视图**（数值条才是可见的呈现），它只是数据 + 求值方法。
#   数值条通过「对应变量」填局部变量名来读它（见 blocks/value_bar.gd::bind_var）。
#   所以改动局部变量的值之后要调 `refresh_value_bars()` 让绑了它的数值条重绘。
@export var local_vars: Array[LocalVar] = []:
	get:
		return _local_vars
	set(value):
		_local_vars = value
		# 数据变了 → 绑了这些局部变量的数值条要重新求值重绘
		refresh_value_bars()

# ============ 变量解析（待接入 VariableSystem）============
# $变量 求值回调；默认空 Callable → 不解析，显示空串。
# 接入变量系统后改为调用 VariableSystem 取得变量值。
var variable_resolver: Callable = Callable()

# ---- 内部 ----
# 文本框已改为「真实子节点」渲染（blocks/text_box_view.gd），Block 不再手绘文本框。

# ★ 玩家积木一律「可被选中」——入树时兜底补上 selectable 标签。
# 与 autoload/level_manager.gd 关卡侧的规则**完全一致**（那里是 DEFAULT_TAGS + instantiate_blocks 显式补）：
#   非调试模式下的「能否被框选 / 左键单选」**只由 selectable 标签决定**（见 desktop.gd _is_selectable），
#   不补的话，玩家在游戏态下根本选不中自己造出来的积木 → 「框选失效、点不中积木」。
# 两类**不补**（即"非玩家内容"，判定见 BlockTags.SYSTEM_TAGS 标签族）：
#   · auto_generated 及其角色标签 —— 系统派生积木：桌面屏障 / 任务栏屏障 / 桌面图标边界 /
#     页面边框 / 页面覆盖 / 关卡页面，它们由窗口与图标状态自动重建，不该被玩家选中
#     （2026-09-27 起用「不带 selectable」表达该语义）。
#   · always_unselectable —— 显式"永远不可选"，优先级最高（含调试模式），用于铺满屏幕的环境积木。
# 想表达"这块积木玩家不能选"时：给它 always_unselectable（而不是删 selectable —— 入树会被补回来）。
# 幂等：已有 selectable 时原样返回（关卡积木、存档恢复的积木都已带标签，不会重复添加）。
func _ensure_selectable() -> void:
	if BlockTags.SELECTABLE in tags:
		return
	# 系统派生积木：不补（判定用「系统标签族」而不是只看 auto_generated —— 屏障类 JSON 只写了角色标签）
	for t in tags:
		if str(t) in BlockTags.SYSTEM_TAGS:
			return
	var t2 := PackedStringArray(tags)
	t2.append(BlockTags.SELECTABLE)
	tags = t2

func _ready() -> void:
	# 旧积木只有 gravity / rollable 标签，没有运动面板字段 → 入树时迁移一次。
	# 显式写入过新字段的积木（属性面板 / 类型 JSON）不受标签影响。
	if not _motion_toggles_explicit:
		_init_legacy_motion_flags()
	_ensure_selectable()
	z_index = int(round(display_layer))
	add_to_group("block")
	# 位移基准：父子级同步用「本帧位置 - 上一物理帧位置」求 delta，入树时先对齐一次
	_prev_global_pos = global_position
	# 文本框视图必须在入树后重建（setter 在入树前会被跳过，见 rebuild_text_boxes）
	rebuild_text_boxes()
	# 数值条视图同样需在入树后重建（与文本框同构）
	rebuild_value_bars()
	# 注册 ID（autoload 单例「BlockManager」）
	if BlockManager != null:
		BlockManager.allocate_id(self)
	queue_redraw()
	# 镂空遮罩入树：按初始标签建好「打洞」子画布
	_sync_cutout_items()
	# 骨骼填充：入树后按当前 fill 建离屏场景；隐藏/镂空时暂停离屏刷新
	if not visibility_changed.is_connected(_sync_skeleton_activity):
		visibility_changed.connect(_sync_skeleton_activity)
	refresh_fill_visual()

# ============ 重力 / 滚动开关（「积木运动」面板）============
# ★★ 这两个开关**已从标签系统移除**：物理只读下面的字段，标签不再有任何作用。
#   旧存档里残留的 gravity / rollable 在入树时读取一次（迁移），随后**剥离** ——
#   留着它们，标签选择页就会显示一个「看着能控制、其实什么都不控制」的假开关。
func _init_legacy_motion_flags() -> void:
	gravity_enabled = BlockTags.GRAVITY in _tags
	roll_enabled = BlockTags.ROLLABLE in _tags
	_strip_legacy_motion_tags()


## 由属性面板 / 类型 JSON 显式写入。
func set_motion_toggles(gravity_on: bool, roll_on: bool) -> void:
	gravity_enabled = gravity_on
	roll_enabled = roll_on
	_motion_toggles_explicit = true
	_strip_legacy_motion_tags()


# 剥离旧的重力 / 可滚动标签（改由「积木运动」面板的字段控制后，标签只剩迁移读取的价值）。
func _strip_legacy_motion_tags() -> void:
	if BlockTags.GRAVITY not in _tags and BlockTags.ROLLABLE not in _tags:
		return
	var t: PackedStringArray = PackedStringArray(_tags)
	t.erase(BlockTags.GRAVITY)
	t.erase(BlockTags.ROLLABLE)
	tags = t


## 旋转轴 / 质心（世界坐标）：几何中心 + 局部偏移（随 rotation 旋转）。
func get_rotation_axis_position() -> Vector2:
	return global_position + roll_axis_offset.rotated(rotation)


func _com_world() -> Vector2:
	return get_rotation_axis_position()


## 绕配置的旋转轴旋转：轴点保持不动，几何中心随之平移。
## 用于空中自转 / 自由旋转；贴地翻滚仍以真实接触点为支点。
func _rotate_about_com(dtheta: float) -> void:
	if absf(dtheta) < 0.000001:
		return
	var axis: Vector2 = get_rotation_axis_position()
	rotation += dtheta
	global_position = axis - roll_axis_offset.rotated(rotation)


# 离开场景树：解开双向绑定，避免留下悬空引用。
# 「绑定」是 ID 关系而不是节点父子关系（场景树保持扁平），
# 所以父级消失时子级只是失去父级，不会被连带删除。
func _exit_tree() -> void:
	# 拖动中被删除/移出树：清掉全局拖动引用并恢复图层，
	# 否则下一次拖动会被"上一个已消失的拖动"阻塞（_dragging_block 非空即拒绝新的拖动）
	if Block._dragging_block == self:
		Block._dragging_block = null
	_is_dragging = false
	_exit_drag_layer()
	# 释放数值条视图（与文本框视图同构）
	for v in _value_bar_views:
		if is_instance_valid(v):
			v.queue_free()
	_value_bar_views.clear()
	unbind_parent()
	for c in _child_blocks.duplicate():
		if is_instance_valid(c) and c.parent_block == self:
			c.parent_block = null
	_child_blocks.clear()
	# 检测标签：作为检测者，要通知被我扫到的积木"我不再检测了"（否则它们的 detected_XXX 会永久残留）
	_detect_release_all()
	# 镂空遮罩离树：打洞子画布随本节点一起离开（无需额外处理）

# ============ 自测量（批次 1）：_draw 次数与耗时 ============
# ★ 用 static 字段而不去查 autoload 单例：_draw 每帧可能被 400+ 块各调一次，
#   每块都做一次 autoload 查找纯属浪费。关闭时只多一条 static bool 判断。
static var profile_on := false          # 由自测量面板开关（关 = 零开销）
static var profile_draw_count: int = 0  # 窗口内 _draw 次数（面板读后清零）
static var profile_draw_usec: int = 0   # 窗口内 _draw 总耗时（微秒，面板读后清零）

func _draw() -> void:
	if profile_on:
		var t0 := Time.get_ticks_usec()
		_draw_impl()
		profile_draw_usec += Time.get_ticks_usec() - t0
		profile_draw_count += 1
		return
	_draw_impl()

func _draw_impl() -> void:
	if not (BlockTags.SHOW in tags):
		return
	var flipped := _should_flip_visual()
	if flipped:
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(-1.0, 1.0))
	var rect := Rect2(-width / 2.0, -height / 2.0, width, height)
	# 填充（纯色 / 图片二选一）；镂空遮罩(cutout)：自身始终透明——即使带 fill 标签也不绘制填充。
	# 低层积木无需自行抠洞：cutout 积木的「打洞画布」在渲染期把洞内已画内容的 alpha 乘成 0，
	# （见下方 _sync_cutout_items / _CutoutHoleItem），填充、边框、文本框、图片全部自动被抹掉。
	# ★ 图片填充优先：带 fill_image 标签且填充来源有效 → 画图片（贴图缺失时 _draw_image_fill
	#   自己会退回纯色）。否则才走纯色填充（纯色仍要求 fill 标签）。
	#   ★ 图片分支**不要求**同时带 fill 标签——属性面板填了图片路径就会加 fill_image，
	#     若还强制要求 fill，用户会「填了路径却什么都不显示」。
	if not (BlockTags.CUTOUT in tags):
		if BlockTags.FILL_IMAGE in tags and fill != null and fill.is_valid():
			if shape == Shape.RECT:
				if int(fill.anim_type) == int(BlockFill.AnimType.SKELETON):
					_draw_skeleton_fill(rect)
				else:
					_draw_image_fill(rect, fill)
			else:
				_draw_shaped_image_fill(fill)
		elif BlockTags.FILL in tags:
			if shape == Shape.RECT:
				draw_rect(rect, fill_color)
			else:
				_draw_shape_solid(fill_color)
	# 边框（cutout 的边框改由 _border_item 子画布在洞之后绘制，避免被自己的洞抠掉）
	if BlockTags.BORDER in tags and not (BlockTags.CUTOUT in tags):
		if shape == Shape.RECT:
			draw_rect(rect, border_color, false, border_width)
		else:
			_draw_shape_border(border_color, border_width)
	if flipped:
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)   # 复位，避免影响后续绘制
	# 文本框：不再在 _draw 里手绘，改为子节点 TextBoxView 自行渲染（见 rebuild_text_boxes）
	# ★ 强制显示边框由 debug/force_border_overlay.gd 的全局顶层覆盖层统一绘制（忽略标签、
	#   位于 cutout 打洞画布之上，不会被镂空洞穿透），此处不再处理。

# ============ 镂空遮罩（cutout）支持 ============
# 带 cutout 标签的积木：自身透明（不绘制填充），并打穿一块「直通电脑桌面」的洞——
#   所有**先于本积木绘制**的内容（更低显示图层积木的填充/边框/文本框/图片等）在洞内全部被抹掉，
#   只露出电脑本身的画面（窗口未绘制处 alpha=0 → 桌面透出，见 DesktopShell 透明覆盖层）。
# 实现：挂一个 MUL(乘法混合) 材质的子画布 _hole_item，往帧缓冲写 Color(0,0,0,0)，
#   把洞内已有像素的 RGB/alpha 乘成 0（真机验证：alpha=0 桌面可见，半透明按比例减）。
#   绘制顺序 = 显示图层：洞只影响「比本积木先画」的内容（更低图层；同级时按树序先画的）；
#   更高图层的内容在洞之后绘制，不受影响。位置随父节点自动移动、尺寸/颜色变化由
#   子画布 _process 自检重绘 —— 不再需要任何「通知低层重绘」的簿记。
# 遮罩自身的边框由 _border_item 子画布（普通混合，排在洞之后）绘制，窗口轮廓仍可见。

var _hole_item: Node2D = null     # MUL 打洞画布（cutout 专用，置于子节点最前）
var _border_item: Node2D = null   # 遮罩边框画布（洞之后绘制，不被自己的洞抠掉）

# 打洞画布：往父积木矩形内写 (0,0,0,0)（MUL → 洞内一切已画内容归零）
class _CutoutHoleItem extends Node2D:
	var block: Block = null
	var _last_sig := ""
	func _draw() -> void:
		if block == null or not is_instance_valid(block):
			return
		# 打洞区域 = 积木形状（矩形走 draw_rect；圆/椭圆/三角形走多边形）。
		if int(block.shape) == 0:
			draw_rect(Rect2(-block.width / 2.0, -block.height / 2.0, block.width, block.height),
				Color(0, 0, 0, 0))
		else:
			var pts := block._shape_local_polygon()
			if pts.size() >= 3:
				draw_colored_polygon(pts, Color(0, 0, 0, 0))
	func _process(_delta: float) -> void:
		# 尺寸 / 形状变化随动；位置由父节点带动（子画布随父移动），无需处理
		if block == null or not is_instance_valid(block):
			return
		var sig := "%s_%s_%s_%s" % [str(block.width), str(block.height), str(block.shape), str(block.shape_dir)]
		if sig != _last_sig:
			_last_sig = sig
			queue_redraw()

# 遮罩边框画布：普通混合，绘制顺序在洞之后 → 轮廓仍可见。
# 仅当积木本身带 border 标签时绘制（强制显示边框由全局覆盖层统一处理，此处不重复）。
class _CutoutBorderItem extends Node2D:
	var block: Block = null
	var _sig := ""
	func _draw() -> void:
		if block == null or not is_instance_valid(block):
			return
		if not (BlockTags.BORDER in block.tags):
			return
		if int(block.shape) == 0:
			draw_rect(Rect2(-block.width / 2.0, -block.height / 2.0, block.width, block.height),
				block.border_color, false, block.border_width)
		else:
			var pts := block._shape_local_polygon()
			if pts.size() >= 2:
				var line := PackedVector2Array(pts)
				line.append(pts[0])
				draw_polyline(line, block.border_color, block.border_width)
	func _process(_delta: float) -> void:
		if block == null or not is_instance_valid(block):
			return
		var sig := "%s|%s|%s|%s|%s|%s|%s" % [str(block.width), str(block.height),
			str(block.border_color), str(block.border_width),
			"1" if (BlockTags.BORDER in block.tags) else "0",
			str(block.shape), str(block.shape_dir)]
		if sig != _sig:
			_sig = sig
			queue_redraw()

## 按 cutout 标签同步「打洞画布 / 边框画布」子节点的建删与排序
func _sync_cutout_items() -> void:
	var on := (BlockTags.CUTOUT in _tags) and (BlockTags.SHOW in _tags)
	if on:
		if _hole_item == null or not is_instance_valid(_hole_item):
			var hole := _CutoutHoleItem.new()
			hole.block = self
			hole.name = "CutoutHole"
			var mat := CanvasItemMaterial.new()
			mat.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
			hole.material = mat
			_hole_item = hole
			add_child(hole)
		if _border_item == null or not is_instance_valid(_border_item):
			var bi := _CutoutBorderItem.new()
			bi.block = self
			bi.name = "CutoutBorder"
			_border_item = bi
			add_child(bi)
		# 排序：洞放最前（先打洞再画遮罩自己的文本框），边框紧随其后
		move_child(_hole_item, 0)
		move_child(_border_item, mini(1, get_child_count() - 1))
		_hole_item.visible = true
		_border_item.visible = true
	else:
		if _hole_item != null and is_instance_valid(_hole_item):
			_hole_item.queue_free()
		if _border_item != null and is_instance_valid(_border_item):
			_border_item.queue_free()
		_hole_item = null
		_border_item = null
	_sync_skeleton_activity()

## ★★ 输入侧与绘制侧同源的闸门：**该全局坐标点是否被更高的镂空遮罩盖住**。
##
## 绘制侧的事实（见上方 cutout 一节）：带 cutout 的积木往帧缓冲写 MUL 洞，把**比它先画**
## （显示层更低）的内容在洞内全部乘成 0 —— 那块像素上显示的是遮罩后面的东西。
## 若输入侧仍让被抹掉的积木吃事件，就会出现「看得见的地方点不动、看不见的地方反而有反应」：
##   典型 = 窗口页面的覆盖积木盖住桌面图标后，点窗口内容却触发了下面那个**已经看不见**的图标
##   （表现为「这块区域怎么操作都不对」）。
##
## 本函数给输入侧一把与绘制侧同源的尺子：同场景内是否存在一块
##   「带 cutout + 带 show + 可见 + 显示层**严格更高** + 矩形包含该点」的积木。
## 命中 → 调用方应放弃这次点击 / 拖动（**不吞事件**，交给真正的上层或桌面处理）。
##
## 说明：
##   · 只比显示层（`>`），与 block_tags.gd 对 cutout 的说明一致（「只隐藏 display_layer 比它小的积木」）。
##     覆盖积木的显示层被夹在 [32,63]（见 window_page.gd），故玩家积木(64)/页面边框(90)不受影响。
##   · 与 _can_move_to / _detect_scan 同款**同场景闸门**：跨场景（桌面 ↔ 关卡页面）互不遮蔽。
##   · 每帧不调用，只在鼠标按下（以及桌面点选）时调用一次；组遍历条数与碰撞判定同级，可接受。
func is_point_covered(p: Vector2) -> bool:
	var tree := get_tree()
	if tree == null:
		return false
	# 自身不可见的积木本来也不接收输入，无需再算
	if not (BlockTags.SHOW in tags):
		return false
	var my_scene: Node = _scene_of()
	var my_layer: float = display_layer
	for other in tree.get_nodes_in_group("block"):
		# ★ 先 is_instance_valid 再 `is Block`（组是全局快照，可能含已释放节点）
		if not is_instance_valid(other) or other == self or not (other is Block):
			continue
		var ob: Block = other
		if not (BlockTags.CUTOUT in ob.tags) or not (BlockTags.SHOW in ob.tags):
			continue
		if not ob.is_visible_in_tree():
			continue
		if ob._scene_of() != my_scene:
			continue
		if ob.display_layer <= my_layer:
			continue
		if ob._obb_contains_point(ob.global_position, p):
			return true
	return false


# ============ 文本框视图（完全重做）============
# 每个 TextBox 数据对应一个 TextBoxView 子节点：
#   - 背景：Panel + StyleBoxFlat（引擎样式系统绘制，必定生效）
#   - 文字：RichTextLabel + BBCode（引擎文本系统绘制，必定生效）
# 因此文本框在「远程」场景树中可见，可单独检查尺寸与内容，不再依赖 Block._draw。
func rebuild_text_boxes() -> void:
	for v in _tb_views:
		if is_instance_valid(v):
			v.queue_free()
	_tb_views.clear()
	# 未入树时不建视图（入树后 _ready 会再调一次）
	if not is_inside_tree():
		return
	for tb in _text_boxes:
		if tb == null:
			continue
		# 文本框变量被赋值（事件/脚本/属性面板）→ Resource.changed 触发，自动刷新视图，无需轮询
		if not tb.changed.is_connected(_on_text_box_changed):
			tb.changed.connect(_on_text_box_changed)
		var view := TextBoxView.new()
		view.name = "TextBoxView"
		add_child(view)
		view.setup(tb, self)
		_tb_views.append(view)
	print("[Block] 重建文本框视图: 数据=%d 视图=%d TEXT标签=%s" % [
		_text_boxes.size(), _tb_views.size(), str(BlockTags.TEXT in _tags)])

# 标签变化 → 同步文本框视图显隐（含 show / text 两个标签）
func sync_text_box_visibility() -> void:
	for v in _tb_views:
		if is_instance_valid(v):
			v.refresh_visibility()

# 完整重算所有文本框视图（尺寸/样式/文本求值/显隐）
# 调用时机：文本框变量（如文本内容、变量值）变化后。
func refresh_text_boxes() -> void:
	for v in _tb_views:
		if is_instance_valid(v):
			v.refresh()

# 文本框变量变化回调（TextBox 的 Resource.changed）→ 全量刷新
func _on_text_box_changed() -> void:
	refresh_text_boxes()

# ============ 文本框变量（供事件链 / 脚本修改）============
# 统一入口：set_text_box_var(文本框名, 变量名, 值)
#   block.set_text_box_var("标题", "hide_when_empty", true)
# 也可直接给 TextBox 赋值（其 changed 信号会自动刷新视图）：
#   var tb := block.find_text_box("标题")
#   if tb != null: tb.hide_when_empty = true
# 新增可改变量时，在 _set_text_box_prop() 的 match 里登记即可。
func find_text_box(tb_name: String) -> TextBox:
	for tb in _text_boxes:
		if tb != null and tb.name == tb_name:
			return tb
	return null

func get_text_box_var(tb_name: String, prop: String) -> Variant:
	var tb := find_text_box(tb_name)
	if tb == null:
		return null
	match prop:
		"hide_when_empty":
			return tb.hide_when_empty
		"text_def":
			return tb.text_def
		"text_defs":
			# 返回副本：避免调用方就地改字典而绕过 changed 通知（视图不刷新）。
			return tb.text_defs.duplicate(true)
		"fill_image_path":
			return tb.fill_image_path
		_:
			push_warning("[Block] 未知文本框变量: %s" % prop)
			return null

func set_text_box_var(tb_name: String, prop: String, value: Variant) -> bool:
	var tb := find_text_box(tb_name)
	if tb == null:
		push_warning("[Block] set_text_box_var 找不到文本框: '%s'" % tb_name)
		return false
	return _set_text_box_prop(tb, prop, value)

# 往积木上新增一个文本框（自动重建议图）；返回是否成功添加
func add_text_box(tb: TextBox) -> bool:
	if tb == null or not (tb is TextBox):
		return false
	var arr := _text_boxes.duplicate()
	arr.append(tb)
	text_boxes = arr   # 触发 setter → rebuild_text_boxes()
	return true


# ============ 数值条视图（与文本框同构）============
# 每个 ValueBar 数据对应一个 ValueBarView 子节点（真实 Control 节点，自行 _draw）。
func rebuild_value_bars() -> void:
	for v in _value_bar_views:
		if is_instance_valid(v):
			v.queue_free()
	_value_bar_views.clear()
	# 未入树时不建视图（入树后 _ready 会再调一次）
	if not is_inside_tree():
		return
	for vb in _value_bars:
		if vb == null:
			continue
		var view := ValueBarView.new()
		view.name = "ValueBarView"
		add_child(view)
		view.setup(vb, self)
		_value_bar_views.append(view)
	print("[Block] 重建数值条视图: 数据=%d 视图=%d" % [_value_bars.size(), _value_bar_views.size()])


# 标签变化 → 同步数值条视图显隐（含 show 标签）
func sync_value_bar_visibility() -> void:
	for v in _value_bar_views:
		if is_instance_valid(v):
			v.refresh_visibility()


# 完整重算所有数值条视图（比例/样式/文本求值/显隐）
func refresh_value_bars() -> void:
	for v in _value_bar_views:
		if is_instance_valid(v):
			v.refresh()


func find_value_bar(vb_name: String) -> ValueBar:
	for vb in _value_bars:
		if vb != null and vb.name == vb_name:
			return vb
	return null


# 往积木上新增一个数值条（自动重建视图）；返回是否成功添加
func add_value_bar(vb: ValueBar) -> bool:
	if vb == null or not (vb is ValueBar):
		return false
	var arr: Array[ValueBar] = []
	for v in _value_bars:
		arr.append(v)
	arr.append(vb)
	value_bars = arr   # 触发 setter → rebuild_value_bars()
	return true


# ============ 局部变量 API（无视图，见 local_var.gd）============

## 按名字取局部变量；没有 / 名字空 → null
func find_local_var(lv_name: String) -> LocalVar:
	if lv_name == "":
		return null
	for lv in _local_vars:
		if lv != null and lv.name == lv_name:
			return lv
	return null


## 新增一个局部变量（同名则拒绝，返回 false）。会自动让数值条重绘。
func add_local_var(lv: LocalVar) -> bool:
	if lv == null or not (lv is LocalVar):
		return false
	if find_local_var(lv.name) != null:
		return false
	var arr: Array[LocalVar] = []
	for v in _local_vars:
		arr.append(v)
	arr.append(lv)
	local_vars = arr   # 触发 setter → refresh_value_bars()
	return true


## 删除指定名字的局部变量；返回是否真的删了。
func remove_local_var(lv_name: String) -> bool:
	var arr: Array[LocalVar] = []
	var found := false
	for v in _local_vars:
		if v != null and v.name == lv_name:
			found = true
			continue
		arr.append(v)
	if found:
		local_vars = arr
	return found


## 设某个局部变量的现有值（自动夹紧到 [min,max]）；返回是否真的改变了。
##   数值条绑了它的话会立刻重绘比例（setter 里做了）。
func set_local_var_value(lv_name: String, v: float) -> bool:
	var lv := find_local_var(lv_name)
	if lv == null:
		return false
	if not lv.set_current(v):
		return false
	refresh_value_bars()
	return true


## 推进一次「恢复」：对所有 recover_rate > 0 的局部变量各 tick 一次。
##   返回「是否有任一个变量发生了变化」（决定要不要重绘）。
##   ★ 现在没有计时器自动调它 —— 留给将来的事件链 / `LocalVarSystem`；
##     手动调用一次即可看到数值条变化。
func tick_local_vars() -> bool:
	var any := false
	for lv in _local_vars:
		if lv != null and lv.tick_recover():
			any = true
	if any:
		refresh_value_bars()
	return any


func _set_text_box_prop(tb: TextBox, prop: String, value: Variant) -> bool:
	match prop:
		"hide_when_empty":
			tb.hide_when_empty = bool(value)     # setter 会发 changed → 自动刷新
		"text_def":
			tb.text_def = str(value)
			refresh_text_boxes()
		"text_defs":
			# 整份替换多语言文本（属性页「应用」走这里）。非字典 → 视为清空。
			# ★ 直接给字段赋值不会 emit_changed（只有 hide_when_empty 的 setter 会）→ 必须显式刷新视图。
			if value is Dictionary:
				tb.text_defs = (value as Dictionary).duplicate(true)
			else:
				tb.text_defs = {}
			refresh_text_boxes()
		"fill_image_path":
			tb.fill_image_path = str(value)
			refresh_text_boxes()
		_:
			push_warning("[Block] 未知文本框变量: %s" % prop)
			return false
	return true

# 统一解析「填充来源贴图」：YSM 包走 YSMProjector 烘焙，其余走 TextureCache。
# 返回 null = 无有效贴图（调用方应退回纯色兜底）。
func _resolve_fill_texture(src: BlockFill) -> Texture2D:
	if src == null:
		return null
	if int(src.anim_type) == int(BlockFill.AnimType.YSM):
		return YSMProjector.get_texture(src.path)
	return TextureCache.fetch(src.path)


# 静态图填充绘制：按 src.path 取贴图，依 src.fill_mode 决定铺法。
#   KEEP_MAX_RATIO 等比缩放完整显示并居中（默认） / FILL 拉伸铺满（可能变形） /
#   CENTER 居中原尺寸 / TILE 平铺重复 / ORIGINAL 左上角原尺寸。
# ★ 只有静态图走这里；骨骼动画由下方 _draw_skeleton_fill 处理，动图仍按首帧静态绘制。
#   贴图加载失败 → 纯色兜底，不让坏路径报错刷屏。
func _draw_image_fill(rect: Rect2, src: BlockFill) -> void:
	if src == null:
		draw_rect(rect, fill_color)
		return
	var tex := _resolve_fill_texture(src)
	if tex == null:
		draw_rect(rect, fill_color)
		return
	var tsize: Vector2 = tex.get_size()
	if tsize.x <= 0.0 or tsize.y <= 0.0:
		draw_rect(rect, fill_color)
		return
	# 瓦片（九宫格/网格）绘制：切分 ≥ 2×2 时走专用绘制，否则退回普通填充模式
	if src.is_tiled():
		_draw_tiled(rect, tex, src, tsize)
		return
	match int(src.fill_mode):
		BlockFill.Mode.FILL:
			# 拉伸铺满
			draw_texture_rect(tex, rect, false)
		BlockFill.Mode.TILE:
			# 平铺重复
			draw_texture_rect(tex, rect, true)
		BlockFill.Mode.ORIGINAL:
			# 左上角，原尺寸（超出部分不显示）
			draw_texture_rect(tex, Rect2(rect.position, tsize), false)
		BlockFill.Mode.CENTER:
			# 居中，原尺寸
			draw_texture_rect(tex, Rect2(rect.position + (rect.size - tsize) * 0.5, tsize), false)
		_:
			# KEEP_MAX_RATIO（默认）：等比缩放，完整显示，居中，不裁剪
			var s := minf(rect.size.x / tsize.x, rect.size.y / tsize.y)
			var d := tsize * s
			draw_texture_rect(tex, Rect2(rect.position + (rect.size - d) * 0.5, d), false)


# ============ 非矩形形状的填充 / 边框 / 贴图 ============

# 纯色填充：按形状多边形填充。
func _draw_shape_solid(color: Color) -> void:
	var pts := _shape_local_polygon()
	if pts.size() >= 3:
		draw_colored_polygon(pts, color)


# 边框：沿形状多边形描一圈（闭合）。
func _draw_shape_border(color: Color, w: float) -> void:
	var pts := _shape_local_polygon()
	if pts.size() < 2:
		return
	var line := PackedVector2Array(pts)
	line.append(pts[0])
	draw_polyline(line, color, w)


# 图片填充（非矩形）：把贴图按「包围盒 UV」映射到形状多边形 = 按形状裁剪。
# 骨骼动画 / 瓦片在非矩形上极少见 → 退回矩形绘制（不裁形），保证功能不缺失。
func _draw_shaped_image_fill(src: BlockFill) -> void:
	if src != null and int(src.anim_type) == int(BlockFill.AnimType.SKELETON):
		_draw_skeleton_fill(Rect2(-width / 2.0, -height / 2.0, width, height))
		return
	var tex: Texture2D = _resolve_fill_texture(src)
	if tex == null:
		_draw_shape_solid(fill_color)
		return
	var tsize: Vector2 = tex.get_size()
	if tsize.x <= 0.0 or tsize.y <= 0.0:
		_draw_shape_solid(fill_color)
		return
	var pts := _shape_local_polygon()
	if pts.size() < 3:
		return
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var w: float = maxf(1.0, width)
	var h: float = maxf(1.0, height)
	for lp in pts:
		var u: float = (lp.x + width * 0.5) / w
		var v: float = (lp.y + height * 0.5) / h
		uvs.append(Vector2(u * tsize.x, v * tsize.y))
		cols.append(Color.WHITE)
	draw_polygon(pts, cols, uvs, tex)


# ============ 骨骼动画填充 ============
# 数据：fill.path = .tscn 场景，fill.anim_type = SKELETON（由「积木属性 → 填充类型」选择）。
# 做法：每块积木挂一个 SubViewport，把场景实例放进去交给 AnimationPlayer 播放；
#   先在动画多个时间点采样 Sprite2D 包围盒，按 fill_mode 把整棵骨架缩放/平移进一块
#   与积木同宽高比的离屏画布（画布边缘自然裁掉超出的部分），最后把整张画布贴进积木矩形。
#   这样朝向镜像、边框、文本框覆盖、镂空、显示层全部沿用原有绘制顺序，不需要另开渲染路径。
#
# 性能：只有 SKELETON 填充创建 SubViewport，纯色/静态图零额外开销；
#   积木不可见（无 show / cutout / visible=false）时切到 UPDATE_DISABLED，暂停离屏刷新。

## 填充来源被修改后调用（属性面板 apply、存档恢复、类型模板创建）。重建骨骼离屏场景。
## 静态图 / 纯色只需重绘（旧骨骼节点一并释放）。
func refresh_fill_visual() -> void:
	_teardown_skeleton()
	queue_redraw()
	if _wants_skeleton():
		_queue_skeleton_rebuild()


func _wants_skeleton() -> bool:
	return fill != null and fill.is_valid() and int(fill.anim_type) == int(BlockFill.AnimType.SKELETON)


func _queue_skeleton_rebuild() -> void:
	if _skel_rebuild_queued:
		return
	_skel_rebuild_queued = true
	call_deferred("_rebuild_skeleton_deferred")


func _rebuild_skeleton_deferred() -> void:
	_skel_rebuild_queued = false
	_teardown_skeleton()
	_build_skeleton()


func _build_skeleton() -> void:
	if not is_inside_tree() or not _wants_skeleton() or _skel_viewport != null:
		return
	var path := str(fill.path).strip_edges()
	if not ResourceLoader.exists(path):
		_skel_failed = true
		queue_redraw()
		return
	var res: Resource = load(path)
	if not (res is PackedScene):
		_skel_failed = true
		queue_redraw()
		return
	var packed: PackedScene = res as PackedScene
	var inst: Node = packed.instantiate()
	if inst == null:
		_skel_failed = true
		queue_redraw()
		return
	var vp := SubViewport.new()
	vp.name = "SkeletonViewport"
	vp.transparent_bg = true
	vp.world_2d = World2D.new()   # 独立 2D 世界：骨骼场景不参与桌面/关卡的物理与相机
	vp.disable_3d = true
	vp.gui_disable_input = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.size = _desired_skeleton_vp_size()
	add_child(vp)
	var wrap := Node2D.new()
	wrap.name = "Fit"
	vp.add_child(wrap)
	wrap.add_child(inst)
	_skel_viewport = vp
	_skel_wrapper = wrap
	_skel_scene = inst
	_skel_tex = vp.get_texture()
	_skel_vp_size = vp.size
	_skel_anim = _find_animation_player(inst)
	_skel_anim_name = _pick_skeleton_anim(_skel_anim)
	_skel_bounds = _sample_skeleton_bounds(_skel_anim, _skel_anim_name)
	_skel_ok = _skel_bounds.size.x > 0.5 and _skel_bounds.size.y > 0.5
	_skel_failed = not _skel_ok
	if _skel_ok:
		_apply_skeleton_fit()
	else:
		push_warning("[Block] 骨骼场景里没有可测量尺寸的 Sprite2D：%s" % path)
	_sync_skeleton_activity()
	queue_redraw()


func _teardown_skeleton() -> void:
	if _skel_viewport != null and is_instance_valid(_skel_viewport):
		_skel_viewport.queue_free()
	_skel_viewport = null
	_skel_wrapper = null
	_skel_scene = null
	_skel_anim = null
	_skel_anim_name = ""
	_skel_tex = null
	_skel_bounds = Rect2()
	_skel_vp_size = Vector2i.ZERO
	_skel_ok = false
	_skel_failed = false


func _sync_skeleton_activity() -> void:
	if _skel_viewport == null or not is_instance_valid(_skel_viewport):
		return
	var active := is_inside_tree() and visible and (BlockTags.SHOW in _tags) and not (BlockTags.CUTOUT in _tags)
	_skel_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED


# 离屏画布尺寸：与积木同宽高比，乘以超采样倍数；超大积木自动降低倍数并夹到上限。
func _desired_skeleton_vp_size() -> Vector2i:
	var w := maxf(1.0, width)
	var h := maxf(1.0, height)
	var ss := SKELETON_SS
	var longest := maxf(w, h)
	if longest * ss > float(SKELETON_VP_MAX):
		ss = float(SKELETON_VP_MAX) / longest
	var px := maxi(1, int(round(w * ss)))
	var py := maxi(1, int(round(h * ss)))
	return Vector2i(mini(px, SKELETON_VP_MAX), mini(py, SKELETON_VP_MAX))


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var ap := _find_animation_player(child)
		if ap != null:
			return ap
	return null


# 优先 autoplay；没有就播第一个非 RESET 动画。返回 "" = 场景无动画（只显示绑定姿势）。
func _pick_skeleton_anim(ap: AnimationPlayer) -> String:
	if ap == null:
		return ""
	var auto_anim := str(ap.autoplay)
	if not auto_anim.is_empty() and ap.has_animation(auto_anim):
		return auto_anim
	for anim_name in ap.get_animation_list():
		if str(anim_name) != "RESET":
			return str(anim_name)
	return ""


# 在动画时长内均匀采样，取 Sprite2D 包围盒的并集 —— 走路时手脚会伸出绑定姿势，
# 只按第 0 帧适配会导致动画中途被裁掉。
func _sample_skeleton_bounds(ap: AnimationPlayer, anim_name: String) -> Rect2:
	var has_anim := ap != null and not anim_name.is_empty() and ap.has_animation(anim_name)
	var anim_len := 0.0
	if has_anim:
		ap.play(anim_name)
		var anim := ap.get_animation(anim_name)
		if anim != null:
			anim_len = anim.length
	var acc := Rect2()
	var found := false
	var samples: int = 1 if (not has_anim or anim_len <= 0.0) else 13
	for i in samples:
		if has_anim:
			ap.seek(anim_len * float(i) / float(maxi(1, samples - 1)), true)
		var r := _current_sprite_bounds()
		if r.size.x > 0.0 and r.size.y > 0.0:
			acc = r if not found else acc.merge(r)
			found = true
	if has_anim:
		ap.seek(0.0, true)
		ap.play(anim_name)
	return acc


# 当前姿势下所有 Sprite2D 在「wrapper 坐标系」里的并集（采样时 wrapper 是单位变换）。
func _current_sprite_bounds() -> Rect2:
	var acc := Rect2()
	var found := false
	if _skel_scene == null or not is_instance_valid(_skel_scene):
		return acc
	var sprites: Array[Sprite2D] = []
	_collect_sprites(_skel_scene, sprites)
	for spr in sprites:
		if spr.texture == null or not spr.visible:
			continue
		var r := spr.get_rect()
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		var xf := spr.get_global_transform()
		var p0 := xf * r.position
		var p1 := xf * Vector2(r.position.x + r.size.x, r.position.y)
		var p2 := xf * (r.position + r.size)
		var p3 := xf * Vector2(r.position.x, r.position.y + r.size.y)
		var box := Rect2(p0, Vector2.ZERO).expand(p1).expand(p2).expand(p3)
		acc = box if not found else acc.merge(box)
		found = true
	return acc


func _collect_sprites(node: Node, out: Array[Sprite2D]) -> void:
	if node is Sprite2D:
		out.append(node as Sprite2D)
	for child in node.get_children():
		_collect_sprites(child, out)


# 把包围盒映射进离屏画布，语义与静态图填充模式一致。
# CENTER / ORIGINAL 的「原尺寸」= 场景像素尺寸（画布是积木的 SS 倍，所以乘 SS 还原）。
func _apply_skeleton_fit() -> void:
	if _skel_wrapper == null or not is_instance_valid(_skel_wrapper) or _skel_viewport == null:
		return
	var b := _skel_bounds
	if b.size.x <= 0.0 or b.size.y <= 0.0:
		_skel_wrapper.transform = Transform2D.IDENTITY
		return
	var vp_size := Vector2(_skel_viewport.size)
	var mode := int(BlockFill.Mode.KEEP_MAX_RATIO)
	if fill != null:
		mode = int(fill.fill_mode)
	var fit_scale := Vector2.ONE
	var fit_origin := Vector2.ZERO
	if mode == int(BlockFill.Mode.FILL):
		fit_scale = Vector2(vp_size.x / b.size.x, vp_size.y / b.size.y)
		fit_origin = -b.position * fit_scale
	elif mode == int(BlockFill.Mode.CENTER):
		fit_scale = Vector2(SKELETON_SS, SKELETON_SS)
		fit_origin = (vp_size - b.size * SKELETON_SS) * 0.5 - b.position * SKELETON_SS
	elif mode == int(BlockFill.Mode.ORIGINAL):
		fit_scale = Vector2(SKELETON_SS, SKELETON_SS)
		fit_origin = -b.position * SKELETON_SS
	else:
		# KEEP_MAX_RATIO（默认）；TILE 对骨骼没有意义，也按最大原比例处理
		var fit := minf(vp_size.x / b.size.x, vp_size.y / b.size.y)
		fit_scale = Vector2(fit, fit)
		fit_origin = (vp_size - b.size * fit) * 0.5 - b.position * fit
	_skel_wrapper.transform = Transform2D(0.0, fit_scale, 0.0, fit_origin)


# 把离屏画布整张贴进积木矩形（内容已按 fill_mode 排好并被画布裁切）。
func _draw_skeleton_fill(rect: Rect2) -> void:
	if _skel_ok and _skel_tex != null and _skel_viewport != null and is_instance_valid(_skel_viewport):
		if _desired_skeleton_vp_size() != _skel_vp_size:
			_queue_skeleton_rebuild()
		draw_texture_rect(_skel_tex, rect, false)
		return
	if _skel_viewport == null and not _skel_failed:
		_queue_skeleton_rebuild()   # 尚未建好：本帧先留空，避免闪一块纯色
		return
	draw_rect(rect, fill_color)


# ============ 瓦片（九宫格 / 网格）贴图绘制 ============
# 源图切成 N×M 格（N=tile_split.x, M=tile_split.y，≥2），按 tile_size 绘制到积木 rect。
# 两种布局：
#   A) 退化网格（N<3 或 M<3，如 2×2 / 2×3 / 3×2）：积木切为 N×M 等分区，每区恰好一张源格
#      铺满（无重复、无裁切）——对应「2×2 上半部分=上边、下半部分=剩余」「2×3/3×2 类似」。
#   B) 标准九宫格（N≥3 且 M≥3）：四角格固定满尺寸贴四角（角落维持不变），上/下/左/右边带由
#      对应边格平铺（末端无法密铺时裁切半张=不完全平铺），中部由内格平铺。顺序/随机取格生效。
# 瓦片尺寸：ABSOLUTE=像素；MULTIPLE=积木宽高×倍数（仅九宫格布局用，退化网格按等分区铺满）。
# 绘制入口：计算所有 (dest, src) 绘制规格，再交给 draw_texture_rect_region。
# 几何计算抽成 _build_tile_specs（纯函数、可在无 GPU 的 headless 下单元测试）。
func _draw_tiled(rect: Rect2, tex: Texture2D, src: BlockFill, tsize: Vector2) -> void:
	var N: int = maxi(1, int(src.tile_split.x))
	var M: int = maxi(1, int(src.tile_split.y))
	var cell_w: float = tsize.x / float(N)
	var cell_h: float = tsize.y / float(M)
	var cw: float
	var ch: float
	if src.tile_size_mode == BlockFill.TileSizeMode.MULTIPLE:
		cw = rect.size.x * maxf(0.0001, src.tile_size.x)
		ch = rect.size.y * maxf(0.0001, src.tile_size.y)
	else:
		cw = maxf(1.0, src.tile_size.x)
		ch = maxf(1.0, src.tile_size.y)
	var seed: int = int(get_instance_id()) & 0x7fffffff
	var order: int = int(src.tile_fill_order)
	var specs := _build_tile_specs(rect, N, M, cell_w, cell_h, cw, ch, order, seed)
	for s in specs:
		draw_texture_rect_region(tex, s.dest, s.src)


# 生成全部绘制规格（Array of {dest:Rect2, src:Rect2}）。
#   A) 退化网格（N<3 或 M<3）：积木切 N×M 等分区，每区一张源格铺满。
#   B) 九宫格（N≥3 且 M≥3）：四角固定满尺寸贴四角（不裁切），边带平铺（末端裁半张=不完全平铺），中部平铺。
func _build_tile_specs(rect: Rect2, N: int, M: int, cell_w: float, cell_h: float,
		cw: float, ch: float, order: int, seed: int) -> Array:
	var specs: Array = []
	if N < 3 or M < 3:
		_append_grid(specs, rect, N, M, cell_w, cell_h)
	else:
		_append_nine(specs, rect, N, M, cell_w, cell_h, cw, ch, order, seed)
	return specs


# A) 退化网格：等分区，每区一张源格。
func _append_grid(specs: Array, rect: Rect2, N: int, M: int, cell_w: float, cell_h: float) -> void:
	var zw: float = rect.size.x / float(N)
	var zh: float = rect.size.y / float(M)
	for j in M:
		for i in N:
			specs.append({
				"dest": Rect2(rect.position.x + float(i) * zw, rect.position.y + float(j) * zh, zw, zh),
				"src": Rect2(float(i) * cell_w, float(j) * cell_h, cell_w, cell_h),
			})


# B) 九宫格。
func _append_nine(specs: Array, rect: Rect2, N: int, M: int, cell_w: float, cell_h: float,
		cw: float, ch: float, order: int, seed: int) -> void:
	var left: float = rect.position.x
	var top: float = rect.position.y
	var right: float = rect.position.x + rect.size.x
	var bottom: float = rect.position.y + rect.size.y
	var mid_x0: float = left + cw
	var mid_x1: float = right - cw
	var mid_y0: float = top + ch
	var mid_y1: float = bottom - ch
	var mid_w: float = mid_x1 - mid_x0
	var mid_h: float = mid_y1 - mid_y0
	if mid_w < 0.0 or mid_h < 0.0:
		# 积木比 2 张瓦片还小：仅画四角（满尺寸，可能重叠），边/中无空间
		_append_corner(specs, Rect2(left, top, cw, ch), 0, 0, cell_w, cell_h)
		_append_corner(specs, Rect2(right - cw, top, cw, ch), N - 1, 0, cell_w, cell_h)
		_append_corner(specs, Rect2(left, bottom - ch, cw, ch), 0, M - 1, cell_w, cell_h)
		_append_corner(specs, Rect2(right - cw, bottom - ch, cw, ch), N - 1, M - 1, cell_w, cell_h)
		return
	# 四角（固定满尺寸，不裁切）
	_append_corner(specs, Rect2(left, top, cw, ch), 0, 0, cell_w, cell_h)
	_append_corner(specs, Rect2(right - cw, top, cw, ch), N - 1, 0, cell_w, cell_h)
	_append_corner(specs, Rect2(left, bottom - ch, cw, ch), 0, M - 1, cell_w, cell_h)
	_append_corner(specs, Rect2(right - cw, bottom - ch, cw, ch), N - 1, M - 1, cell_w, cell_h)
	# 上边（row0, col 1..N-2 平铺）/ 下边（row M-1）
	_append_edge_h(specs, Rect2(mid_x0, top, mid_w, ch), 0, 1, N - 2, cell_w, cell_h, cw, ch, order, seed, 0)
	_append_edge_h(specs, Rect2(mid_x0, bottom - ch, mid_w, ch), M - 1, 1, N - 2, cell_w, cell_h, cw, ch, order, seed, 1)
	# 左边（col0, row 1..M-2 平铺）/ 右边（col N-1）
	_append_edge_v(specs, Rect2(left, mid_y0, cw, mid_h), 0, 1, M - 2, cell_w, cell_h, cw, ch, order, seed, 2)
	_append_edge_v(specs, Rect2(right - cw, mid_y0, cw, mid_h), N - 1, 1, M - 2, cell_w, cell_h, cw, ch, order, seed, 3)
	# 中部（内格 rows 1..M-2 × cols 1..N-2 平铺）
	_center_cols = maxi(1, N - 2)
	_center_rows = maxi(1, M - 2)
	_append_center(specs, Rect2(mid_x0, mid_y0, mid_w, mid_h), cell_w, cell_h, cw, ch, order, seed)


func _append_corner(specs: Array, r: Rect2, ci: int, cj: int, cell_w: float, cell_h: float) -> void:
	specs.append({"dest": r, "src": Rect2(float(ci) * cell_w, float(cj) * cell_h, cell_w, cell_h)})


# 水平边带：从左到右平铺 source 行=row、列从 c0 起共 count 张；末端不足一张时裁切（不完全平铺）。
func _append_edge_h(specs: Array, r: Rect2, row: int, c0: int, count: int, cell_w: float, cell_h: float,
		cw: float, ch: float, order: int, seed: int, edge_id: int) -> void:
	if count <= 0:
		return
	var x: float = r.position.x
	var slot: int = 0
	while x < r.end.x - 0.001:
		var rem: float = r.end.x - x
		var tw: float = minf(cw, rem)
		var frac: float = tw / cw
		var pool_idx: int = slot % count if order == BlockFill.TileFillOrder.SEQUENTIAL else (absi(_tile_stable_rand(slot, edge_id, seed)) % count)
		var src_col: int = c0 + pool_idx
		specs.append({"dest": Rect2(x, r.position.y, tw, ch), "src": Rect2(float(src_col) * cell_w, float(row) * cell_h, cell_w * frac, cell_h)})
		x += cw
		slot += 1


# 垂直边带：从上到下平铺 source 列=col、行从 r0 起共 count 张；末端不足一张时裁切。
func _append_edge_v(specs: Array, r: Rect2, col: int, r0: int, count: int, cell_w: float, cell_h: float,
		cw: float, ch: float, order: int, seed: int, edge_id: int) -> void:
	if count <= 0:
		return
	var y: float = r.position.y
	var slot: int = 0
	while y < r.end.y - 0.001:
		var rem: float = r.end.y - y
		var th: float = minf(ch, rem)
		var frac: float = th / ch
		var pool_idx: int = slot % count if order == BlockFill.TileFillOrder.SEQUENTIAL else (absi(_tile_stable_rand(slot, edge_id, seed)) % count)
		var src_row: int = r0 + pool_idx
		specs.append({"dest": Rect2(r.position.x, y, cw, th), "src": Rect2(float(col) * cell_w, float(src_row) * cell_h, cell_w, cell_h * frac)})
		y += ch
		slot += 1


# 中部：平铺内格（起始列=1、行=1，周期 _center_cols × _center_rows）；末端裁切（x、y 均可）。
func _append_center(specs: Array, r: Rect2, cell_w: float, cell_h: float,
		cw: float, ch: float, order: int, seed: int) -> void:
	var y: float = r.position.y
	var tj: int = 0
	while y < r.end.y - 0.001:
		var rem_y: float = r.end.y - y
		var th: float = minf(ch, rem_y)
		var frac_y: float = th / ch
		var x: float = r.position.x
		var ti: int = 0
		while x < r.end.x - 0.001:
			var rem_x: float = r.end.x - x
			var tw: float = minf(cw, rem_x)
			var frac_x: float = tw / cw
			var ic: int
			var ir: int
			if order == BlockFill.TileFillOrder.SEQUENTIAL:
				ic = 1 + (ti % maxi(1, _center_cols))
				ir = 1 + (tj % maxi(1, _center_rows))
			else:
				ic = 1 + absi(_tile_stable_rand(ti, 7, seed)) % maxi(1, _center_cols)
				ir = 1 + absi(_tile_stable_rand(tj, 13, seed)) % maxi(1, _center_rows)
			specs.append({"dest": Rect2(x, y, tw, th), "src": Rect2(float(ic) * cell_w, float(ir) * cell_h, cell_w * frac_x, cell_h * frac_y)})
			x += cw
			ti += 1
		y += ch
		tj += 1


# 中部平铺周期（内格列数/行数），_append_nine 调用 _append_center 前赋值。
var _center_cols: int = 1
var _center_rows: int = 1


# 稳定伪随机（同 (a,b,seed) 必同值，范围覆盖 int；调用方取模）。
func _tile_stable_rand(a: int, b: int, seed: int) -> int:
	var h: int = (a * 73856093) ^ (b * 19349663) ^ (seed * 83492791)
	h = h ^ (h >> 13)
	h = h * 1274126177
	h = h ^ (h >> 16)
	return h


func absi(v: int) -> int:
	return v if v >= 0 else -v


# ============ 父/子级锚定（ID 绑定 + 位移同步）============
# 语义（本次约定，参考已废弃版本的父子级系统）：
#   - 一个积木最多一个父级，父级可有任意多个子级。
#   - 绑定关系用「积木 ID」表示（BlockManager 注册表查找），**不是** Node 节点父子关系 →
#     场景树保持扁平；删除父级不会连带删除子级，子级的 position 始终是场景坐标。
#   - 父级移动 → 把本帧位移 delta 原样下发给每个子级，子级一并位移（仅位置，不含旋转/缩放）。
#   - 子级移动 → 不影响父级（单向下行同步）。
#   - 子级被别的积木挡住时，只能走"能走的那一部分"（整段 → 单轴滑动 → 原地不动）；
#     即使父级仍在移动，两者的相对位置也会因阻挡而改变 —— 这是设计允许的行为，不做回追。
#   - 父级在碰撞判定里忽略「自己携带的整棵子树」（父级 + 其所有后代）：
#     自己带的东西不该把自己卡住。这同时解决了旧版"子级压在父级上方时，
#     父级想向上移动却被子级挡住"的特殊情况。
#   - 跟随开关：子级的「child_follow」标签（bind_child 会自动补上）；
#     删掉该标签即只保留绑定关系而不跟随位移。

const CHILD_SHIFT_STEP_PX: float = 8.0   # 子级被动位移的子步长度（与自主移动同量级，防穿透）
const CHILD_SHIFT_MAX_STEPS: int = 24    # 子级被动位移的子步数上限（防极端帧率下卡顿）
const BIND_CHAIN_MAX: int = 64           # 父子链深度上限（防环 / 防数据异常时死循环）

## 父级积木（null = 无父级）。只读：用 bind_parent() / unbind_parent() / set_parent_id() 修改。
var parent_block: Block = null

## 本积木的子级积木（内部列表；外部读用 get_child_blocks() / get_child_ids()）
var _child_blocks: Array[Block] = []

## 上一物理帧的全局位置：用于求「本帧位移 delta」并下发给子级
var _prev_global_pos: Vector2 = Vector2.ZERO


## 取当前生效的子级积木（只读副本）
func get_child_blocks() -> Array[Block]:
	var out: Array[Block] = []
	for c in _child_blocks:
		if is_instance_valid(c):
			out.append(c)
	return out


## 取子级 ID 列表（供属性面板 / 事件链读写）
func get_child_ids() -> Array[int]:
	var out: Array[int] = []
	for c in get_child_blocks():
		out.append(c.id)
	return out


## 取父级 ID（0 = 无父级）
func get_parent_id() -> int:
	if parent_block != null and is_instance_valid(parent_block):
		return parent_block.id
	return 0


## 把 p 绑为本积木的父级（若已有父级 → 先解绑）。返回是否成功。
func bind_parent(p: Block) -> bool:
	if p == null or not is_instance_valid(p):
		unbind_parent()
		return false
	if p == self:
		push_warning("[Block] bind_parent 拒绝：父级不能是自己 (id=%d)" % id)
		return false
	# 成环判据：p 若是「自己或自己的下游」，让 p 当自己的父级就会接成环
	if p._is_in_subtree_of(self):
		push_warning("[Block] bind_parent 拒绝成环：%d 位于 %d 的下游" % [p.id, id])
		return false
	unbind_parent()
	parent_block = p
	_prev_global_pos = global_position
	if not p._child_blocks.has(self):
		p._child_blocks.append(self)
	# 绑定即跟随：自动补上 child_follow 标签（可手动删除，以只保留绑定关系而不跟随）
	if not (BlockTags.CHILD_FOLLOW in _tags):
		var t: PackedStringArray = _tags
		t.append(BlockTags.CHILD_FOLLOW)
		tags = t
	return true


## 解除本积木的父级绑定（不递归影响自己的子级）
func unbind_parent() -> void:
	var p := parent_block
	parent_block = null
	if p != null and is_instance_valid(p):
		p._child_blocks.erase(self)


## 把 child 绑为本积木的子级（child 若已有父级 → 自动改绑；已在名下则视为幂等成功）。
func bind_child(child: Block) -> bool:
	if child == null or not is_instance_valid(child) or child == self:
		return false
	# 成环判据：自己若是「child 或 child 的下游」，把 child 挂到名下就会接成环
	if self._is_in_subtree_of(child):
		push_warning("[Block] bind_child 拒绝成环：%d 位于 %d 的下游" % [id, child.id])
		return false
	return child.bind_parent(self)


## 解除某个子级的绑定
func unbind_child(child: Block) -> void:
	if child == null:
		return
	_child_blocks.erase(child)
	if is_instance_valid(child) and child.parent_block == self:
		child.parent_block = null


## 按 ID 设父级（<=0 或找不到 → 解绑）。供属性面板 / 事件链使用。
func set_parent_id(pid: int) -> bool:
	if pid <= 0:
		unbind_parent()
		return true
	var p := _find_block_by_id(pid)
	if p == null:
		push_warning("[Block] set_parent_id: 找不到 ID=%d 的积木" % pid)
		return false
	return bind_parent(p)


## 按 ID 列表重设子级（全量覆盖；非法 / 自身 / 成环的 ID 会被跳过）
func set_child_ids(ids: Array) -> void:
	for c in _child_blocks.duplicate():
		unbind_child(c)
	for v in ids:
		var cid: int = int(v)
		if cid <= 0 or cid == id:
			continue
		var c: Block = _find_block_by_id(cid)
		if c == null:
			push_warning("[Block] set_child_ids: 找不到 ID=%d 的积木" % cid)
			continue
		bind_child(c)


## self 是否等于 root，或位于 root 的下游（沿 parent_block 上溯）。
## 用途：成环检测、碰撞豁免（判断"是否属于一起走的同一棵子树"）。
func _is_in_subtree_of(root: Block) -> bool:
	if root == null:
		return false
	var n: Block = self
	var guard: int = 0
	while n != null and is_instance_valid(n) and guard < BIND_CHAIN_MAX:
		if n == root:
			return true
		n = n.parent_block
		guard += 1
	return false


## 按 ID 查找积木实例（注册表里已释放的条目视为不存在）
func _find_block_by_id(bid: int) -> Block:
	if bid <= 0 or BlockManager == null:
		return null
	var b = BlockManager.get_block(bid)
	if is_instance_valid(b) and b is Block:
		return b
	return null


## 【兼容别名】旧的 Node 父子挂载写法 → 现改为 ID 绑定
func set_as_parent(child: Block) -> void:
	bind_child(child)


# ============ 父级 → 子级 位移同步 ============
# 每物理帧末：算本帧位移 delta，把 delta 原样下发给每个「跟随中」的子级。
# 注意：这里刻意**不更新** child._prev_global_pos —— 让它保留位移前的旧值，
#   这样子级自己的 _sync_children() 仍能把这段位移继续传给它的子级（孙级）。
func _sync_children() -> void:
	if _child_blocks.is_empty():
		return
	var delta: Vector2 = global_position - _prev_global_pos
	if delta.length() < 0.001:
		return
	for c in _child_blocks.duplicate():
		if not is_instance_valid(c):
			continue
		if not (BlockTags.CHILD_FOLLOW in c.tags):
			continue   # 子级没开 child_follow → 只保留绑定关系，不跟随位移
		_shift_child_by(c, delta)


## 把 child 按 delta 平移（大位移拆子步；每子步：整段 → 单轴滑动 → 停下）
## 只允许"穿透不变深"，因此子级绝不会被父级硬推进别的积木里；
## 被挡住时子级就少走一段，相对位置随之改变（设计允许）。
func _shift_child_by(child: Block, delta: Vector2) -> void:
	if delta.length() < 0.001:
		return
	var steps: int = clampi(int(ceil(delta.length() / CHILD_SHIFT_STEP_PX)), 1, CHILD_SHIFT_MAX_STEPS)
	var step: Vector2 = delta / float(steps)
	for _i in steps:
		if not is_instance_valid(child):
			return
		var origin: Vector2 = child.global_position
		if child._can_shift_to(origin + step, self):
			child.global_position = origin + step
			continue
		# 整步被挡 → 退化到单轴滑动（与积木自主移动的子步行为一致）
		var moved: bool = false
		if absf(step.x) > 0.01 and child._can_shift_to(Vector2(origin.x + step.x, origin.y), self):
			child.global_position = Vector2(origin.x + step.x, origin.y)
			moved = true
		var cur: Vector2 = child.global_position
		if absf(step.y) > 0.01 and child._can_shift_to(Vector2(cur.x, cur.y + step.y), self):
			child.global_position = Vector2(cur.x, cur.y + step.y)
			moved = true
		if not moved:
			return   # 这个方向走不通 → 剩余子步也不再尝试

# ============ 交互与物理（自 abandon 版迁移简化：拖动 / 重力 / 受控移动 / 跳跃）============
# 迁移自旧版 block.gd + main.gd 的移动逻辑（v0.1.25 定稿行为）；碰撞改为 OBB（随 rotation 旋转，SAT 解算）：
#   - 碰撞箱四角随本积木 rotation 旋转，物理碰撞/命中测试均与画面一致（批次103 引入 OBB/SAT）
#   - 碰撞条件：双方都含 "collision" 标签，且 collision_layer 集合有公共元素（至少一个相同才对撞）
#
# 常量（与旧版手感一致）
const MOVE_SPEED: float = 240.0             # 受控按住方向键的匀速速度（像素/秒）
const MOVE_DECAY_RATE: float = 1200.0       # 松手后速度线性衰减率（像素/秒²）
const JUMP_INITIAL_VELOCITY: float = 640.0  # 跳跃初速度（像素/秒）；h = v²/(2g)
const MOVE_SUBSTEPS: int = 4               # 位移子步数（防止高速穿透）
const MOVE_COLLISION_EPSILON: float = 0.05 # "恰好贴着"容差：小于此穿透深度视为可滑动
const FLOOR_VY_EPSILON: float = 0.5         # 竖直速度≈0 判定容差（在地面）
const MAX_JUMPS: int = 1                   # 跳数上限。改为 2 即启用二段跳（逻辑已预留）

# ---- 可滚动（标签 rollable）----
# 物理滚动：重心被底部「受支撑区间」托住 → 停滚（并回正姿态）；重心偏出区间 → 绕最近的
# 支撑缘翻/滚下去（碰撞箱随 rotation 真转）；完全悬空 → 自由下落 + 自转。
const ROLL_PROBE: float = 4.0             # 向下探测支撑的距离（像素）；> MOVE_COLLISION_EPSILON 才能探穿"恰好贴着"
const ROLL_ACCEL: float = 600.0           # 滚动水平加速度（像素/秒²）
const ROLL_MAX_SPEED: float = 360.0       # 滚动水平最大速度（像素/秒）
const ROLL_SLOPE_EPS: float = 2.0         # 左右支撑深度差超过该值（像素）判定为斜坡 → 朝更低侧真滚；否则视作平地稳定
const ROLL_SETTLE_SPEED: float = 4.0      # 矩形落地回正到「面朝下」的角速度（弧度/秒），越大回正越快

# ---- 运动参数（「积木运动」面板 / ui/block_motion_panel.gd）----
# 进一步细化受控移动：把原本写死的 MOVE_SPEED 拆成「每块可配的最大速度 + 加速度」。
#   can_fly           可飞行：**不受重力**（悬停），且可按住 W/↑ 上升、S/↓ 下降（仍需 controlled 标签）。
#   horiz_max_speed   水平最大速度（像素/秒）。非飞行时同时就是整体移动速度上限（斜向不叠加，同旧版）。
#   horiz_accel       水平加速度（像素/秒²）。★ <=0 视为「瞬时到位」（保留旧版手感，也是默认值）。
#   fly_up_max_speed  飞行上升最大速度（像素/秒）；飞行下降复用同一速度值。
#   fly_up_accel      飞行上升加速度（像素/秒²）。★ <=0 视为「瞬时到位」。
#   mass              质量（相对值，默认 1.0）。只作用于「可滚动」积木的惯性：
#                     越重 → 起步更慢、风阻影响更小、动量更足（驱动力与风阻按 1/mass 缩放）。
#                     ★ 地面摩擦**不**按质量缩放：库仑摩擦的减速度 = μ·g 与质量无关（批次 537）。
#                     1.0 时缩放系数恒为 1 → 旧手感不变；<=0 视为 1.0（防除零）。
# ★ 全部有默认值 → 存量积木 / 未带这些键的类型 JSON 行为完全不变。
@export var can_fly: bool = false
@export var horiz_max_speed: float = MOVE_SPEED
@export var horiz_accel: float = 0.0
@export var fly_up_max_speed: float = MOVE_SPEED
@export var fly_up_accel: float = 0.0
@export var mass: float = 1.0
# ---- 重力 / 滚动（「积木运动」面板；2026-10-23 起取代 gravity / rollable 标签）----
# gravity_enabled  是否受重力。未显式配置时按旧标签迁移（见 _init_legacy_motion_flags）。
# roll_enabled     是否可滚动。同上。
# free_roll        完全自由的滚动姿态：取消「翻到面朝下」的吸附与自纠正，
#                  允许任意角度静止；仍受重力与接触自然翻倒。
# roll_axis_offset 旋转轴 / 质心相对几何中心的局部偏移（像素，随 rotation 旋转）。
#                  ★ 它参与力矩（τ = m·g·r，r = 质心−支点）与自由自转中心，
#                  所以改变它会让积木的翻滚快慢、稳定姿态都不同。
@export var gravity_enabled: bool = false
@export var roll_enabled: bool = false
@export var free_roll: bool = false
@export var roll_axis_offset: Vector2 = Vector2.ZERO
# ---- 摩擦 / 风阻 / 弹性（「积木运动」面板；2026-10-23 批次 537）----
# ★ 思路来自 Flash 物理小游戏（Box2D 一路）：观感好坏取决于**能量有没有去处**。
# friction_coef  摩擦系数 μ。库仑摩擦 F = μ·N ⇒ 滑动减速度 = μ·g，
#                ★与质量无关（同材质轻重不同的箱子滑停距离一样，现实如此）。
#                μ=0 ≈ 冰面：只滑不翻、也停不下来；μ 大 ≈ 橡胶：一绊就翻。
#                μ 还吃得住坡度 → 浅坡上放着不动（静摩擦），坡够陡才开始下滑。
# air_drag       风阻（1/秒）：速度每帧 ×1/(1+drag·dt)，按 1/mass 放大（轻的更受影响）。
# restitution    弹性（恢复系数 0~0.9）：撞击法向速度按比例反弹；低于阈值不弹，
#                否则小角度来回弹 = 永远停不下来的抖动。
#                ★只对「可滚动」积木生效 —— 桌面图标不该弹。
# squash_amount   落地挤压幅度（0 = 关闭）：撞击把积木沿接触法线压扁到这个比例，
#                 再由弹簧回弹（并轻微过冲成拉伸）—— Flash 小游戏「Q 弹」的观感来源。
#                 ★纯视觉（只动 scale/offset），碰撞体、力矩、质心一律不受影响。
# squash_stiffness 回弹刚度（rad/s）：越大回得越快越"硬"，越小越"软糖"。
@export var friction_coef: float = 0.45
@export var air_drag: float = 0.15
@export var restitution: float = 0.2
@export var squash_amount: float = 0.25
@export var squash_stiffness: float = 22.0
# ---- 转动惯量（「积木运动」面板；2026-10-24 批次 541）----
# ★★ 538 及以前的转动方程把整块积木当成**集中在质心的一个质点**绕支点转
#   （α = g·r.x/|r|²、起翻 ω = v/|r|×1.35 的手调增益）→ 尺寸与质量都不进方程
#   → 大石块和小纸片翻起来一个样，这就是「生硬」的物理内核。
# inertia_enabled  计入转动惯量：α 的分母换成真回转半径²（薄板绕质心 + 平行轴到支点），
#                  起翻 ω 改成**对支点的角动量守恒**（ω = v·摩擦力臂/k²），
#                  圆件的滑移耦合 β 也按形状算（盘 0.5、环 1.0、椭圆随转角变）。
#                  ★ 关掉时逐位退回 538 的老手感（存量积木零影响）。
#                  开与关的观感差异是真实的：矮胖子被推只会滑、高瘦件一推就翻，
#                  大件起步明显更懒、翻一面耗时更长。
# inertia_value    手动转动惯量 I（单位：质量·像素²，绕自转轴）；0 = 按形状与尺寸自动算。
#                  ★ 填大 → 更难被拧起来（翻滚懒、打滑久）；填小 → 像纸片一碰就转。
@export var inertia_enabled: bool = false
@export var inertia_value: float = 0.0

# 显式配置标记：属性面板/类型 JSON 写入过新字段 → 不再从旧标签推导。
# 旧积木（只有 gravity / rollable 标签）在 _ready 时推导一次，保证存量行为不丢。
var _motion_toggles_explicit: bool = false

# ---- 命令移动（标签 commandable，「移到此处」）----
# 只做直线：每帧朝目标点取一小步，不做绕行 / 寻路（需求：现在做直线就行）。
# ★ 速度不再用独立常量，而是**复用「积木运动」面板的参数**（见 _command_velocity）：
#   · 可飞行 → 水平用 horiz_max_speed/horiz_accel，竖直用 fly_up_max_speed/fly_up_accel；
#   · 不可飞行 → 水平同样用 horiz_max_speed/horiz_accel，但**竖直只能靠跳跃**（见 _command_step）。
const COMMAND_ARRIVE_EPSILON: float = 1.0   # 抵达判定容差（像素）
const COMMAND_STUCK_FRAMES: int = 10        # 连续这么多帧没能靠近目标 → 判定走不通，结束命令
# 竖直容差：|dy| 小于它就认为"高度已对齐"，可以纯水平靠近（避免为了 0.3px 的高度差反复起跳）。
const COMMAND_VERTICAL_EPSILON: float = 2.0
# 跳跃冷却帧数：起跳后这么多帧内不再判起跳（一次跳跃的上升段大约 39 帧，冷却只防同帧重复触发）。
const COMMAND_JUMP_COOLDOWN: int = 6
# 不可飞行时的最大起跳尝试次数：超了仍没够到目标高度 → 判定"跳不上去"，结束命令。
# 不可飞行的积木**物理上无法悬停**：能到达的高度就是单跳射程 h = v²/(2g) ≈ 209px，
# 所以"目标比这更高"时只能反复尝试、最终诚实地放弃，而不是无限循环起跳。
const COMMAND_MAX_JUMPS: int = 6

# ---- 状态 ----
var _gravity_velocity: Vector2 = Vector2.ZERO  # 重力累积速度（vy<0 = 上升中）
var _move_velocity: Vector2 = Vector2.ZERO     # 受控移动速度（匀速/线性衰减）
var _roll_dir: float = 0.0                     # 可滚动：当前翻滚方向（+1 右 / -1 左 / 0 停稳）；跨帧保持，避免卡在边缘薄刃
var _spin: float = 0.0                       # 可滚动：角速度（弧度/秒）—— 倾倒/翻滚的角动量；空中保留（角动量守恒）
var _rb_mode: int = 0                        # 可滚动：刚体状态（RB_AIR 悬空 / RB_FLAT 边着地 / RB_TOPPLE 倾倒）
var _rb_slide: float = 0.0                   # 可滚动（矩形/三角）：沿支撑面切向的滑动速度（跨帧保持）
var _rb_pivot_i: int = -1                    # 可滚动（矩形/三角）：当前倾倒支点的顶点索引（跨帧保持，防支点跳变）
var _rb_target_rot: float = 0.0              # 可滚动（矩形/三角）：倾倒的目标姿态角（对齐到支撑面）
var _rb_target_valid: bool = false           # 目标姿态是否已计算
var _rb_target_pivot_i: int = -1             # 目标姿态对应的支点（支点变了要重算）
var _rb_grounded: bool = false               # 可滚动：本帧是否有支撑（悬空时禁止「滚动自转」）
var _rb_tumble: bool = false                 # 可滚动（矩形/三角）：受推力驱动的「平地主动翻滚」进行中
var _rb_tumble_speed: float = 0.0            # 主动翻滚结束时要保留的水平速度（像素/秒）
var _rb_orbit_pivot: Vector2 = Vector2.ZERO  # 上一帧绕着公转的支点（世界）——支点换了就要重新换算角动量，见批次 542
# ---- 批次 538：法向冲量 + 挤压回弹 ----
# _contact_impulse：本帧接触**吸收了多大的法向速度**（像素/秒）。
# ★★ 库仑摩擦的上限是 F ≤ μ·N，N 是法向**冲量**而不只是重力：
#   旧写法只给 μ·m·g·dt → 高速落地的球要花 14~35 帧才把 ω 拉起来（实测 0.23~0.58s 打滑），
#   就是用户说的「先落到底、顿一下才滚动」。把撞击那一份算进预算，落地那一帧就咬地起滚。
var _contact_impulse: float = 0.0
var _impulse_bank: float = 0.0                # 上一帧撞击冲量的「存款」（本帧仍悬空 → 摩擦没处花，留着）
var _squash: float = 0.0                     # 挤压弹簧的当前形变（+=压扁 / −=拉伸，无量纲）
var _squash_vel: float = 0.0                 # 形变速度（决定回弹快慢与过冲）
var _squash_normal: Vector2 = Vector2.UP     # 挤压方向（世界）= 最后一次接触的法线
var _is_dragging: bool = false                 # 正被鼠标拖动
var _drag_offset: Vector2 = Vector2.ZERO       # 按下时 鼠标→积木中心 的偏移
var _drag_layer_saved: bool = false            # 是否已备份「拖动前的碰撞图层」
var _pre_drag_collision_layer: PackedStringArray = PackedStringArray()  # 拖动前的碰撞图层（松开后恢复）
var _pending_drag: bool = false                 # 左键已按下且命中本积木、但位移未超阈值（还没真开始拖）
var _drag_press_pos: Vector2 = Vector2.ZERO     # 按下时的鼠标位置（用于判定位移是否超阈值）
# 位移阈值（像素）：按住后鼠标移动必须超过它才判定为「拖动」，否则就是「点击/双击」。
# 与 desktop.gd 的 DRAG_THRESHOLD 保持一致（Windows 系统即如此处理）。
const DRAG_THRESHOLD: float = 6.0
# 双击（按钮信号）判定：两次点击的间隔 ≤ DOUBLE_CLICK_MS、且两点距离 ≤ DRAG_THRESHOLD 才算一次双击，
# 用同一阈值判定位移，避免「双击」和「拖动」互相冲突（鼠标略动即记为拖动，屏蔽为双击）。
const DOUBLE_CLICK_MS: float = 500.0
var _last_click_time: float = -1.0            # 上一次"单击"时间（ticks_msec），<0 表示尚无
var _last_click_pos: Vector2 = Vector2.ZERO   # 上一次"单击"时的鼠标位置
var _on_floor: bool = false                    # 是否落地（底部有碰撞支撑）
var _jumps_used: int = 0                       # 已用跳数（落地清零；二段跳预留）
var _space_prev: bool = false                  # 空格上一帧状态（自维护按下边沿）
var _a_prev: bool = false                      # A/← 上一帧状态（自维护按下边沿 → 更新朝向）
var _d_prev: bool = false                      # D/→ 上一帧状态（自维护按下边沿 → 更新朝向）
# ---- 命令移动（标签 commandable）运行态 ----
var _command_active: bool = false              # 是否正在执行「移到此处」命令
var _command_target: Vector2 = Vector2.ZERO    # 命令目标点（积木中心的世界坐标）
var _command_stuck: int = 0                    # 连续"没能靠近目标"的帧数（用于放弃判定）
var _command_vel: Vector2 = Vector2.ZERO       # 命令移动当前速度（受运动参数约束，见 _command_step）
var _command_jump_cd: int = 0                  # 跳跃冷却帧数（起跳后短暂禁止再判起跳，避免同一帧连跳）
var _command_jumps: int = 0                    # 本次命令已起跳次数（不可飞行时用于"跳不上去就放弃"）
var _command_vert_done: bool = false           # 不可飞行 + 目标在上方：是否"到达过目标高度"（闩锁）

# ---- 检测标签（待检测_XXX → 检测到_XXX）的运行时状态 ----
# 检测者侧（本积木带 to_detect_XXX）：
#   _detect_prev[XXX] = { 被检测积木 id → true }，记录上一物理帧的检测结果，用于帧间差分。
# 被检测者侧（有别的积木带 to_detect_XXX 扫到了我）：
#   _detect_sources[XXX] = { 检测者 id → true }，**引用计数**语义 ——
#   同一帧可能有多个检测者给我加同一个 XXX 标签，必须等它们全部离开才能移除，
#   否则"A1、A2 都带 to_detect_X，我先离开 A1"会把标签错误地摘掉。
var _detect_prev: Dictionary = {}
var _detect_sources: Dictionary = {}

# 当前正在被拖动的积木（全局面保证同时只有一个拖动）
static var _dragging_block: Block = null

# ============ 受控状态 API（供右键菜单 / 属性面板 / 事件链调用）============
# 「受控状态」就是标签集合里的 `controlled` 元素（BlockTags.CONTROLLED）。
# 本积木一旦带该标签，就会在 _physics_step 里读取键盘：
#   WASD / 四个方向键 → 匀速移动（松手线性衰减滑行至停）
#   空格               → 起跳（需同时具备 gravity 标签，否则没有"跳起再落下"）
# 右键菜单（调试模式下）的「控制积木 / 解除控制」就是增删这个标签元素。
func is_controlled() -> bool:
	return BlockTags.CONTROLLED in _tags

## 写入受控状态：true = 向标签集合加入 controlled，false = 从集合移除。
## 幂等：重复调用不会产生重复元素。
func set_controlled(on: bool) -> void:
	var t: PackedStringArray = _tags
	var has: bool = t.has(BlockTags.CONTROLLED)
	if on and not has:
		t.append(BlockTags.CONTROLLED)
		tags = t          # 走 setter，同步文本框视图显隐
	elif (not on) and has:
		t.remove_at(t.find(BlockTags.CONTROLLED))
		tags = t


# ============ 朝向 API（供属性面板 / 事件链 / 脚本调用）============
# 值：FACING_RIGHT(1) / FACING_LEFT(-1)。set_facing 内部做值收敛（非左即右），并触重绘。
func set_facing(v: int) -> void:
	facing = v

func get_facing() -> int:
	return _facing

# 视觉是否应水平镜像。规则：
#   默认（无 fill_flip 标签）  ：朝左镜像，朝右正常。
#   带 fill_flip（填充反转）   ：朝右镜像，朝左正常。
# 即 flipped = (朝左) XOR (有 fill_flip 标签)。
func _should_flip_visual() -> bool:
	var flipped := _facing == FACING_LEFT
	if BlockTags.FILL_FLIP in _tags:
		flipped = not flipped
	return flipped


# 是否参与碰撞（标签 + 集合非空双重条件）
func _has_collision() -> bool:
	return (BlockTags.COLLISION in tags) and collision_layer.size() > 0

# 两个积木碰撞图层集合是否有公共元素（至少一个相同才对撞）
# ★ 参数**故意不做类型标注**：Godot 4.7 在运行期对「PackedStringArray 实参 → PackedStringArray 形参」
#   会偶发误报 "Cannot convert argument 2 from PackedStringArray to PackedStringArray"（属性经 export/赋值路径后
#   内部元素标记不一致），一旦抛出该错误，本函数返回 null → 冲突判定被跳过（碰撞静默失效），且每帧刷屏。
#   去掉形参类型即可规避（逻辑只用 `in`，对 Array / PackedStringArray 通用）。
func _collision_layers_intersect(a, b) -> bool:
	for layer in a:
		if layer in b:
			return true
	return false

# 以 pos 为中心的 AABB（忽略旋转的近似）。
# ★ 仅用于「检测区」(detect) 这类**不要求**碰撞体旋转的语义；物理碰撞/命中测试已改用 OBB（见下）。
func _aabb_at(pos: Vector2) -> Rect2:
	return Rect2(pos.x - width / 2.0, pos.y - height / 2.0, width, height)

# ============ 朝向矩形（OBB）碰撞：碰撞箱随 rotation 旋转 ============
# 本积木此前（批次≤101）碰撞用「未旋转 AABB 近似」，旋转只改渲染、碰撞箱不跟着转。
# 现改为 OBB（分离轴定理 SAT）：碰撞箱四角随本积木 rotation 旋转，
# 物理碰撞/命中测试/可滚动支撑判定全部基于 OBB，旋转后碰撞箱与画面一致。

# 形状的横向 / 纵向「半轴」（用于滚动与支撑探测；圆/椭圆按各自半径）。
func _shape_radius_x() -> float:
	var hw: float = maxf(0.0, width / 2.0)
	match shape:
		Shape.CIRCLE:
			return minf(hw, maxf(0.0, height / 2.0))
		_:
			return hw


func _shape_radius_y() -> float:
	var hh: float = maxf(0.0, height / 2.0)
	match shape:
		Shape.CIRCLE:
			return minf(maxf(0.0, width / 2.0), hh)
		_:
			return hh


# 本地空间（中心原点、未旋转）形状多边形；shrink 把各半径内缩。
# 圆 / 椭圆用 24 边形近似（凸多边形 → SAT 与点包含直接可用）。
func _shape_local_polygon(shrink: float = 0.0) -> PackedVector2Array:
	var hw: float = maxf(0.0, width / 2.0 - shrink)
	var hh: float = maxf(0.0, height / 2.0 - shrink)
	var pts := PackedVector2Array()
	match shape:
		Shape.CIRCLE:
			var r: float = minf(hw, hh)
			if r <= 0.0:
				pts.append(Vector2.ZERO)
				return pts
			var n: int = 24
			for i in range(n):
				var a: float = TAU * float(i) / float(n)
				pts.append(Vector2(cos(a) * r, sin(a) * r))
		Shape.ELLIPSE:
			if hw <= 0.0 or hh <= 0.0:
				pts.append(Vector2.ZERO)
				return pts
			var n2: int = 24
			for i in range(n2):
				var a2: float = TAU * float(i) / float(n2)
				pts.append(Vector2(cos(a2) * hw, sin(a2) * hh))
		Shape.TRI_ISOSCELES, Shape.TRI_EQUILATERAL, Shape.TRI_RIGHT:
			pts = _tri_local_pts(hw, hh)
		_:
			pts.append(Vector2(hw, hh))
			pts.append(Vector2(-hw, hh))
			pts.append(Vector2(-hw, -hh))
			pts.append(Vector2(hw, -hh))
	return pts


# 三角形本地顶点（先按「顶点朝上」构造），再按 shape_dir 旋转 90° 的整数倍。
func _tri_local_pts(hw: float, hh: float) -> PackedVector2Array:
	var base := PackedVector2Array()
	if shape == Shape.TRI_RIGHT:
		# 直角在左下：左上、左下、右下
		base.append(Vector2(-hw, -hh))
		base.append(Vector2(-hw, hh))
		base.append(Vector2(hw, hh))
	else:
		var apex_y: float = -hh
		var base_y: float = hh
		if shape == Shape.TRI_EQUILATERAL:
			# 以宽为边长 → 高 = sqrt(3) * hw；竖直居中放进包围盒
			var h_eq: float = sqrt(3.0) * hw
			apex_y = -h_eq * 0.5
			base_y = h_eq * 0.5
		# 等腰 / 等边：顶点朝上、底边朝下
		base.append(Vector2(0.0, apex_y))
		base.append(Vector2(hw, base_y))
		base.append(Vector2(-hw, base_y))
	var dir: int = int(shape_dir) % 4
	if dir != 0:
		var ang: float = TAU * float(dir) / 4.0
		var c: float = cos(ang)
		var s: float = sin(ang)
		for i in range(base.size()):
			var v: Vector2 = base[i]
			base[i] = Vector2(v.x * c - v.y * s, v.x * s + v.y * c)
	return base


# 世界空间形状多边形：本地形状 → 绕中心旋转 rotation → 平移到 pos。
# shrink>0 时内缩每侧（用于「恰好贴着」容差）。
func _shape_polygon(pos: Vector2, shrink: float = 0.0) -> PackedVector2Array:
	var local := _shape_local_polygon(shrink)
	var c: float = cos(rotation)
	var s: float = sin(rotation)
	var out := PackedVector2Array()
	for l in local:
		out.append(pos + Vector2(l.x * c - l.y * s, l.x * s + l.y * c))
	return out


# 中心 pos 处的碰撞多边形（世界坐标）——SAT / 命中 / 支撑全部经此。
# ★ 名称沿用 _obb_corners（历史上仅矩形四角），现按 shape 返回 N 个顶点；
#   所有调用方都只把它喂给 _sat_overlap / _penetration_at，不假设恰好 4 个点。
func _obb_corners(pos: Vector2, shrink: float = 0.0) -> PackedVector2Array:
	return _shape_polygon(pos, shrink)


# 点 p 是否落入中心 pos 处的形状内（随 rotation 旋转；形状感知）。
func _obb_contains_point(pos: Vector2, p: Vector2) -> bool:
	var d := p - pos
	var c: float = cos(-rotation)
	var s: float = sin(-rotation)
	var lx := d.x * c - d.y * s
	var ly := d.x * s + d.y * c
	match shape:
		Shape.CIRCLE:
			var r: float = minf(width / 2.0, height / 2.0)
			return (lx * lx + ly * ly) <= r * r
		Shape.ELLIPSE:
			var rx: float = maxf(0.0001, width / 2.0)
			var ry: float = maxf(0.0001, height / 2.0)
			return (lx * lx) / (rx * rx) + (ly * ly) / (ry * ry) <= 1.0
		Shape.TRI_ISOSCELES, Shape.TRI_EQUILATERAL, Shape.TRI_RIGHT:
			return _point_in_polygon(Vector2(lx, ly), _shape_local_polygon())
		_:
			return absf(lx) <= width / 2.0 and absf(ly) <= height / 2.0


# 射线法点在多边形内（凸/凹通用）。
func _point_in_polygon(p: Vector2, poly: PackedVector2Array) -> bool:
	var n: int = poly.size()
	if n < 3:
		return false
	var inside := false
	var j: int = n - 1
	for i in range(n):
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[j]
		if ((a.y > p.y) != (b.y > p.y)) and (p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x):
			inside = not inside
		j = i
	return inside

# 多边形在轴上的投影区间 [min, max]（Vector2.x=min, .y=max）
func _project_range(poly: PackedVector2Array, axis: Vector2) -> Vector2:
	var mn := INF
	var mx := -INF
	for v in poly:
		var p := v.x * axis.x + v.y * axis.y
		mn = minf(mn, p)
		mx = maxf(mx, p)
	return Vector2(mn, mx)

func _poly_center(poly: PackedVector2Array) -> Vector2:
	var sum := Vector2.ZERO
	for v in poly:
		sum += v
	return sum / float(poly.size())

# SAT 重叠检测（两个 OBB，各 4 角点）。返回 Dictionary：
#   { "overlap": bool, "axis": Vector2, "depth": float }
# axis 从 a 指向 b（把 a 沿 axis 推出即可分离）；depth = 最小穿透深度（0 = 刚好接触/不重叠）。
func _sat_overlap(a: PackedVector2Array, b: PackedVector2Array) -> Dictionary:
	var best_depth := INF
	var best_axis := Vector2.ZERO
	var axes := PackedVector2Array()
	# 两个矩形的边法线（各 4 条，平行边重复无妨）；显式 Vector2 类型避免弱类型推断报错
	for i in range(a.size()):
		var p1: Vector2 = a[i]
		var p2: Vector2 = a[(i + 1) % a.size()]
		var edge := p2 - p1
		var ln := edge.length()
		if ln < 0.0001:
			continue
		axes.append(Vector2(-edge.y, edge.x) / ln)
	for i in range(b.size()):
		var p1: Vector2 = b[i]
		var p2: Vector2 = b[(i + 1) % b.size()]
		var edge := p2 - p1
		var ln := edge.length()
		if ln < 0.0001:
			continue
		axes.append(Vector2(-edge.y, edge.x) / ln)
	for axis in axes:
		var ra := _project_range(a, axis)
		var rb := _project_range(b, axis)
		var o := minf(ra.y, rb.y) - maxf(ra.x, rb.x)
		if o <= 0.0:
			return { "overlap": false, "axis": Vector2.ZERO, "depth": 0.0 }
		if o < best_depth:
			best_depth = o
			var ca := _poly_center(a)
			var cb := _poly_center(b)
			var dd := cb - ca
			best_axis = axis if dd.dot(axis) >= 0.0 else -axis
	return { "overlap": true, "axis": best_axis, "depth": best_depth }

# 以 pos 为中心的 OBB 与 other 的 OBB 的重叠深度（0 = 未重叠），基于 SAT。
func _penetration_at(pos: Vector2, other: Block) -> float:
	var r := _sat_overlap(_obb_corners(pos), other._obb_corners(other.global_position))
	return float(r["depth"]) if bool(r["overlap"]) else 0.0

# 判断能否移动到 target（绝对判据：对任一积木 OBB 重叠即阻挡）。
# 碰撞箱随 rotation 旋转（OBB/SAT）；my 盒缩边 MOVE_COLLISION_EPSILON 实现"恰好贴着可滑动"。
# 例外：**自己携带的子树**不算障碍物（同旧逻辑）。
func _can_move_to(target: Vector2, shrink: float = MOVE_COLLISION_EPSILON) -> bool:
	if not _has_collision():
		return true
	var tree := get_tree()
	if tree == null:
		return true
	var my := _obb_corners(target, shrink)
	var my_scene: Node = _scene_of()
	for other in tree.get_nodes_in_group("block"):
		# ★ 先 is_instance_valid 再 `is Block`：组里可能残留已释放节点。
		if not is_instance_valid(other) or other == self or not (other is Block):
			continue
		var ob: Block = other
		# ★★ 同场景闸门：只有同一归属的积木才互相碰撞阻挡。
		if ob._scene_of() != my_scene:
			continue
		if ob._is_in_subtree_of(self):
			continue
		if not ob._has_collision():
			continue
		if not _collision_layers_intersect(collision_layer, ob.collision_layer):
			continue
		# 缩边后 OBB 相交测试 → 阻挡
		if bool(_sat_overlap(my, ob._obb_corners(ob.global_position))["overlap"]):
			return false
	return true

# 判断"被父级带动、平移到 target"是否可行（参考废弃版 v0.1.41 的增量判据）。
# 与 _can_move_to 的绝对判据不同：这里只要求「对任何积木的穿透不得比现在更深」，
#   从而允许子级贴着接触面滑动，又绝不会更深地挤进别人身体里（不把别人顶走）。
# carried_root: 本次位移的根（父级）。整棵子树（父级 + 其所有后代）都不算障碍物 ——
#   它们是"一起走"的，把它们当障碍会让父级/子级被自己带的东西卡住。
func _can_shift_to(target: Vector2, carried_root: Block = null) -> bool:
	if not _has_collision():
		return true
	var tree := get_tree()
	if tree == null:
		return true
	var my_scene: Node = _scene_of()
	for other in tree.get_nodes_in_group("block"):
		# ★ 先 is_instance_valid 再 `is Block`（同 _can_move_to）。
		if not is_instance_valid(other) or other == self or not (other is Block):
			continue
		var ob: Block = other
		# ★★ 同场景闸门（同 _can_move_to）：跨场景的积木不参与碰撞阻挡。
		if ob._scene_of() != my_scene:
			continue
		if carried_root != null and ob._is_in_subtree_of(carried_root):
			continue
		if not ob._has_collision():
			continue
		if not _collision_layers_intersect(collision_layer, ob.collision_layer):
			continue
		var pen_now: float = _penetration_at(global_position, ob)
		var pen_new: float = _penetration_at(target, ob)
		if pen_new > pen_now + MOVE_COLLISION_EPSILON:
			return false
	return true

# ============ 对外移动 API（供事件链 / 脚本移动积木）============
## 尝试按 offset 平移本积木（走碰撞校验，与受控移动同一套判据）。
## 返回 Dictionary：{ "moved_x": bool, "moved_y": bool, "blocked_y": bool }
## 注意：父级在判定里会忽略「自己携带的子树」，所以父级移动不会被自己的子级挡住。
func move_by(offset: Vector2) -> Dictionary:
	return _try_move(offset)

# ============ 命令移动 API（供右键菜单「移到此处」/ 事件链 / 脚本调用）============
## 本积木是否带「可命令」标签（右键菜单据此决定要不要显示「移到此处」）
func is_commandable() -> bool:
	return BlockTags.COMMANDABLE in _tags

## 下发「移到此处」命令：之后每物理帧沿**直线**朝 target（世界坐标 = 积木中心）前进。
## 返回 true = 命令已被接受；false = 本积木不带「可命令」标签，命令被忽略。
## ★ 重复下令 = 直接覆盖旧目标（不做"先到旧点再去新点"的排队）。
func command_move_to(target: Vector2) -> bool:
	if not is_commandable():
		return false
	_command_target = target
	_command_active = true
	_command_stuck = 0
	_command_vel = Vector2.ZERO
	_command_jump_cd = 0
	_command_jumps = 0
	_command_vert_done = false
	return true

## 取消当前命令移动：积木就地停下，随后恢复重力 / 受控键盘输入。
## 抵达目标、被墙夹住走不动、开始拖动，都会自动走到这里。
func cancel_command_move() -> void:
	_command_active = false
	_command_stuck = 0
	_command_vel = Vector2.ZERO
	_command_jump_cd = 0
	_command_jumps = 0
	_command_vert_done = false

## 是否正在执行命令移动
func is_command_moving() -> bool:
	return _command_active

## 当前命令目标点（未在下令中时返回本积木当前位置）
func get_command_target() -> Vector2:
	return _command_target if _command_active else global_position

# ============ 行为系统移动 API（绕过 commandable 标签闸门）============
## 行为系统驱动移动：机制与 command_move_to 完全相同（复用 _command_step 直线趋近 + 碰撞校验），
## 但不要求本积木带 commandable 标签 —— 让「行为 / 巡逻」能驱动任意积木自主移动。
## 重复调用 = 直接覆盖旧目标（不做排队）。
func behavior_move_to(target: Vector2) -> void:
	_command_target = target
	_command_active = true
	_command_stuck = 0
	_command_vel = Vector2.ZERO
	_command_jump_cd = 0
	_command_jumps = 0
	_command_vert_done = false

## 行为系统是否正在驱动移动（与 is_command_moving 共用同一标志位 _command_active）
func is_behavior_moving() -> bool:
	return _command_active

# 尝试按 offset 位移移动（4 子步 + 单轴滑动），返回各轴移动/阻挡结果
# 返回 Dictionary：{ "moved_x": bool, "moved_y": bool, "blocked_y": bool }
#
# ★ 关键：单轴滑动后 **不能 break**。
#   若 break，则"站在地面上横向移动"退化成每帧只走 1 个子步 = 1/4 速度
#   （实测 20 帧仅 19px，而 MOVE_SPEED=240 应为 80px）：
#   因为合成位移里含重力分量 vy>0，整步会被脚下的地面判定为阻挡，
#   于是每帧都走"单轴滑动"分支并 break，剩下 3 个子步被丢弃。
#   改为 continue 后，单轴走通的那一帧会顺带把重力清零，
#   其余子步照常推进 → 贴地跑动 / 贴墙滑动都是完整的 MOVE_SPEED。
func _try_move(offset: Vector2) -> Dictionary:
	var res: Dictionary = { "moved_x": false, "moved_y": false, "blocked_y": false }
	if offset.length() < 0.001:
		return res
	var step: Vector2 = offset / float(MOVE_SUBSTEPS)
	for _i in MOVE_SUBSTEPS:
		if step.length() < 0.001:
			break
		var target: Vector2 = global_position + step
		if _can_move_to(target):
			global_position = target
			if absf(step.x) > 0.01:
				res["moved_x"] = true
			if absf(step.y) > 0.01:
				res["moved_y"] = true
			continue
		# 整步被挡 → 单轴尝试（贴墙滑动）
		var y_ok := false
		if absf(step.y) > 0.01:
			var y_only := Vector2(global_position.x, global_position.y + step.y)
			if _can_move_to(y_only):
				global_position = y_only
				y_ok = true
				res["moved_y"] = true
			else:
				res["blocked_y"] = true
				_gravity_velocity.y = 0.0   # 竖直被挡 → 清零重力速度（vy 归 0）
		var x_ok := false
		if absf(step.x) > 0.01:
			var x_only := Vector2(global_position.x + step.x, global_position.y)
			if _can_move_to(x_only):
				global_position = x_only
				x_ok = true
				res["moved_x"] = true
			else:
				_gravity_velocity.x = 0.0
		# 两轴都走不通（真被墙夹住）→ 后面的子步也没有意义，提前收工
		if not y_ok and not x_ok:
			break
	return res

# ---- 命令移动的单帧推进（「移到此处」）----
# 位移/速度**全部走「积木运动」面板的参数**（horiz_* / fly_up_*），不再用独立常量。
#
# 两种模式（由 can_fly 标签/字段决定）：
#   ① 可飞行（can_fly）：两轴独立贴近目标 —— 与受控移动同一套加速模型（加速度 <=0 即瞬时到位），
#      所以"往上飞"就是普通的竖直移动。
#   ② 不可飞行：**水平照常走；竖直目标是靠跳跃达成的**（需求原文）。因为不可飞的积木竖直方向
#      只有重力和跳跃两种来源，直接"向上位移"是作弊 —— 会穿过墙/无视重力。做法：
#        · 目标在**上方**（dy < -容差）：站在地面就起跳（_try_jump），空中继续按水平速度靠近；
#        · 目标在**下方**：交给重力自然下落即可（水平照常）；
#        · 已经跳了但落点不够 → 落地后再次起跳（受 COMMAND_JUMP_COOLDOWN 限流，不会连跳一帧一次）。
#
# 结束条件（三者任一）：
#   ① 抵达 —— 水平对齐（|dx| ≤ 容差）且竖直达成；
#      · 可飞行：竖直 = |dy| ≤ 容差（能精确悬停）。
#      · 不可飞行 + 目标在上方：竖直 = **到达过目标高度**（闩锁 _command_vert_done）。
#        ★ 不可飞行的积木物理上无法悬停 —— 跳过去只会在最高点掠过再落回，
#          所以"到过该高度"就是这类积木能做到的极限，判它抵达（否则永远差一点）。
#      · 不可飞行 + 目标不在上方：竖直 = |dy| ≤ 容差（靠重力落到目标高度）。
#   ② 跳不上去 —— 不可飞行且起跳次数超过 COMMAND_MAX_JUMPS 仍没够到目标高度。
#   ③ 走不通 —— 连续 COMMAND_STUCK_FRAMES 帧没能让"到目标的距离"变小。
#      ★ 起跳判定必须先于 stuck 计数，且**起跳当帧不计 stuck**
#        （否则会在墙角处因反复起跳被误判为走不通而提前结束）。
#      ★ 不可飞行时**空中帧一律不计 stuck**：下落段天生"没能靠近"，
#        照常计数会在落地前就攒满阈值，把"跳第二下"提前掐死。
func _command_step(delta: float) -> void:
	var to_target: Vector2 = _command_target - global_position
	var dx: float = to_target.x
	var dy: float = to_target.y
	var dist: float = to_target.length()

	if _command_jump_cd > 0:
		_command_jump_cd -= 1

	# ---- 抵达判定（必须在移动之前判：上一帧结束时若已达成，本帧不再多走一步）----
	var x_ok: bool = absf(dx) <= COMMAND_ARRIVE_EPSILON
	var y_ok: bool
	if can_fly:
		y_ok = absf(dy) <= COMMAND_ARRIVE_EPSILON
	elif dy < -COMMAND_VERTICAL_EPSILON:
		# 不可飞行 + 目标在上方：到达过目标高度即算竖直达成（闩锁，一旦成立不再失效）
		if global_position.y <= _command_target.y + COMMAND_ARRIVE_EPSILON:
			_command_vert_done = true
		y_ok = _command_vert_done
	else:
		y_ok = absf(dy) <= COMMAND_ARRIVE_EPSILON
	if x_ok and y_ok:
		cancel_command_move()
		return

	# 目标方向（单位向量）；dist 极小的情况上面已经判过了
	var dir: Vector2 = to_target / dist if dist > 0.001 else Vector2.ZERO
	var jumped_this_frame := false

	# ---- ① 可飞行：两轴独立趋近（复用运动参数）----
	if can_fly:
		var tvx: float = signf(dir.x) * horiz_max_speed if absf(dir.x) > 0.001 else 0.0
		_command_vel.x = move_toward(_command_vel.x, tvx, horiz_accel * delta) if horiz_accel > 0.0 else tvx
		var tvy: float = signf(dir.y) * fly_up_max_speed if absf(dir.y) > 0.001 else 0.0
		_command_vel.y = move_toward(_command_vel.y, tvy, fly_up_accel * delta) if fly_up_accel > 0.0 else tvy
	else:
		# ---- ② 不可飞行：竖直靠跳跃 ----
		# 水平：按 horiz_max_speed / horiz_accel 趋近（与受控移动同一模型）
		var tvx2: float = signf(dir.x) * horiz_max_speed if absf(dir.x) > 0.001 else 0.0
		_command_vel.x = move_toward(_command_vel.x, tvx2, horiz_accel * delta) if horiz_accel > 0.0 else tvx2
		# 竖直：只保留重力速度（由本函数下方的重力段累积），命令自己不产生向上的速度
		_command_vel.y = 0.0
		# 需要升高的高度（负 = 目标在上方）
		if dy < -COMMAND_VERTICAL_EPSILON and _command_jump_cd == 0:
			if _command_jumps >= COMMAND_MAX_JUMPS:
				# 试了这么多次还是够不到 → 诚实放弃（不要无限起跳）
				print("[Block] id=%d 命令移动结束（跳不上去，目标高 %.0fpx 超出单跳射程，剩余 %.1fpx）"
					% [id, -dy, dist])
				cancel_command_move()
				return
			# 目标在上方 → 尝试起跳。落地才跳得起来，空中 _try_jump 会自己拒绝。
			if _try_jump():
				jumped_this_frame = true
				_command_jumps += 1
				_command_jump_cd = COMMAND_JUMP_COOLDOWN
				# 起跳的向上初速度已写入 _gravity_velocity，后续交给下方重力段累积

	# 水平位移由命令驱动；竖直位移由命令（飞行）或重力/跳跃（不可飞）驱动。
	# ★ 走 _try_move 而不是直接改 global_position：碰撞校验照旧生效。
	_try_move(_command_vel * delta)

	# ★★ 不可飞行时补跑重力：**必须放在 stuck 判定之前**，且并入本函数（不能留在 _physics_step）。
	#   否则竖直目标（纯上升）会出现：本帧命令的水平位移为 0 → 位置没变 → 判定"没能靠近"
	#   → 每帧都 stuck+1 → 10 帧后命令被误判为"走不通"而提前结束。
	#   实测症状：起跳后只升 ~100px（= 10 帧 × 9px/帧）就停在半空，永远到不了 150px 的目标。
	#   把重力位移并进命令帧内，stuck 判据看的才是"本帧所有位移落定后"的距离。
	if not can_fly and gravity_enabled:
		var g: float = ProjectSettings.get_setting("physics/2d/default_gravity", 980.0)
		_gravity_velocity.y += g * delta
		# ★★ 必须**先留档 vy** 再调 _try_move：_try_move 内部在竖直被挡时会
		#   `_gravity_velocity.y = 0.0`（见其"竖直被挡 → 清零重力速度"分支），
		#   所以调用后 `_gravity_velocity.y > 0.0` 永远为假 → 落地判定永不成立
		#   → _on_floor 恒为 false → "空中不计 stuck"把命令卡成永动机（永远不会结束也永远不跳第二下）。
		#   实测症状：G 段落回 y=2955 后 vy=0、on_floor 却始终 false，命令挂死。
		var vy_before: float = _gravity_velocity.y
		var res_g := _try_move(_gravity_velocity * delta)
		if bool(res_g["blocked_y"]) and vy_before > 0.0:
			_on_floor = true
			_gravity_velocity.y = 0.0
		elif bool(res_g["moved_y"]):
			_on_floor = false

	# 移动后再判一次"是否已掠过目标"：不可飞行的上升/下落速度低时单帧位移小，
	# 只在帧首判可能整帧跨过目标高度却两侧都不在容差内（上升 9px/帧、容差 1px）。
	if not can_fly and dy < -COMMAND_VERTICAL_EPSILON:
		if global_position.y <= _command_target.y + COMMAND_ARRIVE_EPSILON:
			_command_vert_done = true
		if x_ok and _command_vert_done:
			cancel_command_move()
			return

	# stuck 计数：本帧确实靠近了目标才清零（起跳当帧不算"没能靠近"，见函数头注释）
	#
	# ★★ 不可飞行时**空中帧一律不计 stuck**：
	#   跳跃是抛物线 —— 过了最高点后必然离目标越来越远（"没能靠近"），
	#   若照常计数，上升后的下落段会攒满 COMMAND_STUCK_FRAMES，
	#   于是"跳第二下"还没等到落地就被判成"走不通"而提前结束。
	#   实测症状：目标 300px（单跳射程 ~209px）只跳了 1 次就报"被阻挡"。
	#   只在地上判 stuck，才等价于"站着走不动了"这个真正该放弃的语义。
	var airborne: bool = (not can_fly) and (not _on_floor)
	var left: float = (_command_target - global_position).length()
	if left < dist - 0.01 or jumped_this_frame or airborne:
		_command_stuck = 0
	else:
		_command_stuck += 1
		if _command_stuck >= COMMAND_STUCK_FRAMES:
			print("[Block] id=%d 命令移动结束（被阻挡，剩余 %.1fpx）" % [id, left])
			cancel_command_move()

# UI 是否正在接收键盘输入（如属性面板的输入框）→ 是则跳过受控移动/跳跃
func _ui_has_focus() -> bool:
	var vp := get_viewport()
	return vp != null and vp.gui_get_focus_owner() != null

func _physics_process(delta: float) -> void:
	_physics_step(delta)
	# 父级 → 子级 位移同步。必须在更新 _prev_global_pos 之前算 delta，
	# 且必须放在所有提前 return 之外（拖动分支也会 return）。
	_sync_children()
	# 检测标签扫描：放在本帧位移（含子级同步位移）全部落定之后，
	# 保证「谁在谁里面」用的是最终位置。没有 to_detect_* 标签的积木在此几乎零开销。
	_detect_scan()
	# 镂空遮罩(cutout)：打洞画布是子节点，随父节点移动自动生效，无需通知任何积木重绘
	_prev_global_pos = global_position


func _physics_step(delta: float) -> void:
	# 视觉弹簧先走一步（任何分支都要跑，否则拖动/命令期间会停在半扁状态）
	_squash_step(delta)
	# ★ 取「上一帧接触吸收掉的法向速度」作为本帧摩擦预算的一部分（见 _fric_impulse_budget）。
	#   ★ 加上 _impulse_bank：撞击那一帧常常还在「SAT 已停住、支撑面还没贴实」的空档里
	#     （538 逐帧实测：落地帧 blocked_y 收了 784px/s，下一帧 _rb_grounded 仍为 false）
	#     → 唯一一笔大额预算当场作废，之后只能按 μ·g·dt 一帧帧磨 = 「顿一下才滚」。
	#     悬空时把它存起来（逐帧衰减），接触一恢复立刻继续领取。
	var impact: float = maxf(_contact_impulse, _impulse_bank)
	_contact_impulse = 0.0
	_impulse_bank = 0.0
	# ---- 待判定拖动：按下后位移未达阈值 ---- 
	if _pending_drag:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_pending_drag = false                      # 未拖动就松开 → 记为一次点击
			_register_click()                          # 连续两次靠近的点击 → 发按钮信号
		elif get_global_mouse_position().distance_to(_drag_press_pos) > DRAG_THRESHOLD:
			_pending_drag = false                      # 位移超阈值 → 开始拖动（仅可拖动积木）
			# ★★ 按**按下点**复核一次是否被镂空遮罩盖住：若按住期间有更高层的覆盖积木盖上来
			#   （如窗口挪到此处），就不转拖动 —— 与 _unhandled_input 的按下闸门同一判据，
			#   且用固定的按下点而非移动中的光标，避免"拖到一半忽然中断"的抖动。
			if BlockTags.DRAGGABLE in tags and not is_point_covered(_drag_press_pos):
				_start_drag()
		return

	# ---- 拖动中 ----
	if _is_dragging:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_stop_drag()
		else:
			var target := get_global_mouse_position() + _drag_offset
			if _can_move_to(target):
				global_position = target
			_gravity_velocity = Vector2.ZERO
		return

	# ---- 命令移动（标签 commandable，右键菜单「移到此处」）----
	# 优先级高于受控键盘输入：命令期间由命令驱动位移。
	# 否则"同时带 gravity / controlled 的积木"会被键盘拽着走弧线、永远到不了目标点。
	#
	# ★ 竖直方向的处理分两种（2026-09-29 改）：
	#   · 可飞行 → 命令自己产生竖直速度（往上飞），所以清空重力速度。
	#   · 不可飞行 → **竖直只能靠跳跃/重力**：不能清空重力速度（否则跳起来后没有重力回落），
	#     由 _command_step 里的 _try_jump() 负责"往上"、它自己补跑的重力段负责"往下"。
	if _command_active:
		if can_fly:
			_gravity_velocity = Vector2.ZERO
		_move_velocity = Vector2.ZERO
		# ★ 不可飞行时，重力累积与位移**已并入 _command_step**（必须在它的 stuck 判定之前跑，
		#   否则纯竖直目标会因"本帧水平位移为 0"被每帧误计 stuck 而提前结束）。
		_command_step(delta)
		return

	# ---- 受控输入（标签 controlled）----
	# 水平（A/D/←/→）：只需 controlled。
	# 竖直（W/S/↑/↓）：controlled **且**（标签集合含 detected_vertical_move（检测到_竖直移动）**或** 可飞行）。
	#   前者通常不是手写的，而是由带 to_detect_vertical_move（待检测_竖直移动）
	#   的检测区在"中心点进入它"时自动赋予（见下方「检测标签」一节）；
	#   后者（can_fly 可飞行）本身就意味着能上下飞，故无需再挂检测标签。
	#   于是"只能在特定区域里上下移动"就成了纯粹的标签组合，不需要额外开关变量。
	var motion := Vector2.ZERO
	var input_active := (BlockTags.CONTROLLED in tags) and not _ui_has_focus()
	if input_active:
		var a_now := Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT)
		var d_now := Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT)
		if a_now:
			motion.x -= 1.0
		if d_now:
			motion.x += 1.0
		# 朝向跟随「上一次按下的水平方向键」(边沿)：带 lock_facing 标签则固定不变
		if BlockTags.LOCK_FACING not in tags:
			if a_now and not _a_prev:
				set_facing(FACING_LEFT)
			if d_now and not _d_prev:
				set_facing(FACING_RIGHT)
		_a_prev = a_now
		_d_prev = d_now
		if BlockTags.DETECTED_VERTICAL_MOVE in tags or can_fly:
			if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
				motion.y -= 1.0
			if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
				motion.y += 1.0
	# 跳跃：
	#   - 按下瞬间（上升沿）           → 起跳
	#   - **一直按住不放** + 已经落地  → 再次起跳（= 连续跳跃）
	#     "落地"就是 _on_floor 为真，即底部重新接触到了其他积木（下落被挡）。
	#     于是按住空格不松：起跳 → 空中（_on_floor=false，_try_jump 会因跳数用尽而拒绝）
	#     → 落地（_on_floor=true，_try_jump 内先清零跳数）→ 立刻再起跳，如此往复。
	var space_now := Input.is_physical_key_pressed(KEY_SPACE)
	var jump_edge := space_now and not _space_prev
	_space_prev = space_now
	if input_active:
		if jump_edge:
			_try_jump()
		elif space_now and _on_floor:
			_try_jump()

	# 速度系统（进一步细化为每块可配的「最大速度 + 加速度」，见文件头「运动参数」）：
	#   · 非飞行：水平 / 竖直合成为一个方向，速度上限 = 水平最大速度（默认 240 = 旧 MOVE_SPEED），
	#     斜向不叠加（同旧版）；加速度 >0 时按 horiz_accel 逐渐逼近目标，=0 时瞬时到位；
	#     松手仍按 MOVE_DECAY_RATE 线性衰减滑停。
	#   · 飞行（can_fly）：两轴各自独立 —— 水平用 horiz_max_speed / horiz_accel，
	#     竖直（W/↑ 上升、S/↓ 下降）用 fly_up_max_speed / fly_up_accel。
	# ★★ 可滚动积木的水平速度**只能有一处主人**：`_roll_step`（平地摩擦 / 斜坡加速 / 空中动量）。
	#   若这里再套一层 MOVE_DECAY_RATE(1200)，它会比 ROLL_ACCEL(600) 还大 →
	#   斜坡上每帧「加 10、减 20」，速度被死死压在个位数，表现为「斜坡上几乎滚不动」（批 533 实测）。
	#   竖直方向不受影响，照常衰减。
	var rollable: bool = roll_enabled
	if can_fly:
		if motion.x != 0.0:
			var tvx: float = motion.x * horiz_max_speed
			_move_velocity.x = move_toward(_move_velocity.x, tvx, horiz_accel * delta) if horiz_accel > 0.0 else tvx
		elif not rollable:
			_move_velocity.x = move_toward(_move_velocity.x, 0.0, MOVE_DECAY_RATE * delta)
		if motion.y != 0.0:
			var tvy: float = motion.y * fly_up_max_speed
			_move_velocity.y = move_toward(_move_velocity.y, tvy, fly_up_accel * delta) if fly_up_accel > 0.0 else tvy
		else:
			_move_velocity.y = move_toward(_move_velocity.y, 0.0, MOVE_DECAY_RATE * delta)
	else:
		if motion.length() > 0.0:
			var target := motion.normalized() * horiz_max_speed
			if horiz_accel > 0.0:
				_move_velocity = _move_velocity.move_toward(target, horiz_accel * delta)
			else:
				_move_velocity = target
		elif rollable:
			_move_velocity.y = move_toward(_move_velocity.y, 0.0, MOVE_DECAY_RATE * delta)
		else:
			_move_velocity = _move_velocity.move_toward(Vector2.ZERO, MOVE_DECAY_RATE * delta)

	# 重力累积（未开启「受重力」或 可飞行 → 不下落）
	if gravity_enabled and not can_fly:
		var g: float = ProjectSettings.get_setting("physics/2d/default_gravity", 980.0)
		_gravity_velocity.y += g * delta
	else:
		_gravity_velocity = Vector2.ZERO

	# 可滚动：重心未受支撑时滚动（水平位移+旋转），被支撑则停稳
	# ★ 传入受控水平方向：平地上玩家正按方向键时不能被滚动摩擦吃掉速度
	_roll_step(delta, motion.x, impact)
	# ★★ 撞击冲量「这一帧没处花」就存起来：摩擦只在**接触帧**存在，而落地帧常常是
	#   blocked_y 先把下落停住、`_rb_grounded` 要到下一帧贴实才为真（538 逐帧实测：
	#   入射 784px/s 记在 blocked_y 那一帧，之后 4 帧圆形件的接触判据仍为假）。
	#   判据用 `_rb_grounded` 而不是 `_on_floor`：后者表示「本帧竖直没动」，
	#   在这段空档期还挂着 true → 唯一一笔大额预算当场作废，之后只能按 μ·g·dt 一帧帧磨
	#   = 「先落到底、顿一下才滚动」。存住的这份在接触恢复的那一帧继续供摩擦。
	if impact > 0.0 and not _rb_grounded:
		_impulse_bank = impact * IMPULSE_BANK_KEEP

	# 刚体倾倒中（矩形 / 三角绕支点公转）：位置与角度已由物理给出，
	# 不能再叠加「速度位移」——否则质心会被平移与公转各推一次（双重运动、抖动）。
	if _rb_mode == RB_TOPPLE:
		_on_floor = true      # 支点着地 → 视为落地（可跳跃）
		return

	# 合成位移并移动
	var total := _move_velocity + _gravity_velocity
	# ★★ 零位移直接早退：**完全等价**于 _try_move 的零位移分支，但省掉每物理帧一次
	#   GDScript 调用 + 一次 Dictionary 分配。
	#   _try_move(offset) 在 `offset.length() < 0.001` 时返回
	#   {moved_x:false, moved_y:false, blocked_y:false}，下面三处判定全部依赖这三个键，
	#   全 false ⇒ 一个副作用都不会发生（不写 _on_floor，不清 _gravity_velocity）。
	#   收益：静止积木（无 gravity / 无 controlled / 未被拖动）在 300+ 块的场景里
	#   每帧省掉 300+ 次跨函数调用与 Dictionary 堆分配（45fps ≈ 1.4 万次/秒）。
	#   ★ 崩溃取证（2026-10-05）：崩溃点正是这一行的调用（blocks/block.gd:1494 →
	#     GDScriptFunction::call 里初始化被调函数栈槽时写野指针），活跃块若全都零位移，
	#     整条分配路径都不再被走到。
	if total.length() < 0.001:
		return
	var _roll_prev_x: float = global_position.x
	# ★ _try_move 在竖直被挡时会把 _gravity_velocity.y 清零 → 撞击速度必须先取下来，
	#   否则弹性反弹拿不到入射速度。
	var vy_before: float = _gravity_velocity.y
	var r := _try_move(total * delta)
	# 可滚动（圆 / 椭圆）：角度已由 _roll_step_round 里的 ω 积分给出，这里只做**撞墙校验**：
	# 实际水平位移明显小于预期 → 是被实体挡住（墙/桌沿），平移归零、自转减半吸收撞击。
	# ★ 旧版这里是「rotation = 实际位移 / 半径」（强制无滑移）→ 打滑在数学上永远不可能出现。
	# ★ 阈值必须是「位移掉了大半」而不是「差 0.01px」：正常滚动的浮点误差就会越过 0.01，
	#   旧写法把每一帧都判成撞停，并把 ω 强行改回 v/r → 刚建立的滑移动力学当场被抹平
	#   （批次 537 探针 T8：椭圆第 4 帧 ω 从 1.3 跳到 3.7 后冻死）。
	if roll_enabled and (shape == Shape.CIRCLE or shape == Shape.ELLIPSE) and _rb_grounded:
		var dx_act: float = global_position.x - _roll_prev_x
		var dx_int: float = total.x * delta
		if absf(dx_act) < absf(dx_int) * 0.4:
			_move_velocity.x = 0.0
			_gravity_velocity.x = 0.0
			_spin *= 0.5

	# 落地状态机：下落被挡 → 落地；竖直方向成功移动 → 离地
	if bool(r["blocked_y"]) and total.y > 0.0:
		_on_floor = true
		# ★ 弹性（批次 537）：入射法向速度按恢复系数反弹 —— 「落地那一下」的观感来源。
		#   只给「可滚动」积木（桌面图标不该跳）；低于 LAND_MIN_SPEED 完全不弹，
		#   否则每次弹得更小却永远停不下来（高频抖动）。
		var rebound: float = 0.0
		if roll_enabled and restitution > 0.0 and vy_before * restitution > LAND_MIN_SPEED:
			rebound = vy_before * restitution
			_gravity_velocity.y = -rebound
		else:
			_gravity_velocity.y = 0.0
		# ★★ 撞击被接触**吸收掉的法向速度** = 入射 + 回弹（完全非弹性时就是入射）。
		#   ① 下一帧的摩擦预算加上这一份 → 落地当帧就能咬地起滚（修「顿一下才滚动」）；
		#   ② 同时驱动挤压回弹的形变量（砸得越狠扁得越多）。
		#   ★ 只在真撞击时记：贴着地面静止的那帧 g·dt≈16 不该算撞击，
		#     否则静止积木会带着一层恒定薄扁（那一份本来就在 μ·g·dt 里）。
		var absorbed: float = vy_before + rebound
		if absorbed > LAND_MIN_SPEED:
			_note_contact_impulse(absorbed, Vector2.UP)
	elif bool(r["moved_y"]):
		_on_floor = false

	# 仅竖直受控移动（W/S）→ 清零重力：浮空悬停不下落（旧版行为）
	# 水平移动(A/D)/跳跃中不清零 → 跳跃抛物线正常完成
	if bool(r["moved_y"]) and not bool(r["moved_x"]) and absf(motion.y) > 0.0:
		_gravity_velocity = Vector2.ZERO

# 尝试跳跃。返回 true 表示成功起跳。
# 条件（旧版 v0.1.28 行为）：
#   - 必须有 gravity 标签（无重力无"跳起再落下"）
#   - 落地状态（vy≈0 且底部有碰撞支撑）才能首跳
# 二段跳预留：
#   - _jumps_used 落地清零，起跳 +1
#   - 当前 MAX_JUMPS=1：起跳后空中 _jumps_used>=1 → 无法再跳
#   - 将 MAX_JUMPS 改为 2 → 空中可再跳一次（第二个 if 分支自动生效，无需改逻辑）
# 连续跳跃（本次新增）：
#   调用方在"按住空格且 _on_floor 为真"时**每帧**调用本函数即可实现连跳；
#   因为 _on_floor 为真时会先把 _jumps_used 清零，所以每一次落地都能重新起跳，
#   而空中（_on_floor 为假、跳数用尽）的调用会被直接拒绝，不产生额外开销。
func _try_jump() -> bool:
	if not gravity_enabled:
		return false
	if _on_floor:
		_jumps_used = 0   # 落地重置跳数（二段跳预留）
	if _jumps_used >= MAX_JUMPS:
		return false      # 跳数用尽（MAX_JUMPS=1 时即"空中不能再跳"）
	if _jumps_used == 0 and not _on_floor:
		return false      # 首跳必须在地面（底部有其他积木碰撞支撑）
	# 起跳前先向上抬 1px（迁移自废弃版 v0.1.28 的 _do_jump）：
	# 脱离与地面/屏障之间的微小重叠，否则"站在屏障边缘"时会因为已经嵌进去而跳不起来。
	# 抬不动（正上方被顶住）也无妨，照常给初速度。
	var lifted := Vector2(global_position.x, global_position.y - 1.0)
	if _can_move_to(lifted):
		global_position.y = lifted.y
	# 起跳：给 vy 一个向上初速度，重力自然把速度衰减回 0 再加速下落
	_gravity_velocity.y = -JUMP_INITIAL_VELOCITY
	_jumps_used += 1
	_on_floor = false
	return true

# ============ 可滚动（「积木运动」面板 roll_enabled）============
# ★★ 批次 534：把「位移驱动自转 + 纯平移」的伪刚体，换成**刚体支点公转**模型。
# 旧模型的三个物理错误：
#   ① 悬空时照样自转（还会在空中横向加速）→ 看着像「积木在空中滚」；
#   ② 矩形以角着地时不会翻倒，而是一角撑着疯转 → 永远落不成「边着地」；
#   ③ 着地姿态靠 _flat_settle 强行回正（瞬移感），且与自转互相拉扯。
# 新模型按形状分两路：
#   · 圆 / 椭圆（旋转对称）= 真滚动：仍按「实际水平位移 / 半径」自转，但**仅在有支撑时**；
#     悬空时水平动量原样保留（不加速、不衰减）、不自转（角动量只保留 _spin）。
#   · 矩形 / 三角（有棱有角）= 真刚体：
#       - 找「触地」的顶点当支点 → 质心绕支点**公转**（走圆弧），角速度由「重力对支点的力矩」积分；
#       - 单角着地 = 倾倒中 → 靠力矩自然翻到「边着地」（角落地问题就此解决）；
#       - 两个同属一条底边的顶点同高着地 = 边着地（稳定，可被推动而滑动，不自转）。
# ★ 须带 collision 标签才有支撑可托（否则无支撑、持续下落，与无碰撞积木一致）。
const RB_GROUND_EPS: float = 2.5    # 旧：顶点下方多少像素内有支撑算「触地」（保留常量名以免外部引用断裂）
const RB_CONTACT_EPS: float = 0.4   # 顶点到支撑面的**法向**距离 ≤ 此值算「接触」（矩形/三角路径用；与坡度无关）
const RB_ROUND_GAP: float = 1.0      # 圆/椭圆：中心到支撑面的法向距离 − 支撑半径 ≤ 此值算「着地」
const RB_ROUND_SEAT: float = 10.0    # 圆/椭圆：允许的嵌入容差，并在贴地时沿法线补正（椭圆滚转时支撑半径会变）
const RB_ROUND_SEAT_MAX: float = 4.0 # 每帧最多沿法线补正多少像素（防瞬移）
const RB_FLAT_NORMAL: float = 0.99     # 同一支撑面的法线平行判据（|cos|）
const RB_FACE_UP: float = 0.35      # 支撑面外法线的 y 分量须 ≤ -0.35（面足够「朝上」才作支撑，排除侧壁）
const RB_APPROACH_MAX: float = 90.0 # 「还在快速落向支撑面」的速度阈值（px/s）：超过则不算接触（防空中误判着地）
const RB_FLAT_PARALLEL: float = 0.999  # 两面平行判据（|cos| 阈值，≈2.6°）
const RB_GAP_MATCH: float = 1.2     # 底边两端「到支撑面法向距离」的最大差（超过 → 不是边着地）
const RB_SEAT_MAX: float = 0.35     # 每帧最多把积木「按到支撑面上」多少像素（消除悬空缝隙）
const RB_SLOPE_ANG_EPS: float = 0.03  # 坡面倾角小于此值视作平地（弧度）
const RB_SLOPE_FULL: float = 0.30   # 坡面「满速」倾角（sin 值，≈17°）：越陡滑得越快
const RB_SPIN_DAMP: float = 0.6    # 倾倒角速度阻尼（每秒比例，模拟能量损耗）
const RB_SPIN_MAX: float = 2.5     # 自转角速度上限的**下限**（rad/s）——大件沿用此值；小件按尺寸抬高，见 _roll_spin_cap
const RB_MAX_DTHETA: float = 0.08  # 单帧最大转角（防一步转太多穿进地面）
const RB_ORBIT_PIVOT_EPS: float = 0.75  # 支点跨帧位移小于此值视作**同一个支点**（继续公转，不重新换算角动量）
const RB_TOPPLE_SLOP: float = 2.0  # 绕棱角公转时允许的额外嵌入容差（px）——见 _rb_topple 的说明
const RB_TOPPLE_SNAP: float = 0.05  # 距目标姿态小于此值直接吸附（避免卡在「差一点平」的角上）
const RB_CORNER_EPS: float = 1.0   # 积木顶点 ↔ 支撑体「角」的距离阈值（角接触）
const RB_FACE_EPS: float = 0.8      # 面级接触的高度容差（我的边与支撑面的法向距离）
const RB_PAR_EPS: float = 0.05     # 边与支撑面「平行」的判据（|sin|）
const RB_BAL_MARGIN: float = 0.5   # 重心投影落在接触区间内的余量（静力平衡判据）
const RB_EDGE_EPS: float = 1.5     # 积木边 ↔ 支撑体「角」的距离阈值（积木的边压在支撑角上）
const RB_EQ_EPS: float = 1.0       # 重心投影落在接触区段内的容差（静力平衡判定）
const RB_AIR: int = 0              # 刚体状态：悬空
const RB_FLAT: int = 1             # 刚体状态：边着地（稳定）
const RB_TOPPLE: int = 2           # 刚体状态：倾倒（绕支点公转）
# ---- 平地主动翻滚（可滚动矩形/三角被推动时，像现实一样越过前缘翻过去）----
const RB_TUMBLE_MIN_SPEED: float = 30.0  # 低于此水平速度只滑动、不翻滚
const RB_TUMBLE_MIN_SPIN: float = 1.2    # 主动翻滚的起步角速度下限（rad/s）
const RB_TUMBLE_SPIN_MAX: float = 4.0    # 主动翻滚时的角速度上限（rad/s）
const RB_TUMBLE_SPIN_GAIN: float = 1.35  # 起步角速度相对 v/r 的增益（推在手推高度的力矩，v/r 之外的一部分）
const RB_TUMBLE_SPIN_MARGIN: float = 1.6 # 翻滚角速度上限 = 越过支点所需最小值 × 此余量（见 _rb_flip_min_spin）
const RB_TUMBLE_DRIVE: float = 3.0       # 玩家持续推动时额外角加速度（rad/s²），保证翻得过去
const RB_TUMBLE_DRIVE_REF_K2: float = 2000.0  # 上式的归一化基准 k²（538 时代 80×40 方块）—— 见 _rb_step 的推动力矩
const RB_SPIN_DAMP_TUMBLE: float = 0.2   # 主动翻滚的角速度阻尼（比自由翻落的 0.6 小，避免半途停下）
const RB_TUMBLE_PEAK_SPIN: float = 0.6   # 重力矩≈0 且角速度低于此值 = 悬在「翻不过去」的峰顶（批次 542）
# ---- 摩擦 / 风阻 / 弹性（批次 537：库仑摩擦 + 滑移耦合）----
const LAND_MIN_SPEED: float = 70.0      # 撞击法向速度低于此值**不反弹**（否则小角度来回弹 = 抖动）
const SETTLE_SPEED: float = 18.0        # 滑动速度低于此值 → 静摩擦直接咬死（停得干脆，不磨）
const ROLL_RESIST_SCALE: float = 0.05   # 滚动阻力 = μ·该比例·g（圆形件负责「慢慢收住」）
const SLIP_BETA: float = 0.5            # 转动惯量 I = m·β·r²（实心圆盘 0.5、圆环 1.0）
# ---- 挤压回弹 / 撞击摩擦预算（批次 538）----
const SQUASH_FULL_SPEED: float = 620.0  # 撞击法向速度到这个值 → 形变打满 1.0（再快也不更扁）
const SQUASH_ZETA: float = 0.38         # 弹簧阻尼比：<1 才会回弹过冲成「拉伸」，就是 Q 弹那一下
const SQUASH_MAX: float = 0.5           # 视觉形变上限（scale 最低 0.5 倍，绝不为负）
const ROLL_SPIN_CAP: float = 14.0       # 圆形件角速度硬上限（rad/s）—— 见 _roll_spin_cap
const IMPULSE_BANK_KEEP: float = 0.9    # 撞击冲量「这一帧没花掉」时的存留比例（见 _impulse_bank）
func _roll_step(delta: float, ctrl_x: float = 0.0, impulse: float = 0.0) -> void:
	if not roll_enabled:
		return
	# 质量惯性缩放：a = F/m 的简化 —— **驱动力**按 1/mass 走（越重起步越慢）。
	# ★ 摩擦不再乘 mi：库仑摩擦的减速度 = μ·g，与质量无关（批次 537）；
	#   批次 538 起摩擦上限改成 μ×法向冲量（见 _fric_impulse_budget），故此处不再预取 μ·g。
	var mi: float = _mass_inertia()
	var acc: float = ROLL_ACCEL * mi
	# 圆 / 椭圆 = 连续滚动（无棱角，不会「翻面」）；矩形/三角 = 支点刚体模型。
	if shape == Shape.CIRCLE or shape == Shape.ELLIPSE:
		_roll_step_round(delta, ctrl_x, acc, impulse)
	else:
		_rb_step(delta, ctrl_x, acc, impulse)


# ---- 圆 / 椭圆：真滚动 ----
# ★ 触地判定改成「**中心到支撑面的法向距离 − 支撑半径**」：
#   旧版用「最低点下方 2.5px 内有支撑」→ 悬空 2px 也算着地 → 空中照样滚（用户报的现象之一）。
#   新判据与坡度无关、且要求真正贴面（gap ≈ 0），空中绝不会被误判成着地。
func _roll_step_round(delta: float, ctrl_x: float, acc: float, impulse: float = 0.0) -> void:
	var c: Dictionary = _rb_round_contact()
	_rb_grounded = not c.is_empty()
	var r_eff: float = _roll_eff_radius()
	# ★ 滑移→自转的耦合系数：538 写死实心盘 0.5，541 起按形状/手填惯量实算（见 _inertia_slip_beta）
	var beta: float = _inertia_slip_beta(r_eff)
	if not _rb_grounded:
		# 悬空：线动量与角动量**都保留**（不加速、不硬清零），只受风阻。
		# ★ 旧版规定「空中一律不自转」→ 滚动的球滚下悬崖会突然停转（角动量凭空消失）。
		#   现在守恒：`_spin` 只可能由**地面接触**（打滑/翻倒）产生，
		#   被鼠标拖放的积木 `_spin` 恒为 0 → 不会出现「空中凭空转起来」。
		_rb_mode = RB_AIR
		_roll_dir = 0.0
		_rb_slide = 0.0
		# ★ 重力统一由 _physics_step 的 gravity_enabled 分支累积；
		#   这里旧版有一段「没有 gravity 标签才加重力」的反向判断，已删除（会造成双份/缺失）。
		var dm_air: float = _drag_mul(delta)
		_move_velocity *= dm_air
		_gravity_velocity *= dm_air
		_spin = clampf(_spin * dm_air, -_roll_spin_cap(r_eff), _roll_spin_cap(r_eff))
		if absf(_spin) > 0.0001:
			# ★ 单帧转角与 ω 上限同源（见 _rb_round_integrate 的同一条注释）：
			#   写死 RB_MAX_DTHETA 会让高速滚出的球在空中「转得比 ω 慢」= 看着像被冻住。
			_rotate_about_com(clampf(_spin * delta, -maxf(RB_MAX_DTHETA, _roll_spin_cap(r_eff) * delta),
				maxf(RB_MAX_DTHETA, _roll_spin_cap(r_eff) * delta)))
		return
	_rb_mode = RB_FLAT
	# ★ 圆/椭圆贴地补正：椭圆转过一个角度后「朝下方向的支撑半径」会变
	#   （圆恒定），若只按水平位移补旋转而不补高度，中心会逐帧陷进支撑面 → 接触丢失、停转。
	#   这里沿支撑面法线把中心拉回「刚好相切」，每帧限速 RB_ROUND_SEAT_MAX 防瞬移。
	#   ★ 正在回弹（向上）时不补 —— 否则每帧 0.35px 的拉力会把撞击弹跳磨平。
	var cgap: float = float(c["gap"])
	if absf(cgap) > 0.01 and _gravity_velocity.y >= 0.0:
		var cnrm: Vector2 = Vector2(c["normal"])
		var seated_round: Vector2 = global_position - cnrm * clampf(cgap, -RB_ROUND_SEAT_MAX, RB_ROUND_SEAT_MAX)
		if _can_move_to(seated_round):
			global_position = seated_round
	# 斜坡判定与滑动方向：**用支撑面的切向**（不是世界 x 轴）。
	#   ★ 旧版把速度硬塞给 _move_velocity.x（世界水平），在斜坡上等于往坡里钻。
	#   现在速度严格沿支撑面切向 → 圆是「贴着坡面滚下去」而不是「横着插进坡里」。
	var tang: Vector2 = c["tangent"]
	if tang.y < 0.0:
		tang = -tang
	if absf(tang.y) > RB_SLOPE_ANG_EPS:
		# —— 斜坡：滚动加速度 = g·sinθ / (1+β) ——
		#   ★ 分母是「摩擦把滑动变成滚动」的代价：同一份摩擦力既要推质心、又要提供力矩
		#     → 球沿坡滚得比方块**滑**得慢（实心球 β=0.5 → 只有纯滑动加速度的 2/3）。
		#   滚动阻力吃得住坡度 → 静止（浅坡上放着不动，坡够陡才开始滚）。
		_roll_dir = 1.0 if tang.y > 0.0 else -1.0
		var a_roll: float = _gravity_px() * absf(tang.y) / (1.0 + beta)
		var a_res: float = _roll_resist_decel()
		if ctrl_x != 0.0:
			_rb_slide = move_toward(_rb_slide, ctrl_x * horiz_max_speed * (1.0 if tang.x >= 0.0 else -1.0), acc * delta)
		elif absf(_rb_slide) < SETTLE_SPEED and a_roll <= a_res:
			_rb_slide = 0.0
		else:
			_rb_slide = clampf(_rb_slide + (a_roll - signf(_rb_slide) * a_res) * delta,
				-ROLL_MAX_SPEED, ROLL_MAX_SPEED)
		_rb_slide *= _drag_mul(delta)
		_move_velocity = tang * _rb_slide
		if _gravity_velocity.y > LAND_MIN_SPEED:
			_land_absorb(_gravity_velocity.y, Vector2(c["normal"]))
		if _gravity_velocity.y >= 0.0:
			_gravity_velocity = Vector2.ZERO
		_spin = _move_velocity.x / r_eff     # 坡上按无滑移约束滚动
		_rb_round_integrate(delta, c)
		return
	# —— 平地：摩擦作用在**接触点滑移速度**上（v_slip = v − ω·r），不是质心速度 ——
	# ★★ 这是 Flash 物理小游戏观感的核心，旧模型完全没有：
	#   · 球被砸出去（v 大、ω 小）→ 接触点向前打滑 → 摩擦**同时**减 v、加 ω
	#     → 先滑一小段、再咬地起滚（而不是一碰地就完美滚动）；
	#   · 倒旋（ω 与 v 反号）会被摩擦「抓住」突然向前窜出去 —— 台球效应；
	#   · 静摩擦冲量够用（μ·g·dt ≥ 滑移）→ 一帧掐掉，直接纯滚动。
	# ★ 受控输入优先：玩家正按方向键时水平速度归「受控移动」管，不做停滚清零
	#   （否则可滚动积木按 D 走不动：每帧被摩擦减完）。
	_rb_slide = 0.0
	# ★ 向上（y<0）的速度是撞击回弹，必须放行 —— 与 _rb_step 稳定分支同一条纪律：
	#   旧版在这里无条件清零 → 「落地弹性」对圆/椭圆永远不可能出现（探针 T5 实测升起 0px）。
	# ★★ 清零之前先记下「被接触吸收掉的法向速度」= 本帧的撞击冲量（批次 538），
	#   并按恢复系数把它的一部分转回**向上**的速度。
	#   ★★ 为什么回弹不能只写在 `_physics_step` 的 blocked_y 里：圆形件落下来那一步
	#   刚好「贴到表面」（不穿透）→ SAT 不算挡 → blocked_y 恒假 → 弹性永远不触发
	#   （538 探针 T5 实测升起 0px）；而且竖直速度在这里就被接触吃掉了。
	if _gravity_velocity.y > LAND_MIN_SPEED:
		_land_absorb(_gravity_velocity.y, Vector2(c["normal"]))
	if _gravity_velocity.y >= 0.0:
		_gravity_velocity = Vector2.ZERO
	_roll_dir = 0.0
	var slip: float = _move_velocity.x - _spin * r_eff
	if absf(slip) > 0.5:
		# 摩擦冲量上限 = μ ×（重力 + 本帧撞击吸收的法向冲量）—— 落地那一帧预算极大，
		# 于是滑移被一帧掐掉、立刻起滚（旧写法只有 μ·g·dt，高速落地要滑 0.2~0.6s = 「顿一下」）
		var j: float = minf(absf(slip) / (1.0 + 1.0 / beta), _fric_impulse_budget(delta, impulse))
		var s: float = signf(slip)
		_move_velocity.x -= j * s
		_spin += j * s / (beta * r_eff)
	elif ctrl_x == 0.0:
		# 已纯滚动：只剩滚动阻力 + 风阻；低于静摩擦阈值**直接咬死**（停得干脆、不磨）
		var res: float = _roll_resist_decel() * delta
		if absf(_move_velocity.x) <= maxf(res, SETTLE_SPEED):
			_move_velocity.x = 0.0
			_spin = 0.0
		else:
			_move_velocity.x -= signf(_move_velocity.x) * res
			_spin = _move_velocity.x / r_eff
	var dm: float = _drag_mul(delta)
	_move_velocity.x *= dm
	_spin = clampf(_spin * dm, -_roll_spin_cap(r_eff), _roll_spin_cap(r_eff))
	# ★ 角度由 ω 积分 —— 旧版在 _physics_step 里按「实际水平位移 / 半径」反推，
	#   等于强制无滑移 → 「打滑」在数学上永远不可能出现（观感假的根源）。
	_rb_round_integrate(delta, c)


# 圆形件本帧的「转角积分 + 贴地复算」。
# ★ 二次贴地不能省：贴地补正发生在旋转**之前**，而椭圆的支撑半径随角度变
#   （转到 90° 是 50、躺着是 30）→ 旋转后的那一帧会略微陷进支撑体，
#   水平位移被 SAT 拒绝 → 通用校验把它当成「撞墙」，滚动当场冻住（批次 537 探针 T8 实测）。
#   这里按解析支撑差直接沿法线抬回，无需再扫一遍场景。
func _rb_round_integrate(delta: float, c: Dictionary) -> void:
	var nrm: Vector2 = Vector2(c["normal"])
	var ext_before: float = _rb_support_dist(nrm)
	# ★ 转角上限跟着 ω 上限走，而不是写死 RB_MAX_DTHETA：0.08 rad/帧只等于 4.8rad/s，
	#   高速纯滚的球（ω 可到 12）会被它掐住 → 「跑得比转得快」= 看上去还在打滑。
	#   圆/椭圆的支撑半径重新算一遍就能贴回，放大这一步不会破坏接触。
	var dth_cap: float = maxf(RB_MAX_DTHETA, ROLL_SPIN_CAP * delta)
	var dth: float = clampf(_spin * delta, -dth_cap, dth_cap)
	if absf(dth) > 0.0001:
		_rotate_about_com(dth)
	var lift: float = _rb_support_dist(nrm) - ext_before
	if absf(lift) > 0.005:
		var seated: Vector2 = global_position + nrm * lift
		if _can_move_to(seated):
			global_position = seated


# ============ 矩形 / 三角：真刚体（支撑面 + 对齐目标）============
# ★★ 批次 534 v2 的模型（由隔离探针的逐帧几何反推得出 —— 斜坡单一场景实测）：
#   旧模型（v1）=「固定支点公转 + 点采样贴地判据」，在三处硬伤上连环失效：
#   ① 贴地判据用「沿面法线探 0.8/2.0px 有支撑」→ 真实缝隙 1~2px 就判失败 → 误入倾倒；
#      倾倒支点又按「谁的 y 大」选 → 选到**下坡角** → 力矩反向（spin 变负）→
#      积木越转越插进坡体（实测 pen=1.71）→ can_move_to 恒假 → **永久卡死**。
#   ② 倾倒**没有转角上限**：转过「边与支撑面平行」的姿态还继续转 → 远端顶点压进坡体。
#   ③ 坡面下滑速度写在 _move_velocity 上，却被通用 MOVE_DECAY_RATE 衰减 y 分量
#      → 坡面向下（y 增大）的分量被碾到 ~0（实测 vel=(154, 2.0)）→ 积木横着插进坡里。
#   v2 的做法：
#   · 接触用「顶点 → 支撑体**朝上面**的**法向**有向距离 gap」求（>0 悬空 / <0 已嵌入），
#     与坡度无关；并排除「还在快速落向支撑面」的情况（否则空中会误判着地 → 空中滚动）；
#   · 底边两端都接触同一支撑面、且底边与该面平行 → RB_FLAT（躺着，可沿面滑动）；
#   · 只一角接触 → RB_TOPPLE：绕该角公转，**转到「边与支撑面平行」为止**（对齐上限）；
#   · 已经嵌入支撑体 → 按 SAT 最小平移量顶出来（否则 can_move_to 恒假 → 卡死）；
#   · 悬空（无接触）→ 不自转、不横向加速（空中滚动问题就此根治）。
#
# ============ 支撑分析（批次 535 v3：面级接触 + 静力平衡）============
# ★★ 批次 534 的 v2 模型只做**逐顶点**采样（顶点 → 支撑面法向距离），漏掉了
#   两种最常见的真实支撑形态：
#     ① **我的底边与支撑面共线**（矩形躺着，只有底边中间一小段搭在窄台上）；
#     ② **支撑体的棱角压在我的底边中间**（斜着搭在台角上）。
#   这两种情况下**我的两个底角都在支撑体之外** → 顶点采样一个都碰不到 →
#   判定成「悬空」→ 刚体层完全不工作，而通用 SAT 碰撞又把我按在原地 →
#   表现为「维持角度、不会像现实那样倒下来」（批次 535 的根因）。
#   v3 改为**面级接触**：对支撑体的每个朝上面求出「接触区间」，
#   再用**静力平衡判据**（重心投影是否落在接触区间内）决定
#   「躺平（可沿面滑动）」还是「绕区间外端翻倒」。
#
# 返回「支撑候选」数组，每项描述「某个支撑体的某个朝上面」与我的接触关系：
#   { "kind":int, "block":Block, "origin":Vector2, "dir":Vector2, "len":float,
#     "nrm":Vector2, "s_lo":float, "s_hi":float, "gap":float,
#     "pivot":Vector2, "pivot_i":int }
#   kind: 0 = 面接触（我的边与支撑面共线，接触是**一段**）
#         1 = 点接触（我的顶点压在支撑面上）
#         2 = 棱角接触（支撑体的角压在我的边/顶点上）
func _rb_analyze(poly: PackedVector2Array) -> Array:
	var res: Array = []
	var tree := get_tree()
	if tree == null:
		return res
	var my_scene: Node = _scene_of()
	var n: int = poly.size()
	if n < 3:
		return res
	# 当前总速度：用来判断「还在快速落向支撑面」→ 那种情况不算接触（否则空中会误判着地）
	var vel: Vector2 = _move_velocity + _gravity_velocity
	var my_reach: float = _rb_reach()
	# 顶点「嵌进支撑体多深仍算接触」（px，负方向的搜索窗口）——见下面 ② 的说明
	var pen_look: float = maxf(2.0, my_reach * 0.5)
	for other in tree.get_nodes_in_group("block"):
		if not is_instance_valid(other) or other == self or not (other is Block):
			continue
		var ob: Block = other
		if ob._scene_of() != my_scene:
			continue
		if ob._is_in_subtree_of(self):
			continue
		if not ob._has_collision():
			continue
		if not _collision_layers_intersect(collision_layer, ob.collision_layer):
			continue
		# 粗筛：中心距太远直接跳过（避免对全场积木都算多边形）
		var dd: Vector2 = ob.global_position - global_position
		var lim: float = my_reach + ob._rb_reach() + 2.0
		if dd.length_squared() > lim * lim:
			continue
		var opoly: PackedVector2Array = ob._obb_corners(ob.global_position)
		var m: int = opoly.size()
		if m < 3:
			continue
		var ocent: Vector2 = _poly_center(opoly)
		for k in range(m):
			var a: Vector2 = opoly[k]
			var b: Vector2 = opoly[(k + 1) % m]
			var e: Vector2 = b - a
			var el: float = e.length()
			if el < 0.0001:
				continue
			var dir: Vector2 = e / el
			# 支撑面外法线：背离支撑体质心
			var nrm: Vector2 = Vector2(-dir.y, dir.x)
			if nrm.dot((a + b) * 0.5 - ocent) < 0.0:
				nrm = -nrm
			# 只认「足够朝上」的面（侧壁不算支撑面）
			if nrm.y > -RB_FACE_UP:
				continue
			# ---------- ① 面接触：我的某条边与本面共线 ----------
			var bi_lo: float = INF
			var bi_hi: float = -INF
			var bi_gap: float = 0.0
			for i in range(n):
				var j: int = (i + 1) % n
				var v1: Vector2 = poly[i]
				var v2: Vector2 = poly[j]
				var h1: float = (v1 - a).dot(nrm)
				var h2: float = (v2 - a).dot(nrm)
				if absf(h1) > RB_FACE_EPS or absf(h2) > RB_FACE_EPS:
					continue
				var ed: Vector2 = v2 - v1
				var edl: float = ed.length()
				if edl < 0.0001:
					continue
				# 边必须与支撑面平行（|sin| 判据）
				if absf(dir.x * (ed.y / edl) - dir.y * (ed.x / edl)) > RB_PAR_EPS:
					continue
				var s1: float = (v1 - a).dot(dir)
				var s2: float = (v2 - a).dot(dir)
				var lo: float = maxf(0.0, minf(s1, s2))
				var hi: float = minf(el, maxf(s1, s2))
				if hi - lo <= 0.0:
					continue
				var gap: float = (h1 + h2) * 0.5
				# 还在快速落向支撑面 → 尚未接触（避免空中误判着地 → 空中滚动）
				if gap > 0.05 and -vel.dot(nrm) > RB_APPROACH_MAX:
					continue
				if lo < bi_lo or hi > bi_hi:
					bi_lo = minf(bi_lo, lo)
					bi_hi = maxf(bi_hi, hi)
					bi_gap = gap
			if bi_hi > bi_lo:
				res.append({
					"kind": 0, "block": ob, "origin": a, "dir": dir, "len": el,
					"nrm": nrm, "s_lo": bi_lo, "s_hi": bi_hi, "gap": bi_gap,
					"pivot": Vector2.ZERO, "pivot_i": -1,
				})
			# ---------- ② 点接触：我的顶点落在本面上 ----------
			# ★★ 负向窗口必须放开到「至少半个自身尺寸」（批次 542）：
			#   h < 0 表示顶点**已经在支撑体里面**——那是毫无疑问的接触，绝不能因为
			#   「嵌得太深、不像接触」而看不见它。旧窗口只到 −1px，而高速自转的方块
			#   每帧转角把棱尖往下甩 3~4px（ω=5.6、r=42 → 4px/帧），于是：
			#   嵌深 → 分析说「无支撑」→ 唯一能脱嵌的 _rb_unstick() 根本不会被调用
			#   → 通用 SAT 又拒绝一切位移 → 角在土里原地打转、位置纹丝不动（542 DIAG f1~f11）。
			#   ★ 正向（悬空）一侧不动：h>0 仍是薄窗口 + 「正在快速接近就不算接触」，
			#   否则空中会被误判着地（537 的老教训）。
			for i in range(n):
				var v: Vector2 = poly[i]
				var h: float = (v - a).dot(nrm)
				if h > RB_CONTACT_EPS or h < -pen_look:
					continue
				var s: float = (v - a).dot(dir)
				if s < -RB_CORNER_EPS or s > el + RB_CORNER_EPS:
					continue
				if h > 0.05 and -vel.dot(nrm) > RB_APPROACH_MAX:
					continue
				if s >= 0.0 and s <= el:
					res.append({
						"kind": 1, "block": ob, "origin": a, "dir": dir, "len": el,
						"nrm": nrm, "s_lo": s, "s_hi": s, "gap": h,
						"pivot": v, "pivot_i": i,
					})
				else:
					# 顶点落在面的**外侧** → 实际是靠支撑体的**棱角**顶着
					var cp: Vector2 = a if s < 0.0 else b
					res.append({
						"kind": 2, "block": ob, "origin": a, "dir": dir, "len": el,
						"nrm": nrm, "s_lo": 0.0, "s_hi": 0.0, "gap": h,
						"pivot": cp, "pivot_i": -1,
					})
			# ---------- ③ 棱角接触：支撑体本面的端点压在我的边/顶点上 ----------
			for cpv in [a, b]:
				var cpoint: Vector2 = cpv
				# 棱角必须在我重心之下 → 才是「从下往上顶」
				if cpoint.y < _com_world().y - RB_CORNER_EPS:
					continue
				for i in range(n):
					var j: int = (i + 1) % n
					var dist: float = _rb_point_seg_dist(cpoint, poly[i], poly[j])
					if dist > RB_CORNER_EPS:
						continue
					res.append({
						"kind": 2, "block": ob, "origin": a, "dir": dir, "len": el,
						"nrm": nrm, "s_lo": 0.0, "s_hi": 0.0, "gap": dist,
						"pivot": cpoint, "pivot_i": -1,
					})
	return res


# 从候选里挑出「最该用」的支撑：
#   优先级：面接触（区间最长）> 点接触（间隙最小 = 嵌得最深）> 棱角接触（间隙最小）
#   点接触额外遵守「跨帧保持支点」（_rb_pivot_i），避免支点跳变导致抖动。
func _rb_pick(cands: Array) -> Dictionary:
	var face: Dictionary = {}
	var point: Dictionary = {}
	var point_sticky: Dictionary = {}
	var corner: Dictionary = {}
	for c in cands:
		var cd: Dictionary = c
		var k: int = int(cd["kind"])
		if k == 0:
			if face.is_empty() or _rb_span(cd) > _rb_span(face):
				face = cd
		elif k == 1:
			if _rb_pivot_i >= 0 and int(cd["pivot_i"]) == _rb_pivot_i:
				point_sticky = cd
			elif point.is_empty() or float(cd["gap"]) < float(point["gap"]):
				point = cd
		else:
			if corner.is_empty() or float(cd["gap"]) < float(corner["gap"]):
				corner = cd
	if not face.is_empty():
		return face
	if not point_sticky.is_empty():
		return point_sticky
	if not point.is_empty():
		return point
	return corner


# 候选的「接触区间长度」
func _rb_span(c: Dictionary) -> float:
	return float(c["s_hi"]) - float(c["s_lo"])


# 点 p 到线段 ab 的最短距离（用于「支撑体棱角压在我的边上」判定）
func _rb_point_seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var l2: float = ab.length_squared()
	if l2 < 0.0001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)



# 圆 / 椭圆：找与支撑面的接触（用中心 + 支撑半径，判定与坡度无关）
# 返回 { "gap": float, "tangent": Vector2, "normal": Vector2, "block": Block } 或空字典
func _rb_round_contact() -> Dictionary:
	var tree := get_tree()
	if tree == null:
		return {}
	var my_scene: Node = _scene_of()
	var my_reach: float = _rb_reach()
	var best_gap: float = INF
	var best_tang: Vector2 = Vector2.RIGHT
	var best_nrm: Vector2 = Vector2.UP
	var best_block: Block = null
	for other in tree.get_nodes_in_group("block"):
		if not is_instance_valid(other) or other == self or not (other is Block):
			continue
		var ob: Block = other
		if ob._scene_of() != my_scene:
			continue
		if ob._is_in_subtree_of(self):
			continue
		if not ob._has_collision():
			continue
		if not _collision_layers_intersect(collision_layer, ob.collision_layer):
			continue
		var dd: Vector2 = ob.global_position - global_position
		var lim: float = my_reach + ob._rb_reach() + 2.0
		if dd.length_squared() > lim * lim:
			continue
		var opoly: PackedVector2Array = ob._obb_corners(ob.global_position)
		var m: int = opoly.size()
		if m < 3:
			continue
		var ocent: Vector2 = _poly_center(opoly)
		for k in range(m):
			var a: Vector2 = opoly[k]
			var b: Vector2 = opoly[(k + 1) % m]
			var e: Vector2 = b - a
			var el: float = e.length()
			if el < 0.0001:
				continue
			var dir: Vector2 = e / el
			var nrm: Vector2 = Vector2(-dir.y, dir.x)
			if nrm.dot((a + b) * 0.5 - ocent) < 0.0:
				nrm = -nrm
			if nrm.y > -RB_FACE_UP:
				continue
			# 中心在面上的投影必须落在这条面的覆盖范围内
			var s: float = (global_position - a).dot(dir)
			if s < -2.0 or s > el + 2.0:
				continue
			var gap: float = (global_position - a).dot(nrm) - _rb_support_dist(nrm)
			# 允许最多 RB_ROUND_SEAT 的嵌入（椭圆滚转时支撑半径按姿态变化，不补正会越陷越深）
			if gap > RB_ROUND_GAP or gap < -RB_ROUND_SEAT:
				continue
			if gap < best_gap:
				best_gap = gap
				best_tang = dir
				best_nrm = nrm
				best_block = ob
	if best_block == null:
		return {}
	return {"gap": best_gap, "tangent": best_tang, "normal": best_nrm, "block": best_block}


# 本积木在方向 n 上的「支撑半径」（圆 = 半径；椭圆 = 支撑函数；其余 = 0，即当作一个点）
func _rb_support_dist(n: Vector2) -> float:
	match shape:
		Shape.CIRCLE:
			return minf(width, height) * 0.5
		Shape.ELLIPSE:
			var n2: Vector2 = n.rotated(-rotation)   # 世界法线 → 本地（椭圆随 rotation 转）
			var a2: float = width * 0.5
			var b2: float = height * 0.5
			return sqrt(a2 * a2 * n2.x * n2.x + b2 * b2 * n2.y * n2.y)
		_:
			return 0.0


# 本积木的外接半径（粗筛用）
func _rb_reach() -> float:
	# ★★ 本积木的「影响半径」= **半对角线**（不是最长边的一半）。
	#   多边形的最远顶点距离中心是半对角线 sqrt(w²+h²)/2；
	#   用「最长边一半」会**低估**影响范围 → 粗筛把「斜着搭在窄台/窄边上」的支撑体
	#   误判成「太远」而跳过 → 接触漏判 → 积木被判成悬空、被通用碰撞卡住、维持角度
	#   （批次 535 的第二个根因：100×100 方块 vs 40 宽窄台，中心距 72px > 误算的 72 边界）。
	#   与批次 533「矩形翻滚支点是角 → 半径取半对角线」是同一条几何纪律。
	return 0.5 * sqrt(width * width + height * height)


# 把已经嵌入支撑体的积木顶出来（SAT 最小平移量）。
# ★ 必须有：一旦嵌入，_can_move_to 永远为假 → 刚体再也动不了（v1 实测永久卡死）。
func _rb_unstick() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var my_scene: Node = _scene_of()
	var my_reach: float = _rb_reach()
	for other in tree.get_nodes_in_group("block"):
		if not is_instance_valid(other) or other == self or not (other is Block):
			continue
		var ob: Block = other
		if ob._scene_of() != my_scene:
			continue
		if ob._is_in_subtree_of(self):
			continue
		if not ob._has_collision():
			continue
		if not _collision_layers_intersect(collision_layer, ob.collision_layer):
			continue
		var dd: Vector2 = ob.global_position - global_position
		var lim: float = my_reach + ob._rb_reach() + 2.0
		if dd.length_squared() > lim * lim:
			continue
		var r: Dictionary = _sat_overlap(_obb_corners(global_position), ob._obb_corners(ob.global_position))
		if not bool(r["overlap"]):
			continue
		var depth: float = float(r["depth"])
		if depth <= 0.2:
			continue
		var axis: Vector2 = r["axis"]
		if axis.length_squared() < 0.0001:
			continue
		# axis 指向「我 → 对方」，分离要沿 -axis 走
		global_position -= axis * (depth + 0.05)


# 刚体三态：RB_AIR 悬空 / RB_FLAT 边着地 / RB_TOPPLE 倾倒
# ★ 判据全部基于「与支撑面的真实接触关系」，与坡度无关：
#   ① 无任何接触 → 悬空（不滚、不自转）；
#   ② 底边与支撑面共线（接触是一**段**），且**重心投影落在接触区间内**
#      → 边着地（可沿支撑面滑动）；
#   ③ 重心投影落在接触区间**之外** → 绕区间外端（支撑体的棱）翻倒；
#   ④ 只顶点接触 → 绕该顶点倾倒，转到与支撑面平行为止。
# ★★ ②③ 的分界就是**静力平衡判据** —— 现实中「只有一点点接触面」的物体会倒，
#    v2 没有这个判据 → 维持角度不倒（批次 535 的核心修复）。
func _rb_step(delta: float, ctrl_x: float, acc: float, impulse: float = 0.0) -> void:
	var was_topple: bool = (_rb_mode == RB_TOPPLE)
	var poly := _obb_corners(global_position)
	var n: int = poly.size()
	if n < 3:
		return
	# ---- 主动翻滚进行中：继续绕支点公转 ----
	# 不能走下面的静力平衡判定：翻滚到一半时接触只剩支点一个顶点，
	# 重算会把它判成「角撑着」或换支点 → 翻滚立刻中断。
	# 支点仍在支撑上 → 沿冻结的目标姿态继续转；支点脱离（翻过棱 / 悬空）→ 交回常规分析。
	if _rb_tumble and _rb_mode == RB_TOPPLE:
		var pi: int = _rb_pivot_i
		if pi >= 0 and pi < n and _rb_point_supported(poly[pi] + Vector2(0.0, 1.5)):
			var tp: Vector2 = poly[pi]
			var tr: Vector2 = _com_world() - tp
			var trr: float = maxf(1.0, tr.length())
			var tg2: float = ProjectSettings.get_setting("physics/2d/default_gravity", 980.0)
			var t_alpha: float = tg2 * tr.x / _inertia_k2(trr)
			# ★★ 峰顶放手（批次 542 用户报的第二条：「停在不应该平衡下来的角度」）：
			#   翻面翻到「质心正好在支点正上方」而角速度也耗尽时，重力矩≈0，
			#   而这一分支里**没有**下面倾倒分支那条极小自纠正力矩 →
			#   积木会永远悬在这一面**根本站不住**的角度上（探针 R1 f60~f69：
			#   rot 卡死在 1.403rad、离躺平只差 9.6°，ω 与 vx 一起归零）。
			#   正确做法是**交回常规支撑分析**：那里按当前支点重算对齐目标，
			#   取转角最小的稳定姿态 → 倒回它来的那一面，自然落定。
			#   ★ 只在「真的没力气了」时放手：还有角速度说明这一面正要被甩过去，
			#     中途改判会把 538 校好的接力翻面打断。自由翻滚不做吸附，也不放手。
			if absf(t_alpha) < 0.5 and absf(_spin) < RB_TUMBLE_PEAK_SPIN and not free_roll:
				_rb_tumble = false
				_rb_tumble_speed = 0.0
				_rb_target_valid = false
			else:
				# 玩家持续推动 → 额外驱动（推力的力矩），保证越过重心最高点；
				# 松手后只有角动量与重力矩，翻不过去就自然回落。
				if ctrl_x != 0.0:
					# ★ 推力的力矩同样要过惯量这关：开惯量后 α_drive = (τ/m)/k²
					#   → 大件、手填大 I 的件「推得动但拧不动」，不会再一推就利落翻面。
					#   基准 k² 取 538 时代 80×40 方块的 |质心−支点|²≈2000，
					#   使默认件在开与关之间观感连续；关闭时直接用定值（逐位不变）。
					var drive: float = RB_TUMBLE_DRIVE
					if inertia_enabled:
						drive = RB_TUMBLE_DRIVE * RB_TUMBLE_DRIVE_REF_K2 / _inertia_k2(trr)
					t_alpha += signf(wrapf(_rb_target_rot - rotation, -PI, PI)) * drive
				_rb_topple(delta, tp, _rb_target_rot, t_alpha, true)
				return
		_rb_tumble = false
		_rb_tumble_speed = 0.0
	var cands: Array = _rb_analyze(poly)
	var best: Dictionary = _rb_pick(cands)
	if best.is_empty():
		# 悬空：不施加自转（角动量只保留 _spin）→ 不再出现「空中滚动」
		_rb_release_to_air(delta)
		return
	# 已经嵌进支撑体（老模型留下的坏状态）→ 先顶出来，否则一切移动都会被 can_move_to 拒绝
	if float(best["gap"]) < -0.2:
		_rb_unstick()
		cands = _rb_analyze(_obb_corners(global_position))
		best = _rb_pick(cands)
		if best.is_empty():
			_rb_mode = RB_AIR
			_rb_grounded = false
			_rb_pivot_i = -1
			_rb_target_valid = false
			_rb_slide = 0.0
			_rb_tumble = false
			_rb_tumble_speed = 0.0
			return
	var kind: int = int(best["kind"])
	var dir: Vector2 = Vector2(best["dir"])
	var nrm: Vector2 = Vector2(best["nrm"])
	var origin: Vector2 = Vector2(best["origin"])
	# 记下当前支撑面法线：撞击帧的挤压形变沿它压扁（公转途中没有新的 best，沿用这一份）
	_squash_normal = nrm
	# 重心（= 配置的旋转轴）在支撑面切向上的投影（静力平衡判据的输入）
	# ★ 用 _com_world() 而不是 global_position：轴偏移会改变重心位置 → 改变稳定姿态与倾倒力矩。
	var com_s: float = (_com_world() - origin).dot(dir)
	var s_lo: float = float(best["s_lo"])
	var s_hi: float = float(best["s_hi"])
	# ---- 静力平衡：重心投影落在接触区间内 → 躺平；否则 → 翻倒 ----
	var stable: bool = false
	if kind == 0:
		stable = com_s >= s_lo - RB_BAL_MARGIN and com_s <= s_hi + RB_BAL_MARGIN
	if stable:
		_rb_mode = RB_FLAT
		_rb_grounded = true
		_rb_pivot_i = -1
		_rb_target_valid = false
		_rb_tumble = false
		_rb_tumble_speed = 0.0
		_spin = 0.0
		# 支撑面切向：取 y 增大的一侧 = 下坡方向
		var tang: Vector2 = dir
		if tang.y < 0.0:
			tang = -tang
		# 「按到支撑面上」：消除悬空缝隙（每帧最多 RB_SEAT_MAX 像素）
		#   ★ 正在向上回弹时不补 —— 否则每帧 0.35px 的拉力会把撞击弹跳磨平。
		var gap: float = float(best["gap"])
		if gap > 0.0 and _gravity_velocity.y >= 0.0:
			var seated: Vector2 = global_position - nrm * minf(gap, RB_SEAT_MAX)
			if _can_move_to(seated):
				global_position = seated
		# 法向重力交给接触承担（否则会逐帧往支撑面里硬顶）。
		# ★ 例外：**向上**的速度（y<0）是撞击回弹，必须放行 —— 它先把积木抬离支撑面
		#   （接触断开 → 转入 RB_AIR），重力再把它拉回来重砸一次。
		#   这就是 Flash 游戏里「翻面砸地 → 弹一下 → 再砸实」的来源；
		#   旧版在这里一律清零 → 弹性参数永远不可能起作用。
		# ★★ 「按到支撑面上」清零竖直速度 == 接触吸收了法向动量 == 一次撞击：先记下再清零
		#   （与 _roll_step_round 的同一条纪律；blocked_y 对刚体件基本不触发）。
		if _gravity_velocity.y > LAND_MIN_SPEED:
			_land_absorb(_gravity_velocity.y, nrm)
		if _gravity_velocity.y >= 0.0:
			_gravity_velocity = Vector2.ZERO
		if absf(tang.y) > RB_SLOPE_ANG_EPS:
			# —— 坡面：库仑滑动 a = g·(sinθ − μ·cosθ) ——
			#   ★ μ·cosθ 吃得住 g·sinθ → **静摩擦**：浅坡上放着不动、坡够陡才开始下滑。
			#     旧模型只看坡度不看摩擦 → 任何微小倾斜都滑到满速，观感像冰面。
			#   ★ y 分量绝不能被通用 MOVE_DECAY_RATE 衰减掉，否则会横着插进坡里（实测 vel=(154,2.0)）。
			if _rb_slide == 0.0:
				_rb_slide = _move_velocity.dot(tang)   # 继承进入坡面时的水平动量
			var sin_t: float = absf(tang.y)
			var cos_t: float = sqrt(maxf(0.0, 1.0 - sin_t * sin_t))
			var a_grav: float = _gravity_px() * sin_t
			var a_fric: float = clampf(friction_coef, 0.0, 2.0) * _gravity_px() * cos_t
			if ctrl_x != 0.0:
				# 玩家推动：把水平意图投影到坡面切向（acc 已含质量惯性缩放）
				_rb_slide = move_toward(_rb_slide, ctrl_x * horiz_max_speed * tang.x, acc * delta)
			elif absf(_rb_slide) < SETTLE_SPEED and a_grav <= a_fric:
				_rb_slide = 0.0     # 静摩擦咬住
			else:
				var prev_slide: float = _rb_slide
				_rb_slide = clampf(prev_slide + (a_grav - signf(prev_slide) * a_fric) * delta,
					-ROLL_MAX_SPEED, ROLL_MAX_SPEED)
				# 摩擦吃得住坡度时不许「反向滑上坡」：穿过零点就咬死
				if prev_slide > 0.0 and _rb_slide < 0.0 and a_grav <= a_fric:
					_rb_slide = 0.0
			_rb_slide *= _drag_mul(delta)
			_move_velocity = tang * _rb_slide
			return
		# —— 平地：库仑摩擦 μ·g 匀减速 + 静摩擦阈值 ——
		_rb_slide = 0.0
		if not can_fly:
			_move_velocity.y = 0.0
		# ★★ 撞击那一帧**先**判翻滚（批次 538）：此刻水平速度还完整、且摩擦预算被法向冲量抬高，
		#   「砸下来还往前滑」应当直接接力翻下一面。
		#   顺序反了（先减摩擦再判）→ 撞击帧的大预算一口吃掉水平速度 → 起翻速度被掐死
		#   = 方块版的「落到底、顿一下才滚」。
		if impulse > 0.0 and _rb_try_tumble(delta, poly, dir, nrm, origin, ctrl_x, impulse):
			return
		if ctrl_x == 0.0:
			# ★ 摩擦上限是 μ×**法向冲量**（重力 g·dt + 本帧被接触吸收的撞击速度），不是恒定 μ·g·dt。
			_move_velocity.x = move_toward(_move_velocity.x, 0.0, _fric_impulse_budget(delta, impulse))
			# ★ 低于阈值直接咬死：旧版只剩线性缓动 → 末尾几十像素磨磨蹭蹭（「停得太肉」）。
			if absf(_move_velocity.x) < SETTLE_SPEED:
				_move_velocity.x = 0.0
		_move_velocity.x *= _drag_mul(delta)
		# 推得够快 → 绕「运行方向前下方」的棱翻过去（现实里推盒子就是这样翻滚的），
		# 而不是像旧模型那样贴着地面平移。
		if _rb_try_tumble(delta, poly, dir, nrm, origin, ctrl_x, impulse):
			return
		return
	# ================= 翻倒 =================
	var pivot: Vector2 = Vector2.ZERO
	var align: bool = false
	var pivot_i: int = -1
	if kind == 0:
		# 重心在接触区间之外 → 绕区间外端（支撑体的棱）翻倒
		var s_p: float = s_hi
		if com_s < s_lo:
			s_p = s_lo
		pivot = origin + dir * s_p
	elif kind == 1:
		# 我的顶点压在支撑面上 → 绕它倾倒，转到「边与支撑面平行」为止
		# ★ 自由翻滚（free_roll）：不做对齐吸附 —— 让它按重力自然转，
		#   允许以任意角度搭在棱角上（用户要的「完全自由的滚动姿态」）。
		pivot = Vector2(best["pivot"])
		pivot_i = int(best["pivot_i"])
		align = not free_roll
	else:
		# 支撑体的棱角顶着我 → 绕该棱翻落
		pivot = Vector2(best["pivot"])
	_rb_mode = RB_TOPPLE
	_rb_grounded = true
	var comw: Vector2 = _com_world()
	var r: Vector2 = comw - pivot
	var rr: float = maxf(1.0, r.length())
	var g2: float = ProjectSettings.get_setting("physics/2d/default_gravity", 980.0)
	# 力矩：重力对支点的力矩 τ = m·g·r.x（r = 质心 − 支点）；角加速度 α = τ/I = g·r.x/k²。
	# ★ k² 由 `_inertia_k2(rr)` 给：关闭时 = |r|²（质点近似，与 538 逐位一致）；开启时 =
	#   形状绕质心的回转半径² + 平行轴 → 同包围盒下 α 变小（真实薄板是 4/3 倍），
	#   大件与手填大 I 的件明显更「懒」。
	# ★ **自动惯量仍与质量无关**（τ ∝ m、I ∝ m 抵消，现实如此）；
	#   只有手填 I（单位含质量）才让质量真正进转动方程 —— 想要「同尺寸但更沉更不易翻」就填它。
	#   v1 误乘 1/mass → 重块 8 倍慢 → 永远翻不过来（探针 T6b 实测用时 -1 帧）。
	var alpha: float = g2 * r.x / _inertia_k2(rr)
	var fall: float = signf(r.x)
	if absf(r.x) < 1.0:
		fall = 0.0
	var target_rot: float = rotation
	if align:
		# 目标姿态 = 「含支点的边转到与支撑面平行」（进入倾倒时冻结，避免逐帧跳变；支点变了才重算）
		if not was_topple or not _rb_target_valid or _rb_target_pivot_i != pivot_i:
			_rb_target_rot = rotation + _rb_align_d(poly, pivot_i, dir, nrm, fall)
			_rb_target_valid = true
			_rb_target_pivot_i = pivot_i
		target_rot = _rb_target_rot
		# 近乎平衡（质心正好在支点正上方）→ 给一个极小的自纠正力矩，
		#   否则积木会永远「角撑着」站在尖上（正是用户报的现象）。
		#   ★ 必须在**每条路径**上都生效（不能写成 elif）——否则正好平衡的角撑完全不动。
		#   ★ 自由翻滚时不加这个人工纠正 —— 允许「角撑着」的自然姿态。
		if absf(alpha) < 0.5 and not free_roll:
			# ★ 近乎平衡 + 几乎不动 = 真的悬在角上（批次 542）：此刻冻结的目标可能是
			#   **上一段**倾倒留下的、指向「绕远的那一面」，照它爬会停在中途的假平衡角。
			#   这一刻最可信的判据是「哪一面最近」→ fall=0 重算目标
			#   （`_rb_align_d` 在 fall=0 时退化成只取转角最小者，与本函数注释的意图一致）。
			if absf(_spin) < RB_TUMBLE_PEAK_SPIN:
				_rb_target_rot = rotation + _rb_align_d(poly, pivot_i, dir, nrm, 0.0)
				_rb_target_valid = true
				_rb_target_pivot_i = pivot_i
				target_rot = _rb_target_rot
			alpha = signf(target_rot - rotation) * 0.5
	elif absf(alpha) < 0.5 and not free_roll:
		# 近乎平衡 → 极小自纠正力矩（朝重心偏移的方向）
		var side: float = signf(com_s - (pivot - origin).dot(dir))
		if side == 0.0:
			side = 1.0
		alpha = side * 0.5
	# ★★ 「重心低于支点就放手自由落体」是**错的**：重心低于支点只说明方块已经转到
	#   支点下方，但**支点仍在承重**（接触依然存在）——此时放手会让方块穿模、
	#   或者被通用 SAT 挡住 → 表现为「维持角度、既不倒也不落」（批次 535 用户报的现象）。
	# ================= 棱角支点：先解这一帧的接触冲量，再决定「咬住公转」还是「继续滑」 =================
	# ★★ 公转的前提是接触点被**钉死**（接触点线速度一帧归零）。棱角能给的冲量分两种：
	#   法向（顶住）永远给得起；切向最多只有 μ×法向那一份（库仑）。
	#   旧写法把棱角当理想铰链：`_rb_topple` 末尾用 _move_velocity = ω×r 覆盖真实速度 →
	#   滑到台角那一帧 291px/s 的水平动量凭空蒸发（542 探针 f7→f8「水平位移掉了 100%」），
	#   之后只剩重力矩一点一点爬 = 用户说的「像和那块静止的积木之间有粘性」，
	#   并且会停在「根本平衡不住的角度」上不倒也不落。
	#   现在分层解：① 法向吸收「挖进支撑面」那一份（=撞击，顺带顶住本帧重力）；
	#   ② 切向按 μ 上限吸收滑移（与圆形件 _roll_step_round 的滑移摩擦同一条纪律）；
	#   ③ 只有滑移被吃光（接触真的咬住）且单向接触留得住，才转成绕支点公转；
	#   否则继续滑——支持力对质心的力矩会把积木**逐渐**拧起来：探出越多、力臂越大、
	#   拧得越快，脱离台角时带着自然的自转飞出去（这就是「接着滚下去」的那一下）。
	var rc: Vector2 = pivot - comw
	var tang: Vector2 = dir
	if tang.y < 0.0:
		tang = -tang
	var k2c: float = maxf(1.0, _inertia_k2_axis())
	var arm_n: float = rc.x * nrm.y - rc.y * nrm.x
	var arm_t: float = rc.x * tang.y - rc.y * tang.x
	var den_n: float = 1.0 + arm_n * arm_n / k2c
	var den_t: float = 1.0 + arm_t * arm_t / k2c
	var v_com: Vector2 = _move_velocity + _gravity_velocity
	# 接触点这一帧的速度 = 质心速度 + 自转带动的那一份
	var u: Vector2 = v_com + _spin * Vector2(-rc.y, rc.x)
	var u_n: float = -u.dot(nrm)
	var u_t: float = u.dot(tang)
	# ① 法向冲量：把「压进支撑面」顶出来（e 决定回弹），并顶住本帧重力
	#   （等价于旧稳定分支的「竖直速度交给接触承担」，但这里是按力臂分配到自转的真冲量）
	var jn: float = (maxf(0.0, u_n) * (1.0 + clampf(restitution, 0.0, 0.9)) + g2 * delta) / den_n
	_apply_contact_impulse(jn, nrm, arm_n, k2c)
	if u_n > LAND_MIN_SPEED:
		_note_contact_impulse(u_n, nrm)
	# ② 切向冲量：|P_t| ≤ μ·P_n —— 撞击那帧预算极大，一帧就能咬地（批次 538 的老纪律）
	var jt_need: float = -u_t / den_t
	var jt_cap: float = _fric_impulse_budget(delta, maxf(0.0, u_n))
	_apply_contact_impulse(clampf(jt_need, -jt_cap, jt_cap), tang, arm_t, k2c)
	# ③ 咬住 = 这一帧的摩擦足以把接触点的滑移全吃光；再加单向接触顶得住公转
	var stuck: bool = absf(jt_need) <= jt_cap * 1.1 + 1.0
	var pin_spin: float = _spin
	if not (was_topple and pivot.distance_squared_to(_rb_orbit_pivot) \
			< RB_ORBIT_PIVOT_EPS * RB_ORBIT_PIVOT_EPS):
		# 新支点接管：铰链假设下角动量守恒 L = k²_质心·ω + r×v → ω = L / k²_支点
		#   ★ 关闭惯量时 k²_质心项 = 0（质点近似，与 538 逐位同）→ ω = 切向速度/r，天然按尺寸给
		var k2p: float = _inertia_k2(rr)
		pin_spin = (_spin * maxf(0.0, k2p - rr * rr) + r.x * v_com.y - r.y * v_com.x) / k2p
	# ★ 公转要求的向下向心加速度超过重力时，支点必须反过来「往下拉」积木才留得住
	#   —— 棱角拉不住，这一刻积木其实已经在往外抛出，只能走滑移那条路。
	var a_orbit: Vector2 = Vector2(-pin_spin * pin_spin * r.x - alpha * r.y,
		-pin_spin * pin_spin * r.y + alpha * r.x)
	if stuck and (a_orbit - Vector2(0.0, g2)).dot(nrm) >= 0.0:
		_spin = pin_spin
		_rb_orbit_pivot = pivot
		_rb_pivot_i = pivot_i
		_rb_topple(delta, pivot, target_rot, alpha, align)
		return
	# ---- 滑移接触：接触还在（顶着、有摩擦），但没钉死 → 继续平移，同时被力矩拧 ----
	_rb_orbit_pivot = pivot
	_rb_mode = RB_FLAT
	_rb_grounded = true
	_rb_pivot_i = -1
	_rb_target_valid = false
	_rb_slide = 0.0
	_rb_tumble = false
	_rb_tumble_speed = 0.0
	var slip_cap: float = _roll_spin_cap(maxf(1.0, rr))
	_spin = clampf(_spin * maxf(0.0, 1.0 - RB_SPIN_DAMP * delta) * _drag_mul(delta),
		-slip_cap, slip_cap)
	var slip_dth: float = maxf(RB_MAX_DTHETA, slip_cap * delta)
	_rotate_about_com(clampf(_spin * delta, -slip_dth, slip_dth))


# 单位质量冲量 j（带符号）沿单位方向 drc 作用在接触点上：
#   质心速度按其分量分摊给 _move_velocity(x) / _gravity_velocity(y)（与全文件的分工一致），
#   角速度按力矩改：Δω = j·arm / k²_质心（arm = 接触点对质心的力矩臂 = rc×drc）。
# ★ 与圆形件 _roll_step_round 里那句「j = min(|slip|/(1+1/β), 摩擦预算)」是同一条纪律，
#   只是刚体件的冲量作用点不一定在质心正下方，力臂必须按真实接触点算，否则
#   「棱角被顶一下」不会让积木转起来（= 又回到只平移、不翻滚的老观感）。
func _apply_contact_impulse(j: float, drc: Vector2, arm: float, k2c: float) -> void:
	var dv: Vector2 = drc * j
	_move_velocity.x += dv.x
	_gravity_velocity.y += dv.y
	_spin += j * arm / k2c



# 绕支点转到「该边与支撑切向平行」所需的转角（带符号）。
# ★ 几何要点：支点在支撑面上，把「含支点的边」转到与支撑切向平行时，
#   远端顶点恰好落在支撑面上（沿切向）—— 这就是「边着地」的唯一稳定姿态。
#   两个解相差 π（远端落在支点两侧）：取与力矩方向（fall）一致、且转角最小者；
#   力矩近乎为零（正好平衡在角上）时取转角最小者 + 极小自纠正力矩，
#   免得积木永远「角撑着」站不起来。
func _rb_align_d(poly: PackedVector2Array, pivot_i: int, tang: Vector2, nrm: Vector2, fall: float) -> float:
	var n: int = poly.size()
	var pivot: Vector2 = poly[pivot_i]
	var com: Vector2 = _com_world() - pivot
	var nbs: Array = [(pivot_i + 1) % n, (pivot_i - 1 + n) % n]
	var best: float = INF
	var best_d: float = 0.0
	var backup: float = INF
	var backup_d: float = 0.0
	for nbv in nbs:
		var nb: int = int(nbv)
		var f: Vector2 = poly[nb] - pivot
		if f.length() < 0.0001:
			continue
		f = f.normalized()
		# 该邻边在当前力矩方向下是否会下降（只有下降的邻边才可能是「落地面」）：
		#   旋转 +dθ 时邻点速度 = dθ·(-f.y, f.x) → f.x > 0 下降；反向则相反。
		if fall > 0.0 and f.x <= 0.0:
			continue
		if fall < 0.0 and f.x >= 0.0:
			continue
		var raw: float = tang.angle() - f.angle()
		for m in range(2):
			var d: float = wrapf(raw - float(m) * PI, -PI, PI)
			if absf(d) < backup:
				backup = absf(d)
				backup_d = d
			# 旋转方向必须与力矩方向一致
			if fall > 0.0 and d <= 0.0001:
				continue
			if fall < 0.0 and d >= -0.0001:
				continue
			# 落地面之后积木本体必须仍在支撑面上方（否则那是「翻过去」的解）
			if com.rotated(d).dot(nrm) <= 0.0:
				continue
			if absf(d) < best:
				best = absf(d)
				best_d = d
	if best == INF:
		return backup_d
	return best_d


# 把质心「抬到支点正上方」所需要的最小角速度（能量判据）：
#   ½Iω² = m·g·(d − h_c) → ω = sqrt(2g(d − h_c)/k²_支点)
#   d = |质心 − 支点|，h_c = 质心在支点**上方**的高度（屏幕 y 向下 → −r.y）。
# ★ 只用于**角速度上限**（不是力）：上限低于这个值，翻面必然「爬到一半没力气、
#   倒头滑回来」（538 T3 实测停在 29.7°）。尺寸越小要的 ω 越大，由公式自然给出。
# ★ h_c 按**当前姿态**实算而不是 height/2：方块立起来（翻过一面之后）只需把质心抬
#   4.7px，用 height/2 会算出 4.26 的假需求 → 上限虚高、连翻第二面时疯转。
# ★ k² 取法：开惯量走 `_inertia_k2`（形状 + 平行轴，手填 I 也算进去）；
#   关闭时用解析薄板 (w²+h²)/3 —— 与 538 校好的那两个上限逐位一致。
func _rb_flip_min_spin(r: Vector2) -> float:
	var d: float = maxf(1.0, r.length())
	var h_c: float = maxf(0.0, -r.y)
	var k2: float = _inertia_k2(d) if inertia_enabled \
		else maxf(1.0, (width * width + height * height) / 3.0)
	return sqrt(maxf(0.0, 2.0 * _gravity_px() * maxf(0.0, d - h_c) / k2))


# 接触断开 / 棱角拉住积木 → 交回自由抛落。
# ★★ 线动量与角动量**都保留**（批次 542）：这正是「从台角甩出去」的那一下，
#   旧写法在这里把 _spin 钳进 RB_SPIN_MAX=2.5 —— 60×60 的件由动量换算出的真实角速度 ≈9.6，
#   一帧就被吃掉 → 又变成「慢慢爬下台角」。上限改成按尺寸给（与圆形件同一条纪律，见 _roll_spin_cap）：
#   它本身就是「接触点线速度 ≤ ROLL_MAX_SPEED」，大件（r ≥ 144px）算出来仍是 2.5，行为逐位不变。
func _rb_release_to_air(delta: float) -> void:
	_rb_mode = RB_AIR
	_rb_grounded = false
	_rb_pivot_i = -1
	_rb_target_valid = false
	_rb_slide = 0.0
	_rb_tumble = false
	_rb_tumble_speed = 0.0
	var cap: float = _roll_spin_cap(_rb_reach())
	_spin = clampf(_spin * _drag_mul(delta), -cap, cap)
	if absf(_spin) > 0.0001:
		# 绕配置的旋转轴（质心）自转 —— 而不是几何中心；单帧转角与上限同源（同 _rb_round_integrate）
		var dth: float = maxf(RB_MAX_DTHETA, cap * delta)
		_rotate_about_com(clampf(_spin * delta, -dth, dth))


# 绕支点公转（真刚体翻倒），带「对齐上限」：
#   ★ 转到「边与支撑面平行」就停 —— 这是 v1 缺失的关键一步：
#     旧模型无上限地继续转 → 远端顶点压进坡体（pen=1.71）→ can_move_to 恒假 → 永久卡死。
func _rb_topple(delta: float, pivot: Vector2, target_rot: float, alpha: float, has_target: bool = true) -> void:
	# ★★ 公转每一帧末尾都会把竖直速度交给接触（下面两处 `_gravity_velocity = ZERO`）——
	#   第一帧那一份就是「棱角砸到地面」吸收掉的法向冲量：先记下来，
	#   它既驱动挤压形变，也给下一帧（转入 RB_FLAT）的摩擦预算与绊翻判据抬boost。
	if _gravity_velocity.y > LAND_MIN_SPEED:
		_note_contact_impulse(_gravity_velocity.y, _squash_normal)
	var c: Vector2 = global_position
	var r: Vector2 = c - pivot
	_spin += alpha * delta
	# 角速度耗散：接触处的能量损耗（RB_SPIN_DAMP*）+ 风阻（air_drag，按 1/mass 放大）
	var damp: float = RB_SPIN_DAMP_TUMBLE if _rb_tumble else RB_SPIN_DAMP
	_spin *= maxf(0.0, 1.0 - damp * delta) * _drag_mul(delta)
	# 自转上限：自由翻落（绕棱角甩出去）时角速度不能无限涨 ——
	#   实测无上限时会转 2 圈以上、横向甩出 200+px，手感很差。
	#   主动翻滚（被推动）允许多一点角速度，否则 90° 翻面会显得拖沓。
	# ★★ 翻滚（_rb_tumble）的上限必须**按积木自己的尺寸**给：把质心抬过支点所需的
	#   最小角速度来自能量判据 ½Iω² = m·g·(d − h_c)（I/m = k² = (w²+h²)/3，绕支角）
	#   → ω_flip = sqrt(2g(d−h_c)/k²)。80×40 的方块算出 4.26rad/s，而旧写法一律钳在
	#   RB_TUMBLE_SPIN_MAX=4.0 → 撞击接力翻面「转到 30° 就没力气、倒头滑回来」
	#   （538 探针 T3 逐帧实测）。小件要的 ω 更大（ω∝1/尺寸），大件更小，都由这条公式自然给出。
	var spin_max: float = _roll_spin_cap(maxf(1.0, r.length()))
	if _rb_tumble:
		spin_max = maxf(RB_TUMBLE_SPIN_MAX, _rb_flip_min_spin(r) * RB_TUMBLE_SPIN_MARGIN)
	_spin = clampf(_spin, -spin_max, spin_max)
	var dtheta: float = _spin * delta
	# ★ 单帧转角上限跟着 ω 上限走（否则 ω=6.8 仍被 0.08rad/帧 掐成 4.8，翻面照样拖沓）。
	#   自由翻落仍是 RB_MAX_DTHETA 原值，观感不变。
	var dth_cap: float = maxf(RB_MAX_DTHETA, spin_max * delta)
	if absf(dtheta) > dth_cap:
		# ★ 只钳制**单帧转角**（防一步转太多穿进支撑体），
		#   **不覆盖 _spin** —— 覆盖会让角速度被钉死在 RB_MAX_DTHETA/delta
		#   （实测恒为 4.8 rad/s）→ 空中一直疯转、落地还在转。
		#   真实角速度继续按上面的 alpha/阻尼演化。
		dtheta = signf(dtheta) * dth_cap
	# 与目标姿态的剩余夹角（带符号）
	#   ★ has_target=false（自由翻落）：没有「对齐目标」，只受「不穿进支撑体」约束 ——
	#     现实里「只有一点点接触面」的物体会一直翻到脱开支撑为止。
	if has_target:
		var remain: float = wrapf(target_rot - rotation, -PI, PI)
		if absf(remain) < RB_TOPPLE_SNAP:
			# 已到位 → 贴地（下一帧由接触判据接管，转入 RB_FLAT 沿面滑动）
			rotation = target_rot
			global_position = pivot + (c - pivot).rotated(remain)
			# ★ 撞击速度 = |ω|·|质心−支点|（绕支点公转的线速度）。
			#   弹性 e 把它的一部分转成**向上**的速度：下一帧 _rb_step 的稳定分支放行
			#   （见那里的「向上回弹」注释）→ 积木抬离支撑面 → 重力再把它拉回来重砸一次。
			#   这就是 Flash 小游戏里「翻过去 → 弹一下 → 砸实」的收势；
			#   旧版这里无条件清零 → 翻到姿态像被踩住一样硬定（用户说的「太生硬」）。
			var impact: float = absf(_spin) * maxf(1.0, (c - pivot).length())
			var bounce: float = impact * clampf(restitution, 0.0, 0.9)
			_spin = 0.0
			# ★★ 撞击转翻滚（批次 538）：翻到下一面这一帧**既要把水平动量接力下去，
			#   又要把撞击冲量交给下一帧的摩擦预算与绊翻判据**。
			#   旧写法固定「主动翻滚保全部 / 自由翻落保一半」，而且不记冲量 →
			#   落地面 boost=1、判据退回 μ·h>w → 只平移滑停 = 方块版的「顿一下才滚」。
			#   现在按撞击强弱扣一点点（砸得狠损失多、轻砸几乎全保）→
			#   硬砸能连着翻两三面再自然收敛；`keep ≤ 1` 保证松手后逐面减速、不会自己越滚越快。
			var keep: float = 1.0 - clampf(impact / SQUASH_FULL_SPEED, 0.0, 0.5)
			var relay: float = _rb_tumble_speed if _rb_tumble else _move_velocity.x
			if _rb_tumble:
				_rb_tumble = false
				_rb_tumble_speed = 0.0
			_move_velocity = Vector2(relay * keep, 0.0)
			_gravity_velocity = Vector2(0.0, -bounce) if bounce > LAND_MIN_SPEED else Vector2.ZERO
			_rb_mode = RB_FLAT
			_rb_grounded = true
			if impact > LAND_MIN_SPEED:
				_note_contact_impulse(impact, _squash_normal)
			return
		# 不越过目标姿态
		if signf(dtheta) == signf(remain) and absf(dtheta) > absf(remain):
			dtheta = remain
			_spin = dtheta / maxf(delta, 0.0001)

	var new_pos: Vector2 = pivot + (c - pivot).rotated(dtheta)
	if not _can_move_to(new_pos, 1.0):
		# 被挡：先把嵌入的部分顶出来，仍不行就放弃这一步
		_rb_unstick()
		if not _can_move_to(new_pos, 1.0):
			# ★★ 绕**棱角**公转时，旋转必然会让方块的一角略微进入支撑体
			#   （实测垂距 0.0364px —— 肉眼根本看不见，但 SAT 判为重叠）。
			#   若直接放弃这一步 → 转速被 _spin*=0.3 压到几乎为零 → **永远转不动**
			#   → 表现为「维持角度、既不倒也不落」（用户报的现象）。
			#   正确处理：允许**极小的嵌入**（只放宽一点点容差），
			#   让它能继续转；只有真的撞到别的东西才停。
			if _can_move_to(new_pos, RB_TOPPLE_SLOP):
				# 轻微嵌入 → 照转（下一帧 _rb_unstick 会把它顶回去）
				global_position = new_pos
				rotation += dtheta
				_move_velocity = _spin * Vector2(-r.y, r.x)
				_gravity_velocity = Vector2.ZERO
				return
			# ★★ 这一步被实体挡住 = **另一个角真的砸在地面/别的东西上** ——
			#   这是整段公转里唯一真实的撞击时刻（比「到达目标姿态」更可信）。
			#   按恢复系数把角速度**反向**弹回：来回摆两下、幅度递减到停 ——
			#   旧版一律 `_spin *= 0.3`（方向不变）→ 看着像「卡了一下继续转」，没有撞击感。
			var e_rock: float = clampf(restitution, 0.0, 0.9)
			var rock_impact: float = absf(_spin) * maxf(1.0, r.length())
			if rock_impact * e_rock > LAND_MIN_SPEED:
				_spin = -_spin * e_rock
			else:
				_spin = 0.0
			_rb_tumble = false
			_rb_tumble_speed = 0.0
			if rock_impact > LAND_MIN_SPEED:
				_note_contact_impulse(rock_impact, _squash_normal)
			return
	global_position = new_pos
	rotation += dtheta
	# 质心速度 = ω × r（脱离支点时接管动量用）
	_move_velocity = _spin * Vector2(-r.y, r.x)
	_gravity_velocity = Vector2.ZERO


# 平地主动翻滚：水平速度达到阈值时，绕「行进方向前下方」的棱翻向下一条边。
# ★ 现实里推一个盒子：推力相对前缘产生力矩，越过前缘后整块翻过去再落到下一条边；
#   旧模型只在「重心投影落到接触区间外」时才翻倒，平地正常推动永远只平移 —— 就是用户说的「不滚动」。
# ★ 只由**运动方向**决定支点与落地面，与重力矩方向无关（平地上重力矩为 0）。
# ★ 松手滑行时还要过**绊翻判据**（μ·h > w）：摩擦力不够（冰面）就只是滑停，不会翻。
func _rb_try_tumble(delta: float, poly: PackedVector2Array, dir: Vector2, nrm: Vector2, origin: Vector2, ctrl_x: float, impulse: float = 0.0) -> bool:
	var spd: float = _move_velocity.x
	if absf(spd) < RB_TUMBLE_MIN_SPEED:
		return false
	var n: int = poly.size()
	if n < 3:
		return false
	var dsign: float = signf(spd)
	# 支撑切向按运动方向定向（dir 可能指向上坡/下坡）
	var axis: Vector2 = dir if dir.x * dsign >= 0.0 else -dir
	var com: Vector2 = _com_world()
	var best_i: int = -1
	var best_s: float = -INF
	for i in range(n):
		var v: Vector2 = poly[i]
		# 支点必须落在支撑面上（贴在别的顶点/空中都不行）
		if absf((v - origin).dot(nrm)) > RB_FACE_EPS + 0.8:
			continue
		# 支点必须在重心下方
		if (v - com).dot(nrm) >= 0.0:
			continue
		var s: float = (v - origin).dot(axis)
		if s > best_s:
			best_s = s
			best_i = i
	if best_i < 0:
		return false
	var d: float = _rb_next_face_d(poly, best_i, axis, dsign)
	if absf(d) < 0.05:
		return false
	var pivot: Vector2 = poly[best_i]
	var r: Vector2 = com - pivot
	var rr: float = maxf(1.0, r.length())
	# ★ 松手后自己滑出去的积木，只有**被摩擦绊停**才可能翻：
	#   摩擦力 μmg 的力臂是质心高度 h，重力的稳定力臂是支点到质心的水平距离 w
	#   → 绊翻条件 μ·h > w。矮胖子要 μ>1 才翻、高瘦件 μ>0.4 就翻（现实如此）；
	#   冰面（μ≈0）永远只是滑出去，不会一推就翻 —— 这就是「摩擦力」在观感上的作用。
	#   ★ 玩家正在按方向键推（ctrl_x≠0）时由手的推力矩负责，不受这条约束。
	#   ★ 撞击帧（批次 538）：摩擦上限是 μ×**法向冲量**，砸地那一帧法向冲量是重力的 boost 倍
	#     → 绊翻判据同比例放宽成 μ·h·boost > w。硬砸下来还带着水平速度的方块因此
	#     直接接力翻下一面（用户要的「撞击转翻滚」），轻落地 boost≈1、慢滑依旧只是滑停。
	var boost: float = 1.0 + maxf(0.0, impulse) / maxf(0.0001, _gravity_px() * delta)
	if ctrl_x == 0.0 and friction_coef * absf(r.y) * boost < absf(r.x):
		return false
	var spin: float
	if inertia_enabled:
		# ★★ 绊翻的起步角速度 = 对支点的**角动量守恒**（接触瞬间完全非弹性捕获）：
		#   L/m = v_x·h（h = 质心离地高度 = 摩擦力 μmg 的力臂）→ ω = v_x·h / k²_支点。
		#   「矮胖子推不动、高瘦件一推就翻、同形状越大越懒」全部由这一条自己长出来，
		#   不再需要 538 那个 v/|r|×1.35 的手调增益（它就是「生硬」的另一半来源）。
		#   ★ 竖直（砸下来）那份动量**不计**：它被支撑面的法向冲量就地吸收，
		#     作用线过支点 → 对支点的矩≈0 —— T4「垂直落地不乱翻」说的就是这件事。
		spin = absf(spd) * absf(r.y) / _inertia_k2(rr)
	else:
		# 关闭：逐位保留 538 的增益式（老手感不变）
		spin = absf(spd) / rr * RB_TUMBLE_SPIN_GAIN
	spin = maxf(spin, RB_TUMBLE_MIN_SPIN)
	_rb_mode = RB_TOPPLE
	_rb_grounded = true
	_rb_pivot_i = best_i
	_rb_target_rot = rotation + d
	_rb_target_valid = true
	_rb_target_pivot_i = best_i
	_spin = dsign * spin
	_rb_tumble = true
	_rb_tumble_speed = spd
	var g2: float = ProjectSettings.get_setting("physics/2d/default_gravity", 980.0)
	# ★ 重力矩的角加速度同样除以对支点的 k²（关闭时 _inertia_k2(rr)==rr²，逐位等于 538）
	_rb_topple(delta, pivot, _rb_target_rot, g2 * r.x / _inertia_k2(rr), true)
	return true


# 绕顶点 pivot_i 转到「相邻边与支撑切向平行」所需的带符号转角（与 dsign 同号，取最小者）。
# ★ 与 _rb_align_d 的区别：不按「哪条邻边在重力矩下下降」过滤 ——
#   平地主动翻滚时落地的下一条边完全由**运动方向**决定。
func _rb_next_face_d(poly: PackedVector2Array, pivot_i: int, tang: Vector2, dsign: float) -> float:
	var n: int = poly.size()
	var pivot: Vector2 = poly[pivot_i]
	var nbs: Array = [(pivot_i + 1) % n, (pivot_i - 1 + n) % n]
	var best: float = INF
	for nbv in nbs:
		var nb: int = int(nbv)
		var f: Vector2 = poly[nb] - pivot
		if f.length() < 0.0001:
			continue
		var fa: float = f.normalized().angle()
		for m in range(2):
			# 边可与切向同向或反向平行（相差 π 的两个解都算对齐）
			var raw: float = tang.angle() + float(m) * PI - fa
			var d: float = 0.0
			if dsign > 0.0:
				d = wrapf(raw, 0.0, TAU)
				if d < 0.0001 or d >= PI - 0.0001:
					continue
			else:
				d = wrapf(raw, -TAU, 0.0)
				if d > -0.0001 or d <= -PI + 0.0001:
					continue
			if absf(d) < absf(best):
				best = d
	return best if best != INF else 0.0

# 世界坐标点 p 是否落在「其它可碰撞积木」的 OBB 内（_support_at 的通用化）。
func _rb_point_supported(p: Vector2) -> bool:
	var tree := get_tree()
	if tree == null:
		return false
	var my_scene: Node = _scene_of()
	for other in tree.get_nodes_in_group("block"):
		if not is_instance_valid(other) or other == self or not (other is Block):
			continue
		var ob: Block = other
		if ob._scene_of() != my_scene:
			continue
		if ob._is_in_subtree_of(self):
			continue
		if not ob._has_collision():
			continue
		if not _collision_layers_intersect(collision_layer, ob.collision_layer):
			continue
		if ob._obb_contains_point(ob.global_position, p):
			return true
	return false


# 顶点 p 是否「触地」（正下方 RB_GROUND_EPS 内有支撑）
func _rb_touching(p: Vector2) -> bool:
	return _rb_point_supported(p + Vector2(0.0, RB_GROUND_EPS))


# 形状最低点（世界坐标）
func _rb_lowest_point() -> Vector2:
	var poly := _obb_corners(global_position)
	if poly.is_empty():
		return global_position
	var best: Vector2 = poly[0]
	for p in poly:
		if p.y > best.y:
			best = p
	return best


# 多边形顶点 i、j 是否相邻（同一底边）；三角形任意两顶点相邻
func _rb_adjacent(i: int, j: int, n: int) -> bool:
	if n <= 3:
		return true
	var d: int = absi(i - j)
	return d == 1 or d == n - 1


# 滚动半径（线速度 → 角速度）：圆 = 半径；椭圆取两半轴均值；矩形/三角形 = 半对角线。
# ★ 矩形/三角形用「半对角线」而非「短边半长」：它们翻滚时的支点是**角/顶点**，中心到支点的
#   距离就是半对角线。旧写法（短边半长）把半径报小了近一倍 → 角速度虚高、翻滚看起来" frantic "
#   地疯转；换成几何上正确的支点距离后，滚动视觉速度与平移速度一致，明显更顺。
func _roll_radius() -> float:
	match shape:
		Shape.CIRCLE:
			return maxf(1.0, minf(width, height) * 0.5)
		Shape.ELLIPSE:
			return maxf(1.0, (width + height) * 0.25)
		_:
			return maxf(1.0, sqrt(width * width + height * height) * 0.5)


# 滚动有效半径（旋转轴 → 接地点）：圆/椭圆取**当前朝下方向**的支撑距离
# （椭圆转到不同角度时半径本来就会变），再减去质心偏移在该方向上的分量。
# ★ 轴偏移让「轴到接地点」变短 → 同样线速度下角速度更大（偏心轮的摆动感）。
func _roll_eff_radius() -> float:
	var r: float = _roll_radius()
	if shape == Shape.CIRCLE or shape == Shape.ELLIPSE:
		r = _rb_support_dist(Vector2(0.0, 1.0))
	r -= roll_axis_offset.rotated(rotation).y
	return maxf(1.0, r)


# 圆形件的角速度上限：必须按「纯滚动所需 ω = v/r」给，不能是一个写死的数。
# ★★ 旧写法（537 之前）一律钳到 RB_TUMBLE_SPIN_MAX=4.0 rad/s —— 半径 30 的球最多只能
#   滚 4×30=120px/s，而 ROLL_MAX_SPEED=360。于是 400px/s 抛出去的球落地后
#   「永远咬不住地」：摩擦为了满足无滑移约束，只能把水平速度砍到 120 = 一次急刹
#   = 「先落到底、顿一下才滚」的另一半成因（538 探针逐帧实测）。
#   下限保留 RB_SPIN_MAX：大半径件（r=100 → 3.6）不该被压得比小球还慢。
func _roll_spin_cap(r_eff: float) -> float:
	return minf(ROLL_SPIN_CAP, maxf(RB_SPIN_MAX, ROLL_MAX_SPEED / maxf(1.0, r_eff)))


# 质量对「滚动惯性」的缩放系数（1/mass）：越重越小 → 加速度、摩擦衰减同步变小，
# 于是「起步慢、停得慢、滚得远」。mass=1 → 恒 1.0（旧手感不变）；<=0 收敛为 1.0 防除零。
func _mass_inertia() -> float:
	if mass <= 0.0:
		return 1.0
	return 1.0 / clampf(mass, 0.1, 100.0)


# ---- 转动惯量（批次 541）----
# ★★ 下面三个 static 是**唯一一份**惯量算法：物理侧（_inertia_k2_axis）、「积木运动」面板的
#   自动参考值、验收探针都调它，UI 与模拟不会漂移到不同数字上。
# 形状「绕**自身形心**」的回转半径² k² = I/m（像素²，单位质量）。
# ★ 全部取薄板（绕垂直于画面的轴）的解析式，不是拟合数：
#   矩形 (w²+h²)/12；圆盘 r²/2；椭圆 (a²+b²)/4（a=w/2）；
#   三角形用「任意三角形 I/m = (a²+b²+c²)/36」（a/b/c 为三边），
#   等边代回 s²/12 与课本一致。未知形状退回矩形（保守 = 转得更慢）。
static func k2_shape_center(p_shape: int, w: float, h: float) -> float:
	var ww: float = maxf(1.0, w)
	var hh: float = maxf(1.0, h)
	match p_shape:
		Shape.CIRCLE:
			return ww * ww / 8.0
		Shape.ELLIPSE:
			return (ww * ww + hh * hh) / 16.0
		Shape.TRI_ISOSCELES:
			# 三边：底 w、两腰 sqrt((w/2)²+h²) → Σ边² = 1.5w² + 2h²
			return (1.5 * ww * ww + 2.0 * hh * hh) / 36.0
		Shape.TRI_RIGHT:
			# 三边：w、h、sqrt(w²+h²) → Σ边² = 2w² + 2h²
			return (2.0 * ww * ww + 2.0 * hh * hh) / 36.0
		Shape.TRI_EQUILATERAL:
			return 3.0 * ww * ww / 36.0
		_:
			return (ww * ww + hh * hh) / 12.0


# ★★ 形状本地（相对包围盒中心）的**面积形心**：矩形/圆/椭圆 = 原点；三角形 ≠ 原点
#   （形心在底边一侧 h/3 处，而包围盒中心在 h/2）。与 roll_axis_offset 同一局部坐标系，
#   两者直接相减就是「自转轴到形心」的距离（旋转不改变长度）。
# ★ 三角形取「顶点平均 = 面积形心」的解析式，不建多边形 —— 每帧都会被转动方程调到。
static func local_centroid(p_shape: int, w: float, h: float, p_dir: int) -> Vector2:
	var hw: float = maxf(0.0, w / 2.0)
	var hh: float = maxf(0.0, h / 2.0)
	var c: Vector2 = Vector2.ZERO
	match p_shape:
		# 等腰：顶点朝上 (0,−hh)、(±hw, hh) → 形心 (0, hh/3)
		Shape.TRI_ISOSCELES:
			c = Vector2(0.0, hh / 3.0)
		# 等边：按「宽 = 边长」构造 → 高 = √3·hw，形心 (0, 高/6)
		Shape.TRI_EQUILATERAL:
			c = Vector2(0.0, sqrt(3.0) * hw / 6.0)
		# 直角：(−hw,−hh)、(−hw,hh)、(hw,hh) → 形心 (−hw/3, hh/3)
		Shape.TRI_RIGHT:
			c = Vector2(-hw / 3.0, hh / 3.0)
		_:
			return Vector2.ZERO
	var dir: int = p_dir % 4
	if dir == 0:
		return c
	var ang: float = TAU * float(dir) / 4.0
	var co: float = cos(ang)
	var si: float = sin(ang)
	return Vector2(c.x * co - c.y * si, c.x * si + c.y * co)


# 绕自转轴的 k² = 形心 k² + 平行轴（自转轴到形心的距离²）。与 _inertia_k2_axis 一致。
static func k2_axis_auto(p_shape: int, w: float, h: float, p_dir: int, axis: Vector2) -> float:
	var ww: float = maxf(1.0, w)
	var hh: float = maxf(1.0, h)
	var off: Vector2 = axis - local_centroid(p_shape, ww, hh, p_dir)
	return maxf(1.0, k2_shape_center(p_shape, ww, hh) + off.length_squared())


# 绕**自转轴（质心）**的 k²。手填 I 优先（I 含质量 → 换算回单位质量的 k²）。
# ★ 平行轴是**加**：自转轴偏离形状自身形心 d → I_轴 = I_形心 + m·d²。
#   偏心件（摆锤）绕自己的轴更难拧起来，一碰就转的是「质量集中在轴上」的件。
func _inertia_k2_axis() -> float:
	if inertia_value > 0.0:
		return inertia_value / maxf(0.1, mass)
	return k2_axis_auto(int(shape), width, height, int(shape_dir), roll_axis_offset)


# ★★ 转动方程真正要的分母：绕**当前支点/接触点**的 k² = I_质心 + |质心−支点|²。
# ★ 关闭时返回 dist² —— 正是 538 的质点近似，逐位等价（老手感零风险）。
func _inertia_k2(dist: float) -> float:
	if not inertia_enabled:
		return maxf(1.0, dist * dist)
	return maxf(1.0, _inertia_k2_axis() + dist * dist)


# 圆形件「接触点滑移 → 自转」的耦合系数 β = k²_质心/r²（等价于 I = m·β·r²）。
# ★ 538 把它写死成实心盘的 0.5；开惯量后按形状/手填值实算：
#   β 大（环、扁椭圆立着时）→ 同样的摩擦冲量更难把它「拧」起来 = 打滑更久、下坡更慢。
# ★ 关闭时恒等于 SLIP_BETA（逐位等价于 538）。
func _inertia_slip_beta(r_eff: float) -> float:
	if not inertia_enabled:
		return SLIP_BETA
	return clampf(_inertia_k2_axis() / maxf(1.0, r_eff * r_eff), 0.05, 4.0)


# ---- 摩擦 / 风阻 / 弹性（批次 537）----
# 重力加速度（像素/秒²）：力矩、摩擦、坡面下滑共用同一来源。
func _gravity_px() -> float:
	return ProjectSettings.get_setting("physics/2d/default_gravity", 980.0)


# 库仑摩擦能给出的最大减速度 = μ·g（像素/秒²）。
# ★ 不乘质量：滑动摩擦力 F = μ·m·g，除以 m 后减速度与质量无关（现实里同材质滑停距离一样）。
#   旧模型用写死的 ROLL_FRICTION=900/mass，等于「越重越黏地」—— 与现实相反。
func _fric_decel() -> float:
	return clampf(friction_coef, 0.0, 2.0) * _gravity_px()


# 滚动阻力（圆形件专用）：远小于滑动摩擦，负责「慢慢收住」而不是急停。
func _roll_resist_decel() -> float:
	return _fric_decel() * ROLL_RESIST_SCALE


# 风阻的一帧衰减系数：1/(1+drag·dt/mass)（隐式积分，任意 dt 都稳定，不会过冲变负）。
# ★ 越重受影响越小（a_drag = drag·v·m/mass 的归一化写法）。
func _drag_mul(delta: float) -> float:
	if air_drag <= 0.0:
		return 1.0
	return 1.0 / (1.0 + air_drag * delta * _mass_inertia())


# ★★ 本帧**能用的摩擦冲量上限** = μ × 法向冲量（单位质量，直接是可减掉的切向速度 px/s）。
# 法向冲量有两块来源：① 重力那一份 = g·dt（稳态贴地滑动，等于旧写法 μ·g·dt）；
# ② 撞击那一份 = 本帧被接触吸收掉的法向速度 —— 落地、砸到下一面、被支撑顶住都算。
# ★ 旧模型只有 ①：球以 400px/s 落地时，把 ω 拉到无滑移需要 35 帧（0.58s）的可见打滑，
#   而水平方向这段时间几乎不掉速 → 观感就是「先落到底、顿一下才滚」（批次 538 实测）。
#   Box2D/Flash 的摩擦约束本来就是 `|P_t| ≤ μ·|P_n|`，撞击时 P_n 巨大 → 一帧咬地起滚。
func _fric_impulse_budget(delta: float, impulse: float) -> float:
	return clampf(friction_coef, 0.0, 2.0) * (_gravity_px() * delta + maxf(0.0, impulse))


# ★★ 接触「吃掉法向速度」那一帧的统一收尾：先记冲量，再按恢复系数把其中一部分转回**向上**。
# 必须在**吸收点**做（圆形件贴地、刚体平地分支），不能只写在 `_physics_step` 的 blocked_y 里：
# 落下来那一步刚好贴到表面（不穿透）→ SAT 不报挡 → blocked_y 恒假 → 弹性形同虚设。
# ★ 只改 y：切向速度归 `_move_velocity` / 坡面切向管，竖直分量才代表「离开表面」。
func _land_absorb(v: float, nrm: Vector2) -> void:
	_note_contact_impulse(v, nrm)
	var up: float = maxf(0.0, v) * clampf(restitution, 0.0, 0.9)
	if up > LAND_MIN_SPEED:
		_gravity_velocity.y = -up


# 记下「本帧接触吸收掉的法向速度」，供下一帧的摩擦预算与挤压形变使用。
func _note_contact_impulse(v: float, nrm: Vector2) -> void:
	var a := maxf(0.0, v)
	if a <= 0.01:
		return
	_contact_impulse = maxf(_contact_impulse, a)
	# 形变按撞击强弱打满（与 squash_amount 相乘后才作用到 scale）
	var target: float = clampf(a / SQUASH_FULL_SPEED, 0.0, 1.0)
	if nrm != Vector2.ZERO:
		_squash_normal = nrm
	if target > _squash:
		_squash = target
		_squash_vel = 0.0
		# ★ 撞击当帧就把扁做出来（否则要等下一帧的 _squash_step 才 visible，
		#   接触的那一下正好是最该看见的 16ms）
		_apply_squash_transform()


# ---- 落地挤压回弹（纯视觉：只动 scale，不碰碰撞体、力矩、质心）----
# 弹簧：受 _squash 的当前值驱动，回拉到 0 时因欠阻尼（ZETA<1）轻微过冲成负值 = 拉伸，
# 于是「砸扁 → 弹起 → 拉长一点 → 归位」，正是 Flash 小物件那一下。
func _squash_step(delta: float) -> void:
	if not _squash_visual_active():
		# ★ 一旦不再可见就**彻底清零**，不是只清 scale：欠阻尼的尾巴可能在某一帧
		#   同时满足「形变已小于阈值」而「速度还大于阈值」，那时 `_squash_visual_active()`
		#   返回 false → 弹簧当场停摆，把 0.0004 这种残留永久冻在状态里
		#   （下一次撞击的 target 若更小就被 `target > _squash` 挡掉 = 轻砸不形变）。
		if _squash != 0.0 or _squash_vel != 0.0:
			_squash = 0.0
			_squash_vel = 0.0
		if scale != Vector2.ONE:
			scale = Vector2.ONE
		return
	var k: float = maxf(2.0, squash_stiffness)
	# 半隐式积分：先更新速度再更新位移，欠阻尼下也不会发散
	_squash_vel += (-k * k * _squash - 2.0 * SQUASH_ZETA * k * _squash_vel) * delta
	_squash += _squash_vel * delta
	# ★ 拉伸相位限幅：欠阻尼的自然过冲约 −0.27，留一点余量；
	#   再大就会「拉长到 1.5 倍」——看着像橡皮虫，而且绕中心拉长时下缘会插进支撑面里。
	_squash = clampf(_squash, -0.35, 1.0)
	if absf(_squash) < 0.002 and absf(_squash_vel) < 0.05:
		_squash = 0.0
		_squash_vel = 0.0
	_apply_squash_transform()


func _squash_visual_active() -> bool:
	if squash_amount <= 0.001:
		return false
	if absf(_squash) < 0.0005:
		return false
	# 系统积木（屏障 / 图标边界 / 页面边框覆盖 / 桌面图标）不参与形变：桌面必须保持笔直
	for t in tags:
		if str(t) in BlockTags.SYSTEM_TAGS or str(t) == BlockTags.DESKTOP_ICON:
			return false
	return true


# 沿接触法线压扁 s、垂直方向鼓出 0.55s —— 只动 `scale`（Node2D 的变换）。
# ★ 为什么不去钉住接触点：Godot 4.7 的 Node2D 只有 position/rotation/scale/skew，
#   旧版的 pivot_offset、offset 都不存在了（实测 get_property_list 里没有）；
#   而 `position` 是物理的唯一真值（OBB、质心、支撑探测都直接读 global_position），
#   为了视觉效果去挪它 → 邻居积木本帧会按偏移后的位置做碰撞 → 抖动。
#   所以这里接受「绕中心压扁」：下缘抬起的量 = s·h/2（默认参数、典型落地≈1~2px，
#   且此时弹性本来就在把积木往上抬），代价小、也不会污染物理。
func _apply_squash_transform() -> void:
	var s: float = clampf(_squash * squash_amount, -SQUASH_MAX, SQUASH_MAX)
	if absf(s) < 0.0005:
		scale = Vector2.ONE
		return
	# 把世界法线转回本地，挑最接近的那根本地轴做非等比缩放（Node2D.scale 只能沿本地轴）
	var ln: Vector2 = _squash_normal.rotated(-rotation)
	var vertical: bool = absf(ln.y) >= absf(ln.x)
	var shrink: float = 1.0 - s
	var bulge: float = 1.0 + s * 0.55
	scale = Vector2(bulge, shrink) if vertical else Vector2(shrink, bulge)


# 某「相对中心」的点正下方是否有碰撞支撑（用于可滚动）：
# 探测点 = 本积木中心 + (local_x, local_y_offset)，落入任一 collidable 积木的 OBB 即算有支撑。
func _support_at(local_x: float, local_y_offset: float) -> bool:
	var p := Vector2(global_position.x + local_x, global_position.y + local_y_offset)
	var tree := get_tree()
	if tree == null:
		return false
	var my_scene: Node = _scene_of()
	for other in tree.get_nodes_in_group("block"):
		if not is_instance_valid(other) or other == self or not (other is Block):
			continue
		var ob: Block = other
		if ob._scene_of() != my_scene:
			continue
		if ob._is_in_subtree_of(self):
			continue
		if not ob._has_collision():
			continue
		if not _collision_layers_intersect(collision_layer, ob.collision_layer):
			continue
		if ob._obb_contains_point(ob.global_position, p):
			return true
	return false

# 本积木中心偏移 local_x 处的「底部向下」支撑深度（从底边 ry 起、首次探到碰撞支撑的向下距离，
# 单位像素；探不到返回 INF）。用于可滚动的「平地 / 斜坡 / 贴墙平地 / 边缘」区分：
#   · 重心正下方深度为 INF（悬空）→ 翻滚掉落；左右深度相等（平地 / 贴墙平地）→ 稳定；
#   · 左右深度不等（斜坡）→ 朝更深（更低）那侧真滚。
# ★ 用「局部点下探」(_support_at) 而非整块平移探针：整块平移会把半悬积木误判为整条底边都有支撑。
func _support_depth(local_x: float) -> float:
	var ry: float = _shape_radius_y()
	var d: float = ROLL_PROBE
	var max_d: float = 48.0
	var step_d: float = 6.0
	while d <= max_d:
		if _support_at(local_x, ry + d):
			return d
		d += step_d
	return INF

# ★ 批次 534：原「_needs_flat_settle / _flat_settle」已删除 ——
#   旧的「强行把 rotation 回正到 k·π/2 + 把中心压到贴地高度」是**瞬移式**的姿态矫正，
#   会与自转互相拉扯（抖动），也无法解决「角落地」——角着地的积木根本进不了这条分支。
#   现在改由刚体支点公转（_rb_step / _rb_topple）自然完成：单角着地 → 绕该角公转 → 翻到边着地；
#   边着地的稳定姿态恰好就是「某一边朝下」（rotation ≈ k·π/2），与旧需求一致且无瞬移。

# ---- 拖动（标签 draggable）----
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# 可拖动 或 带按钮标签（button_XXX）的积木都接收左键，进入「待判定」：
		#   可拖动 → 位移超阈值转拖动；按钮 → 双击发信号。都会先占用这次按下，不落全局框选。
		var clickable := BlockTags.has_button(tags) or BlockTags.DRAGGABLE in tags
		if clickable and Block._dragging_block == null and not _pending_drag:
			# 命中本积木（AABB 近似，忽略旋转）→ 进入「待判定拖动」。
			# 先不立即拖：位移超阈值才由 _physics_step 转成真拖动，否则松开就是点击/双击，
			# 避免双击时产生一丁点拖动/图层切换。按住本积木按下的事件同样被吞掉（不落到 desktop 框选）。
			var mp := get_global_mouse_position()
			# ★★ 被更高的镂空遮罩盖住 → 该点上本积木已被视觉抹掉：既不入「待判定拖动」（挡住拖动），
			#   也不吞事件（留给真正的上层）。于是"看得见的地方才点得动"，不再出现某块区域无法操作。
			# 命中测试用 OBB（随 rotation 旋转），与碰撞箱一致。
			if _obb_contains_point(global_position, mp) and not is_point_covered(mp):
				_pending_drag = true
				_drag_press_pos = mp
				_drag_offset = global_position - _drag_press_pos
				get_viewport().set_input_as_handled()

func _start_drag() -> void:
	_is_dragging = true
	Block._dragging_block = self
	# 拖动 = 手动接管 → 放弃未完成的「移到此处」命令（否则松手后又自己跑走）
	cancel_command_move()
	_drag_offset = global_position - get_global_mouse_position()
	_gravity_velocity = Vector2.ZERO
	_on_floor = false
	# 碰撞图层临时覆盖为「被拖动中」(BlockLayers.DRAGGING)
	_enter_drag_layer()

func _stop_drag() -> void:
	_is_dragging = false
	if Block._dragging_block == self:
		Block._dragging_block = null
	# 松开 → 恢复拖动前的碰撞图层
	_exit_drag_layer()
	# 伪装图标对齐：带 DESKTOP_ICON 标签的积木在松开时吸附到桌面图标网格（未按 Ctrl 时）
	_snap_to_desktop_icon()


# ---- 桌面伪装图标的「松手对齐」（标签 BlockTags.DESKTOP_ICON）----
#
# 需求：虚视跳转器 / 回收站 / 此电脑 这类"伪装成桌面图标"的积木很难和真的桌面图标对齐，
#   所以拖动松手后自动吸附到**桌面图标会在的位置**（桌面图标网格）；
#   ★ 按住 Ctrl 拖动 = 自由摆放：松手停在原地，不做任何吸附（给玩家精确摆放的出口）。
#
# 网格由 desktop.gd 提供（snap_to_desktop_icon，数据与图标边界墙同源）——
# 这里沿父链找宿主，避免 Block 反向依赖具体场景类型（关卡里的积木宿主是关卡页，自然找不到 → 不对齐）。
func _snap_to_desktop_icon() -> void:
	if not (BlockTags.DESKTOP_ICON in tags):
		return
	# ★ 按住 Ctrl（左/右均可）→ 完全自由，不吸附
	if Input.is_key_pressed(KEY_CTRL):
		return
	var host := _find_snap_host()
	if host == null:
		return
	# ★ 批次 121：把自身（self）一并传出，供宿主 desktop 排除"正在移动松手的这块"自身，
	#   避免它去避让自己当前所在的格位而乱跳。
	var target: Vector2 = host.call("snap_to_desktop_icon", global_position, self)
	if target.distance_to(global_position) < 0.5:
		return          # 本来就在格位上（含"无图标数据 → 原样返回"）→ 不动，也不打日志
	global_position = target
	print("[Block] 伪装图标松手对齐 %s → %s" % [string_id, str(target)])


## 沿父链找到能提供桌面图标网格的宿主（desktop）；找不到返回 null。
func _find_snap_host() -> Node:
	var n: Node = get_parent()
	while n != null:
		if n.has_method("snap_to_desktop_icon"):
			return n
		n = n.get_parent()
	return null

# ============ 拖动期间的碰撞图层覆盖（「被拖动中」= dragging）============
# 需求：拖动中的积木"有时需要被阻挡，有时不需要"，所以**不能**把图层清空，
#   而是临时换成一个专门的层，让别的积木自己决定要不要挡它。
#   - 覆盖期间图层 = [dragging]：普通积木（[default]）与它无交集 → 拖动时不被它们阻挡
#     （可以穿过地面、穿过其他普通积木，拖动体验顺滑）；
#   - 想让某个积木**挡住**被拖动的东西：把它的碰撞图层写成 "default,dragging"（或只写 dragging）；
#   - 松手后立刻恢复成拖动前那一份图层（多层、自定义层都原样还原）。
# 注意：[dragging] 是**非空集合**，被拖动的积木依旧具备碰撞体（_has_collision() 为真）。
func _enter_drag_layer() -> void:
	if _drag_layer_saved:
		return
	_pre_drag_collision_layer = PackedStringArray(collision_layer)   # 备份（含自定义/多层）
	_drag_layer_saved = true
	collision_layer = PackedStringArray([BlockLayers.DRAGGING])

func _exit_drag_layer() -> void:
	if not _drag_layer_saved:
		return
	_drag_layer_saved = false
	collision_layer = _pre_drag_collision_layer

## 一次「单击」落下：若本积木带按钮标签（button_XXX），累积两次靠近的点击
## （间隔 ≤ DOUBLE_CLICK_MS 且两点距离 ≤ DRAG_THRESHOLD）→ 视为双击 → 发出按钮信号，
## 供事件链 / 脚本做后续行动。非按钮积木这里是空操作。
func _register_click() -> void:
	var keys := BlockTags.button_keys(tags)
	if keys.is_empty():
		return
	var now := Time.get_ticks_msec()
	var mpos := get_global_mouse_position()
	if _last_click_time >= 0.0 \
			and (now - _last_click_time) <= DOUBLE_CLICK_MS \
			and mpos.distance_to(_last_click_pos) <= DRAG_THRESHOLD:
		# 双击达成：发出所有 button_XXX 信号
		for k in keys:
			button_activated.emit(k)
			# 同步到全局信号总线，供关卡页面等跨积木监听（见 SignalBus）
			if SignalBus != null:
				SignalBus.emit_block_button(k)
			print("[Block] id=%d 双击按钮 → 发信号 button_%s" % [id, k])
		_last_click_time = -1.0     # 消费本次双击，避免三连击再次触发
		_last_click_pos = Vector2.ZERO
		return
	_last_click_time = now
	_last_click_pos = mpos

## 拖动期间生效的碰撞图层（供属性面板 / 事件链查询；非拖动中返回自身图层）
func is_dragging() -> bool:
	return _is_dragging


# ============ 检测标签（待检测_XXX → 检测到_XXX）============
# 规则（与 block_tags.gd 的说明一致）：
#   1) 本积木带 to_detect_XXX（待检测_XXX）→ 本积木是「检测区」；
#   2) 任何**其他**积木 B 的**中心点**落在检测区内 → B 自动获得 detected_XXX（检测到_XXX）；
#   3) B 的中心点不再落在**任何**带 to_detect_XXX 的积木内 → 自动移除 detected_XXX。
#   XXX 可自由替换，待检测与检测到始终成对（to_detect_红 ↔ detected_红）。
#
# ★★ 判据 = 「B 的中心点是否落在检测区矩形内」，**不是** AABB 重叠：
#   重叠判定下 B 只要用一角蹭到检测区就被判"检测到"，玩家在画面上根本看不出它进了区；
#   改判中心点后，「B 真的进到区里面」与「标签生效」在视觉上同步
#   （与 portal_manager.gd 的"中心点进入口"是同一条几何规则）。
#   ★ 代价（有意为之）：**站在检测区上面**不再算命中 —— 顶部支撑时 B 的中心在检测区上方；
#     想表达"踩在上面就获得能力"，要把 B 换成能**走进区内部**（检测区图层与它不同即可穿进去）。
# 判定**不看碰撞图层，也不要求 collision 标签**：
#   实际使用中检测区常与被检测物处在不同图层（互不阻挡），被检测物因此能"走进去"；
#   这正是本机制最常见的用法。
#
# 标签的增删是**集合操作**且幂等：每帧只对"本帧新进入 / 本帧刚离开"的积木动作。
# 移除采用**引用计数**（一个被检测积木可能同时被多个同键检测区扫到）。

## 本积木是否带任意「待检测_XXX」标签
func has_pending_detect() -> bool:
	return BlockTags.has_pending_detect(tags)


## 本积木当前携带的全部「待检测_XXX」的键
func get_pending_detect_keys() -> Array[String]:
	return BlockTags.pending_detect_keys(tags)


## 本积木当前因检测而获得的「检测到_XXX」标签（不含手动写的同名标签中未被登记的部分）
## 返回形如 { 键: 检测者数 }
func get_detected_tags() -> Dictionary:
	var out: Dictionary = {}
	for k in _detect_sources.keys():
		out[BlockTags.detected_tag(k)] = (_detect_sources[k] as Dictionary).size()
	return out


# 每物理帧：作为「检测区」扫描一次
func _detect_scan() -> void:
	# (0) ★ 快路径：绝大多数积木既没有「待检测_XXX」标签、也从没扫到过谁 → 直接返回。
	#     这里刻意**不调用** BlockTags.pending_detect_keys(tags)：那是一个静态函数调用，
	#     要把 tags（PackedStringArray）当实参传进去，而本项目这个 Godot 构建对
	#     PackedStringArray 形参偶发误判/不稳（历史上出现过 "Cannot convert argument N from
	#     PackedStringArray to PackedStringArray" 的假报错）。_physics_process 里每秒要执行
	#     上万次这种调用（数百积木 × 60fps），是崩溃日志里唯一被抓到的 GDScript 现场
	#     （pending_detect_keys ← _detect_scan ← _physics_process）→ 改成在本地做一次前缀判断，
	#     零参数传递。语义与原实现完全一致：只有「没有待检测标签 且 没有待释放记录」才提前返回。
	var any_pending := false
	for t in tags:
		if t.begins_with(BlockTags.DETECT_PENDING_PREFIX):
			any_pending = true
			break
	if not any_pending and _detect_prev.is_empty():
		return
	var keys := BlockTags.pending_detect_keys(tags)
	# (1) 标签被删/被改 → 之前扫到的积木要全部释放（否则 detected_XXX 会永久残留）
	for k in _detect_prev.keys():
		if not (k in keys):
			_release_detect_key(k)
	# (2) 没有待检测标签（绝大多数积木）→ 到此为止
	if keys.is_empty():
		return
	var tree := get_tree()
	if tree == null:
		return
	var all_blocks: Array = tree.get_nodes_in_group("block")
	# 判定范围 = 自身矩形（检测区）。判据是"对方**中心点**是否落在此矩形内"（见本节省首注释）。
	var my_rect := _aabb_at(global_position)
	# ★★ 「检测区」与「被检测积木」必须**同场景**（都在桌面，或都在**同一个**关卡页面）。
	#   否则：移动关卡页面 / 传送搬运时，积木的全局坐标会跨场景浮动，一旦与另一场景里
	#   静止的积木 AABB 重叠 → 误加/误删 detected_XXX（与传送门误传送同族）。
	#   ★ 归属判定用 _scene_of()（沿祖先找最近的 LevelPage，找不到=桌面），**不能比全局坐标**。
	var my_scene: Node = _scene_of()
	for k in keys:
		var now: Dictionary = {}
		for ob in all_blocks:
			# ★ 先 is_instance_valid 再 `is Block`：all_blocks 是本帧取到的**快照**，
			#   循环里若某个积木被释放，它会变成已释放实例 → `ob is Block` 抛硬错误。
			if not is_instance_valid(ob) or ob == self or not (ob is Block):
				continue
			var other: Block = ob
			# ★★ 同场景闸门：跨场景一律不检测（见上）。
			if other._scene_of() != my_scene:
				continue
			# ★ 判据：对方**中心点**落在本检测区矩形内 → 命中（见本节省首注释）。
			#   这里**不取** other 的 AABB：只用它自己的 global_position 当点、尺寸无关，
			#   所以不存在旧实现那种"拿错尺寸构造矩形"的坑（旧实现要靠 other 的 AABB 才需要）。
			if my_rect.has_point(other.global_position):
				now[other.id] = true
		var prev: Dictionary = _detect_prev.get(k, {})
		# 本帧接触到的 → **全量**登记（幂等，且带自愈：标签被外部脚本删掉也会在下一帧补回）
		for bid in now:
			var b_in := _find_block_by_id(int(bid))
			if b_in != null:
				b_in._detect_acquire(self, k)
		# 本帧刚离开的 → 通知对面释放（对面可能还被别的检测区罩着，由它自己判断）
		for bid in prev:
			if not now.has(bid):
				var b_out := _find_block_by_id(int(bid))
				if b_out != null:
					b_out._detect_release(self, k)
		_detect_prev[k] = now


# 本积木所属「场景」：沿祖先链找最近的关卡面板（LevelPage）即属于该场景；否则为桌面（返回 null）。
# ★★ 与 portal_manager.gd::_scene_of 同款：**归属**判定的唯一尺子，绝不能改用全局坐标比较。
#    必须先 is_instance_valid 再 `is LevelPage`：搬运/清场途中祖先链上可能有已释放节点，
#    对已释放实例执行 `is` 会抛「previously freed instance」硬错误。
func _scene_of() -> Node:
	var n: Node = self
	while n != null:
		if not is_instance_valid(n):
			return null
		# ★ 关卡页与家园页都是「场景归属」：沿祖先链找到最近的任一种即归该场景。
		if n is LevelPage or n is HomePage:
			return n
		n = n.get_parent()
	return null


# 释放某个键上"我扫到的全部积木"（标签被移除 / 本积木离开场景树时调用）
func _release_detect_key(k: String) -> void:
	var prev: Dictionary = _detect_prev.get(k, {})
	for bid in prev:
		var b := _find_block_by_id(int(bid))
		if b != null:
			b._detect_release(self, k)
	_detect_prev.erase(k)


func _detect_release_all() -> void:
	for k in _detect_prev.keys():
		_release_detect_key(k)
	_detect_sources.clear()


# ---- 以下两个由「检测区」回调，作用在**被检测的积木**上 ----

# 被 detector 扫到 → 登记来源并确保标签存在（幂等；标签被外部删掉会在这里补回）
func _detect_acquire(detector: Block, k: String) -> void:
	var src: Dictionary = _detect_sources.get(k, {})
	if not src.has(detector.id):
		src[detector.id] = true
		_detect_sources[k] = src
	var tag := BlockTags.detected_tag(k)
	if not (tag in tags):
		var t := PackedStringArray(tags)
		t.append(tag)
		tags = t
		print("[Block] id=%d 获得标签 %s（检测区 id=%d）" % [id, tag, detector.id])


# detector 不再扫到我 → 注销来源；**所有**来源都走了才真正移除标签
func _detect_release(detector: Block, k: String) -> void:
	if not _detect_sources.has(k):
		return
	var src: Dictionary = _detect_sources[k]
	src.erase(detector.id)
	if not src.is_empty():
		_detect_sources[k] = src
		return
	_detect_sources.erase(k)
	var tag := BlockTags.detected_tag(k)
	if tag in tags:
		var t := PackedStringArray(tags)
		t.remove_at(t.find(tag))
		tags = t
		print("[Block] id=%d 移除标签 %s（检测区 id=%d 离开）" % [id, tag, detector.id])
