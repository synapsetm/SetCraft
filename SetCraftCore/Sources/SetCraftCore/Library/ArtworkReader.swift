import AVFoundation
import Foundation

/// Liest Cover-Art aus den Common-Metadata einer Audiodatei. AVFoundation
/// normalisiert MP3 (APIC), M4A (covr), FLAC (PICTURE) und Ogg/Vorbis in
/// dasselbe `commonIdentifierArtwork`-Item, sodass formatübergreifend ein
/// einziger Pfad reicht. Liefert die Roh-Bytes (PNG/JPEG); die Darstellung
/// (Image-Decode) übernimmt die UI-Schicht.
public enum ArtworkReader {

    public static func loadArtwork(url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.commonMetadata)
            let artworkItems = AVMetadataItem.metadataItems(
                from: metadata,
                filteredByIdentifier: .commonIdentifierArtwork
            )
            guard let item = artworkItems.first else { return nil }
            return try await item.load(.dataValue)
        } catch {
            return nil
        }
    }
}
