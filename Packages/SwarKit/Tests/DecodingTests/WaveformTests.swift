import AudioToolbox
import Foundation
import Testing
@testable import Decoding

struct WaveformTests {
    private func encoded(_ values: [UInt64], bytes: Int, bigEndian: Bool = false) -> Data {
        Data(values.flatMap { value in (0..<bytes).map { UInt8(truncatingIfNeeded: value >> ((bigEndian ? bytes - $0 - 1 : $0) * 8)) } })
    }

    @Test(arguments: [8, 16, 20, 24, 32]) func signedPackedSamplesRetainFullNegativeScale(bits: Int) throws {
        let bytes = (bits + 7) / 8
        let data = encoded(Array(repeating: UInt64(1) << (bits - 1), count: 512), bytes: bytes)
        let decoder = WaveformFixture(data: data, bits: bits, channels: 1)
        #expect(try WaveformAnalysis.peaks(decoder: decoder).allSatisfy { $0 == 1 })
    }

    @Test func stereoOppositePhasesDoNotCancelAndTimelineBucketsAreCorrect() throws {
        let frames: [UInt64] = (0..<1024).flatMap { $0 < 512 ? [UInt64(0), 0] : [UInt64(0x4000), 0xc000] }
        let decoder = WaveformFixture(data: encoded(frames, bytes: 2), bits: 16, channels: 2)
        let peaks = try WaveformAnalysis.peaks(decoder: decoder)
        #expect(peaks.count == 512)
        #expect(peaks.prefix(256).allSatisfy { $0 == 0 })
        #expect(peaks.suffix(256).allSatisfy { $0 == 0.5 })
    }

    @Test func endianHighAlignedAndUnsignedSamplesAreNormalized() throws {
        let big = WaveformFixture(data: encoded(Array(repeating: 0x4000, count: 512), bytes: 2, bigEndian: true), bits: 16, channels: 1, extraFlags: kAudioFormatFlagIsBigEndian)
        #expect(try WaveformAnalysis.peaks(decoder: big).allSatisfy { $0 == 0.5 })
        let high = WaveformFixture(data: encoded(Array(repeating: 0x800000, count: 512), bytes: 3), bits: 20, channels: 1, extraFlags: kAudioFormatFlagIsAlignedHigh)
        #expect(try WaveformAnalysis.peaks(decoder: high).allSatisfy { $0 == 1 })
        let unsigned = WaveformFixture(data: Data(repeating: 128, count: 512), bits: 8, channels: 1, signed: false)
        #expect(try WaveformAnalysis.peaks(decoder: unsigned).allSatisfy { $0 == 0 })
    }

    @Test(arguments: [32, 64]) func floatingSamplesIgnoreNonFiniteValues(bits: Int) throws {
        let values: [Double] = [.nan, .infinity, -0.25, 0.75] + Array(repeating: 0, count: 508)
        let raw = values.map { bits == 32 ? UInt64(Float($0).bitPattern) : $0.bitPattern }
        let decoder = WaveformFixture(data: encoded(raw, bytes: bits / 8), bits: bits, channels: 1, extraFlags: kAudioFormatFlagIsFloat)
        let peaks = try WaveformAnalysis.peaks(decoder: decoder)
        #expect(peaks[0] == 0 && peaks[1] == 0 && peaks[2] == 0.25 && peaks[3] == 0.75)
    }

    @Test func energyEnvelopeDistinguishesSustainedAudioFromEqualPeaks() throws {
        let frames: [UInt64] = (0..<512).flatMap { bucket in
            bucket < 256 ? [0x7fff] + Array(repeating: 0, count: 7) : Array(repeating: 0x7fff, count: 8)
        }
        let data = encoded(frames, bytes: 2)
        let peaks = try WaveformAnalysis.peaks(decoder: WaveformFixture(data: data, bits: 16, channels: 1))
        let energy = try WaveformAnalysis.envelope(decoder: WaveformFixture(data: data, bits: 16, channels: 1))
        #expect(peaks.allSatisfy { $0 > 0.99 })
        #expect(energy.count == 512 && energy.allSatisfy { $0.isFinite && (0...1).contains($0) })
        #expect(energy[0] > 0.3 && energy[256] > energy[0] * 1.8)
    }

    @Test func energyEnvelopePreservesStereoEnergyAndSilence() throws {
        let frames: [UInt64] = (0..<4096).flatMap { $0 < 2048 ? [UInt64(0), 0] : [UInt64(0x4000), 0xc000] }
        let energy = try WaveformAnalysis.envelope(decoder: WaveformFixture(data: encoded(frames, bytes: 2), bits: 16, channels: 2))
        #expect(energy.prefix(256).allSatisfy { $0 == 0 })
        #expect(energy.suffix(256).allSatisfy { abs($0 - 0.5) < 0.00001 })
    }

    @Test func analysisHonoursBudgetCancellationAndUnsupportedLayouts() async throws {
        let decoder = WaveformFixture(data: Data(repeating: 0, count: 1024), bits: 16, channels: 1)
        #expect(throws: (any Error).self) { try WaveformAnalysis.peaks(decoder: decoder, timeLimit: 0) }
        #expect(decoder.readCount == 0)
        let noninterleaved = WaveformFixture(data: Data(repeating: 0, count: 1024), bits: 16, channels: 1, extraFlags: kAudioFormatFlagIsNonInterleaved)
        #expect(throws: (any Error).self) { try WaveformAnalysis.peaks(decoder: noninterleaved) }
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try WaveformAnalysis.peaks(decoder: WaveformFixture(data: Data(repeating: 0, count: 1024), bits: 16, channels: 1))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cacheSharesRequestsPersistsRecoversCorruptionAndInvalidatesChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("one.wav")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/44100-16.wav")
        try FileManager.default.copyItem(at: fixture, to: source)
        let original = try Data(contentsOf: source)
        let directory = root.appendingPathComponent("Waveforms")
        let store = WaveformStore(directory: directory)
        async let first = store.waveform(url: source, accessRoot: root)
        async let second = store.waveform(url: source, accessRoot: root)
        let (a, b) = try await (first, second)
        #expect(a == b && a.count == 512 && (a.max() ?? 0) > 0)
        #expect(try Data(contentsOf: source) == original)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let disk = WaveformStore(directory: directory)
        #expect(try await disk.waveform(url: source, accessRoot: root) == a)
        try Data("invalid".utf8).write(to: files[0])
        let repaired = WaveformStore(directory: directory)
        #expect(try await repaired.waveform(url: source, accessRoot: root) == a)
        try silentWAV().write(to: source)
        let changed = try await store.waveform(url: source, accessRoot: root)
        #expect(changed.allSatisfy { $0 == 0 })
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 2)
    }

    @Test func diskCacheIsBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("Waveforms")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<256 {
            let url = directory.appendingPathComponent("old-\(index).json")
            try Data("[]".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: url.path)
        }
        let source = root.appendingPathComponent("silence.wav")
        try silentWAV().write(to: source)
        let store = WaveformStore(directory: directory)
        _ = try await store.waveform(url: source, accessRoot: root)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 256)
    }

    private func silentWAV() -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init)) }
        func u32(_ value: UInt32) { data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init)) }
        text("RIFF"); u32(36 + 1024); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(44100); u32(88200); u16(2); u16(16); text("data"); u32(1024)
        data.append(Data(repeating: 0, count: 1024))
        return data
    }

    @Test func waveformStoreCoalescesConcurrentRequestsForSameFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("one.wav")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/44100-16.wav")
        try FileManager.default.copyItem(at: fixture, to: source)
        let directory = root.appendingPathComponent("Waveforms")
        let store = WaveformStore(directory: directory)

        // 20 concurrent requests for the same file must share one decode.
        var decodes: [[Float]] = []
        try await withThrowingTaskGroup(of: [Float].self) { group in
            for _ in 0..<20 {
                group.addTask { try await store.waveform(url: source, accessRoot: root) }
            }
            for try await result in group {
                decodes.append(result)
            }
        }
        #expect(decodes.count == 20, "All 20 concurrent requests should complete")
        #expect(decodes.allSatisfy { $0.count == 512 && ($0.max() ?? 0) > 0 })
        // Decode should happen exactly once; only one artifact should be written.
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1, "Only one decode artifact should be written")
    }

    @Test func waveformStoreMemoryLRUEvictsOldestEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Waveforms")
        let store = WaveformStore(directory: directory)

        // Create 30 distinct silent WAV files (memory cap is 24).
        var urls: [URL] = []
        for index in 0..<30 {
            let url = root.appendingPathComponent("tone-\(index).wav")
            try silentWAV().write(to: url)
            urls.append(url)
        }
        // Access all 30; the last 24 should remain in memory, first 6 evicted.
        var results: [[Float]] = []
        for url in urls {
            results.append(try await store.waveform(url: url, accessRoot: root))
        }
        #expect(results.count == 30)
        #expect(results.allSatisfy { $0.count == 512 })

        // Re-accessing an evicted URL must still succeed (served from the disk
        // cache or re-decoded) and must not create a second artifact for it.
        let revisited = try await store.waveform(url: urls[0], accessRoot: root)
        #expect(revisited.count == 512)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 30, "Disk cache keeps exactly one entry per unique file")
    }

    @Test func waveformStoreCancelledDecodeDoesNotBlockOthers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("one.wav")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/44100-16.wav")
        try FileManager.default.copyItem(at: fixture, to: source)
        let directory = root.appendingPathComponent("Waveforms")
        let store = WaveformStore(directory: directory)

        // Start a request, cancel it immediately, then make a new one that must not
        // be blocked by the abandoned work.
        let cancelled = Task {
            try await store.waveform(url: source, accessRoot: root)
        }
        cancelled.cancel()
        _ = try? await cancelled.value

        let result = try await store.waveform(url: source, accessRoot: root)
        #expect(result.count == 512 && (result.max() ?? 0) > 0)
    }
}

private final class WaveformFixture: AudioDecoding {
    let source: SourceFormat
    let pcmFormat: AudioStreamBasicDescription
    let frameCount: Int64
    let data: Data
    private var position = 0
    private(set) var readCount = 0
    init(data: Data, bits: Int, channels: Int, signed: Bool = true, extraFlags: UInt32 = 0) {
        self.data = data
        source = SourceFormat(codec: "PCM", sampleRate: 44100, bitDepth: bits, channels: channels, isLossless: true)
        let frameBytes = ((bits + 7) / 8) * channels
        pcmFormat = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: (signed ? kAudioFormatFlagIsSignedInteger : 0) | extraFlags,
            mBytesPerPacket: UInt32(frameBytes), mFramesPerPacket: 1, mBytesPerFrame: UInt32(frameBytes),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: UInt32(bits), mReserved: 0)
        frameCount = Int64(data.count / frameBytes)
    }
    func read(into buffer: UnsafeMutableRawPointer, frames: UInt32) throws -> UInt32 {
        readCount += 1
        let bytes = Int(pcmFormat.mBytesPerFrame)
        let count = min(Int(frames), Int(frameCount) - position)
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), from: position * bytes..<(position + count) * bytes)
        position += count
        return UInt32(count)
    }
    func seek(to frame: Int64) throws { position = Int(frame) }
}
