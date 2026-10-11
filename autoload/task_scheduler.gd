# task_scheduler.gd
# 「系统任务表」加载器。
# 读取 %Documents%\HelloNyxel\Temp\task_schedule.json（与 sysinfo.json 同目录），
# 表内记录「事件在哪个日期触发」，例如某农作物在几号进入下一成长阶段、
# 某事件链的某个事件应在几号触发。
#
# 事件系统尚未实现，此处只负责：
#   1) 进入游戏时读取该文件并解析（失败不崩溃，仅告警）；
#   2) 判定其中哪些事件在今天(月/日)触发，存入 today_events 供将来使用。
#
# 约定（task_schedule.json 结构）：
#   {
#     "version": 1,
#     "events": [
#       {
#         "id":      "唯一id",
#         "kind":    "事件类型(如 crop_stage / event_chain)",
#         "year":    null 或 数字（null=每年都触发；数字=仅该年触发）,
#         "month":   1~12,
#         "day":     1~31,
#         "note":    "说明（可选）",
#         "payload": { ... 事件系统将来读取的自定义数据 ... }
#       }
#     ]
#   }
extends Node

# 与 sysinfo.json 同目录的相对路径（相对 %Documents%）
const SCHEDULE_SUBDIR := "HelloNyxel/Temp/task_schedule.json"

# 解析出来的绝对路径
var schedule_path: String = ""
# 原始表内容（解析后的 Dictionary）
var schedule: Dictionary = {}
# 「今天需要触发」的事件数组（元素为 events[] 里的条目）
var today_events: Array = []


func _ready() -> void:
	_resolve_schedule_path()
	_load_schedule()
	_collect_today_events()
	print("[TaskScheduler] 已读取系统任务表：%s（共 %d 条事件，今天触发 %d 条）" % [
		schedule_path, schedule.get("events", []).size(), today_events.size()])
	for ev in today_events:
		print("  [今天触发] id=%s kind=%s" % [ev.get("id", ""), ev.get("kind", "")])


# ---- 对外接口 ----

## 全部事件数组（供将来事件系统查询）
func get_events() -> Array:
	return schedule.get("events", [])


## 按 id 取单条事件；找不到返回 null
func get_event(id: String) -> Variant:
	for ev in schedule.get("events", []):
		if ev is Dictionary and str(ev.get("id", "")) == id:
			return ev
	return null


## 今天触发的事件（已按任务表日期过滤）
func get_today_events() -> Array:
	return today_events


# ---- 内部 ----

func _resolve_schedule_path() -> void:
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs.is_empty():
		docs = OS.get_environment("USERPROFILE")
	schedule_path = docs.path_join(SCHEDULE_SUBDIR)


func _load_schedule() -> void:
	# 文件缺失/打不开/解析失败 → 空表 + 告警，绝不抛错
	if schedule_path.is_empty():
		return
	if not FileAccess.file_exists(schedule_path):
		push_warning("[TaskScheduler] 未找到任务表：%s" % schedule_path)
		return
	var f := FileAccess.open(schedule_path, FileAccess.READ)
	if f == null:
		push_warning("[TaskScheduler] 任务表打不开：%s" % schedule_path)
		return
	var txt := f.get_as_text()
	f.close()
	var parser := JSON.new()
	if parser.parse(txt) != OK:
		push_warning("[TaskScheduler] 任务表解析失败（第 %d 行）：%s" % [
			parser.get_error_line(), parser.get_error_message()])
		return
	var data: Variant = parser.data
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("[TaskScheduler] 任务表根节点不是 JSON 对象")
		return
	schedule = data


func _collect_today_events() -> void:
	var events: Array = schedule.get("events", [])
	if events.is_empty():
		return
	var today := Time.get_date_dict_from_system()
	var ty: int = today["year"]
	var tm: int = today["month"]
	var td: int = today["day"]
	today_events.clear()
	for ev in events:
		if typeof(ev) != TYPE_DICTIONARY:
			continue
		var year: Variant = ev.get("year", null)
		if year != null and year != ty:
			continue  # 指定了年份且不是今年 → 非今天
		if int(ev.get("month", 0)) == tm and int(ev.get("day", 0)) == td:
			today_events.append(ev)