extends Node

# 在 Godot 项目启动时自动执行一次：收集设备系统信息，
# 并写入 %Documents%\HelloNyxel\Temp\sysinfo.json。
# 本脚本作为 AutoLoad 注册（见 project.godot 的 [autoload] 段）。
#
# ★★ 两条路径，**预编译 EXE 优先**（与 TrayRunner / SingleInstance 同一套路）：
#     ① `SysInfo.exe`（build_sysinfo.ps1 编出的纯 C# 可执行文件，无需 Add-Type）
#     ② `gather_sysinfo.ps1`（PowerShell 运行时 Add-Type 编译，兜底）
#   为什么不能只用 ②：本机安全策略会**拦截 PowerShell 里的 Add-Type**（"Add-Type compiles
#   and loads .NET code at runtime"）→ 子进程被直接打断、**退出码仍然是 0**、连 ps1 里的
#   catch 兜底写 error-json 都跑不到 → **sysinfo.json 永远不会生成**，
#   DesktopShell 于是拿不到分辨率 / 任务栏厚度 / 桌面图标（批次 64 的根因之一：
#   右下角提醒窗因此落到屏幕最底、被任务栏盖住）。
const EXE_PATH := "res://addons/hellonyxel_sysinfo/SysInfo.exe"
const SCRIPT_PATH := "res://addons/hellonyxel_sysinfo/gather_sysinfo.ps1"

func _ready() -> void:
	if _run_exe():
		return
	_run_script()


# ① 预编译 EXE：无参调用即「采集系统信息并写 sysinfo.json」。
# ★ 用**绝对 OS 路径**判断存在性（不是 res://）：导出后 res:// 里的 exe 取不到。
func _run_exe() -> bool:
	var exe_abs := ProjectSettings.globalize_path(EXE_PATH)
	if not FileAccess.file_exists(exe_abs):
		push_warning("[SysInfoRunner] 未找到 SysInfo.exe → 回退 PowerShell：%s" % exe_abs)
		return false
	var output: Array = []
	var exit_code := OS.execute(exe_abs, PackedStringArray(), output, false)
	if exit_code == 0:
		print("[SysInfoRunner] 系统信息已生成（SysInfo.exe），退出码: ", exit_code)
		return true
	printerr("[SysInfoRunner] SysInfo.exe 执行失败，退出码: ", exit_code, " 输出: ", output)
	return false


# ② 兜底：PowerShell 运行时编译（需要 Add-Type 权限；被安全策略拦截时会静默失败）。
func _run_script() -> void:
	var abs_script := ProjectSettings.globalize_path(SCRIPT_PATH)
	if not FileAccess.file_exists(abs_script):
		printerr("[SysInfoRunner] 未找到脚本: ", abs_script)
		return
	var args := PackedStringArray(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", abs_script])
	var output: Array = []
	var exit_code := OS.execute("powershell.exe", args, output, false)
	if exit_code == 0:
		print("[SysInfoRunner] 系统信息已生成（PowerShell），退出码: ", exit_code)
	else:
		printerr("[SysInfoRunner] 执行失败，退出码: ", exit_code, " 输出: ", output)
