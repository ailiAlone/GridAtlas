extends VBoxContainer
## 物件面板：资源库（StaticAssetDef）/ 待放方向 / 清空。
## 内置 Tiny Swords 物件已彻底移除；旧边车里的实例载入时丢弃。
## 放置与删除由 GridView 上报区域、main.gd 写 PropsData —— 本面板不碰地图数据。
## 结构：静态控制区在一个 FoldSection（"静态"）里，各分类是独立的可折叠卡片。

signal asset_selected(asset_id: StringName)
signal rotation_selected(rot: int)
signal scale_selected(scale: int)
signal clear_requested
signal assets_refresh_requested
signal asset_edit_requested

const AssetButtonScene = preload("res://editor/ui/asset_button.tscn")
const ScaleRowScene = preload("res://editor/ui/scale_row.tscn")
const CategorySectionScene = preload("res://editor/ui/category_section.tscn")

## 本图热点区最多显示最近 N 个；完整记录仍在 .assets.tres，全局库也始终可查。
const LOCAL_VISIBLE_MAX: int = 8

@onready var assetscontainer: VBoxContainer = $"SectionGlobal/VBox/Content/Body/Assets"
@onready var assetempty: Label = $"SectionGlobal/VBox/Content/Body/AssetEmpty"
@onready var sectionmain: FoldSection = $"SectionMain"
@onready var sectionlocal: FoldSection = $"SectionLocal"
@onready var localflow: HFlowContainer = $"SectionLocal/VBox/Content/Body/Flow"
@onready var assetsrefresh: Button = $"SectionMain/VBox/Content/Body/AssetTitleRow/AssetRefresh"
@onready var assetedit: Button = $"SectionMain/VBox/Content/Body/AssetTitleRow/AssetEdit"
@onready var selectedlabel: Label = $"SectionMain/VBox/Content/Body/Selected"
@onready var rotationrow: HBoxContainer = $"SectionMain/VBox/Content/Body/RotationRow"
@onready var rot0: Button = $"SectionMain/VBox/Content/Body/RotationRow/Rot0"
@onready var rot90: Button = $"SectionMain/VBox/Content/Body/RotationRow/Rot90"
@onready var countlabel: Label = $"SectionMain/VBox/Content/Body/Count"
@onready var clearbutton: Button = $"SectionMain/VBox/Content/Body/Clear"

var scalerow: HBoxContainer = null   # 放在“树木”分类小节里
var scalespin: SpinBox = null

@export var asset_group: ButtonGroup   # 静态定义在 props_tool.tscn
var selected_asset: StringName = &""
var pending_rotation: int = 0         # 待放置方向：0=横向 / 1=竖向
var pending_scale: int = 1            # 植物倍率：1=原大小，2=占地 2×2/图片 1.5×
var asset_defs: Dictionary = {}

var asset_buttons: Dictionary = {}   # id -> Button
var hot_buttons: Dictionary = {}   # id -> Button（本图热点快捷区）
var hot_ids: PackedStringArray = PackedStringArray()  # 当前本图热点库（全局刷新后重建用）

## 资源库展示顺序：建筑之后先放树木，常用植物不用滚到最后。
const SECTION_ORDER: Array[StringName] = [
	&"building", &"tree", &"prop", &"gate", &"fence", &"bridge", &"other",
]


func _ready() -> void:
	countlabel.text = "静态 0 个"
	selectedlabel.text = "当前：无"
	assetscontainer.add_theme_constant_override("separation", 6)
	clearbutton.pressed.connect(_on_clear)
	assetsrefresh.pressed.connect(_on_assets_refresh)
	assetedit.pressed.connect(_on_asset_edit)
	rot0.pressed.connect(_on_rotation_pressed.bind(0))
	rot90.pressed.connect(_on_rotation_pressed.bind(1))
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
			# 随机款式组只展示 primary（如“阔叶树”），其余成员放置时随机抽取
			if def.variant_group != &"" and not def.variant_primary:
				continue
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
	# 全局定义刷新后，本图热点区也要用新定义重建，避免按钮缓存指向旧 def
	if not hot_ids.is_empty():
		set_hot_assets(hot_ids)
	if selected_asset != &"":
		var abtn: Button = _asset_button(selected_asset)
		if abtn == null:
			selected_asset = &""
			selectedlabel.text = "当前：无"
			_set_rotation_enabled(false)
			_update_scale_row(null)
		else:
			abtn.set_pressed_no_signal(true)
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


## 分类小节 = 可折叠卡片，默认全部收起（标题带计数可扫读，展开按需）；
## 建筑 24 个按钮全展开会把左栏顶得老长。
func _add_category_section(cat_id: StringName, items: Array) -> void:
	var section = CategorySectionScene.instantiate()
	assetscontainer.add_child(section)   # 先入树（body 等 @onready 才可用）再填内容
	section.setup("%s · %d" % [StaticAssetDef.category_label(cat_id), items.size()], true)
	var flow: HFlowContainer = section.body.get_node("Flow") as HFlowContainer
	if cat_id == &"tree":
		_add_scale_row(section.body)
	for def: StaticAssetDef in items:
		_add_asset_button(def, flow)


## 倍率行：静态模板（editor/ui/scale_row.tscn）实例化，只填当前值
func _add_scale_row(parent: VBoxContainer) -> void:
	scalerow = ScaleRowScene.instantiate() as HBoxContainer
	scalespin = scalerow.get_node("Spin") as SpinBox
	scalespin.set_value_no_signal(pending_scale)
	scalespin.value_changed.connect(_on_scale_value_changed)
	parent.add_child(scalerow)
	parent.move_child(scalerow, 0)   # 倍率行放在资源按钮流之前


## 资源按钮：静态模板（editor/ui/asset_button.tscn）实例化，只填文案与信号
func _add_asset_button(def: StaticAssetDef, flow: HFlowContainer, local: bool = false) -> void:
	var button: Button = AssetButtonScene.instantiate() as Button
	button.text = def.short_name()
	button.tooltip_text = "%s\n%s · 占地范围 %d×%d · 阻挡 %d 格" % [
		String(def.id), StaticAssetDef.category_label(def.category),
		def.footprint.x, def.footprint.y, def.blocking_count()]
	button.button_group = asset_group
	button.pressed.connect(_on_asset_pressed.bind(StringName(def.id)))
	flow.add_child(button)
	var target: Dictionary = hot_buttons if local else asset_buttons
	target[StringName(def.id)] = button


## 重建「本图热点」快捷区：按 id 顺序（最近使用在前），空列表隐藏整节。
## 只铺最近 LOCAL_VISIBLE_MAX 个，避免 40+ 资源把左栏顶得老长。
func set_hot_assets(ids: PackedStringArray) -> void:
	hot_ids = ids
	for child: Node in localflow.get_children():
		child.free()
	hot_buttons.clear()
	var shown: int = 0
	var visible_count: int = mini(ids.size(), LOCAL_VISIBLE_MAX)
	for i: int in visible_count:
		var id: StringName = StringName(ids[i])
		var def: StaticAssetDef = asset_defs.get(id) as StaticAssetDef
		if def == null:
			continue
		_add_asset_button(def, localflow, true)
		shown += 1
	if ids.size() > LOCAL_VISIBLE_MAX:
		var more: Label = Label.new()
		more.theme_type_variation = &"Dim"
		more.text = "仅显示最近 %d / %d 个" % [LOCAL_VISIBLE_MAX, ids.size()]
		localflow.add_child(more)
	sectionlocal.visible = shown > 0
	_sync_selection_buttons()


## 已在本图热点区里的资源再次被放置：按钮移到最前，不重建整节。
## 返回 false 表示该 id 当前不在可见区（超过上限），调用方应改为整节重建。
func touch_hot_asset(id: StringName) -> bool:
	var button: Button = hot_buttons.get(id) as Button
	if button == null:
		return false
	localflow.move_child(button, 0)
	sectionlocal.visible = true
	_sync_selection_buttons()
	return true


## 同一个 id 可能同时出现在全局分类和本图热点区：两套按钮一起同步选中态。
func _sync_selection_buttons() -> void:
	for buttons: Dictionary in [asset_buttons, hot_buttons]:
		for key: StringName in buttons:
			(buttons[key] as Button).set_pressed_no_signal(key == selected_asset)


func _asset_button(id: StringName) -> Button:
	return asset_buttons.get(id) as Button


func _on_asset_pressed(id: StringName) -> void:
	sectionmain.set_folded(false)   # 选中静态资源时自动展开方向/计数/清空控制区
	selected_asset = id
	_set_rotation_enabled(true)
	_sync_selection_buttons()
	var def: StaticAssetDef = asset_defs.get(id) as StaticAssetDef
	var showname: String = String(id)
	if def != null:
		showname = def.display_name
		if def.variant_group != &"":
			showname += "（随机款式）"
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
		rotbuttons[i].set_pressed_no_signal(i == pending_rotation)
	if notify:
		rotation_selected.emit(pending_rotation)


func _on_rotation_pressed(rot: int) -> void:
	set_pending_rotation(rot, true)


## 植物倍率：占格按整数倍，图片按 1/1.5/2/2.5 渐变。不是所有资源都生效。
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


## 切回地形/道路笔刷时清掉资源按钮的高亮（全局库与本图热点区一起清）
func clear_selection() -> void:
	selected_asset = &""
	_set_rotation_enabled(false)
	selectedlabel.text = "当前：无"
	_update_scale_row(null)
	_sync_selection_buttons()


func set_count(n: int) -> void:
	countlabel.text = "静态 %d 个" % n
