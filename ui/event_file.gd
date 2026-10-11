# ui/event_file.gd
# 事件链 · 数据模型与落盘（纯静态工具）。
#
# 目录约定（res://events = 游戏本体事件根目录）：
#   res://events/<事件链名>/              一个子文件夹 = 一条事件链
#        <事件名>.json                    事件脚本（见 §2.2 计划书 Schema v1）
#        <文件名>_zh_CN.txt / _zh_TW.txt / _en.txt   多语言文本（(修饰)[文本]）
#
# 原则：
#   - json 里只写"逻辑文件名"（不含语言、不含扩展名）；
#   - 运行时/编辑器按语言组出 <逻辑名>_<lang>.txt；缺失回退 zh_CN → 空。
#   - 本阶段只负责读写一致性，执行（EventChainRunner）在阶段二。
class_name EventFile
extends RefCounted

const ROOT := "res://events"
const LANG_CODES: Array = ["zh_CN", "zh_TW", "en"]   # 须与 TranslationManager.LANG_CODES 一致

# 扩展名
const JSON_EXT := ".json"
const TXT_EXT := ".txt"


# ---------------- 目录 / 路径 ----------------

static func chain_dir(chain: String) -> String:
	return ROOT.path_join(chain)

static func chain_exists(chain: String) -> bool:
	return not chain.is_empty() and DirAccess.dir_exists_absolute(chain_dir(chain))

# 若事件链目录不存在则递归创建；返回链目录绝对路径。
static func ensure_chain(chain: String) -> String:
	var p := chain_dir(chain)
	if not DirAccess.dir_exists_absolute(p):
		DirAccess.make_dir_recursive_absolute(p)
	return p


# ---------------- 枚举（编辑器下拉选项用） ----------------

# 列出所有事件链（res://events 下的子目录名），按名称排序；目录不存在 → 空数组。
# ★ 只在「点开下拉」那一刻调用，避免启动时就遍历磁盘。
static func list_chains() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(ROOT)
	if dir == null:
		return out
	for d in dir.get_directories():
		if d.begins_with("."):
			continue   # 跳过隐藏目录
		out.append(d)
	out.sort()
	return out


# 列出某事件链下的事件名（<chain>/*.json 去掉扩展名），按名称排序；链不存在 → 空数组。
static func list_event_names(chain: String) -> Array[String]:
	var out: Array[String] = []
	if chain.is_empty():
		return out
	var dir := DirAccess.open(chain_dir(chain))
	if dir == null:
		return out
	for f in dir.get_files():
		if not f.ends_with(JSON_EXT) or f.begins_with("."):
			continue
		var stem := f.substr(0, f.length() - JSON_EXT.length())
		# ★ 事件链配置文件（config.json）不是事件，绝不能当成事件名列出。
		if stem == CHAIN_CONFIG_STEM:
			continue
		out.append(stem)
	out.sort()
	return out


# ---------------- 事件链配置 ----------------

# 事件链配置文件：<事件链目录>/config.json（供其他系统检测该链的触发方式）。
# 结构：
#   { "version": 1, "chain": "<链名>",
#     "trigger_event": "<触发事件>", "trigger_condition": "<触发条件>", "weight": 1.0 }
const CHAIN_CONFIG_STEM := "config"
const CHAIN_CONFIG_VERSION: int = 1

static func chain_config_path(chain: String) -> String:
	return chain_dir(chain).path_join(CHAIN_CONFIG_STEM + JSON_EXT)

# 读事件链配置；不存在 / 解析失败 / 非字典 → 空 Dictionary（调用方用默认值兜底）。
static func read_chain_config(chain: String) -> Dictionary:
	if chain.is_empty():
		return {}
	var p := chain_config_path(chain)
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parser := JSON.new()
	if parser.parse(txt) != OK:
		return {}
	if typeof(parser.data) != TYPE_DICTIONARY:
		return {}
	return parser.data

# 写（覆盖）事件链配置到 <链名>/config.json；返回 OK 或错误码。
static func write_chain_config(chain: String, data: Dictionary) -> Error:
	if chain.is_empty():
		return ERR_INVALID_PARAMETER
	ensure_chain(chain)
	var bytes := (JSON.stringify(data, "\t") + "\n").to_utf8_buffer()
	var f := FileAccess.open(chain_config_path(chain), FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(bytes)
	f.close()
	return OK


# ---------------- JSON 事件脚本 ----------------

static func script_path(chain: String, name: String) -> String:
	return chain_dir(chain).path_join(name + JSON_EXT)

# 读事件脚本：返回 Dictionary；文件不存在/解析失败 → null。
static func read_script(chain: String, name: String) -> Variant:
	var p := script_path(chain, name)
	if not FileAccess.file_exists(p):
		return null
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return null
	var txt := f.get_as_text()
	f.close()
	var parser := JSON.new()
	if parser.parse(txt) != OK:
		return null
	if typeof(parser.data) != TYPE_DICTIONARY:
		return null
	return parser.data


# 写（覆盖）事件脚本到 <chain>/<name>.json；返回 OK 或错误码。
static func write_script(chain: String, name: String, data: Dictionary) -> Error:
	if chain.is_empty() or name.is_empty():
		return ERR_INVALID_PARAMETER
	ensure_chain(chain)
	var bytes := (JSON.stringify(data, "\t") + "\n").to_utf8_buffer()
	var f := FileAccess.open(script_path(chain, name), FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(bytes)
	f.close()
	return OK


# ---------------- txt 多语言文本 ----------------

# 逻辑文件名 → 实际语言文件路径（不校验存在性）
static func txt_path(dir: String, logical: String, lang: String) -> String:
	return dir.path_join("%s_%s%s" % [logical, lang, TXT_EXT])


# 读指定语言文本：先试 lang，回退 zh_CN，再回退空串。文件不存在 → ""。
static func read_txt(dir: String, logical: String, lang: String) -> String:
	if logical.is_empty():
		return ""
	for cand in _fallback_sequence(lang):
		var p := txt_path(dir, logical, cand)
		if FileAccess.file_exists(p):
			return FileAccess.get_file_as_string(p)
	return ""


# 写（覆盖）指定语言文本（UTF-8 无 BOM）；返回 OK 或错误码。
static func write_txt(dir: String, logical: String, lang: String, content: String) -> Error:
	if logical.is_empty() or lang.is_empty():
		return ERR_INVALID_PARAMETER
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(txt_path(dir, logical, lang), FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(content)
	f.close()
	return OK


# ---------------- txt 多语言文本（正文 + 按钮文字小节） ----------------
#
# 为什么按钮文字也要进 txt：
#   按钮文字和正文一样是「要跟着语言变」的内容。以前它只存在 <事件名>.json 的
#   buttons[].label 里，json 是**单份、不分语言**的 → 切语言时正文变了、按钮还是老语言。
#   现在约定：按钮文字写进**同一份** <逻辑名>_<lang>.txt，跟在正文后面，每行一个：
#
#       (#ffffffL)["你好啊，初次见面"]
#
#       @button b1 = (#ffffffL)[“下一句”]
#       @button b2 = (#ffffffL)[“结束”]
#
#   json 里的 label 保留为**回退值**（老数据 / txt 里没写这一行时用）。

# 按钮小节的行首标记（必须是行首、后跟空白）。
const BUTTON_LINE_PREFIX := "@button"

# 把一份 <逻辑名>_<lang>.txt 拆成「正文 + 按钮文字表」。
# 返回 { "body": String, "buttons": Dictionary }（buttons: id(String) -> 定义(String)）。
# ★ 向后兼容：老 txt 里一行 @button 都没有 → body = 原文（仅去掉尾部空行），buttons = {}。
static func parse_localized(raw: String) -> Dictionary:
	var body_lines := PackedStringArray()
	var buttons: Dictionary = {}
	for line in raw.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with(BUTTON_LINE_PREFIX):
			var rest := trimmed.substr(BUTTON_LINE_PREFIX.length())
			# ★ 必须以空白续接才算按钮行：否则正文里的 "@buttons" 之类会被误吃。
			if rest.is_empty() or rest.begins_with(" ") or rest.begins_with("\t"):
				var eq := rest.find("=")
				if eq >= 0:
					var bid := rest.substr(0, eq).strip_edges()
					if not bid.is_empty():
						buttons[bid] = rest.substr(eq + 1).strip_edges()
						continue   # 这一行是按钮声明，不进正文
		body_lines.append(line)
	# 正文尾部空行是剥离按钮行留下的，抹掉；中间空行（正文自己的换行）保留。
	while not body_lines.is_empty() and body_lines[body_lines.size() - 1].strip_edges().is_empty():
		body_lines.remove_at(body_lines.size() - 1)
	return { "body": "\n".join(body_lines), "buttons": buttons }


# 反过来拼：正文 + 空行 + 若干 @button 行（按 id 排序，避免每次保存 diff 抖动）。
# buttons 为空 → 原样返回正文（这样「没按钮的 txt」与老格式逐字节一致）。
static func build_localized(body: String, buttons: Dictionary) -> String:
	if buttons.is_empty():
		return body
	var out := body
	if not out.is_empty() and not out.ends_with("\n"):
		out += "\n"
	out += "\n"
	var ids: Array = buttons.keys()
	ids.sort()
	for id in ids:
		out += "%s %s = %s\n" % [BUTTON_LINE_PREFIX, str(id), str(buttons[id])]
	return out


# 读指定语言 txt 并解析 → { body, buttons }；文件不存在 → { body="", buttons={} }。
static func read_localized(dir: String, logical: String, lang: String) -> Dictionary:
	return parse_localized(read_txt(dir, logical, lang))


# 写指定语言 txt（正文 + 按钮小节）；返回 OK 或错误码。
static func write_localized(dir: String, logical: String, lang: String, body: String, buttons: Dictionary) -> Error:
	return write_txt(dir, logical, lang, build_localized(body, buttons))


# 语言尝试顺序：lang（若非空）→ 回退 zh_CN
static func _fallback_sequence(lang: String) -> Array:
	if lang.is_empty():
		return ["zh_CN"]
	if lang == "zh_CN":
		return ["zh_CN"]
	return [lang, "zh_CN"]


# ---------------- close / open 目标 ----------------

# 【open】列表里的特殊目标 "auto" = 「正文对应的对话框」：
#   打开/关闭哪一个面板，由 content.panel_type 决定（popup → 弹窗，bottom → 底部）。
#
# 为什么需要它（用户报的 bug）：
#   以前「有没有正文」与「弹不弹面板」是同一件事 —— 只要 content.panel_type 写了 popup/bottom，
#   运行器就顺手把面板显示出来。于是编辑器里【4】打开的目标留空，面板照样弹出来，
#   「删掉打开项」这件事毫无意义。
#   现在两者彻底分开：content 只负责**写内容**，open 才负责**显不显示**。
#     · json 里**没有 open 键**（迁移前的老脚本）→ 按 ["auto"] 处理，历史行为不变；
#     · 显式写 "open": []（编辑器里删掉那条 auto）→ 什么都不打开，
#       正文依旧写进面板缓存（标题/台词/按钮都更新），但面板保持原样不弹。
const TARGET_AUTO := "auto"

# 取事件脚本的「打开目标」列表：缺 open 键 → 默认 ["auto"]（老脚本行为与今天一致）。
static func open_targets(data: Dictionary) -> Array:
	if not data.has("open"):
		return [TARGET_AUTO]
	var v: Variant = data.get("open")
	if v is Array:
		var arr: Array = v
		return arr
	return []


# ---------------- 校验 / 提示 ----------------

# 校验事件脚本 dict 是否符合基本结构；返回错误描述，合法返回 ""。
static func validate(data: Dictionary) -> String:
	if not data.has("content") or not (data["content"] is Dictionary):
		return "缺少 content（正文）"
	var c: Dictionary = data["content"]
	var pt: String = str(c.get("panel_type", ""))
	# "" = 「无修改」：该事件不改动正文/面板（合法；事件编辑器里是默认项）
	if pt != "" and pt != "popup" and pt != "bottom" and pt != "bubble" and pt != "notification":
		return "content.panel_type 非法: %s（应为 空(无修改)/popup/bottom/bubble/notification）" % pt
	if data.has("buttons") and not (data["buttons"] is Array):
		return "buttons 应为数组"
	return ""