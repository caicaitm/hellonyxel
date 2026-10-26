# autoload/inventory.gd
# 背包系统（数据层）—— 从 abandon 版 scripts/core/inventory.gd 迁移，适应当前项目。
#
# 现状：
#   · **开局不预置任何物品** —— 起始背包为空（旧版会塞进整本电脑硬件目录，批次 40 已取消）。
#     电脑硬件的「零件 / 整机配置」只作为**物品模板**存在（res://items_types/<id>.json）。
#   · 保留数据模型与增删查、排序；每次启动仍用当前模板刷新玩家手上已有零件的属性。
#
# 物品数据模型（Dictionary）：
#   {
#     "id": String, "name": String, "count": int, "category": String,
#     "tags": Array[String], "description": String, "attrs": Dictionary,
#   }
#
# 拖放约定（InventoryPanel + desktop.place_inventory_item）—— **「构建」变量**：
#   物品 `attrs.build = { "type": <积木类型名>, "mod": <修饰串> }`
#   （编辑物品页的「构建」行填写）。把该物品图标拖出背包、在场景里松开 →
#   在落点生成一个类型为 `build.type` 的积木，把 `build.mod` 当作**属性覆盖**套在
#   类型定义之上（见 parse_build_modifiers），同时该物品数量 -1。
#   ★★ **「构建」只对带「数字物品」（digital_item）标签的物品生效**：即便有 build 变量，
#      非数字物品拖到桌面也**不生成积木、数量也不减少**。门禁唯一执行点是 build_info()。
#   ★ 兼容旧约定：物品标签里的 `构建_<类别>{<修饰>}`（如 构建_方块{color_red}）仍可解析，
#      但同样要过「数字物品」门禁（见 build_info 的 legacy 回退）。
extends Node

var _items: Dictionary = {}   # id -> item Dictionary
# ★ 一次性迁移标记：是否已清掉「旧版开机预置进背包」的整本硬件目录（见 _strip_seed_catalog）。
var _catalog_stripped: bool = false
# ★★ 批次 96：本文件里「不认识的顶层键」原样保管，save_to_disk 时写回。
#    原因：本系统是「内存模型 → 整份重建外壳」的写法，不认识的键会被无声丢掉 ——
#    而 StateRegistry 的状态标签（tags）正是写在这个文件顶层的另一个键上。
var _extra: Dictionary = {}

# 背包物品「种类」标签（按种类筛选用；编辑物品面板也会写这些标签）。
# ★ 值一律英文（避免中文标识符 / 存档跨平台兼容问题）；UI 中文仅作展示。
const TAG_DIGITAL := "digital_item"          # 数字物品
const TAG_REAL := "real_item"                # 现实物品
const TAG_IN_RECYCLE := "in_recycle_bin"     # 在回收站中（常态隐藏，除非勾选「在回收站中」）
const TAG_UNDELETABLE := "undeletable"       # 不可删除（移入回收站时被跳过）
const TAG_DELETED := "deleted"               # 已删除（软删除：仅打标签，不真正移除；调试模式可恢复）

# 电脑硬件相关标签（PCHardware / 电脑配置页使用；值一律英文）。
const TAG_PC_HARDWARE := "pc_hardware"       # 设备硬件（背包「设备硬件」筛选用）
const TAG_CASE := "case"                     # 外壳（= 一台电脑）
const TAG_MOTHERBOARD := "motherboard"       # 主板
const TAG_CPU := "cpu"                       # CPU
const TAG_RAM := "ram"                       # 内存条
const TAG_GPU := "gpu"                       # 显卡
const TAG_SSD := "ssd"                       # 固态硬盘
const TAG_HDD := "hdd"                       # 机械硬盘
const TAG_NIC := "nic"                       # 网卡
const TAG_COOLER := "cooler"                 # 散热器
const TAG_PSU := "psu"                       # 电源
const TAG_DOCK := "dock"                     # 转接卡/拓展坞/显卡坞
const TAG_PERIPHERAL := "peripheral"         # 外设卡（USB / Type-C / 网口 等对外接口）
const TAG_ONLINE := "online"                 # 在线（电脑/设备联网状态）
const TAG_NEEDS_HIGH_SPEED_STORAGE := "needs_high_speed_storage"  # 数字物品：是否需要高速存储

# ★★ 物品标签 vs 积木标签**互不相干**：物品有自己的一套标准标签（下面 ITEM_TAGS），
#    积木的那套在 BlockTags.ALL。「标签选择」页按来源拆成两个页面（标题带（积木）/（物品）），
#    各显示各的清单，不再混在一张表里（见 ui/tag_picker_panel.gd 的 Mode）。
const ITEM_TAGS := [TAG_DIGITAL, TAG_REAL, TAG_IN_RECYCLE, TAG_UNDELETABLE, TAG_DELETED,
	TAG_PC_HARDWARE, TAG_NEEDS_HIGH_SPEED_STORAGE]

# 「设备硬件」标签勾选后，标签选择（物品）页里额外列出的**硬件类型**标签
# （与 PCHardware 的 part_type 一一对应；勾一个就表示这件物品是那种硬件）。
const HW_PART_TAGS := [TAG_CASE, TAG_MOTHERBOARD, TAG_CPU, TAG_RAM, TAG_GPU,
	TAG_SSD, TAG_HDD, TAG_NIC, TAG_COOLER, TAG_PSU, TAG_DOCK, TAG_PERIPHERAL]

# 硬件零件「接口」字段（标签选择（物品）页的「接口」下拉用；按零件类型给默认值）
const HW_IF_KEYS := ["socket", "cpu_socket", "mem_type", "gpu_if", "storage_if",
	"nic_if", "peripheral_if", "dock_if", "form_factor"]

# 零件类型 → 默认接口字段（拉出「接口」下拉的默认选项）
const HW_DEFAULT_IF := {
	"cpu": "socket", "motherboard": "cpu_socket", "ram": "mem_type",
	"gpu": "gpu_if", "ssd": "storage_if", "hdd": "storage_if",
	"nic": "nic_if", "peripheral": "peripheral_if", "dock": "dock_if",
	"psu": "form_factor", "case": "form_factor",
}

# 「文件大小」/ 落盘位置相关
const DISK_SSD := "ssd"
const DISK_HDD := "hdd"

# 「电脑文件」特殊物品：系统按每台算力设备固态硬盘 10% 自动占用的容量；
# 数字物品 + 需高速存储（落固态）+ 不可删除。id 用中文（与「系统文件」一致）。
const ID_COMPUTER_FILES := "电脑文件"
const NAME_COMPUTER_FILES := "电脑文件"

# ---- 「构建」变量（物品 attrs 里的固定键，用于「拖到桌面 → 生成积木」）----
# ★ 键名一律英文（与其它 attrs 一致，避免中文 key 的存档/跨平台问题）。
const BUILD_KEY := "build"                   # attrs["build"] = { type, mod }
const MOD_BUILD_TYPE := "type"               # 要生成的积木类型名（BlockTypes 里的名字）
const MOD_BUILD_MOD := "mod"                 # 修饰串：属性覆盖，见 parse_build_modifiers()

# 修饰串允许的键白名单 —— **只认 BlockProperty.apply_to_block 支持的字段**。
# ★ 刻意**不含** id / string_id / parent_id / child_ids / text_boxes / attack_boxes
#   / value_bars / local_vars：这些要么需要复杂结构、要么会与积木自身的注册表/父子
#   引用打架，用一行 `key=value` 表达不安全。
const BUILD_MOD_KEYS := [
	"width", "height", "display_layer", "border_width", "border_color",
	"fill_color", "collision_layer", "tags", "rotation_deg", "facing",
	"base_attack", "can_fly", "horiz_max_speed", "horiz_accel",
	"fly_up_max_speed", "fly_up_accel", "mass",
	"gravity_enabled", "roll_enabled", "free_roll", "roll_axis_x", "roll_axis_y",
	"friction_coef", "air_drag", "restitution", "squash_amount", "squash_stiffness",
	"inertia_enabled", "inertia_value",
]

# 修饰串里按「逗号分隔 → Array」处理的键（其余按 parse_attr_value 单值解析）
const BUILD_MOD_ARRAY_KEYS := ["collision_layer", "tags"]

# 物品标签的中文显示名（仅 UI 展示；标签值本身始终保持英文）
const ITEM_TAG_NAMES := {
	"digital_item": "数字物品",
	"real_item": "现实物品",
	"in_recycle_bin": "在回收站中",
	"undeletable": "不可删除",
	"deleted": "已删除",
	"pc_hardware": "设备硬件",
	"case": "外壳/电脑",
	"motherboard": "主板",
	"cpu": "CPU",
	"ram": "内存条",
	"gpu": "显卡",
	"ssd": "固态硬盘",
	"hdd": "机械硬盘",
	"nic": "网卡",
	"cooler": "散热器",
	"psu": "电源",
	"dock": "转接卡/拓展坞",
	"peripheral": "外设卡",
	"online": "在线",
	"needs_high_speed_storage": "需高速存储",
}

## 物品标签的中文显示名（非标准物品标签原样返回）
func item_tag_display_name(tag: String) -> String:
	return str(ITEM_TAG_NAMES.get(tag, tag))

# 持久化：背包状态写入 %文档%/HelloNyxel/Temp/inventory.json（与 save.json 拆分，
# 由 SaveManager 在每个存档里随 Temp 一起拷贝/恢复，避免 save.json 单文件膨胀）。
const TEMP_FILE := "inventory.json"

# 物品数据变化（增删改 / 从磁盘载入）→ 通知 UI 刷新
signal changed


## 添加物品。id 已存在时默认累加数量（merge=true）
func add_item(id: String, name: String, count: int, category: String,
		tags: Array = [], description: String = "", attrs: Dictionary = {},
		merge: bool = true) -> bool:
	var added := false
	if _items.has(id):
		if merge:
			_items[id]["count"] = int(_items[id].get("count", 0)) + int(count)
	else:
		_items[id] = {
			"id": id,
			"name": name,
			"count": int(count),
			"category": category,
			"tags": _as_str_array(tags),
			"description": description,
			"attrs": attrs if attrs is Dictionary else {},
		}
		added = true
	_persist()
	return added


## 减少数量；amount<=0 表示整条移除。减到 <=0 时整条移除
func remove_item(id: String, amount: int = 1) -> void:
	if not _items.has(id):
		return
	if has_tag(id, TAG_UNDELETABLE):   # 不可删除：任何代码路径都跳过硬删
		print("[Inventory] 跳过删除「不可删除」物品：%s" % id)
		return
	if amount <= 0:
		_items.erase(id)
		_persist()
		return
	var it: Dictionary = _items[id]
	it["count"] = int(it.get("count", 0)) - amount
	if it["count"] <= 0:
		_items.erase(id)
	_persist()


## 直接设置数量（<=0 移除整条）
func set_count(id: String, count: int) -> void:
	if not _items.has(id):
		return
	if count <= 0:
		_items.erase(id)
	else:
		_items[id]["count"] = int(count)
	_persist()


## 整体写入/更新一个物品（编辑物品面板「保存到背包」用）。
## dict 必须含 "id"；仅覆盖 dict 中出现的字段，未出现的保持原值。
## 字段：name / category / tags(Array) / description / attrs(Dictionary) / texture_path / count
##       / names(Dictionary) / descriptions(Dictionary)。
## ★ `names` / `descriptions` 是编辑物品页的「多语言名称 / 描述」——早先 apply_item 不认这两个键，
##   导致那两栏**填了等于没填**（落盘后被静默丢弃）。现在一并写入，编辑页才「真正生效」。
func apply_item(dict: Dictionary) -> void:
	var id := str(dict.get("id", ""))
	if id == "":
		push_warning("[Inventory] apply_item: 缺少 id，忽略")
		return
	if not _items.has(id):
		_items[id] = {
			"id": id, "name": "", "count": 1, "category": "",
			"tags": [], "description": "", "attrs": {}, "texture_path": "",
		}
	var it: Dictionary = _items[id]
	for key in ["name", "category", "tags", "description", "attrs", "texture_path", "count",
			"names", "descriptions"]:
		if dict.has(key):
			it[key] = dict[key]
	it["tags"] = _as_str_array(it.get("tags", []))
	if not (it.get("attrs") is Dictionary):
		it["attrs"] = {}
	for k in ["names", "descriptions"]:
		if it.has(k) and not (it[k] is Dictionary):
			it[k] = {}
	_persist()


func get_item(id: String) -> Dictionary:
	return _items.get(id, {})


func has_item(id: String) -> bool:
	return _items.has(id)


## 某物品的当前数量（不存在返回 0）
func get_count(id: String) -> int:
	var it = _items.get(id, null)
	if it is Dictionary:
		return int(it.get("count", 0))
	return 0


func get_all() -> Array:
	return _items.values()


## 取所有带某标签的物品
func get_items_by_tag(tag: String) -> Array:
	var out: Array = []
	for it in _items.values():
		if has_tag(str(it.get("id", "")), tag):
			out.append(it)
	return out


func size() -> int:
	return _items.size()


## ★ 数字物品的「文件大小」：`attrs.capacity`（单位 GB，**float**，可精确到 0.01）。
## 早期版本写的是整数，这里统一按 float 读，`size_gb()` 做两位小数归整。
func size_gb(id: String) -> float:
	var it = _items.get(id, null)
	if not (it is Dictionary):
		return 0.0
	return size_gb_of_attrs((it as Dictionary).get("attrs", {}))


## 从 attrs 读「文件大小」（GB，float）。**不依赖数字物品标签**（标签由调用方判断）。
static func size_gb_of_attrs(attrs) -> float:
	if not (attrs is Dictionary):
		return 0.0
	var v = (attrs as Dictionary).get("capacity", 0)
	if v is String:
		if not (v as String).is_valid_float():
			return 0.0
		v = (v as String).to_float()
	return maxf(0.0, snappedf(float(v), 0.01))


## ★ 背包「数据仓库」用：数字物品在两盘上的**实际占用**（GB，float）。
## 口径：`attrs.capacity`（GB，含 0.01 精度）× `count`（多份累加）。
## 归属看 `attrs.disk`（由「编辑物品」或「文件搬迁」写入）：
##   · 缺省时——带 TAG_NEEDS_HIGH_SPEED_STORAGE → 固态，其余 → 机械。
## ★ 回收站中 / 已（软）删除的物品照样占盘（软删除只是打标签，不真的腾空间），
## 这样「把文件拖进回收站」不会让硬盘条凭空变空。
## `exclude_id` 非空时不计入该物品（「编辑物品」估算落盘位置时要排除自己，否则重复计数）。
## 只读聚合，不落盘、不发信号。
func used_storage_gb(exclude_id: String = "") -> Dictionary:
	var ssd := 0.0
	var hdd := 0.0
	for it in _items.values():
		if not (it is Dictionary):
			continue
		var d: Dictionary = it
		var tags := _as_str_array(d.get("tags", []))
		if not tags.has(TAG_DIGITAL):
			continue
		var it_id := str(d.get("id", ""))
		if exclude_id != "" and it_id == exclude_id:
			continue
		var cap := size_gb_of_attrs(d.get("attrs", {}))
		if cap <= 0.0:
			continue
		var n: int = maxi(1, int(d.get("count", 1)))
		if _disk_of(d) == DISK_SSD:
			ssd += cap * float(n)
		else:
			hdd += cap * float(n)
	return { "ssd": snappedf(ssd, 0.01), "hdd": snappedf(hdd, 0.01) }


## 某条数字物品落在哪块盘上（`attrs.disk` 优先；缺省按「需高速存储」标签推）。
func _disk_of(d: Dictionary) -> String:
	var attrs = d.get("attrs", {})
	var disk := ""
	if attrs is Dictionary:
		disk = str((attrs as Dictionary).get("disk", ""))
	if disk == DISK_SSD or disk == DISK_HDD:
		return disk
	return DISK_SSD if _as_str_array(d.get("tags", [])).has(TAG_NEEDS_HIGH_SPEED_STORAGE) else DISK_HDD


## 给某个文件推荐落盘位置（GB）。需高速 → 固态；否则**优先机械**，机械装不下才固态。
## exclude_id：正在编辑的物品（其当前占用要先从「已用」里剔掉，避免自己挤自己）。
func suggest_disk(size: float, high_speed: bool, exclude_id: String = "") -> String:
	if high_speed:
		return DISK_SSD
	var cap: Dictionary = Devices.total_storage_capacity()
	var hdd_cap := maxf(0.0, float(cap.get(DISK_HDD, 0)))
	var used: Dictionary = used_storage_gb(exclude_id)
	var hdd_used := maxf(0.0, float(used.get(DISK_HDD, 0)))
	if hdd_used + maxf(0.0, size) <= hdd_cap:
		return DISK_HDD
	return DISK_SSD


## ★「文件搬迁」按钮：重新计算**所有数字物品**的落盘位置（写 `attrs.disk`）。
## 规则（简单装箱）：带「需要高速存储」的一律固态（不可搬）；
## 其余按文件大小**从小到大**依次往机械塞，机械剩余空间装不下才放固态。
## 落盘 + 广播 changed。返回 {moved, hdd, ssd, hdd_cap, ssd_cap}。
func migrate_storage() -> Dictionary:
	var cap: Dictionary = Devices.total_storage_capacity()
	var hdd_cap := maxf(0.0, float(cap.get(DISK_HDD, 0)))
	var ssd_cap := maxf(0.0, float(cap.get(DISK_SSD, 0)))
	var plan: Array = []          # [{item, total, high}]
	var ssd_used := 0.0
	var hdd_used := 0.0
	for it in _items.values():
		if not (it is Dictionary):
			continue
		var d: Dictionary = it
		var tags := _as_str_array(d.get("tags", []))
		if not tags.has(TAG_DIGITAL):
			continue
		var size := size_gb_of_attrs(d.get("attrs", {}))
		if size <= 0.0:
			continue
		var total := size * float(maxi(1, int(d.get("count", 1))))
		var high: bool = tags.has(TAG_NEEDS_HIGH_SPEED_STORAGE)
		if high:
			ssd_used += total
			plan.append({ "d": d, "total": total, "high": true })
		else:
			plan.append({ "d": d, "total": total, "high": false })
	# 可搬迁的按体积升序（小文件先占机械，装箱更省）
	var movable: Array = []
	for p in plan:
		if not bool(p["high"]):
			movable.append(p)
	movable.sort_custom(func(a, b) -> bool: return float(a["total"]) < float(b["total"]))
	hdd_used = 0.0
	var moved := 0
	for p in movable:
		var total := float(p["total"])
		var d: Dictionary = p["d"]
		var target := DISK_SSD
		if hdd_used + total <= hdd_cap:
			target = DISK_HDD
			hdd_used += total
		else:
			ssd_used += total
		if _disk_of(d) != target:
			moved += 1
		_set_disk(d, target)
	for p in plan:
		if bool(p["high"]):
			var d2: Dictionary = p["d"]
			if _disk_of(d2) != DISK_SSD:
				moved += 1
			_set_disk(d2, DISK_SSD)
	if moved > 0:
		_persist()
	return {
		"moved": moved,
		"hdd": snappedf(hdd_used, 0.01), "ssd": snappedf(ssd_used, 0.01),
		"hdd_cap": hdd_cap, "ssd_cap": ssd_cap,
	}


## 就地把一条数字物品的落盘位置写进 attrs（不落盘）
func _set_disk(d: Dictionary, disk: String) -> void:
	var attrs = d.get("attrs", null)
	if not (attrs is Dictionary):
		attrs = {}
		d["attrs"] = attrs
	(attrs as Dictionary)["disk"] = disk


# ============================================================
# 标签增删查（回收站 / 软删除 / 不可删除 等均以标签形式落地）
# ============================================================

## 给物品追加一个标签（已存在则幂等，不重复）。变更会落盘 + 广播。
func add_tag(id: String, tag: String) -> void:
	if not _items.has(id):
		return
	var it: Dictionary = _items[id]
	var tags: Array = _as_str_array(it.get("tags", []))
	var s := str(tag)
	if tags.has(s):
		return
	tags.append(s)
	it["tags"] = tags
	_persist()


## 移除物品的一个标签（不存在则幂等）。变更会落盘 + 广播。
func remove_tag(id: String, tag: String) -> void:
	if not _items.has(id):
		return
	var it: Dictionary = _items[id]
	var tags: Array = _as_str_array(it.get("tags", []))
	var s := str(tag)
	var idx: int = tags.find(s)
	if idx < 0:
		return
	tags.remove_at(idx)
	it["tags"] = tags
	_persist()


## 物品是否带某标签
func has_tag(id: String, tag: String) -> bool:
	if not _items.has(id):
		return false
	var tags: Array = _as_str_array(_items[id].get("tags", []))
	return tags.has(str(tag))


## 排序（在全部物品上排序，再交 UI 分页）。sort_by: "name" | "count" | "category"
func get_sorted(sort_by: String = "name", asc: bool = true) -> Array:
	var arr: Array = get_all()
	arr.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var va
		var vb
		if sort_by == "count":
			va = int(a.get("count", 0))
			vb = int(b.get("count", 0))
		else:
			va = str(a.get(sort_by, ""))
			vb = str(b.get(sort_by, ""))
		if va == vb:
			return str(a.get("id", "")) < str(b.get("id", ""))
		if asc:
			return va < vb
		return va > vb
	)
	return arr


# ============================================================
# 持久化（Temp/inventory.json）
# ============================================================
#
# 设计：背包是「工作态」数据，单独落到 %文档%/HelloNyxel/Temp/inventory.json，
# 不进 save.json（save.json 只保留积木 + 全局变量快照，见 SaveManager）。
# SaveManager 每次存档会把整个 Temp 目录拷进 <存档>/temp/，读档时写回 Temp ——
# 所以背包随任意存档一起被快照/恢复，且 save.json 不会因此变大。

func _ready() -> void:
	# 启动时从磁盘恢复背包。Inventory 在 autoload 顺序里排在 SaveManager 之前，
	# 但 _temp_path() 经 SaveManager.get_temp_dir() 会惰性建好 Temp 目录。
	load_from_disk()
	# ★★ 开局**不预置任何物品**：新存档就是空背包（旧版会把整本硬件目录塞进来）。
	#    硬件只作为 items_types/*.json 的物品模板存在，不再默认发到玩家手上。
	var dirty := false
	if not _catalog_stripped:
		_strip_seed_catalog()      # 老存档：一次性清掉之前预置进背包的整本目录
		_catalog_stripped = true   # 标记位本身也要落盘，故无论有没有删到都算 dirty
		dirty = true
	# 模板代码改了 → 玩家手上已有的零件属性按当前模板刷新一遍（价格/功耗/尺寸等）。
	if PCHardware.refresh_owned_attrs() > 0:
		dirty = true
	if dirty:
		save_to_disk()
		changed.emit()
	# 「电脑文件」随设备系统变化动态占用：订阅 Devices.changed（设备就绪后由 Devices._ready
	# 显式触发首次同步，因为种子/迁移路径不 emit changed）。
	if Devices != null and not Devices.changed.is_connected(_on_devices_changed):
		Devices.changed.connect(_on_devices_changed)


## 「电脑文件」特殊物品（动态占用每台算力设备固态硬盘的 10%）
# ---------------------------------------------------------------------------
## 保证「电脑文件」存在且其容量 = Devices.computer_files_capacity_gb()。
## 数字物品 + 需高速存储（落固态）+ 不可删除。仅容量变化才落盘/广播，幂等。
func sync_computer_files() -> void:
	var target := snappedf(Devices.computer_files_capacity_gb(), 0.01)
	var it = _items.get(ID_COMPUTER_FILES, null)
	if it == null or not (it is Dictionary):
		add_item(ID_COMPUTER_FILES, NAME_COMPUTER_FILES, 1, "digital_item",
			[TAG_DIGITAL, TAG_NEEDS_HIGH_SPEED_STORAGE, TAG_UNDELETABLE],
			"系统自动占用的文件：每台算力设备按自身固态硬盘容量的 10% 计，使用高速存储，不可删除。",
			{"capacity": target, "disk": DISK_SSD})
		return
	var attrs: Dictionary = it.get("attrs", {})
	if not (attrs is Dictionary):
		attrs = {}
	var cur := snappedf(float(attrs.get("capacity", 0)), 0.01)
	if cur != target:
		attrs["capacity"] = target
		it["attrs"] = attrs
		_persist()
		changed.emit()


## 设备系统任何变化（装/拆零件、增删设备、上下线）→ 重新同步「电脑文件」占用。
func _on_devices_changed() -> void:
	sync_computer_files()


## ★ 一次性迁移：把「旧版开机预置进背包」的整本硬件目录删掉。
## 只删「id 恰好等于某个内置零件模板 id」的条目 —— 玩家自建物品（自定义 id）与
## 「系统文件」之类非硬件物品都不受影响。幂等：靠 _catalog_stripped 标记只跑一次。
func _strip_seed_catalog() -> int:
	var removed := 0
	for id in PCHardware.part_template_ids():
		if _items.has(str(id)):
			_items.erase(str(id))
			removed += 1
	if removed > 0:
		print("[Inventory] 已清掉旧版预置的硬件目录 %d 种（零件改为 items_types/ 物品模板）" % removed)
	return removed


## 背包持久化文件路径：%文档%/HelloNyxel/Temp/inventory.json
func _temp_path() -> String:
	if SaveManager != null:
		return SaveManager.get_temp_dir().path_join(TEMP_FILE)
	# 兜底：直接算文档目录（极端情况下 SaveManager 不可用）
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs.is_empty():
		docs = OS.get_environment("USERPROFILE")
	return docs.path_join("HelloNyxel/Temp").path_join(TEMP_FILE)


## 把内存背包写到 Temp/inventory.json（每次增删改后调用）。
func save_to_disk() -> void:
	var path := _temp_path()
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var arr: Array = []
	for it in _items.values():
		if it is Dictionary:
			arr.append(_serialize_item(it))
	var data := { "version": 1, "catalog_stripped": _catalog_stripped, "items": arr }
	# ★ 批次 96：带上原先就在文件里的「不认识的顶层键」（如 StateRegistry 写的状态标签），
	#   否则背包每保存一次就把它们抹掉一次。
	for k in _extra:
		if not data.has(str(k)):
			data[str(k)] = _extra[k]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[Inventory] 写入失败: %s" % path)
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()


# ---- 自检：文件残缺 → 按默认值（空背包）重建 ----------------------------------
# ★ 由 SaveManager.ensure_temp_files() 在「进入游戏前 / 载入存档前」调用。
# ★★ 判据**保守**：只要 inventory.json 能解析成对象、且 items 是数组，就认为「完整」——
#    避免因缺个别键把玩家的背包整份冲掉。只有整份不可用才退回默认空背包。
# 返回是否真的写盘（true = 补建或修复过）。
func ensure_file() -> bool:
	var path := _temp_path()
	var need := true
	if FileAccess.file_exists(path):
		var txt := FileAccess.get_file_as_string(path)
		if not txt.strip_edges().is_empty():
			var parsed: Variant = JSON.parse_string(txt)
			if parsed is Dictionary:
				need = not _inventory_file_intact(parsed as Dictionary)
	if not need:
		return false
	_items = {}
	_catalog_stripped = true   # 新背包 = 已剥离旧版预置目录（避免下次启动再跑一遍剥离）
	_extra = {}                # 整份重建 → 原文件里那些不认识的键已无从谈起
	save_to_disk()
	changed.emit()
	print("[Inventory] 背包文件残缺 → 已按默认空背包重建 -> " + path)
	return true


static func _inventory_file_intact(d: Dictionary) -> bool:
	return d.has("items") and (d["items"] is Array)


## 从 Temp/inventory.json 载入背包（覆盖内存）。文件不存在/损坏 → 保持空背包，不报错。
func load_from_disk() -> void:
	var path := _temp_path()
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("[Inventory] inventory.json 解析失败，忽略")
		return
	var items = data.get("items", [])
	if typeof(items) != TYPE_ARRAY:
		return
	_catalog_stripped = bool(data.get("catalog_stripped", false))
	# ★ 批次 96：先把「不认识的顶层键」收进 _extra（键名与 save_to_disk 的写出表一一对应）
	_extra = {}
	for k in data.keys():
		var ks := str(k)
		if ks == "version" or ks == "catalog_stripped" or ks == "items":
			continue
		_extra[ks] = data[ks]
	_items = {}
	for raw in items:
		if not (raw is Dictionary):
			continue
		var it: Dictionary = raw
		var id := str(it.get("id", ""))
		if id == "":
			continue
		# 兼容旧版中文标签（数字物品 / 现实物品）→ 英文键，避免存量背包与新逻辑脱节
		var raw_tags: Array = _as_str_array(it.get("tags", []))
		for i in range(raw_tags.size()):
			match str(raw_tags[i]):
				"数字物品":
					raw_tags[i] = TAG_DIGITAL
				"现实物品":
					raw_tags[i] = TAG_REAL
		_items[id] = {
			"id": id,
			"name": str(it.get("name", id)),
			"count": int(it.get("count", 1)),
			"category": str(it.get("category", "")),
			"tags": raw_tags,
			"description": str(it.get("description", "")),
			"attrs": (it.get("attrs", {}) if (it.get("attrs", {}) is Dictionary) else {}),
			"texture_path": str(it.get("texture_path", "")),
			"names": (it.get("names", {}) if (it.get("names", {}) is Dictionary) else {}),
			"descriptions": (it.get("descriptions", {}) if (it.get("descriptions", {}) is Dictionary) else {}),
		}
	print("[Inventory] 已从磁盘载入 %d 个物品" % _items.size())
	changed.emit()


## 单个物品 → JSON 兼容字典（tags 转普通 Array，attrs 确保 Dictionary）
func _serialize_item(it: Dictionary) -> Dictionary:
	var tags = it.get("tags", [])
	var tags_arr: Array = []
	for t in tags:
		tags_arr.append(str(t))
	return {
		"id": str(it.get("id", "")),
		"name": str(it.get("name", "")),
		"count": int(it.get("count", 1)),
		"category": str(it.get("category", "")),
		"tags": tags_arr,
		"description": str(it.get("description", "")),
		"attrs": (it.get("attrs", {}) if (it.get("attrs", {}) is Dictionary) else {}),
		"texture_path": str(it.get("texture_path", "")),
		"names": (it.get("names", {}) if (it.get("names", {}) is Dictionary) else {}),
		"descriptions": (it.get("descriptions", {}) if (it.get("descriptions", {}) is Dictionary) else {}),
	}


## 写入磁盘 + 广播变化（增删改统一走这里）
func _persist() -> void:
	save_to_disk()
	changed.emit()


# ============================================================
# 「构建」变量（物品 attrs.build）—— 拖到桌面生成积木
# ============================================================
# 数据形状：attrs["build"] = { "type": "方块", "mod": "width=200;fill_color=#FF0000" }
# 权威解析入口 build_info()：**「只有数字物品才能构建」这条规则只在这里执行一次**，
# 其余调用点（背包面板 / desktop.place_inventory_item）一律问它，不要各自判标签。

## 从**属性字典**里取构建变量（非字典 / 缺键 → 空字典）
func build_var_of_attrs(attrs) -> Dictionary:
	if not (attrs is Dictionary):
		return {}
	var bv = attrs.get(BUILD_KEY, null)
	return bv if (bv is Dictionary) else {}


## 从**物品字典**里取构建变量
func build_var_of(item: Dictionary) -> Dictionary:
	return build_var_of_attrs(item.get("attrs", {}))


## 构建变量里的积木类型名（无 → ""）
func build_type_of(item: Dictionary) -> String:
	return str(build_var_of(item).get(MOD_BUILD_TYPE, "")).strip_edges()


## 构建变量里的修饰串（无 → ""）
func build_modifiers_of(item: Dictionary) -> String:
	return str(build_var_of(item).get(MOD_BUILD_MOD, "")).strip_edges()


## ★★ 权威解析：物品 → 可构建信息。返回 { ok, type, modifiers, reason, legacy }
##   reason: "" | "no_item" | "not_digital" | "no_build" | "no_type"
##   · **not_digital** —— 标签里没有「数字物品」→ 一律不可构建（即便带 build 变量）
##   · legacy —— 本次是从旧式「构建_XXX{}」标签解析出来的
func build_info(item: Dictionary) -> Dictionary:
	if item.is_empty():
		return _build_fail("no_item")
	# ★★ 门禁：不是数字物品 → 无需再看有没有 build 变量
	if not _as_str_array(item.get("tags", [])).has(TAG_DIGITAL):
		return _build_fail("not_digital")
	var ty: String = build_type_of(item)
	if not build_var_of(item).is_empty():
		if ty.is_empty():
			return _build_fail("no_type")
		return { "ok": true, "type": ty, "modifiers": build_modifiers_of(item), "reason": "", "legacy": false }
	# 兼容旧式标签约定 `构建_<类别>{<修饰>}`（仅当没有新变量时才回退，避免两套并存时打架）
	var info := parse_construct_tag(item)
	if not info.ok:
		return _build_fail("no_build")
	var lty: String = str(info.category).strip_edges()
	if lty.is_empty():
		return _build_fail("no_type")
	return { "ok": true, "type": lty, "modifiers": str(info.modifiers), "reason": "", "legacy": true }


## build_info 的失败返回值
func _build_fail(reason: String) -> Dictionary:
	return { "ok": false, "type": "", "modifiers": "", "reason": reason, "legacy": false }


## 修饰串 → 属性覆盖字典（喂给 BlockProperty.apply_to_block）。
## 语法：`键=值` 多组，用 `;` 或换行分隔（如 `width=200;fill_color=#FF0000;tags=a,b`）。
##   · 只认 BUILD_MOD_KEYS 白名单，其它键静默忽略（不写进积木）；
##   · collision_layer / tags 按**逗号**切成数组；
##   · 其余值走 parse_attr_value（JSON 数组/对象 → true/false → int/float → 字符串）。
## 空白串 / 全是无效项 → 空字典（调用方可据此跳过 apply_to_block）。
func parse_build_modifiers(mod: String) -> Dictionary:
	var out: Dictionary = {}
	var txt := str(mod).strip_edges()
	if txt.is_empty():
		return out
	for raw in txt.replace("\r\n", "\n").replace("\n", ";").split(";"):
		var seg := str(raw).strip_edges()
		if seg.is_empty():
			continue
		var eq: int = seg.find("=")
		if eq <= 0:
			continue
		var key := seg.substr(0, eq).strip_edges()
		if not (key in BUILD_MOD_KEYS):
			continue
		var val := seg.substr(eq + 1)
		if key in BUILD_MOD_ARRAY_KEYS:
			var arr: Array = []
			for p in val.split(","):
				var s := str(p).strip_edges()
				if s != "":
					arr.append(s)
			out[key] = arr
		else:
			out[key] = parse_attr_value(val)
	return out


# ============================================================
# 「构建_XXX{}」标签约定（旧式，仅作 build_info 的回退）
# ============================================================

## 是否带旧式构建标签（任一条 tag 以“构建_”开头）
func is_construct(item: Dictionary) -> bool:
	return parse_construct_tag(item).ok


## 解析物品的构建标签。返回 { ok, category, modifiers }
##   tag = 构建_<类别>{<修饰>}，如 构建_方块{color_red}
##   -> category = "方块"，modifiers = "color_red"（{} 内原样保留，功能后续再接）
func parse_construct_tag(item: Dictionary) -> Dictionary:
	for raw_tag in _as_str_array(item.get("tags", [])):
		var tag := str(raw_tag).strip_edges()
		if not tag.begins_with("构建_"):
			continue
		var rest: String = tag.trim_prefix("构建_")
		var open_idx: int = rest.find("{")
		var category: String
		var modifiers: String = ""
		if open_idx < 0:
			category = rest
		else:
			category = rest.substr(0, open_idx).trim_suffix(" ")
			modifiers = rest.substr(open_idx + 1)
			var close_idx: int = modifiers.find("}")
			if close_idx >= 0:
				modifiers = modifiers.substr(0, close_idx)
		category = category.strip_edges()
		if category.is_empty():
			return { "ok": false, "category": "", "modifiers": "" }
		return { "ok": true, "category": category, "modifiers": modifiers }
	return { "ok": false, "category": "", "modifiers": "" }


# ============================================================
# 工具
# ============================================================

## 值文本 → Variant：JSON（数组/对象）优先，其次 int / float / bool，最后字符串。
## ★ 唯一实现在这里（物品 attrs 的键=值输入框、积木修饰串解析共用）；
##   原先散在 ui/tag_picker_panel.gd 里的私有副本已删除，调用点统一走 Inventory.
static func parse_attr_value(s: String):
	var t := str(s).strip_edges()
	if t == "":
		return ""
	if (t.begins_with("[") and t.ends_with("]")) or (t.begins_with("{") and t.ends_with("}")):
		var parsed = JSON.parse_string(t)
		if parsed != null:
			return parsed
	if t == "true":
		return true
	if t == "false":
		return false
	if t.is_valid_int():
		return t.to_int()
	if t.is_valid_float():
		return t.to_float()
	return t


## Variant → 输入框文本（与 parse_attr_value 互逆）
static func fmt_attr_value(v) -> String:
	if v is Dictionary or v is Array:
		return JSON.stringify(v)
	if v is bool:
		return "true" if v else "false"
	return str(v)


func _as_str_array(raw) -> Array[String]:
	var out: Array[String] = []
	if raw == null:
		return out
	for x in raw:
		var s := str(x)
		if not out.has(s):
			out.append(s)
	return out