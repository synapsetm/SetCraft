//
//  MiniPlayerView.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import SwiftUI
import SetCraftCore

/// Persistente Mini-Player-Leiste über der Tab-Bar (Mockup `docs/library.html`).
/// Tippen auf den Inhalt schaltet auf den Player-Tab; der Play-Button rechts
/// togglet Play/Pause inline.
struct MiniPlayerView: View {
    let store: PlayerStore
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(url: store.currentTrack?.url,
                        size: Theme.MetricsIOS.miniCoverSize,
                        cornerRadius: Theme.MetricsIOS.coverRadius)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.currentTrack?.displayTitle ?? "")
                    .font(Theme.TypoIOS.body.weight(.medium))
                    .foregroundStyle(Theme.Palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(Theme.TypoIOS.rowDetail.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

            Button {
                store.togglePlayPause()
            } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(ThemeButtonStyle(width: Theme.MetricsIOS.minTouch,
                                          height: Theme.MetricsIOS.minTouch,
                                          kind: .prominent))
        }
        .padding(.leading, Theme.MetricsIOS.padding)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(Theme.Palette.surface)
        .overlay(alignment: .top) {
            Theme.Palette.border.frame(height: 1)
        }
    }

    private var subtitle: String {
        guard let track = store.currentTrack else { return "" }
        var parts: [String] = []
        if !track.artist.isEmpty { parts.append(track.artist) }
        if let bpm = track.bpm { parts.append(String(format: "%.1f", bpm)) }
        if let key = track.key { parts.append(key.description) }
        return parts.joined(separator: " · ")
    }
}
