class_name RenderTool
extends VBoxContainer
## RenderTool —— 渲染参数配置面板。结构全部静态在 render_tool.tscn：
##   每节是 FoldSection 实例（可折叠），行挂在 Content/Body/Rows 下，一行一个 HBoxContainer，
##   节点名即参数名，行内 Title(标题) / Slider(HSlider) / Value(数值)，范围与步长在场景里设好。
## 本脚本只做：按节点名绑定到 RenderSettings 属性、同步初始值、改动发 settings_changed。
## 颜色与过渡矩阵在材质参数浮窗里编辑，由“材质参数”按钮请求打开。
## 地表着色器一节只发请求信号，编排（拷贝副本/定位文件/重载视图）全在 main.gd。

signal settings_changed
signal material_params_requested  # 点“材质参数”：由外部打开材质浮窗（颜色/过渡矩阵）
signal shader_open_requested      # 点“打开”：物化副本并在资源管理器中定位
signal shader_reload_requested    # 点“重载”：重新读入着色器文件
signal shader_reset_requested     # 点“从母版重置”：用母版覆盖地图副本（main 先弹确认）

const MapSidecars = preload("res://data/map_sidecars.gd")

var settings: RenderSettings

@onready var seedbox:SpinBox = $"PanelTexture/VBox/Content/Body/HBoxContainer/SpinBox"
@onready var materialbutton:Button = $"ButtonMaterial"
@onready var shaderstatus:Label = $"PanelShader/VBox/Content/Body/ShaderStatus"
@onready var shaderopen:Button = $"PanelShader/VBox/Content/Body/HBoxContainer/ButtonOpenShader"
@onready var shaderreload:Button = $"PanelShader/VBox/Content/Body/HBoxContainer/ButtonReloadShader"
@onready var shaderreset:Button = $"PanelShader/VBox/Content/Body/HBoxContainer/ButtonResetShader"


func _ready() -> void:
	settings = RenderSettings.new()
	seedbox.value = settings.noise_seed
	seedbox.value_changed.connect(_on_seed_changed)
	materialbutton.pressed.connect(_on_material_button)
	shaderopen.pressed.connect(func(): shader_open_requested.emit())
	shaderreload.pressed.connect(func(): shader_reload_requested.emit())
	shaderreset.pressed.connect(func(): shader_reset_requested.emit())
	_bind_sliders()
	set_shader_context("")
	print("[渲染配置] 面板就绪（默认参数，种子 %d）" % settings.noise_seed)


# ---------- 对外接口 ----------

## 换一份配置（打开地图时载入同名的 .look.tres）：同步所有控件后广播一次
func set_settings(value: RenderSettings) -> void:
	if value == null:
		return
	settings = value
	seedbox.set_value_no_signal(settings.noise_seed)
	for section: Node in get_children():
		var rows: Node = section.get_node_or_null("VBox/Content/Body/Rows")
		if rows == null:
			continue
		for row: Node in rows.get_children():
			if not (row is HBoxContainer):
				continue
			var slider: HSlider = row.get_node("Slider") as HSlider
			var valuelabel: Label = row.get_node("Value") as Label
			var prop: StringName = StringName(row.name)
			slider.set_value_no_signal(float(settings.get(prop)))
			valuelabel.text = _fmt(slider.value)
	settings_changed.emit()


## 着色器一节的状态（打开/加载地图、保存地图后由 main 推入当前地图路径）：
##   未保存的新图 → 用母版，按钮禁用；已保存无副本 → 母版兜底；有副本 → 显示副本文件名
func set_shader_context(map_path: String) -> void:
	var path: String = MapSidecars.terrain_shader_path(map_path)
	if path.is_empty():
		shaderstatus.text = "未保存的新图 · 用母版"
	elif FileAccess.file_exists(path):
		shaderstatus.text = "地图副本 " + path.get_file()
	else:
		shaderstatus.text = "母版（保存或点“打开”生成副本）"
	var usable: bool = not path.is_empty()
	shaderopen.disabled = not usable
	shaderreload.disabled = not usable
	shaderreset.disabled = not usable


# ---------- 绑定 ----------

## 遍历各节的 Rows：行节点名就是 RenderSettings 属性名
func _bind_sliders() -> void:
	for section: Node in get_children():
		var rows: Node = section.get_node_or_null("VBox/Content/Body/Rows")
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
