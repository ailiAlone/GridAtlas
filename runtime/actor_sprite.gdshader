shader_type canvas_item;
render_mode blend_mix, unshaded;
// Tiny Swords 贴图立牌：采样真实精灵 + 与程序化立牌同一套高度场遮挡。
// UV 覆盖的是 AtlasTexture 的“非透明内容区”，脚底 = 立牌底边。
// 旧模式用 art_lift 做垂直剪切；遮挡判定与 actor_card.gdshader 完全一致。
// 遮挡判定与 actor_card.gdshader 完全一致；区别只是颜色/透明度来自贴图。

uniform sampler2D u_art : source_color, filter_linear, repeat_disable;
uniform sampler2D u_elev_smooth : filter_linear, repeat_disable;
uniform vec2 u_map_size = vec2(64.0);
uniform float u_elev_smooth_max = 32.0;
uniform float u_height_scale = 2.5;
uniform float u_pitch = 0.785398;
uniform vec2 u_view_dir = vec2(0.7071, 0.7071);   // 立牌 → 相机 的水平方向
uniform vec2 u_base_cell = vec2(0.0);
uniform float u_base_z = 0.0;
uniform vec2 u_art_size = vec2(1.0, 2.2);         // 立牌尺寸（格，不按俯角压缩）
uniform vec2 u_art_lift = vec2(0.0);              // 左/右整侧抬升（占立牌高度比例）
uniform bool u_flip_x = false;                    // 竖向资源：水平镜像贴图与左右抬升
uniform float u_art_height = 3.11;                // 立牌顶端的世界高度（= 高 / cos(俯角)）
uniform float u_fade = 0.0;                       // 被挡时保留的不透明度
uniform float u_style_sat = 1.0;                  // 统一色盘：0=灰度，1=原图
uniform float u_style_grain = 0.0;                // 与地形共享的细颗粒
uniform vec3 u_style_tint = vec3(1.0);            // 统一环境染色
uniform vec3 u_variation_tint = vec3(1.0);        // 植物个体色调差异（每棵树略不同）
uniform float u_crown_warp = 0.0;                  // 树冠上部宽度偏移（个体差异）
uniform float u_crown_lean = 0.0;                  // 树冠上部横向倾斜
uniform vec3 u_ground_tint = vec3(1.0);           // 脚底地形色的轻微环境反射
uniform float u_soft_grass_base = 0.0;            // 树下草垫边缘柔化（0=关闭，1=树木）

float elev_field_at(vec2 p) {
	return texture(u_elev_smooth, (p - 0.5) / u_map_size).r * u_elev_smooth_max;
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float occlusion(vec2 base_cell, float world_z) {
	float tanp = tan(u_pitch);
	float occl = 0.0;
	// 20 步 × 0.55 = 11 格：远处的山脊也能挡住立牌，不会在 5.5 格处截断
	for (int i = 1; i <= 20; i++) {
		float d = float(i) * 0.55;
		vec2 p = base_cell + u_view_dir * d;
		float tz = max(elev_field_at(p) - 1.0, 0.0) * u_height_scale;
		float rayz = world_z + d * tanp;
		occl = max(occl, smoothstep(0.02, 0.22, tz - rayz));
	}
	return occl;
}

void fragment() {
	// 旧模式：左右整侧抬升 = 上下边倾斜、左右边保持竖直的平行四边形。
	// st 是源贴图 UV；越界部分透明。
	vec2 st;
	// 竖向资源水平镜像：贴图 u 取反，左右抬升同时换边，镜像后的轮廓才对得上。
	float h = max(u_art_size.y, 0.001);
	vec2 lift = u_flip_x ? u_art_lift.yx : u_art_lift;
	float l_left = -lift.x * h;
	float l_right = -lift.y * h;
	float l_min = min(l_left, l_right);
	float bbox_h = h + abs(l_left - l_right);
	float l = mix(l_left, l_right, UV.x);
	float v = (UV.y * bbox_h - (l - l_min)) / h;
	st = vec2(u_flip_x ? 1.0 - UV.x : UV.x, v);
	if (st.x < 0.0 || st.x > 1.0 || st.y < 0.0 || st.y > 1.0) {
		COLOR = vec4(0.0);
	} else {
		// t：0=地基，1=立牌顶端。
		float t = clamp(1.0 - st.y, 0.0, 1.0);
		// 树冠形变：只在上半段横向缩放/倾斜，树干脚底保持不动。
		// 每棵树取不同的 warp/lean，同一张树图才不会像复制粘贴。
		float crown = smoothstep(0.18, 0.95, t);
		float su = 0.5 + (st.x - 0.5) * (1.0 + u_crown_warp * crown);
		su += u_crown_lean * crown * crown;
		su = clamp(su, 0.0, 1.0);
		vec4 tex = texture(u_art, vec2(su, v));
		float zs = u_base_z + t * u_art_height;
		float occl = occlusion(u_base_cell, zs);
		float a = tex.a * mix(1.0, u_fade, occl);
		// 树木贴图底部自带的草垫：只柔化边缘的草色像素，树干/树根保持原样。
		// 草垫的硬边被地形草接管，树脚就不会像贴了一块绿色菱形。
		if (u_soft_grass_base > 0.001 && t < 0.16) {
			float greenish = smoothstep(-0.060, 0.005, tex.g - tex.r * 0.88)
				* smoothstep(-0.020, 0.020, tex.g - tex.b);
			float band = 1.0 - smoothstep(0.10, 0.16, t);
			float side = smoothstep(0.18, 0.40, abs(st.x - 0.5));
			float bottom = 1.0 - smoothstep(0.005, 0.07, t);
			// 草垫整体降到 ~5%，边缘再额外收掉：地形树根草垫接管脚底
			float feather = greenish * band * (0.90 + 0.10 * max(side, bottom));
			a *= 1.0 - feather * 0.97;
		}
		vec3 rgb = tex.rgb * u_variation_tint;
		float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
		rgb = mix(vec3(luma), rgb, u_style_sat);
		rgb *= u_style_tint;
		rgb *= u_ground_tint;
		// 与地形共享的低频斑驳：树干/屋顶/木板不再是一整块平色
		vec2 npos = u_base_cell * 1.7 + UV * u_art_size * 2.0;
		float paint_n = vnoise(npos) * 0.65 + vnoise(npos * 2.3 + vec2(7.1, 3.7)) * 0.35;
		rgb *= 0.95 + 0.09 * paint_n;
		// 柔化剪影边缘：把低 alpha 的边缘往脚底地形色靠一点
		float edge = 1.0 - smoothstep(0.0, 0.40, tex.a);
		rgb = mix(rgb, rgb * u_ground_tint * 0.92, edge * 0.22);
		// 底部接地：压暗并偏一点地形草色，避免立牌像剪纸贴在草地上
		float ground_ao = smoothstep(0.78, 1.0, 1.0 - t) * 0.20;
		rgb *= 1.0 - ground_ao;
		rgb = mix(rgb, rgb * vec3(0.94, 0.99, 0.88), ground_ao);
		float gn = fract(sin(dot(UV * vec2(317.0, 913.0) + u_base_cell, vec2(12.9898, 78.233))) * 43758.5453);
		rgb += (gn - 0.5) * u_style_grain;
		COLOR = vec4(rgb, a);
	}
}
