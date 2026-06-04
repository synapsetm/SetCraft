//
//  ArtworkView.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import SwiftUI
import UIKit
import SetCraftCore

/// Lädt Cover-Art async via Core-`ArtworkReader` und fällt bei fehlendem
/// Bild auf `CoverPlaceholderView` (lila Gradient + Vinyl-Icon) zurück,
/// damit der Render-Pfad und die Layout-Höhe unabhängig vom Erfolg sind.
struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    let cornerRadius: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                CoverPlaceholderView(
                    size: size,
                    cornerRadius: cornerRadius,
                    iconSize: max(12, size * 0.42)
                )
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url else { image = nil; return }
        let data = await ArtworkReader.loadArtwork(url: url)
        if Task.isCancelled { return }
        image = data.flatMap { UIImage(data: $0) }
    }
}
