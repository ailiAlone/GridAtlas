class_name GridDefs
## 全局网格定义：枚举与颜色表。
## 工具面板的按钮 id、MapData 的存储值、网格绘制的颜色，都以这里为唯一标准。


enum Land { NONE, GRASS, SAND, WASTELAND, SNOW, SWAMP, ICE }
enum Road { NONE, DIRT, GRAVEL, STONE_BRICK }
enum Water { NONE, SHALLOW, DEEP }
enum Flow { NONE, NW, N, NE, W, CENTER, E, SW, S, SE }


# 与 grid_tools.tscn 中按钮 StyleBoxFlat 的颜色保持一致
# 与 grid_tools.tscn 中按钮 StyleBoxFlat 的颜色保持一致
# （按钮样式是静态场景资源，不能引用常量；改色时两边同步）
const LAND_COLORS: Dictionary = {
	Land.GRASS: Color(0.42, 0.745, 0.348, 1),
	Land.SAND: Color(0.91, 0.82, 0.54, 1),
	Land.WASTELAND: Color(0.58, 0.5, 0.39, 1),
	Land.SNOW: Color(0.93, 0.95, 0.97, 1),
	Land.SWAMP: Color(0.33, 0.42, 0.25, 1),
	Land.ICE: Color(0.66, 0.847, 0.91, 1),
}

const ROAD_COLORS: Dictionary = {
	Road.DIRT: Color(0.65, 0.486, 0.32, 1),
	Road.GRAVEL: Color(0.65, 0.65, 0.65, 1),
	Road.STONE_BRICK: Color(0.44, 0.486, 0.522, 1),
}

const WATER_COLORS: Dictionary = {
	Water.SHALLOW: Color(0.43, 0.776, 0.91, 1),
	Water.DEEP: Color(0.17, 0.38, 0.6, 1),
}

## 山体在俯视编辑画布上的颜色：和陆地/水域/道路都拉开
const MOUNTAIN_COLOR: Color = Color(0.27, 0.27, 0.30, 1)


# Flow 枚举 <-> 方向向量（Godot 2D 坐标系：+x 向右，+y 向下，北为 -y）
const FLOW_VECTORS: Dictionary = {
	Flow.NW: Vector2i(-1, -1), Flow.N: Vector2i(0, -1), Flow.NE: Vector2i(1, -1),
	Flow.W: Vector2i(-1, 0), Flow.CENTER: Vector2i(0, 0), Flow.E: Vector2i(1, 0),
	Flow.SW: Vector2i(-1, 1), Flow.S: Vector2i(0, 1), Flow.SE: Vector2i(1, 1),
}


# 中文名称表：控制台输出 / UI 显示用
const LAYER_NAMES: Dictionary = {
	&"land": "陆地",
	&"road": "道路",
	&"water": "水域",
	&"flow": "流向",
	&"mountain": "山体",
	&"elevation": "高程",
	&"bridge": "桥",
}

const LAND_NAMES: Dictionary = {
	Land.NONE: "无",
	Land.GRASS: "草地",
	Land.SAND: "沙地",
	Land.WASTELAND: "荒地",
	Land.SNOW: "雪地",
	Land.SWAMP: "沼泽",
	Land.ICE: "冰面",
}

const ROAD_NAMES: Dictionary = {
	Road.NONE: "无",
	Road.DIRT: "土路",
	Road.GRAVEL: "碎石路",
	Road.STONE_BRICK: "石砖路",
}

const WATER_NAMES: Dictionary = {
	Water.NONE: "无",
	Water.SHALLOW: "浅水",
	Water.DEEP: "深水",
}


static func flow_vector(flow: int) -> Vector2i:
	return FLOW_VECTORS.get(flow, Vector2i.ZERO)


static func flow_from_vector(v: Vector2i) -> int:
	for flow: int in FLOW_VECTORS:
		if FLOW_VECTORS[flow] == v:
			return flow
	return Flow.NONE


## 高度显示文本：整数不带小数，其余保留两位
static func height_text(value: float) -> String:
	if absf(value - roundf(value)) < 0.001:
		return str(int(roundf(value)))
	return "%.2f" % value
