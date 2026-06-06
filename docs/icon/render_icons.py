#!/usr/bin/env python3
"""Rendert die SetCraft-Icons in alle macOS-Größen (PNG) plus 1024 Master."""
from PIL import Image, ImageDraw

BG = (21, 21, 26, 255)  # #15151a

# Balken im 1024er-Koordinatenraum: (x, y, w, h, farbe)
# Playhead mittig bei cx=512 (Breite 30 -> x=497). Je vier Balken links/rechts,
# Rasterabstand 72px von Mittelachse aus, symmetrisch gespiegelt.
def _bar(cx, h, col, w=41):
    return (int(cx - w / 2), int(512 - h / 2), w, int(h), col)

FULL = [
    _bar(512 - 4 * 72, 150, "#FF5630"),
    _bar(512 - 3 * 72, 330, "#FF7A33"),
    _bar(512 - 2 * 72, 560, "#F5B544"),
    _bar(512 - 1 * 72, 250, "#7DC850"),
    (497, 512 - 760 // 2, 30, 760, "#FFFFFF"),  # Playhead, mittig, überragt
    _bar(512 + 1 * 72, 250, "#4A8DF0"),
    _bar(512 + 2 * 72, 560, "#7A6CEC"),
    _bar(512 + 3 * 72, 330, "#5E7BEE"),
    _bar(512 + 4 * 72, 150, "#B57BE0"),
]
SMALL = [
    (276, 432, 52, 160, "#FF7A33"),
    (346, 336, 52, 352, "#F5B544"),
    (416, 448, 52, 128, "#7DC850"),
    (486, 208, 52, 608, "#FFFFFF"),
    (556, 448, 52, 128, "#4A8DF0"),
    (626, 336, 52, 352, "#7A6CEC"),
    (696, 432, 52, 160, "#B57BE0"),
]

def hx(c):
    c = c.lstrip("#")
    return tuple(int(c[i:i+2], 16) for i in (0, 2, 4)) + (255,)

def render(bars, px):
    # supersample x4 für saubere Kanten
    ss = 4
    S = 1024 * ss
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    radius = int(230 * ss)
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=radius, fill=BG)
    for (x, y, w, h, col) in bars:
        x0, y0 = x * ss, y * ss
        x1, y1 = (x + w) * ss, (y + h) * ss
        rr = (w * ss) / 2
        d.rounded_rectangle([x0, y0, x1, y1], radius=rr, fill=hx(col))
    return img.resize((px, px), Image.LANCZOS)

OUT = "SetCraft/Assets.xcassets/AppIcon.appiconset"
import os
os.makedirs(OUT, exist_ok=True)

# (px, dateiname, welches motiv)
jobs = [
    (16,   "icon_16x16.png",     SMALL),
    (32,   "icon_16x16@2x.png",  SMALL),
    (32,   "icon_32x32.png",     SMALL),
    (64,   "icon_32x32@2x.png",  FULL),
    (128,  "icon_128x128.png",   FULL),
    (256,  "icon_128x128@2x.png",FULL),
    (256,  "icon_256x256.png",   FULL),
    (512,  "icon_256x256@2x.png",FULL),
    (512,  "icon_512x512.png",   FULL),
    (1024, "icon_512x512@2x.png",FULL),
]
for px, name, bars in jobs:
    render(bars, px).save(os.path.join(OUT, name))

# Master-PNGs für die Doku
render(FULL, 1024).save("docs/icon/setcraft-icon-1024.png")
render(SMALL, 512).save("docs/icon/setcraft-icon-small.png")
print("done")
