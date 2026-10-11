# 玩家性能占用监控（全局单例 autoload「PerfMonitor」）。
#
# 目的：读取玩家机器的 CPU / 内存 / 显存 占用百分比，供后续判断「玩家是否在忙」
#      （机器是否处于高负载），并显示在调试面板里。
#
# 采样策略：
#   - 默认每分钟（SAMPLE_INTERVAL 秒）采样一次 —— 足够判断「是否在忙」，又不频繁打扰系统。
#   - 显存用量走 Godot 的 RenderingServer（必须在主线程读）；
#     系统 CPU / 物理内存占用百分比、显存总量走一次 PowerShell 查询，放在独立 Thread 里跑，
#     避免每 60s 卡主线程（否则采样本身就会造成卡顿，反而干扰「是否在忙」的判断）。
#
# 字段说明（均为「总占用」视角，即占该资源总量的百分比）：
#   cpu_percent   系统 CPU 总占用 %
#   mem_percent   系统物理内存已用 %
#   mem_used_mb / mem_total_mb   物理内存（MB）
#   vram_percent  显存已用 %（vram_used_mb / vram_total_mb）
#   vram_used_mb  由 RenderingServer 读的当前显存占用（MB）
#   vram_total_mb 由 WMI 读的显卡显存总量（MB，近似；集显可能为共享内存或 0）
#
# 非 Windows 平台（Linux/macOS 导出等）：PowerShell 不可用，仅保留显存与提示；
# 本项目为 Steam / Windows，主路径是 Windows。
#
# 进程辅助检测：每次系统采样（PowerShell 线程里）同时采集「当前运行进程名集合」，
# 供忙闲面板做「检测到某进程即加分」的辅助判断（见 perf_busy_panel.gd）。
# 判定为二值——进程名存在即可（大小写不敏感，自动忽略尾随 .exe）。
#
# 公开 API：
#   PerfMonitor.perf_updated 信号（每次采样结束，含 ok/error）
#   PerfMonitor.is_player_busy(cpu_th=80, mem_th=85, vram_th=90) -> bool
#   PerfMonitor.is_process_running(name) -> bool   进程是否正在运行（大小写不敏感）
#   PerfMonitor.running_process_names() -> Dictionary   最近一次采到的进程名集合(小写->true)
#   PerfMonitor.force_sample() 立即触发一次采样（测试 / 外部调用）

extends Node

# 采样周期（秒）：每分钟一次
const SAMPLE_INTERVAL: float = 60.0

# ---- 最新快照（调试面板 / 判断逻辑直接读这些字段）----
var cpu_percent: float = 0.0
var mem_used_mb: float = 0.0
var mem_total_mb: float = 0.0
var mem_percent: float = 0.0
var vram_used_mb: float = 0.0
var vram_total_mb: float = 0.0
var vram_percent: float = 0.0

# 采样状态：true=最近一次成功；false=失败（见 last_error）
var last_sample_ok: bool = false
var last_error: String = ""

# 最近一次系统采样采到的「运行进程名集合」（小写名 -> true）。
# 在 _on_system_done（主线程）里整体重新赋值，主线程读它的 .has() 安全无竞态。
var _running_processes: Dictionary = {}

# 每次采样结束（无论成败）发射，参数为快照 Dictionary
signal perf_updated(snapshot: Dictionary)

var _timer: Timer = null
var _thread: Thread = null
var _busy: bool = false

func _ready() -> void:
	_timer = Timer.new()
	_timer.name = "PerfSampleTimer"
	_timer.wait_time = SAMPLE_INTERVAL
	_timer.one_shot = true
	_timer.timeout.connect(_on_timer)
	add_child(_timer)
	# 启动后尽快采一次（不干等满 60s），其余靠 _timer 周期触发
	call_deferred("_on_timer")


# 立即触发一次采样（重复调用若上一次未结束则忽略，避免线程叠加）
func force_sample() -> void:
	_on_timer()


func _on_timer() -> void:
	if _busy:
		_arm_timer()
		return
	_busy = true
	# ★ 显存用量必须在主线程读（RenderingServer 相关）
	if DisplayServer.get_name() != "headless":
		var used: int = int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED))
		vram_used_mb = used / 1e6
	else:
		vram_used_mb = 0.0
	# 系统侧（CPU / 内存 / 显存总量）放独立线程，避免卡主线程
	# ★★ 不变式：`_thread != null` ⟹ 该 Thread **一定 start() 成功**（失败就当场置 null）。
	#   保证 _on_system_done / _exit_tree 里的 `wait_to_finish()` 永远作用于已启动的线程。
	var t := Thread.new()
	if t.start(_sample_system) != OK:
		push_warning("[PerfMonitor] 采样线程启动失败，本轮跳过")
		_thread = null
		_busy = false
		_arm_timer()
		return
	_thread = t


# 线程入口：执行 PowerShell 采集 CPU / 内存 / 显存总量。
# 输出格式（单行，逗号分隔）： cpu,memUsedMb,memTotalMb,memPct,vramTotalMb
func _sample_system() -> void:
	var result: Dictionary = {"ok": false, "err": ""}
	if OS.get_name() != "Windows":
		result.err = "非 Windows 平台：跳过系统采样（仅显存可用）"
		call_deferred("_on_system_done", result)
		return
	var out: Array = []
	var rc: int = OS.execute("powershell.exe",
		["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", _PS_SCRIPT], out)
	if rc != 0 or out.is_empty():
		result.err = "PowerShell 退出码=%d（无输出或执行失败）" % rc
		call_deferred("_on_system_done", result)
		return
	# OS.execute 把整个 stdout 作为单个字符串放进 out[0]（按换行分隔多行），
	# 故 metrics 在首行、进程名列表在次行。
	var raw: String = str(out[0])
	var raw_lines: PackedStringArray = raw.split("\n")
	var line: String = raw_lines[0].strip_edges() if raw_lines.size() > 0 else ""
	var parts: PackedStringArray = line.split(",")
	if parts.size() < 5:
		result.err = "输出格式异常: %s" % line
		call_deferred("_on_system_done", result)
		return
	# 解析时逐个 try，避免某一项 NaN 拖累整体
	var vals: PackedFloat64Array = PackedFloat64Array()
	for p in parts.slice(0, 5):
		var f: float = float(str(p).strip_edges())
		vals.append(f)
	result.ok = true
	result["cpu"] = vals[0]
	result["mem_used"] = vals[1]
	result["mem_total"] = vals[2]
	result["mem_pct"] = vals[3]
	result["vram_total"] = vals[4]
	# 进程名列表：同一脚本顺带采集，次行为 | 分隔的进程名
	var pset: Dictionary = {}
	if raw_lines.size() >= 2:
		var plist: PackedStringArray = raw_lines[1].strip_edges().split("|")
		for pn in plist:
			var p := str(pn).strip_edges().to_lower()
			if not p.is_empty():
				pset[p] = true
	result["processes"] = pset
	call_deferred("_on_system_done", result)


func _on_system_done(result: Dictionary) -> void:
	_busy = false
	if _thread != null and is_instance_valid(_thread):
		_thread.wait_to_finish()
		_thread = null
	if result.get("ok", false):
		cpu_percent = result["cpu"]
		mem_used_mb = result["mem_used"]
		mem_total_mb = result["mem_total"]
		mem_percent = result["mem_pct"]
		vram_total_mb = result["vram_total"]
		if vram_total_mb > 0.0 and vram_used_mb > 0.0:
			vram_percent = vram_used_mb / vram_total_mb * 100.0
		else:
			vram_percent = 0.0
		last_sample_ok = true
		last_error = ""
	else:
		last_sample_ok = false
		last_error = result.get("err", "unknown")
	# 进程名集合整体重新赋值（主线程读 .has() 安全）
	_running_processes = result.get("processes", {})
	var snap: Dictionary = {
		"cpu_percent": cpu_percent,
		"mem_used_mb": mem_used_mb,
		"mem_total_mb": mem_total_mb,
		"mem_percent": mem_percent,
		"vram_used_mb": vram_used_mb,
		"vram_total_mb": vram_total_mb,
		"vram_percent": vram_percent,
		"ok": last_sample_ok,
		"error": last_error,
	}
	perf_updated.emit(snap)
	_arm_timer()


func _arm_timer() -> void:
	if _timer != null and is_instance_valid(_timer):
		_timer.start()


# ---------------- 自测量（批次 1）：子系统计时累加器 ----------------
#
# 目的：回答「性能消耗到哪里去了」—— 把若干子系统的耗时按帧累加，供自测量面板显示。
#
# ★★ 零开销约定：**只有自测量面板打开时才计时**。
#   面板打开 → 调 begin_profiling()；关闭 → end_profiling()。关闭时：
#     · `profiling` 为 false → 所有调用点的 `if PerfMonitor.profiling:` 闸门直接跳过
#       （连一次 Time.get_ticks_usec() 都不发）
#     · Block._draw 走的是 Block 自己的 static 标志（每帧可能被 400+ 块各调一次，
#       用 static 字段读，避免每块都去做一次 autoload 查找）
#
# ★ 汇总口径 = **每帧平均**（滚动窗口 WINDOW_FRAMES 帧），不是"最后一帧"：
#   最后一帧抖动太大，40~60 fps 下也看不出趋势。面板按 ~4 Hz 显示平均值。

const PROFILE_WINDOW_FRAMES: int = 60    # 滚动窗口长度（约 1~1.3 s @ 45~60 fps）

var profiling: bool = false              # ★ 调用点唯一闸门（见上方零开销约定）

var _span_acc: Dictionary = {}           # 窗口内累加（名字 → 微秒）
var _span_frames: int = 0                # 窗口内已累计帧数
var _span_avg: Dictionary = {}           # 窗口结算结果（名字 → 每帧平均微秒）
var _last_frame_usec: int = 0            # 最近一次结算的每帧平均帧时长
var _frame_usec_acc: int = 0             # 窗口内帧时长累加


# 面板打开时调用：清零并开闸
func begin_profiling() -> void:
	_span_acc.clear()
	_span_avg.clear()
	_span_frames = 0
	_frame_usec_acc = 0
	_last_frame_usec = 0
	profiling = true


# 面板关闭时调用：关闸并释放累加数据
func end_profiling() -> void:
	profiling = false
	_span_acc.clear()
	_span_avg.clear()
	_span_frames = 0
	_frame_usec_acc = 0
	_last_frame_usec = 0


# 累加一次子系统耗时（微秒）。调用点应先过 `profiling` 闸门。
func add_span(name: String, usec: int) -> void:
	if not profiling:
		return
	_span_acc[name] = int(_span_acc.get(name, 0)) + usec


# 面板每帧调用一次：把本帧帧时长并入窗口；满一窗就结算成"每帧平均"。
func commit_frame(frame_usec: int) -> void:
	if not profiling:
		return
	_frame_usec_acc += frame_usec
	_span_frames += 1
	if _span_frames < PROFILE_WINDOW_FRAMES:
		return
	var avg: Dictionary = {}
	for k in _span_acc:
		avg[k] = float(_span_acc[k]) / float(_span_frames)
	_span_avg = avg
	_last_frame_usec = _frame_usec_acc / _span_frames
	_span_acc.clear()
	_span_frames = 0
	_frame_usec_acc = 0


# 最近一次结算的「每帧平均子系统耗时（微秒）」（面板读）
func span_avg() -> Dictionary:
	return _span_avg


# 最近一次结算的「每帧平均帧时长（微秒）」
func last_frame_usec() -> int:
	return _last_frame_usec


# 当前窗口已累计的原始耗时（微秒）—— 面板首次打开时先显示这个，避免等满一窗才出数
func span_acc() -> Dictionary:
	return _span_acc


# ---------------- 进程树轻量读取（面板用；走预编译 SysInfo.exe，不起 PowerShell）----------------

# 最近一次 subtree 结果（Dictionary；空 = 还没取到）
var child_tree: Dictionary = {}
var child_tree_ok: bool = false
var child_tree_err: String = ""
var _tree_thread: Thread = null
var _tree_busy: bool = false

# 请求一次「本进程树」快照（异步，不阻塞主线程；上一次没结束就跳过）。
# 结果落在 child_tree / child_tree_ok / child_tree_err。
func request_child_tree() -> void:
	if _tree_busy:
		return
	var exe_abs := ProjectSettings.globalize_path("res://addons/hellonyxel_sysinfo/SysInfo.exe")
	if not FileAccess.file_exists(exe_abs):
		child_tree_ok = false
		child_tree_err = "未找到 SysInfo.exe"
		return
	_tree_busy = true
	# ★★ 不变式：`_tree_thread != null` ⟹ start() 成功（失败当场置 null）
	var t := Thread.new()
	if t.start(_child_tree_worker.bind(exe_abs)) != OK:
		_tree_busy = false
		child_tree_ok = false
		child_tree_err = "subtree 线程启动失败"
		return
	_tree_thread = t


func _child_tree_worker(exe_abs: String) -> void:
	var out: Array = []   # ★★ 必须是 Array（OS.execute 的 output 形参类型）
	var code := OS.execute(exe_abs, PackedStringArray(["subtree", str(OS.get_process_id())]), out, false)
	var parsed: Dictionary = {}
	var ok := false
	var err := ""
	if code != 0 or out.is_empty():
		err = "SysInfo.exe subtree 退出码=%d（输出 %d 行）" % [code, out.size()]
	else:
		var txt := "\n".join(PackedStringArray(out)).strip_edges()
		var v = JSON.parse_string(txt)
		if v is Dictionary:
			parsed = v
			ok = not parsed.has("error")
			if not ok:
				err = str(parsed.get("error", ""))
		else:
			err = "subtree 输出不是 JSON: %s" % txt.left(120)
	call_deferred("_on_child_tree_done", parsed, ok, err)


func _on_child_tree_done(parsed: Dictionary, ok: bool, err: String) -> void:
	# ★★ 出口无条件 join（不变式保证线程一定 start 过）
	if _tree_thread != null:
		_tree_thread.wait_to_finish()
		_tree_thread = null
	_tree_busy = false
	child_tree = parsed
	child_tree_ok = ok
	child_tree_err = err


func _exit_tree() -> void:
	# ★★ 退出时无条件回收采样线程：若正巧在采样中退出，`_on_system_done`（call_deferred）
	#   可能还没跑到 → Thread 未被 join → `~Thread` 刷
	#   "destroyed without its completion having been realized"（甚至在原生层与
	#   PowerShell 子进程同拆时引发段错）。这里补上退出兜底 join。
	#   不变式保证：`_thread != null` ⟹ start() 成功 ⟹ wait_to_finish() 合法。
	if _timer != null and is_instance_valid(_timer):
		_timer.stop()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	# ★★ 同样无条件回收「进程树快照」线程（批次 1 新增）：出口必须覆盖**所有**启动过的线程，
	#   否则 `~Thread` 会刷 "destroyed without its completion having been realized"。
	if _tree_thread != null:
		_tree_thread.wait_to_finish()
		_tree_thread = null
	_busy = false
	_tree_busy = false


# 判断玩家是否「忙」（机器高负载）。
# 任一资源超过阈值即视为忙；数据不可用时保守返回 false（不误判）。
func is_player_busy(cpu_thresh: float = 80.0, mem_thresh: float = 85.0, vram_thresh: float = 90.0) -> bool:
	if not last_sample_ok:
		return false
	return cpu_percent >= cpu_thresh or mem_percent >= mem_thresh or vram_percent >= vram_thresh


# ---------------- 加权「电脑性能使用分数」模型（供忙闲面板 / 事件链复用）----------------

# 读取某项资源当前总占用%（key ∈ "cpu" / "mem" / "vram"）；非法 key 返 0。
func metric_percent(key: String) -> float:
	match key:
		"cpu":
			return cpu_percent
		"mem":
			return mem_percent
		"vram":
			return vram_percent
	return 0.0


# 计算「电脑性能使用分数」：对每项资源，超过判断线的百分比乘以权重后求和。
#   thresholds / weights：{cpu, mem, vram} 浮点（判断线 0~100、权重任意非负更合理）。
#   公式：score = Σ max(0, 当前% - 判断线) × 权重
# 未采样成功（last_sample_ok=false）时返回 -1.0，调用方据此显示「数据不可用」而非误判。
func compute_busy_score(thresholds: Dictionary, weights: Dictionary) -> float:
	if not last_sample_ok:
		return -1.0
	var score := 0.0
	for key in ["cpu", "mem", "vram"]:
		var cur: float = metric_percent(key)
		var over: float = cur - float(thresholds.get(key, 0.0))
		if over > 0.0:
			score += over * float(weights.get(key, 1.0))
	return score


# ---------------- 进程辅助检测（供忙闲面板「检测到进程即加分」）----------------

# 进程是否正在运行：大小写不敏感，自动忽略尾随 .exe（如 "chrome" / "CHROME.EXE" 等价）。
# 未采样成功（_running_processes 为空）时一律返回 false。
func is_process_running(name: String) -> bool:
	var n := str(name).strip_edges().to_lower()
	if n.ends_with(".exe"):
		n = n.substr(0, n.length() - 4)
	return _running_processes.has(n)


# 最近一次采到的运行进程名集合（小写名 -> true）；仅用于调试 / 排查。
func running_process_names() -> Dictionary:
	return _running_processes


# PowerShell 脚本（单行）。读系统 CPU 总占用、物理内存已用/总量、显存总量，
# 最后 Write-Output 一行逗号分隔的结果。
# 路径里的 `\\%` 在 GDScript 字符串里是「反斜杠 + 百分号」，PowerShell 单引号内原样保留。
const _PS_SCRIPT: String = \
	"$cpu=(Get-Counter '\\Processor(_Total)\\% Processor Time').CounterSamples.CookedValue;" + \
	"$os=Get-CimInstance Win32_OperatingSystem;" + \
	"$mt=[math]::Round($os.TotalVisibleMemorySize/1KB,1);" + \
	"$mf=[math]::Round($os.FreePhysicalMemory/1KB,1);" + \
	"$mu=[math]::Round($mt-$mf,1);" + \
	"$mp=[math]::Round(($mu/$mt)*100,1);" + \
	"$gpu=Get-CimInstance Win32_VideoController|Select-Object -First 1;" + \
	"$vt=[math]::Round($gpu.AdapterRAM/1MB,1);" + \
	"$pl=@(Get-Process|Select-Object -ExpandProperty ProcessName);" + \
	"$ps=($pl -join '|');" + \
	"Write-Output ('{0},{1},{2},{3},{4}' -f $cpu,$mu,$mt,$mp,$vt);" + \
	"Write-Output $ps"
