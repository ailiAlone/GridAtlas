class_name RenderSettings
extends Resource
## RenderSettings —— 渲染层全部开发者参数：RenderTool 面板编辑，GamePreview / 游戏端消费。
## 两张场景想要不同观感（如地面颜色不同）时，各持一份本资源即可，着色器零改动。
##
## 表面编号（颜色纹理与亲和度矩阵共用这套索引）：
##   1草 2沙 3荒 4雪 5沼 6冰 | 7浅水 8深水 | 9土路 10碎石 11石砖 | 12泡沫
## 亲和度（affinity）：0=硬边（清晰界面，如冰↔水），1=完全消融（连续渐变，如浅↔深水）。
## 矩阵只存对称对 Vector2i(小, 大)；未写明的对按默认值处理。

const SURFACE_NAMES: Dictionary = {
	1: "草地", 2: "沙地", 3: "荒地", 4: "雪地", 5: "沼泽", 6: "冰面",
	7: "浅水", 8: "深水",
}
const SURFACE_SHORT: Dictionary = {1: "草", 2: "沙", 3: "荒", 4: "雪", 5: "沼", 6: "冰", 7: "浅", 8: "深"}

# ---------- 颜色（编辑器调色板 GridDefs 不受这里影响，两套各管各的） ----------

@export var land_colors: Dictionary = {
	1: Color(0.42, 0.745, 0.348),
	2: Color(0.91, 0.82, 0.54),
	3: Color(0.58, 0.5, 0.39),
	4: Color(0.93, 0.95, 0.97),
	5: Color(0.33, 0.42, 0.25),
	6: Color(0.66, 0.847, 0.91),
}
@export var water_colors: Dictionary = {
	7: Color(0.43, 0.776, 0.91),
	8: Color(0.26, 0.55, 0.76),   # 比浅水只暗一档：亮度差过大时任何宽渐变都会被看成一条边
}
@export var road_colors: Dictionary = {
	9: Color(0.65, 0.486, 0.32),
	10: Color(0.65, 0.65, 0.65),
	11: Color(0.44, 0.486, 0.522),
}
@export var foam_color: Color = Color(0.93, 0.97, 1.0)
## 山体：坡度与高度驱动的两种覆盖色（不属于地表编号，只进颜色表 13/14）
@export var rock_color: Color = Color(0.58, 0.55, 0.50)
@export var snowcap_color: Color = Color(0.94, 0.96, 0.975)

# ---------- 亲和度矩阵（键：Vector2i(小, 大)） ----------

@export var affinity: Dictionary = {
	Vector2i(1, 5): 0.9,    # 草↔沼泽：干湿植被，软
	Vector2i(2, 3): 0.8,    # 沙↔荒地：同为颗粒质地，软
	Vector2i(4, 6): 0.7,    # 雪↔冰：同为冻结面
	Vector2i(5, 7): 0.5,    # 沼泽↔浅水：湿地过渡
	Vector2i(5, 8): 0.5,    # 沼泽↔深水
	Vector2i(6, 7): 0.1,    # 冰↔水：清晰冰缘（已验收）
	Vector2i(6, 8): 0.1,    # 冰↔深水
	Vector2i(1, 2): 0.35,   # 草↔沙：中偏硬
	Vector2i(7, 8): 1.0,    # 浅↔深：连续深度，完全消融
}
@export var default_affinity: float = 0.35      # 矩阵未定义的 陆↔陆
@export var default_land_water: float = 0.1     # 矩阵未定义的 陆↔水（海岸线硬边）

# ---------- 质感与噪声 ----------

@export var noise_seed: int = 20261026
@export var texture_strength: float = 0.68    # 分材质结构图案的强度（1=原样）
@export var texture_frequency: float = 0.9   # 结构图案的频率倍率
@export var grain: float = 0.015             # 逐像素细颗粒（只做抖动，别大）
@export var biome: float = 0.12              # 全图低频色差（避免大片纯色）
@export var bump: float = 0.55               # 材质微凹凸光度（无高程数据也有立体感）

# ---------- 过渡 ----------

@export var band_hard: float = 0.18     # 亲和度 0 的混合带宽（占格比例）
@export var band_soft: float = 0.85     # 亲和度 1 的混合带宽
@export var edge_jitter: float = 1.6    # 小尺度边界抖动
@export var coast_warp: float = 0.8     # 大尺度边界扭曲（把格子阶梯变成自然曲线）
@export var crease_width: float = 0.14  # 材质交界的折痕宽度
@export var crease_dark: float = 0.14   # 折痕压暗强度

# ---------- 潮汐（深浅交界与"沙地↔浅水"岸线的来回摆动） ----------
# 沙地↔浅水 与 浅↔深水 共用下面两个参数；按需再拆成两组独立参数。

@export var tide_frequency: float = 1.85  # 潮汐频率倍率（1 = 默认速度）
@export var tide_amplitude: float = 1.15  # 潮汐幅度倍率（1 = 默认幅度，0 = 完全静止）

# ---------- 浮雕光照（方向见下方 light_azimuth / light_elevation） ----------

@export var relief: float = 1.2         # 高程起伏带来的明暗强度

# ---------- 水面 ----------

@export var ripple_frequency: float = 0.9
@export var ripple_speed: float = 0.7
@export var ripple_strength: float = 0.11
@export var flow_speed: float = 0.5     # 流向驱动漂移（格/秒）
@export var foam_width: float = 0.89
@export var foam_strength: float = 0.55

# ---------- 道路 ----------

@export var road_width: float = 0.30
@export var road_softness: float = 0.06
@export var road_texture: float = 0.24
@export var road_round: float = 0.26    # 转弯/路角的圆角半径（格）
@export var road_bend: float = 0.14     # 直路蛇行幅度（格，峰-峰的一半）

# ---------- 高程光照 ----------

@export var elevation_bright: float = 0.09
@export var elevation_shadow: float = 0.16
@export var elevation_rim: float = 0.05
@export var elevation_shadow_width: float = 0.30

# ---------- 山体与光照（岩石/雪线阈值、坡面光向） ----------

@export var rock_slope_low: float = 0.52    # 坡度（级/格）开始露岩
@export var rock_slope_high: float = 1.05   # 完全成为岩石的坡度
@export var snow_line_ratio: float = 0.62   # 雪线 = 全图最高高程 × 该比例
@export var snow_line_min: float = 4.0      # 雪线最低高程（级）：低海拔图不积雪
@export var light_azimuth: float = 315.0    # 光的来向（度）：0=北 90=东 180=南 270=西
@export var light_elevation: float = 28.7   # 光的高度角（度）：0=贴地 90=正上方

# ---------- 地形垂直比例（45° 游戏视图 / 斜角渲染共用） ----------

@export var height_scale: float = 2.5   # 每级高程对应的世界高度（格）；越大山越陡


static func is_water(surface: int) -> bool:
	return surface >= 7 and surface <= 8


func get_affinity(a: int, b: int) -> float:
	if a == b:
		return 1.0
	var key: Vector2i = Vector2i(mini(a, b), maxi(a, b))
	if affinity.has(key):
		return affinity[key]
	if is_water(a) != is_water(b):
		return default_land_water
	return default_affinity


func set_affinity(a: int, b: int, value: float) -> void:
	if a == b:
		return
	var key: Vector2i = Vector2i(mini(a, b), maxi(a, b))
	affinity[key] = clampf(value, 0.0, 1.0)


## 颜色纹理取色：索引见文件头注释；0 号空置不使用
func surface_color(index: int) -> Color:
	if index == 14:
		return snowcap_color
	if index == 13:
		return rock_color
	if index == 12:
		return foam_color
	if index >= 9:
		return road_colors.get(index, Color.WHITE)
	if index >= 7:
		return water_colors.get(index, Color.WHITE)
	return land_colors.get(index, Color.WHITE)
