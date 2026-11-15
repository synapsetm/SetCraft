import SwiftUI
import SetCraftCore

/// Fünf Sterne, alle gefüllt; gesetzte in `star`, offene in `starDim` (B6).
/// `size` nil = Bibliotheksgrösse, sonst Punktgrösse (Transport-Zeile: 17).
/// `onAccent`: in einer markierten (Amber-)Zeile dunkle Sterne, sonst
/// verschwänden die Amber-Sterne auf der Amber-Fläche.
struct StarRatingView: View {
    let rating: Rating
    var size: CGFloat? = nil
    var onAccent = false
    let onChange: (Rating) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                let filled = star <= rating.stars
                starImage
                    .foregroundStyle(color(filled: filled))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let next = rating.stars == star ? 0 : star
                        onChange(Rating(stars: next))
                    }
            }
        }
    }

    private func color(filled: Bool) -> Color {
        if onAccent {
            return filled ? Theme.Palette.onAccent : Theme.Palette.onAccent.opacity(0.3)
        }
        return filled ? Theme.Palette.star : Theme.Palette.starDim
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
