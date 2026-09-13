//
//  MetadataFixSheet.swift
//  SetCraft iOS
//

import SwiftUI
import SetCraftCore

/// Review-Screen für die Tag-Ergänzung.
///
/// Wie auf dem Mac gilt: Vorschläge werden **nie** automatisch geschrieben.
/// Pro Feld steht nebeneinander, was in der Datei steht, was vorgeschlagen
/// wird, welche Stufe es vorschlägt und wie verlässlich das ist. Angehakt ist
/// zunächst nur, was fehlt und als sicher gilt.
struct MetadataFixSheet: View {

    @Bindable var store: MetadataFixStore
    let onClose: () -> Void

    @AppStorage("metadata.catalogPolicy") private var policyRaw = CatalogCheckPolicy.whenUncertain.rawValue
    @AppStorage("metadata.fields") private var fieldsRaw = MetadataField.allCases.map(\.rawValue).joined(separator: ",")
    @AppStorage("discogs.token") private var discogsToken = ""

    @State private var scope: MetadataFixStore.Scope = .missing
    @State private var showOptions = false

    var body: some View {
        NavigationStack {
            List {
                controlSection
                if showOptions { optionsSection }
                if store.proposals.isEmpty {
                    emptySection
                } else {
                    ForEach($store.proposals) { $proposal in
                        ProposalSection(proposal: $proposal)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Complete missing tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onClose)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        Task { await store.applyAccepted() }
                    }
                    .disabled(store.acceptedFieldCount == 0)
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .bottomBar) {
                    bottomBar
                }
            }
        }
        .onAppear {
            // Ohne vorherigen Lauf sind die Optionen das Erste, was interessiert.
            showOptions = !store.didRun
        }
    }

    // MARK: - Steuerung

    private var controlSection: some View {
        Section {
            Picker("Tracks", selection: $scope) {
                ForEach(MetadataFixStore.Scope.allCases) { option in
                    Text(scopeLabel(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(store.isRunning)

            Picker("Catalog check", selection: $policyRaw) {
                ForEach(CatalogCheckPolicy.allCases, id: \.rawValue) { option in
                    Text(policyLabel(option)).tag(option.rawValue)
                }
            }
            .disabled(store.isRunning)

            if store.isRunning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("\(store.processed) of \(store.total)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { store.cancel() }
                }
            } else {
                Button {
                    store.start(scope: scope, settings: settings)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(store.tracks(for: scope).isEmpty)
            }

            if !store.isRunning, store.estimatedSeconds >= 30, store.proposals.isEmpty {
                Text("Estimated runtime: \(durationText(store.estimatedSeconds))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Toggle("Discogs options", isOn: $showOptions)
                .font(.footnote)
        } footer: {
            Text("Discogs costs two requests per track. “Only when uncertain” asks just for the doubtful ones.")
        }
    }

    private var optionsSection: some View {
        Section {
            HStack {
                Text("Personal access token")
                    .font(.footnote)
                Spacer()
                SecureField("optional", text: $discogsToken)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            ForEach(MetadataField.allCases, id: \.rawValue) { field in
                Toggle(fieldName(field), isOn: binding(for: field))
                    .disabled(MetadataField.core.contains(field))
            }
        } header: {
            Text("Fields to complete")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Reading works without an account. A token raises the limit from 25 to 60 requests per minute. It is stored in this app’s preferences in plain text.")
                Text("Artist and title are always included. Genre is deliberately left out — Discogs styles would overwrite your own curation.")
            }
        }
    }

    private var emptySection: some View {
        Section {
            if store.isRunning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for suggestions…")
                        .foregroundStyle(.secondary)
                }
            } else if store.didRun {
                Label("No suggestions — nothing to complete here.", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pick a set of tracks and press Start.")
                    Text("\(store.tracks(for: scope).count) tracks in scope")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Menu {
                Button("Select all missing") { store.setAllAccepted(true, onlyMissingValues: true) }
                Button("Only high confidence") { store.acceptHighConfidenceOnly() }
                Button("Clear selection") { store.setAllAccepted(false, onlyMissingValues: false) }
            } label: {
                Label("Selection", systemImage: "checklist")
            }
            .disabled(store.proposals.isEmpty)

            Spacer()

            Text("\(store.acceptedTrackCount) tracks · \(store.acceptedFieldCount) fields")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
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

    private func scopeLabel(_ scope: MetadataFixStore.Scope) -> String {
        let count = store.tracks(for: scope).count
        switch scope {
        case .missing: return String(localized: "Missing tags (\(count))")
        case .all:     return String(localized: "All tracks (\(count))")
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

// MARK: - Ein Vorschlag

private struct ProposalSection: View {
    @Binding var proposal: MetadataProposal

    var body: some View {
        Section {
            ForEach($proposal.fields) { $field in
                Button {
                    field.isAccepted.toggle()
                } label: {
                    FieldRow(field: field)
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack(spacing: 6) {
                Text(proposal.url.lastPathComponent)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                ConfidenceDot(confidence: proposal.confidence)
            }
        } footer: {
            if !proposal.notes.isEmpty {
                Text(proposal.notes.map(noteText).joined(separator: " · "))
            }
        }
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: field.isAccepted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(field.isAccepted ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(fieldName(field.field))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(field.value)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    ConfidenceDot(confidence: field.confidence)
                }
                HStack(spacing: 6) {
                    Text(field.currentValue.isEmpty ? "—" : field.currentValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if field.isOverwrite {
                        Text("overwrites")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 4)
                    Text(sourceName(field.source))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

private struct ConfidenceDot: View {
    let confidence: Double

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }

    private var color: Color {
        switch SuggestionConfidence.level(confidence) {
        case .high:   return .green
        case .medium: return .orange
        case .low:    return .red
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
    case .folderName:       return String(localized: "Folder name")
    case .libraryDuplicate: return String(localized: "Library twin")
    case .catalog:          return String(localized: "Discogs")
    }
}
