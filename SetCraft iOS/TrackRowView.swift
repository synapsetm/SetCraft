//
//  TrackRowView.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import SwiftUI
import SetCraftCore

/// Eine Zeile in der Library-Liste, eng am Mockup `docs/library.html`:
/// Play-Indikator links, Titel + Artist + Sterne mittig, BPM + Camelot-
/// Badge rechts. Bei aktivem Track (geladen im Player) zeigt links eine
/// orange Akzentlinie, der Zeilenhintergrund wird leicht warm — das
/// Icon wechselt zwischen Play/Pause je nach Wiedergabe-Zustand.
struct TrackRowView: View {
    let track: Track
    /// Track ist der gerade im Player geladene — unabhängig davon, ob
    /// gerade abgespielt oder pausiert wird. Steuert Hintergrund-Tint
    /// und den linken Akzentstreifen.
    let isCurrent: Bool
    /// Engine spielt aktuell ab. Steuert nur das Icon (play vs. pause).
    let isPlaying: Bool
    let isAnalyzing: Bool
    /// Klingende Tonart bei gesetztem Master-Tempo. Reiner Anzeigewert —
    /// in die Datei geht immer `track.key`.
    var sounding: SoundingKey? = nil

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isCurrent ? Color.orange : Color.clear)
                .frame(width: 3)

            HStack(spacing: 10) {
                playIndicator
                titleColumn
                Spacer(minLength: 8)
                metaColumn
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .listRowBackground(
            isCurrent ? Color.orange.opacity(0.10) : Color.clear
        )
        .listRowInsets(EdgeInsets())
    }

    @ViewBuilder private var playIndicator: some View {
        ZStack {
            if isCurrent {
                Image(systemName: isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 14)
    }

    @ViewBuilder private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(track.displayTitle)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(track.artist.isEmpty ? "—" : track.artist)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 6) {
                StarStripView(stars: track.rating.stars)
                if track.playCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 9))
                        Text("\(track.playCount)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder private var metaColumn: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if isAnalyzing {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
            } else {
                Text(formattedBPM)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                if let sounding, sounding.isShifted {
                    HStack(spacing: 2) {
                        KeyBadgeView(key: sounding.original, dimmed: true)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        if sounding.isAmbiguous {
                            Text("~")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(red: 1.0, green: 0.624, blue: 0.271))
                        }
                        KeyBadgeView(key: sounding.sounding)
                    }
                } else {
                    KeyBadgeView(key: track.key)
                }
            }
        }
    }

    private var formattedBPM: String {
        guard let bpm = track.bpm else { return "—" }
        return String(format: "%.1f", bpm)
    }
}

struct StarStripView: View {
    let stars: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= stars ? "star.fill" : "star")
                    .font(.system(size: 9))
                    .foregroundStyle(i <= stars ? Color.yellow : Color.secondary.opacity(0.4))
            }
        }
    }
}

struct KeyBadgeView: View {
    let key: CamelotKey?
    /// Ausgegraut für den Original-Key, wenn daneben der klingende steht.
    var dimmed: Bool = false

    var body: some View {
        Text(key?.description ?? "—")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle((key?.color ?? .secondary).opacity(dimmed ? 0.4 : 1.0))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
    }
}
