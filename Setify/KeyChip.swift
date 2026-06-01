import SwiftUI
import SetifyCore

/// Reine Anzeige der gerade gespielten Tonart — bewusst ohne Capsule/Border,
/// damit sie sich visuell vom editierbaren `TempoChip` abgrenzt: ein Label
/// signalisiert "Information", ein Pill-Button signalisiert "antippbar".
struct KeyChip: View {
    @Bindable var transport: TransportViewModel
    let hasLoadedTrack: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "music.note")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(displayKey)
                .font(.body.monospacedDigit().weight(.medium))
                .foregroundStyle(keyColor)
        }
        .opacity(hasLoadedTrack ? 1.0 : 0.55)
        .help("Key")
    }

    private var displayKey: String {
        transport.effectiveKey?.description ?? "—"
    }

    private var keyColor: Color {
        transport.effectiveKey?.color ?? Color.secondary
    }
}
