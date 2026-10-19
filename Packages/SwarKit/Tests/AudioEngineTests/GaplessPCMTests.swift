import AudioToolbox
import Decoding
import Foundation
import RealtimeAudio
import Testing
@testable import AudioEngine

struct GaplessPCMTests {
    @Test func singleRenderReadCrossesBoundaryWithoutSilenceOrSampleLoss() throws {
        let fixture = try nextTrack(frames: 2000, value: 2222)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stream = try GaplessPCM(decoder: ConstantDecoder(frames: 5000, value: 1111), url: fixture.root.appendingPathComponent("first.wav"), capacity: 9000)
        let firstToken = stream.current.token
        stream.request(fixture.next.item.id)
        #expect(stream.install(fixture.next))
        try stream.fill()
        #expect(stream.current.token == firstToken) // Decoding ahead must not advance UI identity.
        let first = read(stream, frames: 4999)
        #expect(first.allSatisfy { $0 == 1111 })
        #expect(stream.current.token == firstToken)
        let crossing = read(stream, frames: 4)
        #expect(crossing == [1111, 1111, 2222, 2222, 2222, 2222, 2222, 2222])
        #expect(stream.current.entryID == fixture.next.item.id)
        #expect(stream.current.token == fixture.next.token)
        #expect(abs(stream.position - 3.0 / 44100) < 0.000001)
        #expect(swar_ring_underruns(stream.ring) == 0)
    }

    @Test func repeatedSmallRenderBlocksWrapRingAndPreserveEntirePCM() throws {
        let fixture = try nextTrack(frames: 2000, value: -2222)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stream = try GaplessPCM(decoder: ConstantDecoder(frames: 5000, value: 1111), url: fixture.root.appendingPathComponent("first.wav"), capacity: 256)
        stream.request(fixture.next.item.id); #expect(stream.install(fixture.next))
        var samples: [Int16] = []
        while !stream.eof || swar_ring_readable(stream.ring) > 0 {
            try stream.fill()
            samples += read(stream, frames: min(127, swar_ring_readable(stream.ring)))
        }
        #expect(samples == [Int16](repeating: 1111, count: 10_000) + [Int16](repeating: -2222, count: 4000))
        #expect(swar_ring_underruns(stream.ring) == 0)
    }

    @Test func repeatedEntryCanBePreparedAgainAfterAudiblePromotion() throws {
        let fixture = try nextTrack(frames: 20000, value: 2222)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stream = try GaplessPCM(decoder: ConstantDecoder(frames: 5000, value: 1111), url: fixture.root.appendingPathComponent("first.wav"), capacity: 256)
        stream.request(fixture.next.item.id); #expect(stream.install(fixture.next))
        var samples: [Int16] = []
        var repeated = false
        while !stream.eof || swar_ring_readable(stream.ring) > 0 {
            try stream.fill()
            samples += read(stream, frames: min(127, swar_ring_readable(stream.ring)))
            if !repeated, stream.current.token == fixture.next.token {
                #expect(stream.requestedID == nil)
                stream.request(fixture.next.item.id)
                #expect(stream.install(try PreparedContinuation(fixture.next.item)))
                repeated = true
            }
        }
        #expect(repeated)
        #expect(samples == [Int16](repeating: 1111, count: 10_000) + [Int16](repeating: 2222, count: 80_000))
        #expect(swar_ring_underruns(stream.ring) == 0)
    }

    @Test func seekDiscardsAlreadyBufferedNextTrackAndCanSeekAfterPromotion() throws {
        let fixture = try nextTrack(frames: 2000, value: 2222)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stream = try GaplessPCM(decoder: ConstantDecoder(frames: 5000, value: 1111), url: fixture.root.appendingPathComponent("first.wav"), capacity: 9000)
        stream.request(fixture.next.item.id); #expect(stream.install(fixture.next)); try stream.fill()
        _ = read(stream, frames: 100)
        try stream.seek(0)
        #expect(!stream.hasQueuedBoundary && stream.requestedID == nil)
        try stream.fill()
        #expect(read(stream, frames: swar_ring_readable(stream.ring)) == [Int16](repeating: 1111, count: 10_000))

        let other = try nextTrack(frames: 2000, value: -3333)
        defer { try? FileManager.default.removeItem(at: other.root) }
        let promoted = try GaplessPCM(decoder: ConstantDecoder(frames: 5000, value: 1111), url: other.root.appendingPathComponent("first.wav"), capacity: 9000)
        promoted.request(other.next.item.id); #expect(promoted.install(other.next)); try promoted.fill()
        _ = read(promoted, frames: 5100)
        let token = promoted.current.token
        try promoted.seek(0)
        #expect(promoted.current.token == token && promoted.current.entryID == other.next.item.id)
        try promoted.fill()
        #expect(read(promoted, frames: swar_ring_readable(promoted.ring)) == [Int16](repeating: -3333, count: 4000))
    }

    @Test func incompatibleOrCancelledPreparationLeavesCurrentTrackIntact() throws {
        let fixture = try nextTrack(frames: 2000, value: 2222, rate: 48000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stream = try GaplessPCM(decoder: ConstantDecoder(frames: 5000, value: 1111), url: fixture.root.appendingPathComponent("first.wav"), capacity: 9000)
        stream.request(fixture.next.item.id); #expect(!stream.install(fixture.next))
        try stream.fill()
        #expect(stream.eof && stream.current.entryID == nil)
        #expect(read(stream, frames: swar_ring_readable(stream.ring)) == [Int16](repeating: 1111, count: 10_000))

        let compatible = try nextTrack(frames: 2000, value: 2222)
        defer { try? FileManager.default.removeItem(at: compatible.root) }
        let cancelled = try GaplessPCM(decoder: ConstantDecoder(frames: 5000, value: 1111), url: compatible.root.appendingPathComponent("first.wav"), capacity: 9000)
        cancelled.request(compatible.next.item.id); #expect(cancelled.install(compatible.next))
        cancelled.request(nil); try cancelled.fill()
        #expect(read(cancelled, frames: swar_ring_readable(cancelled.ring)).allSatisfy { $0 == 1111 })
    }

    @Test func failingSuccessorDoesNotInterruptCurrentTracksBufferedTail() throws {
        let url = URL(fileURLWithPath: "/test/next.wav")
        let item = PlaybackContinuation(id: UUID(), url: url, accessRoot: url)
        let decoder = ConstantDecoder(frames: 20000, value: 2222)
        decoder.failing = true
        var prefix = [Int16](repeating: 2222, count: 4)
        let data = prefix.withUnsafeMutableBytes { Data($0) }
        let next = PreparedContinuation(item: item, decoder: decoder, prefix: data)
        let stream = try GaplessPCM(decoder: ConstantDecoder(frames: 5000, value: 1111), url: url, capacity: 9000)
        stream.request(item.id); #expect(stream.install(next)); try stream.fill()
        #expect(stream.failure == nil)
        #expect(read(stream, frames: 4999).allSatisfy { $0 == 1111 })
        #expect(stream.failure == nil)
        #expect(read(stream, frames: 1) == [1111, 1111])
        #expect(stream.failure != nil && stream.current.entryID == item.id)
    }

    @Test func formatCompatibilityIncludesPackingPrecisionAndChannels() {
        let format = ConstantDecoder(frames: 1, value: 1).pcmFormat
        #expect(GaplessPCM.compatible(format, format))
        for field in 0..<5 {
            var changed = format
            switch field {
            case 0: changed.mSampleRate = 48000
            case 1: changed.mFormatFlags |= kAudioFormatFlagIsBigEndian
            case 2: changed.mBitsPerChannel = 24
            case 3: changed.mChannelsPerFrame = 1
            default: changed.mBytesPerFrame = 8
            }
            #expect(!GaplessPCM.compatible(format, changed))
        }
    }

    private func read(_ stream: GaplessPCM, frames: UInt32) -> [Int16] {
        guard frames > 0 else { return [] }
        var result = [Int16](repeating: 0, count: Int(frames) * 2)
        let count = result.withUnsafeMutableBytes { swar_ring_read(stream.ring, $0.baseAddress!, frames) }
        return Array(result.prefix(Int(count) * 2))
    }

    private func nextTrack(frames: UInt32, value: Int16, rate: UInt32 = 44100) throws -> (root: URL, next: PreparedContinuation) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swar-gapless-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("next.wav")
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + frames * 4); text("WAVEfmt "); u32(16); u16(1); u16(2)
        u32(rate); u32(rate * 4); u16(4); u16(16); text("data"); u32(frames * 4)
        for _ in 0..<frames * 2 { u16(UInt16(bitPattern: value)) }
        try data.write(to: url)
        return (root, try PreparedContinuation(PlaybackContinuation(id: UUID(), url: url, accessRoot: root)))
    }
}

private final class ConstantDecoder: AudioDecoding {
    let source = SourceFormat(codec: "PCM", sampleRate: 44100, bitDepth: 16, channels: 2, isLossless: true)
    let pcmFormat = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
    let frameCount: Int64
    let value: Int16
    var position: Int64 = 0
    var failing = false
    init(frames: Int64, value: Int16) { frameCount = frames; self.value = value }
    func read(into buffer: UnsafeMutableRawPointer, frames: UInt32) throws -> UInt32 {
        if failing { throw AudioFailure("Test decode failure") }
        let count = min(Int64(frames), frameCount - position)
        let samples = buffer.assumingMemoryBound(to: Int16.self)
        for index in 0..<Int(count) * 2 { samples[index] = value }
        position += count
        return UInt32(count)
    }
    func seek(to frame: Int64) throws { position = min(frameCount, max(0, frame)) }
}
