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

float vnoise(vec2 p) {
	return texture(u_noise, p).r;
}

float fbm(vec2 p) {
	return vnoise(p) * 0.5 + vnoise(p * 2.03 + vec2(0.33, 0.71)) * 0.3 + vnoise(p * 4.13 + vec2(0.71, 0.33)) * 0.2;
}

// ===== 分材质结构图案 =====
// 用硬边阈值造碎块/团簇，而不是大范围软渐变；频率压在 0.3~2 周期/格。
float material_pattern(vec2 p, float id) {
	float n1 = fbm(p * 0.55);
	float n2 = vnoise(p * 1.15 + vec2(3.7, 1.9));
	if (id < 1.5) {
		// 草地：硬边草簇 + 稀疏深色簇点 + 纵向草束
		float clump = smoothstep(0.47, 0.53, n1);
		float specks = smoothstep(0.80, 0.90, vnoise(p * 3.1 + vec2(5.3, 1.7)));
		float stroke = vnoise(vec2(p.x * 0.55, p.y * 2.0) + vec2(7.3, 2.1));
		return 0.92 + 0.13 * clump - 0.07 * specks + 0.04 * stroke;
	}
	if (id < 2.5) {
		// 沙地：锐化的沙纹带
		float ripple = 0.5 + 0.5 * sin(p.x * 2.1 + n2 * 3.0);
		float band = smoothstep(0.55, 0.85, ripple);
		return 0.955 + 0.075 * band + 0.025 * n2;
	}
	if (id < 3.5) {
		// 荒地：碎块板 + 深色裂缝
		float plate = smoothstep(0.46, 0.54, n2);
		float seam = 1.0 - smoothstep(0.0, 0.06, abs(n2 - 0.5));
		return 0.90 + 0.16 * plate - 0.12 * seam + 0.04 * n1;
	}
	if (id < 4.5) {
		// 雪地：柔和起伏 + 极轻微雪垄
		float drift = smoothstep(0.55, 0.75, n1);
		return 1.0 + 0.045 * (drift - 0.5) + 0.02 * (n2 - 0.5);
	}
	if (id < 5.5) {
		// 沼泽：硬边水洼（暗）+ 苔藓亮边
		float pool = smoothstep(0.50, 0.56, n2);
		float rim = smoothstep(0.44, 0.50, n2) - pool;
		return mix(1.05, 0.74, pool) + 0.06 * rim + 0.03 * (n1 - 0.5);
	}
	if (id < 6.5) {
		// 冰面：大块球面 + 细裂纹
		float plate = smoothstep(0.46, 0.52, n1);
		float crack = 1.0 - smoothstep(0.0, 0.035, abs(n2 - 0.5));
		return 0.975 + 0.07 * plate + 0.12 * crack;
	}
	return 1.0;
}

float soft_box(vec2 p, vec2 mn, vec2 mx, float e) {
	vec2 lo = smoothstep(mn - e, mn + e, p);
	vec2 hi = 1.0 - smoothstep(mx - e, mx + e, p);
	return lo.x * hi.x * lo.y * hi.y;
}

void fragment() {
	vec2 cf = UV * u_map_size;
	vec2 dirs[4] = vec2[](vec2(1.0, 0.0), vec2(-1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, -1.0));

	// ---- 0) 连续水深场：岸线与浅深分界都是它的等值线 ----
	vec2 ip = floor(cf);
	vec2 fp = cf - ip;
	vec2 iq = fp * fp * (3.0 - 2.0 * fp);   // 平滑插值，让等值线在格内转角处斜切
	vec4 d00 = cell_data(ip);
	vec4 d10 = cell_data(ip + vec2(1.0, 0.0));
	vec4 d01 = cell_data(ip + vec2(0.0, 1.0));
	vec4 d11 = cell_data(ip + vec2(1.0, 1.0));
	float wfield = mix(mix(d00.g, d10.g, iq.x), mix(d01.g, d11.g, iq.x), iq.y) * 255.0;
	// 噪声扰动等值线（幅度必须 < 0.3 水深档，否则会把整格浅水翻成陆地）
	float coast_noise = (fbm(cf * 0.42 + vec2(2.3, 6.1)) - 0.5) * 1.3
		+ (vnoise(cf * 1.15 + vec2(7.7, 1.2)) - 0.5) * 0.9;
	wfield += coast_noise * u_coast_warp * 0.22;
	float water_cover = smoothstep(0.42, 0.62, wfield);
	float deep_cover = smoothstep(1.34, 1.66, wfield);
	float waterness = max(water_cover, deep_cover);

	// ---- 1) 陆地类型（离散格）+ 低频生物群系色差 ----
	vec2 warp = (vec2(vnoise(cf * 0.90 + vec2(3.3, 0.7)), vnoise(cf * 0.90 + vec2(6.1, 5.2))) - 0.5)
		* (u_coast_warp * 0.35)
		+ (vec2(vnoise(cf * 1.80 + vec2(0.5, 5.7)), vnoise(cf * 1.80 + vec2(4.9, 1.3))) - 0.5)
		* (u_edge_jitter * 0.08);
	vec2 wpos = cf + warp;
	vec2 wcell = floor(wpos);
	vec2 winc = wpos - wcell;
	float land_id = cell_land(wcell);

	float bio = fbm(cf * 0.16 + vec2(11.3, 5.7));
	float bio2 = fbm(cf * 0.11 + vec2(2.1, 9.4));
	vec3 tint = vec3(1.0 + (bio - 0.5) * u_biome,
		1.0 + (bio2 - 0.5) * u_biome * 0.7,
		1.0 - (bio - 0.5) * u_biome * 0.8);
	vec3 col = table_color(int(land_id)) * tint;

	// ---- 2) 分材质结构图案 + 微凹凸光照 ----
	vec2 pf = cf * u_texture_frequency;
	float p0 = material_pattern(pf, land_id);
	float pdx = material_pattern(pf + vec2(0.22, 0.0), land_id);
	float pdy = material_pattern(pf + vec2(0.0, 0.22), land_id);
	col *= 1.0 + (p0 - 1.0) * u_texture_strength;
	vec2 grad = vec2(pdx - p0, pdy - p0) * u_texture_strength * 8.0;
	float bump = 1.0 - (grad.x + grad.y) * u_bump;   // 光从左上：右下坡变暗
	col *= mix(1.0, clamp(bump, 0.55, 1.5), 1.0 - water_cover);

	// ---- 3) 陆陆交界：按亲和度的窄过渡 + 交界折痕（水面以下不做） ----
	if (water_cover < 0.85) {
		vec3 acc = vec3(0.0);
		float accw = 0.0;
		float crease = 0.0;
		for (int i = 0; i < 4; i++) {
			float nid = cell_land(wcell + dirs[i]);
			if (abs(nid - land_id) > 0.01) {
				float aff = pair_affinity(land_id, nid);
				float band = mix(max(u_band_hard, 0.04), max(u_band_soft, u_band_hard), aff);
				float d = 0.5 + 0.5 * dot(dirs[i], winc * 2.0 - 1.0);
				float nv = fbm(cf * 2.2 + dirs[i] * 23.0);
				float t = smoothstep(1.0 - band, 1.0, d + (nv - 0.5) * band * 0.9);
				acc += table_color(int(nid)) * tint * t;
				accw += t;
				crease += smoothstep(1.0 - max(u_crease_width, 0.01), 1.0, d) * (1.0 - aff * 0.7);
			}
		}
		if (accw > 0.0) {
			col = mix(col, acc / accw, min(accw, 1.0));
		}
		col *= 1.0 - min(crease, 1.0) * u_crease_dark;
	}

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

	// ---- 6) 水面动效：波纹沿流向 + 岸线泡沫 ----
	if (waterness > 0.01) {
		float flow_id = cell_data(wcell).a * 255.0;
		vec2 drift = flow_vec(flow_id) * u_time * u_flow_speed;
		float r1 = vnoise(cf * u_ripple_frequency * 1.4 - drift);
		float r2 = vnoise(cf * u_ripple_frequency * 3.2 + drift * 1.7 - vec2(0.0, u_time * u_ripple_speed * 2.0));
		float rip = r1 * 0.6 + r2 * 0.4;
		vec3 water = col * (1.0 - u_ripple_strength * 0.5 + u_ripple_strength * rip);
		water += vec3(smoothstep(0.75, 1.0, vnoise(cf * 11.0 - drift * 2.2))) * 0.08;
		// 岸线泡沫：贴着 water_cover ≈ 0.5 的一条带，水侧更亮
		float dshore = abs(wfield - 0.55);
		float foam_mask = 1.0 - smoothstep(0.02, 0.02 + 0.55 * max(u_foam_width, 0.1), dshore);
		foam_mask *= smoothstep(0.45, 0.62, water_cover);
		float foam = smoothstep(0.25, 0.75, foam_mask * (0.55 + 0.9 * vnoise(cf * 6.0 + vec2(0.0, u_time * 0.8))));
		water = mix(water, table_color(12), foam * u_foam_strength);
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
