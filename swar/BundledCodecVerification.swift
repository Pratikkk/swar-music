import Foundation
import AudioToolbox
import Decoding
import Darwin

/// Packaging runs this inside the signed app process, where Hardened Runtime
/// library validation applies. Unit-test hosts do not reproduce that policy.
enum BundledCodecVerification {
    static func runAndExit() -> Never {
        do {
            try verify()
            FileHandle.standardOutput.write(Data("Bundled codec runtime check passed (decode, seek, EOF).\n".utf8))
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("Bundled codec runtime check failed: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func verify() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Swar-codec-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("probe.wav")
        let frames = 256
        var samples = Data()
        for i in 0..<frames {
            append(Int16(i * 97 - 12000), to: &samples)
            append(Int16(12000 - i * 83), to: &samples)
        }
        var wave = Data("RIFF".utf8)
        append(UInt32(36 + samples.count), to: &wave)
        wave.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &wave)
        append(UInt16(1), to: &wave)
        append(UInt16(2), to: &wave)
        append(UInt32(44100), to: &wave)
        append(UInt32(44100 * 4), to: &wave)
        append(UInt16(4), to: &wave)
        append(UInt16(16), to: &wave)
        wave.append(Data("data".utf8))
        append(UInt32(samples.count), to: &wave)
        wave.append(samples)
        try wave.write(to: url)

        // Force the bundled path; a native WAV decoder would hide signing failures.
        let decoder = try FFmpegDecoder(url: url)
        guard decoder.pcmFormat.mBytesPerFrame == 4, decoder.frameCount == frames else {
            throw CheckFailure("Unexpected probe format")
        }
        var decoded = Data(count: samples.count)
        let count = try decoded.withUnsafeMutableBytes { try decoder.read(into: $0.baseAddress!, frames: UInt32(frames)) }
        guard count == frames, decoded == samples else { throw CheckFailure("Decoded samples differ") }
        let end = try decoded.withUnsafeMutableBytes { try decoder.read(into: $0.baseAddress!, frames: 1) }
        guard end == 0 else { throw CheckFailure("Decoder did not reach EOF") }
        try decoder.seek(to: 64)
        var sought = Data(count: 4)
        let read = try sought.withUnsafeMutableBytes { try decoder.read(into: $0.baseAddress!, frames: 1) }
        guard read == 1, sought == samples.subdata(in: 256..<260) else { throw CheckFailure("Seek samples differ") }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private struct CheckFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
