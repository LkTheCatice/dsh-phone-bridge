"""
图标效果试验：不改 icon-1024.png，只生成对比预览图，供确认后再落地。

试验内容：
  A. 角标贴死右下角（白方块外边与画布右边/下边对齐）
  B. 人物垂直底部对齐（脚贴底，头顶自然留白）
"""

import os

from PIL import Image

SRC = r"D:\Documents\deepseek-harness\default-workspace\phone-dsh\assets\icon-source.png"
OUT_DIR = r"D:\Documents\deepseek-harness\default-workspace\phone-dsh\dist"

CANVAS = 2048


def reuse_helpers():
    """复用 make-icon.py 里的处理函数，避免两套逻辑漂移。"""
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "make_icon",
        r"D:\Documents\deepseek-harness\default-workspace\phone-dsh\bridge\bin\make-icon.py",
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build(mi, content_ratio, badge_size, badge_radius, margin, sink=0):
    img = Image.open(SRC).convert("RGBA")
    mi.erase_watermark(img)
    mi.cut_white_corners(img)
    bbox = img.getbbox()
    content = img.crop(bbox)

    target = int(CANVAS * content_ratio)
    scale = target / max(content.size)
    content = content.resize(
        (max(1, int(content.size[0] * scale)), max(1, int(content.size[1] * scale))),
        Image.LANCZOS,
    )

    canvas = mi.make_background()
    bx = (CANVAS - content.size[0]) // 2
    # 底部对齐后再按 sink 继续往下压（脚会裁掉 sink 像素，头顶留白变多）
    by = CANVAS - content.size[1] + sink
    canvas.alpha_composite(content, (bx, by))

    badge = mi.make_badge(size=badge_size, radius=badge_radius)
    canvas.alpha_composite(badge, (CANVAS - badge.size[0] - margin, CANVAS - badge.size[1] - margin))
    return canvas.resize((1024, 1024), Image.LANCZOS).convert("RGB")


def main():
    mi = reuse_helpers()
    os.makedirs(OUT_DIR, exist_ok=True)

    # A：角标贴边（margin=0），人物脚贴底
    a = build(mi, content_ratio=1.02, badge_size=660, badge_radius=110, margin=0)
    a.save(os.path.join(OUT_DIR, "icon-tryA.png"))
    a.resize((256, 256), Image.LANCZOS).save(os.path.join(OUT_DIR, "icon-tryA-small.png"))

    # B：角标留 60px 呼吸位，其余同 A
    b = build(mi, content_ratio=1.02, badge_size=600, badge_radius=100, margin=60)
    b.save(os.path.join(OUT_DIR, "icon-tryB.png"))
    b.resize((256, 256), Image.LANCZOS).save(os.path.join(OUT_DIR, "icon-tryB-small.png"))

    # C：人物再往下沉 90px（脚裁一点，头顶留白更多），角标贴边
    c = build(mi, content_ratio=1.02, badge_size=660, badge_radius=110, margin=0, sink=90)
    c.save(os.path.join(OUT_DIR, "icon-tryC.png"))
    c.resize((256, 256), Image.LANCZOS).save(os.path.join(OUT_DIR, "icon-tryC-small.png"))

    print("已生成 icon-tryA / B / C")
    print("A: 脚贴底 + 角标贴死")
    print("B: 脚贴底 + 角标留 60px")
    print("C: 人物再下沉 90px（脚裁一点，头顶留白更多）+ 角标贴死")


if __name__ == "__main__":
    main()
