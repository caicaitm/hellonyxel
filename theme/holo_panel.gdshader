shader_type canvas_item;

// 量子全息面板（批次 59）—— 与「液态玻璃」平行的第三套界面主题的绘制核心。
//
// 三条硬特征（用户需求）：
//   ① 没有边框：本着色器**不画任何描边亮线**，面板边界靠"淡出"收口 → 天然无硬边。
//   ② 纯净透明荧光蓝：整体是一层荧光蓝薄纱，只做「色 + alpha」，不做模糊/折射/虹彩。
//   ③ 中心透明度低、边缘透明度高：椭圆径向 alpha 衰减 —— 中心 alpha 最高（最实），
//      向外递减到边缘最低（最虚），再叠一层圆角 SDF 保证四角干净。
//
// ★ 与 glass_blur.gdshader 的关键差别（很重要）：
//   本着色器**不采样 SCREEN_TEXTURE** → 在 headless（dummy 渲染器）下同样能编译并生效，
//   无需像液态玻璃那样降级成平板色（参见 ui/ui_panel.gd 的 _sync_render）。
//
// 由 ui/ui_panel.gd 在全息主题下挂到面板底层的 ColorRect 上；uniform 由代码传入。

// ★ 批次 60 调参（用户反馈「效果不明显，有颜色的范围调大、纯透明的范围调小」）：
//   core_scale 0.92 → 1.30（颜色铺满整个面板，仅四角淡出）+ core_power 1.70 → 2.80
//   （中段更实）→ 「有颜色」占比大幅上升、「纯透明」只剩最外圈/四角。
uniform vec4 tint : source_color = vec4(0.35, 0.85, 1.0, 1.0);  // 荧光蓝基色
uniform vec2 panel_size = vec2(64.0, 64.0);                     // 面板像素尺寸
uniform float corner_radius : hint_range(0.0, 64.0) = 10.0;     // 圆角半径（塑形用，不画线）
uniform float center_alpha : hint_range(0.0, 1.0) = 0.48;       // 中心不透明度（"低透明度"=更实）
uniform float edge_alpha : hint_range(0.0, 1.0) = 0.04;         // 边缘不透明度（"高透明度"=更虚）
uniform float core_power : hint_range(0.4, 6.0) = 2.80;         // 径向衰减曲线（越大中段越实）
uniform float core_scale : hint_range(0.2, 2.0) = 1.30;         // 径向核心半径（相对半宽/半高）★ 越大「有颜色」范围越大
uniform float glow_strength : hint_range(0.0, 2.0) = 0.38;      // 中心"能量核"提亮强度

// 圆角矩形有向距离场（SDF）：<0 在内部，=0 在边上，>0 在外部。
float rounded_box_sdf(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + vec2(r);
	return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

void fragment() {
	vec2 half_size = max(panel_size * 0.5, vec2(0.0001));
	vec2 p = (UV * panel_size) - half_size;

	// ---- 形状：圆角矩形 + 1.5px 羽化（无描边） ----
	float d = rounded_box_sdf(p, half_size, corner_radius);
	float shape = 1.0 - smoothstep(-1.5, 0.0, d);

	// ---- 径向透明度：中心实 → 边缘虚 ----
	// 用 p/半宽半高 归一化 → 椭圆径向坐标，长宽比自动适配（宽面板也是椭圆光斑）。
	vec2 q = p / half_size;
	float rad = clamp(length(q) / max(core_scale, 0.05), 0.0, 1.0);
	float falloff = 1.0 - pow(rad, core_power);            // 中心 1 → 边缘 0
	float a = mix(edge_alpha, center_alpha, falloff) * shape;

	// ---- 颜色：荧光蓝 + 中心"能量核"微亮（全息发光感） ----
	vec3 col = tint.rgb * (1.0 + glow_strength * falloff * falloff);

	COLOR = vec4(col, a);
}
