extends Control
## GridAtlas 编辑器主脚本：持有 MapData，把工具面板的笔刷/地图变化接到网格视图。


@onready var tools: VBoxContainer = $HBoxContainer/VBoxContainer/Panel2/ScrollContainer/GridTools
@onready var minimap: MapMinimap = $HBoxContainer/VBoxContainer/Panel/Minimap
@onready var grid_view: GridView = $HBoxContainer/VBoxContainer2/Panel/ScrollContainer/GridView
@onready var coord_label: Label = $HBoxContainer/VBoxContainer2/Panel2/HBoxContainer/Label

var map: MapData  # 唯一持有者：所有使用方（tools/grid_view/minimap）都从这里拿引用


func _ready() -> void:
	map = MapData.create(Vector2i(64, 64))
	tools.set_map(map)
	minimap.set_map(map)
	grid_view.set_map(map)
	tools.brush_changed.connect(grid_view.set_brush)
	tools.elevation_view_changed.connect(grid_view.set_elevation_mode)
	tools.brush_size_changed.connect(grid_view.set_brush_size)
	tools.rect_mode_changed.connect(grid_view.set_rect_mode)
	tools.map_resized.connect(_on_map_resized)
	tools.map_loaded.connect(_on_map_loaded)
	grid_view.area_painted.connect(_on_area_painted)
	grid_view.cell_hovered.connect(_on_cell_hovered)
	print("[地图] 新建地图 %d×%d，全图草地/高程1（未保存）" % [map.grid_size.x, map.grid_size.y])


## 涂画/矩形填充统一入口：把笔刷值写到区域内每个格子（越界部分跳过）
func _on_area_painted(area: Rect2i, erase: bool) -> void:
	var layer: StringName = tools.brush_layer
	# 陆地/高程没有 NONE：擦除=恢复默认（草地/1）；水域/道路/流向擦除=0（NONE）
	var value: int = tools.brush_value
	if erase:
		if layer == &"land":
			value = GridDefs.Land.GRASS
		elif layer == &"elevation":
			value = 1
		else:
			value = 0
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			var cell: Vector2i = Vector2i(x, y)
			if not map.in_bounds(cell):
				continue
			if layer == &"land":
				map.set_land(cell, value)
				if not erase:
					# 陆水互斥：画陆地清掉水域及其流向；擦除只是恢复草地，不动水面
					map.set_water(cell, GridDefs.Water.NONE)
					map.set_flow(cell, GridDefs.Flow.NONE)
			elif layer == &"water":
				map.set_water(cell, value)
				if value == GridDefs.Water.NONE:
					map.set_flow(cell, GridDefs.Flow.NONE)  # 水没了，流向一并清掉
				# 陆地保留在水下：擦除水后陆地重新露出
			elif layer == &"road":
				map.set_road(cell, value)
			elif layer == &"flow":
				map.set_flow(cell, value)
			elif layer == &"elevation":
				map.set_elevation(cell, value)
	tools.mark_dirty()
	grid_view.queue_redraw()
	minimap.queue_redraw()
	if erase:
		print("[绘制] (%d,%d) %d×%d 擦除 %s -> %s" % [area.position.x, area.position.y, area.size.x, area.size.y, GridDefs.LAYER_NAMES.get(layer, layer), tools.value_name(layer, value)])
	else:
		print("[绘制] (%d,%d) %d×%d %s = %s" % [area.position.x, area.position.y, area.size.x, area.size.y, GridDefs.LAYER_NAMES.get(layer, layer), tools.value_name(layer, tools.brush_value)])


func _on_cell_hovered(cell: Vector2i) -> void:
	if cell.x >= 0:
		coord_label.text = "当前坐标(%d,%d)" % [cell.x, cell.y]
	else:
		coord_label.text = "当前坐标(-,-)"


## 尺寸变化：同一个 MapData 对象原地 resize，刷新显示即可
func _on_map_resized() -> void:
	grid_view.refresh()
	minimap.queue_redraw()


## 打开地图：tools 把新 MapData 随信号送来，main 是唯一持有者，负责回灌给所有使用方
func _on_map_loaded(data: MapData) -> void:
	map = data
	tools.set_map(map)
	grid_view.set_map(map)
	minimap.set_map(map)
