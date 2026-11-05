extends Node2D
## 静态资源/立牌的接触阴影：贴地软椭圆，画在立牌下面。
## 只负责“压住脚底”，不代替地形阴影；颜色取冷暗色，避免纯黑。
##
## 阴影是共享的径向渐变纹理，一次 draw_texture_rect 画完。
## 以前用 12 层扁椭圆叠加：159 个立牌就是 1908 次绘制指令，
## 在编辑器里白白占用 CPU/GPU；单张纹理既更平滑也只剩 159 次。

var _radius: float = 0.6
var _color: Color = Color(0.06, 0.07, 0.05, 0.22)

static var _shadow_texture: ImageTexture = null


func setup(width: float) -> void:
	_radius = maxf(width * 0.46, 0.25)
	queue_redraw()


## foot_local：脚底相对立牌节点左上角的位置（屏幕格）
func place(foot_local: Vector2) -> void:
	position = foot_local
	queue_redraw()


static func _get_shadow_texture() -> Texture2D:
	if _shadow_texture == null:
		var size: int = 64
		var img: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
		for y in size:
			for x in size:
				var dx: float = (float(x) + 0.5) / float(size) * 2.0 - 1.0
				var dy: float = (float(y) + 0.5) / float(size) * 2.0 - 1.0
				var d: float = sqrt(dx * dx + dy * dy)
				var a: float = pow(clampf(1.0 - d, 0.0, 1.0), 1.8)
				img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
		_shadow_texture = ImageTexture.create_from_image(img)
	return _shadow_texture


func _draw() -> void:
	draw_texture_rect(_get_shadow_texture(),
		Rect2(-_radius, -_radius * 0.30, _radius * 2.0, _radius * 0.60),
		false, _color)
