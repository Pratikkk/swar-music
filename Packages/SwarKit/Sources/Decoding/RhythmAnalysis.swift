import Foundation
import AudioToolbox
import CryptoKit

public struct RhythmProfile: Codable, Sendable, Equatable {
    public let bpm: Double?
    /// Periodicity heuristic, not a calibrated probability of correctness.
    public let confidence: Double
    public let beats: [Double]
    public let duration: Double
    /// Half-second RMS energy bins for a future transition planner.
    public let energy: [Float]

    public init(bpm: Double?, confidence: Double, beats: [Double], duration: Double, energy: [Float]) {
        self.bpm = bpm; self.confidence = confidence; self.beats = beats
        self.duration = duration; self.energy = energy
    }
}

public enum RhythmAnalysis {
    /// A conservative energy-onset baseline. It does not infer downbeats, meter,
    /// vocal sections or musical phrases, and can confuse half/double tempo.
    public static func estimate(onsets: [Double], rate: Double = 100) -> RhythmProfile {
        guard rate.isFinite, (10...1000).contains(rate), onsets.count >= Int(rate * 8),
              onsets.count <= 900_000, onsets.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return RhythmProfile(bpm: nil, confidence: 0, beats: [], duration: 0, energy: [])
        }
        let duration = Double(onsets.count) / rate
        let power = onsets.reduce(0) { $0 + $1 * $1 }
        guard power > 1e-10 else { return RhythmProfile(bpm: nil, confidence: 0, beats: [], duration: duration, energy: []) }
        let mean = onsets.reduce(0, +) / Double(onsets.count)
        let centered = onsets.map { $0 - mean }
        guard centered.reduce(0, { $0 + $1 * $1 }) > 1e-10 else {
            return RhythmProfile(bpm: nil, confidence: 0, beats: [], duration: duration, energy: [])
        }
        let low = max(1, Int(rate * 60 / 180)), high = Int(rate * 60 / 60)
        var scores = [Double](repeating: 0, count: high + 2)
        for lag in low...high {
            var dot = 0.0, left = 0.0, right = 0.0
            for i in lag..<onsets.count {
                dot += centered[i] * centered[i - lag]
                left += centered[i] * centered[i]
                right += centered[i - lag] * centered[i - lag]
            }
            scores[lag] = dot / max(1e-12, sqrt(left * right))
        }
        let strongest = (low...high).max { scores[$0] < scores[$1] } ?? low
        // Prefer the first strong local peak over its half-tempo harmonic.
        let lag = (low...high).first {
            scores[$0] >= scores[strongest] * 0.90 &&
            ($0 == low || scores[$0] >= scores[$0 - 1]) &&
            ($0 == high || scores[$0] >= scores[$0 + 1])
        } ?? strongest
        let confidence = min(1, max(0, scores[lag]))
        guard confidence >= 0.25 else {
            return RhythmProfile(bpm: nil, confidence: confidence, beats: [], duration: duration, energy: [])
        }
        var period = Double(lag)
        if lag > low, lag < high {
            let denominator = scores[lag - 1] - 2 * scores[lag] + scores[lag + 1]
            if abs(denominator) > 1e-9 {
                period += max(-0.5, min(0.5, 0.5 * (scores[lag - 1] - scores[lag + 1]) / denominator))
            }
        }
        var beats: [Double] = []
        let onsetRMS = sqrt(power / Double(onsets.count))
        var tick = Double(onsets.firstIndex(where: { $0 > onsetRMS * 2 }) ?? 0)
        while tick < Double(onsets.count) {
            let radius = max(1, Int(period * 0.12))
            let start = max(0, Int(tick) - radius), end = min(onsets.count - 1, Int(tick) + radius)
            let peak = (start...end).max { onsets[$0] < onsets[$1] } ?? Int(tick)
            // Do not invent a beat in a silent passage.
            if onsets[peak] > onsetRMS * 0.5 {
                let time = Double(peak) / rate
                if beats.last.map({ time > $0 }) ?? true { beats.append(time) }
            }
            // Re-anchor to observed onsets instead of letting rounded lag error
            // accumulate over a long song with a non-integer beat period.
            tick = (onsets[peak] > onsetRMS * 0.5 ? Double(peak) : tick) + period
        }
        return RhythmProfile(bpm: min(180, max(60, 60 * rate / period)), confidence: confidence, beats: beats, duration: duration, energy: [])
    }

    public static func analyze(decoder: any AudioDecoding, timeLimit: Double = 12) throws -> RhythmProfile {
        let f = decoder.pcmFormat
        let channels = Int(f.mChannelsPerFrame), bytes = Int(f.mBytesPerFrame), bits = Int(f.mBitsPerChannel)
        let floating = f.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard f.mSampleRate.isFinite, (8000...384000).contains(f.mSampleRate), decoder.frameCount > 0,
              Double(decoder.frameCount) / f.mSampleRate <= 900,
              (1...8).contains(channels), bytes > 0, bytes % channels == 0,
              f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              floating ? [32, 64].contains(bits) : [8, 16, 20, 24, 32].contains(bits),
              bytes / channels == (bits + 7) / 8 else {
            throw AudioFailure("Rhythm analysis supports interleaved PCM songs up to 15 minutes.")
        }
        let sampleBytes = bytes / channels
        let bigEndian = f.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let signed = f.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let highAligned = f.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 8192 * bytes, alignment: 16)
        defer { buffer.deallocate() }
        let started = ProcessInfo.processInfo.systemUptime
        let count = Int(ceil(Double(decoder.frameCount) / f.mSampleRate * 100))
        var sums = [Double](repeating: 0, count: count), counts = [Int](repeating: 0, count: count)
        let stride = max(1, Int(f.mSampleRate / 4000))
        var position: Int64 = 0
        while position < decoder.frameCount {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - started < timeLimit else { throw AudioFailure("Rhythm analysis exceeded its background time budget.") }
            let frames = try decoder.read(into: buffer, frames: UInt32(min(8192, decoder.frameCount - position)))
            guard frames > 0 else { break }
            let data = buffer.assumingMemoryBound(to: UInt8.self)
            for frame in 0..<Int(frames) where (Int(position) + frame) % stride == 0 {
                var energy = 0.0
                for channel in 0..<channels {
                    let offset = frame * bytes + channel * sampleBytes
                    var raw: UInt64 = 0
                    for byte in 0..<sampleBytes { raw |= UInt64(data[offset + byte]) << ((bigEndian ? sampleBytes - byte - 1 : byte) * 8) }
                    let sample: Double
                    if floating { sample = bits == 32 ? Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw))) : Double(bitPattern: raw) }
                    else {
                        if highAligned { raw >>= sampleBytes * 8 - bits }
                        let range = UInt64(1) << bits
                        raw &= range - 1
                        let half = Int64(range / 2)
                        let value = signed ? (raw >= range / 2 ? Int64(raw) - Int64(range) : Int64(raw)) : Int64(raw) - half
                        sample = Double(value) / Double(half)
                    }
                    if sample.isFinite { energy += min(1, sample * sample) / Double(channels) }
                }
                let bin = min(count - 1, Int(Double(position + Int64(frame)) / f.mSampleRate * 100))
                sums[bin] += energy; counts[bin] += 1
            }
            position += Int64(frames)
        }
        guard position > 0, decoder.frameCount - position < Int64(f.mSampleRate) else { throw AudioFailure("The audio ended before rhythm analysis completed.") }
        var previous = 0.0
        let onsets = sums.indices.map { i -> Double in
            let level = log1p(100 * sqrt(sums[i] / Double(max(1, counts[i]))))
            defer { previous = level }
            return max(0, level - previous)
        }
        try Task.checkCancellation()
        let result = estimate(onsets: onsets)
        var energy: [Float] = []
        for start in Swift.stride(from: 0, to: count, by: 50) {
            let end = min(count, start + 50)
            let total = (start..<end).reduce(0.0) { $0 + sums[$1] }
            let samples = (start..<end).reduce(0) { $0 + counts[$1] }
            energy.append(Float(sqrt(total / Double(max(1, samples)))))
        }
        return RhythmProfile(bpm: result.bpm, confidence: result.confidence, beats: result.beats,
                             duration: Double(position) / f.mSampleRate, energy: energy)
    }
}

/// One serial analysis lane, disk cache keyed by file identity and algorithm version.
/// Closing the requesting view cancels work; analysis never uses the playback decoder.
public actor RhythmStore {
    public static let shared = RhythmStore()
    private let directory: URL?
    private var tail: Task<Void, Never>?
    public init(directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Swar/Rhythm")) { self.directory = directory }

    public func profile(url: URL, accessRoot: URL, codecDirectory: URL? = nil) async throws -> RhythmProfile {
        let previous = tail, directory = directory
        let task = Task.detached(priority: .utility) {
            await previous?.value
            try Task.checkCancellation()
            let acquired = accessRoot.startAccessingSecurityScopedResource()
            defer { if acquired { accessRoot.stopAccessingSecurityScopedResource() } }
            func fingerprint() throws -> String {
                var file = url.standardizedFileURL; file.removeAllCachedResourceValues()
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else { throw AudioFailure("The song is unavailable for analysis.") }
                return SHA256.hash(data: Data("rhythm-v1|\(file.path)|\(size)|\(modified.timeIntervalSince1970)".utf8)).map { String(format: "%02x", $0) }.joined()
            }
            let key = try fingerprint()
            let file = directory?.appendingPathComponent(key + ".json")
            if let file, let handle = try? FileHandle(forReadingFrom: file) {
                defer { try? handle.close() }
                if let data = try? handle.read(upToCount: 262145), data.count <= 262144,
                   let result = try? JSONDecoder().decode(RhythmProfile.self, from: data),
                   result.duration > 0, result.duration <= 900, (0...1).contains(result.confidence),
                   result.bpm.map({ (60...181).contains($0) }) ?? true,
                   result.beats.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= result.duration }),
                   result.energy.allSatisfy({ $0.isFinite && (0...1).contains($0) }) { return result }
            }
            let result = try RhythmAnalysis.analyze(decoder: DecoderFactory.open(url: url, codecDirectory: codecDirectory))
            try Task.checkCancellation()
            guard try fingerprint() == key else { throw AudioFailure("The song changed during rhythm analysis.") }
            if let directory, let file {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? JSONEncoder().encode(result).write(to: file, options: .atomic)
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                if files.count > 256 {
                    let sorted = files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                    for old in sorted.prefix(files.count - 256) where old.pathExtension == "json" { try? FileManager.default.removeItem(at: old) }
                }
            }
            return result
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }
}
