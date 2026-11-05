class_name AssetMaskEditor
extends Control
## 占地范围与阻挡格编辑器（45° 视角）。
##
## 网格按游戏固定相机（yaw=135°、pitch=45°）投影成斜四边形。
## PNG 保持原始比例直立显示，默认不自动扭曲；左右两个圆点可单独抬高/压低，
## 让图片单侧平滑拉伸，去对齐网格。单侧最多抬到一整张立牌高度。
## 整体缩放由表单里的「立牌宽度」与「高度拉伸」控制。
## 红色=实际阻挡（门柱/墙），绿色=可通行（门洞）；只有 blocking_mode=MASK 时允许点格。

signal mask_changed
signal offset_changed(offset: Vector2)
signal lift_changed

const DEF = preload("res://Assets/static_assets/static_asset_def.gd")
const YAW: float = 2.356194490192345    # 135°
const PITCH: float = 0.7853981633974483 # 45°
const PAD: float = 12.0
const TARGET_W: float = 400.0
const TARGET_H: float = 380.0
const MIN_VIEW_W: float = 420.0
const MIN_VIEW_H: float = 420.0
const MIN_SCALE: float = 24.0
const MAX_SCALE: float = 140.0
const FONT_SIZE: int = 11
const HANDLE_RADIUS: float = 7.0

var footprint: Vector2i = Vector2i.ONE
var blocking_cells: Array[Vector2i] = []
var blocking_mode: int = DEF.Blocking.ALL

var _texture: Texture2D
var _art_size: Vector2 = Vector2.ONE
var _art_lift: Vector2 = Vector2.ZERO
var _art_offset: Vector2 = Vector2.ZERO
var _art_quad: PackedVector2Array = PackedVector2Array()
var _painting: bool = false
var _paint_blocked: bool = true
var _hover: Vector2i = Vector2i(-1, -1)
var _drag_handle: int = -1
var _drag_start_y: float = 0.0
var _drag_start_lift: float = 0.0
var _move_dragging: bool = false
var _refit_locked: bool = false

# 投影缓存：screen = _origin + (p·rt, p·nfd·sinPitch) * _scale
var _rt: Vector2 = Vector2.ONE
var _nfd: Vector2 = Vector2.ONE
var _sin_pitch: float = 1.0
var _det: float = 1.0
var _scale: float = 40.0
var _origin: Vector2 = Vector2.ZERO
var _in_projection: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	resized.connect(_update_projection)
	mouse_exited.connect(_on_mouse_exited)
	_update_projection()


func set_data(fp: Vector2i, cells: Array[Vector2i], mode: int) -> void:
	footprint = Vector2i(maxi(fp.x, 1), maxi(fp.y, 1))
	blocking_mode = mode
	blocking_cells.clear()
	for cell: Vector2i in cells:
		if _in_bounds(cell) and not blocking_cells.has(cell):
			blocking_cells.append(cell)
	_update_projection()
	queue_redraw()


func set_footprint(fp: Vector2i) -> void:
	footprint = Vector2i(maxi(fp.x, 1), maxi(fp.y, 1))
	var kept: Array[Vector2i] = []
	for cell: Vector2i in blocking_cells:
		if _in_bounds(cell):
			kept.append(cell)
	blocking_cells = kept
	_update_projection()
	queue_redraw()


func set_blocking_mode(mode: int) -> void:
	blocking_mode = mode
	queue_redraw()


func set_texture(tex: Texture2D) -> void:
	_texture = tex
	_update_projection()
	queue_redraw()


func set_art_size(value: Vector2) -> void:
	_art_size = Vector2(maxf(value.x, 0.05), maxf(value.y, 0.05))
	_update_projection()
	queue_redraw()


func set_lift(value: Vector2) -> void:
	_art_lift = Vector2(
		clampf(value.x, -DEF.ART_LIFT_LIMIT, DEF.ART_LIFT_LIMIT),
		clampf(value.y, -DEF.ART_LIFT_LIMIT, DEF.ART_LIFT_LIMIT))
	_update_projection()
	queue_redraw()


func get_lift() -> Vector2:
	return _art_lift


func set_art_offset(value: Vector2) -> void:
	_art_offset = Vector2(clampf(value.x, -32.0, 32.0), clampf(value.y, -32.0, 32.0))
	_update_projection()
	queue_redraw()


func get_art_offset() -> Vector2:
	return _art_offset


func set_cells(cells: Array[Vector2i]) -> void:
	blocking_cells.clear()
	for cell: Vector2i in cells:
		if _in_bounds(cell) and not blocking_cells.has(cell):
			blocking_cells.append(cell)
	mask_changed.emit()
	queue_redraw()


func get_cells() -> Array[Vector2i]:
	return blocking_cells.duplicate()


func all_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in footprint.y:
		for x in footprint.x:
			out.append(Vector2i(x, y))
	return out


# ---------- 投影 ----------

## 用固定相机的 fd/rt 与本地点做正交斜视投影；与 GridAtlas 的公式一致。
## 网格和 PNG 各自独立：网格固定 45°，PNG 以立牌大小直立，顶部左右可单侧抬升。
## 投影包围盒（网格 + 图片）一起缩放适配预览区：1×1 会被放大，5×1 自动缩小。
func _update_projection() -> void:
	if _in_projection:
		return
	_in_projection = true
	var fd: Vector2 = Vector2(-sin(YAW), cos(YAW))
	_rt = Vector2(-fd.y, fd.x)
	_nfd = -fd
	_sin_pitch = sin(PITCH)
	_det = _rt.x * _nfd.y - _rt.y * _nfd.x

	var grid_min: Vector2 = Vector2(INF, INF)
	var grid_max: Vector2 = Vector2(-INF, -INF)
	for corner: Vector2 in _footprint_corners():
		var p: Vector2 = Vector2(corner.dot(_rt), corner.dot(_nfd) * _sin_pitch)
		grid_min = Vector2(minf(grid_min.x, p.x), minf(grid_min.y, p.y))
		grid_max = Vector2(maxf(grid_max.x, p.x), maxf(grid_max.y, p.y))
	var center: Vector2 = (grid_min + grid_max) * 0.5
	var art_center: Vector2 = center + _art_offset

	if not _refit_locked:
		var min_all: Vector2 = grid_min
		var max_all: Vector2 = grid_max
		var art_min: Vector2 = Vector2.ZERO
		var art_max: Vector2 = Vector2.ZERO
		if _texture != null:
			var art_w: float = _art_size.x
			var art_h: float = _art_size.y
			# 只按当前实际抬升量扩取景：上限调到 1 倍高度后，未拉伸的图片不会被缩得看不清
			var top_room: float = maxf(maxf(_art_lift.x, _art_lift.y), 0.0) * art_h
			var bottom_room: float = maxf(-minf(_art_lift.x, _art_lift.y), 0.0) * art_h
			art_min = Vector2(art_center.x - art_w * 0.5, art_center.y - art_h - top_room)
			art_max = Vector2(art_center.x + art_w * 0.5, art_center.y + bottom_room)
			min_all = Vector2(minf(min_all.x, art_min.x), minf(min_all.y, art_min.y))
			max_all = Vector2(maxf(max_all.x, art_max.x), maxf(max_all.y, art_max.y))

		var span: Vector2 = max_all - min_all
		_scale = clampf(minf(TARGET_W / maxf(span.x, 0.01), TARGET_H / maxf(span.y, 0.01)),
			MIN_SCALE, MAX_SCALE)
		var content: Vector2 = span * _scale
		var minimum: Vector2 = Vector2(
			maxf(content.x + PAD * 2.0, MIN_VIEW_W),
			maxf(content.y + PAD * 2.0, MIN_VIEW_H))
		custom_minimum_size = minimum
		# ScrollContainer 会把控件撑到视口大小：按实际 size 居中，而不是最小尺寸
		var view: Vector2 = Vector2(maxf(minimum.x, size.x), maxf(minimum.y, size.y))
		_origin = (view - content) * 0.5 - min_all * _scale

	_art_quad = PackedVector2Array()
	if _texture != null:
		var art_w2: float = _art_size.x
		var art_h2: float = _art_size.y
		var lift_l2: float = -_art_lift.x * art_h2
		var lift_r2: float = -_art_lift.y * art_h2
		var tl: Vector2 = Vector2(art_center.x - art_w2 * 0.5, art_center.y - art_h2 + lift_l2)
		var tr: Vector2 = Vector2(art_center.x + art_w2 * 0.5, art_center.y - art_h2 + lift_r2)
		var br: Vector2 = Vector2(art_center.x + art_w2 * 0.5, art_center.y + lift_r2)
		var bl: Vector2 = Vector2(art_center.x - art_w2 * 0.5, art_center.y + lift_l2)
		_art_quad = PackedVector2Array([
			tl * _scale + _origin, tr * _scale + _origin,
			br * _scale + _origin, bl * _scale + _origin,
		])
	_in_projection = false


## 结束一次拖动：解锁取景并按当前内容重新适配一次。
## 拖动期间冻结缩放/原点，避免抬一侧时另一侧被重新取景带跑。
func _unlock_refit() -> void:
	if not _refit_locked:
		return
	_refit_locked = false
	_update_projection()
	queue_redraw()


func _on_mouse_exited() -> void:
	if _drag_handle < 0 and not _move_dragging:
		return
	_drag_handle = -1
	_move_dragging = false
	_unlock_refit()


func _footprint_corners() -> Array[Vector2]:
	var w: float = float(footprint.x)
	var h: float = float(footprint.y)
	return [Vector2(0, 0), Vector2(w, 0), Vector2(0, h), Vector2(w, h)]


func _project(p: Vector2) -> Vector2:
	return _origin + Vector2(p.dot(_rt), p.dot(_nfd) * _sin_pitch) * _scale


func _cell_polygon(cell: Vector2i) -> PackedVector2Array:
	var x: float = float(cell.x)
	var y: float = float(cell.y)
	return PackedVector2Array([
		_project(Vector2(x, y)),
		_project(Vector2(x + 1.0, y)),
		_project(Vector2(x + 1.0, y + 1.0)),
		_project(Vector2(x, y + 1.0)),
	])


# ---------- 查询 ----------

func _in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < footprint.x and cell.y < footprint.y


func _is_blocked(cell: Vector2i) -> bool:
	if blocking_mode == DEF.Blocking.ALL:
		return true
	if blocking_mode == DEF.Blocking.NONE:
		return false
	return blocking_cells.has(cell)


## 屏幕点 -> 格子：把投影后的 (u, v) 反解回 footprint 的 (x, y)
func _cell_at(pos: Vector2) -> Vector2i:
	if _scale <= 0.001:
		return Vector2i(-1, -1)
	var u: float = (pos.x - _origin.x) / _scale
	var v: float = (pos.y - _origin.y) / _scale
	var dot_nfd: float = v / _sin_pitch
	var x: float = (u * _nfd.y - _rt.y * dot_nfd) / _det
	var y: float = (_rt.x * dot_nfd - u * _nfd.x) / _det
	return Vector2i(floori(x), floori(y))


## 左右侧边中点拖拽点：0=左侧，1=右侧，-1=没有
func _handle_at(pos: Vector2) -> int:
	if _art_quad.size() < 4:
		return -1
	var left_mid: Vector2 = (_art_quad[0] + _art_quad[3]) * 0.5
	var right_mid: Vector2 = (_art_quad[1] + _art_quad[2]) * 0.5
	if pos.distance_to(left_mid) <= HANDLE_RADIUS + 4.0:
		return 0
	if pos.distance_to(right_mid) <= HANDLE_RADIUS + 4.0:
		return 1
	return -1


func _apply_cell(cell: Vector2i, blocked: bool) -> void:
	var has: bool = blocking_cells.has(cell)
	if blocked == has:
		return
	if blocked:
		blocking_cells.append(cell)
	else:
		blocking_cells.erase(cell)
	mask_changed.emit()
	queue_redraw()


# ---------- 输入 ----------

func _gui_input(event: InputEvent) -> void:
	# 1) 先处理图片顶部左右拖拽点（不受阻挡模式影响）
	if event is InputEventMouseButton:
		var mb_handle: InputEventMouseButton = event as InputEventMouseButton
		if mb_handle.button_index == MOUSE_BUTTON_LEFT:
			if mb_handle.pressed:
				var handle: int = _handle_at(mb_handle.position)
				if handle >= 0:
					_drag_handle = handle
					_drag_start_y = mb_handle.position.y
					_drag_start_lift = _art_lift.x if handle == 0 else _art_lift.y
					_refit_locked = true
					accept_event()
					return
			elif _drag_handle >= 0:
				_drag_handle = -1
				_unlock_refit()
				accept_event()
				return
	elif event is InputEventMouseMotion and _drag_handle >= 0:
		var motion_handle: InputEventMouseMotion = event as InputEventMouseMotion
		var art_h: float = _art_size.y * _scale
		if art_h > 0.0:
			var lift: float = _drag_start_lift - (motion_handle.position.y - _drag_start_y) / art_h
			lift = clampf(lift, -DEF.ART_LIFT_LIMIT, DEF.ART_LIFT_LIMIT)
			if _drag_handle == 0:
				_art_lift.x = lift
			else:
				_art_lift.y = lift
			lift_changed.emit()
			_update_projection()
			queue_redraw()
			accept_event()
		return

	# 2) 右键拖动图片整体移动
	if event is InputEventMouseButton:
		var mb_move: InputEventMouseButton = event as InputEventMouseButton
		if mb_move.button_index == MOUSE_BUTTON_RIGHT:
			if mb_move.pressed:
				if _art_quad.size() == 4 and Geometry2D.is_point_in_polygon(mb_move.position, _art_quad):
					_move_dragging = true
					_refit_locked = true
					accept_event()
					return
			elif _move_dragging:
				_move_dragging = false
				_unlock_refit()
				accept_event()
				return
	elif event is InputEventMouseMotion and _move_dragging:
		var motion_move: InputEventMouseMotion = event as InputEventMouseMotion
		if _scale > 0.001:
			_art_offset = Vector2(
				clampf(_art_offset.x + motion_move.relative.x / _scale, -32.0, 32.0),
				clampf(_art_offset.y + motion_move.relative.y / _scale, -32.0, 32.0))
			_update_projection()
			offset_changed.emit(_art_offset)
			queue_redraw()
			accept_event()
		return

	# 3) 阻挡格编辑
	if blocking_mode != DEF.Blocking.MASK:
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			var cell: Vector2i = _cell_at(mb.position)
			if mb.pressed and _in_bounds(cell):
				_painting = true
				_paint_blocked = not _is_blocked(cell)
				_apply_cell(cell, _paint_blocked)
				accept_event()
			elif not mb.pressed:
				_painting = false
				accept_event()
	elif event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		var hover: Vector2i = _cell_at(motion.position)
		_hover = hover if _in_bounds(hover) else Vector2i(-1, -1)
		queue_redraw()
		if _painting and _in_bounds(hover):
			_apply_cell(hover, _paint_blocked)
			accept_event()


# ---------- 绘制 ----------

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.07, 0.08, 0.09, 0.9), true)
	draw_rect(Rect2(Vector2.ZERO, size).grow(-0.5), Color(1, 1, 1, 0.06), false, 1.0)
	var font: Font = ThemeDB.fallback_font
	var cells: Array[Vector2i] = all_cells()

	# 1) 格子底色（红/绿）
	for cell: Vector2i in cells:
		var blocked: bool = _is_blocked(cell)
		var fill: Color = Color(0.88, 0.30, 0.24, 0.20) if blocked else Color(0.30, 0.72, 0.42, 0.16)
		draw_colored_polygon(_cell_polygon(cell), fill)

	# 2) PNG 保持原比例直立在网格上方，半透明；不自动贴地拉伸。
	if _texture != null and _art_quad.size() == 4:
		var uvs: PackedVector2Array = PackedVector2Array([
			Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1),
		])
		var tint: Color = Color(1, 1, 1, 0.52)
		draw_polygon(_art_quad, PackedColorArray([tint, tint, tint, tint]), uvs, _texture)

	# 3) 边框 + 坐标 + 悬停高亮（画在 PNG 之上）
	for cell: Vector2i in cells:
		var poly: PackedVector2Array = _cell_polygon(cell)
		var blocked: bool = _is_blocked(cell)
		var edge: Color = Color(1.0, 0.42, 0.32, 0.90) if blocked else Color(0.38, 0.94, 0.55, 0.55)
		var closed: PackedVector2Array = PackedVector2Array([poly[0], poly[1], poly[2], poly[3], poly[0]])
		draw_polyline(closed, edge, 1.2, true)
		var center: Vector2 = _project(Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5))
		var label: String = "%d,%d" % [cell.x, cell.y]
		draw_string(font, center + Vector2(-30.0, 4.0), label, HORIZONTAL_ALIGNMENT_CENTER,
			60.0, FONT_SIZE, Color(0.95, 0.97, 1.0, 0.85))
		if cell == _hover and blocking_mode == DEF.Blocking.MASK:
			draw_polyline(closed, Color(1, 1, 1, 0.95), 2.2, true)

	# 4) 左右侧边中点拖拽点：整条侧边一起抬高/压低
	if _art_quad.size() == 4:
		var handles: Array[Vector2] = [
			(_art_quad[0] + _art_quad[3]) * 0.5,
			(_art_quad[1] + _art_quad[2]) * 0.5,
		]
		for handle: Vector2 in handles:
			draw_circle(handle, HANDLE_RADIUS + 2.0, Color(0.05, 0.06, 0.07, 0.9))
			draw_circle(handle, HANDLE_RADIUS, Color(1.0, 0.76, 0.30, 0.95))
			draw_arc(handle, HANDLE_RADIUS - 1.0, 0.0, TAU, 20, Color(0.35, 0.22, 0.05, 0.9), 1.0)
