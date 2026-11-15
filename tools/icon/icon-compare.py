"""
图标方案对比图：把几个候选并排拼成一张，并模拟 iOS 圆角后的真实观感。

用法：python icon-compare.py
输出：dist/icon-compare.png（并排对比，含圆角模拟）
"""

import importlib.util
import os

from PIL import Image, ImageDraw

SRC = r"D:\Documents\deepseek-harness\default-workspace\phone-dsh\assets\icon-source.png"
OUT_DIR = r"D:\Documents\deepseek-harness\default-workspace\phone-dsh\dist"
CANVAS = 2048

# (标签, content_ratio, badge_size, badge_radius, margin, sink)
VARIANTS = [
    ("A", 1.02, 660, 110, 0, 0),
    ("C", 1.02, 660, 110, 0, 90),
    ("D", 1.02, 660, 110, 0, 140),
]


def reuse_helpers():
    spec = importlib.util.spec_from_file_location(
        "make_icon",
        r"D:\Documents\deepseek-harness\default-workspace\phone-dsh\bridge\bin\make-icon.py",
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build(mi, content_ratio, badge_size, badge_radius, margin, sink):
    img = Image.open(SRC).convert("RGBA")
    mi.erase_watermark(img)
    mi.cut_white_corners(img)
    content = img.crop(img.getbbox())

    target = int(CANVAS * content_ratio)
    scale = target / max(content.size)
    content = content.resize(
        (max(1, int(content.size[0] * scale)), max(1, int(content.size[1] * scale))),
        Image.LANCZOS,
    )

    canvas = mi.make_background()
    bx = (CANVAS - content.size[0]) // 2
    by = CANVAS - content.size[1] + sink
    canvas.alpha_composite(content, (bx, by))

    badge = mi.make_badge(size=badge_size, radius=badge_radius)
    canvas.alpha_composite(badge, (CANVAS - badge.size[0] - margin, CANVAS - badge.size[1] - margin))
    return canvas.resize((1024, 1024), Image.LANCZOS).convert("RGB")


def ios_round(im, ratio=0.2237):
    """模拟 iOS 主屏图标的圆角裁切。"""
    size = im.size[0]
    radius = int(size * ratio)
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    out = Image.new("RGB", im.size, (246, 246, 248))
    out.paste(im, (0, 0), mask)
    return out


def main():
    mi = reuse_helpers()
    os.makedirs(OUT_DIR, exist_ok=True)

    cell = 380
    gap = 26
    top = 46
    width = gap + len(VARIANTS) * (cell + gap)
    height = top + cell + gap + 26
    sheet = Image.new("RGB", (width, height), (250, 250, 252))
    draw = ImageDraw.Draw(sheet)

    for index, (label, ratio, bsize, bradius, margin, sink) in enumerate(VARIANTS):
        icon = build(mi, ratio, bsize, bradius, margin, sink)
        icon.save(os.path.join(OUT_DIR, f"icon-try{label}.png"))
        rounded = ios_round(icon).resize((cell, cell), Image.LANCZOS)
        x = gap + index * (cell + gap)
        sheet.paste(rounded, (x, top))
        draw.text((x + 4, 18), f"{label}   sink={sink}", fill=(60, 60, 70))

    sheet.save(os.path.join(OUT_DIR, "icon-compare.png"))
    print("已生成 dist/icon-compare.png（A / C / D 并排，含 iOS 圆角模拟）")


if __name__ == "__main__":
    main()
