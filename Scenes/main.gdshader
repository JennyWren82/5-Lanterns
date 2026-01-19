shader_type canvas_item;

uniform float vignette_strength : hint_range(0.0, 1.0) = 0.75; // stronger
uniform float vignette_start : hint_range(0.0, 1.0) = 0.15;    // where it begins
uniform float vignette_end : hint_range(0.0, 2.0) = 0.95;      // how far it reaches

uniform vec4 vignette_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

void fragment() {
	vec2 uv = SCREEN_UV;
	float r = length(uv - vec2(0.5));      // center=0, corners~0.707

	// 0 in the center, 1 toward edges
	float v = smoothstep(vignette_start, vignette_end, r);

	// Only draw darkness on the edges. Center stays transparent.
	float alpha = vignette_strength * v;

	COLOR = vec4(vignette_color.rgb, alpha);
}
