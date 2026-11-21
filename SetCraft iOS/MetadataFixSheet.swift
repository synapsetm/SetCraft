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
    /// Liegt im Keychain, nicht in `@AppStorage` — siehe `DiscogsTokenStore`.
    @State private var discogsToken = ""

    @State private var scope: MetadataFixStore.Scope = .missing
    @State private var showOptions = false

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Theme.Palette.border.frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    controlSection
                    if showOptions { optionsSection }
                    if store.proposals.isEmpty {
                        emptySection
                    } else {
                        ForEach($store.proposals) { $proposal in
                            ProposalCard(proposal: $proposal)
                        }
                    }
                }
                .padding(Theme.MetricsIOS.padding)
            }
            .scrollDismissesKeyboard(.interactively)

            Theme.Palette.border.frame(height: 1)
            bottomBar
        }
        .background(Theme.Palette.background)
        .presentationDetents([.large])
        .presentationBackground(Theme.Palette.background)
        .onAppear {
            // Ohne vorherigen Lauf sind die Optionen das Erste, was interessiert.
            showOptions = !store.didRun
            discogsToken = DiscogsTokenStore().load()
        }
        .onChange(of: discogsToken) { _, token in DiscogsTokenStore().save(token) }
    }

    // MARK: - Kopf

    private var sheetHeader: some View {
        HStack {
            Text("Complete missing tags")
                .themeSheetTitle()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: Theme.MetricsIOS.minTouch, height: Theme.MetricsIOS.minTouch)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
        }
        .padding(.leading, Theme.MetricsIOS.padding)
        .padding(.trailing, 4)
        .padding(.top, 8)
    }

    // MARK: - Steuerung

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                selectBox(title: "Tracks", value: scopeLabel(scope)) {
                    Picker("Tracks", selection: $scope) {
                        ForEach(MetadataFixStore.Scope.allCases) { option in
                            Text(scopeLabel(option)).tag(option)
                        }
                    }
                }
                selectBox(title: "Catalog check",
                          value: policyLabel(CatalogCheckPolicy(rawValue: policyRaw) ?? .whenUncertain)) {
                    Picker("Catalog check", selection: $policyRaw) {
                        ForEach(CatalogCheckPolicy.allCases, id: \.rawValue) { option in
                            Text(policyLabel(option)).tag(option.rawValue)
                        }
                    }
                }
            }
            .disabled(store.isRunning)

            if !store.isRunning, store.estimatedSeconds >= 30, store.proposals.isEmpty {
                Text("Estimated runtime: \(durationText(store.estimatedSeconds))")
                    .font(Theme.TypoIOS.rowDetail)
                    .foregroundStyle(Theme.Palette.textMuted)
            }

            Button {
                withAnimation(.easeOut(duration: 0.2)) { showOptions.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Discogs options")
                    Image(systemName: showOptions ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .themeLabel()
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Der Token gehört zu den Discogs-Einstellungen, nicht zur
            // Feldauswahl — deshalb hier und nicht unter „Zu ergänzende Felder".
            if showOptions {
                HStack {
                    Text("Personal access token")
                        .font(Theme.TypoIOS.rowDetail)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Spacer()
                    SecureField("optional", text: $discogsToken)
                        .font(Theme.TypoIOS.body)
                        .foregroundStyle(Theme.Palette.text)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 10)
                .frame(minHeight: Theme.MetricsIOS.minTouch)
                .themeField()
            }

            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Theme.TypoIOS.rowDetail)
                    .foregroundStyle(Theme.Palette.issueText)
            }

            Text("Discogs costs two requests per track. “Only when uncertain” asks just for the doubtful ones.")
                .font(Theme.TypoIOS.rowDetail)
                .foregroundStyle(Theme.Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Auswahlfeld im Mockup-Stil: Label oben, Wert mit Auswahlpfeil darunter.
    /// Das Menü enthält den bisherigen Picker unverändert.
    private func selectBox<P: View>(title: LocalizedStringKey, value: String,
                                    @ViewBuilder picker: () -> P) -> some View {
        Menu {
            picker()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .themeLabel()
                HStack(spacing: 4) {
                    Text(value)
                        .font(Theme.TypoIOS.rowDetail.weight(.medium))
                        .foregroundStyle(Theme.Palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textMuted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: Theme.MetricsIOS.minTouch, alignment: .leading)
            .themeField()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fields to complete")
                .themeLabel()

            VStack(spacing: 0) {
                // Artist und Titel lassen sich nicht abwählen. Ein ausgegrauter
                // Schalter, der trotzdem „an" zeigt, sieht aber nach Fehler aus —
                // also sagen wir es hin.
                HStack {
                    Text(coreFieldNames)
                        .foregroundStyle(Theme.Palette.text)
                    Spacer()
                    Text("always included")
                        .foregroundStyle(Theme.Palette.textMuted)
                }
                .font(Theme.TypoIOS.body)
                .frame(minHeight: Theme.MetricsIOS.minTouch)

                ForEach(optionalFields, id: \.rawValue) { field in
                    Theme.Palette.rowDivider.frame(height: 1)
                    Toggle(fieldName(field), isOn: binding(for: field))
                        .font(Theme.TypoIOS.body)
                        .foregroundStyle(Theme.Palette.text)
                        .tint(Theme.Palette.accent)
                        .frame(minHeight: Theme.MetricsIOS.minTouch)
                }
            }
            .padding(.horizontal, 10)
            .themeField()

            VStack(alignment: .leading, spacing: 6) {
                Text("Reading works without an account. A token raises the limit from 25 to 60 requests per minute. It is stored in the keychain.")
                Text("Genre is deliberately left out — Discogs styles would overwrite your own curation.")
            }
            .font(Theme.TypoIOS.rowDetail)
            .foregroundStyle(Theme.Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptySection: some View {
        Group {
            if store.isRunning {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.Palette.accent)
                    Text("Looking for suggestions…")
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            } else if store.didRun {
                Label("No suggestions — nothing to complete here.", systemImage: "checkmark.seal")
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pick a set of tracks and press Start.")
                        .foregroundStyle(Theme.Palette.text)
                    Text("\(store.tracks(for: scope).count) tracks in scope")
                        .font(Theme.TypoIOS.rowDetail)
                        .foregroundStyle(Theme.Palette.textMuted)
                }
            }
        }
        .font(Theme.TypoIOS.body)
        .padding(.vertical, 8)
    }

    // MARK: - Fusszeile

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                footerButton("Select all missing") {
                    store.setAllAccepted(true, onlyMissingValues: true)
                }
                footerButton("Only high confidence") {
                    store.acceptHighConfidenceOnly()
                }
                footerButton("Clear selection") {
                    store.setAllAccepted(false, onlyMissingValues: false)
                }
            }
            .disabled(store.proposals.isEmpty || store.isRunning)

            HStack(spacing: 8) {
                if store.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().tint(Theme.Palette.accent)
                        Text("\(store.processed) of \(store.total)")
                            .font(Theme.TypoIOS.rowDetail.monospacedDigit())
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    Button("Stop") { store.cancel() }
                        .buttonStyle(ThemeButtonStyle(height: Theme.MetricsIOS.minTouch, kind: .issue))
                        .frame(maxWidth: .infinity)
                } else {
                    Button {
                        store.start(scope: scope, settings: settings)
                    } label: {
                        Text("Start").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ThemeButtonStyle(height: Theme.MetricsIOS.minTouch, kind: .accentOutline))
                    .disabled(store.tracks(for: scope).isEmpty)
                }

                Button {
                    Task { await store.applyAccepted() }
                } label: {
                    Text("Apply \(store.acceptedFieldCount) fields").frame(maxWidth: .infinity)
                }
                .buttonStyle(ThemeButtonStyle(height: Theme.MetricsIOS.minTouch, kind: .prominent))
                .disabled(store.acceptedFieldCount == 0)
            }

            VStack(spacing: 2) {
                Text("\(store.acceptedTrackCount) tracks · \(store.acceptedFieldCount) fields")
                    .themeLabel()
                    .monospacedDigit()
                // Worauf sich Zwillings-Abgleich und Interpreten-Trennung
                // stützen — 0 erklärt sofort, warum beide Stufen schweigen.
                if store.didRun {
                    Text("Library: \(store.libraryCandidateCount) tagged tracks · \(store.knownArtistCount) artists")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(store.libraryCandidateCount == 0
                                         ? Theme.Palette.accent : Theme.Palette.textMuted)
                }
            }
        }
        .padding(.horizontal, Theme.MetricsIOS.padding)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Auswahl-Button der Fusszeile: drei teilen sich eine Zeile, lange
    /// Texte (Deutsch) dürfen auf zwei Zeilen umbrechen.
    private func footerButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ThemeButtonStyle(height: Theme.MetricsIOS.minTouch))
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

private struct ProposalCard: View {
    @Binding var proposal: MetadataProposal

    /// Mindestens ein Feld würde einen vorhandenen Wert überschreiben.
    private var hasConflict: Bool {
        proposal.fields.contains(where: \.isOverwrite)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textMuted)
                Text(proposal.url.lastPathComponent)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                ConfidenceDot(confidence: proposal.confidence)
            }

            ForEach($proposal.fields) { $field in
                FieldRow(field: $field)
            }

            if !proposal.notes.isEmpty {
                Text(proposal.notes.map(noteText).joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                .strokeBorder(hasConflict ? Theme.Palette.accent : Theme.Palette.border, lineWidth: 1)
        )
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
        case .artistsSplitUsingLibrary:
            return String(localized: "Split into several artists using names from your library")
        case .catalogOverruled:     return String(localized: "Discogs suggests another version — kept the derived value")
        case .libraryTwinKept:      return String(localized: "Discogs disagrees — kept your library’s value")
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
    @Binding var field: FieldSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    field.isAccepted.toggle()
                } label: {
                    CheckBox(isOn: field.isAccepted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(fieldName(field.field))
                .accessibilityValue(field.isAccepted ? Text("On") : Text("Off"))

                Text(fieldName(field.field))
                    .themeLabel()

                if field.isOverwrite {
                    Text("overwrites")
                        .font(Theme.Typo.label)
                        .tracking(Theme.Typo.labelTracking)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.Palette.accent)
                }

                Spacer(minLength: 4)

                if !field.alternatives.isEmpty {
                    Menu {
                        ForEach(field.alternatives) { alternative in
                            Button {
                                field.select(alternative)
                                field.isAccepted = true
                            } label: {
                                Text("\(alternative.value) — \(sourceName(alternative.source))")
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                }

                Text(sourceName(field.source))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                        .strokeBorder(Theme.Palette.borderStrong, lineWidth: 1))

                ConfidenceDot(confidence: field.confidence)
            }

            // Direkt editierbar: keine Stufe hat immer recht, und
            // manchmal weiss nur der Besitzer der Datei, wie der
            // Track heisst.
            TextField("", text: valueBinding)
                .font(Theme.TypoIOS.body)
                .foregroundStyle(Theme.Palette.text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .frame(minHeight: 40)
                .background(Theme.Palette.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1))

            // Was heute in der Datei steht.
            Text(field.currentValue.isEmpty ? "—" : field.currentValue)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textMuted)
                .lineLimit(1)
                .padding(.leading, 2)
        }
    }

    /// Tippen macht den Wert zu einer Handeingabe — und hakt die Zeile an,
    /// weil niemand etwas eintippt, das er nicht übernehmen will.
    private var valueBinding: Binding<String> {
        Binding(
            get: { field.value },
            set: { newValue in
                field.setManualValue(newValue)
                field.isAccepted = !newValue.trimmingCharacters(in: .whitespaces).isEmpty
            }
        )
    }
}

/// Eckige Checkbox: an = gefüllt in `accent` mit Haken, aus = Rahmen.
private struct CheckBox: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Metrics.radius)
            .fill(isOn ? Theme.Palette.accent : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                    .strokeBorder(isOn ? Theme.Palette.accent : Theme.Palette.borderStrong, lineWidth: 1.5)
            )
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Palette.onAccent)
                    .opacity(isOn ? 1 : 0)
            )
            .frame(width: 20, height: 20)
    }
}

/// Sicherheit eines Vorschlags: hoch grün, mittel `accent`, niedrig `issueText`.
private struct ConfidenceDot: View {
    let confidence: Double

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch SuggestionConfidence.level(confidence) {
        case .high:   return .green
        case .medium: return Theme.Palette.accent
        case .low:    return Theme.Palette.issueText
        }
    }
}

private extension View {
    /// Eingabe-/Auswahlfeld: `surface` mit `border`-Rahmen, eckig.
    func themeField() -> some View {
        self.background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                .strokeBorder(Theme.Palette.border, lineWidth: 1))
    }
}

// MARK: - Gemeinsame Beschriftungen

/// „Artist · Titel" — die Felder, die immer mitlaufen.
private var coreFieldNames: String {
    MetadataField.allCases
        .filter { MetadataField.core.contains($0) }
        .map(fieldName)
        .joined(separator: " · ")
}

/// Felder, die sich abwählen lassen.
private var optionalFields: [MetadataField] {
    MetadataField.allCases.filter { !MetadataField.core.contains($0) }
}

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
    case .manual:           return String(localized: "Typed in")
    }
}
