# AI 素材制作：Tiny Swords 风格 + 固定 45° 相机

目标：用 AI 生成能直接放进 GridAtlas 的物件/角色贴图。
不是做插画，是做**透明底、脚底锚定、相机角度一致**的游戏立牌。

## 1. 先理解相机：45° 不是等距瓦片

GridAtlas 的固定相机：

- **yaw = 135°**：相机在地图东南，看向西北；
- **pitch = 45°**：从地平线向下俯 45°；
- 地面按屏幕像素做正交斜视步进；**立牌本身是竖直的 billboard**，不跟着地面压扁。

因此，立牌贴图应该画成：

- **从东南方向看的 3/4 前视**（能看到正面和右侧面），屋顶可见；
- **底边水平**，像站在一条水平线上；
- **没有地面砖/菱形底座**；地面交给渲染器；
- 光影默认左上受光（渲染配置里的光照方位/高度角可调），和 Tiny Swords 及地形着色器一致；
- 物体下方只有一小块椭圆软阴影，不要长投影。

### 关于“±45°”

“45°”在这里是**俯角**，不是等距地图的菱形角度。两种理解要分开：

1. **立牌朝向**：固定相机只需要一个“面向东南/镜头”的视角。生成 ±45° 两个朝向不会让建筑更贴合，
   反而会和固定相机打架；建筑要换朝向就需要给物件数据加 rotation/facing 字段，并准备多套图。
2. **真等距（isometric）图**：如果图里画了菱形地面、45° 斜边底座，它属于地面投影资产，不适配
   当前“竖直立牌 + 水平底边”的锚点，会像贴纸一样浮着。不要生成等距 tile。
3. 如果你以后想让相机旋转，单张 billboard 就不够了：要么做 4/8 方向精灵，要么换 3D。

**推荐**：所有物件都生成“东南 3/4 前视、俯角约 45°、平底、无地面”的单张立牌；
树/灌木/石头可以更正面。角色如果只做静态演示，一张面向镜头的即可。

## 2. 风格拆解（提示词里要写清的）

Tiny Swords 的观感来自这些约束，不是“像素风”三个字：

- 16-bit/2D RPG 像素画；**1–2 px 深色描边**（深海军蓝/深棕，不用纯黑）；
- 低饱和环境 + 高饱和主体；**每个材质 3–4 档明暗**，没有渐变；
- 屋顶青蓝/蓝绿（#2C6E7E、#3E8FA0、#63AFC0 附近）；
- 木结构暖棕（#6B4328、#9A6238、#C98F55）；
- 奶油色墙（#D8C7A2、#F0E0BC）；
- 石头冷灰（#5A5F66、#8A8D8E、#C2C2B8）；
- 深绿针叶（#1F4A36、#2F6B4A、#6FAE5A），秋树（#B96A2E、#E0A33F、#F2C96B）；
- 强轮廓、大色块、圆润造型；不要细碎噪点、不要抗锯齿、不要照片纹理；
- 底边有很短的椭圆软阴影，光源左上。

从素材包里取色最准：用 Aseprite 打开 `Tiny Swords` 的 `.aseprite` 源文件，
吸管取色、看描边宽度和帧尺寸；不要凭感觉调色。

## 3. 工具选择

按“能不能稳定出游戏资产”排序：

1. **Retro Diffusion / PixelLab**：像素画专用，支持角色/建筑、方向、动画帧，最容易接近这个风格。
2. **Scenario**：游戏资产生成，可做私有风格训练；适合批量保持同一套外观。
3. **Stable Diffusion / Flux + pixel-art LoRA**：配合 IP-Adapter（风格参考）+ ControlNet
   （轮廓/深度控制），可控性最高，但需要搭环境。
4. **Midjourney**：出概念和剪影最快，`--sref` 做风格参考；但它不是真正的像素网格，
   透明底也不可靠，最终要下采样 + 手工清理。

清理工具：**Aseprite**（首选，源包也有 `.aseprite` 可研究）或 Pixelorama。
去背景：本地 `remove-bg` 工具可以，但像素画更推荐**纯色洋红/绿幕背景 + 颜色键**，
再手工修边缘；AI 的 alpha 经常半透明脏边。

> 注意：不要把 Tiny Swords 的原始 PNG/Aseprite 上传到公开模型做训练或公开发布；
> 授权允许使用和修改，不允许再分发原始素材。可以拿来做**本地视觉参考**和取色，
> 但生成模型/服务的使用条款也要单独确认。

## 4. 提示词模板

把“相机、底边、轮廓、调色板、像素密度”写进去。生成时固定 seed/参考图。

### 建筑（木屋/塔/城堡）

```
pixel art game sprite, single medieval fantasy building, 2.5D orthographic view from the south-east,
camera pitched 45 degrees downward, three-quarter front-right view, roof visible,
blue-green tiled roof, cream plaster walls, dark timber frame, wooden door, stone foundation,
strong top-left sunlight, chunky 1-2 pixel dark outline, limited 24-color palette,
crisp pixel clusters, no anti-aliasing, no gradients, flat horizontal base, small soft oval shadow,
transparent background, centered, no ground tile, no isometric diamond base, no UI, no text,
target 128x192 pixels
```

### 树 / 灌木 / 石头

```
pixel art game sprite, single conifer tree, 2.5D orthographic view from the south-east,
camera pitched 45 degrees downward, upright billboard, flat horizontal base,
layered dark green and teal needles, warm brown trunk, strong top-left light,
chunky dark outline, limited palette, crisp pixels, no anti-aliasing,
small soft oval shadow, transparent background, centered, no ground tile,
target 192x256 pixels
```

### 角色

```
pixel art game sprite, cute chibi blue-armored knight, front three-quarter view facing the south-east,
camera pitched 45 degrees downward, idle pose, sword and shield, 1-2 pixel dark outline,
limited palette, crisp pixel clusters, no anti-aliasing, feet at the bottom edge,
small soft shadow, transparent background, centered, no ground tile, no UI,
target 192x192 pixels
```

### 负向提示词

```
isometric floor tile, diamond base, top-down flat view, 3D render, photorealistic,
blurry, anti-aliased, gradient, noise, text, watermark, UI, multiple objects,
cropped, front elevation only, long cast shadow
```

要点：

- **不要写“isometric”**，除非你真的要等距 tile；写 `2.5D orthographic, 3/4 front-right, flat base`。
- **不要写“front view”**；建筑会变成正面平视，屋顶看不见。写 `three-quarter front-right, roof visible`。
- 生成尺寸取目标的 2–4 倍（如 512×768 → 128×192），最后用**最近邻**下采样。
- 先在低分辨率下检查剪影；剪影读不出来，细节再多也没用。

## 5. 从图到工程：接入步骤

1. **生成 + 选图**：单物体、透明/纯色背景、平底、无地面。
2. **下采样**：最近邻缩到目标高度（建筑 128×192，树 192×256，灌木 128×128，
   石头 64×64，角色 192×192），减色到 24–32 色，补 1–2 px 描边，修掉孤立像素。
3. **去背景**：颜色键后检查边缘；保留底部软阴影，不要让阴影被抠掉。
4. **量内容区**：取非透明像素的包围盒（x, y, w, h）。工程里用 `Image.get_used_rect()`
   或 Aseprite 的裁剪信息；不要生成裁切 PNG。
5. **放进项目**：`Assets/ChineseVillage/Processed/delivery/`（或 `Assets/Generated/`），
   Godot 自动导入。
6. **在编辑器登记**：打开 GridAtlas，左侧「物件 → 资源库」右侧点「编辑」弹出导入页：
   - 选择透明 PNG，导入页自动检测 alpha、裁出内容区；
   - 设置占地范围、实际阻挡格、立牌宽度与高度拉伸、图片偏移；
   - 保存为 `GridData/static_assets/defs/<id>.tres`，catalog 自动更新。
   不需要维护内置目录，也不需要往 `props_tool.tscn` 加按钮：资源按钮由 catalog 动态生成。
7. **进工具验证**：打开地图 → 选资源 → 放置 → “切换渲染”；
   - `G` 看格线，确认底边落在格心、脚不悬空；
   - 右键拖动/滚轮缩放看侧面；
   - 放在山后验证遮挡：静态资源立牌应完全消失，角色半透明；
   - 横/竖方向与占地范围在导入页和放置时都能检查。

导入页与游戏端共用 `content_rect`：`StaticAssetStore.texture_for()` 在内存里裁内容区，
不写裁切文件；自定义 sampler 不会自动应用 `AtlasTexture.region`，所以不要直接传 AtlasTexture。

## 6. 动画（现在还没接）

静态资源定义目前没有动画帧字段；示例玩家使用的 Tiny Swords 多帧源图也只取第 0 帧。

要接动画时：

- 生成/整理成**等宽帧横排**（例如每帧 192×192），脚底和阴影位置逐帧对齐；
- 给 `StaticAssetDef` 增加帧宽/帧数（或单独的动画定义），`actor_card` 按时间推进帧；
- 贴图 shader 仍然逐片元遮挡，但需要用帧 UV 或每帧一张内存裁切；
- 角色走路可以先用 4 个屏幕方向（前/后/左/右）的 idle/run，固定相机下够用；
  如果以后相机要转，才需要 8 方向或 3D。

## 7. 最小检查清单

- [ ] 底边水平、无地面砖/等距菱形
- [ ] 相机是东南 3/4、俯角约 45°，屋顶可见
- [ ] 默认左上光（渲染配置可调），阴影短且贴脚
- [ ] 1–2 px 深色描边，无抗锯齿/渐变
- [ ] 透明背景，内容区外没有脏像素
- [ ] 目标高度与内容区宽高比一致
- [ ] 脚底格 = 立牌底边，格线检查不悬空
- [ ] 遮挡测试通过（角色半透明，静态物件消失）
- [ ] 记录了模型/工具/提示词/授权，便于以后复现
