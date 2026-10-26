// the words/world_cloud_shell.gdshader
// 地球「云层壳」的材质（第十八轮）。半径 ≈ 地球半径 R × 1.015 —— **贴近地面但不与地面重合**
// （同心不同半径 ⇒ 绝不会 z-fighting；球面网格的分面偏差只有 ~0.0004R，1.5% 的间隙远远够）。
//
// ★ 云贴图实测是「白云黑底」（撒哈拉 = (3,3,3)）⇒ 亮度可直接当 alpha 用。
// ★ 云只在**向阳面**亮、夜面近乎不可见（夜里的云本该是暗的剪影，不能是一张自发光的白饼）。
// ★ 整体透明度 `shell_alpha` 由 WorldView 按**相机距离**逐帧写入（淡入淡出，见 WorldNode.update_shells）：
//   离得远才显示云，贴近地表时淡出 —— 否则云会把地表细节糊掉。
shader_type spatial;
render_mode blend_mix, cull_back, unshaded, depth_draw_never, shadows_disabled;

uniform sampler2D tex_clouds : source_color, filter_linear_mipmap_anisotropic, repeat_enable;

// 地球 → 太阳（世界空间）
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);

uniform float cloud_alpha_gain = 1.0;   // 云亮度 → alpha 的增益
uniform float shell_alpha = 1.0;        // 整体淡入淡出（0 = 完全隐藏，1 = 完全显示）
uniform float cloud_ambient = 0.05;     // 夜面残余亮度（留一点点，避免夜面云变成「洞」）
uniform float cloud_day_gain = 1.0;     // 向阳面云顶亮度
uniform float terminator_soft = 0.10;   // 云层晨昏柔化宽度

void fragment() {
	vec3 N = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float day_f = smoothstep(-terminator_soft, terminator_soft, dot(N, normalize(sun_dir)));

	// unshaded ⇒ ALBEDO 就是最终颜色，光照只能这样手算。
	ALBEDO = vec3(clamp(cloud_ambient + cloud_day_gain * day_f, 0.0, 1.0));
	ALPHA = clamp(texture(tex_clouds, UV).r * cloud_alpha_gain, 0.0, 1.0) * shell_alpha;
}
