# autoload/nyxel_daily_state.gd
# 荧惑日常状态（Nyxel Daily State）—— 荧惑的每日/日常循环数值与状态标签的唯一真源。
#
# 落盘：%文档%/HelloNyxel/Temp/nyxel_daily_state.json
#
# ★ 数据模型（两条并行子表，均为**扁平顶层键**，便于事件链/控制台直接读写）：
#   · 状态条（bars，数值 0~100，越高越好）：
#       satiety   饱食度   —— 0=饿坏了，100=吃得饱饱的
#       energy    精力     —— 0=精疲力竭，100=精神焕发
#       stamina   体力     —— 0=动弹不得，100=体力充沛
#       alertness 清醒度   —— 0=困得睁不开眼，100=神志清醒
#   · 状态标签集（sets，字符串数组，可增删的「集合类文本」）：
#       mood      心情     —— 如「愉快」「疲惫」「好奇」
#       desire    欲望     —— 如「想吃甜食」「想睡个午觉」
#
# ★ 设计取舍：
#   · 数值统一 0~100（浮点，便于按天/按事件做小数增减），越界一律夹回区间；
#   · 状态条与标签集都用**扁平顶层键**（不做嵌套对象）：StateRegistry 的
#     effective_vars_of 只扫顶层键 → 事件链「效果」编辑器能直接列出这 6 个变量名；
#   · 文件不存在/损坏 → 一律返回**默认满状态**（bars 全 100、标签集为空），
#     表示「新的一天、状态满格」，而不是 0（0 会被误读成「奄奄一息」）；
#   · 本脚本是 autoload 单例（名 NyxelDailyState），故**不声明 class_name**（同名会撞）。
extends Node

const STATE_FILE := "nyxel_daily_state.json"
const VERSION: int = 1

# 状态条数值上限（下限恒为 0）
const BAR_MAX: float = 100.0
# 默认（未初始化 / 重置后）的满状态
const BAR_DEFAULT: float = 100.0

# 状态条键（顺序即页面展示顺序）
const BAR_KEYS: Array[String] = ["satiety", "energy", "stamina", "alertness"]
# 状态标签集键（顺序即页面展示顺序）
const SET_KEYS: Array[String] = ["mood", "desire"]

# 每个标签集最多保留多少条（防无限增长；超出丢弃最早加入的）
const SET_ITEM_LIMIT: int = 16
# 单条标签文本长度上限（防误粘贴超长文本撑爆面板）
const SET_TEXT_MAX: int = 24

# 键 → 中文标签（页面展示 / 调试面板用；键本身保持 ASCII 以便事件链书写）
const BAR_LABELS: Dictionary = {
	"satiety": "饱食度",
	"energy": "精力",
	"stamina": "体力",
	"alertness": "清醒度",
}
const SET_LABELS: Dictionary = {
	"mood": "心情",
	"desire": "欲望",
}

# 状态变化（任何 set_bar / add_bar / 标签增删 / 重置 / 重新读盘）—— 状态页据此实时刷新
signal changed(state: Dictionary)

var _state: Dictionary = {}
var _loaded: bool = false


# ---------------- 读写 ----------------

# 惰性加载：不在 _ready 里读盘（SaveManager 就绪顺序 + 启动零开销）
func load_state() -> Dictionary:
	if not _loaded:
		_state = read_from_disk()
		_loaded = true
	return _state


# 从磁盘读一份**归一化**的状态（纯读，不动缓存；状态页也用这个）
func read_from_disk() -> Dictionary:
	var out := default_state()
	var path := resolve_path()
	if not FileAccess.file_exists(path):
		return out
	var txt := FileAccess.get_file_as_string(path)
	if txt.strip_edges().is_empty():
		return out
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		push_warning("[NyxelDailyState] 状态 JSON 无法解析为对象: " + path)
		return out
	var d: Dictionary = parsed
	# 状态条：只接受已知键，逐个夹到 [0, BAR_MAX]
	for k in BAR_KEYS:
		if d.has(k):
			out[k] = clampf(_to_float(d[k]), 0.0, BAR_MAX)
	# 标签集：只接受已知键，归一化成去重后的字符串数组
	for k in SET_KEYS:
		if d.has(k):
			out[k] = normalize_items(d[k])
	out["updated_at"] = str(d.get("updated_at", ""))
	out["version"] = VERSION
	return out


# 重新读盘并广播（状态页「刷新」按钮 / 外部系统用）
func reload() -> Dictionary:
	_state = read_from_disk()
	_loaded = true
	changed.emit(_state)
	return _state


# 重置为默认满状态（页面「重置」/ 调试用）
func reset() -> Dictionary:
	_state = default_state()
	_loaded = true
	_state["updated_at"] = _now()
	persist()
	changed.emit(_state)
	return _state


func persist() -> Error:
	var path := resolve_path()
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		var err := FileAccess.get_open_error()
		push_error("[NyxelDailyState] 无法写入状态: %s (err=%d)" % [path, err])
		return err
	f.store_string(JSON.stringify(_state, "  "))
	f.close()
	print("[NyxelDailyState] 已写入状态 -> " + path)
	return OK


# ---- 自检：文件残缺 → 按默认值重建 -------------------------------------------
# ★ 由 SaveManager.ensure_temp_files() 在「进入游戏前 / 载入存档前」调用。
# 「残缺」= 文件不存在 / 文本为空 / 无法解析为对象 / 缺关键键 / 容器类型不符。
# 修复时**不丢已有合法字段**（read_from_disk() 已有逐键归一化 + 夹取）。
# 返回是否真的写盘（true = 补建或修复过）。
func ensure_file() -> bool:
	var path := resolve_path()
	var need := true
	if FileAccess.file_exists(path):
		var txt := FileAccess.get_file_as_string(path)
		if not txt.strip_edges().is_empty():
			var parsed: Variant = JSON.parse_string(txt)
			if parsed is Dictionary:
				need = not _state_intact(parsed as Dictionary)
	if not need:
		return false
	_state = read_from_disk()
	_loaded = true
	persist()
	print("[NyxelDailyState] 状态文件残缺 → 已按默认值重建 -> " + path)
	return true


# 4 条状态条必须是数字、2 个标签集必须是数组（缺任一即视为残缺）
static func _state_intact(d: Dictionary) -> bool:
	for k in ["satiety", "energy", "stamina", "alertness"]:
		if not d.has(k):
			return false
		if not (d[k] is float or d[k] is int):
			return false
	for k in ["mood", "desire"]:
		if not d.has(k) or not (d[k] is Array):
			return false
	return true


# ---------------- 对外 API：状态条 ----------------

# 全部状态条（键 → 0~100 浮点）
func bars() -> Dictionary:
	var s := load_state()
	var out := {}
	for k in BAR_KEYS:
		out[k] = float(s.get(k, BAR_DEFAULT))
	return out


# 单个状态条当前值（未知键返回 0）
func get_bar(key: String) -> float:
	return float(load_state().get(key, 0.0))


# 设置状态条（夹到 [0,100]；未知键忽略）。写盘 + 广播。
func set_bar(key: String, value: float) -> void:
	if not (key in BAR_KEYS):
		push_warning("[NyxelDailyState] 未知状态条键: %s" % key)
		return
	var s := load_state()
	var v := clampf(float(value), 0.0, BAR_MAX)
	if is_equal_approx(float(s.get(key, BAR_DEFAULT)), v):
		return
	s[key] = v
	s["updated_at"] = _now()
	persist()
	changed.emit(s)


# 增减状态条（delta 可正可负；结果夹到 [0,100]）。写盘 + 广播。
func add_bar(key: String, delta: float) -> void:
	if not (key in BAR_KEYS):
		push_warning("[NyxelDailyState] 未知状态条键: %s" % key)
		return
	set_bar(key, get_bar(key) + float(delta))


# ---------------- 对外 API：状态标签集 ----------------

# 全部标签集（键 → 字符串数组副本）
func sets() -> Dictionary:
	var s := load_state()
	var out := {}
	for k in SET_KEYS:
		out[k] = normalize_items(s.get(k, []))
	return out


# 单个标签集内容（字符串数组副本；未知键返回空数组）
func get_set(key: String) -> Array:
	return normalize_items(load_state().get(key, []))


# 往标签集加一条（已存在则返回 false，不重复加）。写盘 + 广播。
func add_set_item(key: String, text: String) -> bool:
	if not (key in SET_KEYS):
		push_warning("[NyxelDailyState] 未知标签集键: %s" % key)
		return false
	var t := text.strip_edges()
	if t.is_empty():
		return false
	if t.length() > SET_TEXT_MAX:
		t = t.left(SET_TEXT_MAX)
	var s := load_state()
	var arr := normalize_items(s.get(key, []))
	if t in arr:
		return false
	arr.append(t)
	while arr.size() > SET_ITEM_LIMIT:
		arr.pop_front()
	s[key] = arr
	s["updated_at"] = _now()
	persist()
	changed.emit(s)
	return true


# 从标签集移除一条（不存在返回 false）。写盘 + 广播。
func remove_set_item(key: String, text: String) -> bool:
	if not (key in SET_KEYS):
		return false
	var s := load_state()
	var arr := normalize_items(s.get(key, []))
	var t := text.strip_edges()
	var idx := arr.find(t)
	if idx < 0:
		return false
	arr.remove_at(idx)
	s[key] = arr
	s["updated_at"] = _now()
	persist()
	changed.emit(s)
	return true


# 清空某个标签集（已空则不写盘）
func clear_set(key: String) -> void:
	if not (key in SET_KEYS):
		return
	var s := load_state()
	if normalize_items(s.get(key, [])).is_empty():
		return
	s[key] = []
	s["updated_at"] = _now()
	persist()
	changed.emit(s)


# ---------------- 展示辅助 / 静态常量暴露 ----------------

func bar_label(key: String) -> String:
	return str(BAR_LABELS.get(key, key))


func set_label(key: String) -> String:
	return str(SET_LABELS.get(key, key))


# 公开只读入口（其它脚本用方法取列表，避免依赖「实例访问常量」的写法）
func bar_keys() -> Array[String]:
	return BAR_KEYS.duplicate()


func set_keys() -> Array[String]:
	return SET_KEYS.duplicate()


func bar_max() -> float:
	return BAR_MAX


func default_state() -> Dictionary:
	var out := {
		"version": VERSION,
		"updated_at": "",
	}
	for k in BAR_KEYS:
		out[k] = BAR_DEFAULT
	for k in SET_KEYS:
		out[k] = []
	return out


# 状态文件绝对路径（= %文档%/HelloNyxel/Temp/nyxel_daily_state.json）
func resolve_path() -> String:
	var dir := "D:/Documents/HelloNyxel/Temp"
	if SaveManager != null and SaveManager.has_method("get_temp_dir"):
		dir = str(SaveManager.get_temp_dir())
	return dir.path_join(STATE_FILE)


# ---------------- 归一化工具（探针 / 其它系统可直接调用）----------------

# 任意值 → 去重、去空、限长的字符串数组
func normalize_items(src: Variant) -> Array:
	var out: Array = []
	if not (src is Array):
		return out
	for x in src:
		var t := str(x).strip_edges()
		if t.is_empty():
			continue
		if t.length() > SET_TEXT_MAX:
			t = t.left(SET_TEXT_MAX)
		if not (t in out):
			out.append(t)
	return out


static func _to_float(v: Variant) -> float:
	if v is float or v is int:
		return float(v)
	var s := str(v).strip_edges()
	return float(s) if s.is_valid_float() else 0.0


func _now() -> String:
	return Time.get_datetime_string_from_system(false, true)
