//
//  WaveformCanvasView.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import SwiftUI
import SetCraftCore

/// Center-Playhead-Waveform aus `docs/player.html`. Anders als auf dem Mac
/// (festes Wave-Bild, beweglicher Playhead) bleibt der Playhead hier in der
/// Mitte und die Wellenform scrollt unter ihm hindurch — CDJ-Look.
///
/// Drag-Scrub: Finger nach links → Wave nach links → Zeit läuft vorwärts.
/// `axis == .vertical` rendert dieselbe Welle um 90° gedreht — Zeit verläuft
/// von oben nach unten, Playhead ist eine horizontale Linie in der Mitte.
/// Wird im iPhone-Landscape vom `PlayerScreen` genutzt.
struct WaveformCanvasView: View {
    let data: WaveformData?
    let position: TimeInterval
    let duration: TimeInterval
    let bpm: Double?
    let isLoading: Bool
    let onScrub: (TimeInterval) -> Void
    var axis: Axis = .horizontal

    /// Zoom-Level: Pixel pro Sekunde der Wellenform. Persistent über
    /// App-Sessions via `@AppStorage`. Pinch-Geste (Magnify) skaliert
    /// im Bereich 15…200 px/s — von "Track in einem Blick" bis hin zu
    /// einzelnen Beats.
    @AppStorage("waveformPxPerSec") private var pxPerSec: Double = 52

    @State private var dragStartTime: TimeInterval?
    @State private var pinchStartZoom: Double?
    @State private var zoomHUDOpacity: Double = 0

    private let minPxPerSec: Double = 2
    private let maxPxPerSec: Double = 200
    private let defaultPxPerSec: Double = 52

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color(red: 0.055, green: 0.055, blue: 0.07)

                Canvas { ctx, size in
                    if axis == .horizontal {
                        draw(in: ctx, size: size)
                    } else {
                        drawVertical(in: ctx, size: size)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragStartTime == nil { dragStartTime = position }
                            // Im Landscape verläuft die Zeit von oben (Zukunft)
                            // nach unten (Vergangenheit). Finger nach unten ziehen
                            // = Welle nach unten schieben = Zeit läuft vorwärts.
                            let primary = axis == .horizontal
                                ? -Double(value.translation.width)
                                : Double(value.translation.height)
                            let dt = primary / pxPerSec
                            let new = max(0, min(duration, (dragStartTime ?? 0) + dt))
                            onScrub(new)
                        }
                        .onEnded { _ in
                            dragStartTime = nil
                        }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if pinchStartZoom == nil {
                                pinchStartZoom = pxPerSec
                                zoomHUDOpacity = 1
                            }
                            let scaled = (pinchStartZoom ?? pxPerSec) * value.magnification
                            pxPerSec = max(minPxPerSec, min(maxPxPerSec, scaled))
                        }
                        .onEnded { _ in
                            pinchStartZoom = nil
                            withAnimation(.easeOut(duration: 0.4).delay(0.6)) {
                                zoomHUDOpacity = 0
                            }
                        }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        pxPerSec = defaultPxPerSec
                        showZoomHUDBriefly()
                    }
                )

                if axis == .horizontal {
                    progressBar(width: proxy.size.width)
                    timeLabels(width: proxy.size.width)
                } else {
                    progressBarVertical(height: proxy.size.height)
                    timeLabelsVertical(height: proxy.size.height)
                }

                zoomHUD(width: proxy.size.width)

                // Im schmalen Landscape-Streifen überdecken die Buttons sonst
                // das Duration-Label. Pinch-to-zoom bleibt aktiv.
                if axis == .horizontal {
                    zoomButtonsOverlay
                }

                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func progressBar(width: CGFloat) -> some View {
        let frac = duration > 0 ? CGFloat(position / duration) : 0
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color(red: 0.15, green: 0.15, blue: 0.18))
                .frame(height: 2)
            Rectangle()
                .fill(Color.orange)
                .frame(width: width * frac, height: 2)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func timeLabels(width _: CGFloat) -> some View {
        HStack {
            Text("\(formatTime(position)) / -\(formatTime(max(0, duration - position)))")
                .modifier(WaveformTimeLabel())
                .padding(.leading, 8)
            Spacer()
            Text(formatTime(duration))
                .modifier(WaveformTimeLabel())
                .padding(.trailing, 8)
        }
        .padding(.top, 8)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func zoomHUD(width: CGFloat) -> some View {
        let visibleSeconds = Double(width) / pxPerSec
        VStack {
            Spacer()
            Text(String(format: "%.1fs sichtbar", visibleSeconds))
                .modifier(WaveformTimeLabel())
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .opacity(zoomHUDOpacity)
        .allowsHitTesting(false)
    }

    /// Sichtbare +/–-Buttons als Alternative zur Pinch-Geste. Doppeltap auf
    /// die Wave setzt den Zoom auf den Default zurück.
    @ViewBuilder
    private var zoomButtonsOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    zoomButton(symbol: "minus", factor: 1.0 / 1.25)
                    zoomButton(symbol: "plus",  factor: 1.25)
                }
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func zoomButton(symbol: String, factor: Double) -> some View {
        Button {
            let scaled = pxPerSec * factor
            pxPerSec = max(minPxPerSec, min(maxPxPerSec, scaled))
            showZoomHUDBriefly()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Color.black.opacity(0.45), in: Circle())
                .foregroundStyle(.white.opacity(0.9))
        }
        .buttonStyle(.plain)
    }

    private func showZoomHUDBriefly() {
        zoomHUDOpacity = 1
        withAnimation(.easeOut(duration: 0.4).delay(0.6)) {
            zoomHUDOpacity = 0
        }
    }

    private func draw(in ctx: GraphicsContext, size: CGSize) {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return }
        let midY = height * 0.5
        let centerX = width * 0.5
        let leftTime = position - Double(centerX) / pxPerSec

        // Beat-Grid alle 4 Beats — nur wenn BPM bekannt.
        if let bpm, bpm > 0 {
            let bar = (60.0 / bpm) * 4
            var t = (leftTime / bar).rounded(.up) * bar
            while true {
                let x = centerX + CGFloat((t - position) * pxPerSec)
                if x > width { break }
                if x >= 0 {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: height))
                    ctx.stroke(p, with: .color(.white.opacity(0.05)), lineWidth: 1)
                }
                t += bar
            }
        }

        // Waveform-Säulen — pro Pixelspalte den richtigen Bin-Bereich
        // aggregieren. Bei niedrigem Zoom (z. B. 2 px/s, ganzer Track im
        // Viewport) deckt ein Pixel viele Bins ab; sonst gehen Peaks
        // verloren. Max für die Höhe (rms), Mittel für die RGB-Färbung.
        if let data, !data.bins.isEmpty {
            let totalSeconds = data.secondsPerBin * Double(data.bins.count)
            let secondsPerPixel = 1.0 / pxPerSec
            let binsPerPixel = max(1, Int((secondsPerPixel / data.secondsPerBin).rounded()))
            let halfWindow = binsPerPixel / 2

            for x in 0..<Int(width.rounded()) {
                let t = leftTime + Double(x) / pxPerSec
                if t < 0 || t > totalSeconds { continue }
                let centerBin = Int(t / data.secondsPerBin)
                let startBin = max(0, centerBin - halfWindow)
                let endBin = min(data.bins.count, centerBin + halfWindow + 1)
                guard startBin < endBin else { continue }

                var maxRms: Float = 0
                var sumBass: Float = 0
                var sumMid: Float = 0
                var sumHigh: Float = 0
                for i in startBin..<endBin {
                    let bin = data.bins[i]
                    if bin.rms > maxRms { maxRms = bin.rms }
                    sumBass += bin.bass
                    sumMid  += bin.mid
                    sumHigh += bin.high
                }
                let n = Float(endBin - startBin)
                let bass = sumBass / n
                let mid  = sumMid  / n
                let high = sumHigh / n

                let amp = CGFloat(pow(Double(maxRms), 0.6)) * height * 0.44
                let gamma = 0.4
                let color = Color(
                    red:   pow(Double(bass), gamma),
                    green: pow(Double(mid),  gamma),
                    blue:  pow(Double(high), gamma)
                )
                var p = Path()
                p.move(to: CGPoint(x: CGFloat(x) + 0.5, y: midY - amp))
                p.addLine(to: CGPoint(x: CGFloat(x) + 0.5, y: midY + amp))
                ctx.stroke(p, with: .color(color), lineWidth: 1)
            }
        }

        // Played-Side-Overlay (links der Mitte abdunkeln).
        let overlay = Path(CGRect(x: 0, y: 0, width: centerX, height: height))
        ctx.fill(overlay, with: .color(.black.opacity(0.42)))

        // Center-Playhead vertikal.
        var line = Path()
        line.move(to: CGPoint(x: centerX, y: 0))
        line.addLine(to: CGPoint(x: centerX, y: height))
        ctx.stroke(line, with: .color(.white), lineWidth: 2)

        // Dreieck-Marker oben und unten.
        var triTop = Path()
        triTop.move(to: CGPoint(x: centerX - 6, y: 0))
        triTop.addLine(to: CGPoint(x: centerX + 6, y: 0))
        triTop.addLine(to: CGPoint(x: centerX, y: 8))
        triTop.closeSubpath()
        ctx.fill(triTop, with: .color(.white))

        var triBot = Path()
        triBot.move(to: CGPoint(x: centerX - 6, y: height))
        triBot.addLine(to: CGPoint(x: centerX + 6, y: height))
        triBot.addLine(to: CGPoint(x: centerX, y: height - 8))
        triBot.closeSubpath()
        ctx.fill(triBot, with: .color(.white))
    }

    private func formatTime(_ s: TimeInterval) -> String {
        let total = max(0, Int(s.rounded()))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    @ViewBuilder
    private func progressBarVertical(height: CGFloat) -> some View {
        let frac = duration > 0 ? CGFloat(position / duration) : 0
        HStack {
            Spacer(minLength: 0)
            // Wächst von unten nach oben — passt zur Logik „Vergangenheit unten,
            // Zukunft oben". Voll = Track komplett gespielt.
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(Color(red: 0.15, green: 0.15, blue: 0.18))
                    .frame(width: 2, height: height)
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 2, height: height * frac)
            }
            .padding(.trailing, 2)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func timeLabelsVertical(height _: CGFloat) -> some View {
        VStack {
            // Oben: abgespielt / Restzeit (CDJ-Layout, identisch zum
            // Portrait-Header). Unten: Gesamtdauer als zweite Pill.
            Text("\(formatTime(position)) / -\(formatTime(max(0, duration - position)))")
                .modifier(WaveformTimeLabel())
                .padding(.top, 8)
            Spacer()
            Text(formatTime(duration))
                .modifier(WaveformTimeLabel())
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    /// Vertikales Pendant zu `draw(in:size:)` für den Landscape-Modus.
    /// Zeit verläuft top→bottom: oben liegt die ZUKUNFT, unten die
    /// VERGANGENHEIT, der Playhead bleibt zentriert. Das matched die
    /// Erwartung „die Welle läuft von oben nach unten ab" — neue Audio-
    /// Inhalte kommen oben rein, scrollen durch den Playhead und
    /// verschwinden unten.
    private func drawVertical(in ctx: GraphicsContext, size: CGSize) {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return }
        let midX = width * 0.5
        let centerY = height * 0.5
        // Zeit am Punkt y: oben (y=0) ist Zukunft, unten (y=height) ist
        // Vergangenheit — daher (centerY - y) im Zähler.
        let timeOffsetPerPixel = 1.0 / pxPerSec
        let topTime = position + Double(centerY) * timeOffsetPerPixel

        if let bpm, bpm > 0 {
            let bar = (60.0 / bpm) * 4
            // Beat-Linien zwischen bottomTime und topTime, von der ältesten
            // sichtbaren aus aufwärts iterieren.
            let bottomTime = position - Double(height - centerY) * timeOffsetPerPixel
            var t = (bottomTime / bar).rounded(.up) * bar
            while t <= topTime {
                let y = centerY - CGFloat((t - position) * pxPerSec)
                if y >= 0, y <= height {
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: width, y: y))
                    ctx.stroke(p, with: .color(.white.opacity(0.05)), lineWidth: 1)
                }
                t += bar
            }
        }

        if let data, !data.bins.isEmpty {
            let totalSeconds = data.secondsPerBin * Double(data.bins.count)
            let binsPerPixel = max(1, Int((timeOffsetPerPixel / data.secondsPerBin).rounded()))
            let halfWindow = binsPerPixel / 2

            for y in 0..<Int(height.rounded()) {
                // y wächst nach unten = ältere Zeit.
                let t = topTime - Double(y) * timeOffsetPerPixel
                if t < 0 || t > totalSeconds { continue }
                let centerBin = Int(t / data.secondsPerBin)
                let startBin = max(0, centerBin - halfWindow)
                let endBin = min(data.bins.count, centerBin + halfWindow + 1)
                guard startBin < endBin else { continue }

                var maxRms: Float = 0
                var sumBass: Float = 0
                var sumMid: Float = 0
                var sumHigh: Float = 0
                for i in startBin..<endBin {
                    let bin = data.bins[i]
                    if bin.rms > maxRms { maxRms = bin.rms }
                    sumBass += bin.bass
                    sumMid  += bin.mid
                    sumHigh += bin.high
                }
                let n = Float(endBin - startBin)
                let bass = sumBass / n
                let mid  = sumMid  / n
                let high = sumHigh / n

                let amp = CGFloat(pow(Double(maxRms), 0.6)) * width * 0.44
                let gamma = 0.4
                let color = Color(
                    red:   pow(Double(bass), gamma),
                    green: pow(Double(mid),  gamma),
                    blue:  pow(Double(high), gamma)
                )
                var p = Path()
                p.move(to: CGPoint(x: midX - amp, y: CGFloat(y) + 0.5))
                p.addLine(to: CGPoint(x: midX + amp, y: CGFloat(y) + 0.5))
                ctx.stroke(p, with: .color(color), lineWidth: 1)
            }
        }

        // Played-Overlay deckt die untere Hälfte ab (= Vergangenheit).
        let overlay = Path(CGRect(x: 0, y: centerY, width: width, height: height - centerY))
        ctx.fill(overlay, with: .color(.black.opacity(0.42)))

        var line = Path()
        line.move(to: CGPoint(x: 0, y: centerY))
        line.addLine(to: CGPoint(x: width, y: centerY))
        ctx.stroke(line, with: .color(.white), lineWidth: 2)

        var triLeft = Path()
        triLeft.move(to: CGPoint(x: 0, y: centerY - 6))
        triLeft.addLine(to: CGPoint(x: 0, y: centerY + 6))
        triLeft.addLine(to: CGPoint(x: 8, y: centerY))
        triLeft.closeSubpath()
        ctx.fill(triLeft, with: .color(.white))

        var triRight = Path()
        triRight.move(to: CGPoint(x: width, y: centerY - 6))
        triRight.addLine(to: CGPoint(x: width, y: centerY + 6))
        triRight.addLine(to: CGPoint(x: width - 8, y: centerY))
        triRight.closeSubpath()
        ctx.fill(triRight, with: .color(.white))
    }
}

private struct WaveformTimeLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color(red: 0.81, green: 0.81, blue: 0.84))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
    }
}
