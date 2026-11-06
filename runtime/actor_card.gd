extends Node2D
## 2.5D 立牌实体：脚底锚点 + 程序化占位美术 / 贴图 + 高度场遮挡。
## 屏幕位置/尺寸全部来自 GridAtlas 的投影，本节点不自己算相机。
##
## 贴图立牌：art_lift 做左/右整侧垂直抬升（占立牌高度的比例），
## 把图片单侧拉伸去适配网格；片元着色器采样，节点本身只画一个 AABB 矩形。
##
## 注意：这里必须是 Node2D，不能用 Control/ColorRect。
## 立牌挂在按 ppm 缩放的 Actors 下，Control.position 会被
## gui/common/snap_controls_to_pixels 吸附到整数——在本节点里就是整格，
## 每个实例随机偏半格，成排的建筑会看起来无规律错位。

var atlas   # GridAtlas（不写类型：要跨脚本访问其成员）
var kind: int = 0
var art_size: Vector2 = Vector2(1.0, 2.2)
var art_lift: Vector2 = Vector2.ZERO     # x=左侧，y=右侧；正数=抬高
var art_flip_x: bool = false             # 竖向资源：贴图水平镜像
var art_offset: Vector2 = Vector2.ZERO   # 屏幕格偏移（不参与脚底/遮挡判定）
var fade_occluded: float = 0.38
var base_cell: Vector2 = Vector2.ZERO   # 脚底格坐标（0..map_size）

var _mat: ShaderMaterial
var _box: Vector2 = Vector2.ONE         # 立牌矩形（格，含左右抬升跨度）
var _shadow: Node2D
var _is_sprite: bool = false            # true=actor_sprite.gdshader（有 ground/variation 参数）

const GridProj = preload("res://data/grid_projection.gd")
const ShadowScript = preload("res://runtime/asset_shadow.gd")


func _ready() -> void:
	_ensure_shadow()


func _ensure_shadow() -> void:
	if _shadow == null:
		_shadow = ShadowScript.new()
		_shadow.show_behind_parent = true
		_shadow.z_as_relative = true
		_shadow.z_index = -1
		add_child(_shadow)
	var width: float = art_size.x
	_shadow.setup(width)


## kind: 0=角色（被挡后半透明） 1=树（被挡后完全消失）
## art_size: 立牌在屏幕上的尺寸，单位=格（不按俯角压缩）
## texture: 传入内容区纹理时走贴图材质；不传则用程序化占位美术
func setup(view, card_kind: int, card_size: Vector2, fade: float, texture: Texture2D = null) -> void:
	if texture != null:
		setup_sprite(view, card_size, fade, texture, Vector2.ZERO)
		return
	atlas = view
	kind = card_kind
	art_size = card_size
	art_lift = Vector2.ZERO
	art_offset = Vector2.ZERO
	_is_sprite = false
	fade_occluded = fade
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_mat = atlas.make_actor_material(kind, art_size, fade_occluded)
	material = _mat
	_apply_box()
	z_as_relative = true


## 贴图立牌（静态资源）：lift 是左/右整侧抬升比例；flip_x 为竖向资源的水平镜像
func setup_sprite(view, card_size: Vector2, fade: float, texture: Texture2D,
		lift: Vector2 = Vector2.ZERO, flip_x: bool = false) -> void:
	atlas = view
	kind = 1
	art_size = card_size
	art_lift = lift
	art_flip_x = flip_x
	art_offset = Vector2.ZERO
	_is_sprite = true
	fade_occluded = fade
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_mat = atlas.make_sprite_material(texture, art_size, fade_occluded, art_lift, art_flip_x)
	material = _mat
	_apply_box()
	z_as_relative = true


## 立牌框 = 图片尺寸 + 两侧抬升的垂直跨度。
func _apply_box() -> void:
	_box = GridProj.art_rect(Vector2.ZERO, art_size, Vector2.ZERO, art_lift).size
	queue_redraw()
	if is_inside_tree():
		_ensure_shadow()


## 用与 ColorRect 相同的 draw_rect 覆盖整个立牌框；UV 0..1 交给立牌着色器。
func _draw() -> void:
	if _mat == null:
		return
	draw_rect(Rect2(Vector2.ZERO, _box), Color.WHITE)


## pos = 格坐标（0..map_size，格心在 x+0.5）；z = 渲染高度（世界格）
## 立牌矩形由 GridProjection.art_rect 统一给出，和导入页的预览共用同一套锚点。
func place(pos: Vector2, z: float) -> void:
	base_cell = pos
	var foot: Vector2 = atlas.projected_point(pos, z)
	var art: Rect2 = GridProj.art_rect(foot, art_size, art_offset, art_lift)
	position = art.position
	if _mat != null:
		_mat.set_shader_parameter("u_base_cell", pos)
		_mat.set_shader_parameter("u_base_z", z)
	# 画序按脚底离相机的距离，而不是屏幕 y —— 高处的树不会因为"更靠上"被排到山后
	z_index = atlas.actor_z_index(pos)
	if _shadow != null:
		_shadow.place(foot - art.position)


## 运行时改 height_scale（编辑器拖滑杆）时同步遮挡用的垂直比例；
## 脚底高度还要由调用方重新 place，因为地形几何也一起变了。
func set_height_scale(value: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter("u_height_scale", value)


## 把脚底格的地形色作为很轻的环境反射，让立牌和草地/林地/水面共享一点色相。
func set_ground_tint(color: Color) -> void:
	if _mat != null and _is_sprite:
		_mat.set_shader_parameter("u_ground_tint", Vector3(color.r, color.g, color.b))


## 树木贴图底部带草垫：柔化草色像素的外缘，让贴图草垫与地形程序化草衔接。
func set_soft_grass_base(value: float) -> void:
	if _mat != null and _is_sprite:
		_mat.set_shader_parameter("u_soft_grass_base", value)


## 植物个体色调：同一张树图略偏黄/偏冷/偏暗，降低"复制粘贴感"。
func set_variation_tint(color: Color) -> void:
	if _mat != null and _is_sprite:
		_mat.set_shader_parameter("u_variation_tint",
			Vector3(color.r, color.g, color.b))


## 树冠形变：warp=上部宽度偏移，lean=上部横向倾斜；只作用于贴图立牌。
func set_crown_variation(warp: float, lean: float) -> void:
	if _mat != null and _is_sprite:
		_mat.set_shader_parameter("u_crown_warp", warp)
		_mat.set_shader_parameter("u_crown_lean", lean)
