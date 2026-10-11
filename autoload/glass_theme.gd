extends Node
# 批次 52：把液态玻璃主题应用到所有「默认主题」控件（Button / LineEdit / OptionButton /
# Label / CheckBox / CheckButton / ProgressBar / PopupMenu / RichTextLabel / TextEdit / 滚动条 /
# Panel 等）。自定义面板都走 UIPanel（已在 ui/ui_panel.gd 改玻璃风），这里只补默认控件，
# 让「所有窗口」视觉统一。
#
# ★ 批次 55：本文件造出的 StyleBox 全部来自 UIStyle.glass_box()（自更新 GlassBox），
#   故界面主题（透明液态玻璃 ↔ 半透明纯色 ↔ 量子全息 / 主题色）变化时**不必重构 Theme**，
#   只需在收到 SaveManager.ui_theme_changed 后调用 UIStyle.restyle_all_boxes() 即可。
#   ★ 批次 59：量子全息的「无边框 + 荧光蓝」也在 GlassBox.apply_theme_colors() 里
#     按主题现算（描边一律压成透明）→ 同样零重构。
#
# ★ 纯白玻璃填充会压低白字对比度，故所有文字控件统一加「深色描边」保证可读性
#   （描边色/粗细见 UIStyle.TEXT_OUTLINE / TEXT_OUTLINE_SIZE）。
#
# ★★ 关键坑（探针实测，务必遵守）：Control 的 theme 查找链是「自身 → 父 Control → … → Window」，
#   遇到 **CanvasLayer 就中断**（CanvasLayer 不是 Control）。本项目所有面板都挂在 ui_layer /
#   page_layer 这两个 CanvasLayer 下，因此挂在 `get_tree().root.theme`（Window）上的主题
#   **完全不生效**（实测 Label.get_theme_constant("outline_size") 返回 0）。
#   正确做法：把 Theme 挂到「CanvasLayer 下的 Control 面板根」上——theme 会向整棵 Control 子树继承。
#   故本 autoload 用「延迟一帧 + 遍历所有 CanvasLayer 里的 Control + 监听新增节点」的方式逐个挂载。
#
# 各面板代码里的 add_theme_* 覆盖优先级高于本主题，互不冲突。
# 不声明 class_name（autoload 同名限制）。

var _theme: Theme = null

func _ready() -> void:
	_theme = _build_theme()
	# 延迟到主场景树成形后再挂载（_ready 时 ui_layer 往往还没建好）。
	_defer_scan()
	# 监听后续新增节点：面板多为运行时动态 add_child，需自动补挂。
	get_tree().node_added.connect(_on_node_added)
	# ★ 批次 55：界面主题（玻璃 ↔ 纯色 / 主题色）变化时，批量重算所有由
	#   UIStyle.glass_box() 造出的 StyleBox。这些 StyleBox 都是自更新的 GlassBox
	#   实例，且控件持有的就是同一实例 → 原地改颜色即完成换肤，无需重新挂 Theme。
	var sm := get_node_or_null("/root/SaveManager")
	if sm != null and sm.has_signal("ui_theme_changed") and not sm.ui_theme_changed.is_connected(_on_ui_theme_changed):
		sm.ui_theme_changed.connect(_on_ui_theme_changed)


func _on_ui_theme_changed(_mode: String, _color_key: String) -> void:
	UIStyle.restyle_all_boxes()


func _build_theme() -> Theme:
	var t := Theme.new()
	_apply_button(t)
	_apply_line_edit(t)
	_apply_option_button(t)
	_apply_label(t)
	_apply_check_box(t, "CheckBox")
	_apply_check_box(t, "CheckButton")
	_apply_progress_bar(t)
	_apply_popup_menu(t)
	_apply_rich_text(t)
	_apply_text_edit(t)
	_apply_panel(t)
	_apply_scroll(t)
	return t


## 按「当前（含预览覆盖的）主题」现造一份 Theme —— 供设置页「主题预览」使用。
##
## ★ 为什么预览必须另造一份而不能就地改色：本文件的 Theme 是**全局唯一一份**，
##   且被 GlassTheme 挂到了几乎所有 Control 的 `.theme` 上；StyleBox 更是控件共用的
##   同一实例 —— 就地改色 = 全局改色。所以预览改为「给设置页子树换上这份副本」。
## ★ 调用约定：先 UIStyle.set_theme_preview(mode, color)，再调本方法。
func build_theme_now() -> Theme:
	return _build_theme()


## 延迟两帧后全量扫描（等 desktop 建好 ui_layer/page_layer）。
func _defer_scan() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if _theme == null:
		return
	_attach_all(get_tree().root)


## 递归：给「位于 CanvasLayer 之下、且自身尚无 theme 的 Control」补挂主题，
## 从而覆盖 CanvasLayer 内整棵 Control 子树（挂到最外层那个 Control 即可，无需逐个）。
func _attach_all(node: Node) -> void:
	if node == null:
		return
	for child in node.get_children():
		if child is CanvasLayer:
			# CanvasLayer 下的直接 Control 子节点就是「面板根」，逐个挂上（其子树自动继承）。
			for gc in child.get_children():
				if gc is Control:
					_attach(gc)
				else:
					_attach_all(gc)
		else:
			_attach_all(child)


func _attach(c: Control) -> void:
	if c == null or not is_instance_valid(c):
		return
	# ★ 批次 56：设置页「主题预览」期间，其子树内的节点一律**不挂共享主题**
	#   （那些节点改用设置页现造的「预览主题副本」，见 ui/settings_panel.gd 的
	#   _apply_theme_scope）。否则预览中新建/懒建的节点（如 OptionButton 的下拉 PopupMenu）
	#   会把共享主题又贴回去 → 预览"漏色"。
	if _in_preview_scope(c):
		return
	# 不覆盖面板自身显式设置的 theme（尊重局部覆盖）。
	if c.theme == null:
		c.theme = _theme


## 节点是否位于某个「主题预览作用域」内（任一祖先带 meta ui_theme_preview_root）。
func _in_preview_scope(n: Node) -> bool:
	var p: Node = n
	while p != null:
		if p.has_meta("ui_theme_preview_root"):
			return true
		p = p.get_parent()
	return false


## 新增节点若为 CanvasLayer 下的 Control（如动态弹出的面板），立即补挂主题。
func _on_node_added(node: Node) -> void:
	if _theme == null or not (node is Control) or not is_instance_valid(node):
		return
	# 仅当父链中存在 CanvasLayer 时才需要处理（root 下的控件本就会被 Windown theme 覆盖，
	# 但 Window theme 我们没设，所以统一处理亦可）。
	_attach(node as Control)


## 给某控件类型补「文字描边」：纯白玻璃填充会压低白字对比度，描边保证可读性。
## （Label/RichTextLabel/TextEdit 等的描边 theme item 名一致，故统一处理。）
func _outline(t: Theme, type: String) -> void:
	t.set_color("font_outline_color", type, UIStyle.TEXT_OUTLINE)
	t.set_constant("outline_size", type, UIStyle.TEXT_OUTLINE_SIZE)


func _sb(fill: Color, border: Color, radius: float, bw: float) -> StyleBoxFlat:
	# 统一走 UIStyle.glass_box：圆角抗锯齿 + 玻璃观感
	var sb := UIStyle.glass_box(fill, border, int(radius), int(bw), true)
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 5.0
	sb.content_margin_bottom = 5.0
	return sb


func _apply_button(t: Theme) -> void:
	# ★ 批次 58：静止态改用 FILL_SURFACE（0.06 白）= 与磨砂面板同一视觉权重。
	#   原来用 FILL_DEFAULT(0.16) + glow 阴影，实测在深色桌面上比面板亮 5~7 倍，
	#   看上去就是一块「纯色半透明板」，与液态玻璃面板不统一（用户报此问题）。
	t.set_stylebox("normal", "Button", _sb(UIStyle.FILL_SURFACE, UIStyle.BORDER, 8, 1.5))
	# ★ 批次 58：hover = 更亮的填充 + 亮白描边 + 略粗边框（原来只换填充，磨砂上几乎看不出）
	t.set_stylebox("hover", "Button", _sb(UIStyle.FILL_HOVER, UIStyle.BORDER_HOVER, 8, UIStyle.BORDER_WIDTH_HOVER))
	t.set_stylebox("pressed", "Button", _sb(UIStyle.FILL_PRESSED, UIStyle.BORDER, 8, 1.5))
	# 键盘焦点：不再铺一层亮板（FILL_HOVER 会变成一个"实心块"），改成亮白描边提示。
	t.set_stylebox("focus", "Button", _sb(UIStyle.FILL_SURFACE, UIStyle.BORDER_HOVER, 8, UIStyle.BORDER_WIDTH_HOVER))
	t.set_stylebox("disabled", "Button", _sb(Color(0.30, 0.34, 0.40, 0.40), Color(0.5, 0.6, 0.7, 0.5), 8, 1.5))
	t.set_color("font_color", "Button", UIStyle.TEXT_DEFAULT)
	t.set_constant("font_size", "Button", UIStyle.FONT_SIZE)
	_outline(t, "Button")


func _apply_line_edit(t: Theme) -> void:
	t.set_stylebox("normal", "LineEdit", UIStyle.line_edit_stylebox(false))
	t.set_stylebox("focus", "LineEdit", UIStyle.line_edit_stylebox(true))
	t.set_stylebox("read_only", "LineEdit", UIStyle.line_edit_stylebox(false))
	t.set_color("font_color", "LineEdit", UIStyle.TEXT_DEFAULT)
	t.set_color("font_placeholder_color", "LineEdit", Color(UIStyle.TEXT_DEFAULT.r, UIStyle.TEXT_DEFAULT.g, UIStyle.TEXT_DEFAULT.b, 0.45))
	t.set_color("caret_color", "LineEdit", UIStyle.TEXT_DEFAULT)
	t.set_color("selection_color", "LineEdit", Color(0.30, 0.75, 1.0, 0.45))
	_outline(t, "LineEdit")


func _apply_option_button(t: Theme) -> void:
	# ★ 批次 58：与 Button 同款 —— 静止态与磨砂面板同权重（FILL_SURFACE），
	#   不再是一块比面板亮好几倍的"实心板"。
	t.set_stylebox("normal", "OptionButton", _sb(UIStyle.FILL_SURFACE, UIStyle.BORDER, 8, 1.5))
	# ★ 批次 58：与 Button 同款 —— hover 点亮填充 + 描边
	t.set_stylebox("hover", "OptionButton", _sb(UIStyle.FILL_HOVER, UIStyle.BORDER_HOVER, 8, UIStyle.BORDER_WIDTH_HOVER))
	t.set_stylebox("pressed", "OptionButton", _sb(UIStyle.FILL_PRESSED, UIStyle.BORDER, 8, 1.5))
	t.set_stylebox("focus", "OptionButton", _sb(UIStyle.FILL_SURFACE, UIStyle.BORDER_HOVER, 8, UIStyle.BORDER_WIDTH_HOVER))
	t.set_color("font_color", "OptionButton", UIStyle.TEXT_DEFAULT)
	t.set_constant("font_size", "OptionButton", UIStyle.FONT_SIZE)
	_outline(t, "OptionButton")


func _apply_label(t: Theme) -> void:
	t.set_color("font_color", "Label", UIStyle.TEXT_DEFAULT)
	t.set_constant("font_size", "Label", UIStyle.FONT_SIZE)
	_outline(t, "Label")


## 复选框（CheckBox / CheckButton）：同为带文字的默认控件，白字 + 描边。
func _apply_check_box(t: Theme, type: String) -> void:
	t.set_color("font_color", type, UIStyle.TEXT_DEFAULT)
	t.set_constant("font_size", type, UIStyle.FONT_SIZE)
	_outline(t, type)


## 进度条百分比文字：白字 + 描边（避免落在浅色进度填充上看不清）。
func _apply_progress_bar(t: Theme) -> void:
	t.set_color("font_color", "ProgressBar", UIStyle.TEXT_DEFAULT)
	_outline(t, "ProgressBar")


## OptionButton 展开的下拉列表（PopupMenu）：白字 + 描边 + 液态玻璃底。
func _apply_popup_menu(t: Theme) -> void:
	t.set_color("font_color", "PopupMenu", UIStyle.TEXT_DEFAULT)
	t.set_constant("font_size", "PopupMenu", UIStyle.FONT_SIZE)
	_outline(t, "PopupMenu")
	# 玻璃底：半透明冰白 + 圆角描边（替代引擎默认深灰）
	t.set_stylebox("panel", "PopupMenu", UIStyle.glass_box(Color(0.08, 0.14, 0.24, 0.92), Color(0.80, 0.92, 1.0, 0.55), 6, 1))
	t.set_stylebox("hover", "PopupMenu", UIStyle.glass_box(Color(1.0, 1.0, 1.0, 0.30), Color(1.0, 1.0, 1.0, 0.0), 4, 0))
	t.set_color("font_hover_color", "PopupMenu", UIStyle.TEXT_DEFAULT)


## RichTextLabel（对话栏/事件正文/文本框积木）：默认白字 + 描边，保证浅色玻璃上可读。
## 不设字号（各面板有自己的 override），避免破坏既有排版。
func _apply_rich_text(t: Theme) -> void:
	t.set_color("default_color", "RichTextLabel", UIStyle.TEXT_DEFAULT)
	_outline(t, "RichTextLabel")


## TextEdit（多行输入/备忘录/日记）：白字 + 描边（其深色编辑区默认背景由引擎提供）。
func _apply_text_edit(t: Theme) -> void:
	t.set_color("font_color", "TextEdit", UIStyle.TEXT_DEFAULT)
	_outline(t, "TextEdit")


func _apply_panel(t: Theme) -> void:
	# 默认 Panel / PanelContainer 透明，避免给窗口盖一层不透明底
	var empty := StyleBoxFlat.new()
	empty.bg_color = Color(0, 0, 0, 0)
	t.set_stylebox("panel", "Panel", empty)
	t.set_stylebox("panel", "PanelContainer", empty)


func _apply_scroll(t: Theme) -> void:
	var empty := StyleBoxFlat.new()
	empty.bg_color = Color(0, 0, 0, 0)
	t.set_stylebox("bg", "ScrollContainer", empty)
	t.set_stylebox("panel", "ScrollContainer", empty)
	# 滚动条：液态玻璃细条（半透明冰白滑块 + 透明槽），替代引擎默认灰色方块。
	var trough := UIStyle.glass_box(Color(1.0, 1.0, 1.0, 0.05), Color(1.0, 1.0, 1.0, 0.0), 4, 0)
	var grabber := UIStyle.glass_box(Color(1.0, 1.0, 1.0, 0.30), Color(0.80, 0.92, 1.0, 0.45), 4, 1)
	var grabber_hl := UIStyle.glass_box(Color(1.0, 1.0, 1.0, 0.48), Color(0.82, 0.93, 1.0, 0.60), 4, 1)
	var grabber_pr := UIStyle.glass_box(Color(1.0, 1.0, 1.0, 0.60), UIStyle.BORDER, 4, 1)
	for bar in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", bar, trough)
		t.set_stylebox("grabber", bar, grabber)
		t.set_stylebox("grabber_highlight", bar, grabber_hl)
		t.set_stylebox("grabber_pressed", bar, grabber_pr)
