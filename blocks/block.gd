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
			_draw_image_fill(rect, fill)
		elif BlockTags.FILL in tags:
			draw_rect(rect, fill_color)
	# 边框（cutout 的边框改由 _border_item 子画布在洞之后绘制，避免被自己的洞抠掉）
	if BlockTags.BORDER in tags and not (BlockTags.CUTOUT in tags):
		draw_rect(rect, border_color, false, border_width)
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
	var _last_size := Vector2.INF
	func _draw() -> void:
		if block == null or not is_instance_valid(block):
			return
		draw_rect(Rect2(-block.width / 2.0, -block.height / 2.0, block.width, block.height),
			Color(0, 0, 0, 0))
	func _process(_delta: float) -> void:
		# 尺寸变化随动；位置由父节点带动（子画布随父移动），无需处理
		if block == null or not is_instance_valid(block):
			return
		var s := Vector2(block.width, block.height)
		if s != _last_size:
			_last_size = s
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
		draw_rect(Rect2(-block.width / 2.0, -block.height / 2.0, block.width, block.height),
			block.border_color, false, block.border_width)
	func _process(_delta: float) -> void:
		if block == null or not is_instance_valid(block):
			return
		var sig := "%s|%s|%s|%s|%s" % [str(block.width), str(block.height),
			str(block.border_color), str(block.border_width),
			"1" if (BlockTags.BORDER in block.tags) else "0"]
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
		if ob._aabb_at(ob.global_position).has_point(p):
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
		"fill_image_path":
			tb.fill_image_path = str(value)
			refresh_text_boxes()
		_:
			push_warning("[Block] 未知文本框变量: %s" % prop)
			return false
	return true

# 图片填充绘制：按 src.path 取贴图，依 src.fill_mode 决定铺法。
#   KEEP_MAX_RATIO 等比缩放完整显示并居中（默认） / FILL 拉伸铺满（可能变形） /
#   CENTER 居中原尺寸 / TILE 平铺重复 / ORIGINAL 左上角原尺寸。
# ★ 仅实现**静态图**：anim_type = ANIMATED(动图) / SKELETON(骨骼) 仍按静态图绘制首帧，
#   播放逻辑待资源系统接入（TODO）。贴图加载失败 → 纯色兜底，不让坏路径报错刷屏。
func _draw_image_fill(rect: Rect2, src: BlockFill) -> void:
	if src == null:
		draw_rect(rect, fill_color)
		return
	var tex := TextureCache.fetch(src.path)
	if tex == null:
		draw_rect(rect, fill_color)
		return
	var tsize: Vector2 = tex.get_size()
	if tsize.x <= 0.0 or tsize.y <= 0.0:
		draw_rect(rect, fill_color)
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
# 迁移自旧版 block.gd + main.gd 的移动逻辑（v0.1.25 定稿行为），简化为 AABB 碰撞：
#   - 旋转不参与碰撞判定（按未旋转 AABB 近似，待后续需要时再引入 SAT）
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

# ---- 运动参数（「积木运动」面板 / ui/block_motion_panel.gd）----
# 进一步细化受控移动：把原本写死的 MOVE_SPEED 拆成「每块可配的最大速度 + 加速度」。
#   can_fly           可飞行：**不受重力**（悬停），且可按住 W/↑ 上升、S/↓ 下降（仍需 controlled 标签）。
#   horiz_max_speed   水平最大速度（像素/秒）。非飞行时同时就是整体移动速度上限（斜向不叠加，同旧版）。
#   horiz_accel       水平加速度（像素/秒²）。★ <=0 视为「瞬时到位」（保留旧版手感，也是默认值）。
#   fly_up_max_speed  飞行上升最大速度（像素/秒）；飞行下降复用同一速度值。
#   fly_up_accel      飞行上升加速度（像素/秒²）。★ <=0 视为「瞬时到位」。
# ★ 全部有默认值 → 存量积木 / 未带这些键的类型 JSON 行为完全不变。
@export var can_fly: bool = false
@export var horiz_max_speed: float = MOVE_SPEED
@export var horiz_accel: float = 0.0
@export var fly_up_max_speed: float = MOVE_SPEED
@export var fly_up_accel: float = 0.0

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

# 以 pos 为中心的 AABB（忽略旋转的近似）
func _aabb_at(pos: Vector2) -> Rect2:
	return Rect2(pos.x - width / 2.0, pos.y - height / 2.0, width, height)

# 以 pos 为中心的 AABB 与 other 的 AABB 的重叠深度（0 = 未重叠）。
# 本项目碰撞不做旋转（按未旋转 AABB 近似），故深度 = 两轴重叠量的较小值。
func _penetration_at(pos: Vector2, other: Block) -> float:
	var a := _aabb_at(pos)
	var b := other._aabb_at(other.global_position)
	var ox: float = minf(a.end.x, b.end.x) - maxf(a.position.x, b.position.x)
	var oy: float = minf(a.end.y, b.end.y) - maxf(a.position.y, b.position.y)
	if ox <= 0.0 or oy <= 0.0:
		return 0.0
	return minf(ox, oy)

# 判断能否移动到 target（绝对判据：对任一积木穿透 > 容差即阻挡）
# 例外：**自己携带的子树**（自己的子级及其后代）不算障碍物 ——
#   父级不该被自己带的东西卡住，否则"子级压在父级侧面/上方"时父级会被自己锁死。
func _can_move_to(target: Vector2) -> bool:
	if not _has_collision():
		return true
	var tree := get_tree()
	if tree == null:
		return true
	var my_rect := _aabb_at(target).grow(-MOVE_COLLISION_EPSILON)
	var my_scene: Node = _scene_of()
	for other in tree.get_nodes_in_group("block"):
		# ★ 先 is_instance_valid 再 `is Block`（同 portal_manager）：组里可能残留已释放节点，
		#   对已释放实例执行 `is` 会抛「previously freed instance」硬脚本错误。
		if not is_instance_valid(other) or other == self or not (other is Block):
			continue
		var ob: Block = other
		# ★★ 同场景闸门：只有同一归属的积木才互相碰撞阻挡。
		#   组是**全局快照**、AABB 是**全局坐标** —— 关卡积木被页面平移/搬运时全局坐标会扫过
		#   另一场景的静止积木，缺此闸门就会被"隔场景"挡住（同 portal_manager / _detect_scan）。
		if ob._scene_of() != my_scene:
			continue
		if ob._is_in_subtree_of(self):
			continue
		if not ob._has_collision():
			continue
		if not _collision_layers_intersect(collision_layer, ob.collision_layer):
			continue
		# 缩边后相交测试："恰好贴着"（穿透 ≤ 容差）不算重叠 → 可沿接触面滑动
		if my_rect.intersects(ob._aabb_at(ob.global_position), true):
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
	if not can_fly and BlockTags.GRAVITY in tags:
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
	if can_fly:
		if motion.x != 0.0:
			var tvx: float = motion.x * horiz_max_speed
			_move_velocity.x = move_toward(_move_velocity.x, tvx, horiz_accel * delta) if horiz_accel > 0.0 else tvx
		else:
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
		else:
			_move_velocity = _move_velocity.move_toward(Vector2.ZERO, MOVE_DECAY_RATE * delta)

	# 重力累积（无 gravity 标签 或 可飞行 → 不下落）
	if BlockTags.GRAVITY in tags and not can_fly:
		var g: float = ProjectSettings.get_setting("physics/2d/default_gravity", 980.0)
		_gravity_velocity.y += g * delta
	else:
		_gravity_velocity = Vector2.ZERO

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
	var r := _try_move(total * delta)

	# 落地状态机：下落被挡 → 落地；竖直方向成功移动 → 离地
	if bool(r["blocked_y"]) and total.y > 0.0:
		_on_floor = true
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
	if not (BlockTags.GRAVITY in tags):
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
			if _aabb_at(global_position).has_point(mp) and not is_point_covered(mp):
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
	var target: Vector2 = host.call("snap_to_desktop_icon", global_position)
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
		if n is LevelPage:
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
