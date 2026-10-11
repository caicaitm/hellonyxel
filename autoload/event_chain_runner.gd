# autoload/event_chain_runner.gd
# 事件链 · 顺序执行器（阶段二）。
#
# 职责：把一个事件脚本（EventFile 读取的 JSON dict）按顺序表演出来，并接管其按钮路由：
#   1) close 目标   —— 关闭脚本里点名的对话框（弹窗/底部/通知/积木ID/关卡页面）
#   2) content      —— 按 panel_type 把正文/标题/配图/按钮**写进**对应面板；
#                      panel_type 缺省/为空 = 「无修改」→ 不改动任何面板
#   3) open 目标    —— 打开脚本里点名打开的对话框（含关卡页面）；"auto" = 正文对应的对话框
#   4) buttons      —— 按「显示要求」show 过滤后挂到面板；点按钮就按「效果」处理
#
# ★ 显隐归属（用户要求，2026-10-11 改）：
#   「有没有正文」与「弹不弹面板」是两件事。content 只写内容，**一律不改面板显隐**；
#   显不显示完全由 open 列表说了算 —— 所以把 open 里的 "auto" 删掉，就是明确告诉运行器
#   「本次事件不打开任何面板」，此时正文仍会写进面板缓存，但面板保持原样。
#   （json 里没写 open 键的老脚本按 ["auto"] 处理，行为与改动前一致，见 EventFile.open_targets。）
#
# 目标条目两种形态：
#   · 字符串 / 整数：点名的面板（"popup"/"bottom"/"notification"）或积木 ID；
#   · Dictionary：带参数的复合目标，目前只有 { "level": "<关卡名>" } = 关卡页面。
#     open → 若填了关卡名就先投影该关卡到面板，再显示页面；名字为空 → 只显示。
#     close → 隐藏关卡页面（名字仅作日志）。
#
# 本次约定（与用户确认）：
#   - show：空串 → 恒显示；非空 → 用 EventExpr 表达式求值（真值才显示）。
#   - effect：仅「预留」—— 解析成命令序列并打印日志，暂不真正执行（真正起效果后续再设计）。
#
# 面板类型 → 写入目标：
#   popup         → DialogueManager（event_name/event_image_path/event_content/popup_buttons）
#   bottom        → DialogueManager（character_name/avatar_path/line_text/bottom_buttons）
#   notification  → NotificationManager.show（notification_buttons=true → timeout=0 持久，不自动消失）
#                   ★ 通知是**瞬时**的（没有可显隐的持久面板），所以它由 2) 直接弹出，
#                     不参与 open 的显隐控制；"auto" 在它身上只做「关闭时收掉」。
#   bubble        → 预留（仅日志）
#
# 注册见 project.godot [autoload]：EventChainRunner="*res://autoload/event_chain_runner.gd"
extends Node

const DEFAULT_NOTIFY_TIMEOUT := 5.0

# 当前运行上下文
var _running := false
var _chain := ""
var _pname := ""
var _data: Dictionary = {}
# 通过 show 过滤后的按钮行（保留 effect/show 原文，供按下时查效果）
var _filtered: Array = []


func _ready() -> void:
	if GlobalVars != null:
		EventExpr.globals = GlobalVars
	if StateRegistry != null:
		EventExpr.states = StateRegistry
	# ★ 批次 94：玩家状态谓词解析器。
	#   ★ BusyState 在 autoload 列表里排在 EventChainRunner **之后** → 此处很可能还没进树，
	#     所以用 /root 路径取、拿不到就留给 EventExpr 内部「按节点名惰性取」的兜底。
	var _bs := get_node_or_null("/root/BusyState")
	if _bs != null:
		EventExpr.busy = _bs
	if DialogueManager != null:
		DialogueManager.dialogue_button_pressed.connect(_on_dialogue_button)
	# ★ 玩家切语言 → 用新语言的 txt 把正文与按钮文字重贴一遍（否则正文变了、按钮还是老语言）。
	if TranslationManager != null and not TranslationManager.language_changed.is_connected(_on_language_changed):
		TranslationManager.language_changed.connect(_on_language_changed)
	print("[EventChain] 备用到执行就绪（可 run_event / run_from_schedule 触发）")


# ================= 对外接口 =================

func is_running() -> bool:
	return _running


## 当前正在运行的事件链名（"" = 无）。供 /play_event 的「auto / 不写 = 同事件链」使用。
func current_chain() -> String:
	return _chain


## 当前正在运行的事件名（"" = 无）。
func current_event_name() -> String:
	return _pname


## 运行一个事件脚本：<链名>/<事件名>。**从磁盘读取**已保存的脚本。成功返回 true。
func run_event(chain: String, name: String) -> bool:
	var data: Variant = EventFile.read_script(chain, name)
	if data == null or not (data is Dictionary):
		push_warning("[EventChain] 事件不存在或解析失败：%s / %s" % [chain, name])
		return false
	_execute(chain, name, data)
	return true


## 直接用**内存里的脚本字典**运行（事件链编辑器「运行未保存内容」用）。
## 不读磁盘、不要求先保存 —— 编辑器里改了什么就跑什么，方便边改边测。
## text_override：非 null → 用它作为正文，不再按 content.text_file 去磁盘读 txt
##   （编辑器里改了正文但没保存时要用；传 "" 表示正文为空，与「不覆盖」区分开）。
## buttons_override：非 null → 用它的 {id,label} 覆盖按钮文字（同上，编辑器里刚改的那份）。
func run_dict(chain: String, name: String, data: Dictionary, text_override = null,
		buttons_override = null) -> bool:
	if data.is_empty():
		push_warning("[EventChain] 脚本为空，无法运行：%s / %s" % [chain, name])
		return false
	_execute(chain, name, data, text_override, buttons_override)
	return true


## 从系统任务表条目触发（payload 里带 chain/name）。kind 须为 event_chain。
func run_from_schedule(ev: Dictionary) -> bool:
	if str(ev.get("kind", "")) != "event_chain":
		push_warning("[EventChain] 非 event_chain 条目，跳过：%s" % str(ev.get("id", "")))
		return false
	var payload: Variant = ev.get("payload", {})
	if not (payload is Dictionary):
		push_warning("[EventChain] 条目缺少 payload（应为 {chain, name}）")
		return false
	var chain := str(payload.get("chain", ""))
	var name := str(payload.get("name", ""))
	return run_event(chain, name)


# ================= 顺序执行 =================

func _execute(chain: String, name: String, data: Dictionary, text_override = null,
		buttons_override = null) -> void:
	_chain = chain
	_pname = name
	_running = true
	# ★ 必须把本次脚本存进 _data：按钮过滤/按钮查找/按钮点击路由全靠它。
	#   之前这里漏了赋值 → _data 恒为空 → 事件面板**一个按钮都不显示**、
	#   点了按钮也永远「未找到按钮 id」（真实 bug，2026-10-03 修）。
	_data = data
	var lang := _current_lang()

	# 1) 关闭目标
	_apply_targets(data.get("close", []), false)
	# 2) 正文：**只写入内容**（标题/配图/正文/按钮），不看 panel_type 就把面板弹出来。
	#    弹不弹由 3) 的 open 列表决定（默认项 "auto" 才是"打开正文对应的对话框"）。
	var c: Dictionary = data.get("content", {})
	_open_content(c, lang, text_override, buttons_override)
	# 3) 打开目标（"auto" = 打开正文对应的对话框；老脚本缺 open 键 → 默认 ["auto"]）
	_apply_targets(EventFile.open_targets(data), true)

	print("[EventChain] 已运行事件：%s / %s（panel=%s，按钮=%d 个，打开=%s）" % [
		chain, name, str(c.get("panel_type", "")) if str(c.get("panel_type", "")) != "" else "无修改",
		_filtered.size(), str(EventFile.open_targets(data))])


# 当前语言代码（TranslationManager 不可用时按 zh_CN）
func _current_lang() -> String:
	if TranslationManager != null:
		return str(TranslationManager.current_lang)
	return "zh_CN"


# ================= 语言切换 → 重贴本地化文本 =================

func _on_language_changed(_lang: String) -> void:
	refresh_localized_text()


## 用**当前语言**的 txt 重新贴一次正文 + 按钮文字。
## ★ 只在「本次事件的面板正显示着」时动手：切语言不该把玩家已经关掉的对话框重新弹出来。
## ★ 正文与按钮文字都来自 <逻辑名>_<lang>.txt（正文 + @button 小节），所以换语言两样一起变。
## ★ 不重复记台词记录：切语言不是「又说了一句」（见 DialogueManager.begin_restate）。
func refresh_localized_text() -> void:
	if not _running or _data.is_empty():
		return
	var c: Dictionary = _data.get("content", {})
	var pt := str(c.get("panel_type", ""))
	if pt != "popup" and pt != "bottom":
		return
	if DialogueManager == null:
		return
	if pt == "bottom" and not DialogueManager.bottom_visible:
		return
	if pt == "popup" and not DialogueManager.popup_visible:
		return
	DialogueManager.begin_restate()
	_open_content(c, _current_lang(), null, null)
	DialogueManager.end_restate()
	print("[EventChain] 语言切换 → 已按 %s 重贴正文与按钮（%s / %s）" % [
		_current_lang(), _chain, _pname])


# ---- 1) / 3) 关闭 / 打开目标 ----
func _apply_targets(arr: Array, open_state: bool) -> void:
	for t in arr:
		if t is Dictionary:
			_apply_compound_target(t, open_state)
			continue
		if t is int:
			_set_block_visible(t, open_state)
			continue
		match t:
			EventFile.TARGET_AUTO:
				_auto_panel(open_state)
			"popup":
				DialogueManager.popup_visible = open_state
			"bottom":
				DialogueManager.bottom_visible = open_state
			"notification":
				if open_state:
					print("[EventChain] 脚本要求打开通知面板（无正文，忽略；请用 content.panel_type=notification）")
				else:
					NotificationManager.close_all()
			_:
				print("[EventChain] 未知目标：%s" % str(t))


# "auto" = 打开/关闭「正文对应的对话框」：开哪一个由 content.panel_type 决定。
# ★ 这是【4】打开目标的**默认项** —— 老行为（有正文就弹面板）由它保住；
#   把它删掉 = 本次事件不打开任何面板（正文照旧写进面板缓存，面板保持原样）。
func _auto_panel(on: bool) -> void:
	if DialogueManager == null:
		return
	var pt := _content_panel_type()
	match pt:
		"popup":
			DialogueManager.popup_visible = on
			print("[EventChain] open=auto → %s弹窗对话面板" % ("打开" if on else "关闭"))
		"bottom":
			DialogueManager.bottom_visible = on
			print("[EventChain] open=auto → %s底部对话面板" % ("打开" if on else "关闭"))
		"notification":
			# 通知是瞬时的：它的"打开"就是正文步骤里的 NotificationManager.show（无需重复弹），
			# 只有"关闭"需要动一下手。
			if not on and NotificationManager != null:
				NotificationManager.close_all()
			print("[EventChain] open=auto：正文是通知 → 由正文步骤直接弹出（无持久面板可显隐）")
		_:
			print("[EventChain] open=auto，但本次正文是「无修改」→ 没有对应的对话框可%s" % [
				"打开" if on else "关闭"])


# 本次事件的正文面板类型（"" = 无修改）
func _content_panel_type() -> String:
	var c: Dictionary = _data.get("content", {})
	return str(c.get("panel_type", ""))


# 复合目标（带参数）：目前只有 { "level": "<关卡名>" } = 关卡页面。
func _apply_compound_target(t: Dictionary, open_state: bool) -> void:
	if t.has("level"):
		_set_level_page(str(t.get("level", "")), open_state)
		return
	print("[EventChain] 未知复合目标（已忽略）：%s" % str(t))


# 关卡页面 开 / 关（走 LevelPage.open_level / close_level 统一入口）。
# 打开时若填了关卡名 → 先把该关卡投影到面板上再显示；名字为空 → 只显示；
# 名字填错 → 只显示 + 告警（不静默失败），详见 LevelPage.open_level。
func _set_level_page(name: String, on: bool) -> void:
	if LevelManager == null:
		push_warning("[EventChain] LevelManager 不可用，忽略关卡目标「%s」" % name)
		return
	var page: LevelPage = LevelManager.level_page as LevelPage
	if page == null or not is_instance_valid(page):
		push_warning("[EventChain] 关卡页面尚未就绪，忽略关卡目标「%s」" % name)
		return
	if on:
		page.open_level(name)
	else:
		page.close_level()
	print("[EventChain] 关卡页面 → %s%s" % [
		"打开" if on else "关闭",
		("（关卡「%s」）" % name) if not name.is_empty() else ""])


func _set_block_visible(id: int, visible: bool) -> void:
	if BlockManager == null:
		return
	var blk = BlockManager.get_block(id)
	if blk != null and is_instance_valid(blk):
		blk.visible = visible


# ---- 2) 写入正文面板内容（**不负责显隐**）----
# text_override   非 null → 用它当正文（编辑器「运行未保存内容」）
# buttons_override 非 null → 用它的 {id,label} 覆盖按钮文字（同上）
# ★ 这里**绝不**改面板显隐：只把内容写进 DialogueManager 的缓存。
#   面板弹不弹由 open 列表决定（见 _apply_targets / _auto_panel）。
func _open_content(c: Dictionary, lang: String, text_override = null,
		buttons_override = null) -> void:
	# ★ 缺省 / 空字符串 = 「无修改」：**不改动任何面板**（不打开、不覆盖正文）。
	#   早期这里缺省成 "popup"，导致「没有正文的事件」也会弹出一个空弹窗。
	var pt := str(c.get("panel_type", ""))
	_filtered = _filter_buttons(_data.get("buttons", []))
	if pt == "":
		print("[EventChain] 正文=无修改 → 不改动任何面板")
		return

	# ★★ 正文与按钮文字都从**当前语言**的 <逻辑名>_<lang>.txt 取：
	#   txt = 正文 + 若干行「@button <id> = <定义>」（见 EventFile.parse_localized）。
	#   这样按钮文字才能**随语言变**：json 里的 buttons[].label 是单份不分语言的，
	#   只作回退值（txt 里没写这个 id / txt 不存在 时用）。
	var loc: Dictionary = { "body": "", "buttons": {} }
	var raw_text: String
	if text_override != null:
		raw_text = str(text_override)
	else:
		loc = EventFile.read_localized(
			EventFile.chain_dir(_chain), str(c.get("text_file", "")), lang)
		raw_text = str(loc.get("body", ""))
	var txt_buttons: Dictionary = loc.get("buttons", {})
	var ovr: Dictionary = _buttons_override_map(buttons_override)

	var label_pairs: Array = []
	for b in _filtered:
		var bid := str(b.get("id", ""))
		# 优先级：编辑器本次覆盖 > 当前语言 txt 的 @button > json 的 label（回退）
		var ldef: String = str(txt_buttons[bid]) if txt_buttons.has(bid) else str(b.get("label", ""))
		if ovr.has(bid):
			ldef = str(ovr[bid])
		label_pairs.append({ "id": bid, "label": ldef })

	var text := _resolve_vars(raw_text)

	match pt:
		"popup":
			var title := str(c.get("title", ""))
			DialogueManager.event_name = title if title != "" else _pname
			DialogueManager.event_image_path = str(c.get("image", ""))
			DialogueManager.event_content = text
			DialogueManager.popup_buttons = label_pairs
			# ★ 不置 popup_visible：弹不弹由 open 决定（"auto" → _auto_panel）
		"bottom":
			var role := str(c.get("title", ""))
			DialogueManager.character_name = role
			DialogueManager.avatar_path = str(c.get("image", ""))
			# ★ 给「原始定义 + 已解析纯文本」两份：台词音效要按原始结构逐字发声
			#   （$变量 只响一声），显示用解析后的纯文本。
			DialogueManager.set_line_definition(raw_text, text)
			DialogueManager.bottom_buttons = label_pairs
			# 声音 content.voice：**缺省 = "auto"**（逐字/逐词泡泡声）——事件编辑器里该栏默认也是 auto；
			#   显式写 "" = 不发声；"auto:相对路径" = 逐字/逐词但换声源；相对路径 = 整段播该文件。
			DialogueManager.voice = str(c.get("voice", "auto"))
			# ★ 台词「正文效果」：点击该台词时执行（与按钮 effect 同源的 DSL 串）。
			#   编辑器「正文效果」输入框的值收集进 content.effect —— 这里取出挂到 DialogueManager。
			DialogueManager.line_effect = str(c.get("effect", ""))
			# ★ 不置 bottom_visible：弹不弹由 open 决定（"auto" → _auto_panel）
		"notification":
			# 通知是**瞬时**的：它的出现就是这一步（没有可显隐的持久面板），故照旧直接弹出。
			var persist := bool(c.get("notification_buttons", false))
			var timeout := 0.0 if persist else DEFAULT_NOTIFY_TIMEOUT
			var panel := NotificationManager.show(text, label_pairs.slice(0, 2), timeout)
			if panel != null and not panel.button_pressed.is_connected(_on_notify_button):
				panel.button_pressed.connect(_on_notify_button)
		_:
			# bubble 及其它：预留
			print("[EventChain] 面板类型 %s 尚未实现（预留），仅挂按钮上下文" % pt)


# 把「编辑器传来的按钮行数组」转成 id → label 的查表（非数组 / 空 → 空表）
func _buttons_override_map(src) -> Dictionary:
	var out: Dictionary = {}
	if not (src is Array):
		return out
	for e in src:
		if e is Dictionary:
			var k := str(e.get("id", ""))
			if not k.is_empty():
				out[k] = str(e.get("label", ""))
	return out


# ---- 4) 按钮过滤 ----
func _filter_buttons(buttons: Array) -> Array:
	var out: Array = []
	for b in buttons:
		if b is Dictionary and EventExpr.show_true(str(b.get("show", ""))):
			out.append(b)
	return out


# ================= 按钮按下路由 =================

func _on_dialogue_button(panel: String, id: String) -> void:
	if not _running:
		return
	var c: Dictionary = _data.get("content", {})
	if panel != str(c.get("panel_type", "")):
		return  # 只处理当前运行事件的主面板
	_handle_button(id)


func _on_notify_button(id: String) -> void:
	if not _running:
		return
	_handle_button(id)


func _handle_button(id: String) -> void:
	var row := _find_button(id)
	if row.is_empty():
		push_warning("[EventChain] 当前事件下未找到按钮 id = %s" % id)
		return
	_run_effect(str(row.get("effect", "")))


func _find_button(id: String) -> Dictionary:
	for b in _data.get("buttons", []):
		if b is Dictionary and str(b.get("id", "")) == id:
			return b
	return {}


# ================= 效果（统一命令语言）=================

# 按钮「效果」字段现在直接使用与控制台相同的命令语言（DSL）：
#   多条命令以 ; 分隔，每条均为 /xxx 形式，例如
#     /add_var player:score = 100; /set_var player:hp -= 10
# 直接交给 ConsoleCommand 执行，做到「控制台 / 事件链按钮 / 时间轴」三处写法完全统一。
func _run_effect(effect: String) -> void:
	var e := str(effect).strip_edges()
	if e.is_empty():
		return
	var res = ConsoleCommand.exec(e)
	# ★ 与手敲命令同路径：结果同时回写控制台 UI（ConsolePanel.log_lines）与日志 print，
	#   保证「控制台 / 事件链按钮 / 台词点击」三处写入与输出完全一致。
	ConsolePanel.log_lines(res.lines, not res.ok)
	for line in res.lines:
		print("[EventChain] ▶ 效果: " + line)
	if not res.ok:
		push_warning("[EventChain] 效果执行存在错误（见上方日志）")


# ================= 工具 =================

# 把正文里的 $变量名 替换为 GlobalVars.resolve 的结果
func _resolve_vars(text: String) -> String:
	if GlobalVars == null:
		return text
	if not str(text).contains("$"):
		return text
	var s := str(text)
	var out := ""
	var i := 0
	var n := s.length()
	while i < n:
		var c := s[i]
		if c != "$":
			out += c
			i += 1
			continue
		var j := i + 1
		while j < n and _is_ident_part(s[j]):
			j += 1
		if j > i + 1:
			var vname := s.substr(i + 1, j - i - 1)
			out += str(GlobalVars.resolve(vname))
			i = j
		else:
			out += "$"
			i += 1
	return out


func _is_ident_part(c: String) -> bool:
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_"