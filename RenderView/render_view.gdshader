shader_type canvas_item;
// RenderView 成品渲染着色器。数据每格一像素，逐像素程序化着色。
//
// 机制总览：
//  0) 连续水深场：把水域数据当标量做平滑插值，岸线/浅深分界由【等值线】决定，
//     所以边界会斜穿格子、自然弯曲 —— 这是消除"方格阶梯"的根本手段。
//  1) 陆地类型仍是离散格（分类数据无法插值），只在陆陆交界处做按亲和度的窄过渡。
//     例外是沼泽↔草地：它不是"两种地的分界"，而是"越来越湿"，所以用一张连续沼泽场
//     驱动底色与水洼密度（见 2b），边界因此既不是格子阶梯，也不是一条渐变线。
//  2) 分材质结构图案：硬边碎块/团簇，频率压在 0.3~2 周期/格。
//  3) 微凹凸光照 + 高程浮雕：固定光源（左上），让表面有立体感。
//  4) 低频生物群系色差：避免大片纯色。
//  5) 交界折痕：一条窄暗线，读起来是物理接缝而不是颜色渐变。
//  6) 细颗粒只做极低幅度抖动，绝不主导画面。
//  7) 斜角视图：同一套地表着色函数，改为从正交斜视方向对高度场做射线步进，
//     取第一次命中的地表再着色 —— 遮挡、坡面、边缘侧壁都是真的。

uniform sampler2D u_data : filter_nearest, repeat_disable;     // R=陆地 G=水域 B=道路 A=流向
uniform sampler2D u_elev : filter_linear, repeat_disable;      // R=高程（原始单位，1 级 = 4 单位）
uniform sampler2D u_elev_smooth : filter_linear, repeat_disable; // R=平滑高程（0..16 级）
uniform sampler2D u_noise : filter_linear, repeat_enable;      // 白噪声，线性采样当值噪声
uniform sampler2D u_colors : filter_nearest, repeat_disable;   // 13×1 颜色表
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
uniform float u_road_width = 0.30;
uniform float u_road_softness = 0.06;
uniform float u_road_texture = 0.24;
// ---- 高程 ----
uniform float u_elev_bright = 0.045;
uniform float u_elev_shadow = 0.16;
uniform float u_elev_rim = 0.05;
uniform float u_elev_shadow_width = 0.30;
// ---- 斜角视图（正交、从南向北俯看） ----
uniform float u_oblique = 0.0;          // 0 = 俯视，1 = 斜角
uniform float u_pitch = 0.93;           // 俯仰角（弧度），约 53°
uniform float u_height_scale = 2.5;     // 每级高程 = 多少世界格高
uniform float u_elev_max = 4.0;         // 全图最高高程（级），GDScript 侧更新
uniform vec2 u_view_size = vec2(1024.0, 1024.0);
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
		// 草地：大块草簇 + 低频纵向草束（不做逐像素散点，那是雪花）
		float clump = smoothstep(0.42, 0.62, n1);
		float stroke = vnoise(vec2(p.x * 0.45, p.y * 1.6) + vec2(7.3, 2.1));
		return 0.975 + 0.045 * clump + 0.025 * stroke;
	}
	if (id < 2.5) {
		// 沙地：沙纹带（低频）
		float ripple = 0.5 + 0.5 * sin(p.x * 1.7 + n2 * 2.4);
		float band = smoothstep(0.50, 0.90, ripple);
		return 0.955 + 0.06 * band + 0.02 * n2;
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

float soft_box(vec2 p, vec2 mn, vec2 mx, float e) {
	vec2 lo = smoothstep(mn - e, mn + e, p);
	vec2 hi = 1.0 - smoothstep(mx - e, mx + e, p);
	return lo.x * hi.x * lo.y * hi.y;
}

// 定向波列：正弦相位 + 两级噪声扭曲（否则是完美平行的直线条纹，很假）
float wave_train(vec2 p, vec2 dir, float freq, float speed, float t) {
	float phase = dot(p, dir) * freq * 6.2831853 - t * speed;
	phase += (vnoise(p * 0.45 + dir * 7.0) - 0.5) * 6.0;   // 大尺度弯曲
	phase += (vnoise(p * 1.40 + dir * 3.0) - 0.5) * 2.5;   // 细碎扰动
	return sin(phase);
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
	float dw = mix(0.10, 0.45, pair_affinity(7.0, 8.0));

	// 陆地类型场（提前取用，岸线潮汐需要它判断"沙地在场"）
	float Lf = land_blur(cf) + (vnoise(cf * 1.6 + vec2(4.4, 8.8)) - 0.5) * u_edge_jitter * 0.06;

	// 沙地↔浅水且高程相同的岸段：岸线来回进退（潮汐）
	// 三个连续遮罩相乘：沙地在场 × 浅水在场 × 高程无落差
	float e0 = elev_smooth(cf);
	float ex = elev_smooth(cf + vec2(0.60, 0.0));
	float ey = elev_smooth(cf + vec2(0.0, 0.60));
	float egrad = abs(ex - e0) + abs(ey - e0);
	float same_elev = 1.0 - smoothstep(0.15, 0.55, egrad);
	// 以"沙地"编号 2 为中心的窄带（不能用 smoothstep(下限,上限,Lf)：那样冰面/雪地/荒地都会命中）
	float sand_side = exp(-pow((Lf - 2.0) / 0.55, 2.0));
	float shallow_side = smoothstep(0.15, 0.45, wfield) * (1.0 - smoothstep(1.15, 1.55, wfield));
	float shore_tide = sand_side * shallow_side * same_elev;
	float shore_phase = sin(u_time * 0.52 * u_tide_frequency + dot(cf, vec2(0.80, 0.60))) * (0.25 * u_tide_amplitude)
		+ sin(u_time * 0.29 * u_tide_frequency - dot(cf, vec2(0.30, 0.90)) + 2.1) * (0.15 * u_tide_amplitude);

	float water_cover = smoothstep(0.46, 0.54, wfield + shore_tide * shore_phase);
	float deep_cover = smoothstep(1.5 - dw, 1.5 + dw, wfield + deep_wobble + tide);
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

	// ---- 2) 分材质结构图案 + 微凹凸光照 ----
	vec2 pf = cf * u_texture_frequency;
	float p0 = material_pattern(pf, pattern_id);
	// 过渡带里两种纹理按场混合，否则草丛的纵向纹理与水洼的纹理会在格子边界上突然换手
	if (marsh > 0.004 && swamp_zone > 0.5 && marsh < 0.996) {
		p0 = mix(material_pattern(pf, 1.0), material_pattern(pf, 5.0), marsh);
	}
	float pdx = material_pattern(pf + vec2(0.40, 0.0), pattern_id);
	float pdy = material_pattern(pf + vec2(0.0, 0.40), pattern_id);
	col *= 1.0 + (p0 - 1.0) * u_texture_strength;
	vec2 grad = vec2(pdx - p0, pdy - p0) * u_texture_strength * 2.2;
	float bump = 1.0 - (grad.x + grad.y) * u_bump * 0.35;
	col *= mix(1.0, clamp(bump, 0.90, 1.10), 1.0 - water_cover);

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

	// ---- 5) 高程浮雕：平滑高度场 → 法线 → 固定左上光 ----
	// 平地的法线是竖直的，读数归一为 1；迎光坡变亮、背光坡变暗，由此读出坡向和体量。
	float d = max(u_elev_shadow_width, 0.10) * 1.6;
	float h0 = elev_relief(cf);
	float hx = elev_relief(cf + vec2(d, 0.0));
	float hy = elev_relief(cf + vec2(0.0, d));
	vec2 g = vec2(hx - h0, hy - h0) / d;        // 梯度（高度/格）
	float k = max(u_relief, 0.05) * 1.4;        // 垂直夸张
	vec3 nrm = normalize(vec3(-g.x * k, -g.y * k, 1.0));
	vec3 lgt = normalize(vec3(-0.62, -0.62, 0.48));   // 固定左上
	float ndl = dot(nrm, lgt);
	// 山体：陡坡露岩、高处缓坡积雪。用世界坡度（梯度 × 垂直比例）判定。
	float land_mask = 1.0 - waterness;
	// 用原始坡度（级/格）而不是垂直夸张后的坡度：换"斜角高度"不会改变岩石分布
	float slope = length(g);
	float rock = smoothstep(0.52, 1.05, slope) * land_mask;
	float snow_line = max(4.0, u_elev_max * 0.62);
	// 雪线不是一条等高线：用低频噪声把阈值打散成斑块
	float snow_n = (fbm(cf * 0.55 + vec2(5.3, 2.7)) - 0.5) * 2.4;
	float snow = smoothstep(snow_line, snow_line + 1.0, h0 + snow_n)
		* (1.0 - smoothstep(0.26, 0.46, slope)) * land_mask;
	// 以平地（ndl = lgt.z）为零点做对称的明暗：迎光 +，背光 −，
	// 不用 (ndl-1) 那种写法 —— 背光侧会一直压到黑，坡面就变成一条深沟。
	float shade = clamp(ndl - lgt.z, -0.45, 0.55);
	float lit = 1.0 + shade * (u_elev_shadow * 2.4);
	lit += max(shade, 0.0) * u_elev_rim * 1.5;   // 迎光坡的窄高光
	float lit_c = clamp(lit, 0.62, 1.32);
	col *= mix(1.0, lit_c, land_mask);
	// 暗部略偏冷、亮部略偏暖：比单纯压暗更像受光，也不容易读成脏污
	col *= mix(vec3(0.97, 0.995, 1.03), vec3(1.02, 1.0, 0.97), clamp(shade * 2.0 + 0.5, 0.0, 1.0));
	// 高度提亮按全图最高点归一，否则高山会一路加到过曝
	float hrel = clamp((h0 - 1.0) / max(u_elev_max - 1.0, 1.0), 0.0, 1.0);
	col *= 1.0 + hrel * u_elev_bright * 2.0;
	// 山体覆盖放在打光之后：岩石/雪帽用同一个 lit 明暗，但不再叠加高度提亮
	if (rock > 0.002 || snow > 0.002) {
		float rock_grain = 0.86 + 0.26 * fbm(cf * 1.25 + vec2(3.7, 8.1));
		vec3 rock_c = table_color(13) * rock_grain * clamp(lit, 0.62, 1.32);
		vec3 snow_c = table_color(14) * clamp(lit, 0.78, 1.16);
		col = mix(col, rock_c, rock * 0.85);
		col = mix(col, snow_c, snow * 0.72);
	}

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
		// 岸线泡沫
		float dshore = abs(wfield - 0.55);
		float foam_mask = 1.0 - smoothstep(0.02, 0.02 + 0.18 * max(u_foam_width, 0.1), dshore);
		foam_mask *= smoothstep(0.45, 0.62, water_cover);
		float foam = smoothstep(0.25, 0.75, foam_mask * (0.55 + 0.9 * vnoise(cf * 6.0 + vec2(0.0, u_time * 0.8))));
		water = mix(water, table_color(12), foam * u_foam_strength * 0.6);
		col = mix(col, water, clamp(waterness, 0.0, 1.0));
	}

	// ---- 7) 道路：不参与边界扭曲，路带笔直并与相邻道路格连接 ----
	vec2 dcell = floor(cf);
	vec2 dinc = cf - dcell;
	float road_id = cell_data(dcell).b * 255.0;
	if (road_id > 0.5) {
		bool cE = cell_data(dcell + vec2(1.0, 0.0)).b * 255.0 > 0.5;
		bool cW = cell_data(dcell + vec2(-1.0, 0.0)).b * 255.0 > 0.5;
		bool cS = cell_data(dcell + vec2(0.0, 1.0)).b * 255.0 > 0.5;
		bool cN = cell_data(dcell + vec2(0.0, -1.0)).b * 255.0 > 0.5;
		vec2 rp = dinc + (vec2(vnoise(cf * 3.3), vnoise(cf * 3.3 + vec2(4.1, 8.2))) - 0.5) * 0.05;
		float w = u_road_width;
		float e = max(u_road_softness, 0.01);
		float m = soft_box(rp, vec2(0.5 - w), vec2(0.5 + w), e);
		if (cE) m = max(m, soft_box(rp, vec2(0.5 - w, 0.5 - w), vec2(1.0, 0.5 + w), e));
		if (cW) m = max(m, soft_box(rp, vec2(0.0, 0.5 - w), vec2(0.5 + w, 0.5 + w), e));
		if (cS) m = max(m, soft_box(rp, vec2(0.5 - w, 0.5 - w), vec2(0.5 + w, 1.0), e));
		if (cN) m = max(m, soft_box(rp, vec2(0.5 - w, 0.0), vec2(0.5 + w, 0.5 + w), e));
		vec3 rcol = table_color(8 + int(clamp(road_id, 1.0, 3.0)));
		float grain = vnoise(cf * 9.0) * 0.6 + vnoise(cf * 3.5 + vec2(2.0, 6.0)) * 0.4;
		rcol *= 1.0 - u_road_texture * 0.5 + u_road_texture * grain;
		col = mix(col, rcol, m);
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

	// 视野：宽度取整张地图，高度按视口比例；含地形高度的总高度也尽量铺满
	float aspect = max(u_view_size.x, 1.0) / max(u_view_size.y, 1.0);
	float need_h = H * sp + zmax * cp;
	float world_w = max(W, need_h * aspect) * 1.04;
	float world_h = world_w / aspect;
	float sx = (uv.x - 0.5) * world_w + W * 0.5;
	float sy = (0.5 - uv.y) * world_h - (H * sp - zmax * cp) * 0.5;

	float cot = cp / sp;              // 每上升 1 格高度，射线在 y 方向后退多少格
	float base_y = -sy / sp;          // 该像素对应的 z=0 地面点
	float step_z = max(zmax / 22.0, 0.05);
	float z = zmax;
	float prev_z = zmax + step_z;
	bool hit = false;
	bool wall = false;                // 命中地图边缘的侧壁
	for (int i = 0; i < 24; i++) {
		float y = base_y + z * cot;
		if (sx >= 0.0 && sx < W) {
			if (y >= 0.0 && y < H) {
				if (z <= terrain_z(vec2(sx, y))) {
					hit = true;
					break;
				}
			} else if (y < 0.0) {
				// 越过北边缘：如果低于该处地表，看到的是切面侧壁；否则整条射线都在空中
				if (z <= terrain_z(vec2(sx, 0.0)) && z > 0.001) wall = true;
				break;
			}
		} else if (y >= 0.0 && y < H) {
			// 东西边缘同理
			float ex = clamp(sx, 0.0, W - 0.001);
			if (z <= terrain_z(vec2(ex, y)) && z > 0.001) wall = true;
			break;
		}
		if (z <= 0.0) break;
		prev_z = z;
		z -= step_z;
	}
	if (wall) {
		float ex = clamp(sx, 0.0, W - 0.001);
		float ey = clamp(base_y + z * cot, 0.0, H - 0.001);
		vec3 wcol = shade_surface(vec2(ex, ey)) * vec3(0.50, 0.47, 0.42);
		float top = max(terrain_z(vec2(ex, ey)), 0.001);
		wcol *= mix(0.62, 1.0, clamp(z / top, 0.0, 1.0));   // 越靠底越暗
		float wfog = smoothstep(0.0, 1.0, clamp((H - ey) / H, 0.0, 1.0)) * 0.20;
		return mix(wcol, u_sky_bottom, wfog);
	}
	float hy = 0.0;
	if (hit) {
		float lo = z;        // 已在地表以下
		float hi = prev_z;   // 仍在地表以上
		for (int k = 0; k < 4; k++) {
			float mid = (lo + hi) * 0.5;
			float my = base_y + mid * cot;
			if (mid <= terrain_z(vec2(sx, clamp(my, 0.0, H - 0.001)))) lo = mid;
			else hi = mid;
		}
		hy = base_y + lo * cot;
	}

	vec3 sky = mix(u_sky_bottom, u_sky_top, clamp(uv.y, 0.0, 1.0));
	if (!hit || hy < 0.0 || hy >= H) return sky;
	vec3 col = shade_surface(vec2(sx, hy));
	// 远景薄雾：越靠北（画面深处）越淡，给纵深
	float fog = smoothstep(0.0, 1.0, clamp((H - hy) / H, 0.0, 1.0)) * 0.20;
	return mix(col, u_sky_bottom, fog);
}


void fragment() {
	if (u_oblique > 0.5) {
		COLOR = vec4(oblique_color(UV), 1.0);
	} else {
		COLOR = vec4(shade_surface(UV * u_map_size), 1.0);
	}
}
