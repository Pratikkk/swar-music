import AudioToolbox
import Foundation
import Accelerate
import CryptoKit

/// Analysis owns a separate decoder; it never touches playback buffers or device state.
public enum WaveformAnalysis {
    public static let bucketCount = 512

    public static func peaks(decoder: any AudioDecoding, timeLimit: TimeInterval = 8) throws -> [Float] {
        try analyze(decoder: decoder, timeLimit: timeLimit, energyWeighted: false)
    }

    /// RMS describes sustained energy; a smaller peak contribution retains short transients.
    public static func envelope(decoder: any AudioDecoding, timeLimit: TimeInterval = 8) throws -> [Float] {
        try analyze(decoder: decoder, timeLimit: timeLimit, energyWeighted: true)
    }

    private static func analyze(decoder: any AudioDecoding, timeLimit: TimeInterval, energyWeighted: Bool) throws -> [Float] {
        let format = decoder.pcmFormat
        let channels = Int(format.mChannelsPerFrame)
        let frameBytes = Int(format.mBytesPerFrame)
        let bits = Int(format.mBitsPerChannel)
        let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard decoder.frameCount > 0, channels > 0, channels <= 8, frameBytes > 0,
              frameBytes % channels == 0, format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              floating ? [32, 64].contains(bits) : [8, 16, 20, 24, 32].contains(bits) else {
            throw AudioFailure("Waveform analysis does not support this PCM format.")
        }
        let sampleBytes = frameBytes / channels
        guard sampleBytes == (bits + 7) / 8 else { throw AudioFailure("Unsupported waveform sample layout.") }
        let bigEndian = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let signed = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let highAligned = format.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 16384 * frameBytes, alignment: 16)
        defer { buffer.deallocate() }
        let started = ProcessInfo.processInfo.systemUptime
        var peaks = [Float](repeating: 0, count: bucketCount)
        var energy = [Double](repeating: 0, count: bucketCount)
        var counts = [Int](repeating: 0, count: bucketCount)
        var position: Int64 = 0

        // Fast-path sample extractors for common formats
        let sampleExtractor: (UnsafeRawPointer, Int, Int) -> Double
        let channelStride = frameBytes / channels

        if floating {
            if bits == 32 {
                sampleExtractor = { ptr, frame, channel in
                    let floatPtr = ptr.assumingMemoryBound(to: Float32.self)
                    return Double(floatPtr[frame * channels + channel])
                }
            } else { // Float64
                sampleExtractor = { ptr, frame, channel in
                    let doublePtr = ptr.assumingMemoryBound(to: Float64.self)
                    return doublePtr[frame * channels + channel]
                }
            }
        } else {
            switch bits {
            case 16:
                sampleExtractor = { ptr, frame, channel in
                    let int16Ptr = ptr.assumingMemoryBound(to: Int16.self)
                    let raw = int16Ptr[frame * channels + channel]
                    return Double(raw) / Double(Int16.max)
                }
            case 24, 20:
                // 24-bit (stored as 3 bytes) and 20-bit (in 3 bytes, low-aligned 24-bit container)
                sampleExtractor = { ptr, frame, channel in
                    let baseOffset = frame * frameBytes + channel * 3
                    var raw: UInt32 = 0
                    if bigEndian {
                        raw = UInt32(ptr.load(fromByteOffset: baseOffset, as: UInt8.self)) << 16
                        raw |= UInt32(ptr.load(fromByteOffset: baseOffset + 1, as: UInt8.self)) << 8
                        raw |= UInt32(ptr.load(fromByteOffset: baseOffset + 2, as: UInt8.self))
                    } else {
                        raw = UInt32(ptr.load(fromByteOffset: baseOffset, as: UInt8.self))
                        raw |= UInt32(ptr.load(fromByteOffset: baseOffset + 1, as: UInt8.self)) << 8
                        raw |= UInt32(ptr.load(fromByteOffset: baseOffset + 2, as: UInt8.self)) << 16
                    }
                    if highAligned { raw >>= 8 }
                    if bits == 20 { raw &= 0xFFFFF }
                    let range = UInt32(1) << bits
                    let half = Float(range / 2)
                    let value = signed ? (raw >= range / 2 ? Float(Int32(raw) - Int32(range)) : Float(raw)) : Float(raw) - half
                    return Double(value / half)
                }
            case 32:
                sampleExtractor = { ptr, frame, channel in
                    let int32Ptr = ptr.assumingMemoryBound(to: Int32.self)
                    let raw = int32Ptr[frame * channels + channel]
                    return Double(raw) / Double(Int32.max)
                }
            case 8:
                sampleExtractor = { ptr, frame, channel in
                    let uint8Ptr = ptr.assumingMemoryBound(to: UInt8.self)
                    let raw = uint8Ptr[frame * channels + channel]
                    return Double(raw) / Double(UInt8.max)
                }
            default:
                // Fallback for unsupported bit depths
                sampleExtractor = { ptr, frame, channel in
                    let baseOffset = frame * frameBytes + channel * sampleBytes
                    var raw: UInt64 = 0
                    for byte in 0..<sampleBytes {
                        let shift = (bigEndian ? sampleBytes - byte - 1 : byte) * 8
                        raw |= UInt64(ptr.load(fromByteOffset: baseOffset + byte, as: UInt8.self)) << shift
                    }
                    if floating {
                        return bits == 32 ? Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw))) : Double(bitPattern: raw)
                    } else {
                        if highAligned { raw >>= sampleBytes * 8 - bits }
                        let range = UInt64(1) << bits
                        raw &= range - 1
                        let half = Int64(range / 2)
                        let value = signed ? (raw >= range / 2 ? Int64(raw) - Int64(range) : Int64(raw)) : Int64(raw) - half
                        return Double(value) / Double(half)
                    }
                }
            }
        }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 16384 * frameBytes, alignment: 16)
        defer { buffer.deallocate() }
        let started = ProcessInfo.processInfo.systemUptime
        var peaks = [Float](repeating: 0, count: bucketCount)
        var energy = [Double](repeating: 0, count: bucketCount)
        var counts = [Int](repeating: 0, count: bucketCount)
        var position: Int64 = 0
        while position < decoder.frameCount {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - started < timeLimit else {
                throw AudioFailure("Waveform analysis exceeded its background time budget.")
            }
            let frames = try decoder.read(into: buffer, frames: UInt32(min(16384, decoder.frameCount - position)))
            guard frames > 0 else { break }
            let ptr = buffer.assumingMemoryBound(to: UInt8.self)
            let frameStep = max(1, Int(frames) / 256)
            for frame in stride(from: 0, to: Int(frames), by: frameStep) {
                var peak: Float = 0
                var frameEnergy = 0.0
                for channel in 0..<channels {
                    let sample = sampleExtractor(buffer, frame, channel)
                    if sample.isFinite {
                        let amplitude = min(1, abs(sample))
                        peak = max(peak, Float(amplitude))
                        if energyWeighted { frameEnergy += amplitude * amplitude }
                    }
                }
                let bucket = min(bucketCount - 1, Int(Double(position + Int64(frame)) / Double(decoder.frameCount) * Double(bucketCount)))
                peaks[bucket] = max(peaks[bucket], peak)
                if energyWeighted {
                    energy[bucket] += frameEnergy / Double(channels)
                    counts[bucket] += 1
                }
            }
            position += Int64(frames)
        }
        guard position > 0 else { throw AudioFailure("No audio was available for a waveform.") }
        if energyWeighted {
            return peaks.indices.map { index in
                guard counts[index] > 0 else { return 0 }
                let rms = sqrt(energy[index] / Double(counts[index]))
                return Float(min(1, 0.82 * rms + 0.18 * Double(peaks[index])))
            }
        }
        return peaks
    }
}

public actor WaveformStore {
    public static let shared = WaveformStore()
    private struct Key: Hashable, Sendable {
        let path: String
        let size: Int
        let modified: Double
        var filename: String {
            SHA256.hash(data: Data("waveform-v2-energy|\(path)|\(size)|\(modified)".utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
        }
    }
    private struct Job {
        let id: UUID
        let task: Task<[Float], Error>
        var waiters: Set<UUID>
    }
    private let directory: URL?
    private var memory: [Key: [Float]] = [:]
    private var order: [Key] = []
    private var jobs: [Key: Job] = [:]
    private var failures: [Key: Date] = [:]
    
    // Memory bounds
    private let maxMemoryEntries = 32        // Max cached waveforms in memory
    private let maxMemoryBytes = 4 * 1024 * 1024  // 4 MB max for waveform data
    private let maxJobs = 16                 // Max concurrent analysis jobs
    private let maxFailures = 32             // Max tracked failures

    public init(directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Swar/Waveforms")) {
        self.directory = directory
    }
    
    /// Evicts oldest entries when memory or entry limits are exceeded
    private func enforceMemoryLimits() {
        // Enforce entry count limit
        while memory.count > maxMemoryEntries {
            if let oldest = order.first {
                memory.removeValue(forKey: oldest)
                order.removeFirst()
            } else { break }
        }
        
        // Enforce approximate byte limit (each waveform ~bucketCount * 4 bytes + overhead)
        let bytesPerWaveform = WaveformAnalysis.bucketCount * 4 + 256  // ~2.3 KB per waveform
        let estimatedBytes = memory.count * bytesPerWaveform
        while estimatedBytes > maxMemoryBytes && !order.isEmpty {
            if let oldest = order.first {
                memory.removeValue(forKey: oldest)
                order.removeFirst()
            } else { break }
        }
        
        // Enforce jobs limit
        while jobs.count > maxJobs {
            if let oldestKey = jobs.keys.first {
                if let job = jobs[oldestKey], job.waiters.isEmpty {
                    job.task.cancel()
                }
                jobs.removeValue(forKey: oldestKey)
            } else { break }
        }
        
        // Enforce failures limit
        while failures.count > maxFailures {
            if let oldestKey = failures.keys.min(by: { failures[$0]! < failures[$1]! }) {
                failures.removeValue(forKey: oldestKey)
            } else { break }
        }
    }
    
    /// Cleans up stale failures older than 5 minutes
    private func cleanupStaleFailures() {
        let now = Date()
        let staleThreshold: TimeInterval = 300  // 5 minutes
        for (key, date) in failures {
            if now.timeIntervalSince(date) > staleThreshold {
                failures.removeValue(forKey: key)
            }
        }
    }
    
    /// Called when a track is skipped or removed - cancels any pending analysis
    public func cancelForURL(_ url: URL, accessRoot: URL) async {
        let key = try? await Self.key(url: url, root: accessRoot)
        guard let key else { return }
        
        if let job = jobs[key], job.waiters.isEmpty {
            job.task.cancel()
            jobs.removeValue(forKey: key)
        }
        // Also remove from memory if present
        memory.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }
    
    /// Returns current memory usage statistics
    public func memoryStats() -> (entries: Int, estimatedBytes: Int, jobs: Int, failures: Int) {
        let bytesPerWaveform = WaveformAnalysis.bucketCount * 4 + 256
        return (memory.count, memory.count * bytesPerWaveform, jobs.count, failures.count)
    }

    public func waveform(url: URL, accessRoot: URL, codecDirectory: URL? = nil) async throws -> [Float] {
        try Task.checkCancellation()
        let key = try await Task.detached(priority: .utility) { try Self.key(url: url, root: accessRoot) }.value
        try Task.checkCancellation()
        if let cached = memory[key] { return cached }
        if let failed = failures[key], Date().timeIntervalSince(failed) < 60 {
            throw AudioFailure("A waveform is unavailable for this file.")
        }
        let waiter = UUID()
        let job: Job
        if var existing = jobs[key] {
            existing.waiters.insert(waiter); jobs[key] = existing; job = existing
        } else {
            // Enforce limits before starting new job
            enforceMemoryLimits()
            cleanupStaleFailures()
            
            let directory = directory
            let task = Task.detached(priority: .utility) {
                let acquired = accessRoot.startAccessingSecurityScopedResource()
                defer { if acquired { accessRoot.stopAccessingSecurityScopedResource() } }
                try Task.checkCancellation()
                if let directory, let cached = Self.readCache(directory.appendingPathComponent(key.filename)) { return cached }
                let decoder = try DecoderFactory.open(url: url, codecDirectory: codecDirectory)
                let result = try WaveformAnalysis.envelope(decoder: decoder)
                try Task.checkCancellation()
                guard try Self.key(url: url, root: accessRoot) == key else { throw AudioFailure("The song changed during waveform analysis.") }
                if let directory { Self.writeCache(result, key: key, directory: directory) }
                return result
            }
            job = Job(id: UUID(), task: task, waiters: [waiter]); jobs[key] = job
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await job.task.value
                if jobs[key]?.id == job.id {
                    jobs[key] = nil; failures[key] = nil
                    memory[key] = result; order.append(key)
                    enforceMemoryLimits()
                }
                try Task.checkCancellation()
                return result
            } catch {
                if jobs[key]?.id == job.id {
                    jobs[key] = nil
                    if !(error is CancellationError) {
                        failures[key] = Date()
                        enforceMemoryLimits()
                    }
                }
                throw error
            }
        } onCancel: { Task { await self.release(waiter, key: key, jobID: job.id) } }
    }

    private func release(_ waiter: UUID, key: Key, jobID: UUID) {
        guard var job = jobs[key], job.id == jobID else { return }
        job.waiters.remove(waiter)
        if job.waiters.isEmpty { job.task.cancel(); jobs[key] = nil }
        else { jobs[key] = job }
    }

    private static func key(url: URL, root: URL) throws -> Key {
        let acquired = root.startAccessingSecurityScopedResource()
        defer { if acquired { root.stopAccessingSecurityScopedResource() } }
        var freshURL = url.standardizedFileURL
        freshURL.removeAllCachedResourceValues()
        let values = try freshURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else { throw AudioFailure("The waveform file is unavailable.") }
        return Key(path: url.standardizedFileURL.path, size: size, modified: modified.timeIntervalSince1970)
    }

    private static func readCache(_ url: URL) -> [Float]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32_769), data.count <= 32_768,
              let peaks = try? JSONDecoder().decode([Float].self, from: data),
              peaks.count == WaveformAnalysis.bucketCount, peaks.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        return peaks
    }

    private static func writeCache(_ peaks: [Float], key: Key, directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(peaks).write(to: directory.appendingPathComponent(key.filename), options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "json" }
            if files.count > 256 {
                let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                for file in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - 256) { try? FileManager.default.removeItem(at: file.0) }
            }
        } catch { /* The private cache is optional; playback never depends on it. */ }
    }
}
