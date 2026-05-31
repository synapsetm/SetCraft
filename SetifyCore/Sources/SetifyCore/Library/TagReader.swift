import Foundation
import SetifyCoreObjC

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

    public struct Result: Sendable {
        public let track: Track
        /// Bereinigter Kommentar ohne Sterne-Präfix.
        public let cleanComment: String
    }

    public static func read(url: URL) throws -> Result {
        let raw = try SetifyTagBridge.readTags(atPath: url.path)
        let (ratingFromComment, cleanComment) = RatingPrefix.parse(raw.comment)

        let track = Track(
            url: url,
            title: raw.title ?? "",
            artist: raw.artist ?? "",
            album: raw.album ?? "",
            genre: raw.genre ?? "",
            durationSeconds: raw.durationSeconds,
            bpm: parseBPM(raw.bpm),
            key: raw.initialKey.flatMap(CamelotKey.init),
            rating: ratingFromComment
        )

        return Result(track: track, cleanComment: cleanComment)
    }

    private static func parseBPM(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }
}
