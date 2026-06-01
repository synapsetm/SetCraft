import SwiftUI
import SetifyCore

/// SwiftUI-Canvas-Renderer für die RGB-Waveform.
/// - Säulenhöhe = `rms` × Viewhöhe (gespiegelt um die Mitte).
/// - Farbe = additiv R = bass, G = mid, B = high. Werte werden mit
///   sqrt() perzeptuell aufgehellt, damit auch mittlere Energien sichtbar
///   bleiben.
/// - Vor dem Playhead leicht gedimmt (bereits gespielt), dahinter voll.
/// - Klick = Seek.
struct WaveformView: View {
    let data: WaveformData?
    let progress: Double          // 0…1 (player.position / duration)
    let cueProgress: Double?      // 0…1 oder nil
    let onSeek: (Double) -> Void  // mit fraction 0…1

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
        let cueColor = Color(red: 1.0, green: 0.54, blue: 0.24)

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

            // sqrt() bringt mittlere Energien optisch nach oben — sonst sind
            // nur die Peak-Momente farbig und der Rest sieht beinahe schwarz aus.
            let r = sqrt(Double(bass))
            let g = sqrt(Double(mid))
            let b = sqrt(Double(high))

            // Dark-Mode: additive Farben auf Schwarz funktionieren direkt
            //   (bass-heavy = rot, mid-heavy = grün, high-heavy = blau,
            //    Mischungen = Orange/Magenta/Cyan).
            // Light-Mode: dieselben Farben werden um Faktor 0.65 abgedunkelt,
            //   damit sie sich vom weissen Hintergrund klar abheben (sonst
            //   verschwinden helle Töne wie Cyan in Weiss).
            let dimFactor = isDark ? 1.0 : 0.65
            let baseColor = Color(
                red: r * dimFactor,
                green: g * dimFactor,
                blue: b * dimFactor
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

        // Cue-Marker als kleine orange Markierung unten.
        if let cueProgress {
            let cueX = CGFloat(cueProgress) * width
            var cueMarker = Path()
            cueMarker.move(to: CGPoint(x: cueX, y: height - 6))
            cueMarker.addLine(to: CGPoint(x: cueX - 4, y: height))
            cueMarker.addLine(to: CGPoint(x: cueX + 4, y: height))
            cueMarker.closeSubpath()
            ctx.fill(cueMarker, with: .color(cueColor))
            var cueLine = Path()
            cueLine.move(to: CGPoint(x: cueX, y: 0))
            cueLine.addLine(to: CGPoint(x: cueX, y: height))
            ctx.stroke(cueLine, with: .color(cueColor.opacity(0.45)), lineWidth: 1)
        }

        // Playhead als vertikale Linie.
        var playhead = Path()
        playhead.move(to: CGPoint(x: progressX, y: 0))
        playhead.addLine(to: CGPoint(x: progressX, y: height))
        ctx.stroke(playhead, with: .color(playheadColor), lineWidth: 1.5)
    }
}
