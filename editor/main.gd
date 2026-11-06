extends Control
## GridAtlas 编辑器主脚本：MapData 唯一持有者，负责注入与视图编排。
## 视图实例静态分布、轮换只切 visible、零增删：
##   大面板 Panel：编辑模式 GridView(滚动画布) / 渲染模式 GamePreview(固定 45° 游戏视图)
##   小面板 Panel：编辑模式 GamePreviewMini(45° 整图概览) / 渲染模式 GridViewMini(俯视编辑镜像)
## 工具区 GridTools ↔ RenderTool 同为静态显隐；编辑改动即时刷新编辑画布与 45° 小预览，
## 大 45° 视图在切到渲染模式时按当前地图/物件重建。

@onready var tools: VBoxContainer = $HBoxContainer/VBoxContainer/Panel2/ScrollContainer/GridTools
@onready var rtool: RenderTool = $HBoxContainer/VBoxContainer/Panel2/ScrollContainer/RenderTool
@onready var grid_view: GridView = $HBoxContainer/VBoxContainer2/Panel/ScrollContainer/GridView
@onready var game_preview: GamePreviewScript = $HBoxContainer/VBoxContainer2/Panel/GamePreview
@onready var material_params: PanelContainer = $HBoxContainer/VBoxContainer2/Panel/MaterialParameters
@onready var grid_mini: GridView = $HBoxContainer/VBoxContainer/Panel/GridViewMini
@onready var preview_mini: GamePreviewScript = $HBoxContainer/VBoxContainer/Panel/GamePreviewMini
@onready var swapbutton: Button = $HBoxContainer/VBoxContainer/Panel/Button
@onready var filebar: Control = $HBoxContainer/VBoxContainer/FileBar
@onready var status_hint: Label = $HBoxContainer/VBoxContainer2/Panel2/HBoxContainer/StatusHint
@onready var status_hover: Label = $HBoxContainer/VBoxContainer2/Panel2/HBoxContainer/StatusHover
@onready var status_zoom: Label = $HBoxContainer/VBoxContainer2/Panel2/HBoxContainer/StatusZoom
@onready var smallpanel: Panel = $HBoxContainer/VBoxContainer/Panel
@onready var bigscroll: ScrollContainer = $HBoxContainer/VBoxContainer2/Panel/ScrollContainer
@onready var import_overlay: Control = $ImportOverlay
@onready var import_view = $ImportOverlay/StaticAssetImportView
@onready var _reset_confirm: ConfirmationDialog = $ShaderResetConfirm
@onready var _unsaved_confirm: ConfirmationDialog = $UnsavedConfirm
@onready var _newmap_dialog: AcceptDialog = $NewMapDialog
@onready var _newmap_w: SpinBox = $NewMapDialog/VBox/HBoxSize/SpinBoxW
@onready var _newmap_h: SpinBox = $NewMapDialog/VBox/HBoxSize/SpinBoxH
@onready var map_browser: Window = $MapBrowser

const PropsData = preload("res://data/props_data.gd")
const BridgesData = preload("res://data/bridges_data.gd")
const MapSidecars = preload("res://data/map_sidecars.gd")
const GamePreviewScript = preload("res://editor/game_preview.gd")
const Toast = preload("res://editor/ui/toast.gd")

var map: MapData  # 唯一持有者：所有使用方从这里拿引用
var props   # 物件层（PropsData，地图边车）：同样由本脚本持有、注入视图
var bridges # 桥层（BridgesData，地图边车）：独立于静态资源，只由道路面板的桥工具写入
var asset_defs: Dictionary = {}  # StringName -> StaticAssetDef（资源库，运行时载入）
var render_mode: bool = false  # false=编辑模式，true=渲染模式
var grids: Array = []      # 两个编辑视图（大可编辑、小只读镜像）

# 左上角 45° 小预览的脏区累积：每帧最多增量刷新一次，拖动笔刷不卡
var _mini_dirty: Rect2i = Rect2i()
var _mini_elev_dirty: bool = false
var _mini_sync_queued: bool = false
var _mountain_preview_queued: bool = false  # 山体 footprint 变了：需要整图重建程序化高度

# 撤销/重做：整图快照。64×64 时一份约 80KB，60 步上限约 5MB。
const HISTORY_MAX: int = 60
var undo_stack: Array[Dictionary] = []
var redo_stack: Array[Dictionary] = []
var last_edit_cell: Vector2i = Vector2i(-1, -1)  # 最近一次落笔位置：切到 45° 预览时从那里看
var _pending_flow: StringName = &""   # 未保存确认之后要执行的动作（new/open/quit）
var _quit_after_save: bool = false    # 走另存对话框保存成功后自动退出
var _suppress_dirty: bool = false     # 载入 look / 新建地图时抑制 settings_changed 点脏
var _erase_miss_toasted: bool = false # 本次落笔是否已提示过"没删到物件"


func _ready() -> void:
	grids = [grid_view, grid_mini]
	map = MapData.create(Vector2i(64, 64))
	props = PropsData.new()
	bridges = BridgesData.new()
	_reload_asset_defs()
	for view: GridView in grids:
		view.set_map(map)
		view.set_props(props)
		view.set_bridges(bridges)
	tools.set_map(map)
	tools.set_prop_count(0)
	# 交互类信号只接大编辑视图（小面板完全只读）
	tools.brush_changed.connect(grid_view.set_brush)
	tools.brush_changed.connect(_on_brush_changed)
	tools.brush_size_changed.connect(grid_view.set_brush_size)
	tools.rect_mode_changed.connect(grid_view.set_rect_mode)
	tools.prop_rotation_changed.connect(_on_prop_rotation_changed)
	tools.prop_scale_changed.connect(_on_prop_scale_changed)
	tools.propstool.clear_requested.connect(_on_props_clear_requested)
	tools.map_resized.connect(_on_map_resized)
	tools.map_loaded.connect(_on_map_loaded)
	tools.map_saved.connect(_on_map_saved)
	tools.edit_checkpoint.connect(_push_history)
	tools.propstool.assets_refresh_requested.connect(_reload_asset_defs.bind(true))
	tools.propstool.asset_edit_requested.connect(_on_asset_edit_requested)
	import_view.closed.connect(_on_import_view_closed)
	# 高程视图是显示模式，大小编辑视图一起切
	tools.elevation_view_changed.connect(grid_view.set_elevation_mode)
	tools.elevation_view_changed.connect(grid_mini.set_elevation_mode)
	grid_view.area_painted.connect(_on_area_painted)
	grid_view.bridge_committed.connect(_on_bridge_committed)
	grid_view.cell_hovered.connect(_on_cell_hovered)
	grid_view.stroke_started.connect(_push_history)
	grid_view.stroke_ended.connect(_on_stroke_ended)
	rtool.settings_changed.connect(_on_render_settings_changed)
	rtool.material_params_requested.connect(_on_material_params_requested)
	rtool.shader_open_requested.connect(_on_shader_open_requested)
	rtool.shader_reload_requested.connect(_on_shader_reload_requested)
	rtool.shader_reset_requested.connect(_on_shader_reset_requested)
	_reset_confirm.confirmed.connect(_on_shader_reset_confirmed)
	material_params.connect("settings_changed", _on_material_params_changed)
	material_params.visibility_changed.connect(_on_material_params_visibility)
	swapbutton.pressed.connect(_on_swap_pressed)
	smallpanel.resized.connect(_refresh_views)
	bigscroll.resized.connect(_refresh_views)
	# 文件条（两模式常驻）：保存/新建/打开/另存为都从这里进，脏状态由 tools 广播
	filebar.save_requested.connect(func(): tools.save_map())
	filebar.open_requested.connect(_on_open_map_requested)
	filebar.menu_new_requested.connect(_on_new_map_requested)
	filebar.menu_open_requested.connect(_on_open_map_requested)
	filebar.menu_save_as_requested.connect(func(): tools.save_as_map())
	tools.dirty_state_changed.connect(filebar.set_dirty)
	tools.map_path_changed.connect(filebar.set_map_path)
	# 关窗保护：连接 close_requested 后引擎不再自动退出，由这里决定退不退
	get_window().close_requested.connect(_on_close_requested)
	_unsaved_confirm.confirmed.connect(_on_unsaved_confirmed)      # 保存后继续
	_unsaved_confirm.add_button("不保存，直接继续", true, &"discard_go")
	_unsaved_confirm.custom_action.connect(_on_unsaved_custom)    # 丢弃并继续
	_newmap_dialog.confirmed.connect(_on_new_map_confirmed)
	for preset: Button in _newmap_dialog.find_children("Preset*", "Button", true, false):
		preset.pressed.connect(_on_newmap_preset.bind(int(preset.text)))
	map_browser.map_chosen.connect(_open_map_chosen)
	map_browser.new_requested.connect(func(): _newmap_dialog.popup_centered())
	map_browser.browse_requested.connect(func(): tools.open_map_dialog())
	# 静态初始化两个编辑画布的面板模式（此后不再变化）
	grid_view.set_panel_mode(true)
	grid_mini.set_panel_mode(false)
	preview_mini.set_preview_mode(true)
	_setup_mini_preview()
	swapbutton.text = "切换渲染"
	print("[地图] 新建地图 %d×%d，全图草地/高程1（未保存）" % [map.grid_size.x, map.grid_size.y])
	# 调试截图：--shot [--shot-map=res://...] [--shot-cell=x,y] [--shot-render] [--shot-material]
	if "--shot" in _cmdline_all():
		_capture_and_quit()


# ---------- 视图轮换（纯显隐） ----------

## 编辑模式：左 45° 整图预览 / 右网格；渲染模式：左网格镜像 / 右 45° 大画面。
func _on_swap_pressed() -> void:
	render_mode = not render_mode
	if render_mode:
		# 先记住编辑画布看到的中心，再隐藏它；预览优先看最近落笔处
		var center: Vector2 = _preview_focus_cell()
		game_preview.set_preview_mode(false)
		game_preview.visible = true
		game_preview.setup(map, rtool.settings, props, bridges, center)
	else:
		game_preview.visible = false
	bigscroll.visible = not render_mode
	if not render_mode:
		material_params.visible = false
	grid_view.visible = not render_mode
	grid_mini.visible = render_mode
	preview_mini.visible = not render_mode
	if not render_mode:
		_setup_mini_preview()
	tools.visible = not render_mode
	rtool.visible = render_mode
	status_hover.text = "(-,-)"
	_update_status_hint()
	swapbutton.text = "切换编辑" if render_mode else "切换渲染"
	print("[视图] %s" % ("渲染模式（45° 游戏视图）" if render_mode else "编辑模式"))


## 重建左上角 45° 整图预览（地图/物件/外观变化后调用）。
func _setup_mini_preview() -> void:
	if preview_mini == null or map == null:
		return
	_mini_dirty = Rect2i()
	_mini_elev_dirty = false
	preview_mini.set_preview_mode(true)
	preview_mini.setup(map, rtool.settings, props, bridges, Vector2(map.grid_size) * 0.5)
	preview_mini.fit_overview()


## 编辑画布当前可见区域的中心（格坐标）。作为 45° 预览焦点与可见性判断的基准。
func _edit_center_cell() -> Vector2:
	if map == null:
		return Vector2.ZERO
	var step: float = grid_view.step()
	if step <= 0.001:
		return Vector2(map.grid_size) * 0.5
	var px: Vector2 = Vector2(bigscroll.scroll_horizontal, bigscroll.scroll_vertical) + bigscroll.size * 0.5
	var cell: Vector2 = px / step
	return Vector2(clampf(cell.x, 0.0, float(map.grid_size.x)), clampf(cell.y, 0.0, float(map.grid_size.y)))


## 45° 预览的初始焦点：最近落笔处（还在编辑画布可见范围内时），否则用当前视图中心。
## 没有落笔记录（例如刚打开地图）时，取所有物件的中心——切过去先看到物件，
## 而不是整张图的几何中心。这样刚放完物件切过去，看到的就是刚放的那一片。
func _preview_focus_cell() -> Vector2:
	var view_center: Vector2 = _edit_center_cell()
	if last_edit_cell.x < 0:
		if props != null and props.count() > 0:
			var sum: Vector2 = Vector2.ZERO
			for i in props.count():
				var fp: Rect2i = props.footprint_at(i)
				sum += Vector2(fp.position) + Vector2(fp.size) * 0.5
			return sum / float(props.count())
		return view_center
	var step: float = grid_view.step()
	if step <= 0.001:
		return Vector2(last_edit_cell) + Vector2(0.5, 0.5)
	var half_cells: Vector2 = bigscroll.size * 0.5 / step
	var focus: Vector2 = Vector2(last_edit_cell) + Vector2(0.5, 0.5)
	if absf(focus.x - view_center.x) > half_cells.x or absf(focus.y - view_center.y) > half_cells.y:
		return view_center
	return focus


# ---------- 开发调试截图 ----------

## 引擎参数 + `--` 之后的用户参数（--shot 系列写在 -- 后面）。
func _cmdline_all() -> PackedStringArray:
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	return args


## --shot 截当前视图并退出；可配合 --shot-map / --shot-cell / --shot-render / --shot-material。
## 输出到 %TEMP%/gridatlas_shots/tool_<edit|render|material>.png。
func _capture_and_quit() -> void:
	var args: PackedStringArray = _cmdline_all()
	var map_path: String = ""
	var center: Vector2i = Vector2i(-1, -1)
	for arg: String in args:
		if arg.begins_with("--shot-map="):
			map_path = arg.trim_prefix("--shot-map=")
		elif arg.begins_with("--shot-cell="):
			var parts: PackedStringArray = arg.trim_prefix("--shot-cell=").split(",")
			if parts.size() == 2:
				center = Vector2i(int(parts[0]), int(parts[1]))
	if not map_path.is_empty():
		tools.open_map(map_path)
	for i in 4:
		await get_tree().process_frame
	if center.x >= 0:
		_scroll_edit_to(center)
		last_edit_cell = center
	for i in 4:
		await get_tree().process_frame
	if "--shot-render" in args:
		_on_swap_pressed()
		if "--shot-material" in args:
			_on_material_params_requested()
		if "--shot-back" in args:
			for i in 4:
				await get_tree().process_frame
			_on_swap_pressed()
	for i in 12:
		await get_tree().process_frame
	var mode: String = "edit"
	if render_mode:
		mode = "render"
	if material_params.visible:
		mode = "material"
	var img: Image = get_viewport().get_texture().get_image()
	var dir: String = OS.get_environment("TEMP").replace("\\", "/") + "/gridatlas_shots"
	DirAccess.make_dir_recursive_absolute(dir)
	var out: String = dir + "/tool_%s.png" % mode
	if FileAccess.file_exists(out):
		DirAccess.remove_absolute(out)
	var err: Error = img.save_png(out)
	print("[截图] %s (%s)" % [out, error_string(err)])
	get_tree().quit()


## 把编辑画布的可见中心滚到指定格（截图取景用）
func _scroll_edit_to(cell: Vector2i) -> void:
	var step: float = grid_view.step()
	if step <= 0.001:
		return
	var target: Vector2 = Vector2(cell) + Vector2(0.5, 0.5)
	bigscroll.scroll_horizontal = int(round(target.x * step - bigscroll.size.x * 0.5))
	bigscroll.scroll_vertical = int(round(target.y * step - bigscroll.size.y * 0.5))


## 任一容器尺寸变化：两个编辑画布重适配，45° 小预览重算整图取景，大视图刷新相机。
func _refresh_views() -> void:
	for view: GridView in grids:
		view.refresh()
	if preview_mini.visible:
		preview_mini.fit_overview()
	if game_preview.visible:
		game_preview.refresh_view()


# ---------- 编辑应用 ----------

## 涂画/矩形填充统一入口：把笔刷值写到区域内每个格子（越界部分跳过）
func _on_area_painted(area: Rect2i, erase: bool) -> void:
	var half: int = int(area.size.x * 0.5)
	last_edit_cell = area.position + Vector2i(half, half)
	var layer: StringName = tools.brush_layer
	# 山体是独立遮罩：只改材质与通行，不覆盖你画的陆地/道路/水域
	if layer == &"mountain":
		_paint_mountains(area, erase)
		return
	# 物件是"每笔一个"，不写地图图层，也不动格子缓存
	if layer == &"prop":
		_paint_props(area, erase)
		return
	# 高程是整级设定：独立于陆地/水/道路，不被它们覆盖
	if layer == &"elevation":
		_paint_elevation(area, erase)
		return
	# 陆地没有 NONE：擦除=恢复默认（草地）；水域/道路/流向擦除=0（NONE）
	var value: int = tools.brush_value
	if erase:
		if layer == &"land":
			value = GridDefs.Land.GRASS
		else:
			value = 0
	var carved_mountain: bool = false
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
					# 在山上画回地面 = 把这块山体挖掉
					carved_mountain = _carve_mountain(cell) or carved_mountain
			elif layer == &"water":
				if value != GridDefs.Water.NONE:
					# 河床强制是沙地：画水的同时把陆地类型改写为沙
					map.set_land(cell, GridDefs.Land.SAND)
					map.set_water(cell, value)
					carved_mountain = _carve_mountain(cell) or carved_mountain
				else:
					map.set_water(cell, GridDefs.Water.NONE)
					map.set_flow(cell, GridDefs.Flow.NONE)  # 水没了，流向一并清掉
					# 擦除水后露出的是画水时改写的沙地
			elif layer == &"road":
				# 道路只能画在陆地上（水格跳过；擦除不受限）
				if erase or map.get_water(cell) == GridDefs.Water.NONE:
					map.set_road(cell, value)
					if not erase:
						carved_mountain = _carve_mountain(cell) or carved_mountain
			elif layer == &"flow":
				map.set_flow(cell, value)
	tools.mark_dirty()
	for view: GridView in grids:
		view.sync_cell_area(area)
	if carved_mountain:
		_queue_mountain_preview()
	else:
		_queue_mini_sync(area, false)
	if erase:
		print("[绘制] (%d,%d) %d×%d 擦除 %s -> %s" % [area.position.x, area.position.y, area.size.x, area.size.y, GridDefs.LAYER_NAMES.get(layer, layer), tools.value_name(layer, value)])
	else:
		print("[绘制] (%d,%d) %d×%d %s = %s" % [area.position.x, area.position.y, area.size.x, area.size.y, GridDefs.LAYER_NAMES.get(layer, layer), tools.value_name(layer, tools.brush_value)])


## 山体遮罩：左键=画山、Shift+左键=清除；山脉格不可通行，但下面的陆地/道路数据不动。
func _paint_mountains(area: Rect2i, erase: bool) -> void:
	var value: int = 0 if erase else 1
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			var cell: Vector2i = Vector2i(x, y)
			if not map.in_bounds(cell):
				continue
			# 水面不画山；擦除不限制
			if not erase and map.get_water(cell) != GridDefs.Water.NONE:
				continue
			map.set_mountain(cell, value)
	tools.mark_dirty()
	for view: GridView in grids:
		view.sync_cell_area(area)
	_queue_mountain_preview()
	print("[绘制] (%d,%d) %d×%d 山体 %s" % [
		area.position.x, area.position.y, area.size.x, area.size.y,
		"擦除" if erase else "绘制"])


## 把一格山体挖掉；返回是否真的挖到了山体。
func _carve_mountain(cell: Vector2i) -> bool:
	if map.get_mountain(cell) <= 0:
		return false
	map.set_mountain(cell, 0)
	return true


## 高程笔刷：区域内每格直接写入选定整级高度，Shift+左键恢复 1 级。
## 山体高度由最近山脚的基础高程派生，所以有山体时整张 45° 预览要按新基准重建；
## 没有山体时只同步脏区，拖动大图也不卡。
func _paint_elevation(area: Rect2i, erase: bool) -> void:
	var level: int = 1 if erase else tools.brush_value
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			var cell: Vector2i = Vector2i(x, y)
			if map.in_bounds(cell):
				map.set_height(cell, float(level))
	tools.mark_dirty()
	for view: GridView in grids:
		view.sync_cell_area(area)
	if map.has_mountain():
		_queue_mountain_preview()
	else:
		_queue_mini_sync(area, true)
	print("[绘制] (%d,%d) %d×%d 高程 %s" % [
		area.position.x, area.position.y, area.size.x, area.size.y,
		"恢复 1 级" if erase else "= %d 级" % level])


## 山体 footprint 变化会重算整张程序化高度场；小预览整图重建（每帧最多一次）。
func _queue_mountain_preview() -> void:
	if _mountain_preview_queued:
		return
	_mountain_preview_queued = true
	_flush_mountain_preview.call_deferred()


func _flush_mountain_preview() -> void:
	_mountain_preview_queued = false
	if preview_mini != null and preview_mini.visible:
		_setup_mini_preview()


## 把小预览的脏区攒起来，每帧最多刷新一次：拖动笔刷时不会每个格子都重建纹理。
func _queue_mini_sync(area: Rect2i, elev_changed: bool) -> void:
	if preview_mini == null or not preview_mini.visible:
		return
	if _mini_dirty.size.x <= 0:
		_mini_dirty = area
	else:
		var start: Vector2i = Vector2i(
			mini(_mini_dirty.position.x, area.position.x),
			mini(_mini_dirty.position.y, area.position.y))
		var end: Vector2i = Vector2i(
			maxi(_mini_dirty.end.x, area.end.x),
			maxi(_mini_dirty.end.y, area.end.y))
		_mini_dirty = Rect2i(start, end - start)
	_mini_elev_dirty = _mini_elev_dirty or elev_changed
	if not _mini_sync_queued:
		_mini_sync_queued = true
		_flush_mini_sync.call_deferred()


func _flush_mini_sync() -> void:
	_mini_sync_queued = false
	if _mini_dirty.size.x <= 0:
		return
	var area: Rect2i = _mini_dirty
	var elev_changed: bool = _mini_elev_dirty
	_mini_dirty = Rect2i()
	_mini_elev_dirty = false
	if preview_mini != null and preview_mini.visible:
		preview_mini.refresh_terrain(area, elev_changed)


## 松手后按新的最高点重算一次整图取景；拖动过程中不缩放，避免镜头抖动。
func _on_stroke_ended() -> void:
	_erase_miss_toasted = false   # 下一次落笔重新允许"没删到"提示
	if preview_mini != null and preview_mini.visible:
		preview_mini.flush_ground_mask()
		preview_mini.fit_overview()
	if game_preview != null and game_preview.visible:
		game_preview.flush_ground_mask()


# ---------- 物件 ----------

## 载入/刷新静态资源目录：定义注入物件层（占地/阻挡按定义走），
## 按钮与 45° 立牌跟着更新。资源导入页保存后点“资源库/刷新”即可生效，不必重启。
func _reload_asset_defs(announce: bool = false) -> void:
	StaticAssetStore.clear_texture_cache()
	asset_defs = StaticAssetStore.load_def_map()
	if props != null:
		props.set_asset_defs(asset_defs)
		var missing: int = 0
		for i in props.count():
			if not asset_defs.has(props.asset_id_at(i)):
				missing += 1
		if missing > 0:
			push_warning("有 %d 个资源实例找不到定义（已删除/改名），会显示占位或不渲染" % missing)
	if tools != null:
		tools.set_asset_defs(asset_defs)
	for view: GridView in grids:
		view.queue_redraw()
	if preview_mini != null and preview_mini.visible:
		preview_mini.refresh_props()
	if game_preview != null and game_preview.visible:
		game_preview.refresh_props()
	print("[资源] 已载入 %d 个定义%s" % [asset_defs.size(), "（刷新）" if announce else ""])


## 资源落笔：在笔刷区域中心放一个静态资源（Shift+左键=删除占地范围覆盖该格的物件）。
## 笔刷大小 >1 时按区域中心落点，与 GridView 的绿色预览框一致。
func _paint_props(area: Rect2i, erase: bool) -> void:
	if props == null or tools == null or tools.brush_layer != &"prop":
		return
	var half: int = int(area.size.x * 0.5)
	var center: Vector2i = area.position + Vector2i(half, half)
	if erase:
		var idx: int = props.asset_index_at(center)
		var removed: int = props.remove_at(center)
		if removed > 0:
			tools.mark_dirty()
			_refresh_prop_views()
			if removed == 1 and idx >= 0:
				# 只移除这一张立牌；草垫遮罩留到松手后重算。
				if preview_mini != null and preview_mini.visible:
					preview_mini.remove_prop_preview(idx)
				if game_preview != null and game_preview.visible:
					game_preview.remove_prop_preview(idx)
			else:
				_refresh_props()
				if game_preview != null and game_preview.visible:
					game_preview.refresh_props()
			print("[物件] 删除 %s（%d 个）" % [str(center), removed])
		elif not _erase_miss_toasted:
			_erase_miss_toasted = true   # 一次落笔只提示一次，拖动连续擦除不刷屏
			Toast.show(self, "该位置没有可删除的物件")
		return
	if tools.prop_asset_id == &"":
		return
	_paint_asset(center)


## 静态资源：锚点按占地范围居中（与 GridView 的落点预览同一个公式）
func _paint_asset(center: Vector2i) -> void:
	var def: StaticAssetDef = props.asset(tools.prop_asset_id)
	if def == null:
		push_warning("资源定义缺失: " + String(tools.prop_asset_id))
		return
	var rot: int = tools.prop_rotation
	var scale: int = tools.current_prop_scale()
	var fp: Vector2i = PropsData.rotated_footprint(
		Vector2i(def.footprint.x * scale, def.footprint.y * scale), rot)
	var anchor: Vector2i = PropsData.anchor_for(fp, center)
	# 只校验地图边界与实例重叠；水面/山体等任何地形都允许摆放
	if props.add_asset(tools.prop_asset_id, anchor, map.grid_size, rot, scale):
		tools.mark_dirty()
		# 拖动放置：只追加这一张立牌 + 增量草垫，不重建全部物件。
		_refresh_prop_views()
		var idx: int = props.count() - 1
		if preview_mini != null and preview_mini.visible:
			preview_mini.add_prop_preview(idx)
		if game_preview != null and game_preview.visible:
			game_preview.add_prop_preview(idx)
		print("[资源] 放置 %s @ %s（占地范围 %d×%d，%d×，方向 %s，阻挡 %d 格）" % [
			def.display_name, str(anchor), fp.x, fp.y, scale,
			"竖向" if rot == 1 else "横向", props.blocking_cells_at(idx).size()])
	else:
		var reason: String = "越界" if not props.can_place_fp(fp, anchor, map.grid_size) else "与已有物件重叠"
		Toast.show(self, "无法放置 %s：%s" % [def.display_name, reason], true)


## R 键：鼠标下有资源就在横向/竖向之间切换；否则只切换待放置方向（与方向按钮同一状态）。
## 原地旋转绕占地中心；只拒绝越界和与其它实例重叠，水面/山体不影响。
func _rotate_asset_at(cell: Vector2i) -> void:
	if props == null:
		return
	var idx: int = props.asset_index_at(cell)
	if idx < 0:
		tools.cycle_rotation()
		return
	var def: StaticAssetDef = props.asset(props.asset_id_at(idx))
	var showname: String = String(props.asset_id_at(idx))
	if def != null:
		showname = def.display_name
	if not props.can_rotate(idx, map.grid_size):
		Toast.show(self, "不能旋转 %s：越界或与已有物件重叠" % showname, true)
		print("[资源] 不能旋转 %s：越界或与已有物件重叠" % showname)
		return
	_push_history()
	if not props.rotate_instance(idx):
		return
	tools.mark_dirty()
	_refresh_props()
	var new_fp: Vector2i = props.footprint_at(idx).size
	last_edit_cell = props.cell_at(idx) + Vector2i(new_fp.x / 2, new_fp.y / 2)
	print("[资源] 旋转 %s -> %s（占地 %d×%d，阻挡 %d 格）" % [
		showname, "竖向（图片镜像）" if props.rotation_at(idx) == 1 else "横向",
		new_fp.x, new_fp.y, props.blocking_cells_at(idx).size()])


## 只刷新编辑画布与计数（小预览全量 setup 时已经带上物件，避免重建两遍）
func _refresh_prop_views() -> void:
	for view: GridView in grids:
		view.queue_redraw()
	tools.set_prop_count(props.count())


## 物件增删/清空：编辑画布重画，左上角 45° 预览重建立牌
func _refresh_props() -> void:
	_refresh_prop_views()
	if preview_mini != null and preview_mini.visible:
		preview_mini.refresh_props()


# ---------- 桥（独立桥层，不经过静态资源） ----------

func _on_bridge_committed(start: Vector2i, end: Vector2i, kind: int, erase: bool) -> void:
	if bridges == null:
		return
	if erase:
		if bridges.remove_at_cell(start) > 0:
			tools.mark_dirty()
			_refresh_bridge_views()
			print("[桥] 删除包含 %s 的桥" % str(start))
		return
	if not _bridge_span_allowed(start, end):
		Toast.show(self, "无效落桥：桥座各占一格陆地，桥身全部在水上，不能穿山/压物件/重复", true)
		print("[桥] 无效落桥：两个桥座必须各占一格陆地，桥身必须全部在水上；不能穿山/压物件/重复")
		return
	if not bridges.add_bridge(kind, start, end, map.grid_size):
		Toast.show(self, "放置失败：斜线、越界或与已有桥重叠", true)
		print("[桥] 放置失败：斜线、越界或与已有桥重叠")
		return
	tools.mark_dirty()
	last_edit_cell = end
	_refresh_bridge_views()
	print("[桥] 放置 %s 桥座 %s / %s，桥身 %d 格" % [
		BridgesData.kind_name(kind), str(start), str(end),
		BridgesData.span_cells(start, end).size() - 2])


func _bridge_span_allowed(start: Vector2i, end: Vector2i) -> bool:
	if map == null or bridges == null:
		return false
	if not BridgesData.is_straight_span(start, end):
		return false
	if not map.in_bounds(start) or not map.in_bounds(end):
		return false
	var cells: Array[Vector2i] = BridgesData.span_cells(start, end)
	if cells.size() < 3:
		return false
	for idx in cells.size():
		var cell: Vector2i = cells[idx]
		if map.get_mountain(cell) > 0:
			return false
		var wet: bool = map.get_water(cell) != GridDefs.Water.NONE
		if idx == 0 or idx == cells.size() - 1:
			if wet:
				return false
		elif not wet:
			return false
		for i in props.count():
			if props.footprint_at(i).has_point(cell):
				return false
	return not bridges.overlaps_span(start, end)


func _refresh_bridge_views() -> void:
	for view: GridView in grids:
		view.queue_redraw()
	if preview_mini != null and preview_mini.visible:
		preview_mini.refresh_bridges()
	if game_preview != null and game_preview.visible:
		game_preview.refresh_bridges()


func _on_brush_changed(layer: StringName, _value: int) -> void:
	if layer == &"prop" and tools.prop_asset_id != &"":
		grid_view.set_asset_preview(tools.prop_asset_id, tools.prop_rotation,
			tools.current_prop_scale())
	else:
		grid_view.set_asset_preview(&"")
	_update_status_hint()


## 方向按钮/R 键改变待放置方向：ghost 立即换占地与掩码
func _on_prop_rotation_changed(rot: int) -> void:
	if tools.brush_layer == &"prop" and tools.prop_asset_id != &"":
		grid_view.set_asset_preview(tools.prop_asset_id, rot, tools.current_prop_scale())


## 植物倍率改变：落点预览立即变成放大后的占地框
func _on_prop_scale_changed(_scale: int) -> void:
	if tools.brush_layer == &"prop" and tools.prop_asset_id != &"":
		grid_view.set_asset_preview(tools.prop_asset_id, tools.prop_rotation,
			tools.current_prop_scale())


func _on_props_clear_requested() -> void:
	if props == null or props.count() == 0:
		return
	_push_history()
	props.clear()
	tools.mark_dirty()
	_refresh_props()
	print("[物件] 已清除全部物件")


## 资源库“编辑”：打开模态导入页。Main.tscn 里只放一个实例，反复开关不重建。
func _on_asset_edit_requested() -> void:
	# 导入页是模态的：预览不再响应 G/R，避免用户在填表时把背后画面转走
	game_preview.set_process_unhandled_key_input(false)
	import_overlay.visible = true
	import_view.open_page()


## 导入页关闭：隐藏遮罩并重新读 catalog；增删/改占地立即回到左侧资源库和已放实例
func _on_import_view_closed() -> void:
	game_preview.set_process_unhandled_key_input(true)
	import_overlay.visible = false
	_reload_asset_defs(true)
	print("[资源] 导入页已关闭，资源库已刷新")


## 悬停信息（状态栏中区）：坐标 · 地形 · 高程 · 物件名——Shift+左键删除前先知道会删到什么
func _on_cell_hovered(cell: Vector2i) -> void:
	if cell.x < 0:
		status_hover.text = "(-,-)"
		return
	var parts: PackedStringArray = ["(%d,%d)" % [cell.x, cell.y]]
	if map.is_mountain(cell):
		parts.append("山体")
	elif map.get_water(cell) != GridDefs.Water.NONE:
		parts.append(String(GridDefs.WATER_NAMES.get(map.get_water(cell), "水")))
	else:
		parts.append(String(GridDefs.LAND_NAMES.get(map.get_land(cell), "?")))
	var road: int = map.get_road(cell)
	if road != GridDefs.Road.NONE:
		parts.append(String(GridDefs.ROAD_NAMES.get(road, "路")))
	parts.append("高 %s" % GridDefs.height_text(map.get_height(cell)))
	if props != null:
		var index: int = props.asset_index_at(cell)
		if index >= 0:
			var def: StaticAssetDef = props.asset(props.asset_id_at(index))
			parts.append(def.display_name if def != null else String(props.asset_id_at(index)))
	status_hover.text = " · ".join(parts)


## 状态栏左区：随模式和当前笔刷变化的上下文操作提示
func _update_status_hint() -> void:
	if render_mode:
		status_hint.text = "滚轮缩放 · 右键/中键拖动 · G 格线 · R 复位视角 · Ctrl+S 保存"
		return
	match tools.brush_layer:
		&"prop":
			var def: StaticAssetDef = props.asset(tools.prop_asset_id) if props != null else null
			var name: String = def.display_name if def != null else "未选中"
			status_hint.text = "放置 %s · 左键放置 · Shift+左键删除 · R 旋转 · Esc 退出" % name
		_:
			status_hint.text = "左键绘制 · Shift+左键擦除 · 右键拖动平移 · 滚轮缩放 · Ctrl+Z 撤销" + _brush_status()


## 状态栏右区：编辑模式显示缩放百分比，渲染模式显示像素/格（值没变不重写）
func _process(_delta: float) -> void:
	var text: String
	if render_mode:
		text = "%d px/格" % roundi(game_preview.current_ppm())
	else:
		text = "%d%%" % roundi(grid_view.zoom * 100.0)
	if text != status_zoom.text:
		status_zoom.text = text


## 左下角坐标条后面附上当前笔刷，方便一眼确认是否真的退出了资源放置。
func _brush_status() -> String:
	if tools == null:
		return ""
	match tools.brush_layer:
		&"prop":
			var def: StaticAssetDef = props.asset(tools.prop_asset_id) if props != null else null
			var label: String = " · 资源：%s" % (def.display_name if def != null else "未选中")
			if def != null and def.category == &"tree":
				label += "（%d×）" % tools.current_prop_scale()
			return label
		&"land":
			return " · 陆地"
		&"road":
			return " · 道路"
		&"bridge":
			return " · 桥：%s（两个桥座 + 水面桥身）" % BridgesData.kind_name(tools.brush_value)
		&"water":
			return " · 水域"
		&"flow":
			return " · 流向"
		&"mountain":
			return " · 山体"
		&"elevation":
			return " · 高程：%d 级" % tools.brush_value
	return ""


# ---------- 地图与配置事件 ----------

## 尺寸变化：同一个 MapData 对象原地 resize，重建渲染纹理、重铺格子缓存
func _on_map_resized(_size: Vector2i) -> void:
	var dropped: int = props.drop_out_of_bounds(map.grid_size)
	if dropped > 0:
		tools.mark_dirty()
		print("[物件] 尺寸缩小，丢弃 %d 个越界物件" % dropped)
	var dropped_bridges: int = bridges.drop_out_of_bounds(map.grid_size)
	if dropped_bridges > 0:
		tools.mark_dirty()
		print("[桥] 尺寸缩小，丢弃 %d 条越界桥" % dropped_bridges)
	for view: GridView in grids:
		view.set_map(map)
	_refresh_prop_views()
	_setup_mini_preview()
	if render_mode:
		game_preview.setup(map, rtool.settings, props, bridges,
			game_preview.home_center, game_preview.current_ppm())


## 打开地图：MapData 被整体替换，回灌给所有使用方
func _on_map_loaded(data: MapData) -> void:
	if data.ensure_precision():
		print("[地图] 高程已迁移到 0.25 级精度")
		tools.mark_dirty()
	map = data
	var flooded: int = map.ensure_water_sand()
	if flooded > 0:
		tools.mark_dirty()
		print("[地图] %d 个水下格子已迁移为沙地河床" % flooded)
	props = _load_props(tools.current_path)
	bridges = _load_bridges(tools.current_path)
	last_edit_cell = Vector2i(-1, -1)
	undo_stack.clear()
	redo_stack.clear()
	tools.set_map(map)
	for view: GridView in grids:
		view.set_map(map)
		view.set_props(props)
		view.set_bridges(bridges)
	_load_look(tools.current_path)
	rtool.set_shader_context(tools.current_path)
	Toast.show(self, "已打开 %s（%d×%d）" % [tools.current_path.get_file(), map.grid_size.x, map.grid_size.y])
	_refresh_prop_views()
	_setup_mini_preview()
	if render_mode:
		game_preview.setup(map, rtool.settings, props, bridges,
			game_preview.home_center, game_preview.current_ppm())


## 渲染配置面板任何改动：即时注入两个 45° 预览；look 也是地图状态的一部分，点亮脏标记。
## 载入边车 / 新建地图时的 set_settings 走 _suppress_dirty，不算用户改动。
func _on_render_settings_changed() -> void:
	if not _suppress_dirty:
		tools.mark_dirty()
	_apply_look_to_views()
	if material_params.visible:
		material_params.call("set_settings", rtool.settings)


## 把当前 RenderSettings 推给两个 45° 视图；小预览可见时重新整图取景
func _apply_look_to_views() -> void:
	preview_mini.apply_look(rtool.settings)
	if preview_mini.visible:
		preview_mini.fit_overview()
	game_preview.apply_look(rtool.settings)


# ---------- 渲染配置持久化（与地图同名的 .look.tres 边车） ----------

## 保存地图后顺手保存物件层与当前渲染配置
func _on_map_saved(path: String) -> void:
	var side: String = PropsData.sidecar_path(path)
	if not side.is_empty():
		var perr: Error = ResourceSaver.save(props, side)
		if perr == OK:
			print("[物件] 已保存 %d 个: %s" % [props.count(), side])
		else:
			push_warning("物件保存失败(%s): %s" % [error_string(perr), side])
	var bridge_side: String = BridgesData.sidecar_path(path)
	if not bridge_side.is_empty():
		var berr: Error = ResourceSaver.save(bridges, bridge_side)
		if berr == OK:
			print("[桥] 已保存 %d 条: %s" % [bridges.count(), bridge_side])
		else:
			push_warning("桥保存失败(%s): %s" % [error_string(berr), bridge_side])
	var look_path: String = MapSidecars.look_path(path)
	if not look_path.is_empty():
		var err: Error = ResourceSaver.save(rtool.settings, look_path)
		if err == OK:
			print("[渲染] 配置已保存: %s" % look_path)
		else:
			push_warning("渲染配置保存失败(%s): %s" % [error_string(err), look_path])
	# 地表着色器边车：首存拷一份母版给这张图（已存在则不动），面板状态随之刷新
	var shader_copy: String = MapSidecars.ensure_terrain_copy(path)
	if not shader_copy.is_empty():
		print("[渲染] 着色器副本就绪: %s" % shader_copy)
	rtool.set_shader_context(path)
	Toast.show(self, "已保存 %s" % path.get_file())
	if _quit_after_save and not tools.dirty:
		_quit_after_save = false
		get_tree().quit()


## 打开地图时，若存在同名边车就载入；没有则保持当前外观
func _load_look(map_path: String) -> void:
	var look_path: String = MapSidecars.look_path(map_path)
	if look_path.is_empty() or not ResourceLoader.exists(look_path):
		return
	var loaded: RenderSettings = load(look_path) as RenderSettings
	if loaded == null:
		push_warning("渲染配置不是有效资源: " + look_path)
		return
	_suppress_dirty = true
	rtool.set_settings(loaded)
	_suppress_dirty = false
	tools.clear_dirty()   # 载入边车不算用户改动：清掉可能被点亮的脏标记
	print("[渲染] 已载入配置: %s" % look_path)


# ---------- 地表着色器的按图副本（打开/重载/从母版重置） ----------

## 在资源管理器中定位地图专属着色器：副本不存在先物化（拷母版），
## 两个 45° 预览随即换用副本，保证所见即所编。
func _on_shader_open_requested() -> void:
	var map_path: String = tools.current_path
	var shader_copy: String = MapSidecars.ensure_terrain_copy(map_path)
	if shader_copy.is_empty():
		return
	OS.shell_show_in_file_manager(ProjectSettings.globalize_path(shader_copy))
	_reload_shader_views()
	rtool.set_shader_context(map_path)
	print("[渲染] 已定位着色器: %s" % shader_copy)


## 外部编辑器改完着色器后手动重载：两个 45° 预览原地换新，画面不闪
func _on_shader_reload_requested() -> void:
	_reload_shader_views()
	Toast.show(self, "着色器已重载：%s" % _live_shader_path().get_file())
	print("[渲染] 着色器已重载: %s" % _live_shader_path())


## 用母版覆盖地图副本（先确认——会抹掉这张图里定制过的着色器代码）
func _on_shader_reset_requested() -> void:
	var shader_copy: String = MapSidecars.terrain_shader_path(tools.current_path)
	if shader_copy.is_empty():
		return
	_reset_confirm.dialog_text = "用母版 runtime/terrain.gdshader 覆盖\n%s？\n\n这张图里定制过的着色器代码会被抹掉。" % shader_copy.get_file()
	_reset_confirm.popup_centered()


func _on_shader_reset_confirmed() -> void:
	if not MapSidecars.reset_terrain_copy(tools.current_path):
		return
	_reload_shader_views()
	print("[渲染] 着色器已从母版重置: %s" % MapSidecars.terrain_shader_path(tools.current_path))


func _reload_shader_views() -> void:
	preview_mini.reload_shader()
	game_preview.reload_shader()


## 当前预览实际在用的着色器文件（两个预览同源，取其一即可）
func _live_shader_path() -> String:
	var runtime = preview_mini.runtime
	return runtime.shader_path if runtime != null else MapSidecars.MASTER_TERRAIN_SHADER


## 物件边车：与地图同目录同名；缺失/损坏时返回空层，不阻塞地图打开。
## 资源目录必须先注入：footprint/阻挡格从定义里查，边车只存 id。
func _load_props(map_path: String):
	var data = PropsData.new()
	data.set_asset_defs(asset_defs)
	var side: String = PropsData.sidecar_path(map_path)
	if side.is_empty() or not ResourceLoader.exists(side):
		return data
	var loaded = load(side)
	if loaded == null or loaded.get_script() != PropsData:
		push_warning("物件边车不是有效资源: " + side)
		return data
	loaded.set_asset_defs(asset_defs)
	if loaded.sanitize():
		print("[物件] 物件边车已升级/清理: " + side)
	var dropped: int = loaded.drop_out_of_bounds(map.grid_size)
	if dropped > 0:
		push_warning("物件边车有 %d 个越界物件已丢弃: %s" % [dropped, side])
	print("[物件] 已载入 %d 个: %s" % [loaded.count(), side])
	return loaded


## 桥层边车：与地图同名 .bridges.tres；缺失/损坏时返回空层。
func _load_bridges(map_path: String):
	var data = BridgesData.new()
	var side: String = BridgesData.sidecar_path(map_path)
	if side.is_empty() or not ResourceLoader.exists(side):
		return data
	var loaded = load(side)
	if loaded == null or loaded.get_script() != BridgesData:
		push_warning("桥边车不是有效资源: " + side)
		return data
	if loaded.sanitize():
		print("[桥] 旧边车条目已清理: " + side)
	var dropped: int = loaded.drop_out_of_bounds(map.grid_size)
	if dropped > 0:
		push_warning("桥边车有 %d 条越界桥已丢弃: %s" % [dropped, side])
	print("[桥] 已载入 %d 条: %s" % [loaded.count(), side])
	return loaded


# ---------- 撤销 / 重做 ----------

## 压入一份"改动前"的整图+物件快照（落笔开始、清空物件、改尺寸之前调用）
func _push_history() -> void:
	if map == null:
		return
	undo_stack.append(_snapshot_state())
	if undo_stack.size() > HISTORY_MAX:
		undo_stack.pop_front()
	redo_stack.clear()


func _snapshot_state() -> Dictionary:
	return {"map": _snapshot_map(), "props": props.duplicate_data(), "bridges": bridges.duplicate_data()}


func _snapshot_map() -> MapData:
	var snap: MapData = MapData.new()
	snap.grid_size = map.grid_size
	snap.elev_unit = map.elev_unit
	snap.land = map.land.duplicate()
	snap.water = map.water.duplicate()
	snap.flow = map.flow.duplicate()
	snap.road = map.road.duplicate()
	snap.mountain = map.mountain.duplicate()
	snap.elevation = map.elevation.duplicate()
	return snap


## 把快照写回同一个 MapData / PropsData 对象（视图都持有引用，不能换对象）
func _restore_state(snap: Dictionary) -> void:
	_restore_map(snap["map"] as MapData)
	if props != null and snap.has("props"):
		props.restore_from(snap["props"])
		_refresh_prop_views()
	if bridges != null and snap.has("bridges"):
		bridges.restore_from(snap["bridges"])
		_refresh_bridge_views()
	# 地图对象已原地换掉，当前可见的 45° 视图要按新数据重建
	if render_mode:
		game_preview.setup(map, rtool.settings, props, bridges, game_preview.home_center, game_preview.current_ppm())
	else:
		_setup_mini_preview()


func _restore_map(snap: MapData) -> void:
	map.grid_size = snap.grid_size
	map.elev_unit = snap.elev_unit
	map.land = snap.land.duplicate()
	map.water = snap.water.duplicate()
	map.flow = snap.flow.duplicate()
	map.road = snap.road.duplicate()
	map.mountain = snap.mountain.duplicate()
	map.elevation = snap.elevation.duplicate()
	tools.set_map(map)
	for view: GridView in grids:
		view.set_map(map)
	_refresh_views()
	tools.mark_dirty()


func _undo() -> void:
	if undo_stack.is_empty():
		Toast.show(self, "没有可撤销的操作")
		return
	redo_stack.append(_snapshot_state())
	var snap: Dictionary = undo_stack.pop_back()
	_restore_state(snap)
	print("[编辑] 撤销（还可撤销 %d 步）" % undo_stack.size())


func _redo() -> void:
	if redo_stack.is_empty():
		Toast.show(self, "没有可重做的操作")
		return
	undo_stack.append(_snapshot_state())
	var snap: Dictionary = redo_stack.pop_back()
	_restore_state(snap)
	print("[编辑] 重做（还可重做 %d 步）" % redo_stack.size())


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key: InputEventKey = event as InputEventKey
	if import_overlay.visible:
		return   # 导入页打开时不响应用户在编辑器里的撤销/重做/R
	if not key.ctrl_pressed:
		# 编辑模式：Esc 强制退出资源放置；R 旋转鼠标下的资源；没有资源就循环待放置方向。
		# 渲染模式的 R 是“回到初始视角”，由 GamePreview 自己处理。
		if not render_mode and key.keycode == KEY_ESCAPE and tools.brush_layer == &"prop":
			tools.exit_prop_mode()
			get_viewport().set_input_as_handled()
			return
		if not render_mode and key.keycode == KEY_R:
			_rotate_asset_at(grid_view.hover_cell())
			get_viewport().set_input_as_handled()
		return
	# Ctrl 系快捷键：文件操作 + 撤销/重做 + 着色器重载
	match key.keycode:
		KEY_S:
			if key.shift_pressed:
				tools.save_as_map()
			else:
				tools.save_map()
			get_viewport().set_input_as_handled()
		KEY_R:
			if render_mode:
				_on_shader_reload_requested()
				get_viewport().set_input_as_handled()
		KEY_N:
			_on_new_map_requested()
			get_viewport().set_input_as_handled()
		KEY_O:
			_on_open_map_requested()
			get_viewport().set_input_as_handled()
		KEY_Z:
			if key.shift_pressed:
				_redo()
			else:
				_undo()
			get_viewport().set_input_as_handled()
		KEY_Y:
			_redo()
			get_viewport().set_input_as_handled()


# ---------- 文件工作流（文件条 / 快捷键共用入口） ----------

## 统一的未保存确认流：OK=保存后继续，自定义按钮=不保存直接继续，取消=留在编辑器。
## _pending_flow 记住确认完要去干什么（new / open / quit）。
func _request_after_unsaved(flow: StringName, ok_text: String) -> void:
	_pending_flow = flow
	_unsaved_confirm.dialog_text = "当前地图有未保存的修改。"
	_unsaved_confirm.ok_button_text = ok_text
	_unsaved_confirm.popup_centered()


func _on_unsaved_confirmed() -> void:
	tools.save_map()   # 有路径直接存；没路径弹另存对话框，用户取消则流程自然中止
	if _pending_flow == &"quit":
		if not tools.dirty:
			get_tree().quit()
		else:
			_quit_after_save = true   # 走另存对话框：_on_map_saved 里退
	else:
		_proceed_pending_flow()


func _on_unsaved_custom(_action: StringName) -> void:
	_unsaved_confirm.hide()
	_proceed_pending_flow()


func _proceed_pending_flow() -> void:
	match _pending_flow:
		&"new":
			_newmap_dialog.popup_centered()
		&"open":
			_open_map_after_confirm()
		&"quit":
			get_tree().quit()
	_pending_flow = &""


## 新建地图：脏状态先确认，再弹尺寸对话框
func _on_new_map_requested() -> void:
	if tools.dirty:
		_request_after_unsaved(&"new", "保存后新建")
		return
	_newmap_dialog.popup_centered()


func _on_newmap_preset(size: int) -> void:
	_newmap_w.set_value_no_signal(size)
	_newmap_h.set_value_no_signal(size)


func _on_new_map_confirmed() -> void:
	_apply_new_map(Vector2i(int(_newmap_w.value), int(_newmap_h.value)))


## 新地图本体：换 MapData/边车层/外观默认值，全部视图重灌（与打开地图同一套流程）
func _apply_new_map(size: Vector2i) -> void:
	map = MapData.create(size)
	props = PropsData.new()
	props.set_asset_defs(asset_defs)
	bridges = BridgesData.new()
	last_edit_cell = Vector2i(-1, -1)
	undo_stack.clear()
	redo_stack.clear()
	_suppress_dirty = true
	rtool.set_settings(RenderSettings.new())
	_suppress_dirty = false
	tools.reset_file_state()
	tools.set_map(map)
	for view: GridView in grids:
		view.set_map(map)
		view.set_props(props)
		view.set_bridges(bridges)
	_refresh_prop_views()
	_setup_mini_preview()
	if render_mode:
		game_preview.setup(map, rtool.settings, props, bridges, Vector2(map.grid_size) * 0.5)
	Toast.show(self, "新建地图 %d×%d（未保存）" % [size.x, size.y])
	print("[地图] 新建地图 %d×%d（未保存）" % [size.x, size.y])


## 打开地图：脏状态先确认；列表弹窗（maps/ 没图时回退 FileDialog）
func _on_open_map_requested() -> void:
	if tools.dirty:
		_request_after_unsaved(&"open", "保存后打开")
		return
	_open_map_after_confirm()


func _open_map_after_confirm() -> void:
	if map_browser.available():
		map_browser.popup_centered()
	else:
		tools.open_map_dialog()


func _open_map_chosen(path: String) -> void:
	tools.open_map(path)


# ---------- 关窗保护 ----------

## 关窗：干净直接退；有修改弹"保存 / 不保存直接继续 / 取消"
func _on_close_requested() -> void:
	if not tools.dirty:
		get_tree().quit()
		return
	_request_after_unsaved(&"quit", "保存并关闭")


## 点“材质参数”：打开大面板里的材质浮窗（颜色/过渡矩阵），并把它的改动接回重渲
func _on_material_params_requested() -> void:
	material_params.call("set_settings", rtool.settings)
	material_params.call("open")
	print("[材质] 材质参数窗口已打开")


func _on_material_params_changed() -> void:
	_apply_look_to_views()


func _on_material_params_visibility() -> void:
	game_preview.set_hint_visible(not material_params.visible)
