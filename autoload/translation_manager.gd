# autoload/translation_manager.gd
# 多语言管理（模仿 abandon 版 scripts/i18n.gd 的控制逻辑，适配当前项目）。
#
# 翻译表：res://data/translations.tsv（Tab 分隔）。
#   表头：简体中文 / 繁体中文 / English
#   每行：简体中文原文(同时也是 key) \t 繁体中文 \t English
#
# 规则：
#   - t(key) 取当前语言的翻译；该语言缺失 → 回退简体中文(key 本身)；未知 key 也回退原字样，保证不空白。
#   - set_lang() 修改 current_lang 并发射 language_changed，供已打开的面板实时重译。
#   - 打开时默认语言 = 玩家电脑语言（读 sysinfo.json 的 language.ui_culture_name）；
#     该语言游戏没做 → 回退英文。
#
# 注意：本脚本作为 autoload 单例（名 TranslationManager），故不再声明 class_name，
#       否则 Godot 报 "Class hides an autoload singleton"。翻译函数叫 t() 而非 tr()
#       （tr() 是 Object 原生方法，重名会解析失败）。
extends Node

const TABLE_PATH: String = "res://data/translations.tsv"

# 语言代码（顺序 = TSV 列顺序）。第 0 列必须是简体中文(key 列)。
const LANG_CODES: Array = ["zh_CN", "zh_TW", "en", "ja", "ru", "ko", "es", "pt", "fr", "de", "it", "tr", "pl", "th", "vi"]
# 语言显示名（= TSV 表头顺序；语言按钮用，不做翻译）
const LANG_NAMES: Array = ["简体中文", "繁体中文", "English", "日本語", "Русский", "한국어", "Español", "Português", "Français", "Deutsch", "Italiano", "Türkçe", "Polski", "ไทย", "Tiếng Việt"]

var _table: Dictionary = {}          # zh_key -> { zh_CN, zh_TW, en }
var _reverse: Dictionary = {}        # 任意语言的译文 -> zh_key（用于已显示文字的反查重译）
var current_lang: String = "en"

signal language_changed(lang: String)


func _ready() -> void:
	load_table()
	current_lang = _default_lang()
	print("[TranslationManager] 默认语言 = %s（已加载 %d 条翻译）" % [current_lang, _table.size()])


# 打开时默认语言：读 sysinfo 的玩家电脑语言；未做该语言 → 英文
func _default_lang() -> String:
	var lang: Variant = null
	if DesktopShell != null and DesktopShell.sysinfo is Dictionary:
		lang = (DesktopShell.sysinfo as Dictionary).get("language", null)
	var name := ""
	if lang is Dictionary:
		name = str((lang as Dictionary).get("ui_culture_name", ""))
	name = name.to_lower()
	if name.begins_with("zh"):
		# zh-TW / zh-HK / zh-MO / zh-Hant → 繁体中文；其余中文 → 简体
		if name.contains("tw") or name.contains("hk") or name.contains("mo") or name.contains("hant"):
			return "zh_TW"
		return "zh_CN"
	if name.begins_with("en"):
		return "en"
	if name.begins_with("ja"):
		return "ja"
	if name.begins_with("ru"):
		return "ru"
	if name.begins_with("ko"):
		return "ko"
	if name.begins_with("es"):
		return "es"
	if name.begins_with("pt"):
		return "pt"
	if name.begins_with("fr"):
		return "fr"
	if name.begins_with("de"):
		return "de"
	if name.begins_with("it"):
		return "it"
	if name.begins_with("tr"):
		return "tr"
	if name.begins_with("pl"):
		return "pl"
	if name.begins_with("th"):
		return "th"
	if name.begins_with("vi"):
		return "vi"
	# 未实现该语言 → 英文
	return "en"


## 从 TSV 加载翻译表（覆盖式）
func load_table() -> void:
	_table.clear()
	_reverse.clear()
	if not FileAccess.file_exists(TABLE_PATH):
		push_warning("[TranslationManager] 翻译表缺失: %s" % TABLE_PATH)
		return
	var f := FileAccess.open(TABLE_PATH, FileAccess.READ)
	if f == null:
		push_warning("[TranslationManager] 翻译表打开失败: %s" % TABLE_PATH)
		return
	var first: bool = true
	while not f.eof_reached():
		var line := f.get_line()
		if first:
			first = false      # 跳过表头
			continue
		if line.strip_edges() == "":
			continue
		var parts := line.split("\t")   # 保留空列(allow_empty 默认 true)
		var cols: Array = []
		for i in range(LANG_CODES.size()):
			var c: String = parts[i] if i < parts.size() else ""
			cols.append(_clean_cell(c))
		var zh: String = cols[0]
		if zh.is_empty():
			continue
		var row := { "zh_CN": zh }
		for i in range(1, LANG_CODES.size()):
			row[LANG_CODES[i]] = cols[i]
		_table[zh] = row
		# 反查索引：任意语言的译文 → 简体中文 key。首次出现优先。
		for v in cols:
			var sv: String = str(v)
			if not sv.is_empty() and not _reverse.has(sv):
				_reverse[sv] = zh
	f.close()
	print("[TranslationManager] 已加载 %d 条翻译" % _table.size())


## 单元格清洗：去 UTF-8 BOM / 回车 / 成对双引号；还原字面量 \n
func _clean_cell(raw: String) -> String:
	var s := raw.replace("\r", "").replace("\uFEFF", "").strip_edges()
	if s.length() >= 2 and s.begins_with("\"") and s.ends_with("\""):
		s = s.substr(1, s.length() - 2).replace("\"\"", "\"")
	return s.replace("\\n", "\n")


## 取当前语言的翻译；缺失 → 回退简体中文(key)；未知 key → 原样返回
func t(key: String) -> String:
	return t_lang(key, current_lang)


## 取指定语言的翻译（不改变当前语言，用于"预览指定语言"）。缺失 → 回退简体中文；未知 → 原样。
func t_lang(key: String, lang: String) -> String:
	if key.is_empty():
		return ""
	var row: Dictionary = _table.get(key, {})
	if row.is_empty():
		return key
	var v: String = str(row.get(lang, ""))
	if v.is_empty():
		v = str(row.get("zh_CN", ""))      # 回退简体中文
	if v.is_empty():
		v = key
	return v


## 把「任意语言的已显示文字」换算回简体中文 key；查不到就原样返回
func to_key(shown: String) -> String:
	return str(_reverse.get(shown, shown))


## 把已构建好的 UI 子树整体重译成当前语言。
## 原理：节点上显示的文字必然是某种语言的译文 → 用 _reverse 反查回简体中文 key
##       → 再用 t_lang() 取目标语言的译文。表里查不到的文字（玩家输入、动态数字等）原样保留。
func retranslate_tree(root: Node) -> void:
	retranslate_tree_lang(root, current_lang)


## 按"指定语言"重译整个子树（用于语言预览：不改当前语言，只把界面文字换成目标语言的译文）
func retranslate_tree_lang(root: Node, lang: String) -> void:
	if root == null or not is_instance_valid(root):
		return
	_retranslate_node(root, lang)
	for child in root.get_children():
		retranslate_tree_lang(child, lang)


func _retranslate_node(n: Node, lang: String) -> void:
	# UIBtn 是自绘按钮，文字在 label_node 上，必须走 set_label() 才会重排
	# ★ 判据顺序：is_instance_valid(n) 必须排最前（`is` 作用于已释放实例 = use-after-free）；
	#   label_node 同理用 is_instance_valid 而不是 `!= null`（对已释放实例 `!= null` 仍可能为真）。
	if is_instance_valid(n) and n is UIBtn and is_instance_valid(n.label_node):
		var b: UIBtn = n
		var newtext: String = t_lang(to_key(b.label_node.text), lang)
		if newtext != b.label_node.text:
			b.set_label(newtext)
		return
	if n is Label:
		var l: Label = n
		var newtext: String = t_lang(to_key(l.text), lang)
		if newtext != l.text:
			l.text = newtext
		return
	# ★★ OptionButton 必须排在 Button 之前：它**继承自 Button**，写成 `is Button` 先判，
	#   这一支永远不会执行 → 所有下拉项的文本都不跟随语言（批次67 定位到的根因）。
	if n is OptionButton:
		var ob: OptionButton = n
		for i in ob.item_count:
			var txt: String = ob.get_item_text(i)
			var nt: String = t_lang(to_key(txt), lang)
			if nt != txt:
				ob.set_item_text(i, nt)
		return
	if n is Button or n is CheckBox:
		var btn: Button = n
		var newtext: String = t_lang(to_key(btn.text), lang)
		if newtext != btn.text:
			btn.text = newtext
		return
	if n is LineEdit:
		var le: LineEdit = n
		if not le.placeholder_text.is_empty():
			le.placeholder_text = t_lang(to_key(le.placeholder_text), lang)
		return


## 切换语言：更新当前语言 + 广播（持久化暂由上层决定，本单例不落盘）
func set_lang(lang: String) -> void:
	if not (lang in LANG_CODES):
		push_warning("[TranslationManager] 未知语言: %s" % lang)
		return
	if lang == current_lang:
		return
	current_lang = lang
	language_changed.emit(lang)


## 语言代码 → 显示名
func get_lang_name(lang: String) -> String:
	var idx: int = LANG_CODES.find(lang)
	if idx >= 0:
		return str(LANG_NAMES[idx])
	return lang