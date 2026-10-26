# block_behaviors.gd
# 积木「行为」系统的命名空间 + 解析 + 标签族 helpers（纯静态工具，不持有状态）。
#
# 行为规格（Block.behaviors: PackedStringArray 的每个元素，顺序=优先级）：
#   · 预设：random_patrol[:组] / ordered_patrol[:组] / area_patrol[:组] / hold_position
#       - 冒号后是可选参数（巡逻组名）；缺省则行为系统从本积木的标签推断组。
#   · 挂载脚本：script:<脚本名>（res://behaviors/<脚本名>.json 里的 behaviors 列表）
#   · 组合节点（行为树，可嵌套，向后兼容）：
#       sel(a,b,c)        优先选择：按序取首个「生效」的子行为
#       if_tag(T,B)       状态守卫：本积木带标签 T 时才执行 B
#       if_not_tag(T,B)   状态守卫：本积木不带标签 T 时才执行 B
#       repeat(B)         循环：每 tick 重新驱动 B（持续重下单，即使正在移动中）
#   组合节点与扁平列表 / 脚本引用可自由混用，向后兼容。
#
# 巡逻 / 队伍用到的积木标签（玩家给积木打这些标签，行为系统读取）：
#   巡逻_xxx            随机巡逻的目标积木（xxx = 组名）
#   巡逻_xxx_数字       顺序巡逻的目标积木（数字 = 顺序，从 1 递增；到最大后回到 1）
#   巡逻区域_xxx_半径    区域巡逻圆心（xxx = 组名；半径 = 数字 px，单位像素）
#   队长_xxx            队伍队长（xxx = 队名）
#   队员_xxx            队伍队员（xxx = 队名）
class_name BlockBehaviors
extends RefCounted

# ---- 预设行为（值用英文，避免中文标识符 / 存档跨平台问题）----
const RANDOM_PATROL := "random_patrol"
const ORDERED_PATROL := "ordered_patrol"
const AREA_PATROL := "area_patrol"
const HOLD_POSITION := "hold_position"

const PRESETS := [RANDOM_PATROL, ORDERED_PATROL, AREA_PATROL, HOLD_POSITION]

# 预设行为的中文显示名（仅 UI 用；值保持英文）
const DISPLAY_NAMES := {
	RANDOM_PATROL: "随机巡逻",
	ORDERED_PATROL: "顺序巡逻",
	AREA_PATROL: "区域巡逻",
	HOLD_POSITION: "坚守岗位",
}

# 行为规格：关键字与参数分隔符 / 脚本挂载前缀
const PARAM_SEP := ":"
const SCRIPT_PREFIX := "script:"

# 组合节点（行为树）操作符；参数为子行为规格，可嵌套，顶层逗号分隔。
#   sel(a,b,c)        优先选择：按序取首个「生效」的子行为
#   if_tag(T,B)       状态守卫：本积木带标签 T 时才执行 B
#   if_not_tag(T,B)   状态守卫：本积木不带标签 T 时才执行 B
#   repeat(B)         循环：每 tick 重新驱动 B（持续重下单）
const COMPOSITE_OPS := ["sel", "if_tag", "if_not_tag", "repeat"]

# ---- 标签族前缀（供巡逻 / 队伍读取；注意 巡逻区域_ 必须先于 巡逻_ 判定）----
const PATROL_PREFIX := "巡逻_"
const PATROL_AREA_PREFIX := "巡逻区域_"
const CAPTAIN_PREFIX := "队长_"
const MEMBER_PREFIX := "队员_"


# ==================== 行为规格解析 ====================

## 解析一个行为规格字符串 → Dictionary：
##   { "kind": "preset"|"script"|"unknown", "name": String, "param": String }
## 空串 → 空 Dictionary（调用方跳过）。
static func parse(spec: String) -> Dictionary:
	var s := spec.strip_edges()
	if s.is_empty():
		return {}
	if s.begins_with(SCRIPT_PREFIX):
		return { "kind": "script", "name": s.substr(SCRIPT_PREFIX.length()).strip_edges(), "param": "" }
	if is_composite(s):
		return parse_composite(s)
	var name := s
	var param := ""
	var idx := s.find(PARAM_SEP)
	if idx >= 0:
		name = s.substr(0, idx).strip_edges()
		param = s.substr(idx + 1).strip_edges()
	if name in PRESETS:
		return { "kind": "preset", "name": name, "param": param }
	return { "kind": "unknown", "name": name, "param": param }


## 某规格是否为组合节点（sel/if_tag/if_not_tag/repeat）。
static func is_composite(spec: String) -> bool:
	var s := spec.strip_edges()
	if s.is_empty():
		return false
	var op_end := s.find("(")
	if op_end <= 0 or not s.ends_with(")"):
		return false
	var op := s.substr(0, op_end)
	if not (op in COMPOSITE_OPS):
		return false
	return _balanced_parens(s.substr(op_end))


## 顶层逗号切分（组合节点参数含逗号/嵌套括号时，只在最外层按逗号切）。
## 用于解析 sel(a,b,c) 这类节点的子行为，以及把用户输入的「逗号分隔规格串」拆成多个规格。
static func split_top_level(s: String) -> PackedStringArray:
	var out := PackedStringArray()
	var depth := 0
	var cur := ""
	for i in s.length():
		var c := s[i]
		if c == "(":
			depth += 1
			cur += c
		elif c == ")":
			depth -= 1
			cur += c
		elif c == "," and depth == 0:
			out.append(cur.strip_edges())
			cur = ""
		else:
			cur += c
	if not cur.strip_edges().is_empty():
		out.append(cur.strip_edges())
	return out


## 解析组合节点 → { "kind":"composite", "op":String, "args":PackedStringArray }。
## args 保留为原始子规格字符串（惰性，交给运行时递归求值）。
static func parse_composite(spec: String) -> Dictionary:
	var s := spec.strip_edges()
	var op_end := s.find("(")
	var op := s.substr(0, op_end)
	var inner := s.substr(op_end + 1, s.length() - op_end - 2)
	var args := split_top_level(inner)
	return { "kind": "composite", "op": op, "args": args }


static func _balanced_parens(s: String) -> bool:
	var depth := 0
	for i in s.length():
		var c := s[i]
		if c == "(":
			depth += 1
		elif c == ")":
			depth -= 1
			if depth < 0:
				return false
	return depth == 0


static func is_preset(spec: String) -> bool:
	return parse(spec).get("kind", "") == "preset"


static func is_script(spec: String) -> bool:
	return parse(spec).get("kind", "") == "script"


## 行为规格的中文显示名（已选列表 / 调试展示用）；组合节点递归渲染。
static func display_name(spec: String) -> String:
	var p := parse(spec)
	if p.is_empty():
		return ""
	var kind: String = p.get("kind", "")
	if kind == "composite":
		var op := str(p["op"])
		var args = p["args"]
		match op:
			"sel":
				var parts := PackedStringArray()
				for a in args:
					parts.append(display_name(str(a)))
				return "优先选择(" + " ; ".join(parts) + ")"
			"if_tag":
				var tag := str(args[0]) if args.size() > 0 else ""
				var body := display_name(str(args[1])) if args.size() > 1 else ""
				return "若有标签·%s 则 %s" % [tag, body]
			"if_not_tag":
				var tag := str(args[0]) if args.size() > 0 else ""
				var body := display_name(str(args[1])) if args.size() > 1 else ""
				return "若无标签·%s 则 %s" % [tag, body]
			"repeat":
				var body := display_name(str(args[0])) if args.size() > 0 else ""
				return "循环·%s" % body
			_:
				return spec
	if kind == "script":
		return "脚本·" + str(p["name"])
	if kind == "preset":
		var base := str(DISPLAY_NAMES.get(p["name"], p["name"]))
		var pm := str(p["param"])
		if not pm.is_empty():
			base += "(%s)" % pm
		return base
	return spec


# ==================== 标签族解析 ====================

## 巡逻目标标签 巡逻_xxx → 组名 xxx；非此类返回 ""。
## ★ 必须先判 巡逻区域_（它也是 巡逻_ 的子串）。
static func patrol_group(tag: String) -> String:
	if tag.begins_with(PATROL_PREFIX) and not tag.begins_with(PATROL_AREA_PREFIX):
		return tag.substr(PATROL_PREFIX.length())
	return ""


## 顺序巡逻标签 巡逻_xxx_数字 → { "group": String, "number": int }；非此类 group=""、number=-1。
static func ordered_patrol_info(tag: String) -> Dictionary:
	if not tag.begins_with(PATROL_PREFIX) or tag.begins_with(PATROL_AREA_PREFIX):
		return { "group": "", "number": -1 }
	var rest := tag.substr(PATROL_PREFIX.length())
	var parts := rest.split("_")
	if parts.size() < 2:
		return { "group": rest, "number": -1 }
	var num_str := parts[parts.size() - 1]
	if not num_str.is_valid_int():
		return { "group": rest, "number": -1 }
	var group := "_".join(parts.slice(0, parts.size() - 1))
	return { "group": group, "number": int(num_str) }


## 区域巡逻标签 巡逻区域_xxx_半径 → { "group": String, "radius": float }；非此类 group=""、radius=-1。
static func area_region(tag: String) -> Dictionary:
	if not tag.begins_with(PATROL_AREA_PREFIX):
		return { "group": "", "radius": -1.0 }
	var rest := tag.substr(PATROL_AREA_PREFIX.length())
	var parts := rest.split("_")
	if parts.size() < 2:
		return { "group": rest, "radius": -1.0 }
	var r_str := parts[parts.size() - 1]
	if not r_str.is_valid_float():
		return { "group": rest, "radius": -1.0 }
	var group := "_".join(parts.slice(0, parts.size() - 1))
	return { "group": group, "radius": float(r_str) }


## 队长 / 队员标签 → 队名 xxx；非此类返回 ""。
static func team_group(tag: String) -> String:
	if tag.begins_with(CAPTAIN_PREFIX):
		return tag.substr(CAPTAIN_PREFIX.length())
	if tag.begins_with(MEMBER_PREFIX):
		return tag.substr(MEMBER_PREFIX.length())
	return ""


## 某标签是否为队长标签（返回队名；非则空串）
static func captain_group(tag: String) -> String:
	if tag.begins_with(CAPTAIN_PREFIX):
		return tag.substr(CAPTAIN_PREFIX.length())
	return ""


## 某标签是否为队员标签（返回队名；非则空串）
static func member_group(tag: String) -> String:
	if tag.begins_with(MEMBER_PREFIX):
		return tag.substr(MEMBER_PREFIX.length())
	return ""
