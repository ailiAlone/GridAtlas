shader_type canvas_item;
// RenderView 成品渲染着色器。数据每格一像素，逐像素程序化着色。
//
// 机制总览：
//  0) 连续水深场：把水域数据当标量做平滑插值，岸线/浅深分界由【等值线】决定，
//     所以边界会斜穿格子、自然弯曲 —— 这是消除"方格阶梯"的根本手段。
//  1) 陆地类型仍是离散格（分类数据无法插值），只在陆陆交界处做按亲和度的窄过渡。
//  2) 分材质结构图案：硬边碎块/团簇，频率压在 0.3~2 周期/格。
//  3) 微凹凸光照 + 高程浮雕：固定光源（左上），让表面有立体感。
//  4) 低频生物群系色差：避免大片纯色。
//  5) 交界折痕：一条窄暗线，读起来是物理接缝而不是颜色渐变。
//  6) 细颗粒只做极低幅度抖动，绝不主导画面。

uniform sampler2D u_data : filter_nearest, repeat_disable;     // R=陆地 G=水域 B=道路 A=流向
uniform sampler2D u_elev : filter_linear, repeat_disable;      // R=高程（线性插值→平滑起伏）
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

// 平滑高程（线性插值）：用于起伏光照，避免一格一台阶
float elev_smooth(vec2 cf) {
	return texture(u_elev, (cf - vec2(0.5)) / u_map_size).r * 255.0;
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
		// 沼泽：大块暗色水洼 + 苔藓亮边
		float pool = smoothstep(0.46, 0.58, n1);
		float rim = smoothstep(0.40, 0.46, n1) - pool;
		return mix(1.04, 0.78, pool) + 0.05 * rim;
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

void fragment() {
	vec2 cf = UV * u_map_size;

	// ---- 0) 连续水深场（宽核平滑）+ 等值线定岸：岸线因此是平滑曲线，不再是方格骨架 ----
	float wfield = water_blur(cf);
	// 低频噪声扰动等值线：给出湾岬与参差；幅度必须远小于 1 水深档
	float coast_noise = (fbm(cf * 0.33 + vec2(2.3, 6.1)) - 0.5)
		+ (vnoise(cf * 0.90 + vec2(7.7, 1.2)) - 0.5) * 0.5;
	wfield += coast_noise * u_coast_warp * 0.35;
	// 浅→深同样按亲和度决定过渡宽度（矩阵里"浅↔深"设 1.0 就是宽渐变）
	float dw = mix(0.08, 0.45, pair_affinity(7.0, 8.0));
	float water_cover = smoothstep(0.46, 0.54, wfield);
	float deep_cover = smoothstep(1.5 - dw, 1.5 + dw, wfield);
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
	// 叠一点高频噪声让边界参差（对应面板上的"边界打散幅度"）
	float Lf = land_blur(cf) + (vnoise(cf * 1.6 + vec2(4.4, 8.8)) - 0.5) * u_edge_jitter * 0.06;
	float t = 0.0;
	if (abs(other_id - base_id) > 0.01) {
		t = clamp((Lf - base_id) / (other_id - base_id), 0.0, 1.0);
	}
	float aff = abs(other_id - base_id) > 0.01 ? pair_affinity(base_id, other_id) : 0.0;
	float bh = mix(max(u_band_hard, 0.04), max(u_band_soft, u_band_hard), aff) * 0.5;
	float mixw = smoothstep(0.5 - bh, 0.5 + bh, t);
	vec3 col = mix(table_color(int(base_id)) * tint, table_color(int(other_id)) * tint, mixw);
	float crease = 1.0 - smoothstep(0.0, max(u_crease_width, 0.02), abs(t - 0.5));
	col *= 1.0 - crease * u_crease_dark * (1.0 - aff * 0.7) * (1.0 - water_cover);
	float pattern_id = mixw > 0.5 ? other_id : base_id;

	// ---- 2) 分材质结构图案 + 微凹凸光照 ----
	vec2 pf = cf * u_texture_frequency;
	float p0 = material_pattern(pf, pattern_id);
	float pdx = material_pattern(pf + vec2(0.40, 0.0), pattern_id);
	float pdy = material_pattern(pf + vec2(0.0, 0.40), pattern_id);
	col *= 1.0 + (p0 - 1.0) * u_texture_strength;
	vec2 grad = vec2(pdx - p0, pdy - p0) * u_texture_strength * 2.2;
	float bump = 1.0 - (grad.x + grad.y) * u_bump * 0.35;
	col *= mix(1.0, clamp(bump, 0.90, 1.10), 1.0 - water_cover);

	// ---- 4) 水面：由水深场合成浅/深两色，再做波纹与岸线泡沫 ----
	vec3 shallow_c = table_color(7) * tint;
	vec3 deep_c = table_color(8) * tint;
	col = mix(col, shallow_c, water_cover);
	col = mix(col, deep_c, deep_cover);
	col *= 1.0 - 0.06 * clamp(wfield - 1.0, 0.0, 1.0);   // 越深越沉

	// ---- 5) 高程浮雕：平滑高程求坡度，光固定左上 ----
	vec2 stp = vec2(max(u_elev_shadow_width, 0.05) * 0.9, 0.0);
	float h0 = elev_smooth(cf);
	float hx = elev_smooth(cf + stp);
	float hy = elev_smooth(cf + stp.yx);
	float slope = ((h0 - hx) + (h0 - hy)) * 0.5;
	float lit = 1.0 + slope * u_relief * u_elev_shadow * 3.0 + max(slope, 0.0) * u_elev_rim * 3.0;
	col *= mix(1.0, clamp(lit, 0.35, 2.0), 1.0 - waterness);
	col *= 1.0 + (h0 - 1.0) * u_elev_bright;

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
		float amp = u_ripple_strength * (0.85 + 0.75 * deep_cover);   // 深水浪更大
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

	COLOR = vec4(col, 1.0);
}
