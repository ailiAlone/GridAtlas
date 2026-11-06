extends Control
## 游戏端使用示例：不经过编辑器，直接加载地图数据 + look 参数，
## 用同一个着色器画地表，用同一份数据做寻路。
##
## 操作：左键设起点/终点（自动重算路径）｜右键清除｜滚轮缩放｜中键拖动平移
## 运行：godot res://demos/example.tscn
## 截图：加 --shot（自动选一段路做演示，存到 %TEMP%/gridatlas_shots/example.png）

const MapSidecars = preload("res://data/map_sidecars.gd")
const MAP_PATH: String = "res://maps/first/first.tres"
const RUNTIME_SCRIPT: GDScript = preload("res://runtime/map_runtime.gd")
const MIN_ZOOM: float = 0.35
const MAX_ZOOM: float = 12.0

@onready var viewport_rect: Control = $"Viewport"
@onready var world: Node2D = $"Viewport/World"
@onready var terrain: ColorRect = $"Viewport/World/Terrain"
@onready var overlay: Node2D = $"Viewport/World/Overlay"
@onready var info_label: Label = $"HUD/Info"

var runtime
var start_cell: Vector2i = Vector2i(-1, -1)
var end_cell: Vector2i = Vector2i(-1, -1)
var hover_cell: Vector2i = Vector2i(-1, -1)
var path: Array[Vector2i] = []
var _panning: bool = false
var _time: float = 0.0


var _fitted: bool = false


func _ready() -> void:
	_load_map()
	if "--shot" in OS.get_cmdline_args():
		await get_tree().process_frame
		_fit_view()
		_demo_route()
		_shot_and_quit()
	else:
		_fit_view()
		resized.connect(_on_first_resize)


## 视口尺寸在 _ready 时可能还没定下来：第一次真正拿到尺寸后再取景
func _on_first_resize() -> void:
	if _fitted:
		resized.disconnect(_on_first_resize)
		return
	_fit_view()


## 水面动效：地形着色器本来就每帧绘制，推进 u_time 不额外收费
func _process(delta: float) -> void:
	if runtime == null:
		return
	_time += delta
	runtime.material.set_shader_parameter("u_time", _time)


func _load_map() -> void:
	var map: MapData = load(MAP_PATH) as MapData
	if map == null:
		push_error("找不到地图：" + MAP_PATH)
		return
	var look: RenderSettings = RenderSettings.new()
	var look_path: String = MapSidecars.look_path(MAP_PATH)
	if ResourceLoader.exists(look_path):
		var loaded: RenderSettings = load(look_path) as RenderSettings
		if loaded != null:
			look = loaded
	runtime = RUNTIME_SCRIPT.new()
	runtime.setup(map, look)
	terrain.material = runtime.material
	terrain.size = runtime.world_size()
	terrain.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	overlay.set("runtime", runtime)
	print("[示例] 已载入 %s (%d×%d)，世界尺寸 %.0f×%.0f" % [
		MAP_PATH.get_file(), map.grid_size.x, map.grid_size.y,
		runtime.world_size().x, runtime.world_size().y])
	_update_hud()


## 初始取景：整图铺满视口，并居中
func _fit_view() -> void:
	if runtime == null:
		return
	var view: Vector2 = viewport_rect.size
	var world_size: Vector2 = runtime.world_size()
	if view.x <= 0.0 or view.y <= 0.0:
		view = get_viewport_rect().size
	var zoom: float = minf(view.x / world_size.x, view.y / world_size.y)
	world.scale = Vector2(zoom, zoom)
	world.position = (view - world_size * zoom) * 0.5
	_fitted = true


# ---------- 输入 ----------

func _gui_input(event: InputEvent) -> void:
	if runtime == null:
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(mb.position, 1.15)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at(mb.position, 1.0 / 1.15)
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_click_cell(_cell_at(mb.position))
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_clear_route()
	elif event is InputEventMouseMotion:
		if _panning:
			world.position += (event as InputEventMouseMotion).relative
		else:
			var cell: Vector2i = _cell_at(event.position)
			if cell != hover_cell:
				hover_cell = cell
				overlay.call("set_hover", cell)


func _cell_at(local_pos: Vector2) -> Vector2i:
	# Viewport 本地坐标 → 世界坐标 → 格子
	var world_pos: Vector2 = (local_pos - world.position) / world.scale
	var cell: Vector2i = Vector2i((world_pos / RUNTIME_SCRIPT.CELL_SIZE).floor())
	if cell.x < 0 or cell.y < 0 or cell.x >= runtime.map.grid_size.x or cell.y >= runtime.map.grid_size.y:
		return Vector2i(-1, -1)
	return cell


func _click_cell(cell: Vector2i) -> void:
	if cell.x < 0:
		return
	if start_cell.x < 0:
		start_cell = cell
		end_cell = Vector2i(-1, -1)
		path = []
	elif end_cell.x < 0:
		end_cell = cell
		_recompute()
	else:
		start_cell = cell
		end_cell = Vector2i(-1, -1)
		path = []
	overlay.call("set_path", path, start_cell, end_cell)
	_update_hud()


func _recompute() -> void:
	if start_cell.x < 0 or end_cell.x < 0:
		path = []
		return
	path = runtime.find_path(start_cell, end_cell)


func _clear_route() -> void:
	start_cell = Vector2i(-1, -1)
	end_cell = Vector2i(-1, -1)
	path = []
	overlay.call("set_path", path, start_cell, end_cell)
	_update_hud()


func _zoom_at(local_pos: Vector2, factor: float) -> void:
	var old_scale: float = world.scale.x
	var new_scale: float = clampf(old_scale * factor, MIN_ZOOM, MAX_ZOOM)
	if is_equal_approx(new_scale, old_scale):
		return
	# 以鼠标位置为锚点缩放：锚点下的世界坐标保持不动
	var anchor: Vector2 = (local_pos - world.position) / old_scale
	world.scale = Vector2(new_scale, new_scale)
	world.position = local_pos - anchor * new_scale


# ---------- HUD ----------

func _update_hud() -> void:
	var lines: Array[String] = []
	lines.append("GridAtlas 游戏端示例 · %s" % MAP_PATH.get_file())
	lines.append("左键：设起点/终点　右键：清除　滚轮：缩放　中键拖动：平移")
	if start_cell.x >= 0 and end_cell.x >= 0:
		if path.is_empty():
			lines.append("起点 %s → 终点 %s：走不通" % [str(start_cell), str(end_cell)])
		else:
			var cost: float = runtime.path_cost(path)
			# 假设基础速度 1 格/代价秒，代价可直接换成时间
			lines.append("路径 %d 格，代价 %.1f（约 %.1f 秒）" % [path.size(), cost, cost])
	elif start_cell.x >= 0:
		lines.append("起点 %s，请点终点" % str(start_cell))
	else:
		lines.append("请点一个起点")
	info_label.text = "\n".join(lines)


# ---------- 截图模式（验证用） ----------

## 自动选一段路上的两点，演示寻路
func _demo_route() -> void:
	var road_cells: Array[Vector2i] = []
	for y in runtime.map.grid_size.y:
		for x in runtime.map.grid_size.x:
			var cell: Vector2i = Vector2i(x, y)
			if runtime.map.get_road(cell) != GridDefs.Road.NONE and runtime.is_walkable(cell):
				road_cells.append(cell)
	if road_cells.size() < 2:
		return
	start_cell = road_cells[0]
	end_cell = road_cells[road_cells.size() - 1]
	_recompute()
	overlay.call("set_path", path, start_cell, end_cell)
	_update_hud()


func _shot_and_quit() -> void:
	for i in 8:
		await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	var dir: String = OS.get_environment("TEMP").replace("\\", "/") + "/gridatlas_shots"
	DirAccess.make_dir_recursive_absolute(dir)
	var path_out: String = dir + "/example.png"
	if FileAccess.file_exists(path_out):
		DirAccess.remove_absolute(path_out)   # 旧图被看图工具占用时可能写不进去
	var err: Error = img.save_png(path_out)
	if err != OK:
		path_out = dir + "/example_%d.png" % Time.get_ticks_msec()
		err = img.save_png(path_out)
	print("[示例截图] %s (%s)" % [path_out, error_string(err)])
	get_tree().quit()
