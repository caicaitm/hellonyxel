# desktop_demo.gd
# 「桌面」示例积木（原 desktop.gd 里的 6 组演示内容，整体搬到这里）。
#
# ★ 为什么搬走：正式启动时桌面应当**是空的**（只有屏幕外那圈「桌面屏障」），
#   积木由事件链 / 调试面板 / 右键菜单按需创建。示例积木只在做验证时使用。
#
# 启用方式（默认关闭）：
#   命令行/环境变量 HELLONYXEL_DEMO=1 → desktop.gd 会在 _ready 里调 spawn(self)
#   例：HELLONYXEL_DEMO=1 godot --path <项目路径>
#
# 这里保留的是**逐字迁移**的旧演示内容，它们的用途是回归验证：
#   1) 示例积木（可拖动 + 碰撞 + 文本框）
#   2) 静态地面（重力 / 跳跃 / 落地）
#   3) 受控测试块（WASD 移动、空格连跳）
#   4) 父子级锚定（载具 + 两个子级）
#   5) 「被拖动中」碰撞图层（能挡住被拖动积木的墙）
#   6) 检测标签「待检测_竖直移动」区域（区外 W/S 无效，区内有效）
class_name DesktopDemo
extends RefCounted


# 在 root（桌面场景根节点）下生成全部示例积木
static func spawn(root: Node2D) -> void:
	if root == null:
		return

	# 1. 普通示例块（可拖动 + 碰撞）
	var demo := Block.new()
	demo.position = Vector2(480, 320)
	demo.width = 200.0
	demo.height = 140.0
	demo.tags = ["show", "border", "fill", "text", "collision", "draggable"]
	demo.variable_resolver = func(nm: String) -> Variant:
		return {"rank": 3, "player": "张三"}.get(nm)
	root.add_child(demo)

	# 1b. 示例文本框（验证文本框子节点渲染）
	#     文本框是 Block 的真实子节点（TextBoxView），不再由 Block._draw 手绘。
	var demo_tb := TextBox.new()
	demo_tb.name = "标题"
	demo_tb.width = 176.0
	demo_tb.height = 48.0
	demo_tb.center_offset = Vector2(0, 0)
	demo_tb.rotation_deg = 0.0
	demo_tb.follow_block_rotation = true
	demo_tb.fill_color = Color(0.05, 0.25, 0.5, 0.85)
	demo_tb.border_color = Color(0.5, 0.95, 1.0, 1.0)
	demo_tb.text_def = '(#FFD700,C)["Hello 荧惑"]'
	# 「内容为空时隐藏」示例：本框有文本 → 仍正常显示；若文本被改成空，整框会消失。
	demo_tb.hide_when_empty = true
	var demo_tbs: Array[TextBox] = []
	demo_tbs.append(demo_tb)
	demo.text_boxes = demo_tbs

	# 2. 静态地面块（碰撞支撑，验证重力/跳跃用）
	var ground := Block.new()
	ground.position = Vector2(480, 600)
	ground.width = 700.0
	ground.height = 40.0
	ground.tags = ["show", "border", "fill", "collision"]
	ground.fill_color = Color(0.35, 0.35, 0.4, 1.0)
	root.add_child(ground)

	# 3. 受控测试块（可拖动 + 重力 + 受控：WASD/方向键移动、空格跳跃）
	#    出生点放在示例积木右侧的空档，让它落到**地面**上（而不是停在示例积木顶面），
	#    这样按住空格可以直观看到"落地 → 再次起跳"的连续跳跃。
	var player := Block.new()
	player.position = Vector2(700, 200)
	player.width = 60.0
	player.height = 60.0
	player.tags = ["show", "border", "fill", "collision", "draggable", "controlled"]
	player.set_motion_toggles(true, false)   # 受重力 = 「积木运动」面板字段（旧 gravity 标签已移除）
	player.fill_color = Color(0.2, 0.8, 0.4, 1.0)
	root.add_child(player)

	# 4. 父子级锚定示例（按 ID 绑定，父动子动）
	#    - 父级「载具」带一个文本框显示自己的 id，方便在属性面板里填 父级ID / 子级ID；
	#    - 两个子级压在载具上方：拖动载具（鼠标左键）时子级一并位移；
	#      子级被挡住时只走"能走的那一部分"，相对位置随之改变；
	#      载具想向上移动不会被自己带的东西挡住。
	var carrier := Block.new()
	carrier.position = Vector2(250, 565)
	carrier.width = 260.0
	carrier.height = 30.0
	carrier.tags = ["show", "border", "fill", "text", "collision", "draggable"]
	carrier.set_motion_toggles(true, false)   # 同上：受重力走面板字段
	carrier.fill_color = Color(0.55, 0.42, 0.22, 1.0)
	carrier.border_color = Color(0.95, 0.82, 0.45, 1.0)
	root.add_child(carrier)   # 入树后 id 才分配

	# 变量回调必须在 text_boxes 之前挂好（文本框视图重建时会立即求值一次）
	carrier.variable_resolver = func(nm: String) -> Variant:
		if nm == "cid":
			return str(carrier.id)
		return null
	var carrier_tb := TextBox.new()
	carrier_tb.name = "标识"
	carrier_tb.width = 240.0
	carrier_tb.height = 22.0
	carrier_tb.center_offset = Vector2.ZERO
	carrier_tb.fill_color = Color(0.05, 0.25, 0.5, 0.85)
	carrier_tb.border_color = Color(0.5, 0.95, 1.0, 1.0)
	carrier_tb.text_def = '(#FFE08A,C)["载具 id="+$cid]'
	carrier_tb.hide_when_empty = true
	var carrier_tbs: Array[TextBox] = []
	carrier_tbs.append(carrier_tb)
	carrier.text_boxes = carrier_tbs

	# 两个子级：放在载具顶面上，靠重力 + 与载具的碰撞稳稳压住
	var kid_offsets: Array[float] = [60.0, -60.0]
	for ox in kid_offsets:
		var kid := Block.new()
		kid.width = 44.0
		kid.height = 44.0
		kid.position = Vector2(carrier.position.x + ox, carrier.position.y - 15.0 - 22.0)
		kid.tags = ["show", "border", "fill", "collision"]
		kid.set_motion_toggles(true, false)   # 同上：受重力走面板字段
		kid.fill_color = Color(0.9, 0.62, 0.25, 1.0)
		kid.border_color = Color(0.95, 0.85, 0.6, 1.0)
		root.add_child(kid)
		# 绑定父子级：bind_child 会自动给子级补上 child_follow 标签 → 默认即跟随
		var ok: bool = carrier.bind_child(kid)
		print("[desktop_demo] 父子级绑定: 父 id=%d ←→ 子 id=%d ok=%s" % [carrier.id, kid.id, str(ok)])

	# 5. 「被拖动中」碰撞图层示例
	#    拖动积木时，它的碰撞图层会临时覆盖成 [dragging]（BlockLayers.DRAGGING）。
	#    - 普通积木（图层只有 default）→ 与 dragging 无交集 → **挡不住被拖动的积木**，
	#      所以拖动时可以穿过地面、穿过上面的示例积木；
	#    - 本屏障的图层额外带上了 dragging → 它**能挡住**被拖动的积木（拖到这里就走不动）。
	#    想让某积木"挡住拖动中的东西"，把它的碰撞图层写成 "default,dragging" 即可。
	var drag_wall := Block.new()
	drag_wall.position = Vector2(1055, 430)
	drag_wall.width = 24.0
	drag_wall.height = 420.0
	drag_wall.tags = ["show", "border", "fill", "collision"]
	drag_wall.collision_layer = PackedStringArray([BlockLayers.DEFAULT, BlockLayers.DRAGGING])
	drag_wall.fill_color = Color(0.42, 0.30, 0.55, 1.0)
	drag_wall.border_color = Color(0.80, 0.70, 0.95, 1.0)
	root.add_child(drag_wall)

	# 6. 检测标签示例：「检测到_竖直移动」区域
	#    - 本积木带 to_detect_vertical_move（待检测_竖直移动）→ 它是一块「检测区」；
	#    - 碰撞图层写成自定义的 ["zone"]，与玩家的 ["default"] 无交集 → 玩家**不被它挡住**，
	#      可以直接走进区里面（这正是"被检测物进入检测区内部"的典型场景）；
	#    - 玩家（带 controlled）的**中心点走进它** → 自动获得 detected_vertical_move（检测到_竖直移动）
	#      → 此时 W/S / ↑/↓ 才生效（水平 A/D 本来就可用）；走出去标签被移除，竖直键立即失效。
	#    ★ 判据是"中心点入区"，不是"碰到"：蹭到边缘不算、站在区**上面**也不算（中心在区上方）。
	#      地面也因此不必特意留缝 —— 地面块的中心不可能落进本区，AABB 相邻不再误扫。
	var lift_zone := Block.new()
	lift_zone.position = Vector2(560, 495)
	lift_zone.width = 120.0
	lift_zone.height = 155.0
	lift_zone.tags = ["show", "border", "fill", "collision", "to_detect_vertical_move"]
	lift_zone.collision_layer = PackedStringArray(["zone"])
	lift_zone.fill_color = Color(0.18, 0.42, 0.55, 0.55)
	lift_zone.border_color = Color(0.45, 0.95, 1.0, 0.9)
	root.add_child(lift_zone)
