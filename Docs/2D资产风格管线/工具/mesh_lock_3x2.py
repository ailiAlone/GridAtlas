"""3×2 单间茅草屋：纹理锁回参考实现（几何锁定版流程阶段 3A）。

前置：Seedream 原图先跑 AI 抠图 remove-bg skill，输出 _nobg.png。
控制点 SP（源图）按实际画面标；TP（线稿）来自 h44 线稿的脚本坐标。
按 6 个可见面分块做逐块仿射，山墙三角用墙面补，最后乘线稿 + 色盘校正。
"""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from collections import deque

SRC = str(ROOT / "Assets/Generated/GridAtlas/redraw_3x2/raw_h44/bld_poor_cottage_single_h44_seed6102_nobg.png")
DST = str(ROOT / "Assets/Generated/GridAtlas/redraw_3x2/bld_poor_cottage_single_3x2_h44_drawn.png")
LINE = str(ROOT / "Assets/Generated/GridAtlas/redraw_3x2/bld_poor_cottage_single_3x2_h44_lineart.png")
OUT = str(ROOT / "Assets/Generated/GridAtlas/redraw_3x2/final_h44/bld_poor_cottage_single_h44_locked.png")

# ---- source: AI matte (remove-bg skill), edge cleaned ----
src = Image.open(SRC).convert("RGBA")
arr = np.array(src)
a = Image.fromarray(arr[:, :, 3]).filter(ImageFilter.MinFilter(3))
arr[:, :, 3] = np.array(a)
src = Image.fromarray(arr)

# ---- control points: source (Seedream) -> target (h44 lineart) ----
SP = {
 "L0": (170, 1448), "F0": (815, 1656), "R0": (1295, 1390),
 "L1": (232, 1370), "F1": (815, 1580), "R1": (1285, 1320),
 "L2": (232, 1005), "F2": (810, 1130), "R2": (1275, 975),
 "RF": (675, 775), "RB": (1030, 410), "GA": (600, 940),
 "Fr": (870, 1140), "Rr": (1245, 965),
}
TP = {
 "L0": (116.61, 551.35), "F0": (273.59, 662.35), "R0": (378.24, 588.35),
 "L1": (116.61, 525.45), "F1": (273.59, 636.45), "R1": (378.24, 562.45),
 "L2": (116.61, 366.35), "F2": (273.59, 477.35), "R2": (378.24, 403.35),
 "RF": (195.10, 281.25), "RB": (299.75, 207.25), "GA": (195.10, 281.25),
 "Fr": (273.59, 477.35), "Rr": (378.24, 403.35),
}
# quads / tris as keys, CCW-ish; each quad split into 2 triangles
QUADS = [
 ("foundation_left", "L0", "F0", "F1", "L1"),
 ("foundation_right", "F0", "R0", "R1", "F1"),
 ("gable_wall", "L1", "F1", "F2", "L2"),
 ("right_wall", "F1", "R1", "R2", "F2"),
 ("right_roof", "Fr", "Rr", "RB", "RF"),
]
TW, TH = 512, 768
out = Image.new("RGBA", (TW, TH), (0, 0, 0, 0))

def tri_mask(pts, size):
    m = Image.new("L", (size[0]*4, size[1]*4), 0)
    d = ImageDraw.Draw(m)
    d.polygon([(p[0]*4, p[1]*4) for p in pts], fill=255)
    m = m.resize(size, Image.LANCZOS)
    return m

def paste_tri(srcimg, s_tri, t_tri, outimg):
    # affine source -> target, invert for PIL (output -> input)
    S = np.array([[s_tri[1][0]-s_tri[0][0], s_tri[2][0]-s_tri[0][0]],
                  [s_tri[1][1]-s_tri[0][1], s_tri[2][1]-s_tri[0][1]]], float)
    T = np.array([[t_tri[1][0]-t_tri[0][0], t_tri[2][0]-t_tri[0][0]],
                  [t_tri[1][1]-t_tri[0][1], t_tri[2][1]-t_tri[0][1]]], float)
    M = T @ np.linalg.inv(S)
    off = np.array(t_tri[0]) - M @ np.array(s_tri[0])
    # output -> source: S = M^-1 (T - off)
    Mi = np.linalg.inv(M)
    # PIL coeffs map output pixel -> input pixel
    a, b = Mi[0, 0], Mi[0, 1]
    d, e = Mi[1, 0], Mi[1, 1]
    c = Mi[0, 0]*(-off[0]) + Mi[0, 1]*(-off[1])
    f = Mi[1, 0]*(-off[0]) + Mi[1, 1]*(-off[1])
    warped = srcimg.transform((TW, TH), Image.AFFINE, (a, b, c, d, e, f), Image.BICUBIC)
    mask = tri_mask(t_tri, (TW, TH))
    outimg.paste(warped, (0, 0), mask)
    return warped, mask

def tri_of_keys(keys):
    if len(keys) == 4:
        return [[keys[0], keys[1], keys[2]], [keys[0], keys[2], keys[3]]]
    return [[keys[0], keys[1], keys[2]]]

for name, *keys in QUADS:
    for tri in tri_of_keys(keys):
        s_tri = [SP[k] for k in tri]
        t_tri = [TP[k] for k in tri]
        paste_tri(src, s_tri, t_tri, out)



# ---- gable wall: lift the source's cast-shadow so it matches the drawn mud wall ----
gmask = Image.new("L", (TW, TH), 0)
gd = ImageDraw.Draw(gmask)
gd.polygon([TP["L1"], TP["F1"], TP["F2"], TP["L2"]], fill=255)
arr2 = np.array(out).astype(np.float32)
lift = np.where(np.array(gmask)[:, :, None] > 0, (arr2[:, :, :3] / 255.0) ** 0.88 * 255.0, arr2[:, :, :3])
out = Image.fromarray(np.dstack([np.clip(lift, 0, 255), arr2[:, :, 3]]).astype(np.uint8), "RGBA")

# ---- gable triangle: stretch the wall patch above the door (source has no visible triangle) ----
patch = src.crop((250, 1100, 470, 1320))
tx0, ty0, tx1, ty1 = 116.61, 281.25, 273.59, 477.35
patch = patch.resize((int(tx1-tx0), int(ty1-ty0)), Image.LANCZOS)
pa = np.array(patch).astype(np.float32)
pa[:, :, :3] = np.clip((pa[:, :, :3] / 255.0) ** 0.82 * 255.0, 0, 255)
patch = Image.fromarray(pa.astype(np.uint8), "RGBA")
mask = Image.new("L", (TW, TH), 0)
md = ImageDraw.Draw(mask)
md.polygon([TP["L2"], TP["F2"], TP["RF"]], fill=255)
tmp = Image.new("RGBA", (TW, TH), (0,0,0,0))
tmp.paste(patch, (int(tx0), int(ty0)))
out = Image.composite(tmp, out, mask)

# ---- style grade to the old village palette ----
TP_ROOF = [TP["F2"], TP["R2"], TP["RB"], TP["RF"]]
TP_WALL = [TP["L1"], TP["F1"], TP["F2"], TP["L2"]]
TP_TRI = [TP["L2"], TP["F2"], TP["RF"]]
TP_WALL_R = [TP["F1"], TP["R1"], TP["R2"], TP["F2"]]
TP_STONE = [TP["L0"], TP["F0"], TP["R0"]]
def poly_mask(pts):
    m = Image.new("L", (TW, TH), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return np.array(m) > 0
arr3 = np.array(out).astype(np.float32)
rgb3 = arr3[:, :, :3] / 255.0
# global: slight contrast + warm
rgb3 = np.clip((rgb3 - 0.5) * 1.07 + 0.5, 0, 1)
rgb3 *= np.array([1.02, 0.97, 0.90])
roofm = poly_mask(TP_ROOF)
rgb3[roofm] *= np.array([1.00, 0.88, 0.68])
rgb3[roofm] = np.clip((rgb3[roofm] - 0.5) * 1.05 + 0.5, 0, 1)
wallm = poly_mask(TP_WALL) | poly_mask(TP_TRI) | poly_mask(TP_WALL_R)
rgb3[wallm] *= np.array([1.00, 0.97, 0.88])
stonem = poly_mask(TP_STONE)
rgb3[stonem] = np.clip(rgb3[stonem] * 1.10, 0, 1)
arr3[:, :, :3] = np.clip(rgb3 * 255.0, 0, 255)
out = Image.fromarray(arr3.astype(np.uint8), "RGBA")

# ---- ridge roll: thick thatch ridge like the old village assets ----
rr = ImageDraw.Draw(out)
rfx, rfy = TP["RF"]; rbx, rby = TP["RB"]
dx, dy = rbx - rfx, rby - rfy
ln = (dx * dx + dy * dy) ** 0.5
nx, ny = dy / ln, -dx / ln
if ny < 0: nx, ny = -nx, -ny
band = [(rfx, rfy), (rbx, rby), (rbx + nx * 11, rby + ny * 11), (rfx + nx * 11, rfy + ny * 11)]
rr.polygon(band, fill=(104, 64, 38, 255))

# ---- target alpha + lineart multiply ----
tgt = Image.open(DST).convert("RGBA")
alpha = tgt.getchannel("A")
# keep a little inside bleed for the cut edge
alpha = alpha.filter(ImageFilter.MinFilter(3))
out.putalpha(alpha)

line = Image.open(LINE).convert("L")
la = np.array(line).astype(np.float32) / 255.0
la = 0.45 + 0.55 * la  # multiply, keep colors readable
rgb = np.array(out.convert("RGB")).astype(np.float32)
rgb *= la[:, :, None]
res = np.dstack([np.clip(rgb, 0, 255).astype(np.uint8), np.array(alpha)]).astype(np.uint8)
res_img = Image.fromarray(res, "RGBA")
import os
os.makedirs(os.path.dirname(OUT), exist_ok=True)
res_img.save(OUT)
# previews
prev = Image.new("RGBA", (TW, TH), (24, 28, 34, 255))
prev.alpha_composite(res_img)
prev.convert("RGB").save(OUT.replace(".png", "_preview.png"))
print("saved", OUT)
