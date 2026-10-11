# popup_dialogue_panel.gd
# 弹窗对话面板（Control）—— 纯「事件表演」显示界面。
# 4 个栏（自上而下）：顶部事件名称栏、事件配图栏、事件内容栏、底部按钮选择栏。
#
# 设计原则：本面板 **只负责显示** DialogueManager 的当前值，不含任何输入控件。
#   写值由事件链脚本（或调试面板的「修改」按钮）通过 DialogueManager 完成。
#   面板显隐由 DialogueManager.popup_visible 控制。
#
# 顶栏右上角两个控制按钮（本次新增）：
#   - 移动把柄 UIDragHandle：按住拖动可移动整个面板（移动后不再自动回到屏幕中心）
#   - 最小化按钮 UIBtn：− 最小化（只留顶栏）/ □ 还原
#
# 历史说明：事件内容栏曾一度改成「LineEdit + 长文本按钮」，后回退为只读显示
#   （现为 RichTextLabel，可渲染 (修饰) 样式）；长文本输入窗（UILongTextInputPanel）只在调试面板使用。
#
# ★ 事件内容栏的显示：内容里若写了 (修饰)[内容] / "字符串" / $变量，
#   必须经 TextRenderer 渲染成 BBCode —— 直接把原文塞给 Label 会把「(#ff0000)[你好]」
#   连同括号一起显示出来（看起来就是「修饰格式不对」）。
class_name PopupDialoguePanel
extends Control

const PANEL_W: float = 520.0
const PANEL_H: float = 380.0
const PAD: float = 12.0
const TITLE_H: float = 30.0
const IMG_H: float = 140.0
const CONTENT_TOP_GAP: float = 8.0
const BTN_H: float = 30.0
const BTN_GAP: float = 6.0
const BTN_W: float = 150.0
# 顶栏控制按钮（移动把柄 / 最小化）
const CTRL_SIZE: float = 28.0
const CTRL_GAP: float = 6.0
# 最小化后的高度 = 顶栏 + 上下内边距
const MIN_H: float = TITLE_H + PAD * 2.0

var _name_label: Label
var _image: TextureRect
var _content_label: RichTextLabel
var _buttons_box: VBoxContainer
var _drag_handle: UIDragHandle
var _min_btn: UIBtn
var _font: FontFile
var _renderer := TextRenderer.new()   # (修饰) → BBCode

var _minimized: bool = false
# 用户拖动过之后，不再自动回到屏幕中心（否则最小化/还原会把面板弹回中间）
var _moved: bool = false


func _ready() -> void:
	_font = UIStyle.get_cjk_font()

	# 背景面板（FULL_RECT → 跟随面板尺寸，最小化时自动变矮）
	var bg := UIPanel.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	bg.set_fill_color(UIStyle.FILL_DEFAULT)
	bg.set_border_color(UIStyle.BORDER)
	bg.set_border_width(UIStyle.BORDER_WIDTH)
	add_child(bg)

	# 顶部事件名称栏
	_name_label = Label.new()
	_name_label.name = "EventName"
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_label.clip_text = true
	_name_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_name_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 2)
	if is_instance_valid(_font):
		_name_label.add_theme_font_override("font", _font)
	add_child(_name_label)

	# 移动把柄（顶栏右侧；按住拖动 → 整个面板跟着走）
	_drag_handle = UIDragHandle.new()
	_drag_handle.name = "DragHandle"
	_drag_handle.setup(self)
	_drag_handle.drag_started.connect(_on_drag_started)
	add_child(_drag_handle)

	# 最小化按钮（顶栏最右；− 最小化 / □ 还原）
	_min_btn = UIBtn.new()
	_min_btn.name = "MinBtn"
	_min_btn.set_id("popup_minimize")
	_min_btn.set_label("−")
	_min_btn.pressed_id.connect(_on_min_pressed)
	add_child(_min_btn)

	# 事件配图栏
	_image = TextureRect.new()
	_image.name = "EventImage"
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(_image)

	# 事件内容栏（只读 RichTextLabel；自动换行，(修饰) 生效）
	_content_label = RichTextLabel.new()
	_content_label.name = "EventContent"
	_content_label.bbcode_enabled = true
	_content_label.scroll_active = false
	_content_label.fit_content = false
	_content_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_content_label.add_theme_color_override("default_color", UIStyle.TEXT_DEFAULT)
	_content_label.add_theme_font_size_override("normal_font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_font):
		_content_label.add_theme_font_override("normal_font", _font)
	add_child(_content_label)

	# 底部按钮选择栏
	_buttons_box = VBoxContainer.new()
	_buttons_box.name = "Buttons"
	_buttons_box.add_theme_constant_override("separation", int(BTN_GAP))
	add_child(_buttons_box)

	# 监听全局变量
	DialogueManager.variable_changed.connect(_on_var_changed)
	DialogueManager.panel_visibility_changed.connect(_on_vis_changed)
	DialogueManager.dialogue_button_pressed.connect(_on_dialogue_button)
	# ★ 切语言：事件正文由事件链执行器按新语言 txt 重贴（它先收到 language_changed），
	#   这里只负责把按钮文字也跟着重排（事件链没在跑、按钮由别处写值时也能生效）。
	if not TranslationManager.language_changed.is_connected(_on_language_changed):
		TranslationManager.language_changed.connect(_on_language_changed)

	_refresh_all()
	_layout()
	visible = DialogueManager.popup_visible
	# 视口尺寸变化 → 重新布局（未手动拖动过时回到屏幕中心，拖动过则保持用户位置）
	get_viewport().size_changed.connect(_layout)


# ================= 布局 =================

func _layout() -> void:
	size = Vector2(PANEL_W, MIN_H if _minimized else PANEL_H)
	if not _moved:
		var vp := UIStyle.canvas_viewport_size(self)
		position = Vector2((vp.x - PANEL_W) * 0.5, (vp.y - PANEL_H) * 0.5)
	_layout_children()


# 子节点按当前尺寸摆放（最小化时内容控件被隐藏，只留顶栏）
func _layout_children() -> void:
	var ctrl_y: float = PAD + (TITLE_H - CTRL_SIZE) * 0.5
	var ctrl_right: float = PANEL_W - PAD

	# 顶部事件名称栏（右侧预留两个控制按钮的宽度）
	_name_label.position = Vector2(PAD, PAD)
	_name_label.size = Vector2(max(40.0, ctrl_right - CTRL_SIZE * 2.0 - CTRL_GAP - PAD), TITLE_H)

	# 顶栏右侧：移动把柄 + 最小化按钮
	_drag_handle.position = Vector2(ctrl_right - CTRL_SIZE * 2.0 - CTRL_GAP, ctrl_y)
	_drag_handle.size = Vector2(CTRL_SIZE, CTRL_SIZE)
	_min_btn.position = Vector2(ctrl_right - CTRL_SIZE, ctrl_y)
	_min_btn.size = Vector2(CTRL_SIZE, CTRL_SIZE)

	# 事件配图栏
	_image.position = Vector2(PAD, PAD + TITLE_H + CONTENT_TOP_GAP)
	_image.size = Vector2(PANEL_W - PAD * 2.0, IMG_H)

	# 事件内容栏（配图下方 → 按钮栏上方）
	var content_y: float = PAD + TITLE_H + CONTENT_TOP_GAP + IMG_H + CONTENT_TOP_GAP
	var content_h: float = PANEL_H - content_y - PAD - BTN_H - CONTENT_TOP_GAP
	_content_label.position = Vector2(PAD, content_y)
	_content_label.size = Vector2(PANEL_W - PAD * 2.0, max(20.0, content_h))

	# 底部按钮选择栏
	_buttons_box.position = Vector2((PANEL_W - BTN_W) * 0.5, PANEL_H - PAD - BTN_H)
	_buttons_box.size = Vector2(BTN_W, BTN_H)


# ================= 最小化 / 移动 =================

func _on_min_pressed(_id: String) -> void:
	set_minimized(not _minimized)


# 公开 API：最小化（只保留顶栏）/ 还原
func set_minimized(v: bool) -> void:
	_minimized = v
	if _min_btn == null:
		return
	UIMinimize.set_label(_min_btn, _minimized)
	# 标题栏控件（标题 / 把柄 / 最小化 / 关闭）是本面板的**直接孩子** → 按顶栏条带折叠
	UIMinimize.fold_top_strip(self, _minimized)
	# ★ 顺序要紧：先 apply_size（此时还是展开尺寸 → 由它记下原始 size 供还原），
	#   再 _layout()（它会按最小化态重设 size），最后再收一次宽度（记录已在首次完成）。
	#   若把 apply_size 放在 _layout 之后，记下的就是「已收过的高度」→ 还原不回去。
	UIMinimize.apply_size(self, _minimized, MIN_H)
	_layout()
	UIMinimize.apply_size(self, _minimized, MIN_H)


# 公开 API：当前是否最小化
func is_minimized() -> bool:
	return _minimized


func _on_drag_started() -> void:
	# 用户一旦手动拖动，位置交还给用户（最小化/还原不再自动居中）
	_moved = true


# ================= 数据显示 =================

func _refresh_all() -> void:
	_name_label.text = DialogueManager.event_name
	_apply_image(DialogueManager.event_image_path)
	_content_label.text = _content_bbcode(DialogueManager.event_content)
	_rebuild_buttons(DialogueManager.popup_buttons)


## 事件正文 → BBCode：把 (修饰)[内容] / "字符串" / $变量 渲染出来。
## 直接赋原文给控件会把括号与修饰当正文显示，所以必须走渲染器。
func _content_bbcode(raw: String) -> String:
	if raw.strip_edges().is_empty():
		return ""
	var r: Dictionary = _renderer.to_bbcode(raw, DialogueVoice.default_resolver())
	return str(r.get("bbcode", ""))


func _apply_image(path: String) -> void:
	# ★ 走 TextureCache：既支持 res:// 已导入图，也支持玩家素材目录的绝对路径图
	#   （原来直接 ResourceLoader.exists，只认项目内已导入的图）。
	if path != "":
		_image.texture = TextureCache.fetch(path)
	else:
		_image.texture = null


func _rebuild_buttons(arr: Array) -> void:
	for c in _buttons_box.get_children():
		c.queue_free()
	for entry in arr:
		if entry is Dictionary and entry.has("label"):
			var btn := UIBtn.new()
			btn.set_id(entry.get("id", ""))
			# ★★ 按钮文字与事件正文同源（(修饰)[内容] 定义串）→ 同一条富文本管线，
			#   否则会把修饰连同括号原样显示出来（历史 bug）。
			#   没写修饰的仍走普通 Label（保持历史观感、不多挂节点）。
			var lab := DialogueVoice.render_button_label(str(entry.get("label", "?")),
				TranslationManager.current_lang)
			if bool(lab.get("rich", false)):
				btn.set_label_bbcode(str(lab.get("bbcode", "")), str(lab.get("plain", "")))
			else:
				btn.set_label(str(lab.get("plain", "")))
			btn.custom_minimum_size = Vector2(BTN_W, BTN_H)
			btn.size = Vector2(BTN_W, BTN_H)
			btn.pressed_id.connect(_on_btn_pressed)
			_buttons_box.add_child(btn)


func _on_btn_pressed(id: String) -> void:
	DialogueManager.emit_button("popup", id)
	# 记录玩家按下的按钮（显示文本从当前按钮列表里按 id 查）
	var label := _button_label(id, DialogueManager.popup_buttons)
	if not DialogueManager.is_restating():
		DialogueLog.record_button("popup", id, label)


# 从按钮列表里按 id 查**显示文本**：把定义串渲染成纯文本（查不到 / 空 → 用 id 兜底）
func _button_label(id: String, arr: Array) -> String:
	for e in arr:
		if e is Dictionary and str(e.get("id", "")) == id:
			var def := str(e.get("label", "")).strip_edges()
			if def.is_empty():
				return id
			return str(DialogueVoice.to_display(def, TranslationManager.current_lang).get("display", ""))
	return id


func _on_var_changed(name: String, _value: Variant) -> void:
	match name:
		"event_name":
			_name_label.text = DialogueManager.event_name
		"event_image_path":
			_apply_image(DialogueManager.event_image_path)
		"event_content":
			_content_label.text = _content_bbcode(DialogueManager.event_content)
			# 事件内容更新 → 记入台词记录（去修饰后的纯文本）
			# ★ 但「切语言重贴」不是新说了一句 → 那段时间里不记（见 DialogueManager.is_restating）。
			if not DialogueManager.is_restating():
				var plain: String = DialogueVoice.parse(
					DialogueManager.event_content, TranslationManager.current_lang).get("display", "")
				DialogueLog.record_line("popup", plain)
		"popup_buttons":
			_rebuild_buttons(DialogueManager.popup_buttons)


func _on_language_changed(_lang: String) -> void:
	# 事件正文是「已求值的纯文本」，面板自己无法重新本地化 → 由事件链执行器负责；
	# 这里只需把按钮文字（定义串，面板自己能渲染）重排一次。
	_rebuild_buttons(DialogueManager.popup_buttons)


func _on_vis_changed(panel: String, vis: bool) -> void:
	if panel == "popup":
		visible = vis


# 预留：未来事件链接管对话面板按钮
func _on_dialogue_button(_panel: String, _id: String) -> void:
	pass
