# GridAtlas

45° 等距网格地图编辑器与运行时，基于 **Godot 4.6**（GL Compatibility）。

![Level_1_new 的 45° 游戏视图](Docs/2D资产风格管线/截图/Level_1_new-主建筑补齐-45度.png)

GridAtlas 把「编辑地图」和「在游戏里渲染地图」做成同一套数据的两端：编辑器负责画地形、放物件、搭桥、调外观；运行时只读地图文件，就能得到固定 45° 的成片画面和 A* 通行数据。编辑器「渲染模式」里看到的大画面，就是游戏实际会看到的画面。

## 特性

- **固定 45° 等距投影**：默认 yaw 135° / pitch 45°，不随角色旋转，只允许缩放和平移；地面、立牌、点击拾取共用同一套投影公式，不会出现「地面在动、树在滑」。
- **全屏光线步进地表**：高度场、水域、道路、噪声、光照都在 `runtime/terrain.gdshader` 里按屏幕像素计算，缩放锐利，开销只与可视像素有关，与地图尺寸无关。
- **编辑 / 渲染双模式**：编辑画布左上角常驻 45° 整图概览；切到渲染模式可全屏调外观，两模式共用同一份地图和文件条。
- **地图自包含**：每张图一个文件夹，格子数据、外观参数、物件层、桥层、本图使用记录、专属着色器都放在里面，拷贝整套即可迁移。
- **本图使用库**：每张地图单独记录用过的静态资源，面板顶部提供「本图使用」快捷区；资源定义仍全局唯一，改一次定义所有地图同步。
- **每张地图独立的着色器代码**：首次保存时从母版拷贝一份，之后修改这张图不影响其他地图；母版更新也不会自动覆盖，需要时用「从母版重置」取回。
- **物件与桥**：静态资源库（建筑 / 树木 / 道具 / 门 / 栅栏）、横竖旋转、植物倍率与个体差异；独木桥 / 木桥 / 石桥按两次点击生成。
- **运行时直接可用**：`MapRuntime` 提供通行性、移动代价、高程与 A* 寻路，`GridAtlas` 负责画面与立牌遮挡。

## 快速开始

1. 安装 **Godot 4.6**（使用 GL Compatibility 渲染器）。
2. 用 Godot 打开本目录的 `project.godot`。
3. 按 <kbd>F5</kbd> 运行，主场景是 `editor/Main.tscn`。

启动后是一张 64×64 的空地图，可以直接开画。左栏顶部文件条提供「保存」按钮和「▼」文件菜单（新建 / 打开 / 另存为）；快捷键为 <kbd>Ctrl</kbd>+<kbd>N</kbd> 新建、<kbd>Ctrl</kbd>+<kbd>O</kbd> 打开、<kbd>Ctrl</kbd>+<kbd>S</kbd> 保存。

> **注意**：美术资源和地图数据没有入库（见「仓库内容」），所以 clone 后资源库是空的，示例地图也不在仓库里。编辑器本身可以正常启动并绘制地形、道路、水域。

## 编辑器操作

### 鼠标

| 操作 | 作用 |
| --- | --- |
| 左键拖动 | 用当前笔刷绘制 |
| **右键拖动** | 平移画布 |
| **Shift + 左键** | 擦除（拖框即为矩形擦除） |
| 滚轮 | 缩放 |
| 右键 / 中键拖动（渲染模式） | 平移 45° 视图 |

### 键盘

| 快捷键 | 作用 |
| --- | --- |
| <kbd>Ctrl</kbd>+<kbd>S</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>S</kbd> | 保存 / 另存为 |
| <kbd>Ctrl</kbd>+<kbd>N</kbd> / <kbd>Ctrl</kbd>+<kbd>O</kbd> | 新建 / 打开地图 |
| <kbd>Ctrl</kbd>+<kbd>Z</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Z</kbd> / <kbd>Ctrl</kbd>+<kbd>Y</kbd> | 撤销 / 重做 |
| <kbd>R</kbd> | 旋转鼠标下的物件；不在物件上时切换待放置方向 |
| <kbd>Esc</kbd> | 退出物件放置 |
| <kbd>Ctrl</kbd>+<kbd>R</kbd>（渲染模式） | 重新读盘加载地表着色器 |

## 地图文件结构

地图按文件夹组织，全部文件同名，边车路径由主图路径去后缀推导：

```text
maps/<地图名>/
├── <地图名>.tres                # MapData：格子数据（陆地/道路/水域/高程/山体）
├── <地图名>.look.tres           # RenderSettings：外观参数（颜色、噪声、光照、高度比例）
├── <地图名>.props.tres          # PropsData：物件层
├── <地图名>.bridges.tres        # BridgesData：桥层
├── <地图名>.assets.tres         # MapAssetLibrary：本图用过的静态资源 id
└── <地图名>.terrain.gdshader    # 该地图专属的地表着色器（首次保存时生成）
```

- 后五个是边车（sidecar），缺失时回退默认值，旧地图无需迁移。
- `<地图名>.assets.tres` 只记录这张图用过的资源 id（最近使用在前），供面板顶部的「本图使用」快捷区使用；资源定义仍然只有全局一份，修改定义会同步到所有地图。旧地图第一次打开时会自动推导并补写这一层。
- 着色器副本只在第一次保存（或第一次点「打开着色器」）时从 `runtime/terrain.gdshader` 拷贝；之后**永不自动覆盖**。在外部编辑器改完代码，回到编辑器点「重载」（或 <kbd>Ctrl</kbd>+<kbd>R</kbd>）即可看到新内容。
- 「从母版重置」会覆盖当前地图的着色器副本，操作前会确认。
- 移动地图时把整个文件夹一起移动即可。

## 项目结构

| 目录 | 内容 |
| --- | --- |
| `editor/` | 编辑器：主界面、编辑画布、工具面板、渲染参数、资源导入页、地图列表 |
| `runtime/` | 游戏端运行时：地表材质、45° 视图、立牌与遮挡、程序化桥、地表着色器 |
| `data/` | 数据层：`MapData`、`PropsData`、`BridgesData`、投影公式、网格定义、边车约定 |
| `demos/` | 游戏端示例：俯视 A*、固定 45° 视角、遮挡验证 |
| `Assets/` | 静态资源（美术文件与导入定义） |
| `maps/` | 地图数据 |
| `Docs/` | 美术风格管线、ID 映射等文档与参考截图 |

## 在游戏里使用

```gdscript
const RUNTIME_SCRIPT = preload("res://runtime/map_runtime.gd")

var rt = RUNTIME_SCRIPT.new()
rt.setup(load("res://maps/first/first.tres"),
		load("res://maps/first/first.look.tres"))
$GridAtlas.setup(rt)
$GridAtlas.set_center_cell(Vector2(32.5, 32.5))
$GridAtlas.set_zoom(42.0)

rt.is_walkable(cell)          # 可通行
rt.move_cost(cell)            # 移动代价（0 表示不可通行）
rt.height_at(cell)            # 高程（级）
rt.find_path(from_cell, to_cell)  # A* 路径
```

更完整的接入说明、遮挡规则、性能数据见 [`demos/README.md`](demos/README.md)。

## 运行示例

```bash
godot --path . res://demos/example.tscn           # 俯视 A* 寻路
godot --path . res://demos/grid_atlas_demo.tscn   # 固定 45° 游戏视角
godot --path . res://demos/occlusion_test.tscn    # 山体遮挡验证
```

## 仓库内容

本仓库**只提交代码、文档与截图**：

- `Assets/` 下的美术文件（PNG、导入后的 `.tres`）体积较大，且部分素材有再分发限制，未入库；仅保留 `.gd` 脚本与 `.uid`。
- `maps/` 下的地图数据未入库，仅保留 `*.terrain.gdshader` 示例副本。
- 因此 clone 后可以运行编辑器，但资源库为空、示例地图和 demo 数据需要自备。

## 文档

- [`demos/README.md`](demos/README.md)：游戏端接入、45° 投影公式、遮挡规则、性能取舍
- [`Docs/2D资产风格管线/全流程方案.md`](Docs/2D资产风格管线/全流程方案.md)：美术资源从概念到导入的完整流程
- [`Docs/2D资产风格管线/ArtBible.md`](Docs/2D资产风格管线/ArtBible.md)：美术风格规范

## License

本仓库暂未指定开源许可证。如需允许他人使用、修改或分发，请补充 `LICENSE` 文件。
