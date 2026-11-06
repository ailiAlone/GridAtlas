shader_type canvas_item;
// 地表成品着色器（GamePreview / GamePreviewMini / 游戏端 MapRuntime 共用）。
// 数据每格一像素，逐像素程序化着色。
//
// 机制总览：
//  0) 连续水深场：把水域数据当标量做平滑插值，岸线/浅深分界由【等值线】决定，
//     所以边界会斜穿格子、自然弯曲 —— 这是消除"方格阶梯"的根本手段。
//  1) 陆地类型仍是离散格（分类数据无法插值），只在陆陆交界处做按亲和度的窄过渡。
//     例外是沼泽↔草地：它不是"两种地的分界"，而是"越来越湿"，所以用一张连续沼泽场
//     驱动底色与水洼密度（见 2b），边界因此既不是格子阶梯，也不是一条渐变线。
//  2) 分材质结构图案：硬边碎块/团簇，频率压在 0.3~2 周期/格。
//  3) 微凹凸光照 + 高程浮雕：可调光源方向（默认左上），让表面有立体感。
//  4) 低频生物群系色差：避免大片纯色。
//  5) 交界折痕：一条窄暗线，读起来是物理接缝而不是颜色渐变。
//  6) 细颗粒只做极低幅度抖动，绝不主导画面。
//  7) 斜角视图：同一套地表着色函数，改为从正交斜视方向对高度场做射线步进，
//     取第一次命中的地表再着色 —— 遮挡、坡面、边缘侧壁都是真的。
//  8) 树根草垫：tree 类物件脚底烘一张遮罩，地表先长一圈同色草；立牌着色器
//     再把贴图自带的草垫草色像素淡出，两者共同消化 AI 图里的烘焙草。

uniform sampler2D u_data : filter_nearest, repeat_disable;     // R=陆地 G=水域 B=道路 A=流向
uniform sampler2D u_elev : filter_linear, repeat_disable;      // R=高程（原始单位，1 级 = 4 单位）
uniform sampler2D u_elev_smooth : filter_linear, repeat_disable; // R=平滑高程（0..16 级）
uniform sampler2D u_mountain : filter_linear, repeat_disable;   // R=山体遮罩（0/1，独立于地面）
uniform sampler2D u_prop_ground : filter_linear, repeat_disable; // R=树根草垫遮罩（树木脚底）
uniform sampler2D u_noise : filter_linear, repeat_enable;      // 白噪声，线性采样当值噪声
uniform sampler2D u_colors : filter_nearest, repeat_disable;   // 15×1 颜色表
uniform sampler2D u_affinity : filter_nearest, repeat_disable; // 8×8 亲和度矩阵

uniform vec2 u_map_size = vec2(64.0, 64.0);
uniform float u_time = 0.0;

// ---- 质感 ----
uniform float u_texture_strength = 1.0;
uniform float u_texture_frequency = 0.9;
uniform float u_grain = 0.015;
uniform float u_biome = 0.12;
uniform float u_bump = 0.55;
// ---- 边界 ----
uniform float u_band_hard = 0.18;
uniform float u_band_soft = 0.85;
uniform float u_edge_jitter = 1.6;
uniform float u_coast_warp = 0.8;    // 岸线等值线的弯曲幅度（水深档）
uniform float u_crease_width = 0.14;
uniform float u_crease_dark = 0.30;
// ---- 潮汐 ----
uniform float u_tide_frequency = 1.0;   // 潮汐频率倍率
uniform float u_tide_amplitude = 1.0;   // 潮汐幅度倍率
// ---- 浮雕 ----
uniform float u_relief = 1.2;
// ---- 水面 ----
uniform float u_ripple_frequency = 3.1;
uniform float u_ripple_speed = 0.35;
uniform float u_ripple_strength = 0.28;
uniform float u_flow_speed = 0.5;
uniform float u_foam_width = 0.5;
uniform float u_foam_strength = 0.65;
// ---- 道路 ----
uniform float u_road_width = 0.5;
uniform float u_road_softness = 0.06;
uniform float u_road_texture = 0.24;
uniform float u_road_round = 0.38;   // 转弯/路角的圆角半径（格）
uniform float u_road_bend = 0.28;    // 直路蛇行幅度（格，峰-峰的一半）
uniform float u_road_blend = 1.6;   // 土路/石子路/石砖路交界处的交叉过渡半宽（格）
uniform float u_road_grass = 0.7;   // 路缘草的浓度（0=干净的路边，1=草漫上来）
// ---- 高程 ----
uniform float u_elevation_bright = 0.045;
uniform float u_elevation_shadow = 0.16;
uniform float u_elevation_rim = 0.05;
uniform float u_elevation_shadow_width = 0.30;
// ---- 山体与光照 ----
uniform float u_rock_slope_low = 0.52;    // 坡度（级/格）开始露岩
uniform float u_rock_slope_high = 1.05;   // 完全成为岩石的坡度
uniform float u_snow_line_ratio = 0.62;   // 雪线 = 全图最高高程 × 该比例
uniform float u_snow_line_min = 4.0;      // 雪线最低高程（级）
uniform float u_light_azimuth = 315.0;    // 光的来向（度）：0=北 90=东 180=南 270=西
uniform float u_light_elevation = 28.7;   // 光的高度角（度）：0=贴地 90=正上方
// ---- 斜角视图（正交、从南向北俯看） ----
uniform float u_oblique = 0.0;          // 0 = 俯视，1 = 斜角
uniform float u_pitch = 0.785398;       // 俯仰角（弧度），45°
uniform float u_height_scale = 2.5;     // 每级高程 = 多少世界格高
uniform float u_elev_max = 4.0;         // 全图最高高程（级），GDScript 侧更新
uniform vec2 u_view_size = vec2(1024.0, 1024.0);
// ---- 固定游戏视角（GridAtlas 用；工具预览用默认值，保持原取景） ----
// yaw = 相机所在方位（从目标看向相机）：0=北 90°=东 135°=东南 180°=南（工具默认）
// 视线方向 fd = (-sin yaw, cos yaw)，所以相机在南边时 fd 指向北。
uniform float u_view_yaw = 3.14159265;
uniform vec2 u_view_center = vec2(0.0); // 视口中心对应的地面格（仅 view_cells > 0 时生效）
uniform float u_view_cells = 0.0;       // 视口宽度覆盖多少格；<= 0 表示"整图铺满"（工具预览）
uniform vec3 u_sky_top = vec3(0.40, 0.58, 0.75);
uniform vec3 u_sky_bottom = vec3(0.79, 0.85, 0.88);

// ===== 数据取格 =====

vec4 cell_data(vec2 cell) {
	ivec2 c = clamp(ivec2(cell), ivec2(0), ivec2(u_map_size) - ivec2(1));
	return texelFetch(u_data, c, 0);
}

float cell_land(vec2 cell) {
	float l = cell_data(cell).r * 255.0;
	if (l < 0.5) l = 1.0;      // 旧存档水下格没有陆地层，按草地处理
	if (l > 6.5) l = 6.0;
	return l;
}

// 高程（双线性，逐格原值）：只用于"同一高程"判定等需要格值的地方。
// 光照与斜角几何用下面 elev_field（渲染端烘焙的平滑纹理）。
const float ELEV_UNITS = 4.0;

float elev_smooth(vec2 cf) {
	return texture(u_elev, (cf - vec2(0.5)) / u_map_size).r * 255.0 / ELEV_UNITS;
}

// 渲染端烘焙的平滑高程（5 点可分离核）：整数台阶被摊成缓坡，
// 斜角的射线求交与地面的山体阴影共用同一张，几何与明暗因此一致。
const float ELEV_SMOOTH_MAX = 32.0;

float elev_field(vec2 p) {
	return texture(u_elev_smooth, (p - vec2(0.5)) / u_map_size).r * ELEV_SMOOTH_MAX;
}

float pair_affinity(float a, float b) {
	return texelFetch(u_affinity, ivec2(int(a) - 1, int(b) - 1), 0).r;
}

// 水深通道的双线性采样（格坐标）
float water_at(vec2 p) {
	vec2 ip = floor(p);
	vec2 fp = p - ip;
	vec2 iq = fp * fp * (3.0 - 2.0 * fp);
	vec4 a = cell_data(ip);
	vec4 b = cell_data(ip + vec2(1.0, 0.0));
	vec4 c = cell_data(ip + vec2(0.0, 1.0));
	vec4 d = cell_data(ip + vec2(1.0, 1.0));
	return mix(mix(a.g, b.g, iq.x), mix(c.g, d.g, iq.x), iq.y) * 255.0;
}

// 水深场的宽核平滑：把离散水深摊成连续场，等值线才能画出平滑曲线海岸。
// 半径 1.3 格、σ≈1 格；这是消除"方格阶梯"的决定性一步。
float water_blur(vec2 p) {
	float r = 1.3;
	float s = water_at(p) * 0.24;
	s += (water_at(p + vec2(r, 0.0)) + water_at(p - vec2(r, 0.0))
		+ water_at(p + vec2(0.0, r)) + water_at(p - vec2(0.0, r))) * 0.12;
	s += (water_at(p + vec2(r, r)) + water_at(p + vec2(-r, r))
		+ water_at(p + vec2(r, -r)) + water_at(p + vec2(-r, -r))) * 0.07;
	return s;
}

// 流向场（有方向=1）的宽核平滑：与 water_blur 同核。
// 流动的水不该再有往复摆动，潮汐按这个场削弱；宽核让河口/溪岸的削弱是渐变的。
// Flow.CENTER(5) 表示没有方向，不算流动。
float flow_at(vec2 p) {
	float id = cell_data(floor(p)).a * 255.0;
	return (id > 0.5 && abs(id - 5.0) > 0.5) ? 1.0 : 0.0;
}
float flow_blur(vec2 p) {
	float r = 1.3;
	float s = flow_at(p) * 0.24;
	s += (flow_at(p + vec2(r, 0.0)) + flow_at(p - vec2(r, 0.0))
		+ flow_at(p + vec2(0.0, r)) + flow_at(p - vec2(0.0, r))) * 0.12;
	s += (flow_at(p + vec2(r, r)) + flow_at(p + vec2(-r, r))
		+ flow_at(p + vec2(r, -r)) + flow_at(p + vec2(-r, -r))) * 0.07;
	return s;
}

// 陆地通道的双线性采样（格坐标）
float land_of(vec4 d) {
	float l = d.r * 255.0;
	if (l < 0.5) l = 1.0;      // 旧存档水下格没有陆地层，按草地处理
	if (l > 6.5) l = 6.0;
	return l;
}
float land_at(vec2 p) {
	vec2 ip = floor(p);
	vec2 fp = p - ip;
	vec2 iq = fp * fp * (3.0 - 2.0 * fp);
	vec4 a = cell_data(ip);
	vec4 b = cell_data(ip + vec2(1.0, 0.0));
	vec4 c = cell_data(ip + vec2(0.0, 1.0));
	vec4 d = cell_data(ip + vec2(1.0, 1.0));
	return mix(mix(a.r, b.r, iq.x), mix(c.r, d.r, iq.x), iq.y) * 255.0;
}

// 陆地类型的窄核平滑：半径 0.6 格。只把方格边界揉成曲线，不会吞掉 1 格宽的地带。
float land_blur(vec2 p) {
	float r = 0.6;
	float s = land_at(p) * 0.40;
	s += (land_at(p + vec2(r, 0.0)) + land_at(p - vec2(r, 0.0))
		+ land_at(p + vec2(0.0, r)) + land_at(p - vec2(0.0, r))) * 0.15;
	return s;
}

// 干沙滩指示：该格是沙地且没有水面（1/0）。
// 有水面的格子陆地字段已强制为沙（河床），所以识别"沙滩"必须排除水下沙，
// 否则浅水内部的沙河床会满足潮汐遮罩，水与水之间也会互相摆动。
float beach_ind(vec2 p) {
	vec4 d = cell_data(floor(p));
	float l = d.r * 255.0;
	float sand = step(1.5, l) * step(l, 2.5);
	float wet = step(0.5, d.g * 255.0);
	return sand * (1.0 - wet);
}

// 干沙滩的宽核模糊：与 water_blur 同核，岸线两侧各有约 1 格的过渡带。
float beach_blur(vec2 p) {
	float r = 1.3;
	float s = beach_ind(p) * 0.24;
	s += (beach_ind(p + vec2(r, 0.0)) + beach_ind(p - vec2(r, 0.0))
		+ beach_ind(p + vec2(0.0, r)) + beach_ind(p - vec2(0.0, r))) * 0.12;
	s += (beach_ind(p + vec2(r, r)) + beach_ind(p + vec2(-r, r))
		+ beach_ind(p + vec2(r, -r)) + beach_ind(p + vec2(-r, -r))) * 0.07;
	return s;
}

// 树根草垫遮罩的软采样：掩码按格放大 2~4 倍烘，9 点取样把格子边摊成约 1.5 格的草垫。
// 掩码由 MapRuntime.set_ground_props() 按 tree 类物件生成；没有树时整张为 0。
float prop_ground_at(vec2 p) {
	return texture(u_prop_ground, p / u_map_size).r;
}

float root_field(vec2 p) {
	float s = prop_ground_at(p) * 0.36;
	s += (prop_ground_at(p + vec2(0.55, 0.0)) + prop_ground_at(p - vec2(0.55, 0.0))
		+ prop_ground_at(p + vec2(0.0, 0.55)) + prop_ground_at(p - vec2(0.0, 0.55))) * 0.12;
	s += (prop_ground_at(p + vec2(0.50, 0.50)) + prop_ground_at(p + vec2(-0.50, 0.50))
		+ prop_ground_at(p + vec2(0.50, -0.50)) + prop_ground_at(p + vec2(-0.50, -0.50))) * 0.07;
	return s;
}

// 沼泽指示：该格是不是沼泽（1/0）
float swamp_ind(vec2 p) {
	float l = land_of(cell_data(floor(p)));
	return (l > 4.5 && l < 5.5) ? 1.0 : 0.0;
}
// 沼泽指示的双线性采样：整格跳变会变成"按格子描边"，必须先插值再扩散
float swamp_at(vec2 p) {
	vec2 ip = floor(p);
	vec2 fp = p - ip;
	vec2 iq = fp * fp * (3.0 - 2.0 * fp);
	float a = swamp_ind(ip);
	float b = swamp_ind(ip + vec2(1.0, 0.0));
	float c = swamp_ind(ip + vec2(0.0, 1.0));
	float d = swamp_ind(ip + vec2(1.0, 1.0));
	return mix(mix(a, b, iq.x), mix(c, d, iq.x), iq.y);
}

// 沼泽影响场：半径约 2 格。不是"距离场"，但足够连续 —— 底色的插值和水洼密度的交叉淡入
// 都靠它跨过格子边界，所以分界处不会留下格子形状的台阶。
float swamp_field(vec2 p) {
	float s = swamp_at(p) * 0.30;
	s += (swamp_at(p + vec2(0.9, 0.0)) + swamp_at(p - vec2(0.9, 0.0))
		+ swamp_at(p + vec2(0.0, 0.9)) + swamp_at(p - vec2(0.0, 0.9))) * 0.05;
	s += (swamp_at(p + vec2(0.64, 0.64)) + swamp_at(p + vec2(-0.64, 0.64))
		+ swamp_at(p + vec2(0.64, -0.64)) + swamp_at(p + vec2(-0.64, -0.64))) * 0.05;
	s += (swamp_at(p + vec2(1.9, 0.0)) + swamp_at(p - vec2(1.9, 0.0))
		+ swamp_at(p + vec2(0.0, 1.9)) + swamp_at(p - vec2(0.0, 1.9))) * 0.03;
	s += (swamp_at(p + vec2(1.34, 1.34)) + swamp_at(p + vec2(-1.34, 1.34))
		+ swamp_at(p + vec2(1.34, -1.34)) + swamp_at(p + vec2(-1.34, -1.34))) * 0.03;
	return s;
}

vec3 table_color(int index) {
	return texelFetch(u_colors, ivec2(index, 0), 0).rgb;
}

vec2 flow_vec(float v) {
	if (v < 0.5) return vec2(0.25, 0.0);
	else if (v < 1.5) return vec2(-1.0, -1.0);
	else if (v < 2.5) return vec2(0.0, -1.0);
	else if (v < 3.5) return vec2(1.0, -1.0);
	else if (v < 4.5) return vec2(-1.0, 0.0);
	else if (v < 5.5) return vec2(0.0, 0.0);
	else if (v < 6.5) return vec2(1.0, 0.0);
	else if (v < 7.5) return vec2(-1.0, 1.0);
	else if (v < 8.5) return vec2(0.0, 1.0);
	return vec2(1.0, 1.0);
}

// ===== 噪声 =====
// 注意：texture() 的采样坐标是【归一化 UV】，噪声纹理 256×256。
// p 以"格"为单位传入，除以 256 后 1 个噪声特征约等于 1 格。
// （若直接把格子坐标当 UV 传，每个像素会取到随机纹素 → 整幅画面变成电视雪花。）
const float NOISE_TEXELS = 256.0;

float vnoise(vec2 p) {
	return texture(u_noise, p / NOISE_TEXELS).r;
}

float fbm(vec2 p) {
	return vnoise(p) * 0.5 + vnoise(p * 2.03 + vec2(0.33, 0.71)) * 0.3 + vnoise(p * 4.13 + vec2(0.71, 0.33)) * 0.2;
}

// 整数格哈希：给每块石头/砖一个稳定的随机数（不依赖噪声纹理，方便按块索引取）
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// 像素草丛：0.17 格一个草窝，每窝三根短叶，3×3 邻域防止叶尖在格边被截断。
// 位置在 tuft 格内大幅抖动，密度由两层低频场控制成簇/留白，避免草窝排成整齐行列。
// 叶的方向不是地图 y，而是【屏幕上竖直】的方向（相机 forward 在地面的投影）——
// 地图 y 在 45° 下是斜的，直接沿 y 画会变成一片斜向排线。
// 返回 x=叶身，y=叶根暗边，z=每根草的颜色随机值，w=叶尖高度比（0=根，1=尖）。
vec4 grass_tuft(vec2 gp, float clump) {
	const float TUFT = 0.17;   // 草窝间距（格）
	vec2 up_dir = vec2(-sin(u_view_yaw), cos(u_view_yaw));   // 屏幕向上的地面方向
	vec2 side_dir = vec2(-up_dir.y, up_dir.x);
	vec2 tp = gp / TUFT;
	vec2 ti = floor(tp);
	float blade = 0.0;
	float edge = 0.0;
	float tone = 0.0;
	float tip = 0.0;
	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
			vec2 o = vec2(float(ox), float(oy));
			vec2 rnd = vec2(hash21(ti + o), hash21(ti + o + vec2(17.1, 4.7)));
			// 位置/大小用另一组哈希：与密度分开，避免"哪里密、哪里就偏左/偏高"的隐藏相关
			vec2 prnd = vec2(hash21(ti + o + vec2(31.7, 9.2)),
				hash21(ti + o + vec2(5.3, 44.1)));
			// 草窝密度：低频 clump 控制成片/稀疏；阈值接近二值，密处成片、疏处干脆没有。
			float keep = step(0.72, rnd.x * 0.30 + clump * 0.95);
			vec2 jitter = prnd - 0.5;
			vec2 base = (ti + o + 0.5 + jitter * 0.96) * TUFT;
			vec2 rel = gp - base;
			float u = dot(rel, side_dir);
			float v = dot(rel, up_dir);
			float lean = (prnd.y - 0.5) * 0.85;
			float size = 0.72 + 0.55 * fract(prnd.x * 13.7 + prnd.y * 7.1);
			// 第一根：较高，略倾斜；叶尖收窄
			float h1 = (0.09 + 0.08 * prnd.y) * size;
			float x1 = u - v * lean;
			float w1 = mix(0.026, 0.009, clamp(v / h1, 0.0, 1.0)) * size;
			float b1 = keep * (1.0 - smoothstep(w1 - 0.005, w1 + 0.004, abs(x1)))
				* step(0.0, v) * (1.0 - smoothstep(h1, h1 + 0.024, v));
			if (b1 > blade) {
				blade = b1;
				tone = prnd.x;
				tip = clamp(v / h1, 0.0, 1.0);
			}
			// 第二根：矮一些，偏到旁边，草窝才像一撮而不是一排
			float h2 = (0.05 + 0.06 * prnd.x) * size;
			float x2 = u - 0.024 * size - v * lean * 0.6;
			float w2 = mix(0.021, 0.008, clamp(v / h2, 0.0, 1.0)) * size;
			float b2 = keep * (1.0 - smoothstep(w2 - 0.004, w2 + 0.004, abs(x2)))
				* step(0.0, v) * (1.0 - smoothstep(h2, h2 + 0.024, v));
			if (b2 > blade) {
				blade = b2;
				tone = fract(prnd.y + 0.37);
				tip = clamp(v / h2, 0.0, 1.0);
			}
			// 第三根：只在部分草窝里出现，密处成撮、疏处仍是一两根
			float h3 = (0.035 + 0.05 * fract(prnd.x * 7.0)) * size;
			float x3 = u + 0.022 * size + v * lean * 0.5;
			float w3 = mix(0.017, 0.007, clamp(v / h3, 0.0, 1.0)) * size;
			float b3 = step(0.40, prnd.x) * keep
				* (1.0 - smoothstep(w3 - 0.004, w3 + 0.004, abs(x3)))
				* step(0.0, v) * (1.0 - smoothstep(h3, h3 + 0.024, v));
			if (b3 > blade) {
				blade = b3;
				tone = fract(prnd.x + 0.71);
				tip = clamp(v / h3, 0.0, 1.0);
			}
			// 叶根一团暗色：树贴图里草叶是靠根部/侧面的暗边读出来的
			float sx = 1.0 - smoothstep(0.030, 0.050, abs(u));
			float sy = step(-0.018, v) * (1.0 - smoothstep(0.045, 0.075, v));
			edge = max(edge, keep * sx * sy * (1.0 - max(b1, b2)));
		}
	}
	return vec4(blade, edge, tone, tip);
}

// 光照用高度：平滑高程 + 一层很轻的低频起伏（约 0.14 格）。
// 起伏让平直的台阶轮廓自然弯曲，明暗带才不会读成两条云影。
float elev_relief(vec2 p) {
	return elev_field(p) + (fbm(p * 0.45 + vec2(7.3, 2.1)) - 0.5) * 0.14;
}

// ===== 分材质结构图案 =====
// 用硬边阈值造碎块/团簇，而不是大范围软渐变；频率压在 0.3~2 周期/格。
float material_pattern(vec2 p, float id) {
	float n1 = fbm(p * 0.40);                            // 大块（约 2.5 格周期）
	float n2 = vnoise(p * 1.05 + vec2(3.7, 1.9));        // 中块（约 1 格周期）
	if (id < 1.5) {
		// 草地底色：只留很轻的草簇明暗。大片平滑的"水波"交给贴图立牌会很出戏，
		// 细碎的像素草叶由 1b 段负责，这里不做长条/羽状图案。
		float clump = vnoise(p * 1.40 + vec2(5.1, 2.3));
		float fine = vnoise(p * 4.60 + vec2(1.7, 8.4));
		return 0.97 + 0.035 * (clump - 0.5) + 0.025 * (fine - 0.5);
	}
	if (id < 2.5) {
		// 沙地：细沙粒 + 柔和沙丘起伏。
		// 不用任何方向性条状结构（脊线/车辙式拉伸）—— 那和草叶是同一类笔触，
		// 一眼就读成"换了颜色的草地"。沙靠的是各向同性的颗粒感和很软的大块明暗。
		float grain = vnoise(p * 17.0) * 0.5 + vnoise(p * 9.0 + vec2(3.7, 8.9)) * 0.5;   // 沙粒（约 1px/粒）
		float clump = vnoise(p * 4.2 + vec2(5.5, 1.3));                                   // 颗粒团（约 1/4 格）
		float dune = fbm(p * 0.40 + vec2(2.4, 8.1));                                      // 沙丘起伏（3~5 格）
		// 沙粒不是平滑噪声：阈值锐化出稀疏的亮点与暗坑，才有松散颗粒感
		float speck = smoothstep(0.58, 0.72, vnoise(p * 14.0 + vec2(1.7, 9.3)));
		float spark = smoothstep(0.60, 0.74, vnoise(p * 23.0 + vec2(6.2, 2.8)));
		float pit = smoothstep(0.64, 0.78, vnoise(p * 18.0 + vec2(9.1, 4.4)));
		return 0.955 + 0.060 * speck + 0.045 * spark - 0.040 * pit
			+ 0.030 * (clump - 0.5) + 0.045 * (dune - 0.5) + 0.020 * (grain - 0.5);
	}
	if (id < 3.5) {
		// 荒地：大块板 + 深色裂缝
		float plate = smoothstep(0.42, 0.58, n1);
		float seam = 1.0 - smoothstep(0.0, 0.05, abs(n2 - 0.5));
		return 0.92 + 0.12 * plate - 0.08 * seam;
	}
	if (id < 4.5) {
		// 雪地：柔和起伏
		float drift = smoothstep(0.45, 0.65, n1);
		return 1.0 + 0.04 * (drift - 0.5) + 0.015 * (n2 - 0.5);
	}
	if (id < 5.5) {
		// 沼泽陆地部分：苔藓团簇（亮）与泥炭（暗）交错
		float moss = smoothstep(0.46, 0.58, n1);
		float peat = smoothstep(0.42, 0.52, n2);
		return 0.84 + 0.13 * moss + 0.08 * peat;
	}
	if (id < 6.5) {
		// 冰面：大块球面 + 细裂纹
		float plate = smoothstep(0.44, 0.54, n1);
		float crack = 1.0 - smoothstep(0.0, 0.03, abs(n2 - 0.5));
		return 0.975 + 0.06 * plate + 0.10 * crack;
	}
	return 1.0;
}

// 点到轴对齐矩形的有符号距离（矩形：中心 c、半边长 0.5）
float rect_dist(vec2 p, vec2 c) {
	vec2 q = abs(p - c) - vec2(0.5);
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// 道路区域的距离场（3×3 邻域所有道路格的并集）：d0 < 0 在路内、> 0 在路外。
// 关键点是这个场在任何格子上都能求值（草格也算），路缘因此可以越过格界，
// 而不是像"每格画自己那一块"那样被格界裁成直线。
// 顺带记录最近道路格（取路型用）与最近的另一种路型（路型过渡用）。
struct RoadField {
	float d0;     // 到道路区域边界的距离（负 = 路内）
	float id0;    // 最近道路格的路型
	vec2 cell0;
	float d0c;    // 到最近"同型格"的矩形距离（路型过渡用）
	float d1;     // 到最近"另一种路型格"的矩形距离
	float id1;
	vec2 cell1;
};

// 线段距离（轴对齐，用作道路边界）
float seg_dist(vec2 p, vec2 a, vec2 b) {
	vec2 ab = b - a;
	vec2 ap = p - a;
	float t = clamp(dot(ap, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
	return length(ap - ab * t);
}

// 3×3 路型表：[col][row] = 格 (dc.x + col - 1, dc.y + row - 1)
mat3 road_ids_3x3(vec2 dc) {
	mat3 m;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			m[i + 1][j + 1] = floor(cell_data(dc + vec2(float(i), float(j))).b * 255.0 + 0.5);
		}
	}
	return m;
}

float road_id_at(mat3 ids, int i, int j) {
	if (i < -1 || i > 1 || j < -1 || j > 1) { return 0.0; }
	return ids[i + 1][j + 1];
}

// 到道路区域边界的有符号距离（负 = 路内）。
// 边界就是"路格与非路格共享的那些格边"，直接量点到这些线段的距离：
// 只对矩形做 min 会在相邻格的公共边上退化成 0（内部接缝），每格都塌一次；
// 量边界线段则处处精确，路宽、直段、拐角都不会有 1 格周期的串珠。
float road_signed_dist(vec2 p, vec2 dc, mat3 ids) {
	float best = 64.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			if (ids[i + 1][j + 1] < 0.5) { continue; }
			vec2 c = dc + vec2(float(i), float(j));
			if (road_id_at(ids, i - 1, j) < 0.5)
				best = min(best, seg_dist(p, vec2(c.x, c.y), vec2(c.x, c.y + 1.0)));
			if (road_id_at(ids, i + 1, j) < 0.5)
				best = min(best, seg_dist(p, vec2(c.x + 1.0, c.y), vec2(c.x + 1.0, c.y + 1.0)));
			if (road_id_at(ids, i, j - 1) < 0.5)
				best = min(best, seg_dist(p, vec2(c.x, c.y), vec2(c.x + 1.0, c.y)));
			if (road_id_at(ids, i, j + 1) < 0.5)
				best = min(best, seg_dist(p, vec2(c.x, c.y + 1.0), vec2(c.x + 1.0, c.y + 1.0)));
		}
	}
	best = min(best, 2.0);
	float inside = floor(cell_data(floor(p)).b * 255.0 + 0.5);
	return inside > 0.5 ? -best : best;
}

RoadField road_field(vec2 p, vec2 dc, mat3 ids) {
	RoadField f;
	f.d0 = 0.0; f.id0 = 0.0; f.cell0 = dc; f.d0c = 64.0;
	f.d1 = 64.0; f.id1 = 0.0; f.cell1 = dc;
	float drawn = 64.0;   // 到最近道路格的距离（选 id/格用）
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			float id = ids[i + 1][j + 1];
			if (id < 0.5) { continue; }
			vec2 c = dc + vec2(float(i), float(j));
			float d = rect_dist(p, c + vec2(0.5));
			if (d < drawn) {
				// 被顶替的最近格若路型不同，降级成路型过渡的候选
				if (f.id0 > 0.5 && abs(f.id0 - id) > 0.5 && drawn < f.d1) {
					f.d1 = drawn; f.id1 = f.id0; f.cell1 = f.cell0;
				}
				drawn = d; f.id0 = id; f.cell0 = c;
			} else if (abs(id - f.id0) > 0.5 && d < f.d1) {
				f.d1 = d; f.id1 = id; f.cell1 = c;
			}
		}
	}
	f.d0c = drawn;
	f.d0 = road_signed_dist(p, dc, ids);
	return f;
}

// 道路蛇行：低频域扭曲，整条路（直段与弯道一起）缓慢摆动。
// 与"给距离值加噪声"不同，它改的是采样位置 —— 边线的位置和走向都会变，
// 长直段才会真的拐出 S 形，而不是一条宽度在抖的直线。
vec2 road_warp(vec2 cf) {
	vec2 w = (vec2(fbm(cf * 0.075 + vec2(1.7, 9.2)), fbm(cf * 0.075 + vec2(7.4, 3.1))) - 0.5) * 1.30
		+ (vec2(fbm(cf * 0.210 + vec2(4.8, 2.6)), fbm(cf * 0.210 + vec2(11.3, 6.7))) - 0.5) * 0.70;
	return w * u_road_bend;
}

// 路缘噪声：多个尺度的分形起伏 + 成簇的草啃缺口。
// 只有慢波会读成"一条被柔化的直线"，必须带上 1 格以下的高频毛边，
// 边界才像被草一点点吃出来的，而不是画笔画的一条光滑曲线。
float road_edge_noise(vec2 cf) {
	float n = 0.0;
	n += (vnoise(cf * 0.18 + vec2(3.3, 8.1)) - 0.5) * 0.080;  // 约 5.5 格的大起伏
	n += (vnoise(cf * 0.40 + vec2(1.2, 4.7)) - 0.5) * 0.090;  // 约 2.5 格
	n += (vnoise(cf * 1.35 + vec2(7.7, 2.4)) - 0.5) * 0.045;  // 约 0.75 格
	n += (vnoise(cf * 3.10 + vec2(2.6, 5.9)) - 0.5) * 0.026;  // 约 0.32 格
	n += (vnoise(cf * 7.40 + vec2(6.1, 9.4)) - 0.5) * 0.014;  // 约 0.14 格毛边
	// 单侧缺口：成簇、只往里啃，偶尔凹进一大块，破掉"等宽带子"的读感
	n += smoothstep(0.60, 0.86, vnoise(cf * 1.55 + vec2(1.9, 6.3))) * 0.11;
	return n;
}

// 定向波列：正弦相位 + 两级噪声扭曲（否则是完美平行的直线条纹，很假）
float wave_train(vec2 p, vec2 dir, float freq, float speed, float t) {
	float phase = dot(p, dir) * freq * 6.2831853 - t * speed;
	phase += (vnoise(p * 0.45 + dir * 7.0) - 0.5) * 6.0;   // 大尺度弯曲
	phase += (vnoise(p * 1.40 + dir * 3.0) - 0.5) * 2.5;   // 细碎扰动
	return sin(phase);
}

// 坡面光照方向：方位角是"光从哪个方向来"（0=北、90=东、180=南、270=西），
// 高度角 0=贴着地平线、90=正上方。默认 315°/28.7° 即原来的左上光
// normalize(-0.62, -0.62, 0.48)。高度角夹到 2°~88°，避免退化向量。
vec3 light_vector() {
	float az = radians(u_light_azimuth);
	float el = radians(clamp(u_light_elevation, 2.0, 88.0));
	return normalize(vec3(sin(az) * cos(el), -cos(az) * cos(el), sin(el)));
}

// 水平光向：只有俯视明暗的地方（道路碎石）用，和 light_vector 的 xy 一致。
vec2 light_vector_xy() {
	float az = radians(u_light_azimuth);
	return normalize(vec2(sin(az), -cos(az)));
}

// 山体投影：从当前点沿光的方向步进高度场，看山脊是否挡住了光。
// 只在斜角使用；高度单位=级，射线高度按 tan(光高度角) 上升。
float sun_shadow(vec2 cf, float h0) {
	if (u_oblique < 0.5) return 0.0;
	vec2 ld = light_vector_xy();
	float el = radians(clamp(u_light_elevation, 8.0, 80.0));
	float tanel = tan(el);
	float occ = 0.0;
	for (int i = 1; i <= 12; i++) {
		float d = float(i) * 0.55;
		float h = elev_relief(cf + ld * d);
		float ray = h0 + d * tanel;
		occ = max(occ, smoothstep(0.10, 0.55, h - ray));
	}
	return occ;
}

// 单种路型的表面纹理（不含道路遮罩、边缘压暗和坡面光照）。
// 抽成函数是为了在土路/石子路/石砖路交界处分别采样两侧路型再交叉混合。
vec3 road_surface(float road_id, vec2 cf, vec2 dcell) {
	bool cE = cell_data(dcell + vec2(1.0, 0.0)).b * 255.0 > 0.5;
	bool cW = cell_data(dcell + vec2(-1.0, 0.0)).b * 255.0 > 0.5;
	bool cS = cell_data(dcell + vec2(0.0, 1.0)).b * 255.0 > 0.5;
	bool cN = cell_data(dcell + vec2(0.0, -1.0)).b * 255.0 > 0.5;
	vec3 rcol = table_color(8 + int(clamp(road_id, 1.0, 3.0)));
	if (road_id > 2.5) {
		// ---- 石砖路：错缝矩形砖 + 灰缝 + 棱边明暗 ----
		float bw = 0.58;
		float bh = 0.26;
		vec2 bp = vec2(cf.x / bw, cf.y / bh);
		float brow = floor(bp.y);
		bp.x += mod(brow, 2.0) * 0.5;
		vec2 bid = floor(bp);
		vec2 bf = fract(bp);
		float mortar = 0.048;
		float bx0 = bf.x * bw;
		float by0 = bf.y * bh;
		float bd = min(min(bx0, bw - bx0), min(by0, bh - by0));
		float joint = 1.0 - smoothstep(mortar, mortar + 0.018, bd);
		float stone_tone = 0.86 + 0.26 * hash21(bid + vec2(3.7, 1.3));
		vec3 bcol = rcol * stone_tone * (0.95 + 0.10 * vnoise(cf * 5.5 + bid * 2.9));
		float m2 = mortar + 0.020;
		float m3 = mortar + 0.058;
		float band_l = smoothstep(mortar, m2, bx0) * (1.0 - smoothstep(m2, m3, bx0));
		float band_t = smoothstep(mortar, m2, by0) * (1.0 - smoothstep(m2, m3, by0));
		float band_r = smoothstep(mortar, m2, bw - bx0) * (1.0 - smoothstep(m2, m3, bw - bx0));
		float band_b = smoothstep(mortar, m2, bh - by0) * (1.0 - smoothstep(m2, m3, bh - by0));
		bcol *= 1.0 + max(band_l, band_t) * 0.20 - max(band_r, band_b) * 0.22;
		return mix(bcol, bcol * 0.42, joint * (0.55 + u_road_texture * 1.4));
	} else if (road_id > 1.5) {
		// ---- 碎石路：Voronoi 卵石 ----
		float gs = 0.34;
		vec2 gp = cf / gs;
		vec2 gi = floor(gp);
		vec2 gf = fract(gp);
		float f1 = 8.0;
		float f2 = 8.0;
		vec2 gbest = vec2(0.0);
		vec2 gfrom = vec2(0.0);
		for (int oy = -1; oy <= 1; oy++) {
			for (int ox = -1; ox <= 1; ox++) {
				vec2 o = vec2(float(ox), float(oy));
				vec2 rnd = vec2(hash21(gi + o), hash21(gi + o + vec2(17.1, 4.7)));
				vec2 pos = o + rnd - gf;
				float d = length(pos);
				if (d < f1) {
					f2 = f1;
					f1 = d;
					gbest = gi + o;
					gfrom = pos;
				} else if (d < f2) {
					f2 = d;
				}
			}
		}
		float seam = smoothstep(0.03, 0.16, f2 - f1);
		float pebble = 0.90 + 0.22 * hash21(gbest + vec2(6.1, 2.3));
		vec3 gcol = rcol * pebble;
		float dome = 1.0 - smoothstep(0.0, 0.55, f1);
		float light_dir = dot(normalize(gfrom + vec2(1e-4)), light_vector_xy());
		gcol *= 0.88 + dome * 0.20 + light_dir * dome * 0.10;
		gcol *= 0.94 + 0.12 * vnoise(cf * 9.0);
		return mix(gcol * 0.50, gcol, seam * (0.55 + u_road_texture * 1.2));
	}
	// ---- 土路：沿走向拉长的细纹 + 干湿斑 + 碎石点 ----
	float ew = (cE || cW) ? 1.0 : 0.0;
	float ns = (cN || cS) ? 1.0 : 0.0;
	float run_t = ew / max(ew + ns, 1.0);
	vec2 suv = mix(vec2(cf.x * 2.4, cf.y * 9.0), vec2(cf.x * 9.0, cf.y * 2.4), run_t);
	float grain = vnoise(cf * 9.0) * 0.6 + vnoise(cf * 3.5 + vec2(2.0, 6.0)) * 0.4;
	grain = mix(grain, vnoise(suv), 0.55);
	// 大块干湿斑：土路不是一块均匀色板
	float damp = fbm(cf * 0.85 + vec2(7.1, 3.4));
	// 碎石/土块：暗点 + 少量亮点。阈值化才有颗粒感，平滑噪声只会糊成一片
	float peb = smoothstep(0.76, 0.92, vnoise(cf * 30.0 + vec2(3.9, 8.2)));
	float spec = smoothstep(0.84, 0.96, vnoise(cf * 38.0 + vec2(6.7, 2.5)));
	rcol *= 1.0 - u_road_texture * 0.50 + u_road_texture * grain;
	rcol *= 0.95 + (damp - 0.5) * 0.18;
	rcol *= 1.0 - peb * 0.06 + spec * 0.04;
	return rcol;
}

// 地表着色：cf 是格坐标（0..map_size）。俯视时直接由 UV 换算，斜角时由高度场步进得到。
vec3 shade_surface(vec2 cf) {

	// ---- 0) 连续水深场（宽核平滑）+ 等值线定岸：岸线因此是平滑曲线，不再是方格骨架 ----
	float wfield = water_blur(cf);
	// 低频噪声扰动等值线：给出湾岬与参差；幅度必须远小于 1 水深档
	float coast_noise = (fbm(cf * 0.33 + vec2(2.3, 6.1)) - 0.5)
		+ (vnoise(cf * 0.90 + vec2(7.7, 1.2)) - 0.5) * 0.5;
	wfield += coast_noise * u_coast_warp * 0.35;
	// 浅→深：阈值加噪声扰动、跨度拉宽 —— 边界变成"逐渐变深 + 深浅斑块交错"，不再是一条等值线
	float deep_wobble = (fbm(cf * 0.50 + vec2(3.1, 7.3)) - 0.5) * 0.55;
	// 交界带来回偏移（潮汐感）：两组缓慢行波叠加，让深浅带整体缓慢地进退，眼睛锁不住固定边界
	float tide = sin(u_time * 0.62 * u_tide_frequency + dot(cf, vec2(0.65, 0.35))) * (0.26 * u_tide_amplitude)
		+ sin(u_time * 0.34 * u_tide_frequency - dot(cf, vec2(0.25, 0.85)) + 1.7) * (0.16 * u_tide_amplitude);
	// 有水流方向的水面削弱潮汐：流动的水由流向驱动漂移，不再叠加往复摆动
	float flow_field = clamp(flow_blur(cf), 0.0, 1.0);
	float tide_damp = 1.0 - 0.75 * flow_field;
	float dw = mix(0.10, 0.45, pair_affinity(7.0, 8.0));

	// 陆地类型场（提前取用，岸线潮汐需要它判断"沙地在场"）
	float Lf = land_blur(cf) + (vnoise(cf * 1.6 + vec2(4.4, 8.8)) - 0.5) * u_edge_jitter * 0.06;

	// 沙地↔浅水且高程相同的岸段：岸线来回进退（潮汐）
	// sand_side 只认"干的沙滩"（beach_blur，水下沙河床不算），
	// 否则浅水下面的沙会让水与水之间也互相潮汐。
	float e0 = elev_smooth(cf);
	float ex = elev_smooth(cf + vec2(0.60, 0.0));
	float ey = elev_smooth(cf + vec2(0.0, 0.60));
	float egrad = abs(ex - e0) + abs(ey - e0);
	float same_elev = 1.0 - smoothstep(0.15, 0.55, egrad);
	// 以"沙地"编号 2 为中心的窄带（不能用 smoothstep(下限,上限,Lf)：那样冰面/雪地/荒地都会命中）
	float sand_side = exp(-pow((Lf - 2.0) / 0.55, 2.0)) * clamp(beach_blur(cf) * 2.5, 0.0, 1.0);
	float shallow_side = smoothstep(0.15, 0.45, wfield) * (1.0 - smoothstep(1.15, 1.55, wfield));
	float shore_tide = sand_side * shallow_side * same_elev;
	float shore_phase = sin(u_time * 0.52 * u_tide_frequency + dot(cf, vec2(0.80, 0.60))) * (0.25 * u_tide_amplitude)
		+ sin(u_time * 0.29 * u_tide_frequency - dot(cf, vec2(0.30, 0.90)) + 2.1) * (0.15 * u_tide_amplitude);

	float water_cover = smoothstep(0.46, 0.54, wfield + shore_tide * tide_damp * shore_phase);
	float deep_cover = smoothstep(1.5 - dw, 1.5 + dw, wfield + deep_wobble + tide * tide_damp);
	float waterness = max(water_cover, deep_cover);

	// ---- 1) 陆地类型：平滑场只当插值参数，两端必须是【真实相邻的两种材质】，
	//         否则 ID 插值会穿过不存在的中间材质（草地与沼泽之间冒出沙地/雪地色环）。 ----
	vec2 ip = floor(cf);
	vec2 fp = cf - ip;
	vec2 iq = fp * fp * (3.0 - 2.0 * fp);
	float i00 = land_of(cell_data(ip));
	float i10 = land_of(cell_data(ip + vec2(1.0, 0.0)));
	float i01 = land_of(cell_data(ip + vec2(0.0, 1.0)));
	float i11 = land_of(cell_data(ip + vec2(1.0, 1.0)));
	float base_id = land_of(cell_data(floor(cf + vec2(0.5))));
	float other_id = base_id;
	float bestw = 0.0;
	float w00 = (1.0 - iq.x) * (1.0 - iq.y);
	float w10 = iq.x * (1.0 - iq.y);
	float w01 = (1.0 - iq.x) * iq.y;
	float w11 = iq.x * iq.y;
	if (abs(i00 - base_id) > 0.01 && w00 > bestw) { other_id = i00; bestw = w00; }
	if (abs(i10 - base_id) > 0.01 && w10 > bestw) { other_id = i10; bestw = w10; }
	if (abs(i01 - base_id) > 0.01 && w01 > bestw) { other_id = i01; bestw = w01; }
	if (abs(i11 - base_id) > 0.01 && w11 > bestw) { other_id = i11; bestw = w11; }

	float bio = fbm(cf * 0.16 + vec2(11.3, 5.7));
	float bio2 = fbm(cf * 0.11 + vec2(2.1, 9.4));
	vec3 tint = vec3(1.0 + (bio - 0.5) * u_biome,
		1.0 + (bio2 - 0.5) * u_biome * 0.7,
		1.0 - (bio - 0.5) * u_biome * 0.8);

	// 平滑场 Lf 只用来算"在两种材质之间走到哪一步"，边界形状因此是曲线；
	// 叠一点高频噪声让边界参差（对应面板上的"边界打散幅度"）；Lf 已在上方陆地场处算好
	float t = 0.0;
	if (abs(other_id - base_id) > 0.01) {
		t = clamp((Lf - base_id) / (other_id - base_id), 0.0, 1.0);
	}
	float aff = abs(other_id - base_id) > 0.01 ? pair_affinity(base_id, other_id) : 0.0;
	// 草↔沼不走"硬边咬合"：沼泽是渐湿的地，不是另一种颜色插进来的地。见 2c。
	float sg = 0.0;
	if (abs(base_id - 1.0) < 0.01 && abs(other_id - 5.0) < 0.01) sg = 1.0;
	if (abs(base_id - 5.0) < 0.01 && abs(other_id - 1.0) < 0.01) sg = 1.0;
	float bh = mix(max(u_band_hard, 0.03), max(u_band_soft, u_band_hard), aff) * 0.12;
	float wob = (fbm(cf * 0.70 + vec2(4.7, 1.3)) - 0.5) * 0.85
		+ (vnoise(cf * 1.70 + vec2(9.1, 6.2)) - 0.5) * 0.40;
	float tk = t + wob * (0.30 + 0.70 * aff);
	float mixw = smoothstep(0.5 - bh, 0.5 + bh, tk);
	// 草↔沼：底色不再按格混合（那会在格子边界留下方形台阶），
	// 过渡完全交给 2c 的湿气场；这里只保留"这一格是谁"。
	mixw = mix(mixw, step(4.5, base_id), sg);
	vec3 col = mix(table_color(int(base_id)) * tint, table_color(int(other_id)) * tint, mixw);
	float crease = 1.0 - smoothstep(0.0, max(u_crease_width, 0.02), abs(tk - 0.5));
	col *= 1.0 - crease * u_crease_dark * 1.0 * (1.0 - aff * 0.7) * (1.0 - water_cover) * (1.0 - sg);
	float pattern_id = mixw > 0.5 ? other_id : base_id;

	// 沼泽连续场：底色、水洼密度、材质纹理的混合都由它跨过格子边界驱动
	float swf = swamp_field(cf + (vec2(vnoise(cf * 0.33 + vec2(2.7, 5.5)),
		vnoise(cf * 0.33 + vec2(7.9, 1.1))) - 0.5) * 1.6);
	float swfn = swf + (fbm(cf * 0.55 + vec2(3.2, 8.4)) - 0.5) * 0.30
		+ (vnoise(cf * 1.45 + vec2(6.6, 2.2)) - 0.5) * 0.10;
	float marsh = smoothstep(0.24, 0.56, swfn);
	float swamp_zone = (base_id < 1.5 || (base_id > 4.5 && base_id < 5.5)) ? 1.0 : 0.0;

	// ---- 1.5) 高程梯度 + 陡壁参数（图案/光照共用） ----
	// 俯视纹理落在近垂直的坡面上会沿坡拉长；这里先算出坡度，
	// 后面把俯视图案压平、换成立面岩层。梯度同时给光照段复用，不重复采样高度场。
	float d = max(u_elevation_shadow_width, 0.10) * 1.6;
	float h0 = elev_relief(cf);
	float hx = elev_relief(cf + vec2(d, 0.0));
	float hy = elev_relief(cf + vec2(0.0, d));
	vec2 g = vec2(hx - h0, hy - h0) / d;        // 梯度（高度/格）
	float slope = length(g);
	float land_mask = 1.0 - waterness;
	// 陡壁不画俯视图案：斜角里沿坡会被拉长，这里先压平图案/草叶；
	// 陡壁的材质由后面的“沿等高线/沿高度”的层理与裂缝接手。俯视视图不启用。
	float cliff = smoothstep(0.12, 0.30, slope) * land_mask * (u_oblique > 0.5 ? 1.0 : 0.0);

	// ---- 1.6) 树根草垫 ----
	// 树木贴图底部自带一小片草，固定色与地表程序化草很难完全一致。
	// 在树的脚底先铺一圈同色、同颗粒的草，贴图草垫的边缘就会落在近似材质上。
	// 掩码由 MapRuntime 按 tree 类物件烘成 2~4 px/格，噪声把圆形边界打散。
	float root = root_field(cf);
	float root_n = fbm(cf * 1.55 + vec2(3.7, 8.9)) - 0.5;
	float root_n2 = vnoise(cf * 4.2 + vec2(6.3, 1.9)) - 0.5;
	root = smoothstep(0.05, 0.55, root + root_n * 0.30 + root_n2 * 0.10);
	root *= 1.0 - clamp(water_cover, 0.0, 1.0);
	root *= 1.0 - cliff * 0.6;

	// ---- 2) 分材质结构图案 + 微凹凸光照 ----
	vec2 pf = cf * u_texture_frequency;
	float p0 = material_pattern(pf, pattern_id);
	// 过渡带里两种纹理按场混合，否则草丛的纵向纹理与水洼的纹理会在格子边界上突然换手
	if (marsh > 0.004 && swamp_zone > 0.5 && marsh < 0.996) {
		p0 = mix(material_pattern(pf, 1.0), material_pattern(pf, 5.0), marsh);
	}
	float pdx = material_pattern(pf + vec2(0.40, 0.0), pattern_id);
	float pdy = material_pattern(pf + vec2(0.0, 0.40), pattern_id);
	// 陡壁：俯视图案和微凹凸沿坡会被拉长，先压平，后面由立面岩层接手
	p0 = mix(p0, 1.0, cliff);
	pdx = mix(pdx, 1.0, cliff);
	pdy = mix(pdy, 1.0, cliff);
	col *= 1.0 + (p0 - 1.0) * u_texture_strength;
	vec2 grad = vec2(pdx - p0, pdy - p0) * u_texture_strength * 2.2;
	float bump = 1.0 - (grad.x + grad.y) * u_bump * 0.35;
	col *= mix(1.0, clamp(bump, 0.90, 1.10), 1.0 - water_cover);

	// ---- 1b) 草地：像素草丛 ----
	// 树贴图里的草是"一团一团"的：暗橄榄底色、成簇的短草叶、黄绿叶尖、叶间深缝。
	// 程序化草也按这个读法做：像素格上硬边切叶，低频噪声决定草簇疏密，
	// 不再用大范围平滑渐变 —— 那样在 45° 下会变成一片流动的绿浆。
	float grass_w = 0.0;
	// 只要本格是草就满权重：草叶不是"两材质混合量"，而是这一格自己的材质细节。
	// 旧写法用 mixw，纯草格邻接荒地时 mixw 会被推到 1，整片草都被判成没草。
	if (abs(base_id - 1.0) < 0.5) {
		grass_w = 1.0;
	} else if (abs(other_id - 1.0) < 0.5) {
		grass_w = t;
	}
	grass_w *= 1.0 - clamp(water_cover, 0.0, 1.0);
	grass_w *= 1.0 - cliff;   // 草叶也是俯视笔触，陡壁上会拉长
	float root_core = smoothstep(0.10, 0.58, root);
	// 树根下不一定原本就是草地：裸土上也长一小片草，贴图里的草垫才不会浮在土上
	if (root_core > 0.002) {
		float rt = fbm(cf * 2.10 + vec2(2.9, 6.4));
		vec3 root_col = mix(vec3(0.35, 0.38, 0.15), vec3(0.43, 0.45, 0.18), rt) * tint;
		col = mix(col, root_col, root_core * 0.58);
	}
	float grass_cover = max(grass_w, root_core * 0.92);
	if (grass_cover > 0.01) {
		// 草叶坐标直接用世界格：叶片只有 1~2 屏幕像素宽，
		// 再量化到 20 px/格的网格会把它整根漏掉。
		vec2 gp = cf;
		// 草窝密度：两层低频噪声决定哪里成片、哪里稀疏（小团 + 大块）
		float clump_a = smoothstep(0.36, 0.66, fbm(cf * 1.30 + vec2(6.1, 3.3)));
		float clump_b = smoothstep(0.30, 0.70, fbm(cf * 0.55 + vec2(2.4, 9.7)));
		float clump = clamp(clump_a * 0.72 + clump_b * 0.52, 0.0, 1.0);
		// 低频扭曲草窝网格：否则所有草窝会在地图坐标里排成整齐的斜行
		vec2 gwarp = vec2(vnoise(cf * 1.7 + vec2(2.3, 5.1)),
			vnoise(cf * 1.7 + vec2(8.7, 1.4))) - 0.5;
		vec4 tuft = grass_tuft(gp + gwarp * 0.26, clump);
		float blade = tuft.x;
		float edge = tuft.y;
		float tone = tuft.z;
		float tip = tuft.w;
		float gk = clamp(u_texture_strength, 0.0, 2.0);
		float w = grass_cover * gk;
		// 像素底纹：16 个世界像素/格，2~3 档硬边明暗。
		// 树贴图的草垫不是纯色底，放大看有细碎的深浅块；这层让程序化草也有同样的颗粒。
		vec2 mp = floor(cf * 16.0) / 16.0;
		float m1 = vnoise(mp * 4.5 + vec2(3.1, 7.7));
		float m2 = vnoise(mp * 9.0 + vec2(8.4, 2.6));
		col *= 0.955 + 0.040 * step(0.45, m1) + 0.025 * step(0.62, m2);
		col *= 1.0 - 0.030 * step(0.60, 1.0 - m1);
		// 大一点的暗草簇：树贴图草垫里也有成片的深色草，不让整片草地读成一块平色
		float dark_clump = smoothstep(0.56, 0.76, fbm(cf * 0.72 + vec2(9.1, 4.3)));
		col *= 1.0 - dark_clump * grass_cover * 0.09;
		// 叶身用显式的深橄榄→黄绿叶色，不再只是在底色上加减亮度：
		// 这样即使地表底色和树贴图草垫有一点差异，叶片本身也会读成同一种草。
		vec3 blade_col = mix(vec3(0.21, 0.25, 0.09), vec3(0.46, 0.49, 0.17), tip) * tint;
		blade_col = mix(blade_col, blade_col * vec3(1.10, 1.06, 0.72), tone * 0.35);
		col = mix(col, blade_col, blade * w * 0.70);
		// 叶根暗边：贴图草叶根部的一圈深色
		col = mix(col, col * vec3(0.62, 0.68, 0.46), edge * w * 0.42);
		// 一丛丛的暗色草窝：让草地有疏密，不是均匀噪点
		float dark = smoothstep(0.58, 0.80, vnoise(gp * 2.8 + vec2(7.4, 3.8))) * (1.0 - blade);
		col *= 1.0 - dark * w * 0.10;
		// 细粒：只做极轻的抖动
		col *= 1.0 + (vnoise(cf * 9.5 + vec2(2.2, 5.5)) - 0.5) * 0.04 * grass_cover;
	}

	// ---- 2b) 沼泽湿地：瓣状咬合 + 瓣外湿地，全部由一张连续沼泽场驱动 ----
	// 分界不再是"格子归属"的切换：底色由噪声等值线被场推动后决定（大瓣互相伸入），
	// 水洼密度在瓣内外连续过渡，瓣缘还有草丘与湿斑 —— 所以既没有格子台阶，也不是一条渐变线。
	if (marsh > 0.002 && swamp_zone > 0.5 && water_cover < 0.5) {
		// 底色：大尺度离散咬合 —— 噪声等值线被连续沼泽场推动，形成互相伸入的瓣。
		// 瓣的尺度是 2~4 格，所以既不是格子台阶，也不是一条柔和的渐变线。
		// 亲和度（草↔沼）决定瓣互相伸入的深度。
		float lobe_k = 0.60 + 0.45 * pair_affinity(1.0, 5.0);
		float lobe = fbm(cf * 0.38 + vec2(3.9, 8.2)) + (swfn - 0.5) * 1.35 * lobe_k
			+ (vnoise(cf * 1.15 + vec2(6.3, 3.4)) - 0.5) * 0.22;   // 细一级的参差
		float sw = smoothstep(0.47, 0.53, lobe);
		col = mix(table_color(1), table_color(5), sw) * tint;
		// 瓣边缘一圈湿泥：草地一侧轻微压暗，说明"这里更湿"，但不破坏离散感
		float wet_rim = 1.0 - smoothstep(0.02, 0.13, abs(lobe - 0.5));
		col *= 1.0 - wet_rim * 0.16;
		// 苔草团：草地一侧的亮黄绿小簇，把瓣边缘打散
		float hum_n = fbm(cf * 0.80 + vec2(9.1, 2.2));
		float hum = smoothstep(0.55, 0.63, hum_n) * (1.0 - sw) * smoothstep(0.10, 0.45, marsh);
		col = mix(col, vec3(0.52, 0.60, 0.28) * tint, hum * 0.38);
		// 反向：沼泽一侧靠边的草丘（草地色的小块伸进沼泽），两个方向都在咬合
		float edge_in = (1.0 - smoothstep(0.56, 0.66, lobe)) * sw;
		float tuft = smoothstep(0.56, 0.64, fbm(cf * 0.95 + vec2(7.7, 1.9))) * edge_in;
		col = mix(col, table_color(1) * 0.90 * tint, tuft * 0.60);
		// 瓣外一圈：草地离沼泽最近的这一带先"湿"下去（噪声调制，避免变成整齐晕圈），
		// 再散落几处小水洼 —— 边界之外也有水有暗，剪影感就没了
		float outside = (1.0 - sw) * smoothstep(0.10, 0.46, lobe);
		float damp_patch = smoothstep(0.50, 0.58, fbm(cf * 1.10 + vec2(14.2, 3.6)));
		col = mix(col, col * vec3(0.72, 0.80, 0.55), outside * damp_patch * 0.85);
		vec2 sp = cf * u_texture_frequency;
		float pool_n = fbm(sp * 0.40 + vec2(5.1, 2.7));
		float pool_fine = vnoise(sp * 1.30 + vec2(8.3, 4.1));
		float pn = pool_n + (pool_fine - 0.5) * 0.16;
		// 阈值连续：草地侧 0.86→0.48（越进瓣越多），瓣内保持沼泽的密度
		float pthr = mix(0.86, 0.48, sw);
		float pool = smoothstep(pthr, pthr + 0.03, pn);
		// 瓣外散布的小水洼：同一张场的高阈值切片，自然形成互不相连的小坑
		float puddle = smoothstep(0.70, 0.74, pn) * outside;
		pool = max(pool, puddle * 0.9);
		// 水洼：暗青底，涟漪缓慢推过（相位被噪声打散，避免出现规则条纹）
		float rip = 0.5 + 0.5 * sin(dot(cf, vec2(0.9, 0.4)) * 3.6 - u_time * 0.8
			+ pool_n * 10.0 + pool_fine * 4.5);
		rip = rip * 0.65 + vnoise(sp * 1.9 + vec2(3.3, 6.7)) * 0.35;
		vec3 poolcol = mix(vec3(0.12, 0.21, 0.19), vec3(0.24, 0.37, 0.33), rip * 0.55 + 0.22);
		// 细窄反射亮纹：很窄的高光，沿另一个方向缓慢移动
		float sheen = pow(max(0.0, sin(dot(cf, vec2(0.55, 0.83)) * 2.1 - u_time * 0.5 + pool_n * 6.0)), 34.0);
		poolcol += vec3(0.11) * sheen;
		poolcol *= tint;
		// 水洼里稀疏冒出的植被小岛
		float isl = smoothstep(0.70, 0.77, vnoise(sp * 1.8 + vec2(11.0, 3.0)));
		poolcol = mix(poolcol, table_color(5) * 1.35 * tint, isl * 0.8);
		// 池缘：湿泥一圈压暗，让水洼"陷"进去
		float rim = smoothstep(pthr - 0.10, pthr, pn) * (1.0 - pool);
		rim = max(rim, smoothstep(0.66, 0.74, pn) * outside * (1.0 - puddle));
		col = mix(col, col * 0.68, rim * 0.85);
		col = mix(col, poolcol, pool);
		// 芦苇：成片的纵向草穗，只出现在瓣缘附近的草地一侧；用低频噪声控制"成片/没有"，
		// 避免绕场一圈均匀的描边
		float reed_n = vnoise(vec2(cf.x * 2.4, cf.y * 0.40) + vec2(4.4, 1.2)) * 0.70
			+ vnoise(vec2(cf.x * 6.5, cf.y * 1.10) + vec2(1.7, 8.8)) * 0.30;
		float reed_patch = smoothstep(0.30, 0.62, vnoise(cf * 0.42 + vec2(12.7, 5.1)));
		float reed = smoothstep(0.64, 0.72, reed_n) * reed_patch
			* (1.0 - sw) * smoothstep(0.12, 0.45, marsh) * (1.0 - pool);
		col = mix(col, vec3(0.50, 0.56, 0.26) * tint, reed * 0.50);
	}

	// ---- 4) 水面：浅水透出海底（沙/泥/草色），深水不透明；深浅之间逐渐加深 ----
	vec3 shallow_c = mix(col, table_color(7) * tint, 0.88);
	vec3 deep_c = table_color(8) * tint;
	col = mix(col, shallow_c, water_cover);
	col = mix(col, deep_c, deep_cover);
	col *= 1.0 - 0.02 * clamp(wfield - 1.0, 0.0, 1.0);   // 越深越沉（很轻微）

	// ---- 4b) 山体：独立遮罩 + 独立岩石材质，和可行走地面明确分开 ----
	// 山体不是地形分类：地面/道路/水域仍按你的笔刷画，山体格只覆盖表面材质并阻挡通行。
	float mnt = texture(u_mountain, cf / u_map_size).r;
	float mtn = smoothstep(0.35, 0.65, mnt);
	if (mtn > 0.001) {
		// 大块板岩 + 水平层理 + 竖向裂缝；不沿用草地/沙地的笔触
		float plate_n = fbm(cf * 0.55 + vec2(7.3, 2.8));
		float strata = 0.5 + 0.5 * sin(h0 * 3.4 + fbm(cf * 0.42 + vec2(2.6, 6.1)) * 6.5);
		float crack_n = fbm(vec2(cf.x * 2.2, cf.y * 0.75) + vec2(4.3, 1.7));
		float crack = 1.0 - smoothstep(0.0, 0.06, abs(crack_n - 0.5));
		float block = smoothstep(0.40, 0.60, fbm(cf * 0.33 + vec2(9.7, 3.1)));
		vec3 mtn_c = table_color(13) * (0.62 + 0.30 * plate_n + 0.10 * strata);
		mtn_c *= mix(0.82, 1.06, block);
		mtn_c *= vec3(0.92, 0.96, 1.05);   // 偏冷的板岩色，和草地/沙地拉开
		mtn_c *= 1.0 - crack * 0.30;
		mtn_c *= 0.96 + 0.08 * fbm(cf * 4.2 + vec2(6.1, 2.4));
		mtn_c *= mix(0.78, 1.0, smoothstep(0.0, 0.45, mnt));
		col = mix(col, mtn_c, mtn);
		// 山脚折痕：边界压暗，山体和可行走地面不会粘成一块
		float edge = 1.0 - smoothstep(0.0, 0.18, abs(mnt - 0.5));
		col *= 1.0 - edge * 0.35;
	}

	// ---- 5) 高程浮雕：法线 → 光照方向（方位/高度角见 u_light_*） ----
	// 平地的法线是竖直的，读数归一为 1；迎光坡变亮、背光坡变暗，由此读出坡向和体量。
	// 梯度 / 坡度 / land_mask 已在 1.5 段算好（图案与陡壁共用同一份）。
	float k = max(u_relief, 0.05) * 1.4;        // 垂直夸张
	vec3 nrm = normalize(vec3(-g.x * k, -g.y * k, 1.0));
	vec3 lgt = light_vector();
	float ndl = dot(nrm, lgt);
	// 山体：陡坡露岩、高处缓坡积雪。用原始坡度（级/格）而不是垂直夸张后的坡度：
	// 换"斜角高度"不会改变岩石分布。
	float rock = smoothstep(u_rock_slope_low, max(u_rock_slope_high, u_rock_slope_low + 0.01), slope) * land_mask;
	float snow_line = max(u_snow_line_min, u_elev_max * u_snow_line_ratio);
	// 雪线不是一条等高线：用低频噪声把阈值打散成斑块
	float snow_n = (fbm(cf * 0.55 + vec2(5.3, 2.7)) - 0.5) * 2.4;
	float snow = smoothstep(snow_line, snow_line + 1.0, h0 + snow_n)
		* (1.0 - smoothstep(0.75, 1.05, slope)) * land_mask;
	// 以平地（ndl = lgt.z）为零点做对称的明暗：迎光 +，背光 −，
	// 不用 (ndl-1) 那种写法 —— 背光侧会一直压到黑，坡面就变成一条深沟。
	float shade = clamp(ndl - lgt.z, -0.45, 0.55);
	float lit = 1.0 + shade * (u_elevation_shadow * 2.4);
	lit += max(shade, 0.0) * u_elevation_rim * 1.5;   // 迎光坡的窄高光
	float lit_c = clamp(lit, 0.62, 1.32);
	col *= mix(1.0, lit_c, land_mask);
	// 暗部略偏冷、亮部略偏暖：比单纯压暗更像受光，也不容易读成脏污
	col *= mix(vec3(0.97, 0.995, 1.03), vec3(1.02, 1.0, 0.97), clamp(shade * 2.0 + 0.5, 0.0, 1.0));
	// 高度提亮按全图最高点归一，否则高山会一路加到过曝
	float hrel = clamp((h0 - 1.0) / max(u_elev_max - 1.0, 1.0), 0.0, 1.0);
	col *= 1.0 + hrel * u_elevation_bright * 2.0;
	// 山体覆盖放在打光之后：岩石/雪帽用同一个 lit 明暗，但不再叠加高度提亮。
	// 陡壁不再压成平色：用高度层理 + 竖向裂缝给岩壁一个可读的立面材质。
	if (rock > 0.002 || snow > 0.002) {
		// 崖壁纹理用“沿等高线 / 沿高度”的二维坐标，避免俯视噪声在坡面上被拉成长条。
		vec2 contour_dir = normalize(vec2(-g.y, g.x) + vec2(0.0001, 0.0002));
		float face_u = dot(cf, contour_dir) * 1.80;
		float face_v = h0 * 1.10;
		float rock_n = fbm(vec2(face_u * 1.80, face_v * 1.10) + vec2(3.7, 8.1));
		float strata = 0.5 + 0.5 * sin(face_v * 2.6 + fbm(vec2(face_u * 0.30, face_v * 0.18)) * 7.0);
		float crack_n = fbm(vec2(face_u * 0.70, face_v * 0.20) + vec2(4.3, 1.7));
		float crack = 1.0 - smoothstep(0.0, 0.07, abs(crack_n - 0.5));
		float grain = 0.80 + 0.30 * mix(rock_n, fbm(cf * 2.1 + vec2(2.2, 6.9)), 0.45);
		grain *= mix(1.0, 0.92 + 0.14 * strata, cliff);
		grain *= 1.0 - crack * 0.18 * cliff;
		vec3 rock_c = table_color(13) * grain * clamp(lit, 0.62, 1.32);
		vec3 snow_c = table_color(14) * (0.94 + 0.12 * fbm(cf * 1.8 + vec2(1.9, 6.4)))
			* clamp(lit, 0.78, 1.16);
		col = mix(col, rock_c, rock * 0.92);
		col = mix(col, snow_c, snow * 0.72);
	}
	// 山体自投影：谷地/背坡压暗，山脊才有体量
	float sun_occ = sun_shadow(cf, h0);
	col *= mix(1.0, 0.66, sun_occ * land_mask);
	col *= mix(vec3(1.0), vec3(0.83, 0.89, 1.06), sun_occ * land_mask * 0.65);

	// ---- 6) 水面动效：定向波列（方向跟随流向）+ 波峰高光 + 岸线泡沫 ----
	if (waterness > 0.01) {
		float flow_id = cell_data(floor(cf)).a * 255.0;
		vec2 fdir = flow_vec(flow_id);
		if (dot(fdir, fdir) < 0.04) fdir = vec2(1.0, 0.25);   // 没画流向时给一组默认东偏南的浪
		vec2 md = normalize(fdir);
		vec2 sd = vec2(-md.y, md.x);
		float t = u_time;
		// 长涌浪 + 中浪 + 细浪，方向略有夹角；再乘波群调制，让浪有大有小而不是均匀条纹
		float w1 = wave_train(cf, md, u_ripple_frequency * 0.14, u_ripple_speed * 1.3, t);
		float w2 = wave_train(cf, normalize(md + sd * 0.7 + vec2(0.001, 0.001)), u_ripple_frequency * 0.30, u_ripple_speed * 2.4, t);
		float w3 = wave_train(cf, normalize(md - sd * 0.5 + vec2(0.001, 0.001)), u_ripple_frequency * 0.55, u_ripple_speed * 3.8, t);
		float group = 0.38 + 0.62 * vnoise(cf * 0.22 + md * 3.0 + vec2(0.0, t * 0.05));
		float wave = (w1 * 0.55 + w2 * 0.30 + w3 * 0.15) * group;
		float amp = u_ripple_strength * (0.95 + 0.30 * deep_cover);   // 深水浪略大（差距不能大，否则交界处纹理突变）
		vec3 water = col * (1.0 + wave * amp * 0.80);
		// 波峰抬亮、波谷压暗（这是"浪"能被看出来的关键）
		water += vec3(smoothstep(0.25, 1.0, wave)) * amp * 0.22;
		water *= 1.0 - smoothstep(0.25, 1.0, -wave) * amp * 0.18;
		// 浪尖碎白
		float chop = vnoise(cf * u_ripple_frequency * 0.9 - fdir * t * u_flow_speed);
		water += vec3(smoothstep(0.82, 1.0, chop)) * amp * 0.07;
		// 溪流的方向性水纹：沿流向拉长的亮暗条纹 + 快速漂移的碎白。
		// 大水面没有画流向时 flow_mask=0，不会变成条纹海。
		float flow_mask = smoothstep(0.08, 0.55, flow_field);
		if (flow_mask > 0.01) {
			float flow_t = u_time * (u_flow_speed * 2.5 + 0.20);
			float across = dot(cf, sd);
			float along = dot(cf, md);
			// 长条泡沫：横跨流向很窄、顺流拉长，向下游快速漂移。
			// across 先被噪声扭曲，条纹才会弯、会断，不会变成一排平行直线。
			float warp_a = (vnoise(vec2(along * 1.6, across * 1.1)) - 0.5) * 1.6;
			float streak_n = fbm(vec2((across + warp_a) * 5.5, along * 0.35 - flow_t * 0.9));
			float streak = smoothstep(0.56, 0.68, streak_n)
				- 0.50 * smoothstep(0.38, 0.28, streak_n);
			water += vec3(0.16) * streak * flow_mask * (0.80 + 0.50 * amp);
			// 第二层短沫：更宽、更慢，补足溪流中间的碎波
			float warp_b = (vnoise(vec2(along * 2.2, across * 1.7)) - 0.5) * 1.2;
			float streak2_n = fbm(vec2((across + warp_b) * 3.0, along * 1.1 - flow_t * 1.6));
			float streak2 = smoothstep(0.58, 0.70, streak2_n)
				- 0.45 * smoothstep(0.38, 0.28, streak2_n);
			water += vec3(0.11) * streak2 * flow_mask;
			// 碎白：被水流拉碎的亮点
			float fleck_n = vnoise(vec2(across * 9.0, along * 1.4 - flow_t * 2.2));
			water += vec3(0.18) * smoothstep(0.80, 0.94, fleck_n) * flow_mask;
		}
		// 岸线泡沫
		float dshore = abs(wfield - 0.55);
		float foam_mask = 1.0 - smoothstep(0.02, 0.02 + 0.18 * max(u_foam_width, 0.1), dshore);
		foam_mask *= smoothstep(0.45, 0.62, water_cover);
		float foam = smoothstep(0.25, 0.75, foam_mask * (0.55 + 0.9 * vnoise(cf * 6.0 + vec2(0.0, u_time * 0.8))));
		water = mix(water, table_color(12), foam * u_foam_strength * 0.6);
		col = mix(col, water, clamp(waterness, 0.0, 1.0));
	}

	// ---- 7) 道路：连续距离场 + 等值线定边 ----
	// 旧实现"每个路格只画自己那一格"：路缘最多从格界往里缩，向外的一侧被格子
	// 裁掉一半，所以长直段永远笔直、转角永远是 90° 折角。现在把 3×3 邻域的
	// 路格并成一个区域求有符号距离，场在草格上照样有值 —— 路缘可以越界外鼓、
	// 也可以被草往里啃，位置不再由格界决定。
	// 角部不做特殊补丁：对距离场做 5 点平均，凸角被磨成圆弧、凹角被填成圆角，
	// 直段因对称而位置不变（圆头补丁那种在内侧鼓凸包的问题也就不存在了）。
	vec2 dcell = floor(cf);
	mat3 road_ids = road_ids_3x3(dcell);   // 3×3 路型取一次，距离/平滑/取色共用
	vec2 pw = cf + road_warp(cf);
	RoadField rf = road_field(pw, dcell, road_ids);
	float rw = u_road_width;
	float re = max(u_road_softness, 0.01);
	float inset = 0.5 - rw;   // 从数据边界再往里收多少（0.5 格宽 = 路占满整格）
	float rr = clamp(u_road_round, 0.0, 0.5);
	if (rr > 0.02 && rf.d0 < 0.85) {
		vec2 o = vec2(rr);
		float ds = road_signed_dist(pw + o, dcell, road_ids)
			+ road_signed_dist(pw - o, dcell, road_ids)
			+ road_signed_dist(pw + vec2(o.x, -o.y), dcell, road_ids)
			+ road_signed_dist(pw + vec2(-o.x, o.y), dcell, road_ids);
		float dsm = (rf.d0 + ds) * 0.2;
		// 平滑只在路缘附近生效：整格都做平均会把 1 格宽的路中心从 -0.5 磨到 -0.2，
		// 再叠上边缘噪声就会出现"路面被啃断"的洞。窄路必须保住中心的深度。
		float wsm = 1.0 - smoothstep(0.22, 0.50, -rf.d0);
		rf.d0 = mix(rf.d0, dsm, wsm);
	}
	float db = rf.d0 + road_edge_noise(cf);
	float rm = 1.0 - smoothstep(-inset - re, -inset + re, db);
	// 水下不显路（道路数据仍在陆地层，水退后自动露出来）
	rm *= 1.0 - clamp(waterness, 0.0, 1.0);
	// 路外裸土：路肩外侧的地皮被踩秃。用阈值噪声做成稀疏斑块 ——
	// 一圈均匀的渐变只会让路看起来像贴上去的带子，斑块才读成"这里常有人走"。
	float apron_n = smoothstep(0.50, 0.74, vnoise(cf * 2.7 + vec2(4.4, 1.6)))
		* smoothstep(0.36, 0.68, vnoise(cf * 0.90 + vec2(8.2, 3.7)))
		* (0.55 + 0.45 * smoothstep(0.45, 0.75, vnoise(cf * 3.9 + vec2(7.3, 2.1))));
	float apron = (1.0 - smoothstep(-inset - 0.02, -inset + 0.30, db)) * apron_n * 0.22;
	apron *= 1.0 - rm;   // 路内不叠裸土
	float cover = max(rm, apron);
	if (cover > 0.002 && rf.id0 > 0.5) {
		vec3 rcol = road_surface(rf.id0, cf, rf.cell0);
		// 不同路型交界：按路型 id 固定 A/B，用一个【全局单值】权重交叉。
		// 旧写法是"本地材质 + 对方比例"：两侧算出的比例相同、底色却相反，
		// 于是颜色在交界处直接换手 —— 那就是硬切线。
		// 现在取 f = dB - dA（A 侧为正、B 侧为负、交界为 0），权重只由 f 决定，
		// 两侧算的是同一个数；再用噪声推交界线，形成互相伸入的舌状，
		// 过渡带里是完整的两种路面，而不是一层灰泥。
		if (rf.id1 > 0.5 && rf.d1 < 60.0) {
			float idA = min(rf.id0, rf.id1);
			float idB = max(rf.id0, rf.id1);
			float dA = (abs(rf.id0 - idA) < 0.5) ? rf.d0c : rf.d1;
			float dB = (abs(rf.id0 - idB) < 0.5) ? rf.d0c : rf.d1;
			float fsep = dB - dA;
			float bw = max(u_road_blend, 0.05);
			if (abs(fsep) < bw * 2.6) {
				vec2 cellA = (abs(rf.id0 - idA) < 0.5) ? rf.cell0 : rf.cell1;
				vec2 cellB = (abs(rf.id0 - idB) < 0.5) ? rf.cell0 : rf.cell1;
				// 噪声只在交界附近起作用，远处（f 大）不再叠 —— 否则整条路都会被染色
				float near = 1.0 - smoothstep(0.0, bw * 2.0, abs(fsep));
				float lobe = (fbm(cf * 1.05 + vec2(3.7, 8.4)) - 0.5)
					+ (vnoise(cf * 2.60 + vec2(9.1, 2.2)) - 0.5) * 0.45;
				float wB = clamp(0.5 - (fsep + lobe * bw * 1.30 * near) / (2.0 * bw), 0.0, 1.0);
				// 阈值化：交界处不是"两层各半透明地叠在一起"（那样只会糊成一层灰泥），
				// 而是整片完整的另一种路面成舌状伸进来；越远舌头越少，密度自然衰减。
				wB = smoothstep(0.30, 0.70, wB);
				rcol = mix(road_surface(idA, cf, cellA), road_surface(idB, cf, cellB), wB);
				// 交界处的细小散落：碎石被带到土面上，越远离石面越稀。
				// 尺寸压到 3~5 像素、颜色带随机深浅，才读成"小石子"而不是一片灰斑。
				float nearB = 1.0 - smoothstep(0.0, bw * 1.05, abs(fsep));
				if (nearB > 0.01 && rf.id0 < 1.5) {
					float speck = smoothstep(0.78, 0.86, vnoise(cf * 30.0 + vec2(5.4, 3.1)));
					float st = vnoise(cf * 57.0 + vec2(1.7, 8.8));
					vec3 pcol = table_color(10) * (0.72 + 0.42 * st);
					rcol = mix(rcol, pcol, speck * nearB * 0.85);
				}
			}
		}
		// 路肩压暗：跟着噪声位移后的真实边缘走，宽度再抖一抖，不是一圈定宽描边
		float rim_n = 0.65 + 0.70 * vnoise(cf * 3.1 + vec2(5.5, 7.2));
		float rim = smoothstep(-inset - 0.18, -inset, db) * (1.0 - smoothstep(-inset, -inset + 0.06, db)) * rim_n;
		rcol *= 1.0 - rim * 0.16;
		// 与地形共用同一套坡面明暗：山坡上的路才不会像贴纸
		rcol *= lit_c;
		// 路外裸土更暗、更脏（踩实的土混着腐殖质），和路面拉出层次
		vec3 acol = rcol * 0.76;
		col = mix(col, mix(acol, rcol, smoothstep(0.0, 0.45, rm)), clamp(cover, 0.0, 1.0));
		// 路缘草：草叶跨过边界漫上来一点。只做颜色过渡的话，路会读成一条贴上去的
		// 色带；有草真的长在边上，才是"被人踩出来的路"。
		// 用 db（不是 rm）取带：rm 的过渡只有 0.03 格宽，草叶根本落不进去。
		float egrass = smoothstep(-inset - 0.30, -inset - 0.02, db)
			* (1.0 - smoothstep(-inset + 0.02, -inset + 0.20, db));
		egrass *= clamp(grass_cover, 0.0, 1.0);
		if (egrass > 0.02) {
			float eclump = smoothstep(0.50, 0.72, fbm(cf * 0.95 + vec2(6.1, 2.8)));
			vec4 et = grass_tuft(cf + vec2(0.37, 0.11), 0.62);
			vec3 ecol = mix(vec3(0.21, 0.25, 0.09), vec3(0.46, 0.49, 0.17), et.w) * tint;
			col = mix(col, ecol, et.x * egrass * u_road_grass * eclump);
		}
	}
	// ---- 8) 细颗粒：只做极低幅度抖动，防止色带 ----
	col *= 1.0 + (vnoise(cf * 7.3 + vec2(0.5, 3.1)) - 0.5) * u_grain;

	return col;
}


// ===== 斜角视图：正交相机（从南向北俯看）对高度场做射线步进 =====
// 世界系：x 向右（格），y 向下（格，南为 +y），z 向上（高）。屏幕 up = -y*sin + z*cos。
// 对每个屏幕像素，从最高处沿视线向下走，第一次落到地表以下的点就是可见表面；
// 因此遮挡关系是真实的，山坡也可以挡住后面的地面。

// 地形高度（世界格）：基准级 1 记为 0，避免整张图浮在半空
float terrain_z(vec2 cell) {
	return max(elev_field(cell) - 1.0, 0.0) * u_height_scale;
}

vec3 oblique_color(vec2 uv) {
	float pitch = clamp(u_pitch, 0.30, 1.45);
	float sp = sin(pitch);
	float cp = cos(pitch);
	float W = u_map_size.x;
	float H = u_map_size.y;
	float zmax = max((u_elev_max - 1.0) * u_height_scale, 0.4);

	// 视线水平朝向 fd（相机 → 场景）与屏幕右向 rt，都是格空间单位向量。
	// 工具预览 yaw=0：fd=(0,-1)，从南往北看，与旧实现等价；
	// 游戏视图 yaw=3π/4：fd=(-0.707,-0.707)，从东南（地图右下角）看向中心。
	vec2 fd = vec2(-sin(u_view_yaw), cos(u_view_yaw));
	vec2 rt = vec2(-fd.y, fd.x);

	float aspect = max(u_view_size.x, 1.0) / max(u_view_size.y, 1.0);
	float world_w;
	vec2 center;
	if (u_view_cells > 0.5) {
		// 游戏取景：视口宽度覆盖 u_view_cells 格，中心由相机给出
		world_w = u_view_cells;
		center = u_view_center;
	} else {
		// 工具取景：整图铺满，并把"地图 + 最高点"竖直居中（原公式）
		float need_h = H * sp + zmax * cp;
		world_w = max(W, need_h * aspect) * 1.04;
		center = vec2(W * 0.5, H * 0.5 - zmax * cp / (2.0 * sp));
	}
	float world_h = world_w / aspect;
	float sx = (uv.x - 0.5) * world_w;
	float sy = (0.5 - uv.y) * world_h;         // 屏幕向上为正

	float cot = cp / sp;
	// 屏幕中心对应 center 这个地面点；沿 fd 退 sy/sp 格就是该像素在 z=0 的落点
	vec2 base = center + rt * sx + fd * (sy / sp);
	float step_z = max(zmax / 46.0, 0.02);
	float z = zmax;
	float prev_z = zmax + step_z;
	bool hit = false;
	bool wall = false;
	for (int i = 0; i < 48; i++) {
		vec2 p = base - fd * (z * cot);
		if (p.x >= 0.0 && p.x < W && p.y >= 0.0 && p.y < H) {
			if (z <= terrain_z(p)) {
				hit = true;
				break;
			}
		} else if (p.y < 0.0 || p.x < 0.0) {
			// 越过远端边缘（工具：北；游戏：北/西）：低于边缘地表 = 切面侧壁，否则是天空
			vec2 edge = clamp(p, vec2(0.0), vec2(W - 0.001, H - 0.001));
			if (z <= terrain_z(edge) && z > 0.001) wall = true;
			break;
		}
		if (z <= 0.0) break;
		prev_z = z;
		z -= step_z;
	}
	if (wall) {
		// 游戏视图不再画地图边缘的假切面：那两块向外拉的大三角只是把边缘格
		// 拉成一面墙，除了在工具整图预览里看边界，没有存在必要。
		if (u_view_cells > 0.5) {
			return mix(u_sky_bottom, u_sky_top, clamp(uv.y, 0.0, 1.0));
		}
		vec2 edge = clamp(base - fd * (z * cot), vec2(0.0), vec2(W - 0.001, H - 0.001));
		vec3 wcol = shade_surface(edge) * vec3(0.50, 0.47, 0.42);
		float top = max(terrain_z(edge), 0.001);
		wcol *= mix(0.62, 1.0, clamp(z / top, 0.0, 1.0));   // 越靠底越暗
		float wfog = smoothstep(0.0, 1.0, clamp((H - edge.y) / H, 0.0, 1.0)) * 0.20;
		return mix(wcol, u_sky_bottom, wfog);
	}
	vec2 surf = base;
	if (hit) {
		float lo = z;        // 已在地表以下
		float hi = prev_z;   // 仍在地表以上
		for (int k = 0; k < 4; k++) {
			float mid = (lo + hi) * 0.5;
			vec2 mp = base - fd * (mid * cot);
			if (mid <= terrain_z(clamp(mp, vec2(0.0), vec2(W - 0.001, H - 0.001)))) lo = mid;
			else hi = mid;
		}
		surf = base - fd * (lo * cot);
	}
	// 没被地形挡住时，射线一定落到 z=0 的地面 —— 不能因为步进恰好停在 0 上方就返回天空。
	// （旧实现靠浮点误差刚好命中平地，地图换尺寸/换最高点就可能整片平地变天空。）
	if (surf.x < 0.0 || surf.x >= W || surf.y < 0.0 || surf.y >= H) {
		return mix(u_sky_bottom, u_sky_top, clamp(uv.y, 0.0, 1.0));
	}
	vec3 col = shade_surface(surf);
	// 远景薄雾：越靠北（画面深处）越淡，给纵深
	float fog = smoothstep(0.0, 1.0, clamp((H - surf.y) / H, 0.0, 1.0)) * 0.30;
	return mix(col, u_sky_bottom, fog);
}


void fragment() {
	if (u_oblique > 0.5) {
		COLOR = vec4(oblique_color(UV), 1.0);
	} else {
		COLOR = vec4(shade_surface(UV * u_map_size), 1.0);
	}
}
