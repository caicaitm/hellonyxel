# ui/ui_resize_handle.gd
# 「拖动调大小」把柄 —— 右下角把柄，复用 UIDragHandle 整套拖动逻辑（含增量回调模式
# set_move_callback：拖动不再改 target 位置，而是每帧把鼠标增量交给回调）。
# ★ 图标与 UIDragResizeHandle（长文本页等处的调整把柄）完全一致：4 枚对角箭头
#   （↖↗↙↘，箭头顶点距中心 9px、半径 4.5、白色），示意「沿任一对角线拉伸」。
#   悬停光标也与之一致（CURSOR_FDIAGSIZE）。
class_name UIResizeHandle
extends UIDragHandle

## 箭头颜色直接用父类常量 ARROW_COLOR（★子类重复声明会报「member already exists in parent class」）。


## 悬停/移开时切换对角缩放光标（UIDragHandle._ready 已把信号连到 _on_mouse_entered/_exited，
## 覆盖后走子类版本，先 super 保留悬停变色，再设光标）。
func _on_mouse_entered() -> void:
	super()
	Input.set_default_cursor_shape(Input.CursorShape.CURSOR_FDIAGSIZE)


func _on_mouse_exited() -> void:
	super()
	Input.set_default_cursor_shape(Input.CursorShape.CURSOR_ARROW)


func _draw() -> void:
	var c: Color = ARROW_COLOR
	var cx: float = size.x * 0.5
	var cy: float = size.y * 0.5
	var s: float = 4.5    # 箭头半径（与 UIDragResizeHandle 一致）

	## 对角线 ↙→↗（从左上到右下）：两个箭头分别指↖和↘
	_draw_diagonal_arrow(cx, cy, -1.0, -1.0, s, c)   # ↖ 箭头（左上端）
	_draw_diagonal_arrow(cx, cy,  1.0,  1.0, s, c)   # ↘ 箭头（右下端）

	## 对角线 ↘→↙（从右上到左下）：两个箭头分别指↗和↙
	_draw_diagonal_arrow(cx, cy, -1.0,  1.0, s, c)   # ↗ 箭头（右上端）
	_draw_diagonal_arrow(cx, cy,  1.0, -1.0, s, c)   # ↙ 箭头（左下端）


## 与 UIDragResizeHandle._draw_diagonal_arrow 逐字一致：箭头顶点在距中心 9px 处，沿 (dir_x, dir_y) 方向延伸
func _draw_diagonal_arrow(
		cx: float, cy: float,
		dir_x: float, dir_y: float,
		s: float,
		c: Color
) -> void:
	var tip_x: float = cx + dir_x * 9.0
	var tip_y: float = cy + dir_y * 9.0
	## 箭头基底垂直于方向的偏移
	var perp_x: float = -dir_y
	var perp_y:  float =  dir_x
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(tip_x + dir_x * s,        tip_y + dir_y * s),
			Vector2(tip_x + perp_x * s * 0.5, tip_y + perp_y * s * 0.5),
			Vector2(tip_x - perp_x * s * 0.5, tip_y - perp_y * s * 0.5),
		]), c
	)
