extends Resource

const MapSidecars = preload("res://data/map_sidecars.gd")
## 静态资源实例层：每张地图一份，和地图同目录同名边车保存
## （maps/first/first.tres → maps/first/first.props.tres）。
## 平行紧凑数组，风格与 MapData 一致：
##   asset_ids[i] 资源定义 id（StringName）
##   cells[2i]    占地范围左上角 x
##   cells[2i+1]  占地范围左上角 y
##   rots[i]      0=横向（原始图片）/ 1=竖向（占地交换宽高，图片水平镜像）
##   multipliers[i] 植物倍率：1=原始占地/图片；2=2×2 占地、图片 1.5×；
##                  3=3×3 占地、图片 2×；4=4×4 占地、图片 2.5×
##   visual_offsets[i] 植物的视觉位移（格，只影响图片/树根草垫，不影响占格）
##   size_biases[i] 植物的视觉尺寸偏置（0.92~1.08）
##
## 只存 id + 锚点 + 方向 + 植物表现参数：占地范围与阻挡格属于资源定义，
## 运行时不重复存档。内置物件已经彻底移除：旧边车（kinds/cells/scales 格式）
## 在 sanitize() 里清空，所有没有 asset_ids 的旧实例不再参与渲染/阻挡。

@export var asset_ids: PackedStringArray = PackedStringArray()
@export var rots: PackedInt32Array = PackedInt32Array()
@export var cells: PackedInt32Array = PackedInt32Array()
@export var multipliers: PackedInt32Array = PackedInt32Array()
@export var visual_offsets: PackedVector2Array = PackedVector2Array()
@export var size_biases: PackedFloat32Array = PackedFloat32Array()

const MULTIPLIER_MIN: int = 1
const MULTIPLIER_MAX: int = 4
const SIZE_BIAS_MIN: float = 0.92
const SIZE_BIAS_MAX: float = 1.08

## id -> StaticAssetDef。由 main 在载入资源目录后注入，不写进边车。
var asset_defs: Dictionary = {}
## 随机款式组：group id -> Array[StringName]（组内所有定义，含 primary）。
var variant_groups: Dictionary = {}


## 边车路径：与地图同目录同名，后缀换成 .props.tres
static func sidecar_path(map_path: String) -> String:
	return MapSidecars.props_path(map_path)


func set_asset_defs(defs: Dictionary) -> void:
	asset_defs = defs
	variant_groups.clear()
	for key: StringName in defs:
		var def: StaticAssetDef = defs[key] as StaticAssetDef
		if def == null or def.variant_group == &"":
			continue
		var ids: Array = variant_groups.get(def.variant_group, [])
		ids.append(def.id)
		variant_groups[def.variant_group] = ids


func asset(id: StringName) -> StaticAssetDef:
	if not asset_defs.has(id):
		return null
	return asset_defs[id] as StaticAssetDef


## 旧边车清理 + 数组对齐：
##   - 只有 kinds/cells/scales、没有 asset_ids 的旧内置物件：全部丢弃；
##   - 新格式：丢掉空 id、尾部不完整项，补齐方向/倍率/视觉参数；
## 返回是否发生了改动（调用方据此提示旧边车已清理/升级）。
func sanitize() -> bool:
	var changed: bool = false
	if asset_ids.is_empty():
		if not cells.is_empty() or not rots.is_empty() or not multipliers.is_empty() \
				or not visual_offsets.is_empty() or not size_biases.is_empty():
			cells.clear()
			rots.clear()
			multipliers.clear()
			visual_offsets.clear()
			size_biases.clear()
			changed = true
		return changed

	var valid: int = mini(asset_ids.size(), cells.size() / 2)
	var kept_ids: PackedStringArray = PackedStringArray()
	var kept_rots: PackedInt32Array = PackedInt32Array()
	var kept_cells: PackedInt32Array = PackedInt32Array()
	var kept_mults: PackedInt32Array = PackedInt32Array()
	var kept_offsets: PackedVector2Array = PackedVector2Array()
	var kept_biases: PackedFloat32Array = PackedFloat32Array()
	for i in valid:
		var id: String = asset_ids[i]
		if id.is_empty():
			changed = true
			continue
		var rot: int = rots[i] if i < rots.size() else 0
		var mult: int = multipliers[i] if i < multipliers.size() else 1
		var clamped_mult: int = clampi(mult, MULTIPLIER_MIN, MULTIPLIER_MAX)
		var offset: Vector2 = visual_offsets[i] if i < visual_offsets.size() else Vector2.ZERO
		var bias: float = size_biases[i] if i < size_biases.size() else 1.0
		var clamped_bias: float = clampf(bias, SIZE_BIAS_MIN, SIZE_BIAS_MAX)
		if clamped_mult != mult or not is_equal_approx(clamped_bias, bias):
			changed = true
		kept_ids.append(id)
		kept_rots.append(posmod(rot, 2))
		kept_cells.append(cells[i * 2])
		kept_cells.append(cells[i * 2 + 1])
		kept_mults.append(clamped_mult)
		kept_offsets.append(offset)
		kept_biases.append(clamped_bias)
	if kept_ids.size() != asset_ids.size() or kept_rots.size() != rots.size() \
			or kept_cells.size() != cells.size() or kept_mults.size() != multipliers.size() \
			or kept_offsets.size() != visual_offsets.size() or kept_biases.size() != size_biases.size():
		changed = true
	asset_ids = kept_ids
	rots = kept_rots
	cells = kept_cells
	multipliers = kept_mults
	visual_offsets = kept_offsets
	size_biases = kept_biases
	return changed


func count() -> int:
	return mini(asset_ids.size(), mini(cells.size() / 2, rots.size()))


func asset_id_at(i: int) -> StringName:
	if i < 0 or i >= asset_ids.size():
		return &""
	return StringName(asset_ids[i])


func rotation_at(i: int) -> int:
	if i < 0 or i >= rots.size():
		return 0
	return posmod(rots[i], 2)


## 植物的视觉缩放：倍率 1/2/3/4 → 1.0/1.5/2.0/2.5。
## 占地/阻挡仍按整数倍率（1×1/2×2/3×3/4×4），只放缓图片宽高的增长，
## 避免 1× 到 2× 之间出现“突然变成参天大树”的断层。
static func visual_scale(mult: int) -> float:
	return 1.0 + 0.5 * float(clampi(mult, MULTIPLIER_MIN, MULTIPLIER_MAX) - 1)


## 某实例的视觉缩放（非植物恒为 1）。
func visual_scale_at(i: int) -> float:
	return visual_scale(multiplier_at(i))


## 植物倍率：占地/阻挡按整数倍率；图片宽高用 visual_scale_at 渐变。
## 非植物与新旧数据默认 1。
func multiplier_at(i: int) -> int:
	if i < 0 or i >= multipliers.size():
		return 1
	var def: StaticAssetDef = asset(asset_id_at(i))
	if def != null and def.category != &"tree":
		return 1
	return clampi(multipliers[i], MULTIPLIER_MIN, MULTIPLIER_MAX)


## 视觉位移（格）：只挪图片和树根草垫，不改变占格/阻挡。
func visual_offset_at(i: int) -> Vector2:
	if i < 0 or i >= visual_offsets.size():
		return Vector2.ZERO
	return visual_offsets[i]


## 视觉尺寸偏置：只缩放图片，不改变占格。
func size_bias_at(i: int) -> float:
	if i < 0 or i >= size_biases.size():
		return 1.0
	return clampf(size_biases[i], SIZE_BIAS_MIN, SIZE_BIAS_MAX)


func is_plant(i: int) -> bool:
	var def: StaticAssetDef = asset(asset_id_at(i))
	return def != null and def.category == &"tree"


## 每株植物的稳定个体差异，不写存档：由资产 id + 格子坐标派生。
## 返回 x=色调(0..1), y=明暗/翻转(0..1), z=形态宽高比(0..1)。
## 用格子坐标而不是实例下标：删树、重排、撤销都不会让其它树突然变色。
func variation_at(i: int) -> Vector3:
	var cell: Vector2i = cell_at(i)
	var n: int = _stable_string_hash(String(asset_id_at(i))) \
		^ (cell.x * 73856093) ^ (cell.y * 19349663)
	return Vector3(_hash01(n), _hash01(n ^ 0x9e3779b9), _hash01(n ^ 0x85ebca6b))


## 植物微小色调：暖黄绿 / 中性 / 冷绿 / 橄榄，压得很轻，只用来区分个体。
func variation_tint_at(i: int) -> Color:
	if not is_plant(i):
		return Color.WHITE
	var v: Vector3 = variation_at(i)
	var warm: Color = Color(1.10, 1.03, 0.82)
	var cool: Color = Color(0.90, 1.03, 1.00)
	var bright: Color = Color(1.06, 1.08, 0.90)
	var olive: Color = Color(0.94, 0.98, 0.82)
	var tint: Color
	if v.x < 0.28:
		tint = warm.lerp(Color.WHITE, v.x / 0.28)
	elif v.x < 0.58:
		tint = Color.WHITE.lerp(cool, (v.x - 0.28) / 0.30)
	elif v.x < 0.82:
		tint = cool.lerp(bright, (v.x - 0.58) / 0.24)
	else:
		tint = bright.lerp(olive, (v.x - 0.82) / 0.18)
	var lum: float = 0.90 + v.y * 0.20
	return Color(tint.r * lum, tint.g * lum, tint.b * lum)


## 植物宽高比：0.90~1.10；宽度乘 sqrt，高度除 sqrt，整体面积大致不变。
func variation_aspect_at(i: int) -> float:
	if not is_plant(i):
		return 1.0
	return 0.90 + variation_at(i).z * 0.20


## 个体整体大小：0.88~1.12。旧地图的树也会立刻有大小差异。
func variation_scale_at(i: int) -> float:
	if not is_plant(i):
		return 1.0
	var cell: Vector2i = cell_at(i)
	var n: int = _stable_string_hash(String(asset_id_at(i))) \
		^ (cell.x * 73856093) ^ (cell.y * 19349663)
	return 0.88 + _hash01(n ^ 0x2545f491) * 0.24


## 约 1/3 的植物水平镜像，进一步打破"同一张图"的重复感。
func variation_flip_at(i: int) -> bool:
	if not is_plant(i):
		return false
	var cell: Vector2i = cell_at(i)
	var n: int = _stable_string_hash(String(asset_id_at(i))) \
		^ (cell.x * 73856093) ^ (cell.y * 19349663)
	return _hash01(n ^ 0x7f4a7c15) > 0.66


## 树冠形变：x=上部宽度倍率偏移，y=上部横向倾斜；只作用于图片。
func variation_crown_at(i: int) -> Vector2:
	if not is_plant(i):
		return Vector2.ZERO
	var cell: Vector2i = cell_at(i)
	var n: int = _stable_string_hash(String(asset_id_at(i))) \
		^ (cell.x * 73856093) ^ (cell.y * 19349663)
	return Vector2((_hash01(n ^ 0x27d4eb2d) - 0.5) * 0.34,
		(_hash01(n ^ 0x165667b1) - 0.5) * 0.14)


static func _stable_string_hash(s: String) -> int:
	var h: int = 2166136261
	for i in s.length():
		h = ((h ^ s.unicode_at(i)) * 16777619) & 0x7fffffff
	return h


static func _hash01(n: int) -> float:
	var x: int = n & 0x7fffffff
	x = ((x ^ (x >> 16)) * 0x45d9f3b) & 0x7fffffff
	x = ((x ^ (x >> 16)) * 0x45d9f3b) & 0x7fffffff
	x = x ^ (x >> 16)
	return float(x & 0x00ffffff) / 16777215.0


func cell_at(i: int) -> Vector2i:
	return Vector2i(cells[i * 2], cells[i * 2 + 1])


func footprint_at(i: int) -> Rect2i:
	return Rect2i(cell_at(i), footprint_of(asset_id_at(i), rotation_at(i), multiplier_at(i)))


## 资源在指定方向/倍率下的占地尺寸；定义缺失时退化成 1×1。
## 倍率先乘到基础占地，再旋转；1×1 树 ×2 = 2×2。
func footprint_of(asset_id: StringName, rot: int = 0, scale: int = 1) -> Vector2i:
	var def: StaticAssetDef = asset(asset_id)
	if def == null:
		return Vector2i.ONE
	var mult: int = maxi(scale, 1)
	if def.category != &"tree":
		mult = 1
	var base: Vector2i = Vector2i(def.footprint.x * mult, def.footprint.y * mult)
	return rotated_footprint(base, rot)


## 放置碰撞按占地范围判定；A* 阻挡另走 blocking_cells_at()，门洞保持可通行。
func can_place_asset(asset_id: StringName, cell: Vector2i, map_size: Vector2i,
		rot: int = 0, scale: int = 1) -> bool:
	var def: StaticAssetDef = asset(asset_id)
	if def == null:
		return false
	return can_place_fp(footprint_of(asset_id, rot, scale), cell, map_size)


func can_place_fp(fp: Vector2i, cell: Vector2i, map_size: Vector2i) -> bool:
	return can_place_fp_excluding(fp, cell, map_size, -1)


## ignore_index >= 0 时跳过该实例：原地旋转要允许和"自己"的原占地重叠
func can_place_fp_excluding(fp: Vector2i, cell: Vector2i, map_size: Vector2i, ignore_index: int) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x + fp.x > map_size.x or cell.y + fp.y > map_size.y:
		return false
	var area: Rect2i = Rect2i(cell, fp)
	for i in count():
		if i == ignore_index:
			continue
		if footprint_at(i).intersects(area):
			return false
	return true


## 随机款式：选中组里的 primary 定义后，放置时随机换成一个同组实例。
## 组内成员必须共享占地/阻挡；目前阔叶树组全部 1×1。
func variant_for(id: StringName) -> StringName:
	var def: StaticAssetDef = asset(id)
	if def == null or def.variant_group == &"":
		return id
	var ids: Array = variant_groups.get(def.variant_group, [])
	if ids.is_empty():
		return id
	return StringName(ids.pick_random())


## 放置一个静态资源实例；锚点是旋转后占地范围的左上角。
## scale>1 只对植物生效：占地 ×scale，图片按 visual_scale 渐变；并写入小幅位置/尺寸随机偏置。
func add_asset(asset_id: StringName, cell: Vector2i, map_size: Vector2i,
		rot: int = 0, scale: int = 1) -> bool:
	sanitize()
	var def: StaticAssetDef = asset(asset_id)
	if def == null:
		return false
	var chosen_id: StringName = variant_for(asset_id)
	var chosen_def: StaticAssetDef = asset(chosen_id)
	if chosen_def == null:
		chosen_id = asset_id
		chosen_def = def
	var mult: int = clampi(scale, MULTIPLIER_MIN, MULTIPLIER_MAX)
	if chosen_def.category != &"tree":
		mult = 1
	if not can_place_asset(chosen_id, cell, map_size, rot, mult):
		return false
	var offset: Vector2 = Vector2.ZERO
	var bias: float = 1.0
	if chosen_def.category == &"tree":
		# 小幅偏置：只影响观感，不改变占格/阻挡；倍率越大，绝对偏移稍微放大。
		var jitter: float = 0.055 * float(mult)
		offset = Vector2(randf_range(-jitter, jitter), randf_range(-jitter, jitter))
		bias = randf_range(SIZE_BIAS_MIN, SIZE_BIAS_MAX)
	asset_ids.append(String(chosen_id))
	rots.append(posmod(rot, 2))
	cells.append(cell.x)
	cells.append(cell.y)
	multipliers.append(mult)
	visual_offsets.append(offset)
	size_biases.append(bias)
	return true


## 删除所有占地覆盖该格的实例（右键擦除按占地范围判定，2×2 不会只删一半）
func remove_at(cell: Vector2i) -> int:
	sanitize()
	var removed: int = 0
	for i in range(count() - 1, -1, -1):
		if footprint_at(i).has_point(cell):
			asset_ids.remove_at(i)
			rots.remove_at(i)
			cells.remove_at(i * 2)
			cells.remove_at(i * 2)
			multipliers.remove_at(i)
			visual_offsets.remove_at(i)
			size_biases.remove_at(i)
			removed += 1
	return removed


## 清空全部实例（面板“清除全部”）
func clear() -> void:
	asset_ids.clear()
	rots.clear()
	cells.clear()
	multipliers.clear()
	visual_offsets.clear()
	size_biases.clear()


## 撤销快照用：数组深拷贝（实例是纯数据，没有共享引用）
func duplicate_data():
	var out = get_script().new()
	out.asset_ids = asset_ids.duplicate()
	out.rots = rots.duplicate()
	out.cells = cells.duplicate()
	out.multipliers = multipliers.duplicate()
	out.visual_offsets = visual_offsets.duplicate()
	out.size_biases = size_biases.duplicate()
	out.asset_defs = asset_defs
	return out


## 把另一份数据写回本对象（视图持有引用，不能换对象）
func restore_from(other) -> void:
	asset_ids = other.asset_ids.duplicate()
	rots = other.rots.duplicate()
	cells = other.cells.duplicate()
	multipliers = other.multipliers.duplicate()
	visual_offsets = other.visual_offsets.duplicate()
	size_biases = other.size_biases.duplicate()


## 改地图尺寸后丢掉越界的实例；返回丢弃数量
func drop_out_of_bounds(map_size: Vector2i) -> int:
	sanitize()
	var kept_ids: PackedStringArray = PackedStringArray()
	var kept_rots: PackedInt32Array = PackedInt32Array()
	var kept_cells: PackedInt32Array = PackedInt32Array()
	var kept_mults: PackedInt32Array = PackedInt32Array()
	var kept_offsets: PackedVector2Array = PackedVector2Array()
	var kept_biases: PackedFloat32Array = PackedFloat32Array()
	var dropped: int = 0
	for i in count():
		var fp: Rect2i = footprint_at(i)
		if fp.position.x >= 0 and fp.position.y >= 0 and fp.end.x <= map_size.x and fp.end.y <= map_size.y:
			kept_ids.append(String(asset_id_at(i)))
			kept_rots.append(rotation_at(i))
			kept_cells.append(fp.position.x)
			kept_cells.append(fp.position.y)
			kept_mults.append(multiplier_at(i))
			kept_offsets.append(visual_offset_at(i))
			kept_biases.append(size_bias_at(i))
		else:
			dropped += 1
	asset_ids = kept_ids
	rots = kept_rots
	cells = kept_cells
	multipliers = kept_mults
	visual_offsets = kept_offsets
	size_biases = kept_biases
	return dropped


## 该实例真正写进 A* 的阻挡格（绝对坐标），按资源的 ALL/NONE/MASK 定义与倍率。
func blocking_cells_at(i: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var def: StaticAssetDef = asset(asset_id_at(i))
	if def == null:
		return out
	var origin: Vector2i = cell_at(i)
	for local: Vector2i in rotated_blocking_cells(def, rotation_at(i), multiplier_at(i)):
		out.append(origin + local)
	return out


# ---------- 方向（实例级，只有横向/竖向两种） ----------

## 竖向（rot=1）交换宽高；横向保持原样
static func rotated_footprint(fp: Vector2i, rot: int) -> Vector2i:
	if posmod(rot, 2) == 1:
		return Vector2i(fp.y, fp.x)
	return fp


## 原 local 格 -> 竖向后的 local 格；fp 是旋转前的尺寸
static func rotate_cell(cell: Vector2i, fp: Vector2i, rot: int) -> Vector2i:
	if posmod(rot, 2) == 1:
		return Vector2i(fp.y - 1 - cell.y, cell.x)
	return cell


## 资源定义里的阻挡格 -> 旋转后的 local 格；scale>1 时把每格放大为 scale×scale。
static func rotated_blocking_cells(def: StaticAssetDef, rot: int, scale: int = 1) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if def == null:
		return out
	var mult: int = maxi(scale, 1)
	if def.category != &"tree":
		mult = 1
	var base_fp: Vector2i = Vector2i(def.footprint.x * mult, def.footprint.y * mult)
	if def.blocking_mode == StaticAssetDef.Blocking.NONE:
		return out
	if def.blocking_mode == StaticAssetDef.Blocking.ALL:
		for y in base_fp.y:
			for x in base_fp.x:
				out.append(rotate_cell(Vector2i(x, y), base_fp, rot))
		return out
	for y in def.footprint.y:
		for x in def.footprint.x:
			var local: Vector2i = Vector2i(x, y)
			if not def.is_blocked(local):
				continue
			for sy in mult:
				for sx in mult:
					var scaled: Vector2i = Vector2i(x * mult + sx, y * mult + sy)
					out.append(rotate_cell(scaled, base_fp, rot))
	return out


## 绕占地中心旋转后的新左上角；偶数/奇数混排时取最近的整格（最多偏半格）
static func rotated_anchor(cell: Vector2i, fp: Vector2i, rot: int) -> Vector2i:
	var new_fp: Vector2i = rotated_footprint(fp, rot)
	var center: Vector2 = Vector2(cell) + Vector2(fp) * 0.5
	return Vector2i(roundi(center.x - new_fp.x * 0.5), roundi(center.y - new_fp.y * 0.5))


func next_rotation(i: int) -> int:
	return (rotation_at(i) + 1) % 2


func next_rotation_footprint(i: int) -> Vector2i:
	return rotated_footprint(footprint_at(i).size, 1)


func next_rotation_anchor(i: int) -> Vector2i:
	return rotated_anchor(cell_at(i), footprint_at(i).size, 1)


## 原地旋转（+90°）是否合法：只看越界与实例重叠，地形不限
func can_rotate(i: int, map_size: Vector2i) -> bool:
	if i < 0 or i >= count():
		return false
	return can_place_fp_excluding(next_rotation_footprint(i), next_rotation_anchor(i), map_size, i)


## 原始数据操作：不做越界/重叠校验；调用方应先 can_rotate
func rotate_instance(i: int) -> bool:
	if i < 0 or i >= count():
		return false
	sanitize()
	var anchor: Vector2i = next_rotation_anchor(i)
	var rot: int = next_rotation(i)
	rots[i] = rot
	cells[i * 2] = anchor.x
	cells[i * 2 + 1] = anchor.y
	return true


## 覆盖该格的实例下标；没有返回 -1
func asset_index_at(cell: Vector2i) -> int:
	for i in count():
		if footprint_at(i).has_point(cell):
			return i
	return -1


## 资源的锚点：让占地范围尽量以鼠标格为中心，而不是从鼠标格向右下铺开。
## 奇数边长可以真正居中；偶数边长（2×2）鼠标格落在左上角。
static func anchor_for(fp: Vector2i, center: Vector2i) -> Vector2i:
	return center - Vector2i(int(floorf(float(fp.x - 1) * 0.5)), int(floorf(float(fp.y - 1) * 0.5)))
