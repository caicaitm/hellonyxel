// the words/world_earth_surface.gdshader
// 地球「地表壳」的材质（第十八轮）。半径 = 地球半径 R。
//   向阳面 = 白天贴图；背阳面 = 极暗底色 + 夜晚城市灯光；海面按镜面反射贴图叠一层太阳高光。
//
// ★ 为什么 render_mode 是 unshaded（昼夜 / 镜面全部**手算**）：
//   世界根那盏太阳 OmniLight 挂在**球心**，对地球表面每个片元都是「从背后照来」（N·L ≤ 0），
//   而且球心光没有方向性、会把**夜面也一起照亮** ⇒ 引擎光照在这里根本用不上，必须自己按 sun_dir 算。
//
// ★ 光照方向 `sun_dir`（世界空间单位向量）由 WorldView 在「建树后 + 每次公转 tick 之后」写入
//   （地球位置逐月变 ⇒ 方向必须跟着变；自转不改位置 ⇒ 不必重写）。
shader_type spatial;
render_mode unshaded, cull_back;

uniform sampler2D tex_day    : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_night  : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_normal : hint_normal,  filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_spec   : source_color, filter_linear_mipmap_anisotropic, repeat_enable;

// ---- 第二十六轮：近景「瓦片高清补丁」（见 the words/earth_tile_layer.gd）----
// tex_detail = 由 (G+2)×G 张 512px 素材瓦片拼成的 atlas（★ 东、西各比中间多一列 —— 屏幕横向
//   可视范围比纵向宽，块东西边缘最容易先露糊边，故横向多补一列）；detail_rect = (u0, v0, du, dv)
//   块在等距圆柱 UV 里的矩形；detail_grid = atlas 的 (列数, 行数) = (G+2, G)；
//   块外自动回落到 8K 底图，边界用 detail_edge 做软过渡。★ 只对**陆地**生效（海洋走底图）。
uniform sampler2D tex_detail : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 detail_rect = vec4(0.0, 0.0, 0.0, 0.0);
uniform vec2 detail_grid = vec2(3.0, 3.0);
uniform float detail_blend = 0.0;
uniform float detail_edge = 0.06;

// ---- 第二十七轮：近景「地势起伏」（海拔栅格 = WorldClim 2.1 2.5m elev，见 JSON 的 texture_height）----
// tex_height 是**等距圆柱**的 8 位灰度海拔图（0..1 对应 0..height_max_m 米，海面 = 0）；
//   本 shader 用它在片元里**现算坡度**，把地形明暗叠到白天色上 —— 靠得越近（height_blend → 1）越明显。
// ★ 为什么不烘焙成法线图：太阳方向会随公历逐月变（sun_dir 由 WorldView 写），
//   坡度是**光照无关**的量，留着在片元里算才能跟着太阳走。
// ★ 为什么不做几何位移：球壳网格 256×128（每段 ~1.4°≈155 km），而山脊只有几十 km 宽 ⇒
//   位移根本落不到网格精度上；用「坡度 → 明暗」表达地势起伏才是这条路径唯一稳的做法。
uniform sampler2D tex_height : filter_linear_mipmap, repeat_enable;
uniform vec2 height_tex_size = vec2(4320.0, 2160.0);
uniform float height_max_m = 6000.0;   // 编码上限（米）：源码本层 = 0..6000 m
uniform float height_exag = 2.5;       // 垂直夸张（栅格本身 ~9 km/px，真实坡度被抹平，须放大）
uniform float height_shade = 3.0;      // 明暗强度（1.0 = 真实余弦差；>1 提亮/压暗以让起伏看清）
uniform float height_blend = 0.0;      // 近景权重（WorldNode 按相机距离每帧写）

// ---- 第二十八轮续 7：「视图模式」叠加（WorldView.set_view_mode 每帧外写，切换下拉时变）----
//   0 = 俯瞰视图（无叠加）/ 1 = 时区视图 / 2 = 人口密度 / 3 = 气候分布
//   时区视图：把经度按 15° 平均切成 24 带：带心在 0°、±15°、…（即 UTC+0 以本初子午线为中心），
//   与现实中「每 15° 一个时区、格林尼治为零时区」大致对得上；相邻时区用冷/暖两色交替，
//   边界画一条抗锯齿细线（宽度按屏幕导数自适应，贴着看也不会糊成粗条）。
uniform int view_mode = 0;
// 人口密度：8 位对数索引（v = log10(1+d)/log10(1+1e5)，见转换脚本 / WorldNode.POP_MAX_DENSITY）。
// 气候分布：Köppen 配色的 RGB 图（海洋 = 纯黑 ⇒ 本 shader 跳过，不染海洋）。
uniform sampler2D tex_pop : filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_climate : source_color, filter_linear_mipmap, repeat_enable;

// 地球 → 太阳（世界空间）
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
// 反射/受光色：略偏暖的白（真阳光是白的 —— 别拿太阳的橙色去染地球，否则整颗地球发橙）
uniform vec3 sun_color : source_color = vec3(1.0, 0.94, 0.84);

uniform float day_gain = 1.2;         // 白天贴图总增益（对齐其它行星的引擎光亮度 light_energy = 1.2）
// 夜面「极暗底色」比例：**故意用白天贴图**、而不是夜景贴图 —— 夜景图在近黑区被 BC1（S3TC 4×4 分块）
// 压出块状/条状噪声，一放大就是用户看到的「奇怪的深色像素状条纹」；白天贴图是亮图，压到这么低很干净。
// 它的作用是让夜面**仍是一个看得见的球**（暗版地球 / 地照），否则夜半球会黑到只剩几颗灯点、没了轮廓。
uniform float night_base = 0.20;
uniform float night_gain = 2.4;       // 城市灯光增益（夜晚贴图本身很暗，必须放大）
// ★ 夜景贴图的「裁噪地板」：夜景图在近黑区被 BC1（S3TC 对 4×4 分块）压出块状/条状噪声，
//   再被 night_gain 放大到肉眼可见（用户反馈「阴影部位有奇怪的深色像素状条纹」）。
//   整幅**减掉这个地板** ⇒ 近黑噪声被压成纯黑。
uniform float night_floor = 0.020;
// ★ 再把夜景图自带的**稀薄云底 / 陆底**（亮度大致在 0.06~0.12，就是那些「脏条纹」）用一条亮度软门压掉，
//   只留下真正明亮的城市灯光 ⇒ 夜面变成「干净的深色 + 清晰的城市灯点」。
uniform float night_gate_lo = 0.055;
uniform float night_gate_hi = 0.16;
// ★ 城市灯光的**作用范围**（单位 = N·L）：N·L ≤ −night_start 才开始淡入、≤ −night_full 才达全强
//   ⇒ 灯光只出现在**深入夜面**之后，覆盖范围比整个夜半球小得多（用户要求「作用范围小一些」）。
uniform float night_start = 0.05;
uniform float night_full = 0.35;
uniform float spec_gain = 1.1;        // 海面镜面高光强度
uniform float shininess = 42.0;       // 高光锐度
uniform float normal_strength = 0.7;  // 法线起伏强度（0 = 不用法线贴图）
// 晨昏线柔化宽度（单位 = N·L）：白天贴图在这条带里**淡入淡出**到夜面（用户要求过渡有淡入淡出）
uniform float terminator_soft = 0.13;
uniform bool  normal_flip_y = false;  // 法线贴图绿通道方向（OpenGL / DirectX 约定不同）

void fragment() {
	// ★ Godot 片元里的 VERTEX / NORMAL 是**视图空间**，用 INV_VIEW_MATRIX 转回世界空间。
	//   （实测：裸 NORMAL 在画面中心是 (0,0,1)，即指向相机 —— 那是视图空间，不是世界空间。）
	vec3 wpos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 N = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);

	// —— 法线贴图 → 世界空间法线 ——
	// 切向基**不手搓**（球面解析切向的朝向很容易搞反），改用屏幕空间导数构造 cotangent frame：
	// 它自动贴合网格的 UV 布局，换贴图 / 换 UV 都不会错。
	// ★★ 第二十七轮修掉的精度坑：导数必须在**视图空间**（`VERTEX`）上取，**不能**用世界空间 wpos。
	//   地球离世界原点约 2.3 万单位，float32 在那里一个 ulp ≈ 0.002 单位 ≈ 12 km；
	//   而贴脸时相邻像素的世界距离只有零点几 km ⇒ dFdx(wpos) 被量化成 0 或乱跳，
	//   切向基整段失效（法线图与地势起伏**同时**失灵，画面看上去「只有贴图没有明暗」）。
	//   视图空间的原点在相机 ⇒ 数值只有 1~2 个单位，精度足够；再**只旋转**回世界空间即可。
	vec3 N2 = N;
	vec3 Tn = vec3(0.0);   // 单位切向（+u 方向，世界空间）
	vec3 Bn = vec3(0.0);   // 单位副切向（+v 方向，世界空间）
	vec3 dp1 = dFdx(VERTEX);
	vec3 dp2 = dFdy(VERTEX);
	vec2 duv1 = dFdx(UV);
	vec2 duv2 = dFdy(UV);
	vec3 T = (INV_VIEW_MATRIX * vec4(dp1 * duv2.y - dp2 * duv1.y, 0.0)).xyz;
	vec3 B = (INV_VIEW_MATRIX * vec4(dp2 * duv1.x - dp1 * duv2.x, 0.0)).xyz;
	float tl = length(T);
	float bl = length(B);
	if (tl > 1e-9 && bl > 1e-9) {
		Tn = T / tl;
		Bn = B / bl;
		vec3 nt = texture(tex_normal, UV).xyz * 2.0 - 1.0;
		nt.xy *= normal_strength;
		if (normal_flip_y) {
			nt.y = -nt.y;
		}
		// ★ 法线图的 B **不可信**：它按「法线图 + VRAM 压缩」导入 ⇒ 存成 RGTC/BC5（只留 R/G 两通道），
		//   采样回来的蓝通道恒为 0 ⇒ 若直接拿它当 z，nt.z 就恒为 -1、法线整体翻成 -N
		//   （昼夜与海面高光会全部反过来；实测调试通道里 B=0 已坐实）。
		//   ⇒ 由 R/G 反解 z（这正是 RGTC 的重构公式）：贴图带不带 B 都正确，平坦区（源图 B=255）结果等价。
		nt.z = sqrt(max(0.0, 1.0 - dot(nt.xy, nt.xy)));
		N2 = normalize(Tn * nt.x + Bn * nt.y + N * nt.z);
	}

	// —— 昼夜混合 ——
	// 白天贴图用**较宽**的 smoothstep 淡出到夜面（用户要求「昼夜贴图的过渡要有淡入淡出」）；
	// 城市灯光另用一条**独立**的 smoothstep（见下）⇒ 灯光只在深入夜面后才出现，范围比夜半球小得多。
	vec3 L = normalize(sun_dir);
	float ndl = dot(N2, L);
	float day_f = smoothstep(-terminator_soft, terminator_soft, ndl);

	vec3 day_c = texture(tex_day, UV).rgb;
	// ★ 第二十六轮：近景「瓦片高清补丁」——把相机脚下那一小块**陆地**换成素材库瓦片。
	//   仅陆地生效：tex_spec 的「水 = 白 / 陆 = 黑」掩码保证海洋照旧走 8K 底图
	//   （瓦片的海洋色与底图不同，不盖就不会在海岸线露缝）。
	float sea = texture(tex_spec, UV).r;
	if (detail_blend > 0.001) {
		// 块内归一化坐标：u 方向经度跨 ±180 时 rel.x < 0 ⇒ fract 自动 +1（块左右环绕自然衔接）
		vec2 rel = vec2(fract(UV.x - detail_rect.x), UV.y - detail_rect.y);
		vec2 nrm = rel / detail_rect.zw;
		// 到块边界的最小距离：越界 ⇒ < 0 ⇒ 权重 0（块外完全不采瓦片）
		float edge = min(min(nrm.x, 1.0 - nrm.x), min(nrm.y, 1.0 - nrm.y));
		float w = smoothstep(0.0, detail_edge, edge) * detail_blend * (1.0 - sea);
		if (w > 0.001) {
			vec2 t = clamp(nrm, vec2(0.0), vec2(1.0)) * detail_grid;
			vec2 ti = clamp(floor(t), vec2(0.0), detail_grid - vec2(1.0));
			vec2 tf = t - floor(t);
			vec2 atlas_uv = (ti + tf) / detail_grid;
			day_c = mix(day_c, texture(tex_detail, atlas_uv).rgb, w);
		}
	}
	vec3 col = day_c * day_gain * day_f;                       // 向阳面：白天贴图
	col += day_c * night_base * (1.0 - day_f);                 // 背阳面：极暗底色

	// —— 近景「地势起伏」：海拔栅格 → 坡度 → 地形明暗 ——
	// 取 UV 邻域四个高度做中心差分（栅格是等距圆柱，u 方向的实际距离要乘 cos(纬度)，否则
	// 高纬度的山脊会被算成陡得多 / 平得多）；把坡度折进**世界空间法线**，再拿它跟太阳算一次
	// 余弦，得到「该点比同位置的平坦球面亮多少 / 暗多少」——这份差异就是肉眼看到的地势起伏。
	// ★ 只在陆地（1−sea）与白天（day_f）生效；海洋没有海拔数据，不应凭空出现阴影。
	if (height_blend > 0.001) {
		float hu = 1.0 / max(height_tex_size.x, 1.0);
		float hv = 1.0 / max(height_tex_size.y, 1.0);
		float h_l = texture(tex_height, UV - vec2(hu, 0.0)).r;
		float h_r = texture(tex_height, UV + vec2(hu, 0.0)).r;
		float h_d = texture(tex_height, UV + vec2(0.0, hv)).r;
		float h_u = texture(tex_height, UV - vec2(0.0, hv)).r;
		float coslat = max(cos((0.5 - UV.y) * PI), 0.02);
		float du_m = TAU * 6371000.0 * coslat;    // 每 1.0 个 UV 对应的地面米数（u 方向，随纬度收缩）
		float dv_m = PI * 6371000.0;              // v 方向
		float gu = (h_r - h_l) * height_max_m / (2.0 * hu) / du_m;   // 无量纲坡度（米 / 米）
		float gv = (h_d - h_u) * height_max_m / (2.0 * hv) / dv_m;
		// ★ 切向基用**解析式**（东 = up×N，南 = 东×N），不用屏幕导数：
		//   贴脸时可见地面只有一两百 km、一屏只跨一两个网格四边形，屏幕导数会退化（tl/bl 趋 0，
		//   整个起伏段被 skip —— 实测 1.02R 差异恒为 0 就是这个原因）；解析式在任何距离都稳。
		//   本工程的球面 UV 就是等距圆柱（u 随经度增、v 随纬度减），与解析基一一对应。
		vec3 Tu = normalize(cross(vec3(0.0, 1.0, 0.0), N));
		vec3 Tv = cross(Tu, N);
		vec3 Nh = normalize(N2 - (gu * Tu + gv * Tv) * height_exag);
		float relief = clamp(1.0 + height_shade * (dot(Nh, L) - ndl), 0.55, 1.55);
		col *= mix(1.0, relief, height_blend * (1.0 - sea) * day_f);
	}

	// —— 夜面：城市灯光 ——
	// ① 先整幅减掉 night_floor（裁掉 BC1 在近黑区压出的块状/条状噪声）；
	// ② 再按亮度过一道软门（night_gate_*）：把夜景图自带的稀薄云底/陆底压掉，只留明亮城市灯光；
	// ③ 最后乘 night_f：灯光只在 N·L 深入负值后才淡入 ⇒ 作用范围收窄。
	vec3 night_c = max(texture(tex_night, UV).rgb - vec3(night_floor), vec3(0.0));
	float night_lum = max(night_c.r, max(night_c.g, night_c.b));
	night_c *= smoothstep(night_gate_lo, night_gate_hi, night_lum);
	float night_f = 1.0 - smoothstep(-night_full, -night_start, ndl);
	col += night_c * night_gain * night_f;

	// —— 海面镜面反射太阳光 ——
	// tex_spec 实测 **水 = 白 / 陆 = 黑** ⇒ 它的红通道直接就是「海面掩码」（见上面 detail 段已取 sea）。
	vec3 V = normalize(CAMERA_POSITION_WORLD - wpos);
	vec3 H = normalize(L + V);
	float spec = pow(max(dot(N2, H), 0.0), shininess) * sea * day_f;
	col += sun_color * spec * spec_gain;

	// —— 时区视图：24 条 15° 经度带（带心在本初子午线，边界 ±7.5° + 15k）——
	// ★ 只做「视觉参考」：不追求现实时区的折线边界，按用户要求把经度平均切 24 份，
	//   但切法与现实时区的位置对得上（UTC+0 以格林尼治为中心）。
	if (view_mode == 1) {
		float lon_deg = (UV.x - 0.5) * 360.0;
		float t = (lon_deg + 7.5) / 15.0;           // 整数 = 边界，floor(t) = 带序号（=UTC 偏移 + 12 的近似）
		float band = floor(t);
		float parity = mod(band, 2.0);
		vec3 tint = mix(vec3(0.72, 0.86, 1.15), vec3(1.15, 0.86, 0.72), parity);  // 冷 / 暖交替
		col = mix(col, col * tint, 0.5);
		// 边界细线：宽度随屏幕导数自适应（贴脸看也不会变成粗色条）
		float f = t - band;
		float d = min(f, 1.0 - f) * 15.0;           // 到最近边界的度数
		float aa = max(fwidth(lon_deg) * 0.8, 0.02);
		float line = 1.0 - smoothstep(aa * 0.5, aa, d);
		col = mix(col, vec3(0.95, 0.98, 1.0), line * 0.75);
	}

	// —— 人口密度视图 ——
	// v 是**对数**索引：色带因此在对数尺度上均匀「好认」—— 深蓝 = 荒野、青绿 = 乡村、
	// 黄 = 小城、橙红 = 城市、亮红 = 都会核心。无人区（v 接近 0）保留原底色，不把海洋涂蓝。
	if (view_mode == 2) {
		float v = texture(tex_pop, UV).r;
		vec3 pop_col = mix(vec3(0.06, 0.16, 0.45), vec3(0.08, 0.62, 0.55), smoothstep(0.00, 0.25, v));
		pop_col = mix(pop_col, vec3(0.93, 0.86, 0.28), smoothstep(0.25, 0.50, v));
		pop_col = mix(pop_col, vec3(0.95, 0.45, 0.16), smoothstep(0.50, 0.75, v));
		pop_col = mix(pop_col, vec3(0.98, 0.13, 0.11), smoothstep(0.75, 1.00, v));
		float mask = smoothstep(0.015, 0.05, v);          // < ~1 人/km² 视为无人区
		col = mix(col, pop_col * mix(0.55, 1.0, day_f), mask * 0.92);
	}

	// —— 气候分布视图 ——
	// 直接用 Köppen 配色图（海洋在转换时被写成纯黑 ⇒ 这里跳过，海洋照旧显示地球本色）。
	if (view_mode == 3) {
		vec3 cc = texture(tex_climate, UV).rgb;
		float land = step(0.02, max(cc.r, max(cc.g, cc.b)));
		col = mix(col, cc * mix(0.55, 1.0, day_f), land * 0.92);
	}

	ALBEDO = col;
}
