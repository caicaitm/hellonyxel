# system_const.gd
# 自动加载单例：系统常量注册表（SystemConst）。
#
# 用途：把「设备相关数值」以**具名常量**暴露给全局，供任何地方快速调用。
#   例如积木的宽 / 高可以直接写常量名（如 "icon_size"）而不是写死的数值 ——
#   序列化时存的是**常量名**，运行时才解析成当前设备的实际像素值，
#   于是同一份类型定义在不同设备上得到不同（但都合适）的实际尺寸。
#
# 数据源：%Documents%/HelloNyxel/Temp/sysinfo.json 的 "consts" 段
#   —— 该文件由 SysInfo.exe（addons/hellonyxel_sysinfo/SysInfo.cs）每次采集**整份重写**，
#      so 常量必须在 EXE 侧输出（Godot 侧写入会被下次采集覆盖）。
#   兼容：旧 EXE 写出的文件没有 "consts" 段 -> 回退读原始段（desktop_icons / taskbar / screen）。
#
# 求值口径：**每次现读文件**（不缓存）—— EXE 复写后下一次读取即拿到新值，无需广播。
extends Node

const SYSINFO_SUBDIR := "HelloNyxel/Temp/sysinfo.json"

# 常量注册表：名 -> {
#   "path": ["consts", "<键>"]          新文件（首选）
#   "alt":  [<段>, <键>, ...]           旧文件回退路径（consts 段缺失时）
#   "fallback": 数值                     文件缺失 / 键全缺时的代码兜底
#   "desc": 说明（供面板 / 控制台提示）
# }
const REGISTRY: Dictionary = {
	"icon_size": {
		"path": ["consts", "icon_size"],
		"alt": ["desktop_icons", "icon_size_px"],
		"fallback": 48.0,
		"desc": "桌面图标尺寸（像素）",
	},
	"icon_cell_spacing": {
		"path": ["consts", "icon_cell_spacing"],
		"alt": ["desktop_icons", "icon_cell_spacing"],
		"fallback": 96.0,
		"desc": "桌面图标网格间距（像素）",
	},
	"taskbar_height": {
		"path": ["consts", "taskbar_height"],
		"alt": ["taskbar", "height_px"],
		"fallback": 0.0,
		"desc": "任务栏厚度（像素）",
	},
	"screen_width": {
		"path": ["consts", "screen_width"],
		"alt": ["screen", "primary_resolution", "width"],
		"fallback": 1920.0,
		"desc": "主显示器宽度（像素）",
	},
	"screen_height": {
		"path": ["consts", "screen_height"],
		"alt": ["screen", "primary_resolution", "height"],
		"fallback": 1080.0,
		"desc": "主显示器高度（像素）",
	},
	"system_dpi": {
		"path": ["consts", "system_dpi"],
		"alt": ["screen", "system_dpi"],
		"fallback": 96.0,
		"desc": "系统 DPI（96 = 100%）",
	},
}


## sysinfo.json 的绝对路径（%Documents% 可能被 OneDrive / 系统重定向，必须问系统）
func sysinfo_path() -> String:
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs.is_empty():
		docs = OS.get_environment("USERPROFILE")
	return docs.path_join(SYSINFO_SUBDIR)


## 现读 sysinfo.json（失败返回空字典）
func read_sysinfo() -> Dictionary:
	var p := sysinfo_path()
	if p.is_empty() or not FileAccess.file_exists(p):
		return {}
	var txt := FileAccess.get_file_as_string(p)
	if txt.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(txt)
	if parsed is Dictionary:
		return parsed
	return {}


## 常量名是否已注册
func has(name: String) -> bool:
	return REGISTRY.has(name)


## 取常量的当前值（现读文件；缺失走回退路径，再缺走代码兜底）
func get_value(name: String) -> float:
	var entry: Variant = REGISTRY.get(name, null)
	if not (entry is Dictionary):
		push_warning("SystemConst: 未注册的常量名 '%s'" % name)
		return 0.0
	var e: Dictionary = entry
	var root := read_sysinfo()
	var v: Variant = _lookup(root, e.get("path", []))
	if v == null:
		v = _lookup(root, e.get("alt", []))
	if v == null:
		return float(e.get("fallback", 0.0))
	if v is String:
		return float(v)
	return float(v)


## 把「数值 或 常量名」统一解析成数值。
##   · 传 float / int -> 原样返回（存量数值不受影响）
##   · 传已注册常量名（如 "icon_size"）-> 按当前设备解析
##   · 传数字文本（如 "120"）-> 按数字解析
##   · 传未注册的非数字文本 -> 告警并返回 0.0（由调用方 min 保护决定最终值）
func resolve(v: Variant) -> float:
	if v is String:
		var s: String = str(v).strip_edges()
		if REGISTRY.has(s):
			return get_value(s)
		if s.is_valid_float():
			return float(s)
		if not s.is_empty():
			push_warning("SystemConst: '%s' 既不是已注册常量名，也不是数字" % s)
		return 0.0
	return float(v)


## 全部已注册常量名（供面板下拉 / 控制台提示）
func available() -> PackedStringArray:
	var out: PackedStringArray = []
	for k in REGISTRY.keys():
		out.append(str(k))
	return out


## 「名 = 当前值（说明）」的一行摘要（面板 / 控制台展示用）
func describe(name: String) -> String:
	if not REGISTRY.has(name):
		return "%s = <未注册>" % name
	var e: Dictionary = REGISTRY[name]
	return "%s = %s（%s）" % [name, str(get_value(name)), str(e.get("desc", ""))]


# 沿 path（如 ["screen","primary_resolution","width"]）逐层深入；任一层缺失返回 null
func _lookup(root: Dictionary, path) -> Variant:
	var cur: Variant = root
	for k in path:
		if not (cur is Dictionary):
			return null
		var d: Dictionary = cur
		if not d.has(k):
			return null
		cur = d[k]
	return cur
