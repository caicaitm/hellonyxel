# autoload/devices.gd
# 设备系统（独立于背包）的持久化与逻辑层 —— 单例（autoload 名：Devices）。
#
# 设计要点：
#   · 设备 = 一台「电脑/设备」，每个外壳就是一个设备。记录单独落到
#     %文档%/HelloNyxel/Temp/devices.json（不进背包 inventory.json）。
#   · 设备字典结构：
#       { "id": "dev_xxx", "name": "我的笔记本", "online": bool,
#         "attrs": { "part_type": "case", "chassis_type": "laptop",
#                    "config": { slot_key: <内嵌零件 dict> } } }
#     config 里直接内嵌零件 dict（整套 {id,name,count,category,tags,description,attrs}），
#     不再引用背包 id —— 已安装的零件「不在背包里」，而以设备的形式存在。
#   · 安装：从背包备件里取一份拷贝内嵌进设备，并扣减背包对应零件数量；
#     移除/拆解：把内嵌零件退回背包（数量 +1 / 新建条目）。
#   · 在线设备：背包页据此提供硬盘容量（Devices.total_storage_capacity）；
#     设备管理页据此显示「占用功率」。
#   · 所有代码标识符 / 标签 / attrs 键一律英文；仅 UI 展示串用中文。
extends Node
# ★ 本脚本作为 autoload 单例（名 Devices），故不声明 class_name（否则与 autoload 名冲突：
#   "Class 'Devices' hides an autoload singleton"）。外部一律用全局名 Devices.xxx 访问。

signal changed

const DEVICES_FILE := "devices.json"

# 内嵌零件的 config 槽位键，与 PCHardware 槽位类型保持一致（slot_type + 数字索引）
const SLOT_MAINBOARD := "mainboard"
const SLOT_CPU := "cpu"
const SLOT_MEMORY := "memory"
const SLOT_GPU := "gpu"
const SLOT_STORAGE := "storage"
const SLOT_NIC := "nic"
const SLOT_PSU := "psu"
const SLOT_COOLER := "cooler"
## ★ 已经没有「拓展」槽位了（拓展件按规格+协议插进普通槽）；这个常量只留给旧存档迁移用。
const SLOT_EXPANSION_LEGACY := "expansion"

var _devices := {}   # id -> 设备 dict（get_device 返回其引用，改完需 _persist）
var _seed_ver: int = 0   # 设备内嵌零件属性已刷新到第几批模板（PCHardware.HW_SEED_VERSION）
var _main_id: String = ""   # ★ 主力设备 id（全局唯一；仅电脑类可担任；其余设备须与之连通才能上线）
# ★★ 批次 96：本文件里「不认识的顶层键」原样保管，_persist 时写回。
#    原因：本系统是「内存模型 → 整份重建外壳」的写法，不认识的键会被无声丢掉 ——
#    而 StateRegistry 的状态标签（tags）正是写在这个文件顶层的另一个键上。
var _extra: Dictionary = {}
# ★ 一次性迁移标记：是否已把开局设备从旧版 7 台裁到 3 台（见 _migrate_trim_seed_devices）。
var _seed_trimmed: bool = false


# ---------------------------------------------------------------------------
# 开局设备（批次 40 起：**仅 3 台**）
# ---------------------------------------------------------------------------
## ★ 旧版「开局预置」的 4 台电脑 / 工作站 + 扫描重构器。现在不再生成；
##   老存档启动时按 id 一次性清掉（见 _migrate_trim_seed_devices）。
const LEGACY_SEED_DROP_IDS := [
	"dev_desktop_matx", "dev_desktop_atx", "dev_workstation", "dev_scanner",
]

## 旧版那台笔记本的「槽位键 -> 零件模板 id」。老存档里的 dev_laptop 若仍与这份
## 配置**逐项一致**（说明玩家没改装过）→ 按新模板降级；改装过则原样保留。
const LEGACY_SEED_LAPTOP_CONFIG := {
	"mainboard0": "mb_laptop", "cpu0": "cpu_laptop_r7",
	"memory0": "ram_ddr5_16", "memory1": "ram_ddr5_16",
	"gpu0": "gpu_laptop_4060", "storage0": "ssd_m2_1t",
	"nic0": "nic_laptop_m2", "cooler0": "cooler_laptop", "psu0": "psu_sfx_300",
}


func _ready() -> void:
	load_from_disk()
	if _devices.is_empty():
		seed_devices()
	# 旧模型把电脑当背包物品（带 case 标签）；迁移时清掉，避免背包里残留「电脑」条目。
	_cleanup_legacy_case_items()
	# ★ 开局设备裁到 3 台：老存档按 id 清掉旧版预置的台式机 / 工作站 / 扫描重构器，
	#   并把「没被玩家改装过的」笔记本按新模板降级。
	_migrate_trim_seed_devices()
	# 内嵌零件属性刷新（模板代码改了，devices.json 里存的是旧拷贝）
	_migrate_part_attrs()
	# 设备种类迁移（老存档无 device_kind → 电脑；网络器材补自带 port_specs）
	_migrate_device_kind()
	# ★ 槽位模型变了：不再有「拓展」槽位 → 旧存档里 expansionN 上的拓展件（及其接口上的零件）卸下退回背包。
	#   必须放在 _migrate_part_attrs 之后（要先拿到刷新过的零件属性）。
	_migrate_drop_expansion_slots()
	# 上线硬规则：①必须满足「最基本硬件组成 + 可用网卡」才能在线；②尽量保留至少一台在线。
	_normalize_online_state()
	# 链接自检：零件被拆掉后，网卡带来的无线口会消失 → 那条链接/对端反向链接都要清掉。
	validate_links()
	# 「电脑文件」特殊物品：设备就绪后显式同步一次（种子/迁移路径不 emit changed，
	# 后续变化由 Inventory 订阅 Devices.changed 接管）。
	if Inventory != null:
		Inventory.sync_computer_files()


## 迁移：给老设备补上 `device_kind`（缺省 = 电脑），并给网络器材补自带 `port_specs`。
## 幂等：跑过一次后 attrs 里就都有这些键了。
func _migrate_device_kind() -> void:
	var touched := 0
	for id in _devices.keys():
		var dev: Dictionary = _devices[id]
		if not (dev is Dictionary):
			continue
		var ca: Dictionary = dev.get("attrs", {})
		if not (ca is Dictionary):
			ca = {}
		var changed := false
		var kind := str(ca.get("device_kind", ""))
		if kind == "":
			ca["device_kind"] = PCHardware.KIND_COMPUTER
			kind = PCHardware.KIND_COMPUTER
			changed = true
		if PCHardware.is_net_kind(kind):
			var specs = ca.get("port_specs", null)
			if not (specs is Array) or (specs as Array).is_empty():
				ca["port_specs"] = PCHardware.kind_port_specs(kind)
				changed = true
			if kind == PCHardware.KIND_SWITCH and not ca.has("global_net"):
				ca["global_net"] = false
				changed = true
		if changed:
			dev["attrs"] = ca
			touched += 1
	if touched > 0:
		_persist()
		print("[Devices] 已迁移 %d 台设备的 device_kind / port_specs" % touched)


# ---------------------------------------------------------------------------
# 持久化
# ---------------------------------------------------------------------------
func _temp_path() -> String:
	var dir := ""
	if SaveManager != null:
		dir = SaveManager.get_temp_dir()
	else:
		var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
		if docs.is_empty():
			docs = OS.get_environment("USERPROFILE")
		dir = docs.path_join("HelloNyxel/Temp")
	return dir.path_join(DEVICES_FILE)


func load_from_disk() -> void:
	var path := _temp_path()
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var data = JSON.parse_string(txt)
	if not (data is Dictionary):
		return
	_seed_ver = int(data.get("hw_seed_ver", 0))
	_main_id = str(data.get("main_device_id", ""))
	_seed_trimmed = bool(data.get("seed_trimmed", false))
	# ★ 批次 96：先把「不认识的顶层键」收进 _extra（键名与下面 _persist 的写出表一一对应）
	_extra = {}
	for k in data.keys():
		var ks := str(k)
		if ks == "hw_seed_ver" or ks == "main_device_id" or ks == "seed_trimmed" or ks == "devices":
			continue
		_extra[ks] = data[ks]
	var arr = data.get("devices", [])
	if not (arr is Array):
		return
	for d in arr:
		if d is Dictionary and d.has("id"):
			_devices[str(d["id"])] = d
	_migrate_chassis_attrs()


# 迁移：旧设备 attrs 缺外壳属性（replaceable / max_mb_ff / max_gpu_len_mm / max_psu_ff）
# → 从 chassis_type 补齐，否则 is_compatible 会拒绝安装/替换除主板外的任何零件。
func _migrate_chassis_attrs() -> void:
	var dirty := false
	for id in _devices.keys():
		var dev: Dictionary = _devices[id]
		if not (dev is Dictionary):
			continue
		var ca: Dictionary = dev.get("attrs", {})
		if not (ca is Dictionary):
			ca = {}
		# ★ 网络器材（扫描重构器 / 交换机 / 无线网络发生器）**没有机箱概念**：
		#   不能并入 chassis_attrs("") 的桌面属性（那会把 replaceable 取并集补满 → 变成「可装零件」）。
		if PCHardware.is_net_kind(PCHardware.device_kind(dev)):
			continue
		var merged: Dictionary = PCHardware.chassis_attrs(str(ca.get("chassis_type", "")))
		if merged.is_empty():
			continue
		var changed := false
		for k in merged.keys():
			if not ca.has(k):        # 保留已有 part_type / chassis_type / config
				ca[k] = merged[k]
				changed = true
		# ★ replaceable 必须**取并集**：老存档是在旧代码下写的，可能缺后加的槽位类型
		#   （例如外设槽 peripheral），缺了就会被 is_compatible 判成「不可更换」→ 选择器里永远没有备件。
		var want = merged.get("replaceable", null)
		var have = ca.get("replaceable", null)
		if want is Array:
			if not (have is Array):
				ca["replaceable"] = (want as Array).duplicate()
				changed = true
			else:
				var cur: Array = []
				for r in (have as Array):
					cur.append(str(r))
				var out: Array = (have as Array).duplicate()
				for r2 in (want as Array):
					if not cur.has(str(r2)):
						out.append(r2)
						changed = true
				if changed:
					ca["replaceable"] = out
		if changed:
			dev["attrs"] = ca
			dirty = true
	if dirty:
		_persist()
		print("[Devices] 已迁移设备外壳属性（replaceable / max_*_ff）")


## ★ 内嵌零件属性刷新：模板代码改了（例如给主板加 external_ports / peripheral_slots、
## 给笔记本主板开拓展槽），devices.json 里存的仍是旧拷贝 → 用当前模板覆盖一遍。
## 只按 id 刷新零件，不动槽位键与设备自身属性。
func _migrate_part_attrs() -> void:
	if _seed_ver >= PCHardware.HW_SEED_VERSION:
		return
	var n := 0
	for id in _devices.keys():
		var cfg = _devices[id].get("attrs", {}).get("config", {})
		if not (cfg is Dictionary):
			continue
		for k in cfg.keys():
			var p = cfg[k]
			if not (p is Dictionary):
				continue
			var pid := str((p as Dictionary).get("id", ""))
			var tp: Dictionary = PCHardware.get_part_template(pid)
			if tp.is_empty():
				continue
			if PCHardware._dict_same((p as Dictionary).get("attrs", {}), tp.get("attrs", {})):
				continue
			cfg[k] = tp.duplicate(true)
			n += 1
	_seed_ver = PCHardware.HW_SEED_VERSION
	_persist()
	if n > 0:
		print("[Devices] 已用模板刷新 %d 个内嵌零件属性（hw_seed_ver=%d）" % [n, _seed_ver])


func _persist() -> void:
	var path := _temp_path()
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var arr: Array = []
	for d in _devices.values():
		arr.append(d)
	var out := {
		"hw_seed_ver": _seed_ver, "seed_trimmed": _seed_trimmed,
		"main_device_id": _main_id, "devices": arr,
	}
	# ★ 批次 96：带上原先就在文件里的「不认识的顶层键」（如 StateRegistry 写的状态标签），
	#   否则设备系统每保存一次就把它们抹掉一次。
	for k in _extra:
		if not out.has(str(k)):
			out[str(k)] = _extra[k]
	var txt := JSON.stringify(out)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(txt)
		f.close()


# ---- 自检：文件残缺 → 按默认值（开局 3 台种子设备）重建 ------------------------
# ★ 由 SaveManager.ensure_temp_files() 在「进入游戏前 / 载入存档前」调用。
# ★★ 判据**刻意保守**：只要 devices.json 能解析成对象、且 devices 是数组，就认为「完整」——
#    绝不因缺个别元数据键（hw_seed_ver / main_device_id / seed_trimmed）而重建，
#    否则会把玩家辛苦配好的设备整份冲掉（那些缺键由 load_from_disk / 迁移逻辑自行兜底）。
# 只有整份不可用（不存在 / 空 / 解析失败 / devices 不是数组）才退回种子默认。
# 返回是否真的写盘（true = 补建或修复过）。
func ensure_file() -> bool:
	var path := _temp_path()
	var need := true
	if FileAccess.file_exists(path):
		var txt := FileAccess.get_file_as_string(path)
		if not txt.strip_edges().is_empty():
			var parsed: Variant = JSON.parse_string(txt)
			if parsed is Dictionary:
				need = not _devices_file_intact(parsed as Dictionary)
	if not need:
		return false
	_devices = {}
	_seed_ver = 0
	_main_id = ""
	_seed_trimmed = false
	seed_devices()
	print("[Devices] 设备文件残缺 → 已按开局默认重建 -> " + path)
	return true


static func _devices_file_intact(d: Dictionary) -> bool:
	return d.has("devices") and (d["devices"] is Array)


# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------
func get_devices() -> Array:
	return _devices.values()


func get_device(id: String) -> Dictionary:
	return _devices.get(id, {})


func has_device(id: String) -> bool:
	return _devices.has(id)


func device_count() -> int:
	return _devices.size()


# ---------------------------------------------------------------------------
# 设备生命周期
# ---------------------------------------------------------------------------
func create_device(chassis_type: String, kind: String = PCHardware.KIND_COMPUTER) -> String:
	var id := _new_id()
	var k := str(kind)
	if k == "":
		k = PCHardware.KIND_COMPUTER
	var name := _unique_name(PCHardware.kind_zh(k) if PCHardware.is_net_kind(k) else "新设备")
	# ★ 外壳属性（replaceable / max_mb_ff / max_gpu_len_mm / max_psu_ff）必须并入设备 attrs，
	#   否则 is_compatible 会因缺 replaceable 而拒绝安装除主板外的任何零件。
	#   ★ 网络器材走 kind_attrs：replaceable 为空 + 自带 port_specs（不做零件）。
	var attrs: Dictionary = PCHardware.kind_attrs(k, str(chassis_type))
	if attrs.is_empty():
		attrs = { "part_type": "case", "chassis_type": str(chassis_type) }
	if not attrs.has("device_kind"):
		attrs["device_kind"] = k
	attrs["config"] = {}
	var dev := {
		"id": id,
		"name": name,
		"online": false,
		"attrs": attrs,
	}
	# ★ 网络器材自带硬件、开箱即在线（不做零件 → 没有「装不齐硬件」的问题）。
	if PCHardware.is_net_kind(k):
		dev["online"] = true
	_devices[id] = dev
	_persist()
	changed.emit()
	return id


func rename(id: String, name: String) -> void:
	var dev := get_device(id)
	if dev.is_empty():
		return
	dev["name"] = str(name)
	_persist()
	changed.emit()


## 上线前置检查（不改状态）。返回 "" = 可以上线；否则返回中文原因。
## 条件：主板 / CPU / 内存 / 电源（最基本硬件组成）+ 一块可用网卡。
## ★ 另加：设了主力设备后，还必须与主力设备「直接或间接链接」才允许上线。
func online_block_reason(id: String) -> String:
	var dev := get_device(id)
	if dev.is_empty():
		return "设备不存在"
	var req: Dictionary = PCHardware.online_requirement(dev)
	if not bool(req.get("ok", false)):
		return str(req.get("reason", "硬件不满足上线条件"))
	# ★ 主力设备连通性：没设主力设备则不设防；主力设备自己恒可。
	if _main_id != "" and str(id) != _main_id and not linked_to_main(id):
		var mname := str(get_device(_main_id).get("name", _main_id))
		return "必须与主力设备「%s」直接或间接链接才能上线" % mname
	return ""


## 上线/下线。
##   · 上线：先过 online_block_reason（缺硬件 / 未与主力设备链接 → 失败返回 false）。
##   · 下线：★ 至少保留一台在线 —— 把最后一台在线设备下线会失败（返回 false）。
##   · 下线：★ 主力设备不能下线。
func set_online(id: String, on: bool) -> bool:
	var dev := get_device(id)
	if dev.is_empty():
		return false
	if on and online_block_reason(id) != "":
		return false
	if not on:
		# ★ 主力设备不可下线
		if is_main_device(id):
			return false
		if bool(dev.get("online", false)) and online_count() <= 1:
			return false
	dev["online"] = on
	# ★ 交换机下线 → 自动断开「全球网络」（没下线的设备不动）。
	#   语义：交换机离线就等于没接在世界上，硬留着 global_net=true 会让
	#   `GlobalNet.is_on_global_network()` 把它算成可达 → 其它设备误判「已上全球网络」。
	if not on:
		_auto_drop_global_net(id)
		# ★★ 下线会改变「链接图上的在线性」→ 必须重跑连通性不变式，让**依赖它的那批设备跟着下线**。
		#   例：主力 --交换机-- 电脑，交换机一下线，那台电脑就与主力断连 →
		#   `_enforce_main_connectivity()` 把它（以及任何其它因此失去连通的在线设备）一并下线。
		#   ★ 这一步是「交换机下线连带下线」需求的唯一实现点；漏了就会出现
		#   「交换机已离线，其它设备却还在线」的非法状态（它们既不连通也不下线）。
		#   主力设备自己不在其列（它不能下线），故「至少保留一台在线」的不变式天然成立。
		_enforce_main_connectivity()
	_persist()
	changed.emit()
	return true


## ★ 交换机下线时自动断开其「全球网络」连接（非交换机 / 本来就没接 → 不动）。
##   幂等：只写 true→false 的那一跳，返回值表示是否真的改了。
func _auto_drop_global_net(dev_id: String) -> bool:
	var dev := get_device(dev_id)
	if dev.is_empty():
		return false
	if PCHardware.device_kind(dev) != PCHardware.KIND_SWITCH:
		return false
	var ca = dev.get("attrs", {})
	if not (ca is Dictionary):
		return false
	if not bool((ca as Dictionary).get("global_net", false)):
		return false
	(ca as Dictionary)["global_net"] = false
	dev["attrs"] = ca
	return true


## 当前在线设备数量
func online_count() -> int:
	var n := 0
	for d in _devices.values():
		if bool(d.get("online", false)):
			n += 1
	return n


# ---------------------------------------------------------------------------
# ★「主力设备」（全局唯一）
# ---------------------------------------------------------------------------
# 规则：
#   · 只有 **笔记本 / 台式机 / 工作站**（电脑类，device_kind == KIND_COMPUTER）能当主力设备；
#     网络器材（扫描重构器 / 交换机 / 无线网络发生器）不能当。
#   · 主力设备**不能下线**、**不能拆解**。
#   · 其它设备必须与主力设备「直接或间接链接」（沿对外接口的链接图连通）才能上线；
#     主力设备自己视为连通（它是根）。
#   · 设备名显示时前面加一颗黄色星星（UI 层负责，数据层只暴露 main_device_id / is_main_device）。

## 主力设备 id（没设置 = 空串）
func main_device_id() -> String:
	return _main_id


## 某设备是否就是当前主力设备
func is_main_device(dev_id: String) -> bool:
	return _main_id != "" and str(dev_id) == _main_id


## 能否把该设备设为主力设备：必须是电脑类（笔记本/台式机/工作站）。返回 ""=可以，否则中文原因。
func main_set_block_reason(dev_id: String) -> String:
	var dev := get_device(dev_id)
	if dev.is_empty():
		return "设备不存在"
	if PCHardware.is_net_kind(PCHardware.device_kind(dev)):
		return "只有笔记本 / 台式机 / 工作站可以设为主力设备"
	return ""


## 设置 / 取消主力设备。传空串 = 取消。返回 ""=成功，否则中文原因。
## 取消或改选后，若原主力设备不再满足「在线」的其他规则，交由调用方决定是否下线；
## 这里只负责改标记 + 落盘。为避免「取消主力后原主力立刻掉线」的手感突变，取消时**不自动下线**。
func set_main_device(dev_id: String) -> String:
	var id := str(dev_id)
	if id == "":
		if _main_id == "":
			return ""
		_main_id = ""
		_persist()
		changed.emit()
		return ""
	var block := main_set_block_reason(id)
	if block != "":
		return block
	_main_id = id
	# 设了主力设备后，维持连通性不变式：原先在线但与新主力设备不连通的设备强制下线
	# （主力设备自己不受影响、保持在线）。
	_enforce_main_connectivity()
	_persist()
	changed.emit()
	return ""


## 沿「对外接口链接」做一次 DFS，返回从 from_id 能到达的所有设备 id 集合（含自身）。
## 直接或间接链接 = 在这张无向图上连通（link 是双向占用的，所以按无向图走）。
##
## ★★ 批次 16：**只经过在线设备**。信号要真的能「通」到目标，中间每一台设备都必须在线
##   （典型：电脑 --eth-- 交换机 --eth-- 电脑，交换机下线则两端互不通）。
##
## ★★ `allow_id` = 允许「即使离线也能走进」的节点，只应传**目标设备自己**。
##   为什么必须有它：判定「能不能上线」时，目标此刻本来就是离线的（否则无需上线）。
##   若不豁免目标，则「把一台离线设备拉上线」会先卡在「到不了它自己」→
##   `online_block_reason` 永远非空 → **它永远上不了线**（死锁）。
##   豁免目标 ≠ 豁免中转：A --(B 离线)-- C 想让 C 上线时，B 仍是断点 → C 上不了，正确。
##   起点 from_id（主力设备）无需豁免：它在起点位置、天然已在 seen 里。
func _link_reachable(from_id: String, allow_id: String = "") -> Dictionary:
	var seen: Dictionary = {}
	if from_id == "" or not _devices.has(from_id):
		return seen
	# 邻接表：device -> [peer...]（来自 PCHardware.port_links）
	var adj: Dictionary = {}
	for d in _devices.values():
		var did := str(d.get("id", ""))
		adj[did] = []
		for lk in PCHardware.port_links(d):
			var peer := str((lk as Dictionary).get("peer_id", ""))
			if peer != "" and _devices.has(peer):
				(adj[did] as Array).append(peer)
	var stack: Array = [from_id]
	seen[from_id] = true
	while not stack.is_empty():
		var cur: String = str(stack.pop_back())
		for nb in (adj.get(cur, []) as Array):
			var n := str(nb)
			if seen.has(n):
				continue
			# ★ 中转设备必须在线才继续往下走；目标设备（allow_id）豁免。
			if n != allow_id and not _is_online(n):
				continue
			seen[n] = true
			stack.append(n)
	return seen


## 设备是否在线（内部小工具；不存在 → false）
func _is_online(dev_id: String) -> bool:
	var d = _devices.get(dev_id, null)
	if d is Dictionary:
		return bool((d as Dictionary).get("online", false))
	return false


## 某设备是否与主力设备「直接或间接链接」连通。
##   · 没设主力设备 → 恒 true（不设防）。
##   · 是主力设备自己 → 恒 true（根节点）。
##   · 否则按链接图连通，且**路径上所有中转设备都在线**（目标自己豁免，见 _link_reachable 注释）。
func linked_to_main(dev_id: String) -> bool:
	if _main_id == "":
		return true
	if str(dev_id) == _main_id:
		return true
	return _link_reachable(_main_id, str(dev_id)).has(str(dev_id))


# 在线状态归一化（启动时）：
#   ① 已在线但硬件不再满足上线条件 → 下线（例如零件被拆走）；
#   ② 一台在线的都没有 → 上线「第一台满足条件」的设备；若没有设备满足条件则全部保持离线。
func _normalize_online_state() -> void:
	if _devices.is_empty():
		return
	var dirty := false
	for id in _devices.keys():
		var d: Dictionary = _devices[id]
		if bool(d.get("online", false)) and online_block_reason(id) != "":
			d["online"] = false
			# ★ 不满足上线条件而下线（含交换机）→ 自动断开全球网络
			_auto_drop_global_net(str(id))
			dirty = true
	if online_count() == 0:
		# 上线第一台「满足条件」的设备（GDScript 无 for…else，用标记变量）
		var picked := ""
		for id in _devices.keys():
			if online_block_reason(id) == "":
				picked = str(id)
				break
		if picked != "":
			_devices[picked]["online"] = true
			dirty = true
			print("[Devices] 已自动上线第一台满足条件的设备（保证至少一台在线）")
		else:
			print("[Devices] 没有设备满足上线条件（缺最基本硬件或网卡），暂不自动上线")
	if dirty:
		_persist()
		changed.emit()


## 按给定 id 顺序重建设备表（设备管理页拖动排序用）；未列出的设备按原顺序追加在后。
func reorder(ordered_ids: Array) -> void:
	if _devices.is_empty():
		return
	var new_map := {}
	for id in ordered_ids:
		var sid := str(id)
		if _devices.has(sid) and not new_map.has(sid):
			new_map[sid] = _devices[sid]
	for id in _devices.keys():
		if not new_map.has(id):
			new_map[id] = _devices[id]
	_devices = new_map
	_persist()
	changed.emit()


# ---------------------------------------------------------------------------
# 安装 / 移除 / 拆解（内嵌零件 + 与背包联动）
# ---------------------------------------------------------------------------
## 把背包里的一个备件（part_id）安装到设备的 slot_key 槽位。
## 校验兼容性后：内嵌一份拷贝到设备 config，并扣减背包该零件数量。
func install_part(device_id: String, slot_key: String, part_id: String) -> Dictionary:
	var dev := get_device(device_id)
	if dev.is_empty():
		return { "ok": false, "reason": "设备不存在" }
	var part: Dictionary = Inventory.get_item(part_id)
	if part.is_empty():
		return { "ok": false, "reason": "背包里没有该零件" }
	var chk := PCHardware.is_compatible(dev, part, slot_key)
	if not chk.get("ok", false):
		return chk
	var ca: Dictionary = dev.get("attrs", {})
	if not (ca is Dictionary):
		ca = {}
	var cfg: Dictionary = ca.get("config", {})
	if not (cfg is Dictionary):
		cfg = {}
	var old_part = cfg.get(slot_key, null)   # 替换时已装的旧零件，先退回背包
	cfg[slot_key] = part.duplicate(true)   # 内嵌一份拷贝
	ca["config"] = cfg
	dev["attrs"] = ca
	_persist()
	if old_part is Dictionary and not old_part.is_empty():
		_return_part_to_backpack(old_part)   # 旧件退回背包
	Inventory.remove_item(part_id, 1)       # 新件从背包扣减（减到 0 自动移除）
	changed.emit()
	return { "ok": true, "reason": "已安装" }


## 移除某槽位零件，退回背包（数量 +1 / 新建条目）。
func remove_part(device_id: String, slot_key: String) -> bool:
	var dev := get_device(device_id)
	if dev.is_empty():
		return false
	var ca: Dictionary = dev.get("attrs", {})
	if not (ca is Dictionary):
		ca = {}
	var cfg: Dictionary = ca.get("config", {})
	if not (cfg is Dictionary) or not cfg.has(slot_key):
		return false
	var part = cfg[slot_key]
	cfg.erase(slot_key)
	ca["config"] = cfg
	dev["attrs"] = ca
	_persist()
	if part is Dictionary and not part.is_empty():
		_return_part_to_backpack(part)
	changed.emit()
	return true


## 移除零件的带校验版本（UI 使用）：★ 在线设备不允许拆掉「上线必需」的零件
## （否则设备会立刻不满足在线条件）。返回 { ok: bool, reason: String }
func remove_part_checked(device_id: String, slot_key: String) -> Dictionary:
	var dev := get_device(device_id)
	if dev.is_empty():
		return { "ok": false, "reason": "设备不存在" }
	var src_attrs = dev.get("attrs", {})
	if not (src_attrs is Dictionary):
		return { "ok": false, "reason": "设备数据异常" }
	var cfg: Dictionary = src_attrs.get("config", {})
	if not (cfg is Dictionary) or not cfg.has(slot_key):
		return { "ok": false, "reason": "该槽位是空的" }
	if bool(dev.get("online", false)):
		# 用「移除后的配置」试算一次上线条件；不满足 → 拒绝（先下线再拆）
		var probe_attrs: Dictionary = (src_attrs as Dictionary).duplicate(true)
		var probe_cfg: Dictionary = probe_attrs.get("config", {})
		probe_cfg.erase(slot_key)
		probe_attrs["config"] = probe_cfg
		if not bool(PCHardware.online_requirement({ "attrs": probe_attrs }).get("ok", false)):
			return { "ok": false, "reason": "该零件是上线必需，请先下线设备再移除" }
	if remove_part(device_id, slot_key):
		return { "ok": true, "reason": "已移除" }
	return { "ok": false, "reason": "移除失败" }


## 拆解整台设备：所有内嵌零件退回背包，设备自身移除。
## ★ 主力设备不可拆解 → 直接返回（不动数据）。
func disassemble(device_id: String) -> void:
	var dev := get_device(device_id)
	if dev.is_empty():
		return
	# ★ 主力设备不能拆解
	if is_main_device(device_id):
		return
	var ca: Dictionary = dev.get("attrs", {})
	var cfg: Dictionary = ca.get("config", {})
	if cfg is Dictionary:
		for key in cfg.keys():
			var part = cfg[key]
			if part is Dictionary and not part.is_empty():
				_return_part_to_backpack(part)
	_devices.erase(device_id)
	_persist()
	changed.emit()


# ---------------------------------------------------------------------------
# 配置的「暂存 → 应用并保存」
# ---------------------------------------------------------------------------
## 取设备当前配置的**可编辑草稿**（深拷贝；改它不会影响设备本身）。
func snapshot_config(device_id: String) -> Dictionary:
	var dev := get_device(device_id)
	if dev.is_empty():
		return {}
	var cfg = dev.get("attrs", {}).get("config", {})
	if not (cfg is Dictionary):
		return {}
	return (cfg as Dictionary).duplicate(true)


## 配置差分（按**零件 id 的多重集**比较，因此零件被重新编号不算增删）。
## 返回 { add: {pid: {part, n}}, remove: {pid: {part, n}} }
func _config_delta(old_cfg: Dictionary, new_cfg: Dictionary) -> Dictionary:
	var o: Dictionary = {}
	var n: Dictionary = {}
	for k in old_cfg.keys():
		var p = old_cfg[k]
		if p is Dictionary and not (p as Dictionary).is_empty():
			var pid := str((p as Dictionary).get("id", ""))
			if pid != "":
				o[pid] = { "part": p, "n": int(o.get(pid, {}).get("n", 0)) + 1 }
	for k2 in new_cfg.keys():
		var p2 = new_cfg[k2]
		if p2 is Dictionary and not (p2 as Dictionary).is_empty():
			var pid2 := str((p2 as Dictionary).get("id", ""))
			if pid2 != "":
				n[pid2] = { "part": p2, "n": int(n.get(pid2, {}).get("n", 0)) + 1 }
	var add: Dictionary = {}
	var rem: Dictionary = {}
	for pid3 in n.keys():
		var d := int(n[pid3]["n"]) - int(o.get(pid3, {}).get("n", 0))
		if d > 0:
			add[pid3] = { "part": n[pid3]["part"], "n": d }
	for pid4 in o.keys():
		var d2 := int(o[pid4]["n"]) - int(n.get(pid4, {}).get("n", 0))
		if d2 > 0:
			rem[pid4] = { "part": o[pid4]["part"], "n": d2 }
	return { "add": add, "remove": rem }


## ★ 应用并保存一份配置草稿 —— **原子操作，失败不留痕**。
## 流程：①归一化（拓展件卸下 → 其拓展接口上的零件一并卸下；硬件变化后放不下的卸下）
##       ②与当前配置做零件多重集差分 → 退回背包 / 从背包扣减
##       ③校验背包数量足够 ④在线判定（不满足开机条件 → 强制下线；若会变成 0 台在线 → 拒绝保存）
##       ⑤写入设备 + 落盘
## 返回 { ok, reason, removed: Array（被一并卸下的槽位键）, forced_offline, returned, consumed }
func commit_config(device_id: String, new_cfg: Dictionary) -> Dictionary:
	var dev := get_device(device_id)
	if dev.is_empty():
		return { "ok": false, "reason": "设备不存在", "removed": [] }
	var ca = dev.get("attrs", {})
	if not (ca is Dictionary):
		return { "ok": false, "reason": "设备数据异常", "removed": [] }
	var old_cfg = (ca as Dictionary).get("config", {})
	if not (old_cfg is Dictionary):
		old_cfg = {}

	# ① 归一化
	var norm: Dictionary = PCHardware.normalize_config(ca, new_cfg)
	var cfg: Dictionary = norm.get("cfg", {})
	var cascade: Array = norm.get("removed", [])
	# ② 差分
	var delta: Dictionary = _config_delta(old_cfg, cfg)
	var add: Dictionary = delta["add"]
	var rem: Dictionary = delta["remove"]
	# ③ 背包数量校验（退回的零件先算进可用量，避免「替换同型号」被误判不够）
	for pid in add.keys():
		var need := int(add[pid]["n"])
		var avail: int = Inventory.get_count(str(pid)) + int(rem.get(pid, {}).get("n", 0))
		if avail < need:
			return { "ok": false, "reason": "背包里的「%s」不够（需要 %d，可用 %d）" % [
				str(add[pid]["part"].get("name", pid)), need, avail], "removed": [] }
	# ④ 在线判定
	var was_online: bool = bool(dev.get("online", false))
	var forced_offline := false
	if was_online:
		var probe: Dictionary = { "online": true, "attrs": (ca as Dictionary).duplicate(true) }
		probe["attrs"]["config"] = cfg
		var req: Dictionary = PCHardware.online_requirement(probe)
		if not bool(req.get("ok", false)):
			if online_count() <= 1:
				return { "ok": false, "reason": "保存被拒绝：该配置无法开机（%s），而这是唯一在线的设备" % str(req.get("reason", "")), "removed": [] }
			forced_offline = true
	# ⑤ 应用
	var returned := 0
	for pid2 in rem.keys():
		var e: Dictionary = rem[pid2]
		for _i in range(int(e["n"])):
			_return_part_to_backpack(e["part"])
			returned += 1
	var consumed := 0
	for pid3 in add.keys():
		var cnt := int(add[pid3]["n"])
		Inventory.remove_item(str(pid3), cnt)
		consumed += cnt
	(ca as Dictionary)["config"] = cfg
	dev["attrs"] = ca
	if forced_offline:
		dev["online"] = false
		# ★ 与 set_online 同语义：被强制下线的交换机自动断开全球网络
		_auto_drop_global_net(device_id)
		# ★★ 同理：这次强制下线（例如拆掉了网卡）也会改变连通性 →
		#   连带把「因此失去与主力设备连通」的那些在线设备一并下线。
		_enforce_main_connectivity()
	_persist()
	changed.emit()
	var reason := "已应用并保存"
	if forced_offline:
		reason = "已保存，但配置无法开机 → 设备已强制下线"
	return {
		"ok": true, "reason": reason, "removed": cascade,
		"forced_offline": forced_offline, "returned": returned, "consumed": consumed,
	}


## ★ 旧存档迁移：早期版本里「转接卡 / 拓展坞 / 显卡坞」占用专门的 "expansionN" 槽位；
## 现在没有这类槽位了 → 把它们（连同其拓展接口上的零件）一并卸下并退回背包，
## 并把设备 attrs.replaceable 里残留的 "expansion" 清掉。
## 幂等：跑过一次后配置里就不再有 expansionN 键 / replaceable 里也不再有它。
func _migrate_drop_expansion_slots() -> void:
	var touched := 0
	var returned := 0
	for id in _devices.keys():
		var dev: Dictionary = _devices[id]
		if not (dev is Dictionary):
			continue
		var ca: Dictionary = dev.get("attrs", {})
		if not (ca is Dictionary):
			continue
		var changed := false
		# ① replaceable 里清掉 "expansion"
		var repl = ca.get("replaceable", null)
		if repl is Array and (repl as Array).has(SLOT_EXPANSION_LEGACY):
			var kept_repl: Array = []
			for r in (repl as Array):
				if str(r) != SLOT_EXPANSION_LEGACY:
					kept_repl.append(r)
			ca["replaceable"] = kept_repl
			changed = true
		# ② config 里的 expansionN 槽位
		var cfg = ca.get("config", null)
		if cfg is Dictionary:
			var has_legacy := false
			for k in (cfg as Dictionary).keys():
				if PCHardware._slot_type_of(str(k)) == SLOT_EXPANSION_LEGACY:
					has_legacy = true
					break
			if has_legacy:
				var kept: Dictionary = {}
				var legacy_parts: Array = []      # ★ 拓展件自己也要退回背包（normalize 只回报「放不下的」）
				for k in (cfg as Dictionary).keys():
					if PCHardware._slot_type_of(str(k)) == SLOT_EXPANSION_LEGACY:
						var lp = (cfg as Dictionary)[k]
						if lp is Dictionary and not (lp as Dictionary).is_empty():
							legacy_parts.append(lp)
						continue
					kept[k] = (cfg as Dictionary)[k]
				for lp2 in legacy_parts:
					_return_part_to_backpack(lp2)
					returned += 1
				# 走正规归一化：级联卸下拓展件所提供的接口上的零件
				var norm: Dictionary = PCHardware.normalize_config(ca, kept)
				var new_cfg: Dictionary = norm.get("cfg", {})
				var removed: Array = norm.get("removed", [])
				for rk in removed:
					var p = (cfg as Dictionary).get(str(rk), null)
					if p is Dictionary and not (p as Dictionary).is_empty():
						_return_part_to_backpack(p as Dictionary)
						returned += 1
				ca["config"] = new_cfg
				changed = true
		if changed:
			dev["attrs"] = ca
			touched += 1
	if touched > 0:
		_persist()
		print("[Devices] 已迁移「拓展槽位」旧存档 %d 台（退回背包 %d 个零件）" % [touched, returned])
	if returned > 0:
		Inventory.changed.emit()


func _return_part_to_backpack(part: Dictionary) -> void:
	var pid := str(part.get("id", ""))
	if pid == "":
		return
	Inventory.add_item(pid, str(part.get("name", "")), 1, str(part.get("category", "")),
		part.get("tags", []), str(part.get("description", "")), part.get("attrs", {}), true)


# ---------------------------------------------------------------------------
# 对外接口「链接」（设备之间，双向各占 1 个同类接口）
# ---------------------------------------------------------------------------
## 对外接口链接到另一台设备（**双向占用**：发起方与对端各占 1 个同类接口）。
## 规则：两端都必须有该类接口的**空闲**口；同一种类才有得谈（网口↔网口、无线网↔无线网）。
## 返回 { ok, reason, port_a, port_b }
func link_devices(a_id: String, kind: String, b_id: String) -> Dictionary:
	var k := str(kind)
	if k == "" or a_id == "" or b_id == "" or a_id == b_id:
		return { "ok": false, "reason": "参数不合法" }
	var a: Dictionary = get_device(a_id)
	var b: Dictionary = get_device(b_id)
	if a.is_empty() or b.is_empty():
		return { "ok": false, "reason": "设备不存在" }
	var ia := _first_free_port_index(a, k)
	if ia < 0:
		return { "ok": false, "reason": "「%s」没有空闲的%s" % [
			str(a.get("name", "")), PCHardware.port_zh(k)] }
	var ib := _first_free_port_index(b, k)
	if ib < 0:
		return { "ok": false, "reason": "「%s」没有空闲的%s" % [
			str(b.get("name", "")), PCHardware.port_zh(k)] }
	var pa := "%s%d" % [k, ia]
	var pb := "%s%d" % [k, ib]
	_set_port_link(a, k, ia, b_id, pb)
	_set_port_link(b, k, ib, a_id, pa)
	_persist()
	changed.emit()
	return { "ok": true, "reason": "已链接", "port_a": pa, "port_b": pb }


## 断开某接口上的链接（**两端一起断开**）。返回 { ok, reason, peer_id }
## ★ 断开后若导致某些「已在线」设备不再与主力设备连通 → 强制下线（维持「不能上线」的不变式）。
func unlink_port(dev_id: String, port_key: String) -> Dictionary:
	var dev: Dictionary = get_device(dev_id)
	if dev.is_empty():
		return { "ok": false, "reason": "设备不存在" }
	var lk: Dictionary = _find_link(dev, str(port_key))
	if lk.is_empty():
		return { "ok": false, "reason": "该接口没有链接" }
	var peer_id := str(lk.get("device_id", ""))
	var peer_port := str(lk.get("port_key", ""))
	_erase_link(dev, str(port_key))
	if _devices.has(peer_id):
		_erase_link(get_device(peer_id), peer_port)
	_enforce_main_connectivity()
	_persist()
	changed.emit()
	return { "ok": true, "reason": "已断开", "peer_id": peer_id }


## 维持主力设备连通性不变式：设了主力设备后，任何「已在线但不与主力设备连通」的设备强制下线。
## 在断开链接 / 拆掉网卡等会改变连通性的操作后调用。
func _enforce_main_connectivity() -> void:
	if _main_id == "":
		return
	for id in _devices.keys():
		var d: Dictionary = _devices[id]
		if not bool(d.get("online", false)):
			continue
		if str(id) == _main_id:
			continue
		if not linked_to_main(str(id)):
			d["online"] = false
			# ★ 因失去与主力设备的连通性而被强制下线的交换机 → 自动断开全球网络
			_auto_drop_global_net(str(id))


## 清理失效链接（双向互指校验）：对端口已不存在 / 对端设备已拆解 / 单向残留 → 清掉。
## ★ 启动时跑一次（零件被拆掉后网卡带来的无线口会消失，那条链接就成了孤儿）。
func validate_links() -> int:
	var removed := 0
	# 跑两轮：第一轮清「对端无效」，第二轮清因此产生的「单向残留」
	for _pass in range(2):
		for id in _devices.keys():
			var dev: Dictionary = _devices[id]
			var ca = dev.get("attrs", {})
			if not (ca is Dictionary):
				continue
			var specs = (ca as Dictionary).get("port_specs", null)
			if not (specs is Array):
				continue
			var dirty := false
			for s in (specs as Array):
				if not (s is Dictionary):
					continue
				var kind := str((s as Dictionary).get("kind", ""))
				var cnt := int((s as Dictionary).get("count", 0))
				var links = (s as Dictionary).get("links", null)
				if not (links is Dictionary):
					continue
				for lk in (links as Dictionary).keys():
					var i := int(str(lk))
					var peer = (links as Dictionary)[lk]
					var pid := str((peer as Dictionary).get("device_id", "")) if (peer is Dictionary) else ""
					var pkey := str((peer as Dictionary).get("port_key", "")) if (peer is Dictionary) else ""
					var ok := true
					if cnt >= 0 and (i < 0 or i >= cnt):
						ok = false
					if not _devices.has(pid):
						ok = false
					else:
						var back: Dictionary = _find_link(get_device(pid), pkey)
						if back.is_empty() \
								or str(back.get("device_id", "")) != str(id) \
								or str(back.get("port_key", "")) != "%s%d" % [kind, i]:
							ok = false
					if not ok:
						(links as Dictionary).erase(lk)
						dirty = true
						removed += 1
			if dirty:
				dev["attrs"] = ca
	if removed > 0:
		_persist()
		changed.emit()
		print("[Devices] 已清理 %d 条失效链接" % removed)
	return removed


## 该设备某种类接口还能再链接几个（PORT_UNLIMITED = 无限；0 = 满了）
func free_port_count(dev_id: String, kind: String) -> int:
	var dev: Dictionary = get_device(dev_id)
	if dev.is_empty():
		return 0
	return PCHardware.port_free_count(dev, str(kind))


## 可链接的候选设备：有同类**空闲**接口、不是自己、且没和自己在这一类上已经连过。
## 返回 [ { id, name, free } ]
func link_candidates(dev_id: String, kind: String) -> Array:
	var out: Array = []
	var k := str(kind)
	if k == "":
		return out
	var me: Dictionary = get_device(dev_id)
	if me.is_empty():
		return out
	# 已经和我在这一类上连过的设备（避免同一条链路重复连）
	var linked: Dictionary = {}
	for lk in PCHardware.port_links(me):
		if str((lk as Dictionary).get("kind", "")) == k:
			linked[str((lk as Dictionary).get("peer_id", ""))] = true
	for id in _devices.keys():
		var sid := str(id)
		if sid == str(dev_id) or linked.has(sid):
			continue
		var d: Dictionary = _devices[id]
		var free := PCHardware.port_free_count(d, k)
		if free == 0:
			continue
		out.append({ "id": sid, "name": str(d.get("name", "?")), "free": free })
	return out


## 某设备某接口上的链接（无则 {}）：返回 { "device_id": ..., "port_key": ... }
func _find_link(dev: Dictionary, port_key: String) -> Dictionary:
	var ca = dev.get("attrs", {})
	var specs = ca.get("port_specs", []) if (ca is Dictionary) else []
	if not (specs is Array):
		return {}
	for s in (specs as Array):
		if not (s is Dictionary):
			continue
		var kind := str((s as Dictionary).get("kind", ""))
		var links = (s as Dictionary).get("links", null)
		if not (links is Dictionary):
			continue
		for lk in (links as Dictionary).keys():
			if "%s%d" % [kind, int(str(lk))] != port_key:
				continue
			var v = (links as Dictionary)[lk]
			return (v as Dictionary).duplicate() if v is Dictionary else {}
	return {}


func _erase_link(dev: Dictionary, port_key: String) -> bool:
	var ca = dev.get("attrs", {})
	var specs = ca.get("port_specs", []) if (ca is Dictionary) else []
	if not (specs is Array):
		return false
	for s in (specs as Array):
		if not (s is Dictionary):
			continue
		var kind := str((s as Dictionary).get("kind", ""))
		var links = (s as Dictionary).get("links", null)
		if not (links is Dictionary):
			continue
		for lk in (links as Dictionary).keys():
			if "%s%d" % [kind, int(str(lk))] == port_key:
				(links as Dictionary).erase(lk)
				dev["attrs"] = ca
				return true
	return false


## 写一条链接（缺 port_specs 条目时现建；★ 新建的「无线网」条目 count 记 0，
## 因为它是由网卡带来的「+1」，拆掉网卡就该消失）。
func _set_port_link(dev: Dictionary, kind: String, index: int, peer_id: String, peer_port: String) -> void:
	var ca = dev.get("attrs", {})
	if not (ca is Dictionary):
		ca = {}
		dev["attrs"] = ca
	var specs = (ca as Dictionary).get("port_specs", null)
	if not (specs is Array):
		specs = []
		(ca as Dictionary)["port_specs"] = specs
	var spec: Dictionary = {}
	for s in (specs as Array):
		if s is Dictionary and str((s as Dictionary).get("kind", "")) == kind:
			spec = s
			break
	if spec.is_empty():
		var cnt := 0 if kind == "wireless" else PCHardware.device_port_total(dev, kind)
		spec = { "kind": kind, "count": cnt, "speed_mbps": 1200, "links": {} }
		(specs as Array).append(spec)
	var links = spec.get("links", null)
	if not (links is Dictionary):
		links = {}
		spec["links"] = links
	(links as Dictionary)[str(index)] = { "device_id": peer_id, "port_key": peer_port }
	dev["attrs"] = ca


## 首个空闲接口编号（该类无接口 → -1；该类的口都占了 → -1）
func _first_free_port_index(dev: Dictionary, kind: String) -> int:
	if not PCHardware.device_port_kinds(dev).has(kind):
		return -1
	var cnt := PCHardware.device_port_total(dev, kind)
	var used: Dictionary = {}
	var ca = dev.get("attrs", {})
	var specs = ca.get("port_specs", []) if (ca is Dictionary) else []
	if specs is Array:
		for s in (specs as Array):
			if not (s is Dictionary) or str((s as Dictionary).get("kind", "")) != kind:
				continue
			var links = (s as Dictionary).get("links", null)
			if links is Dictionary:
				for lk in (links as Dictionary).keys():
					used[int(str(lk))] = true
	var i := 0
	while i <= 4096:
		if not used.has(i):
			if cnt < 0:
				return i
			return i if i < cnt else -1
		i += 1
	return -1


# ---------------------------------------------------------------------------
# 「连接到全球网络」（仅交换机有；状态落 devices.json 的 attrs.global_net）
# ---------------------------------------------------------------------------
## 交换机是否接入全球网络（非交换机 → false）
func global_net_state(dev_id: String) -> bool:
	var dev: Dictionary = get_device(str(dev_id))
	if dev.is_empty():
		return false
	if PCHardware.device_kind(dev) != PCHardware.KIND_SWITCH:
		return false
	var ca = dev.get("attrs", {})
	if not (ca is Dictionary):
		return false
	return bool((ca as Dictionary).get("global_net", false))


## 拨动交换机「连接到全球网络」开关。非交换机 → false（拒绝）。落盘 + 广播 changed。
func set_global_net(dev_id: String, on: bool) -> bool:
	var dev: Dictionary = get_device(str(dev_id))
	if dev.is_empty():
		return false
	if PCHardware.device_kind(dev) != PCHardware.KIND_SWITCH:
		return false
	var ca = dev.get("attrs", {})
	if not (ca is Dictionary):
		return false
	(ca as Dictionary)["global_net"] = bool(on)
	dev["attrs"] = ca
	_persist()
	changed.emit()
	return true


# ---------------------------------------------------------------------------
# 聚合
# ---------------------------------------------------------------------------
## 所有「在线」设备的 固态/机械 容量合计（背包面板右侧展示用）
func total_storage_capacity() -> Dictionary:
	var ssd := 0
	var hdd := 0
	for dev in _devices.values():
		if bool(dev.get("online", false)):
			var st: Dictionary = PCHardware.computer_stat(dev)
			ssd += int(st.get("ssd_capacity", 0))
			hdd += int(st.get("hdd_capacity", 0))
	return { "ssd": ssd, "hdd": hdd }


## 「电脑文件」特殊物品应占用的容量（GB）：每台**在线**算力设备（笔记本/台式机/工作站）
## 按自身固态硬盘容量的 10% 累加。离线设备不计入（其磁盘不参与「数据仓库」可用容量，
## 避免占用超过可用）；网络器材（交换机/AP）不计入。
func computer_files_capacity_gb() -> float:
	var total := 0.0
	for dev in _devices.values():
		if PCHardware.device_kind(dev) != PCHardware.KIND_COMPUTER:
			continue
		if not bool(dev.get("online", false)):
			continue
		var st: Dictionary = PCHardware.computer_stat(dev)
		total += 0.1 * float(st.get("ssd_capacity", 0))
	return snappedf(total, 0.01)


# ---------------------------------------------------------------------------
# 种子（首次无 devices.json 时预置示例设备，含内嵌零件）
# ---------------------------------------------------------------------------
func seed_devices() -> void:
	for def in _seed_defs():
		var dev := _build_device_from_template(def)
		_devices[dev["id"]] = dev
	_seed_ver = PCHardware.HW_SEED_VERSION   # 刚由当前模板构建，无需再刷新
	_persist()
	print("[Devices] 已预置设备（共 %d 台，含内嵌零件）" % _devices.size())


# 3 台预置设备：配置里写「槽位键 -> 零件模板 id」，build 时解析为内嵌零件 dict。
# ★★ 批次 40 起开局**只给 3 台**：一台弱配置笔记本 + 一个交换机 + 一个无线网络发生器。
#    原先预置的 2 台台式机 / 1 台工作站 / 1 台扫描重构器已取消（见 LEGACY_SEED_DROP_IDS）。
func _seed_defs() -> Array:
	var t: Array = []
	t.append(_laptop_seed_def())
	# ---- 网络器材（不做零件；自带对外接口，开箱即在线）----
	t.append({
		"id": "dev_switch", "name": "交换机", "kind": PCHardware.KIND_SWITCH, "online": true,
		"config": {},
	})
	t.append({
		"id": "dev_ap", "name": "无线网络发生器", "kind": PCHardware.KIND_AP, "online": true,
		"config": {},
	})
	return t


## 开局唯一那台电脑：笔记本 —— 板载主板 + 笔记本 CPU + **8GB 内存（单条）** +
## 板载显卡 + **512GB 固态** + 笔记本网卡 / 散热 / 300W SFX 电源（其余配件一律取最弱档）。
func _laptop_seed_def() -> Dictionary:
	return {
		"id": "dev_laptop", "name": "我的笔记本", "chassis": "laptop", "online": true,
		"config": {
			SLOT_MAINBOARD + "0": "mb_laptop", SLOT_CPU + "0": "cpu_laptop_r7",
			SLOT_MEMORY + "0": "ram_ddr5_8", SLOT_GPU + "0": "gpu_laptop_4060",
			SLOT_STORAGE + "0": "ssd_m2_512", SLOT_NIC + "0": "nic_laptop_m2",
			SLOT_COOLER + "0": "cooler_laptop", SLOT_PSU + "0": "psu_sfx_300",
		},
	}


# ---------------------------------------------------------------------------
# 迁移：开局设备从 7 台裁到 3 台
# ---------------------------------------------------------------------------
## ① 按 id 删掉旧版预置的台式机 / 高性能台式机 / 工作站 / 扫描重构器；
## ② 若 dev_laptop 的「槽位 -> 零件 id」仍与旧版预置完全一致（玩家没改装过）
##    → 按 _laptop_seed_def() 重建（内存 16G×2→8G×1、固态 1TB→512G）；
## ③ 主力设备若被删掉 → 清空标记（否则连通性判定会一直指向不存在的设备）。
## 幂等：靠 _seed_trimmed 标记只跑一次。
func _migrate_trim_seed_devices() -> void:
	if _seed_trimmed:
		return
	_seed_trimmed = true
	for id in LEGACY_SEED_DROP_IDS:
		_devices.erase(str(id))
	var lap = _devices.get("dev_laptop", null)
	if lap is Dictionary and _config_ids_match(lap, LEGACY_SEED_LAPTOP_CONFIG):
		_devices["dev_laptop"] = _build_device_from_template(_laptop_seed_def())
		print("[Devices] 预置笔记本仍是旧配置 → 已按新模板降级（8GB 内存 / 512GB 固态）")
	if _main_id != "" and not _devices.has(_main_id):
		_main_id = ""
	_persist()
	print("[Devices] 开局设备已裁到 %d 台（弱笔记本 + 交换机 + 无线网络发生器）" % _devices.size())


## 设备 config 的「槽位键 -> 内嵌零件 id」映射（用于和预置配置比对）。
func _config_ids(dev: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var ca = dev.get("attrs", {})
	if not (ca is Dictionary):
		return out
	var cfg = (ca as Dictionary).get("config", {})
	if not (cfg is Dictionary):
		return out
	for k in (cfg as Dictionary).keys():
		var v = (cfg as Dictionary)[k]
		if v is Dictionary:
			out[str(k)] = str((v as Dictionary).get("id", ""))
	return out


## 映射是否与期望的「槽位键 -> 零件 id」逐项一致（键集 + 每键取值）。
## ★ 不用 Dictionary 的 == ：这里要的是「同键同值」这种值语义比对，写死更稳。
func _config_ids_match(dev: Dictionary, want: Dictionary) -> bool:
	var got := _config_ids(dev)
	if got.size() != want.size():
		return false
	for k in want.keys():
		if not got.has(k) or str(got[k]) != str(want[k]):
			return false
	return true


func _build_device_from_template(def: Dictionary) -> Dictionary:
	var kind := str(def.get("kind", PCHardware.KIND_COMPUTER))
	if kind == "":
		kind = PCHardware.KIND_COMPUTER
	# ★ 并入外壳属性（见 create_device 注释），保证预置设备也能安装/替换除主板外的零件。
	#   ★ 网络器材走 kind_attrs（自带 port_specs、replaceable 为空）。
	var attrs: Dictionary = PCHardware.kind_attrs(kind, str(def.get("chassis", "")))
	if attrs.is_empty():
		attrs = { "part_type": "case", "chassis_type": str(def.get("chassis", "")) }
	if not attrs.has("device_kind"):
		attrs["device_kind"] = kind
	attrs["config"] = {}
	var dev := {
		"id": str(def.get("id", "")),
		"name": str(def.get("name", "")),
		"online": bool(def.get("online", true)),
		"attrs": attrs,
	}
	var cfg: Dictionary = {}
	var src: Dictionary = def.get("config", {})
	if src is Dictionary:
		for slot_key in src.keys():
			var pid = src[slot_key]
			var tpl: Dictionary = PCHardware.get_part_template(str(pid))
			if not tpl.is_empty():
				cfg[slot_key] = tpl.duplicate(true)
	dev["attrs"]["config"] = cfg
	return dev


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------
func _new_id() -> String:
	return "dev_%d_%d" % [int(Time.get_unix_time_from_system()), int(Time.get_ticks_usec() % 1000000)]


func _unique_name(base: String) -> String:
	var n := 1
	var name := base
	while _name_exists(name):
		n += 1
		name = "%s%d" % [base, n]
	return name


func _name_exists(name: String) -> bool:
	for d in _devices.values():
		if str(d.get("name", "")) == name:
			return true
	return false


# 迁移：旧模型把电脑当背包物品（带 case 标签），这里删掉它们（设备改由 devices.json 管理）
func _cleanup_legacy_case_items() -> void:
	for it in Inventory.get_items_by_tag(Inventory.TAG_CASE):
		var id := str(it.get("id", ""))
		if id != "":
			Inventory.set_count(id, 0)
