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
                    .foregroundStyle(isOn ? Theme.Palette.accent : Theme.Palette.textMuted)

                Text("Master BPM")
                    .themeLabel()

                Text(isOn ? String(format: "%.1f", masterBPM ?? 0) : "—")
                    .font(Theme.TypoIOS.bodyNumeric.weight(.semibold))
                    .foregroundStyle(isOn ? Theme.Palette.accent : Theme.Palette.textMuted)
                    .frame(minWidth: 52, alignment: .leading)

                Spacer()

                Button(isOn ? "Off" : "On") {
                    masterBPM = isOn ? nil : Self.defaultBPM
                }
                .buttonStyle(ThemeButtonStyle(width: 64, height: Self.controlHeight,
                                              kind: isOn ? .standard : .accentOutline))
            }

            if isOn {
                HStack(spacing: 10) {
                    Button {
                        adjust(by: -0.5)
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(ThemeButtonStyle(width: Self.controlHeight, height: Self.controlHeight))

                    Slider(
                        value: Binding(
                            get: { masterBPM ?? Self.defaultBPM },
                            set: { masterBPM = $0 }
                        ),
                        in: Self.range,
                        step: 0.5
                    )
                    .tint(Theme.Palette.accent)

                    Button {
                        adjust(by: 0.5)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(ThemeButtonStyle(width: Self.controlHeight, height: Self.controlHeight))
                }

                Text("Every track opens at this tempo — keys shift with it.")
                    .font(Theme.TypoIOS.rowDetail)
                    .foregroundStyle(Theme.Palette.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Theme.MetricsIOS.padding)
        .padding(.vertical, 6)
        .background(Theme.Palette.background)
    }

    /// Touch-Ziel nach I1-Spec: mindestens 44 pt.
    private static let controlHeight: CGFloat = Theme.MetricsIOS.minTouch

    private func adjust(by delta: Double) {
        let current = masterBPM ?? Self.defaultBPM
        masterBPM = min(Self.range.upperBound,
                        max(Self.range.lowerBound, current + delta))
    }
}
