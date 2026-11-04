shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;

void fragment() {
	vec3 background = textureLod(screen_texture, SCREEN_UV, 3.5).rgb;
	COLOR = vec4(background * 0.38, 1.0);
}
