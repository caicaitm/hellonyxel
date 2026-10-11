# ui/save_list_panel.gd
# 「存档列表」页面：由系统托盘图标的右键二级菜单「存档 → 打开存档列表」打开（见 TrayRunner / TrayIcon.cs）。
#
# 与设置页面同一套 UI 模式：
#   · 面板本体为 Control，居中（可拖动把柄移动），复用了天蓝半透明底 + 荧光蓝边框
#   · 内容区套 ScrollContainer + VBoxContainer，存档条目逐行列出
#   · 支持手动存档（可输入存档名，默认时间命名/重名自动加后缀）、读取、删除
#   · 列表数据来自 SaveManager（autoload），每次打开时刷新
class_name SaveListPanel
extends Control

signal closed

const W := 520.0
const H := 460.0
const PAD := 16.0
const TITLE_H := 40.0
const ROW_H := 40.0
const FOOTER_H := 64.0

var _panel: UIPanel
var _title: Label
var _foot: HBoxContainer = null
var _scroll: ScrollContainer
var _rows_root: VBoxContainer
var _drag_handle: UIDragHandle
var _name_edit: LineEdit
var _save_btn: UIBtn
var _close_btn: UIBtn
var _open_folder_btn: UIBtn
var _open: bool = false
var _ever_centered: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	if not TranslationManager.language_changed.is_connected(_on_lang_changed):
		TranslationManager.language_changed.connect(_on_lang_changed)
	visible = false


func open() -> void:
	_open = true
	visible = true
	_refresh_list()
	if not _ever_centered:
		_center()
		_ever_centered = true
	move_to_front()


func close() -> void:
	_open = false
	visible = false
	get_viewport().gui_release_focus()
	closed.emit()


func is_open() -> bool:
	return _open


# ---------------- 构建 UI ----------------


# 「最小化」按钮由 UIMinimize 统一创建
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build_ui() -> void:
	_panel = UIPanel.new()
	_panel.name = "UIPanel"
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.set_corner_radius(UIStyle.CORNER_RADIUS)
	_panel.set_fill_color(UIStyle.FILL_DEFAULT)
	_panel.set_border_color(UIStyle.BORDER)
	_panel.set_border_width(UIStyle.BORDER_WIDTH)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	# 顶栏：标题 + 右侧拖动把柄
	var top := _hbox()
	top.position = Vector2(PAD, PAD)
	top.size = Vector2(W - PAD * 2.0, 30.0)
	add_child(top)

	_title = _label(TranslationManager.t("存档列表"))
	_title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 6)
	_title.custom_minimum_size = Vector2(0.0, 30.0)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_title)

	_drag_handle = UIDragHandle.new()
	top.add_child(_drag_handle)
	_drag_handle.setup(self)
	_drag_handle.tooltip_text = "拖动以移动面板"
	# 最小化按钮（排在拖动把柄右侧）
	_min_btn = UIMinimize.attach(top, func(): set_minimized(not _minimized))
	# ★ 顶栏 × 关闭：底栏已有一个「关闭」，这里再给顶栏一个，符合「折叠后仍能关」的惯例，
	#   也让关闭按钮与其他页面一样出现在标题栏右侧。
	var top_close := UIBtn.new()
	top_close.set_id("close_top")
	top_close.set_label("×")
	top_close.custom_minimum_size = Vector2(28, 28)
	top_close.pressed_id.connect(_on_close_top)
	top.add_child(top_close)

	# 内容区：存档列表（可滚动）
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.position = Vector2(PAD, PAD + TITLE_H)
	_scroll.size = Vector2(W - PAD * 2.0, H - PAD - TITLE_H - FOOTER_H)
	add_child(_scroll)

	_rows_root = VBoxContainer.new()
	_rows_root.name = "Rows"
	_rows_root.custom_minimum_size = Vector2(W - PAD * 2.0, 0.0)
	_rows_root.add_theme_constant_override("separation", 6)
	_scroll.add_child(_rows_root)

	# —— 底部：存档名输入 + 保存 / 关闭 ——
	var foot := _hbox()
	_foot = foot
	foot.position = Vector2(PAD, H - PAD - 44.0)
	foot.size = Vector2(W - PAD * 2.0, 36.0)
	add_child(foot)

	var lbl := _label(TranslationManager.t("存档名"))
	lbl.custom_minimum_size = Vector2(64.0, 30.0)
	foot.add_child(lbl)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = TranslationManager.t("存档名")
	UIStyle.apply_line_edit_style(_name_edit)
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.custom_minimum_size = Vector2(0.0, 30.0)
	_name_edit.editable = true
	foot.add_child(_name_edit)

	_save_btn = UIBtn.new()
	_save_btn.set_label(TranslationManager.t("保存"))
	_save_btn.custom_minimum_size = Vector2(72.0, 30.0)
	_save_btn.pressed_id.connect(_on_save)
	foot.add_child(_save_btn)

	_close_btn = UIBtn.new()
	_close_btn.set_label(TranslationManager.t("关闭"))
	_close_btn.custom_minimum_size = Vector2(64.0, 30.0)
	_close_btn.pressed_id.connect(_on_close)
	foot.add_child(_close_btn)

	# 在资源管理器里打开存档文件夹（图标按钮，形制与其它按钮一致）
	_open_folder_btn = UIBtn.new()
	_open_folder_btn.set_label("📂")
	_open_folder_btn.tooltip_text = "在资源管理器打开存档文件夹"
	_open_folder_btn.custom_minimum_size = Vector2(34.0, 30.0)
	_open_folder_btn.pressed_id.connect(_on_open_folder)
	foot.add_child(_open_folder_btn)


func _on_lang_changed(_lang: String) -> void:
	TranslationManager.retranslate_tree(self)
	_refresh_list()


# ---------------- 列表刷新 ----------------

func _refresh_list() -> void:
	for c in _rows_root.get_children():
		c.queue_free()
	var saves: Array = SaveManager.list_saves() if SaveManager != null else []
	# 按「桌面 / 世界」切成两个分区：上部桌面存档、下部世界存档。
	var world_type: String = SaveManager.TYPE_WORLD if SaveManager != null else "world"
	var desktop: Array = []
	var world: Array = []
	for meta in saves:
		if str(meta.get("type", "")) == world_type:
			world.append(meta)
		else:
			desktop.append(meta)
	_rows_root.add_child(_build_section(TranslationManager.t("桌面存档"), desktop))
	_rows_root.add_child(_build_section(TranslationManager.t("世界存档"), world))


## 一个分区（桌面 / 世界）：标题 + 「手动」「自动」两组。
## 组内按时间倒序（最新在前）；该类型一份存档都没有时给一句提示。
func _build_section(title: String, items: Array) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var head := _label(title)
	head.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 2)
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(head)

	if items.is_empty():
		var none := _label(TranslationManager.t("没有存档"))
		none.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		none.add_theme_color_override("font_color", _dim_color())
		box.add_child(none)
		return box

	var manual: Array = []
	var auto: Array = []
	for m in items:
		if bool(m.get("auto", false)):
			auto.append(m)
		else:
			manual.append(m)
	manual.sort_custom(_newest_first)
	auto.sort_custom(_newest_first)

	_add_group(box, TranslationManager.t("手动存档"), manual)
	_add_group(box, TranslationManager.t("自动存档"), auto)
	return box


## 分区内的一个小组（手动 / 自动）：小标题 + 该组各行；空组整体不显示。
func _add_group(box: Control, title: String, items: Array) -> void:
	if items.is_empty():
		return
	var sub := _label(title)
	sub.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	sub.add_theme_color_override("font_color", _dim_color())
	sub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(sub)
	for m in items:
		box.add_child(_build_row(m))


## 排序比较器：时间倒序（最新在前）
func _newest_first(a: Variant, b: Variant) -> bool:
	return int(a.get("created_at", 0)) > int(b.get("created_at", 0))


## 次级文字颜色（分区小标题用）：沿用 UIStyle 里 placeholder 的做法，取 TEXT_DEFAULT 降透明度
func _dim_color() -> Color:
	return Color(UIStyle.TEXT_DEFAULT.r, UIStyle.TEXT_DEFAULT.g, UIStyle.TEXT_DEFAULT.b, 0.7)


func _build_row(meta: Dictionary) -> Control:
	var name: String = str(meta.get("name", ""))
	var created: int = int(meta.get("created_at", 0))

	var row := _hbox()
	# ★ 原「N块」的位置改为显示 手动 / 自动。
	#   桌面 / 世界已由所属分区标题表达，行内不再重复类型标签。
	var kind := TranslationManager.t("自动") if bool(meta.get("auto", false)) else TranslationManager.t("手动")
	var info := _label("%s  %s" % [kind, _fmt_time(created)])
	info.custom_minimum_size = Vector2(0.0, 30.0)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(info)

	var load_btn := UIBtn.new()
	load_btn.set_label(TranslationManager.t("读取"))
	load_btn.custom_minimum_size = Vector2(62.0, 28.0)
	load_btn.pressed_id.connect(_on_load.bind(name))
	row.add_child(load_btn)

	var del_btn := UIBtn.new()
	del_btn.set_label(TranslationManager.t("删除"))
	del_btn.custom_minimum_size = Vector2(62.0, 28.0)
	del_btn.pressed_id.connect(_on_delete.bind(name))
	row.add_child(del_btn)

	return row


# ---------------- 交互 ----------------

func _on_save(_id: String) -> void:
	if SaveManager == null:
		return
	var custom := _name_edit.text.strip_edges()
	# 手动存档默认存「桌面」类型（世界系统独立，尚未开发）
	var res: Dictionary = SaveManager.save(SaveManager.TYPE_DESKTOP, custom)
	if res.get("ok", false):
		_name_edit.clear()
	_refresh_list()


func _on_load(_id: String, name: String) -> void:
	if SaveManager == null:
		return
	var res: Dictionary = SaveManager.load_save(name)
	print("[SaveListPanel] 读取存档 %s → ok=%s" % [name, res.get("ok", false)])
	close()
	_refresh_list()


func _on_delete(_id: String, name: String) -> void:
	if SaveManager != null:
		SaveManager.delete_save(name)
	_refresh_list()


func _on_close(_id: String) -> void:
	close()


# 顶栏 × 关闭（与底栏「关闭」等效；折叠状态下底栏仍可见，故两者都在）
func _on_close_top(_id: String) -> void:
	close()


func _on_open_folder(_id: String) -> void:
	if SaveManager == null:
		return
	var dir: String = SaveManager.get_saves_dir()
	if dir.is_empty():
		printerr("[SaveListPanel] 存档目录为空，无法打开")
		return
	# 目录可能尚未创建（无存档时），先确保存在再交给系统打开
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	OS.shell_open(dir)


# ---------------- 小工具 ----------------

func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fnt = UIStyle.get_cjk_font()
	if fnt != null:
		l.add_theme_font_override("font", fnt)
	l.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	l.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	return l


func _hbox() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	return h


func _fmt_time(unix: int) -> String:
	if unix <= 0:
		return ""
	var d := Time.get_datetime_dict_from_unix_time(unix)
	return "%04d-%02d-%02d %02d:%02d" % [int(d.year), int(d.month), int(d.day), int(d.hour), int(d.minute)]


func _center() -> void:
	var vp: Vector2 = UIStyle.canvas_viewport_size(self)
	size = Vector2(W, H)
	position = (vp - size) / 2.0
	# ★ is_instance_valid：_panel 可能已被释放（`if _panel:` 对已释放实例仍可能为真 → use-after-free）。
	if is_instance_valid(_panel):
		_panel.size = size

## 最小化 / 还原：本页关闭按钮在**底栏**，所以折叠只隐藏中间的存档列表；
## 顶栏（标题 + 拖动把柄 + 最小化）与底栏（存档名 + 保存 + 关闭）都保留 —— 仍能拖走、仍能关。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.set_label(_min_btn, v)
	UIMinimize.fold_rows([_scroll, _foot], v)
	UIMinimize.apply_size(self, v)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
