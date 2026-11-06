extends RefCounted
## Toast —— 右上角轻量浮出提示（2.4s 后淡出），替代"只有控制台 print 知道"的静默失败。
## 容器与卡片模板静态在 Main.tscn（ToastLayer / ToastTemplate）；
## 这里只复制模板、填文案、做淡入淡出，不再运行时创建节点结构。
##
## 用法：Toast.show(host, "无法放置：与已有物件重叠", true)

const LIFE: float = 2.4
const FADE: float = 0.35
const MAX_STACK: int = 5


static func show(host: Control, message: String, error: bool = false) -> void:
	if host == null:
		return
	var layer: VBoxContainer = host.get_node_or_null("ToastLayer") as VBoxContainer
	var template: Control = host.get_node_or_null("ToastLayer/ToastTemplate") as Control
	if layer == null or template == null:
		return
	_trim(layer, template)
	var card: Control = template.duplicate() as Control
	card.visible = true
	card.modulate.a = 0.0
	var label: Label = card.get_node_or_null("Label") as Label
	if label != null:
		label.text = message
		if error:
			label.add_theme_color_override("font_color", Color("e07b64"))
	layer.add_child(card)

	var tween: Tween = card.create_tween()
	tween.tween_property(card, "modulate:a", 1.0, FADE)
	tween.tween_interval(LIFE)
	tween.tween_property(card, "modulate:a", 0.0, FADE)
	tween.tween_callback(card.queue_free)


## 活跃卡片超过上限时，从最早的开始回收（模板本身不算）
static func _trim(layer: VBoxContainer, template: Control) -> void:
	var active: int = 0
	for child: Node in layer.get_children():
		if child != template:
			active += 1
	for child: Node in layer.get_children():
		if active < MAX_STACK:
			break
		if child != template:
			child.queue_free()
			active -= 1
