# block_layers.gd
# 「碰撞图层」集合的标准图层名。
#
# 与「标签」(block_tags.gd) 的区别：
#   标签      → 控制"某组属性是否生效"（画不画边框、受不受重力…）
#   碰撞图层  → 控制"谁能挡住谁"：两个积木只有 collision_layer 集合**存在公共元素**时才会互相碰撞。
#
# 本文件只做「命名空间 + 校验」，不持有状态。
class_name BlockLayers
extends RefCounted

# ---- 标准图层（值用英文串，避免中文标识符问题）----
const DEFAULT := "default"      # 默认层：绝大多数积木都在本层，互相阻挡
const DRAGGING := "dragging"    # 被拖动中：**正在被鼠标拖动的积木临时切到本层**
                                #   普通积木（只有 default）与它无交集 → 不阻挡正在被拖动的积木；
                                #   若某个积木的图层里也写上 dragging，它就会阻挡被拖动的积木。
                                #   ★ 本层不是空集：被拖动积木仍具备碰撞体（只是换了层），
                                #     所以"有的挡得住、有的挡不住"可以按需配置。

# ---- 环境层（系统生成积木用的"分层"层名）----
# 用途：让积木可以呈现出不同"层"。设定里：桌面（含图标）始终在最下面，各程序页面在其上。
#   语法与普通层一致（集合有公共元素才互相阻挡）；这些层默认只与它们各自标记的积木互为同类参照，
#   普通积木因为还带着 default，所以仍然会与它们碰撞（行为同改前一致，只是能力上多了"分层"）。
const DESKTOP_ICON := "desktop_icon"            # 桌面图标（层）：桌面图标边界积木所在层。
                                                #   桌面图标恒在桌面层，位于所有程序页面的下面。
const PROGRAM_PAGE_BORDER := "program_page_border"  # 程序页面（边框）：程序窗口四边框积木所在层。
const PROGRAM_PAGE_COVER := "program_page_cover"    # 程序页面（覆盖）：程序窗口的整页半透明覆盖积木所在层。
                                                #   它只用于视觉遮挡（显示层高于桌面内容），不阻挡普通积木
                                                #   （很干净地独立一层 ↔ 与 default 无交集）。

# ---- 功能层（靠"独占一层"实现"不阻挡普通积木"的层名）----
# 用途：让积木在不阻挡任何普通积木的前提下扮演一个「角色」。做法就是把该层**独占地**给这类积木用：
#   该层不出现在普通积木的 collision_layer 里，于是两者图层集合无交集 → 互不碰撞。
#   （环境层里的 PROGRAM_PAGE_COVER 是同一思路的另一例：那条是"视觉遮挡"、本条是"几何检测"。）

# 检测区（层）：带 to_detect_XXX（待检测_XXX）的检测区积木所在层。
#   ★ 与 default **无交集** → 普通积木不被检测区积木阻挡，可以自由"走进去 / 拖进去" ——
#     这正是检测标签判定的前提：判据是"对方**中心点**落在检测区内"（见 block.gd::_detect_scan），
#     若检测区积木会把对方挡住，中心就永远进不去，检测标签也就永远加不上。
#   ★ 反过来，检测区积木也不会被普通积木挡住，所以它可以被拖到桌面上任意位置。
#   ★ 想让某块积木"挡住检测区"：把它的 collision_layer 写成"default,detect_zone"（或只写 detect_zone）。
const DETECT_ZONE := "detect_zone"

# ---- 编号图层（1 ~ 30）----
# 用途：给使用者一组「现成的、够用的」自定义层名额 —— 直接写 "1"、"7"、"23" 即可，
#       不必再自己发明层名。语义与其它层完全一样（集合有公共元素才互相阻挡）。
# ★「桌面屏障」(desktop_barrier) 的碰撞图层 = 编号层 1~30 + default + dragging + detect_zone 的
#   **全集**，所以不管积木落在哪一层、是否正在被拖动，都挡得住它（见 barrier_layers()）。
const NUMBERED_MIN := 1
const NUMBERED_MAX := 30

# 全部标准图层（用于编辑器提示 / 遍历参考）
const ALL := ["default", "dragging", "desktop_icon", "program_page_border", "program_page_cover", "detect_zone"]

# 编号图层 1~30（"1" … "30"）
static func numbered() -> PackedStringArray:
	var out: PackedStringArray = []
	for i in range(NUMBERED_MIN, NUMBERED_MAX + 1):
		out.append(str(i))
	return out

# 是否为编号图层（1~30 的十进制整数字符串）
static func is_numbered(layer: String) -> bool:
	if not layer.is_valid_int():
		return false
	var n := int(layer)
	return n >= NUMBERED_MIN and n <= NUMBERED_MAX

# 全部标准图层 = 基础层 + 编号层
static func all() -> PackedStringArray:
	var out: PackedStringArray = []
	for n in ALL:
		out.append(str(n))
	out.append_array(numbered())
	return out

# 「桌面屏障」专用的图层全集：编号 1~30 + 默认 + 被拖动中 + 检测区。
# 顺序：1..30, default, dragging, detect_zone
# ★ 检测区必须在这里，否则"带 gravity 的检测区积木"会直接穿出屏幕外、再也找不回来：
#   检测区积木刻意不带 default（带了就会挡住普通积木、检测标签永远加不上），
#   于是屏障若不认 detect_zone 这一层，两者图层集合就没有公共元素 = 屏障拦不住它。
#   （桌面屏障是**唯一**把积木留在屏内的机制 —— _can_move_to 不做任何屏幕夹取。）
static func barrier_layers() -> PackedStringArray:
	var out := numbered()
	out.append(DEFAULT)
	out.append(DRAGGING)
	out.append(DETECT_ZONE)
	return out

# 「桌面图标边界」图层：默认 + 桌面图标。桌面（含图标）恒在下层，普通积木仍与其碰撞。
static func icon_boundary_layers() -> PackedStringArray:
	return PackedStringArray([DEFAULT, DESKTOP_ICON])

# 「程序页面边框」图层：默认 + 程序页面(边框)。积木落在页面上边框而不下落。
static func program_page_border_layers() -> PackedStringArray:
	return PackedStringArray([DEFAULT, PROGRAM_PAGE_BORDER])

# 「程序页面覆盖」图层：仅程序页面(覆盖)——与 default 无交集，不阻挡普通积木（纯视觉遮挡）。
static func program_page_cover_layers() -> PackedStringArray:
	return PackedStringArray([PROGRAM_PAGE_COVER])

# 「检测区」图层：仅检测区(层)——与 default 无交集，不阻挡普通积木，供检测标签判定使用。
static func detect_zone_layers() -> PackedStringArray:
	return PackedStringArray([DETECT_ZONE])

# 标准图层的「中文显示名」——仅用于 UI 展示与文档；
# 图层值本身始终保持英文（避免中文标识符 / 存档兼容问题）。
const DISPLAY_NAMES := {
	"default": "默认",
	"dragging": "被拖动中",
	"desktop_icon": "桌面图标",
	"program_page_border": "程序页面（边框）",
	"program_page_cover": "程序页面（覆盖）",
	"detect_zone": "检测区",
}

# 取标准图层的中文显示名（非标准图层原样返回；编号层显示为「N 号层」）
static func display_name(layer: String) -> String:
	if DISPLAY_NAMES.has(layer):
		return str(DISPLAY_NAMES[layer])
	if is_numbered(layer):
		return "%s 号层" % layer
	return layer

# 判断是否为已知标准图层（基础层 或 编号层）
static func is_standard_layer(name: String) -> bool:
	return name in ALL or is_numbered(name)
