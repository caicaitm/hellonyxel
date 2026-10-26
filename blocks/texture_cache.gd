# blocks/texture_cache.gd
# 贴图缓存（积木填充图 / 文本框底图 / 背包物品图标 / 对话头像与事件图 共用）。
#
# 为什么需要：积木填充是在 _draw() 里画的，每帧都会调用一次；
#   若每帧都 ResourceLoader.load() 读盘，几十块带图积木就能把帧率拖垮。
#   这里按路径缓存 Texture2D，只加载一次。
#
# ★★★ 两条加载通道（玩家自定义贴图靠第二条，无需重启）★★★：
#   ① res:// 已导入资源 → ResourceLoader.load()
#      走 Godot 导入产物（.import + .godot/imported/*.ctex）。
#      ★ res:// 下的文件默认**全部都会被导入**，与代码是否引用无关；
#        不需要的素材目录放一个空的 `.gdignore` 即可整棵跳过导入。
#   ② user:// 与磁盘绝对路径 → Image.load() + ImageTexture.create_from_image()
#      **运行期直接读文件，完全不需要导入**，也不进 .godot/imported。
#      玩家把图丢进用户素材目录（%文档%/HelloNyxel/Textures/）即可使用，
#      补文件后不用重启游戏（下文的负缓存策略保证这点）。
#
# ★ 加载失败也**记成 null**（仅限 res://）：否则坏路径会导致每帧重复尝试加载
#   （同样的开销，且刷屏告警）。
#   ★★ 但**不能**缓存 user:// / 绝对路径的失败 —— 否则玩家补上文件后
#      必须重启才能生效，与「随时换图」的需求冲突。
#   成功的结果一律缓存（积木每帧 _draw，绝不能每帧读盘）。
#   文件被替换后想立刻刷新：TextureCache.forget(path) 或 clear()。
#
# 用法：
#   var tex := TextureCache.fetch("res://textures/foo.png")
#   var tex2 := TextureCache.fetch("D:/Documents/HelloNyxel/Textures/cat.png")
#   if tex != null: ... else: 纯色兜底
#
# ★★ 方法**不能命名为 get**：Object 已有内置 `get()`，同名会触发
#    Parse Error: Could not resolve external class member "get"（本项目实际踩到）。
class_name TextureCache
extends RefCounted

static var _cache: Dictionary = {}


## 取贴图。路径为空 / 文件不存在 / 不是贴图 → 返回 null（调用方自行兜底）。
static func fetch(path: String) -> Texture2D:
	var p := str(path).strip_edges()
	if p == "":
		return null
	if _cache.has(p):
		return _cache[p]
	var tex := _load_imported(p)
	if tex == null:
		tex = _load_res_unimported(p)   # res:// 磁盘有文件但没被 Godot 导入（缺 .import）→ 直读原图兜底
	if tex == null:
		tex = _load_runtime_file(p)     # user:// / 绝对路径（玩家自定义，运行期直读）
	# ★ 成功的**一律缓存**：积木在 _draw() 里每帧调 fetch，不缓存等于每帧读盘。
	if tex != null:
		_cache[p] = tex
	# ★ 只有 res:// 才把「失败」记进缓存（项目内文件是固定的，坏路径不该每帧重试）。
	#   user:// 与绝对路径加载失败时不记 → 玩家补上文件后立刻可用，不用重启。
	elif p.begins_with("res://"):
		_push_warning_unimported(p)
		_cache[p] = null
	return tex


## 丢弃某条缓存（玩家换了磁盘上的图之后调用，下次 fetch 会重新读）。
static func forget(path: String) -> void:
	_cache.erase(str(path).strip_edges())


## 清空缓存（切换存档 / 热重载资源时用；正常游玩不需要）
static func clear() -> void:
	_cache.clear()


# ==================== 两条加载通道 ====================

## 通道①：res:// 已导入资源。返回 null = 不存在 / 不是贴图 / 未导入。
static func _load_imported(p: String) -> Texture2D:
	if not p.begins_with("res://"):
		return null
	if not ResourceLoader.exists(p):
		return null
	var res := ResourceLoader.load(p, "Texture2D")
	if res is Texture2D:
		return res
	push_warning("[TextureCache] 不是贴图资源：%s" % p)
	return null


## 通道①补充：res:// 下「磁盘有文件、但 Godot 没导入」（缺 .import）的兜底。
## 典型场景：在 property 编辑器里给积木填了一个 res:// 贴图路径，但该项目还没被 Godot
##   打开导入过（或导入产物丢失）→ ResourceLoader.exists 返回 false → 通道①返回 null。
## 这里改用 ProjectSettings.globalize_path 拿真实磁盘绝对路径，Image.load 直读原始图片，
##   实现「指定路径即生效」，不再依赖「必须先让 Godot 导入一次」。
## ★ 仅 res:// 走这条路；user:// / 绝对路径仍是通道②。
## ★ 成功一律缓存（与通道①同待遇）；失败不缓存（保持「补文件后即时可用」的语义）。
static func _load_res_unimported(p: String) -> Texture2D:
	if not p.begins_with("res://"):
		return null
	var disk := ProjectSettings.globalize_path(p)
	if disk == "" or not FileAccess.file_exists(disk):
		return null
	var img := Image.new()
	if img.load(disk) != OK:
		push_warning("[TextureCache] 图片解码失败（res:// 未导入直读）：%s" % p)
		return null
	return ImageTexture.create_from_image(img)


## 通道②：运行期直读磁盘（user:// 或绝对路径），**无需 Godot 导入**。
## ★ Image.load() 同时吃 res:// / user:// / 绝对路径，但对 res:// 仍要求已导入，
##   所以这条路只用于「玩家自己的文件」。
static func _load_runtime_file(p: String) -> Texture2D:
	if not (p.begins_with("user://") or _is_absolute(p)):
		return null
	if not FileAccess.file_exists(p):
		return null
	var img := Image.new()
	if img.load(p) != OK:
		push_warning("[TextureCache] 图片解码失败：%s" % p)
		return null
	return ImageTexture.create_from_image(img)


## 是否磁盘绝对路径（`D:/…`、`D:\…`、UNC `\\srv\share`、POSIX `/…`）
static func _is_absolute(p: String) -> bool:
	if p.begins_with("/") or p.begins_with("\\"):
		return true
	# Windows 盘符：`D:/…` 或 `D:\…`（第 2 个字符是冒号）
	if p.length() >= 3 and p.substr(1, 2).begins_with(":"):
		return true
	return false


## res:// 且磁盘上有文件却「不存在」于 ResourceLoader = **没有被 Godot 导入**。
## 与「路径写错」是两回事，必须分开提示，否则极易误判成路径错误甚至「图片太大」。
static func _push_warning_unimported(p: String) -> void:
	if FileAccess.file_exists(p):
		push_warning("[TextureCache] 贴图未导入（磁盘有文件但缺 .import）：%s —— "
			+ "项目内图片请用 Godot 打开一次本项目完成导入；"
			+ "若这是玩家自定义图片，请放到用户素材目录（%文档%/HelloNyxel/Textures/）并用绝对路径" % p)
	else:
		push_warning("[TextureCache] 贴图不存在：%s" % p)