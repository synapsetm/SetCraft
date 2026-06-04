//
//  TempoSheet.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import SwiftUI
import SetCraftCore

/// Tempo-Anpassung für den aktuell geladenen Track (Pendant zum
/// `TempoChip`-Popover der Mac-App). Slider für ±8 %, direkte BPM-
/// Eingabe und Reset auf 1.0. Live-Preview — jede Änderung schickt
/// die neue Rate sofort an den `PlayerStore`. Kein Master/Global —
/// auf iOS ist iOS-Side immer Per-Track.
struct TempoSheet: View {
    /// Original-BPM aus dem Tag (`currentTrack.bpm`). `nil` → keine
    /// Ziel-BPM-Berechnung möglich, der Slider funktioniert trotzdem.
    let originalBPM: Double?
    let initialRate: Double
    let onRateChange: (Double) -> Void
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rate: Double
    @State private var bpmText: String

    init(
        originalBPM: Double?,
        initialRate: Double,
        onRateChange: @escaping (Double) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.originalBPM = originalBPM
        self.initialRate = initialRate
        self.onRateChange = onRateChange
        self.onReset = onReset
        _rate = State(initialValue: initialRate)
        if let original = originalBPM {
            _bpmText = State(initialValue: String(format: "%.1f", original * initialRate))
        } else {
            _bpmText = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Target BPM")
                        Spacer()
                        TextField("—", text: $bpmText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit { commitBPMText() }
                            .disabled(originalBPM == nil)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Fine adjust ±8 %")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(percentLabel)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $rate,
                            in: (1.0 - PlayerStore.tempoSpan)...(1.0 + PlayerStore.tempoSpan),
                            step: 0.001
                        )
                        .onChange(of: rate) { _, newRate in
                            onRateChange(newRate)
                            syncBPMText()
                        }
                    }
                }

                Section {
                    Button("Reset to 100 %") {
                        rate = 1.0
                        onReset()
                        syncBPMText()
                    }
                }

                if let original = originalBPM {
                    Section {
                        LabeledContent("Original BPM") {
                            Text(String(format: "%.1f", original))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Tempo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commitBPMText()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var percentLabel: String {
        let pct = (rate - 1.0) * 100
        return String(format: "%+0.1f %%", pct)
    }

    private func syncBPMText() {
        guard let original = originalBPM else { return }
        bpmText = String(format: "%.1f", original * rate)
    }

    private func commitBPMText() {
        let trimmed = bpmText.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(trimmed), value > 0,
              let original = originalBPM, original > 0
        else {
            syncBPMText()
            return
        }
        let target = max(1.0 - PlayerStore.tempoSpan, min(1.0 + PlayerStore.tempoSpan, value / original))
        rate = target
        onRateChange(target)
        syncBPMText()
    }
}
