#!/usr/bin/env python3
"""把「图标预览图」（圆角方块 + 浅色背景的 mockup）转换成 macOS 标准 App 图标主图。

产出规格：1024x1024、**完全不透明**（满出血）的 PNG。
macOS 会自己把 App 图标裁成标准形状（实测：824x824 的连续曲率圆角方块 + 系统投影），
所以主图只需要保证「标准形状范围内的像素都是图标本体」即可。

注意：带透明通道的 icns 在当前 macOS 上会被系统额外套一层浅灰底板并把图标缩小
（本项目旧图标也有同样问题），因此这里刻意输出满出血不透明图。

用法:
    python3 scripts/make-icon.py <mockup.png> <out-1024.png>
"""
import sys
import numpy as np
from PIL import Image

# ---- macOS 图标规范（由系统 App 图标实测得出）----
CANVAS = 1024          # 画布边长
CONTENT = 824          # 系统实际使用的图标形状边长
SQUIRCLE_N = 4.27      # 连续曲率圆角（squircle）指数，拟合自系统图标形状
SAFETY_ZOOM = 850      # 素材放大到 850 再居中，保证形状边缘不会露出原图背景
CROP_INSET = 16        # 从方块边缘内缩的像素数，避开原图的羽化边与 JPEG 噪点
SAT_BODY = 0.18        # 判定「图标本体」的饱和度阈值（背景与投影都是低饱和灰）
SAT_EDGE = 0.06        # 判定「非背景」的宽松阈值，用于边缘自检
EDGE_RING = 20         # 自检的环形宽度（px）：标准形状外圈必须全是图标本体


def saturation(img: Image.Image) -> np.ndarray:
    rgb = np.asarray(img.convert("RGB")).astype(np.float32)
    mx, mn = rgb.max(axis=-1), rgb.min(axis=-1)
    return (mx - mn) / (mx + 1e-6)


def find_icon_square(img: Image.Image):
    """用饱和度定位预览图里的图标方块，返回 (cx, cy, side)。"""
    ys, xs = np.where(saturation(img) > SAT_BODY)
    if len(xs) == 0:
        raise SystemExit("没有在预览图里找到图标区域")
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    cx, cy = (x0 + x1 + 1) / 2.0, (y0 + y1 + 1) / 2.0
    side = min(x1 - x0 + 1, y1 - y0 + 1) - 2 * CROP_INSET
    print(f"  定位图标方块: x {x0}..{x1} y {y0}..{y1} "
          f"({x1 - x0 + 1}x{y1 - y0 + 1}) 中心 ({cx:.1f}, {cy:.1f})")
    return cx, cy, side


def squircle_alpha(content: int = CONTENT, size: int = CANVAS, n: float = SQUIRCLE_N):
    """系统标准图标形状的 alpha 遮罩（解析法抗锯齿）。"""
    half = content / 2.0
    center = size / 2.0
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    x = np.abs(xx + 0.5 - center) / half
    y = np.abs(yy + 0.5 - center) / half
    r = (x ** n + y ** n) ** (1.0 / n)
    # (1-r)*half ≈ 到形状边界的像素距离，用 1px 宽度做羽化
    return np.clip((1.0 - r) * half + 0.5, 0.0, 1.0)


def extend_edges(rgb: np.ndarray, known: np.ndarray) -> np.ndarray:
    """把 known 区域的像素颜色向 unknown 区域逐层扩散，直到铺满整张画布。

    这样形状之外的角落会延续渐变，而不是残留预览图的灰底。
    """
    out = rgb.copy()
    filled = known.copy()
    for _ in range(max(out.shape[:2])):
        if filled.all():
            break
        p = np.pad(out, ((1, 1), (1, 1), (0, 0)), mode="edge")
        pk = np.pad(filled, 1, mode="edge")
        neigh = np.stack([p[0:-2, 1:-1], p[2:, 1:-1], p[1:-1, 0:-2], p[1:-1, 2:]], 0)
        nk = np.stack([pk[0:-2, 1:-1], pk[2:, 1:-1], pk[1:-1, 0:-2], pk[1:-1, 2:]], 0)
        fresh = (~filled) & nk.any(0)
        if not fresh.any():
            break
        pick = nk.argmax(0)
        out[fresh] = np.take_along_axis(neigh, pick[None, ..., None], 0)[0][fresh]
        filled |= fresh
    return out


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    src_path, out_path = sys.argv[1], sys.argv[2]

    src = Image.open(src_path).convert("RGB")
    print(f"▶ 读取预览图: {src_path} ({src.width}x{src.height})")
    cx, cy, side = find_icon_square(src)

    # 裁出图标方块（内缩若干像素，避开原图背景的羽化边）
    x0, y0 = round(cx - side / 2), round(cy - side / 2)
    box = (x0, y0, x0 + side, y0 + side)
    art = src.crop(box).resize((SAFETY_ZOOM, SAFETY_ZOOM), Image.LANCZOS)
    print(f"  裁切 {box} → {side}x{side} → 放大到 {SAFETY_ZOOM}x{SAFETY_ZOOM}")

    # 居中贴到 1024 画布（略微溢出，确保形状范围内没有原图背景）
    off = (CANVAS - SAFETY_ZOOM) // 2
    canvas = np.zeros((CANVAS, CANVAS, 3), dtype=np.float32)
    canvas[off:off + SAFETY_ZOOM, off:off + SAFETY_ZOOM] = np.asarray(art).astype(np.float32)

    shape = squircle_alpha()
    inside = shape > 0.5

    # ---- 自检：标准形状外圈必须全是图标本体，不能是预览图的背景 ----
    sat_canvas = np.zeros((CANVAS, CANVAS), dtype=np.float32)
    sat_canvas[off:off + SAFETY_ZOOM, off:off + SAFETY_ZOOM] = np.asarray(
        Image.fromarray((saturation(src) * 255).astype(np.uint8), "L")
        .crop(box).resize((SAFETY_ZOOM, SAFETY_ZOOM), Image.LANCZOS)
    ).astype(np.float32) / 255.0
    ring = inside & (squircle_alpha(CONTENT - 2 * EDGE_RING) < 0.5)
    bad = int((ring & (sat_canvas < SAT_EDGE)).sum())
    print(f"  形状外圈 {EDGE_RING}px 里的背景像素: {bad}",
          "✓" if bad == 0 else "⚠️ 请调大 SAFETY_ZOOM")
    assert bad == 0, "标准形状边缘会露出预览图背景"

    # ---- 用图标本体的颜色向外扩散，铺满整张画布（满出血、不透明）----
    rgb = extend_edges(canvas, inside)
    out = np.concatenate([rgb, np.full((CANVAS, CANVAS, 1), 255.0, np.float32)], -1)
    img = Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8), "RGBA")
    img.save(out_path)

    a = np.asarray(img)
    print(f"  输出: {img.width}x{img.height} 不透明")
    print(f"  取样 左上角(5,5)={a[5,5][:3].tolist()} 角内(200,200)={a[200,200][:3].tolist()} "
          f"右下(900,900)={a[900,900][:3].tolist()}")
    print(f"✓ 已生成 {out_path}")


if __name__ == "__main__":
    main()
