//
//  PlayerChips.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import SwiftUI
import SetCraftCore

/// BPM-Kachel — zeigt das **effektive** BPM (Original × Rate) in `accent`.
/// Antippen öffnet das Tempo-Sheet; das Chevron neben dem Label zeigt an,
/// dass die Kachel interaktiv ist.
struct BPMChipView: View {
    let bpm: Double?
    let isAnalyzing: Bool
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("BPM")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .themeLabel()
                if isAnalyzing {
                    ProgressView()
                        .tint(Theme.Palette.accent)
                        .frame(height: 36)
                } else {
                    Text(formattedBPM)
                        .font(Theme.TypoIOS.readout)
                        .foregroundStyle(bpm == nil ? Theme.Palette.textMuted : Theme.Palette.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .padding(.horizontal, Theme.MetricsIOS.padding)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var formattedBPM: String {
        guard let bpm else { return "—" }
        return String(format: "%.1f", bpm)
    }
}

/// KEY-Kachel — gespielter Key in Camelot-Farbe. Nicht interaktiv; der Key
/// wird im `TagEditSheet` gesetzt (Player-Kopfzeile → ••• → Edit).
struct KeyChipView: View {
    let key: CamelotKey?
    let isAnalyzing: Bool
    /// Bei ausgeschaltetem Key-Lock die tatsächlich klingende Tonart —
    /// dann zeigt die Kachel `8A → 9A`. Reiner Anzeigewert.
    var sounding: SoundingKey? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Key")
                .themeLabel()
            if isAnalyzing {
                ProgressView()
                    .tint(Theme.Palette.accent)
                    .frame(height: 36)
            } else if let sounding, sounding.isShifted {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(sounding.original.description)
                        .font(.system(size: 18, weight: .semibold).monospacedDigit())
                        .foregroundStyle(sounding.original.color.opacity(0.4))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textMuted)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        if sounding.isAmbiguous {
                            Text(verbatim: "~")
                                .foregroundStyle(Theme.Palette.keyAmbiguous)
                        }
                        Text(sounding.sounding.description)
                            .foregroundStyle(sounding.sounding.color)
                    }
                    .font(Theme.TypoIOS.readout)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            } else {
                Text(key?.description ?? "—")
                    .font(Theme.TypoIOS.readout)
                    .foregroundStyle(key?.color ?? Theme.Palette.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .padding(.horizontal, Theme.MetricsIOS.padding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Fünf große, antippbare Sterne. Tap auf einen bereits gesetzten Stern
/// setzt das Rating auf 0 zurück (Toggle-Off), damit der Nutzer ohne extra
/// UI ein Rating wieder entfernen kann.
struct BigStarsView: View {
    let value: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { i in
                Button {
                    onChange(i == value ? 0 : i)
                } label: {
                    Image(systemName: i <= value ? "star.fill" : "star")
                        .font(.system(size: Theme.MetricsIOS.bigStar))
                        .foregroundStyle(i <= value ? Theme.Palette.star : Theme.Palette.starDim)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
