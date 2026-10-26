# dialogue_manager.gd
# 对话系统全局变量管理器（autoload 单例）。
#
# 设计核心：把对话相关的「8 个栏」做成全局变量。
# 未来事件链的原理 = 不断覆盖这 8 个变量；对应的对话面板（底部 / 弹窗）
# 始终显示这些变量的当前值。所以面板只负责「显示」，写值由事件链完成。
#
# 变量分两组：
#   底部对话面板 4 栏：line_text / avatar_path / character_name / bottom_buttons
#   弹窗对话面板 4 栏：event_name / event_image_path / event_content / popup_buttons
# 另加 1 个语音配置：voice（"auto" = 逐字/逐词泡泡声；"auto:路径" = 同上但换成该音频；或声音文件相对路径 = 整段播）
# 另加 2 个显隐开关：bottom_visible / popup_visible
# 另预留「冒泡对话」字段：bubble_text / bubble_visible（未来扩展用，暂不参与显示）
# 另加 line_text_def：台词「原始定义」（含 (修饰) / $变量 / #停顿），供台词音效与显示渲染使用。
#   直接写 line_text 时它会被清空；事件链写台词走 set_line_definition()（两个都给）。
# 注意：不要在此写 class_name DialogueManager。
# 该脚本是名为 DialogueManager 的 autoload 单例；若再声明同名 class_name，
# GDScript 会把裸名 DialogueManager 解析成「类类型」而非单例实例，
# 导致所有 DialogueManager.xxx 成员访问报「找不到成员 / 不能对类直接调用非静态函数」。
extends Node

# ===================== 底部对话面板 4 个栏 =====================
var _line_text: String = ""           # 中心的台词栏
var _line_text_def: String = ""        # 台词「原始定义」（含修饰/$变量/#停顿）；空 = 用 line_text 本身
var _avatar_path: String = ""          # 左侧头像栏（图片路径，预留加载为纹理）
var _avatar_background_path: String = "" # 头像背景层（图片路径；头像透明处透出背景；空 = 不绘制背景）
var _character_name: String = ""       # 头像栏下的角色名称栏
var _bottom_buttons: Array = []        # 右侧按钮选择栏（元素: {"label":String,"id":String}）
var _voice: String = ""                # 台词语音："auto"=逐字/逐词泡泡声；"auto:路径"=同上换声源；路径=整段播；空=不发声
var _line_effect: String = ""          # 点击该台词时执行的「效果」（DSL 串，与按钮 effect 同源）

# ===================== 弹窗对话面板 4 个栏 =====================
var _event_name: String = ""           # 顶部事件名称栏
var _event_image_path: String = ""     # 事件配图栏（图片路径，预留加载为纹理）
var _event_content: String = ""        # 事件内容栏
var _popup_buttons: Array = []         # 底部按钮选择栏（元素: {"label":String,"id":String}）

# ===================== 面板显隐（true = 显示）=====================
var _bottom_visible: bool = false
var _popup_visible: bool = false

# ===================== 冒泡对话 预留（未来扩展，暂不使用）=====================
var _bubble_text: String = ""
var _bubble_visible: bool = false

# 变量变化信号：name 为变量名，value 为新值
signal variable_changed(name: String, value: Variant)
# 面板显隐信号：panel 为 "bottom" / "popup" / "bubble"
signal panel_visibility_changed(panel: String, visible: bool)
# 对话面板内按钮被按下：panel 为目标面板名，id 为按钮 id（事件链未来接管）
signal dialogue_button_pressed(panel: String, id: String)


# ---------------- 底部面板属性 ----------------
var line_text: String:
	get:
		return _line_text
	set(v):
		_line_text = v
		# 直接写台词 = 以它自身为唯一来源（事件链写台词走 set_line_definition，会另存原始定义）
		_line_text_def = ""
		variable_changed.emit("line_text", v)

# 台词「原始定义」（只读）：优先代表 (修饰)[...] 的完整定义，供台词音效解析与显示渲染
var line_text_def: String:
	get:
		return _line_text_def

# 音效解析 / 显示渲染的唯一取用口：优先用原始定义，否则用 line_text
func line_source() -> String:
	return _line_text_def if not _line_text_def.is_empty() else _line_text


# 事件链专用：同时给出「原始定义」与「已解析纯文本（仅作兜底显示）」。
# def 含 (修饰)/["字符串"]/$变量/#停顿；resolved 是 $变量 已被替换后的纯文本。
func set_line_definition(def: String, resolved: String) -> void:
	_line_text_def = def
	_line_text = resolved
	variable_changed.emit("line_text_def", def)
	variable_changed.emit("line_text", resolved)

# 台词语音配置
var voice: String:
	get:
		return _voice
	set(v):
		_voice = v
		variable_changed.emit("voice", v)

var avatar_path: String:
	get:
		return _avatar_path
	set(v):
		_avatar_path = v
		variable_changed.emit("avatar_path", v)

# 头像背景层：头像透明的部分透出这一层；空 = 不绘制任何背景
var avatar_background_path: String:
	get:
		return _avatar_background_path
	set(v):
		_avatar_background_path = v
		variable_changed.emit("avatar_background_path", v)

var character_name: String:
	get:
		return _character_name
	set(v):
		_character_name = v
		variable_changed.emit("character_name", v)

var bottom_buttons: Array:
	get:
		return _bottom_buttons
	set(v):
		_bottom_buttons = v if v is Array else []
		variable_changed.emit("bottom_buttons", _bottom_buttons)


# 点击台词时执行的效果（DSL 串）；与事件链按钮 effect 同源，保证「点击台词」与「按钮」一致
var line_effect: String:
	get:
		return _line_effect
	set(v):
		_line_effect = str(v)
		variable_changed.emit("line_effect", _line_effect)


# ---------------- 弹窗面板属性 ----------------
var event_name: String:
	get:
		return _event_name
	set(v):
		_event_name = v
		variable_changed.emit("event_name", v)

var event_image_path: String:
	get:
		return _event_image_path
	set(v):
		_event_image_path = v
		variable_changed.emit("event_image_path", v)

var event_content: String:
	get:
		return _event_content
	set(v):
		_event_content = v
		variable_changed.emit("event_content", v)

var popup_buttons: Array:
	get:
		return _popup_buttons
	set(v):
		_popup_buttons = v if v is Array else []
		variable_changed.emit("popup_buttons", _popup_buttons)


# ---------------- 面板显隐 ----------------
var bottom_visible: bool:
	get:
		return _bottom_visible
	set(v):
		_bottom_visible = v
		panel_visibility_changed.emit("bottom", v)

var popup_visible: bool:
	get:
		return _popup_visible
	set(v):
		_popup_visible = v
		panel_visibility_changed.emit("popup", v)


# ---------------- 冒泡对话 预留 ----------------
var bubble_text: String:
	get:
		return _bubble_text
	set(v):
		_bubble_text = v
		variable_changed.emit("bubble_text", v)

var bubble_visible: bool:
	get:
		return _bubble_visible
	set(v):
		_bubble_visible = v
		panel_visibility_changed.emit("bubble", v)


# ===================== 语言重贴（不记重复台词）=====================
# ★ 玩家切语言时，事件链执行器会用新语言的 txt 把正文/按钮**重新贴一遍**。
#   那是「把同一句话换个语言再说一遍」，不是「又说了一句新台词」——
#   若不管，台词记录里会平白多出一条。执行器在这段窗口里把它置为 true，
#   面板据此跳过 DialogueLog.record_line / record_button。
#   （用显式 begin/end 而不是靠时间戳：中间发生的 emit 是同步的，窗口必须精确。）
var _restating: bool = false


func begin_restate() -> void:
	_restating = true


func end_restate() -> void:
	_restating = false


func is_restating() -> bool:
	return _restating


# ===================== 通用读写（供调试面板/外部以字符串键访问）=====================
func set_value(name: String, value: Variant) -> void:
	match name:
		"line_text":
			line_text = value
		"avatar_path":
			avatar_path = value
		"avatar_background_path":
			avatar_background_path = value
		"character_name":
			character_name = value
		"bottom_buttons":
			bottom_buttons = value if value is Array else []
		"line_effect":
			line_effect = str(value)
		"voice":
			voice = str(value)
		"event_name":
			event_name = value
		"event_image_path":
			event_image_path = value
		"event_content":
			event_content = value
		"popup_buttons":
			popup_buttons = value if value is Array else []
		"bubble_text":
			bubble_text = value


func get_value(name: String) -> Variant:
	match name:
		"line_text":
			return line_text
		"avatar_path":
			return avatar_path
		"avatar_background_path":
			return avatar_background_path
		"character_name":
			return character_name
		"bottom_buttons":
			return bottom_buttons
		"line_effect":
			return line_effect
		"voice":
			return voice
		"event_name":
			return event_name
		"event_image_path":
			return event_image_path
		"event_content":
			return event_content
		"popup_buttons":
			return popup_buttons
		"bubble_text":
			return bubble_text
	return null


# 8 个栏变量名清单（便于遍历/调试）
static func bar_names() -> PackedStringArray:
	return PackedStringArray([
		"line_text", "avatar_path", "character_name", "bottom_buttons",
		"event_name", "event_image_path", "event_content", "popup_buttons"
	])


# 面板内 UIBtn 按下后转发（事件链未来接管 dialogue_button_pressed）
func emit_button(panel: String, id: String) -> void:
	dialogue_button_pressed.emit(panel, id)
