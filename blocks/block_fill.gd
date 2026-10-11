# block_fill.gd
# 积木「填充」的来源：图片 / 动图 / 骨骼动画。
# 注意：骨架动画尚未制作，骨骼部分仅做预留。
# 文件标准：路径(变量) + 填充模式(变量)。填充模式预留了未来更多模式。
class_name BlockFill
extends Resource

# 填充模式（未来可能新增更多，故用枚举并预留枚举值）
enum Mode {
	KEEP_MAX_RATIO,   # 等比缩放，完整显示，不裁剪（默认）
	FILL,             # 拉伸铺满，可能变形
	CENTER,           # 居中，按原尺寸（预留）
	TILE,             # 平铺重复（预留）
	ORIGINAL,         # 左上角原尺寸（预留）
}

# 动画类型：区分静态图 / 动图 / 骨骼
enum AnimType {
	STATIC,        # 普通图片（png/jpg...）
	ANIMATED,      # GIF / 动图（播放逻辑预留）
	SKELETON,      # 骨骼动画（预留，暂未制作）
}

@export var path: String = ""                        # 资源路径（res:// 或 user://）
@export var fill_mode: Mode = Mode.KEEP_MAX_RATIO
@export var anim_type: AnimType = AnimType.STATIC

# 路径非空才视为有效填充来源
func is_valid() -> bool:
	return path != ""
