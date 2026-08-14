import SwiftUI
import SetCraftCore

/// Key-Zelle der Bibliothek. Steht der Key-Lock auf „aus" und ist ein
/// Master-Tempo gesetzt, zeigt sie `8A → 9A`: links ausgegraut der getaggte
/// Original-Key, rechts farbig der Key, der tatsächlich klingt. Liegt die
/// Verschiebung zwischen zwei Halbtönen, wird der klingende Key mit einer
/// Tilde relativiert.
///
/// Die berechneten Werte sind reine Anzeige — in die Datei geht immer
/// `track.key` (siehe `CLAUDE.md`, `SPEC.md` §5b).
struct SoundingKeyLabel: View {
    let track: Track
    let context: SoundingContext

    /// Warnfarbe für die Tilde, wie im Mockup (`#FF9F45`).
    private static let ambiguousColor = Color(red: 1.0, green: 0.624, blue: 0.271)

    var body: some View {
        if let sounding = track.playingKey(in: context), sounding.isShifted {
            HStack(spacing: 3) {
                Text(sounding.original.description)
                    .foregroundStyle(sounding.original.color.opacity(0.4))
                    .monospacedDigit()
                Image(systemName: "arrow.right")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                if sounding.isAmbiguous {
                    Text("~")
                        .foregroundStyle(Self.ambiguousColor)
                        .monospacedDigit()
                }
                Text(sounding.sounding.description)
                    .foregroundStyle(sounding.sounding.color)
                    .monospacedDigit()
            }
            .help(helpText(for: sounding))
        } else {
            Text(track.key?.description ?? "—")
                .foregroundStyle(track.key?.color ?? Color.secondary)
                .monospacedDigit()
        }
    }

    private func helpText(for sounding: SoundingKey) -> String {
        let shift = String(format: "%+.2f", sounding.exactSemitones)
        if sounding.isAmbiguous {
            return "Klingt \(shift) Halbtöne höher — zwischen zwei Tonarten, die Rundung auf \(sounding.sounding) ist willkürlich. In der Datei steht weiterhin \(sounding.original)."
        }
        return "Klingt \(shift) Halbtöne höher: \(sounding.sounding). In der Datei steht weiterhin \(sounding.original)."
    }
}

/// Hinweisbanner über der Track-Liste, solange die Tonarten verschoben sind.
struct KeyShiftBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.small)
            Text("Key lock aus — die Tonarten verschieben sich mit dem Tempo. Sortierung nach klingendem Key.")
                .font(.caption)
            Spacer()
        }
        .foregroundStyle(Color(red: 1.0, green: 0.624, blue: 0.271))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 1.0, green: 0.624, blue: 0.271).opacity(0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(red: 1.0, green: 0.624, blue: 0.271).opacity(0.32))
                )
        )
    }
}
