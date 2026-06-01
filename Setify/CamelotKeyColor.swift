import SwiftUI
import SetifyCore

/// Farbcode pro Camelot-Position, wie ihn DJ-Apps (Mixxx, Rekordbox, Serato)
/// üblicherweise verwenden: Position 1–12 läuft einmal um den Farbkreis.
/// `B` (Dur) ist heller/wärmer als `A` (Moll) bei derselben Position.
extension CamelotKey {
    /// Hauptfarbe für UI-Elemente, die nicht auf den Hintergrund-Kontrast achten müssen.
    var color: Color {
        // Position 1 startet bei Grün (120°), läuft im Uhrzeigersinn durch
        // den Kreis. Das matcht das Layout vieler Camelot-Wheels.
        let hue = (Double(((number - 1) % 12 + 12) % 12) * 30.0 + 120.0)
            .truncatingRemainder(dividingBy: 360.0) / 360.0
        let saturation: Double = (mode == .minor) ? 0.85 : 0.55
        let brightness: Double = (mode == .minor) ? 0.85 : 1.00
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}
