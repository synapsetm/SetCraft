//
//  TrackInfoSheet.swift
//  SetCraft iOS
//
//  Created by BeatBuehler on 04.06.2026.
//

import SwiftUI
import SetCraftCore

/// Read-only Datei- und Audio-Eigenschaften — analog zu den Library-Spalten
/// der Mac-App (Type, Bitrate, Size, Year). Wird aus dem Library-Swipe-Right
/// vor dem Edit-Button angeboten.
struct TrackInfoSheet: View {
    let track: Track

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("File") {
                    LabeledContent("Name", value: track.fileName)
                    LabeledContent("Type", value: track.fileType.isEmpty ? "—" : track.fileType)
                    LabeledContent("Size", value: formattedSize)
                    LabeledContent("Duration", value: formattedDuration)
                }

                Section("Encoding") {
                    LabeledContent("Bitrate", value: formattedBitrate)
                }

                Section("Metadata") {
                    LabeledContent("Title", value: track.title.isEmpty ? "—" : track.title)
                    LabeledContent("Artist", value: track.artist.isEmpty ? "—" : track.artist)
                    LabeledContent("Album", value: track.album.isEmpty ? "—" : track.album)
                    LabeledContent("Label", value: track.label.isEmpty ? "—" : track.label)
                    LabeledContent("Genre", value: track.genre.isEmpty ? "—" : track.genre)
                    LabeledContent("Year", value: track.year.map { String($0) } ?? "—")
                    LabeledContent("BPM", value: track.bpm.map { String(format: "%.1f", $0) } ?? "—")
                    LabeledContent("Key", value: track.key?.description ?? "—")
                    LabeledContent("Rating", value: ratingDescription)
                }

                Section("Path") {
                    Text(track.url.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var formattedSize: String {
        guard let bytes = track.fileSize else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private var formattedDuration: String {
        let total = max(0, Int(track.durationSeconds.rounded()))
        let m = total / 60
        let s = total % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    private var formattedBitrate: String {
        guard let kbps = track.bitrate else { return "—" }
        return "\(kbps) kbps"
    }

    private var ratingDescription: String {
        let stars = track.rating.stars
        return stars == 0 ? "—" : String(repeating: "★", count: stars)
    }
}
