# signal_bus.gd
# 「信号总线」单例（autoload 名：SignalBus）。
# 把任意积木的按钮信号（button_XXX 双击发出）汇流到一个全局出口，
# 供事件链 / 脚本 / 关卡页面统一监听 —— 不依赖与某块具体积木直接 connect。
# 注册见 project.godot [autoload]：SignalBus="*res://autoload/signal_bus.gd"
extends Node

## 任一积木双击发出按钮信号（signal_name 为 button_XXX 里的 XXX）
signal block_button(signal_name: String)

# block.gd 双击按钮 → 转发到总线（见 Block._register_click）
func emit_block_button(signal_name: String) -> void:
	block_button.emit(signal_name)