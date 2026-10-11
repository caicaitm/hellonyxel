# autoload/save_manager.gd
# 存档管理器（autoload 名：SaveManager）
#
# 职责：
#   - 存档目录 %文档%/HelloNyxel/Saves/<存档名>/（与 Temp 同父目录）
#   - 存档分为两种类型：desktop（桌面）/ world（世界）。世界系统尚未开发，
#     故 world 存档暂只记录元数据 + Temp 文件，积木列表为空（预留）。
#   - 每次存档 = 一个独立文件夹，命名 = auto_<type>_时间 / <type>_时间
#     （自动存档带 auto_ 前缀；type = desktop / world；自定义名同样自动加前缀）：
#       save.json        —— 元信息 + 积木序列化 + 全局变量快照
#       temp/            —— 存档时 Temp 目录内文件的拷贝（读取时写回 Temp）
#   - 序列化范围：**除 AUTO_GENERATED 标签的积木外**全部积木（字节块=桌面屏障 /
#     图标墙 / 页面边框覆盖等系统派生积木不进存档，读取时由系统运行时重建）。
#   - 自动存档：按类型各设间隔（桌面 5/10/15/20/30/60 分钟；世界 1/2/3/4 小时）。
#     间隔落盘于 settings 目录，重启保留。
#   - 读取后预留「时间反应」钩子（处理时间流逝应发生的状态变化，当前仅占位）。
extends Node

const TYPE_DESKTOP := "desktop"
const TYPE_WORLD := "world"

const SAVE_SUBDIR := "HelloNyxel/Saves"
const TEMP_SUBDIR := "HelloNyxel/Temp"
# 玩家自定义贴图目录（**故意在 res:// 之外** → 不参与 Godot 导入扫描）
const USER_TEX_SUBDIR := "HelloNyxel/Textures"
# 日历系统的备忘录/日记数据（Temp 目录，随存档一起备份/恢复）
const CALENDAR_NOTES_PATH := "HelloNyxel/Temp/calendar_notes.json"
const SETTINGS_PATH := "HelloNyxel/settings/settings.json"
const PERF_BUSY_PATH := "HelloNyxel/settings/perf_busy.json"
const AI_CONFIG_PATH := "HelloNyxel/settings/ai.json"
const WEATHER_CONFIG_PATH := "HelloNyxel/settings/weather.json"
# 「获取设备定位」结果文件（经纬度 + IP 定位，由 get_location.ps1 产出）
const LOCATION_PATH := "HelloNyxel/settings/location.json"
# 「本机天气」结果文件（Windows/MSN 天气 + 历史保留，由 get_local_weather.ps1 产出）
const LOCAL_WEATHER_PATH := "HelloNyxel/settings/local_weather.json"
# 「设备日历」结果文件（Windows 设备日历/邮件日历，由 get_calendar.ps1 产出）
const DEVICE_CALENDAR_PATH := "HelloNyxel/settings/device_calendar.json"
const SAVE_VERSION := 1

# 桌面自动存档间隔可选（分钟）
const DESKTOP_MINUTES_OPTIONS := [5, 10, 15, 20, 30, 60]
# 世界自动存档间隔可选（小时）
const WORLD_HOURS_OPTIONS := [1, 2, 3, 4]

# 自动存档上限（桌面 / 世界各一份）：某类型的**自动存档**数量超过该上限时，
# 把**最旧的**自动存档移入系统回收站（见 _prune_auto_saves）。
# 只对「自动存档」（auto_<type>_… 命名）计数，手动存档不受影响。
# 0 = 不限制。落盘 settings.json 的 auto_limit_desktop / auto_limit_world。
const AUTO_LIMIT_OPTIONS := [3, 5, 10, 20, 50]
const AUTO_LIMIT_UNLIMITED := 0
const AUTO_LIMIT_DEFAULT := 10

# UI 缩放（⚠️实验性内容）：取值区间与默认值，与设置面板的滑条一致。
# 本值即「唯一权威」——各面板所在 CanvasLayer 的缩放由它驱动（见 UIStyle.watch_ui_scale）。
const UI_SCALE_MIN := 0.5
const UI_SCALE_MAX := 2.0
const UI_SCALE_DEFAULT := 1.0

# UI 缩放变化（应用后广播）：承载面板的各 CanvasLayer 据此重新施加缩放。
signal ui_scale_changed(scale: float)

var _ui_scale: float = UI_SCALE_DEFAULT

# ============ 界面主题（批次 55） ============
# 「透明液态玻璃」/「半透明纯色」两套主题 + 纯色主题的「主题色」。
# 本值是**唯一权威**（落 settings.json 的 ui_theme_mode / ui_theme_color）；
# ui/ui_style.gd 只做「读取 + 按模式派生颜色」，不自己存状态。
# ★ 变化后广播 ui_theme_changed：UIPanel 据此重算 frosted/取色，GlassTheme 据此
#   批量重算所有 glass_box 造出的 StyleBox —— 运行时即时生效，无需重启。
const THEME_MODE_GLASS := "glass"
const THEME_MODE_SOLID := "solid"
const THEME_MODE_HOLO := "holo"      # 量子全息（批次 59）：与液态玻璃平行
const THEME_MODE_DEFAULT := THEME_MODE_GLASS
const THEME_COLOR_DEFAULT := "ice"

signal ui_theme_changed(mode: String, color_key: String)

var _ui_theme_mode: String = THEME_MODE_DEFAULT
var _ui_theme_color: String = THEME_COLOR_DEFAULT

# ============ 帧率上限（用户可配） ============
# ★ 为什么需要：本窗口是一张**铺满全屏的逐像素透明覆盖层**，即使桌面完全静止，
#   引擎每帧仍要整屏重绘 + 交给 DWM 重新合成。实测（165Hz 屏、垂直同步开启）
#   默认会跑满 165 FPS → godot 进程吃掉约 0.9~1.4 核、GPU 8~11%、笔记本风扇明显起转。
#   限帧后同一场景实测降到 0.17~0.22 核（--max-fps 15 / 30）。
# 取值：MAX_FPS_UNLIMITED(0) = 不限制；其余夹到 >= MAX_FPS_MIN。
#   ★ 下限 15 而不是 1：再低会让拖拽/面板开关出现肉眼可见的顿感。
# 本值即「唯一权威」（落 settings.json 的 max_fps），由 autoload/FrameLimiter 施加到 Engine.max_fps。
const MAX_FPS_MIN := 15
const MAX_FPS_UNLIMITED := 0
const MAX_FPS_DEFAULT := 60
# 设置页下拉的可选项（0 会显示成「不限制」）
const MAX_FPS_OPTIONS := [15, 30, 45, 60, 90, 120, 0]

# 帧率上限变化（应用后广播）
signal max_fps_changed(fps: int)

var _max_fps: int = MAX_FPS_DEFAULT

# 默认间隔（分钟）：桌面默认 10 分钟，世界默认 1 小时
var _desktop_interval_min: int = 10
var _world_interval_hour: int = 1

# 自动存档数量上限（0 = 不限制；落 settings.json，重启保留）
var _auto_limit_desktop: int = AUTO_LIMIT_DEFAULT
var _auto_limit_world: int = AUTO_LIMIT_DEFAULT

# 退出游戏时自动存档开关（默认关；设置面板可勾选，落盘保留）
var _quit_auto_save: bool = false

# 自动载入存档开关（默认关；设置面板可勾选，落盘保留）：启动时自动载入最新存档
var _auto_load_save: bool = false

# 日历「周起始」开关（默认 true = 周一在前；false = 周日在前，应对文化差异）。落盘 settings.json。
var _calendar_week_starts_monday: bool = true

# 计时累积（秒）
var _desktop_accum := 0.0
var _world_accum := 0.0

var _saves_dir: String = ""
var _temp_dir: String = ""
var _user_tex_dir: String = ""
var _settings_path: String = ""
var _perf_busy_path: String = ""
var _ai_config_path: String = ""
var _weather_config_path: String = ""
var _location_path: String = ""
var _local_weather_path: String = ""
var _device_calendar_path: String = ""
var _calendar_notes_path: String = ""
var _app_settings: Dictionary = {}   # settings.json 全量（与具体存档无关，所有存档通用）
var _settings_loaded: bool = false   # settings.json 是否已读过（惰性加载用，见 _ensure_settings_loaded）


func _ready() -> void:
	_resolve_paths()
	_ensure_dirs()
	_load_app_settings()
	print("[SaveManager] 就绪 存档目录=%s 当前间隔=桌面 %d 分钟 / 世界 %d 小时"
		% [_saves_dir, _desktop_interval_min, _world_interval_hour])
	print("[SaveManager] 自动存档上限=桌面 %d / 世界 %d（0=不限制）"
		% [_auto_limit_desktop, _auto_limit_world])


## 惰性确保 settings.json 已加载。
## ★ 为什么需要：本 autoload 在 project.godot 里排在 NotificationManager **之后**，
##   而那边在 _ready() 里就要按 UI 缩放给承载层设 scale → 此时本脚本的 _ready() 还没跑，
##   `get_ui_scale()` 会读到默认值 1.0（设置存的是别的值 → 启动时通知层缩放错档）。
##   所以凡是「读设置」的入口都先过这里（幂等，读过即空操作）。
func _ensure_settings_loaded() -> void:
	if _settings_loaded:
		return
	_resolve_paths()
	_ensure_dirs()
	_load_app_settings()


func _process(delta: float) -> void:
	_desktop_accum += delta
	if _desktop_interval_min > 0 and _desktop_accum >= _desktop_interval_min * 60.0:
		_desktop_accum = 0.0
		auto_save(TYPE_DESKTOP)
	_world_accum += delta
	if _world_interval_hour > 0 and _world_accum >= _world_interval_hour * 3600.0:
		_world_accum = 0.0
		auto_save(TYPE_WORLD)


# ============ 路径与目录 ============

## 惰性确保「路径已解析 + 目录已建好」。
## 为什么需要：`_ready()` 之前（例如 `--script` 探针、或被外部提前调用）拿到的路径是空串，
## 而 settings 目录一旦不存在，FileAccess.open(WRITE) 会直接失败 → 设置静默丢失。
## 本函数幂等：已就绪时是空操作。
func _ensure_ready() -> void:
	if _settings_path.is_empty():
		_resolve_paths()
		_ensure_dirs()


func _resolve_paths() -> void:
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs.is_empty():
		docs = OS.get_environment("USERPROFILE")
	_saves_dir = docs.path_join(SAVE_SUBDIR)
	_temp_dir = docs.path_join(TEMP_SUBDIR)
	_settings_path = docs.path_join(SETTINGS_PATH)
	_perf_busy_path = docs.path_join(PERF_BUSY_PATH)
	_ai_config_path = docs.path_join(AI_CONFIG_PATH)
	_weather_config_path = docs.path_join(WEATHER_CONFIG_PATH)
	_location_path = docs.path_join(LOCATION_PATH)
	_local_weather_path = docs.path_join(LOCAL_WEATHER_PATH)
	_device_calendar_path = docs.path_join(DEVICE_CALENDAR_PATH)
	_calendar_notes_path = docs.path_join(CALENDAR_NOTES_PATH)
	_user_tex_dir = docs.path_join(USER_TEX_SUBDIR)


func _ensure_dirs() -> void:
	if not DirAccess.dir_exists_absolute(_saves_dir):
		DirAccess.make_dir_recursive_absolute(_saves_dir)
	if not DirAccess.dir_exists_absolute(_temp_dir):
		DirAccess.make_dir_recursive_absolute(_temp_dir)
	# ★ 用户素材目录：玩家自定义贴图丢这里 → 运行期直读，**不需要 Godot 导入**。
	if not DirAccess.dir_exists_absolute(_user_tex_dir):
		DirAccess.make_dir_recursive_absolute(_user_tex_dir)
	var sd := _settings_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(sd):
		DirAccess.make_dir_recursive_absolute(sd)


## 用户素材目录（%文档%/HelloNyxel/Textures/）—— 玩家自定义贴图放这里。
## ★ 故意**放在 res:// 之外**：这样 Godot 的导入扫描完全看不到它，
##   玩家加多少张图都不会产生 .import / .ctex，也就不会拖慢打开项目。
##   运行时由 TextureCache 通道② 直接读文件（Image.load），**加了就能用、无需重启**。
func get_user_textures_dir() -> String:
	_ensure_ready()
	return _user_tex_dir


## 把一张外部图片复制进用户素材目录，返回副本的绝对路径（失败返回 ""）。
## 供「贴图路径」的文件选择器使用：玩家在项目外选图 → 自动收进素材目录 → 直接可用。
## 重名时自动加 _2 / _3 … 后缀，不覆盖已有文件。
func import_user_texture(abs_path: String) -> String:
	_ensure_ready()
	var src := str(abs_path).strip_edges()
	if src.is_empty() or not FileAccess.file_exists(src):
		return ""
	var dir := _user_tex_dir
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var base := src.get_file().get_basename()
	var ext := src.get_extension()
	var final_name := "%s.%s" % [base, ext]
	var n := 2
	while FileAccess.file_exists(dir.path_join(final_name)):
		final_name = "%s_%d.%s" % [base, n, ext]
		n += 1
	var dst := dir.path_join(final_name)
	if DirAccess.copy_absolute(src, dst) != OK:
		push_warning("[SaveManager] 复制到用户素材目录失败：%s → %s" % [src, dst])
		return ""
	return dst


func get_saves_dir() -> String:
	_ensure_ready()
	return _saves_dir


func get_temp_dir() -> String:
	_ensure_ready()
	return _temp_dir


## 全局设置目录（%文档%/HelloNyxel/settings/）—— settings.json / perf_busy.json /
## ai.json / weather.json 都落在这里，便于玩家直接查看与备份。
func get_settings_dir() -> String:
	_ensure_ready()
	return _settings_path.get_base_dir()


## 「接入人工智能」配置文件的绝对路径（ai.json）
func get_ai_config_path() -> String:
	_ensure_ready()
	return _ai_config_path


## 「配置天气」配置文件的绝对路径（weather.json）
func get_weather_config_path() -> String:
	_ensure_ready()
	return _weather_config_path


## 「设备定位」结果文件的绝对路径（location.json）
func get_location_path() -> String:
	_ensure_ready()
	return _location_path


## 「本机天气」结果文件的绝对路径（local_weather.json）——由 get_local_weather.ps1 产出。
func get_local_weather_path() -> String:
	_ensure_ready()
	return _local_weather_path


## 「设备日历」结果文件的绝对路径（device_calendar.json）——由 get_calendar.ps1 产出。
func get_device_calendar_path() -> String:
	_ensure_ready()
	return _device_calendar_path


## 「日历备忘录/日记」数据文件的绝对路径（calendar_notes.json，位于 Temp 目录）。
func get_calendar_notes_path() -> String:
	_ensure_ready()
	return _calendar_notes_path


# ============ 对外存档 API ============

## 手动存档。type 见 TYPE_*。custom_name 空 → 用「前缀 + 时间」默认名。
## 命名规则：自动存档 = auto_<type>_…，手动存档 = <type>_…（如 desktop_2026_09_27_20_00_00）；
## 自定义名也会自动加前缀（已带前缀则不重复加），便于按名字一眼区分自动/手动与桌面/世界。
## 返回 Dictionary：{ ok, name, type, message }
func save(type: String, custom_name: String = "", auto: bool = false) -> Dictionary:
	_ensure_ready()
	if type != TYPE_DESKTOP and type != TYPE_WORLD:
		return { "ok": false, "message": "未知存档类型: %s" % type }
	var prefix := _name_prefix(type, auto)
	var body := _sanitize_name(custom_name)
	if body.begins_with("auto_" + type + "_") or body.begins_with(type + "_"):
		# 已带同类前缀（如用户手输或整名复用）→ 不重复加
		prefix = ""
	var final_name := _ensure_unique_name(prefix + (body if not body.is_empty() else _default_save_name()))
	var folder := _saves_dir.path_join(final_name)
	if not DirAccess.dir_exists_absolute(folder):
		DirAccess.make_dir_recursive_absolute(folder)

	var data := _build_save_data(type, final_name)
	var ok := _write_json(folder.path_join("save.json"), data)
	if not ok:
		return { "ok": false, "type": type, "name": final_name, "message": "写入 save.json 失败" }
	_backup_temp_to(folder.path_join("temp"))
	print("[SaveManager] 已存档 [%s] %s （桌面积木 %d 块）"
		% [type, final_name, (data["blocks"] as Array).size()])
	# ★ 自动存档：落盘后立刻按上限清理（把最旧的自动存档移入系统回收站）。
	#   放在 save() 而不是 auto_save()，是为了让**所有**自动存档入口
	#   （间隔触发 / 退出存档 / 外部直接调 save(type,"",true)）都统一受上限约束。
	if auto:
		_prune_auto_saves(type)
	return { "ok": true, "type": type, "name": final_name, "message": "ok" }


## 自动存档：与手动存档同一路径，但命名带 auto_ 前缀（auto_desktop_… / auto_world_…）。
func auto_save(type: String) -> Dictionary:
	print("[SaveManager] 自动存档 [%s]" % type)
	return save(type, "", true)


## 列出全部存档（升序）。返回 Array[Dictionary]：{ name, type, created_at, block_count }
func list_saves() -> Array:
	_ensure_ready()
	var out: Array = []
	if not DirAccess.dir_exists_absolute(_saves_dir):
		return out
	var dir := DirAccess.open(_saves_dir)
	if dir == null:
		return out
	for entry in dir.get_directories():
		var meta := _read_meta(entry)
		if meta.is_empty():
			continue
		out.append(meta)
	out.sort_custom(func(a, b): return int(a.get("created_at", 0)) > int(b.get("created_at", 0)))
	return out


## 读取存档。返回 Dictionary：{ ok, type, name, applied, message }
func load_save(name: String) -> Dictionary:
	_ensure_ready()
	var folder := _saves_dir.path_join(name)
	if not DirAccess.dir_exists_absolute(folder):
		return { "ok": false, "name": name, "message": "存档文件夹不存在" }
	var data := _read_json(folder.path_join("save.json"))
	if data.is_empty():
		return { "ok": false, "name": name, "message": "save.json 缺失或解析失败" }
	var type: String = str(data.get("type", TYPE_DESKTOP))
	# 1) 写回 Temp（把存档内的 temp 文件恢复到 Temp 目录）
	_restore_temp_from(folder.path_join("temp"))
	# 1b) 状态文件自检：读档把存档内的 Temp 覆盖回来后，若某个状态 JSON 残缺
	#     （存档本身坏 / 老存档没存过该文件 / 被截断）→ 立即按默认值补建，
	#     保证后续步骤读到的都是完整数据（玩家画像 / 荧惑日常状态 / 日历笔记 / 设备 / 背包…）。
	ensure_temp_files()
	# 2) 重建积木
	var blocks_res := _apply_saved_blocks(data.get("blocks", []))
	# 3) 恢复全局变量
	_apply_saved_vars(data.get("vars", {}))
	# 4) 重新摆放/确认系统积木（屏障等由运行时重建；此处只做位置对齐）
	_after_load_refresh_environment()
	# 5) 预留：时间反应步骤（时间流逝应发生的状态变化 / 到点触发事件，当前仅占位）
	_time_reaction(data)
	print("[SaveManager] 已读档 [%s] %s（重建积木 %d 块）" % [type, name, blocks_res])
	return { "ok": true, "type": type, "name": name, "applied": blocks_res, "message": "ok" }


## 删除存档：移入系统回收站（而非硬删除），误删可恢复。
## 返回是否成功（true 表示文件夹已不在存档目录内）。
##
## ★★ 为什么不用 OS.move_to_trash()：本项目运行环境里该 API **会直接卡死**
##   （headless 与带窗口实测均无输出、进程残留、需 taskkill），故不可用；
##   统一改走 _move_to_recycle_bin()（PowerShell + .NET 回收站 API，实测可行）。
func delete_save(name: String) -> bool:
	_ensure_ready()
	var folder := _saves_dir.path_join(name)
	if not DirAccess.dir_exists_absolute(folder):
		return false
	var moved := _move_to_recycle_bin([folder])
	if moved <= 0:
		push_warning("[SaveManager] 移入回收站失败: %s" % folder)
		return false
	print("[SaveManager] 已移入回收站 %s" % name)
	return true


# ============ 自动存档上限 / 回收站 ============

## 规范化自动存档上限：0（不限制）原样保留；负数/垃圾值 → 默认值；其余至少 1。
func _normalize_auto_limit(v: int) -> int:
	if v == AUTO_LIMIT_UNLIMITED:
		return AUTO_LIMIT_UNLIMITED
	if v < 0:
		return AUTO_LIMIT_DEFAULT
	return maxi(1, v)


## 桌面自动存档上限（0 = 不限制）——设置页可改，落盘 settings.json，重启保留。
func get_auto_limit_desktop() -> int:
	_ensure_settings_loaded()
	return _auto_limit_desktop


## 世界自动存档上限（0 = 不限制）
func get_auto_limit_world() -> int:
	_ensure_settings_loaded()
	return _auto_limit_world


func set_auto_limit_desktop(n: int) -> void:
	_auto_limit_desktop = _normalize_auto_limit(int(n))
	save_app_settings({ "auto_limit_desktop": _auto_limit_desktop })


func set_auto_limit_world(n: int) -> void:
	_auto_limit_world = _normalize_auto_limit(int(n))
	save_app_settings({ "auto_limit_world": _auto_limit_world })


## 列出某类型的**自动存档**名（按时间升序 → 最旧的在前）。
## ★ 用目录名排序代替读 save.json（省 IO）：自动存档名 = auto_<type>_yyyy_mm_dd_hh_mm_ss，
##   定宽数字段 → 字典序即时间序（同秒重名会加 _2/_3 后缀，'_'(95) 大于数字(48~57)
##   → 后缀项仍排在同秒项之后，顺序依旧正确）。
func _list_auto_save_names(type: String) -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(_saves_dir):
		return out
	var dir := DirAccess.open(_saves_dir)
	if dir == null:
		return out
	var prefix := "auto_" + type + "_"
	for entry in dir.get_directories():
		var n := str(entry)
		if n.begins_with(prefix):
			out.append(n)
	out.sort()
	return out


## 收集某类型中**超出上限**（即最旧的若干份）的自动存档绝对路径。0 = 不限制 → 空数组。
func _collect_auto_save_victims(type: String) -> Array:
	_ensure_ready()
	var limit := _auto_limit_desktop if type == TYPE_DESKTOP else _auto_limit_world
	if limit <= 0:
		return []
	var names := _list_auto_save_names(type)
	var over: int = names.size() - limit
	if over <= 0:
		return []
	var out: Array = []
	for i in over:
		out.append(_saves_dir.path_join(str(names[i])))
	return out


## 自动存档上限清理（单类型）：超出上限时把**最旧的**若干份移入回收站。
## 返回实际移入回收站的数量。limit <= 0（不限制）时不做任何事。
func _prune_auto_saves(type: String) -> int:
	var victims := _collect_auto_save_victims(type)
	if victims.is_empty():
		return 0
	var moved := _move_to_recycle_bin(victims)
	print("[SaveManager] 自动存档上限清理：%s 移入回收站 %d 份" % [type, moved])
	return moved


## 按当前上限一次性清理**两个类型**（合成一次 PowerShell 调用批量移入回收站）。
## 用途：设置页「确定修改」把上限调小后立即生效 —— 否则要等到下一次自动存档才会清理，
## 而"数量已超过新阈值"这件事在按下确定的当下就已经成立了。
func prune_auto_saves_all() -> int:
	_ensure_ready()
	var victims: Array = []
	victims.append_array(_collect_auto_save_victims(TYPE_DESKTOP))
	victims.append_array(_collect_auto_save_victims(TYPE_WORLD))
	if victims.is_empty():
		return 0
	var moved := _move_to_recycle_bin(victims)
	print("[SaveManager] 自动存档上限清理：共移入回收站 %d 份" % moved)
	return moved


## 把若干文件/目录移入**系统回收站**（一次 PowerShell 调用批量处理，避免逐项起宿主）。
## 返回**实际从原位置消失**的条目数（0 = 全部失败或没有有效条目）。
##
## ★★ 实现选型（均来自本机实测）：
##   ① `OS.move_to_trash()` **会卡死**（headless / 带窗口都无输出、进程残留）→ 弃用；
##   ② `Shell.Application` COM 被安全策略拦截（Command blocked for security）→ 弃用；
##   ③ 可行方案 = PowerShell 调 .NET：`Add-Type -AssemblyName Microsoft.VisualBasic`
##      再用 FileSystem.DeleteDirectory / DeleteFile 的 SendToRecycleBin 重载。
##      实测条目确实落入 `<盘>:\$RECYCLE.BIN\<SID>\`（$R / $I 文件配对），
##      正斜杠与反斜杠都能成功，批量 3 项约 1.26s。
## ★ 该 .NET API 即使**已经成功**也常抛 MethodInvocationException（错误对话框日志），
##   所以**不能**以"是否抛异常 / 进程退出码"判断成败 —— 脚本内 try/catch 吞掉异常，
##   并一律以「回读原路径是否还存在」作为唯一判据。
func _move_to_recycle_bin(paths: Array) -> int:
	_ensure_ready()
	var targets: Array = []
	for p in paths:
		var s := str(p)
		if s.is_empty():
			continue
		if FileAccess.file_exists(s) or DirAccess.dir_exists_absolute(s):
			targets.append(s)
	if targets.is_empty():
		return 0
	# 组装 PS 数组字面量：统一用正斜杠、单引号转义（PS 单引号串里 '' 表示一个 '）
	var arr_text := ""
	for i in targets.size():
		if i > 0:
			arr_text += ", "
		arr_text += "'" + str(targets[i]).replace("\\", "/").replace("'", "''") + "'"
	var loop_head := "foreach ($p in @(%s)) { " % arr_text
	var call_dir := "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p,[Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,[Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)"
	var call_file := "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p,[Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,[Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)"
	var script := (
		"Add-Type -AssemblyName Microsoft.VisualBasic; $ErrorActionPreference='SilentlyContinue'; "
		+ loop_head
		+ "try { if (Test-Path -LiteralPath $p) { "
		+ "if ((Get-Item -LiteralPath $p -Force).PSIsContainer) { " + call_dir
		+ " } else { " + call_file + " } } } catch {} }"
	)
	var out: Array = []
	OS.execute("powershell.exe", PackedStringArray([
		"-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script]), out, false)
	# 唯一判据：原路径是否已消失
	var moved := 0
	for p in targets:
		var s := str(p)
		if not FileAccess.file_exists(s) and not DirAccess.dir_exists_absolute(s):
			moved += 1
	return moved


# ============ 序列化 ============

func _build_save_data(type: String, name: String) -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"type": type,
		"name": name,
		"created_at": int(Time.get_unix_time_from_system()),
		"vars": GlobalVars.dump() if GlobalVars != null else {},
		"blocks": _collect_blocks() if type == TYPE_DESKTOP else [],
		"world": {},   # 预留：世界系统数据（独立存档系统）
	}


## 收集**可保存**积木（排除 AUTO_GENERATED 标签的系统积木）→ JSON 兼容数组
func _collect_blocks() -> Array:
	var out: Array = []
	if get_tree() == null:
		return out
	for b in get_tree().get_nodes_in_group("block"):
		# ★ 先 is_instance_valid 再 `is Block`（见 portal_manager）：对已释放实例执行 `is` 会报错。
		if not is_instance_valid(b) or not (b is Block):
			continue
		if BlockTags.AUTO_GENERATED in b.tags:
			continue
		var prop := BlockProperty.from_block(b)
		out.append(_to_json_compatible({
			"id": int(b.id),
			"string_id": str(b.string_id),
			"pos": [float(b.position.x), float(b.position.y)],
			"rot": rad_to_deg(b.rotation),
			"prop": prop,
		}))
	return out


func _apply_saved_blocks(blocks: Array) -> int:
	if get_tree() == null:
		return 0
	# 0) 清掉现有「可保存」积木（不含系统积木），避免与读档重复
	_remove_existing_user_blocks()
	if blocks.is_empty():
		return 0
	var parent := get_tree().current_scene
	if parent == null:
		return 0
	var created: Array = []
	for entry in blocks:
		if not (entry is Dictionary):
			continue
		var b := Block.new()
		var prop: Dictionary = (entry as Dictionary).get("prop", {})
		BlockProperty.apply_to_block(b, prop)
		# 数值 ID / 字符串 ID：读档在入树后由 BlockManager 登记
		if (entry as Dictionary).has("id"):
			b.id = int((entry as Dictionary)["id"])
		if (entry as Dictionary).has("string_id") and str((entry as Dictionary)["string_id"]) != "":
			b.string_id = str((entry as Dictionary)["string_id"])
		# 位置 / 旋转
		var pos: Array = (entry as Dictionary).get("pos", [0.0, 0.0])
		b.position = Vector2(float(pos[0]), float(pos[1]))
		b.rotation = deg_to_rad(float((entry as Dictionary).get("rot", 0.0)))
		parent.add_child(b)
		# 入树后重新登记数值 ID 与字符串 ID
		if b.id > 0:
			BlockManager.set_id(b, b.id)
		if b.string_id != "":
			BlockManager.set_string_id(b, b.string_id)
		# 父子锚定：读档的 prop 里已有 parent_id/child_ids（按数值 ID），
		# apply_to_block 入树后已重设（ID 一一对应，读档顺序无关）。
		created.append(b)
	return created.size()


func _remove_existing_user_blocks() -> void:
	if get_tree() == null:
		return
	for b in get_tree().get_nodes_in_group("block"):
		# ★ 先 is_instance_valid 再 `is Block`（见 portal_manager）：对已释放实例执行 `is` 会报错。
		if not is_instance_valid(b) or not (b is Block):
			continue
		if BlockTags.AUTO_GENERATED in b.tags:
			continue
		BlockManager.unregister(b)
		b.queue_free()


func _apply_saved_vars(vars: Dictionary) -> void:
	if GlobalVars == null or typeof(vars) != TYPE_DICTIONARY:
		return
	for k in vars:
		GlobalVars.set_var(str(k), vars[k])


## 读档后让系统积木（屏障等）按当前桌面矩形重新摆放。
## 图标边界 / 程序页边框由实时枚举线程持续维护，无需手动重建。
func _after_load_refresh_environment() -> void:
	var sc := get_tree().current_scene
	if sc != null and sc.has_method("refresh_barriers"):
		sc.refresh_barriers()


## 预留：时间反应步骤。
## 因游戏关联显示（如农作物 12h 后成熟），存档保存的是当时状态；
## 读档后应处理「经过这段时间后面应呈现的状态」及到点触发的事件。
## 目前接入：时间轴系统——重置载入缓冲并让已到期的计划事件按规则触发。
func _time_reaction(_data: Dictionary) -> void:
	if TimelineManager != null:
		TimelineManager.on_save_loaded()
	print("[SaveManager] 时间反应：时间轴系统已重放（其它时间流逝处理预留）")


# ============ 全局设置（与具体存档无关，存于 settings 目录，所有存档通用） ============
#
# 用户需求：设置页 + 判断忙闲页的设置，存于 %文档%/HelloNyxel/settings/，
# 以 JSON 分别保存，且无论读取哪个存档，这些全局设置都一致（不进 save.json）。

## 把设置页内容合并写回 settings.json（保留其它键）。
## patch 可含：volumes / ui_scale / ui_theme_mode / ui_theme_color / max_fps / lang / lang2 / desktop_minutes / world_hours / auto_limit_desktop / auto_limit_world / timeline_max / quit_auto_save / auto_load_save
func save_app_settings(patch: Dictionary) -> void:
	_ensure_ready()
	for k in patch:
		_app_settings[k] = patch[k]
	# 同步内部间隔变量（供 _process 自动存档使用）
	if patch.has("desktop_minutes"):
		_desktop_interval_min = maxi(0, int(patch["desktop_minutes"]))
	if patch.has("world_hours"):
		_world_interval_hour = maxi(0, int(patch["world_hours"]))
	# 同步自动存档上限（供 save() 落盘后的清理使用）
	if patch.has("auto_limit_desktop"):
		_auto_limit_desktop = _normalize_auto_limit(int(patch["auto_limit_desktop"]))
	if patch.has("auto_limit_world"):
		_auto_limit_world = _normalize_auto_limit(int(patch["auto_limit_world"]))
	if patch.has("quit_auto_save"):
		_quit_auto_save = bool(patch["quit_auto_save"])
	if patch.has("auto_load_save"):
		_auto_load_save = bool(patch["auto_load_save"])
	if patch.has("calendar_week_starts_monday"):
		_calendar_week_starts_monday = bool(patch["calendar_week_starts_monday"])
	_write_json(_settings_path, _app_settings)


func get_app_settings() -> Dictionary:
	return _app_settings


## 设置页自动存档间隔（分钟）。0 = 关闭。写入 settings.json 并保留其它设置键。
func set_desktop_interval_minutes(m: int) -> void:
	_desktop_interval_min = maxi(0, m)
	_desktop_accum = 0.0
	save_app_settings({ "desktop_minutes": _desktop_interval_min })


func set_world_interval_hours(h: int) -> void:
	_world_interval_hour = maxi(0, h)
	_world_accum = 0.0
	save_app_settings({ "world_hours": _world_interval_hour })


func get_desktop_interval_minutes() -> int:
	return _desktop_interval_min


func get_world_interval_hours() -> int:
	return _world_interval_hour


## 退出游戏时自动存档开关
func set_quit_auto_save(on: bool) -> void:
	_quit_auto_save = on
	save_app_settings({ "quit_auto_save": _quit_auto_save })


func get_quit_auto_save() -> bool:
	return _quit_auto_save


## 自动载入存档开关：开启时游戏启动即自动载入最新存档（按 created_at 倒序的第一条）。
## 落盘 settings.json，重启保留（与具体存档无关，所有存档通用）。
func set_auto_load_save(on: bool) -> void:
	_auto_load_save = on
	save_app_settings({ "auto_load_save": _auto_load_save })


func get_auto_load_save() -> bool:
	return _auto_load_save


## 日历「周起始」开关：true = 周一在前（默认）；false = 周日在前。落盘 settings.json，重启保留。
func set_calendar_week_starts_monday(on: bool) -> void:
	_calendar_week_starts_monday = on
	save_app_settings({ "calendar_week_starts_monday": _calendar_week_starts_monday })


func get_calendar_week_starts_monday() -> bool:
	return _calendar_week_starts_monday


# ============ UI 缩放（⚠️实验性内容） ============

## 当前 UI 缩放（0.5 ~ 2.0，默认 1.0）。承载面板的各 CanvasLayer 的缩放由它驱动。
func get_ui_scale() -> float:
	_ensure_settings_loaded()
	return _ui_scale


## 设置 UI 缩放：夹到合法区间 → （persist 时）落盘 settings.json → 广播
## （各面板所在层当场重新施加缩放）。
## ★ persist=true 时**即使值没变也要落盘**：设置页「松手预览」已经把内存值改成了目标值
##   （persist=false，不写盘），随后按「确定修改」正是要把这个预览值**固化**到文件 ——
##   若这里因为 is_equal_approx 提前 return，文件里会残留预览前的旧倍率
##   （表现为「确定修改后重启，缩放又变回去了」）。
##   值确实没变时仍然不重复广播（信号只表达"显示需要更新"）。
## persist=false 用于设置页的「松手预览」与「未确定就关闭时的还原」——只改内存与显示，不写盘。
func set_ui_scale(s: float, persist: bool = true) -> void:
	var v := clampf(float(s), UI_SCALE_MIN, UI_SCALE_MAX)
	var changed := not is_equal_approx(v, _ui_scale)
	_ui_scale = v
	if persist:
		save_app_settings({ "ui_scale": v })
	if changed:
		ui_scale_changed.emit(v)


# ============ 界面主题（透明液态玻璃 / 半透明纯色 + 主题色） ============
#
# 语义与 set_ui_scale 同款：persist=true 时**即使值没变也落盘**（设置页可能先做过
# 内存预览）；值确实没变则不重复广播（信号只表达"显示需要更新"）。
# persist=false 用于设置页「确定修改」时：patch 已经负责落盘 → 这里只广播运行时更新。

## 当前界面主题模式："glass"（透明液态玻璃）/ "solid"（半透明纯色）/ "holo"（量子全息）。
func get_ui_theme_mode() -> String:
	_ensure_settings_loaded()
	return _ui_theme_mode


## 当前「半透明纯色」主题色键（如 "ice"）；未知值一律当默认处理。
func get_ui_theme_color() -> String:
	_ensure_settings_loaded()
	return _ui_theme_color


func set_ui_theme_mode(m: String, persist: bool = true) -> void:
	var v := _normalize_theme_mode(str(m))
	var changed := v != _ui_theme_mode
	_ui_theme_mode = v
	if persist:
		save_app_settings({ "ui_theme_mode": v })
	if changed:
		ui_theme_changed.emit(_ui_theme_mode, _ui_theme_color)


## 合法主题模式规整：glass / solid / holo；其余一律当 glass。
## ★ 新增主题时只改这一处（set / 加载 / 探针都走它）。
func _normalize_theme_mode(m: String) -> String:
	if m == THEME_MODE_SOLID or m == THEME_MODE_HOLO:
		return m
	return THEME_MODE_GLASS


func set_ui_theme_color(key: String, persist: bool = true) -> void:
	var k := str(key)
	var v := k if not k.is_empty() else THEME_COLOR_DEFAULT
	var changed := v != _ui_theme_color
	_ui_theme_color = v
	if persist:
		save_app_settings({ "ui_theme_color": v })
	if changed:
		ui_theme_changed.emit(_ui_theme_mode, _ui_theme_color)


# ============ 帧率上限 ============

## 规范化帧率上限：0（不限制）原样保留；其余夹到 [MAX_FPS_MIN, ∞)。
## 负数 / 垃圾值一律当默认值处理。
func _normalize_max_fps(v: int) -> int:
	if v == MAX_FPS_UNLIMITED:
		return MAX_FPS_UNLIMITED
	if v <= 0:
		return MAX_FPS_DEFAULT
	return maxi(MAX_FPS_MIN, v)


## 当前帧率上限（0 = 不限制，默认 60）。由 autoload/FrameLimiter 施加到 Engine.max_fps。
func get_max_fps() -> int:
	_ensure_settings_loaded()
	return _max_fps


## 设置帧率上限：规范化 → （persist 时）落盘 settings.json → 广播。
## ★ 与 set_ui_scale 同款语义：persist=true 时**即使值没变也要落盘**
##   （设置页可能先做过"内存预览"），值确实没变则不重复广播。
func set_max_fps(v: int, persist: bool = true) -> void:
	var n := _normalize_max_fps(int(v))
	var changed := n != _max_fps
	_max_fps = n
	if persist:
		save_app_settings({ "max_fps": n })
	if changed:
		max_fps_changed.emit(n)


## 判断忙闲页面设置：独立 JSON（perf_busy.json），同样与存档无关。
func save_perf_busy_settings(data: Dictionary) -> void:
	_ensure_ready()
	_write_json(_perf_busy_path, data)


func load_perf_busy_settings() -> Dictionary:
	_ensure_ready()
	return _read_json(_perf_busy_path)


## 「接入人工智能」设置：独立 JSON（ai.json），与存档无关。
## 结构：{ api, prompt, allow_files[], deny_files[] }
func save_ai_config(data: Dictionary) -> void:
	_ensure_ready()
	_write_json(_ai_config_path, data)


func load_ai_config() -> Dictionary:
	_ensure_ready()
	return _read_json(_ai_config_path)


## 「配置天气」设置：独立 JSON（weather.json），与存档无关。
## 结构：{ location, api }
func save_weather_config(data: Dictionary) -> void:
	_ensure_ready()
	_write_json(_weather_config_path, data)


func load_weather_config() -> Dictionary:
	_ensure_ready()
	return _read_json(_weather_config_path)


## 只改 weather.json 里的某些键，**保留其它键**（手动定位 / api 不会被抹掉）。
## 用途：天气面板的「读取本机天气」开关（LocalWeather.set_enabled）——它与面板各自的
## 「整份重写」写入者共用同一个文件，所以必须走这个合并写入口。
func patch_weather_config(patch: Dictionary) -> void:
	_ensure_ready()
	var d := _read_json(_weather_config_path)
	for k in patch:
		d[k] = patch[k]
	_write_json(_weather_config_path, d)


## 「设备定位」结果：独立 JSON（location.json），与存档无关。
## 结构（由 get_location.ps1 写入）：
##   { source, updated_at, device{latitude,longitude,accuracy,available,status,error},
##     ip{address,country,country_code,province,city,district,isp,source},
##     local_ips[], location_text, error }
## location_text = 以 IP 定位为准拼出的「国家/省份/城市」（天气面板的定位栏就填它）。
func save_location_data(data: Dictionary) -> void:
	_ensure_ready()
	_write_json(_location_path, data)


func load_location_data() -> Dictionary:
	_ensure_ready()
	return _read_json(_location_path)


## 启动加载 settings.json：填充内部间隔变量，整份字典供面板读取。
func _load_app_settings() -> void:
	var d := _read_json(_settings_path)
	if typeof(d) == TYPE_DICTIONARY and not d.is_empty():
		_app_settings = d
	if _app_settings.has("desktop_minutes"):
		_desktop_interval_min = maxi(0, int(_app_settings["desktop_minutes"]))
	if _app_settings.has("world_hours"):
		_world_interval_hour = maxi(0, int(_app_settings["world_hours"]))
	# 自动存档上限（0 = 不限制；负数/垃圾值 → 默认值）
	if _app_settings.has("auto_limit_desktop"):
		_auto_limit_desktop = _normalize_auto_limit(int(_app_settings["auto_limit_desktop"]))
	if _app_settings.has("auto_limit_world"):
		_auto_limit_world = _normalize_auto_limit(int(_app_settings["auto_limit_world"]))
	if _app_settings.has("quit_auto_save"):
		_quit_auto_save = bool(_app_settings["quit_auto_save"])
	if _app_settings.has("auto_load_save"):
		_auto_load_save = bool(_app_settings["auto_load_save"])
	if _app_settings.has("calendar_week_starts_monday"):
		_calendar_week_starts_monday = bool(_app_settings["calendar_week_starts_monday"])
	# UI 缩放：非法/越界值夹回合法区间（面板/各 CanvasLayer 在各自 _ready 时读取本值）
	if _app_settings.has("ui_scale"):
		_ui_scale = clampf(float(_app_settings["ui_scale"]), UI_SCALE_MIN, UI_SCALE_MAX)
	# 界面主题：模式只认 glass / solid / holo（其余当 glass）；主题色未知键照收
	#（UIStyle.solid_base_color 查不到会回落到默认冰蓝，故不必在此校验合法键）。
	if _app_settings.has("ui_theme_mode"):
		_ui_theme_mode = _normalize_theme_mode(str(_app_settings["ui_theme_mode"]))
	if _app_settings.has("ui_theme_color"):
		var tk := str(_app_settings["ui_theme_color"])
		_ui_theme_color = tk if not tk.is_empty() else THEME_COLOR_DEFAULT
	# 帧率上限：0 = 不限制（原样保留），其余夹到 >= MAX_FPS_MIN
	if _app_settings.has("max_fps"):
		_max_fps = _normalize_max_fps(int(_app_settings["max_fps"]))
	_settings_loaded = true


# ============ Temp 备份 / 恢复 ============

## 把 Temp 目录下所有文件拷贝到存档的 temp 子目录
func _backup_temp_to(backup_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(backup_dir):
		DirAccess.make_dir_recursive_absolute(backup_dir)
	if not DirAccess.dir_exists_absolute(_temp_dir):
		return
	var src := DirAccess.open(_temp_dir)
	if src == null:
		return
	for f in src.get_files():
		var full_src := _temp_dir.path_join(f)
		var full_dst := backup_dir.path_join(f)
		var bytes := FileAccess.get_file_as_bytes(full_src)
		if bytes.is_empty() and FileAccess.get_open_error() != OK:
			continue
		var w := FileAccess.open(full_dst, FileAccess.WRITE)
		if w != null:
			w.store_buffer(bytes)
			w.close()


## 把存档 temp 子目录内文件恢复到 Temp 目录（覆盖同名）
func _restore_temp_from(backup_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(backup_dir):
		return
	if not DirAccess.dir_exists_absolute(_temp_dir):
		DirAccess.make_dir_recursive_absolute(_temp_dir)
	var src := DirAccess.open(backup_dir)
	if src == null:
		return
	for f in src.get_files():
		var full_src := backup_dir.path_join(f)
		var full_dst := _temp_dir.path_join(f)
		var bytes := FileAccess.get_file_as_bytes(full_src)
		if bytes.is_empty() and FileAccess.get_open_error() != OK:
			continue
		var w := FileAccess.open(full_dst, FileAccess.WRITE)
		if w != null:
			w.store_buffer(bytes)
			w.close()
		# 恢复后清掉进程内的旧内存缓存（如 sysinfo 被覆盖则提示重新读取）
	_after_temp_restored_dirty()


## sysinfo.json 若被恢复成存档时的旧值 → 通知 DesktopShell 重新读取并应用几何。
func _after_temp_restored_dirty() -> void:
	if DesktopShell != null and DesktopShell.has_method("refresh_from_sysinfo"):
		if FileAccess.file_exists(_temp_dir.path_join("sysinfo.json")):
			print("[SaveManager] Temp 已恢复，重新读取 sysinfo")
			DesktopShell.refresh_from_sysinfo()
	# 背包 inventory.json 随 Temp 一起恢复 → 让 Inventory 重新从磁盘载入（面板若开着会自刷新）
	if Inventory != null and Inventory.has_method("load_from_disk"):
		Inventory.load_from_disk()


# ============ Temp 状态文件自检（进入游戏 / 载入存档前） ============

## 判断一个 JSON 文件是否「残缺」（需要重建）：
##   不存在 / 文本为空 / 解析失败或不是对象 / 缺 spec.require_keys 里的键 /
##   spec.dict_keys 里出现的键不是 Dictionary / spec.array_keys 里出现的键不是 Array。
func json_needs_repair(path: String, spec: Dictionary = {}) -> bool:
	if not FileAccess.file_exists(path):
		return true
	var txt := FileAccess.get_file_as_string(path)
	if txt.strip_edges().is_empty():
		return true
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		return true
	var d: Dictionary = parsed
	for k in spec.get("require_keys", []):
		if not d.has(str(k)):
			return true
	for k in spec.get("dict_keys", []):
		if d.has(str(k)) and not (d[str(k)] is Dictionary):
			return true
	for k in spec.get("array_keys", []):
		if d.has(str(k)) and not (d[str(k)] is Array):
			return true
	return false


## ★★ 状态文件自检（「进入游戏前」与「载入存档后」各跑一次）：
##    Temp 目录下的**游戏状态 JSON** 若残缺 → 调各自 owner 的 ensure_file() 按默认值重建。
##    ★ 默认值只有各 owner 自己知道（玩家画像 / 荧惑日常状态 / 日历笔记 / 设备清单 / 背包），
##      故本函数只做**协调**，不把 5 套默认值抄到这里。
##    ★ 明确**不碰**：html_cmd.json（HtmlBridge 临时命令文件，随时可无）、
##      sysinfo.json（SysInfo.exe 外部产出），以及 *.instance.* / *_debug.txt 等非状态文件。
##    返回 { checked: int, repaired: Array[String] }。
func ensure_temp_files() -> Dictionary:
	_ensure_ready()
	if not DirAccess.dir_exists_absolute(_temp_dir):
		DirAccess.make_dir_recursive_absolute(_temp_dir)
	var repaired: Array = []
	var checked := 0
	# ① 有 owner 的 5 份状态文件（默认值由 owner 自己决定）
	var owners: Array = [
		["player_profile.json", PlayerProfile],
		["nyxel_daily_state.json", NyxelDailyState],
		["calendar_notes.json", CalendarNotes],
		["devices.json", Devices],
		["inventory.json", Inventory],
	]
	for row in owners:
		var node = row[1]
		if node == null or not node.has_method("ensure_file"):
			continue
		checked += 1
		if bool(node.ensure_file()):
			repaired.append(str(row[0]))
	# ② 无 owner 的通用状态（StateRegistry 已登记；默认值 = 空对象，等价「无任何变量」）
	for f in ["nyxel_story_state.json", "world_state.json", "story_state.json"]:
		checked += 1
		var p := _temp_dir.path_join(f)
		if json_needs_repair(p):
			_write_json(p, {})
			repaired.append(f)
	# ③ task_schedule.json：外部提供的任务表；默认骨架 = 空事件列表（只在残缺时补，不覆盖已有内容）
	checked += 1
	var ts := _temp_dir.path_join("task_schedule.json")
	if json_needs_repair(ts, {"require_keys": ["events"], "array_keys": ["events"]}):
		_write_json(ts, {"version": 1, "events": []})
		repaired.append("task_schedule.json")
	if not repaired.is_empty():
		print("[SaveManager] Temp 状态自检：检查 %d 项，补建 %d 项 %s" % [checked, repaired.size(), str(repaired)])
	return { "checked": checked, "repaired": repaired }


# ============ 元数据 / 工具 ============

## 读取存档 save.json 的摘要（不展开积木，仅列表面板用）
func _read_meta(name: String) -> Dictionary:
	var data := _read_json(_saves_dir.path_join(name).path_join("save.json"))
	if data.is_empty():
		return {}
	return {
		"name": name,
		"type": str(data.get("type", TYPE_DESKTOP)),
		"created_at": int(data.get("created_at", 0)),
		"block_count": (data.get("blocks", []) as Array).size() if data.has("blocks") and typeof(data["blocks"]) == TYPE_ARRAY else 0,
		# ★ 自动 / 手动按**存档名前缀**判定（自动存档 = auto_<type>_…）。
		#   必须与 _prune_auto_saves / _list_auto_save_names 用同一判据：
		#   否则会出现「列表里标着自动、却不会被上限清理」或反之的不一致。
		"auto": name.begins_with("auto_"),
	}


## 递归把 dict/array 转成 JSON 可序列化结构（PackedStringArray → Array 等）
func _to_json_compatible(v: Variant) -> Variant:
	if v is PackedStringArray:
		return Array(v)
	if v is Dictionary:
		var out := {}
		for k in v:
			out[k] = _to_json_compatible(v[k])
		return out
	if v is Array:
		var out := []
		for e in v:
			out.append(_to_json_compatible(e))
		return out
	return v


func _write_json(path: String, data: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[SaveManager] 写入失败: %s" % path)
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return true


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	return data


## 存档名清洗：去掉不允许的路径字符；空 → 空串（由调用方生成默认名）
func _sanitize_name(s: String) -> String:
	return s.strip_edges().replace("/", "_").replace("\\", "_").replace(":", "_").replace("*", "_").replace("?", "_").replace("\"", "_").replace("<", "_").replace(">", "_").replace("|", "_")


## 存档名前缀：手动 = <type>_，自动 = auto_<type>_（区分自动/手动与桌面/世界）
func _name_prefix(type: String, auto: bool) -> String:
	return ("auto_" if auto else "") + type + "_"


## 默认存档名：yyyy_mm_dd_hh_min_ss（参照设计草案的时间命名；与前缀拼接使用）
func _default_save_name() -> String:
	var d := Time.get_datetime_dict_from_system(false)
	return "%04d_%02d_%02d_%02d_%02d_%02d" % [int(d.year), int(d.month), int(d.day), int(d.hour), int(d.minute), int(d.second)]


## 重名时追加 _2 / _3 后缀，直到不冲突
func _ensure_unique_name(base: String) -> String:
	var name := base
	var n := 2
	while DirAccess.dir_exists_absolute(_saves_dir.path_join(name)):
		name = "%s_%d" % [base, n]
		n += 1
	return name