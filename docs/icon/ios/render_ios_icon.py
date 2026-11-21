#!/usr/bin/env python3
"""SetCraft iOS-Icon: dasselbe Motiv wie macOS (../macos/render_macos_icon.py),
randlos im iOS-Stil.

iOS rundet die Ecken selbst ab und verlangt ein deckendes Quadrat ohne
Transparenz. Deshalb: 1024 x 1024, Hintergrund bis an den Rand, kein Schatten.
Das Motiv wird so skaliert, dass es im Quadrat dieselben Proportionen hat wie
im 824er-Körper des Mac-Icons (Faktor 1024 / 824).

Erzeugt:
  setcraft-ios-1024.png  — Vorschau
  ../../../SetCraft iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
"""
import os
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "macos"))
from render_macos_icon import BG, MID, PH, bars_full  # noqa: E402  (Motiv nur einmal definieren)

SCALE = 1024 / 824          # Mac-Körper -> randloses iOS-Quadrat
APPICON = os.path.join(HERE, "..", "..", "..", "SetCraft iOS", "Assets.xcassets",
                       "AppIcon.appiconset", "AppIcon-1024.png")


def tx(v):
    """Koordinate um die Mitte skalieren."""
    return (v - MID) * SCALE + MID


def render(px=1024):
    ss = 4
    S = 1024 * ss
    img = Image.new("RGB", (S, S), BG)
    d = ImageDraw.Draw(img)
    for cx, w, h, c in bars_full():
        w2, h2 = w * SCALE / 2, h * SCALE / 2
        x, y = tx(cx), MID
        d.rounded_rectangle([(x - w2) * ss, (y - h2) * ss, (x + w2) * ss, (y + h2) * ss],
                            radius=w2 * ss, fill=c)
    pw = PH["w"] * SCALE / 2
    top, bottom, t = tx(PH["top"]), tx(PH["bottom"]), PH["tri"] * SCALE
    d.rectangle([(MID - pw) * ss, top * ss, (MID + pw) * ss, bottom * ss], fill="#ffffff")
    d.polygon([((MID - t) * ss, top * ss), ((MID + t) * ss, top * ss),
               (MID * ss, (top + t * 1.05) * ss)], fill="#ffffff")
    return img.resize((px, px), Image.LANCZOS)


def main():
    icon = render()
    icon.save(os.path.join(HERE, "setcraft-ios-1024.png"))
    icon.save(os.path.normpath(APPICON))
    print("ok")


if __name__ == "__main__":
    main()
