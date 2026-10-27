extends PanelContainer
## MaterialParameters —— 材质参数浮窗（RenderView 子节点）。
## 结构全部静态在 material_parameters.tscn：
##   材质颜色：HFlowContainer 下 12 个 ColorRect（内含文字 Label + 选中描边 Outline）
##   材质过渡矩阵：GridContainer（9 列）下的表头 Label + 8×8 TextEdit（直接输入 0..1）
## 本脚本只负责：点选色块 → 右侧取色器实时调色；矩阵输入解析并镜像对称格；
## 改动经 settings_changed 通知外部（main 接到两个渲染实例即时重渲）。
## settings 由所属 RenderView 在 apply_settings 时推入，这里只做数值同步。

signal settings_changed

## 材质编号 -> 场景节点名（颜色区）
const SWATCH_NODES: Dictionary = {
	1: "Grass", 2: "Sand", 3: "Wasteland", 4: "Snow", 5: "Swamp", 6: "Ice",
	7: "Shallow", 8: "Deep", 9: "Dirt", 10: "Gravel", 11: "StoneBrick", 12: "Foam",
	13: "Rock", 14: "SnowCap",
}
const MATERIAL_NAMES: Dictionary = {
	1: "草地", 2: "沙地", 3: "荒地", 4: "雪地", 5: "沼泽", 6: "冰面",
	7: "浅水", 8: "深水", 9: "土路", 10: "碎石路", 11: "石砖路", 12: "泡沫",
	13: "岩石", 14: "雪线",
}

var settings: RenderSettings
var selected: int = 1
var _syncing: bool = false  # 程序回写文本时屏蔽 text_changed，避免递归

var swatches: Dictionary = {}       # 材质编号 -> ColorRect
var outlines: Dictionary = {}       # 材质编号 -> 选中描边 Panel
var affinityboxes: Dictionary = {}  # Vector2i(a, b) -> TextEdit

@onready var swatchflow:HFlowContainer = $"HBoxContainer/VBoxContainer/PanelContainer/VBoxContainer/HFlowContainer"
@onready var affinitygrid:GridContainer = $"HBoxContainer/VBoxContainer/PanelContainer2/VBoxContainer/GridContainer"
@onready var picker:ColorPicker = $"HBoxContainer/ColorPicker"
@onready var closebutton:Button = $"HBoxContainer/VBoxContainer/Button"


func _ready() -> void:
	closebutton.pressed.connect(hide)
	picker.color_changed.connect(_on_picker_changed)
	_bind_static_widgets()


# ---------- 静态控件绑定 ----------

func _bind_static_widgets() -> void:
	for index: int in SWATCH_NODES:
		var rect: ColorRect = swatchflow.get_node(String(SWATCH_NODES[index])) as ColorRect
		rect.gui_input.connect(_on_swatch_input.bind(index))
		swatches[index] = rect
		outlines[index] = rect.get_node("Outline") as Panel
	for a in range(1, 9):
		for b in range(1, 9):
			var box: TextEdit = affinitygrid.get_node("A%d_%d" % [a, b]) as TextEdit
			if a != b:
				box.text_changed.connect(_on_affinity_text_changed.bind(a, b))
				box.focus_exited.connect(_on_affinity_focus_exited.bind(a, b))
			affinityboxes[Vector2i(a, b)] = box


# ---------- 对外 ----------

## 由 RenderView.apply_settings 推入配置，同步到静态控件
func set_settings(s: RenderSettings) -> void:
	settings = s
	_sync_widgets()


## 打开并摆到父视图当前可见区左上角（大面板有滚动时也保证整个窗口可见）
func open() -> void:
	visible = true
	_place_in_view()


# ---------- 交互 ----------

func _on_swatch_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		selected = index
		_apply_selection()
		print("[材质] 选中 %s" % MATERIAL_NAMES[index])


func _on_picker_changed(color: Color) -> void:
	if settings == null:
		return
	if selected == 14:
		settings.snowcap_color = color
	elif selected == 13:
		settings.rock_color = color
	elif selected == 12:
		settings.foam_color = color
	elif selected >= 9:
		settings.road_colors[selected] = color
	elif selected >= 7:
		settings.water_colors[selected] = color
	else:
		settings.land_colors[selected] = color
	_paint_swatch(selected)
	settings_changed.emit()


## 输入即解析：合法数值（0..1）立刻生效，并同步对称格
func _on_affinity_text_changed(a: int, b: int) -> void:
	if _syncing or settings == null:
		return
	var box: TextEdit = affinityboxes[Vector2i(a, b)]
	var raw: String = box.text.replace("\n", "").strip_edges()
	if raw != box.text:
		# TextEdit 里回车会插入换行，这里直接抹掉（单格单值）
		_syncing = true
		box.set_text(raw)
		_syncing = false
	if raw == "" or not raw.is_valid_float():
		return
	var value: float = clampf(raw.to_float(), 0.0, 1.0)
	settings.set_affinity(a, b, value)
	_set_box_text(b, a, value)


## 离开格子时统一格式化为两位小数，顺便清掉非法输入
func _on_affinity_focus_exited(a: int, b: int) -> void:
	if settings == null:
		return
	_set_box_text(a, b, settings.get_affinity(a, b))


# ---------- 刷新 ----------

## 色块填色 + 深浅底上自动切黑/白文字
func _paint_swatch(index: int) -> void:
	var rect: ColorRect = swatches[index]
	var color: Color = settings.surface_color(index)
	rect.color = color
	var label: Label = rect.get_node_or_null("Label") as Label
	if label != null:
		label.add_theme_color_override("font_color", Color.BLACK if color.get_luminance() > 0.45 else Color.WHITE)


func _apply_selection() -> void:
	for index: int in outlines:
		(outlines[index] as Panel).visible = index == selected
	if settings != null:
		picker.color = settings.surface_color(selected)


## 外部改动（RenderTool 滑杆等）后仅刷新数值
func _sync_widgets() -> void:
	for index: int in swatches:
		_paint_swatch(index)
	picker.color = settings.surface_color(selected)
	_syncing = true
	for key: Vector2i in affinityboxes:
		(affinityboxes[key] as TextEdit).set_text("%.2f" % settings.get_affinity(key.x, key.y))
	_syncing = false
	_apply_selection()


func _set_box_text(a: int, b: int, value: float) -> void:
	_syncing = true
	(affinityboxes[Vector2i(a, b)] as TextEdit).set_text("%.2f" % value)
	_syncing = false


## 摆到父视图可见区左上角（ScrollContainer 会把子节点位置设为负的滚动偏移）
func _place_in_view() -> void:
	var parent_ctl: Control = get_parent() as Control
	if parent_ctl == null:
		return
	var vis_origin: Vector2 = Vector2.ZERO
	var vis_size: Vector2 = parent_ctl.size
	var scroll: Node = parent_ctl.get_parent()
	if scroll is ScrollContainer:
		vis_origin = -parent_ctl.position
		vis_size = (scroll as ScrollContainer).size
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = vis_origin + Vector2(8, 8)
	var pref: Vector2 = get_combined_minimum_size()
	size = Vector2(minf(maxf(pref.x, 400.0), vis_size.x - 16.0), minf(maxf(pref.y, 300.0), vis_size.y - 16.0))
