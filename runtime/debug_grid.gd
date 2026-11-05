extends Control
## 调试图层：相机附近每格画一个四边形，顶点抬到该格的渲染高度。
## 用来确认"地面着色器"和"实体投影"用的是同一套坐标——两边错一格，肉眼立刻能看出来。

var atlas   # GridAtlas（不写类型：要跨脚本访问其成员）


func _draw() -> void:
	if atlas == null or not atlas.show_debug or atlas.runtime == null:
		return
	var runtime = atlas.runtime
	var map_size: Vector2i = runtime.map.grid_size
	var center: Vector2 = atlas.center_cell
	var radius: int = clampi(int(atlas.size.x / atlas.ppm * 0.22), 5, 12)
	var c: Vector2i = Vector2i(floori(center.x), floori(center.y))
	var col: Color = Color(0.05, 0.06, 0.08, 0.30)
	for y in range(c.y - radius, c.y + radius + 2):
		for x in range(c.x - radius, c.x + radius + 2):
			if x < 0 or y < 0 or x >= map_size.x or y >= map_size.y:
				continue
			var z: float = runtime.terrain_z(Vector2i(x, y))
			var pts: PackedVector2Array = PackedVector2Array([
				atlas.cell_to_screen(Vector2(x, y), z),
				atlas.cell_to_screen(Vector2(x + 1, y), z),
				atlas.cell_to_screen(Vector2(x + 1, y + 1), z),
				atlas.cell_to_screen(Vector2(x, y + 1), z),
				atlas.cell_to_screen(Vector2(x, y), z),
			])
			draw_polyline(pts, col, 1.0)
	var mid: Vector2 = atlas.size * 0.5
	draw_line(mid - Vector2(7.0, 0.0), mid + Vector2(7.0, 0.0), Color(0.90, 0.22, 0.18, 0.75), 1.0)
	draw_line(mid - Vector2(0.0, 7.0), mid + Vector2(0.0, 7.0), Color(0.90, 0.22, 0.18, 0.75), 1.0)
