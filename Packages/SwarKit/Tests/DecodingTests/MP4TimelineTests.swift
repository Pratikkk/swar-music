import Foundation
import Testing
@testable import Decoding

struct MP4TimelineTests {
    private func integer(_ value: UInt64, bytes: Int = 4) -> Data {
        Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func box(_ type: String, _ payload: Data) -> Data {
        integer(UInt64(payload.count + 8)) + Data(type.utf8) + payload
    }
    private func movie(version: UInt8, mediaTime: UInt64) -> Data {
        var header = Data(count: version == 1 ? 24 : 16)
        header[0] = version
        header.replaceSubrange((version == 1 ? 20 : 12)..<(version == 1 ? 24 : 16), with: integer(1000))
        let edit = Data([version, 0, 0, 0]) + integer(1) + integer(1000, bytes: version == 1 ? 8 : 4)
            + integer(mediaTime, bytes: version == 1 ? 8 : 4) + integer(0x10000)
        let handler = Data(count: 8) + Data("soun".utf8)
        return box("moov", box("mvhd", header) + box("trak", box("mdia", box("hdlr", handler)) + box("edts", box("elst", edit))))
    }
    private func fixture(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try data.write(to: url)
        return url
    }

    @Test(arguments: [UInt8(0), UInt8(1)])
    func timingVersionsDistinguishDefaultAndEditedTimelines(_ version: UInt8) throws {
        for mediaTime: UInt64 in [0, 2205] {
            let url = try fixture(box("ftyp", Data()) + movie(version: version, mediaTime: mediaTime))
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(try MP4Timeline.requiresBundledDecoder(url: url, frames: 44100, sampleRate: 44100) == (mediaTime != 0))
            if mediaTime == 0 {
                #expect(try MP4Timeline.requiresBundledDecoder(url: url, frames: 88200, sampleRate: 44100), "A trailing timeline trim also needs the bundled path")
                #expect(try MP4Timeline.requiresBundledDecoder(url: url, frames: 1001, sampleRate: 1000), "An exact one-sample trim must not be treated as timing rounding")
                #expect(try !MP4Timeline.requiresBundledDecoder(url: url, frames: 44101, sampleRate: 44100), "Ordinary movie-tick rounding should retain native decoding")
            }
        }
    }

    @Test func mediaPayloadsAreSkippedAndMalformedSizesFailSafely() throws {
        let url = try fixture(box("ftyp", Data()) + integer(1) + Data("free".utf8) + integer(64 * 1024 * 1024, bytes: 8))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        let offset: UInt64 = 8 + 64 * 1024 * 1024
        try handle.truncate(atOffset: offset)
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: movie(version: 1, mediaTime: 2205))
        try handle.close()
        #expect(try MP4Timeline.requiresBundledDecoder(url: url, frames: 44100, sampleRate: 44100))
        for malformed in [integer(4) + Data("ftyp".utf8), integer(1) + Data("ftyp".utf8) + integer(UInt64.max, bytes: 8)] {
            let broken = try fixture(malformed)
            defer { try? FileManager.default.removeItem(at: broken) }
            #expect(throws: AudioFailure.self) { try MP4Timeline.requiresBundledDecoder(url: broken, frames: 44100, sampleRate: 44100) }
        }
    }
}
