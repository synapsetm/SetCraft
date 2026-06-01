import SwiftUI
import SetifyCore

struct TempoChip: View {
    @Bindable var transport: TransportViewModel
    let hasLoadedTrack: Bool

    @State private var showPopover = false
    @State private var bpmText: String = ""

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "metronome")
                    .imageScale(.small)
                Text(displayBPM)
                    .font(.body.monospacedDigit().weight(.medium))
                Text("BPM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if transport.isGlobalBPM {
                    Text("global")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.25), in: Capsule())
                        .foregroundStyle(.orange)
                }
                // Chevron als sichtbarer Hinweis: hier öffnet sich ein Popover.
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
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
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            popover
                .padding(16)
                .frame(width: 260)
                .onAppear { bpmText = displayBPM }
        }
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
