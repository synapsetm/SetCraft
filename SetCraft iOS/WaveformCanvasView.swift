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
    /// Der Track wird gerade auf das Gerät geholt. Eigener Zustand neben
    /// `isLoading` (das die Waveform-Analyse meint): beim Antippen eines kalten
    /// Tracks über Mobilfunk ist das die eigentliche Wartezeit, und der Blick
    /// liegt in diesem Moment auf der leeren Wellenfläche.
    var isLoadingTrack: Bool = false
    /// Anteil der übertragenen Bytes, 0…1 — `nil`, solange unbekannt.
    var loadProgress: Double? = nil

    /// Zoom in Takten (I1-Spec): sichtbar sind `zoomBars` Takte über die
    /// ganze Breite bzw. Höhe. Weil der Zoom in Takten statt in px/s steht,
    /// bleibt er bei Tempoänderungen musikalisch gleich. Persistent über
    /// App-Sessions; der frühere Key `waveformPxPerSec` wird nicht mehr gelesen.
    @AppStorage("waveformZoomBars") private var zoomBars: Int = Theme.MetricsIOS.defaultZoomBars

    @State private var dragStartTime: TimeInterval?
    /// Laufender Pinch: Startwert und stufenloser Zwischenwert in Takten.
    /// Beim Loslassen rastet der Zoom auf die nächste Stufe ein.
    @State private var pinchStartBars: Double?
    @State private var pinchBars: Double?

    private static let zoomSteps = Theme.MetricsIOS.zoomBars
    /// Tempo für die Zoom-Umrechnung, solange kein BPM bekannt ist.
    private static let fallbackBPM: Double = 120

    /// Gerade sichtbare Takte — während des Pinch stufenlos.
    private var visibleBars: Double {
        pinchBars ?? Double(clampedZoomBars)
    }

    /// Gespeicherter Wert, auf eine gültige Stufe gezogen.
    private var clampedZoomBars: Int {
        Self.zoomSteps.contains(zoomBars) ? zoomBars : Theme.MetricsIOS.defaultZoomBars
    }

    /// Gültiges Tempo für Grid und Zoom, sonst `nil`. Ein unsinniger Tag
    /// („inf", „1e300") darf weder die Umrechnung noch das Grid kippen.
    private var validBPM: Double? {
        guard let bpm, bpm.isFinite, bpm >= 20, bpm <= 400 else { return nil }
        return bpm
    }

    /// Pixel pro Sekunde für die Länge der Zeitachse:
    /// `length / (bars × 4 × 60 / bpm)`.
    private func pixelsPerSecond(length: CGFloat) -> Double {
        let secondsPerBar = 4 * 60 / (validBPM ?? Self.fallbackBPM)
        let visibleSeconds = visibleBars * secondsPerBar
        guard length > 0, visibleSeconds > 0 else { return 1 }
        return Double(length) / visibleSeconds
    }

    var body: some View {
        GeometryReader { proxy in
            let length = axis == .horizontal ? proxy.size.width : proxy.size.height
            let pxPerSec = pixelsPerSecond(length: length)
            ZStack(alignment: .topLeading) {
                Theme.Palette.waveformBG

                Canvas { ctx, size in
                    if axis == .horizontal {
                        draw(in: ctx, size: size, pxPerSec: pxPerSec)
                    } else {
                        drawVertical(in: ctx, size: size, pxPerSec: pxPerSec)
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
                            if pinchStartBars == nil {
                                pinchStartBars = Double(clampedZoomBars)
                            }
                            // Auseinanderziehen = hineinzoomen = weniger Takte.
                            let m = max(0.01, Double(value.magnification))
                            let bars = (pinchStartBars ?? 8) / m
                            let lo = Double(Self.zoomSteps.first ?? 1)
                            let hi = Double(Self.zoomSteps.last ?? 64)
                            pinchBars = min(hi, max(lo, bars))
                        }
                        .onEnded { _ in
                            if let bars = pinchBars {
                                zoomBars = Self.nearestStep(to: bars)
                            }
                            pinchStartBars = nil
                            pinchBars = nil
                        }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        zoomBars = Theme.MetricsIOS.defaultZoomBars
                    }
                )

                if axis == .horizontal {
                    progressBar(width: proxy.size.width)
                    timeLabels
                } else {
                    progressBarVertical(height: proxy.size.height)
                    timeLabelsVertical
                }

                // Im schmalen Landscape-Streifen ist kein Platz für die
                // Kapsel; Pinch und Doppeltipp bleiben dort aktiv.
                if axis == .horizontal {
                    zoomCapsuleOverlay
                }

                if isLoadingTrack {
                    trackLoadOverlay(width: proxy.size.width)
                } else if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// Ladeanzeige mittig auf der Wellenfläche. Bewusst hier und nicht unten am
    /// Bildschirmrand: die Fläche ist während des Ladens ohnehin leer, und der
    /// Blick liegt beim Antippen dort.
    @ViewBuilder
    private func trackLoadOverlay(width: CGFloat) -> some View {
        VStack(spacing: 8) {
            if let fraction = loadProgress {
                ProgressView(value: fraction)
                    .tint(Theme.Palette.accent)
                    .frame(width: min(220, max(120, width * 0.5)))
                Text(verbatim: "\(Int(fraction * 100)) %")
                    .font(Theme.TypoIOS.time)
                    .foregroundStyle(Theme.Palette.text)
            } else {
                // Noch kein Anteil bekannt — der Download hat gerade erst
                // begonnen oder die Quelle ist lokal.
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.Palette.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.waveformBG.opacity(0.85))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func progressBar(width: CGFloat) -> some View {
        let frac = duration > 0 ? CGFloat(position / duration) : 0
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Theme.Palette.border)
                .frame(height: Theme.MetricsIOS.progressHeight)
            Rectangle()
                .fill(Theme.Palette.accent)
                .frame(width: width * frac, height: Theme.MetricsIOS.progressHeight)
        }
        .allowsHitTesting(false)
    }

    /// ELAPSED oben links, REMAIN oben rechts. Die Gesamtdauer steht im
    /// `TrackInfoSheet` (und ergibt sich aus beiden).
    @ViewBuilder
    private var timeLabels: some View {
        HStack {
            Text(verbatim: formatTime(position))
                .modifier(WaveformTimeLabel())
            Spacer()
            Text(verbatim: "-" + formatTime(max(0, duration - position)))
                .modifier(WaveformTimeLabel(secondary: true))
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .allowsHitTesting(false)
    }

    /// Zoom-Kapsel unten rechts: `−  8 BARS  +`. Minus zeigt mehr Takte
    /// (herauszoomen), Plus weniger (hineinzoomen).
    @ViewBuilder
    private var zoomCapsuleOverlay: some View {
        let shown = Int(visibleBars.rounded())
        let index = Self.zoomSteps.firstIndex(of: clampedZoomBars) ?? 3
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 0) {
                    zoomButton(symbol: "minus", enabled: index < Self.zoomSteps.count - 1) {
                        zoomBars = Self.zoomSteps[min(Self.zoomSteps.count - 1, index + 1)]
                    }
                    .accessibilityLabel("Zoom out")
                    Text("\(shown) bars")
                        .font(Theme.TypoIOS.time)
                        .textCase(.uppercase)
                        .tracking(Theme.Typo.labelTracking)
                        .foregroundStyle(Theme.Palette.text)
                        .frame(minWidth: 64)
                    zoomButton(symbol: "plus", enabled: index > 0) {
                        zoomBars = Self.zoomSteps[max(0, index - 1)]
                    }
                    .accessibilityLabel("Zoom in")
                }
                .background(Theme.Palette.waveformBG.opacity(0.8), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.Palette.borderStrong, lineWidth: 1))
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func zoomButton(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.Palette.text)
                .frame(width: Theme.MetricsIOS.minTouch, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    /// Nächste Zoomstufe — im Log-Raum, weil die Stufen sich verdoppeln.
    private static func nearestStep(to bars: Double) -> Int {
        let target = log2(max(bars, 0.001))
        return zoomSteps.min(by: {
            abs(log2(Double($0)) - target) < abs(log2(Double($1)) - target)
        }) ?? Theme.MetricsIOS.defaultZoomBars
    }

    /// Beatgrid-Raster nach Zoom: ≤ 4 Takte pro Beat, ≤ 16 pro Takt, sonst
    /// alle 4 Takte. Jede vierte Linie ist heller (Takt bzw. 4 bzw. 16 Takte).
    private func gridSpacing(bpm: Double) -> (step: Double, majorEvery: Int) {
        let beat = 60.0 / bpm
        let bar = beat * 4
        switch visibleBars {
        case ...4:  return (beat, 4)
        case ...16: return (bar, 4)
        default:    return (bar * 4, 4)
        }
    }

    /// Grid-Linie: jede `majorEvery`-te etwas heller.
    private func gridColor(index: Double, majorEvery: Int) -> Color {
        let isMajor = index.truncatingRemainder(dividingBy: Double(majorEvery)) == 0
        return isMajor ? Theme.Palette.text.opacity(0.16) : Theme.Palette.beatgrid
    }

    private func draw(in ctx: GraphicsContext, size: CGSize, pxPerSec: Double) {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return }
        let midY = height * 0.5
        let centerX = width * 0.5
        let leftTime = position - Double(centerX) / pxPerSec

        // Beat-Grid nach Zoomstufe — nur wenn BPM bekannt.
        //
        // Über den Takt wird per Index iteriert, nicht per `t += bar`. Ein
        // unsinniges BPM (ein Tag mit dem Text „inf" oder „1e300") ergab sonst
        // ein `bar` von 0 bzw. subnormal: `t` kam nicht mehr vorwärts, bei `inf`
        // wurde es NaN — und weil jeder Vergleich mit NaN false ist, brach
        // `while true` nie ab. Ein harter Hänger im Draw, auf dem Main-Thread.
        // `TagReader` lässt solche Werte inzwischen nicht mehr durch; die
        // Zeichnung verlässt sich nicht darauf.
        if let bpm = validBPM {
            let grid = gridSpacing(bpm: bpm)
            // Unter vier Pixel Abstand ist das Grid ohnehin nur noch Rauschen.
            if grid.step * pxPerSec >= 4 {
                let firstIndex = (leftTime / grid.step).rounded(.up)
                let maxLines = Int(width / (grid.step * pxPerSec)) + 2
                for step in 0..<maxLines {
                    let index = firstIndex + Double(step)
                    let t = index * grid.step
                    let x = centerX + CGFloat((t - position) * pxPerSec)
                    if x > width { break }
                    if x >= 0 {
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: height))
                        ctx.stroke(p, with: .color(gridColor(index: index, majorEvery: grid.majorEvery)),
                                   lineWidth: 1)
                    }
                }
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

        // Center-Playhead vertikal, mit Dreieck oben.
        var line = Path()
        line.move(to: CGPoint(x: centerX, y: 0))
        line.addLine(to: CGPoint(x: centerX, y: height))
        ctx.stroke(line, with: .color(Theme.Palette.accent), lineWidth: Theme.MetricsIOS.playheadWidth)

        var triTop = Path()
        triTop.move(to: CGPoint(x: centerX - 6, y: 0))
        triTop.addLine(to: CGPoint(x: centerX + 6, y: 0))
        triTop.addLine(to: CGPoint(x: centerX, y: 8))
        triTop.closeSubpath()
        ctx.fill(triTop, with: .color(Theme.Palette.accent))
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
                    .fill(Theme.Palette.border)
                    .frame(width: Theme.MetricsIOS.progressHeight, height: height)
                Rectangle()
                    .fill(Theme.Palette.accent)
                    .frame(width: Theme.MetricsIOS.progressHeight, height: height * frac)
            }
            .padding(.trailing, 2)
        }
        .allowsHitTesting(false)
    }

    /// Querformat: ELAPSED oben, REMAIN unten.
    @ViewBuilder
    private var timeLabelsVertical: some View {
        VStack {
            Text(verbatim: formatTime(position))
                .modifier(WaveformTimeLabel())
                .padding(.top, 8)
            Spacer()
            Text(verbatim: "-" + formatTime(max(0, duration - position)))
                .modifier(WaveformTimeLabel(secondary: true))
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
    private func drawVertical(in ctx: GraphicsContext, size: CGSize, pxPerSec: Double) {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return }
        let midX = width * 0.5
        let centerY = height * 0.5
        // Zeit am Punkt y: oben (y=0) ist Zukunft, unten (y=height) ist
        // Vergangenheit — daher (centerY - y) im Zähler.
        let timeOffsetPerPixel = 1.0 / pxPerSec
        let topTime = position + Double(centerY) * timeOffsetPerPixel

        // Index-Iteration wie im horizontalen Pendant — siehe die Begründung
        // dort. `while t <= topTime` terminiert bei NaN zwar von selbst, aber
        // bei subnormalem `bar` liefe es praktisch endlos.
        if let bpm = validBPM {
            let grid = gridSpacing(bpm: bpm)
            if grid.step * pxPerSec >= 4 {
                // Linien zwischen bottomTime und topTime, von der ältesten
                // sichtbaren aus aufwärts iterieren.
                let bottomTime = position - Double(height - centerY) * timeOffsetPerPixel
                let firstIndex = (bottomTime / grid.step).rounded(.up)
                let maxLines = Int(height / (grid.step * pxPerSec)) + 2
                for step in 0..<maxLines {
                    let index = firstIndex + Double(step)
                    let t = index * grid.step
                    if t > topTime { break }
                    let y = centerY - CGFloat((t - position) * pxPerSec)
                    if y >= 0, y <= height {
                        var p = Path()
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: width, y: y))
                        ctx.stroke(p, with: .color(gridColor(index: index, majorEvery: grid.majorEvery)),
                                   lineWidth: 1)
                    }
                }
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
        ctx.stroke(line, with: .color(Theme.Palette.accent), lineWidth: Theme.MetricsIOS.playheadWidth)

        var triLeft = Path()
        triLeft.move(to: CGPoint(x: 0, y: centerY - 6))
        triLeft.addLine(to: CGPoint(x: 0, y: centerY + 6))
        triLeft.addLine(to: CGPoint(x: 8, y: centerY))
        triLeft.closeSubpath()
        ctx.fill(triLeft, with: .color(Theme.Palette.accent))
    }
}

/// Zeit-Pille auf der Wellenfläche: halbtransparenter dunkler Grund.
private struct WaveformTimeLabel: ViewModifier {
    var secondary = false

    func body(content: Content) -> some View {
        content
            .font(Theme.TypoIOS.time)
            .foregroundStyle(secondary ? Theme.Palette.textSecondary : Theme.Palette.text)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.Palette.waveformBG.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
    }
}
