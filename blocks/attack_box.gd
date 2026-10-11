# attack_box.gd
# 积木上的「攻击判定框」（仅用于近战判定，仿照 TextBox 设计）。
# 与积木本体独立，是一个相对积木中心定位的矩形判定区。
#
# 字段：
#   name            框名
#   center_offset   中心位置 = 相对「积木中心」的偏移（px）。标准 Godot 约定：+X 向右、+Y 向下。
#   width / height  判定框宽高（px）
#   enable_condition  启用条件（字符串表达式，如 "facing == right"；空 = 恒启用）
#   attack_power      攻击力函数（字符串表达式，引用积木的 base_attack，如 "base_attack*1"）
#
# 执行判定本体在后续阶段（近战系统）；本类只负责数据模型 + 预设生成。
class_name AttackBox
extends Resource

# 变量变化通知：与 TextBox 同款，复用 Resource 自带的 changed 信号。
# 事件链 / 脚本给变量赋值后 emit_changed()，运行时系统据此刷新判定框状态。

@export var name: String = "判定框"
@export var width: float = 120.0
@export var height: float = 120.0
@export var center_offset: Vector2 = Vector2.ZERO   # 相对「积木中心」的偏移
@export var enable_condition: String = ""           # 启用条件（字符串表达式）
@export var attack_power: String = ""               # 攻击力函数（字符串表达式）

# ============ 预留攻击判定框预设（属性面板「快速添加判定框」下拉）============
# 尺寸 / 偏移以「积木当前宽高」为基准即时快照（不随积木后续改尺寸自动变，与 TextBox 一致）。
#   cx_mul / cy_mul  中心 X / Y 相对积木宽 / 高的倍数（标准 Godot：+Y 向下）
#   w_mul / h_mul     宽 / 高相对积木的倍数
#   enable           默认启用条件（空 = 恒启用）
#   attack           默认攻击力函数（引用积木预留变量 base_attack）
const PRESETS: Dictionary = {
	"horizontal": {
		"label": "水平普攻",
		"cx_mul": 1.5, "cy_mul": 0.0,          # 中心在积木正中右侧 1.5 倍宽处
		"w_mul": 2.0, "h_mul": 2.0,            # 宽 2 倍积木宽、高 2 倍积木高
		"enable": "facing == right",           # 启用条件：积木朝向为右
		"attack": "base_attack*1",
	},
	"fall": {
		"label": "下落攻击框",
		"cx_mul": 0.0, "cy_mul": 1.0,          # 中心在积木正下方 1 倍高处（+Y 向下）
		"w_mul": 3.0, "h_mul": 1.0,            # 宽 3 倍积木宽、高 1 倍积木高
		"enable": "",                          # 未指定启用条件 → 恒启用
		"attack": "base_attack*3",
	},
}

static func preset_label(key: String) -> String:
	if PRESETS.has(key):
		return PRESETS[key]["label"]
	return ""

# 生成一份 AttackBox 编辑器数据（与 PropertyEditorPanel._make_ab_editor 输入格式一致）。
# block_w / block_h 为积木当前宽高；尺寸 / 偏移以它们为基准即时快照。
static func preset_dict(key: String, block_w: float, block_h: float) -> Dictionary:
	if not PRESETS.has(key):
		return {}
	var p: Dictionary = PRESETS[key]
	return {
		"name": preset_label(key),
		"width": maxf(1.0, block_w * float(p["w_mul"])),
		"height": maxf(1.0, block_h * float(p["h_mul"])),
		"cx": block_w * float(p["cx_mul"]),
		"cy": block_h * float(p["cy_mul"]),
		"enable_condition": str(p["enable"]),
		"attack_power": str(p["attack"]),
	}