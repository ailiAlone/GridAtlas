class_name StaticAssetCatalog
extends Resource
## 静态资源目录：只记录每个定义的 .tres 路径，真正的定义仍是独立文件。
## 这样新增/编辑一个素材不会重写整份大 catalog，也方便单独拷贝/版本管理。

@export var asset_paths: PackedStringArray = PackedStringArray()


func add_path(path: String) -> bool:
	if path.is_empty() or asset_paths.has(path):
		return false
	asset_paths.append(path)
	return true


func remove_path(path: String) -> bool:
	var index: int = asset_paths.find(path)
	if index < 0:
		return false
	asset_paths.remove_at(index)
	return true
