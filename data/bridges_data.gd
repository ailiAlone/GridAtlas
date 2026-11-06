class_name BridgesData
extends Resource

const MapSidecars = preload("res://data/map_sidecars.gd")
## 独立于静态资源的桥层：一条桥 = 两个 1×1 桥座（陆地） + 桥身（水面）。
## starts/ends 存两个桥座格；桥身是两座之间的水面格，至少 1 格、长度不限。
## 只允许水平/垂直的整条直线，不允许 L 形或斜线；桥体视觉全部由 procedural_bridge 生成。
## 与地图同目录同名的 .bridges.tres 边车保存
## （maps/first/first.tres -> maps/first/first.bridges.tres）。

enum Kind { LOG, WOOD, STONE }

const KIND_NAMES: Array[String] = ["独木桥", "木桥", "石桥"]
const KIND_LIFTS: Array[float] = [0.36, 0.68, 0.60]
const SURFACE_COST: float = 0.6

@export var kinds: PackedInt32Array = PackedInt32Array()
@export var starts: PackedInt32Array = PackedInt32Array()  # x,y 成对
@export var ends: PackedInt32Array = PackedInt32Array()    # x,y 成对


static func sidecar_path(map_path: String) -> String:
	return MapSidecars.bridges_path(map_path)


static func kind_name(kind: int) -> String:
	if kind < 0 or kind >= KIND_NAMES.size():
		return "桥"
	return KIND_NAMES[kind]


static func kind_lift(kind: int) -> float:
	if kind < 0 or kind >= KIND_LIFTS.size():
		return KIND_LIFTS[Kind.WOOD]
	return KIND_LIFTS[kind]


func count() -> int:
	return mini(kinds.size(), mini(starts.size() / 2, ends.size() / 2))


func kind_at(i: int) -> int:
	if i < 0 or i >= kinds.size():
		return Kind.WOOD
	return clampi(kinds[i], Kind.LOG, Kind.STONE)


func start_at(i: int) -> Vector2i:
	if i < 0 or i * 2 + 1 >= starts.size():
		return Vector2i.ZERO
	return Vector2i(starts[i * 2], starts[i * 2 + 1])


func end_at(i: int) -> Vector2i:
	if i < 0 or i * 2 + 1 >= ends.size():
		return Vector2i.ZERO
	return Vector2i(ends[i * 2], ends[i * 2 + 1])


func cells_at(i: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var a: Vector2i = start_at(i)
	var b: Vector2i = end_at(i)
	if a.x == b.x:
		var y0: int = mini(a.y, b.y)
		var y1: int = maxi(a.y, b.y)
		for y in range(y0, y1 + 1):
			out.append(Vector2i(a.x, y))
	elif a.y == b.y:
		var x0: int = mini(a.x, b.x)
		var x1: int = maxi(a.x, b.x)
		for x in range(x0, x1 + 1):
			out.append(Vector2i(x, a.y))
	return out


## 只允许水平/垂直、至少跨两格
static func is_straight_span(a: Vector2i, b: Vector2i) -> bool:
	if a == b:
		return false
	return a.x == b.x or a.y == b.y


func overlaps_span(a: Vector2i, b: Vector2i, ignore_index: int = -1) -> bool:
	var mine: Array[Vector2i] = _line_cells(a, b)
	if mine.is_empty():
		return false
	for i in count():
		if i == ignore_index:
			continue
		for cell: Vector2i in cells_at(i):
			if mine.has(cell):
				return true
	return false


static func span_cells(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if a.x == b.x:
		for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
			out.append(Vector2i(a.x, y))
	elif a.y == b.y:
		for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
			out.append(Vector2i(x, a.y))
	return out


func _line_cells(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	return span_cells(a, b)


## 添加一条直线桥；越界/斜线/重叠都拒绝。地形条件由调用方校验。
func add_bridge(kind: int, a: Vector2i, b: Vector2i, map_size: Vector2i) -> bool:
	sanitize()
	if kind < Kind.LOG or kind > Kind.STONE:
		return false
	if not is_straight_span(a, b):
		return false
	if span_cells(a, b).size() < 3:   # 两个桥座 + 至少 1 格桥身
		return false
	if not _in_bounds(a, map_size) or not _in_bounds(b, map_size):
		return false
	if overlaps_span(a, b):
		return false
	kinds.append(kind)
	starts.append(a.x)
	starts.append(a.y)
	ends.append(b.x)
	ends.append(b.y)
	return true


func remove_at(i: int) -> bool:
	sanitize()
	if i < 0 or i >= count():
		return false
	kinds.remove_at(i)
	starts.remove_at(i * 2)
	starts.remove_at(i * 2)
	ends.remove_at(i * 2)
	ends.remove_at(i * 2)
	return true


## 删除包含该格的桥；返回删除条数（通常 0/1）
func remove_at_cell(cell: Vector2i) -> int:
	sanitize()
	for i in range(count() - 1, -1, -1):
		if cells_at(i).has(cell):
			remove_at(i)
			return 1
	return 0


func index_at_cell(cell: Vector2i) -> int:
	for i in count():
		if cells_at(i).has(cell):
			return i
	return -1


func clear() -> void:
	kinds.clear()
	starts.clear()
	ends.clear()


func duplicate_data():
	var out = get_script().new()
	out.kinds = kinds.duplicate()
	out.starts = starts.duplicate()
	out.ends = ends.duplicate()
	return out


func restore_from(other) -> void:
	if other == null:
		clear()
		return
	kinds = other.kinds.duplicate()
	starts = other.starts.duplicate()
	ends = other.ends.duplicate()


## 丢掉数组不完整/斜线/零长度/类型非法的条目；不改地图边界。
func sanitize() -> bool:
	var n: int = mini(kinds.size(), mini(starts.size() / 2, ends.size() / 2))
	if n == kinds.size() and starts.size() == n * 2 and ends.size() == n * 2:
		var bad: bool = false
		for i in n:
			if kinds[i] < Kind.LOG or kinds[i] > Kind.STONE \
					or not is_straight_span(start_at(i), end_at(i)):
				bad = true
				break
		if not bad:
			return false
	var kk: PackedInt32Array = PackedInt32Array()
	var ss: PackedInt32Array = PackedInt32Array()
	var ee: PackedInt32Array = PackedInt32Array()
	for i in n:
		var kind: int = kinds[i]
		var a: Vector2i = Vector2i(starts[i * 2], starts[i * 2 + 1])
		var b: Vector2i = Vector2i(ends[i * 2], ends[i * 2 + 1])
		if kind < Kind.LOG or kind > Kind.STONE:
			continue
		if not is_straight_span(a, b):
			continue
		if span_cells(a, b).size() < 3:
			continue
		kk.append(kind)
		ss.append(a.x)
		ss.append(a.y)
		ee.append(b.x)
		ee.append(b.y)
	kinds = kk
	starts = ss
	ends = ee
	return true


## 地图缩小后删除越界桥；返回删除条数。
func drop_out_of_bounds(map_size: Vector2i) -> int:
	sanitize()
	var dropped: int = 0
	for i in range(count() - 1, -1, -1):
		var a: Vector2i = start_at(i)
		var b: Vector2i = end_at(i)
		if not _in_bounds(a, map_size) or not _in_bounds(b, map_size):
			remove_at(i)
			dropped += 1
	return dropped


func _in_bounds(cell: Vector2i, map_size: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < map_size.x and cell.y < map_size.y
