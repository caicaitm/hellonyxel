# context_menu.gd
# 右键菜单（代码构建，不依赖 .tscn）
# API:
#   open(at_pos, items)   items: Array[Dictionary]
#     { "label": "...", "id": "...", "submenu": [...]? }
#     { "separator": true }
#   close()
#   is_open()
# signal: item_selected(id, submenu_path)  —— 按下有效按钮时触发
extends Control
class_name ContextMenu

signal item_selected(id: String, submenu_path: PackedStringArray)

const PANEL_PADDING: float = 4.0
const BTN_SPACING: float = 2.0
const BTN_HEIGHT: float = 28.0
const BTN_MIN_WIDTH: float = 120.0
const SUBMENU_GAP: float = 4.0
const BTN_HORIZ_PADDING: float = 12.0

var _panel: UIPanel
var _items_container: Control
var _items: Array = []
var _submenu_path: PackedStringArray = PackedStringArray()
var _submenu_popup: SubMenu = null
# ★★ open() 是**跨帧协程**（内部 await ×2），但调用方 desktop.gd 是 fire-and-forget（不 await）。
#   连续/快速右键会让多个 open() 协程**同时挂起**在同一个 _items_container 上：
#   后一次 open() 的 _clear() 会 **同步 free()** 掉前一次已构建的子节点，
#   前一次协程 resume 后就会遍历/操作这批已释放节点 → use-after-free（可致 native signal 11）。
#   用「代际计数器」让旧协程在每个 await 之后自行作废；另加 is_instance_valid 兜底。
var _open_gen: int = 0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_panel = UIPanel.new()
	_panel.name = "UIPanel"
	_panel.set_corner_radius(UIStyle.CORNER_RADIUS)
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_panel)
	_items_container = Control.new()
	_items_container.name = "ItemsContainer"
	_items_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_items_container)
	visible = false
	resized.connect(_on_resized)

func _on_resized() -> void:
	# ★ is_instance_valid 兜底：_panel/_items_container 可能已被释放（避免对已释放节点设 size）。
	if is_instance_valid(_panel):
		_panel.size = size
	if is_instance_valid(_items_container):
		_items_container.size = size

func open(at_pos: Vector2, items: Array, path: PackedStringArray = PackedStringArray()) -> void:
	_open_gen += 1
	var my_gen: int = _open_gen
	_items = items.duplicate(true)
	_submenu_path = path
	_clear()
	_build_items()
	await get_tree().process_frame
	# ★ 本次 open 期间若又来了新的 open()（或本菜单已被释放）→ 本协程作废，不再碰任何节点。
	if my_gen != _open_gen or not is_inside_tree():
		return
	var font = UIStyle.get_cjk_font()
	var max_label_w: float = 0.0
	for it in _items:
		var item: Dictionary = it
		if item.get("separator", false):
			continue
		var label: String = str(item.get("label", "?"))
		if item.get("submenu", []).size() > 0:
			label += " ▶"
		var lw: float = 0.0
		if font != null:
			lw = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, UIStyle.FONT_SIZE).x
		else:
			lw = label.length() * (UIStyle.FONT_SIZE * 0.6)
		var total: float = lw + BTN_HORIZ_PADDING * 2.0
		if total > max_label_w:
			max_label_w = total
	var max_w: float = max(max_label_w, BTN_MIN_WIDTH) + PANEL_PADDING * 2.0
	var y: float = PANEL_PADDING
	# ★ _items_container 本身若已被释放 → 直接放弃（下方还有二次 await，风险更高）。
	if not is_instance_valid(_items_container):
		return
	for child in _items_container.get_children():
		# ★ is_instance_valid 兜底：即便有别的路径释放了子节点，也不对已释放实例调方法。
		if not is_instance_valid(child):
			continue
		if child is UIBtn:
			child._force_size(Vector2(max_w - PANEL_PADDING * 2.0, BTN_HEIGHT))
			child.position = Vector2(PANEL_PADDING, y)
			y += BTN_HEIGHT + BTN_SPACING
		elif child is HSeparator:
			var sep: HSeparator = child
			sep.size = Vector2(max_w - PANEL_PADDING * 2.0, 6.0)
			sep.position = Vector2(PANEL_PADDING, y)
			y += 6.0
	var total_h: float = y + PANEL_PADDING
	size = Vector2(max_w, total_h)
	await get_tree().process_frame
	# ★ 第二次 await 之后同样复检：本菜单可能已被 close()/释放，或已有更新的 open 接管。
	if my_gen != _open_gen or not is_inside_tree():
		return
	if not is_instance_valid(_panel) or not is_instance_valid(_items_container):
		return
	# ★ 夹取范围要用**画布坐标**下的可见区（本菜单在 ui_layer 内，层可能带 UI 缩放）：
	#   直接读 get_visible_rect() 得到的是视口像素 → 缩放 ≠ 1 时菜单会夹不到位/被摆到屏幕外。
	var vp_size: Vector2 = UIStyle.canvas_viewport_size(self)
	var final_pos: Vector2 = at_pos
	if final_pos.x + size.x > vp_size.x:
		final_pos.x = at_pos.x - size.x
	if final_pos.y + size.y > vp_size.y:
		final_pos.y = at_pos.y - size.y
	if final_pos.x < 0.0:
		final_pos.x = 4.0
	if final_pos.y < 0.0:
		final_pos.y = 4.0
	global_position = final_pos
	visible = true
	if _submenu_popup and is_instance_valid(_submenu_popup):
		_submenu_popup.close()

func close() -> void:
	visible = false
	# ★ 作废可能仍挂起的 open() 协程：关闭后旧协程 resume 不应再动任何节点。
	_open_gen += 1
	if _submenu_popup and is_instance_valid(_submenu_popup):
		_submenu_popup.close()
		_submenu_popup.queue_free()
		_submenu_popup = null

func is_open() -> bool:
	return visible

func _clear() -> void:
	# ★★ 2026-10-05 崩溃取证后改写：**不再同步 free()**，改为 remove_child + queue_free。
	#   原注释说"必须同步释放，否则旧按钮与新增按钮并存、y 起点被反复累加 + 残影"——
	#   但那个症状的**真正解法是 `remove_child`**：它当场就把子节点从 _items_container
	#   的 children 列表里摘掉，本函数之后的 _build_items()/尺寸计算看到的已经是空列表。
	#   而 `child.free()` 额外做的是「**当场析构**」——在信号派发链里同步析构一个
	#   刚被点过/正被 hover 的 Control，正是本项目反复踩到的 native signal 11 制造方式
	#   （同 ui_btn.gd 注释、desktop 行内重建列表的历史崩溃）。
	#   所以：摘掉 → 立刻隐藏 + 不再吃鼠标（本帧剩余时间不会有残影/误点）→ 排队释放。
	if not is_instance_valid(_items_container):
		return
	for child in _items_container.get_children():
		if not is_instance_valid(child):
			continue
		_items_container.remove_child(child)
		if child is CanvasItem:
			(child as CanvasItem).visible = false
		if child is Control:
			(child as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		child.queue_free()

func _build_items() -> void:
	for it in _items:
		var item: Dictionary = it
		if item.get("separator", false):
			var sep := HSeparator.new()
			sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_items_container.add_child(sep)
			continue
		var btn := UIBtn.new()
		var label_text: String = str(item.get("label", "?"))
		if item.get("submenu", []).size() > 0:
			label_text += " ▶"
		btn.set_label(label_text)
		btn.set_id(str(item.get("id", "")))
		btn.pressed_id.connect(_on_item_pressed.bind(item))
		_items_container.add_child(btn)

func _on_item_pressed(id: String, item: Dictionary) -> void:
	var sub_data: Array = item.get("submenu", [])
	if sub_data.size() > 0:
		if _submenu_popup and is_instance_valid(_submenu_popup) and _submenu_popup.visible:
			_submenu_popup.close()
			_submenu_popup.queue_free()
			_submenu_popup = null
		else:
			var src_btn: UIBtn = null
			if is_instance_valid(_items_container):
				for child in _items_container.get_children():
					# ★ 必须先 is_instance_valid 再 `is UIBtn`：子节点可能已被释放，
					#   对已释放实例执行 `is` 会抛「previously freed instance」硬脚本错误。
					if not is_instance_valid(child):
						continue
					if child is UIBtn and (child as UIBtn)._id == id:
						src_btn = child
						break
			if src_btn != null:
				_open_submenu(src_btn, sub_data, id)
		return
	var full_path: PackedStringArray = PackedStringArray(_submenu_path)
	full_path.append(id)
	item_selected.emit(id, full_path)
	_close_chain()

func _open_submenu(btn: UIBtn, sub_data: Array, id: String) -> void:
	# ★ btn 可能已被释放（_on_item_pressed 到这里的路径经过信号派发）→ 取坐标前先校验。
	if not is_instance_valid(btn):
		return
	if _submenu_popup and is_instance_valid(_submenu_popup):
		_submenu_popup.close()
		_submenu_popup.queue_free()
		_submenu_popup = null
	_submenu_popup = SubMenu.new()
	add_child(_submenu_popup)
	var new_path: PackedStringArray = PackedStringArray(_submenu_path)
	new_path.append(id)
	_submenu_popup.open(
		Vector2(btn.global_position.x + btn._get_self_size().x + SUBMENU_GAP, btn.global_position.y),
		sub_data, new_path
	)
	_submenu_popup.item_selected.connect(_on_submenu_selected)

func _on_submenu_selected(id: String, full_path: PackedStringArray) -> void:
	item_selected.emit(id, full_path)
	_close_chain()

func _close_chain() -> void:
	var root: Node = self
	while root.get_parent() != null and root.get_parent() is ContextMenu:
		root = root.get_parent()
	if root is ContextMenu:
		root.close()
