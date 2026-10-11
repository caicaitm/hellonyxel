# dialogue/dialogue_voice.gd
# 台词音效（「泡泡声」）解析器 —— 纯静态工具：只把台词定义换算成「显示文本 + 语音事件序列」，
# 自己不做任何播放（播放见 dialogue/dialogue_voice_player.gd）。
#
# ── 台词定义语法（与 TextRenderer 的 (修饰)[内容] 同源，另加语音扩展）──
#   (修饰)        样式修饰段头。语音忽略；显示会翻译成 BBCode（底部对话面板已改 RichTextLabel，
#                 颜色/字号/透明度/对齐/换行真正生效）。
#   [ ... ]       内容块（可省略）
#   "字符串"      字面文本 → 按语言逐字 / 逐词发声
#   $变量名       变量 → 显示的是变量值；语音**无论值多长都只响一声**
#   #             「间隔」= 停顿 1 个单位（0.1s）；连写累计（### = 3 个单位 = 0.3s）
#   #*N           停顿 N 个单位（0.1s × N）
#   +             段间连接符（忽略）
#
# ★ 排版空白：结构符（引号 / $变量 / # / [ ] / ( )）之间的空格、换行只是排版，不进显示、
#   也不发声。要显示空格请写进引号里：["Hello " "world"]。引号**内部**的空白照常保留。
#
# 例：
#   (修饰1)["我是字符串1" $我是变量 ### "我是字符串2"](修饰2)["我是字符串3" $我是变量 #*10 "我是字符串4"]
#   → 显示：我是字符串1<变量值>我是字符串2我是字符串3<变量值>我是字符串4
#   → 语音：…逐字泡泡… 「1 声」 …停顿 0.3s… …逐字泡泡… …逐字泡泡… 「1 声」 …停顿 1.0s… …逐字泡泡…
#
# ── 语言决定「字」还是「词」──
#   中日韩泰（zh_* / ja / ko / th）无词间空格 → 逐字
#   其余语言（en / es / fr …）按空格分词 → 逐词
#
# ── 标点 ──
#   命中标点的那个字 / 词发声「加重 + 加长」（播放器据此加大音量、降低音高）。
#
# ★ 本脚本**不引用任何 autoload 全局名**（变量求值走外部传入的 resolver，
#   缺省时按节点名从 /root 取），这样在 `--script` 探针里也能被 load() 后独立使用。
class_name DialogueVoice
extends RefCounted

# 事件类型（events 数组的元素都是 Dictionary）
const EV_POP := "pop"       # { "type":"pop", "unit":String, "punct":bool }  一次泡泡
const EV_VAR := "var"       # { "type":"var" }                               变量：只响一声
const EV_PAUSE := "pause"   # { "type":"pause", "seconds":float }            停顿

const PAUSE_SYMBOL := "#"   # 「间隔」符号（暂定 #，与用户示例一致）
const PAUSE_UNIT := 0.1     # 一个 # = 0.1 秒
const VAR_SYMBOL := "$"

# 逐字语言（无词间空格）
const CHAR_LANGS: Array = ["ja", "ko", "th"]

# 标点集合（中英混排；含常见全角/半角标点）
const PUNCT_CHARS := "，。！？；：、,.!?;:…—～~·「」『』（）()【】〔〕《》〈〉“”‘’\"'`-/|&*+=<>_"


## 解析台词定义 → { "display": String, "events": Array, "blocks": Array }
## resolver: Callable(变量名)->Variant；留空则用 /root/GlobalVars.resolve。
## display  = 去掉 (修饰) 与 [ ] 与引号、把 $变量 换成值之后的纯文本；
## blocks   = [{ "mod":String, "text":String }] 按修饰串分组的已求值文本
##            （供对话面板生成 BBCode：颜色/字号/透明度/对齐/换行真正生效）；
## events   = 按顺序排列的语音事件（pop / var / pause）。
static func parse(def: String, lang: String, resolver: Callable = Callable()) -> Dictionary:
	var atoms := tokenize(def)
	var res: Callable = resolver if resolver.is_valid() else default_resolver()
	var display := ""
	var events: Array = []
	var blocks: Array = []
	## 当前生效的修饰串：遇到 (修饰)[ 就更新（空修饰 () = 回到默认样式），
	## 与 TextRenderer 的「无新修饰则沿用上一段样式」一致。
	var cur_mod := ""
	for a in atoms:
		match str(a.get("t", "")):
			"mod":
				cur_mod = str(a.get("s", ""))
			"text":
				var s := str(a.get("s", ""))
				display += s
				_push_block(blocks, cur_mod, s)
				_emit_text_events(s, lang, events)
			"var":
				var vs := _resolve(res, str(a.get("s", "")))
				display += vs
				_push_block(blocks, cur_mod, vs)
				events.append({ "type": EV_VAR })
			"pause":
				events.append({ "type": EV_PAUSE, "seconds": float(a.get("n", 1)) * PAUSE_UNIT })
	return { "display": display, "events": events, "blocks": blocks }


## 只取「显示」的便捷入口（按钮文字 / 台词记录等**不需要语音事件**的场景）：
## 返回 { "display": String, "blocks": Array }，字段与 parse 完全一致。
static func to_display(def: String, lang: String, resolver: Callable = Callable()) -> Dictionary:
	var r := parse(def, lang, resolver)
	return { "display": str(r.get("display", "")), "blocks": r.get("blocks", []) }


## 定义串 → **BBCode**（供 RichTextLabel 直接 set_text：颜色/透明度/字号/对齐/换行真正生效）。
## ★ 与正文同一套求值（引号 / $变量 / 停顿），只是再交给 TextRenderer 把 (修饰) 翻成标签。
static func to_bbcode(def: String, lang: String, resolver: Callable = Callable()) -> String:
	var r := parse(def, lang, resolver)
	var blocks: Array = r.get("blocks", [])
	var tr := TextRenderer.new()
	return tr.bbcode_from_blocks(blocks)


## 按钮文字：把「定义串」渲染成 { "plain":String, "bbcode":String, "rich":bool }。
##   rich = false 表示**没有** (修饰)[ 结构 → 调用方应退回普通 Label：
##     保持既有的居中观感（普通 Label 是居中的，RichTextLabel 默认左对齐），
##     也省掉一个节点。只有真写了修饰（要颜色/字号/对齐）才值得上富文本。
static func render_button_label(def: String, lang: String,
		resolver: Callable = Callable()) -> Dictionary:
	var d := to_display(def, lang, resolver)
	var plain := str(d.get("display", ""))
	if not has_modifier(def):
		return { "plain": plain, "bbcode": "", "rich": false }
	var tr := TextRenderer.new()
	return { "plain": plain, "bbcode": tr.bbcode_from_blocks(d.get("blocks", [])), "rich": true }


## 定义串里是否含「(修饰)[」结构（= 需要富文本渲染）。
## ★ 判据与 tokenize 的第 1 条完全一致：`(` … `)` 之后**紧跟** `[`（中间允许排版空白）。
static func has_modifier(def: String) -> bool:
	var i := def.find("(")
	while i != -1:
		var close := def.find(")", i + 1)
		if close == -1:
			return false
		var j := close + 1
		while j < def.length() and (def[j] == " " or def[j] == "\t" or def[j] == "\n"):
			j += 1
		if j < def.length() and def[j] == "[":
			return true
		i = def.find("(", close + 1)
	return false


## 变量求值器：默认从 /root/GlobalVars 取（用节点名而非全局名，避免编译期依赖）
static func default_resolver() -> Callable:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var gv := (loop as SceneTree).root.get_node_or_null("GlobalVars")
		if gv != null and gv.has_method("resolve"):
			return Callable(gv, "resolve")
	return Callable()


## 该语言是否「逐字」发声（true=按字，false=按空格逐词）
static func is_per_char_lang(lang: String) -> bool:
	var l := lang.to_lower()
	if l.begins_with("zh"):
		return true
	return l in CHAR_LANGS


## 单个字符是否为标点
static func is_punct_char(c: String) -> bool:
	return c.length() == 1 and PUNCT_CHARS.contains(c)


## 该字 / 词里是否含标点（逐词语言用：Hello, → 命中）
static func contains_punct(s: String) -> bool:
	for ch in s:
		if PUNCT_CHARS.contains(ch):
			return true
	return false


## 把事件序列格式化成一行的可读串（调试 / 验证用）
static func format_events(events: Array) -> String:
	var parts: Array = []
	for e in events:
		match str(e.get("type", "")):
			EV_POP:
				parts.append(("!pop(%s)" if bool(e.get("punct", false)) else "pop(%s)") % str(e.get("unit", "")))
			EV_VAR:
				parts.append("var")
			EV_PAUSE:
				parts.append("pause(%.1f)" % float(e.get("seconds", 0.0)))
	return " ".join(parts)


# ==================== 内部：词法扫描 ====================

## 把定义串切成原子序列：[{t:"text"|"var"|"pause", ...}]
static func tokenize(def: String) -> Array:
	var out: Array = []
	var n := def.length()
	var i := 0
	var buf := ""
	while i < n:
		var c := def[i]
		# 1) 样式修饰 ( ... )：仅当紧跟 [ 时才当修饰（否则是普通括号，当文字保留）
		if c == "(":
			var close := _find_matching(def, i, "(", ")")
			var after: int = -1
			if close != -1:
				after = _next_non_space(def, close + 1)
			if close != -1 and after != -1 and def[after] == "[":
				_flush_text(out, buf)
				buf = ""
				# 单独记一个 mod 原子：显示时把 (修饰) 翻译成样式（语音忽略）
				out.append({ "t": "mod", "s": def.substr(i + 1, close - i - 1) })
				i = close + 1
				continue
			buf += c
			i += 1
			continue
		# 2) 内容块括号：结构符，丢弃
		if c == "[" or c == "]":
			i += 1
			continue
		# 3) 引号字面串：剥掉引号，收内部文本（支持 \" \\ \n 转义）
		if c == "\"":
			var s := ""
			i += 1
			while i < n:
				var ch := def[i]
				if ch == "\\" and i + 1 < n:
					var nx := def[i + 1]
					if nx == "n":
						s += "\n"
					elif nx == "\"":
						s += "\""
					elif nx == "\\":
						s += "\\"
					else:
						s += nx
					i += 2
					continue
				if ch == "\"":
					i += 1
					break
				s += ch
				i += 1
			_flush_text(out, buf)
			buf = ""
			out.append({ "t": "text", "s": s })
			continue
		# 4) $变量名（变量名允许中文等非 ASCII 字符）
		if c == VAR_SYMBOL:
			var j := i + 1
			while j < n and _is_ident(def[j]):
				j += 1
			if j > i + 1:
				_flush_text(out, buf)
				buf = ""
				out.append({ "t": "var", "s": def.substr(i + 1, j - i - 1) })
				i = j
				continue
			buf += c
			i += 1
			continue
		# 5) 停顿 # / #*N
		if c == PAUSE_SYMBOL:
			var k := i + 1
			var num := 1
			if k < n and def[k] == "*":
				k += 1
				var d := ""
				while k < n and def[k] >= "0" and def[k] <= "9":
					d += def[k]
					k += 1
				if d != "":
					num = int(d)
			_flush_text(out, buf)
			buf = ""
			_push_pause(out, maxi(num, 0))
			i = k
			continue
		# 6) 段连接符 +：仅当右侧紧跟新段起始（( [ " $）时才是连接符，否则是普通文字
		if c == "+":
			var q := _next_non_space(def, i + 1)
			if q != -1 and (def[q] == "(" or def[q] == "[" or def[q] == "\"" or def[q] == VAR_SYMBOL):
				_flush_text(out, buf)
				buf = ""
				i = q
				continue
			buf += c
			i += 1
			continue
		buf += c
		i += 1
	_flush_text(out, buf)
	return out


# 冲刷文本缓冲：纯空白（结构符之间的排版空格）直接丢弃；否则去掉尾部空白再收成 text 原子
static func _flush_text(out: Array, buf: String) -> void:
	var s := buf.rstrip(" \t\r\n")
	if s != "":
		out.append({ "t": "text", "s": s })


# 追加一个「样式块」：同一修饰串下的相邻文本合并成一块（减少 BBCode 标签数量）
static func _push_block(blocks: Array, mod: String, text: String) -> void:
	if text.is_empty():
		return
	if not blocks.is_empty():
		var last: Dictionary = blocks[blocks.size() - 1]
		# ★ 不能用 "\u0000" 当「不存在」哨兵：Godot 会把它解析成真正的 NUL 字符塞进 String，
		#   追加时触发 "Unicode parsing error ... Unexpected NUL character"。改用 has() 判存在性。
		if last.has("mod") and str(last["mod"]) == mod:
			last["text"] = str(last.get("text", "")) + text
			return
	blocks.append({ "mod": mod, "text": text })


# 追加一个停顿；若紧挨着前一个原子也是停顿（如 ### 连写），合并单位数（3 → 0.3s）
static func _push_pause(out: Array, units: int) -> void:
	if units <= 0:
		return
	if not out.is_empty():
		var last: Dictionary = out[out.size() - 1]
		if str(last.get("t", "")) == "pause":
			last["n"] = int(last.get("n", 0)) + units
			return
	out.append({ "t": "pause", "n": units })


# 按语言把一段文本拆成发声单元，追加 pop 事件
static func _emit_text_events(text: String, lang: String, events: Array) -> void:
	if text.is_empty():
		return
	if is_per_char_lang(lang):
		for ch in text:
			if ch.strip_edges() == "":
				continue   # 空白不发声
			events.append({ "type": EV_POP, "unit": ch, "punct": is_punct_char(ch) })
		return
	var norm := text.replace("\t", " ").replace("\r", " ").replace("\n", " ")
	for w in norm.split(" ", false):
		if str(w).is_empty():
			continue
		events.append({ "type": EV_POP, "unit": str(w), "punct": contains_punct(str(w)) })


static func _resolve(res: Callable, name: String) -> String:
	if not res.is_valid():
		return ""
	var v: Variant = res.call(name)
	return "" if v == null else str(v)


static func _find_matching(s: String, start: int, open_c: String, close_c: String) -> int:
	var depth := 0
	for i in range(start, s.length()):
		var ch := s[i]
		if ch == open_c:
			depth += 1
		elif ch == close_c:
			depth -= 1
			if depth == 0:
				return i
	return -1


static func _next_non_space(s: String, start: int) -> int:
	var i := start
	while i < s.length():
		var c := s[i]
		if c != " " and c != "\t" and c != "\r" and c != "\n":
			return i
		i += 1
	return -1


# 变量名允许：字母 / 数字 / 下划线 / 任意非 ASCII（中文变量名）
static func _is_ident(c: String) -> bool:
	if c == "_":
		return true
	if c >= "a" and c <= "z":
		return true
	if c >= "A" and c <= "Z":
		return true
	if c >= "0" and c <= "9":
		return true
	return c.length() == 1 and ord(c) > 127
