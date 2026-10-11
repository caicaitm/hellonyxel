extends Node
# Windows 系统托盘（任务栏右下角「通知区域」）小图标 —— 游戏侧的拉起 / 收尾 / 退出请求处理。
#
# 分工：
#   托盘图标本身是 Windows 提供的（Shell_NotifyIcon），Godot 没有对应 API，
#   所以由本 autoload 在启动时拉起一个独立辅助进程
#   （addons/hellonyxel_tray/tray_icon.ps1 + TrayIcon.cs，与 SysInfoRunner 同一套原生调用约定）。
#
# 「退出游戏」的链路（不是杀进程）：
#   托盘右键菜单 → 点「退出游戏」→ 辅助进程写出「退出请求文件」
#   → 本脚本轮询到 → get_tree().quit()（走正常退出流程，保留"退出前存档"等钩子）
#   → _exit_tree 里结束辅助进程（正常路径），辅助进程的看门狗也会在游戏进程消失时自行退出（异常路径）。
#
# 注意：autoload 脚本不要声明与 autoload 名不同的 class_name（见项目记忆）。

# ★ 批次 5：优先用**预编译的 TrayIcon.exe**（同目录，由 build_tray.ps1 生成）；
#   PS1_PATH 仅作 EXE 缺失/失败时的兜底 —— PowerShell 宿主常驻要 ~103 MB，
#   而托盘真正需要的只是 WinForms 的消息循环。
const TRAY_EXE := "res://addons/hellonyxel_tray/TrayIcon.exe"
const PS1_PATH := "res://addons/hellonyxel_tray/tray_icon.ps1"
const ICON_PNG := "user://tray_icon.png"
const ICON_SIZE := 32                 # 通知区域图标按 32×32 生成，由 Windows 按 DPI 缩放
# ★ 批次 62：托盘改为**忙闲双图标** —— 空闲 icon.ico，在忙 icon_zzz.ico（与 BusyState 绑定）。
#   ★★ 放在 `.0icon/`（点开头）里是**故意的**：Godot 扫描会跳过点开头的目录 →
#      这两个 .ico 不进导入库、也不会被当成资源处理；辅助进程只需要一个**真实文件路径**。
#   ★ 换图标由托盘进程自己做（只有持有 NotifyIcon 的进程能改它）：
#      游戏侧只写忙闲状态文件（见 write_busy_state），托盘轮询到变化就换（见 TrayIcon.cs）。
const ICON_IDLE := "res://textures/.0icon/icon.ico"
const ICON_BUSY := "res://textures/.0icon/icon_zzz.ico"
const POLL_INTERVAL := 0.2            # 退出请求文件的轮询间隔（秒）

# 托盘「打开设置」请求（右键 → 设置 → 打开设置）：收到后发 settings_requested 信号
signal settings_requested
# 托盘「打开存档列表」请求（右键 → 存档 → 打开存档列表）：收到后发 saves_list_requested 信号
signal saves_list_requested
# 托盘「打开MOD列表」请求（右键 → 打开MOD列表）：收到后发 mod_list_requested 信号
signal mod_list_requested
# 托盘「性能忙闲判断」请求（右键 → 性能忙闲判断）：收到后发 perf_busy_requested 信号
signal perf_busy_requested
# 托盘「配置天气」请求（右键 → 配置天气）：收到后发 weather_config_requested 信号（业务预留）
signal weather_config_requested
# 托盘「配置人工智能」请求（右键 → 配置人工智能）：收到后发 ai_config_requested 信号（业务预留）
signal ai_config_requested
# 托盘「打开日历」请求（右键 → 打开日历）：收到后发 calendar_requested 信号
signal calendar_requested
# 托盘「进入/退出调试模式」请求（右键 → 进入/退出调试模式）：收到后发 toggle_debug_requested 信号
signal toggle_debug_requested

var _tray_pid: int = -1               # 辅助进程 PID；-1 = 未运行
var _request_path: String = ""        # 「退出游戏」请求文件（含本进程 PID，避免多开互相干扰）
var _settings_request_path: String = ""  # 「打开设置」请求文件
var _saves_request_path: String = ""     # 「打开存档列表」请求文件
var _mod_request_path: String = ""        # 「打开MOD列表」请求文件
var _perf_busy_request_path: String = ""   # 「性能忙闲判断」请求文件
var _weather_request_path: String = ""      # 「配置天气」请求文件
var _ai_request_path: String = ""          # 「配置人工智能」请求文件
var _calendar_request_path: String = ""    # 「打开日历」请求文件
var _passthrough_request_path: String = ""  # 「关闭桌面穿透」请求文件
var _debug_request_path: String = ""        # 「进入/退出调试模式」请求文件
var _busy_state_path: String = ""           # 忙闲状态文件（本进程 → 托盘：内容 "busy|locked" 等）
var _debug_state_path: String = ""          # 调试状态文件（本进程 → 托盘：内容 "on"/"off"）
var _busy_now_request_path: String = ""     # 「现在在忙」请求文件（托盘 → 本进程）
var _idle_now_request_path: String = ""     # 「现在空闲」请求文件（托盘 → 本进程）
var _accum: float = 0.0
var _quit_handled: bool = false
var _exe_warned: bool = false          # TrayIcon.exe 缺失/拉起失败的告警只发一次


func _ready() -> void:
	# ★ OS.get_name() 返回的是 "Windows"（首字母大写）；这里用特性判定更稳。
	if not OS.has_feature("windows"):
		return
	set_process(false)
	# 等一帧：确保显示服务器已就绪，headless 判定才准确
	await get_tree().process_frame
	# 无头运行（编辑器解析扫描 / 自动化验证）不拉起托盘，否则会留下永不退出的残留进程。
	# HELLONYXEL_NO_TRAY=1 也可显式关掉（自动化测试用）。
	if DisplayServer.get_name() == "headless" or OS.get_environment("HELLONYXEL_NO_TRAY") == "1":
		print("[TrayRunner] 跳过系统托盘（headless / HELLONYXEL_NO_TRAY=1）")
		return
	_request_path = ProjectSettings.globalize_path("user://tray_quit_%d.request" % OS.get_process_id())
	_settings_request_path = ProjectSettings.globalize_path("user://tray_settings_%d.request" % OS.get_process_id())
	_saves_request_path = ProjectSettings.globalize_path("user://tray_saves_%d.request" % OS.get_process_id())
	_mod_request_path = ProjectSettings.globalize_path("user://tray_modlist_%d.request" % OS.get_process_id())
	_perf_busy_request_path = ProjectSettings.globalize_path("user://tray_perfbusy_%d.request" % OS.get_process_id())
	_weather_request_path = ProjectSettings.globalize_path("user://tray_weather_%d.request" % OS.get_process_id())
	_ai_request_path = ProjectSettings.globalize_path("user://tray_ai_%d.request" % OS.get_process_id())
	_calendar_request_path = ProjectSettings.globalize_path("user://tray_calendar_%d.request" % OS.get_process_id())
	_passthrough_request_path = ProjectSettings.globalize_path("user://tray_passthrough_%d.request" % OS.get_process_id())
	_debug_request_path = ProjectSettings.globalize_path("user://tray_debug_%d.request" % OS.get_process_id())
	_busy_state_path = _busy_state_file()
	_debug_state_path = _debug_state_file()
	_busy_now_request_path = ProjectSettings.globalize_path("user://tray_busynow_%d.request" % OS.get_process_id())
	_idle_now_request_path = ProjectSettings.globalize_path("user://tray_idlenow_%d.request" % OS.get_process_id())
	_tray_pid = _launch_tray()
	if _tray_pid > 0:
		set_process(true)
		print("[TrayRunner] 系统托盘已启动 pid=%d 请求文件=%s" % [_tray_pid, _request_path])
		# 把「是否显示调试模式按钮」的初始状态写给托盘（设置在托盘启动前已从 settings.json 读好）。
		_deliver_debug_visibility()
		# 把当前调试状态写给托盘（决定那项显示「进入」还是「退出」）。
		write_debug_state(_current_debug_mode())


func _process(delta: float) -> void:
	_accum += delta
	if _accum < POLL_INTERVAL:
		return
	_accum = 0.0
	# 1) 「退出游戏」请求：辅助进程写的文件 → 正常退出
	if not _request_path.is_empty() and FileAccess.file_exists(_request_path):
		DirAccess.remove_absolute(_request_path)
		print("[TrayRunner] 收到托盘「退出游戏」请求 → 正常退出")
		graceful_quit()
		return
	# 2) 「打开设置」请求：辅助进程写的文件 → 发信号让桌面打开设置页
	if not _settings_request_path.is_empty() and FileAccess.file_exists(_settings_request_path):
		DirAccess.remove_absolute(_settings_request_path)
		print("[TrayRunner] 收到托盘「打开设置」请求")
		settings_requested.emit()
	# 3) 「打开存档列表」请求：辅助进程写的文件 → 发信号让桌面打开存档列表页
	if not _saves_request_path.is_empty() and FileAccess.file_exists(_saves_request_path):
		DirAccess.remove_absolute(_saves_request_path)
		print("[TrayRunner] 收到托盘「打开存档列表」请求")
		saves_list_requested.emit()
	# 3b) 「打开MOD列表」请求：辅助进程写的文件 → 发信号让桌面打开MOD列表占位页
	if not _mod_request_path.is_empty() and FileAccess.file_exists(_mod_request_path):
		DirAccess.remove_absolute(_mod_request_path)
		print("[TrayRunner] 收到托盘「打开MOD列表」请求")
		mod_list_requested.emit()
	# 4) 「关闭桌面穿透」请求：辅助进程写的文件 → 关闭穿透（开启用 Tab，关闭统一走托盘右键菜单）
	if not _passthrough_request_path.is_empty() and FileAccess.file_exists(_passthrough_request_path):
		DirAccess.remove_absolute(_passthrough_request_path)
		print("[TrayRunner] 收到托盘「关闭桌面穿透」请求 → 关闭穿透")
		MousePassRunner.set_enabled(false)
	# 5) 「性能忙闲判断」请求：辅助进程写的文件 → 发信号让桌面打开性能忙闲判断面板
	if not _perf_busy_request_path.is_empty() and FileAccess.file_exists(_perf_busy_request_path):
		DirAccess.remove_absolute(_perf_busy_request_path)
		print("[TrayRunner] 收到托盘「性能忙闲判断」请求")
		perf_busy_requested.emit()
	# 6) 「配置天气」请求：辅助进程写的文件 → 发信号让桌面打开天气配置占位页面
	if not _weather_request_path.is_empty() and FileAccess.file_exists(_weather_request_path):
		DirAccess.remove_absolute(_weather_request_path)
		print("[TrayRunner] 收到托盘「配置天气」请求")
		weather_config_requested.emit()
	# 7) 「配置人工智能」请求：辅助进程写的文件 → 发信号让桌面打开人工智能配置占位页面
	if not _ai_request_path.is_empty() and FileAccess.file_exists(_ai_request_path):
		DirAccess.remove_absolute(_ai_request_path)
		print("[TrayRunner] 收到托盘「配置人工智能」请求")
		ai_config_requested.emit()
	# 7.5) 「打开日历」请求：辅助进程写的文件 → 发信号让桌面打开日历/日记/备忘录单页
	if not _calendar_request_path.is_empty() and FileAccess.file_exists(_calendar_request_path):
		DirAccess.remove_absolute(_calendar_request_path)
		print("[TrayRunner] 收到托盘「打开日历」请求")
		calendar_requested.emit()
	# 7.6) 「进入/退出调试模式」请求：辅助进程写的文件 → 发信号让桌面切换 Debug.debug_mode
	if not _debug_request_path.is_empty() and FileAccess.file_exists(_debug_request_path):
		DirAccess.remove_absolute(_debug_request_path)
		print("[TrayRunner] 收到托盘「进入/退出调试模式」请求")
		toggle_debug_requested.emit()
	# 8) 「现在在忙 / 现在空闲」请求：两个独立文件，**存在即代表意图**（与其它请求同一约定，
	#    这样只要不出现半个文件就绝不会读错意图）→ 交给 BusyState 处理。
	#    ★ 时段内已手动切换过一次时 BusyState 会拒绝（本次时段锁定）。
	if not _busy_now_request_path.is_empty() and FileAccess.file_exists(_busy_now_request_path):
		DirAccess.remove_absolute(_busy_now_request_path)
		print("[TrayRunner] 收到托盘「现在在忙」请求")
		_apply_manual_busy(true)
	if not _idle_now_request_path.is_empty() and FileAccess.file_exists(_idle_now_request_path):
		DirAccess.remove_absolute(_idle_now_request_path)
		print("[TrayRunner] 收到托盘「现在空闲」请求")
		_apply_manual_busy(false)


# ---------------- 对外 API（事件链 / 调试面板 / 外部工具均可调用）----------------

# 写出「退出游戏」请求文件 —— 与托盘菜单点击完全等价，随后由轮询统一走 graceful_quit()。
# （外部工具想请求游戏退出时，往 get_request_path() 写个文件即可。）
func write_quit_request() -> void:
	if _request_path.is_empty():
		_request_path = ProjectSettings.globalize_path("user://tray_quit_%d.request" % OS.get_process_id())
	var f := FileAccess.open(_request_path, FileAccess.WRITE)
	if f != null:
		f.close()


# 写出「打开设置」请求 —— 与托盘二级菜单「打开设置」等价（测试 / 外部工具可用）。
func write_settings_request() -> void:
	if _settings_request_path.is_empty():
		_settings_request_path = ProjectSettings.globalize_path("user://tray_settings_%d.request" % OS.get_process_id())
	var f := FileAccess.open(_settings_request_path, FileAccess.WRITE)
	if f != null:
		f.close()


# 写出「打开存档列表」请求 —— 与托盘二级菜单「打开存档列表」等价（测试 / 外部工具可用）。
func write_saves_request() -> void:
	if _saves_request_path.is_empty():
		_saves_request_path = ProjectSettings.globalize_path("user://tray_saves_%d.request" % OS.get_process_id())
	var f := FileAccess.open(_saves_request_path, FileAccess.WRITE)
	if f != null:
		f.close()


# 写出「打开MOD列表」请求 —— 与托盘右键菜单「打开MOD列表」等价（测试 / 外部工具可用）。
func write_mod_request() -> void:
	if _mod_request_path.is_empty():
		_mod_request_path = ProjectSettings.globalize_path("user://tray_modlist_%d.request" % OS.get_process_id())
	var f := FileAccess.open(_mod_request_path, FileAccess.WRITE)
	if f != null:
		f.close()


# 写出「性能忙闲判断」请求 —— 与托盘右键菜单「性能忙闲判断」等价（测试 / 外部工具可用）。
func write_perf_busy_request() -> void:
	if _perf_busy_request_path.is_empty():
		_perf_busy_request_path = ProjectSettings.globalize_path("user://tray_perfbusy_%d.request" % OS.get_process_id())
	var f := FileAccess.open(_perf_busy_request_path, FileAccess.WRITE)
	if f != null:
		f.close()


# 写出「配置天气」请求 —— 与托盘右键菜单「配置天气」等价（测试 / 外部工具可用，业务预留）。
func write_weather_request() -> void:
	if _weather_request_path.is_empty():
		_weather_request_path = ProjectSettings.globalize_path("user://tray_weather_%d.request" % OS.get_process_id())
	var f := FileAccess.open(_weather_request_path, FileAccess.WRITE)
	if f != null:
		f.close()


# 写出「配置人工智能」请求 —— 与托盘右键菜单「配置人工智能」等价（测试 / 外部工具可用，业务预留）。
func write_ai_request() -> void:
	if _ai_request_path.is_empty():
		_ai_request_path = ProjectSettings.globalize_path("user://tray_ai_%d.request" % OS.get_process_id())
	var f := FileAccess.open(_ai_request_path, FileAccess.WRITE)
	if f != null:
		f.close()


# 写出「打开日历」请求 —— 与托盘右键菜单「打开日历」等价（测试 / 外部工具可用）。
func write_calendar_request() -> void:
	if _calendar_request_path.is_empty():
		_calendar_request_path = ProjectSettings.globalize_path("user://tray_calendar_%d.request" % OS.get_process_id())
	var f := FileAccess.open(_calendar_request_path, FileAccess.WRITE)
	if f != null:
		f.close()


# 写出「关闭桌面穿透」请求 —— 与托盘右键菜单「关闭桌面穿透」等价（测试 / 外部工具可用）。
func write_passthrough_request() -> void:
	if _passthrough_request_path.is_empty():
		_passthrough_request_path = ProjectSettings.globalize_path("user://tray_passthrough_%d.request" % OS.get_process_id())
	var f := FileAccess.open(_passthrough_request_path, FileAccess.WRITE)
	if f != null:
		f.close()


# 写出「进入/退出调试模式」请求 —— 与托盘右键菜单「进入/退出调试模式」等价（测试 / 外部工具可用）。
func write_debug_request() -> void:
	if _debug_request_path.is_empty():
		_debug_request_path = ProjectSettings.globalize_path("user://tray_debug_%d.request" % OS.get_process_id())
	var f := FileAccess.open(_debug_request_path, FileAccess.WRITE)
	if f != null:
		f.close()


# 忙闲状态文件路径（本进程 → 托盘）。每次会话独立文件名，避免多开互相干扰。
func _busy_state_file() -> String:
	return ProjectSettings.globalize_path("user://tray_busystate_%d.txt" % OS.get_process_id())


# 调试状态文件路径（本进程 → 托盘）。决定菜单项显示「进入调试模式」还是「退出调试模式」。
func _debug_state_file() -> String:
	return ProjectSettings.globalize_path("user://tray_debugstate_%d.txt" % OS.get_process_id())


# 把调试状态写给托盘（内容 "on" / "off"）。托盘**菜单展开时**读它，据此切换调试项的文案。
# 设置页开关「显示调试模式按钮」变化、以及 Debug.debug_mode 变化时都调用本函数。
func write_debug_state(on: bool) -> void:
	if _debug_state_path.is_empty():
		_debug_state_path = _debug_state_file()
	var f := FileAccess.open(_debug_state_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("on" if on else "off")
	f.close()


# 写「是否显示调试模式按钮」的状态文件（内容 "1" / "0"）。托盘**菜单展开时**读它决定调试项显隐。
# ★ 为什么用状态文件而不是重启托盘进程：托盘是常驻独立进程，重启代价高（图标闪烁 + 丢菜单状态）；
#   用状态文件即可让设置页开关**当场生效**（下一次右键展开菜单时读取）。
func _deliver_debug_visibility() -> void:
	var path := _debug_visible_file()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("1" if _debug_button_visible() else "0")
	f.close()


# 「是否显示调试模式按钮」状态文件路径（本进程 → 托盘）。
func _debug_visible_file() -> String:
	return ProjectSettings.globalize_path("user://tray_debugvisible_%d.txt" % OS.get_process_id())


# 读设置里的「显示调试模式按钮」开关（默认显示）。设置页改动时也调本函数重新下发给托盘。
func _debug_button_visible() -> bool:
	var sm = get_node_or_null("/root/SaveManager")
	if sm == null:
		return true
	var s: Variant = sm.get_app_settings()
	if typeof(s) != TYPE_DICTIONARY:
		return true
	var d: Dictionary = s as Dictionary
	if not d.has("tray_debug_button"):
		return true     # 默认显示
	return bool(d["tray_debug_button"])


# 读当前调试模式状态（Debug.debug_mode）。
func _current_debug_mode() -> bool:
	var dbg = get_node_or_null("/root/Debug")
	if dbg == null:
		return false
	return bool(dbg.debug_mode)


# 供设置页调用：开关变化时立刻把新的显隐下发给托盘（无需重启托盘）。
# ★ 不因 _tray_pid <= 0 而早退：状态文件是托盘的唯一真源，随时保持与设置一致最稳妥
#   （托盘进程在菜单展开时才读它；此处只写一个小文本文件，开销可忽略）。
func refresh_debug_button_visibility() -> void:
	_deliver_debug_visibility()


# 把忙闲状态写给托盘（内容 "busy|locked" / "idle|unlocked"）。
# 托盘右键菜单**展开时**读它，据此只显示「现在在忙 / 现在空闲」中与当前相反的那一项，
# 并可据此把按钮置灰（locked=true = 本时段已手动切换过）。
func write_busy_state(busy: bool, locked: bool) -> void:
	if _busy_state_path.is_empty():
		_busy_state_path = _busy_state_file()
	var f := FileAccess.open(_busy_state_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("%s|%s" % ["busy" if busy else "idle", "locked" if locked else "unlocked"])
	f.close()


# 托盘「现在在忙 / 现在空闲」→ 交给 BusyState 裁决（时段内第二次切换会被拒绝）。
# BusyState 拒绝时自行打印原因；这里只负责转发，保证托盘侧不需要知道任何规则。
func _apply_manual_busy(busy: bool) -> void:
	var bs = get_node_or_null("/root/BusyState")
	if bs == null or not bs.has_method("set_manual"):
		push_warning("[TrayRunner] BusyState 不可用 → 忽略手动忙闲切换")
		return
	bs.set_manual(busy)


func is_tray_running() -> bool:
	return _tray_pid > 0

func get_tray_pid() -> int:
	return _tray_pid


func get_request_path() -> String:
	return _request_path


# 结束托盘辅助进程（游戏退出时自动调用；脚本 / 调试面板也可手动调用）。
# 正常路径由这里 OS.kill 收掉；异常路径（游戏崩溃）由辅助进程自己的看门狗收掉。
func stop_tray() -> void:
	if _tray_pid <= 0:
		return
	OS.kill(_tray_pid)
	print("[TrayRunner] 已结束托盘辅助进程 pid=%d" % _tray_pid)
	_tray_pid = -1


# 正常退出流程：若开启了「退出自动存档」，先存档再退出。
func graceful_quit() -> void:
	if _quit_handled:
		return
	_quit_handled = true
	_maybe_quit_auto_save()
	_cleanup()
	get_tree().quit()


# 退出自动存档：默认关；设置面板勾选启用（SaveManager.get_quit_auto_save）。
func _maybe_quit_auto_save() -> void:
	var sm = get_node_or_null("/root/SaveManager")
	if sm == null or not sm.get_quit_auto_save():
		return
	var r: Dictionary = sm.auto_save("desktop")
	print("[TrayRunner] 退出自动存档 %s  %s" % ["成功" if r.get("ok", false) else "失败", str(r.get("name", ""))])


func _exit_tree() -> void:
	_cleanup()


# ---------------- 内部 ----------------

func _launch_tray() -> int:
	# 清掉上一次会话遗留的请求文件与日志（每次会话用独立文件名，不清理会一直堆积）
	_clean_stale_files()
	var auto_click := OS.get_environment("HELLONYXEL_TRAY_AUTOCLICK")
	if auto_click.is_empty():
		auto_click = "0"    # 端到端自测钩子：设为秒数则辅助进程到时自动点一次「退出游戏」
	# 传参一律用**具名**参数：路径可能为空（图标生成失败时省略 -IconPath），
	# 用具名可避免位置参数因空串被丢弃而整体错位。
	# ★★ 批次 5（P0-C / C1）：这份参数表 EXE 与脚本**两条路径共用** —— TrayIcon.Main()
	#    解析的就是同一批名字（见 TrayIcon.cs 的 Main）。
	var named := PackedStringArray()
	var icon := _prepare_icon()
	if not icon.is_empty():
		named.append_array(["-IconPath", _q(icon)])
	# 「在忙」图标：为空时 C# 侧只用一个图标（忙闲不换图标），托盘照常可用。
	var busy_icon := _prepare_busy_icon()
	if not busy_icon.is_empty():
		named.append_array(["-BusyIconPath", _q(busy_icon)])
	named.append_array([
		"-RequestPath", _q(_request_path),
		"-SettingsRequestPath", _q(_settings_request_path),
		"-SavesRequestPath", _q(_saves_request_path),
		"-ModListRequestPath", _q(_mod_request_path),
		"-PerfBusyRequestPath", _q(_perf_busy_request_path),
		"-WeatherRequestPath", _q(_weather_request_path),
		"-AIRequestPath", _q(_ai_request_path),
		"-CalendarRequestPath", _q(_calendar_request_path),
		"-PassthroughRequestPath", _q(_passthrough_request_path),
		"-DebugRequestPath", _q(_debug_request_path),
		"-BusyStatePath", _q(_busy_state_path),
		"-DebugStatePath", _q(_debug_state_path),
		"-DebugVisiblePath", _q(_debug_visible_file()),
		"-ShowDebugItem", "1" if _debug_button_visible() else "0",
		"-BusyNowRequestPath", _q(_busy_now_request_path),
		"-IdleNowRequestPath", _q(_idle_now_request_path),
		"-GamePid", str(OS.get_process_id()),
		"-AutoClickSeconds", auto_click,
	])
	# ① 优先**预编译的 TrayIcon.exe**：
	#    托盘常驻整个会话，而 PowerShell 宿主光是把 System.Management.Automation +
	#    CLR + WinForms + Drawing 装进来就要 ~103 MB；独立 EXE 只需 WinForms 消息循环，
	#    且（GUI 子系统）连 conhost 都不新建。
	var exe_abs := ProjectSettings.globalize_path(TRAY_EXE)
	if FileAccess.file_exists(exe_abs):
		var pid := OS.create_process(exe_abs, named, false)
		if pid > 0:
			return pid
		if not _exe_warned:
			_exe_warned = true
			push_warning("[TrayRunner] TrayIcon.exe 拉起失败 → 回退 powershell + tray_icon.ps1")
	elif not _exe_warned:
		_exe_warned = true
		push_warning("[TrayRunner] 未找到 TrayIcon.exe（先跑 addons/hellonyxel_tray/build_tray.ps1 生成）→ 回退 powershell + tray_icon.ps1")
	# ② 兜底：旧的 PowerShell 路径（每次现编译 TrayIcon.cs，慢且吃内存，但功能等价）
	var ps1 := ProjectSettings.globalize_path(PS1_PATH)
	if not FileAccess.file_exists(ps1):
		push_warning("[TrayRunner] 未找到托盘脚本: %s" % ps1)
		return -1
	var args := PackedStringArray(["-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", _q(ps1)])
	args.append_array(named)
	var pid2 := OS.create_process("powershell.exe", args, false)   # open_console=false → 不弹黑框
	if pid2 <= 0:
		push_warning("[TrayRunner] 拉起托盘辅助进程失败（powershell.exe 不可用？）")
	return pid2


# 命令行参数加引号（路径可能含空格）
func _q(path: String) -> String:
	return "\"%s\"" % path


# 清理上一次会话遗留的 tray_quit_* / tray_settings_* / tray_saves_* / tray_passthrough_* 文件
# （保留本次会话自己的一份；每次会话用独立文件名，不清理会一直堆积）
func _clean_stale_files() -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	var keep: Array = [_request_path, _settings_request_path, _saves_request_path, _mod_request_path, _perf_busy_request_path,
		_weather_request_path, _ai_request_path, _calendar_request_path, _passthrough_request_path, _debug_request_path,
		_busy_state_path, _debug_state_path, _debug_visible_file(), _busy_now_request_path, _idle_now_request_path,
		_request_path + ".log", _settings_request_path + ".log", _saves_request_path + ".log", _mod_request_path + ".log",
		_perf_busy_request_path + ".log", _weather_request_path + ".log", _ai_request_path + ".log", _calendar_request_path + ".log", _passthrough_request_path + ".log"]
	for f in dir.get_files():
		if not f.begins_with("tray_quit_") and not f.begins_with("tray_settings_") and not f.begins_with("tray_saves_") and not f.begins_with("tray_modlist_") and not f.begins_with("tray_perfbusy_") and not f.begins_with("tray_weather_") and not f.begins_with("tray_ai_") and not f.begins_with("tray_calendar_") and not f.begins_with("tray_passthrough_") and not f.begins_with("tray_debug_") and not f.begins_with("tray_busystate_") and not f.begins_with("tray_debugstate_") and not f.begins_with("tray_debugvisible_") and not f.begins_with("tray_busynow_") and not f.begins_with("tray_idlenow_"):
			continue
		var full := ProjectSettings.globalize_path("user://" + f)
		if full in keep:
			continue
		dir.remove(f)


# 托盘图标（空闲态）：textures/.0icon/icon.ico。两个 .ico 都缺失时才退回
# 「把 icon.svg 转成 PNG」的老路，保证托盘永远有图标。
func _prepare_icon() -> String:
	var ico := ProjectSettings.globalize_path(ICON_IDLE)
	if FileAccess.file_exists(ico):
		return ico
	return _prepare_fallback_png()


# 托盘图标（在忙态）：textures/.0icon/icon_zzz.ico；缺失 → 返回空串（忙闲不换图标）。
func _prepare_busy_icon() -> String:
	var ico := ProjectSettings.globalize_path(ICON_BUSY)
	if FileAccess.file_exists(ico):
		return ico
	return ""


# 兜底：把项目图标转成 PNG 交给托盘（NotifyIcon 需要 Icon，C# 侧从 PNG 的 HICON 得到）。
# 任何一步失败都返回空串 → C# 退回系统默认图标，不影响托盘可用性。
func _prepare_fallback_png() -> String:
	var tex = load("res://icon.svg")
	if not (tex is Texture2D):
		return ""
	var img: Image = (tex as Texture2D).get_image()
	if img == null:
		return ""
	img.resize(ICON_SIZE, ICON_SIZE, Image.INTERPOLATE_LANCZOS)
	var out := ProjectSettings.globalize_path(ICON_PNG)
	if img.save_png(out) != OK:
		return ""
	return out


func _cleanup() -> void:
	if not _request_path.is_empty() and FileAccess.file_exists(_request_path):
		DirAccess.remove_absolute(_request_path)
	if not _settings_request_path.is_empty() and FileAccess.file_exists(_settings_request_path):
		DirAccess.remove_absolute(_settings_request_path)
	if not _saves_request_path.is_empty() and FileAccess.file_exists(_saves_request_path):
		DirAccess.remove_absolute(_saves_request_path)
	if not _mod_request_path.is_empty() and FileAccess.file_exists(_mod_request_path):
		DirAccess.remove_absolute(_mod_request_path)
	if not _perf_busy_request_path.is_empty() and FileAccess.file_exists(_perf_busy_request_path):
		DirAccess.remove_absolute(_perf_busy_request_path)
	if not _weather_request_path.is_empty() and FileAccess.file_exists(_weather_request_path):
		DirAccess.remove_absolute(_weather_request_path)
	if not _ai_request_path.is_empty() and FileAccess.file_exists(_ai_request_path):
		DirAccess.remove_absolute(_ai_request_path)
	if not _passthrough_request_path.is_empty() and FileAccess.file_exists(_passthrough_request_path):
		DirAccess.remove_absolute(_passthrough_request_path)
	if not _debug_request_path.is_empty() and FileAccess.file_exists(_debug_request_path):
		DirAccess.remove_absolute(_debug_request_path)
	if not _busy_state_path.is_empty() and FileAccess.file_exists(_busy_state_path):
		DirAccess.remove_absolute(_busy_state_path)
	if not _debug_state_path.is_empty() and FileAccess.file_exists(_debug_state_path):
		DirAccess.remove_absolute(_debug_state_path)
	var dvp := _debug_visible_file()
	if FileAccess.file_exists(dvp):
		DirAccess.remove_absolute(dvp)
	if not _busy_now_request_path.is_empty() and FileAccess.file_exists(_busy_now_request_path):
		DirAccess.remove_absolute(_busy_now_request_path)
	if not _idle_now_request_path.is_empty() and FileAccess.file_exists(_idle_now_request_path):
		DirAccess.remove_absolute(_idle_now_request_path)
	stop_tray()
