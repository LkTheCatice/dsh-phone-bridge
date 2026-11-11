"""
把绿幕原图做成 iOS App 图标。

思路：
  1. 按 HSV 色相判定绿色背景 → alpha 0
  2. 边缘做软过渡 + 去溢色（绿边会把角色镶一圈绿）
  3. 裁剪到角色外接框，等比缩放到 1024 画布的 ~80%
  4. 合成到浅蓝径向渐变底（iOS 图标不能带透明通道）
"""

import colorsys
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

SRC = r"C:\Users\acer\.dsh\attachments\v1\objects\88\88b9a2670c941a3dd999ca99f1fe3f4fc2db561b5fb6cf0f31196983c1ab0980"
OUT_DIR = r"D:\Documents\deepseek-harness\default-workspace\phone-dsh\ios\DSHRemote\Sources\Assets.xcassets\AppIcon.appiconset"
OUT = os.path.join(OUT_DIR, "icon-1024.png")
PREVIEW = r"D:\Documents\deepseek-harness\default-workspace\phone-dsh\dist\icon-preview.png"


BG = (180, 234, 120)  # 实测背景色 rgb(180,234,120) / 色相 88° / 饱和度 0.49


def greenness(r, g, b):
    """返回 0..1 的"这像素有多像绿幕"。

    单看色相+饱和度不够：背景饱和度只有 0.49，会被判成"不够绿"。
    所以用两条判据叠加：
      1. 绿色必须明显高于红和蓝（排除白色、浅蓝等角色用色）
      2. 与实测背景色的距离（越近越确定是幕布，用于边缘软过渡）
    """
    if g < 90:
        return 0.0
    if g <= r * 1.12 or g <= b * 1.30:
        return 0.0
    dist = ((r - BG[0]) ** 2 + (g - BG[1]) ** 2 + (b - BG[2]) ** 2) ** 0.5
    if dist <= 60:
        return 1.0
    if dist >= 180:
        return 0.0
    return 1.0 - (dist - 60) / 120.0


def main():
    src = Image.open(SRC).convert("RGBA")
    w, h = src.size
    print(f"原图: {w}x{h}")

    px = src.load()
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    opx = out.load()

    kept = 0
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            gscore = greenness(r, g, b)
            if gscore >= 0.85:
                continue  # 纯背景
            alpha = int(255 * (1.0 - gscore))
            # 原图手机屏幕的发光会在角色周围留一圈半透明白雾，浅底上很脏。
            # 只压"半透明 + 接近纯白"的像素，不会伤到 alpha 实心的白裙边。
            if alpha < 210 and r > 222 and g > 222 and b > 222:
                alpha = int(alpha * 0.2)
            # 去溢色：保留像素里把绿色压到 R/B 的平均水平，去掉绿边
            if g > (r + b) / 2:
                g = int((r + b) / 2)
            opx[x, y] = (r, g, b, alpha)
            if alpha > 16:
                kept += 1

    print(f"保留像素: {kept} ({kept / (w * h) * 100:.1f}%)")

    # 收紧 alpha 边缘一点点，去掉残留光晕
    alpha = out.split()[3].filter(ImageFilter.MinFilter(3))
    out.putalpha(alpha)

    bbox = out.getbbox()
    if not bbox:
        print("抠图后什么都没剩下，检查阈值")
        sys.exit(1)
    out = out.crop(bbox)
    cw, ch = out.size
    print(f"角色外接框: {cw}x{ch}")

    # 1024 画布 + 浅蓝径向渐变底
    canvas_size = 1024
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 255))
    grad = Image.new("RGBA", (canvas_size, canvas_size))
    gd = grad.load()
    cx = cy = canvas_size / 2
    maxd = (canvas_size / 2) * 1.414
    inner = (238, 247, 255)
    outer = (150, 197, 240)
    for yy in range(canvas_size):
        for xx in range(canvas_size):
            d = min(1.0, (((xx - cx) ** 2 + (yy - cy) ** 2) ** 0.5) / maxd)
            gd[xx, yy] = (
                int(inner[0] + (outer[0] - inner[0]) * d),
                int(inner[1] + (outer[1] - inner[1]) * d),
                int(inner[2] + (outer[2] - inner[2]) * d),
                255,
            )
    canvas = grad

    # 角色占画布高度 80%，水平居中略偏上（底部留呼吸位）
    target_h = int(canvas_size * 0.80)
    scale = target_h / ch
    target_w = int(cw * scale)
    resized = out.resize((target_w, target_h), Image.LANCZOS)

    x = (canvas_size - target_w) // 2
    y = int(canvas_size * 0.52 - target_h / 2)
    y = max(24, min(y, canvas_size - target_h - 24))

    # 先垫一层柔和投影，角色才不像贴纸浮在底色上
    shadow_alpha = resized.split()[3].filter(ImageFilter.GaussianBlur(9))
    shadow = Image.new("RGBA", resized.size, (38, 66, 110, 0))
    shadow.putalpha(shadow_alpha.point(lambda v: int(v * 0.45)))
    canvas.alpha_composite(shadow, (x + 10, y + 14))
    canvas.alpha_composite(resized, (x, y))

    # iOS 图标不允许 alpha 通道
    final = canvas.convert("RGB")
    os.makedirs(OUT_DIR, exist_ok=True)
    final.save(OUT, "PNG")
    os.makedirs(os.path.dirname(PREVIEW), exist_ok=True)
    final.resize((256, 256), Image.LANCZOS).save(PREVIEW, "PNG")
    print(f"已输出: {OUT}")
    print(f"预览: {PREVIEW}")


if __name__ == "__main__":
    main()
