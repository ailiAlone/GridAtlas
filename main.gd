extends Control
## GridAtlas 编辑器主脚本：MapData 唯一持有者，负责注入与视图编排。
## 四个视图实例静态分布在两个容器里，轮换只切 visible、零增删：
##   大面板 ScrollContainer：GridView(编辑) + RenderView(成品，隐藏)
##   小面板 Panel：RenderViewMini(成品预览) + GridViewMini(编辑预览，隐藏)
## 工具区 GridTools ↔ RenderTool 同为静态显隐；编辑改动经 sync_area 即时重渲两个渲染实例。

@onready var tools: VBoxContainer = $HBoxContainer/VBoxContainer/Panel2/ScrollContainer/GridTools
@onready var rtool: RenderTool = $HBoxContainer/VBoxContainer/Panel2/ScrollContainer/RenderTool
@onready var grid_view: GridView = $HBoxContainer/VBoxContainer2/Panel/ScrollContainer/GridView
@onready var render_view: RenderView = $HBoxContainer/VBoxContainer2/Panel/ScrollContainer/RenderView
@onready var grid_mini: GridView = $HBoxContainer/VBoxContainer/Panel/GridViewMini
@onready var render_mini: RenderView = $HBoxContainer/VBoxContainer/Panel/RenderViewMini
@onready var swapbutton: Button = $HBoxContainer/VBoxContainer/Panel/Button
@onready var coord_label: Label = $HBoxContainer/VBoxContainer2/Panel2/HBoxContainer/Label
@onready var smallpanel: Panel = $HBoxContainer/VBoxContainer/Panel
@onready var bigscroll: ScrollContainer = $HBoxContainer/VBoxContainer2/Panel/ScrollContainer

var map: MapData  # 唯一持有者：所有使用方从这里拿引用
var render_mode: bool = false  # false=编辑模式，true=渲染模式
var grids: Array = []      # 两个编辑视图（大可编辑、小只读镜像）
var renders: Array = []    # 两个渲染实例（大成品、小预览）

# 撤销/重做：整图快照。64×64 时一份约 80KB，60 步上限约 5MB。
const HISTORY_MAX: int = 60
var undo_stack: Array[MapData] = []
var redo_stack: Array[MapData] = []


func _ready() -> void:
	grids = [grid_view, grid_mini]
	renders = [render_view, render_mini]
	map = MapData.create(Vector2i(64, 64))
	for view: GridView in grids:
		view.set_map(map)
	for view: RenderView in renders:
		view.set_map(map)
		view.apply_settings(rtool.settings)
	tools.set_map(map)
	# 交互类信号只接大编辑视图（小面板完全只读）
	tools.brush_changed.connect(grid_view.set_brush)
	tools.brush_size_changed.connect(grid_view.set_brush_size)
	tools.rect_mode_changed.connect(grid_view.set_rect_mode)
	tools.map_resized.connect(_on_map_resized)
	tools.map_loaded.connect(_on_map_loaded)
	tools.map_saved.connect(_on_map_saved)
	tools.edit_checkpoint.connect(_push_history)
	# 高程视图是显示模式，大小编辑视图一起切
	tools.elevation_view_changed.connect(grid_view.set_elevation_mode)
	tools.elevation_view_changed.connect(grid_mini.set_elevation_mode)
	grid_view.area_painted.connect(_on_area_painted)
	grid_view.cell_hovered.connect(_on_cell_hovered)
	grid_view.stroke_started.connect(_push_history)
	rtool.settings_changed.connect(_on_render_settings_changed)
	rtool.material_params_requested.connect(_on_material_params_requested)
	rtool.oblique_changed.connect(_on_oblique_changed)
	swapbutton.pressed.connect(_on_swap_pressed)
	smallpanel.resized.connect(_refresh_views)
	bigscroll.resized.connect(_refresh_views)
	# 静态初始化各实例的面板模式（此后不再变化）
	grid_view.set_panel_mode(true)
	render_view.set_panel_mode(true)
	grid_mini.set_panel_mode(false)
	render_mini.set_panel_mode(false)
	print("[地图] 新建地图 %d×%d，全图草地/高程1（未保存）" % [map.grid_size.x, map.grid_size.y])


# ---------- 视图轮换（纯显隐） ----------

func _on_swap_pressed() -> void:
	render_mode = not render_mode
	grid_view.visible = not render_mode
	render_view.visible = render_mode
	grid_mini.visible = render_mode
	render_mini.visible = not render_mode
	tools.visible = not render_mode
	rtool.visible = render_mode
	coord_label.text = "当前坐标(-,-)"
	print("[视图] %s" % ("渲染模式（成品预览）" if render_mode else "编辑模式"))


## 任一容器尺寸变化：四个实例各自按自己的模式重新适配
func _refresh_views() -> void:
	for view: GridView in grids:
		view.refresh()
	for view: RenderView in renders:
		view.refresh()


# ---------- 编辑应用 ----------

## 涂画/矩形填充统一入口：把笔刷值写到区域内每个格子（越界部分跳过）
func _on_area_painted(area: Rect2i, erase: bool) -> void:
	var layer: StringName = tools.brush_layer
	# 陆地/高程没有 NONE：擦除=恢复默认（草地/1）；水域/道路/流向擦除=0（NONE）
	var value: int = tools.brush_value
	var height: float = 1.0 if erase else tools.brush_height
	if erase:
		if layer == &"land":
			value = GridDefs.Land.GRASS
		elif layer != &"elevation":
			value = 0
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			var cell: Vector2i = Vector2i(x, y)
			if not map.in_bounds(cell):
				continue
			if layer == &"land":
				map.set_land(cell, value)
				if not erase:
					# 陆水互斥：画陆地清掉水域及其流向；擦除只是恢复草地，不动水面
					map.set_water(cell, GridDefs.Water.NONE)
					map.set_flow(cell, GridDefs.Flow.NONE)
			elif layer == &"water":
				map.set_water(cell, value)
				if value == GridDefs.Water.NONE:
					map.set_flow(cell, GridDefs.Flow.NONE)  # 水没了，流向一并清掉
				# 陆地保留在水下：擦除水后陆地重新露出
			elif layer == &"road":
				# 道路只能画在陆地上（水格跳过；擦除不受限）
				if erase or map.get_water(cell) == GridDefs.Water.NONE:
					map.set_road(cell, value)
			elif layer == &"flow":
				map.set_flow(cell, value)
			elif layer == &"elevation":
				map.set_height(cell, height)
	tools.mark_dirty()
	for view: GridView in grids:
		view.queue_redraw()
	for view: RenderView in renders:
		view.sync_area(area)
	if erase:
		print("[绘制] (%d,%d) %d×%d 擦除 %s -> %s" % [area.position.x, area.position.y, area.size.x, area.size.y, GridDefs.LAYER_NAMES.get(layer, layer), _brush_text(layer, value)])
	else:
		print("[绘制] (%d,%d) %d×%d %s = %s" % [area.position.x, area.position.y, area.size.x, area.size.y, GridDefs.LAYER_NAMES.get(layer, layer), _brush_text(layer, tools.brush_value)])


## 绘制日志用的笔刷值文本（高程是浮点，其余是枚举名）
func _brush_text(layer: StringName, value: int) -> String:
	if layer == &"elevation":
		return tools.height_text(tools.brush_height)
	return tools.value_name(layer, value)


func _on_cell_hovered(cell: Vector2i) -> void:
	if cell.x >= 0:
		coord_label.text = "当前坐标(%d,%d)" % [cell.x, cell.y]
	else:
		coord_label.text = "当前坐标(-,-)"


# ---------- 地图与配置事件 ----------

## 尺寸变化：同一个 MapData 对象原地 resize，重建渲染纹理、刷新编辑视图
func _on_map_resized(_size: Vector2i) -> void:
	for view: RenderView in renders:
		view.set_map(map)
	for view: GridView in grids:
		view.refresh()


## 打开地图：MapData 被整体替换，回灌给所有使用方
func _on_map_loaded(data: MapData) -> void:
	if data.ensure_precision():
		print("[地图] 高程已迁移到 0.25 级精度")
		tools.mark_dirty()
	map = data
	undo_stack.clear()
	redo_stack.clear()
	tools.set_map(map)
	for view: GridView in grids:
		view.set_map(map)
	for view: RenderView in renders:
		view.set_map(map)
	_load_look(tools.current_path)


## 渲染配置面板任何改动：即时注入两个渲染实例
func _on_render_settings_changed() -> void:
	for view: RenderView in renders:
		view.apply_settings(rtool.settings)


## 斜角视图开关：两个渲染实例一起切（俯视 ↔ 正交斜看）
func _on_oblique_changed(on: bool) -> void:
	for view: RenderView in renders:
		view.set_oblique(on)


# ---------- 渲染配置持久化（与地图同名的 .look.tres 边车） ----------

## 边车路径：与地图同目录同名，后缀换成 .look.tres（first.tres -> first.look.tres）
func _look_path(map_path: String) -> String:
	if map_path.is_empty():
		return ""
	return map_path.get_basename() + ".look.tres"


## 保存地图后顺手保存当前渲染配置
func _on_map_saved(path: String) -> void:
	var look_path: String = _look_path(path)
	if look_path.is_empty():
		return
	var err: Error = ResourceSaver.save(rtool.settings, look_path)
	if err == OK:
		print("[渲染] 配置已保存: %s" % look_path)
	else:
		push_warning("渲染配置保存失败(%s): %s" % [error_string(err), look_path])


## 打开地图时，若存在同名边车就载入；没有则保持当前外观
func _load_look(map_path: String) -> void:
	var look_path: String = _look_path(map_path)
	if look_path.is_empty() or not ResourceLoader.exists(look_path):
		return
	var loaded: RenderSettings = load(look_path) as RenderSettings
	if loaded == null:
		push_warning("渲染配置不是有效资源: " + look_path)
		return
	rtool.set_settings(loaded)
	print("[渲染] 已载入配置: %s" % look_path)


# ---------- 撤销 / 重做 ----------

## 压入一份"改动前"的整图快照（落笔开始、改尺寸之前调用）
func _push_history() -> void:
	if map == null:
		return
	undo_stack.append(_snapshot_map())
	if undo_stack.size() > HISTORY_MAX:
		undo_stack.pop_front()
	redo_stack.clear()


func _snapshot_map() -> MapData:
	var snap: MapData = MapData.new()
	snap.grid_size = map.grid_size
	snap.elev_unit = map.elev_unit
	snap.land = map.land.duplicate()
	snap.water = map.water.duplicate()
	snap.flow = map.flow.duplicate()
	snap.road = map.road.duplicate()
	snap.elevation = map.elevation.duplicate()
	return snap


## 把快照写回同一个 MapData 对象（视图都持有它的引用，不能换对象）
func _restore_map(snap: MapData) -> void:
	map.grid_size = snap.grid_size
	map.elev_unit = snap.elev_unit
	map.land = snap.land.duplicate()
	map.water = snap.water.duplicate()
	map.flow = snap.flow.duplicate()
	map.road = snap.road.duplicate()
	map.elevation = snap.elevation.duplicate()
	tools.set_map(map)
	for view: GridView in grids:
		view.set_map(map)
	for view: RenderView in renders:
		view.set_map(map)
	_refresh_views()
	tools.mark_dirty()


func _undo() -> void:
	if undo_stack.is_empty():
		return
	redo_stack.append(_snapshot_map())
	var snap: MapData = undo_stack.pop_back()
	_restore_map(snap)
	print("[编辑] 撤销（还可撤销 %d 步）" % undo_stack.size())


func _redo() -> void:
	if redo_stack.is_empty():
		return
	undo_stack.append(_snapshot_map())
	var snap: MapData = redo_stack.pop_back()
	_restore_map(snap)
	print("[编辑] 重做（还可重做 %d 步）" % redo_stack.size())


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key: InputEventKey = event as InputEventKey
	if not key.ctrl_pressed:
		return
	if key.keycode == KEY_Z:
		if key.shift_pressed:
			_redo()
		else:
			_undo()
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_Y:
		_redo()
		get_viewport().set_input_as_handled()


## 点“材质参数”：打开大面板里渲染实例的材质浮窗（颜色/过渡矩阵），并把它的改动接回重渲
func _on_material_params_requested() -> void:
	var params: Node = render_view.get_node_or_null("MaterialParameters")
	if params == null:
		return
	if not params.is_connected("settings_changed", Callable(self, "_on_material_params_changed")):
		params.connect("settings_changed", Callable(self, "_on_material_params_changed"))
	params.call("set_settings", rtool.settings)
	params.call("open")
	print("[材质] 材质参数窗口已打开")


func _on_material_params_changed() -> void:
	for view: RenderView in renders:
		view.apply_settings(rtool.settings)
