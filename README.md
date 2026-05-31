# Setify

Ein DJ-orientierter Musikplayer für macOS (mit geplantem iOS/iPad-Port).
Frequenzbasierte RGB-Waveform, editierbare Bibliothek mit Sterne-Bewertung, Tempo-/Key-Steuerung
(pro Track und global) sowie automatische BPM-/Key-Analyse.

> **Planungsdokumente:** `CLAUDE.md` (verbindliche Leitplanken) und `SPEC.md` (vollständiger Plan).
> UI-Entwurf: `docs/mockup-main.html` im Browser öffnen.

Privates, nicht-kommerzielles Projekt — GPL-Libraries erlaubt.

---

## Ablage dieser Dateien

Diese Dateien liegen auf der **Repo-Wurzel** — also dort, wo `Setify.xcodeproj` und der innere
`Setify/`-Ordner nebeneinander liegen, **nicht** im inneren Quellcode-Ordner und nicht im `.xcodeproj`:

```
Setify/                    ← hier startest du Claude Code & git init
├── CLAUDE.md
├── SPEC.md
├── README.md
├── .gitignore
├── docs/mockup-main.html
├── Setify/                ← Quellcode (SetifyApp.swift, ContentView.swift, Assets.xcassets)
└── Setify.xcodeproj
```

---

## Voraussetzungen (Setup-Reihenfolge)

1. **Xcode** (App Store) — bereits vorhanden, da das Projekt existiert.
2. **Xcode Command Line Tools**:
   ```
   xcode-select --install
   ```
   (Liefert git, clang, make — von Claude Code und beim Library-Bau benötigt.)
3. **Homebrew** (https://brew.sh), dann die C/C++-Libraries:
   ```
   brew install aubio libkeyfinder taglib
   ```
   (aubio zieht FFTW als Abhängigkeit; libKeyFinder ggf. weitere — Homebrew löst das auf.)
4. **Claude Code** (nativer Installer, kein Node.js nötig):
   ```
   curl -fsSL https://claude.ai/install.sh | bash
   ```
   Voraussetzung: macOS 13.0+ und ein bezahltes Anthropic-Konto (Pro/Max/Team/Enterprise/Console).
   Der kostenlose Claude.ai-Plan enthält keinen Claude-Code-Zugang.
5. Optional: **VS Code** als zusätzlicher Editor (Claude Code läuft im Terminal, auch aus VS Code heraus).

---

## Loslegen mit Claude Code

Einmalig auf der Repo-Wurzel, falls noch nicht geschehen:

```
git init
```

Dann:

```
claude
```

Als ersten Auftrag etwa:

> Lies `CLAUDE.md` und `SPEC.md`. Das Setify-Xcode-Projekt existiert bereits in der flachen
> Default-Struktur. Fasse deinen Plan für **Phase 0** in 3–6 Sätzen zusammen — inklusive deiner
> Empfehlung zur Code-Organisation (Weg A oder B aus SPEC §6) — und frag nach, was unklar ist,
> **bevor** du Code schreibst.

Claude Code liest `CLAUDE.md` automatisch bei jeder Sitzung; `SPEC.md` bei Bedarf.

---

## Hinweis zum kniffligen Teil

Das Einbinden der C/C++-Libraries (aubio, libKeyFinder, TagLib) in das Swift/Xcode-Projekt über die
Objective-C++-Brücke (Header-Pfade, Linker-Flags, Framework-Einbettung) ist erfahrungsgemäß der
aufwändigste Schritt — mehr als die App-Logik. Diese Libraries sind deshalb hinter den Protokollen
`Analyzer` und `TrackStore` gekapselt, damit das Gefummel an einer Stelle isoliert bleibt.

---

## Lizenzen der verwendeten Libraries

| Library | Zweck | Lizenz |
|---|---|---|
| AVFoundation, Accelerate, Metal | nativ (Audio, DSP, Rendering) | Apple |
| aubio | BPM-Analyse | GPL |
| libKeyFinder | Key-Analyse | GPL |
| TagLib | Tags lesen/schreiben | LGPL |
| GRDB.swift (später) | SQLite-Cache | MIT |
| SFBAudioEngine (optional) | zusätzliche Decoder | MIT/BSD-Anteile (prüfen) |

Da privat/nicht-kommerziell, ist GPL hier unproblematisch.
