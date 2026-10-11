# ui/state_view_panel.gd
# 「状态页」查看器 —— 由调试面板的 5 个状态页按钮打开。
#
# 每个状态页只做一件事：读取 %文档%/HelloNyxel/Temp/<文件名>.json 并格式化展示。
# 目前这些状态（玩家画像 / 荧惑剧情状态 / 荧惑日常状态 / 世界状态 / 剧情状态）大多
# 尚未开发或尚未落盘 —— 因此**文件缺失属正常情况**，页面照常打开并给出占位提示 +
# 预期路径，便于后续系统对齐文件名。
#
# 由 Debug（debug/debug_manager.gd）用状态表 STATE_VIEWS 实例化：
#     var p = StateViewPanelScript.new()
#     p.configure("玩家画像", "player_profile.json")   # 必须在入树前调用
#     layer.add_child(p)                                # _ready 里才建 UI
#     p.closed.connect(_on_state_view_closed.bind(key, layer))
class_name StateViewPanel
extends Control

signal closed

const PANEL_W: float = 560.0
const PANEL_H: float = 520.0
const TITLE_H: float = 28.0

# 入树前由 configure() 注入（= 面板身份），_ready() 里才据此建 UI 并读文件。
var _title_text: String = "状态页"
var _file_name: String = ""

var _bg: UIPanel
var _title_label: Label
var _path_label: Label
var _scroll: ScrollContainer
var _body: Label
var _status: Label
var _cjk: FontFile


# 配置（必须在 add_child 之前调用；此时 _ready 尚未跑，UI 成员都还是 null）
func configure(title: String, file_name: String) -> void:
	_title_text = title
	_file_name = file_name


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_cjk = UIStyle.get_cjk_font()
	_build_ui()
	reload()



# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏控件整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build_ui() -> void:
	# 入树前（headless 探针 / 极端时机）get_viewport() 为 null → 给安全尺寸，别报错
	var vp := get_viewport()
	var vs: Vector2 = UIStyle.canvas_viewport_size(self) if vp != null else Vector2(1280.0, 720.0)
	size = Vector2(PANEL_W, PANEL_H)
	position = Vector2(maxf(40.0, (vs.x - PANEL_W) * 0.5), maxf(50.0, (vs.y - PANEL_H) * 0.4))

	_bg = UIPanel.new()
	_bg.name = "Bg"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	# 拖动把柄（右上角，关闭按钮左侧）—— 与 MOD 列表 / 控制台一致的手感
	var drag := UIDragHandle.new()
	drag.name = "DragHandle"
	drag.setup(self)
	drag.anchor_left = 1.0
	drag.anchor_top = 0.0
	drag.anchor_right = 1.0
	drag.anchor_bottom = 0.0
	drag.offset_left = -(TITLE_H * 2.0 + UIStyle.PANEL_PADDING + 4.0)
	drag.offset_top = UIStyle.PANEL_PADDING
	drag.offset_right = -(TITLE_H + UIStyle.PANEL_PADDING + 4.0)
	drag.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING
	add_child(drag)

	# 关闭按钮（右上角，锚定）
	var close_btn := UIBtn.new()
	close_btn.name = "CloseBtn"
	close_btn.set_id("close")
	close_btn.set_label("×")
	close_btn.anchor_left = 1.0
	close_btn.anchor_top = 0.0
	close_btn.anchor_right = 1.0
	close_btn.anchor_bottom = 0.0
	close_btn.offset_left = -(TITLE_H + UIStyle.PANEL_PADDING)
	close_btn.offset_top = UIStyle.PANEL_PADDING
	close_btn.offset_right = -UIStyle.PANEL_PADDING
	close_btn.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING
	close_btn.pressed_id.connect(_on_close_pressed)
	add_child(close_btn)
	_min_btn = UIMinimize.attach_anchored(self, close_btn, func(): set_minimized(not _minimized))

	# 刷新按钮（关闭按钮左侧第二格，紧跟拖动把柄左边）
	var refresh_btn := UIBtn.new()
	refresh_btn.name = "RefreshBtn"
	refresh_btn.set_id("refresh")
	refresh_btn.set_label("刷新")
	refresh_btn.anchor_left = 1.0
	refresh_btn.anchor_top = 0.0
	refresh_btn.anchor_right = 1.0
	refresh_btn.anchor_bottom = 0.0
	refresh_btn.offset_left = -(TITLE_H * 3.0 + UIStyle.PANEL_PADDING + 8.0 + 56.0)
	refresh_btn.offset_top = UIStyle.PANEL_PADDING
	refresh_btn.offset_right = -(TITLE_H * 2.0 + UIStyle.PANEL_PADDING + 12.0)
	refresh_btn.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING
	refresh_btn.pressed_id.connect(_on_refresh_pressed)
	add_child(refresh_btn)

	# 标题（左上角）
	_title_label = Label.new()
	_title_label.name = "TitleLabel"
	_title_label.text = _title_text
	_title_label.position = Vector2(UIStyle.PANEL_PADDING + 2.0, UIStyle.PANEL_PADDING)
	_title_label.custom_minimum_size = Vector2(0.0, TITLE_H)
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", Color(0.8, 0.94, 1.0))
	_title_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 1)
	if is_instance_valid(_cjk):
		_title_label.add_theme_font_override("font", _cjk)
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_title_label)
	# ★ 限宽：页面名较长时不要压到右侧按钮上（此时顶栏按钮均已建好、锚定位置已解析）
	UIMinimize.clamp_title_width(self, _title_label)

	# 文件路径行（让用户能直接照着路径去放/看文件）
	_path_label = Label.new()
	_path_label.name = "PathLabel"
	_path_label.text = ""
	_path_label.clip_text = true
	_path_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_path_label.offset_left = UIStyle.PANEL_PADDING
	_path_label.offset_top = TITLE_H + UIStyle.PANEL_PADDING
	_path_label.offset_right = -UIStyle.PANEL_PADDING
	_path_label.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING + 20.0
	_path_label.add_theme_color_override("font_color", Color(0.78, 0.86, 0.95, 0.75))
	_path_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		_path_label.add_theme_font_override("font", _cjk)
	_path_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_path_label)

	# 正文（滚动区，等宽观感：JSON 缩进直接由空格体现）
	var body_top := TITLE_H + UIStyle.PANEL_PADDING + 22.0
	_scroll = ScrollContainer.new()
	_scroll.name = "BodyScroll"
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.offset_left = UIStyle.PANEL_PADDING
	_scroll.offset_top = body_top
	_scroll.offset_right = -UIStyle.PANEL_PADDING
	_scroll.offset_bottom = -(UIStyle.PANEL_PADDING + 24.0)
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_scroll)

	_body = Label.new()
	_body.name = "BodyLabel"
	_body.text = ""
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_body.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_cjk):
		_body.add_theme_font_override("font", _cjk)
	_scroll.add_child(_body)

	# 状态行（底部，一行）
	_status = Label.new()
	_status.name = "StatusLabel"
	_status.text = ""
	_status.clip_text = true
	_status.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_status.offset_left = UIStyle.PANEL_PADDING
	_status.offset_top = -(UIStyle.PANEL_PADDING + 20.0)
	_status.offset_right = -UIStyle.PANEL_PADDING
	_status.offset_bottom = -UIStyle.PANEL_PADDING
	_status.add_theme_color_override("font_color", Color(0.78, 0.86, 0.95, 0.8))
	_status.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		_status.add_theme_font_override("font", _cjk)
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_status)


# 状态页数据文件路径 = %文档%/HelloNyxel/Temp/<文件名>
# ★ 与 devices/inventory/task_scheduler 等一致，统一走 SaveManager.get_temp_dir()；
#   仅在它不可用时才退回硬编码（与 desktop.gd 的兜底同源）。
func resolve_path() -> String:
	var dir := "D:/Documents/HelloNyxel/Temp"
	if SaveManager != null and SaveManager.has_method("get_temp_dir"):
		dir = str(SaveManager.get_temp_dir())
	return dir.path_join(_file_name)


func get_file_name() -> String:
	return _file_name


func reload() -> void:
	var path := resolve_path()
	if _path_label != null and is_instance_valid(_path_label):
		_path_label.text = "文件: %s" % path
	var txt := _read_text(path)
	if txt.strip_edges().is_empty():
		_set_body("（暂无数据 —— 该状态页尚未开发 / 尚未生成文件）\n\n预期文件路径：\n%s" % path)
		_set_status("未读取到内容（缺失或为空）")
		return
	var parsed: Variant = JSON.parse_string(txt)
	if parsed == null:
		# 解析失败也只能原样展示；null 也可能是合法 JSON 的 null，故与"失败"合并处理。
		_set_body(txt)
		_set_status("读取成功，但非可解析的 JSON 对象（已原样展示）")
		return
	_set_body(JSON.stringify(parsed, "  "))
	_set_status("读取成功 · %d 字符" % txt.length())


func _set_body(t: String) -> void:
	if _body != null and is_instance_valid(_body):
		_body.text = t


func _set_status(t: String) -> void:
	if _status != null and is_instance_valid(_status):
		_status.text = t


func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text()
	f.close()
	return s


func _on_refresh_pressed(_id: String) -> void:
	reload()


func _on_close_pressed(_id: String) -> void:
	close()


# 关闭：销毁自身（与其他调试子面板一致 —— 由 Debug 释放承载层）
func close() -> void:
	closed.emit()


## 最小化 / 还原：折叠只隐藏内容，标题栏控件（标题 / 把柄 / 最小化 / 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.set_label(_min_btn, v)
	UIMinimize.fold_top_strip(self, v)
	UIMinimize.apply_size(self, v)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
