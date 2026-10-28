extends ColorRect
## 2.5D 立牌实体：脚底锚点 + 程序化占位美术 / 贴图 + 高度场遮挡。
## 屏幕位置/尺寸全部来自 GridAtlas 的投影，本节点不自己算相机。
##
## 贴图立牌支持 art_lift：左/右整侧垂直抬升（占立牌高度的比例），
## 用来把图片单侧拉伸去适配网格；节点高度会加上抬升的跨度，
## 片元着色器按剪切后的四边形采样，图片本身仍是原比例。

var atlas   # GridAtlas（不写类型：要跨脚本访问其成员）
var kind: int = 0
var art_size: Vector2 = Vector2(1.0, 2.2)
var art_lift: Vector2 = Vector2.ZERO     # x=左侧，y=右侧；正数=抬高
var art_flip_x: bool = false             # 竖向资源：贴图水平镜像
var art_offset: Vector2 = Vector2.ZERO   # 屏幕格偏移（不参与脚底/遮挡判定）
var fade_occluded: float = 0.38
var base_cell: Vector2 = Vector2.ZERO   # 脚底格坐标（0..map_size）
var base_z: float = 0.0                 # 脚底地表高度（世界格）

var _mat: ShaderMaterial


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
	fade_occluded = fade
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
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
	fade_occluded = fade
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_mat = atlas.make_sprite_material(texture, art_size, fade_occluded, art_lift, art_flip_x)
	material = _mat
	_apply_box()
	z_as_relative = true


## 节点尺寸 = 图片尺寸 + 两侧抬升的垂直跨度（着色器负责按剪切四边形采样）
func _apply_box() -> void:
	var span: float = absf(art_lift.x - art_lift.y) * art_size.y
	size = Vector2(art_size.x, art_size.y + span)


## 节点顶边相对脚底的 y：图片原始顶边是 -art_h，再减去更高一侧的抬升量
func _top_offset() -> float:
	return -art_size.y * (1.0 + maxf(art_lift.x, art_lift.y))


## pos = 格坐标（0..map_size，格心在 x+0.5）；z = 渲染高度（世界格）
func place(pos: Vector2, z: float) -> void:
	base_cell = pos
	base_z = z
	var foot: Vector2 = atlas.projected_point(pos, z)
	position = foot + Vector2(-art_size.x * 0.5, _top_offset()) + art_offset
	if _mat != null:
		_mat.set_shader_parameter("u_base_cell", pos)
		_mat.set_shader_parameter("u_base_z", z)
	# 画序按脚底离相机的距离，而不是屏幕 y —— 高处的树不会因为"更靠上"被排到山后
	z_index = atlas.actor_z_index(pos)


## 运行时改 height_scale（编辑器拖滑杆）时同步遮挡用的垂直比例；
## 脚底高度还要由调用方重新 place，因为地形几何也一起变了。
func set_height_scale(value: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter("u_height_scale", value)
