# M3U / M3U8 · Playlists importieren und exportieren

Stufe 1: **Import als Quelle (nur lesen) + Export**. Bearbeiten von Playlists (Umsortieren, Hinzufügen,
Zurückschreiben in die M3U) ist bewusst **Stufe 2** und nicht Teil dieser Spec.

## Spielregeln
- Plattformneutrale Logik (Parser, Writer, Pfadauflösung, Relink-Suche) gehört nach **SetCraftCore**
  (`Library/`), nicht in die Views. macOS (`LibraryViewModel`) und iOS (`LibraryStore`) rufen nur auf.
- Zugriff auf Dateien über die bestehende Sandbox-Logik
  (`Library/SecurityScope.swift`, Bookmarks in `Persistence/FolderRecord.swift`).
  **Ausnahme (entschieden 2026-11-21):** macOS erhält
  `temporary-exception.files.absolute-path.read-write` für `/Volumes/`, damit Playlists mit Tracks
  auf NAS/USB ohne Ordner-Dialog laden. Der Freigabe-Dialog aus §2 bleibt für Pfade ausserhalb
  von `/Volumes/`. iOS unverändert.
- M3U-Dateien werden in Stufe 1 **nie verändert**. Audiodateien und deren Tags ebenfalls nicht.
- Beim Export gelten die Regeln aus SPEC §5b sinngemäss: keine Wiedergabewerte (gespielter BPM/Key) schreiben.
- Darstellung im Stil B6 (macOS) bzw. I1 (iOS, `docs/design/ios-amber/`).
- Texte über `Localizable.xcstrings` beider Targets, danach `scripts/check-localization.py`.

## 1. Parser (SetCraftCore)

Eingabe: Datei-URL der Playlist. Ausgabe: geordnete Liste von Einträgen
`PlaylistEntry { index, rawLine, resolvedURL?, extDuration?, extArtist?, extTitle? }`.

- **Zeichensatz:** `.m3u8` immer UTF-8. `.m3u`: zuerst UTF-8 (BOM entfernen); ist das ungültig, Windows-1252.
- **Zeilenenden:** `\n`, `\r\n` und `\r` akzeptieren. Leerzeilen ignorieren.
- **Direktiven:** `#EXTM3U` optional. `#EXTINF:<sek>,<Artist> - <Title>` gehört zur nächsten Pfadzeile
  (Dauer kann `-1` sein; Trennung Artist/Title am ersten ` - `). Alle anderen `#`-Zeilen ignorieren
  (z. B. `#EXTVLCOPT`, `#PLAYLIST`).
- **Pfadformen:**
  - absolut: `/Volumes/share/…`
  - relativ zur M3U-Datei: `Tracks/abc.mp3`, `../Musik/abc.mp3`
  - URL: `file:///Volumes/…` mit Prozent-Kodierung (`%20`)
  - Windows-Pfade (`C:\…`, `\\server\…`): Backslashes normalisieren; nur der Dateiname ist für Relink brauchbar.
  - `http(s)://`-Einträge: als «nicht unterstützt» markieren, nicht laden.
- **Reihenfolge und Duplikate** bleiben exakt erhalten (ein Track darf mehrfach vorkommen).
- Unit-Tests mit Fixtures für: UTF-8 mit BOM, Windows-1252 mit Umlauten, CRLF, relative Pfade mit `..`,
  `file://` mit `%20`, fehlendes `#EXTM3U`, `#EXTINF` ohne Artist, Rekordbox-Export, Traktor-Export.

## 2. Pfadauflösung und Sandbox

Reihenfolge pro Eintrag:
1. Pfad existiert und liegt in einem Ordner mit vorhandenem Bookmark → direkt verwenden.
2. Pfad existiert, aber ohne Zugriffsrecht → Eintrag als **«kein Zugriff»** markieren.
   Nach dem Einlesen einmal den **kleinsten gemeinsamen übergeordneten Ordner** aller solcher Einträge
   ermitteln und den Nutzer per Ordner-Dialog um Freigabe bitten (vorausgewählt auf diesen Ordner).
   Nach Freigabe Bookmark speichern (wie bei «Add folder») und neu auflösen.
3. Pfad existiert nicht → **Relink-Kandidat** (siehe 4).

Die M3U-Datei selbst wird beim Import als Bookmark gespeichert, damit die Playlist nach einem Neustart
wieder geöffnet werden kann.

**iOS:** Absolute Mac-Pfade existieren nicht. Dort immer über Relink auflösen
(relativer Pfad innerhalb freigegebener Ordner, sonst Dateiname). Für Playlists, die vom Mac kommen,
ist das der Normalfall, kein Fehlerfall.

## 3. Darstellung als Quelle

- Eine importierte Playlist ist ein **eigener Quellentyp** neben Ordnern, in der Quellenliste mit
  Playlist-Symbol und Nummer (macOS-Sidebar «04 ▸ Set BMF 2027», iOS-Quellen-Menü analog).
- Standard-Sortierung: **Playlist-Reihenfolge** (eigene Spalte/Sortierung «#»). Andere Sortierungen
  sind möglich; «#» stellt die Reihenfolge wieder her.
- Statuszeile: «24 TRACKS · 2 MISSING · 1 NO ACCESS».
- Einträge ohne Datei bleiben in der Liste: ausgegraut, mit Pfad als Tooltip/Detail und Aktion **Relink**.
  Bei Einträgen mit `#EXTINF` Artist/Title aus der M3U anzeigen.
- Entfernen der Quelle entfernt nur den Eintrag in SetCraft, nicht die M3U-Datei.
- Bestehende Funktionen (Analyse, Rating, Tags ergänzen, Abspielen) wirken auf die aufgelösten Tracks
  genauso wie in Ordnerquellen.

## 4. Relink

- Suche über alle vorhandenen Quellordner, Reihenfolge:
  1. gleicher relativer Pfad-Schwanz (letzte 2–3 Pfadsegmente),
  2. gleicher Dateiname,
  3. gleicher Dateiname ohne Gross-/Kleinschreibung und Unicode-normalisiert (NFC/NFD, wichtig für Umlaute auf NAS).
- Genau ein Treffer → automatisch zuordnen, Zeile mit dezentem «relinked»-Hinweis.
- Mehrere Treffer → Auswahl anzeigen. Kein Treffer → «Locate…» (Datei-Dialog).
- Relink-Ergebnis wird in der SQLite-Basis zur Playlist gespeichert (Original-Pfad → aufgelöste Datei),
  die M3U bleibt unverändert.

## 5. Export

- Aktion **«Export as M3U8…»** im Overflow-Menü (macOS Toolbar, iOS «•••»): exportiert die
  **aktuell angezeigte Liste in der aktuellen Sortierung**; ist eine Auswahl aktiv, nur die Auswahl.
- Format:
  ```
  #EXTM3U
  #EXTINF:447,One Function - Ajna (IKØN Remix)
  /Volumes/share/_INCOMING Traxx/One_Function_-_Ajna.mp3
  ```
  UTF-8 ohne BOM, Zeilenende `\n`, Dauer in ganzen Sekunden.
- Option **Pfade:** absolut (Standard; für Rekordbox/Traktor auf demselben Rechner) oder
  **relativ zum Speicherort der M3U** (für USB-Stick/Ordner, in dem Playlist und Musik zusammen liegen).
  Ist ein relativer Pfad nicht möglich (anderes Volume), absolut schreiben und im Abschlussdialog melden.
- Fehlende Einträge (ohne Datei) werden nicht exportiert; Anzahl im Abschlussdialog nennen.
- iOS: Export über das Teilen-Menü bzw. «In Dateien sichern».

## 6. Abnahme
- Unit-Tests für Parser, Pfadauflösung und Writer (Roundtrip: Export → Import ergibt gleiche Reihenfolge).
- Manuell geprüft und in `STATUS.md` festgehalten:
  - Rekordbox-Export (M3U8) und Traktor-Export (M3U) in SetCraft importiert.
  - SetCraft-Export in **Rekordbox** und **Serato** importiert. Erst danach im README als kompatibel bezeichnen.
  - Playlist mit Tracks ausserhalb freigegebener Ordner: genau ein Freigabe-Dialog.
  - Gleiche Playlist auf iOS: Tracks werden über Relink gefunden.

## Stufe 2 (nicht jetzt)
Reihenfolge per Drag & Drop ändern, Tracks hinzufügen/entfernen, Änderungen in die M3U zurückschreiben
(atomar, mit Rückfrage), eigene Playlists ohne M3U-Datei in SQLite.
