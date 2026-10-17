import AudioToolbox
import Decoding
import Foundation
import Testing

struct Packed24BitTests {
    private var codecs: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Vendor/FFmpeg/lib")
    }

    @Test(arguments: [false, true])
    func bundledPacked24BitExtremesAndLowBits(alac: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("source.wav")
        // Literal little-endian two's-complement bytes: zero, +/-1, signed
        // limits, alternating bits and values with nonzero low bytes. Distinct
        // stereo channels and enough frames to cross decoder block boundaries.
        let edges: [[UInt8]] = [
            [0, 0, 0], [1, 0, 0], [255, 255, 255],
            [255, 255, 127], [0, 0, 128], [1, 0, 128],
            [0x56, 0x34, 0x12], [0xaa, 0xcb, 0xed],
            [0x55, 0xaa, 0x55], [0xaa, 0x55, 0xaa]
        ]
        var expected = Data()
        let frameCount = 8_194
        var random: UInt32 = 0x12345678
        for sample in 0..<(frameCount * 2) {
            if sample < edges.count { expected.append(contentsOf: edges[sample]) }
            else {
                random = random &* 1_664_525 &+ 1_013_904_223
                expected.append(contentsOf: [UInt8(truncatingIfNeeded: random),
                    UInt8(truncatingIfNeeded: random >> 8), UInt8(truncatingIfNeeded: random >> 16)])
            }
        }
        var header = Data()
        func text(_ s: String) { header.append(contentsOf: s.utf8) }
        func u16(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + expected.count)); text("WAVEfmt "); u32(16)
        u16(1); u16(2); u32(96_000); u32(96_000 * 6); u16(6); u16(24)
        text("data"); u32(UInt32(expected.count)); header.append(expected)
        try header.write(to: wav)
        var input = wav
        if alac {
            input = directory.appendingPathComponent("source.m4a")
            let converter = Process()
            converter.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            converter.arguments = [wav.path, input.path, "-d", "alac", "-f", "m4af"]
            try converter.run(); converter.waitUntilExit()
            try #require(converter.terminationStatus == 0)
        }
        // Force the C bridge: DecoderFactory could otherwise use AudioToolbox.
        // WAV exercises interleaved S32, ALAC exercises planar S32P.
        let decoder = try FFmpegDecoder(url: input, codecDirectory: codecs)
        #expect(decoder.source.bitDepth == 24)
        #expect(decoder.source.isLossless)
        #expect(decoder.pcmFormat.mBytesPerFrame == 6)
        #expect(decoder.pcmFormat.mBitsPerChannel == 24)
        #expect(decoder.pcmFormat.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0)
        #expect(decoder.pcmFormat.mFormatFlags & kAudioFormatFlagIsPacked != 0)
        #expect(decoder.pcmFormat.mFormatFlags & kAudioFormatFlagIsFloat == 0)
        #expect(decoder.frameCount == Int64(frameCount))
        var decoded = Data()
        let chunks: [UInt32] = [1, 3, 137, 4093]
        var iteration = 0
        while true {
            let requested = chunks[iteration % chunks.count]
            // Guard bytes detect writes beyond the requested packed frame count.
            var buffer = Data(repeating: 0xa5, count: Int(requested) * 6 + 16)
            let read = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0.baseAddress!, frames: requested) }
            try #require(read <= requested)
            #expect(buffer.suffix(16) == Data(repeating: 0xa5, count: 16))
            decoded.append(buffer.prefix(Int(read) * 6))
            try #require(decoded.count <= expected.count)
            if read == 0 { break }
            iteration += 1
        }
        #expect(decoded == expected, "Every packed byte must match the independently constructed source, including negative signs and low bits")
        for target: Int64 in [0, 1, 4, 4095, 4096, Int64(frameCount - 1)] {
            try decoder.seek(to: target)
            var frame = Data(count: 6)
            let read = try frame.withUnsafeMutableBytes { try decoder.read(into: $0.baseAddress!, frames: 1) }
            #expect(read == 1)
            let offset = Int(target) * 6
            #expect(frame == expected.subdata(in: offset..<(offset + 6)))
        }
    }
}
