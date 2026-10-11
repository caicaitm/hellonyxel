# value_bar.gd
# 积木上的「数值条（数值）」系统（与文本框独立）。
#
# 与文本框的区别：
#   - 文本框只展示文本；数值条展示一个「由变量驱动的比例」（生命/能量/体力/弹药 等）。
#   - 数值条必须「锚定变量」：current_var = 当前值变量名，max_var = 最大值变量名
#     （均指向全局变量，见 autoload/global_vars.gd）；任一变量变化 → 视图实时刷新。
#   - 两种样式：连续条（颜色填充 + 隔断）与图标（激活/消耗图标，消耗位可空或 auto 黑色剪影）。
#   - 横向：0 在最左，向右增长；纵向：0 在最下，向上增长。
#   - 显示：数值("当前/最大") 或 百分比("xx%"，精确到 1%)。
#
# 渲染由 blocks/value_bar_view.gd 负责；本类只是「纯数据 + 预设工厂」。
class_name ValueBar
extends Resource

# 样式
enum Style { CONTINUOUS, ICON }
# 朝向
enum Orientation { HORIZONTAL, VERTICAL }
# 显示内容
enum ShowMode { VALUE, PERCENT }

@export var name: String = ""                       # 数值条名称
@export var orientation: int = Orientation.HORIZONTAL
@export var style: int = Style.CONTINUOUS
@export var center_offset: Vector2 = Vector2.ZERO   # 相对「积木中心」的偏移
@export var width: float = 100.0
@export var height: float = 8.0
@export var show_mode: int = ShowMode.VALUE     # 显示数值 / 百分比

# ---- 绑定变量（★ 批次 19 改版：单一「对应变量」）----
# ★ 需求：把原来的「当前变量」+「最大变量」两个输入框**移除**，改为一个「对应变量」框。
#   bind_var 指向**局部变量**（本积木的，见 local_var.gd）优先；找不到同名局部变量时
#   **回退**到全局变量（autoload/GlobalVars），以兼容旧档 / 事件链的旧写法。
#
#   对「局部变量」而言，一条数值条只需要它一个名字：
#     分子 = 局部变量.current_value（现有值）
#     分母 = 局部变量.max_value（最大值）
#   这正是「一条血条不用手工填两个变量名」的收益。
#
# ★ current_var / max_var 仍保留为**兼容字段**（老 JSON 里存的是这两个）：
#   读档时若 bind_var 为空而 current_var 非空，会把 current_var 迁进 bind_var（见
#   BlockProperty.value_bar_from_dict）；新的属性面板不再写这两个字段。
@export var bind_var: String = ""
@export var current_var: String = ""   # ← 旧字段（兼容用，见上方说明）
@export var max_var: String = ""       # ← 旧字段（兼容用）

# ---- 连续条样式（Style.CONTINUOUS）----
@export var active_color: Color = Color(1, 0, 0, 1)       # 激活（已填充）部分
@export var consumed_color: Color = Color(0, 0, 0, 1)    # 消耗（已失去）部分
@export var segments: int = 1                            # 隔断段数（1 = 不分段）

# ---- 图标样式（Style.ICON）----
# 激活图标路径；消耗图标路径：
#   ""     = 消耗位不显示任何图标（只显示激活位）
#   "auto" = 用激活图标的「黑色剪影」填充消耗位（将图片不透明部分覆盖为纯黑）
#   其它路径 = 直接加载该图片作为消耗图标
@export var icon_active_path: String = ""
@export var icon_consumed_path: String = ""

# 变量变化通知：直接复用 Resource 原生的 emit_changed()（不要覆盖该方法，否则在
# 开启「警告即错误」的项目里会编译失败）。事件链/脚本给任意字段赋值后调用
# vb.emit_changed() 即可通知视图刷新；全局变量驱动的比例变化走 GlobalVars.changed，
# 由 ValueBarView 直接监听，不经过这里。
#
# 是否指定了激活图标（图标样式专用）
func has_active_icon() -> bool:
	return not icon_active_path.strip_edges().is_empty()

# ============ 预留数值条预设（属性面板「快速添加预设数值条」下拉）============
# 设计：预设表与生成逻辑放这里（纯 Resource，便于独立测试），
#       属性面板只负责「下拉选择 → 调 ValueBar.preset_dict → 建编辑器」。
#
# 字段（尺寸/偏移均以积木当前宽高为基准即时快照，不随积木后续改尺寸自动变）：
#   label      显示名（用作数值条名；面板侧做同名冲突检测）
#   orient     朝向
#   w_mul/h_mul 宽/高相对积木的倍数
#   cx_mul/cy_mul 中心偏移相对积木宽/高的倍数（中心 X 恒为 0）
#   style      样式
#   show       显示模式
#   bind       ★ 批次 19：绑定的「对应变量」名（局部变量优先，回退全局变量）。
#              预制各绑到同名局部变量：血条→HP / 能量条→能量 / 体力条→体力 / 弹药条→弹药。
#              局部变量不存在时会回退同名全局变量（兼容旧写法），都没有 → 比例 0。
#   ac/ cc     连续条 激活/消耗 颜色(#RRGGBBAA)
#   seg        隔断段数
#   ai/ ci     图标 激活/消耗 路径（ci 可空 / "auto"）
const PRESETS: Dictionary = {
	"health": {
		"label": "血条", "orient": Orientation.HORIZONTAL,
		"w_mul": 1.0, "h_mul": 0.05, "cx_mul": 0.0, "cy_mul": -0.6,
		"style": Style.CONTINUOUS, "show": ShowMode.VALUE,
		"bind": "HP",
		"ac": "#FF0000FF", "cc": "#000000FF", "seg": 10,
		"ai": "", "ci": "",
	},
	"energy": {
		"label": "能量条", "orient": Orientation.HORIZONTAL,
		"w_mul": 1.0, "h_mul": 0.05, "cx_mul": 0.0, "cy_mul": -0.58,
		"style": Style.CONTINUOUS, "show": ShowMode.VALUE,
		"bind": "能量",
		"ac": "#00BFFFFF", "cc": "#00000000", "seg": 1,
		"ai": "", "ci": "",
	},
	"stamina": {
		"label": "体力条", "orient": Orientation.VERTICAL,
		"w_mul": 0.05, "h_mul": 0.8, "cx_mul": -0.6, "cy_mul": 0.0,
		"style": Style.CONTINUOUS, "show": ShowMode.PERCENT,
		"bind": "体力",
		"ac": "#FFFF00FF", "cc": "#000000FF", "seg": 1,
		"ai": "", "ci": "",
	},
	"ammo": {
		"label": "弹药条", "orient": Orientation.VERTICAL,
		# ★ 批次 21：宽/高按需求放大 —— 宽 = 积木宽*0.6、高 = 积木高*1.0。
		#   中心偏移 cx/cy 仍取 0：让这条**贴着积木左侧**（宽 0.6 倍 → 右边留 0.4 倍空隙），
		#   高度撑满（1.0 倍）→ 图标格是细长条，弹药格数多时一眼数得清。
		"w_mul": 0.6, "h_mul": 1.0, "cx_mul": -0.2, "cy_mul": 0.0,
		"style": Style.ICON, "show": ShowMode.VALUE,
		"bind": "弹药",
		"ac": "#FFFFFFFF", "cc": "#000000FF", "seg": 1,
		"ai": "res://textures/value_bars/bullet.png", "ci": "auto",
	},
}

static func preset_label(key: String) -> String:
	if PRESETS.has(key):
		return PRESETS[key]["label"]
	return ""

# 生成一份 ValueBar 编辑器数据（与 PropertyEditorPanel._make_vb_editor 输入格式一致）。
# block_w / block_h 为积木当前宽高；尺寸 / 偏移以它们为基准即时快照。
static func preset_dict(key: String, block_w: float, block_h: float) -> Dictionary:
	if not PRESETS.has(key):
		return {}
	var p: Dictionary = PRESETS[key]
	return {
		"name": preset_label(key),
		"orientation": int(p["orient"]),
		"width": maxf(1.0, block_w * float(p["w_mul"])),
		"height": maxf(1.0, block_h * float(p["h_mul"])),
		"cx": block_w * float(p["cx_mul"]),
		"cy": block_h * float(p["cy_mul"]),
		"show_mode": int(p["show"]),
		# ★ 批次 19：预制数值条默认绑到同名局部变量（弹药条→弹药、体力条→体力…），
		#   属性面板「添加局部变量」下拉里有这几个预制，一绑即生效。
		"bind_var": str(p["bind"]),
		"style": int(p["style"]),
		"active_color": str(p["ac"]),
		"consumed_color": str(p["cc"]),
		"segments": int(p["seg"]),
		"icon_active_path": str(p["ai"]),
		"icon_consumed_path": str(p["ci"]),
	}
