# global_vars.gd
# 「全局变量」单例（autoload 名：GlobalVars）。
# 事件链 / 脚本 / 关卡页面 通过这里读写命名全局变量；任何变量值变化都会发出 changed 信号，
# 供绑定的 UI（如关卡页面顶部的文字框）实时刷新。
#
# 注册见 project.godot [autoload]：GlobalVars="*res://autoload/global_vars.gd"
extends Node

## 任一全局变量变化时发出（旧值 != 新值才发，避免无谓刷新）
signal changed(var_name: String, value: Variant)

var _vars: Dictionary = {}


func _ready() -> void:
	# 关卡页面顶部标题默认绑定的变量：改它 = 标题文字跟着变
	if not _vars.has("level_title"):
		set_var("level_title", "神秘的一关")


## 设置变量；值有变化才发 changed
func set_var(var_name: String, value: Variant) -> void:
	var old: Variant = _vars.get(var_name, null)
	_vars[var_name] = value
	if old != value:
		changed.emit(var_name, value)


## 读取变量（缺失返回 default）
func get_var(var_name: String, default: Variant = null) -> Variant:
	return _vars.get(var_name, default)


## 供 TextRenderer 的 $变量 求值统一走这里（缺失返回空串）
func resolve(var_name: String) -> Variant:
	return get_var(var_name, "")


## 全部变量快照（调试 / 存档用）
func dump() -> Dictionary:
	return _vars.duplicate()