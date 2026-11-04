"""参数化 45° 立牌几何生成器 v2：按旧茅草屋的构造重画。

输入 W×D（占地，格）和 H（地基线以上的屏幕高度，格），按 GridAtlas 的固定投影
生成：占地面、石基、墙、山墙、屋面、出檐、门窗、锚点。

构造参考旧茅草屋：
  - 低墙 + 大屋顶：墙顶约在地基以上 0.42H，屋顶占其余；
  - 屋顶面与山墙共用山墙斜边（博风板），出檐是屋面外侧的窄条，不覆盖山墙；
  - 屋面只画可见的右坡；山墙三角完整可见；
  - 石基有台沿，门/窗按墙高比例。
"""
import json, math, random, pathlib
from PIL import Image, ImageDraw

S = 0.7071067811865476
OUT_DIR = pathlib.Path(r"C:/Users/34935/Documents/GridAtlas/Assets/Generated/GridAtlas/geometry_v2")
CW, CH = 512, 768
MARGIN = 26

OUTLINE = (40, 27, 27, 255)
STONE_D = (70, 60, 58, 255); STONE = (99, 82, 85, 255); STONE_L = (135, 112, 110, 255)
MUD_D = (113, 67, 49, 255); MUD = (150, 85, 50, 255); MUD_L = (185, 103, 46, 255)
WOOD_D = (60, 32, 24, 255); WOOD = (95, 52, 34, 255); WOOD_L = (130, 80, 50, 255)
THATCH_D = (120, 64, 38, 255); THATCH = (165, 95, 50, 255); THATCH_L = (204, 131, 68, 255)
DOOR = (64, 31, 26, 255); DARK = (34, 28, 24, 255)
SOFFIT = (52, 34, 26, 255)


def ground(x, y):
    return ((x - y) * S, (x + y) * 0.5)


def build(W, D, H, wall_top=None, stone_h=0.40, overhang=0.35, seed=1):
    if wall_top is None:
        wall_top = stone_h + (H - stone_h) * 0.42
    c = ground(W * 0.5, D * 0.5)

    def G(x, y, h=0.0):
        gx, gy = ground(x, y)
        return (gx - c[0], gy - c[1] - h)

    L, F, R, B = G(0, D), G(W, D), G(W, 0), G(0, 0)
    rg, rb = G(W * 0.5, D, H), G(W * 0.5, 0, H)
    Lw, Fw, Rw = G(0, D, wall_top), G(W, D, wall_top), G(W, 0, wall_top)
    # 出檐点（屋面外侧窄条）
    Fwo = G(W + overhang, D + overhang, wall_top)
    Rwo = G(W + overhang, -overhang, wall_top)
    rgo = G(W * 0.5, D + overhang, H)
    rbo = G(W * 0.5, -overhang, H)
    return dict(W=W, D=D, H=H, wall_top=wall_top, stone_h=stone_h, overhang=overhang,
                L=L, F=F, R=R, B=B, Lw=Lw, Fw=Fw, Rw=Rw, rg=rg, rb=rb,
                Fwo=Fwo, Rwo=Rwo, rgo=rgo, rbo=rbo, seed=seed)


def lift(p, h):
    return (p[0], p[1] - h)


def render(g, name):
    W, D, H = g["W"], g["D"], g["H"]
    stone_h, wt, ov = g["stone_h"], g["wall_top"], g["overhang"]
    L, F, R = g["L"], g["F"], g["R"]
    Lw, Fw, Rw, rg, rb = g["Lw"], g["Fw"], g["Rw"], g["rg"], g["rb"]
    Fwo, Rwo, rgo, rbo = g["Fwo"], g["Rwo"], g["rgo"], g["rbo"]

    pts = [L, F, R, g["B"], Lw, Fw, Rw, rg, rb, Fwo, Rwo, rgo, rbo,
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

    # ---------- 石基（带台沿） ----------
    Ls, Fs, Rs = lift(L, stone_h), lift(F, stone_h), lift(R, stone_h)
    poly([L, F, Fs, Ls], STONE)
    poly([F, R, Rs, Fs], STONE)
    line(Ls, Fs, STONE_L, 3)
    line(Fs, Rs, STONE_L, 3)
    for i in range(1, max(2, int(W * 2))):
        u = i / max(2, int(W * 2))
        line((L[0] + (F[0] - L[0]) * u, L[1] + (F[1] - L[1]) * u),
             (Ls[0] + (Fs[0] - Ls[0]) * u, Ls[1] + (Fs[1] - Ls[1]) * u), STONE_D, 1)
    for i in range(1, max(2, int(D * 2))):
        u = i / max(2, int(D * 2))
        line((F[0] + (R[0] - F[0]) * u, F[1] + (R[1] - F[1]) * u),
             (Fs[0] + (Rs[0] - Fs[0]) * u, Fs[1] + (Rs[1] - Fs[1]) * u), STONE_D, 1)

    # ---------- 山墙（左面）与右墙 ----------
    poly([Ls, Fs, Fw, Lw], MUD)
    poly([Fs, Rs, Rw, Fw], MUD)
    # 山墙木构：角柱、檐口横梁、中柱、斜撑
    for u in (0.03, 0.97):
        face_line(Ls, Fs, Lw, u, 0.02, u, 0.98, WOOD_D, 4)
    face_line(Ls, Fs, Lw, 0.03, 0.93, 0.97, 0.93, WOOD, 3)
    face_line(Ls, Fs, Lw, 0.50, 0.02, 0.50, 0.98, WOOD_D, 3)
    face_line(Ls, Fs, Lw, 0.03, 0.55, 0.97, 0.55, WOOD, 2)
    face_line(Ls, Fs, Lw, 0.08, 0.10, 0.28, 0.55, WOOD, 2)
    face_line(Ls, Fs, Lw, 0.92, 0.10, 0.72, 0.55, WOOD, 2)
    # 右墙木构
    for u in (0.03, 0.97):
        face_line(Fs, Rs, Fw, u, 0.02, u, 0.98, WOOD_D, 4)
    face_line(Fs, Rs, Fw, 0.03, 0.93, 0.97, 0.93, WOOD, 3)
    face_line(Fs, Rs, Fw, 0.03, 0.55, 0.97, 0.55, WOOD, 2)
    face_line(Fs, Rs, Fw, 0.08, 0.10, 0.28, 0.55, WOOD, 2)
    face_line(Fs, Rs, Fw, 0.92, 0.10, 0.72, 0.55, WOOD, 2)

    # 门（山墙中偏左，带门框/门楣/门槛）
    du0, du1, dv0, dv1 = 0.38, 0.62, 0.02, 0.78
    poly(face_poly(Ls, Fs, Lw, (du0, du1, dv0, dv1)), DOOR)
    for i in range(1, 3):
        u = du0 + (du1 - du0) * i / 3.0
        face_line(Ls, Fs, Lw, u, dv0 + 0.02, u, dv1 - 0.02, (92, 56, 36, 255), 2)
    poly(face_poly(Ls, Fs, Lw, (du0 - 0.03, du1 + 0.03, dv1, dv1 + 0.05)), WOOD, 2)
    poly(face_poly(Ls, Fs, Lw, (du0 - 0.03, du1 + 0.03, -0.02, 0.02)), STONE_L, 2)

    # 门头小雨棚（旧屋结构）
    p1 = face_pt(Ls, Fs, Lw, du0 - 0.06, dv1)
    p2 = face_pt(Ls, Fs, Lw, du1 + 0.06, dv1)
    p3 = (p2[0] - 0.55, p2[1] - 0.10)
    p4 = (p1[0] - 0.55, p1[1] - 0.10)
    d.polygon([P(p1), P(p2), P(p3), P(p4)], fill=THATCH)
    d.line([P(p1), P(p2), P(p3), P(p4), P(p1)], fill=OUTLINE, width=2)
    d.line([P(p1), P(p4), P(p3)], fill=(58, 38, 30, 255), width=4)

    # 窗（右墙，带窗框）
    wu0, wu1, wv0, wv1 = 0.44, 0.62, 0.50, 0.78
    poly(face_poly(Fs, Rs, Fw, (wu0 - 0.03, wu1 + 0.03, wv0 - 0.03, wv1 + 0.03)), WOOD, 2)
    poly(face_poly(Fs, Rs, Fw, (wu0, wu1, wv0, wv1)), DARK, 2)
    face_line(Fs, Rs, Fw, (wu0 + wu1) * 0.5, wv0, (wu0 + wu1) * 0.5, wv1, WOOD, 2)
    face_line(Fs, Rs, Fw, wu0, (wv0 + wv1) * 0.5, wu1, (wv0 + wv1) * 0.5, WOOD, 2)

    # ---------- 山墙三角 ----------
    poly([Lw, Fw, rg], MUD)
    face_line(Lw, Fw, rg, 0.03, 0.02, 0.50, 0.97, WOOD, 3)
    face_line(Lw, Fw, rg, 0.97, 0.02, 0.50, 0.97, WOOD, 3)
    face_line(Lw, Fw, rg, 0.50, 0.02, 0.50, 0.97, WOOD_D, 3)
    face_line(Lw, Fw, rg, 0.12, 0.30, 0.88, 0.30, WOOD, 2)
    poly([face_pt(Lw, Fw, rg, 0.46, 0.36), face_pt(Lw, Fw, rg, 0.54, 0.36),
          face_pt(Lw, Fw, rg, 0.54, 0.48), face_pt(Lw, Fw, rg, 0.46, 0.48)], DARK, 1)

    # ---------- 屋面（右坡，与山墙共用斜边） ----------
    roof = [Fw, Rw, rb, rg]
    poly(roof, THATCH)
    rows = max(6, int((H - wt) * 4.0))
    for i in range(rows + 1):
        v = i / rows
        col = THATCH_D
        if v < 0.12:
            col = THATCH_L
        elif v > 0.88:
            col = (96, 52, 30, 255)
        a = face_pt(Fw, Rw, rg, 0.0, v)
        b = face_pt(Fw, Rw, rg, 1.0, v)
        d.line([P(a), P(b)], fill=col, width=3)
    for i in range(1, 14):
        u = i / 14.0
        a = face_pt(Fw, Rw, rg, u, 0.02)
        b = face_pt(Fw, Rw, rg, u, 0.96)
        d.line([P(a), P(b)], fill=THATCH_D, width=1)

    # 茅草檐口/博风挂边（锯齿 + 草茎），不覆盖山墙
    def fringe(a, b, depth=0.11, teeth=10):
        pts = [a, b]
        for i in range(teeth, -1, -1):
            t = i / teeth
            x = a[0] + (b[0] - a[0]) * t
            y = a[1] + (b[1] - a[1]) * t
            y += depth * (1.0 if i % 2 else 1.45)
            pts.append((x, y))
        d.polygon([P(p) for p in pts], fill=THATCH_D)
        d.line([P(p) for p in pts] + [P(pts[0])], fill=OUTLINE, width=2)
        for i in range(teeth):
            t = (i + 0.5) / teeth
            x = a[0] + (b[0] - a[0]) * t
            y = a[1] + (b[1] - a[1]) * t
            d.line([P((x, y)), P((x, y + depth * 1.2))],
                   fill=THATCH_L if i % 2 else THATCH, width=1)
    fringe(Fw, Rw, 0.10, max(6, int(D * 5)))
    fringe(rg, Fw, 0.10, max(6, int(W * 5)))

    # 博风板（山墙斜边）与檐口板
    line(rg, Fw, WOOD_D, 8)
    line(rg, Fw, OUTLINE, 2)
    line(Fw, Rw, WOOD_D, 7)
    line(Fw, Rw, OUTLINE, 2)
    # 屋脊
    line(rg, rb, THATCH_L, 10)
    line(rg, rb, OUTLINE, 3)

    # ---------- 基础落地线 ----------
    d.line([P(L), P(F), P(R)], fill=OUTLINE, width=3)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out = OUT_DIR / f"{name}_drawn.png"
    img.save(out)
    bg = Image.new("RGBA", img.size, (255, 255, 255, 255))
    bg.alpha_composite(img)
    gimg = bg.convert("L")
    gimg.point(lambda p: 0 if p < 110 else 255).convert("RGB").save(OUT_DIR / f"{name}_lineart.png")

    anchors = dict(left=P(L), front=P(F), right=P(R), ridge=P(rg),
                   eave_front=P(Fw), eave_back=P(Rw), ridge_front=P(rgo),
                   ridge_back=P(rbo), scale=scale)
    (OUT_DIR / f"{name}_anchors.json").write_text(
        json.dumps(anchors, ensure_ascii=False, indent=1), encoding="utf-8")
    base_line = (P(L)[1] + P(F)[1]) * 0.5
    hpx = base_line - P(rg)[1]
    print(name, "W,D,H=", W, D, H, "wall_top", round(wt, 2), "scale", round(scale, 2),
          "h_px", round(hpx, 1), "expected", round(H * scale, 1),
          "OK" if abs(hpx - H * scale) < 0.01 else "FAIL")
    return img, anchors


if __name__ == "__main__":
    for name, W, D, H in [("v2_3x2", 3, 2, 3.8), ("v2_3x3", 3, 3, 4.5),
                          ("v2_5x4", 5, 4, 5.5), ("v2_2x2", 2, 2, 3.1)]:
        render(build(W, D, H, seed=sum(map(ord, name))), name)
