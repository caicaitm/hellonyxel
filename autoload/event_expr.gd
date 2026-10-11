# autoload/event_expr.gd
# 事件链 · 条件表达式求值器（纯静态工具，class_name = EventExpr）。
# 用途：事件脚本按钮的「显示要求」show 字段求值，以及未来效果/入口条件复用。
#
# 规则（本次约定）：
#   show_true(expr)：空串 → 恒显示（true）；非空 → 按表达式求值取布尔。
#
# 支持的表达式（递归下降，无 eval，安全）：
#   - 布尔运算  and / or / !（括号可嵌套）
#   - 比较运算  ==  !=  <  >  <=  >=
#   - 算术      +  -  *  /  （数值）
#   - 字面量    true  /  false  /  null  / 数字 / 字符串(单引号或双引号)
#   - 标识符    当作「全局变量名」，经 GlobalVars.get_var() 取值（缺失→null）
#   - 函数调用  has_tag(状态友好名, 标签)  /  state_field(状态友好名, 字段)
#              状态友好名/标签/字段均以字符串字面量书写（如 has_tag("荧惑日常状态","happy")）
#              有标签 = 该状态 JSON 中任一字符串数组字段含此标签；取反 !has_tag(...) = 无标签
#              state_field 返回该字段的值（数值/字符串），再与数字/字符串比较
#   - 玩家状态  player_busy()                当前是否「在忙」
#              activity_active("game")      是否在运行某类活动（按应用属性，见 BusyState.ACTIVITY_KINDS）
#              activity_top() / activity_low()   权重最高 / 最低的当前活动属性真值（无命中 → ""）
#              activity_weight("game")      某属性的当前运行权重（未命中 → 0.0）
#              ★ 以上经 EventExpr.busy（= BusyState）求值；并入条件编辑器「玩家状态」谓词。
#   顶层若返回非布尔值（裸变量/数字），按真值规则转布尔。
#
# 真值规则：null/false/0/空串 → false；其余 → true。
class_name EventExpr
extends RefCounted

## 全局变量解析器（Object）。供标识符求值引用全局变量。
## 由 EventChainRunner(autoload) 启动时设为 GlobalVars；解耦后便于独立单元测试。
static var globals: Object = null

## 状态注册表解析器（Object）。供 has_tag / state_field 读取状态 JSON。
## 由 EventChainRunner(autoload) 启动时设为 StateRegistry（提供 path_of(friendly)）。
static var states: Object = null

## ★ 批次 94：忙闲/活动状态解析器（Object）。供 player_busy / activity_* 求值。
## 由 EventChainRunner(autoload) 启动时设为 BusyState（autoload 单例）。
## ★ 与 globals / states 同样做成可注入 + 空安全 → 独立单元测试/探针环境缺少 autoload 时不会崩。
static var busy: Object = null


## 便捷入口：show 字段求值。空 → 恒显示。
static func show_true(expr: String) -> bool:
	var e := str(expr).strip_edges()
	if e.is_empty():
		return true
	return eval(e)


## 求值表达式并转布尔；语法错误 → false（保守：出错了就不显示该按钮）。
static func eval(expr: String) -> bool:
	var tk := _Tok.new()
	tk.text = str(expr)
	if not tk.parse():
		return false
	var val: Variant = _parse_or(tk)
	if tk.err or not tk.done():
		return false
	return _truthy(val)


## 仅做语法健全性检查（不求值、不读状态文件），供编辑器实时预览标记。
## 合法 → true；空串 → true（视为「恒显示」）；语法错误 → false。
static func is_well_formed(expr: String) -> bool:
	var e := str(expr).strip_edges()
	if e.is_empty():
		return true
	var tk := _Tok.new()
	tk.text = e
	if not tk.parse():
		return false
	_parse_or(tk)
	return (not tk.err) and tk.done()


func _init() -> void:
	# 纯静态类，不实例化
	push_warning("[EventExpr] 此类为静态工具，不应实例化")


# ================= 解析器（递归下降）=================

static func _parse_or(tk: _Tok) -> Variant:
	var v: Variant = _parse_and(tk)
	while not tk.done() and not tk.err and tk.is_kw("or"):
		tk.advance()
		var _r: Variant = _parse_and(tk)
		v = _bool(_truthy(v) or _truthy(_r))
	return v


static func _parse_and(tk: _Tok) -> Variant:
	var v: Variant = _parse_not(tk)
	while not tk.done() and not tk.err and tk.is_kw("and"):
		tk.advance()
		var _r: Variant = _parse_not(tk)
		v = _bool(_truthy(v) and _truthy(_r))
	return v


static func _parse_not(tk: _Tok) -> Variant:
	if not tk.done() and tk.peek_ok("!"):
		tk.advance()
		return _bool(not _truthy(_parse_not(tk)))
	return _parse_cmp(tk)


static func _parse_cmp(tk: _Tok) -> Variant:
	var v: Variant = _parse_add(tk)
	if tk.done() or tk.err:
		return v
	var op: String = tk.peek_op()
	if op == "" or op == "+" or op == "-" or op == "*" or op == "/" or op == ")":
		return v     # 不是比较运算符 → 原样返回
	tk.advance()
	var r: Variant = _parse_add(tk)
	return _compare(op, v, r)


static func _parse_add(tk: _Tok) -> Variant:
	var v: Variant = _parse_mul(tk)
	while not tk.done() and not tk.err:
		var op: String = tk.peek_op()
		if op != "+" and op != "-":
			break
		tk.advance()
		var r: Variant = _parse_mul(tk)
		v = _arith(op, v, r)
	return v


static func _parse_mul(tk: _Tok) -> Variant:
	var v: Variant = _parse_unary(tk)
	while not tk.done() and not tk.err:
		var op: String = tk.peek_op()
		if op != "*" and op != "/":
			break
		tk.advance()
		var r: Variant = _parse_unary(tk)
		v = _arith(op, v, r)
	return v


static func _parse_unary(tk: _Tok) -> Variant:
	if not tk.done() and tk.peek_ok("-"):
		tk.advance()
		var inner: Variant = _parse_unary(tk)
		if inner is float or inner is int:
			return -float(inner)
		tk.set_err("一元负号作用于非数值")
		return null
	if not tk.done() and tk.peek_ok("+"):
		tk.advance()
		return _parse_unary(tk)
	return _parse_primary(tk)


static func _parse_primary(tk: _Tok) -> Variant:
	if tk.done():
		tk.set_err("意外结束")
		return null
	var t = tk.cur()
	match t.type:
		_Tok.T_NUM:
			tk.advance()
			return t.num
		_Tok.T_STR:
			tk.advance()
			return t.strv
		_Tok.T_KEYW:
			var k: String = t.strv
			if k == "true":
				tk.advance()
				return true
			if k == "false":
				tk.advance()
				return false
			if k == "null":
				tk.advance()
				return null
			tk.set_err("未知关键字 %s" % k)
			return null
		_Tok.T_IDENT:
			tk.advance()
			return _resolve_var(t.strv)
		_Tok.T_LPAREN:
			tk.advance()
			var v: Variant = _parse_or(tk)
			if tk.done() or not tk.peek_ok(")"):
				tk.set_err("缺少右括号")
				return null
			tk.advance()
			return v
		_Tok.T_FUNC:
			tk.advance()
			if tk.done() or not tk.peek_ok("("):
				tk.set_err("函数 %s 后缺少 ( " % t.strv)
				return null
			tk.advance()
			var args: Array = []
			if not tk.done() and not tk.peek_ok(")"):
				args.append(_parse_or(tk))
				while not tk.done() and not tk.err and tk.peek_ok(","):
					tk.advance()
					args.append(_parse_or(tk))
			if tk.done() or not tk.peek_ok(")"):
				tk.set_err("函数 %s 缺少 ) " % t.strv)
				return null
			tk.advance()
			return _resolve_func(tk, t.strv, args)
		_:
			tk.set_err("无法解析的 token")
			return null


# ================= 运算 =================

static func _arith(op: String, a: Variant, b: Variant) -> Variant:
	if not _is_num(a) or not _is_num(b):
		return null
	var x := float(a)
	var y := float(b)
	match op:
		"+":
			return x + y
		"-":
			return x - y
		"*":
			return x * y
		"/":
			return x / y if y != 0.0 else null
	return null


static func _compare(op: String, a: Variant, b: Variant) -> bool:
	match op:
		"==":
			return _eq(a, b)
		"!=":
			return not _eq(a, b)
		"<":
			return _less(a, b)
		">":
			return _less(b, a)
		"<=":
			return _less(a, b) or _eq(a, b)
		">=":
			return _less(b, a) or _eq(a, b)
	return false


static func _eq(a: Variant, b: Variant) -> bool:
	if _is_num(a) and _is_num(b):
		return float(a) == float(b)
	var sa := str(a)
	var sb := str(b)
	return sa == sb


static func _less(a: Variant, b: Variant) -> bool:
	if _is_num(a) and _is_num(b):
		return float(a) < float(b)
	return str(a) < str(b)


static func _is_num(v: Variant) -> bool:
	return v is float or v is int


# 标识符 → 全局变量值；无解析器或缺失 → null
static func _resolve_var(name: String) -> Variant:
	if globals != null and globals.has_method("get_var"):
		return globals.get_var(name, null)
	return null


# ================= 内置函数 =================

## 函数分派：name(参数...) → 值（或 bool）。语法错误经 tk.set_err 上报。
static func _resolve_func(tk: _Tok, name: String, args: Array) -> Variant:
	match name:
		"has_tag":
			if args.size() != 2:
				tk.set_err("has_tag 需要 2 个参数（状态友好名, 标签）")
				return null
			return _has_tag(args[0], args[1])
		"state_field":
			if args.size() != 2:
				tk.set_err("state_field 需要 2 个参数（状态友好名, 字段）")
				return null
			return _state_field(args[0], args[1])
		# ---- 批次 94：玩家状态谓词（在忙/在闲 · 活动属性 · 权重最高/最低）----
		"player_busy":
			if not args.is_empty():
				tk.set_err("player_busy 不需要参数")
				return null
			return _player_busy()
		"activity_active":
			if args.size() != 1:
				tk.set_err("activity_active 需要 1 个参数（活动属性真值，如 \"game\"）")
				return null
			return _activity_active(args[0])
		"activity_weight":
			if args.size() != 1:
				tk.set_err("activity_weight 需要 1 个参数（活动属性真值，如 \"game\"）")
				return null
			return _activity_weight(args[0])
		"activity_top":
			if not args.is_empty():
				tk.set_err("activity_top 不需要参数")
				return null
			return _activity_extreme(true)
		"activity_low":
			if not args.is_empty():
				tk.set_err("activity_low 不需要参数")
				return null
			return _activity_extreme(false)
		_:
			tk.set_err("未知函数 %s" % name)
			return null


# ================= 玩家状态谓词（批次 94）=================
# ★ 全部空安全：busy 未注入 / 缺少对应方法 → 返回保守值（false / 0.0 / ""），绝不崩。

## 取忙闲解析器：优先用注入的 busy；没有则**按节点名从 root 惰性取一次**并缓存。
## ★ 存在的理由：BusyState 的 autoload 顺序晚于 EventChainRunner，注入点执行时它还没进树；
##   惰性取保证「真正求值那一刻」一定拿得到，且不依赖 autoload 顺序。
static func _busy_node() -> Object:
	if busy != null:
		return busy
	var loop: MainLoop = Engine.get_main_loop()
	if loop is SceneTree:
		var n := (loop as SceneTree).root.get_node_or_null("BusyState")
		if n != null:
			busy = n
			return n
	return null


## 当前是否「在忙」（BusyState.is_busy()：自动判断 + 手动覆盖的综合结果）。
static func _player_busy() -> bool:
	var b := _busy_node()
	if b != null and b.has_method("is_busy"):
		return bool(b.is_busy())
	return false


## 是否正在运行某类活动（该属性权重 > 0）。kind 非字符串 → false。
static func _activity_active(kind: Variant) -> bool:
	var b := _busy_node()
	if b != null and b.has_method("activity_active"):
		return bool(b.activity_active(str(kind)))
	return false


## 某活动属性的当前运行权重（未命中 / 无解析器 → 0.0）。便于做 activity_weight("game") > 3 这类比较。
static func _activity_weight(kind: Variant) -> float:
	var b := _busy_node()
	if b != null and b.has_method("activity_weights"):
		var w: Variant = b.activity_weights()
		if w is Dictionary:
			return float((w as Dictionary).get(str(kind), 0.0))
	return 0.0


## 权重最高 / 最低的当前活动属性真值；无命中 → ""（调用方按 false 比较）。
static func _activity_extreme(highest: bool) -> String:
	var b := _busy_node()
	if b == null or not b.has_method("activity_extreme"):
		return ""
	return str(b.activity_extreme(highest))


## has_tag(状态友好名, 标签)：遍历该状态 JSON 所有「字符串数组」字段，任一含该标签 → true。
static func _has_tag(state_friendly: Variant, tag: Variant) -> bool:
	var data: Variant = _read_state(str(state_friendly))
	if data == null or not (data is Dictionary):
		return false
	var tagstr: String = str(tag)
	var d: Dictionary = data as Dictionary
	for key in d:
		var v = d[key]
		if v is Array:
			for elem in (v as Array):
				if str(elem) == tagstr:
					return true
	return false


## state_field(状态友好名, 字段)：返回该字段的值（数值/字符串/数组），缺失 → null。
static func _state_field(state_friendly: Variant, field: Variant) -> Variant:
	var data: Variant = _read_state(str(state_friendly))
	if data == null or not (data is Dictionary):
		return null
	var d: Dictionary = data as Dictionary
	var key: String = str(field)
	if d.has(key):
		return d[key]
	return null


## 经 StateRegistry.path_of 解析状态 JSON 路径并读取；无注册表/无文件 → null。
static func _read_state(friendly: String) -> Variant:
	if states == null or not states.has_method("path_of"):
		return null
	var path: String = states.path_of(friendly)
	if path == "" or not FileAccess.file_exists(path):
		return null
	return _read_json(path)


## 读取 JSON 文件 → 解析结果（Dictionary/Array/标量）；失败 → null。
static func _read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var txt := f.get_as_text()
	f.close()
	var p := JSON.new()
	if p.parse(txt) != OK:
		return null
	return p.data


static func _bool(v: bool) -> bool:
	return v


static func _truthy(v: Variant) -> bool:
	if v == null:
		return false
	if v is bool:
		return v
	if v is float or v is int:
		return float(v) != 0.0
	if v is String:
		return not (v as String).is_empty()
	if v is Dictionary or v is Array:
		return (v as Array).size() > 0 if v is Array else (v as Dictionary).size() > 0
	return true


# ================= 词法器 =================
# 轻量 token 流：支持数字 / 字符串(' " 双引号) / 标识符 / 关键字 / 运算符 + 括号
class _Tok:
	const T_NUM := 0
	const T_STR := 1
	const T_IDENT := 2
	const T_KEYW := 3
	const T_OP := 4
	const T_LPAREN := 5
	const T_RPAREN := 6
	const T_FUNC := 7
	const T_COMMA := 8

	var text := ""
	var toks: Array = []   # 元素 {type, strv, num}
	var pos := 0
	var err := false
	var _errmsg := ""

	func cur() -> Variant:
		return toks[pos]

	func done() -> bool:
		return err or pos >= toks.size()

	func advance() -> void:
		if pos < toks.size():
			pos += 1

	func peek_ok(s: String) -> bool:
		if pos >= toks.size():
			return false
		var t = toks[pos]
		return (t.type == T_OP or t.type == T_LPAREN or t.type == T_RPAREN or t.type == T_COMMA) and str(t.strv) == s

	func peek_op() -> String:
		if pos >= toks.size():
			return ""
		var t = toks[pos]
		if t.type != T_OP and t.type != T_LPAREN and t.type != T_RPAREN:
			return ""
		return str(t.strv)

	func is_kw(k: String) -> bool:
		if pos >= toks.size():
			return false
		var t = toks[pos]
		return t.type == T_KEYW and str(t.strv) == k

	func set_err(m: String) -> void:
		if not err:
			err = true
			_errmsg = m

	func get_err() -> String:
		return _errmsg

	# 分词：成功返回 true
	func parse() -> bool:
		pos = 0
		err = false
		toks.clear()
		var i := 0
		var n := text.length()
		while i < n:
			var c := text[i]
			if c == " " or c == "\t" or c == "\n" or c == "\r":
				i += 1
				continue
			if c == "(":
				toks.append({ "type": T_LPAREN, "strv": c, "num": 0.0 })
				i += 1
				continue
			if c == ")":
				toks.append({ "type": T_RPAREN, "strv": c, "num": 0.0 })
				i += 1
				continue
			if c == ",":
				toks.append({ "type": T_COMMA, "strv": c, "num": 0.0 })
				i += 1
				continue
			# 数字
			if _is_digit(c) or (c == "." and i + 1 < n and _is_digit(text[i + 1])):
				var j := i
				while j < n and (_is_digit(text[j]) or text[j] == "."):
					j += 1
				var numstr := text.substr(i, j - i)
				if not numstr.is_valid_float():
					set_err("非法数字 %s" % numstr)
					return false
				toks.append({ "type": T_NUM, "strv": numstr, "num": float(numstr) })
				i = j
				continue
			# 字符串
			if c == "'" or c == "\"":
				var quote := c
				var j := i + 1
				var sb := ""
				while j < n:
					if text[j] == quote:
						break
					if text[j] == "\\" and j + 1 < n:
						sb += text[j + 1]
						j += 2
						continue
					sb += text[j]
					j += 1
				if j >= n:
					set_err("字符串未闭合")
					return false
				toks.append({ "type": T_STR, "strv": sb, "num": 0.0 })
				i = j + 1
				continue
			# 运算符（长匹配优先：>= <= != ==）
			if c == "=" or c == "<" or c == ">" or c == "!":
				var two := text.substr(i, 2)
				if two == "==" or two == "<=" or two == ">=" or two == "!=":
					toks.append({ "type": T_OP, "strv": two, "num": 0.0 })
					i += 2
					continue
				if c == "!":
					# 单 ! 作为逻辑非
					toks.append({ "type": T_OP, "strv": "!", "num": 0.0 })
					i += 1
					continue
				if c == "=":
					set_err("孤立的 = （应写成 ==）")
					return false
				toks.append({ "type": T_OP, "strv": c, "num": 0.0 })
				i += 1
				continue
			if c == "+" or c == "-" or c == "*" or c == "/":
				toks.append({ "type": T_OP, "strv": c, "num": 0.0 })
				i += 1
				continue
			# 标识符 / 关键字
			if _is_ident_start(c):
				var j := i
				while j < n and _is_ident_part(text[j]):
					j += 1
				var word := text.substr(i, j - i)
				var lw := word.to_lower()
				if lw == "true" or lw == "false" or lw == "null" or lw == "and" or lw == "or":
					toks.append({ "type": T_KEYW, "strv": lw, "num": 0.0 })
				else:
					# 标识符：若紧随 (（允许中间空格）→ 视为函数名
					var k := j
					while k < n and (text[k] == " " or text[k] == "\t"):
						k += 1
					if k < n and text[k] == "(":
						toks.append({ "type": T_FUNC, "strv": word, "num": 0.0 })
					else:
						toks.append({ "type": T_IDENT, "strv": word, "num": 0.0 })
				i = j
				continue
			set_err("无法识别字符 %s" % c)
			return false
		return true

	func _is_digit(c: String) -> bool:
		return c >= "0" and c <= "9"

	func _is_ident_start(c: String) -> bool:
		return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"

	func _is_ident_part(c: String) -> bool:
		return _is_ident_start(c) or (c >= "0" and c <= "9")