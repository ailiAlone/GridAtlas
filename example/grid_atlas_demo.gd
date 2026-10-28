extends Control
## GridAtlas 固定 45° 游戏视角演示。
##
## 相机：从地图东南角方向看向西北（yaw 135°），俯角 45°，跟随玩家但不旋转。
## 实体：角色与资源立牌都用 GridAtlas 的投影定位；被地形挡住时
##       角色半透明（u_fade=0.38），资源立牌完全消失（u_fade=0）。
##
## 操作：WASD 走格（按屏幕方向）｜滚轮缩放｜右键拖动平移｜G 网格｜R 回到角色
## 截图：--shot [--shot-yaw=0] [--shot-debug] [--shot-ppm=42] [--map=res://...]

const MAP_PATH: String = "res://GridData/maps/first.tres"
const RUNTIME_SCRIPT: GDScript = preload("res://example/map_runtime.gd")
const CARD_SCRIPT: GDScript = preload("res://example/actor_card.gd")
const DemoUnit = preload("res://example/demo_unit.gd")
const PropsData = preload("res://GridData/props_data.gd")
const MOVE_SPEED: float = 6.0
const CAMERA_AHEAD: float = 1.5

@onready var atlas = $"Map"
@onready var info: Label = $"HUD/Info"

var runtime
var props
var asset_defs: Dictionary = {}   # StringName -> StaticAssetDef（游戏端也读同一份资源目录）
var prop_source: String = "无"
var player
var player_cell: Vector2i = Vector2i(32, 32)
var player_pos: Vector2 = Vector2(32.5, 32.5)
var player_z: float = 0.0

var start_zoom: float = 42.0
var moving: bool = false
var from_pos: Vector2 = Vector2.ZERO
var to_pos: Vector2 = Vector2.ZERO
var from_z: float = 0.0
var to_z: float = 0.0
var move_t: float = 0.0

var _panning: bool = false
var _time: float = 0.0
var _hud_t: float = 0.0


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_args()
	var shot: bool = "--shot" in args
	var shot_debug: bool = "--shot-debug" in args
	var map_path: String = MAP_PATH
	var forced_cell: Vector2i = Vector2i(-1, -1)
	for arg: String in args:
		if arg.begins_with("--shot-yaw="):
			atlas.yaw = deg_to_rad(arg.trim_prefix("--shot-yaw=").to_float())
		elif arg.begins_with("--shot-ppm="):
			start_zoom = arg.trim_prefix("--shot-ppm=").to_float()
		elif arg.begins_with("--shot-cell="):
			var parts: PackedStringArray = arg.trim_prefix("--shot-cell=").split(",")
			if parts.size() == 2:
				forced_cell = Vector2i(int(parts[0]), int(parts[1]))
		elif arg.begins_with("--map="):
			map_path = arg.trim_prefix("--map=")
	_load_map(map_path)
	await get_tree().process_frame
	_place_viewpoint(shot_debug, forced_cell)
	_spawn_props()
	_update_hud()
	if "--bench" in args:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		await get_tree().create_timer(0.5).timeout
		var t0: int = Time.get_ticks_usec()
		for i in 180:
			await get_tree().process_frame
		var frame_ms: float = float(Time.get_ticks_usec() - t0) / 180.0 / 1000.0
		print("[Bench] %s %dx%d  ppm %.0f  →  %.2f ms/帧 (%.0f fps)" % [
			map_path.get_file(), int(get_viewport_rect().size.x), int(get_viewport_rect().size.y),
			atlas.ppm, frame_ms, 1000.0 / frame_ms])
		get_tree().quit()
	if shot:
		for i in 8:
			await get_tree().process_frame
		_save_shot()
		get_tree().quit()


func _load_map(path: String) -> void:
	var map: MapData = load(path) as MapData
	if map == null:
		push_error("找不到地图：" + path)
		return
	_load_asset_defs()
	var look: RenderSettings = RenderSettings.new()
	var look_path: String = path.get_basename() + ".look.tres"
	if ResourceLoader.exists(look_path):
		var loaded: RenderSettings = load(look_path) as RenderSettings
		if loaded != null:
			look = loaded
	runtime = RUNTIME_SCRIPT.new()
	runtime.setup(map, look)
	props = _load_props(path)
	var blocked: int = runtime.apply_props(props)
	atlas.setup(runtime)
	print("[GridAtlas] %s %d×%d → yaw %.0f° pitch %.0f° ppm %.0f" % [
		path.get_file(), map.grid_size.x, map.grid_size.y,
		rad_to_deg(atlas.yaw), rad_to_deg(atlas.pitch), atlas.ppm])
	print("[GridAtlas] 物件 %d 个，阻挡 %d 格" % [props.count(), blocked])


## 资源目录：编辑器导入页保存的定义，游戏端按同一份数据解析占地/阻挡
func _load_asset_defs() -> void:
	StaticAssetStore.clear_texture_cache()
	asset_defs = StaticAssetStore.load_def_map()
	print("[GridAtlas] 资源定义 %d 个" % asset_defs.size())


## 物件边车：与地图同名；缺失时返回空层（不再生成随机林）
func _load_props(map_path: String):
	var data = PropsData.new()
	data.set_asset_defs(asset_defs)
	var side: String = PropsData.sidecar_path(map_path)
	if not ResourceLoader.exists(side):
		return data
	var loaded = load(side)
	if loaded == null or loaded.get_script() != PropsData:
		push_warning("物件边车不是有效资源: " + side)
		return data
	loaded.set_asset_defs(asset_defs)
	if loaded.sanitize():
		print("[GridAtlas] 旧边车内置实例已清理: " + side)
	var dropped: int = loaded.drop_out_of_bounds(runtime.map.grid_size)
	if dropped > 0:
		push_warning("物件边车有 %d 个越界物件已丢弃: %s" % [dropped, side])
	print("[GridAtlas] 载入物件边车: %s (%d 个)" % [side, loaded.count()])
	return loaded



# ---------- 取景与实体 ----------

func _place_viewpoint(debug: bool, forced: Vector2i = Vector2i(-1, -1)) -> void:
	player_cell = forced if (forced.x >= 0 and forced.y >= 0) else _find_viewpoint()
	player_pos = Vector2(player_cell) + Vector2(0.5, 0.5)
	player_z = runtime.terrain_z(player_cell)
	atlas.set_debug(debug)
	atlas.set_zoom(start_zoom)
	atlas.set_center_cell(player_pos + atlas.forward_axis() * CAMERA_AHEAD)
	player = CARD_SCRIPT.new()
	player.setup(atlas, 0, DemoUnit.SIZE, 0.38, DemoUnit.texture())
	atlas.actors.add_child(player)
	player.place(player_pos, player_z)
	print("[GridAtlas] 玩家格 %s 高程 %.1f" % [str(player_cell), runtime.height_at(player_cell)])


## 选一处"离岸 4~7 格 + 附近有高低落差"的可行走格：
## 画面里同时有海岸、台地边缘和资源立牌，而不是一整屏同高的草甸。
## 纯陆地地图没有海岸候选时，从中部向外找第一个空着的可行走格。
func _find_viewpoint() -> Vector2i:
	var best: Vector2i = Vector2i(-1, -1)
	var best_score: float = -1e20
	for y in range(22, runtime.map.grid_size.y - 20):
		for x in range(22, runtime.map.grid_size.x - 20):
			var c: Vector2i = Vector2i(x, y)
			if not runtime.is_walkable(c) or not _prop_free(c):
				continue
			if runtime.water_at(c) != GridDefs.Water.NONE:
				continue
			if runtime.map.get_road(c) != GridDefs.Road.NONE:
				continue
			var h0: float = runtime.height_at(c)
			var near: float = 99.0
			var relief: float = 0.0
			for oy in range(-12, 13):
				for ox in range(-12, 13):
					var n: Vector2i = c + Vector2i(ox, oy)
					if not runtime.map.in_bounds(n):
						continue
					var d: float = sqrt(float(ox * ox + oy * oy))
					var wgt: float = maxf(0.0, 1.0 - d / 13.0)
					if runtime.water_at(n) != GridDefs.Water.NONE:
						near = minf(near, d)
					relief += absf(runtime.height_at(n) - h0) * wgt
			if near < 3.0 or near > 7.0:
				continue
			var score: float = -absf(near - 5.0) * 3.0 + relief * 1.2 + h0 * 0.6
			if score > best_score:
				best_score = score
				best = c
	if best.x >= 0:
		return best
	var center: Vector2i = Vector2i(int(runtime.map.grid_size.x * 0.5), int(runtime.map.grid_size.y * 0.5))
	var limit: int = maxi(runtime.map.grid_size.x, runtime.map.grid_size.y)
	for radius in range(0, limit):
		for oy in range(-radius, radius + 1):
			for ox in range(-radius, radius + 1):
				var c2: Vector2i = center + Vector2i(ox, oy)
				if not runtime.map.in_bounds(c2):
					continue
				if runtime.water_at(c2) == GridDefs.Water.NONE and runtime.is_walkable(c2) and _prop_free(c2):
					return c2
	return center


## 该格是否被某个物件的占地覆盖（灌木不挡路，但玩家不该站在里面）
func _prop_free(cell: Vector2i) -> bool:
	if props == null:
		return true
	for i in props.count():
		if props.footprint_at(i).has_point(cell):
			return false
	return true


## 有物件边车就用边车（占地范围/类别/大小/遮挡全部照数据）；没有边车就显示空地图。
func _spawn_props() -> void:
	if props == null or props.count() == 0:
		prop_source = "无物件"
		return
	prop_source = "边车 %d 个" % props.count()
	for i in props.count():
		_spawn_prop(i)
	print("[GridAtlas] 立牌：边车物件 %d 个" % props.count())


## 从物件数据生成一张立牌：脚底用占地中心，尺寸吃实例缩放，遮挡/阻挡走目录定义
func _spawn_prop(i: int) -> void:
	var fp: Rect2i = props.footprint_at(i)
	var center: Vector2 = Vector2(props.cell_at(i)) + Vector2(fp.size) * 0.5
	var ground: Vector2i = Vector2i(floori(center.x), floori(center.y))
	var def: StaticAssetDef = props.asset(props.asset_id_at(i))
	if def == null:
		return
	var vertical: bool = props.rotation_at(i) == 1
	var card = CARD_SCRIPT.new()
	var tex: Texture2D = StaticAssetStore.texture_for(def)
	if tex != null:
		card.setup_sprite(atlas, def.art_size, 0.0, tex, def.art_lift, vertical)
		var offset: Vector2 = def.art_offset
		if vertical:
			offset.x = -offset.x
		card.art_offset = offset
	else:
		card.setup(atlas, 4, def.art_size, 0.0)
	atlas.actors.add_child(card)
	card.place(center, runtime.terrain_z(ground))


# ---------- 输入 ----------

func _gui_input(event: InputEvent) -> void:
	if runtime == null:
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			atlas.zoom_at(mb.position, 1.12)
			_update_hud()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			atlas.zoom_at(mb.position, 1.0 / 1.12)
			_update_hud()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE or mb.button_index == MOUSE_BUTTON_RIGHT:
			_panning = mb.pressed
	elif event is InputEventMouseMotion and _panning:
		atlas.pan((event as InputEventMouseMotion).relative)


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var ke: InputEventKey = event as InputEventKey
		if not ke.pressed or ke.echo:
			return
		if ke.keycode == KEY_G:
			atlas.set_debug(not atlas.show_debug)
		elif ke.keycode == KEY_R:
			atlas.set_center_cell(atlas.clamped_center(player_pos + atlas.forward_axis() * CAMERA_AHEAD))


func _process(delta: float) -> void:
	if runtime == null:
		return
	_time += delta
	runtime.material.set_shader_parameter("u_time", _time)
	_step_move(delta)
	var target: Vector2 = atlas.clamped_center(player_pos + atlas.forward_axis() * CAMERA_AHEAD)
	atlas.set_center_cell(atlas.center_cell.lerp(target, 1.0 - exp(-6.0 * delta)))
	_hud_t += delta
	if _hud_t > 0.2:
		_hud_t = 0.0
		_update_hud()


## 走格：WASD 是屏幕方向，换算成格方向（45° 下 W 正好是地图西北对角）
func _step_move(delta: float) -> void:
	if moving:
		move_t = minf(move_t + delta * MOVE_SPEED / maxf(from_pos.distance_to(to_pos), 0.001), 1.0)
		var k: float = smoothstep(0.0, 1.0, move_t)
		player_pos = from_pos.lerp(to_pos, k)
		player_z = lerpf(from_z, to_z, k)
		player.place(player_pos, player_z)
		if move_t >= 1.0:
			moving = false
			player_cell = Vector2i(floori(player_pos.x), floori(player_pos.y))
		return
	var iv: Vector2 = Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	if iv.length_squared() < 0.1:
		return
	var dir: Vector2 = (atlas.right_axis() * iv.x + atlas.forward_axis() * (-iv.y)).normalized()
	var step: Vector2i = Vector2i(roundi(dir.x), roundi(dir.y))
	if step == Vector2i.ZERO:
		return
	var next: Vector2i = player_cell + step
	if not runtime.is_walkable(next):
		return
	if runtime.water_at(next) != GridDefs.Water.NONE:   # 演示只走陆地；涉水规则留给游戏自己定
		return
	from_pos = player_pos
	to_pos = Vector2(next) + Vector2(0.5, 0.5)
	from_z = player_z
	to_z = runtime.terrain_z(next)
	moving = true
	move_t = 0.0


# ---------- HUD / 截图 ----------

func _update_hud() -> void:
	var lines: Array[String] = []
	lines.append("GridAtlas · 固定 %.0f° 俯视 / 相机方位 %.0f° · %s" % [
		rad_to_deg(atlas.pitch), rad_to_deg(atlas.yaw), runtime.map.resource_path.get_file()])
	lines.append("WASD 走格　滚轮缩放　右键拖动　G 网格　R 回到角色")
	lines.append("格 %s · 高程 %.1f · 缩放 %.0f px/格" % [
		str(player_cell), runtime.height_at(player_cell), atlas.ppm])
	lines.append("物件：%s" % prop_source)
	lines.append("山挡住角色 → 半透明；挡住资源立牌 → 消失（G 看格线）")
	info.text = "\n".join(lines)


func _save_shot() -> void:
	var deg: int = int(round(rad_to_deg(atlas.yaw)))
	var name: String = "grid_atlas_yaw%d" % deg
	if atlas.show_debug:
		name += "_debug"
	if not is_equal_approx(start_zoom, 42.0):
		name += "_z%d" % int(round(start_zoom))
	print("[GridAtlas] center=%s player=%s z=%.2f screen=%s view=%s" % [
		str(atlas.center_cell), str(player_pos), player_z,
		str(atlas.cell_to_screen(player_pos, player_z)), str(atlas.size)])
	var img: Image = get_viewport().get_texture().get_image()
	var dir: String = OS.get_environment("TEMP").replace("\\", "/") + "/gridatlas_shots"
	DirAccess.make_dir_recursive_absolute(dir)
	var out: String = dir + "/" + name + ".png"
	if FileAccess.file_exists(out):
		DirAccess.remove_absolute(out)
	var err: Error = img.save_png(out)
	if err != OK:
		out = dir + "/%s_%d.png" % [name, Time.get_ticks_msec()]
		err = img.save_png(out)
	print("[GridAtlas 截图] %s (%s)" % [out, error_string(err)])
