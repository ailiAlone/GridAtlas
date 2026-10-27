class_name RenderView
extends Control
## RenderView —— 成品渲染视图（纯程序化，无外部素材）。
## MapData 打包成数据纹理（每格一像素），render_view.gdshader 逐像素着色；
## 全部开发者参数集中在 RenderSettings（RenderTool 面板编辑），经 apply_settings() 注入。
## 阶段一（当前）：独立运行自动加载 first.tres 预览；并入主场景后由 main.gd 注入地图与配置。

const NOISE_SIZE: int = 256
const PREVIEW_MAP_PATH: String = "res://GridData/maps/second.tres"
const SHADER_PATH: String = "res://RenderView/render_view.gdshader"
const COLOR_COUNT: int = 15  # 0空 1..6陆 7..8水 9..11路 12泡沫 13岩石 14雪线
## 平滑高程纹理的取值范围（级）。8 位纹理在这里换到最细的 0.0625 级。
const ELEV_SMOOTH_MAX: float = 32.0
## 可分离 5 点平滑核（1 4 6 4 1）/16
const ELEV_BLUR: Array[float] = [1.0, 4.0, 6.0, 4.0, 1.0]
## RenderSettings 属性名 == uniform 名去掉 u_ 前缀
const SCALAR_UNIFORMS: Array[StringName] = [
	&"texture_strength", &"texture_frequency", &"grain", &"biome", &"bump",
	&"band_hard", &"band_soft", &"edge_jitter", &"coast_warp",
	&"crease_width", &"crease_dark", &"relief",
	&"tide_frequency", &"tide_amplitude",
	&"ripple_frequency", &"ripple_speed", &"ripple_strength", &"flow_speed",
	&"foam_width", &"foam_strength",
	&"road_width", &"road_softness", &"road_texture", &"road_round", &"road_bend",
	&"elevation_bright", &"elevation_shadow", &"elevation_rim", &"elevation_shadow_width",
	&"height_scale",
]

var map: MapData
var settings: RenderSettings
var time_sec: float = 0.0
var big_panel: bool = false  # 大面板模式（COVER 撑满滚动区）；false=小面板/独立运行（CONTAIN 居中）

var dataimage: Image    # RGBA8：R=陆地 G=水域 B=道路 A=流向
var elevimage: Image    # R8：高程（原始单位，1 级 = elev_unit 单位）
var elevsmoothimage: Image  # R8：平滑高程（几何与光照共用）
var smoothbytes: PackedByteArray = PackedByteArray()  # 平滑高程的权威字节流（就地区域更新）
var datatexture: ImageTexture
var elevtexture: ImageTexture
var elevsmoothtexture: ImageTexture
var colortexture: ImageTexture
var affinitytexture: ImageTexture
var noiseimage: Image
var noisetexture: ImageTexture

var surfacematerial: ShaderMaterial
var appliedseed: int = -1
var oblique: bool = false       # 斜角视图（正交俯看 + 高度场步进）
var height_max: float = 1.0     # 全图最高高程（级），供斜角射线范围使用


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE  # 成品视图永远只读，滚轮留给 ScrollContainer
	_build_material()
	apply_settings(RenderSettings.new())
	if map == null and get_tree().current_scene == self:
		# 仅独立运行 render_view.tscn 时自动加载预览图；被 Main 实例化时等 main 注入
		# --shot-map=res://... 可临时换一张图做对比截图（只影响独立运行）
		var path: String = PREVIEW_MAP_PATH
		for arg: String in OS.get_cmdline_args():
			if arg.begins_with("--shot-map="):
				path = arg.trim_prefix("--shot-map=")
		var preview: MapData = load(path) as MapData
		if preview != null:
			set_map(preview)
		else:
			push_warning("找不到预览地图: " + path)
	resized.connect(_on_resized)
	if "--oblique" in OS.get_cmdline_args():
		set_oblique(true)
	if "--shot" in OS.get_cmdline_args():
		_capture_and_quit()


## 截图模式（仅命令行带 --shot 时生效，正常使用完全不受影响）：
## 可用 --shot-t=<秒> 指定冻结的水面时间，便于对比不同时刻的波形。
func _capture_and_quit() -> void:
	set_process(false)
	var shot_time: float = 0.0
	for arg: String in OS.get_cmdline_args():
		if arg.begins_with("--shot-t="):
			shot_time = arg.trim_prefix("--shot-t=").to_float()
	time_sec = shot_time
	if surfacematerial != null:
		surfacematerial.set_shader_parameter("u_time", shot_time)
	for i in 8:
		await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	var dir: String = OS.get_environment("TEMP").replace("\\", "/") + "/gridatlas_shots"
	DirAccess.make_dir_recursive_absolute(dir)
	var path: String = dir + "/shot_%.2f.png" % shot_time
	var err: Error = img.save_png(path)
	if err == OK:
		print("[截图] " + path)
	else:
		push_error("截图失败: %s" % error_string(err))
	get_tree().quit()


## 水面动画：只更新时间参数，着色器逐帧重算（纹理内容不变）
func _process(delta: float) -> void:
	time_sec += delta
	if surfacematerial != null:
		surfacematerial.set_shader_parameter("u_time", time_sec)


# ---------- 对外接口 ----------

func set_map(data: MapData) -> void:
	map = data
	# 旧存档（整数高程）在这里也迁移一次，保证独立运行预览与主场景表现一致
	map.ensure_precision()
	_sync_textures()
	print("[渲染] set_map %d×%d" % [map.grid_size.x, map.grid_size.y])


## 注入/更新渲染配置（RenderTool 面板改动后调用；种子变化时重建噪声纹理）
func apply_settings(s: RenderSettings) -> void:
	settings = s
	_bake_color_texture()
	_bake_affinity_texture()
	if s.noise_seed != appliedseed:
		appliedseed = s.noise_seed
		_rebuild_noise()
	for prop: StringName in SCALAR_UNIFORMS:
		surfacematerial.set_shader_parameter("u_" + String(prop), s.get(prop))
	surfacematerial.set_shader_parameter("u_elev_max", height_max)
	_push_view_size()
	# 把同一份配置推给材质参数浮窗（子节点，可能不存在）
	var params: Node = get_node_or_null("MaterialParameters")
	if params != null and params.has_method("set_settings"):
		params.call("set_settings", s)
	queue_redraw()


## 尺寸变化：斜角投影按视口比例取景
func _on_resized() -> void:
	_push_view_size()
	queue_redraw()


func _push_view_size() -> void:
	if surfacematerial != null:
		surfacematerial.set_shader_parameter("u_view_size", size)


## 斜角视图开关（俯视 ↔ 正交斜看）
func set_oblique(on: bool) -> void:
	oblique = on
	if surfacematerial != null:
		surfacematerial.set_shader_parameter("u_oblique", 1.0 if on else 0.0)
	queue_redraw()


## 单格增量更新（编辑即时重渲用）
func sync_cell(cell: Vector2i) -> void:
	if map == null or not map.in_bounds(cell):
		return
	_write_cell(cell.x, cell.y)
	datatexture.update(dataimage)
	elevtexture.update(elevimage)


## 区域批量增量更新（笔刷/矩形填充）：只写区域内像素、只上传笔刷矩形。
## elev_changed=true（地形笔刷动了高度）才重建高程派生数据——陆地/水域/道路
## 笔刷完全不动高程，跳过整图模糊和最大高度扫描，这是大图涂画流畅的关键。
func sync_area(area: Rect2i, elev_changed: bool = false) -> void:
	if map == null or dataimage == null:
		return
	var clipped: Rect2i = area.intersection(Rect2i(Vector2i.ZERO, map.grid_size))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return
	for y in range(clipped.position.y, clipped.end.y):
		for x in range(clipped.position.x, clipped.end.x):
			_write_cell(x, y)
	# ImageTexture 没有 update_region：整图一次上传（128² 仅 64KB，成本在驱动一次调用）
	datatexture.update(dataimage)
	if elev_changed:
		elevtexture.update(elevimage)
		_rebuild_elev_smooth(clipped)
		_refresh_height_max()


func get_content_size() -> Vector2:
	if map != null:
		return Vector2(map.grid_size)
	return Vector2.ZERO


## 轮换入口：big=true 大面板（COVER 撑满滚动区可滚动），false 小面板/独立（CONTAIN 整图居中）
func set_panel_mode(big: bool) -> void:
	big_panel = big
	if big:
		set_anchors_preset(Control.PRESET_TOP_LEFT)
		var scroll: ScrollContainer = get_parent() as ScrollContainer
		var content: Vector2 = get_content_size()
		if scroll != null and content.x > 0.0 and content.y > 0.0:
			var view: Vector2 = scroll.size
			var zoom: float = maxf(view.x / content.x, view.y / content.y)
			custom_minimum_size = content * zoom
			size = content * zoom
	else:
		custom_minimum_size = Vector2.ZERO
		set_anchors_preset(Control.PRESET_FULL_RECT)
	_push_view_size()
	queue_redraw()


## 按当前模式重新适配尺寸（面板尺寸变化时由外部调用）
func refresh() -> void:
	set_panel_mode(big_panel)


# ---------- 内部 ----------

func _build_material() -> void:
	surfacematerial = ShaderMaterial.new()
	surfacematerial.shader = load(SHADER_PATH)
	material = surfacematerial


## 噪声纹理按种子重建（换种子 = 换整张图的颗粒性格）
func _rebuild_noise() -> void:
	if noiseimage == null:
		noiseimage = Image.create(NOISE_SIZE, NOISE_SIZE, false, Image.FORMAT_RGBA8)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = settings.noise_seed
	for y in NOISE_SIZE:
		for x in NOISE_SIZE:
			noiseimage.set_pixel(x, y, Color(rng.randf(), rng.randf(), rng.randf(), rng.randf()))
	if noisetexture == null:
		noisetexture = ImageTexture.create_from_image(noiseimage)
		surfacematerial.set_shader_parameter("u_noise", noisetexture)
	else:
		noisetexture.update(noiseimage)


## 颜色表 13×1：RenderSettings.surface_color() 是唯一取色来源
func _bake_color_texture() -> void:
	var img: Image = Image.create(COLOR_COUNT, 1, false, Image.FORMAT_RGBA8)
	for i in COLOR_COUNT:
		img.set_pixel(i, 0, settings.surface_color(i))
	if colortexture == null:
		colortexture = ImageTexture.create_from_image(img)
		surfacematerial.set_shader_parameter("u_colors", colortexture)
	else:
		colortexture.update(img)


## 亲和度矩阵 8×8（R 通道 0..1）
func _bake_affinity_texture() -> void:
	var img: Image = Image.create(8, 8, false, Image.FORMAT_R8)
	for a in range(1, 9):
		for b in range(1, 9):
			img.set_pixel(a - 1, b - 1, Color(settings.get_affinity(a, b), 0.0, 0.0, 1.0))
	if affinitytexture == null:
		affinitytexture = ImageTexture.create_from_image(img)
		surfacematerial.set_shader_parameter("u_affinity", affinitytexture)
	else:
		affinitytexture.update(img)


## 全量重建数据纹理（set_map / 换图 / 改尺寸时）
func _sync_textures() -> void:
	if map == null or surfacematerial == null:
		return
	var w: int = map.grid_size.x
	var h: int = map.grid_size.y
	if dataimage == null or dataimage.get_width() != w or dataimage.get_height() != h:
		dataimage = Image.create(w, h, false, Image.FORMAT_RGBA8)
		elevimage = Image.create(w, h, false, Image.FORMAT_R8)
		elevsmoothimage = Image.create(w, h, false, Image.FORMAT_R8)
		datatexture = ImageTexture.create_from_image(dataimage)
		elevtexture = ImageTexture.create_from_image(elevimage)
		elevsmoothtexture = ImageTexture.create_from_image(elevsmoothimage)
		surfacematerial.set_shader_parameter("u_data", datatexture)
		surfacematerial.set_shader_parameter("u_elev", elevtexture)
		surfacematerial.set_shader_parameter("u_elev_smooth", elevsmoothtexture)
		surfacematerial.set_shader_parameter("u_map_size", Vector2(map.grid_size))
	for y in h:
		for x in w:
			_write_cell(x, y)
	_rebuild_elev_smooth()
	datatexture.update(dataimage)
	elevtexture.update(elevimage)
	elevsmoothtexture.update(elevsmoothimage)
	_refresh_height_max()
	_push_view_size()
	queue_redraw()


## 平滑高程纹理：可分离 5 点核，把整数台阶摊成缓坡。
## 斜角的射线求交和地面的山体阴影都用它 —— 几何与明暗因此是同一张嘴脸。
## 平滑高程纹理：可分离 5 点核，把整数台阶摊成缓坡。
## 斜角的射线求交和地面的山体阴影都用它 —— 几何与明暗因此是同一张嘴脸。
## area 非空时只重算该区域外扩 2 格（核半径）的部分：笔刷落点几十字，
## 字节流就地更新后整图一次上传（create_from_data 是 C++ 拷贝）。
func _rebuild_elev_smooth(area: Rect2i = Rect2i()) -> void:
	if map == null or elevsmoothimage == null:
		return
	var w: int = map.grid_size.x
	var h: int = map.grid_size.y
	if smoothbytes.size() != w * h:
		smoothbytes = PackedByteArray()
		smoothbytes.resize(w * h)
		area = Rect2i(Vector2i.ZERO, map.grid_size)  # 纹理尺寸变了只能整图重算
	var reg: Rect2i
	if area.size.x <= 0 or area.size.y <= 0:
		reg = Rect2i(Vector2i.ZERO, map.grid_size)
	else:
		reg = area.grow(2).intersection(Rect2i(Vector2i.ZERO, map.grid_size))
	var unit: float = float(map.elev_unit)
	var scale: float = 255.0 / ELEV_SMOOTH_MAX
	# 横向趟只算 区域行±2 × 区域列（纵向趟的输入范围）；结果落在全图坐标系的 tmp 里
	var ty0: int = maxi(reg.position.y - 2, 0)
	var ty1: int = mini(reg.end.y + 2, h)
	var tmp: PackedFloat32Array = PackedFloat32Array()
	tmp.resize(w * h)
	for y in range(ty0, ty1):
		var row: int = y * w
		for x in range(reg.position.x, reg.end.x):
			var acc: float = 0.0
			for k in 5:
				var xx: int = clampi(x + k - 2, 0, w - 1)
				acc += float(map.elevation[row + xx]) * ELEV_BLUR[k]
			tmp[row + x] = acc * 0.0625
	for y in range(reg.position.y, reg.end.y):
		var row: int = y * w
		for x in range(reg.position.x, reg.end.x):
			var acc: float = 0.0
			for k in 5:
				var yy: int = clampi(y + k - 2, 0, h - 1)
				acc += tmp[yy * w + x] * ELEV_BLUR[k]
			var level: float = acc * 0.0625 / unit
			smoothbytes[row + x] = clampi(int(round(level * scale)), 0, 255)
	elevsmoothimage.copy_from(Image.create_from_data(w, h, false, Image.FORMAT_R8, smoothbytes))
	elevsmoothtexture.update(elevsmoothimage)


## 斜角射线的范围要跟着地形最高点走（高程改动后调用）
func _refresh_height_max() -> void:
	if map == null or surfacematerial == null:
		return
	height_max = maxf(map.max_height(), 1.0)
	surfacematerial.set_shader_parameter("u_elev_max", height_max)


func _write_cell(x: int, y: int) -> void:
	var i: int = y * map.grid_size.x + x
	dataimage.set_pixel(x, y, Color8(map.land[i], map.water[i], map.road[i], map.flow[i]))
	elevimage.set_pixel(x, y, Color8(clampi(map.elevation[i], 0, 255), 0, 0, 255))


func _draw() -> void:
	if map == null:
		return
	if big_panel:
		draw_rect(Rect2(Vector2.ZERO, size), Color.WHITE)
		return
	var content: Vector2 = get_content_size()
	if content.x <= 0.0 or content.y <= 0.0:
		return
	var s: float = minf(size.x / content.x, size.y / content.y)
	var drawn: Vector2 = content * s
	draw_rect(Rect2((size - drawn) * 0.5, drawn), Color.WHITE)
