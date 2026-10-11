# items/pc_hardware/pc_catalog.gd
# 电脑配置（硬件模拟）数据层 —— 全部为「静态工具类」（class_name: PCHardware），
# 不挂场景、不依赖实例；背包面板 / 电脑配置面板 / desktop 直接以 PCHardware.xxx() 调用。
#
# 设计要点：
#   · 每件硬件 = 一个背包物品（Inventory 的 Dictionary），带英文标签 + attrs（属性全英文键）。
#   · 一台「电脑」= 一个带 case 标签的「外壳」物品；其 attrs.config 记录已安装零件
#     （槽位键 -> 已安装物品 id）。外壳的 chassis_type 决定电脑种类（笔记本/台式机/工作站）。
#   · 主板决定各槽位数量与协议；安装/替换需过 is_compatible（种类 / 协议 / 尺寸 / 可更换性）。
#   · 转接卡 / 拓展坞 / 显卡坞插在 expansion 槽，额外提供其它槽位（provides_slots）；
#     它们提供的槽位算「拓展接口」：算力打折、散热更差，且卸下时其上的零件一并卸下。
#   · 「外设」槽（SLOT_PERIPHERAL）由主板提供，可插 USB / Type-C / 网口 等外设卡；
#     外设卡与主板自带 attrs.external_ports = [{kind, speed_mbps, count}]，用于展示对外速率，
#     带 eth 口的零件也算「可用联网」（不强制必须装独立网卡）。
#
# ★ 所有代码标识符 / 标签 / attrs 键一律英文；仅 UI 展示串用中文。
extends Node
class_name PCHardware

# ---------------------------------------------------------------------------
# 槽位 / 零件类型
# ---------------------------------------------------------------------------
# 9 类槽位（电脑上能被零件占据的位置）。
# ★ 没有专门的「拓展」槽位：转接卡 / 拓展坞 / 显卡坞按「槽位规格 + 协议」插进普通槽位
#   （显卡 / 存储 / 内存 / 网卡 / 外设），仿现实规则。见 DOCK_HOST_SLOTS。
const SLOT_MAINBOARD := "mainboard"
const SLOT_CPU := "cpu"
const SLOT_MEMORY := "memory"
const SLOT_GPU := "gpu"
const SLOT_STORAGE := "storage"
const SLOT_NIC := "nic"
const SLOT_PERIPHERAL := "peripheral"
const SLOT_PSU := "psu"
const SLOT_COOLER := "cooler"

## 允许安装「转接卡 / 拓展坞 / 显卡坞」的槽位类型（普通零件槽位；黄色拓展接口一律拒绝）。
const DOCK_HOST_SLOTS: Array[String] = [
	SLOT_GPU, SLOT_STORAGE, SLOT_MEMORY, SLOT_NIC, SLOT_PERIPHERAL,
]

# 转接卡/拓展坞/显卡坞提供的槽位算「拓展接口」：插在其上的零件性能打折、散热更差。
const DOCK_COMPUTE_MULT := 0.7      # 插在拓展接口上的零件算力 ×0.7
const DOCK_COOLING_PENALTY := -10    # 插在拓展接口上的零件额外散热惩罚
const COOLING_BONUS_CAP := 40        # 散热正收益换算的算力加成上限（%）
const DOCK_IF_ANY := "ANY"           # dock_if 通配：任何拓展槽都插得进（如显卡坞）

# 中文展示名（仅 UI）
const SLOT_ZH := {
	"mainboard": "主板", "cpu": "CPU", "memory": "内存", "gpu": "显卡",
	"storage": "存储", "nic": "网卡", "peripheral": "外设",
	"psu": "电源", "cooler": "散热",
}
const CHASSIS_ZH := {
	"laptop": "笔记本", "desktop": "台式机", "workstation": "工作站",
}
# 对外接口种类（仅 UI 展示用）。
# ★ "wireless" = 「无线网」：不由零件提供，而是「设备装了网卡就多一个」，或网络器材自带。
const PORT_ZH := {
	"eth": "网口", "usb": "USB", "typec": "Type-C", "audio": "音频",
	"wireless": "无线网",
}

# ---------------------------------------------------------------------------
# 设备种类（device_kind）：电脑 / 网络器材
# ---------------------------------------------------------------------------
# 电脑（computer）：现有模型 —— 装零件，靠主板提供槽位。
# 网络器材（scanner / switch / ap）：**暂不做零件**，外壳固定，但自带「对外接口」，
#   可与其他设备建立「链接」（双向各占 1 个同类接口）。
const KIND_COMPUTER := "computer"
const KIND_SCANNER := "scanner"    # 扫描重构器（自带 2 个网口）
const KIND_SWITCH := "switch"      # 交换机（自带数个网口 + 「连接全球网络」开关）
const KIND_AP := "ap"              # 无线网络发生器（自带无限个「无线网」口）

const KIND_ZH := {
	"computer": "电脑", "scanner": "扫描重构器",
	"switch": "交换机", "ap": "无线网络发生器",
}

## 「网络器材」：不做零件、靠自带对外接口工作的整机设备。
const NET_DEVICE_KINDS: Array[String] = [KIND_SCANNER, KIND_SWITCH, KIND_AP]

## 无限个接口（需求：「无线网」接口数量无限）。
const PORT_UNLIMITED := -1

## 设备种类（老存档无 device_kind → 视作电脑）。
static func device_kind(dev: Dictionary) -> String:
	var a = dev.get("attrs", {})
	var k := str(a.get("device_kind", "")) if (a is Dictionary) else ""
	return k if k != "" else KIND_COMPUTER


static func kind_zh(kind: String) -> String:
	return str(KIND_ZH.get(kind, kind))


static func is_net_kind(kind: String) -> bool:
	return NET_DEVICE_KINDS.has(kind)


## 某类「网络器材」自带的对外接口清单（count = PORT_UNLIMITED → 无限）。
static func kind_port_specs(kind: String) -> Array:
	match str(kind):
		KIND_SCANNER:
			return [_port_spec("eth", 2, 10000)]
		KIND_SWITCH:
			return [_port_spec("eth", 8, 10000)]
		KIND_AP:
			return [_port_spec("wireless", PORT_UNLIMITED, 1200)]
	return []


static func _port_spec(kind: String, count: int, speed_mbps: int) -> Dictionary:
	return { "kind": str(kind), "count": int(count), "speed_mbps": int(speed_mbps), "links": {} }


## 新建设备时的 attrs 基座。kind == computer → 走外壳属性（保持旧行为）；
## 网络器材 → 种类标记 + 自带对外接口（+ 交换机默认「未连接全球网络」）。
static func kind_attrs(kind: String, chassis_type: String = "") -> Dictionary:
	var k := str(kind)
	if k == "" or k == KIND_COMPUTER:
		return chassis_attrs(str(chassis_type))
	var a: Dictionary = {
		"part_type": "case", "device_kind": k,
		# 不做零件：可更换槽位为空（is_compatible 因此一律拒绝安装零件）
		"replaceable": [],
		"max_mb_ff": "LAPTOP", "max_gpu_len_mm": 0, "max_psu_ff": "SFX",
		"port_specs": kind_port_specs(k),
	}
	if k == KIND_SWITCH:
		a["global_net"] = false
	return a

# 槽位 -> 接受的零件标签（storage 同时接受 ssd / hdd）。
# ★ 拓展件（TAG_DOCK）不再有专属槽位：它被登记进上面 5 类普通槽位，再由接口协议判定能否真的装上。
static func _slot_accepts(slot_type: String) -> Array:
	match slot_type:
		SLOT_MAINBOARD: return [Inventory.TAG_MOTHERBOARD]
		SLOT_CPU: return [Inventory.TAG_CPU]
		SLOT_MEMORY: return [Inventory.TAG_RAM, Inventory.TAG_DOCK]
		SLOT_GPU: return [Inventory.TAG_GPU, Inventory.TAG_DOCK]
		SLOT_STORAGE: return [Inventory.TAG_SSD, Inventory.TAG_HDD, Inventory.TAG_DOCK]
		SLOT_NIC: return [Inventory.TAG_NIC, Inventory.TAG_DOCK]
		SLOT_PERIPHERAL: return [Inventory.TAG_PERIPHERAL, Inventory.TAG_DOCK]
		SLOT_PSU: return [Inventory.TAG_PSU]
		SLOT_COOLER: return [Inventory.TAG_COOLER]
	return []


## 槽位类型 -> 主板侧声明该槽位「规格 / 协议」的 attrs 字段名
static func _slot_if_key(slot_type: String) -> String:
	match slot_type:
		SLOT_CPU: return "cpu_socket"
		SLOT_MEMORY: return "mem_type"
		SLOT_GPU: return "gpu_if"
		SLOT_STORAGE: return "storage_if"
		SLOT_NIC: return "nic_if"
		SLOT_PERIPHERAL: return "peripheral_if"
	return ""

static func slot_zh(slot_type: String) -> String:
	return str(SLOT_ZH.get(slot_type, slot_type))

static func port_zh(kind: String) -> String:
	return str(PORT_ZH.get(kind, kind))

static func chassis_zh(chassis: String) -> String:
	return str(CHASSIS_ZH.get(chassis, chassis))


## 外壳（机箱）属性：设备 attrs 需要这些字段供 is_compatible 校验兼容性。
## Devices.create_device / _build_device_from_template 会并入设备 attrs。
static func chassis_attrs(chassis_type: String) -> Dictionary:
	# ★ 可更换槽位（没有「拓展」槽位这一说：拓展件插进普通槽位）
	var full: Array = [SLOT_CPU, SLOT_MEMORY, SLOT_GPU, SLOT_STORAGE, SLOT_NIC,
		SLOT_PERIPHERAL, SLOT_PSU, SLOT_COOLER]
	match str(chassis_type):
		"laptop":
			# 笔记本：主板为板载（max_mb_ff=LAPTOP 仅接受笔记本主板）；电源限 SFX。
			return {
				"part_type": "case", "chassis_type": "laptop",
				"replaceable": full,
				"max_mb_ff": "LAPTOP", "max_gpu_len_mm": 0, "max_psu_ff": "SFX",
			}
		"workstation":
			return {
				"part_type": "case", "chassis_type": "workstation",
				"replaceable": full,
				"max_mb_ff": "EATX", "max_gpu_len_mm": 0, "max_psu_ff": "ATX",
			}
		_:   # desktop（默认）
			return {
				"part_type": "case", "chassis_type": "desktop",
				"replaceable": full,
				"max_mb_ff": "ATX", "max_gpu_len_mm": 0, "max_psu_ff": "ATX",
			}


## 按 id 取零件模板 dict（属性全英文键）。设备系统安装时用来解析「内嵌零件」。
## 找不到返回空字典。
static func get_part_template(id: String) -> Dictionary:
	for tp in get_part_templates():
		if str(tp.get("id", "")) == id:
			return tp
	return {}


# ---------------------------------------------------------------------------
# 物品构造辅助
# ---------------------------------------------------------------------------
static func _item(id: String, name: String, category: String, tags: Array,
		desc: String, attrs: Dictionary, count: int = 1) -> Dictionary:
	return {
		"id": id, "name": name, "count": count, "category": category,
		"tags": tags, "description": desc, "attrs": attrs,
	}


# ============================ 主板模板 ============================
## 对外接口清单：[["eth", 2500, 1], ["usb", 480, 4], ...] -> [{kind, speed_mbps, count}]
static func _ports(entries: Array) -> Array:
	var out: Array = []
	for e in entries:
		out.append({ "kind": str(e[0]), "speed_mbps": int(e[1]), "count": int(e[2]) })
	return out


static func _mb(id: String, name: String, ff: String, cpu_sock: String, mem_type: String,
		gpu_if: String, sto_if: String, nic_if: String, per_if: String,
		cpu_s: int, mem_s: int, sto_s: int, gpu_s: int, nic_s: int,
		per_s: int = 0, ports: Array = []) -> Dictionary:
	var attrs := {
		"part_type": "motherboard", "form_factor": ff,
		"cpu_socket": cpu_sock, "mem_type": mem_type,
		"gpu_if": gpu_if, "storage_if": sto_if, "nic_if": nic_if, "peripheral_if": per_if,
		"cpu_slots": cpu_s, "mem_slots": mem_s, "storage_slots": sto_s,
		"gpu_slots": gpu_s, "nic_slots": nic_s,
		"peripheral_slots": per_s, "external_ports": ports,
		"power_w": 15, "compute_score": 0, "cooling_score": -2,
	}
	return _item(id, name, "主板",
		[Inventory.TAG_PC_HARDWARE, Inventory.TAG_REAL, Inventory.TAG_MOTHERBOARD],
		"主板 %s（%s 内存 / %s 显卡）" % [ff, mem_type, gpu_if], attrs)


# ============================ 外设卡 模板 ============================
## 外设卡：插在主板提供的「外设」槽，提供若干带速率的对外接口（网口 / USB / Type-C）。
static func _periph(id: String, name: String, per_if: String, ports: Array,
		score: int, power: int, cool: int) -> Dictionary:
	var attrs := {
		"part_type": "peripheral", "peripheral_if": per_if, "external_ports": ports,
		"compute_score": score, "power_w": power, "cooling_score": cool,
	}
	return _item(id, name, "外设卡",
		[Inventory.TAG_PC_HARDWARE, Inventory.TAG_REAL, Inventory.TAG_PERIPHERAL],
		"外设卡 %s（提供 %d 个对外接口）" % [per_if, ports.size()], attrs)


# ============================ CPU 模板 ============================
static func _cpu(id: String, name: String, sock: String, big: int, small: int, score: int, power: int) -> Dictionary:
	var attrs := {
		"part_type": "cpu", "socket": sock, "big_cores": big, "small_cores": small,
		"compute_score": score, "power_w": power, "cooling_score": -int(score * 0.15),
	}
	return _item(id, name, "CPU",
		[Inventory.TAG_PC_HARDWARE, Inventory.TAG_REAL, Inventory.TAG_CPU],
		"CPU %s（大核%d+小核%d，算力%d）" % [sock, big, small, score], attrs)


# ============================ 内存条 模板 ============================
static func _ram(id: String, name: String, mem_type: String, gb: int, score: int, power: int) -> Dictionary:
	var attrs := {
		"part_type": "ram", "mem_type": mem_type, "memory_size_gb": gb,
		"compute_score": score, "power_w": power, "cooling_score": -2,
	}
	return _item(id, name, "内存条",
		[Inventory.TAG_PC_HARDWARE, Inventory.TAG_REAL, Inventory.TAG_RAM],
		"内存条 %s %dGB（算力%d）" % [mem_type, gb, score], attrs)


# ============================ 显卡 模板 ============================
static func _gpu(id: String, name: String, gpu_if: String, mm: int, vram: int, score: int, power: int) -> Dictionary:
	var attrs := {
		"part_type": "gpu", "gpu_if": gpu_if, "size_mm": mm, "vram_gb": vram,
		"compute_score": score, "power_w": power, "cooling_score": -int(score * 0.12),
	}
	return _item(id, name, "显卡",
		[Inventory.TAG_PC_HARDWARE, Inventory.TAG_REAL, Inventory.TAG_GPU],
		"显卡 %s %dGB（长%dmm，算力%d）" % [gpu_if, vram, mm, score], attrs)


# ============================ 固态硬盘 模板 ============================
static func _ssd(id: String, name: String, sto_if: String, gb: int, score: int, power: int) -> Dictionary:
	var attrs := {
		"part_type": "ssd", "storage_type": "SSD", "storage_if": sto_if,
		"storage_capacity_gb": gb, "compute_score": score, "power_w": power, "cooling_score": -1,
	}
	return _item(id, name, "固态硬盘",
		[Inventory.TAG_PC_HARDWARE, Inventory.TAG_REAL, Inventory.TAG_SSD],
		"固态硬盘 %s %dGB" % [sto_if, gb], attrs)


# ============================ 机械硬盘 模板 ============================
static func _hdd(id: String, name: String, gb: int, power: int) -> Dictionary:
	var attrs := {
		"part_type": "hdd", "storage_type": "HDD", "storage_if": "SATA3",
		"storage_capacity_gb": gb, "compute_score": 0, "power_w": power, "cooling_score": -3,
	}
	return _item(id, name, "机械硬盘",
		[Inventory.TAG_PC_HARDWARE, Inventory.TAG_REAL, Inventory.TAG_HDD],
		"机械硬盘 SATA3 %dGB" % gb, attrs)


# ============================ 网卡 模板 ============================
static func _nic(id: String, name: String, nic_if: String, mbps: int, power: int) -> Dictionary:
	var attrs := {
		"part_type": "nic", "nic_if": nic_if, "data_speed_mbps": mbps,
		"provides_online": true, "compute_score": 0, "power_w": power, "cooling_score": 0,
	}
	return _item(id, name, "网卡",
		[Inventory.TAG_PC_HARDWARE, Inventory.TAG_REAL, Inventory.TAG_NIC],
		"网卡 %s %dMbps" % [nic_if, mbps], attrs)


# ============================ 散热器 模板 ============================
static func _cooler(id: String, name: String, score: int, power: int) -> Dictionary:
	var attrs := {
		"part_type": "cooler", "cooling_score": score, "compute_score": 0, "power_w": power,
	}
	return _item(id, name, "散热器",
		[Inventory.TAG_PC_HARDWARE, Inventory.TAG_REAL, Inventory.TAG_COOLER],
		"散热器（散热%d）" % score, attrs)


# ============================ 电源 模板 ============================
static func _psu(id: String, name: String, supply: int, ff: String, power: int) -> Dictionary:
	var attrs := {
		"part_type": "psu", "power_supply_w": supply, "form_factor": ff,
		"power_w": power, "compute_score": 0, "cooling_score": -2,
	}
	return _item(id, name, "电源",
		[Inventory.TAG_PC_HARDWARE, Inventory.TAG_REAL, Inventory.TAG_PSU],
		"电源 额定%dW（%s）" % [supply, ff], attrs)


# ============================ 转接卡 / 拓展坞 / 显卡坞 模板 ============================
## 拓展零件：**占用一个普通槽位**（显卡 / 存储 / 内存 / 网卡 / 外设，按「槽位规格 + 协议」判定），
## 换来若干其它种类的槽位（provides_slots）。
##   dock_if         : 自己要插进去的接口/协议；可以是字符串，也可以是**数组**（任一命中即可，
##                     如显卡坞 = ["PCIe4x16", "Thunderbolt"]）；"ANY" = 不挑槽位。
##   provides_if     : { slot_type: interface } —— 拓展接口上的零件按**拓展零件自己**的接口校验；
##                     未列出的槽位类型 → 不做接口校验（只校验零件种类）。这是「拓展坞提供接口」的核心。
##   provides_limits : 覆盖外壳限制（如 max_psu_ff），让笔记本也能吃 ATX 电源。
##   power_supply_w  : 自身向整机提供的额定功率（显卡坞自带电源）。
##   ★ 卸下本零件时，其提供的拓展接口上的零件必须一并卸下（由 Devices 处理）。
##   ★ 拓展零件**不能**插到另一个拓展零件提供的接口上（黄色接口），避免套娃。
static func _dock(id: String, name: String, dock_if, provides: Dictionary,
		power: int, cool: int, provides_if: Dictionary = {}, provides_limits: Dictionary = {},
		power_supply_w: int = 0, score: int = 0) -> Dictionary:
	var attrs := {
		"part_type": "dock", "dock_if": dock_if, "provides_slots": provides,
		"provides_if": provides_if, "provides_limits": provides_limits,
		"power_supply_w": power_supply_w,
		"power_w": power, "cooling_score": cool, "compute_score": score,
	}
	var pl: Array = []
	for st in provides.keys():
		pl.append("%s×%d" % [slot_zh(str(st)), int(provides[st])])
	var need := "/".join(dock_if) if dock_if is Array else str(dock_if)
	return _item(id, name, "转接卡/拓展坞",
		[Inventory.TAG_PC_HARDWARE, Inventory.TAG_REAL, Inventory.TAG_DOCK],
		"拓展设备（需 %s，提供 %s）" % [need, "、".join(pl)], attrs)


# ---------------------------------------------------------------------------
# 模板全集（每种零件按接口/协议排列组合）
# ---------------------------------------------------------------------------
static func get_part_templates() -> Array:
	var t: Array = []

	# ---- 主板 ----（末两位：外设槽数 per_s / 对外接口 external_ports）
	# ★ 参数顺序：… gpu_if, storage_if, nic_if, peripheral_if, cpu_s, mem_s, sto_s, gpu_s, nic_s, per_s, ports
	#   （没有专门的「拓展」槽位了；per_if 是「外设槽」的规格，桌面上是内部 PCIe x1 扩展位）
	t.append(_mb("mb_itx_lga1700_ddr5", "ITX 主板 LGA1700/DDR5", "ITX", "LGA1700", "DDR5", "PCIe4x16", "M.2_NVMe", "M.2", "PCIe4x1", 1, 2, 2, 1, 1,
		1, _ports([["eth", 2500, 1], ["usb", 480, 4], ["typec", 5000, 1]])))
	t.append(_mb("mb_itx_am5_ddr5", "ITX 主板 AM5/DDR5", "ITX", "AM5", "DDR5", "PCIe4x16", "M.2_NVMe", "M.2", "PCIe4x1", 1, 2, 2, 1, 1,
		1, _ports([["eth", 2500, 1], ["usb", 480, 4], ["typec", 10000, 1]])))
	t.append(_mb("mb_matx_am5_ddr5", "MATX 主板 AM5/DDR5", "MATX", "AM5", "DDR5", "PCIe4x16", "M.2_NVMe", "PCIe", "PCIe4x1", 1, 4, 4, 1, 1,
		2, _ports([["eth", 2500, 1], ["usb", 480, 6], ["usb", 5000, 2], ["typec", 10000, 1]])))
	t.append(_mb("mb_atx_lga1700_ddr4", "ATX 主板 LGA1700/DDR4", "ATX", "LGA1700", "DDR4", "PCIe4x16", "SATA3", "PCIe", "PCIe4x1", 1, 4, 6, 2, 1,
		2, _ports([["eth", 1000, 1], ["usb", 480, 4], ["usb", 5000, 2], ["typec", 10000, 1]])))
	t.append(_mb("mb_eatx_am5_ddr5", "EATX 工作站主板 AM5/DDR5", "EATX", "AM5", "DDR5", "PCIe5x16", "M.2_NVMe", "PCIe", "PCIe4x1", 1, 8, 8, 2, 2,
		3, _ports([["eth", 10000, 1], ["usb", 480, 4], ["usb", 5000, 4], ["typec", 10000, 2]])))
	# 笔记本主板：CPU / 显卡都是板载（各占 1 位）；外接显卡坞走「外设槽」的 Thunderbolt（USB-C）口
	t.append(_mb("mb_laptop", "笔记本主板（板载）", "LAPTOP", "BGA_LAPTOP", "DDR5", "SOL", "M.2_NVMe", "M.2", "Thunderbolt", 1, 2, 2, 1, 1,
		1, _ports([["eth", 1000, 1], ["usb", 480, 2], ["usb", 5000, 1], ["typec", 10000, 1]])))

	# ---- CPU ----
	t.append(_cpu("cpu_lga1700_i5", "CPU i5-13600K", "LGA1700", 6, 8, 120, 125))
	t.append(_cpu("cpu_lga1700_i7", "CPU i7-13700K", "LGA1700", 8, 8, 180, 125))
	t.append(_cpu("cpu_lga1700_i9", "CPU i9-13900K", "LGA1700", 8, 16, 240, 150))
	t.append(_cpu("cpu_am5_r5", "CPU R5-7600", "AM5", 6, 0, 130, 65))
	t.append(_cpu("cpu_am5_r7", "CPU R7-7700", "AM5", 8, 0, 190, 105))
	t.append(_cpu("cpu_am5_r9", "CPU R9-7950X", "AM5", 16, 0, 270, 170))
	t.append(_cpu("cpu_laptop_r7", "笔记本 CPU R7-6800U", "BGA_LAPTOP", 8, 0, 150, 45))

	# ---- 内存条 ----
	t.append(_ram("ram_ddr5_8", "DDR5 内存 8GB", "DDR5", 8, 10, 5))
	t.append(_ram("ram_ddr5_16", "DDR5 内存 16GB", "DDR5", 16, 20, 6))
	t.append(_ram("ram_ddr5_32", "DDR5 内存 32GB", "DDR5", 32, 35, 8))
	t.append(_ram("ram_ddr4_8", "DDR4 内存 8GB", "DDR4", 8, 8, 4))
	t.append(_ram("ram_ddr4_16", "DDR4 内存 16GB", "DDR4", 16, 16, 5))
	t.append(_ram("ram_ddr4_32", "DDR4 内存 32GB", "DDR4", 32, 28, 7))

	# ---- 显卡 ----
	t.append(_gpu("gpu_pcie4x16_rtx4060", "显卡 RTX4060", "PCIe4x16", 200, 8, 200, 115))
	t.append(_gpu("gpu_pcie4x16_rtx4070", "显卡 RTX4070", "PCIe4x16", 244, 12, 280, 200))
	t.append(_gpu("gpu_pcie4x16_rtx4080", "显卡 RTX4080", "PCIe4x16", 310, 16, 360, 320))
	t.append(_gpu("gpu_pcie4x16_rtx4090", "显卡 RTX4090", "PCIe4x16", 336, 24, 450, 450))
	t.append(_gpu("gpu_pcie5x16_rtx5090", "显卡 RTX5090", "PCIe5x16", 360, 32, 600, 575))
	t.append(_gpu("gpu_laptop_4060", "笔记本显卡 RTX4060", "SOL", 0, 8, 180, 80))

	# ---- 固态硬盘 ----
	t.append(_ssd("ssd_m2_512", "固态 512GB M.2", "M.2_NVMe", 512, 15, 4))
	t.append(_ssd("ssd_m2_1t", "固态 1TB M.2", "M.2_NVMe", 1024, 25, 5))
	t.append(_ssd("ssd_m2_2t", "固态 2TB M.2", "M.2_NVMe", 2048, 40, 6))
	t.append(_ssd("ssd_sata_512", "固态 512GB SATA", "SATA3", 512, 8, 3))
	t.append(_ssd("ssd_sata_1t", "固态 1TB SATA", "SATA3", 1024, 14, 4))

	# ---- 机械硬盘 ----
	t.append(_hdd("hdd_sata_1t", "机械 1TB", 1024, 6))
	t.append(_hdd("hdd_sata_2t", "机械 2TB", 2048, 8))
	t.append(_hdd("hdd_sata_4t", "机械 4TB", 4096, 9))
	t.append(_hdd("hdd_sata_8t", "机械 8TB", 8192, 12))

	# ---- 网卡 ----
	t.append(_nic("nic_pcie_1g", "网卡 1GbE PCIe", "PCIe", 1000, 2))
	t.append(_nic("nic_pcie_2_5g", "网卡 2.5GbE PCIe", "PCIe", 2500, 3))
	t.append(_nic("nic_pcie_10g", "网卡 10GbE PCIe", "PCIe", 10000, 5))
	t.append(_nic("nic_m2_2_5g", "网卡 2.5GbE M.2", "M.2", 2500, 2))
	t.append(_nic("nic_laptop_m2", "笔记本网卡 M.2", "M.2", 2500, 1))

	# ---- 散热器 ----
	t.append(_cooler("cooler_stock", "原装下压散热", 25, 3))
	t.append(_cooler("cooler_tower", "塔式风冷", 55, 4))
	t.append(_cooler("cooler_aio240", "240 一体水冷", 80, 6))
	t.append(_cooler("cooler_aio360", "360 一体水冷", 110, 9))
	t.append(_cooler("cooler_laptop", "笔记本散热模组", 30, 3))

	# ---- 电源 ----
	t.append(_psu("psu_sfx_300", "电源 300W SFX", 300, "SFX", 3))
	t.append(_psu("psu_atx_450", "电源 450W ATX", 450, "ATX", 4))
	t.append(_psu("psu_atx_650", "电源 650W ATX", 650, "ATX", 5))
	t.append(_psu("psu_atx_850", "电源 850W ATX", 850, "ATX", 6))
	t.append(_psu("psu_atx_1000", "电源 1000W ATX", 1000, "ATX", 7))
	t.append(_psu("psu_atx_1200", "电源 1200W ATX", 1200, "ATX", 8))

	# ---- 转接卡 / 拓展坞 / 显卡坞 ----
	# ★ 没有专门的「拓展」槽位：dock_if 就是它要插进去的**普通槽位规格**，只要规格+协议匹配就能插
	#   （PCIe 形式遵守通道规则：x1 卡可插 x4/x16 槽；所以 PCIe 卡插显卡槽 / 网卡槽 / 外设槽都行）。
	t.append(_dock("dock_pcie_nic", "PCIe 转接卡(网卡)", "PCIe4x1", {"nic": 1}, 3, -5,
		{"nic": "PCIe"}))
	# 拓展坞提供的存储口不校验协议（M.2 与 SATA 都能插）——「拓展坞提供接口」的直接体现
	t.append(_dock("dock_pcie_storage", "PCIe 拓展坞(存储)", "PCIe4x4", {"storage": 2}, 4, -6))
	t.append(_dock("dock_pcie_m2", "PCIe 拓展坞(存储+网卡)", "PCIe4x4", {"storage": 1, "nic": 1}, 4, -6))
	# 外设拓展卡：1 个 PCIe 槽换成 2 个外设槽
	t.append(_dock("dock_pcie_periph", "PCIe 外设拓展卡", "PCIe4x1", {"peripheral": 2}, 3, -4))
	# M.2 转接卡：插进**硬盘槽（M.2）**，把 1 个 M.2 位换成 2 个 SATA 位（现实里的 M.2→2×SATA）
	t.append(_dock("dock_m2_sata", "M.2 转接卡(2×SATA)", "M.2_NVMe", {"storage": 2}, 2, -3))
	# 内存槽转接卡：插进**内存槽（DDR5）**，把 1 个内存位换成 2 个 M.2 位（现实里的 DIMM.2）
	t.append(_dock("dock_dimm_m2", "内存槽转接卡(2×M.2)", "DDR5", {"storage": 2, "nic": 1}, 3, -4))
	# 显卡坞：需 PCIe x16 槽或 Thunderbolt 口（台式机插显卡槽 / 笔记本插 Thunderbolt 外设口）；
	#         自带电源，同时给显卡 + 电源槽
	t.append(_dock("dock_egpu_600", "显卡坞 600W", ["PCIe4x16", "Thunderbolt"], {"gpu": 1, "psu": 1}, 10, -8,
		{"gpu": "PCIe4x16"}, {"max_gpu_len_mm": 0, "max_psu_ff": "ATX"}, 600, 0))
	t.append(_dock("dock_egpu_850", "显卡坞 850W", ["PCIe4x16", "Thunderbolt"], {"gpu": 1, "psu": 1}, 12, -8,
		{"gpu": "PCIe4x16"}, {"max_gpu_len_mm": 0, "max_psu_ff": "ATX"}, 850, 0))

	# ---- 外设卡（插主板的「外设」槽，提供带速率的对外接口）----
	t.append(_periph("per_usb3", "USB 3.0 扩展卡", "PCIe", _ports([["usb", 5000, 4]]), 0, 5, -1))
	t.append(_periph("per_usb3_8", "USB 3.0 扩展卡 ×8", "PCIe", _ports([["usb", 5000, 8]]), 0, 8, -2))
	t.append(_periph("per_typec", "Type-C 扩展卡", "PCIe", _ports([["typec", 10000, 2], ["usb", 480, 2]]), 5, 5, -1))
	t.append(_periph("per_lan_1g", "千兆网口卡", "PCIe", _ports([["eth", 1000, 2]]), 5, 3, 0))
	t.append(_periph("per_lan_2_5g", "2.5G 网口卡", "PCIe", _ports([["eth", 2500, 1], ["usb", 480, 2]]), 8, 4, 0))
	# 笔记本的「外设槽」就是那个 Thunderbolt/USB-C 口 → 有专门的 Thunderbolt 外设卡
	t.append(_periph("per_tb_hub", "Thunderbolt 扩展坞", "Thunderbolt",
		_ports([["typec", 40000, 2], ["usb", 10000, 3]]), 10, 6, -1))

	return t


# 四台预置电脑现在由 Devices 单例（devices.json）负责（设备系统独立于背包）。
# 这里只保留零件模板；电脑/设备的预装配置见 autoload/devices.gd。


# ---------------------------------------------------------------------------
# 模板版本号 / 模板 id 清单
# ---------------------------------------------------------------------------
## ★ 新增或修改零件模板时把这个版本号 +1。
## ★ 用途只剩一处：Devices 用它判断「设备里**内嵌**的零件属性要不要按当前模板刷新一遍」
##   （见 autoload/devices.gd 的 _migrate_part_attrs）。
## ★★ 批次 40 起**不再把整本硬件目录预置进背包** —— 起始背包为空；
##    这些零件只以 res://items_types/<id>.json 的**物品模板**形式存在。
const HW_SEED_VERSION := 3


## 内置零件模板的全部 id（顺序与 get_part_templates() 一致）。
## ★ 用途：Inventory 的一次性迁移「清掉旧版预置进背包的整本目录」按这份清单比对 id。
static func part_template_ids() -> Array:
	var out: Array = []
	for tp in get_part_templates():
		out.append(str(tp.get("id", "")))
	return out


## 字典是否等价（键集 + 逐键 JSON 比对；用于判断是否需要刷新）
static func _dict_same(a, b) -> bool:
	if not (a is Dictionary) or not (b is Dictionary):
		return false
	if (a as Dictionary).size() != (b as Dictionary).size():
		return false
	for k in (a as Dictionary).keys():
		if not (b as Dictionary).has(k):
			return false
		if JSON.stringify((a as Dictionary)[k]) != JSON.stringify((b as Dictionary)[k]):
			return false
	return true


## ★ 用「当前代码里的模板」刷新背包里已有零件（name / category / tags / description / attrs）。
## 为什么必须做：背包存的是模板的**拷贝**，改了模板代码（例如给笔记本主板加拓展槽/外设槽、
## 给主板加 external_ports）不会自动作用到老存档 —— 必须显式刷新，否则用户会觉得「改了没用」。
## ★ 不动 id 与 count（不碰玩家手上的数量）。
static func refresh_owned_attrs() -> int:
	var n := 0
	for tp in get_part_templates():
		var id := str(tp.get("id", ""))
		if id == "" or not Inventory.has_item(id):
			continue
		var cur: Dictionary = Inventory.get_item(id)
		if _dict_same(cur.get("attrs", {}), tp.get("attrs", {})) \
				and str(cur.get("name", "")) == str(tp.get("name", "")) \
				and str(cur.get("description", "")) == str(tp.get("description", "")) \
				and str(cur.get("category", "")) == str(tp.get("category", "")) \
				and _dict_same(_tag_set(cur.get("tags", [])), _tag_set(tp.get("tags", []))):
			continue
		Inventory.apply_item({
			"id": id, "name": str(tp.get("name", "")), "category": str(tp.get("category", "")),
			"tags": tp.get("tags", []), "description": str(tp.get("description", "")),
			"attrs": tp.get("attrs", {}),
		})
		n += 1
	return n


## 把标签数组转成「集合」字典（顺序无关比对）
static func _tag_set(tags) -> Dictionary:
	var d: Dictionary = {}
	if tags is Array:
		for t in tags:
			d[str(t)] = true
	return d


# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------
## 槽位里已安装的零件物品（无则空字典）。
## 新模型：config 直接内嵌零件 dict（从背包/设备系统写入）；旧模型：config 存背包零件 id。
static func get_installed(case_item: Dictionary, slot_key: String) -> Dictionary:
	var cfg: Dictionary = case_item.get("attrs", {}).get("config", {})
	if not (cfg is Dictionary):
		return {}
	var v = cfg.get(slot_key, null)
	if v == null:
		return {}
	if v is Dictionary:
		return v   # 新模型：内嵌零件 dict
	if str(v) == "":
		return {}
	return Inventory.get_item(str(v))   # 兼容旧模型：config 存的是背包零件 id


static func _tag_has(tags, tag: String) -> bool:
	for t in tags:
		if str(t) == tag:
			return true
	return false


## 槽位键 -> 槽位类型（去掉末尾数字）
static func _slot_type_of(slot_key: String) -> String:
	var s := str(slot_key)
	var i := s.length() - 1
	while i >= 0:
		if s[i] >= "0" and s[i] <= "9":
			i -= 1
		else:
			break
	return s.substr(0, i + 1)


## 槽位键里的数字索引（"memory3" -> 3；无数字 -> -1）
static func _slot_index(slot_key: String) -> int:
	var st := _slot_type_of(slot_key)
	var tail := str(slot_key).substr(st.length())
	return int(tail) if tail != "" else -1


# ---------------------------------------------------------------------------
# 兼容性
# ---------------------------------------------------------------------------
## 校验 part_item 能否安装到 case_item 的 slot_key 槽位。
## 返回 { ok: bool, reason: String }
static func is_compatible(case_item: Dictionary, part_item: Dictionary, slot_key: String) -> Dictionary:
	var ca: Dictionary = case_item.get("attrs", {})
	if not (ca is Dictionary) or str(ca.get("part_type", "")) != "case":
		return { "ok": false, "reason": "这不是一台电脑（外壳）" }
	var slot_type := _slot_type_of(slot_key)
	var repl = ca.get("replaceable", [])
	if not (repl is Array):
		repl = []
	# 可更换性：主板在笔记本上不可换，但笔记本本就没有主板槽给用户操作；其余按 replaceable
	if slot_type != SLOT_MAINBOARD and not repl.has(slot_type):
		return { "ok": false, "reason": "%s 不可更换" % slot_zh(slot_type) }

	# ★ 槽位必须真实存在：索引要落在「原生 + 拓展件已提供」的范围内。
	#   （没有专门的拓展槽之后，槽位键的索引不再天然等于件数，必须显式校验，
	#     否则会出现「把拓展件插进 gpu9」这种越界写入，其提供的接口还会和自身键撞号。）
	var lay: Dictionary = slot_layout(case_item)
	if lay.has(slot_type):
		var total := int(lay[slot_type].get("total", 0))
		if _slot_index(slot_key) >= total:
			return { "ok": false, "reason": "没有这个%s槽位（%s）" % [slot_zh(slot_type), str(slot_key)] }

	# 零件种类是否对槽位
	var acc: Array = _slot_accepts(slot_type)
	var ptags = part_item.get("tags", [])
	var ok_tag := false
	for t in ptags:
		if str(t) in acc:
			ok_tag = true
	if not ok_tag:
		return { "ok": false, "reason": "%s 不接受该零件" % slot_zh(slot_type) }
	var is_dock := _tag_has(ptags, Inventory.TAG_DOCK)

	# 主板（安装主板本身时需校验尺寸）
	if slot_type == SLOT_MAINBOARD:
		var ff := str(part_item.get("attrs", {}).get("form_factor", ""))
		var maxff := str(ca.get("max_mb_ff", ""))
		if maxff != "ANY" and maxff != "":
			if not _ff_fits(ff, maxff):
				return { "ok": false, "reason": "主板尺寸 %s 不适合该外壳" % ff }
		return { "ok": true, "reason": "" }

	# 其它零件：需要已装主板（除非正在装的就是主板，已上面处理）
	var mb := _mb_item(case_item, part_item, slot_type)
	if mb.is_empty():
		return { "ok": false, "reason": "未安装主板，无法安装其它零件" }
	var pa: Dictionary = part_item.get("attrs", {})
	var mba: Dictionary = mb.get("attrs", {})

	# ★「拓展接口」：装在本设备某拓展零件提供的槽位上时，接口协议与尺寸上限一律改用
	#   **那个拓展零件自己**声明的 provides_if / provides_limits —— 这正是「转接卡 / 拓展坞 /
	#   显卡坞提供一个或多个其它种类的接口」的落点（例如笔记本借显卡坞获得 PCIe4x16 显卡口与
	#   ATX 电源位，而不是被板载的 SOL 接口挡住）。
	var dock := dock_owner_of(case_item, slot_key)
	var lim := func(key: String, fallback):
		if not dock.is_empty():
			var plim = dock.get("attrs", {}).get("provides_limits", {})
			if plim is Dictionary and plim.has(key):
				return plim[key]
		return fallback

	# ★ 拓展零件（转接卡 / 拓展坞 / 显卡坞）：不再有专属槽位，按「槽位规格 + 协议」判能否插进来。
	#   规则：①不能插在另一个拓展零件提供的接口上（黄色接口，避免套娃）；
	#         ②槽位类型必须是普通零件槽（显卡/存储/内存/网卡/外设）；
	#         ③主板上该类槽位的规格/协议要让 dock_if 过得去（PCIe 走通道规则）。
	if is_dock:
		if not dock.is_empty():
			return { "ok": false, "reason": "拓展接口上不能再安装拓展设备（不支持串联）" }
		if not (slot_type in DOCK_HOST_SLOTS):
			return { "ok": false, "reason": "%s 槽位不能安装拓展设备" % slot_zh(slot_type) }
		var eff_d := _eff_if(mba, {}, slot_type, _slot_if_key(slot_type))
		var need = pa.get("dock_if", "")
		if dock_if_mismatch(eff_d, need):
			return { "ok": false, "reason": "拓展设备需要 %s，该 %s 槽位是 %s" % [
				dock_if_text(need), slot_zh(slot_type), (eff_d if eff_d != "" else "（未声明协议）")] }
		return { "ok": true, "reason": "" }

	match slot_type:
		SLOT_CPU:
			var eif := _eff_if(mba, dock, SLOT_CPU, "cpu_socket")
			if _if_mismatch(eif, str(pa.get("socket", ""))):
				return { "ok": false, "reason": "CPU 接口 %s 与主板 %s 不符" % [pa.get("socket", ""), mba.get("cpu_socket", "")] }
		SLOT_MEMORY:
			var eif2 := _eff_if(mba, dock, SLOT_MEMORY, "mem_type")
			if _if_mismatch(eif2, str(pa.get("mem_type", ""))):
				return { "ok": false, "reason": "内存类型 %s 与主板 %s 不符" % [pa.get("mem_type", ""), mba.get("mem_type", "")] }
		SLOT_GPU:
			var eif3 := _eff_if(mba, dock, SLOT_GPU, "gpu_if")
			if _if_mismatch(eif3, str(pa.get("gpu_if", ""))):
				return { "ok": false, "reason": "显卡接口 %s 与该槽位 %s 不符" % [pa.get("gpu_if", ""), eif3] }
			var maxg := int(lim.call("max_gpu_len_mm", ca.get("max_gpu_len_mm", 0)))
			if maxg > 0 and int(pa.get("size_mm", 9999)) > maxg:
				return { "ok": false, "reason": "显卡长 %dmm 超过上限 %dmm" % [int(pa.get("size_mm", 0)), maxg] }
		SLOT_STORAGE:
			var eif4 := _eff_if(mba, dock, SLOT_STORAGE, "storage_if")
			if _if_mismatch(eif4, str(pa.get("storage_if", ""))):
				return { "ok": false, "reason": "存储接口 %s 与该槽位 %s 不符" % [pa.get("storage_if", ""), eif4] }
		SLOT_NIC:
			var eif5 := _eff_if(mba, dock, SLOT_NIC, "nic_if")
			if _if_mismatch(eif5, str(pa.get("nic_if", ""))):
				return { "ok": false, "reason": "网卡接口 %s 与该槽位 %s 不符" % [pa.get("nic_if", ""), eif5] }
		SLOT_PERIPHERAL:
			var eif7 := _eff_if(mba, dock, SLOT_PERIPHERAL, "peripheral_if")
			if _if_mismatch(eif7, str(pa.get("peripheral_if", ""))):
				return { "ok": false, "reason": "外设卡接口 %s 与该槽位 %s 不符" % [pa.get("peripheral_if", ""), eif7] }
		SLOT_PSU:
			var maxpsu := str(lim.call("max_psu_ff", ca.get("max_psu_ff", "")))
			if maxpsu != DOCK_IF_ANY and maxpsu != "":
				if not _ff_fits(str(pa.get("form_factor", "")), maxpsu):
					return { "ok": false, "reason": "电源尺寸 %s 不适合该槽位（上限 %s）" % [pa.get("form_factor", ""), maxpsu] }
		SLOT_COOLER:
			pass
	return { "ok": true, "reason": "" }


## 取「有效接口」：槽位由拓展零件提供 → 用它的 provides_if（未声明该类 → 不校验）；
## 否则用主板对应字段。返回 DOCK_IF_ANY 表示不校验。
static func _eff_if(mba: Dictionary, dock: Dictionary, slot_type: String, mb_key: String) -> String:
	if dock.is_empty():
		return str(mba.get(mb_key, ""))
	var pif = dock.get("attrs", {}).get("provides_if", {})
	if pif is Dictionary and pif.has(slot_type):
		return str(pif[slot_type])
	return DOCK_IF_ANY


## 接口是否不匹配。规则：
##   · 任一侧为 ANY / 空 → 通配，不校验；
##   · 完全相等 → 通过；
##   · 都是 PCIe 形式（PCIe<代数>x<通道数>）→ **通道数少的零件能插进通道数多的槽**（x1 卡可插 x4 槽）；
##   · 其余（CPU 插槽 / 内存类型 / M.2 与 PCIe …）→ 必须完全相等。
static func _if_mismatch(eff: String, actual: String) -> bool:
	if eff == DOCK_IF_ANY or eff == "" or actual == "" or actual == DOCK_IF_ANY:
		return false
	if eff == actual:
		return false
	var sl := _pcie_lanes(eff)
	var pl := _pcie_lanes(actual)
	if sl > 0 and pl > 0:
		return pl > sl
	return true


## 解析 PCIe 形式接口的通道数（"PCIe4x16" -> 16）。
## ★ 光秃秃的 "PCIe"（未标代数/通道）按 **x1** 计：等价于「一张 x1 卡 / 一个 x1 槽」——
##   这样普通 PCIe 网卡既能插网卡槽（也都是 "PCIe"），也能插 x4/x16 的显卡槽。
## 非 PCIe 形式返回 0。
static func _pcie_lanes(if_str: String) -> int:
	var s := str(if_str)
	if not s.begins_with("PCIe"):
		return 0
	var x := s.find("x")
	if x < 0:
		return 1
	var tail := s.substr(x + 1)
	var digits := ""
	for i in range(tail.length()):
		var ch := tail[i]
		if ch >= "0" and ch <= "9":
			digits += ch
		else:
			break
	return int(digits) if digits != "" else 1


## 拓展零件的 dock_if 判定：dock_if 可以是字符串，也可以是数组（任一命中即可）。
## 空 / "ANY" → 不挑槽位。
static func dock_if_mismatch(eff: String, need) -> bool:
	if need is Array:
		if (need as Array).is_empty():
			return false
		for n in need:
			if not _if_mismatch(eff, str(n)):
				return false
		return true
	return _if_mismatch(eff, str(need))


## dock_if 的展示文本（数组 → "A/B"）
static func dock_if_text(need) -> String:
	if need is Array:
		var parts: Array = []
		for n in need:
			parts.append(str(n))
		return "/".join(parts)
	return str(need)


## 已装主板（若正装主板则用候选；否则从 config 查已装主板）
static func _mb_item(case_item: Dictionary, part_item: Dictionary, slot_type: String) -> Dictionary:
	if slot_type == SLOT_MAINBOARD:
		if str(part_item.get("attrs", {}).get("part_type", "")) == "motherboard":
			return part_item
		# 没有候选主板时，回落到 config 里已装的主板
	var cfg: Dictionary = case_item.get("attrs", {}).get("config", {})
	if not (cfg is Dictionary):
		return {}
	var mid = cfg.get(SLOT_MAINBOARD + "0", null)
	if mid == null:
		return {}
	if mid is Dictionary:
		return mid   # 新模型：内嵌零件 dict
	if str(mid) == "":
		return {}
	return Inventory.get_item(str(mid))   # 兼容旧模型


## 尺寸等级比较：ff 必须 <= maxff（ITX<MATX<ATX<EATX；SFX<ATX）
static func _ff_fits(ff: String, maxff: String) -> bool:
	var rank := { "ITX": 1, "MATX": 2, "ATX": 3, "EATX": 4, "SFX": 1, "LAPTOP": 0 }
	var a := int(rank.get(ff, 3))
	var b := int(rank.get(maxff, 3))
	return a <= b


# ---------------------------------------------------------------------------
# 槽位布局（原生槽位 vs 拓展零件提供的「拓展接口」）
# ---------------------------------------------------------------------------
## 主板 / 外壳「原生」提供的槽位数（不含任何拓展零件）。
static func native_slots(case_item: Dictionary) -> Dictionary:
	# ★ 网络器材（扫描重构器 / 交换机 / 无线网络发生器）**不做零件** → 原生槽位一律 0。
	#   否则会凭空多出「主板 / 电源 / 散热」三个槽（主板还走 is_compatible 的豁免分支），
	#   用户就能给交换机装一块主板 —— 与「不做零件」的设计直接冲突。
	if is_net_kind(device_kind(case_item)):
		return {
			SLOT_MAINBOARD: 0, SLOT_PSU: 0, SLOT_COOLER: 0, SLOT_CPU: 0, SLOT_MEMORY: 0,
			SLOT_GPU: 0, SLOT_STORAGE: 0, SLOT_NIC: 0, SLOT_PERIPHERAL: 0,
		}
	var mb := _mb_item(case_item, {}, SLOT_MAINBOARD)
	var mba: Dictionary = mb.get("attrs", {}) if not mb.is_empty() else {}
	return {
		SLOT_MAINBOARD: 1, SLOT_PSU: 1, SLOT_COOLER: 1,
		SLOT_CPU: int(mba.get("cpu_slots", 0)),
		SLOT_MEMORY: int(mba.get("mem_slots", 0)),
		SLOT_GPU: int(mba.get("gpu_slots", 0)),
		SLOT_STORAGE: int(mba.get("storage_slots", 0)),
		SLOT_NIC: int(mba.get("nic_slots", 0)),
		SLOT_PERIPHERAL: int(mba.get("peripheral_slots", 0)),
	}


## 内嵌零件是不是「拓展零件」（转接卡 / 拓展坞 / 显卡坞）——靠 part_type 判，与它插在哪个槽无关。
static func _is_dock_item(it) -> bool:
	if not (it is Dictionary) or (it as Dictionary).is_empty():
		return false
	return str((it as Dictionary).get("attrs", {}).get("part_type", "")) == "dock"


## 各槽位类型「拓展件所提供接口」的起始编号：原生槽数之后，且跳过 config 里已存在的同类键。
## （拓展件自己就占着一个索引；虽然黄色接口不许再插拓展件、理论上不会撞号，这里仍做防御。）
static func _dock_start_index(case_item: Dictionary) -> Dictionary:
	var native := native_slots(case_item)
	var out: Dictionary = {}
	for st in native.keys():
		out[st] = int(native[st])
	var ca: Dictionary = case_item.get("attrs", {})
	var cfg = ca.get("config", {})
	if not (cfg is Dictionary):
		return out
	for k in (cfg as Dictionary).keys():
		var st_k := _slot_type_of(str(k))
		if not out.has(st_k):
			continue
		out[st_k] = maxi(int(out[st_k]), _slot_index(str(k)) + 1)
	return out


## 拓展零件提供的槽位归属：slot_key -> 提供它的拓展件的槽位键（如 "gpu1" -> "storage2"）。
## ★ 拓展件可以插在任意普通槽位里（没有专属拓展槽），所以扫描**整份 config**。
## 分配规则：原生槽位先占 [0, native)，拓展件按 config 键的字典序依次向后追加；
## 未安装零件的空位也会列出（用于 UI 画「拓展接口」的黄边框）。
static func dock_layout(case_item: Dictionary) -> Dictionary:
	var ca: Dictionary = case_item.get("attrs", {})
	var cfg: Dictionary = ca.get("config", {})
	if not (cfg is Dictionary):
		return {}
	var nextn: Dictionary = _dock_start_index(case_item)
	var owner: Dictionary = {}
	var keys: Array = cfg.keys()
	keys.sort()
	for dk in keys:
		var dock: Dictionary = get_installed(case_item, str(dk))
		if not _is_dock_item(dock):
			continue
		var prov = dock.get("attrs", {}).get("provides_slots", {})
		if not (prov is Dictionary):
			continue
		for st in prov.keys():
			var cnt := int(prov[st])
			if cnt <= 0:
				continue
			var base := int(nextn.get(st, 0))
			for i in range(cnt):
				owner["%s%d" % [str(st), base + i]] = str(dk)
			nextn[st] = base + cnt
	return owner


## 某个槽位是不是「拓展接口」，是则返回提供它的拓展零件（否则空字典）。
static func dock_owner_of(case_item: Dictionary, slot_key: String) -> Dictionary:
	var owner := dock_layout(case_item)
	if not owner.has(str(slot_key)):
		return {}
	return get_installed(case_item, str(owner[str(slot_key)]))


## 返回各槽位的 { native, docked, total, used }（docked = 已被拓展件占用的拓展接口数）
static func slot_layout(case_item: Dictionary) -> Dictionary:
	var ca: Dictionary = case_item.get("attrs", {})
	var cfg: Dictionary = ca.get("config", {})
	if not (cfg is Dictionary):
		cfg = {}
	var native := native_slots(case_item)
	var owner := dock_layout(case_item)
	var used: Dictionary = {}
	var dock_used: Dictionary = {}
	for key in cfg.keys():
		var st := _slot_type_of(str(key))
		used[st] = int(used.get(st, 0)) + 1
		if owner.has(str(key)):
			dock_used[st] = int(dock_used.get(st, 0)) + 1
	var out: Dictionary = {}
	for st in native.keys():
		var n := int(native[st])
		out[st] = {
			"native": n, "docked": int(dock_used.get(st, 0)),
			"total": n + _dock_provided_count(case_item, st),
			"used": int(used.get(st, 0)),
		}
	return out


## 某槽位类型被拓展件提供了几个位置
static func _dock_provided_count(case_item: Dictionary, slot_type: String) -> int:
	var owner := dock_layout(case_item)
	var n := 0
	for k in owner.keys():
		if _slot_type_of(str(k)) == slot_type:
			n += 1
	return n


# ---------------------------------------------------------------------------
# 配置归一化（保存时的关键一环）
# ---------------------------------------------------------------------------
## 用一份「目标配置」+ 设备外壳属性构造临时设备（只读用）。
static func _probe_case(base_attrs: Dictionary, cfg: Dictionary) -> Dictionary:
	var a: Dictionary = base_attrs.duplicate(true)
	a["config"] = cfg
	return { "attrs": a }


## 把一份「目标配置」规范化：**拓展件被卸下 → 它提供的拓展接口上的零件一并卸下**；
## 主板/硬件变化导致放不下的零件也一并卸下；仍在拓展接口上的零件按新的归属重新编号
## （避免两个同类拓展件只卸掉一个时，另一个的零件索引错位）。
## 返回 { cfg: Dictionary（规范化后的配置）, removed: Array（被一并卸下的槽位键） }
static func normalize_config(old_attrs: Dictionary, new_cfg: Dictionary) -> Dictionary:
	var old_cfg = old_attrs.get("config", {})
	if not (old_cfg is Dictionary):
		old_cfg = {}
	var old_owner := dock_layout(_probe_case(old_attrs, old_cfg))
	var new_case := _probe_case(old_attrs, new_cfg)
	var native := native_slots(new_case)
	var new_owner := dock_layout(new_case)

	# 新布局里每个「拓展件 + 槽位类型」的起始索引与容量
	var base_of: Dictionary = {}
	var cap_of: Dictionary = {}
	var nextn: Dictionary = _dock_start_index(new_case)
	var dks: Array = new_cfg.keys()
	dks.sort()
	for dk in dks:
		var dock: Dictionary = get_installed(new_case, str(dk))
		if not _is_dock_item(dock):
			continue
		var prov = dock.get("attrs", {}).get("provides_slots", {})
		if not (prov is Dictionary):
			continue
		for st2 in prov.keys():
			var cnt := int(prov[st2])
			if cnt <= 0:
				continue
			var tag := "%s|%s" % [str(dk), str(st2)]
			base_of[tag] = int(nextn.get(st2, 0))
			cap_of[tag] = cnt
			nextn[st2] = int(nextn.get(st2, 0)) + cnt

	var out_cfg: Dictionary = {}
	var removed: Array = []
	var pool: Dictionary = {}      # tag -> [{key, part}]（按原索引升序）
	var src: Array = new_cfg.keys()
	src.sort()
	for key in src:
		var k := str(key)
		var part = new_cfg[key]
		if not (part is Dictionary) or (part as Dictionary).is_empty():
			continue
		var st3 := _slot_type_of(k)
		var idx := int(k.substr(st3.length()))
		# 归属：优先按「旧配置里的拓展接口归属」，其次按新配置（新插上的拓展件）
		var owner_dk := ""
		if old_owner.has(k):
			owner_dk = str(old_owner[k])
		elif new_owner.has(k):
			owner_dk = str(new_owner[k])
		if owner_dk != "":
			var tag2 := "%s|%s" % [owner_dk, st3]
			if not base_of.has(tag2):
				removed.append(k)          # ★ 提供该接口的拓展件已被卸下 → 一并卸下
				continue
			if not pool.has(tag2):
				pool[tag2] = []
			pool[tag2].append({ "key": k, "part": part })
		elif idx < int(native.get(st3, 0)):
			out_cfg[k] = part              # 原生槽位：保持原索引
		elif _is_dock_item(part):
			out_cfg[k] = part              # ★ 拓展件自己：它可能落在非原生索引上（正常），保持原位
		else:
			removed.append(k)              # 主板/硬件变化后放不下 → 卸下

	for tag3 in pool.keys():
		var parts: Array = pool[tag3]
		var cap: int = int(cap_of.get(tag3, 0))
		var pos: int = int(base_of.get(tag3, 0))
		var st4 := str(tag3).split("|")[1]
		for i in range(parts.size()):
			var e: Dictionary = parts[i]
			if i >= cap:
				removed.append(str(e.get("key", "")))
				continue
			out_cfg["%s%d" % [st4, pos]] = e.get("part")
			pos += 1
	return { "cfg": out_cfg, "removed": removed }


# ---------------------------------------------------------------------------
# 槽位计数（含拓展零件提供的额外槽位）
# ---------------------------------------------------------------------------
## 返回各槽位的 { total, used }（对外保持旧接口）
static func slot_fill(case_item: Dictionary) -> Dictionary:
	var lay := slot_layout(case_item)
	var out: Dictionary = {}
	for st in lay.keys():
		out[st] = { "total": int(lay[st].get("total", 0)), "used": int(lay[st].get("used", 0)) }
	return out


## 该槽位类别的「规格 + 协议」文本（**空槽位显示它**，不再留白）。
## 普通槽位取主板/外壳声明的规格；拓展接口（黄色）取拓展零件声明的 provides_if。
static func slot_spec_text(case_item: Dictionary, slot_key: String) -> String:
	var st := _slot_type_of(slot_key)
	var ca: Dictionary = case_item.get("attrs", {})
	match st:
		SLOT_MAINBOARD:
			var m := str(ca.get("max_mb_ff", ""))
			return ("≤" + m) if (m != "" and m != DOCK_IF_ANY) else "任意尺寸"
		SLOT_PSU:
			var p := str(ca.get("max_psu_ff", ""))
			return ("≤" + p) if (p != "" and p != DOCK_IF_ANY) else "任意规格"
		SLOT_COOLER:
			return "任意规格"
	var dock := dock_owner_of(case_item, slot_key)
	if not dock.is_empty():
		var pif = dock.get("attrs", {}).get("provides_if", {})
		if pif is Dictionary and pif.has(st):
			return str(pif[st])
		return "不限协议"
	var key := _slot_if_key(st)
	if key == "":
		return ""
	var mb := _mb_item(case_item, {}, SLOT_MAINBOARD)
	var mba: Dictionary = mb.get("attrs", {}) if not mb.is_empty() else {}
	var txt := str(mba.get(key, ""))
	if st == SLOT_GPU:
		var maxg := int(ca.get("max_gpu_len_mm", 0))
		if not dock.is_empty():
			var plim = dock.get("attrs", {}).get("provides_limits", {})
			if plim is Dictionary and plim.has("max_gpu_len_mm"):
				maxg = int(plim["max_gpu_len_mm"])
		if maxg > 0:
			txt += " ≤%dmm" % maxg
	return txt


## 设备状态等级（左列表状态方框用）：
##   "offline"  红 —— 已下线
##   "degraded" 黄 —— **上线了但状态不佳**（散热不足 / 功耗超额定）
##   "online"   绿 —— 在线且状态正常
static func status_level(case_item: Dictionary) -> String:
	var st := computer_stat(case_item)
	if not bool(st.get("online", false)):
		return "offline"
	# ★ 网络器材不做零件 → 没有「散热 / 供电」这两个概念，不该被判成「状态不佳」。
	if is_net_kind(device_kind(case_item)):
		return "online"
	if int(st.get("cooling_total", 0)) <= 0 or not bool(st.get("power_ok", true)):
		return "degraded"
	return "online"


## 该槽位类型第一个空位（无空位返回 ""）
static func first_free_slot(case_item: Dictionary, slot_type: String) -> String:
	var fill := slot_fill(case_item)
	var f = fill.get(slot_type, { "total": 0, "used": 0 })
	var used: int = int(f.get("used", 0))
	for i in range(int(f.get("total", 0))):
		var key: String = slot_type + str(i)
		var inst := get_installed(case_item, key)
		if inst.is_empty():
			return key
	return ""


# ---------------------------------------------------------------------------
# 安装 / 移除：现在由 Devices 单例负责（内嵌零件 + 与背包联动扣减/退回）。
# 这里只保留「兼容性查询」与「列出兼容备件」，供设备安装页复用。
# ---------------------------------------------------------------------------
## 列出可与某槽位兼容的背包零件（用于安装选择器）。
## ★ slot_key 传「真实槽位键」时按该槽位的归属校验接口（拓展接口走拓展零件自己的接口声明）；
##   传空则退回 slot_type + "0"（原生槽位）。
static func list_compatible(case_item: Dictionary, slot_type: String, slot_key: String = "") -> Array:
	var sample := slot_key if slot_key != "" else slot_type + "0"
	var out: Array = []
	for it in Inventory.get_all():
		var tags = it.get("tags", [])
		if not _tag_has(tags, Inventory.TAG_PC_HARDWARE):
			continue
		var acc: Array = _slot_accepts(slot_type)
		var ok_tag := false
		for t in tags:
			if str(t) in acc:
				ok_tag = true
		if not ok_tag:
			continue
		var chk := is_compatible(case_item, it, sample)
		if chk.ok:
			out.append(it)
	return out


# ---------------------------------------------------------------------------
# 上线条件
# ---------------------------------------------------------------------------
## 「电脑最基本的硬件组成」：主板 / CPU / 内存 / 电源（缺一不可）。
## ★ 想调整上线门槛只改这里（例如把 SLOT_COOLER / SLOT_STORAGE 也加进来）。
static func required_online_slots() -> Array:
	return [SLOT_MAINBOARD, SLOT_CPU, SLOT_MEMORY, SLOT_PSU]


## 是否「可联网」：装有可用网卡（data_speed_mbps>0），**或**装有带 eth 口的外设/主板自带网口。
## （现实里主板 I/O 面板上的网口就能联网，不一定要独立网卡。）
static func has_usable_nic(case_item: Dictionary) -> bool:
	var cfg: Dictionary = case_item.get("attrs", {}).get("config", {})
	if not (cfg is Dictionary):
		return false
	for key in cfg.keys():
		var it := get_installed(case_item, key)
		if it.is_empty():
			continue
		var pa: Dictionary = it.get("attrs", {})
		if _slot_type_of(key) == SLOT_NIC and int(pa.get("data_speed_mbps", 0)) > 0:
			return true
		if eth_speed(pa) > 0:
			return true
	return false


## 某零件「网口」总速率（Mbps）：从 attrs.external_ports 里挑 kind == "eth" 的累加。
static func eth_speed(part_attrs: Dictionary) -> int:
	var total := 0
	for e in external_ports_of(part_attrs):
		if str(e.get("kind", "")) == "eth":
			total += int(e.get("speed_mbps", 0)) * maxi(1, int(e.get("count", 1)))
	return total


## 归一化零件的对外接口清单（缺字段时容错）。
static func external_ports_of(part_attrs: Dictionary) -> Array:
	var raw = part_attrs.get("external_ports", [])
	if not (raw is Array):
		return []
	var out: Array = []
	for e in raw:
		if e is Dictionary:
			out.append(e)
	return out


## 装了「网卡」槽位零件（data_speed_mbps > 0）→ 对外接口多 1 个「无线网」。
## ★ 只看**独立网卡**，不看主板自带网口（主板 I/O 上的网口不算「装了网卡」）。
static func has_installed_nic(case_item: Dictionary) -> bool:
	var cfg = case_item.get("attrs", {}).get("config", {})
	if not (cfg is Dictionary):
		return false
	for key in (cfg as Dictionary).keys():
		if _slot_type_of(str(key)) != SLOT_NIC:
			continue
		var it: Dictionary = get_installed(case_item, key)
		if it.is_empty():
			continue
		if int(it.get("attrs", {}).get("data_speed_mbps", 0)) > 0:
			return true
	return false


## 设备「对外接口」清单（统一来源：展示 / 链接 / 空闲计算都基于它）：
##   = attrs.port_specs（自带 + 已建链接的条目，**权威**） + 「装了网卡 → 多 1 个无线网」
##     + 已装零件提供的对外口（主板 I/O、外设卡、拓展坞…）。
## ★ 零件提供的种类若已在「自带/已链接」条目里出现，则不再叠加（自带权威，避免重复计数）；
##   否则累加（多个同类零件，如多张外设卡）。
## ★ 网卡带来的无线网口不落盘（拆掉网卡自动消失）；链接落盘进 attrs.port_specs 对应 wireless 项。
## ★ 这是「设备有哪些接口种类、每种几个、链了几个」的唯一权威——external_port_totals / port_free_totals /
##   port_links / device_port_kinds 都基于它。过去只有「自带口」能链接，电脑的网口（来自主板）点不了；
##   现在零件提供的口也纳入 → 笔记本/台式机也能把网口连到交换机。
static func device_port_specs(dev: Dictionary) -> Array:
	var ca = dev.get("attrs", {})
	var out: Array = []
	var have: Dictionary = {}
	var own_idx: Dictionary = {}
	var raw = ca.get("port_specs", []) if (ca is Dictionary) else []
	if raw is Array:
		for s in raw:
			if s is Dictionary:
				var d: Dictionary = (s as Dictionary).duplicate(true)
				if not (d.get("links") is Dictionary):
					d["links"] = {}
				out.append(d)
				var k := str(d.get("kind", ""))
				have[k] = out.size() - 1
				own_idx[k] = out.size() - 1
	if has_installed_nic(dev):
		if have.has("wireless"):
			var c := int((out[have["wireless"]] as Dictionary).get("count", 0))
			if c >= 0:
				(out[have["wireless"]] as Dictionary)["count"] = c + 1
			own_idx["wireless"] = have["wireless"]
		else:
			out.append(_port_spec("wireless", 1, 1200))
			have["wireless"] = out.size() - 1
			own_idx["wireless"] = have["wireless"]
	var cfg = ca.get("config", {}) if (ca is Dictionary) else {}
	if cfg is Dictionary:
		for key in (cfg as Dictionary).keys():
			var it: Dictionary = get_installed(dev, str(key))
			if it.is_empty():
				continue
			for e in external_ports_of(it.get("attrs", {})):
				var kind := str(e.get("kind", ""))
				if kind == "":
					continue
				var cnt := maxi(1, int(e.get("count", 1)))
				var sp := int(e.get("speed_mbps", 0))
				if have.has(kind):
					if own_idx.has(kind):
						continue   # 自带 / 已链接条目权威，不叠加零件
					var entry = out[have[kind]]
					var cur := int(entry.get("count", 0))
					if cnt < 0 or cur < 0:
						entry["count"] = PORT_UNLIMITED
					else:
						entry["count"] = cur + cnt
					entry["speed_mbps"] = maxi(int(entry.get("speed_mbps", 0)), sp)
				else:
					out.append(_port_spec(kind, cnt, sp))
					have[kind] = out.size() - 1
	# ★ 归并后再滤掉「0 个口」的种类：网卡拆掉后遗留的 wireless 条目（count 0）不应再出现在界面上。
	var keep: Array = []
	for s3 in out:
		if int((s3 as Dictionary).get("count", 0)) != 0:
			keep.append(s3)
	return keep


## 该种类的自带接口总数（PORT_UNLIMITED → 无限）
static func device_port_total(dev: Dictionary, kind: String) -> int:
	for s in device_port_specs(dev):
		if str((s as Dictionary).get("kind", "")) == str(kind):
			return int((s as Dictionary).get("count", 0))
	return 0


## links 里「落在有效编号范围内」的链接数（容忍 count 变小后残留的陈旧链接）
static func _valid_link_count(links: Dictionary, count: int) -> int:
	if count < 0:
		return links.size()
	var n := 0
	for k in links.keys():
		var i := int(str(k))
		if i >= 0 and i < count:
			n += 1
	return n


## 设备自带接口的空闲统计：{ kind: { free, total, speed_max, unlimited } }
##   · free / total = 还能再链接几个 / 总共几个（PORT_UNLIMITED 均为 -1 → 无限）
static func port_free_totals(dev: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for s in device_port_specs(dev):
		var kind := str((s as Dictionary).get("kind", ""))
		if kind == "":
			continue
		var cnt := int((s as Dictionary).get("count", 0))
		var links = (s as Dictionary).get("links", {})
		if not (links is Dictionary):
			links = {}
		var used := _valid_link_count(links, cnt)
		var cur = out.get(kind, { "free": 0, "total": 0, "speed_max": 0, "unlimited": false })
		if cnt < 0:
			cur["unlimited"] = true
			cur["total"] = PORT_UNLIMITED
			cur["free"] = PORT_UNLIMITED
		else:
			cur["total"] = int(cur["total"]) + cnt
			cur["free"] = int(cur["free"]) + maxi(0, cnt - used)
		cur["speed_max"] = maxi(int(cur["speed_max"]), int((s as Dictionary).get("speed_mbps", 0)))
		out[kind] = cur
	return out


## 设备自带的接口种类（决定「对外接口」行里哪些格子可点）
static func device_port_kinds(dev: Dictionary) -> Array:
	var out: Array = []
	for s in device_port_specs(dev):
		var k := str((s as Dictionary).get("kind", ""))
		if k != "" and not out.has(k):
			out.append(k)
	return out


## 设备已有的链接清单：[ { port_key, kind, index, peer_id } ]
static func port_links(dev: Dictionary) -> Array:
	var out: Array = []
	for s in device_port_specs(dev):
		var kind := str((s as Dictionary).get("kind", ""))
		var cnt := int((s as Dictionary).get("count", 0))
		var links = (s as Dictionary).get("links", {})
		if not (links is Dictionary):
			continue
		for k in (links as Dictionary).keys():
			var i := int(str(k))
			if cnt >= 0 and (i < 0 or i >= cnt):
				continue      # 陈旧链接（该口已不存在）→ 不展示
			var peer = (links as Dictionary)[k]
			if not (peer is Dictionary):
				continue
			out.append({
				"port_key": "%s%d" % [kind, i], "kind": kind, "index": i,
				"peer_id": str((peer as Dictionary).get("device_id", "")),
			})
	return out


## 该设备还有空位的自带接口种类（可发起链接的种类）
static func free_port_kinds(dev: Dictionary) -> Array:
	var out: Array = []
	var t := port_free_totals(dev)
	for k in t.keys():
		if int((t[k] as Dictionary).get("free", 0)) != 0:
			out.append(str(k))
	return out


## 某设备某种类接口还能再链接几个（PORT_UNLIMITED = 无限）
static func port_free_count(dev: Dictionary, kind: String) -> int:
	var t := port_free_totals(dev)
	if not t.has(str(kind)):
		return 0
	return int((t[str(kind)] as Dictionary).get("free", 0))


## 某零件的对外口累加进汇总表（count < 0 或已有无限 → 记成无限）
static func _accum_port(out: Dictionary, kind: String, cnt: int, sp: int) -> void:
	if kind == "":
		return
	var cur = out.get(kind, { "count": 0, "speed_max": 0, "speed_sum": 0, "unlimited": false })
	if cnt < 0 or bool(cur.get("unlimited", false)):
		cur["unlimited"] = true
		cur["count"] = PORT_UNLIMITED
	else:
		cur["count"] = int(cur["count"]) + cnt
		cur["speed_sum"] = int(cur["speed_sum"]) + sp * maxi(0, cnt)
	cur["speed_max"] = maxi(int(cur["speed_max"]), sp)
	out[kind] = cur


## 整机对外接口汇总：{ kind: { "count": n（-1=无限）, "speed_max": m, "speed_sum": s, "unlimited": bool } }
## ★ 来源两处：①已装零件提供的（主板 I/O + 外设卡 + 拓展坞）；②设备**自带 / 已链接**的
##   （网络器材的网口/无线网、以及「装了网卡 → 多 1 个无线网」）。
## ★ 以 device_port_specs（自带/已链接，权威）为准覆盖同类目，零件只补「自带里没有」的同类目，
##   既让电脑的网卡/主板口也能被统计与链接，又避免与自带条目重复计数。
static func external_port_totals(case_item: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var cfg = case_item.get("attrs", {}).get("config", {}) if (case_item.get("attrs", {}) is Dictionary) else {}
	if cfg is Dictionary:
		for key in (cfg as Dictionary).keys():
			var it: Dictionary = get_installed(case_item, str(key))
			if it.is_empty():
				continue
			for e in external_ports_of(it.get("attrs", {})):
				_accum_port(out, str(e.get("kind", "")), maxi(1, int(e.get("count", 1))),
					int(e.get("speed_mbps", 0)))
	# 自带 / 已链接条目权威覆盖同类目（count<0 → 无限）
	for s in device_port_specs(case_item):
		var kind := str((s as Dictionary).get("kind", ""))
		if kind == "":
			continue
		var cnt := int((s as Dictionary).get("count", 0))
		var sp := int((s as Dictionary).get("speed_mbps", 0))
		var cur = out.get(kind, { "count": 0, "speed_max": 0, "speed_sum": 0, "unlimited": false })
		if cnt < 0:
			cur["unlimited"] = true
			cur["count"] = PORT_UNLIMITED
			cur["speed_sum"] = PORT_UNLIMITED
		else:
			cur["count"] = cnt
			cur["speed_sum"] = cnt * maxi(0, sp)
		cur["speed_max"] = maxi(int(cur.get("speed_max", 0)), sp)
		out[kind] = cur
	return out


## 整机对外接口一句话描述（UI 展示用，如「网口×2 2500Mbps · USB×6 · 无线网×∞」）。
## ★ 设备**自带**的接口（可链接）显示**空闲数** —— 链接一台设备就 −1，与插槽区「对外接口」格子口径一致。
static func external_port_summary(case_item: Dictionary) -> String:
	var tot := external_port_totals(case_item)
	var free_t := port_free_totals(case_item)
	var names: Array = []
	for kind in tot.keys():
		var sk := str(kind)
		var d: Dictionary = tot[kind]
		var c := int(d.get("count", 0))
		if free_t.has(sk) and c >= 0:
			c = int((free_t[sk] as Dictionary).get("free", c))
		var ctxt := "∞" if c < 0 else str(c)
		var txt := "%s×%s" % [port_zh(sk), ctxt]
		if int(d.get("speed_max", 0)) > 0:
			txt += " %dMbps" % int(d.get("speed_max", 0))
		names.append(txt)
	if names.is_empty():
		return "（无）"
	return " · ".join(names)


## 上线前置条件校验：必须有「最基本硬件组成」且有可用网卡。
## ★ 例外：网络器材（扫描重构器 / 交换机 / 无线网络发生器）**不做零件**，属自带硬件的整机 → 恒可上线。
## 返回 { ok: bool, missing: Array（中文槽位名）, reason: String（中文，ok 时为空） }
static func online_requirement(case_item: Dictionary) -> Dictionary:
	if is_net_kind(device_kind(case_item)):
		return { "ok": true, "missing": [], "reason": "" }
	var fill := slot_fill(case_item)
	var missing: Array = []
	for st in required_online_slots():
		var f = fill.get(st, { "total": 0, "used": 0 })
		if int(f.get("used", 0)) <= 0:
			missing.append(slot_zh(st))
	if not has_usable_nic(case_item):
		var nz := slot_zh(SLOT_NIC)
		if not missing.has(nz):
			missing.append(nz)
	if missing.is_empty():
		return { "ok": true, "missing": [], "reason": "" }
	return { "ok": false, "missing": missing, "reason": "缺少：%s" % "、".join(missing) }


# ---------------------------------------------------------------------------
# 统计聚合
# ---------------------------------------------------------------------------
## 电脑综合属性。返回含算力/功耗/散热/容量/在线/槽位占用/告警的字典。
static func computer_stat(case_item: Dictionary) -> Dictionary:
	var ca: Dictionary = case_item.get("attrs", {})
	var cfg: Dictionary = ca.get("config", {})
	if not (cfg is Dictionary):
		cfg = {}
	var mb := _mb_item(case_item, {}, SLOT_MAINBOARD)
	var chassis := str(ca.get("chassis_type", ""))
	# ★ 网络器材（不做零件）不参与「主板 / 电源 / 散热」这类电脑硬件告警。
	var kind := device_kind(case_item)
	var is_net := is_net_kind(kind)

	var compute_raw := 0
	var power_used := 0
	var power_cap := 0
	var cooling := 0
	var ssd_cap := 0
	var hdd_cap := 0
	# 在线状态：新模型优先读设备顶层 "online" 字段；旧模型（无 online 键）靠网卡判定。
	var online := false
	if case_item.has("online"):
		online = bool(case_item.get("online", false))
	var _nic_online := false
	var warnings: Array = []

	# 槽位归属：由 slot_layout / dock_layout 统一判定谁在「拓展接口」上
	var lay := slot_layout(case_item)
	var owner := dock_layout(case_item)

	for key in cfg.keys():
		var st := _slot_type_of(key)
		var it: Dictionary = get_installed(case_item, key)
		if it.is_empty():
			continue
		var pa: Dictionary = it.get("attrs", {})
		# 是否插在拓展零件提供的槽位（拓展接口）→ 算力打折、散热额外惩罚
		var via_dock := owner.has(str(key))

		var cs := int(pa.get("compute_score", 0))
		if via_dock:
			cs = int(float(cs) * DOCK_COMPUTE_MULT)
		compute_raw += cs

		var pw := int(pa.get("power_w", 0))
		power_used += pw

		var cl := int(pa.get("cooling_score", 0))
		if via_dock:
			cl += DOCK_COOLING_PENALTY
		cooling += cl

		var pt := str(pa.get("part_type", ""))
		if pt == "psu":
			power_cap += int(pa.get("power_supply_w", 0))
		elif pt == "dock":
			# ★ 显卡坞等自带电源的拓展件：额定功率计入整机供电
			power_cap += int(pa.get("power_supply_w", 0))
		elif pt == "ssd":
			ssd_cap += int(pa.get("storage_capacity_gb", 0))
		elif pt == "hdd":
			hdd_cap += int(pa.get("storage_capacity_gb", 0))
		elif pt == "nic":
			if int(pa.get("data_speed_mbps", 0)) > 0:
				_nic_online = true
		if eth_speed(pa) > 0:
			_nic_online = true

	if not is_net:
		if mb.is_empty():
			warnings.append("未安装主板")
		if power_cap <= 0:
			warnings.append("未安装电源")
		elif power_used > power_cap:
			warnings.append("功耗 %dW 超过电源额定 %dW" % [power_used, power_cap])
	if case_item.has("online"):
		if not bool(case_item.get("online", false)):
			warnings.append("设备已下线")
	else:
		if not _nic_online:
			warnings.append("未安装可用网卡（离线）")
	if not is_net and cooling <= 0:
		warnings.append("散热不足（总散热 %d）" % cooling)
	# 拓展接口上的零件：给出提示（性能有折扣）
	var dock_used := 0
	for key2 in cfg.keys():
		if owner.has(str(key2)):
			dock_used += 1
	if dock_used > 0:
		warnings.append("有 %d 个零件装在拓展接口上（算力 ×%.1f，散热 %d）" % [
			dock_used, DOCK_COMPUTE_MULT, DOCK_COOLING_PENALTY])

	# 散热正收益 -> 算力加成
	var bonus_pct := 0
	if cooling > 0:
		bonus_pct = mini(cooling, COOLING_BONUS_CAP)
	var compute_final := int(float(compute_raw) * (1.0 + float(bonus_pct) / 100.0))

	return {
		"chassis_type": chassis,
		"device_kind": kind,
		"online": online,
		"power_used": power_used,
		"power_cap": power_cap,
		"power_ok": (power_cap <= 0 or power_used <= power_cap),
		"cooling_total": cooling,
		"cooling_bonus_pct": bonus_pct,
		"compute_raw": compute_raw,
		"compute_final": compute_final,
		"ssd_capacity": ssd_cap,
		"hdd_capacity": hdd_cap,
		"slot_fill": slot_fill(case_item),
		"slot_layout": lay,
		"dock_used": dock_used,
		"ports": external_port_totals(case_item),
		"ports_text": external_port_summary(case_item),
		"warnings": warnings,
	}


## 全背包「在线电脑」的 固态/机械 容量合计现由 Devices.total_storage_capacity() 提供
## （设备系统独立于背包，见 autoload/devices.gd）。
