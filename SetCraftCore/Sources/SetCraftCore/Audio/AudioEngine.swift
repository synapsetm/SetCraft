import Foundation

@MainActor
public protocol AudioEngine: AnyObject {
    func load(url: URL) throws
    func unload()
    func play()
    func pause()
    func seek(to seconds: TimeInterval)

    var rate: Double { get set }
    /// Zusätzlicher Tonhöhen-Offset (Master-Key). Die Verschiebung, die sich
    /// aus der Rate ergibt, kommt automatisch dazu — die Engine spielt ohne
    /// Key-Lock, die Tonhöhe folgt dem Tempo wie bei einem Plattenspieler.
    var pitchCents: Double { get set }

    var isPlaying: Bool { get }
    var position: TimeInterval { get }
    /// Wie `position`, aber auf jedem Zugriff frisch berechnet aus
    /// `lastRenderTime` — ohne die 30-Hz-Timer-Verzögerung. Beide Werte sind
    /// um die Ausgabe-Latenz korrigiert und meinen die **hörbare** Position,
    /// nicht die gerenderte. Für die Waveform-Playhead-Anzeige in einer
    /// `TimelineView`, damit der Cursor synchron zum hörbaren Audio läuft.
    var livePosition: TimeInterval { get }
    var duration: TimeInterval { get }
    var loadedURL: URL? { get }
}

public enum AudioEngineError: Error, Sendable {
    case fileNotLoaded
    case unsupportedFormat
    case engineStartFailed(underlying: String)
    /// Die Datei liess sich nicht (vollständig) auf das Gerät holen — typisch
    /// für eine Quelle über den FileProvider (iCloud, NAS/SMB) ohne Netz.
    case fileUnavailable(reason: String)
    /// Das Gerät hat gar keinen Netzpfad (Flugmodus), die Quelle liegt aber
    /// nicht lokal. Eigener Fall, damit die UI-Schicht eine verständliche,
    /// lokalisierte Meldung daraus machen kann statt einer Cocoa-Floskel.
    case sourceOffline
}

/// Bewusst **nicht** lokalisiert: `SetCraftCore` ist ein SwiftPM-Package ohne
/// `defaultLocalization` und ohne String-Katalog — hier abgelegte Keys würden
/// von keinem der beiden App-Kataloge erfasst und stillschweigend englisch
/// ausgeliefert. Die Conformance sorgt nur dafür, dass `localizedDescription`
/// einen lesbaren Satz statt einer Enum-Beschreibung liefert; übersetzt wird
/// in der UI-Schicht, die den Fehler in ihre eigene Meldung einbettet.
extension AudioEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotLoaded:
            "No track loaded."
        case .unsupportedFormat:
            "This audio format is not supported."
        case .engineStartFailed(let underlying):
            "The audio engine could not be started: \(underlying)"
        case .fileUnavailable(let reason):
            reason
        case .sourceOffline:
            "The device is offline and the source is not available locally."
        }
    }
}
