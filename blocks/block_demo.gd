# block_demo.gd
# 「桌面」场景积木系统的用法演示。把本脚本挂到任意 Node2D 场景根节点，F5 运行即可看到效果。
# 前置：project.godot 已注册 autoload「BlockManager」（本次已完成）。
extends Node2D

func _ready() -> void:
	# ---- 1) 父积木 ----
	var parent := Block.new()
	parent.width = 300.0
	parent.height = 200.0
	parent.position = Vector2(420, 300)
	parent.tags = ["show", "border", "fill", "text", "child_follow"]
	parent.border_color = UIStyle.BORDER
	parent.border_width = UIStyle.BORDER_WIDTH
	parent.fill_color = UIStyle.FILL_DEFAULT
	parent.display_layer = 1
	add_child(parent)   # 父._ready 自动向「BlockManager」申请唯一 ID

	# ---- 2) 文本框（(修饰)[内容] 富文本）----
	var tb := TextBox.new()
	tb.name = "标题"
	tb.width = 280.0
	tb.height = 60.0
	tb.center_offset = Vector2(0, -60)        # 相对积木中心向上偏移
	tb.rotation_deg = 0.0
	tb.follow_block_rotation = true
	# 文本框背景统一使用旧版 UI 深色按下态 + 荧光蓝边框
	tb.fill_color = UIStyle.FILL_PRESSED
	tb.border_color = UIStyle.BORDER
	tb.text_def = '(%80,#FFFFFF,C)[得分:]+(#FFD700)["第"+$rank+"名"]'
	# 注意：text_boxes 是 Array[TextBox]（带类型），必须用同类型数组赋值；
	# 直接写 [tb]（无类型 Array）在 Godot 4 会运行时报类型错误。
	var tbs: Array[TextBox] = []
	tbs.append(tb)
	parent.text_boxes = tbs

	# ---- 3) $变量 求值回调（待接入 VariableSystem，此处用临时字典）----
	parent.variable_resolver = func(nm: String) -> Variant:
		return {"rank": 3, "player": "张三"}.get(nm)

	# ---- 4) 子积木（跟随父级位移；由子级的「child_follow」标签控制）----
	# 绑定是「ID 关系」而不是节点父子关系：场景树保持扁平，
	# 子积木的 position 用的是场景坐标（不再是相对父级的局部坐标）。
	var child := Block.new()
	child.width = 80.0
	child.height = 80.0
	child.position = parent.position + Vector2(0, 160)  # 父级下方（场景坐标）
	child.fill_color = UIStyle.FILL_HOVER
	child.border_color = UIStyle.BORDER
	add_child(child)                          # 与父级平级入树（不是父级的 Node 子节点）
	parent.bind_child(child)                  # 自动补上 child_follow 标签 → 父动子动

	parent.queue_redraw()
	print("父积木 id = ", parent.id, " | 子积木 id = ", child.id, " | 已注册总数 = ", BlockManager.count())
