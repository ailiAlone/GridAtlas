extends RefCounted

const BridgesData = preload("res://GridData/bridges_data.gd")
## 游戏端地图运行时：把 MapData + RenderSettings 变成两样东西
##   1) 一套直接喂给地表着色器的纹理与材质（外观）
##   2) 一套玩法查询：可通行 / 移动代价 / 高程 / 水域 / 寻路（玩法）
## 工具（GamePreview）和游戏共用同一份 .tres 与同一份 look 参数，
## 所以地图外观和玩法规则不会各说各话。
##
## 用法：
##   var rt: RefCounted = preload("res://example/map_runtime.gd").new()
##   rt.setup(map, look)
##   terrain.material = rt.material
##   rt.find_path(from_cell, to_cell)

const SHADER_PATH: String = "res://RenderView/terrain.gdshader"
const NOISE_SIZE: int = 256
const COLOR_COUNT: int = 15
const ELEV_BLUR: Array[int] = [1, 4, 6, 4, 1]
const ELEV_SMOOTH_MAX: float = 32.0
const CELL_SIZE: float = 16.0   # 世界像素/格（和工具画布一致，实体与点击都用它换算）

# 与 RenderSettings 的属性一一对应；照抄工具里的清单，外观才不会漂移
const SCALAR_UNIFORMS: Array[StringName] = [
	&"texture_strength", &"texture_frequency", &"grain", &"biome", &"bump",
	&"band_hard", &"band_soft", &"edge_jitter", &"coast_warp",
	&"crease_width", &"crease_dark", &"relief",
	&"tide_frequency", &"tide_amplitude",
	&"ripple_frequency", &"ripple_speed", &"ripple_strength", &"flow_speed",
	&"foam_width", &"foam_strength",
	&"road_width", &"road_softness", &"road_texture", &"road_round", &"road_bend",
	&"elevation_bright", &"elevation_shadow", &"elevation_rim", &"elevation_shadow_width",
	&"rock_slope_low", &"rock_slope_high", &"snow_line_ratio", &"snow_line_min",
	&"light_azimuth", &"light_elevation",
	&"height_scale",
]

# ---------- 移动代价（越小越快，0 = 不可通行） ----------
# 数值是"每格耗时"的相对值，游戏里乘以一个基础速度即可换算成秒

const LAND_COST: Dictionary = {
	GridDefs.Land.GRASS: 1.0,
	GridDefs.Land.SAND: 1.15,
	GridDefs.Land.WASTELAND: 1.3,
	GridDefs.Land.SNOW: 1.4,
	GridDefs.Land.SWAMP: 2.0,
	GridDefs.Land.ICE: 0.8,
}
const ROAD_COST: Dictionary = {
	GridDefs.Road.DIRT: 0.60,
	GridDefs.Road.GRAVEL: 0.75,
	GridDefs.Road.STONE_BRICK: 0.50,
}
const SHALLOW_WATER_COST: float = 3.0   # 涉水：很慢但能过
const DEEP_WATER_COST: float = 0.0      # 深水：不可通行
const SLOPE_COST: float = 0.03          # 每高一级的额外代价

var map: MapData
var look: RenderSettings
var material: ShaderMaterial
var astar: AStarGrid2D

var data_img: Image
var elev_img: Image
var smooth_img: Image
var mountain_img: Image
var prop_ground_img: Image             # 树下草垫遮罩：R=树根附近地表草化强度
var data_texture: ImageTexture
var elev_texture: ImageTexture
var smooth_texture: ImageTexture
var mountain_texture: ImageTexture
var prop_ground_texture: ImageTexture

var _costs: PackedFloat32Array = PackedFloat32Array()
var _bridge_cells: PackedByteArray = PackedByteArray()
var _bridge_z: PackedFloat32Array = PackedFloat32Array()
var _smooth: PackedByteArray = PackedByteArray()   # 平滑高程（级 × 255 / 32），和着色器同一张场
var _smooth_tmp: PackedFloat32Array = PackedFloat32Array()  # 区域平滑的横向趟缓存
var _heights: PackedInt32Array = PackedInt32Array()  # 基础高程 + 程序化山体（单位=存档单位）
var _height_max: float = 1.0                       # 合成高程最高值（级）
var _noise_seed: int = -1


## 地图世界尺寸（像素），用于摆放地形与相机取景
func world_size() -> Vector2:
	return Vector2(map.grid_size) * CELL_SIZE


# ---------- 初始化 ----------

## with_gameplay=false：只建地表外观（45° 预览不需要 A* / 通行代价），省掉整图寻路格。
func setup(data: MapData, look_settings: RenderSettings, with_gameplay: bool = true) -> void:
	map = data
	look = look_settings if look_settings != null else RenderSettings.new()
	map.ensure_precision()   # 旧存档（整数高程）在这里统一迁移，和工具一致
	map.ensure_water_sand()  # 旧存档的“水下草地”统一迁移为沙地河床
	map.ensure_mountain()    # 旧存档没有山体遮罩：补 0 数组
	# 山体高度由 footprint 程序化生成；基础高程仍来自 map.elevation
	_heights = MountainGenerator.build_heights(map)
	_height_max = _heights_max_level()
	_build_material()
	_build_textures()
	if with_gameplay:
		_build_gameplay()
	else:
		astar = null
		_costs = PackedFloat32Array()


func _build_material() -> void:
	material = ShaderMaterial.new()
	material.shader = load(SHADER_PATH) as Shader
	for prop: StringName in SCALAR_UNIFORMS:
		material.set_shader_parameter("u_" + String(prop), look.get(prop))


func _build_textures() -> void:
	var w: int = map.grid_size.x
	var h: int = map.grid_size.y

	# 每格一像素：R=陆地 G=水域 B=道路 A=流向
	data_img = Image.create(w, h, false, Image.FORMAT_RGBA8)
	elev_img = Image.create(w, h, false, Image.FORMAT_R8)
	mountain_img = Image.create(w, h, false, Image.FORMAT_R8)
	var mask_scale: int = clampi(int(floor(2048.0 / float(maxi(w, h)))), 1, 4)
	prop_ground_img = Image.create(w * mask_scale, h * mask_scale, false, Image.FORMAT_R8)
	prop_ground_img.fill(Color(0.0, 0.0, 0.0, 1.0))
	for y in h:
		for x in w:
			var i: int = y * w + x
			data_img.set_pixel(x, y, Color8(map.land[i], map.water[i], map.road[i], map.flow[i]))
			elev_img.set_pixel(x, y, Color8(clampi(_heights[i], 0, 255), 0, 0, 255))
			mountain_img.set_pixel(x, y, Color8(255 if map.mountain[i] > 0 else 0, 0, 0, 255))

	# 平滑高程：5 点可分离模糊，斜角几何与山体阴影共用（与区域重建同一算法）
	_smooth_tmp.resize(w * h)
	var tmp: PackedFloat32Array = _smooth_tmp
	for y in h:
		var row: int = y * w
		for x in w:
			var acc: float = 0.0
			for k in 5:
				var xx: int = clampi(x + k - 2, 0, w - 1)
				acc += float(_heights[row + xx]) * ELEV_BLUR[k]
			tmp[row + x] = acc * 0.0625
	var smooth_bytes: PackedByteArray = PackedByteArray()
	smooth_bytes.resize(w * h)
	var unit: float = float(map.elev_unit)
	var scale: float = 255.0 / ELEV_SMOOTH_MAX
	for y in h:
		var row: int = y * w
		for x in w:
			var acc: float = 0.0
			for k in 5:
				var yy: int = clampi(y + k - 2, 0, h - 1)
				acc += tmp[yy * w + x] * ELEV_BLUR[k]
			var level: float = acc * 0.0625 / unit
			smooth_bytes[row + x] = clampi(int(round(level * scale)), 0, 255)
	_smooth = smooth_bytes
	smooth_img = Image.create_from_data(w, h, false, Image.FORMAT_R8, smooth_bytes)

	data_texture = ImageTexture.create_from_image(data_img)
	elev_texture = ImageTexture.create_from_image(elev_img)
	mountain_texture = ImageTexture.create_from_image(mountain_img)
	smooth_texture = ImageTexture.create_from_image(smooth_img)
	prop_ground_texture = ImageTexture.create_from_image(prop_ground_img)
	material.set_shader_parameter("u_data", data_texture)
	material.set_shader_parameter("u_elev", elev_texture)
	material.set_shader_parameter("u_elev_smooth", smooth_texture)
	material.set_shader_parameter("u_mountain", mountain_texture)
	material.set_shader_parameter("u_prop_ground", prop_ground_texture)
	material.set_shader_parameter("u_map_size", Vector2(map.grid_size))
	material.set_shader_parameter("u_elev_max", maxf(_height_max, 1.0))
	material.set_shader_parameter("u_time", 0.0)
	material.set_shader_parameter("u_oblique", false)
	_bake_noise()
	_bake_colors()
	_bake_affinity()


## 笔刷/矩形填充后的区域增量更新：只写区域内像素、只上传一次纹理。
## elev_changed=true 时才重算平滑高程与最高点；with_gameplay=true 时同步通行代价。
## 预览用的 runtime（with_gameplay=false）不做寻路，只更新外观。
## 注意：通行代价的增量不会重新应用物件阻挡，游戏端改地形后应再调用 apply_props()。
func sync_area(area: Rect2i, elev_changed: bool = false) -> void:
	if map == null or data_img == null:
		return
	var clipped: Rect2i = area.intersection(Rect2i(Vector2i.ZERO, map.grid_size))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return
	if elev_changed:
		_refresh_heights(clipped)
	var w: int = map.grid_size.x
	for y in range(clipped.position.y, clipped.end.y):
		var row: int = y * w
		for x in range(clipped.position.x, clipped.end.x):
			var i: int = row + x
			data_img.set_pixel(x, y, Color8(map.land[i], map.water[i], map.road[i], map.flow[i]))
			elev_img.set_pixel(x, y, Color8(clampi(_heights[i], 0, 255), 0, 0, 255))
			mountain_img.set_pixel(x, y, Color8(255 if map.mountain[i] > 0 else 0, 0, 0, 255))
			if not _costs.is_empty():
				var cell: Vector2i = Vector2i(x, y)
				var cost: float = _raw_cost(cell)
				_costs[i] = cost
				if cost <= 0.0:
					astar.set_point_solid(cell, true)
				else:
					astar.set_point_solid(cell, false)
					astar.set_point_weight_scale(cell, cost)
	data_texture.update(data_img)
	elev_texture.update(elev_img)
	mountain_texture.update(mountain_img)
	if elev_changed:
		_rebuild_smooth_region(clipped)
		smooth_texture.update(smooth_img)
		material.set_shader_parameter("u_elev_max", maxf(_height_max, 1.0))


## 基础高程改动后同步合成高度场：
## 没有山体时只抄脏区；有山体时山脚基准可能变化，整图重新生成（含山体高度）。
func _refresh_heights(area: Rect2i) -> void:
	if map.has_mountain():
		_heights = MountainGenerator.build_heights(map)
		_height_max = _heights_max_level()
		return
	var w: int = map.grid_size.x
	for y in range(area.position.y, area.end.y):
		var row: int = y * w
		for x in range(area.position.x, area.end.x):
			_heights[row + x] = map.elevation[row + x]
	_height_max = _heights_max_level()


## 平滑高程的区域重建（5 点可分离核，半径 2 格）：与全量构建同一算法。
## 区域外扩 2 格是因为核半径；只重算这些行列，笔刷拖动时不会整图重算。
func _rebuild_smooth_region(area: Rect2i) -> void:
	var w: int = map.grid_size.x
	var h: int = map.grid_size.y
	if _smooth.size() != w * h or _smooth_tmp.size() != w * h:
		return
	var reg: Rect2i = area.grow(2).intersection(Rect2i(Vector2i.ZERO, map.grid_size))
	var tmp: PackedFloat32Array = _smooth_tmp
	var unit: float = float(map.elev_unit)
	var scale: float = 255.0 / ELEV_SMOOTH_MAX
	var ty0: int = maxi(reg.position.y - 2, 0)
	var ty1: int = mini(reg.end.y + 2, h)
	for y in range(ty0, ty1):
		var row: int = y * w
		for x in range(reg.position.x, reg.end.x):
			var acc: float = 0.0
			for k in 5:
				var xx: int = clampi(x + k - 2, 0, w - 1)
				acc += float(_heights[row + xx]) * ELEV_BLUR[k]
			tmp[row + x] = acc * 0.0625
	for y in range(reg.position.y, reg.end.y):
		var row: int = y * w
		for x in range(reg.position.x, reg.end.x):
			var acc: float = 0.0
			for k in 5:
				var yy: int = clampi(y + k - 2, 0, h - 1)
				acc += tmp[yy * w + x] * ELEV_BLUR[k]
			var level: float = acc * 0.0625 / unit
			var value: int = clampi(int(round(level * scale)), 0, 255)
			_smooth[row + x] = value
			smooth_img.set_pixel(x, y, Color(value / 255.0, 0.0, 0.0, 1.0))


## 换一份 look（编辑器里拖滑杆/改材质）时在现有材质上原地更新：
## 不重建地图纹理，也不动 u_time / 相机 uniform，游戏画面不闪。
func apply_look(settings: RenderSettings) -> void:
	if settings == null or material == null:
		return
	look = settings
	for prop: StringName in SCALAR_UNIFORMS:
		material.set_shader_parameter("u_" + String(prop), look.get(prop))
	_bake_noise()
	_bake_colors()
	_bake_affinity()


## 噪声：种子决定颗粒性格，必须和工具用同一个 seed，否则外观不一致
func _bake_noise() -> void:
	if look.noise_seed == _noise_seed:
		return
	_noise_seed = look.noise_seed
	var noise_img: Image = Image.create(NOISE_SIZE, NOISE_SIZE, false, Image.FORMAT_RGBA8)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = look.noise_seed
	for y in NOISE_SIZE:
		for x in NOISE_SIZE:
			noise_img.set_pixel(x, y, Color(rng.randf(), rng.randf(), rng.randf(), rng.randf()))
	material.set_shader_parameter("u_noise", ImageTexture.create_from_image(noise_img))


## 色表与材质亲和度：都来自 RenderSettings，材质窗口改了颜色/亲和在游戏里同样生效
func _bake_colors() -> void:
	var color_img: Image = Image.create(COLOR_COUNT, 1, false, Image.FORMAT_RGBA8)
	for i in COLOR_COUNT:
		color_img.set_pixel(i, 0, look.surface_color(i))
	material.set_shader_parameter("u_colors", ImageTexture.create_from_image(color_img))


func _bake_affinity() -> void:
	var aff_img: Image = Image.create(8, 8, false, Image.FORMAT_R8)
	for a in range(1, 9):
		for b in range(1, 9):
			aff_img.set_pixel(a - 1, b - 1, Color(look.get_affinity(a, b), 0.0, 0.0, 1.0))
	material.set_shader_parameter("u_affinity", ImageTexture.create_from_image(aff_img))


## 树根草垫遮罩：静态树木贴图底部自带一圈草，和地表草很难完全同色。
## 这里把每棵树的脚底标进一张 R8 纹理，地表着色器据此长出一圈同色、同颗粒的草，
## 让贴图草垫的边缘落在近似材质上，而不是硬切在另一种绿色上。
## 只影响外观；物件增删后由 GamePreview / 游戏端重新调用。
func set_ground_props(props) -> void:
	if map == null or prop_ground_img == null or prop_ground_texture == null:
		return
	var w: int = map.grid_size.x
	var h: int = map.grid_size.y
	# 草垫遮罩按格放大 2~4 倍烘：1px/格的径向渐变在 45° 下会读出同心圆台阶。
	var mask_scale: int = clampi(int(floor(2048.0 / float(maxi(w, h)))), 1, 4)
	var mw: int = w * mask_scale
	var mh: int = h * mask_scale
	if prop_ground_img.get_width() != mw or prop_ground_img.get_height() != mh:
		prop_ground_img = Image.create(mw, mh, false, Image.FORMAT_R8)
		prop_ground_texture = ImageTexture.create_from_image(prop_ground_img)
		material.set_shader_parameter("u_prop_ground", prop_ground_texture)
	else:
		prop_ground_img.fill(Color(0.0, 0.0, 0.0, 1.0))
	if props != null:
		for i in props.count():
			var def: StaticAssetDef = props.asset(props.asset_id_at(i))
			if def == null or def.category != &"tree":
				continue
			_paint_ground_patch(_tree_ground_center(props, i), mask_scale,
				_tree_ground_radius(props, i))
	prop_ground_texture.update(prop_ground_img)


## 树脚草垫中心：占地中心 + 实例视觉位移 + 一点确定性偏移，避免整片森林出现同心圆。
func _tree_ground_center(props, i: int) -> Vector2:
	var fp: Rect2i = props.footprint_at(i)
	var center: Vector2 = Vector2(props.cell_at(i)) + Vector2(fp.size) * 0.5
	center += props.visual_offset_at(i)
	center += Vector2(
		sin(center.x * 1.7 + center.y * 4.3) * 0.18,
		cos(center.x * 3.1 - center.y * 2.3) * 0.18)
	return center


## 草垫半径跟着植物倍率和视觉尺寸走：2× 树的贴图草垫也是 2×。
func _tree_ground_radius(props, i: int) -> float:
	return clampf(1.25 * float(props.multiplier_at(i)) * props.size_bias_at(i)
		* props.variation_scale_at(i), 0.8, 6.0)


## 把一圈草垫写进遮罩（不更新纹理，调用方批量/单次更新）。
func _paint_ground_patch(center: Vector2, mask_scale: int, radius_cells: float = 1.25) -> void:
	var mw: int = prop_ground_img.get_width()
	var mh: int = prop_ground_img.get_height()
	var center_px: Vector2 = center * float(mask_scale)
	var radius: float = radius_cells * float(mask_scale)
	var x0: int = maxi(0, floori(center_px.x - radius))
	var x1: int = mini(mw - 1, ceili(center_px.x + radius))
	var y0: int = maxi(0, floori(center_px.y - radius))
	var y1: int = mini(mh - 1, ceili(center_px.y + radius))
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var dx: float = (float(x) + 0.5 - center_px.x) / radius
			var dy: float = (float(y) + 0.5 - center_px.y) / radius
			var d: float = sqrt(dx * dx + dy * dy)
			var v: float = 1.0 - smoothstep(0.30, 1.0, d)
			if v <= 0.0:
				continue
			var value: int = int(round(v * 255.0))
			var old: int = int(round(prop_ground_img.get_pixel(x, y).r * 255.0))
			if value > old:
				prop_ground_img.set_pixel(x, y, Color(value / 255.0, 0.0, 0.0, 1.0))


## 拖动放置一棵树时增量更新草垫：不重算整张遮罩，避免每落一格都卡一下。
func add_ground_prop(props, index: int) -> void:
	if map == null or props == null or prop_ground_img == null or prop_ground_texture == null:
		return
	if index < 0 or index >= props.count():
		return
	var def: StaticAssetDef = props.asset(props.asset_id_at(index))
	if def == null or def.category != &"tree":
		return
	var mask_scale: int = prop_ground_img.get_width() / map.grid_size.x
	if mask_scale < 1:
		set_ground_props(props)
		return
	_paint_ground_patch(_tree_ground_center(props, index), mask_scale,
		_tree_ground_radius(props, index))
	prop_ground_texture.update(prop_ground_img)


## 玩法网格：通行代价写进 AStarGrid2D，可通行性用 solid 点标记
func _build_gameplay() -> void:
	var w: int = map.grid_size.x
	var h: int = map.grid_size.y
	_costs.resize(w * h)
	_bridge_cells.resize(w * h)
	_bridge_cells.fill(0)
	_bridge_z.resize(w * h)
	_bridge_z.fill(0.0)
	astar = AStarGrid2D.new()
	astar.region = Rect2i(Vector2i.ZERO, map.grid_size)
	astar.cell_size = Vector2.ONE
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	astar.update()
	for y in h:
		for x in w:
			var cell: Vector2i = Vector2i(x, y)
			var cost: float = _raw_cost(cell)
			_costs[y * w + x] = cost
			if cost <= 0.0:
				astar.set_point_solid(cell, true)
			else:
				astar.set_point_weight_scale(cell, cost)


## 单格通行代价；0 表示不可通行
func _raw_cost(cell: Vector2i) -> float:
	if map.is_mountain(cell):
		return 0.0
	var water: int = map.get_water(cell)
	if water == GridDefs.Water.DEEP:
		return DEEP_WATER_COST
	var base: float = SHALLOW_WATER_COST
	if water == GridDefs.Water.NONE:
		var road: int = map.get_road(cell)
		if road != GridDefs.Road.NONE:
			base = float(ROAD_COST.get(road, 1.0))
		else:
			base = float(LAND_COST.get(map.get_land(cell), 1.0))
	# 高地更费时：高程 1 级以上每级加一点
	base *= 1.0 + maxf(0.0, map.get_height(cell) - 1.0) * SLOPE_COST
	return base


## 把桥层的直线桥写进通行网格：桥格覆盖地形代价（深水也能过），
## 同时记录桥面高度，角色立牌用 surface_z() 走到桥面上。
## 必须在 setup(with_gameplay=true) 之后、apply_props 之后调用。
func apply_bridges(bridges) -> int:
	if bridges == null or astar == null:
		return 0
	var w: int = map.grid_size.x
	var h: int = map.grid_size.y
	_bridge_cells.resize(w * h)
	_bridge_cells.fill(0)
	_bridge_z.resize(w * h)
	_bridge_z.fill(0.0)
	var applied: int = 0
	for i in bridges.count():
		var cells: Array[Vector2i] = bridges.cells_at(i)
		if cells.is_empty():
			continue
		var top: float = 0.0
		for cell: Vector2i in cells:
			top = maxf(top, terrain_z(cell))
		var deck: float = top + BridgesData.kind_lift(bridges.kind_at(i))
		for cell: Vector2i in cells:
			if not map.in_bounds(cell):
				continue
			var idx: int = cell.y * w + cell.x
			_costs[idx] = BridgesData.SURFACE_COST
			_bridge_cells[idx] = 1
			_bridge_z[idx] = deck
			astar.set_point_solid(cell, false)
			astar.set_point_weight_scale(cell, BridgesData.SURFACE_COST)
			applied += 1
	return applied


## 桥面高度：桥格返回桥面 z，其余返回原地表。
func surface_z(cell: Vector2i) -> float:
	if not _bridge_cells.is_empty() and map != null and map.in_bounds(cell):
		var idx: int = cell.y * map.grid_size.x + cell.x
		if _bridge_cells[idx] == 1:
			return _bridge_z[idx]
	return terrain_z(cell)


func is_bridge_cell(cell: Vector2i) -> bool:
	if _bridge_cells.is_empty() or map == null or not map.in_bounds(cell):
		return false
	return _bridge_cells[cell.y * map.grid_size.x + cell.x] == 1


# ---------- 玩法查询 ----------

## 单格设为不可通行（物件占地用）；返回是否真的改变了
func block_cell(cell: Vector2i) -> bool:
	if astar == null or _costs.is_empty() or not map.in_bounds(cell):
		return false
	var idx: int = cell.y * map.grid_size.x + cell.x
	if _costs[idx] <= 0.0:
		return false
	_costs[idx] = 0.0
	astar.set_point_solid(cell, true)
	return true


## 把物件的实际阻挡格写进通行网格；必须在 setup() 之后调用。返回新增阻挡格数。
## 只处理静态资源：按定义里的 ALL/NONE/MASK 写实际阻挡格。
## surface_cost >= 0 的资产（桥/栈道）先覆盖其占地格的地形代价，
## 即使下面是深水也可通行；随后再写阻挡格。
func apply_props(props) -> int:
	set_ground_props(props)
	if props == null or astar == null:
		return 0
	var blocked: int = 0
	for i in props.count():
		var def: StaticAssetDef = props.asset(props.asset_id_at(i))
		if def != null and def.surface_cost >= 0.0:
			var fp: Rect2i = props.footprint_at(i)
			for cy in range(fp.position.y, fp.end.y):
				for cx in range(fp.position.x, fp.end.x):
					var cell: Vector2i = Vector2i(cx, cy)
					if not map.in_bounds(cell):
						continue
					var idx: int = cell.y * map.grid_size.x + cell.x
					_costs[idx] = def.surface_cost
					astar.set_point_solid(cell, false)
					astar.set_point_weight_scale(cell, def.surface_cost)
		for cell: Vector2i in props.blocking_cells_at(i):
			if block_cell(cell):
				blocked += 1
	return blocked


func is_walkable(cell: Vector2i) -> bool:
	if _costs.is_empty():
		return false
	return map.in_bounds(cell) and _costs[cell.y * map.grid_size.x + cell.x] > 0.0


func move_cost(cell: Vector2i) -> float:
	if _costs.is_empty() or not map.in_bounds(cell):
		return 0.0
	return _costs[cell.y * map.grid_size.x + cell.x]


func height_at(cell: Vector2i) -> float:
	return map.get_height(cell) if map.in_bounds(cell) else 0.0


## 渲染用的平滑高程（级）。斜角几何和精灵落脚点必须用同一张场，
## 否则脚会陷进坡里或者浮在半空。
func smooth_level(cell: Vector2i) -> float:
	if map == null or _smooth.is_empty() or not map.in_bounds(cell):
		return 0.0
	return float(_smooth[cell.y * map.grid_size.x + cell.x]) / 255.0 * ELEV_SMOOTH_MAX


## 合成高程（基础 + 程序化山体）的最高级数；取景/雪线用
func height_max() -> float:
	return _height_max


func _heights_max_level() -> float:
	var top: int = 0
	for v in _heights:
		if v > top:
			top = v
	return float(top) / float(maxi(map.elev_unit, 1))


## 地表高度（世界格），与着色器 terrain_z() 完全一致
func terrain_z(cell: Vector2i) -> float:
	return maxf(smooth_level(cell) - 1.0, 0.0) * look.height_scale


func water_at(cell: Vector2i) -> int:
	return map.get_water(cell) if map.in_bounds(cell) else GridDefs.Water.NONE


## A* 寻路：返回格子序列（含起点终点）；走不通返回空数组
func find_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	if astar == null or not is_walkable(from) or not is_walkable(to):
		return empty
	var ids: PackedVector2Array = astar.get_id_path(from, to)
	var path: Array[Vector2i] = []
	for p: Vector2 in ids:
		path.append(Vector2i(p))
	return path


## 路径总代价（斜向按 √2 加权），游戏里乘以基础速度就是秒数
func path_cost(path: Array[Vector2i]) -> float:
	var total: float = 0.0
	for i in range(1, path.size()):
		var prev: Vector2i = path[i - 1]
		var cur: Vector2i = path[i]
		var step: float = 1.4142135 if (prev.x != cur.x and prev.y != cur.y) else 1.0
		total += step * maxf(move_cost(cur), move_cost(prev))
	return total


## 格心世界坐标（实体摆放 / 覆盖层绘制都用它）
func cell_center(cell: Vector2i) -> Vector2:
	return (Vector2(cell) + Vector2(0.5, 0.5)) * CELL_SIZE
