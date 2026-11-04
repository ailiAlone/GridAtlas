"""参数化 45° 立牌几何生成器。

输入 W×D（占地，格）和 H（地基线以上的屏幕高度，格），按 GridAtlas 的固定投影
直接生成：占地面、石基、墙、山墙、屋顶、门窗、锚点。输出 PNG + anchors.json。

投影约定（与 GridProjection 一致）：
  ground(x,y) = ((x-y)*S, (x+y)*0.5), S = 0.7071
  立牌竖直方向 1:1（不乘 cos），H 就是屏幕格高度。
"""
import json, math, random, sys, pathlib
from PIL import Image, ImageDraw, ImageFont

S = 0.7071067811865476
OUT_DIR = pathlib.Path(r"C:/Users/34935/Documents/GridAtlas/Assets/Generated/GridAtlas/geometry")
CW, CH = 512, 768
MARGIN = 26

# 立面配色（扁平风格；可后续换材质）
OUTLINE = (40, 27, 27, 255)
STONE_D = (70, 60, 58, 255); STONE = (99, 82, 85, 255); STONE_L = (135, 112, 110, 255)
MUD_D = (113, 67, 49, 255); MUD = (150, 85, 50, 255); MUD_L = (185, 103, 46, 255)
WOOD_D = (60, 32, 24, 255); WOOD = (95, 52, 34, 255); WOOD_L = (130, 80, 50, 255)
THATCH_D = (120, 64, 38, 255); THATCH = (165, 95, 50, 255); THATCH_L = (204, 131, 68, 255)
DOOR = (64, 31, 26, 255); DARK = (34, 28, 24, 255)


def ground(x, y):
    return ((x - y) * S, (x + y) * 0.5)


def build(W, D, H, wall_h=None, stone_h=0.40, overhang=0.22, seed=1):
    """返回世界屏幕坐标（footprint 中心为原点）与绘制参数。"""
    if wall_h is None:
        wall_h = max(0.9, H * 0.74)
    center = ground(W * 0.5, D * 0.5)
    L = (ground(0, D)[0] - center[0], ground(0, D)[1] - center[1])
    F = (ground(W, D)[0] - center[0], ground(W, D)[1] - center[1])
    R = (ground(W, 0)[0] - center[0], ground(W, 0)[1] - center[1])
    B = (ground(0, 0)[0] - center[0], ground(0, 0)[1] - center[1])
    rg = (ground(W * 0.5, D)[0] - center[0], ground(W * 0.5, D)[1] - center[1] - H)
    ef = (ground(W + overhang, D + overhang)[0] - center[0],
          ground(W + overhang, D + overhang)[1] - center[1] - wall_h)
    eb = (ground(W + overhang, -overhang)[0] - center[0],
          ground(W + overhang, -overhang)[1] - center[1] - wall_h)
    rf = (ground(W * 0.5, D + overhang)[0] - center[0],
          ground(W * 0.5, D + overhang)[1] - center[1] - H)
    rb = (ground(W * 0.5, -overhang)[0] - center[0],
          ground(W * 0.5, -overhang)[1] - center[1] - H)
    return dict(W=W, D=D, H=H, wall_h=wall_h, stone_h=stone_h, overhang=overhang,
                L=L, F=F, R=R, B=B, rg=rg, ef=ef, eb=eb, rf=rf, rb=rb, seed=seed)


def lift(p, h):
    return (p[0], p[1] - h)


def render(g, name):
    W, D, H = g["W"], g["D"], g["H"]
    wall_h, stone_h, ov = g["wall_h"], g["stone_h"], g["overhang"]
    L, F, R, rg = g["L"], g["F"], g["R"], g["rg"]
    ef, eb, rf, rb = g["ef"], g["eb"], g["rf"], g["rb"]
    # 所有几何点（用于取景）
    pts = [L, F, R, g["B"], rg, ef, eb, rf, rb,
           lift(L, wall_h), lift(F, wall_h), lift(R, wall_h),
           lift(L, stone_h), lift(F, stone_h), lift(R, stone_h)]
    minx = min(p[0] for p in pts); maxx = max(p[0] for p in pts)
    miny = min(p[1] for p in pts); maxy = max(p[1] for p in pts)
    scale = min((CW - MARGIN * 2) / (maxx - minx), (CH - MARGIN * 2) / (maxy - miny))
    ox = (CW - (maxx - minx) * scale) * 0.5 - minx * scale
    oy = (CH - (maxy - miny) * scale) * 0.5 - miny * scale

    def P(p):
        return (p[0] * scale + ox, p[1] * scale + oy)

    img = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rng = random.Random(g["seed"])

    def poly(points, fill, width=2):
        pp = [P(p) for p in points]
        if fill is not None:
            d.polygon(pp, fill=fill)
        d.line(pp + [pp[0]], fill=OUTLINE, width=width)

    def line(a, b, fill, width=2):
        d.line([P(a), P(b)], fill=fill, width=width)

    # 石基（两个可见面）
    Ls, Fs, Rs = lift(L, stone_h), lift(F, stone_h), lift(R, stone_h)
    poly([L, F, Fs, Ls], STONE)
    poly([F, R, Rs, Fs], STONE)
    # 石块缝
    for i in range(1, max(2, int(W * 2))):
        u = i / max(2, int(W * 2))
        line((L[0] + (F[0] - L[0]) * u, L[1] + (F[1] - L[1]) * u),
             (Ls[0] + (Fs[0] - Ls[0]) * u, Ls[1] + (Fs[1] - Ls[1]) * u),
             STONE_D, 1)
    for i in range(1, max(2, int(D * 2))):
        u = i / max(2, int(D * 2))
        line((F[0] + (R[0] - F[0]) * u, F[1] + (R[1] - F[1]) * u),
             (Fs[0] + (Rs[0] - Fs[0]) * u, Fs[1] + (Rs[1] - Fs[1]) * u),
             STONE_D, 1)

    def face_pt(p00, p10, p01, u, v):
        return (p00[0] + (p10[0] - p00[0]) * u + (p01[0] - p00[0]) * v,
                p00[1] + (p10[1] - p00[1]) * u + (p01[1] - p00[1]) * v)

    def face_poly(p00, p10, p01, r):
        u0, u1, v0, v1 = r
        return [face_pt(p00, p10, p01, u0, v0), face_pt(p00, p10, p01, u1, v0),
                face_pt(p00, p10, p01, u1, v1), face_pt(p00, p10, p01, u0, v1)]

    def face_line(p00, p10, p01, u0, v0, u1, v1, fill, width):
        d.line([P(face_pt(p00, p10, p01, u0, v0)), P(face_pt(p00, p10, p01, u1, v1))],
               fill=fill, width=width)

    # 屋顶（出挑后的右坡）
    roof = [ef, eb, rb, rf]
    poly(roof, THATCH)
    rows = max(5, int(H * 2.2))
    for i in range(rows + 1):
        v = i / rows
        a = face_pt(ef, eb, rf, 0.0, v)
        b = face_pt(ef, eb, rf, 1.0, v)
        d.line([P(a), P(b)], fill=THATCH_D, width=2)
    for i in range(1, 12):
        u = i / 12.0
        a = face_pt(ef, eb, rf, u, 0.02)
        b = face_pt(ef, eb, rf, u, 0.96)
        d.line([P(a), P(b)], fill=THATCH_D, width=1)
    # 墙（石基顶 -> 墙顶）
    Lw, Fw, Rw = lift(Ls, wall_h - stone_h), lift(Fs, wall_h - stone_h), lift(Rs, wall_h - stone_h)
    poly([Ls, Fs, Fw, Lw], MUD)
    poly([Fs, Rs, Rw, Fw], MUD)
    # 墙顶受光/背光
    line([Ls, Fs][0], [Ls, Fs][1], MUD_D, 1)

    # 前山墙木构
    for u in (0.04, 0.34, 0.66, 0.96):
        face_line(Ls, Fs, Lw, u, 0.02, u, 0.98, WOOD_D, 3)
    for v in (0.45, 0.96):
        face_line(Ls, Fs, Lw, 0.02, v, 0.98, v, WOOD, 2)
    face_line(Ls, Fs, Lw, 0.06, 0.08, 0.30, 0.42, WOOD, 2)
    face_line(Ls, Fs, Lw, 0.94, 0.08, 0.70, 0.42, WOOD, 2)
    # 右侧长墙木构
    for u in (0.04, 0.34, 0.66, 0.96):
        face_line(Fs, Rs, Fw, u, 0.02, u, 0.98, WOOD_D, 3)
    for v in (0.45, 0.96):
        face_line(Fs, Rs, Fw, 0.02, v, 0.98, v, WOOD, 2)
    face_line(Fs, Rs, Fw, 0.06, 0.08, 0.30, 0.42, WOOD, 2)
    face_line(Fs, Rs, Fw, 0.94, 0.08, 0.70, 0.42, WOOD, 2)

    # 门（前山墙）
    du0, du1 = 0.36, 0.62
    poly(face_poly(Ls, Fs, Lw, (du0, du1, 0.04, 0.56)), DOOR)
    for i in range(1, 3):
        face_line(Ls, Fs, Lw, du0 + (du1 - du0) * i / 3.0, 0.06,
                  du0 + (du1 - du0) * i / 3.0, 0.54, (92, 56, 36, 255), 2)
    # 窗（右墙）
    poly(face_poly(Fs, Rs, Fw, (0.42, 0.58, 0.50, 0.72)), DARK)
    face_line(Fs, Rs, Fw, 0.50, 0.50, 0.50, 0.72, WOOD, 2)
    face_line(Fs, Rs, Fw, 0.42, 0.61, 0.58, 0.61, WOOD, 2)

    # 山墙三角
    poly([Lw, Fw, rg], MUD)
    face_line(Lw, Fw, rg, 0.02, 0.02, 0.50, 0.96, WOOD, 3)
    face_line(Lw, Fw, rg, 0.98, 0.02, 0.50, 0.96, WOOD, 3)
    face_line(Lw, Fw, rg, 0.02, 0.0, 0.98, 0.0, WOOD_D, 3)
    face_line(Lw, Fw, rg, 0.50, 0.0, 0.50, 0.95, WOOD_D, 3)
    # 通风口
    poly([face_pt(Lw, Fw, rg, 0.45, 0.30), face_pt(Lw, Fw, rg, 0.55, 0.30),
          face_pt(Lw, Fw, rg, 0.55, 0.42), face_pt(Lw, Fw, rg, 0.45, 0.42)], DARK, 1)

    # 出挑底部（檐下阴影），让屋顶和山墙的前后关系读得出来
    front_soffit = [rg, Fw, ef, rf]
    d.polygon([P(p) for p in front_soffit], fill=(52, 34, 26, 255))
    d.line([P(p) for p in front_soffit] + [P(front_soffit[0])], fill=OUTLINE, width=2)
    eave_soffit = [Fw, Rw, eb, ef]
    d.polygon([P(p) for p in eave_soffit], fill=(58, 38, 30, 255))
    d.line([P(p) for p in eave_soffit] + [P(eave_soffit[0])], fill=OUTLINE, width=2)
    # 博风板/檐口板
    line(rf, ef, (95, 52, 34, 255), 7)
    line(rf, ef, OUTLINE, 2)
    line(ef, eb, (95, 52, 34, 255), 6)
    line(ef, eb, OUTLINE, 2)
    # 屋脊
    line(rf, rb, (190, 160, 92, 255), 5)
    line(rf, rb, OUTLINE, 2)
    # 山墙檐口阴影
    line(Lw, Fw, OUTLINE, 3)
    line(Fw, Rw, OUTLINE, 3)

    # 基础落地线
    d.line([P(L), P(F), P(R)], fill=OUTLINE, width=3)

    out = OUT_DIR / f"{name}_drawn.png"
    img.save(out)
    # 线稿
    bg = Image.new("RGBA", img.size, (255, 255, 255, 255))
    bg.alpha_composite(img)
    gimg = bg.convert("L")
    line_img = gimg.point(lambda p: 0 if p < 110 else 255)
    line_img.convert("RGB").save(OUT_DIR / f"{name}_lineart.png")

    anchors = dict(left=P(L), front=P(F), right=P(R),
                   ridge=P(rg), eave_front=P(ef), eave_back=P(eb),
                   ridge_front=P(rf), ridge_back=P(rb), scale=scale)
    (OUT_DIR / f"{name}_anchors.json").write_text(
        json.dumps(anchors, ensure_ascii=False, 
        indent=1), encoding="utf-8")
    # 尺寸自检
    base_w = math.dist(P(L), P(R))
    base_line_y = (P(L)[1] + P(F)[1]) * 0.5
    front_h = base_line_y - P(rg)[1]
    print(name, "W,D,H=", W, D, H, "scale", round(scale, 2),
          "base_w_px", round(base_w, 1), "ridge_above_baseline_px", round(front_h, 1),
          "expected H*scale", round(H * scale, 1))
    return img, anchors


if __name__ == "__main__":
    specs = [
        ("bld_3x2_h44", 3, 2, 4.4),
        ("bld_3x3_h50", 3, 3, 5.0),
        ("bld_5x4_h64", 5, 4, 6.4),
        ("bld_2x2_h36", 2, 2, 3.6),
    ]
    for name, W, D, H in specs:
        render(build(W, D, H, seed=sum(map(ord, name))), name)
