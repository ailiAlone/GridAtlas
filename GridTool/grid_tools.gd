extends VBoxContainer
## GridTools —— 编辑器左侧工具面板。
## 负责：笔刷选择（陆地/道路/水域/流向）、地形工具（抬升/压低/平滑/展平）、地图尺寸、保存/打开。
## 状态变化通过信号通知外部，由 main.gd 负责把笔刷和地图接到 GridView 上。
## MapData 只归 main.gd 所有：这里的 map 是 main 通过 set_map 注入的借用引用，
## 本脚本不创建、不替换；打开文件得到的新地图经 map_loaded 信号交还 main。


# ---------- 对外信号 ----------

## 笔刷切换：layer 为 &"land"/&"road"/&"water"/&"flow"/&"terrain"，value 为 GridDefs 枚举值
signal brush_changed(layer: StringName, value: int)
signal map_resized(size: Vector2i)
signal map_loaded(data: MapData)
signal map_saved(path: String)      # 保存成功后上报路径（渲染配置随之写边车文件）
signal edit_checkpoint              # 即将发生不可逆改动（如改尺寸）：main 在这里压撤销快照
signal elevation_view_changed(on: bool)
signal brush_size_changed(size: int)
signal rect_mode_changed(on: bool)
signal prop_rotation_changed(rot: int)


# ---------- 节点引用 ----------

@onready var landscontainer:HFlowContainer = $"PanelContainer/VBoxContainer/HFlowContainer"
@onready var roadscontainer:HFlowContainer = $"PanelContainer4/VBoxContainer/HFlowContainer"
@onready var waterscontainer:HBoxContainer = $"PanelContainer2/VBoxContainer/HBoxContainer"
@onready var directionscontainer:GridContainer = $"PanelContainer2/VBoxContainer/HBoxContainer/GridContainer"
@onready var elevationviewbutton:Button = $"PanelTerrain/VBoxContainer/Label/Button"
@onready var terrainraise:Button = $"PanelTerrain/VBoxContainer/HFlowContainer/ButtonRaise"
@onready var terrainlower:Button = $"PanelTerrain/VBoxContainer/HFlowContainer/ButtonLower"
@onready var terrainsmooth:Button = $"PanelTerrain/VBoxContainer/HFlowContainer/ButtonSmooth"
@onready var terrainflatten:Button = $"PanelTerrain/VBoxContainer/HFlowContainer/ButtonFlatten"
@onready var terrainstrength:HSlider = $"PanelTerrain/VBoxContainer/HBoxContainer/Slider"
@onready var terrainvaluelabel:Label = $"PanelTerrain/VBoxContainer/HBoxContainer/Value"
@onready var elevationspin:SpinBox = $"PanelTerrain/VBoxContainer/HBoxHeight/ElevationSpin"
@onready var terrainstrengthrow:HBoxContainer = $"PanelTerrain/VBoxContainer/HBoxContainer"
@onready var terrainheightrow:HBoxContainer = $"PanelTerrain/VBoxContainer/HBoxHeight"
@onready var brushcontainer:HFlowContainer = $"PanelContainerBrush/VBoxContainer/HFlowContainer"
@onready var brushplusbutton:Button = $"PanelContainerBrush/VBoxContainer/HFlowContainer/ButtonPlus"
@onready var brushrectbutton:Button = $"PanelContainerBrush/VBoxContainer/ButtonRect"
@onready var savebutton:Button = $"PanelContainer5/VBoxContainer/HBoxContainer/Button"
@onready var loadbutton:Button = $"PanelContainer5/VBoxContainer/Label/Button"
@onready var filenamelabel:Label = $"PanelContainer5/VBoxContainer/HBoxContainer/Label"
@onready var filedialog:FileDialog = $"PanelContainer5/FileDialog"
@onready var widthbox:SpinBox = $"PanelContainer5/VBoxContainer/HBoxContainer2/SpinBox"
@onready var heightbox:SpinBox = $"PanelContainer5/VBoxContainer/HBoxContainer2/SpinBox2"
@onready var propstool: PanelContainer = $"PropsTool"




# ---------- 按钮名 -> 业务参数（枚举定义见 grid_defs.gd） ----------

const LAND_BUTTONS: Dictionary = {
	"Grass": GridDefs.Land.GRASS,
	"Sand": GridDefs.Land.SAND,
	"Wasteland": GridDefs.Land.WASTELAND,
	"Snow": GridDefs.Land.SNOW,
	"Swamp": GridDefs.Land.SWAMP,
	"Ice": GridDefs.Land.ICE,
}

const ROAD_BUTTONS: Dictionary = {
	"None": GridDefs.Road.NONE,
	"Dirt": GridDefs.Road.DIRT,
	"Gravel": GridDefs.Road.GRAVEL,
	"StoneBrick": GridDefs.Road.STONE_BRICK,
}

const WATER_BUTTONS: Dictionary = {
	"ShallowWater": GridDefs.Water.SHALLOW,
	"DeepWater": GridDefs.Water.DEEP,
}

# Godot 2D 坐标系：+x 向右、+y 向下，北为 -y
const DIRECTION_BUTTONS: Dictionary = {
	"NW": Vector2i(-1, -1), "N": Vector2i(0, -1), "NE": Vector2i(1, -1),
	"W": Vector2i(-1, 0), "Center": Vector2i(0, 0), "E": Vector2i(1, 0),
	"SW": Vector2i(-1, 1), "S": Vector2i(0, 1), "SE": Vector2i(1, 1),
}


# ---------- 编辑器状态 ----------

var map: MapData  # 借用引用：由 main.gd 注入，不自己创建或替换
var brush_layer: StringName = &"land"
var brush_value: int = GridDefs.Land.GRASS
var brush_height: float = 1.0  # 展平的目标高度（级，0.25 步长）
var terrain_mode: StringName = &"raise"  # 地形笔刷：raise / lower / smooth / flatten
var terrain_strength: float = 0.25       # 每次落笔的高度变化量（级）
var terrain_group: ButtonGroup = ButtonGroup.new()  # 地形模式互斥
var brush_size: int = 1
var brush_size_max: int = 3  # 当前可选的最大笔刷边长（与数字按钮数一致）
var sizegroup: ButtonGroup = ButtonGroup.new()  # 笔刷大小互斥选择
var prop_asset_id: StringName = &""  # 当前选中的资源定义 id（空串=未选资源）
var prop_rotation: int = 0           # 待放置方向：0=横向 / 1=竖向（图片水平镜像）
var current_path: String = ""
var dirty: bool = false
var _saving_via_dialog: bool = false


func _ready() -> void:
	_connect_group(landscontainer, LAND_BUTTONS, _on_land_button)
	_connect_group(roadscontainer, ROAD_BUTTONS, _on_road_button)
	_connect_group(waterscontainer, WATER_BUTTONS, _on_water_button)
	_connect_group(directionscontainer, DIRECTION_BUTTONS, _on_direction_button)
	elevationspin.value_changed.connect(_on_elevation_value)
	elevationviewbutton.toggle_mode = true
	elevationviewbutton.toggled.connect(_on_elevation_view_toggled)
	_setup_terrain_buttons()
	terrainstrength.value_changed.connect(_on_terrain_strength)
	_setup_size_buttons()
	brushplusbutton.pressed.connect(_on_brush_plus)
	brushrectbutton.toggle_mode = true
	brushrectbutton.toggled.connect(_on_rect_toggled)
	savebutton.pressed.connect(_on_save_pressed)
	loadbutton.pressed.connect(_on_load_pressed)
	filedialog.file_selected.connect(_on_file_selected)
	widthbox.value_changed.connect(_on_width_changed)
	heightbox.value_changed.connect(_on_height_changed)
	propstool.asset_selected.connect(_on_asset_selected)
	propstool.rotation_selected.connect(_on_rotation_selected)
	_update_save_button()
	_update_file_label()


## 把 container 下与 mapping 键同名的按钮统一连到 handler，
## 并把 mapping 里的值作为参数附加进去（pressed 本身无参数）。
func _connect_group(container: Node, mapping: Dictionary, handler: Callable) -> void:
	for button_name: String in mapping:
		var button: Button = container.get_node(button_name) as Button
		button.pressed.connect(handler.bind(mapping[button_name]))


# ---------- 信号处理（只做转发） ----------

func _on_land_button(id: int) -> void:
	select_land(id)

func _on_road_button(id: int) -> void:
	select_road(id)

func _on_water_button(id: int) -> void:
	select_water(id)

func _on_direction_button(dir: Vector2i) -> void:
	select_direction(dir)

func _on_elevation_value(value: float) -> void:
	brush_height = snappedf(value, 0.25)
	print("[笔刷] 展平高度 -> %s" % GridDefs.height_text(brush_height))

## 高程视图开关：按下时画布改用红绿归一化显示高度，按钮保持高亮、文字变为“普通视图”
func _on_elevation_view_toggled(pressed: bool) -> void:
	elevationviewbutton.text = "普通视图" if pressed else "高程视图"
	elevation_view_changed.emit(pressed)
	print("[视图] %s" % ("高程视图（红绿归一化）" if pressed else "普通视图"))

func _on_size_toggled(pressed: bool, size: int) -> void:
	if pressed:
		brush_size = size
		brush_size_changed.emit(size)
		print("[笔刷] 大小 %d×%d" % [size, size])

func _on_brush_plus() -> void:
	add_brush_size()

func _on_rect_toggled(pressed: bool) -> void:
	rect_mode_changed.emit(pressed)
	print("[笔刷] %s" % ("矩形填充模式（拖选区域，右键=擦除填充）" if pressed else "涂画模式"))


## 资源库：选中即切到资源笔刷；真正的放置/擦除由 GridView 上报、main 写数据
func _on_asset_selected(asset_id: StringName) -> void:
	prop_asset_id = asset_id
	brush_layer = &"prop"
	brush_changed.emit(&"prop", -1)
	print("[笔刷] 资源 -> %s" % asset_name(asset_id))


func _on_rotation_selected(rot: int) -> void:
	prop_rotation = posmod(rot, 2)
	prop_rotation_changed.emit(prop_rotation)
	print("[笔刷] 资源方向 -> %s" % rotation_name(prop_rotation))


## 鼠标不在已放资源上时按 R：在横向/竖向之间切换
func cycle_rotation() -> void:
	prop_rotation = (prop_rotation + 1) % 2
	propstool.set_pending_rotation(prop_rotation)
	prop_rotation_changed.emit(prop_rotation)
	print("[笔刷] 资源方向 -> %s" % rotation_name(prop_rotation))


static func rotation_name(rot: int) -> String:
	return "竖向（图片镜像）" if posmod(rot, 2) == 1 else "横向"


func set_asset_defs(defs: Dictionary) -> void:
	propstool.set_asset_defs(defs)
	# 当前选中的资源被删除/改名：退回陆地笔刷，避免之后落笔引用一个不存在的 id
	if prop_asset_id != &"" and not defs.has(prop_asset_id):
		prop_asset_id = &""
		if brush_layer == &"prop":
			brush_layer = &"land"
			brush_value = GridDefs.Land.GRASS
			brush_changed.emit(&"land", brush_value)


func asset_name(asset_id: StringName) -> String:
	var def: StaticAssetDef = propstool.asset_defs.get(asset_id) as StaticAssetDef
	if def != null:
		return def.display_name
	return String(asset_id)


func set_prop_count(n: int) -> void:
	propstool.set_count(n)

func _on_save_pressed() -> void:
	save_map()

func _on_load_pressed() -> void:
	open_map_dialog()

func _on_file_selected(path: String) -> void:
	if _saving_via_dialog:
		_saving_via_dialog = false
		_do_save(path)
	else:
		open_map(path)

func _on_width_changed(value: float) -> void:
	resize_map(Vector2i(int(value), int(heightbox.value)))

func _on_height_changed(value: float) -> void:
	resize_map(Vector2i(int(widthbox.value), int(value)))


# ---------- 笔刷 ----------

func select_land(id: int) -> void:
	_set_brush(&"land", id)

func select_road(id: int) -> void:
	_set_brush(&"road", id)

func select_water(id: int) -> void:
	_set_brush(&"water", id)

func select_direction(dir: Vector2i) -> void:
	_set_brush(&"flow", GridDefs.flow_from_vector(dir))


## 地形模式：四个互斥 toggle，默认"抬升"。抬升/压低/平滑吃强度，展平吃高度
func _setup_terrain_buttons() -> void:
	var buttons: Array[Button] = [terrainraise, terrainlower, terrainsmooth, terrainflatten]
	var modes: Array[StringName] = [&"raise", &"lower", &"smooth", &"flatten"]
	for i in buttons.size():
		var button: Button = buttons[i]
		button.toggle_mode = true
		button.button_group = terrain_group
		button.toggled.connect(_on_terrain_mode.bind(modes[i]))
		button.pressed.connect(_on_terrain_pressed)
	terrainraise.set_pressed_no_signal(true)
	terrainvaluelabel.text = "%.2f" % terrain_strength
	_update_terrain_rows()


## 互斥组里点击"已经选中"的那个按钮不会发 toggled（比如刚启动时的抬升），
## 但 pressed 每次点击都发：用它兜底，保证点过地形按钮后地形笔刷一定处于激活状态。
func _on_terrain_pressed() -> void:
	propstool.clear_selection()
	prop_asset_id = &""
	if brush_layer != &"terrain":
		brush_layer = &"terrain"
		brush_changed.emit(&"terrain", 0)
		_update_terrain_rows()


func _on_terrain_mode(on: bool, mode: StringName) -> void:
	if not on:
		return
	propstool.clear_selection()
	prop_asset_id = &""
	terrain_mode = mode
	brush_layer = &"terrain"
	brush_changed.emit(&"terrain", 0)
	_update_terrain_rows()
	print("[笔刷] 地形 -> %s（%s）" % [terrain_mode_text(), terrain_param_text()])


func _on_terrain_strength(value: float) -> void:
	terrain_strength = value
	terrainvaluelabel.text = "%.2f" % value


func terrain_mode_text() -> String:
	if terrain_mode == &"raise":
		return "抬升"
	if terrain_mode == &"lower":
		return "压低"
	if terrain_mode == &"flatten":
		return "展平"
	return "平滑"


## 当前模式的生效参数文本：展平报目标高度，其余三个报强度
func terrain_param_text() -> String:
	if terrain_mode == &"flatten":
		return "高度 %s" % GridDefs.height_text(brush_height)
	return "强度 %.2f" % terrain_strength


## 两行参数各自只服务一部分模式：把当前用不到的那行压暗，避免误读
func _update_terrain_rows() -> void:
	var flatten: bool = terrain_mode == &"flatten"
	terrainstrengthrow.modulate = Color(1.0, 1.0, 1.0, 0.45 if flatten else 1.0)
	terrainheightrow.modulate = Color(1.0, 1.0, 1.0, 1.0 if flatten else 0.45)


## 初始化 1/2/3 尺寸按钮为互斥 toggle 组，默认选中 1
func _setup_size_buttons() -> void:
	for i in range(1, brush_size_max + 1):
		var button: Button = brushcontainer.get_node("Button%d" % i) as Button
		_bind_size_button(button, i)
	var first: Button = brushcontainer.get_node("Button1") as Button
	first.set_pressed_no_signal(true)

func _bind_size_button(button: Button, size: int) -> void:
	button.toggle_mode = true
	button.button_group = sizegroup
	button.toggled.connect(_on_size_toggled.bind(size))


## 点击 + ：新增下一个笔刷尺寸按钮（1,2,3,4...），插入到 + 之前
func add_brush_size() -> void:
	brush_size_max += 1
	var button: Button = Button.new()
	button.text = str(brush_size_max)
	button.custom_minimum_size = Vector2(32, 32)
	_bind_size_button(button, brush_size_max)
	brushcontainer.add_child(button)
	brushcontainer.move_child(button, brushplusbutton.get_index())
	print("[笔刷] 新增大小 %d" % brush_size_max)

func _set_brush(layer: StringName, value: int) -> void:
	propstool.clear_selection()
	prop_asset_id = &""
	brush_layer = layer
	brush_value = value
	brush_changed.emit(layer, value)
	print("[笔刷] %s -> %s" % [GridDefs.LAYER_NAMES.get(layer, layer), value_name(layer, value)])


## 笔刷值的可读名称（控制台输出用）
func value_name(layer: StringName, value: int) -> String:
	if layer == &"land":
		return String(GridDefs.LAND_NAMES.get(value, str(value)))
	elif layer == &"road":
		return String(GridDefs.ROAD_NAMES.get(value, str(value)))
	elif layer == &"water":
		return String(GridDefs.WATER_NAMES.get(value, str(value)))
	elif layer == &"flow":
		return String(GridDefs.Flow.keys()[value])
	elif layer == &"terrain":
		return terrain_mode_text()
	elif layer == &"prop":
		return asset_name(prop_asset_id) if prop_asset_id != &"" else "资源"
	return str(value)


# ---------- 地图 / 文件 ----------

func set_map(data: MapData) -> void:
	map = data
	_sync_size_boxes()


## 数据被修改后调用（由 main.gd 在绘制格子后触发）
func mark_dirty() -> void:
	if not dirty:
		dirty = true
		_update_save_button()


## 有已保存路径就直接覆盖保存，否则弹出保存对话框
func save_map() -> void:
	if map == null:
		return
	if current_path != "" and FileAccess.file_exists(current_path):
		_do_save(current_path)
		return
	DirAccess.make_dir_recursive_absolute("res://GridData/maps")
	filedialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	filedialog.current_dir = "res://GridData/maps"
	_saving_via_dialog = true
	filedialog.popup_centered(Vector2i(800, 600))


## 弹出打开对话框，选择已有的 .tres 地图
func open_map_dialog() -> void:
	DirAccess.make_dir_recursive_absolute("res://GridData/maps")
	filedialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	filedialog.current_dir = "res://GridData/maps"
	_saving_via_dialog = false
	filedialog.popup_centered(Vector2i(800, 600))


func open_map(path: String) -> void:
	var loaded: MapData = load(path) as MapData
	if loaded == null:
		push_warning("不是有效的地图文件: " + path)
		return
	current_path = path
	dirty = false
	_update_save_button()
	_update_file_label()
	# 不自己持有：新地图随信号交给 main，main 回灌给所有使用方（含本面板）
	map_loaded.emit(loaded)
	print("[文件] 已打开: %s (%d×%d)" % [path, loaded.grid_size.x, loaded.grid_size.y])


func resize_map(size: Vector2i) -> void:
	if map == null or size == map.grid_size:
		return
	edit_checkpoint.emit()
	map.resize(size)
	mark_dirty()
	map_resized.emit(size)
	print("[地图] 尺寸改为 %d×%d" % [size.x, size.y])


func _do_save(path: String) -> void:
	if not path.ends_with(".tres"):
		path += ".tres"
	var err: Error = ResourceSaver.save(map, path)
	if err == OK:
		current_path = path
		dirty = false
		_update_save_button()
		_update_file_label()
		print("[文件] 已保存: %s" % path)
		map_saved.emit(path)
	else:
		push_error("保存失败(%s): %s" % [error_string(err), path])


func _sync_size_boxes() -> void:
	if map == null:
		return
	widthbox.set_value_no_signal(map.grid_size.x)
	heightbox.set_value_no_signal(map.grid_size.y)


func _update_save_button() -> void:
	savebutton.text = "保存*" if dirty else "保存"


func _update_file_label() -> void:
	if current_path == "":
		filenamelabel.text = "未命名"
	else:
		filenamelabel.text = current_path.get_file()
