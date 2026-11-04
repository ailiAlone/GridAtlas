extends Node3D
## 45° 白模实验：按项目固定相机（yaw 135° / pitch 45°）渲染一个 3×3 药铺体块。
## 只作为 Seedream 的结构参考，不是最终资产。

const OUT_DIR := "C:/Users/34935/Documents/GridAtlas/Assets/Generated/GridAtlas/blockout45"
const OUT_PNG := OUT_DIR + "/apoth_45.png"

var _mats: Dictionary = {}


func _ready() -> void:
	get_window().size = Vector2i(1024, 1536)
	_build()
	for i in 4:
		await get_tree().process_frame
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var img: Image = get_viewport().get_texture().get_image()
	var err: Error = img.save_png(OUT_PNG)
	print("[blockout45] %s (%s) %s" % [OUT_PNG, error_string(err), str(img.get_size())])
	get_tree().quit()


func _mat(color: Color, rough: float = 0.95) -> StandardMaterial3D:
	var key: String = str(color) + "/" + str(rough)
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	_mats[key] = m
	return m


func _box(size: Vector3, pos: Vector3, material: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = material
	add_child(mi)
	return mi


func _build() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.965, 0.962, 0.95)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.78, 0.80, 0.84)
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var world := WorldEnvironment.new()
	world.environment = env
	add_child(world)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -38, 0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	add_child(sun)

	# 12×12 地面，1 格 = 1 单位；网格让模型看清 45° 底面
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(12, 12)
	ground.mesh = plane
	var gs := Shader.new()
	gs.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;
void fragment() {
	vec2 uv = UV * 12.0;
	vec2 g = abs(fract(uv) - 0.5) / fwidth(uv);
	float line = min(g.x, g.y);
	float a = 1.0 - smoothstep(0.5, 1.4, line);
	ALBEDO = mix(vec3(0.90, 0.89, 0.86), vec3(0.48, 0.50, 0.53), a * 0.75);
}
"""
	var gm := ShaderMaterial.new()
	gm.shader = gs
	ground.material_override = gm
	add_child(ground)

	# 3×3 蓝色占地
	var foot := MeshInstance3D.new()
	var fp := PlaneMesh.new()
	fp.size = Vector2(3.4, 3.4)
	foot.mesh = fp
	foot.position = Vector3(0, 0.02, 0)
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.15, 0.52, 1.0, 0.34)
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	foot.material_override = fm
	add_child(foot)

	var stone := _mat(Color(0.48, 0.48, 0.46))
	var plaster := _mat(Color(0.80, 0.72, 0.56))
	var timber := _mat(Color(0.28, 0.18, 0.11))
	var roof := _mat(Color(0.24, 0.25, 0.27))
	var door := _mat(Color(0.32, 0.20, 0.12))
	var dark := _mat(Color(0.12, 0.14, 0.17))

	# 石基 + 墙 + 木构
	_box(Vector3(3.0, 0.4, 3.0), Vector3(0, 0.2, 0), stone)
	_box(Vector3(2.7, 1.8, 2.7), Vector3(0, 1.3, 0), plaster)
	_box(Vector3(2.76, 0.14, 2.76), Vector3(0, 1.3, 0), timber)
	for x in [-1.32, 1.32]:
		for z in [-1.32, 1.32]:
			_box(Vector3(0.12, 1.8, 0.12), Vector3(x, 1.3, z), timber)

	# 山墙屋顶（脊沿 Z）
	var pr := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(3.2, 0.8, 3.2)
	prism.left_to_right = 0.5
	pr.mesh = prism
	pr.position = Vector3(0, 2.6, 0)
	pr.material_override = roof
	add_child(pr)

	# 门、窗、门廊、烟囱
	_box(Vector3(0.55, 1.25, 0.10), Vector3(-0.45, 1.05, 1.38), door)
	_box(Vector3(0.72, 0.62, 0.10), Vector3(0.55, 1.55, 1.38), dark)
	_box(Vector3(0.78, 0.08, 0.12), Vector3(0.55, 1.26, 1.39), timber)
	_box(Vector3(0.78, 0.08, 0.12), Vector3(0.55, 1.84, 1.39), timber)
	_box(Vector3(1.9, 0.10, 0.85), Vector3(-0.25, 1.75, 1.75), timber)
	_box(Vector3(0.10, 1.6, 0.10), Vector3(-1.10, 0.8, 2.10), timber)
	_box(Vector3(0.10, 1.6, 0.10), Vector3(0.60, 0.8, 2.10), timber)
	_box(Vector3(0.36, 0.9, 0.36), Vector3(0.92, 3.0, -0.82), stone)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 7.2
	cam.near = 0.1
	cam.far = 100.0
	var target := Vector3(0, 1.5, 0)
	cam.position = target + Vector3(0.70710678, 0.70710678, 0.70710678) * 22.0
	add_child(cam)
	cam.look_at(target, Vector3.UP)
	cam.current = true
