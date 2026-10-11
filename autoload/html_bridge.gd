# autoload/html_bridge.gd
# HTML ↔ 游戏 命令桥接（轮询模式）
#
# 协议：
#   HTML 把所有要执行的命令写成一个 JSON 文件（默认名 html_cmd.json，位于 Temp 目录），
#   并在同目录放一个「标志文件」(默认名 html_cmd.flag) 表示「有待处理命令」。
#   游戏侧（本 autoload）只在 polling=true 时轮询该标志文件；发现后：
#     1) 读取并解析 html_cmd.json 里的 commands 数组，逐条执行；
#     2) 把 html_cmd.json 覆盖成空 JSON（{}）；
#     3) 删除标志文件。
#   轮询开关 polling 默认关，外部通过 set_polling(true/false) 控制；
#   命令里可包含 {"action":"set_poll","value":false} 让游戏自行关闭轮询。
#
# 注意：本脚本作为 autoload 单例（名 HtmlBridge），故不声明 class_name。

extends Node

const CMD_FILE := "html_cmd.json"
const FLAG_FILE := "html_cmd.flag"
# ⚠ 画像文件名已迁到 PlayerProfile.PROFILE_FILE（这里是同一名字，保留仅为兼容旧引用）
const PROFILE_FILE := "player_profile.json"

# 轮询开关（默认关）：只有开着时才轮询标志文件
var polling: bool = false
# 轮询间隔（秒）
var _interval: float = 0.25
var _acc: float = 0.0

# 命令执行信号（便于其它系统消费）
signal command_received(cmd: Dictionary)
signal profile_received(profile: Dictionary)
signal poll_state_changed(on: bool)


func _process(delta: float) -> void:
	if not polling:
		return
	_acc += delta
	if _acc < _interval:
		return
	_acc = 0.0
	_poll_once()


# 设置轮询开关（开/关）。切换会发信号，便于调试面板同步按钮文案。
func set_polling(v: bool) -> void:
	if polling == v:
		return
	polling = v
	poll_state_changed.emit(v)
	print("[HtmlBridge] polling = %s" % v)


# 单次轮询：发现标志文件才处理
func _poll_once() -> void:
	var dir: String = SaveManager.get_temp_dir()
	if dir.is_empty():
		return
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var flag := dir.path_join(FLAG_FILE)
	if not FileAccess.file_exists(flag):
		return
	var cmd_path := dir.path_join(CMD_FILE)
	var cmds := _read_commands(cmd_path)
	for c in cmds:
		_exec(c)
	_write_empty(cmd_path)
	if DirAccess.remove_absolute(flag) != OK:
		push_warning("[HtmlBridge] 无法删除标志文件: " + flag)
	print("[HtmlBridge] 已处理命令文件并清空，标志文件已删除")


# 读取并校验命令 JSON，返回 commands 数组
func _read_commands(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var txt := FileAccess.get_file_as_string(path)
	if txt.strip_edges().is_empty():
		return []
	var p := JSON.new()
	if p.parse(txt) != OK:
		push_error("[HtmlBridge] 命令 JSON 解析失败: " + p.get_error_message())
		return []
	if not (p.data is Dictionary) or not p.data.has("commands"):
		push_warning("[HtmlBridge] 命令 JSON 缺少 commands 数组")
		return []
	return p.data["commands"]


# 把命令文件覆盖成空 JSON（{}）
func _write_empty(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[HtmlBridge] 无法写入空命令文件: " + path)
		return
	f.store_string("{}")
	f.close()


# 执行单条命令
func _exec(cmd: Variant) -> void:
	if not (cmd is Dictionary):
		return
	var action: String = cmd.get("action", "")
	match action:
		"set_profile":
			var data: Variant = cmd.get("data", {})
			_save_profile(data)
			profile_received.emit(data if data is Dictionary else {})
		"set_poll":
			set_polling(bool(cmd.get("value", false)))
		"echo":
			print("[HtmlBridge] echo: " + str(cmd.get("message", "")))
		_:
			push_warning("[HtmlBridge] 未知命令 action: " + str(action))
			command_received.emit(cmd)


# 保存玩家画像：**交给 PlayerProfile 单例**（归一化 + 权重累积 + 落盘集中在一处）。
# ★ 本文件不再自己写 player_profile.json —— 画像数据模型（姓名/生日/地址直接记录，
#   性别/年龄按桶累积权重）统一由 autoload/player_profile.gd 负责，避免两处口径漂移。
func _save_profile(data: Variant) -> void:
	if not (data is Dictionary):
		return
	if PlayerProfile == null or not PlayerProfile.has_method("apply_submission"):
		push_error("[HtmlBridge] PlayerProfile 未就绪，无法保存玩家画像")
		return
	PlayerProfile.apply_submission(data as Dictionary)
