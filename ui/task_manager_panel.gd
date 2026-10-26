# ui/task_manager_panel.gd
# 「电脑任务管理器」页面（配合忙闲判断的进程选取）。
#
# 用途：系统自带任务管理器无法直接把进程名填回游戏，手动输入又不方便 →
#   在「性能忙闲判断」面板的进程名输入框旁给一个按钮，打开本页；
#   本页罗列电脑此时正在运行的进程，每进程一个「选择」按钮，
#   点了就把进程名写回那个输入框（与 TagPickerPanel 同样的「子面板回写」模式）。
#
# 数据来源：PowerShell `Get-Process`（与 PerfMonitor 同一条已验证通路），
#   在新线程里执行、结果 call_deferred 回主线程，避免卡顿。
#   按进程名去重（忙闲判断按名字匹配，同名多实例合并为一行），显示实例数与内存合计。
#
# 设计约束（与 version_announcement_panel / tag_picker_panel 一致）：
#   class_name TaskManagerPanel extends Control；signal closed；
#   open()/close()/is_open() 三件套；close() 内 closed.emit()；
#   由调用方建 CanvasLayer 承载（层号需高于调用方面板）。
class_name TaskManagerPanel extends Control

signal closed

const PANEL_W: float = 560.0
const PANEL_H: float = 520.0
const TITLE_H: float = 28.0
const ROW_H: float = 26.0

# PowerShell：输出「Id<Tab>进程名<Tab>内存MB<Tab>CPU%」每行一个进程。
# ★ CPU% 用**两次采样求差**得到（任务管理器那种「当前占用」）：
#     取 TotalProcessorTime → Start-Sleep 400ms → 再取一次，(差/实耗/核心数)×100。
#     （Get-Process 的 .CPU 只是「累计 CPU 秒」，不能直接当占用率用。）
# ★★ 硬约束（实测踩出，改这条命令时必须满足）：
#   ① **绝对不能出现双引号** —— Godot 的 OS.execute 在 Windows 上会破坏 argv 里的 `"`，
#      PowerShell 收到残缺命令 → 解析失败、退出码 1（实测：带双引号 rc=1，去掉 rc=0）。
#      （PerfMonitor 的 _PS_SCRIPT 也全程用单引号，同一原因。）
#   ② Tab 用 [char]9 直接产出，不要先 `$t=[char]9` 再 "$t$($_.Name)" ——
#      PowerShell 无法词法解析「变量紧贴 $(」，同样报「意外的标记」。
# ★ GDScript 单引号字符串内 $ 不做插值 → PowerShell 侧照常展开。
const _PS_ENUM: String = '$n=[System.Environment]::ProcessorCount;$sw=[System.Diagnostics.Stopwatch]::StartNew();$a=Get-Process -ErrorAction SilentlyContinue|Select-Object Id,ProcessName,WorkingSet64,TotalProcessorTime;Start-Sleep -Milliseconds 400;$b=Get-Process -ErrorAction SilentlyContinue|Select-Object Id,ProcessName,WorkingSet64,TotalProcessorTime;$sw.Stop();$e=$sw.Elapsed.TotalSeconds;if($e -le 0){$e=0.4};$h=@{};foreach($y in $b){$h[[int]$y.Id]=$y};foreach($x in $a){$y=$h[[int]$x.Id];if($y -ne $null){$d=($y.TotalProcessorTime.TotalSeconds-$x.TotalProcessorTime.TotalSeconds);$c=[math]::Round($d/$e/$n*100,1);$x.Id.ToString()+[char]9+$x.ProcessName+[char]9+[math]::Round($x.WorkingSet64/1MB,1)+[char]9+$c}}'

# ★ 已知 Windows 系统进程名（小写、去 .exe）。勾选「隐藏系统进程」开关后，这些从列表剔除，
#   减少干扰、方便选择真正的用户进程。
#   说明：explorer（文件资源管理器外壳）、taskmgr（任务管理器工具）故意**不**列入，
#   因为它们是用户可能想选择的目标；其余均为后台 OS 服务/驱动，属典型「噪声」。
const SYSTEM_PROC_NAMES := {
	"system": true, "system idle process": true, "system interrupts": true,
	"smss": true, "csrss": true, "wininit": true, "winlogon": true,
	"services": true, "lsass": true, "lsaiso": true,
	"svchost": true, "fontdrvhost": true, "dwm": true, "audiodg": true,
	"conhost": true, "dllhost": true, "spoolsv": true, "taskhostw": true,
	"searchindexer": true, "msmpeng": true, "nissrv": true, "wudfhost": true,
	"sihost": true, "runtimebroker": true,
}

var _bg: UIPanel = null
var _title_label: Label = null
var _close_btn: UIBtn = null
var _filter_edit: LineEdit = null
var _refresh_btn: UIBtn = null
var _status_label: Label = null
var _scroll: ScrollContainer = null
var _list: VBoxContainer = null
var _btn_sort_name: UIBtn = null
var _btn_sort_cpu: UIBtn = null
var _btn_sort_mem: UIBtn = null
var _sys_toggle: CheckBox = null

# ★ 排序：字段名 + 正/逆序。按钮在页面顶部，点当前项切正逆序、点别的项换字段。
var _sort_field: String = "name"       # name / cpu / mem
var _sort_asc: bool = true
var _hide_system: bool = false         # ★ 是否隐藏系统进程（顶部开关控制；默认 false=显示全部，兼容既有行为）

var _source_edit: LineEdit = null      # 要回填的进程名输入框（由 open() 传入）
var _all_rows: Array = []              # [{name, count, mem_mb, cpu_pct}]

var _open: bool = false
var _cjk: FontFile = null
var _enum_thread: Thread = null
var _enum_busy: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_cjk = UIStyle.get_cjk_font()
	_build_ui()
	visible = false


func _build_ui() -> void:
	var vs: Vector2 = UIStyle.canvas_viewport_size(self) if get_viewport() != null else Vector2(1280.0, 720.0)
	size = Vector2(PANEL_W, PANEL_H)
	position = Vector2(maxf(40.0, (vs.x - PANEL_W) * 0.5), maxf(40.0, (vs.y - PANEL_H) * 0.35))

	_bg = UIPanel.new()
	_bg.bind_page_dark_bg()
	_bg.name = "Bg"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.STAGE_BORDER)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	var drag := UIDragHandle.new()
	drag.name = "DragHandle"
	drag.setup(self)
	drag.anchor_left = 1.0
	drag.anchor_top = 0.0
	drag.anchor_right = 1.0
	drag.anchor_bottom = 0.0
	drag.offset_left = -(TITLE_H * 2.0 + UIStyle.PANEL_PADDING + 4.0)
	drag.offset_top = UIStyle.PANEL_PADDING
	drag.offset_right = -(TITLE_H + UIStyle.PANEL_PADDING + 4.0)
	drag.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING
	add_child(drag)

	_close_btn = UIBtn.new()
	_close_btn.name = "CloseBtn"
	_close_btn.set_id("close")
	_close_btn.set_label("×")
	_close_btn.anchor_left = 1.0
	_close_btn.anchor_top = 0.0
	_close_btn.anchor_right = 1.0
	_close_btn.anchor_bottom = 0.0
	_close_btn.offset_left = -(TITLE_H + UIStyle.PANEL_PADDING)
	_close_btn.offset_top = UIStyle.PANEL_PADDING
	_close_btn.offset_right = -UIStyle.PANEL_PADDING
	_close_btn.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING
	_close_btn.pressed_id.connect(_on_close_pressed)
	add_child(_close_btn)

	_title_label = Label.new()
	_title_label.name = "TitleLabel"
	_title_label.text = "电脑任务管理器"
	_title_label.position = Vector2(UIStyle.PANEL_PADDING + 2.0, UIStyle.PANEL_PADDING)
	_title_label.custom_minimum_size = Vector2(0.0, TITLE_H)
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", Color(0.8, 0.94, 1.0))
	_title_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 1)
	if is_instance_valid(_cjk):
		_title_label.add_theme_font_override("font", _cjk)
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_title_label)

	var top_y := TITLE_H + UIStyle.PANEL_PADDING

	# ★ 排序行（页面顶部）：「排序」提示 + 名称 / CPU / 内存 三个按钮
	var sort_bar := HBoxContainer.new()
	sort_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	sort_bar.offset_left = UIStyle.PANEL_PADDING
	sort_bar.offset_top = top_y
	sort_bar.offset_right = -UIStyle.PANEL_PADDING
	sort_bar.offset_bottom = top_y + 26.0
	sort_bar.add_theme_constant_override("separation", 4)
	add_child(sort_bar)

	var sort_hint := Label.new()
	sort_hint.text = "排序："
	sort_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sort_hint.add_theme_color_override("font_color", Color(0.78, 0.86, 0.95, 0.85))
	sort_hint.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		sort_hint.add_theme_font_override("font", _cjk)
	sort_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sort_bar.add_child(sort_hint)

	_btn_sort_name = _make_sort_btn("名称", "name", sort_bar)
	_btn_sort_cpu = _make_sort_btn("CPU", "cpu", sort_bar)
	_btn_sort_mem = _make_sort_btn("内存", "mem", sort_bar)
	_refresh_sort_labels()

	# ★ 系统进程开关（顶部第二行）：勾选后列表隐藏系统进程，方便选择用户进程
	var toggle_bar := HBoxContainer.new()
	toggle_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	toggle_bar.offset_left = UIStyle.PANEL_PADDING
	toggle_bar.offset_top = top_y + 30.0
	toggle_bar.offset_right = -UIStyle.PANEL_PADDING
	toggle_bar.offset_bottom = top_y + 56.0
	toggle_bar.add_theme_constant_override("separation", 6)
	add_child(toggle_bar)

	_sys_toggle = CheckBox.new()
	_sys_toggle.name = "HideSystemToggle"
	_sys_toggle.text = "隐藏系统进程"
	_sys_toggle.button_pressed = _hide_system
	_sys_toggle.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	_sys_toggle.add_theme_color_override("font_color", Color(0.82, 0.9, 0.98, 0.95))
	if is_instance_valid(_cjk):
		_sys_toggle.add_theme_font_override("font", _cjk)
	_sys_toggle.toggled.connect(_on_hide_system_toggled)
	toggle_bar.add_child(_sys_toggle)

	# 筛选框 + 刷新按钮
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_left = UIStyle.PANEL_PADDING
	bar.offset_top = top_y + 60.0
	bar.offset_right = -UIStyle.PANEL_PADDING
	bar.offset_bottom = top_y + 86.0
	bar.add_theme_constant_override("separation", 4)
	add_child(bar)

	_filter_edit = LineEdit.new()
	_filter_edit.placeholder_text = "筛选进程名…"
	_filter_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_filter_edit.custom_maximum_size = Vector2(10000.0, 10000.0)
	_filter_edit.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_cjk):
		_filter_edit.add_theme_font_override("font", _cjk)
	UIStyle.apply_line_edit_style(_filter_edit)
	_filter_edit.text_changed.connect(_on_filter_changed)
	bar.add_child(_filter_edit)

	_refresh_btn = UIBtn.new()
	_refresh_btn.set_id("refresh")
	_refresh_btn.set_label("刷新")
	_refresh_btn.custom_minimum_size = Vector2(64.0, 26.0)
	_refresh_btn.pressed_id.connect(_on_refresh_pressed)
	bar.add_child(_refresh_btn)

	# 状态行
	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.text = "正在读取进程列表…"
	_status_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_status_label.offset_left = UIStyle.PANEL_PADDING
	_status_label.offset_top = top_y + 88.0
	_status_label.offset_right = -UIStyle.PANEL_PADDING
	_status_label.offset_bottom = top_y + 106.0
	_status_label.add_theme_color_override("font_color", Color(0.78, 0.86, 0.95, 0.85))
	_status_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		_status_label.add_theme_font_override("font", _cjk)
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_status_label)

	# 进程列表（滚动）
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.offset_left = UIStyle.PANEL_PADDING
	_scroll.offset_top = top_y + 110.0
	_scroll.offset_right = -UIStyle.PANEL_PADDING
	_scroll.offset_bottom = -UIStyle.PANEL_PADDING
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)

	_list = VBoxContainer.new()
	_list.name = "List"
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 2)
	_scroll.add_child(_list)


# ============ 打开 / 关闭 ============

# source：要回填进程名的输入框（通常是忙闲面板某一行的「进程名」LineEdit）。
func open(source: LineEdit) -> void:
	_source_edit = source
	_open = true
	visible = true
	move_to_front()
	_start_enum()


func close() -> void:
	_open = false
	visible = false
	if get_viewport() != null:
		get_viewport().gui_release_focus()
	closed.emit()


func is_open() -> bool:
	return _open


func _on_close_pressed(_id: String) -> void:
	close()


# ============ 进程枚举（新线程 + 回主线程） ============

func _start_enum() -> void:
	if _enum_busy:
		return
	_enum_busy = true
	_status_label.text = "正在读取进程列表…"
	if _filter_edit != null and is_instance_valid(_filter_edit):
		_filter_edit.editable = false
	_enum_thread = Thread.new()
	_enum_thread.start(_enum_worker)


# ★ 后台线程：绝不 print（见项目约定）
func _enum_worker() -> void:
	var rows: Array = []
	var err := ""
	if OS.get_name() != "Windows":
		err = "仅 Windows 支持读取进程列表"
	else:
		var out: Array = []
		var rc: int = OS.execute("powershell.exe",
			["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", _PS_ENUM], out, false)
		if rc != 0 or out.is_empty():
			err = "读取失败（PowerShell 退出码 %d）" % rc
		else:
			rows = _parse_ps_output(str(out[0]))
			if rows.is_empty():
				err = "未读到任何进程（输出为空）"
	call_deferred("_on_enum_done", {"rows": rows, "err": err})


# 解析 PowerShell 输出：每行 Id<Tab>进程名<Tab>内存MB<Tab>CPU%；按进程名去重合并。
# ★ 第 4 列 CPU% 可选（老格式只有 3 列时按 0 处理），保证解析向后兼容。
# ★ 静态：headless 可单测，无需实例化面板。
static func _parse_ps_output(raw: String) -> Array:
	var tab := String.chr(9)
	var merged: Dictionary = {}   # 小写名 -> {name, count, mem_mb, cpu_pct}
	var lines := raw.split(String.chr(10))
	for ln in lines:
		var line := str(ln).replace(String.chr(13), "").strip_edges()
		if line.is_empty():
			continue
		var parts := line.split(tab)
		if parts.size() < 3:
			continue
		var pname := str(parts[1]).strip_edges()
		if pname.is_empty():
			continue
		var mem_mb := float(str(parts[2]).strip_edges())
		var cpu_pct := 0.0
		if parts.size() >= 4:
			cpu_pct = float(str(parts[3]).strip_edges())
		var key := pname.to_lower()
		if merged.has(key):
			var rec: Dictionary = merged[key]
			rec["count"] = int(rec.get("count", 0)) + 1
			rec["mem_mb"] = float(rec.get("mem_mb", 0.0)) + mem_mb
			rec["cpu_pct"] = float(rec.get("cpu_pct", 0.0)) + cpu_pct
		else:
			merged[key] = {"name": pname, "count": 1, "mem_mb": mem_mb, "cpu_pct": cpu_pct}
	var rows: Array = []
	for k in merged.keys():
		rows.append(merged[k])
	rows.sort_custom(Callable(TaskManagerPanel, "_cmp_by_name"))
	return rows


static func _cmp_by_name(a, b) -> bool:
	return str(a.get("name", "")).to_lower() < str(b.get("name", "")).to_lower()


# ★ 判定某进程名是否为已知 Windows 系统进程（去 .exe、小写）。静态便于单测。
static func _is_system_proc(pname: String) -> bool:
	var n := str(pname).to_lower()
	if n.ends_with(".exe"):
		n = n.left(n.length() - 4)
	return SYSTEM_PROC_NAMES.has(n)


# ============ 排序 ============

# 当前比较器（给 sort_custom 用）：按 _sort_field / _sort_asc。
func _cmp_cur(a, b) -> bool:
	var an := str(a.get("name", "")).to_lower()
	var bn := str(b.get("name", "")).to_lower()
	if _sort_field == "name":
		if an == bn:
			return false
		return (an < bn) if _sort_asc else (an > bn)
	var av := float(a.get(_sort_field_key(), 0.0))
	var bv := float(b.get(_sort_field_key(), 0.0))
	if absf(av - bv) < 0.0001:
		return an < bn      # 数值相同用名字兜底，保证顺序稳定
	return (av < bv) if _sort_asc else (av > bv)


func _sort_field_key() -> String:
	return "cpu_pct" if _sort_field == "cpu" else "mem_mb"


func _apply_sort() -> void:
	_all_rows.sort_custom(Callable(self, "_cmp_cur"))


func _make_sort_btn(text: String, field: String, parent: Node) -> UIBtn:
	var b := UIBtn.new()
	b.set_id("sort_" + field)
	b.set_label(text)
	b.custom_minimum_size = Vector2(72.0, 24.0)
	if is_instance_valid(_cjk):
		b.add_theme_font_override("font", _cjk)
	b.pressed_id.connect(_on_sort_pressed.bind(field))
	parent.add_child(b)
	return b


# 点当前排序字段 → 切正逆序；点别的字段 → 换字段（名称默认正序，CPU/内存默认逆序=大的在前）
func _on_sort_pressed(_id: String, field: String) -> void:
	if _sort_field == field:
		_sort_asc = not _sort_asc
	else:
		_sort_field = field
		_sort_asc = (field == "name")
	_refresh_sort_labels()
	_apply_sort()
	_populate()


func _refresh_sort_labels() -> void:
	var arrow := "▲" if _sort_asc else "▼"
	if _btn_sort_name != null and is_instance_valid(_btn_sort_name):
		_btn_sort_name.set_label("名称" + (arrow if _sort_field == "name" else ""))
	if _btn_sort_cpu != null and is_instance_valid(_btn_sort_cpu):
		_btn_sort_cpu.set_label("CPU" + (arrow if _sort_field == "cpu" else ""))
	if _btn_sort_mem != null and is_instance_valid(_btn_sort_mem):
		_btn_sort_mem.set_label("内存" + (arrow if _sort_field == "mem" else ""))


func _on_enum_done(result: Variant) -> void:
	if _enum_thread != null and is_instance_valid(_enum_thread):
		_enum_thread.wait_to_finish()
		_enum_thread = null
	_enum_busy = false
	if _filter_edit != null and is_instance_valid(_filter_edit):
		_filter_edit.editable = true
	if not (result is Dictionary):
		return
	var res: Dictionary = result
	var err := str(res.get("err", ""))
	_all_rows = res.get("rows", [])
	if not err.is_empty():
		_status_label.text = err
	else:
		_status_label.text = "共 %d 个进程（同名已合并）" % _all_rows.size()
	_apply_sort()      # ★ 枚举完立刻按当前排序规则排一次（不重新枚举）
	_populate()


# ============ 列表渲染 ============

func _populate() -> void:
	if _list == null or not is_instance_valid(_list):
		return
	# ★ 重建容器：先 remove_child 再 queue_free
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()

	var kw := ""
	if _filter_edit != null and is_instance_valid(_filter_edit):
		kw = _filter_edit.text.strip_edges().to_lower()

	var shown := 0
	var hidden_sys := 0      # 被「隐藏系统进程」开关过滤掉的数量
	for r in _all_rows:
		if not (r is Dictionary):
			continue
		var nm := str(r.get("name", ""))
		if _hide_system and _is_system_proc(nm):
			hidden_sys += 1
			continue
		if not kw.is_empty() and not nm.to_lower().contains(kw):
			continue
		_list.add_child(_build_row(r))
		shown += 1

	if not _status_label.text.begins_with("读取失败") and not _status_label.text.begins_with("仅 Windows"):
		if kw.is_empty():
			if _hide_system and hidden_sys > 0:
				_status_label.text = "显示 %d 个 / 共 %d 个（已隐藏系统进程）" % [shown, _all_rows.size()]
			else:
				_status_label.text = "共 %d 个进程（同名已合并）" % _all_rows.size()
		else:
			_status_label.text = "匹配 %d / %d 个进程" % [shown, _all_rows.size()]


func _build_row(r: Dictionary) -> HBoxContainer:
	var nm := str(r.get("name", ""))
	var cnt := int(r.get("count", 1))
	var mem := float(r.get("mem_mb", 0.0))
	var cpu := float(r.get("cpu_pct", 0.0))

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.custom_minimum_size = Vector2(0.0, ROW_H)
	row.add_theme_constant_override("separation", 6)

	var name_lbl := Label.new()
	name_lbl.text = nm
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.clip_text = true
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	name_lbl.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(_cjk):
		name_lbl.add_theme_font_override("font", _cjk)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_lbl)

	var info := "×%d   %.1f%%   %.0f MB" % [cnt, cpu, mem]
	var info_lbl := Label.new()
	info_lbl.text = info
	info_lbl.custom_minimum_size = Vector2(140.0, 0.0)
	info_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	info_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	info_lbl.add_theme_color_override("font_color", Color(0.78, 0.86, 0.95, 0.85))
	info_lbl.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
	if is_instance_valid(_cjk):
		info_lbl.add_theme_font_override("font", _cjk)
	info_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(info_lbl)

	var pick := UIBtn.new()
	pick.set_id("pick")
	pick.set_label("选择")
	pick.custom_minimum_size = Vector2(56.0, 24.0)
	pick.pressed_id.connect(_on_select_pressed.bind(nm))
	row.add_child(pick)

	return row


# ============ 选择 / 回写 ============

func _on_select_pressed(_id: String, pname: String) -> void:
	if _source_edit != null and is_instance_valid(_source_edit) and _source_edit is LineEdit:
		_source_edit.text = pname
	close()


func _on_filter_changed(_text: String) -> void:
	_populate()


# ★ 顶部「隐藏系统进程」开关：切换即按当前数据重排列表。
func _on_hide_system_toggled(on: bool) -> void:
	_hide_system = on
	_populate()


func _on_refresh_pressed(_id: String) -> void:
	_start_enum()
