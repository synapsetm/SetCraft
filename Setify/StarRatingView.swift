import SwiftUI
import SetifyCore

struct StarRatingView: View {
    let rating: Rating
    let onChange: (Rating) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                let filled = star <= rating.stars
                Image(systemName: filled ? "star.fill" : "star")
                    .imageScale(.small)
                    .foregroundStyle(filled ? Color.yellow : Color.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let next = rating.stars == star ? 0 : star
                        onChange(Rating(stars: next))
                    }
            }
        }
    }
}
