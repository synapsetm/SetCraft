import Foundation
import Observation
import SetifyCore

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
                let result = try await cache.waveform(for: url)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    // Race: Player könnte inzwischen einen anderen Track haben.
                    guard self.currentURL == url else { return }
                    self.data = result
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
