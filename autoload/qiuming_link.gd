# autoload/qiuming_link.gd
# QiumingDLL 桥接层（仅负责「各软件启动情况」= procdetect 进程检测）。
#
# 设计：把 QiumingProc.exe（封装 qiumingdll.dll）的进程检测结果暴露给 GDScript。
#   - EXE / DLL 缺失或调用失败 → available=false / last_ok=false，上层自动回退到
#     原有 PowerShell 进程枚举（PerfMonitor._running_processes），游戏照常工作。
#   - 这实现了「QiumingDLL 接手进程检测、SysInfo 继续负责窗口/时间/屏幕」的分工。
#
# 调用方：
#   QiumingLink.available  /  QiumingLink.last_ok   （状态查询）
#   QiumingLink.refresh(process_names: Array)        （BusyState 每个 tick 调一次）
#   QiumingLink.is_process_running(name: String) -> bool
#
# ★ 注意：窗口位置/大小/时间 不由 QiumingDLL 提供（它不枚举其它窗口、也不读时区），
#   这些仍由 SysInfo C# EXE / Godot Time 负责，本桥接不处理。

extends Node

const EXE_PATH := "res://addons/hellonyxel_qiuming/QiumingProc.exe"

# DLL + EXE 能加载并跑通 version → true；否则 false（回退 PowerShell）
var available: bool = false
# 最近一次 refresh 是否成功取到数据 → 若 procdetect 函数名错/调用失败，置 false 让上层回退
var last_ok: bool = false
# 最近一次 refresh 的「小写进程名(去 .exe) -> true」
var _running: Dictionary = {}


func _ready() -> void:
	_check_exe()


# 探测可用性：EXE 存在 + version 命令不报 ERR
func _check_exe() -> void:
	var exe_abs := ProjectSettings.globalize_path(EXE_PATH)
	if not FileAccess.file_exists(exe_abs):
		available = false
		return
	var out: Array = []
	var rc := OS.execute(exe_abs, PackedStringArray(["version"]), out, false)
	var txt := "".join(PackedStringArray(out)).strip_edges()
	available = (rc == 0 and not txt.begins_with("ERR"))
	if not available:
		print("[QiumingLink] 不可用（rc=%d, %s）→ 进程检测回退 PowerShell" % [rc, txt])
	else:
		print("[QiumingLink] 可用（version=%s）→ 进程检测走 QiumingDLL" % txt)


# 用 EXE 批量刷新「指定进程名」的运行状态（BusyState 每个 tick 调一次）。
# process_names: 任意可遍历集合，元素为进程名（可带或不带 .exe）。
func refresh(process_names: Array) -> void:
	if not available:
		last_ok = false
		return
	var exe_abs := ProjectSettings.globalize_path(EXE_PATH)
	var joined := ""
	for n in process_names:
		var s := str(n).strip_edges()
		if s.is_empty():
			continue
		joined += s + "|"
	joined = joined.trim_suffix("|")
	if joined.is_empty():
		last_ok = false
		return
	var out: Array = []
	var rc := OS.execute(exe_abs, PackedStringArray(["procs", joined]), out, false)
	var txt := "".join(PackedStringArray(out)).strip_edges()
	if rc != 0 or txt.begins_with("ERR"):
		last_ok = false
		return
	var parsed := {}
	var got := 0
	for line in txt.split("\n"):
		line = line.strip_edges()
		if line.is_empty():
			continue
		var kv := line.split(":")
		if kv.size() >= 2 and kv[1] == "1":
			parsed[kv[0].strip_edges()] = true
			got += 1
	_running = parsed
	last_ok = got > 0


func is_process_running(name: String) -> bool:
	if not (available and last_ok):
		return false
	var n := str(name).strip_edges().to_lower()
	if n.ends_with(".exe"):
		n = n.substr(0, n.length() - 4)
	return _running.has(n)
