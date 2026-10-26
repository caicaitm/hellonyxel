# block_tags.gd
# 「标签」集合的标准标签名。
# 用途：积木的「标签」(PackedStringArray) 里含有某个标准标签名时，
#       对应的那一组属性才会生效（绘制/碰撞等）。
# 本文件只做「命名空间 + 校验」，不持有状态。
class_name BlockTags
extends RefCounted

# ---- 标准标签（控制各组属性是否生效；值用英文串，避免中文标识符问题）----
const SHOW := "show"              # 积木整体可见（对应 CanvasItem.visible）
const BORDER := "border"          # 边框绘制生效
const FILL := "fill"              # 填充绘制生效
const FILL_IMAGE := "fill_image"  # 以图片/动图/骨骼填充（需 填充模式选择 != 纯色）
const COLLISION := "collision"    # 碰撞体 / 碰撞图层生效
const TEXT := "text"              # 文本框绘制生效
const CHILD_FOLLOW := "child_follow"  # 子级单位跟随父级位移（仅位置；父级移动时子级一并位移）
                                      # bind_child() 会自动补上该标签；删掉它即只保留父子绑定关系而不跟随
const DRAGGABLE := "draggable"    # 可拖动：鼠标左键按住可拖动本积木（受碰撞阻挡）
const GRAVITY := "gravity"        # ★★ 已**从标签系统移除**（2026-10-23）：受重力改由「积木运动」面板
                                  #   的 gravity_enabled 设置。本常量只用来读旧存档做一次迁移，
                                  #   迁移后积木身上的这个标签会被剥离（见 block.gd _strip_legacy_motion_tags）。
const SELECTABLE := "selectable"  # 可被选中：允许被框选 / 左键右键单选选中——**选中与否的唯一闸门**。
                                  # ★ 不带本标签的积木在**非调试模式**下不可被选中（框选与单选都会跳过它）；
                                  #   调试模式下一切**可见**积木照常可选中（便于编辑关卡）。
                                  # ★ 系统积木（桌面屏障 / 图标墙 / 页面边框等）生成时就不带本标签
                                  #   → 非调试下天然不可选（不再依赖 auto_generated 判断，见 desktop.gd _is_selectable）。
                                  # ★ **玩家积木入树时由 block.gd _ensure_selectable() 自动补上**（幂等）：
                                  #   新建积木 / 虚视跳转器 / 图标副本 / 存档恢复 / 关卡积木 / 控制台创建 全都带它
                                  #   —— 否则玩家在游戏态下选不中自己造的积木（2026-09-29 修）。
                                  #   想表达"玩家不能选这块"用 ALWAYS_UNSELECTABLE（删本标签会被自动补回）。
const CONTROLLED := "controlled"  # 受控状态：WASD/方向键移动，空格跳跃（跳跃需「积木运动」里开启受重力）
                                  # 右键积木（调试模式下）可一键「控制积木 / 解除控制」= 增删本标签
                                  # ★ 其中**竖直**方向（W/S/↑/↓）另需 DETECTED_VERTICAL_MOVE 标签，
                                  #   水平方向（A/D/←/→）只需本标签。
const COMMANDABLE := "commandable"
                                  # 可命令：**被选中**时右键点空白处 → 右键菜单里出现「移到此处」；
                                  #   下令后本积木沿**直线**移动到该点（全程走碰撞校验，撞墙即停）。
                                  #   · 目标点是"命令下发那一刻右键点到的位置"，移动过程不受鼠标影响。
                                  #   · 若还开了受重力 / 带 controlled：命令期间由命令驱动位移（重力/键盘让位），
                                  #     命令结束后照常恢复（否则有重力的积木会被重力拽成弧线、永远到不了目标）。
                                  #   · 多个选中里只有带本标签的会动；不带的不动（见 desktop.gd _command_move_selection）。
                                  # ★ 该菜单项**不受调试模式限制**（非调试 / 游戏态下也显示）——
                                  #   这是右键菜单里唯一"常显"的条目，其余编辑类条目仍只在调试模式出现。
                                  # ★ 与 draggable/controlled 同为「能力型」标签：默认不含，需要才加。
const ROLLABLE := "rollable"      # ★★ 已**从标签系统移除**（2026-10-23）：可滚动改由「积木运动」面板
                                  #   的 roll_enabled 设置。本常量只用来读旧存档做一次迁移，
                                  #   迁移后积木身上的这个标签会被剥离（见 block.gd _strip_legacy_motion_tags）。
                                  #   开关打开后：圆/椭圆连续滚动；矩形/三角按刚体支点翻滚。
                                  #   ★ 须同时带 collision 标签才有支撑可托。
const ALWAYS_UNSELECTABLE := "always_unselectable"
                                  # 始终不可选：**优先级高于调试模式**。带本标签的积木在任何模式
                                  #   （含调试模式）下都不可被选中 / 框选 / 左右键单选。
                                  # ★ 用于"铺满全屏会遮住操作"的环境积木（如程序页面覆盖），
                                  #   避免调试时被误选而卡死操作。
                                  # ★ 需要调试这类积木时：用调试面板「选择ID」下拉旁的「调试」按钮
                                  #   强制打开对应积木的属性窗（绕过选中闸门）。
const DESKTOP_BARRIER := "desktop_barrier"
                                  # 桌面屏障：屏幕外的那圈 1px 边界阻挡积木（由 blocks/desktop_barrier.gd
                                  #   在启动时自动生成 4 块，防止积木掉出屏幕外）。
                                  #   · 只参与碰撞，**不带 show** → 不绘制（它是"看不见的墙"）；
                                  #   · 位于屏幕外，故不计入桌面穿透区域（见 MousePassRunner）；
                                  #   · 碰撞图层 = 编号层 1~30 + 默认 + 被拖动中 + 检测区（BlockLayers.barrier_layers()），
                                  #     所以无论积木用哪一层、是否正在被拖动，都挡得住。
const DESKTOP_TASKBAR := "desktop_taskbar"
                                  # 桌面任务栏屏障：贴在任务栏上表面（或侧边内沿）的那条 1px 阻挡积木
                                  #   （由 blocks/desktop_barrier.gd 按 sysinfo 里的 taskbar 信息生成），
                                  #   防止积木落到任务栏里。其余同 DESKTOP_BARRIER（不可见、不计入穿透）。
const DESKTOP_ICON_BOUNDARY := "desktop_icon_boundary"
                                  # 桌面图标边界：在每个桌面图标上下左右 0.5*icon_size_px 处生成的
                                  #   1px 透明碰撞墙（由 blocks/desktop_icon_boundary.gd 按 sysinfo 的
                                  #   desktop_icons 生成），把图标"围"起来，防止积木盖住/进入图标。
                                  #   不可见、只碰撞、不计入桌面穿透区域（见 MousePassRunner）。
const DESKTOP_ICON := "desktop_icon"
                                  # 桌面图标（层）+ **伪装图标对齐**（双用途，故名同）：
                                  #   · 作为**碰撞图层**名（见 BlockLayers）：桌面图标边界积木所在层。
                                  #     与 DESKTOP_ICON_BOUNDARY 标签同名，但一个是图层（谁能挡谁）、
                                  #     一个是标签（属性生效与否）。用于"分层"：桌面图标在下属。
                                  #   · 作为**积木标签**（批次 58）：标记"这是伪装成桌面图标的积木"
                                  #     → 拖动**松手**时自动对齐到「桌面图标会在的位置」（桌面图标网格，
                                  #       由 DesktopIconBoundary.grid_snap_free 按实时枚举到的图标推算；
                                  #       ★ 批次 114：最近格位若已被**真实图标**占用 → 自动跳到最近的
                                  #       **空**格位，避免"假图标和真图标完全重合"）；
                                  #       **按住 Ctrl** 拖动 = 自由摆放，松手停在原地、不对齐。
                                  #     见 blocks/block.gd 的 _snap_to_desktop_icon()。
                                  #   ★ 虚视跳转器 / 回收站 / 此电脑 / 设备管理 / 扫描重构器 / 日历 /
                                  #     图标占位 这些"桌面伪装"类型在登记类型时就带本标签（见 desktop.gd）。
const PROGRAM_PAGE_BORDER := "program_page_border"
                                  # 程序页面（边框）：每个程序窗口四边生成的边框积木的**碰撞图层**名
                                  #   （由 blocks/window_page.gd 按实时窗口枚举生成）。积木可落在页面上
                                  #   的边框而不下落，碰撞图层 = [默认, 本层]。
const PROGRAM_PAGE_COVER := "program_page_cover"
                                  # 程序页面（覆盖）：每个程序窗口的整页半透明覆盖积木的**碰撞图层**名
                                  #   （由 blocks/window_page.gd 生成）。卷积只用于视觉遮挡、显示层高于
                                  #   桌面内容，不阻挡普通积木。
const AUTO_GENERATED := "auto_generated"
                                  # 系统自动生成：所有由程序自动创建的环境积木（桌面屏障 / 任务栏屏障 /
                                  #   图标边界 / 页面边框 / 页面覆盖）都带本标签。
                                  #   · 用途：未来的存档系统**不保存**这类积木的位置等（它们是运行时派生物，
                                  #     随窗口/图标状态重建，存了反而会脏）。
                                  #   · ★ 不再用于「能否被选中」的判断——选中与否已统一由 selectable 标签控制
                                  #     （系统积木不带 selectable → 非调试下天然不可选）。
const LEVEL_PAGE := "level_page"
                                  # 关卡页面（表面）：是「关卡」页面的边框 / 覆盖 / 标题 / 缩放按钮所带标签。
                                  #   · 与 AUTO_GENERATED 一起用：保留"系统自动生成、不参与选择/编辑/保存"，
                                  #     同时标记它仍是**可交互的游戏表面**——桌面穿透开启时计入鼠标接收区
                                  #     （见 MousePassRunner._collect_rects），不会像程序页边框那样被裁掉。

# ---- 检测标签（动态、成对出现）----
# 「待检测_XXX」与「检测到_XXX」是一对**键始终对应**的标签，XXX 由使用者自由替换：
#     积木 A 带 to_detect_XXX（待检测_XXX） → A 成为「检测区」
#     任何积木 B（B != A）的**中心点落在 A 内** → B 自动获得 detected_XXX（检测到_XXX）
#     B 的中心点不再落在任何带 to_detect_XXX 的积木内 → 自动移除 detected_XXX
# ★ 判据是「中心点入区」而**不是**「AABB 重叠」：重叠判定下 B 用一角蹭到 A 就算命中，
#   画面上看不出它进了区；判中心点后"真的进到区里"才生效（与传送门的判据同款）。
# ★ 因此**站在检测区上面不算命中**（B 的中心在区上方）—— 要"进入"而不是"踩上去"。
# 判定**不看碰撞图层**：正因为 A、B 图层不同（互不阻挡）时 B 才能进入 A 内部，
#   这种"走进去"恰是本机制最常见的用法。
# 它们不在 ALL 里、也不做 is_standard_tag 校验 —— 因为键是开放的（前缀 + 任意串）。
const DETECT_PENDING_PREFIX := "to_detect_"   # 待检测_XXX：本积木是"检测区"
const DETECTED_PREFIX := "detected_"          # 检测到_XXX：被检测区碰到/包住的积木自动获得

# 「检测到_竖直移动」：受控积木**额外**需要本标签才能用 W/S / ↑/↓ 竖直移动。
# 一般由带 to_detect_vertical_move（待检测_竖直移动）的检测区自动赋予。
const DETECTED_VERTICAL_MOVE := "detected_vertical_move"

# 「回收站」检测键（recycle_bin）：桌面上的「回收站」积木带 to_detect_recycle_bin（待检测_回收站）
#   → 它是一块检测区；中心点进入它的积木自动获得 detected_recycle_bin（检测到_回收站）。
#   ★ 引擎本身**不对**这两个标签做特殊处理 —— "回收"这件事由事件链 / 脚本监听
#     detected_recycle_bin 自行完成（例如把积木 queue_free 掉）。登记在这里只是为了让 UI
#     把键翻译成中文（见 DETECT_KEY_NAMES），以及给 desktop.gd 拼标签时一个唯一出处。
#   ★ 它**不是**标准标签（不进 ALL）：recycle_bin 是开放检测键的一个普通取值，
#     像 vertical_move 一样由"待检测 / 检测到"两个族前缀动态组合出来。
const DETECT_KEY_RECYCLE_BIN := "recycle_bin"

const FILL_FLIP := "fill_flip"
                                  # 填充反转：**反转**朝向镜像的极性。默认（无本标签）朝左时
                                  #   视觉镜像、朝右正常；带本标签则**朝右镜像、朝左正常**。
                                  #   即「是否镜像 = (朝左) XOR (有本标签)」（见 block.gd _should_flip_visual）。
const LOCK_FACING := "lock_facing"
                                  # 锁定朝向：带本标签的积木,朝向(facing)值被固定,不受受控移动的
                                  #   A/D/←/→ 按键边沿影响（仍可用 set_facing / 属性面板手动改）。
const CUTOUT := "cutout"
                                  # 镂空遮罩：带本标签的积木**自身透明**（不带 fill 标签即不填充），
                                  #   但会「抠掉」所有**显示图层更低(display_layer 更小)**且与之重叠的积木在
                                  #   重叠区的绘制——该区域只露出最底层画面（即「电脑本身的画面」）。
                                  #   · 只隐藏 display_layer 比它小的积木；同层 / 更高层不受影响（仍正常显示）。
                                  #   · 文本框视图也按中心点是否被该遮罩覆盖来决定显隐。
                                  #   · 遮罩积木移动时，会自动通知下方更低层积木重绘（否则静态低层不会更新）。
                                  # 典型用法：只给积木 show + cutout（+ 可选 draggable / border），不写 fill。

# ---- 关卡标签（「关卡环境」用）----
# 「关卡环境」是**关卡级别**的标签集合（结构与积木的 tags 同构，都是逗号分隔的字符串集合），
# 用来描述"这个关卡具备哪些属性"。
# ★ 两类语义：
#   · **纯标注**（unit/start/end/reward）：引擎不做任何特殊处理，未来由事件链 / 脚本读取后
#     自行发挥（例如「起点」决定玩家出生点、「奖励箱」生成宝箱）。
#   · **驱动引擎行为**（allow_zoom / allow_drag）：关卡页面**直接读**它们决定摄像头能不能缩放/拖动
#     （见 blocks/level_page.gd 的 _env_allows()）。加新标签时请在这里说清是哪一类。
# ★ 不进 ALL：ALL 是**积木**标签清单（供积木的属性面板「标签选择」用）。关卡标签混进 ALL
#   会让积木也能勾到它们，语义就糊了 —— 关卡标签单独走 LEVEL_ENV_TAGS，
#   由标签选择页的 LEVEL 模式（ui/tag_picker_panel.gd Mode.LEVEL）取用。
const LEVEL_ENV_UNIT := "unit"        # 单元
const LEVEL_ENV_START := "start"      # 起点
const LEVEL_ENV_END := "end"          # 终点
const LEVEL_ENV_REWARD := "reward"    # 奖励箱
# ---- 下面两个是「驱动引擎行为」的关卡标签（关卡页摄像头，2026-10-05）----
const LEVEL_ENV_ALLOW_ZOOM := "allow_zoom"   # 允许缩放场景（载入后滚轮缩放关卡视图）
const LEVEL_ENV_ALLOW_DRAG := "allow_drag"   # 允许拖动场景（按住右键平移摄像头）
# ---- 下面六个是「关卡类型」标注标签（纯标注，驱动随机生成器分池；2026-10-14）----
const LEVEL_ENV_ENTRANCE_LEVEL := "entrance_level"   # 入口关卡：必定携带一个「关卡出口」锚点积木，一般还带一个传送门出口
const LEVEL_ENV_EXIT_LEVEL := "exit_level"           # 出口关卡：一般携带一个「关卡入口」按钮 + 一个传送门出口按钮
const LEVEL_ENV_TRAP_LEVEL := "trap_level"           # 陷阱关卡
const LEVEL_ENV_REWARD_LEVEL := "reward_level"       # 奖励关卡
const LEVEL_ENV_NORMAL_LEVEL := "normal_level"       # 普通关卡
const LEVEL_ENV_CHALLENGE_LEVEL := "challenge_level" # 挑战关卡
# 关卡环境的可选标签清单（顺序即标签选择页的展示顺序）
const LEVEL_ENV_TAGS := [
	LEVEL_ENV_UNIT, LEVEL_ENV_START, LEVEL_ENV_END, LEVEL_ENV_REWARD,
	LEVEL_ENV_ALLOW_ZOOM, LEVEL_ENV_ALLOW_DRAG,
	LEVEL_ENV_ENTRANCE_LEVEL, LEVEL_ENV_EXIT_LEVEL,
	LEVEL_ENV_TRAP_LEVEL, LEVEL_ENV_REWARD_LEVEL,
	LEVEL_ENV_NORMAL_LEVEL, LEVEL_ENV_CHALLENGE_LEVEL,
]

# 关卡组组装用的「积木锚点」标签（block 级）：标记单关的「入口/出口」位置积木。
#   · level_entrance —— 本积木是单关的「关卡入口」锚点（其中心用于和**上一关**的出口对齐）
#   · level_exit     —— 本积木是单关的「关卡出口」锚点（其中心用于和**下一关**的入口对齐）
# ★ 单关应**恰有 1 个** level_entrance + 1 个 level_exit（多个岔路会导致关卡重叠 / 路线难汇合）。
# ★ 它们进 ALL（可在积木标签选择页勾选），但不进 LEVEL_ENV_TAGS（那是关卡级标签）。
const LEVEL_BLOCK_ENTRANCE := "level_entrance"   # 关卡入口锚点（积木）
const LEVEL_BLOCK_EXIT := "level_exit"           # 关卡出口锚点（积木）

# ---- 传送门标签（动态、前缀开放，组用英文）----
# 与 autoload/portal_manager.gd 的标签约定一致。组字符串自由替换（建议英文），同组才互通：
#   portal_entrance_<组>  带此标签的积木成为「传送门入口」（积木中心即入口位置）
#   portal_exit_<组>      带此标签的积木成为「传送门出口」；入口命中后把可传送积木送过来
#   teleportable_<组>     带此标签且与某同组入口重叠的积木会被传送
# 开放键（前缀 + 任意组），**不进 ALL、不做 is_standard_tag 校验**（同 detect/button）。
# ★ 标签值一律英文（避免中文标识符 / 存档跨平台兼容问题）。
const PORTAL_ENTRANCE_PREFIX := "portal_entrance_"
const PORTAL_EXIT_PREFIX := "portal_exit_"
const PORTAL_TELEPORTABLE_PREFIX := "teleportable_"

# 传送门角色：入口 / 出口 / 可传送（用于 UI 分组）
enum PortalType { ENTRANCE, EXIT, TELEPORTABLE }

# 某标签是否为传送门标签；是则返回其 PortalType，否则返回 -1
static func portal_type(tag: String) -> int:
	if tag.begins_with(PORTAL_ENTRANCE_PREFIX):
		return PortalType.ENTRANCE
	if tag.begins_with(PORTAL_EXIT_PREFIX):
		return PortalType.EXIT
	if tag.begins_with(PORTAL_TELEPORTABLE_PREFIX):
		return PortalType.TELEPORTABLE
	return -1

static func is_portal(tag: String) -> bool:
	return portal_type(tag) >= 0

# 由传送门标签取出组字符串（非传送门标签返回空串）
static func portal_group(tag: String) -> String:
	match portal_type(tag):
		PortalType.ENTRANCE:
			return tag.substr(PORTAL_ENTRANCE_PREFIX.length())
		PortalType.EXIT:
			return tag.substr(PORTAL_EXIT_PREFIX.length())
		PortalType.TELEPORTABLE:
			return tag.substr(PORTAL_TELEPORTABLE_PREFIX.length())
	return ""

# 由「角色 + 组」拼出对应标签字符串
static func portal_tag(role: int, group: String) -> String:
	match role:
		PortalType.ENTRANCE:
			return PORTAL_ENTRANCE_PREFIX + group
		PortalType.EXIT:
			return PORTAL_EXIT_PREFIX + group
		PortalType.TELEPORTABLE:
			return PORTAL_TELEPORTABLE_PREFIX + group
	return ""

# 从一组标签里取出所有「传送门」标签（按角色 0/1/2 分成三个数组，保持出现顺序）
static func portal_tags(tag_list) -> Array:
	var out: Array = [ [], [], [] ]
	for t in tag_list:
		var s := str(t)
		if s.begins_with(PORTAL_ENTRANCE_PREFIX):
			if not (s in out[0]): out[0].append(s)
		elif s.begins_with(PORTAL_EXIT_PREFIX):
			if not (s in out[1]): out[1].append(s)
		elif s.begins_with(PORTAL_TELEPORTABLE_PREFIX):
			if not (s in out[2]): out[2].append(s)
	return out

# 一组标签里是否存在任意传送门标签
static func has_portal(tag_list) -> bool:
	for t in tag_list:
		if is_portal(str(t)):
			return true
	return false

# 「系统派生积木」标签族：带其中**任一**即代表"程序自动生成的环境内容"，玩家不该选中它。
#   · auto_generated —— 通用标记（新增系统积木时应带上；见其注释）
#   · 其余是各类系统积木的**角色标签**，历史文件里可能只有角色标签、没带 auto_generated
#     （例：block_types/BedRockX.json 的 tags 只有 collision + desktop_barrier），
#     所以判定"是否玩家积木"必须看整族，不能只看 auto_generated。
# 用途：blocks/block.gd _ensure_selectable() 的排除表（玩家积木入树补 selectable）。
const SYSTEM_TAGS := [
	AUTO_GENERATED, ALWAYS_UNSELECTABLE,
	DESKTOP_BARRIER, DESKTOP_TASKBAR, DESKTOP_ICON_BOUNDARY,
	PROGRAM_PAGE_BORDER, PROGRAM_PAGE_COVER, LEVEL_PAGE,
]

# ---- 按钮信号标签（动态、前缀开放）----
# 积木带 button_XXX（按钮_XXX）标签 → 把本积木当作「按钮」：
#   鼠标**双击**本积木（两次点击的间隔与距离均 ≤ 阈值）→ 发出名为 XXX 的信号，供事件链 /
#   脚本监听做后续行动。XXX 由使用者自由替换（如 button_start_jump / button_open_door）。
# 与检测标签一样：键是开放的，**不进 ALL、不做 is_standard_tag 校验**。
const BUTTON_PREFIX := "button_"

# 检测键的中文显示名（仅 UI 展示用；键值本身始终保持英文）
const DETECT_KEY_NAMES := {
	"vertical_move": "竖直移动",
	"recycle_bin": "回收站",
}

# 全部标准标签（用于编辑器默认 / 遍历参考）
# ★ 只含**积木**标签。物品的标签（digital_item / real_item / in_recycle_bin /
#   undeletable / deleted）不在这里 —— 它们归 Inventory.ITEM_TAGS 管，两套清单不混用
#   （「标签选择」页按（积木）/（物品）拆成两个页面，见 ui/tag_picker_panel.gd）。
# ★★ gravity / rollable **不在清单里**（2026-10-23）：受重力 / 可滚动是「积木运动」面板的字段，
#   不再是标签；旧存档里残留的这两个标签在积木入树时被剥离（见 block.gd _strip_legacy_motion_tags）。
const ALL := ["show", "border", "fill", "fill_image", "collision", "text", "child_follow", "draggable", "selectable", "always_unselectable", "controlled", "commandable", "desktop_barrier", "desktop_taskbar", "desktop_icon_boundary", "desktop_icon", "program_page_border", "program_page_cover", "auto_generated", "level_page", "detected_vertical_move", "fill_flip", "lock_facing", "cutout", "level_entrance", "level_exit"]

# 标签选择页（ui/tag_picker_panel.gd）**不列出来**的标签：程序自动生成的环境积木所带的
# 「角色标签」（桌面屏障 / 任务栏屏障 / 图标边界 / 图标层 / 页面边框 / 页面覆盖 / 关卡页面）
# 以及通用标记 auto_generated。
# ★ 理由：它们是系统派生标记 —— 玩家既不参与添加，也没有频繁增删的需要。列在勾选框里只会
#   把真正可用的「能力型」标签（draggable / selectable / controlled / commandable …）淹掉；
#   而且误勾上一个（例如 auto_generated）会让这块积木被当成系统内容（存档不保存 / 不可选）。
# ★ 只影响「可选项清单」：若某积木**已经**带了这些标签，标签选择页仍会把它列出来
#   （见 tag_picker_panel._rebuild_rows 的第二轮：当前标签集里的非族标签一律展示），
#   以免出现"标签明明挂在积木上、选择页却既看不到也删不掉"。
const PICKER_HIDDEN := [
	DESKTOP_BARRIER, DESKTOP_TASKBAR, DESKTOP_ICON_BOUNDARY,
	PROGRAM_PAGE_BORDER, PROGRAM_PAGE_COVER, AUTO_GENERATED, LEVEL_PAGE,
]
# ★ 批次 58：DESKTOP_ICON **不在此列** —— 它除了当图层名，还是「松手对齐桌面图标」的
#   能力标签，玩家应当能给任意积木加上/去掉（如把自制图标粘到桌面网格上）。

# 标准标签的「中文显示名」——仅用于 UI 展示与文档；
# 标签值本身始终保持英文（避免中文标识符 / 存档兼容问题）。
const DISPLAY_NAMES := {
	"show": "显示",
	"border": "边框",
	"fill": "填充",
	"fill_image": "图片填充",
	"collision": "碰撞",
	"text": "文本",
	"child_follow": "跟随父级",
	"draggable": "可拖动",
	"selectable": "可被选中",
	"always_unselectable": "始终不可选",
	"controlled": "受控状态",
	"commandable": "可命令",
	"desktop_barrier": "桌面屏障",
	"desktop_taskbar": "桌面任务栏屏障",
	"desktop_icon_boundary": "桌面图标边界",
	"desktop_icon": "桌面图标（层·对齐）",
	"program_page_border": "程序页面（边框）",
	"program_page_cover": "程序页面（覆盖）",
	"auto_generated": "系统自动生成",
	"level_page": "关卡页面",
	"detected_vertical_move": "检测到_竖直移动",
	"fill_flip": "填充反转",
	"lock_facing": "锁定朝向",
	"cutout": "镂空遮罩",
	# 关卡环境标签（关卡页面「关卡环境」输入框用；不是积木标签）
	"unit": "单元",
	"start": "起点",
	"end": "终点",
	"reward": "奖励箱",
	"allow_zoom": "允许缩放场景",
	"allow_drag": "允许拖动场景",
	# 关卡组组装：积木锚点 + 关卡类型（2026-10-14）
	"level_entrance": "关卡入口（锚点）",
	"level_exit": "关卡出口（锚点）",
	"entrance_level": "入口关卡",
	"exit_level": "出口关卡",
	"trap_level": "陷阱关卡",
	"reward_level": "奖励关卡",
	"normal_level": "普通关卡",
	"challenge_level": "挑战关卡",
}

# 取标准标签的中文显示名（非标准标签原样返回）。
# ★ 动态检测标签（待检测_XXX / 检测到_XXX）会被翻译成"中文前缀 + 键的中文名"，
#   例如 to_detect_vertical_move → 「待检测_竖直移动」。
# ★ 传送门标签（portal_entrance_组 / portal_exit_组 / teleportable_组）→ 「角色·组」。
static func display_name(tag: String) -> String:
	if DISPLAY_NAMES.has(tag):
		return str(DISPLAY_NAMES[tag])
	var pt := portal_type(tag)
	if pt >= 0:
		var g := portal_group(tag)
		match pt:
			PortalType.ENTRANCE:
				return "传送门入口·" + g
			PortalType.EXIT:
				return "传送门出口·" + g
			PortalType.TELEPORTABLE:
				return "可传送·" + g
		return tag
	var k := pending_detect_key(tag)
	if not k.is_empty():
		return "待检测_" + detect_key_display(k)
	if tag.begins_with(DETECTED_PREFIX):
		return "检测到_" + detect_key_display(tag.substr(DETECTED_PREFIX.length()))
	if tag.begins_with(BUTTON_PREFIX):
		return "按钮_" + detect_key_display(tag.substr(BUTTON_PREFIX.length()))
	return tag

# 检测键的中文显示名（未登记的原样返回）
static func detect_key_display(key: String) -> String:
	return str(DETECT_KEY_NAMES.get(key, key))

# ---- 检测标签工具 ----

## 某标签是否为「待检测_XXX」；是则返回 XXX，否则返回空串
static func pending_detect_key(tag: String) -> String:
	if tag.begins_with(DETECT_PENDING_PREFIX):
		return tag.substr(DETECT_PENDING_PREFIX.length())
	return ""

## 由 XXX 拼出「待检测_XXX」
static func pending_detect_tag(key: String) -> String:
	return DETECT_PENDING_PREFIX + key

## 由 XXX 拼出「检测到_XXX」
static func detected_tag(key: String) -> String:
	return DETECTED_PREFIX + key

## 从一组标签里取出所有「待检测_XXX」的 XXX（去重，保持出现顺序）
static func pending_detect_keys(tag_list) -> Array[String]:
	var out: Array[String] = []
	for t in tag_list:
		var k := pending_detect_key(str(t))
		if not k.is_empty() and not (k in out):
			out.append(k)
	return out

## 一组标签里是否存在任意「待检测_XXX」
static func has_pending_detect(tag_list) -> bool:
	for t in tag_list:
		if str(t).begins_with(DETECT_PENDING_PREFIX):
			return true
	return false

# ---- 按钮信号标签工具 ----

## 某标签是否为「按钮_XXX」；是则返回信号名 XXX，否则返回空串
static func button_key(tag: String) -> String:
	if tag.begins_with(BUTTON_PREFIX):
		return tag.substr(BUTTON_PREFIX.length())
	return ""

## 由信号名 XXX 拼出标签「button_XXX」
static func button_tag(key: String) -> String:
	return BUTTON_PREFIX + key

## 从一组标签里取出所有「按钮_XXX」的信号名 XXX（去重，保持出现顺序）
static func button_keys(tag_list) -> Array[String]:
	var out: Array[String] = []
	for t in tag_list:
		var k := button_key(str(t))
		if not k.is_empty() and not (k in out):
			out.append(k)
	return out

## 一组标签里是否存在任意「按钮_XXX」
static func has_button(tag_list) -> bool:
	for t in tag_list:
		if str(t).begins_with(BUTTON_PREFIX):
			return true
	return false

# ---- 动态标签族（「加号按钮」添加，后缀由使用者自由填）----
# 这些标签带开放前缀、不进 ALL、不做标准校验；「标签选择页」里以 + 按钮形式添加，
# 而非勾选框。顺序即 UI 展示顺序。注意 detected_vertical_move 是标准标签，不归入「检测到」族。
const TAG_FAMILIES := [
	{ "prefix": PORTAL_ENTRANCE_PREFIX, "label": "传送门入口" },
	{ "prefix": PORTAL_EXIT_PREFIX, "label": "传送门出口" },
	{ "prefix": PORTAL_TELEPORTABLE_PREFIX, "label": "可传送" },
	{ "prefix": BUTTON_PREFIX, "label": "按钮" },
	{ "prefix": DETECT_PENDING_PREFIX, "label": "待检测" },
	{ "prefix": DETECTED_PREFIX, "label": "检测到" },
]

## 某标签是否属于「需 + 按钮添加」的动态标签族（detected_vertical_move 是标准标签，不算）
static func is_family_tag(tag: String) -> bool:
	return not family_prefix(tag).is_empty()

## 取标签所属动态标签族的前缀（非族标签返回空串）
static func family_prefix(tag: String) -> String:
	if is_portal(tag):
		match portal_type(tag):
			PortalType.ENTRANCE:
				return PORTAL_ENTRANCE_PREFIX
			PortalType.EXIT:
				return PORTAL_EXIT_PREFIX
			PortalType.TELEPORTABLE:
				return PORTAL_TELEPORTABLE_PREFIX
	if not button_key(tag).is_empty():
		return BUTTON_PREFIX
	if not pending_detect_key(tag).is_empty():
		return DETECT_PENDING_PREFIX
	if tag.begins_with(DETECTED_PREFIX) and tag != DETECTED_VERTICAL_MOVE:
		return DETECTED_PREFIX
	return ""

# 新建积木时默认开启的标签（其余按需手动添加）
const DEFAULT_ON := ["show", "border", "fill", "text"]

# 判断是否为已知标准标签
static func is_standard_tag(name: String) -> bool:
	return name in ALL
