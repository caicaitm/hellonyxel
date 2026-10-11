extends Node

# ============================================================================
# 桌面穿透（鼠标层） —— autoload 名：MousePassRunner
#
# 目标：「没画东西的地方」点击**直达下层**（桌面 / 其他窗口）；
#       「画了东西的地方」（积木、UI 面板）仍由本场景接收。
#
# 实现：DisplayServer.window_set_mouse_passthrough(多边形)
#   多边形**内部** = 本窗口接收鼠标；**外部** = 事件穿透到下层。
#
# ★★ Windows 上这条 API 是 SetWindowRgn 语义：区域之外**既不接收鼠标、也不绘制**。
#    也就是说区域必须把所有「画出来的东西」都包进去 —— **漏一个，它就会当场消失**。
#    因此本脚本的策略是「宁大勿小」：积木按外扩网格取整，UI 取**所有可见 Control** 的矩形。
#    （实测证据：把区域设成屏幕一角后，区域之外的积木全部消失。）
#    例外：带「桌面屏障」标签的积木位于屏幕外、且不绘制 → 直接排除（见 _collect_rects）。
#
# ★★ 另一个约束：这条 API 只收**一个**多边形，而我们要表达的是「一堆互不相交的矩形」。
#    直接把多个矩形首尾相接会因为在两条矩形之间产生"跳跃边"而算错填充，
#    直接把重叠矩形接起来又会因 GDI 的奇偶填充在重叠处挖洞。所以这里老老实实做三步：
#      1) _union_strips  —— 矩形并集 → **互不相交**的竖条
#      2) _connect_strips —— 加"梳齿"把竖条连成**一个连通体**（否则会得到多个环）
#      3) _trace_outline  —— 拆边 + 抵消共边 + 串环 → **单环**轮廓
#    任何一步算不出合法结果，都退化为「满屏区域」= 关闭穿透（绝不让窗口被裁没）。
#
# ★ 顺带一提：DisplayServer.WINDOW_FLAG_MOUSE_PASSTHROUGH 在 Windows 上**不是**
#   桌面穿透（实测它不改窗口扩展样式、命中测试照样命中本窗口），别用它。
#
# ★★ 弹窗（下拉菜单 / 弹窗面板 / tooltip）必须在展开期间**临时满屏**，否则会被裁没：
#   它们是「嵌入式子窗口」，画在本窗口内部、却在接收区之外 → SetWindowRgn 直接切掉。
#   判据 = `Viewport.get_embedded_subwindows()`（**只返回可见的**，实测不会误报），
#   见 `_popup_expanded()`。**不要**靠「逐个下拉登记」——漏一个就废一个（历史 bug）。
#
# 🔛 开关：**默认开启**（enabled=true）—— 启动即穿透：
#   空白处的点击/右键**直达桌面**（系统菜单、桌面图标可正常操作）；"画了东西的地方"
#   （积木、UI 面板）仍在接收区内、照常可点。
#   ★ 关掉的唯一入口 = **系统托盘右键菜单**（见 TrayIcon.cs / TrayRunner.gd:100）；
#     调试面板的「桌面穿透」按钮可来回切；Tab 键只在**未开启**时把它打开一次。
#   ★ 历史：2026-09-30 之前默认是 false（启动不穿透，右键空白弹游戏菜单）。
# ============================================================================

const GRID := 8.0     # 矩形坐标向外吸附到 8px 网格：拖动时区域不会每帧都变
const EPS := 0.5      # 浮点比较容差
const DEBUG_LOG := false

var enabled := true

# 桌面穿透开关变化时发出（调试面板据此刷新状态显示）
signal enabled_changed(on: bool)

var _started := false
# 上一帧"会被画出来"的矩形。★ 批次 6：原来是 `_last_sig: String`（把每个矩形拼成
# "x0,y0,x1,y1" 再**排序 + join** 成一个长串），实测在面板全开（391 个矩形）时要 **413 µs/帧**
# —— 比整个遍历还贵。改成**逐项比较**后只要 **30 µs/帧**（−93%），且不分配字符串。
# ★ 逐项比较**没有假阴性**（不会漏掉真变化）；顺序变了只会造成假阳性 → 多算一次多边形，
#   而多边形重建本身已被 C6-4 降到亚毫秒，所以假阳性的代价可以接受。
var _last_rects: Array = []
var _poly_points := 0
var _apply_count := 0
# 是否有"已展开的下拉/弹窗"正在显示：展开期间临时用满屏区域(整窗可绘制)，
# 否则 SetWindowRgn 会把超出接收区的下拉裁没看不见。
# ★★ 批次66：权威判据 = `_popup_expanded()` 每帧扫 `Viewport.get_embedded_subwindows()`
#   （**只返回可见的**嵌入式子窗口）→ 覆盖所有弹窗、无需任何调用方登记。
var _popup_full: bool = false
# 显式登记的下拉/弹窗计数（about_to_popup +1 / popup_hide -1）。
# ★★ 批次66 起**仅作退化兜底**（老版本 Godot 无 get_embedded_subwindows 时才用）；
#   它要求每个下拉都记得登记 + 依赖 popup_hide 送达 → 曾导致大量下拉被裁没，故降级。
var _popup_refcount: int = 0


func _ready() -> void:
	# 允许用环境变量关掉（排障用）：HELLONYXEL_NO_PASSTHROUGH=1
	if OS.get_environment("HELLONYXEL_NO_PASSTHROUGH") == "1":
		enabled = false
		print("[MousePass] 已按环境变量禁用桌面穿透")
		return
	call_deferred("_deferred_start")


func _deferred_start() -> void:
	await get_tree().process_frame
	_started = true
	# 默认开启穿透（enabled=true）：等场景树建好后再应用接收区，
	# 否则启动瞬间还没有任何 Control/积木 → 区域算出来是空的 → 整窗被裁没。
	if enabled:
		_apply(true)


func _process(_delta: float) -> void:
	if not (_started and enabled):
		return
	# ★★ 批次66：**全局**判据 —— 只要有任何**可见的嵌入式子窗口**正在显示（下拉菜单 PopupMenu、
	#   弹窗面板 PopupPanel、乃至 Godot 自己为 tooltip 建的 TooltipPanel），就临时满屏(整窗可绘制)，
	#   关闭后恢复裁剪区。
	#   为什么不只靠 suspend_passthrough_for_popup 的引用计数：那要求**每个**下拉都记得登记，
	#   而全项目上十个 OptionButton 只登记了一个 → 其余下拉一展开，超出面板/接收区的部分
	#   就被 SetWindowRgn 当场裁没（**用户报的正是这个 bug**）。扫描「所见即所得」，无需登记，
	#   新增下拉也不必改任何调用方。
	if _popup_expanded():
		if not _popup_full:
			DisplayServer.window_set_mouse_passthrough(PackedVector2Array())
			_popup_full = true
			_last_rects.clear()   # 弹窗关闭后强制重算裁剪区
		return
	if _popup_full:
		_popup_full = false
		_last_rects.clear()   # 触发重算裁剪区
	_apply(false)


# ---- 是否有「展开中的弹窗」----
#
# ★★ 批次66：`Viewport.get_embedded_subwindows()` 只返回**可见的**嵌入式子窗口 ——
#    headless 探针实测：PopupPanel 只入树未显示 → n=0；`popup_centered()` 后 → n=1；
#    `hide()` 后 → n=0。即它天然就是「现在屏上有没有弹窗」的准确判据，**不会误报**。
#    因此以它为准：准确 + 自愈（不依赖 `popup_hide` 信号是否送达）+ **新增下拉零改动**。
#
#   ★ 只看**列表成员资格**，不看 `Window.visible`：
#     ① 该列表**只装可见的**嵌入式子窗口（实测：隐藏后立即为 0，headless 与带窗口都验过）；
#     ② 本项目实证嵌入式 Window 的 `visible` 不可靠（dialogue_debug_panel.gd 记着
#        「headless 下恒为 true」），拿它当判据反而可能抖动 → 不做多余过滤。
#   ★ 退化路径：若某版本 Godot 没有该 API，回到 `suspend_passthrough_for_popup` 的引用计数。
func _popup_expanded() -> bool:
	var vp := get_viewport()
	if vp != null and vp.has_method("get_embedded_subwindows"):
		return not vp.get_embedded_subwindows().is_empty()
	return _popup_refcount > 0


# 各下拉/弹窗在创建 popup 后调用一次：展开期间临时满屏(整窗可绘制)，
# 避免被 SetWindowRgn 裁没看不见。内部用引用计数，支持同时多个弹窗；popup 为 null 自动忽略。
# ★★ 批次66：本函数已**不再是必需步骤** —— 现在由 `_popup_expanded()` 每帧扫
#   `Viewport.get_embedded_subwindows()` 自动覆盖所有弹窗（含未登记的）。保留它是为了：
#     ① 老版本 Godot 没有该 API 时的退化通道；② 语义直白，便于调用方表达意图。
#   注意：**不要**再用它来判「弹窗是否展开」——`popup_hide` 可能因异常丢失导致计数卡死
#   （dialogue_debug_panel.gd 就为此加了 2s 硬超时），而扫描没有这个问题。
func suspend_passthrough_for_popup(popup: Window) -> void:
	if popup == null or not is_instance_valid(popup):
		return
	if not popup.is_connected("about_to_popup", _on_popup_about_to_show):
		popup.about_to_popup.connect(_on_popup_about_to_show)
	if not popup.is_connected("popup_hide", _on_popup_hidden):
		popup.popup_hide.connect(_on_popup_hidden)


func _on_popup_about_to_show() -> void:
	_popup_refcount += 1


func _on_popup_hidden() -> void:
	_popup_refcount = maxi(0, _popup_refcount - 1)


# ============ 对外 API（事件链 / 调试面板可调用）============

# 开/关桌面穿透。关掉时清空区域 = 整窗可点（恢复普通窗口行为）
func set_enabled(on: bool) -> void:
	if enabled == on:
		return
	enabled = on
	_popup_full = false
	if on:
		# 若在弹窗展开期间重开穿透，直接保持满屏(整窗可绘制)，避免弹窗被裁
		if _popup_refcount > 0:
			DisplayServer.window_set_mouse_passthrough(PackedVector2Array())
			_popup_full = true
		else:
			_apply(true)
	else:
		_last_rects.clear()
		DisplayServer.window_set_mouse_passthrough(PackedVector2Array())
	enabled_changed.emit(on)


func is_enabled() -> bool:
	return enabled


# 强制立即重算（布局大改后可调，正常每帧会自动跟）
func force_refresh() -> void:
	if enabled:
		_apply(true)


func debug_info() -> String:
	return "MousePass enabled=%s 多边形点数=%d 重算次数=%d" % [enabled, _poly_points, _apply_count]


# ============ 主流程 ============

# ★ 自测量（批次 1）：闸门关闭时只多一次 bool 读，零计时开销。
#   注意 `_collect_rects()` 在签名比对**之前**执行 ⇒ 它每帧都跑，是本函数的主要开销，
#   所以要连早退路径一起计时（而不是只量"真的重算了"的那几次）。
func _apply(force: bool) -> void:
	if PerfMonitor.profiling:
		var t0 := Time.get_ticks_usec()
		_apply_impl(force)
		PerfMonitor.add_span("pass_apply", Time.get_ticks_usec() - t0)
		return
	_apply_impl(force)


func _apply_impl(force: bool) -> void:
	var rects := _collect_rects()
	# ★ 自测量（批次 6）：把 pass_apply 拆成"收集 / 比对 / 建多边形"三段。
	#   比对是**每帧都做**的那一步（短路只省掉建多边形），所以要单独量。
	var t1: int = 0
	if PerfMonitor.profiling:
		t1 = Time.get_ticks_usec()
	var unchanged := _same_rects(rects)
	if PerfMonitor.profiling:
		PerfMonitor.add_span("pass_sig", Time.get_ticks_usec() - t1)
	if not force and unchanged:
		return
	_last_rects = rects
	var t2: int = 0
	if PerfMonitor.profiling:
		t2 = Time.get_ticks_usec()
	var poly := _build_polygon(rects)
	if PerfMonitor.profiling:
		# 只在真的变了才重建 → 多数窗口里这一项不会产生数据（面板显示"—"），属正常
		PerfMonitor.add_span("pass_poly", Time.get_ticks_usec() - t2)
	_poly_points = poly.size()
	_apply_count += 1
	DisplayServer.window_set_mouse_passthrough(poly)
	if DEBUG_LOG:
		print("[MousePass] 区域矩形 %d 个 → 多边形 %d 点" % [rects.size(), _poly_points])


# ---- 1) 收集所有"会被画出来"的矩形 ----

func _collect_rects() -> Array:
	var raw: Array = []
	var vp := get_viewport().get_visible_rect().size
	var screen := Rect2(Vector2.ZERO, vp)
	var t_blk: int = 0
	if PerfMonitor.profiling:
		t_blk = Time.get_ticks_usec()

	# 积木：位置是**中心点**，width/height 是尺寸（block.gd 里 _draw 以中心为原点）
	# ★ 批次 6：原来用 `b is Node2D` + `n2.get("tags"/"width"/"height")` 的**鸭子类型**访问，
	#   每次 get() 都是一次"按名查属性"的哈希查找，实测 335 µs/帧。
	#   组 "block" 全项目只有 blocks/block.gd 会 join（已核）⇒ 直接按 `Block` 类型取字段，
	#   实测降到 **194 µs/帧（−42%）**，且两种写法收集到的矩形**逐项一致**（探针 0 次不一致）。
	for b in get_tree().get_nodes_in_group("block"):
		if not is_instance_valid(b) or not (b is Block):
			continue
		var blk: Block = b
		if not blk.is_visible_in_tree():
			continue
		# 「桌面屏障」/「任务栏屏障」（屏幕外的、不可见的 1px 碰撞墙）不计入穿透区域。
		# 否则会外扩+吸附网格，在屏幕边多出若干条不可穿透的窄条（那里本应能点到桌面）。
		# ★ 系统自动生成的环境积木——桌面图标边界墙 / 程序页面边框与覆盖（都带 BlockTags.AUTO_GENERATED）——
		#   **不进入接收区**。这是刻意的：它们只是画出来的"页面/图标"假象，不是真实可交互内容。
		#   若计入，巨大覆盖积木会把几乎整屏占进接收区 → 桌面穿透就失效了（本 bug 的根因）。
		#   穿透开启时它们被 SetWindowRgn 裁掉（正好"透过"看到真实桌面）；穿透关闭时整窗绘制，它们照常可见。
		# ★ 例外：同时带 BlockTags.LEVEL_PAGE 的「关卡页面」积木是**真实可交互的游戏表面**，
		#   要计入接收区（否则穿透开启时页面会被裁没、按钮点不到）。
		var tg: PackedStringArray = blk.tags
		if BlockTags.DESKTOP_BARRIER in tg \
				or BlockTags.DESKTOP_TASKBAR in tg \
				or (BlockTags.AUTO_GENERATED in tg and not BlockTags.LEVEL_PAGE in tg):
			continue
		# ★★ 被 cutout 镂空遮罩盖住的积木（典型：被程序窗口盖住的桌面图标）**不进入接收区**。
		#   背景：cutout 把洞内像素乘 0 → 这块积木已经**看不见**了；批次 10 也已让它**点不动**
		#   （`Block.is_point_covered` 接入 _unhandled_input / _physics_step / _block_under_point）。
		#   但 SetWindowRgn 语义只看「矩形在不在区域里」—— 积木本身还活着、矩形还在，
		#   于是这块**看不见也点不动**的死区仍然把鼠标吃在本窗口上，
		#   用户的观感就是「被窗口盖住的那块地方点不动、点不到下面的真实窗口」。
		#   这里把判定与 `is_point_covered` 保持同一把尺子（cutout + 显示层更高 + 同场景 + 可见），
		#   用**矩形中心**取样（与批次 10 的点判定一致）；中心被盖住即整块排除。
		if _is_rect_covered_by_cutout(blk):
			continue
		var w: float = blk.width
		var h: float = blk.height
		if w <= 0.0 or h <= 0.0:
			continue
		# ★ 本区域是**屏幕像素**（SetWindowRgn 用），而积木的 global_position 是**画布坐标**：
		#   关卡页面在自己的 CanvasLayer 里、浮层面板层还带 UI 缩放 → 必须按所在画布换算，
		#   否则接收区与画面错位（漏一个就会被裁没）。外扩 4px 也放在屏幕像素上。
		var xf: Transform2D = blk.get_canvas_transform()
		var sz: Vector2 = xf.basis_xform(Vector2(w, h)).abs()
		var ctr: Vector2 = xf * blk.global_position
		raw.append(Rect2(ctr - sz * 0.5, sz).grow(4.0))

	# UI：所有可见 Control（含挂在积木上的文本框 TextBoxView）
	var t_ctl: int = 0
	if PerfMonitor.profiling:
		t_ctl = Time.get_ticks_usec()
		PerfMonitor.add_span("pass_blocks", t_ctl - t_blk)
	_collect_controls(get_tree().root, raw)
	if PerfMonitor.profiling:
		PerfMonitor.add_span("pass_ctrl", Time.get_ticks_usec() - t_ctl)

	# 向外吸附网格 + 裁到屏幕内
	var out: Array = []
	for r in raw:
		var rr0: Rect2 = r
		var x0 := floorf(rr0.position.x / GRID) * GRID
		var y0 := floorf(rr0.position.y / GRID) * GRID
		var x1 := ceilf(rr0.end.x / GRID) * GRID
		var y1 := ceilf(rr0.end.y / GRID) * GRID
		var rr := Rect2(x0, y0, x1 - x0, y1 - y0).intersection(screen)
		if rr.size.x >= 1.0 and rr.size.y >= 1.0:
			out.append(rr)
	return out


# ★★ 批次 6：原来这里是**每节点一次 GDScript 递归调用** + `get_children()`（每节点分配一个
#   Array）+ 对每个 Control 调 `is_visible_in_tree()`（O(深度)）。实测 1142 µs/帧（面板全开、
#   1536 个节点、391 个可见控件），是 `pass_apply` 的 68%，**全场最贵的一步**。
#   两处改动都**不改语义**：
#     ① 显式栈代替递归 —— 去掉 1500+ 次 GDScript 函数调用（GDScript 调用很贵）；
#        用 get_child_count()/get_child(i) 代替 get_children()，去掉每节点一次数组分配。
#     ② 整棵跳过"本地不可见"的 CanvasItem / 不可见 CanvasLayer 子树。
#        依据：`CanvasItem.is_visible_in_tree()` ⟺ 自身与**所有祖先 CanvasItem** 均 visible，
#        且所在 CanvasLayer 可见 ⇒ 父不可见时，子树内任何节点都不可能可见，整棵跳过是等价变换。
#        所以这里不再需要逐控件的 `is_visible_in_tree()`（可见性已由剪枝保证）。
#   实测：1142 → **724 µs/帧（−37%）**；矩形集合与旧实现**逐项完全一致**（探针同帧对比 0 差异）。
## ★★ 该积木是否被 cutout 镂空遮罩盖住（= 不可见 + 点不动）。
##   判据与 `Block.is_point_covered` **完全同一把尺子**（批次 10 定的输入侧规则）：
##     同场景 + 遮罩带 cutout 且 show + 可见 + 遮罩 display_layer **严格更高** + 遮罩 AABB 含取样点。
##   取样点用**积木矩形中心**（与点判定一致的直觉：一个图标被整块盖住 → 中心必在洞内）。
##   为什么放在这里：SetWindowRgn 只看矩形在不在区域里，被盖住的积木矩形仍在
##   → 看不见也点不动的「死区」把鼠标吃掉。本函数让这类积木不进接收区，
##   鼠标便能穿透到下层的真实窗口。
func _is_rect_covered_by_cutout(blk: Block) -> bool:
	if not (BlockTags.SHOW in blk.tags):
		return false
	var tree := get_tree()
	if tree == null:
		return false
	var my_scene: Node = blk._scene_of()
	var my_layer: float = blk.display_layer
	# 积木自身中心（画布坐标）—— 与 _aabb_at 同源，旋转不参与（项目不做旋转）
	var ctr: Vector2 = blk.global_position
	for other in tree.get_nodes_in_group("block"):
		if not is_instance_valid(other) or other == blk or not (other is Block):
			continue
		var ob: Block = other
		if not (BlockTags.CUTOUT in ob.tags) or not (BlockTags.SHOW in ob.tags):
			continue
		if not ob.is_visible_in_tree():
			continue
		if ob._scene_of() != my_scene:
			continue
		if ob.display_layer <= my_layer:
			continue
		if ob._aabb_at(ob.global_position).has_point(ctr):
			return true
	return false


func _collect_controls(root: Node, out: Array) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var cnt := n.get_child_count()
		for i in cnt:
			var c := n.get_child(i)
			if c is CanvasItem and not (c as CanvasItem).visible:
				continue
			if c is CanvasLayer and not (c as CanvasLayer).visible:
				continue
			if c is Control:
				var ctl := c as Control
				if ctl.size.x > 0.0 and ctl.size.y > 0.0:
					# ★ 用 with_canvas 版本换算到**屏幕像素**：`Control.get_global_rect()` 只到画布为止、
					#   **不含** CanvasLayer 的 UI 缩放 → 缩放 ≠ 1 时接收区会与画面错位（漏一个就被裁没）。
					var xf: Transform2D = ctl.get_global_transform_with_canvas()
					out.append(Rect2(xf.origin, xf.basis_xform(ctl.size).abs()))
				# ★ ScrollContainer 会裁掉超出其视口的子控件（只渲染滚动可视区）。
				#   但子控件的**几何矩形不被裁减**——它们仍按完整内容尺寸排布，会一直延伸到
				#   滚动可视区之外。若把这些子矩形也并进桌面穿透接收区，滚动内容越长、
				#   穿透死区越大（事件链编辑器默认就中招：内容矮、面板却被写死成 760 上限，
				#   底部大片空背景仍算进接收区 → 开窗后穿透失效）。
				#   ScrollContainer 自身的矩形 = 可视区，已经覆盖里面所有可见控件，
				#   所以只取它自己的矩形、不再下钻其子节点。
				if c is ScrollContainer:
					continue
			stack.append(c)


# 与上一帧的矩形**逐项**比较（不排序、不拼串、不分配）。
# ★ 没有假阴性（真变化一定测得出）；顺序变了只会假阳性 → 多算一次多边形（已被降到亚毫秒，无妨）。
func _same_rects(rects: Array) -> bool:
	if rects.size() != _last_rects.size():
		return false
	for i in rects.size():
		var a: Rect2 = rects[i]
		var b: Rect2 = _last_rects[i]
		if a.position != b.position or a.size != b.size:
			return false
	return true


# ---- 2) 多边形构造 ----

func _build_polygon(rects: Array) -> PackedVector2Array:
	var vp := get_viewport().get_visible_rect().size
	var full := PackedVector2Array([
		Vector2.ZERO, Vector2(vp.x, 0.0), Vector2(vp.x, vp.y), Vector2(0.0, vp.y),
	])
	if rects.is_empty():
		# 什么都没画：给一个小锚点区域。空区域会把窗口整个裁掉，所以绝不能用空数组
		return PackedVector2Array([Vector2.ZERO, Vector2(GRID, 0.0), Vector2(GRID, GRID), Vector2(0.0, GRID)])

	var strips := _coalesce(_union_strips(_prune_contained(rects)))
	if strips.is_empty():
		return full
	var strips2 := _coalesce(_union_strips(_connect_strips(strips)))
	if strips2.is_empty():
		return full
	var loop := _trace_outline(strips2)
	if loop.size() < 3:
		# 兜底：算不出轮廓就"整窗可点"，宁可没有穿透，也不能把窗口裁没
		push_warning("[MousePass] 轮廓构造失败，退化为整窗可点")
		return full
	return loop


# ★★ 批次 6：丢掉"被另一个矩形完全包住"的矩形后再做几何计算。
#
# 为什么必须做：`_union_strips` 的复杂度是 **O(唯一 x 坐标数 × 矩形数)**。
#   面板全开时矩形数 391 → 唯一 x 约 400 → 单次 `_build_polygon` 实测 **13.6 ms**！
#   而**拖拽积木会每帧改变区域 ⇒ 每帧重建 ⇒ 明显卡顿**（`pass_poly` 在静态窗口里几乎为 0，
#   所以之前没被发现）。
#
# 为什么是等价变换：B ⊆ A ⟹ A ∪ B = A。所以丢掉被包住的矩形**不改变并集**，
#   而 `_union_strips` 之后的所有步骤（合并竖条 / 连成连通体 / 串轮廓）都只依赖并集
#   ⇒ **最终区域完全相同**（点序列可能不同、通常还会更少）。
#   实测：391 → 数十个，单次从 13.6 ms 降到亚毫秒。
#
# 做法：按面积从大到小扫，只跟"已保留"的小集合比包含关系（大的先留 ⇒ 小集合一直很小），
#   避免 O(n²)。坐标在 `_collect_rects` 里已吸附到 8px 网格，用精确比较即可。
func _prune_contained(rects: Array) -> Array:
	var n := rects.size()
	if n < 2:
		return rects
	var areas: Array = []
	for r in rects:
		var rr: Rect2 = r
		areas.append(rr.size.x * rr.size.y)
	var idx: Array = []
	for i in n:
		idx.append(i)
	idx.sort_custom(func(a, b): return areas[a] > areas[b])
	var kept: Array = []
	for i in idx:
		var r: Rect2 = rects[i]
		var covered := false
		for k in kept:
			var kr: Rect2 = k
			if kr.position.x <= r.position.x and kr.position.y <= r.position.y \
					and kr.end.x >= r.end.x and kr.end.y >= r.end.y:
				covered = true
				break
		if not covered:
			kept.append(r)
	return kept


func _union_strips(rects: Array) -> Array:
	if rects.is_empty():
		return []
	var xs: Array = []
	for r in rects:
		xs.append(r.position.x)
		xs.append(r.end.x)
	xs.sort()
	var ux := _dedup(xs)

	var strips: Array = []
	for i in range(ux.size() - 1):
		var x0: float = ux[i]
		var x1: float = ux[i + 1]
		if x1 - x0 <= EPS:
			continue
		var xm := (x0 + x1) * 0.5
		var iv: Array = []
		for r in rects:
			if r.position.x - EPS <= xm and xm <= r.end.x + EPS:
				iv.append(Vector2(r.position.y, r.end.y))
		if iv.is_empty():
			continue
		iv.sort_custom(func(a, b): return a.x < b.x)
		var cur: Vector2 = iv[0]
		var merged: Array = []
		for k in range(1, iv.size()):
			var vk: Vector2 = iv[k]
			if vk.x <= cur.y + EPS:
				cur.y = maxf(cur.y, vk.y)
			else:
				merged.append(cur)
				cur = vk
		merged.append(cur)
		for m in merged:
			if m.y - m.x > EPS:
				strips.append(Rect2(x0, m.x, x1 - x0, m.y - m.x))
	return strips


# 把 y 区间相同的相邻竖条横向合并 —— 密集 UI（表格状控件）能从上万点压到几十点
func _coalesce(strips: Array) -> Array:
	if strips.is_empty():
		return []
	var by_y: Dictionary = {}
	for s in strips:
		var k := "%d|%d" % [roundi(s.position.y), roundi(s.end.y)]
		if not by_y.has(k):
			by_y[k] = []
		by_y[k].append(s)
	var out: Array = []
	for k in by_y.keys():
		var arr: Array = by_y[k]
		arr.sort_custom(func(a, b): return a.position.x < b.position.x)
		var cur: Rect2 = arr[0]
		for i in range(1, arr.size()):
			var s: Rect2 = arr[i]
			if s.position.x <= cur.end.x + EPS:
				cur = Rect2(cur.position, Vector2(maxf(cur.end.x, s.end.x) - cur.position.x, cur.size.y))
			else:
				out.append(cur)
				cur = s
		out.append(cur)
	return out


# 加"梳齿"：一条 1px 横脊 + 每条竖条一根 1px 竖齿 → 所有条带连成一个连通体。
# （之后的第二次并集会把重叠部分清理干净，所以这里不用小心翼翼。）
func _connect_strips(strips: Array) -> Array:
	var out: Array = []
	for s in strips:
		out.append(s)
	if strips.size() <= 1:
		return out
	var min_top := INF
	var min_left := INF
	var max_right := -INF
	for s in strips:
		var sr: Rect2 = s
		min_top = minf(min_top, sr.position.y)
		min_left = minf(min_left, sr.position.x)
		max_right = maxf(max_right, sr.end.x)
	var spine_y := maxf(0.0, min_top - 3.0)
	out.append(Rect2(Vector2(min_left, spine_y), Vector2(max_right - min_left, 1.0)))
	for s in strips:
		var sr2: Rect2 = s
		var h: float = sr2.position.y - spine_y + 1.0
		if h > 0.0:
			out.append(Rect2(Vector2(sr2.position.x, spine_y), Vector2(1.0, h)))
	return out


# 拆边 + 抵消共边 + 串环 → 单环轮廓。输入必须**互不相交**（由 _union_strips 保证）。
#
# ★★ 批次 6：原来顶点/边都用**字符串**做键 —— `_vk` 走 `"%d,%d" % [...]` 格式化，
#   `_add_edge` 拼 `ka + ">" + kb`，遍历时再 `String(key).split(">")` 解析回来。
#   面板全开时（393 矩形 → 33 条互不相交竖条）实测这一步独占 **1405 µs**，
#   占整条"建多边形"尾巴的 **91%**，全是字符串分配 / 解析的代价。
#   改用 **Vector2i（顶点）/ Vector4i（有向边）** 做键后零字符串、零解析。
#   ★ 语义完全不变：取整仍用 `roundi`，插入顺序不变（Godot Dictionary 保序），
#     起点仍是"最靠上、再靠左"，环的走向与**点序列逐点相同**（探针实测 poly_points_identical=true）。
func _trace_outline(strips: Array) -> PackedVector2Array:
	var xs: Array = []
	var ys: Array = []
	for s in strips:
		xs.append(s.position.x)
		xs.append(s.end.x)
		ys.append(s.position.y)
		ys.append(s.end.y)
	xs.sort()
	ys.sort()
	xs = _dedup(xs)
	ys = _dedup(ys)

	var edges: Dictionary = {}
	for s in strips:
		var corners: Array = [
			Vector2(s.position.x, s.position.y),
			Vector2(s.end.x, s.position.y),
			Vector2(s.end.x, s.end.y),
			Vector2(s.position.x, s.end.y),
		]
		for i in 4:
			_emit_split_edges(edges, corners[i], corners[(i + 1) % 4], xs, ys)

	var adj: Dictionary = {}
	for key in edges.keys():
		var e: Vector4i = key
		var ka := Vector2i(e.x, e.y)
		if not adj.has(ka):
			adj[ka] = []
		adj[ka].append(Vector2i(e.z, e.w))

	# 起点取最靠上、再靠左的那个顶点，环的走向稳定
	var start := Vector2i.ZERO
	var best := INF
	var found := false
	for key in adj.keys():
		var v: Vector2i = key
		var score := float(v.y) * 1000000.0 + float(v.x)
		if score < best:
			best = score
			start = v
			found = true
	if not found:
		return PackedVector2Array()

	var used: Dictionary = {}
	var loop := PackedVector2Array()
	var cur := start
	# 屏幕坐标恒 >= 0，用 (-1,-1) 当"没得走"的哨兵
	var none := Vector2i(-1, -1)
	for _guard in range(200000):
		loop.append(Vector2(cur.x, cur.y))
		var outs: Array = adj.get(cur, [])
		var chosen := none
		for o in outs:
			var ob: Vector2i = o
			var ek := Vector4i(cur.x, cur.y, ob.x, ob.y)
			if not used.has(ek):
				chosen = ob
				used[ek] = true
				break
		if chosen == none:
			break
		cur = chosen
		if cur == start:
			break
	if loop.size() < 3:
		return PackedVector2Array()
	return loop


func _emit_split_edges(edges: Dictionary, a: Vector2, b: Vector2, xs: Array, ys: Array) -> void:
	if absf(a.y - b.y) <= EPS:
		var lo := minf(a.x, b.x)
		var hi := maxf(a.x, b.x)
		if hi - lo <= EPS:
			return
		var cuts: Array = [lo]
		for x in xs:
			if x > lo + EPS and x < hi - EPS:
				cuts.append(x)
		cuts.append(hi)
		var l2r := b.x > a.x
		for i in range(cuts.size() - 1):
			var p0 := Vector2(cuts[i], a.y)
			var p1 := Vector2(cuts[i + 1], a.y)
			if l2r:
				_add_edge(edges, p0, p1)
			else:
				_add_edge(edges, p1, p0)
	elif absf(a.x - b.x) <= EPS:
		var lo := minf(a.y, b.y)
		var hi := maxf(a.y, b.y)
		if hi - lo <= EPS:
			return
		var cuts: Array = [lo]
		for y in ys:
			if y > lo + EPS and y < hi - EPS:
				cuts.append(y)
		cuts.append(hi)
		var t2b := b.y > a.y
		for i in range(cuts.size() - 1):
			var p0 := Vector2(a.x, cuts[i])
			var p1 := Vector2(a.x, cuts[i + 1])
			if t2b:
				_add_edge(edges, p0, p1)
			else:
				_add_edge(edges, p1, p0)


# 反向边成对抵消（= 两个矩形之间的公共内部边，不该出现在外轮廓上）
# ★ 批次 6：键从 `"x1,y1>x2,y2"` 字符串换成 `Vector4i(x1,y1,x2,y2)`（见 _trace_outline 注释）。
func _add_edge(edges: Dictionary, a: Vector2, b: Vector2) -> void:
	var ka := Vector2i(roundi(a.x), roundi(a.y))
	var kb := Vector2i(roundi(b.x), roundi(b.y))
	if ka == kb:
		return
	var key := Vector4i(ka.x, ka.y, kb.x, kb.y)
	var rev := Vector4i(kb.x, kb.y, ka.x, ka.y)
	if edges.has(rev):
		var c := int(edges[rev]) - 1
		if c <= 0:
			edges.erase(rev)
		else:
			edges[rev] = c
		return
	edges[key] = int(edges.get(key, 0)) + 1


func _dedup(sorted_vals: Array) -> Array:
	var out: Array = []
	for v in sorted_vals:
		if out.is_empty() or absf(float(v) - float(out[out.size() - 1])) > EPS:
			out.append(float(v))
	return out
