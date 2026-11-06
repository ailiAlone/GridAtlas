extends RefCounted
## Toast —— 右上角轻量浮出提示（2.4s 后淡出），替代"只有控制台 print 知道"的静默失败。
## 用法：Toast.show(host, "无法放置：与已有物件重叠")   —— host 一般传编辑器根 Control。
## 同一 host 的提示自上而下堆叠；error=true 时文字用警示红。

const WIDTH: int = 320
const LIFE: float = 2.4
const FADE: float = 0.35
const MAX_STACK: int = 5


static func show(host: Control, message: String, error: bool = false) -> void:
	if host == null:
		return
	var layer: VBoxContainer = _layer(host)
	while layer.get_child_count() >= MAX_STACK:
		layer.get_child(0).queue_free()

	var card: PanelContainer = PanelContainer.new()
	var label: Label = Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(WIDTH, 0)
	if error:
		label.add_theme_color_override("font_color", Color("e07b64"))
	card.add_child(label)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.modulate.a = 0.0
	layer.add_child(card)

	var tween: Tween = card.create_tween()
	tween.tween_property(card, "modulate:a", 1.0, FADE)
	tween.tween_interval(LIFE)
	tween.tween_property(card, "modulate:a", 0.0, FADE)
	tween.tween_callback(card.queue_free)


## 每个宿主一个右上角浮层容器（VBox 堆叠），挂在宿主 meta 上避免重复创建
static func _layer(host: Control) -> VBoxContainer:
	if host.has_meta("_toast_layer"):
		return host.get_meta("_toast_layer") as VBoxContainer
	var layer: VBoxContainer = VBoxContainer.new()
	layer.name = "ToastLayer"
	layer.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	layer.offset_left = -WIDTH - 16.0
	layer.offset_top = 54.0   # 让开 45° 预览顶部的常驻提示条
	layer.offset_right = -16.0
	layer.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	layer.add_theme_constant_override("separation", 8)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.z_index = 4095   # CanvasItem z 上限 4096，取顶格
	host.add_child(layer)
	host.set_meta("_toast_layer", layer)
	return layer
