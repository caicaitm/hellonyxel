# level_blocked_overlay.gd
# 「被阻挡」提示层（画在关卡舞台之上、深色背景之外的积木上）。
#
# 关卡页面用自己的深色背景作为「页面范围」：落在背景矩形之外的积木（被摄像头平移甩出去的）
# 不再正常显示，而是本层给它压暗 + 橙色描边，表示"这块积木被挡在页面外"。
# 本层是 LevelPage 的兄弟节点、位于 Stage 之后 → 绘制顺序在积木之上，不会被积木盖住。
class_name LevelBlockedOverlay
extends Control

const DIM: Color = Color(0.02, 0.03, 0.06, 0.66)   # 压暗：表示不在这个页面范围内
const EDGE: Color = Color(1.0, 0.55, 0.20, 0.95)   # 橙色描边：一眼看出是"被挡住"

var targets: Array = []   # 需要画提示的积木（Block）


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_targets(list: Array) -> void:
	targets = list
	queue_redraw()


func _draw() -> void:
	for b in targets:
		if b == null or not is_instance_valid(b):
			continue
		# b.position 是舞台局部坐标 → 加舞台平移量（= 本层所在的页面坐标）再画
		var anchor: Node2D = b as Node2D
		var stage_offset := Vector2.ZERO
		if anchor != null and anchor.get_parent() != null:
			var st: Node2D = anchor.get_parent()
			if st is Node2D:
				stage_offset = st.position
		var half := Vector2(b.width * 0.5, b.height * 0.5)
		var r := Rect2(b.position + stage_offset - half, Vector2(b.width, b.height)).grow(2.0)
		draw_rect(r, DIM, true)
		draw_rect(r, EDGE, false, 2.0)
