extends Node
# 单实例守卫：只允许一个游戏进程。第二个实例**自己退出**，并把已有实例的窗口顶到前台。
#
# 需求背景（玩家反馈）：手抖双击图标会开出两个游戏 → 两个透明全屏覆盖层互相打架
#   （争抢置顶、抢鼠标穿透区域、两份存档写入）。这里从根上堵住。
#
# ── 架构（为什么不是"读个 PID 文件就完事"）────────────────────────────
# 判据交给**预编译的 SysInfo.exe**（`single-instance` / `single-instance-hold`），
# 由它做两件 GDScript 做不到也不该做的事：
#   ① 内核级原子仲裁（CreateMutex / CreateFile）—— 两个实例**同一秒**启动也不会都当自己是一手；
#   ② 探测"陈旧锁"（锁文件里的 PID 是否还活着）—— 玩家强杀 / 崩溃后不会永久开不了游戏。
#
# ★★ 持锁者必须是**长生命周期**进程：命名 mutex 与文件句柄都是进程级内核对象，
#   创建它们的进程一退出内核就回收。所以 `hold` 子进程会一直活着，直到本进程消失
#   （与托盘看门狗同一套生命周期论证，不新增常驻进程种类）。
#   一次性 `single-instance` 调用**拿不到锁**（实测两次调用都是 FIRST）。
#
# ★ headless / 自动化验证**必须放行**：否则四道门的 headless 主场景冒烟会被自己的
#   另一个实例挡掉。判定用 DisplayServer.get_name() == "headless"，与 TrayRunner 同源。
# ★ HELLONYXEL_NO_SINGLEINSTANCE=1 也可显式关掉（跑基准测试时用）。

const SI_EXE := "res://addons/hellonyxel_sysinfo/SysInfo.exe"
const SI_SCRIPT := "res://addons/hellonyxel_sysinfo/SysInfo.ps1"   # 兜底（EXE 缺失时）
const MUTEX_NAME := "HelloNyxel.SingleInstance.v1"
const LOCK_NAME := "hello_nyxel.instance.lock"
const INFO_NAME := "hello_nyxel.instance.info"
const SI_SUBDIR := "HelloNyxel"          # 与 SaveManager.get_temp_dir() 同源（%文档%\HelloNyxel\Temp）

## true = 本实例是唯一的那个（持锁成功）；false = 已有实例，本进程应立刻退出。
var is_primary: bool = true
## 已有实例的 PID（is_primary == false 时有效），0 = 未知。
var existing_pid: int = 0
## 退出时打一行日志，便于玩家/开发确认"第二个实例是被拦下的"。
var blocked: bool = false

var _lock_path := ""
var _info_path := ""
var _exe_warned := false


func _ready() -> void:
	# ---- 1) 放行条件：headless（自动化验证）/ 非 Windows / 显式关闭 ----
	if not OS.has_feature("windows"):
		return
	if DisplayServer.get_name() == "headless":
		return
	if OS.get_environment("HELLONYXEL_NO_SINGLEINSTANCE") == "1":
		print("[SingleInstance] HELLONYXEL_NO_SINGLEINSTANCE=1 → 跳过单实例检查")
		return

	var tmp := _temp_dir()
	_lock_path = tmp.path_join(LOCK_NAME)
	_info_path = tmp.path_join(INFO_NAME)

	# ---- 2) 抢锁（一次性判定：这一关就能决定是不是首个实例）----
	var verdict := _claim_once()
	if verdict.begins_with("SECOND"):
		is_primary = false
		blocked = true
		var parts := verdict.split(" ")
		if parts.size() >= 2:
			existing_pid = int(parts[1])
		print("[SingleInstance] 检测到已有游戏实例（pid=%d）→ 本实例退出（手抖双击已拦截）"
			% existing_pid)
		# 立刻退出：早于任何 autoload 的实质工作（建积木 / 枚举窗口 / 拉托盘）
		get_tree().quit()
		return

	# ---- 3) 拿到锁 → 拉起持锁子进程，让锁活到本进程结束 ----
	#    ★ 这里**必须等**：create_process 只是"启动"子进程，返回时它还没跑完抢锁动作
	#    （实测立刻回读锁得到 false）。而如果不等，第二个实例就能在持锁者就位前抢进来。
	await _spawn_holder()
	print("[SingleInstance] 本实例为唯一实例（pid=%d）" % OS.get_process_id())


# ---------------------------------------------------------------- 内部

func _temp_dir() -> String:
	# %Documents% 可能被 OneDrive / 系统重定向，必须问系统（与 DesktopShell 同一理由）
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs.is_empty():
		docs = OS.get_environment("USERPROFILE")
	var tmp := docs.path_join(SI_SUBDIR).path_join("Temp")
	if not DirAccess.dir_exists_absolute(tmp):
		DirAccess.make_dir_recursive_absolute(tmp)
	return tmp


# 跑一次 `SysInfo.exe single-instance`，返回 FIRST / SECOND <pid> <hwnd>。
func _claim_once() -> String:
	var out: Array = []
	var exe_abs := ProjectSettings.globalize_path(SI_EXE)
	# ★ 用**绝对 OS 路径**判断存在性（不是 res://）：导出后 res:// 里的 exe 取不到。
	if FileAccess.file_exists(exe_abs):
		var code := OS.execute(exe_abs, PackedStringArray([
			"single-instance", MUTEX_NAME, _lock_path, _info_path, str(OS.get_process_id()),
		]), out, false)
		if code == 0 and not out.is_empty():
			return String(out[0]).strip_edges()
		if not _exe_warned:
			_exe_warned = true
			push_warning("[SingleInstance] SysInfo.exe single-instance 失败（退出码 %d）→ 放行（宁可多开）" % code)
		return "FIRST"
	# EXE 缺失：不做单实例拦截（游戏照常能开），只提示一次。
	if not _exe_warned:
		_exe_warned = true
		push_warning("[SingleInstance] 未找到 SysInfo.exe（先跑 addons/hellonyxel_sysinfo/build_sysinfo.ps1）→ 跳过单实例检查")
	return "FIRST"


# 拉起持锁子进程并**等它把锁占住**。它会一直活到本进程消失，届时内核自动回收锁。
func _spawn_holder() -> void:
	var exe_abs := ProjectSettings.globalize_path(SI_EXE)
	if not FileAccess.file_exists(exe_abs):
		push_warning("[SingleInstance] 持锁子进程无法拉起（缺 SysInfo.exe）→ 本次运行期间不保证单实例")
		return
	var args := PackedStringArray([
		"single-instance-hold", MUTEX_NAME, _lock_path, _info_path, str(OS.get_process_id()),
	])
	# ★ 走 create_process（不等待子进程结束）：持锁者必须与本进程**并行存活**。
	#   OS.execute 会阻塞到子进程结束 —— 那样会直接卡死游戏主线程。
	var pid := OS.create_process(exe_abs, args, false)
	if pid <= 0:
		push_warning("[SingleInstance] 持锁子进程拉起失败（create_process 返回 %d）→ 本次运行期间不保证单实例" % pid)
		return
	# 等它把锁占住。
	# ★ 这一步不是"保险"，是**必需**：持锁者启动有几十毫秒的进程创建开销，这段时间里
	#   锁是空的 → 第二个实例会抢进来（实测踩过：第二实例照样报"唯一实例"）。
	# ★ 探测**最多做几次**而不是每帧做：`lock-probe` 每次都是一个 SysInfo.exe 进程
	#   （~40 ms），每帧轮询会把这个 autoload 的等待拉得很长。
	await _wait_for_lock(pid)


func _wait_for_lock(pid: int) -> void:
	var tries := 0
	while tries < 12:
		if _probe_locked():
			print("[SingleInstance] 持锁子进程 pid=%d 已占住锁（第 %d 次探测）" % [pid, tries + 1])
			return
		tries += 1
		await get_tree().create_timer(0.1).timeout
	push_warning("[SingleInstance] 持锁子进程（pid=%d）未占住锁（探测 %d 次）→ 可能有第二个实例进入"
		% [pid, tries])


# 锁是否已被持锁者占住？
# ★ **不能**用 Godot 的 FileAccess 去试：实测 `FileAccess.open(path, READ_WRITE)` 在
#   Windows 上**不独占**（同进程二次打开会成功并覆盖内容）→ 永远返回"没锁"。
#   只能问 SysInfo.exe —— 它用与持锁者**同一个 Win32 访问掩码**试，判据才一致。
#   `lock-probe` 是**只读**的：不抢锁、不写任何东西，纯查询。
func _probe_locked() -> bool:
	var exe_abs := ProjectSettings.globalize_path(SI_EXE)
	if not FileAccess.file_exists(exe_abs):
		return false
	var out: Array = []
	var code := OS.execute(exe_abs, PackedStringArray(["lock-probe", _lock_path]), out, false)
	if code != 0 or out.is_empty():
		return false
	return String(out[0]).strip_edges() == "LOCKED"
