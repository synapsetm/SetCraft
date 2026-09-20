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
- **NIEMALS berechnete Wiedergabewerte persistieren.** In die Datei geht immer der **Original**-Key und
  die **Original**-BPM aus Analyse/Tag — nie der durch Master-Tempo/Master-Key verschobene Anzeigewert.
  Modell strikt trennen: `track.key` / `track.bpm` (persistiert) vs. `track.playingKey` / `track.playingBPM`
  (berechnet, nur Anzeige). Siehe `SPEC.md` §5b.
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

**Prüfen** (das betroffene Target vorher bauen, das Skript liest die vom
Compiler extrahierten `.stringsdata`):

```sh
python3 scripts/check-localization.py                 # beide Targets
python3 scripts/check-localization.py --target ios    # nur iOS
```

Gemeldet werden fehlende `de`-Einträge, nicht zusammenpassende Platzhalter,
„ß" statt „ss", Karteileichen, Keys ohne Katalogeintrag — und Fälle, in denen
macOS und iOS denselben Key unterschiedlich übersetzen. Letzteres ist der
häufigste Fehler, weil die Kataloge getrennt sind.

**Der Rückgabewert taugt als Gate:** 0 = sauber, 1 = blockierender Befund
**oder** fehlende bzw. veraltete Build-Daten. Rein informative Kategorien
(Karteileichen, `de` == Key bei Einzelbegriffen wie „Album") lassen ihn in
Ruhe. Sind die `.stringsdata` älter als die Quellen, bricht das Skript ab,
statt einen veralteten Stand als sauber zu melden.

**Beide Release-Skripte prüfen das automatisch** — nach dem Archive, vor dem
Export. Ein fehlender deutscher String bricht den Release ab, bevor etwas
notarisiert oder zu App Store Connect hochgeladen wird. Bewusst übergehen:
`SKIP_L10N_CHECK=1 ./scripts/release.sh`.

---

## Praktische Stolpersteine (im Hinterkopf behalten)

- **DnB-BPM-Oktavfehler**: aubio erkennt 174 BPM gern als 87. Erwarteten Bereich (z. B. 140–180) bzw.
  Verdopplungs-Heuristik einbauen.
- **Master-Key kann große Pitch-Shifts erzeugen** (Camelot-Nachbarn liegen 5–7 Halbtöne auseinander).
  Key-Anpassung nur sinnvoll mit aktivem **Key-Lock**. Siehe `SPEC.md`.
- **Rekordbox lädt geänderte Tags nicht automatisch neu** — Nutzer muss „reload tags". Erwartetes Verhalten, kein Bug.
- **Jede Datei-API kann bei einer Netz-Quelle blockieren.** Bei einer
  FileProvider-URL (iCloud, NAS/SMB aus der Files-App, gemountetes Netz-Volume)
  geht auch eine harmlos aussehende Metadaten-Abfrage zum Provider und kehrt
  ohne Netz nicht zurück — `resourceValues`, ein Verzeichnis-Listing, ein
  `AVAudioFile`-Open. Drei Einfrier-Befunde dieser Art stehen in `STATUS.md`,
  alle nach demselben Muster: synchroner Aufruf auf dem MainActor. Solche
  Aufrufe gehören auf eine **eigene DispatchQueue** — nicht auf den MainActor
  und nicht auf den Cooperative Pool, dessen enges Thread-Budget ein
  sekundenlang blockierter Aufruf sprengt. Achtung: die App-Targets laufen mit
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, ein `Task { }` in einer
  ViewModel-Klasse erbt den MainActor also.
- **Nie direkt von einer Provider-URL abspielen.** Der Download läuft
  sequenziell, Reads blockieren bis zu ihrer Stelle — die Engine spielt sonst
  Stille bei laufendem Playhead, ohne Fehlermeldung. Gespielt wird aus
  `PlaybackCache`. Details und Messwerte in `SPEC.md` §5c.
- **Swift 6: ein nicht-`@Sendable`-Callback erbt die Isolation seines
  Entstehungsorts.** Ruft das Framework ihn auf einer eigenen Queue auf, prüft
  die Runtime das und der Prozess stirbt mit `EXC_BREAKPOINT` — genau so beim
  `MPMediaItemArtwork`-Handler passiert, der im `@MainActor`-NowPlayingManager
  gebildet wurde. Solche Closures in einer `nonisolated` Funktion bauen.
