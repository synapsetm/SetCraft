import Foundation

/// Merkt sich über App-Starts hinweg, welche Quelle zuletzt aktiv war.
///
/// Bewusst `UserDefaults` und nicht die Datenbank: das ist eine reine
/// Anzeige-Präferenz, kein Bibliotheksinhalt. Geht der Wert verloren (frische
/// Installation, gelöschte Quelle), fällt `resolve(in:)` auf die zuletzt
/// hinzugefügte Quelle zurück — das bisherige Verhalten.
///
/// Wird von beiden Plattformen benutzt (`LibraryViewModel` auf dem Mac,
/// `LibraryStore` auf iOS), damit der Schlüssel nicht auseinanderdriftet.
public enum LastSelectedSource {
    private static let key = "lastSelectedFolderID"

    /// ID der zuletzt aktiven Quelle. `nil` löscht den Eintrag.
    public static var id: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// Quelle, die beim Start aktiviert werden soll: die zuletzt aktive,
    /// sofern sie noch existiert — sonst die zuletzt hinzugefügte.
    public static func resolve(in folders: [FolderRecord]) -> FolderRecord? {
        if let id, let remembered = folders.first(where: { $0.id == id }) {
            return remembered
        }
        return folders.last
    }
}
