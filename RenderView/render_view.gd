class_name RenderView
extends Control
## RenderView —— 成品渲染视图（纯程序化，无外部素材）。
## MapData 打包成数据纹理（每格一像素），render_view.gdshader 逐像素着色；
## 全部开发者参数集中在 RenderSettings（RenderTool 面板编辑），经 apply_settings() 注入。
## 阶段一（当前）：独立运行自动加载 first.tres 预览；并入主场景后由 main.gd 注入地图与配置。

const NOISE_SIZE: int = 256
const PREVIEW_MAP_PATH: String = "res://GridData/maps/first.tres"
const SHADER_PATH: String = "res://RenderView/render_view.gdshader"
const COLOR_COUNT: int = 13  # 0空 1..6陆 7..8水 9..11路 12泡沫
## RenderSettings 属性名 == uniform 名去掉 u_ 前缀
const SCALAR_UNIFORMS: Array[StringName] = [
	&"texture_strength", &"texture_frequency", &"grain", &"biome", &"bump",
	&"band_hard", &"band_soft", &"edge_jitter", &"coast_warp",
	&"crease_width", &"crease_dark", &"relief",
	&"ripple_frequency", &"ripple_speed", &"ripple_strength", &"flow_speed",
	&"foam_width", &"foam_strength",
	&"road_width", &"road_softness", &"road_texture",
	&"elevation_bright", &"elevation_shadow", &"elevation_rim", &"elevation_shadow_width",
]

var map: MapData
var settings: RenderSettings
var time_sec: float = 0.0
var big_panel: bool = false  # 大面板模式（COVER 撑满滚动区）；false=小面板/独立运行（CONTAIN 居中）

var dataimage: Image    # RGBA8：R=陆地 G=水域 B=道路 A=流向
var elevimage: Image    # R8：高程
var datatexture: ImageTexture
var elevtexture: ImageTexture
var colortexture: ImageTexture
var affinitytexture: ImageTexture
var noiseimage: Image
var noisetexture: ImageTexture

var surfacematerial: ShaderMaterial
var appliedseed: int = -1


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE  # 成品视图永远只读，滚轮留给 ScrollContainer
	_build_material()
	apply_settings(RenderSettings.new())
	if map == null and get_tree().current_scene == self:
		# 仅独立运行 render_view.tscn 时自动加载预览图；被 Main 实例化时等 main 注入
		var preview: MapData = load(PREVIEW_MAP_PATH) as MapData
		if preview != null:
			set_map(preview)
		else:
			push_warning("找不到预览地图: " + PREVIEW_MAP_PATH)
	resized.connect(queue_redraw)
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
	# 把同一份配置推给材质参数浮窗（子节点，可能不存在）
	var params: Node = get_node_or_null("MaterialParameters")
	if params != null and params.has_method("set_settings"):
		params.call("set_settings", s)
	queue_redraw()


## 单格增量更新（编辑即时重渲用）
func sync_cell(cell: Vector2i) -> void:
	if map == null or not map.in_bounds(cell):
		return
	_write_cell(cell.x, cell.y)
	datatexture.update(dataimage)
	elevtexture.update(elevimage)


## 区域批量增量更新（笔刷/矩形填充，一次纹理上传）
func sync_area(area: Rect2i) -> void:
	if map == null or dataimage == null:
		return
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			if map.in_bounds(Vector2i(x, y)):
				_write_cell(x, y)
	datatexture.update(dataimage)
	elevtexture.update(elevimage)


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
		datatexture = ImageTexture.create_from_image(dataimage)
		elevtexture = ImageTexture.create_from_image(elevimage)
		surfacematerial.set_shader_parameter("u_data", datatexture)
		surfacematerial.set_shader_parameter("u_elev", elevtexture)
		surfacematerial.set_shader_parameter("u_map_size", Vector2(map.grid_size))
	for y in h:
		for x in w:
			_write_cell(x, y)
	datatexture.update(dataimage)
	elevtexture.update(elevimage)
	queue_redraw()


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
