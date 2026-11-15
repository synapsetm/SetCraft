# SetCraft App-Icon

Frequenzbasierte RGB-Waveform mit zentraler, überragender Playhead auf dunklem Squircle.

> **Seit v1.5 (2026-11-15) getrennt nach Plattform.**
> - **macOS:** `macos/` — unregelmässige Waveform mit 22 Balken, Bass (Rot) links bis Höhen
>   (Violett) rechts, nach macOS-Vorlage (1024er Canvas, Körper 824 × 824 mit 100 px Rand,
>   Radius 185, Schlagschatten). Für 16/32 px die reduzierte Variante mit 6 Balken.
>   `macos/render_macos_icon.py` (Pillow) erzeugt SVGs, Vorschauen und ein `AppIcon.appiconset`
>   in `macos/` — danach von Hand nach `SetCraft/Assets.xcassets/AppIcon.appiconset/` kopieren.
> - **iOS:** die Dateien in diesem Ordner (unten) — das bisherige symmetrische Motiv, randlos
>   im iOS-Stil. Der Abschnitt „In Xcode einsetzen" unten betrifft nur noch iOS.

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
