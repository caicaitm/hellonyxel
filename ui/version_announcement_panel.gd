# ui/version_announcement_panel.gd
# 「版本显示」+「更新公告」系统（系统托盘右键「版本」打开）。
#
# 数据文件：res://data/announcements.tsv（与翻译表 translations.tsv 同目录，Tab 分隔）
#   格式：版本号 \t 日期 \t 名称 \t 语言 \t 内容 \t 是否显示
#   - 每行 = 某个版本某语言的一条公告；同一版本可有多种语言的多行。
#   - 「是否显示」= "1" 公开 / "0" 不公开。
#
# 规则：
#   - 版本显示：读取「最新版本号」并恒展示（无论该版本是否显示）。
#   - 更新公告可见性：普通模式按「是否显示」；调试模式(Debug.debug_mode)下无论写什么都强制可见。
#   - 内容语言：显示与玩家当前语言(TranslationManager.current_lang)相同的正文；
#     该语言缺失 → 回退简体中文(zh_CN) → 再缺 → 该版本首行。
#   - 调试模式：面板可编辑「当前选中语言（默认玩家语言）」的公告正文与「是否显示」，并写回文件。
#
# 设计约束（与 calendar_panel 一致）：
#   class_name VersionAnnouncementPanel extends Control；signal closed；
#   open()/close()/is_open() 三件套；close() 内 closed.emit()；入树后由 desktop.gd 挂到 ui_layer。
class_name VersionAnnouncementPanel extends Control

signal closed

const ANNOUNCE_PATH := "res://data/announcements.tsv"
const PANEL_W: float = 560.0
const PANEL_H: float = 480.0
const TITLE_H: float = 28.0

var _bg: UIPanel
var _title_label: Label
var _close_btn: UIBtn
var _min_btn: UIBtn = null
var _minimized: bool = false
var _version_label: Label
var _name_label: Label
var _date_label: Label
var _content_label: Label
var _edit_block: VBoxContainer
var _lang_sel: OptionButton
var _content_edit: TextEdit
var _visible_chk: CheckBox
var _save_btn: UIBtn
var _status_label: Label

var _all_rows: Array = []
var _latest: String = ""
var _open: bool = false
var _cjk: FontFile


func _ready() -> void:
    mouse_filter = Control.MOUSE_FILTER_STOP
    _cjk = UIStyle.get_cjk_font()
    _build_ui()
    visible = false


func _build_ui() -> void:
    var vs: Vector2 = UIStyle.canvas_viewport_size(self) if get_viewport() != null else Vector2(1280.0, 720.0)
    size = Vector2(PANEL_W, PANEL_H)
    position = Vector2(maxf(40.0, (vs.x - PANEL_W) * 0.5), maxf(50.0, (vs.y - PANEL_H) * 0.4))

    _bg = UIPanel.new()
    _bg.bind_page_dark_bg()
    _bg.name = "Bg"
    _bg.set_anchors_preset(Control.PRESET_FULL_RECT)
    _bg.set_corner_radius(UIStyle.CORNER_RADIUS)
    _bg.set_fill_color(UIStyle.FILL_DEFAULT)
    _bg.set_border_color(UIStyle.STAGE_BORDER)
    _bg.set_border_width(UIStyle.BORDER_WIDTH)
    _bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_bg)

    var drag := UIDragHandle.new()
    drag.name = "DragHandle"
    drag.setup(self)
    drag.anchor_left = 1.0
    drag.anchor_top = 0.0
    drag.anchor_right = 1.0
    drag.anchor_bottom = 0.0
    drag.offset_left = -(TITLE_H * 2.0 + UIStyle.PANEL_PADDING + 4.0)
    drag.offset_top = UIStyle.PANEL_PADDING
    drag.offset_right = -(TITLE_H + UIStyle.PANEL_PADDING + 4.0)
    drag.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING
    add_child(drag)

    _close_btn = UIBtn.new()
    _close_btn.name = "CloseBtn"
    _close_btn.set_id("close")
    _close_btn.set_label("×")
    _close_btn.anchor_left = 1.0
    _close_btn.anchor_top = 0.0
    _close_btn.anchor_right = 1.0
    _close_btn.anchor_bottom = 0.0
    _close_btn.offset_left = -(TITLE_H + UIStyle.PANEL_PADDING)
    _close_btn.offset_top = UIStyle.PANEL_PADDING
    _close_btn.offset_right = -UIStyle.PANEL_PADDING
    _close_btn.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING
    _close_btn.pressed_id.connect(_on_close_pressed)
    add_child(_close_btn)
    _min_btn = UIMinimize.attach_anchored(self, _close_btn, func(): set_minimized(not _minimized))

    _title_label = Label.new()
    _title_label.name = "TitleLabel"
    _title_label.text = "版本与更新公告"
    _title_label.position = Vector2(UIStyle.PANEL_PADDING + 2.0, UIStyle.PANEL_PADDING)
    _title_label.custom_minimum_size = Vector2(0.0, TITLE_H)
    _title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _title_label.add_theme_color_override("font_color", Color(0.8, 0.94, 1.0))
    _title_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 1)
    if is_instance_valid(_cjk):
        _title_label.add_theme_font_override("font", _cjk)
    _title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_title_label)

    _version_label = Label.new()
    _version_label.name = "VersionLabel"
    _version_label.text = "当前版本：—"
    _version_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
    _version_label.offset_left = UIStyle.PANEL_PADDING
    _version_label.offset_top = TITLE_H + UIStyle.PANEL_PADDING
    _version_label.offset_right = -UIStyle.PANEL_PADDING
    _version_label.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING + 22.0
    _version_label.add_theme_color_override("font_color", Color(0.9, 0.96, 1.0))
    _version_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE + 2)
    if is_instance_valid(_cjk):
        _version_label.add_theme_font_override("font", _cjk)
    _version_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_version_label)

    _name_label = Label.new()
    _name_label.name = "NameLabel"
    _name_label.text = ""
    _name_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
    _name_label.offset_left = UIStyle.PANEL_PADDING
    _name_label.offset_top = TITLE_H + UIStyle.PANEL_PADDING + 26.0
    _name_label.offset_right = -UIStyle.PANEL_PADDING
    _name_label.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING + 46.0
    _name_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
    _name_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
    if is_instance_valid(_cjk):
        _name_label.add_theme_font_override("font", _cjk)
    _name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_name_label)

    _date_label = Label.new()
    _date_label.name = "DateLabel"
    _date_label.text = ""
    _date_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
    _date_label.offset_left = UIStyle.PANEL_PADDING
    _date_label.offset_top = TITLE_H + UIStyle.PANEL_PADDING + 48.0
    _date_label.offset_right = -UIStyle.PANEL_PADDING
    _date_label.offset_bottom = TITLE_H + UIStyle.PANEL_PADDING + 66.0
    _date_label.add_theme_color_override("font_color", Color(0.78, 0.86, 0.95, 0.85))
    _date_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
    if is_instance_valid(_cjk):
        _date_label.add_theme_font_override("font", _cjk)
    _date_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_date_label)

    _content_label = Label.new()
    _content_label.name = "ContentLabel"
    _content_label.text = ""
    _content_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _content_label.set_anchors_preset(Control.PRESET_FULL_RECT)
    _content_label.offset_left = UIStyle.PANEL_PADDING
    _content_label.offset_top = TITLE_H + UIStyle.PANEL_PADDING + 70.0
    _content_label.offset_right = -UIStyle.PANEL_PADDING
    _content_label.offset_bottom = -UIStyle.PANEL_PADDING
    _content_label.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
    _content_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE)
    if is_instance_valid(_cjk):
        _content_label.add_theme_font_override("font", _cjk)
    _content_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_content_label)

    _edit_block = _build_edit_block()
    _edit_block.visible = false
    add_child(_edit_block)


func _build_edit_block() -> VBoxContainer:
    var sec := VBoxContainer.new()
    sec.name = "EditBlock"
    sec.set_anchors_preset(Control.PRESET_FULL_RECT)
    sec.offset_left = UIStyle.PANEL_PADDING
    sec.offset_top = TITLE_H + UIStyle.PANEL_PADDING + 70.0
    sec.offset_right = -UIStyle.PANEL_PADDING
    sec.offset_bottom = -UIStyle.PANEL_PADDING
    sec.add_theme_constant_override("separation", 6)
    sec.size_flags_vertical = Control.SIZE_EXPAND_FILL

    var lang_title := Label.new()
    lang_title.text = "编辑语言（调试模式）"
    lang_title.add_theme_color_override("font_color", UIStyle.TEXT_DEFAULT)
    lang_title.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
    if is_instance_valid(_cjk):
        lang_title.add_theme_font_override("font", _cjk)
    sec.add_child(lang_title)

    _lang_sel = OptionButton.new()
    _lang_sel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    if is_instance_valid(_cjk):
        _lang_sel.add_theme_font_override("font", _cjk)
    _lang_sel.item_selected.connect(_on_lang_selected)
    sec.add_child(_lang_sel)

    _content_edit = TextEdit.new()
    _content_edit.name = "ContentEdit"
    _content_edit.placeholder_text = "公告正文（支持换行）…"
    _content_edit.custom_minimum_size = Vector2(0.0, 160.0)
    _content_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
    UIStyle.apply_text_edit_style(_content_edit)
    sec.add_child(_content_edit)

    _visible_chk = CheckBox.new()
    _visible_chk.text = "公开显示（是否显示 = 1）"
    if is_instance_valid(_cjk):
        _visible_chk.add_theme_font_override("font", _cjk)
    sec.add_child(_visible_chk)

    _save_btn = UIBtn.new()
    _save_btn.set_id("save")
    _save_btn.set_label("保存公告")
    _save_btn.custom_minimum_size = Vector2(120.0, 28.0)
    _save_btn.pressed_id.connect(_on_save_pressed)
    sec.add_child(_save_btn)

    _status_label = Label.new()
    _status_label.name = "StatusLabel"
    _status_label.text = ""
    _status_label.custom_minimum_size = Vector2(0.0, 18.0)
    _status_label.add_theme_color_override("font_color", Color(0.78, 0.86, 0.95, 0.85))
    _status_label.add_theme_font_size_override("font_size", UIStyle.FONT_SIZE - 1)
    if is_instance_valid(_cjk):
        _status_label.add_theme_font_override("font", _cjk)
    sec.add_child(_status_label)

    return sec


# ============ 打开 / 关闭 ============

func open() -> void:
    _refresh()
    _open = true
    visible = true
    move_to_front()


func close() -> void:
    _open = false
    visible = false
    if get_viewport() != null:
        get_viewport().gui_release_focus()
    closed.emit()


func is_open() -> bool:
    return _open


func _refresh() -> void:
    _all_rows = parse_announcements(ANNOUNCE_PATH)
    _latest = latest_version(_all_rows)
    var dbg := _debug_on()
    _version_label.text = "当前版本：%s" % (_latest if not _latest.is_empty() else "—")
    _title_label.text = "版本与更新公告" + ("（调试）" if dbg else "")
    if dbg:
        _show_edit()
    else:
        _show_readonly()


func _show_readonly() -> void:
    _edit_block.visible = false
    _content_label.visible = true
    var lang := _current_lang()
    var row := pick_row(_all_rows, _latest, lang)
    if row.is_empty():
        _name_label.text = ""
        _date_label.text = ""
        _content_label.text = "（暂无更新公告）"
        return
    _name_label.text = str(row.get("name", ""))
    _date_label.text = str(row.get("date", ""))
    if bool(row.get("visible", false)) or _debug_on():
        _content_label.text = str(row.get("content", ""))
    else:
        _content_label.text = "（该版本公告暂未公开）"


func _show_edit() -> void:
    _content_label.visible = false
    _edit_block.visible = true
    _populate_lang_sel()
    var lang := _current_lang()
    var idx := TranslationManager.LANG_CODES.find(lang)
    if idx < 0:
        idx = 0
    _lang_sel.select(idx)
    _load_edit_row(lang)


func _populate_lang_sel() -> void:
    _lang_sel.clear()
    for i in range(TranslationManager.LANG_CODES.size()):
        var code: String = TranslationManager.LANG_CODES[i]
        var nm: String = TranslationManager.LANG_NAMES[i]
        _lang_sel.add_item("%s (%s)" % [nm, code])
        _lang_sel.set_item_metadata(i, code)


func _load_edit_row(lang: String) -> void:
    var row := pick_row(_all_rows, _latest, lang)
    if row.is_empty():
        _content_edit.text = ""
        _visible_chk.button_pressed = false
        _status_label.text = "（该语言暂无公告，保存将新增一行）"
        return
    _content_edit.text = str(row.get("content", ""))
    _visible_chk.button_pressed = bool(row.get("visible", false))
    _status_label.text = ""


func _on_lang_selected(_idx: int) -> void:
    var code: String = _lang_sel.get_item_metadata(_lang_sel.selected)
    _load_edit_row(code)


func _on_save_pressed(_id: String) -> void:
    if _latest.is_empty():
        _status_label.text = "（没有可保存的版本）"
        return
    var code: String = _lang_sel.get_item_metadata(_lang_sel.selected)
    var content: String = _content_edit.text
    var visible: bool = _visible_chk.button_pressed
    var ok := _save_row(_latest, code, content, visible)
    if ok:
        _status_label.text = "已保存 %s / %s" % [code, _latest]
        _refresh()
    else:
        _status_label.text = "保存失败（文件不可写？）"


func _save_row(version: String, lang: String, content: String, visible: bool) -> bool:
    var found := false
    for r in _all_rows:
        if str(r.get("version", "")) == version and str(r.get("lang", "")) == lang:
            r["content"] = content
            r["visible"] = visible
            found = true
            break
    if not found:
        var date := _latest_date_for(version)
        var name := _latest_name_for(version, lang)
        _all_rows.append({"version": version, "date": date, "name": name, "lang": lang, "content": content, "visible": visible})
    return _write_file()


func _latest_date_for(version: String) -> String:
    for r in _all_rows:
        if str(r.get("version", "")) == version:
            return str(r.get("date", ""))
    return ""


func _latest_name_for(version: String, lang: String) -> String:
    for r in _all_rows:
        if str(r.get("version", "")) == version and str(r.get("lang", "")) == lang:
            return str(r.get("name", ""))
    for r in _all_rows:
        if str(r.get("version", "")) == version and str(r.get("lang", "")) == "zh_CN":
            return str(r.get("name", ""))
    for r in _all_rows:
        if str(r.get("version", "")) == version:
            return str(r.get("name", ""))
    return "更新"


func _write_file() -> bool:
    var path := ANNOUNCE_PATH
    var f := FileAccess.open(path, FileAccess.WRITE)
    if f == null:
        # 导出包内 res:// 只读 → 回退 user://（开发/编辑器环境通常能直接写 res://）
        path = "user://announcements.tsv"
        f = FileAccess.open(path, FileAccess.WRITE)
    if f == null:
        return false
    var tab := String.chr(9)
    var lines: Array[String] = []
    lines.append("版本号" + tab + "日期" + tab + "名称" + tab + "语言" + tab + "内容" + tab + "是否显示")
    for r in _all_rows:
        var cells := [
            str(r.get("version", "")),
            str(r.get("date", "")),
            _to_cell(str(r.get("name", ""))),
            str(r.get("lang", "")),
            _to_cell(str(r.get("content", ""))),
            "1" if bool(r.get("visible", false)) else "0",
        ]
        lines.append(tab.join(cells))
    f.store_string("\n".join(lines) + "\n")
    f.close()
    print("[VersionAnnouncementPanel] 公告已写回: %s" % path)
    return true


# ============ 最小化 ============

func set_minimized(v: bool) -> void:
    _minimized = v
    if _min_btn != null and is_instance_valid(_min_btn):
        UIMinimize.set_label(_min_btn, v)
    UIMinimize.fold_top_strip(self, v)
    UIMinimize.apply_size(self, v)


func is_minimized() -> bool:
    return _minimized


func _on_close_pressed(_id: String) -> void:
    close()


# ============ 运行时辅助 ============

func _debug_on() -> bool:
    var dbg = get_node_or_null("/root/Debug")
    if dbg == null:
        return false
    return bool(dbg.debug_mode)


func _current_lang() -> String:
    var tm = get_node_or_null("/root/TranslationManager")
    if tm == null:
        return "en"
    return str(tm.current_lang)


# ============ 静态解析（供 headless 探针单测，无需实例化面板） ============

# 解析公告 TSV：返回 Array[Dictionary]{version,date,name,lang,content,visible(bool)}。
# 表头（第 6 列是「是否显示」）与脏行（第 6 列非 0/1）会被跳过，故无论是否带表头都能解析。
static func parse_announcements(path: String) -> Array:
    var out: Array = []
    if not FileAccess.file_exists(path):
        return out
    var f := FileAccess.open(path, FileAccess.READ)
    if f == null:
        return out
    while not f.eof_reached():
        var line := f.get_line()
        if line.strip_edges() == "":
            continue
        var parts := line.split(String.chr(9))
        if parts.size() < 6:
            continue
        var visible_raw: String = parts[5].strip_edges()
        if visible_raw != "0" and visible_raw != "1":
            continue
        out.append({
            "version": parts[0].strip_edges(),
            "date": parts[1].strip_edges(),
            "name": parts[2].strip_edges(),
            "lang": parts[3].strip_edges(),
            "content": _clean_cell_static(parts[4]),
            "visible": visible_raw == "1",
        })
    f.close()
    return out


static func _clean_cell_static(raw: String) -> String:
    var s := raw.replace(String.chr(13), "").replace(String.chr(65279), "").strip_edges()
    return s.replace(String.chr(92) + "n", String.chr(10))


static func _to_cell(s: String) -> String:
    return s.replace(String.chr(10), String.chr(92) + "n").replace(String.chr(13), "")


static func latest_version(ann: Array) -> String:
    var best := ""
    var best_row: Dictionary = {}
    var has := false
    for r in ann:
        if not (r is Dictionary):
            continue
        var v: String = str(r.get("version", ""))
        if v.is_empty():
            continue
        if not has or _row_newer(r, best_row):
            best_row = r
            best = v
            has = true
    return best


static func _row_newer(a: Dictionary, b: Dictionary) -> bool:
    var ka := _version_key(str(a.get("version", "")))
    var kb := _version_key(str(b.get("version", "")))
    for i in range(maxi(ka.size(), kb.size())):
        var x: int = ka[i] if i < ka.size() else 0
        var y: int = kb[i] if i < kb.size() else 0
        if x != y:
            return x > y
    return str(a.get("date", "")) > str(b.get("date", ""))


static func _version_key(v: String) -> Array:
    var out: Array = []
    for seg in v.split("."):
        var n := 0
        for ch in seg:
            if ch >= "0" and ch <= "9":
                n = n * 10 + int(ch)
            else:
                break
        out.append(n)
    while out.size() < 4:
        out.append(0)
    return out


static func pick_row(ann: Array, version: String, lang: String) -> Dictionary:
    var same_ver: Array = []
    for r in ann:
        if not (r is Dictionary):
            continue
        if str(r.get("version", "")) == version:
            same_ver.append(r)
    if same_ver.is_empty():
        return {}
    for r in same_ver:
        if str(r.get("lang", "")) == lang:
            return r as Dictionary
    for r in same_ver:
        if str(r.get("lang", "")) == "zh_CN":
            return r as Dictionary
    return same_ver[0] as Dictionary
