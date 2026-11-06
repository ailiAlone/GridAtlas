extends Control
## 45° 游戏视角预览（编辑器“渲染模式”的大画面）。
##
## 不重写一套相机/投影：直接复用 example/ 里的游戏端组件——
##   GridAtlas（固定 yaw 135° / pitch 45° 的视口）、MapRuntime（地表材质）、
##   actor_card（立牌 + 逐片元山体遮挡）。
## 这里只负责：重建运行时、把编辑画布的中心带过来、从 PropsData 生成立牌、
## 以及预览内的缩放/平移/格线。看到的画面就是正式游戏画面。

const RUNTIME_SCRIPT: GDScript = preload("res://runtime/map_runtime.gd")
const CARD_SCRIPT: GDScript = preload("res://runtime/actor_card.gd")
const BRIDGE_SCRIPT: GDScript = preload("res://runtime/procedural_bridge.gd")
const GridProj = preload("res://data/grid_projection.gd")

const DEFAULT_PPM: float = 42.0

@onready var atlas = $Atlas
@onready var hint: Label = $Hint

var runtime
var props
var bridges
var home_center: Vector2 = Vector2.ZERO
var preview_mode: bool = false   # true=编辑模式左上角的整图概览（只读）

var _panning: bool = false
var _time: float = 0.0
var _height_scale: float = -1.0
var _ground_mask_dirty: bool = false   # 删除树后草垫遮罩需要整张重算，拖拽期间先欠着


func _ready() -> void:
	atlas.yaw = deg_to_rad(135.0)
	atlas.pitch = deg_to_rad(45.0)
	atlas.set_zoom(DEFAULT_PPM)
	_install_style_overlay()
	visibility_changed.connect(_on_visibility_changed)
	resized.connect(refresh_view)
	set_process(visible)


## 共享后处理层：只覆盖 45° 画面，Hint 在其上面。
func _install_style_overlay() -> void:
	var overlay: ColorRect = ColorRect.new()
	overlay.name = "StyleOverlay"
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = load("res://editor/style_overlay.gdshader") as Shader
	overlay.material = mat
	add_child(overlay)
	move_child(overlay, hint.get_index())


func _on_visibility_changed() -> void:
	set_process(visible)
	_panning = false
	if visible:
		refresh_view()


## 编辑模式左上角的小预览：只读、铺满面板、裁剪到面板内。
## 大 45° 画面仍保持滚轮缩放/右键拖动/G/R。
func set_preview_mode(on: bool) -> void:
	preview_mode = on
	mouse_filter = Control.MOUSE_FILTER_IGNORE if on else Control.MOUSE_FILTER_STOP
	clip_contents = on
	_panning = false
	if on:
		hint.visible = false
	else:
		hint.visible = true


## 左上角整图概览：把地图四角按当前 45° 投影投到屏幕，按包围盒算 ppm/center。
## 不能套用着色器里 yaw=0 的整图公式：固定视角是 135°，地图对角线才是屏幕宽度。
## 需要绕过 MIN_ZOOM（64 格约 3–4 px/格；1024 格会低到亚像素，此时隐藏立牌）。
func fit_overview() -> void:
	if runtime == null or atlas == null:
		return
	if size.x < 1.0 or size.y < 1.0:
		return
	var map_size: Vector2i = runtime.map.grid_size
	var w: float = float(map_size.x)
	var h: float = float(map_size.y)
	var fd: Vector2 = atlas.forward_axis()
	var rt: Vector2 = atlas.right_axis()
	var sp: float = sin(atlas.pitch)
	var cp: float = cos(atlas.pitch)
	# 地形最高点 + 最高立牌（屏幕格换算回世界高度）；资源立牌可能比地形高很多
	var zmax: float = maxf((runtime.height_max() - 1.0) * runtime.look.height_scale, 0.4) \
		+ _max_actor_height() / cp + 0.5
	var u_min: float = INF
	var u_max: float = -INF
	var v_min: float = INF
	var v_max: float = -INF
	for corner: Vector2 in [Vector2(0, 0), Vector2(w, 0), Vector2(0, h), Vector2(w, h)]:
		var u: float = corner.dot(rt)
		var v0: float = corner.dot(-fd) * sp
		u_min = minf(u_min, u)
		u_max = maxf(u_max, u)
		v_min = minf(v_min, v0 - zmax * cp)
		v_max = maxf(v_max, v0 + 0.8)   # 图片向下偏移/宽松留边
	var span_u: float = maxf(u_max - u_min, 0.1)
	var span_v: float = maxf(v_max - v_min, 0.1)
	var ppm: float = minf(size.x / span_u, size.y / span_v) * 0.96
	# 屏幕中心对应的地面点：让投影包围盒中心落在视口中心
	var center: Vector2 = rt * ((u_min + u_max) * 0.5) + (-fd) * ((v_min + v_max) * 0.5 / sp)
	atlas.set_camera_unclamped(center, ppm)
	atlas.actors.visible = ppm >= 1.5   # 亚像素立牌只会闪，整图概览时隐藏


## 面板尺寸变化：预览模式重新整图取景；大视图只刷新相机 uniform。
func refresh_view() -> void:
	if atlas == null:
		return
	if preview_mode:
		fit_overview()
	else:
		atlas.refresh_view()


## 重建 45° 视图（切换到渲染模式的大画面，或编辑模式左上角的整图概览）。
## center/ppm 只对大画面有意义；预览模式随后会调用 fit_overview() 重新取景。
## with_gameplay 固定 false：45° 视图只用地表外观，不建 A*。
func setup(map_data: MapData, look: RenderSettings, props_data, bridges_data,
		center: Vector2, ppm: float = 0.0) -> void:
	props = props_data
	bridges = bridges_data
	runtime = RUNTIME_SCRIPT.new()
	runtime.setup(map_data, look, false)
	_height_scale = runtime.look.height_scale
	atlas.setup(runtime)
	atlas.actors.visible = true
	atlas.set_zoom(ppm if ppm > 0.0 else DEFAULT_PPM)
	home_center = center
	atlas.set_center_cell(center)
	_spawn_props()
	_spawn_bridges()
	_update_hint()
	_time = 0.0
	atlas.refresh_view()
	if preview_mode:
		fit_overview.call_deferred()
	print("[预览] 45° 中心 %s ppm %.2f 视图 %s 物件 %d 桥 %d" % [
		str(center), atlas.ppm, str(atlas.size),
		props.count() if props != null else 0, bridges.count() if bridges != null else 0])


## 地形/水域/道路笔刷后的区域增量刷新：只更新受影响的纹理与立牌脚底。
func refresh_terrain(area: Rect2i, elev_changed: bool) -> void:
	if runtime == null:
		return
	runtime.sync_area(area, elev_changed)
	if elev_changed:
		_reposition_props(area)
	if bridges != null and bridges.count() > 0:
		refresh_bridges()
	atlas.refresh_view()


## 脚底格地形色 → 很淡的环境反射色（均值归一化，避免整体压暗）。
func _ground_tint_for(cell: Vector2i) -> Color:
	if runtime == null or runtime.look == null or not runtime.map.in_bounds(cell):
		return Color.WHITE
	var c: Color = Color.WHITE
	var water: int = runtime.map.get_water(cell)
	if water != GridDefs.Water.NONE:
		c = runtime.look.water_colors.get(water, Color.WHITE)
	else:
		c = runtime.look.land_colors.get(runtime.map.get_land(cell), Color.WHITE)
	var mean: float = (c.r + c.g + c.b) / 3.0
	var strength: float = 0.30
	return Color(
		clampf(1.0 + (c.r - mean) * strength, 0.88, 1.12),
		clampf(1.0 + (c.g - mean) * strength, 0.88, 1.12),
		clampf(1.0 + (c.b - mean) * strength, 0.88, 1.12))


## 物件增删/清空后重建全部立牌（数量少，整批重建比增量维护简单可靠）。
func refresh_props() -> void:
	if runtime == null:
		return
	_spawn_props()
	_spawn_bridges()
	_update_hint()


## 渲染配置改动：只换颜色/亲和度/噪声/标量，不重建地图纹理，也不重置相机与动画。
## height_scale 会同时改变地形几何和立牌脚底高度，单独处理。
func apply_look(settings: RenderSettings) -> void:
	if runtime == null or settings == null:
		return
	var old_scale: float = _height_scale
	runtime.apply_look(settings)
	if not is_equal_approx(old_scale, settings.height_scale):
		_height_scale = settings.height_scale
		_rebase_props()
		refresh_bridges()
		if preview_mode:
			fit_overview.call_deferred()


## 地表着色器文件在外部被改过（或刚物化出地图副本）：原地换 shader 引用，
## 材质上的纹理、u_time、相机 uniform 都保留，视图与动画不动。
func reload_shader() -> void:
	if runtime == null:
		return
	runtime.reload_shader()


## 地形垂直比例变了：立牌脚底跟着重新落到新地表，遮挡用的 u_height_scale 同步。
func _rebase_props() -> void:
	for child: Node in atlas.actors.get_children():
		if child.has_method("set_height_scale"):
			child.call("set_height_scale", _height_scale)
	_reposition_props()


## 重新把立牌放到当前地表高度上；area 非空时只处理脚底落在该区域（外扩 3 格）的立牌。
func _reposition_props(area: Rect2i = Rect2i()) -> void:
	if runtime == null:
		return
	var region: Rect2i = area.grow(3) if area.size.x > 0 else Rect2i()
	for child: Node in atlas.actors.get_children():
		if not child.has_method("place"):
			continue
		var pos: Vector2 = Vector2(child.get("base_cell"))
		var ground: Vector2i = Vector2i(floori(pos.x), floori(pos.y))
		if region.size.x > 0 and not region.has_point(ground):
			continue
		child.call("place", pos, runtime.terrain_z(ground))


func current_ppm() -> float:
	return atlas.ppm if atlas != null else DEFAULT_PPM


## 材质浮窗打开时藏起顶部提示，避免文字透过半透明面板叠在一起。
## 左上角小预览始终不显示提示。
func set_hint_visible(on: bool) -> void:
	hint.visible = on and not preview_mode


# ---------- 物件立牌 ----------

## 当前物件里最高的立牌（屏幕格，脚底以上）。整图概览用它预留顶部空间，
## 否则 4~6 格高的资源立牌会被预览面板裁掉。
func _max_actor_height() -> float:
	var tallest: float = 2.0
	if props == null:
		return tallest
	for i in props.count():
		var def: StaticAssetDef = props.asset(props.asset_id_at(i))
		if def == null:
			continue
		var aspect: float = props.variation_aspect_at(i) if props.is_plant(i) else 1.0
		var indiv: float = props.variation_scale_at(i) if props.is_plant(i) else 1.0
		var top: float = def.art_size.y * props.visual_scale_at(i) \
			* props.size_bias_at(i) * indiv / sqrt(aspect) \
			* (1.0 + maxf(def.art_lift.x, def.art_lift.y)) \
			- def.art_offset.y
		tallest = maxf(tallest, top)
	return tallest


func _spawn_props() -> void:
	if runtime != null:
		# 树下草垫遮罩先于立牌重建：树脚落地时地表已经长好同色草
		runtime.set_ground_props(props)
	_ground_mask_dirty = false
	for child: Node in atlas.actors.get_children():
		atlas.actors.remove_child(child)
		child.queue_free()
	if props == null or runtime == null:
		return
	for i in props.count():
		_spawn_prop_card(i)


## 拖动放置时只追加这一张立牌，不重建全部物件节点。
func add_prop_preview(index: int) -> void:
	if runtime == null or props == null:
		return
	if index < 0 or index >= props.count():
		return
	runtime.add_ground_prop(props, index)
	_spawn_prop_card(index)
	_update_hint()


## 右键拖动删除：只移除对应立牌并把后面的索引前移；草垫遮罩留到松手后重算。
func remove_prop_preview(index: int) -> void:
	if runtime == null or props == null or index < 0:
		return
	var found: bool = false
	for child: Node in atlas.actors.get_children():
		if not child.has_meta("prop_index"):
			continue
		var ci: int = int(child.get_meta("prop_index"))
		if ci == index:
			atlas.actors.remove_child(child)
			child.queue_free()
			found = true
		elif ci > index:
			child.set_meta("prop_index", ci - 1)
	if not found:
		refresh_props()
		return
	_ground_mask_dirty = true
	_update_hint()


## 拖拽删除结束后重算一次草垫遮罩（比逐格全量重算少一个数量级）。
func flush_ground_mask() -> void:
	if not _ground_mask_dirty or runtime == null:
		return
	runtime.set_ground_props(props)
	_ground_mask_dirty = false


func _spawn_prop_card(i: int) -> void:
	var fp: Rect2i = props.footprint_at(i)
	var center: Vector2 = Vector2(props.cell_at(i)) + Vector2(fp.size) * 0.5
	var ground: Vector2i = Vector2i(floori(center.x), floori(center.y))
	var z: float = runtime.terrain_z(ground)
	var def: StaticAssetDef = props.asset(props.asset_id_at(i))
	if def == null:
		return
	var bias: float = props.size_bias_at(i)
	var plant: bool = def.category == &"tree"
	var aspect: float = props.variation_aspect_at(i) if plant else 1.0
	var tint: Color = props.variation_tint_at(i) if plant else Color.WHITE
	var crown: Vector2 = props.variation_crown_at(i) if plant else Vector2.ZERO
	var mirror: bool = props.variation_flip_at(i)
	var indiv: float = props.variation_scale_at(i) if plant else 1.0
	var art_size: Vector2 = def.art_size * props.visual_scale_at(i) * bias * indiv
	art_size.x *= sqrt(aspect)
	art_size.y /= sqrt(aspect)
	var vertical: bool = props.rotation_at(i) == 1
	var flip: bool = vertical != mirror
	var card = CARD_SCRIPT.new()
	var tex: Texture2D = StaticAssetStore.texture_for(def)
	if tex != null:
		card.setup_sprite(atlas, art_size, 0.0, tex, def.art_lift, flip)
		var offset: Vector2 = def.art_offset
		if flip:
			offset.x = -offset.x   # 镜像后偏移也绕中心翻到另一侧
		card.art_offset = offset
	else:
		# PNG 缺失时退回程序化建筑占位，至少能看到占地位置
		card.setup(atlas, 4, art_size, 0.0)
	card.set_meta("prop_index", i)
	atlas.actors.add_child(card)
	card.set_ground_tint(_ground_tint_for(ground))
	card.set_soft_grass_base(1.0 if plant else 0.0)
	card.set_variation_tint(tint)
	card.set_crown_variation(crown.x, crown.y)
	card.place(center + props.visual_offset_at(i), z)



func _spawn_bridges() -> void:
	if bridges == null or runtime == null:
		return
	for i in bridges.count():
		var bridge: Node2D = BRIDGE_SCRIPT.new()
		bridge.set_meta("is_bridge", true)
		atlas.actors.add_child(bridge)
		bridge.setup(atlas, runtime, bridges.kind_at(i),
			bridges.start_at(i), bridges.end_at(i))


## 桥增删/地形改动后只重建桥，不重建建筑立牌。
func refresh_bridges() -> void:
	if atlas == null or runtime == null:
		return
	for child: Node in atlas.actors.get_children():
		if child.has_meta("is_bridge"):
			atlas.actors.remove_child(child)
			child.queue_free()
	_spawn_bridges()
	atlas.refresh_view()


func _update_hint() -> void:
	if runtime == null:
		hint.text = "45° 游戏视图"
		return
	var map_name: String = runtime.map.resource_path.get_file()
	if map_name.is_empty():
		map_name = "未保存地图"
	hint.text = "45° 游戏视图 · %s · 物件 %d · 桥 %d · 滚轮缩放 / 右键拖动 / G 格线 / R 回到初始视角" % [
		map_name, props.count() if props != null else 0, bridges.count() if bridges != null else 0]


# ---------- 动画与输入 ----------

func _process(delta: float) -> void:
	if runtime == null or not visible:
		return
	_time += delta
	runtime.material.set_shader_parameter("u_time", _time)


func _gui_input(event: InputEvent) -> void:
	if runtime == null or preview_mode:
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			atlas.zoom_at(mb.position, 1.12)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			atlas.zoom_at(mb.position, 1.0 / 1.12)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE or mb.button_index == MOUSE_BUTTON_RIGHT:
			_panning = mb.pressed
			accept_event()
	elif event is InputEventMouseMotion and _panning:
		atlas.pan((event as InputEventMouseMotion).relative)
		accept_event()


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or runtime == null or preview_mode:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key: InputEventKey = event as InputEventKey
	if key.keycode == KEY_G:
		atlas.set_debug(not atlas.show_debug)
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_R:
		atlas.set_center_cell(home_center)
		get_viewport().set_input_as_handled()
