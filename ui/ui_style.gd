# ui_style.gd
# UI 系统静态风格常量（从 abandon 版 0.1.2 UI 系统迁移，统一新版视觉风格）
class_name UIStyle
extends RefCounted

# 用 static var 而非 const，因为 Color 是动态类型
# —— 液态玻璃配色（批次 52）：纯白半透明填充、顶部更亮、荧光冰蓝描边、外发光 ——
# ★ 批次 58：悬停对比度增强 —— 原来 0.16→0.34 叠在磨砂模糊上几乎看不出变化，
#   鼠标移到按钮上没有"可点"的直觉反馈。现在 hover 提到 0.46，并新增更亮的
#   BORDER_HOVER（悬停描边亮起），两者叠加才够醒目。
static var FILL_DEFAULT: Color = Color(1.0, 1.0, 1.0, 0.16)      # 常规填充（纯白玻璃，高通透）
static var FILL_HOVER: Color = Color(1.0, 1.0, 1.0, 0.46)        # 悬停更亮（纯白；批次58 由 0.34 提到 0.46）
static var FILL_PRESSED: Color = Color(0.82, 0.88, 0.95, 0.66)   # 按下白玻璃加深（保留点按反馈）

static var BORDER: Color = Color(0.82, 0.93, 1.0, 0.65)          # 荧光冰蓝描边（减弱）
# 悬停描边：亮白 + 近乎不透明 → 鼠标移上去时整圈"亮起"，是最直观的可交互信号。
# ★ 刻意做成「主题无关」的亮白（classify_border 不认它 → 走自定义色路径，不随主题重算），
#   这样玻璃/纯色两套主题下的 hover 反馈完全一致。
static var BORDER_HOVER: Color = Color(1.0, 1.0, 1.0, 0.95)      # 悬停描边（亮白）
# 悬停描边加粗（比 BORDER_WIDTH 略粗，进一步强化"亮起"的观感）。
static var BORDER_WIDTH_HOVER: float = 2.5

# ---- 「控件底」专用填充（批次 58）----
#
# 为什么需要它：本项目面板背景（UIPanel）走**磨砂着色器**，其内部 alpha 被
# glass_blur.gdshader 压到 `tint.a * 0.25 + 0.02`（≈0.06 白）。而
# Theme 里的 Button / OptionButton 只能用 StyleBoxFlat（无着色器），会以
# `FILL_DEFAULT`（0.16 白）整块铺开 → 在深色桌面上比面板亮 5~7 倍，
# 看上去就是"另一套主题（半透明纯色）"的一块实心板。
# 故给「面板内部的控件底」单开一个角色，权重与磨砂面板对齐；
# 悬停/按下仍用 FILL_HOVER / FILL_PRESSED（要的就是"亮起来"的反馈）。
static var FILL_SURFACE: Color = Color(1.0, 1.0, 1.0, 0.06)     # 控件静止态（= 面板内部的实际权重）

# 液态玻璃增强参数（供 UIPanel 渐变/高光/光晕使用）
static var GLASS_TOP: Color = Color(1.0, 1.0, 1.0, 0.28)         # 渐变顶部（纯白，更亮更透）
static var GLASS_BOTTOM: Color = Color(0.90, 0.94, 0.99, 0.42)   # 渐变底部（纯白微冷）
static var GLASS_HIGHLIGHT: Color = Color(1.0, 1.0, 1.0, 0.42)   # 顶部高光（镜面反射，减弱）
static var GLASS_GLOW: Color = Color(0.50, 0.78, 1.0, 0.14)      # 外发光（环境光晕，减弱）
static var GLASS_REFRACT: float = 14.0                            # 边框折射强度（像素位移）
# 边框「光线散射 / 色散」参数（批次 52 追加）：让边框不再是单调白线，而分解出彩色光带。
static var GLASS_DISPERSION: float = 6.0                          # 色散强度（RGB 偏移差，像素）
static var GLASS_IRIDESCENCE: float = 0.75                        # 虹彩强度（0=纯描边色，1=全彩虹）
static var GLASS_SCATTER: float = 0.55                            # 外侧彩色散射光晕强度
# 薄膜干涉彩虹 + 表面反射高光（批次 52 追加）
static var GLASS_FILM: float = 0.42                               # 薄膜干涉强度（0=关）
static var GLASS_FILM_THICKNESS: float = 9.0                      # 薄膜厚度（影响条纹密度）
static var GLASS_SPECULAR: float = 0.55                           # 表面反射高光强度

# 磨砂背景模糊（SCREEN_TEXTURE）的**历史默认值**。
# ★ 批次 55 起，实际开关由「界面主题」决定：见 frosted_enabled()（玻璃主题 true / 纯色主题 false）。
#   UIPanel 不再直接读本常量，只保留它作为「玻璃主题默认开磨砂」的文档化常量。
static var GLASS_FROSTED: bool = true
static var GLASS_BLUR_RADIUS: float = 1.6   # 更轻的模糊（1.6px）→ 背景细节保留更多，通透感更强
static var GLASS_SHADER: String = "res://theme/glass_blur.gdshader"

# ==================== 界面主题模式（批次 55 / 59） ====================
#
# 三套主题：
#   · THEME_MODE_GLASS —— 透明液态玻璃（默认）：磨砂模糊 + 折射/虹彩/薄膜/表面高光。
#   · THEME_MODE_SOLID —— 半透明纯色：关闭模糊与全部玻璃增益，面板画成一层
#       「半透明纯色」平板（颜色由「主题色」决定），描边取同色系更深一档。
#   · THEME_MODE_HOLO  —— 量子全息（批次 59）：无边框 + 纯净透明荧光蓝 +
#       中心实/边缘虚的径向透明度（见下方「量子全息」一节）。
#
# 唯一权威值 = SaveManager 的 settings.json（ui_theme_mode / ui_theme_color）；
# 本文件只负责「读取 + 按模式派生颜色」，不自己存状态。
# （例外：设置页「预览」期间会被 _preview_* 临时覆盖，见下方「主题预览覆盖」一节。）
#
# ★ 运行时即时生效（无需重启）的三条通道：
#   · UIPanel 订阅 SaveManager.ui_theme_changed → 重算 frosted + 重取填充/描边；
#   · 由 UIStyle.glass_box() 造出的 StyleBox（含 GlassTheme 的默认控件样式、输入框
#     外观、滚动条等）都是**自更新**的 GlassBox 实例 → GlassTheme 收到信号后
#     统一 restyle_all_boxes()，控件持有的是同一实例，故无需触碰控件即完成换肤；
#   · 面板自绘（ui_panel.gd 的 _draw）在纯色模式下不再画外发光与顶部高光。
const THEME_MODE_GLASS := "glass"
const THEME_MODE_SOLID := "solid"
const THEME_MODE_HOLO := "holo"     # 量子全息（批次 59）：与液态玻璃平行
const THEME_MODE_DEFAULT := THEME_MODE_GLASS

## 合法主题模式列表（下拉构建 / 校验共用）。
static func theme_mode_list() -> Array:
	return [THEME_MODE_GLASS, THEME_MODE_SOLID, THEME_MODE_HOLO]


## 把任意字符串规整成合法主题模式（未知 → 透明液态玻璃）。
## ★ 全部「读模式」的地方都要走这里，避免每处各写一遍三元判断时漏掉新主题。
static func normalize_theme_mode(m: String) -> String:
	var v := str(m)
	if v == THEME_MODE_SOLID or v == THEME_MODE_HOLO:
		return v
	return THEME_MODE_GLASS

# 「半透明纯色」可选主题色：键（落盘用，ASCII 稳定）→ 显示名 / 基色 RGB。
# 均为「浅色 + 低饱和」，保证叠在桌面之上仍能看清白色文字（配合深色描边）。
static var SOLID_COLOR_KEYS: Array = ["ice", "sky", "mint", "sand", "dusk", "graphite"]
static var SOLID_COLOR_NAMES := {
	"ice": "冰蓝",
	"sky": "天青",
	"mint": "薄荷",
	"sand": "暖砂",
	"dusk": "薄暮",
	"graphite": "石墨",
}
static var SOLID_COLORS := {
	"ice": Color(0.62, 0.80, 0.98),
	"sky": Color(0.58, 0.90, 0.94),
	"mint": Color(0.64, 0.92, 0.80),
	"sand": Color(0.96, 0.88, 0.72),
	"dusk": Color(0.76, 0.72, 0.96),
	"graphite": Color(0.80, 0.83, 0.88),
}
const SOLID_COLOR_DEFAULT := "ice"
# 纯色模式描边的不透明度基准（会再乘调用方自己的透明度比例）。
const SOLID_BORDER_ALPHA := 0.90

# 玻璃模式各「填充角色」的基准色（同时也是 classify_fill 的判据）。
# ★ 必须与上面的 FILL_* 常量保持一致 —— classify_fill 靠"颜色是否等于基准色"来识别角色。
static var _GLASS_FILL_BASES := {
	"default": Color(1.0, 1.0, 1.0, 0.16),
	"surface": Color(1.0, 1.0, 1.0, 0.06),   # 面板内控件底（与磨砂面板同权重），见 FILL_SURFACE
	"hover": Color(1.0, 1.0, 1.0, 0.46),
	"pressed": Color(0.82, 0.88, 0.95, 0.66),
}
# 纯色模式下各角色的基准不透明度（再乘调用方的透明度比例）。
# ★ "surface" 与 "default" 同为 0.42 —— 纯色模式下控件底与面板底本就一致（无需区分）。
static var _SOLID_FILL_ALPHAS := {
	"default": 0.42,
	"surface": 0.42,
	"hover": 0.74,
	"pressed": 0.78,
}

# ==================== 量子全息（批次 59） ====================
#
# 第三套界面主题，与「透明液态玻璃」平行。三条硬特征（用户需求原文）：
#   ① 没有边框 —— 所有描边一律透明（连批次 58 的「悬停亮白描边」也不再画）；
#   ② 纯净透明荧光蓝 —— 整体是一层荧光蓝薄纱，不透出屏幕画面、不模糊；
#   ③ 中心透明度低、边缘透明度高 —— 椭圆径向 alpha 衰减（中心最实、向边缘转虚），
#      由 theme/holo_panel.gdshader 绘制 → 面板边界靠"淡出"收口，天然没有硬边。
#
# ★ 与液态玻璃的关键差别：全息面板**不采样 SCREEN_TEXTURE**（不做模糊/折射），
#   因此在 headless（dummy 渲染器）下同样能编译并生效，无需像玻璃那样降级为平板色。
#
# ★★ 调参速查（「有颜色范围 ↔ 纯透明范围」就靠这两个）：
#   · HOLO_CORE_SCALE  —— **有颜色的椭圆半径（相对半宽/半高）**。矩形面板对角距离约 1.414，
#     所以 0.92 时四角+外圈大片落到 clamp→edge_alpha（≈看不见）；1.30 时颜色几乎铺满，
#     只有最外圈/四角才淡出。**要「有颜色占比更大」就调大它**。
#   · HOLO_CORE_POWER  —— 衰减曲线陡度。越大→中段越实（颜色占比进一步上升、纯透明更快收口）。
#   · HOLO_CENTER_ALPHA / HOLO_EDGE_ALPHA —— 两端的不透明度（对比强度）。
static var HOLO_BLUE: Color = Color(0.38, 0.88, 1.00)     # 荧光蓝基色（偏亮青，配合中心提亮=发光感）
static var HOLO_CENTER_ALPHA: float = 0.48                # 中心不透明度（"透明度低"=更实）
static var HOLO_EDGE_ALPHA: float = 0.04                  # 边缘不透明度（"透明度高"=更虚）
static var HOLO_CORE_POWER: float = 2.80                  # 径向衰减曲线（越大中段越实）
static var HOLO_CORE_SCALE: float = 1.30                  # 径向核心半径（相对半宽/半高）★ 越大「有颜色」范围越大
static var HOLO_GLOW: float = 0.38                        # 中心"能量核"提亮强度（荧光感来源）
static var HOLO_SHADER: String = "res://theme/holo_panel.gdshader"

# 全息模式下各「填充角色」的基准不透明度（再乘调用方的透明度比例）。
# 比玻璃模式略实一点：全息没有描边兜底，控件需要靠自身底色被看见。
static var _HOLO_FILL_ALPHAS := {
	"default": 0.22,
	"surface": 0.18,
	"hover": 0.44,
	"pressed": 0.58,
}

# ==================== 主题「预览」覆盖（批次 56） ====================
#
# 需求：设置页里改「界面主题 / 主题色」下拉时，**先只把设置页自身刷成新主题**给用户看效果
# （预览），必须按「确定修改」才全局生效。
#
# 做法：下拉一变就把下面两个值设成下拉当前值 —— 于是任何「按当前主题现算颜色」的重算
# （UIPanel.refresh_theme / glass_box）读到的都是预览值。
# ★ 作用域由调用方（ui/settings_panel.gd）保证：它把设置页整棵子树的 .theme 换成
#   「预览主题副本」、并**只**刷新子树内的 UIPanel —— 所以其它面板既没被刷新、也没换
#   theme，本体颜色不受影响（它们的 StyleBox 是共享实例，但本次重算根本没碰它们）。
# ★ 调用方必须成对调用（set → clear），且 clear 要**先于**把子树换回共享主题并重算，
#   否则重算会读到预览值，把设置页留在预览配色上。
static var _preview_mode: String = ""
static var _preview_color: String = ""


## 开启 / 更新预览覆盖（参数 = 下拉当前值）。幂等。
static func set_theme_preview(mode: String, color_key: String) -> void:
	_preview_mode = normalize_theme_mode(mode)
	var k := str(color_key)
	_preview_color = k if not k.is_empty() else SOLID_COLOR_DEFAULT


## 关闭预览覆盖：此后一律读 SaveManager 的**已生效值**。
static func clear_theme_preview() -> void:
	_preview_mode = ""
	_preview_color = ""


## 是否处于预览态（探针 / 调试用）。
static func has_theme_preview() -> bool:
	return not _preview_mode.is_empty()


## 当前界面主题模式（预览覆盖 > SaveManager；取不到 → 默认玻璃）。
static func theme_mode() -> String:
	if not _preview_mode.is_empty():
		return _preview_mode
	var sm := _save_manager()
	if sm != null and sm.has_method("get_ui_theme_mode"):
		return normalize_theme_mode(str(sm.call("get_ui_theme_mode")))
	return THEME_MODE_DEFAULT


static func is_solid_mode() -> bool:
	return theme_mode() == THEME_MODE_SOLID


static func is_holo_mode() -> bool:
	return theme_mode() == THEME_MODE_HOLO


## 是否启用磨砂模糊（**只有「透明液态玻璃」需要** SCREEN_TEXTURE；
## 量子全息有自己的径向着色器，纯色主题则退化为平板）。
static func frosted_enabled() -> bool:
	return theme_mode() == THEME_MODE_GLASS


## 当前「主题色」键（预览覆盖 > SaveManager；空 → 默认冰蓝）。
static func theme_color_key() -> String:
	if not _preview_color.is_empty():
		return _preview_color
	var sm := _save_manager()
	if sm != null and sm.has_method("get_ui_theme_color"):
		var k := str(sm.call("get_ui_theme_color"))
		if not k.is_empty():
			return k
	return SOLID_COLOR_DEFAULT


## 当前主题色的基色 RGB（未知名 → 默认冰蓝）。
static func solid_base_color() -> Color:
	return SOLID_COLORS.get(theme_color_key(), SOLID_COLORS[SOLID_COLOR_DEFAULT])


## 主题色键 → 显示名（未知 → 原样返回）。
static func solid_color_name(key: String) -> String:
	return str(SOLID_COLOR_NAMES.get(key, key))


## 把颜色归类成「填充角色」：default / hover / pressed。
## 自定义色（关卡舞台深底、端口/连线色、强调色等）→ ""（保持原样，不随主题变）。
## 判据 = 与玻璃模式基准色比对（面板源码里传的就是这些常量本身或它们的透明度变体）。
static func classify_fill(c: Color) -> String:
	if _color_eq(c, _GLASS_FILL_BASES["default"]):
		return "default"
	if _color_eq(c, _GLASS_FILL_BASES["hover"]):
		return "hover"
	if _color_eq(c, _GLASS_FILL_BASES["pressed"]):
		return "pressed"
	# ★ 批次58：「控件底」角色 —— 容差刻意收紧（0.006），否则会把滚轮槽 0.05、
	#   列表底 0.08 等同类"白玻璃变体"一并吞掉（它们在纯色模式下的映射不同）。
	if _color_eq(c, FILL_SURFACE, 0.006):
		return "surface"
	if _rgb_eq(c, Color(1, 1, 1)):
		return "default"      # 白玻璃的透明度变体（如列表底 0.30 / 0.32 / 0.55）
	return ""


## 把颜色归类成描边角色：border / ""（自定义，保持原样）。
static func classify_border(c: Color) -> String:
	if _rgb_eq(c, BORDER, 0.03):
		return "border"
	return ""


## 该填充角色在玻璃模式下的基准不透明度 → 换算调用方自己的「透明度比例」。
static func fill_alpha_ratio(role: String, alpha: float) -> float:
	var base: Color = _GLASS_FILL_BASES.get(role, Color(1, 1, 1, 0.16))
	if base.a <= 0.0:
		return 1.0
	return alpha / base.a


static func border_alpha_ratio(alpha: float) -> float:
	if BORDER.a <= 0.0:
		return 1.0
	return alpha / BORDER.a


## 按「当前主题模式 + 主题色」算出填充角色实际要用的颜色。
static func theme_fill(role: String, ratio: float) -> Color:
	if is_holo_mode():
		# 量子全息：荧光蓝薄纱（不分主题色，恒为 HOLO_BLUE）。
		var ha: float = float(_HOLO_FILL_ALPHAS.get(role, 0.22))
		return Color(HOLO_BLUE.r, HOLO_BLUE.g, HOLO_BLUE.b, clampf(ha * ratio, 0.0, 0.85))
	var base: Color = _GLASS_FILL_BASES.get(role, Color(1, 1, 1, 0.16))
	if is_solid_mode():
		var c := solid_base_color()
		var a: float = float(_SOLID_FILL_ALPHAS.get(role, 0.42))
		return Color(c.r, c.g, c.b, clampf(a * ratio, 0.0, 0.85))
	return Color(base.r, base.g, base.b, clampf(base.a * ratio, 0.0, 1.0))


## 按「当前主题模式 + 主题色」算出描边色（纯色模式取同色系更深一档）。
static func theme_border(ratio: float) -> Color:
	if is_holo_mode():
		# ★ 量子全息：**无边框** —— 描边一律透明（alpha 0，颜色无所谓）。
		return Color(HOLO_BLUE.r, HOLO_BLUE.g, HOLO_BLUE.b, 0.0)
	if is_solid_mode():
		var c := solid_base_color()
		return Color(c.r * 0.50, c.g * 0.54, c.b * 0.60, clampf(SOLID_BORDER_ALPHA * ratio, 0.0, 1.0))
	return Color(BORDER.r, BORDER.g, BORDER.b, clampf(BORDER.a * ratio, 0.0, 1.0))


static func _rgb_eq(a: Color, b: Color, tol: float = 0.02) -> bool:
	return absf(a.r - b.r) <= tol and absf(a.g - b.g) <= tol and absf(a.b - b.b) <= tol


static func _color_eq(a: Color, b: Color, tol: float = 0.02) -> bool:
	return _rgb_eq(a, b, tol) and absf(a.a - b.a) <= tol


# 关卡页面「舞台」配色：深色背景用来托住关卡积木，比面板底色（天蓝）暗得多，
# 同时比纯黑多一点蓝，避免积木边框糊在一起。舞台不做磨砂，保持实心深底。
static var FILL_LEVEL_STAGE: Color = Color(0.035, 0.075, 0.135, 0.96)
static var STAGE_BORDER: Color = Color(0.16, 0.34, 0.52, 0.95)

static var TEXT_DEFAULT: Color = Color(1, 1, 1, 1)              # 白色文字
static var TEXT_PRESSED: Color = Color(0.70, 0.95, 1.0, 1.0)     # 按下时文字
# 文字描边（批次 52 追加）：纯白玻璃填充会压低白字对比度，加一圈深色描边保证可读性。
# 与项目既有先例（value_bar_view / text_box_view）一致，默认 3px。
static var TEXT_OUTLINE: Color = Color(0.02, 0.05, 0.11, 0.90)
static var TEXT_OUTLINE_SIZE: int = 3

static var BTN_HEIGHT: float = 28.0
static var BTN_MIN_WIDTH: float = 140.0
static var PANEL_PADDING: float = 4.0
static var BTN_SPACING: float = 2.0
static var BORDER_WIDTH: float = 1.5
static var CORNER_RADIUS: float = 10.0

static var FONT_SIZE: int = 14

# CJK 中文字体（黑体），避免中文渲染成黑块。
# 用懒加载避免 Godot 首次导入缓存未生成时 static var 初始化失败。
static var _cjk_font: FontFile = null
static func get_cjk_font() -> FontFile:
	if _cjk_font == null:
		_cjk_font = load("res://assets/fonts/simhei.ttf")
	return _cjk_font

# 输入框（LineEdit）统一外观。
# 为什么必须显式接管：默认主题给 LineEdit 的 normal/focus/read_only 三个 StyleBox
# 尺寸/留白与本项目面板不匹配，实测会在输入框内部多画出一个「内嵌空框」，故统一覆盖。
# ==================== 液态玻璃 StyleBox 工厂（批次 52 追加） ====================
# 说明：StyleBoxFlat 无法上着色器（无模糊/折射），但可用「半透明冰白底 + 双色描边 +
# 圆角 + 内高光近似 + 外阴影光晕」在引擎层面模拟液态玻璃的观感。
# 所有「杂项」控件（输入框 / 下拉 / 搜索框 / 列表高亮 / 小按钮）统一走这里，保证视觉一致。
#
# ★ 批次 55：返回的不再是裸 StyleBoxFlat，而是自更新的 **GlassBox**（见下），
#   从而「透明液态玻璃 ↔ 半透明纯色」与「主题色」变更可以运行时即时生效，
#   且**不需要重新构建任何面板**（控件持有的是同一个 StyleBox 实例）。
static var _live_boxes: Array = []   # 全部 glass_box 造出的实例（WeakRef，避免阻止释放）


# ---------------------------------------------------------------- 自更新 StyleBox
#
# 面板里大量 `UIStyle.glass_box(...)` 造出的 StyleBox 是**构建期烘焙**的：
# 直接给 bg_color 赋死颜色，主题一变就留在旧颜色上。GlassBox 只记「角色 + 透明度比例」，
# 颜色在 apply_theme_colors() 里按当前主题现算 → 换肤只需重算一次。
class GlassBox extends StyleBoxFlat:
	var fill_role: String = ""
	var fill_ratio: float = 1.0
	var fill_custom: Color = Color(1, 1, 1, 0.16)
	var border_role: String = ""
	var border_ratio: float = 1.0
	var border_custom: Color = Color(1, 1, 1, 0.0)
	var glow_flag: bool = false

	func apply_theme_colors() -> void:
		bg_color = UIStyle.theme_fill(fill_role, fill_ratio) if not fill_role.is_empty() else fill_custom
		border_color = UIStyle.theme_border(border_ratio) if not border_role.is_empty() else border_custom
		# ★ 批次59「量子全息」＝无边框：把**所有**描边压成透明 —— 包括"自定义描边"
		#   （悬停亮白 BORDER_HOVER、PopupMenu 冰蓝描边等，它们的角色为空、不会走
		#   theme_border 的重映射）。放在这里一次搞定，无需逐个调用方改。
		if UIStyle.is_holo_mode():
			border_color = Color(border_color.r, border_color.g, border_color.b, 0.0)
		# ★ 批次58：「外发光」不再用 StyleBoxFlat 的 shadow 模拟。
		#   原因（探针实测）：shadow 是画在**填充之下**的一块更大的圆角矩形，
		#   而控件填充是半透明的 → 阴影会从控件内部透出来，把它染成一块「灰蓝实心板」
		#   （静止态实测 ≈(0.28,0.34,0.40)，而磨砂面板只有 ≈0.06）。
		#   这正是用户报的「液态玻璃下部分按钮/下拉栏却是纯色半透明主题」的根因。
		#   现在控件只保留「纯白纱 + 冰蓝描边」，权重与面板一致；外发光只由面板着色器提供。
		shadow_size = 0
		shadow_offset = Vector2.ZERO


static func _register_box(sb: StyleBoxFlat) -> void:
	if _live_boxes.size() >= 512:
		_prune_boxes()
	_live_boxes.append(weakref(sb))


static func _prune_boxes() -> void:
	var out: Array = []
	for w in _live_boxes:
		if w is WeakRef and w.get_ref() != null:
			out.append(w)
	_live_boxes = out


## 主题模式 / 主题色变化后调用：把所有 glass_box 造出的 StyleBox 重算一遍。
##（UIPanel 不走这里，它自己订阅信号；见 ui/ui_panel.gd 的 refresh_theme）
static func restyle_all_boxes() -> void:
	_prune_boxes()
	for w in _live_boxes:
		var sb = w.get_ref() if w is WeakRef else null
		if sb != null and sb is GlassBox:
			sb.apply_theme_colors()


static func glass_box(fill: Color, border: Color, radius: int = 6, bw: int = 1, glow: bool = false) -> StyleBoxFlat:
	var sb := GlassBox.new()
	# 角色判定：命中主题调色板 → 记角色 + 透明度比例（换主题可无损重映射）；
	# 自定义色（强调色 / 深色下拉底等）→ 原样保存，不随主题变。
	sb.fill_role = classify_fill(fill)
	if sb.fill_role.is_empty():
		sb.fill_custom = fill
	else:
		sb.fill_ratio = fill_alpha_ratio(sb.fill_role, fill.a)
	sb.border_role = classify_border(border)
	if sb.border_role.is_empty():
		sb.border_custom = border
	else:
		sb.border_ratio = border_alpha_ratio(border.a)
	sb.glow_flag = glow
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(radius)
	# 圆角抗锯齿，避免小圆角出现阶梯锯齿（玻璃质感更顺滑）
	sb.anti_aliasing = true
	sb.anti_aliasing_size = 1.0
	sb.apply_theme_colors()
	_register_box(sb)
	return sb


static func line_edit_stylebox(focused: bool = false) -> StyleBoxFlat:
	# 液态玻璃输入框：半透明冰白玻璃底（通透、与面板一致），聚焦时描边加到冰蓝荧光色。
	var fill := Color(1.0, 1.0, 1.0, 0.10) if not focused else Color(1.0, 1.0, 1.0, 0.16)
	var brd := BORDER if focused else Color(0.80, 0.92, 1.0, 0.55)
	var sb := glass_box(fill, brd, 6, 1, focused)
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb


static func apply_line_edit_style(le: LineEdit) -> void:
	if le == null:
		return
	le.add_theme_stylebox_override("normal", line_edit_stylebox(false))
	le.add_theme_stylebox_override("focus", line_edit_stylebox(true))
	le.add_theme_stylebox_override("read_only", line_edit_stylebox(false))
	le.add_theme_color_override("font_color", TEXT_DEFAULT)
	le.add_theme_color_override("font_uneditable_color", Color(TEXT_DEFAULT.r, TEXT_DEFAULT.g, TEXT_DEFAULT.b, 0.55))
	le.add_theme_color_override("caret_color", TEXT_DEFAULT)
	le.add_theme_color_override("selection_color", Color(0.30, 0.75, 1.0, 0.45))


# 多行输入框（TextEdit）统一外观。与 LineEdit 同一套底色/边框，
# 额外接管 caret_color / selection_color / 当前行高亮（默认主题的高亮与本项目不合）。
static func apply_text_edit_style(te: TextEdit) -> void:
	if te == null:
		return
	te.add_theme_stylebox_override("normal", line_edit_stylebox(false))
	te.add_theme_stylebox_override("focus", line_edit_stylebox(true))
	te.add_theme_stylebox_override("read_only", line_edit_stylebox(false))
	te.add_theme_color_override("font_color", TEXT_DEFAULT)
	te.add_theme_color_override("font_placeholder_color", Color(TEXT_DEFAULT.r, TEXT_DEFAULT.g, TEXT_DEFAULT.b, 0.45))
	te.add_theme_color_override("caret_color", TEXT_DEFAULT)
	te.add_theme_color_override("selection_color", Color(0.30, 0.75, 1.0, 0.45))
	te.add_theme_color_override("current_line_color", Color(1, 1, 1, 0.06))
	te.add_theme_color_override("line_number_color", Color(1, 1, 1, 0.35))
	te.scroll_fit_content_height = false   # 固定高度 + 自己滚动（提示词要能放下一页内容）


# ============================ UI 缩放（⚠️实验性内容） ============================
#
# 需求：设置页的「UI 缩放比例」要真的缩放各面板（不再只是占位）。
#
# 实现载体 = 承载面板的 **CanvasLayer.scale**（层内所有 Control 一并缩放，面板内部布局完全不用改）。
# 唯一权威值 = SaveManager 的 settings.json `ui_scale`；本文件只做「读取 + 施加 + 订阅」。
#
# ★★ 坐标语义（已在 Godot 4.7.2 实测，改这块代码前务必先读）：
#   · CanvasLayer 的缩放**不改变**子节点的 position / global_position / get_global_rect()
#     —— 层变换只在**渲染**与**事件分发**时施加（global_transform 只到画布为止）。
#   · 子控件收到的 gui_input 事件坐标**已换算**到该控件本地 → 面板内按钮/滑条/输入框自动正确。
#   · 而 `_unhandled_input` 里的 `event.position`、`get_viewport().get_visible_rect()`
#     /`get_viewport_rect()` 全都是**视口像素（= 屏幕像素）**，与画布坐标差一个缩放倍率。
#   由此两条硬规则：
#     ① 面板的「居中 / 贴边 / 夹取」一律用 canvas_viewport_rect/size()（画布坐标），
#        直接读 get_visible_rect() 会让面板按缩放倍率偏移（缩放 2× 时居中的面板跑到右下角）；
#     ② 屏幕像素 → 画布坐标用 screen_to_canvas()（鼠标落点摆菜单/属性面板用）。
# ★ 不要让调试描边/穿透接收区去用画布坐标：它们必须留在**屏幕像素**（见 MousePassRunner）。

## SaveManager 取不到时（`--script` 探针 / 未入树）回落 1.0，保证任何环境都能算坐标。
static func _save_manager() -> Node:
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return null
	var root: Window = (loop as SceneTree).root
	if root == null:
		return null
	return root.get_node_or_null("SaveManager")


## 当前 UI 缩放（0.5 ~ 2.0，默认 1.0）。
static func ui_scale() -> float:
	var sm := _save_manager()
	if sm == null or not sm.has_method("get_ui_scale"):
		return 1.0
	return maxf(0.01, float(sm.call("get_ui_scale")))


## 把当前 UI 缩放施加到指定 CanvasLayer（层内所有 Control 一并缩放）。
static func apply_ui_scale(layer: CanvasLayer) -> void:
	if layer == null or not is_instance_valid(layer):
		return
	var f := ui_scale()
	layer.scale = Vector2(f, f)


## 立即施加一次 + 订阅后续变化（设置页改缩放时各面板当场跟着变）。
## 幂等：同一层重复调用只订阅一次（记在 meta 上）。
static func watch_ui_scale(layer: CanvasLayer) -> void:
	if layer == null or not is_instance_valid(layer):
		return
	apply_ui_scale(layer)
	var sm := _save_manager()
	if sm == null:
		return
	if layer.has_meta("_ui_scale_cb"):
		return
	var cb := func(f: float) -> void:
		if layer == null or not is_instance_valid(layer):
			return
		layer.scale = Vector2(maxf(0.01, f), maxf(0.01, f))
	layer.set_meta("_ui_scale_cb", cb)
	sm.connect("ui_scale_changed", cb)


## 某 CanvasItem 所在画布的缩放倍数（桌面/主场景画布 = 1，ui_layer = UI 缩放）。
static func canvas_scale(c: CanvasItem) -> Vector2:
	if c == null or not is_instance_valid(c):
		return Vector2.ONE
	var s: Vector2 = c.get_canvas_transform().get_scale()
	return Vector2(maxf(absf(s.x), 0.0001), maxf(absf(s.y), 0.0001))


## 某 CanvasItem 所在画布的「可见区矩形」，**画布坐标**（= 屏幕像素 ÷ 画布缩放）。
## 面板的居中/贴边/夹取一律用这个；`get_viewport().get_visible_rect()` 给的是视口像素。
static func canvas_viewport_rect(c: CanvasItem) -> Rect2:
	if c == null or not is_instance_valid(c):
		return Rect2(Vector2.ZERO, Vector2(1280.0, 720.0))
	var vp: Viewport = c.get_viewport()
	if vp == null:
		return Rect2(Vector2.ZERO, Vector2(1280.0, 720.0))
	return c.get_canvas_transform().affine_inverse() * vp.get_visible_rect()


static func canvas_viewport_size(c: CanvasItem) -> Vector2:
	return canvas_viewport_rect(c).size


## 屏幕像素（`event.position` / `get_global_mouse_position()` 在默认画布下的值）→ 该 CanvasItem 的画布坐标。
static func screen_to_canvas(c: CanvasItem, screen_pos: Vector2) -> Vector2:
	if c == null or not is_instance_valid(c):
		return screen_pos
	return c.get_canvas_transform().affine_inverse() * screen_pos
