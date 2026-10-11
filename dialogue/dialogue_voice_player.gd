# dialogue/dialogue_voice_player.gd
# 台词音效播放器 —— 把 DialogueVoice 解析出的「语音事件序列」变成声音。
#
# 三种模式（由 voice 属性决定，见 DialogueManager.voice）：
#   ① voice = "auto"          → 用 bubble_pop 逐字 / 逐词播放「泡泡声」
#   ② voice = "auto:路径"     → 逐字 / 逐词播放，但把泡泡声换成该音频文件
#                               （节奏、随机音量/音高、标点加重、$变量一声、# 停顿——全与 ① 相同）
#   ③ voice = 声音文件相对路径 → 不论台词多少，只播这一个文件，播完为止。
#
# 泡泡声的细节：
#   · 每个字 / 词一声，字 / 词之间有 0.06s 基础间隔；
#   · 每一声的音量（±3dB）与长短（音高 0.92~1.08 倍，越低越长）都做小幅随机波动；
#   · 标点处特殊处理：音量 +4dB、音高 ×0.84（更低 → 更长，更像「顿一下」）；
#   · $变量 无论值多长，只响一声；
#   · # / #*N 停顿 0.1s × N（不出声）。
#
# 音量：跟随设置页「语音音量」滑条（settings.json 的 volumes.语音音量）；
#       滑条为 0 → 静音。找不到设置时用 DEFAULT_VOICE_VOLUME。
#
# ★ 不引用任何 autoload 全局名：设置走「主循环 root 按节点名取 SaveManager」，便于 `--script` 探针复用。
#   初始化是惰性的（_ensure_init 幂等），即使 _ready 未跑（探针 / 手工 new）也能正常播。
# 音频格式选择：用 WAV（res://audio/bubble_pop.wav）。理由是泡泡声要密集叠加触发，
#   WAV 无压缩、进内存即可播，不用解码等待，最不会在连发时卡顿；0.9s 单声道体积可忽略。
class_name DialogueVoicePlayer
extends Node

const BUBBLE_POP := "res://audio/bubble_pop.wav"
const AUTO := "auto"                    # voice = auto → 泡泡声
const AUTO_PREFIX := "auto:"            # voice = auto:路径 → 逐字/逐词，但声源换成该文件
const VOICE_VOLUME_KEY := "语音音量"     # settings.json volumes 里的键（与设置页滑条一致）

const POOL_SIZE := 8                    # 同时可叠加的泡泡播放器数量
const POP_GAP := 0.06                   # 相邻泡泡的基础间隔（秒）
const DEFAULT_VOICE_VOLUME := 0.85      # 与设置页「语音音量」默认值一致（settings_panel.SOUND_ROWS）
const MIN_DB := -80.0

# 随机波动
const PITCH_MIN := 0.92
const PITCH_MAX := 1.08
const DB_JITTER := 3.0                  # ±3dB

# 标点特殊处理
const PUNCT_BONUS_DB := 4.0             # 更响
const PUNCT_PITCH := 0.84               # 音高更低 → 播放更长

## 一次播放结束（泡泡序列放完 / 语音文件播完）
signal playback_finished

var _pool: Array[AudioStreamPlayer] = []
var _cursor := 0
var _bubble: AudioStream = null
var _file_player: AudioStreamPlayer = null
## 本次 pop 模式实际使用的「一声」音频：默认泡泡声；voice = "auto:路径" 时换成该文件。
## ★ 只影响声源，不影响任何播放参数（间隔/随机/标点/变量/停顿都走原逻辑）。
var _pop_stream: AudioStream = null

var _mode := ""                          # "" | "pop" | "file"
var _playing := false
var _pending: Array = []                 # 待播事件队列
var _timer := 0.0                        # 下一个事件前的等待
# 上次播放参数（replay 用）
var _last_voice := ""
var _last_def := ""
var _last_lang := "zh_CN"
# 音量覆盖（<0 = 跟随设置）
var _volume_override := -1.0


func _ready() -> void:
	_ensure_init()
	set_process(false)


## 惰性初始化（幂等）：_ready 之前被调用、或 `--script` 探针里没跑 _ready 时也能正常工作。
func _ensure_init() -> void:
	if _bubble == null:
		_bubble = load_stream(BUBBLE_POP)
	if _pool.is_empty():
		for i in POOL_SIZE:
			var p := AudioStreamPlayer.new()
			p.name = "Pop%d" % i
			if _bubble != null:
				p.stream = _bubble
			add_child(p)
			_pool.append(p)
	if _file_player == null:
		_file_player = AudioStreamPlayer.new()
		_file_player.name = "VoiceFile"
		_file_player.finished.connect(_on_file_finished)
		add_child(_file_player)


# ==================== 对外接口 ====================

## 播放台词音效。
##   voice 空串            → 不发声；
##   "auto"                → 用默认泡泡声逐字/逐词；
##   "auto:相对路径"       → 同上，但把泡泡声换成该文件；
##   其它（相对路径）      → 按相对路径整段播文件。
func play(voice: String, def: String, lang: String) -> void:
	_ensure_init()
	stop()
	_last_voice = voice
	_last_def = def
	_last_lang = lang
	var cfg := resolve_voice(voice)
	var mode := str(cfg.get("mode", "silent"))
	var path := str(cfg.get("path", ""))
	if mode == "silent":
		print("[DialogueVoice] 未配置语音，静默（line=%s）" % _short(def))
		return
	if mode == "file":
		_play_file(path)
		return
	# ---- pop 模式：逐字 / 逐词 ----
	_pop_stream = load_stream(path)
	if _pop_stream == null:
		push_warning("[DialogueVoice] 泡泡声文件无法加载：%s（退回默认泡泡声）" % path)
		_pop_stream = _bubble
	if _pop_stream == null:
		return
	var parsed: Dictionary = DialogueVoice.parse(def, lang)
	_pending = parsed.get("events", [])
	if _pending.is_empty():
		return
	_mode = "pop"
	_playing = true
	_timer = 0.0
	set_process(true)
	print("[DialogueVoice] 播放泡泡声：字/词=%d 语言=%s 声源=%s" % [_pending.size(), lang, path])


## 解析 voice 配置 → { "mode": "silent"|"pop"|"file", "path": String }
## ★ 单独成函数（纯函数、不碰状态）：便于断言，也让调用方（未来其它对话面板 / 探针）
##   能先问一句「这句到底怎么播、用哪个文件」。
##   ""            → silent
##   "auto"        → pop + 默认泡泡声
##   "auto:路径"   → pop + 该文件（"auto:" 后面没给路径 → 退回默认泡泡声）
##   其它          → file
func resolve_voice(voice: String) -> Dictionary:
	var v := voice.strip_edges()
	if v.is_empty():
		return { "mode": "silent", "path": "" }
	if v == AUTO:
		return { "mode": "pop", "path": BUBBLE_POP }
	if v.begins_with(AUTO_PREFIX):
		var p := v.substr(AUTO_PREFIX.length()).strip_edges()
		if p.is_empty():
			return { "mode": "pop", "path": BUBBLE_POP }
		return { "mode": "pop", "path": p }
	return { "mode": "file", "path": v }


## 用上次的参数重播（停止当前音频 → 从头播）
func replay() -> void:
	play(_last_voice, _last_def, _last_lang)


## 停止当前音频并清空队列
func stop() -> void:
	_pending.clear()
	_timer = 0.0
	_playing = false
	_mode = ""
	set_process(false)
	for p in _pool:
		if p != null and is_instance_valid(p):
			p.stop()
	if _file_player != null and is_instance_valid(_file_player):
		_file_player.stop()


func is_playing() -> bool:
	return _playing


## 手动覆盖音量（线性 0~1）；传 -1 恢复「跟随设置」
func set_volume_override(v: float) -> void:
	_volume_override = v


# ==================== 内部 ====================

func _process(delta: float) -> void:
	if not _playing:
		set_process(false)
		return
	if _mode == "file":
		return   # 由 finished 信号收尾
	_timer -= delta
	while _timer <= 0.0 and not _pending.is_empty():
		var ev: Dictionary = _pending.pop_front()
		_fire(ev)
		if str(ev.get("type", "")) == DialogueVoice.EV_PAUSE:
			_timer += float(ev.get("seconds", 0.0))
		else:
			_timer += POP_GAP
	if _pending.is_empty() and _timer <= 0.0:
		_finish()


func _fire(ev: Dictionary) -> void:
	match str(ev.get("type", "")):
		DialogueVoice.EV_POP:
			_pop(bool(ev.get("punct", false)))
		DialogueVoice.EV_VAR:
			_pop(false)          # 变量：不管值多长，只响一声
		_:
			pass                 # 停顿：不出声


## 播一声泡泡（punct=true 时更响更长）
## ★ 声源用本次 pop 模式解析出的 _pop_stream（"auto:路径" 时就是那个文件），其余参数一律不变。
func _pop(punct: bool) -> void:
	var s: AudioStream = _pop_stream if _pop_stream != null else _bubble
	if s == null:
		return
	var p := _next_player()
	if p == null:
		return
	p.stream = s
	var params := pop_params(punct)
	p.pitch_scale = float(params["pitch"])
	p.volume_db = float(params["db"])
	p.play()


## 计算一声泡泡的参数 { "pitch": float, "db": float }（纯函数，便于验证）。
## punct=true → 音量 +PUNCT_BONUS_DB、音高 ×PUNCT_PITCH（更低 = 更长）。
func pop_params(punct: bool) -> Dictionary:
	var pitch := randf_range(PITCH_MIN, PITCH_MAX)
	var db := randf_range(-DB_JITTER, DB_JITTER)
	if punct:
		pitch *= PUNCT_PITCH
		db += PUNCT_BONUS_DB
	return {
		"pitch": clampf(pitch, 0.25, 4.0),
		"db": clampf(_base_db() + db, MIN_DB, 24.0),
	}


func _next_player() -> AudioStreamPlayer:
	_ensure_init()
	if _pool.is_empty():
		return null
	for i in _pool.size():
		var idx := (_cursor + i) % _pool.size()
		if not _pool[idx].playing:
			_cursor = (idx + 1) % _pool.size()
			return _pool[idx]
	var p := _pool[_cursor]
	_cursor = (_cursor + 1) % _pool.size()
	return p


func _play_file(path: String) -> void:
	_ensure_init()
	var s := load_stream(path)
	if s == null:
		push_warning("[DialogueVoice] 语音文件无法加载：%s" % path)
		return
	_file_player.stream = s
	_file_player.volume_db = clampf(_base_db(), MIN_DB, 24.0)
	_file_player.play()
	_mode = "file"
	_playing = true
	set_process(true)
	print("[DialogueVoice] 播放语音文件：%s（%.2fs）" % [path, s.get_length()])


func _on_file_finished() -> void:
	if _mode == "file":
		_finish()


func _finish() -> void:
	_playing = false
	_mode = ""
	set_process(false)
	playback_finished.emit()


## 加载音频流（不存在 / 不是 AudioStream → null）
func load_stream(path: String) -> AudioStream:
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	var r: Variant = load(path)
	if r is AudioStream:
		return r
	return null


## 线性音量 → dB（0 → 静音）
func _base_db() -> float:
	var lin: float = _voice_volume()
	if lin <= 0.0001:
		return MIN_DB
	return linear_to_db(lin)


## 当前生效的「语音音量」（线性 0~1）：优先用覆盖值，否则读设置页，缺省 0.85
func _voice_volume() -> float:
	if _volume_override >= 0.0:
		return clampf(_volume_override, 0.0, 1.0)
	# 用主循环的 root 按节点名取（不用绝对路径 get_node），使 `--script` 探针里也能取到
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var sm := (loop as SceneTree).root.get_node_or_null("SaveManager")
		if sm != null and sm.has_method("get_app_settings"):
			var s: Variant = sm.call("get_app_settings")
			if s is Dictionary:
				var vols: Variant = (s as Dictionary).get("volumes", {})
				if vols is Dictionary and (vols as Dictionary).has(VOICE_VOLUME_KEY):
					return clampf(float((vols as Dictionary)[VOICE_VOLUME_KEY]), 0.0, 1.0)
	return DEFAULT_VOICE_VOLUME


func _short(s: String) -> String:
	return s if s.length() <= 24 else s.substr(0, 24) + "…"
