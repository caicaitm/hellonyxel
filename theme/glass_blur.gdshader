shader_type canvas_item;

// 液态玻璃（进阶版·薄膜干涉 + 表面反射）：框内轻度磨砂 + 通透纯白轻纱；
// 折射只出现在边框带；★ 追加两种光学效果：
//   ① 薄膜干涉彩虹：按「视角余弦→光程差」用多条正弦叠加生成物理感干涉条纹（随位置缓慢流动），
//      在表面中央极淡、靠近边缘增强，模拟真实玻璃/肥皂膜随视角变化的虹彩。
//   ② 表面反射高光：右上主镜面亮斑 + 菲涅尔掠射边缘光 + 顶部条状反光。
// 由 ui/ui_panel.gd 的磨砂路径挂在 ColorRect 上，各 uniform 由代码经 set_shader_parameter 传入。

uniform float blur_radius : hint_range(0.0, 16.0) = 4.0;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 0.22);
uniform float corner_radius : hint_range(0.0, 64.0) = 8.0;
uniform vec2 panel_size = vec2(64.0, 64.0);
uniform float border_width : hint_range(0.0, 8.0) = 1.5;
uniform vec4 border_color : source_color = vec4(0.78, 0.96, 1.0, 0.95);
uniform float highlight_strength : hint_range(0.0, 1.0) = 0.18;
uniform vec4 glow_color : source_color = vec4(0.45, 0.75, 1.0, 0.22);
uniform float glow_width : hint_range(0.0, 16.0) = 4.0;
uniform float refract_pixels : hint_range(0.0, 40.0) = 14.0;   // 边框折射强度（像素位移）
uniform float dispersion : hint_range(0.0, 24.0) = 6.0;        // 色散强度（RGB 偏移差，像素）
uniform float iridescence : hint_range(0.0, 1.0) = 0.75;       // 虹彩强度
uniform float scatter_strength : hint_range(0.0, 1.0) = 0.55;  // 外侧彩色散射光晕强度
// —— 薄膜干涉 & 表面反射参数 ——
uniform float film_strength : hint_range(0.0, 1.0) = 0.42;     // 薄膜干涉彩虹强度
uniform float film_thickness : hint_range(2.0, 24.0) = 9.0;    // 薄膜厚度（影响条纹密度）
uniform float specular_strength : hint_range(0.0, 1.0) = 0.55; // 表面反射高光强度
uniform vec2 light_dir = vec2(0.55, -0.82);                    // 光源方向（右上，-y 为上）

// Godot 4.7 起全局 SCREEN_TEXTURE 已移除，需显式声明为带 hint_screen_texture 的 sampler2D。
// SCREEN_UV / SCREEN_PIXEL_SIZE 仍作为内置 varying 可用。
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;

// 圆角矩形有向距离场（SDF）：<0 在内部，=0 在边上，>0 在外部。
float rounded_box_sdf(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + vec2(r);
	return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

// HSV → RGB（用于生成沿边框流动的虹彩色相）。
vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

// 薄膜干涉：给定「光程差相位」和「视角余弦」，返回 RGB 虹彩。
// 物理近似——不同波长在膜内干涉后，反射光强随相位作正弦变化；用 3 条错开的余弦
// 分别代表 R/G/B 通道，即得到随相位连续变化的彩色条纹（肥皂膜/油膜的典型观感）。
vec3 thin_film(float phase, float cos_view) {
	// 每通道波长不同 → 相位步长不同（R 长、B 短）
	float r = cos(phase * 1.00) * 0.5 + 0.5;
	float g = cos(phase * 1.18 + 2.094) * 0.5 + 0.5;   // +120°
	float b = cos(phase * 1.42 + 4.188) * 0.5 + 0.5;   // +240°
	vec3 c = vec3(r, g, b);
	// 掠射（cos_view 小）时膜干涉更强（真实薄膜效应），正对时减弱
	float boost = mix(0.45, 1.0, 1.0 - cos_view);
	return c * boost;
}

void fragment() {
	vec2 half_size = max(panel_size * 0.5, vec2(0.0001));
	vec2 p = (UV * panel_size) - half_size;
	float d = rounded_box_sdf(p, half_size, corner_radius);

	// 到边框的内侧深度：0 在边、越大越靠中心
	float depth = -d;
	// 边框折射带：仅在此带内对背景做折射偏移，框内主体保持通透
	float band = border_width + 14.0;
	float edge = 1.0 - smoothstep(0.0, band, depth);

	// 圆角盒外法线（折射方向）：取 p 到内盒最近点的方向
	vec2 b = max(half_size - vec2(corner_radius), vec2(0.0001));
	vec2 nearest = clamp(p, -b, b);
	vec2 n = normalize(p - nearest + vec2(1e-4));

	// 归一化局部坐标（-1~1）：用于薄膜干涉的视角与表面高光定位
	vec2 q = p / half_size;                       // -1..1
	// 伪表面法线：中心凸起（像吹胀的玻璃面），边缘趋向法线朝外
	// 用 q 的径向分量近似「视线与表面法线夹角」的余弦
	float cos_view = clamp(1.0 - dot(q, q) * 0.55, 0.0, 1.0);

	// 沿边框的「弧长参数」→ 决定虹彩色相（边框带的棱镜色散）
	vec2 dir = normalize(p / half_size + vec2(1e-4));
	float ang = atan(dir.y, dir.x) / 6.2831853 + 0.5;   // 0~1 环绕
	float hue = fract(ang + UV.y * 0.15);
	vec3 irid = hsv2rgb(vec3(hue, 0.55, 1.0));

	vec3 col = vec3(0.0);
	float alpha = 0.0;

	if (d > 0.0) {
		// 面板外侧：色散散射光晕——光晕带色相，模拟光线在玻璃边缘分解后向外弥散
		float ga = (1.0 - clamp(d / max(glow_width, 0.0001), 0.0, 1.0)) * glow_color.a;
		vec3 halo = mix(glow_color.rgb, irid, iridescence * 0.7) * scatter_strength;
		float falloff = exp(-d / max(glow_width, 0.0001) * 2.2);
		col = halo;
		alpha = ga * (0.5 + falloff);
	} else {
		// 色散折射：RGB 三通道用不同偏移量采样屏幕 → 边缘分解出彩色光带
		float disp = dispersion * edge;
		vec2 refr_base = n * edge * refract_pixels * SCREEN_PIXEL_SIZE;
		vec2 refr_r = n * (edge * refract_pixels + disp) * SCREEN_PIXEL_SIZE;
		vec2 refr_g = refr_base;
		vec2 refr_b = n * (edge * refract_pixels - disp * 0.6) * SCREEN_PIXEL_SIZE;

		// 轻度模糊：3x3 加权采样（半径由 blur_radius 控制）→ 柔和磨砂
		vec2 px = SCREEN_PIXEL_SIZE * blur_radius;
		vec3 bg = vec3(0.0);
		float wsum = 0.0;
		for (int x = -1; x <= 1; x++) {
			for (int y = -1; y <= 1; y++) {
				vec2 o = vec2(float(x), float(y)) * px;
				float w = (x == 0 && y == 0) ? 4.0 : 1.0;
				vec3 s;
				s.r = texture(SCREEN_TEXTURE, SCREEN_UV + refr_r + o).r;
				s.g = texture(SCREEN_TEXTURE, SCREEN_UV + refr_g + o).g;
				s.b = texture(SCREEN_TEXTURE, SCREEN_UV + refr_b + o).b;
				bg += s * w;
				wsum += w;
			}
		}
		bg /= max(wsum, 0.0001);

		// 框内主体：让背景几乎原样透出（通透感来源）。白纱只在中心极淡，且随靠近边缘略增。
		// ★ 通透关键：白纱权重从旧版固定 0.10 降到 0.03，避免整块面板被"蒙白"发闷。
		float veil = mix(0.03, 0.10, edge);
		col = mix(bg, vec3(1.0), veil);
		// ★ 通透关键：中心 alpha 压到极低（背景亮度几乎不被覆盖），仅边缘带递增。
		alpha = tint.a * 0.25 + 0.02 + edge * 0.10;

		// ========== ① 薄膜干涉彩虹 ==========
		// 光程差相位 = 膜厚 × 视角余弦（视角越斜、光程越长）→ 相位随位置缓慢变化
		float phase = film_thickness * cos_view * 3.14159265 + depth * 0.05;
		vec3 film = thin_film(phase, cos_view);
		// ★ 通透关键：干涉只保留在靠近边缘的带内（中心 mask 由 0.35 降到 0.05），
		//   整块表面不再泛彩虹，从而不糊住背景。
		float film_mask = mix(0.05, 1.0, edge) * film_strength;
		// 用 screen 混合上膜色（只加亮特定通道，不整体提白）
		col = mix(col, vec3(1.0) - (vec3(1.0) - col) * (vec3(1.0) - film), film_mask * 0.5);

		// ========== ② 表面反射高光 ==========
		// ★ 通透关键：高光整体权重下调（0.55→0.35），且主亮斑/条光只在有玻璃感的区域，
		//   避免全屏加亮导致"磨砂雾"。
		vec2 spec_center = light_dir * 0.42;
		float spec_d = length((q - spec_center) * vec2(1.0, 1.55));
		float spec = exp(-spec_d * spec_d * 6.5) * specular_strength * 0.6;
		// (b) 顶部条状反光（弱化，只在上缘附近）
		float top_bar = smoothstep(half_size.y * 0.98, half_size.y * 0.62, p.y);
		top_bar *= smoothstep(half_size.x, half_size.x * 0.25, abs(p.x));
		spec += top_bar * specular_strength * 0.12;
		// (c) 菲涅尔掠射边缘光：边缘处反射率骤增（玻璃边缘最亮的一圈）
		float fres = pow(1.0 - cos_view, 3.0);
		spec += fres * specular_strength * 0.35;
		col += vec3(spec);

		// (d) 顶部镜面高光（上边缘 16px 内，弱化）
		float dist_top = half_size.y - p.y;
		float hl = (1.0 - smoothstep(0.0, 16.0, dist_top)) * highlight_strength * 0.7;
		col += hl;

		// 边框亮线：由「冰蓝描边色」渐变到「沿边框流动的虹彩色」→ 不再是单调白线
		float bw = smoothstep(-border_width, 0.0, d);
		vec3 line_color = mix(border_color.rgb, irid, iridescence);
		// ★ 边框线透明度兜底：玻璃描边默认 alpha 仅 0.65（UIStyle.BORDER 的亮冰蓝），
		//   画在亮色玻璃填充上对比度不足，面板一收窄/最小化细线就被玻璃「吞掉」→ 观感「边框丢失」。
		//   把线 alpha 抬到不低于纯色模式的 0.90，保证任意尺寸（含最小化条）都清晰可见，
		//   同时不改变描边色相，最大化保留原有观感。
		float ba = max(border_color.a, 0.9);
		col = mix(col, line_color, bw * ba);
		// 折射带内叠加虹彩散射微光（越靠边越亮）
		col += irid * edge * 0.12;
		col += line_color * edge * 0.06;
		// 边缘薄膜干涉再强化一点（贴合真实玻璃边缘的彩边）
		col += film * edge * film_strength * 0.30;
		alpha = max(alpha, bw * ba);
	}

	COLOR = vec4(col, alpha);
}
