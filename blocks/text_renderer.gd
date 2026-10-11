# text_renderer.gd
# 解析「(修饰变量)[内容]」富文本定义，并求值内容里的 $变量 / "字符串"。
#
# ── 设计基准（本次实现约定）──
# 修饰变量（可任意组合，推荐用 #RRGGBB 写颜色以避免与 R/C/L 字母歧义）：
#   RGB码      #RRGGBB（推荐）或 R,G,B[,A]（0~255，A 可选）
#   \n         换行（本段开始前换到下一行）
#   R / C / L  右对齐 / 居中 / 左对齐（默认左）
#   %透明度    0~100，控制字的透明度（如 %80 → 0.8）
#   @字号      6~120（如 @24），控制本段字号（默认 16）
# 内容：
#   $变量名    显示该变量的值（找不到则显示空）
#   "字符串"   字面字符串（\" \\ \n 会被转义）
#   可用 + 拼接，如 "您本次比赛第" + $名次 + "名"
# 拼接段：
#   (修饰1)[内容1] + (修饰2)[内容2]  → 各自独立样式
#   (修饰1)[内容1] + [内容2]         → 内容2 沿用内容1 的样式（无新修饰即继承）
class_name TextRenderer
extends RefCounted

# 单个文本片段（同一样式的一段内容）
class TextSegment:
	var fill_color: Color = UIStyle.TEXT_DEFAULT  # 默认样式（项目统一白字）；无颜色修饰/空修饰 () 即沿用此值
	var alpha: float = 1.0        # 0~1
	var align: String = "L"       # L 左 / C 中 / R 右
	var newline: bool = false     # 本段之前是否强制换行
	var font_size: int = 16       # @字号 6~120，默认 16
	var content: String = ""      # 原始内容定义（含 $var / "..." / +）

# ---- 对外入口 ----

## 将整段定义解析为「文本片段」数组（样式已解析，内容仍是定义串，待 求值）
func parse(def: String) -> Array[TextSegment]:
	var raw_segs := _split_plus(def, true)
	var segs: Array[TextSegment] = []
	var base := _new_segment()
	for raw in raw_segs:
		var mod := ""
		var has_mod := false
		var content := raw
		if raw.strip_edges().begins_with("("):
			var op := raw.find("(")
			var end := raw.find(")")
			if op != -1 and end != -1 and end > op:
				mod = raw.substr(op + 1, end - op - 1)
				content = raw.substr(end + 1)
				has_mod = true
		## ★ 必须先去首尾空白再判方括号：分段是按 + 切的，切出的片段会带着
		##   「 + 」两侧的空格（如 `[第一段] `）。若直接判 ends_with("]") 会失败 →
		##   方括号被当成正文显示成 `[第一段]`（修饰没错，是这里漏了裁剪）。
		##   括号「内侧」的空白保留（`[ 你好 ]` → ` 你好 `），只裁括号外的排版空白。
		var trimmed := content.strip_edges()
		var inner := content
		if trimmed.length() >= 2 and trimmed.begins_with("[") and trimmed.ends_with("]"):
			inner = trimmed.substr(1, trimmed.length() - 2)
		else:
			inner = trimmed
		if has_mod:
			# 空修饰 () 时 mod=="" → _apply_modifier 不覆盖任何项，得到默认样式段（白字/左对齐/不透明）
			base = _apply_modifier(_new_segment(), mod)
		segs.append(_build(base, inner))
	return segs

## 将一段内容里的 $变量 / "字符串" 求值并拼接。
## 变量解析器: Callable(名:String)->Variant；返回 null 视为空。
func evaluate(seg_content: String, variable_resolver: Callable) -> String:
	var parts := _split_plus(seg_content, false)
	var result := ""
	for p in parts:
		## ★ 按 + 切出来的片段会带着「 + 」两侧的排版空格，必须先裁首尾空白再判前缀。
		##   否则 `"第" + $名次 + "名"` 里的 ` $名次 ` 不以 $ 开头 → 变量被当字面文本原样显示。
		var t := p.strip_edges()
		if t.begins_with("$"):
			var nm := t.substr(1)
			var v = null
			if variable_resolver.is_valid():
				v = variable_resolver.call(nm)
			result += "" if v == null else str(v)
		elif t.begins_with("\""):
			var s := t.substr(1, maxi(t.length() - 2, 0))
			s = s.replace("\\\"", "\"").replace("\\\\", "\\").replace("\\n", "\n")
			result += s
		else:
			result += t
	return result

# ---- 公共渲染：定义串 → BBCode（供 RichTextLabel 使用）----

## 定义串 → { "bbcode":String, "text":String }
## text = 去掉一切修饰/结构符后的纯文本（供「是否有可见文本」判定）。
## 积木文本框 / 弹窗事件正文都走这里，保证「修饰」只有一份实现。
func to_bbcode(def: String, resolver: Callable = Callable()) -> Dictionary:
	if def.strip_edges().is_empty():
		return { "bbcode": "", "text": "" }
	var bb := ""
	var plain := ""
	var segs: Array = parse(def)
	for seg in segs:
		if seg.newline:
			bb += "\n"
		var text: String = evaluate(seg.content, resolver)
		if text.is_empty():
			continue
		plain += text
		bb += _bbcode_body(seg, text)
	return { "bbcode": bb, "text": plain }


## 由「修饰串 + 已求值文本」列表生成 BBCode。
## blocks 元素: { "mod":String, "text":String }。对话面板用：文本已由 DialogueVoice
## 按台词语法（引号/停顿/变量）求值，这里只负责把 (修饰) 翻译成 BBCode。
func bbcode_from_blocks(blocks: Array) -> String:
	var out := ""
	for b in blocks:
		if not (b is Dictionary):
			continue
		var text: String = str(b.get("text", ""))
		if text.is_empty():
			continue
		var seg: TextSegment = _apply_modifier(_new_segment(), str(b.get("mod", "")))
		if seg.newline:
			out += "\n"
		out += _bbcode_body(seg, text)
	return out


## 单段 → BBCode（颜色含透明度 / 字号 / 对齐）。
## 正文里的 [ 必须转义，否则会被当 BBCode 标签。
func _bbcode_body(seg: TextSegment, text: String) -> String:
	var col: Color = seg.fill_color
	col.a *= seg.alpha
	# 只有真的需要透明度时才输出 8 位 hex（#RRGGBBAA）；否则用更保险的 6 位 #RRGGBB
	var hex: String = col.to_html(col.a < 1.0)
	var body: String = "[color=#%s][font_size=%d]%s[/font_size][/color]" % [
		hex, seg.font_size, text.replace("[", "[lb]")]
	match str(seg.align):
		"C":
			return "[center]" + body + "[/center]"
		"R":
			return "[right]" + body + "[/right]"
	return body


# ---- 内部 ----

func _new_segment() -> TextSegment:
	return TextSegment.new()

func _build(base: TextSegment, inner: String) -> TextSegment:
	var f := TextSegment.new()
	f.fill_color = base.fill_color
	f.alpha = base.alpha
	f.align = base.align
	f.newline = base.newline
	f.font_size = base.font_size
	f.content = inner
	return f

# 顶层/内容 分段：按 + 切分，可选跟踪 [ ] 深度与 " " 引号
func _split_plus(def: String, track_bracket: bool) -> PackedStringArray:
	var segs: PackedStringArray = []
	var cur := ""
	var depth := 0
	var in_quote := false
	var n := def.length()
	for i in n:
		var ch := def[i]
		if ch == "\"":
			in_quote = not in_quote
			cur += ch
		elif track_bracket and ch == "[":
			depth += 1
			cur += ch
		elif track_bracket and ch == "]":
			depth = maxi(depth - 1, 0)
			cur += ch
		elif ch == "+" and depth == 0 and not in_quote:
			segs.append(cur)
			cur = ""
		else:
			cur += ch
	segs.append(cur)
	return segs

# 把修饰串应用到片段（仅覆盖出现的项，其余保持传入的默认值）
func _apply_modifier(seg: TextSegment, mod: String) -> TextSegment:
	var s := mod
	# 1) 透明度 %NN
	var pi := s.find("%")
	if pi != -1:
		var after := s.substr(pi + 1)
		var digits := ""
		for k in after.length():
			var c := after[k]
			if c >= "0" and c <= "9":
				digits += c
			else:
				break
		if digits != "":
			seg.alpha = clamp(float(digits) / 100.0, 0.0, 1.0)
		var tail := pi + 1 + digits.length()
		s = s.substr(0, pi) + s.substr(tail)
	# 2) 换行 \n
	if "\\n" in s:
		seg.newline = true
		s = s.replace("\\n", "")
	# 3) 颜色（#RRGGBB 或 R,G,B[,A]）
	s = _extract_color(s, seg)
	# 4) 字号 @NN
	var ati := s.find("@")
	if ati != -1:
		var after := s.substr(ati + 1)
		var dstr := ""
		for c in after:
			if c >= "0" and c <= "9":
				dstr += c
			else:
				break
		if dstr != "":
			seg.font_size = clampi(int(dstr), 6, 120)
		var tail2 := ati + 1 + dstr.length()
		s = s.substr(0, ati) + s.substr(tail2)
	# 5) 对齐 R/C/L（剩余字符中，取最后一个出现的为准）
	var align_char := ""
	for ch in s:
		if ch == "R" or ch == "C" or ch == "L":
			align_char = ch
	if align_char != "":
		seg.align = align_char
	return seg

func _extract_color(s: String, seg: TextSegment) -> String:
	var rest := s
	# #RRGGBB
	var hi := rest.find("#")
	if hi != -1:
		var hex := rest.substr(hi + 1, 6)
		if _is_hex6(hex):
			seg.fill_color = Color("#" + hex)
			rest = rest.substr(0, hi) + rest.substr(hi + 1 + 6)
			return rest
	# R,G,B[,A]（允许末项带尾随对齐字母，如 255,0,0L）
	if "," in rest:
		var parts := rest.split(",")
		if parts.size() >= 3 and _all_digits(parts[0]) and _all_digits(parts[1]) and _all_digits(parts[2]):
			var r := int(parts[0])
			var g := int(parts[1])
			var b := int(_digit_prefix(parts[2]))
			var a := 255
			if parts.size() >= 4:
				a = int(_digit_prefix(parts[3]))
			seg.fill_color = Color(
				clamp(float(r) / 255.0, 0.0, 1.0),
				clamp(float(g) / 255.0, 0.0, 1.0),
				clamp(float(b) / 255.0, 0.0, 1.0),
				clamp(float(a) / 255.0, 0.0, 1.0))
			var removed := parts[0] + "," + parts[1] + "," + _digit_prefix(parts[2])
			rest = rest.replace(removed, "")
			return rest
	# 兜底：纯 6 位 hex（无 #）
	if rest.length() == 6 and _is_hex6(rest):
		seg.fill_color = Color("#" + rest)
		return ""
	return rest

func _digit_prefix(s: String) -> String:
	var o := ""
	for ch in s:
		if ch >= "0" and ch <= "9":
			o += ch
		else:
			break
	return o

func _all_digits(s: String) -> bool:
	if s == "":
		return false
	for ch in s:
		if ch < "0" or ch > "9":
			return false
	return true

func _is_hex6(s: String) -> bool:
	if s.length() != 6:
		return false
	for ch in s:
		var u := ch.to_upper()
		if not ((u >= "0" and u <= "9") or (u >= "A" and u <= "F")):
			return false
	return true

# ---- 供编辑器/外部使用的公开接口 ----

## 顶层分段：按 + 切分(跟踪 [ ] 深度与引号)，返回各段原始串(含括号/修饰/内容)
func split_plus(def: String) -> PackedStringArray:
	return _split_plus(def, true)

## 新建一个默认样式片段
func new_segment() -> TextSegment:
	return TextSegment.new()

## 把修饰串应用到片段(只覆盖出现的项)，返回该片段
func apply_modifier(seg: TextSegment, mod: String) -> TextSegment:
	return _apply_modifier(seg, mod)

## 由片段序列化成修饰串(规范化：颜色写 #RRGGBB、字号 @NN、透明度 %NN、换行 \n、对齐字符)
func build_modifier(seg: TextSegment) -> String:
	var m := ""
	var rgb := Color(seg.fill_color.r, seg.fill_color.g, seg.fill_color.b)
	m += "#" + rgb.to_html(false)
	if seg.font_size != 16:
		m += "@%d" % seg.font_size
	if seg.newline:
		m += "\\n"
	if seg.alpha < 1.0:
		m += "%%%d" % clampi(roundi(seg.alpha * 100.0), 0, 100)
	m += seg.align
	return m
