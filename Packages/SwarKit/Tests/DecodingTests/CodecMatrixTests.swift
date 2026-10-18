import AudioToolbox
import CryptoKit
import Decoding
import Foundation
import Testing

struct CodecMatrixTests {
    private struct Fixture: Decodable {
        let file: String
        let codec: String
        let rate: Double
        let bits: Int?
        let channels: Int
        let lossless: Bool
        let native: Bool
        let reference: String?
        let sha256: String?
    }

    private var directory: URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures") }
    private var codecs: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Vendor/FFmpeg/lib")
    }
    private func fixture(_ filename: String) throws -> Fixture {
        let all = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        return try #require(all.first { $0.file == filename })
    }

    private func readAll(_ decoder: any AudioDecoding) throws -> Data {
        var data = Data()
        let stride = Int(decoder.pcmFormat.mBytesPerFrame)
        var buffer = Data(count: 137 * stride)
        while true {
            let frames = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0.baseAddress!, frames: 137) }
            if frames == 0 { break }
            data.append(buffer.prefix(Int(frames) * stride))
            try #require(data.count < 16_000_000, "Decoder must eventually reach EOF")
        }
        return data
    }

    private func verifyLossless(_ name: String, forceBundled: Bool = false) throws {
        let item = try fixture(name)
        let url = directory.appendingPathComponent(name)
        let decoder: any AudioDecoding = forceBundled ? try FFmpegDecoder(url: url, codecDirectory: codecs) : try DecoderFactory.open(url: url, codecDirectory: codecs)
        #expect(decoder.source.codec == item.codec)
        #expect(decoder.source.bitDepth == item.bits)
        #expect(decoder.source.sampleRate == item.rate)
        #expect(decoder.source.channels == item.channels)
        #expect(decoder.source.isLossless)
        #expect((decoder.pcmFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0) == name.contains("float"))
        if item.native && !forceBundled { #expect(decoder is NativeDecoder, "Native decoder expected for \(name)") }
        let decoded = try readAll(decoder)
        let hash = SHA256.hash(data: decoded).map { String(format: "%02x", $0) }.joined()
        #expect(hash == item.sha256, "Decoded bytes must match the original source: \(name)")
        let reference = try Data(contentsOf: directory.appendingPathComponent(try #require(item.reference)))
        let samplesMatch = decoded == reference
        #expect(samplesMatch)
        let stride = Int(decoder.pcmFormat.mBytesPerFrame)
        #expect(decoded.count == Int(decoder.frameCount) * stride)
        let target = decoder.frameCount / 3
        try decoder.seek(to: target)
        var sought = Data(count: 37 * stride)
        let frames = try sought.withUnsafeMutableBytes { try decoder.read(into: $0.baseAddress!, frames: 37) }
        #expect(frames == 37)
        let offset = Int(target) * stride
        #expect(sought == reference.subdata(in: offset..<(offset + sought.count)), "Seek must preserve sample alignment: \(name)")
    }

    @Test(arguments: ["44100-16", "96000-24", "192000-24"])
    func tierOneAndWavPackAtEveryRate(base: String) throws {
        for ext in ["wav", "m4a", "flac", "aiff", "caf", "wv"] {
            do { try verifyLossless("\(base).\(ext)") }
            catch { Issue.record(error, "Fixture \(base).\(ext)") }
        }
    }

    @Test(arguments: ["wav", "aifc", "caf", "wv"])
    func floatingPointPCM(ext: String) throws {
        try verifyLossless("96000-float.\(ext)")
    }

    @Test(arguments: ["flac", "m4a", "wv"])
    func bundledLosslessDecoderPreservesNativeIntegers(ext: String) throws {
        for base in ["44100-16", "96000-24", "192000-24"] {
            do { try verifyLossless("\(base).\(ext)", forceBundled: true) }
            catch { Issue.record(error, "Bundled decoder: \(base).\(ext)") }
        }
    }

    @Test(arguments: ["44100-16.aac.m4a", "44100-16.aac", "44100-16.mp3", "44100-16.ogg", "44100-16.opus", "44100-16.wma"])
    func lossyContentDecodeAndSeek(name: String) throws {
        let item = try fixture(name)
        let decoder = try DecoderFactory.open(url: directory.appendingPathComponent(name), codecDirectory: codecs)
        #expect(decoder.source.codec == item.codec)
        #expect(decoder.source.sampleRate == item.rate)
        #expect(!decoder.source.isLossless)
        #expect(decoder.source.bitDepth == nil)
        let decoded = try readAll(decoder)
        #expect(!decoded.isEmpty)
        #expect(decoded.contains { $0 != 0 })
        if item.codec == "Opus" {
            #expect(decoder.frameCount == 9_600)
            #expect(decoded.count == 9_600 * Int(decoder.pcmFormat.mBytesPerFrame))
        }
        try decoder.seek(to: Int64(item.rate / 20))
        var sought = Data(count: Int(decoder.pcmFormat.mBytesPerFrame) * 100)
        let count = try sought.withUnsafeMutableBytes { try decoder.read(into: $0.baseAddress!, frames: 100) }
        #expect(count == 100)
    }

    @Test func bundledDetectionIgnoresMisleadingExtension() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: directory.appendingPathComponent("44100-16.opus"), to: temporary)
        let decoder = try DecoderFactory.open(url: temporary, codecDirectory: codecs)
        #expect(decoder.source.codec == "Opus")
        #expect(decoder.source.sampleRate == 48_000)
    }

    @Test func nativeFlacReportsItsFormat() throws {
        let decoder = try NativeDecoder(url: directory.appendingPathComponent("96000-24.flac"))
        #expect(decoder.source.bitDepth == 24)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWAR_EXTERNAL_CODEC_FIXTURES"] != nil), arguments: ["ape", "wma"])
    func externalLosslessRegressionSamples(ext: String) throws {
        let path = try #require(ProcessInfo.processInfo.environment["SWAR_EXTERNAL_CODEC_FIXTURES"])
        let root = URL(fileURLWithPath: path)
        let decoder = try FFmpegDecoder(url: root.appendingPathComponent("sample.\(ext)"), codecDirectory: codecs)
        #expect(decoder.source.codec == (ext == "ape" ? "Monkey's Audio" : "WMA Lossless"))
        #expect(decoder.source.isLossless)
        #expect(decoder.source.bitDepth == 16)
        let reference = try Data(contentsOf: root.appendingPathComponent("sample-\(ext).pcm"))
        let decoded = try readAll(decoder)
        let matches = SHA256.hash(data: decoded) == SHA256.hash(data: reference)
        #expect(matches, "Decoded sample checksum must match the independent reference")
        let stride = Int(decoder.pcmFormat.mBytesPerFrame)
        let target = Int64(reference.count / stride / 3)
        try decoder.seek(to: target)
        var sought = Data(count: stride * 100)
        let count = try sought.withUnsafeMutableBytes { try decoder.read(into: $0.baseAddress!, frames: 100) }
        #expect(count == 100)
        let offset = Int(target) * stride
        let seekMatches = sought == reference.subdata(in: offset..<(offset + sought.count))
        #expect(seekMatches, "Seek should land on the same samples as linear decoding")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWAR_EXTERNAL_CODEC_FIXTURES"] != nil))
    func hybridWavPackIsNotClaimedAsLossless() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SWAR_EXTERNAL_CODEC_FIXTURES"])
        let decoder = try FFmpegDecoder(url: URL(fileURLWithPath: path).appendingPathComponent("hybrid.wv"), codecDirectory: codecs)
        #expect(decoder.source.codec == "WavPack")
        #expect(!decoder.source.isLossless)
        #expect(decoder.source.bitDepth == nil)
        #expect(!(try readAll(decoder)).isEmpty)
    }

    @Test func missingRuntimeAndCorruptContentReportErrors() throws {
        #expect(throws: (any Error).self) {
            try FFmpegDecoder(url: directory.appendingPathComponent("44100-16.opus"), codecDirectory: directory)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".opus")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("corrupt audio".utf8).write(to: file)
        #expect(throws: (any Error).self) { try DecoderFactory.open(url: file, codecDirectory: codecs) }
        #expect(throws: (any Error).self) { try DecoderFactory.open(url: URL(string: "https://example.com/a.opus")!, codecDirectory: codecs) }
    }

    @Test func truncatedLosslessContentDoesNotEndSilently() throws {
        let original = try Data(contentsOf: directory.appendingPathComponent("96000-24.flac"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
        defer { try? FileManager.default.removeItem(at: file) }
        try original.prefix(original.count / 2).write(to: file)
        #expect(throws: (any Error).self) {
            let decoder = try DecoderFactory.open(url: file, codecDirectory: codecs)
            _ = try readAll(decoder)
        }
    }

    @Test func alacWithStaleAACDelayPreservesSamplesAndReachesEOF() throws {
        let url = directory.appendingPathComponent("alac-stale-aac-delay.m4a")
        // Core Audio applies the stale AAC priming tag to ALAC. Reject that
        // path at open, rather than discovering the mismatch at track end.
        #expect(throws: AudioFailure.self) { try NativeDecoder(url: url) }
        let decoder = try DecoderFactory.open(url: url, codecDirectory: codecs)
        #expect(decoder is FFmpegDecoder)
        let expected = try Data(contentsOf: directory.appendingPathComponent("44100-16.pcm"))
        let decoded = try readAll(decoder)
        #expect(decoded == expected, "Encoder-delay tags must not remove real lossless samples")
        let stride = Int(decoder.pcmFormat.mBytesPerFrame)
        #expect(decoder.frameCount == Int64(expected.count / stride))

        let tailFrames = 17
        try decoder.seek(to: decoder.frameCount - Int64(tailFrames))
        var tail = Data(count: 4096 * stride)
        let count = try tail.withUnsafeMutableBytes { try decoder.read(into: $0.baseAddress!, frames: 4096) }
        #expect(count == UInt32(tailFrames))
        #expect(tail.prefix(tailFrames * stride) == expected.suffix(tailFrames * stride))
        for _ in 0..<2 {
            let eof = try tail.withUnsafeMutableBytes { try decoder.read(into: $0.baseAddress!, frames: 4096) }
            #expect(eof == 0)
        }
    }
}
