import AppKit
import Observation
import UniformTypeIdentifiers

/// Verknüpft die abspielbaren Audioformate im Finder mit SetCraft.
///
/// Die `Info.plist` meldet SetCraft nur als `Alternate`-Handler an — damit
/// steht die App unter „Öffnen mit", wird aber nie von selbst Standard. Das
/// Setzen läuft über LaunchServices (`NSWorkspace.setDefaultApplication`),
/// sandbox-tauglich und ohne zusätzliches Entitlement. Ein „Zurücksetzen"
/// bietet Apple nicht an; das geht nur über Finder → Informationen.
///
/// Bewusst nur Formate, die AVFoundation auch abspielt. Ogg/Opus scannt die
/// Library zwar (`FolderScanner.audioExtensions`), ein Doppelklick im Finder
/// liefe aber in einen Ladefehler — erst mit Phase 5c (SFBAudioEngine).
@Observable
final class DefaultPlayerAssociation {

    struct Format: Identifiable {
        /// Anzeigename, z. B. „MP3" — in allen Sprachen gleich.
        let id: String
        let extensions: [String]

        /// Der UTType, den LaunchServices pro Endung tatsächlich nachschlägt
        /// (`.m4a` → `com.apple.m4a-audio`, nicht das allgemeinere
        /// `public.mpeg-4-audio`).
        var types: [UTType] {
            extensions.compactMap { UTType(filenameExtension: $0, conformingTo: .audio) }
        }
    }

    struct Row: Identifiable {
        let format: Format
        /// Alle Standard-Apps der Endungen dieses Formats, ohne Duplikate.
        let handlers: [URL]
        let isSetCraft: Bool

        var id: String { format.id }
    }

    static let formats: [Format] = [
        Format(id: "MP3", extensions: ["mp3"]),
        Format(id: "AAC / ALAC", extensions: ["m4a", "aac"]),
        Format(id: "FLAC", extensions: ["flac"]),
        Format(id: "WAV", extensions: ["wav"]),
        Format(id: "AIFF", extensions: ["aif", "aiff", "aifc"])
    ]

    private(set) var rows: [Row] = []
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    var allSetCraft: Bool { rows.allSatisfy(\.isSetCraft) }

    /// Liest die aktuellen Standard-Apps. LaunchServices fragt nur die lokale
    /// Datenbank ab, keine Datei — kein Risiko, an einer Netz-Quelle zu hängen.
    func refresh() {
        rows = Self.formats.map { format in
            var handlers: [URL] = []
            var isSetCraft = true
            for type in format.types {
                let app = NSWorkspace.shared.urlForApplication(toOpen: type)
                if let app, !handlers.contains(app) { handlers.append(app) }
                if !Self.isSetCraft(app) { isSetCraft = false }
            }
            return Row(format: format, handlers: handlers, isSetCraft: isSetCraft)
        }
    }

    func makeDefault(for formats: [Format]) async {
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            refresh()
        }
        // Beim ersten Fehler aufhören: lehnt der Nutzer den Systemdialog ab,
        // soll für die übrigen Typen nicht gleich der nächste erscheinen.
        for type in formats.flatMap(\.types) {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    /// Vergleich über die Bundle-ID statt den Pfad: ein Debug-Build aus
    /// DerivedData und die installierte App in /Applications sind dieselbe App.
    private static func isSetCraft(_ app: URL?) -> Bool {
        guard let app, let id = Bundle(url: app)?.bundleIdentifier else { return false }
        return id == Bundle.main.bundleIdentifier
    }
}
