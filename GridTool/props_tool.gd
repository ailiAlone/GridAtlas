extends PanelContainer
## 物件面板：资源库（StaticAssetDef）/ 待放方向 / 清空。
## 内置 Tiny Swords 物件已彻底移除；旧边车里的实例载入时丢弃。
## 放置与删除由 GridView 上报区域、main.gd 写 PropsData —— 本面板不碰地图数据。

signal asset_selected(asset_id: StringName)
signal rotation_selected(rot: int)
signal scale_selected(scale: int)
signal clear_requested
signal assets_refresh_requested
signal asset_edit_requested

@onready var assetscontainer: VBoxContainer = $"VBox/Assets"
@onready var assetempty: Label = $"VBox/AssetEmpty"
@onready var assetsrefresh: Button = $"VBox/AssetTitleRow/AssetRefresh"
@onready var assetedit: Button = $"VBox/AssetTitleRow/AssetEdit"
@onready var selectedlabel: Label = $"VBox/Selected"
@onready var rotationrow: HBoxContainer = $"VBox/RotationRow"
@onready var rot0: Button = $"VBox/RotationRow/Rot0"
@onready var rot90: Button = $"VBox/RotationRow/Rot90"
@onready var countlabel: Label = $"VBox/Count"
@onready var clearbutton: Button = $"VBox/Clear"

var scalerow: HBoxContainer = null   # 放在“树木”分类小节里
var scalespin: SpinBox = null

var asset_group: ButtonGroup = ButtonGroup.new()
var rotationgroup: ButtonGroup = ButtonGroup.new()
var selected_asset: StringName = &""
var pending_rotation: int = 0         # 待放置方向：0=横向 / 1=竖向
var pending_scale: int = 1            # 植物倍率：1=原大小，2=占地/图片 2×
var asset_defs: Dictionary = {}

var asset_buttons: Dictionary = {}   # id -> Button

## 资源库展示顺序：建筑之后先放树木，常用植物不用滚到最后。
const SECTION_ORDER: Array[StringName] = [
	&"building", &"tree", &"prop", &"gate", &"fence", &"bridge", &"other",
]


func _ready() -> void:
	countlabel.text = "物件 0 个"
	selectedlabel.text = "当前：无"
	assetscontainer.add_theme_constant_override("separation", 6)
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
	pending_scale = 1


## main 载入资源目录后注入；按分类/层级/名称排好再生成按钮
func set_asset_defs(defs: Dictionary) -> void:
	asset_defs = defs
	scalerow = null
	scalespin = null
	for child: Node in assetscontainer.get_children():
		child.free()
	asset_buttons.clear()
	var list: Array[StaticAssetDef] = []
	for key: StringName in defs:
		var def: StaticAssetDef = defs[key] as StaticAssetDef
		if def != null and not String(def.id).is_empty():
			list.append(def)
	list.sort_custom(_def_before)
	# 按类型分组成独立小节：建筑 / 门 / 栅栏 / 桥 / 道具 / 树木 / 其他
	var groups: Dictionary = {}
	for def: StaticAssetDef in list:
		var cat_index: int = StaticAssetDef.category_index(def.category)
		var cat_id: StringName = StaticAssetDef.CATEGORY_IDS[cat_index]
		if not groups.has(cat_id):
			groups[cat_id] = []
		groups[cat_id].append(def)
	for cat_id: StringName in SECTION_ORDER:
		if groups.has(cat_id):
			_add_category_section(cat_id, groups[cat_id])
	assetempty.visible = list.is_empty()
	if selected_asset != &"":
		var abtn: Button = _asset_button(selected_asset)
		if abtn == null:
			selected_asset = &""
			selectedlabel.text = "当前：无"
			_set_rotation_enabled(false)
			_update_scale_row(null)
		else:
			abtn.set_pressed_no_signal(true)
			abtn.modulate = Color(1.0, 0.94, 0.62, 1.0)
			_update_scale_row(asset_defs.get(selected_asset) as StaticAssetDef)
	else:
		_update_scale_row(null)


func _def_before(a: StaticAssetDef, b: StaticAssetDef) -> bool:
	var ca: int = StaticAssetDef.category_rank(a.category)
	var cb: int = StaticAssetDef.category_rank(b.category)
	if ca != cb:
		return ca < cb
	if a.tier != b.tier:
		return a.tier < b.tier
	return a.display_name.naturalnocasecmp_to(b.display_name) < 0


func _add_category_section(cat_id: StringName, items: Array) -> void:
	var section: VBoxContainer = VBoxContainer.new()
	section.add_theme_constant_override("separation", 2)
	var header: Label = Label.new()
	header.text = "%s  ·  %d" % [StaticAssetDef.category_label(cat_id), items.size()]
	header.add_theme_font_size_override("font_size", 12)
	header.add_theme_color_override("font_color", Color(0.96, 0.87, 0.58, 1.0))
	section.add_child(header)
	if cat_id == &"tree":
		_add_scale_row(section)
	var flow: HFlowContainer = HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 6)
	section.add_child(flow)
	for def: StaticAssetDef in items:
		_add_asset_button(def, flow)
	assetscontainer.add_child(section)


func _add_scale_row(parent: VBoxContainer) -> void:
	scalerow = HBoxContainer.new()
	scalerow.add_theme_constant_override("separation", 6)
	var title: Label = Label.new()
	title.text = "植物倍率"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.tooltip_text = "仅植物：倍率 2 = 占地 2×2、图片 2×，变成参天大树"
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Color(0.96, 0.87, 0.58, 1.0))
	scalerow.add_child(title)
	scalespin = SpinBox.new()
	scalespin.custom_minimum_size = Vector2(86, 26)
	scalespin.min_value = 1.0
	scalespin.max_value = 4.0
	scalespin.step = 1.0
	scalespin.value = pending_scale
	scalespin.suffix = "×"
	scalespin.tooltip_text = "仅植物：倍率 2 = 占地 2×2、图片 2×"
	scalespin.value_changed.connect(_on_scale_value_changed)
	scalerow.add_child(scalespin)
	parent.add_child(scalerow)


func _add_asset_button(def: StaticAssetDef, flow: HFlowContainer) -> void:
	var button: Button = Button.new()
	button.text = def.short_name()
	button.tooltip_text = "%s\n%s · 占地范围 %d×%d · 阻挡 %d 格" % [
		String(def.id), StaticAssetDef.category_label(def.category),
		def.footprint.x, def.footprint.y, def.blocking_count()]
	button.custom_minimum_size = Vector2(104, 30)
	button.clip_text = true
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.toggle_mode = true
	button.button_group = asset_group
	button.pressed.connect(_on_asset_pressed.bind(StringName(def.id)))
	flow.add_child(button)
	asset_buttons[StringName(def.id)] = button


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
	_update_scale_row(def)
	asset_selected.emit(id)


## 倍率行只存在于“树木”分类小节里；这里只同步当前值。
func _update_scale_row(_def: StaticAssetDef) -> void:
	if scalerow == null or scalespin == null:
		return
	scalespin.set_value_no_signal(pending_scale)


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


## 植物倍率：1=原占地/图片，2=占地/图片 2×（参天大树）。不是所有资源都生效。
func set_pending_scale(scale: int, notify: bool = false) -> void:
	pending_scale = clampi(scale, 1, 4)
	if scalespin != null:
		scalespin.set_value_no_signal(pending_scale)
	if notify:
		scale_selected.emit(pending_scale)


func _on_scale_value_changed(value: float) -> void:
	var scale: int = clampi(int(round(value)), 1, 4)
	if scale != pending_scale:
		set_pending_scale(scale, true)


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
	_update_scale_row(null)
	for key: StringName in asset_buttons:
		var abtn: Button = _asset_button(key)
		abtn.set_pressed_no_signal(false)
		abtn.modulate = Color.WHITE


func set_count(n: int) -> void:
	countlabel.text = "物件 %d 个" % n
