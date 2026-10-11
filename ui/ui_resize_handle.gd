# ui/ui_resize_handle.gd
# 「拖动调大小」把柄 —— 右下角的对角双箭头，复用 UIDragHandle 整套拖动逻辑，
# 仅把图标换成「↖ ↘」对角箭头，并叠加增量回调模式（继承自 set_move_callback）：
#   func _on_resize_inc(inc: Vector2) -> void  # 每次增量交给回调 → 我方把 size 加上增量
class_name UIResizeHandle
extends UIDragHandle

func _draw() -> void:
	var c: Color = Color.WHITE
	var cx := size.x * 0.5
	var cy := size.y * 0.5
	var a := size.x * 0.22
	var head_len := a * 1.35
	var half_w := a * 0.6
	# 右下箭头 ↘ 与 左上箭头 ↖，两枚对角相接，示意"沿对角线拉伸"
	_arrow_head(Vector2(cx + a, cy + a), Vector2(1, 1).normalized(), head_len, half_w, c)
	_arrow_head(Vector2(cx - a, cy - a), Vector2(-1, -1).normalized(), head_len, half_w, c)


# 画一枚实心箭头：尖端在 tip，开口朝「tip - d*len」方向（d 指向尖端）
func _arrow_head(tip: Vector2, d: Vector2, length: float, half_w: float, col: Color) -> void:
	var back := tip - d * length
	var perp := Vector2(-d.y, d.x)
	draw_colored_polygon(
		PackedVector2Array([tip, back + perp * half_w, back - perp * half_w]), col
	)