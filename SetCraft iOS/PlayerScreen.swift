//
//  PlayerScreen.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import SwiftUI
import SetCraftCore

/// Player-Tab gemäß `docs/player.html`. In dieser e1-Phase: Track-Header
/// mit Cover-Platzhalter, Transport (Prev/Play-Pause/Next), Zeit-Anzeige.
/// Waveform-Canvas folgt in e2, BPM/Key/Sterne-Chips in e3.
struct PlayerScreen: View {
    let store: PlayerStore

    @State private var showTagEditSheet = false
    @State private var showTempoSheet = false

    var body: some View {
        VStack(spacing: 0) {
            WaveformCanvasView(
                data: store.currentWaveform,
                position: store.position,
                duration: store.duration,
                bpm: store.effectiveBPM,
                isLoading: store.isLoadingWaveform,
                onScrub: { store.seek(to: $0) }
            )
            controlPanel
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
        .sheet(isPresented: $showTagEditSheet) {
            if let track = store.currentTrack {
                TagEditSheet(track: track) { updated in
                    store.applyEdit(updated)
                }
            }
        }
        .sheet(isPresented: $showTempoSheet) {
            TempoSheet(
                originalBPM: store.currentTrack?.bpm,
                initialRate: store.currentRate,
                onRateChange: { store.setRate($0) },
                onReset: { store.resetTempo() }
            )
        }
    }

    @ViewBuilder private var controlPanel: some View {
        VStack {
            Spacer(minLength: 0)
            trackHeader
            Spacer(minLength: 0)
            transport
            Spacer(minLength: 0)
            chipsRow
            Spacer(minLength: 0)
            starsRow
            Spacer(minLength: 0)
            if let error = store.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
    }

    @ViewBuilder private var trackHeader: some View {
        VStack(spacing: 12) {
            ArtworkView(url: store.currentTrack?.url, size: 140, cornerRadius: 14)

            VStack(spacing: 2) {
                Text(displayTitle)
                    .font(.system(size: 17, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(displayArtist)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var chipsRow: some View {
        if hasTrack {
            HStack(spacing: 12) {
                BPMChipView(bpm: store.effectiveBPM) {
                    showTempoSheet = true
                }
                KeyChipView(key: store.currentTrack?.key)
                PlayerEditButton { showTagEditSheet = true }
            }
        }
    }

    @ViewBuilder private var starsRow: some View {
        if hasTrack {
            BigStarsView(value: store.currentTrack?.rating.stars ?? 0) { newValue in
                store.setRating(newValue)
            }
        }
    }

    @ViewBuilder private var transport: some View {
        HStack(spacing: 38) {
            Button {
                store.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(transportTint)
            }
            .disabled(!hasTrack)

            Button {
                store.togglePlayPause()
            } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color(red: 0.08, green: 0.08, blue: 0.10))
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(.orange))
            }
            .disabled(!hasTrack)

            Button {
                store.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(transportTint)
            }
            .disabled(!hasTrack)
        }
        .buttonStyle(.plain)
    }

    private var hasTrack: Bool { store.currentTrack != nil }

    private var transportTint: Color {
        hasTrack ? .primary : .secondary
    }

    private var displayTitle: String {
        store.currentTrack?.displayTitle ?? "Kein Track geladen"
    }

    private var displayArtist: String {
        guard let track = store.currentTrack else { return "—" }
        return track.artist.isEmpty ? "—" : track.artist
    }

    private var timeLine: String {
        let elapsed = formatTime(store.position)
        let remaining = formatTime(max(0, store.duration - store.position))
        return "\(elapsed) / -\(remaining)"
    }

    private func formatTime(_ s: TimeInterval) -> String {
        let total = max(0, Int(s.rounded()))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

/// Vinyl-/Cover-Platzhalter im Mockup-Stil (lila Gradient).
/// Wird in e3 durch echtes Artwork ersetzt.
struct CoverPlaceholderView: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    let iconSize: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(LinearGradient(
                colors: [
                    Color(red: 0.23, green: 0.13, blue: 0.32),
                    Color(red: 0.35, green: 0.20, blue: 0.48)
                ],
                startPoint: .top,
                endPoint: .bottom
            ))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "music.note")
                    .foregroundStyle(.white.opacity(0.72))
                    .font(.system(size: iconSize))
            )
    }
}
