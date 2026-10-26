extends Node

# 桌面外壳（autoload 名：DesktopShell）
#
# 目标：让本游戏窗口成为**一张覆盖整个屏幕（含任务栏）的透明画布** ——
#   桌面壁纸/图标从透明处透出来，玩家可以照常操作桌面，也可以操作场景里的元素。
#
# 这里负责三件事：
#   1) 尺寸不写死 —— 从 %Documents%\HelloNyxel\Temp\sysinfo.json 的
#      screen.primary_resolution 读取（该文件由 addons/hellonyxel_sysinfo 生成，
#      由 autoload SysInfoRunner 在启动时刷新）；读不到就退化为真实屏幕尺寸。
#   2) 窗口几何 —— 覆盖整屏时用「无边框窗口 + 高度 = 屏幕-1px」：
#      既盖住任务栏，又绕开"尺寸==屏幕会被驱动切成独占全屏"的黑屏陷阱；
#      同时保留 window_set_mouse_passthrough（桌面穿透）可用的前提。
#      ★ 不能用「无边框 + set_size(屏幕尺寸)」去铺满，也不能用 WINDOW_MODE_FULLSCREEN（会让穿透失效）。
#   3) 背景透明 —— 根视口 transparent_bg = true，未绘制处 alpha = 0。
#
# ★ 坐标系：project.godot 里 stretch/mode = "disabled"，窗口多大、视口就多大，
#   场景坐标 == 屏幕像素。所以 get_global_mouse_position() / event.position 就是屏幕坐标，
#   无需任何换算（desktop.gd 里的命中判定直接拿 event.position 用，就是这个原因）。
#
# 鼠标穿透（透明处点击直达桌面）不在本脚本里做 —— 见 autoload/MousePassRunner.gd。

const SYSINFO_SUBDIR := "HelloNyxel/Temp/sysinfo.json"
# 原生强制置顶：优先用**预编译的 SysInfo.exe**（子命令 `topmost <hwnd>`，批次 4 已内置），
# 它把「查 WS_EX_TOPMOST → 丢失才补钉 → 回读验证」打包成一次 ~40 ms 的原生调用。
# PIN_SCRIPT 仅作 EXE 缺失/失败时的兜底（每次都要现编译 30KB C#，慢一个数量级）。
const PIN_EXE := "res://addons/hellonyxel_sysinfo/SysInfo.exe"
const PIN_SCRIPT := "res://addons/hellonyxel_sysinfo/pin_topmost.ps1"

# 场景尺寸变化时发出（事件链 / UI 可据此重排）
signal geometry_changed(size: Vector2i)
# 窗口"强制置顶"开关变化时发出（模拟加速球的置顶特性：按 Win+D 也不隐藏本窗口）
signal always_on_top_changed(on: bool)
# 窗口"从任务栏隐藏"开关变化时发出
signal hide_from_taskbar_changed(on: bool)

var scene_size: Vector2i = Vector2i.ZERO   # 当前场景尺寸（= 窗口尺寸，单位像素）
var sysinfo_path: String = ""              # 解析出来的 sysinfo.json 绝对路径
var sysinfo: Dictionary = {}               # 最近一次读到的 sysinfo 内容

# 窗口是否强制置顶（默认开）。true → 像悬浮球那样浮在桌面上，显示桌面(Win+D)也不会被藏起来
var _always_on_top := true
# 是否把窗口从任务栏 + Alt+Tab 隐藏（WS_EX_TOOLWINDOW，默认开）。
# 本游戏是铺满全屏的桌面覆盖层，常驻任务栏会挤占一格并干扰玩家。
var _hide_from_taskbar := true
# 最近一次工具窗口设置的验证结果（TOOLWIN_OK 才算真的落进系统）
var _toolwindow_verified := false
# 原生置顶的后台线程（避免阻塞主线程；同一时间只跑一个）
var _pin_thread: Thread = null
# 最近一次成功钉顶的窗口句柄（若每次取回不同 → 窗口被重建、置顶丢了，需立刻重钉）
var _last_hwnd: int = 0
# 上一次原生钉顶后读回的验证结果（WS_EX_TOPMOST 是否真的在位）
var _topmost_verified := false
var _repin_accum := 0.0
# 最小化恢复的最小间隔（秒）。★ 恢复动作可能连续多帧都不生效（窗口被系统压着），
#   不加冷却就会**每帧** push_warning + 每帧重钉置顶（起 Thread + PowerShell 子进程）。
const RESTORE_COOLDOWN_SEC := 0.5
var _restore_cooldown := 0.0
# 周期兜底重钉的间隔（秒）。
# ★★ 批次 5（P0-C / C2）：这里**取代**了原来的常驻守护进程 pin_topmost_loop.ps1。
#   原设计是一个常驻 PowerShell 每 250 ms 查一次 WS_EX_TOPMOST、丢失才补钉 ——
#   它常驻要吃掉 ~93 MB + 一个 conhost ~7 MB，而它做的**唯一**一件事就是
#   「置顶标志被悄悄降级时 250 ms 内补回来」。可 pin 本来就是**事件驱动**的
#   （失焦 / 句柄变化 / 最小化恢复各钉一次，见 _notification 与 _restore_after_minimize），
#   周期兜底只是最后一道保险 ⇒ 改成一个 30 s 的兜底即可，且每次现在只有 ~40 ms。
const PIN_REPIN_SEC := 30.0
# ★★ 两次「起钉顶线程」之间的**最小间隔**（秒）—— 线程/子进程风暴的节流闸门。
#   崩溃取证（2026-10-04 signal 11）：日志最后一段是
#   「检测到窗口被最小化 → 恢复并重钉 → 连续 4 次『原生置顶 TOPOK』→ CrashHandlerException」，
#   且 12:25 那轮日志里 `最小化期间场景尺寸失效 (0, 0)` 反复出现。
#   也就是说：最小化恢复会在**同一帧**同时触发 3 个钉顶入口
#   （_restore_after_minimize 拉满 _repin_accum / _process 的句柄变化 / _notification 失焦），
#   旧实现只有「上一轮还活着就跳过」这一个闸门 —— 上一轮**刚跑完**的瞬间会立刻再起一个，
#   于是 SysInfo.exe 子进程 + 线程在窗口句柄正在被系统重建的当口被成批拉起（native 段错）。
#   加一个最小间隔后，窗口剧变期间最多只保留一次在途钉顶。
const PIN_MIN_INTERVAL_SEC := 2.0
var _last_pin_start: int = 0   # 上次**起线程**的时刻（Time.get_ticks_msec）

# ★★ 钉顶线程的结果交接（后台线程 → 主线程）。
#   崩溃取证：旧实现在 `_pin_worker`（**后台线程**）里直接 `print()` 并写 `_topmost_verified`。
#   `print()` 会走引擎的全局日志系统，与主线程并发写日志文件（且启动期日志正在轮转）
#   是 native 崩溃的经典来源。现在线程**只做计算、只写结果槽**（Mutex 保护），
#   打印与状态应用一律回到主线程 `_process` 里做。
var _pin_mutex := Mutex.new()
var _pin_res_ready := false
var _pin_res_code := -1
var _pin_res_verified := false
var _pin_res_hwnd := 0
# 同一次 `window-style` 调用里顺手带回的「任务栏隐藏」验证位（TOOLWIN_OK）
var _pin_res_toolwin := false

# ★★ 退出闩锁：一旦进入 _exit_tree 就置 true。
#    `_pin_topmost_native()` 据此**早退**，彻底关掉「退出期间又起新线程 / 新子进程」这个窗口。
#    否则退出时子进程与 Thread 同时拆 → 线程未回收 → 原生段错（signal 11）。
var _exiting := false

# ★★ headless（`--headless` 无真实窗口）下 `DisplayServer.window_get_mode()` **恒为 MINIMIZED**，
#   于是 `_process` 每 0.5s 触发一次「恢复最小化」→ 告警刷屏、并反复起 Thread + SysInfo 子进程。
#   本机实测跑一次 headless 主场景就刷出 6 条恢复告警（真实窗口下也会刷）。
#   headless 既没有窗口可恢复、也没有窗口可钉顶 → 整段直接跳过。
var _headless := false
# 最小化恢复的累计次数（仅用于日志节流，见 `_restore_after_minimize`）。
var _restore_count := 0


func _ready() -> void:
	# ★ headless 检测：本构建下 `OS.has_feature("headless")` / `--headless` 均不可靠，
	#   `DisplayServer.get_name()` 才是唯一可信来源（见项目记忆）。
	_headless = DisplayServer.get_name().to_lower().contains("headless")
	_resolve_sysinfo_path()
	refresh_from_sysinfo()
	# 等窗口完全显示后再做一次原生置顶（覆盖 _ready 里 _apply_geometry 触发的钉顶之前窗口可能未就绪的情况）
	_deferred_pin()


# 推迟几帧后原生置顶一次（窗口已显示、几何已稳定，此时钉住最稳）
func _deferred_pin() -> void:
	for i in 3:
		await get_tree().process_frame
	if _exiting or not is_inside_tree():
		return          # ★ 退出中 / 已离树：不再钉顶（这个协程可能跨越退出时刻）
	_pin_topmost_native()


# 每帧保驾护航：真正的「悬浮球」行为。
#   Win+D（显示桌面）只会最小化**非置顶**窗口；置顶(WS_EX_TOPMOST)窗口会被跳过。
#   但置顶标志可能被后续窗口操作静默降级 / 窗口被重建，所以这里：
#     1) 一旦发现被最小化（被误伤）→ 立刻恢复并重钉；
#     2) 窗口句柄变化（窗口被重建）→ 立刻重钉；
#     3) 每 PIN_REPIN_SEC 强制再钉一次，抗「置顶被悄悄降级」。
func _process(delta: float) -> void:
	# ★★ 先消费钉顶线程的结果（后台线程只写槽，打印/状态应用全在这里 → 主线程）。
	#   放在最前面：即使下面因 !_always_on_top / _exiting 早退，结果也能被正常消费掉。
	_consume_pin_result()
	# ★★ headless：没有真实窗口。窗口模式恒为 MINIMIZED 会让下面每冷却周期都「恢复」一次
	#   （告警刷屏 + 起 Thread/子进程），重钉置顶也毫无意义 → 整段跳过。
	if _headless:
		return
	# 置顶与「任务栏隐藏」都不需要维护时直接跳过（否则句柄变化/周期兜底都要跑一次原生调用）
	if not _always_on_top and not _hide_from_taskbar:
		return
	if _exiting:
		return          # ★ 退出中：不再重钉 / 不再管守护，避免退出期新起线程或子进程
	# 1) 被最小化 → 恢复（覆盖层是透明画布，恢复不打扰桌面浏览）
	#    ★ 带冷却闸门：旧版每帧调用 → 日志刷屏 + 每帧重钉（线程/子进程风暴）。
	if _restore_cooldown > 0.0:
		_restore_cooldown = maxf(0.0, _restore_cooldown - delta)
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED:
		_restore_after_minimize()
	# 2) 周期兜底重钉 + 句柄变化立刻重钉（★ 批次 5 起不再维护常驻守护进程）
	_repin_accum += delta
	var hwnd := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
	if _repin_accum >= PIN_REPIN_SEC or hwnd != _last_hwnd:
		_last_hwnd = hwnd
		_repin_accum = 0.0
		_topmost_verified = false
		_pin_topmost_native()   # 兜底一次性钉顶（并输出验证日志）


# 被最小化（通常来自 Win+D 误伤 / 某些全屏切换）→ 恢复为普通窗口并立刻重钉置顶
func _restore_after_minimize() -> void:
	# ★★ 冷却闸门：恢复不一定一帧就生效（窗口被系统压着时会连续多帧判定为 MINIMIZED）。
	#   旧版无闸门 → 每帧 push_warning、每帧把 _repin_accum 拉满 → 每帧重钉置顶
	#   （`_pin_topmost_native` 会起 Thread + PowerShell 子进程）→ 本机实测单次会话刷出
	#   240~300 条恢复警告 + 数百次置顶子进程 → 线程/进程风暴，是已知的 native 崩溃来源。
	if _restore_cooldown > 0.0:
		return
	_restore_cooldown = RESTORE_COOLDOWN_SEC
	# ★★ 这是**预期内的自愈**（覆盖层被 Win+D 等误伤 → 恢复并重钉），不是错误。
	#   原来用 push_warning → 每次都在输出面板里显示成黄色告警、并刷屏（旧实现单会话 240~300 条）。
	#   改为 print + 节流：第 1 次与之后每 10 次各留一条，既能排查又不淹没日志。
	_restore_count += 1
	if _restore_count == 1 or _restore_count % 10 == 0:
		print("[DesktopShell] 检测到窗口被最小化（可能被 显示桌面/Win+D 误伤）→ 已恢复并重钉置顶（累计 %d 次）" % _restore_count)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	# ★ 最小化期间窗口几何可能已被破坏（本机出现过 scene_size 被设成 (0,-1)）→ 尺寸非法时重算一次。
	if scene_size.x <= 0 or scene_size.y <= 0:
		push_warning("[DesktopShell] 最小化期间场景尺寸失效 %s → 重新应用窗口几何" % str(scene_size))
		refresh_from_sysinfo()
	_apply_always_on_top()
	_repin_accum = PIN_REPIN_SEC   # 冷却结束后的那一帧立刻进入重钉分支


# 失焦（别的窗口被打开 / 激活 / 抢占焦点）→ 立刻重钉置顶。
# 否则新开的窗口可能把本覆盖层"压到下面"（置顶标志被窗口操作悄悄降级）。
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		if _always_on_top:
			_topmost_verified = false
			_pin_topmost_native()


# ============ 对外 API（事件链 / 调试面板 / 外部工具均可调用）============

# 重新读 sysinfo.json 并应用窗口几何（启动时自动调一次；换分辨率后可再调）
func refresh_from_sysinfo() -> void:
	sysinfo = read_sysinfo()
	var size := _resolution_from_sysinfo()
	if size.x <= 0 or size.y <= 0:
		size = DisplayServer.screen_get_size()
		push_warning("[DesktopShell] sysinfo 里没有可用分辨率，退化为实际屏幕尺寸 %s" % str(size))
	_apply_geometry(size)


# 手动指定场景尺寸（像素）。事件链脚本可直接调用做"改变桌面大小"。
func set_scene_size(size: Vector2i) -> void:
	_apply_geometry(size)


# 开关「窗口强制置顶」：true=浮在桌面上（按 Win+D 也不隐藏），false=普通窗口
func set_always_on_top(on: bool) -> void:
	if _always_on_top == on:
		return
	_always_on_top = on
	_apply_always_on_top()
	if on:
		_pin_topmost_native()   # 原生再钉一次置顶，抗住 Godot 透明窗口的降级
	always_on_top_changed.emit(on)


func is_always_on_top() -> bool:
	return _always_on_top


# 开关「从任务栏隐藏」：true（默认）=加 WS_EX_TOOLWINDOW，窗口不出现在任务栏与 Alt+Tab；
# false=恢复成普通任务栏窗口。改动后立刻原生应用一次（复用钉顶线程，一次子进程搞定两项）。
func set_hide_from_taskbar(on: bool) -> void:
	if _hide_from_taskbar == on:
		return
	_hide_from_taskbar = on
	_pin_topmost_native()
	hide_from_taskbar_changed.emit(on)


func is_hide_from_taskbar() -> bool:
	return _hide_from_taskbar


# 最近一次「任务栏隐藏」是否真的落进了系统（WS_EX_TOOLWINDOW 在位）
func is_toolwindow_verified() -> bool:
	return _toolwindow_verified


# 把「置顶」标志应用到系统窗口（WINDOW_FLAG_ALWAYS_ON_TOP → Windows 的 WS_EX_TOPMOST）
func _apply_always_on_top() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, _always_on_top)


# 原生强制置顶：后台线程跑 SysInfo.exe（兜底 pin_topmost.ps1），
# 对当前窗口 HWND 执行 SetWindowPos(HWND_TOPMOST)。
# Godot 的 WINDOW_FLAG_ALWAYS_ON_TOP 在透明覆盖窗口上可能被后续窗口操作降级、导致 Win+D 仍会最小化，
# 原生 SetWindowPos 双保险，确保置顶真正落进系统。
func _pin_topmost_native() -> void:
	if _exiting:
		return          # ★ 退出中：不再起置顶线程（否则退出期 Thread 与 PowerShell 子进程同拆 → 段错）
	# 置顶关了但仍要隐藏任务栏时，这条链路仍要走（它一次调用同时处理两项）
	if not _always_on_top and not _hide_from_taskbar:
		return
	# ★★ 节流闸门：距上次起线程不足 PIN_MIN_INTERVAL_SEC 就跳过。
	#   崩溃取证见 PIN_MIN_INTERVAL_SEC 注释 —— 窗口剧变（最小化恢复 / 句柄重建）时
	#   多个钉顶入口会挤在同一帧各起一个子进程，那是 native signal 11 的实际触发路径。
	var now_ms := Time.get_ticks_msec()
	if _last_pin_start > 0 and (now_ms - _last_pin_start) < int(PIN_MIN_INTERVAL_SEC * 1000):
		return
	if _pin_thread != null:
		if _pin_thread.is_alive():
			return          # 上一轮还没跑完，跳过本次
		_pin_thread.wait_to_finish()
		_pin_thread = null
	var hwnd := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
	if hwnd == 0:
		return
	# ★★ 不变式：`_pin_thread != null` ⟹ 该 Thread **一定已经 start() 成功**。
	#   否则 `wait_to_finish()` 会对未启动的 Thread 报错（ERR_UNCONFIGURED）。
	#   start() 失败就当场把对象丢掉，绝不留下"已 new、未 start"的悬空线程。
	var t := Thread.new()
	_last_pin_start = now_ms
	# 清掉上一轮的结果槽（Mutex 内做，避免与 worker 写入竞争）
	_pin_mutex.lock()
	_pin_res_ready = false
	_pin_mutex.unlock()
	if t.start(_pin_worker.bind(hwnd)) != OK:
		push_warning("[DesktopShell] 置顶线程启动失败（hwnd=%d）" % hwnd)
		return
	_pin_thread = t


func _pin_worker(hwnd: int) -> void:
	# ★ 批次 5：优先用预编译的 SysInfo.exe（子命令 `topmost <hwnd>`），一次 ~40 ms ——
	#   没有 PowerShell 宿主启动、没有现编译 30KB C#、也没有 conhost。
	#   只有 EXE 不在（或退出码非 0）时才退回旧的 pin_topmost.ps1。
	var out: Array = []
	# ★★ 必须是 `Array`，**不能**是 `PackedStringArray`：`OS.execute` 的 `output` 形参类型是
	#    `Array`，传 PackedStringArray 时引擎只在内部临时数组里填结果，调用方这个变量
	#    **永远拿不到输出**（`out` 恒空 → `_topmost_verified` 恒 false，且没有任何报错）。
	#    这是 `_topmost_verified` 长期恒 false 的根因（2026-10-02 批次 5 实测确认）。
	var exe_abs := ProjectSettings.globalize_path(PIN_EXE)
	var code := -1
	if FileAccess.file_exists(exe_abs):
		# 一次调用同时处理「置顶」与「任务栏隐藏」：pin=1（需要则补钉），hideTaskbar 按当前开关。
		code = OS.execute(exe_abs, PackedStringArray([
			"window-style", str(hwnd), "1" if _always_on_top else "0",
			"1" if _hide_from_taskbar else "0"]), out, false)
	if code != 0:
		out = PackedStringArray()
		var args := PackedStringArray([
			"-NoProfile", "-ExecutionPolicy", "Bypass",
			"-File", ProjectSettings.globalize_path(PIN_SCRIPT),
			"-Hwnd", str(hwnd),
		])
		code = OS.execute("powershell.exe", args, out, false)
	# 读回脚本打印的 TOPMOST_OK / TOPMOST_FAIL / TOOLWIN_OK / TOOLWIN_FAIL
	var verified := false
	var toolwin := false
	for line in out:
		if "TOPMOST_OK" in line:
			verified = true
		if "TOOLWIN_OK" in line:
			toolwin = true
	# ★★★ 崩溃修复（2026-10-04 signal 11）：**后台线程里绝不 print、绝不碰引擎日志**。
	#   旧实现在这里直接 `print(...)` 并写 `_topmost_verified`。print 走引擎的全局日志系统，
	#   与主线程并发写（启动/退出期日志文件还在轮转）是 native 崩溃的经典来源。
	#   现在线程只把结果写进 Mutex 保护的槽位，由主线程 _process 统一消费 + 打印。
	_pin_mutex.lock()
	_pin_res_hwnd = hwnd
	_pin_res_code = code
	_pin_res_verified = verified
	_pin_res_toolwin = toolwin
	_pin_res_ready = true
	_pin_mutex.unlock()


## 主线程侧：消费钉顶线程的结果槽（应用验证位 + 打印）。返回 true = 本帧消费了一条。
func _consume_pin_result() -> bool:
	_pin_mutex.lock()
	if not _pin_res_ready:
		_pin_mutex.unlock()
		return false
	_pin_res_ready = false
	var rh := _pin_res_hwnd
	var rc := _pin_res_code
	var rv := _pin_res_verified
	var rt := _pin_res_toolwin
	_pin_mutex.unlock()
	_topmost_verified = rv
	_toolwindow_verified = rt
	print("[DesktopShell] 窗口样式 hwnd=%d 退出码=%d 置顶=%s 任务栏隐藏=%s" % [
		rh, rc, "TOPOK" if rv else "FAIL", "HIDDEN" if rt else "VISIBLE"])
	return true


# 最近一次原生钉顶是否真的把 WS_EX_TOPMOST 写进了系统（调试面板可据此显示真实状态）
func is_topmost_verified() -> bool:
	return _topmost_verified


func _exit_tree() -> void:
	# ★★ 退出顺序：① 先落闩锁（让所有入口立刻早退，不再新起线程/进程）
	#   → ② 最后 join 置顶线程（此时不可能再被重新赋值，join 的对象是确定的）。
	#   ★ 批次 5 起没有常驻守护子进程了，原来的「先杀子进程」这一步随之删除。
	_exiting = true
	if _pin_thread != null:
		# ★★ 必须**无条件** join —— 这里曾经是 `if _pin_thread.is_alive(): wait_to_finish()`，
		#   而 `is_alive()` 在「线程体已跑完但从未 join」时返回 **false** → 直接跳到 `= null`
		#   → 析构一个"完成未被 realize"的 Thread → 退出期刷出
		#   `A Thread object is being destroyed without its completion having been realized.`
		#   （core/os/thread.cpp:116，backtrace 指向本函数）。
		#   线程是否还在跑与是否需要 join 是**两件事**：只要 start() 过就必须 join。
		_pin_thread.wait_to_finish()
		_pin_thread = null


func get_scene_size() -> Vector2i:
	return scene_size


# 主显示器尺寸（像素）—— 优先 sysinfo，其次真实屏幕
func get_primary_resolution() -> Vector2i:
	var size := _resolution_from_sysinfo()
	if size.x <= 0 or size.y <= 0:
		size = DisplayServer.screen_get_size()
	return size


# 桌面工作区（整个场景覆盖的矩形，原点 (0,0)）
# ★ 兜底：`scene_size` 是全局共享量，一旦是 0/负（最小化期间被破坏）会污染所有调用方
#   （桌面屏障、图标边界同步、UI 布局…）→ **绝不**把非法尺寸交出去，退化为主显示器分辨率。
func _safe_scene_size() -> Vector2i:
	if scene_size.x > 0 and scene_size.y > 0:
		return scene_size
	var fallback := get_primary_resolution()
	if fallback.x <= 0 or fallback.y <= 0:
		fallback = Vector2i(1280, 720)
	return fallback


func get_desktop_rect() -> Rect2i:
	return Rect2i(Vector2i.ZERO, _safe_scene_size())


func get_desktop_rect_f() -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(_safe_scene_size()))


# 任务栏贴在哪条边（"bottom"/"top"/"left"/"right"）。查不到 → "bottom"。
# ★★ 数据源优先级：**Godot 原生工作区** → sysinfo.json → "bottom"（见 get_taskbar_thickness）。
func get_taskbar_edge() -> String:
	var nat := _native_taskbar_edge()
	if not nat.is_empty():
		return nat
	_ensure_sysinfo_loaded()
	var tb: Variant = sysinfo.get("taskbar", {})
	if tb is Dictionary:
		var e := str((tb as Dictionary).get("edge", "bottom"))
		if not e.is_empty():
			return e
	return "bottom"


# 任务栏厚度（像素）= 屏幕尺寸 - 工作区尺寸；查不到 / 没有任务栏 → 0。
# 底部任务栏时就是「屏幕底边往上被任务栏占掉多少」。
# ★ 本窗口铺满整个屏幕（含任务栏区域），所以贴底的面板必须自己抬高这么多才不会被任务栏盖住。
# ★ stretch/mode=disabled → 场景坐标 == 屏幕像素，这里的像素值可直接当 UI 单位用。
#
# ★★ 为什么不能只信 sysinfo.json（批次 64 用户反馈「提醒窗跑到屏幕底下」的根因）：
#   sysinfo.json 由 SysInfoRunner 的 PowerShell 子进程**异步**写出。本机安全策略会拦截
#   PowerShell 里的 `Add-Type` → 子进程被直接打断、退出码仍是 0、连 ps1 的兜底 catch 都跑不到
#   → **sysinfo.json 永远不生成** → 厚度恒为 0 → 贴底面版落到屏幕最底、被任务栏盖住。
#   `DisplayServer.screen_get_usable_rect()` 是 Godot 直接问操作系统，**不依赖任何外部文件**，
#   且任务栏被移动/改尺寸后会立刻反映 → 以它为准，sysinfo 只作兜底。
func get_taskbar_thickness() -> float:
	# ① 原生工作区（权威、实时）
	var screen := DisplayServer.get_primary_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	if usable.size.x > 0 and usable.size.y > 0:
		var scr := DisplayServer.screen_get_size(screen)
		var th := maxi(scr.y - usable.size.y, scr.x - usable.size.x)
		if th > 0:
			return float(th)
	# ② sysinfo.json（SysInfo.exe 采集的快照）
	_ensure_sysinfo_loaded()
	var tb: Variant = sysinfo.get("taskbar", {})
	if tb is Dictionary:
		var _th := float((tb as Dictionary).get("height_px", 0.0))
		if _th > 0.0:
			return _th
	return 0.0


# 任务栏几何字典 `{"edge": String, "height_px": float}` —— 贴边面板与任务栏屏障积木共用同一份规则。
func get_taskbar_info() -> Dictionary:
	return { "edge": get_taskbar_edge(), "height_px": get_taskbar_thickness() }


# ★ 批次 124：排除任务栏后的「桌面可用区」矩形（屏幕像素口径，与 get_desktop_rect_f 同坐标系）。
#   供桌面伪装图标积木的网格吸附 bounds 使用 —— 让假图标不会吸附到任务栏条带上（见 desktop.gd::snap_to_desktop_icon）。
# ★ 语义：在整屏 get_desktop_rect_f() 基础上，把任务栏所占的那条「贴边带状区域」整段切掉：
#     bottom → 切掉底部 th 像素；top → 切掉顶部 th 像素；left → 切掉左侧 th 像素；right → 切掉右侧 th 像素。
#   几何与 desktop_barrier.gd::_place_taskbar 的任务栏屏障一致（屏障 1px 贴任务栏内侧），这里切掉的就是屏障外的任务栏本体。
# ★ thickness <= 0（无任务栏 / headless 测不到）→ 退回整屏，行为与旧逻辑一致，不引入回归。
func get_desktop_usable_rect_f() -> Rect2:
	var full := get_desktop_rect_f()
	var th: float = get_taskbar_thickness()
	if th <= 0.0:
		return full
	var edge := get_taskbar_edge()
	match edge:
		"top":
			return Rect2(full.position.x, full.position.y + th, full.size.x, full.size.y - th)
		"left":
			return Rect2(full.position.x + th, full.position.y, full.size.x - th, full.size.y)
		"right":
			return Rect2(full.position.x, full.position.y, full.size.x - th, full.size.y)
		_:  # "bottom" 或未知 → 默认按底部处理
			return Rect2(full.position.x, full.position.y, full.size.x, full.size.y - th)


# 由原生工作区推算任务栏贴边方向（工作区比屏幕少的那一侧）。判定不出 → ""。
func _native_taskbar_edge() -> String:
	var screen := DisplayServer.get_primary_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	if usable.size.x <= 0 or usable.size.y <= 0:
		return ""
	var scr := DisplayServer.screen_get_size(screen)
	var pos := DisplayServer.screen_get_position(screen)
	var dy := scr.y - usable.size.y
	var dx := scr.x - usable.size.x
	if dy > 0 and dy >= dx:
		# 工作区上边被推下去 = 任务栏在顶部；否则在下边
		return "top" if usable.position.y > pos.y else "bottom"
	if dx > 0:
		# 工作区左边被推右 = 任务栏在左侧；否则在右侧
		return "left" if usable.position.x > pos.x else "right"
	return ""


# ★★ 任务栏几何是「贴边面板」的定位依据。sysinfo.json 由 SysInfoRunner 的子进程
#   （gather_sysinfo.ps1 → SysInfo，非阻塞启动）**异步**写出；DesktopShell._ready 那次首读
#   往往文件还没生成 → 缓存 sysinfo 为空 → get_taskbar_thickness() 恒为 0，
#   贴底的提示框 / 对话面板就会落到屏幕底而非任务栏上沿。
#   这里在用到任务栏数据时若缓存里还没有 taskbar 段，重新读一次文件，
#   拿到 SysInfo 写好的最新值（已有则不再读，避免每帧重读）。
func _ensure_sysinfo_loaded() -> void:
	if sysinfo.has("taskbar"):
		return
	var fresh := read_sysinfo()
	if fresh.has("taskbar"):
		sysinfo = fresh


# 读 sysinfo.json（文件不存在 / 解析失败都返回空字典，绝不抛错）
func read_sysinfo() -> Dictionary:
	if sysinfo_path.is_empty():
		return {}
	if not FileAccess.file_exists(sysinfo_path):
		push_warning("[DesktopShell] 未找到 sysinfo.json：%s" % sysinfo_path)
		return {}
	var f := FileAccess.open(sysinfo_path, FileAccess.READ)
	if f == null:
		push_warning("[DesktopShell] sysinfo.json 打不开：%s" % sysinfo_path)
		return {}
	var txt := f.get_as_text()
	f.close()
	var parser := JSON.new()
	if parser.parse(txt) != OK:
		push_warning("[DesktopShell] sysinfo.json 解析失败（第 %d 行）：%s"
			% [parser.get_error_line(), parser.get_error_message()])
		return {}
	var data: Variant = parser.data
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	return data


# ============ 内部 ============

func _resolve_sysinfo_path() -> void:
	# %Documents% 可能被 OneDrive / 系统重定向，必须问系统而不是拼 USERPROFILE
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs.is_empty():
		docs = OS.get_environment("USERPROFILE")
	sysinfo_path = docs.path_join(SYSINFO_SUBDIR)


func _resolution_from_sysinfo() -> Vector2i:
	var scr: Variant = sysinfo.get("screen", null)
	if typeof(scr) != TYPE_DICTIONARY:
		return Vector2i.ZERO
	# 首选主显示器分辨率
	var v := _size_of(scr.get("primary_resolution", null))
	if v.x > 0 and v.y > 0:
		return v
	# 兜底：虚拟屏幕整体范围（多显示器拼接时等于所有屏幕的外接矩形）
	return _size_of(scr.get("virtual_screen", null))


func _size_of(d: Variant) -> Vector2i:
	if typeof(d) != TYPE_DICTIONARY:
		return Vector2i.ZERO
	return Vector2i(int(d.get("width", 0)), int(d.get("height", 0)))


func _apply_geometry(size: Vector2i) -> void:
	if size.x <= 0 or size.y <= 0:
		push_warning("[DesktopShell] 拒绝非法尺寸 %s" % str(size))
		return
	scene_size = size

	# 先取样：后面的窗口改动会影响 screen_get_size 的取值，必须在这之前拿
	var screen_size := _current_screen_size()
	var screen_pos := _current_screen_position()

	# 背景透明：未绘制处 alpha=0（配合 project.godot 的 transparent / per_pixel_transparency）
	var win := get_window()
	if win != null:
		win.transparent_bg = true
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_TRANSPARENT, true)

	# ★ 顺序很关键：先摆好窗口标志，再定模式 / 位置 / 尺寸。
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	_apply_always_on_top()

	# ★★★ 本文件最关键的一次决策 ★★★
	# 要覆盖整屏时，窗口尺寸**必须比屏幕矮 1px**，并且用「无边框窗口」而不是全屏模式。
	#
	# 为什么不能「尺寸 == 屏幕」：Windows 的 GPU 驱动会把「无边框窗口 + 尺寸==屏幕 +
	# 有焦点」自动切成**独占全屏**，而独占全屏会**禁用 DWM 合成器** → 我们渲染的 alpha
	# 被直接丢弃 → 未绘制处变成**纯黑**（失焦后合成器恢复，又变回透明）。
	#   · 官方依据：Godot issue #107582 / #76551（核心开发者 bruvzg 的结论）。
	#   · 本机实测：尺寸==屏幕时 WIN_MODE 会变成 EXCLUSIVE_FULLSCREEN(4)，聚焦即黑屏；
	#     改成屏幕-1 后，聚焦状态下未绘制处的像素与"把窗口藏起来之后的真实背景"完全一致
	#     = 透明确实生效。
	#
	# 为什么不用 WINDOW_MODE_FULLSCREEN：它同样能兼顾透明（也实测通过），但会让
	# window_set_mouse_passthrough（桌面穿透）直接失效 —— 实测一设区域，整个窗口就从
	# EnumWindows 里消失。要"透明 + 穿透"同时成立，只能走「窗口模式 + 矮 1px」：
	# 少掉的是屏幕最底下一行像素，肉眼不可见。
	# ★★ 关键防御：只有**合法的屏幕尺寸**才允许走「矮 1px 覆盖整屏」这条路。
	#   窗口最小化 / 刚创建 / 会话未就绪时 `screen_get_size()` 会返回 0，
	#   而旧写法 `size >= screen_size` 在 screen=(0,0) 时**恒真** → target 算出 (0, -1)
	#   → `window_set_size(0, -1)` 把窗口尺寸设成 0（本机日志实测：
	#   `桌面覆盖尺寸 = 0x-1（请求 2560x1600，模式=最小化…）`）→ 窗口消失、
	#   后续 0 尺寸渲染 + 每帧"恢复失败"循环（见 _restore_after_minimize 的节流注释）。
	var target := compute_window_target(size, screen_size)

	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_position(screen_pos)
	DisplayServer.window_set_size(target)
	scene_size = target

	# ★ 最后再补一次扩展样式：Windows 改窗口模式/尺寸可能清掉 WS_EX_TOPMOST，
	#   置顶/无边框/透明必须放在末尾重设，否则"强制置顶"按 Win+D 时仍会被隐藏。
	_apply_always_on_top()
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_TRANSPARENT, true)

	print("[DesktopShell] 桌面覆盖尺寸 = %dx%d（请求 %dx%d，屏幕=%s，模式=%s，置顶=%s，来源：%s）"
		% [target.x, target.y, size.x, size.y, str(screen_size),
			_mode_name(DisplayServer.window_get_mode()),
			"开" if _always_on_top else "关", sysinfo_path])
	geometry_changed.emit(target)
	# 几何稳定后再原生钉一次置顶（尺寸/位置改动可能重置了 WS_EX_TOPMOST）
	_pin_topmost_native()


## 计算窗口实际要用的尺寸（**纯函数**，便于 headless 单测）。
##   · 屏幕尺寸非法（任一 ≤ 0）→ 直接返回请求尺寸（**绝不**拿不可信的屏幕尺寸做减法）；
##   · 请求尺寸 ≥ 屏幕尺寸 → 返回「屏幕宽 × (屏幕高-1)」：覆盖整屏但比屏幕矮 1px，
##     绕开「无边框窗口 + 尺寸==屏幕」被驱动切成独占全屏（禁用 DWM 合成 → 透明失效变黑屏）的陷阱；
##   · 其余情况 → 原样使用请求尺寸。
static func compute_window_target(size: Vector2i, screen_size: Vector2i) -> Vector2i:
	if size.x <= 0 or size.y <= 0:
		return size                       # 请求本身非法：交给调用方的拒绝逻辑，不在这里造数
	if screen_size.x <= 0 or screen_size.y <= 0:
		return size                       # ★ 屏幕尺寸不可信（最小化/未就绪）→ 保证不产出 0/负尺寸
	if size.x >= screen_size.x and size.y >= screen_size.y:
		var t := Vector2i(screen_size.x, screen_size.y - 1)
		if t.x > 0 and t.y > 0:
			return t
	return size


# ★ `window_get_current_screen()` 在窗口刚创建 / 最小化 / 会话未就绪时可能返回 -1（非法索引）
#   → 直接喂给 screen_get_size 会得到 (0,0) → 触发上面的 (0,-1) 连锁。
#   这里统一夹到 0（主显示器），保证拿到真实屏幕几何。
func _current_screen_index() -> int:
	var idx := DisplayServer.window_get_current_screen()
	var n := DisplayServer.get_screen_count()
	if idx < 0 or (n > 0 and idx >= n):
		idx = 0
	return idx


# 当前窗口所在屏幕的物理分辨率（像素）
func _current_screen_size() -> Vector2i:
	return DisplayServer.screen_get_size(_current_screen_index())


# 当前窗口所在屏幕的左上角坐标
func _current_screen_position() -> Vector2i:
	return DisplayServer.screen_get_position(_current_screen_index())


func _mode_name(mode: int) -> String:
	match mode:
		DisplayServer.WINDOW_MODE_WINDOWED: return "窗口"
		DisplayServer.WINDOW_MODE_MINIMIZED: return "最小化"
		DisplayServer.WINDOW_MODE_MAXIMIZED: return "最大化"
		DisplayServer.WINDOW_MODE_FULLSCREEN: return "合成全屏"
		DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN: return "独占全屏(禁用合成=会黑屏)"
	return "未知(%d)" % mode
