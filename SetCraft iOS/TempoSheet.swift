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
    /// Originaler Key aus dem Tag — für die Vorschau der klingenden Tonart.
    let originalKey: CamelotKey?
    /// Aktuelles Master-Tempo, `nil` = aus. Änderungen am Tempo schreiben
    /// hier mit, solange das Master aktiv ist.
    let masterBPM: Double?
    /// Master ein-/ausschalten. Beim Einschalten wird das gerade eingestellte
    /// Tempo zum Master für alle folgenden Tracks.
    let onMasterToggle: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rate: Double
    @State private var bpmText: String

    init(
        originalBPM: Double?,
        initialRate: Double,
        originalKey: CamelotKey? = nil,
        masterBPM: Double? = nil,
        onMasterToggle: @escaping (Bool) -> Void = { _ in },
        onRateChange: @escaping (Double) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.originalBPM = originalBPM
        self.initialRate = initialRate
        self.originalKey = originalKey
        self.masterBPM = masterBPM
        self.onMasterToggle = onMasterToggle
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
                        Slider(value: $rate, in: sliderRange, step: 0.001)
                            .onChange(of: rate) { _, newRate in
                                onRateChange(newRate)
                                syncBPMText()
                            }
                    }
                }

                Section {
                    Toggle("Master tempo", isOn: Binding(
                        get: { masterBPM != nil },
                        set: { onMasterToggle($0) }
                    ))
                    if let masterBPM {
                        LabeledContent("Master BPM") {
                            Text(String(format: "%.1f", masterBPM))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    Text(masterBPM == nil
                         ? "Tempo changes apply to this track only."
                         : "Tempo changes also set the master — every track opens at this tempo.")
                }

                if let shifted = soundingPreview {
                    Section {
                        Text(shiftedFooter(for: shifted))
                            .font(.footnote)
                            .foregroundStyle(shifted.isAmbiguous
                                             ? Color(red: 1.0, green: 0.624, blue: 0.271)
                                             : Color.secondary)
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

    /// Normalerweise ±8 % um das Original. Zieht das Master-Tempo den Track
    /// weiter, wandert das Fenster mit — sonst stünde der Regler am Anschlag
    /// und die Feinjustage wäre unbrauchbar. 1.0 bleibt immer erreichbar.
    private var sliderRange: ClosedRange<Double> {
        let span = PlayerStore.tempoSpan
        return min(1.0 - span, rate - span)...max(1.0 + span, rate + span)
    }

    /// Klingende Tonart bei der gerade eingestellten Rate — Vorschau im
    /// Footer, damit der Effekt des Schalters sofort sichtbar ist.
    private var soundingPreview: SoundingKey? {
        guard let originalKey, rate != 1.0 else { return nil }
        return SoundingKey(original: originalKey, rate: rate)
    }

    private func shiftedFooter(for shifted: SoundingKey) -> String {
        let semitones = String(format: "%+.2f", shifted.exactSemitones)
        if shifted.isAmbiguous {
            return String(localized: "Sounds \(semitones) semitones off — between two keys: \(shifted.original.description) → ~\(shifted.sounding.description). The file keeps \(shifted.original.description).")
        }
        return String(localized: "Sounds \(semitones) semitones off: \(shifted.original.description) → \(shifted.sounding.description). The file keeps \(shifted.original.description).")
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
        // Auf die Engine-Grenzen klemmen, nicht auf ±8 %: über dieses Feld
        // wird auch das Set-Tempo gesetzt, das beliebig weit vom Original des
        // gerade laufenden Tracks entfernt liegen kann. Der ±8-%-Regler
        // bleibt die Feinjustage darum herum.
        let target = max(PlayerStore.engineRateMin,
                         min(PlayerStore.engineRateMax, value / original))
        rate = target
        onRateChange(target)
        syncBPMText()
    }
}
