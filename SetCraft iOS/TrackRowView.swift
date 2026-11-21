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
/// Akzentlinie in `accent`, der Zeilenhintergrund `selection` — das
/// Icon wechselt zwischen Play/Pause je nach Wiedergabe-Zustand.
struct TrackRowView: View {
    let track: Track
    /// Track ist der gerade im Player geladene — unabhängig davon, ob
    /// gerade abgespielt oder pausiert wird. Steuert Hintergrund-Tint
    /// und den linken Akzentstreifen.
    let isCurrent: Bool
    /// Engine spielt aktuell ab. Steuert nur das Icon (play vs. pause).
    let isPlaying: Bool
    /// Track wird gerade auf das Gerät geholt — zwischen Tap und erstem
    /// Ton. Bei einer NAS-Quelle über VPN dauert das spürbar, deshalb ein
    /// Spinner an der Stelle des Play-Indikators.
    var isLoading: Bool = false
    let isAnalyzing: Bool
    /// Klingende Tonart bei gesetztem Master-Tempo. Reiner Anzeigewert —
    /// in die Datei geht immer `track.key`.
    var sounding: SoundingKey? = nil

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isCurrent ? Theme.Palette.accent : Color.clear)
                .frame(width: Theme.MetricsIOS.selectionEdge)

            HStack(spacing: 10) {
                playIndicator
                titleColumn
                Spacer(minLength: 8)
                metaColumn
            }
            .padding(.leading, 11)
            .padding(.trailing, Theme.MetricsIOS.padding)
            .padding(.vertical, 8)
        }
        .listRowBackground(
            isCurrent ? Theme.Palette.selection : Theme.Palette.background
        )
        .listRowSeparatorTint(Theme.Palette.rowDivider)
        .listRowInsets(EdgeInsets())
    }

    @ViewBuilder private var playIndicator: some View {
        ZStack {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.Palette.accent)
                    .accessibilityLabel("Loading track")
            } else if isCurrent {
                Image(systemName: isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.accent)
            }
        }
        .frame(width: 14)
    }

    @ViewBuilder private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.displayTitle)
                .font(Theme.TypoIOS.rowTitle)
                .foregroundStyle(isCurrent ? Theme.Palette.accent : Theme.Palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(track.artist.isEmpty ? "—" : track.artist)
                .font(Theme.TypoIOS.rowDetail)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 6) {
                StarStripView(stars: track.rating.stars)
                if track.playCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 9))
                        Text("\(track.playCount)")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                    }
                    .foregroundStyle(Theme.Palette.textMuted)
                }
            }
            .padding(.top, 1)
        }
    }

    @ViewBuilder private var metaColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if isAnalyzing {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.Palette.accent)
                    .frame(width: 14, height: 14)
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.Palette.accent)
                    .frame(width: 14, height: 14)
            } else {
                Text(formattedBPM)
                    .font(Theme.TypoIOS.rowNumeric)
                    .foregroundStyle(track.bpm == nil ? Theme.Palette.textMuted : Theme.Palette.text)
                if let sounding, sounding.isShifted {
                    HStack(spacing: 2) {
                        KeyBadgeView(key: sounding.original, dimmed: true)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.Palette.textMuted)
                        if sounding.isAmbiguous {
                            Text("~")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(Theme.Palette.keyAmbiguous)
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
                    .foregroundStyle(i <= stars ? Theme.Palette.star : Theme.Palette.starDim)
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
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle((key?.color ?? Theme.Palette.textMuted).opacity(dimmed ? 0.4 : 1.0))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
    }
}
