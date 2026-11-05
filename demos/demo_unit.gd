extends RefCounted
## 示例场景的角色立牌（Tiny Swords 战士 Idle 第 0 帧）。
## 这不是地图资源目录：编辑器可放置的资源全部来自 Assets/static_assets。

const FILE: String = "res://Assets/TinySwords/Units/Warrior_Idle.png"
const REGION: Rect2 = Rect2(62, 48, 79, 89)
const SIZE: Vector2 = Vector2(1.69, 1.9)

static var _texture: Texture2D


static func texture() -> Texture2D:
	if _texture != null:
		return _texture
	var src: Texture2D = load(FILE) as Texture2D
	if src == null:
		return null
	var full: Image = src.get_image()
	if full == null:
		return null
	var rect: Rect2i = Rect2i(
		roundi(REGION.position.x), roundi(REGION.position.y),
		roundi(REGION.size.x), roundi(REGION.size.y))
	var clipped: Rect2i = rect.intersection(Rect2i(Vector2i.ZERO, full.get_size()))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return null
	_texture = ImageTexture.create_from_image(full.get_region(clipped))
	return _texture
