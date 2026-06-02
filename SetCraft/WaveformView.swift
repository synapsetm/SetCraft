import AppKit
import SwiftUI
import SetCraftCore

/// SwiftUI-Canvas-Renderer für die RGB-Waveform.
/// - Säulenhöhe = `rms` × Viewhöhe (gespiegelt um die Mitte).
/// - Farbe = additiv R = bass, G = mid, B = high. Werte werden mit
///   sqrt() perzeptuell aufgehellt, damit auch mittlere Energien sichtbar
///   bleiben.
/// - Vor dem Playhead leicht gedimmt (bereits gespielt), dahinter voll.
/// - Klick = Seek. Mausrad = Scrubbing relativ zur aktuellen Position.
struct WaveformView: View {
    let data: WaveformData?
    let progress: Double                  // 0…1 (player.position / duration)
    let onSeek: (Double) -> Void          // absolute Position als fraction 0…1
    let onScrub: (Double) -> Void         // relatives Scrubbing in fraction-Einheiten

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            Canvas { ctx, size in
                draw(in: ctx, size: size, isDark: colorScheme == .dark)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let fraction = max(0, min(1, value.location.x / proxy.size.width))
                        onSeek(fraction)
                    }
            )
            .overlay(
                ScrollWheelCatcher { deltaX, deltaY in
                    // Trackpad liefert deltaX bei horizontaler Geste, ein
                    // klassisches Rad nur deltaY. Beide Achsen kombinieren,
                    // damit beide Eingabearten natürlich wirken.
                    let raw = deltaX != 0 ? Double(deltaX) : Double(deltaY)
                    guard raw != 0 else { return }
                    // 1 Wheel-Tick ≈ 0,5 % der Trackbreite. Trackpad-Pixel-
                    // Deltas werden durch die Breite geteilt und fühlen sich
                    // damit unabhängig von der Fensterbreite konstant an.
                    let width = max(proxy.size.width, 1)
                    let fractionDelta = raw / width
                    onScrub(fractionDelta)
                }
            )
        }
        .frame(height: 80)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private func draw(in ctx: GraphicsContext, size: CGSize, isDark: Bool) {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return }

        let skeletonColor: Color = isDark ? .white.opacity(0.18) : .black.opacity(0.2)
        let playheadColor: Color = isDark ? .white.opacity(0.85) : .black.opacity(0.8)

        // Skeleton-Linie in der Mitte, solange wir noch keine Daten haben.
        guard let data, !data.bins.isEmpty else {
            let midY = height * 0.5
            var line = Path()
            line.move(to: CGPoint(x: 0, y: midY))
            line.addLine(to: CGPoint(x: width, y: midY))
            ctx.stroke(line, with: .color(skeletonColor), lineWidth: 1)
            return
        }

        // Auf Pixelbreite herunterrechnen: jede Säule fasst die Bins eines
        // Zeitabschnitts zusammen (Max für die Höhe, Mittelwert für die Farbe).
        let columnCount = Int(width.rounded())
        guard columnCount > 0 else { return }
        let binsPerColumn = max(1, data.bins.count / columnCount)

        let progressX = CGFloat(progress) * width

        // Horizontal-Mitte: Säulen wachsen symmetrisch nach oben und unten.
        let midY = height * 0.5

        for col in 0..<columnCount {
            let start = col * binsPerColumn
            guard start < data.bins.count else { break }
            let end = min(start + binsPerColumn, data.bins.count)

            var maxRms: Float = 0
            var sumBass: Float = 0
            var sumMid: Float = 0
            var sumHigh: Float = 0
            for i in start..<end {
                let b = data.bins[i]
                if b.rms > maxRms { maxRms = b.rms }
                sumBass += b.bass
                sumMid  += b.mid
                sumHigh += b.high
            }
            let n = Float(end - start)
            let bass = sumBass / n
            let mid  = sumMid  / n
            let high = sumHigh / n

            // Höhe ~ rms, etwas non-linear, damit leise Stellen sichtbar bleiben
            // und laute nicht alles fluten.
            let amp = CGFloat(pow(maxRms, 0.6)) * (height * 0.45)
            let x = CGFloat(col) + 0.5

            // Additive RGB: R = Bass, G = Mitten, B = Höhen. pow(0.4) hebt
            // mittlere Energien deutlich perzeptuell an — sonst landen die
            // Werte nach der Normalisierung oft im 0.2–0.4-Bereich und
            // die Säulen sehen flau/grau aus. Knalligere Farben sind das Ziel.
            let gamma: Double = 0.4
            let baseColor = Color(
                red:   pow(Double(bass), gamma),
                green: pow(Double(mid),  gamma),
                blue:  pow(Double(high), gamma)
            )

            let played = CGFloat(x) < progressX
            let color: Color = played
                ? baseColor.opacity(isDark ? 0.45 : 0.55)
                : baseColor

            var path = Path()
            path.move(to: CGPoint(x: x, y: midY - amp))
            path.addLine(to: CGPoint(x: x, y: midY + amp))
            ctx.stroke(path, with: .color(color), lineWidth: 1.0)
        }

        // Playhead als vertikale Linie.
        var playhead = Path()
        playhead.move(to: CGPoint(x: progressX, y: 0))
        playhead.addLine(to: CGPoint(x: progressX, y: height))
        ctx.stroke(playhead, with: .color(playheadColor), lineWidth: 1.5)
    }
}

/// Transparente NSView, die nur eines tut: `scrollWheel:`-Events auffangen
/// und über einen Callback an SwiftUI weiterreichen. SwiftUI hat (noch) keinen
/// nativen Modifier für Mausrad-Events auf macOS.
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = ScrollView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollView)?.onScroll = onScroll
    }

    final class ScrollView: NSView {
        var onScroll: ((CGFloat, CGFloat) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            onScroll?(event.scrollingDeltaX, event.scrollingDeltaY)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Nur Scroll-Events fangen wir ab; Mausklicks reichen wir an
            // SwiftUI darunter durch (sonst kommt die Drag-Geste fürs Seeken
            // nicht mehr an).
            if NSApp.currentEvent?.type == .scrollWheel { return self }
            return nil
        }
    }
}
