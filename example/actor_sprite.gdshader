shader_type canvas_item;
render_mode blend_mix, unshaded;
// Tiny Swords 贴图立牌：采样真实精灵 + 与程序化立牌同一套高度场遮挡。
// UV 覆盖的是 AtlasTexture 的“非透明内容区”，脚底 = 立牌底边。
// 遮挡判定与 actor_card.gdshader 完全一致；区别只是颜色/透明度来自贴图。

uniform sampler2D u_art : source_color, filter_nearest, repeat_disable;
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
	// 左右整侧抬升 = 上下边倾斜、左右边保持竖直的平行四边形。
	// 节点高度已经加上抬升跨度，这里把 UV.y 反算回图片自身的 v，越界部分透明。
	// 竖向资源水平镜像：贴图 u 取反，左右抬升同时换边，镜像后的轮廓才对得上。
	float h = max(u_art_size.y, 0.001);
	vec2 lift = u_flip_x ? u_art_lift.yx : u_art_lift;
	float l_left = -lift.x * h;
	float l_right = -lift.y * h;
	float l_min = min(l_left, l_right);
	float bbox_h = h + abs(l_left - l_right);
	float l = mix(l_left, l_right, UV.x);
	float v = (UV.y * bbox_h - (l - l_min)) / h;
	if (v < 0.0 || v > 1.0) {
		COLOR = vec4(0.0);
	} else {
		float u = u_flip_x ? 1.0 - UV.x : UV.x;
		vec4 tex = texture(u_art, vec2(u, v));
		float zs = u_base_z + (1.0 - v) * u_art_height;
		float occl = occlusion(u_base_cell, zs);
		float a = tex.a * mix(1.0, u_fade, occl);
		COLOR = vec4(tex.rgb, a);
	}
}
