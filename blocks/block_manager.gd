# block_manager.gd
# 自动加载单例：负责「积木」的 ID 分配与注册（本次必须完成的部分）。
# 注册方式见 project.godot 的 [autoload]：BlockManager="*res://blocks/block_manager.gd"
# 注意：本脚本作为 autoload 单例，其全局名已是 "BlockManager"，
# 因此这里不再声明 class_name（否则会与 autoload 单例重名，触发
# “Class 'BlockManager' hides an autoload singleton” 报错）。
extends Node

var _next_id: int = 1
var _registry: Dictionary = {}   # ID -> Block
var _string_registry: Dictionary = {}   # string_id -> Block（字符串 ID 与数字 ID 并存）
# 注册表变更计数：任何 ID 的注册/注销/改写后 +1。
# 供 UI（调试面板「选择ID」下拉）判断是否需要重刷——桌面图标/屏障会周期性重建，
# 不重刷则下拉里会残留已销毁的 ID，点选后「没反应」。
var registry_version: int = 0

func _bump_registry_version() -> void:
	registry_version += 1

func _ready() -> void:
	pass

## 为新积木分配唯一 ID。
## ID 规则（时间基）：以「创建时刻」为基，格式 YYYYMMDDHHMMSS（14 位整数）；
## 同一秒内创建多块时，第 1 块用纯时间戳（无后缀），后续块追加 _num 数字后缀
## （ts*100 + seq，seq 从 1 递增）避免冲突。
## 若积木已带合法且未冲突的 ID（如读档），则保留并登记，不重生成。
func allocate_id(block: Block) -> int:
	if block.id > 0 and _registry.has(block.id):
		if _registry[block.id] == block:
			return block.id
		# 被别的积木占用 → 重新分配
	else:
		if block.id > 0:
			# 有合法 ID 但未登记（如读档），直接登记
			_registry[block.id] = block
			if block.id >= _next_id:
				_next_id = block.id + 1
			return block.id
	var id := _make_time_id()
	_registry[id] = block
	block.id = id
	if id >= _next_id:
		_next_id = id + 1
	_bump_registry_version()
	return id

## 生成「创建时刻基」ID：YYYYMMDDHHMMSS（14 位）。
## 同秒第 1 块 → 纯时间戳（无后缀）；同秒后续块 → 追加 _num 数字后缀直到拿到空闲 ID。
## 注：因同秒第 1 块是 14 位、后缀块是 16 位，后缀块在 get_all_ids() 升序里会排到末尾，
## 属正常（同秒碰撞罕见），不影响唯一性与下拉选取。
func _make_time_id() -> int:
	var t := Time.get_datetime_dict_from_system(false)
	var ts: int = int(t.year) * 10000000000 \
		+ int(t.month) * 100000000 \
		+ int(t.day) * 1000000 \
		+ int(t.hour) * 10000 \
		+ int(t.minute) * 100 \
		+ int(t.second)
	# 同秒第 1 块：纯时间戳（无后缀）
	if not _registry.has(ts):
		return ts
	# 同秒后续块：ts * 100 + _num（seq 从 1 递增），直到空闲
	var seq: int = 1
	var candidate: int = ts * 100 + seq
	while _registry.has(candidate):
		seq += 1
		candidate = ts * 100 + seq
	return candidate

## 强制指定 ID（用于读档/调试）；被占用或非法返回 false
func set_id(block: Block, id: int) -> bool:
	if id <= 0:
		push_error("BlockManager: ID 必须为正整数")
		return false
	if _registry.has(id) and _registry[id] != block:
		push_error("BlockManager: ID %d 已被占用" % id)
		return false
	if block.id > 0 and _registry.has(block.id):
		_registry.erase(block.id)
	_registry[id] = block
	block.id = id
	if id >= _next_id:
		_next_id = id + 1
	_bump_registry_version()
	return true

## 重新指定某积木的 ID（属性面板「积木ID」栏修改时使用）。
## 会同步重映射其它积木对该旧 ID 的父级/子级引用，避免绑定断裂。
## new_id<=0、已被其它积木占用、或 block 无效 → 返回 false；未变化(new_id==旧ID)→ 返回 true。
func reassign_id(block: Block, new_id: int) -> bool:
	if block == null or not is_instance_valid(block):
		return false
	if new_id <= 0:
		return false
	if new_id == block.id:
		return true
	if _registry.has(new_id) and _registry[new_id] != block:
		return false
	var old_id: int = block.id
	# 更新注册表：先摘旧键，再挂新键
	if old_id > 0 and _registry.has(old_id) and _registry[old_id] == block:
		_registry.erase(old_id)
	_registry[new_id] = block
	block.id = new_id
	if new_id >= _next_id:
		_next_id = new_id + 1
	# 重映射其它积木对旧 ID 的引用（父级/子级绑定），避免成环或悬空
	for other in _registry.values():
		# ★★ 守卫顺序：**必须先 is_instance_valid 再 `is Block`**（同 portal_manager / block.gd）。
		#   _registry 只保证「登记过」：积木 queue_free 后条目仍留在表里（无人调用 unregister 时）
		#   → 这里可能拿到已释放实例。对已释放实例执行 `is` 会抛
		#   「previously freed instance」硬脚本错误；旧写法把 `other is not Block` 放在前面，
		#   正好踩中本项目「is 绝不作用于已释放实例」这条硬规则。
		if not is_instance_valid(other) or other == block or not (other is Block):
			continue
		if other.has_method("get_parent_id") and other.get_parent_id() == old_id:
			other.set_parent_id(new_id)
		if other.has_method("get_child_ids"):
			var kids: Array = other.get_child_ids()
			if int(old_id) in kids:
				var new_kids: Array = []
				for k in kids:
					new_kids.append(new_id if int(k) == old_id else k)
				other.set_child_ids(new_kids)
	_bump_registry_version()
	return true

## 按 ID 取积木（已被释放的条目视为不存在，避免返回悬空引用）
func get_block(id: int) -> Block:
	var b = _registry.get(id, null)
	if is_instance_valid(b) and b is Block:
		return b
	return null

## 积木销毁/移除时注销（数字 ID 与字符串 ID 一起摘除）
func unregister(block: Block) -> void:
	if block.id > 0 and _registry.has(block.id) and _registry[block.id] == block:
		_registry.erase(block.id)
	if block.string_id != "" and _string_registry.get(block.string_id, null) == block:
		_string_registry.erase(block.string_id)
	_bump_registry_version()

# ============================ 字符串 ID ============================

## 为积木指定字符串 ID（系统生成的积木按固定规则命名，如 BedRockXU / 收藏夹(560,120)U）。
## 一块积木同一时刻只持有一个字符串 ID（换绑时自动摘旧挂新）。
## 返回 false：block 无效 / sid 为空 / sid 已被**其它有效积木**占用（此时 push_warning，不改状态）。
func set_string_id(block: Block, sid: String) -> bool:
	if block == null or not is_instance_valid(block):
		return false
	if sid.is_empty():
		return false
	var holder: Variant = _string_registry.get(sid, null)
	# ★ 先 is_instance_valid 再 `is Block`（对已释放实例用 `is` 会报错）
	if is_instance_valid(holder) and holder is Block and holder != block:
		push_warning("BlockManager: 字符串 ID '%s' 已被积木 id=%d 占用" % [sid, holder.id])
		return false
	# 摘掉本积木旧字符串 ID
	for k in _string_registry.keys():
		if _string_registry[k] == block:
			_string_registry.erase(k)
			break
	_string_registry[sid] = block
	block.string_id = sid
	_bump_registry_version()
	return true

## 清空积木的字符串 ID（无 ID 或非持有者则不起作用）；返回是否确实清除。
func clear_string_id(block: Block) -> bool:
	if block == null or not is_instance_valid(block):
		return false
	if block.string_id.is_empty():
		return false
	for k in _string_registry.keys():
		if _string_registry[k] == block:
			_string_registry.erase(k)
			break
	block.string_id = ""
	_bump_registry_version()
	return true

## 按字符串 ID 取积木（不存在 / 已释放 → null）
func get_block_by_string_id(sid: String) -> Block:
	var b: Variant = _string_registry.get(sid, null)
	if is_instance_valid(b) and b is Block:
		return b
	return null

## 列出全部有效字符串 ID（升序），供调试面板 / 脚本枚举
func get_all_string_ids() -> Array[String]:
	var ids: Array[String] = []
	for k in _string_registry.keys():
		var b: Variant = _string_registry[k]
		if is_instance_valid(b) and b is Block:
			ids.append(String(k))
	ids.sort()
	return ids

func count() -> int:
	return _registry.size()

func next_id() -> int:
	return _next_id

## 列出所有已注册且未释放的积木 ID（升序），供调试面板等按 ID 枚举场景内积木
func get_all_ids() -> Array[int]:
	var ids: Array[int] = []
	for k in _registry.keys():
		var b = _registry[k]
		if is_instance_valid(b) and b is Block:
			ids.append(int(k))
	ids.sort()
	return ids
