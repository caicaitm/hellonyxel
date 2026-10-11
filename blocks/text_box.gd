# text_box.gd
# 积木上的文本框（与积木本体独立）。
# 与积木本体的区别：
#   - 边框/填充只允许「RGB码+透明度」或「图片路径」，不能用动图。
#   - 有文本框名、自身旋转角度、是否随积木旋转等独立变量。
class_name TextBox
extends Resource

# 文本框填充来源：纯色 / 图片（无动图）
enum FillSource { SOLID, IMAGE }

# 变量变化通知：直接复用 Resource 自带的 changed 信号 / emit_changed()。
# 任何「可由事件/脚本修改」的变量被赋值后 emit_changed()，Block 据此刷新视图，
# 事件链脚本只要给变量赋值即可立刻生效，无需手动通知视图（不做轮询）。
# 注意：不要在本类里另写 `signal changed` —— Resource 基类已有同名信号，会冲突。

@export var name: String = ""                       # 文本框名
@export var width: float = 200.0
@export var height: float = 48.0
@export var center_offset: Vector2 = Vector2.ZERO   # 相对「积木中心」的偏移
@export var border_color: Color = Color(1, 1, 1, 1)
@export var fill_source: FillSource = FillSource.SOLID
@export var fill_color: Color = Color(0.2, 0.65, 1.0, 0.7)
@export var fill_image_path: String = ""            # 仅图片路径，不能用动图
@export var rotation_deg: float = 0.0               # 度
@export var follow_block_rotation: bool = true      # 是否随积木旋转而旋转
@export var text_def: String = ""                   # (修饰变量)[内容] 格式，详见 text_renderer.gd

# ---------- 「内容为空时是否隐藏」（可被事件修改）----------
# 语义：本文本框的「内容」= 文本（text_def 经变量求值后）+ 填充图片（fill_image_path）。
#   二者都为空 → 视为「内容为空」；此时若本项为 true，则整个文本框（含背景与边框）都不显示。
# 注意：纯色填充色不算「内容」——那只是底色，不是文本/图片内容。
#
# 为什么用 backing 变量 + setter：
#   赋值即 emit_changed()，Block 收到后立刻刷新视图 → 「事件改变量 → 画面立刻变」，无需轮询。
# 事件链 / 脚本修改方式（两种等价）：
#   var tb = block.find_text_box("标题")
#   if tb != null:
#       tb.hide_when_empty = true          # 直接赋值（自动刷新）
#   block.set_text_box_var("标题", "hide_when_empty", true)   # 或走 Block 的统一入口
var _hide_when_empty: bool = false
@export var hide_when_empty: bool = false:
	get:
		return _hide_when_empty
	set(value):
		if _hide_when_empty == value:
			return
		_hide_when_empty = value
		emit_changed()

# 该文本框是否为空（无定义则不绘制文本）
func has_text() -> bool:
	return text_def != ""

# 是否指定了填充图片（= 图片内容）。路径没接资源系统前，以「路径非空」为判据。
func has_image() -> bool:
	return fill_source == FillSource.IMAGE and not fill_image_path.strip_edges().is_empty()

# ============ 预留文本框预设（属性面板「快速添加预设文本框」下拉）============
# 设计：预设表与生成逻辑放这里（TextBox 是无 autoload 依赖的纯 Resource，便于独立测试），
#       属性面板只负责「下拉选择 → 调 TextBox.preset_dict → 建编辑器」。
#
# 字段：
#   label  显示名（用作文本框名，面板侧会做同名冲突检测：拒绝创建，不自动改名）
#   follow 是否随积木旋转（true=随旋转；false=保持世界轴向，文本始终正向可读）
#   border / fill 边框色 / 填充色（#RRGGBBAA；透明 = alpha 0）
#   w_mul / h_mul 宽 / 高相对积木的倍数；cy_mul 中心 Y 相对积木高的倍数（中心 X 恒为 0）
const PRESETS: Dictionary = {
	"internal": { "label": "内部显示框", "follow": true,  "border": "#00000000", "fill": "#00000000", "w_mul": 1.0, "h_mul": 1.0, "cy_mul": 0.0 },
	"top":      { "label": "顶部显示框", "follow": false, "border": "#00000000", "fill": "#00000000", "w_mul": 2.0, "h_mul": 1.0, "cy_mul": 0.8 },
	"bottom":   { "label": "底部显示框", "follow": false, "border": "#00000000", "fill": "#00000000", "w_mul": 2.0, "h_mul": 1.0, "cy_mul": -0.8 },
	"bubble":   { "label": "冒泡对话框", "follow": false, "border": "#000000FF", "fill": "#FFFFFFFF", "w_mul": 3.0, "h_mul": 1.0, "cy_mul": 1.5 },
}

static func preset_label(key: String) -> String:
	if PRESETS.has(key):
		return PRESETS[key]["label"]
	return ""

# 生成一份 TextBox 编辑器数据（与 PropertyEditorPanel._make_tb_editor 输入格式一致）。
# block_w / block_h 为积木当前宽高；尺寸 / 偏移以它们为基准即时快照，
# 不随积木后续改尺寸自动变（与现有 TextBox 模型一致）。
static func preset_dict(key: String, block_w: float, block_h: float) -> Dictionary:
	if not PRESETS.has(key):
		return {}
	var p: Dictionary = PRESETS[key]
	return {
		"name": preset_label(key),
		"width": maxf(1.0, block_w * float(p["w_mul"])),
		"height": maxf(1.0, block_h * float(p["h_mul"])),
		"cx": 0.0,
		"cy": block_h * float(p["cy_mul"]),
		"border_color": str(p["border"]),
		"fill_color": str(p["fill"]),
		"fill_source": 0,
		"fill_image_path": "",
		"rotation_deg": 0.0,
		"follow_block_rotation": bool(p["follow"]),
		"text_def": "",
		"hide_when_empty": false,
	}
