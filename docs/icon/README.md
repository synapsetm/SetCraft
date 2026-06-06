# SetCraft App-Icon

Frequenzbasierte RGB-Waveform mit zentraler, überragender Playhead auf dunklem Squircle.

## Dateien

- `setcraft-icon-1024.svg` — Vektor-Master des vollen Motivs (9 Balken + Playhead, symmetrisch).
- `setcraft-icon-small.svg` — reduzierte Variante für kleine Größen (7 Balken + Playhead).
- `setcraft-icon-1024.png`, `setcraft-icon-small.png` — gerasterte Vorschauen.
- `preview-contact-sheet.png` — alle Größen nebeneinander zur Kontrolle.
- `render_icons.py` — erzeugt sämtliche PNGs neu (Pillow nötig: `pip install pillow`).
- `../../SetCraft/Assets.xcassets/AppIcon.appiconset/` — **fertiges Icon-Set für Xcode** (10 PNGs + `Contents.json`).

## In Xcode einsetzen

Das `AppIcon.appiconset` liegt bereits am richtigen Ort: `SetCraft/Assets.xcassets/AppIcon.appiconset/`.
Sobald du den SetCraft-Ordner als Projekt öffnest, sollte Xcode das Icon automatisch erkennen
(Target → General → App Icons → „AppIcon"). Falls nicht:

1. In Xcode `Assets.xcassets` öffnen.
2. Prüfen, dass ein Eintrag `AppIcon` mit allen Größen (16/32/128/256/512 je @1x/@2x) gefüllt ist.
3. Unter Target → General → „App Icon" `AppIcon` auswählen.

## Größenstrategie

- **16 / 32px** nutzen das reduzierte Motiv (weniger Balken, vertikal gestaucht) — bleibt lesbar.
- **64px und größer** nutzen das volle Motiv.
Das ist bei macOS-Icons üblich und vorgesehen (separate Bilder pro Größe).

## Neu rendern / anpassen

Farben, Balkenhöhen oder -abstände in `render_icons.py` ändern und das Skript erneut ausführen:

```
cd SetCraft
python3 docs/icon/render_icons.py
```

Die PNGs im `AppIcon.appiconset` werden dabei überschrieben.
