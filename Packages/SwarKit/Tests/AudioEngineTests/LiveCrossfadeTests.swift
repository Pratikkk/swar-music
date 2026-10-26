import Testing
import Foundation
import Decoding
import RealtimeAudio
@testable import AudioEngine

struct LiveCrossfadeTests {
    @Test func liveProducerOverlapsThenPromotesAtTheAudibleBoundary() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = PlaybackContinuation(id: UUID(), url: root.appendingPathComponent("one.wav"), accessRoot: root)
        let next = PlaybackContinuation(id: UUID(), url: root.appendingPathComponent("two.wav"), accessRoot: root)
        let decoder = try ConvertedPCMDecoder(decoder: NativeDecoder(url: first.url), sampleRate: 44100)
        let stream = try GaplessPCM(decoder: decoder, url: first.url, entryID: first.id, capacity: 257, processed: true)
        let token = stream.current.token
        stream.request(next.id)
        #expect(stream.install(try PreparedContinuation(next, outputRate: 44100)))
        #expect(stream.install(try PreparedCrossfade(current: first, next: next, overlap: 0.5, rate: 44100)))
        #expect(stream.audible.crossfadeID == nil) // Prepared is not yet audible.
        var output: [Float] = []
        var buffer = [Float](repeating: 0, count: 113)
        var sawOverlap = false, promoted = false
        while !stream.eof || swar_ring_readable(stream.ring) > 0 {
            try stream.fill()
            let count = min(113, swar_ring_readable(stream.ring))
            let read = buffer.withUnsafeMutableBytes { swar_ring_read(stream.ring, $0.baseAddress!, count) }
            output.append(contentsOf: buffer.prefix(Int(read)))
            let audible = stream.audible
            let overlapping = output.count >= 22050 && output.count < 44100
            #expect(audible.crossfadeID == (overlapping ? next.id : nil))
            if output.count < 44100 { #expect(audible.segment.token == token) }
            if stream.hasAudibleCrossfade { sawOverlap = true }
            if audible.segment.entryID == next.id {
                promoted = true
                #expect(audible.position >= 0.5)
            }
        }
        #expect(sawOverlap && promoted)
        #expect(output.count == 66150)
        #expect(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
        #expect(abs(stream.position - 1) < 1e-8)
        #expect(swar_ring_underruns(stream.ring) == 0)
        // Seeking after promotion addresses the incoming source, not the old outgoing file.
        try stream.seek(0.25)
        #expect(stream.current.entryID == next.id)
        #expect(stream.audible.crossfadeID == nil)
        #expect(abs(stream.position - 0.25) < 1e-8)
        try stream.fill()
        #expect(swar_ring_readable(stream.ring) > 0)
    }

    @Test func seekingDuringAudibleOverlapClearsTransitionIdentity() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = PlaybackContinuation(id: UUID(), url: root.appendingPathComponent("one.wav"), accessRoot: root)
        let next = PlaybackContinuation(id: UUID(), url: root.appendingPathComponent("two.wav"), accessRoot: root)
        let decoder = try ConvertedPCMDecoder(decoder: NativeDecoder(url: first.url), sampleRate: 44100)
        let stream = try GaplessPCM(decoder: decoder, url: first.url, entryID: first.id, capacity: 44100, processed: true)
        stream.request(next.id)
        #expect(stream.install(try PreparedContinuation(next, outputRate: 44100)))
        #expect(stream.install(try PreparedCrossfade(current: first, next: next, overlap: 0.5, rate: 44100)))
        try stream.fill(upTo: 30000)
        #expect(stream.audible.crossfadeID == nil)
        var buffer = [Float](repeating: 0, count: 25000)
        let read = buffer.withUnsafeMutableBytes { swar_ring_read(stream.ring, $0.baseAddress!, 25000) }
        #expect(read == 25000)
        #expect(stream.audible.crossfadeID == next.id)
        try stream.seek(0.1)
        #expect(stream.audible.crossfadeID == nil)
        #expect(stream.current.entryID == first.id)
        #expect(swar_ring_readable(stream.ring) == 0)
    }

    @Test func seekCancelsPreparedTransitionAndLateInstallationIsRejected() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = PlaybackContinuation(id: UUID(), url: root.appendingPathComponent("one.wav"), accessRoot: root)
        let next = PlaybackContinuation(id: UUID(), url: root.appendingPathComponent("two.wav"), accessRoot: root)
        let decoder = try ConvertedPCMDecoder(decoder: NativeDecoder(url: first.url), sampleRate: 44100)
        let stream = try GaplessPCM(decoder: decoder, url: first.url, capacity: 44100, processed: true)
        stream.request(next.id)
        #expect(stream.install(try PreparedContinuation(next, outputRate: 44100)))
        let pair = try PreparedCrossfade(current: first, next: next, overlap: 0.5, rate: 44100)
        #expect(stream.install(pair))
        try stream.seek(0.1)
        #expect(stream.requestedID == nil && !stream.hasAudibleCrossfade)
        #expect(stream.audible.crossfadeID == nil)
        #expect(!stream.install(pair))
        stream.request(next.id)
        #expect(stream.install(try PreparedContinuation(next, outputRate: 44100)))
        try stream.fill(upTo: 30000)
        #expect(!stream.install(pair)) // Outgoing tail already buffered; retain gapless.
    }

    @Test(arguments: [(1, 2, true), (2, 1, true), (1, 2, false), (2, 1, false)])
    func monoStereoPairsShareAContinuousStereoTimeline(configuration: (Int, Int, Bool)) throws {
        let channels = (configuration.0, configuration.1)
        let root = try workspace(channels: channels)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = PlaybackContinuation(id: UUID(), url: root.appendingPathComponent("one.wav"), accessRoot: root)
        let next = PlaybackContinuation(id: UUID(), url: root.appendingPathComponent("two.wav"), accessRoot: root)
        let decoder = try ConvertedPCMDecoder(decoder: NativeDecoder(url: first.url), sampleRate: 44100, channels: 2)
        let stream = try GaplessPCM(decoder: decoder, url: first.url, entryID: first.id, capacity: 257, processed: true)
        stream.request(next.id)
        #expect(stream.install(try PreparedContinuation(next, outputRate: 44100, outputChannels: 2)))
        if configuration.2 {
            #expect(stream.install(try PreparedCrossfade(current: first, next: next, overlap: 0.5, rate: 44100, channels: 2)))
        }
        var output: [Float] = [], buffer = [Float](repeating: 0, count: 113 * 2)
        while !stream.eof || swar_ring_readable(stream.ring) > 0 {
            try stream.fill()
            let count = min(113, swar_ring_readable(stream.ring))
            let read = buffer.withUnsafeMutableBytes { swar_ring_read(stream.ring, $0.baseAddress!, count) }
            output.append(contentsOf: buffer.prefix(Int(read) * 2))
        }
        #expect(output.count == (configuration.2 ? 66150 : 88200) * 2)
        #expect(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
        // Mono duplicates exactly; stereo's two distinct channels remain distinct.
        #expect(channels.0 == 1 ? output[200] == output[201] : output[200] == -output[201])
        let end = output.count - 200
        #expect(channels.1 == 1 ? output[end] == output[end + 1] : output[end] == -output[end + 1])
        #expect(stream.audible.segment.entryID == next.id)
        #expect(swar_ring_underruns(stream.ring) == 0)
        try stream.seek(0.25)
        try stream.fill()
        #expect(abs(stream.position - 0.25) < 1e-8)
    }

    private func workspace(channels: (Int, Int) = (1, 1)) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, rate, amplitude) in [("one.wav", 44100, Int16(6000)), ("two.wav", 48000, Int16(-6000))] {
            let count = name == "one.wav" ? channels.0 : channels.1
            var data = Data("RIFF".utf8)
            func append<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
            append(UInt32(36 + rate * 2 * count)); data.append(Data("WAVEfmt ".utf8))
            append(UInt32(16)); append(UInt16(1)); append(UInt16(count)); append(UInt32(rate)); append(UInt32(rate * 2 * count))
            append(UInt16(2 * count)); append(UInt16(16)); data.append(Data("data".utf8)); append(UInt32(rate * 2 * count))
            for _ in 0..<rate {
                append(amplitude)
                if count == 2 { append(-amplitude) }
            }
            try data.write(to: root.appendingPathComponent(name))
        }
        return root
    }
}
