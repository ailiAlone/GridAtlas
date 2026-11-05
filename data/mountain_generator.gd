class_name MountainGenerator
extends RefCounted
## 程序化山体：只输入 MapData.mountain 的连续 footprint + 基础高程，
## 生成山体的高度场（返回所有格子的合成高程，单位=存档单位）。
##
## 规则：
##   - 山体区域外完全保留 map.elevation；
##   - 山体区域内以你画的该格高程为基础，再用距离场 + 脊状噪声生成峰谷；
##     不用最近山脚的高程，所以把山体格的高程改成 1/3，山峰就会变成 max+1 / max+3；
##   - 峰顶 = 该格基础高程 + 山体起伏；没有绝对高度封顶，
##     唯一上限是 8 位高程存储（255 单位 = 63.75 级）；
##   - 同一 footprint 同一结果（固定种子），改 footprint 会重新生成。
##
## 这是渲染/玩法用的派生高度场，不写回 MapData；保存的仍只有基础高程 + 山体遮罩。

const SEED: int = 20261030
const RIM_CELLS: float = 6.0       # 山脚到山顶的展开距离（格）：越大越缓
const AMP_MIN: float = 5.0         # 山体起伏下限（级，不含山脚基础高程）
const AMP_MAX: float = 8.0         # 山体起伏上限（级，不含山脚基础高程）


## 返回长度 = grid_size.x * grid_size.y 的合成高程（存档单位）
static func build_heights(map_data: MapData) -> PackedInt32Array:
	var w: int = map_data.grid_size.x
	var h: int = map_data.grid_size.y
	var n: int = w * h
	var out: PackedInt32Array = map_data.elevation.duplicate()
	if out.size() != n:
		return out
	if map_data.mountain.size() != n:
		return out
	var unit: float = float(maxi(map_data.elev_unit, 1))

	# 从所有非山体格做多源 BFS：只求山体格的 dist=离山脚几格。
	# 基础高程不在这里传播：山峰要加在“你在这格画的高程”上，
	# 而不是最近山脚的高程，否则山脚高程改了、山内画的高程就没作用。
	var dist: PackedInt32Array = PackedInt32Array()
	dist.resize(n)
	dist.fill(-1)
	var queue: PackedInt32Array = PackedInt32Array()
	for i in n:
		if map_data.mountain[i] <= 0:
			dist[i] = 0
			queue.append(i)
	if queue.is_empty():
		return out

	var head: int = 0
	var maxd: int = 0
	while head < queue.size():
		var i: int = queue[head]
		head += 1
		var x: int = i % w
		var y: int = i / w
		var nd: int = dist[i] + 1
		for oy in range(-1, 2):
			for ox in range(-1, 2):
				if ox == 0 and oy == 0:
					continue
				var nx: int = x + ox
				var ny: int = y + oy
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				var ni: int = ny * w + nx
				if dist[ni] >= 0 or map_data.mountain[ni] <= 0:
					continue
				dist[ni] = nd
				maxd = maxi(maxd, nd)
				queue.append(ni)
	if maxd <= 0:
		return out

	var noise_a: FastNoiseLite = _noise(SEED, 0.075, 4)
	var noise_b: FastNoiseLite = _noise(SEED + 97, 0.165, 3)
	for y in h:
		for x in w:
			var i: int = y * w + x
			if map_data.mountain[i] <= 0 or dist[i] <= 0:
				continue
			var d: float = float(dist[i])
			# 指数缓升：山脚坡度平缓，向山脊逐渐收顶；窄山脊也能自然变矮
			var rise: float = 1.0 - exp(-d / RIM_CELLS)
			var ridge_a: float = 1.0 - absf(noise_a.get_noise_2d(float(x), float(y)))
			var ridge_b: float = 1.0 - absf(noise_b.get_noise_2d(float(x), float(y)))
			var shape: float = ridge_a * 0.55 + ridge_b * 0.45
			var relief: float = pow(shape, 0.9)
			var amp: float = clampf(3.5 + float(maxd) * 0.9, AMP_MIN, AMP_MAX)
			var offset: float = amp * rise * (0.30 + 0.70 * relief)
			# 峰顶 = 该格基础高程 + 山体起伏，不做绝对高度封顶：
			# 高程为 1 的地方 → 最高 max+1；高程为 3 的地方 → 最高 max+3。
			# 唯一的硬上限是 8 位高程存储（255 单位 = 63.75 级）。
			var base_level: float = float(map_data.elevation[i]) / unit
			var level: float = base_level + offset
			out[i] = clampi(int(round(level * unit)), 0, 255)
	return out


static func _noise(seed_value: int, frequency: float, octaves: int) -> FastNoiseLite:
	var noise: FastNoiseLite = FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	noise.fractal_octaves = octaves
	return noise
