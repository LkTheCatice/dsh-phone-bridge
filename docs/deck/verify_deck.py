"""复查：页数、标题序列、转场是否写入、图片是否嵌入。"""
import os
from pptx import Presentation
from pptx.oxml.ns import qn

HERE = os.path.dirname(os.path.abspath(__file__))
path = os.path.join(HERE, "DSH-Helm-宣传.pptx")
prs = Presentation(path)

print("slides:", len(prs.slides))
print("size:", round(prs.slide_width / 914400, 2), "x", round(prs.slide_height / 914400, 2), "in")

for i, slide in enumerate(prs.slides, 1):
    texts = []
    pics = 0
    for shape in slide.shapes:
        if shape.shape_type == 13:
            pics += 1
        if shape.has_text_frame:
            t = shape.text_frame.text.strip()
            if t:
                texts.append(t.split("\n")[0])
    trans = slide._element.find(qn("p:transition"))
    kind = "none"
    if trans is not None:
        for child in trans:
            tag = child.tag.split("}")[-1]
            if tag not in ("sndAc",):
                kind = tag
                break
    head = texts[0][:34] if texts else "(no text)"
    print(f"{i:2d}. transition={kind:6s} pics={pics}  {head}")
