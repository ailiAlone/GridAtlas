extends VBoxContainer

const BridgesData = preload("res://data/bridges_data.gd")
const LevelButtonScene = preload("res://editor/ui/level_button.tscn")
## GridTools —— 编辑器左侧工具面板。
## 负责：笔刷选择（陆地/山体/道路/水域/流向/高程）、地图尺寸、保存/打开。
## 状态变化通过信号通知外部，由 main.gd 负责把笔刷和地图接到 GridView 上。
## MapData 只归 main.gd 所有：这里的 map 是 main 通过 set_map 注入的借用引用，
## 本脚本不创建、不替换；打开文件得到的新地图经 map_loaded 信号交还 main。


# ---------- 对外信号 ----------

## 笔刷切换：layer 为 &"land"/&"mountain"/&"road"/&"water"/&"flow"/&"elevation"，
## value 为 GridDefs 枚举值；高程笔刷时为整级高度。
signal brush_changed(layer: StringName, value: int)
signal map_resized(size: Vector2i)
signal map_loaded(data: MapData)
signal map_saved(path: String)      # 保存成功后上报路径（渲染配置随之写边车文件）
signal edit_checkpoint              # 即将发生不可逆改动（如改尺寸）：main 在这里压撤销快照
signal elevation_view_changed(on: bool)
signal brush_size_changed(size: int)
signal rect_mode_changed(on: bool)
signal prop_rotation_changed(rot: int)
signal prop_scale_changed(scale: int)
signal dirty_state_changed(on: bool)   # 文件条（FileBar）据此显示 ●/○
signal map_path_changed(path: String)  # 文件条据此显示地图名


# ---------- 节点引用（分节为 FoldSection 实例，内容挂在 Content/Body 下） ----------

@onready var landscontainer:HFlowContainer = $"SectionLand/VBox/Content/Body/HFlowContainer"
@onready var mountainbutton:Button = $"SectionLand/VBox/Content/Body/HFlowContainer/Mountain"
@onready var roadscontainer:HFlowContainer = $"SectionRoad/VBox/Content/Body/HFlowContainer"
@onready var bridgescontainer:HFlowContainer = $"SectionRoad/VBox/Content/Body/BridgeFlow"
@onready var waterscontainer:HBoxContainer = $"SectionWater/VBox/Content/Body/HBoxWater"
@onready var directionscontainer:GridContainer = $"SectionWater/VBox/Content/Body/HBoxFlow/GridContainer"
@onready var elevationviewbutton:Button = $"SectionTerrain/VBox/Content/Body/HBoxView/ElevationView"
@onready var elevationcontainer:HFlowContainer = $"SectionTerrain/VBox/Content/Body/HFlowContainerElevation"
@onready var elevationplusbutton:Button = $"SectionTerrain/VBox/Content/Body/HFlowContainerElevation/ButtonPlus"
@onready var brushcontainer:HFlowContainer = $"SectionBrush/VBox/Content/Body/HFlowContainer"
@onready var brushplusbutton:Button = $"SectionBrush/VBox/Content/Body/HFlowContainer/ButtonPlus"
@onready var brushrectbutton:Button = $"SectionBrush/VBox/Content/Body/ButtonRect"
@onready var filedialog:FileDialog = $"FileDialog"
@onready var widthbox:SpinBox = $"SectionData/VBox/Content/Body/HBoxContainer2/SpinBox"
@onready var heightbox:SpinBox = $"SectionData/VBox/Content/Body/HBoxContainer2/SpinBox2"
@onready var propstool: VBoxContainer = $"PropsTool"




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

const BRIDGE_BUTTONS: Dictionary = {
	"LogBridge": BridgesData.Kind.LOG,
	"WoodBridge": BridgesData.Kind.WOOD,
	"StoneBridge": BridgesData.Kind.STONE,
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

const ELEVATION_MAX: int = 32  # + 增大等级的上限（存档上限 255 单位 = 63.75 级）

var map: MapData  # 借用引用：由 main.gd 注入，不自己创建或替换
var brush_layer: StringName = &"land"
var brush_value: int = GridDefs.Land.GRASS
var brush_size: int = 1
var brush_size_max: int = 3  # 当前可选的最大笔刷边长（与数字按钮数一致）
@export var sizegroup: ButtonGroup   # 笔刷大小互斥组（静态定义在 tscn）
var elevation_value: int = 1  # 高程笔刷的目标级数
var elevation_max: int = 3    # 当前可选的最大高程级数（与数字按钮数一致）
@export var elevation_group: ButtonGroup   # 高程级别互斥组（静态定义在 tscn）
var prop_asset_id: StringName = &""  # 当前选中的资源定义 id（空串=未选资源）
var prop_rotation: int = 0           # 待放置方向：0=横向 / 1=竖向（图片水平镜像）
var prop_scale: int = 1              # 植物倍率：1=原大小 / 2=占地 2×2、图片 1.5×
var _last_edit_layer: StringName = &"land"  # 退出资源放置时回到的上一支笔刷
var _last_edit_value: int = GridDefs.Land.GRASS
var current_path: String = ""
var dirty: bool = false
var _saving_via_dialog: bool = false


func _ready() -> void:
	_connect_group(landscontainer, LAND_BUTTONS, _on_land_button)
	mountainbutton.pressed.connect(_on_mountain_button)
	_connect_group(roadscontainer, ROAD_BUTTONS, _on_road_button)
	_connect_group(bridgescontainer, BRIDGE_BUTTONS, _on_bridge_button)
	_connect_group(waterscontainer, WATER_BUTTONS, _on_water_button)
	_connect_group(directionscontainer, DIRECTION_BUTTONS, _on_direction_button)
	elevationviewbutton.toggle_mode = true
	elevationviewbutton.toggled.connect(_on_elevation_view_toggled)
	_setup_elevation_buttons()
	elevationplusbutton.pressed.connect(_on_elevation_plus)
	_setup_size_buttons()
	brushplusbutton.pressed.connect(_on_brush_plus)
	brushrectbutton.toggle_mode = true
	brushrectbutton.toggled.connect(_on_rect_toggled)
	filedialog.file_selected.connect(_on_file_selected)
	widthbox.value_changed.connect(_on_width_changed)
	heightbox.value_changed.connect(_on_height_changed)
	propstool.asset_selected.connect(_on_asset_selected)
	propstool.rotation_selected.connect(_on_rotation_selected)
	propstool.scale_selected.connect(_on_scale_selected)
	_refresh_brush_buttons()
	_update_save_button()
	_update_file_label()


## 把面板按钮的选中态同步成当前笔刷（外部切笔刷/退出放置时也保持一致）。
## 按钮的互斥组与三态样式都在 grid_tools.tscn 里静态配置，这里只改选中态。
func _refresh_brush_buttons() -> void:
	for container: Node in [landscontainer, roadscontainer, waterscontainer,
			bridgescontainer, directionscontainer]:
		for child: Node in container.get_children():
			if child is BaseButton and child.toggle_mode:
				(child as BaseButton).set_pressed_no_signal(false)
	match brush_layer:
		&"land":
			_press_by_value(LAND_BUTTONS, brush_value, landscontainer)
		&"mountain":
			mountainbutton.set_pressed_no_signal(true)
		&"road":
			_press_by_value(ROAD_BUTTONS, brush_value, roadscontainer)
		&"water":
			_press_by_value(WATER_BUTTONS, brush_value, waterscontainer)
		&"bridge":
			_press_by_value(BRIDGE_BUTTONS, brush_value, bridgescontainer)
		&"flow":
			var dir: Vector2i = GridDefs.flow_vector(brush_value)
			for name: String in DIRECTION_BUTTONS:
				if DIRECTION_BUTTONS[name] == dir:
					(directionscontainer.get_node(name) as Button).set_pressed_no_signal(true)
					break


func _press_by_value(mapping: Dictionary, value: int, container: Node) -> void:
	for name: String in mapping:
		if mapping[name] == value:
			(container.get_node(name) as Button).set_pressed_no_signal(true)
			return


## 把 container 下与 mapping 键同名的按钮统一连到 handler，
## 并把 mapping 里的值作为参数附加进去（pressed 本身无参数）。
func _connect_group(container: Node, mapping: Dictionary, handler: Callable) -> void:
	for button_name: String in mapping:
		var button: Button = container.get_node(button_name) as Button
		button.pressed.connect(handler.bind(mapping[button_name]))


# ---------- 信号处理（只做转发） ----------

func _on_land_button(id: int) -> void:
	select_land(id)

## 山体笔刷：独立字段，不覆盖陆地/道路；左键画、Shift+左键擦
func _on_mountain_button() -> void:
	_set_brush(&"mountain", 1)
	print("[笔刷] 山体（左键绘制，Shift+左键擦除）")

func _on_road_button(id: int) -> void:
	select_road(id)

func _on_bridge_button(kind: int) -> void:
	select_bridge(kind)

func _on_water_button(id: int) -> void:
	select_water(id)

func _on_direction_button(dir: Vector2i) -> void:
	select_direction(dir)

## 高程等级：点数字即切到高程笔刷，左键设成这一级、Shift+左键恢复 1 级
func _on_elevation_selected(level: int) -> void:
	elevation_value = level
	_set_brush(&"elevation", level)

func _on_elevation_plus() -> void:
	add_elevation_level()

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
	print("[笔刷] %s" % ("矩形填充模式（拖选区域，Shift+左键=擦除填充）" if pressed else "涂画模式"))


## 资源库：选中即切到资源笔刷；真正的放置/擦除由 GridView 上报、main 写数据
func _on_asset_selected(asset_id: StringName) -> void:
	prop_asset_id = asset_id
	brush_layer = &"prop"
	brush_changed.emit(&"prop", -1)
	_refresh_brush_buttons()   # prop 不对应任何工具按钮：清掉全部选中态
	print("[笔刷] 资源 -> %s" % asset_name(asset_id))


func _on_rotation_selected(rot: int) -> void:
	prop_rotation = posmod(rot, 2)
	prop_rotation_changed.emit(prop_rotation)
	print("[笔刷] 资源方向 -> %s" % rotation_name(prop_rotation))


func _on_scale_selected(scale: int) -> void:
	prop_scale = clampi(scale, 1, 4)
	prop_scale_changed.emit(prop_scale)
	print("[笔刷] 植物倍率 -> %d×" % prop_scale)


## 当前资源实际可用的倍率：只有植物（category=tree）才不是 1。
func current_prop_scale() -> int:
	var def: StaticAssetDef = propstool.asset_defs.get(prop_asset_id) as StaticAssetDef
	if def != null and def.category == &"tree":
		return prop_scale
	return 1


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

func select_bridge(kind: int) -> void:
	_set_brush(&"bridge", clampi(kind, BridgesData.Kind.LOG, BridgesData.Kind.STONE))

func select_water(id: int) -> void:
	_set_brush(&"water", id)

func select_direction(dir: Vector2i) -> void:
	_set_brush(&"flow", GridDefs.flow_from_vector(dir))


## 强制退出资源放置，回到上一支非资源笔刷（Esc / 外部调用）。
func exit_prop_mode() -> void:
	if brush_layer == &"prop":
		_set_brush(_last_edit_layer, _last_edit_value)


## 高程是整级设定（不再抬升/压低/平滑）：1/2/3/+ 选级别，左键写入、Shift+左键恢复 1 级。
## 初始化 1/2/3 按钮为互斥 toggle 组，默认选中 1（不自动激活高程笔刷）。
func _setup_elevation_buttons() -> void:
	for i in range(1, elevation_max + 1):
		var button: Button = elevationcontainer.get_node("Button%d" % i) as Button
		_bind_elevation_button(button, i)
	var first: Button = elevationcontainer.get_node("Button1") as Button
	first.set_pressed_no_signal(true)


func _bind_elevation_button(button: Button, level: int) -> void:
	button.pressed.connect(_on_elevation_selected.bind(level))


## 点击 + ：新增下一个高程等级按钮（1,2,3,4...），插入到 + 之前并直接选中
func add_elevation_level() -> void:
	if elevation_max >= ELEVATION_MAX:
		return
	elevation_max += 1
	var button: Button = LevelButtonScene.instantiate() as Button
	button.name = "Button%d" % elevation_max
	button.text = str(elevation_max)
	button.button_group = elevation_group
	_bind_elevation_button(button, elevation_max)
	elevationcontainer.add_child(button)
	elevationcontainer.move_child(button, elevationplusbutton.get_index())
	button.button_pressed = true
	elevation_value = elevation_max
	_set_brush(&"elevation", elevation_max)
	print("[高程] 新增级数 %d" % elevation_max)


## 初始化 1/2/3 尺寸按钮为互斥 toggle 组，默认选中 1
func _setup_size_buttons() -> void:
	for i in range(1, brush_size_max + 1):
		var button: Button = brushcontainer.get_node("Button%d" % i) as Button
		_bind_size_button(button, i)
	var first: Button = brushcontainer.get_node("Button1") as Button
	first.set_pressed_no_signal(true)

func _bind_size_button(button: Button, size: int) -> void:
	button.toggled.connect(_on_size_toggled.bind(size))


## 点击 + ：新增下一个笔刷尺寸按钮（1,2,3,4...），插入到 + 之前
func add_brush_size() -> void:
	brush_size_max += 1
	var button: Button = LevelButtonScene.instantiate() as Button
	button.name = "Button%d" % brush_size_max
	button.text = str(brush_size_max)
	button.button_group = sizegroup
	_bind_size_button(button, brush_size_max)
	brushcontainer.add_child(button)
	brushcontainer.move_child(button, brushplusbutton.get_index())
	print("[笔刷] 新增大小 %d" % brush_size_max)

func _set_brush(layer: StringName, value: int) -> void:
	propstool.clear_selection()
	prop_asset_id = &""
	brush_layer = layer
	brush_value = value
	if layer != &"prop":
		_last_edit_layer = layer
		_last_edit_value = value
	brush_changed.emit(layer, value)
	_refresh_brush_buttons()
	print("[笔刷] %s -> %s" % [GridDefs.LAYER_NAMES.get(layer, layer), value_name(layer, value)])


## 笔刷值的可读名称（控制台输出用）
func value_name(layer: StringName, value: int) -> String:
	if layer == &"land":
		return String(GridDefs.LAND_NAMES.get(value, str(value)))
	elif layer == &"road":
		return String(GridDefs.ROAD_NAMES.get(value, str(value)))
	elif layer == &"bridge":
		return BridgesData.kind_name(value)
	elif layer == &"water":
		return String(GridDefs.WATER_NAMES.get(value, str(value)))
	elif layer == &"flow":
		return String(GridDefs.Flow.keys()[value])
	elif layer == &"mountain":
		return "山体" if value > 0 else "清除"
	elif layer == &"elevation":
		return "%d 级" % value
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


## 清脏标记但保留当前路径（载入 look 边车等"非用户改动"场景用）
func clear_dirty() -> void:
	if dirty:
		dirty = false
		_update_save_button()


## 有已保存路径就直接覆盖保存，否则弹出保存对话框
## 地图数据约定：每张地图一个同名子文件夹（maps/<地图名>/<地图名>.tres），
## 边车自动写到同一目录；新地图可在对话框里新建子文件夹。
func save_map() -> void:
	if map == null:
		return
	if current_path != "" and FileAccess.file_exists(current_path):
		_do_save(current_path)
		return
	_popup_save_dialog()


## 另存为：永远弹保存对话框，整套文件（主图+边车+着色器副本）落到新位置，旧文件不动
func save_as_map() -> void:
	if map == null:
		return
	_popup_save_dialog()


func _popup_save_dialog() -> void:
	DirAccess.make_dir_recursive_absolute("res://maps")
	filedialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	filedialog.current_dir = _default_map_dir()
	_saving_via_dialog = true
	filedialog.popup_centered(Vector2i(800, 600))


## 新地图：清空路径与脏状态（数据本体由 main 重建后 set_map 注入）
func reset_file_state() -> void:
	current_path = ""
	dirty = false
	_update_save_button()
	_update_file_label()


## 弹出打开对话框，选择已有的 .tres 地图
func open_map_dialog() -> void:
	DirAccess.make_dir_recursive_absolute("res://maps")
	filedialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	filedialog.current_dir = _default_map_dir()
	_saving_via_dialog = false
	filedialog.popup_centered(Vector2i(800, 600))


## 当前地图所在目录；没有当前地图时回到地图根目录
func _default_map_dir() -> String:
	var dir: String = "res://maps"
	if current_path != "":
		dir = current_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


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
	# 另存到新文件夹时目录可能还不存在：先建目录，边车随后才能落到同一目录
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err: Error = ResourceSaver.save(map, path)
	if err == OK:
		current_path = path
		# 显式落 resource_path：MapRuntime 靠它推导同目录的着色器副本等边车路径
		map.resource_path = path
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


## 脏状态/地图名广播给文件条（原按钮/标签已随文件操作移交 FileBar 移除）
func _update_save_button() -> void:
	dirty_state_changed.emit(dirty)


func _update_file_label() -> void:
	map_path_changed.emit(current_path)
