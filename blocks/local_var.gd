# local_var.gd
# 积木的「局部变量」系统（与文本框 / 数值条并列的第三种子组件）。
#
# 设计意图（需求）：
#   积木身上可以带若干**局部变量**（弹药 / 体力 / 能量 / HP …），
#   每个变量自己带一组「可变数值」：最小值 / 最大值 / 现有值 / 恢复频率 / 回复量。
#   数值条可**绑定**到某个局部变量，直接用它的「现有值 / 最大值」算比例 ——
#   于是「一条血条」不必再手工填两个全局变量名，填一个局部变量名就够了。
#
# 与全局变量（autoload/GlobalVars）的关系：
#   · 局部变量是**积木私有**的：每块积木各有一份，互不干扰（全局变量是整个游戏共享一份）。
#   · 数值条的「对应变量」既可填局部变量名（优先），也可填全局变量名（回退），
#     保持对旧存档 / 旧写法的兼容。
#
# 恢复频率 / 回复量的语义（供将来事件链 / 计时器使用；本批只落数据）：
#   恢复频率 = 每隔多久恢复一次（秒）
#   回复量   = 每次恢复多少点（可负 = 持续流失，例如毒、饥饿）
#   计时器触发时按 `clamp(现有值 + 回复量, 最小值, 最大值)` 夹紧写回。
#   恢复频率 <= 0 表示不自动恢复。
class_name LocalVar
extends Resource

# ---- 变量名 ----
@export var name: String = ""

# ---- 可变数值组（需求指定的五个）----
@export var min_value: float = 0.0        # 最小值（下限，恢复/流失都夹到这里）
@export var max_value: float = 100.0      # 最大值（上限 = 数值条的比例分母）
@export var current_value: float = 100.0  # 现有值（分子）
@export var recover_rate: float = 0.0     # 恢复频率（秒；<=0 = 不自动恢复）
@export var recover_amount: float = 0.0   # 回复量（每次恢复的增量；可负 = 流失）

# ============ 运行时求值 ============

## 把现有值夹到 [min_value, max_value] 区间（改 min/max 后应调用一次，保证不变量）。
func clamp_current() -> void:
	current_value = clampf(current_value, min_value, max_value)


## 直接设置现有值（自动夹紧到 [min,max]）。返回是否真的改变了值。
func set_current(v: float) -> bool:
	var nv := clampf(v, min_value, max_value)
	if is_equal_approx(nv, current_value):
		return false
	current_value = nv
	return true


## 推进一次「恢复」（由将来的计时器 / 事件链调用）。
##   返回是否真的改变了值（用于决定要不要 emit_changed / 重绘）。
func tick_recover() -> bool:
	if recover_rate <= 0.0:
		return false
	return set_current(current_value + recover_amount)


## 比例（0~1）= 现有值 / 最大值；最大值 <= 0 时按 0 处理。
##   数值条就是用它来算填充比例的（与「全局变量」路径求值语义一致）。
func ratio() -> float:
	if max_value <= 0.0:
		return 0.0
	return clampf(current_value / max_value, 0.0, 1.0)


## 数值格式（整数不带小数，否则两位小数）——与 ValueBarView._fmt_num 同款显示规则。
func fmt(v: float) -> String:
	if absf(v - roundf(v)) < 0.001:
		return str(int(roundf(v)))
	return str(snapped(v, 0.01))


## 「现有/最大」的显示文本（数值条 VALUE 模式下画在条中间的字）。
func value_text() -> String:
	return "%s/%s" % [fmt(current_value), fmt(max_value)]


# ============ 预制局部变量（属性面板「快速添加预设局部变量」下拉）============
# 与 ValueBar.PRESETS 同构：预设表 + 生成逻辑放这里（纯 Resource，便于独立测试），
# 属性面板只负责「下拉选择 → 调 LocalVar.preset_dict → 建编辑器」。
#
# 字段：label 显示名；min/max 现值域；rate 恢复频率（秒）；amount 回复量。
#   弹药 = 0~30 整数、每 1 秒回 1（装填）
#   体力 = 0~100、每 5 秒回 2（喘息恢复）
#   能量 = 0~100、每 3 秒回 5（施法回魔）
#   HP   = 0~100、每 10 秒回 1（缓慢恢复）
const PRESETS: Dictionary = {
	"ammo": {
		"label": "弹药", "min": 0.0, "max": 30.0, "cur": 30.0,
		"rate": 1.0, "amount": 1.0,
	},
	"stamina": {
		"label": "体力", "min": 0.0, "max": 100.0, "cur": 100.0,
		"rate": 5.0, "amount": 2.0,
	},
	"energy": {
		"label": "能量", "min": 0.0, "max": 100.0, "cur": 100.0,
		"rate": 3.0, "amount": 5.0,
	},
	"hp": {
		"label": "HP", "min": 0.0, "max": 100.0, "cur": 100.0,
		"rate": 10.0, "amount": 1.0,
	},
}


static func preset_label(key: String) -> String:
	if PRESETS.has(key):
		return str(PRESETS[key]["label"])
	return ""


## 生成一份 LocalVar 编辑器数据（与属性面板 _make_lv_editor 的输入格式一致）。
static func preset_dict(key: String) -> Dictionary:
	if not PRESETS.has(key):
		return {}
	var p: Dictionary = PRESETS[key]
	return {
		"name": preset_label(key),
		"min_value": float(p["min"]),
		"max_value": float(p["max"]),
		"current_value": float(p["cur"]),
		"recover_rate": float(p["rate"]),
		"recover_amount": float(p["amount"]),
	}
