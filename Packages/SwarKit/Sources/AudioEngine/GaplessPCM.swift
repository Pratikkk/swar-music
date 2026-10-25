import AudioToolbox
import Decoding
import Foundation
import RealtimeAudio
import os

public struct PlaybackContinuation: Sendable, Equatable {
    public let id: UUID
    public let url: URL
    public let accessRoot: URL
    public init(id: UUID, url: URL, accessRoot: URL) { self.id = id; self.url = url; self.accessRoot = accessRoot }
}

/// Created on a utility worker, then transferred exclusively to the engine queue.
final class PreparedContinuation: @unchecked Sendable {
    let item: PlaybackContinuation
    let decoder: any AudioDecoding
    let prefix: Data
    let token = UUID()
    private let acquired: Bool
    init(_ item: PlaybackContinuation, outputRate: Double? = nil) throws {
        self.item = item
        acquired = item.accessRoot.startAccessingSecurityScopedResource()
        do {
            let original = try DecoderFactory.open(url: item.url)
            let opened: any AudioDecoding = try outputRate.map { try ConvertedPCMDecoder(decoder: original, sampleRate: $0) } ?? original
            decoder = opened
            let frames = min(outputRate == nil ? 16384 : 4096, max(1, Int(decoder.source.sampleRate * 0.2)))
            var data = Data(count: frames * Int(decoder.pcmFormat.mBytesPerFrame))
            let count = try data.withUnsafeMutableBytes { try opened.read(into: $0.baseAddress!, frames: UInt32(frames)) }
            guard count > 0 else { throw AudioFailure("The next track contains no audio.") }
            data.count = Int(count) * Int(decoder.pcmFormat.mBytesPerFrame)
            prefix = data
        } catch {
            if acquired { item.accessRoot.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
    init(item: PlaybackContinuation, decoder: any AudioDecoding, prefix: Data) {
        self.item = item; self.decoder = decoder; self.prefix = prefix
        acquired = item.accessRoot.startAccessingSecurityScopedResource()
    }
    deinit { if acquired { item.accessRoot.stopAccessingSecurityScopedResource() } }
}

/// One bounded decoder-open worker; obsolete queued requests do no filesystem work.
final class ContinuationPreparer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "catto.swar.continuation", qos: .utility)
    private let revision = OSAllocatedUnfairLock(initialState: UUID())
    func invalidate(_ request: UUID = UUID()) { revision.withLock { $0 = request } }
    func prepare(_ item: PlaybackContinuation, request: UUID, outputRate: Double? = nil) async -> PreparedContinuation? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard revision.withLock({ $0 == request }) else { continuation.resume(returning: nil); return }
                let result = try? PreparedContinuation(item, outputRate: outputRate)
                continuation.resume(returning: revision.withLock({ $0 == request }) ? result : nil)
            }
        }
    }
    func prepareCrossfade(current: PlaybackContinuation, next: PlaybackContinuation, overlap: Double,
                          rate: Double, request: UUID) async -> PreparedCrossfade? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard revision.withLock({ $0 == request }) else { continuation.resume(returning: nil); return }
                let result = try? PreparedCrossfade(current: current, next: next, overlap: overlap, rate: rate)
                continuation.resume(returning: revision.withLock({ $0 == request }) ? result : nil)
            }
        }
    }
}

/// Opened on a utility worker, then owned solely by the audio producer queue.
final class PreparedCrossfade: @unchecked Sendable {
    let outgoing: PreparedContinuation
    let incoming: PreparedContinuation
    let reader: CrossfadePCMReader
    init(current: PlaybackContinuation, next: PlaybackContinuation, overlap: Double, rate: Double) throws {
        guard overlap.isFinite, (0.5...12).contains(overlap) else { throw AudioFailure("Invalid transition duration.") }
        outgoing = try PreparedContinuation(current, outputRate: rate)
        incoming = try PreparedContinuation(next, outputRate: rate)
        reader = try CrossfadePCMReader(outgoing: outgoing.decoder, incoming: incoming.decoder,
                                        overlapFrames: Int64((overlap * rate).rounded()))
        try reader.seek(to: reader.outgoingTransitionFrame)
    }
}

/// Single-queue producer and audible timeline. The render callback only sees its C ring.
final class GaplessPCM {
    struct Segment {
        let decoder: any AudioDecoding
        let url: URL
        let entryID: UUID?
        let token: UUID
        let start: UInt64
        let baseFrame: Int64
        let access: PreparedContinuation?
    }
    let ring: OpaquePointer
    private var segments: [Segment]
    private var prepared: PreparedContinuation?
    private var crossfade: PreparedCrossfade?
    private let processed: Bool
    private var committedFadeStart: UInt64?
    private var prefixOffset = 0
    private var prefix: Data = Data()
    private var scratch: UnsafeMutableRawPointer
    private let stride: Int
    private var written: UInt64 = 0
    private var deferredFailure: (token: UUID, message: String)?
    private(set) var eof = false
    private(set) var requestedID: UUID?
    private(set) var requestedToken: UUID?

    init(decoder: any AudioDecoding, url: URL, entryID: UUID? = nil, token: UUID? = nil, capacity: UInt32? = nil, processed: Bool = false) throws {
        self.processed = processed
        stride = Int(decoder.pcmFormat.mBytesPerFrame)
        guard !processed || (decoder.pcmFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && decoder.pcmFormat.mBitsPerChannel == 32
            && stride == Int(decoder.pcmFormat.mChannelsPerFrame) * 4) else {
            throw AudioFailure("Processed playback requires interleaved Float32 PCM.")
        }
        guard let ring = swar_ring_create(capacity ?? UInt32(decoder.source.sampleRate), decoder.pcmFormat.mBytesPerFrame) else {
            throw AudioFailure("Could not allocate a lock-free audio buffer.")
        }
        self.ring = ring
        scratch = .allocate(byteCount: 4096 * stride, alignment: 16)
        segments = [Segment(decoder: decoder, url: url, entryID: entryID, token: token ?? UUID(), start: 0, baseFrame: 0, access: nil)]
    }
    deinit { scratch.deallocate(); swar_ring_destroy(ring) }

    var audible: (segment: Segment, position: Double, duration: Double) {
        // Take one consumer counter snapshot so identity, time and format agree.
        let consumed = swar_ring_consumed(ring)
        while segments.count > 1, consumed >= segments[1].start { segments.removeFirst(); requestedID = nil; requestedToken = nil; committedFadeStart = nil }
        let active = segments[0]
        let rate = active.decoder.source.sampleRate
        let position = min(Double(active.decoder.frameCount), Double(active.baseFrame) + Double(consumed - active.start)) / rate
        return (active, position, Double(active.decoder.frameCount) / rate)
    }
    var current: Segment { audible.segment }
    var position: Double { audible.position }
    var duration: Double { audible.duration }
    var hasAudibleCrossfade: Bool {
        _ = current
        return committedFadeStart.map { swar_ring_consumed(ring) >= $0 } ?? false
    }
    var hasQueuedBoundary: Bool { _ = current; return segments.count > 1 }

    var failure: String? {
        guard let deferredFailure, current.token == deferredFailure.token else { return nil }
        return deferredFailure.message
    }
    func request(_ id: UUID?, after token: UUID? = nil) {
        let origin = token ?? current.token
        requestedID = id; requestedToken = origin; prepared = nil; crossfade = nil; committedFadeStart = nil
    }
    func install(_ next: PreparedContinuation) -> Bool {
        guard !hasQueuedBoundary else { return false }
        let active = current
        guard requestedID == next.item.id, requestedToken == active.token, !eof,
              Self.compatible(active.decoder.pcmFormat, next.decoder.pcmFormat) else { return false }
        prepared = next
        return true
    }

    func install(_ pair: PreparedCrossfade) -> Bool {
        guard processed, !hasQueuedBoundary, !eof, let prepared,
              prepared.item.id == pair.incoming.item.id, requestedID == pair.incoming.item.id,
              requestedToken == current.token,
              Self.compatible(current.decoder.pcmFormat, pair.incoming.decoder.pcmFormat) else { return false }
        let segment = segments[0]
        guard pair.reader.outgoingTransitionFrame >= segment.baseFrame else { return false }
        let start = segment.start + UInt64(pair.reader.outgoingTransitionFrame - segment.baseFrame)
        guard written <= start else { return false } // Already-buffered audio is never rewritten live.
        crossfade = pair
        committedFadeStart = start
        return true
    }

    // Caller must stop AUHAL before rewinding/discarding queued PCM.
    func seek(_ seconds: Double) throws {
        let active = current
        let frame = Int64(max(0, min(seconds, duration)) * active.decoder.source.sampleRate)
        try active.decoder.seek(to: frame)
        swar_ring_reset(ring)
        segments = [Segment(decoder: active.decoder, url: active.url, entryID: active.entryID,
                            token: active.token, start: 0, baseFrame: frame, access: active.access)]
        written = 0; eof = false; committedFadeStart = nil; prepared = nil; crossfade = nil; requestedID = nil; requestedToken = nil; deferredFailure = nil
        prefix = Data(); prefixOffset = 0
    }

    func fill(upTo target: UInt32 = .max) throws {
        guard !eof else { return }
        while swar_ring_writable(ring) > 0 {
            _ = current
            let readable = swar_ring_readable(ring)
            guard readable < target else { break }
            var requested = min(4096, swar_ring_writable(ring), target - readable)
            if let pair = crossfade, segments.count == 1 {
                let segment = segments[0]
                let start = segment.start + UInt64(pair.reader.outgoingTransitionFrame - segment.baseFrame)
                if written >= start {
                    let frames = try pair.reader.read(into: UnsafeMutableBufferPointer(start: scratch.assumingMemoryBound(to: Float.self), count: Int(requested) * pair.reader.channels), frames: Int(requested))
                    guard frames > 0, swar_ring_write(ring, scratch, UInt32(frames)) == UInt32(frames) else {
                        throw AudioFailure("Crossfade producer stopped unexpectedly.")
                    }
                    written += UInt64(frames)
                    if pair.reader.position >= pair.reader.incomingPromotionFrame {
                        let next = pair.incoming
                        segments.append(Segment(decoder: next.decoder, url: next.item.url, entryID: next.item.id,
                            token: next.token, start: written, baseFrame: pair.reader.overlapFrames, access: next))
                        prepared = nil; crossfade = nil; prefix = Data(); prefixOffset = 0
                    }
                    continue
                }
                requested = min(requested, UInt32(min(UInt64(requested), start - written)))
            }
            let count: UInt32
            if prefixOffset < prefix.count {
                count = min(requested, UInt32((prefix.count - prefixOffset) / stride))
                prefix.withUnsafeBytes { scratch.copyMemory(from: $0.baseAddress!.advanced(by: prefixOffset), byteCount: Int(count) * stride) }
                prefixOffset += Int(count) * stride
            } else {
                do { count = try segments.last!.decoder.read(into: scratch, frames: requested) }
                catch {
                    // A failing successor must not cut off the still-audible tail.
                    guard segments.count > 1 else { throw error }
                    deferredFailure = (segments.last!.token, error.localizedDescription)
                    eof = true; swar_ring_finish(ring); return
                }
            }
            if count == 0 {
                if let next = prepared, segments.count == 1 {
                    segments.append(Segment(decoder: next.decoder, url: next.item.url, entryID: next.item.id,
                                            token: next.token, start: written, baseFrame: 0, access: next))
                    prefix = next.prefix; prefixOffset = 0; prepared = nil
                    continue
                }
                eof = true; swar_ring_finish(ring); break
            }
            if processed, count > 0 {
                let samples = scratch.assumingMemoryBound(to: Float.self)
                for i in 0..<(Int(count) * Int(segments.last!.decoder.pcmFormat.mChannelsPerFrame)) {
                    samples[i] = samples[i].isFinite ? max(-1, min(1, samples[i])) * CrossfadeCurve.equalPower.dryGain : 0
                }
            }
            guard swar_ring_write(ring, scratch, count) == count else { throw AudioFailure("PCM buffer write failed.") }
            written += UInt64(count)
        }
    }

    static func compatible(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags &&
        a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame &&
        a.mBitsPerChannel == b.mBitsPerChannel && a.mBytesPerPacket == b.mBytesPerPacket && a.mFramesPerPacket == b.mFramesPerPacket
    }
}
