# AGENTS.md — GridAtlas Agent 工作指南

> 面向在本仓库工作的代码 Agent。人类负责描述效果和做最终视觉验收；Agent 负责定位问题、判断该调参数还是改代码，并给出可执行的验收步骤。

## 1. 项目是什么

GridAtlas 是一个 **Godot 4.6（GL Compatibility）** 的 45° 等距网格地图编辑器 + 游戏端运行时。

- **地表**：全屏 fragment shader 对高度场做正交斜视 ray march（`runtime/terrain.gdshader`），开销按屏幕像素走，与地图大小无关。
- **实体**：立牌（billboard），`runtime/actor_card.gd` / `actor_sprite.gdshader`，脚底锚点、画序、逐片元山体遮挡。
- **编辑器**：`editor/Main.tscn`，编辑模式（俯视网格 + 左上 45° 概览）和渲染模式（大 45° 画面）共用同一份地图和文件条。
- **运行时**：`runtime/map_runtime.gd` 把 MapData 变成数据纹理/高程/材质/A*；`runtime/grid_atlas.gd` 负责 45° 视图。
- **示例**：`demos/` 是消费 `maps/first/` 的示例工程；`first` 是演示地图数据，`demos/` 不是地图本身。

项目已经基本完成。默认目标是**小步、可验证的修改**，不要做无必要的大规模重构。

## 2. 运行与验证

本机 Godot 4.6.1；命令里的 `godot` 换成你的可执行文件路径即可。

```bash
# 编辑器
godot --path . editor/Main.tscn          # 或直接 F5，主场景已是 editor/Main.tscn

# 示例
godot --path . res://demos/example.tscn
godot --path . res://demos/grid_atlas_demo.tscn
godot --path . res://demos/occlusion_test.tscn

# 单个脚本语法检查
godot --headless --path . --check-only --script res://editor/main.gd

# 编辑器截图（必须窗口模式；headless 下 --shot 会挂住）
godot --path . -- --shot --shot-map=res://maps/first/first.tres --shot-render
```

`--shot` 输出到 `%TEMP%/gridatlas_shots/tool_<edit|render|material>.png`，可用参数：

- `--shot-map=res://maps/.../xxx.tres`
- `--shot-cell=32,22`
- `--shot-render`（切到 45° 渲染模式）
- `--shot-material`（同时打开材质浮窗）
- `--shot-back`（切渲染后再切回编辑）

示例场景也有自己的 `--shot` 参数：`--shot-yaw=135 --shot-ppm=42 --shot-cell=32,22 --shot-debug`。

> `--shot` 和 demo 截图都需要真实窗口；不要在 `--headless` 下跑截图。

## 3. 目录与职责

| 路径 | 作用 |
|---|---|
| `editor/main.gd` | 唯一持有 MapData，编排保存/打开/撤销/预览/导入/地图列表 |
| `editor/grid_view.gd` | 俯视编辑画布：绘制、笔刷、矩形、平移缩放、右键平移、Shift+左键擦除 |
| `editor/grid_tools.gd` / `.tscn` | 左栏工具面板：陆地/道路/水域/高程/笔刷/静态资源 |
| `editor/props_tool.gd` / `.tscn` | 静态资源库：静态 → 分类 → 本图热点/全局库 |
| `editor/render_tool.gd` / `.tscn` | 渲染参数面板：滑杆全部静态定义，行名 = RenderSettings 属性名 |
| `editor/material_parameters.*` | 颜色/亲和度矩阵浮窗 |
| `editor/game_preview.gd` | 45° 预览：渲染模式大画面 + 编辑模式左上整图概览 |
| `editor/ui/*` | FoldSection、FileBar、Toast、MapBrowser、资源按钮等静态组件 |
| `editor/theme/*` | 唯一主题与样式；不要在代码里临时拼 StyleBox |
| `data/*` | MapData / PropsData / BridgesData / MapAssetLibrary / GridProjection / MapSidecars |
| `runtime/*` | 游戏端运行时：材质、45° 视图、立牌、桥、地表 shader |
| `demos/*` | 游戏端接入示例；读取 `maps/first/` |
| `Docs/*` | 开发期美术管线归档；部分路径指向本地资源，不在仓库里 |

## 4. 数据与文件约定

### 4.1 地图

每张地图一个文件夹，全部文件同名：

```text
maps/<name>/
├── <name>.tres                # MapData：格子数据
├── <name>.look.tres           # RenderSettings：外观参数
├── <name>.props.tres          # PropsData：物件层
├── <name>.bridges.tres        # BridgesData：桥层
├── <name>.assets.tres         # MapAssetLibrary：本图热点 id
└── <name>.terrain.gdshader    # 该图专属地表 shader（首存时从母版拷贝）
```

- **路径一律走 `data/map_sidecars.gd`（MapSidecars）**，不要手写 `get_basename() + ".props.tres"`。
- 新建地图第一次保存会写全部六件；`grid_tools._do_save()` 会先建目录。
- 打开地图：`_on_map_loaded()` 依次 `_load_props` / `_load_bridges` / `_load_asset_library` / `_load_look`。
- 保存地图：`map_saved` → `main._on_map_saved()` 写 props / bridges / look / assets / shader 副本。
- 撤销/重做是整图 + 物件 + 桥的快照；不要绕过 `_push_history()` / `mark_dirty()`。

### 4.2 静态资源

- 定义在全局 `Assets/static_assets/defs/*.tres` + `catalog.tres`；**定义只有一份**，不随地图复制。
- 编辑器导入页（`editor/StaticAssetImportView.*`）负责新建/编辑定义；关闭时主编辑器重读 catalog。
- 每张地图的 `.assets.tres` 只记录 `hot_ids`（最近使用在前），用于「本图热点」快捷区。
- 放置资源、或在当前地图导入/保存资源，会自动加入该图热点；清空全部/撤销不会清热点记录。
- `PropsData` 是并行紧凑数组，读取用 `asset_id_at / rotation_at / cell_at / multiplier_at / visual_offset_at / size_bias_at`。
- 当前仓库**不包含**个人美术资源和 TinySwords 原图。TinySwords 需从
  https://pixelfrog-assets.itch.io/tiny-swords 下载到 `Assets/TinySwords/`；授权允许使用/修改，但**禁止再分发**。
- **不要**把 `Assets/`、`maps/`、`Docs/截图`、`Docs/参考`、`Assets/TinySwords` 强加进 Git。`.gitignore` 已排除；`git add -f` 前先问人。

### 4.3 每图 shader 副本

- 首存/首次点「打开」时，从 `runtime/terrain.gdshader` 拷贝一份到地图文件夹。
- 之后**永不自动覆盖**；改母版不会影响已有地图副本。
- 要让某张图用上新母版：编辑器里「从母版重置」，或直接改该图的 `.terrain.gdshader`。
- `Ctrl+R`（渲染模式）或「重载」会强制读盘，不重启即可看到外部编辑。

## 5. 两种修改方式（先判断，再动手）

人类会描述“我想要什么效果”。先判断：

### 5.1 效果可以通过参数调整

适用于：颜色、强度、频率、宽度、速度、噪声、光照、岸线、纹理等连续可调的外观。

做法：

1. 找到 shader uniform 和对应设置：shader 里 `u_<name>` ↔ `editor/render_settings.gd` 里 `@export var <name>`。
2. 注入是自动的：`MapRuntime._inject_uniforms()` 遍历 `shader.get_shader_uniform_list()`，去掉 `u_` 后 `look.get(name)`，再 `set_shader_parameter("u_"+name, value)`。**没有固定参数列表**。
3. 如果已有滑杆：滑杆行在 `editor/render_tool.tscn` 的某个 `PanelX/VBox/Content/Body/Rows/<name>`，**节点名就是属性名**。改 `Slider.min_value / max_value / step` 即可放宽/收紧可调范围。
4. 如果没有滑杆：在合适的 `Rows` 下加一个静态行，节点名严格等于属性名，包含 `Title`、`Slider`、`Value`。不要用运行时代码生成 UI。
5. 新参数的标准三件套：
   - `runtime/terrain.gdshader`：`uniform float u_foo : hint_range(0.0, 1.0) = 0.5;`
   - `editor/render_settings.gd`：`@export var foo: float = 0.5`
   - `editor/render_tool.tscn`：`Rows/foo` 行 + Slider 范围/步长
6. 不要替人类“定死”一个效果值。改完范围后告诉人类：**哪个模式、哪个分节、哪根滑杆、从多少拖到多少、看什么**，让他自己滑并反馈。
7. 如果地图有 `.terrain.gdshader` 副本，母版改动不会生效；先重置/更新副本，再让人看。

> 当前没有滑杆但仍在用的 shader 参数：`biome`、`coast_warp`、`crease_width`、`crease_dark`。它们通过 `u_<name>` 注入；如果人类要调它们，按上面第 4 步加滑杆，不要删掉属性。

### 5.2 非参数问题：改代码

适用于：布局、交互、保存/加载、撤销、面板行为、性能、遮挡逻辑、新功能、bug。

- 编辑器 UI 以**静态场景**为准：新面板/按钮/分节写进 `.tscn`，优先用 `FoldSection`、`FileBar`、`Toast`、`asset_button.tscn`、`scale_row.tscn`、`category_section.tscn`、`level_button.tscn`。
- 只有数据驱动的列表（资源分类、地图列表、立牌）才在运行时创建。
- 业务编排放 `main.gd`；面板只发信号，不直接改地图数据。
- 改交互时同步状态栏提示（`_update_status_hint`）和 README 操作表。
- 改完后跑语法检查 + 截图冒烟，并请人类做视觉验收。

## 6. 参数修改示例

让人调整“材质硬边带宽”：

1. shader 已有 `uniform float u_band_hard`，`render_settings.gd` 已有 `band_hard`，`render_tool.tscn` 已有 `PanelBlend/.../Rows/band_hard`。
2. 如果范围太窄，只改 `Rows/band_hard/Slider` 的 `max_value`（例如 0.6 → 1.0）和 `step`。
3. 不要改 shader 里的计算，除非效果本身需要新公式。
4. 告诉人类：渲染模式 → 过渡 → 硬边带宽，拖到 0.3–0.8 看草地/沙地边界。
5. 人类反馈后，再决定是否调整 `RenderSettings` 默认值。

如果参数不存在：按 §5.1 第 5 步补齐三件套，然后让人类滑。

## 7. UI 与交互约定

- 一级「静态」→ 二级分类（建筑/树/道具/门/栅栏）→ 三级「本图热点 / 全局库」。
- 二级分类默认收起，标题显示 `建筑 · 24 · 热点 5`；热点每类最多显示最近 8 个，其余在全局库。
- 选中静态资源会自动展开「静态」控制区；切到地形笔刷会自动收起。
- 文件条常驻：`保存`、`▼`（新建/打开/另存为）；打开地图走地图列表或 FileDialog。
- 底部状态栏三区：当前操作提示 / 悬停格信息 / 缩放比例。
- 添加/删除/失败操作通过 `Toast.show(...)` 反馈，不要静默。
- 输入模型：左键绘制、右键拖动平移、Shift+左键擦除、滚轮缩放；R 旋转/切换方向，Esc 退出放置。
- 快捷键：Ctrl+S 保存、Ctrl+Shift+S 另存、Ctrl+N 新建、Ctrl+O 打开、Ctrl+Z/Shift+Z/Y 撤销重做、Ctrl+R（渲染模式）重载 shader。
- 不要引入第二套输入模型或重建 UI 层级；沿用现有组件和主题。

## 8. 代码约定与容易踩的坑

- **投影只有一个定义源**：`data/grid_projection.gd`。地面和立牌必须用同一套 yaw/pitch；不要在新代码里复制投影公式。
- 固定 45°（yaw 135° / pitch 45°）；立牌是竖直 billboard，不按 cos(pitch) 压扁。
- **参数名映射**：`RenderSettings` 属性 `<name>` ↔ shader `u_<name>`；滑杆行节点名 `<name>`。三者必须一致。
- **不要用 `\bname\b` 判断死代码**：`u_biome` 里 `_` 是词字符，`\bbiome\b` 不会匹配。检查 `get_shader_uniform_list()` / `u_<name>`。
- `default_affinity` / `default_land_water` 被 `RenderSettings.get_affinity()` 使用，不是死代码。
- `GridAtlas.screen_to_cell()` 是公开投影 API，即使当前 demo 没调用也保留。
- 每图 shader 副本不会自动跟随母版；改母版后要提醒人类重置副本。
- 边车路径统一走 `MapSidecars`；不要新增第 N 套命名规则。
- 地图数据、资源定义、个人美术、TinySwords 原图都不在仓库；clone 后资源库为空、demo 需要本地地图 + 下载素材。
- 代码/文档注释用中文；提交信息用中文；文件保持 LF（`.gitattributes`）。
- 不要提交 `Assets/`、`maps/`、`Docs/截图`、`Docs/参考`；不要 `git add -f` 被忽略的文件。
- 不要删除 `demos/` 的示例或 `Docs/` 的归档文档，除非人类明确要求。

## 9. 验证清单

改完后至少做：

1. 所有改动的 `.gd` 过 `--check-only`；改 `.tscn`/`.tres` 后跑一次编辑器启动。
2. 编辑器截图：
   ```bash
   godot --path . -- --shot --shot-map=res://maps/first/first.tres --shot-render
   ```
   检查 `%TEMP%/gridatlas_shots/tool_render.png`。
3. 参数改动：确认 `u_<name>` 和 `RenderSettings` 属性都在，滑杆行名正确；**请人类滑动并反馈**，不要自行宣布视觉通过。
4. 代码改动：跑相关 demo 冒烟（`grid_atlas_demo.tscn` 等）；涉及地图保存时，打开/保存/重开一次，确认六件边车都在。
5. 涉及每图 shader：分别验证母版和地图副本；确认「从母版重置」后效果更新。
6. 不要留下临时测试脚本（`_tmp*.gd`）或截图文件在仓库里。

## 10. 不要做的事

- 不要做大规模重构、重命名公开 API、或删除“看起来没用”的代码，除非先确认引用/动态注入。
- 不要用运行时代码重建已经静态定义的 UI。
- 不要硬编码地图/边车/资源路径。
- 不要在 shader 和 GDScript 里各写一份投影公式。
- 不要把效果参数写死成一个值；人类要的是可滑动的范围。
- 不要把 TinySwords 原图或个人美术提交到公开仓库。
- 不要绕过 `mark_dirty` / 撤销栈 / 边车保存流程。
- 不要声称“视觉效果已验收”——最终视觉判断由人类完成。

## 11. 快速定位

| 想改什么 | 先看 |
|---|---|
| 地表颜色/噪声/岸线/光照/纹理 | `runtime/terrain.gdshader` + `editor/render_settings.gd` + `editor/render_tool.tscn` |
| 材质颜色/亲和度矩阵 | `editor/material_parameters.*` + `render_settings.gd` + `runtime/map_runtime.gd` |
| 编辑画布输入/绘制/矩形/擦除 | `editor/grid_view.gd` |
| 左栏工具/笔刷/静态库 | `editor/grid_tools.*`、`editor/props_tool.*` |
| 文件条/地图列表/Toast | `editor/ui/*`、`editor/main.gd` |
| 地图保存/打开/撤销 | `editor/main.gd`、`editor/grid_tools.gd`、`data/map_sidecars.gd` |
| 地图数据/物件/桥/热点 | `data/map_data.gd`、`props_data.gd`、`bridges_data.gd`、`map_asset_library.gd` |
| 45° 运行时/立牌/遮挡 | `runtime/map_runtime.gd`、`grid_atlas.gd`、`actor_card.gd`、`actor_sprite.gdshader` |
| 投影/坐标 | `data/grid_projection.gd` + `runtime/terrain.gdshader` |
| 示例接入 | `demos/README.md`、`demos/*.gd` |
| 世界观/美术管线归档 | `Docs/`（部分路径指向本地资源） |
