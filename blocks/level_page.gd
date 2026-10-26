# level_page.gd
# 「关卡」页面 —— 未来的关卡场景会"投影"到这块页面上（投影本身先不实现）。
#
# 本版把页面做成与背包/设置一致的 **UI 面板窗口**（UIPanel 圆角半透明 + 可见边框），
# 面板本身即「页面主体」，上面放关卡页面已有的控件：
#   · 左上角「移动把柄」：UIDragHandle（复用设置页同款），拖动整个面板平移；
#   · 把柄右侧「关卡名称」：UI 标签，绑定全局变量（默认 level_title），变量一变实时刷新；
#   · 右下角「调大小把柄」：UIResizeHandle，沿对角线拖动调整面板大小。
#
# ★★ 左上角最左端还有「折叠/展开」按钮 + 展开的「关卡配置」浮层面板（**仅调试模式**可见）：
#   · 面板里放的是**关卡级**配置（不属于任何一块积木）：
#       ① 摄像头锚定的目标 —— 按积木 ID 锚定关卡摄像头（空/0 = 自由平移）。
#          原先在「调试面板」里，本批迁到这里（关卡的事归关卡页面管）。
#       ② 关卡环境 —— 关卡标签集合（可选「单元/起点/终点/奖励箱」）。行尾两个按钮复用
#          标签选择窗（TagPickerPanel 的 LEVEL 模式）与长文本窗（UILongTextInputPanel）。
#          ★ 当前**仅作标注**、不影响任何玩法；随关卡一起落盘（levels/<名>.json 的 "env"）。
#   · 显隐统一由 _refresh_cfg_visible() 管（Debug.debug_mode + _cfg_open 两个条件）。
#
# 采用 UI 面板而非积木：① 边框/背景由 UIPanel 稳定绘制、不会再"看不见"；
# ② 可见 Control 会被 MousePassRunner._collect_controls 自动计入桌面穿透接收区，
# 穿透开启时不会被 SetWindowRgn 裁掉。
#
# ★ 层级：由 desktop 挂在**独立 CanvasLayer(99)** 里（低于浮层 ui_layer=100）——页面是
#   「世界表面」，**不跟随设置里的 UI 缩放**（理由见 desktop._setup_level_page 的说明）。
class_name LevelPage
extends Control

# ★ 关卡页在「可拖动背景」上判定为**右键单击**（位移未超拖动阈值）时发出，桌面据此补弹右键菜单。
#   为什么用信号：右键在可拖动背景上按下时无法区分"单击 / 按住拖动"——只能先吞掉按下、
#   等抬起（或位移越阈）再定；判定为单击时由本页主动通知桌面弹菜单，否则这次右键就丢了。
signal right_click_at(screen_pos: Vector2)

# 面板大小上下限。
# ★ 最小值**锁定为分辨率的 0.5 倍**（宽、高各取屏幕分辨率的一半），保证关卡视野始终够大，
#   面板再怎么拖也不会缩成一个小窗口。实际取值见 min_page_size() / max_page_size()（动态算）。
const MIN_SCREEN_RATIO: float = 0.5
const MIN_W_FLOOR: float = 240.0    # 兜底下限（headless / 异常分辨率时 screen 尺寸为 0）
const MIN_H_FLOOR: float = 160.0
const MAX_W_FLOOR: float = 1400.0
const MAX_H_FLOOR: float = 900.0
const PADDING: float = 12.0

var title_var: String = "level_title"  # 关卡名称绑定的全局变量名
var _visible := false                  # 面板是否显示（由「打开桌面副本」信号切换）

# UI 部件
var _bg: UIPanel = null            # 面板底（边框 + 背景 = UIPanel）
var _title_label: Label = null     # 关卡名称
var _drag_handle: UIDragHandle = null      # 移动把柄
var _resize_handle: UIResizeHandle = null  # 右下角调大小把柄

# ============ 舞台区（深色背景 + 裁剪 + 阻挡提示）============
# _body 是深色背景矩形：这就是积木的"可显示范围"。积木被 _stage_view 裁到本矩形内，
#   落到本矩形外（顶栏/边框/按钮之上）的部分直接不绘制，不会挡住 UI。
# _stage_view 负责裁剪（clip_contents 范围 = 本深色背景矩形）：积木不会画到面板之外、也不会盖住顶栏/按钮。
var _body: UIPanel = null               # 深色背景（UIPanel，填充取自 UIStyle.FILL_LEVEL_STAGE）
var _stage_view: Control = null         # 舞台容器：clip_contents 打开，裁剪掉画到面板外的积木
var _blocked_overlay: Control = null    # （已弃用）原阻挡提示层；StageView 现裁到深色背景，深色背景外积木不再绘制，故不创建。_update_blocked 见其 null 早退。
var _top_bar: Control = null            # 顶栏容器（决定深色背景的上边界）
var _blocked: Array[Block] = []         # 当前「在深色背景之外」的积木

# 关卡投影：`_stage` 是承载关卡积木的 Node2D 舞台（坐标原点 = 面板左上角），
# 关卡积木作为它的 Node2D 子节点，与桌面积木同属一个物理世界 → 交互逻辑通用。
var _stage: Node2D = null              # 关卡舞台（投影积木都挂这里）
var _level_blocks: Array[Block] = []   # 当前投影到面板上的关卡积木
var current_level_name: String = ""    # 当前投影的关卡名（空 = 未投影）
# 桌面世界节点（由 desktop 注入）：关卡积木被传送门送出关卡时退回这里（见 release_block）。
var desktop_world: Node = null

# ============ 关卡摄像头 ============
# 两种移动：① 锚定某个积木（摄像头跟随积木移动）；② 自由（按住鼠标中键平移）。
# 视口中心 = 屏幕中心对准的「关卡坐标」；舞台平移量恒为  stage.position = size*0.5 - 视口中心。
# 关卡积木以 JSON 原生坐标摆在舞台下（不再预居中），居中以摄像头平移实现 → 保存也能原样写回坐标。
# ★★ 锚定目标支持**两种**标识（二选一、互斥）：
#   · 数字 ID `_requested_anchor_id` = `Block.id`，由 BlockManager 在积木入树时分配 ——
#     **每次重新投影/重新载入关卡都会变**，所以只适合"临时看一眼某块积木"。
#   · 字符串 ID `_requested_anchor_sid` = `Block.string_id`（如 start / BedRockXU），
#     随关卡 JSON 的 `string_id` 字段落盘 → **重新投影后依然指向同一块积木**，
#     适合"在关卡配置里写死摄像头跟随哪块积木"。
#   两者不会同时生效：两个入口 set_camera_anchor_id / set_camera_anchor_sid 各自清空对方。
var _requested_anchor_id: int = 0        # 锚定目标的**数字**积木 ID（>0 才生效）
var _requested_anchor_sid: String = ""   # 锚定目标的**字符串**积木 ID（非空才生效，优先于数字）
var _free_center: Vector2 = Vector2.ZERO # 自由平移时视口中心的关卡坐标
# ★★ 平滑跟随（本页摄像头"近稳远追"观感的核心）：
#   · `_cam_center` 是**实际拿去投影**的相机中心（关卡坐标）—— 可能滞后于目标中心（目标 =
#     锚定积木位置 / `_free_center`）。舞台变换恒由它算出，故它才是"可见的"相机中心。
#   · 锚定积木**小幅度**移动 → 目标每帧只挪一点点，相机几乎同步 → 视觉上"稳定跟随"（并天然滤掉抖动）；
#     积木**大幅度**移动（快速拖拽 / 传送 / 物理甩动）→ 相机按更低的速率收敛 → "尝试追上"的滞后观感。
#   · 自由平移**不平滑**（内容要跟手）；载入 / 换锚定 / 解绑 / 缩放 / 拖动锚定块 → 一律直接吸附。
var _cam_center: Vector2 = Vector2.ZERO
var _cam_snap: bool = true               # 下一次更新直接吸附到目标（避免首帧从 (0,0) 或旧视角"飞入"）
# 收敛速率（每秒；指数插值，帧率无关）：距离近→快（几乎锁定），距离远→慢（慢慢追）。
const CAM_FOLLOW_RATE_NEAR: float = 9.0  # 误差≈0 时的速率 → 小幅度移动几乎锁定（稳定跟随）
const CAM_FOLLOW_RATE_FAR: float = 2.2   # 误差≥CAM_LAG_DIST 时的速率 → 大幅度移动明显滞后（追赶观感）
const CAM_LAG_DIST: float = 140.0        # 误差达到该值（关卡坐标像素）即取最慢速率
const CAM_MAX_LAG_FRAC: float = 0.9      # 锚定块离屏幕中心的最大距离 = (面板半尺寸 − 积木半尺寸) × 该比例（防"跟丢"）
var _panning := false                    # 正在**拖动**摄像头（中键按下即拖；右键需位移超阈值才算）
# ★★ 右键「单击 vs 拖动」阈值判定：右键在深色背景下按下时先记 _rdrag_pending（不平移、不解绑），
#   只有屏幕位移 > DRAG_THRESHOLD 才**升级**为拖动（此刻才解绑锚定 + 开始平移）；阈值内抬起 = 单击。
#   阈值用**屏幕像素**（event.position），与桌面左键框选的 DRAG_THRESHOLD 同口径。
const DRAG_THRESHOLD := 6.0
var _rdrag_pending := false              # 右键已按在深色背景上、位移还没到阈值
var _rdrag_start_screen := Vector2.ZERO  # 右键按下时的屏幕坐标（阈值比较基准）

# ============ 关卡属性：允许缩放场景（标签 allow_zoom）============
# 缩放只改**舞台的 scale**（位置按中心补偿），积木的关卡坐标一律不动
#   → 保存出来的 x/y 与当前缩放无关，缩放纯属"看"的事。
# ★ 没这个标签时倍率恒为 1.0（_refresh_env_hint 会在标签消失时主动复位）→ 老关卡行为不变。
const ZOOM_STEP := 1.1                   # 每格滚轮的倍率（正向 ×1.1，反向 ÷1.1）
const ZOOM_MIN := 0.2                    # 缩放下限（1/5）
const ZOOM_MAX := 5.0                    # 缩放上限（5 倍）
var _zoom: float = 1.0                   # 当前缩放倍率（1.0 = 原始大小）

# ============ 保存（仅调试模式） ============
# 顶栏右侧：「保存位置」下拉 + 「保存」按钮。默认项是 MOD（占位），只有「本体」真正写文件到 levels/。
# 关卡下拉的「无选择」项（恒为 index 0）。
# ★★ 为什么必须有它（本次修复的 bug）：`OptionButton.clear()` **不会复位 `selected`**，
#   重建条目后 selected 仍是 0 → 未手动选择也显示"列表第一关"，但「载入」读的是输入框
#   （空 → `_editor_name()` 回落 `current_level_name`）→ 显示的关卡与实际加载的不是同一个；
#   且用户点这个"第一关"时 selected 已经是 0 → OptionButton 内部 `index != selected` 判否 →
#   **`item_selected` 根本不发** → 点它既没反应也加载不了，必须先换一个选择才会触发信号。
#   加上此项后第一个**关卡**的 index 变成 1，点击必然触发。
const LEVEL_NONE_LABEL: String = "（无选择）"
const LEVEL_NONE_INDEX: int = 0

const SAVE_ITEMS: Array = ["本体", "MOD", "DLC"]
# 默认选中「本体」= 点「保存」直接生效。
# （旧版默认 MOD 占位，导致点保存只打印一行提示、什么都没存 —— 改为默认可用。）
const SAVE_DEFAULT_INDEX: int = 0
var _save_bar: Control = null
var _save_option: OptionButton = null
var _save_btn: UIBtn = null

# ============ 关卡名称输入区（仅调试模式） ============
# 顶栏里：关卡名称「输入框 + 已有关卡下拉 + 载入按钮」。
# 这排整体替代原先只读的「关卡名称」标签（非调试模式仍显示标签）。
# ★ 下拉**只在每次点开时**才遍历 levels/（list_level_names），不在启动时枚举。
var _name_bar: Control = null            # 名称输入行容器（与 _title_label 互斥显隐）
var _name_input: LineEdit = null         # 关卡名称输入框（可输入 → 保存/载入都用这个名字）
var _name_option: OptionButton = null    # 已有关卡下拉（点开时才填充）
var _load_btn: UIBtn = null              # 「载入」按钮
# 覆盖确认框：用项目自绘的 UIConfirmPanel（恒居中 + 与其它面板同一套样式）。
# ★ 不用 ConfirmationDialog：它是 Window 子视口，不着项目主题（灰色默认样式）、
#   且位置是屏幕绝对坐标，show() 默认停在 (0,0) → 会弹在屏幕左上角。
var _confirm: UIConfirmPanel = null
var _save_pending: String = ""           # 待确认覆盖的关卡名（确认框点「覆盖」时写入）

# ============ 关卡配置（仅调试模式；左上角「折叠/展开」按钮 + 浮层面板）============
# 面板承载**关卡级**配置（不挂在任何一块积木上）：摄像头锚定目标 + 关卡环境。
# ★ 「关卡环境」的权威数据源就是 _env_input.text（逗号分隔）—— 标签选择窗 / 长文本窗都是
#   往这个输入框里写，故只认它一份、不另存副本（LineEdit.text= 不发 text_changed，
#   所以两窗关闭后各主动刷一次中文回显）。
# ★★ 本页「浮层 UI」（配置面板 / 标签选择窗 / 长文本窗）统一用这个 z_index。
#   为什么必须是**远高于任何积木显示图层**的大数：积木的 `display_layer` 不是 0 ——
#   玩家「右键→新建积木」走 `BlockTypes.create_blank_block()`，而 `res://block_types/Blank.json`
#   写的是 `display_layer: 64`；关卡 JSON 也允许逐块写 display_layer。若这三样东西留在 z=0，
#   任意 display_layer ≥ 1 的关卡积木都会**整块盖住**它们（真机复现：图层 64 的新建积木把
#   「关卡配置」面板和「标签选择」窗全糊掉，采样点仍是纯洋红）。
#   与 desktop 的 SELECTION_Z(4096) 同一套思路：先比 CanvasLayer 层号，同层内再比 z_index。
#   ★ 只抬高这三样，不动积木自己的 display_layer（那是玩家的显式设定，不能被页面偷偷改写）。
const PAGE_OVERLAY_Z: int = 4096
const CONFIG_W: float = 430.0          # 配置面板宽度（固定；高度按内容最小高）
const ROW_LABEL_W: float = 84.0        # 行首标签宽度（两行对齐；也是面板最小宽的来源之一）
const APPLY_BTN_W: float = 46.0        # 「确定」按钮宽度
var _cfg_open := false                 # 配置面板是否展开（按钮 ▼/▶ 与面板显隐都看它）
var _cfg_btn: UIBtn = null             # 左上角「折叠/展开」按钮
var _cfg_panel: PanelContainer = null  # 展开的配置面板（浮在舞台之上）
var _cam_input: LineEdit = null        # 摄像头锚定目标（数字积木 ID 或字符串 ID）
var _cam_status: Label = null          # 锚定结果反馈（绿=成功 / 橙=失败）
var _env_input: LineEdit = null        # 关卡环境（逗号分隔的标签集合）
var _env_hint: Label = null            # 关卡环境解析结果回显（中文名）
# 两个复用的子窗口（不属于本页子树，挂在页面层上 → 不会被 _clear() 顺手带走，须显式关）
var _env_picker: TagPickerPanel = null
var _env_long_panel: UILongTextInputPanel = null

# origin 与 Control.position 互通：桌面按场景坐标给页面定位
var origin: Vector2:
	set(v):
		position = v
	get:
		return position


func _ready() -> void:
	# ★ 必须 IGNORE：桌面右键菜单 / 框选（desktop._unhandled_input）与积木的拖动/选中
	#   （block._unhandled_input）都走「未处理输入」管线；若本页 STOP，会把页面区域内
	#   的全部鼠标事件在 GUI 阶段吞掉 → 关卡里点不了积木、右键也没有菜单。
	#   改 IGNORE 后事件照常落到 _unhandled_input；真正的 UI（按钮/把柄/输入框）
	#   仍是 STOP 控件，照常拦截自己的点击。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


# ---------------- 面板尺寸上下限（随分辨率动态算）----------------
# 最小值 = 分辨率 × 0.5（宽、高各一半）；上限 = 不超过屏幕，同时不低于兜底常量。
func min_page_size() -> Vector2:
	var s := _screen_size()
	return Vector2(
		maxf(s.x * MIN_SCREEN_RATIO, MIN_W_FLOOR),
		maxf(s.y * MIN_SCREEN_RATIO, MIN_H_FLOOR))


func max_page_size() -> Vector2:
	var s := _screen_size()
	return Vector2(maxf(s.x, MAX_W_FLOOR), maxf(s.y, MAX_H_FLOOR))


# 本页面所在画布的「屏幕尺寸」：物理屏 ÷ 本页画布的缩放。
# ★ 页面的 position/size 都是**画布坐标**，而 DisplayServer.screen_get_size() 是物理屏幕像素；
#   两者差一个画布缩放（当前页面层固定 1:1 → 相等，但公式写成通用式，层若缩放也成立）。
func _screen_size() -> Vector2:
	var s := DisplayServer.screen_get_size()
	var f := UIStyle.canvas_scale(self)
	return Vector2(float(s.x) / maxf(f.x, 0.0001), float(s.y) / maxf(f.y, 0.0001))


# 把面板尺寸夹到合法区间（不足最小值时按最小值撑开）。
# 上下限每次都重算，所以换屏 / 改缩放后最小值自动跟着变。
func _clamp_size(v: Vector2) -> Vector2:
	var mn := min_page_size()
	var mx := max_page_size()
	return Vector2(clampf(v.x, mn.x, mx.x), clampf(v.y, mn.y, mx.y))


# 搭起页面：铺面板 + 放控件 + 接线。title_var_name 指定关卡名称绑定的全局变量名。
func build(title_var_name: String = "level_title") -> void:
	title_var = title_var_name
	_clear()
	_build_ui()
	# 建好后就满足「不小于分辨率的一半」：不足则按下限撑开
	size = _clamp_size(size)
	_layout_body()
	_refresh_title()
	_refresh_env_hint()
	if not GlobalVars.changed.is_connected(_on_var_changed):
		GlobalVars.changed.connect(_on_var_changed)
	print("[LevelPage] 关卡页面已生成 pos=%s size=%s 标题变量=%s" % [str(position), str(size), title_var])


# 页面当前是否显示
func is_page_visible() -> bool:
	return _visible


# 显示 / 隐藏整个页面（Control 的 visible；隐藏的控件不绘制、也不会计入穿透接收区）
func set_page_visible(on: bool) -> void:
	_visible = on
	visible = on
	# 页面隐藏 → 挂在页面层上的两个子窗口（标签选择 / 长文本）一并收掉，
	# 否则会留下一个悬空的全屏遮罩挡着桌面。
	if not on:
		_close_sub_panels()
	if MousePassRunner.is_enabled():
		MousePassRunner.force_refresh()
	print("[LevelPage] 关卡页面 → %s" % ("显示" if on else "隐藏"))


# 切换显隐（由「打开桌面副本」信号驱动）
func toggle_page_visible() -> void:
	set_page_visible(not _visible)


# ============ 对外开关入口（事件链等外部系统统一走这里）============

# 打开关卡页面。level_name 非空 → 先把该关卡投影到面板再显示；
# 为空 → 只显示（沿用当前已投影的关卡）。
# 关卡名不存在 / LevelManager 不可用 → 告警但仍然显示页面（不静默失败）。
# 返回页面最终是否可见。
func open_level(level_name: String = "") -> bool:
	var want := level_name.strip_edges()
	if not want.is_empty():
		if LevelManager == null:
			push_warning("[LevelPage] open_level：LevelManager 不可用，忽略关卡名「%s」" % want)
		elif LevelManager.has_level(want):
			project_level(LevelManager.canonical_name(want))
		else:
			push_warning("[LevelPage] open_level：未找到关卡「%s」（可用：%s），只显示关卡页面" % [
				want, str(LevelManager.list_level_names())])
	set_page_visible(true)
	return _visible


# 关闭关卡页面（积木保留在舞台上，下次打开还在）。
func close_level() -> void:
	set_page_visible(false)


# ============ 关卡投影 ============

# 按关卡名把该关卡场景"投影"到本面板上：
#   清掉旧投影 → 从 LevelManager 读 JSON → 把关卡积木以**原生 JSON 坐标**实例化到舞台。
# 居中不靠预偏移，而由摄像头（视口中心 = 积木组中心）实现，这样保存能原样把头坐标写回文件。
# 返回是否成功。加载后关卡名写入绑定的全局变量（title_var），面板标题跟着刷新。
func project_level(level_name: String) -> bool:
	if LevelManager == null:
		push_warning("[LevelPage] LevelManager 不可用，无法投影关卡")
		return false
	var data := LevelManager.load_level(level_name)
	if data.is_empty():
		return false
	_clear_level_blocks()
	var bounds := LevelManager.blocks_bounds(data)
	# ★ 视口中心：优先用关卡 JSON 里保存的相机中心（编辑+保存后再载入 → 保持原视角，不回中）；
	#   旧关卡/无相机字段 → 退回"几何中心居中"（首次投影的默认行为，向后兼容）。
	var cam: Variant = data.get("camera", {})
	if cam is Dictionary and cam.has("x") and cam.has("y"):
		_free_center = Vector2(float(cam["x"]), float(cam["y"]))
	else:
		_free_center = bounds.get_center()
	_ensure_stage()
	# 以 JSON 原生坐标摆放（offset=ZERO），不再平移积木本身，平移交给摄像头 stage.position
	_level_blocks = LevelManager.instantiate_blocks(data, _stage, Vector2.ZERO)
	current_level_name = str(data.get("name", level_name))
	# 关卡环境（标签集合，仅作标注）：随关卡读回；旧关卡没有 "env" 字段 → 清空（向后兼容）
	set_level_env(data.get("env", []))
	# 标题跟随：写全局变量 level_title（面板标签绑定它，见 _refresh_title）
	# 同时把名字回填到调试输入区 → 保存/载入默认沿用当前关卡名
	GlobalVars.set_var(title_var, current_level_name)
	if _name_input != null and is_instance_valid(_name_input):
		_name_input.text = current_level_name
	# ★ 换关卡就回到 1:1 并结束拖动：缩放/拖拽是"看"的临时状态，不该跨关卡串味。
	#   （allow_zoom 只决定"能不能缩放"，不决定"载入时多少倍" → 恒从 1:1 开始）
	_zoom = 1.0
	_panning = false
	_rdrag_pending = false
	_apply_camera()
	_update_blocked()   # 投影后立刻判一遍「谁在深色背景外面」
	print("[LevelPage] 已投影关卡「%s」 积木=%d 面板size=%s 视口中心=%s 锚定=%s 环境=%s" % [
		current_level_name, _level_blocks.size(), str(size), str(_free_center),
		_anchor_desc(), str(level_env())])
	return true


# 按内存中的关卡 dict 投影（不读文件、不依赖关卡名）。
# 与 project_level 同逻辑，但数据来源是传入的 dict —— 用于随机生成的关卡组等
# 「仅生成不保存」场景。返回是否成功。
func project_data(data: Dictionary) -> bool:
	if data.is_empty():
		push_warning("[LevelPage] project_data：空数据，无法投影")
		return false
	if LevelManager == null:
		push_warning("[LevelPage] LevelManager 不可用，无法投影关卡数据")
		return false
	_clear_level_blocks()
	var bounds := LevelManager.blocks_bounds(data)
	var cam: Variant = data.get("camera", {})
	if cam is Dictionary and cam.has("x") and cam.has("y"):
		_free_center = Vector2(float(cam["x"]), float(cam["y"]))
	else:
		_free_center = bounds.get_center()
	_ensure_stage()
	_level_blocks = LevelManager.instantiate_blocks(data, _stage, Vector2.ZERO)
	current_level_name = str(data.get("name", ""))
	set_level_env(data.get("env", []))
	GlobalVars.set_var(title_var, current_level_name)
	if _name_input != null and is_instance_valid(_name_input):
		_name_input.text = current_level_name
	_zoom = 1.0
	_panning = false
	_rdrag_pending = false
	_apply_camera()
	_update_blocked()
	print("[LevelPage] 已投影内存关卡数据「%s」 积木=%d 面板size=%s 视口中心=%s 锚定=%s 环境=%s" % [
		current_level_name, _level_blocks.size(), str(size), str(_free_center),
		_anchor_desc(), str(level_env())])
	return true


# ---------------- 就地新建积木（右键「新建积木」时归入关卡）----------------

# 该**全局**坐标点是否落在本关卡页面矩形内（页面显示时才可能为真）。
# 用于：桌面右键「新建积木」时判断这次新建该进关卡、还是进桌面世界。
func page_contains_global_point(global_pos: Vector2) -> bool:
	if not _visible:
		return false
	var local := get_global_transform().affine_inverse() * global_pos
	return Rect2(Vector2.ZERO, size).has_point(local)


# 换父节点（保持调用方随后自行设定的坐标）。Godot 的 add_child 虽能自动换父，
# 但这里显式 remove + add，语义清楚、也不依赖版本行为。
func _reparent(n: Node, new_parent: Node) -> void:
	if n == null or not is_instance_valid(n) or new_parent == null:
		return
	# ★ 正在排队删除的节点不能搬：add_child 会「复活」一个本节末注定被释放的节点，
	#   之后它被 free → 留在这个新父节点下成为半死节点（下一帧遍历就炸 / 表现为卡死）。
	#   关卡清场（_clear_level_blocks 的 queue_free）与传送门搬运同帧发生时会命中这里。
	if n.is_queued_for_deletion():
		return
	# 不能把节点加进自己的子树（会成环）→ 直接拒绝
	if n == new_parent or new_parent.is_ancestor_of(n):
		return
	var old := n.get_parent()
	if old == new_parent:
		return
	if old != null:
		old.remove_child(n)
	new_parent.add_child(n)


# 换父 + 保持「屏幕上看到的位置」。
# ★★ 跨场景搬运是在**两个画布**之间进行：桌面世界 = 主场景画布（1:1），关卡页面 = 自己的页面层
#   （当前也是 1:1，但两层的缩放**将来可能不同**）。换父后把 global_position 原样抄过去，
#   两个画布缩放不同时积木会在屏幕上跳 s 倍（表现为跨场景传送"位置错乱"）。
#   所以统一按**屏幕像素**中转：换父前 → 屏幕，换父后 → 新画布坐标。当前 1:1 时是恒等变换。
func _reparent_keep_screen(n: Node2D, new_parent: Node) -> void:
	if n == null or not is_instance_valid(n):
		return
	var screen_pos: Vector2 = n.get_canvas_transform() * n.global_position
	_reparent(n, new_parent)
	if not is_instance_valid(n):
		return
	n.global_position = n.get_canvas_transform().affine_inverse() * screen_pos


# 「桌面世界」节点（关卡积木被送出关卡时退回的目标）。由 desktop 在搭建页面时注入，
# 兜底用 current_scene（桌面就是主场景根）。
func _desktop_world() -> Node:
	if desktop_world != null and is_instance_valid(desktop_world):
		return desktop_world
	var tree := get_tree()
	if tree != null and tree.current_scene != null:
		return tree.current_scene
	return null


# 把关卡积木挂进**关卡舞台**（而不是桌面世界）：位置换算成舞台局部（= 关卡原生坐标），
# 并登记进 _level_blocks（保存/清场都按它走）。
# 返回 false = 该点不在页面内（调用方应改挂桌面）。global_pos 为全局坐标。
func add_level_block(blk: Block, global_pos: Vector2) -> bool:
	if blk == null or blk.is_queued_for_deletion() or not page_contains_global_point(global_pos):
		return false
	_ensure_stage()
	if _stage == null or not is_instance_valid(_stage):
		return false
	_reparent(blk, _stage)
	blk.position = _stage.to_local(global_pos)   # 全局点 → 舞台局部（关卡原生坐标）
	if not _level_blocks.has(blk):
		_level_blocks.append(blk)
	_update_blocked()
	print("[LevelPage] 已新建关卡积木 id=%d pos=%s（归入关卡，不落桌面）" % [blk.id, str(blk.position)])
	return true


# ---------------- 传送门：跨场景搬运（归属切换）----------------
# ★ 为什么要换父节点：关卡积木挂在页面里（页面层 / 被 _stage_view 裁剪），桌面积木挂在
#   桌面世界（主场景，绘制关卡页面**之下**）。只改坐标不换父节点时——
#     · 桌面积木"传送进关卡"→ 位置对了，却被关卡面板整个盖住（看不见）；
#     · 关卡积木"传送出关卡"→ 位置对了，却被 _stage_view 裁掉（看不见）。
#   两种情况都表现为「积木传过去就消失了、没从出口出现」。所以传送后必须把积木
#   搬到**出口所在的那个场景**里。位置由调用方在换父之后再用 global_position 指定。

# 把一块外部积木「收进」本关卡：换父到舞台 + 登记进 _level_blocks（保留当前坐标）。
func adopt_block(blk: Block) -> bool:
	if blk == null or not is_instance_valid(blk) or blk.is_queued_for_deletion():
		return false
	_ensure_stage()
	if _stage == null or not is_instance_valid(_stage):
		return false
	# ★ 保持屏幕位置（两个画布缩放可能不同，不能照抄 global_position）
	_reparent_keep_screen(blk, _stage)
	if not is_instance_valid(blk):
		return false
	if not _level_blocks.has(blk):
		_level_blocks.append(blk)
	_update_blocked()
	print("[LevelPage] 积木 id=%d 已收进关卡（跨场景传送），坐标=%s" % [blk.id, str(blk.position)])
	return true


# 只做「归属摘除」：把积木从本关卡的 _level_blocks 里去掉（不换父节点）。
# 跨关卡传送（A 关 → B 关）时源关卡先忘掉它，否则保存/清场还会把它算进来。
func forget_block(blk: Block) -> void:
	if blk == null:
		return
	if _level_blocks.has(blk):
		_level_blocks.erase(blk)
		_update_blocked()


# 把关卡积木「退回」桌面世界：脱离 _level_blocks（保存/清场不再管它）+ 换父到桌面世界。
func release_block(blk: Block) -> bool:
	if blk == null or not is_instance_valid(blk) or blk.is_queued_for_deletion():
		return false
	forget_block(blk)
	var world := _desktop_world()
	if world == null:
		push_warning("[LevelPage] 找不到桌面世界节点，积木 id=%d 留在关卡里" % blk.id)
		return false
	# ★ 保持屏幕位置（关卡画布 → 桌面画布，缩放不同；见 _reparent_keep_screen）
	var g: Vector2 = blk.global_position
	_reparent_keep_screen(blk, world)
	print("[LevelPage] 积木 id=%d 已退回桌面世界（跨场景传送），屏幕位置=%s" % [
		blk.id, str(blk.get_canvas_transform() * blk.global_position)])
	return true


# ---------------- 关卡摄像头 ----------------

# 当前是否处于「锚定」模式：设定了锚定目标，且该积木在**当前投影**里有效。
# ★ 只认当前投影（`_level_blocks`）：锚定的语义是"在关卡视图里跟随某块积木"，
#   桌面世界的积木用的是另一套坐标系，跟随它会把舞台推到面板外。
# ★ 字符串 ID 优先于数字 ID（前者稳定、后者每次投影都变；两个入口互斥，同时非空只是 defensive）。
func _anchor_block() -> Block:
	var by_sid := _level_block_by_sid(_requested_anchor_sid)
	if by_sid != null:
		return by_sid
	if _requested_anchor_id <= 0:
		return null
	for b in _level_blocks:
		if is_instance_valid(b) and int(b.id) == _requested_anchor_id:
			return b
	return null


# 在当前投影里按**字符串 ID** 找积木（未投影 / 没这个名字 → null）。
# ★ 直接扫 `_level_blocks` 而不是查 BlockManager 注册表：这里要回答的是
#   "这块积木**在当前投影里**吗"，投影外的同名积木不该被锚定。
func _level_block_by_sid(sid: String) -> Block:
	if sid.is_empty():
		return null
	for b in _level_blocks:
		if is_instance_valid(b) and b.string_id == sid:
			return b
	return null


# 当前投影里存在的全部字符串 ID（升序、去重）——「名字打错」时把候选列给用户看。
func level_string_ids() -> Array[String]:
	var ids: Array[String] = []
	for b in _level_blocks:
		if is_instance_valid(b) and not b.string_id.is_empty() and not (b.string_id in ids):
			ids.append(b.string_id)
	ids.sort()
	return ids


# 人类可读的锚定目标描述（日志 / 状态栏共用）
func _anchor_desc() -> String:
	if not _requested_anchor_sid.is_empty():
		return "字符串 ID \"%s\"" % _requested_anchor_sid
	if _requested_anchor_id > 0:
		return "数字 ID %d" % _requested_anchor_id
	return "自由平移"


# 摄像头定位：锚定 → 视口中心对准锚定积木；自由 → 对准 _free_center。
# 舞台平移量 = size*0.5 - 视口中心*缩放，使**视口中心恒落在面板中央**（缩放也成立）。
# ★ 缩放走 _stage.scale：积木的关卡坐标不动，只有"看"的倍率变。
# ★★ 平滑跟随：delta >= 0（由 _physics_process 每帧传入）时启用指数平滑 ——
#   小幅度移动近乎同步（稳定跟随），大幅度移动缓慢收敛（"尝试追上"）。见 _cam_follow_alpha。
#   delta < 0（默认）= 直接吸附：给载入 / 换锚定 / 解绑 / 缩放这些**不该有惯性**的场合用，
#   避免画面从旧位置"飞入"。
# ★ 仍在拖动「锚定积木」本身时冻结相机：把这次拖拽当成"平移世界"（积木跟手），
#   否则每帧 _stage.position 都会随积木位置来回改写 → 拖动时积木在「光标」与「屏幕中心」之间
#   反复跳变（表现为卡死/失控，_stage.position 会被推到几千的量级）。
#   松手后 _dragging_block 清空 → 下方正常逻辑把积木归位屏幕中心、世界按拖拽量平移。
func _apply_camera(delta: float = -1.0) -> void:
	if _stage == null:
		return
	var anchor := _anchor_block()
	if anchor != null and Block._dragging_block == anchor:
		return
	var target: Vector2 = anchor.position if anchor != null else _free_center
	if _cam_snap or delta < 0.0 or anchor == null:
		# 吸附：首帧 / 显式吸附请求 / 自由平移（内容跟手，不做惯性）
		_cam_center = target
		_cam_snap = false
	else:
		# 平滑：按「误差距离」自适应的指数插值（帧率无关）+ 离屏上限保护
		_cam_center = _cam_center.lerp(target, _cam_follow_alpha(_cam_center.distance_to(target), delta))
		_cam_center = _clamp_camera_lag(target, anchor)
	_stage.scale = Vector2(_zoom, _zoom)
	_stage.position = size * 0.5 - _cam_center * _zoom


# 平滑插值系数（0~1，帧率无关）：alpha = 1 - exp(-rate*delta)。
# ★★ 速率随「当前误差距离」在 NEAR（近，几乎锁定）与 FAR（远，慢慢追）之间线性过渡 ——
#   这正是需求要的两种手感：小幅度移动稳定跟随、大幅度移动"追不上"。
func _cam_follow_alpha(dist: float, delta: float) -> float:
	var t := clampf(dist / CAM_LAG_DIST, 0.0, 1.0)
	var rate := lerpf(CAM_FOLLOW_RATE_NEAR, CAM_FOLLOW_RATE_FAR, t)
	return 1.0 - exp(-rate * delta)


# 把相机中心限制在「锚定块仍留在面板内」的范围内（分轴、换算成关卡坐标）。
# ★ 只对大误差生效（小幅度移动时 off 远小于上限 → 无任何影响）。
# ★ 意义：长时间高速移动时别让锚定块整个甩出面板 —— "努力追" 不等于 "跟丢"。
#   上限 = (面板半尺寸 − 积木半尺寸) × CAM_MAX_LAG_FRAC：保证**整块积木**留在面板内。
# ★ 分轴（不取短边）：面板通常是宽的，横向允许的滞后本就比纵向大 —— 取短边会把横向也压死。
# ★ 锚定块由调用方传入（锚定模式下非 null）→ 免去每帧重复扫描 `_level_blocks`。
func _clamp_camera_lag(target: Vector2, a: Block) -> Vector2:
	var half := size * 0.5
	if a != null and is_instance_valid(a):
		half -= Vector2(a.width, a.height) * 0.5
	half *= CAM_MAX_LAG_FRAC
	if half.x <= 0.0 or half.y <= 0.0:
		return _cam_center
	half /= maxf(_zoom, 0.001)
	var off := _cam_center - target
	return target + Vector2(clampf(off.x, -half.x, half.x), clampf(off.y, -half.y, half.y))


# 舞台节点（放积木的那个 Node2D）确保存在，且挂在 _stage_view 下 → 被页面裁剪、画不出面板外。
func _ensure_stage() -> void:
	if _stage == null:
		_stage = Node2D.new()
		_stage.name = "Stage"
	if _stage_view != null and _stage.get_parent() != _stage_view:
		_stage_view.add_child(_stage)


# 当前摄像头对准的「关卡坐标」（= 屏幕中心对应的世界点）。
# 锚定模式 = 锚定积木的位置；自由模式 = _free_center。保存/恢复视角都用它（同一套关卡坐标空间）。
func _camera_center() -> Vector2:
	var a := _anchor_block()
	if a != null:
		return a.position
	return _free_center


# ---------------- 深色背景 / 阻挡 ----------------

# 深色背景矩形（页面局部坐标）。顶栏在页面上占掉一段，深色区的上边界 = 顶栏下沿 + 留白。
func _body_rect() -> Rect2:
	if _body == null:
		return Rect2(Vector2.ZERO, size)
	return Rect2(_body.position, _body.size)   # 只认深色区，顶栏那条不算「背景内」


# 每帧（物理帧）判定：积木是否整块落在深色背景之外 → 进 _blocked（_blocked_overlay 已弃用，
#   本函数现仅作无副作用占位：_blocked_overlay 为 null 时直接早退，见下方 null 守卫）。
func _update_blocked() -> void:
	_blocked.clear()
	if _blocked_overlay == null or not is_instance_valid(_blocked_overlay):
		return
	var body := _body_rect()
	for b in _level_blocks:
		if b == null or not is_instance_valid(b):
			continue
		# ★ b.position 是**舞台局部**坐标；深色背景矩形在**页面**坐标里 → 必须加上舞台平移量
		#   （_stage.position 即摄像头偏移），否则平移一改判定就全错。
		var half := Vector2(b.width * 0.5, b.height * 0.5)
		var r := Rect2(b.position + _stage.position - half, Vector2(b.width, b.height))
		if not body.intersects(r):
			_blocked.append(b)
	if _blocked_overlay.has_method("set_targets"):
		_blocked_overlay.set_targets(_blocked)
	_blocked_overlay.queue_redraw()


# 深色背景的上下左右：上边界跟着顶栏实际高度走（顶栏内容变化时会重算）。
func _layout_body() -> void:
	_layout_config()   # 配置面板跟着顶栏下沿走（顶栏高度变了它也要跟着挪）
	if _body == null:
		return
	var want := _top_h() + PADDING
	if absf(_body.offset_top - want) > 0.5:
		_body.offset_top = want
		_stage_view.offset_top = want   # 裁剪范围上边界与深色背景同步（画布坐标一致）
		_update_blocked()


# 顶栏实际高度（首帧布局前 _top_bar.size.y 还是 0 → 回落 34，与 _layout_body 原逻辑一致）。
func _top_h() -> float:
	if _top_bar != null and is_instance_valid(_top_bar) and _top_bar.size.y > 0.0:
		return _top_bar.size.y
	return 34.0


# 配置面板定位：贴页面左上角、落在顶栏下沿；宽固定 CONFIG_W、高 = 内容最小高。
# ★ 高度取 get_combined_minimum_size().y 而不是 reset_size()：本面板里没有自动换行 Label
#   （批次 27 的"宽度=1 → 逐字一行 → 最小高爆炸"陷阱在自动换行控件上才会发生），
#   但每次仍只在值真的变化时写一次 size，避免每帧无谓的布局重算。
func _layout_config() -> void:
	if _cfg_panel == null or not is_instance_valid(_cfg_panel):
		return
	var want_pos := Vector2(PADDING, _top_h() + PADDING)
	if _cfg_panel.position != want_pos:
		_cfg_panel.position = want_pos
	var cmin: Vector2 = _cfg_panel.get_combined_minimum_size()
	var want_size := Vector2(maxf(CONFIG_W, cmin.x), cmin.y)
	if _cfg_panel.size != want_size:
		_cfg_panel.size = want_size


func _process(_delta: float) -> void:
	# 顶栏要等第一次布局才有真实高度 → 每帧校一次（值不变时不会触发重绘）
	_layout_body()


func _physics_process(dt: float) -> void:
	if not _visible or _stage == null:
		return
	# ★ 传 delta → 锚定积木的跟随走平滑（近稳远追）；吸附/自由平移由 _apply_camera 内部自行判定
	_apply_camera(dt)
	_update_blocked()   # 摄像头平移后，重新判定哪些积木跑出了深色背景


# 摄像头输入。三种操作（②③ 是同一套平移代码，只是触发键不同）：
#   ① 滚轮缩放 —— 需关卡带「允许缩放场景」(allow_zoom)
#   ② 中键拖动 —— 恒可（保持原有语义：仅自由模式）
#   ③ 右键拖动 —— 需关卡带「允许拖动场景」(allow_drag)；★ 锚定中按下即**解绑**再拖（需求）
# ★ 为什么右键要"吞事件"：右键原本归桌面（空白处右键 = 弹游戏菜单 / 右键积木 = 积木菜单）。
#   只在关卡明确开了 allow_drag、且落点在深色背景里时才吞 —— 没开标签的关卡右键行为完全不变。
#   页面根是 IGNORE，本方法走 _unhandled_input（与桌面/积木同一条管线）。
func _unhandled_input(event: InputEvent) -> void:
	if not _visible or _stage == null:
		return

	# ---- ① 滚轮缩放 ----
	if event is InputEventMouseButton:
		var wb := event as InputEventMouseButton
		if wb.pressed and (wb.button_index == MOUSE_BUTTON_WHEEL_UP or wb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			if not _env_allows(BlockTags.LEVEL_ENV_ALLOW_ZOOM):
				return     # 没开标签 → 滚轮完全不管（也不吞，留给别的逻辑）
			# ★ make_input_local 的返回类型是 InputEvent（基类）→ 取 .position 必须显式标注类型，
			#   否则 `:=` 推断失败（Cannot infer the type）
			var wl: Vector2 = (make_input_local(wb) as InputEventMouseButton).position
			if not _body_rect().has_point(wl):
				return
			var f: float = ZOOM_STEP if wb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / ZOOM_STEP
			_zoom_by(f, wl)
			get_viewport().set_input_as_handled()
			return

	# ---- ②③ 按下 / 抬起 ----
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var is_mid: bool = mb.button_index == MOUSE_BUTTON_MIDDLE
		var is_right: bool = mb.button_index == MOUSE_BUTTON_RIGHT
		if not is_mid and not is_right:
			return
		if is_right and not _env_allows(BlockTags.LEVEL_ENV_ALLOW_DRAG):
			return     # 没开标签 → 右键归桌面，不吞（桌面菜单照旧）
		if mb.pressed:
			# ★ 先判落点、再解绑：落点不在深色背景里（顶栏 / 配置面板）就不是"拖场景"，
			#   不该把锚定顺手解掉（顺序写反 = 点一下顶栏就把锚定弄丢）。
			if not _body_rect().has_point(make_input_local(mb).position):
				return
			if is_right:
				# ★★ 右键：按下时**先不解绑、不平移** —— 此刻还分不清"单击"还是"按住拖动"，
				#   只记起点，等位移超过 DRAG_THRESHOLD 才升级为拖动（见下面 motion 分支）。
				#   但必须**吞掉按下**，否则桌面右键菜单会在按下瞬间弹出、拖动时还挂在那儿。
				_rdrag_pending = true
				_rdrag_start_screen = mb.position
				get_viewport().set_input_as_handled()
				return
			# 中键：保持"按下即平移"的老语义（中键没有单击语义，不做阈值）
			if _anchor_block() != null:
				return     # 锚定中：中键不平移
			_panning = true    # 页面内按下 → 开始平移并吞掉，避免误触别的逻辑
			get_viewport().set_input_as_handled()
		elif _panning:
			_panning = false
			get_viewport().set_input_as_handled()
		elif _rdrag_pending:
			# ★ 右键在阈值内抬起 = **单击**（不是拖动）→ 不起平移、不解锚定，通知桌面补弹右键菜单。
			#   按下已被本页吞掉，只能由本页主动"补一枪"，否则这次右键就丢了。
			_rdrag_pending = false
			right_click_at.emit(mb.position)
			get_viewport().set_input_as_handled()
		return

	# ---- ②③ 拖动中的移动 ----
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _panning:
			# ★ 除以缩放倍率：屏幕上拖 N 像素，关卡坐标只该移动 N/倍率 → 内容才跟手
			_free_center -= mm.relative / maxf(_zoom, 0.001)
			get_viewport().set_input_as_handled()
		elif _rdrag_pending:
			# ★★ 阈值判定：屏幕位移超过阈值 → 这次右键算"拖动"，**此刻才**解绑锚定 + 开始平移。
			var d: Vector2 = mm.position - _rdrag_start_screen
			if d.length() > DRAG_THRESHOLD:
				_rdrag_pending = false
				if _anchor_block() != null:
					_unbind_for_drag()
				_panning = true
				# 一次性补上"按下→越阈"这段位移，内容才跟手（中间几帧既不平移也不吞）
				_free_center -= d / maxf(_zoom, 0.001)
				get_viewport().set_input_as_handled()


# 以「页面局部坐标 p_local」为锚点缩放：该点下方的关卡内容保持不动（滚轮缩放的直觉行为）。
# 自由模式：center1 = center0 + d*(1/z0 - 1/z1)，d = 该点相对面板中心的偏移（舞台容器坐标系）。
# 锚定模式：中心恒 = 锚定积木位置 → 只改倍率（锚定块留在面板正中，缩放天然绕它进行）。
func _zoom_by(factor: float, p_local: Vector2) -> void:
	if _stage == null:
		return
	var z0 := _zoom
	var z1 := clampf(z0 * factor, ZOOM_MIN, ZOOM_MAX)
	if absf(z1 - z0) < 0.0001:
		return     # 已到上下限：别让位置补偿白算一遍
	if _anchor_block() == null:
		var d := _stage_view_local(p_local) - size * 0.5
		_free_center += d * (1.0 / z0 - 1.0 / z1)
	_zoom = z1
	_apply_camera()
	# 回显文案里带「当前缩放 ×N.NN」→ 缩放后必须跟着刷，否则读数永远停在滚轮之前的值
	_refresh_env_hint()


# 页面局部坐标 → 舞台容器（_stage_view）局部坐标。
# ★ 必须换算：`_apply_camera` 里的 "size*0.5" 是**舞台容器**坐标系，而 make_input_local 给的是
#   **页面**坐标，两者差一个 `_stage_view.position`（有 PADDING 内缩）。
#   直接混用会让"鼠标下的内容钉住"整体偏移几十像素。
func _stage_view_local(p_local: Vector2) -> Vector2:
	if _stage_view == null or not is_instance_valid(_stage_view):
		return p_local
	return p_local - _stage_view.position


# 解绑锚定但**保持当前视角**：把此刻的**可见**相机中心接到 _free_center，
# 否则解绑瞬间画面会跳回"上一次自由平移留下的位置"。
# ★ 用 `_cam_center`（而非 `_camera_center()`）：平滑跟随中相机可能正滞后于锚定块，
#   只有 `_cam_center` 才是"屏幕上正在显示的中心" → 解绑才不会闪跳（拖动时会明显看出来）。
func _release_anchor() -> void:
	if _requested_anchor_id <= 0 and _requested_anchor_sid.is_empty():
		return
	_free_center = _cam_center
	_requested_anchor_id = 0
	_requested_anchor_sid = ""
	_cam_snap = true      # 解绑是"不该有惯性"的场合 → 下一帧直接吸附到 _free_center（已等于当前视角）
	_apply_camera()


# 右键拖动开始时解绑锚定（关卡属性「允许拖动场景」的要求）+ 同步锚定输入框与回显，
# 免得界面上还显示着一个其实已经失效的锚定目标。
func _unbind_for_drag() -> void:
	var was := _anchor_desc()
	_release_anchor()
	if _cam_input != null and is_instance_valid(_cam_input):
		_cam_input.text = ""
	_set_cam_status("已解绑锚定（原 %s）→ 现在拖动；这是「允许拖动场景」的要求" % was, true)
	print("[LevelPage] 拖动场景 → 已解绑锚定（原 %s）" % was)


# 桌面右键询问入口（**画布坐标**，桌面用 _to_page(mb.position) 传进来）：
# 这次右键是否该由本页的「拖动场景」接手？
# 语义 = 页面可见 + 关卡带 allow_drag + 落点在深色背景区里（顶栏 / 配置面板不算）。
# ★ 桌面据此**按下时一律不弹游戏菜单**（单击要弹的菜单等抬起后由 right_click_at 信号补），
#   于是与本页 _unhandled_input 谁先跑无关 → 顺序无关。
func wants_right_drag_at(screen_pos: Vector2) -> bool:
	if not _visible or _stage == null:
		return false
	if not _env_allows(BlockTags.LEVEL_ENV_ALLOW_DRAG):
		return false
	if _body == null or not is_instance_valid(_body):
		return false
	return _body.get_global_rect().has_point(screen_pos)


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		_panning = false        # 页面隐藏时终止拖动状态
		_rdrag_pending = false  # 以及"待判定"的右键（避免下次显示时残留）


# 把锚定目标设为**数字**积木 ID（0 = 切回自由平移）。ID 按 BlockManager 的积木 ID 索引。
# ★ 数字 ID 每次重新投影都会变（积木入树时由时间戳分配）→ 过关/重投影后需要重设。
func set_camera_anchor_id(id: int) -> void:
	_requested_anchor_id = maxi(id, 0)
	_requested_anchor_sid = ""
	_apply_camera()
	if id > 0 and _anchor_block() == null:
		print("[LevelPage] 已记录锚定数字 ID=%d（当前投影里暂无对应积木，投影到对应关卡后自动跟随）" % id)
	else:
		print("[LevelPage] 关卡摄像头锚定目标=%s" % _anchor_desc())


# 把锚定目标设为**字符串**积木 ID（"" = 切回自由平移）。
# ★ 字符串 ID 随关卡 JSON 的 `string_id` 字段一起落盘 → 重新投影 / 重新载入关卡后
#   仍指向同一块积木（数字 ID 做不到，这是本功能的意义所在）。
func set_camera_anchor_sid(sid: String) -> void:
	_requested_anchor_sid = sid.strip_edges()
	_requested_anchor_id = 0
	_apply_camera()
	if not _requested_anchor_sid.is_empty() and _anchor_block() == null:
		print("[LevelPage] 已记录锚定字符串 ID=\"%s\"（当前投影里暂无对应积木%s）" % [
			_requested_anchor_sid, _candidate_suffix()])
	else:
		print("[LevelPage] 关卡摄像头锚定目标=%s" % _anchor_desc())


# 「当前投影里可选哪些字符串 ID」的日志尾巴（无候选则返回空串）
func _candidate_suffix() -> String:
	var cand := level_string_ids()
	if cand.is_empty():
		return ""
	return "；当前可选：" + ", ".join(cand)


# 卸载当前投影关卡（清空舞台上的积木）。舞台保留，下次可再投影。
func _clear_level_blocks() -> void:
	if _stage == null:
		_level_blocks.clear()
		return
	for b in _level_blocks:
		if b == null or not is_instance_valid(b):
			continue
		if BlockManager != null and BlockManager.has_method("unregister"):
			BlockManager.unregister(b)
		b.queue_free()
	_level_blocks.clear()


# ============ 构建 UI ============

func _clear() -> void:
	_abort_confirm()        # 覆盖确认框不在本页子节点里（挂独立高层 CanvasLayer），需单独收
	_close_sub_panels()     # 标签选择窗 / 长文本窗同样挂在页面层上（不是本页子树），也要单独收
	_clear_level_blocks()   # 先清掉投影积木（舞台与积木会被下面 remove_child 一并移除）
	for c in get_children():
		remove_child(c)
		c.queue_free()


func _build_ui() -> void:
	# ① 面板底：圆角半透明填充 + 可见边框 → 即"边框 + 背景"
	_bg = UIPanel.new()
	_bg.name = "Bg"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	# ② 深色舞台背景（关卡舞台底）：比面板底色深得多，积木只有落在这块矩形里才算「在页面上」。
	#    上边界由顶栏实际高度决定（_layout_body 每帧校正）。
	_body = UIPanel.new()
	_body.name = "StageBody"
	_body.set_frosted(false)   # 舞台保持实心深底，不做磨砂模糊（批次 52）
	# ★ 必须用 FULL_RECT 锚点 + 四边偏移：若把 bottom 锚点设成 0（TOP_WIDE），
	#   高度会按 `offset_bottom - offset_top` 算成负数 → 背景高度恒为 0。
	_body.set_anchors_preset(Control.PRESET_FULL_RECT)
	_body.offset_left = PADDING
	_body.offset_right = -PADDING
	_body.offset_top = PADDING
	_body.offset_bottom = -PADDING
	_body.set_corner_radius(0.0)
	_body.set_fill_color(UIStyle.FILL_LEVEL_STAGE)
	_body.set_border_color(UIStyle.STAGE_BORDER)
	_body.set_border_width(1.0)
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_body)

	# ③ 内容留白容器（面板上部放标题栏，主体留空作"页面"）
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", int(PADDING))
	margin.add_theme_constant_override("margin_right", int(PADDING))
	margin.add_theme_constant_override("margin_top", int(PADDING))
	margin.add_theme_constant_override("margin_bottom", int(PADDING))
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	# 纵向容器：顶栏行**不会被拉伸**（VBox 只按子控件最小高度排布，行高保持固定）
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(PADDING))
	margin.add_child(vbox)

	# 顶栏：移动把柄 + 关卡名称
	var top := _build_top_bar()
	top.size_flags_vertical = Control.SIZE_SHRINK_BEGIN   # 顶栏固定在顶部、行高恒为最小高度
	vbox.add_child(top)
	_top_bar = top

	# ④ 舞台容器（裁剪）：积木挂在它的 Stage 子节点下。
	# ★ 裁剪范围 = **深色背景矩形**（_body_rect），不是整页！
	#   原代码用 FULL_RECT 整页裁剪，积木会被画到顶栏 / 边框 / 按钮之上（挡住标题与按钮）。
	#   改成与 _body 同款内缩偏移（左/右/下留 PADDING，上边界跟随顶栏高度），
	#   clip_contents 即把积木限制在深色背景内 —— 只有深色背景才是积木的"可显示范围"。
	_stage_view = Control.new()
	_stage_view.name = "StageView"
	_stage_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stage_view.offset_left = PADDING
	_stage_view.offset_right = -PADDING
	_stage_view.offset_top = PADDING          # 顶边由 _layout_body 按顶栏实际高度校正
	_stage_view.offset_bottom = -PADDING
	_stage_view.clip_contents = true   # 积木只显示在深色背景矩形内，画到顶栏/边框的被裁掉（不挡按钮）
	_stage_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stage_view)
	_ensure_stage()   # Stage 节点放进来（_clear 之后可能是空引用，这里一并补建）

	# ★ 阻挡提示层已移除：原 _blocked_overlay 在整页裁剪下会"压暗深色背景外的积木"，
	#   但那些积木同时也盖在按钮/边框上，压暗反而更糊。现在 StageView 直接裁到深色背景，
	#   深色背景外的积木不再绘制（符合"深色背景才是可显示范围"），提示层无存在必要。

	# ⑤ 关卡配置浮层面板（仅调试模式可见）：放在 StageView **之后** → 压在关卡积木之上；
	#    位置/大小由 _layout_config() 每帧跟顶栏高度走（见 _layout_body）。
	_build_config_panel()

	# 右下角调大小把柄（贴角内缩 6px，不受上方流式布局影响）
	_resize_handle = UIResizeHandle.new()
	_resize_handle.name = "Resize"
	_resize_handle.set_move_callback(_on_resize_increment)
	add_child(_resize_handle)
	_resize_handle.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_resize_handle.offset_right = -6.0
	_resize_handle.offset_bottom = -6.0
	_resize_handle.offset_left = -(UIDragHandle.SIZE + 6.0)
	_resize_handle.offset_top = -(UIDragHandle.SIZE + 6.0)


# 顶栏：移动把柄 + 关卡名称（标题在移动按钮旁边）+ 保存区（仅调试模式显示）
func _build_top_bar() -> HBoxContainer:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)

	# ★ 最左端 = 「页面左上角」：关卡配置的折叠/展开按钮（仅调试模式可见，见 _refresh_cfg_visible）
	_cfg_btn = UIBtn.new()
	_cfg_btn.set_id("level_config_toggle")
	_cfg_btn.set_label("▼ 配置" if _cfg_open else "▶ 配置")
	_cfg_btn.custom_minimum_size = Vector2(72.0, UIStyle.BTN_HEIGHT)
	_cfg_btn.pressed_id.connect(_on_cfg_toggle_pressed)
	top.add_child(_cfg_btn)

	_drag_handle = UIDragHandle.new()
	_drag_handle.setup(self)   # 拖动 → 平移整个面板
	top.add_child(_drag_handle)

	_title_label = _make_label("", 16, Color.WHITE)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_title_label)

	# 关卡名称输入区（调试模式启用）：输入框 + 已有关卡下拉 + 「载入」按钮
	_name_bar = _build_name_bar()
	top.add_child(_name_bar)

	# 保存区：本体/MOD/DLC 下拉 + 「保存」按钮。默认选「本体」（直接生效）；只有「本体」写文件到 levels/。
	_save_bar = HBoxContainer.new()
	_save_bar.add_theme_constant_override("separation", 6)
	_save_option = OptionButton.new()
	_save_option.fit_to_longest_item = false
	_save_option.add_theme_font_size_override("font_size", 14)
	var fnt := UIStyle.get_cjk_font()
	if is_instance_valid(fnt):
		_save_option.add_theme_font_override("font", fnt)
	for it in SAVE_ITEMS:
		_save_option.add_item(it)
	_save_option.select(SAVE_DEFAULT_INDEX)
	_save_bar.add_child(_save_option)

	_save_btn = UIBtn.new()
	_save_btn.set_id("level_save")
	_save_btn.set_label("保存")
	_save_btn.custom_minimum_size = Vector2(56.0, UIStyle.BTN_HEIGHT)
	_save_btn.pressed_id.connect(_on_save_pressed)
	_save_bar.add_child(_save_btn)

	top.add_child(_save_bar)
	# 仅调试模式显示；Debug 切换时同步显隐
	if Debug != null:
		call_deferred("_sync_debug_visibility")
		if not Debug.mode_changed.is_connected(_on_debug_mode_changed):
			Debug.mode_changed.connect(_on_debug_mode_changed)
	return top


# 关卡名称输入区：输入框（关卡名，可手输）+ 下拉（已有关卡，点开才遍历）+ 「载入」按钮
func _build_name_bar() -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)

	_name_input = LineEdit.new()
	_name_input.name = "NameInput"
	UIStyle.apply_line_edit_style(_name_input)
	_name_input.placeholder_text = "关卡名称"
	_name_input.custom_minimum_size = Vector2(150.0, UIStyle.BTN_HEIGHT)
	_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_input.select_all_on_focus = true
	_name_input.text_changed.connect(_on_name_input_changed)
	bar.add_child(_name_input)

	# ★ 下拉条目在「点开的那一刻」才生成（_reload_level_menu），避免启动时就遍历 levels/。
	#   ★★ 必须挂 PopupMenu 的 about_to_popup，**不能**挂 OptionButton.pressed：
	#   OptionButton 内部 _pressed() 会先把自己的条目灌进 PopupMenu 并立刻弹窗，
	#   之后才派发 pressed；此时再 clear() 会把刚弹出的菜单清空 → 下拉"一点就收、展不开"。
	#   about_to_popup 在菜单显示之前发出（实测确认），此刻重建条目正好赶上。
	_name_option = OptionButton.new()
	_name_option.name = "NameMenu"
	_name_option.fit_to_longest_item = false
	_name_option.add_theme_font_size_override("font_size", 14)
	var fnt2 := UIStyle.get_cjk_font()
	if is_instance_valid(fnt2):
		_name_option.add_theme_font_override("font", fnt2)
	# ★ 初始就是「无选择」（不再用禁用的"关卡…"占位）：未手动选择时下拉显示"无选择"，
	#   与"输入框为空 = 载入无动作"的语义一致；点开下拉后条目会被 _reload_level_menu 重建，
	#   重建时 index 0 依旧是「无选择」。
	_name_option.add_item(LEVEL_NONE_LABEL)
	_name_option.select(LEVEL_NONE_INDEX)
	_name_option.get_popup().about_to_popup.connect(_reload_level_menu)
	_name_option.item_selected.connect(_on_level_menu_selected)
	bar.add_child(_name_option)

	_load_btn = UIBtn.new()
	_load_btn.set_id("level_load")
	_load_btn.set_label("载入")
	_load_btn.custom_minimum_size = Vector2(56.0, UIStyle.BTN_HEIGHT)
	_load_btn.pressed_id.connect(_on_load_pressed)
	bar.add_child(_load_btn)
	return bar


# ============ 关卡配置面板（仅调试模式；左上角按钮展开）============

# 面板骨架：PanelContainer + StyleBoxFlat（**不裸用 UIPanel**：UIPanel 不报最小尺寸，
# 直接当容器会把面板压成 0 高）。里面纵向排：标题 / 摄像头锚定 / 关卡环境。
func _build_config_panel() -> void:
	_cfg_panel = PanelContainer.new()
	_cfg_panel.name = "LevelConfig"
	_cfg_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.09, 0.16, 0.94)
	sb.border_color = UIStyle.BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(int(UIStyle.CORNER_RADIUS))
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	_cfg_panel.add_theme_stylebox_override("panel", sb)
	_cfg_panel.mouse_filter = Control.MOUSE_FILTER_STOP   # 面板区域内吃掉点击（别透给背后的积木）
	_cfg_panel.z_index = PAGE_OVERLAY_Z   # ★ 抬到所有关卡积木之上（见 PAGE_OVERLAY_Z 说明）
	_cfg_panel.visible = false
	add_child(_cfg_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_cfg_panel.add_child(box)

	box.add_child(_make_label("关卡配置", 15, Color(0.75, 0.92, 1.0)))
	box.add_child(_build_cam_row())
	box.add_child(_build_env_row())

	# 建完立刻按当前调试状态定一次显隐（按钮在 _build_top_bar 里先建好，此处两件都在）。
	# 不能只靠 _build_top_bar 里那句 call_deferred —— Debug 为 null 时那句不会注册，
	# 按钮就会永远留着（本页是**仅调试模式**可见的入口）。
	_refresh_cfg_visible()


# 行首标签（宽度对齐 ROW_LABEL_W，缺了它两行输入框会错位）
func _row_label(text: String) -> Label:
	var l := _make_label(text, UIStyle.FONT_SIZE, UIStyle.TEXT_DEFAULT)
	l.custom_minimum_size = Vector2(ROW_LABEL_W, 0.0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


# 统一风格的输入框（与页面其它输入框同一套外观）
func _make_line_edit(placeholder: String) -> LineEdit:
	var le := LineEdit.new()
	UIStyle.apply_line_edit_style(le)
	le.placeholder_text = placeholder
	le.custom_minimum_size = Vector2(110.0, UIStyle.BTN_HEIGHT)
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	var fnt := UIStyle.get_cjk_font()
	if is_instance_valid(fnt):
		le.add_theme_font_override("font", fnt)
	return le


# 小号说明/反馈文字
func _hint_label() -> Label:
	return _make_label("", UIStyle.FONT_SIZE - 2, Color(0.78, 0.82, 0.88))


# ① 摄像头锚定的目标（原先在「调试面板」里，本批迁到关卡页面的配置面板）
func _build_cam_row() -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(_row_label("摄像头锚定"))

	_cam_input = _make_line_edit("数字ID 或 字符串ID（空=自由平移）")
	_cam_input.tooltip_text = "两种写法：\n· 纯数字 = 积木数字 ID（每次重新投影都会变）\n· 其它文本 = 积木字符串 ID（随关卡保存，重投影后仍跟随）\n留空或填 0 = 自由平移（按住中键拖动）"
	_cam_input.text_submitted.connect(func(_t: String): _on_cam_apply(""))
	row.add_child(_cam_input)

	var ok := UIBtn.new()
	ok.set_id("level_cam_anchor_apply")
	ok.set_label("确定")
	ok.custom_minimum_size = Vector2(APPLY_BTN_W, UIStyle.BTN_HEIGHT)
	ok.pressed_id.connect(_on_cam_apply)
	row.add_child(ok)
	col.add_child(row)

	_cam_status = _hint_label()
	_cam_status.text = "数字 ID 或字符串 ID；留空 / 0 = 自由平移"
	col.add_child(_cam_status)
	return col


# ② 关卡环境：标签集合（逗号分隔）+ 行尾「长文本」「标签选择」两个复用窗口
func _build_env_row() -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(_row_label("关卡环境"))

	_env_input = _make_line_edit("标签，逗号分隔")
	_env_input.text_changed.connect(_on_env_text_changed)
	row.add_child(_env_input)

	var lt := UIBtn.new()
	lt.set_id("level_env_long_text")
	lt.set_label("长文本")
	lt.custom_minimum_size = Vector2(60.0, UIStyle.BTN_HEIGHT)
	lt.pressed_id.connect(_on_env_long_text_pressed)
	row.add_child(lt)

	var pk := UIBtn.new()
	pk.set_id("level_env_tags")
	pk.set_label("标签选择")
	pk.custom_minimum_size = Vector2(72.0, UIStyle.BTN_HEIGHT)
	pk.pressed_id.connect(_on_env_tags_pressed)
	row.add_child(pk)
	col.add_child(row)

	_env_hint = _hint_label()
	col.add_child(_env_hint)
	return col


# 配置面板显隐：调试模式 **且** 展开 时才显示（退出调试模式顺带收掉两个子窗口）。
func _refresh_cfg_visible() -> void:
	var on := Debug != null and Debug.debug_mode
	if _cfg_btn != null and is_instance_valid(_cfg_btn):
		_cfg_btn.visible = on
		_cfg_btn.set_label("▼ 配置" if _cfg_open else "▶ 配置")
	if _cfg_panel != null and is_instance_valid(_cfg_panel):
		_cfg_panel.visible = on and _cfg_open
	if not on:
		_close_sub_panels()


# 折叠 / 展开按钮
func _on_cfg_toggle_pressed(_id: String) -> void:
	_cfg_open = not _cfg_open
	_refresh_cfg_visible()
	_layout_config()
	print("[LevelPage] 关卡配置 → %s" % ("展开" if _cfg_open else "折叠"))


# 找承载本页的 CanvasLayer：标签选择窗 / 长文本窗必须挂在它下面，
# 这样它们以视口为原点居中（open() 用视口尺寸算位置），且浮在页面之上。
func _ui_layer() -> CanvasLayer:
	var n: Node = get_parent()
	while n != null:
		if n is CanvasLayer:
			return n
		n = n.get_parent()
	return null


# 收掉还开着的子窗口（面板重建 / 页面隐藏 / 退出调试模式时用）
func _close_sub_panels() -> void:
	if _env_picker != null and is_instance_valid(_env_picker):
		_env_picker.close()
	_env_picker = null
	if _env_long_panel != null and is_instance_valid(_env_long_panel):
		_env_long_panel.close()
	_env_long_panel = null


# ---------------- 摄像头锚定目标 ----------------

# 「确定」：把输入框里的目标设成关卡摄像头锚定目标（数字 ID 或字符串 ID）。
# 目标就是本页面自己 —— 原先这段在调试面板里，靠 LevelManager.level_page 绕一圈拿页面。
#
# 判定规则（按顺序、刻意保持"可预测"）：
#   ① 空 / "0"  → 自由平移
#   ② 纯数字    → 按**数字**积木 ID 处理；但若当前投影里既没有这个数字 ID、
#                 又恰好有一块积木的字符串 ID 就是这串数字 → 按**字符串** ID 处理（兜底，
#                 避免"字符串 ID 恰好全是数字"时永远锚不上）
#   ③ 其它文本  → 按**字符串**积木 ID 处理（如 start / BedRockXU）
func _on_cam_apply(_id: String) -> void:
	if _cam_input == null or not is_instance_valid(_cam_input):
		return
	var text: String = _cam_input.text.strip_edges()

	# ① 自由平移
	if text.is_empty() or text == "0":
		set_camera_anchor_id(0)
		_set_cam_status("✓ 已设为自由平移", true)
		return

	# ② 纯数字：优先数字 ID
	if text.is_valid_int():
		var num := int(text)
		var keep := false
		for b in _level_blocks:
			if is_instance_valid(b) and int(b.id) == num:
				keep = true
				break
		if not keep and _level_block_by_sid(text) != null:
			set_camera_anchor_sid(text)
			_set_cam_status("✓ 已锚定字符串 ID \"%s\"（当前投影没有这个数字 ID，按字符串 ID 处理）" % text, true)
			return
		set_camera_anchor_id(num)
		var on_num: bool = _anchor_block() != null
		_set_cam_status(
			("✓ 已锚定数字 ID %d" % num) if on_num else
			"已记录数字 ID %d（当前投影无此积木，投影对应关卡后跟随；★ 重投影后该数字会变）" % num,
			on_num)
		return

	# ③ 非数字：字符串 ID
	set_camera_anchor_sid(text)
	if _anchor_block() != null:
		_set_cam_status("✓ 已锚定字符串 ID \"%s\"（随关卡保存，重投影后仍跟随）" % text, true)
	else:
		_set_cam_status("已记录字符串 ID \"%s\"（当前投影无此积木%s）" % [
			text, _candidate_suffix()], false)


# ---------------- 外部入口：右键「摄像头锚定」把某块积木设为锚定目标 ----------------

# 桌面右键菜单「摄像头锚定」的落笔处：把这块积木的 ID 填进配置面板输入框并**按下「确定」**
# （走的是与手输完全同一条路：写 .text → `_on_cam_apply("")`，两种 ID 的判定规则不重复实现）。
#
# 填哪个 ID —— 优先**字符串 ID**，没有才退回**数字 ID**：
#   · 字符串 ID 随关卡 JSON 落盘 → 重投影 / 重载后仍指向同一块积木（`set_camera_anchor_sid`），
#     这才是「锚定」的意义；数字 ID 每次投影都会重新分配（`set_camera_anchor_id` 的状态栏会提醒）。
#   · 绝大多数块没有字符串 ID → 自动落到数字 ID，用户不必先起名。
#
# ★ 顺带把配置面板**展开**（否则用户按了菜单却在界面上看不见任何反馈——面板可能正收着）。
#   写 .text 直接赋值不发 text_changed（与「标签窗 / 长文本窗回填」同一套约定），
#   所以紧接着必须自己调 `_on_cam_apply("")`，不能指望信号。
# 返回是否真的落笔（桌面积木 / 不在本次投影里的积木会被拒）。
func set_camera_anchor_from_block(blk: Block) -> bool:
	if blk == null or not is_instance_valid(blk):
		return false
	if _cam_input == null or not is_instance_valid(_cam_input):
		return false
	# ★ 只接受**本页当前投影**里的积木：锚定的是关卡里的东西，别处（含桌面世界）的积木不参与。
	if not _level_blocks.has(blk):
		push_warning("[LevelPage] 摄像头锚定：积木 id=%d 不在当前投影的关卡里，已忽略" % int(blk.id))
		return false
	var text: String = blk.string_id if not blk.string_id.is_empty() else str(int(blk.id))
	_cam_input.text = text
	_on_cam_apply("")
	# 展开配置面板 + 重排一次（面板刚变可见时最小尺寸还没量过）→ 用户能立刻看到结果
	if not _cfg_open:
		_cfg_open = true
	_refresh_cfg_visible()
	_layout_config()
	_cam_input.grab_focus()
	_cam_input.caret_column = text.length()
	print("[LevelPage] 右键「摄像头锚定」：积木 id=%d string_id=\"%s\" → 输入框 \"%s\"（%s）" % [
		int(blk.id), blk.string_id, text,
		"字符串 ID" if not blk.string_id.is_empty() else "数字 ID"])
	return true


func _set_cam_status(msg: String, ok: bool) -> void:
	if _cam_status == null or not is_instance_valid(_cam_status):
		return
	_cam_status.text = msg
	_cam_status.add_theme_color_override("font_color",
		Color(0.45, 1.0, 0.55) if ok else Color(1.0, 0.62, 0.45))


# ---------------- 关卡环境 ----------------

# 关卡环境的权威数据源 = 输入框文本（逗号分隔、去空白、去重保序）。
# ★ 标签选择窗 / 长文本窗都是往这个输入框里写，故不另存副本，只认它一份。
func level_env() -> Array[String]:
	var out: Array[String] = []
	if _env_input == null or not is_instance_valid(_env_input):
		return out
	for part in _env_input.text.split(","):
		var t := str(part).strip_edges()
		if not t.is_empty() and not (t in out):
			out.append(t)
	return out


# 关卡是否带某个「关卡环境」标签。
# ★ 每次都从 level_env()（输入框文本）现算，不缓存 —— 标签窗 / 长文本窗都是**直接写 .text
#   （不发 text_changed）**，缓存会有"标签已经改了、判定还是旧的"的窗口。
func _env_allows(tag: String) -> bool:
	return tag in level_env()


# 直接写入关卡环境（投影关卡时回填；不触发 text_changed → 自己刷回显）
func set_level_env(tags) -> void:
	if _env_input == null or not is_instance_valid(_env_input):
		return
	var parts: Array[String] = []
	for t in tags:
		var s := str(t).strip_edges()
		if not s.is_empty() and not (s in parts):
			parts.append(s)
	_env_input.text = ",".join(parts)
	_refresh_env_hint()


func _on_env_text_changed(_text: String) -> void:
	_refresh_env_hint()


# 中文回显：让玩家看得见"输入框里的英文标签被认成了什么"。
# ★ 未登记的标签原样显示（BlockTags.display_name 对未知标签返回原串）—— 不静默吞掉，
#   否则用户敲错一个键会以为"输入没生效"。
# ★ 顺带复位"标签带来的状态"：标签被删掉后，缩放/拖动要立刻失效，
#   保证**没这些标签的关卡与加功能之前逐像素一致**（老关卡不会被残留倍率莫名其妙缩放）。
func _refresh_env_hint() -> void:
	if _env_hint == null or not is_instance_valid(_env_hint):
		return
	var zoom_on := _env_allows(BlockTags.LEVEL_ENV_ALLOW_ZOOM)
	var drag_on := _env_allows(BlockTags.LEVEL_ENV_ALLOW_DRAG)
	if not zoom_on and not is_equal_approx(_zoom, 1.0):
		_zoom = 1.0
		_apply_camera()
	if not drag_on:
		_panning = false
		_rdrag_pending = false
	var tags := level_env()
	if tags.is_empty():
		_env_hint.text = "（空）可选：单元 / 起点 / 终点 / 奖励箱 / 允许缩放场景 / 允许拖动场景"
		return
	var names: Array[String] = []
	for t in tags:
		var n := BlockTags.display_name(t)
		# 打上「生效」标记：这四个 ↑ 里只有这两个真的改引擎行为，其余纯标注
		if t == BlockTags.LEVEL_ENV_ALLOW_ZOOM or t == BlockTags.LEVEL_ENV_ALLOW_DRAG:
			names.append("%s（生效）" % n)
		else:
			names.append(n)
	var tail := ""
	if zoom_on:
		tail = "；当前缩放 ×%.2f" % _zoom
	_env_hint.text = "%s%s" % ["、".join(names), tail]


# 「标签选择」：复用 TagPickerPanel 的 LEVEL 模式（清单 = BlockTags.LEVEL_ENV_TAGS）。
# ★ 同步打开、不用 await：避免关闭后滞后的协程把已关的窗再弹出来（同属性面板的做法）。
func _on_env_tags_pressed(_id: String) -> void:
	if _env_input == null or not is_instance_valid(_env_input):
		return
	if _env_picker != null and is_instance_valid(_env_picker):
		_env_picker.close()
		_env_picker = null
	var layer := _ui_layer()
	if layer == null:
		push_warning("[LevelPage] 未找到 CanvasLayer，标签选择窗无法显示")
		return
	_env_picker = TagPickerPanel.new()
	_env_picker.z_index = PAGE_OVERLAY_Z   # ★ 抬到所有关卡积木之上（见 PAGE_OVERLAY_Z 说明）
	layer.add_child(_env_picker)
	_env_picker.closed.connect(_on_env_picker_closed)
	_env_picker.open(_env_input, TagPickerPanel.Mode.LEVEL)


func _on_env_picker_closed() -> void:
	_env_picker = null
	_refresh_env_hint()   # 标签窗是直接写 LineEdit.text（不发 text_changed）→ 手动刷一次


# 「长文本」：复用 UILongTextInputPanel（内容实时回填到 _env_input）
func _on_env_long_text_pressed(_id: String) -> void:
	if _env_input == null or not is_instance_valid(_env_input):
		return
	if _env_long_panel != null and is_instance_valid(_env_long_panel):
		_env_long_panel.close()
		_env_long_panel = null
	var layer := _ui_layer()
	if layer == null:
		push_warning("[LevelPage] 未找到 CanvasLayer，长文本窗无法显示")
		return
	_env_long_panel = UILongTextInputPanel.new()
	_env_long_panel.z_index = PAGE_OVERLAY_Z   # ★ 抬到所有关卡积木之上（见 PAGE_OVERLAY_Z 说明）
	layer.add_child(_env_long_panel)
	_env_long_panel.closed.connect(_on_env_long_closed)
	_env_long_panel.open(_env_input, _env_input.text)


func _on_env_long_closed() -> void:
	_env_long_panel = null
	_refresh_env_hint()   # 关闭时回填 LineEdit.text（不发 text_changed）→ 手动刷一次


# 生成（或刷新）「已有关卡」下拉条目。仅由点开下拉触发（不在启动时枚举）。
# 挂在 PopupMenu.about_to_popup（菜单显示前），此刻 clear + 重建不会把已弹出的菜单清空。
func _reload_level_menu() -> void:
	if _name_option == null or not is_instance_valid(_name_option):
		return
	# 兜底：万一菜单已可见，先收起再填（避免 clear 过程中菜单闪空）
	var pop := _name_option.get_popup()
	if pop.visible:
		pop.hide()
	_name_option.clear()
	# ★ index 0 恒为「无选择」：既是"没有选任何关卡"的默认项，也是"清空选择"的入口。
	#   没有它时第一个关卡落在 index 0，而 `selected` 恰好也是 0 → 造成"默认选中第一关"的假象。
	_name_option.add_item(LEVEL_NONE_LABEL)
	var names: Array[String] = []
	if LevelManager != null:
		names = LevelManager.list_level_names()
	if names.is_empty():
		_name_option.add_item("（levels/ 下暂无关卡）")
		_name_option.set_item_disabled(1, true)
		_name_option.select(LEVEL_NONE_INDEX)
		return
	for n in names:
		_name_option.add_item(str(n))
	# 名称输入里现有的名字若在关卡列表里，直接高亮（预览当前选中项）；否则回到「无选择」
	var cur := _editor_name()
	for i in names.size():
		if str(names[i]) == cur:
			_name_option.select(i + 1)   # ★ 偏移 1（index 0 是「无选择」）
			return
	_name_option.select(LEVEL_NONE_INDEX)


# 下拉选中某关：把名字填进输入框（不自动载入，载入交给「载入」按钮）
func _on_level_menu_selected(idx: int) -> void:
	if _name_option == null or not is_instance_valid(_name_option):
		return
	if idx < 0 or idx >= _name_option.get_item_count():
		return
	var t := _name_option.get_item_text(idx)
	# 「无选择」/ 提示项：清空输入框并把下拉复位。
	# ★ 判据用**双条件**：`idx == 0` **且**文案确实是「（无选择）」——只靠 index 在列表布局变化时会误判，
	#   只靠文案又怕关卡名以「（」开头。
	# ★ 必须清空输入框：下拉的选中项每次展开都由 `_editor_name()`（以输入框为准）重算，
	#   若输入框还留着旧名字，下次展开又会高亮回那一关 → 用户会觉得"点了无选择没用"。
	if (idx == LEVEL_NONE_INDEX and t == LEVEL_NONE_LABEL) or t.is_empty() or t.begins_with("（"):
		_name_option.select(LEVEL_NONE_INDEX)
		if _name_input != null and is_instance_valid(_name_input):
			_name_input.text = ""      # 触发 text_changed → 标题会被清空，下面补回来
		# ★ 标题跟的是"当前投影的关卡"，不该被上面那句清掉（无选择 ≠ 卸载关卡）
		if _title_label != null and is_instance_valid(_title_label):
			_title_label.text = current_level_name
		print("[LevelPage] 已选择「%s」：清空关卡名输入框（载入需重新输入或选择）" % LEVEL_NONE_LABEL)
		return
	if _name_input != null and is_instance_valid(_name_input):
		_name_input.text = t
	print("[LevelPage] 已选中关卡「%s」，点「载入」投影到面板" % t)


# 同步名称输入区 / 保存区显隐：只有调试模式（Debug.debug_mode）才显示。
# 关卡名称标签与输入区互斥：调试模式看得到输入框，非调试模式回到只读标签。
# ★ 左上角「配置」按钮与展开的配置面板同样只在调试模式可见（面板还要求 _cfg_open）。
func _sync_debug_visibility() -> void:
	var on := Debug != null and Debug.debug_mode
	if _title_label != null and is_instance_valid(_title_label):
		_title_label.visible = not on
	for c in [_name_bar, _save_bar]:
		if c != null and is_instance_valid(c):
			c.visible = on
	_refresh_cfg_visible()


func _on_debug_mode_changed(_on: bool) -> void:
	_sync_debug_visibility()


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", font_size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fnt := UIStyle.get_cjk_font()
	if is_instance_valid(fnt):
		l.add_theme_font_override("font", fnt)
	return l


# ============ 交互 ============

# ---------------- 名称 / 载入 / 保存 ----------------

# 编辑区里当前输入的关卡名（已去空白）。输入框为空时回落到当前投影的关卡名。
func _editor_name() -> String:
	if _name_input != null and is_instance_valid(_name_input):
		var t := _name_input.text.strip_edges()
		if not t.is_empty():
			return t
	return current_level_name


# 输入框改名时同步标题标签（调试模式标签隐藏，仅保证切换回非调试时标题显示的是当前名字）
func _on_name_input_changed(text: String) -> void:
	if _title_label != null and is_instance_valid(_title_label):
		_title_label.text = text.strip_edges()


# 「载入」按钮：把输入框（或下拉选中的）关卡名投影到面板。
func _on_load_pressed(_id: String) -> void:
	if LevelManager == null:
		print("[LevelPage] 载入失败：LevelManager 不可用")
		return
	var name := _editor_name()
	if name.is_empty():
		print("[LevelPage] 载入失败：请先输入关卡名，或从下拉里选一个")
		return
	if not LevelManager.has_level(name):
		print("[LevelPage] 载入失败：未找到关卡「%s」（可用：%s）" % [name, str(LevelManager.list_level_names())])
		return
	if not project_level(name):
		print("[LevelPage] 载入失败：关卡「%s」投影失败" % name)


# 「本体」= 真正把当前关卡 JSON 写回 levels/；MOD / DLC 是占位（提示后不写入）。
# ★ 关卡名 = 输入框里的名字，且**这个名字同时就是文件名**（LevelManager 统一保证）。
#   若该文件已存在，先弹确认框问是否覆盖。
func _on_save_pressed(_id: String) -> void:
	if _save_option == null or not is_instance_valid(_save_option):
		return
	var sel: String = _save_option.get_item_text(_save_option.selected)
	if sel != "本体":
		print("[LevelPage] 保存位置「%s」为占位选项，尚未生效；请选择「本体」" % sel)
		return
	if _level_blocks.is_empty():
		print("[LevelPage] 当前没有可保存的关卡（请先载入/投影一个关卡）")
		return
	if LevelManager == null:
		print("[LevelPage] 保存失败：LevelManager 不可用")
		return
	var name := LevelManager.canonical_name(_editor_name())
	if name.is_empty():
		print("[LevelPage] 保存失败：关卡名为空，请在输入框里给关卡起个名字")
		return
	if not LevelManager.is_valid_level_name(name):
		print("[LevelPage] 保存失败：关卡名「%s」不能用作文件名（不可含 \\ / : * ? \" < > |）" % name)
		return
	var path := LevelManager.level_path(name)
	if FileAccess.file_exists(path):
		# 已有关卡同名 → 询问是否覆盖（点「取消」则放弃本次保存）
		_ask_overwrite(name)
		return
	_do_save_level(name)


# 弹「覆盖确认」框（项目自绘模态框：屏幕居中 + 与其它面板同款样式）。
# ★ 顺序不能反：先收旧框（它的 canceled 会清空 _save_pending），**再**登记本次待确认名。
#   反过来写的话，连点「保存」时旧框关闭会把刚登记的新目标清掉 → 再点「覆盖」静默不保存。
func _ask_overwrite(name: String) -> void:
	_abort_confirm()
	_save_pending = name
	var c := UIConfirmPanel.new()
	c.confirmed.connect(_on_confirm_overwrite)
	c.canceled.connect(_on_cancel_overwrite)
	_confirm = c
	c.open("覆盖确认",
		"关卡「%s」已存在。\n覆盖它？原内容将被本次保存替换。" % name,
		"覆盖", "取消")


# 确认框「覆盖」→ 执行保存
func _on_confirm_overwrite() -> void:
	_confirm = null
	var name := _save_pending
	_save_pending = ""
	if not name.is_empty():
		_do_save_level(name)


# 确认框「取消」→ 放弃本次保存
func _on_cancel_overwrite() -> void:
	_confirm = null
	if not _save_pending.is_empty():
		print("[LevelPage] 已取消覆盖关卡「%s」" % _save_pending)
	_save_pending = ""


# 收掉还开着的确认框（面板重建 / 重复弹窗时用）；按「取消」结算。
func _abort_confirm() -> void:
	if _confirm != null and is_instance_valid(_confirm):
		if _confirm.is_open():
			_confirm.close(false)
	_confirm = null


# 真正写盘：把当前投影积木按 name 存成 levels/<name>.json（★ 文件名即关卡名）。
# 交给 LevelManager.save_level 统一落盘：它会强制 JSON 里的 name == 文件名；
# 传入旧名 → 若本次改了名字（重命名），旧文件一并删除，不会留下重复关卡。
func _do_save_level(name: String) -> void:
	var old := current_level_name
	var err := LevelManager.save_level(name, _serialize_level(name), old)
	if err != OK:
		print("[LevelPage] 保存失败(err=%d)：%s" % [err, LevelManager.level_path(name)])
		return
	# 保存后以这个名字为准：后续保存写同一文件，标题变量也同步（切回非调试时标签显示正确名字）
	current_level_name = name
	if _name_input != null and is_instance_valid(_name_input):
		_name_input.text = name
	GlobalVars.set_var(title_var, name)
	print("[LevelPage] ✓ 已保存关卡「%s」到本体 levels/ → %s" % [name, LevelManager.level_path(name)])


# 把当前投影积木序列化成关卡 JSON。x/y 用积木在舞台的原生（关卡）坐标，
# 这样保存->重新投影能做到位置不漂移。tags 与 JSON 里不一致时才带出。
func _serialize_level(name: String = "") -> Dictionary:
	var blocks: Array = []
	for b in _level_blocks:
		if b == null or not is_instance_valid(b):
			continue
		var rec: Dictionary = {
			"x": b.position.x,
			"y": b.position.y,
			"width": b.width,
			"height": b.height,
		}
		if b.tags != LevelManager.DEFAULT_TAGS:
			var tags: Array = []
			for t in b.tags:
				tags.append(str(t))
			rec["tags"] = tags
		# ★ 字符串 ID 落盘（非空才写）：关卡页的「摄像头锚定」可以按字符串 ID 跟随积木，
		#   而字符串 ID 只有在**存进 JSON** 之后才能跨"重新投影/重新载入"存活
		#   （数字 ID 每次投影都会重新分配，靠不住）。
		#   读回端见 LevelManager.instantiate_blocks 的 `string_id` 分支（早就有，只差这里写出去）。
		if not b.string_id.is_empty():
			rec["string_id"] = b.string_id
		blocks.append(rec)
	var nm := name
	if nm.is_empty():
		nm = current_level_name
	# 相机中心一并落盘：编辑+保存后再载入 → 视角保持（不回中）。与 _free_center / 锚定位置同一套关卡坐标。
	var c := _camera_center()
	var out: Dictionary = {"name": nm, "blocks": blocks, "camera": {"x": c.x, "y": c.y}}
	# 关卡环境（标签集合，仅作标注）：**非空才写** —— 否则每存一次就给旧关卡塞一个空 "env" 键。
	var env := level_env()
	if not env.is_empty():
		out["env"] = env
	return out


# 调大小拖动态回调：沿右下角调整面板大小（收到增量）
func _on_resize_increment(inc: Vector2) -> void:
	if inc == Vector2.ZERO:
		return
	size = _clamp_size(size + inc)


# 当前关卡名称（从绑定的全局变量取值）
func _current_title() -> String:
	return str(GlobalVars.get_var(title_var, ""))


func _refresh_title() -> void:
	if _title_label != null and is_instance_valid(_title_label):
		_title_label.text = _current_title()


# 全局变量变化 → 关卡名称标签跟随刷新
func _on_var_changed(var_name: String, _value: Variant) -> void:
	if var_name == title_var:
		_refresh_title()


# 释放接线与子节点（退出 / 重搭时用）
func destroy() -> void:
	if GlobalVars.changed.is_connected(_on_var_changed):
		GlobalVars.changed.disconnect(_on_var_changed)
	_close_sub_panels()
	_clear()