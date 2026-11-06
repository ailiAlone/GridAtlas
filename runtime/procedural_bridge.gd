extends Node2D
## 程序化桥：按“类型 + 起点/终点格”生成，不贴外部贴图，全部用暖色平涂和手工细节绘制。
## 独木桥/木桥/石桥各自有圆木、木板/栏杆/木桩、石板/石墩/石护栏。
## A* 的 surface_cost 与桥面高度由 BridgesData + MapRuntime 负责，这里只负责外观。

enum Kind { LOG, WOOD, STONE }

const INK: Color = Color("38291c")
const INK_SOFT: Color = Color("4a3524")

const WOOD_D: Color = Color("664a32")
const WOOD_M: Color = Color("85603c")
const WOOD_M2: Color = Color("946c45")
const WOOD_L: Color = Color("a67e50")
const WOOD_H: Color = Color("c19968")

const STONE_D: Color = Color("665545")
const STONE_M: Color = Color("81705a")
const STONE_M2: Color = Color("8f7a61")
const STONE_L: Color = Color("a18c6e")
const STONE_H: Color = Color("b7a17f")
const MOSS: Color = Color("6b7748")
const MOSS_D: Color = Color("55613a")

const EARTH: Color = Color("7c5f3f")
const EARTH_L: Color = Color("98764e")
const EARTH_H: Color = Color("aa875c")
const GRASS: Color = Color("708a49")

const AO: Color = Color(0.10, 0.08, 0.05, 0.15)

var _atlas
var _runtime
var _kind: int = Kind.WOOD
var _a: Vector2 = Vector2.ZERO
var _b: Vector2 = Vector2.ZERO
var _perp: Vector2 = Vector2(0, 1)
var _axis: Vector2 = Vector2(1, 0)
var _deck_z: float = 0.0
var _bank_za: float = 0.0
var _bank_zb: float = 0.0
var _half: float = 0.58
var _rail_side: float = 0.50
var _deck_thick: float = 0.12
var _lift: float = 0.34
var _near_sign: float = 1.0


func setup(atlas, runtime, kind: int, start_cell: Vector2i, end_cell: Vector2i) -> void:
	_atlas = atlas
	_runtime = runtime
	_kind = kind
	# 桥的长轴、跨度由编辑器拖出的两个桥头格直接给出；不再自动找岸。
	_a = Vector2(start_cell) + Vector2(0.5, 0.5)
	_b = Vector2(end_cell) + Vector2(0.5, 0.5)
	_axis = (_b - _a).normalized()
	_perp = Vector2(0.0, 1.0) if absf(_axis.x) > 0.5 else Vector2(1.0, 0.0)
	_bank_za = _bank_z(_a)
	_bank_zb = _bank_z(_b)
	var top_ground: float = maxf(_bank_za, _bank_zb)
	top_ground = maxf(top_ground, _bank_z((_a + _b) * 0.5))
	if _kind == Kind.LOG:
		_lift = 0.36
		_half = 0.34
		_deck_thick = 0.24
	elif _kind == Kind.STONE:
		_lift = 0.60
		_half = 0.72
		_deck_thick = 0.16
		_rail_side = 0.55
	else:
		_lift = 0.68
		_half = 0.58
		_deck_thick = 0.10
		_rail_side = 0.50
	_deck_z = top_ground + _lift
	var mid: Vector2 = (_a + _b) * 0.5
	var plus: Vector2 = _p(mid + _perp * _half, _deck_z)
	var minus: Vector2 = _p(mid - _perp * _half, _deck_z)
	_near_sign = 1.0 if plus.y > minus.y else -1.0
	z_as_relative = true
	z_index = atlas.actor_z_index(mid)
	queue_redraw()


func _bank_z(p: Vector2) -> float:
	return _runtime.terrain_z(Vector2i(floori(p.x), floori(p.y)))


func _p(p: Vector2, z: float) -> Vector2:
	return _atlas.projected_point(p, z)


# ---------- 基础绘制 ----------

func _screen(pts: Array[Vector2], z: float) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	for p: Vector2 in pts:
		out.append(_p(p, z))
	return out


func _poly(pts: Array[Vector2], z: float, color: Color) -> void:
	draw_colored_polygon(_screen(pts, z), color)


func _poly4(p0: Vector2, z0: float, p1: Vector2, z1: float,
		p2: Vector2, z2: float, p3: Vector2, z3: float, color: Color) -> void:
	draw_colored_polygon(PackedVector2Array([
		_p(p0, z0), _p(p1, z1), _p(p2, z2), _p(p3, z3)
	]), color)


func _face(a: Vector2, b: Vector2, z_top: float, z_bot: float, color: Color) -> void:
	_poly4(a, z_top, b, z_top, b, z_bot, a, z_bot, color)


func _line3(a: Vector2, b: Vector2, z: float, color: Color, width: float) -> void:
	draw_line(_p(a, z), _p(b, z), color, width, true)


func _line_v(a: Vector2, z0: float, z1: float, color: Color, width: float) -> void:
	draw_line(_p(a, z0), _p(a, z1), color, width, true)


func _outline_screen(pts: PackedVector2Array, color: Color, width: float, close: bool = true) -> void:
	var arr: PackedVector2Array = pts.duplicate()
	if close:
		arr.append(arr[0])
	draw_polyline(arr, color, width, true)


func _outline3(pts: Array[Vector2], z: float, color: Color, width: float) -> void:
	_outline_screen(_screen(pts, z), color, width, true)


func _ellipse(center: Vector2, z: float, rx: float, ry: float, color: Color) -> void:
	var ctr: Vector2 = _p(center, z)
	var pts: PackedVector2Array = PackedVector2Array()
	for i in 22:
		var ang: float = TAU * float(i) / 22.0
		pts.append(ctr + Vector2(cos(ang) * rx, sin(ang) * ry))
	draw_colored_polygon(pts, color)


func _dot(center: Vector2, z: float, r: float, color: Color) -> void:
	_ellipse(center, z, r, r * 0.72, color)


func _dim(c: Color, f: float) -> Color:
	return Color(c.r * f, c.g * f, c.b * f, c.a)


func _cool(c: Color, amt: float) -> Color:
	return Color(c.r * (1.0 - amt * 0.10), c.g * (1.0 - amt * 0.03),
		c.b * (1.0 + amt * 0.06), c.a)


# ---------- 总入口 ----------

func _draw() -> void:
	var a_l: Vector2 = _a + _perp * _half
	var a_r: Vector2 = _a - _perp * _half
	var b_l: Vector2 = _b + _perp * _half
	var b_r: Vector2 = _b - _perp * _half
	match _kind:
		Kind.LOG:
			_draw_log(a_l, a_r, b_l, b_r)
		Kind.STONE:
			_draw_stone(a_l, a_r, b_l, b_r)
		_:
			_draw_wood(a_l, a_r, b_l, b_r)


# ---------- 木桥 ----------

func _draw_wood(a_l: Vector2, a_r: Vector2, b_l: Vector2, b_r: Vector2) -> void:
	var far_sign: float = -_near_sign
	var far_a: Vector2 = _a + _perp * (_rail_side * far_sign)
	var far_b: Vector2 = _b + _perp * (_rail_side * far_sign)
	_draw_wood_rail(far_a, far_b, _deck_z, true)

	_draw_wood_piers()
	_draw_wood_end(_a, _axis, _bank_za)
	_draw_wood_end(_b, -_axis, _bank_zb)
	_draw_wood_deck(a_l, a_r, b_l, b_r)
	_draw_rail_shadow(far_a, far_b, true)
	_draw_edge_ao(a_l if _near_sign > 0 else a_r, b_l if _near_sign > 0 else b_r)

	var near_a: Vector2 = _a + _perp * (_rail_side * _near_sign)
	var near_b: Vector2 = _b + _perp * (_rail_side * _near_sign)
	_draw_wood_rail(near_a, near_b, _deck_z, false)


func _draw_wood_deck(a_l: Vector2, a_r: Vector2, b_l: Vector2, b_r: Vector2) -> void:
	var z: float = _deck_z
	var thick: float = _deck_thick
	_poly([a_l, b_l, b_r, a_r], z, WOOD_D)

	var planks: int = 6
	var colors: Array[Color] = [WOOD_M, WOOD_M2, WOOD_L, WOOD_L, WOOD_M2, WOOD_M]
	for i in planks:
		var o0: float = -_half + 2.0 * _half * float(i) / float(planks)
		var o1: float = -_half + 2.0 * _half * float(i + 1) / float(planks)
		var p0: Vector2 = _a + _perp * o0
		var q0: Vector2 = _b + _perp * o0
		var p1: Vector2 = _a + _perp * o1
		var q1: Vector2 = _b + _perp * o1
		_poly([p0, q0, q1, p1], z, colors[i])
		# 板缝
		_line3(p1, q1, z, WOOD_D, 0.021)
		# 错位的板端横缝 + 钉子
		var t0: float = 0.26 + 0.17 * float(i % 3)
		var t1: float = 0.68 - 0.11 * float(i % 2)
		for t: float in [t0, t1]:
			var c: Vector2 = _a.lerp(_b, t)
			_line3(c + _perp * o0, c + _perp * o1, z, _dim(colors[i], 0.72), 0.022)
			_dot(c + _perp * (o0 + 0.035), z, 0.017, INK_SOFT)
			_dot(c + _perp * (o1 - 0.035), z, 0.017, INK_SOFT)

	# 磨损：桥面中央两条板稍亮
	var w0: float = -0.16
	var w1: float = 0.16
	_poly([_a + _perp * w0, _b + _perp * w0, _b + _perp * w1, _a + _perp * w1],
		z + 0.001, Color(WOOD_H.r, WOOD_H.g, WOOD_H.b, 0.16))
	_outline3([a_l, b_l, b_r, a_r], z, INK, 0.030)

	var na: Vector2 = a_l if _near_sign > 0 else a_r
	var nb: Vector2 = b_l if _near_sign > 0 else b_r
	# 近侧封边：上方亮口、下面阴影，中间木板端面
	_face(na, nb, z, z - thick, WOOD_D)
	_line3(na, nb, z - 0.006, WOOD_H, 0.024)
	_line3(na, nb, z - thick + 0.012, INK_SOFT, 0.028)
	for i in 9:
		var t: float = 0.04 + 0.115 * float(i)
		var q: Vector2 = _a.lerp(_b, t) + _perp * (_near_sign * _half)
		_line_v(q, z - 0.01, z - thick + 0.02, _dim(WOOD_M, 0.82), 0.018)
	# 封边下的侧梁
	var ba: Vector2 = na + _perp * (_near_sign * 0.035)
	var bb: Vector2 = nb + _perp * (_near_sign * 0.035)
	_draw_rail_beam(ba, bb, z - thick - 0.012, 0.075, 0.045, WOOD_M, WOOD_D, INK_SOFT)
	# 梁头
	for t: float in [0.015, 0.985]:
		var q2: Vector2 = _a.lerp(_b, t) + _perp * (_near_sign * 0.035)
		_face(q2 - _axis * 0.055, q2 + _axis * 0.055,
			z - thick - 0.006, z - thick - 0.115, WOOD_M)
		_outline_screen(PackedVector2Array([
			_p(q2 - _axis * 0.055, z - thick - 0.006),
			_p(q2 + _axis * 0.055, z - thick - 0.006),
			_p(q2 + _axis * 0.055, z - thick - 0.115),
			_p(q2 - _axis * 0.055, z - thick - 0.115),
		]), INK, 0.028)


func _draw_wood_rail(a_side: Vector2, b_side: Vector2, z: float, far: bool) -> void:
	var f: float = 0.80 if far else 1.0
	var c_d: Color = _cool(_dim(WOOD_D, f), 0.4 if far else 0.0)
	var c_m: Color = _cool(_dim(WOOD_L, f), 0.4 if far else 0.0)
	var c_l: Color = _cool(_dim(WOOD_H, f), 0.4 if far else 0.0)
	var c_h: Color = _cool(_dim(WOOD_H, f), 0.4 if far else 0.0)
	var top_z: float = z + 0.56
	var ts: Array[float] = [0.0, 0.34, 0.66, 1.0]
	if not far:
		_draw_rail_beam(a_side, b_side, z + 0.50, 0.062, 0.038, c_h, c_m, c_d)
		_draw_rail_beam(a_side, b_side, z + 0.24, 0.045, 0.028, c_l, c_m, c_d)
	for i in ts.size():
		var t: float = ts[i]
		var p: Vector2 = a_side.lerp(b_side, t)
		_draw_post(p, z, top_z, 0.075, c_m, c_h, c_d)
		if i == 0 or i == ts.size() - 1:
			var inward: Vector2 = _axis * (0.20 if i == 0 else -0.20)
			_draw_brace(p, p + inward, z, 0.24, c_d, c_m)
	if far:
		_draw_rail_beam(a_side, b_side, z + 0.50, 0.062, 0.038, c_h, c_m, c_d)
		_draw_rail_beam(a_side, b_side, z + 0.24, 0.045, 0.028, c_l, c_m, c_d)


func _draw_rail_beam(a_side: Vector2, b_side: Vector2, z_bottom: float,
		height: float, half_t: float, c_top: Color, c_face: Color, c_low: Color) -> void:
	var off_near: Vector2 = _perp * (_near_sign * half_t)
	var off_far: Vector2 = -off_near
	var zt: float = z_bottom + height
	_poly4(a_side + off_far, zt, b_side + off_far, zt,
		b_side + off_near, zt, a_side + off_near, zt, c_top)
	var a_n: Vector2 = a_side + off_near
	var b_n: Vector2 = b_side + off_near
	_face(a_n, b_n, zt, zt - height * 0.66, c_face)
	_line3(a_n, b_n, zt - height * 0.68, c_low, 0.020)
	_outline_screen(PackedVector2Array([
		_p(a_side + off_far, zt), _p(b_side + off_far, zt), _p(b_n, zt),
		_p(b_n, zt - height * 0.66), _p(a_n, zt - height * 0.66), _p(a_n, zt)
	]), INK, 0.028)


func _draw_post(p: Vector2, z0: float, z1: float, w: float,
		c_face: Color, c_top: Color, c_side: Color) -> void:
	var ax: Vector2 = _axis * (w * 0.5)
	var pp: Vector2 = _perp * (w * 0.5)
	_poly4(p - ax - pp, z1, p + ax - pp, z1, p + ax + pp, z1, p - ax + pp, z1, c_top)
	var plus_x: float = _p(p + ax, z1).x
	var minus_x: float = _p(p - ax, z1).x
	if plus_x > minus_x:
		_face(p + ax - pp, p + ax + pp, z1, z0, c_side)
	else:
		_face(p - ax - pp, p - ax + pp, z1, z0, c_side)
	_face(p + pp - ax, p + pp + ax, z1, z0, c_face)
	# 受光边
	draw_line(_p(p + pp - ax, z0), _p(p + pp - ax, z1), c_top, 0.022, true)
	draw_line(_p(p - pp - ax, z0), _p(p - pp - ax, z1), c_top, 0.016, true)
	_outline_screen(PackedVector2Array([
		_p(p + pp - ax, z1), _p(p + pp + ax, z1), _p(p + pp + ax, z0), _p(p + pp - ax, z0)
	]), INK, 0.028)
	var cap_z: float = z1 + 0.030
	_poly4(p - ax - pp, cap_z, p + ax - pp, cap_z,
		p + ax + pp, cap_z, p - ax + pp, cap_z, c_side)
	_face(p + pp - ax, p + pp + ax, cap_z, z1, c_face)
	_outline_screen(PackedVector2Array([
		_p(p + pp - ax, cap_z), _p(p + pp + ax, cap_z),
		_p(p + pp + ax, z1), _p(p + pp - ax, z1)
	]), INK, 0.025)


func _draw_brace(p0: Vector2, p1: Vector2, z: float, h: float,
		c_face: Color, c_top: Color) -> void:
	var near: Vector2 = _perp * (_near_sign * 0.032)
	var height: float = 0.030
	_poly4(p0 + near, z + h, p1 + near, z + 0.02,
		p1 + near, z + 0.02 + height, p0 + near, z + h + height, c_top)
	draw_line(_p(p0, z + h), _p(p1, z + 0.02), c_face, 0.034, true)
	draw_line(_p(p0, z + h + height), _p(p1, z + 0.02 + height), c_face, 0.034, true)
	_outline_screen(PackedVector2Array([
		_p(p0 + near, z + h + height), _p(p1 + near, z + 0.02 + height)
	]), INK, 0.012, false)
	_dot(p0, z + h + height, 0.030, INK_SOFT)
	_dot(p1, z + 0.02 + height, 0.028, INK_SOFT)


func _draw_wood_piers() -> void:
	for i in 2:
		var t: float = 1.0 / 3.0 + float(i) / 3.0
		var center: Vector2 = _a.lerp(_b, t)
		var z_bot: float = maxf(_bank_z(center), 0.0)
		var z_top: float = _deck_z - _deck_thick - 0.010
		var near: float = _near_sign
		var p0: Vector2 = center + _perp * (near * 0.50)
		var p1: Vector2 = center + _perp * (near * 0.235)
		_draw_pile(p0, z_bot, z_top)
		_draw_pile(p1, z_bot, z_top)
		# 斜撑：两根桩之间
		var brace_a: Vector2 = p0
		var brace_b: Vector2 = p1
		draw_line(_p(brace_a, z_bot + 0.16), _p(brace_b, z_bot + 0.30),
			WOOD_D, 0.040, true)
		draw_line(_p(brace_a, z_bot + 0.175), _p(brace_b, z_bot + 0.315),
			WOOD_M2, 0.014, true)
		# 桩顶盖梁（贴着桥底）
		var cap_a: Vector2 = center + _perp * (near * 0.12)
		var cap_b: Vector2 = center + _perp * (near * 0.58)
		_face(cap_a, cap_b, z_top - 0.018, z_top - 0.100, WOOD_M)
		_line3(cap_a, cap_b, z_top - 0.020, WOOD_H, 0.014)
		_line3(cap_a, cap_b, z_top - 0.102, INK_SOFT, 0.016)
		_outline_screen(PackedVector2Array([
			_p(cap_a, z_top - 0.018), _p(cap_b, z_top - 0.018),
			_p(cap_b, z_top - 0.100), _p(cap_a, z_top - 0.100)
		]), INK, 0.026)


func _draw_pile(p: Vector2, z0: float, z1: float) -> void:
	var w: float = 0.085
	var near: Vector2 = _perp * (_near_sign * w * 0.5)
	var side: Vector2 = _axis * (w * 0.5)
	# 近侧面
	_face(p + near - side, p + near + side, z1, z0, WOOD_M)
	# 受光边
	draw_line(_p(p + near - side, z0), _p(p + near - side, z1), WOOD_L, 0.017, true)
	# 朝屏幕右侧的窄侧面
	var plus_x: float = _p(p + side, z1).x
	var minus_x: float = _p(p - side, z1).x
	if plus_x > minus_x:
		_face(p + side - _perp * (w * 0.5), p + side + _perp * (w * 0.5), z1, z0, WOOD_D)
	else:
		_face(p - side - _perp * (w * 0.5), p - side + _perp * (w * 0.5), z1, z0, WOOD_D)
	# 水线湿痕
	_face(p + near - side, p + near + side, z0 + 0.075, z0, Color("4c4a3e"))
	_outline_screen(PackedVector2Array([
		_p(p + near - side, z1), _p(p + near + side, z1),
		_p(p + near + side, z0), _p(p + near - side, z0)
	]), INK, 0.017)


func _draw_wood_end(p: Vector2, axis_in: Vector2, ground_z: float) -> void:
	var width: float = _half * 1.00
	var z_top: float = _deck_z - 0.012
	var steps: int = 4
	var total: float = z_top - ground_z
	var step_h: float = total / float(steps)
	var depth: float = 0.108
	var near: Vector2 = _perp * (_near_sign * width)
	var foot_out: Vector2 = p - axis_in * (depth * float(steps))
	# 最下一级下面的条石基础
	_poly4(foot_out + _perp * width, ground_z + 0.012,
		p + _perp * width, ground_z + 0.020,
		p - _perp * width, ground_z + 0.020,
		foot_out - _perp * width, ground_z + 0.012, STONE_M2)
	_face(foot_out + near, p + near, ground_z + 0.020, ground_z - 0.035, STONE_M)
	_line3(foot_out + near, p + near, ground_z + 0.024, STONE_L, 0.020)
	_outline3([foot_out + _perp * width, p + _perp * width,
		p - _perp * width, foot_out - _perp * width], ground_z + 0.020, INK, 0.022)
	# 木踏步
	for i in steps:
		var z: float = ground_z + step_h * float(i + 1)
		var outer: Vector2 = p - axis_in * (depth * float(steps - i))
		var inner: Vector2 = p - axis_in * (depth * float(steps - i - 1))
		# 近侧板端立面
		_face(outer + near, inner + near, z, z - step_h + 0.008, WOOD_M2)
		# 外侧踢面
		_face(outer + _perp * width, outer - _perp * width, z, z - step_h + 0.008, WOOD_D)
		# 踏面
		_poly4(outer + _perp * width, z, inner + _perp * width, z,
			inner - _perp * width, z, outer - _perp * width, z, WOOD_L)
		_line3(outer + _perp * width, outer - _perp * width, z - 0.004, WOOD_H, 0.024)
		_line3(outer + _perp * width, inner + _perp * width, z - 0.004, WOOD_H, 0.018)
		# 板缝
		_line3(outer.lerp(inner, 0.48) + _perp * width, outer.lerp(inner, 0.48) - _perp * width,
			z - 0.008, WOOD_D, 0.017)
		_outline3([outer + _perp * width, inner + _perp * width,
			inner - _perp * width, outer - _perp * width], z, INK, 0.032)
	# 两侧草与碎石
	for i in 3:
		var t: float = 0.15 + 0.25 * float(i)
		var q: Vector2 = foot_out.lerp(p, t) + _perp * (_near_sign * (width + 0.02))
		_poly([q, q + _axis * 0.05 + _perp * (_near_sign * 0.045),
			q + _axis * 0.09], ground_z + 0.035, GRASS)


func _draw_rail_shadow(a_side: Vector2, b_side: Vector2, far: bool) -> void:
	var off: Vector2 = _perp * (0.10 * _near_sign) + Vector2(0.035, 0.028)
	var strip: PackedVector2Array = PackedVector2Array([
		_p(a_side, _deck_z) + off, _p(b_side, _deck_z) + off,
		_p(b_side + _perp * (0.08 * _near_sign), _deck_z) + off,
		_p(a_side + _perp * (0.08 * _near_sign), _deck_z) + off
	])
	draw_colored_polygon(strip, AO)
	if not far:
		return
	for t: float in [0.0, 0.34, 0.66, 1.0]:
		var p: Vector2 = a_side.lerp(b_side, t)
		var c: Vector2 = _p(p, _deck_z) + off * 0.5
		draw_line(c, c + Vector2(0.10, 0.075), Color(0.08, 0.06, 0.04, 0.16), 0.05, true)


func _draw_edge_ao(na: Vector2, nb: Vector2) -> void:
	var strip: PackedVector2Array = PackedVector2Array([
		_p(na, _deck_z), _p(nb, _deck_z),
		_p(nb - _perp * (_near_sign * 0.075), _deck_z),
		_p(na - _perp * (_near_sign * 0.075), _deck_z)
	])
	draw_colored_polygon(strip, AO)


# ---------- 石桥 ----------

func _draw_stone(a_l: Vector2, a_r: Vector2, b_l: Vector2, b_r: Vector2) -> void:
	var far_sign: float = -_near_sign
	_draw_stone_wall(far_sign, true)
	_draw_stone_piers()
	_draw_stone_end(_a, _axis, _bank_za)
	_draw_stone_end(_b, -_axis, _bank_zb)
	_draw_stone_deck(a_l, a_r, b_l, b_r)
	_draw_wall_shadow(far_sign)
	_draw_stone_wall(_near_sign, false)


## 石桥：石板桥面 + 两根石墩 + 实心石护栏；没有拱。
## 石墩的正面朝向相机，桥面从水面上方跨过，水从石墩之间流过。
func _draw_stone_piers() -> void:
	for i in 2:
		var t: float = 1.0 / 3.0 + float(i) / 3.0
		var center: Vector2 = _a.lerp(_b, t)
		var z_bot: float = maxf(_bank_z(center), 0.0)
		var z_top: float = _deck_z - _deck_thick - 0.005
		var off: Vector2 = _perp * (_near_sign * _half * 0.76)
		var fa: Vector2 = center - _axis * 0.13 + off
		var fb: Vector2 = center + _axis * 0.13 + off
		# 朝屏幕右的窄侧面
		var plus_x: float = _p(center + _axis * 0.13, z_top).x
		var minus_x: float = _p(center - _axis * 0.13, z_top).x
		var side: Vector2 = _axis * (0.13 if plus_x > minus_x else -0.13)
		_face(center + side + off - _perp * (_near_sign * 0.10),
			center + side + off + _perp * (_near_sign * 0.10), z_top, z_bot, STONE_D)
		# 正面砌石
		_face(fa, fb, z_top, z_bot, STONE_M2)
		for c: float in [0.30, 0.56, 0.79]:
			_line3(fa, fb, lerpf(z_bot, z_top, c), STONE_D, 0.018)
		for i2 in 3:
			var zz0: float = lerpf(z_bot, z_top, float(i2) / 3.0)
			var zz1: float = lerpf(z_bot, z_top, float(i2 + 1) / 3.0)
			var xo: float = 0.16 if i2 % 2 == 0 else 0.32
			var vq: Vector2 = fa.lerp(fb, xo)
			_line_v(vq, zz0 + 0.012, zz1 - 0.012, STONE_D, 0.016)
		# 压顶石（贴着桥底）
		var ca: Vector2 = fa - _axis * 0.02
		var cb: Vector2 = fb + _axis * 0.02
		_face(ca, cb, z_top - 0.004, z_top - 0.060, STONE_L)
		_line3(ca, cb, z_top - 0.006, STONE_H, 0.020)
		# 水线、湿痕、苔
		_face(fa, fb, z_bot + 0.075, z_bot, Color("4c4f46"))
		_poly([fa + _axis * 0.02, fa + _axis * 0.18, fa + _axis * 0.18 + _perp * 0.02,
			fa + _axis * 0.02 + _perp * 0.02], z_bot + 0.034, MOSS_D)
		_outline_screen(PackedVector2Array([
			_p(fa, z_top - 0.004), _p(fb, z_top - 0.004),
			_p(fb, z_bot), _p(fa, z_bot)
		]), INK, 0.027)


func _draw_stone_deck(a_l: Vector2, a_r: Vector2, b_l: Vector2, b_r: Vector2) -> void:
	var z: float = _deck_z
	var thick: float = _deck_thick
	_poly([a_l, b_l, b_r, a_r], z, STONE_M)
	# 四块大石板（两排错缝）
	var cuts: Array = [
		[0.0, 0.54, 1.0],
		[0.0, 0.46, 1.0]
	]
	var tones: Array[Color] = [STONE_M, STONE_L, STONE_M2, STONE_H]
	for row in 2:
		var o0: float = -_half + _half * float(row)
		var o1: float = -_half + _half * float(row + 1)
		var list: Array = cuts[row]
		for c in range(list.size() - 1):
			var t0: float = float(list[c])
			var t1: float = float(list[c + 1])
			var p0: Vector2 = _a.lerp(_b, t0) + _perp * o0
			var q0: Vector2 = _a.lerp(_b, t0) + _perp * o1
			var p1: Vector2 = _a.lerp(_b, t1) + _perp * o0
			var q1: Vector2 = _a.lerp(_b, t1) + _perp * o1
			var ci: int = (row * 2 + c) % tones.size()
			_poly([p0, p1, q1, q0], z, tones[ci])
			# 缺角
			if (row + c) % 3 == 1:
				_poly([p0, p0 + _axis * 0.055, p0 + _perp * (0.035 * (1.0 if row == 0 else -1.0))],
					z + 0.001, STONE_D)
			# 一条细裂纹
			if row == 0 and c == 0:
				draw_line(_p(_a.lerp(_b, 0.12) + _perp * (o0 + 0.16), z + 0.002),
					_p(_a.lerp(_b, 0.38) + _perp * (o0 + 0.22), z + 0.002),
					STONE_D, 0.017, true)
	# 石板缝
	for row in 2:
		var o: float = -_half + _half * float(row)
		_line3(_a + _perp * o, _b + _perp * o, z, STONE_D, 0.019)
	_line3(_a, _b, z, STONE_D, 0.014)
	for row in 2:
		var o2: float = -_half + _half * float(row)
		var t: float = float(cuts[row][1])
		draw_line(_p(_a.lerp(_b, t) + _perp * o2, z),
			_p(_a.lerp(_b, t) + _perp * (o2 + _half), z), STONE_D, 0.012, true)
	# 中央磨亮的走道
	_poly([_a + _perp * -0.20, _b + _perp * -0.20, _b + _perp * 0.20, _a + _perp * 0.20],
		z + 0.001, Color(STONE_H.r, STONE_H.g, STONE_H.b, 0.22))
	# 石面麻点与污渍
	for i in 7:
		var t: float = 0.09 + 0.13 * float(i)
		var off: float = -0.38 + 0.13 * float(i % 4)
		_dot(_a.lerp(_b, t) + _perp * off, z + 0.002, 0.016, _dim(STONE_D, 0.9))
	for i: int in 2:
		var t2: float = 0.18 + 0.55 * float(i)
		_poly([_a.lerp(_b, t2) + _perp * (0.30 - 0.18 * float(i)),
			_a.lerp(_b, t2 + 0.08) + _perp * (0.34 - 0.18 * float(i)),
			_a.lerp(_b, t2 + 0.05) + _perp * (0.20 - 0.18 * float(i))],
			z + 0.002, Color(STONE_D.r, STONE_D.g, STONE_D.b, 0.20))
	# 青苔
	for i in 4:
		var t: float = 0.12 + 0.22 * float(i)
		var q: Vector2 = _a.lerp(_b, t) + _perp * (-_half + 0.08)
		_poly([q, q + _axis * 0.10, q + _axis * 0.05 + _perp * 0.07], z + 0.002, MOSS_D)
	for i in 3:
		var t2: float = 0.16 + 0.28 * float(i)
		var q2: Vector2 = _a.lerp(_b, t2) + _perp * (_half - 0.09)
		_poly([q2, q2 + _axis * 0.08, q2 + _axis * 0.05 - _perp * 0.06], z + 0.002,
			Color(MOSS.r, MOSS.g, MOSS.b, 0.55))
	_outline3([a_l, b_l, b_r, a_r], z, INK, 0.032)

	var na: Vector2 = a_l if _near_sign > 0 else a_r
	var nb: Vector2 = b_l if _near_sign > 0 else b_r
	# 近侧封边：两道石带 + 檐口
	_face(na, nb, z, z - thick * 0.5, STONE_M2)
	_face(na, nb, z - thick * 0.5, z - thick, STONE_D)
	_line3(na, nb, z - thick * 0.5, _dim(STONE_D, 0.85), 0.014)
	_line3(na, nb, z - 0.008, STONE_H, 0.018)
	_line3(na, nb, z - 0.020, STONE_D, 0.017)
	_line3(na, nb, z - thick + 0.010, _dim(STONE_D, 0.72), 0.018)
	for t: float in [0.34, 0.67]:
		var q: Vector2 = _a.lerp(_b, t) + _perp * (_near_sign * _half)
		_line_v(q, z - 0.01, z - thick + 0.01, STONE_D, 0.019)
	# 水渍与苔
	for i in 5:
		var t: float = 0.06 + 0.19 * float(i)
		var q2: Vector2 = _a.lerp(_b, t) + _perp * (_near_sign * _half)
		_poly([q2, q2 + _axis * 0.10, q2 + _axis * 0.10 - _perp * (_near_sign * 0.035),
			q2 - _perp * (_near_sign * 0.035)], z - thick + 0.025,
			Color(MOSS_D.r, MOSS_D.g, MOSS_D.b, 0.55))


func _draw_stone_wall(side_sign: float, far: bool) -> void:
	var f: float = 0.80 if far else 1.0
	var c_d: Color = _cool(_dim(STONE_D, f), 0.5 if far else 0.0)
	var c_m: Color = _cool(_dim(STONE_M, f), 0.5 if far else 0.0)
	var c_l: Color = _cool(_dim(STONE_L, f), 0.5 if far else 0.0)
	var c_h: Color = _cool(_dim(STONE_H, f), 0.5 if far else 0.0)
	var center_off: float = _rail_side * side_sign
	var thick: float = 0.140
	var h: float = 0.44
	var z: float = _deck_z
	var a_c: Vector2 = _a + _perp * center_off
	var b_c: Vector2 = _b + _perp * center_off
	var off_n: Vector2 = _perp * (_near_sign * thick * 0.5)

	# 顶面
	_poly([a_c + off_n, b_c + off_n, b_c - off_n, a_c - off_n], z + h, c_h)
	# 朝向相机的一面
	var a_f: Vector2 = a_c + _perp * (_near_sign * thick * 0.5)
	var b_f: Vector2 = b_c + _perp * (_near_sign * thick * 0.5)
	_face(a_f, b_f, z + h, z, c_m)
	# 底部压暗
	_face(a_f, b_f, z + 0.05, z, _dim(c_d, 0.9))
	# 石缝
	for t: float in [0.34, 0.67]:
		var q: Vector2 = a_f.lerp(b_f, t)
		_line_v(q, z + h, z + 0.005, c_d, 0.012)
	_line3(a_f, b_f, z + 0.13, c_d, 0.012)
	# 压顶石
	var cap_h: float = 0.035
	var cap_t: float = 0.012
	var segs: Array[float] = [0.0, 0.36, 0.68, 1.0]
	for i in range(segs.size() - 1):
		var t0: float = segs[i]
		var t1: float = segs[i + 1]
		var p0: Vector2 = _a.lerp(_b, t0) + _perp * (center_off + (thick * 0.5 + cap_t) * _near_sign)
		var p1: Vector2 = _a.lerp(_b, t1) + _perp * (center_off + (thick * 0.5 + cap_t) * _near_sign)
		var q0: Vector2 = _a.lerp(_b, t0) + _perp * (center_off - (thick * 0.5 + cap_t) * _near_sign)
		var q1: Vector2 = _a.lerp(_b, t1) + _perp * (center_off - (thick * 0.5 + cap_t) * _near_sign)
		_poly([p0, p1, q1, q0], z + h + cap_h, c_h if i % 2 == 0 else c_l)
		_face(p0, p1, z + h + cap_h, z + h, c_m)
		_outline_screen(PackedVector2Array([
			_p(p0, z + h + cap_h), _p(p1, z + h + cap_h),
			_p(p1, z + h), _p(p0, z + h)
		]), INK, 0.024)
	# 端柱
	for t: float in [0.0, 1.0]:
		var p: Vector2 = a_c.lerp(b_c, t)
		var w: float = 0.11
		var pp: Vector2 = _perp * (w * 0.5)
		var ax: Vector2 = _axis * (w * 0.5)
		var z1: float = z + h + 0.14
		_poly4(p - ax - pp, z1, p + ax - pp, z1, p + ax + pp, z1, p - ax + pp, z1, c_h)
		_face(p + pp - ax, p + pp + ax, z1, z + 0.02, c_m)
		draw_line(_p(p + pp - ax, z + 0.02), _p(p + pp - ax, z1), c_h, 0.016, true)
		_poly4(p - ax - pp, z1 + 0.028, p + ax - pp, z1 + 0.028,
			p + ax + pp, z1 + 0.028, p - ax + pp, z1 + 0.028, c_l)
		_face(p + pp - ax, p + pp + ax, z1 + 0.028, z1, c_m)
		_outline_screen(PackedVector2Array([
			_p(p + pp - ax, z1 + 0.028), _p(p + pp + ax, z1 + 0.028),
			_p(p + pp + ax, z + 0.02), _p(p + pp - ax, z + 0.02)
		]), INK, 0.025)
	# 苔痕
	for i in 3:
		var t: float = 0.12 + 0.30 * float(i)
		var q: Vector2 = a_f.lerp(b_f, t)
		_poly([q, q + _axis * 0.07, q + _axis * 0.05 - _perp * (_near_sign * 0.03),
			q - _perp * (_near_sign * 0.02)], z + 0.015, MOSS_D)
		for k: int in 2:
			var q2: Vector2 = a_f.lerp(b_f, t + 0.05 * float(k))
			_poly([q2, q2 + _axis * 0.10, q2 + _axis * 0.09 + _perp * (_near_sign * 0.04),
				q2 + _perp * (_near_sign * 0.02)], z + 0.03 + 0.02 * float(k),
				Color(MOSS.r, MOSS.g, MOSS.b, 0.55))


func _draw_stone_end(p: Vector2, axis_in: Vector2, ground_z: float) -> void:
	var width: float = _half * 1.00
	var z_top: float = _deck_z - 0.015
	var steps: int = 6
	var total: float = z_top - ground_z
	var step_h: float = total / float(steps)
	var depth: float = 0.098
	for i in steps:
		var z: float = ground_z + step_h * float(i + 1)
		var outer: Vector2 = p - axis_in * (depth * float(steps - i))
		var inner: Vector2 = p - axis_in * (depth * float(steps - i - 1))
		var near: Vector2 = _perp * (_near_sign * width)
		_poly4(outer + _perp * width, z, inner + _perp * width, z,
			inner - _perp * width, z, outer - _perp * width, z, STONE_L)
		# 外侧踏步立面
		_face(outer + _perp * width, outer - _perp * width, z, z - step_h, STONE_M2)
		# 近侧轮廓立面
		_face(outer + near, inner + near, z, z - step_h, STONE_M)
		_line3(outer + _perp * width, outer - _perp * width, z - 0.004, STONE_H, 0.016)
		_outline3([outer + _perp * width, inner + _perp * width,
			inner - _perp * width, outer - _perp * width], z, INK, 0.026)
		# 台阶端头压暗
		_line3(outer + near, inner + near, z - step_h + 0.01, STONE_D, 0.019)
	# 草与苔
	_poly([p - axis_in * 0.34 + _perp * (_near_sign * width), p - axis_in * 0.24 + _perp * (_near_sign * width),
		p - axis_in * 0.26 + _perp * (_near_sign * (width + 0.05))], ground_z + 0.10, GRASS)


func _draw_wall_shadow(side_sign: float) -> void:
	var center_off: float = _rail_side * side_sign
	var a_c: Vector2 = _a + _perp * center_off + _perp * (_near_sign * 0.0525)
	var b_c: Vector2 = _b + _perp * center_off + _perp * (_near_sign * 0.0525)
	var off: Vector2 = Vector2(0.030, 0.025)
	var pts: PackedVector2Array = PackedVector2Array([
		_p(a_c, _deck_z) + off, _p(b_c, _deck_z) + off,
		_p(b_c + _perp * (_near_sign * 0.16), _deck_z) + off,
		_p(a_c + _perp * (_near_sign * 0.16), _deck_z) + off
	])
	draw_colored_polygon(pts, AO)


# ---------- 独木桥 ----------

func _draw_log(a_l: Vector2, a_r: Vector2, b_l: Vector2, b_r: Vector2) -> void:
	_draw_log_supports()
	var z: float = _deck_z
	var d: float = _deck_thick
	var half_a: float = _half
	var half_b: float = _half * 0.93
	# 顶面：7 条纵向明暗带，中间受光、两边压暗
	var band_cols: Array[Color] = [WOOD_D, WOOD_M, WOOD_M2, WOOD_L, WOOD_M2, WOOD_M, WOOD_D]
	for i in 7:
		var f0: float = -1.0 + 2.0 * float(i) / 7.0
		var f1: float = -1.0 + 2.0 * float(i + 1) / 7.0
		_poly([
			_a + _perp * (half_a * f0), _b + _perp * (half_b * f0),
			_b + _perp * (half_b * f1), _a + _perp * (half_a * f1)
		], z, band_cols[i])
	# 近侧：5 条圆木明暗带，底缘明显内收
	var us: Array[float] = [0.0, 0.20, 0.46, 0.74, 1.0]
	var offs: Array[float] = [1.0, 0.97, 0.86, 0.64, 0.40]
	var cols: Array[Color] = [WOOD_L, WOOD_M2, WOOD_M, WOOD_D, INK_SOFT]
	for i in 4:
		var u0: float = us[i]
		var u1: float = us[i + 1]
		var f0: float = offs[i]
		var f1: float = offs[i + 1]
		var a0: Vector2 = _a + _perp * (_near_sign * half_a * f0)
		var b0: Vector2 = _b + _perp * (_near_sign * half_b * f0)
		var a1: Vector2 = _a + _perp * (_near_sign * half_a * f1)
		var b1: Vector2 = _b + _perp * (_near_sign * half_b * f1)
		_poly4(a0, z - d * u0, b0, z - d * u0, b1, z - d * u1, a1, z - d * u1, cols[i])
	# 受光边
	draw_line(_p(_a + _perp * (_near_sign * half_a * 0.97), z - d * 0.20),
		_p(_b + _perp * (_near_sign * half_b * 0.97), z - d * 0.20), WOOD_H, 0.020, true)
	# 轮廓：近侧与远侧
	var near_bottom_a: Vector2 = _a + _perp * (_near_sign * half_a * 0.40)
	var near_bottom_b: Vector2 = _b + _perp * (_near_sign * half_b * 0.40)
	_outline_screen(PackedVector2Array([
		_p(_a + _perp * (_near_sign * half_a), z), _p(_b + _perp * (_near_sign * half_b), z),
		_p(near_bottom_b, z - d), _p(near_bottom_a, z - d)
	]), INK, 0.026)
	_outline_screen(PackedVector2Array([
		_p(_a - _perp * half_a, z), _p(_b - _perp * half_b, z)
	]), INK_SOFT, 0.018, false)
	# 树皮板：沿木身拉长的碎块，跨顶面和侧面
	for i in 4:
		var t: float = 0.09 + 0.22 * float(i)
		var off: float = sin(float(i) * 2.1) * half_a * 0.48
		var q: Vector2 = _a.lerp(_b, t) + _perp * off
		var ln: float = 0.15 + 0.03 * float(i % 2)
		_poly([q - _axis * ln, q + _perp * 0.05, q + _axis * (ln * 0.55),
			q + _perp * 0.02, q - _axis * (ln * 0.45), q - _perp * 0.035],
			z + 0.001, WOOD_D)
	for i in 3:
		var t: float = 0.20 + 0.24 * float(i)
		var u: float = 0.30 + 0.18 * float(i % 2)
		var q0: Vector2 = _a.lerp(_b, t) + _perp * (_near_sign * half_a * (1.0 - 0.34 * u))
		var q1: Vector2 = _a.lerp(_b, t + 0.10) + _perp * (_near_sign * half_a * (1.0 - 0.34 * u))
		_poly4(q0, z - d * u, q1, z - d * u, q1 + _perp * (_near_sign * 0.02),
			z - d * (u + 0.12), q0 + _perp * (_near_sign * 0.02), z - d * (u + 0.12),
			_dim(WOOD_D, 0.9))
	# 木纹
	for i in 4:
		var t0: float = 0.12 + 0.18 * float(i)
		var off: float = -half_a * 0.52 + half_a * 0.30 * float(i)
		var p0: Vector2 = _a.lerp(_b, t0) + _perp * off
		var p1: Vector2 = _a.lerp(_b, t0 + 0.18) + _perp * (off + half_a * 0.025)
		var p2: Vector2 = _a.lerp(_b, t0 + 0.34) + _perp * (off - half_a * 0.012)
		draw_polyline(PackedVector2Array([_p(p0, z + 0.002), _p(p1, z + 0.002),
			_p(p2, z + 0.002)]), WOOD_M2, 0.018, true)
	# 节疤
	for i in 2:
		var t: float = 0.32 + 0.30 * float(i)
		var q: Vector2 = _a.lerp(_b, t) + _perp * (half_a * 0.20)
		_ellipse(q, z + 0.002, 0.055, 0.032, WOOD_M2)
		_ellipse(q, z + 0.003, 0.038, 0.021, WOOD_D)
		_ellipse(q + Vector2(-0.004, -0.006), z + 0.004, 0.014, 0.008, WOOD_L)
	# 端面
	_draw_log_end(_a, half_a, 1.0, z, d)
	_draw_log_end(_b, half_b, -1.0, z, d)


func _log_ring(center: Vector2, z: float, rh: float, rv: float) -> PackedVector2Array:
	var pts: PackedVector2Array = PackedVector2Array()
	for i in 28:
		var ang: float = TAU * float(i) / 28.0
		pts.append(_p(center + _perp * (cos(ang) * rh), z + sin(ang) * rv))
	return pts


func _draw_log_end(p: Vector2, half: float, _dir: float, z: float, d: float) -> void:
	var zc: float = z - d * 0.55
	var rh: float = half * 0.99
	var rv: float = d * 0.52
	# 树皮外圈
	draw_colored_polygon(_log_ring(p, zc, rh * 1.02, rv * 1.04), WOOD_D)
	draw_colored_polygon(_log_ring(p, zc, rh * 0.91, rv * 0.92), WOOD_M)
	# 切面（亮木）
	draw_colored_polygon(_log_ring(p, zc, rh * 0.84, rv * 0.84), WOOD_L)
	draw_colored_polygon(_log_ring(p, zc, rh * 0.54, rv * 0.54), WOOD_H)
	# 年轮
	for k: float in [0.24, 0.38, 0.52, 0.66, 0.76]:
		var ring: PackedVector2Array = _log_ring(p, zc, rh * k, rv * k)
		ring.append(ring[0])
		draw_polyline(ring, _dim(WOOD_M, 0.72), 0.015, true)
	# 裂纹
	draw_polyline(PackedVector2Array([
		_p(p + _perp * (rh * 0.08), zc + rv * 0.30),
		_p(p + _perp * (rh * 0.30), zc - rv * 0.20),
		_p(p + _perp * (rh * 0.18), zc - rv * 0.72)
	]), INK_SOFT, 0.016, true)
	# 外轮廓
	var outline: PackedVector2Array = _log_ring(p, zc, rh * 1.02, rv * 1.04)
	outline.append(outline[0])
	draw_polyline(outline, INK, 0.030, true)


func _draw_log_supports() -> void:
	for p: Vector2 in [_a, _b]:
		var ground: float = _bank_z(p)
		var width: float = _half * 1.20
		var depth: float = 0.19
		var z_top: float = _deck_z - 0.15
		# 土墩（暗土，不做成浅色平台）
		_poly([
			p - _axis * depth + _perp * width, p + _axis * depth * 0.88 + _perp * (width * 0.96),
			p + _axis * depth + _perp * (width * 0.16), p + _axis * depth * 0.82 - _perp * (width * 0.98),
			p - _axis * depth * 1.04 - _perp * width
		], z_top, EARTH_L)
		var near: Vector2 = _perp * (_near_sign * width)
		_face(p - _axis * depth + near, p + _axis * depth + near, z_top, ground - 0.015, EARTH)
		_line3(p - _axis * depth + near, p + _axis * depth + near, z_top, EARTH_H, 0.013)
		# 两侧石枕
		for side: float in [-1.0, 1.0]:
			var c: Vector2 = p + _perp * (side * width * 0.86) - _axis * 0.02
			var w: float = 0.115
			var dd: float = 0.20
			_poly4(c - _axis * dd + _perp * (side * w), z_top + 0.03,
				c + _axis * dd + _perp * (side * w), z_top + 0.03,
				c + _axis * dd - _perp * (side * w), z_top + 0.03,
				c - _axis * dd - _perp * (side * w), z_top + 0.03, STONE_M)
			_face(c - _axis * dd + _perp * (side * w), c + _axis * dd + _perp * (side * w),
				z_top + 0.03, ground + 0.03, STONE_M2)
			_line3(c - _axis * dd + _perp * (side * w), c + _axis * dd + _perp * (side * w),
				z_top + 0.034, STONE_L, 0.020)
			_line3(c - _axis * dd + _perp * (side * w), c + _axis * dd + _perp * (side * w),
				ground + 0.10, MOSS_D, 0.028)
		# 草丛
		for i in 3:
			var t: float = -0.55 + 0.42 * float(i)
			var q3: Vector2 = p + _perp * (width * t) + _axis * 0.21
			_poly([q3, q3 + _axis * 0.045 + _perp * (_near_sign * 0.05),
				q3 + _axis * 0.10], ground + 0.06, GRASS)



