//
//  TagEditSheet.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import SwiftUI
import SetCraftCore

/// Vollständiges ID-Tag-Edit-Sheet — wird aus dem Library-Swipe-Right und
/// vom Player-BPM-Chip aufgerufen. Form-basierte UI mit Sektionen für Track-
/// Metadata, Musik-Eigenschaften, Rating und Kommentar. Done committed das
/// gesamte modifizierte Track-Objekt; Cancel verwirft.
struct TagEditSheet: View {
    let track: Track
    let onCommit: (Track) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var label: String
    @State private var genre: String
    @State private var yearText: String
    @State private var bpmText: String
    @State private var key: CamelotKey?
    @State private var ratingStars: Int
    @State private var comment: String

    init(track: Track, onCommit: @escaping (Track) -> Void) {
        self.track = track
        self.onCommit = onCommit
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
        _album = State(initialValue: track.album)
        _label = State(initialValue: track.label)
        _genre = State(initialValue: track.genre)
        _yearText = State(initialValue: track.year.map { String($0) } ?? "")
        _bpmText = State(initialValue: track.bpm.map { String(format: "%.1f", $0) } ?? "")
        _key = State(initialValue: track.key)
        _ratingStars = State(initialValue: track.rating.stars)
        _comment = State(initialValue: track.comment)
    }

    /// WAV speichert ID3 nur in einem RIFF-Chunk, den Serato und Rekordbox
    /// nicht zuverlässig lesen — TagLib schreibt zwar erfolgreich, das
    /// Ergebnis ist in den DJ-Apps aber häufig unsichtbar. User vorwarnen.
    private var isWAVFile: Bool {
        track.url.pathExtension.lowercased() == "wav"
    }

    var body: some View {
        NavigationStack {
            Form {
                if isWAVFile {
                    Section {
                        Label {
                            Text("WAV-Tags werden von Serato und Rekordbox unzuverlässig gelesen — Änderungen können in DJ-Apps unsichtbar bleiben.")
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Track") {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                    TextField("Album", text: $album)
                    TextField("Label", text: $label)
                    TextField("Genre", text: $genre)
                    TextField("Year", text: $yearText)
                        .keyboardType(.numberPad)
                }

                Section("Music") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("BPM")
                            Spacer()
                            TextField("—", text: $bpmText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 120)
                                .font(.system(.body, design: .monospaced))
                        }
                        HStack(spacing: 8) {
                            scaleButton(label: "÷2",   factor: 0.5)
                            scaleButton(label: "÷1.5", factor: 1.0 / 1.5)
                            scaleButton(label: "×1.5", factor: 1.5)
                            scaleButton(label: "×2",   factor: 2.0)
                        }
                    }
                    Picker("Key", selection: $key) {
                        Text("—").tag(CamelotKey?.none)
                        ForEach(Self.allCamelotKeys, id: \.self) { k in
                            Text(k.description).tag(CamelotKey?.some(k))
                        }
                    }
                }

                Section("Rating") {
                    HStack {
                        Spacer()
                        BigStarsView(value: ratingStars) { ratingStars = $0 }
                        Spacer()
                    }
                }

                Section("Comment") {
                    TextField("Comment", text: $comment, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Edit Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commit() }
                        .disabled(!isValid)
                }
            }
        }
    }

    /// Done bleibt aktiv solange BPM und Year entweder leer (= unbekannt)
    /// oder parsebar sind. Andere Felder sind freie Strings — kein Validate.
    private var isValid: Bool {
        if !bpmText.isEmpty, parsedBPM == nil { return false }
        if !yearText.isEmpty, parsedYear == nil { return false }
        return true
    }

    private var parsedBPM: Double? {
        Double(bpmText.replacingOccurrences(of: ",", with: "."))
    }

    private var parsedYear: Int? {
        Int(yearText.trimmingCharacters(in: .whitespaces))
    }

    @ViewBuilder
    private func scaleButton(label: String, factor: Double) -> some View {
        Button(label) {
            guard let current = parsedBPM else { return }
            let scaled = (current * factor * 10).rounded() / 10
            bpmText = String(format: "%.1f", scaled)
        }
        .buttonStyle(.bordered)
        .font(.system(size: 14, weight: .medium, design: .monospaced))
        .disabled(parsedBPM == nil)
    }

    private func commit() {
        var updated = track
        updated.title = title
        updated.artist = artist
        updated.album = album
        updated.label = label
        updated.genre = genre
        updated.year = yearText.isEmpty ? nil : parsedYear
        updated.bpm = bpmText.isEmpty ? nil : parsedBPM
        updated.key = key
        updated.rating = Rating(stars: ratingStars)
        updated.comment = comment
        onCommit(updated)
        dismiss()
    }

    private static let allCamelotKeys: [CamelotKey] = {
        var list: [CamelotKey] = []
        for n in 1...12 {
            for mode in [CamelotKey.Mode.minor, .major] {
                if let k = CamelotKey(number: n, mode: mode) {
                    list.append(k)
                }
            }
        }
        return list
    }()
}
