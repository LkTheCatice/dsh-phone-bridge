"""生成 DSH Helm 宣传 PPT（含转场与分镜式动效表达）。

说明：python-pptx 不支持写入元素级动画时间轴，所以：
  · 页面级别注入**淡入 / 推入**转场（PowerPoint 会播放）
  · 关键动作用「连续分镜」表达（运行中 → 收尾 → 查看）
  · 真正的交互动效放在 docs/ui-demo/index.html（现场演示）
"""

import os
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE
from pptx.oxml.ns import qn
from lxml import etree

HERE = os.path.dirname(os.path.abspath(__file__))
IMG = os.path.join(HERE, "img")
OUT = os.path.join(HERE, "DSH-Helm-宣传.pptx")

# ── 设计令牌（与 App 一致）────────────────────────────────────
BG = RGBColor(0x0E, 0x11, 0x16)
CARD = RGBColor(0x17, 0x1B, 0x21)
CARD2 = RGBColor(0x1F, 0x24, 0x2C)
ACCENT = RGBColor(0x0A, 0x84, 0xFF)
GREEN = RGBColor(0x34, 0xC7, 0x59)
TEXT = RGBColor(0xF2, 0xF3, 0xF5)
MUTED = RGBColor(0x9B, 0xA1, 0xAA)
LINE = RGBColor(0x2C, 0x32, 0x3C)
FONT = "微软雅黑"

prs = Presentation()
prs.slide_width = Inches(13.333)
prs.slide_height = Inches(7.5)
W, H = prs.slide_width, prs.slide_height


def dark(slide):
    bg = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, 0, 0, W, H)
    bg.fill.solid()
    bg.fill.fore_color.rgb = BG
    bg.line.fill.background()
    bg.shadow.inherit = False
    return bg


def text(slide, s, x, y, w, h, size=18, color=TEXT, bold=False,
         align=PP_ALIGN.LEFT, line=1.35, space_after=0):
    box = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = box.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = MSO_ANCHOR.TOP
    paras = s.split("\n")
    for i, line_text in enumerate(paras):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = align
        p.line_spacing = line
        p.space_after = Pt(space_after)
        r = p.add_run()
        r.text = line_text
        r.font.size = Pt(size)
        r.font.bold = bold
        r.font.color.rgb = color
        r.font.name = FONT
    return box


def card(slide, x, y, w, h, fill=CARD, radius=True, outline=None):
    shape_type = MSO_SHAPE.ROUNDED_RECTANGLE if radius else MSO_SHAPE.RECTANGLE
    s = slide.shapes.add_shape(shape_type, Inches(x), Inches(y), Inches(w), Inches(h))
    s.fill.solid()
    s.fill.fore_color.rgb = fill
    if outline is None:
        s.line.fill.background()
    else:
        s.line.color.rgb = outline
        s.line.width = Pt(0.75)
    s.shadow.inherit = False
    if radius:
        try:
            s.adjustments[0] = 0.08
        except Exception:
            pass
    return s


def phone(slide, img, x, y, height_in, outline=LINE):
    """放一张手机截图：按比例算宽，外加细边框。"""
    from PIL import Image
    path = os.path.join(IMG, img)
    if not os.path.exists(path):
        return None
    iw, ih = Image.open(path).size
    h = Inches(height_in)
    w = Emu(int(h * iw / ih))
    pic = slide.shapes.add_picture(path, Inches(x), Inches(y), height=h)
    frame = slide.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, pic.left, pic.top, pic.width, pic.height)
    frame.fill.background()
    frame.line.color.rgb = outline
    frame.line.width = Pt(1)
    frame.shadow.inherit = False
    try:
        frame.adjustments[0] = 0.06
    except Exception:
        pass
    return pic


def chip(slide, icon, name, tag, x, y, w=4.6, tag_color=ACCENT):
    """产物卡片：与手机端同一套样式。"""
    c = card(slide, x, y, w, 0.44, fill=CARD2)
    text(slide, f"{icon}  {name}", x + 0.16, y + 0.08, w - 1.5, 0.3, size=12)
    text(slide, tag, x + w - 1.05, y + 0.11, 0.9, 0.26, size=10, color=tag_color, align=PP_ALIGN.RIGHT)
    return c


def add_transition(slide, kind="fade", speed="med"):
    """往 slide XML 注入转场：PowerPoint 原生播放。"""
    xml = (
        '<p:transition xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
        'xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main" spd="%s">'
        '<p:%s/>'
        "</p:transition>" % (speed, kind)
    )
    el = etree.fromstring(xml)
    sld = slide._element
    # 转场必须放在 cSld/clrMapOvr 之后、timing 之前
    anchor = sld.find(qn("p:timing"))
    if anchor is not None:
        anchor.addprevious(el)
    else:
        sld.append(el)


def new_slide():
    return prs.slides.add_slide(prs.slide_layouts[6])


# ═════════════════════════════════════════════════════════════
# 1. 封面
# ═════════════════════════════════════════════════════════════
s = new_slide()
dark(s)
text(s, "DSH Helm", 0.9, 1.55, 6.4, 1.0, size=54, bold=True)
text(s, "手机就是你的 DeepSeek Harness 控制台", 0.95, 2.6, 6.6, 0.6, size=22, color=TEXT)
text(s, "电脑跑活 · 端到端加密 · 手机上看着它干",
     0.95, 3.3, 6.6, 0.5, size=15, color=MUTED)
card(s, 0.95, 4.3, 5.6, 0.06, fill=ACCENT, radius=False)
text(s, "宣传用 · 2026-11-13", 0.95, 4.55, 5, 0.4, size=12, color=MUTED)
phone(s, "chat-logs.jpg", 7.6, 1.05, 5.7)
phone(s, "fold.jpg", 10.4, 1.55, 4.7)

# ═════════════════════════════════════════════════════════════
# 2. 三个"不用"
# ═════════════════════════════════════════════════════════════
s = new_slide()
dark(s)
text(s, "以前：离开电脑就断了线", 0.9, 0.75, 11, 0.7, size=32, bold=True)
items = [
    ("不在电脑前", "看不到它在干什么，只能等结果"),
    ("过程会丢", "日志刷完就没了，出错没法回溯"),
    ("产物看不见", "生成的文档、图片、包，手机上完全不知道"),
]
for i, (head, sub) in enumerate(items):
    x = 0.9 + i * 4.05
    card(s, x, 2.0, 3.7, 2.5, fill=CARD)
    text(s, f"0{i+1}", x + 0.35, 2.25, 1.2, 0.5, size=26, color=ACCENT, bold=True)
    text(s, head, x + 0.35, 2.95, 3.0, 0.5, size=20, bold=True)
    text(s, sub, x + 0.35, 3.5, 3.0, 0.9, size=13, color=MUTED, line=1.5)
text(s, "DSH Helm 把这三件事补齐：过程可回看、每一步可下钻、产物可打开。",
     0.9, 5.0, 11.5, 0.6, size=17, color=TEXT)
text(s, "连接走端到端加密（X25519 + AES-GCM），电脑侧仍是唯一执行者。",
     0.9, 5.6, 11.5, 0.5, size=13, color=MUTED)

# ═════════════════════════════════════════════════════════════
# 3. 架构
# ═════════════════════════════════════════════════════════════
s = new_slide()
dark(s)
text(s, "怎么连的", 0.9, 0.7, 6, 0.7, size=32, bold=True)
# 电脑
card(s, 0.9, 1.9, 4.1, 3.5, fill=CARD)
text(s, "🖥  电脑（唯一执行者）", 1.2, 2.15, 3.6, 0.4, size=15, bold=True)
text(s, "· DeepSeek Harness 跑会话 / 工具 / 文件\n"
       "· 产物落在本机目录\n"
       "· 手机只能读白名单内的路径",
     1.2, 2.7, 3.4, 2.2, size=12.5, color=MUTED, line=1.6)
# 中间通道
card(s, 5.35, 2.55, 2.6, 2.2, fill=CARD2, outline=ACCENT)
text(s, "端到端加密", 5.55, 2.85, 2.2, 0.4, size=14, bold=True, color=ACCENT, align=PP_ALIGN.CENTER)
text(s, "SSE 推送\nX25519 握手\nAES-GCM 帧", 5.55, 3.3, 2.2, 1.2,
     size=11.5, color=MUTED, align=PP_ALIGN.CENTER, line=1.6)
# 手机
card(s, 8.3, 1.9, 4.1, 3.5, fill=CARD)
text(s, "📱  手机（看 + 控）", 8.6, 2.15, 3.6, 0.4, size=15, bold=True)
text(s, "· 实时看思考 / 工具 / 回答\n"
       "· 发送、排队、插队、停止\n"
       "· 点开任一产物预览或下载",
     8.6, 2.7, 3.4, 2.2, size=12.5, color=MUTED, line=1.6)
text(s, "断线不丢事：横幅常显、可划掉，重连后自动收起。",
     0.9, 5.75, 11.6, 0.5, size=13, color=MUTED)

# ═════════════════════════════════════════════════════════════
# 4. 运行中（分镜 1/3）
# ═════════════════════════════════════════════════════════════
s = new_slide()
dark(s)
text(s, "① 干活的时候，逐条看得见", 0.9, 0.7, 11, 0.6, size=30, bold=True)
phone(s, "chat-logs.jpg", 0.9, 1.6, 5.2)
text(s, "思考与工具同一套排版", 5.9, 1.85, 6.4, 0.4, size=17, bold=True)
text(s, "· 行首统一 “> ”，等宽 12pt 灰字，和日志一类\n"
       "· 思考最多两行，第二行放不下才省略\n"
       "· 工具行、产物卡片同宽对齐，一眼扫得下去",
     5.9, 2.35, 6.5, 2.0, size=13.5, color=MUTED, line=1.7)
card(s, 5.9, 4.45, 6.4, 1.6, fill=CARD2)
text(s, "> 思考 · 先确认这一轮的日志结构……\n"
       "> 运行命令 · Verify the build artifact\n"
       "> 读取 · uploads/1794560546-image.jpg",
     6.15, 4.62, 5.9, 1.3, size=11.5, color=MUTED, line=1.6)

# ═════════════════════════════════════════════════════════════
# 5. 结束后（分镜 2/3）
# ═════════════════════════════════════════════════════════════
s = new_slide()
dark(s)
text(s, "② 结束后，收成一张卡片", 0.9, 0.7, 11, 0.6, size=30, bold=True)
phone(s, "fold.jpg", 0.9, 1.6, 5.2)
text(s, "「▸ 本轮过程 · N 步」", 5.9, 1.85, 6.4, 0.4, size=17, bold=True)
text(s, "· 只要有步骤就折叠，哪怕只跑了一步\n"
       "· 主题色卡片，看得出能点\n"
       "· 主列表因此保持干净：一轮只占一行",
     5.9, 2.35, 6.5, 1.9, size=13.5, color=MUTED, line=1.7)
chip(s, "▸", "本轮过程 · 10 步", "点击查看  ›", 5.9, 4.4, w=5.6)
text(s, "内部实现：折叠只存引用，不复制内容；步骤数据来自帧，可重建。",
     5.9, 5.1, 6.5, 0.5, size=11.5, color=MUTED)

# ═════════════════════════════════════════════════════════════
# 6. 本轮过程页（分镜 3/3）
# ═════════════════════════════════════════════════════════════
s = new_slide()
dark(s)
text(s, "③ 想看的时候，逐条展开", 0.9, 0.7, 11, 0.6, size=30, bold=True)
phone(s, "turnlog.jpg", 0.9, 1.6, 5.2)
text(s, "每一步都能再点开", 5.9, 1.85, 6.4, 0.4, size=17, bold=True)
rows = [
    ("1", "思考", "先确认这一轮的日志结构", True),
    ("2", "运行命令", "Verify the build artifact", True),
    ("3", "读取", "uploads/…-0.jpg", True),
    ("4", "写入", "docs/KNOWN-GOOD.md", True),
]
for i, (idx, name, sub, ok) in enumerate(rows):
    y = 2.4 + i * 0.72
    card(s, 5.9, y, 6.4, 0.62, fill=CARD2)
    text(s, idx, 6.02, y + 0.16, 0.35, 0.3, size=11, color=MUTED)
    text(s, name, 6.4, y + 0.1, 2.0, 0.28, size=12.5)
    text(s, sub, 6.4, y + 0.33, 3.6, 0.26, size=10.5, color=MUTED)
    text(s, "✔", 11.75, y + 0.16, 0.35, 0.3, size=11, color=GREEN)
text(s, "点任意一行 → 参数 / 结果 / 它读过的图（下一张）",
     5.9, 5.5, 6.4, 0.4, size=12, color=ACCENT)

# ═════════════════════════════════════════════════════════════
# 7. 步骤详情
# ═════════════════════════════════════════════════════════════
s = new_slide()
dark(s)
text(s, "它看过的，你也能看见", 0.9, 0.7, 11, 0.6, size=30, bold=True)
text(s, "工具详情 = 参数 + 结果 + 它读过的图片（电脑侧压到 900px 再传）",
     0.9, 1.4, 11.6, 0.45, size=14, color=MUTED)
card(s, 0.9, 2.1, 5.6, 4.4, fill=CARD)
text(s, "读取", 1.2, 2.3, 3, 0.35, size=14, bold=True)
text(s, "uploads/1794560546-image-1794560546-0.jpg", 1.2, 2.65, 5.0, 0.3, size=10.5, color=MUTED)
card(s, 1.2, 3.05, 5.0, 1.35, fill=CARD2)
text(s, '{\n  "type": "text",\n  "text": "<path>E:\\\\AI\\\\…\\\\x.png</path>"\n}',
     1.4, 3.15, 4.6, 1.2, size=10, color=MUTED, line=1.5)
card(s, 1.2, 4.55, 5.0, 1.7, fill=CARD2)
text(s, "🖼  图片预览（点开可看大图 / 保存）", 1.4, 4.7, 4.6, 0.3, size=11, color=ACCENT)
text(s, "电脑侧压缩后再传：几十 MB 的原图 → 几百 KB", 1.4, 5.05, 4.6, 0.6, size=10.5, color=MUTED)
text(s, "为什么值得强调", 7.1, 2.1, 5, 0.4, size=16, bold=True)
text(s, "· 出问题时，第一句话通常是“它到底看了什么”\n"
       "· 以前只有电脑上能翻；现在点工具行就能看\n"
       "· 图片路径来自工具参数，不额外记录、不额外上传",
     7.1, 2.6, 5.3, 2.2, size=13, color=MUTED, line=1.7)

# ═════════════════════════════════════════════════════════════
# 8. 产物卡片
# ═════════════════════════════════════════════════════════════
s = new_slide()
dark(s)
text(s, "产出什么，一眼看到", 0.9, 0.7, 11, 0.6, size=30, bold=True)
text(s, "所有产物统一成一张卡片：图标 + 文件名 + 能力标签",
     0.9, 1.4, 11.6, 0.45, size=14, color=MUTED)
cards = [
    ("🖼", "案例图.png", "可预览", ACCENT),
    ("🎬", "demo.mp4", "可预览", ACCENT),
    ("📝", "晨报.md", "可预览", ACCENT),
    ("📄", "方案.docx", "下载", MUTED),
    ("🗜", "素材.zip", "下载", MUTED),
    ("📦", "DSHRemote.ipa", "下载", MUTED),
]
for i, (icon, name, tag, color) in enumerate(cards):
    x = 0.9 + (i % 2) * 5.9
    y = 2.2 + (i // 2) * 0.95
    chip(s, icon, name, tag, x, y, w=5.5, tag_color=color)
text(s, "「可预览」= 点开就能看（图片 / 视频 / 音频 / 文本）",
     0.9, 5.25, 11.6, 0.4, size=13, color=TEXT)
text(s, "「下载」= 手机不能直接看，取回到本地再分享",
     0.9, 5.7, 11.6, 0.4, size=13, color=MUTED)
text(s, "不再靠“路径里恰好有图片”来猜——按扩展名分类，源码不提示，避免刷屏。",
     0.9, 6.3, 11.6, 0.4, size=12, color=MUTED)

# ═════════════════════════════════════════════════════════════
# 9. 输入与队列
# ═════════════════════════════════════════════════════════════
s = new_slide()
dark(s)
text(s, "排队、插队、长文输入", 0.9, 0.7, 11, 0.6, size=30, bold=True)
three = [
    ("排队", "忙的时候发出去不丢，进队列等你点", "队列 N 条 / 已排队提示只由服务端状态驱动"),
    ("插队", "对队列里的某条点插队，它会在当前小任务收尾后立刻执行", "回答会落到它自己下面，不并进上一个气泡"),
    ("长文输入", "输入框到 5 行后转为内部滚动，光标始终可见", "以前超过上限的文字会“打不进去”"),
]
for i, (head, body, note) in enumerate(three):
    x = 0.9 + i * 4.05
    card(s, x, 1.9, 3.7, 2.7, fill=CARD)
    text(s, head, x + 0.35, 2.15, 3.0, 0.45, size=19, bold=True)
    text(s, body, x + 0.35, 2.75, 3.05, 1.2, size=12.5, color=MUTED, line=1.6)
    text(s, note, x + 0.35, 3.95, 3.05, 0.5, size=11, color=ACCENT, line=1.5)
text(s, "底栏：连接 / 画图状态两行，右侧「对话 · 设置」，键盘弹起时自动让位。",
     0.9, 5.1, 11.6, 0.5, size=13, color=MUTED)

# ═════════════════════════════════════════════════════════════
# 10. 稳定性
# ═════════════════════════════════════════════════════════════
s = new_slide()
dark(s)
text(s, "稳定性不是“感觉”，是几个具体约束", 0.9, 0.7, 11.6, 0.6, size=28, bold=True)
rows = [
    ("顺序", "列表顺序 = (轮次, 帧时间, 轮内序号, id)，全部来自帧数据",
     "重启 / 上拉 / 切会话，投影出来的顺序都一样"),
    ("贴底", "冷启动时“贴底”是一个持续状态，不是一次性滚动",
     "内容分批到达也不会停在半路"),
    ("去重", "用户消息 id 是内容+轮次的确定性哈希",
     "回放与回显不会出现两条一样的提问"),
    ("断线", "横幅未连接常显、可划掉、5 秒回来、连上即消",
     "重连时的相位抖动不再让它闪"),
]
for i, (k, v, note) in enumerate(rows):
    y = 1.85 + i * 1.15
    card(s, 0.9, y, 11.6, 0.98, fill=CARD)
    text(s, k, 1.15, y + 0.28, 1.1, 0.4, size=15, bold=True, color=ACCENT)
    text(s, v, 2.4, y + 0.16, 9.8, 0.4, size=13)
    text(s, note, 2.4, y + 0.55, 9.8, 0.35, size=11, color=MUTED)

# ═════════════════════════════════════════════════════════════
# 11. 现场演示
# ═════════════════════════════════════════════════════════════
s = new_slide()
dark(s)
text(s, "现场演示（可交互）", 0.9, 0.75, 11, 0.7, size=32, bold=True)
text(s, "docs/ui-demo/index.html", 0.9, 1.55, 8, 0.45, size=17, color=ACCENT)
steps = [
    ("1", "浏览器打开 index.html", "单文件、无依赖；右侧面板可逐场景触发"),
    ("2", "点「▶ 自动播完整流程」", "开屏 → 发消息 → 思考 → 工具 → 回答 → 折叠 → 过程页 → 步骤详情"),
    ("3", "或按 URL 加 ?autoplay=1", "自动跑完约 9 秒，适合直接录屏"),
]
for i, (n, head, sub) in enumerate(steps):
    y = 2.25 + i * 1.05
    card(s, 0.9, y, 6.6, 0.88, fill=CARD)
    text(s, n, 1.1, y + 0.22, 0.4, 0.4, size=15, bold=True, color=ACCENT)
    text(s, head, 1.6, y + 0.13, 5.7, 0.35, size=13)
    text(s, sub, 1.6, y + 0.47, 5.7, 0.35, size=10.5, color=MUTED)
card(s, 7.9, 2.25, 4.5, 3.6, fill=CARD2)
text(s, "演示里能看到的动效", 8.15, 2.45, 4.0, 0.35, size=13, bold=True)
text(s, "· 开屏 2.3s 停留 + 0.5s 淡出\n"
       "· 思考行逐字流式（两行截断）\n"
       "· 工具行逐条落下\n"
       "· 过程行收成折叠卡片\n"
       "· 页面推入「本轮过程」\n"
       "· 步骤详情滑出",
     8.15, 2.9, 4.0, 2.6, size=11.5, color=MUTED, line=1.65)
text(s, "为什么用网页演示：PPT 不能承载可点击的交互，也不适合放逐字流式。",
     0.9, 6.2, 11.6, 0.4, size=12, color=MUTED)

# ═════════════════════════════════════════════════════════════
# 12. 结尾
# ═════════════════════════════════════════════════════════════
s = new_slide()
dark(s)
text(s, "一句话", 0.9, 1.5, 11, 0.6, size=20, color=ACCENT, bold=True)
text(s, "让手机成为一双眼睛和一只手，\n但活仍然在电脑上跑。",
     0.9, 2.05, 11.6, 1.8, size=40, bold=True, line=1.35)
text(s, "过程可回看 · 每一步可下钻 · 产物可打开", 0.95, 4.1, 11, 0.5, size=18, color=MUTED)
card(s, 0.95, 4.9, 5.4, 0.05, fill=ACCENT, radius=False)
text(s, "仓库：phone-dsh　|　构建：Codemagic ios-unsigned-ipa　|　包：dist/DSHRemote-unsigned.ipa",
     0.95, 5.15, 11, 0.4, size=11, color=MUTED)

# ── 全部页面注入转场 ────────────────────────────────────────
for i, slide in enumerate(prs.slides):
    add_transition(slide, kind="push" if i in (3, 4, 5) else "fade", speed="med")

prs.save(OUT)
print("saved:", OUT, "slides:", len(prs.slides.__iter__.__self__._sldIdLst))
