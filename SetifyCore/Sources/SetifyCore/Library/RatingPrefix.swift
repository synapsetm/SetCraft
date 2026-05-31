import Foundation

/// Konvertierung zwischen einem `Rating` und dem Sterne-Präfix im Kommentarfeld.
///
/// Format: `★★★★☆ | <restlicher Kommentar>`
/// - 0 Sterne: kein Präfix, der Kommentar bleibt unverändert.
/// - 1–5 Sterne: genau fünf Symbole (★ oder ☆), dann ` | `, dann der Rest.
///
/// Beim Lesen wird das Präfix erkannt **und** entfernt, sodass der UI-Layer
/// nur den eigentlichen Kommentartext sieht. Beim Schreiben muss der
/// bestehende (bereinigte) Kommentartext mitgegeben werden, damit dieser
/// erhalten bleibt.
public enum RatingPrefix {

    public static let separator = " | "

    /// Aus einem rohen Kommentartext Sterne und Rest-Kommentar trennen.
    public static func parse(_ raw: String?) -> (rating: Rating, rest: String) {
        guard let raw, !raw.isEmpty else {
            return (.none, "")
        }

        // Erste fünf Skalare prüfen.
        var iterator = raw.unicodeScalars.makeIterator()
        var prefix: [Unicode.Scalar] = []
        for _ in 0..<5 {
            guard let scalar = iterator.next() else { break }
            prefix.append(scalar)
        }

        guard prefix.count == 5 else {
            return (.none, raw)
        }

        var stars = 0
        var valid = true
        for scalar in prefix {
            switch scalar {
            case "★": stars += 1
            case "☆": break
            default:  valid = false
            }
            if !valid { break }
        }

        guard valid else {
            return (.none, raw)
        }

        let prefixLength = 5  // genau fünf Skalare
        let afterPrefix = raw.unicodeScalars.index(
            raw.unicodeScalars.startIndex,
            offsetBy: prefixLength
        )

        var rest = String(raw.unicodeScalars[afterPrefix...])
        if rest.hasPrefix(separator) {
            rest.removeFirst(separator.count)
        } else if rest.first == " " {
            // toleranter: einzelnes Leerzeichen entfernen, falls Separator fehlt
            rest.removeFirst()
        }

        return (Rating(stars: stars), rest)
    }

    /// Aus einem Rating + bestehendem (bereits bereinigtem) Kommentartext den
    /// vollständigen Wert für das Kommentarfeld bauen.
    public static func format(_ rating: Rating, rest: String) -> String {
        guard rating.stars > 0 else {
            return rest
        }
        let stars = String(repeating: "★", count: rating.stars)
            + String(repeating: "☆", count: 5 - rating.stars)
        return rest.isEmpty ? stars : stars + separator + rest
    }
}
