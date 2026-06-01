import SwiftUI
import SetifyCore

struct LibraryView: View {
    @Bindable var library: LibraryViewModel
    let onLoadInPlayer: (Track) -> Void

    /// Persistente Konfiguration von Spaltenreihenfolge und -sichtbarkeit.
    /// `TableColumnCustomization` schreibt automatisch JSON in den AppStorage-
    /// Schlüssel und liest beim Start daraus zurück. Sichtbarkeit wird per
    /// Kontextmenü auf den Header umgeschaltet, Reihenfolge per Drag.
    @AppStorage("librarytable.columns") private var columnsRaw: String = ""
    @State private var columnCustomization = TableColumnCustomization<Track>()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            table
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                library.chooseFolder()
            } label: {
                Label("Ordner wählen…", systemImage: "folder")
            }

            if let folder = library.folderURL {
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if library.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("\(library.tracks.count) gefunden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !library.tracks.isEmpty {
                Text("\(library.tracks.count) Tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = library.lastWriteError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(error)
            }
            if let error = library.lastAnalysisError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
            }

            Menu {
                ForEach(BPMRangePreset.allCases) { preset in
                    Button {
                        library.bpmPreset = preset
                    } label: {
                        if library.bpmPreset == preset {
                            Label(preset.displayName, systemImage: "checkmark")
                        } else {
                            Text(preset.displayName)
                        }
                    }
                }
            } label: {
                Label("BPM: \(library.bpmPreset.displayName)", systemImage: "waveform")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("BPM-Erwartungsbereich für die Oktav-Korrektur")

            Button {
                library.analyzeAllMissing()
            } label: {
                let missing = library.tracks.filter { $0.bpm == nil || $0.key == nil }.count
                if library.pendingAnalysisCount > 0 {
                    Label("Analysiere (\(library.pendingAnalysisCount))", systemImage: "wand.and.stars")
                } else {
                    Label(
                        missing > 0 ? "Fehlende analysieren (\(missing))" : "Analysieren",
                        systemImage: "wand.and.stars"
                    )
                }
            }
            .disabled(library.tracks.allSatisfy { $0.bpm != nil && $0.key != nil })

            Button {
                library.saveAllNow()
            } label: {
                Label(
                    library.hasUnsavedChanges
                        ? "Speichern (\(library.unsavedTrackIDs.count))"
                        : "Speichern",
                    systemImage: "square.and.arrow.down"
                )
            }
            .disabled(!library.hasUnsavedChanges)
            .keyboardShortcut("s", modifiers: .command)
        }
    }

    private var table: some View {
        Table(
            library.sortedTracks,
            selection: $library.selectedTrackID,
            sortOrder: $library.sortOrder,
            columnCustomization: $columnCustomization
        ) {
            // Status-Spalte: immer sichtbar, nicht sortier-/verschiebbar.
            TableColumn("●") { track in
                Circle()
                    .fill(library.unsavedTrackIDs.contains(track.id) ? Color.red : Color.clear)
                    .frame(width: 8, height: 8)
                    .help(library.unsavedTrackIDs.contains(track.id) ? "Ungespeicherte Änderungen" : "")
            }
            .width(14)
            .customizationID("status")
            .disabledCustomizationBehavior([.visibility, .reorder])

            TableColumn("Titel", value: \.title) { track in
                TextField("Titel", text: binding(track, \.title))
                    .textFieldStyle(.plain)
            }
            .customizationID("title")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Artist", value: \.artist) { track in
                TextField("Artist", text: binding(track, \.artist))
                    .textFieldStyle(.plain)
            }
            .customizationID("artist")

            TableColumn("BPM", value: \.bpmSortable) { track in
                HStack(spacing: 4) {
                    TextField("BPM", text: bpmBinding(for: track))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                    if library.analysisState[track.id] == .scheduled && track.bpm == nil {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .width(min: 60, ideal: 75, max: 100)
            .customizationID("bpm")

            TableColumn("Key", value: \.keySortable) { track in
                HStack(spacing: 4) {
                    Text(track.key?.description ?? "—")
                        .foregroundStyle(track.key != nil ? Color.green : Color.secondary)
                        .monospacedDigit()
                    if library.analysisState[track.id] == .scheduled && track.key == nil {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .width(min: 50, ideal: 65, max: 80)
            .customizationID("key")

            TableColumn("Rating", value: \.rating.stars) { track in
                StarRatingView(rating: track.rating) { newRating in
                    update(track) { $0.rating = newRating }
                }
            }
            .width(min: 90, ideal: 100, max: 120)
            .customizationID("rating")

            TableColumn("Genre", value: \.genre) { track in
                TextField("Genre", text: binding(track, \.genre))
                    .textFieldStyle(.plain)
            }
            .width(min: 80, ideal: 120)
            .customizationID("genre")

            TableColumn("Kommentar", value: \.comment) { track in
                TextField("Kommentar", text: binding(track, \.comment))
                    .textFieldStyle(.plain)
            }
            .width(min: 100, ideal: 180)
            .customizationID("comment")

            TableColumn("Zeit", value: \.durationSeconds) { track in
                Text(formatTime(track.durationSeconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 55, max: 70)
            .customizationID("time")
        }
        .onAppear { restoreColumnCustomization() }
        .onChange(of: columnCustomization) { _, _ in persistColumnCustomization() }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            Button("In Player laden") {
                loadFirst(ids)
            }
            .disabled(ids.isEmpty)
        } primaryAction: { ids in
            loadFirst(ids)
        }
    }

    // MARK: - Bindings

    private func binding<T>(_ track: Track, _ keyPath: WritableKeyPath<Track, T>) -> Binding<T> {
        Binding(
            get: {
                library.tracks.first(where: { $0.id == track.id })?[keyPath: keyPath]
                    ?? track[keyPath: keyPath]
            },
            set: { newValue in
                update(track) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    /// BPM wird im UI als String editiert; leeres Feld = `nil`.
    private func bpmBinding(for track: Track) -> Binding<String> {
        Binding(
            get: {
                let current = library.tracks.first(where: { $0.id == track.id })?.bpm ?? track.bpm
                guard let bpm = current else { return "" }
                return bpm.rounded() == bpm
                    ? String(Int(bpm))
                    : String(format: "%.1f", bpm)
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                let parsed: Double? = trimmed.isEmpty
                    ? nil
                    : Double(trimmed.replacingOccurrences(of: ",", with: "."))
                update(track) { $0.bpm = parsed }
            }
        )
    }

    private func update(_ track: Track, _ mutate: (inout Track) -> Void) {
        guard let idx = library.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        mutate(&library.tracks[idx])
        library.scheduleSave(library.tracks[idx])
    }

    private func loadFirst(_ ids: Set<Track.ID>) {
        guard
            let id = ids.first,
            let track = library.tracks.first(where: { $0.id == id })
        else { return }
        onLoadInPlayer(track)
    }

    private func formatTime(_ secs: TimeInterval) -> String {
        guard secs.isFinite, secs >= 0 else { return "0:00" }
        let total = Int(secs.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Spalten-Persistenz

    /// `TableColumnCustomization` ist Codable; wir serialisieren als JSON
    /// in den AppStorage-Schlüssel.
    private func persistColumnCustomization() {
        guard let data = try? JSONEncoder().encode(columnCustomization),
              let json = String(data: data, encoding: .utf8) else { return }
        columnsRaw = json
    }

    private func restoreColumnCustomization() {
        guard !columnsRaw.isEmpty,
              let data = columnsRaw.data(using: .utf8),
              let restored = try? JSONDecoder().decode(TableColumnCustomization<Track>.self, from: data)
        else { return }
        columnCustomization = restored
    }
}

/// Sortier-Helfer für Optional-Spalten: `KeyPathComparator` möchte einen
/// `Comparable`-Pfad, `Optional` ist aber nicht von Haus aus Comparable.
extension Track {
    /// BPM zum Sortieren: nil sortiert ganz nach unten (-1).
    var bpmSortable: Double { bpm ?? -1 }
    /// Key zum Sortieren: Camelot-String (z. B. "8A"), nil → "" (oben).
    var keySortable: String { key?.description ?? "" }
}

