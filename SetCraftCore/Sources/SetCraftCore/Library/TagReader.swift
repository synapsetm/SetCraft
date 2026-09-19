import Foundation
import SetCraftCoreObjC

/// Liest Datei-Tags via TagLib-Bridge und baut daraus einen `Track`.
///
/// Heuristik:
/// - Fehlende Titel werden in der UI über `Track.displayTitle` aus dem
///   Dateinamen abgeleitet — hier wird der Rohwert `""` belassen.
/// - BPM wird aus dem String der Datei geparst (Komma oder Punkt).
/// - Key wird als Camelot interpretiert, falls möglich.
/// - Rating wird aus dem Sterne-Präfix des Kommentars gelesen
///   (`POPM` als Sekundärquelle kommt später, sobald die Bridge das liefert).
/// - Der bereinigte Kommentar steht im `Track`-Modell nicht — er wird im
///   Library-ViewModel separat geführt, damit das Sterne-Präfix beim
///   Schreiben rekonstruiert werden kann.
public enum TagReader {

    public static func read(url: URL) throws -> Track {
        let raw = try SetCraftTagBridge.readTags(atPath: url.path)
        let (ratingFromComment, cleanComment) = RatingPrefix.parse(raw.comment)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }

        return Track(
            url: url,
            title: raw.title ?? "",
            artist: raw.artist ?? "",
            album: raw.album ?? "",
            genre: raw.genre ?? "",
            comment: cleanComment,
            durationSeconds: raw.durationSeconds,
            bpm: parseBPM(raw.bpm),
            key: raw.initialKey.flatMap(CamelotKey.init),
            rating: ratingFromComment,
            year: raw.year > 0 ? Int(raw.year) : nil,
            bitrate: raw.bitrate > 0 ? Int(raw.bitrate) : nil,
            label: raw.label ?? "",
            fileSize: fileSize
        )
    }

    private static func parseBPM(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized) else { return nil }
        return sanitizedBPM(value)
    }

    /// Obergrenze und Endlichkeit für BPM aus fremden Tags.
    ///
    /// `Double("inf")` ist ein gültiger Double, und ein BPM-Tag mit diesem Text
    /// (oder mit `1e300`) hat die Waveform-Zeichnung auf iOS zum Stillstand
    /// gebracht: das Beat-Grid rechnet `bar = 60 / bpm * 4`, das wird 0 bzw.
    /// subnormal, und der Schleifenzähler `t += bar` kommt nicht mehr vorwärts —
    /// bei `inf` wird `t` sogar NaN, womit jede Abbruchbedingung false ist.
    /// Die Schleife ist inzwischen zusätzlich begrenzt; hier wird der Unsinn
    /// gar nicht erst ins Modell gelassen.
    ///
    /// 500 als Grenze lässt jedes real vorkommende Genre durch (Speedcore liegt
    /// bei 250–300) und verwirft, was kein Tempo sein kann — etwa die in manchen
    /// Werkzeugen auftauchende ×100-Schreibweise („12800" für 128,00). Dafür
    /// bewusst kein Rateraten: ein verworfener Wert wird von der Analyse ersetzt,
    /// ein falsch interpretierter bleibt falsch.
    static func sanitizedBPM(_ value: Double) -> Double? {
        guard value.isFinite, value > 0, value <= 500 else { return nil }
        return value
    }
}
