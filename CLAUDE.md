# CLAUDE.md — Projektleitplanken (SetCraft)

Diese Datei wird bei jeder Sitzung gelesen. Sie enthält die **verbindlichen Kern-Regeln**.
Den vollständigen Plan (Architektur, Phasen, Detailentscheidungen) findest du in **`SPEC.md`** — lies sie bei Bedarf.

> **Status:** Das Xcode-Projekt **SetCraft** existiert bereits in der schlanken Xcode-Default-Struktur
> (`SetCraft.xcodeproj` + innerer `SetCraft/`-Ordner mit `SetCraftApp.swift`, `ContentView.swift`, `Assets.xcassets`).
> Die in `SPEC.md` skizzierte Aufteilung in ein separates Swift Package ist ein **Vorschlag**, kein Zwang —
> in **Phase 0** entscheiden wir gemeinsam, ob wir bei der flachen Struktur bleiben oder das Package ergänzen.

---

## Was wir bauen

Eine **DJ-orientierte Musikplayer-App für macOS** (Swift / SwiftUI), die später auf **iOS (iPhone)** portierbar sein soll.
Kernmerkmale:

- Frequenzbasierte **RGB-Waveform** (Mixxx-Stil: Bass = Rot, Mitten = Grün, Höhen = Blau).
- **Track-Bibliothek** mit direkt editierbaren Spalten (Titel, Artist, BPM, Genre) und klickbarer **Sterne-Bewertung**.
- **Tempo- und Key-Steuerung**: pro Track änderbar **und** global als „Master" setzbar — jeder geöffnete Track wird auf den Master-Wert gezogen.
- **Automatische BPM- und Key-Analyse** beim Öffnen, falls die Werte nicht in den Metadaten stehen.

Das Projekt ist **nicht-kommerziell / privat**. GPL-Libraries sind daher erlaubt.

---

## Tech-Stack (Kurzfassung)

| Aufgabe | Werkzeug |
|---|---|
| Audio laden/dekodieren | AVFoundation (`AVAudioFile`) |
| Abspielen + Tempo/Key | AVAudioEngine + `AVAudioUnitTimePitch` |
| BPM-Analyse | aubio (GPL) |
| Key-Analyse | libKeyFinder (GPL) → Camelot |
| Waveform-DSP (3 Bänder) | Accelerate / vDSP |
| Waveform-Rendering | Metal |
| Tags lesen/schreiben | TagLib (LGPL) |
| Bibliothek-Speicher | `TrackStore`-Protokoll (erst Tags-only, später SQLite-Cache via GRDB) |

**Native zuerst.** Greife erst zu einer Fremd-Library, wenn der native Apple-Weg nicht reicht — und erkläre dann kurz warum.

---

## Architektur-Grundsatz (nicht verletzen)

- Die plattformunabhängige Logik (Modelle, Engine, Analyse, Store, Waveform-DSP) wird **sauber von der UI getrennt**
  gehalten — entweder als eigenes Swift Package `SetCraftCore` oder als klar abgegrenzte Ordnergruppe im
  bestehenden Projekt. Die SwiftUI-Views enthalten **keine** Audio-/Analyse-/Tag-Logik.
- Die C/C++-Libraries (**aubio, libKeyFinder, TagLib**) werden über eine **Objective-C++-Brücke (`.mm`)** eingebunden
  und hinter **sauberen Swift-Protokollen** versteckt (`Analyzer`, `TrackStore`, `AudioEngine`).
  Niemand außerhalb der Bridge sieht C++-Typen.
- Grund: einfacher iOS-Port, und die GPL-Bausteine bleiben an einer Stelle austauschbar.

---

## Tag-Strategie (KRITISCH — Serato DJ & Rekordbox müssen lesen können)

Beim Zurückschreiben in die Datei (siehe `SPEC.md` für Details):

- **BPM** → `TBPM` (ID3) / `BPM` (Vorbis) / `tmpo` (MP4).
- **Key** → `TKEY` + `INITIALKEY` (ID3) / `INITIALKEY` (Vorbis), Wert in **Camelot** (z. B. `8A`).
- **Rating** → **zwei Felder gleichzeitig**:
  1. `POPM` mit WMP-Mapping (5★=255, 4★=196, 3★=128, 2★=64, 1★=1).
  2. **Sterne-Präfix im Kommentarfeld** (`COMM`/`COMMENT`), z. B. `★★★★☆ | <bestehender Kommentar>`.
     Grund: Rekordbox liest `POPM` **nicht**, zeigt aber das Kommentarfeld an. Das Kommentarfeld ist der
     verlässliche gemeinsame Nenner für Serato **und** Rekordbox.

**Pflichtregeln beim Tag-Schreiben:**
- **Bestehenden Kommentar erhalten.** Nur das eigene Sterne-Token aktualisieren, den Rest unangetastet lassen.
  Beim Lesen das Token sauber herausparsen.
- **Atomar schreiben**: in temporäre Datei schreiben, dann umbenennen. Niemals direkt in die Originaldatei schreiben.
- **Nie in den gerade abgespielten Track schreiben.** Schreibvorgänge serialisieren.
- WAV ist als Tag-Ziel schwach — als Sonderfall behandeln / warnen.

---

## Verhaltensregeln für dich (Claude Code)

1. **Kleine, testbare Schritte.** Kein „große App in einem Rutsch".
2. **Nach jedem funktionierenden Teilschritt committen** mit aussagekräftiger Message im Conventional-Commits-Stil
   (`feat:`, `fix:`, `refactor:`, `chore:`, `docs:`). Beispiel: `feat(audio): play/pause über AVAudioEngine`.
3. **Vor jeder neuen Phase** zuerst deinen Plan in 3–6 Sätzen zusammenfassen und nachfragen, falls etwas unklar ist —
   erst dann Code schreiben.
4. **Vor dem Einbinden einer externen Library** kurz begründen, warum sie nötig ist.
5. **UI nie blockieren** — Analyse und Bibliotheks-Scan laufen asynchron im Hintergrund.
6. **Vor destruktiven Aktionen** (Dateien löschen, Tags überschreiben ohne Backup-Pfad) nachfragen.
7. **Keine Geheimnisse/Keys** committen. `.gitignore` respektieren.
8. Halte dich an die **Phasenreihenfolge** in `SPEC.md`, sofern nicht anders abgesprochen.
9. **Respektiere die bestehende Projektstruktur** — lege nicht ungefragt eine zweite, parallele Struktur an.
   Wenn eine Umstrukturierung sinnvoll ist, schlage sie vor und warte auf Zustimmung.
10. **Bei GUI-Änderungen die Übersetzungen im selben Schritt nachziehen** — siehe unten.

---

## Lokalisierung (bei jeder GUI-Änderung mitziehen)

Beide Targets haben einen eigenen String-Katalog, Quellsprache ist **Englisch**:
`SetCraft/Localizable.xcstrings` (macOS) und `SetCraft iOS/Localizable.xcstrings` (iOS).

**Regel:** Wer einen benutzersichtbaren String hinzufügt, ändert oder entfernt, ergänzt im
**selben Commit** die deutsche Übersetzung. Ein Feature gilt erst als fertig, wenn im
betroffenen Katalog kein Eintrag ohne `de`-Localization steht — ausgenommen reine Symbol-
und Formatstrings (`—`, `●`, `%lld kbps`, `BPM: %@`), die im Deutschen identisch sind.

- **Neue Strings immer auf Englisch in den Code schreiben.** Die Quellsprache ist `en`;
  ein deutscher Literal im Code wird zum Katalog-Key und erscheint dann auch bei
  englischer Systemsprache.
- **Betrifft es beide Plattformen, beide Kataloge pflegen** — sie sind getrennt und
  driften sonst auseinander.
- Der Build extrahiert neue Keys automatisch (Clean-Build nötig, inkrementell reicht nicht);
  **Übersetzungen fügt er nicht hinzu**, das ist Handarbeit.
- **Kataloge nie mit einem JSON-Dumper umschreiben** — das normalisiert Xcodes Formatierung
  und bläht den Diff auf hunderte Zeilen. Einträge direkt im Text einfügen.
- **Mehrfach-Platzhalter positionsbasiert** schreiben (`%1$@`, `%2$@`), weil sich die
  Wortstellung im Deutschen verschiebt.

**Stil im Deutschen** (am Bestand ausgerichtet): geduzt („Was möchtest du tun?"),
Tooltips im Infinitiv („Markierten Track aus der Bibliothek laden"), Schweizer **„ss"
statt „ß"** („Grösse", „Schliessen"). Fachbegriffe bleiben englisch: Track, Player,
Tempo, BPM, Key.

**Prüfen**, ob noch Lücken offen sind:

```sh
python3 -c "
import json,sys
for p in ['SetCraft/Localizable.xcstrings','SetCraft iOS/Localizable.xcstrings']:
    s=json.load(open(p))['strings']
    miss=[k for k,v in s.items() if 'de' not in v.get('localizations',{})]
    print(p, '->', len(miss), 'ohne de:', miss)
"
```

---

## Praktische Stolpersteine (im Hinterkopf behalten)

- **DnB-BPM-Oktavfehler**: aubio erkennt 174 BPM gern als 87. Erwarteten Bereich (z. B. 140–180) bzw.
  Verdopplungs-Heuristik einbauen.
- **Master-Key kann große Pitch-Shifts erzeugen** (Camelot-Nachbarn liegen 5–7 Halbtöne auseinander).
  Key-Anpassung nur sinnvoll mit aktivem **Key-Lock**. Siehe `SPEC.md`.
- **Rekordbox lädt geänderte Tags nicht automatisch neu** — Nutzer muss „reload tags". Erwartetes Verhalten, kein Bug.
