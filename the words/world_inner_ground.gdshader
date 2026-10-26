// the words/world_inner_ground.gdshader
// 「地心世界」的反地面 —— 地球的**内壁**（凹面），第二十八轮。
//   · 从内部看：整个天空就是这片地面（球的内表面铺满视野）；
//   · 从外部看：因为只画背面，看到的仍是**远侧内壁**，整体形如一颗绿色星球（正好当剖面图看）。
//
// ★ render_mode cull_front：**只画背面** = 球的内壁。默认的 cull_back 只会画外表面，
//   从球里面看是一片空白（所有面都背对镜头）。
// ★ render_mode unshaded：地心太阳在球心 ⇒ 对每一块内壁都是垂直入射（N·L ≡ 1），
//   根本不存在方向性明暗；层次只能靠贴图本身 + **距离雾**（越远越淡，勾出辽阔感）。
shader_type spatial;
render_mode unshaded, cull_front;

uniform sampler2D tex_ground : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_texture = true;   // false = 纯色填充（不采样贴图，只用 tint × gain）
uniform vec3 tint : source_color = vec3(1.0);    // 实例色（与其它星体一致，来自 JSON 的 color）
uniform float gain = 1.0;
// 距离雾：把远处的地面往雾色里混 ⇒ 内壁「越远越淡」，否则一整面均匀的绿会像贴纸。
uniform vec3 haze_color : source_color = vec3(0.60, 0.76, 0.70);
uniform float radius = 1.0;        // 本节点半径（世界单位）：雾距以它为单位，换尺度不用改参数
uniform float haze_start = 2.2;    // 起雾（× radius）
uniform float haze_end = 5.0;      // 全雾（× radius）
uniform float haze_max = 0.42;     // 最远混入比例（留足底色，别把苍绿糊成灰）
// ★ 雾距一律以**本节点半径**为单位（而不是绝对值）：第二十八轮续把反地面半径从 0.9 缩到 0.3，
//   若雾是绝对距离，同样的参数会立刻糊成一片 —— 用倍率就不必跟着改。

void fragment() {
	vec3 c = tint * gain;
	if (use_texture) {
		c *= texture(tex_ground, UV).rgb;
	}
	vec3 wpos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float nd = distance(CAMERA_POSITION_WORLD, wpos) / max(radius, 1e-6);
	float h = smoothstep(haze_start, haze_end, nd) * haze_max;
	ALBEDO = mix(c, haze_color, h);
}
