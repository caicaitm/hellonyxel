# autoload/input_bindings.gd
#
# 「键鼠映射 / 多设备输入」运行时系统（面向未来：鼠标 + 键盘 + 手柄三种设备）。
#
# 设计要点：
#   · 动作集（action）：每个游戏功能一个逻辑动作（左移 / 跳跃 / 交互 …）。
#   · 每个动作对每个「设备」各有一个绑定槽（keyboard / mouse / gamepad），可单独重绑。
#   · 设备级「勾选启用」：某设备未启用时，它的所有绑定在查询里被忽略 →
#       实现「专注某设备时，其它设备的误触不会触发任何动作」。
#   · 落盘到全局 settings.json 的 `input_bindings`（devices + bindings），与其它设置同源，
#     经由 SaveManager，重启保留；加载时以默认集为底、用存档覆盖，缺键不影响存量。
#   · 提供运行时查询 API（is_action_pressed / action_just_pressed / is_device_enabled），
#     供 block.gd 等未来接入；当前本文件只是「存设置 + 提供查询」，不主动改写现有硬编码输入。
#
# ★ 不使用 Godot 内置 InputMap：默认键集是项目自定义的，且需要「按设备分槽 + 设备级开关」，
#   内置 InputMap 表达不了设备级禁用语义，故自管绑定表。
# ★ 不使用 class_name：本脚本以 autoload 名 `InputBindings` 注册为单例，若再声明同名
#   class_name 会与单例同名冲突（"hides an autoload singleton"），导致外部只能按类调用静态方法。
extends Node

# —— 动作定义：id（落盘稳定）+ 显示名 ——
const ACTION_DEFS := [
	["move_left", "左移"],
	["move_right", "右移"],
	["move_up", "上移"],
	["move_down", "下移"],
	["jump", "跳跃"],
	["interact", "交互"],
	["cancel", "取消"],
	["pause", "暂停"],
	["open_settings", "打开设置"],
	["toggle_desktop", "切换桌面"],
]

# —— 设备定义：id（落盘稳定）+ 显示名；顺序即标签页里的展示顺序 ——
const DEVICE_DEFS := [
	["keyboard", "键盘"],
	["mouse", "鼠标"],
	["gamepad", "手柄"],
]

# 内部状态（运行时）：bindings[action][device] = 绑定描述 dict | null
var _bindings: Dictionary = {}
# devices[device] = bool（是否启用）
var _devices: Dictionary = {}

# —— just_pressed 边沿检测（轮询式，兼容未知消费者帧序）——
var _prev_pressed: Dictionary = {}
var _just_pressed: Dictionary = {}


func _ready() -> void:
	reload_settings()


# ---------------- 默认集 ----------------

# 默认绑定：键盘为主，鼠标 / 手柄槽留空（玩家可自行添加）。
func _build_default_bindings() -> Dictionary:
	var b := {}
	b["move_left"] = { "keyboard": _key_rep(KEY_LEFT), "mouse": null, "gamepad": null }
	b["move_right"] = { "keyboard": _key_rep(KEY_RIGHT), "mouse": null, "gamepad": null }
	b["move_up"] = { "keyboard": _key_rep(KEY_UP), "mouse": null, "gamepad": null }
	b["move_down"] = { "keyboard": _key_rep(KEY_DOWN), "mouse": null, "gamepad": null }
	b["jump"] = { "keyboard": _key_rep(KEY_SPACE), "mouse": null, "gamepad": null }
	b["interact"] = { "keyboard": _key_rep(KEY_E), "mouse": null, "gamepad": null }
	b["cancel"] = { "keyboard": _key_rep(KEY_ESCAPE), "mouse": null, "gamepad": null }
	b["pause"] = { "keyboard": _key_rep(KEY_P), "mouse": null, "gamepad": null }
	b["open_settings"] = { "keyboard": _key_rep(KEY_F2), "mouse": null, "gamepad": null }
	b["toggle_desktop"] = { "keyboard": _key_rep(KEY_F3), "mouse": null, "gamepad": null }
	return b


func _key_rep(kc: int) -> Dictionary:
	return { "device": "keyboard", "type": "key", "keycode": int(kc) }


func _build_default_devices() -> Dictionary:
	return { "keyboard": true, "mouse": true, "gamepad": true }


# ---------------- 公开只读访问 ----------------

func get_action_order() -> Array:
	var out := []
	for d in ACTION_DEFS:
		out.append(str(d[0]))
	return out


func get_action_label(action: String) -> String:
	for d in ACTION_DEFS:
		if str(d[0]) == action:
			return str(d[1])
	return action


func get_device_order() -> Array:
	var out := []
	for d in DEVICE_DEFS:
		out.append(str(d[0]))
	return out


func get_device_label(device: String) -> String:
	for d in DEVICE_DEFS:
		if str(d[0]) == device:
			return str(d[1])
	return device


func get_default_bindings() -> Dictionary:
	return _deep_copy(_build_default_bindings())


func get_default_devices() -> Dictionary:
	return _build_default_devices().duplicate()


func get_devices() -> Dictionary:
	return _devices.duplicate()


func get_bindings() -> Dictionary:
	return _deep_copy(_bindings)


func is_device_enabled(device: String) -> bool:
	if not _devices.has(device):
		return true
	return bool(_devices[device])


func get_binding(action: String, device: String):
	if not _bindings.has(action):
		return null
	var ab: Dictionary = _bindings[action]
	if not ab.has(device):
		return null
	return ab[device]


# ---------------- 暂存式修改（由设置面板调用，再 commit） ----------------

func set_devices(d: Dictionary) -> void:
	_devices = d.duplicate()


func set_bindings(b: Dictionary) -> void:
	_bindings = _deep_copy(b)


func set_binding(action: String, device: String, rep: Variant) -> void:
	if not _bindings.has(action):
		return
	if not _bindings[action].has(device):
		return
	_bindings[action][device] = rep if rep != null else null


func clear_binding(action: String, device: String) -> void:
	set_binding(action, device, null)


func reset_defaults() -> void:
	_bindings = _build_default_bindings()
	_devices = _build_default_devices()


# ---------------- 持久化 ----------------

## 从全局 settings.json 读取并合并到默认集（缺键不影响存量；文件缺失则全默认）。
func reload_settings() -> void:
	_bindings = _build_default_bindings()
	_devices = _build_default_devices()
	if SaveManager == null:
		return
	var s: Variant = SaveManager.get_app_settings()
	if typeof(s) != TYPE_DICTIONARY:
		return
	var d: Dictionary = s as Dictionary
	if not d.has("input_bindings"):
		return
	var ib: Variant = d["input_bindings"]
	if typeof(ib) != TYPE_DICTIONARY:
		return
	var ibd: Dictionary = ib as Dictionary
	# 设备开关：只覆盖已知设备
	if ibd.has("devices") and typeof(ibd["devices"]) == TYPE_DICTIONARY:
		var sd: Dictionary = ibd["devices"]
		for dev in _devices:
			if sd.has(dev):
				_devices[dev] = bool(sd[dev])
	# 绑定：逐动作逐设备覆盖（存档里的 null 也会清掉默认）
	if ibd.has("bindings") and typeof(ibd["bindings"]) == TYPE_DICTIONARY:
		var sb: Dictionary = ibd["bindings"]
		for action in _bindings:
			if not sb.has(action):
				continue
			var ab: Variant = sb[action]
			if typeof(ab) != TYPE_DICTIONARY:
				continue
			var abd: Dictionary = ab as Dictionary
			for dev in _bindings[action]:
				if not abd.has(dev):
					continue
				var rep: Variant = abd[dev]
				if typeof(rep) == TYPE_DICTIONARY:
					_bindings[action][dev] = rep as Dictionary
				else:
					_bindings[action][dev] = null


## 把当前 devices + bindings 落盘 settings.json（仅增量合并该键，保留其它设置）。
func commit() -> void:
	if SaveManager == null:
		return
	var ib := { "devices": _devices.duplicate(), "bindings": _deep_copy(_bindings) }
	SaveManager.save_app_settings({ "input_bindings": ib })


# ---------------- 事件 ↔ 可序列化描述 ----------------

## 把一个 InputEvent 转成可 JSON 化的描述 dict；不支持的类型返回 null。
## 只认「按下」类事件（忽略 echo / 松开），避免误绑。
func event_to_dict(event) -> Dictionary:
	if event is InputEventKey:
		var ke: InputEventKey = event as InputEventKey
		if ke.echo or not ke.pressed:
			return {}
		var kc: int = int(ke.physical_keycode) if int(ke.physical_keycode) != 0 else int(ke.keycode)
		return { "device": "keyboard", "type": "key", "keycode": kc }
	if event is InputEventMouseButton:
		var me: InputEventMouseButton = event as InputEventMouseButton
		if not me.pressed:
			return {}
		return { "device": "mouse", "type": "mouse", "button_index": int(me.button_index) }
	if event is InputEventJoypadButton:
		var je: InputEventJoypadButton = event as InputEventJoypadButton
		if not je.pressed:
			return {}
		return { "device": "gamepad", "type": "joypad", "button_index": int(je.button_index) }
	return {}


## 描述 dict → InputEvent（用于未来回放 / 模拟；当前查询走物理状态，不依赖此函数）。
func dict_to_event(rep) -> InputEvent:
	if rep == null or typeof(rep) != TYPE_DICTIONARY:
		return null
	var t: String = str(rep.get("type", ""))
	if t == "key":
		var e: InputEventKey = InputEventKey.new()
		e.keycode = int(rep.get("keycode", 0))
		e.physical_keycode = int(rep.get("keycode", 0))
		return e
	if t == "mouse":
		var e: InputEventMouseButton = InputEventMouseButton.new()
		e.button_index = int(rep.get("button_index", 0))
		return e
	if t == "joypad":
		var e: InputEventJoypadButton = InputEventJoypadButton.new()
		e.button_index = int(rep.get("button_index", 0))
		return e
	return null


## 人类可读的绑定描述（用于设置页按钮文字 / 调试）。
func describe_binding(rep) -> String:
	if rep == null or typeof(rep) != TYPE_DICTIONARY:
		return "—"
	var t: String = str(rep.get("type", ""))
	if t == "key":
		return OS.get_keycode_string(int(rep.get("keycode", 0)))
	if t == "mouse":
		return _mouse_name(int(rep.get("button_index", 0)))
	if t == "joypad":
		return TranslationManager.t("手柄") + " " + str(int(rep.get("button_index", 0)))
	return "?"


func _mouse_name(bi: int) -> String:
	match bi:
		MOUSE_BUTTON_LEFT:
			return TranslationManager.t("鼠标左键")
		MOUSE_BUTTON_RIGHT:
			return TranslationManager.t("鼠标右键")
		MOUSE_BUTTON_MIDDLE:
			return TranslationManager.t("鼠标中键")
		MOUSE_BUTTON_WHEEL_UP:
			return TranslationManager.t("滚轮上")
		MOUSE_BUTTON_WHEEL_DOWN:
			return TranslationManager.t("滚轮下")
		MOUSE_BUTTON_XBUTTON1:
			return TranslationManager.t("鼠标侧键1")
		MOUSE_BUTTON_XBUTTON2:
			return TranslationManager.t("鼠标侧键2")
		_:
			return TranslationManager.t("鼠标键") + " " + str(bi)


# ---------------- 运行时查询 ----------------

## 当前某动作是否被「任意已启用设备」的绑定按住（持续态）。
func is_action_pressed(action: String) -> bool:
	if not _bindings.has(action):
		return false
	var ab: Dictionary = _bindings[action]
	for dev in ab:
		if not is_device_enabled(dev):
			continue
		var rep: Variant = ab[dev]
		if rep != null and typeof(rep) == TYPE_DICTIONARY and _event_pressed(rep as Dictionary):
			return true
	return false


## 某动作本帧是否「刚按下」（边沿）。读后自动消费（同帧二次读为 false）。
## 未读取的边沿会在下次释放→按下时重新置位，不会永久卡死。
func action_just_pressed(action: String) -> bool:
	var v: bool = _just_pressed.get(action, false)
	_just_pressed[action] = false
	return v


## 轮询：每个动作计算当前按下态，并标记本帧新按下的边沿。
func _process(_delta: float) -> void:
	for action in _bindings:
		var cur: bool = is_action_pressed(action)
		if cur and not _prev_pressed.get(action, false):
			_just_pressed[action] = true
		_prev_pressed[action] = cur


# 描述 dict → 当前物理按下态
func _event_pressed(rep: Dictionary) -> bool:
	var t: String = str(rep.get("type", ""))
	if t == "key":
		return Input.is_physical_key_pressed(int(rep.get("keycode", 0)))
	if t == "mouse":
		return Input.is_mouse_button_pressed(int(rep.get("button_index", 0)))
	if t == "joypad":
		var bi: int = int(rep.get("button_index", 0))
		for jid in Input.get_connected_joypads():
			if Input.is_joy_button_pressed(jid, bi):
				return true
	return false


# ---------------- 工具 ----------------

## 深拷贝 bindings（每动作每设备一层 dict）。bindings 内部只有 dict / null，故两层即可。
func _deep_copy(b: Dictionary) -> Dictionary:
	var out := {}
	for action in b:
		var ab: Dictionary = b[action]
		var copy := {}
		for dev in ab:
			var rep: Variant = ab[dev]
			copy[dev] = rep if rep == null else (rep as Dictionary).duplicate()
		out[action] = copy
	return out
