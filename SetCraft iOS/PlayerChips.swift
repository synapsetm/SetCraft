//
//  PlayerChips.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import SwiftUI
import SetCraftCore

/// BPM-Chip im Mockup-Stil (`docs/player.html`): Metronom-Icon orange,
/// Wert in Mono-Font, kleines "BPM"-Label, Chevron rechts → tappbar fürs
/// Edit-Sheet. Wenn kein BPM gesetzt ist, zeigt der Chip "—".
struct BPMChipView: View {
    let bpm: Double?
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "metronome")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
            Text(formattedBPM)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
            Text("BPM")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.down")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(red: 0.13, green: 0.13, blue: 0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(perform: onTap)
    }

    private var formattedBPM: String {
        guard let bpm else { return "—" }
        return String(format: "%.1f", bpm)
    }
}

/// Key-Chip read-only — Mac hat hier die Camelot-Wheel-Editierung,
/// auf iOS aktuell bewusst weggelassen (Mockup zeigt den Chip auch ohne
/// Edit-Hinweis). Farbe kommt aus `CamelotKey.color` (Core-Extension).
struct KeyChipView: View {
    let key: CamelotKey?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
                .font(.system(size: 15))
            Text(key?.description ?? "—")
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundStyle(key?.color ?? .secondary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(red: 0.13, green: 0.13, blue: 0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
    }
}

/// Fünf große, antippbare Sterne im Mockup-Stil. Tap auf einen bereits
/// gesetzten Stern setzt das Rating auf 0 zurück (Toggle-Off), damit der
/// Nutzer ohne extra UI ein Rating wieder entfernen kann.
struct BigStarsView: View {
    let value: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(1...5, id: \.self) { i in
                Button {
                    onChange(i == value ? 0 : i)
                } label: {
                    Image(systemName: i <= value ? "star.fill" : "star")
                        .font(.system(size: 32))
                        .foregroundStyle(i <= value ? Color.yellow : Color.secondary.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// BPM-Edit-Sheet. Direkte Eingabe via Decimal-Keyboard plus vier Schnell-
/// Skalierungs-Buttons (×2, ÷2, ×1.5, ÷1.5 — der Triolen-Fix aus den
/// Mac-Library-Kontextmenüs). Done committed, Cancel verwirft.
struct BPMEditSheet: View {
    let initialValue: Double?
    let onCommit: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var textValue: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Text("BPM")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    TextField("BPM", text: $textValue)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 36, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                }

                HStack(spacing: 10) {
                    scaleButton(label: "÷2",   factor: 0.5)
                    scaleButton(label: "÷1.5", factor: 1.0 / 1.5)
                    scaleButton(label: "×1.5", factor: 1.5)
                    scaleButton(label: "×2",   factor: 2.0)
                }

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("BPM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commit() }
                        .disabled(parsedValue == nil)
                }
            }
            .onAppear {
                if let v = initialValue {
                    textValue = String(format: "%.1f", v)
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func scaleButton(label: String, factor: Double) -> some View {
        Button(label) {
            guard let current = parsedValue else { return }
            let scaled = (current * factor * 10).rounded() / 10
            textValue = String(format: "%.1f", scaled)
        }
        .buttonStyle(.bordered)
        .font(.system(size: 14, weight: .medium, design: .monospaced))
    }

    private var parsedValue: Double? {
        Double(textValue.replacingOccurrences(of: ",", with: "."))
    }

    private func commit() {
        guard let v = parsedValue else { return }
        onCommit(v)
        dismiss()
    }
}
