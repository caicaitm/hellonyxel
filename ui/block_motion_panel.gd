# ui/block_motion_panel.gd
# 「积木运动」面板 —— 在积木属性面板里按「调整运动...」打开，细化积木的受控移动参数。
#
# 字段：
#   受重力（勾选框）            开启后积木受重力（取代旧 gravity 标签）
#   可滚动（勾选框）            开启后按形状做刚体滚动/翻滚（取代旧 rollable 标签）
#   自由翻滚（勾选框）          取消「翻到面朝下」的吸附与自纠正，允许任意角度静止
#   旋转轴偏移 X/Y（像素）      旋转轴 / 质心相对几何中心的偏移（随 rotation 旋转）
#   摩擦系数 μ                  滑动减速度 = μ·g（与质量无关）；也决定能否被绊翻、坡上会不会自己滑
#   风阻（1/秒）                速度每帧 ×1/(1+drag·dt)，越重受影响越小
#   弹性 e                      撞击恢复系数（仅「可滚动」积木）：落地/翻面砸地后弹一下
#   挤压幅度                    落地形变强度（纯视觉 scale）：0 = 不形变，撞击越猛扁得越多
#   回弹刚度                    形变弹簧的快慢（rad/s）：小 = 慢慢回位，大 = 一下就弹回
#   计入转动惯量（勾选框）      翻面/起滚改用按形状实算的转动惯量（I = m·k² + 平行轴）
#   转动惯量 I（质量·像素²）    0 = 按形状与尺寸自动算；>0 = 手填（单位含质量，所以会随质量放大）
#   材质预设（不入库）          一键把 μ/风阻/弹性/挤压/刚度 填成一组常见手感
#   可飞行（勾选框）            开启后积木不受重力（悬停），可按住 W/↑ 上升、S/↓ 下降（仍需 controlled 标签）
#   水平最大速度（像素/秒）
#   水平加速度（像素/秒²）      0 = 瞬时到位（保留旧手感）
#   飞行上升最大速度（像素/秒）
#   飞行上升加速度（像素/秒²）  0 = 瞬时到位
#   质量（相对值）              只影响可滚动积木的惯性
#
# 数值框用 SpinBox：可直接输入，也可滚轮 / 上下箭头增减（“可滚动填写框”）。
#
# 数据流向（对齐 TagPickerPanel / 长文本窗的「子面板回写」模式）：
#   open(data) 读入 → 界面调整 → 按「确定」把当前值存入 _values；按「取消」/× 保持原值不变。
#   调用方（属性面板）在收到 closed 信号后 get_values() 取回 —— 取消时取回的就是初始值（= 无改动）。
#   属性面板再把这份值写进自己的 prop dict，最终随「确定」一起 apply_to_block。
#
# 样式与其它 UI 一致（天蓝半透明底 + 荧光蓝边框），顶栏复用 UIDragHandle 拖动把柄。
class_name BlockMotionPanel
extends Control

signal closed

# ---------------- 尺寸 / 常量 ----------------
const PAD := 12.0
const TITLE_H := 30.0
const ROW_H := 28.0
const PANEL_W := 440.0
const PANEL_H := 792.0
const DEFAULT_PANEL_W := 1152.0
const DEFAULT_PANEL_H := 648.0
# 小号字（说明文字）。不能用 UIStyle.FONT_SIZE - 2 当 const：static var 不是常量表达式。
const SMALL_FONT := 12

# 数值框上下限（给足余量，不限制玩家配置）
const V_MAX := 100000.0

# 默认值（与 Block / BlockProperty 保持一致）
const DEFAULTS: Dictionary = {
	"gravity_enabled": false,
	"roll_enabled": false,
	"free_roll": false,
	"roll_axis_x": 0.0,
	"roll_axis_y": 0.0,
	"friction_coef": 0.45,
	"air_drag": 0.15,
	"restitution": 0.2,
	"squash_amount": 0.25,
	"squash_stiffness": 22.0,
	"inertia_enabled": false,
	"inertia_value": 0.0,
	"can_fly": false,
	"horiz_max_speed": 240.0,
	"horiz_accel": 0.0,
	"fly_up_max_speed": 240.0,
	"fly_up_accel": 0.0,
	"mass": 1.0,
}

# 质量下限/步进：>0 才有意义（0 会让惯性缩放除零，Block 侧也按 <=0 收敛为 1）
const MASS_MIN := 0.1
const MASS_STEP := 0.1

# 转动惯量 I 的可填上限（单位 = 质量·像素²）。
# ★ 上限给得这么离谱是因为它的量纲带 px²：1000×1000 的方块 k²≈16.7 万，mass=100 时
#   自动值就上千万元 —— 面板卡在小数值会让「手填比自动值更大 = 更难翻」根本填不出来。
#   ★ 与 BlockProperty.apply_to_block 的夹紧区间必须一致（两处各写一遍会漂移）。
const INERTIA_MAX := 20000000.0

# 材质预设：一键把「μ / 风阻 / 弹性 / 挤压 / 回弹」填成一组常见手感。
# ★★ 这是**纯界面快捷键**：不在 DEFAULTS 里、不进 _collect()、不写存档 ——
#   存下来的永远是那五个独立参数，所以事后手调任何一项都不存在「预设归属被破坏」的问题。
const PRESET_KEYS: Array = ["friction_coef", "air_drag", "restitution", "squash_amount", "squash_stiffness"]
const PRESETS: Array = [
	{ "name": "自定义", "v": {} },
	{ "name": "橡胶（皮球）", "v": {"friction_coef": 0.9, "air_drag": 0.1, "restitution": 0.65, "squash_amount": 0.4, "squash_stiffness": 16.0} },
	{ "name": "木头（纸箱）", "v": {"friction_coef": 0.45, "air_drag": 0.15, "restitution": 0.2, "squash_amount": 0.15, "squash_stiffness": 26.0} },
	{ "name": "冰面", "v": {"friction_coef": 0.05, "air_drag": 0.05, "restitution": 0.02, "squash_amount": 0.0, "squash_stiffness": 22.0} },
	{ "name": "钢铁", "v": {"friction_coef": 0.3, "air_drag": 0.08, "restitution": 0.35, "squash_amount": 0.05, "squash_stiffness": 40.0} },
	{ "name": "石头", "v": {"friction_coef": 0.7, "air_drag": 0.12, "restitution": 0.05, "squash_amount": 0.02, "squash_stiffness": 45.0} },
]

# ---------------- 内部引用 ----------------
var _panel: UIPanel
var _title: Label
var _gravity_check: CheckBox
var _roll_check: CheckBox
var _free_check: CheckBox
var _axis_x: SpinBox
var _axis_y: SpinBox
var _friction: SpinBox
var _air_drag: SpinBox
var _restitution: SpinBox
var _squash_amount: SpinBox
var _squash_stiffness: SpinBox
var _inertia_check: CheckBox
var _inertia_value: SpinBox
var _inertia_hint: Label
var _preset: OptionButton
var _fly_check: CheckBox
var _horiz_speed: SpinBox
var _horiz_accel: SpinBox
var _fly_speed: SpinBox
var _fly_accel: SpinBox
var _mass: SpinBox

# ---------------- 状态 ----------------
var _values: Dictionary = {}     # 权威数据：open 时读入，确定时覆盖
var _open: bool = false
var _ever_centered: bool = false
# ★ 只读几何上下文（width/height/shape/shape_dir）：调用方 open() 第二个参数带进来，
#   只为算「自动惯量参考值」给玩家看量级 —— 不进 DEFAULTS、不进 _collect、不入存档。
var _geom: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	visible = false


# ==================== 构建 ====================

func _build_ui() -> void:
	# 背景：与其它 UI 一致的浅天蓝半透明 + 荧光蓝边框
	_panel = UIPanel.new()
	_panel.name = "UIPanel"
	_panel.set_corner_radius(UIStyle.CORNER_RADIUS)
	_panel.set_fill_color(UIStyle.FILL_DEFAULT)
	_panel.set_border_color(UIStyle.BORDER)
	_panel.set_border_width(UIStyle.BORDER_WIDTH)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	# ★ 先入树、再设锚点：在树外设「不对等锚点」会被 Godot 警告。
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)

	# 整体可滚动：内容长于面板时（小屏 / 大字号）也能看到全部字段
	var sc := ScrollContainer.new()
	sc.name = "Body"
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(sc)
	sc.set_anchors_preset(Control.PRESET_FULL_RECT)
	sc.offset_left = PAD
	sc.offset_top = PAD
	sc.offset_right = -PAD
	sc.offset_bottom = -PAD

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 6)
	sc.add_child(vbox)

	vbox.add_child(_build_title_row())
	vbox.add_child(_hint("重力 / 可滚动**已从标签系统移到本面板**：旧存档的 gravity / rollable 标签在首次加载时迁移一次，随后从积木身上剥离。"))
	vbox.add_child(_build_check_row("受重力", "开启（受重力下落；可配合 controlled 键盘移动）", "gravity"))
	vbox.add_child(_build_check_row("可滚动", "开启（按形状做刚体滚动 / 翻滚）", "roll"))
	vbox.add_child(_build_check_row("自由翻滚", "开启（不做「翻到面朝下」的吸附，可任意角度静止）", "free"))
	var r_ax := _spin_row("旋转轴偏移 X", "(像素)", -V_MAX, 1.0)
	_axis_x = r_ax["spin"]
	vbox.add_child(r_ax["row"])
	var r_ay := _spin_row("旋转轴偏移 Y", "(像素)", -V_MAX, 1.0)
	_axis_y = r_ay["spin"]
	vbox.add_child(r_ay["row"])
	vbox.add_child(_hint("旋转轴 = 质心：偏移会让力矩、稳定姿态、自转中心一起改变。\n(0,0) = 几何中心；X 向右为正，Y 向下为正。"))
	var r_fr := _spin_row("摩擦系数 μ", "(0≈冰面 1≈橡胶)", 0.0, 0.05)
	_friction = r_fr["spin"]
	_friction.max_value = 2.0
	_friction.custom_arrow_step = 0.05
	vbox.add_child(r_fr["row"])
	var r_ad := _spin_row("风阻", "(1/秒)", 0.0, 0.05)
	_air_drag = r_ad["spin"]
	_air_drag.custom_arrow_step = 0.05
	vbox.add_child(r_ad["row"])
	var r_rs := _spin_row("弹性 e", "(0=不弹 0.6=皮球)", 0.0, 0.05)
	_restitution = r_rs["spin"]
	_restitution.max_value = 0.9
	_restitution.custom_arrow_step = 0.05
	vbox.add_child(r_rs["row"])
	var r_sq := _spin_row("挤压幅度", "(0=不形变)", 0.0, 0.05)
	_squash_amount = r_sq["spin"]
	_squash_amount.max_value = 0.6
	_squash_amount.custom_arrow_step = 0.05
	vbox.add_child(r_sq["row"])
	var r_sk := _spin_row("回弹速度", "(小=软 大=硬)", 2.0, 1.0)
	_squash_stiffness = r_sk["spin"]
	_squash_stiffness.max_value = 60.0
	_squash_stiffness.custom_arrow_step = 1.0
	vbox.add_child(r_sk["row"])
	# ---- 转动惯量（批次 541）----
	vbox.add_child(_build_check_row("计入转动惯量", "开启（翻面 / 起滚按形状实算惯量）", "inertia"))
	var r_iv := _spin_row("转动惯量 I", "(0=按形状自动)", 0.0, 1.0)
	_inertia_value = r_iv["spin"]
	_inertia_value.max_value = INERTIA_MAX
	_inertia_value.custom_arrow_step = 100.0
	vbox.add_child(r_iv["row"])
	_inertia_hint = _hint("")
	vbox.add_child(_inertia_hint)
	vbox.add_child(_build_preset_row())
	vbox.add_child(_hint("摩擦与弹性是「看着像活的」的关键（参考 Flash 物理小游戏的做法）：\n· μ 决定滑停距离与**能不能绊翻** —— μ 太小（冰面）只会滑出去不翻面；μ 还吃得住坡度（浅坡上放着不滑）。\n· 风阻让空中与滚动的速度逐渐衰减（越重受影响越小），杜绝「永远在原地磨」。\n· 弹性只在撞击速度够大时弹一下（翻面砸地 → 弹起 → 再砸实）；调 0 = 落地立刻躺平。\n· 挤压幅度 = 落地那一下砸扁多少（纯视觉缩放，碰撞盒与质心都不变）；回弹速度 = 弹簧软硬。\n· 撞击那一帧摩擦力按「法向冲量」放大（μ×N，不只是 μ·m·g）→ 落地当帧就咬地起滚 / 接力翻面，\n  不再「先落到底、顿一下才滚」。\n· 材质预设只是把上面五项一次填好的快捷键，**它本身不保存**；填完仍可逐项手调。\n★ μ 的减速度与质量无关（库仑摩擦），质量只通过驱动力与风阻起作用。"))
	vbox.add_child(_build_fly_row())
	var r_hs := _spin_row("水平最大速度", "(像素/秒)")
	_horiz_speed = r_hs["spin"]
	vbox.add_child(r_hs["row"])
	var r_ha := _spin_row("水平加速度", "(像素/秒²)")
	_horiz_accel = r_ha["spin"]
	vbox.add_child(r_ha["row"])
	var r_fs := _spin_row("飞行上升最大速度", "(像素/秒)")
	_fly_speed = r_fs["spin"]
	vbox.add_child(r_fs["row"])
	var r_fa := _spin_row("飞行上升加速度", "(像素/秒²)")
	_fly_accel = r_fa["spin"]
	vbox.add_child(r_fa["row"])
	vbox.add_child(_hint("飞行下降复用「飞行上升」的速度与加速度。"))
	var r_m := _spin_row("质量", "(相对, 1=标准)", MASS_MIN, MASS_STEP)
	_mass = r_m["spin"]
	vbox.add_child(r_m["row"])
	vbox.add_child(_hint("质量只影响「可滚动」积木的惯性：越重 → 起步更慢、风阻影响更小、动量更足。\n★ 滑停距离与质量无关（库仑摩擦 μ·g），现实里轻重一样的箱子滑得一样远。"))
	vbox.add_child(_build_footer())

	# ★ 惯量参考值的联动要等 _mass / _axis_* 都建好之后再接（否则此处引用为 null）。
	_inertia_check.toggled.connect(_on_inertia_ui_changed)
	for src in [_inertia_value, _mass, _axis_x, _axis_y]:
		(src as SpinBox).value_changed.connect(_on_inertia_ui_changed)

	# ★ 不要再给 _panel 手动 size：它挂的是 FULL_RECT 锚点，尺寸自动跟随本 Control。
	size = Vector2(PANEL_W, PANEL_H)



# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏控件整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build_title_row() -> HBoxContainer:
	var top := HBoxContainer.new()
	top.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.custom_minimum_size = Vector2(0.0, TITLE_H)

	_title = Label.new()
	_title.text = "积木运动"
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_apply_font(_title, 2)
	top.add_child(_title)

	# 拖动把柄（复用 UIDragHandle：按住移动整个面板）
	var handle := UIDragHandle.new()
	handle.setup(self)
	handle.tooltip_text = "拖动以移动面板"
	top.add_child(handle)

	# 右上 × 关闭（= 取消）
	var x_btn := UIBtn.new()
	x_btn.set_id("close")
	x_btn.set_label("×")
	x_btn.custom_minimum_size = Vector2(TITLE_H, TITLE_H)
	x_btn.pressed_id.connect(_on_footer_pressed)
	top.add_child(x_btn)
	# ★ 本页顶栏是 HBox（标题 | 移动把柄 | × 关闭）→ 最小化插到 × **之前**，
	#   排布即「移动 | 最小化 | 关闭」。误用 attach_anchored 会按绝对偏移摆位。
	_min_btn = UIMinimize.attach_before(top, x_btn, func(): set_minimized(not _minimized))
	return top


func _build_fly_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)
	row.add_child(_label("可飞行", 150.0))
	_fly_check = CheckBox.new()
	_fly_check.text = "开启（不受重力，可上升/下降）"
	_fly_check.mouse_filter = Control.MOUSE_FILTER_STOP
	_apply_font(_fly_check, 0)
	row.add_child(_fly_check)
	return row


# 材质预设行（只改界面上那五个框的值，本身不入存档）
func _build_preset_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)
	row.add_child(_label("材质预设", 150.0))
	_preset = OptionButton.new()
	_preset.name = "材质预设"
	_preset.custom_minimum_size = Vector2(150.0, ROW_H)
	_preset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset.mouse_filter = Control.MOUSE_FILTER_STOP
	for i in range(PRESETS.size()):
		_preset.add_item(str(PRESETS[i]["name"]), i)
	_apply_font(_preset, 0)
	_preset.item_selected.connect(_on_preset_selected)
	row.add_child(_preset)
	return row


func _on_preset_selected(index: int) -> void:
	var v: Dictionary = PRESETS[clampi(index, 0, PRESETS.size() - 1)]["v"]
	if v.is_empty():
		return
	for k in PRESET_KEYS:
		if not v.has(k):
			continue
		match k:
			"friction_coef":
				_friction.value = float(v[k])
			"air_drag":
				_air_drag.value = float(v[k])
			"restitution":
				_restitution.value = float(v[k])
			"squash_amount":
				_squash_amount.value = float(v[k])
			"squash_stiffness":
				_squash_stiffness.value = float(v[k])


# ---- 转动惯量（批次 541）----
# 任何影响自动参考值的输入（开关 / I / 质量 / 轴偏移）都刷新同一行说明。
func _on_inertia_ui_changed(_v) -> void:
	_refresh_inertia_hint()


# ★★ 这行说明的唯一作用：让玩家知道「转动惯量 I」的量纲（质量·像素²）该填到多大。
#   数字来自 Block 的同一套 static 公式（k2_axis_auto）→ 与模拟实际用的值一致，
#   只是这里用界面当前输入（轴偏移、质量）现算，不读积木本体。
func _refresh_inertia_hint() -> void:
	if _inertia_hint == null or not is_instance_valid(_inertia_hint):
		return
	var base: String = "· 关闭 = 质点近似（力矩分母取 |质心−支点|²，538 的老手感）；开启 = 形状绕质心的 k² + 平行轴。\n"
	base += "· 开启后：同尺寸的件翻得更慢（矩形约慢 25%）、**越大越懒**；矮胖子更难绊翻、高瘦件照样一碰就翻。\n"
	if not bool(_inertia_check.button_pressed):
		_inertia_hint.text = base + "· 现在关闭 → 「转动惯量 I」填多少都不参与计算（留着备用即可）。"
		return
	var m: float = maxf(MASS_MIN, float(_mass.value))
	var iv: float = float(_inertia_value.value)
	if not _geom.has("width"):
		# 调用方没给几何（例如物品/类型编辑）→ 只能给量级公式，不给具体数
		_inertia_hint.text = base + "· I = 质量 × k²；k²(矩形)=(w²+h²)/12、圆盘=r²/2、三角形=Σ边²/36（单位：像素²）。\n· 填 0 = 按积木自己的形状自动算。"
		return
	var k2: float = Block.k2_axis_auto(int(_geom.get("shape", 0)), float(_geom["width"]),
		float(_geom.get("height", _geom["width"])), int(_geom.get("shape_dir", 0)),
		Vector2(float(_axis_x.value), float(_axis_y.value)))
	var auto_i: float = k2 * m
	var txt: String = base
	txt += "· 当前这块（%s × %s px、质量 %s、轴偏移 %s,%s）的自动值：k²≈%s px²（回转半径 ≈%s px）→ I≈%s\n" % [
		_fmt_brief(float(_geom["width"])), _fmt_brief(float(_geom.get("height", _geom["width"]))),
		_fmt_brief(m), _fmt_brief(float(_axis_x.value)), _fmt_brief(float(_axis_y.value)),
		_fmt_brief(k2), "%.1f" % sqrt(maxf(0.0, k2)), _fmt_brief(auto_i)]
	if iv <= 0.0:
		txt += "· I 填 0 → 就用上面这个自动值。"
	else:
		txt += "· I 现在手填 %s = 自动值的 %s 倍 → %s。" % [
			_fmt_brief(iv), "%.2f" % (iv / maxf(0.0001, auto_i)),
			"更难翻 / 更懒" if iv > auto_i else "更轻易翻 / 更灵活"]
	txt += "\n· 想「同样大小但更不容易翻」→ 填自动值的 2~4 倍；材质预设不动这一项。"
	_inertia_hint.text = txt


# 勾选行：label + CheckBox。key 决定把控件存到哪个字段（gravity / roll / free）。
func _build_check_row(label_text: String, check_text: String, key: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)
	row.add_child(_label(label_text, 150.0))
	var ck := CheckBox.new()
	ck.text = check_text
	ck.mouse_filter = Control.MOUSE_FILTER_STOP
	_apply_font(ck, 0)
	row.add_child(ck)
	match key:
		"gravity":
			_gravity_check = ck
		"roll":
			_roll_check = ck
		"free":
			_free_check = ck
		"inertia":
			_inertia_check = ck
	return row


# 数值行：标签 + SpinBox（可滚动填写框）。返回 { "row": HBoxContainer, "spin": SpinBox }
func _spin_row(label_text: String, unit_text: String, min_v: float = 0.0, step_v: float = 1.0) -> Dictionary:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)
	row.add_child(_label(label_text, 150.0))

	var spin := SpinBox.new()
	spin.name = label_text
	spin.min_value = min_v
	spin.max_value = V_MAX
	spin.step = step_v
	spin.custom_arrow_step = step_v * 10.0   # 上下箭头一大步（step=1 → 10，step=0.1 → 1.0）
	spin.allow_greater = false
	spin.allow_lesser = false
	spin.suffix = " " + unit_text
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.custom_minimum_size = Vector2(150.0, ROW_H)
	spin.mouse_filter = Control.MOUSE_FILTER_STOP
	# SpinBox 内部是一个 LineEdit —— 套用本项目 LineEdit 统一样式
	var le := spin.get_line_edit()
	if le != null:
		le.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
		if is_instance_valid(UIStyle.get_cjk_font()):
			le.add_theme_font_override("font", UIStyle.get_cjk_font())
		UIStyle.apply_line_edit_style(le)
	row.add_child(spin)

	return { "row": row, "spin": spin }


func _build_footer() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 10)

	var ok_btn := UIBtn.new()
	ok_btn.set_id("ok")
	ok_btn.set_label("确定")
	ok_btn.custom_minimum_size = Vector2(80.0, 30.0)
	ok_btn.pressed_id.connect(_on_footer_pressed)
	row.add_child(ok_btn)

	var cancel_btn := UIBtn.new()
	cancel_btn.set_id("cancel")
	cancel_btn.set_label("取消")
	cancel_btn.custom_minimum_size = Vector2(80.0, 30.0)
	cancel_btn.pressed_id.connect(_on_footer_pressed)
	row.add_child(cancel_btn)
	return row


# ---------------- 复用的行零件 ----------------

func _label(text: String, min_w: float) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.clip_text = true
	if min_w > 0.0:
		l.custom_minimum_size = Vector2(min_w, ROW_H)
	_apply_font(l, 0)
	return l


func _hint(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_color_override("font_color", Color(0.82, 0.88, 0.94, 0.85))
	l.add_theme_font_size_override("font_size", SMALL_FONT)
	if is_instance_valid(UIStyle.get_cjk_font()):
		l.add_theme_font_override("font", UIStyle.get_cjk_font())
	return l


# 短数值显示（整数不带小数点）—— 与属性面板的摘要同一口味。
func _fmt_brief(v) -> String:
	var f := float(v)
	return str(int(f)) if f == floor(f) else str(f)


func _apply_font(c: Control, size_bonus: int) -> void:
	c.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	c.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + size_bonus)
	if is_instance_valid(UIStyle.get_cjk_font()):
		c.add_theme_font_override("font", UIStyle.get_cjk_font())


# ==================== 打开 / 关闭 ====================

# 打开：以 data 为初始值（缺键用默认）。同步完成，不 await。
# ★ geom = 只读几何上下文（width/height/shape/shape_dir），仅用于「自动惯量参考值」那行说明；
#   不参与 _values / _collect，所以不会被写回属性或存档。
func open(data: Dictionary, geom: Dictionary = {}) -> void:
	_values = _normalize(data)
	_geom = geom
	_gravity_check.button_pressed = bool(_values["gravity_enabled"])
	_roll_check.button_pressed = bool(_values["roll_enabled"])
	_free_check.button_pressed = bool(_values["free_roll"])
	_axis_x.value = float(_values["roll_axis_x"])
	_axis_y.value = float(_values["roll_axis_y"])
	_friction.value = float(_values["friction_coef"])
	_air_drag.value = float(_values["air_drag"])
	_restitution.value = float(_values["restitution"])
	_squash_amount.value = float(_values["squash_amount"])
	_squash_stiffness.value = float(_values["squash_stiffness"])
	_inertia_check.button_pressed = bool(_values["inertia_enabled"])
	_inertia_value.value = float(_values["inertia_value"])
	_refresh_inertia_hint()
	# 预设是一次性快捷键：每次打开都回到「自定义」（赋值 selected 不会触发 item_selected）
	_preset.selected = 0
	_fly_check.button_pressed = bool(_values["can_fly"])
	_horiz_speed.value = float(_values["horiz_max_speed"])
	_horiz_accel.value = float(_values["horiz_accel"])
	_fly_speed.value = float(_values["fly_up_max_speed"])
	_fly_accel.value = float(_values["fly_up_accel"])
	_mass.value = float(_values["mass"])
	if not _ever_centered:
		_center()
		_ever_centered = true
	visible = true
	move_to_front()
	_open = true
	print("[BlockMotion] 打开 can_fly=%s 水平%s/%s 上升%s/%s" % [
		str(_values["can_fly"]), str(_values["horiz_max_speed"]), str(_values["horiz_accel"]),
		str(_values["fly_up_max_speed"]), str(_values["fly_up_accel"])])


# 当前值（确定后=界面值；取消后= open 时传入的初始值）
func get_values() -> Dictionary:
	return _values.duplicate()


func close() -> void:
	_open = false
	visible = false
	# 可能已被移除出场景树（父面板先关）→ get_viewport() 会返回 null，先判断再释放焦点。
	if is_inside_tree() and get_viewport() != null:
		get_viewport().gui_release_focus()
	closed.emit()
	queue_free()


func is_open() -> bool:
	return _open


func _on_footer_pressed(id: String) -> void:
	match id:
		"ok":
			_values = _collect()
			print("[BlockMotion] 确定 can_fly=%s 水平%s/%s 上升%s/%s" % [
				str(_values["can_fly"]), str(_values["horiz_max_speed"]), str(_values["horiz_accel"]),
				str(_values["fly_up_max_speed"]), str(_values["fly_up_accel"])])
			close()
		"cancel", "close":
			close()


func _collect() -> Dictionary:
	return {
		"gravity_enabled": _gravity_check.button_pressed,
		"roll_enabled": _roll_check.button_pressed,
		"free_roll": _free_check.button_pressed,
		"roll_axis_x": float(_axis_x.value),
		"roll_axis_y": float(_axis_y.value),
		"friction_coef": float(_friction.value),
		"air_drag": float(_air_drag.value),
		"restitution": float(_restitution.value),
		"squash_amount": float(_squash_amount.value),
		"squash_stiffness": float(_squash_stiffness.value),
		"inertia_enabled": _inertia_check.button_pressed,
		"inertia_value": clampf(float(_inertia_value.value), 0.0, INERTIA_MAX),
		"can_fly": _fly_check.button_pressed,
		"horiz_max_speed": float(_horiz_speed.value),
		"horiz_accel": float(_horiz_accel.value),
		"fly_up_max_speed": float(_fly_speed.value),
		"fly_up_accel": float(_fly_accel.value),
		"mass": maxf(MASS_MIN, float(_mass.value)),
	}


# 补全 / 收敛输入：缺键用默认，负数收敛到 0（面板下限即为 0）；质量收敛到 [MASS_MIN, V_MAX]
# 轴偏移允许正负（左/上为负），只按 V_MAX 限幅。
func _normalize(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	out["gravity_enabled"] = bool(d.get("gravity_enabled", DEFAULTS["gravity_enabled"]))
	out["roll_enabled"] = bool(d.get("roll_enabled", DEFAULTS["roll_enabled"]))
	out["free_roll"] = bool(d.get("free_roll", DEFAULTS["free_roll"]))
	out["roll_axis_x"] = clampf(float(d.get("roll_axis_x", DEFAULTS["roll_axis_x"])), -V_MAX, V_MAX)
	out["roll_axis_y"] = clampf(float(d.get("roll_axis_y", DEFAULTS["roll_axis_y"])), -V_MAX, V_MAX)
	out["friction_coef"] = clampf(float(d.get("friction_coef", DEFAULTS["friction_coef"])), 0.0, 2.0)
	out["air_drag"] = clampf(float(d.get("air_drag", DEFAULTS["air_drag"])), 0.0, V_MAX)
	out["restitution"] = clampf(float(d.get("restitution", DEFAULTS["restitution"])), 0.0, 0.9)
	out["squash_amount"] = clampf(float(d.get("squash_amount", DEFAULTS["squash_amount"])), 0.0, 0.6)
	out["squash_stiffness"] = clampf(float(d.get("squash_stiffness", DEFAULTS["squash_stiffness"])), 2.0, 60.0)
	out["inertia_enabled"] = bool(d.get("inertia_enabled", DEFAULTS["inertia_enabled"]))
	out["inertia_value"] = clampf(float(d.get("inertia_value", DEFAULTS["inertia_value"])), 0.0, INERTIA_MAX)
	out["can_fly"] = bool(d.get("can_fly", DEFAULTS["can_fly"]))
	for k in ["horiz_max_speed", "horiz_accel", "fly_up_max_speed", "fly_up_accel"]:
		out[k] = maxf(0.0, float(d.get(k, DEFAULTS[k])))
	out["mass"] = clampf(float(d.get("mass", DEFAULTS["mass"])), MASS_MIN, V_MAX)
	return out


func _center() -> void:
	var vp := Vector2(DEFAULT_PANEL_W, DEFAULT_PANEL_H)
	if is_inside_tree() and get_viewport() != null:
		vp = UIStyle.canvas_viewport_size(self)
	# 略向右下错开，避免与下方的属性面板完全重叠
	var p := (vp - size) * 0.5 + Vector2(60.0, -20.0)
	p.x = clampf(p.x, 4.0, maxf(4.0, vp.x - size.x - 4.0))
	p.y = clampf(p.y, 4.0, maxf(4.0, vp.y - size.y - 4.0))
	position = p.floor()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()


## 最小化 / 还原：折叠只隐藏内容，标题栏控件（标题 / 把柄 / 最小化 / 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.apply(self, _min_btn, v, _min_btn.get_parent() if is_instance_valid(_min_btn) else null)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
