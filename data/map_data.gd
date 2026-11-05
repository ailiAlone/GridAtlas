class_name MapData
extends Resource
## 网格地图数据：每个图层一条平行紧凑数组，下标 = y * grid_size.x + x。
## 存档直接 ResourceSaver.save() 成 .tres。
## 本类只存纯数据；文件路径、「未保存」标记属于编辑器状态，不放这里。


@export var grid_size: Vector2i = Vector2i(64, 64)

@export var land: PackedInt32Array       # GridDefs.Land
@export var water: PackedInt32Array      # GridDefs.Water
@export var flow: PackedInt32Array       # GridDefs.Flow（水域流向）
@export var road: PackedInt32Array       # GridDefs.Road
## 山体遮罩：0=无，1=山体。和陆地/高程分开存：
## 山体只改变材质与通行（岩石、不可走），不覆盖你画的地形分类。
@export var mountain: PackedInt32Array
## 高程，存储单位 = 1 / elev_unit 级。新图 elev_unit=4（0.25 级精度）。
@export var elevation: PackedInt32Array
## 每级的存储单位数。旧存档没有这个字段，默认 1（值就是级数）；载入时由 ensure_precision() 迁移到 4。
@export var elev_unit: int = 1


## 新图使用的高程单位：0.25 级。8 位纹理正好装得下（255 单位 = 63.75 级）。
const ELEV_UNITS: int = 4


## 新建指定尺寸的地图：陆地全图默认草地、高程默认 1（两者没有 NONE 状态）；
## 水域/流向/道路为 0（NONE），因为它们是可选覆盖层。
static func create(size: Vector2i) -> MapData:
	var data: MapData = MapData.new()
	data.grid_size = size
	var count: int = size.x * size.y
	data.land.resize(count)
	data.land.fill(GridDefs.Land.GRASS)
	data.water.resize(count)
	data.flow.resize(count)
	data.road.resize(count)
	data.mountain.resize(count)
	data.elevation.resize(count)
	data.elevation.fill(ELEV_UNITS)
	data.elev_unit = ELEV_UNITS
	return data


func idx(cell: Vector2i) -> int:
	return cell.y * grid_size.x + cell.x


func in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < grid_size.x and cell.y < grid_size.y


# ---------- 按图层读写 ----------

func get_land(cell: Vector2i) -> int:
	return land[idx(cell)]

func set_land(cell: Vector2i, value: int) -> void:
	land[idx(cell)] = value

func get_water(cell: Vector2i) -> int:
	return water[idx(cell)]

func set_water(cell: Vector2i, value: int) -> void:
	water[idx(cell)] = value

func get_flow(cell: Vector2i) -> int:
	return flow[idx(cell)]

func set_flow(cell: Vector2i, value: int) -> void:
	flow[idx(cell)] = value

func get_road(cell: Vector2i) -> int:
	return road[idx(cell)]

func set_road(cell: Vector2i, value: int) -> void:
	road[idx(cell)] = value


## 山体遮罩：旧地图没有这个字段时按 0 处理
func get_mountain(cell: Vector2i) -> int:
	var i: int = idx(cell)
	if i < 0 or i >= mountain.size():
		return 0
	return mountain[i]

func set_mountain(cell: Vector2i, value: int) -> void:
	ensure_mountain()
	mountain[idx(cell)] = 1 if value > 0 else 0


## 旧存档没有 mountain：补一条和地图等长的 0 数组
func ensure_mountain() -> void:
	var count: int = grid_size.x * grid_size.y
	if mountain.size() == count:
		return
	mountain.resize(count)
	mountain.fill(0)


## 该格是否是不可通行的山体
func is_mountain(cell: Vector2i) -> bool:
	return get_mountain(cell) > 0


## 整张图是否至少有一格山体（地形改动后判断要不要重算山体高度）。
func has_mountain() -> bool:
	for value in mountain:
		if value > 0:
			return true
	return false


## 高程按"级"读写（1.0 = 基准面，0.25 为最小步长）
func get_height(cell: Vector2i) -> float:
	return float(elevation[idx(cell)]) / float(elev_unit)


func set_height(cell: Vector2i, value: float) -> void:
	elevation[idx(cell)] = clampi(roundi(value * float(elev_unit)), 0, 255)


## 旧存档（elev_unit = 1，值就是级数）迁移到 0.25 级单位；返回是否发生了迁移。
func ensure_precision() -> bool:
	if elev_unit == ELEV_UNITS:
		return false
	var factor: int = ELEV_UNITS / maxi(elev_unit, 1)
	for i in elevation.size():
		elevation[i] = clampi(elevation[i] * factor, 0, 255)
	elev_unit = ELEV_UNITS
	return true


## 不变量：有水面的格子，陆地字段必须是沙地（河床/海床）。
## 旧存档里"水下草地"在这里统一改写；返回被改写的格子数。
func ensure_water_sand() -> int:
	var fixed: int = 0
	for i in water.size():
		if water[i] != GridDefs.Water.NONE and land[i] != GridDefs.Land.SAND:
			land[i] = GridDefs.Land.SAND
			fixed += 1
	return fixed


## 全图最高高程（级），供渲染端计算斜角视角的射线范围
func max_height() -> float:
	var top: int = 0
	for i in elevation.size():
		if elevation[i] > top:
			top = elevation[i]
	return float(top) / float(elev_unit)


## 调整尺寸：新旧重叠区域的数据保留；新增区域 陆地=草地、高程=1，其余为 0（NONE）。
func resize(new_size: Vector2i) -> void:
	if new_size.x <= 0 or new_size.y <= 0 or new_size == grid_size:
		return
	land = _resized(land, new_size, GridDefs.Land.GRASS)
	water = _resized(water, new_size)
	flow = _resized(flow, new_size)
	road = _resized(road, new_size)
	mountain = _resized(mountain, new_size)
	elevation = _resized(elevation, new_size, elev_unit)
	grid_size = new_size


func _resized(source: PackedInt32Array, new_size: Vector2i, fill: int = 0) -> PackedInt32Array:
	var updated: PackedInt32Array = PackedInt32Array()
	updated.resize(new_size.x * new_size.y)
	if fill != 0:
		updated.fill(fill)
	for y in mini(new_size.y, grid_size.y):
		var from: int = y * grid_size.x
		var to: int = y * new_size.x
		for x in mini(new_size.x, grid_size.x):
			updated[to + x] = source[from + x]
	return updated
