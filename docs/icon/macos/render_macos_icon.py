#!/usr/bin/env python3
"""SetCraft macOS-Icon (Big-Sur-Vorlage): 1024er Canvas, Body 824x824 @100, Radius 185.4, Schatten.
Erzeugt SVG-Master (voll + reduziert), PNG-Vorschau und das AppIcon.appiconset.

Das Motiv (Balken, Farben, Playhead) nutzt auch ../ios/render_ios_icon.py —
deshalb laufen die Ausgaben nur beim direkten Aufruf (main)."""
import os, json
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.dirname(os.path.abspath(__file__))
SET = os.path.join(OUT, "AppIcon.appiconset")

BODY = (100, 100, 924, 924); R = 185.4
BG = "#15151a"; MID = 512

# Spektrum warm -> kalt (Bass links, Hoehen rechts), mit leichten Spruengen
SPEC = ["#FF5630","#FF6A33","#FF7A33","#F59A3C","#F5B544","#C9D24A","#9BCB4E","#7DC850",
        "#3FB950","#2BB9A6","#2BC4C4","#3AA6E0","#4A8DF0","#5E7BEE","#6E72EC","#7A6CEC",
        "#9070E6","#A375E3","#B57BE0","#C27FD8","#CC86D0","#D28BC8"]

# FULL: 11 Balken links (aussen->innen), Playhead, 11 rechts (innen->aussen) - bewusst unregelmaessig
LEFT  = [70, 150, 105, 265, 185, 335, 135, 405, 245, 170, 360]
RIGHT = [300, 430, 155, 240, 385, 115, 280, 205, 90, 175, 60]
STEP, W = 28, 18
PH = dict(w=14, top=196, bottom=828, tri=34)          # Playhead ueberragt die Waveform

SMALL_L = [180, 390, 235]; SMALL_R = [425, 195, 300]
S_STEP, S_W = 100, 62
S_PH = dict(w=40, top=214, bottom=810, tri=70)

def bars_full():
    out = []
    for i, h in enumerate(LEFT):                       # i=0 ist ganz aussen
        cx = MID - STEP * (11 - i)
        out.append((cx, W, h, SPEC[i]))
    for i, h in enumerate(RIGHT):
        cx = MID + STEP * (i + 1)
        out.append((cx, W, h, SPEC[11 + i]))
    return out

def bars_small():
    cols_l = ["#FF7A33", "#F5B544", "#7DC850"]; cols_r = ["#2BB9A6", "#4A8DF0", "#A375E3"]
    out = []
    for i, h in enumerate(SMALL_L):
        out.append((MID - S_STEP * (3 - i), S_W, h, cols_l[i]))
    for i, h in enumerate(SMALL_R):
        out.append((MID + S_STEP * (i + 1), S_W, h, cols_r[i]))
    return out

def svg(bars, ph, title):
    s = [f'<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">',
         f'<title>{title}</title>',
         '<defs><filter id="sh" x="-20%" y="-20%" width="140%" height="140%">'
         '<feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000" flood-opacity="0.30"/></filter>'
         f'<clipPath id="body"><rect x="100" y="100" width="824" height="824" rx="{R}"/></clipPath></defs>',
         f'<rect x="100" y="100" width="824" height="824" rx="{R}" fill="{BG}" filter="url(#sh)"/>',
         '<g clip-path="url(#body)">']
    for cx, w, h, c in bars:
        s.append(f'<rect x="{cx-w/2:.1f}" y="{MID-h/2:.1f}" width="{w}" height="{h}" rx="{w/2:.1f}" fill="{c}"/>')
    pw = ph["w"]
    s.append(f'<rect x="{MID-pw/2:.1f}" y="{ph["top"]}" width="{pw}" height="{ph["bottom"]-ph["top"]}" fill="#ffffff"/>')
    t = ph["tri"]
    s.append(f'<polygon points="{MID-t},{ph["top"]} {MID+t},{ph["top"]} {MID},{ph["top"]+t*1.05:.0f}" fill="#ffffff"/>')
    s.append('</g></svg>')
    return "\n".join(s)

def render(bars, ph, px):
    ss = 4; S = 1024 * ss
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # Schatten
    sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([BODY[0]*ss, (BODY[1]+10)*ss, BODY[2]*ss, (BODY[3]+10)*ss],
                                         radius=R*ss, fill=(0, 0, 0, 77))
    sh = sh.filter(ImageFilter.GaussianBlur(14*ss))
    img.alpha_composite(sh)
    # Body + Inhalte auf eigener Ebene, dann mit Body-Maske clippen
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(layer)
    d.rounded_rectangle([b*ss for b in BODY], radius=R*ss, fill=BG)
    for cx, w, h, c in bars:
        d.rounded_rectangle([(cx-w/2)*ss, (MID-h/2)*ss, (cx+w/2)*ss, (MID+h/2)*ss], radius=w/2*ss, fill=c)
    pw = ph["w"]; t = ph["tri"]
    d.rectangle([(MID-pw/2)*ss, ph["top"]*ss, (MID+pw/2)*ss, ph["bottom"]*ss], fill="#ffffff")
    d.polygon([((MID-t)*ss, ph["top"]*ss), ((MID+t)*ss, ph["top"]*ss), (MID*ss, (ph["top"]+t*1.05)*ss)], fill="#ffffff")
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([b*ss for b in BODY], radius=R*ss, fill=255)
    img.paste(layer, (0, 0), mask)
    return img.resize((px, px), Image.LANCZOS)

def main():
    os.makedirs(SET, exist_ok=True)
    FULL, SMALL = bars_full(), bars_small()
    open(os.path.join(OUT, "setcraft-icon-1024.svg"), "w").write(svg(FULL, PH, "SetCraft macOS Icon"))
    open(os.path.join(OUT, "setcraft-icon-small.svg"), "w").write(svg(SMALL, S_PH, "SetCraft macOS Icon (klein)"))
    render(FULL, PH, 1024).save(os.path.join(OUT, "setcraft-icon-1024.png"))
    render(SMALL, S_PH, 1024).save(os.path.join(OUT, "setcraft-icon-small.png"))

    jobs = [(16,"icon_16x16.png",SMALL,S_PH),(32,"icon_16x16@2x.png",SMALL,S_PH),(32,"icon_32x32.png",SMALL,S_PH),
            (64,"icon_32x32@2x.png",FULL,PH),(128,"icon_128x128.png",FULL,PH),(256,"icon_128x128@2x.png",FULL,PH),
            (256,"icon_256x256.png",FULL,PH),(512,"icon_256x256@2x.png",FULL,PH),(512,"icon_512x512.png",FULL,PH),
            (1024,"icon_512x512@2x.png",FULL,PH)]
    images = []
    for px, name, b, ph in jobs:
        render(b, ph, px).save(os.path.join(SET, name))
        size = name.split("_")[1].split("@")[0].replace(".png","")
        images.append({"size": size, "idiom": "mac", "filename": name, "scale": "2x" if "@2x" in name else "1x"})
    json.dump({"images": images, "info": {"version": 1, "author": "xcode"}}, open(os.path.join(SET, "Contents.json"), "w"), indent=2)

    # Kontaktblatt
    sizes = [(1024,"setcraft-icon-1024.png"),]
    sheet_sizes = [16, 32, 64, 128, 256, 512]
    files = {16:"icon_16x16.png",32:"icon_32x32.png",64:"icon_32x32@2x.png",128:"icon_128x128.png",256:"icon_256x256.png",512:"icon_512x512.png"}
    pad = 28; H = 512 + 2*pad; W = sum(sheet_sizes) + pad*(len(sheet_sizes)+1)
    for name, bg in [("preview-dark.png",(30,30,34,255)),("preview-light.png",(236,236,240,255))]:
        sheet = Image.new("RGBA", (W, H), bg); x = pad
        for s in sheet_sizes:
            im = Image.open(os.path.join(SET, files[s])).convert("RGBA")
            sheet.alpha_composite(im, (x, (H - s)//2)); x += s + pad
        sheet.save(os.path.join(OUT, name))
    print("ok")


if __name__ == "__main__":
    main()
