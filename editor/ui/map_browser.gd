extends Window
## MapBrowser —— 地图列表弹窗：枚举 maps/<图>/<图>.tres，双击打开。
## 每行显示：地图名 · 尺寸 · 物件数 · 修改时间。
## 只发信号不做业务：map_chosen(path) / new_requested / browse_requested 由 main 编排。

signal map_chosen(path: String)
signal new_requested
signal browse_requested

const MapSidecars = preload("res://data/map_sidecars.gd")

var _paths: PackedStringArray = PackedStringArray()

@onready var list: ItemList = $"VBox/List"


func _ready() -> void:
	list.item_activated.connect(_on_item_activated)
	# Window 的关闭按钮只发 close_requested，不会自动隐藏，必须显式接住
	close_requested.connect(hide)
	$VBox/Buttons/NewMap.pressed.connect(func(): new_requested.emit(); hide)
	$VBox/Buttons/Browse.pressed.connect(func(): browse_requested.emit(); hide)
	$VBox/Buttons/Refresh.pressed.connect(rebuild)
	about_to_popup.connect(rebuild)


## 有任何地图时可走列表，否则调用方回退 FileDialog。
## 只做目录扫描，不加载资源——随时可调。
func available() -> bool:
	return not _scan_paths().is_empty()


## 扫描 maps/ 下符合"同名子文件夹"约定的地图路径（纯文件系统，零资源加载）
func _scan_paths() -> PackedStringArray:
	var paths: PackedStringArray = PackedStringArray()
	var dir := DirAccess.open("res://maps")
	if dir == null:
		return paths
	dir.list_dir_begin()
	var names: PackedStringArray = dir.get_directories()
	dir.list_dir_end()
	names.sort()
	for map_dir: String in names:
		if map_dir.begins_with("."):
			continue
		var tres: String = "res://maps/%s/%s.tres" % [map_dir, map_dir]
		if FileAccess.file_exists(tres):
			paths.append(tres)
	return paths


## 打开前重建列表：小图直接 load 取尺寸（几 KB～几十 KB，可接受）
func rebuild() -> void:
	_paths = _scan_paths()
	list.clear()
	for tres: String in _paths:
		list.add_item(_describe(tres, tres.get_base_dir().get_file()))
	if _paths.is_empty():
		list.add_item("maps/ 下还没有地图——点“新建地图…”画一张")
		list.set_item_disabled(0, true)


func _on_item_activated(index: int) -> void:
	if index < 0 or index >= _paths.size():
		return
	hide()
	map_chosen.emit(_paths[index])


func _describe(tres: String, map_dir: String) -> String:
	var data: MapData = load(tres) as MapData
	var size_text: String = ("%d×%d" % [data.grid_size.x, data.grid_size.y]) if data != null else "?"
	var prop_count: int = -1
	var props_side: String = MapSidecars.props_path(tres)
	if ResourceLoader.exists(props_side):
		var side = load(props_side)
		if side != null and side.has_method("count"):
			prop_count = side.count()
	var mtime: int = FileAccess.get_modified_time(tres)
	var time_text: String = Time.get_datetime_string_from_unix_time(mtime) if mtime > 0 else ""
	var count_text: String = ("物件 %d" % prop_count) if prop_count >= 0 else "无物件层"
	return "%s  ·  %s  ·  %s  ·  %s" % [map_dir, size_text, count_text, time_text]
