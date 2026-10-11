# 强制显示边框覆盖层（调试用）。
#
# 由 Debug 单例按需创建并挂到当前场景（桌面）下。
# 设计目标（解决旧实现“边框被裁切/被镂空洞穿透”的根因）：
#   · 它是一个独立的 Node2D，z_index 设到远高于任何积木（页面覆盖=33、页面边框=90），
#     因此绘制顺序在所有积木（含其 cutout 打洞子画布）之上 → 边框不会被页面覆盖/边框的
#     镂空洞（MUL 乘法混合）穿透，也不会被更高 display_layer 的积木盖住。
#   · 遍历场景内「block」组的全部积木，无视任何标签控制，一律画一圈高亮边框
#     （带 border 标签的积木用自身边框色/宽；其余用统一亮黄 2px），用于排查布局。
#   · 每帧 queue_redraw（Debug.force_border 为真时），让拖动/重排后的边框即时跟随。
#
# 注意：本覆盖层在「世界坐标系」绘制（场景根在原点，世界坐标==本地坐标），
#   跟随桌面默认相机（无缩放/平移）精确对齐；若关卡页面相机缩放/平移则会有偏差，
#   但那只是调试叠层，不影响实际积木。
extends Node2D

const COLOR := Color(1.0, 1.0, 0.0, 1.0)   # 统一高亮色（无 border 标签的积木）
const WIDTH := 2.0

func _ready() -> void:
	z_as_relative = false      # 绝对层级，不被父节点 z 影响
	z_index = 1000             # 高于任何积木（页面覆盖=33、边框=90），低于 UI CanvasLayer(100)

func _process(_dt: float) -> void:
	if Debug.force_border:
		queue_redraw()

func _draw() -> void:
	if not Debug.force_border:
		return
	var tree := get_tree()
	if tree == null:
		return
	for b in tree.get_nodes_in_group("block"):
		if is_instance_valid(b) and b is Block and (BlockTags.SHOW in b.tags):
			var half := Vector2(b.width * 0.5, b.height * 0.5)
			var rect := Rect2(b.global_position - half, Vector2(b.width, b.height))
			var col := COLOR
			var w := WIDTH
			if BlockTags.BORDER in b.tags:
				col = b.border_color
				w = b.border_width
			draw_rect(rect, col, false, w)
