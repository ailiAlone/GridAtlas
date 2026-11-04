shader_type canvas_item;
render_mode unshaded;

// 45° 视图的轻量共享后处理：把地形与所有 2D 立牌拉到同一套色阶/颗粒/暗角里。
// 只作用于 GamePreview 内部，不影响编辑器 UI 和 GridView。
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform float u_sat = 0.96;
uniform float u_contrast = 0.97;
uniform vec3 u_tint = vec3(1.01, 0.995, 0.97);
uniform float u_grain = 0.008;
uniform float u_vignette = 0.05;

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(vec3(l), c, u_sat);
	c = (c - 0.5) * u_contrast + 0.5;
	c *= u_tint;
	float n = fract(sin(dot(SCREEN_UV * vec2(1920.0, 1080.0), vec2(12.9898, 78.233))) * 43758.5453);
	c += (n - 0.5) * u_grain;
	vec2 v = SCREEN_UV - 0.5;
	c *= 1.0 - smoothstep(0.30, 0.78, length(v)) * u_vignette;
	COLOR = vec4(c, 1.0);
}
