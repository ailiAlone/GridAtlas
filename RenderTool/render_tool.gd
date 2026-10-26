class_name RenderTool
extends VBoxContainer
## RenderTool —— 渲染参数配置面板。结构全部静态在 render_tool.tscn：
##   每节 PanelContainer/VBoxContainer/Rows 下是一行一个 HBoxContainer，节点名即参数名，
##   行内 Title(标题) / Slider(HSlider) / Value(数值)，范围与步长也在场景里设好。
## 本脚本只做：按节点名绑定到 RenderSettings 属性、同步初始值、改动发 settings_changed。
## 颜色与过渡矩阵在材质参数浮窗里编辑，由“材质参数”按钮请求打开。

signal settings_changed
signal material_params_requested  # 点“材质参数”：由外部打开材质浮窗（颜色/过渡矩阵）
signal oblique_changed(on: bool)  # 斜角视图开关（作用于两个渲染实例）

var settings: RenderSettings

@onready var seedbox:SpinBox = $"PanelTexture/VBoxContainer/HBoxContainer/SpinBox"
@onready var materialbutton:Button = $"ButtonMaterial"
@onready var obliquecheck:CheckButton = $"CheckOblique"


func _ready() -> void:
	settings = RenderSettings.new()
	seedbox.value = settings.noise_seed
	seedbox.value_changed.connect(_on_seed_changed)
	materialbutton.pressed.connect(_on_material_button)
	obliquecheck.toggled.connect(_on_oblique_toggled)
	_bind_sliders()
	print("[渲染配置] 面板就绪（默认参数，种子 %d）" % settings.noise_seed)


func _on_oblique_toggled(on: bool) -> void:
	oblique_changed.emit(on)
	print("[视图] %s" % ("斜角视图" if on else "俯视"))


# ---------- 绑定 ----------

## 遍历各节的 Rows：行节点名就是 RenderSettings 属性名
func _bind_sliders() -> void:
	for section: Node in get_children():
		var rows: Node = section.get_node_or_null("VBoxContainer/Rows")
		if rows == null:
			continue
		for row: Node in rows.get_children():
			if not (row is HBoxContainer):
				continue
			var slider: HSlider = row.get_node("Slider") as HSlider
			var valuelabel: Label = row.get_node("Value") as Label
			var prop: StringName = StringName(row.name)
			slider.value = settings.get(prop)
			valuelabel.text = _fmt(slider.value)
			slider.value_changed.connect(_on_float_changed.bind(prop, valuelabel))


# ---------- 变更处理（滑杆拖动不打印，避免刷屏；种子改动打印） ----------

func _on_float_changed(value: float, prop: StringName, valuelabel: Label) -> void:
	settings.set(prop, value)
	valuelabel.text = _fmt(value)
	settings_changed.emit()


func _on_seed_changed(value: float) -> void:
	settings.noise_seed = int(value)
	print("[渲染配置] 噪声种子 = %d" % settings.noise_seed)
	settings_changed.emit()


func _on_material_button() -> void:
	material_params_requested.emit()


func _fmt(v: float) -> String:
	# 最多保留 3 位有效数字（去掉多余尾零）
	if absf(v) < 0.000000001:
		return "0"
	var digits: int = 3
	var exp: int = int(floor(log(absf(v)) / log(10.0)))
	var decimals: int = clampi(digits - 1 - exp, 0, 6)
	var s: String = ("%." + str(decimals) + "f") % v
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return s
