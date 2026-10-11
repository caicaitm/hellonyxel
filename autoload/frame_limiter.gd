extends Node
## 帧率上限 + 按需渲染（性能优化的核心开关）
##
## 【为什么需要】
##   本窗口是一张**铺满全屏的逐像素透明覆盖层**。即使桌面完全静止，引擎每帧仍要
##   整屏重绘 + 交给 DWM 重新合成 —— Godot 的 gl_compatibility 渲染器没有"局部重绘"，
##   "画面没变"≠"没在画"。
##   实测（165Hz 屏、垂直同步开启）：默认会跑满 165 FPS，godot 进程吃掉 0.9~1.4 核、
##   GPU 8~11%、笔记本风扇明显起转；同一场景 `--max-fps 30` 降到 0.22 核、`--max-fps 15`
##   降到 0.17 核。也就是说 godot 侧约 85% 的 CPU 只是"帧数"的函数。
##
## 【策略：两档】
##   · 活跃档 = 用户在设置页选的「帧率上限」（0 = 不限制）。
##   · 空闲档 = ECO_FPS（15）。满足**全部**下列"确实空闲"条件才降档：
##       1) 距上一次输入（鼠标移动/按键）已超过 BOOST_SEC；
##       2) 没有按住任何鼠标键（拖拽中）；
##       3) 引擎里没有未结束的 Tween（屏幕上确实有动画在跑）；
##       4) 启动宽限期（STARTUP_GRACE_SEC）已过。
##   桌面覆盖层在空闲时**本来就没有任何东西在变化**，降档不会被看见；
##   一旦有输入（鼠标移到积木/面板上、按键、对话框…）立刻回到用户设定值。
##
## 【为什么用"输入"当信号】
##   桌面穿透开启时，鼠标落在**没有任何积木/UI 的空白桌面**上会被系统直接转发给桌面，
##   Godot 收不到事件 → 自动处于空闲档；只有移到真正可交互的内容上才会收到事件 → 提档。
##   这个语义恰好就是我们想要的（"没人跟游戏交互"=省钱）。
##
## 【关闭方式】
##   环境变量 `HELLONYXEL_NO_FPS_CAP=1` → 完全跳过限帧（保持引擎默认，便于对照测试）。

## 空闲档帧率。★ 不要再往下调：15 是"操作起来不顿"的下限经验值
##   （拖拽积木 / 开关面板时需要 1~2 帧内响应，15FPS ≈ 67ms/帧）。
const ECO_FPS: int = 15

## 一次输入把"活跃档"维持多久（秒）。取 2.0 是为了让连续操作（拖拽、连续点击）
## 之间不出现"中途掉回空闲档"的抖动。
const BOOST_SEC: float = 2.0

## 启动后先按活跃档跑这么久（秒）：启动期有大量建积木 / 场景枚举的收尾工作，
## 此时降到 15FPS 会把启动拖长。
const STARTUP_GRACE_SEC: float = 3.0

## 检测到「有 Tween 在跑」时，把活跃档续这么久（秒）。
## 【为什么需要】空闲降档只在"屏幕上没东西在变"时才安全。本项目里**唯一**的逐帧
##   动画是通知面板的淡入淡出（全项目只有 ui/notification_panel.gd 用了 create_tween），
##   它在没有任何输入的情况下也会跑 —— 若此时停在 15FPS，淡入淡出会明显卡成幻灯片。
##   所以只要引擎里还有未结束的 Tween，就维持活跃档。
const ANIM_BOOST_SEC: float = 0.5

## 每隔几帧才去查一次"有没有 Tween 在跑"（get_processed_tweens() 会分配一个数组，
## 满帧时不必每帧都问；4 帧 ≈ 空闲档 264ms / 活跃档 24ms，远小于 ANIM_BOOST_SEC）。
const ANIM_CHECK_EVERY: int = 4

var _cap: int = 60                 # 用户设定（0 = 不限制）
var _boost_left: float = STARTUP_GRACE_SEC
var _applied: int = -1             # 最近一次写进 Engine.max_fps 的值
var _disabled: bool = false        # 由环境变量强制关闭
var _anim_tick: int = 0            # 动画检测节流计数器


func _ready() -> void:
	_disabled = OS.get_environment("HELLONYXEL_NO_FPS_CAP") == "1"
	if _disabled:
		print("[FrameLimiter] 已由 HELLONYXEL_NO_FPS_CAP=1 强制关闭（不做任何限帧）")
		set_process(false)
		set_process_input(false)
		return
	# 输入监听：任何鼠标 / 按键事件都算"活跃"
	set_process_input(true)
	# 用户设置（SaveManager 是唯一权威；此处已在其之后 autoload，能直接读）
	if SaveManager != null:
		_cap = SaveManager.get_max_fps()
		if not SaveManager.max_fps_changed.is_connected(_on_cap_changed):
			SaveManager.max_fps_changed.connect(_on_cap_changed)
	_apply_now()
	print("[FrameLimiter] 就绪 上限=%s 空闲档=%d 活跃维持=%.1fs（无输入时自动降到空闲档）"
		% [_cap_text(), ECO_FPS, BOOST_SEC])


## 用户在设置页改了上限 → 立刻按新值生效（并当作一次"活跃"）
func _on_cap_changed(fps: int) -> void:
	_cap = fps
	print("[FrameLimiter] 帧率上限已改为 %s" % _cap_text())
	request_boost()


## 请求提到活跃档。默认维持 BOOST_SEC 秒。
## 供业务侧调用（例如：场景枚举发现窗口变化、面板开关、通知弹出）。
func request_boost(sec: float = BOOST_SEC) -> void:
	if _disabled:
		return
	_boost_left = maxf(_boost_left, sec)
	_apply_now()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion or event is InputEventMouseButton or event is InputEventKey:
		request_boost()


func _process(delta: float) -> void:
	if _boost_left > 0.0:
		_boost_left = maxf(0.0, _boost_left - delta)
	# 有 Tween 在跑 = 屏幕上确实有动画 → 续活跃档（见 ANIM_BOOST_SEC 注释）
	_anim_tick += 1
	if _anim_tick >= ANIM_CHECK_EVERY:
		_anim_tick = 0
		var tr := get_tree()
		if tr != null and not tr.get_processed_tweens().is_empty():
			request_boost(ANIM_BOOST_SEC)
	_apply_now()


## 按住任意鼠标键（拖拽 / 长按）→ 不降档。
## 【为什么必须单独判】拖拽过程中鼠标**可能静止不动**（握着不动、或缓慢移动），
##   此时既没有新事件、也可能已经超过 BOOST_SEC → 会掉到空闲档，下一次移动要等
##   最多 67ms 才被处理 → 表现为"积木跟不上光标"。用**轮询**而不是记住按下/松开事件，
##   是为了自愈：即使松开事件丢了（鼠标移出窗口等）也不会永久卡在活跃档。
func _button_held() -> bool:
	return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
		or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) \
		or Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE)


## 目标帧率：活跃档 = 上限（0 = 不限制，写 0 即引擎语义"不限"）；空闲档 = ECO_FPS。
func _target_fps() -> int:
	if _boost_left > 0.0 or _button_held():
		return _cap
	return ECO_FPS


func _apply_now() -> void:
	var t := _target_fps()
	if t == _applied:
		return
	_applied = t
	Engine.max_fps = t
	# 只在**档位真的改变**时出声，且走 print_verbose → 默认静默，加 --verbose 才看得到
	# （用于验证"空闲降档 / 输入提档"是否按预期发生，不污染正常运行日志）。
	print_verbose("[FrameLimiter] 帧率上限 -> %s" % _fps_text(t))


## 当前实际生效的帧率上限写值（0 = 不限制）。供自测量面板 / 设置页显示。
func get_applied_fps() -> int:
	return _applied


func _cap_text() -> String:
	return _fps_text(_cap)


func _fps_text(v: int) -> String:
	return "不限制" if v == 0 else "%d" % v
