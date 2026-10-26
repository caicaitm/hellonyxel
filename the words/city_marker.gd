# the words/city_marker.gd
# 城市**标识**（第十九轮 · 城市节点原型）：一个只画图形的 Control —— 四种等级四种图形。
#   capital 首都 / 首府   = **五角星**
#   metro   大·特大城市   = **双圈**（圈内一个圈）
#   medium  中型城市      = **圈内点**
#   small   小型城市      = **单圈**
#
# ★ 尺寸：**基准尺寸恒定**（BOX_SIZE = 20px），但由 WorldPage 用 `Control.scale` 统一缩放 ——
#   第十九轮曾经「远近都画一样大」，第二十一轮用户反馈「无论摄像头多远都一样大」⇒ 改为
#   **随放大倍数缩放**（缩放因子与去重格宽同源，见 world_page.gd 的 CITY_MARK_REF_PX）。
#   这里只管「1.0× 时长什么样」，缩放是外面的事。
# ★ 为什么用 `_draw()` 程序化画、而不是准备 4 张图片：图形很简单，而标识要能在**任意缩放下**都锐利
#   —— 矢量画出来天然可缩放，比引图片省事，也不用占素材库、不用管贴图导入。
# ★ 为什么每种图形都画两遍（先深色描边、再主色）：地球的白天侧是亮海面/亮云、夜晚侧近黑，
#   单色标识总有一侧看不清；深色描边保证两侧都能读出来（与铭牌文字用深色描边同一个理由）。
class_name CityMarker
extends Control

const TIER_CAPITAL := "capital"
const TIER_METRO := "metro"
const TIER_MEDIUM := "medium"
const TIER_SMALL := "small"
## ★ 第三十轮：玩家位置标记 —— 倒置红色等腰三角形，尖尖指向玩家在地球上的位置。
const TIER_PLAYER := "player"

## 标识的方形边长（px）：所有图形都画在这个方框内，方框中心 = 城市的投影点。
const BOX_SIZE := 20.0
const STAR_RADIUS := 7.0      # 五角星的外接半径
const RING_RADIUS := 5.0      # 双圈 / 圈内点（大档）的外圈半径
## ★ 第二十八轮续：小城市（单圈）再小一圈 —— 用户要求它明显小于首府与大城市的标识。
##   3.8 / 5.0 = 76%，直径差 24%；与「单圈出现在更近的距离」配合，密集区不再被小圈糊满。
const SMALL_RING_RADIUS := 3.8
const INNER_RATIO := 0.5      # 双圈的内圈半径 ÷ 外圈半径
const DOT_RATIO := 0.28       # 圈内点的中心点半径 ÷ 外圈半径
const LINE_WIDTH := 1.6       # 线条宽（px）
const OUTLINE_EXTRA := 2.0    # 描边比主图形宽出的像素（画两遍的第二遍差）
## ---- 玩家位置标记（倒置红色等腰三角形）----
## ★ 三角形的半宽与高度（px）：尖尖朝下，底边在上。
const TRI_HALF_W := 6.0
const TRI_H := 10.0
## ★ 第二十三轮：**选中态** —— 在标识外再叠一个「四角直角括号」的选择框（比本体大出 SELECT_PAD）。
##   ★ 第二十六轮按用户要求由「一圈青色圆环」改为 **四个直角组成的方框**（不完整的正方形：
##     四个角落各画一个 L 形括号、**每条边的中段留空不画**）—— 比整圈更轻巧、不压住标识本体。
##   为什么用括号而非"改变标识本身的颜色"好：标识颜色已经是四种等级的统一色，改色会与等级语义打架；
##   多一个框则「选中的是这一座」一目了然，且在白底（白天面）与黑底（夜面）上都读得出。
const SELECT_COLOR: Color = Color(0.35, 0.95, 1.0, 0.95)
const SELECT_WIDTH: float = 1.8
const SELECT_PAD: float = 4.5      # 选择框半边长比标识本体大出的像素
const CORNER_ARM: float = 6.0      # 每个直角的两条臂长（px；与标识一起随放大倍数缩放）

var tier: String = TIER_SMALL
var marker_color: Color = Color.WHITE
var outline_color: Color = Color(0.06, 0.06, 0.08, 0.9)
## 是否被选中（由 WorldPage 按「持有该城市的槽位」置位；自身只管重画）
var selected: bool = false:
	set(v):
		if selected == v:
			return
		selected = v
		queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(BOX_SIZE, BOX_SIZE)
	size = Vector2(BOX_SIZE, BOX_SIZE)


## 设定等级与配色（配色由 WorldPage 统一给，见其 CITY_* 常量）。
func configure(t: String, color: Color, outline: Color) -> void:
	tier = t
	marker_color = color
	outline_color = outline
	queue_redraw()


func _draw() -> void:
	var c := size * 0.5
	match tier:
		TIER_CAPITAL:
			draw_colored_polygon(_star_points(c, STAR_RADIUS + OUTLINE_EXTRA), outline_color)
			draw_colored_polygon(_star_points(c, STAR_RADIUS), marker_color)
		TIER_METRO:
			_ring(c, RING_RADIUS)
			_ring(c, RING_RADIUS * INNER_RATIO)
		TIER_MEDIUM:
			_ring(c, RING_RADIUS)
			draw_circle(c, RING_RADIUS * DOT_RATIO + OUTLINE_EXTRA * 0.5, outline_color)
			draw_circle(c, RING_RADIUS * DOT_RATIO, marker_color)
		TIER_PLAYER:
			var pts := PackedVector2Array([
				c + Vector2(0.0, TRI_H * 0.5),                    # 尖尖（底，指向玩家位置）
				c + Vector2(-TRI_HALF_W, -TRI_H * 0.5),           # 左上
				c + Vector2(TRI_HALF_W, -TRI_H * 0.5),            # 右上
			])
			draw_colored_polygon(pts, outline_color)
			var inner := PackedVector2Array([
				c + Vector2(0.0, TRI_H * 0.5 - 1.0),
				c + Vector2(-TRI_HALF_W + 1.0, -TRI_H * 0.5 + 1.0),
				c + Vector2(TRI_HALF_W - 1.0, -TRI_H * 0.5 + 1.0),
			])
			draw_colored_polygon(inner, marker_color)
		_:
			_ring(c, SMALL_RING_RADIUS)
	if selected:
		# 选择框：四个直角括号，先深色垫底再青色（与标识本体同一套「两遍」画法 ⇒ 亮面/暗面都读得出）
		var base := STAR_RADIUS if tier == TIER_CAPITAL else (
			SMALL_RING_RADIUS if tier == TIER_SMALL else (
			maxf(TRI_HALF_W, TRI_H * 0.5) if tier == TIER_PLAYER else RING_RADIUS))
		_corner_brackets(c, base + SELECT_PAD)


## 四角直角括号（不完整的正方形）：四个角落各画一个 L 形，**边的中段不画**。
## 每个角 = 从角点出发、向内侧各延伸 `arm` 的一段水平线段 + 一段垂直线段（两遍描边）。
func _corner_brackets(c: Vector2, half: float) -> void:
	var arm := minf(CORNER_ARM, half)   # 臂长不超过半边长，免得相邻两角的臂在中段接上
	for sx: float in [-1.0, 1.0]:
		for sy: float in [-1.0, 1.0]:
			var p := c + Vector2(sx * half, sy * half)
			var qx := p - Vector2(sx * arm, 0.0)   # 水平臂的内端
			var qy := p - Vector2(0.0, sy * arm)   # 垂直臂的内端
			draw_line(p, qx, outline_color, SELECT_WIDTH + OUTLINE_EXTRA, true)
			draw_line(p, qy, outline_color, SELECT_WIDTH + OUTLINE_EXTRA, true)
			draw_line(p, qx, SELECT_COLOR, SELECT_WIDTH, true)
			draw_line(p, qy, SELECT_COLOR, SELECT_WIDTH, true)


## 一圈（先深色描边、再主色）。`antialiased = true` ⇒ 斜边不会出锯齿。
func _ring(c: Vector2, r: float) -> void:
	draw_arc(c, r, 0.0, TAU, 36, outline_color, LINE_WIDTH + OUTLINE_EXTRA, true)
	draw_arc(c, r, 0.0, TAU, 36, marker_color, LINE_WIDTH, true)


## 五角星的 10 个顶点（外 / 内半径交替）。从正上方（−90°）起算 ⇒ 星尖朝上。
static func _star_points(c: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(10):
		var ang := -PI * 0.5 + float(i) * PI / 5.0
		var rr := r if i % 2 == 0 else r * 0.42
		pts.append(c + Vector2(cos(ang), sin(ang)) * rr)
	return pts
