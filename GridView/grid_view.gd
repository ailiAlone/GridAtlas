class_name GridView
extends Control
## 网格视图（画布组件）：单一 Control 承担画布全部职责——
## 绘制地图各图层与网格线、绘制边框游标、处理鼠标绘制/悬停、
## 按 COVER 缩放比撑开自身尺寸让外层 ScrollContainer 产生滚动条。
##
## 用法：作为 ScrollContainer 的子节点实例化（Main.tscn 画布区）。
## mouse_filter = PASS：未消费的事件（滚轮）上抛给 ScrollContainer 滚动。

signal area_painted(area: Rect2i, erase: bool)  # 涂画/矩形填充统一上报：左上角格子 + 格子数尺寸
signal cell_hovered(cell: Vector2i)  # 移出网格时上报 (-1, -1)


const EMPTY_COLOR: Color = Color(0.16, 0.16, 0.16, 1)
const BAR: float = 10.0  # 游标条厚度（屏幕像素，不随缩放变化）
const BAR_BG: Color = Color(1, 1, 1, 0.08)
const BAR_MARK: Color = Color(1, 1, 1, 0.9)

@export var cell_size: float = 16.0:
	set(value):
		cell_size = maxf(4.0, value)
		queue_redraw()

var map: MapData
var brush_layer: StringName = &"land"
var brush_value: int = GridDefs.Land.GRASS
var zoom: float = 1.0
var elevation_mode: bool = false  # 高程视图：格子填色改为红绿归一化的高度，不显示地形
var brush_size: int = 1  # 笔刷边长：1=1×1，2=2×2...（悬停格为左上角，向右下扩展）
var rect_mode: bool = false  # 矩形填充模式：按下拖动框选，松开整块填充
var big_panel: bool = true   # 大面板模式（COVER 可编辑）；false=小面板（CONTAIN 整图只读）

var _dragging: bool = false
var _erasing: bool = false
var _last_cell: Vector2i = Vector2i(-1, -1)
var _hover_cell: Vector2i = Vector2i(-1, -1)
var _rect_dragging: bool = false
var _rect_anchor: Vector2i = Vector2i(-1, -1)
var _rect_current: Vector2i = Vector2i(-1, -1)

@onready var scroll: ScrollContainer = get_parent() as ScrollContainer


func _ready() -> void:
	if scroll != null:
		scroll.resized.connect(refresh)
	refresh.call_deferred()


# ---------- 对外接口 ----------

func set_map(data: MapData) -> void:
	map = data
	refresh()


func set_brush(layer: StringName, value: int) -> void:
	brush_layer = layer
	brush_value = value


## 切换 高程视图（true：红绿归一化显示高度）/ 普通视图（false：地形各图层）
func set_elevation_mode(on: bool) -> void:
	elevation_mode = on
	queue_redraw()


func set_brush_size(size: int) -> void:
	brush_size = maxi(1, size)
	queue_redraw()


## 矩形填充模式：true 时按下拖动是框选，松开把整块矩形交给外部填充
func set_rect_mode(on: bool) -> void:
	rect_mode = on
	_rect_dragging = false
	queue_redraw()


## 轮换入口：big=true 大面板（COVER + 滚动 + 可编辑），false 小面板（CONTAIN 整图只读）
func set_panel_mode(big: bool) -> void:
	big_panel = big
	set_anchors_preset(Control.PRESET_TOP_LEFT)  # 小面板手动控制 position/size，不能挂拉伸锚点；容器场景不受影响
	_dragging = false
	_last_cell = Vector2i(-1, -1)
	_hover_cell = Vector2i(-1, -1)
	mouse_filter = MOUSE_FILTER_PASS if big else MOUSE_FILTER_IGNORE
	refresh()


func get_content_size() -> Vector2:
	if map != null:
		return Vector2(map.grid_size) * cell_size
	return Vector2.ZERO


## 大面板：COVER 按滚动区重算缩放并撑开尺寸产生滚动条；小面板：CONTAIN 整图缩放居中
func refresh() -> void:
	var content: Vector2 = get_content_size()
	if content.x <= 0.0 or content.y <= 0.0:
		return
	var view: Vector2
	if big_panel:
		if scroll == null:
			return
		view = scroll.size
		zoom = maxf(view.x / content.x, view.y / content.y)
		custom_minimum_size = content * zoom
		size = content * zoom
	elif get_parent() is Control:
		view = (get_parent() as Control).size
		zoom = minf(view.x / content.x, view.y / content.y)
		var drawn: Vector2 = content * zoom
		position = ((view - drawn) * 0.5).floor()
		size = drawn
	queue_redraw()


# ---------- 坐标换算 ----------

## 一个格子在屏幕上的边长
func step() -> float:
	return cell_size * zoom


func pixel_to_cell(point: Vector2) -> Vector2i:
	return Vector2i((point / step()).floor())


# ---------- 绘制 ----------

func _draw() -> void:
	if map == null:
		return
	if elevation_mode:
		_draw_elevation()
	else:
		var s: float = step()
		for y in map.grid_size.y:
			for x in map.grid_size.x:
				var cell: Vector2i = Vector2i(x, y)
				var rect: Rect2 = Rect2(Vector2(cell) * s, Vector2(s, s))
				_draw_cell(cell, rect)
	_draw_grid_lines()
	_draw_cursor_bars()
	_draw_previews()


func _draw_cell(cell: Vector2i, rect: Rect2) -> void:
	var s: float = step()
	draw_rect(rect, GridDefs.LAND_COLORS.get(map.get_land(cell), EMPTY_COLOR))

	var water: int = map.get_water(cell)
	if water != GridDefs.Water.NONE:
		var c: Color = GridDefs.WATER_COLORS.get(water, Color.WHITE)
		c.a = 0.85
		draw_rect(rect, c)

	var road: int = map.get_road(cell)
	if road != GridDefs.Road.NONE:
		draw_rect(rect.grow(-s * 0.2), GridDefs.ROAD_COLORS.get(road, Color.WHITE))

	var flow: int = map.get_flow(cell)
	if water != GridDefs.Water.NONE and flow != GridDefs.Flow.NONE:
		_draw_flow(flow, rect.get_center())

	var elevation: float = map.get_height(cell)
	if elevation > 1.001 and s >= 12.0:  # 1 是默认高程，不标注
		var font_size: int = clampi(int(s * 0.5), 8, 16)
		draw_string(ThemeDB.fallback_font, rect.position + Vector2(2, s * 0.5 + font_size * 0.5), _height_text(elevation),
			HORIZONTAL_ALIGNMENT_LEFT, s - 2, font_size, Color(0, 0, 0, 0.8))


## 高程显示文本：整数不带小数，其余保留两位
func _height_text(value: float) -> String:
	if absf(value - roundf(value)) < 0.001:
		return str(int(roundf(value)))
	return "%.2f" % value


## 高程视图：按全图实际最高高程归一化，低=绿、高=红；0 只会出现在旧存档里，显示深灰
func _draw_elevation() -> void:
	var s: float = step()
	var max_e: float = maxf(map.max_height(), 1.0)
	for y in map.grid_size.y:
		for x in map.grid_size.x:
			var cell: Vector2i = Vector2i(x, y)
			var rect: Rect2 = Rect2(Vector2(cell) * s, Vector2(s, s))
			var e: float = map.get_height(cell)
			if e > 0.001:
				var t: float = clampf(e / max_e, 0.0, 1.0)
				draw_rect(rect, Color(t, 1.0 - t, 0.0))
			else:
				draw_rect(rect, EMPTY_COLOR)
			if e > 1.001 and s >= 12.0:  # 1 是默认高程，不标注
				var font_size: int = clampi(int(s * 0.5), 8, 16)
				draw_string(ThemeDB.fallback_font, rect.position + Vector2(2, s * 0.5 + font_size * 0.5), _height_text(e),
					HORIZONTAL_ALIGNMENT_LEFT, s - 2, font_size, Color(1, 1, 1, 0.9))


func _draw_flow(flow: int, center: Vector2) -> void:
	var s: float = step()
	if flow == GridDefs.Flow.CENTER:
		draw_circle(center, s * 0.12, Color.WHITE)
		return
	var dir: Vector2 = Vector2(GridDefs.flow_vector(flow)).normalized()
	var perp: Vector2 = dir.orthogonal()
	var tip: Vector2 = center + dir * s * 0.38
	var p1: Vector2 = center - dir * s * 0.1 + perp * s * 0.22
	var p2: Vector2 = center - dir * s * 0.1 - perp * s * 0.22
	var points: PackedVector2Array = PackedVector2Array([tip, p1, p2])
	draw_polygon(points, PackedColorArray([Color.WHITE]))
	draw_polyline(PackedVector2Array([tip, p1, p2, tip]), Color(0, 0, 0, 0.5), 1.0)


func _draw_grid_lines() -> void:
	var line: Color = Color(0, 0, 0, 0.18)
	var s: float = step()
	var w: float = map.grid_size.x * s
	var h: float = map.grid_size.y * s
	for i in map.grid_size.x + 1:
		var x: float = i * s
		draw_line(Vector2(x, 0), Vector2(x, h), line)
	for j in map.grid_size.y + 1:
		var y: float = j * s
		draw_line(Vector2(0, y), Vector2(w, y), line)
	draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), Color(0, 0, 0, 0.5), false, 1.0)


## 上、左边框的游标条：底条 + 悬停格所在列/行的高亮段
func _draw_cursor_bars() -> void:
	draw_rect(Rect2(0, 0, size.x, BAR), BAR_BG)
	draw_rect(Rect2(0, 0, BAR, size.y), BAR_BG)
	if _hover_cell.x >= 0:
		var s: float = step()
		draw_rect(Rect2(_hover_cell.x * s, 0, s, BAR), BAR_MARK)
		draw_rect(Rect2(0, _hover_cell.y * s, BAR, s), BAR_MARK)


## 操作预览：大笔刷（>1）的落笔范围框；矩形模式的拖选框
func _draw_previews() -> void:
	var s: float = step()
	if rect_mode and _rect_dragging:
		var area: Rect2i = _rect_area()
		var rect: Rect2 = Rect2(Vector2(area.position) * s, Vector2(area.size) * s)
		draw_rect(rect, Color(1, 1, 1, 0.15))
		draw_rect(rect, Color(1, 1, 1, 0.9), false, 2.0)
	elif not rect_mode and _hover_cell.x >= 0 and brush_size > 1:
		draw_rect(Rect2(Vector2(_hover_cell) * s, Vector2(s * brush_size, s * brush_size)), Color(1, 1, 1, 0.9), false, 2.0)


# ---------- 输入 ----------

func _gui_input(event: InputEvent) -> void:
	if map == null:
		return
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		if rect_mode:
			_handle_rect_button(event)
		elif event.pressed:
			_dragging = true
			_erasing = event.button_index == MOUSE_BUTTON_RIGHT
			_last_cell = Vector2i(-1, -1)
			_paint_under_mouse()
		else:
			_dragging = false
		accept_event()  # 消费按钮，避免 ScrollContainer 当成拖拽滚动
	elif event is InputEventMouseMotion:
		var cell: Vector2i = pixel_to_cell(get_local_mouse_position())
		_hover_cell = cell if map.in_bounds(cell) else Vector2i(-1, -1)
		cell_hovered.emit(_hover_cell)
		queue_redraw()
		if _dragging:
			_paint_under_mouse()
		elif rect_mode and _rect_dragging:
			_rect_current = _clamped_cell(cell)
			queue_redraw()


func _paint_under_mouse() -> void:
	var cell: Vector2i = pixel_to_cell(get_local_mouse_position())
	if not map.in_bounds(cell) or cell == _last_cell:
		return
	if _last_cell.x >= 0:
		# 快速拖动时沿路径补齐跳过的锚点格，避免拉出断点
		var delta: Vector2i = cell - _last_cell
		var steps: int = maxi(absi(delta.x), absi(delta.y))
		for i in range(1, steps):
			var mid: Vector2i = _last_cell + Vector2i((Vector2(delta) * (float(i) / float(steps))).round())
			_emit_area(mid)
	_last_cell = cell
	_emit_area(cell)


## 以 anchor 为左上角涂 brush_size×brush_size 的区域
func _emit_area(anchor: Vector2i) -> void:
	area_painted.emit(Rect2i(anchor, Vector2i(brush_size, brush_size)), _erasing)


## 矩形模式：按下记录起点，松开把拖出的矩形（含起终点）交给外部填充
func _handle_rect_button(event: InputEventMouseButton) -> void:
	if event.pressed:
		_rect_dragging = true
		_erasing = event.button_index == MOUSE_BUTTON_RIGHT
		_rect_anchor = _clamped_cell(pixel_to_cell(get_local_mouse_position()))
		_rect_current = _rect_anchor
		queue_redraw()
	elif _rect_dragging:
		_rect_dragging = false
		area_painted.emit(_rect_area(), _erasing)
		queue_redraw()


func _clamped_cell(cell: Vector2i) -> Vector2i:
	return Vector2i(clampi(cell.x, 0, map.grid_size.x - 1), clampi(cell.y, 0, map.grid_size.y - 1))


## 起点/终点两格组成的完整矩形（含两端）
func _rect_area() -> Rect2i:
	var a: Vector2i = _clamped_cell(_rect_anchor)
	var b: Vector2i = _clamped_cell(_rect_current)
	return Rect2i(Vector2i(mini(a.x, b.x), mini(a.y, b.y)), Vector2i(absi(a.x - b.x) + 1, absi(a.y - b.y) + 1))
