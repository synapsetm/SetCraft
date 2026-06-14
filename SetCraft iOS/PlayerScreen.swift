//
//  PlayerScreen.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import SwiftUI
import SetCraftCore

/// Player-Tab. Im Portrait ist das Layout vertikal aufgebaut: Waveform oben,
/// Track-Info darunter, Controls unten. Im iPhone-Landscape (verticalSizeClass
/// `.compact`) klappt das Layout horizontal: vertikale Waveform links, Track-
/// Info mittig, Controls rechts — passend zur DJ-Hand-am-Gerät-Erwartung.
struct PlayerScreen: View {
    let store: PlayerStore

    @State private var showTagEditSheet = false
    @State private var showTempoSheet = false
    @Environment(\.verticalSizeClass) private var vSizeClass

    var body: some View {
        Group {
            if vSizeClass == .compact {
                landscapeBody
            } else {
                portraitBody
            }
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

    @ViewBuilder
    private var portraitBody: some View {
        VStack(spacing: 0) {
            waveform
                .frame(height: 208)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                headerCard
                Spacer(minLength: 0)
                controlsCard
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
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.10, green: 0.10, blue: 0.13))
            .contentShape(Rectangle())
            .gesture(trackSwipeGesture)
        }
    }

    /// Landscape-Layout: vertikale Waveform links, Track-Header mittig,
    /// Steuerelemente rechts. Mini-Player + TabView bleiben unangetastet.
    @ViewBuilder
    private var landscapeBody: some View {
        HStack(spacing: 0) {
            verticalWaveform
                .frame(width: 140)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                headerCard
                Spacer(minLength: 0)
                if let error = store.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(trackSwipeGesture)

            VStack {
                Spacer(minLength: 0)
                controlsCard
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(width: 360)
            .contentShape(Rectangle())
            .gesture(trackSwipeGesture)
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
    }

    /// Horizontaler Swipe wechselt den Track: nach links → next, nach rechts
    /// → previous. Wird bewusst NUR auf den Track-Info-/Controls-Bereich gelegt
    /// und nicht auf die Waveform, damit das Scrubbing nicht hijacked wird.
    private var trackSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 40, coordinateSpace: .local)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                // Mehr horizontal als vertikal + ausreichend Distanz, sonst
                // schluckt der Swipe versehentlich Tap-In-Drag-Sequenzen.
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 60 else { return }
                if dx < 0 {
                    store.next()
                } else {
                    store.previous()
                }
            }
    }

    @ViewBuilder
    private var verticalWaveform: some View {
        WaveformCanvasView(
            data: store.currentWaveform,
            position: store.position,
            duration: store.duration,
            bpm: store.effectiveBPM,
            isLoading: store.isLoadingWaveform,
            onScrub: { store.seek(to: $0) },
            axis: .vertical
        )
    }

    @ViewBuilder
    private var headerCard: some View {
        VStack(spacing: 12) {
            ArtworkView(url: store.currentTrack?.url, size: 160, cornerRadius: 14)
            VStack(spacing: 3) {
                Text(displayTitle)
                    .font(.system(size: 17, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(displayArtist)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .playerCardStyle()
    }

    @ViewBuilder
    private var controlsCard: some View {
        VStack(spacing: 16) {
            transport
            HStack(spacing: 10) {
                BPMChipView(
                    bpm: store.effectiveBPM,
                    isAnalyzing: store.isAnalyzingCurrentTrack,
                    isEnabled: hasTrack
                ) {
                    showTempoSheet = true
                }
                KeyChipView(key: store.currentTrack?.key, isAnalyzing: store.isAnalyzingCurrentTrack)
                Spacer(minLength: 4)
                PlayerEditButton { showTagEditSheet = true }
                    .disabled(!hasTrack)
                    .opacity(hasTrack ? 1 : 0.4)
            }
            BigStarsView(value: store.currentTrack?.rating.stars ?? 0) { newValue in
                store.setRating(newValue)
            }
            .disabled(!hasTrack)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .playerCardStyle()
    }

    @ViewBuilder
    private var waveform: some View {
        WaveformCanvasView(
            data: store.currentWaveform,
            position: store.position,
            duration: store.duration,
            bpm: store.effectiveBPM,
            isLoading: store.isLoadingWaveform,
            onScrub: { store.seek(to: $0) }
        )
    }

    @ViewBuilder
    private var transport: some View {
        HStack(spacing: 36) {
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
        store.currentTrack?.displayTitle ?? String(localized: "No track loaded")
    }

    private var displayArtist: String {
        guard let track = store.currentTrack else { return "—" }
        return track.artist.isEmpty ? "—" : track.artist
    }
}

/// Vinyl-/Cover-Platzhalter im Mockup-Stil (lila Gradient). Wird gezeigt,
/// solange echte Artwork noch nicht geladen ist oder der Track keine hat.
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

private extension View {
    /// Karten-Hintergrund für die Portrait-Sektionen — dunkler Block mit
    /// dünnem hellem Border, abgerundete Ecken.
    func playerCardStyle() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(red: 0.13, green: 0.13, blue: 0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    )
            )
    }
}
