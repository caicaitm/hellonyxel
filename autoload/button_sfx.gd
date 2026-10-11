# autoload/button_sfx.gd
# 全局按钮点击音效。所有 UIBtn 在 button_down 时调用 play_click()，
# 音量跟随设置页「音效音量」（settings.json 的 volumes.音效音量），0 → 静音。
#
# 资源用 click.wav（WAV 无压缩、进内存即播，连点不卡，与 dialogue_voice_player 选
# bubble_pop.wav 同理由）。
# ★ 池化：连点 / 同时触发多个按钮时，用一个小池轮流取空闲播放器，避免争抢同一个节点。
# ★ 只引用 SaveManager（它本身就是 autoload，引用安全），不依赖其它模块。
extends Node

const CLICK := "res://audio/click.wav"
const SFX_VOLUME_KEY := "音效音量"      # 与设置页滑条键一致（settings_panel.SOUND_ROWS）
const DEFAULT_SFX_VOLUME := 0.80        # 与设置页「音效音量」默认值一致
const MIN_DB := -80.0
const POOL_SIZE := 4

var _stream: AudioStream = null
var _pool: Array[AudioStreamPlayer] = []
var _cursor := 0


func _ready() -> void:
	_ensure_init()


## 惰性初始化（幂等）：_ready 之前被调用（手工 new / 探针）也能正常播。
func _ensure_init() -> void:
	if _stream == null and ResourceLoader.exists(CLICK):
		var r: Variant = load(CLICK)
		if r is AudioStream:
			_stream = r
	if _pool.is_empty():
		for i in POOL_SIZE:
			var p := AudioStreamPlayer.new()
			p.name = "Click%d" % i
			if _stream != null:
				p.stream = _stream
			add_child(p)
			_pool.append(p)


## 播放一次点击音效（音量跟随「音效音量」）。
func play_click() -> void:
	_ensure_init()
	if _stream == null:
		return
	var p := _next_player()
	if p == null:
		return
	p.volume_db = _base_db()
	p.pitch_scale = 1.0
	p.play()


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


## 线性音量 → dB（0 → 静音）
func _base_db() -> float:
	var lin: float = _sfx_volume()
	if lin <= 0.0001:
		return MIN_DB
	return linear_to_db(lin)


## 当前生效的「音效音量」（线性 0~1）：读设置页，缺省 0.80
func _sfx_volume() -> float:
	if SaveManager != null and SaveManager.has_method("get_app_settings"):
		var s: Variant = SaveManager.get_app_settings()
		if s is Dictionary:
			var vols: Variant = (s as Dictionary).get("volumes", {})
			if vols is Dictionary and (vols as Dictionary).has(SFX_VOLUME_KEY):
				return clampf(float((vols as Dictionary)[SFX_VOLUME_KEY]), 0.0, 1.0)
	return DEFAULT_SFX_VOLUME
