import SwiftUI
import SetCraftCore

/// Master-Tempo direkt über der Bibliotheksliste: einmal gesetzt, wird jeder
/// geöffnete Track auf diese Geschwindigkeit gezogen — und die Liste zeigt die
/// Tonarten, die dann tatsächlich klingen.
///
/// Pendant zum Tempo-Chip der Mac-App, hier aber bewusst in der Listenansicht,
/// weil das Set-Tempo beim Sichten der Bibliothek gebraucht wird und nicht
/// erst im Player.
struct MasterTempoBar: View {
    @Binding var masterBPM: Double?

    /// Bereich, in dem sich ein Set-Tempo sinnvoll bewegt — deckt House bis
    /// DnB ab, ohne dass der Slider unbrauchbar fein wird.
    private static let range: ClosedRange<Double> = 60...200

    /// Wert für den Slider, solange kein Master gesetzt ist.
    private static let defaultBPM: Double = 128

    private var isOn: Bool { masterBPM != nil }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "metronome")
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? .orange : .secondary)

                Text(isOn ? String(format: "%.1f", masterBPM ?? 0) : "—")
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .frame(minWidth: 52, alignment: .leading)

                Text("Master BPM")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(isOn ? "Off" : "On") {
                    masterBPM = isOn ? nil : Self.defaultBPM
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isOn {
                HStack(spacing: 10) {
                    Button {
                        adjust(by: -0.5)
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Slider(
                        value: Binding(
                            get: { masterBPM ?? Self.defaultBPM },
                            set: { masterBPM = $0 }
                        ),
                        in: Self.range,
                        step: 0.5
                    )
                    .tint(.orange)

                    Button {
                        adjust(by: 0.5)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Text("Every track opens at this tempo — keys shift with it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func adjust(by delta: Double) {
        let current = masterBPM ?? Self.defaultBPM
        masterBPM = min(Self.range.upperBound,
                        max(Self.range.lowerBound, current + delta))
    }
}
