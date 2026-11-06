class_name GridProjection
extends RefCounted
## 固定 45° 相机与立牌矩形的唯一定义。
##
## 导入页的占地编辑器、地图的 GridView/GamePreview、游戏端的 GridAtlas
## 都从这里取投影和立牌矩形，避免三处各写一份公式后慢慢漂移。
##
## 坐标约定：
##   yaw   相机方位（从目标看向相机的方向）：135° = 相机在地图东南
##   fd    视线方向（相机 → 场景）= (-sin(yaw), cos(yaw))
##   rt    屏幕右向 = (-fd.y, fd.x)
##   screen = (p·rt, p·(-fd)·sin(pitch) - height·cos(pitch))
## 地面的 z 只在斜视投影里乘 cos(pitch)，立牌本身是竖直 billboard，不压扁。

const YAW: float = 2.356194490192345      # 135°
const PITCH: float = 0.7853981633974483   # 45°


static func forward_axis(yaw: float = YAW) -> Vector2:
	return Vector2(-sin(yaw), cos(yaw))


static func right_axis(yaw: float = YAW) -> Vector2:
	var fd: Vector2 = forward_axis(yaw)
	return Vector2(-fd.y, fd.x)


## 地面点 → 屏幕（单位：格，不含相机的平移）
static func project_ground(pos: Vector2, yaw: float = YAW, pitch: float = PITCH) -> Vector2:
	var fd: Vector2 = forward_axis(yaw)
	var rt: Vector2 = right_axis(yaw)
	return Vector2(pos.dot(rt), pos.dot(-fd) * sin(pitch))


## 地面点 + 世界高度 → 屏幕（单位：格，不含相机的平移）
static func project_point(pos: Vector2, height: float = 0.0,
		yaw: float = YAW, pitch: float = PITCH) -> Vector2:
	return project_ground(pos, yaw, pitch) - Vector2(0.0, height * cos(pitch))


## 立牌节点的矩形（单位：格）。
## foot 是地面锚点（已经过斜视投影）；art_offset 是屏幕格偏移；
## lift 是左右侧抬升比例。返回值和 ActorCard 的立牌矩形一致：
## 顶部 = foot + offset - art_h*(1+最大抬升)，高度 = art_h + 左右抬升跨度。
static func art_rect(foot: Vector2, art_size: Vector2, art_offset: Vector2,
		lift: Vector2) -> Rect2:
	var span: float = absf(lift.x - lift.y) * art_size.y
	var top: float = -art_size.y * (1.0 + maxf(lift.x, lift.y))
	return Rect2(foot + art_offset + Vector2(-art_size.x * 0.5, top),
		Vector2(art_size.x, art_size.y + span))
