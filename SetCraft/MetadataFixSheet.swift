import SwiftUI
import SetCraftCore

/// Review-Sheet für die Tag-Ergänzung.
///
/// Der Grundsatz: Vorschläge werden **nie** automatisch geschrieben. Hier steht
/// pro Feld nebeneinander, was in der Datei steht, was vorgeschlagen wird, wer
/// es vorschlägt und wie belastbar das ist. Angehakt ist zunächst nur, was
/// fehlt und was die Kette als sicher einstuft; bestehende Werte zu
/// überschreiben bleibt ein bewusster Klick.
struct MetadataFixSheet: View {

    @Bindable var model: MetadataFixViewModel
    /// Womit das Sheet aufgeht: aus dem Kontextmenü die Selektion, aus der
    /// Toolbar die Tracks mit fehlenden Tags.
    var initialScope: MetadataFixViewModel.Scope = .missing
    let onClose: () -> Void

    @AppStorage("metadata.catalogPolicy") private var policyRaw = CatalogCheckPolicy.whenUncertain.rawValue
    @AppStorage("metadata.fields") private var fieldsRaw = MetadataField.allCases.map(\.rawValue).joined(separator: ",")
    @AppStorage("discogs.token") private var discogsToken = ""

    @State private var scope: MetadataFixViewModel.Scope = .missing
    @State private var showOptions = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 520, idealHeight: 640)
        .onAppear { scope = initialScope }
    }

    // MARK: - Kopf

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Complete missing tags")
                    .font(.headline)
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 12) {
                Picker("Tracks", selection: $scope) {
                    ForEach(MetadataFixViewModel.Scope.allCases) { option in
                        Text(scopeLabel(option)).tag(option)
                    }
                }
                .fixedSize()
                .disabled(model.isRunning)

                Picker("Catalog check", selection: $policyRaw) {
                    ForEach(CatalogCheckPolicy.allCases, id: \.rawValue) { option in
                        Text(policyLabel(option)).tag(option.rawValue)
                    }
                }
                .fixedSize()
                .disabled(model.isRunning)
                .help("Discogs costs two requests per track. “Only when uncertain” asks just for the doubtful ones.")

                Spacer()

                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(model.processed) of \(model.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Stop") { model.cancel() }
                } else {
                    Button("Start") {
                        model.start(scope: scope, settings: settings)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.tracks(for: scope).isEmpty)
                }
            }

            if !model.isRunning, model.estimatedSeconds >= 30, model.proposals.isEmpty {
                Text("Estimated runtime: \(durationText(model.estimatedSeconds))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Discogs options", isExpanded: $showOptions) {
                optionsPane
                    .padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(16)
    }

    private var optionsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Personal access token")
                SecureField("optional", text: $discogsToken)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
            }
            Text("Reading works without an account. A token raises the limit from 25 to 60 requests per minute. It is stored in this app’s preferences in plain text.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            Text("Fields to complete")
                .font(.caption)
            HStack(spacing: 14) {
                ForEach(MetadataField.allCases, id: \.rawValue) { field in
                    Toggle(fieldName(field), isOn: binding(for: field))
                        .toggleStyle(.checkbox)
                        .disabled(MetadataField.core.contains(field))
                }
            }
            Text("Artist and title are always included. Genre is deliberately left out — Discogs styles would overwrite your own curation.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Liste

    @ViewBuilder
    private var content: some View {
        if model.proposals.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach($model.proposals) { $proposal in
                        ProposalCard(proposal: $proposal)
                    }
                }
                .padding(16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            if model.isRunning {
                ProgressView()
                Text("Looking for suggestions…")
                    .foregroundStyle(.secondary)
            } else if model.didRun {
                Image(systemName: "checkmark.seal")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No suggestions — nothing to complete here.")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "text.badge.plus")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Pick a set of tracks and press Start.")
                    .foregroundStyle(.secondary)
                Text("\(model.tracks(for: scope).count) tracks in scope")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Fuss

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Select all missing") { model.setAllAccepted(true, onlyMissingValues: true) }
            Button("Only high confidence") { model.acceptHighConfidenceOnly() }
            Button("Clear selection") { model.setAllAccepted(false, onlyMissingValues: false) }

            Spacer()

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Text("\(model.acceptedTrackCount) tracks · \(model.acceptedFieldCount) fields")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Apply") {
                model.applyAccepted()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.acceptedFieldCount == 0)
        }
        .padding(12)
        .disabled(model.proposals.isEmpty)
    }

    // MARK: - Einstellungen

    private var settings: MetadataFixRunner.Settings {
        MetadataFixRunner.Settings(
            fields: selectedFields,
            policy: CatalogCheckPolicy(rawValue: policyRaw) ?? .whenUncertain,
            discogsToken: discogsToken.isEmpty ? nil : discogsToken,
            userAgent: Self.userAgent
        )
    }

    /// Discogs verlangt einen User-Agent, der die App eindeutig benennt —
    /// generische Werte werden härter gedrosselt.
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "SetCraft/\(version) +https://github.com/synapsetm/SetCraft"
    }

    private var selectedFields: Set<MetadataField> {
        let stored = Set(fieldsRaw.split(separator: ",").compactMap { MetadataField(rawValue: String($0)) })
        return stored.union(MetadataField.core)
    }

    private func binding(for field: MetadataField) -> Binding<Bool> {
        Binding(
            get: { selectedFields.contains(field) },
            set: { isOn in
                var fields = selectedFields
                if isOn { fields.insert(field) } else { fields.remove(field) }
                fields.formUnion(MetadataField.core)
                fieldsRaw = MetadataField.allCases
                    .filter { fields.contains($0) }
                    .map(\.rawValue)
                    .joined(separator: ",")
            }
        )
    }

    // MARK: - Texte

    private func scopeLabel(_ scope: MetadataFixViewModel.Scope) -> String {
        let count = model.tracks(for: scope).count
        switch scope {
        case .selection: return String(localized: "Selection (\(count))")
        case .missing:   return String(localized: "Missing tags (\(count))")
        case .all:       return String(localized: "All tracks (\(count))")
        }
    }

    private func policyLabel(_ policy: CatalogCheckPolicy) -> String {
        switch policy {
        case .off:           return String(localized: "Discogs: off")
        case .whenUncertain: return String(localized: "Discogs: when uncertain")
        case .always:        return String(localized: "Discogs: always")
        }
    }

    private func durationText(_ seconds: Double) -> String {
        if seconds < 90 { return String(localized: "about \(Int(seconds.rounded())) s") }
        return String(localized: "about \(Int((seconds / 60).rounded())) min")
    }
}

// MARK: - Eine Vorschlagskarte

private struct ProposalCard: View {
    @Binding var proposal: MetadataProposal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(proposal.url.lastPathComponent)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                ConfidenceDot(confidence: proposal.confidence)
            }

            ForEach($proposal.fields) { $field in
                Toggle(isOn: $field.isAccepted) {
                    FieldRow(field: field)
                }
                .toggleStyle(.checkbox)
            }

            if !proposal.notes.isEmpty {
                Text(proposal.notes.map(noteText).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func noteText(_ note: ProposalNote) -> String {
        switch note {
        case .orderAmbiguous:       return String(localized: "Artist/title order unclear")
        case .weakSeparator:        return String(localized: "Separator was only a hyphen")
        case .noSeparator:          return String(localized: "No separator in the filename")
        case .folderPatternApplied: return String(localized: "Folder naming pattern applied")
        case .folderPatternSwapped: return String(localized: "Folder pattern: sides swapped")
        case .libraryDuplicate:     return String(localized: "Tags from a duplicate in your library")
        case .identicalFileFound:   return String(localized: "Identical file found in your library")
        case .catalogConfirmed:     return String(localized: "Confirmed by Discogs")
        case .catalogCorrected:     return String(localized: "Corrected by Discogs")
        case .catalogNoMatch:       return String(localized: "Not found on Discogs")
        case .catalogAmbiguous:     return String(localized: "Several plausible Discogs matches")
        case .catalogUnavailable:   return String(localized: "Discogs was unreachable")
        case .catalogNotChecked:    return String(localized: "Discogs not queried")
        }
    }
}

private struct FieldRow: View {
    let field: FieldSuggestion

    var body: some View {
        HStack(spacing: 8) {
            Text(fieldName(field.field))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            Text(field.currentValue.isEmpty ? "—" : field.currentValue)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Text(field.value)
                .fontWeight(field.isOverwrite ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if field.isOverwrite {
                Text("overwrites")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Text(sourceName(field.source))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())

            ConfidenceDot(confidence: field.confidence)
        }
    }
}

private struct ConfidenceDot: View {
    let confidence: Double

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(label)
    }

    private var color: Color {
        switch SuggestionConfidence.level(confidence) {
        case .high:   return .green
        case .medium: return .orange
        case .low:    return .red
        }
    }

    private var label: String {
        switch SuggestionConfidence.level(confidence) {
        case .high:   return String(localized: "High confidence")
        case .medium: return String(localized: "Medium confidence")
        case .low:    return String(localized: "Low confidence")
        }
    }
}

// MARK: - Gemeinsame Beschriftungen

private func fieldName(_ field: MetadataField) -> String {
    switch field {
    case .artist: return String(localized: "Artist")
    case .title:  return String(localized: "Title")
    case .album:  return String(localized: "Album")
    case .label:  return String(localized: "Label")
    case .year:   return String(localized: "Year")
    }
}

private func sourceName(_ source: SuggestionSource) -> String {
    switch source {
    case .filename:         return String(localized: "Filename")
    case .folderPattern:    return String(localized: "Folder pattern")
    case .libraryDuplicate: return String(localized: "Library twin")
    case .catalog:          return String(localized: "Discogs")
    }
}
