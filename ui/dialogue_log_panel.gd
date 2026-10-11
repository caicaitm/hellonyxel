# dialogue_log_panel.gd
# 台词记录查看页（Control）。
# 显示 DialogueLog 的历史记录：每行 = [时间] 类型 文本；每页 100 条，超出翻页。
# 打开时跳到最后一页（最新记录）；有新记录且当前停在末页时自动刷新。
#
# 面板由底部对话栏的「台词记录」按钮（重播按钮左侧）按需打开（挂到 ui_layer）。
class_name DialogueLogPanel
extends Control

const PANEL_W: float = 660.0
const PANEL_H: float = 540.0
const PAD: float = 12.0
const TITLE_H: float = 30.0
const FOOTER_H: float = 40.0
const CTRL_SIZE: float = 28.0
const PER_PAGE: int = 100

var _title: Label
var _drag_handle: UIDragHandle = null
var _close_btn: UIBtn
var _scroll: ScrollContainer
var _list: VBoxContainer
var _prev_btn: UIBtn
var _next_btn: UIBtn
var _page_label: Label
var _page: int = 1
var _font: FontFile



# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏控件整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _ready() -> void:
	_font = UIStyle.get_cjk_font()

	var bg := UIPanel.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	bg.set_fill_color(UIStyle.FILL_DEFAULT)
	bg.set_border_color(UIStyle.BORDER)
	bg.set_border_width(UIStyle.BORDER_WIDTH)
	add_child(bg)

	# 标题
	_title = Label.new()
	_title.name = "Title"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 2)
	if is_instance_valid(_font):
		_title.add_theme_font_override("font", _font)
	add_child(_title)

	# 关闭按钮（右上）
	# 拖动把柄（锚定右上角）：本页原先没有 → 折叠后只剩「最小化/关闭」，无法移动。
	#   排布由 UIMinimize 统一成「移动 | 最小化 | 关闭」。
	_drag_handle = UIDragHandle.new()
	_drag_handle.name = "DragHandle"
	_drag_handle.setup(self)
	_drag_handle.anchor_left = 1.0
	_drag_handle.anchor_top = 0.0
	_drag_handle.anchor_right = 1.0
	_drag_handle.anchor_bottom = 0.0
	_drag_handle.offset_top = UIStyle.PANEL_PADDING
	_drag_handle.offset_bottom = UIStyle.PANEL_PADDING + 28.0
	add_child(_drag_handle)

	_close_btn = UIBtn.new()
	_close_btn.name = "Close"
	_close_btn.set_id("log_close")
	_close_btn.set_label("✕")
	_close_btn.pressed_id.connect(_on_close)
	add_child(_close_btn)
	_min_btn = UIMinimize.attach_anchored(self, _close_btn, func(): set_minimized(not _minimized))

	# 滚动列表
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_list = VBoxContainer.new()
	_list.name = "List"
	_list.add_theme_constant_override("separation", 2)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)

	# 底部分页栏
	_prev_btn = UIBtn.new()
	_prev_btn.name = "Prev"
	_prev_btn.set_id("log_prev")
	_prev_btn.set_label(TranslationManager.t("上一页"))
	_prev_btn.pressed_id.connect(_on_prev)
	add_child(_prev_btn)

	_next_btn = UIBtn.new()
	_next_btn.name = "Next"
	_next_btn.set_id("log_next")
	_next_btn.set_label(TranslationManager.t("下一页"))
	_next_btn.pressed_id.connect(_on_next)
	add_child(_next_btn)

	_page_label = Label.new()
	_page_label.name = "Page"
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_page_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	if is_instance_valid(_font):
		_page_label.add_theme_font_override("font", _font)
	add_child(_page_label)

	_layout()
	_translate()
	if not TranslationManager.language_changed.is_connected(_on_language_changed):
		TranslationManager.language_changed.connect(_on_language_changed)
	if not DialogueLog.changed.is_connected(_on_log_changed):
		DialogueLog.changed.connect(_on_log_changed)
	jump_to_last_page()


func _layout() -> void:
	var vp := UIStyle.canvas_viewport_size(self)
	position = Vector2((vp.x - PANEL_W) * 0.5, (vp.y - PANEL_H) * 0.5)
	size = Vector2(PANEL_W, PANEL_H)

	_title.position = Vector2(PAD, PAD)
	_title.size = Vector2(max(40.0, PANEL_W - PAD * 2.0 - CTRL_SIZE - PAD), TITLE_H)

	_close_btn.position = Vector2(PANEL_W - PAD - CTRL_SIZE, PAD)
	_close_btn.size = Vector2(CTRL_SIZE, CTRL_SIZE)

	var list_y := PAD + TITLE_H + PAD
	var list_h := PANEL_H - list_y - FOOTER_H - PAD
	_scroll.position = Vector2(PAD, list_y)
	_scroll.size = Vector2(PANEL_W - PAD * 2.0, max(40.0, list_h))

	var fy := PANEL_H - PAD - FOOTER_H
	var btn_w := 90.0
	_prev_btn.position = Vector2(PAD, fy)
	_prev_btn.size = Vector2(btn_w, FOOTER_H)
	_next_btn.position = Vector2(PANEL_W - PAD - btn_w, fy)
	_next_btn.size = Vector2(btn_w, FOOTER_H)
	_page_label.position = Vector2(PAD + btn_w + PAD, fy)
	_page_label.size = Vector2(max(40.0, PANEL_W - PAD * 2.0 - btn_w * 2.0 - PAD * 2.0), FOOTER_H)


func _translate() -> void:
	_title.text = TranslationManager.t("台词记录")
	_prev_btn.set_label(TranslationManager.t("上一页"))
	_next_btn.set_label(TranslationManager.t("下一页"))


func _on_language_changed(_lang: String) -> void:
	_translate()
	_refresh()


# 打开时跳到最新一页
func jump_to_last_page() -> void:
	_page = DialogueLog.last_page(PER_PAGE)
	_refresh()


func _on_log_changed() -> void:
	# 仅当停在末页时自动跟随新记录；翻看历史时不打扰
	if _page >= DialogueLog.page_count(PER_PAGE):
		_page = DialogueLog.page_count(PER_PAGE)
		_refresh()


func _on_prev(_id: String) -> void:
	_page = maxi(1, _page - 1)
	_refresh()


func _on_next(_id: String) -> void:
	_page = mini(DialogueLog.page_count(PER_PAGE), _page + 1)
	_refresh()


func _on_close(_id: String) -> void:
	queue_free()


func _type_tag(panel: String, type: String) -> String:
	if type == "button":
		return "按钮" if panel == "bottom" else "弹窗按钮"
	return "台词" if panel == "bottom" else "事件"


func _fmt_time(t: float) -> String:
	var dt := Time.get_datetime_dict_from_unix_time(t)
	return "%02d-%02d %02d:%02d:%02d" % [dt["month"], dt["day"], dt["hour"], dt["minute"], dt["second"]]


func _refresh() -> void:
	_page = clampi(_page, 1, DialogueLog.page_count(PER_PAGE))
	for c in _list.get_children():
		c.queue_free()
	var rows := DialogueLog.get_page(_page, PER_PAGE)
	for e in rows:
		var lbl := Label.new()
		lbl.name = "Row"
		var tag := _type_tag(str(e.get("panel", "")), str(e.get("type", "")))
		var ts := _fmt_time(float(e.get("t", 0)))
		var content := str(e.get("text", ""))
		lbl.text = "[%s] %s  %s" % [ts, tag, content]
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
		lbl.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
		if is_instance_valid(_font):
			lbl.add_theme_font_override("font", _font)
		_list.add_child(lbl)
	_page_label.text = "%d / %d" % [_page, DialogueLog.page_count(PER_PAGE)]
	_prev_btn.disabled = _page <= 1
	_next_btn.disabled = _page >= DialogueLog.page_count(PER_PAGE)
	# 末页自动滚到最新一条
	if _page >= DialogueLog.page_count(PER_PAGE):
		_scroll.scroll_vertical = 100000


## 最小化 / 还原：折叠只隐藏内容，标题栏控件（标题 / 把柄 / 最小化 / 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.set_label(_min_btn, v)
	UIMinimize.fold_top_strip(self, v)
	UIMinimize.apply_size(self, v)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
