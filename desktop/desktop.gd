# desktop.gd
# 「桌面」场景根脚本（main scene）。
# 职责：
#   - 生成「桌面屏障」（屏幕外 1px 的四条边界阻挡积木，见 blocks/desktop_barrier.gd）
#     ★ 桌面上**不再预置任何示例积木**：启动时是空的，积木由事件链 / 调试面板 / 右键菜单创建。
#       需要旧的那一整套演示积木（地面 / 受控块 / 父子级 / 检测区…）做回归验证时，
#       用环境变量 HELLONYXEL_DEMO=1 启动（见 desktop/desktop_demo.gd）。
#   - 承载 UI 层（右键菜单 + 属性面板 + 调试面板 + 两个对话面板）
#   - 桌面穿透开关：按 Tab 开启（默认关 → 右键是游戏菜单，开启 → 空白处右键是系统菜单）；
#     关闭穿透走系统托盘右键菜单（见 TrayIcon.cs / TrayRunner）
#   - 鼠标点击游戏内容时把窗口带到前台激活（否则焦点在桌面时收不到键盘，受控积木会失灵）
#   - 属性面板 applied 信号 → 应用 / 入库 / 生成积木
extends Node2D

var ui_layer: CanvasLayer
# 关卡页面专用层：**不缩放**（世界表面，见 _setup_level_page 的说明）且低于 ui_layer。
var page_layer: CanvasLayer
var menu: ContextMenu
var editor: PropertyEditorPanel
var settings_panel: SettingsPanel = null   # 设置页面（托盘菜单打开）
var saves_panel: SaveListPanel = null      # 存档列表面板（托盘菜单打开）
var weather_panel: ApiConfigPanel = null   # 配置天气页面（托盘菜单「配置天气」打开，预留占位）
var ai_panel: ApiConfigPanel = null        # 配置人工智能页面（托盘菜单「配置人工智能」打开，预留占位）
var mod_list_panel: ModListPanel = null    # MOD 列表页（托盘菜单「打开MOD列表」打开，占位）
var calendar_panel: CalendarPanel = null     # 日历/日记/备忘录单页（托盘菜单「打开日历」打开）
var course_schedule_panel: CourseSchedulePanel = null  # 课程表单页（托盘菜单「课程表」/ 双击积木打开）
var version_panel: VersionAnnouncementPanel = null   # 版本与更新公告（托盘菜单「版本」打开）
var inventory_panel: InventoryPanel = null # 背包面板（调试面板「背包」打开）
var device_manager_panel: DeviceManagerPanel = null   # 设备管理面板（双击「设备管理」积木 / 背包「设备管理」打开）
var scan_reconfigure_panel: ScanReconfigurePanel = null   # 扫描重构面板（双击「扫描重构器」积木打开）
var _last_mouse_pos: Vector2 = Vector2.ZERO
var _target_block = null
# 关卡页面（可交互页面；未来关卡场景投影到此表面，见 blocks/level_page.gd）
var _level_page: LevelPage = null
# 家园页面（仿关卡系统的「单一场景家园」；积木随存档保存，见 blocks/home_page.gd）
var _home_page: HomePage = null
# 世界页面（3D 宏观世界；3D 落在窗口内嵌的 SubViewport 里，见 the words/world_page.gd）
var _world_page: WorldPage = null

# 关卡页面的「开关」由这个信号驱动：任意带 button_打开桌面副本 标签的积木双击发出（经 SignalBus）
const LEVEL_OPEN_SIGNAL := "打开桌面副本"

## 背包开关信号（英文）：任意带「button_open_inventory」标签的积木双击发出，
## 经 SignalBus 汇流到桌面后打开背包页面（与关卡页 button_打开桌面副本 同款路径）。
const INVENTORY_OPEN_SIGNAL := "open_inventory"
const INVENTORY_RECYCLE_SIGNAL := "open_inventory_recycle"   # 双击回收站 → 打开背包并仅勾选「在回收站中」

## 关卡页面所在 CanvasLayer 的层号：低于 UI 层(100) → 浮层面板永远压在它上面；
## 高于桌面世界（主场景默认画布 = 0）→ 页面仍盖住桌面积木。该层恒不缩放（见 _setup_level_page）。
const PAGE_LAYER_INDEX := 99
# 测试用积木类型：尺寸对齐桌面图标 / 无重力 / 可拖动 / 碰撞层与「包围桌面图标的积木」一致。
# ★ 故意不含 button_打开桌面副本 标签 —— 需要哪个积木触发关卡页面，由玩家手动给它加这个标签。
const ICON_COPY_TYPE := "icon_placeholder"
const ICON_COPY_FILL := "#3A7BD5AA"
const ICON_COPY_BORDER := "#2E6BD6FF"
# ★「图标占位」的宽 / 高写**系统常量名**（SystemConst 注册，值 = 桌面图标尺寸），而不是写死数值：
#   类型定义里存的是名字，创建积木时由 SystemConst 现读 sysinfo.json 解析成当前设备的实际像素
#   —— 换台设备（图标 32 / 48 / 96 …）占位积木自动跟着变，无需改任何定义。
const ICON_COPY_SIZE_CONST := "icon_size"

# 「虚视跳转器」积木类型：尺寸对齐桌面图标（= 围住图标的大小）/ 可拖动 / 不受重力 /
# 底部显示栏写「虚视跳转器」/ 双击（button_open_darknet 标签）打开暗网入口页。
# 启动时注册为一个新类型（BlockTypes），并自动在桌面放一个实例。
const VIRTUAL_JUMP_TYPE := "virtual_jump"
const VIRTUAL_JUMP_FILL := "#7B3A9DCC"      # 暗紫半透明填充
const VIRTUAL_JUMP_BORDER := "#C77DFFFF"   # 亮紫边框
const VIRTUAL_JUMP_BTN_SIGNAL := "open_darknet"   # 双击发出的按钮信号名（button_open_darknet）
const VIRTUAL_JUMP_SID := "虚视跳转器"             # 自动生成实例的固定字符串 ID（避免重复生成）
var _vj_size := Vector2(48.0, 48.0)   # 虚视跳转器当前尺寸（随图标盒子更新，对齐「围住图标的四个边组成的空间」）
var _vj_spawned := false              # 虚视跳转器实例是否已在场景里（首轮挑空白点放置后置 true）

# 「回收站」积木类型：与「虚视跳转器」同款（尺寸 = 图标选择框盒子 / 可拖动 / 不受重力 /
# 底部显示栏写「回收站」/ 启动时自动放一个实例）。双击打开背包并仅勾选「在回收站中」（button_open_inventory_recycle）。
#   · 虚视跳转器带 button_open_darknet（双击 → 打开暗网入口页）；
#   · 回收站带 to_detect_recycle_bin（待检测_回收站）→ 它是一块「检测区」，
#     任何积木的**中心点**进入它 → 该积木自动获得 detected_recycle_bin（检测到_回收站）。
#     ★ 引擎不对这两个标签做任何特殊处理 —— "被回收"（销毁积木 / 计分 / 触发事件链）
#       由**事件链 / 脚本**监听 detected_recycle_bin 自行完成（见 BlockTags 的说明）。
# ★ 碰撞图层 = BlockLayers.detect_zone_layers()（**独占 detect_zone 层**，不含 default）
#   → 与普通积木的图层集合无交集 = 互不阻挡。这是检测标签的前提：判据要求对方**中心点**
#     落在检测区内，若回收站会把对方挡住，中心就永远进不去、标签永远加不上。
const RECYCLE_BIN_TYPE := "recycle_bin"
const RECYCLE_BIN_FILL := "#4A5A6ACC"      # 石板灰半透明填充（刻意区别于虚视跳转器的暗紫）
const RECYCLE_BIN_BORDER := "#9FB3C8FF"    # 浅石板灰边框
const RECYCLE_BIN_SID := "回收站"           # 自动生成实例的固定字符串 ID（避免重复生成）
var _rb_size := Vector2(48.0, 48.0)   # 回收站当前尺寸（随图标盒子更新，与虚视跳转器同款）
var _rb_spawned := false              # 回收站实例是否已在场景里（首轮挑空白点放置后置 true）

# 「此电脑」积木类型：与「虚视跳转器」同款（尺寸 = 图标选择框盒子 / 可拖动 / 不受重力 /
# 底部显示栏写「此电脑」/ 启动时自动放一个实例）。唯一的区别是按钮标签：
#   · 虚视跳转器带 button_open_darknet（双击 → 打开暗网入口页）；
#   · 此电脑带 button_open_inventory（双击 → 打开背包页面）。
const THIS_PC_TYPE := "this_pc"
const THIS_PC_FILL := "#2E5E8CCC"        # 桌面蓝半透明填充（区别于虚视跳转器的暗紫 / 回收站的石板灰）
const THIS_PC_BORDER := "#7FB2FFFF"      # 亮蓝边框
const THIS_PC_SID := "此电脑"             # 自动生成实例的固定字符串 ID（避免重复生成）
var _pc_size := Vector2(48.0, 48.0)   # 此电脑当前尺寸（随图标盒子更新，与虚视跳转器同款）
var _pc_spawned := false              # 此电脑实例是否已在场景里（首轮挑空白点放置后置 true）

# 「设备管理」积木类型：与「此电脑」同款（尺寸 = 图标选择框盒子 / 可拖动 / 不受重力 /
# 底部显示栏写「设备管理」/ 启动时自动放一个实例）。双击 → 打开「设备管理」页面
# （仿「此电脑」双击 → 打开背包页面）。
const DEVICE_MANAGER_TYPE := "device_manager"
const DEVICE_MANAGER_FILL := "#2E8C6CCC"      # 设备绿蓝半透明填充（区别于此电脑的桌面蓝）
const DEVICE_MANAGER_BORDER := "#7FE0B2FF"    # 亮青绿边框
const DEVICE_MANAGER_SID := "设备管理"         # 自动生成实例的固定字符串 ID（避免重复生成）
const DEVICE_MANAGER_OPEN_SIGNAL := "open_device_manager"
var _dm_size := Vector2(48.0, 48.0)    # 设备管理当前尺寸（随图标盒子更新，与此电脑同款）
var _dm_spawned := false               # 设备管理实例是否已在场景里（首轮挑空白点放置后置 true）

# 「扫描重构器」积木类型（批次 16）：与「设备管理」同款流程（尺寸 = 图标选择框盒子 / 可拖动 /
# 不受重力 / 底部显示栏写「扫描重构器」/ 启动时自动放一个实例）。双击 → 打开「扫描重构」页面。
const SCAN_RECONFIGURE_TYPE := "scan_reconfigure"
const SCAN_RECONFIGURE_FILL := "#8C6C2ECC"      # 琥珀紫半透明填充（与设备管理绿蓝 / 此电脑桌面蓝区分）
const SCAN_RECONFIGURE_BORDER := "#E0C87FFF"    # 亮琥珀紫边框
const SCAN_RECONFIGURE_SID := "扫描重构器"      # 自动生成实例的固定字符串 ID（避免重复生成）
const SCAN_RECONFIGURE_OPEN_SIGNAL := "open_scan_reconfigure"
var _sr_size := Vector2(48.0, 48.0)    # 扫描重构器当前尺寸（随图标盒子更新）
var _sr_spawned := false               # 扫描重构器实例是否已在场景里

# 「日历」积木类型（批次 52）：与「扫描重构器」完全同款流程（尺寸 = 图标选择框盒子 / 可拖动 /
# 不受重力 / 底部显示栏写「日历」/ 启动时自动放一个实例）。双击 → 打开「日历/日记/备忘录」页面。
const CALENDAR_TYPE := "calendar"
const CALENDAR_FILL := "#B23A48CC"       # 暖红半透明填充（与设备管理绿蓝 / 扫描重构器琥珀紫区分）
const CALENDAR_BORDER := "#FFC2B4FF"     # 亮珊瑚边框
const CALENDAR_SID := "日历"             # 自动生成实例的固定字符串 ID（避免重复生成）
const CALENDAR_OPEN_SIGNAL := "open_calendar"
var _cal_size := Vector2(48.0, 48.0)    # 日历当前尺寸（随图标盒子更新）
var _cal_spawned := false               # 日历实例是否已在场景里

# 「课程表」积木类型（批次 111）：与日历完全同款流程（尺寸 = 图标选择框盒子 / 可拖动 /
# 不受重力 / 底部显示栏写「课程表」/ 启动时自动放一个实例）。双击 → 打开「课程表」页面。
const COURSE_SCHEDULE_TYPE := "course_schedule"
const COURSE_SCHEDULE_FILL := "#2E8B97CC"   # 青蓝半透明填充（与日历暖红 / 设备管理绿蓝区分）
const COURSE_SCHEDULE_BORDER := "#A8E6F0FF" # 亮青边框
const COURSE_SCHEDULE_SID := "课程表"       # 自动生成实例的固定字符串 ID（避免重复生成）
const COURSE_SCHEDULE_OPEN_SIGNAL := "open_course_schedule"
var _cs_size := Vector2(48.0, 48.0)    # 课程表当前尺寸（随图标盒子更新）
var _cs_spawned := false               # 课程表实例是否已在场景里

# Tab 键在「桌面穿透未开启」时开启穿透；关闭侧挂在系统托盘右键菜单（见 TrayIcon.cs）
# （不再用 Ctrl+Shift：部分输入法切换占用该组合，会误触发）

# 桌面屏障：{ role -> Block }，role 见 DesktopBarrier.ROLE_*（top/bottom/left/right）
var _barriers: Dictionary = {}
# 任务栏屏障：单条 Block（null 表示当前无任务栏 / 未生成）
var _taskbar_barrier: Variant = null
# 桌面图标边界墙：Block 列表
var _icon_walls: Array = []
# 桌面图标的「选择框」矩形（与上述四条边界墙所围区域**同源同形**）：挑空白落点时当避让区。
# 由 _sync_icon_boundaries 在图标几何变化时刷新（见 DesktopIconBoundary.box_rects）。
var _icon_boxes: Array[Rect2] = []
# 最近一次枚举到的「桌面图标」原始数据（items）与网格间距：供「伪装图标松手对齐」复用。
# ★ 与 _icon_boxes / 图标边界墙**同源**（同一个 items / spacing）→ 对齐到的位置就是
#   "桌面图标会出现的位置"，而不是另算一套网格。
var _icon_items: Variant = null
var _icon_spacing: float = 0.0

# 框选 / 选择集合
var _selection: Array[Block] = []
var _rubber_active := false          # 正在拉框选（位移已超阈值）
var _rubber_pending := false         # 左键已按在空白处、但位移未超阈值（还没真正开始拉框）
var _rubber_union := false           # 本次框选是否为 Shift 加选（合并进现有选择）
var _rubber_start := Vector2.ZERO
var _rubber_end := Vector2.ZERO
# 位移阈值（像素）：按住后的鼠标移动必须超过它才判定为「拖拽 / 框选」。
# 低于该位移就松开 = 一次「点击 / 双击」，不产生框选框（Windows 系统即如此处理）。
const DRAG_THRESHOLD := 6.0

# ★★ 选择/框选的绘制层：**必须是独立子节点**，且 z_index 高于一切积木。
# 原因（2026-09-29 修）：框选框与选中描边原先由 desktop 自己 _draw() 画，而 desktop 是
#   所有积木的**父节点**、z_index 恒为 0 —— Godot 的 CanvasItem 绘制顺序是「父先子后」，
#   同 z_index 时子节点压住父节点，于是：
#     · 桌面图标边界墙（icon_boundary，z=0，376 条，带 show+fill）压住桌面上的一切描边；
#     · 窗口页面积木 page_cover(z=32) / page_frame(z=90)、玩家积木 Blank(z=64) 全都更高。
#   结果 = 拉框时**框选框完全看不见**、选中积木**没有高亮** → 用户报「框选失效、显示不出框选框」。
#   （框选逻辑本身是对的：选择集算得正确，只是画不出来。）
# 解决：把这两样东西挪到一个 z_index = SELECTION_Z 的专属 Node2D 上，永远画在所有积木之上。
#   取 4096：远高于任何 display_layer 基数（玩家 64 / 页面 90），又远低于 CanvasLayer 的层级差。
const SELECTION_Z := 4096
var _overlay: Node2D = null          # 选择高亮 + 框选框的绘制层（见 SELECTION_Z 注释）
# 批编辑范围：本次右键「编辑积木属性」是否作用于整个选中集合
var _batch_edit := false
# 拖动监听：抓捕「拖拽未选中积木 → 清空选择」（拖动事件被 Block 自身 handler 吞掉，
# desktop 收不到按下，得在物理帧里看 Block._dragging_block 的切换）
var _drag_watch_block: Block = null

# 「移到此处」右键命令（积木标签 BlockTags.COMMANDABLE = 可命令）：
#   空白处右键 + 选中集合里含「可命令」积木 → 出现本条目，**不受调试模式限制**。
const MOVE_HERE_LABEL := "移到此处"
const MOVE_HERE_ID := "move_here"

# —— 程序页面 / 桌面图标 的「实时内存枚举」——
# 几何不再落盘到 sysinfo.json，而是由 **预编译的 SysInfo.exe** 定时在**后台线程**枚举（内存解析）。
# ★★ 为什么用 EXE 而不是 PowerShell 脚本：旧路径 `powershell.exe -File enumerate_scene.ps1`
#    每次调用都会 `Add-Type -Path SysInfo.cs` **现编译 30 KB C#**（实测单次 1.0~1.1 s，
#    其中约 0.64 s 花在编译上），而轮询间隔就是 1 s ⇒ 那个 PowerShell 几乎从不空闲，
#    构成与帧率无关的 ~0.28 核固定底噪。EXE 把**编译**与 **PowerShell 宿主的启动**一起去掉，
#    并且用 Windows 子系统编译 ⇒ 连 conhost.exe 都不再新建。
const ENUM_EXE := "res://addons/hellonyxel_sysinfo/SysInfo.exe"
const ENUM_SCRIPT := "res://addons/hellonyxel_sysinfo/enumerate_scene.ps1"   # 仅作 EXE 缺失/失败时的兜底
const ENUM_DEBUG := true   # 首次枚举把窗口清单（含游戏窗口是否被排除）落盘到 Temp/enum_debug.txt，便于排查"虚视跳转器被盖"
const ENUM_INTERVAL_SEC := 0.2          # 轮询间隔：窗口/图标变化在 ~0.2s 内被感知（实验值：0.2s=5Hz ⇒ SysInfo.exe scene ~42ms/次 ≈ 0.2 核；活跃拖动期风扇风险，静止靠 ENUM_IDLE 3s 退避兜底）

# ★★ 批次 8：自适应轮询间隔（空闲降频）。
#   背景：`SysInfo.exe scene` 单次 CPU 46.9 ms（实测 30 次中位）⇒ 1 s 轮询 =
#   **0.047 核固定底噪**，而 60 s 会 spawn **62** 个子进程（验收判据是 0~2）。
#   批次 4 已把单次从 967 ms 打到 40 ms，但**频率没动** ⇒ 这里改频率。
#   做法：连续 `ENUM_STABLE_ROUNDS` 轮枚举结果**完全相同** → 退到 `ENUM_IDLE_INTERVAL_SEC`；
#   一旦出现任何差异立刻回 `ENUM_INTERVAL_SEC`。
#   ★ 判据用**原始 JSON 文本**而不是 `WindowPage.sync` 的 `changed`：
#     后者只覆盖"窗口增删"，**不含窗口移动/缩放**（`_sync_frames` / `_sync_cover` 无回报）
#     ⇒ 用它做判据会在拖动窗口时让边框跟不上。
#   ★ 感知延迟上界 = 退避后的间隔（≤3 s）；且退避期间**每轮仍在比对**，
#     任何真实变化都会立刻把间隔调回 1 s，所以不会叠加成"变化迟迟不响应"。
const ENUM_IDLE_INTERVAL_SEC := 3.0   # 退避后的间隔（手感上界）
const ENUM_STABLE_ROUNDS := 3         # 连续多少轮结果相同才开始退避
var _enum_last_json := ""             # 上一轮枚举的原始 JSON（退避判据）
var _enum_stable := 0                 # 连续"无变化"的轮数
var _enum_backed_off := false         # 当前是否已退避（打印 / 探针用）
var _page_state: Dictionary = {}        # 窗口句柄 -> {frames:[..4], cover:Block}（WindowPage.sync 维护）
var _icon_signature := ""               # 上次图标数据的签名（变了才重排）
var _enum_busy := false                 # 是否已有枚举线程在跑（防叠加）
var _enum_pending := false              # 有结果等主线程解析
var _enum_json := ""
var _enum_mutex := Mutex.new()
var _enum_thread: Thread = null         # 持引用防 GC，用完下一轮复用
var _enum_timer: Timer = null           # 枚举节拍器（忙闲联动会 stop/start）
var _busy_paused := false               # 「在忙」→ 暂停扫描窗口 + 停用图标边界积木系统（见 _apply_busy_pause）
var _game_hwnd := 0                     # 游戏主窗口 HWND（主线程取一次，供枚举精确排除自身窗口）
var _enum_debug_done := false           # 首次枚举诊断只写一次
var _enum_exe_warned := false           # EXE 不可用的告警只打一次（避免每秒刷屏）


func _ready() -> void:
	# 0) 选择/框选绘制层：**必须最先建**，否则后续生成的积木会排在它后面（同 z_index 时按顺序画）。
	#    自身 z_index 拉高（见 SELECTION_Z），保证框选框/选中描边永远压在所有积木之上。
	_setup_selection_overlay()
	# 1) 桌面屏障：启动时按当前桌面矩形生成 4 块（上/下 BedRockX，左/右 BedRockY）
	_setup_barriers()
	# 1b) 系统积木类型：确保「图标边界 / 页面边框 / 页面覆盖」三类落盘到 res://block_types/，
	#     之后实时枚举生成时直接读 JSON（改 JSON 即改自动积木）。须在 _setup_scene_enum 之前。
	_register_system_types()
	# 「场景大小可动」：桌面矩形变化后，屏障跟着重排（DesktopShell 改完尺寸会发这个信号）
	if not DesktopShell.geometry_changed.is_connected(_on_desktop_geometry_changed):
		DesktopShell.geometry_changed.connect(_on_desktop_geometry_changed)

	# 2) 示例积木：默认不生成（桌面启动时为空）。验证用 HELLONYXEL_DEMO=1 打开。
	if OS.get_environment("HELLONYXEL_DEMO") == "1":
		DesktopDemo.spawn(self)
		print("[desktop] 已按 HELLONYXEL_DEMO=1 生成示例积木（仅验证用）")

	# 3) UI 层（置于最上层，承载菜单与属性面板）
	ui_layer = CanvasLayer.new()
	ui_layer.layer = 100
	add_child(ui_layer)
	# ★ UI 缩放（⚠️实验性内容，设置页可调）：施加在本层 —— 层内**所有**面板（含关卡页面）
	#   一并缩放。watch 会先按当前值施加一次，再订阅变化（改设置当场生效）。
	UIStyle.watch_ui_scale(ui_layer)

	menu = ContextMenu.new()
	ui_layer.add_child(menu)
	menu.item_selected.connect(_on_menu_selected)

	# 退出调试模式 → 清掉「不可被选中」的积木，避免选中残留（见 _is_selectable）
	if not Debug.mode_changed.is_connected(_on_debug_mode_changed):
		Debug.mode_changed.connect(_on_debug_mode_changed)

	editor = PropertyEditorPanel.new()
	ui_layer.add_child(editor)
	editor.applied.connect(_on_editor_applied)

	# 设置页面：由系统托盘图标的右键二级菜单「设置 → 打开设置」打开
	settings_panel = SettingsPanel.new()
	ui_layer.add_child(settings_panel)
	if not TrayRunner.settings_requested.is_connected(_open_settings):
		TrayRunner.settings_requested.connect(_open_settings)

	# 存档列表页面：由系统托盘图标的右键菜单「打开存档列表」打开
	saves_panel = SaveListPanel.new()
	ui_layer.add_child(saves_panel)
	if not TrayRunner.saves_list_requested.is_connected(open_saves_list):
		TrayRunner.saves_list_requested.connect(open_saves_list)

	# 配置天气页面：由系统托盘右键菜单「配置天气」打开（记录 定位 / API → weather.json）
	weather_panel = ApiConfigPanel.new()
	weather_panel.config_kind = "weather"
	weather_panel.config_title = "配置天气"
	ui_layer.add_child(weather_panel)
	if not TrayRunner.weather_config_requested.is_connected(_open_weather_config):
		TrayRunner.weather_config_requested.connect(_open_weather_config)

	# 配置人工智能页面：由系统托盘右键菜单「配置人工智能」打开（记录 API / 提示词 / 个人信息文件 → ai.json）
	ai_panel = ApiConfigPanel.new()
	ai_panel.config_kind = "ai"
	ai_panel.config_title = "配置人工智能"
	ui_layer.add_child(ai_panel)
	if not TrayRunner.ai_config_requested.is_connected(_open_ai_config):
		TrayRunner.ai_config_requested.connect(_open_ai_config)

	# MOD 列表页：由系统托盘右键菜单「打开MOD列表」打开（占位，业务未接入）
	mod_list_panel = ModListPanel.new()
	ui_layer.add_child(mod_list_panel)
	if not TrayRunner.mod_list_requested.is_connected(_open_mod_list):
		TrayRunner.mod_list_requested.connect(_open_mod_list)

	# 日历/日记/备忘录单页：由系统托盘右键菜单「打开日历」打开（新手友好入口）
	calendar_panel = CalendarPanel.new()
	ui_layer.add_child(calendar_panel)
	if not TrayRunner.calendar_requested.is_connected(_open_calendar):
		TrayRunner.calendar_requested.connect(_open_calendar)

	# 课程表单页：由系统托盘右键菜单「课程表」/ 双击「课程表」积木打开
	course_schedule_panel = CourseSchedulePanel.new()
	ui_layer.add_child(course_schedule_panel)
	if not TrayRunner.course_schedule_requested.is_connected(_open_course_schedule):
		TrayRunner.course_schedule_requested.connect(_open_course_schedule)

	# 版本与更新公告：由系统托盘右键菜单「版本」打开（读取最新版本号 + 更新公告）
	version_panel = VersionAnnouncementPanel.new()
	ui_layer.add_child(version_panel)
	if not TrayRunner.version_requested.is_connected(_open_version_announcement):
		TrayRunner.version_requested.connect(_open_version_announcement)

	# 进入/退出调试模式：由系统托盘右键菜单「进入/退出调试模式」触发（切换 Debug.debug_mode）
	if not TrayRunner.toggle_debug_requested.is_connected(_on_tray_toggle_debug):
		TrayRunner.toggle_debug_requested.connect(_on_tray_toggle_debug)

	# 性能忙闲判断面板：由系统托盘图标的右键菜单「性能忙闲判断」打开
	if not TrayRunner.perf_busy_requested.is_connected(_open_perf_busy):
		TrayRunner.perf_busy_requested.connect(_open_perf_busy)

	# 背包面板：物品拖出→按「构建_XXX{}」标签生成积木并消耗 1 个
	inventory_panel = InventoryPanel.new()
	ui_layer.add_child(inventory_panel)

	# 设备管理面板：管理多台设备 / 安装零件 / 上线下线 / 新建设备（双击「设备管理」积木或背包「设备管理」打开）
	device_manager_panel = DeviceManagerPanel.new()
	ui_layer.add_child(device_manager_panel)

	# 扫描重构面板：双击「扫描重构器」积木打开（当前为骨架占位：输入框 → 长箭头 → 输出框）
	scan_reconfigure_panel = ScanReconfigurePanel.new()
	ui_layer.add_child(scan_reconfigure_panel)

	# 对话面板：底部对话面板 + 弹窗对话面板（自身监听 DialogueManager，随全局变量显隐/刷新）
	var bottom_dlg := BottomDialoguePanel.new()
	var popup_dlg := PopupDialoguePanel.new()
	ui_layer.add_child(bottom_dlg)
	ui_layer.add_child(popup_dlg)

	# 4) 实时内存枚举：程序页面边框/覆盖 + 桌面图标边界（后台线程定时拉取，内存解析）
	_setup_scene_enum()

# 5) 关卡页面：搭起可交互的「关卡」页面（边框/覆盖 + 标题文字 + 缩放按钮）
#    ★ 层级约定：关卡页面是「工作区表面」，必须低于所有浮层（右键菜单、属性面板、
#      对话/背包/设置等面板，以及动态挂到 ui_layer 的长文本窗、标签选择器），
#      同时高于桌面世界（主场景）的积木。用**独立 CanvasLayer(99) < ui_layer(100)** 表达，
#      绘制与输入顺序都由层号唯一确定（不再依赖「同层内 z_index + move_child」那套技巧）。
	_setup_level_page()
	_setup_home_page()
	_setup_world_page()

	# 6) 虚视跳转器：注册类型（落 JSON）；实例在首次窗口枚举后挑「空白处」放置
	#    （避开窗口，避免一启动就被页面覆盖的 cutout 洞穿透；见 _ensure_virtual_jump_spawned）
	_register_virtual_jump_type()
	# 兜底：若枚举/PowerShell 失败导致首轮 _apply_scene_data 没跑到，3s 后按默认点放置，保证一定出现
	var vj_fb := Timer.new()
	vj_fb.wait_time = 3.0
	vj_fb.one_shot = true
	vj_fb.timeout.connect(_spawn_virtual_jump_block)
	add_child(vj_fb)
	vj_fb.start()

	# 7) 回收站：与虚视跳转器同款流程（注册类型 + 首轮挑空白点放置 + 3s 兜底）。
	#    ★ 挑点时**额外避开虚视跳转器**（见 _ensure_recycle_bin_spawned）——
	#      两者的候选落点算法同源，不避让就会叠在一起。
	_register_recycle_bin_type()
	var rb_fb := Timer.new()
	rb_fb.wait_time = 3.0
	rb_fb.one_shot = true
	# 兜底走完整流程（传空窗口列表）：既挑点又避让虚视跳转器、并与"首轮已放置"互斥。
	# 用 0 参 lambda 接 timeout（信号自带 0 参 + 0 绑定 = 恰好 1 个实参传进去）。
	rb_fb.timeout.connect(func() -> void: _ensure_recycle_bin_spawned([]))
	add_child(rb_fb)
	rb_fb.start()

	# 8) 此电脑：与虚视跳转器同款流程（注册类型 + 首轮挑空白点放置 + 3s 兜底）。
	#    ★ 挑点时额外避开虚视跳转器 / 回收站（见 _ensure_this_pc_spawned）。
	_register_this_pc_type()
	var pc_fb := Timer.new()
	pc_fb.wait_time = 3.0
	pc_fb.one_shot = true
	pc_fb.timeout.connect(_spawn_this_pc_block)
	add_child(pc_fb)
	pc_fb.start()

	# 9) 设备管理：与「此电脑」同款流程（注册类型 + 首轮挑空白点放置 + 3s 兜底）。
	#    ★ 挑点时额外避开虚视跳转器 / 回收站 / 此电脑（见 _ensure_device_manager_spawned）。
	_register_device_manager_type()
	var dm_fb := Timer.new()
	dm_fb.wait_time = 3.0
	dm_fb.one_shot = true
	dm_fb.timeout.connect(_spawn_device_manager_block)
	add_child(dm_fb)
	dm_fb.start()

	# 10) 扫描重构器：与「设备管理」同款流程（注册类型 + 首轮挑空白点放置 + 3s 兜底）。
	#     ★ 挑点时额外避开 虚视跳转器 / 回收站 / 此电脑 / 设备管理（见 _ensure_scan_reconfigure_spawned）。
	_register_scan_reconfigure_type()
	var sr_fb := Timer.new()
	sr_fb.wait_time = 3.0
	sr_fb.one_shot = true
	sr_fb.timeout.connect(_spawn_scan_reconfigure_block)
	add_child(sr_fb)
	sr_fb.start()

	# 10b) 日历：与「扫描重构器」同款流程（注册类型 + 首轮挑空白点放置 + 3s 兜底）。
	#      ★ 挑点时额外避开 虚视跳转器 / 回收站 / 此电脑 / 设备管理 / 扫描重构器（见 _ensure_calendar_spawned）。
	_register_calendar_type()
	var cal_fb := Timer.new()
	cal_fb.wait_time = 3.0
	cal_fb.one_shot = true
	cal_fb.timeout.connect(_spawn_calendar_block)
	add_child(cal_fb)
	cal_fb.start()

	# 10b2) 课程表：与「日历」同款流程（注册类型 + 首轮挑空白点放置 + 3s 兜底）。
	#       ★ 挑点时额外避开 虚视跳转器 / 回收站 / 此电脑 / 设备管理 / 扫描重构器 / 日历（见 _ensure_course_schedule_spawned）。
	_register_course_schedule_type()
	var cs_fb := Timer.new()
	cs_fb.wait_time = 3.0
	cs_fb.one_shot = true
	cs_fb.timeout.connect(_spawn_course_schedule_block)
	add_child(cs_fb)
	cs_fb.start()

	# 10c) 状态文件自检：**进入游戏前**，Temp 目录下的状态 JSON（玩家画像 / 荧惑日常状态 /
	#      日历笔记 / 设备清单 / 背包 / 通用状态…）若残缺 → 按各自默认值补建文件。
	#      ★ 必须放在第 11 步「自动载入存档」之前：读档会把存档内的 Temp 覆盖回来，
	#        覆盖后还会再自检一次（见 SaveManager.load_save 的 1b 步）。
	SaveManager.ensure_temp_files()

	# 11) 自动载入最新存档：设置页开启「自动载入存档」时，主场景就绪后自动载入最新存档。
	#     ★ deferred 执行：load_save 依赖 get_tree().current_scene（=本场景）已就绪；
	#       自动块（虚视跳转器/回收站/此电脑…）的生成守卫按 string_id 判重，载入的存档若含这些块
	#       会被识别为已存在 → 不会重复生成（见 _ensure_virtual_jump_spawned）。
	_auto_load_latest_on_startup()


# ============ 自动载入存档（启动） ============

## 启动自动载入：设置开启时，在主场景就绪后载入 created_at 最新的存档。
## 由 _ready 末尾调用；真正执行走 call_deferred，确保 current_scene 已就位。
func _auto_load_latest_on_startup() -> void:
	if SaveManager == null or not SaveManager.get_auto_load_save():
		return
	call_deferred("_do_auto_load_latest")


## 实际载入（deferred）：list_saves 已按 created_at 倒序，[0] 即最新。
func _do_auto_load_latest() -> void:
	if SaveManager == null or not SaveManager.get_auto_load_save():
		return
	var saves := SaveManager.list_saves()
	if saves.is_empty():
		return
	var latest: Dictionary = saves[0]
	var name: String = str(latest.get("name", ""))
	if name.is_empty():
		return
	var res := SaveManager.load_save(name)
	if res.get("ok", false):
		print("[desktop] 已按设置自动载入最新存档：%s" % name)
	else:
		push_warning("[desktop] 自动载入存档失败：%s（%s）" % [name, str(res.get("message", ""))])


# ============ 关卡页面 ============

# 在桌面偏上的位置搭「关卡」页面（未来关卡场景投影到此表面；投影接线另做）。
# 页面默认**隐藏**，收到「打开桌面副本」信号才显示（开关见 _on_level_page_button）。
#
# ★★ 为什么关卡页面**不**跟 UI 缩放（独立 CanvasLayer 99，scale 恒为 1）：
#   它是**世界表面**而不是面板 —— 里面是带碰撞/传送/物理的关卡积木，与桌面积木共用一套
#   屏幕坐标（见 PortalManager 的说明）。若让它跟着 UI 缩放：
#     · 同一块积木在关卡里会比桌面大 s 倍，跨场景传送时尺寸突变；
#     · 传送落点要「积木相对入口的偏移 + 出口坐标」跨画布换算，明显更易错。
#   所以：浮层面板（ui_layer=100）缩放，世界表面（本层=99）保持 1:1。
func _setup_level_page() -> void:
	page_layer = CanvasLayer.new()
	page_layer.layer = PAGE_LAYER_INDEX
	add_child(page_layer)
	var rect := _screen_rect_to_page(DesktopShell.get_desktop_rect_f())
	var page := LevelPage.new()
	page_layer.add_child(page)
	page.origin = Vector2(rect.position.x + maxf(40.0, (rect.size.x - 560.0) * 0.5), rect.position.y + 90.0)
	page.size = Vector2(560.0, 380.0)
	page.build("level_title")
	# ★ 注入「桌面世界」= 本场景根：关卡积木被传送门送出关卡时退回这里（桌面 = 主场景根，
	#   它同时是桌面积木的父节点，也在同一坐标系（原点、无缩放））。
	page.desktop_world = self
	# build() 会按「不小于分辨率一半」把面板撑大 → 定位随之夹回桌面矩形内，避免溢出右/下边缘。
	page.origin = Vector2(
		clampf(page.origin.x, rect.position.x, rect.position.x + rect.size.x - page.size.x),
		clampf(page.origin.y, rect.position.y, rect.position.y + rect.size.y - page.size.y))
	_level_page = page
	# 关卡页判定为「右键单击」（位移未超拖动阈值）时补弹右键菜单：按下瞬间无法区分单击/拖动，
	# 菜单只能等抬起后由关卡页发信号过来（见 LevelPage.right_click_at / _on_level_right_click）。
	if not page.right_click_at.is_connected(_on_level_right_click):
		page.right_click_at.connect(_on_level_right_click)
	# 登记到 LevelManager：控制台 /load_level 等按名投影的入口据此定位关卡面板
	if LevelManager != null:
		LevelManager.level_page = page
	# 注册测试用积木类型 + 收「打开桌面副本」信号
	_register_icon_copy_type()
	if not SignalBus.block_button.is_connected(_on_block_button_signal):
		SignalBus.block_button.connect(_on_block_button_signal)
	# 默认隐藏：需要「打开桌面副本」信号才打开
	page.set_page_visible(false)


# 家园页面接线（仿 _setup_level_page）：复用同一张 page_layer（CanvasLayer 99），
# 创建 HomePage 并登记到 HomeManager，右键单击经 right_click_at 信号补弹菜单。
# ★ 家园是单一场景，不需要「打开桌面副本」信号；开关由控制台 /open_home 与事件链 "home" 驱动。
func _setup_home_page() -> void:
	if page_layer == null or not is_instance_valid(page_layer):
		page_layer = CanvasLayer.new()
		page_layer.layer = PAGE_LAYER_INDEX
		add_child(page_layer)
	var rect := _screen_rect_to_page(DesktopShell.get_desktop_rect_f())
	var page := HomePage.new()
	page_layer.add_child(page)
	# ★ 与关卡页错开起点，避免两者同时可见时完全重叠
	page.origin = Vector2(rect.position.x + 60.0, rect.position.y + 60.0)
	page.size = Vector2(560.0, 380.0)
	page.build("home_title")
	# 注入「桌面世界」= 本场景根（家园积木被传送门送出家园时退回这里）
	page.desktop_world = self
	page.origin = Vector2(
		clampf(page.origin.x, rect.position.x, rect.position.x + rect.size.x - page.size.x),
		clampf(page.origin.y, rect.position.y, rect.position.y + rect.size.y - page.size.y))
	_home_page = page
	# 家园页判定为「右键单击」时补弹右键菜单（同关卡页 right_click_at）
	if not page.right_click_at.is_connected(_on_home_right_click):
		page.right_click_at.connect(_on_home_right_click)
	# 登记到 HomeManager：控制台 /open_home 等入口据此定位家园面板
	if HomeManager != null:
		HomeManager.home_page = page
	# 默认隐藏：由 /open_home 或事件链 "home" 打开
	page.set_page_visible(false)


# 世界页面接线（仿 _setup_home_page）：复用同一张 page_layer（CanvasLayer 99），
# 创建 WorldPage（3D 宏观世界：内嵌 SubViewport + 左侧「世界节点」列表 + 镜头锚定）。
# ★ 默认隐藏；开关由调试面板的「世界页面」按钮驱动（desktop.toggle_world_page）。
func _setup_world_page() -> void:
	if page_layer == null or not is_instance_valid(page_layer):
		page_layer = CanvasLayer.new()
		page_layer.layer = PAGE_LAYER_INDEX
		add_child(page_layer)
	var rect := _screen_rect_to_page(DesktopShell.get_desktop_rect_f())
	var page := WorldPage.new()
	page_layer.add_child(page)
	# ★ 与关卡页/家园页错开起点，避免同时可见时完全重叠
	page.origin = Vector2(rect.position.x + 110.0, rect.position.y + 100.0)
	page.size = Vector2(660.0, 440.0)
	page.build("world_title")
	page.origin = Vector2(
		clampf(page.origin.x, rect.position.x, rect.position.x + rect.size.x - page.size.x),
		clampf(page.origin.y, rect.position.y, rect.position.y + rect.size.y - page.size.y))
	_world_page = page
	page.set_page_visible(false)


# 登记「图标占位」内置类型默认模板（仅内存，绝不写盘）；JSON 在创建时读取、保存时写盘。
# 宽高写系统常量名（ICON_COPY_SIZE_CONST），由 SystemConst 在创建积木时按当前设备解析。
func _register_icon_copy_type() -> void:
	BlockTypes.ensure_builtin_type(ICON_COPY_TYPE, _icon_copy_def(),
		{"width": ICON_COPY_SIZE_CONST, "height": ICON_COPY_SIZE_CONST})
	print("[desktop] 确保图标占位类型（宽高 = 常量 %s，当前解析 = %s）"
		% [ICON_COPY_SIZE_CONST, str(SystemConst.get_value(ICON_COPY_SIZE_CONST))])


# 「图标占位」类型定义（默认；首次启动落盘，之后以 JSON 为准）
func _icon_copy_def() -> Dictionary:
	return {
		"name": ICON_COPY_TYPE,
		"width": ICON_COPY_SIZE_CONST, "height": ICON_COPY_SIZE_CONST,
		"display_layer": 0,
		"collision_layer": BlockLayers.icon_boundary_layers(),
		"border_width": 2.0,
		"border_color": ICON_COPY_BORDER,
		"fill_color": ICON_COPY_FILL,
		"fill_path": "", "fill_mode": 0, "fill_anim": 0,
		"rotation_deg": 0.0,
		"text_boxes": [], "parent_id": 0, "child_ids": [],
		"tags": PackedStringArray([BlockTags.SHOW, BlockTags.FILL, BlockTags.BORDER,
			BlockTags.COLLISION, BlockTags.DRAGGABLE, BlockTags.DESKTOP_ICON]),
	}


# 登记「虚视跳转器」内置类型默认模板（仅内存，绝不写盘）；JSON 在创建时读取、保存时写盘。
#   · 尺寸 = 桌面图标尺寸（系统常量 icon_size）→ 与「围住桌面图标」的大小一致
#   · 标签：显示/填充/边框/碰撞/文本 + 可拖动(draggable) + 双击按钮(button_open_darknet)
#            ★ 故意不含 gravity → 不受重力影响（浮在放置处，可自由拖动）
#   · 底部显示栏：一个贴底文本框，居中写「虚视跳转器」
func _register_virtual_jump_type() -> void:
	BlockTypes.ensure_builtin_type(VIRTUAL_JUMP_TYPE, _virtual_jump_def())
	print("[desktop] 确保虚视跳转器类型（尺寸=%s）" % str(_vj_size))


# 「虚视跳转器」类型定义（默认；首次启动落盘，之后以 JSON 为准）
#   · 尺寸 = 图标选择框盒子（_vj_size，随图标枚举更新）→ 与「围住图标的四个边组成的空间」一致
#   · display_layer = 0 = 桌面层：伪装成桌面文件，真实窗口（页面覆盖 33+ / 边框 90）能盖住它
#   · 标签：显示/填充/边框/碰撞/文本 + 可拖动(draggable) + 双击按钮(button_open_darknet)
#            ★ 故意不含 gravity → 不受重力影响（浮在放置处，可自由拖动）
#   · 底部显示栏：一个贴底文本框，居中写「虚视跳转器」，随块宽拉伸
func _virtual_jump_def() -> Dictionary:
	var s := _vj_size.x
	var bar_h: float = maxf(22.0, s * 0.34)
	var bar_cy: float = _vj_size.y * 0.5 - bar_h * 0.5   # 贴底（center_offset.y 正=向下）
	return {
		"name": VIRTUAL_JUMP_TYPE,
		"width": _vj_size.x, "height": _vj_size.y,
		"display_layer": 0,
		"collision_layer": BlockLayers.icon_boundary_layers(),
		"border_width": 3.0,
		"border_color": VIRTUAL_JUMP_BORDER,
		"fill_color": VIRTUAL_JUMP_FILL,
		"fill_path": "res://textures/apps/network_globe.png", "fill_mode": 0, "fill_anim": 0,
		"rotation_deg": 0.0,
		"text_boxes": [
			{
				"name": "底部栏",
				"width": _vj_size.x,
				"height": bar_h,
				"cx": 0.0,
				"cy": bar_cy,
				"border_color": "#00000000",
				"fill_color": "#00000000",
				"fill_source": 0,
				"fill_image_path": "",
				"rotation_deg": 0.0,
				"follow_block_rotation": false,
				"text_def": "(C)[虚视跳转器]",
				"text_defs": {
					"zh_CN": "(C)[虚视跳转器]",
					"zh_TW": "(C)[虛視跳轉器]",
					"en": "(C)[Virtual Jump Device]",
					"ja": "(C)[仮想ジャンプ装置]",
					"ru": "(C)[Устройство виртуального прыжка]",
					"ko": "(C)[가상 점프 장치]",
					"es": "(C)[Dispositivo de salto virtual]",
					"pt": "(C)[Dispositivo de salto virtual]",
					"fr": "(C)[Appareil de saut virtuel]",
					"de": "(C)[Virtuelles Sprunggerät]",
					"it": "(C)[Dispositivo di salto virtuale]",
					"tr": "(C)[Sanal Atlama Cihazı]",
					"pl": "(C)[Wirtualne urządzenie skoku]",
					"th": "(C)[อุปกรณ์กระโดดเสมือน]",
					"vi": "(C)[Thiết bị nhảy ảo]",
				},
				"hide_when_empty": false,
			}
		],
		"parent_id": 0, "child_ids": [],
		"tags": PackedStringArray([BlockTags.SHOW, BlockTags.FILL,
			BlockTags.COLLISION, BlockTags.TEXT, BlockTags.DRAGGABLE, BlockTags.DESKTOP_ICON,
			BlockTags.button_tag(VIRTUAL_JUMP_BTN_SIGNAL), BlockTags.SELECTABLE, BlockTags.FILL_IMAGE]),
	}


# 登记「回收站」内置类型默认模板（仅内存，绝不写盘）；JSON 在创建时读取、保存时写盘。
#   · 尺寸 = 桌面图标尺寸（_rb_size，随图标枚举更新）→ 与虚拟跳转器取同一个选择框盒子
#   · 标签：显示/填充/边框/碰撞/文本 + 可拖动 + **待检测_回收站**（to_detect_recycle_bin）
#            ★ 故意不含 gravity → 不受重力影响（浮在放置处，可自由拖动）
#            ★ 故意不含任何 button_* → 双击不做任何事（与虚视跳转器的唯一区别）
func _register_recycle_bin_type() -> void:
	BlockTypes.ensure_builtin_type(RECYCLE_BIN_TYPE, _recycle_bin_def())
	print("[desktop] 确保回收站类型（尺寸=%s）" % str(_rb_size))


# 「回收站」类型定义 —— 逐字段照抄 _virtual_jump_def()，只改三处：
#   collision_layer → 独占 detect_zone 层（不阻挡普通积木，普通积木能走进它中心）
#   tags            → button_open_darknet 换成 to_detect_recycle_bin（按钮 → 检测区）
#   颜色 / 底部栏文字 → 回收站自己的配色与「回收站」字样
func _recycle_bin_def() -> Dictionary:
	var s := _rb_size.x
	var bar_h: float = maxf(22.0, s * 0.34)
	var bar_cy: float = _rb_size.y * 0.5 - bar_h * 0.5   # 贴底（center_offset.y 正=向下）
	return {
		"name": RECYCLE_BIN_TYPE,
		"width": _rb_size.x, "height": _rb_size.y,
		"display_layer": 0,
		"collision_layer": BlockLayers.detect_zone_layers(),
		"border_width": 3.0,
		"border_color": RECYCLE_BIN_BORDER,
		"fill_color": RECYCLE_BIN_FILL,
		"fill_path": "res://textures/apps/recycle_bin.png", "fill_mode": 0, "fill_anim": 0,
		"rotation_deg": 0.0,
		"text_boxes": [
			{
				"name": "底部栏",
				"width": _rb_size.x,
				"height": bar_h,
				"cx": 0.0,
				"cy": bar_cy,
				"border_color": "#00000000",
				"fill_color": "#00000000",
				"fill_source": 0,
				"fill_image_path": "",
				"rotation_deg": 0.0,
				"follow_block_rotation": false,
				"text_def": "(C)[回收站]",
				"text_defs": {
					"zh_CN": "(C)[回收站]",
					"zh_TW": "(C)[資源回收筒]",
					"en": "(C)[Recycle Bin]",
					"ja": "(C)[ゴミ箱]",
					"ru": "(C)[Корзина]",
					"ko": "(C)[휴지통]",
					"es": "(C)[Papelera de reciclaje]",
					"pt": "(C)[Lixeira]",
					"fr": "(C)[Corbeille]",
					"de": "(C)[Papierkorb]",
					"it": "(C)[Cestino]",
					"tr": "(C)[Geri Dönüşüm Kutusu]",
					"pl": "(C)[Kosz]",
					"th": "(C)[ถังรีไซเคิล]",
					"vi": "(C)[Thùng rác]",
				},
				"hide_when_empty": false,
			}
		],
		"parent_id": 0, "child_ids": [],
		"tags": PackedStringArray([BlockTags.SHOW, BlockTags.FILL,
			BlockTags.COLLISION, BlockTags.TEXT, BlockTags.DRAGGABLE, BlockTags.DESKTOP_ICON,
			BlockTags.pending_detect_tag(BlockTags.DETECT_KEY_RECYCLE_BIN),
			BlockTags.button_tag(INVENTORY_RECYCLE_SIGNAL), BlockTags.SELECTABLE, BlockTags.FILL_IMAGE]),
	}


# 登记「此电脑」内置类型默认模板（仅内存，绝不写盘）；JSON 在创建时读取、保存时写盘。
#   · 尺寸 = 桌面图标尺寸（_pc_size，随图标枚举更新）→ 与虚拟跳转器取同一个选择框盒子
#   · 标签：显示/填充/边框/碰撞/文本 + 可拖动 + 双击按钮(button_open_inventory)
#            ★ 故意不含 gravity → 不受重力影响（浮在放置处，可自由拖动）
#   · 底部显示栏：一个贴底文本框，居中写「此电脑」，随块宽拉伸
func _register_this_pc_type() -> void:
	BlockTypes.ensure_builtin_type(THIS_PC_TYPE, _this_pc_def())
	print("[desktop] 确保此电脑类型（尺寸=%s）" % str(_pc_size))


# 「此电脑」类型定义 —— 逐字段照抄 _virtual_jump_def()，只改三处：
#   colors  → 此电脑自己的配色（桌面蓝）
#   底部栏文字 → 「此电脑」
#   tags    → button_open_darknet 换成 button_open_inventory（双击 → 打开背包页面）
func _this_pc_def() -> Dictionary:
	var s := _pc_size.x
	var bar_h: float = maxf(22.0, s * 0.34)
	var bar_cy: float = _pc_size.y * 0.5 - bar_h * 0.5   # 贴底（center_offset.y 正=向下）
	return {
		"name": THIS_PC_TYPE,
		"width": _pc_size.x, "height": _pc_size.y,
		"display_layer": 0,
		"collision_layer": BlockLayers.icon_boundary_layers(),
		"border_width": 3.0,
		"border_color": THIS_PC_BORDER,
		"fill_color": THIS_PC_FILL,
		"fill_path": "res://textures/apps/computer.png", "fill_mode": 0, "fill_anim": 0,
		"rotation_deg": 0.0,
		"text_boxes": [
			{
				"name": "底部栏",
				"width": _pc_size.x,
				"height": bar_h,
				"cx": 0.0,
				"cy": bar_cy,
				"border_color": "#00000000",
				"fill_color": "#00000000",
				"fill_source": 0,
				"fill_image_path": "",
				"rotation_deg": 0.0,
				"follow_block_rotation": false,
				"text_def": "(C)[此电脑]",
				"text_defs": {
					"zh_CN": "(C)[此电脑]",
					"zh_TW": "(C)[本機]",
					"en": "(C)[This PC]",
					"ja": "(C)[この PC]",
					"ru": "(C)[Этот компьютер]",
					"ko": "(C)[내 PC]",
					"es": "(C)[Este equipo]",
					"pt": "(C)[Este computador]",
					"fr": "(C)[Ce PC]",
					"de": "(C)[Dieser PC]",
					"it": "(C)[Questo PC]",
					"tr": "(C)[Bu Bilgisayar]",
					"pl": "(C)[Ten komputer]",
					"th": "(C)[พีซีนี้]",
					"vi": "(C)[PC này]",
				},
				"hide_when_empty": false,
			}
		],
		"parent_id": 0, "child_ids": [],
		"tags": PackedStringArray([BlockTags.SHOW, BlockTags.FILL,
			BlockTags.COLLISION, BlockTags.TEXT, BlockTags.DRAGGABLE, BlockTags.DESKTOP_ICON,
			BlockTags.button_tag(INVENTORY_OPEN_SIGNAL), BlockTags.SELECTABLE, BlockTags.FILL_IMAGE]),
	}


# 在桌面放置一个「此电脑」实例（启动即可见、可拖动、双击开背包页面）
# ★ 用固定字符串 ID 去重：读档恢复等情况已存在该实例时不再重复生成。
#   pos 省略时用默认点（桌面顶部居中偏左，避开虚视跳转器 / 回收站的默认点）。
func _spawn_this_pc_block(pos: Vector2 = Vector2.ZERO) -> void:
	if BlockManager.get_block_by_string_id(THIS_PC_SID) != null:
		_pc_spawned = true
		return   # 已有实例，不重复生成
	var b := BlockTypes.create_block(THIS_PC_TYPE)
	if b == null:
		push_warning("[desktop] 此电脑类型尚未注册，无法放置实例")
		return
	var rect := DesktopShell.get_desktop_rect_f()
	var p := pos
	if p == Vector2.ZERO:
		p = Vector2(rect.position.x + rect.size.x * 0.5 - 160.0, rect.position.y + 140.0)
	b.global_position = p
	add_child(b)
	BlockManager.set_string_id(b, THIS_PC_SID)
	_pc_spawned = true
	print("[desktop] 已放置此电脑积木 id=%d pos=%s tags=%s" % [b.id, str(p), str(b.tags)])


# 首轮窗口枚举后调用：若实例尚未生成，挑一个「不被任何窗口 / 不被虚视跳转器 / 回收站覆盖」的
# 空白点放置。与 _ensure_virtual_jump_spawned 同构，差别是多了"避开虚视跳转器 + 回收站"。
func _ensure_this_pc_spawned(windows: Variant) -> void:
	if _pc_spawned:
		return
	if BlockManager.get_block_by_string_id(THIS_PC_SID) != null:
		_pc_spawned = true
		return
	var wins: Array = windows if windows is Array else []
	var rect := DesktopShell.get_desktop_rect_f()
	# ★ 避让区 = 真实窗口 + 桌面图标选择框 + 已就位的虚视跳转器 + 回收站。
	var search: Array = []
	search.append_array(wins)
	for r in _icon_boxes:
		search.append({"x": r.position.x, "y": r.position.y, "w": r.size.x, "h": r.size.y})
	var vj_w := _block_as_window(BlockManager.get_block_by_string_id(VIRTUAL_JUMP_SID))
	if not vj_w.is_empty():
		search.append(vj_w)
	var rb_w := _block_as_window(BlockManager.get_block_by_string_id(RECYCLE_BIN_SID))
	if not rb_w.is_empty():
		search.append(rb_w)
	var pos := _find_free_spot(search, rect, _pc_size)
	_spawn_this_pc_block(pos)
	# ★ 生成走的是 JSON 落盘尺寸（可能是首次注册时的 48×48 兜底值），而本轮
	#   _sync_icon_boundaries 先于本函数执行、对齐时实例尚不存在被 no-op 掉，
	#   故生成后立即按当前图标盒子（_pc_size）强制对齐一次，保证尺寸=选择框。
	if BlockManager.get_block_by_string_id(THIS_PC_SID) != null:
		_resize_this_pc_block(_pc_size)
	var pc := BlockManager.get_block_by_string_id(THIS_PC_SID)
	if pc != null:
		var cover := _count_windows_overlapping(pos, Vector2(pc.width, pc.height), wins)
		_dump_spawn_debug(pc, wins, rect, "spawn cover=%d" % cover, "pc_debug.txt")


func _resize_this_pc_block(box: Vector2) -> void:
	_resize_auto_block(THIS_PC_SID, box)


# 「设备管理」类型注册（落 JSON，与此电脑同款）
func _register_device_manager_type() -> void:
	BlockTypes.ensure_builtin_type(DEVICE_MANAGER_TYPE, _device_manager_def())
	print("[desktop] 确保设备管理类型（尺寸=%s）" % str(_dm_size))


# 「设备管理」类型定义 —— 照抄 _this_pc_def()，只改三处：
#   colors  → 设备管理自己的配色（设备绿蓝）
#   底部栏文字 → 「设备管理」
#   tags    → button_open_inventory 换成 button_open_device_manager（双击 → 打开设备管理页）
func _device_manager_def() -> Dictionary:
	var s := _dm_size.x
	var bar_h: float = maxf(22.0, s * 0.34)
	var bar_cy: float = _dm_size.y * 0.5 - bar_h * 0.5   # 贴底（center_offset.y 正=向下）
	return {
		"name": DEVICE_MANAGER_TYPE,
		"width": _dm_size.x, "height": _dm_size.y,
		"display_layer": 0,
		"collision_layer": BlockLayers.icon_boundary_layers(),
		"border_width": 3.0,
		"border_color": DEVICE_MANAGER_BORDER,
		"fill_color": DEVICE_MANAGER_FILL,
		"fill_path": "res://textures/apps/server.png", "fill_mode": 0, "fill_anim": 0,
		"rotation_deg": 0.0,
		"text_boxes": [
			{
				"name": "底部栏",
				"width": _dm_size.x,
				"height": bar_h,
				"cx": 0.0,
				"cy": bar_cy,
				"border_color": "#00000000",
				"fill_color": "#00000000",
				"fill_source": 0,
				"fill_image_path": "",
				"rotation_deg": 0.0,
				"follow_block_rotation": false,
				"text_def": "(C)[设备管理]",
				"text_defs": {
					"zh_CN": "(C)[设备管理]",
					"zh_TW": "(C)[裝置管理]",
					"en": "(C)[Device management]",
					"ja": "(C)[デバイス管理]",
					"ru": "(C)[Управление устройствами]",
					"ko": "(C)[장치 관리]",
					"es": "(C)[Gestión de dispositivos]",
					"pt": "(C)[Gerenciamento de dispositivos]",
					"fr": "(C)[Gestion des appareils]",
					"de": "(C)[Geräteverwaltung]",
					"it": "(C)[Gestione dispositivi]",
					"tr": "(C)[Cihaz yönetimi]",
					"pl": "(C)[Zarządzanie urządzeniami]",
					"th": "(C)[การจัดการอุปกรณ์]",
					"vi": "(C)[Quản lý thiết bị]",
				},
				"hide_when_empty": false,
			}
		],
		"parent_id": 0, "child_ids": [],
		"tags": PackedStringArray([BlockTags.SHOW, BlockTags.FILL,
			BlockTags.COLLISION, BlockTags.TEXT, BlockTags.DRAGGABLE, BlockTags.DESKTOP_ICON,
			BlockTags.button_tag(DEVICE_MANAGER_OPEN_SIGNAL), BlockTags.SELECTABLE, BlockTags.FILL_IMAGE]),
	}


# 在桌面放置一个「设备管理」实例（启动即可见、可拖动、双击开设备管理页）
func _spawn_device_manager_block(pos: Vector2 = Vector2.ZERO) -> void:
	if BlockManager.get_block_by_string_id(DEVICE_MANAGER_SID) != null:
		_dm_spawned = true
		return   # 已有实例，不重复生成
	var b := BlockTypes.create_block(DEVICE_MANAGER_TYPE)
	if b == null:
		push_warning("[desktop] 设备管理类型尚未注册，无法放置实例")
		return
	var rect := DesktopShell.get_desktop_rect_f()
	var p := pos
	if p == Vector2.ZERO:
		p = Vector2(rect.position.x + rect.size.x * 0.5 - 100.0, rect.position.y + 140.0)
	b.global_position = p
	add_child(b)
	BlockManager.set_string_id(b, DEVICE_MANAGER_SID)
	_dm_spawned = true
	print("[desktop] 已放置设备管理积木 id=%d pos=%s tags=%s" % [b.id, str(p), str(b.tags)])


# 首轮窗口枚举后调用：若实例尚未生成，挑一个「不被任何窗口 / 虚视跳转器 / 回收站 / 此电脑覆盖」的
# 空白点放置。
func _ensure_device_manager_spawned(windows: Variant) -> void:
	if _dm_spawned:
		return
	if BlockManager.get_block_by_string_id(DEVICE_MANAGER_SID) != null:
		_dm_spawned = true
		return
	var wins: Array = windows if windows is Array else []
	var rect := DesktopShell.get_desktop_rect_f()
	var search: Array = []
	search.append_array(wins)
	for r in _icon_boxes:
		search.append({"x": r.position.x, "y": r.position.y, "w": r.size.x, "h": r.size.y})
	var vj_w := _block_as_window(BlockManager.get_block_by_string_id(VIRTUAL_JUMP_SID))
	if not vj_w.is_empty():
		search.append(vj_w)
	var rb_w := _block_as_window(BlockManager.get_block_by_string_id(RECYCLE_BIN_SID))
	if not rb_w.is_empty():
		search.append(rb_w)
	var pc_w := _block_as_window(BlockManager.get_block_by_string_id(THIS_PC_SID))
	if not pc_w.is_empty():
		search.append(pc_w)
	var pos := _find_free_spot(search, rect, _dm_size)
	_spawn_device_manager_block(pos)
	if BlockManager.get_block_by_string_id(DEVICE_MANAGER_SID) != null:
		_resize_device_manager_block(_dm_size)


func _resize_device_manager_block(box: Vector2) -> void:
	_resize_auto_block(DEVICE_MANAGER_SID, box)


# ============================ 「扫描重构器」积木（批次 16）============================
# 与「设备管理」完全同构：只改 类型名 / 配色 / 底部栏文字 / 双击信号。

# 「扫描重构器」类型注册（落 JSON，与设备管理同款）
func _register_scan_reconfigure_type() -> void:
	BlockTypes.ensure_builtin_type(SCAN_RECONFIGURE_TYPE, _scan_reconfigure_def())
	print("[desktop] 确保扫描重构器类型（尺寸=%s）" % str(_sr_size))


# 「扫描重构器」类型定义 —— 照抄 _device_manager_def()，只改三处：
#   colors  → 扫描重构器自己的配色（琥珀紫）
#   底部栏文字 → 「扫描重构器」
#   tags    → 双击信号换成 open_scan_reconfigure（双击 → 打开「扫描重构」页）
func _scan_reconfigure_def() -> Dictionary:
	var s := _sr_size.x
	var bar_h: float = maxf(22.0, s * 0.34)
	var bar_cy: float = _sr_size.y * 0.5 - bar_h * 0.5   # 贴底（center_offset.y 正=向下）
	return {
		"name": SCAN_RECONFIGURE_TYPE,
		"width": _sr_size.x, "height": _sr_size.y,
		"display_layer": 0,
		"collision_layer": BlockLayers.icon_boundary_layers(),
		"border_width": 3.0,
		"border_color": SCAN_RECONFIGURE_BORDER,
		"fill_color": SCAN_RECONFIGURE_FILL,
		"fill_path": "res://textures/apps/microscope.png", "fill_mode": 0, "fill_anim": 0,
		"rotation_deg": 0.0,
		"text_boxes": [
			{
				"name": "底部栏",
				"width": _sr_size.x,
				"height": bar_h,
				"cx": 0.0,
				"cy": bar_cy,
				"border_color": "#00000000",
				"fill_color": "#00000000",
				"fill_source": 0,
				"fill_image_path": "",
				"rotation_deg": 0.0,
				"follow_block_rotation": false,
				"text_def": "(C)[扫描重构器]",
				"text_defs": {
					"zh_CN": "(C)[扫描重构器]",
					"zh_TW": "(C)[掃描重構器]",
					"en": "(C)[Scan Restructurer]",
					"ja": "(C)[スキャン再構築器]",
					"ru": "(C)[Сканер-реструктуризатор]",
					"ko": "(C)[스캔 재구성기]",
					"es": "(C)[Reestructurador de escaneo]",
					"pt": "(C)[Reestruturador de varredura]",
					"fr": "(C)[Restructurateur de scan]",
					"de": "(C)[Scan-Restrukturierer]",
					"it": "(C)[Ristrutturatore di scansione]",
					"tr": "(C)[Tarama Yeniden Yapılandırıcı]",
					"pl": "(C)[Restrukturyzator skanowania]",
					"th": "(C)[ตัวปรับโครงสร้างการสแกน]",
					"vi": "(C)[Bộ tái cấu trúc quét]",
				},
				"hide_when_empty": false,
			}
		],
		"parent_id": 0, "child_ids": [],
		"tags": PackedStringArray([BlockTags.SHOW, BlockTags.FILL,
			BlockTags.COLLISION, BlockTags.TEXT, BlockTags.DRAGGABLE, BlockTags.DESKTOP_ICON,
			BlockTags.button_tag(SCAN_RECONFIGURE_OPEN_SIGNAL), BlockTags.SELECTABLE, BlockTags.FILL_IMAGE]),
	}


# 在桌面放置一个「扫描重构器」实例（启动即可见、可拖动、双击开扫描重构页）
func _spawn_scan_reconfigure_block(pos: Vector2 = Vector2.ZERO) -> void:
	if BlockManager.get_block_by_string_id(SCAN_RECONFIGURE_SID) != null:
		_sr_spawned = true
		return   # 已有实例，不重复生成
	var b := BlockTypes.create_block(SCAN_RECONFIGURE_TYPE)
	if b == null:
		push_warning("[desktop] 扫描重构器类型尚未注册，无法放置实例")
		return
	var rect := DesktopShell.get_desktop_rect_f()
	var p := pos
	if p == Vector2.ZERO:
		p = Vector2(rect.position.x + rect.size.x * 0.5 + 140.0, rect.position.y + 140.0)
	b.global_position = p
	add_child(b)
	BlockManager.set_string_id(b, SCAN_RECONFIGURE_SID)
	_sr_spawned = true
	print("[desktop] 已放置扫描重构器积木 id=%d pos=%s tags=%s" % [b.id, str(p), str(b.tags)])


# 首轮窗口枚举后调用：若实例尚未生成，挑一个「不被任何窗口 / 其它桌面图标覆盖」的空白点放置。
#   ★ 避让区 = 真实窗口 + 桌面图标选择框 + 虚视跳转器 / 回收站 / 此电脑 / 设备管理。
func _ensure_scan_reconfigure_spawned(windows: Variant) -> void:
	if _sr_spawned:
		return
	if BlockManager.get_block_by_string_id(SCAN_RECONFIGURE_SID) != null:
		_sr_spawned = true
		return
	var wins: Array = windows if windows is Array else []
	var rect := DesktopShell.get_desktop_rect_f()
	var search: Array = []
	search.append_array(wins)
	for r in _icon_boxes:
		search.append({"x": r.position.x, "y": r.position.y, "w": r.size.x, "h": r.size.y})
	for sid in [VIRTUAL_JUMP_SID, RECYCLE_BIN_SID, THIS_PC_SID, DEVICE_MANAGER_SID]:
		var w := _block_as_window(BlockManager.get_block_by_string_id(sid))
		if not w.is_empty():
			search.append(w)
	var pos := _find_free_spot(search, rect, _sr_size)
	_spawn_scan_reconfigure_block(pos)
	if BlockManager.get_block_by_string_id(SCAN_RECONFIGURE_SID) != null:
		_resize_scan_reconfigure_block(_sr_size)


func _resize_scan_reconfigure_block(box: Vector2) -> void:
	_resize_auto_block(SCAN_RECONFIGURE_SID, box)


# ============================ 「日历」积木（批次 52）============================
# 与「扫描重构器」完全同构：只改 类型名 / 配色 / 底部栏文字 / 双击信号。

# 「日历」类型注册（落 JSON，与扫描重构器同款）
func _register_calendar_type() -> void:
	BlockTypes.ensure_builtin_type(CALENDAR_TYPE, _calendar_def())
	print("[desktop] 确保日历类型（尺寸=%s）" % str(_cal_size))


# 「日历」类型定义 —— 照抄 _scan_reconfigure_def()，只改三处：
#   colors  → 日历自己的配色（暖红）
#   底部栏文字 → 「日历」
#   tags    → 双击信号换成 open_calendar（双击 → 打开「日历/日记/备忘录」页面）
func _calendar_def() -> Dictionary:
	var s := _cal_size.x
	var bar_h: float = maxf(22.0, s * 0.34)
	var bar_cy: float = _cal_size.y * 0.5 - bar_h * 0.5   # 贴底（center_offset.y 正=向下）
	return {
		"name": CALENDAR_TYPE,
		"width": _cal_size.x, "height": _cal_size.y,
		"display_layer": 0,
		"collision_layer": BlockLayers.icon_boundary_layers(),
		"border_width": 3.0,
		"border_color": CALENDAR_BORDER,
		"fill_color": CALENDAR_FILL,
		"fill_path": "res://textures/apps/empty_calendar_icon.png", "fill_mode": 0, "fill_anim": 0,
		"rotation_deg": 0.0,
		"text_boxes": [
			{
				"name": "底部栏",
				"width": _cal_size.x,
				"height": bar_h,
				"cx": 0.0,
				"cy": bar_cy,
				"border_color": "#00000000",
				"fill_color": "#00000000",
				"fill_source": 0,
				"fill_image_path": "",
				"rotation_deg": 0.0,
				"follow_block_rotation": false,
				"text_def": "(C)[日历]",
				"text_defs": {
					"zh_CN": "(C)[日历]",
					"zh_TW": "(C)[行事曆]",
					"en": "(C)[Calendar]",
					"ja": "(C)[カレンダー]",
					"ru": "(C)[Календарь]",
					"ko": "(C)[달력]",
					"es": "(C)[Calendario]",
					"pt": "(C)[Calendário]",
					"fr": "(C)[Calendrier]",
					"de": "(C)[Kalender]",
					"it": "(C)[Calendario]",
					"tr": "(C)[Takvim]",
					"pl": "(C)[Kalendarz]",
					"th": "(C)[ปฏิทิน]",
					"vi": "(C)[Lịch]",
				},
				"hide_when_empty": false,
			}
		],
		"parent_id": 0, "child_ids": [],
		"tags": PackedStringArray([BlockTags.SHOW, BlockTags.FILL,
			BlockTags.COLLISION, BlockTags.TEXT, BlockTags.DRAGGABLE, BlockTags.DESKTOP_ICON,
			BlockTags.button_tag(CALENDAR_OPEN_SIGNAL), BlockTags.SELECTABLE, BlockTags.FILL_IMAGE]),
	}


# 在桌面放置一个「日历」实例（启动即可见、可拖动、双击开日历页面）
func _spawn_calendar_block(pos: Vector2 = Vector2.ZERO) -> void:
	if BlockManager.get_block_by_string_id(CALENDAR_SID) != null:
		_cal_spawned = true
		return   # 已有实例，不重复生成
	var b := BlockTypes.create_block(CALENDAR_TYPE)
	if b == null:
		push_warning("[desktop] 日历类型尚未注册，无法放置实例")
		return
	var rect := DesktopShell.get_desktop_rect_f()
	var p := pos
	if p == Vector2.ZERO:
		p = Vector2(rect.position.x + rect.size.x * 0.5 + 180.0, rect.position.y + 140.0)
	b.global_position = p
	add_child(b)
	BlockManager.set_string_id(b, CALENDAR_SID)
	_cal_spawned = true
	print("[desktop] 已放置日历积木 id=%d pos=%s tags=%s" % [b.id, str(p), str(b.tags)])


# 首轮窗口枚举后调用：若实例尚未生成，挑一个「不被任何窗口 / 其它桌面图标覆盖」的空白点放置。
#   ★ 避让区 = 真实窗口 + 桌面图标选择框 + 虚视跳转器 / 回收站 / 此电脑 / 设备管理 / 扫描重构器。
func _ensure_calendar_spawned(windows: Variant) -> void:
	if _cal_spawned:
		return
	if BlockManager.get_block_by_string_id(CALENDAR_SID) != null:
		_cal_spawned = true
		return
	var wins: Array = windows if windows is Array else []
	var rect := DesktopShell.get_desktop_rect_f()
	var search: Array = []
	search.append_array(wins)
	for r in _icon_boxes:
		search.append({"x": r.position.x, "y": r.position.y, "w": r.size.x, "h": r.size.y})
	for sid in [VIRTUAL_JUMP_SID, RECYCLE_BIN_SID, THIS_PC_SID, DEVICE_MANAGER_SID, SCAN_RECONFIGURE_SID]:
		var w := _block_as_window(BlockManager.get_block_by_string_id(sid))
		if not w.is_empty():
			search.append(w)
	var pos := _find_free_spot(search, rect, _cal_size)
	_spawn_calendar_block(pos)
	if BlockManager.get_block_by_string_id(CALENDAR_SID) != null:
		_resize_calendar_block(_cal_size)


func _resize_calendar_block(box: Vector2) -> void:
	_resize_auto_block(CALENDAR_SID, box)


# ───────────────────────── 课程表积木（批次 111，与日历同构） ─────────────────────────

func _register_course_schedule_type() -> void:
	BlockTypes.ensure_builtin_type(COURSE_SCHEDULE_TYPE, _course_schedule_def())
	print("[desktop] 确保课程表类型（尺寸=%s）" % str(_cs_size))


func _course_schedule_def() -> Dictionary:
	var s := _cs_size.x
	var bar_h: float = maxf(22.0, s * 0.34)
	var bar_cy: float = _cs_size.y * 0.5 - bar_h * 0.5
	return {
		"name": COURSE_SCHEDULE_TYPE,
		"width": _cs_size.x, "height": _cs_size.y,
		"display_layer": 0,
		"collision_layer": BlockLayers.icon_boundary_layers(),
		"border_width": 3.0,
		"border_color": COURSE_SCHEDULE_BORDER,
		"fill_color": COURSE_SCHEDULE_FILL,
		"fill_path": "res://textures/apps/timetable.png", "fill_mode": 0, "fill_anim": 0,
		"rotation_deg": 0.0,
		"text_boxes": [
			{
				"name": "底部栏",
				"width": _cs_size.x,
				"height": bar_h,
				"cx": 0.0,
				"cy": bar_cy,
				"border_color": "#00000000",
				"fill_color": "#00000000",
				"fill_source": 0,
				"fill_image_path": "",
				"rotation_deg": 0.0,
				"follow_block_rotation": false,
				"text_def": "(C)[课程表]",
				"text_defs": {
					"zh_CN": "(C)[课程表]",
					"zh_TW": "(C)[課表]",
					"en": "(C)[Timetable]",
					"ja": "(C)[時間割]",
					"ru": "(C)[Расписание]",
					"ko": "(C)[시간표]",
					"es": "(C)[Horario]",
					"pt": "(C)[Horário]",
					"fr": "(C)[Emploi du temps]",
					"de": "(C)[Stundenplan]",
					"it": "(C)[Orario]",
					"tr": "(C)[Ders programı]",
					"pl": "(C)[Plan lekcji]",
					"th": "(C)[ตารางเรียน]",
					"vi": "(C)[Thời khóa biểu]",
				},
				"hide_when_empty": false,
			}
		],
		"parent_id": 0, "child_ids": [],
		"tags": PackedStringArray([BlockTags.SHOW, BlockTags.FILL,
			BlockTags.COLLISION, BlockTags.TEXT, BlockTags.DRAGGABLE, BlockTags.DESKTOP_ICON,
			BlockTags.button_tag(COURSE_SCHEDULE_OPEN_SIGNAL), BlockTags.SELECTABLE, BlockTags.FILL_IMAGE]),
	}


func _spawn_course_schedule_block(pos: Vector2 = Vector2.ZERO) -> void:
	if BlockManager.get_block_by_string_id(COURSE_SCHEDULE_SID) != null:
		_cs_spawned = true
		return
	var b := BlockTypes.create_block(COURSE_SCHEDULE_TYPE)
	if b == null:
		push_warning("[desktop] 课程表类型尚未注册，无法放置实例")
		return
	var rect := DesktopShell.get_desktop_rect_f()
	var p := pos
	if p == Vector2.ZERO:
		p = Vector2(rect.position.x + rect.size.x * 0.5 + 240.0, rect.position.y + 140.0)
	b.global_position = p
	add_child(b)
	BlockManager.set_string_id(b, COURSE_SCHEDULE_SID)
	_cs_spawned = true
	print("[desktop] 已放置课程表积木 id=%d pos=%s tags=%s" % [b.id, str(p), str(b.tags)])


func _ensure_course_schedule_spawned(windows: Variant) -> void:
	if _cs_spawned:
		return
	if BlockManager.get_block_by_string_id(COURSE_SCHEDULE_SID) != null:
		_cs_spawned = true
		return
	var wins: Array = windows if windows is Array else []
	var rect := DesktopShell.get_desktop_rect_f()
	var search: Array = []
	search.append_array(wins)
	for r in _icon_boxes:
		search.append({"x": r.position.x, "y": r.position.y, "w": r.size.x, "h": r.size.y})
	for sid in [VIRTUAL_JUMP_SID, RECYCLE_BIN_SID, THIS_PC_SID, DEVICE_MANAGER_SID, SCAN_RECONFIGURE_SID, CALENDAR_SID]:
		var w := _block_as_window(BlockManager.get_block_by_string_id(sid))
		if not w.is_empty():
			search.append(w)
	var pos := _find_free_spot(search, rect, _cs_size)
	_spawn_course_schedule_block(pos)
	if BlockManager.get_block_by_string_id(COURSE_SCHEDULE_SID) != null:
		_resize_course_schedule_block(_cs_size)


func _resize_course_schedule_block(box: Vector2) -> void:
	_resize_auto_block(COURSE_SCHEDULE_SID, box)


# 在桌面放置一个「回收站」实例（启动即可见、可拖动；中心点进入它的积木会获得 detected_recycle_bin）
# ★ 用固定字符串 ID 去重：读档恢复等情况已存在该实例时不再重复生成。
#   pos 省略时用默认点（桌面顶部居中偏右，避开虚视跳转器的默认点）。
func _spawn_recycle_bin_block(pos: Vector2 = Vector2.ZERO) -> void:
	if BlockManager.get_block_by_string_id(RECYCLE_BIN_SID) != null:
		_rb_spawned = true
		return   # 已有实例，不重复生成
	var b := BlockTypes.create_block(RECYCLE_BIN_TYPE)
	if b == null:
		push_warning("[desktop] 回收站类型尚未注册，无法放置实例")
		return
	var rect := DesktopShell.get_desktop_rect_f()
	var p := pos
	if p == Vector2.ZERO:
		p = Vector2(rect.position.x + rect.size.x * 0.5 + 160.0, rect.position.y + 140.0)
	b.global_position = p
	add_child(b)
	BlockManager.set_string_id(b, RECYCLE_BIN_SID)
	_rb_spawned = true
	print("[desktop] 已放置回收站积木 id=%d pos=%s tags=%s layer=%s"
		% [b.id, str(p), str(b.tags), str(b.collision_layer)])


# 首轮窗口枚举后调用：若回收站实例尚未生成，挑一个「不被任何窗口 / 不被虚视跳转器覆盖」的
# 空白点放置。与 _ensure_virtual_jump_spawned 同构，唯一的差别就是多了"避开虚视跳转器"。
func _ensure_recycle_bin_spawned(windows: Variant) -> void:
	if _rb_spawned:
		return
	var existing := BlockManager.get_block_by_string_id(RECYCLE_BIN_SID)
	if existing != null:
		_rb_spawned = true
		# ★ 旧存档实例可能是在「双击打开背包并仅勾选在回收站中」按钮标签加入之前写盘的，
		#   直接复用会丢失该 button_ 标签 → 双击无反应。这里兜底：确保按钮标签存在（已在则不动）。
		var bt := BlockTags.button_tag(INVENTORY_RECYCLE_SIGNAL)
		if not (bt in existing.tags):
			existing.tags.append(bt)
			print("[desktop] 回收站实例补上按钮标签 %s（来自改前存档）" % bt)
		return
	var wins: Array = windows if windows is Array else []
	var rect := DesktopShell.get_desktop_rect_f()
	# ★ 避让区 = 真实窗口 + 桌面图标选择框 + 已就位的虚视跳转器。
	#   三者都写成"窗口形状"的字典，复用 _find_free_spot 的同一套评分（"被最少东西覆盖"），
	#   不必为"避开另一块积木 / 图标"再造第二套几何。
	#   · 必须避开**虚视跳转器**：两者候选落点算法同源，不避让就会叠在一起。
	#   · 必须避开**桌面图标**：图标的选择框被那四条边界墙围住，回收站落进去就被"围死"——
	#     除拖动外（拖动会临时切到 dragging 层）重力 / 受控 / 命令移动全都进不来，
	#     而"能被走进来"正是检测区（to_detect_*）的存在意义；同时那四条墙会落在回收站
	#     范围内被误判成"进入检测区"，给系统积木沾上 detected_recycle_bin。
	#     （虚视跳转器是"按钮"、不需要被进入，所以它沿用旧的落点算法不变。）
	var search: Array = []
	search.append_array(wins)
	for r in _icon_boxes:
		search.append({"x": r.position.x, "y": r.position.y, "w": r.size.x, "h": r.size.y})
	var vj_w := _block_as_window(BlockManager.get_block_by_string_id(VIRTUAL_JUMP_SID))
	if not vj_w.is_empty():
		search.append(vj_w)
	var pos := _find_free_spot(search, rect, _rb_size)
	_spawn_recycle_bin_block(pos)
	# ★ 生成走的是 JSON 落盘尺寸（可能是首次注册时的 48×48 兜底值），而本轮
	#   _sync_icon_boundaries 先于本函数执行、对齐时实例尚不存在被 no-op 掉，
	#   故生成后立即按当前图标盒子（_rb_size）强制对齐一次，保证尺寸=选择框。
	if BlockManager.get_block_by_string_id(RECYCLE_BIN_SID) != null:
		_resize_recycle_bin_block(_rb_size)
	var rb := BlockManager.get_block_by_string_id(RECYCLE_BIN_SID)
	if rb != null:
		# 注意：这里传 wins（真实窗口）而不是 search —— 调试文件里的 cover_count /
		# covered_by 只该反映"被真实窗口挡住"，把虚视跳转器写进去会让人误以为它是窗口。
		_dump_spawn_debug(rb, wins, rect, "spawn rb", "rb_debug.txt")


# 在桌面放置一个「虚视跳转器」实例（启动即可见、可拖动、双击开暗网入口）
# ★ 用固定字符串 ID 去重：读档恢复等情况已存在该实例时不再重复生成。
#   pos 省略时用默认点（桌面顶部居中）；由 _ensure_virtual_jump_spawned 传「避开窗口」的空白点。
func _spawn_virtual_jump_block(pos: Vector2 = Vector2.ZERO) -> void:
	if BlockManager.get_block_by_string_id(VIRTUAL_JUMP_SID) != null:
		_vj_spawned = true
		return   # 已有实例，不重复生成
	var b := BlockTypes.create_block(VIRTUAL_JUMP_TYPE)
	if b == null:
		push_warning("[desktop] 虚视跳转器类型尚未注册，无法放置实例")
		return
	var rect := DesktopShell.get_desktop_rect_f()
	var p := pos
	if p == Vector2.ZERO:
		p = Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y + 140.0)
	b.global_position = p
	add_child(b)
	BlockManager.set_string_id(b, VIRTUAL_JUMP_SID)
	_vj_spawned = true
	print("[desktop] 已放置虚视跳转器积木 id=%d pos=%s" % [b.id, str(p)])


# 首轮窗口枚举后调用：若实例尚未生成，挑一个「不被任何窗口覆盖」的空白点放置，
# 使其默认常驻（伪装成桌面文件）。之后若有真实窗口移到它上面，仍会被页面覆盖的
# cutout 洞正确穿透盖住（符合「被真实窗口盖住」语义）。
func _ensure_virtual_jump_spawned(windows: Variant) -> void:
	if _vj_spawned:
		return
	if BlockManager.get_block_by_string_id(VIRTUAL_JUMP_SID) != null:
		_vj_spawned = true
		return
	var wins: Array = windows if windows is Array else []
	var rect := DesktopShell.get_desktop_rect_f()
	var pos := _find_free_spot(wins, rect, _vj_size)
	_spawn_virtual_jump_block(pos)
	# ★ 生成走的是 JSON 落盘尺寸（可能是首次注册时的 48×48 兜底值），而本轮
	#   _sync_icon_boundaries 先于本函数执行、对齐时实例尚不存在被 no-op 掉，
	#   故生成后立即按当前图标盒子（_vj_size）强制对齐一次，保证尺寸=选择框。
	if BlockManager.get_block_by_string_id(VIRTUAL_JUMP_SID) != null:
		_resize_virtual_jump_block(_vj_size)
	var vj := BlockManager.get_block_by_string_id(VIRTUAL_JUMP_SID)
	if vj != null:
		var cover := _count_windows_overlapping(pos, Vector2(vj.width, vj.height), wins)
		_dump_spawn_debug(vj, wins, rect, "spawn cover=%d" % cover, "vj_debug.txt")


# 在桌面矩形内扫描一个落点（中心坐标）。
# 优先选「完全不被窗口覆盖」的格子（贴近默认点顶部居中）；若整屏被窗口盖满
# （真实桌面文件此时也会看不见），则退而求其次选「被最少窗口覆盖」的格子 ——
# 受页面覆盖 cutout 洞穿透最少、最可见，仍尽量靠近默认点。
func _find_free_spot(windows: Array, rect: Rect2, size: Vector2) -> Vector2:
	var margin := 32.0
	var gap := 24.0
	var preferred := Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y + 140.0)
	var step := Vector2(size.x + gap, size.y + gap)
	var cols := maxi(1, int((rect.size.x - margin * 2.0) / step.x))
	var rows := maxi(1, int((rect.size.y - margin * 2.0) / step.y))
	var best := preferred
	var best_d := INF
	var best_cover := INF
	for r in rows:
		for c in cols:
			var center := Vector2(
				rect.position.x + margin + step.x * 0.5 + c * step.x,
				rect.position.y + margin + step.y * 0.5 + r * step.y)
			var cover := _count_windows_overlapping(center, size, windows)
			var d := center.distance_to(preferred)
			if cover < best_cover or (cover == best_cover and d < best_d):
				best_cover = cover
				best_d = d
				best = center
	return best


# 统计某落点（中心）与多少个窗口矩形相交（窗口外扩 6px，避免贴边）。0 = 完全空白。
func _count_windows_overlapping(center: Vector2, size: Vector2, windows: Array) -> int:
	var box := Rect2(center - size * 0.5, size)
	var m := 6.0
	var n := 0
	for w in windows:
		if not (w is Dictionary):
			continue
		var ww := float(w.get("w", 0.0))
		var wh := float(w.get("h", 0.0))
		if ww <= 0.0 or wh <= 0.0:
			continue
		var wr := Rect2(float(w.get("x", 0.0)) - m, float(w.get("y", 0.0)) - m,
			ww + m * 2.0, wh + m * 2.0)
		if box.intersects(wr):
			n += 1
	return n


# 把一块已放置的积木包成「窗口」形状的字典（{x,y,w,h}，左上角 + 宽高），
# 供 _find_free_spot / _count_windows_overlapping 统一避让 —— 这样"挑空白点"只需一套几何，
# 不必为"避开另一块积木"再造第二套评分。无效积木返回空字典（调用方判 is_empty 后再 append）。
func _block_as_window(b: Variant) -> Dictionary:
	if b == null or not is_instance_valid(b) or not (b is Block):
		return {}
	var blk: Block = b
	return {
		"x": blk.global_position.x - blk.width * 0.5,
		"y": blk.global_position.y - blk.height * 0.5,
		"w": blk.width, "h": blk.height,
	}


# 把「自动放置的常驻积木」（虚视跳转器 / 回收站）的最终状态（位置/尺寸/被多少窗口覆盖/
# 桌面矩形/窗口数）落盘到 Temp/<file_name>，便于「看不到它」时定位根因
# （结合 force_border 覆盖层看它是否被窗口盖住）。
func _dump_spawn_debug(block: Block, wins: Array, rect: Rect2, note: String,
		file_name: String = "vj_debug.txt") -> void:
	if block == null:
		return
	var dir := SaveManager.get_temp_dir() if SaveManager != null and SaveManager.has_method("get_temp_dir") else "D:/Documents/HelloNyxel/Temp"
	var path := dir.path_join(file_name) if typeof(dir) == TYPE_STRING else "D:/Documents/HelloNyxel/Temp/" + file_name
	var lines := PackedStringArray()
	lines.append("note=%s" % note)
	lines.append("pos=%s size=%s display_layer=%s id=%d tags=%s layer=%s" % [
		str(block.global_position), str(Vector2(block.width, block.height)),
		str(block.display_layer), block.id, str(block.tags), str(block.collision_layer)])
	lines.append("desktop_rect=%s window_count=%d" % [str(rect), wins.size()])
	lines.append("cover_count=%d" % _count_windows_overlapping(block.global_position, Vector2(block.width, block.height), wins))
	# 覆盖窗口明细：逐个列出与之相交的窗口（标题/类名/矩形/z 序），直接回答「是什么挡住了它」。
	var box := Rect2(block.global_position - Vector2(block.width, block.height) * 0.5, Vector2(block.width, block.height))
	for w in wins:
		if not (w is Dictionary):
			continue
		var wr := Rect2(Vector2(float(w.get("x", 0.0)), float(w.get("y", 0.0))),
			Vector2(float(w.get("w", 0.0)), float(w.get("h", 0.0))))
		if box.intersects(wr):
			lines.append("covered_by z=%s cls=%s title=%s rect=%s" % [
				str(w.get("z", "")), str(w.get("cls", "")), str(w.get("title", "")), str(wr)])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines))
		f.close()


# 把「自动放置的常驻积木」的尺寸对齐到图标选择框盒子（围住图标四边的空间），
# 并让底部栏文本框随块宽拉伸、保持贴底居中。仅改运行期实例（JSON 类型以 icons 枚举后的
# _vj_size / _rb_size 为准，保存时落盘；此处保证已存在的常驻实例即时对齐）。
# ★ 用固定字符串 ID 定位实例 —— 虚视跳转器与回收站的结构完全同构（都是 48×48 起、
#   底部一条「底部栏」文本框），故共用这一套几何，避免两份逐字重复的代码各自漂移。
func _resize_auto_block(sid: String, box: Vector2) -> void:
	var b := BlockManager.get_block_by_string_id(sid)
	if b == null:
		return
	b.width = box.x
	b.height = box.y
	var tbs := b.text_boxes
	for tb in tbs:
		if tb != null and tb.name == "底部栏":
			tb.width = box.x
			tb.center_offset = Vector2(0.0, box.y * 0.5 - tb.height * 0.5)
	b.text_boxes = tbs   # 触发 rebuild_text_boxes() → 文本框视图按新尺寸重建
	print("[desktop] %s 尺寸已对齐图标盒子: %s" % [sid, str(box)])


func _resize_virtual_jump_block(box: Vector2) -> void:
	_resize_auto_block(VIRTUAL_JUMP_SID, box)


func _resize_recycle_bin_block(box: Vector2) -> void:
	_resize_auto_block(RECYCLE_BIN_SID, box)


# 任意积木双击发出的按钮信号都汇到这里，按信号名分派到对应功能
func _on_block_button_signal(signal_name: String) -> void:
	if signal_name == LEVEL_OPEN_SIGNAL:
		_on_level_page_button()
	elif signal_name == INVENTORY_OPEN_SIGNAL:
		open_inventory()
	elif signal_name == INVENTORY_RECYCLE_SIGNAL:
		open_inventory_recycle()
	elif signal_name == DEVICE_MANAGER_OPEN_SIGNAL:
		open_device_manager()
	elif signal_name == SCAN_RECONFIGURE_OPEN_SIGNAL:
		open_scan_reconfigure()
	elif signal_name == CALENDAR_OPEN_SIGNAL:
		open_calendar()
	elif signal_name == COURSE_SCHEDULE_OPEN_SIGNAL:
		open_course_schedule()
	elif signal_name == VIRTUAL_JUMP_BTN_SIGNAL:
		_open_darknet_entry()


# 在默认浏览器打开「暗网入口」本地 HTML 页（res://html/darknet_entry.html）
func _open_darknet_entry() -> void:
	var html_path: String = ProjectSettings.globalize_path("res://html/darknet_entry.html")
	if FileAccess.file_exists(html_path):
		OS.shell_open(html_path)
		print("[desktop] 已打开暗网入口 HTML: %s" % html_path)
	else:
		printerr("[desktop] 暗网入口 HTML 未找到: %s" % html_path)


# 关卡页面开关：由带 button_打开桌面副本 标签的积木双击发出（经 SignalBus 汇流）
func _on_level_page_button() -> void:
	if _level_page != null and is_instance_valid(_level_page):
		_level_page.toggle_page_visible()


# 「关卡页面开关」的统一入口（预留接口）：
# 现在由调试面板调用；未来其它方式（事件链 / 快捷键 / 其它积木信号）也汇到这里切换显隐。
func toggle_level_page() -> void:
	if _level_page != null and is_instance_valid(_level_page):
		_level_page.toggle_page_visible()


# 关卡页面当前是否可见（调试面板显示状态用）
func level_page_is_visible() -> bool:
	return _level_page != null and is_instance_valid(_level_page) and _level_page.is_page_visible()


# 世界页面开关（调试面板「世界页面」按钮的统一入口）
func toggle_world_page() -> void:
	if _world_page != null and is_instance_valid(_world_page):
		_world_page.toggle_page_visible()


# 世界页面当前是否可见（调试面板显示状态用）
func world_page_is_visible() -> bool:
	return _world_page != null and is_instance_valid(_world_page) and _world_page.is_page_visible()


# 托盘二级菜单「打开设置」→ 打开设置页面
func _open_settings() -> void:
	if settings_panel != null and is_instance_valid(settings_panel) and not settings_panel.is_open():
		settings_panel.open()
		print("[desktop] 打开设置页面")


# 托盘二级菜单「打开存档列表」→ 打开存档列表页面
func open_saves_list() -> void:
	if saves_panel != null and is_instance_valid(saves_panel) and not saves_panel.is_open():
		saves_panel.open()
		print("[desktop] 打开存档列表页面")


# 托盘右键菜单「性能忙闲判断」→ 打开性能忙闲判断面板
# ★ 这是该面板**唯一**的打开入口（调试面板上的按钮已于 2026-09-30 移除）。
func _open_perf_busy() -> void:
	if Debug != null and Debug.has_method("_toggle_perf_busy"):
		Debug._toggle_perf_busy()
		print("[desktop] 打开性能忙闲判断面板")


# 托盘右键菜单「配置天气」→ 打开配置天气占位页面（业务预留，暂无功能）
func _open_weather_config() -> void:
	if weather_panel != null and is_instance_valid(weather_panel) and not weather_panel.is_open():
		weather_panel.open()
		print("[desktop] 打开配置天气页面")


# 托盘右键菜单「配置人工智能」→ 打开配置人工智能占位页面（业务预留，暂无功能）
func _open_ai_config() -> void:
	if ai_panel != null and is_instance_valid(ai_panel) and not ai_panel.is_open():
		ai_panel.open()
		print("[desktop] 打开配置人工智能页面")


# 托盘右键菜单「打开MOD列表」→ 打开MOD列表占位页（仅容器，业务未接入）
func _open_mod_list() -> void:
	if mod_list_panel != null and is_instance_valid(mod_list_panel) and not mod_list_panel.is_open():
		mod_list_panel.open()
		print("[desktop] 打开MOD列表页面")


# 托盘右键菜单「打开日历」→ 打开日历/日记/备忘录单页
func _open_calendar() -> void:
	if calendar_panel != null and is_instance_valid(calendar_panel) and not calendar_panel.is_open():
		calendar_panel.open()
		print("[desktop] 打开日历页面")


# 托盘右键菜单「版本」→ 打开版本显示 + 更新公告面板
func _open_version_announcement() -> void:
	if version_panel != null and is_instance_valid(version_panel) and not version_panel.is_open():
		version_panel.open()
		print("[desktop] 打开版本与更新公告")


# 「日历」积木双击 / 其它入口的统一公开入口（与托盘菜单同一路径）
func open_calendar() -> void:
	_open_calendar()


func calendar_is_open() -> bool:
	return calendar_panel != null and is_instance_valid(calendar_panel) and calendar_panel.is_open()


# 托盘右键菜单「课程表」→ 打开课程表面板
func _open_course_schedule() -> void:
	if course_schedule_panel != null and is_instance_valid(course_schedule_panel) and not course_schedule_panel.is_open():
		course_schedule_panel.open()
		print("[desktop] 打开课程表面板")


# 「课程表」积木双击 / 托盘菜单的统一公开入口
func open_course_schedule() -> void:
	_open_course_schedule()


func course_schedule_is_open() -> bool:
	return course_schedule_panel != null and is_instance_valid(course_schedule_panel) and course_schedule_panel.is_open()


func saves_list_is_open() -> bool:
	return saves_panel != null and is_instance_valid(saves_panel) and saves_panel.is_open()


# ============================ 背包 ============================

func toggle_inventory() -> void:
	if inventory_panel != null and is_instance_valid(inventory_panel):
		if inventory_panel.is_open():
			inventory_panel.close()
		else:
			inventory_panel.open()


func open_inventory() -> void:
	if inventory_panel != null and is_instance_valid(inventory_panel) and not inventory_panel.is_open():
		inventory_panel.open()


## 双击「回收站」积木入口：打开背包页面，并把种类筛选设为「仅勾选在回收站中」。
func open_inventory_recycle() -> void:
	if inventory_panel != null and is_instance_valid(inventory_panel):
		inventory_panel.open_recycle_only()


func close_inventory() -> void:
	if inventory_panel != null and is_instance_valid(inventory_panel):
		inventory_panel.close()


func inventory_is_open() -> bool:
	return inventory_panel != null and is_instance_valid(inventory_panel) and inventory_panel.is_open()


# ============================ 设备管理面板 ============================

func open_device_manager() -> void:
	if device_manager_panel != null and is_instance_valid(device_manager_panel) and not device_manager_panel.is_open():
		device_manager_panel.open()


func close_device_manager() -> void:
	if device_manager_panel != null and is_instance_valid(device_manager_panel):
		device_manager_panel.close()


func device_manager_is_open() -> bool:
	return device_manager_panel != null and is_instance_valid(device_manager_panel) and device_manager_panel.is_open()


# ---- 扫描重构页（双击「扫描重构器」积木打开；当前为骨架占位）----

func open_scan_reconfigure() -> void:
	if scan_reconfigure_panel != null and is_instance_valid(scan_reconfigure_panel) and not scan_reconfigure_panel.is_open():
		scan_reconfigure_panel.open()


func close_scan_reconfigure() -> void:
	if scan_reconfigure_panel != null and is_instance_valid(scan_reconfigure_panel):
		scan_reconfigure_panel.close()


func scan_reconfigure_is_open() -> bool:
	return scan_reconfigure_panel != null and is_instance_valid(scan_reconfigure_panel) and scan_reconfigure_panel.is_open()


## 背包物品拖出放置：物品需带「数字物品」标签，且含「构建」变量
## （`attrs.build = { type, mod }`，或旧式标签 `构建_XXX{修饰}`）。
## 在 drop_pos 处生成一个类型为 build.type 的积木（build.mod 作属性覆盖套在类型定义之上），
## 并把该物品数量 -1。
## ★★ 「构建」**只对数字物品生效** —— 门禁在 Inventory.build_info() 里只判一次；
##    即便调用方硬塞了 category/modifiers，这里也会重新按物品数据校验一遍。
## 返回 "OK" / "ERR_NOT_DIGITAL" / "ERR_NO_BUILD" / "ERR_NO_ITEM" / "ERR_NO_COUNT" /
##      "ERR_NO_CATEGORY" / "ERR_NO_TYPE"。
func place_inventory_item(item_id: String, category: String, modifiers: String, drop_pos: Vector2) -> String:
	var item: Dictionary = Inventory.get_item(item_id)
	if item.is_empty():
		return "ERR_NO_ITEM"
	if int(item.get("count", 0)) < 1:
		return "ERR_NO_COUNT"
	var info: Dictionary = Inventory.build_info(item)
	if not info.ok:
		print("[desktop] 物品 %s 不可构建（%s），未生成积木、数量不变" % [item_id, str(info.reason)])
		return "ERR_NOT_DIGITAL" if str(info.reason) == "not_digital" else "ERR_NO_BUILD"
	# 以**物品数据**为准（调用方传参与物品不一致时不影响最终结果）
	category = str(info.type)
	modifiers = str(info.modifiers)
	if category.is_empty():
		return "ERR_NO_CATEGORY"
	if not BlockTypes.has(category):
		push_warning("[desktop] 背包生成积木：未注册类别 '%s'（修饰:%s）" % [category, modifiers])
		return "ERR_NO_TYPE"
	var b := BlockTypes.create_block(category)
	if b == null:
		return "ERR_NO_TYPE"
	# 修饰串 = **属性覆盖**：create_block 已按类型定义设过一遍，这里在其上覆写
	# （apply_to_block 每个字段都带 has() 守卫，白名单见 Inventory.BUILD_MOD_KEYS）
	var mods: Dictionary = Inventory.parse_build_modifiers(modifiers)
	if not mods.is_empty():
		BlockProperty.apply_to_block(b, mods)
	# ★ drop_pos 来自背包面板的 `get_global_mouse_position()`，那是 **ui_layer 画布坐标**
	#   （含 UI 缩放）；而积木挂在**桌面世界**（默认画布 = 屏幕像素）→ 缩放 ≠ 1 必须换算。
	# ★ 积木的 `position` 就是**中心**（Block 是 Node2D，_draw 从 (-w/2,-h/2) 起画）→
	#   落点即中心，**不减 half**（旧写法减 half 会把积木整块推向左上）。
	var center: Vector2 = _to_screen(drop_pos)
	# ★ 归属与「右键新建积木」同一条约定：关卡页/家园页开着且落点在页面内 → 进对应页，否则进桌面。
	if not _place_into_open_level(b, center) and not _place_into_open_home(b, center):
		b.position = center
		add_child(b)
	Inventory.remove_item(item_id, 1)
	print("[desktop] 物品 %s → 生成积木[%s]（修饰:%s） 剩余数量=%d" % [
		item_id, category, modifiers, int(Inventory.get_item(item_id).get("count", 0))])
	return "OK"


## 把刚落地的积木交给「正在开着的关卡页」（落点在页面内时），返回是否已归入关卡。
## ★ 与 `_host_new_block` 同一条归属约定（`LevelManager.level_page` + `add_level_block`
##   做页面内判定），只是位置由调用方给出：`_host_new_block` 用右键那一刻的
##   `_last_mouse_pos`，背包拖放用拖放落点。
func _place_into_open_level(blk: Block, screen_center: Vector2) -> bool:
	if blk == null or blk.is_queued_for_deletion():
		return false
	var lp = LevelManager.level_page
	if lp == null or not is_instance_valid(lp) or not lp.has_method("add_level_block"):
		return false
	# add_level_block 收的是**页面画布坐标**（页面层自带 transform，见 desktop._to_page）
	if lp.add_level_block(blk, _to_page(screen_center)):
		return true
	return false


## 把关卡页的归属逻辑镜像到家园页：家园页开着且落点在页面内 → 进家园，否则交给调用方（桌面/关卡）。
func _place_into_open_home(blk: Block, screen_center: Vector2) -> bool:
	if blk == null or blk.is_queued_for_deletion():
		return false
	var hp = _home_page
	if hp == null or not is_instance_valid(hp) or not hp.has_method("add_home_block"):
		return false
	# add_home_block 同样收页面画布坐标（见 desktop._to_page）。
	if hp.add_home_block(blk, _to_page(screen_center)):
		return true
	return false


# ============ 桌面屏障 ============

# 生成屏障：先登记 BedRockX / BedRockY 两个内置类型的默认模板（仅内存），
# 再生成 4 块实例（尺寸与位置由 DesktopBarrier 按桌面矩形算出，不依赖 JSON 写盘）。
# 顺带生成任务栏上表面屏障。注：桌面图标边界 / 程序页面积木**不在这里**生成，
# 它们由「实时内存枚举」（_setup_scene_enum → _apply_scene_data）按最新几何维护。
func _setup_barriers() -> void:
	var rect := DesktopShell.get_desktop_rect_f()
	_register_barrier_types(rect)
	_barriers = DesktopBarrier.spawn_all(self, rect)
	var sids: Array[String] = []
	for role in _barriers.keys():
		var bb: Block = _barriers[role]
		if bb != null:
			sids.append(bb.string_id)
	print("[desktop] 桌面屏障已生成 %d 块（类型 %s / %s，字符串ID %s，桌面矩形 %s）"
		% [_barriers.size(), DesktopBarrier.TYPE_X, DesktopBarrier.TYPE_Y, str(sids), str(rect)])
	_setup_taskbar_barrier(rect)


# 系统自动生成的积木类型：确保「图标边界 / 页面边框 / 页面覆盖」三类落盘到 res://block_types/。
# 之后实时枚举（_apply_scene_data）生成这些积木时直接读 JSON —— 改 JSON 即改自动积木外观/标签/碰撞层。
# 几何（图标墙尺寸、覆盖层显示层）因随运行期数据变化，由各自生成逻辑在 JSON 之上覆写。
func _register_system_types() -> void:
	DesktopIconBoundary.ensure_type()
	WindowPage.ensure_types()
	print("[desktop] 已确保系统积木类型：图标边界 / 页面边框 / 页面覆盖（落 JSON）")


# 在任务栏上表面（或侧边内沿）生成一条 1px 屏障，防止积木落入任务栏。
# 数据来源：sysinfo.json 的 taskbar 段（SysInfo.cs 自动采集的 {"edge","height_px"}）。
func _setup_taskbar_barrier(rect: Rect2) -> void:
	# ★ 统一走 DesktopShell.get_taskbar_info()：**原生工作区优先**，sysinfo.json 只做兜底。
	#   旧写法直接读 DesktopShell.sysinfo["taskbar"]，在 sysinfo.json 没生成时恒为空字典
	#   → 任务栏屏障静默缺失（同一根因，见 DesktopShell.get_taskbar_thickness 注释）。
	var taskbar: Dictionary = DesktopShell.get_taskbar_info()
	_taskbar_barrier = DesktopBarrier.spawn_taskbar(self, rect, taskbar)
	if _taskbar_barrier != null:
		print("[desktop] 任务栏屏障已生成（edge=%s height_px=%s）" % [taskbar.get("edge"), taskbar.get("height_px")])
	else:
		print("[desktop] 未生成任务栏屏障（taskbar 信息不可用）: %s" % str(taskbar))


# 为每个桌面图标的「选中框」（LVIR_BOUNDS 整项矩形）四边生成碰撞墙（把图标围起来）。
# 数据来源：实时内存枚举（enumerate_scene.ps1 的 desktop_icons 段）。
# 用「签名」去重：几何没变就不重建整批（避免每轮枚举都销毁+重排导致闪烁）。
func _sync_icon_boundaries(di: Variant) -> void:
	# ★ 自测量（批次 1）：关闸时只多一次 bool 读
	if PerfMonitor.profiling:
		var t0 := Time.get_ticks_usec()
		_sync_icon_boundaries_impl(di)
		PerfMonitor.add_span("icon_walls", Time.get_ticks_usec() - t0)
		return
	_sync_icon_boundaries_impl(di)


func _sync_icon_boundaries_impl(di: Variant) -> void:
	# ★ 忙闲联动：「在忙」时整套图标边界积木系统停用 —— 不建墙、不重排；
	#   已存在的墙在切换那一刻就由 _apply_busy_pause() 收掉了。
	if _busy_paused:
		return
	if not (di is Dictionary):
		# 暂无图标数据：先清空旧墙（比如从有到无），但不清空是少见情况
		if not _icon_walls.is_empty():
			DesktopIconBoundary.destroy(_icon_walls)
			if MousePassRunner.is_enabled():
				MousePassRunner.force_refresh()
		return
	var items: Variant = di.get("items", null)
	var size: float = float(di.get("icon_size_px", 48))
	# ★ 图标尺寸变化**不再需要**同步「图标占位」类型：该类型宽高是系统常量名（icon_size），
	#   创建积木时由 SystemConst 现读 sysinfo.json 解析 —— 天然跟随桌面图标尺寸变化。
	# 图标网格间距：仅作 items 全缺 w/h 时的兜底尺寸（正常几何直接用各图标的整项矩形，
	# 统一按众数尺寸处理，见 DesktopIconBoundary._uniform_size）。无该字段时按图标尺寸×2 回退
	var spacing: float = float(di.get("icon_cell_spacing", 0))
	if spacing <= 0:
		spacing = size * 2.0
	var sig := DesktopIconBoundary.signature(spacing, items)
	if sig == _icon_signature:
		return
	_icon_signature = sig
	# 图标几何变了 → 同步刷新"避让区"（与下面生成的墙同源同形，供挑空白落点使用）
	_icon_boxes = DesktopIconBoundary.box_rects(items, spacing)
	# 伪装图标「松手对齐」用的原始数据（与墙 / 避让区同源，见 snap_to_desktop_icon）
	_icon_items = items
	_icon_spacing = spacing
	if not _icon_walls.is_empty():
		DesktopIconBoundary.destroy(_icon_walls)
	# 重建耗时走 print_verbose：忙闲联动恢复时会**整组重建这 384 条墙**，需要能观测这一次卡顿
	var t0 := Time.get_ticks_usec()
	_icon_walls = DesktopIconBoundary.spawn_all(self, spacing, items)
	print_verbose("[desktop] 图标边界积木重建：%d 条，耗时 %.1f ms" % [_icon_walls.size(), (Time.get_ticks_usec() - t0) / 1000.0])
	# 虚视跳转器 / 回收站 / 此电脑：一起对齐「围住图标的四个边组成的空间」（图标选择框统一尺寸 std.w × std.h）
	# 三者共用同一个图标盒子（见 desktop.gd 的 VIRTUAL_JUMP_* / RECYCLE_BIN_* / THIS_PC_* 常量说明）。
	if items is Array and items.size() > 0:
		var cell := maxf(spacing, DesktopIconBoundary.THICKNESS)
		var box := DesktopIconBoundary.uniform_size(items, cell)
		if box.x > 0.0 and box.y > 0.0:
			_vj_size = box
			_resize_virtual_jump_block(box)
		_rb_size = box
		_resize_recycle_bin_block(box)
		_pc_size = box
		_resize_this_pc_block(box)
		_dm_size = box
		_resize_device_manager_block(box)
		_sr_size = box
		_resize_scan_reconfigure_block(box)
		_cal_size = box
		_resize_calendar_block(box)
		# ★ 批次 121：课程表积木此前漏同步，恒为默认 48×48（"大小不正常"根因）
		_cs_size = box
		_resize_course_schedule_block(box)
	var sample: Array[String] = []
	for i in mini(4, _icon_walls.size()):
		var wb: Block = _icon_walls[i]
		if wb != null:
			sample.append(wb.string_id)
	print("[desktop] 桌面图标边界同步：%d 条墙（图标 %d 个，icon_size=%s，字符串ID示例 %s）"
		% [_icon_walls.size(), _icon_walls.size() / 4, str(size), str(sample)])
	if MousePassRunner.is_enabled():
		MousePassRunner.force_refresh()


# 把「桌面伪装图标」积木（带标签 BlockTags.DESKTOP_ICON）的中心吸附到桌面图标网格的最近格位。
# ★ 供 blocks/block.gd 的 _snap_to_desktop_icon() 在拖动松手时调用（沿父链找宿主，见那里）。
# ★ 数据源与图标边界墙同源（_icon_items / _icon_spacing）→ 对齐后的位置就是"图标会在的位置"。
# ★ 批次 114：改走 grid_snap_free —— 最近格位若已被**真实图标**占用，自动跳到最近的**空**格位，
#   避免"假图标和真图标完全重合"（见 DesktopIconBoundary.grid_snap_free 的说明）。
# ★ 无图标数据（未枚举到 / 忙闲联动期间收掉了墙）→ 原样返回，调用方据此跳过（不会乱跳）。
func snap_to_desktop_icon(p: Vector2, mover: Block = null) -> Vector2:
	# ★ 批次 121：收集其它"桌面伪装图标"积木（标签 BlockTags.DESKTOP_ICON）当前已占据的格位，
	#   传给 grid_snap_free 的 extra_occupied，使被拖动松手的假图标不会落到另一个假图标之上
	#   （mover 自身除外，否则它会避开自己当前所在的格位、反而跳走）。
	var extra: Array[Rect2] = []
	if BlockManager != null:
		for id in BlockManager.get_all_ids():
			var b: Block = BlockManager.get_block(id)
			if b == null or b == mover:
				continue
			if not (BlockTags.DESKTOP_ICON in b.tags):
				continue
			var sz := Vector2(b.width, b.height)
			extra.append(Rect2(b.global_position - sz * 0.5, sz))
	# ★ 批次 119：传入桌面可用区矩形（屏幕像素口径），约束落点不能跑到屏幕外面
	#   （真实桌面图标贴着屏幕边时，其上方/左侧"空格位"在屏幕外 → 旧逻辑会选中它导致假图标出屏）。
	# ★ 批次 124：改用 get_desktop_usable_rect_f() —— 把任务栏条带整段排除，假图标不再吸附到任务栏上。
	return DesktopIconBoundary.grid_snap_free(p, _icon_items, _icon_spacing, DesktopShell.get_desktop_usable_rect_f(), extra)


# ============ 实时内存枚举（程序页面 + 桌面图标）============

func _setup_scene_enum() -> void:
	# 进游戏立刻先拉一次（不等第一个 1s），让边框/图标尽快出现
	_start_scene_enum()
	_enum_timer = Timer.new()
	_enum_timer.wait_time = ENUM_INTERVAL_SEC
	_enum_timer.autostart = true
	_enum_timer.timeout.connect(_start_scene_enum)
	add_child(_enum_timer)
	# ★ 忙闲联动：机器「在忙」→ 停掉「扫描窗口 + 图标边界积木」这一整套（见 _apply_busy_pause）
	if BusyState != null:
		if not BusyState.state_changed.is_connected(_on_busy_state_changed):
			BusyState.state_changed.connect(_on_busy_state_changed)
		# 启动时已经处于「在忙」→ 立刻按忙碌档运行（本轮已发出的枚举结果仍会被应用，
		# 只是不再建墙、也不再起下一轮扫描）
		_apply_busy_pause(BusyState.is_busy())


func _on_busy_state_changed(busy: bool, _source: String) -> void:
	_apply_busy_pause(busy)


## 忙闲联动：机器「在忙」时关闭两套"背景性"系统（用户需求：忙时关掉一部分系统）。
##
## 【为什么关这两个】
##   · 扫描窗口 = 每秒起一个 PowerShell 现编译 30KB C# 再枚举全部顶层窗口（1.0~1.1s/次），
##     是**与帧率无关的固定底噪**；忙的时候完全没必要每秒扫一次。
##   · 桌面图标边界积木 = 96 个图标 × 4 向 = **384 条积木**，每条都在跑 `_physics_process`
##     （60Hz ⇒ 每秒 2.3 万次脚本调用），纯静态装饰却有实打实的物理帧成本。
##
## 【行为】
##   在忙 → 停节拍器 + 收掉已建的墙（并复位签名，恢复时重建）+ 跳过建墙代码路径
##   空闲 → 重启节拍器并**立刻**拉一次（不等下一个 1s），下一轮枚举自然把墙重建回来
##   ★ 首轮枚举结果仍然照常应用 → 窗口页面（程序页面边框/覆盖）不受影响，
##     不会出现"启动时正在忙 → 桌面一片空白"的观感问题。
func _apply_busy_pause(busy: bool) -> void:
	if busy == _busy_paused:
		return
	_busy_paused = busy
	if _enum_timer != null and is_instance_valid(_enum_timer):
		if busy:
			_enum_timer.stop()
		else:
			_enum_timer.start()
	if busy:
		var n: int = _icon_walls.size()
		if n > 0:
			DesktopIconBoundary.destroy(_icon_walls)
			_icon_walls.clear()
		_icon_signature = ""      # 复位 → 恢复后的下一轮枚举会重建整组墙
		if MousePassRunner.is_enabled():
			MousePassRunner.force_refresh()
		print("[desktop] 忙闲联动：在忙 → 停止扫描窗口（子进程归零）+ 收掉 %d 条图标边界积木" % n)
	else:
		_start_scene_enum()       # 立刻恢复一次，不等 1s 节拍
		print("[desktop] 忙闲联动：空闲 → 恢复扫描窗口 + 图标边界积木（下一轮枚举重建）")
	# ★★ 批次 8：忙闲切换**必须复位退避**。切到空闲的那一轮往往正是"刚发生了一堆变化"
	#   （用户刚操作完别的窗口），带着退避状态恢复会让第一轮用 3 s 间隔 → 响应变慢。
	if not busy:
		_reset_enum_backoff()


# ★★ 批次 8：自适应轮询间隔（空闲降频）。
#
# 为什么值得做：`SysInfo.exe scene` 单次 CPU **46.9 ms**（30 次采样中位），
#   1 s 轮询 = **0.047 核固定底噪**，60 s spawn **62** 个子进程（判据 0~2）。
#   批次 4 把单次从 967 ms 打到 40 ms 已经很好，但**频率没动** —— 底噪按频率线性缩放。
#   业务侧的等价前提：**这一轮枚举的结果与上一轮完全相同 ⇒ 场景没有变化**，
#   而场景没变化时"少扫几次"在功能上不可观测（没有任何东西需要被更新）。
#
# 为什么不直接改成固定 3 s：那样**任何**窗口变动的感知延迟都会从 ~1 s 变成 ~3 s。
#   自适应保留了"有变化时立刻回到 1 s"，只在**真正静止**时才降频。
#
# 判据为什么用原始 JSON 文本（而不是 `WindowPage.sync` 返回的 `changed`）：
#   `changed` 只在"窗口增删"时为 true；窗口**移动/缩放**走 `_sync_frames` /
#   `_sync_cover`，它们**不回报变化** ⇒ 用它当判据会在用户拖动窗口时停止刷新边框。
#   原始文本逐字节比较是**零歧义**的：任何字段（含坐标/尺寸/图标数组）变了都会被看到。
func _update_enum_backoff(json: String) -> void:
	if _enum_timer == null or not is_instance_valid(_enum_timer):
		return
	if json == _enum_last_json:
		_enum_stable += 1
	else:
		# 变了（或这是第一次有效结果）→ 复位并把间隔调回快速档
		_enum_last_json = json
		_enum_stable = 0
		_set_enum_interval(ENUM_INTERVAL_SEC, false)
		return
	if _enum_stable >= ENUM_STABLE_ROUNDS:
		_set_enum_interval(ENUM_IDLE_INTERVAL_SEC, true)


# 复位退避状态并立刻把间隔调回 1 s（忙闲恢复时用）。
func _reset_enum_backoff() -> void:
	_enum_last_json = ""
	_enum_stable = 0
	_set_enum_interval(ENUM_INTERVAL_SEC, false)


# 设置节拍间隔并同步 `_enum_backed_off`。`backed` 只用于可观测性（打印 / 探针）。
func _set_enum_interval(sec: float, backed: bool) -> void:
	if _enum_timer != null and is_instance_valid(_enum_timer):
		if not is_equal_approx(_enum_timer.wait_time, sec):
			_enum_timer.wait_time = sec
	if _enum_backed_off == backed:
		return
	_enum_backed_off = backed
	print("[desktop] 场景枚举：%s → 间隔 %.1f s（静止 %d 轮后降频，任何变化立刻回到 %.1f s）"
		% ["降频" if backed else "恢复", sec, _enum_stable, ENUM_INTERVAL_SEC])


# 在后台线程跑一次 enumerate_scene.ps1，拿到 JSON 后交由主线程解析。
# （OS.execute 会阻塞；放进线程避免每 ~1s 卡一次 UI。）每轮新建线程，不复用已结束的 Thread。
func _start_scene_enum() -> void:
	if _enum_busy:
		return
	# ★ 忙闲联动：在忙期间不起新的一轮扫描（唯一的调用源是节拍器，而它在忙时已被 stop；
	#   这里再兜一道，避免任何新增调用点在忙时把 PowerShell 又拉起来）
	if _busy_paused:
		return
	# 主线程取游戏窗口 HWND（DisplayServer 只能在主线程调用），供枚举精确排除自身窗口
	_game_hwnd = DisplayServer.window_get_native_handle(get_window().get_window_id())
	_enum_busy = true
	# ★ 上一轮的 Thread 若已跑完但还没被 _consume_scene_enum 回收（同帧内 timer 先于 _process
	#   触发就会发生），先 join 掉再覆盖，否则旧 Thread 被直接弃引用 → `~Thread` 告警。
	if _enum_thread != null:
		_enum_thread.wait_to_finish()
		_enum_thread = null
	# ★★ 不变式：`_enum_thread != null` ⟹ start() 成功（失败就当场 null 掉）。
	#   保证 _consume_scene_enum / _exit_tree 里的 `wait_to_finish()` 永远合法。
	var t := Thread.new()
	if t.start(_enum_worker) != OK:
		push_warning("[Desktop] 场景枚举线程启动失败，本轮跳过")
		_enum_busy = false
		return
	_enum_thread = t


func _enum_worker() -> void:
	var json := _run_scene_enum_once()
	_enum_mutex.lock()
	_enum_json = json
	_enum_pending = true
	_enum_busy = false
	_enum_mutex.unlock()


# 跑一次外部枚举，返回 stdout 文本（失败返回 ""）。
# ★ 优先 **预编译的 SysInfo.exe**：一次进程启动 + 直接调用已编译好的 C#，
#   没有 PowerShell 宿主启动、没有每次现编译 C#、也没有 conhost。
# ★ 兜底：EXE 不存在，或存在但退出码非 0 / 没有输出 → 退回旧的 PowerShell 脚本路径
#   （功能等价但每次都要现编译 30 KB C#，开销高一个数量级）。兜底只在异常环境触发，
#   告警只打一次，避免每秒刷屏。
# 参数约定（三条路径一致）：把游戏真实 PID 与主窗口 HWND 传给枚举，让它能跳过游戏自身的
# 透明覆盖窗口 —— 否则会为它生成铺满全屏的页面覆盖/边框积木，反过来盖住游戏内容。
func _run_scene_enum_once() -> String:
	var out: Array = []
	var pid := OS.get_process_id()
	var exe_abs := ProjectSettings.globalize_path(ENUM_EXE)
	# ★ 用**绝对 OS 路径**判断存在性（不是 res://）：导出后 res:// 里的 exe 取不到，
	#   此处就会走兜底，行为可预期。
	if FileAccess.file_exists(exe_abs):
		var code := OS.execute(exe_abs, PackedStringArray(["scene", str(pid), str(_game_hwnd)]), out, false)
		if code == 0 and not out.is_empty():
			# 进程输出是多行 JSON，OS.execute 每行一个元素 → 需用 \n 拼回完整字符串
			return "\n".join(out)
		if not _enum_exe_warned:
			_enum_exe_warned = true
			push_warning("[Desktop] SysInfo.exe 执行失败（退出码 %d，输出 %d 行）→ 回退 PowerShell 枚举"
				% [code, out.size()])
	elif not _enum_exe_warned:
		_enum_exe_warned = true
		push_warning("[Desktop] 未找到 SysInfo.exe（先跑 addons/hellonyxel_sysinfo/build_sysinfo.ps1 生成）→ 回退 PowerShell 枚举")
	out = []
	var args := PackedStringArray([
		"-NoProfile", "-ExecutionPolicy", "Bypass",
		"-File", ProjectSettings.globalize_path(ENUM_SCRIPT),
		"-GamePid", str(pid),
		"-GameHwnd", str(_game_hwnd),
	])
	var code2 := OS.execute("powershell.exe", args, out, false)
	return "" if code2 != 0 or out.is_empty() else "\n".join(out)


# 在 _process 里调用：把后台枚举结果应用到场景（仅当有结果且**线程已结束**时取）
func _consume_scene_enum() -> void:
	_enum_mutex.lock()
	var pending := _enum_pending
	var json := _enum_json
	var alive := _enum_thread != null and _enum_thread.is_alive()
	_enum_mutex.unlock()
	if not pending or alive:
		return
	_enum_mutex.lock()
	_enum_pending = false
	_enum_mutex.unlock()

	# 线程已结束：取回其句柄（wait_to_finish 立即返回），避免析构告警并复用同一线程对象下一轮
	if _enum_thread != null:
		_enum_thread.wait_to_finish()
	_enum_thread = null

	var data: Variant
	if PerfMonitor.profiling:
		# ★ 自测量（批次 1）：枚举 JSON 的解析成本（每轮枚举一次）
		var _t0 := Time.get_ticks_usec()
		data = JSON.parse_string(json)
		PerfMonitor.add_span("enum_parse", Time.get_ticks_usec() - _t0)
	else:
		data = JSON.parse_string(json)
	if typeof(data) != TYPE_DICTIONARY:
		return
	# ★★ 批次 8：拿到**有效**结果后才更新退避判据（放这里而不是前面，
	#   这样"枚举失败/返回空"不会被误判成"结果没变"而错误地退避）。
	_update_enum_backoff(json)
	if ENUM_DEBUG and not _enum_debug_done:
		_enum_debug_done = true
		_dump_enum_debug(data)
	_apply_scene_data(data)


func _dump_enum_debug(data: Dictionary) -> void:
	# 把首次枚举到的窗口清单 + 游戏自身窗口的排除判定落盘，供排查「虚视跳转器被页面覆盖盖住」。
	var lines := PackedStringArray()
	lines.append("game_pid=" + str(OS.get_process_id()) + " game_hwnd=" + str(_game_hwnd))
	var wins: Array = data.get("windows", [])
	lines.append("window_count=" + str(wins.size()))
	for w in wins:
		if w is Dictionary:
			var hw := int(w.get("hwnd", 0))
			var pd := int(w.get("pid", 0))
			var is_game := (pd == OS.get_process_id()) or (hw == _game_hwnd and _game_hwnd != 0)
			lines.append("  hwnd=%d pid=%d cls=%s title=%s rect=%d,%d %dx%d is_game=%s" % [
				hw, pd, str(w.get("cls", "")), str(w.get("title", "")),
				int(w.get("x", 0)), int(w.get("y", 0)), int(w.get("w", 0)), int(w.get("h", 0)),
				is_game])
	var dir := SaveManager.get_temp_dir()
	var path := dir.path_join("enum_debug.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines))
		f.close()


func _apply_scene_data(data: Dictionary) -> void:
	# ★ 自测量（批次 1）：注意 `icon_walls` 是本函数**内部**的子项，面板里要标注清楚。
	if PerfMonitor.profiling:
		var t0 := Time.get_ticks_usec()
		_apply_scene_data_impl(data)
		PerfMonitor.add_span("scene_data", Time.get_ticks_usec() - t0)
		return
	_apply_scene_data_impl(data)


func _apply_scene_data_impl(data: Dictionary) -> void:
	# 1) 程序页面：边框 + 覆盖（差量同步，开/关/最小化窗口不整批重建）
	var res := WindowPage.sync(self, data.get("windows", []), _page_state)
	_page_state = res["state"]
	if res["changed"] and MousePassRunner.is_enabled():
		MousePassRunner.force_refresh()
	# 2) 桌面图标边界：按需重排
	_sync_icon_boundaries(data.get("desktop_icons", null))
	# 3) 虚视跳转器：首轮在「空白（无窗口）」处放置一个实例（避开窗口，避免被 cutout 洞穿透）
	#    之后不再自动迁移 —— 被真实窗口盖住是「桌面文件」语义的正确行为，用户拖放的位置必须尊重。
	_ensure_virtual_jump_spawned(data.get("windows", []))
	# 3b) 回收站：同款流程，挑点时额外避开（此时已就位的）虚视跳转器。
	#     ★ 必须在 3) 之后：避让列表里要拿到虚视跳转器的真实矩形。
	_ensure_recycle_bin_spawned(data.get("windows", []))
	# 3c) 此电脑：同款流程，挑点时额外避开虚视跳转器 / 回收站。
	#     ★ 必须在 3)/3b) 之后：避让列表里要拿到虚视跳转器、回收站的真实矩形。
	_ensure_this_pc_spawned(data.get("windows", []))
	# 3d) 设备管理：同款流程，挑点时额外避开虚视跳转器 / 回收站 / 此电脑。
	#     ★ 必须在 3c) 之后：避让列表里要拿到此电脑的真实矩形。
	_ensure_device_manager_spawned(data.get("windows", []))
	# 3e) 扫描重构器：同款流程，挑点时额外避开 虚视跳转器 / 回收站 / 此电脑 / 设备管理。
	#     ★ 必须在 3d) 之后：避让列表里要拿到设备管理的真实矩形。
	_ensure_scan_reconfigure_spawned(data.get("windows", []))
	# 3f) 日历：同款流程，挑点时额外避开 虚视跳转器 / 回收站 / 此电脑 / 设备管理 / 扫描重构器。
	#     ★ 必须在 3e) 之后：避让列表里要拿到扫描重构器的真实矩形。
	_ensure_calendar_spawned(data.get("windows", []))
	# 3g) 课程表：同款流程，挑点时额外避开 虚视跳转器 / 回收站 / 此电脑 / 设备管理 / 扫描重构器 / 日历。
	#     ★ 必须在 3f) 之后：避让列表里要拿到日历的真实矩形。
	_ensure_course_schedule_spawned(data.get("windows", []))


# 类型名 BedRockX / BedRockY：登记内置默认模板（"我的积木类型"里可见；仅内存，不写盘）。
# 几何尺寸在创建时由 DesktopBarrier.spawn_all / _place 按当前桌面矩形强制覆盖（符合「尺寸不靠 JSON」）。
func _register_barrier_types(rect: Rect2) -> void:
	# ★ 屏障类型定义以 res://block_types/（BedRockX.json / BedRockY.json）的 JSON 为准（创建时读取）；
	#   文件不存在时回退到代码默认；用户改 JSON 即生效；仅在保存积木种类时写盘。
	BlockTypes.ensure_builtin_type(DesktopBarrier.TYPE_X, DesktopBarrier.make_def_x(rect.size.x))
	BlockTypes.ensure_builtin_type(DesktopBarrier.TYPE_Y, DesktopBarrier.make_def_y(rect.size.y))


# 桌面矩形变化 → 类型定义 + 屏障实例 + 任务栏屏障一起跟着变
func _on_desktop_geometry_changed(size: Vector2i) -> void:
	var rect := Rect2(Vector2.ZERO, Vector2(size))
	_register_barrier_types(rect)
	DesktopBarrier.apply_rect(_barriers, rect)
	_refresh_taskbar_barrier(rect)


func _refresh_taskbar_barrier(rect: Rect2) -> void:
	# ★ 与 _setup_taskbar_barrier 同源（原生工作区优先），保证几何变化后重排用的是同一份规则。
	var taskbar: Dictionary = DesktopShell.get_taskbar_info()
	DesktopBarrier.apply_taskbar(_taskbar_barrier, rect, taskbar)


# 对外 API：桌面屏障 { role -> Block }
func get_barriers() -> Dictionary:
	return _barriers


# 对外 API：按当前桌面矩形重排屏障（事件链 / 调试面板可调用）
func refresh_barriers() -> void:
	var rect := DesktopShell.get_desktop_rect_f()
	_register_barrier_types(rect)
	DesktopBarrier.apply_rect(_barriers, rect)


# 当前焦点是否落在「文本输入控件」上（LineEdit / TextEdit / 其子类）。
# 用于让 Tab 在输入场景下归输入控件（如控制台 Tab 补全），不被桌面的「Tab 开启穿透」抢走。
func _text_input_has_focus() -> bool:
	var vp := get_viewport()
	if vp == null:
		return false
	var fo := vp.gui_get_focus_owner()
	if fo == null or not is_instance_valid(fo):
		return false
	return fo is LineEdit or fo is TextEdit


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		# Tab 键：仅在「桌面穿透未开启」时开启穿透。
		# 关闭穿透不在这里做——走系统托盘右键菜单（避免与输入法冲突，见 TrayIcon.cs）。
		# ★ 例外：当**文本输入控件正在编辑**（LineEdit/TextEdit 持有焦点，含 IME 组字中）时，
		#   Tab 归输入控件（控制台 Tab 补全 / 表格切栏等）。否则一旦在输入框里按 Tab，
		#   本函数会把整窗裁成接收区（SetWindowRgn）→ 正在输入的面板当场被裁没 = 「一按 Tab 就崩」。
		if k.pressed and not k.echo and k.keycode == KEY_TAB:
			if not _text_input_has_focus() and not MousePassRunner.is_enabled():
				MousePassRunner.set_enabled(true)
				print("[desktop] Tab → 桌面穿透开启（关闭请在系统托盘右键菜单操作）")
				get_viewport().set_input_as_handled()

		if k.pressed and not k.echo and k.keycode == KEY_ESCAPE:
			if menu.is_open():
				menu.close()
			elif editor.is_open():
				editor.close()

	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			# 鼠标按下能到达这里，说明点在窗口「接收区」（积木 / UI），而非穿透区。
			# 此时把窗口带到前台激活：否则当焦点停留在桌面（其他程序都关闭）时，
			# Godot 收不到键盘事件，受控积木的 WASD / 空格会失灵。见 _ensure_active。
			_ensure_active()
		if mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
			_last_mouse_pos = mb.position
			# ★ 关卡页开着「允许拖动场景」(allow_drag) 且这次右键落在它的深色背景里
			#   → 这次右键归关卡页做摄像头平移，不弹游戏菜单。
			#   这里**主动询问关卡页**、而不是靠"谁的 _unhandled_input 先跑" →
			#   与节点遍历顺序无关，右键拖动在任何顺序下都稳定。
			if _level_page_wants_right_drag(mb.position) or _home_page_wants_right_drag(mb.position):
				return
			# 穿透开启（默认）时，空白处的事件穿到桌面（到不了这里）→ 走 Windows 原生菜单；
			# 穿透关闭时，空白处的事件也到得了这里 → 弹游戏菜单。
			# 积木/UI 处于穿透接收区，无论开关都到得了这里 → 右键积木始终是游戏菜单。
			# 非调试模式下菜单是空的 → 不弹空菜单，也不吞掉这次右键（留给游戏逻辑用）
			if _open_context_menu(mb.position):
				get_viewport().set_input_as_handled()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			if menu.is_open():
				menu.close()
			_begin_left_press(mb.position)
		elif (not mb.pressed) and mb.button_index == MOUSE_BUTTON_LEFT and (_rubber_active or _rubber_pending):
			# 松开左键才结束（要么已拉框受力 → 框选生效；要么未超阈值 → 视为点击，不出框），
			# 否则普通点击/双击/拖动积木的松开会被误当成空框而清空选择。
			_end_left_press()
	elif event is InputEventMouseMotion:
		if _rubber_active:
			# 拉框中：实时更新框
			_rubber_end = event.position
			_redraw_selection()
		elif _rubber_pending:
			# 待判定：位移超过阈值才真正开始拉框（否则按下后微动不产生极小框）
			if event.position.distance_to(_rubber_start) > DRAG_THRESHOLD:
				_rubber_active = true
				_rubber_end = event.position
				_redraw_selection()


# ============ 框选 / 选择集 ============

# 左键按下：判断点在积木上还是空白处，分派「选中 / 加选 / 开始拉框」。
# 注意：可拖动积木的按下会被 Block 自身的 _unhandled_input 吞掉（到不了这里），
# 对「拖拽未选中积木清空选择」串由 _physics_process 里的 _drag_watch_block 监听兜底。
func _begin_left_press(pos: Vector2) -> void:
	_last_mouse_pos = pos
	# 若上次少松了一次（如窗口切走），保证框选不会卡死
	if _rubber_active or _rubber_pending:
		_end_left_press()
	var b: Block = _block_under_point(pos)
	if b != null:
		if Input.is_key_pressed(KEY_SHIFT):
			# Shift 点击：切换该积木的选中状态（选中 ⇄ 不选），其余保持
			_toggle_in_selection(b)
		elif not _selection.has(b):
			# 点到「未选中」的积木 → 清空旧选择并只选它（单击其他地方 / 点未选中元素即清空）
			_clear_selection()
			_select(b)
		else:
			# 点到「已选中」的积木 → 保持整个选择（便于整组拖动 / 批量操作）
			pass
		_redraw_selection()
		return
	# 点在空白处：先进入「待判定」态（不出框）。位移超阈值 → 开始拉框；未超就松开 → 点击。
	# Shift → 合并进现有选择；否则结束框时替换选择（清空旧的）。
	_rubber_pending = true
	_rubber_union = Input.is_key_pressed(KEY_SHIFT)
	_rubber_start = pos
	_rubber_end = pos


# 左键松开：要么按框内积木更新选择集合，要么（未超阈值）当作一次「点击空白」只清空选择。
# 本函数同时处理 active（已拉框）与 pending（未超阈值）两种收尾。
func _end_left_press() -> void:
	if not _rubber_active and not _rubber_pending:
		return
	var was_active: bool = _rubber_active
	_rubber_active = false
	_rubber_pending = false
	if not was_active:
		# 位移未达阈值 → 视为一次对空白处的点击/双击：维持「点击空白清空选择」的语义，
		# 但不画出任何极小框选框。（Shift+点击空白 = 加选模式，什么都不合并 → 保持原选择）
		if not _rubber_union:
			_clear_selection()
		_redraw_selection()
		return
	var rect := Rect2(_rubber_start, _rubber_end - _rubber_start).abs()
	var hits := _blocks_in_rect(rect)
	if _rubber_union:
		# Shift 加选：把框内的并入现有选择（不重复）
		for h in hits:
			if not _selection.has(h):
				_selection.append(h)
	else:
		# 普通框选：替换整个选择（若框内为空 ≡ 清空上次选择）
		_selection = hits
	_redraw_selection()


func _clear_selection() -> void:
	_selection.clear()
	# ★★ 清空必须**立刻**刷新选择层，不能指望调用方记得补一次 _redraw_selection：
	#   Node2D 的绘制指令是**保留式**的 —— 不 queue_redraw，上一帧画的高亮矩形会一直
	#   留在屏幕上。而 _process 只在「有选中项」时才刷新，清空之后就再也不会刷
	#   → 删除积木后那块高亮边框永远停在原地，就是「选中状态的残影」。
	#   （历史 bug：右键菜单「删除积木」的整组删除分支只调了 _clear_selection。)
	_redraw_selection()


func _select(b: Block) -> void:
	if not _selection.has(b):
		_selection.append(b)


func _toggle_in_selection(b: Block) -> void:
	if _selection.has(b):
		_selection.erase(b)
	else:
		_selection.append(b)


# 摘掉选择集里**已被释放**的积木（返回是否真发生了变化）。
# ★ 为什么需要：只有本类自己删积木才顺手 _clear_selection；控制台 /remove_block、
#   读档清场（save_manager）、关卡清场（level_page）都在别处 queue_free 积木
#   → 选择集里会留下死引用，让「_selection 非空」恒成立（每帧白刷一次），
#   也会让「编辑积木属性(N)」把已删的块算进个数。
# ★ 先 is_instance_valid 再判类型：`is` 作用在已释放实例上会报错。
func _prune_selection() -> bool:
	var alive: Array[Block] = []
	for b in _selection:
		if is_instance_valid(b) and b is Block:
			alive.append(b)
	if alive.size() == _selection.size():
		return false
	_selection = alive
	return true


# 返回与矩形相交的全部「可见、可被选中」积木。选中与否**只由标签控制**（统一闸门）：
#   · show —— 可见性：无 show 的积木（BedRock 屏障等隐形墙）不参与框选；
#   · selectable（可被选中）—— 非调试模式下必须带；调试模式一切可见积木均可选中
#     （含 auto_generated 的系统积木，如图标边界墙，便于调试编辑）。
#   系统积木（屏障/图标墙/页面边框）生成时就不带 selectable → 非调试下天然不可选。
func _blocks_in_rect(rect: Rect2) -> Array[Block]:
	var out: Array[Block] = []
	# ★★ 框选限定在**当前活动场景**内：
	#   · 关卡页面可见 → 只框关卡内积木（桌面积木被页面盖住，不该被框到）；
	#   · 关卡页面不可见 → 只框桌面积木（关卡积木藏在页面里，其全局坐标会随页面平移浮动）。
	#   `global_position` 是**世界坐标**，而关卡积木的坐标会随页面平移/搬运漂移 —— 只用全局矩形
	#   相交判定会让"看不见的"积木被框进来（同传送/检测的同场景闸门问题）。
	var want_scenes: Array = []
	if _level_page != null and is_instance_valid(_level_page) and _level_page.is_page_visible():
		want_scenes.append(_level_page)
	if _home_page != null and is_instance_valid(_home_page) and _home_page.is_page_visible():
		want_scenes.append(_home_page)
	var blocks: Array = get_tree().get_nodes_in_group("block")
	for b in blocks:
		if is_instance_valid(b) and b is Block and (BlockTags.SHOW in b.tags):
			if not _is_selectable(b):
				continue
			if not want_scenes.is_empty() and not (b._scene_of() in want_scenes):
				continue
			# ★ rect 来自 `event.position`（屏幕像素）→ 积木矩形也必须换算到屏幕像素
			#   （关卡页面在缩放画布里，直接用 global_position 会框选错位）。
			if rect.intersects(_block_screen_rect(b)):
				out.append(b)
	return out


# 积木当前是否可被玩家选中（框选 / 左键右键单选共用；唯一的选中闸门）：
#   调试模式 → 一切积木可选中（便于编辑）；
#   非调试模式 → 仅带 selectable（可被选中）标签的积木可选中。
#   ★ selectable 由 block.gd _ensure_selectable() 在入树时**给所有非系统积木自动补上**，
#     所以游戏态下"玩家自己造的积木"默认可选中；只有系统派生积木（auto_generated：
#     桌面屏障 / 图标墙 / 页面边框 / 页面覆盖）和显式 always_unselectable 的不可选。
func _is_selectable(b: Block) -> bool:
	if BlockTags.ALWAYS_UNSELECTABLE in b.tags:
		return false   # 始终不可选：优先级高于调试模式
	if Debug.debug_mode:
		return true
	return BlockTags.SELECTABLE in b.tags


# 调试模式切换：关闭时把「仅调试模式可选中」的积木从选择集里摘掉（避免高亮残留）
func _on_debug_mode_changed(on: bool) -> void:
	# 把新状态回写给托盘（决定右键菜单项显示「进入调试模式」还是「退出调试模式」）
	if TrayRunner != null and TrayRunner.has_method("write_debug_state"):
		TrayRunner.write_debug_state(on)
	if on:
		return
	var changed := false
	for b in _selection.duplicate():
		if is_instance_valid(b) and b is Block and not (BlockTags.SELECTABLE in b.tags):
			_selection.erase(b)
			changed = true
	if changed:
		_redraw_selection()


# 托盘右键菜单「进入/退出调试模式」→ 切换 Debug.debug_mode（mode_changed 信号会驱动各面板刷新）。
func _on_tray_toggle_debug() -> void:
	if Debug == null:
		return
	Debug.debug_mode = not Debug.debug_mode
	print("[Desktop] 托盘「进入/退出调试模式」→ 调试模式 = %s" % ("开" if Debug.debug_mode else "关"))


# 每帧：选中高亮 + 框选矩形 需要跟随积木移动而刷新；顺带消费后台枚举结果
func _process(_delta: float) -> void:
	# ★ 先摘掉已被外部释放的积木：只剩死引用时也要**刷一次**把高亮抹掉，
	#   否则同样会留下保留式绘制的残影（见 _prune_selection 的注释）。
	if _prune_selection():
		_redraw_selection()
	if _rubber_active or not _selection.is_empty():
		_redraw_selection()
	_consume_scene_enum()


# 物理帧：监听「拖拽未选中积木 → 清空选择」
func _physics_process(_delta: float) -> void:
	var db: Block = Block._dragging_block
	if db != null and db != _drag_watch_block:
		# 拖动刚开始：被拖的积木不在当前选择里 → 按需求清空选择对象
		if not _selection.has(db):
			_clear_selection()
			_redraw_selection()
		_drag_watch_block = db
	elif db == null:
		_drag_watch_block = null


# 注：desktop 自己**不再绘制任何东西** —— 原先的 _draw()（选中高亮 + 框选框）已迁到
#     _draw_selection()，由 _overlay 承载，见 _setup_selection_overlay()。


# ★ 建立「选择/框选」专用绘制层（见 SELECTION_Z 的注释说明为什么不能画在 desktop 自己身上）。
#   · 用 Node2D + 同脚本的绘制回调（draw 信号连到本类的 _draw_selection）
#   · z_index 拉到 SELECTION_Z → 永远在所有积木之上
#   · 不接收输入（Node2D 本就不参与 GUI 命中），也不参与鼠标穿透区域收集（它不是 Control）
func _setup_selection_overlay() -> void:
	_overlay = Node2D.new()
	_overlay.name = "SelectionOverlay"
	_overlay.z_index = SELECTION_Z
	_overlay.draw.connect(_draw_selection)
	add_child(_overlay)


# 刷新「选择高亮 + 框选框」的绘制（替代原先直接调 desktop 自己的 queue_redraw）。
# 所有原本 queue_redraw() 的位置都应改调本函数。
func _redraw_selection() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_redraw()


# 实际绘制内容：选中积木高亮（描边）+ 框选矩形。
# ★ 画在 _overlay 上（z_index = SELECTION_Z），坐标与 desktop 同空间（overlay 在原点、无缩放）。
func _draw_selection() -> void:
	# 选中积木高亮（描边，贴在积木外缘）
	for b in _selection:
		if is_instance_valid(b) and b is Block and (BlockTags.SHOW in b.tags):
			# ★ overlay 在默认画布（屏幕像素）→ 取积木的屏幕 AABB 描边，缩放 ≠ 1 时描边才贴住积木
			var rect := _block_screen_rect(b)
			_overlay.draw_rect(rect.grow(3.0), Color(0.30, 0.78, 1.0, 0.95), false, 2.0)
			_overlay.draw_rect(rect.grow(3.0), Color(0.30, 0.78, 1.0, 0.12), true)
	# 框选矩形
	if _rubber_active:
		var rect := Rect2(_rubber_start, _rubber_end - _rubber_start).abs()
		_overlay.draw_rect(rect, Color(0.42, 0.62, 1.0, 0.22), true)
		_overlay.draw_rect(rect, Color(0.42, 0.82, 1.0, 0.95), false, 1.0)


# 把窗口带到前台并激活（用于桌面前台时也能接收键盘，从而控制受控积木）
func _ensure_active() -> void:
	var win := get_window()
	if win != null and not win.has_focus():
		DisplayServer.window_move_to_foreground()


# ============ 屏幕像素 ⇄ 画布坐标（UI 缩放下必须换算）============
#
# 本场景有**三个**坐标空间，缩放假定不同（见 UIStyle 的坐标语义说明）：
#   · 默认画布（桌面世界 / 主场景，1:1）—— 本脚本的 `_unhandled_input` 拿到的
#     `event.position`、`get_global_mouse_position()`、桌面积木的 `global_position` 都在这里，
#     值就等于**屏幕像素**；
#   · ui_layer 画布（**所有浮层面板**：菜单/属性面板/设置/存档/背包/对话…）—— `scale` = UI 缩放；
#   · 关卡页面画布（独立 CanvasLayer 99，世界表面，当前不缩放）。
# 把「屏幕像素」直接当另两个画布的坐标用，缩放 ≠ 1 时菜单/属性面板会摆到「点击位置 × 缩放」处、
# 关卡落点会偏。清场时统一走下面这几个函数，别各处手算。

# ui_layer 的「画布 → 屏幕」变换（= 层变换，实测与层内节点的 get_canvas_transform() 一致）
func _ui_xf() -> Transform2D:
	if ui_layer != null and is_instance_valid(ui_layer):
		return ui_layer.transform
	return Transform2D.IDENTITY


# 屏幕像素 → ui_layer 画布坐标（鼠标落点交给菜单/属性面板时用）
func _to_ui(screen_pos: Vector2) -> Vector2:
	return _ui_xf().affine_inverse() * screen_pos


# ui_layer 画布坐标 → 屏幕像素
func _to_screen(ui_pos: Vector2) -> Vector2:
	return _ui_xf() * ui_pos


# 屏幕像素矩形 → ui_layer 画布坐标矩形
func _screen_rect_to_ui(screen_rect: Rect2) -> Rect2:
	return _ui_xf().affine_inverse() * screen_rect


# ---- 关卡页面画布（独立层，当前不缩放；换算写成通用式，将来该层若要缩放也不用改调用点）----

func _page_xf() -> Transform2D:
	if page_layer != null and is_instance_valid(page_layer):
		return page_layer.transform
	return Transform2D.IDENTITY


# 屏幕像素 → 关卡页面画布坐标（交给 add_level_block / 页面归属判定时用）
func _to_page(screen_pos: Vector2) -> Vector2:
	return _page_xf().affine_inverse() * screen_pos


func _screen_rect_to_page(screen_rect: Rect2) -> Rect2:
	return _page_xf().affine_inverse() * screen_rect


# 积木在**屏幕像素**下的 AABB（含所在画布的缩放：桌面画布 1×，关卡页面 = UI 缩放）。
# ★ 框选矩形、鼠标点、选中描边都来自屏幕像素（`event.position`），必须与积木在同一空间比较：
#   直接用 `b.global_position` 在缩放 ≠ 1 时会「点不中画出来的积木 / 框选错位」。
func _block_screen_rect(b: Block) -> Rect2:
	var xf: Transform2D = b.get_canvas_transform()
	var ctr: Vector2 = xf * b.global_position
	var sz: Vector2 = xf.basis_xform(Vector2(b.width, b.height)).abs()
	return Rect2(ctr - sz * 0.5, sz)


# 返回是否真的弹出了菜单。非调试模式下：选中集合里没有「可命令」积木时不弹（游戏态"只玩不改"）；
# 有「可命令」积木时会弹出只含「移到此处」的菜单（该条目不受调试模式限制）。
func _open_context_menu(screen_pos: Vector2) -> bool:
	# ★★ 先把「本次菜单的落点」记进 `_last_mouse_pos`，再建菜单项 —— 因为：
	#   ① `build_menu_items()` 里要用它（`_scene_and_point(_last_mouse_pos)` 数「移到此处(N)」）；
	#   ② 之后菜单动作（新建积木 / 新建积木类型 / 编辑积木属性的弹出位置）全用它。
	# ★ 为什么必须在这里兜底、不能只靠右键按下的 `_unhandled_input`：
	#   关卡页开着「允许拖动场景」(allow_drag) 时，右键**按下**被关卡页吞掉 → 桌面根本收不到
	#   那次按下 → `_last_mouse_pos` 停留在旧值（首次甚至为 ZERO）→ 之后「新建积木」会把积木
	#   放到页面/屏幕的**左上角**（正是本次修复的 bug）。单击结束由关卡页发 right_click_at 信号
	#   回来弹菜单（见 _on_level_right_click），这里补记落点即可覆盖该路径。
	_last_mouse_pos = screen_pos
	_target_block = _block_under_point(screen_pos)
	# 批量编辑范围：选中集合非空，且（点到空白 或 点中的是已选积木）→「编辑积木属性」作用于整组
	_batch_edit = (not _selection.is_empty()) and (_target_block == null or _selection.has(_target_block))
	var items: Array = build_menu_items(_target_block)
	if items.is_empty():
		return false
	# ★ 菜单在 ui_layer 里（画布坐标）→ 落点必须先由屏幕像素换算，缩放 ≠ 1 时菜单才会出现在点到处
	menu.open(_to_ui(screen_pos), items)
	return true


# ============ 「移到此处」（积木标签 commandable = 可命令）============

# 选中集合里带「可命令」标签的积木（顺带过滤已失效 / 非积木的引用）。
# 右键菜单与下令都走这一个来源，保证「菜单里显示几个」与「实际动几个」永远一致。
#
# ★★ 归属闸门：`filter_scene=true` 时，只保留**所属场景 == `scene`** 的积木。
#   这里「桌面」是一个**合法的比较值**（`scene == null` 表示桌面），不是"不过滤"的开关 ——
#   这个区分靠 `filter_scene` 承担，绝不能图省事写成 `if scene != null and ...`：
#     · `scene != null` 在 `scene` 是 **null Object** 时为 false → 桌面落点会**完全不过滤**
#       （正是本次「关卡内积木照样接受桌面落点」的隐蔽成因）；
#     · 且 Variant 里放的是 Object，`!= null` 对"空对象"的判定本身也不可靠。
#   所以判据一律「先比 `b._scene_of()`，再看要不要比」，并用独立的 bool 表达"要不要比"。
#
#   落点归属 = 「该世界坐标是否落在**可见的**关卡页面矩形内」（是→该页面，否→桌面）：
#     · 页面可见 + 点页面内 → 只命令**关卡内**积木；
#     · 页面不可见 / 点页面外 → 只命令**桌面**积木。
#   缺此闸门时，选中集合里的关卡积木收到"桌面上那个点"的世界坐标后会**朝桌面对应位置直线移动**
#   （甚至被页面裁剪后"消失"），反之亦然 —— 即用户报的「关卡内积木向桌面对应位置移动」。
func _commandable_selection(scene: Node = null, filter_scene: bool = true) -> Array[Block]:
	var out: Array[Block] = []
	for b in _selection:
		if not (is_instance_valid(b) and b is Block):
			continue
		if not (b.has_method("is_commandable") and b.is_commandable()):
			continue
		if filter_scene and b._scene_of() != scene:
			continue
		out.append(b)
	return out


# 落点所属的场景 + 「该场景坐标空间下的落点」。
# ★ 屏幕像素在**不同画布**里含义不同：桌面世界 = 默认画布（1:1，屏幕像素即画布坐标）；
#   关卡页面在自己的 CanvasLayer 里（换算走 _to_page）→ 给关卡积木下令/判归属都要用页面坐标，
#   否则缩放 ≠ 1 时会偏。
#   返回 [scene, point]：scene == null 表示桌面（合法值，别拿 null 兼任"不过滤"哨兵）。
func _scene_and_point(screen_pos: Vector2) -> Array:
	var page_pt := _to_page(screen_pos)
	if _level_page != null and is_instance_valid(_level_page) and _level_page.is_page_visible() \
			and _level_page.page_contains_global_point(page_pt):
		return [_level_page, page_pt]
	if _home_page != null and is_instance_valid(_home_page) and _home_page.is_page_visible() \
			and _home_page.page_contains_global_point(page_pt):
		return [_home_page, page_pt]
	return [null, screen_pos]


# 落点 `global_pos` 所属的场景（**画布坐标**输入 → 归属）：落在**可见的**关卡页面矩形内 = 该关卡页面；
# 否则 = 桌面（返回 null）。与 `LevelPage.page_contains_global_point()` 同一把尺子。
func _scene_of_point(global_pos: Vector2) -> Node:
	if _level_page != null and is_instance_valid(_level_page) and _level_page.is_page_visible():
		if _level_page.page_contains_global_point(global_pos):
			return _level_page
	if _home_page != null and is_instance_valid(_home_page) and _home_page.is_page_visible():
		if _home_page.page_contains_global_point(global_pos):
			return _home_page
	return null


# 这次右键是否该**让给关卡页**做「拖动场景」（关卡属性 allow_drag）？
# 语义出处 = LevelPage.wants_right_drag_at（页面可见 + 带 allow_drag + 落在深色背景里）。
# ★ 坐标换算走 _to_page：屏幕像素 → 关卡页画布坐标（与 page_contains_global_point 同一把尺子）。
func _level_page_wants_right_drag(screen_pos: Vector2) -> bool:
	if _level_page == null or not is_instance_valid(_level_page):
		return false
	if not _level_page.has_method("wants_right_drag_at"):
		return false
	return _level_page.wants_right_drag_at(_to_page(screen_pos))


# 家园页是否要接手这次右键做「拖动场景」？家园**始终允许**右拖平移（无关卡环境门槛）。
func _home_page_wants_right_drag(screen_pos: Vector2) -> bool:
	if _home_page == null or not is_instance_valid(_home_page):
		return false
	if not _home_page.has_method("wants_right_drag_at"):
		return false
	return _home_page.wants_right_drag_at(_to_page(screen_pos))


# 关卡页「右键单击」（屏幕位移未超拖动阈值）→ 由本页补弹右键菜单。
# ★ 为什么在**抬起**时才弹：右键落在可拖动背景上时，必须等"是不是拖动"判定完（阈值在关卡页里），
#   按下瞬间无法区分单击/拖动 → 按下时一律不弹（见 _unhandled_input 的 wants_right_drag 早退），
#   判定为单击后由关卡页发信号过来，这里才弹。screen_pos 是**屏幕像素**（与按下时同一口径）。
func _on_level_right_click(screen_pos: Vector2) -> void:
	if _open_context_menu(screen_pos):
		get_viewport().set_input_as_handled()


# 家园页「右键单击」（屏幕位移未超拖动阈值）→ 由本页补弹右键菜单（同 _on_level_right_click）。
func _on_home_right_click(screen_pos: Vector2) -> void:
	if _open_context_menu(screen_pos):
		get_viewport().set_input_as_handled()


# 给选中集合里的「可命令」积木下令：沿直线移动到 target（**该积木所在场景的坐标空间**）。
# ★ 每块积木各自走直线到该点 —— 若同时选中多块，它们会分别奔过去（大体会叠在一起）。
#   移动过程与鼠标无关（目标点是下单那一刻的位置），期间仍受碰撞阻挡（撞墙即停）。
# ★★ 只对**与落点同场景**的积木下令，且落点按该场景的坐标空间换算（见 _scene_and_point 的说明）。
func _command_move_selection(screen_pos: Vector2) -> int:
	var sp := _scene_and_point(screen_pos)
	var movables := _commandable_selection(sp[0], true)
	var target: Vector2 = sp[1]
	for b in movables:
		b.command_move_to(target)
	if not movables.is_empty():
		print("[desktop] 移到此处 (%.0f, %.0f) → %d 块可命令积木已下令" % [target.x, target.y, movables.size()])
	return movables.size()


# 构造右键菜单项（抽成独立函数：便于单元验证，也便于后续按模式增删条目）
#   blk != null → 针对该积木的操作
#   blk == null → 空白处操作（新建 / 我的积木类型）
#
# ★ **常显**（不受调试模式限制）的条目只有一个：
#     ·「移到此处」（MOVE_HERE_ID）：右键**空白处** + 选中集合里有带 BlockTags.COMMANDABLE（可命令）
#       标签的积木 → 无论是否调试模式都出现。必须加在下面的调试闸门**之前**。
# ★ 「编辑积木属性」(edit) 属于**仅调试模式**（右键积木，或空白处 + 已有选中时的批量入口）。
#     ★ 历史坑：它一度被当作"常显基础入口"提到闸门**之前**，于是非调试模式下玩家右键也能
#       看到属性编辑器 —— 用户按 bug 反馈。属性编辑与「另存为新类型 / 删除积木」同属调试工具，
#       必须待在 `if not Debug.debug_mode: return items` 闸门**之后**。
# ★ 其余条目**只在调试模式**（Debug.debug_mode）下可见：
#     「编辑积木属性」「另存为新类型」「删除积木」（右键积木）
#     「新建积木(空白)」「新建积木类型...」「我的积木类型」（右键空白处）
# ★「控制积木 / 解除控制」同样只在调试模式出现，且两者**二选一**：
#   按积木「标签」集合里有没有 BlockTags.CONTROLLED（受控状态）判断 ——
#     已受控 → 只显示「解除控制」（从标签集合移除 controlled）
#     未受控 → 只显示「控制积木」（向标签集合加入 controlled）
func build_menu_items(blk) -> Array:
	var items: Array = []
	# ---- 「移到此处」：空白处右键 + 选中集合含「可命令」积木 → 常显 ----
	if blk == null:
		# ★ 菜单条目也按**右键落点所属场景**过滤：只列"真会被下令"的那些积木，
		#   保证「菜单里显示几个」与「实际动几个」一致（同一把闸门；落点已按场景空间换算）。
		var movables := _commandable_selection(_scene_and_point(_last_mouse_pos)[0])
		if not movables.is_empty():
			var move_label := MOVE_HERE_LABEL
			if movables.size() > 1:
				move_label = "%s(%d)" % [MOVE_HERE_LABEL, movables.size()]
			items.append({"label": move_label, "id": MOVE_HERE_ID})
	# ---- 调试闸门：以下条目只在调试模式下可见 ----
	if not Debug.debug_mode:
		return items

	# ---- 「编辑积木属性」：**仅调试模式** ----
	# ★ 曾经把它放在上面那道闸门**之前**（当时理解为"常显入口"），结果非调试模式下
	#   玩家右键也能看到「编辑积木属性」→ 用户反馈为 bug。属性编辑器是调试工具，
	#   必须与「另存为新类型 / 删除积木」一样待在闸门后面。
	if blk != null:
		var edit_label := "编辑积木属性"
		if _batch_edit and _selection.size() > 1:
			edit_label = "编辑积木属性(%d)" % _selection.size()
		items.append({"label": edit_label, "id": "edit"})
	elif _batch_edit and not _selection.is_empty():
		# 批量编辑入口：空白处右键 + 已有选中 → 「编辑积木属性(选中N个)」
		var b_label := "编辑积木属性"
		if _selection.size() > 1:
			b_label = "编辑积木属性(%d)" % _selection.size()
		items.append({"label": b_label, "id": "edit"})

	if not items.is_empty():
		items.append({"separator": true})   # 与下方调试条目分隔
	if blk != null:
		# ★★ 「摄像头锚定」（仅调试模式 + 仅**关卡内**积木）：把关卡配置面板里「摄像头锚定」的
		#   目标直接写成这块积木的 ID 并**按下确定** —— 省掉"手抄 ID 再回配置面板粘贴"那一步。
		#   归属判定用 Block._scene_of()（向上找 LevelPage 祖先），与桌面/关卡同一把尺子。
		#   桌面积木不出现此项：锚定的是关卡摄像头，桌面积木不参与关卡投影。
		if _is_level_block(blk):
			items.append({"label": "摄像头锚定", "id": "cam_anchor"})
		items.append({"label": "另存为新类型", "id": "save_type"})
		var controlled: bool = blk.has_method("is_controlled") and blk.is_controlled()
		items.append({"separator": true})
		if controlled:
			items.append({"label": "解除控制", "id": "release_control"})
		else:
			items.append({"label": "控制积木", "id": "take_control"})
		items.append({"separator": true})
		items.append({"label": "删除积木", "id": "delete"})
	else:
		items.append({"label": "新建积木(空白)", "id": "new_blank"})
		items.append({"label": "新建积木类型...", "id": "new_type"})
		items.append({"separator": true})
		# 我的积木类型（次级菜单）
		var types: PackedStringArray = BlockTypes.list_names()
		var sub: Array = []
		if types.is_empty():
			sub.append({"label": "（暂无保存的类型）", "id": "__none__"})
		else:
			for tn in types:
				sub.append({"label": tn, "id": "spawn_type:" + tn})
		items.append({"label": "我的积木类型", "id": "my_types", "submenu": sub})
	return items


# 这块积木是否属于**当前关卡的投影**（右键菜单据此决定要不要给「摄像头锚定」入口）。
# ★ 先 is_instance_valid 再判类型：引用里可能留已释放积木，而 `is` 作用在已释放实例上会报错。
# 判定用 Block._scene_of()（向上找 LevelPage 祖先）——与 _commandable_selection 的场景闸门同源。
func _is_level_block(blk) -> bool:
	if blk == null or not is_instance_valid(blk) or not (blk is Block):
		return false
	var lp: Node = _level_page
	if lp == null or not is_instance_valid(lp):
		return false
	return blk._scene_of() == lp


# 点选命中判定（左键/右键单选与右键菜单目标共用）：
#   与 _blocks_in_rect 同一套标签闸门 —— show（可见）+ selectable（可被选中，调试模式全开）。
#   无 show 的隐形墙（BedRock 屏障）点不中，不会挡住它后面的东西。
func _block_under_point(screen_pos: Vector2):
	# ★★ 点选同样限定在**当前活动场景**内（同 _blocks_in_rect）：关卡页面可见时只点得中关卡积木，
	#   否则只点得中桌面积木 —— 避免点到"看不见的"另一场景积木。
	var want_scenes: Array = []
	if _level_page != null and is_instance_valid(_level_page) and _level_page.is_page_visible():
		want_scenes.append(_level_page)
	if _home_page != null and is_instance_valid(_home_page) and _home_page.is_page_visible():
		want_scenes.append(_home_page)
	var blocks: Array = get_tree().get_nodes_in_group("block")
	for b in blocks:
		# ★ 先 is_instance_valid 再 `is Block`：组快照里可能有已释放积木。
		if not is_instance_valid(b) or not (b is Block):
			continue
		if BlockTags.SHOW in b.tags:
			if not _is_selectable(b):
				continue
			if not want_scenes.is_empty() and not (b._scene_of() in want_scenes):
				continue
			# ★ 与框选同一把尺子：换成**屏幕像素** AABB，缩放 ≠ 1 时才点得中画出来的积木
			var rect := _block_screen_rect(b)
			if not rect.has_point(screen_pos):
				continue
			# ★★ 被更高的镂空遮罩盖住 → 该点上本积木已被视觉抹掉，点不中
			#   （闸门见 Block.is_point_covered，与 block.gd 的按下闸门同一把尺子）。
			#   否则在窗口的覆盖积木上点一下/右键，会选中并弹出"看不见的"下层积木的菜单。
			#   ★ 屏幕像素 → 该积木所在画布坐标：与 _block_screen_rect 用同一个 canvas_transform。
			if b.is_point_covered(b.get_canvas_transform().affine_inverse() * screen_pos):
				continue
			return b
	return null


func _on_menu_selected(id: String, _path: PackedStringArray) -> void:
	if id == MOVE_HERE_ID:
		# 「移到此处」：目标是**右键下单时**的位置（_last_mouse_pos 在右键按下时记录）
		_command_move_selection(_last_mouse_pos)
	elif id == "cam_anchor":
		_anchor_camera_to_target_block()
	elif id == "edit":
		_open_edit_panel()
	elif id == "save_type" and _target_block != null:
		var prop := BlockProperty.from_block(_target_block)
		editor.open(_to_ui(_last_mouse_pos), prop, "save_as_type", {"block": _target_block})
	elif id == "delete" and _target_block != null:
		# 删除：若目标是选中集合的一员，整组删除；否则只删单个
		if _selection.has(_target_block):
			for b in _selection.duplicate():
				if is_instance_valid(b):
					BlockManager.unregister(b)
					b.queue_free()
			_clear_selection()   # 内部会刷新选择层 → 抹掉高亮（不再留残影）
		else:
			BlockManager.unregister(_target_block)
			_target_block.queue_free()
			_redraw_selection()
		# ★ 删完顺手把「菜单上下文」清干净：
		#   · _target_block 已指向被释放的积木（实测 Godot 4.7 里它与 null 比较仍为真，
		#     所以不会误进别的分支，但引用本身是悬空的，留着只会让后面读它的代码吃惊）；
		#   · _batch_edit 是「选中集合 + 目标」派生出来的，删除后不再成立。
		_target_block = null
		_batch_edit = false
	elif id == "take_control" and _target_block != null:
		# 控制积木：把「受控状态」(controlled) 加入标签集合
		_target_block.set_controlled(true)
		print("[desktop] 控制积木 id=%d → 标签=%s" % [_target_block.id, str(_target_block.tags)])
	elif id == "release_control" and _target_block != null:
		# 解除控制：从标签集合移除「受控状态」(controlled)
		_target_block.set_controlled(false)
		print("[desktop] 解除控制 id=%d → 标签=%s" % [_target_block.id, str(_target_block.tags)])
	elif id == "new_blank":
		# 新建空白积木：属性全部来自 res://block_types/Blank.json（改 JSON 即改默认），
		# 创建后立即打开属性面板，让用户为这块积木设定精确宽高/标签等。
		var nb := BlockTypes.create_blank_block()
		if nb == null:
			push_warning("[desktop] 空白积木模板加载失败，已退回裸 Block")
			nb = Block.new()
		_host_new_block(nb)
		editor.open(_to_ui(_last_mouse_pos), BlockProperty.from_block(nb), "apply_to_block", {"block": nb})
	elif id == "new_type":
		var prop := BlockProperty.default_for_new()
		editor.open(_to_ui(_last_mouse_pos), prop, "spawn_new", {})
	elif id.begins_with("spawn_type:"):
		var name := id.substr("spawn_type:".length())
		var blk: Block = BlockTypes.create_block(name)
		if blk != null:
			_host_new_block(blk)
	# "my_types" 自身带次级菜单，不会作为叶子触发；__none__ 为占位，忽略


# 新建积木的**归属**：右键点落在可见的关卡页面内 → 挂进关卡舞台（位置=关卡原生坐标）；
# 否则挂到桌面世界（全局坐标）。
# ★ 修复：此前「关卡页面里右键新建积木」一律 add_child 到桌面 → 积木跑到桌面场景、不在关卡里。
# 「摄像头锚定」菜单动作：把关卡配置里的锚定目标设成**右键的那块关卡积木**。
# 真正的落笔（填 ID + 按确定 + 展开面板）在 LevelPage.set_camera_anchor_from_block 里 ——
# 配置面板的状态（_cam_input / _cfg_open）归关卡页面自己管，桌面只负责把目标递过去。
func _anchor_camera_to_target_block() -> void:
	if _target_block == null or not is_instance_valid(_target_block) or not (_target_block is Block):
		return
	var lp: LevelPage = _level_page
	if lp == null or not is_instance_valid(lp):
		return
	lp.set_camera_anchor_from_block(_target_block)


func _host_new_block(blk: Block) -> void:
	if blk == null:
		return
	var lp = LevelManager.level_page
	# ★ 关卡页面在自己的画布层里 → 落点用 _to_page 换算；
	#   桌面世界是默认画布，落点即屏幕像素（下面 else 分支照旧）。
	if lp != null and is_instance_valid(lp) and lp.has_method("add_level_block"):
		if lp.add_level_block(blk, _to_page(_last_mouse_pos)):
			return
	var hp = _home_page
	# ★ 家园页同理：开着且右键落点在页面内 → 进家园（落点仍用 _to_page 换算）。
	if hp != null and is_instance_valid(hp) and hp.has_method("add_home_block"):
		if hp.add_home_block(blk, _to_page(_last_mouse_pos)):
			return
	blk.position = _last_mouse_pos
	add_child(blk)


# 打开属性编辑面板：有批编辑范围 → 整组；否则单块
func _open_edit_panel() -> void:
	if _batch_edit and not _selection.is_empty():
		var blocks: Array[Block] = []
		for b in _selection:
			if is_instance_valid(b) and b is Block:
				blocks.append(b)
		if blocks.is_empty():
			return
		# ★ 只选中 1 个积木时按「单块编辑」处理。
		#   单击积木即进入选中集合（_select），所以「选中 1 个 + 右键它」也会满足 _batch_edit；
		#   若就此走批量分支，context 里没有 "block" → 面板把「积木ID / 字符串ID」两栏禁用，
		#   表现为「输入框灰掉、无法录入」（菜单项此时显示的却是不带数量的「编辑积木属性」，更易误判）。
		if blocks.size() == 1:
			editor.open(_to_ui(_last_mouse_pos), BlockProperty.from_block(blocks[0]),
				"apply_to_block", {"block": blocks[0]})
			return
		var prop := BlockProperty.from_block(blocks[0])
		editor.open(_to_ui(_last_mouse_pos), prop, "apply_to_block", {"blocks": blocks})
		return
	if _target_block != null and is_instance_valid(_target_block):
		var prop := BlockProperty.from_block(_target_block)
		editor.open(_to_ui(_last_mouse_pos), prop, "apply_to_block", {"block": _target_block})


func _on_editor_applied(action: String, payload: Dictionary) -> void:
	if action == "apply_to_block":
		var prop: Dictionary = payload.get("prop", {})
		var blocks: Variant = payload.get("blocks", null)
		if blocks is Array and not blocks.is_empty():
			for b in blocks:
				if is_instance_valid(b) and b is Block:
					BlockProperty.apply_to_block(b, prop)
		else:
			var b: Block = payload.get("block")
			if b != null:
				BlockProperty.apply_to_block(b, prop)
	elif action == "spawn_new":
		var name: String = payload.get("type_name", "")
		if name != "":
			BlockTypes.register(name, BlockProperty.to_type_def(name, payload.get("prop", {})))
			var blk: Block = BlockTypes.create_block(name)
			if blk != null:
				_host_new_block(blk)
			else:
				push_warning("[desktop] 类型 '%s' 已保存，但保存位置不是「本体」，本会话/游戏中不生效（仅 MOD/DLC 占位）" % name)
	elif action == "save_as_type":
		var name: String = payload.get("name", "")
		if name != "":
			BlockTypes.register(name, BlockProperty.to_type_def(name, payload.get("prop", {})))
			var b: Block = payload.get("block")
			if b != null:
				BlockProperty.apply_to_block(b, payload.get("prop", {}))


# 调试面板「调试」按钮：按 ID 强制打开积木属性窗（绕过「始终不可选」/ 选中闸门）
func open_block_editor_by_id(id: int) -> void:
	var b: Block = BlockManager.get_block(id)
	if b == null or not is_instance_valid(b):
		return
	# ★ 属性面板在 ui_layer（画布坐标）：积木的屏幕位置需换算；夹取范围也要用画布坐标下的可见矩形
	#   （读 get_visible_rect() 会在缩放 ≠ 1 时把面板夹到屏幕外）。
	var vr := UIStyle.canvas_viewport_rect(editor)
	var screen_pos := b.get_canvas_transform() * b.global_position
	var ui_pos := _to_ui(screen_pos)
	var pos := Vector2(
		clampf(ui_pos.x, vr.position.x, vr.end.x),
		clampf(ui_pos.y, vr.position.y, vr.end.y))
	editor.open(pos, BlockProperty.from_block(b), "apply_to_block", {"block": b})


# 退出时回收枚举线程，避免“Thread 对象销毁时未 wait_to_finish”的告警
func _exit_tree() -> void:
	if _enum_thread != null:
		# ★★ 必须**无条件** join：`is_alive()` 在「线程体已跑完但从未 join」时返回 false，
		#   旧写法（`if is_alive(): wait_to_finish()`）会跳过 join → 析构"完成未 realize"的
		#   Thread → 退出期刷 `destroyed without its completion having been realized`。
		#   不变式：`_enum_thread != null` ⟹ start() 成功 ⟹ 这里 wait_to_finish() 合法。
		_enum_thread.wait_to_finish()
		_enum_thread = null
