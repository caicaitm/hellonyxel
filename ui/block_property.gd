# block_property.gd
# 积木属性统一数据结构（伴随“积木属性”面板与“另存为新类型”复用）
# 适配新版 Block 模型：
#   - collision_layer 为 PackedStringArray（集合：含相同元素的两个积木才对撞）
#   - 填充用 BlockFill（path + fill_mode + anim_type）
#   - 文本框为 Array[TextBox]（富文本 text_def）
#   - 标签用 PackedStringArray，标准标签见 BlockTags
class_name BlockProperty
extends RefCounted

const DEFAULT_TAGS: PackedStringArray = ["show", "border", "fill", "text", "collision", "selectable"]


# 从 Block 实例提取 prop dict
static func from_block(b) -> Dictionary:
	if b == null:
		return default_for_new()
	var fp: String = ""
	var fm: int = 0
	var fa: int = 0
	var tsplit_x: int = 1
	var tsplit_y: int = 1
	var tsize_mode: int = 0
	var tsize_x: float = 32.0
	var tsize_y: float = 32.0
	var torder: int = 0
	if b.fill != null:
		fp = b.fill.path
		fm = int(b.fill.fill_mode)
		fa = int(b.fill.anim_type)
		tsplit_x = int(b.fill.tile_split.x)
		tsplit_y = int(b.fill.tile_split.y)
		tsize_mode = int(b.fill.tile_size_mode)
		tsize_x = float(b.fill.tile_size.x)
		tsize_y = float(b.fill.tile_size.y)
		torder = int(b.fill.tile_fill_order)
	var tbs: Array = []
	for tb in b.text_boxes:
		tbs.append(text_box_to_dict(tb))
	var abs: Array = []
	for ab in b.attack_boxes:
		abs.append(attack_box_to_dict(ab))
	var vbs: Array = []
	for vb in b.value_bars:
		vbs.append(value_bar_to_dict(vb))
	var lvs: Array = []
	for lv in b.local_vars:
		lvs.append(local_var_to_dict(lv))
	return {
		# ★ 宽度：内存里恒为「解析后的数值」（常量名在 apply_to_block 时已由 SystemConst 解析）
		"width": float(b.width),
		"height": float(b.height),
		"shape": int(b.shape),
		"shape_dir": int(b.shape_dir),
		"display_layer": float(b.display_layer),
		"collision_layer": PackedStringArray(b.collision_layer),
		"border_color": color_to_hex(b.border_color),
		"border_width": float(b.border_width),
		"fill_color": color_to_hex(b.fill_color),
		"tags": PackedStringArray(b.tags),
		"behaviors": PackedStringArray(b.behaviors),
		"fill_path": fp,
		"fill_mode": fm,
		"fill_anim": fa,
		"tile_split_x": tsplit_x,
		"tile_split_y": tsplit_y,
		"tile_size_mode": tsize_mode,
		"tile_size_x": tsize_x,
		"tile_size_y": tsize_y,
		"tile_fill_order": torder,
		"rotation_deg": rad_to_deg(b.rotation),
		"text_boxes": tbs,
		"facing": b.facing,
		"base_attack": b.base_attack,
		"string_id": b.string_id,
		"attack_boxes": abs,
		"value_bars": vbs,
		"local_vars": lvs,
		# 运动参数（「积木运动」面板，见 ui/block_motion_panel.gd）
		"can_fly": bool(b.can_fly),
		"horiz_max_speed": float(b.horiz_max_speed),
		"horiz_accel": float(b.horiz_accel),
		"fly_up_max_speed": float(b.fly_up_max_speed),
		"fly_up_accel": float(b.fly_up_accel),
		"mass": float(b.mass),
		# 重力 / 滚动开关（已从 gravity / rollable 标签迁来；轴偏移 = 质心偏移）
		"gravity_enabled": bool(b.gravity_enabled),
		"roll_enabled": bool(b.roll_enabled),
		"free_roll": bool(b.free_roll),
		"roll_axis_x": float(b.roll_axis_offset.x),
		"roll_axis_y": float(b.roll_axis_offset.y),
		# 摩擦 / 风阻 / 弹性（批次 537）
		"friction_coef": float(b.friction_coef),
		"air_drag": float(b.air_drag),
		"restitution": float(b.restitution),
		"squash_amount": float(b.squash_amount),
		"squash_stiffness": float(b.squash_stiffness),
		# 转动惯量（批次 541）
		"inertia_enabled": bool(b.inertia_enabled),
		"inertia_value": float(b.inertia_value),
		# 父子级锚定（ID 绑定，参考废弃版父子级系统）
		"parent_id": int(b.get_parent_id()) if b.has_method("get_parent_id") else 0,
		"child_ids": Array(b.get_child_ids()) if b.has_method("get_child_ids") else [],
	}


# 新建带属性的默认 prop（右键空白处 / 新建类型用）
# ★ 默认尺寸改为非方形（160×100），避免“右键新建积木”出来一水的 120×120 正方形；
#   用户仍可在属性面板把宽高改成任意值。
static func default_for_new() -> Dictionary:
	return {
		"width": 160.0,
		"height": 100.0,
		"shape": 0,
		"shape_dir": 0,
		"display_layer": 0,
		"collision_layer": PackedStringArray(["default"]),
		"border_color": "#FFFFFFFF",
		"border_width": 3.0,
		"fill_color": "#4090F0FF",
		"tags": PackedStringArray(DEFAULT_TAGS),
		"behaviors": PackedStringArray(),
		"fill_path": "",
		"fill_mode": 0,
		"fill_anim": 0,
		"tile_split_x": 1,
		"tile_split_y": 1,
		"tile_size_mode": 0,
		"tile_size_x": 32.0,
		"tile_size_y": 32.0,
		"tile_fill_order": 0,
		"rotation_deg": 0.0,
		"text_boxes": [],
		"facing": 1,
		"base_attack": 1.0,
		"value_bars": [],
		"local_vars": [],
		"attack_boxes": [],
		# 运动参数（默认值与 Block 一致：不可飞行 / 速度 240 / 加速度 0=瞬时）
		"can_fly": false,
		"horiz_max_speed": 240.0,
		"horiz_accel": 0.0,
		"fly_up_max_speed": 240.0,
		"fly_up_accel": 0.0,
		"mass": 1.0,
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
		"parent_id": 0,
		"child_ids": [],
	}


# 把 prop dict 应用到 Block
static func apply_to_block(b, d: Dictionary) -> void:
	if b == null:
		return
	if d.has("width"):
		# ★ 宽 / 高可以是数值，也可以是**已注册的系统常量名**（如 "icon_size"）：
		#   常量名在运行时按当前设备解析（SystemConst 现读 sysinfo.json），
		#   于是同一份类型定义在不同设备上得到不同（但都合适）的实际尺寸。
		b.width = SystemConst.resolve(d["width"])
	if d.has("height"):
		b.height = SystemConst.resolve(d["height"])
	if d.has("shape"):
		b.shape = int(d["shape"])
	if d.has("shape_dir"):
		b.shape_dir = int(d["shape_dir"])
	if d.has("display_layer"):
		b.display_layer = float(d["display_layer"])
	if d.has("collision_layer"):
		b.collision_layer = PackedStringArray(Array(d["collision_layer"]))
	if d.has("border_color"):
		var bc: String = d["border_color"]
		if bc != "":
			b.border_color = hex_to_color(bc)
	if d.has("border_width"):
		b.border_width = float(d["border_width"])
	if d.has("fill_color"):
		var fc: String = d["fill_color"]
		if fc != "":
			b.fill_color = hex_to_color(fc)
	if d.has("tags"):
		b.tags = PackedStringArray(Array(d["tags"]))
	if d.has("behaviors"):
		b.behaviors = PackedStringArray(Array(d["behaviors"]))
	# 填充来源（图片/动图/骨骼）
	if d.has("fill_path"):
		var fp: String = d["fill_path"]
		if fp != "":
			if b.fill == null:
				b.fill = BlockFill.new()
			b.fill.path = fp
			b.fill.fill_mode = int(d.get("fill_mode", 0))
			b.fill.anim_type = int(d.get("fill_anim", 0))
			# 瓦片系统参数（标量键，规避 Vector2i/Vector2 经 dict 序列化问题）
			b.fill.tile_split = Vector2i(int(d.get("tile_split_x", 1)), int(d.get("tile_split_y", 1)))
			b.fill.tile_size_mode = int(d.get("tile_size_mode", 0))
			b.fill.tile_size = Vector2(float(d.get("tile_size_x", 32.0)), float(d.get("tile_size_y", 32.0)))
			b.fill.tile_fill_order = int(d.get("tile_fill_order", 0))
			if not (BlockTags.FILL_IMAGE in b.tags):
				b.tags.append(BlockTags.FILL_IMAGE)
		else:
			b.fill = null
			var idx: int = b.tags.find(BlockTags.FILL_IMAGE)
			if idx >= 0:
				b.tags.remove_at(idx)
	if d.has("rotation_deg"):
		b.rotation = deg_to_rad(float(d["rotation_deg"]))
	# 朝向（左/右）：值收敛为 -1 / 1，触发重绘
	if d.has("facing"):
		b.set_facing(int(d["facing"]))
	# 基础攻击力（预留变量，默认 1；攻击力函数以 base_attack 引用）
	if d.has("base_attack"):
		b.base_attack = float(d["base_attack"])
	# 父子级锚定（按 ID）。
	# 只在积木已入树（= 真实实例）时应用：类型模板的创建阶段块还没入树、
	# 也还没有自己的 ID，此时绑定无意义。
	if b.is_inside_tree():
		if d.has("parent_id") and b.has_method("set_parent_id"):
			b.set_parent_id(int(d["parent_id"]))
		if d.has("child_ids") and b.has_method("set_child_ids"):
			b.set_child_ids(Array(d["child_ids"]))
		# 积木ID（仅单块编辑、且积木已入树时重指定；引用重映射在 BlockManager 内完成）
		if d.has("id"):
			BlockManager.reassign_id(b, int(d["id"]))
		# 字符串ID（仅单块编辑、且积木已入树时设置/清空；唯一性由 BlockManager 保证）
		if d.has("string_id"):
			var sid := str(d["string_id"]).strip_edges()
			if sid.is_empty():
				BlockManager.clear_string_id(b)
			else:
				BlockManager.set_string_id(b, sid)
	# 文本框（Array[TextBox]）
	if d.has("text_boxes"):
		var new_tbs: Array[TextBox] = []
		for tbd in d["text_boxes"]:
			new_tbs.append(text_box_from_dict(tbd))
		b.text_boxes = new_tbs
	# 攻击判定框（Array[AttackBox]）
	if d.has("attack_boxes"):
		var new_abs: Array[AttackBox] = []
		for abd in d["attack_boxes"]:
			new_abs.append(attack_box_from_dict(abd))
		b.attack_boxes = new_abs
	# 数值条（Array[ValueBar]）
	if d.has("value_bars"):
		var new_vbs: Array[ValueBar] = []
		for vbd in d["value_bars"]:
			new_vbs.append(value_bar_from_dict(vbd))
		b.value_bars = new_vbs
	# 局部变量（Array[LocalVar]）—— 缺键则保留积木自身默认（存量 JSON 不受影响）
	if d.has("local_vars"):
		var new_lvs: Array[LocalVar] = []
		for lvd in d["local_vars"]:
			new_lvs.append(local_var_from_dict(lvd))
		b.local_vars = new_lvs
	# 运动参数（「积木运动」面板）—— 缺键则保留积木自身默认值（存量 JSON 不受影响）
	if d.has("can_fly"):
		b.can_fly = bool(d["can_fly"])
	if d.has("horiz_max_speed"):
		b.horiz_max_speed = float(d["horiz_max_speed"])
	if d.has("horiz_accel"):
		b.horiz_accel = float(d["horiz_accel"])
	if d.has("fly_up_max_speed"):
		b.fly_up_max_speed = float(d["fly_up_max_speed"])
	if d.has("fly_up_accel"):
		b.fly_up_accel = float(d["fly_up_accel"])
	if d.has("mass"):
		b.mass = maxf(0.01, float(d["mass"]))
	# 摩擦 / 风阻 / 弹性（批次 537，与「积木运动」面板同一套字段）：夹紧到面板允许的区间，
	# 免得手改 JSON / 命令回放塞进 μ=80 或 e=5 这类把物理打崩的值。
	if d.has("friction_coef"):
		b.friction_coef = clampf(float(d["friction_coef"]), 0.0, 2.0)
	if d.has("air_drag"):
		b.air_drag = maxf(0.0, float(d["air_drag"]))
	if d.has("restitution"):
		b.restitution = clampf(float(d["restitution"]), 0.0, 0.9)
	if d.has("squash_amount"):
		b.squash_amount = clampf(float(d["squash_amount"]), 0.0, 0.6)
	if d.has("squash_stiffness"):
		b.squash_stiffness = clampf(float(d["squash_stiffness"]), 2.0, 60.0)
	# 转动惯量（批次 541）：I 的单位是「质量·像素²」，绕自转轴。
	# ★ 上限必须与「积木运动」面板的 INERTIA_MAX 一致（量纲带 px²，大件自动值本就上千万）；
	#   负数没有物理意义 → 夹到 0（= 按形状自动算）。
	if d.has("inertia_enabled"):
		b.inertia_enabled = bool(d["inertia_enabled"])
	if d.has("inertia_value"):
		b.inertia_value = clampf(float(d["inertia_value"]), 0.0, 20000000.0)
	# 重力 / 滚动开关 + 轴偏移。
	# ★ 开关走 set_motion_toggles：同时标记「已显式配置」并**剥离**残留的旧 gravity/rollable 标签
	#   （这两个开关已从标签系统移除，标签只剩存量迁移的作用），
	#   否则 _ready 会用旧标签把刚写入的开关覆盖掉。
	var has_motion_toggle: bool = d.has("gravity_enabled") or d.has("roll_enabled")
	if d.has("free_roll"):
		b.free_roll = bool(d["free_roll"])
	if d.has("roll_axis_x") or d.has("roll_axis_y"):
		b.roll_axis_offset = Vector2(float(d.get("roll_axis_x", 0.0)), float(d.get("roll_axis_y", 0.0)))
	if has_motion_toggle and b.has_method("set_motion_toggles"):
		b.set_motion_toggles(
			bool(d.get("gravity_enabled", b.gravity_enabled)),
			bool(d.get("roll_enabled", b.roll_enabled))
		)
	if b.has_method("refresh_fill_visual"):
		b.refresh_fill_visual()   # 骨骼填充：按新路径/类型重建离屏场景（静态图/纯色只重绘）
	elif b.has_method("queue_redraw"):
		b.queue_redraw()
	print("[BlockProperty.apply_to_block] 已应用: text_boxes=%d, TEXT标签=%s, collision_layer=%s" % [b.text_boxes.size(), str(BlockTags.TEXT in b.tags), b.collision_layer])


# 把 prop dict 转成“新积木类型 def”（含 name）
static func to_type_def(name: String, prop: Dictionary) -> Dictionary:
	var d := prop.duplicate(true)
	d["name"] = name
	if not d.has("tags"):
		d["tags"] = PackedStringArray(DEFAULT_TAGS)
	return d


# 校验积木类型名（返回 "" 表示通过，非空为错误信息）
# 说明：类型名仅作为「字典键 / 显示用」，不参与代码标识符，故放行非 ASCII 字符（如中文）。
# 仍拒绝：空、超长、空白字符、数字开头、以及 ASCII 标点符号。
static func validate_name(name: String) -> String:
	var n := name.strip_edges()
	if n.is_empty():
		return "名字不能为空"
	if n.length() > 32:
		return "名字太长(>32 字符)"
	if not _is_name_char(n[0], true):
		return "名字必须以字母或下划线开头"
	for i in n.length():
		if not _is_name_char(n[i], false):
			return "名字只能含字母、数字、下划线"
	return ""


# 类型名字符合法性：字母 / 数字 / 下划线；非 ASCII（中文等）放行，空白拒绝
static func _is_name_char(c: String, is_first: bool) -> bool:
	if c.length() != 1:
		return false
	if c.strip_edges().is_empty():
		return false
	var code := c.unicode_at(0)
	if code > 127:
		return true
	if c >= "a" and c <= "z":
		return true
	if c >= "A" and c <= "Z":
		return true
	if c == "_":
		return true
	if not is_first and c >= "0" and c <= "9":
		return true
	return false


# ---- 文本框 互转 ----
static func text_box_to_dict(tb) -> Dictionary:
	if tb == null:
		return {}
	var out: Dictionary = {
		"name": tb.name,
		"width": float(tb.width),
		"height": float(tb.height),
		"cx": float(tb.center_offset.x),
		"cy": float(tb.center_offset.y),
		"border_color": color_to_hex(tb.border_color),
		"fill_color": color_to_hex(tb.fill_color),
		"fill_source": int(tb.fill_source),
		"fill_image_path": tb.fill_image_path,
		"rotation_deg": float(tb.rotation_deg),
		"follow_block_rotation": bool(tb.follow_block_rotation),
		"text_def": tb.text_def,
		"hide_when_empty": bool(tb.hide_when_empty),
	}
	# 多语言文本定义（语言代码 → 定义串）。
	# ★ 空字典「不写键」：存量存档 / block_types/*.json 里没有这个字段，
	#   若强行写 {} 会让它们首次保存后满屏 diff（且旧版本读回也多余）。非空才落盘。
	if not tb.text_defs.is_empty():
		out["text_defs"] = tb.text_defs.duplicate(true)
	return out


static func text_box_from_dict(d: Dictionary) -> TextBox:
	var tb := TextBox.new()
	tb.name = d.get("name", "")
	tb.width = float(d.get("width", 200.0))
	tb.height = float(d.get("height", 48.0))
	tb.center_offset = Vector2(float(d.get("cx", 0.0)), float(d.get("cy", 0.0)))
	tb.border_color = hex_to_color(d.get("border_color", "#FFFFFFFF"))
	tb.fill_color = hex_to_color(d.get("fill_color", "#3399FFFF"))
	tb.fill_source = int(d.get("fill_source", 0))
	tb.fill_image_path = d.get("fill_image_path", "")
	tb.rotation_deg = float(d.get("rotation_deg", 0.0))
	tb.follow_block_rotation = bool(d.get("follow_block_rotation", true))
	tb.text_def = d.get("text_def", "")
	# 缺字段（存量存档）→ 空字典 = 只用默认文本；类型不对（手工改坏）也当空，不让它崩。
	var defs: Variant = d.get("text_defs", {})
	if defs is Dictionary:
		tb.text_defs = (defs as Dictionary).duplicate(true)
	tb.hide_when_empty = bool(d.get("hide_when_empty", false))
	return tb


# ---- 攻击判定框 互转 ----
static func attack_box_to_dict(ab) -> Dictionary:
	if ab == null:
		return {}
	return {
		"name": ab.name,
		"width": float(ab.width),
		"height": float(ab.height),
		"cx": float(ab.center_offset.x),
		"cy": float(ab.center_offset.y),
		"enable_condition": ab.enable_condition,
		"attack_power": ab.attack_power,
	}


static func attack_box_from_dict(d: Dictionary) -> AttackBox:
	var ab := AttackBox.new()
	ab.name = str(d.get("name", "判定框"))
	ab.width = maxf(1.0, float(d.get("width", 120.0)))
	ab.height = maxf(1.0, float(d.get("height", 120.0)))
	ab.center_offset = Vector2(float(d.get("cx", 0.0)), float(d.get("cy", 0.0)))
	ab.enable_condition = str(d.get("enable_condition", ""))
	ab.attack_power = str(d.get("attack_power", ""))
	return ab


# ---- 数值条 互转 ----
static func value_bar_to_dict(vb) -> Dictionary:
	if vb == null:
		return {}
	return {
		"name": vb.name,
		"orientation": int(vb.orientation),
		"cx": float(vb.center_offset.x),
		"cy": float(vb.center_offset.y),
		"width": float(vb.width),
		"height": float(vb.height),
		"show_mode": int(vb.show_mode),
		"current_var": vb.current_var,
		"max_var": vb.max_var,
		# ★ bind_var = 「对应变量」：绑局部变量（优先）或全局变量。旧键 current_var/max_var
		#   仍会被读入（见 value_bar_from_dict 的兼容分支），保证存量 JSON / 旧档不丢绑定。
		"bind_var": vb.bind_var,
		"style": int(vb.style),
		"active_color": color_to_hex(vb.active_color),
		"consumed_color": color_to_hex(vb.consumed_color),
		"segments": int(vb.segments),
		"icon_active_path": vb.icon_active_path,
		"icon_consumed_path": vb.icon_consumed_path,
	}


static func value_bar_from_dict(d: Dictionary) -> ValueBar:
	var vb := ValueBar.new()
	vb.name = d.get("name", "")
	vb.orientation = int(d.get("orientation", 0))
	vb.center_offset = Vector2(float(d.get("cx", 0.0)), float(d.get("cy", 0.0)))
	vb.width = maxf(1.0, float(d.get("width", 100.0)))
	vb.height = maxf(1.0, float(d.get("height", 8.0)))
	vb.show_mode = int(d.get("show_mode", 0))
	# ★ 兼容：优先读新键 bind_var；没有则回退旧的 current_var（存量 JSON 迁移路径）。
	vb.bind_var = str(d.get("bind_var", d.get("current_var", "")))
	vb.current_var = str(d.get("current_var", ""))
	vb.max_var = str(d.get("max_var", ""))
	vb.style = int(d.get("style", 0))
	vb.active_color = hex_to_color(d.get("active_color", "#FF0000FF"))
	vb.consumed_color = hex_to_color(d.get("consumed_color", "#000000FF"))
	vb.segments = maxi(1, int(d.get("segments", 1)))
	vb.icon_active_path = d.get("icon_active_path", "")
	vb.icon_consumed_path = d.get("icon_consumed_path", "")
	return vb


# ---- 局部变量 互转 ----
static func local_var_to_dict(lv) -> Dictionary:
	if lv == null:
		return {}
	return {
		"name": lv.name,
		"min_value": float(lv.min_value),
		"max_value": float(lv.max_value),
		"current_value": float(lv.current_value),
		"recover_rate": float(lv.recover_rate),
		"recover_amount": float(lv.recover_amount),
	}


static func local_var_from_dict(d: Dictionary) -> LocalVar:
	var lv := LocalVar.new()
	lv.name = str(d.get("name", ""))
	lv.min_value = float(d.get("min_value", 0.0))
	lv.max_value = float(d.get("max_value", 100.0))
	lv.current_value = float(d.get("current_value", 100.0))
	lv.recover_rate = float(d.get("recover_rate", 0.0))
	lv.recover_amount = float(d.get("recover_amount", 0.0))
	# 夹紧一次：存量 JSON 里 min/max 被改小后 current 可能越界
	lv.clamp_current()
	return lv


# ================= 属性字典 → 控制台创建命令 =================
# 把 property_editor_panel._collect_prop_dict() 产出的字典序列化为 /create_block { ... } 文本，
# 供「复制为命令」按钮回放。text_boxes / attack_boxes 是对象数组，需先转成 dict 才能序列化。

static func prop_to_command(prop: Dictionary, block = null) -> String:
	var d := prop.duplicate(true)
	# 文本框 / 攻击框：对象数组 → dict 数组（text_box_to_dict / attack_box_to_dict 保留全部字段）
	if d.has("text_boxes"):
		var tb_dicts: Array = []
		for tb in d["text_boxes"]:
			if tb != null:
				tb_dicts.append(text_box_to_dict(tb))
		d["text_boxes"] = tb_dicts
	if d.has("attack_boxes"):
		var ab_dicts: Array = []
		for ab in d["attack_boxes"]:
			if ab != null:
				ab_dicts.append(attack_box_to_dict(ab))
		d["attack_boxes"] = ab_dicts
	if d.has("value_bars"):
		var vb_dicts: Array = []
		for vb in d["value_bars"]:
			if vb != null:
				vb_dicts.append(value_bar_to_dict(vb))
		d["value_bars"] = vb_dicts
	if d.has("local_vars"):
		var lv_dicts: Array = []
		for lv in d["local_vars"]:
			if lv != null:
				lv_dicts.append(local_var_to_dict(lv))
		d["local_vars"] = lv_dicts
	# 跳过「空/零」哨兵值，避免回放时出现无意义甚至非法的赋值（如 id=0 / 空 string_id）
	var bag: PackedStringArray = []
	if block != null and is_instance_valid(block):
		bag.append("position = (%s,%s)" % [_fmt_num(block.global_position.x), _fmt_num(block.global_position.y)])
	for k in d:
		var v = d[k]
		var ks := str(k)
		if ks in ["fill_path", "string_id"] and (v == null or str(v).strip_edges() == ""):
			continue
		if ks in ["id", "parent_id"] and int(v) <= 0:
			continue
		if (ks == "child_ids" or ks == "text_boxes" or ks == "attack_boxes") and v is Array and v.is_empty():
			continue
		bag.append("%s = %s" % [ks, _serialize_value(v)])
	return "/create_block { " + ", ".join(bag) + " }"


static func _serialize_value(v) -> String:
	if v == null:
		return "null"
	if v is bool:
		return "true" if v else "false"
	if v is int or v is float:
		return _fmt_num(v)
	if v is String:
		return "\"" + _escape_str(v) + "\""
	if v is Vector2:
		return "(%s,%s)" % [_fmt_num(v.x), _fmt_num(v.y)]
	if v is Array or v is PackedStringArray or v is PackedInt32Array or v is PackedFloat32Array or v is PackedByteArray:
		var parts: PackedStringArray = []
		for e in v:
			parts.append(_serialize_value(e))
		return "{ " + ", ".join(parts) + " }"
	if v is Dictionary:
		var parts: PackedStringArray = []
		for k in v:
			parts.append("%s = %s" % [str(k), _serialize_value(v[k])])
		return "{ " + ", ".join(parts) + " }"
	return "\"" + _escape_str(str(v)) + "\""


static func _fmt_num(v: float) -> String:
	if v == floor(v) and abs(v) < 1e15:
		return str(int(v))
	return str(v)


static func _escape_str(s: String) -> String:
	return s.replace("\\", "\\\\").replace("\"", "\\\"")


# ---- 颜色助手 ----
static func color_to_hex(c: Color) -> String:
	return "#%02X%02X%02X%02X" % [int(c.r * 255.0), int(c.g * 255.0), int(c.b * 255.0), int(c.a * 255.0)]


static func is_valid_hex_color(s: String) -> bool:
	if s == null or s.is_empty():
		return true
	var hex: String = s
	if hex.begins_with("#"):
		hex = hex.substr(1)
	if hex.length() != 3 and hex.length() != 6 and hex.length() != 8:
		return false
	for i in hex.length():
		var c: String = hex[i]
		if not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f") or (c >= "A" and c <= "F")):
			return false
	return true


# "#RRGGBB" / "RRGGBB" / "#RGB" / "#RRGGBBAA" → Color（失败返回透明黑，由调用方判断）。
# ★ 兼容带/不带 "#" 前缀：代码默认 def 用 Color.to_html() 输出无前缀（如 "9ea3bf42"），
#   而属性面板序列化用 color_to_hex() 输出带前缀；两种都支持，避免存量 JSON 颜色被解析成透明黑。
static func hex_to_color(s: String) -> Color:
	if s == null or s.is_empty():
		return Color(0, 0, 0, 0)
	if not is_valid_hex_color(s):
		return Color(0, 0, 0, 0)
	var hex: String = s
	if hex.begins_with("#"):
		hex = hex.substr(1)
	if hex.length() == 3:
		var expanded: String = ""
		for i in 3:
			expanded += hex[i] + hex[i]
		hex = expanded
	var r: float = _hex_pair_to_byte(hex.substr(0, 2)) / 255.0
	var g: float = _hex_pair_to_byte(hex.substr(2, 2)) / 255.0
	var b: float = _hex_pair_to_byte(hex.substr(4, 2)) / 255.0
	var a: float = 1.0
	if hex.length() == 8:
		a = _hex_pair_to_byte(hex.substr(6, 2)) / 255.0
	return Color(r, g, b, a)


static func _hex_pair_to_byte(pair: String) -> float:
	if pair.length() != 2:
		return 0.0
	var hi := _hex_char_to_nibble(pair[0])
	var lo := _hex_char_to_nibble(pair[1])
	return float(hi * 16 + lo)


static func _hex_char_to_nibble(c: String) -> int:
	if c.length() != 1:
		return 0
	var ch := c.unicode_at(0)
	if ch >= 0x30 and ch <= 0x39:
		return ch - 0x30
	if ch >= 0x41 and ch <= 0x46:
		return ch - 0x41 + 10
	if ch >= 0x61 and ch <= 0x66:
		return ch - 0x61 + 10
	return 0
