import Foundation

public struct Rating: Hashable, Sendable, CustomStringConvertible {
    public let stars: Int

    public init(stars: Int) {
        self.stars = max(0, min(5, stars))
    }

    public static let none = Rating(stars: 0)

    public var description: String {
        String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
    }
}
