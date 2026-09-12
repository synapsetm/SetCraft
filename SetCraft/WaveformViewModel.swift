import Foundation
import Observation
import SetCraftCore

/// Verwaltet die Waveform-Daten zum gerade geladenen Player-Track.
/// Berechnung läuft im Hintergrund, der ViewModel ist die einzige Stelle,
/// die den `WaveformCache` kennt.
@MainActor
@Observable
final class WaveformViewModel {
    var data: WaveformData?
    var isLoading: Bool = false
    var lastError: String?

    private let cache: WaveformCache
    private var currentURL: URL?
    private var loadTask: Task<Void, Never>?

    init(cache: WaveformCache) {
        self.cache = cache
    }

    /// Wird aus ContentView.onChange(loadedURL) angestossen.
    func setActiveURL(_ url: URL?) {
        if url == currentURL { return }
        currentURL = url
        loadTask?.cancel()
        data = nil
        lastError = nil

        guard let url else {
            isLoading = false
            return
        }

        isLoading = true
        loadTask = Task { [weak self, cache] in
            do {
                // Zwischenstände: die Welle wächst von links nach rechts,
                // statt bis zum Ende der Analyse leer zu bleiben. Aus dem
                // Cache kommt sofort ein einziger, vollständiger Stand.
                for try await update in cache.stream(for: url) {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        guard let self else { return }
                        // Race: Player könnte inzwischen einen anderen Track
                        // haben.
                        guard self.currentURL == url else { return }
                        // Zwischenstände können verspätet eintreffen — nie
                        // hinter den bereits gezeigten Stand zurückfallen.
                        if let existing = self.data,
                           update.bins.count < existing.bins.count,
                           !update.isComplete {
                            return
                        }
                        self.data = update
                        self.isLoading = !update.isComplete
                    }
                }
                await MainActor.run {
                    guard let self, self.currentURL == url else { return }
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    if self.currentURL == url {
                        self.lastError = error.localizedDescription
                        self.isLoading = false
                    }
                }
            }
        }
    }
}
