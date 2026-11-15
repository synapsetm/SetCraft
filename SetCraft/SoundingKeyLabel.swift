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
    /// Ersetzt alle Farben, z. B. `onAccent` in einer markierten Zeile.
    var tint: Color? = nil

    var body: some View {
        if let sounding = track.playingKey(in: context), sounding.isShifted {
            HStack(spacing: 3) {
                Text(sounding.original.description)
                    .foregroundStyle((tint ?? sounding.original.color).opacity(0.4))
                    .monospacedDigit()
                Image(systemName: "arrow.right")
                    .imageScale(.small)
                    .foregroundStyle(tint.map { AnyShapeStyle($0.opacity(0.6)) } ?? AnyShapeStyle(.tertiary))
                if sounding.isAmbiguous {
                    Text("~")
                        .foregroundStyle(tint ?? Theme.Palette.keyAmbiguous)
                        .monospacedDigit()
                }
                Text(sounding.sounding.description)
                    .foregroundStyle(tint ?? sounding.sounding.color)
                    .monospacedDigit()
            }
            .help(helpText(for: sounding))
        } else {
            Text(track.key?.description ?? "—")
                .foregroundStyle(tint ?? track.key?.color ?? Theme.Palette.textMuted)
                .monospacedDigit()
        }
    }

    private func helpText(for sounding: SoundingKey) -> String {
        let shift = String(format: "%+.2f", sounding.exactSemitones)
        if sounding.isAmbiguous {
            return String(localized: "Sounds \(shift) semitones off — between two keys, so rounding to \(sounding.sounding.description) is arbitrary. The file still says \(sounding.original.description).")
        }
        return String(localized: "Sounds \(shift) semitones off: \(sounding.sounding.description). The file still says \(sounding.original.description).")
    }
}

/// Hinweisbanner über der Track-Liste, solange die Tonarten verschoben sind.
struct KeyShiftBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.small)
            Text("Master tempo active — keys shift with the tempo. Sorted by sounding key.")
                .font(.caption)
            Spacer()
        }
        .foregroundStyle(Theme.Palette.keyAmbiguous)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                .fill(Theme.Palette.keyAmbiguous.opacity(0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                        .strokeBorder(Theme.Palette.keyAmbiguous.opacity(0.32))
                )
        )
    }
}
