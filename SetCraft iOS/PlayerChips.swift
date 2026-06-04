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

