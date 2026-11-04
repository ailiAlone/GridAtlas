import math, os, pathlib
from PIL import Image, ImageDraw, ImageFont

S = 0.7071067811865476
OUT = str(pathlib.Path(__file__).resolve().parent.parent / "参考")

def ground(x, y):
    return ((x - y) * S, (x + y) * 0.5)

def at_height(x, y, h):
    # 立牌是竖直 billboard，屏幕高度不按 cos(pitch) 压扁：1 格高度 = 1 格屏幕。
    gx, gy = ground(x, y)
    return (gx, gy - h)

def font(size):
    for p in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\msyhbd.ttc",
              r"C:\Windows\Fonts\simhei.ttf"):
        try:
            return ImageFont.truetype(p, size)
        except Exception:
            pass
    return ImageFont.load_default()

def dashed(d, a, b, fill, width=2, dash=10.0):
    ax, ay = a; bx, by = b
    dx, dy = bx - ax, by - ay
    length = math.hypot(dx, dy)
    if length < 1.0:
        return
    ux, uy = dx / length, dy / length
    t = 0.0
    while t < length:
        t2 = min(t + dash, length)
        d.line([(ax + ux * t, ay + uy * t), (ax + ux * t2, ay + uy * t2)],
               fill=fill, width=width)
        t += dash * 2.0

def draw_ref(W, H, height, annotated):
    corners = {"back": (0, 0), "right": (W, 0), "front": (W, H), "left": (0, H)}
    base = {k: ground(*v) for k, v in corners.items()}
    up = {k: at_height(v[0], v[1], height) for k, v in corners.items()}
    pts = list(base.values()) + list(up.values())
    minx = min(p[0] for p in pts); maxx = max(p[0] for p in pts)
    miny = min(p[1] for p in pts); maxy = max(p[1] for p in pts)
    cw = 1200
    top_reserve = 150 if annotated else 30
    ch = 1250 + top_reserve
    margin = 90
    scale = min((cw - margin * 2) / (maxx - minx),
                (ch - top_reserve - margin * 2) / (maxy - miny))
    ox = (cw - (maxx - minx) * scale) * 0.5 - minx * scale
    oy = top_reserve + (ch - top_reserve - (maxy - miny) * scale) * 0.5 - miny * scale
    def P(p):
        return (p[0] * scale + ox, p[1] * scale + oy)

    img = Image.new("RGBA", (cw, ch), (16, 20, 26, 255) if annotated else (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    f = font(22); fs = font(18); ft = font(30)
    cyan = (70, 220, 255, 245); faint = (70, 220, 255, 80)
    green = (120, 255, 160, 245); amber = (255, 190, 80, 245)
    vline = (200, 220, 245, 170)

    # 占地网格
    for x in range(W + 1):
        d.line([P(ground(x, 0)), P(ground(x, H))], fill=faint, width=2)
    for y in range(H + 1):
        d.line([P(ground(0, y)), P(ground(W, y))], fill=faint, width=2)

    # 地基菱形
    base_poly = [P(base["back"]), P(base["right"]), P(base["front"]), P(base["left"])]
    d.line(base_poly + [base_poly[0]], fill=cyan, width=4)

    # 四条竖边（虚线）+ 顶部目标高度框
    for k in corners:
        dashed(d, P(base[k]), P(up[k]), vline, width=2, dash=9.0)
    top_poly = [P(up["back"]), P(up["right"]), P(up["front"]), P(up["left"])]
    d.line(top_poly + [top_poly[0]], fill=amber, width=3)

    # 前角高度刻度
    fx, fy = corners["front"]
    for i in range(1, int(math.floor(height)) + 1):
        q = at_height(fx, fy, i)
        p0 = P(q)
        p1 = P((q[0] - 0.32, q[1]))
        d.line([p0, p1], fill=amber, width=2)
        d.text((p1[0] - 34, p1[1] - 10), str(i), fill=amber, font=fs)

    # 三个锚点
    for k, label in (("left", "左"), ("front", "前"), ("right", "右")):
        px, py = P(base[k])
        d.ellipse([px - 8, py - 8, px + 8, py + 8], fill=green)
        d.text((px + 12, py - 12), label, fill=green, font=f)

    if annotated:
        left_ratio = (0.5 * W) / (S * (W + H))
        right_ratio = (0.5 * H) / (S * (W + H))
        lines = [
            (f"{W}×{H} 占地 · 45° 相机 · 左坡 {left_ratio:.3f} / 右坡 {right_ratio:.3f}", ft),
            (f"目标高度 {height:.1f} 格（立牌屏幕高度，不压扁） · 竖墙 · 无地面底座", fs),
            ("左/前/右 = 三个锚点；蓝框 = 占地；黄框 = 目标高度", fs),
        ]
        y = 26
        for text, fnt in lines:
            d.text((margin, y), text, fill=(255, 255, 255, 245), font=fnt)
            y += 44 if fnt is ft else 32

    suffix = "标注" if annotated else "参考"
    img.save(os.path.join(OUT, f"{W}x{H}-45度-{suffix}.png"))
    print(W, H, "ratio", round((0.5 * W) / (S * (W + H)), 3), "scale", round(scale, 1))

for W, H, h in ((5, 4, 5.5), (4, 3, 4.8), (3, 3, 4.5), (3, 2, 3.8), (4, 4, 4.8), (2, 3, 3.6), (2, 2, 3.1), (8, 6, 0.0), (7, 8, 0.0)):
    draw_ref(W, H, h, False)
    draw_ref(W, H, h, True)
