# ui/effect_editor_panel.gd
# 「效果」可视化编辑器：按命令自动给出**合乎逻辑的参数**，拼出统一 DSL 命令，
# 自动翻译为命令串写回来源 LineEdit（事件链按钮 effect / 正文 effect）。
#
# ★★ 批次 69：字段按命令分化（本文件的核心）。
#   旧版所有命令共用一套「目标(状态文件) + 变量 + 附加」，于是 create_block（新建积木）上也会
#   冒出「世界状态」这种文件下拉 —— 逻辑不通。现在每条命令各自声明需要的字段：
#     create_block → 积木类型 / 字符串 ID / 位置 / 其他参数
#     remove_block → 字符串 ID / 删除条件 / 其他判定
#     set_var      → 目标引用 / 变量名 / 操作(覆盖,累加…) / 值类型 / 值
#     add_var      → 目标引用 / 变量名 / 值类型 / 值
#     remove_var   → 目标引用 / 变量名 / 模式(移除键|移除元素) / 值
#     load_level   → 关卡名（下拉，来自 LevelManager）
#     perf         → 参数（切换|打开|关闭|导出快照）
#     help         → 命令名（下拉）
#     clear        → 无参数
#   ★ 批次 94：add_timeline（添加到时间轴）→ 预计时间（相对 "10m" / 绝对 "2026.10.11.20:00"）
#     + 时间轴效果（要执行的命令）+ 触发事件（链/事件名）+ 其他属性（tag/ignore/delay/max_skip）。
#     效果与触发事件可同时给 → 时间轴写同刻两条（靠写入顺序保「先效果后事件」）。
#   ★★ 批次 96：add_tag / remove_tag / clear_tags（状态标签）——
#     条件编辑器能写 `has_tag("剧情状态","得到钥匙")`，可效果这边当年只有「变量」，
#     而 /set_var 的右侧**不支持数组字面量** → 「加个标签」根本表达不出来。
#     现在给出**明确的标签入口**：状态（已注册状态下拉）+ 标签字段（该状态现有数组字段下拉）
#     + 标签（文本）。字段下拉来自 StateRegistry.tag_fields_of，与 has_tag 的判定范围一致。
#
# ★ 变量命令的「目标引用」= DSL 里 ref 的第一段：状态文件（友好名→文件）、积木 ID/字符串 ID、
#   或全局变量名 —— 下拉给出注册过的状态文件，选「(自定义引用…)」可自由填写。
#   变量名下拉据目标文件列出「注册变量 + 文件实际键」，也可手填；嵌套路径（a:b:c）原样保留。
#
# ★★ 未知参数不丢：create_block / remove_block 里编辑器没显式覆盖的 bag 键
#   （width / height / tags …）会原样落到「其他参数 / 其他判定」文本框并可编辑 ——
#   保证「源串 → 行 → DSL」往返不静默丢数据。
#
# ★★ 显示文本 ≠ 真值（批次 67 根因）：所有下拉的「真值」一律存 item metadata，
#   显示文本随语言变；任何地方都不得拿 get_item_text() 当判据。
class_name EffectEditorPanel
extends Control

const ConsoleCommandScript := preload("res://autoload/console_command.gd")

const PANEL_W: float = 760.0
const PANEL_H: float = 560.0
const TITLE_BAR_H: float = 28.0

# 下拉「哨兵」真值（都不是合法命令参数，故可安全当判据）
const CUSTOM_REF_LABEL: String = "(自定义引用…)"
const VAR_SENTINEL: String = "(选择变量)"
const LEVEL_SENTINEL: String = "(选择关卡)"
const BLANK_TYPE_LABEL: String = "(空白积木)"
const TAG_STATE_SENTINEL: String = "(选择状态)"
const TAG_FIELD_SENTINEL: String = "(选择标签字段)"

# 每条命令要显示哪些字段（顺序即界面顺序）。字段 → 控件在 _add_row() 里统一建好，靠 visible 控制。
const FIELDS: Dictionary = {
	"create_block": ["block_type", "string_id", "position", "extras"],
	"remove_block": ["string_id", "cond", "extras"],
	"set_var": ["ref", "var", "set_op", "vtype", "value"],
	"add_var": ["ref", "var", "vtype", "value"],
	"remove_var": ["ref", "var", "rm_mode", "value"],
	"load_level": ["level"],
	"perf": ["perf_arg"],
	"help": ["help_cmd"],
	"play_event": ["chain", "event"],
	"add_timeline": ["tl_time", "tl_effect", "tl_event", "tl_props"],
	"add_tag": ["tag_state", "tag_field", "tag_value"],
	"remove_tag": ["tag_state", "tag_field", "tag_value"],
	"clear_tags": ["tag_state", "tag_field"],
	"clear": [],
}

# 操作 / 模式 / 类型 下拉的选项：[真值, 显示名(翻译表 key)]
const SET_OPS: Array = [
	["=", "覆盖（=）"],
	["+=", "累加（+=）"],
	["-=", "累减（-=）"],
	["*=", "累乘（*=）"],
	["/=", "累除（/=）"],
]
const RM_MODES: Array = [
	["remove_key", "移除该键 / 清空"],
	["remove_elem", "移除集合中的指定元素"],
]
const VTYPES: Array = [
	["auto", "自动（按内容判断）"],
	["string", "文本"],
	["int", "整数"],
	["float", "小数"],
	["bool", "布尔"],
	["null", "空（null）"],
]
const PERF_ARGS: Array = [
	["", "(切换)"],
	["on", "打开"],
	["off", "关闭"],
	["snapshot", "导出快照"],
]

signal closed

var _bg: UIPanel
var _rows_box: VBoxContainer
var _source_le: LineEdit = null
var _rows: Array = []   # 每行控件引用集合
var _drag: UIDragHandle = null   # 标题栏拖动把手（tooltip 需手动跟语言）


func open(title: String, source_le: LineEdit) -> void:
	_source_le = source_le
	_build(title)
	_parse_source()


# ================= 构建 =================


# 「最小化」按钮由 UIMinimize 统一创建；折叠后顶栏整排保留
var _min_btn: UIBtn = null
var _minimized: bool = false

func _build(title: String) -> void:
	_bg = UIPanel.new()
	_bg.position = Vector2(440.0, 60.0)
	_bg.size = Vector2(PANEL_W, PANEL_H)
	_bg.set_corner_radius(UIStyle.CORNER_RADIUS)
	_bg.set_border_width(UIStyle.BORDER_WIDTH)
	_bg.set_fill_color(UIStyle.FILL_DEFAULT)
	_bg.set_border_color(UIStyle.BORDER)
	add_child(_bg)
	var fnt := UIStyle.get_cjk_font()

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 4)
	_bg.add_child(root)

	# 标题栏
	var title_row := HBoxContainer.new()
	title_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title_label := Label.new()
	title_label.text = title
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	title_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		title_label.add_theme_font_override("font", fnt)
	title_row.add_child(title_label)
	var drag := UIDragHandle.new()
	_drag = drag
	drag.setup(_bg)
	title_row.add_child(drag)
	var close_btn := UIBtn.new()
	close_btn.set_id("effect_close")
	close_btn.set_label("×")
	close_btn.custom_minimum_size = Vector2(TITLE_BAR_H, TITLE_BAR_H)
	close_btn.size = Vector2(TITLE_BAR_H, TITLE_BAR_H)
	close_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	close_btn.pressed_id.connect(func(_id: String) -> void: close())
	_min_btn = UIMinimize.attach(title_row, func(): set_minimized(not _minimized))
	title_row.add_child(close_btn)
	root.add_child(title_row)

	# 行容器（可滚动）
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_rows_box)
	root.add_child(scroll)

	# 底部：加号 + 完成
	var btn_row := HBoxContainer.new()
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var add_btn := UIBtn.new()
	add_btn.set_id("effect_add")
	add_btn.set_label("＋ 添加命令")
	add_btn.custom_minimum_size = Vector2(160.0, UIStyle.BTN_HEIGHT)
	add_btn.pressed_id.connect(func(_id: String) -> void: _add_row({}))
	btn_row.add_child(add_btn)
	var done_btn := UIBtn.new()
	done_btn.set_id("effect_done")
	done_btn.set_label("完成")
	done_btn.custom_minimum_size = Vector2(100.0, UIStyle.BTN_HEIGHT)
	done_btn.pressed_id.connect(func(_id: String) -> void: close())
	btn_row.add_child(done_btn)
	root.add_child(btn_row)

	# ★ 面板文案（标题/按钮/占位符/字段标签）与命令显示名一样走翻译表：
	#   先订阅语言切换，再把已建好的这部分换成当前语言。每行在 _add_row() 末尾各自重译。
	if not TranslationManager.language_changed.is_connected(_on_language_changed):
		TranslationManager.language_changed.connect(_on_language_changed)
	TranslationManager.retranslate_tree(self)
	_refresh_tooltips()


# ★ tooltip_text 不在 retranslate_tree 的处理范围（只认 Label/Button/OptionButton/LineEdit 占位符）
#   → 这里手动跟一次语言。
func _refresh_tooltips() -> void:
	if is_instance_valid(_drag):
		_drag.tooltip_text = TranslationManager.t("拖动以移动效果编辑器")


func _on_language_changed(_lang: String) -> void:
	if is_instance_valid(self):
		TranslationManager.retranslate_tree(self)
		_refresh_tooltips()


# ================= 一行 = 一条命令 =================

func _add_row(parsed: Dictionary) -> void:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var fnt := UIStyle.get_cjk_font()
	var widgets: Dictionary = {}

	# ---- 标题行：命令下拉（占满）+ 删除 ----
	var r1 := HBoxContainer.new()
	r1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r1.add_theme_constant_override("separation", 4)

	var cmd_ob := _mk_option(fnt)
	# ★ 显示名走翻译（要翻译的是「显示文本」），真值（命令名）存进 item metadata。
	for name in ConsoleCommandScript.command_names():
		cmd_ob.add_item(TranslationManager.t(ConsoleCommandScript.command_label(name)))
		cmd_ob.set_item_metadata(cmd_ob.item_count - 1, name)
	_select_cmd(cmd_ob, str(parsed.get("cmd", "add_var")))
	r1.add_child(cmd_ob)

	var del := UIBtn.new()
	del.set_id("row_del")
	del.set_label("−")
	del.custom_minimum_size = Vector2(TITLE_BAR_H, UIStyle.BTN_HEIGHT)
	del.size = Vector2(TITLE_BAR_H, UIStyle.BTN_HEIGHT)
	del.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r1.add_child(del)
	vbox.add_child(r1)

	# ---- 参数网格（2 列：标签 + 控件）。容器会跳过隐藏子节点 → 用 visible 控制显隐 ----
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 4)
	vbox.add_child(grid)

	# 1) 积木类型（create_block）
	var block_type_ob := _mk_option(fnt)
	block_type_ob.add_item(TranslationManager.t(BLANK_TYPE_LABEL))
	block_type_ob.set_item_metadata(0, "")
	if BlockTypes != null and BlockTypes.has_method("list_names"):
		for n in BlockTypes.list_names():
			block_type_ob.add_item(str(n))
			block_type_ob.set_item_metadata(block_type_ob.item_count - 1, str(n))
	# ★ 源里的类型名不在下拉里时（Blank 属隐藏类型 / 已被删 / MOD 型未登记）→ 临时补一项，
	#   否则「源串 → 行 → DSL」会把这个类型静默丢掉（真机往返丢参数）。
	var want_type: String = str(parsed.get("block_type", ""))
	if want_type != "" and not _has_meta(block_type_ob, want_type):
		block_type_ob.add_item(want_type)
		block_type_ob.set_item_metadata(block_type_ob.item_count - 1, want_type)
	_select_by_meta(block_type_ob, want_type)
	widgets["block_type"] = _add_field(grid, fnt, "积木类型", block_type_ob)

	# 2) 字符串 ID
	var string_id_le := _mk_line(fnt, "留空 = 自动生成")
	string_id_le.text = str(parsed.get("string_id", ""))
	widgets["string_id"] = _add_field(grid, fnt, "字符串 ID", string_id_le)

	# 3) 位置
	var position_le := _mk_line(fnt, "留空 = 桌面中心；也可写 100,200")
	position_le.text = str(parsed.get("position", ""))
	widgets["position"] = _add_field(grid, fnt, "位置", position_le)

	# 4) 目标引用（下拉 + 自定义）
	var ref_ob := _mk_option(fnt)
	for fr in StateRegistry.registered_friendly():
		ref_ob.add_item(TranslationManager.t(fr))
		ref_ob.set_item_metadata(ref_ob.item_count - 1, fr)
	ref_ob.add_item(TranslationManager.t(CUSTOM_REF_LABEL))
	ref_ob.set_item_metadata(ref_ob.item_count - 1, CUSTOM_REF_LABEL)
	var ref_custom := _mk_line(fnt, "自定义引用（文件名 / 积木 ID / 全局变量）")
	widgets["ref"] = _add_field(grid, fnt, "目标引用", _compound([ref_ob, ref_custom]))

	# 5) 变量名（下拉 + 手填）
	var var_ob := _mk_option(fnt)
	var var_custom := _mk_line(fnt, "或手动输入变量名")
	widgets["var"] = _add_field(grid, fnt, "变量名", _compound([var_ob, var_custom]))

	# 6) 操作（set_var）
	var set_op_ob := _mk_option(fnt)
	_fill_pairs(set_op_ob, SET_OPS)
	widgets["set_op"] = _add_field(grid, fnt, "操作", set_op_ob)

	# 7) 模式（remove_var）
	var rm_mode_ob := _mk_option(fnt)
	_fill_pairs(rm_mode_ob, RM_MODES)
	widgets["rm_mode"] = _add_field(grid, fnt, "模式", rm_mode_ob)

	# 8) 值类型
	var vtype_ob := _mk_option(fnt)
	_fill_pairs(vtype_ob, VTYPES)
	widgets["vtype"] = _add_field(grid, fnt, "值类型", vtype_ob)

	# 9) 值
	var value_le := _mk_line(fnt, "值（文本 / 数字 / true/false）")
	value_le.text = str(parsed.get("value", ""))
	widgets["value"] = _add_field(grid, fnt, "值", value_le)

	# 10) 删除条件（remove_block）
	var cond_le := _mk_line(fnt, "条件表达式（如 this:width > 100）")
	cond_le.text = str(parsed.get("cond", ""))
	widgets["cond"] = _add_field(grid, fnt, "删除条件", cond_le)

	# 11) 关卡（下拉 + 手填）
	var level_ob := _mk_option(fnt)
	level_ob.add_item(TranslationManager.t(LEVEL_SENTINEL))
	level_ob.set_item_metadata(0, LEVEL_SENTINEL)
	if LevelManager != null and LevelManager.has_method("list_level_names"):
		for lv in LevelManager.list_level_names():
			level_ob.add_item(str(lv))
			level_ob.set_item_metadata(level_ob.item_count - 1, str(lv))
	var level_custom := _mk_line(fnt, "或手动输入关卡名")
	widgets["level"] = _add_field(grid, fnt, "关卡名", _compound([level_ob, level_custom]))

	# 12) 自测参数（perf）
	var perf_ob := _mk_option(fnt)
	_fill_pairs(perf_ob, PERF_ARGS)
	widgets["perf_arg"] = _add_field(grid, fnt, "参数", perf_ob)

	# 13) 帮助的命令（help）
	var help_ob := _mk_option(fnt)
	help_ob.add_item(TranslationManager.t("(全部命令)"))
	help_ob.set_item_metadata(0, "")
	for name in ConsoleCommandScript.command_names():
		help_ob.add_item(TranslationManager.t(ConsoleCommandScript.command_label(name)))
		help_ob.set_item_metadata(help_ob.item_count - 1, name)
	widgets["help_cmd"] = _add_field(grid, fnt, "帮助的命令", help_ob)

	# 13b) 播放事件（play_event）：事件链下拉（含 auto=同事件链）+ 事件名
	var chain_ob := _mk_option(fnt)
	chain_ob.add_item(TranslationManager.t("(同事件链 auto)"))
	chain_ob.set_item_metadata(0, "auto")
	# ★ EventFile 是已注册的 class_name（见 ui/event_file.gd），其 list_chains 为 static，可直接调用。
	for ch in EventFile.list_chains():
		chain_ob.add_item(str(ch))
		chain_ob.set_item_metadata(chain_ob.item_count - 1, str(ch))
	var want_chain: String = str(parsed.get("chain", ""))
	if want_chain != "" and want_chain != "auto" and not _has_meta(chain_ob, want_chain):
		chain_ob.add_item(want_chain)   # 源里的链名不在列表 → 补项，避免往返丢链
		chain_ob.set_item_metadata(chain_ob.item_count - 1, want_chain)
	_select_by_meta(chain_ob, want_chain if want_chain != "" else "auto")
	widgets["chain"] = _add_field(grid, fnt, "事件链", chain_ob)

	var event_le := _mk_line(fnt, "事件名")
	event_le.text = str(parsed.get("event", parsed.get("ev_name", "")))
	widgets["event"] = _add_field(grid, fnt, "事件名", event_le)

	# 13c) 添加到时间轴（add_timeline）
	#   预计时间：相对（10m / 90s / 2h）或绝对（2026.10.11.20:00）自动判别；
	#   效果 / 触发事件至少填一项；其他属性按计划文件的 k=v;… 写法原样保留。
	var tl_time_le := _mk_line(fnt, "预计时间：10m / 90s / 2h，或 2026.10.11.20:00")
	tl_time_le.text = str(parsed.get("tl_time", ""))
	widgets["tl_time"] = _add_field(grid, fnt, "预计时间", tl_time_le)

	var tl_effect_le := _mk_line(fnt, "时间轴效果（要执行的命令，如 /set_var a = 1）")
	tl_effect_le.text = str(parsed.get("tl_effect", ""))
	widgets["tl_effect"] = _add_field(grid, fnt, "时间轴效果", tl_effect_le)

	var tl_event_le := _mk_line(fnt, "触发事件（事件链/事件名）")
	tl_event_le.text = str(parsed.get("tl_event", ""))
	widgets["tl_event"] = _add_field(grid, fnt, "触发事件", tl_event_le)

	var tl_props_le := _mk_line(fnt, "其他属性（如 tag=提醒;ignore=1）")
	tl_props_le.text = str(parsed.get("tl_props", ""))
	widgets["tl_props"] = _add_field(grid, fnt, "其他属性", tl_props_le)

	# 13d) 状态标签（add_tag / remove_tag / clear_tags）
	#   ★ 状态 = StateRegistry 的**友好名**（不是文件名）；字段 = 该状态现有的「字符串数组」字段。
	#     这套下拉就是「明确的标签入口」——用户不必再自己去猜要往哪个变量里塞数组。
	var tag_state_ob := _mk_option(fnt)
	tag_state_ob.add_item(TranslationManager.t(TAG_STATE_SENTINEL))
	tag_state_ob.set_item_metadata(0, TAG_STATE_SENTINEL)
	for fr in StateRegistry.tag_writable_friendly():
		tag_state_ob.add_item(TranslationManager.t(fr))
		tag_state_ob.set_item_metadata(tag_state_ob.item_count - 1, fr)
	# ★ 源里的状态不在列表里（未注册 / 改名）→ 临时补一项，否则往返会静默丢掉状态名
	var want_tag_state: String = str(parsed.get("tag_state", ""))
	if want_tag_state != "" and not _has_meta(tag_state_ob, want_tag_state):
		tag_state_ob.add_item(want_tag_state)
		tag_state_ob.set_item_metadata(tag_state_ob.item_count - 1, want_tag_state)
	_select_by_meta(tag_state_ob, want_tag_state)
	widgets["tag_state"] = _add_field(grid, fnt, "状态", tag_state_ob)

	var tag_field_ob := _mk_option(fnt)
	var tag_field_le := _mk_line(fnt, "或手动输入字段名（顶层字符串数组）")
	widgets["tag_field"] = _add_field(grid, fnt, "标签字段", _compound([tag_field_ob, tag_field_le]))

	var tag_value_le := _mk_line(fnt, "要添加 / 移除的标签（如 得到钥匙）")
	tag_value_le.text = str(parsed.get("tag_value", ""))
	widgets["tag_value"] = _add_field(grid, fnt, "标签", tag_value_le)

	# 14) 其他参数 / 其他判定（原样保留，避免往返丢数据）
	var extras_le := _mk_line(fnt, "其他参数（原样保留，如 width=120, tags={gravity}）")
	extras_le.text = str(parsed.get("extras", ""))
	widgets["extras"] = _add_field(grid, fnt, "其他参数", extras_le)

	# ---- DSL 预览（该行当前会写出什么）----
	var hint := Label.new()
	hint.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.62))
	hint.add_theme_font_size_override("font_size", maxi(UIStyle.FONT_SIZE - 3, 9))
	if is_instance_valid(fnt):
		hint.add_theme_font_override("font", fnt)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(hint)

	_rows_box.add_child(vbox)

	var rec := {
		"vbox": vbox, "widgets": widgets, "hint": hint,
		"cmd_ob": cmd_ob, "del_btn": del,
		"block_type_ob": block_type_ob, "string_id_le": string_id_le, "position_le": position_le,
		"ref_ob": ref_ob, "ref_custom": ref_custom,
		"var_ob": var_ob, "var_custom": var_custom,
		"set_op_ob": set_op_ob, "rm_mode_ob": rm_mode_ob,
		"vtype_ob": vtype_ob, "value_le": value_le,
		"cond_le": cond_le,
		"level_ob": level_ob, "level_custom": level_custom,
		"perf_ob": perf_ob, "help_ob": help_ob,
		"chain_ob": chain_ob, "event_le": event_le,
		"tl_time_le": tl_time_le, "tl_effect_le": tl_effect_le,
		"tl_event_le": tl_event_le, "tl_props_le": tl_props_le,
		"tag_state_ob": tag_state_ob, "tag_field_ob": tag_field_ob,
		"tag_field_le": tag_field_le, "tag_value_le": tag_value_le,
		"extras_le": extras_le,
		# 只有当前命令仍等于解析时那一条，才沿用解析出来的附加信息
		"parsed_cmd": str(parsed.get("cmd", "")),
		"parsed_var": str(parsed.get("var", "")),
		"var_tail_extra": str(parsed.get("var_tail_extra", "")),
		# ★ 源里 after= 与 time= 同时出现时，只显示一个输入框 → 另一个原样寄存在这里，
		#   序列化时补回，绝不静默丢（用户一旦改动预计时间输入框即丢弃该寄存）。
		"tl_time_extra": str(parsed.get("tl_time_extra", "")),
	}
	_rows.append(rec)

	# ---- 初始回填 ----
	_select_by_meta(set_op_ob, str(parsed.get("op", "=")))
	_select_by_meta(rm_mode_ob, str(parsed.get("rm_mode", "remove_key")))
	_select_by_meta(vtype_ob, str(parsed.get("vtype", "auto")))
	_select_by_meta(perf_ob, str(parsed.get("perf_arg", "")))
	_select_by_meta(help_ob, str(parsed.get("help_cmd", "")))
	var lv := str(parsed.get("level", ""))
	if lv != "" and not _select_by_meta(level_ob, lv):
		level_custom.text = lv
	_apply_ref(rec, str(parsed.get("ref", "")), str(parsed.get("var", "")))
	# 标签字段下拉：据当前状态重建；源里的字段不在候选里 → 落到手填框（往返不丢）
	_populate_tag_fields(rec, _tag_state_of(rec))
	var want_tag_field: String = str(parsed.get("tag_field", ""))
	if want_tag_field != "" and not _select_by_meta(tag_field_ob, want_tag_field):
		tag_field_le.text = want_tag_field

	# ---- 信号 ----
	cmd_ob.item_selected.connect(func(_i: int) -> void: _on_cmd_changed(rec))
	ref_ob.item_selected.connect(func(_i: int) -> void: _on_ref_changed(rec))
	ref_custom.text_changed.connect(func(_t: String) -> void: _recompute())
	var_ob.item_selected.connect(func(_i: int) -> void: _recompute())
	var_custom.text_changed.connect(func(_t: String) -> void: _recompute())
	set_op_ob.item_selected.connect(func(_i: int) -> void: _recompute())
	rm_mode_ob.item_selected.connect(func(_i: int) -> void: _on_rm_mode_changed(rec))
	vtype_ob.item_selected.connect(func(_i: int) -> void: _recompute())
	value_le.text_changed.connect(func(_t: String) -> void: _recompute())
	cond_le.text_changed.connect(func(_t: String) -> void: _recompute())
	block_type_ob.item_selected.connect(func(_i: int) -> void: _recompute())
	string_id_le.text_changed.connect(func(_t: String) -> void: _recompute())
	position_le.text_changed.connect(func(_t: String) -> void: _recompute())
	extras_le.text_changed.connect(func(_t: String) -> void: _recompute())
	level_ob.item_selected.connect(func(_i: int) -> void: _recompute())
	level_custom.text_changed.connect(func(_t: String) -> void: _recompute())
	perf_ob.item_selected.connect(func(_i: int) -> void: _recompute())
	help_ob.item_selected.connect(func(_i: int) -> void: _recompute())
	chain_ob.item_selected.connect(func(_i: int) -> void: _recompute())
	event_le.text_changed.connect(func(_t: String) -> void: _recompute())
	tl_time_le.text_changed.connect(func(_t: String) -> void:
		rec["tl_time_extra"] = ""     # 用户改过预计时间 → 丢弃寄存的另一种写法
		_recompute())
	tl_effect_le.text_changed.connect(func(_t: String) -> void: _recompute())
	tl_event_le.text_changed.connect(func(_t: String) -> void: _recompute())
	tl_props_le.text_changed.connect(func(_t: String) -> void: _recompute())
	tag_state_ob.item_selected.connect(func(_i: int) -> void:
		# 换状态 → 标签字段换一批（当前字段不在新候选里时，手填框里的值原样保留）
		_populate_tag_fields(rec, _tag_state_of(rec))
		_recompute())
	tag_field_ob.item_selected.connect(func(_i: int) -> void: _recompute())
	tag_field_le.text_changed.connect(func(_t: String) -> void: _recompute())
	tag_value_le.text_changed.connect(func(_t: String) -> void: _recompute())
	del.pressed_id.connect(func(_id: String) -> void: _remove_row(rec))

	_refresh_row_visibility(rec)
	_recompute()
	# ★ 本行建完后再重译：显示文本换成当前语言，metadata（真值）不受影响。
	TranslationManager.retranslate_tree(vbox)


# ================= 小控件工厂 =================

func _mk_option(fnt: FontFile) -> OptionButton:
	var ob := OptionButton.new()
	if is_instance_valid(fnt):
		ob.add_theme_font_override("font", fnt)
	ob.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return ob


func _mk_line(fnt: FontFile, placeholder: String) -> LineEdit:
	var le := LineEdit.new()
	le.placeholder_text = placeholder
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if is_instance_valid(fnt):
		le.add_theme_font_override("font", fnt)
	UIStyle.apply_line_edit_style(le)
	return le


func _compound(parts: Array) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_theme_constant_override("separation", 4)
	for p in parts:
		h.add_child(p)
	return h


# 把一个字段（标签 + 控件）加进 2 列网格，返回 {label, ctrl} 供显隐控制。
func _add_field(grid: GridContainer, fnt: FontFile, label_text: String, ctrl: Control) -> Dictionary:
	var lb := Label.new()
	lb.text = label_text
	lb.custom_minimum_size = Vector2(74.0, 0.0)
	lb.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
	lb.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
	if is_instance_valid(fnt):
		lb.add_theme_font_override("font", fnt)
	grid.add_child(lb)
	grid.add_child(ctrl)
	return {"label": lb, "ctrl": ctrl}


# 用 [真值, 显示名] 对填下拉：显示名翻译，真值进 metadata。
func _fill_pairs(ob: OptionButton, pairs: Array) -> void:
	for pair in pairs:
		ob.add_item(TranslationManager.t(str(pair[1])))
		ob.set_item_metadata(ob.item_count - 1, str(pair[0]))


# ================= 真值读取（一律走 metadata）=================

func _meta_of(ob: OptionButton) -> String:
	if ob == null or ob.selected < 0:
		return ""
	var md: Variant = ob.get_item_metadata(ob.selected)
	return str(md) if md != null else ob.get_item_text(ob.selected)


# 按真值选中某项（OptionButton.get_item_index 在本版本要求 int，故自行线性查找）。
func _select_by_meta(ob: OptionButton, value: String) -> bool:
	for i in ob.item_count:
		if str(ob.get_item_metadata(i)) == value:
			ob.select(i)
			return true
	return false


func _select_cmd(ob: OptionButton, cmd: String) -> void:
	_select_by_meta(ob, cmd)


# 下拉里有没有这个真值项（用于「补项」判断）
func _has_meta(ob: OptionButton, value: String) -> bool:
	for i in ob.item_count:
		if str(ob.get_item_metadata(i)) == value:
			return true
	return false


func _cmd_of(ob: OptionButton) -> String:
	return _meta_of(ob)


# 变量下拉的真值；哨兵项 → ""（表示「没选变量」）。
func _var_name_of(ob: OptionButton) -> String:
	var s := _meta_of(ob)
	return "" if s == VAR_SENTINEL else s


# 目标引用的第一段（真值）：选注册项 → 文件名；选自定义 → 手填文本。
func _ref_root(rec: Dictionary) -> String:
	var ob: OptionButton = rec["ref_ob"]
	var custom: LineEdit = rec["ref_custom"]
	var sel := _meta_of(ob)
	if sel == CUSTOM_REF_LABEL:
		return custom.text.strip_edges()
	var f := StateRegistry.file_of(sel)
	return f if f != "" else sel


# 变量名：优先下拉真值，哨兵时退回手填。
func _var_value(rec: Dictionary) -> String:
	var v := _var_name_of(rec["var_ob"])
	if v == "":
		v = (rec["var_custom"] as LineEdit).text.strip_edges()
	return v


# 关卡名：优先下拉真值，哨兵时退回手填。
func _level_value(rec: Dictionary) -> String:
	var v := _meta_of(rec["level_ob"])
	if v == LEVEL_SENTINEL:
		v = ""
	if v == "":
		v = (rec["level_custom"] as LineEdit).text.strip_edges()
	return v


func _ref_display_of(file_or_root: String) -> String:
	if file_or_root == "":
		return ""
	var fr := StateRegistry.friendly_of_file(file_or_root)
	return fr if fr != "" else file_or_root


# 变量下拉：据目标文件列「注册变量 + 文件实际键」，首项是哨兵。
func _populate_vars(var_ob: OptionButton, file: String) -> void:
	var_ob.clear()
	var_ob.add_item(TranslationManager.t(VAR_SENTINEL))
	var_ob.set_item_metadata(0, VAR_SENTINEL)
	var fr := StateRegistry.friendly_of_file(file)
	if fr != "":
		for v in StateRegistry.effective_vars_of(fr):
			var_ob.add_item(v)
			var_ob.set_item_metadata(var_ob.item_count - 1, v)


# ---- 状态标签（批次 96）----

# 状态下拉真值 = 友好名；哨兵 → ""（表示「没选状态」）。
func _tag_state_of(rec: Dictionary) -> String:
	var v := _meta_of(rec["tag_state_ob"])
	return "" if v == TAG_STATE_SENTINEL else v


# 标签字段：优先下拉真值，哨兵时退回手填。
func _tag_field_of(rec: Dictionary) -> String:
	var v := _meta_of(rec["tag_field_ob"])
	if v == TAG_FIELD_SENTINEL:
		v = ""
	if v == "":
		v = (rec["tag_field_le"] as LineEdit).text.strip_edges()
	return v


# 标签字段下拉：据**该状态**的现有「字符串数组」字段重建（StateRegistry.tag_fields_of）。
# ★ OptionButton.clear() 不复位 selected → 清空后必须显式 select(0)。
# ★ 候选只有一个 → **自动选中它**（与控制台「唯一候选自动用」的规则一致）：
#   这样编辑器写出来的命令总是带 field，不会把「哪个字段」这件事故意留给运行期去猜。
func _populate_tag_fields(rec: Dictionary, state: String) -> void:
	var ob: OptionButton = rec["tag_field_ob"]
	ob.clear()
	ob.add_item(TranslationManager.t(TAG_FIELD_SENTINEL))
	ob.set_item_metadata(0, TAG_FIELD_SENTINEL)
	if state != "":
		for f in StateRegistry.tag_fields_of(state):
			ob.add_item(str(f))
			ob.set_item_metadata(ob.item_count - 1, str(f))
	if ob.item_count == 2:
		ob.select(1)
	else:
		ob.select(0)


# 回填「目标引用 + 变量」：显示串可能是友好名（注册过）或裸引用（自定义）。
# 自定义引用也可能带「:变量」（解析时已拆开，这里只管引用本身）。
func _apply_ref(rec: Dictionary, ref_display: String, var_name: String) -> void:
	var ref_ob: OptionButton = rec["ref_ob"]
	var ref_custom: LineEdit = rec["ref_custom"]
	var var_ob: OptionButton = rec["var_ob"]
	var var_custom: LineEdit = rec["var_custom"]
	if ref_display != "" and not _select_by_meta(ref_ob, ref_display):
		_select_by_meta(ref_ob, CUSTOM_REF_LABEL)
		ref_custom.text = ref_display
	ref_custom.visible = _meta_of(ref_ob) == CUSTOM_REF_LABEL
	_populate_vars(var_ob, _ref_root(rec))
	if var_name != "" and not _select_by_meta(var_ob, var_name):
		var_custom.text = var_name


# ================= 显隐 =================

func _refresh_row_visibility(rec: Dictionary) -> void:
	var cmd := _cmd_of(rec["cmd_ob"])
	var fields: Array = FIELDS.get(cmd, [])
	var widgets: Dictionary = rec["widgets"]
	var show_value := true
	if cmd == "remove_var":
		show_value = _meta_of(rec["rm_mode_ob"]) == "remove_elem"
	for f in widgets:
		var w: Dictionary = widgets[f]
		var on: bool = (f in fields)
		if f == "value":
			on = on and show_value
		w["label"].visible = on
		w["ctrl"].visible = on
	# 「其他参数 / 其他判定」的占位文案随命令换（都是翻译 key）
	var extras_le: LineEdit = rec["extras_le"]
	extras_le.placeholder_text = "其他判定（如 width=120）" if cmd == "remove_block" else "其他参数（原样保留，如 width=120, tags={gravity}）"


func _on_cmd_changed(rec: Dictionary) -> void:
	_refresh_row_visibility(rec)
	_recompute()
	# ★ 命令换掉的这一行，之前解析出来的「其他参数/嵌套路径」不再适用 → 清空，避免张冠李戴
	if _cmd_of(rec["cmd_ob"]) != str(rec["parsed_cmd"]):
		(rec["extras_le"] as LineEdit).text = ""
		rec["var_tail_extra"] = ""
		rec["tl_time_extra"] = ""


func _on_ref_changed(rec: Dictionary) -> void:
	ref_custom_visible(rec)
	_populate_vars(rec["var_ob"], _ref_root(rec))
	(rec["var_custom"] as LineEdit).text = ""
	_recompute()


# remove_var 的「模式」改变会决定「值」这一栏要不要出现
func _on_rm_mode_changed(rec: Dictionary) -> void:
	_refresh_row_visibility(rec)
	_recompute()


func ref_custom_visible(rec: Dictionary) -> void:
	(rec["ref_custom"] as LineEdit).visible = _meta_of(rec["ref_ob"]) == CUSTOM_REF_LABEL


func _remove_row(rec: Dictionary) -> void:
	var vbox: Control = rec["vbox"]
	if vbox.get_parent() != null:
		vbox.get_parent().remove_child(vbox)
	vbox.queue_free()
	_rows.erase(rec)
	_recompute()


# ================= 序列化（行 → DSL 串，写回来源 LineEdit）=================

func _recompute() -> void:
	if _source_le == null:
		return
	var lines: Array[String] = []
	for rec in _rows:
		var line := _row_dsl(rec)
		var hint: Label = rec["hint"]
		hint.text = line if line != "" else "（未完成：请补齐必填项）"
		if line != "":
			lines.append(line)
	_source_le.text = "; ".join(lines)


func _row_dsl(rec: Dictionary) -> String:
	var cmd := _cmd_of(rec["cmd_ob"])
	match cmd:
		"create_block":
			return _dsl_create_block(rec)
		"remove_block":
			return _dsl_remove_block(rec)
		"set_var", "add_var", "remove_var":
			return _dsl_var(rec, cmd)
		"load_level":
			return _dsl_load_level(rec)
		"perf":
			return _dsl_perf(rec)
		"help":
			return _dsl_help(rec)
		"play_event":
			return _dsl_play_event(rec)
		"add_timeline":
			return _dsl_add_timeline(rec)
		"add_tag", "remove_tag", "clear_tags":
			return _dsl_tag(rec, cmd)
		"clear":
			return "/clear"
	return ""


## 状态标签：state（必填）+ field（可省：只有一个候选时已自动选中；多候选留空则交由
## 控制台按同一套规则处理 —— 与 has_tag 的判定范围同源）+ tag（clear_tags 不需要）。
## ★ 严格「1 行 = 1 条命令 = 1 条标签」：与条件侧 has_tag(状态,标签) 一一对称，
##   要加多条标签就再加一行（"＋ 添加命令"）——不在这里做逗号拆分，
##   否则「源串 → 行 → DSL」会一行变多行，用户看到的东西和存下来的东西对不上。
func _dsl_tag(rec: Dictionary, cmd: String) -> String:
	var st := _tag_state_of(rec)
	var fld := _tag_field_of(rec)
	if st == "":
		return ""
	var parts: Array[String] = ["state=%s" % _quote_always(st)]
	if fld != "":
		parts.append("field=%s" % _quote_always(fld))
	if cmd == "clear_tags":
		return "/clear_tags { %s }" % ", ".join(parts)
	var tag := (rec["tag_value_le"] as LineEdit).text.strip_edges()
	if tag == "":
		return ""
	parts.append("tag=%s" % _quote_always(tag))
	return "/%s { %s }" % [cmd, ", ".join(parts)]


## 添加到时间轴：预计时间（相对/绝对自动判别，绝对补全成 HH:MM:SS）+ 效果 / 触发事件 + 其他属性。
## ★ 必填：预计时间 + （效果 或 触发事件）之一；缺一个就返回 ""（提示「未完成」而不是写出半截命令）。
func _dsl_add_timeline(rec: Dictionary) -> String:
	var t := (rec["tl_time_le"] as LineEdit).text.strip_edges()
	var effect := (rec["tl_effect_le"] as LineEdit).text.strip_edges()
	var ev := (rec["tl_event_le"] as LineEdit).text.strip_edges()
	var props := (rec["tl_props_le"] as LineEdit).text.strip_edges()
	if t == "":
		return ""
	if effect == "" and ev == "":
		return ""
	var parts: Array[String] = []
	if _looks_absolute_time(t):
		parts.append("time=%s" % _quote_always(_normalize_abs_time(t)))
	else:
		parts.append("after=%s" % _quote_always(t))
	if effect != "":
		parts.append("effect=%s" % _quote_always(effect))
	if ev != "":
		parts.append("event=%s" % _quote_always(ev))
	if props != "":
		# 其他属性：界面里按计划文件的 k=v;… 写法填写 → 逐项转成 bag 的逗号分隔
		for piece in props.split(";"):
			var p := piece.strip_edges()
			if p != "":
				parts.append(p)
	var extra := str(rec.get("tl_time_extra", "")).strip_edges()
	if extra != "":
		parts.append(extra)
	return "/add_timeline { %s }" % ", ".join(parts)


## 判断「预计时间」输入是绝对时刻（YYYY.MM.DD.HH:MM / …:SS）还是相对时长（10m / 90s）。
## ★ 不用正则：按固定位置逐字符判数字，失败分支一眼可见。
func _looks_absolute_time(t: String) -> bool:
	var s := t.strip_edges()
	if s.length() != 16 and s.length() != 19:
		return false
	if s[4] != "." or s[7] != "." or s[10] != "." or s[13] != ":":
		return false
	if s.length() == 19 and s[16] != ":":
		return false
	for i in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15]:
		var c: String = s[i]
		if c < "0" or c > "9":
			return false
	if s.length() == 19:
		for i2 in [17, 18]:
			var c2: String = s[i2]
			if c2 < "0" or c2 > "9":
				return false
	return true


## "2026.10.11.20:00" → "2026.10.11.20:00:00"（计划文件要求带秒）
func _normalize_abs_time(t: String) -> String:
	var s := t.strip_edges()
	return s + ":00" if s.length() == 16 else s


## 播放事件：事件链为 auto（同事件链）时只写事件名，否则写「链 事件名」。
func _dsl_play_event(rec: Dictionary) -> String:
	var chain := _meta_of(rec["chain_ob"]).strip_edges()
	var ev := (rec["event_le"] as LineEdit).text.strip_edges()
	if ev == "":
		return "/play_event"
	if chain == "" or chain == "auto":
		return "/play_event %s" % _quote(ev)
	return "/play_event %s %s" % [_quote(chain), _quote(ev)]


func _dsl_create_block(rec: Dictionary) -> String:
	var parts: Array[String] = []
	var tname := _meta_of(rec["block_type_ob"])
	if tname != "":
		parts.append("block_type=%s" % _quote_always(tname))
	var sid := (rec["string_id_le"] as LineEdit).text.strip_edges()
	if sid != "":
		parts.append("string_id=%s" % _quote_always(sid))
	var pos := _parse_xy((rec["position_le"] as LineEdit).text)
	if pos != "":
		parts.append("position=%s" % pos)
	var ex := _extras_text(rec, "create_block")
	if ex != "":
		parts.append(ex)
	if parts.is_empty():
		return "/create_block"
	return "/create_block { %s }" % ", ".join(parts)


func _dsl_remove_block(rec: Dictionary) -> String:
	var parts: Array[String] = []
	var sid := (rec["string_id_le"] as LineEdit).text.strip_edges()
	if sid != "":
		parts.append("string_id=%s" % _quote_always(sid))
	var ex := _extras_text(rec, "remove_block")
	if ex != "":
		parts.append(ex)
	var cond := (rec["cond_le"] as LineEdit).text.strip_edges()
	if parts.is_empty() and cond == "":
		return ""   # 什么都不给 = 会误删全部积木 → 不产出（控制台也会拒绝）
	var out := "/remove_block"
	if not parts.is_empty():
		out += " { %s }" % ", ".join(parts)
	if cond != "":
		out += " if ( %s )" % cond
	return out


func _dsl_var(rec: Dictionary, cmd: String) -> String:
	var root := _ref_root(rec)
	var var_name := _var_value(rec)
	if root == "" and var_name == "":
		return ""
	var ref := root
	if var_name != "":
		ref += ":" + var_name
	if var_name != "" and var_name == str(rec["parsed_var"]) and str(rec["var_tail_extra"]) != "":
		ref += ":" + str(rec["var_tail_extra"])     # 嵌套路径原样保留
	if cmd == "add_var":
		var lit := _value_literal(rec)
		if lit == "":
			return ""
		return "/add_var %s = %s" % [ref, lit]
	if cmd == "remove_var":
		if _meta_of(rec["rm_mode_ob"]) == "remove_elem":
			var lit := _value_literal(rec)
			if lit == "":
				return ""
			return "/remove_var %s = %s" % [ref, lit]
		return "/remove_var %s" % ref
	# set_var
	var op := _meta_of(rec["set_op_ob"])
	var lit := _value_literal(rec)
	if lit == "":
		return ""
	return "/set_var %s %s %s" % [ref, op, lit]


func _dsl_load_level(rec: Dictionary) -> String:
	var lv := _level_value(rec)
	if lv == "":
		return ""
	return "/load_level %s" % _quote_always(lv)


func _dsl_perf(rec: Dictionary) -> String:
	var a := _meta_of(rec["perf_ob"])
	return "/perf" if a == "" else "/perf %s" % a


func _dsl_help(rec: Dictionary) -> String:
	var c := _meta_of(rec["help_ob"])
	return "/help" if c == "" else "/help %s" % c


# 该行「其他参数」文本：只有当前命令 == 解析时那条才带上（避免命令换掉后张冠李戴）
func _extras_text(rec: Dictionary, cmd: String) -> String:
	if _cmd_of(rec["cmd_ob"]) != str(rec["parsed_cmd"]):
		return ""
	return (rec["extras_le"] as LineEdit).text.strip_edges()


# 值 → DSL 字面量（按「值类型」决定引号/格式）
func _value_literal(rec: Dictionary) -> String:
	var raw := (rec["value_le"] as LineEdit).text.strip_edges()
	var vt := _meta_of(rec["vtype_ob"])
	match vt:
		"string":
			return _quote_always(raw)
		"int":
			return raw if raw.is_valid_int() else _quote(raw)
		"float":
			return raw if (raw.is_valid_float() or raw.is_valid_int()) else _quote(raw)
		"bool":
			return "true" if _truthy(raw) else "false"
		"null":
			return "null"
	if raw == "":
		return ""    # 自动模式且为空 → 视为未填
	return _quote(raw)


func _truthy(s: String) -> bool:
	var t := s.strip_edges().to_lower()
	return t in ["true", "1", "yes", "on", "是", "真"]


func _quote(v: String) -> String:
	var s := v.strip_edges()
	if s == "":
		return "\"\""
	if s in ["true", "false", "null"]:
		return s
	if s.is_valid_int() or s.is_valid_float():
		return s
	return _quote_always(s)


func _quote_always(v: String) -> String:
	return "\"" + v.replace("\"", "\\\"") + "\""


# "100,200" / "(100,200)" → "(100,200)"；非法返回 ""
func _parse_xy(s: String) -> String:
	var t := s.strip_edges()
	if t == "":
		return ""
	if t.begins_with("(") and t.ends_with(")"):
		t = t.substr(1, t.length() - 2)
	var segs := t.split(",")
	if segs.size() != 2:
		return ""
	var a := segs[0].strip_edges()
	var b := segs[1].strip_edges()
	if not (a.is_valid_float() or a.is_valid_int()) or not (b.is_valid_float() or b.is_valid_int()):
		return ""
	return "(%s,%s)" % [a, b]


# ================= 反序列化（来源 LineEdit → 行）=================

func _parse_source() -> void:
	if _source_le == null:
		return
	var txt := _source_le.text
	var any := false
	for line in _split_effect(txt):
		_add_row(_parse_line(line))
		any = true
	if not any:
		_add_row({})


func _split_effect(txt: String) -> Array[String]:
	var out: Array[String] = []
	for raw in txt.split("\n", false):
		for seg in _split_top(raw, ";"):
			var s := seg.strip_edges()
			if s != "":
				out.append(s)
	return out


func _parse_line(line: String) -> Dictionary:
	var s := line.strip_edges()
	if s.begins_with("/"):
		s = s.substr(1)
	var sp := s.find(" ")
	var cmd := s
	var rest := ""
	if sp >= 0:
		cmd = s.substr(0, sp)
		rest = s.substr(sp + 1).strip_edges()
	var out := {
		"cmd": cmd,
		"block_type": "", "string_id": "", "position": "", "extras": "",
		"ref": "", "var": "", "var_tail_extra": "",
		"op": "=", "rm_mode": "remove_key", "vtype": "auto", "value": "",
		"cond": "", "level": "", "perf_arg": "", "help_cmd": "",
		"chain": "", "event": "",
		"tl_time": "", "tl_time_extra": "", "tl_effect": "", "tl_event": "", "tl_props": "",
		"tag_state": "", "tag_field": "", "tag_value": "",
	}
	match cmd:
		"create_block":
			_parse_create_block(rest, out)
		"remove_block":
			_parse_remove_block(rest, out)
		"set_var", "add_var", "remove_var":
			_parse_var(cmd, rest, out)
		"load_level":
			out["level"] = _unquote(rest)
		"perf":
			out["perf_arg"] = rest
		"help":
			out["help_cmd"] = rest
		"play_event":
			_parse_play_event(rest, out)
		"add_timeline":
			_parse_add_timeline(rest, out)
		"add_tag", "remove_tag", "clear_tags":
			_parse_tag(rest, out)
	return out


## 解析 /add_tag · /remove_tag · /clear_tags：
##   bag 写法   { state="剧情状态", field="tags", tag="得到钥匙" }
##   位置写法   <状态> [标签] [字段]     （/clear_tags 是 <状态> [字段]）
func _parse_tag(rest: String, out: Dictionary) -> void:
	var r := rest.strip_edges()
	if r.begins_with("{"):
		var bag := _parse_bag_text(r)
		if bag.has("state"):
			out["tag_state"] = _unquote(str((bag["state"] as Dictionary)["val"]))
		elif bag.has("status"):
			out["tag_state"] = _unquote(str((bag["status"] as Dictionary)["val"]))
		if bag.has("field"):
			out["tag_field"] = _unquote(str((bag["field"] as Dictionary)["val"]))
		var tk := ""
		if bag.has("tag"):
			tk = "tag"
		elif bag.has("value"):
			tk = "value"
		if tk != "":
			out["tag_value"] = _unquote(str((bag[tk] as Dictionary)["val"]))
		return
	var args := _split_ws_top(r)
	if args.size() >= 1:
		out["tag_state"] = _unquote(args[0])
	if str(out["cmd"]) == "clear_tags":
		if args.size() >= 2:
			out["tag_field"] = _unquote(args[1])
	else:
		if args.size() >= 2:
			out["tag_value"] = _unquote(args[1])
		if args.size() >= 3:
			out["tag_field"] = _unquote(args[2])


## 解析 /add_timeline { after=… | time=…, effect=…, event=…, tag=…, ignore=…, delay=…, max_skip=… }
func _parse_add_timeline(rest: String, out: Dictionary) -> void:
	var r := rest.strip_edges()
	if not r.begins_with("{"):
		return
	var bag := _parse_bag_text(r)
	var after := ""
	var absolute := ""
	if bag.has("after"):
		after = _unquote(str((bag["after"] as Dictionary)["val"]))
	if bag.has("time"):
		absolute = _unquote(str((bag["time"] as Dictionary)["val"]))
	if bag.has("effect"):
		out["tl_effect"] = _unquote(str((bag["effect"] as Dictionary)["val"]))
	if bag.has("event"):
		out["tl_event"] = _unquote(str((bag["event"] as Dictionary)["val"]))
	# 计划属性：原样保留（恢复成计划文件里的 k=v;k2=v2 写法）
	# ★ 键表以 ConsoleCommand.TIMELINE_PROP_KEYS 为唯一真源，避免两处漂移。
	var ps: Array[String] = []
	for k in ConsoleCommandScript.TIMELINE_PROP_KEYS:
		if bag.has(str(k)):
			ps.append(str((bag[str(k)] as Dictionary)["raw"]))
	out["tl_props"] = ";".join(ps)
	# 预计时间：绝对优先展示；两者同时出现时把「相对」寄存在 tl_time_extra，往返不丢
	if absolute != "" and after != "":
		out["tl_time"] = absolute
		out["tl_time_extra"] = "after=%s" % _quote_always(after)
	else:
		out["tl_time"] = absolute if absolute != "" else after


## 解析 /play_event 的两种写法：
##   <事件名>            → chain 留 ""（=auto，同事件链）
##   <事件链> <事件名>    → 两段
##   { chain="x", name="y" } → bag 形式（name 也可写 event）
func _parse_play_event(rest: String, out: Dictionary) -> void:
	var r := rest.strip_edges()
	if r.begins_with("{"):
		var bag := _parse_bag_text(r)
		if bag.has("chain"):
			out["chain"] = _unquote(str((bag["chain"] as Dictionary)["val"]))
		var nm_key := "name" if bag.has("name") else ("event" if bag.has("event") else "")
		if nm_key != "":
			out["event"] = _unquote(str((bag[nm_key] as Dictionary)["val"]))
		return
	var args := _split_ws_top(r)
	if args.size() >= 2:
		out["chain"] = _unquote(args[0])
		out["event"] = _unquote(args[1])
	elif args.size() == 1:
		out["event"] = _unquote(args[0])


## 顶层按空白切分（尊重引号 / 括号 / 花括号嵌套）。
func _split_ws_top(s: String) -> Array[String]:
	var out: Array[String] = []
	var cur := ""
	var depth := 0
	var quote := ""
	for i in s.length():
		var ch := s[i]
		if quote != "":
			cur += ch
			if ch == quote:
				quote = ""
			continue
		if ch == "\"" or ch == "'":
			quote = ch
			cur += ch
			continue
		if ch == "(" or ch == "{" or ch == "[":
			depth += 1
		elif ch == ")" or ch == "}" or ch == "]":
			depth = maxi(0, depth - 1)
		if (ch == " " or ch == "\t" or ch == "\n") and depth == 0:
			if cur != "":
				out.append(cur)
				cur = ""
			continue
		cur += ch
	if cur != "":
		out.append(cur)
	return out


func _parse_create_block(rest: String, out: Dictionary) -> void:
	var bag := _parse_bag_text(rest)
	var extras: Array[String] = []
	for k in bag:
		var kv: Dictionary = bag[k]
		var raw := str(kv["raw"])
		match str(k):
			"block_type":
				out["block_type"] = _unquote(str(kv["val"]))
			"string_id":
				out["string_id"] = _unquote(str(kv["val"]))
			"position":
				out["position"] = _xy_text(str(kv["val"]))
			_:
				extras.append(raw)
	out["extras"] = ", ".join(extras)


func _parse_remove_block(rest: String, out: Dictionary) -> void:
	var pred_part := rest
	var cond_part := ""
	var if_idx := _find_top_kw(rest, "if")
	if if_idx >= 0:
		pred_part = rest.substr(0, if_idx).strip_edges()
		cond_part = rest.substr(if_idx + 2).strip_edges()
		if cond_part.begins_with("(") and cond_part.ends_with(")"):
			cond_part = cond_part.substr(1, cond_part.length() - 2).strip_edges()
	out["cond"] = cond_part
	var bag := _parse_bag_text(pred_part)
	var extras: Array[String] = []
	for k in bag:
		var kv: Dictionary = bag[k]
		match str(k):
			"string_id":
				out["string_id"] = _unquote(str(kv["val"]))
			_:
				extras.append(str(kv["raw"]))
	out["extras"] = ", ".join(extras)


func _parse_var(cmd: String, rest: String, out: Dictionary) -> void:
	var op := "="
	var left := rest
	var right := ""
	var found := _find_top_op(rest)
	if found["idx"] >= 0:
		op = str(found["op"])
		left = rest.substr(0, int(found["idx"])).strip_edges()
		right = rest.substr(int(found["idx"]) + op.length()).strip_edges()
	if cmd == "set_var":
		out["op"] = op
	elif cmd == "remove_var":
		out["rm_mode"] = "remove_elem" if found["idx"] >= 0 else "remove_key"
	# ref 的第一段 = 引用根；其余段 = 变量（第一段进下拉，之后的作嵌套尾巴保留）
	var colon := _find_top_colon(left)
	if colon >= 0:
		out["ref"] = _ref_display_of(left.substr(0, colon).strip_edges())
		var tail := left.substr(colon + 1).strip_edges()
		var segs := tail.split(":")
		if segs.size() > 0:
			out["var"] = segs[0]
		var extra: Array[String] = []
		for i in range(1, segs.size()):
			extra.append(segs[i])
		out["var_tail_extra"] = ":".join(extra)
	else:
		out["ref"] = _ref_display_of(left)
	# 值 + 类型推断（保证「源串 → 行 → DSL」往返保真：带引号的 "100" 不能退化成数字 100）
	var rv := right.strip_edges()
	if rv.begins_with("\"") and rv.ends_with("\"") and rv.length() >= 2:
		out["vtype"] = "string"
		out["value"] = _unquote(rv)
	elif rv == "true" or rv == "false":
		out["vtype"] = "bool"
		out["value"] = rv
	elif rv == "null":
		out["vtype"] = "null"
		out["value"] = ""
	else:
		out["vtype"] = "auto"
		out["value"] = rv


# 解析 "{ k=v, k2, ... }"（也接受没有外层大括号的裸串）。
# 返回 { key: {val: 值文本, raw: 原样片段} }。
func _parse_bag_text(rest: String) -> Dictionary:
	var out: Dictionary = {}
	var s := rest.strip_edges()
	if s == "":
		return out
	if s.begins_with("{"):
		s = s.substr(1)
		if s.ends_with("}"):
			s = s.substr(0, s.length() - 1)
	for piece in _split_top(s, ","):
		var p := piece.strip_edges()
		if p == "":
			continue
		var f := _find_top_op(p)
		if f["idx"] >= 0 and str(f["op"]) == "=":
			var k := p.substr(0, int(f["idx"])).strip_edges()
			var v := p.substr(int(f["idx"]) + 1).strip_edges()
			out[k] = {"val": v, "raw": p}
		else:
			out[p] = {"val": "true", "raw": p}
	return out


# "(100,200)" → "100,200"
func _xy_text(v: String) -> String:
	var t := v.strip_edges()
	if t.begins_with("(") and t.ends_with(")"):
		t = t.substr(1, t.length() - 2)
	return t.replace(" ", "")


func _unquote(v: String) -> String:
	var s := v.strip_edges()
	if s.length() >= 2 and s.begins_with("\"") and s.ends_with("\""):
		return s.substr(1, s.length() - 2).replace("\\\"", "\"")
	return s


# ---- 顶层切分 / 查找（不在 (){}[] 内、不在引号内）----

func _split_top(s: String, sep: String) -> Array[String]:
	var out: Array[String] = []
	var depth := 0
	var in_q := false
	var cur := ""
	var i := 0
	while i < s.length():
		var ch := s[i]
		if in_q:
			cur += ch
			if ch == "\\" and i + 1 < s.length():
				cur += s[i + 1]
				i += 2
				continue
			if ch == "\"":
				in_q = false
			i += 1
			continue
		if ch == "\"":
			in_q = true
			cur += ch
			i += 1
			continue
		if ch == "(" or ch == "{" or ch == "[":
			depth += 1
		elif ch == ")" or ch == "}" or ch == "]":
			depth -= 1
		elif depth == 0 and ch == sep:
			out.append(cur)
			cur = ""
			i += 1
			continue
		cur += ch
		i += 1
	out.append(cur)
	return out


# 顶层 ":" 定位（ref 的「根」与「键」分界）。找不到 -1。
# ★ 不能用 _find_top_kw（那个要求整词、前后是空白），引用里的冒号是紧贴着的。
func _find_top_colon(s: String) -> int:
	var depth := 0
	var in_q := false
	var i := 0
	while i < s.length():
		var ch := s[i]
		if in_q:
			if ch == "\\" and i + 1 < s.length():
				i += 2
				continue
			if ch == "\"":
				in_q = false
			i += 1
			continue
		if ch == "\"":
			in_q = true
			i += 1
			continue
		if ch == "(" or ch == "{" or ch == "[":
			depth += 1
		elif ch == ")" or ch == "}" or ch == "]":
			depth -= 1
		elif depth == 0 and ch == ":":
			return i
		i += 1
	return -1


# 顶层关键字定位（返回起始下标；找不到 -1）。要求整词（前后是空白或串首尾）。
func _find_top_kw(s: String, kw: String) -> int:
	var depth := 0
	var in_q := false
	var i := 0
	while i < s.length():
		var ch := s[i]
		if in_q:
			if ch == "\\" and i + 1 < s.length():
				i += 2
				continue
			if ch == "\"":
				in_q = false
			i += 1
			continue
		if ch == "\"":
			in_q = true
			i += 1
			continue
		if ch == "(" or ch == "{" or ch == "[":
			depth += 1
		elif ch == ")" or ch == "}" or ch == "]":
			depth -= 1
		elif depth == 0 and s.substr(i, kw.length()) == kw:
			var before_ok := i == 0 or s[i - 1] == " "
			var after := i + kw.length()
			var after_ok := after >= s.length() or s[after] == " "
			if before_ok and after_ok:
				return i
		i += 1
	return -1


# 顶层赋值运算符定位：返回 {op, idx}；无则 idx = -1。
# "+=" "-=" "*=" "/=" 优先于裸 "="（避免把 += 里的 = 当赋值号）。
func _find_top_op(s: String) -> Dictionary:
	var depth := 0
	var in_q := false
	var i := 0
	while i < s.length():
		var ch := s[i]
		if in_q:
			if ch == "\\" and i + 1 < s.length():
				i += 2
				continue
			if ch == "\"":
				in_q = false
			i += 1
			continue
		if ch == "\"":
			in_q = true
			i += 1
			continue
		if ch == "(" or ch == "{" or ch == "[":
			depth += 1
		elif ch == ")" or ch == "}" or ch == "]":
			depth -= 1
		elif depth == 0 and ch == "=":
			if i > 0 and s[i - 1] in ["+", "-", "*", "/"]:
				return {"op": s[i - 1] + "=", "idx": i - 1}
			return {"op": "=", "idx": i}
		i += 1
	return {"op": "", "idx": -1}


# ================= 关闭 =================

func close() -> void:
	_recompute()
	closed.emit()
	queue_free()


## 最小化 / 还原：折叠只隐藏内容，顶栏（标题 + 拖动把柄 + 最小化 + 关闭）整排保留。
func set_minimized(v: bool) -> void:
	_minimized = v
	UIMinimize.apply(self, _min_btn, v, _min_btn.get_parent() if is_instance_valid(_min_btn) else null)


## 当前是否处于最小化状态
func is_minimized() -> bool:
	return _minimized


## ★ 批次 94：多开时层叠错开 —— 把整页相对默认位置再偏移一点（页面视觉就是 _bg）。
func set_origin_offset(off: Vector2) -> void:
	if is_instance_valid(_bg):
		_bg.position += off
