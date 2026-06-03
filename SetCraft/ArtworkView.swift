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
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.secondary.opacity(0.12))
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
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
