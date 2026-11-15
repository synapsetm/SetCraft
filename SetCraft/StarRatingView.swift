import SwiftUI
import SetCraftCore

/// Fünf Sterne, alle gefüllt; gesetzte in `star`, offene in `starDim` (B6).
/// `size` nil = Bibliotheksgrösse, sonst Punktgrösse (Transport-Zeile: 17).
struct StarRatingView: View {
    let rating: Rating
    var size: CGFloat? = nil
    let onChange: (Rating) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                let filled = star <= rating.stars
                starImage
                    .foregroundStyle(filled ? Theme.Palette.star : Theme.Palette.starDim)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let next = rating.stars == star ? 0 : star
                        onChange(Rating(stars: next))
                    }
            }
        }
    }

    @ViewBuilder
    private var starImage: some View {
        if let size {
            Image(systemName: "star.fill").font(.system(size: size))
        } else {
            Image(systemName: "star.fill").imageScale(.small)
        }
    }
}
