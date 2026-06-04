//
//  PlayerChips.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import SwiftUI
import SetCraftCore

/// BPM-Chip read-only ohne Hintergrund/Border — Player-Edit läuft jetzt
/// über den separaten `PlayerEditButton` rechts neben dem Key-Chip.
struct BPMChipView: View {
    let bpm: Double?

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
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

    private var formattedBPM: String {
        guard let bpm else { return "—" }
        return String(format: "%.1f", bpm)
    }
}

/// Edit-Button im Chip-Look — eigene Tap-Affordance neben den read-only
/// BPM- und Key-Chips. Öffnet das `TagEditSheet`.
struct PlayerEditButton: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "pencil")
                    .foregroundStyle(.orange)
                    .font(.system(size: 14))
                Text("Edit")
                    .font(.system(size: 14, weight: .medium))
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
        .buttonStyle(.plain)
    }
}

/// Key-Chip — auf iOS bewusst OHNE Umrandung, weil im Player-Window selbst
/// nicht editierbar (das Edit fließt über den BPM-Chip → `TagEditSheet`,
/// dort wird der Key trotzdem gesetzt). Damit hat der Chip rein
/// informationellen Charakter.
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

