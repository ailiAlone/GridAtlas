extends Node2D
## 覆盖层：画寻路结果、起终点标记、悬停格。只用 MapRuntime 的格子坐标，不碰渲染。
## 绘制单位是世界像素（1 格 = RUNTIME_SCRIPT.CELL_SIZE），跟着 World 的缩放一起放大缩小。

const RUNTIME_SCRIPT: GDScript = preload("res://example/map_runtime.gd")

var runtime
var path: Array[Vector2i] = []
var hover: Vector2i = Vector2i(-1, -1)
var start_cell: Vector2i = Vector2i(-1, -1)
var end_cell: Vector2i = Vector2i(-1, -1)


func set_path(new_path: Array[Vector2i], from: Vector2i, to: Vector2i) -> void:
	path = new_path
	start_cell = from
	end_cell = to
	queue_redraw()


func set_hover(cell: Vector2i) -> void:
	if cell == hover:
		return
	hover = cell
	queue_redraw()


func _draw() -> void:
	if runtime == null:
		return
	var cs: float = RUNTIME_SCRIPT.CELL_SIZE

	# 悬停格：细白框
	if hover.x >= 0:
		draw_rect(Rect2(Vector2(hover) * cs, Vector2(cs, cs)), Color(1, 1, 1, 0.75), false, 1.5)

	# 路径：先画深色描边再画亮线，压在任何底色上都看得清
	if path.size() >= 2:
		var points: PackedVector2Array = PackedVector2Array()
		for cell: Vector2i in path:
			points.append(runtime.cell_center(cell))
		draw_polyline(points, Color(0.05, 0.05, 0.06, 0.85), 5.0, true)
		draw_polyline(points, Color(1.0, 0.86, 0.25, 0.95), 2.4, true)

	# 起点/终点
	if start_cell.x >= 0:
		draw_circle(runtime.cell_center(start_cell), cs * 0.30, Color(0.30, 0.85, 0.45, 0.95))
		draw_arc(runtime.cell_center(start_cell), cs * 0.30, 0, TAU, 24, Color(0.05, 0.1, 0.05, 0.8), 2.0, true)
	if end_cell.x >= 0:
		draw_circle(runtime.cell_center(end_cell), cs * 0.30, Color(0.95, 0.35, 0.30, 0.95))
		draw_arc(runtime.cell_center(end_cell), cs * 0.30, 0, TAU, 24, Color(0.12, 0.03, 0.03, 0.8), 2.0, true)
