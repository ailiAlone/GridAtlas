extends Node3D
## 3D 体块渲染：按 GridAtlas 固定相机输出建筑立牌。
## 运行：Godot --path . res://Tools/building_blockout.tscn -- --bb-name=xxx --bb-W=3 --bb-D=2 --bb-H=3.8

var vp: SubViewport
var cam: Camera3D
var house: Node3D
var W := 3.0
var D := 2.0
var H := 3.8
var asset_name := "bb_sample"
var stone_h := 0.40
var wall_h := 1.75
var overhang := 0.35
var wall_col := Color(0.62, 0.40, 0.25)
var roof_col := Color(0.70, 0.43, 0.20)
var stone_col := Color(0.36, 0.34, 0.33)

const OUT_DIR := "res://Assets/Generated/GridAtlas/blockout"

func _ready() -> void:
	_parse_args()
	_build_viewport()
	_build_house()
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_capture()
	get_tree().quit()

func _parse_col(s: String) -> Color:
	var p: PackedStringArray = s.split(",")
	if p.size() == 3:
		return Color(p[0].to_float(), p[1].to_float(), p[2].to_float())
	return Color.WHITE

func _parse_args() -> void:
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if arg.begins_with("--bb-name="): asset_name = arg.trim_prefix("--bb-name=")
		elif arg.begins_with("--bb-W="): W = arg.trim_prefix("--bb-W=").to_float()
		elif arg.begins_with("--bb-D="): D = arg.trim_prefix("--bb-D=").to_float()
		elif arg.begins_with("--bb-H="): H = arg.trim_prefix("--bb-H=").to_float()
		elif arg.begins_with("--bb-wall="): wall_h = arg.trim_prefix("--bb-wall=").to_float()
		elif arg.begins_with("--bb-ov="): overhang = arg.trim_prefix("--bb-ov=").to_float()
		elif arg.begins_with("--bb-wallcol="): wall_col = _parse_col(arg.trim_prefix("--bb-wallcol="))
		elif arg.begins_with("--bb-roofcol="): roof_col = _parse_col(arg.trim_prefix("--bb-roofcol="))
		elif arg.begins_with("--bb-stonecol="): stone_col = _parse_col(arg.trim_prefix("--bb-stonecol="))
	if wall_h <= 0.0:
		wall_h = stone_h + (H - stone_h) * 0.42

func _build_viewport() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.68, 0.62)
	env.ambient_light_energy = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	vp = SubViewport.new()
	vp.size = Vector2i(512, 768)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.own_world_3d = false
	add_child(vp)

	cam = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.near = 0.1
	cam.far = 100.0
	# 目标点：模型中心偏上；模型 Y 轴放大 1/cos(45°) 抵消俯角压缩
	var target := Vector3(0.0, H * 0.52 * 1.41421356, 0.0)
	var dist := 20.0
	var dir := Vector3(0.5, 0.70710678, 0.5)
	vp.add_child(cam)
	cam.position = target + dir * dist
	cam.look_at(target, Vector3.UP)
	cam.size = maxf(H * 2.35, (W + D) * 1.40)

	var light := DirectionalLight3D.new()
	light.light_energy = 1.1
	light.shadow_enabled = false
	light.rotation_degrees = Vector3(-52, -34, 0)
	add_child(light)

func _mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 1.0
	m.metallic = 0.0
	return m

func _mesh(mesh: Mesh, mat: Material, pos: Vector3, rot := Vector3.ZERO) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	house.add_child(mi)

func _build_house() -> void:
	house = Node3D.new()
	house.scale = Vector3(1.0, 1.41421356, 1.0)
	add_child(house)

	var stone := _mat(stone_col)
	var wall := _mat(wall_col)
	var roof := _mat(roof_col)
	var wood := _mat(Color(0.24, 0.13, 0.09))
	var dark := _mat(Color(0.10, 0.08, 0.07))

	# 石基
	var b := BoxMesh.new(); b.size = Vector3(W, stone_h, D)
	_mesh(b, stone, Vector3(0, stone_h * 0.5, 0))
	# 墙体
	var wh := wall_h - stone_h
	var wb := BoxMesh.new(); wb.size = Vector3(W, wh, D)
	_mesh(wb, wall, Vector3(0, stone_h + wh * 0.5, 0))
	# 山墙三棱柱（墙色）
	var rise := H - wall_h
	var gp := PrismMesh.new(); gp.size = Vector3(W, rise, D)
	_mesh(gp, wall, Vector3(0, wall_h, 0))

	# 双坡屋面：两块斜板，带出檐
	var half := W * 0.5 + overhang
	var slope_len := sqrt(half * half + rise * rise)
	var angle := atan2(rise, half)
	var th := 0.12
	for side: float in [-1.0, 1.0]:
		var rb: BoxMesh = BoxMesh.new()
		rb.size = Vector3(slope_len, th, D + overhang * 2.0)
		var cx: float = side * half * 0.5
		var cy: float = wall_h + rise * 0.5
		var rot: Vector3 = Vector3(0, 0, -side * angle)
		_mesh(rb, roof, Vector3(cx, cy, 0), rot)
	# 脊
	var ridge := BoxMesh.new(); ridge.size = Vector3(0.16, 0.16, D + overhang * 2.0)
	_mesh(ridge, roof, Vector3(0, H + 0.02, 0))

	# 门（前山墙 z+）
	var door_h: float = clampf(wall_h * 0.55, 1.0, 1.6)
	var door_w: float = clampf(W * 0.28, 0.7, 1.3)
	var door_x: float = -W * 0.06
	var db := BoxMesh.new(); db.size = Vector3(door_w, door_h, 0.06)
	_mesh(db, wood, Vector3(door_x, stone_h + door_h * 0.5, D * 0.5 + 0.035))
	# 窗（右墙 x+）
	var win_h: float = clampf(wall_h * 0.30, 0.55, 1.0)
	var win_w: float = clampf(D * 0.30, 0.55, 1.0)
	var wnd := BoxMesh.new(); wnd.size = Vector3(0.06, win_h, win_w)
	_mesh(wnd, dark, Vector3(W * 0.5 + 0.035, stone_h + wall_h * 0.58, D * 0.12))
	# 门框
	var fb := BoxMesh.new(); fb.size = Vector3(door_w + 0.16, 0.10, 0.07)
	_mesh(fb, wood, Vector3(door_x, stone_h + door_h + 0.05, D * 0.5 + 0.04))

func _capture() -> void:
	var img: Image = vp.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var path := OUT_DIR + "/" + asset_name + ".png"
	img.save_png(ProjectSettings.globalize_path(path))
	# 锚点：基座 L/F/R（世界坐标 -> 视口像素）
	var s := 1.41421356
	var pts := {
		"left": Vector3(-W * 0.5, 0, D * 0.5),
		"front": Vector3(W * 0.5, 0, D * 0.5),
		"right": Vector3(W * 0.5, 0, -D * 0.5),
		"ridge": Vector3(0, H * s, 0),
	}
	var out := {}
	for k in pts:
		var wp: Vector3 = pts[k]
		wp.y *= s
		var uv: Vector2 = cam.unproject_position(wp)
		out[k] = [uv.x, uv.y]
	out["size"] = [512.0, 768.0]
	out["scale_px_per_unit"] = 768.0 / cam.size
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT_DIR + "/" + asset_name + "_anchors.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	print("[bb] saved ", path, " anchors ", out)
