# ui/node_property_panel.gd
# 「节点属性」编辑窗口（第二十四轮）—— 照「积木属性」(ui/property_editor_panel.gd) 的骨架做：
#   玻璃底 PanelContainer + 标题栏（标题 + 拖动把柄 + 最小化 + × 关闭）+ 滚动内容区 + 表单。
#
# 用途：编辑**世界节点**（星体：太阳 0 级 / 行星 1 级 / 卫星 2 级；城市 3 级）。
#   本轮真正可改的是：城市 = 名称（多语言）/ 纬度 / 经度 / 档位；星体 = 名称。
#   级别与父节点是**只读展示**（它们由节点类型与场景树决定，不是随手改的字段）。
#
# ★ 「保存位置」下拉（本体 / DLC / MOD / 存档）照「积木属性」同款：
#   **只有「本体」真正落盘**（写进游戏自身的数据层，见 WorldData.save_city_edit / save_node_edit），
#   其余三项是占位（选了会提示"尚未生效"）。这与关卡页「保存位置」下拉是同一套约定。
#
# ★ 本窗口**只管表单与校验**：数据怎么改、改完怎么刷新显示，全部交回调用方
#   （`applied(kind, payload)` 信号 → WorldPage 应用并落盘）—— 免得 UI 与数据层互相咬。
#
# signal applied(kind, payload)
#   kind = "name"      payload = { "lang": 语言码, "value": 名 }        （城市：多语言名）
#   kind = "node_name" payload = { "value": 名 }                        （星体：单语名）
#   kind = "latlon"    payload = { "lat": float, "lon": float }         （城市）
#   kind = "tier"      payload = { "tier": int }                        （城市：0~3）
extends Control
class_name NodePropertyPanel

signal applied(kind: String, payload: Dictionary)

const PANEL_PADDING: float = 6.0
const LABEL_W: float = 62.0
const FIELD_W: float = 170.0
const ROW_H: float = 20.0
const TITLE_BAR_H: float = 28.0
const TITLE_FONT: int = 14
const FORM_FONT: int = 13
const MIN_W: float = 300.0     # 窗口最小宽度（名称行要放语言下拉 + 输入 + 应用）
const MIN_H: float = 200.0

## 保存位置（只有「本体」真正落盘；其余占位）
const SAVE_LOCS: Array = ["本体", "DLC", "MOD", "存档"]
## 档位下拉（顺序 = CityIndex 的档位编号）
const TIER_LABELS: Array = ["首都 / 首府（五角星）", "特大（双圈）", "大（圈内点）", "小（单圈）"]

var _box: PanelContainer = null
var _scroll: ScrollContainer = null
var _form: VBoxContainer = null
var _drag_handle: UIDragHandle = null
var _close_btn: UIBtn = null
var _min_btn: UIBtn = null
var _hint: Label = null

var _save_loc: OptionButton = null
var _kind_value: Label = null      # 节点类型 / 级别 / 父节点（只读值）
var _level_value: Label = null
var _parent_value: Label = null

# 名称：城市 = 语言下拉 + 输入（多语言）；星体 = 只输入（单语）
var _city_name_row: HBoxContainer = null
var _node_name_row: HBoxContainer = null
var _lang_select: OptionButton = null
var _lang_input: LineEdit = null
var _node_input: LineEdit = null

# 位置与档位（只有城市有）
var _pos_row: HBoxContainer = null
var _lat_input: LineEdit = null
var _lon_input: LineEdit = null
var _tier_row: HBoxContainer = null
var _tier_select: OptionButton = null

var _minimized: bool = false
var _user_pos: Vector2 = Vector2.ZERO
var _has_user_pos: bool = false
## 当前编辑对象（由 open_for 存下，原样回传给调用方判定是谁）
var target: Dictionary = {}


func _ready() -> void:
	visible = false
	_build_ui()
	if not TranslationManager.language_changed.is_connected(_on_language_changed):
		TranslationManager.language_changed.connect(_on_language_changed)


func _build_ui() -> void:
	_box = PanelContainer.new()
	_box.mouse_filter = Control.MOUSE_FILTER_STOP
	_box.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_box.position = Vector2.ZERO
	add_child(_box)

	var sb := UIStyle.glass_box(UIStyle.FILL_DEFAULT, UIStyle.BORDER,
		int(UIStyle.CORNER_RADIUS), int(UIStyle.BORDER_WIDTH), true)
	sb.content_margin_left = PANEL_PADDING
	sb.content_margin_right = PANEL_PADDING
	sb.content_margin_top = PANEL_PADDING
	sb.content_margin_bottom = PANEL_PADDING
	_box.add_theme_stylebox_override("panel", sb)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 0)
	_box.add_child(outer)

	# 标题栏：标题 + 拖动把柄 + 最小化 + × 关闭（与积木属性同款）
	var title_bar := HBoxContainer.new()
	title_bar.add_theme_constant_override("separation", 4)
	outer.add_child(title_bar)
	var title := Label.new()
	title.text = "节点属性"
	title.custom_minimum_size = Vector2(0, TITLE_BAR_H)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_font_size_override("font_size", TITLE_FONT)
	var fnt := UIStyle.get_cjk_font()
	if fnt != null:
		title.add_theme_font_override("font", fnt)
	title_bar.add_child(title)
	_drag_handle = UIDragHandle.new()
	_drag_handle.setup(self)
	_drag_handle.drag_ended.connect(_on_drag_ended)
	title_bar.add_child(_drag_handle)
	_min_btn = UIMinimize.attach(title_bar, func() -> void: set_minimized(not _minimized))
	_close_btn = UIBtn.new()
	_close_btn.set_id("close")
	_close_btn.set_label("×")
	_close_btn.custom_minimum_size = Vector2(TITLE_BAR_H, TITLE_BAR_H)
	_close_btn.pressed_id.connect(_on_close_pressed)
	title_bar.add_child(_close_btn)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.custom_minimum_size = Vector2(MIN_W, MIN_H)
	outer.add_child(_scroll)

	_form = VBoxContainer.new()
	_form.add_theme_constant_override("separation", 4)
	_form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_form)

	# ---- 保存位置（只有「本体」真正落盘）----
	_save_loc = OptionButton.new()
	_save_loc.custom_minimum_size = Vector2(FIELD_W, ROW_H)
	_save_loc.add_theme_font_size_override("font_size", FORM_FONT)
	for s in SAVE_LOCS:
		_save_loc.add_item(str(s))
	_save_loc.select(0)
	_form.add_child(_row_with("保存位置", _save_loc))

	# ---- 只读展示：节点类型 / 级别 / 父节点 ----
	_kind_value = _add_value_row("节点类型", "—")
	_level_value = _add_value_row("级别", "—")
	_parent_value = _add_value_row("父节点", "—")

	# ---- 名称（城市：多语言；星体：单语）----
	_lang_select = OptionButton.new()
	_lang_select.custom_minimum_size = Vector2(96.0, ROW_H)
	_lang_select.add_theme_font_size_override("font_size", FORM_FONT)
	for lang in TranslationManager.LANG_CODES:
		_lang_select.add_item(TranslationManager.get_lang_name(lang))
	_lang_select.item_selected.connect(_on_lang_selected)
	_lang_input = _make_input("该语言下的名称（空 = 删除译本）")
	var lang_apply := _small_btn("应用")
	lang_apply.pressed_id.connect(func(_id: String) -> void: _apply_city_name())
	var lang_row := HBoxContainer.new()
	lang_row.add_theme_constant_override("separation", 6)
	lang_row.add_child(_label("语言"))
	lang_row.add_child(_lang_select)
	lang_row.add_child(_lang_input)
	lang_row.add_child(lang_apply)
	_city_name_row = lang_row
	_form.add_child(lang_row)

	_node_input = _make_input("节点名称")
	var node_apply := _small_btn("应用")
	node_apply.pressed_id.connect(func(_id: String) -> void: _apply_node_name())
	var node_row := HBoxContainer.new()
	node_row.add_theme_constant_override("separation", 6)
	node_row.add_child(_label("名称"))
	node_row.add_child(_node_input)
	node_row.add_child(node_apply)
	_node_name_row = node_row
	_form.add_child(node_row)

	# ---- 位置（城市）：纬度 / 经度 + 应用 ----
	_lat_input = _make_input("纬度 -90 ~ 90")
	_lon_input = _make_input("经度 -180 ~ 180")
	var pos_apply := _small_btn("应用")
	pos_apply.pressed_id.connect(func(_id: String) -> void: _apply_latlon())
	var pos_row := HBoxContainer.new()
	pos_row.add_theme_constant_override("separation", 6)
	pos_row.add_child(_label("纬度"))
	pos_row.add_child(_lat_input)
	pos_row.add_child(_label("经度"))
	pos_row.add_child(_lon_input)
	pos_row.add_child(pos_apply)
	_pos_row = pos_row
	_form.add_child(pos_row)

	# ---- 档位（城市）----
	_tier_select = OptionButton.new()
	_tier_select.custom_minimum_size = Vector2(FIELD_W, ROW_H)
	_tier_select.add_theme_font_size_override("font_size", FORM_FONT)
	for t in TIER_LABELS:
		_tier_select.add_item(str(t))
	var tier_apply := _small_btn("应用")
	tier_apply.pressed_id.connect(func(_id: String) -> void: _apply_tier())
	var tier_row := HBoxContainer.new()
	tier_row.add_theme_constant_override("separation", 6)
	tier_row.add_child(_label("档位"))
	tier_row.add_child(_tier_select)
	tier_row.add_child(tier_apply)
	_tier_row = tier_row
	_form.add_child(tier_row)

	# ---- 提示行（校验失败 / 占位保存位置 …）----
	_hint = _label("")
	_hint.add_theme_color_override("font_color", Color(1.0, 0.82, 0.55))
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size = Vector2(MIN_W - 2.0 * PANEL_PADDING, 0.0)
	_form.add_child(_hint)

	_box.custom_minimum_size = Vector2(MIN_W, 0.0)


# ---------------- 打开 / 关闭 ----------------

## 打开编辑某节点。`t` 由调用方（WorldPage）按当前选中对象填好：
##   { "kind": "city"|"node", "id": {…回传用…}, "type_text": "城市（3 级）",
##     "level": 3, "parent": "地球",
##     "names": {语言码: 名}（城市）, "lat": …, "lon": …, "tier": 0~3（城市）,
##     "name": "地球"（星体） }
func open_for(t: Dictionary) -> void:
	target = t
	var is_city := str(t.get("kind", "")) == "city"
	_city_name_row.visible = is_city
	_pos_row.visible = is_city
	_tier_row.visible = is_city
	_node_name_row.visible = not is_city

	_kind_value.text = str(t.get("type_text", "—"))
	_level_value.text = str(t.get("level", "—"))
	_parent_value.text = str(t.get("parent", "—"))

	if is_city:
		var names: Dictionary = t.get("names", {})
		_refresh_lang_input(names)
		_lat_input.text = "%.5f" % float(t.get("lat", 0.0))
		_lon_input.text = "%.5f" % float(t.get("lon", 0.0))
		var ti := int(t.get("tier", 0))
		_tier_select.select(clampi(ti, 0, TIER_LABELS.size() - 1))
	else:
		_node_input.text = str(t.get("name", ""))

	_hint.text = ""
	visible = true
	if _has_user_pos:
		position = _user_pos
	# 打开时把窗口挪进屏幕内（别开在屏幕外）。★ 用**盒子**的实际尺寸算，不是本 Control 的 ——
	#   本类是纯外壳（只负责挂 _box），它自己的 size 恒为 0。
	var ps := _box.size
	if ps.x < 1.0 or ps.y < 1.0:
		ps = Vector2(MIN_W, MIN_H)
	var vp := get_viewport_rect().size
	position = Vector2(clampf(position.x, 0.0, maxf(vp.x - ps.x, 0.0)),
		clampf(position.y, 0.0, maxf(vp.y - ps.y, 0.0)))


func close() -> void:
	visible = false


func is_open() -> bool:
	return visible


func set_minimized(v: bool) -> void:
	_minimized = v
	if _scroll != null and is_instance_valid(_scroll):
		_scroll.visible = not v
	_box.custom_minimum_size = Vector2(MIN_W, TITLE_BAR_H + 2.0 * PANEL_PADDING) if v else Vector2(MIN_W, 0.0)


# ---------------- 行 / 控件工厂 ----------------

func _label(txt: String) -> Label:
	var l := Label.new()
	l.text = txt
	l.custom_minimum_size = Vector2(LABEL_W, 0.0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", Color(0.78, 0.84, 0.92))
	l.add_theme_font_size_override("font_size", FORM_FONT)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var f := UIStyle.get_cjk_font()
	if f != null:
		l.add_theme_font_override("font", f)
	return l


## 「标签 : 值（只读）」一行 —— 返回那个**值** Label（后续 set text 用）。
func _add_value_row(key: String, value: String) -> Label:
	var v := Label.new()
	v.text = value
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_color_override("font_color", Color.WHITE)
	v.add_theme_font_size_override("font_size", FORM_FONT)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var f := UIStyle.get_cjk_font()
	if f != null:
		v.add_theme_font_override("font", f)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(_label(key))
	row.add_child(v)
	_form.add_child(row)
	return v


func _row_with(key: String, ctl: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(_label(key))
	ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ctl)
	return row


func _make_input(placeholder: String) -> LineEdit:
	var le := LineEdit.new()
	le.custom_minimum_size = Vector2(FIELD_W, ROW_H)
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.add_theme_font_size_override("font_size", FORM_FONT)
	le.add_theme_color_override("font_color", Color.WHITE)
	le.add_theme_color_override("placeholder_color", Color(1, 1, 1, 0.45))
	le.placeholder_text = placeholder
	le.mouse_filter = Control.MOUSE_FILTER_STOP
	le.caret_blink = true
	return le


func _small_btn(txt: String) -> UIBtn:
	var b := UIBtn.new()
	b.set_id("apply_" + txt)
	b.set_label(txt)
	b.custom_minimum_size = Vector2(52.0, ROW_H)
	return b


# ---------------- 交互 ----------------

func _on_lang_selected(idx: int) -> void:
	var names: Dictionary = target.get("names", {})
	_refresh_lang_input(names, idx)


func _refresh_lang_input(names: Dictionary, idx: int = -1) -> void:
	var j := idx if idx >= 0 else _lang_select.selected
	var code := str(TranslationManager.LANG_CODES[clampi(j, 0, TranslationManager.LANG_CODES.size() - 1)])
	_lang_input.text = str(names.get(code, ""))


func _cur_lang_code() -> String:
	return str(TranslationManager.LANG_CODES[clampi(_lang_select.selected, 0,
		TranslationManager.LANG_CODES.size() - 1)])


func _apply_city_name() -> void:
	var code := _cur_lang_code()
	var v := _lang_input.text.strip_edges()
	applied.emit("name", {"lang": code, "value": v})
	# 本地也更新一份（用户接着切语言时看到的是最新的）
	var names: Dictionary = target.get("names", {})
	names[code] = v
	target["names"] = names
	_hint.text = "名称已应用（%s）：%s" % [TranslationManager.get_lang_name(code), v if not v.is_empty() else "（空 = 删除该语言译本）"]


func _apply_node_name() -> void:
	var v := _node_input.text.strip_edges()
	if v.is_empty():
		_hint.text = "名称不能为空"
		return
	applied.emit("node_name", {"value": v})
	_hint.text = "名称已应用：%s" % v


func _apply_latlon() -> void:
	var lat := _parse_num(_lat_input.text)
	var lon := _parse_num(_lon_input.text)
	if is_nan(lat) or is_nan(lon):
		_hint.text = "经纬度必须是数字"
		return
	if lat < -90.0 or lat > 90.0:
		_hint.text = "纬度必须在 -90 ~ 90 之间"
		return
	if lon < -180.0 or lon > 180.0:
		_hint.text = "经度必须在 -180 ~ 180 之间"
		return
	applied.emit("latlon", {"lat": lat, "lon": lon})
	_hint.text = "经纬度已应用：%.5f, %.5f" % [lat, lon]


func _apply_tier() -> void:
	var t := clampi(_tier_select.selected, 0, TIER_LABELS.size() - 1)
	applied.emit("tier", {"tier": t})
	target["tier"] = t
	_hint.text = "档位已应用：%s" % TIER_LABELS[t]


static func _parse_num(s: String) -> float:
	var t := s.strip_edges()
	if t.is_empty():
		return NAN
	if not t.is_valid_float():
		return NAN
	return float(t)


## 保存位置校验：只有「本体」真正落盘（照关卡页「保存位置」同款约定）。
func save_location_ok() -> bool:
	var sel: String = str(SAVE_LOCS[clampi(_save_loc.selected, 0, SAVE_LOCS.size() - 1)])
	if sel != "本体":
		_hint.text = "保存位置「%s」为占位选项，尚未生效；请选择「本体」" % sel
		return false
	return true


func _on_drag_ended() -> void:
	_user_pos = position
	_has_user_pos = true


func _on_close_pressed(_id: String) -> void:
	close()


func _on_language_changed(_lang: String) -> void:
	# 语言名下拉里显示的"语言名"是翻译表里的 ⇒ 换语言要重贴（城市名本身不接翻译表，见 CityIndex）
	for i in range(_lang_select.item_count):
		_lang_select.set_item_text(i, TranslationManager.get_lang_name(str(TranslationManager.LANG_CODES[i])))
	_refresh_lang_input(target.get("names", {}))
