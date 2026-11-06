class_name MapAssetLibrary
extends Resource
## 本图使用库：记录这张地图用过的静态资源 id（最近使用在前）。
##
## 定义本身仍只存在全局 Assets/static_assets/defs/，这里不复制任何 def；
## 地图只保存"用过哪些"，用于编辑器「本图使用」快捷区。
## 与地图同目录同名边车：maps/<图>/<图>.tres -> maps/<图>/<图>.assets.tres

const MapSidecars = preload("res://data/map_sidecars.gd")

@export var asset_ids: PackedStringArray = PackedStringArray()


static func sidecar_path(map_path: String) -> String:
	return MapSidecars.library_path(map_path)


## 标记使用：已存在则移到最前；返回是否本次新增（用于决定面板是否重建整节）。
func touch(id: StringName) -> bool:
	var key: String = String(id)
	if key.is_empty():
		return false
	var index: int = asset_ids.find(key)
	if index == 0:
		return false
	if index > 0:
		asset_ids.remove_at(index)
	asset_ids.insert(0, key)
	return index < 0


## 去掉空 id、重复 id、以及全局库里已经找不到定义的 id。
func sanitize(defs: Dictionary) -> void:
	var seen: Dictionary = {}
	var out: PackedStringArray = PackedStringArray()
	for raw: String in asset_ids:
		var key: StringName = StringName(raw)
		if key == &"" or seen.has(key) or not defs.has(key):
			continue
		seen[key] = true
		out.append(raw)
	asset_ids = out
