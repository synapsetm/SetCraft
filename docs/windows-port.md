# Windows-Port: Einschätzung

Stand: 2026-10-31. Noch **kein Entscheid und kein Plan**, sondern eine Aufwandsanalyse.

**Grundlage:** Auswertung von Imports, Dateien und Zeilenzahlen. Kompiliert oder unter
Windows getestet wurde nichts. Aussagen zu Windows-Werkzeugen und Libraries sind
Einschätzungen und im Test unten zu prüfen.

## Kurzfassung

Ein Windows-Port ist im Kern ein drittes Frontend plus eine neue Audio-Schicht und damit
grob doppelt so viel Arbeit wie der iOS-Port. Der iOS-Port konnte den Core komplett
übernehmen und musste nur rund 4'600 Zeilen UI neu schreiben. Auf Windows fällt die UI
genauso an, dazu kommt etwa ein Drittel des Cores.

## Was bleibt und was neu muss

| Bereich | Heute | Auf Windows |
|---|---|---|
| **UI** | SwiftUI/AppKit, 4'800 Zeilen inkl. ViewModels | **Komplett neu**, weil es SwiftUI dort nicht gibt |
| **Wiedergabe** | `AVAudioEnginePlayer` (830 Zeilen) | **Neu**: WASAPI für die Ausgabe und eine Library für Tempo und Key, z. B. SoundTouch oder Rubber Band |
| **Dekodieren** | `PCMLoader` über `AVAudioFile` | **Neu**: Media Foundation oder eine Library, Formate wie ALAC gezielt testen |
| **Waveform-Analyse** | vDSP | **Ersetzen**, und die Resultate sollten gleich aussehen wie auf dem Mac |
| **Waveform-Anzeige** | SwiftUI `Canvas` | **Neu** mit Win2D oder Direct2D |
| **C++-Brücke** | Objective-C++ (`.mm`) | **Umschreiben**, weil Objective-C auf Windows wegfällt; die Swift-Protokolle bleiben |
| **C++-Libraries** | XCFrameworks | **Neu bauen** als Windows-Libraries; aubio, TagLib und fftw sollten gehen, libKeyFinder läuft schon in Mixxx unter Windows |
| **Secrets** | Keychain | **Ersetzen** durch den Windows Credential Manager |
| **Metadaten, Tag-Regeln, Modelle, Discogs** | reines Swift/Foundation, rund 4'800 Zeilen | **Weitgehend übernehmbar**; OSLog muss raus (15 Dateien) |
| **Tests** | 3'400 Zeilen XCTest | Für den portablen Teil **weiter nutzbar** und eine gute Absicherung |

Von den rund 7'700 Zeilen in `SetCraftCore/Sources` hängen etwa 2'900 direkt an
Apple-Frameworks oder Objective-C++.

**Etwas Code fällt weg:** `SecurityScope` und `ProtectedDataMonitor` werden nicht mehr
gebraucht, `SourceKeepAlive` wohl auch. Bei `PlaybackCache` entfällt nur ein Teil, denn
das Blockieren auf Netz-Quellen gibt es auch auf Windows, etwa bei OneDrive-Platzhaltern
und SMB.

## Stolpersteine

- **Tempo und Key:** Das grösste technische Risiko, weil Klang und Latenz sich gegenüber
  Apples Time-Pitch hörbar ändern können. Auch die synchrone Playhead-Anzeige muss neu
  eingemessen werden.
- **Atomares Tag-Schreiben:** Windows sperrt geöffnete Dateien. Hat Serato oder Rekordbox
  den Track offen, schlägt das Umbenennen fehl, also braucht es Retry-Logik und
  `ReplaceFileW`.
- **Persistenz:** Ob GRDB unter Windows läuft, ist ungeklärt. Sonst muss die
  Datenbankschicht (`DatabaseService` und die Records) auf SQLite direkt umziehen.
- **Auslieferung:** Sparkle, DMG und Notarisierung müssen ersetzt werden, etwa durch
  WinSparkle oder Velopack und einen Installer. Ohne Code-Signing warnt SmartScreen beim
  Start.
- **Lokalisierung:** Es käme ein dritter Katalog in einem anderen Format dazu, und
  `check-localization.py` müsste ihn mitprüfen.
- **Testen:** Audio und Dateisperren lassen sich nur auf echter Windows-Hardware
  verlässlich prüfen. Dafür braucht es einen Windows-Rechner oder eine VM und eigene Builds.

**Lizenz:** Hier gibt es keine Hürde wie bei iOS. Ohne Store-Zwang geht eine
GPLv3-Verteilung wie beim macOS-DMG.

## Mögliche Wege

1. **Swift-Core plus WinUI über swift-winrt (empfohlen):** Tag-Logik und Tests bleiben
   einmal vorhanden, und alles bleibt in einer Sprache. Die Schwäche ist die wenig
   verbreitete Werkzeugkette für die UI.
2. **Swift-Core plus C#-UI über eine C-Schnittstelle:** Die UI-Technik ist ausgereift,
   aber es gibt drei Sprachen im Build und eine aufwendige Schnittstelle dazwischen.
3. **Kompletter Neubau in C#/.NET oder JUCE (nicht empfohlen):** Das hat die beste
   Windows-Integration, aber die kritischen Tag-Regeln gäbe es dann zweimal, und sie
   würden auseinanderdriften.

## Empfehlung

Den Port nur angehen, wenn jemand Konkretes die App wirklich auf Windows braucht. Jedes
Feature müsste sonst dreimal gebaut, getestet und übersetzt werden.

Falls ja, kommt vor jedem Produktcode ein kurzer Test in zwei Schritten:

1. **Core kompilieren:** Der portable Teil samt Tests läuft mit `swift test` unter Windows,
   GRDB eingeschlossen.
2. **Audio-Prototyp:** Ein Track spielt mit Tempo- und Key-Änderung über WASAPI.

Scheitert einer der beiden Schritte, fällt Weg 1 weg. Dann eher ganz auf den Port
verzichten als neu bauen.

## Randnotiz

`CLAUDE.md` nennt Metal für die Waveform, im Code gibt es aber keinen Metal-Code: Die
Mac-App rendert mit SwiftUI `Canvas`. Für den Port ist das günstig, weil kein Shader-Code
übertragen werden muss.
