import Foundation
import GRDB

/// SQLite-Repräsentation einer berechneten Waveform. Wir speichern die
/// 4 Floats pro Bin (rms/bass/mid/high) als kompakten Blob in
/// `[bin0.rms, bin0.bass, bin0.mid, bin0.high, bin1.rms, …]`-Reihenfolge.
public struct CachedWaveform: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "waveforms"

    public var url: String
    public var sample_rate: Double
    public var seconds_per_bin: Double
    public var modified_at: Double
    public var bin_count: Int
    public var bins_data: Data

    public init(url: String, data: WaveformData, modifiedAt: Date) {
        self.url = url
        self.sample_rate = data.sampleRate
        self.seconds_per_bin = data.secondsPerBin
        self.modified_at = modifiedAt.timeIntervalSince1970
        self.bin_count = data.bins.count

        // 4 Float32-Werte pro Bin in Reihenfolge rms,bass,mid,high.
        var blob = Data()
        blob.reserveCapacity(data.bins.count * 4 * MemoryLayout<Float>.size)
        for b in data.bins {
            var values: [Float] = [b.rms, b.bass, b.mid, b.high]
            values.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress {
                    blob.append(
                        UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
                        count: 4 * MemoryLayout<Float>.size
                    )
                }
            }
        }
        self.bins_data = blob
    }

    public func waveformData() -> WaveformData {
        let floatsPerBin = 4
        let floats: [Float] = bins_data.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: Float.self)
            return Array(buf)
        }
        var bins: [WaveformBin] = []
        bins.reserveCapacity(bin_count)
        var i = 0
        while i + floatsPerBin <= floats.count {
            bins.append(WaveformBin(rms:  floats[i],
                                    bass: floats[i + 1],
                                    mid:  floats[i + 2],
                                    high: floats[i + 3]))
            i += floatsPerBin
        }
        return WaveformData(bins: bins,
                            sampleRate: sample_rate,
                            secondsPerBin: seconds_per_bin)
    }

    public var modifiedAt: Date { Date(timeIntervalSince1970: modified_at) }
}
