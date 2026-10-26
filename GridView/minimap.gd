class_name MapMinimap
extends Control
## 小地图：按最长边等比缩放完整显示整张地图（CONTAIN，允许留白、无溢出）。
## 不可交互（mouse_filter = Ignore），只做全局预览；每格缩到 s 像素，
## 格子太小(<4px)时省略道路细节，流向/高程一律省略。

var map: MapData


func _ready() -> void:
	resized.connect(queue_redraw)


func set_map(data: MapData) -> void:
	map = data
	queue_redraw()


func _draw() -> void:
	if map == null:
		return
	var content: Vector2 = Vector2(map.grid_size)
	if content.x <= 0.0 or content.y <= 0.0:
		return
	var s: float = minf(size.x / content.x, size.y / content.y)
	var offset: Vector2 = (size - content * s) / 2.0
	draw_rect(Rect2(offset, content * s), Color(0, 0, 0, 0.4))
	for y in map.grid_size.y:
		for x in map.grid_size.x:
			var cell: Vector2i = Vector2i(x, y)
			var rect: Rect2 = Rect2(offset + Vector2(cell) * s, Vector2(s, s))
			var color: Color = GridDefs.LAND_COLORS.get(map.get_land(cell), Color(0.16, 0.16, 0.16, 1))
			var water: int = map.get_water(cell)
			if water != GridDefs.Water.NONE:
				color = GridDefs.WATER_COLORS.get(water, color)
			draw_rect(rect, color)
			if s >= 4.0:
				var road: int = map.get_road(cell)
				if road != GridDefs.Road.NONE:
					draw_rect(rect.grow(-s * 0.25), GridDefs.ROAD_COLORS.get(road, Color.WHITE))
	draw_rect(Rect2(offset, content * s), Color(0, 0, 0, 0.6), false, 1.0)
