# autoload/global_net.gd
# 「全球网络」环境状态 —— 单例（autoload 名：GlobalNet）。
#
# 设计要点（需求：「就如同现实网络那般，交换机要可以连接到全球网络；是否连接到全球网络的状态
# 会成为游戏环境的一部分，要预留接口用来检测」）：
#   · 交换机自身有一个开关（落在 devices.json 的 attrs.global_net），控制它是否接入全球网络。
#   · 「全球网络本身是否可用」是**环境级**开关（`set_global_up`），留给剧情 / 事件链拨动。
#   · 其它系统只需要两个只读接口：
#       GlobalNet.is_global_net_up()              → 全球网络环境是否可用
#       GlobalNet.is_on_global_network(device_id) → 某台设备此刻是否连得上全球网络
#     以及 `changed` 信号（任何相关状态变化都会发一次，方便轮询方改成事件驱动）。
#
# ★ 本脚本作为 autoload 单例（名 GlobalNet），故不声明 class_name（否则与 autoload 名冲突）。
extends Node
# 外部一律用全局名 GlobalNet.xxx 访问。

signal changed

## 全球网络环境是否可用（环境级；默认可用，留给剧情 / 事件链拨动）
var _global_up: bool = true


func _ready() -> void:
	# 设备侧状态变化（拆解交换机 / 建新链接）也会影响「谁在全球网络上」→ 转发一次信号。
	if not Devices.changed.is_connected(_on_devices_changed):
		Devices.changed.connect(_on_devices_changed)


func _on_devices_changed() -> void:
	changed.emit()


# ---------------------------------------------------------------------------
# 环境级：全球网络本身
# ---------------------------------------------------------------------------
func is_global_net_up() -> bool:
	return _global_up


func set_global_up(on: bool) -> void:
	if _global_up == on:
		return
	_global_up = on
	changed.emit()


# ---------------------------------------------------------------------------
# 设备级：交换机开关 + 可达性检测
# ---------------------------------------------------------------------------
## 该设备是不是「交换机」（只有交换机才有「连接全球网络」开关）
func is_switch(device_id: String) -> bool:
	var dev: Dictionary = Devices.get_device(str(device_id))
	if dev.is_empty():
		return false
	return PCHardware.device_kind(dev) == PCHardware.KIND_SWITCH


## 交换机自身的开关状态（非交换机 → false）
func switch_state(device_id: String) -> bool:
	return Devices.global_net_state(str(device_id))


## 拨动交换机的「连接全球网络」开关（写回 devices.json）。非交换机 → false（拒绝）。
func set_switch(device_id: String, on: bool) -> bool:
	var r := Devices.set_global_net(str(device_id), bool(on))
	if r:
		changed.emit()
	return r


## ★ 核心检测接口：该设备此刻是否连得上「全球网络」。
## 判定（够用且不引入无限递归）：
##   · 全球网络环境不可用 → 一律 false；
##   · 设备自己就是一台「已接入全球网络」的交换机 → true；
##   · 设备的某个链接对端是那样的交换机 → true（单跳）。
func is_on_global_network(device_id: String) -> bool:
	if not _global_up:
		return false
	var dev: Dictionary = Devices.get_device(str(device_id))
	if dev.is_empty():
		return false
	if PCHardware.device_kind(dev) == PCHardware.KIND_SWITCH and Devices.global_net_state(str(device_id)):
		return true
	for lk in PCHardware.port_links(dev):
		var peer := str((lk as Dictionary).get("peer_id", ""))
		if peer == "":
			continue
		var pdev: Dictionary = Devices.get_device(peer)
		if pdev.is_empty():
			continue
		if PCHardware.device_kind(pdev) == PCHardware.KIND_SWITCH and Devices.global_net_state(peer):
			return true
	return false


## 已接入全球网络的交换机（id 数组）
func connected_switches() -> Array:
	var out: Array = []
	if not _global_up:
		return out
	for d in Devices.get_devices():
		var id := str((d as Dictionary).get("id", ""))
		if id == "":
			continue
		if PCHardware.device_kind(d) == PCHardware.KIND_SWITCH and Devices.global_net_state(id):
			out.append(id)
	return out


## 环境状态快照（「成为游戏环境的一部分」：其它系统读这一个字典即可）
func state() -> Dictionary:
	var sws: Array = []
	for d in Devices.get_devices():
		if PCHardware.device_kind(d) != PCHardware.KIND_SWITCH:
			continue
		var id := str((d as Dictionary).get("id", ""))
		sws.append({ "id": id, "name": str((d as Dictionary).get("name", "")),
			"on_global": Devices.global_net_state(id) })
	return {
		"global_up": _global_up,
		"switches": sws,
		"connected_switch_count": connected_switches().size(),
	}
