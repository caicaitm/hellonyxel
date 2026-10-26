# autoload/console_command.gd
# 控制台 · 统一命令解释器（class_name = ConsoleCommand）。
#
# 这是一套「控制台 / 事件链按钮效果 / 时间轴触发内容」三处共用的命令语言（DSL）。
# 设计目标：写法和语义完全统一 —— 在控制台敲的命令、事件链按钮 effect 字段、
# 时间轴 {} 触发内容，都是同一种语言，便于复用与互操作。
#
# ---- 命令（均以 / 开头，英文、程序员习惯）----
#   /create_block { <prop>=<value>, ... }     创建积木（可选 block_type="类型名" 先克隆类型，其后键覆盖）
#   /remove_block { <predicate> } [if ( <cond> )]
#                                            删除满足条件的积木；predicate 为 key=value 并列(AND)，
#                                            可再叠加 if(<cond>)；cond 内用 this/self 指代“当前被判定积木”
#   /set_var <ref> = <value>                 设置变量（覆盖）；op ∈ = += -= *= /=
#   /add_var <ref> = <value>                 新增变量/集合元素（dict 加键、array 追加元素）
#   /remove_var <ref> [= <value>]            移除变量/集合元素（有 = 是删集合元素，无 = 是删键/清空）
#   /add_tag <状态> <标签> [字段]             给状态加一条标签（条件 has_tag 判的那个）
#   /remove_tag <状态> <标签> [字段]          移除一条标签
#   /clear_tags <状态> [字段]                清空某字段的全部标签
#   /help [<cmd>]                            打印命令用法
#   /clear                                  请求清空控制台（UI 处理；解释器返回空）
#
# ---- 标识符 ----
#   允许 ASCII 字母/数字/下划线/点，**也允许非 ASCII（中文等）**：状态名 / 标签名 / 事件名
#   可以直接裸写（`/add_tag 剧情状态 得到钥匙`）；含空格的名称才必须加引号。
#
# ---- 变量引用 <ref> = A[:B[:C...]] ----
#   第一段 A 解析优先级：
#     1) 纯数字 → 该数字 id 的积木；
#     2) BlockManager 里存在的 string_id → 该积木；
#     3) 以 .json 结尾或 temp 目录下存在的文件 → JSON 文件（Dictionary/Array）；
#     4) 否则 → 全局变量（GlobalVars）。
#   后续段 B/C... 在上一层结果里导航：
#     - 积木：B = 属性名（width/height/position/string_id/tags/...），C = 集合元素下标；
#     - 文件/Dictionary：B = 键，C = 嵌套键；
#     - 集合读取用下标，写入集合元素用 /add_var /remove_var。
#   条件里 this / self 指代“当前被判定积木”（remove_block 专用）。
#
# ---- 值字面量 ----
#   数字(12 / 3.5)、字符串("..." 或 '...' )、布尔(true/false)、null、
#   Vector2  (x, y)、集合  {a, b, c}（数组/集合）、字典  {k = v, k2 = v2}（可任意嵌套）。
#
# ---- 逻辑/运算符（条件 if 内）----
#   and or not  比较 == != < > <= >= 算术 + - * /  括号 ()  成员判定 has
#   优先级：not > 比较 > and > or；算术高于比较；() 可任意嵌套。
#
# 安全：纯递归下降，无 eval；所有解析错误都转为友好报错而非崩溃。
# 依赖（全部 null-safe 调用，单测环境缺 autoload 也能编译）：
#   BlockManager / BlockTypes / GlobalVars / BlockProperty / Block / SaveManager。
class_name ConsoleCommand
extends RefCounted

const VERSION := "1.0.0"

## 命令元信息（供控制台自动补全/帮助使用）。key = 命令名（不含 /）。
## "label" = 下拉等 UI 上的显示名（简体中文原文，同时作为翻译表 key，见 data/translations.tsv）。
##   ★ 命令名（key）永远不变、永远写进 DSL；label 只用于「看得懂」的展示，
##     UI 必须把真值放 metadata，不能拿显示文本当命令用（否则一换语言就废）。
const COMMANDS: Dictionary = {
	"create_block": {
		"label": "新建积木",
		"usage": "/create_block { string_id=\"x\", block_type=\"类型名\", tags={gravity,draggable}, position=(100,200), width=120, height=120 }",
		"desc": "创建一块积木。block_type 先克隆已登记类型，其后键覆盖它；重复键以最后为准；无 position 时落在桌面中心附近。",
	},
	"remove_block": {
		"label": "删除积木",
		"usage": "/remove_block if ( this:tags has \"gravity\" and this:width > 100 )   或   /remove_block { string_id=\"x\" }",
		"desc": "删除满足条件的积木。{k=v,...}为并列相等判定；可叠加 if(<cond>)；条件里 this/self 指代当前积木。",
	},
	"set_var": {
		"label": "设置变量",
		"usage": "/set_var <ref> = <value>     例：/set_var 123:width = 80    /set_var this:position += (50,0)    /set_var player.json:age = 18",
		"desc": "设置变量（覆盖或 += -= *= /= 运算）。ref 见上方变量引用规则。",
	},
	"add_var": {
		"label": "新增变量",
		"usage": "/add_var <ref> = <value>     例：/add_var 123:tags = \"flag\"    /add_var player.json:score = 100",
		"desc": "新增变量/集合元素：Dictionary 加键，Array/Packed*Array 追加元素。",
	},
	"remove_var": {
		"label": "移除变量",
		"usage": "/remove_var <ref> [= <value>]     例：/remove_var 123:tags = \"flag\"    /remove_var player.json:score",
		"desc": "移除变量/集合元素。带 = 删集合中的某个元素；不带 = 删键/清空（全局变量置 null）。",
	},
	"help": {
		"label": "帮助",
		"usage": "/help [<cmd>]",
		"desc": "打印全部命令或某条命令的用法。",
	},
	"clear": {
		"label": "清空输出",
		"usage": "/clear",
		"desc": "清空控制台输出（仅 UI 生效）。",
	},
	"load_level": {
		"label": "加载关卡",
		"usage": "/load_level \"测试1\"",
		"desc": "按关卡名把该关卡投影到关卡面板（关卡用 JSON 存于 levels/，中文名请加引号）。",
	},
	"open_home": {
		"label": "打开家园",
		"usage": "/open_home",
		"desc": "打开家园面板（家园积木随存档落盘进 Saves/<存档>/home.json，无需关卡名）。",
	},
	"close_home": {
		"label": "关闭家园",
		"usage": "/close_home",
		"desc": "关闭家园面板（不丢数据，下次打开或读档时还原）。",
	},
	"perf": {
		"label": "性能自测量",
		"usage": "/perf [on|off|snapshot]",
		"desc": "自测量面板：省略参数=切换开关；on/off=打开/关闭；snapshot=导出一次性能快照 JSON 到 任务缓存/perf_snapshots/。",
	},
	"play_event": {
		"label": "播放事件",
		"usage": "/play_event <事件名>      或   /play_event <事件链> <事件名>      或   /play_event { chain=\"auto\", name=\"事件名\" }",
		"desc": "运行一个事件链事件。省略事件链（或写 auto）= 用「当前正在运行的事件链」；事件名可加引号（中文名建议加）。",
	},
	"add_timeline": {
		"label": "添加到时间轴",
		"usage": "/add_timeline { after=\"10m\", effect=\"/set_var a = 1\", event=\"链/事件名\", tag=\"笔记\", ignore=1, delay=30 }",
		"desc": "把一条**预定在未来执行**的命令写进时间轴（立即落盘，不等待任何确认；时间到了由时间轴自己触发）。after = 相对时间（\"90s\"/\"10m\"/\"2h\"/\"1d\"，可拼 \"1h30m\"；纯数字=秒；不加引号的纯数字也可）；time = 绝对时刻（\"2026.10.11.20:00\" / \"…:00\"，本地时间）；二者给其一即可。effect = 时间轴效果（要执行的命令，以 / 开头）；event = 触发事件（「事件链/事件名」）；两者可同时给 → 同一预计时刻写两条，**先效果后事件**。可选属性：tag / ignore / delay / max_skip（与计划文件里的属性同名同义）。",
	},
	"add_tag": {
		"label": "添加状态标签",
		"usage": "/add_tag 剧情状态 得到钥匙 tags      或   /add_tag { state=\"剧情状态\", field=\"tags\", tag=\"得到钥匙\" }",
		"desc": "给某个**已注册状态**的「字符串数组」字段加一条标签 —— 条件里的 has_tag(\"状态\",\"标签\") 判的就是它。field 省略时：该状态只有一个标签字段就自动用它，多个则报错要求写明；顶层还没有标签字段时新建 tags。",
	},
	"remove_tag": {
		"label": "移除状态标签",
		"usage": "/remove_tag 剧情状态 得到钥匙 tags",
		"desc": "从某个已注册状态移除一条标签（本来就没有 = 成功，不算错误）。参数与 /add_tag 完全一致。",
	},
	"clear_tags": {
		"label": "清空状态标签",
		"usage": "/clear_tags 荧惑日常状态 mood      或   /clear_tags { state=\"剧情状态\", field=\"tags\" }",
		"desc": "清空某个已注册状态某个标签字段的全部标签。field 的自动规则同 /add_tag（多候选时必须写明，避免误清）。",
	},
}


# ================= 对外入口 =================

## 执行一段命令文本（可含多行；行内 ; 分隔多条，遵守引号/括号嵌套）。
## 返回 ExecResult{ ok, lines:Array[String], clear_requested }。
static func exec(input: String) -> ExecResult:
	var res := ExecResult.new()
	var lines := input.split("\n", false)
	for raw in lines:
		for cmd in _split_commands(raw):
			_exec_one(cmd, res)
	return res


## 命令名列表（升序），供自动补全。
static func command_names() -> Array[String]:
	var out: Array[String] = []
	for k in COMMANDS:
		out.append(str(k))
	out.sort()
	return out


## 某条命令的 UI 显示名（简体中文原文，同时是 data/translations.tsv 的翻译 key）。
## ★ 只用于「显示」：写进 DSL 的永远是命令名本身；UI 侧请把命令名存进 item metadata，
##   不要拿显示文本当命令用（否则一换语言就找不到命令）。
static func command_label(name: String) -> String:
	if COMMANDS.has(name):
		return str((COMMANDS[name] as Dictionary).get("label", name))
	return name


## 按前缀匹配命令名（含 / 前缀的可选传入）。
static func match_commands(prefix: String) -> Array[String]:
	var p := prefix.strip_edges()
	var out: Array[String] = []
	for name in command_names():
		if p == "" or name.begins_with(p):
			out.append(name)
	return out


# ================= 执行结果 =================
class ExecResult:
	var ok: bool = true
	var lines: Array[String] = []
	var clear_requested: bool = false

	func add(text: String, is_error: bool = false) -> void:
		lines.append(text)
		if is_error:
			ok = false

	func out(text: String) -> void:
		add(text, false)

	func err(text: String) -> void:
		add(text, true)


# ================= 命令分派 =================

static func _exec_one(line: String, res: ExecResult) -> void:
	var tk := _Tok.new()
	tk.text = line
	if not tk.parse():
		res.err("[Console] 语法错误：%s" % tk.get_err())
		return
	if tk.done():
		return
	if tk.cur().type != _Tok.T_SLASH:
		res.err("[Console] 未知输入「%s」：命令须以 / 开头（如 /help）" % line.strip_edges())
		return
	tk.advance()
	if tk.done() or tk.cur().type != _Tok.T_IDENT:
		res.err("[Console] 缺少命令名（/ 之后应为命令，如 create_block）")
		return
	var cmd: String = str(tk.cur().strv)
	tk.advance()
	match cmd:
		"create_block":
			_create_block(tk, res)
		"remove_block":
			_remove_block(tk, res)
		"set_var":
			_set_var(tk, res, false)
		"add_var":
			_add_var(tk, res)
		"remove_var":
			_remove_var(tk, res)
		"help":
			_help(tk, res)
		"clear":
			res.clear_requested = true
		"load_level":
			_load_level(tk, res)
		"gen_level_group":
			_gen_level_group(tk, res)
		"open_home":
			_open_home(tk, res)
		"close_home":
			_close_home(tk, res)
		"perf":
			_perf(tk, res)
		"play_event":
			_play_event(tk, res)
		"add_timeline":
			_add_timeline(tk, res)
		"add_tag":
			_tag_cmd(tk, res, "add")
		"remove_tag":
			_tag_cmd(tk, res, "remove")
		"clear_tags":
			_tag_cmd(tk, res, "clear")
		_:
			res.err("[Console] 未知命令：/%s（输入 /help 查看可用命令）" % cmd)


# ================= /create_block =================

static func _create_block(tk: _Tok, res: ExecResult) -> void:
	var bag: Dictionary = {}
	if not tk.done() and tk.cur().type == _Tok.T_LBRACE:
		bag = _parse_bag(tk, res)
		if res.ok == false:
			return
	# 校验是否还残留意外 token
	if not tk.done():
		res.err("[Console] /create_block 多余内容：%s" % tk.rest_text())
		return
	var type_name: String = ""
	if bag.has("block_type"):
		type_name = str(bag["block_type"]).strip_edges()
		bag.erase("block_type")
	var blk = null
	if type_name != "":
		if BlockTypes != null and BlockTypes.has_method("create_block"):
			blk = BlockTypes.create_block(type_name)
		if blk == null:
			res.err("[Console] /create_block 失败：未找到积木类型「%s」" % type_name)
			return
	else:
		# 未指定 block_type = 空白积木：走 BlockTypes 的 Blank 模板（res://block_types/Blank.json）
		if BlockTypes != null and BlockTypes.has_method("create_blank_block"):
			blk = BlockTypes.create_blank_block()
		if blk == null:
			blk = Block.new()
	if blk == null:
		res.err("[Console] /create_block 失败：无法实例化积木")
		return
	# 位置
	var pos := Vector2(200, 200)
	var pos_specified := false
	if bag.has("position"):
		var pv = bag["position"]
		if pv is Vector2:
			pos = pv
			pos_specified = true
		bag.erase("position")
	var world = _world_node()
	if world != null:
		# 空白类型（未指定 block_type）且未显式给 position → 放在屏幕中央，
		# 与右键空白处「新建积木(空白)」一致：都走 BlockTypes 的 Blank 模板。
		if type_name == "" and not pos_specified:
			var vpr: Rect2 = world.get_viewport().get_visible_rect()
			pos = vpr.position + vpr.size * 0.5
		blk.position = pos
		world.add_child(blk)
	else:
		res.err("[Console] /create_block 失败：找不到桌面世界节点（current_scene）")
		return
	# 应用其余属性（重复键以最后为准已由 Dictionary 保证）
	if not bag.is_empty():
		BlockProperty.apply_to_block(blk, bag)
	var label := ""
	if blk.has_method("get") and blk.get("string_id") != null and str(blk.get("string_id")) != "":
		label = " string_id=%s" % str(blk.get("string_id"))
	res.out("[Console] ✓ 已创建积木 id=%d%s（类型=%s）" % [int(blk.get("id")), label, type_name if type_name != "" else "<空白>"])


# ================= /remove_block =================

static func _remove_block(tk: _Tok, res: ExecResult) -> void:
	var preds: Dictionary = {}
	var cond_src := ""
	if not tk.done() and tk.cur().type == _Tok.T_LBRACE:
		preds = _parse_bag(tk, res)
		if res.ok == false:
			return
	if not tk.done() and str(tk.cur().strv).to_lower() == "if":
		tk.advance()
		if tk.done() or tk.cur().type != _Tok.T_LPAREN:
			res.err("[Console] /remove_block if 之后需要 ( <条件> )")
			return
		tk.advance()
		var depth := 1
		var start := tk.pos
		while not tk.done() and depth > 0:
			var t = tk.cur()
			if t.type == _Tok.T_LPAREN:
				depth += 1
			elif t.type == _Tok.T_RPAREN:
				depth -= 1
				if depth == 0:
					break
			tk.advance()
		if depth != 0:
			res.err("[Console] /remove_block if 条件括号未闭合")
			return
		var end := tk.pos
		# 取括号之间的源码字符串重新解析（逐积木求值）
		cond_src = tk.text.substr(_char_of_token(tk, start), _char_of_token(tk, end) - _char_of_token(tk, start)).strip_edges()
		# 跳过右括号
		tk.advance()
	if not tk.done():
		res.err("[Console] /remove_block 多余内容：%s" % tk.rest_text())
		return
	if preds.is_empty() and cond_src == "":
		res.err("[Console] /remove_block 需要 {predicates} 或 if (cond)，否则会误删全部积木")
		return
	# 遍历注册表逐个判定
	var removed := 0
	if BlockManager == null:
		res.err("[Console] /remove_block 失败：BlockManager 不可用")
		return
	var ids: Array[int] = BlockManager.get_all_ids()
	for id in ids:
		var b = BlockManager.get_block(id)
		if b == null or not is_instance_valid(b):
			continue
		var matched := true
		for key in preds:
			if not _match_pred(b, str(key), preds[key]):
				matched = false
				break
		if matched and cond_src != "":
			matched = _eval_condition(cond_src, b)
		if matched:
			BlockManager.unregister(b)
			b.queue_free()
			removed += 1
	res.out("[Console] ✓ 已删除 %d 块积木（共扫描 %d 块）" % [removed, ids.size()])


static func _match_pred(b, key: String, val) -> bool:
	if b == null or not (b is Block):
		return false
	match key:
		"id":
			return int(b.get("id")) == int(val)
		"string_id":
			return str(b.get("string_id")) == str(val)
		"tags":
			if val is Array or val is PackedStringArray:
				for t in val:
					if not (b.get("tags") is PackedStringArray and (b.get("tags") as PackedStringArray).has(str(t))):
						return false
				return true
			return str(b.get("tags")) == str(val)
		"position":
			if val is Vector2 and b.get("position") is Vector2:
				return (b.get("position") as Vector2).is_equal_approx(val)
			return false
		_:
			var cur = b.get(key)
			return _eq(cur, val)


# ================= /load_level =================

static func _load_level(tk: _Tok, res: ExecResult) -> void:
	if tk.done() or (tk.cur().type != _Tok.T_STR and tk.cur().type != _Tok.T_IDENT):
		res.err("[Console] /load_level 需要关卡名（中文名请加引号，如 /load_level \"测试1\"）")
		return
	var name: String = str(tk.cur().strv)
	tk.advance()
	if not tk.done():
		res.err("[Console] /load_level 多余内容：%s" % tk.rest_text())
		return
	if LevelManager == null:
		res.err("[Console] /load_level 失败：LevelManager 不可用")
		return
	if not LevelManager.has_level(name):
		res.err("[Console] /load_level 失败：未找到关卡「%s」（可用：%s）" % [name, str(LevelManager.list_level_names())])
		return
	var page = LevelManager.level_page
	if page == null or not is_instance_valid(page) or not page.has_method("project_level"):
		res.err("[Console] /load_level 失败：关卡面板未就绪")
		return
	var data := LevelManager.load_level(name)
	var display: String = str(data.get("name", name))
	if page.project_level(display):
		var count: int = 0
		if page.get("_level_blocks") is Array:
			count = (page.get("_level_blocks") as Array).size()
		res.out("[Console] ✓ 已投影关卡「%s」到关卡面板（积木=%d）" % [display, count])
	else:
		res.err("[Console] /load_level 失败：关卡「%s」投影失败" % display)


# ================= /gen_level_group =================
# 随机生成关卡组并投影到关卡页面：
#   /gen_level_group <组名> <种子> [trap=N reward=N normal=N challenge=N] [total=N]
# 组名含中文请加引号（如 /gen_level_group "测试组" 123 trap=2 normal=3）。
# 入口关卡/出口关卡各固定 1 个，中间关卡按各类型数量（或 total 随机补足）由种子抽取。

static func _gen_level_group(tk: _Tok, res: ExecResult) -> void:
	if tk.done() or (tk.cur().type != _Tok.T_STR and tk.cur().type != _Tok.T_IDENT):
		res.err("[Console] /gen_level_group 需要：组名 种子 [trap=N reward=N normal=N challenge=N] [total=N]")
		return
	var group_name: String = str(tk.cur().strv)
	tk.advance()
	if tk.done():
		res.err("[Console] /gen_level_group 需要种子（整数）")
		return
	var seed_raw: String = str(tk.cur().strv)
	tk.advance()
	var seed_value: int = 0
	if seed_raw.is_valid_int():
		seed_value = seed_raw.to_int()
	else:
		seed_value = seed_raw.hash()
	var counts := {}
	var total := -1
	while not tk.done():
		var key_tok = tk.cur()
		if key_tok.type != _Tok.T_IDENT:
			res.err("[Console] /gen_level_group 参数须为 key=value：%s" % str(key_tok.strv))
			return
		var key: String = str(key_tok.strv)
		tk.advance()
		if tk.done() or tk.cur().type != _Tok.T_OP or str(tk.cur().strv) != "=":
			res.err("[Console] /gen_level_group 参数「%s」缺少 =值" % key)
			return
		tk.advance()  # 跳过 =
		if tk.done():
			res.err("[Console] /gen_level_group 参数「%s」缺少值" % key)
			return
		var val: String = str(tk.cur().strv)
		tk.advance()
		if key == "total":
			if not val.is_valid_int():
				res.err("[Console] /gen_level_group total 须为整数：%s" % val)
				return
			total = val.to_int()
		elif key in ["trap", "reward", "normal", "challenge"]:
			if not val.is_valid_int():
				res.err("[Console] /gen_level_group %s 须为整数：%s" % [key, val])
				return
			counts[key] = val.to_int()
		else:
			res.err("[Console] /gen_level_group 未知参数：%s（可用 trap/reward/normal/challenge/total）" % key)
			return
	if LevelGroupGenerator == null:
		res.err("[Console] /gen_level_group 失败：LevelGroupGenerator 不可用")
		return
	var cfg := {"group_name": group_name, "seed": seed_value, "counts": counts, "total": total}
	var merged := LevelGroupGenerator.generate(cfg)
	if merged.is_empty():
		res.err("[Console] /gen_level_group 失败：关卡池不足（需要 entrance_level 入口关卡、exit_level 出口关卡，以及各类型关卡）")
		return
	var page = LevelManager.level_page if LevelManager != null else null
	if page == null or not is_instance_valid(page) or not page.has_method("project_data"):
		res.err("[Console] /gen_level_group 失败：关卡面板未就绪")
		return
	if page.project_data(merged):
		var seq: Array = merged.get("_sequence_types", [])
		var n: int = merged.get("blocks", []).size()
		res.out("[Console] ✓ 已生成关卡组「%s」（种子=%d） 关卡顺序=%s 合并积木=%d" % [group_name, seed_value, str(seq), n])
	else:
		res.err("[Console] /gen_level_group 失败：投影失败")


# ================= /open_home / /close_home =================

static func _open_home(tk: _Tok, res: ExecResult) -> void:
	if not tk.done():
		res.err("[Console] /open_home 不接受参数：%s" % tk.rest_text())
		return
	if HomeManager == null:
		res.err("[Console] /open_home 失败：HomeManager 不可用")
		return
	var page = HomeManager.home_page
	if page == null or not is_instance_valid(page) or not page.has_method("open_home"):
		res.err("[Console] /open_home 失败：家园面板未就绪")
		return
	if page.open_home():
		res.out("[Console] ✓ 已打开家园面板")
	else:
		res.err("[Console] /open_home 失败：家园投影失败")


static func _close_home(tk: _Tok, res: ExecResult) -> void:
	if not tk.done():
		res.err("[Console] /close_home 不接受参数：%s" % tk.rest_text())
		return
	if HomeManager == null:
		res.err("[Console] /close_home 失败：HomeManager 不可用")
		return
	var page = HomeManager.home_page
	if page == null or not is_instance_valid(page) or not page.has_method("close_home"):
		res.err("[Console] /close_home 失败：家园面板未就绪")
		return
	page.close_home()
	res.out("[Console] ✓ 已关闭家园面板")


# ================= /perf =================
# 自测量面板（批次 1）的统一入口：toggle / on / off / snapshot。
# 面板关闭时所有计时闸门为 false → 零开销（详见 ui/self_profile_panel.gd）。
static func _perf(tk: _Tok, res: ExecResult) -> void:
	if Debug == null or not Debug.has_method("is_self_profile_open"):
		res.err("[Console] /perf 失败：Debug 单例不可用")
		return
	var sub := ""
	if not tk.done():
		if tk.cur().type != _Tok.T_STR and tk.cur().type != _Tok.T_IDENT:
			res.err("[Console] /perf 参数只能是 on / off / snapshot（或省略=切换开关）")
			return
		sub = str(tk.cur().strv).strip_edges().to_lower()
		tk.advance()
	if not tk.done():
		res.err("[Console] /perf 多余内容：%s" % tk.rest_text())
		return
	match sub:
		"", "toggle":
			Debug.set_self_profile_open(not Debug.is_self_profile_open())
			res.out("[Console] 自测量面板: %s" % ("已打开（开始计时）" if Debug.is_self_profile_open() else "已关闭（计时已停）"))
		"on":
			Debug.set_self_profile_open(true)
			res.out("[Console] 自测量面板已打开（开始计时）")
		"off":
			Debug.set_self_profile_open(false)
			res.out("[Console] 自测量面板已关闭（计时已停）")
		"snapshot":
			# ★ 面板没开时 export 会顺带打开（否则快照里没有 span/进程树）
			var was_open: bool = Debug.is_self_profile_open()
			var p: String = Debug.export_self_profile_snapshot()
			if p.is_empty():
				res.err("[Console] /perf snapshot 失败：无法落盘（见面板状态行）")
			else:
				res.out("[Console] ✓ 快照已导出：%s" % p)
				if not was_open:
					res.out("[Console] 提示：面板刚打开，子系统耗时需累计 60 帧才有值；再执行一次 /perf snapshot 可得完整快照")
		_:
			res.err("[Console] /perf 参数只能是 on / off / snapshot（或省略=切换开关）")


# ================= /play_event =================
# 运行一个事件链事件。三种写法：
#   /play_event <事件名>                        → 事件链 = auto（当前正在运行的事件链）
#   /play_event <事件链> <事件名>                → 指定事件链
#   /play_event { chain="auto", name="事件名" } → bag 形式（chain 可省略 = auto）
# ★ 「auto / 不写」= 用 EventChainRunner.current_chain()（同事件链）——用于「按钮/台词效果里
#   播放本链的另一个事件」这种自引用场景，无需把链名写死。
static func _play_event(tk: _Tok, res: ExecResult) -> void:
	if EventChainRunner == null or not EventChainRunner.has_method("run_event"):
		res.err("[Console] /play_event 失败：EventChainRunner 不可用")
		return

	var chain := ""
	var name := ""

	if not tk.done() and tk.cur().type == _Tok.T_LBRACE:
		# bag 形式
		var bag: Dictionary = _parse_bag(tk, res)
		if res.ok == false:
			return
		if not tk.done():
			res.err("[Console] /play_event 多余内容：%s" % tk.rest_text())
			return
		chain = str(bag.get("chain", "")).strip_edges()
		name = str(bag.get("name", bag.get("event", ""))).strip_edges()
	else:
		# 位置参数：1 个 = 事件名（链=auto）；2 个 = 链 + 事件名
		var args: Array[String] = []
		while not tk.done():
			var t: Variant = tk.cur()
			if t.type == _Tok.T_STR or t.type == _Tok.T_IDENT or t.type == _Tok.T_NUM:
				args.append(str(t.strv))
				tk.advance()
			else:
				break
		if not tk.done():
			res.err("[Console] /play_event 参数应为事件名（可加引号）：多余内容 %s" % tk.rest_text())
			return
		if args.size() == 1:
			name = args[0].strip_edges()
		elif args.size() == 2:
			chain = args[0].strip_edges()
			name = args[1].strip_edges()
		elif args.size() >= 3:
			res.err("[Console] /play_event 用法：/play_event <事件名> 或 /play_event <事件链> <事件名>")
			return
		# args.size() == 0 → chain/name 保持 ""，落到下方的「缺少事件名」拦截

	# 「auto」/ 空 → 用当前正在运行的事件链
	if chain == "" or chain.to_lower() == "auto":
		var cur := ""
		if EventChainRunner.has_method("current_chain"):
			cur = str(EventChainRunner.current_chain())
		if cur.is_empty():
			res.err("[Console] /play_event 未指定事件链，且当前不在任何事件链上下文中（无法用 auto）")
			return
		chain = cur

	if name.is_empty():
		res.err("[Console] /play_event 缺少事件名")
		return

	if EventChainRunner.run_event(chain, name):
		res.out("[Console] ✓ 已播放事件：%s / %s" % [chain, name])
	else:
		res.err("[Console] /play_event 失败：事件「%s / %s」不存在或解析失败" % [chain, name])


# ================= /add_timeline =================
# ★★ 语义要点（批次 94）：
#   时间轴本质是「定时（段）执行命令」的**计划表**，所以这个命令是「**提前生效**」的：
#   立刻把一条待执行命令写进 timeline.txt 并落盘，不进入任何「待确认」状态；
#   到点后由 TimelineManager 自己检查并触发。控制台只负责「预定」。
#   ★ effect 与 event 可以同时给 → 写**两条同刻记录**，靠写入顺序（seq）保证「先效果后事件」。

## 可透传为计划文件 props 的键（与 timeline_manager 的属性同名同义）。
const TIMELINE_PROP_KEYS: Array = ["tag", "ignore", "delay", "max_skip"]

static func _add_timeline(tk: _Tok, res: ExecResult) -> void:
	if TimelineManager == null or not TimelineManager.has_method("append_event"):
		res.err("[Console] /add_timeline 失败：TimelineManager 不可用")
		return
	if tk.done() or tk.cur().type != _Tok.T_LBRACE:
		res.err("[Console] /add_timeline 用法：/add_timeline { after=\"10m\", effect=\"/set_var a = 1\", event=\"链/事件名\" }")
		return
	var bag: Dictionary = _parse_bag(tk, res)
	if res.ok == false:
		return
	if not tk.done():
		res.err("[Console] /add_timeline 多余内容：%s" % tk.rest_text())
		return

	var after_raw := str(bag.get("after", "")).strip_edges()
	var time_raw := str(bag.get("time", bag.get("at", ""))).strip_edges()
	var effect := str(bag.get("effect", bag.get("what", ""))).strip_edges()
	var ev := str(bag.get("event", "")).strip_edges()

	if after_raw.is_empty() and time_raw.is_empty():
		res.err("[Console] /add_timeline 缺少预计时间：after=\"10m\"（相对）或 time=\"2026.10.11.20:00\"（绝对）")
		return
	# ★ 两个都给 → 明确报错（旧写法会静默丢掉 time，用户以为生效了）
	if not after_raw.is_empty() and not time_raw.is_empty():
		res.err("[Console] /add_timeline 的 after 与 time 只能给一个：after=\"10m\"（相对）或 time=\"2026.10.11.20:00\"（绝对）")
		return
	if effect.is_empty() and ev.is_empty():
		res.err("[Console] /add_timeline 缺少内容：effect=\"<命令>\"（时间轴效果）或 event=\"链/事件名\"（触发事件）")
		return
	# 事件名必须带链（计划文件的 event: 前缀靠「链/事件」切分）
	if not ev.is_empty() and not ev.contains("/"):
		res.err("[Console] /add_timeline 的 event 须写成「事件链/事件名」，实际：%s" % ev)
		return

	# 计划属性：白名单透传；**不认识的键直接报错**（避免静默丢掉配置）
	var props: Dictionary = {}
	for k in TIMELINE_PROP_KEYS:
		if bag.has(k):
			props[k] = _prop_str(bag[k])
	for k in bag:
		var ks := str(k)
		if ks == "after" or ks == "time" or ks == "at" or ks == "effect" or ks == "what" or ks == "event":
			continue
		if props.has(ks):
			continue
		res.err("[Console] /add_timeline 不认识的属性「%s」（可用：after/time/effect/event/tag/ignore/delay/max_skip）" % ks)
		return

	# 预计时刻：相对 → 换算成绝对；绝对 → 原样交给 append_event 校验
	var time_str := time_raw
	if not after_raw.is_empty():
		var sec := _parse_duration(after_raw)
		if sec < 0.0:
			res.err("[Console] /add_timeline 的 after 格式不正确：%s（支持 \"90s\"/\"10m\"/\"2h\"/\"1d\"，可拼 \"1h30m\"；纯数字=秒）" % after_raw)
			return
		time_str = str(TimelineManager.format_time(TimelineManager.unix_now() + sec))

	# 写入（效果在前、事件在后 → 同刻保序；seq 由时间轴自增分配）
	var count := 0
	if not effect.is_empty():
		if not bool(TimelineManager.append_event(time_str, props, effect)):
			res.err("[Console] /add_timeline 写入失败：时间格式不正确 %s" % time_str)
			return
		res.out("[Console] ✓ 已加入时间轴（预计时间 %s）· 效果：%s" % [time_str, effect])
		count += 1
	if not ev.is_empty():
		var content := "event:" + ev
		if not bool(TimelineManager.append_event(time_str, props, content)):
			res.err("[Console] /add_timeline 写入失败：时间格式不正确 %s" % time_str)
			return
		res.out("[Console] ✓ 已加入时间轴（预计时间 %s）· 触发事件：%s" % [time_str, ev])
		count += 1
	if count == 0:
		res.err("[Console] /add_timeline 没有可写入的内容")


## 计划属性值 → 规范化字符串。
## ★ 必须做：bag 里 `ignore=1` 经 _parse_value 会变成 float 1.0，而计划文件的属性是**文本**，
##   写进去就是 "1.0" —— timeline_manager._props_true 原先只认 "1"/"true"/"yes"/"on"，
##   于是 ignore=1.0 会被判成**假**（「忽略上限」静默失效）。这里把整数数值还原成 "1"。
static func _prop_str(v: Variant) -> String:
	if v is bool:
		return "1" if bool(v) else "0"
	if v is float or v is int:
		var f := float(v)
		if is_equal_approx(f, roundf(f)) and absf(f) < 1000000000000000.0:
			return str(int(roundf(f)))
		return str(f)
	return str(v)


## 相对时长解析："90" / "90s" / "10m" / "2h" / "1d" / "1h30m"（也接受 中文 秒/分/小时/天）。
## ★ 解析失败 → -1（调用方据此报错，绝不静默当成 0 秒）。
static func _parse_duration(s: String) -> float:
	var t := s.strip_edges().to_lower()
	if t.is_empty():
		return -1.0
	var total := 0.0
	var i := 0
	var n := t.length()
	var any := false
	while i < n:
		var j := i
		while j < n and (_is_duration_digit(t[j]) or t[j] == "."):
			j += 1
		if j == i:
			return -1.0
		var num_s := t.substr(i, j - i)
		if not num_s.is_valid_float():
			return -1.0
		var val := float(num_s)
		# 单位 = 数字之后到下一个数字之前的片段
		var k := j
		while k < n and not (_is_duration_digit(t[k]) or t[k] == "."):
			k += 1
		var mult := _duration_unit(t.substr(j, k - j).strip_edges())
		if mult < 0.0:
			return -1.0
		total += val * mult
		any = true
		i = k
	if not any:
		return -1.0
	return total


static func _is_duration_digit(c: String) -> bool:
	return c >= "0" and c <= "9"


## 时长单位 → 秒；未知单位返回 -1。
static func _duration_unit(u: String) -> float:
	match u:
		"", "s", "sec", "secs", "second", "seconds":
			return 1.0
		"m", "min", "mins", "minute", "minutes":
			return 60.0
		"h", "hr", "hrs", "hour", "hours":
			return 3600.0
		"d", "day", "days":
			return 86400.0
		"秒":
			return 1.0
		"分", "分钟":
			return 60.0
		"时", "小时":
			return 3600.0
		"天", "日":
			return 86400.0
	return -1.0


# ================= /add_tag · /remove_tag · /clear_tags =================
# ★★ 语义要点（批次 96）：
#   「状态标签」= 某个**已注册状态**（StateRegistry）里某个「字符串数组」字段的一个元素。
#   条件用 has_tag("状态","标签") 判它，所以效果侧必须有能写出它的命令 ——
#   而 /set_var 的右侧**不支持数组字面量**（只能写标量/字典/集合），加标签根本表达不出来。
#   本命令直接改状态 JSON（StateRegistry 负责 owner 分流与内存同步），写完**立刻生效**：
#   EventExpr 求值时是现读文件，不需要任何广播。
#
# 三种写法：
#   /add_tag 剧情状态 得到钥匙             → 字段自动（唯一候选 → 用它；无候选 → 新建 tags）
#   /add_tag 剧情状态 得到钥匙 tags        → 显式指定字段
#   /add_tag { state="剧情状态", field="tags", tag="得到钥匙" }   → bag 写法（与其它命令一致）
#   /clear_tags 状态 [字段]                → 清空（多候选字段时必须写明，避免误清）

static func _tag_cmd(tk: _Tok, res: ExecResult, op: String) -> void:
	var cmd := "add_tag"
	if op == "remove":
		cmd = "remove_tag"
	elif op == "clear":
		cmd = "clear_tags"
	if StateRegistry == null or not StateRegistry.has_method("add_tag"):
		res.err("[Console] /%s 失败：StateRegistry 不可用" % cmd)
		return
	var a := _tag_args(tk, res, cmd, op != "clear")
	if not bool(a.get("ok", false)):
		return
	var st: String = str(a["state"]).strip_edges()
	if st.is_empty():
		res.err("[Console] /%s 缺少状态名（可用：%s）" % [cmd, ", ".join(StateRegistry.registered_friendly())])
		return
	# ★ 两种「不能用」要分开说：① 根本没注册（名字打错 / 忘了登记）
	#   ② 注册了但没开放标签（理论上不存在，留作将来加状态时的护栏）。
	#   合并成一句「不可写标签」会让人以为状态名写对了，只是不能写 —— 报错必须指向真因。
	if str(StateRegistry.file_of(st)) == "":
		res.err("[Console] /%s 失败：未注册的状态「%s」（可用：%s）" % [
			cmd, st, ", ".join(StateRegistry.registered_friendly())])
		return
	if not bool(StateRegistry.tag_writable(st)):
		res.err("[Console] /%s 失败：状态「%s」不参与状态标签（可写：%s）" % [
			cmd, st, ", ".join(StateRegistry.tag_writable_friendly())])
		return
	var tag: String = str(a["tag"]).strip_edges()
	var fld: String = str(a["field"]).strip_edges()
	var r: Dictionary = {}
	match op:
		"add":
			r = StateRegistry.add_tag(st, tag, fld)
		"remove":
			r = StateRegistry.remove_tag(st, tag, fld)
		_:
			r = StateRegistry.clear_tags(st, fld)
	if not bool(r.get("ok", false)):
		res.err("[Console] /%s 失败：%s" % [cmd, str(r.get("err", ""))])
		return
	var used: String = str(r.get("field", ""))
	var tags: Array = r.get("tags", [])
	var changed := bool(r.get("changed", false))
	match op:
		"add":
			if changed:
				res.out("[Console] ✓ 已给「%s」的 %s 加上标签「%s」（当前 %d 条：%s）" % [
					st, used, tag, tags.size(), _join_tags(tags)])
			else:
				res.out("[Console] · 标签「%s」已在「%s」的 %s 里，未改动（当前 %d 条：%s）" % [
					tag, st, used, tags.size(), _join_tags(tags)])
		"remove":
			if changed:
				res.out("[Console] ✓ 已从「%s」的 %s 移除标签「%s」（当前 %d 条：%s）" % [
					st, used, tag, tags.size(), _join_tags(tags)])
			else:
				res.out("[Console] · 「%s」的 %s 里本来就没有「%s」，未改动（当前 %d 条：%s）" % [
					st, used, tag, tags.size(), _join_tags(tags)])
		_:
			if changed:
				res.out("[Console] ✓ 已清空「%s」的 %s（当前 0 条）" % [st, used])
			else:
				res.out("[Console] · 「%s」的 %s 本来就是空的，未改动" % [st, used])


## 标签命令的参数解析：位置写法「状态 [标签] [字段]」或 bag 写法 { state=…, tag=…, field=… }。
## ★ bag 的值一律按**字面量**解析（allow_ref=false，裸词 = 字符串）——「状态名/标签/字段」都是
##   名字而不是变量；若按引用解析，`field=tags` 会跑去找同名变量并报「未知引用」。
## with_tag=false（/clear_tags）时不接受标签参数。
static func _tag_args(tk: _Tok, res: ExecResult, cmd: String, with_tag: bool) -> Dictionary:
	var out := { "state": "", "tag": "", "field": "", "ok": false }
	if not tk.done() and tk.cur().type == _Tok.T_LBRACE:
		tk.advance()   # 跳过 {
		while not tk.done() and tk.cur().type != _Tok.T_RBRACE:
			if tk.cur().type != _Tok.T_IDENT:
				res.err("[Console] /%s bag 键应为名称：%s" % [cmd, tk.rest_text()])
				return out
			var key: String = str(tk.cur().strv)
			tk.advance()
			var val: Variant = true
			if not tk.done() and tk.cur().type == _Tok.T_OP and str(tk.cur().strv) == "=":
				tk.advance()
				val = _parse_value(tk, res, false)
				if res.ok == false:
					return out
			match key:
				"state", "status":
					out["state"] = str(val)
				"tag", "value":
					out["tag"] = str(val)
				"field", "key":
					out["field"] = str(val)
				_:
					res.err("[Console] /%s 不认识的属性「%s」（可用：state / tag / field）" % [cmd, key])
					return out
			if not tk.done() and tk.cur().type == _Tok.T_COMMA:
				tk.advance()
				continue
			if not tk.done() and tk.cur().type == _Tok.T_RBRACE:
				break
			res.err("[Console] /%s bag 内缺少 , 或 }：%s" % [cmd, tk.rest_text()])
			return out
		if tk.done():
			res.err("[Console] /%s bag 未闭合 }" % cmd)
			return out
		tk.advance()   # 跳过 }
	else:
		var args: Array[String] = []
		while not tk.done():
			var t: Variant = tk.cur()
			if t.type == _Tok.T_STR or t.type == _Tok.T_IDENT or t.type == _Tok.T_NUM:
				args.append(str(t.strv))
				tk.advance()
			else:
				break
		if args.size() >= 1:
			out["state"] = args[0]
		if with_tag:
			if args.size() >= 2:
				out["tag"] = args[1]
			if args.size() >= 3:
				out["field"] = args[2]
			if args.size() > 3:
				res.err("[Console] /%s 用法：/%s <状态> <标签> [字段]" % [cmd, cmd])
				return out
		else:
			if args.size() >= 2:
				out["field"] = args[1]
			if args.size() > 2:
				res.err("[Console] /%s 用法：/%s <状态> [字段]" % [cmd, cmd])
				return out
	if not tk.done():
		res.err("[Console] /%s 多余内容：%s" % [cmd, tk.rest_text()])
		return out
	out["ok"] = true
	return out


## 标签列表 → 一行展示文本（空 → 空串）。
static func _join_tags(tags: Array) -> String:
	var parts: Array[String] = []
	for t in tags:
		parts.append(str(t))
	return ", ".join(parts)


# ================= /set_var =================

static func _set_var(tk: _Tok, res: ExecResult, _unused_add: bool) -> void:
	var ref := _parse_ref(tk, res)
	if ref == null:
		return
	if tk.done() or tk.cur().type != _Tok.T_OP or str(tk.cur().strv) not in ["=", "+=", "-=", "*=", "/="]:
		res.err("[Console] /set_var 期望赋值运算符 = += -= *= /=")
		return
	var op: String = str(tk.cur().strv)
	tk.advance()
	var rhs = _parse_rvalue(tk, res, null)
	if res.ok == false:
		return
	if not tk.done():
		res.err("[Console] /set_var 多余内容：%s" % tk.rest_text())
		return
	var cur = _read_ref(ref, res)
	if res.ok == false:
		return
	var newv
	if op == "=":
		newv = rhs
	else:
		# 剥掉赋值号只留算术运算符（+= → +）
		var base_op := op.replace("=", "")
		newv = _arith(base_op, cur, rhs)
		if newv == null:
			res.err("[Console] /set_var 运算失败：%s 与 %s 不能做 %s" % [str(cur), str(rhs), op])
			return
	_write_ref(ref, newv, res)
	if res.ok:
		res.out("[Console] ✓ %s %s %s → %s" % [ref.to_text(), op, _fmt(rhs), _fmt(newv)])


# ================= /add_var =================

static func _add_var(tk: _Tok, res: ExecResult) -> void:
	var ref := _parse_ref(tk, res)
	if ref == null:
		return
	var value = null
	if not tk.done() and tk.cur().type == _Tok.T_OP and str(tk.cur().strv) == "=":
		tk.advance()
		value = _parse_rvalue(tk, res, null)
		if res.ok == false:
			return
	if not tk.done():
		res.err("[Console] /add_var 多余内容：%s" % tk.rest_text())
		return
	if value == null:
		res.err("[Console] /add_var 需要 = <value>（新增变量/元素都要给值）")
		return
	# 按根容器类型处理：积木/文件/Dictionary/全局变量
	if ref.first == "this" or ref.first == "self":
		res.err("[Console] /add_var 不支持 this/self 根（请用 this:属性）")
		return
	if _is_block_first(ref.first):
		var b = _resolve_block(ref.first, res)
		if res.ok == false or b == null:
			return
		_add_block_prop(b, ref.tail, value, res)
	elif _is_file_first(ref.first):
		var data = _load_file(_file_path(ref.first), res)
		if res.ok == false:
			return
		if ref.tail.is_empty():
			res.err("[Console] /add_var 文件需指定键，如 player.json:score")
			return
		_write_segs(data, ref.tail, value, res)
		_save_file(_file_path(ref.first), data, res)
	elif GlobalVars != null and GlobalVars.has_method("set_var"):
		GlobalVars.set_var(ref.first, value)
	else:
		res.err("[Console] 无法识别引用根：%s" % ref.first)
	if res.ok:
		res.out("[Console] ✓ 已添加 %s = %s" % [ref.to_text(), _fmt(value)])


# ================= /remove_var =================

static func _remove_var(tk: _Tok, res: ExecResult) -> void:
	var ref := _parse_ref(tk, res)
	if ref == null:
		return
	var elem = null
	var has_elem := false
	if not tk.done() and tk.cur().type == _Tok.T_OP and str(tk.cur().strv) == "=":
		tk.advance()
		elem = _parse_rvalue(tk, res, null)
		has_elem = true
		if res.ok == false:
			return
	if not tk.done():
		res.err("[Console] /remove_var 多余内容：%s" % tk.rest_text())
		return
	var cur = _read_ref(ref, res)
	if res.ok == false:
		return
	if _is_block_first(ref.first):
		var b = _resolve_block(ref.first, res)
		if res.ok == false or b == null:
			return
		_remove_block_prop(b, ref.tail, has_elem, elem, res)
	elif _is_file_first(ref.first):
		var data = _load_file(_file_path(ref.first), res)
		if res.ok == false:
			return
		if ref.tail.is_empty():
			res.err("[Console] /remove_var 文件需指定键，如 player.json:score")
			return
		if has_elem:
			var c = _read_segs(data, ref.tail, res, null)
			var filtered = _filter_collection(c, elem, res)
			if res.ok == false:
				return
			# 删元素后集合变空 → 直接删键（更符合“移除”语义）
			if filtered is Array and filtered.is_empty():
				_erase_segs(data, ref.tail, res)
			else:
				_write_segs(data, ref.tail, filtered, res)
		else:
			_erase_segs(data, ref.tail, res)
		_save_file(_file_path(ref.first), data, res)
		if res.ok:
			res.out("[Console] ✓ 已移除 %s" % ref.to_text())
	elif GlobalVars != null and GlobalVars.has_method("set_var"):
		if has_elem:
			var c = GlobalVars.get_var(ref.first, null)
			var filtered = _filter_collection(c, elem, res)
			if res.ok == false:
				return
			GlobalVars.set_var(ref.first, filtered)
		else:
			GlobalVars.set_var(ref.first, null)
		if res.ok:
			res.out("[Console] ✓ 已移除 %s" % ref.to_text())
	else:
		res.err("[Console] 无法识别引用根：%s" % ref.first)


# ================= 积木集合增删辅助 =================

static func _add_block_prop(b, tail: Array[String], value, res: ExecResult) -> void:
	if tail.is_empty():
		res.err("[Console] /add_var 积木需指定属性，如 123:tags")
		return
	var key: String = tail[0]
	if key in ["tags", "collision_layer"]:
		var cur = b.get(key) if b.has_method("get") else null
		var psa: PackedStringArray = PackedStringArray() if cur == null else PackedStringArray(Array(cur))
		if not psa.has(str(value)):
			psa.append(str(value))
		_write_block_prop(b, [key], psa, res)
	else:
		_write_block_prop(b, tail, value, res)


static func _remove_block_prop(b, tail: Array[String], has_elem: bool, elem, res: ExecResult) -> void:
	if tail.is_empty():
		res.err("[Console] /remove_var 积木需指定属性，如 123:tags")
		return
	var key: String = tail[0]
	if key in ["tags", "collision_layer"]:
		var cur = b.get(key) if b.has_method("get") else null
		var psa: PackedStringArray = PackedStringArray() if cur == null else PackedStringArray(Array(cur))
		if has_elem:
			var idx: int = psa.find(str(elem))
			if idx >= 0:
				psa.remove_at(idx)
		else:
			psa = PackedStringArray()
		_write_block_prop(b, [key], psa, res)
	else:
		if has_elem:
			res.err("[Console] /remove_var 非集合属性不需要 = 元素")
			return
		_write_block_prop(b, tail, null, res)


static func _filter_collection(cur, elem, res: ExecResult):
	if cur is Array or cur is PackedStringArray:
		var arr = PackedStringArray() if cur is PackedStringArray else Array()
		for e in cur:
			if not _eq(e, elem):
				arr.append(e)
		return arr
	if cur is Dictionary:
		var d: Dictionary = cur.duplicate(true)
		for k in cur:
			if _eq(k, elem):
				d.erase(k)
		return d
	res.err("[Console] /remove_var = <元素> 仅支持集合/字典")
	return null


static func _erase_segs(root, segs: Array[String], res: ExecResult) -> void:
	if segs.is_empty():
		res.err("[Console] /remove_var 缺少键")
		return
	var cur = root
	for i in segs.size() - 1:
		var seg: String = segs[i]
		if cur is Dictionary:
			if not cur.has(seg):
				cur[seg] = {}
			cur = cur[seg]
		else:
			res.err("[Console] /remove_var 路径中段不可导航：%s" % seg)
			return
	if cur is Dictionary:
		cur.erase(segs.back())
	else:
		res.err("[Console] /remove_var 末端不是字典，无法按键删除")


# ================= /help =================

static func _help(tk: _Tok, res: ExecResult) -> void:
	if not tk.done() and tk.cur().type == _Tok.T_IDENT:
		var name: String = str(tk.cur().strv)
		if COMMANDS.has(name):
			var m: Dictionary = COMMANDS[name]
			res.out("命令 /%s" % name)
			res.out("  用法：%s" % str(m.get("usage", "")))
			res.out("  说明：%s" % str(m.get("desc", "")))
		else:
			res.err("[Console] 没有命令 /%s" % name)
		return
	res.out("=== 控制台命令（/help <cmd> 看详情）===")
	for name in command_names():
		var m: Dictionary = COMMANDS[name]
		res.out("  /%s  ——  %s" % [name, str(m.get("desc", ""))])


# ================= 变量引用解析 =================

# 引用表示为 { first:String, tail:Array[String] }，to_text() 还原字符串。
class _Ref:
	var first: String = ""
	var tail: Array[String] = []
	func to_text() -> String:
		var s := first
		for t in tail:
			s += ":" + t
		return s


static func _parse_ref(tk: _Tok, res: ExecResult) -> _Ref:
	# 第一段可以是 标识符 或 数字（数字 id 的积木，如 20260920203633:width）
	if tk.done() or (tk.cur().type != _Tok.T_IDENT and tk.cur().type != _Tok.T_NUM):
		res.err("[Console] 期望变量引用（如 123 / player.json / this:tags），实际 %s" % tk.rest_text())
		return null
	var r := _Ref.new()
	r.first = str(tk.cur().strv)
	tk.advance()
	while not tk.done() and tk.cur().type == _Tok.T_COLON:
		tk.advance()
		if tk.done() or tk.cur().type != _Tok.T_IDENT:
			res.err("[Console] 引用 : 之后需要名称")
			return null
		r.tail.append(str(tk.cur().strv))
		tk.advance()
	return r


# 读取整个引用的值（first 段可带 ctx_block 解析 this）。
static func _read_ref(r: _Ref, res: ExecResult, ctx_block = null) -> Variant:
	var root = _resolve_root(r.first, res, ctx_block)
	if res.ok == false:
		return null
	return _read_segs(root, r.tail, res, ctx_block)


# 写入整个引用（赋值/增删都由调用方算好最终值后传这里）。
static func _write_ref(r: _Ref, value, res: ExecResult) -> void:
	if r.first == "this" or r.first == "self":
		res.err("[Console] 不能直接写 this/self 根；请用 this:属性 形式")
		return
	# 全局变量（first 不是块/文件）
	if _is_block_first(r.first):
		var b = _resolve_block(r.first, res)
		if res.ok == false or b == null:
			return
		_write_block_prop(b, r.tail, value, res)
		return
	if _is_file_first(r.first):
		var data = _load_file(_file_path(r.first), res)
		if res.ok == false:
			return
		_write_segs(data, r.tail, value, res)
		_save_file(_file_path(r.first), data, res)
		return
	# 全局变量
	if GlobalVars != null and GlobalVars.has_method("set_var"):
		GlobalVars.set_var(r.first, value)
	else:
		res.err("[Console] 全局变量不可用，无法写入 %s" % r.first)


static func _resolve_root(first_seg: String, res: ExecResult, ctx_block = null) -> Variant:
	if first_seg == "this" or first_seg == "self":
		if ctx_block == null:
			res.err("[Console] this/self 只能在 remove_block 的 if 条件里使用")
			return null
		return ctx_block
	if _is_block_first(first_seg):
		return _resolve_block(first_seg, res)
	if _is_file_first(first_seg):
		return _load_file(_file_path(first_seg), res)
	# 全局变量
	if GlobalVars != null and GlobalVars.has_method("get_var"):
		return GlobalVars.get_var(first_seg, null)
	return null


static func _read_segs(root, segs: Array[String], res: ExecResult, ctx_block = null) -> Variant:
	var cur = root
	for seg in segs:
		if cur == null:
			return null
		if cur is Block:
			cur = cur.get(seg)
		elif cur is Dictionary:
			cur = cur.get(seg, null)
		elif cur is Array or cur is PackedStringArray:
			var idx := int(seg)
			if idx >= 0 and idx < cur.size():
				cur = cur[idx]
			else:
				return null
		else:
			res.err("[Console] 无法在 %s 里继续导航 %s" % [str(cur), seg])
			return null
	return cur


static func _write_segs(root, segs: Array[String], value, res: ExecResult) -> void:
	if segs.is_empty():
		res.err("[Console] 写入缺少导航段")
		return
	var cur = root
	for i in segs.size() - 1:
		var seg: String = segs[i]
		if cur is Dictionary:
			if not cur.has(seg):
				cur[seg] = {}
			cur = cur[seg]
		elif cur is Block:
			cur = cur.get(seg)
		else:
			res.err("[Console] 写入路径中段不可导航：%s" % seg)
			return
	var last: String = segs.back()
	if cur is Dictionary:
		cur[last] = value
	elif cur is Block:
		_write_block_prop(cur, [last], value, res)
	else:
		res.err("[Console] 无法写入 %s" % last)


# ---------- 第一段分类 ----------
static func _is_block_first(first_seg: String) -> bool:
	if first_seg.is_empty():
		return false
	if first_seg == "this" or first_seg == "self":
		return false
	if first_seg[0] >= "0" and first_seg[0] <= "9":
		return true  # 纯数字 id
	if BlockManager != null and BlockManager.has_method("get_block_by_string_id"):
		if BlockManager.get_block_by_string_id(first_seg) != null:
			return true
	return false


static func _resolve_block(first_seg: String, res: ExecResult):
	if BlockManager == null:
		res.err("[Console] BlockManager 不可用")
		return null
	if first_seg[0] >= "0" and first_seg[0] <= "9":
		return BlockManager.get_block(int(first_seg))
	return BlockManager.get_block_by_string_id(first_seg)


static func _is_file_first(first_seg: String) -> bool:
	if first_seg.ends_with(".json"):
		return true
	return FileAccess.file_exists(_file_path(first_seg))


# ---------- 积木属性写入（特殊键走 BlockManager）----------
static func _write_block_prop(b, segs: Array[String], value, res: ExecResult) -> void:
	if segs.is_empty():
		res.err("[Console] 积木属性写入缺少属性名")
		return
	var key: String = segs[0]
	if not (b is Block):
		res.err("[Console] 写入目标不是积木")
		return
	match key:
		"id":
			if BlockManager != null and BlockManager.has_method("reassign_id"):
				if not BlockManager.reassign_id(b, int(value)):
					res.err("[Console] 重设积木 id=%s 失败（可能被占用或非正数）" % str(value))
			else:
				res.err("[Console] BlockManager.reassign_id 不可用")
		"string_id":
			var sid := str(value).strip_edges()
			if BlockManager != null and BlockManager.has_method("set_string_id"):
				if sid == "":
					if BlockManager.has_method("clear_string_id"):
						BlockManager.clear_string_id(b)
				elif not BlockManager.set_string_id(b, sid):
					res.err("[Console] 设置 string_id=\"%s\" 失败（可能重复）" % sid)
			else:
				res.err("[Console] BlockManager 字符串ID接口不可用")
		"position":
			if value is Vector2:
				b.position = value
			else:
				res.err("[Console] position 需 Vector2，如 (100,200)")
		"tags", "collision_layer":
			b.set(key, PackedStringArray(Array(value)))
		_:
			b.set(key, value)
	if res.ok:
		pass


# ================= 文件（temp 目录 JSON）=================

static func _temp_dir() -> String:
	if SaveManager != null and SaveManager.has_method("get_temp_dir"):
		var d: String = SaveManager.get_temp_dir()
		if not d.is_empty():
			return d
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs.is_empty():
		docs = OS.get_environment("USERPROFILE")
	return docs.path_join("HelloNyxel/Temp")


static func _file_path(first_seg: String) -> String:
	return _temp_dir().path_join(first_seg)


static func _load_file(path: String, res: ExecResult) -> Variant:
	if not FileAccess.file_exists(path):
		# 允许“新增文件”场景：返回空 Dictionary
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		res.err("[Console] 文件打不开：%s" % path)
		return null
	var txt := f.get_as_text()
	f.close()
	var p := JSON.new()
	if p.parse(txt) != OK:
		res.err("[Console] JSON 解析失败：%s" % path)
		return null
	return p.data


static func _save_file(path: String, data: Variant, res: ExecResult) -> void:
	var dir := DirAccess.open(_temp_dir())
	if dir == null:
		# 尝试创建目录
		DirAccess.make_dir_recursive_absolute(_temp_dir())
		dir = DirAccess.open(_temp_dir())
	if dir == null:
		res.err("[Console] 无法打开 temp 目录")
		return
	var w := FileAccess.open(path, FileAccess.WRITE)
	if w == null:
		res.err("[Console] 文件写入失败：%s" % path)
		return
	w.store_string(JSON.stringify(data, "\t"))
	w.close()


# ================= 世界节点（新建积木挂这里）=================

static func _world_node():
	var ml = Engine.get_main_loop()
	if ml is SceneTree:
		var st := ml as SceneTree
		if st.current_scene != null:
			return st.current_scene
	return null


# ================= 条件求值（remove_block if）=================

static func _eval_condition(src: String, ctx_block) -> bool:
	var tk := _Tok.new()
	tk.text = src
	if not tk.parse():
		push_warning("[Console] 条件解析失败：%s" % tk.get_err())
		return false
	var v = _parse_bexpr(tk, ctx_block)
	if tk.err or not tk.done():
		return false
	return _truthy(v)


# ================= 词法器 =================
class _Tok:
	const T_NUM := 0
	const T_STR := 1
	const T_IDENT := 2
	const T_KW := 3
	const T_OP := 4
	const T_SLASH := 5
	const T_LPAREN := 6
	const T_RPAREN := 7
	const T_LBRACE := 8
	const T_RBRACE := 9
	const T_COLON := 10
	const T_COMMA := 11
	const T_SEMI := 12

	var text := ""
	var toks: Array = []
	var pos := 0
	var err := false
	var _errmsg := ""
	# 记录每个 token 在原文中的起始字符位置（供截取 if 条件源码）
	var _char_at: Array = []

	func cur() -> Variant:
		return toks[pos]

	func done() -> bool:
		return err or pos >= toks.size()

	func advance() -> void:
		if pos < toks.size():
			pos += 1

	func rest_text() -> String:
		if pos >= toks.size():
			return "<EOF>"
		var start := int(_char_at[pos])
		return text.substr(start).strip_edges()

	func get_err() -> String:
		return _errmsg

	func set_err(m: String) -> void:
		if not err:
			err = true
			_errmsg = m

	func parse() -> bool:
		pos = 0
		err = false
		_errmsg = ""
		toks.clear()
		_char_at.clear()
		var i := 0
		var n := text.length()
		while i < n:
			var c := text[i]
			if c == " " or c == "\t" or c == "\r" or c == "\n":
				i += 1
				continue
			if c == "/" and i + 1 < n and text[i + 1] == "/":
				while i < n and text[i] != "\n":
					i += 1
				continue
			if c == "/":
				_tok_char(T_SLASH, "/", i); i += 1; continue
			if c == "(":
				_tok_char(T_LPAREN, "(", i); i += 1; continue
			if c == ")":
				_tok_char(T_RPAREN, ")", i); i += 1; continue
			if c == "{":
				_tok_char(T_LBRACE, "{", i); i += 1; continue
			if c == "}":
				_tok_char(T_RBRACE, "}", i); i += 1; continue
			if c == ",":
				_tok_char(T_COMMA, ",", i); i += 1; continue
			if c == ";":
				_tok_char(T_SEMI, ";", i); i += 1; continue
			if c == ":":
				_tok_char(T_COLON, ":", i); i += 1; continue
			if _is_digit(c) or (c == "." and i + 1 < n and _is_digit(text[i + 1])):
				var j := i
				while j < n and (_is_digit(text[j]) or text[j] == "."):
					j += 1
				var ns := text.substr(i, j - i)
				if not ns.is_valid_float():
					set_err("非法数字 %s" % ns); return false
				_tok_val(T_NUM, ns, float(ns), i); i = j; continue
			if c == "'" or c == "\"":
				var quote := c
				var j := i + 1
				var sb := ""
				while j < n:
					if text[j] == quote:
						break
					if text[j] == "\\" and j + 1 < n:
						var nx := text[j + 1]
						if nx == "n": sb += "\n"
						elif nx == "t": sb += "\t"
						else: sb += nx
						j += 2; continue
					sb += text[j]; j += 1
				if j >= n:
					set_err("字符串未闭合"); return false
				_tok_val(T_STR, sb, sb, i); i = j + 1; continue
			if c == "=" or c == "<" or c == ">" or c == "!":
				var two := text.substr(i, 2)
				if two in ["==", "<=", ">=", "!="]:
					_tok_char(T_OP, two, i); i += 2; continue
				if c == "!":
					_tok_char(T_OP, "!", i); i += 1; continue
				if c == "=":
					_tok_char(T_OP, "=", i); i += 1; continue
				_tok_char(T_OP, c, i); i += 1; continue
			if c == "+" or c == "-" or c == "*" or c == "/":
				if i + 1 < n and text[i + 1] == "=":
					_tok_char(T_OP, c + "=", i); i += 2; continue
				_tok_char(T_OP, c, i); i += 1; continue
			if _is_ident_start(c):
				var j := i
				while j < n and _is_ident_part(text[j]):
					j += 1
				var word := text.substr(i, j - i)
				var lw := word.to_lower()
				if lw in ["true", "false", "null", "and", "or", "not", "has", "if"]:
					_tok_val(T_KW, lw, _kw_val(lw), i)
				else:
					_tok_val(T_IDENT, word, word, i)
				i = j; continue
			set_err("无法识别字符 %s" % c); return false
		return true

	func _tok_char(type: int, s: String, at: int) -> void:
		toks.append({ "type": type, "strv": s, "num": 0.0 })
		_char_at.append(at)

	func _tok_val(type: int, s: String, v, at: int) -> void:
		toks.append({ "type": type, "strv": s, "num": float(v) if type == T_NUM else 0.0, "val": v })
		_char_at.append(at)

	func _kw_val(kw: String):
		match kw:
			"true": return true
			"false": return false
			"null": return null
		return kw

	func _is_digit(c: String) -> bool:
		return c >= "0" and c <= "9"

	func _is_ident_start(c: String) -> bool:
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_":
			return true
		# ★ 批次 96：非 ASCII（中文 / 日文…）也允许作标识符。
		#   在此之前，含中文的裸词一律整行报「无法识别字符 X」——状态名 / 标签名 / 事件名
		#   大多含中文，于是「忘了加引号」变成一整类无谓的报错。
		#   ★ 纯增量：旧写法必须加引号才能工作（不加就报错），故不存在被改变的既有行为。
		return c.unicode_at(0) > 127

	func _is_ident_part(c: String) -> bool:
		return _is_ident_start(c) or (c >= "0" and c <= "9") or c == "."


# ================= 解析：bag / ref / rvalue / bexpr =================

# 解析 { k=v, k={a,b}, ... }；k=v 缺省值时按“存在即 true”的标签处理。
static func _parse_bag(tk: _Tok, res: ExecResult) -> Dictionary:
	tk.advance()  # 跳过 {
	var out: Dictionary = {}
	while not tk.done() and tk.cur().type != _Tok.T_RBRACE:
		if tk.cur().type != _Tok.T_IDENT:
			res.err("[Console] bag 键应为名称，实际 %s" % tk.rest_text())
			return {}
		var key: String = str(tk.cur().strv)
		tk.advance()
		if not tk.done() and tk.cur().type == _Tok.T_OP and str(tk.cur().strv) == "=":
			tk.advance()
			var v = _parse_value(tk, res)
			if res.ok == false:
				return {}
			out[key] = v
		else:
			# 无值 → 视为标签存在（true）
			out[key] = true
		if not tk.done() and tk.cur().type == _Tok.T_COMMA:
			tk.advance()
			continue
		if not tk.done() and tk.cur().type == _Tok.T_RBRACE:
			break
		res.err("[Console] bag 内缺少 , 或 }：%s" % tk.rest_text())
		return {}
	if tk.done():
		res.err("[Console] bag 未闭合 }")
		return {}
	tk.advance()  # 跳过 }
	return out


# 解析一个“值”：字面量 / 向量 / 集合 / 引用。
# allow_ref=false 时，裸词标识符当作字符串（用于集合/标签字面量，避免被误读成变量引用）。
static func _parse_value(tk: _Tok, res: ExecResult, allow_ref := true) -> Variant:
	if tk.done():
		res.err("[Console] 期望值"); return null
	var t = tk.cur()
	# 一元负号 / 正号（负数 / 向量负分量，如 facing = -1、( -10, -20 )）
	if t.type == _Tok.T_OP and str(t.strv) == "-":
		tk.advance()
		var nv = _parse_value(tk, res)
		if _is_num(nv):
			return -float(nv)
		res.err("[Console] 一元负号只能用于数值"); return null
	if t.type == _Tok.T_OP and str(t.strv) == "+":
		tk.advance()
		return _parse_value(tk, res)
	if t.type == _Tok.T_NUM:
		tk.advance(); return t.num
	if t.type == _Tok.T_STR:
		tk.advance(); return t.strv
	if t.type == _Tok.T_KW:
		tk.advance(); return t.val
	if t.type == _Tok.T_LPAREN:
		# 向量 (x, y)
		tk.advance()
		var x = _parse_value(tk, res)
		if not tk.done() and tk.cur().type == _Tok.T_COMMA:
			tk.advance()
		else:
			res.err("[Console] 向量缺少 , "); return null
		var y = _parse_value(tk, res)
		if tk.done() or tk.cur().type != _Tok.T_RPAREN:
			res.err("[Console] 向量未闭合 )"); return null
		tk.advance()
		return Vector2(float(x), float(y))
	if t.type == _Tok.T_LBRACE:
		# 集合 {a, b} 或 字典 {k = v, ...}：看内部首个元素是否为 key = value
		if _is_dict_start(tk):
			return _parse_dict(tk, res)
		return _parse_set(tk, res)
	if t.type == _Tok.T_IDENT:
		if allow_ref:
			var r := _parse_ref(tk, res)
			if r == null:
				return null
			return _read_ref(r, res)
		else:
			# 裸词当字符串（集合/标签字面量）
			tk.advance()
			return t.strv
	res.err("[Console] 无法解析的值：%s" % tk.rest_text())
	return null


# 判断当前 token 是否为 { 且内部首个元素是 key = value（即字典而非集合）。
# 通过前瞻实现：跳过 { 后，若下一个 token 是 IDENT 且其后是 =，则视为字典。
static func _is_dict_start(tk: _Tok) -> bool:
	if tk.done() or tk.cur().type != _Tok.T_LBRACE:
		return false
	var save := tk.pos
	tk.advance()  # 跳过 {
	var is_dict := false
	if not tk.done() and tk.cur().type == _Tok.T_IDENT:
		tk.advance()  # 跳过 key
		if not tk.done() and tk.cur().type == _Tok.T_OP and str(tk.cur().strv) == "=":
			is_dict = true
	tk.pos = save
	return is_dict


# 解析集合 {a, b, c}（返回 Array）。元素一律按字面量解析（allow_ref=false，
# 裸词 = 字符串、引号串 = 字符串、{…} = 字典/嵌套集合），避免把标签名误读成变量引用。
static func _parse_set(tk: _Tok, res: ExecResult) -> Array:
	tk.advance()  # 跳过 {
	var arr: Array = []
	while not tk.done() and tk.cur().type != _Tok.T_RBRACE:
		arr.append(_parse_value(tk, res, false))
		if res.ok == false:
			return []
		if not tk.done() and tk.cur().type == _Tok.T_COMMA:
			tk.advance(); continue
		if not tk.done() and tk.cur().type == _Tok.T_RBRACE:
			break
		res.err("[Console] 集合内缺少 , 或 }"); return []
	if tk.done():
		res.err("[Console] 集合未闭合 }"); return []
	tk.advance()
	return arr


# 解析字典 {k = v, k2 = v2}（返回 Dictionary）。键为名称，值递归解析（允许引用/向量/嵌套集合/嵌套字典）。
static func _parse_dict(tk: _Tok, res: ExecResult) -> Dictionary:
	tk.advance()  # 跳过 {
	var out: Dictionary = {}
	while not tk.done() and tk.cur().type != _Tok.T_RBRACE:
		if tk.cur().type != _Tok.T_IDENT:
			res.err("[Console] dict 键应为名称，实际 %s" % tk.rest_text()); return {}
		var key: String = str(tk.cur().strv)
		tk.advance()
		if not tk.done() and tk.cur().type == _Tok.T_OP and str(tk.cur().strv) == "=":
			tk.advance()
			var v = _parse_value(tk, res)
			if res.ok == false:
				return {}
			out[key] = v
		else:
			res.err("[Console] dict 需要 key = value，实际 %s" % tk.rest_text()); return {}
		if not tk.done() and tk.cur().type == _Tok.T_COMMA:
			tk.advance(); continue
		if not tk.done() and tk.cur().type == _Tok.T_RBRACE:
			break
		res.err("[Console] dict 内缺少 , 或 }"); return {}
	if tk.done():
		res.err("[Console] dict 未闭合 }"); return {}
	tk.advance()
	return out


# 解析赋值 RHS（rvalue）：字面量 / 向量 / 集合 / 一元-/算术。
# 注意：RHS 裸词一律当「字符串字面量」（值/集合元素本就是字面量，如 18 / sword / (100,200)），
# 不解析成变量引用 —— 否则 /remove_var x:y = sword 会把 sword 误读成全局变量而删不掉元素。
static func _parse_rvalue(tk: _Tok, res: ExecResult, ctx_block = null) -> Variant:
	if tk.done():
		res.err("[Console] 期望赋值右侧"); return null
	var t = tk.cur()
	if t.type == _Tok.T_OP and str(t.strv) == "-":
		tk.advance()
		var v = _parse_rvalue(tk, res, ctx_block)
		if _is_num(v):
			return -float(v)
		res.err("[Console] 一元负号用于非数值"); return null
	if t.type == _Tok.T_OP and str(t.strv) == "+":
		tk.advance()
		return _parse_rvalue(tk, res, ctx_block)
	# 首个值（字面量；allow_ref=false → 裸词当字符串）
	var v = _parse_value(tk, res, false)
	if res.ok == false:
		return null
	# 链式算术
	while not tk.done() and tk.cur().type == _Tok.T_OP and str(tk.cur().strv) in ["+", "-", "*", "/"]:
		var op: String = str(tk.cur().strv)
		tk.advance()
		var r = _parse_value(tk, res, false)
		if res.ok == false:
			return null
		v = _arith(op, v, r)
		if v == null:
			res.err("[Console] 运算失败"); return null
	return v


# 布尔表达式（递归下降）。ctx_block 供 this 解析。
static func _parse_bexpr(tk: _Tok, ctx_block) -> Variant:
	var v = _parse_or(tk, ctx_block)
	return v


static func _parse_or(tk: _Tok, ctx_block) -> Variant:
	var v = _parse_and(tk, ctx_block)
	while not tk.done() and tk.cur().type == _Tok.T_KW and str(tk.cur().strv) == "or":
		tk.advance()
		var r = _parse_and(tk, ctx_block)
		v = _bool(_truthy(v) or _truthy(r))
	return v


static func _parse_and(tk: _Tok, ctx_block) -> Variant:
	var v = _parse_not(tk, ctx_block)
	while not tk.done() and tk.cur().type == _Tok.T_KW and str(tk.cur().strv) == "and":
		tk.advance()
		var r = _parse_not(tk, ctx_block)
		v = _bool(_truthy(v) and _truthy(r))
	return v


static func _parse_not(tk: _Tok, ctx_block) -> Variant:
	if not tk.done() and tk.cur().type == _Tok.T_KW and str(tk.cur().strv) == "not":
		tk.advance()
		return _bool(not _truthy(_parse_not(tk, ctx_block)))
	return _parse_cmp(tk, ctx_block)


static func _parse_cmp(tk: _Tok, ctx_block) -> Variant:
	var v = _parse_add(tk, ctx_block)
	if tk.done() or tk.err:
		return v
	if tk.cur().type == _Tok.T_OP and str(tk.cur().strv) in ["==", "!=", "<", ">", "<=", ">="]:
		var op: String = str(tk.cur().strv)
		tk.advance()
		var r = _parse_add(tk, ctx_block)
		return _compare(op, v, r)
	return v


static func _parse_add(tk: _Tok, ctx_block) -> Variant:
	var v = _parse_mul(tk, ctx_block)
	while not tk.done() and tk.cur().type == _Tok.T_OP and str(tk.cur().strv) in ["+", "-"]:
		var op: String = str(tk.cur().strv)
		tk.advance()
		var r = _parse_mul(tk, ctx_block)
		v = _arith(op, v, r)
		if v == null:
			res_err_token(tk, "算术失败")
			return null
	return v


static func _parse_mul(tk: _Tok, ctx_block) -> Variant:
	var v = _parse_unary(tk, ctx_block)
	while not tk.done() and tk.cur().type == _Tok.T_OP and str(tk.cur().strv) in ["*", "/"]:
		var op: String = str(tk.cur().strv)
		tk.advance()
		var r = _parse_unary(tk, ctx_block)
		v = _arith(op, v, r)
		if v == null:
			res_err_token(tk, "算术失败")
			return null
	return v


static func _parse_unary(tk: _Tok, ctx_block) -> Variant:
	if not tk.done() and tk.cur().type == _Tok.T_OP and str(tk.cur().strv) == "-":
		tk.advance()
		var inner = _parse_unary(tk, ctx_block)
		if _is_num(inner):
			return -float(inner)
		res_err_token(tk, "一元负号用于非数值"); return null
	if not tk.done() and tk.cur().type == _Tok.T_OP and str(tk.cur().strv) == "+":
		tk.advance()
		return _parse_unary(tk, ctx_block)
	return _parse_primary(tk, ctx_block)


static func _parse_primary(tk: _Tok, ctx_block) -> Variant:
	if tk.done():
		res_err_token(tk, "意外结束"); return null
	var t = tk.cur()
	match t.type:
		_Tok.T_NUM:
			tk.advance(); return t.num
		_Tok.T_STR:
			tk.advance(); return t.strv
		_Tok.T_KW:
			var k: String = str(t.strv)
			if k in ["true", "false", "null"]:
				tk.advance(); return t.val
			if k == "has":
				res_err_token(tk, "has 前应有集合/字典"); return null
			res_err_token(tk, "意外关键字 %s" % k); return null
		_Tok.T_LPAREN:
			tk.advance()
			var v = _parse_or(tk, ctx_block)
			if tk.done() or tk.cur().type != _Tok.T_RPAREN:
				res_err_token(tk, "缺少右括号"); return null
			tk.advance()
			return v
		_Tok.T_IDENT:
			var r := _parse_ref(tk, _noop_res())
			if r == null:
				res_err_token(tk, "引用解析失败"); return null
			# has 成员判定：ref has elem
			if not tk.done() and tk.cur().type == _Tok.T_KW and str(tk.cur().strv) == "has":
				tk.advance()
				var elem = _parse_value(tk, _noop_res())
				return _membership(_read_ref(r, _noop_res(), ctx_block), elem)
			return _read_ref(r, _noop_res(), ctx_block)
		_:
			res_err_token(tk, "无法解析"); return null


# ================= 运算/比较 =================

static func _arith(op: String, a, b):
	if a is Vector2 and b is Vector2:
		match op:
			"+": return a + b
			"-": return a - b
		return null
	if a is Vector2 and _is_num(b):
		match op:
			"*": return a * float(b)
			"/": return a / float(b)
		return null
	if _is_num(a) and _is_num(b):
		var x := float(a); var y := float(b)
		match op:
			"+": return x + y
			"-": return x - y
			"*": return x * y
			"/": return x / y if y != 0.0 else null
		return null
	return null


static func _compare(op: String, a, b) -> bool:
	match op:
		"==": return _eq(a, b)
		"!=": return not _eq(a, b)
		"<": return _less(a, b)
		">": return _less(b, a)
		"<=": return _less(a, b) or _eq(a, b)
		">=": return _less(b, a) or _eq(a, b)
	return false


static func _membership(collection, elem) -> bool:
	if collection == null:
		return false
	if collection is Dictionary:
		for k in collection:
			if _eq(k, elem):
				return true
		return false
	if collection is Array or collection is PackedStringArray:
		for e in collection:
			if _eq(e, elem):
				return true
		return false
	return false


static func _eq(a, b) -> bool:
	if _is_num(a) and _is_num(b):
		return float(a) == float(b)
	return str(a) == str(b)


static func _less(a, b) -> bool:
	if _is_num(a) and _is_num(b):
		return float(a) < float(b)
	return str(a) < str(b)


static func _is_num(v) -> bool:
	return v is float or v is int


static func _bool(v: bool) -> bool:
	return v


static func _truthy(v) -> bool:
	if v == null:
		return false
	if v is bool:
		return v
	if _is_num(v):
		return float(v) != 0.0
	if v is String:
		return not (v as String).is_empty()
	if v is Dictionary or v is Array or v is PackedStringArray:
		return (v as Array).size() > 0 if v is Array or v is PackedStringArray else (v as Dictionary).size() > 0
	return true


# ================= 小工具 =================

static func _fmt(v) -> String:
	if v == null:
		return "null"
	if v is Vector2:
		return "(%s,%s)" % [snapped(v.x, 0.001), snapped(v.y, 0.001)]
	if v is Array or v is PackedStringArray:
		var s := "["
		var first := true
		for e in v:
			if not first:
				s += ","
			s += _fmt(e); first = false
		return s + "]"
	return str(v)


static func _noop_res() -> ExecResult:
	return ExecResult.new()


static func res_err_token(tk: _Tok, m: String) -> void:
	tk.set_err(m)


# 计算 token 在原文中的字符偏移（用于截取 if 条件源码）。
static func _char_of_token(tk: _Tok, idx: int) -> int:
	if idx < 0 or idx >= tk._char_at.size():
		return tk.text.length()
	return int(tk._char_at[idx])


# 按 ; 切分命令（遵守引号/括号/花括号嵌套）。
static func _split_commands(text: String) -> Array[String]:
	var out: Array[String] = []
	var depth := 0
	var in_str := ""
	var cur := ""
	for i in text.length():
		var c := text[i]
		if in_str != "":
			cur += c
			if c == in_str:
				in_str = ""
			continue
		if c == "'" or c == "\"":
			in_str = c
			cur += c
			continue
		if c in ["(", ")", "{", "["]:
			depth += 1
			cur += c
			continue
		if c in [")", "}", "]"]:
			depth -= 1
			cur += c
			continue
		if c == ";" and depth <= 0:
			out.append(cur.strip_edges())
			cur = ""
			continue
		cur += c
	if cur.strip_edges() != "":
		out.append(cur.strip_edges())
	return out
