# the words/world_page.gd
# 「世界」页面 —— 宏观世界的 3D 舞台（3D 落在桌面窗口内嵌的 SubViewport 里）。
#
# ★ 复用「关卡 / 家园」页面的 UI 外壳：窗口面板 + 左上角移动把柄 + 右下角缩放把柄 + 顶栏标题（× 关闭）。
#   ★ 「世界节点」列表 = **左侧延伸界面**（与「背包」的「按种类筛选」侧栏同款）：
#     它是 body 的**第一个子节点**，点开合按钮就地显隐 ⇒ 面板整体**向左**加宽、
#     舞台列（含顶栏的移动把柄与 × 关闭）的**屏幕位置完全不动**（见 _relayout）。
#     · 列表行 = 图标 + 名称 + 展开/折叠按钮（按层级缩进）；
#     · **右键**列表里的节点 → 弹右键菜单，菜单按钮再决定锚定谁（原来 = 右键即直接锚定）。
#
# ★ 层级：由 desktop 挂在 CanvasLayer(99)（与关卡/家园页同一层）→ 页面是「世界表面」，
#   不跟随设置里的 UI 缩放。
#
# ★ 第十四轮新增「星体铭牌」：每颗**有实体**的星体（radius > 0）在它圆面**正下方**挂一块名称框。
#   铭牌 = `_stage_view` 上的 Control 浮层（_plate_layer），位置每帧按相机投影算（见 _update_plates）；
#   它 **mouse_filter = IGNORE（不吃鼠标）**，于是右键/中键拖动（旋转或平移）在铭牌上照样成立；
#   右键落在铭牌上的判定由舞台输入按矩形自测（_plate_at），而不是让铭牌自己吃事件
#   —— 铭牌与 3D 容器是**兄弟节点**，一旦它 STOP，事件冒泡到不了 3D 容器，拖动会整体失灵。
#
# 操作：3D 舞台内 —— ★ 第十七轮：**左键不再锚定**（用户判定「左键点星体就锚定」是本不该存在的行为），
#   左键现在只「吃掉事件」（原地点一下不会穿透到桌面），锚定 / 解除锚定全部走下面这条路：
#   ★ 第十四轮改：**右键铭牌** / **右键「世界节点」列表行** → 弹右键菜单
#     （「锚定到 <名称>」 / 「解除锚定（自由视角）」），由菜单按钮改变锚定目标。
#     右键在铭牌上**单击** = 弹菜单（抬起时「按下→抬起」位移 < PLATE_CLICK_SLOP 才算单击）；
#     按住**拖动**（含从铭牌上起拖）= 平移，保持原样。
#   锚定后 = **卫星视角**：拖动绕该星体转、滚轮只改距离（不平移太阳系），可一直贴到星体跟前（不穿模）；
#   未锚定时：右键/中键拖动 = 自由平移、滚轮 = 拉近推远（向上滚 = 拉近）。
#   「反转滚轮」/「反转鼠标」两个开关在设置页·世界页里（落盘 settings.json，打开世界页时读取）。
class_name WorldPage
extends Control

# 面板大小上下限（与关卡页/家园页同口径：最小 = 分辨率 × 0.5）
const MIN_SCREEN_RATIO: float = 0.5
const MIN_W_FLOOR: float = 300.0
const MIN_H_FLOOR: float = 200.0
const MAX_W_FLOOR: float = 1600.0
const MAX_H_FLOOR: float = 1000.0
const PADDING: float = 12.0
const BODY_SEP: float = 12.0
const LIST_W: float = 220.0        # 「世界节点」列表宽度
## ★ 第二十三轮：「节点内容（含节点属性）」= 右侧延伸列，宽度与左侧「世界节点」**对称**（同宽）。
const CONTENT_W: float = 220.0
## 左键**点选城市**的容差：标识半尺寸之外再给这么多像素（随标识缩放，见 _pick_city）
const CITY_PICK_SLOP: float = 6.0
const STAGE_PAD: float = 8.0       # 舞台内浮层与舞台边缘的间距
const ROW_INDENT: float = 14.0     # 每深一级缩进的像素
const ICON_SIZE: float = 20.0      # 列表行图标边长

# 星体铭牌（3D 舞台上的名称框浮层）
const PLATE_GAP_PX: float = 6.0             # 铭牌上边缘与星体圆面之间的间距（px）
const PLATE_EDGE_MARGIN: float = 24.0       # 星体投影中心出舞台这么多像素 → 该铭牌隐藏
const PLATE_MAX_OFFSET_RATIO: float = 0.42  # 贴脸时轮廓半径会撑满画面 → 「下线偏移」封顶 = 舞台高 × 该值
const PLATE_CLICK_SLOP: float = 4.0         # 右键「按下→抬起」位移小于它才算**单击**（弹菜单），否则算拖动
const PLATE_RADIUS: int = 6                 # 铭牌圆角
## 铭牌底：`Color(1,1,1,0.16)` = UIStyle 的 FILL_DEFAULT ⇒ glass_box 记「default 角色 + 0.16 比例」，
## 换主题 / 换主题色（含量子全息）时**自动重映射**（与页面底板同一套配色逻辑）。
const PLATE_FILL: Color = Color(1.0, 1.0, 1.0, 0.16)
## 锚定高亮色（列表行 / 铭牌同一金色）。
const ANCHOR_TEXT: Color = Color(1.0, 0.84, 0.36)

## ★ 第十五轮：铭牌的「贴近退场 / 被星体阻挡 / 淡入淡出」。
const PLATE_HIDE_RATIO: float = 3.0     # 相机到星体距离 < 半径 × 该值 → 隐藏该铭牌（与 WorldView.TRAIL_HIDE_RATIO 同口径）
const PLATE_FADE_SPEED: float = 12.0    # 铭牌淡入/淡出速率（1/秒，指数插值、帧率无关；≈0.15s 收敛）
const PLATE_VISIBLE_EPS: float = 0.02   # 透明度低于它 ⇒ visible = false（不再绘制）
const PLATE_CLICK_ALPHA: float = 0.5    # 透明度低于它 ⇒ 不吃右键（半隐的铭牌不该被点中）
const PLATE_OCCLUDE_RATIO: float = 0.5  # 被更近星体圆面盖住的采样比例 > 它 ⇒ 判定「被星体阻挡」（见 _occluded_ratio）

## ---- 城市标识 / 铭牌（第二十轮：全量 ~4.5 万座 ⇒ 分级门控 + 池化 + 屏幕格子去重）----
## ★ 第二十二轮 512 → **1024**：最贴的距离（1.08R）在人口最密的恒河平原实测有 ~734 座城市同时应显示，
##   512 装不下（实测 30 帧里 29 帧打满）⇒「谁上屏」要靠舍弃决定；扩容后最密区也装得下。
##   ★ 槽位是**常数**个节点、且「已完全淡出」的空槽每帧直接跳过 ⇒ 代价只落在**真正用到的**槽位上。
const CITY_POOL_SIZE: int = 1024       # 标识 / 铭牌**池**大小 —— 节点数是**常数**，与城市数无关
const CITY_MARK_SIZE: float = 20.0     # 城市标识 Control 的方形边长（px，与 CityMarker.BOX_SIZE 一致）
const CITY_PLATE_GAP: float = 8.0      # 铭牌与标识之间的间距（px）
## ★ 三档渲染门槛 —— 判据统一用「**地表球在屏幕上的半径**」(= 放大倍数):
##   ① 星标 / 双圈（首都 · 特大）= 屏幕半径 ≥ CITY_ALWAYS_MIN_PX 才渲染；
##      铭牌另有 90→130px 的淡入门控；
##   ② 圈内点（大档 300~1000万）= 屏幕半径 ≥ CITY_MEDIUM_MIN_PX 才渲染（**标识 + 铭牌一起**）；
##   ③ 单圈（小档 <300万，量全在它身上）= 屏幕半径 ≥ CITY_SMALL_MIN_PX，
##      且**只收镜头正对的一小块**（CITY_SMALL_CAP_DEG）—— 这就是「离得足够近才渲染」的实现。
## ★ ① 的门控是**第二十一轮补上**的：原来这一档**完全没有任何距离判据**（「只要朝向镜头就渲染」）
##   ⇒ 缩到全景视距时地球在屏幕上只剩亚像素，星标却照样画在原地 ⇒ 用户反馈「首府类城市无论
##   摄像头放多远都显示」。
## ★ 为什么取 30 而不是更大的值：门控必须在「**锚定后的默认视距**」下仍然放行 ——
##   锚定距离 = 半径 × 12（WorldView.ANCHOR_APPROACH_RATIO），此时屏幕半径 = k/12 ≈ 0.072 × 窗口高
##   （656px 高 ⇒ 47px；400px 高 ⇒ 29px）⇒ 30px 对常规窗口都成立；
##   定得再高就会出现「刚锚定过去却一座城市都没有」。
const CITY_ALWAYS_MIN_PX: float = 30.0
const CITY_PLATE_MIN_PX: float = 90.0
const CITY_PLATE_FULL_PX: float = 130.0
## ★ 第二十六轮把这两档门槛**整体提高**（用户要求「离得远只看大城市和首府，拉得很近才显示小城市」）：
##   MEDIUM 130→190（≈3.0R）、SMALL 260→350（≈1.6R）。判据仍是「地表球屏幕半径」，
##   由 `globe_px = k·R/D`（k ≈ 565）反推：190px ≈ 3.0R、350px ≈ 1.6R。
##   ⇒ 中景（3R 以外）只剩首都 / 特大（CITY_ALWAYS_MIN_PX=30 那一档），
##     小档要贴到 1.6R 以内才出现 —— 这正是用户要的「分级」观感。
## ★ 第二十八轮续再把小档从 350 提到 **460**（≈1.23R）：350 时 1.6R 就冒出小城市，
##   锚定地面后稍一拉近就满屏小圈；460 要求几乎贴到地面（1.02R~1.23R 之间才出现）。
const CITY_MEDIUM_MIN_PX: float = 190.0
const CITY_SMALL_MIN_PX: float = 460.0
## ★ 小档的帽子**故意收得很小**：4.5 万座的量全在它身上，帽一大就又回到「几千座/帧」。
##   实测：22° 时在密集区（欧洲/南亚）会摸到 6500 座、单帧 **12.7 ms** ⇒ 明显卡顿；
##   收到 14° 后候选量 ≤ ~2600（实测 < 4 ms），而 2.0R 机位下它仍覆盖盘面中心那一块。
##   要改就改这里，但记住「量 ≈ 帽面积 × 当地密度」，密度是不可控的那一半。
const CITY_SMALL_CAP_DEG: float = 14.0
## 城市越靠近地球**地平线**（N·V 越小）越淡 ⇒ 避免城市从地球边缘「啪」地跳出来 / 跳回去。
const CITY_LIMB_FADE: float = 0.18
## **屏幕格子去重**：舞台切成 CITY_SCREEN_CELL 见方的格子，一格只摆一座城市 ——
## 密集区（欧洲、印度）不再叠成一坨；同时天然给出「每帧最多画多少」的上限。
## ★ 这是**标识满尺寸（缩放 1.0×）时**的格宽；实际格宽 = 它 × 该星体这一帧的标识缩放
##   （见下面的 CITY_MARK_REF_PX）—— 格子不跟着缩放的话，远看「标识缩到 6px 却还按 14px 一格去重」
##   会白白少画一大半。
const CITY_SCREEN_CELL: float = 14.0
## ---- 标识**随放大倍数缩放**（第二十一轮：原来恒定 20px ⇒ 用户反馈「摄像头多远都一样大」）----
##   缩放 = clamp(地表球屏幕半径 / CITY_MARK_REF_PX, MIN, MAX)。
## ★ 自变量为什么用「地表球屏幕半径」：它就是本工程一直在用的「放大倍数」口径，与窗口大小无关、
##   且与相机距离单调对应（远处小、近处大），与三档门控同源 ⇒ 不会门控放行了而缩放还没动。
## ★ 上下限的取舍：下限保底 —— 再远也得是个认得出的点，且线宽不至于细到消失（0.3× ⇒ 描边 0.48px 已是下限）；
##   上限封顶 —— 贴到 1.08R 时地表铺满全屏，标识再放大就会盖住地面本身。
## ★ REF 取 110 ⇒ 缩放在「约 17R → 约 3.2R」这段里连续变化，正好把锚定默认视距（12R）包在里面
##   （地球屏幕半径 = k/距离，k = (视口高/2)/tan(fov/2) ≈ 0.866×视口高）。
const CITY_MARK_REF_PX: float = 110.0
const CITY_MARK_MIN_SCALE: float = 0.3
const CITY_MARK_MAX_SCALE: float = 1.6
## 标识 / 描边配色：用户拍板「颜色一致」⇒ 四种等级**同色**，等级靠**图形**区分（见 city_marker.gd）。
const CITY_MARK_COLOR: Color = Color(1.0, 1.0, 1.0, 0.95)
const CITY_MARK_OUTLINE: Color = Color(0.06, 0.06, 0.08, 0.9)

## ---- 第二十二轮：**时序稳定**（拖地球时铭牌不闪）+ 补位公平 + 铭牌去重加速 ----
## ★ 为什么需要「环」：池不够用时必须按某个顺序舍弃，而**遍历顺序**（5° 网格是「从低纬行扫到高纬行」）
##   会把纬度更高那一侧整片丢下（实测最密近景 30 帧里 29 帧池满 ⇒ 用户反馈「越远离赤道的城市
##   出现越迟」由此而来）。改按「离**屏幕中心**由近到远」补位 ⇒ 被舍弃的永远是画面**最外圈**，
##   出现带自然居中在屏幕中心，与用户预期一致。
const CITY_RING_PX: float = 40.0     # 环宽（px）：离屏心距离按它分环，环号小的先上屏
const CITY_RINGS: int = 12           # 环数（舞台对角 ≈ 400px ⇒ 12 × 40 已覆盖）
## ★ 铭牌去重：从「两两矩形求交」（O(n²)，最密机位上千块铭牌 ⇒ 几毫秒）改成**格子占用表**，
##   每块只查自己盖住的那十几个格子。★ 判据比精确相交**略严**（共占一格也算冲突）⇒ 密集区铭牌略少一点。
const CITY_PLATE_CELL: float = 10.0
## 槽位「已完全淡出」的判据：到这个透明度以下才算干净、可以回收（否则复用会让旧铭牌"啪"地消失）
const CITY_SLOT_DEAD_EPS: float = 0.02
## ★ 每帧最多扫描的**小档候选数**（分片预算）：最密的机位下小档候选有 5000+ 条，而每帧真正新上屏的
##   只有几十座 —— 全量扫一遍是纯浪费（实测 8 ms）。改成每帧只扫一个预算片、跨帧错开轮转：
##   新进入视野的城市最多晚 1~2 帧上屏（在 0.15s 的淡入下完全看不出来），换来密集区拖动不卡。
const CITY_SCAN_BUDGET: int = 1400

## ---- 太阳辉光（第二十轮续）----
## ★ 为什么手搓 2D 辉光、而不是开引擎的 `Environment.glow`：本工程渲染器是 **gl_compatibility**，
##   该渲染器**不支持辉光/泛光等后处理**（那是 Forward+ 的能力）。
##   所以用**浮层**做「伪辉光」：2D 控件 + 径向渐变贴图 + `BLEND_MODE_ADD`（黑背景上加色就是发光）。
## ★ 第二个关键点是**最小屏幕尺寸**：太阳本体在远处只有零点几像素（半径 109.3 单位 vs 上百万单位视距），
##   不设下限就看不见；有了下限，无论把镜头锁在哪颗星球附近，太阳都是一团显眼的光 ⇒ 满足「容易看见」。
const SUN_GLOW_SCREEN_MUL: float = 3.4      # 辉光直径 ÷ 太阳的**屏幕直径**
const SUN_GLOW_MIN_PX: float = 46.0         # 辉光**最小屏幕直径**（px）—— 「多远都看得见」靠它
const SUN_GLOW_MAX_PX: float = 1600.0       # 上限（贴到太阳跟前时别糊满全屏）
const SUN_GLOW_CORE_RATIO: float = 0.34     # 内层亮核直径 ÷ 辉光直径
const SUN_GLOW_ALPHA: float = 0.9           # 正常强度
## ★ 第二十一轮：**被挡住 = 完全看不见**（用户要求「太阳被挡住时辉光就看不见」）。
##   原值 0.34 —— 当初的取舍是「被行星挡住也找得到太阳」，结果就是地球挡得严严实实时
##   圆盘边上仍透着一圈橙光 ⇒ 与「辉光属于太阳本体」的直觉相悖。
##   取 0.0 后目标强度 = SUN_GLOW_ALPHA × (1 − 遮挡比例)：完全盖住 ⇒ 0（隐藏），
##   只被行星**掠过一部分**时按剩余可见比例线性衰减（不会因为小行星凌日就整团熄掉）。
const SUN_GLOW_OCCLUDED_ALPHA: float = 0.0  # 被别的星体挡住时仍透出的比例（0 = 挡住就看不见）
const SUN_GLOW_FADE_SPEED: float = 6.0      # 淡入淡出速率（1/秒）
## ★ 第十六轮：页面可见期间「按现实时间兜一次星体刷新」的间隔（秒）。
##   为什么要兜：页面一直开着时也会跨过整点（自转）与每月的 1 / 2 / 12 / 22 号（公转），
##   只靠「打开时刷一次」会让世界停在打开那一刻（穿帮）；60s 一次的开销可忽略。
const CELESTIAL_POLL_SEC: float = 60.0

var title_var: String = "world_title"   # 世界标题绑定的全局变量名
var _visible := false
var _celestial_acc: float = 0.0         # 「现实时间兜刷新」的累加器（见 _process）

# UI 部件
var _bg: UIPanel = null
var _body: HBoxContainer = null
var _stage_col: VBoxContainer = null   # 舞台列（顶栏 + 3D 舞台）—— 延伸列表时的**位置锚点**
var _top_bar: Control = null
var _title_label: Label = null
var _drag_handle: UIDragHandle = null
var _resize_handle: UIResizeHandle = null
var _close_btn: UIBtn = null
var _list_toggle_btn: UIBtn = null

# 3D 舞台
var _stage_view: Control = null
var _stage_cont: SubViewportContainer = null
var _sub_viewport: SubViewport = null
var _world_view: WorldView = null
var _panning := false

# 星体铭牌（3D 舞台上的 Control 浮层；纯视觉、不吃鼠标）
var _plate_layer: Control = null
var _plates: Dictionary = {}         # sid → 铭牌（PanelContainer）
var _plate_labels: Dictionary = {}   # sid → 铭牌文字（Label）
var _plate_sids: Array[String] = []  # 参与布局的 sid（= radius > 0 的星体）
var _plate_fade: Dictionary = {}     # sid → 当前透明度（0~1）；目标 1（该显示）/ 0（该隐藏），逐帧指数收敛

## ---- 城市标识 / 铭牌（第二十轮：池化）----
var _city_layer: Control = null      # 城市浮层（与 _plate_layer 同级；后建 ⇒ 画在星体铭牌之上）
## 带城市数据的星体（**数据驱动**，不写死 sid —— 世界 JSON 是通用的，引擎不该认「earth」这个字符串）。
var _city_hosts: Array[WorldNode] = []
## 池：槽位 k 的标识 / 铭牌 / 铭牌文字 / 当前透明度 / 当前挂的是哪座城市（-1 = 空）
var _city_marks: Array[CityMarker] = []
var _city_plates: Array[PanelContainer] = []
var _city_labels: Array[Label] = []
var _city_slot_fade := PackedFloat32Array()    # 标识透明度（0~1）
var _city_slot_pfade := PackedFloat32Array()   # 铭牌透明度（0~1）
var _city_slot_src := PackedInt32Array()       # 槽位当前承载的「城市下标」（-1 = 空）
## ★ 第二十二轮新增的槽位状态：
##   host  = 该槽位的城市属于**哪一颗星体**（城市下标是「每颗星体各自从 0 编」的，必须一起记）；
##   tier  = 该槽位标识**当前画的是**哪一档（档位没变就不重画 —— 原来每次换城都 configure + queue_redraw）；
##   scale = 该槽位标识当前缩放（没变就不写 Control.scale）；
##   of    = 「城市 ↔ 槽位」的**唯一**索引（键 = 星体序号 × 1000000 + 城市下标）——
##           黏滞保留靠它 O(1) 找回「这座城市上一帧挂在哪个槽位」；
##   stamp = 本帧「已保留 / 已填」的帧号戳（用比较代替每帧清 1024 个字节 —— 清表比比较贵）。
var _city_slot_host := PackedInt32Array()
var _city_slot_tier := PackedByteArray()
var _city_slot_scale := PackedFloat32Array()
var _city_slot_of: Dictionary = {}
var _city_keep_stamp := PackedInt64Array()
var _city_frame_stamp: int = 0
## 每帧复用的缓冲（**不每帧新建数组**）
var _city_buf_a := PackedInt32Array()
var _city_buf_m := PackedInt32Array()
var _city_buf_s := PackedInt32Array()
var _city_occupied := PackedByteArray()        # 屏幕格子占用表（0 = 空 / 1 = 已被占走）
## ★ 「本帧候选」标记：表按星体的城市下标开（4.5 万），但**只清 touched** ⇒ 建立与清零都是 O(候选)。
##   黏滞保留要用它回答「这座城市这一帧还算不算候选」。
var _city_cand_mark := PackedByteArray()
var _city_cand_touched := PackedInt32Array()
## ★ 本帧的 winner 集合（**不直接绑槽位**，见 _assign_city_slots）：按档位优先级顺序累积。
var _city_win_src := PackedInt32Array()
var _city_win_host := PackedInt32Array()
var _city_win_pos := PackedVector2Array()
var _city_win_v := PackedFloat32Array()
var _city_win_scale := PackedFloat32Array()
var _city_win_pgate := PackedFloat32Array()
## winner 补位用的**分环计数排序**（O(n)，不排序）与自由槽位表（分「已淡干净」/「还挂着旧城」两张）
var _city_win_ring := PackedInt32Array()
var _city_win_order := PackedInt32Array()
var _city_ring_count := PackedInt32Array()
var _city_free_dead := PackedInt32Array()
var _city_free_live := PackedInt32Array()
## 铭牌去重用的格子占用表（与舞台同尺寸，每帧清一次；跨星体共用 ⇒ 不同星体的铭牌也互相去重）
var _city_plate_occ := PackedByteArray()
var _city_plate_cols: int = 0
var _city_plate_rows: int = 0
## ★ 小档候选的**分片扫描游标**（见 CITY_SCAN_BUDGET）：每帧扫描的起点与条数，跨帧轮转
var _city_scan_off: int = 0
var _city_scan_cnt: int = 0
var _city_scan_rot: int = 0
## ★ 本帧还能上屏几座（= 池 − 已保留）；扫描凑够这个数就提前结束
var _city_new_budget: int = 0
## ★ 第二十一轮「每个格子选代表」用的旁表（**与 `_city_occupied` 同尺寸、同生命周期**）：
##   src  = 该格这一遍（同一档）暂定的城市下标，-1 = 本遍还没人认领；
##   pos  = 暂定者在屏幕上的投影点（用它算「离格心多远」，不用再存一个分数数组）；
##   v    = 暂定者的地平线淡出系数（第二遍摆位时要用）；
##   order = 本遍**第一次**认领格子的顺序（第二遍只遍历它，不扫整张格子表）。
var _city_cell_src := PackedInt32Array()
var _city_cell_pos := PackedVector2Array()
var _city_cell_v := PackedFloat32Array()
var _city_cell_order := PackedInt32Array()
## 上一帧的统计（验证 / 性能观察用）：候选数、实际绘制数、耗时 ms
var city_last_candidates: int = 0
var city_last_drawn: int = 0
var city_last_ms: float = 0.0

## ---- 太阳辉光（第二十轮续）----
var _glow_layer: Control = null          # 辉光浮层（在铭牌层**之下** ⇒ 加色辉光不糊住文字）
var _glow_halo: TextureRect = null       # 外层大光晕
var _glow_core: TextureRect = null       # 内层亮核
var _glow_sun: WorldNode = null          # 跟哪颗（**数据驱动**：取「被标记为 emissive」的那颗，不写死 sid）
var _glow_fade: float = 0.0              # 当前强度（渐入渐出）
# 锚定右键菜单（右键「世界节点」列表行 / 星体铭牌 → 弹它）
var _ctx_menu: ContextMenu = null
var _ctx_sid: String = ""            # 菜单当前对应的星体 sid
var _ctx_city_h: int = -1            # 菜单当前对应的城市（宿主下标 / 城市下标；-1 = 星体菜单）
var _ctx_city_i: int = -1
var _plate_press_sid: String = ""    # 右键按下时命中的铭牌 sid（抬起时判「单击 or 拖动」）
var _plate_press_pos: Vector2 = Vector2.ZERO

# 「世界节点」列表（body 的**左侧延伸列**，默认收起；开合只让面板向左变宽）
var _list_block: Control = null
var _list_box: VBoxContainer = null
var _list_open := false
## 上一次 _relayout 时「舞台列左侧」的占位宽度（列表贡献）→ 用于只补偿左侧增删，
## 让舞台列（含顶栏把柄 / ×）的屏幕位置在列表开合下保持恒定。
var _last_list_w: float = 0.0
var _rows: Dictionary = {}         # sid → 行控件
var _row_labels: Dictionary = {}   # sid → 名称 Label
var _expand_btns: Dictionary = {}  # sid → 展开/折叠按钮
var _expanded: Dictionary = {}     # sid → 是否展开（缺省 = 展开）
var _nodes: Array[WorldNode] = []
var _anchored_sid: String = ""

# ★ 第二十三轮：「节点内容 / 节点属性」= body 的**右侧延伸列**（body 最后一个子节点），
#   与左侧「世界节点」严格对称：左列展开时面板向左变宽，本列展开时面板**向右**变宽 ⇒ 舞台列两端都不动。
var _content_block: Control = null
var _content_toggle_btn: UIBtn = null
var _content_open := false
var _last_content_w: float = 0.0
# 选中态：**城市** = {星体序号, 城市下标}（★ 不记槽位号 —— 槽位每帧都可能换城，见 _update_city_marks）
var _sel_host: int = -1
var _sel_city: int = -1
var _sel_prev_slot: int = -1     # 上一帧挂着选中城市的槽位（用来把选择环从旧槽位挪到新槽位）
## ---- 玩家位置标记（第三十轮：倒置红色三角形，指向玩家在地球上的位置）----
var _player_mark: CityMarker = null       # 玩家位置标识（倒三角）
var _player_fade: float = 0.0             # 当前透明度（0~1，淡入淡出用）
const PLAYER_MARK_COLOR: Color = Color(0.95, 0.15, 0.15, 0.95)   # 红色
const PLAYER_MARK_OUTLINE: Color = Color(0.06, 0.06, 0.08, 0.9)  # 深色描边（与城市标识同款）
const PLAYER_FADE_SPEED: float = 8.0      # 淡入淡出速率（比铭牌稍快，因为只有一个标记）
# 「节点内容」里的 8 个值 Label（顺序 = 名称 / 纬度 / 经度 / 海拔 / 人口密度 / 气候 / 当地时间 / 上级节点），
# 只在选中变化时刷新
var _sel_rows: Array[Label] = []
## ★ 第二十八轮续 7：「视图模式」下拉（俯瞰视图 / 时区视图 / 人口密度 / 气候分布）。
##   它只管**3D 舞台的表现**（地表叠加），不改任何数据。
var _view_mode_btn: OptionButton = null
var _view_mode: int = 0           # 0 = 俯瞰视图（默认，无叠加）/ 1 = 时区 / 2 = 人口密度 / 3 = 气候分布
## ★ 第二十九轮「关注」：被关注的城市挂进「世界节点」列表的宿主行下面。
##   · key = "<宿主 sid>:g<gnid>"（真实城市）/ "<宿主 sid>:p<lat>,<lon>"（没有 gnid 的虚构城市，按坐标定位）
##   · 只存**关注顺序的 key 表**（settings.json 的 world_followed_cities，与具体存档无关）——
##     序号/对象都在运行时按 key 反查 ⇒ 城市表扩容 / 编辑不会把关注指到别的城。
##   · `_followed` 的 value = { "h": _city_hosts 下标, "i": 城市下标 }（构树时解析一次）。
var _followed: Dictionary = {}
var _follow_keys: Array = []
var _followed_rows: Dictionary = {}     # key -> MarginContainer（列表行；每次重建列表时重填）
var _followed_labels: Dictionary = {}   # key -> Label（选中高亮用）
var _follow_btn: UIBtn = null           # 「节点内容」里的关注 / 取消关注按钮
var _city_press_key: String = ""        # 右键按下时命中的城市 key（抬起时判「单击 or 拖动」）
var _city_press_h: int = -1
var _city_press_i: int = -1
var _city_press_pos: Vector2 = Vector2.ZERO
var _ctx_city_key: String = ""          # 右键菜单当前作用的城市 key
const FOLLOW_SETTING_KEY := "world_followed_cities"
## ★ 第二十四轮：「节点属性」= **独立窗口**（照「积木属性」），由本页懒加载创建（随页面一起隐藏）
var _prop_panel: NodePropertyPanel = null
var _prop_btn: UIBtn = null
## ★ 第二十五轮：「可用操作」整块（含「编辑节点属性」按钮与其说明）—— **仅调试模式可见**
var _ops_block: VBoxContainer = null

# ---- 右下角摄像机缩放条（第二十八轮续 3 / 4 改竖直）----
## 竖直滑条值 0 = 底端「远」、1 = 顶端「近」（与「向上滚 = 拉近」同一直觉）；
## 内部换算成 WorldView 的**分段线性**视距：上半截 = 最近~1.10R，下半截 = 1.10R~7R。
var _zoom_panel: PanelContainer = null
var _zoom_slider: VSlider = null
var _zoom_readout: Label = null
var _zoom_syncing := false          # 程序写滑条值时置位，避免 value_changed 反写相机造成抖动
var _zoom_dragging := false         # 用户正按住滑条 ⇒ 本帧不要用相机值覆盖它

# origin 与 Control.position 互通：桌面按场景坐标给页面定位
var origin: Vector2:
	set(v):
		position = v
	get:
		return position


func _ready() -> void:
	# 同 LevelPage / HomePage：页面根 IGNORE，页面内的交互由内部控件自己接（3D 舞台容器 STOP）。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	# ★ 铭牌位置要逐帧按相机投影算；页面隐藏时不必算（与 _world_view.set_process 同一套开关）。
	set_process(false)


# ---------------- 面板尺寸上下限（随分辨率动态算）----------------

func min_page_size() -> Vector2:
	var s := _screen_size()
	return Vector2(maxf(s.x * MIN_SCREEN_RATIO, MIN_W_FLOOR), maxf(s.y * MIN_SCREEN_RATIO, MIN_H_FLOOR))


func max_page_size() -> Vector2:
	var s := _screen_size()
	return Vector2(maxf(s.x, MAX_W_FLOOR), maxf(s.y, MAX_H_FLOOR))


func _screen_size() -> Vector2:
	var s := DisplayServer.screen_get_size()
	var f := UIStyle.canvas_scale(self)
	return Vector2(float(s.x) / maxf(f.x, 0.0001), float(s.y) / maxf(f.y, 0.0001))


func _clamp_size(v: Vector2) -> Vector2:
	var mn := min_page_size()
	var mx := max_page_size()
	return Vector2(clampf(v.x, mn.x, mx.x), clampf(v.y, mn.y, mx.y))


# ---------------- 搭页面 ----------------

func build(title_var_name: String = "world_title") -> void:
	title_var = title_var_name
	_clear()
	_build_ui()
	size = _clamp_size(size)
	_build_world()
	_refresh_title()
	if not GlobalVars.changed.is_connected(_on_var_changed):
		GlobalVars.changed.connect(_on_var_changed)
	print("[WorldPage] 世界页面已生成 pos=%s size=%s 标题变量=%s" % [str(position), str(size), title_var])


func is_page_visible() -> bool:
	return _visible


func set_page_visible(on: bool) -> void:
	_visible = on
	visible = on
	if not on:
		_panning = false
		_plate_press_sid = ""
		_close_anchor_menu()             # 页面藏起来时菜单也要收（否则会留在别的界面上）
		if _world_view != null and is_instance_valid(_world_view):
			_world_view.end_grab(false)   # 隐藏时不要留下惯性
			_world_view.cancel_inertia()
	# 每次打开都同步设置页·世界页的「反转滚轮 / 反转鼠标」
	if on:
		_refresh_invert_flags()
		# ★ 每次打开世界页都按现实时间刷新一次星体位置 / 朝向：玩家可能离线多日、甚至跨过 1 号 / 2 号 /
		#   12 号 / 22 号 —— 打开页面时「该更新了就补更新」，免得世界停在旧位置而穿帮（见 WorldTime）。
		_celestial_acc = 0.0
		if _world_view != null and is_instance_valid(_world_view):
			_world_view.refresh_celestial()
	# ★ 铭牌布局只在页面可见时跑（见 _process）。
	set_process(on)
	# 页面隐藏时不跑 3D：停渲染 + 停镜头跟随（零开销）
	if _sub_viewport != null and is_instance_valid(_sub_viewport):
		_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	if _world_view != null and is_instance_valid(_world_view):
		_world_view.set_process(on)
	if MousePassRunner.is_enabled():
		MousePassRunner.force_refresh()
	print("[WorldPage] 世界页面 → %s" % ("显示" if on else "隐藏"))


func toggle_page_visible() -> void:
	set_page_visible(not _visible)


# ---------------- 建 3D 世界 + 建节点列表 ----------------

func _build_world() -> void:
	_world_view = WorldView.new()
	_world_view.name = "WorldView"
	_world_view.anchor_changed.connect(_on_anchor_changed)
	_sub_viewport.add_child(_world_view)
	_world_view.setup()
	_world_view.set_view_mode(_view_mode)
	_refresh_invert_flags()

	_nodes = _world_view.nodes
	_anchored_sid = _world_view.get_camera_anchor_sid()
	GlobalVars.set_var(title_var, _world_view.world_name)

	# ★ 第二十九轮：城市宿主表（_city_hosts）要先建好 —— 「关注」列表要在构树时按 key 反查宿主/序号。
	_build_city_marks()
	_build_list()
	_build_plates()
	_refresh_anchor_marks()
	_set_list_open(false)
	_set_content_open(false)
	# ★ 第二十四轮：城市名不接翻译表（真源是数据文件的多语言列）⇒ 换语言时自己重贴屏上铭牌
	if not TranslationManager.language_changed.is_connected(_on_language_changed):
		TranslationManager.language_changed.connect(_on_language_changed)
	# ★ 第二十五轮：编辑入口（「可用操作」区）**仅调试模式可见** ⇒ 跟着 Debug 模式开关走
	if not Debug.mode_changed.is_connected(_on_debug_mode_changed):
		Debug.mode_changed.connect(_on_debug_mode_changed)
	_apply_debug_visibility()
	_sync_zoom_slider()


func _build_list() -> void:
	for ch in _list_box.get_children():
		_list_box.remove_child(ch)
		ch.queue_free()
	_rows.clear()
	_row_labels.clear()
	_expand_btns.clear()
	_followed_rows.clear()
	_followed_labels.clear()
	# ★ 第二十九轮：**不再清 _expanded** —— 关注 / 取消关注会重建列表，展开状态必须保留。

	for entry in _ordered_nodes():
		var n: WorldNode = entry["node"]
		var depth := int(entry["depth"])
		var row := _build_row(n, depth)
		_list_box.add_child(row)
		_rows[n.sid] = row
		# ★ 第二十九轮：把关注到本星体上的城市行紧跟宿主行插入（「挂在父节点之下」）。
		for key in _follow_keys:
			var ref: Dictionary = _followed.get(key, {})
			if ref.is_empty():
				continue
			var h := int(ref.get("h", -1))
			if h < 0 or h >= _city_hosts.size() or _city_hosts[h].sid != n.sid:
				continue
			var city_row := _build_followed_city_row(str(key), h, int(ref.get("i", -1)), depth + 1)
			_list_box.add_child(city_row)
			_followed_rows[str(key)] = city_row
	_refresh_expand_buttons()
	_sync_row_visibility()


## 深度优先展开成 (节点, 深度) 序列 → 列表顺序 = 世界树顺序。
func _ordered_nodes() -> Array:
	var out: Array = []
	for n in _nodes:
		if n.parent_node == null:
			_collect(n, 0, out)
	return out


func _collect(n: WorldNode, depth: int, out: Array) -> void:
	out.append({"node": n, "depth": depth})
	for c in _sorted_children(n):
		_collect(c, depth + 1, out)


## 子节点按**离太阳的距离**升序（sort_radius，缺省 = orbit_radius）→ 列表把谷神星/灶神星/…
## 按真实远近**穿插**进行星序列（与 JSON 的书写顺序无关）。
## ★ 只排**显示顺序**，不动 n.child_nodes 本身（3D 里的父子关系不变）。
func _sorted_children(n: WorldNode) -> Array:
	var arr: Array = n.child_nodes.duplicate()
	arr.sort_custom(func(a: WorldNode, b: WorldNode) -> bool:
		return a.sort_radius < b.sort_radius)
	return arr


## 一行 = 缩进 + [展开/折叠按钮] + 图标 + 名称。
## ★ 行容器 mouse_filter = STOP → 右键落在行上（含按钮以外的任何位置）都能锚定。
func _build_row(n: WorldNode, depth: int) -> Control:
	var margin := MarginContainer.new()
	margin.name = "Row_" + n.sid
	margin.add_theme_constant_override("margin_left", int(float(depth) * ROW_INDENT))
	margin.custom_minimum_size = Vector2(0.0, ICON_SIZE + 6.0)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.gui_input.connect(_on_row_gui_input.bind(n.sid))
	margin.add_child(row)

	if n.child_nodes.is_empty():
		var sp := Control.new()
		sp.custom_minimum_size = Vector2(22.0, 22.0)
		sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(sp)
	else:
		var eb := UIBtn.new()
		eb.set_id("exp_" + n.sid)
		eb.custom_minimum_size = Vector2(22.0, 22.0)
		eb.pressed_id.connect(_on_expand_pressed)
		row.add_child(eb)
		_expand_btns[n.sid] = eb

	row.add_child(_make_icon(n))

	var lb := _make_label(n.display_name, UIStyle.FONT_SIZE, Color.WHITE)
	lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lb)
	_row_labels[n.sid] = lb
	return margin


## 行图标：优先用该星体的贴图（当前 = 素材库的地球贴图），取不到贴图就用实例色方块。
func _make_icon(n: WorldNode) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var tex: Texture2D = null
	if not n.texture_path.is_empty():
		tex = TextureCache.fetch(n.texture_path)
	if tex != null:
		var tr := TextureRect.new()
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(tr)
	else:
		var cr := ColorRect.new()
		cr.set_anchors_preset(Control.PRESET_FULL_RECT)
		cr.color = n.color
		cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(cr)
	return holder


# ---------------- 「关注」城市（第二十九轮） ----------------

## 「世界节点」列表里的**关注城市行**：缩进 = 宿主星体深度 + 1，行首一颗金色星标。
## ★ 行本身 mouse_filter = STOP ⇒ 左键选中、右键弹「关注 / 取消关注」菜单（与星体行同一套交互习惯）。
func _build_followed_city_row(key: String, h: int, i: int, depth: int) -> Control:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", int(float(depth) * ROW_INDENT))
	margin.custom_minimum_size = Vector2(0.0, ICON_SIZE + 6.0)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.gui_input.connect(_on_city_row_gui_input.bind(key))
	margin.add_child(row)

	# 与星体行的「展开按钮」同宽的空位 ⇒ 图标 / 名称纵向对齐
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(22.0, 22.0)
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(sp)

	var star := _make_label("★", UIStyle.FONT_SIZE, ANCHOR_TEXT)
	star.custom_minimum_size = Vector2(ICON_SIZE, 0.0)
	star.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	star.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	star.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(star)

	var ci: CityIndex = _city_hosts[h].city_index
	var nm := "—"
	if ci != null and i >= 0 and i < ci.total:
		nm = ci.display_name(i)
	var lb := _make_label(nm, UIStyle.FONT_SIZE, Color.WHITE)
	lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lb.clip_text = true
	lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lb)
	_followed_labels[key] = lb
	return margin


func _on_city_row_gui_input(ev: InputEvent, key: String) -> void:
	if not (ev is InputEventMouseButton):
		return
	var mb := ev as InputEventMouseButton
	if not mb.pressed:
		return
	match mb.button_index:
		MOUSE_BUTTON_LEFT:
			_select_followed_key(key)
			accept_event()
		MOUSE_BUTTON_RIGHT:
			var ref: Dictionary = _followed.get(key, {})
			if not ref.is_empty():
				_open_city_menu(int(ref.get("h", -1)), int(ref.get("i", -1)))
			accept_event()


## 城市的**稳定关注键**：优先 gnid（真实城市为正、虚构城市为负，0 = 没有 ID），
## 没有 ID 时退回经纬度。★ 不存序号：城市表扩容 / 重排后序号会漂，键不会。
func _city_follow_key(host: WorldNode, i: int) -> String:
	var ci: CityIndex = host.city_index
	if ci == null or i < 0 or i >= ci.total:
		return ""
	var g := int(ci.gnids[i])
	if g != 0:
		return "%s:g%d" % [host.sid, g]
	var ll := CityIndex.dir_to_latlon(ci.dirs[i])
	return "%s:p%.4f,%.4f" % [host.sid, ll.x, ll.y]


func _is_followed(h: int, i: int) -> bool:
	if h < 0 or h >= _city_hosts.size():
		return false
	return _followed.has(_city_follow_key(_city_hosts[h], i))


## 从 settings.json 读关注表 → 解析成 (宿主下标, 城市下标)。只保留还能找到的城市（城市表换掉也不报错）。
func _load_followed() -> void:
	_followed.clear()
	_follow_keys.clear()
	var raw: Variant = SaveManager.get_app_settings().get(FOLLOW_SETTING_KEY, [])
	if not (raw is Array):
		return
	var want: Dictionary = {}
	for k in (raw as Array):
		want[str(k)] = true
	if want.is_empty():
		return
	for h in range(_city_hosts.size()):
		var host: WorldNode = _city_hosts[h]
		var ci: CityIndex = host.city_index
		if ci == null:
			continue
		for i in range(ci.total):
			var key := _city_follow_key(host, i)
			if not key.is_empty() and want.has(key) and not _followed.has(key):
				_followed[key] = { "h": h, "i": i }
	for k in (raw as Array):
		var key := str(k)
		if _followed.has(key):
			_follow_keys.append(key)
	print("[WorldPage] 关注城市已载入：%d 座" % _follow_keys.size())


func _save_followed() -> void:
	var arr: Array = []
	for k in _follow_keys:
		arr.append(str(k))
	SaveManager.save_app_settings({ FOLLOW_SETTING_KEY: arr })


## 关注 / 取消关注：写盘 + 刷新按钮 + 选中高亮 + 重建「世界节点」列表（城市行要插到宿主下面）。
func _toggle_follow(h: int, i: int) -> void:
	if h < 0 or h >= _city_hosts.size():
		return
	var key := _city_follow_key(_city_hosts[h], i)
	if key.is_empty():
		return
	if _followed.has(key):
		_followed.erase(key)
		_follow_keys.erase(key)
	else:
		_followed[key] = { "h": h, "i": i }
		_follow_keys.append(key)
		_set_list_open(true)     # 关注后直接展开列表，让玩家看到它挂上去了
	_save_followed()
	_refresh_follow_btn()
	if _list_box != null and is_instance_valid(_list_box):
		_build_list()
		_refresh_anchor_marks()
	_refresh_selected_marks()


func _on_follow_pressed(_id: String) -> void:
	if _sel_host >= 0:
		_toggle_follow(_sel_host, _sel_city)


func _refresh_follow_btn() -> void:
	if _follow_btn == null or not is_instance_valid(_follow_btn):
		return
	var has := _sel_host >= 0 and _sel_host < _city_hosts.size() and _sel_city >= 0
	(_follow_btn as UIBtn).disabled = not has
	if not has:
		(_follow_btn as UIBtn).set_label("关注")
		return
	(_follow_btn as UIBtn).set_label("取消关注" if _is_followed(_sel_host, _sel_city) else "关注")


## 关注行的选中高亮（金色）—— 与锚定高亮同色，一眼看出「当前选中的是它」。
func _refresh_selected_marks() -> void:
	for key in _followed_labels.keys():
		var lb = _followed_labels.get(key, null)
		if lb == null or not is_instance_valid(lb):
			continue
		var ref: Dictionary = _followed.get(key, {})
		var on := int(ref.get("h", -2)) == _sel_host and int(ref.get("i", -2)) == _sel_city
		(lb as Label).add_theme_color_override("font_color", ANCHOR_TEXT if on else Color.WHITE)


func _select_followed_key(key: String) -> void:
	var ref: Dictionary = _followed.get(key, {})
	if ref.is_empty():
		return
	_select_city(int(ref.get("h", -1)), int(ref.get("i", -1)))
	_set_list_open(true)


# ---------------- 列表交互 ----------------

## 右键行 → 弹右键菜单（菜单里的按钮再决定锚定谁 / 解除）；左键行不做任何事。
## ★ 原来是「右键行 = 直接把镜头锚定到该节点」，第十四轮按用户要求改成菜单。
func _on_row_gui_input(ev: InputEvent, sid: String) -> void:
	if not (ev is InputEventMouseButton):
		return
	var mb := ev as InputEventMouseButton
	if mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
		_open_anchor_menu(sid)
		accept_event()


func _on_expand_pressed(id: String) -> void:
	var sid: String = str(id).replace("exp_", "")
	_expanded[sid] = not bool(_expanded.get(sid, true))
	_refresh_expand_buttons()
	_sync_row_visibility()


func _refresh_expand_buttons() -> void:
	for sid in _expand_btns.keys():
		var b = _expand_btns[sid]
		if b == null or not is_instance_valid(b):
			continue
		(b as UIBtn).set_label("▾" if bool(_expanded.get(sid, true)) else "▸")


## 某行可见 ⟺ 它的所有祖先都处于展开状态。
func _sync_row_visibility() -> void:
	for n in _nodes:
		var row = _rows.get(n.sid, null)
		if row == null or not is_instance_valid(row):
			continue
		var vis := true
		var p := n.parent_node
		while p != null:
			if not bool(_expanded.get(p.sid, true)):
				vis = false
				break
			p = p.parent_node
		row.visible = vis
	# ★ 第二十九轮：关注城市行还要额外看「宿主自己展开没有」——星体折叠时城市行必须一起收起。
	for key in _followed_rows.keys():
		var row2 = _followed_rows.get(key, null)
		if row2 == null or not is_instance_valid(row2):
			continue
		var ref: Dictionary = _followed.get(key, {})
		var h := int(ref.get("h", -1))
		if h < 0 or h >= _city_hosts.size():
			continue
		var host: WorldNode = _city_hosts[h]
		var vis2 := bool(_expanded.get(host.sid, true))
		var p2 := host.parent_node
		while p2 != null:
			if not bool(_expanded.get(p2.sid, true)):
				vis2 = false
				break
			p2 = p2.parent_node
		row2.visible = vis2


# ---------------- 星体铭牌（3D 舞台上的名称框浮层） ----------------
#
# ★ 为什么是 **Control 浮层**而不是 3D 里的 Label3D：铭牌要求 ① 屏幕字号恒定、② 星体**圆面正下方**、
#   ③ 用项目既有的玻璃底/描边样式 —— 三条都只有「每帧把星体投影成屏幕坐标、再摆一个 2D 控件」能满足。
# ★ 坐标 1:1：相机在 SubViewport 里，SubViewportContainer 是 `stretch = true` + 全矩形 ⇒
#   `WorldView.project_point()` 返回的视口坐标**就是**舞台 Control 的局部坐标（也是
#   `_on_stage_gui_input` 里 mb.position 的那套坐标）⇒ 两者可直接比较（见 _plate_at）。

## 为每颗**有实体**的星体（radius > 0）建一块铭牌：圆角玻璃底 + 白字（带深色描边）。
## ★ 只建、不摆 —— 位置每帧由 _update_plates() 按屏幕投影算。
## ★ 容器节点（如「小行星带」，radius = 0）不挂铭牌：它钉在太阳原点、没有圆面，「圆面下方」无从谈起。
func _build_plates() -> void:
	if _plate_layer == null or not is_instance_valid(_plate_layer):
		return
	for ch in _plate_layer.get_children():
		_plate_layer.remove_child(ch)
		ch.queue_free()
	_plates.clear()
	_plate_labels.clear()
	_plate_sids.clear()
	_plate_fade.clear()   # 新牌子从透明度 0 开始 → 页面刚打开时整体淡入
	for n in _nodes:
		if n.radius <= 0.0:
			continue
		var plate := PanelContainer.new()
		plate.name = "Plate_" + n.sid
		# ★ 不吃鼠标：判定改由 _on_stage_gui_input 按矩形自测（见 _plate_at）。
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := UIStyle.glass_box(PLATE_FILL, UIStyle.BORDER, PLATE_RADIUS, 1)
		sb.content_margin_left = 6.0
		sb.content_margin_right = 6.0
		sb.content_margin_top = 1.0
		sb.content_margin_bottom = 1.0
		plate.add_theme_stylebox_override("panel", sb)
		# 名称直接用 JSON 的 `name`（= display_name）—— 按既定决策，星体译名不走 UI 翻译表。
		var lb := _make_label(n.display_name, UIStyle.FONT_SIZE, Color.WHITE)
		lb.add_theme_color_override("font_outline_color", UIStyle.TEXT_OUTLINE)
		lb.add_theme_constant_override("outline_size", UIStyle.TEXT_OUTLINE_SIZE)
		plate.add_child(lb)
		plate.visible = false
		_plate_layer.add_child(plate)
		plate.reset_size()   # 立刻取到最小尺寸（非容器父节点下，Control.size 会被夹到 min size）
		_plates[n.sid] = plate
		_plate_labels[n.sid] = lb
		_plate_sids.append(n.sid)


func _process(delta: float) -> void:
	_update_plates(delta)
	_update_sun_glow(delta)
	_update_city_marks(delta)
	_update_player_mark(delta)
	_update_zoom_slider()
	# ★ 页面可见期间每 CELESTIAL_POLL_SEC 兜一次现实时间刷新：页面一直开着时也会跨过整点（自转）
	#   与每月的 1 / 2 / 12 / 22 号（公转），不兜的话位置会停在打开那一刻而穿帮（见 WorldTime）。
	_celestial_acc += delta
	if _celestial_acc >= CELESTIAL_POLL_SEC:
		_celestial_acc = 0.0
		if _world_view != null and is_instance_valid(_world_view):
			_world_view.refresh_celestial()


## 每帧把铭牌摆到各星体圆面**正下方**（页面可见时才跑，见 _ready / set_page_visible 的 set_process）。
## ★ 可见性不再硬切：本函数只决定「这一帧该不该显示」（want），真正的显隐由 _step_plate_fade 平滑收敛
##   ⇒ 铭牌的出现 / 退场（被挡住、贴近、出屏、被去重）都有 0.15s 的淡入淡出。
func _update_plates(delta: float) -> void:
	if _plate_layer == null or not is_instance_valid(_plate_layer):
		return
	if _world_view == null or not is_instance_valid(_world_view):
		return
	var stage := _stage_view.size
	var cam := _world_view.camera_position()
	var discs := _screen_discs(cam)
	var placed: Array[Rect2] = []
	for sid_v in _plate_order():
		var sid := str(sid_v)
		var plate: Control = _plates.get(sid, null) as Control
		if plate == null or not is_instance_valid(plate):
			continue
		var n: WorldNode = _world_view.node_by_sid(sid)
		var rect := Rect2()
		var want := false
		# ★ 第二十八轮：外表被隐藏的星体（地心世界里的地球）不挂铭牌 —— 它会悬在空洞正中挡视线。
		#   反过来，**内部**节点（地心太阳 / 反地面）在地球外表可见时也不挂铭牌 ——
		#   它们本来就被地球挡在里面，铭牌却会穿过球体浮在夜面上（实测很刺眼）。
		var show_plate := n != null and not n.outer_hidden
		if show_plate and not n.interior_of.is_empty():
			var host_n: WorldNode = _world_view.node_by_sid(n.interior_of)
			show_plate = host_n != null and host_n.outer_hidden
		if show_plate and n != null:
			var r: Variant = _plate_rect(n, plate, stage, discs, cam)
			if r != null:
				rect = r as Rect2
				want = true
		if want:
			# ★ 重叠去重：按 _plate_order() 的顺序占位，与已占住的矩形相交者**隐藏**。
			#   全景视距下内圈星体在屏幕上挤成一团，不去重就是一坨字叠在一起。
			#   ★ 被遮挡 / 被隐藏的铭牌**不占位**（它本来就不显示，不该把邻居顶掉）。
			for q in placed:
				if q.intersects(rect):
					want = false
					break
			if want:
				placed.append(rect)
				plate.position = rect.position
		_step_plate_fade(sid, plate, want, delta)


# ---------------- 城市标识 / 铭牌（第二十轮：池化 + 分级门控 + 屏幕格子去重）----------------

## 建「城市标识 / 铭牌**池**」（只建一次，大小 = CITY_POOL_SIZE，循环复用）。
## ★ 为什么是池：全量 4.5 万座不可能一城一个 Control ⇒ **节点数是常数**；
##   每帧只把「这一帧该画的城市」分配到槽位里，没分到的槽位淡出隐藏。
func _build_city_marks() -> void:
	if _city_layer == null or not is_instance_valid(_city_layer):
		return
	for ch in _city_layer.get_children():
		_city_layer.remove_child(ch)
		ch.queue_free()
	_city_marks.clear()
	_city_plates.clear()
	_city_labels.clear()
	_city_hosts.clear()
	_city_slot_fade.resize(CITY_POOL_SIZE)
	_city_slot_pfade.resize(CITY_POOL_SIZE)
	_city_slot_src.resize(CITY_POOL_SIZE)
	_city_slot_host.resize(CITY_POOL_SIZE)
	_city_slot_tier.resize(CITY_POOL_SIZE)
	_city_slot_scale.resize(CITY_POOL_SIZE)
	_city_keep_stamp.resize(CITY_POOL_SIZE)
	_city_slot_of.clear()
	for k in range(CITY_POOL_SIZE):
		_city_slot_fade[k] = 0.0
		_city_slot_pfade[k] = 0.0
		_city_slot_src[k] = -1
		_city_slot_host[k] = -1
		_city_slot_tier[k] = 255        # 255 = 「还没画过任何档位」⇒ 首次赋城市时必然 configure 一次
		_city_slot_scale[k] = -1.0
		_city_keep_stamp[k] = -1
		var mark := CityMarker.new()
		mark.visible = false
		_city_layer.add_child(mark)
		_city_marks.append(mark)
		var plate := PanelContainer.new()
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := UIStyle.glass_box(PLATE_FILL, UIStyle.BORDER, PLATE_RADIUS, 1)
		sb.content_margin_left = 6.0
		sb.content_margin_right = 6.0
		sb.content_margin_top = 1.0
		sb.content_margin_bottom = 1.0
		plate.add_theme_stylebox_override("panel", sb)
		var lb := _make_label("", UIStyle.FONT_SIZE, Color.WHITE)
		lb.add_theme_color_override("font_outline_color", UIStyle.TEXT_OUTLINE)
		lb.add_theme_constant_override("outline_size", UIStyle.TEXT_OUTLINE_SIZE)
		plate.add_child(lb)
		plate.visible = false
		_city_layer.add_child(plate)
		plate.reset_size()
		_city_plates.append(plate)
		_city_labels.append(lb)
	for n in _nodes:
		if n.city_index != null and n.city_index.total > 0:
			_city_hosts.append(n)
	# ★ 第二十九轮：宿主表就绪后立刻把「关注」解析成 (宿主, 城市下标)，再构树时挂到宿主行下面。
	_load_followed()
	print("[WorldPage] 城市池已建：%d 槽位；带城市的星体 %d 个" % [CITY_POOL_SIZE, _city_hosts.size()])
	# ★ 第三十轮：玩家位置标记 —— 复用城市标识的 CityMarker，画倒置红色三角形。
	_build_player_mark()


## ★ 第三十轮：建玩家位置标记（一个独立的 CityMarker，不参与城市池）。
##   挂在 _city_layer 上 ⇒ 与城市标识同层、同样随放大倍数缩放。
func _build_player_mark() -> void:
	if _city_layer == null or not is_instance_valid(_city_layer):
		return
	if _player_mark != null and is_instance_valid(_player_mark):
		_city_layer.remove_child(_player_mark)
		_player_mark.queue_free()
	_player_mark = CityMarker.new()
	_player_mark.configure(CityMarker.TIER_PLAYER, PLAYER_MARK_COLOR, PLAYER_MARK_OUTLINE)
	_player_mark.visible = false
	_city_layer.add_child(_player_mark)
	_player_fade = 0.0
	print("[WorldPage] 玩家位置标记已建")


## ★ 第二十九轮：反地面（凹面内壁）是不是「当前真正可见的世界」——
##   它声明了 `interior_of`，只有宿主（地球）的外表被藏起来（= 镜头锚定了地心世界里的节点）时，
##   3D 里才看得见这层内壁；否则它被地球外壳包着，2D 城市标识绝不能浮到地球正面来。
func _inner_world_visible(host: WorldNode) -> bool:
	if host.interior_of.is_empty():
		return true
	if _world_view == null or not is_instance_valid(_world_view):
		return false
	var hn: WorldNode = _world_view.node_by_sid(host.interior_of)
	return hn != null and hn.outer_hidden


## 每帧把「这一帧该画的城市」摆到池槽位上。
## ★ 第二十二轮把算法从「每帧从头重建一份屏幕格子表」改成**时序稳定**的：
##   ① **黏滞**：上一帧就在屏上的城市，只要这一帧仍有效（档位门控内 + 朝向镜头 + 仍落舞台内）
##      就**原地留着** —— 位置 / 透明度连续推进，不重设文字、不归零透明度；
##   ② 只有**新进入视野**的城市才申请空槽位、从 0 淡入（这才是淡入该发生的地方）；
##   ③ 池不够用时按「离**屏幕中心**由近到远」补位 ⇒ 被舍弃的永远是画面最外圈；
##   ④ 同格的去重由「已在屏上的城市先占」⇒ 相邻城市不再互相顶掉。
## 为什么必须这么改：原实现里槽位的**位置序号**就是身份（本帧第 k 个格子 → 第 k 个槽位），
##   于是任何一个格子进出画面都会让后面所有格子整体移位 —— 实测拖动一帧槽位换掉 82%~96%
##   ⇒ 全屏铭牌反复归零重淡入（闪烁），且每帧几百次文字重排 + 容器 relayout（密集区 19~25 ms/帧
##   = 用户感到的卡顿）。
## 档位优先级不变：首都/特大 → 大档 → 小档（新城市的补位顺序即优先级）。
func _update_city_marks(delta: float) -> void:
	if _city_layer == null or not is_instance_valid(_city_layer) or _city_hosts.is_empty():
		return
	if _world_view == null or not is_instance_valid(_world_view):
		return
	var t0 := Time.get_ticks_usec()
	var cam := _world_view.camera_position()
	var stage := _stage_view.size
	_city_prepare_plate_grid(stage)
	# ★ 城市投影走快路径（见 WorldView.prepare_projection）：几千个点逐个走 unproject_position 太贵
	_world_view.prepare_projection()
	_city_win_src.clear()
	_city_win_host.clear()
	_city_win_pos.clear()
	_city_win_v.clear()
	_city_win_scale.clear()
	_city_win_pgate.clear()
	_city_frame_stamp += 1

	var used := 0
	var cands := 0
	for h in range(_city_hosts.size()):
		var host := _city_hosts[h]
		var ci: CityIndex = host.city_index
		if ci == null or ci.total <= 0:
			continue
		# ★ 第二十八轮：宿主的外表被隐藏时（镜头在地心世界里）不再投影它的城市 ——
		#   否则会有一堆标识浮在空洞中，且它们本来就跟着被藏起来的地表壳走。
		if host.outer_hidden:
			continue
		# ★ 第二十九轮：反地面（凹面内壁）只有「宿主外表已被藏起、我们真的进到地心世界」时才投影城市 ——
		#   否则从外面看地球时，它们会作为 2D 浮层飘在地球正面上（3D 里它们被地表壳完全挡住）。
		if host.inner_surface and not _inner_world_visible(host):
			continue
		if host.body_mi == null or not is_instance_valid(host.body_mi):
			continue
		var globe_px := _world_view.screen_radius_of(host)
		# ★ 距离门控（三档共用的地基）：地球在屏幕上已经小到一个点 ⇒ 这颗星体这一帧一座城市都不画。
		#   不画 = 不保留任何槽位 ⇒ 槽位走淡出循环自然退场（不会硬闪）。
		if globe_px < CITY_ALWAYS_MIN_PX:
			continue
		# 标识缩放 + 随之变化的去重格宽（格子必须跟着标识一起缩，见 CITY_SCREEN_CELL 注释）
		var m_scale := clampf(globe_px / CITY_MARK_REF_PX, CITY_MARK_MIN_SCALE, CITY_MARK_MAX_SCALE)
		var cell := CITY_SCREEN_CELL * m_scale
		var cols := int(ceil(stage.x / cell))
		var rows := int(ceil(stage.y / cell))
		var cell_n := cols * rows
		if _city_occupied.size() != cell_n:
			# 换了格子数 ⇒ 旁表一起重建；`src` 必须填 -1（0 会被当成「0 号城市已占这格」）
			_city_occupied.resize(cell_n)
			_city_cell_src.resize(cell_n)
			_city_cell_src.fill(-1)
			_city_cell_pos.resize(cell_n)
			_city_cell_v.resize(cell_n)
		_city_occupied.fill(0)
		_city_cell_order.clear()
		# 铭牌门控（放大倍数）：< MIN 全隐、≥ FULL 全显、之间线性 ramp
		var plate_gate := 0.0
		if globe_px >= CITY_PLATE_FULL_PX:
			plate_gate = 1.0
		elif globe_px > CITY_PLATE_MIN_PX:
			plate_gate = (globe_px - CITY_PLATE_MIN_PX) / (CITY_PLATE_FULL_PX - CITY_PLATE_MIN_PX)
		# 相机在**地球局部系**里的方向 = 视窗中心那条半径（小档的帽子以它为中心）
		var to_cam := cam - host.global_position
		var cam_local := (host.body_mi.global_transform.basis.transposed() * to_cam).normalized()
		# ★ 第二十九轮：内壁（反地面）可见的是**远侧**球面 ⇒ 一切「朝向镜头」的方向判断都要取反。
		#   用 look_dir 代替 cam_local 传下去：帽子 / 小档点乘 / 候选收集全都在「远侧」半球里算。
		var look_dir := -cam_local if host.inner_surface else cam_local
		var want_medium := globe_px >= CITY_MEDIUM_MIN_PX
		var want_small := globe_px >= CITY_SMALL_MIN_PX
		# ★ 小档的帽子取**自适应**值：CITY_SMALL_CAP_DEG 是上限，实际按「舞台看到的那一小块 + 余量」收窄。
		#   为什么：最贴的 1.08R 下舞台只看得见中心 ±2.7°，而 14° 帽会收进近万座、其中九成投影到画外
		#   —— 每座一次世界变换 + 投影，实测白烧十几毫秒/帧（这就是密集区拖动卡顿的主因）。
		#   超集性质：舞台帽用「半对角」反解 ⇒ 凡投影落进舞台的城市必在帽内（不会漏城）。
		var cap_deg := maxf(6.0, minf(CITY_SMALL_CAP_DEG, _stage_cap_deg(host, look_dir, stage) + 3.0))
		var cap_cos := cos(deg_to_rad(cap_deg))

		# ① 收候选：三档各自的下标表 / 网格。★ 门控关掉的档必须**显式清空**，
		#   否则下面会拿上一帧的旧表（旧实现是「关掉就不调用」，buffers 自然残留）。
		ci.collect_always(look_dir, 180.0, _city_buf_a)
		if want_medium:
			ci.collect_medium(look_dir, 180.0, _city_buf_m)
		else:
			_city_buf_m.clear()
		if want_small:
			ci.collect_small(look_dir, cap_deg, _city_buf_s)
		else:
			_city_buf_s.clear()
		cands += _city_buf_a.size() + _city_buf_m.size() + _city_buf_s.size()

		# ② 候选标记（建立 O(候选)、清零也 O(候选) —— 4.5 万的城市表绝不能整表 memset；
		#   循环**内联**而不是每条约一次函数调用，5 千候选下这一步的调用开销就有 2 ms）
		_city_cand_begin(ci)
		for i in _city_buf_a:
			if _city_cand_mark[i] == 0:
				_city_cand_mark[i] = 1
				_city_cand_touched.append(i)
		for i in _city_buf_m:
			if _city_cand_mark[i] == 0:
				_city_cand_mark[i] = 1
				_city_cand_touched.append(i)
		for i in _city_buf_s:
			if _city_cand_mark[i] == 0:
				_city_cand_mark[i] = 1
				_city_cand_touched.append(i)

		# ③ 黏滞保留（顺带占住它们所在的屏幕格子 ⇒ 第 ④ 步的新城市不能顶掉它们）
		used += _keep_city_slots(h, host, ci, look_dir, cam, stage, cols, rows, cell, m_scale,
			plate_gate, globe_px, cap_cos, host.inner_surface, delta)

		# ④ 其余候选 → 每格一个代表 → 记进本帧 winner 集合（槽位分配统一放最后，见 _assign_city_slots）
		#   ★ 池已满 ⇒ 黏滞的城市已经占满全部槽位、后面一座也放不进来 ⇒ 连候选扫描都省掉
		#     （最密机位实测 30 帧里有 29 帧都处于这个状态）。
		if used < CITY_POOL_SIZE:
			# ★ 本帧「还差几座才算满」：空槽位数 = 池 − 已保留。凑够了就提前结束扫描（见 _city_place_new）——
			#   每帧真正能上屏的只有「这一帧空出来的那些槽位」（实测几十座），扫满几千条纯属浪费。
			_city_new_budget = CITY_POOL_SIZE - used
			_city_place_new(h, ci, _city_buf_a, host, stage, cam, look_dir, cap_cos, cols, rows, cell, m_scale,
				plate_gate, false, host.inner_surface)
			if want_medium:
				_city_place_new(h, ci, _city_buf_m, host, stage, cam, look_dir, cap_cos, cols, rows, cell, m_scale,
					plate_gate, false, host.inner_surface)
			if want_small:
				_city_place_new(h, ci, _city_buf_s, host, stage, cam, look_dir, cap_cos, cols, rows, cell, m_scale,
					plate_gate, true, host.inner_surface)
		_city_cand_end()

	# ⑤⑥ 补位：winner 按「离屏幕中心由近到远」填进自由槽位（池不够时舍弃的是画面外圈）
	used = _assign_city_slots(used, stage, delta)
	# ⑦ 这一帧没被用到的槽位 → 淡出（淡干净了才真正回收 = 解除「城市 ↔ 槽位」的绑定）
	_release_city_slots(delta)
	# ⑧ 选择环跟着「选中城市所在的槽位」走（选中城市换槽位 / 出屏时自动跟过去 / 摘掉）
	_update_sel_ring()

	city_last_candidates = cands
	city_last_drawn = used
	city_last_ms = float(Time.get_ticks_usec() - t0) / 1000.0


# ---------------- 候选标记（只动 touched ⇒ 建立与清零都是 O(候选)）----------------

func _city_cand_begin(ci: CityIndex) -> void:
	if _city_cand_mark.size() != ci.total:
		_city_cand_mark.resize(ci.total)
		_city_cand_mark.fill(0)
		_city_cand_touched.clear()   # 换了表 ⇒ 旧的 touched 下标已无意义


func _city_cand_end() -> void:
	for i in _city_cand_touched:
		_city_cand_mark[i] = 0
	_city_cand_touched.clear()


# ---------------- ③ 黏滞保留 ----------------

## 上一帧挂在槽位上的城市，只要这一帧**仍然有效**（档位门控过 + 朝向镜头 + 仍落在舞台内）
## 就原地留着：位置 / 缩放 / 透明度连续推进，**不重设文字、不归零透明度**。
## ★ 这就是「拖动时铭牌不再反复从低透明度淡入」的关键 —— 城市与槽位是**按身份绑定**的，
##   而不是按「本帧第几个格子」绑定。
## 返回被保留的槽位数（计入绘制量）。
func _keep_city_slots(h: int, host: WorldNode, ci: CityIndex, cam_local: Vector3, cam: Vector3,
		stage: Vector2, cols: int, rows: int, cell: float, m_scale: float, plate_gate: float,
		globe_px: float, cap_cos: float, inner: bool, delta: float) -> int:
	var kept := 0
	var want_small := globe_px >= CITY_SMALL_MIN_PX
	# ★ 内壁（反地面）的「可见面」是远侧：把朝向判据整体取反（见 _update_city_marks 的 look_dir）。
	var face := -1.0 if inner else 1.0
	for k in range(CITY_POOL_SIZE):
		var i := _city_slot_src[k]
		if i < 0 or _city_slot_host[k] != h:
			continue
		var tier := ci.tiers[i]
		var pos := Vector2.ZERO
		var v := 1.0
		if tier == CityIndex.TIER_SMALL:
			# 小档候选已被限制在「镜头正对的小帽子」里 ⇒ 必然朝向镜头、也不会贴地平线（省掉两次点乘）
			if not want_small or ci.dirs[i].dot(cam_local) < cap_cos:
				continue
			pos = _world_view.project_point_fast(host.city_world_pos(i))
		else:
			var need := CITY_ALWAYS_MIN_PX if tier <= CityIndex.TIER_METRO else CITY_MEDIUM_MIN_PX
			if globe_px < need:
				continue
			var wpos := host.city_world_pos(i)
			if _world_view.is_point_behind(wpos):
				continue
			var to_c := cam - wpos
			if to_c.length_squared() <= 1e-12:
				continue
			v = smoothstep(0.0, CITY_LIMB_FADE,
				face * (wpos - host.global_position).normalized().dot(to_c.normalized()))
			if v <= 0.02:
				continue
			pos = _world_view.project_point_fast(wpos)
		if not pos.is_finite():
			continue                       # 相机背后（快路径以 INF 表示）
		var cx := int(floor(pos.x / cell))
		var cy := int(floor(pos.y / cell))
		if cx < 0 or cy < 0 or cx >= cols or cy >= rows:
			continue
		# 占住这一格（后到的候选在同格里会被 _city_place_new 跳过 ⇒ 相邻城市不再互相顶掉）
		_city_occupied[cy * cols + cx] = 1
		# 已保留 ⇒ 从候选标记里摘掉，第 ④ 步不再把它当新城市重复占格
		_city_cand_mark[i] = 0
		_place_city_slot(k, h, ci, i, pos, v, m_scale, plate_gate, stage, delta)
		kept += 1
	return kept


# ---------------- ④ 新城市 → 每格一个代表 → winner 集合 ----------------

## 把一批**新**候选按「每格一个代表」选出 winner，记进本帧 winner 集合（**不直接绑槽位**）。
## ★ 格子内外原本是「按 list 顺序一格一城」（胜负取决于遍历顺序），第二十一轮改成
##   「同格里**离格心最近**者胜」（胜负只取决于几何位置）；第二十二轮保留该规则，
##   但**已在屏上的城市（黏滞）优先占格**，不再参与竞争。
## `pre_visible`：候选已被限制在「镜头正对的小帽子」里 ⇒ 跳过「背后剔除 + 地平线淡出」两笔开销。
func _city_place_new(h: int, ci: CityIndex, list: PackedInt32Array, host: WorldNode, stage: Vector2,
		cam: Vector3, cam_local: Vector3, cap_cos: float, cols: int, rows: int, cell: float, m_scale: float,
		plate_gate: float, pre_visible: bool, inner: bool) -> void:
	if list.is_empty():
		return
	# ★ 内壁（反地面）远侧可见 ⇒ 朝向判据取反（与 _keep_city_slots 同一套）。
	var face := -1.0 if inner else 1.0
	# ★ 分片轮转（只对「量大的小档」）：每帧只扫一个预算片、起点跨帧错开 ⇒ 每帧成本被钉在预算内。
	#   新进入视野的城市最多晚 1~2 帧上屏（0.15s 淡入下看不出来），换密集区拖动不卡。
	var n := list.size()
	if pre_visible and n > CITY_SCAN_BUDGET:
		_city_scan_cnt = CITY_SCAN_BUDGET
		if _city_scan_rot >= n:
			_city_scan_rot = 0
		_city_scan_off = _city_scan_rot
		_city_scan_rot += CITY_SCAN_BUDGET
	else:
		_city_scan_off = 0
		_city_scan_cnt = n
	_city_cell_order.clear()
	# ★ 还差几座才算满：本档的扫描一旦凑够这个数就停（再扫也放不下，纯浪费）。
	var budget := _city_new_budget - _city_win_src.size()
	if budget <= 0:
		return
	# ---- 第一遍：候选 → 「每格的暂定代表」（O(n)，不排序）----
	for j in range(_city_scan_off, mini(_city_scan_off + _city_scan_cnt, n)):
		if _city_cell_order.size() >= budget:
			break                          # 已凑够本帧能上屏的数量
		var i := list[j]
		if _city_cand_mark[i] == 0:
			continue                       # 已被黏滞保留（它自己那一格已占）
		# ★ 先做一次「点乘预筛」：不在舞台帽内的直接丢（一次点乘 ≈ 0.2µs，省掉后面 ~1.5µs 的变换+投影）。
		#   ★ **只对已被帽子限制的小档**用（`pre_visible`）—— 首府 / 大档一共才 310 座，
		#     它们的规则是「可见半球都画」（不同档不该共用同一个帽子，否则盘边上的星标会整片消失）。
		if pre_visible and ci.dirs[i].dot(cam_local) < cap_cos:
			continue
		var wpos := host.city_world_pos(i)
		var v := 1.0
		if not pre_visible:
			var to_cam := cam - wpos
			v = 0.0
			if to_cam.length_squared() > 1e-12:
				v = smoothstep(0.0, CITY_LIMB_FADE,
					face * (wpos - host.global_position).normalized().dot(to_cam.normalized()))
			if v <= 0.02:
				continue
		var pos := _world_view.project_point_fast(wpos)
		if not pos.is_finite():
			continue                       # 相机背后
		# ★ 用 `floor` 而不是 `int()`：GDScript 的 `int()` 向零取整 ⇒ 左/上边缘外一点的负坐标
		#   会被算成 0 号格，白收一个画在屏幕外的标识。
		var cx := int(floor(pos.x / cell))
		var cy := int(floor(pos.y / cell))
		if cx < 0 or cy < 0 or cx >= cols or cy >= rows:
			continue
		var idx := cy * cols + cx
		if _city_occupied[idx] != 0:
			continue                       # 这一格已被更高档位 / 已被保留的城市占走
		if _city_cell_src[idx] == -1:
			# 本档这一格还没人认领 ⇒ 我就是暂定代表
			_city_cell_src[idx] = i
			_city_cell_pos[idx] = pos
			_city_cell_v[idx] = v
			_city_cell_order.append(idx)
		else:
			# 同档竞争：谁离格心近谁代表这一格（与「谁先被遍历到」无关）
			var cc := Vector2((float(cx) + 0.5) * cell, (float(cy) + 0.5) * cell)
			if pos.distance_squared_to(cc) < _city_cell_pos[idx].distance_squared_to(cc):
				_city_cell_src[idx] = i
				_city_cell_pos[idx] = pos
				_city_cell_v[idx] = v
	# ---- 第二遍：每格的胜出者 → 本帧 winner 集合 ----
	for j in _city_cell_order:
		var idx := int(j)
		var i := _city_cell_src[idx]
		# 先读走胜出者、再把「暂定」标记还回去 —— 不还的话下一档会把这一格的旧主
		# 误当成自己这一遍的暂定者，把上一档的格子抢走。
		_city_cell_src[idx] = -1
		_city_occupied[idx] = 1            # 占住 ⇒ 后面的档不能再抢这一格
		if i < 0:
			continue
		_city_win_src.append(i)
		_city_win_host.append(h)
		_city_win_pos.append(_city_cell_pos[idx])
		_city_win_v.append(_city_cell_v[idx])
		_city_win_scale.append(m_scale)
		_city_win_pgate.append(plate_gate)
	_city_cell_order.clear()


# ---------------- ⑤⑥ 补位（离屏幕中心由近到远）+ 摆位 ----------------

## 把本帧 winner 填进**自由槽位**。顺序 = 离屏幕中心由近到远（分环计数排序，O(n)、不排序）：
## 池不够时被舍弃的永远是画面**最外圈**（用户要的「出现带居中在屏幕中心」），而不是遍历方向的后半段。
func _assign_city_slots(used: int, stage: Vector2, delta: float) -> int:
	# 自由槽位分两张表：**已完全淡出**的（复用不会让旧铭牌"啪"地消失，优先用）/ 还挂着旧城的
	_city_free_dead.clear()
	_city_free_live.clear()
	for k in range(CITY_POOL_SIZE):
		if _city_keep_stamp[k] == _city_frame_stamp:
			continue
		if _city_slot_src[k] < 0 and _city_slot_fade[k] <= CITY_SLOT_DEAD_EPS \
				and _city_slot_pfade[k] <= CITY_SLOT_DEAD_EPS:
			_city_free_dead.append(k)
		else:
			_city_free_live.append(k)
	var n := _city_win_src.size()
	if n <= 0:
		return used
	if _city_win_ring.size() != n:
		_city_win_ring.resize(n)
		_city_win_order.resize(n)
	if _city_ring_count.size() != CITY_RINGS:
		_city_ring_count.resize(CITY_RINGS)
	var center := stage * 0.5
	for r in range(CITY_RINGS):
		_city_ring_count[r] = 0
	for j in range(n):
		var r := mini(int(_city_win_pos[j].distance_to(center) / CITY_RING_PX), CITY_RINGS - 1)
		_city_win_ring[j] = r
		_city_ring_count[r] += 1
	var acc := 0
	for r in range(CITY_RINGS):
		var c := _city_ring_count[r]
		_city_ring_count[r] = acc
		acc += c
	for j in range(n):
		var r := _city_win_ring[j]
		_city_win_order[_city_ring_count[r]] = j
		_city_ring_count[r] += 1
	var dead := 0
	var live := 0
	var dead_n := _city_free_dead.size()
	var live_n := _city_free_live.size()
	for jj in _city_win_order:
		var k := -1
		if dead < dead_n:
			k = int(_city_free_dead[dead])
			dead += 1
		elif live < live_n:
			k = int(_city_free_live[live])
			live += 1
		else:
			break                          # 槽位用尽 ⇒ 剩下的 winner 这帧不上屏（它们离屏心最远）
		var j := int(jj)
		var wh := int(_city_win_host[j])
		_place_city_slot(k, wh, _city_hosts[wh].city_index, int(_city_win_src[j]),
			_city_win_pos[j], _city_win_v[j], _city_win_scale[j], _city_win_pgate[j], stage, delta)
		used += 1
	return used


## 把槽位 k 摆到「城市 i / 屏幕位置 pos」上：
##   ★ **换了城市才**淡入（归零透明度）+ 换图形 / 文字 —— 黏滞保留的槽位完全跳过这一支；
##   ★ 缩放与文字**只在真的变了才写**（原来每次换城都写 ⇒ 每帧几百次文字重排 + 容器 relayout）。
func _place_city_slot(k: int, h: int, ci: CityIndex, i: int, pos: Vector2, v: float,
		m_scale: float, plate_gate: float, stage: Vector2, delta: float) -> void:
	_city_keep_stamp[k] = _city_frame_stamp
	var half := Vector2(CITY_MARK_SIZE, CITY_MARK_SIZE) * (0.5 * m_scale)
	if _city_slot_src[k] != i or _city_slot_host[k] != h:
		var oi := _city_slot_src[k]
		if oi >= 0 and _city_slot_host[k] >= 0:
			_city_slot_of.erase(_slot_key(_city_slot_host[k], oi))
		_city_slot_src[k] = i
		_city_slot_host[k] = h
		_city_slot_of[_slot_key(h, i)] = k
		_city_slot_fade[k] = 0.0
		_city_slot_pfade[k] = 0.0
		var tb := ci.tiers[i]
		if _city_slot_tier[k] != tb:
			_city_slot_tier[k] = tb
			_city_marks[k].configure(_tier_name(tb), CITY_MARK_COLOR, CITY_MARK_OUTLINE)
		var nm := ci.display_name(i)
		if _city_labels[k].text != nm:
			_city_labels[k].text = nm
			_city_plates[k].reset_size()
	if _city_slot_scale[k] != m_scale:
		_city_slot_scale[k] = m_scale
		_city_marks[k].scale = Vector2(m_scale, m_scale)
	_city_marks[k].position = pos - half
	# 铭牌：受「放大倍数」门控；大/小档本身已在 130px 以上才出现 ⇒ 出现即带铭牌
	var want_plate := plate_gate > 0.001 and v > 0.5
	if want_plate:
		var plate := _city_plates[k]
		plate.position = pos + Vector2(half.x + CITY_PLATE_GAP, -plate.size.y * 0.5)
		want_plate = _plate_rect_free(Rect2(plate.position, plate.size), stage)
	_step_city_slot(k, v, want_plate, delta)


## 未被本帧用到（没被保留、也没被填）的槽位 → 淡出；淡干净了才解除绑定、真正回收。
func _release_city_slots(delta: float) -> void:
	for k in range(CITY_POOL_SIZE):
		if _city_keep_stamp[k] == _city_frame_stamp:
			continue
		if _city_slot_src[k] < 0:
			if not _city_marks[k].visible and not _city_plates[k].visible:
				# ★ 已完全淡出的空槽直接跳过：每帧白算一次插值 + 两次属性写 × 1024 槽 = 真开销
				_city_slot_fade[k] = 0.0
				_city_slot_pfade[k] = 0.0
				continue
			_step_city_slot(k, 0.0, false, delta)
			continue
		_step_city_slot(k, 0.0, false, delta)
		if _city_slot_fade[k] <= CITY_SLOT_DEAD_EPS and _city_slot_pfade[k] <= CITY_SLOT_DEAD_EPS:
			_city_slot_of.erase(_slot_key(_city_slot_host[k], _city_slot_src[k]))
			_city_slot_src[k] = -1
			_city_slot_host[k] = -1


## ★ 第三十轮：每帧更新玩家位置标记 —— 从 LocalWeather 读取玩家经纬度，
##   投影到屏幕上（复用城市的投影管线），用倒置红色三角形标出。
##   只在地球可见、且玩家位置朝向镜头时才显示（与城市标识同一套可见性逻辑）。
func _update_player_mark(delta: float) -> void:
	if _player_mark == null or not is_instance_valid(_player_mark):
		return
	if _city_layer == null or not is_instance_valid(_city_layer):
		return
	if _world_view == null or not is_instance_valid(_world_view):
		return
	if _city_hosts.is_empty():
		# 没有带城市的星体（地球还没建好）→ 淡出
		_player_fade = maxf(0.0, _player_fade - delta * PLAYER_FADE_SPEED)
		_player_mark.modulate.a = _player_fade
		_player_mark.visible = _player_fade > 0.01
		return
	# 取玩家经纬度：优先 LocalWeather（天气系统已实现读取本机位置），
	# 回落到 location.json（手动定位）
	var lat: float = 0.0
	var lon: float = 0.0
	var has_coords := false
	if LocalWeather != null:
		var entry := LocalWeather.selected_entry()
		if not entry.is_empty():
			var la: Variant = entry.get("latitude", null)
			var lo: Variant = entry.get("longitude", null)
			if la != null and lo != null:
				lat = float(la)
				lon = float(lo)
				has_coords = true
	if not has_coords and SaveManager != null:
		var loc_data := SaveManager.load_location_data()
		if not loc_data.is_empty():
			var dev: Variant = loc_data.get("device", {})
			if dev is Dictionary:
				var la: Variant = (dev as Dictionary).get("latitude", null)
				var lo: Variant = (dev as Dictionary).get("longitude", null)
				if la != null and lo != null:
					lat = float(la)
					lon = float(lo)
					has_coords = true
	if not has_coords:
		# 没有坐标 → 淡出标记
		_player_fade = maxf(0.0, _player_fade - delta * PLAYER_FADE_SPEED)
		_player_mark.modulate.a = _player_fade
		_player_mark.visible = _player_fade > 0.01
		return
	# 找到有城市的星体（通常是地球）
	var host: WorldNode = _city_hosts[0]
	if host.body_mi == null or not is_instance_valid(host.body_mi):
		_player_fade = maxf(0.0, _player_fade - delta * PLAYER_FADE_SPEED)
		_player_mark.modulate.a = _player_fade
		_player_mark.visible = _player_fade > 0.01
		return
	# 外表被隐藏（镜头在地心世界里）→ 不显示
	if host.outer_hidden:
		_player_fade = maxf(0.0, _player_fade - delta * PLAYER_FADE_SPEED)
		_player_mark.modulate.a = _player_fade
		_player_mark.visible = _player_fade > 0.01
		return
	# 经纬度 → 球面局部方向 → 世界坐标（与城市完全一致的管线）
	var dir := CityIndex.latlon_dir(lat, lon)
	var world_pos: Vector3 = host.body_mi.global_transform * (dir * host._city_shell_r)
	# 可见性：玩家位置是否在朝向镜头的一面
	var cam := _world_view.camera_position()
	var to_c := cam - world_pos
	if to_c.length_squared() <= 1e-12:
		_player_fade = maxf(0.0, _player_fade - delta * PLAYER_FADE_SPEED)
		_player_mark.modulate.a = _player_fade
		_player_mark.visible = _player_fade > 0.01
		return
	# 朝向因子：点乘 > 0 表示朝向镜头
	var normal := (world_pos - host.global_position).normalized()
	var face_dot := normal.dot(to_c.normalized())
	# 地球背面 → 隐藏；地平线附近 → 淡出（与城市标识同一套 CITY_LIMB_FADE）
	if face_dot < 0.0:
		_player_fade = maxf(0.0, _player_fade - delta * PLAYER_FADE_SPEED)
		_player_mark.modulate.a = _player_fade
		_player_mark.visible = _player_fade > 0.01
		return
	var v := smoothstep(0.0, CITY_LIMB_FADE, face_dot)
	if v <= 0.02:
		_player_fade = maxf(0.0, _player_fade - delta * PLAYER_FADE_SPEED)
		_player_mark.modulate.a = _player_fade
		_player_mark.visible = _player_fade > 0.01
		return
	# 投影到屏幕
	var pos := _world_view.project_point_fast(world_pos)
	if not pos.is_finite():
		_player_fade = maxf(0.0, _player_fade - delta * PLAYER_FADE_SPEED)
		_player_mark.modulate.a = _player_fade
		_player_mark.visible = _player_fade > 0.01
		return
	# 舞台范围内才显示
	var stage := _stage_view.size
	if pos.x < -20.0 or pos.y < -20.0 or pos.x > stage.x + 20.0 or pos.y > stage.y + 20.0:
		_player_fade = maxf(0.0, _player_fade - delta * PLAYER_FADE_SPEED)
		_player_mark.modulate.a = _player_fade
		_player_mark.visible = _player_fade > 0.01
		return
	# 可见 → 淡入
	_player_fade = minf(1.0, _player_fade + delta * PLAYER_FADE_SPEED)
	# 缩放：与城市标识同一套逻辑（随放大倍数缩放）
	var globe_px := _world_view.screen_radius_of(host)
	var m_scale := clampf(globe_px / CITY_MARK_REF_PX, CITY_MARK_MIN_SCALE, CITY_MARK_MAX_SCALE)
	_player_mark.scale = Vector2(m_scale, m_scale)
	# 定位：三角形尖尖在标记本地坐标 (BOX_SIZE/2, BOX_SIZE/2 + TRI_H/2) 处，
	#   缩放后尖尖相对标记 position 的偏移 = (BOX_SIZE/2 * scale, (BOX_SIZE/2 + TRI_H/2) * scale)。
	#   让尖尖精确落在投影点 pos 上 ⇒ 反推标记的 position。
	var tip_local_x := CityMarker.BOX_SIZE * 0.5
	var tip_local_y := CityMarker.BOX_SIZE * 0.5 + CityMarker.TRI_H * 0.5
	_player_mark.position = Vector2(pos.x - tip_local_x * m_scale, pos.y - tip_local_y * m_scale)
	_player_mark.modulate.a = _player_fade
	_player_mark.visible = _player_fade > 0.01


## 「星体序号 + 城市下标」→ 字典键（城市下标是每颗星体各自从 0 编的，必须带星体才不撞号）。
static func _slot_key(h: int, i: int) -> int:
	return h * 1000000 + i


# ---------------- 舞台帽（把候选裁到「屏幕上真正看得见的那一小块」）----------------

## 「舞台上看得见的那块地」的**最大角半径**（度）：用真实 `project_point` 二分反解 ⇒ 与渲染口径一致。
## ★ 为什么用**半对角**：舞台是矩形、四个角比边远 ⇒ 以半对角为半径一定是**超集**（不会漏掉可见城市）。
## ★ 为什么需要它：小档帽子（CITY_SMALL_CAP_DEG）只是**上限**；最贴的 1.08R 下舞台只看得见中心 ±2.7°，
##   而 14° 帽会收进近万座、其中九成投影到画外 ⇒ 每座一次世界变换 + 投影，白烧十几毫秒/帧。
func _stage_cap_deg(host: WorldNode, cam_local: Vector3, stage: Vector2) -> float:
	if host.body_mi == null or not is_instance_valid(host.body_mi):
		return CITY_SMALL_CAP_DEG
	var axis := cam_local.cross(Vector3.UP)
	if axis.length_squared() < 1e-6:
		axis = cam_local.cross(Vector3.RIGHT)
	if axis.length_squared() < 1e-6:
		return CITY_SMALL_CAP_DEG
	axis = axis.normalized()
	var r := 0.5 * stage.length()
	var center := stage * 0.5
	var xf := host.body_mi.global_transform
	var lo := 0.0
	var hi := 89.0        # 90° 已到球背面（投影无意义）⇒ 上界取 89°
	for it in range(10):
		var mid := (lo + hi) * 0.5
		var t := deg_to_rad(mid)
		var dir := (cam_local * cos(t) + axis * sin(t)).normalized()
		var p := _world_view.project_point(xf * (dir * host.radius))
		if not p.is_finite() or p.distance_to(center) > r:
			hi = mid
		else:
			lo = mid
	return lo


# ---------------- 铭牌去重（格子占用表）----------------

func _city_prepare_plate_grid(stage: Vector2) -> void:
	var cols := maxi(1, int(ceil(stage.x / CITY_PLATE_CELL)))
	var rows := maxi(1, int(ceil(stage.y / CITY_PLATE_CELL)))
	if cols != _city_plate_cols or rows != _city_plate_rows:
		_city_plate_cols = cols
		_city_plate_rows = rows
		_city_plate_occ.resize(cols * rows)
	_city_plate_occ.fill(0)


## 铭牌矩形是否「可放」（不出边界 + 不与已放铭牌冲突）；可放就把它占的格子标上。
## ★ 用格子占用表替代 O(n²) 的两两求交：最密的机位下上千块铭牌，两两要十几万次矩形相交（几毫秒），
##   而每块只查自己盖住的那十几个格子。
func _plate_rect_free(rect: Rect2, stage: Vector2) -> bool:
	if rect.position.x < PLATE_EDGE_MARGIN or rect.end.x > stage.x - PLATE_EDGE_MARGIN \
			or rect.position.y < PLATE_EDGE_MARGIN or rect.end.y > stage.y - PLATE_EDGE_MARGIN:
		return false
	if _city_plate_cols <= 0 or _city_plate_rows <= 0:
		return true
	var x0 := clampi(int(floor(rect.position.x / CITY_PLATE_CELL)), 0, _city_plate_cols - 1)
	var y0 := clampi(int(floor(rect.position.y / CITY_PLATE_CELL)), 0, _city_plate_rows - 1)
	var x1 := clampi(int(floor((rect.end.x - 0.001) / CITY_PLATE_CELL)), 0, _city_plate_cols - 1)
	var y1 := clampi(int(floor((rect.end.y - 0.001) / CITY_PLATE_CELL)), 0, _city_plate_rows - 1)
	for y in range(y0, y1 + 1):
		var base := y * _city_plate_cols
		for x in range(x0, x1 + 1):
			if _city_plate_occ[base + x] != 0:
				return false
	for y in range(y0, y1 + 1):
		var base := y * _city_plate_cols
		for x in range(x0, x1 + 1):
			_city_plate_occ[base + x] = 1
	return true


## 推进某槽位的标识 / 铭牌透明度（指数插值、帧率无关；与星体铭牌同一速率）。
## `v_target` = 该城市的目标标识透明度（含地平线淡出），`want_plate` = 铭牌这一帧该不该显示。
func _step_city_slot(k: int, v_target: float, want_plate: bool, delta: float) -> void:
	var pt := v_target if want_plate else 0.0
	# ★ 第二十二轮：**已经收敛到目标的槽位直接返回** —— 上千个槽位每帧都做「指数插值 + 4 次 Control 属性写」
	#   就是几毫秒的纯浪费（绝大多数槽位在拖动中也一直停在「全显」状态）。
	if absf(_city_slot_fade[k] - v_target) <= 2.5e-3 and absf(_city_slot_pfade[k] - pt) <= 2.5e-3:
		return
	var a := lerpf(_city_slot_fade[k], v_target, 1.0 - exp(-PLATE_FADE_SPEED * delta))
	_city_slot_fade[k] = a
	var mark := _city_marks[k]
	mark.visible = a > PLATE_VISIBLE_EPS
	if mark.visible:
		mark.modulate.a = a
	var b := lerpf(_city_slot_pfade[k], pt, 1.0 - exp(-PLATE_FADE_SPEED * delta))
	_city_slot_pfade[k] = b
	var plate := _city_plates[k]
	plate.visible = b > PLATE_VISIBLE_EPS
	if plate.visible:
		plate.modulate.a = b


## 整数档位 → CityMarker 用的档位字符串。
static func _tier_name(tier: int) -> String:
	match tier:
		CityIndex.TIER_CAPITAL:
			return CityMarker.TIER_CAPITAL
		CityIndex.TIER_METRO:
			return CityMarker.TIER_METRO
		CityIndex.TIER_MEDIUM:
			return CityMarker.TIER_MEDIUM
		_:
			return CityMarker.TIER_SMALL


# ---------------- 太阳辉光（第二十轮续 · gl_compatibility 没有引擎泛光，用浮层做伪辉光）----------------

## 建两层加色光斑（外层大光晕 + 内层亮核）。★ 都先 `visible = false`，位置 / 大小 / 强度每帧由
## `_update_sun_glow` 摆。
func _make_glow_rects() -> void:
	if _glow_layer == null or not is_instance_valid(_glow_layer):
		return
	_glow_halo = _make_glow_rect(Color(1.0, 0.60, 0.16))
	_glow_layer.add_child(_glow_halo)
	_glow_core = _make_glow_rect(Color(1.0, 0.87, 0.64))
	_glow_layer.add_child(_glow_core)


## 一片「径向渐变 + 加色混合」的 TextureRect。
## ★ 渐变用 4 个停点做柔和衰减（中心最亮 → 外缘全透明）：只给两个停点的话，边缘会出现明显的圆环。
## ★ 加色混合在**黑背景**上就是「发光」；这也是为什么不用半透明白片子 —— 加色不会把背景压暗。
func _make_glow_rect(col: Color) -> TextureRect:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.14, 0.40, 1.0])
	g.colors = PackedColorArray([
		Color(col.r, col.g, col.b, 1.0),
		Color(col.r, col.g, col.b, 0.52),
		Color(col.r, col.g, col.b, 0.15),
		Color(col.r, col.g, col.b, 0.0)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 256
	gt.height = 256
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	var tr := TextureRect.new()
	tr.texture = gt
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	tr.material = m
	tr.visible = false
	return tr


## 每帧摆辉光：位置 = 太阳的投影点；**直径 = max(太阳屏幕直径 × MUL, 最小直径)**；
##   强度 = 基准 × 遮挡系数（被行星挡住时仍透出一部分 ⇒ 「被遮住也找得到太阳」）。
func _update_sun_glow(delta: float) -> void:
	if _glow_halo == null or _glow_layer == null or not is_instance_valid(_glow_layer):
		return
	if _glow_sun == null:
		# **数据驱动**：跟着「被标记为自发光」的那颗（世界 JSON 里太阳是 emissive），不写死 sid
		for n in _nodes:
			if n.emissive:
				_glow_sun = n
				break
	if _glow_sun == null or not is_instance_valid(_glow_sun):
		return
	if _world_view == null or not is_instance_valid(_world_view):
		return

	var on := false
	var target := 0.0
	var pos := Vector2.ZERO
	var diam := 0.0
	var sp := _glow_sun.global_position
	if _glow_sun.visible and not _world_view.is_point_behind(sp):
		pos = _world_view.project_point(sp)
		diam = clampf(_world_view.screen_radius_of(_glow_sun) * 2.0 * SUN_GLOW_SCREEN_MUL,
			SUN_GLOW_MIN_PX, SUN_GLOW_MAX_PX)
		var half := diam * 0.5
		var stage := _stage_view.size
		if pos.x > -half and pos.y > -half and pos.x < stage.x + half and pos.y < stage.y + half:
			on = true
			var occ := 0.0
			if _world_view.get_camera_anchor_sid() != _glow_sun.sid:
				var cam := _world_view.camera_position()
				# ★ 采样框从写死的 10×10 换成「太阳**自己的屏幕圆面**」：
				#   ① 太阳在远处屏幕半径只有 2~3px，10×10 的框其实比它大不了多少，勉强够用；
				#    ② 贴近看太阳时 10×10 只是圆心一小点 ⇒ 旁边掠过的行星根本采不到，
				#       会出现「半个太阳被挡住了、辉光还是满亮」。
				#   用 `max(屏幕半径, 4)` 保底：太小时 9 个采样点会退化到同一个像素上。
				var sr := maxf(_world_view.screen_radius_of(_glow_sun), 4.0)
				occ = _occluded_ratio(Rect2(pos - Vector2(sr, sr), Vector2(sr * 2.0, sr * 2.0)),
					_glow_sun.sid, cam.distance_to(sp), _screen_discs(cam))
			target = SUN_GLOW_ALPHA * lerpf(1.0, SUN_GLOW_OCCLUDED_ALPHA, clampf(occ, 0.0, 1.0))

	_glow_fade = lerpf(_glow_fade, target if on else 0.0, 1.0 - exp(-SUN_GLOW_FADE_SPEED * delta))
	var vis := on and _glow_fade > PLATE_VISIBLE_EPS
	_glow_halo.visible = vis
	_glow_core.visible = vis
	if not vis:
		return
	_glow_halo.size = Vector2(diam, diam)
	_glow_halo.position = pos - Vector2(diam, diam) * 0.5
	_glow_halo.modulate.a = _glow_fade
	var cs := diam * SUN_GLOW_CORE_RATIO
	_glow_core.size = Vector2(cs, cs)
	_glow_core.position = pos - Vector2(cs, cs) * 0.5
	_glow_core.modulate.a = _glow_fade


## 算出某块铭牌本帧应摆的矩形；**不该显示 → 返回 null**。判据（任一命中即不显示）：
##   ① 级别过滤掉（`n.visible == false`）或没有实体（`radius <= 0`）；
##   ② 星体在相机背后（投影无意义）；
##   ③ **离星球够近**（相机到它的距离 < 半径 × PLATE_HIDE_RATIO）—— 贴脸时名称框既没用、
##      又会被 PLATE_MAX_OFFSET_RATIO 顶到屏幕下缘露出怪相（与尾迹同款退场口径）；
##   ④ 星体投影中心出舞台（含 PLATE_EDGE_MARGIN 余量）；
##   ⑤ 名称框掉到舞台下沿之外；
##   ⑥ **被更近的星体挡住**（遮挡比例 > PLATE_OCCLUDE_RATIO）—— 铭牌是 2D 浮层、天然画在 3D 之上，
##      「被星体阻挡」只能自己判（见 _screen_discs / _occluded_ratio）。
func _plate_rect(n: WorldNode, plate: Control, stage: Vector2, discs: Array, cam: Vector3) -> Variant:
	if not n.visible or n.radius <= 0.0:
		return null
	var wp := n.global_position
	if _world_view.is_point_behind(wp):
		return null
	var d_self := cam.distance_to(wp)
	if d_self < n.radius * PLATE_HIDE_RATIO:
		return null
	var p := _world_view.project_point(wp)
	if p.x < -PLATE_EDGE_MARGIN or p.x > stage.x + PLATE_EDGE_MARGIN \
			or p.y < -PLATE_EDGE_MARGIN or p.y > stage.y + PLATE_EDGE_MARGIN:
		return null
	# 下线偏移 = 「可见轮廓半径」+ 间距。可见轮廓半径 = 球体轮廓 × 可见倍数：
	# 有星环的行星（土星 2.41×半径）要按**环外缘**算，否则名称框会压在环上。
	var ring_scale := 1.0
	if not n.ring.is_empty():
		ring_scale = maxf(1.0, float(n.ring.get("outer_ratio", 1.0)))
	var off := minf(maxf(_world_view.screen_radius_of(n, ring_scale), 0.0) + PLATE_GAP_PX,
		stage.y * PLATE_MAX_OFFSET_RATIO)
	var sz := plate.size
	# 水平居中于星体，但夹在舞台内（`_stage_view.clip_contents = true` ⇒ 出界会被裁掉）
	var rect := Rect2(clampf(p.x - sz.x * 0.5, 0.0, maxf(0.0, stage.x - sz.x)), p.y + off, sz.x, sz.y)
	if rect.position.y > stage.y:
		return null
	if _occluded_ratio(rect, n.sid, d_self, discs) > PLATE_OCCLUDE_RATIO:
		return null
	return rect


## 「可见星体的屏幕圆面表」：每帧**只建一次**供全部铭牌复用（遮挡判定要 9 点采样，
## 逐块现算会把「投影 + 轮廓半径」重复几十遍）。每项 = `{sid, center, r, d}`：
## center = 球心的屏幕坐标、r = 屏幕轮廓半径（像素）、d = 球心到相机的距离。
func _screen_discs(cam: Vector3) -> Array:
	var out: Array = []
	for n in _nodes:
		if n.radius <= 0.0 or not n.visible:
			continue
		if _world_view.is_point_behind(n.global_position):
			continue
		var r := _world_view.screen_radius_of(n)
		if r <= 0.0:
			continue
		out.append({
			"sid": n.sid,
			"center": _world_view.project_point(n.global_position),
			"r": r,
			"d": cam.distance_to(n.global_position),
		})
	return out


## 铭牌矩形被**比它更近**的星体圆面盖住的采样比例（0~1；3×3 = 9 点）。
##   ★ 只算更近的（`d < d_self`）：更远的星体在 3D 里本来就该被本星体挡住，不该反过来判本铭牌被挡
##     （否则全景视距下巨大的太阳会把所有铭牌判成「被挡」）。
##   ★ 排除自己（同 sid）：自己的圆面投影（拾取体还是 半径×1.2）可能压在铭牌上，但那是「铭牌贴着星体」，不是阻挡。
func _occluded_ratio(rect: Rect2, sid: String, d_self: float, discs: Array) -> float:
	var hit := 0
	for iy in range(3):
		for ix in range(3):
			var pt := Vector2(rect.position.x + rect.size.x * (0.25 + 0.25 * float(ix)),
				rect.position.y + rect.size.y * (0.25 + 0.25 * float(iy)))
			for disc in discs:
				var dd := disc as Dictionary
				if str(dd["sid"]) == sid or float(dd["d"]) >= d_self:
					continue
				var c := dd["center"] as Vector2
				var r := float(dd["r"])
				if absf(pt.x - c.x) > r or absf(pt.y - c.y) > r:   # 圆外接方框粗筛
					continue
				if pt.distance_squared_to(c) <= r * r:
					hit += 1
					break
	return float(hit) / 9.0


## 淡入淡出：目标 1（该显示）/ 0（该隐藏），按 PLATE_FADE_SPEED 指数收敛（帧率无关，≈0.15s 完成）。
## ★ 透明度 < PLATE_VISIBLE_EPS ⇒ visible = false（不再绘制）；< PLATE_CLICK_ALPHA ⇒ 不吃右键（见 _plate_at）。
func _step_plate_fade(sid: String, plate: Control, want: bool, delta: float) -> void:
	var a := float(_plate_fade.get(sid, 0.0))
	a = lerpf(a, 1.0 if want else 0.0, 1.0 - exp(-PLATE_FADE_SPEED * maxf(delta, 0.0)))
	_plate_fade[sid] = a
	plate.modulate.a = a
	plate.visible = a > PLATE_VISIBLE_EPS


## 铭牌的占位顺序（重叠去重时「先到先得」，所以顺序 = 优先级）：
## ① 锚定中的星体最优先（保证它一定显示）
## ② 再按**层级**升序（level 0 太阳 → 1 行星/矮行星/小行星 → 2 卫星/带内小行星）
##    —— 全景视距下屏幕中心那一小片会挤成一团，此时让太阳与行星占位，而不是随机某颗小行星。
## ③ 同级内按「离相机由近到远」。
func _plate_order() -> Array:
	var arr: Array = _plate_sids.duplicate()
	if arr.is_empty() or _world_view == null or not is_instance_valid(_world_view):
		return arr
	var cam := _world_view.camera_position()
	var anchor := _anchored_sid
	arr.sort_custom(func(a: String, b: String) -> bool:
		if a == anchor:
			return true
		if b == anchor:
			return false
		var na: WorldNode = _world_view.node_by_sid(a)
		var nb: WorldNode = _world_view.node_by_sid(b)
		if na == null or nb == null:
			return false
		if na.level != nb.level:
			return na.level < nb.level
		return cam.distance_squared_to(na.global_position) < cam.distance_squared_to(nb.global_position))
	return arr


## 舞台坐标 pos 落在哪块**可见**铭牌上（没有 → 空串）。
## ★ 只测可见的：被重叠去重 / 出屏隐藏的铭牌不吃右键。
func _plate_at(pos: Vector2) -> String:
	for sid in _plate_sids:
		var plate: Control = _plates.get(sid, null) as Control
		if plate == null or not is_instance_valid(plate) or not plate.visible:
			continue
		# ★ 淡出中的铭牌不吃右键（半透明的牌子被点中会很怪）
		if plate.modulate.a < PLATE_CLICK_ALPHA:
			continue
		if Rect2(plate.position, plate.size).has_point(pos):
			return sid
	return ""


# ---------------- 锚定右键菜单 ----------------

## 右键「世界节点」列表行 / 舞台上的星体铭牌 → 弹右键菜单，用菜单按钮**改变镜头锚定目标**。
## ★ 容器节点（radius = 0）不锚定 ⇒ 不给菜单（与旧行为一致：锚它等于把镜头塞进太阳里）。
func _open_anchor_menu(sid: String) -> void:
	if _world_view == null or not is_instance_valid(_world_view):
		return
	var n: WorldNode = _world_view.node_by_sid(sid)
	if n == null or n.radius <= 0.0:
		return
	_close_anchor_menu()
	if _ctx_menu == null or not is_instance_valid(_ctx_menu):
		_ctx_menu = ContextMenu.new()
		_ctx_menu.item_selected.connect(_on_anchor_menu_selected)
		add_child(_ctx_menu)
	_ctx_sid = sid
	_ctx_city_h = -1
	_ctx_city_i = -1
	var items: Array = []
	# 已锚定在它身上时就不必再给「锚定到它」这一项（按不出变化）
	if _anchored_sid != sid:
		items.append({ "label": "锚定到 " + n.display_name, "id": "anchor" })
	items.append({ "label": "解除锚定（自由视角）", "id": "clear" })
	# ★ 第二十四轮：「编辑节点属性」（星体 / 容器的编辑入口在这里 —— 城市走右侧「节点内容」的按钮）
	#   ★ 第二十五轮：与「编辑积木属性」同规矩 —— **仅调试模式**才给这一项（玩家不该看到编辑入口）。
	if Debug.debug_mode:
		items.append({ "label": "编辑节点属性", "id": "edit" })
	# ★ 本页挂在 CanvasLayer(99)（scale 恒为 1）⇒ get_global_mouse_position() 就是画布坐标，
	#   与 desktop / inventory_panel 里 ContextMenu.open() 的用法同一口径。
	_ctx_menu.open(get_global_mouse_position(), items)


## ★ 第二十九轮：舞台右键城市 / 「世界节点」里的关注城市行 → 城市菜单（选中 / 关注 / 取消关注）。
## ★ 复用同一个 ContextMenu（同一时刻只会有一个菜单）；
##   `_ctx_city_h/i` 存现场解析出的 (宿主, 城市)，菜单项按下时直接用它，不再按坐标重算。
func _open_city_menu(h: int, i: int) -> void:
	if h < 0 or h >= _city_hosts.size():
		return
	var host: WorldNode = _city_hosts[h]
	var ci: CityIndex = host.city_index
	if ci == null or i < 0 or i >= ci.total:
		return
	_close_anchor_menu()
	if _ctx_menu == null or not is_instance_valid(_ctx_menu):
		_ctx_menu = ContextMenu.new()
		_ctx_menu.item_selected.connect(_on_anchor_menu_selected)
		add_child(_ctx_menu)
	_ctx_sid = ""
	_ctx_city_h = h
	_ctx_city_i = i
	_ctx_city_key = _city_follow_key(host, i)
	var key := _ctx_city_key
	var items: Array = [
		{ "label": "选中该城市", "id": "city_select" },
		{ "label": "取消关注" if _followed.has(key) else "关注", "id": "city_follow" },
	]
	_ctx_menu.open(get_global_mouse_position(), items)


func _on_anchor_menu_selected(id: String, _path: PackedStringArray) -> void:
	if _world_view == null or not is_instance_valid(_world_view):
		return
	match id:
		"anchor":
			if not _ctx_sid.is_empty():
				_world_view.set_camera_anchor_sid(_ctx_sid)
		"clear":
			_world_view.clear_camera_anchor()
		"edit":
			if not _ctx_sid.is_empty():
				_open_property_for_sid(_ctx_sid)
		"city_select":
			if _ctx_city_h >= 0:
				_select_city(_ctx_city_h, _ctx_city_i)
				_set_content_open(true)
		"city_follow":
			if _ctx_city_h >= 0:
				_toggle_follow(_ctx_city_h, _ctx_city_i)


func _close_anchor_menu() -> void:
	if _ctx_menu != null and is_instance_valid(_ctx_menu):
		_ctx_menu.close()


func _on_anchor_changed(sid: String) -> void:
	_anchored_sid = sid
	_refresh_anchor_marks()


## 锚定中的星体在列表里高亮（金色名称），铭牌同样高亮（同一金色）。
func _refresh_anchor_marks() -> void:
	for sid in _row_labels.keys():
		var lb = _row_labels[sid]
		if lb == null or not is_instance_valid(lb):
			continue
		var on: bool = str(sid) == _anchored_sid
		(lb as Label).add_theme_color_override("font_color",
			ANCHOR_TEXT if on else Color.WHITE)
	# 铭牌同步（一眼看出镜头锚在谁身上；铭牌建好之前 _plate_labels 是空的，天然跳过）
	for sid in _plate_labels.keys():
		var lb2 = _plate_labels[sid]
		if lb2 == null or not is_instance_valid(lb2):
			continue
		(lb2 as Label).add_theme_color_override("font_color",
			ANCHOR_TEXT if str(sid) == _anchored_sid else Color.WHITE)


func _on_list_toggle_pressed(_id: String) -> void:
	_set_list_open(not _list_open)


## 展开 / 收起「世界节点」列表。列表是 body 的**第一个子节点**（左侧延伸列）：
## 开合只让面板**向左**变宽、位置 x 左移同等量 ⇒ 舞台列（含顶栏把柄 / ×）屏幕位置恒定。
func _set_list_open(on: bool) -> void:
	_list_open = on
	if _list_block != null and is_instance_valid(_list_block):
		_list_block.visible = on
	if _list_toggle_btn != null and is_instance_valid(_list_toggle_btn):
		_list_toggle_btn.set_label("世界节点" + (" ▴" if on else " ▾"))
	_relayout()


## 两侧延伸列的**对称补偿**：只补偿「舞台列左/右两侧的占位变化」——
##   左列展开 ⇒ 面板向**左**长、位置 x 反向平移同样多；右列展开 ⇒ 面板向**右**长、位置 x 不动。
##   于是舞台列的**屏幕位置与宽度**在任意一列开合下都不变（顶栏把柄 / × 原地不动）。
func _relayout() -> void:
	if _body == null or not is_instance_valid(_body):
		return
	var lw := _list_side_width()
	var rw := _content_side_width()
	if is_equal_approx(lw, _last_list_w) and is_equal_approx(rw, _last_content_w):
		return
	var d_left := lw - _last_list_w
	var d_right := rw - _last_content_w
	_last_list_w = lw
	_last_content_w = rw
	var old_x := position.x
	var old_sx := size.x
	size = _clamp_size(Vector2(old_sx + d_left + d_right, size.y))
	# ★ 第二十三轮推广为**双侧补偿**：位移量 = 实际宽度变化中**属于左列的那一部分**
	#   （= 总变化 − 右列的理论贡献）。于是：
	#     左列开/合 ⇒ 面板向 左/右 长 ⇒ 位置 x 反向平移 232；右列开/合 ⇒ 位置 x 完全不动；
	#     两列同时开合 ⇒ 只按左列那 232 位移（实测：两列全开 pos.x=-232、全关回到 0）。
	#   ★ 再夹到「左列的贡献」区间内：面板被尺寸上下限夹住（长不动）时，不会把舞台列推歪。
	var shift := (size.x - old_sx) - d_right
	shift = clampf(shift, 0.0, d_left) if d_left >= 0.0 else clampf(shift, d_left, 0.0)
	position.x = old_x - shift


## **舞台列左侧**的占位宽度：列表展开时 = 列表宽 + body 的 separation，其余情况 = 0。
## ★ 容器**不布局隐藏的子节点**（连 separation 也不计）—— 用 visible 而不是 _list_open 单条件，
##   避免 visible 与状态位短时不一致时算错补偿量。
func _list_side_width() -> float:
	if not _list_open:
		return 0.0
	if _list_block == null or not is_instance_valid(_list_block) or not _list_block.visible:
		return 0.0
	return LIST_W + _body_sep()


## **舞台列右侧**的占位宽度：本列展开时 = 列宽 + body 的 separation，其余情况 = 0（与 _list_side_width 对称）。
func _content_side_width() -> float:
	if not _content_open:
		return 0.0
	if _content_block == null or not is_instance_valid(_content_block) or not _content_block.visible:
		return 0.0
	return CONTENT_W + _body_sep()


func _on_content_toggle_pressed(_id: String) -> void:
	_set_content_open(not _content_open)


## 「视图模式」下拉：0 = 俯瞰视图（默认）、1 = 时区视图。
## ★ 只改 3D 舞台的渲染（见 WorldView.set_view_mode），不动数据 / 不改锚定。
func _on_view_mode_selected(idx: int) -> void:
	_view_mode = idx
	if _world_view != null:
		_world_view.set_view_mode(idx)


## 展开 / 收起「节点内容」右侧列（与 _set_list_open 镜像：右列展开时面板向右变宽、位置 x 不动）。
func _set_content_open(on: bool) -> void:
	_content_open = on
	if _content_block != null and is_instance_valid(_content_block):
		_content_block.visible = on
	if _content_toggle_btn != null and is_instance_valid(_content_toggle_btn):
		_content_toggle_btn.set_label("节点内容" + (" ▴" if on else " ▾"))
	_relayout()


func _body_sep() -> float:
	if _body == null or not is_instance_valid(_body):
		return 0.0
	return float(_body.get_theme_constant("separation"))


# ---------------- 3D 舞台输入 ----------------

func _on_stage_gui_input(ev: InputEvent) -> void:
	if _world_view == null or not is_instance_valid(_world_view):
		return
	# 交互前先重读设置页的两个开关 → 设置页刚改过也立刻生效（不必重开世界页）。
	_refresh_invert_flags()

	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_close_anchor_menu()
					_world_view.zoom_wheel(true)
					accept_event()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_close_anchor_menu()
					_world_view.zoom_wheel(false)
					accept_event()
			MOUSE_BUTTON_LEFT:
				# ★ 第十七轮（用户反馈）：**左键不再锚定 / 不再解除锚定** —— 原先「左键点星体 = 锚定它、
				#   点空白 = 解除锚定」被判定为「本不该存在」的行为，已移除。
				#   锚定现在只有一条路：**右键**铭牌 / 右键「世界节点」列表行 → 菜单里选「锚定到 <名称>」；
				#   解除锚定走同一菜单里的「解除锚定（自由视角）」。
				#   ★ 第二十三轮：左键改用于**点选城市**（命中 ⇒ 选中并展开右侧「节点内容」；点空白 ⇒ 取消选中）。
				#   ★ 左键仍要 **accept_event()** 吃掉事件 —— 否则会透传出去（本程序有「鼠标穿透到桌面」机制），
				#     在舞台里点一下就等于点了桌面。
				if mb.pressed:
					if _ctx_menu != null and is_instance_valid(_ctx_menu) and _ctx_menu.is_open():
						_close_anchor_menu()   # 菜单开着时左键只负责**关掉菜单**
					else:
						_pick_city(mb.position)
				accept_event()
			MOUSE_BUTTON_RIGHT:
				# ★ 右键：落在**铭牌**上「单击」= 弹右键菜单；按住**拖动** = 平移（保持原行为）。
				#   两者靠「按下 → 抬起」的位移区分（Windows 的右键菜单也是抬起时才弹）。
				#   拖动**不解除锚定** —— 解除走菜单里的「解除锚定（自由视角）」（★ 第十七轮起左键不再参与）。
				if mb.pressed:
					_plate_press_sid = _plate_at(mb.position)
					_plate_press_pos = mb.position
					# ★ 第二十九轮：没点在星体铭牌上时，再看有没有落在城市标识 / 铭牌上 ——
					#   右键「单击」→ 城市菜单（选中 / 关注）；按住拖动仍是平移。
					_city_press_key = ""
					_city_press_h = -1
					_city_press_i = -1
					_city_press_pos = mb.position
					if _plate_press_sid.is_empty():
						var ck := _city_hit(mb.position)
						if ck >= 0:
							_city_press_h = _city_slot_host[ck]
							_city_press_i = _city_slot_src[ck]
							if _city_press_h >= 0 and _city_press_h < _city_hosts.size():
								_city_press_key = _city_follow_key(_city_hosts[_city_press_h], _city_press_i)
					_world_view.begin_grab(mb.position)
				else:
					var as_click := not _plate_press_sid.is_empty() \
						and mb.position.distance_to(_plate_press_pos) < PLATE_CLICK_SLOP \
						and _plate_at(mb.position) == _plate_press_sid
					var sid := _plate_press_sid
					_plate_press_sid = ""
					# 城市单击：抬起时仍停在**同一座城市**上（按 key 判定，槽位可能已换）
					var as_city_click := false
					if not as_click and not _city_press_key.is_empty() \
							and mb.position.distance_to(_city_press_pos) < PLATE_CLICK_SLOP:
						var ck2 := _city_hit(mb.position)
						if ck2 >= 0:
							var h2 := _city_slot_host[ck2]
							var i2 := _city_slot_src[ck2]
							if h2 >= 0 and h2 < _city_hosts.size():
								as_city_click = _city_press_key == _city_follow_key(_city_hosts[h2], i2)
					if as_click:
						_world_view.end_grab(false)   # 单击：不播种惯性
						_close_anchor_menu()
						_open_anchor_menu(sid)
					elif as_city_click:
						_world_view.end_grab(false)
						_close_anchor_menu()
						_open_city_menu(_city_press_h, _city_press_i)
					else:
						_world_view.end_grab()
					_city_press_key = ""
					_city_press_h = -1
					_city_press_i = -1
				_panning = mb.pressed
				accept_event()
			MOUSE_BUTTON_MIDDLE:
				# 中键拖动平移（与右键拖动同款，但不弹菜单）。
				if mb.pressed:
					_close_anchor_menu()
					_world_view.begin_grab(mb.position)
				else:
					_world_view.end_grab()
				_panning = mb.pressed
				accept_event()
		return

	if ev is InputEventMouseMotion and _panning:
		var mm := ev as InputEventMouseMotion
		_world_view.update_grab(mm.position)
		accept_event()


# ---------------- 右下角缩放条（第二十八轮续 3）----------------

## 每帧把滑条 / 读数同步到相机（**用户正按住滑条时跳过**，否则会和拖拽打架）。
## 滚轮缩放、锚定飞入、切换星体都会自动反映到滑条上。
func _update_zoom_slider() -> void:
	if _zoom_dragging:
		return
	_sync_zoom_slider()


func _sync_zoom_slider() -> void:
	if _zoom_slider == null or not is_instance_valid(_zoom_slider):
		return
	if _world_view == null or not is_instance_valid(_world_view):
		return
	# WorldView: 0 = 最近、1 = 最远；滑条：0 = 远、1 = 近（向右拖 = 拉近）。
	var v := 1.0 - _world_view.get_zoom_fraction()
	_zoom_syncing = true
	_zoom_slider.set_value_no_signal(v)
	_zoom_syncing = false
	_refresh_zoom_readout()


func _refresh_zoom_readout() -> void:
	if _zoom_readout == null or not is_instance_valid(_zoom_readout):
		return
	if _world_view == null or not is_instance_valid(_world_view):
		_zoom_readout.text = "—"
		return
	var ratio := _world_view.get_zoom_distance_ratio()
	if ratio < 100.0:
		_zoom_readout.text = "%.2fR" % ratio
	elif ratio < 10000.0:
		_zoom_readout.text = "%.0fR" % ratio
	else:
		_zoom_readout.text = ">9999R"


func _on_zoom_slider_changed(v: float) -> void:
	if _zoom_syncing:
		return
	if _world_view == null or not is_instance_valid(_world_view):
		return
	_world_view.set_zoom_fraction(1.0 - v)
	_refresh_zoom_readout()


## 按住滑条期间锁住「相机 → 滑条」的同步（滑条才是这一小段时间的主人）。
func _on_zoom_drag_started() -> void:
	_zoom_dragging = true


func _on_zoom_drag_ended(_value_changed: bool) -> void:
	_zoom_dragging = false
	_sync_zoom_slider()


# ---------------- 城市选中（第二十三轮：左列是「节点」，右列是「选中对象的内容」）----------------

## 左键单击舞台 → 选中城市：**先看铭牌**（大、好点），再看标识本体（中心 ± 半尺寸 + 容差）；
##   命中 ⇒ 选中它、自动展开右侧「节点内容」；点空白 ⇒ 取消选中。
## ★ 城市标识 / 铭牌本身**不吃鼠标**（第十九轮起就是原型边界），命中判定统一放在舞台这一层做 ——
##   比让 1024 个 Control 各自吃事件便宜、也不会互相抢事件。
func _pick_city(pos: Vector2) -> void:
	var k := _city_hit(pos)
	if k < 0:
		_select_city(-1, -1)
		return
	_select_city(_city_slot_host[k], _city_slot_src[k])


## 舞台坐标 → 命中的城市槽位（-1 = 没点到）。先铭牌、再标识本体。
## ★ 抽出来是因为右键菜单也要用同一套命中判定（第二十九轮）。
func _city_hit(pos: Vector2) -> int:
	# ① 先看有没有点在**铭牌**上 —— 铭牌比标识大得多（几十~上百像素宽），是最好点的目标。
	for k in range(CITY_POOL_SIZE):
		var i := _city_slot_src[k]
		if i < 0:
			continue
		var pl := _city_plates[k]
		if not pl.visible or pl.modulate.a < PLATE_CLICK_ALPHA:
			continue        # 淡出中的铭牌不吃点（与 _plate_at 同一判据）
		if Rect2(pl.position, pl.size).has_point(pos):
			return k
	# ② 再看标识本体（中心 ± 半尺寸 + 容差）
	var best := -1
	var best_d := 0.0
	for k in range(CITY_POOL_SIZE):
		var i := _city_slot_src[k]
		if i < 0 or not _city_marks[k].visible:
			continue
		var ms := _city_slot_scale[k]
		if ms <= 0.0:
			continue
		var half := Vector2(CITY_MARK_SIZE, CITY_MARK_SIZE) * (0.5 * ms)
		var d := (_city_marks[k].position + half).distance_to(pos)
		if d <= half.x + CITY_PICK_SLOP and (best < 0 or d < best_d):
			best = k
			best_d = d
	return best


## 设 / 清选中城市（星体序号 + 城市下标；host < 0 = 取消）。同时刷新右侧列文本，并在选中时自动展开该列。
func _select_city(host_i: int, city_i: int) -> void:
	if host_i == _sel_host and city_i == _sel_city:
		return
	_sel_host = host_i
	_sel_city = city_i
	_apply_debug_visibility()      # 没选中城市 / 非调试模式 ⇒「编辑节点属性」不可按
	_refresh_sel_rows()
	if _sel_host >= 0:
		_set_content_open(true)


## 刷新「节点内容」的 8 行（名称 / 纬度 / 经度 / 海拔 / 人口密度 / 气候 / 当地时间 / 上级节点）。
## ★ 只在**选中变化**时调用，不是每帧（当地时间按选中那一刻算，跨分钟不追着刷新）。
## 经纬度由 `CityIndex.dir_to_latlon(dirs[i])` 反解 —— 与建索引时的输入严格一致，不必另存一份。
func _refresh_sel_rows() -> void:
	_refresh_follow_btn()          # 选中变了 ⇒ 关注按钮的标题 / 可用性跟着变
	_refresh_selected_marks()      # 关注行的金色高亮
	if _sel_rows.size() < 8:
		return
	if _sel_host < 0 or _sel_host >= _city_hosts.size() or _sel_city < 0:
		for lb in _sel_rows:
			lb.text = "—"
		return
	var host: WorldNode = _city_hosts[_sel_host]
	var ci: CityIndex = host.city_index
	if ci == null or _sel_city >= ci.total:
		return
	var ll := CityIndex.dir_to_latlon(ci.dirs[_sel_city])
	_sel_rows[0].text = ci.display_name(_sel_city)
	_sel_rows[1].text = "%.2f° %s" % [absf(ll.x), "N" if ll.x >= 0.0 else "S"]
	_sel_rows[2].text = "%.2f° %s" % [absf(ll.y), "E" if ll.y >= 0.0 else "W"]
	# ★ 海拔：直接从地表壳的「海拔栅格」按经纬度取样（不精确，只作参考；取不到栅格显示「—」）。
	var h := host.sample_elevation_m(ll.x, ll.y)
	if is_nan(h):
		_sel_rows[3].text = "—"
	elif h < 1.0:
		_sel_rows[3].text = "约 0 m（海平面）"
	else:
		_sel_rows[3].text = "约 %d m" % int(roundf(h / 10.0) * 10.0)
	# ★ 人口密度 / 气候：同样按经纬度从地表壳栅格取样（4K 栅格 ≈ 9 km/px，只作参考）。
	var d := host.sample_population_density(ll.x, ll.y)
	if is_nan(d):
		_sel_rows[4].text = "—"
	elif d < 1.0:
		_sel_rows[4].text = "约 0 人/km²（无人区）"
	elif d < 100.0:
		_sel_rows[4].text = "约 %d 人/km²" % int(roundf(d))
	elif d < 1000.0:
		_sel_rows[4].text = "约 %d 人/km²（乡村）" % int(roundf(d / 10.0) * 10.0)
	else:
		_sel_rows[4].text = "约 %s 人/km²" % _group_thousands(int(roundf(d / 100.0) * 100.0))
	_sel_rows[5].text = host.climate_display_name(host.sample_climate_code(ll.x, ll.y))
	# ★ 当地时间：用户要求「仅按时区简单划分」⇒ 每 15° 经度算一个整点时区（带心在本初子午线），
	#   取 UTC 系统时间 + 偏移即得；不需要夏令时 / 政治时区。
	var off_h := int(roundf(ll.y / 15.0))
	var utc: Dictionary = Time.get_time_dict_from_system(true)
	var mins := (int(utc.get("hour", 0)) * 60 + int(utc.get("minute", 0)) + off_h * 60) % 1440
	if mins < 0:
		mins += 1440
	_sel_rows[6].text = "%02d:%02d（UTC%s%d）" % [
		int(mins / 60.0), mins % 60, "+" if off_h >= 0 else "−", absi(off_h)]
	# 上级节点 = 该城市所属的星体（城市挂在星球上）；顺带写上它的上一级，便于玩家定位
	var parent_txt := host.display_name
	if not host.parent_sid.is_empty():
		var p: WorldNode = _world_view.node_by_sid(host.parent_sid)
		if p != null:
			parent_txt += "（上级：" + p.display_name + "）"
	_sel_rows[7].text = parent_txt


## 整数千分位（人口密度这类四位数以上才用，避免「34567 人/km²」读不出量级）。
func _group_thousands(v: int) -> String:
	var s := str(absi(v))
	var out := ""
	var n := s.length()
	for i in range(n):
		if i > 0 and (n - i) % 3 == 0:
			out += ","
		out += s[i]
	return ("-" if v < 0 else "") + out


## 把**选择环**挪到「当前挂着选中城市」的那个槽位上（选中城市可能因拖动换了槽位、也可能暂时不在屏上）。
## ★ 每帧只查一次 `_city_slot_of` ⇒ O(1)，不做 1024 槽位扫描（选中态变化很稀疏，没必要逐帧重新标）。
func _update_sel_ring() -> void:
	var want := -1
	if _sel_host >= 0 and _sel_city >= 0:
		want = int(_city_slot_of.get(_slot_key(_sel_host, _sel_city), -1))
	if want == _sel_prev_slot:
		return
	if _sel_prev_slot >= 0 and _sel_prev_slot < CITY_POOL_SIZE:
		_city_marks[_sel_prev_slot].selected = false
	_sel_prev_slot = want
	if want >= 0 and want < CITY_POOL_SIZE:
		_city_marks[want].selected = true


# ---------------- 「节点属性」窗口（第二十四轮）----------------

func _on_open_prop_pressed(_id: String) -> void:
	_open_property_for_city()


## 打开「节点属性」窗口编辑**选中的城市**。
func _open_property_for_city() -> void:
	if _sel_host < 0 or _sel_host >= _city_hosts.size() or _sel_city < 0:
		return
	var host: WorldNode = _city_hosts[_sel_host]
	var ci: CityIndex = host.city_index
	if ci == null or _sel_city >= ci.total:
		return
	var ll := CityIndex.dir_to_latlon(ci.dirs[_sel_city])
	# 各语言的当前值（含空 = 无译本）→ 窗口里切语言即可看到 / 编辑
	var names := {}
	for code in TranslationManager.LANG_CODES:
		names[str(code)] = ci.name_in(_sel_city, str(code))
	_open_prop({
		"kind": "city",
		# ★ 回传给「应用」时的定位信息：**按 GeoNamesID** 落盘（稳定键），下标只用于本会话内改内存
		"id": { "host_sid": host.sid, "host_entry": _sel_host, "city": _sel_city,
			"gnid": int(ci.gnids[_sel_city]) },
		"type_text": "城市（3 级）",
		"level": 3,
		"parent": host.display_name,
		"names": names, "lat": ll.x, "lon": ll.y, "tier": int(ci.tiers[_sel_city]),
	})


## 打开「节点属性」窗口编辑**某个星体 / 容器节点**（入口 = 世界节点列表行 / 星体铭牌的右键菜单）。
func _open_property_for_sid(sid: String) -> void:
	if _world_view == null or not is_instance_valid(_world_view):
		return
	var n: WorldNode = _world_view.node_by_sid(sid)
	if n == null:
		return
	var parent_txt := "（世界根）"
	if n.parent_node != null:
		parent_txt = n.parent_node.display_name
	_open_prop({
		"kind": "node",
		"id": { "sid": sid },
		"type_text": "星体" if n.radius > 0.0 else "容器节点",
		"level": n.level,
		"parent": parent_txt,
		"name": n.display_name,
	})


## 懒加载创建窗口并打开。默认摆位 = 世界页**右侧**（与左侧「世界节点」列镜像）。
func _open_prop(t: Dictionary) -> void:
	if _prop_panel == null or not is_instance_valid(_prop_panel):
		_prop_panel = NodePropertyPanel.new()
		_prop_panel.name = "NodePropertyPanel"
		_prop_panel.applied.connect(_on_prop_applied)
		add_child(_prop_panel)
		_prop_panel.position = Vector2(maxf(size.x - 340.0, 0.0), 64.0)
	_prop_panel.open_for(t)


## 窗口里按下「应用」→ 改数据 + 刷新显示 + 落盘（**只有「保存位置 = 本体」才落盘**）。
func _on_prop_applied(kind: String, payload: Dictionary) -> void:
	if _prop_panel == null or not is_instance_valid(_prop_panel):
		return
	if not _prop_panel.save_location_ok():
		return
	var t: Dictionary = _prop_panel.target
	var id: Dictionary = t.get("id", {})
	if str(t.get("kind", "")) == "city":
		_apply_city_edit(id, kind, payload)
	else:
		_apply_node_edit(id, kind, payload)


func _apply_city_edit(id: Dictionary, kind: String, payload: Dictionary) -> void:
	var h := int(id.get("host_entry", -1))
	if h < 0 or h >= _city_hosts.size():
		return
	var host: WorldNode = _city_hosts[h]
	var ci: CityIndex = host.city_index
	var i := int(id.get("city", -1))
	if ci == null or i < 0 or i >= ci.total:
		return
	var patch := {}
	match kind:
		"name":
			var lang := str(payload.get("lang", ""))
			var v := str(payload.get("value", ""))
			ci.set_name(i, lang, v)
			patch["names"] = { lang: v }
		"latlon":
			var lat := float(payload.get("lat", 0.0))
			var lon := float(payload.get("lon", 0.0))
			ci.set_latlon(i, lat, lon)
			patch["lat"] = lat
			patch["lon"] = lon
		"tier":
			var tt := clampi(int(payload.get("tier", 0)), 0, 3)
			ci.set_tier(i, tt)
			patch["tier"] = tt
		_:
			return
	# 「本体」= 写进游戏自身的数据层（按 GeoNamesID 定位；见 WorldData.save_city_edit）
	WorldData.save_city_edit(host.sid, str(int(id.get("gnid", 0))), patch)
	_refresh_sel_rows()          # 右侧「节点内容」的名称 / 经纬度跟着变
	_relabel_city_texts()        # 屏上铭牌重贴（名称变了；档位变了下一帧会自动换图形）


func _apply_node_edit(id: Dictionary, kind: String, payload: Dictionary) -> void:
	if kind != "node_name":
		return
	var sid := str(id.get("sid", ""))
	var n: WorldNode = _world_view.node_by_sid(sid)
	if n == null:
		return
	var v := str(payload.get("value", "")).strip_edges()
	if v.is_empty():
		return
	n.display_name = v
	WorldData.save_node_edit(sid, { "name": v })
	_refresh_node_labels(sid)
	_refresh_sel_rows()


## 把屏上**已画出**的城市铭牌按当前名称重贴一遍（换语言 / 改名后调用）。
func _relabel_city_texts() -> void:
	for k in range(CITY_POOL_SIZE):
		var i := _city_slot_src[k]
		if i < 0:
			continue
		var h := _city_slot_host[k]
		if h < 0 or h >= _city_hosts.size():
			continue
		var ci: CityIndex = _city_hosts[h].city_index
		if ci == null or i >= ci.total:
			continue
		var nm := ci.display_name(i)
		if _city_labels[k].text != nm:
			_city_labels[k].text = nm
			_city_plates[k].reset_size()
	# ★ 第二十九轮：关注行也要跟着换名（同一份 CityIndex 的显示名）。
	for key in _followed.keys():
		var flb = _followed_labels.get(key, null)
		if flb == null or not is_instance_valid(flb):
			continue
		var fref: Dictionary = _followed[key]
		var fh := int(fref.get("h", -1))
		var fi := int(fref.get("i", -1))
		if fh < 0 or fh >= _city_hosts.size():
			continue
		var fci: CityIndex = _city_hosts[fh].city_index
		if fci == null or fi < 0 or fi >= fci.total:
			continue
		(flb as Label).text = fci.display_name(fi)


## 星体改名后：世界节点列表那一行 + 舞台上的星体铭牌都要跟着变。
func _refresh_node_labels(sid: String) -> void:
	if _world_view == null or not is_instance_valid(_world_view):
		return
	var n: WorldNode = _world_view.node_by_sid(sid)
	if n == null:
		return
	var lb: Label = _row_labels.get(sid, null)
	if lb != null and is_instance_valid(lb):
		lb.text = n.display_name
	var pl: Label = _plate_labels.get(sid, null)
	if pl != null and is_instance_valid(pl):
		pl.text = n.display_name


## 换玩家语言 → 城市名要**自己重贴**（城市名不接翻译表：真源是数据文件的多语言列）。
func _on_language_changed(_lang: String) -> void:
	_relabel_city_texts()
	_refresh_sel_rows()


# ---------------- 构建 UI ----------------

func _clear() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_world_view = null
	_sub_viewport = null
	_stage_cont = null
	_stage_col = null
	_list_toggle_btn = null
	_list_block = null
	_last_list_w = 0.0
	_content_block = null
	_content_toggle_btn = null
	_view_mode_btn = null
	_last_content_w = 0.0
	_sel_rows.clear()
	_sel_host = -1
	_sel_city = -1
	_sel_prev_slot = -1
	_player_mark = null
	_player_fade = 0.0
	_prop_panel = null
	_prop_btn = null
	_ops_block = null
	if TranslationManager.language_changed.is_connected(_on_language_changed):
		TranslationManager.language_changed.disconnect(_on_language_changed)
	if Debug.mode_changed.is_connected(_on_debug_mode_changed):
		Debug.mode_changed.disconnect(_on_debug_mode_changed)
	_nodes = []
	_rows.clear()
	_row_labels.clear()
	_expand_btns.clear()
	_expanded.clear()
	_list_open = false
	_last_list_w = 0.0
	_panning = false
	_plate_layer = null
	_plates.clear()
	_plate_labels.clear()
	_plate_sids.clear()
	_plate_fade.clear()
	_city_layer = null
	_city_hosts.clear()
	_city_marks.clear()
	_city_plates.clear()
	_city_labels.clear()
	_city_slot_fade.resize(0)
	_city_slot_pfade.resize(0)
	_city_slot_src.resize(0)
	_city_slot_host.resize(0)
	_city_slot_tier.resize(0)
	_city_slot_scale.resize(0)
	_city_keep_stamp.resize(0)
	_city_slot_of.clear()
	_city_cand_mark.resize(0)
	_city_cand_touched.clear()
	_city_win_src.clear()
	_city_win_host.clear()
	_city_win_pos.clear()
	_city_win_v.clear()
	_city_win_scale.clear()
	_city_win_pgate.clear()
	_city_win_ring.clear()
	_city_win_order.clear()
	_city_ring_count.clear()
	_city_free_dead.clear()
	_city_free_live.clear()
	_city_plate_occ.resize(0)
	_city_plate_cols = 0
	_city_plate_rows = 0
	_city_cell_src.resize(0)
	_city_cell_pos.resize(0)
	_city_cell_v.resize(0)
	_city_cell_order.clear()
	_glow_layer = null
	_glow_halo = null
	_glow_core = null
	_glow_sun = null
	_glow_fade = 0.0
	_ctx_menu = null
	_ctx_sid = ""
	_plate_press_sid = ""


func _build_ui() -> void:
	_bg = UIPanel.new()
	_bg.name = "Bg"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", int(PADDING))
	margin.add_theme_constant_override("margin_right", int(PADDING))
	margin.add_theme_constant_override("margin_top", int(PADDING))
	margin.add_theme_constant_override("margin_bottom", int(PADDING))
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	# ★ 主体 = HBox[ 「世界节点」列表（**左侧延伸列**，默认收起） | 舞台列（顶栏 + 3D 舞台） ]。
	#   顶栏（含移动把柄 / 标题 / ×）**在舞台列里** —— 与「背包」的筛选侧栏同款「中列为锚」布局：
	#   列表展开时面板整体**向左**加宽、位置 x 左移同等量 ⇒ 舞台列（顶栏把柄也在其中）屏幕位置恒定。
	_body = HBoxContainer.new()
	_body.name = "Body"
	_body.add_theme_constant_override("separation", int(BODY_SEP))
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(_body)

	_list_block = _build_list_block()
	_list_block.visible = false
	_body.add_child(_list_block)   # ★ 第一个子节点 → 展开时把舞台列整体往右挤（配合 _relayout 左移面板）

	_stage_col = VBoxContainer.new()
	_stage_col.name = "StageCol"
	_stage_col.add_theme_constant_override("separation", int(PADDING))
	_stage_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stage_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(_stage_col)

	# ★ 第二十三轮：「节点内容 / 节点属性」= **右侧延伸列**（body 的**最后一个子节点**）。
	#   与左侧「世界节点」严格对称：本列展开时面板向右变宽（位置 x 不动）⇒ 舞台列的左缘、顶栏把柄、
	#   × 关闭按钮全都不动，与「左列展开时舞台列右缘不动」互为镜像。
	_content_block = _build_content_block()
	_content_block.visible = false
	_body.add_child(_content_block)

	var top := _build_top_bar()
	top.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_stage_col.add_child(top)
	_top_bar = top

	_build_stage()

	_resize_handle = UIResizeHandle.new()
	_resize_handle.name = "Resize"
	_resize_handle.set_move_callback(_on_resize_increment)
	add_child(_resize_handle)
	_resize_handle.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_resize_handle.offset_right = -6.0
	_resize_handle.offset_bottom = -6.0
	_resize_handle.offset_left = -(UIDragHandle.SIZE + 6.0)
	_resize_handle.offset_top = -(UIDragHandle.SIZE + 6.0)


## 3D 舞台：Control(裁剪) → SubViewportContainer(stretch) → SubViewport(own_world_3d) → WorldView。
func _build_stage() -> void:
	_stage_view = Control.new()
	_stage_view.name = "StageView"
	_stage_view.clip_contents = true
	_stage_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stage_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stage_col.add_child(_stage_view)   # ★ 挂在**舞台列**里（列表在 body 左延伸，不在舞台之上叠）

	_stage_cont = SubViewportContainer.new()
	_stage_cont.name = "Stage3D"
	_stage_cont.stretch = true
	_stage_cont.mouse_filter = Control.MOUSE_FILTER_STOP
	_stage_cont.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stage_cont.gui_input.connect(_on_stage_gui_input)
	_stage_view.add_child(_stage_cont)

	_sub_viewport = SubViewport.new()
	_sub_viewport.name = "World3D"
	_sub_viewport.own_world_3d = true          # 与桌面 2D 世界隔离
	_sub_viewport.transparent_bg = false
	_sub_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED   # 页面显示时才渲染
	_sub_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_stage_cont.add_child(_sub_viewport)

	# ★ 铭牌浮层：紧跟在 3D 容器之后（⇒ 画在 3D 之上）、在「世界节点」开合按钮之前（⇒ 按钮仍最上层）。
	#   它是 `_stage_view` 的绝对定位子节点层（与 _list_toggle_btn 同级同款），`_build_plates()` 往里挂牌子。
	# ★ 太阳辉光层（第二十轮续）：放在**铭牌层之下** ⇒ 加色辉光不会糊住铭牌文字与城市标注。
	_glow_layer = Control.new()
	_glow_layer.name = "SunGlowLayer"
	_glow_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glow_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stage_view.add_child(_glow_layer)
	_make_glow_rects()

	_plate_layer = Control.new()
	_plate_layer.name = "PlateLayer"
	_plate_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plate_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stage_view.add_child(_plate_layer)

	# ★ 城市浮层（第十九轮）：与铭牌层**同级、后建** ⇒ 画在星体铭牌之上（贴近地球时城市标注优先）。
	#   同样不吃鼠标（城市本轮不参与拾取 / 锚定，见计划书 §2-G）。
	_city_layer = Control.new()
	_city_layer.name = "CityLayer"
	_city_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_city_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stage_view.add_child(_city_layer)

	# ★「世界节点」开合按钮固定在 3D 舞台**左上角**（它是 `_stage_view` 的绝对定位子节点，
	#   而 `_stage_view` 属于舞台列 → 列表开合时舞台列屏幕位置不变，按钮自然也不动）。
	#   列表本体已改为 body 的**左侧延伸列**（见 _build_ui / _build_list_block）。
	_list_toggle_btn = UIBtn.new()
	_list_toggle_btn.set_id("world_list_toggle")
	_list_toggle_btn.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_list_toggle_btn.position = Vector2(STAGE_PAD, STAGE_PAD)
	_list_toggle_btn.size = Vector2(106.0, UIStyle.BTN_HEIGHT)
	_list_toggle_btn.pressed_id.connect(_on_list_toggle_pressed)
	_stage_view.add_child(_list_toggle_btn)

	# ★「节点内容」开合按钮固定在舞台**右上角**（与左上角的「世界节点」按钮镜像）。
	#   用 TOP_RIGHT 锚点 + 反向 offset 而不是写死 position：这样窗口缩放时它始终贴着右上角。
	_content_toggle_btn = UIBtn.new()
	_content_toggle_btn.set_id("world_content_toggle")
	_content_toggle_btn.set_label("节点内容 ▾")
	_content_toggle_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_content_toggle_btn.offset_left = -STAGE_PAD - 106.0
	_content_toggle_btn.offset_right = -STAGE_PAD
	_content_toggle_btn.offset_top = STAGE_PAD
	_content_toggle_btn.offset_bottom = STAGE_PAD + UIStyle.BTN_HEIGHT
	_content_toggle_btn.pressed_id.connect(_on_content_toggle_pressed)
	_stage_view.add_child(_content_toggle_btn)

	# ★ 第二十八轮续 7：「视图模式」下拉，紧贴「节点内容」按钮下方（同一右对齐列）。
	#   默认 0 = 俯瞰视图；1 = 时区视图（在地球表面叠 24 条 15° 经度带）。
	#   ★ 只影响舞台表现，不改数据；其它星体没有地球那套 shader ⇒ 选它也不会有变化。
	_view_mode_btn = OptionButton.new()
	_view_mode_btn.name = "ViewModeMenu"
	_view_mode_btn.fit_to_longest_item = false
	_view_mode_btn.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	var vmfnt := UIStyle.get_cjk_font()
	if is_instance_valid(vmfnt):
		_view_mode_btn.add_theme_font_override("font", vmfnt)
	_view_mode_btn.add_item("俯瞰视图")
	_view_mode_btn.add_item("时区视图")
	_view_mode_btn.add_item("人口密度")
	_view_mode_btn.add_item("气候分布")
	_view_mode_btn.select(_view_mode)
	_view_mode_btn.tooltip_text = "视图模式"
	_view_mode_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_view_mode_btn.offset_left = -STAGE_PAD - 106.0
	_view_mode_btn.offset_right = -STAGE_PAD
	_view_mode_btn.offset_top = STAGE_PAD + UIStyle.BTN_HEIGHT + 6.0
	_view_mode_btn.offset_bottom = STAGE_PAD + UIStyle.BTN_HEIGHT * 2.0 + 6.0
	_view_mode_btn.item_selected.connect(_on_view_mode_selected)
	_stage_view.add_child(_view_mode_btn)

	# ★ 第二十八轮续 3 / 4：右下角**竖直摄像机距离滑条**（精细控制视距）。
	#   放在舞台层的最后一层（后建 ⇒ 压在城市/铭牌之上），底端留出页面右下角缩放手柄。
	#   0 = 底端远、1 = 顶端近；上半截 = 最近~1.10R，下半截 = 1.10R~7R（见 get/set_zoom_fraction）。
	_zoom_panel = PanelContainer.new()
	_zoom_panel.name = "ZoomBar"
	_zoom_panel.add_theme_stylebox_override("panel", _side_column_stylebox())
	_zoom_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_zoom_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_zoom_panel.offset_left = -STAGE_PAD - 70.0
	_zoom_panel.offset_right = -STAGE_PAD
	_zoom_panel.offset_top = -STAGE_PAD - 330.0
	_zoom_panel.offset_bottom = -STAGE_PAD - 26.0
	_stage_view.add_child(_zoom_panel)

	var zoom_col := VBoxContainer.new()
	zoom_col.add_theme_constant_override("separation", 2)
	_zoom_panel.add_child(zoom_col)
	var zoom_lab := _make_label("视距", UIStyle.FONT_SIZE, Color(0.72, 0.78, 0.86))
	zoom_lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	zoom_col.add_child(zoom_lab)
	_zoom_readout = _make_label("—", UIStyle.FONT_SIZE, Color(0.75, 0.92, 1.0))
	_zoom_readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_zoom_readout.clip_text = true
	zoom_col.add_child(_zoom_readout)
	var zoom_near := _make_label("近", UIStyle.FONT_SIZE, Color(0.72, 0.78, 0.86))
	zoom_near.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	zoom_col.add_child(zoom_near)
	_zoom_slider = VSlider.new()
	_zoom_slider.name = "ZoomSlider"
	_zoom_slider.min_value = 0.0
	_zoom_slider.max_value = 1.0
	_zoom_slider.step = 0.001
	_zoom_slider.value = 0.5
	_zoom_slider.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_zoom_slider.custom_minimum_size = Vector2(0.0, 180.0)
	_zoom_slider.tooltip_text = "精细调整摄像机距离（上近下远）"
	_zoom_slider.value_changed.connect(_on_zoom_slider_changed)
	_zoom_slider.drag_started.connect(_on_zoom_drag_started)
	_zoom_slider.drag_ended.connect(_on_zoom_drag_ended)
	zoom_col.add_child(_zoom_slider)
	var zoom_far := _make_label("远", UIStyle.FONT_SIZE, Color(0.72, 0.78, 0.86))
	zoom_far.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	zoom_col.add_child(zoom_far)


## 「世界节点」列表 = **左侧延伸列**（固定宽度、竖直撑满；显隐由 _set_list_open 控制，
## 开合靠 _relayout 让面板向左延伸）。
## ★ 第二十五轮：整列加**深色底板** —— 照「设备管理主页」内层区块的做法
##   （`FILL_LEVEL_STAGE` + `STAGE_BORDER` + 0.6× 圆角，见 ui/device_manager_panel.gd）。
##   之前是"无独立底板、与页面背景无缝"，在白天面地形上会和画面糊在一起。
func _build_list_block() -> Control:
	var col_panel := PanelContainer.new()
	col_panel.name = "NodeListBlock"
	col_panel.add_theme_stylebox_override("panel", _side_column_stylebox())
	col_panel.custom_minimum_size = Vector2(LIST_W, 0.0)
	col_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col_panel.add_child(col)

	var title := _make_label("世界节点", UIStyle.FONT_SIZE, Color(0.75, 0.92, 1.0))
	col.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.name = "NodeScroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)

	_list_box = VBoxContainer.new()
	_list_box.name = "NodeRows"
	_list_box.add_theme_constant_override("separation", 2)
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list_box)
	return col_panel


## 两侧延伸列的**深色底板**样式（照「设备管理主页」内层区块：深色 + 细描边 + 0.6× 圆角）。
func _side_column_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = UIStyle.FILL_LEVEL_STAGE
	sb.border_color = UIStyle.STAGE_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(int(UIStyle.CORNER_RADIUS * 0.6))
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb


## 「节点内容 / 节点属性」= **右侧延伸列**（与左侧「世界节点」同宽、同样有**深色底板**，竖直撑满）。
## 现阶段内容：① 选中对象的信息（城市：名称 / 纬度 / 经度 / 上级节点）
##            ②「可用操作」区（★ **仅调试模式**显示：「编辑节点属性」入口）。
func _build_content_block() -> Control:
	var col_panel := PanelContainer.new()
	col_panel.name = "NodeContentBlock"
	col_panel.add_theme_stylebox_override("panel", _side_column_stylebox())
	col_panel.custom_minimum_size = Vector2(CONTENT_W, 0.0)
	col_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col_panel.add_child(col)

	col.add_child(_make_label("节点内容", UIStyle.FONT_SIZE, Color(0.75, 0.92, 1.0)))

	_sel_rows.clear()
	for nm in ["名称", "纬度", "经度", "海拔", "人口密度", "气候", "当地时间", "上级节点"]:
		col.add_child(_build_kv_row(nm, "—", true))

	# ★ 第二十九轮「关注」：放在节点内容里、紧随信息行（玩家视角的按钮，**不**属于调试工具区）。
	_follow_btn = UIBtn.new()
	_follow_btn.set_id("follow")
	_follow_btn.set_label("关注")
	_follow_btn.custom_minimum_size = Vector2(0.0, UIStyle.BTN_HEIGHT)
	_follow_btn.disabled = true
	_follow_btn.pressed_id.connect(_on_follow_pressed)
	col.add_child(_follow_btn)

	# ---- 可用操作（★ 只有调试模式才显示；显隐由 _apply_debug_visibility 统一管）----
	_ops_block = VBoxContainer.new()
	_ops_block.name = "OpsBlock"
	_ops_block.add_theme_constant_override("separation", 6)
	col.add_child(_ops_block)
	_ops_block.add_child(_make_label("可用操作", UIStyle.FONT_SIZE, Color(0.75, 0.92, 1.0)))
	_prop_btn = UIBtn.new()
	_prop_btn.set_id("node_prop_open")
	_prop_btn.set_label("编辑节点属性")
	_prop_btn.custom_minimum_size = Vector2(0.0, UIStyle.BTN_HEIGHT)
	_prop_btn.pressed_id.connect(_on_open_prop_pressed)
	_ops_block.add_child(_prop_btn)
	# ★ 第二十八轮续 3：这条说明原本是**一行长文本**，在调试模式下把 220px 的右侧列撑到 600+px，
	#   整个页面跟着变形。改成可自动换行的短句（任意字符处断行，中文才换得动），
	#   `custom_minimum_size.x = 1` 让 Label 的「最小宽度」归零 ⇒ 列宽恒等于 CONTENT_W。
	var hint := _make_label("星体节点请在列表或铭牌右键菜单中编辑",
		UIStyle.FONT_SIZE, Color(0.62, 0.68, 0.76))
	hint.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	hint.custom_minimum_size = Vector2(1.0, 0.0)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ops_block.add_child(hint)
	return col_panel


## 调试模式开关 → 「可用操作」区显隐（★ 编辑入口只给调试模式看，与「编辑积木属性」同一套规矩）。
func _apply_debug_visibility() -> void:
	var on := Debug.debug_mode
	if _ops_block != null and is_instance_valid(_ops_block):
		_ops_block.visible = on
	if _prop_btn != null and is_instance_valid(_prop_btn):
		_prop_btn.disabled = not on or _sel_host < 0


func _on_debug_mode_changed(_on: bool) -> void:
	_apply_debug_visibility()
	if not Debug.debug_mode and _prop_panel != null and is_instance_valid(_prop_panel):
		_prop_panel.close()          # 退出调试模式就把属性窗收掉（别让玩家看到编辑窗）


## 一行「标签 : 值」。`keep_value = true` ⇒ 把值 Label 记进 `_sel_rows`（选中变化时要刷新的那几行）。
func _build_kv_row(key: String, value: String, keep_value: bool = false) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var kl := _make_label(key, UIStyle.FONT_SIZE, Color(0.72, 0.78, 0.86))
	kl.custom_minimum_size = Vector2(62.0, 0.0)
	row.add_child(kl)
	var vl := _make_label(value, UIStyle.FONT_SIZE, Color.WHITE)
	vl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vl.clip_text = true       # 城市名可能很长 ⇒ 截断显示，别把列撑宽
	row.add_child(vl)
	if keep_value:
		_sel_rows.append(vl)
	return row


## 顶栏：移动把柄 + 标题 + × 关闭。★ 它现在挂在**舞台列**里（列表是 body 左延伸列）→ 列表开合不动它。
func _build_top_bar() -> HBoxContainer:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)

	_drag_handle = UIDragHandle.new()
	_drag_handle.setup(self)
	top.add_child(_drag_handle)

	_title_label = _make_label("", 16, Color.WHITE)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_title_label)

	_close_btn = UIBtn.new()
	_close_btn.set_id("world_close")
	_close_btn.set_label("×")   # 复用其它页面（背包/属性面板）的叉叉关闭按钮
	_close_btn.custom_minimum_size = Vector2(28.0, 28.0)
	_close_btn.pressed_id.connect(_on_close_pressed)
	top.add_child(_close_btn)
	return top


func _on_close_pressed(_id: String) -> void:
	set_page_visible(false)


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


func _on_resize_increment(inc: Vector2) -> void:
	if inc == Vector2.ZERO:
		return
	size = _clamp_size(size + inc)


## 「反转滚轮」：读设置页·世界页写下的全局设置（settings.json 的 world_invert_wheel）。
func _read_invert_wheel() -> bool:
	return WorldView.read_invert_wheel_setting()


## 「反转鼠标」：读设置页·世界页写下的全局设置（settings.json 的 world_invert_mouse）。
func _read_invert_mouse() -> bool:
	return WorldView.read_invert_mouse_setting()


## 把两个开关同步给 3D 视图（打开页面时、以及每次交互前各同步一次 → 设置页刚改过也立刻生效）。
func _refresh_invert_flags() -> void:
	if _world_view == null or not is_instance_valid(_world_view):
		return
	_world_view.invert_wheel = _read_invert_wheel()
	_world_view.invert_mouse = _read_invert_mouse()


func _current_title() -> String:
	return str(GlobalVars.get_var(title_var, ""))


func _refresh_title() -> void:
	if _title_label != null and is_instance_valid(_title_label):
		_title_label.text = _current_title()


func _on_var_changed(var_name: String, _value: Variant) -> void:
	if var_name == title_var:
		_refresh_title()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		_panning = false
		# 页面被藏起来（桌面切走 / 关页）时菜单也跟着收，别留在别的界面上。
		_plate_press_sid = ""
		_close_anchor_menu()
