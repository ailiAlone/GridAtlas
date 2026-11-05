class_name StaticAssetDef
extends Resource
## 静态资源定义：一个透明 PNG + 一套可复用的占地范围/阻挡/立牌参数。
##
## 术语：
##   footprint       占地范围：放置预览、越界、重叠、右键删除用的矩形
##   blocking_mode   阻挡模式：ALL=整个占地范围阻挡，NONE=不阻挡，MASK=按 blocking_cells
##   blocking_cells  实际阻挡格：MASK 下真正写进 A* 的格子（门柱等），其余格可通行
##
## 地图实例只存 id + 锚点 + 方向，不重复存掩码；
## 方向是实例属性（同一个资源可以横放/竖放），不是资源定义的一部分。

enum Blocking { ALL, NONE, MASK }

const CATEGORY_DEFAULT: StringName = &"prop"
const CATEGORY_IDS: Array[StringName] = [
	&"prop", &"building", &"gate", &"fence", &"bridge", &"tree", &"other",
]
const CATEGORY_LABELS: Array[String] = [
	"道具", "建筑", "门", "围墙/栅栏", "桥", "树/植被", "其他",
]
## 面板排序：建筑/门/围墙优先，杂项最后
const CATEGORY_ORDER: Array[StringName] = [
	&"building", &"gate", &"fence", &"bridge", &"prop", &"tree", &"other",
]
## 旧定义里的分类别名：house 统一读成 building
const CATEGORY_ALIASES: Dictionary = {&"house": &"building"}
## 单侧抬升上限：正负一整张立牌高度（导入页左右侧拉伸）
const ART_LIFT_LIMIT: float = 1.0


@export var id: StringName = &""
@export var display_name: String = ""
@export var category: StringName = CATEGORY_DEFAULT
@export var tier: int = 0
## 随机款式组：同一组的资源在放置时随机挑一个实例（例如各种阔叶树）。
## 空串 = 不参与随机；组内只有 variant_primary=true 的定义会出现在物件面板里。
@export var variant_group: StringName = &""
@export var variant_primary: bool = false
@export var texture_path: String = ""
@export var content_rect: Rect2i = Rect2i()
@export var art_size: Vector2 = Vector2.ONE
## 立牌左右整侧的垂直抬升量（占立牌高度的比例）：
## x=左侧，y=右侧；0=原样，正数=整侧抬高，负数=整侧压低，上限 ±1.0。用于侧向拉伸适配网格。
@export var art_lift: Vector2 = Vector2.ZERO
## 图片相对占地范围中心的屏幕偏移（格）：x 右、y 下。用于把立牌挪到合适位置。
@export var art_offset: Vector2 = Vector2.ZERO
@export var footprint: Vector2i = Vector2i.ONE
@export var blocking_mode: int = Blocking.ALL
@export var blocking_cells: Array[Vector2i] = []
## 桥/栈道等地表覆盖物的 A* 通行代价；<0 = 不覆盖地形代价。
@export var surface_cost: float = -1.0


## 修正尺寸/偏移，并丢掉越界或重复的阻挡格
func normalize() -> void:
	footprint = Vector2i(maxi(footprint.x, 1), maxi(footprint.y, 1))
	if variant_group == &"":
		variant_primary = false
	art_size = Vector2(maxf(art_size.x, 0.05), maxf(art_size.y, 0.05))
	art_lift = Vector2(
		clampf(art_lift.x, -ART_LIFT_LIMIT, ART_LIFT_LIMIT),
		clampf(art_lift.y, -ART_LIFT_LIMIT, ART_LIFT_LIMIT))
	art_offset = Vector2(clampf(art_offset.x, -32.0, 32.0), clampf(art_offset.y, -32.0, 32.0))
	blocking_mode = clampi(blocking_mode, Blocking.ALL, Blocking.MASK)
	if blocking_mode == Blocking.ALL or blocking_mode == Blocking.NONE:
		blocking_cells.clear()
		return
	var seen: Array[Vector2i] = []
	for cell: Vector2i in blocking_cells:
		if not _in_footprint(cell) or seen.has(cell):
			continue
		seen.append(cell)
	blocking_cells = seen


static func category_index(value: StringName) -> int:
	var normalized: StringName = StringName(String(CATEGORY_ALIASES.get(value, String(value))))
	var index: int = CATEGORY_IDS.find(normalized)
	return index if index >= 0 else CATEGORY_IDS.find(&"other")


static func category_label(value: StringName) -> String:
	return CATEGORY_LABELS[category_index(value)]


static func category_rank(value: StringName) -> int:
	var normalized: StringName = StringName(String(CATEGORY_ALIASES.get(value, String(value))))
	var rank: int = CATEGORY_ORDER.find(normalized)
	return rank if rank >= 0 else CATEGORY_ORDER.size()


## 面板/列表里的短名：CV-E03_...__gate_r2_se -> gate_r2_se
func short_name() -> String:
	var title: String = display_name.strip_edges()
	if title.is_empty():
		title = String(id)
	if title.contains("__"):
		return title.split("__", true, 1)[1]
	var cut: int = title.find("_")
	if cut > 0 and cut <= 8 and title.substr(0, cut).contains("-"):
		return title.substr(cut + 1)
	return title


func _in_footprint(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < footprint.x and cell.y < footprint.y


## 该格是否阻挡 A*
func is_blocked(cell: Vector2i) -> bool:
	if not _in_footprint(cell):
		return false
	if blocking_mode == Blocking.ALL:
		return true
	if blocking_mode == Blocking.NONE:
		return false
	return blocking_cells.has(cell)


func blocking_count() -> int:
	if blocking_mode == Blocking.ALL:
		return footprint.x * footprint.y
	if blocking_mode == Blocking.NONE:
		return 0
	return blocking_cells.size()


## 返回阻止保存的问题列表；空数组表示通过
func validate() -> Array[String]:
	var errors: Array[String] = []
	if String(id).strip_edges().is_empty():
		errors.append("ID 不能为空")
	if display_name.strip_edges().is_empty():
		errors.append("名称不能为空")
	if texture_path.strip_edges().is_empty():
		errors.append("PNG 路径不能为空")
	if footprint.x < 1 or footprint.y < 1:
		errors.append("占地范围至少 1×1")
	if art_size.x <= 0.0 or art_size.y <= 0.0:
		errors.append("立牌尺寸必须大于 0")
	if blocking_mode == Blocking.MASK:
		for cell: Vector2i in blocking_cells:
			if not _in_footprint(cell):
				errors.append("阻挡格 (%d,%d) 超出占地范围" % [cell.x, cell.y])
				break
	return errors


func clone_def() -> StaticAssetDef:
	var copy: StaticAssetDef = duplicate(true) as StaticAssetDef
	return copy
