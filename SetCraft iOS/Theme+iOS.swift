//
//  Theme+iOS.swift
//  SetCraft iOS
//
//  iPhone-Grössen zum gemeinsamen `Theme` (Shared/Theme.swift). Die Palette
//  gilt für beide Plattformen; `Theme.Typo` und `Theme.Metrics` sind auf den
//  Mac abgestimmt und bleiben dort unverändert. Werte: docs/design/I1-spec.md.
//

import SwiftUI

extension Theme {
    enum TypoIOS {
        static let brand        = Font.system(size: 15, weight: .bold)          // + tracking(brandTracking)
        static let label        = Font.system(size: 11, weight: .medium)        // UPPERCASE + tracking
        static let title        = Font.system(size: 17, weight: .semibold)
        static let artist       = Font.system(size: 15)
        static let readout      = Font.system(size: 30, weight: .semibold).monospacedDigit()
        static let body         = Font.system(size: 15)
        static let bodyNumeric  = Font.system(size: 15).monospacedDigit()
        static let rowTitle     = Font.system(size: 16, weight: .medium)
        static let rowDetail    = Font.system(size: 13)
        static let rowNumeric   = Font.system(size: 15, weight: .medium).monospacedDigit()
        static let button       = Font.system(size: 13, weight: .semibold)      // UPPERCASE + tracking
        static let time         = Font.system(size: 12, weight: .medium).monospacedDigit()
    }

    enum MetricsIOS {
        static let minTouch: CGFloat        = 44
        static let padding: CGFloat         = 16
        static let coverSize: CGFloat       = 46
        static let coverRadius: CGFloat     = 3
        static let miniCoverSize: CGFloat   = 34
        static let waveformHeight: CGFloat  = 220
        static let playheadWidth: CGFloat   = 2
        static let progressHeight: CGFloat  = 2
        static let transportHeight: CGFloat = 46
        static let transportSide: CGFloat   = 56    // Prev / Next
        static let transportMain: CGFloat   = 104   // Play / Pause
        static let bigStar: CGFloat         = 32
        static let selectionEdge: CGFloat   = 3

        /// Zoomstufen der Waveform in Takten, Standard `defaultZoomBars`.
        static let zoomBars: [Int]          = [1, 2, 4, 8, 16, 32, 64]
        static let defaultZoomBars: Int     = 8
    }
}

extension View {
    /// Formular-Sheets (Tempo, Edit, Info) im Theme: eigener Hintergrund,
    /// Navigationsleiste in `background`, Akzent in `accent`. Die
    /// System-Bausteine (Textfelder, Slider, Picker) bleiben.
    func themeForm() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .toolbarBackground(Theme.Palette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(Theme.Palette.accent)
    }
}
