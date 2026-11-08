from PIL import Image, ImageDraw, ImageFont
import os

base = r"g:\AI\清弈-ios\docs\render"
ref = r"c:\Users\狂客\.trae-cn\attachments\4b5e6c7d-9e45-4334-aff2-572caea66509_860fdcd0-e3a7-49e6-b1f6-77a41184b8d0_B137EC30-3079-4FAB-8BAF-E3922C9A14CF.png"

panels = [
    (ref, "用户效果图（基准）"),
    (os.path.join(base, "android-lan-game.png"), "Android 真机 1.1.6"),
    (os.path.join(base, "lg-hara-go.png"), "iOS 渲染稿（墨白）"),
    (os.path.join(base, "lg-monument-go.png"), "iOS 渲染稿（粉彩）"),
]

H = 1100
GAP = 20
TOP = 54
imgs = []
for path, label in panels:
    im = Image.open(path).convert("RGB")
    w = int(im.width * H / im.height)
    imgs.append((im.resize((w, H), Image.LANCZOS), label))

total_w = sum(im.width for im, _ in imgs) + GAP * (len(imgs) - 1)
canvas = Image.new("RGB", (total_w, H + TOP), "#FFFFFF")
draw = ImageDraw.Draw(canvas)
font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 22)

x = 0
for im, label in imgs:
    canvas.paste(im, (x, TOP))
    draw.text((x + 6, 14), label, fill="#1A1A1A", font=font)
    x += im.width + GAP

canvas.save(os.path.join(base, "lan-compare.png"))
print("saved", canvas.size)
