# the words/world_templates.gd
# 「世界」节点模板注册表 —— 对齐 items/pc_hardware/pc_catalog.gd::get_part_template() 的约定：
# 模板是**字典定义**（不是 .tscn），用于**批量创建相似的「世界节点」**。
#   · 例：WorldTemplates.get_template("planet") → 覆写实例数据 → 生成任意多个相似行星；
#   · 后续加小行星 / 卫星时沿用同一套（新增模板即可，不改建树代码）。
class_name WorldTemplates
extends RefCounted

const T_STAR := "star"          # 恒星（太阳）：level 0，自发光
const T_PLANET := "planet"      # 行星：level 1
const T_DWARF := "dwarf"        # 矮行星：level 1，半径很小
const T_ASTEROID := "asteroid"  # 小行星：level 1，半径更小
const T_MOON := "moon"          # 卫星：level 2，绕行星公转
## 小行星带：level 1 的**容器**节点（与行星同级），自身**无实体**（radius = 0 ⇒ 不建球体/拾取体），
## 只作为列表里的分组行 + 带内小行星（level 2，与卫星同级）的父节点。
const T_BELT := "belt"

## 未指定贴图时的模板默认素材：**相对世界 JSON 的 texture_base 的文件名**
## （现为 `res://textures/world/`，见 the words/data/solar_system.json；
##  行星/恒星/矮行星在 planets/ 下，卫星在 moons/ 下，小行星在 asteroids/ 下）。
const DEFAULT_TEXTURE := "planets/earth_day_2k.jpg"
## 模板各自的默认贴图（恒星 / 矮行星不该长着地球的脸）。
const STAR_TEXTURE := "planets/sun_surface_2k.jpg"
const DWARF_TEXTURE := "planets/eris_hypothetical_surface_2k.jpg"
## ★ 小行星默认贴图：素材库没有各小行星的真实表面图 ⇒ 取
##   「06_小行星表面_程序化可平铺材质」的 C 型（碳质）底色图占位（见 solar_system.json._说明_贴图）。
const ASTEROID_TEXTURE := "asteroids/asteroid_c_type_2k.jpg"
## ★ 卫星默认贴图：素材库没有这些小卫星的真实表面图 ⇒ 取
##   「05_小行星表面_可平铺岩石材质_CC0」里的一张裸岩底色图占位（见 solar_system.json._说明_贴图）。
const MOON_TEXTURE := "moons/rock_bare_2k.jpg"


static func all_templates() -> Array:
	return [T_STAR, T_PLANET, T_DWARF, T_ASTEROID, T_MOON, T_BELT]


## 取一个模板定义（不存在的 id 回落 planet）。
static func get_template(id: String) -> Dictionary:
	match str(id):
		T_STAR:
			# ★ 半透明恒星（第十六轮）：`alpha < 1` ⇒ 球体走 ALPHA 混合，背后的行星 / 星空能透出来；
			#   球心另挂一盏 OmniLight（见 WorldView._build_environment）当唯一光源 ⇒ 「半透明球 + 球心光源」。
			# ★ 第十七轮：`emission_energy` 由 1.3 改成 1.8 —— 因为**球壳背面不再绘制**（见 world_node.gd，
			#   用户要求「被阻挡面不去显示」），单层 ALPHA 混合只剩 alpha(0.55) 的亮度，不提能量会发暗。
			#   ★ 与之前的 1.3 不同：现在自发光**带同一张贴图**（emission_texture），亮暗层次由贴图给，
			#     所以提能量不会像「纯色自发光」那样把日面冲成一坨平色。
			return {
				"id": T_STAR,
				"level": 0,
				"tags": ["star", "emissive"],
				"radius": 60.0,
				"color": "#FF8C1A",
				"emissive": true,
				"alpha": 0.55,
				"emission_energy": 1.8,
				"texture": STAR_TEXTURE,
			}
		T_DWARF:
			return {
				"id": T_DWARF,
				"level": 1,
				"tags": ["planet", "dwarf"],
				"radius": 6.0,
				"color": "#C9B8A8",
				"emissive": false,
				"texture": DWARF_TEXTURE,
			}
		T_MOON:
			return {
				"id": T_MOON,
				"level": 2,
				"tags": ["moon"],
				"radius": 0.27,
				"color": "#C9C4BC",
				"emissive": false,
				"texture": MOON_TEXTURE,
			}
		T_ASTEROID:
			return {
				"id": T_ASTEROID,
				"level": 1,
				"tags": ["asteroid"],
				"radius": 0.04,
				"color": "#8E8C86",
				"emissive": false,
				"texture": ASTEROID_TEXTURE,
			}
		T_BELT:
			return {
				"id": T_BELT,
				"level": 1,
				"tags": ["belt"],
				"radius": 0.0,          # ★ 无实体：纯分组容器
				"color": "#8E8C86",
				"emissive": false,
				"texture": "",
			}
		_:
			return {
				"id": T_PLANET,
				"level": 1,
				"tags": ["planet"],
				"radius": 12.0,
				"color": "#4A7DD6",
				"emissive": false,
				"texture": DEFAULT_TEXTURE,
			}
