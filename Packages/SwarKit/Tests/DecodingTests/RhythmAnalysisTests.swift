import Testing
import Foundation
import AudioToolbox
@testable import Decoding

struct RhythmAnalysisTests {
    @Test(arguments: [60.0, 90, 120, 150, 180])
    func detectsSyntheticPulseTempos(bpm: Double) throws {
        var onsets = [Double](repeating: 0, count: 3000)
        var time = 0.17
        while time < 30 {
            let center = Int((time * 100).rounded())
            for offset in -2...2 where onsets.indices.contains(center + offset) {
                onsets[center + offset] = exp(-Double(offset * offset) / 2)
            }
            time += 60 / bpm
        }
        let result = RhythmAnalysis.estimate(onsets: onsets)
        #expect(abs(try #require(result.bpm) - bpm) < 2)
        #expect(result.confidence > 0.5)
        #expect(!result.beats.isEmpty)
        #expect(abs(result.beats.count - Int(30 * bpm / 60)) <= 2)
        #expect(result.beats.allSatisfy { beat in
            let index = ((beat - 0.17) / (60 / bpm)).rounded()
            return abs(beat - (0.17 + index * 60 / bpm)) <= 0.025
        })
        #expect(zip(result.beats, result.beats.dropFirst()).allSatisfy { $0 < $1 })
        #expect(result.beats.allSatisfy { $0 >= 0 && $0 < 30 })
    }

    @Test func silenceConstantAndInvalidInputDoNotInventTempo() {
        for onsets in [[Double](repeating: 0, count: 2000), [Double](repeating: 1, count: 2000), [.nan], [-1], []] {
            #expect(RhythmAnalysis.estimate(onsets: onsets).bpm == nil)
        }
        #expect(RhythmAnalysis.estimate(onsets: [1, 0], rate: .infinity).bpm == nil)
        var seed: UInt64 = 7
        let noise = (0..<6000).map { _ -> Double in
            seed = seed &* 6364136223846793005 &+ 1
            return Double(seed >> 32) / Double(UInt32.max)
        }
        #expect(RhythmAnalysis.estimate(onsets: noise).bpm == nil)
    }

    @Test func nativePCMAnalysisAndCacheInvalidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let song = root.appendingPathComponent("click.wav"), cache = root.appendingPathComponent("cache")
        try Self.writeClicks(song, bpm: 120)
        let store = RhythmStore(directory: cache)
        let first = try await store.profile(url: song, accessRoot: root)
        #expect(abs(try #require(first.bpm) - 120) < 2)
        #expect(first.energy.count == 40)
        #expect(first.energy.allSatisfy { $0.isFinite && $0 >= 0 })
        #expect(try await RhythmStore(directory: cache).profile(url: song, accessRoot: root) == first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 1)
        try Self.writeClicks(song, bpm: 90)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: song.path)
        let changed = try await store.profile(url: song, accessRoot: root)
        #expect(abs(try #require(changed.bpm) - 90) < 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 2)
        let cancelled = Task { try await store.profile(url: song, accessRoot: root) }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancelled analysis returned a result") }
        catch { #expect(error is CancellationError) }
    }

    @Test func decodingHonorsTimeBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeClicks(root, bpm: 120)
        let decoder = try NativeDecoder(url: root)
        #expect(throws: (any Error).self) { try RhythmAnalysis.analyze(decoder: decoder, timeLimit: 0) }
    }

    private static func writeClicks(_ url: URL, bpm: Double) throws {
        let rate = 8000, frames = rate * 20
        var pcm = Data()
        for frame in 0..<frames {
            let phase = Double(frame).truncatingRemainder(dividingBy: Double(rate) * 60 / bpm)
            var sample = Int16(phase < 80 ? 24000 : 0).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        append(UInt32(36 + pcm.count)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(pcm.count)); data.append(pcm)
        try data.write(to: url, options: .atomic)
    }
}
