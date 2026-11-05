extends Control
## GridAtlas —— 固定 45° 视角的地图视图（游戏端）。
##
## 只做一件事：把 MapRuntime 的地表着色器铺满视口，并给游戏实体提供**同一套投影**。
##   · 地面：全屏 ColorRect，着色器在片段里对高度场做正交斜视步进（遮挡是真的）
##   · 实体：Actors 只做平移 + 等比缩放，子节点按"投影后的格坐标"摆放
##           → 立牌不会被旋转/压扁，脚底永远落在对应的地表点上
##
## 投影（yaw = 相机方位，pitch = 俯角）：
##   yaw: 0=相机在北 90°=东 135°=东南 180°=南
##   fd = (-sin yaw, cos yaw)          视线方向（相机 → 场景）
##   rt = (-fd.y, fd.x)                屏幕右向
##   screen = 视口中心 + ppm · ( (P-C)·rt , (P-C)·(-fd)·sin(pitch) - z·cos(pitch) )
## 着色器里的 ray march 用同一组 fd/rt，所以地面和立牌不会各说各话。

const MIN_ZOOM: float = 3.0
const MAX_ZOOM: float = 72.0
const ACTOR_SHADER: String = "res://runtime/actor_card.gdshader"
const ACTOR_SPRITE_SHADER: String = "res://runtime/actor_sprite.gdshader"
const GridProj = preload("res://data/grid_projection.gd")

@onready var ground: ColorRect = $"Ground"
@onready var actors: Node2D = $"Actors"
@onready var debug_layer: Control = $"DebugLayer"

var runtime
var center_cell: Vector2 = Vector2.ZERO   # 视口中心对应的地面点（格坐标 0..map_size）
var ppm: float = 24.0                      # 屏幕像素 / 格
var pitch: float = deg_to_rad(45.0)        # 俯角
var yaw: float = deg_to_rad(135.0)         # 相机方位：135° = 在地图东南看向西北
var show_debug: bool = false

var _view_size: Vector2 = Vector2.ZERO
var _actor_shader: Shader
var _actor_sprite_shader: Shader


func _ready() -> void:
	_actor_shader = load(ACTOR_SHADER) as Shader
	_actor_sprite_shader = load(ACTOR_SPRITE_SHADER) as Shader
	debug_layer.set("atlas", self)
	resized.connect(refresh_view)
	refresh_view()


func setup(rt) -> void:
	runtime = rt
	ground.material = rt.material
	refresh_view()


# ---------- 相机 ----------

func forward_axis() -> Vector2:
	return GridProj.forward_axis(yaw)


func right_axis() -> Vector2:
	return GridProj.right_axis(yaw)


func set_center_cell(pos: Vector2) -> void:
	center_cell = pos
	_clamp_center()
	_apply_camera()


func set_zoom(value: float) -> void:
	ppm = clampf(value, MIN_ZOOM, MAX_ZOOM)
	_apply_camera()


## 编辑器小预览专用：整图取景需要 ppm 低于 MIN_ZOOM，且 center 允许略微出界。
## 交互视图（大 45° 画面 / 游戏）仍走 set_zoom / set_center_cell 的限制。
func set_camera_unclamped(center: Vector2, value: float) -> void:
	center_cell = center
	ppm = maxf(value, 0.01)
	_apply_camera()


## 以屏幕上的某点为锚缩放：锚点下的地面保持不动
func zoom_at(screen_pos: Vector2, factor: float) -> void:
	var old_ppm: float = ppm
	var new_ppm: float = clampf(ppm * factor, MIN_ZOOM, MAX_ZOOM)
	if is_equal_approx(new_ppm, old_ppm):
		return
	var anchor: Vector2 = screen_to_ground_at(screen_pos, 0.0)
	ppm = new_ppm
	var d: Vector2 = (screen_pos - _view_size * 0.5) / ppm
	center_cell = anchor - right_axis() * d.x + forward_axis() * (d.y / sin(pitch))
	_clamp_center()
	_apply_camera()


## 按屏幕位移拖动地图
func pan(screen_delta: Vector2) -> void:
	center_cell += right_axis() * (-screen_delta.x / ppm) \
		+ forward_axis() * (screen_delta.y / (ppm * sin(pitch)))
	_clamp_center()
	_apply_camera()


func set_debug(on: bool) -> void:
	show_debug = on
	debug_layer.queue_redraw()


func refresh_view() -> void:
	_view_size = size
	if _view_size.x < 1.0 or _view_size.y < 1.0:
		return
	_apply_camera()


func _apply_camera() -> void:
	var fd: Vector2 = forward_axis()
	var rt: Vector2 = right_axis()
	actors.scale = Vector2(ppm, ppm)
	actors.position = _view_size * 0.5 \
		- Vector2(center_cell.dot(rt), center_cell.dot(-fd) * sin(pitch)) * ppm
	if runtime != null:
		var mat: ShaderMaterial = runtime.material
		mat.set_shader_parameter("u_oblique", 1.0)
		mat.set_shader_parameter("u_pitch", pitch)
		mat.set_shader_parameter("u_view_yaw", yaw)
		mat.set_shader_parameter("u_view_center", center_cell)
		mat.set_shader_parameter("u_view_cells", _view_size.x / ppm)
		mat.set_shader_parameter("u_view_size", _view_size)
	debug_layer.queue_redraw()


## 把相机中心收进地图范围（允许视口伸到图外）。
## 不能要求"整块视口都在地图内"：那会把相机顶在离边缘半个视口的地方，
## 玩家继续走向边缘就会离开画面。图外的天空/边缘侧壁由着色器兜住。
func clamped_center(pos: Vector2) -> Vector2:
	if runtime == null or _view_size.x < 1.0:
		return pos
	var map_size: Vector2 = Vector2(runtime.map.grid_size)
	return Vector2(clampf(pos.x, 0.0, map_size.x), clampf(pos.y, 0.0, map_size.y))


func _clamp_center() -> void:
	center_cell = clamped_center(center_cell)


# ---------- 投影（实体与点击共用） ----------

## 地面点 → 投影空间（Actors 的局部坐标，单位=格）。height 是渲染高度（世界格）。
func projected_point(pos: Vector2, height: float = 0.0) -> Vector2:
	return GridProj.project_point(pos, height, yaw, pitch)


## 地面点 → 屏幕像素（GridAtlas 本地）
func cell_to_screen(pos: Vector2, height: float = 0.0) -> Vector2:
	var fd: Vector2 = forward_axis()
	var rt: Vector2 = right_axis()
	var d: Vector2 = pos - center_cell
	return _view_size * 0.5 \
		+ Vector2(d.dot(rt), d.dot(-fd) * sin(pitch) - height * cos(pitch)) * ppm


## 立牌画序：按"脚底离相机的距离"排序。
## 不能用绝对深度（yaw=0 时全图深度都是负的，会被地面 z=0 盖住），
## 统一映射到 200..3400 的正区间；相邻格约几十级，足够区分。
func actor_z_index(pos: Vector2) -> int:
	var depth: float = pos.dot(-forward_axis())
	var span: float = float(runtime.map.grid_size.x + runtime.map.grid_size.y)
	var scale: float = 3200.0 / maxf(span * 1.41421356, 1.0)
	return 200 + int(round((depth + span * 0.70710678) * scale))


## 屏幕像素 → 指定高度处的地面点
func screen_to_ground_at(screen: Vector2, height: float) -> Vector2:
	var fd: Vector2 = forward_axis()
	var rt: Vector2 = right_axis()
	var d: Vector2 = (screen - _view_size * 0.5) / ppm
	var base: Vector2 = center_cell + rt * d.x - fd * (d.y / sin(pitch))
	return base - fd * (height * cos(pitch) / sin(pitch))


## 屏幕像素 → 格（沿视线迭代几次，落到地表而不是 z=0 平面）
func screen_to_cell(screen: Vector2) -> Vector2i:
	if runtime == null:
		return Vector2i(-1, -1)
	var pos: Vector2 = screen_to_ground_at(screen, 0.0)
	for i in 3:
		var cell: Vector2i = Vector2i(floori(pos.x), floori(pos.y))
		var z: float = runtime.terrain_z(cell)
		pos = screen_to_ground_at(screen, z)
	return Vector2i(floori(pos.x), floori(pos.y))


# ---------- 立牌 ----------

## 每个立牌一份材质：数据纹理共享，基格/基高/透明度是逐实体的。
## 真正的美术资源接进来时，只要保留这几个 uniform，遮挡逻辑不用改。
## 注意：pitch/yaw/height_scale 在创建时写进材质；运行时若要改视角或改高程比例，
## 需要给所有立牌重建材质（固定视角下不用管）。
func make_actor_material(kind: int, art_size: Vector2, fade: float) -> ShaderMaterial:
	if _actor_shader == null:
		_actor_shader = load(ACTOR_SHADER) as Shader
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = _actor_shader
	var src: ShaderMaterial = runtime.material
	mat.set_shader_parameter("u_elev_smooth", src.get_shader_parameter("u_elev_smooth"))
	mat.set_shader_parameter("u_map_size", src.get_shader_parameter("u_map_size"))
	mat.set_shader_parameter("u_height_scale", src.get_shader_parameter("u_height_scale"))
	mat.set_shader_parameter("u_elev_smooth_max", 32.0)
	mat.set_shader_parameter("u_pitch", pitch)
	mat.set_shader_parameter("u_view_dir", -forward_axis())
	mat.set_shader_parameter("u_fade", fade)
	mat.set_shader_parameter("u_kind", float(kind))
	mat.set_shader_parameter("u_art_size", art_size)
	# 立牌不压缩：屏幕上 1 格高的图，等价于世界上 1/cos(pitch) 格高
	mat.set_shader_parameter("u_art_height", art_size.y / cos(pitch))
	# 所有 2D 立牌共享一层很轻的色盘/颗粒，向 shader 地形靠拢
	mat.set_shader_parameter("u_style_sat", 0.93)
	mat.set_shader_parameter("u_style_tint", Vector3(1.02, 0.99, 0.95))
	mat.set_shader_parameter("u_style_grain", 0.012)
	return mat


## 贴图立牌（静态资源 / 示例玩家）：几何/遮挡与程序化立牌同一套，只是颜色来自贴图。
## lift：左/右整侧垂直抬升比例；flip_x：竖向资源水平镜像贴图与左右抬升。
func make_sprite_material(texture: Texture2D, art_size: Vector2, fade: float,
		lift: Vector2 = Vector2.ZERO, flip_x: bool = false) -> ShaderMaterial:
	if _actor_sprite_shader == null:
		_actor_sprite_shader = load(ACTOR_SPRITE_SHADER) as Shader
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = _actor_sprite_shader
	var src: ShaderMaterial = runtime.material
	mat.set_shader_parameter("u_art", texture)
	mat.set_shader_parameter("u_elev_smooth", src.get_shader_parameter("u_elev_smooth"))
	mat.set_shader_parameter("u_map_size", src.get_shader_parameter("u_map_size"))
	mat.set_shader_parameter("u_height_scale", src.get_shader_parameter("u_height_scale"))
	mat.set_shader_parameter("u_elev_smooth_max", 32.0)
	mat.set_shader_parameter("u_pitch", pitch)
	mat.set_shader_parameter("u_view_dir", -forward_axis())
	mat.set_shader_parameter("u_fade", fade)
	mat.set_shader_parameter("u_art_size", art_size)
	mat.set_shader_parameter("u_art_lift", lift)
	mat.set_shader_parameter("u_flip_x", flip_x)
	mat.set_shader_parameter("u_art_height", art_size.y / cos(pitch))
	# 所有 2D 立牌共享一层很轻的色盘/颗粒，向 shader 地形靠拢
	mat.set_shader_parameter("u_style_sat", 0.93)
	mat.set_shader_parameter("u_style_tint", Vector3(1.02, 0.99, 0.95))
	mat.set_shader_parameter("u_style_grain", 0.012)
	return mat
