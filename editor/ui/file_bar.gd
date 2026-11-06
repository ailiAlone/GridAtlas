extends PanelContainer
## FileBar —— 左栏顶部的常驻文件条（编辑/渲染两模式都可见）。
## 解决"保存按钮在渲染模式不可见"的跨模式断裂：地图名 + 脏状态圆点 + 保存 + 文件菜单。
## 只发信号不做业务，编排（真正的保存/新建/打开/另存为）全在 main.gd。

signal save_requested
signal menu_new_requested
signal menu_open_requested
signal menu_save_as_requested

@onready var mapname: Label = $"HBox/MapName"
@onready var dirtydot: Label = $"HBox/DirtyDot"
@onready var savebutton: Button = $"HBox/SaveButton"
@onready var menubutton: MenuButton = $"HBox/MenuButton"


func _ready() -> void:
	savebutton.pressed.connect(func(): save_requested.emit())
	menubutton.get_popup().index_pressed.connect(_on_menu_index)


func _on_menu_index(index: int) -> void:
	match index:
		0: menu_new_requested.emit()
		1: menu_open_requested.emit()
		2: menu_save_as_requested.emit()


## 地图显示名：有路径显示文件名（去 .tres），未保存显示"未命名"
func set_map_path(path: String) -> void:
	if path.is_empty():
		mapname.text = "未命名"
		mapname.tooltip_text = "尚未保存过的新地图"
	else:
		mapname.text = path.get_file().trim_suffix(".tres")
		mapname.tooltip_text = path


## 脏状态：●金色=有未保存修改，○灰=干净
func set_dirty(on: bool) -> void:
	dirtydot.text = "●" if on else "○"
	dirtydot.modulate = Color(1, 0.78, 0.35) if on else Color(1, 1, 1, 0.28)
	savebutton.text = "保存*" if on else "保存"
