# ui/self_profile_panel.gd
# 「自测量」面板（批次 1）—— 回答「性能消耗到哪里去了」。
#
# 与 ui/perf_busy_panel.gd 的分工：
#   · perf_busy_panel 看的是**系统级**总量（整机 CPU/内存/显存%），目的是判断玩家是否在忙；
#   · 本面板看的是**游戏自身**的归因：帧率、渲染/物理计数、本进程树内存、
#     以及各子系统的每帧耗时。两者互补，互不替代。
#
# ★★ 默认关闭、零开销：面板不存在时所有计时闸门都是 false，
#   调用点连一次 Time.get_ticks_usec() 都不发（见 perf_monitor.gd 顶部约定）。
#   打开面板 → PerfMonitor.begin_profiling() + Block.profile_on = true；
#   关闭 → 二者复位并清空累加数据。
#
# 打开入口：调试面板「自测量」开关（Debug._toggle_self_profile），
#           或控制台命令 /perf [on|off|snapshot]。
#
# 数据刷新：文字 4 Hz；进程树快照 1 Hz（异步线程调预编译 SysInfo.exe subtree，
#          不起 PowerShell）；子系统耗时是 PerfMonitor 的 60 帧滚动平均。
extends Control

const PANEL_W: float = 520.0
const PANEL_H: float = 720.0
const TITLE_BAR_H: float = 28.0
const LINE_INTERVAL: float = 0.25     # 面板文字刷新间隔（4 Hz）
const TREE_INTERVAL: float = 1.0      # 进程树快照间隔（1 Hz，异步、不阻塞）

# 子系统行定义：span 名 → 显示名。顺序即显示顺序。
# ★ `scene_data` 是"窗口/图标差量同步"的整体，`icon_walls` 是它内部的子项 → 显示时缩进标注。
# ★ 批次 6：`pass_apply` 拆出三个子项（blocks=积木矩形收集 / ctrl=控件树遍历 / sig=签名比对），
#   用来回答"这 1.4ms 花在哪一段"；`pass_poly` 只在区域真的变化时才产生数据。
const SPAN_ROWS: Array = [
	["pass_apply", "桌面穿透区域重算"],
	["pass_blocks", "　├ 积木矩形收集"],
	["pass_ctrl", "　├ 控件树遍历"],
	["pass_sig", "　├ 签名构造+比对"],
	["pass_poly", "　└ 多边形重建（仅变化时）"],
	["enum_parse", "枚举 JSON 解析"],
	["scene_data", "窗口/图标差量同步"],
	["icon_walls", "└ 图标边界墙重排"],
	["portal_tp", "传送检测（每物理帧）"],
	["weather_tick", "整点检查（本机天气）"],
]

signal closed

var _bg: UIPanel
var _title_label: Label
var _close_btn: UIBtn
var _status: Label

# 每个指标一行：key → 值 Label（网格两列：名称 + 数值）
var _rows: Dictionary = {}
var _grid: GridContainer

var _line_timer: float = 0.0
var _tree_timer: float = 1.0          # 首帧就取一次进程树
var _frames_since_line: int = 0
var _snapshot_dir: String = ""


func _ready() -> void:
	_build()
	_snapshot_dir = _resolve_snapshot_dir()
	# ★ 开闸：从这里到 close() 之间才产生计时开销
	PerfMonitor.begin_profiling()
	Block.profile_on = true
	Block.profile_draw_count = 0
	Block.profile_draw_usec = 0
	set_process(true)


func _exit_tree() -> void:
	_stats_off()


# 关闸（close() 与节点被释放两条路径都走这里；重复调用安全）
func _stats_off() -> void:
	PerfMonitor.end_profiling()
	Block.profile_on = false
	Block.profile_draw_count = 0
	Block.profile_draw_usec = 0


func close() -> void:
	_stats_off()
	closed.emit()


func _on_close(_id: String) -> void:
	close()



# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build() -> void:
	_bg = UIPanel.new()
	_bg.size = Vector2(PANEL_W, PANEL_H)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	add_child(_bg)
	_center_bg()
	var fnt := UIStyle.get_cjk_font()

	var sc := ScrollContainer.new()
	sc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_bg.add_child(sc)
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 4)
	sc.add_child(vbox)

	# ---- 标题栏 ----
	var title_row := HBoxContainer.new()
	title_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label = Label.new()
	_title_label.text = "自测量（性能归因）"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	_title_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		_title_label.add_theme_font_override("font", fnt)
	title_row.add_child(_title_label)
	var drag_handle := UIDragHandle.new()
	drag_handle.setup(_bg)
	drag_handle.tooltip_text = "拖动以移动面板"
	title_row.add_child(drag_handle)
	_close_btn = UIBtn.new()
	_close_btn.set_id("self_profile_close")
	_close_btn.set_label("×")
	_close_btn.custom_minimum_size = Vector2(TITLE_BAR_H, TITLE_BAR_H)
	_close_btn.size = Vector2(TITLE_BAR_H, TITLE_BAR_H)
	_close_btn.pressed_id.connect(_on_close)
	_min_btn = UIMinimize.attach(title_row, func(): set_minimized(not _minimized))
	title_row.add_child(_close_btn)
	vbox.add_child(title_row)

	# ---- 说明 ----
	var hint := Label.new()
	hint.text = "只在面板打开时计时；子系统为每帧平均，数值越低越好。"
	hint.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	hint.add_theme_font_size_override("font_size", maxi(10, UIStyle.FONT_SIZE - 2))
	if is_instance_valid(fnt):
		hint.add_theme_font_override("font", fnt)
	vbox.add_child(hint)

	# ---- 指标网格 ----
	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 2)
	vbox.add_child(_grid)

	# —— 帧 ——
	_add_section("帧")
	_add_row("fps", "FPS")
	_add_row("frame_ms", "帧时长")
	_add_row("max_fps", "Engine.max_fps")
	_add_row("vsync", "垂直同步")

	# —— 渲染 / 场景 ——
	_add_section("渲染 / 场景")
	_add_row("draw_calls", "本帧绘制调用")
	_add_row("render_objs", "本帧渲染对象")
	_add_row("nodes", "节点数")
	_add_row("orphans", "孤儿节点")

	# —— 物理 ——
	_add_section("物理")
	_add_row("phys_objs", "活动物理对象")
	_add_row("coll_pairs", "碰撞对数")

	# —— 内存 ——
	_add_section("内存")
	_add_row("static_mem", "静态内存")
	_add_row("self_mb", "本进程 RSS")
	_add_row("vram", "显存")
	_add_row("sys_mem", "整机内存")

	# —— 进程树 ——
	_add_section("进程树（本游戏）")
	_add_row("child_count", "子进程数")
	_add_row("child_mb", "子进程内存")
	_add_row("tree_mb", "进程树总计")
	_add_row("child_names", "子进程构成")

	# —— 子系统（每帧平均）——
	_add_section("子系统耗时（每帧平均）")
	for sr in SPAN_ROWS:
		_add_row("span_" + str(sr[0]), str(sr[1]))
	_add_row("block_draw", "积木 _draw")

	# ---- 底部：导出快照 ----
	vbox.add_child(HSeparator.new())
	var btn_row := HBoxContainer.new()
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var exp_btn := UIBtn.new()
	exp_btn.set_id("self_profile_export")
	exp_btn.set_label("导出快照 JSON")
	exp_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	exp_btn.custom_minimum_size = Vector2(0.0, UIStyle.BTN_HEIGHT)
	exp_btn.pressed_id.connect(_on_export)
	btn_row.add_child(exp_btn)
	vbox.add_child(btn_row)

	_status = Label.new()
	_status.text = "快照目录: %s" % _resolve_snapshot_dir()
	_status.clip_text = true
	_status.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	_status.add_theme_font_size_override("font_size", maxi(10, UIStyle.FONT_SIZE - 2))
	if is_instance_valid(fnt):
		_status.add_theme_font_override("font", fnt)
	vbox.add_child(_status)


# 面板居中打开（用户拖动后由 UIDragHandle 接管）
func _center_bg() -> void:
	if _bg == null:
		return
	var vp := Vector2(1152.0, 648.0)
	if is_inside_tree() and get_viewport() != null:
		vp = UIStyle.canvas_viewport_size(self)
	var sz := Vector2(PANEL_W, PANEL_H)
	_bg.position = ((vp - sz) * 0.5).max(Vector2.ZERO).floor()


# 网格里插一行"区块标题"（横跨两列）
func _add_section(title: String) -> void:
	var fnt := UIStyle.get_cjk_font()
	var lab := Label.new()
	lab.text = "— %s —" % title
	lab.add_theme_color_override("font_color", Color(0.75, 0.95, 1.0))
	lab.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		lab.add_theme_font_override("font", fnt)
	_grid.add_child(lab)
	var filler := Label.new()
	filler.text = ""
	_grid.add_child(filler)


# 网格里插一行指标（名称 + 数值）；数值 Label 存进 _rows 供刷新
func _add_row(key: String, name: String) -> void:
	var fnt := UIStyle.get_cjk_font()
	var n := Label.new()
	n.text = name
	n.clip_text = true
	n.custom_minimum_size = Vector2(210.0, 0)
	n.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	n.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		n.add_theme_font_override("font", fnt)
	_grid.add_child(n)
	var v := Label.new()
	v.text = "—"
	v.add_theme_color_override("font_color", Color(0.98, 0.95, 0.70))
	v.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		v.add_theme_font_override("font", fnt)
	_grid.add_child(v)
	_rows[key] = v


func _set_row(key: String, text: String) -> void:
	var l: Label = _rows.get(key, null)
	if l != null and is_instance_valid(l):
		l.text = text


# ---------------- 采样 ----------------

func _process(delta: float) -> void:
	# 帧时长并入 PerfMonitor 的滚动窗口（它负责在满 60 帧时结算成"每帧平均"）
	PerfMonitor.commit_frame(int(delta * 1e6))
	_frames_since_line += 1

	_tree_timer -= delta
	if _tree_timer <= 0.0:
		_tree_timer = TREE_INTERVAL
		PerfMonitor.request_child_tree()

	_line_timer -= delta
	if _line_timer > 0.0:
		return
	_line_timer = LINE_INTERVAL
	_refresh()
	_frames_since_line = 0


func _refresh() -> void:
	var fps := float(Engine.get_frames_per_second())
	_set_row("fps", "%.1f" % fps)

	# 帧时长：优先用 PerfMonitor 的 60 帧平均（比"最后一帧"稳），没有就用 1/FPS 估
	var avg_us := PerfMonitor.last_frame_usec()
	if avg_us > 0:
		_set_row("frame_ms", "%.2f ms" % (avg_us / 1000.0))
	elif fps > 0.0:
		_set_row("frame_ms", "%.2f ms（估）" % (1000.0 / fps))
	else:
		_set_row("frame_ms", "—")

	var mf := Engine.max_fps
	_set_row("max_fps", "不限制（0）" if mf == 0 else "%d" % mf)
	_set_row("vsync", _vsync_name(DisplayServer.window_get_vsync_mode()))

	_set_row("draw_calls", "%d" % int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	_set_row("render_objs", "%d" % int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)))
	_set_row("nodes", "%d" % int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)))
	_set_row("orphans", "%d" % int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)))

	_set_row("phys_objs", "%d" % int(Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS)))
	_set_row("coll_pairs", "%d" % int(Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS)))

	_set_row("static_mem", "%.1f MB" % (float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0))
	_set_row("vram", "%.1f MB" % PerfMonitor.vram_used_mb)
	_set_row("sys_mem", "%.0f / %.0f MB（%.0f%%）" % [
		PerfMonitor.mem_used_mb, PerfMonitor.mem_total_mb, PerfMonitor.mem_percent])

	_refresh_tree()
	_refresh_spans()


func _refresh_tree() -> void:
	if not PerfMonitor.child_tree_ok:
		var err := PerfMonitor.child_tree_err
		var msg := "读取中…" if err.is_empty() else "不可用（%s）" % err
		for k in ["self_mb", "child_count", "child_mb", "tree_mb", "child_names"]:
			_set_row(k, msg)
		return
	var t: Dictionary = PerfMonitor.child_tree
	_set_row("self_mb", "%.1f MB" % float(t.get("self_mb", 0.0)))
	_set_row("child_count", "%d" % int(t.get("child_count", 0)))
	_set_row("child_mb", "%.1f MB" % float(t.get("child_mb", 0.0)))
	_set_row("tree_mb", "%.1f MB" % float(t.get("tree_mb", 0.0)))
	var parts := PackedStringArray()
	for e in t.get("names", []):
		if e is Dictionary:
			parts.append("%s×%d/%.1fMB" % [str(e.get("name", "?")), int(e.get("count", 0)), float(e.get("mb", 0.0))])
	_set_row("child_names", "无" if parts.is_empty() else " ".join(parts))


func _refresh_spans() -> void:
	var avg: Dictionary = PerfMonitor.span_avg()
	for sr in SPAN_ROWS:
		var key := "span_" + str(sr[0])
		if avg.has(sr[0]):
			_set_row(key, "%.3f ms" % (float(avg[sr[0]]) / 1000.0))
		else:
			_set_row(key, "—（等一窗 60 帧）")
	# 积木 _draw：读走累加值并清零（口径 = 上次刷新到现在）
	var cnt := int(Block.profile_draw_count)
	var usec := int(Block.profile_draw_usec)
	Block.profile_draw_count = 0
	Block.profile_draw_usec = 0
	if cnt <= 0:
		_set_row("block_draw", "—（本窗口无重绘）")
	else:
		_set_row("block_draw", "%d 次 / %.2f ms（%.3f ms/帧）" % [
			cnt, usec / 1000.0, (usec / 1000.0) / maxf(1.0, float(_frames_since_line))])


func _vsync_name(mode: int) -> String:
	match mode:
		DisplayServer.VSYNC_DISABLED:
			return "关闭"
		DisplayServer.VSYNC_ENABLED:
			return "开启"
		DisplayServer.VSYNC_ADAPTIVE:
			return "自适应"
		DisplayServer.VSYNC_MAILBOX:
			return "Mailbox"
	return "未知(%d)" % mode


# ---------------- 快照导出 ----------------

# 快照目录 = <项目父目录>/任务缓存/perf_snapshots
# 项目在 D:\.0MyProject\HelloNyxel，任务缓存与它同级 → 用 res:// 的父目录拼。
func _resolve_snapshot_dir() -> String:
	var proj := ProjectSettings.globalize_path("res://")
	if proj.ends_with("/") or proj.ends_with("\\"):
		proj = proj.substr(0, proj.length() - 1)
	return proj.get_base_dir().path_join("任务缓存").path_join("perf_snapshots")


# 组装一份「逐项可对比」的快照（键名固定，便于改前改后 diff）
func collect_snapshot() -> Dictionary:
	var avg: Dictionary = PerfMonitor.span_avg()
	var spans: Dictionary = {}
	for k in avg:
		spans[str(k)] = snappedf(float(avg[k]) / 1000.0, 0.001)   # 统一 ms，3 位小数
	var tree: Dictionary = PerfMonitor.child_tree.duplicate(true) if PerfMonitor.child_tree_ok else {}
	return {
		"schema": 1,
		"captured_at": Time.get_datetime_string_from_system(),
		"fps": snappedf(float(Engine.get_frames_per_second()), 0.1),
		"frame_ms": snappedf(float(PerfMonitor.last_frame_usec()) / 1000.0, 0.001),
		"engine_max_fps": Engine.max_fps,
		"vsync": _vsync_name(DisplayServer.window_get_vsync_mode()),
		"render_draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"render_objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphan_nodes": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"physics_active_objects": int(Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS)),
		"physics_collision_pairs": int(Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS)),
		"memory_static_mb": snappedf(float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0, 0.1),
		"vram_used_mb": snappedf(PerfMonitor.vram_used_mb, 0.1),
		"system_mem_used_mb": snappedf(PerfMonitor.mem_used_mb, 0.1),
		"system_mem_total_mb": snappedf(PerfMonitor.mem_total_mb, 0.1),
		"system_cpu_percent": snappedf(PerfMonitor.cpu_percent, 0.1),
		"process_tree": tree,
		"subsystem_ms_per_frame": spans,
	}


# 导出快照；返回落盘路径（失败返回空串）
func export_snapshot() -> String:
	var dir := _snapshot_dir if not _snapshot_dir.is_empty() else _resolve_snapshot_dir()
	if DirAccess.make_dir_recursive_absolute(dir) != OK and not DirAccess.dir_exists_absolute(dir):
		if _status != null and is_instance_valid(_status):
			_status.text = "✗ 无法创建目录: %s" % dir
		return ""
	var name := "snapshot_%s.json" % Time.get_datetime_string_from_system().replace(":", "-")
	var path := dir.path_join(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		if _status != null and is_instance_valid(_status):
			_status.text = "✗ 写入失败: %s" % path
		return ""
	f.store_string(JSON.stringify(collect_snapshot(), "  "))
	f.close()
	if _status != null and is_instance_valid(_status):
		_status.text = "✓ 已导出 %s" % path
	return path


func _on_export(_id: String) -> void:
	export_snapshot()


# 公开 API（探针 / 控制台 / 事件链可用）
func snapshot_dir() -> String:
	return _snapshot_dir if not _snapshot_dir.is_empty() else _resolve_snapshot_dir()


## 最小化 / 还原：折叠只隐藏内容，顶栏（标题 + 拖动把柄 + 最小化 + 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.apply(self, _min_btn, v, _min_btn.get_parent() if is_instance_valid(_min_btn) else null)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized
