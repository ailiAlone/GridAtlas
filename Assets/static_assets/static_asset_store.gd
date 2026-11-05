class_name StaticAssetStore
extends RefCounted
## 静态资源定义的磁盘布局与读写：
##   res://Assets/static_assets/catalog.tres      资源路径索引
##   res://Assets/static_assets/defs/<id>.tres   单个资源定义
## PNG 仍放在 Assets/（被 git 忽略）；这里只保存路径字符串。

const ROOT_DIR: String = "res://Assets/static_assets"
const DEFS_DIR: String = ROOT_DIR + "/defs"
const CATALOG_PATH: String = ROOT_DIR + "/catalog.tres"

## 运行时裁切缓存：路径 + 内容区 -> ImageTexture（不生成裁切文件）
static var _texture_cache: Dictionary = {}


static func ensure_dirs() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DEFS_DIR))


static func load_catalog() -> StaticAssetCatalog:
	if ResourceLoader.exists(CATALOG_PATH):
		var res: Resource = load(CATALOG_PATH)
		if res is StaticAssetCatalog:
			return res as StaticAssetCatalog
		push_warning("资源目录不是 StaticAssetCatalog: " + CATALOG_PATH)
	return StaticAssetCatalog.new()


static func save_catalog(catalog: StaticAssetCatalog) -> Error:
	ensure_dirs()
	return ResourceSaver.save(catalog, CATALOG_PATH)


## ID 是稳定标识；文件名只做最基本的非法字符替换，不改变 ID 本身。
static func file_path_for(id: StringName) -> String:
	var name: String = String(id)
	for ch: String in ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]:
		name = name.replace(ch, "_")
	if name.strip_edges().is_empty():
		name = "unnamed"
	return DEFS_DIR + "/" + name + ".tres"


static func save_def(def: StaticAssetDef) -> String:
	if def == null:
		return ""
	ensure_dirs()
	var path: String = file_path_for(def.id)
	var err: Error = ResourceSaver.save(def, path)
	if err != OK:
		push_error("资源定义保存失败(%s): %s" % [error_string(err), path])
		return ""
	# ResourceSaver 不会更新 ResourceLoader 的缓存。同一进程里紧接着 load(path)
	# 会拿回保存前的旧定义（例如分类仍是“道具”）。强制用磁盘版本替换缓存。
	ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
	return path


static func load_def(path: String) -> StaticAssetDef:
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	var res: Resource = load(path)
	if res is StaticAssetDef:
		return res as StaticAssetDef
	push_warning("不是有效的静态资源定义: " + path)
	return null


static func load_all(catalog: StaticAssetCatalog) -> Array[StaticAssetDef]:
	var out: Array[StaticAssetDef] = []
	if catalog == null:
		return out
	for path: String in catalog.asset_paths:
		var def: StaticAssetDef = load_def(path)
		if def != null:
			out.append(def)
	return out


## 载入并规范化整份目录，返回 id -> StaticAssetDef。
## 编辑器、45° 预览和游戏端都从这里取，避免各自重复 normalize/过滤。
static func load_def_map() -> Dictionary:
	var out: Dictionary = {}
	var catalog: StaticAssetCatalog = load_catalog()
	for def: StaticAssetDef in load_all(catalog):
		def.normalize()
		if String(def.id).is_empty():
			push_warning("忽略没有 ID 的资源定义: " + def.resource_path)
			continue
		out[def.id] = def
	return out


static func delete_def_file(path: String) -> bool:
	if path.is_empty() or not FileAccess.file_exists(path):
		return false
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK


## 资源的贴图：按 content_rect 裁到内存纹理，透明区保留。
## 自定义 sampler 不会应用 AtlasTexture.region，
## 所以必须交给 shader 一张已经裁好的 ImageTexture。
static func texture_for(def: StaticAssetDef) -> Texture2D:
	if def == null or def.texture_path.is_empty():
		return null
	var key: String = def.texture_path + "|" + str(def.content_rect)
	if _texture_cache.has(key):
		return _texture_cache[key] as Texture2D
	var src: Texture2D = load(def.texture_path) as Texture2D
	if src == null:
		push_warning("资源贴图无法载入: " + def.texture_path)
		return null
	var full: Image = src.get_image()
	if full == null:
		return null
	var rect: Rect2i = def.content_rect
	if rect.size.x <= 0 or rect.size.y <= 0:
		rect = Rect2i(Vector2i.ZERO, full.get_size())
	rect = rect.intersection(Rect2i(Vector2i.ZERO, full.get_size()))
	if rect.size.x <= 0 or rect.size.y <= 0:
		return null
	var part: Image = full.get_region(rect)
	var tex: ImageTexture = ImageTexture.create_from_image(part)
	_texture_cache[key] = tex
	return tex


## 重新导入/覆盖 PNG 后清缓存（编辑器刷新资源库时调用）
static func clear_texture_cache() -> void:
	_texture_cache.clear()
