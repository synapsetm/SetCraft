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
    @State private var showInfoSheet = false
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
        .background(Theme.Palette.background)
        .sheet(isPresented: $showTagEditSheet) {
            if let track = store.currentTrack {
                TagEditSheet(track: track) { updated in
                    store.applyEdit(updated)
                }
            }
        }
        .sheet(isPresented: $showInfoSheet) {
            if let track = store.currentTrack {
                TrackInfoSheet(track: track)
            }
        }
        .sheet(isPresented: $showTempoSheet) {
            TempoSheet(
                originalBPM: store.currentTrack?.bpm,
                initialRate: store.currentRate,
                originalKey: store.currentTrack?.key,
                masterBPM: store.masterBPM,
                onMasterToggle: { store.setMasterEnabled($0) },
                onRateChange: { store.setRate($0) },
                onReset: { store.resetTempo() }
            )
        }
    }

    /// Hochformat nach I1-Spec: Kopfzeile, Waveform, BPM/KEY-Kacheln,
    /// Transport, Sterne. Track-Swipe liegt auf allem ausser der Waveform.
    @ViewBuilder
    private var portraitBody: some View {
        VStack(spacing: 0) {
            header
                .contentShape(Rectangle())
                .gesture(trackSwipeGesture)

            Theme.Palette.border.frame(height: 1)
            waveform
                .frame(height: Theme.MetricsIOS.waveformHeight)
            Theme.Palette.border.frame(height: 1)

            VStack(spacing: 0) {
                tiles
                Theme.Palette.border.frame(height: 1)
                Spacer(minLength: 12)
                transport
                Spacer(minLength: 12)
                stars
                errorLine
                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(trackSwipeGesture)
        }
    }

    /// Landscape-Layout: vertikale Waveform links, Track-Header mittig,
    /// Steuerelemente rechts. Mini-Player + TabView bleiben unangetastet.
    /// Feinschliff nach I1-Spec folgt in Schritt 7.
    @ViewBuilder
    private var landscapeBody: some View {
        HStack(spacing: 0) {
            verticalWaveform
                .frame(width: 140)
            Theme.Palette.border.frame(width: 1)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                header
                Spacer(minLength: 0)
                errorLine
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(trackSwipeGesture)

            Theme.Palette.border.frame(width: 1)
            VStack(spacing: 16) {
                Spacer(minLength: 0)
                tiles
                transport
                stars
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(width: 360)
            .contentShape(Rectangle())
            .gesture(trackSwipeGesture)
        }
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
        WaveformTicker(store: store) { position in
            WaveformCanvasView(
                data: store.currentWaveform,
                position: position,
                duration: store.duration,
                bpm: store.effectiveBPM,
                isLoading: store.isLoadingWaveform && store.currentWaveform == nil,
                onScrub: { store.seek(to: $0) },
                axis: .vertical,
                isLoadingTrack: store.loadingURL != nil,
                loadProgress: store.loadProgress
            )
        }
    }

    /// Kopfzeile: Cover, Label TRACK, Titel, Artist; rechts Edit/Info.
    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            ArtworkView(url: store.currentTrack?.url,
                        size: Theme.MetricsIOS.coverSize,
                        cornerRadius: Theme.MetricsIOS.coverRadius)
            VStack(alignment: .leading, spacing: 2) {
                Text("Track")
                    .themeLabel()
                Text(displayTitle)
                    .font(Theme.TypoIOS.title)
                    .foregroundStyle(Theme.Palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(displayArtist)
                    .font(Theme.TypoIOS.artist)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    showTagEditSheet = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button {
                    showInfoSheet = true
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.text)
                    .frame(width: Theme.MetricsIOS.minTouch, height: Theme.MetricsIOS.minTouch)
                    .contentShape(Rectangle())
            }
            .disabled(!hasTrack)
            .opacity(hasTrack ? 1 : 0.4)
        }
        .padding(.leading, Theme.MetricsIOS.padding)
        .padding(.trailing, 4)
        .padding(.vertical, 10)
    }

    /// BPM- und KEY-Kachel nebeneinander, Trennlinie dazwischen.
    @ViewBuilder
    private var tiles: some View {
        HStack(spacing: 0) {
            BPMChipView(
                bpm: store.effectiveBPM,
                isAnalyzing: store.isAnalyzingCurrentTrack,
                isEnabled: hasTrack
            ) {
                showTempoSheet = true
            }
            Theme.Palette.border.frame(width: 1)
            KeyChipView(key: store.currentTrack?.key,
                        isAnalyzing: store.isAnalyzingCurrentTrack,
                        sounding: store.soundingKey)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var waveform: some View {
        WaveformTicker(store: store) { position in
            WaveformCanvasView(
                data: store.currentWaveform,
                position: position,
                duration: store.duration,
                bpm: store.effectiveBPM,
                isLoading: store.isLoadingWaveform && store.currentWaveform == nil,
                onScrub: { store.seek(to: $0) },
                isLoadingTrack: store.loadingURL != nil,
                loadProgress: store.loadProgress
            )
        }
    }

    /// Prev / Next als Quadrate mit Rahmen, Play/Pause als breiter Amber-Block.
    @ViewBuilder
    private var transport: some View {
        HStack(spacing: 10) {
            Button {
                store.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(ThemeButtonStyle(width: Theme.MetricsIOS.transportSide,
                                          height: Theme.MetricsIOS.transportHeight))

            Button {
                store.togglePlayPause()
            } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(ThemeButtonStyle(width: Theme.MetricsIOS.transportMain,
                                          height: Theme.MetricsIOS.transportHeight,
                                          kind: .prominent))

            Button {
                store.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(ThemeButtonStyle(width: Theme.MetricsIOS.transportSide,
                                          height: Theme.MetricsIOS.transportHeight))
        }
        .disabled(!hasTrack)
    }

    @ViewBuilder
    private var stars: some View {
        BigStarsView(value: store.currentTrack?.rating.stars ?? 0) { newValue in
            store.setRating(newValue)
        }
        .disabled(!hasTrack)
        .opacity(hasTrack ? 1 : 0.4)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error = store.lastError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(Theme.Palette.issueText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.top, 8)
        }
    }

    private var hasTrack: Bool { store.currentTrack != nil }

    private var displayTitle: String {
        store.currentTrack?.displayTitle ?? String(localized: "No track loaded")
    }

    private var displayArtist: String {
        guard let track = store.currentTrack else { return "—" }
        return track.artist.isEmpty ? "—" : track.artist
    }
}

/// Hält die Wellenfläche am Laufen — mit **zwei** Taktgebern, und der zweite
/// ist der Grund, warum es diese View gibt.
///
/// 1. Der 60-Hz-`TimelineView`-Fahrplan zeichnet flüssig; nur er liest
///    `livePosition` frisch aus `lastRenderTime`.
/// 2. Die 30-Hz-`position` aus der Engine wird hier bewusst *gelesen*, ohne
///    sie zu benutzen. Damit hängt die Fläche zusätzlich an der Observation
///    und zeichnet auch dann weiter, wenn der Fahrplan stehen bleibt.
///
/// Genau das passierte nach einem Ausflug in den Hintergrund: der Fahrplan
/// nahm nicht wieder auf, die Welle blieb auf dem letzten Bild davor stehen —
/// beim Auto-Advance also am Ende des *vorigen* Tracks, inklusive Zeitanzeige
/// und Fortschrittsbalken —, während Titel, BPM und Key (die an der
/// Observation hängen) längst den neuen Track zeigten und der Ton weiterlief.
///
/// Ein neuer Startzeitpunkt allein reichte nicht: er ändert zwar den Fahrplan,
/// die `TimelineView` behält aber ihre Identität — und mit ihr den
/// stehengebliebenen Takt. Deshalb hängt `epoch` zusätzlich an `.id()`: ein
/// Wechsel baut die Fläche neu auf, samt frischem Fahrplan. Ausgelöst wird er
/// an den beiden Stellen, an denen der Stillstand aufgefallen ist — Rückkehr
/// in den Vordergrund und **Track-Wechsel**, denn genau beim Auto-Advance aus
/// dem Hintergrund blieb die Welle am Ende des vorigen Tracks stehen.
///
/// Der Neuaufbau kostet nichts: der Zoom liegt in `@AppStorage`, der Rest des
/// View-Zustands ist ohnehin flüchtig (Drag, Zoom-HUD).
private struct WaveformTicker<Content: View>: View {
    let store: PlayerStore
    @ViewBuilder let content: (TimeInterval) -> Content

    @Environment(\.scenePhase) private var scenePhase
    @State private var epoch = Date.now

    var body: some View {
        let _ = store.position
        TimelineView(.periodic(from: epoch, by: 1.0 / 60.0)) { _ in
            content(store.livePosition)
        }
        .id(epoch)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { epoch = .now }
        }
        .onChange(of: store.currentTrack?.url) { _, _ in
            epoch = .now
        }
    }
}

/// Cover-Platzhalter: dunkle Fläche mit Rahmen und Notensymbol. Wird
/// gezeigt, solange echte Artwork noch nicht geladen ist oder der Track
/// keine hat.
struct CoverPlaceholderView: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    let iconSize: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Theme.Palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Theme.Palette.borderStrong, lineWidth: 1)
            )
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "music.note")
                    .foregroundStyle(Theme.Palette.textMuted)
                    .font(.system(size: iconSize))
            )
    }
}
