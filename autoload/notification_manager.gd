# autoload/notification_manager.gd
# 通知管理器（autoload 名：NotificationManager）
#
# 职责：
#   - 把 NotificationPanel 挂到独立的 CanvasLayer（高于桌面 ui_layer 100，用 150），
#     确保通知浮在积木/面板之上、贴近任务栏上沿显示。
#   - 通过 show() 一处触发；多个通知同时弹出时，把已有通知向上让位堆叠。
#
# 使用：NotificationManager.show("该喝水了", [{"id":"ok","label":"知道了"}], 5.0)
#   buttons: 0~2 个 {id, label}；按钮点击通过信号回调，需自行 connect 返回值。
extends Node

const SLOT_STEP := 74.0   # 新通知弹出时，已有通知每次上移的步长

var _layer: CanvasLayer
var _active: Array = []


func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 150
	add_child(_layer)
	# ★ 通知也是「面板」：跟随设置里的 UI 缩放（取不到 SaveManager 时按 1.0 处理）
	UIStyle.watch_ui_scale(_layer)


# 弹出一条通知，返回对应 NotificationPanel（可连接其 button_pressed 信号）。
func show(text: String, buttons: Array = [], timeout: float = 5.0) -> NotificationPanel:
	var panel := NotificationPanel.new()
	panel.init(text, buttons, timeout)
	panel.closed.connect(_on_panel_closed.bind(panel))
	_layer.add_child(panel)
	for p in _active:
		if is_instance_valid(p):
			p.position.y -= SLOT_STEP
	_active.append(panel)
	return panel


func _on_panel_closed(panel: NotificationPanel) -> void:
	_active.erase(panel)


# 关闭全部活动通知（供事件链执行器 close:notification 等用途）
func close_all() -> void:
	for p in _active.duplicate():
		if is_instance_valid(p):
			p.dismiss()