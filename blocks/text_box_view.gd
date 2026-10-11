# text_box_view.gd
# 积木文本框的「视图节点」——文本框显示的完全重做版。
#
# ── 为什么重做 ──────────────────────────────────────────────
# 旧版：文本框在 Block._draw() 里用 draw_colored_polygon / draw_string_outline 手工绘制。
#       问题：绘制依附于父级 _draw（受提前 return、重绘时机、自定义变换影响），
#       出错时画面全无但日志未必报错，极难排查。
# 新版：每个文本框 = 一个真实子节点（本类）。
#       背景 → Panel + StyleBoxFlat（填充/边框交给引擎样式系统，必定生效）
#       文字 → RichTextLabel + BBCode（颜色/对齐/自动换行交给引擎，必定生效）
#       优点：在「远程」场景树里能直接看到该节点与它的尺寸；
#             不再依赖任何手工 _draw，也不依赖父级的绘制流程。
#
# ── 坐标与变换 ──────────────────────────────────────────────
# data.center_offset 是「相对积木中心」的偏移（见 text_box.gd 注释）。
# 本节点父级是 Block（Node2D），因此自动继承积木的位置/旋转/缩放。
#   position = center_offset - size/2   （Control 的 position 是左上角）
#   pivot_offset = size/2               （绕自身中心旋转）
# 旋转：
#   follow_block_rotation = true  → rotation = 自身角度（积木旋转由父级变换承担）
#   follow_block_rotation = false → rotation = 自身角度 - 积木旋转（保持世界轴向）
class_name TextBoxView
extends Control

const FONT_SIZE: int = 16
const OUTLINE_SIZE: int = 4
const PADDING: float = 6.0

var data: TextBox = null
# 拥有者积木。故意【不写 Block 类型】：
# block.gd 会引用 TextBoxView，若此处再引用 Block 就形成循环类引用（Godot 可能报 cyclic reference）。
# 用无类型变量后，block.tags / block.rotation / block.variable_resolver 走动态访问即可。
var block = null

var _bg: Panel
var _fill_img: TextureRect   # 填充图片（data.fill_image_path）；位于背景之上、文字之下
var _text: RichTextLabel
var _renderer := TextRenderer.new()
# 最近一次求值后「是否有可见文本」（供 hide_when_empty 判断），由 _to_bbcode 写入
var _had_visible_text: bool = false


func _ready() -> void:
	_apply()


# 外部注入数据后重新应用（Block.rebuild_text_boxes 调用）
func setup(tb: TextBox, owner_block) -> void:
	data = tb
	block = owner_block
	_apply()


func _build() -> void:
	if _bg != null:
		return
	# 本控件不接收鼠标：保证积木的拖动 / 右键仍然生效
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_bg = Panel.new()
	_bg.name = "Bg"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	# 填充图片：铺满整个文本框，等比缩放居中（TextRect 自带 STRETCH_KEEP_ASPECT_CENTERED）
	_fill_img = TextureRect.new()
	_fill_img.name = "FillImage"
	_fill_img.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fill_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fill_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_fill_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill_img.visible = false
	add_child(_fill_img)

	_text = RichTextLabel.new()
	_text.name = "Text"
	_text.set_anchors_preset(Control.PRESET_FULL_RECT)
	_text.offset_left = PADDING
	_text.offset_right = -PADDING
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.bbcode_enabled = true
	_text.scroll_active = false
	_text.fit_content = false
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.add_theme_font_size_override("normal_font_size", FONT_SIZE)
	_text.add_theme_color_override("default_color", UIStyle.TEXT_DEFAULT)
	# 黑描边：任意底色上都清晰可见（沿用 abandon 版经验）
	_text.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_text.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	var f := UIStyle.get_cjk_font()
	if f != null:
		_text.add_theme_font_override("normal_font", f)
	add_child(_text)


# 把 TextBox 数据完整应用到本视图（尺寸 / 位置 / 旋转 / 背景 / 文字 / 显隐）
func _apply() -> void:
	_build()
	if data == null:
		size = Vector2(1.0, 1.0)
		return

	# ---- 尺寸与位置（center_offset 相对积木中心）----
	size = Vector2(maxf(1.0, data.width), maxf(1.0, data.height))
	position = data.center_offset - size * 0.5
	pivot_offset = size * 0.5

	# ---- 旋转 ----
	var rot := deg_to_rad(data.rotation_deg)
	if not data.follow_block_rotation and block != null:
		rot -= block.rotation
	rotation = rot

	# ---- 背景（Panel + StyleBoxFlat）----
	var use_image_fill: bool = (data.fill_source == TextBox.FillSource.IMAGE) and data.fill_image_path != ""
	# ★ 真正把图片画出来：之前只把背景设成透明，纹理从没加载过 → 填了路径也什么都不显示。
	#   贴图缺失（路径错 / 文件不在）→ 关掉图片、回退成纯色背景，不让文本框变成空洞。
	# ★ 显式声明类型：写成 `var tex := ... if ... else null` 会因「从 Variant 推断」
	#   触发 WARNING-treated-as-error（本项目把警告当错误）。
	var tex: Texture2D = null
	if use_image_fill:
		tex = TextureCache.fetch(data.fill_image_path)
	var show_img: bool = tex != null
	if _fill_img != null and is_instance_valid(_fill_img):
		_fill_img.visible = show_img
		_fill_img.texture = tex
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0) if show_img else data.fill_color
	sb.border_color = data.border_color
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(0)
	_bg.add_theme_stylebox_override("panel", sb)

	# ---- 文字（BBCode）----
	_text.text = _to_bbcode(data.text_def)
	# 单行时纵向大致居中（RichTextLabel 无纵向对齐属性，用上下偏移模拟）
	var line_h: float = float(FONT_SIZE) * 1.4
	var top: float = clampf((size.y - line_h) * 0.5, 2.0, 10.0)
	_text.offset_top = top
	_text.offset_bottom = -top

	# ---- 显隐（受积木标签 与「内容为空时隐藏」控制）----
	_apply_visibility()

	queue_redraw()


func _tag_enabled() -> bool:
	if block == null:
		return false
	return (BlockTags.SHOW in block.tags) and (BlockTags.TEXT in block.tags)


# 显隐判定：
#   1) 标签不满足（无 show / 无 text）→ 隐藏；
#   2) hide_when_empty 为真，且「无可见文本 且 无填充图片」→ 视为内容为空，整个文本框（含背景边框）隐藏。
# 注意：第 2 条依赖 _to_bbcode 写入的 _had_visible_text（文本经变量求值后的真实结果），
#       因此「文本里的变量被改成空」也能正确触发隐藏。
func _apply_visibility() -> void:
	var tag_ok: bool = _tag_enabled()
	var hidden_by_empty: bool = false
	if tag_ok and data != null and data.hide_when_empty:
		hidden_by_empty = (not _had_visible_text) and (not data.has_image())
	visible = tag_ok and not hidden_by_empty
	# 镂空遮罩(cutout)：文本框属低层积木子树、绘制先于遮罩，
	# 遮罩的 MUL 打洞画布会在渲染期把洞内像素（含本文本框）alpha 乘成 0 —— 无需在此隐藏。


# 完整重新应用（尺寸/样式/文本求值/显隐都可能已变）
# 调用时机：Block.refresh_text_boxes()（事件/脚本改了文本框变量后）
func refresh() -> void:
	_apply()


# 仅重算显隐（标签变化时由 Block 调用；文本未变，沿用上次求值结果）
func refresh_visibility() -> void:
	_apply_visibility()


# ---- 富文本 → BBCode ----
# 实现统一在 TextRenderer.to_bbcode（弹窗/对话面板共用同一份 BBCode 生成逻辑，
# 避免「修饰」在任何一处漏改导致表现不一致）
func _to_bbcode(def: String) -> String:
	_had_visible_text = false
	if def.strip_edges().is_empty():
		return ""
	# 显式标注 Dictionary，避免推断到 TextRenderer 内部类类型
	var r: Dictionary = _renderer.to_bbcode(def, _resolver())
	# 全是空白也算空（免得 hide_when_empty 被一个空格骗过）
	_had_visible_text = not str(r.get("text", "")).strip_edges().is_empty()
	return str(r.get("bbcode", ""))


func _resolver() -> Callable:
	if block != null:
		return block.variable_resolver
	return Callable()
