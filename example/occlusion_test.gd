extends Control
## 遮挡验证场景（不依赖存档地图）：
## 在角色与相机之间堆一道高 4 级的山脊，看两件事——
##   1) 角色被山挡住 → 半透明（仍能看见自己）
##   2) 资源立牌被山挡住 → 完全消失（只有较高的立牌顶部会从脊线后露出来）
##
## 运行：godot res://example/occlusion_test.tscn
## 截图：--shot → %TEMP%/gridatlas_shots/occlusion_test.png

const RUNTIME_SCRIPT: GDScript = preload("res://example/map_runtime.gd")
const CARD_SCRIPT: GDScript = preload("res://example/actor_card.gd")
const DemoUnit = preload("res://example/demo_unit.gd")
const OCCLUDER_DEF: String = "res://GridData/static_assets/defs/cv_c01_tavern.tres"
const MAP_SIZE: int = 64
const RIDGE_MIN: int = 66      # 山脊是 x+y = 66..73 的一条斜带（屏幕上是横向的墙）
const RIDGE_MAX: int = 73
const PLAYER_CELL: Vector2i = Vector2i(32, 32)

@onready var atlas = $"Map"
@onready var info: Label = $"HUD/Info"

var runtime
var player
var guide
var occluders: Array = []
var occluder_def: StaticAssetDef
var occluder_tex: Texture2D


func _ready() -> void:
	var map: MapData = MapData.create(Vector2i(MAP_SIZE, MAP_SIZE))
	for y in MAP_SIZE:
		for x in MAP_SIZE:
			var s: int = x + y
			if s >= RIDGE_MIN and s <= RIDGE_MAX:
				map.set_height(Vector2i(x, y), 4.0)
	runtime = RUNTIME_SCRIPT.new()
	runtime.setup(map, RenderSettings.new())
	occluder_def = load(OCCLUDER_DEF) as StaticAssetDef
	if occluder_def != null:
		occluder_tex = StaticAssetStore.texture_for(occluder_def)
	atlas.yaw = deg_to_rad(135.0)
	atlas.pitch = deg_to_rad(45.0)
	atlas.set_zoom(34.0)
	atlas.setup(runtime)
	await get_tree().process_frame

	var ppos: Vector2 = Vector2(PLAYER_CELL) + Vector2(0.5, 0.5)
	var pz: float = runtime.terrain_z(PLAYER_CELL)
	atlas.set_center_cell(ppos + atlas.forward_axis() * 1.5)
	player = _card(0, DemoUnit.SIZE, 0.38, DemoUnit.texture())
	player.place(ppos, pz)
	# 对比：山脊前方（相机侧）再放一个角色，它完全不会被挡
	guide = _card(0, DemoUnit.SIZE, 0.38, DemoUnit.texture())
	guide.place(Vector2(37.5, 37.5), runtime.terrain_z(Vector2i(37, 37)))

	# 资源立牌：脊后 1~4 格、脊顶、脊前
	_occluder(Vector2i(31, 31))   # 脊后 4 格：顶部可能从脊线后露出
	_occluder(Vector2i(34, 31))   # 脊后 1 格：应完全消失
	_occluder(Vector2i(30, 34))   # 脊后 2 格：应完全消失
	_occluder(Vector2i(34, 34))   # 脊顶：正常显示
	_occluder(Vector2i(29, 29))   # 更远的背景立牌
	_occluder(Vector2i(38, 38))   # 脊前：正常显示
	_occluder(Vector2i(40, 35))   # 脊前：正常显示

	info.text = "遮挡验证：山脊（4 级）横在角色与相机之间\n" + \
		"角色半透明（u_fade=0.38）｜资源立牌完全消失（u_fade=0）\n" + \
		"较高的立牌只露出顶部"
	_print_check(ppos, pz)
	if "--shot" in OS.get_cmdline_args():
		for i in 8:
			await get_tree().process_frame
		_save_shot()
		get_tree().quit()


func _card(kind: int, art: Vector2, fade: float, texture: Texture2D = null):
	var card = CARD_SCRIPT.new()
	card.setup(atlas, kind, art, fade, texture)
	atlas.actors.add_child(card)
	return card


func _occluder(cell: Vector2i) -> void:
	if occluder_def == null or occluder_tex == null:
		return
	var card = _card(1, occluder_def.art_size, 0.0, occluder_tex)
	card.place(Vector2(cell) + Vector2(occluder_def.footprint) * 0.5, runtime.terrain_z(cell))
	occluders.append(card)


## CPU 侧复算一遍遮挡，只用于日志对照（真正生效的是立牌着色器）
func _occl(cell: Vector2, world_z: float) -> float:
	var dir: Vector2 = -atlas.forward_axis()
	var tanp: float = tan(atlas.pitch)
	var occ: float = 0.0
	for i in range(1, 11):
		var d: float = float(i) * 0.55
		var p: Vector2 = cell + dir * d
		var ci: Vector2i = Vector2i(floori(p.x), floori(p.y))
		var tz: float = runtime.terrain_z(ci)
		occ = maxf(occ, clampf((tz - (world_z + d * tanp)) / 0.20, 0.0, 1.0))
	return occ


func _print_check(ppos: Vector2, pz: float) -> void:
	var head: float = player.art_size.y / cos(atlas.pitch)
	print("[遮挡] 角色脚 occ=%.2f 头 occ=%.2f（头顶显示 %.0f%%）" % [
		_occl(ppos, pz), _occl(ppos, pz + head),
		lerpf(1.0, 0.38, _occl(ppos, pz + head)) * 100.0])
	for i in occluders.size():
		var card: ColorRect = occluders[i]
		var cell: Vector2i = Vector2i(floori(card.base_cell.x), floori(card.base_cell.y))
		var top: float = card.art_size.y / cos(atlas.pitch)
		print("[遮挡] 立牌%d %s 脚 occ=%.2f 顶 occ=%.2f" % [
			i, str(cell), _occl(card.base_cell, card.base_z),
			_occl(card.base_cell, card.base_z + top)])


func _save_shot() -> void:
	var img: Image = get_viewport().get_texture().get_image()
	var dir: String = OS.get_environment("TEMP").replace("\\", "/") + "/gridatlas_shots"
	DirAccess.make_dir_recursive_absolute(dir)
	var out: String = dir + "/occlusion_test.png"
	if FileAccess.file_exists(out):
		DirAccess.remove_absolute(out)
	var err: Error = img.save_png(out)
	print("[遮挡截图] %s (%s)" % [out, error_string(err)])
