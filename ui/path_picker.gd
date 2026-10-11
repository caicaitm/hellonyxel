# path_picker.gd
# 文件选择按钮（文件夹图标）+ 系统「资源管理器」文件对话框 → 把选中的文件以 **res:// 相对路径**
# 填回对应的输入框。
#
# 用法（一行接入）：
#     UIPathPicker.attach(line_edit, UIPathPicker.DIR_TEXTURES,
#         {"exts": UIPathPicker.IMG_EXTS, "title": "选择图片"})
# 会在该输入框**右侧**插入一个文件夹小按钮：
#   - 点击 → `DisplayServer` 原生文件对话框（`FileDialog.use_native_dialog = true`，即资源管理器样式）；
#   - 默认打开位置 = 该字段对应的**默认目录**（`res://...` → `globalize_path` 后的真实路径）；
#   - 选中后 → `ProjectSettings.localize_path()` 转成 `res://...` 写回输入框。
#
# ★★ 选到项目目录之外的文件（无法表示成 res://）→ **不写入**，只弹提示。
#    这是需求里「现阶段确保不会错误填入」的落地：宁可不填，也不写一个错路径进存档。
#
# ★ 与既有实现保持一致：`ui/api_config_panel.gd::_on_pick_files_pressed` 同样是
#   `FileDialog + use_native_dialog = true + ACCESS_FILESYSTEM`。
extends Node
class_name UIPathPicker

const BTN_W: float = 26.0
const BTN_H: float = 20.0

# 各字段的默认目录（相对路径的唯一出处）
const DIR_TEXTURES := "res://textures/"
const DIR_VALUE_BARS := "res://textures/value_bars/"
const DIR_AUDIO := "res://audio/"
const DIR_ROOT := "res://"

# 文件类型过滤串（FileDialog.filters 用 "扩展名列表 ; 名称" 的写法）
const IMG_EXTS := "*.png,*.jpg,*.jpeg,*.webp,*.svg,*.bmp,*.tga,*.gif"
const AUDIO_EXTS := "*.wav,*.ogg,*.mp3"
const ANY_EXTS := "*.*"

static var _icon: ImageTexture = null

var _target: LineEdit = null
var _default_dir: String = DIR_ROOT
var _opts: Dictionary = {}
var _dlg: FileDialog = null
var _btn: Button = null


# ==================== 一站式接入 ====================

## 给输入框接入「选择文件」按钮。返回该选择器节点（挂在输入框下，随其一起释放）。
static func attach(target: LineEdit, default_dir: String, opts: Dictionary = {}) -> UIPathPicker:
	if not is_instance_valid(target):
		return null
	var p := UIPathPicker.new()
	p.name = "PathPicker"
	p._target = target
	p._default_dir = default_dir
	p._opts = opts
	target.add_child(p)                       # 挂在输入框下：输入框所在行被重建时一并释放
	var row: Node = target.get_parent()
	if row != null:
		var b := p._make_button()
		row.add_child(b)
		row.move_child(b, target.get_index() + 1)   # 紧跟输入框（不依赖 add 顺序）
		p._btn = b
	return p


# ==================== 按钮 ====================

func _make_button() -> Button:
	var b := Button.new()
	b.name = "PathPick"
	b.tooltip_text = "选择文件（默认目录 %s）" % _default_dir
	b.icon = folder_icon()
	b.expand_icon = true
	b.custom_minimum_size = Vector2(BTN_W, BTN_H)
	b.size = Vector2(BTN_W, BTN_H)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.focus_mode = Control.FOCUS_NONE          # 别抢输入框的焦点
	var sb := UIStyle.glass_box(UIStyle.FILL_DEFAULT, UIStyle.BORDER, int(UIStyle.CORNER_RADIUS), 1, true)
	sb.content_margin_left = 3
	sb.content_margin_right = 3
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	var sb_hover: StyleBoxFlat = sb.duplicate()
	sb_hover.bg_color = UIStyle.FILL_HOVER
	var sb_pressed: StyleBoxFlat = sb.duplicate()
	sb_pressed.bg_color = UIStyle.FILL_PRESSED
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb_hover)
	b.add_theme_stylebox_override("pressed", sb_pressed)
	b.add_theme_stylebox_override("focus", sb)
	b.pressed.connect(_on_pressed)
	return b


## 文件夹图标：程序化画一张（项目里没有文件夹图标资源；emoji 在 simhei 字体下会变豆腐块）。
## ★ 缓存在静态变量里，所有按钮共用同一张纹理。
static func folder_icon(sz: int = 20) -> ImageTexture:
	if _icon != null and is_instance_valid(_icon):
		return _icon
	var img := Image.create_empty(sz, sz, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var edge := Color(0.04, 0.20, 0.38, 0.95)    # 深蓝描边（压在浅色按钮上也看得清）
	var body := Color(1, 1, 1, 0.96)
	# 先画「外描边」的方块，再用白色主体压上去 → 得到带描边的文件夹轮廓
	img.fill_rect(Rect2i(2, 4, 7, 6), edge)      # 标签（外）
	img.fill_rect(Rect2i(2, 7, 16, 10), edge)    # 主体（外）
	img.fill_rect(Rect2i(3, 5, 5, 4), body)      # 标签（内）
	img.fill_rect(Rect2i(3, 8, 14, 8), body)     # 主体（内）
	_icon = ImageTexture.create_from_image(img)
	return _icon


# ==================== 打开对话框 ====================

func _on_pressed() -> void:
	if not is_instance_valid(_target):
		return
	if DisplayServer.get_name() == "headless":
		notify_msg("当前环境不支持文件选择")
		return
	var dlg := _ensure_dialog()
	dlg.title = String(_opts.get("title", "选择文件"))
	dlg.filters = _filters_for(_opts)
	dlg.current_dir = default_dir_abs(_default_dir)
	dlg.current_file = ""
	dlg.popup_centered_ratio(0.6)


func _ensure_dialog() -> FileDialog:
	if _dlg != null and is_instance_valid(_dlg):
		return _dlg
	_dlg = FileDialog.new()
	_dlg.name = "PathPickerDialog"
	_dlg.access = FileDialog.ACCESS_FILESYSTEM
	_dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dlg.use_native_dialog = true          # ★ 系统「资源管理器」样式对话框
	# ★ 单选模式(FILE_MODE_OPEN_FILE)发出 file_selected(单数)；多选模式发出 files_selected(复数)。
	#   两个都连上，无论当前是哪种模式都能回填路径（之前只连了复数 → 单选时路径永不被写入）。
	_dlg.file_selected.connect(_on_file_selected)
	_dlg.files_selected.connect(_on_files_selected)
	add_child(_dlg)
	return _dlg


# 单选模式回调（FILE_MODE_OPEN_FILE）：双击或按「打开」按钮时触发。
func _on_file_selected(path: String) -> void:
	if path == null or path == "":
		return
	apply_abs_path(_target, path)


func _on_files_selected(paths: PackedStringArray) -> void:
	if paths.is_empty():
		return
	apply_abs_path(_target, str(paths[0]))


# ==================== 路径换算（纯逻辑，便于单独验证）====================

## `res://...` → 真实磁盘绝对路径（目录不存在时回退到项目根，避免对话框开到奇怪位置）。
static func default_dir_abs(res_dir: String) -> String:
	var d := res_dir.strip_edges()
	if d.is_empty():
		d = DIR_ROOT
	if not d.begins_with("res://") and not d.begins_with("user://"):
		return d                                  # 已经是绝对路径/相对路径 → 原样用
	var abs := ProjectSettings.globalize_path(d)
	if d.begins_with("res://") and not DirAccess.dir_exists_absolute(abs):
		abs = ProjectSettings.globalize_path(DIR_ROOT)
	return abs


## 绝对磁盘路径 → `res://` 相对路径。**不在项目内则返回 ""**（调用方据此拒绝写入）。
static func to_res_path(abs_path: String) -> String:
	var p := abs_path.strip_edges()
	if p.is_empty():
		return ""
	if p.begins_with("res://") or p.begins_with("user://"):
		return p.simplify_path()                  # 已经是资源路径，直接用
	var loc := ProjectSettings.localize_path(p)
	if loc.begins_with("res://"):
		return loc.simplify_path()
	# ★ 兜底：Windows 下盘符大小写 / 反斜杠可能让 localize_path 匹配失败 → 自己按不区分大小写比一次
	var root := ProjectSettings.globalize_path(DIR_ROOT).replace("\\", "/")
	var norm := p.replace("\\", "/")
	if root.ends_with("/"):
		root = root.substr(0, root.length() - 1)
	if norm.to_lower().begins_with(root.to_lower() + "/"):
		return ("res://" + norm.substr(root.length() + 1)).simplify_path()
	return ""


## 把选中的绝对路径写进输入框。
## ★ 分三种情况（批次 78）：
##   ① 已在项目内 → 转成 `res://…`（老行为，走 Godot 导入产物）
##   ② 项目外、但是**图片** → **自动复制进用户素材目录** `%文档%/HelloNyxel/Textures/`，
##      回填该副本的绝对路径。运行期直读，**不需要导入、不需要重启**。
##      这条是「玩家自定义贴图」能落地的关键：以前一律拒绝，玩家只能手动拷进项目再重启。
##   ③ 其它项目外文件 → 仍拒绝并提示（避免把任意路径写进贴图字段）。
## 返回是否写入。
static func apply_abs_path(target: LineEdit, abs_path: String) -> bool:
	if not is_instance_valid(target):
		return false
	var p := str(abs_path).strip_edges()
	if p.is_empty():
		return false
	# 已经是资源路径 → 原样使用
	if p.begins_with("res://") or p.begins_with("user://"):
		target.text = p.simplify_path()
		target.caret_column = target.text.length()
		return true
	var rp := to_res_path(p)
	if not rp.is_empty():
		target.text = rp
		target.caret_column = rp.length()
		return true
	# ② 项目外的图片 → 收进用户素材目录
	if _is_image_file(p) and SaveManager != null:
		var copied: String = SaveManager.import_user_texture(p)
		if not copied.is_empty():
			target.text = copied
			target.caret_column = copied.length()
			notify_msg("已复制到用户素材目录并启用：%s" % copied)
			return true
	# ③ 其它 → 拒绝
	notify_msg("只能选择项目目录（res://）内的文件或图片；本次已忽略：%s" % p.get_file())
	return false


## 是否图片文件（按扩展名判定；决定能否走「收进用户素材目录」这条路）
static func _is_image_file(p: String) -> bool:
	var ext := p.get_extension().to_lower()
	return ext in ["png", "jpg", "jpeg", "webp", "bmp", "tga", "svg", "dds", "ktx", "exr", "hdr"]


static func _filters_for(opts: Dictionary) -> PackedStringArray:
	var exts := String(opts.get("exts", ANY_EXTS))
	var label := String(opts.get("label", "文件"))
	var out: PackedStringArray = PackedStringArray()
	if not exts.is_empty() and exts != ANY_EXTS:
		out.append("%s ; %s" % [exts, label])
	out.append("*.* ; 全部文件")
	return out


static func notify_msg(msg: String) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		var nm: Node = tree.root.get_node_or_null("NotificationManager")
		if nm != null and nm.has_method("show"):
			nm.call("show", msg)
			return
	push_warning("[UIPathPicker] " + msg)
