# 游戏端使用示例

这个文件夹演示 **GridAtlas 的产出如何直接用在游戏里**：只吃
`MapData`（`.tres`）+ `RenderSettings`（`.look.tres`），就能拿到外观、玩法和
固定 45° 的游戏视图。编辑器“切换渲染”的大画面也直接复用这里的 `GridAtlas`，
所以工具里看到的 45° 画面就是游戏画面。

## 三个场景

| 场景 | 用途 |
|---|---|
| `example.tscn` | 俯视 A* 示例：缩放/平移/点击寻路，验证 `MapRuntime` 基础地形寻路（不含物件阻挡，不使用 45° 视图） |
| `grid_atlas_demo.tscn` | **固定 45° 游戏视角**：相机跟随、走格、资源立牌、遮挡规则 |
| `occlusion_test.tscn` | 遮挡验证：合成一道山脊横在角色与相机之间，检查半透明/消失 |

```bash
godot --path . res://example/example.tscn
godot --path . res://example/grid_atlas_demo.tscn
godot --path . res://example/occlusion_test.tscn
```

`grid_atlas_demo.tscn` 操作：WASD 走格（按屏幕方向）｜滚轮缩放｜右键拖动平移｜
G 显示格线（确认地面与实体同一套投影）｜R 回到角色。
截图参数：`--shot [--shot-yaw=135] [--shot-ppm=42] [--shot-cell=32,22] [--shot-debug]`。

## 文件

| 文件 | 作用 |
|---|---|
| `map_runtime.gd` | 运行时核心：数据纹理/高程/噪声/色表/亲和度 → 材质；通行代价与 A* |
| `grid_atlas.gd` / `.tscn` | 45° 地图视图：全屏地表 + 同一投影的实体容器 + 调试图层 |
| `actor_card.gd` | 立牌：程序化占位或贴图，共用脚底锚点/画序/高度场遮挡 |
| `actor_sprite.gdshader` | 贴图立牌着色器（静态资源 / 示例玩家）；遮挡算法与 `actor_card.gdshader` 相同 |
| `actor_card.gdshader` | 程序化占位立牌（贴图缺失时的退路） |
| `debug_grid.gd` | 相机附近逐格画四边形（顶点抬到该格高度），验证投影对齐 |
| `grid_atlas_demo.gd` | 演示场景：取景、相机跟随、走格、缩放、截图 |
| `occlusion_test.gd` | 合成山脊的遮挡验证 |
| `example.gd` / `overlay.gd` | 俯视基础地形寻路示例与覆盖层（只用于验证 `MapRuntime` / A*） |
| `../GridData/props_data.gd` | 静态资源实例边车；`asset_ids` / `rots` / `cells` |
| `../GridData/static_asset_*.gd` | 静态资源定义/目录/读写：footprint、阻挡掩码、PNG、立牌参数 |
| `../GridTool/props_tool.*` | 编辑器物件面板（资源库 / 横竖方向 / 清空） |
| `../RenderView/game_preview.*` | 编辑器 45° 视图：渲染模式大画面 + 编辑模式左上角整图概览（复用这里的运行时与立牌） |
| `../Assets/TinySwords/` | 示例玩家立牌使用的 `Warrior_Idle.png`（由 `demo_unit.gd` 裁切）；不再作为可放置资源 |

## 固定 45° 视角

相机方位固定（`yaw`），不随玩家旋转。默认：

- **相机方位 135°（地图东南）**，看向西北；这是"从地图右下角看中心"的方向
- **俯角 45°**；`pitch`/`yaw` 都是 `GridAtlas` 的属性，改一行就能换。相机固定不旋转，
  预览和游戏都只允许缩放/平移
- **只画可见视口**：地面着色器按屏幕像素步进（开销 ∝ 屏幕大小，与地图大小无关）；
  立牌超出视口由 CanvasItem 自动剔除
- **相机跟随**：中心限制在地图范围内、视口允许伸出图外，角色走到地图边缘也不会离开画面。
  代价是图边之外会露出天空；海面或雾化边界后续再补
- **陡壁不画纹理**：斜角视图里坡度约 >0.12 级/格的坡面不再画俯视结构图案/微凹凸/
  草叶/岩石颗粒，只保留材质底色和光照，避免纹理沿坡拉长；工具小面板的 45° 整图概览同样适用。
  陡面本身是地图的高度台阶（h4→h3→h2）；不想看到陡面就降低 look.height_scale 或把高度改缓
- **游戏视图不画地图边缘的假切面**：图外直接露天空；工具小面板的 45° 整图概览与游戏视图一致，
  也不画切面

投影公式（着色器与 GDScript 完全一致）：

```
fd = (-sin yaw, cos yaw)        视线方向（相机 → 场景）
rt = (-fd.y, fd.x)              屏幕右向
screen = 视口中心 + ppm · ( (P-C)·rt , (P-C)·(-fd)·sin(pitch) - z·cos(pitch) )
```

`GridAtlas` 里 `cell_to_screen / screen_to_cell / projected_point` 是同一组公式；
实体的脚底、点击拾取、调试格线都走它，所以不会出现"地面在动、树在滑"。

## 遮挡规则（按实体类别区分）

立牌着色器（贴图走 `actor_sprite.gdshader`，无贴图退回 `actor_card.gdshader`）从脚底格
出发，沿"朝相机"的水平方向采样平滑高程场：该处地表高于视线
（`立牌高度 + 水平距离·tan(pitch)`）时判为被挡。

| 实体 | `u_fade` | 被山挡住时 |
|---|---|---|
| 角色 | 0.38 | 半透明，玩家始终能看见自己 |
| 树/建筑等静态物体 | 0.0 | 完全消失；高的树只可能露出树梢 |

判定是**逐片元**的：同一棵树的下半截可以被挡掉、树冠还露在脊线外，而不是整块
贴图一起淡出。`occlusion_test.tscn` 就是验证这个的。

## 物件（开发期放置）

工具左侧面板滚到“物件”：

- **资源库**来自 `GridData/static_assets/catalog.tres`，每个已导入的资源一个按钮；
  点右侧「编辑」弹出资源导入页，保存/删除后关闭，主编辑器会自动重读 catalog（也可点“刷新”）。
- **方向**：资源库上方的「横向 / 竖向」两个按钮控制下一次放置。竖向会交换占地范围
  （3×1 门变成 1×3），阻挡掩码跟着转，45° 立牌贴图水平镜像（左右 `art_lift` 也换边）。
  鼠标悬停在已放资源上按 **R** 在横/竖之间切换；鼠标不在资源上按 R 只切换待放置方向。
  越界/压水/与其它实例重叠会拒绝切换，切换进入撤销/重做。
- **左键放置，右键按占地范围删除**。落点框绿色 = 可放；红色 = 越界 / 压水 / 与已有实例的
  占地范围重叠。
- 静态资源按定义里的 `footprint` 占地、按 `blocking_cells` 阻挡 A*（例如 3×1 院门只有两端
  门柱挡路，中间门洞可通行），落点预览会直接用红/绿格标出。
- 资源落点以鼠标格为中心（奇数边长正好居中；2×2 时鼠标格是左上角）；不能放在水面上，
  同一片占地范围不能叠放。
- **保存地图时同时写 `<地图名>.props.tres`**（例：`second.tres → second.props.tres`）。
  撤销/重做、改尺寸时裁掉越界物件，都包含物件层（含资源实例的 `asset_ids` / `rots`）。

运行 `grid_atlas_demo.tscn` 会自动加载同名边车：按实例数据生成立牌，并把实际阻挡格写进 A*。
静态资源实例会读取同一份资源定义，贴图按 `content_rect` 裁切，立牌大小/侧向拉伸/图片偏移
（`art_size` / `art_lift` / `art_offset`）与导入页看到的一致；立牌脚底用**旋转后占地范围**的中心，
竖向资源会把贴图水平镜像（左右 `art_lift` 换边），但仍是正面朝向相机。
没有边车时显示空地图（不再生成随机林）。

在编辑器里放完物件**不必先保存**，直接切“渲染模式”就能在大画面里看到 45° 立牌；
保存是为了把物件写进 `.props.tres`，让游戏和 demo 也能读到。

编辑器已移除内置物件按钮和立牌缩放滑条：新物件全部来自资源库。内置物件的运行路径也已
完全移除——旧边车（`kinds/cells/scales` 格式）里的实例在载入时丢弃，不再渲染/阻挡。示例场景的
玩家立牌仍使用 `Assets/TinySwords/` 的战士贴图（`example/demo_unit.gd`），它不是可放置的地图资源。


## 接进自己的游戏

```gdscript
const RUNTIME_SCRIPT = preload("res://example/map_runtime.gd")

var rt = RUNTIME_SCRIPT.new()
rt.setup(load("res://GridData/maps/second.tres"), load("res://GridData/maps/second.look.tres"))
$GridAtlas.setup(rt)                     # 地表 + 实体容器就位
$GridAtlas.set_center_cell(Vector2(32.5, 32.5))
$GridAtlas.set_zoom(42.0)

rt.is_walkable(cell)                     # 可通行
rt.move_cost(cell)                       # 移动代价（越小越快，0 = 不可通行）
rt.height_at(cell)                       # 高程（级）
rt.water_at(cell)                        # 水域类型
rt.find_path(from_cell, to_cell)         # A* 路径（格子序列）
rt.path_cost(path)                       # 路径总代价
rt.smooth_level(cell) / rt.terrain_z(cell)  # 渲染高度（与着色器同一张场）

# 静态资源定义（物件边车里只会有静态资源实例）
var asset_defs = {}
for def in StaticAssetStore.load_all(StaticAssetStore.load_catalog()):
	asset_defs[def.id] = def

# 物件（可选）：与地图同名的 <map>.props.tres，保存过物件后才会生成
var props = load("res://GridData/maps/second.props.tres")
props.set_asset_defs(asset_defs)         # 定义里查 footprint/阻挡格
rt.apply_props(props)                    # 按资源定义只写实际 blocking_cells
```

约定：`cell_to_screen` / `screen_to_cell` 用的是**格坐标**（0..map_size，格心在
x+0.5），不是世界像素。`MapRuntime.CELL_SIZE`（16）只服务于旧的俯视示例。

物件数据是并行数组：`asset_ids / rots / cells(交错 x,y)`，读取用
`props.asset_id_at(i) / props.rotation_at(i) / props.cell_at(i)`。
旧边车如果只有 `kinds/cells/scales`、没有 `asset_ids`，载入时 `sanitize()` 会整体清空；
`asset_ids[i]`、`rots[i]`、`cells[2i]` 才是有效数据。占地/阻挡格从
`GridData/static_assets/defs/<id>.tres` 解析（实例不重复存档）。
**地图和物件是两个文件**，拷贝地图时记得带上 `.props.tres`。

示例场景的玩家立牌仍使用 `Assets/TinySwords/Units/Warrior_Idle.png`，由
`example/demo_unit.gd` 在内存里裁切；素材的再分发限制见 `Assets/TinySwords/SOURCE.md`。

新的静态资源来自 `GridData/static_assets/defs/*.tres` + `Assets/ChineseVillage/
Processed/delivery/<族>/`（最终交付件按分类分中文文件夹、中文命名）；导入与占地范围
定义流程见 `Docs/三期-资源导入.md`。

## 性能取舍

地表是直接把着色器铺在全屏 `ColorRect` 上（每帧按屏幕像素算）。这最省事、
缩放最锐利，开销按可视像素走，和地图尺寸无关。GTX 1050 / GL Compatibility
实测（`--bench`，含约 100 个立牌的遮挡采样）：

- 1280×720：**4.4 ms/帧**（228 fps）
- 1920×1080：**9.4 ms/帧**（107 fps）

地图更大或 GPU 更弱时：

1. **渲染到 SubViewport**（按世界分辨率渲一次，地图/外观/相机变化时才重渲），
   游戏里只贴一张纹理；水面动效单独叠一层。
2. **缩放 LOD**：远景关掉草叶、碎石、浮雕高频（按 `ppm` 传 uniform 开关）。

## 已知取舍

- **立牌不压缩**：2.5D 里常见做法，树/人保持竖直比例。遮挡换算时按
  `实际世界高度 = 美术高度 / cos(pitch)` 处理；要严格按 3D 高度压扁立牌，
  把 `u_art_height` 改成 `美术高度` 并同步压缩立牌尺寸即可。
- 渲染的岸线/道路边界是连续场与圆角，玩法边界是整格——**玩法以整格为准**。
- 默认代价：草 1.0、沙 1.15、荒地 1.3、雪 1.4、沼泽 2.0、冰 0.8；
  道路 0.5~0.75；浅水 3.0；深水不可通行；每高一级 +3%。
  都在 `map_runtime.gd` 顶部，按游戏需要改。
- 地块高度是**视觉数据**：`look.height_scale` 默认 2.5 格/级，适合展示地形，
  但一步 2.5 格高的"台阶"在玩法上是否可走，需要在移动规则里单独决定。
- 物件与地图分文件保存：拷贝/移动地图时把同名的 `.props.tres` 一起带上。
- 静态资源立牌目前固定第 0 帧；示例玩家也只取 `Warrior_Idle` 的第 0 帧，动画还没接。
- 只接入了示例所需的蓝队战士；其他队伍色、UI、特效、资源点和 terrain tileset 未使用。
  素材来源与再分发限制见 `Assets/TinySwords/SOURCE.md`。
- 编辑模式左上角是 45° 整图概览（有立牌、只读）；渲染模式左上角是俯视网格镜像。
  45° 立牌和遮挡看这个概览、渲染模式大画面或 `grid_atlas_demo.tscn`。
- 立牌按占地中心格取一个地表高度：跨坡的房子/树可能有一侧悬空，后续可做
  多脚采样或“占地压平”。
