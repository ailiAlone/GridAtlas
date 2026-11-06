extends PanelContainer
## 静态资源导入页：透明 PNG → 可复用的 StaticAssetDef。
##
## 资源定义包含：占地范围、实际阻挡格、立牌尺寸、左右侧拉伸、图片偏移。
## 这里只编辑资源定义，不绑定地图坐标；放置、A*、45° 渲染由主编辑器消费同一份 .tres。
## 编辑器里从资源库“编辑”弹出；关闭时发 closed，让主编辑器重读 catalog。
## 数据位置：res://Assets/static_assets/defs/*.tres + catalog.tres

signal closed
signal asset_saved(asset_id: StringName)   # 保存成功后通知编辑器的"本图热点"

const AssetDef = preload("res://Assets/static_assets/static_asset_def.gd")
const AssetCatalog = preload("res://Assets/static_assets/static_asset_catalog.gd")
const AssetStore = preload("res://Assets/static_assets/static_asset_store.gd")

const COLOR_INFO: Color = Color(0.72, 0.86, 1.0)
const COLOR_ERROR: Color = Color(1.0, 0.52, 0.45)
const MIN_ART_WIDTH: float = 0.1
const MAX_ART_WIDTH: float = 64.0
const MIN_ART_STRETCH: float = 0.25
const MAX_ART_STRETCH: float = 3.0

@onready var asset_list: ItemList = %AssetList
@onready var list_count: Label = %ListCount
@onready var new_button: Button = %NewButton
@onready var import_button: Button = %ImportButton
@onready var close_button: Button = %CloseButton

@onready var mask_editor: AssetMaskEditor = %MaskEditor
@onready var mask_summary: Label = %MaskSummary
@onready var all_solid_button: Button = %AllSolid
@onready var all_pass_button: Button = %AllPass
@onready var invert_button: Button = %Invert
@onready var reset_lift_button: Button = %ResetLift
@onready var reset_offset_button: Button = %ResetOffset

@onready var id_edit: LineEdit = %IDEdit
@onready var name_edit: LineEdit = %NameEdit
@onready var category_option: OptionButton = %CategoryOption
@onready var tier_spin: SpinBox = %TierSpin
@onready var path_edit: LineEdit = %PathEdit
@onready var browse_button: Button = %BrowseButton
@onready var content_label: Label = %ContentRectLabel
@onready var foot_w: SpinBox = %FootW
@onready var foot_h: SpinBox = %FootH
@onready var blocking_option: OptionButton = %BlockingOption
@onready var width_slider: HSlider = %WidthSlider
@onready var width_spin: SpinBox = %WidthSpin
@onready var y_stretch: HSlider = %YStretch
@onready var stretch_spin: SpinBox = %StretchSpin
@onready var size_info: Label = %SizeInfo
@onready var off_x: SpinBox = %OffX
@onready var off_y: SpinBox = %OffY
@onready var status_label: Label = %Status
@onready var save_button: Button = %SaveButton
@onready var delete_button: Button = %DeleteButton

@onready var file_dialog: FileDialog = %FileDialog
@onready var confirm_dialog: ConfirmationDialog = %ConfirmDialog

var catalog: AssetCatalog
var defs: Array[StaticAssetDef] = []
var def_paths: PackedStringArray = PackedStringArray()
var current_def: StaticAssetDef
var current_path: String = ""
var current_image: Image
var current_content_rect: Rect2i = Rect2i()
var art_width: float = 1.0
var art_stretch: float = 1.0
var is_new: bool = true
var auto_art: bool = true
var import_creates_new: bool = false
var updating: bool = false


func _ready() -> void:
	_setup_options()
	_connect_signals()
	catalog = AssetStore.load_catalog()
	_refresh_list()
	if defs.is_empty():
		_new_asset()
	else:
		asset_list.select(0)
		_open_definition(def_paths[0])
	if get_tree().current_scene == self and "--shot" in OS.get_cmdline_args():
		_capture_and_quit()


func _setup_options() -> void:
	for i in AssetDef.CATEGORY_LABELS.size():
		category_option.add_item(AssetDef.CATEGORY_LABELS[i], i)
	blocking_option.add_item("全部阻挡", AssetDef.Blocking.ALL)
	blocking_option.add_item("全部通行", AssetDef.Blocking.NONE)
	blocking_option.add_item("按格子", AssetDef.Blocking.MASK)


func _connect_signals() -> void:
	close_button.pressed.connect(_on_close)
	new_button.pressed.connect(_new_asset)
	import_button.pressed.connect(_on_import_pressed)
	browse_button.pressed.connect(_on_browse_pressed)
	asset_list.item_selected.connect(_on_list_selected)
	path_edit.text_changed.connect(_on_path_text_changed)
	file_dialog.file_selected.connect(_on_texture_selected)
	confirm_dialog.confirmed.connect(_on_delete_confirmed)
	all_solid_button.pressed.connect(_on_all_solid)
	all_pass_button.pressed.connect(_on_all_pass)
	invert_button.pressed.connect(_on_invert)
	reset_lift_button.pressed.connect(_on_reset_lift)
	reset_offset_button.pressed.connect(_on_reset_offset)
	width_slider.value_changed.connect(_on_width_changed)
	width_spin.value_changed.connect(_on_width_changed)
	y_stretch.value_changed.connect(_on_y_stretch_changed)
	stretch_spin.value_changed.connect(_on_y_stretch_changed)
	off_x.value_changed.connect(_on_offset_changed)
	off_y.value_changed.connect(_on_offset_changed)
	blocking_option.item_selected.connect(_on_blocking_changed)
	foot_w.value_changed.connect(_on_footprint_changed)
	foot_h.value_changed.connect(_on_footprint_changed)
	mask_editor.offset_changed.connect(_on_mask_offset_changed)
	mask_editor.lift_changed.connect(_on_lift_changed)
	mask_editor.mask_changed.connect(_update_mask_summary)
	save_button.pressed.connect(_on_save)
	delete_button.pressed.connect(_on_delete)


# ---------- 列表 / 载入 ----------

func _refresh_list(select_id: String = "") -> void:
	defs.clear()
	def_paths = PackedStringArray()
	asset_list.clear()
	for path: String in catalog.asset_paths:
		var def: StaticAssetDef = AssetStore.load_def(path)
		if def == null:
			continue
		defs.append(def)
		def_paths.append(path)
		asset_list.add_item(_list_title(def))
		var index: int = asset_list.item_count - 1
		asset_list.set_item_metadata(index, path)
		asset_list.set_item_tooltip(index, "%s\n%s · %s · 占地范围 %d×%d" % [
			def.display_name, String(def.id), AssetDef.category_label(def.category),
			def.footprint.x, def.footprint.y])
	list_count.text = "%d 个" % defs.size()
	if select_id.is_empty():
		return
	for i in defs.size():
		if String(defs[i].id) == select_id:
			asset_list.select(i)
			_open_definition(def_paths[i])
			return


func _on_list_selected(index: int) -> void:
	if index < 0 or index >= asset_list.item_count:
		return
	_open_definition(String(asset_list.get_item_metadata(index)))


func _open_definition(path: String) -> void:
	var def: StaticAssetDef = AssetStore.load_def(path)
	if def == null:
		_set_status("无法载入资源定义: " + path, true)
		return
	current_def = def
	current_path = path
	is_new = false
	auto_art = false
	updating = true
	id_edit.text = String(def.id)
	id_edit.editable = false
	name_edit.text = def.display_name
	tier_spin.value = def.tier
	category_option.select(AssetDef.category_index(def.category))
	_set_path_text(def.texture_path)
	foot_w.value = def.footprint.x
	foot_h.value = def.footprint.y
	blocking_option.select(clampi(def.blocking_mode, 0, 2))
	off_x.value = def.art_offset.x
	off_y.value = def.art_offset.y
	updating = false
	mask_editor.set_lift(def.art_lift)
	mask_editor.set_art_offset(def.art_offset)
	mask_editor.set_data(def.footprint, def.blocking_cells, def.blocking_mode)
	_update_mask_summary()
	_load_texture(def.texture_path, def.content_rect)
	_set_width_control(def.art_size.x)
	var natural: float = _auto_art_height(art_width)
	_set_y_stretch_control(def.art_size.y / maxf(natural, 0.01))
	_sync_art_size()
	delete_button.disabled = false
	save_button.text = "保存修改"
	if current_image != null:
		_set_status("已载入 %s" % String(def.id), false)
	else:
		_set_status("定义已载入，但 PNG 读取失败；请重新选择路径", true)


# ---------- 新建 / 导入 PNG ----------

func _new_asset() -> void:
	current_def = AssetDef.new()
	current_path = ""
	is_new = true
	auto_art = true
	current_image = null
	current_content_rect = Rect2i()
	art_width = 1.0
	updating = true
	id_edit.text = ""
	id_edit.editable = true
	name_edit.text = ""
	category_option.select(0)
	tier_spin.value = 0
	_set_path_text("")
	foot_w.value = 1
	foot_h.value = 1
	blocking_option.select(AssetDef.Blocking.ALL)
	off_x.value = 0.0
	off_y.value = 0.0
	updating = false
	_set_width_control(art_width)
	_set_y_stretch_control(1.0)
	_sync_art_size()
	mask_editor.set_lift(Vector2.ZERO)
	mask_editor.set_art_offset(Vector2.ZERO)
	mask_editor.set_data(Vector2i.ONE, [], AssetDef.Blocking.ALL)
	mask_editor.set_texture(null)
	_update_content_label()
	_update_mask_summary()
	delete_button.disabled = true
	save_button.text = "保存为新资源"
	asset_list.deselect_all()
	_set_status("新建资源：先选择 PNG，再设置占地范围与阻挡格。", false)


func _on_import_pressed() -> void:
	import_creates_new = true
	file_dialog.popup_centered_ratio(0.75)


func _on_browse_pressed() -> void:
	import_creates_new = is_new
	file_dialog.popup_centered_ratio(0.75)


func _on_texture_selected(path: String) -> void:
	if import_creates_new:
		_start_import(path)
	else:
		_apply_texture(path)


## 新建资源：载入 PNG、自动填 ID/名称/立牌宽度，保留用户随后设置的占地范围
func _start_import(path: String) -> void:
	var image: Image = _read_image(path)
	if image == null:
		_set_status("无法读取 PNG: " + path, true)
		return
	if image.detect_alpha() == Image.ALPHA_NONE:
		_set_status("拒绝导入：PNG 没有 alpha 通道。GridAtlas 不做抠图，请先交付透明 PNG。", true)
		return
	_new_asset()
	current_image = image
	current_content_rect = _used_rect(image)
	_set_path_text(_res_path(path))
	id_edit.text = _unique_id(_slug_from_path(path))
	name_edit.text = path.get_file().get_basename().replace("__base", "")
	art_width = 1.0
	auto_art = true
	_set_width_control(art_width)
	_set_y_stretch_control(1.0)
	_sync_art_size()
	mask_editor.set_texture(_content_texture(image, current_content_rect))
	_update_content_label()
	_update_mask_summary()
	_set_status("已载入 PNG。设置占地范围后立牌宽度会自动跟随；门类把「阻挡」改为按格子并点出门柱。", false)


## 已有资源更换 PNG：保留占地/阻挡；高度尽量维持原来的视觉尺寸
func _apply_texture(path: String) -> void:
	var image: Image = _read_image(path)
	if image == null:
		_set_status("无法读取 PNG: " + path, true)
		return
	if image.detect_alpha() == Image.ALPHA_NONE:
		_set_status("拒绝导入：PNG 没有 alpha 通道。", true)
		return
	var old_height: float = _art_height()
	current_image = image
	current_content_rect = _used_rect(image)
	_set_path_text(_res_path(path))
	mask_editor.set_texture(_content_texture(image, current_content_rect))
	_update_content_label()
	if auto_art:
		art_width = float(int(foot_w.value))
		_set_width_control(art_width)
		_set_y_stretch_control(1.0)
	else:
		_set_y_stretch_control(old_height / maxf(_auto_art_height(art_width), 0.01))
	_sync_art_size()
	_set_status("已替换 PNG；保存后写入资源定义。", false)


# ---------- 表单联动 ----------

func _on_footprint_changed(_value: float) -> void:
	if updating:
		return
	var fp: Vector2i = Vector2i(int(foot_w.value), int(foot_h.value))
	mask_editor.set_footprint(fp)
	if auto_art:
		art_width = float(fp.x)
		_set_width_control(art_width)
		_sync_art_size()
	_update_mask_summary()


func _on_width_changed(value: float) -> void:
	if updating:
		return
	art_width = clampf(value, MIN_ART_WIDTH, MAX_ART_WIDTH)
	auto_art = false
	_sync_width_controls()
	_sync_art_size()
	_set_status("立牌宽度 %.2f 格。" % art_width, false)


func _on_y_stretch_changed(value: float) -> void:
	if updating:
		return
	art_stretch = clampf(value, MIN_ART_STRETCH, MAX_ART_STRETCH)
	auto_art = false
	_sync_stretch_controls()
	_sync_art_size()
	_set_status("高度拉伸 %.2f×。" % art_stretch, false)


func _on_offset_changed(_value: float) -> void:
	if updating:
		return
	mask_editor.set_art_offset(Vector2(off_x.value, off_y.value))
	_set_status("图片偏移 (%.2f, %.2f) 格。" % [off_x.value, off_y.value], false)


func _on_lift_changed() -> void:
	var lift: Vector2 = mask_editor.get_lift()
	_set_status("单侧拉伸 左 %.2f / 右 %.2f。" % [lift.x, lift.y], false)
	_sync_art_size()


func _on_mask_offset_changed(offset: Vector2) -> void:
	if updating:
		return
	updating = true
	off_x.value = offset.x
	off_y.value = offset.y
	updating = false
	_set_status("图片偏移 (%.2f, %.2f) 格。" % [offset.x, offset.y], false)


func _on_reset_offset() -> void:
	mask_editor.set_art_offset(Vector2.ZERO)
	updating = true
	off_x.value = 0.0
	off_y.value = 0.0
	updating = false
	_set_status("图片位置已重置。", false)


func _on_reset_lift() -> void:
	mask_editor.set_lift(Vector2.ZERO)
	_set_status("已重置单侧拉伸。", false)


# ---------- 占地范围与阻挡 ----------

func _on_blocking_changed(index: int) -> void:
	if updating:
		return
	mask_editor.set_blocking_mode(blocking_option.get_item_id(index))
	_update_mask_summary()


func _on_all_solid() -> void:
	_set_mask_mode(AssetDef.Blocking.ALL)
	var empty: Array[Vector2i] = []
	mask_editor.set_cells(empty)
	_update_mask_summary()


func _on_all_pass() -> void:
	_set_mask_mode(AssetDef.Blocking.NONE)
	var empty: Array[Vector2i] = []
	mask_editor.set_cells(empty)
	_update_mask_summary()


func _on_invert() -> void:
	var blocked: Array[Vector2i] = mask_editor.get_cells()
	var inverted: Array[Vector2i] = []
	for cell: Vector2i in mask_editor.all_cells():
		if not blocked.has(cell):
			inverted.append(cell)
	_apply_mask_cells(inverted)


func _apply_mask_cells(cells: Array[Vector2i]) -> void:
	_set_mask_mode(AssetDef.Blocking.MASK)
	mask_editor.set_cells(cells)
	_update_mask_summary()


func _set_mask_mode(mode: int) -> void:
	updating = true
	blocking_option.select(mode)
	mask_editor.set_blocking_mode(mode)
	updating = false


func _update_mask_summary() -> void:
	var fp: Vector2i = Vector2i(int(foot_w.value), int(foot_h.value))
	var mode: int = blocking_option.get_item_id(maxi(blocking_option.selected, 0))
	var total: int = fp.x * fp.y
	var blocked: int = total if mode == AssetDef.Blocking.ALL else 0
	if mode == AssetDef.Blocking.MASK:
		blocked = mask_editor.get_cells().size()
	mask_summary.text = "占地范围 %d×%d · 阻挡 %d 格 · 通行 %d 格" % [
		fp.x, fp.y, blocked, total - blocked]


# ---------- 保存 / 删除 ----------

func _on_save() -> void:
	var path_text: String = path_edit.text.strip_edges()
	if path_text.is_empty():
		_set_status("PNG 路径不能为空。", true)
		return
	var image: Image = _read_image(path_text)
	if image == null:
		_set_status("PNG 路径无法读取。", true)
		return
	if image.detect_alpha() == Image.ALPHA_NONE:
		_set_status("PNG 没有 alpha 通道；GridAtlas 只接收透明 PNG。", true)
		return
	# 同一张图保存时保留已存的内容区，避免每次保存都被 alpha bbox 重算而漂移
	var same_texture: bool = not is_new and current_def != null \
		and _res_path(path_text) == current_def.texture_path
	current_image = image
	if not same_texture or not _rect_inside_image(current_content_rect, image):
		current_content_rect = _used_rect(image)
	mask_editor.set_texture(_content_texture(image, current_content_rect))
	_update_content_label()

	var def: StaticAssetDef = AssetDef.new() if is_new else current_def.clone_def()
	if is_new:
		var new_id: String = _slug_from_path(id_edit.text.strip_edges() if not id_edit.text.strip_edges().is_empty() else path_text)
		if _id_exists(new_id):
			_set_status("ID 已存在：%s；请换一个 ID。" % new_id, true)
			return
		def.id = StringName(new_id)
	def.display_name = name_edit.text.strip_edges()
	def.category = AssetDef.CATEGORY_IDS[maxi(category_option.selected, 0)]
	def.tier = int(tier_spin.value)
	def.texture_path = _res_path(path_text)
	def.content_rect = current_content_rect
	def.art_size = Vector2(art_width, _art_height())
	def.art_lift = mask_editor.get_lift()
	def.art_offset = mask_editor.get_art_offset()
	def.footprint = Vector2i(int(foot_w.value), int(foot_h.value))
	def.blocking_mode = blocking_option.get_item_id(maxi(blocking_option.selected, 0))
	var cells: Array[Vector2i] = []
	if def.blocking_mode == AssetDef.Blocking.MASK:
		cells = mask_editor.get_cells()
	def.blocking_cells = cells
	def.normalize()
	var errors: Array[String] = def.validate()
	if not errors.is_empty():
		_set_status(errors[0], true)
		return

	var saved_path: String = AssetStore.save_def(def)
	if saved_path.is_empty():
		_set_status("保存资源定义失败。", true)
		return
	if catalog.add_path(saved_path):
		AssetStore.save_catalog(catalog)
	current_def = def
	current_path = saved_path
	is_new = false
	auto_art = false
	id_edit.text = String(def.id)
	id_edit.editable = false
	delete_button.disabled = false
	save_button.text = "保存修改"
	_refresh_list(String(def.id))
	_set_status("已保存：%s" % saved_path, false)
	asset_saved.emit(def.id)


func _on_delete() -> void:
	if current_path.is_empty():
		_new_asset()
		return
	confirm_dialog.dialog_text = "删除资源定义？\n%s\n\n只删除 .tres，不会删除 PNG。" % String(current_def.id)
	confirm_dialog.popup_centered(Vector2i(440, 180))


func _on_delete_confirmed() -> void:
	if current_path.is_empty():
		return
	catalog.remove_path(current_path)
	AssetStore.save_catalog(catalog)
	AssetStore.delete_def_file(current_path)
	_refresh_list()
	if defs.is_empty():
		_new_asset()
	else:
		asset_list.select(0)
		_open_definition(def_paths[0])
	_set_status("已删除资源定义，PNG 保留。", false)


# ---------- 图片 / 数值辅助 ----------

func _set_path_text(path: String) -> void:
	path_edit.text = path
	path_edit.tooltip_text = path


func _on_path_text_changed(text: String) -> void:
	path_edit.tooltip_text = text


## 列表里优先显示短名（CV-E03_...__gate_r2_se -> gate_r2_se），完整名称放在 tooltip
func _list_title(def: StaticAssetDef) -> String:
	return def.short_name()


func _read_image(path: String) -> Image:
	if path.strip_edges().is_empty():
		return null
	var abs_path: String = ProjectSettings.globalize_path(path) \
		if path.begins_with("res://") or path.begins_with("user://") else path
	var image: Image = Image.new()
	if image.load(abs_path) == OK and not image.is_empty():
		return image
	var tex: Texture2D = load(path) as Texture2D
	if tex != null:
		return tex.get_image()
	return null


func _load_texture(path: String, preferred_rect: Rect2i = Rect2i()) -> void:
	current_image = _read_image(path)
	if current_image == null:
		current_content_rect = preferred_rect if _rect_has_area(preferred_rect) else Rect2i()
		mask_editor.set_texture(null)
		_update_content_label()
		return
	current_content_rect = preferred_rect if _rect_inside_image(preferred_rect, current_image) \
		else _used_rect(current_image)
	mask_editor.set_texture(_content_texture(current_image, current_content_rect))
	_update_content_label()


## 游戏端只画 content_rect 裁出来的区域；导入页用同一块裁切图，避免预览比实际大一圈
func _content_texture(image: Image, rect: Rect2i) -> Texture2D:
	var clipped: Rect2i = rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return null
	return ImageTexture.create_from_image(image.get_region(clipped))


func _rect_has_area(rect: Rect2i) -> bool:
	return rect.size.x > 0 and rect.size.y > 0


func _rect_inside_image(rect: Rect2i, image: Image) -> bool:
	if not _rect_has_area(rect):
		return false
	var full: Rect2i = Rect2i(Vector2i.ZERO, image.get_size())
	return rect.position.x >= full.position.x and rect.position.y >= full.position.y \
		and rect.end.x <= full.end.x and rect.end.y <= full.end.y


func _used_rect(image: Image) -> Rect2i:
	var used: Rect2i = image.get_used_rect()
	if not _rect_has_area(used):
		return Rect2i(Vector2i.ZERO, image.get_size())
	return used


func _update_content_label() -> void:
	if not _rect_has_area(current_content_rect):
		content_label.text = "-"
		return
	content_label.text = "%d×%d @ (%d,%d)" % [
		current_content_rect.size.x, current_content_rect.size.y,
		current_content_rect.position.x, current_content_rect.position.y]


## 内容区宽高比 → 当前宽度下的自然立牌高度（格）
func _auto_art_height(width: float) -> float:
	var rect: Rect2i = current_content_rect
	if not _rect_has_area(rect):
		if current_image == null:
			return maxf(0.1, width)
		rect = Rect2i(Vector2i.ZERO, current_image.get_size())
	return maxf(0.1, width * float(rect.size.y) / float(rect.size.x))


func _art_height() -> float:
	return maxf(0.1, _auto_art_height(art_width) * art_stretch)


func _sync_art_size() -> void:
	var height: float = _art_height()
	mask_editor.set_art_size(Vector2(art_width, height))
	size_info.text = "%.2f × %.2f 格" % [art_width, height]


func _set_width_control(value: float) -> void:
	art_width = clampf(value, MIN_ART_WIDTH, MAX_ART_WIDTH)
	_sync_width_controls()


func _set_y_stretch_control(value: float) -> void:
	art_stretch = clampf(value, MIN_ART_STRETCH, MAX_ART_STRETCH)
	_sync_stretch_controls()


## 滑杆只覆盖常用区间，SpinBox 覆盖全部合法值；两边用同一状态回显，互不触发信号
func _sync_width_controls() -> void:
	width_slider.set_value_no_signal(art_width)
	width_spin.set_value_no_signal(art_width)


func _sync_stretch_controls() -> void:
	y_stretch.set_value_no_signal(art_stretch)
	stretch_spin.set_value_no_signal(art_stretch)


func _res_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return path
	return ProjectSettings.localize_path(path)


func _slug_from_path(path: String) -> String:
	var base: String = path.get_file().get_basename().to_lower()
	for suffix: String in ["__base", "__mirror_h", "__rotate_90"]:
		base = base.replace(suffix, "")
	var out: String = ""
	for i in base.length():
		var ch: String = base[i]
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_":
			out += ch
		else:
			out += "_"
	while out.contains("__"):
		out = out.replace("__", "_")
	out = out.strip_edges()
	if out.is_empty():
		out = "asset"
	if out[0] >= "0" and out[0] <= "9":
		out = "a_" + out
	return out


func _unique_id(base: String) -> String:
	var candidate: String = base
	var n: int = 2
	while _id_exists(candidate):
		candidate = "%s_%d" % [base, n]
		n += 1
	return candidate


func _id_exists(id: String) -> bool:
	for def: StaticAssetDef in defs:
		if String(def.id) == id:
			return true
	return false


func _set_status(text: String, is_error: bool) -> void:
	status_label.text = text
	status_label.add_theme_color_override("font_color", COLOR_ERROR if is_error else COLOR_INFO)


# ---------- 窗口 / 调试 ----------

## 从编辑器弹出：重新读 catalog，尽量保留当前定义；已删除则回到第一个/新建
func open_page() -> void:
	catalog = AssetStore.load_catalog()
	_refresh_list()
	if defs.is_empty():
		_new_asset()
	else:
		var keep_id: String = String(current_def.id) if current_def != null else ""
		var found: bool = false
		for i in defs.size():
			if String(defs[i].id) == keep_id:
				asset_list.select(i)
				_open_definition(def_paths[i])
				found = true
				break
		if not found:
			asset_list.select(0)
			_open_definition(def_paths[0])
	show()


func _on_close() -> void:
	if get_tree().current_scene == self:
		get_tree().quit()
		return
	hide()
	closed.emit()


## 仅单独运行本场景时用于调试截图（--shot）。
func _capture_and_quit() -> void:
	for i in 8:
		await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	var dir: String = OS.get_environment("TEMP").replace("\\", "/") + "/gridatlas_shots"
	DirAccess.make_dir_recursive_absolute(dir)
	var out: String = dir + "/static_import.png"
	if FileAccess.file_exists(out):
		DirAccess.remove_absolute(out)
	print("[截图] %s -> %s" % [error_string(img.save_png(out)), out])
	get_tree().quit()
