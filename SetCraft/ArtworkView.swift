import SwiftUI
import SetCraftCore

/// Zeigt das Album-Cover des geladenen Tracks. Lädt asynchron über
/// `ArtworkReader`; während des Ladens und wenn kein Cover hinterlegt ist,
/// bleibt nur der leere Rahmen stehen — die Player-Header-Höhe bleibt
/// dadurch konstant, unabhängig vom Cover-Status.
struct ArtworkView: View {
    let url: URL?
    let size: CGFloat

    @State private var image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Metrics.radius)
            .fill(Theme.Palette.surface)
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )
            .task(id: url) {
                await loadArtwork()
            }
    }

    private func loadArtwork() async {
        guard let url else {
            image = nil
            return
        }
        let data = await ArtworkReader.loadArtwork(url: url)
        if Task.isCancelled { return }
        if let data, let nsImage = NSImage(data: data) {
            image = nsImage
        } else {
            image = nil
        }
    }
}
