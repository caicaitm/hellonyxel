# block_fill.gd
# 积木「填充」的来源：图片 / 动图 / 骨骼动画。
# 静态图与骨骼动画已可用：骨骼的 path 指向 .tscn 场景（内含 Sprite2D + AnimationPlayer），
# 由 blocks/block.gd::_draw_skeleton_fill 用 SubViewport 离屏播放后画进积木。
# 动图（GIF）尚未接入播放，仍按首帧静态绘制。
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
	SKELETON,      # 骨骼动画：path = .tscn 场景，播放其 AnimationPlayer
	YSM,           # YSM（是，史蒂夫）未加密模型包：path = 包目录 / .zip / ysm.json
}

# 瓦片尺寸模式：绝对像素 / 积木宽高的倍数
enum TileSizeMode {
	ABSOLUTE,      # 瓦片尺寸 = 绝对像素
	MULTIPLE,      # 瓦片尺寸 = 积木宽高 × 倍数（tile_size.x/y 当作倍数，如 0.2 = 20%）
}

# 填充顺序：顺序（按格循环）/ 随机（按位置稳定取格，不闪烁）
enum TileFillOrder {
	SEQUENTIAL,    # 顺序：沿边/中按源格顺序循环取用
	RANDOM,       # 随机：每格按位置哈希稳定取用（移动积木图案不变）
}

@export var path: String = ""                        # 资源路径（res:// 或 user://）
@export var fill_mode: Mode = Mode.KEEP_MAX_RATIO
@export var anim_type: AnimType = AnimType.STATIC

# ============ 瓦片（九宫格 / 网格）贴图系统 ============
# 源图按 tile_split 切分为 N×M 格（最小 2×2）。当 N≥2 且 M≥2 时启用瓦片绘制：
#   - N≥3 且 M≥3：标准九宫格——四角格固定满尺寸贴四角，上下/左右边带由对应边格平铺
#     （末端可裁切半张 = 不完全平铺），中部由内格平铺。
#   - 任一维 < 3（如 2×2 / 2×3 / 3×2）：退化网格——积木切为 N×M 等分区，每区恰好一张源格铺满。
# 顺序 / 随机：边带与中部需要重复取格时生效（退化网格每区仅一张格，顺序无意义）。
# 瓦片尺寸：绝对值（像素）或积木宽高倍数。
@export var tile_split: Vector2i = Vector2i(1, 1)    # 源图切分列数×行数（1×1 = 不切分）
@export var tile_size_mode: int = TileSizeMode.ABSOLUTE
@export var tile_size: Vector2 = Vector2(32.0, 32.0) # 单张瓦片绘制尺寸
@export var tile_fill_order: int = TileFillOrder.SEQUENTIAL

# 是否启用瓦片绘制（仅当切分 ≥ 2×2）
func is_tiled() -> bool:
	return tile_split.x >= 2 and tile_split.y >= 2

# 路径非空才视为有效填充来源
func is_valid() -> bool:
	return path != ""
