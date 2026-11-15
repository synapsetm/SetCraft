import SwiftUI
import SetCraftCore

/// Reine Anzeige der gerade gespielten Tonart im Now-Playing-Raster — ohne
/// Klickfläche, anders als der `TempoChip`: Key-Änderungen laufen über das
/// Tempo, einen eigenen Key-Regler gibt es nicht.
///
/// Weicht der klingende Key vom Original ab, steht wie in der Bibliothek
/// `8A → 9A`: links klein und gedimmt das Original, rechts gross der Key,
/// der tatsächlich klingt. Beides reine Anzeige (SPEC §5b).
struct KeyChip: View {
    @Bindable var transport: TransportViewModel
    let hasLoadedTrack: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Key").themeLabel()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let original = transport.originalKey,
                   let effective = transport.effectiveKey,
                   original != effective {
                    Text(original.description)
                        .font(Theme.Typo.title.monospacedDigit())
                        .foregroundStyle(original.color.opacity(0.4))
                    Image(systemName: "arrow.right")
                        .font(Theme.Typo.artist)
                        .foregroundStyle(Theme.Palette.textMuted)
                }
                Text(displayKey)
                    .font(Theme.Typo.readout)
                    .foregroundStyle(keyColor)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Key")
    }

    private var displayKey: String {
        transport.effectiveKey?.description ?? "—"
    }

    private var keyColor: Color {
        transport.effectiveKey?.color ?? Theme.Palette.textMuted
    }
}
