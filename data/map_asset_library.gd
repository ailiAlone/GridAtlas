class_name MapAssetLibrary
extends Resource
## 本图热点库：记录这张地图"热点"的静态资源 id（最近使用在前）。
##
## 什么会进入热点：
##   · 这张地图里放置过的资源；
##   · 在编辑器中导入/保存资源时，当前地图自动把它记进来。
## 定义本身仍只存在全局 Assets/static_assets/defs/，这里不复制任何 def；
## 热点只用于编辑器「本图热点」快捷区，全局库始终完整。
## 与地图同目录同名边车：maps/<图>/<图>.tres -> maps/<图>/<图>.assets.tres

const MapSidecars = preload("res://data/map_sidecars.gd")

@export var hot_ids: PackedStringArray = PackedStringArray()


static func sidecar_path(map_path: String) -> String:
	return MapSidecars.library_path(map_path)


## 标记热点：已存在则移到最前；返回是否本次新增（用于决定面板是否重建整节）。
func touch(id: StringName) -> bool:
	var key: String = String(id)
	if key.is_empty():
		return false
	var index: int = hot_ids.find(key)
	if index == 0:
		return false
	if index > 0:
		hot_ids.remove_at(index)
	hot_ids.insert(0, key)
	return index < 0


## 去掉空 id、重复 id、以及全局库里已经找不到定义的 id。
func sanitize(defs: Dictionary) -> void:
	var seen: Dictionary = {}
	var out: PackedStringArray = PackedStringArray()
	for raw: String in hot_ids:
		var key: StringName = StringName(raw)
		if key == &"" or seen.has(key) or not defs.has(key):
			continue
		seen[key] = true
		out.append(raw)
	hot_ids = out
