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
            ArtworkView(url: store.currentTrack?.url, size: 34, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(store.currentTrack?.displayTitle ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

            Spacer(minLength: 8)

            Button {
                store.togglePlayPause()
            } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.13, green: 0.13, blue: 0.15))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 0.5)
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
