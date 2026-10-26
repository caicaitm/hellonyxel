# 从 PSD 拆分图层生成「猫娘走路」2D 骨骼场景。
# 用法：godot --headless --path . --script res://tools/build_cat_walk_rig.gd
# 输出：res://textures/cats/walk_rig/cat_walk_rig.tscn
#   walk   —— Sprite2D 分层 + 髋/肩/颈枢轴（原版动画）
#   walk.1 —— 四肢改用整张未切分贴图的网格蒙皮（Skeleton2D 两段骨），膝盖/手肘可弯曲
#   walk.2 — walk.6 —— 在 .1 基础上用不同步态参数做出的多个版本，供挑选
extends SceneTree

const PARTS := "res://textures/cats/walk_rig/parts/"
const OUT_SCENE := "res://textures/cats/walk_rig/cat_walk_rig.tscn"

# 蒙皮网格的顶点间距（像素）与关节附近的权重过渡带宽度
const SKIN_CELL := 9.0
const SKIN_BLEND := 18.0
# 上臂 / 大腿的骨骼长度，决定肘、膝的弯曲位置
const ARM_UPPER_LEN := 100.0
const LEG_UPPER_LEN := 118.0

# 走路动画的默认参数；各版本只覆盖需要变化的项。
#   bob         身体上下起伏幅度（px）
#   lift_h      抬腿高度（px）
#   lift_in     抬腿时向身体中线的内收量（px）
#   hip_rot     抬腿时髋关节外摆角（rad）
#   leg_squash  抬腿时腿的纵向缩短比例（透视）
#   arm_swing   对侧手臂摆幅（rad）
#   arm_shorten 摆臂时手臂纵向缩短比例（透视）
#   knee        抬腿时膝盖弯曲角（rad）
#   elbow_base  手肘基础弯曲角（rad）
#   elbow_swing 摆臂时额外的手肘弯曲角（rad）
#   sway        重心左右摆动幅度（px）
#   lean        身体左右倾斜角（rad）
const WALK_DEFAULTS := {
	"bob": 7.0, "lift_h": 24.0, "lift_in": 6.0, "hip_rot": 0.08,
	"leg_squash": 0.08, "arm_swing": 0.1, "arm_shorten": 0.0,
	"knee": 0.55, "elbow_base": 0.45, "elbow_swing": 0.1,
	"sway": 6.0, "lean": 0.03,
}

const WALK_VARIANTS := {
	# 原版：Sprite2D 分层，骨骼零弯曲
	"walk": {},
	# 整图蒙皮 + 轻微屈膝
	"walk.1": {},
	# 抬腿抬臂（上一版）
	"walk.2": {
		"bob": 10.0, "lift_h": 40.0, "lift_in": 10.0, "hip_rot": 0.22,
		"leg_squash": 0.12, "arm_swing": 0.6, "arm_shorten": 0.1,
		"knee": 0.9, "elbow_base": 0.5, "elbow_swing": 0.25,
	},
	# 自然小步：步幅和摆臂都收小，接近日常走路
	"walk.3": {
		"bob": 6.0, "lift_h": 18.0, "lift_in": 4.0, "hip_rot": 0.1,
		"leg_squash": 0.06, "arm_swing": 0.18, "arm_shorten": 0.03,
		"knee": 0.35, "elbow_base": 0.3, "elbow_swing": 0.1,
		"sway": 5.0, "lean": 0.025,
	},
	# 大步低膝：迈得更开、手臂摆幅中等，膝盖弯曲克制
	"walk.4": {
		"bob": 9.0, "lift_h": 32.0, "lift_in": 8.0, "hip_rot": 0.12,
		"leg_squash": 0.1, "arm_swing": 0.35, "arm_shorten": 0.06,
		"knee": 0.55, "elbow_base": 0.4, "elbow_swing": 0.16,
		"sway": 8.0, "lean": 0.04,
	},
	# 高抬腿：正步感，抬腿最高、屈膝最深、摆臂最大
	"walk.5": {
		"bob": 12.0, "lift_h": 58.0, "lift_in": 12.0, "hip_rot": 0.28,
		"leg_squash": 0.14, "arm_swing": 0.85, "arm_shorten": 0.16,
		"knee": 1.25, "elbow_base": 0.65, "elbow_swing": 0.3,
		"sway": 6.0, "lean": 0.03,
	},
	# 夸张重心：左右摇摆最明显，像悠着步子走
	"walk.6": {
		"bob": 9.0, "lift_h": 26.0, "lift_in": 14.0, "hip_rot": 0.18,
		"leg_squash": 0.09, "arm_swing": 0.45, "arm_shorten": 0.08,
		"knee": 0.6, "elbow_base": 0.5, "elbow_swing": 0.2,
		"sway": 14.0, "lean": 0.06,
	},
}

# PSD 画布坐标（1024×1024）下的关节位置
const BODY_ORIGIN := Vector2(523.0, 700.0)
const HEAD_PIVOT := Vector2(523.0, 435.0)
const HIP_L := Vector2(563.0, 690.0)
const HIP_R := Vector2(465.0, 690.0)
const SHOULDER_L := Vector2(610.0, 495.0)
const SHOULDER_R := Vector2(425.0, 500.0)
const GROUND := Vector2(523.0, 949.0)


func _initialize() -> void:
	var root := Node2D.new()
	root.name = "CatWalkRig"

	_add_shadow(root)
	var body := _add_node2d("Body", BODY_ORIGIN, root)

	# PSD 自下而上的图层顺序：后发/右臂/腿/上衣/左臂/颈/头。
	# 背发挂到头枢轴下（要跟随头部），用负 z_index 压到身体后面。
	_add_limb("ArmL", body, SHOULDER_L, BODY_ORIGIN,
		[["ArmL", "arm_l.png", Rect2(548, 463, 130, 261)]], ARM_UPPER_LEN)
	_add_limb("LegL", body, HIP_L, BODY_ORIGIN,
		[["LegL", "leg_l.png", Rect2(504, 665, 118, 284)]], LEG_UPPER_LEN)
	_add_limb("LegR", body, HIP_R, BODY_ORIGIN,
		[["LegR", "leg_r.png", Rect2(406, 663, 118, 286)]], LEG_UPPER_LEN)
	_add_sprite("Torso", "topwear.png", Rect2(435, 455, 187, 281), body)
	_add_limb("ArmR", body, SHOULDER_R, BODY_ORIGIN,
		[["ArmR", "arm_r.png", Rect2(352, 471, 138, 265)]], ARM_UPPER_LEN)
	_add_sprite("Neck", "neck.png", Rect2(492, 420, 61, 61), body)

	var head := _add_node2d("Head", HEAD_PIVOT - BODY_ORIGIN, body)
	_add_sprite("BackHair", "back_hair.png", Rect2(243, 102, 498, 632), head, -20)
	_add_sprite("Face", "face.png", Rect2(406, 159, 267, 298), head)
	_add_sprite("Mouth", "mouth.png", Rect2(554, 415, 22, 6), head)
	_add_sprite("EyebrowL", "eyebrow_l.png", Rect2(606, 312, 29, 7), head)
	_add_sprite("EyebrowR", "eyebrow_r.png", Rect2(494, 309, 38, 8), head)
	_add_sprite("EyewhiteL", "eyewhite_l.png", Rect2(597, 343, 44, 62), head)
	_add_sprite("EyewhiteR", "eyewhite_r.png", Rect2(473, 342, 54, 64), head)
	_add_sprite("EyelashL", "eyelash_l.png", Rect2(604, 342, 44, 28), head)
	_add_sprite("EyelashR", "eyelash_r.png", Rect2(464, 340, 60, 31), head)
	_add_sprite("EarR", "ear_r.png", Rect2(313, 95, 151, 166), head)
	_add_sprite("EarL", "ear_l.png", Rect2(594, 102, 131, 159), head)
	_add_sprite("FrontHair", "front_hair.png", Rect2(352, 58, 373, 437), head)

	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	var lib := AnimationLibrary.new()
	for variant in WALK_VARIANTS:
		lib.add_animation(variant, _make_walk_anim(variant))
	player.add_animation_library("", lib)
	player.autoplay = "walk"
	root.add_child(player)
	player.owner = root
	for n in root.get_children():
		_own_recursive(n, root)

	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err != OK:
		push_error("打包场景失败: %s" % err)
		quit(1)
		return
	err = ResourceSaver.save(packed, OUT_SCENE)
	if err != OK:
		push_error("保存场景失败: %s" % err)
		quit(1)
		return
	print("[build_cat_walk_rig] 已生成 %s" % OUT_SCENE)
	quit()


func _own_recursive(node: Node, owner: Node) -> void:
	node.owner = owner
	for c in node.get_children():
		_own_recursive(c, owner)


func _add_node2d(node_name: String, pos: Vector2, parent: Node) -> Node2D:
	var n := Node2D.new()
	n.name = node_name
	n.position = pos
	parent.add_child(n)
	return n


func _add_sprite(node_name: String, tex_file: String, bbox: Rect2, parent: Node, z: int = 0) -> Sprite2D:
	var s := Sprite2D.new()
	s.name = node_name
	s.centered = false
	s.texture = load(PARTS + tex_file)
	# 位置 = 图层包围盒左上角相对父级的画布原点（Head 等节点自身有偏移，不能直接用 parent.position）。
	s.position = bbox.position - _canvas_pos(parent)
	s.z_index = z
	parent.add_child(s)
	return s


# 节点在 PSD 画布坐标系里的累计位置（构建期节点尚未入树，不能用 global_position）。
func _canvas_pos(node: Node) -> Vector2:
	var p := Vector2.ZERO
	var cur: Node = node
	while cur is Node2D:
		p += (cur as Node2D).position
		cur = cur.get_parent()
	return p


# 肢体枢轴：旋/缩都绕关节，Sprite 只是挂在枢轴下的偏移图层。
# parts 为 [[节点名, 贴图, PSD包围盒], ...]（目前每根肢体单段）。
# upper_len > 0 时额外生成一份整张贴图的网格蒙皮（walk.1 用），默认隐藏。
func _add_limb(node_name: String, body: Node2D, joint: Vector2, body_origin: Vector2, parts: Array, upper_len: float = 0.0) -> Node2D:
	var pivot := _add_node2d(node_name, joint - body_origin, body)
	for p in parts:
		var s := Sprite2D.new()
		s.name = str(p[0])
		s.centered = false
		s.texture = load(PARTS + str(p[1]))
		var box: Rect2 = p[2]
		s.position = box.position - joint
		pivot.add_child(s)
		if upper_len > 0.0:
			_add_skin_limb(pivot, str(p[1]), box, joint, upper_len)
	return pivot


# 不做任何贴图切分：把整张肢体 PNG 铺成密集三角网格，用两根 Bone2D
# （Upper 从关节起，Lower 挂在肘/膝处）按到关节的距离平滑分配权重。
# 骨骼转动时网格跟着变形，所以肘和膝能弯，而贴图始终是一整张。
func _add_skin_limb(pivot: Node2D, tex_file: String, box: Rect2, joint: Vector2, upper_len: float) -> void:
	var size := box.size
	var offset := box.position - joint
	var cols := maxi(2, int(round(size.x / SKIN_CELL)))
	var rows := maxi(2, int(round(size.y / SKIN_CELL)))

	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var tris: Array[PackedInt32Array] = []
	for gy in rows + 1:
		for gx in cols + 1:
			var px := size.x * float(gx) / float(cols)
			var py := size.y * float(gy) / float(rows)
			verts.append(offset + Vector2(px, py))
			# Polygon2D 的 uv 是贴图像素坐标，不是 0~1 归一化值。
			uvs.append(Vector2(px, py))
	for gy in rows:
		for gx in cols:
			var i0 := gy * (cols + 1) + gx
			var i1 := i0 + 1
			var i2 := i0 + (cols + 1)
			var i3 := i2 + 1
			tris.append(PackedInt32Array([i0, i1, i2]))
			tris.append(PackedInt32Array([i1, i3, i2]))

	var skel := Skeleton2D.new()
	skel.name = "Skel"
	pivot.add_child(skel)

	var upper := Bone2D.new()
	upper.name = "Upper"
	upper.set_autocalculate_length_and_angle(false)
	skel.add_child(upper)
	upper.set_rest(Transform2D(0.0, Vector2.ZERO))
	upper.set_length(upper_len)

	var lower_len := maxf(1.0, size.y + offset.y - upper_len)
	var lower := Bone2D.new()
	lower.name = "Lower"
	lower.position = Vector2(0.0, upper_len)
	lower.set_autocalculate_length_and_angle(false)
	upper.add_child(lower)
	lower.set_rest(Transform2D(0.0, Vector2(0.0, upper_len)))
	lower.set_length(lower_len)

	var wh := PackedFloat32Array()
	var wk := PackedFloat32Array()
	for v in verts:
		var s := clampf((v.y - (upper_len - SKIN_BLEND)) / (SKIN_BLEND * 2.0), 0.0, 1.0)
		var t := s * s * (3.0 - 2.0 * s)
		wh.append(1.0 - t)
		wk.append(t)

	var poly := Polygon2D.new()
	poly.name = "Skin"
	poly.texture = load(PARTS + tex_file)
	poly.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	poly.polygon = verts
	poly.uv = uvs
	poly.polygons = tris
	poly.visible = false
	pivot.add_child(poly)
	poly.skeleton = NodePath("../Skel")
	poly.add_bone(NodePath("../Skel/Upper"), wh)
	poly.add_bone(NodePath("../Skel/Upper/Lower"), wk)


func _add_shadow(root: Node2D) -> void:
	var pivot := _add_node2d("ShadowPivot", GROUND, root)
	var poly := Polygon2D.new()
	poly.name = "Shadow"
	var pts := PackedVector2Array()
	for i in 40:
		var a := TAU * float(i) / 40.0
		pts.append(Vector2(cos(a) * 165.0, sin(a) * 18.0))
	poly.polygon = pts
	poly.color = Color(0.08, 0.09, 0.14, 0.28)
	pivot.add_child(poly)


# walk  原版：Sprite2D 图层，骨骼零弯曲；
# walk.1 起改用整图蒙皮 + 肘/膝弯曲，各版本只在步态参数上做差异（见 WALK_VARIANTS）。
func _make_walk_anim(variant: String) -> Animation:
	var cfg := WALK_DEFAULTS.duplicate()
	if WALK_VARIANTS.has(variant):
		for k in WALK_VARIANTS[variant]:
			cfg[k] = WALK_VARIANTS[variant][k]
	var with_bend := variant != "walk"
	var bob_amp: float = cfg["bob"]
	var lift_h: float = cfg["lift_h"]
	var lift_in: float = cfg["lift_in"]
	var hip_rot: float = cfg["hip_rot"]
	var leg_squash: float = cfg["leg_squash"]
	var arm_swing: float = cfg["arm_swing"]
	var arm_shorten: float = cfg["arm_shorten"]
	var knee_amp: float = cfg["knee"]
	var elbow_base: float = cfg["elbow_base"]
	var elbow_swing: float = cfg["elbow_swing"]
	var sway_amp: float = cfg["sway"]
	var lean: float = cfg["lean"]

	var anim := Animation.new()
	anim.resource_name = variant
	anim.length = 0.8
	anim.loop_mode = Animation.LOOP_LINEAR
	anim.step = 1.0 / 30.0

	var times := PackedFloat32Array()
	var body_pos: Array = []
	var body_rot: Array = []
	var head_pos: Array = []
	var head_rot: Array = []
	var hair_rot: Array = []
	var arm_l_rot: Array = []
	var arm_l_scale: Array = []
	var arm_r_rot: Array = []
	var arm_r_scale: Array = []
	var leg_l_pos: Array = []
	var leg_l_rot: Array = []
	var leg_l_scale: Array = []
	var leg_r_pos: Array = []
	var leg_r_rot: Array = []
	var leg_r_scale: Array = []
	var shadow_scale: Array = []
	var elbow_l: Array = []
	var elbow_r: Array = []
	var knee_l: Array = []
	var knee_r: Array = []

	var steps := 8
	for i in steps + 1:
		var t := 0.8 * float(i) / float(steps)
		var phase := TAU * t / 0.8
		times.append(t)
		# 身体：每步一次上下起伏（一个循环两次），左右重心交替。
		var bob := -bob_amp * (0.5 - 0.5 * cos(phase * 2.0))
		var sway := -sway_amp * sin(phase)
		body_pos.append(BODY_ORIGIN + Vector2(sway, bob))
		body_rot.append(-lean * sin(phase))
		# 头部：抵消部分身体起伏 + 反向小幅倾头。
		head_pos.append(HEAD_PIVOT - BODY_ORIGIN + Vector2(0.0, bob * 0.35))
		head_rot.append(0.022 * sin(phase))
		hair_rot.append(-0.045 * sin(phase))
		# 抬腿：左腿前半圈，右腿后半圈；抬起时向上提、略缩短（透视）、内收并外摆。
		var lift_l := maxf(0.0, sin(phase))
		var lift_r := maxf(0.0, sin(phase + PI))
		leg_l_pos.append(HIP_L - BODY_ORIGIN + Vector2(-lift_in * lift_l, -lift_h * lift_l))
		leg_l_rot.append(-hip_rot * lift_l)
		leg_l_scale.append(Vector2(1.0, 1.0 - leg_squash * lift_l))
		leg_r_pos.append(HIP_R - BODY_ORIGIN + Vector2(lift_in * lift_r, -lift_h * lift_r))
		leg_r_rot.append(hip_rot * lift_r)
		leg_r_scale.append(Vector2(1.0, 1.0 - leg_squash * lift_r))
		# 手臂与同侧腿反向摆：抬腿时对侧手臂向前上方甩出，并轻微缩短模拟前摆透视。
		arm_l_rot.append(-arm_swing * lift_r)
		arm_l_scale.append(Vector2(1.0, 1.0 - arm_shorten * lift_r))
		arm_r_rot.append(arm_swing * lift_l)
		arm_r_scale.append(Vector2(1.0, 1.0 - arm_shorten * lift_l))
		shadow_scale.append(Vector2.ONE * (1.0 + 0.1 * bob / bob_amp))
		# 整张蒙皮时的第二段骨：抬腿屈膝、小臂随摆动微屈。
		var bend_l := lift_l if with_bend else 0.0
		var bend_r := lift_r if with_bend else 0.0
		knee_l.append(-knee_amp * bend_l)
		knee_r.append(knee_amp * bend_r)
		elbow_l.append((elbow_base + elbow_swing * bend_r) if with_bend else 0.0)
		elbow_r.append((-elbow_base - elbow_swing * bend_l) if with_bend else 0.0)

	_add_track(anim, "Body:position", times, body_pos)
	_add_track(anim, "Body:rotation", times, body_rot)
	_add_track(anim, "Body/Head:position", times, head_pos)
	_add_track(anim, "Body/Head:rotation", times, head_rot)
	_add_track(anim, "Body/Head/BackHair:rotation", times, hair_rot)
	_add_track(anim, "Body/ArmL:rotation", times, arm_l_rot)
	_add_track(anim, "Body/ArmL:scale", times, arm_l_scale)
	_add_track(anim, "Body/ArmR:rotation", times, arm_r_rot)
	_add_track(anim, "Body/ArmR:scale", times, arm_r_scale)
	_add_track(anim, "Body/LegL:position", times, leg_l_pos)
	_add_track(anim, "Body/LegL:rotation", times, leg_l_rot)
	_add_track(anim, "Body/LegL:scale", times, leg_l_scale)
	_add_track(anim, "Body/LegR:position", times, leg_r_pos)
	_add_track(anim, "Body/LegR:rotation", times, leg_r_rot)
	_add_track(anim, "Body/LegR:scale", times, leg_r_scale)
	_add_track(anim, "ShadowPivot:scale", times, shadow_scale)
	_add_track(anim, "Body/ArmL/Skel/Upper/Lower:rotation", times, elbow_l)
	_add_track(anim, "Body/ArmR/Skel/Upper/Lower:rotation", times, elbow_r)
	_add_track(anim, "Body/LegL/Skel/Upper/Lower:rotation", times, knee_l)
	_add_track(anim, "Body/LegR/Skel/Upper/Lower:rotation", times, knee_r)

	# 同一根肢体有两套表现：walk 用原 Sprite2D 图层，walk.1 用蒙皮网格。
	var once := PackedFloat32Array([0.0])
	for limb in ["ArmL", "ArmR", "LegL", "LegR"]:
		_add_track(anim, "Body/%s/%s:visible" % [limb, limb], once, [not with_bend])
		_add_track(anim, "Body/%s/Skin:visible" % limb, once, [with_bend])
	return anim


func _add_track(anim: Animation, path: String, times: PackedFloat32Array, values: Array) -> void:
	var idx := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(idx, NodePath(path))
	anim.track_set_interpolation_type(idx, Animation.INTERPOLATION_LINEAR)
	for i in values.size():
		anim.track_insert_key(idx, times[i], values[i])
