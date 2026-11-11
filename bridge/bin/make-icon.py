"""
生成 iOS App 图标（DSH Helm）。

原图：2048×2048 贴纸风格 —— 角色 + 白色描边 + 浅蓝圆底 + 白色四角，右下角有「豆包 AI 生成」水印。

处理思路：
  1. 先把圆内的水印残留逐行回填（圆外那部分交给第 2 步）
  2. 四角纯白 flood fill 成透明 —— 白边和水印所在的白角一起消失
  3. 铺一层浅蓝径向渐变底色，把画布填满
  4. 内容放大到 94%，角色不再显得小
  5. 右下角放 DSH 鲸鱼徽章（只裁鲸鱼本体，不带圆角方块外框）
  6. 输出 1024×1024 无 alpha
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFilter

SRC = r"D:\Documents\deepseek-harness\default-workspace\phone-dsh\assets\icon-source.png"
LOGO = r"C:\Users\acer\AppData\Local\Programs\DeepSeek Harness\resources\icon.png"
OUT_DIR = r"D:\Documents\deepseek-harness\default-workspace\phone-dsh\ios\DSHRemote\Sources\Assets.xcassets\AppIcon.appiconset"
OUT = os.path.join(OUT_DIR, "icon-1024.png")
PREVIEW = r"D:\Documents\deepseek-harness\default-workspace\phone-dsh\dist\icon-preview.png"

CANVAS = 2048
CONTENT_RATIO = 0.94   # 内容占画布比例，越大角色越大


def erase_watermark(img):
    """圆内的水印（浅灰文字）逐行用左侧干净像素回填；圆外部分随后由 flood fill 处理。"""
    px = img.load()
    w, h = img.size
    removed = 0
    for y in range(1865, min(2015, h)):
        ref = px[1650, y]
        for x in range(1680, w):
            r, g, b, a = px[x, y]
            if abs(r - g) < 14 and abs(g - b) < 14 and 150 < (r + g + b) / 3 < 242:
                px[x, y] = ref
                removed += 1
    return removed


def cut_white_corners(img):
    """四角纯白 → 透明。角色周围的白色描边被浅蓝圆隔开，不会一起被吃掉。"""
    w, h = img.size
    for seed in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
        ImageDraw.floodfill(img, seed, (0, 0, 0, 0), thresh=28)


def make_background():
    """浅蓝径向渐变：中心偏白，边缘是原图那个蓝。"""
    bg = Image.new("RGBA", (CANVAS, CANVAS), (255, 255, 255, 255))
    px = bg.load()
    cx = cy = CANVAS / 2
    maxd = (CANVAS / 2) * 1.414
    inner = (232, 245, 255)
    outer = (176, 216, 248)
    for y in range(CANVAS):
        dy = (y - cy) ** 2
        for x in range(CANVAS):
            d = min(1.0, ((x - cx) ** 2 + dy) ** 0.5 / maxd)
            px[x, y] = (
                int(inner[0] + (outer[0] - inner[0]) * d),
                int(inner[1] + (outer[1] - inner[1]) * d),
                int(inner[2] + (outer[2] - inner[2]) * d),
                255,
            )
    return bg


def load_logo(target_w):
    """只取 DSH icon 中间的鲸鱼。

    icon.png 是「白色圆角方块 + 黑鲸鱼」，方块的圆角轮廓同样是深色，
    所以不能靠亮度区分 —— 直接按经验区域裁掉外框，只留鲸鱼本体。
    """
    logo = Image.open(LOGO).convert("RGBA")
    logo = logo.crop((130, 225, 925, 830))
    px = logo.load()
    w, h = logo.size
    for y in range(h):
        for x in range(w):
            r, g, b, _ = px[x, y]
            lum = (r * 299 + g * 587 + b * 114) / 1000
            if lum >= 150:
                px[x, y] = (0, 0, 0, 0)
            else:
                alpha = int(max(0, min(255, (150 - lum) / 90 * 255)))
                px[x, y] = (int(r), int(g), int(b), alpha)
    bbox = logo.getbbox()
    if bbox:
        logo = logo.crop(bbox)
    lw, lh = logo.size
    scale = target_w / lw
    return logo.resize((target_w, max(1, int(lh * scale))), Image.LANCZOS)


def make_badge(size=320, radius=76):
    """角标：白色圆角方块 + 黑色 DSH 鲸鱼 + 一层柔和投影。

    单独给底色是因为纯黑鲸鱼直接压在浅蓝上太小、边界也糊；
    有了圆角白底它才像一个明确的「出品方角标」。
    """
    tile = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # 投影
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (14, 20, size - 14, size - 8), radius=radius, fill=(52, 84, 128, 90)
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(10))
    tile.alpha_composite(shadow)

    # 白底
    ImageDraw.Draw(tile).rounded_rectangle(
        (8, 8, size - 8, size - 8), radius=radius, fill=(255, 255, 255, 255)
    )

    # 鲸鱼：占角标 62%，居中略偏上（视觉重心）
    fish = load_logo(int(size * 0.62))
    fx = (size - fish.size[0]) // 2
    fy = (size - fish.size[1]) // 2 - int(size * 0.02)
    tile.alpha_composite(fish, (fx, fy))
    return tile


def main():
    img = Image.open(SRC).convert("RGBA")
    print(f"原图: {img.size[0]}x{img.size[1]}")

    removed = erase_watermark(img)
    print(f"圆内水印回填: {removed} 像素")

    cut_white_corners(img)
    bbox = img.getbbox()
    if not bbox:
        print("抠图后什么都没剩下")
        sys.exit(1)
    content = img.crop(bbox)
    print(f"内容外接框: {content.size[0]}x{content.size[1]}")

    target = int(CANVAS * CONTENT_RATIO)
    scale = target / max(content.size)
    content = content.resize(
        (max(1, int(content.size[0] * scale)), max(1, int(content.size[1] * scale))),
        Image.LANCZOS,
    )
    print(f"放大后: {content.size[0]}x{content.size[1]}（占画布 {CONTENT_RATIO:.0%}）")

    canvas = make_background()
    bx = (CANVAS - content.size[0]) // 2
    by = (CANVAS - content.size[1]) // 2
    canvas.alpha_composite(content, (bx, by))

    # 角标放右下：留 130px 边距，右下角距 iOS 圆角圆心 (1688,1688) 约 325px < 360，不会被裁
    badge = make_badge(320)
    canvas.alpha_composite(badge, (CANVAS - badge.size[0] - 130, CANVAS - badge.size[1] - 130))
    print(f"角标: {badge.size[0]}x{badge.size[1]}")

    final = canvas.resize((1024, 1024), Image.LANCZOS).convert("RGB")
    os.makedirs(OUT_DIR, exist_ok=True)
    final.save(OUT, "PNG")
    os.makedirs(os.path.dirname(PREVIEW), exist_ok=True)
    final.resize((256, 256), Image.LANCZOS).save(PREVIEW, "PNG")
    print(f"已输出: {OUT}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        print("失败:", exc)
        sys.exit(1)
