shader_type canvas_item;
render_mode blend_mix, unshaded;
// 2.5D 立牌（占位美术）：角色 / 树 / 灌木 / 石堆 / 木屋 / 塔楼 + 高度场遮挡。
//
// 遮挡规则（由 u_fade 区分）：
//   角色 u_fade=0.38 → 被山挡住的部分半透明（玩家要看得见自己）
//   静态物件 u_fade=0.00 → 被山挡住就完全消失（不需要透视揭示）
//
// 判定：从脚的基格出发，沿"朝相机"的水平方向取样平滑高程场。
// 该处地表若高于"视线在同样水平距离上的高度"，这一片就是被挡住的。
// 视线高度 = 立牌上的世界高度 + 水平距离 · tan(俯角)。

uniform sampler2D u_elev_smooth : filter_linear, repeat_disable;
uniform vec2 u_map_size = vec2(64.0);
uniform float u_elev_smooth_max = 32.0;
uniform float u_height_scale = 2.5;
uniform float u_pitch = 0.785398;
uniform vec2 u_view_dir = vec2(0.7071, 0.7071);   // 立牌 → 相机 的水平方向
uniform vec2 u_base_cell = vec2(0.0);             // 脚底所在的格坐标（0..map_size）
uniform float u_base_z = 0.0;                     // 脚底的地表高度（世界格）
uniform vec2 u_art_size = vec2(1.0, 2.2);         // 立牌尺寸（格，屏幕上）
uniform float u_art_height = 3.11;                // 立牌顶端代表的世界高度（= 高 / cos(俯角)）
uniform float u_fade = 0.38;                      // 被挡时保留的不透明度
uniform float u_kind = 0.0;                       // 0角色 1树 2灌木 3石堆 4木屋 5塔楼

float fill(float d, float aa) {
	return 1.0 - smoothstep(-aa, aa, d);
}

float sd_capsule(vec2 p, vec2 a, vec2 b, float r) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h) - r;
}

float sd_box(vec2 p, vec2 c, vec2 h) {
	vec2 d = abs(p - c) - h;
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float elev_field_at(vec2 p) {
	return texture(u_elev_smooth, (p - 0.5) / u_map_size).r * u_elev_smooth_max;
}

float occlusion(vec2 base_cell, float world_z) {
	float tanp = tan(u_pitch);
	float occl = 0.0;
	for (int i = 1; i <= 10; i++) {
		float d = float(i) * 0.55;
		vec2 p = base_cell + u_view_dir * d;
		float tz = max(elev_field_at(p) - 1.0, 0.0) * u_height_scale;
		float rayz = world_z + d * tanp;
		occl = max(occl, smoothstep(0.02, 0.22, tz - rayz));
	}
	return occl;
}

void fragment() {
	vec2 q = (UV - vec2(0.5, 1.0)) * u_art_size;   // 脚底为原点，y 向上为负
	float aa = max(fwidth(q.x), 0.003) * 1.2;

	vec3 col = vec3(0.0);
	float a = 0.0;

	// 影子：画在脚下，不随地形起伏，但会被山一起挡住
	vec2 shr = vec2(0.46, 0.19);
	if (u_kind > 0.5) shr = vec2(0.58, 0.22);    // 树
	if (u_kind > 1.5) shr = vec2(0.55, 0.20);    // 灌木
	if (u_kind > 2.5) shr = vec2(0.55, 0.18);    // 石堆
	if (u_kind > 3.5) shr = vec2(1.25, 0.38);    // 木屋
	if (u_kind > 4.5) shr = vec2(0.55, 0.24);    // 塔楼
	float sh = 1.0 - smoothstep(-0.20, 0.20, length(q / shr) - 1.0);
	col = vec3(0.045, 0.06, 0.05);
	a = sh * 0.30;

	if (u_kind < 0.5) {
		// ---- 角色：兜帽斗篷 + 腰带，深色描边保证在草地/水边都能读出来 ----
		float body_d = sd_capsule(q, vec2(0.0, -1.38), vec2(0.0, -0.38), 0.29);
		float body_edge = fill(body_d + 0.024, aa);
		col = mix(col, vec3(0.08, 0.11, 0.12), body_edge);
		a = max(a, body_edge);
		float body = fill(body_d, aa);
		col = mix(col, vec3(0.17, 0.36, 0.42), body);
		a = max(a, body);
		float belt = body * (1.0 - smoothstep(0.0, 0.04, abs(q.y + 0.78)));
		col = mix(col, vec3(0.87, 0.72, 0.37), belt);
		a = max(a, belt);
		float hood = fill(length(q - vec2(0.0, -1.72)) - 0.355, aa);
		col = mix(col, vec3(0.10, 0.16, 0.16), hood);
		a = max(a, hood);
		float face = fill(length(q - vec2(0.03, -1.66)) - 0.265, aa);
		col = mix(col, vec3(0.92, 0.80, 0.64), face);
		a = max(a, face);
		float eye = fill(length(q - vec2(0.17, -1.71)) - 0.033, aa);
		col = mix(col, vec3(0.10, 0.09, 0.08), eye);
		a = max(a, eye);
	} else if (u_kind < 1.5) {
		// ---- 树：树干 + 三团树冠 + 左上一块受光面 ----
		float trunk = fill(sd_capsule(q, vec2(0.0, -0.05), vec2(0.0, -1.20), 0.105), aa);
		col = mix(col, vec3(0.28, 0.20, 0.13), trunk);
		a = max(a, trunk);
		float canopy = fill(length(q - vec2(0.0, -1.88)) - 0.55, aa);
		canopy = max(canopy, fill(length(q - vec2(-0.36, -1.58)) - 0.42, aa));
		canopy = max(canopy, fill(length(q - vec2(0.36, -1.62)) - 0.40, aa));
		col = mix(col, vec3(0.14, 0.30, 0.13), canopy);
		a = max(a, canopy);
		float lit = fill(length(q - vec2(-0.18, -2.00)) - 0.31, aa);
		col = mix(col, vec3(0.34, 0.52, 0.22), lit * 0.75);
		a = max(a, canopy);
	} else if (u_kind < 2.5) {
		// ---- 灌木：三团贴地的小叶簇 ----
		float bush = fill(length(q - vec2(-0.30, -0.42)) - 0.40, aa);
		bush = max(bush, fill(length(q - vec2(0.30, -0.40)) - 0.38, aa));
		bush = max(bush, fill(length(q - vec2(0.0, -0.66)) - 0.46, aa));
		col = mix(col, vec3(0.16, 0.32, 0.14), bush);
		a = max(a, bush);
		float lit = fill(length(q - vec2(-0.14, -0.78)) - 0.26, aa);
		col = mix(col, vec3(0.30, 0.48, 0.20), lit * 0.85);
		a = max(a, bush);
	} else if (u_kind < 3.5) {
		// ---- 石堆：两块石头叠在一起，左上受光 ----
		float rock = fill(length(q - vec2(-0.20, -0.34)) - 0.42, aa);
		rock = max(rock, fill(length(q - vec2(0.26, -0.28)) - 0.34, aa));
		col = mix(col, vec3(0.42, 0.43, 0.42), rock);
		a = max(a, rock);
		float lit = fill(length(q - vec2(-0.24, -0.52)) - 0.24, aa);
		col = mix(col, vec3(0.64, 0.65, 0.62), lit * 0.85);
		a = max(a, rock);
	} else if (u_kind < 4.5) {
		// ---- 木屋：正面墙 + 人字屋顶 + 门/窗/烟囱 ----
		float wall_d = sd_box(q, vec2(0.0, -0.95), vec2(1.05, 0.90));
		float wall_edge = fill(wall_d + 0.035, aa);
		col = mix(col, vec3(0.16, 0.12, 0.10), wall_edge);
		a = max(a, wall_edge);
		float wall = fill(wall_d, aa);
		col = mix(col, vec3(0.86, 0.79, 0.64), wall);
		a = max(a, wall);
		// 檐口在 y=-1.82，脊在 y=-2.87：半宽从 1.28 收到 0.10
		float t = clamp((-q.y - 1.82) / 1.05, 0.0, 1.0);
		float halfw = 0.10 + 1.18 * (1.0 - t);
		float roof = smoothstep(-2.90 - aa, -2.90 + aa, q.y)
			* (1.0 - smoothstep(-1.82 - aa, -1.82 + aa, q.y))
			* (1.0 - smoothstep(-aa, aa, abs(q.x) - halfw));
		col = mix(col, vec3(0.63, 0.30, 0.20), roof);
		a = max(a, roof);
		float ridge = roof * (1.0 - smoothstep(0.0, 0.05, abs(q.x)));
		col = mix(col, vec3(0.38, 0.17, 0.12), ridge * 0.35);
		float door = fill(sd_box(q, vec2(-0.28, -0.42), vec2(0.24, 0.38)), aa);
		col = mix(col, vec3(0.30, 0.20, 0.13), door);
		a = max(a, door);
		float win = fill(sd_box(q, vec2(0.48, -1.15), vec2(0.22, 0.20)), aa);
		col = mix(col, vec3(0.98, 0.82, 0.42), win);
		a = max(a, win);
		float chim = fill(sd_box(q, vec2(0.62, -2.48), vec2(0.14, 0.42)), aa);
		col = mix(col, vec3(0.55, 0.32, 0.25), chim);
		a = max(a, chim);
	} else {
		// ---- 塔楼：窄高石墙 + 尖顶 + 窗缝 ----
		float wall_d2 = sd_box(q, vec2(0.0, -1.55), vec2(0.55, 1.50));
		float wall_edge2 = fill(wall_d2 + 0.035, aa);
		col = mix(col, vec3(0.13, 0.14, 0.17), wall_edge2);
		a = max(a, wall_edge2);
		float tower = fill(wall_d2, aa);
		col = mix(col, vec3(0.52, 0.54, 0.58), tower);
		a = max(a, tower);
		float seam = tower * (1.0 - smoothstep(0.0, 0.03, abs(fract(q.y * 2.6) - 0.5)));
		col = mix(col, vec3(0.36, 0.38, 0.42), seam * 0.45);
		float t2 = clamp((-q.y - 3.00) / 0.70, 0.0, 1.0);
		float halfw2 = 0.78 * (1.0 - t2);
		float roof2 = smoothstep(-3.72 - aa, -3.72 + aa, q.y)
			* (1.0 - smoothstep(-3.00 - aa, -3.00 + aa, q.y))
			* (1.0 - smoothstep(-aa, aa, abs(q.x) - halfw2));
		col = mix(col, vec3(0.22, 0.30, 0.46), roof2);
		a = max(a, roof2);
		float slit = fill(sd_box(q, vec2(0.0, -2.30), vec2(0.09, 0.22)), aa);
		col = mix(col, vec3(0.95, 0.80, 0.45), slit);
		a = max(a, slit);
		float door2 = fill(sd_box(q, vec2(0.0, -0.35), vec2(0.18, 0.30)), aa);
		col = mix(col, vec3(0.20, 0.16, 0.12), door2);
		a = max(a, door2);
	}

	// 遮挡：按片元自己的世界高度判定，所以"只露一个头"也是对的
	float zs = u_base_z + (1.0 - UV.y) * u_art_height;
	float occl = occlusion(u_base_cell, zs);
	a *= mix(1.0, u_fade, occl);

	COLOR = vec4(col, a);
}
