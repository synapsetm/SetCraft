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
/// Badge rechts. Bei aktivem Player blinkt links eine orange Akzentlinie
/// auf, der Zeilenhintergrund wird leicht warm.
struct TrackRowView: View {
    let track: Track
    let isPlaying: Bool
    let isAnalyzing: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Orange Akzentstreifen links bei aktivem Track
            Rectangle()
                .fill(isPlaying ? Color.orange : Color.clear)
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
            isPlaying ? Color.orange.opacity(0.10) : Color.clear
        )
        .listRowInsets(EdgeInsets())
    }

    @ViewBuilder private var playIndicator: some View {
        ZStack {
            if isPlaying {
                Image(systemName: "play.fill")
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
            StarStripView(stars: track.rating.stars)
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
                KeyBadgeView(key: track.key)
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

    var body: some View {
        Text(key?.description ?? "—")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(key?.color ?? .secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
    }
}
