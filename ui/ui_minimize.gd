# ui/ui_minimize.gd
# 最小化按钮的**统一实现**（批次 80）—— 各窗口式面板复用同一份逻辑。
#
# 为什么抽组件：最小化这件事在项目里重复出现了多次（调试面板 / 弹窗对话面板 / 扫描重构页…），
#   每处各抄一遍 `set_minimized` 会出现：
#     · 行为不一致（有的忘了换「−/□」文案，有的忘了还原高度）
#     · 改一处漏一处
#   统一到这里后，各面板只需三步：
#     1) 顶栏加按钮：  _min_btn = UIMinimize.make_button()
#     2) 按钮回调：    _min_btn.pressed_id.connect(_on_min_btn_pressed)
#     3) 折叠实现：    set_minimized(not _minimized) → UIMinimize.fold_below(_content, ...) / fold_rows([...], ...)
#
# ★ 不变式（与批次 79 的需求一致）：
#   **顶栏永不隐藏** —— 折叠后「拖动把柄 / 最小化 / 关闭」三者仍在，
#   所以折叠状态下页面仍能拖走、也仍能真正关闭。
#
# 跳过最小化的面板（瞬态交互，折叠反而碍事）：右键菜单、子菜单、通知、确认框、
#   颜色选择器、文件选择对话框、对话气泡。
class_name UIMinimize
extends RefCounted

## 折叠后的默认高度（顶栏 28 + 上下内边距 12×2）。
const DEFAULT_MIN_H: float = 52.0
const PAD_X: float = 16.0          # 收窄时左右各留的余量
const BTN_GAP: float = 8.0          # 标题行里控件之间的默认间距

## 展开时的高度（按面板实例记）。首次折叠时记下当前高度，还原时恢复 ——
##   这样各面板**不必**再声明一个 FULL_H 常量（很多面板高度是动态算出来的）。
static var _full_h: Dictionary = {}      # instance_id → 展开时的 size
## 展开时的 custom_minimum_size.y（部分面板用它「顶住」尺寸，见 apply_size 的说明）。
static var _full_min_h: Dictionary = {}
## 展开时**面板自身**的 global_position：还原时按它把窗口归位，
## 否则折叠/还原后整窗会漂到一个新位置（尤其 UI 缩放 ≠ 1 时偏差明显）。
## ★★ key 用 target 的 instance_id（与 _full_h 一致），不是 panel —— 否则 _bg 类面板 erase 不到。
static var _full_pos: Dictionary = {}


## 造一个标准最小化按钮（− 最小化 / □ 还原）。
static func make_button(id: String = "minimize") -> UIBtn:
	var b := UIBtn.new()
	b.set_id(id)
	b.set_label("−")
	b.custom_minimum_size = Vector2(28, 28)
	b.tooltip_text = TranslationManager.t("最小化")
	return b


## ★ 各面板的**唯一一行接线**：造按钮、挂到顶栏、按下时回调面板自己的 set_minimized。
##   _min_btn = UIMinimize.attach(top, func(): set_minimized(not _minimized))
## 面板只需再实现 set_minimized()（一行调 UIMinimize.apply）。
static func attach(parent: Node, on_toggle: Callable) -> UIBtn:
	var b := make_button()
	if on_toggle.is_valid():
		b.pressed_id.connect(func(_id: String) -> void: on_toggle.call())
	parent.add_child(b)
	return b


## ★ 同 attach，但**插到指定兄弟之前**。
## 顶栏排布要求「移动 | 最小化 | 关闭」时，最小化必须排在 × **左边**——
##   直接 attach 会追加到行尾（跑到 × 右边），顺序就错了。
static func attach_before(parent: Node, before: Node, on_toggle: Callable) -> UIBtn:
	var b := make_button()
	if on_toggle.is_valid():
		b.pressed_id.connect(func(_id: String) -> void: on_toggle.call())
	parent.add_child(b)
	if is_instance_valid(before):
		var idx := before.get_index()
		if idx >= 0:
			parent.move_child(b, idx)
	return b


## 该按钮当前是否处于「已折叠」状态（以文案为判据，与按钮同步切换）。
static func is_folded(btn: UIBtn) -> bool:
	return is_instance_valid(btn) and btn.get_label() == "□"


## ★★ 折叠必须「按记录还原」，不能「按判据还原」（批次 89 总根因）。
##   旧实现是**无状态**的：还原时把同一套判据再跑一遍（`visible = not v`），而还原的那一刻
##   面板**还是收窄后的小尺寸** → 判据（「不在顶栏条带内」「在顶栏高度内」等）对小面板得出
##   相反结论 → 本该放回来的控件被 `continue` 跳过 → **永久隐藏**。
##   实测中招：
##     · `_hint`(FULL_RECT Label) / `StatusLabel`(底部锚定) —— 小面板上解析出 y+size ≤ 52 → 跳过
##     · `ResizeHandle`(右下锚定) —— 同上
##     · 事件链编辑器的 `ScrollContainer`
##   现在改为：折叠时把「这次真的被我藏掉的节点」记在宿主节点 meta 里，还原时只把它们放回来。
##   副作用（正是我们要的）：本来就不可见的节点不会被误点亮。
const META_HIDDEN := "_uimin_hidden"

static func _fold_list(owner: Node, targets: Array, v: bool) -> void:
	if v:
		var hid: Array = []
		for t in targets:
			var n := t as Node
			# ★ 只收「有 visible 的节点」（见 _has_visibility）：弹层/子窗口已由
			#   _is_overlay_layer 在收集阶段排除，纯逻辑节点到这里也只是被忽略。
			if is_instance_valid(n) and _has_visibility(n) and n.visible:
				n.visible = false
				hid.append(n)
		if is_instance_valid(owner):
			owner.set_meta(META_HIDDEN, hid)
	else:
		var hid: Array = []
		if is_instance_valid(owner):
			hid = owner.get_meta(META_HIDDEN, [])
		for t in hid:
			var n := t as Node
			if is_instance_valid(n):
				n.visible = true
		if is_instance_valid(owner):
			owner.set_meta(META_HIDDEN, [])


## 隐藏「标题行之外」的其余内容。
## ★ 传进来的 `title_row` 就是**顶栏那一行**（多数面板 = 关闭按钮的父节点）。
##   规则：遍历它的兄弟节点，隐藏除「顶栏自身」与「背景层」以外的全部。
##   这样两种常见结构都自动成立：
##     · 内容根 VBox：panel → margin → VBox[顶栏, 行, 行…]
##     · 顶栏与背景同级：panel → [UIPanel 背景, HBox 顶栏, …内容]
static func fold_below(title_row: Node, v: bool) -> void:
	if not is_instance_valid(title_row):
		return
	var p := title_row.get_parent()
	if p == null:
		return
	var targets: Array = []
	for c in p.get_children():
		if c == title_row:
			continue
		#背景板（UIPanel / 玻璃全息着色器层 / 全屏遮罩）不算内容，别把它也藏了
		if _is_background(c):
			continue
		# ★★ 弹层（CanvasLayer）/ 子窗口 / 纯逻辑节点不是本面板的正文，不参与折叠（批次 93）
		if _is_overlay_layer(c):
			continue
		targets.append(c)
	_fold_list(title_row, targets, v)


## ★★ 该节点是否为「面板背景板」——折叠时**必须保留**。
##   旧判据 `c is UIPanel and c.get_child_count() == 0`（"没有孩子的 UIPanel 才是背景"）
##   在**玻璃/全息主题**下失效：两个着色器路径都会给背景 UIPanel 挂一个 ColorRect 子节点
##   （见 UIPanel._ensure_bg）→ 背景板不再"无孩子" → 被当成内容隐藏：
##     · 最小化瞬间：背景与边框一起消失（用户现象「最小化后边框丢失」）；
##     · 还原时：`fold_top_strip(self,false)` 在 `apply_size(false)` **之前**执行，此刻面板仍是
##       小尺寸，背景板被「顶栏高度内」判定跳过 → visible 不恢复 → **永久消失**
##       （用户现象「最小化一次后，不论有没有最小化边框都不显示」）。
##   改用「孩子是否只有着色器层（或没有孩子）」+「FULL_RECT 锚点」双判据，与尺寸/时序无关。
static func _is_background(c: Node) -> bool:
	var ctl := c as Control
	if ctl == null:
		return false
	var full_rect := _is_full_rect(ctl)
	# ★★ 批次 89 追加：**着色器层本身就是背景**。
	#   UIPanel 的玻璃/全息路径把填充+描边画在一个 FULL_RECT 的 ColorRect 上（UIPanel._ensure_bg），
	#   这个 ColorRect 是**背景 UIPanel 的孩子**、不是 UIPanel —— 于是：
	#     · `fold_below(title_row)` 遍历到它时判不出是背景 → `visible=false`
	#       → **填充与边框一起消失**（用户现象：配置天气 / 配置人工智能最小化后边框丢失）；
	#     · 全屏遮罩（tag 选择页的 `_dim`，也是 FULL_RECT ColorRect）同因被藏 →
	#       （用户现象：深色背景取消最小化后消失）。
	#   判据：FULL_RECT 的 ColorRect 一律当背景层保留（它是装饰层，从来不是内容）。
	if c is ColorRect:
		return full_rect
	if not (c is UIPanel):
		return false
	# ★★ headless 下玻璃会降级成 _draw() 纯色路径（不建 ColorRect 子节点），
	#   真机玻璃/全息则会给背景挂一个 ColorRect —— 所以「无孩子」判据单独用会漏。
	var only_layers := true
	for ch in c.get_children():
		if not (ch is ColorRect):
			only_layers = false
			break
	if only_layers:
		return true                       # 无孩子 或 只有玻璃/全息 ColorRect 层
	return full_rect                      # FULL_RECT 锚点的 UIPanel 也是背景板（跟随面板尺寸）


## 四边锚点是否为 (0,0,1,1)（PRESET_FULL_RECT）。
static func _is_full_rect(ctl: Control) -> bool:
	return is_equal_approx(ctl.anchor_left, 0.0) and is_equal_approx(ctl.anchor_top, 0.0) \
		and is_equal_approx(ctl.anchor_right, 1.0) and is_equal_approx(ctl.anchor_bottom, 1.0)


## ★★ 该节点是否为「叠加层 / 非正文节点」——折叠时**必须保留**（批次 93 总根因）。
##
## 用户现象：最小化**事件链编辑器**时，从它里面打开的「按钮效果（效果编辑）」整页消失。
##
## 根因：两个面板把 CanvasLayer 当**弹层容器**直接挂在自己身上：
##   · ui/event_chain_editor_panel.gd::_ensure_popup_layer()  → 效果编辑页 / 显示要求页 / 长文本窗
##   · debug/dialogue_debug_panel.gd::_ensure_popup_layer()   → 长文本窗
## 这些层是**独立浮层**（注释原话「不受调试面板显隐影响」），不属于面板正文。
## 而旧实现的折叠判据是「**除了顶栏/背景，其余直接孩子一律 visible=false**」：
##   fold_top_strip 里 `var ctl := c as Control; if ctl == null: targets.append(c)` ——
##   CanvasLayer 不是 Control → 一头撞进 targets → 整个弹层连同里面**所有已打开的子页面**
##   一起被藏掉。fold_below 同理（它连条带判据都没有，直接藏光）。
##   两个函数用的是同一句「非 Control 也照藏」，所以这是一个**类**的 bug，不是一处的疏漏。
##
## 判据（在 ui_minimize.gd 里统一表达，调用方不必各自处理）：
##   ① CanvasLayer —— 弹层容器，独立于宿主面板的显隐；
##   ② Window —— 嵌入式子窗口（同样不属于正文）；
##   ③ 非 CanvasItem 的纯逻辑节点（Timer / 辅助节点）—— 根本没有 visible 属性，
##      折它既没意义，赋值 visible 还会报错。
static func _is_overlay_layer(c: Node) -> bool:
	if c is CanvasLayer:
		return true
	if c is Window:
		return true
	return not (c is CanvasItem)


## 该节点是否**具备可见性**（只有 CanvasItem / CanvasLayer 有 visible）。
## 折叠名单只收这两类：对纯 Node 赋 visible 会报「Invalid assignment of property or key 'visible'」。
static func _has_visibility(n: Node) -> bool:
	return n is CanvasItem or n is CanvasLayer


## 是否「右对齐锚定」（左右锚点都在 1）——这类控件跟着**面板右缘**走，
## 面板收窄时它们的屏幕位置天然不变，不需要我们搬（搬了反而错）。
static func _is_right_anchored(ctl: Control) -> bool:
	return is_equal_approx(ctl.anchor_left, 1.0) and is_equal_approx(ctl.anchor_right, 1.0) \
		and is_equal_approx(ctl.anchor_top, ctl.anchor_bottom)


## 是否「自由定位」（四边锚点全 0）——只有这类控件的 position/size 是我们能直接改的。
static func _is_free(ctl: Control) -> bool:
	return is_equal_approx(ctl.anchor_left, 0.0) and is_equal_approx(ctl.anchor_top, 0.0) \
		and is_equal_approx(ctl.anchor_right, 0.0) and is_equal_approx(ctl.anchor_bottom, 0.0)


## 是否落在顶栏条带内（竖直方向）。
static func _in_strip(ctl: Control, strip_h: float = DEFAULT_MIN_H) -> bool:
	return ctl.position.y + ctl.size.y <= strip_h and ctl.position.y >= -2.0


## 是否「左右拉通的弹性 Label」（正文行，随面板伸缩）——不参与宽度基准、也不用限宽。
static func _is_elastic(ctl: Control) -> bool:
	return ctl is Label \
		and is_equal_approx(ctl.anchor_left, 0.0) and is_equal_approx(ctl.anchor_right, 1.0)


## Label 的**文字自然宽度**（标题被 clip 后 size.x 不能反映真实内容宽度，必须量文字）。
static func _text_w(l: Label) -> float:
	if not is_instance_valid(l) or l.text.is_empty():
		return 0.0
	var f: Font = l.get_theme_font("font")
	if f == null:
		return 0.0
	var fs: int = l.get_theme_font_size("font_size")
	return f.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs).x


## 控件的「真实占位宽」。
## ★ UIBtn 的 get_minimum_size() 恒为 0（文字画在**子 Label** 上，BaseButton 自身不带文字），
##   所以宽度基准若只用 get_combined_minimum_size() 会严重低估 →
##   最小化后盒子过窄、按钮横七竖八跑到边框外（用户实测：玩家画像 / 状态页 / 对话记录）。
##   · 自由 Label：取「文字自然宽」与盒子宽的小者（标题可压缩）
##   · 弹性 Label：0（随面板伸缩，不占最小宽）
##   · 其余（UIBtn / UIDragHandle / 普通 Control）：min(上报最小宽, 实际宽) 的实际宽
static func _footprint_w(ctl: Control) -> float:
	if not is_instance_valid(ctl):
		return 0.0
	if _is_elastic(ctl):
		return 0.0
	if ctl is Label:
		var nat := _text_w(ctl as Label)
		if nat <= 0.0:
			return maxf(0.0, ctl.size.x)
		if ctl.size.x <= 1.0:
			return nat
		return minf(ctl.size.x, nat)
	return maxf(ctl.get_combined_minimum_size().x, ctl.size.x)


## 容器（顶栏行）的**真实最小宽**。
## ★ 容器的 get_combined_minimum_size() 已经把「有 custom_minimum_size 的按钮 / Label 文字」
##   算进去了，但**没有**算「没声明 custom_minimum_size 的 UIBtn」（它们上报 0）——
##   直接用会在收窄后触发 HBox 溢出。这里再补上这部分缺口。
static func _row_min_w(row: Container) -> float:
	var total := row.get_combined_minimum_size().x
	for ch in row.get_children():
		var c := ch as Control
		if c == null or not c.visible:
			continue
		var real := _footprint_w(c)
		var rep := c.get_combined_minimum_size().x
		if real > rep:
			total += real - rep
	return total


## 宽度基准里单个条目的贡献宽。
static func _basis_w(ctl: Control) -> float:
	if ctl is Container:
		return _row_min_w(ctl as Container)
	return _footprint_w(ctl)


## 隐藏/显示一组节点（面板结构特殊、无法用「顶栏兄弟」推导时用这个，自己列节点）。
## ★ 宿主节点取「第一个有效节点的父节点」，用于保存这次的隐藏名单（见 _fold_list）。
static func fold_rows(rows: Array, v: bool) -> void:
	var owner: Node = null
	for n in rows:
		var c := n as Node
		if is_instance_valid(c) and c.get_parent() != null:
			owner = c.get_parent()
			break
	_fold_list(owner, rows, v)


## ★ 适用于「标题栏控件**直接挂在面板上**（锚定定位）」的面板：
## calendar / 标签选择 / 状态页 / 设置页 / 事件链编辑器 等没有顶栏容器，
## 标题、把柄、关闭按钮都是面板的直接孩子 —— 此时「兄弟」推导不成立。
## 规则（保留清单）：
##   · 背景层（UIPanel / 着色器 ColorRect / 全屏遮罩）
##   · 竖直范围落在顶栏条带内的控件（标题 Label / 拖动把柄 / 那一排按钮）
##   · 调用方额外指定要保留的节点（extra_keep）
## ★★ 批次 89 修正：旧实现无条件保留**所有** UIBtn / UIDragHandle（本意是「顶栏那一排」），
##   结果正文里的按钮（台词记录页的「上一页 / 下一页」在 y=458）也一起留下了 →
##   最小化后它们停在页脚坐标、戳到边框外（用户实测：时间线/对话调试「页面去到边框外」）。
##   现在改为**只按「是否落在顶栏条带内」**判定，按钮不再有豁免。
static func fold_top_strip(panel: Control, v: bool, strip_h: float = DEFAULT_MIN_H, extra_keep: Array = []) -> void:
	if not is_instance_valid(panel):
		return
	var targets: Array = []
	for c in panel.get_children():
		if extra_keep.has(c):
			continue
		if _is_background(c):
			continue                     # 背景层
		# ★★ 弹层（CanvasLayer）/ 子窗口 / 纯逻辑节点不是正文 → 不进折叠名单（批次 93）
		#   旧实现把「非 Control 的孩子」也塞进 targets → 弹层整层被藏，里面打开的
		#   子页面（效果编辑 / 显示要求 / 长文本窗）一起消失（用户实测）。
		if _is_overlay_layer(c):
			continue
		var ctl := c as Control
		if ctl == null:
			targets.append(c)
			continue
		if _in_strip(ctl, strip_h):
			continue                     # 顶栏条带内（标题 / 把柄 / 按钮）→ 保留
		targets.append(c)
	_fold_list(panel, targets, v)


## 顶栏控件直接挂在面板上时的接线：造按钮 + 锚定到右上角。
## ★★ 必须排在标题栏**最左侧**控件的左边，而不是「关闭按钮的左边」——
##   日历 / MOD 列表 / 状态页等布局里，「拖动把柄」本来就紧贴关闭按钮左侧，
##   若按关闭按钮定位，最小化按钮会与把柄**完全重合**（按钮叠按钮，点不动）。
##   所以先扫一遍面板子节点，找出锚在右上角（anchor_left≈1）的那些控件里最左的一个。
static func attach_anchored(panel: Control, close_btn: Control, on_toggle: Callable, btn_size: float = 28.0) -> UIBtn:
	var b := make_button()
	b.anchor_left = 1.0
	b.anchor_top = 0.0
	b.anchor_right = 1.0
	b.anchor_bottom = 0.0
	_place_anchored(b, panel, btn_size)
	if on_toggle.is_valid():
		b.pressed_id.connect(func(_id: String) -> void: on_toggle.call())
	panel.add_child(b)
	# ★★ 延后几帧**再摆一次**：接线时代码往往还没把标题栏控件建全
	#   （MOD 列表的拖动把柄、状态页的刷新按钮都是在 attach 之后才 add_child 的）
	#   → 首次摆位只看到关闭按钮，于是和随后出现的把柄/刷新按钮**重叠**。
	#   ★ 用「按帧等待」而不是 Timer：Timer 走真实时间，headless / 低帧率下不一定触发。
	_reflow_after_frames(b, panel, btn_size, 3)
	return b


## 等 n 帧后重新摆位（协程，调用方无需 await）。
static func _reflow_after_frames(b: Control, panel: Control, btn_size: float, frames: int) -> void:
	var tree := panel.get_tree() if is_instance_valid(panel) else null
	if tree == null:
		return
	for _i in range(frames):
		await (tree as SceneTree).process_frame
	if is_instance_valid(b) and is_instance_valid(panel):
		_place_anchored(b, panel, btn_size)


## ★ 标题栏排布（用户指定）：**移动 | 最小化 | 关闭**（自左向右）。
## 从右往左排：先把关闭按钮钉在它原位，再把最小化放到它左边，
## 再把拖动把柄放到最小化左边；其余按钮（刷新等）继续往左排，避免互相重叠。
static func _place_anchored(b: Control, panel: Control, btn_size: float) -> void:
	var pw := panel.size.x
	var slot := btn_size + 4.0
	var close_ctl: Control = null
	var handle_ctl: Control = null
	var others: Array = []
	for c in panel.get_children():
		var ctl: Control = c as Control      # ★ 必须先转Control：Node 上没有 offset_left/anchor_left
		if ctl == null or ctl == b:
			continue
		if not (ctl is UIBtn or ctl is UIDragHandle):
			continue
		# ★★ 不再要求「锚定在右上角（anchor_left≥0.99）」——
		#   事件链编辑器的 × / 拖动把柄是**绝对定位**（用 position 写死、anchor=0），
		#   旧判据会漏掉它们 → 最小化按钮落到默认右槽，与 × 和把柄**完全重合**（用户实测）。
		#   改为按「解析后的位置是否在顶栏右上区」判定，锚定/绝对定位两种写法通用。
		if ctl.position.y + ctl.size.y > DEFAULT_MIN_H + 12.0:
			continue                           # 不在顶栏
		if ctl.position.x + ctl.size.x * 0.5 < pw * 0.5:
			continue                           # 不在右半区
		if ctl is UIDragHandle:
			if handle_ctl == null:
				handle_ctl = ctl
		elif _looks_like_close(ctl):
			close_ctl = ctl
		else:
			others.append(ctl)
	# 基准取「关闭按钮左缘（panel 局部解析坐标）」；锚定控件 position 即 offset 的解析结果，
	# 绝对定位控件 position 就是原值 —— 两者同一坐标系，故下面统一用 position 表达。
	var close_left := pw - slot
	var top_y := 4.0
	if close_ctl != null:
		close_left = close_ctl.position.x
		top_y = close_ctl.position.y
	# 1) 最小化按钮：紧贴关闭按钮左侧（b 锚定右上，用 offset 表达）
	b.offset_right = (close_left - 4.0) - pw
	b.offset_left = b.offset_right - btn_size
	b.offset_top = top_y
	b.offset_bottom = top_y + btn_size
	# 2) 拖动把柄：最小化左侧；3) 其余按钮继续往左排（用解析 position，锚定/绝对通用）
	var cursor := close_left - 4.0 - btn_size
	if handle_ctl != null:
		handle_ctl.position = Vector2(cursor - 4.0 - handle_ctl.size.x, top_y)
		cursor -= 4.0 + handle_ctl.size.x
	for o in others:
		var oc := o as Control
		oc.position = Vector2(cursor - 4.0 - oc.size.x, top_y)
		cursor -= 4.0 + oc.size.x


## ★ 把「左上角标题 Label」的宽度收窄到「顶栏最左按钮」的左边，避免长标题压到按钮上。
##   面板标题是**绝对定位的自由 Label**（不在容器里）→ 没有 clip 时文字照常溢出绘制，
##   页面名一长就压到右侧按钮上（用户实测：玩家画像 / 状态页）。这里开 clip 并限宽。
##   必须在**顶栏控件全部建好之后**调用（此时各按钮的锚定位置已解析）。
static func clamp_title_width(panel: Control, title: Label, pad: float = 8.0) -> void:
	if not (is_instance_valid(panel) and is_instance_valid(title)):
		return
	title.clip_text = true
	var leftmost: float = panel.size.x
	for c in panel.get_children():
		var ctl := c as Control
		if ctl == null or ctl == title:
			continue
		if not (ctl is UIBtn or ctl is UIDragHandle):
			continue
		if ctl.position.y + ctl.size.y > DEFAULT_MIN_H + 12.0:
			continue                           # 不在顶栏
		if ctl.position.x + ctl.size.x * 0.5 < panel.size.x * 0.5:
			continue                           # 不在右半区
		leftmost = minf(leftmost, ctl.position.x)
	title.size.x = maxf(60.0, leftmost - title.position.x - pad)


## 切换最小化按钮文案：「− 最小化」⇄「□ 还原」。
## ★ 凡是**不走** apply() / apply_to() 的面板（自己调 fold_top_strip / fold_rows + apply_size），
##   必须在自己的 set_minimized 里调一次本函数，否则按钮会永远停在「−」。
static func set_label(btn: UIBtn, v: bool) -> void:
	if is_instance_valid(btn):
		btn.set_label("□" if v else "−")


## 是否「关闭」按钮：id 含 close，或文案是 ×/✕
static func _looks_like_close(c: UIBtn) -> bool:
	if str(c.get_id()).to_lower().findn("close") >= 0:
		return true
	return c.get_label() in ["×", "✕"]


## 切换面板尺寸：折叠 → 高度收到 min_h、宽度收到「标题行刚好放下」；还原 → 记下的尺寸。
## ★ 折叠时**面板右上角（最小化按钮所在）保持屏幕原位**：宽度收紧后把面板右移对应量，
##   实现「按钮不动、页面收拢到按钮处」（避免最小化后整窗漂走 / 边框没包住按钮）。
## ★ 同时处理custom_minimum_size：部分面板（如属性编辑器）用它顶住尺寸，
##   此时只改 `size` 会被引擎钳回原高度，折叠看起来「没反应」。
## ★★ 宽度也要收：最小化后标题行里「标题与按钮之间」的那片弹性空白会依然横贯全宽，
##   折叠后仍是一条空条 → 宽度基准 = 标题行里各控件的最小宽度之和（basis 由 apply 自动推导）。
static func apply_size(panel: Control, v: bool, min_h: float = DEFAULT_MIN_H, basis: Array = []) -> void:
	var target := _size_target(panel)
	if not is_instance_valid(target):
		return
	var key := target.get_instance_id()
	if v:
		var old_w := target.size.x
		# ★★ 顶栏快照必须在**改尺寸之前**采集：改完高度后，底部锚定的控件会被解析到条带内，
		#   「是否在顶栏」的判定就失真了（这与「还原时顶栏被跳过」是同一个时序坑）。
		var strip: Array = _strip_controls(target)
		if not _strip_saved.has(key):
			_strip_saved[key] = strip
		if not _full_h.has(key):
			_full_h[key] = target.size
			_full_min_h[key] = target.custom_minimum_size
			# ★★ 记下**面板自身**的展开位置（不是 target，因为 target 可能是子背景 _bg）：
			#   还原时按它把窗口归位，避免折叠/还原后整窗漂走。
			if is_instance_valid(panel):
				_full_pos[key] = panel.global_position
		target.custom_minimum_size.y = min_h
		target.size.y = min_h
		var items: Array = basis
		if items.is_empty():
			for d in strip:
				var dd: Dictionary = d          # ★ 快照是字典，取回节点（不能直接 as Control）
				items.append(dd["node"])
		var w := 0.0
		var n := 0
		for item in items:
			var ctl: Control = item as Control
			if ctl == null or not ctl.visible:
				continue
			w += _basis_w(ctl)
			n += 1
		if n > 0:
			w += PAD_X * 2.0 + BTN_GAP * float(n - 1)
			w = maxf(w, min_h * 2.0)
			if w < target.size.x:# ★ 只收窄，绝不变宽
				target.custom_minimum_size.x = w
				target.size.x = w
		# 顶栏重排：右侧簇保持屏幕位置、顶栏行收窄到盒宽、标题限宽
		#   （否则面板右移后，自由定位的按钮整体漂到边框外 —— 用户实测：时间轴 / 对话调试 / 事件链）
		_fit_strip(_strip_saved.get(key, []), old_w, target.size.x)
		# ★★ 保持「面板右上角（最小化按钮通常钉在右上）」的屏幕位置不变：
		#   宽度收紧后，把面板整体右移「收紧量」，让标题栏按钮留在原位，
		#   正文区域（在按钮左边）随之收拢到按钮下方 —— 即「按钮不动、页面移到按钮处」。
		#   ★ 收紧量**不要**再乘画布缩放：Control 的 position / global_position 是画布坐标，
		#     CanvasLayer.scale 只在渲染与事件分发时施加（见 UIStyle 顶部「坐标语义」实测结论），
		#     乘上去会把面板多推 f 倍 → 按钮反而漂走（真机 f≠1 时必现，headless 探针测不到）。
		if is_instance_valid(panel) and not is_equal_approx(old_w, target.size.x):
			panel.global_position.x += old_w - target.size.x
	elif _full_h.has(key):
		target.custom_minimum_size = _full_min_h.get(key, Vector2.ZERO)
		target.size = _full_h[key]
		if _full_pos.has(key) and is_instance_valid(panel):
			panel.global_position = _full_pos[key]
		# 顶栏原样归位（自由定位的控件必须写回，锚定的由锚点自行归位）
		_unfit_strip(_strip_saved.get(key, []))
		_strip_saved.erase(key)


## 折叠时顶栏控件的展开态快照（key = target 的 instance_id）。
##   ★★ 为什么必须快照：面板一收窄，**自由定位**的顶栏控件（标题 Label、绝对定位的 × / 把柄 /
##   那一排按钮）不会自己跟着走 —— 它们停在原局部坐标，面板右移后屏幕位置整体右漂、
##   末尾几个按钮戳出边框（用户实测：时间轴 / 对话调试 / 事件链编辑器）。
##   右锚定的控件不用搬（右缘钉住 → 屏幕位置天然不变）。
static var _strip_saved: Dictionary = {}


## 采集顶栏条带内的直接孩子（背景层除外）。必须传**展开态**的盒子。
static func _strip_controls(box: Control) -> Array:
	var out: Array = []
	if not is_instance_valid(box):
		return out
	var half := box.size.x * 0.5
	for c in box.get_children():
		var ctl := c as Control
		if ctl == null or not ctl.visible:
			continue
		if _is_background(c):
			continue
		if not _in_strip(ctl):
			continue
		var right_half: bool = ctl.position.x + ctl.size.x * 0.5 >= half
		if ctl is Label and _is_elastic(ctl):
			right_half = false
		out.append({
			"node": ctl,
			"x": ctl.position.x,
			"y": ctl.position.y,
			"w": ctl.size.x,
			"h": ctl.size.y,
			"container": ctl is Container,
			"anchored": _is_right_anchored(ctl),
			"free": _is_free(ctl),
			"off_left": ctl.offset_left,
			"right": right_half,
		})
	return out


## 折叠：按快照把顶栏贴回盒子里。
static func _fit_strip(saved: Array, old_w: float, new_w: float) -> void:
	var delta := old_w - new_w
	# ① 右侧簇左缘：右锚定控件不搬，其局部 x = new_w + offset_left（纯算术，不依赖容器重排时序）
	var cluster_left := new_w
	for e in saved:
		var d: Dictionary = e
		if bool(d["anchored"]):
			cluster_left = minf(cluster_left, new_w + float(d["off_left"]))
			continue
		if bool(d["container"]) or not bool(d["right"]):
			continue
		cluster_left = minf(cluster_left, float(d["x"]) - delta)
	# ② 自由控件：右侧簇左移 delta（屏幕位置不变）；顶栏行收窄到盒宽；左簇标题限宽
	for e in saved:
		var d: Dictionary = e
		var ctl := d["node"] as Control
		if not is_instance_valid(ctl) or bool(d["anchored"]):
			continue
		var x0 := float(d["x"])
		var w0 := float(d["w"])
		if bool(d["container"]):
			# 顶栏行（HBox）：右缘本来贴着盒子右缘 → 跟着一起收窄（否则行内按钮戳出边框）
			if x0 + w0 >= old_w - x0 - 2.0:
				ctl.position.x = x0
				ctl.size.x = maxf(0.0, new_w - x0 * 2.0)
			continue
		if bool(d["right"]):
			ctl.position.x = x0 - delta
			continue
		# 左簇（标题 Label）：限宽，别压到右侧按钮上
		if ctl is Label:
			var room := cluster_left - BTN_GAP - ctl.position.x
			if room > 0.0 and ctl.size.x > room:
				ctl.size.x = room


## 还原：把快照里的自由控件原样写回（锚定控件由锚点自行归位，不写）。
static func _unfit_strip(saved: Array) -> void:
	for e in saved:
		var d: Dictionary = e
		var ctl := d["node"] as Control
		if not is_instance_valid(ctl) or not bool(d["free"]):
			continue
		ctl.position = Vector2(float(d["x"]), float(d["y"]))
		ctl.size = Vector2(float(d["w"]), float(d["h"]))


## 自动推导宽度基准：取面板**直接孩子**里落在顶栏条带内的可见控件
## （标题 Label / 拖动把柄 / 最小化 / 关闭…），跳过背景 UIPanel。
## 只取直接孩子 —— 再往下的控件属于正文，收进来会把宽度撑回去。
## 自动推导宽度基准（诊断用）：取面板**直接孩子**里落在顶栏条带内的可见控件。
## 只取直接孩子 —— 再往下的控件属于正文，收进来会把宽度撑回去。
static func _auto_basis(panel: Control) -> Array:
	var out: Array = []
	for d in _strip_controls(panel):
		var dd: Dictionary = d
		var ctl: Control = dd["node"] as Control
		if ctl != null:
			out.append(ctl)
	return out


## ★ 决定「折叠时到底该缩哪个节点」。
## 本项目有两种面板形态（见 console / self_profile / perf_busy / mod_list 等）：
##   ① 面板自身就是可见盒子（`_bg` 用 FULL_RECT 锚点跟随，如 inventory / calendar）
##   ② 面板**只是容器**，可见盒子是手动定位的 `_bg`（`_bg.size = Vector2(PANEL_W, PANEL_H)`），
##      面板自身尺寸恒为 0 ——此时缩面板等于**缩了个看不见的东西**
##      （用户现象：内容消失了、框没收；探针实测 console 400→400 / self_profile 720→720）。
## 统一在这里判定，各面板不必再各自判断。
static func _size_target(panel: Control) -> Control:
	var bg: Variant = panel.get("_bg")
	if bg is Control:
		var b := bg as Control
		# FULL_RECT 锚点背景（`set_anchors_preset(PRESET_FULL_RECT)`，如 calendar / inventory）：
		# 它**跟随面板尺寸**，缩它会被锚点立刻撑回去 → 必须缩面板本身。
		# ★ PRESET_FULL_RECT 的锚点是 (0,0,1,1)（**左边是 0，不是 1**）——
		#   早前误判成 anchor_left==1.0 → 把尺寸写到被锚点绑定的 _bg 上，折叠完全无效。
		var full_rect: bool = is_equal_approx(b.anchor_left, 0.0) \
			and is_equal_approx(b.anchor_top, 0.0) \
			and is_equal_approx(b.anchor_right, 1.0) \
			and is_equal_approx(b.anchor_bottom, 1.0)
		if full_rect:
			return panel
		# 手动定位/定尺寸的背景（`_bg.size = Vector2(PANEL_W, PANEL_H)`，如 console / self_profile /
		# perf_busy / mod_list）：面板自身尺寸恒 0，缩面板等于缩了个看不见的东西 → 缩 _bg。
		if b.size.y > 1.0:
			return b
	return panel


## 组合调用：按钮文案 + 折叠内容 + 切高度。
## ★ 面板的 set_minimized() 推荐直接用这个重载 —— 只需传「关闭按钮」，
##   顶栏 = 关闭按钮的父节点自动推导，不必各自记内容根变量：
##     func set_minimized(v: bool) -> void:
##         _minimized = v
##         UIMinimize.apply_to(self, _min_btn, _close_btn, v)
static func apply(panel: Control, btn: UIBtn, v: bool, root: Node = null, min_h: float = DEFAULT_MIN_H) -> void:
	if is_instance_valid(btn):
		btn.set_label("□" if v else "−")
	if root != null:
		fold_below(root, v)
	# 宽度基准：顶栏是容器时，用它自己的最小宽度（A 类标题行）
	var basis: Array = []
	if root is Container:
		basis.append(root)
	apply_size(panel, v, min_h, basis)


## 面板侧最省事的入口：顶栏由 close_btn.get_parent() 推导。
static func apply_to(panel: Control, btn: UIBtn, close_btn: Node, v: bool, min_h: float = DEFAULT_MIN_H) -> void:
	if is_instance_valid(btn):
		btn.set_label("□" if v else "−")
	var basis: Array = []
	if is_instance_valid(close_btn):
		var row := close_btn.get_parent()
		fold_below(row, v)
		if row is Container:
			basis.append(row)
	apply_size(panel, v, min_h, basis)


## 面板关闭/销毁时清掉记住的高度（避免 Dictionary 无限增长）。
static func forget(panel: Control) -> void:
	if is_instance_valid(panel):
		var key := _size_target(panel).get_instance_id()
		_full_h.erase(key)
		_full_min_h.erase(key)
		_full_pos.erase(key)
		_strip_saved.erase(key)