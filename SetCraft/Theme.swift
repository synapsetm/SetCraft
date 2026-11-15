import SwiftUI

/// Design-Tokens für das Mac-Redesign «B6 · Deck / Amber / Systemschrift».
/// Quelle: docs/design/B6-spec.md. Alle Farben, Schriften und Masse des
/// Hauptfensters kommen von hier – keine Hex-Werte direkt in Views.
enum Theme {

    // MARK: Farben
    enum Palette {
        static let background      = Color(hex: 0x0D0B08)
        static let surface         = Color(hex: 0x14110D)   // Buttons, Eingabefelder
        static let waveformBG      = Color(hex: 0x070604)
        static let beatgrid        = Color(red: 1.0, green: 240/255, blue: 210/255).opacity(0.08)
        static let border          = Color(hex: 0x2F2A22)
        static let borderStrong    = Color(hex: 0x423B30)
        static let rowDivider      = Color(hex: 0x1E1B16)

        static let text            = Color(hex: 0xEFE8DC)
        static let textSecondary   = Color(hex: 0xB5AB99)
        static let textMuted       = Color(hex: 0x9A9080)   // Labels, Spaltenköpfe

        static let accent          = Color(hex: 0xFFB020)   // Amber
        static let onAccent        = Color(hex: 0x241600)
        static let selection       = Color(hex: 0xFFB020).opacity(0.13)

        static let star            = Color(hex: 0xF5B544)
        static let starDim         = Color(hex: 0x6A6253)

        static let cue             = Color(hex: 0xFF6B4A)
        static let cueLabel        = Color(hex: 0xFF8468)

        static let issueBorder     = Color(hex: 0x7A3A33)
        static let issueText       = Color(hex: 0xFF8F82)

        /// Grenzfall-Key (Tilde) – ersetzt den bisherigen Inline-Wert in SoundingKeyLabel.
        static let keyAmbiguous    = Color(hex: 0xFF9F45)
    }

    // MARK: Schrift (Systemschrift SF Pro, Ziffern immer tabellarisch)
    enum Typo {
        static let brand        = Font.system(size: 13, weight: .bold)          // + tracking(2.1)
        static let label        = Font.system(size: 11, weight: .medium)        // UPPERCASE + tracking(0.9)
        static let title        = Font.system(size: 20, weight: .semibold)
        static let artist       = Font.system(size: 14)
        static let readout      = Font.system(size: 38, weight: .semibold).monospacedDigit()
        static let body         = Font.system(size: 13)
        static let bodyNumeric  = Font.system(size: 13).monospacedDigit()
        static let button       = Font.system(size: 12, weight: .semibold)      // UPPERCASE + tracking(0.6)

        static let brandTracking: CGFloat  = 2.1
        static let labelTracking: CGFloat  = 0.9
        static let buttonTracking: CGFloat = 0.6
    }

    // MARK: Masse
    enum Metrics {
        static let radius: CGFloat            = 2
        static let rowHeight: CGFloat         = 32
        static let waveformHeight: CGFloat    = 148
        static let selectionEdge: CGFloat     = 3
        static let transportHeight: CGFloat   = 44
        static let transportSide: CGFloat     = 52    // Prev / Next
        static let transportMain: CGFloat     = 84    // Play / Pause
        static let toolbarHeight: CGFloat     = 28    // Library-Toolbar (Filter, Buttons)
        static let sidebarWidth: CGFloat      = 220
        static let padding: CGFloat           = 16
    }
}

extension Color {
    /// 0xRRGGBB → Color (sRGB).
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >>  8) & 0xFF) / 255,
                  blue:  Double( hex        & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Eckiger B6-Button. Breite optional (sonst Inhalt + 16 seitlich), Höhe
/// standardmässig `transportHeight`, in der Library-Toolbar `toolbarHeight`.
struct ThemeButtonStyle: ButtonStyle {
    enum Kind {
        /// `surface` mit `borderStrong`-Rahmen.
        case standard
        /// Gefüllt in `accent` (Play/Pause).
        case prominent
        /// Rahmen und Text in `accent` (Analyze missing).
        case accentOutline
        /// Rahmen `issueBorder`, Text `issueText` (fehlende Tags).
        case issue
    }

    var width: CGFloat? = nil
    var height: CGFloat = Theme.Metrics.transportHeight
    var kind: Kind = .standard

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, width: width, height: height, kind: kind)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let width: CGFloat?
        let height: CGFloat
        let kind: Kind
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Metrics.radius)
            configuration.label
                .font(Theme.Typo.button)
                .tracking(Theme.Typo.buttonTracking)
                .textCase(.uppercase)
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, width == nil ? 14 : 0)
                .frame(width: width, height: height)
                .background(kind == .prominent ? Theme.Palette.accent : Theme.Palette.surface, in: shape)
                .overlay(shape.strokeBorder(border, lineWidth: 1))
                .contentShape(shape)
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
        }

        private var foreground: Color {
            switch kind {
            case .standard:      Theme.Palette.text
            case .prominent:     Theme.Palette.onAccent
            case .accentOutline: Theme.Palette.accent
            case .issue:         Theme.Palette.issueText
            }
        }

        private var border: Color {
            switch kind {
            case .standard:      Theme.Palette.borderStrong
            case .prominent:     .clear
            case .accentOutline: Theme.Palette.accent
            case .issue:         Theme.Palette.issueBorder
            }
        }
    }
}

extension View {
    /// Kleines Label im B6-Stil (z. B. «BPM», «KEY», Spaltenköpfe).
    func themeLabel() -> some View {
        self.font(Theme.Typo.label)
            .tracking(Theme.Typo.labelTracking)
            .textCase(.uppercase)
            .foregroundStyle(Theme.Palette.textMuted)
    }

    /// Zelle im Now-Playing-Raster: Innenabstand 16 vertikal, 22 seitlich,
    /// füllt die Rasterhöhe, damit Trennlinien und Hover-Fläche durchgehen.
    func nowPlayingCell() -> some View {
        self.padding(.vertical, 16).padding(.horizontal, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
