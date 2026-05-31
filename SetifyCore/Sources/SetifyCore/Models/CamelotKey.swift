import Foundation

public struct CamelotKey: Hashable, Sendable, CustomStringConvertible {
    public enum Mode: String, Sendable, Hashable {
        case minor = "A"
        case major = "B"
    }

    public let number: Int
    public let mode: Mode

    public init?(number: Int, mode: Mode) {
        guard (1...12).contains(number) else { return nil }
        self.number = number
        self.mode = mode
    }

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard let last = trimmed.last,
              let mode = Mode(rawValue: String(last)),
              let n = Int(trimmed.dropLast())
        else { return nil }
        self.init(number: n, mode: mode)
    }

    public var description: String { "\(number)\(mode.rawValue)" }
}
