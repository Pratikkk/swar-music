import AudioToolbox
import Foundation
import Testing
@testable import Decoding

struct NativeDecoderTests {
    /// Known packed 24-bit stereo samples, including positive and negative limits.
    private func fixture() throws -> (URL, URL, Data) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source.wav")
        var samples = Data()
        let pattern: [Int32] = [0, 1, -1, 8_388_607, -8_388_608, 123_456, -123_456, 42]
        for index in 0..<400 {
            let sample = UInt32(bitPattern: pattern[index % pattern.count])
            samples.append(UInt8(truncatingIfNeeded: sample))
            samples.append(UInt8(truncatingIfNeeded: sample >> 8))
            samples.append(UInt8(truncatingIfNeeded: sample >> 16))
        }
        var data = Data()
        func text(_ s: String) { data.append(contentsOf: s.utf8) }
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + samples.count)); text("WAVEfmt "); u32(16)
        u16(1); u16(2); u32(96_000); u32(96_000 * 6); u16(6); u16(24)
        text("data"); u32(UInt32(samples.count)); data.append(samples)
        try data.write(to: url)
        return (directory, url, samples)
    }

    @Test func readsPacked24BitPCMFromContentsAndSeeks() throws {
        let (directory, url, expected) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let misleading = directory.appendingPathComponent("not-really-alac.m4a")
        try FileManager.default.copyItem(at: url, to: misleading)
        let decoder = try NativeDecoder(url: misleading)
        #expect(decoder.source.codec == "PCM")
        #expect(decoder.source.bitDepth == 24)
        #expect(decoder.source.sampleRate == 96_000)
        #expect(decoder.source.channels == 2)
        #expect(decoder.pcmFormat.mFormatFlags & kAudioFormatFlagIsFloat == 0)
        #expect(decoder.frameCount == 200)
        var decoded = Data(count: expected.count)
        let count = try decoded.withUnsafeMutableBytes { try decoder.read(into: $0.baseAddress!, frames: 200) }
        #expect(count == 200)
        #expect(decoded == expected)
        try decoder.seek(to: 5)
        var frame = Data(count: 6)
        let sought = try frame.withUnsafeMutableBytes { try decoder.read(into: $0.baseAddress!, frames: 1) }
        #expect(sought == 1)
        #expect(frame == expected.subdata(in: 30..<36))
    }

    @Test(arguments: ["m4a", "caf"]) func alac24Bit96kHzRoundTripPreservesEverySample(_ ext: String) throws {
        let (directory, input, expected) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("lossless." + ext)
        let converter = Process()
        converter.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        converter.arguments = [input.path, output.path, "-d", "alac", "-f", ext == "caf" ? "caff" : "m4af"]
        try converter.run()
        converter.waitUntilExit()
        try #require(converter.terminationStatus == 0)
        let decoder = try NativeDecoder(url: output)
        #expect(decoder.source.codec == "ALAC")
        #expect(decoder.source.bitDepth == 24)
        #expect(decoder.source.sampleRate == 96_000)
        var decoded = Data(count: expected.count)
        let count = try decoded.withUnsafeMutableBytes { try decoder.read(into: $0.baseAddress!, frames: 200) }
        #expect(count == 200)
        #expect(decoded == expected)
    }

    @Test func corruptFileFailsWithoutCrashing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broken.flac")
        try Data("not audio".utf8).write(to: url)
        #expect(throws: (any Error).self) { try NativeDecoder(url: url) }
    }
}
