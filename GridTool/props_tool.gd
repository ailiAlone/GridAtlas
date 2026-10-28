extends PanelContainer
## 物件面板：资源库（StaticAssetDef）/ 待放方向 / 清空。
## 内置 Tiny Swords 物件已彻底移除；旧边车里的实例载入时丢弃。
## 放置与删除由 GridView 上报区域、main.gd 写 PropsData —— 本面板不碰地图数据。

signal asset_selected(asset_id: StringName)
signal rotation_selected(rot: int)
signal clear_requested
signal assets_refresh_requested
signal asset_edit_requested

## 资源库排序：建筑/门/围墙优先，杂项最后
const CATEGORY_ORDER: Array[StringName] = [
	&"building", &"gate", &"fence", &"bridge", &"prop", &"tree", &"other",
]
const CATEGORY_LABELS: Dictionary = {
	&"prop": "道具", &"building": "建筑", &"gate": "门",
	&"fence": "围墙/栅栏", &"bridge": "桥", &"tree": "树/植被", &"other": "其他",
}

@onready var assetscontainer: HFlowContainer = $"VBox/Assets"
@onready var assetempty: Label = $"VBox/AssetEmpty"
@onready var assetsrefresh: Button = $"VBox/AssetTitleRow/AssetRefresh"
@onready var assetedit: Button = $"VBox/AssetTitleRow/AssetEdit"
@onready var selectedlabel: Label = $"VBox/Selected"
@onready var rotationrow: HBoxContainer = $"VBox/RotationRow"
@onready var rot0: Button = $"VBox/RotationRow/Rot0"
@onready var rot90: Button = $"VBox/RotationRow/Rot90"
@onready var countlabel: Label = $"VBox/Count"
@onready var clearbutton: Button = $"VBox/Clear"

var asset_group: ButtonGroup = ButtonGroup.new()
var rotationgroup: ButtonGroup = ButtonGroup.new()
var selected_asset: StringName = &""
var pending_rotation: int = 0         # 待放置方向：0=横向 / 1=竖向
var asset_defs: Dictionary = {}

var asset_buttons: Dictionary = {}   # id -> Button


func _ready() -> void:
	countlabel.text = "物件 0 个"
	selectedlabel.text = "当前：无"
	clearbutton.pressed.connect(_on_clear)
	assetsrefresh.pressed.connect(_on_assets_refresh)
	assetedit.pressed.connect(_on_asset_edit)
	var rotbuttons: Array[Button] = [rot0, rot90]
	for i in 2:
		var rotbutton: Button = rotbuttons[i]
		rotbutton.toggle_mode = true
		rotbutton.button_group = rotationgroup
		rotbutton.pressed.connect(_on_rotation_pressed.bind(i))
	set_pending_rotation(0)
	_set_rotation_enabled(false)


## main 载入资源目录后注入；按分类/层级/名称排好再生成按钮
func set_asset_defs(defs: Dictionary) -> void:
	asset_defs = defs
	for child: Node in assetscontainer.get_children():
		child.free()
	asset_buttons.clear()
	var list: Array[StaticAssetDef] = []
	for key: StringName in defs:
		var def: StaticAssetDef = defs[key] as StaticAssetDef
		if def != null and not String(def.id).is_empty():
			list.append(def)
	list.sort_custom(_def_before)
	for def: StaticAssetDef in list:
		_add_asset_button(def)
	assetempty.visible = list.is_empty()
	if selected_asset != &"":
		var abtn: Button = _asset_button(selected_asset)
		if abtn == null:
			selected_asset = &""
			selectedlabel.text = "当前：无"
			_set_rotation_enabled(false)
		else:
			abtn.set_pressed_no_signal(true)
			abtn.modulate = Color(1.0, 0.94, 0.62, 1.0)


func _def_before(a: StaticAssetDef, b: StaticAssetDef) -> bool:
	var ca: int = CATEGORY_ORDER.find(a.category)
	var cb: int = CATEGORY_ORDER.find(b.category)
	if ca < 0:
		ca = CATEGORY_ORDER.size()
	if cb < 0:
		cb = CATEGORY_ORDER.size()
	if ca != cb:
		return ca < cb
	if a.tier != b.tier:
		return a.tier < b.tier
	return a.display_name.naturalnocasecmp_to(b.display_name) < 0


func _add_asset_button(def: StaticAssetDef) -> void:
	var button: Button = Button.new()
	button.text = _short_name(def)
	button.tooltip_text = "%s\n%s · 占地范围 %d×%d · 阻挡 %d 格" % [
		String(def.id), String(CATEGORY_LABELS.get(def.category, "其他")),
		def.footprint.x, def.footprint.y, def.blocking_count()]
	button.custom_minimum_size = Vector2(104, 30)
	button.clip_text = true
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.toggle_mode = true
	button.button_group = asset_group
	button.pressed.connect(_on_asset_pressed.bind(StringName(def.id)))
	assetscontainer.add_child(button)
	asset_buttons[StringName(def.id)] = button


## 按钮上只留可读名：去掉 ID 前缀（CV-E03_...__gate_r2_se -> gate_r2_se）
func _short_name(def: StaticAssetDef) -> String:
	var showname: String = def.display_name.strip_edges()
	if showname.is_empty():
		showname = String(def.id)
	if showname.contains("__"):
		showname = showname.split("__", true, 1)[1]
	else:
		var cut: int = showname.find("_")
		if cut > 0 and cut <= 8 and showname.substr(0, cut).contains("-"):
			showname = showname.substr(cut + 1)
	return showname


func _asset_button(id: StringName) -> Button:
	return asset_buttons.get(id) as Button


func _on_asset_pressed(id: StringName) -> void:
	selected_asset = id
	_set_rotation_enabled(true)
	for key: StringName in asset_buttons:
		var abtn: Button = _asset_button(key)
		var on: bool = key == id
		abtn.set_pressed_no_signal(on)
		abtn.modulate = Color(1.0, 0.94, 0.62, 1.0) if on else Color.WHITE
	var def: StaticAssetDef = asset_defs.get(id) as StaticAssetDef
	var showname: String = String(id)
	if def != null:
		showname = def.display_name
	selectedlabel.text = "当前：%s" % showname
	asset_selected.emit(id)


## 待放置方向：横向/竖向两个互斥按钮；R 键/外部程序也可直接调用（notify=false 不重复发信号）
func set_pending_rotation(rot: int, notify: bool = false) -> void:
	pending_rotation = posmod(rot, 2)
	var rotbuttons: Array[Button] = [rot0, rot90]
	for i in 2:
		var button: Button = rotbuttons[i]
		button.set_pressed_no_signal(i == pending_rotation)
		button.modulate = Color(1.0, 0.94, 0.62, 1.0) if i == pending_rotation else Color.WHITE
	if notify:
		rotation_selected.emit(pending_rotation)


func _on_rotation_pressed(rot: int) -> void:
	set_pending_rotation(rot, true)


## 没有选中资源时方向按钮不可点
func _set_rotation_enabled(on: bool) -> void:
	rotationrow.modulate = Color(1, 1, 1, 1) if on else Color(1, 1, 1, 0.45)
	var rotbuttons: Array[Button] = [rot0, rot90]
	for button: Button in rotbuttons:
		button.disabled = not on


func _on_clear() -> void:
	clear_requested.emit()


func _on_assets_refresh() -> void:
	assets_refresh_requested.emit()


func _on_asset_edit() -> void:
	asset_edit_requested.emit()


## 切回地形/道路笔刷时清掉资源按钮的高亮
func clear_selection() -> void:
	selected_asset = &""
	_set_rotation_enabled(false)
	selectedlabel.text = "当前：无"
	for key: StringName in asset_buttons:
		var abtn: Button = _asset_button(key)
		abtn.set_pressed_no_signal(false)
		abtn.modulate = Color.WHITE


func set_count(n: int) -> void:
	countlabel.text = "物件 %d 个" % n
