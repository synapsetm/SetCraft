import SwiftUI
import SetCraftCore

struct TempoChip: View {
    @Bindable var transport: TransportViewModel
    let hasLoadedTrack: Bool

    @State private var showPopover = false
    @State private var bpmText: String = ""
    @State private var isHovering = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            // B6-Readout im Now-Playing-Raster: Label oben, gespielte BPM gross
            // in Amber. Die ganze Zelle ist Klickfläche für das Popover —
            // erkennbar am Pfeil im Label und an der Amber-Fläche bei Hover
            // bzw. offenem Popover (anders als die reine Anzeige KEY).
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Text("BPM")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .themeLabel()
                    if transport.isGlobalBPM {
                        Text("global")
                            .font(Theme.Typo.label)
                            .tracking(Theme.Typo.labelTracking)
                            .textCase(.uppercase)
                            .padding(.horizontal, 4)
                            .background(Theme.Palette.selection,
                                        in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                            .foregroundStyle(Theme.Palette.accent)
                    }
                }
                Text(displayBPM)
                    .font(Theme.Typo.readout)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .foregroundStyle(hasLoadedTrack ? Theme.Palette.accent : Theme.Palette.textMuted)
            }
            .nowPlayingCell()
            .background(isHighlighted ? Theme.Palette.selection : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasLoadedTrack)
        .help("Adjust tempo")
        .onHover { hovering in
            if hovering && hasLoadedTrack {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
            isHovering = hovering
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            popover
                .padding(16)
                .frame(width: 260)
                .onAppear { bpmText = displayBPM }
        }
    }

    private var isHighlighted: Bool {
        hasLoadedTrack && (isHovering || showPopover)
    }

    private var displayBPM: String {
        guard let bpm = transport.effectiveBPM else { return "—" }
        return String(format: "%.1f", bpm)
    }

    // MARK: - Popover

    private var popover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Tempo").font(.headline)
                Spacer()
                Toggle("global", isOn: Binding(
                    get: { transport.isGlobalBPM },
                    set: { transport.setIsGlobalBPM($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                TextField("BPM", text: $bpmText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 80)
                    .onSubmit { commitBPMText() }
                Text("BPM").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") {
                    transport.setRate(1.0)
                    bpmText = displayBPM
                }
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Fine adjust")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(percentLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { transport.currentRate ?? 1.0 },
                        set: { transport.setRate($0); bpmText = displayBPM }
                    ),
                    in: (1.0 - TransportViewModel.tempoSpan)...(1.0 + TransportViewModel.tempoSpan),
                    step: 0.0005
                )
            }

            if let original = bpmOriginalLabel {
                Text(original)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var percentLabel: String {
        guard let rate = transport.currentRate else { return "0.0 %" }
        let pct = (rate - 1.0) * 100
        return String(format: "%+0.1f %%", pct)
    }

    private var bpmOriginalLabel: String? {
        // Über `effectiveBPM` lässt sich das Original nur indirekt zurückrechnen;
        // wir wissen es nicht ohne den PlayerViewModel. Für den Hinweis im Popover
        // lassen wir das vorerst weg — der ±%-Wert macht die Beziehung klar.
        nil
    }

    private func commitBPMText() {
        let trimmed = bpmText.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(trimmed), value > 0 else {
            bpmText = displayBPM
            return
        }
        transport.setBPM(value)
        bpmText = displayBPM
    }
}
