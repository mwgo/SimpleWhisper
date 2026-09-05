#!/usr/bin/env python3
"""Generates Resources/AppIcon.icns: fresh-green macOS icon with a microphone and level bars."""
from PIL import Image, ImageDraw, ImageFilter
import os, subprocess

S = 4096
root = os.path.join(os.path.dirname(__file__), "..", "Resources")
icon_dir = os.path.join(root, "Icon")
os.makedirs(os.path.join(icon_dir, "AppIcon.iconset"), exist_ok=True)

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
pad = int(S * 0.09)
r = int((S - 2 * pad) * 0.2237)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([pad, pad, S - pad, S - pad], radius=r, fill=255)

# Vertical gradient around the HUD green (#3DDC84).
top, bot = (120, 240, 170), (40, 196, 115)
grad = Image.new("RGBA", (S, S))
px = grad.load()
for y in range(S):
    t = y / (S - 1)
    c = tuple(int(top[i] * (1 - t) + bot[i] * t) for i in range(3)) + (255,)
    for x in range(S):
        px[x, y] = c
bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
bg.paste(grad, (0, 0), mask)

def clipped(layer):
    layer.putalpha(Image.composite(layer.split()[3], Image.new("L", (S, S), 0), mask))
    return layer

hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(hl).ellipse([pad - S * 0.1, pad - S * 0.35, S * 0.9, S * 0.55], fill=(255, 255, 255, 80))
bg = Image.alpha_composite(bg, clipped(hl.filter(ImageFilter.GaussianBlur(S * 0.08))))
sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(sh).rounded_rectangle([pad, pad + S * 0.02, S - pad, S - pad + S * 0.02], radius=r, fill=(0, 0, 0, 50))
bg = Image.alpha_composite(bg, clipped(sh.filter(ImageFilter.GaussianBlur(S * 0.02))))
img = Image.alpha_composite(img, bg)

white = (255, 255, 255, 255)
cx, cy = S / 2, S / 2
bw, bh = S * 0.20, S * 0.40
body = [cx - bw / 2, cy - bh / 2 - S * 0.05, cx + bw / 2, cy + bh / 2 - S * 0.05]
msh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(msh).rounded_rectangle([body[0], body[1] + S * 0.02, body[2], body[3] + S * 0.02], radius=bw / 2, fill=(0, 0, 0, 80))
img = Image.alpha_composite(img, msh.filter(ImageFilter.GaussianBlur(S * 0.015)))
d = ImageDraw.Draw(img)
d.rounded_rectangle(body, radius=bw / 2, fill=white)
for i in range(3):
    y = body[1] + bh * 0.35 + i * bh * 0.12
    d.rounded_rectangle([cx - bw * 0.28, y - S * 0.008, cx + bw * 0.28, y + S * 0.008], radius=S * 0.008, fill=(70, 215, 140, 255))
lw = S * 0.035
ub = [cx - bw / 2 - S * 0.06, body[1] + bh * 0.35, cx + bw / 2 + S * 0.06, body[3] + S * 0.06]
d.arc(ub, start=0, end=180, fill=white, width=int(lw))
d.rounded_rectangle([cx - lw / 2, ub[3] - S * 0.01, cx + lw / 2, ub[3] + S * 0.09], radius=lw / 2, fill=white)
d.rounded_rectangle([cx - S * 0.10, ub[3] + S * 0.075, cx + S * 0.10, ub[3] + S * 0.075 + lw], radius=lw / 2, fill=white)
for side in (-1, 1):
    for i, h in enumerate([0.10, 0.18, 0.13]):
        x = cx + side * (bw / 2 + S * 0.13 + i * S * 0.065)
        hh = S * h
        d.rounded_rectangle([x - S * 0.018, cy - hh / 2 - S * 0.02, x + S * 0.018, cy + hh / 2 - S * 0.02], radius=S * 0.018, fill=(255, 255, 255, 235))

final = img.resize((1024, 1024), Image.LANCZOS)
final.save(os.path.join(icon_dir, "icon_1024.png"))
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        name = f"icon_{size}x{size}" + ("@2x" if scale == 2 else "") + ".png"
        final.resize((size * scale, size * scale), Image.LANCZOS).save(os.path.join(icon_dir, "AppIcon.iconset", name))
subprocess.run(["iconutil", "-c", "icns", os.path.join(icon_dir, "AppIcon.iconset"), "-o", os.path.join(root, "AppIcon.icns")], check=True)
print("Resources/AppIcon.icns written")
