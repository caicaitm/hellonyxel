# autoload/player_profile.gd
# 玩家画像（Player Profile）—— 由 `html/player_profile.html` 收集、经 HtmlBridge 命令写入。
#
# 落盘：%文档%/HelloNyxel/Temp/player_profile.json
#
# ★ 数据模型（★ 与 `html/player_profile.html` 的 payload 口径一致）：
#   · 姓名 / 生日 / 地址 = **直接记录**（以最后一次非空提交为准）
#   · 性别 / 年龄       = **权重累积**：每次提交只给「对应选项」加 WEIGHT_STEP 点
#       性别选项：男 / 女 / 其他
#       年龄段  ：8-12 / 12-16 / 16-18 / 18+
#   即页面里填的东西**不直接等于结论**，只是往对应桶里添几点权重；谁分高谁占优。
#
# ★ 归一化口径（HTML 侧也复述了一份，但**以这里为准**）：
#   · 性别：原始选择是「男」→男、「女」→女，其余一切（双性/皮卡丘/其他/…）→其他；
#     仅当原始选择缺失时才采纳对方传入的 gender_bucket（手工投放 html_cmd.json 时也可能没有）。
#   · 年龄：由生日算到「今天」的实岁，再落桶；<12 归 8-12（下限兜底），≥18 归 18+。
#
# ★ 本脚本是 autoload 单例（名 PlayerProfile），故**不声明 class_name**（同名会撞）。
extends Node

const PROFILE_FILE := "player_profile.json"
const VERSION: int = 1

# 一次提交给对应选项增加的权重（"几点"）
const WEIGHT_STEP: int = 3

const GENDER_OPTIONS: Array[String] = ["男", "女", "其他"]
const AGE_BUCKETS: Array[String] = ["8-12", "12-16", "16-18", "18+"]
# 各年龄段的上界（不含）：<12 → 8-12；<16 → 12-16；<18 → 16-18；否则 18+
const AGE_BUCKET_UPPER_BOUNDS: Array[int] = [12, 16, 18]

# history 只留最近 N 条（画像页展示 + 排查用；不做无限增长）
const HISTORY_LIMIT: int = 20

# 画像数据变化（提交 / 重置 / 重新读盘）—— 画像页据此实时刷新
signal changed(profile: Dictionary)

var _profile: Dictionary = {}
var _loaded: bool = false


# 惰性加载：不在 _ready 里读盘（SaveManager 就绪顺序 + 启动零开销）
func load_profile() -> Dictionary:
	if not _loaded:
		_profile = read_from_disk()
		_loaded = true
	return _profile


# 从磁盘读一份**归一化**的画像（纯读，不动缓存；画像页也用这个）
func read_from_disk() -> Dictionary:
	var out := empty_profile()
	var path := resolve_path()
	if not FileAccess.file_exists(path):
		return out
	var txt := FileAccess.get_file_as_string(path)
	if txt.strip_edges().is_empty():
		return out
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		push_warning("[PlayerProfile] 画像 JSON 无法解析为对象: " + path)
		return out
	var d: Dictionary = parsed
	# 逐键合并：只接受已知键（容忍手工编辑 / 旧版本缺键 / 多余垃圾键）
	for k in out.keys():
		if d.has(k):
			out[k] = d[k]
	# ★★ 批次 96：**保留未知顶层键**（例：StateRegistry 给状态加的标签字段 tags）。
	#    本页是「读出来 → 改 → 整份写回」，若把不认识的键丢掉，下一次保存就会把
	#    别的系统写进来的字段抹掉（曾经就是这样：标签只在内存里活到下一次保存）。
	for k in d.keys():
		if not out.has(str(k)):
			out[str(k)] = d[k]
	out["version"] = VERSION
	out["weight_step"] = WEIGHT_STEP
	# 权重表补齐 + 剔除未知选项
	out["gender_weights"] = _merge_weights(out.get("gender_weights", {}), GENDER_OPTIONS)
	out["age_weights"] = _merge_weights(out.get("age_weights", {}), AGE_BUCKETS)
	if not (out.get("history", []) is Array):
		out["history"] = []
	return out


# 重新读盘并广播（画像页「刷新」按钮 / 外部系统用）
func reload() -> Dictionary:
	_profile = read_from_disk()
	_loaded = true
	changed.emit(_profile)
	return _profile


# ---- 提交 ----------------------------------------------------------------
# 由 HtmlBridge 的 set_profile 命令调用。返回写入后的完整画像。
func apply_submission(data: Dictionary) -> Dictionary:
	var p := load_profile()

	# ① 直接记录的字段：非空才覆盖（空值绝不清掉旧记录）
	for key in ["name", "birthday", "address"]:
		var v := str(data.get(key, "")).strip_edges()
		if not v.is_empty():
			p[key] = v

	# ② 归一化：性别 / 年龄 → 桶
	var g_bucket := resolve_gender_bucket(data)
	var bday := str(p.get("birthday", ""))
	var age := age_from_birthday(bday)
	var a_bucket := age_bucket_of(age)

	p["gender_input"] = str(data.get("gender", "")).strip_edges()
	p["gender_bucket"] = g_bucket
	p["age"] = age
	p["age_bucket"] = a_bucket

	# ③ 权重累积 —— 只是给对应选项「加几点」
	var gw: Dictionary = p["gender_weights"]
	var aw: Dictionary = p["age_weights"]
	if not g_bucket.is_empty():
		gw[g_bucket] = int(gw.get(g_bucket, 0)) + WEIGHT_STEP
	if not a_bucket.is_empty():
		aw[a_bucket] = int(aw.get(a_bucket, 0)) + WEIGHT_STEP

	p["submit_count"] = int(p.get("submit_count", 0)) + 1
	p["updated_at"] = Time.get_datetime_string_from_system(false, true)

	var hist: Array = p.get("history", [])
	hist.append({
		"at": str(p["updated_at"]),
		"name": str(p.get("name", "")),
		"birthday": bday,
		"age": age,
		"age_bucket": a_bucket,
		"gender_input": str(p["gender_input"]),
		"gender_bucket": g_bucket,
		"weight": WEIGHT_STEP,
	})
	while hist.size() > HISTORY_LIMIT:
		hist.pop_front()
	p["history"] = hist

	_profile = p
	_loaded = true
	persist()
	changed.emit(_profile)
	return _profile


# 清空画像（画像页「重置」/ 调试用）
func reset() -> Dictionary:
	_profile = empty_profile()
	_loaded = true
	persist()
	changed.emit(_profile)
	return _profile


func persist() -> Error:
	var path := resolve_path()
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		var err := FileAccess.get_open_error()
		push_error("[PlayerProfile] 无法写入画像: %s (err=%d)" % [path, err])
		return err
	f.store_string(JSON.stringify(_profile, "  "))
	f.close()
	print("[PlayerProfile] 已写入画像 -> " + path)
	return OK


# ---- 自检：文件残缺 → 按默认值重建 -------------------------------------------
# ★ 由 SaveManager.ensure_temp_files() 在「进入游戏前 / 载入存档前」调用。
# 「残缺」= 文件不存在 / 文本为空 / 无法解析为对象 / 缺顶层关键键 / 容器类型不符。
# 修复时**不丢已有合法字段**：read_from_disk() 本身就是「默认值 + 逐键合并」，
# 缺的键用默认值补、整份坏掉则退回默认值。返回是否真的写盘（true = 补建或修复过）。
func ensure_file() -> bool:
	var path := resolve_path()
	var need := true
	if FileAccess.file_exists(path):
		var txt := FileAccess.get_file_as_string(path)
		if not txt.strip_edges().is_empty():
			var parsed: Variant = JSON.parse_string(txt)
			if parsed is Dictionary:
				need = not _profile_intact(parsed as Dictionary)
	if not need:
		return false
	_profile = read_from_disk()
	_loaded = true
	persist()
	print("[PlayerProfile] 画像文件残缺 → 已按默认值重建 -> " + path)
	return true


# 顶层关键键是否齐全、容器类型是否匹配（只判「够不够用」，不校验取值语义）
static func _profile_intact(d: Dictionary) -> bool:
	for k in ["name", "birthday", "address", "history"]:
		if not d.has(k):
			return false
	if not (d["history"] is Array):
		return false
	if not (d.has("gender_weights") and (d["gender_weights"] is Dictionary)):
		return false
	if not (d.has("age_weights") and (d["age_weights"] is Dictionary)):
		return false
	return true


# ---- 归一化工具（探针 / 其它系统可直接调用）--------------------------------

# 性别桶：优先由原始选择推导（单一真源），仅在原始字段缺失时采纳对方传入的 bucket
func resolve_gender_bucket(data: Dictionary) -> String:
	var raw := str(data.get("gender", "")).strip_edges()
	if not raw.is_empty():
		return normalize_gender(raw)
	var given := str(data.get("gender_bucket", "")).strip_edges()
	if GENDER_OPTIONS.has(given):
		return given
	return ""


static func normalize_gender(raw: String) -> String:
	var s := raw.strip_edges()
	if s.is_empty():
		return ""
	if s == "男":
		return "男"
	if s == "女":
		return "女"
	return "其他"


# 生日（YYYY-MM-DD）→ 今天的实岁；无法解析返回 -1
static func age_from_birthday(birthday: String) -> int:
	var s := birthday.strip_edges()
	if s.length() < 10:
		return -1
	var parts := s.split("-")
	if parts.size() < 3:
		return -1
	var y := int(parts[0])
	var m := int(parts[1])
	var d := int(parts[2])
	if y <= 0 or m < 1 or m > 12 or d < 1 or d > 31:
		return -1
	var now := Time.get_datetime_dict_from_system()
	var age: int = int(now["year"]) - y
	if int(now["month"]) < m or (int(now["month"]) == m and int(now["day"]) < d):
		age -= 1
	if age < 0:
		age = 0
	return age


# 年龄 → 年龄段；age < 0（无生日）返回空串；<12 归 8-12、≥18 归 18+（上下限兜底）
static func age_bucket_of(age: int) -> String:
	if age < 0:
		return ""
	for i in AGE_BUCKET_UPPER_BOUNDS.size():
		if age < AGE_BUCKET_UPPER_BOUNDS[i]:
			return AGE_BUCKETS[i]
	return AGE_BUCKETS[AGE_BUCKETS.size() - 1]


# 当前权重最高的性别（全 0 返回空串；并列取靠前者）
func top_gender() -> String:
	return _top_of(load_profile().get("gender_weights", {}), GENDER_OPTIONS)


# 当前权重最高的年龄段（同上）
func top_age_bucket() -> String:
	return _top_of(load_profile().get("age_weights", {}), AGE_BUCKETS)


func gender_weights() -> Dictionary:
	return load_profile().get("gender_weights", {})


func age_weights() -> Dictionary:
	return load_profile().get("age_weights", {})


func empty_weights(options: Array) -> Dictionary:
	var d := {}
	for o in options:
		d[str(o)] = 0
	return d


# 公开只读入口（其它脚本用方法取列表，避免依赖「实例访问常量」的写法）
func gender_options() -> Array[String]:
	return GENDER_OPTIONS.duplicate()


func age_buckets() -> Array[String]:
	return AGE_BUCKETS.duplicate()


func weight_step() -> int:
	return WEIGHT_STEP


func empty_profile() -> Dictionary:
	return {
		"version": VERSION,
		"name": "",
		"birthday": "",
		"address": "",
		"age": -1,
		"age_bucket": "",
		"gender_input": "",
		"gender_bucket": "",
		"weight_step": WEIGHT_STEP,
		"gender_weights": empty_weights(GENDER_OPTIONS),
		"age_weights": empty_weights(AGE_BUCKETS),
		"submit_count": 0,
		"updated_at": "",
		"history": [],
	}


# 画像文件绝对路径（= %文档%/HelloNyxel/Temp/player_profile.json）
func resolve_path() -> String:
	var dir := "D:/Documents/HelloNyxel/Temp"
	if SaveManager != null and SaveManager.has_method("get_temp_dir"):
		dir = str(SaveManager.get_temp_dir())
	return dir.path_join(PROFILE_FILE)


func _merge_weights(src: Variant, options: Array) -> Dictionary:
	var out := {}
	for o in options:
		var key := str(o)
		var v: int = 0
		if src is Dictionary and (src as Dictionary).has(key):
			v = int((src as Dictionary)[key])
		out[key] = v
	return out


func _top_of(weights: Variant, options: Array) -> String:
	if not (weights is Dictionary):
		return ""
	var best := ""
	var best_v := 0
	for o in options:
		var k := str(o)
		var v := int((weights as Dictionary).get(k, 0))
		if v > best_v:
			best_v = v
			best = k
	return best
