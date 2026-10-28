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
signal stroke_started  # 一次落笔开始（main 在此压撤销快照）
signal stroke_ended    # 一次落笔结束（松开按键）


const EMPTY_COLOR: Color = Color(0.16, 0.16, 0.16, 1)
const BAR: float = 10.0  # 游标条厚度（屏幕像素，不随缩放变化）
const BAR_BG: Color = Color(1, 1, 1, 0.08)
const BAR_MARK: Color = Color(1, 1, 1, 0.9)

# ---------- 格子填色缓存 ----------
# 逐格 draw_rect 在大图（128²+）上每笔要重录几万条绘制指令，是涂画卡顿的主因之一。
# 改为把每格填色光栅化进一张 ImageTexture（每格 4×4 纹素），_draw 只画这一张纹理；
# 笔刷落点只重画笔刷区域的纹素，再整图一次上传（create_from_data 是 C++ 侧拷贝，
# 远快于逐纹素写）。流向箭头/高程数字数量稀疏，仍走矢量指令，用稀疏列表登记。
const CACHE_RES: int = 4  # 每格纹素数：道路内缩块需要 ≥4 才画得出来
const PropsData = preload("res://GridData/props_data.gd")

var cachebytes: PackedByteArray = PackedByteArray()
var cachetexture: ImageTexture
var cache_elev_max: float = 1.0  # 高程视图的归一化上限（整图重铺时刷新）
var _flow_cells: Array[Vector2i] = []   # 有水面+流向的格子（箭头叠加）
var _label_cells: Array[Vector2i] = []  # 高程 > 1 需标数字的格子

@export var cell_size: float = 16.0:
	set(value):
		cell_size = maxf(4.0, value)
		queue_redraw()

var map: MapData
var props   # PropsData（地图边车；main 注入，本视图不拥有）
var prop_asset_preview: StringName = &""  # 当前选中的资源定义 id；空串=不画落点预览
var prop_asset_rotation: int = 0          # 资源落点预览方向：0=横向 / 1=竖向
var brush_layer: StringName = &"land"
var brush_value: int = GridDefs.Land.GRASS
var zoom: float = 1.0
var elevation_mode: bool = false  # 高程视图：格子填色改为红绿归一化的高度，不显示地形
var brush_size: int = 1  # 笔刷边长：1=1×1，2=2×2...（悬停格为左上角，向右下扩展）
var rect_mode: bool = false  # 矩形填充模式：按下拖动框选，松开整块填充
var big_panel: bool = true   # 大面板模式（COVER 可编辑）；false=小面板（CONTAIN 整图只读）

var _dragging: bool = false
var _erasing: bool = false
var _stroke_active: bool = false
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
	_rebuild_cache()
	refresh()


func set_brush(layer: StringName, value: int) -> void:
	brush_layer = layer
	brush_value = value


## 注入物件层（地图边车）。只画图标，不参与格子填色缓存。
func set_props(data) -> void:
	props = data
	queue_redraw()


## 选中资源后的落点预览（用占地范围 + 阻挡掩码画；空串清除）
func set_asset_preview(asset_id: StringName, rot: int = 0) -> void:
	prop_asset_preview = asset_id
	prop_asset_rotation = posmod(rot, 2)
	queue_redraw()


## 当前鼠标悬停格（不在网格内时返回 (-1,-1)）；main 的 R 旋转用
func hover_cell() -> Vector2i:
	return _hover_cell


## 切换 高程视图（true：红绿归一化显示高度）/ 普通视图（false：地形各图层）
func set_elevation_mode(on: bool) -> void:
	elevation_mode = on
	_rebuild_cache()
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
	_stroke_active = false
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
	var s: float = step()
	if cachetexture != null:
		draw_texture_rect(cachetexture, Rect2(Vector2.ZERO, Vector2(map.grid_size) * s), false)
	# 稀疏叠加：流向箭头（仅普通视图）+ 高程数字，只遍历登记过的格子
	for cell: Vector2i in _flow_cells:
		_draw_flow(map.get_flow(cell), (Vector2(cell) + Vector2(0.5, 0.5)) * s)
	if s >= 12.0:
		var font_size: int = clampi(int(s * 0.5), 8, 16)
		var text_color: Color = Color(1, 1, 1, 0.9) if elevation_mode else Color(0, 0, 0, 0.8)
		for cell: Vector2i in _label_cells:
			var rect: Rect2 = Rect2(Vector2(cell) * s, Vector2(s, s))
			draw_string(ThemeDB.fallback_font, rect.position + Vector2(2, s * 0.5 + font_size * 0.5),
				GridDefs.height_text(map.get_height(cell)), HORIZONTAL_ALIGNMENT_LEFT, s - 2, font_size, text_color)
	_draw_props()
	_draw_grid_lines()
	_draw_cursor_bars()
	_draw_previews()


# ---------- 物件 ----------

## 只画视野内的资源实例（大面板按滚动位置裁剪；小面板整图）
func _draw_props() -> void:
	if props == null or map == null:
		return
	var s: float = step()
	var visible: Rect2 = _visible_cell_rect()
	for i in props.count():
		var cell: Vector2i = props.cell_at(i)
		var fp: Rect2i = props.footprint_at(i)
		var area: Rect2 = Rect2(Vector2(cell), Vector2(fp.size))
		if not visible.intersects(area):
			continue
		_draw_asset_icon(props.asset_id_at(i), Vector2(cell) * s, fp.size,
			props.rotation_at(i), s, 1.0)


func _visible_cell_rect() -> Rect2:
	if not big_panel or scroll == null:
		return Rect2(Vector2(-4.0, -4.0), Vector2(map.grid_size) + Vector2(8.0, 8.0))
	var s: float = step()
	if s <= 0.0:
		return Rect2(Vector2.ZERO, Vector2(map.grid_size))
	var origin: Vector2 = Vector2(scroll.scroll_horizontal, scroll.scroll_vertical) / s
	return Rect2(origin - Vector2(2.0, 2.0), scroll.size / s + Vector2(4.0, 4.0))


## 静态资源：俯视图里只做识别用——占地范围 + 一张缩小的 PNG + 门柱等阻挡格标记。
## 真正的 45° 立牌在 GamePreview 里，这里不按俯角变形；rot 只影响占地和掩码。
func _draw_asset_icon(asset_id: StringName, origin: Vector2, fp: Vector2i, rot: int,
		s: float, alpha: float) -> void:
	var def: StaticAssetDef = props.asset(asset_id) if props != null else null
	if def == null:
		var missing: Rect2 = Rect2(origin, Vector2(fp) * s)
		draw_rect(missing, Color(0.85, 0.25, 0.75, 0.18 * alpha), true)
		draw_rect(missing, Color(0.95, 0.35, 0.85, 0.8 * alpha), false, 1.0)
		return
	var rect: Rect2 = Rect2(origin, Vector2(fp) * s)
	draw_rect(rect, Color(0.95, 0.86, 0.55, 0.10 * alpha), true)
	_draw_asset_texture(def, origin, fp, s, 0.86 * alpha, rot == 1)
	if def.blocking_mode == StaticAssetDef.Blocking.MASK and s >= 10.0:
		for local: Vector2i in PropsData.rotated_blocking_cells(def, rot):
			var cellrect: Rect2 = Rect2(origin + Vector2(local) * s, Vector2(s, s))
			draw_rect(cellrect.grow(-1.0), Color(0.95, 0.30, 0.24, 0.20 * alpha), true)
			draw_rect(cellrect.grow(-1.0), Color(1.0, 0.42, 0.32, 0.75 * alpha), false, 1.0)
	draw_rect(rect, Color(0.95, 0.85, 0.50, 0.70 * alpha), false, 1.0)


## 把资源 PNG 按比例塞进占地范围框（不拉伸），作为俯视图图标。
## flip_x：竖向资源水平镜像缩略图，和 45° 立牌的方向保持一致。
func _draw_asset_texture(def: StaticAssetDef, origin: Vector2, fp: Vector2i, s: float,
		alpha: float, flip_x: bool = false) -> void:
	var tex: Texture2D = StaticAssetStore.texture_for(def)
	if tex == null:
		return
	var rect: Rect2 = Rect2(origin, Vector2(fp) * s)
	var tw: float = maxf(float(tex.get_width()), 1.0)
	var th: float = maxf(float(tex.get_height()), 1.0)
	var fit: float = minf(rect.size.x * 0.92 / tw, rect.size.y * 0.92 / th)
	var drawn: Vector2 = Vector2(tw, th) * fit
	if drawn.x < 2.0 or drawn.y < 2.0:
		return
	if flip_x:
		draw_set_transform(rect.get_center(), 0.0, Vector2(-1.0, 1.0))
		draw_texture_rect(tex, Rect2(-drawn * 0.5, drawn), false, Color(1, 1, 1, alpha))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	else:
		draw_texture_rect(tex, Rect2(rect.get_center() - drawn * 0.5, drawn), false,
			Color(1, 1, 1, alpha))


func _brush_center() -> Vector2i:
	var half: int = int(brush_size * 0.5)
	return _hover_cell + Vector2i(half, half)


## 资源落点预览：占地范围以鼠标为中心（奇数边）或左上角（偶数边）。
## 红格=真正阻挡（门柱），绿格=可通行（门洞），外框绿/红表示能不能放。
func _draw_asset_ghost() -> void:
	if props == null:
		return
	var def: StaticAssetDef = props.asset(prop_asset_preview)
	if def == null:
		return
	var rot: int = prop_asset_rotation
	var fp: Vector2i = PropsData.rotated_footprint(def.footprint, rot)
	var blocked: Array[Vector2i] = PropsData.rotated_blocking_cells(def, rot)
	var cell: Vector2i = PropsData.anchor_for(fp, _brush_center())
	var ok: bool = _asset_placeable(cell, fp)
	var s: float = step()
	var origin: Vector2 = Vector2(cell) * s
	for y in fp.y:
		for x in fp.x:
			var local: Vector2i = Vector2i(x, y)
			var cellrect: Rect2 = Rect2(origin + Vector2(local) * s, Vector2(s, s))
			var fill: Color = Color(0.88, 0.30, 0.24, 0.16) if blocked.has(local) \
				else Color(0.30, 0.72, 0.42, 0.12)
			draw_rect(cellrect, fill, true)
	_draw_asset_texture(def, origin, fp, s, 0.52, prop_asset_rotation == 1)
	for y in fp.y:
		for x in fp.x:
			var local2: Vector2i = Vector2i(x, y)
			var cellrect2: Rect2 = Rect2(origin + Vector2(local2) * s, Vector2(s, s))
			var edge: Color = Color(1.0, 0.42, 0.32, 0.85) if blocked.has(local2) \
				else Color(0.38, 0.94, 0.55, 0.50)
			draw_rect(cellrect2, edge, false, 1.0)
	var outer: Rect2 = Rect2(origin, Vector2(fp) * s)
	var border: Color = Color(0.35, 1.0, 0.45, 0.95) if ok else Color(1.0, 0.30, 0.24, 0.95)
	draw_rect(outer, border, false, 2.0)


func _asset_placeable(cell: Vector2i, fp: Vector2i) -> bool:
	if map == null:
		return false
	for y in range(cell.y, cell.y + fp.y):
		for x in range(cell.x, cell.x + fp.x):
			var c: Vector2i = Vector2i(x, y)
			if not map.in_bounds(c):
				return false
			if map.get_water(c) != GridDefs.Water.NONE:
				return false
	if props != null and not props.can_place_fp(fp, cell, map.grid_size):
		return false
	return true


# ---------- 格子填色缓存 ----------

## 笔刷落点：只重画区域内格子的纹素，整图一次上传；稀疏叠加列表同步增删
func sync_cell_area(area: Rect2i) -> void:
	if map == null or cachetexture == null:
		return
	var clipped: Rect2i = area.intersection(Rect2i(Vector2i.ZERO, map.grid_size))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return
	if elevation_mode:
		# 高程配色按全图最大值归一化，改动后简单起见整图重铺（该模式用于观察，一般不在里面涂画）
		_rebuild_cache()
		queue_redraw()
		return
	_remove_sparse(_flow_cells, clipped)
	_remove_sparse(_label_cells, clipped)
	for y in range(clipped.position.y, clipped.end.y):
		for x in range(clipped.position.x, clipped.end.x):
			_rasterize_cell(Vector2i(x, y))
	var tw: int = map.grid_size.x * CACHE_RES
	var image: Image = Image.create_from_data(tw, map.grid_size.y * CACHE_RES, false, Image.FORMAT_RGBA8, cachebytes)
	if cachetexture == null or cachetexture.get_width() != tw or cachetexture.get_height() != map.grid_size.y * CACHE_RES:
		cachetexture = ImageTexture.create_from_image(image)
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	else:
		cachetexture.update(image)
	queue_redraw()


## 整图重铺缓存（换图/改尺寸/撤销恢复/切高程视图时）
func _rebuild_cache() -> void:
	if map == null:
		return
	var w: int = map.grid_size.x
	var h: int = map.grid_size.y
	var tw: int = w * CACHE_RES
	cachebytes.resize(tw * h * CACHE_RES * 4)
	cache_elev_max = maxf(map.max_height(), 1.0)
	_flow_cells.clear()
	_label_cells.clear()
	for y in h:
		for x in w:
			_rasterize_cell(Vector2i(x, y))
	var image: Image = Image.create_from_data(tw, h * CACHE_RES, false, Image.FORMAT_RGBA8, cachebytes)
	if cachetexture == null or cachetexture.get_width() != tw or cachetexture.get_height() != h * CACHE_RES:
		cachetexture = ImageTexture.create_from_image(image)
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	else:
		cachetexture.update(image)


## 把一个格子的填色写进缓存字节流，并登记稀疏叠加（箭头/高程数字）
func _rasterize_cell(cell: Vector2i) -> void:
	var w: int = map.grid_size.x
	var tw: int = w * CACHE_RES
	var color: Color
	var water: int = GridDefs.Water.NONE
	var road: int = GridDefs.Road.NONE
	if elevation_mode:
		var e: float = map.get_height(cell)
		if e > 0.001:
			var t: float = clampf(e / cache_elev_max, 0.0, 1.0)
			color = Color(t, 1.0 - t, 0.0)
		else:
			color = EMPTY_COLOR
	else:
		water = map.get_water(cell)
		road = map.get_road(cell)
		color = GridDefs.LAND_COLORS.get(map.get_land(cell), EMPTY_COLOR)
		if water != GridDefs.Water.NONE:
			var wc: Color = GridDefs.WATER_COLORS.get(water, Color.WHITE)
			color = Color(color.r * 0.15 + wc.r * 0.85, color.g * 0.15 + wc.g * 0.85,
				color.b * 0.15 + wc.b * 0.85, 1.0)
	var base: int = (cell.y * CACHE_RES * tw + cell.x * CACHE_RES) * 4
	var r8: int = color.r8
	var g8: int = color.g8
	var b8: int = color.b8
	for ry in CACHE_RES:
		var row: int = base + ry * tw * 4
		for rx in CACHE_RES:
			var p: int = row + rx * 4
			cachebytes[p] = r8
			cachebytes[p + 1] = g8
			cachebytes[p + 2] = b8
			cachebytes[p + 3] = 255
	# 道路内缩块：不透明盖在填色上（纹素 4 时留 1 纹素边距）
	if not elevation_mode and road != GridDefs.Road.NONE:
		var rc: Color = GridDefs.ROAD_COLORS.get(road, Color.WHITE)
		var rr8: int = rc.r8
		var rg8: int = rc.g8
		var rb8: int = rc.b8
		for ry in range(1, CACHE_RES - 1):
			var rrow: int = base + ry * tw * 4
			for rx in range(1, CACHE_RES - 1):
				var p: int = rrow + rx * 4
				cachebytes[p] = rr8
				cachebytes[p + 1] = rg8
				cachebytes[p + 2] = rb8
	# 稀疏叠加登记
	if not elevation_mode and water != GridDefs.Water.NONE and map.get_flow(cell) != GridDefs.Flow.NONE:
		_flow_cells.append(cell)
	if map.get_height(cell) > 1.001:
		_label_cells.append(cell)


## 从稀疏列表中移除区域内的旧记录（区域重画后会重新登记）
func _remove_sparse(list: Array[Vector2i], area: Rect2i) -> void:
	for i in range(list.size() - 1, -1, -1):
		var c: Vector2i = list[i]
		if c.x >= area.position.x and c.x < area.end.x and c.y >= area.position.y and c.y < area.end.y:
			list.remove_at(i)


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


## 操作预览：资源落点框；大笔刷（>1）的落笔范围框；矩形模式的拖选框
func _draw_previews() -> void:
	var s: float = step()
	if brush_layer == &"prop" and prop_asset_preview != &"" and _hover_cell.x >= 0 \
			and not (rect_mode and _rect_dragging):
		_draw_asset_ghost()
		return
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
		if event.pressed:
			# 只在地图内的按下才算一次落笔；快照在真正修改之前交给 main
			_stroke_active = map.in_bounds(pixel_to_cell(get_local_mouse_position()))
			if _stroke_active:
				stroke_started.emit()
		if rect_mode:
			_handle_rect_button(event)
		elif event.pressed:
			_dragging = true
			_erasing = event.button_index == MOUSE_BUTTON_RIGHT
			_last_cell = Vector2i(-1, -1)
			_paint_under_mouse()
		else:
			_dragging = false
		if not event.pressed and _stroke_active:
			_stroke_active = false
			stroke_ended.emit()
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
