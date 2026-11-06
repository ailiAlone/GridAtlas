class_name MapSidecars
extends RefCounted
## 地图边车（sidecar）约定的唯一定义源 + 地表着色器的按图副本逻辑。
##
## 每张地图一个同名子文件夹，边车 = 主 .tres 路径去后缀再拼边车后缀：
##   maps/<图>/<图>.tres               MapData（格子数据）
##   maps/<图>/<图>.look.tres          RenderSettings（外观参数）
##   maps/<图>/<图>.props.tres         物件层
##   maps/<图>/<图>.bridges.tres       桥层
##   maps/<图>/<图>.assets.tres        本图热点库（用过的/导入的静态资源 id）
##   maps/<图>/<图>.terrain.gdshader   地表着色器专属副本（本文件负责）
##
## 着色器副本规则（首存拷贝、永不自动覆盖）：
##   · 地图第一次保存（或第一次点"打开着色器"）时，把母版 runtime/terrain.gdshader
##     原样拷进地图文件夹，之后这份副本完全属于这张图——改它不影响其他地图，
##     母版更新也不会自动同步进来（要取回母版用"从母版重置"）。
##   · 只拷 .gdshader 不拷 .uid：副本由引擎按路径加载，uid 重复反而会冲突。
##   · 加载时副本存在用副本、否则回退母版，所以旧地图无需迁移，保存前一直用母版。
##   · 强制读盘（CACHE_MODE_REPLACE）：在外部编辑器改完代码，下次 setup 或
##     reload_shader() 就是新内容，不用重启。

const MASTER_TERRAIN_SHADER: String = "res://runtime/terrain.gdshader"

# 边车后缀：路径一律由"主图路径去 .tres + 后缀"派生，五类边车共用一套规则
const LOOK_SUFFIX: String = ".look.tres"
const PROPS_SUFFIX: String = ".props.tres"
const BRIDGES_SUFFIX: String = ".bridges.tres"
const LIBRARY_SUFFIX: String = ".assets.tres"
const TERRAIN_SUFFIX: String = ".terrain.gdshader"


## 外观参数边车；map_path 为空返回空串
static func look_path(map_path: String) -> String:
	return _with_suffix(map_path, LOOK_SUFFIX)


## 物件层边车
static func props_path(map_path: String) -> String:
	return _with_suffix(map_path, PROPS_SUFFIX)


## 桥层边车
static func bridges_path(map_path: String) -> String:
	return _with_suffix(map_path, BRIDGES_SUFFIX)


## 本图热点库：记录用过的/导入的静态资源 id，定义仍在全局
static func library_path(map_path: String) -> String:
	return _with_suffix(map_path, LIBRARY_SUFFIX)


## 地图专属着色器路径
static func terrain_shader_path(map_path: String) -> String:
	return _with_suffix(map_path, TERRAIN_SUFFIX)


static func _with_suffix(map_path: String, suffix: String) -> String:
	if map_path.is_empty():
		return ""
	return map_path.get_basename() + suffix


## 确保副本存在：没有就拷一份母版，已存在原样返回（永不覆盖）。
## 返回副本路径；map_path 为空或拷贝失败返回空串。
static func ensure_terrain_copy(map_path: String) -> String:
	var path: String = terrain_shader_path(map_path)
	if path.is_empty():
		return ""
	if FileAccess.file_exists(path):
		return path
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err: Error = DirAccess.copy_absolute(MASTER_TERRAIN_SHADER, path)
	if err != OK:
		push_warning("着色器副本拷贝失败(%s): %s" % [error_string(err), path])
		return ""
	return path


## 用母版覆盖副本（"从母版重置"）：会抹掉这张图里定制过的着色器代码，调用方先确认。
## 返回是否成功；副本不存在时等价于 ensure_terrain_copy。
static func reset_terrain_copy(map_path: String) -> bool:
	var path: String = terrain_shader_path(map_path)
	if path.is_empty():
		return false
	if not FileAccess.file_exists(path):
		return not ensure_terrain_copy(map_path).is_empty()
	var err: Error = DirAccess.copy_absolute(MASTER_TERRAIN_SHADER, path)
	if err != OK:
		push_warning("着色器副本重置失败(%s): %s" % [error_string(err), path])
		return false
	return true


## 加载这张地图该用的地表着色器：副本优先、母版兜底。
## CACHE_MODE_REPLACE 强制读盘并刷新缓存，外部编辑后的改动立即可见。
static func load_terrain_shader(map_path: String) -> Shader:
	var path: String = terrain_shader_path(map_path)
	if path.is_empty() or not FileAccess.file_exists(path):
		path = MASTER_TERRAIN_SHADER
	return ResourceLoader.load(path, "Shader", ResourceLoader.CACHE_MODE_REPLACE) as Shader
