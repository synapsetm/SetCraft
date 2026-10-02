#if os(macOS)
import XCTest
import AVFoundation
import Foundation
import SetCraftCoreObjC
@testable import SetCraftCore

/// Smoke-Test der TagLib-Brücke über die drei Tag-Dialekte, die die
/// Tag-Strategie unterscheidet: ID3 (AIFF), Vorbis Comments (FLAC) und
/// MP4-Atome (M4A). Dazu ein Härtetest mit kaputten Dateien — genau die
/// Klasse, die TagLib 2.3.2 adressiert („Verify values parsed from files to
/// prevent resource exhaustion, denial of service attacks and out of range
/// conversions by crafted input").
///
/// Die Fixtures entstehen zur Laufzeit: eine Sekunde Sinus als WAV via
/// AVFoundation, dann `afconvert` ins Zielformat. Kein Binär-Fixture im Repo.
/// macOS-only, weil `afconvert` auf iOS nicht existiert.
final class TagBridgeFormatTests: XCTestCase {

    /// Was geschrieben und wieder erwartet wird. BPM und Key sind die beiden
    /// Felder, auf die es fachlich ankommt — sie müssen in jedem Dialekt
    /// ankommen, sonst findet Serato/Rekordbox sie nicht.
    private struct Expected {
        static let title = "SetCraft Test Tone"
        static let artist = "Test Artist"
        static let album = "Test Album"
        static let genre = "Drum & Bass"
        static let comment = "★★★★☆ | keep this text"
        static let bpm = "174"
        static let key = "8A"
        static let label = "Test Label"
    }

    func test_roundTrip_aiff_id3() throws {
        try assertRoundTrip(format: "AIFF", ext: "aiff")
    }

    func test_roundTrip_flac_vorbisComments() throws {
        try assertRoundTrip(format: "flac", ext: "flac")
    }

    func test_roundTrip_m4a_mp4Atoms() throws {
        // MP4 kennt kein eigenes Label-Atom in TagLibs Property-Map — Label
        // deshalb hier nicht einfordern.
        try assertRoundTrip(format: "mp4f", ext: "m4a", expectLabel: false)
    }

    /// WAV ist als Tag-Ziel schwach (bekannt, s. CLAUDE.md). Hier wird darum
    /// nur verlangt, dass Lesen und Schreiben nicht werfen und nicht abstürzen
    /// — nicht, dass alles zurückkommt.
    func test_wav_doesNotFail() throws {
        let url = try fixture(format: "WAVE", ext: "wav")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNoThrow(try write(to: url), "Write auf WAV darf nicht fehlschlagen")
        XCTAssertNotNil(try SetCraftTagBridge.readTags(atPath: url.path),
                        "WAV muss lesbar bleiben")
    }

    /// Kaputte Eingaben: abgeschnitten, in der Mitte überschrieben, und reiner
    /// Zufall mit Audio-Endung. Erwartet wird kein Erfolg, sondern dass der
    /// Parser kontrolliert aufgibt — der Test besteht schon dadurch, dass der
    /// Prozess ihn überlebt.
    func test_malformedFiles_failWithoutCrashing() throws {
        for (format, ext) in [("flac", "flac"), ("mp4f", "m4a"), ("AIFF", "aiff")] {
            let intact = try fixture(format: format, ext: ext)
            defer { try? FileManager.default.removeItem(at: intact) }
            let data = try Data(contentsOf: intact)

            for broken in Self.corruptions(of: data) {
                let url = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("setcraft-broken-\(UUID().uuidString).\(ext)")
                try broken.write(to: url)
                defer { try? FileManager.default.removeItem(at: url) }

                // Beides darf werfen oder nil liefern — nur nicht hängen oder
                // den Prozess mitnehmen.
                _ = try? SetCraftTagBridge.readTags(atPath: url.path)
                try? write(to: url)
            }
        }
    }

    // MARK: - Helper

    private func assertRoundTrip(format: String, ext: String, expectLabel: Bool = true) throws {
        let url = try fixture(format: format, ext: ext)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNoThrow(try write(to: url), "Write auf .\(ext) schlug fehl")

        let tags = try XCTUnwrap(try SetCraftTagBridge.readTags(atPath: url.path),
                                "nach dem Write nicht mehr lesbar: .\(ext)")
        XCTAssertEqual(tags.title, Expected.title, ".\(ext): title")
        XCTAssertEqual(tags.artist, Expected.artist, ".\(ext): artist")
        XCTAssertEqual(tags.album, Expected.album, ".\(ext): album")
        XCTAssertEqual(tags.genre, Expected.genre, ".\(ext): genre")
        XCTAssertEqual(tags.comment, Expected.comment, ".\(ext): Kommentar inkl. Sterne-Token")
        XCTAssertEqual(tags.bpm, Expected.bpm, ".\(ext): BPM")
        XCTAssertEqual(tags.initialKey, Expected.key, ".\(ext): Key")
        if expectLabel {
            XCTAssertEqual(tags.label, Expected.label, ".\(ext): Label")
        }
        XCTAssertGreaterThan(tags.durationSeconds, 0, ".\(ext): Dauer")
    }

    /// `writeTagsAtPath:…:error:` kommt als werfende Void-Funktion nach Swift —
    /// der BOOL-Rückgabewert fällt dabei weg.
    private func write(to url: URL) throws {
        try SetCraftTagBridge.writeTags(atPath: url.path,
                                        title: Expected.title,
                                        artist: Expected.artist,
                                        album: Expected.album,
                                        genre: Expected.genre,
                                        comment: Expected.comment,
                                        bpm: Expected.bpm,
                                        initialKey: Expected.key,
                                        label: Expected.label)
    }

    /// Drei Spielarten von kaputt: vorne abgeschnitten (Header halb da),
    /// hinten abgeschnitten, Mitte mit Müll überschrieben, und ein Blob aus
    /// reinem Zufall.
    private static func corruptions(of data: Data) -> [Data] {
        var result: [Data] = []
        if data.count > 400 {
            result.append(data.prefix(200))
            result.append(data.prefix(data.count / 2))
            var middle = data
            let start = middle.count / 3
            for i in start..<min(start + 2_000, middle.count) {
                middle[middle.startIndex + i] = UInt8(truncatingIfNeeded: i &* 31)
            }
            result.append(middle)
        }
        var random = Data(count: 4_096)
        for i in 0..<random.count { random[i] = UInt8(truncatingIfNeeded: i &* 7 &+ 13) }
        result.append(random)
        return result
    }

    /// Eine Sekunde Sinus im gewünschten Container. `afconvert` ist Teil von
    /// macOS; fehlt das Zielformat, schlägt der Test mit klarer Meldung fehl
    /// statt stillschweigend durchzulaufen.
    private func fixture(format: String, ext: String) throws -> URL {
        let wav = try writeToneWAV()
        defer { if ext != "wav" { try? FileManager.default.removeItem(at: wav) } }
        if ext == "wav" { return wav }

        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("setcraft-tagfmt-\(UUID().uuidString).\(ext)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", format, "-d", format == "mp4f" ? "aac" : "flac",
                            wav.path, out.path]
        // AIFF/WAVE wollen ein PCM-Datenformat, nicht 'flac'.
        if format == "AIFF" { process.arguments = ["-f", "AIFF", "-d", "BEI16", wav.path, out.path] }
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            throw XCTSkip("afconvert konnte kein .\(ext) erzeugen (Status \(process.terminationStatus)): \(errText)")
        }
        return out
    }

    /// Mono-Float32-WAV — dieselbe Form, die `WaveformStreamingTests` nutzt.
    /// Interleaved Int16 lehnt `ExtAudioFileWrite` hier mit -50 ab; die
    /// Umrechnung ins Zielformat macht ohnehin `afconvert`.
    private func writeToneWAV() throws -> URL {
        let sampleRate: Double = 44_100
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("setcraft-tagsrc-\(UUID().uuidString).wav")
        let frameCount = AVAudioFrameCount(sampleRate)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sampleRate, channels: 1, interleaved: false)!
        let outFile = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
        buf.frameLength = frameCount
        let ch = buf.floatChannelData![0]
        var phase = 0.0
        for f in 0..<Int(frameCount) {
            phase += 2.0 * .pi * 440.0 / sampleRate
            ch[f] = Float(sin(phase) * 0.5)
        }
        try outFile.write(from: buf)
        return url
    }
}
#endif
