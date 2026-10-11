# sub_menu.gd
# 次级菜单：完全复用 ContextMenu 的所有逻辑（继承即可）
# 由 ContextMenu._open_submenu 用 SubMenu.new() 实例化。
extends ContextMenu
class_name SubMenu
