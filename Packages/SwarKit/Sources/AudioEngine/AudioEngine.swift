import AudioToolbox
import Decoding
import Foundation
import RealtimeAudio
import os

public struct PlaybackPCMFormat: Sendable, Equatable {
    public let sampleRate: Double
    public let validBits: Int
    public let containerBits: Int
    public let channels: Int
    public let isFloat: Bool

    public init(sampleRate: Double, validBits: Int, containerBits: Int,
                channels: Int, isFloat: Bool) {
        self.sampleRate = sampleRate
        self.validBits = validBits
        self.containerBits = containerBits
        self.channels = channels
        self.isFloat = isFloat
    }
}

public struct PlaybackSnapshot: Sendable {
    public let source: SourceFormat?
    public let clientPCM: PlaybackPCMFormat?
    public let output: OutputDescription?
    public let duration: Double
    public let position: Double
    public let isPlaying: Bool
    public let underrunFrames: UInt64
    public let error: String?
    public let didFinish: Bool
    public let playbackToken: UUID?
    public let continuationID: UUID?
    public let needsOutputRecovery: Bool
    public let isExclusive: Bool

    public init(source: SourceFormat? = nil, output: OutputDescription? = nil, clientPCM: PlaybackPCMFormat? = nil,
                duration: Double = 0, position: Double = 0, isPlaying: Bool = false,
                underrunFrames: UInt64 = 0, error: String? = nil, didFinish: Bool = false, playbackToken: UUID? = nil, continuationID: UUID? = nil, needsOutputRecovery: Bool = false, isExclusive: Bool = false) {
        self.source = source; self.output = output; self.clientPCM = clientPCM; self.duration = duration
        self.position = position; self.isPlaying = isPlaying
        self.underrunFrames = underrunFrames; self.error = error; self.didFinish = didFinish
        self.playbackToken = playbackToken; self.continuationID = continuationID
        self.needsOutputRecovery = needsOutputRecovery
        self.isExclusive = isExclusive
    }
}

/// Also allows queue behavior to be tested without touching an audio device.
public protocol PlaybackDriving: Sendable {
    func open(_ url: URL) async throws -> PlaybackSnapshot
    func open(_ url: URL, outputDeviceID: UInt32?) async throws -> PlaybackSnapshot
    func togglePlayback() async throws -> PlaybackSnapshot
    func seek(to seconds: Double) async throws -> PlaybackSnapshot
    /// Seek without implicitly resuming. Scrubbing pauses once, sends paused
    /// preview seeks, then resumes only on release.
    func seek(to seconds: Double, resume: Bool) async throws -> PlaybackSnapshot
    func snapshot() async -> PlaybackSnapshot
    func shutdown()
    func prepareNext(_ next: PlaybackContinuation?, after token: UUID) async
    func open(_ url: URL, outputDeviceID: UInt32?, crossfade: Bool) async throws -> PlaybackSnapshot
    func prepareCrossfade(_ next: PlaybackContinuation, currentRoot: URL, overlap: Double, after token: UUID) async
    func suspendOutput() async -> PlaybackSnapshot
    func recoverOutput(_ deviceID: UInt32?, resume: Bool, exclusive: Bool) async throws -> PlaybackSnapshot
    func selectOutput(_ deviceID: UInt32?, pause: Bool, exclusive: Bool) async throws -> PlaybackSnapshot
}

public extension PlaybackDriving {
    func seek(to seconds: Double, resume: Bool) async throws -> PlaybackSnapshot {
        try await seek(to: seconds)
    }
    func suspendOutput() async -> PlaybackSnapshot {
        let state = await snapshot()
        return state.isPlaying ? ((try? await togglePlayback()) ?? state) : state
    }
    func recoverOutput(_ deviceID: UInt32?, resume: Bool, exclusive: Bool = false) async throws -> PlaybackSnapshot {
        var state = try await selectOutput(deviceID, pause: !resume, exclusive: exclusive)
        if resume, !state.isPlaying, state.duration > 0 { state = try await togglePlayback() }
        return state
    }
    func prepareNext(_ next: PlaybackContinuation?, after token: UUID) async {}
    func open(_ url: URL, outputDeviceID: UInt32?, crossfade: Bool) async throws -> PlaybackSnapshot {
        try await open(url, outputDeviceID: outputDeviceID)
    }
    func prepareCrossfade(_ next: PlaybackContinuation, currentRoot: URL, overlap: Double, after token: UUID) async {}
    func open(_ url: URL, outputDeviceID: UInt32?) async throws -> PlaybackSnapshot { try await open(url) }
    func selectOutput(_ deviceID: UInt32?, pause: Bool, exclusive: Bool = false) async throws -> PlaybackSnapshot { await snapshot() }
}

private let engineLog = Logger(subsystem: "catto.swar", category: "AudioEngine")

/// The @unchecked boundary is limited to state owned by a single serial queue.
/// The C callback only sees a ring pointer with atomic counters, never this object.
public final class AudioPlaybackEngine: PlaybackDriving, @unchecked Sendable {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let state = EngineState()

    public convenience init() {
        self.init(queue: DispatchQueue(label: "catto.swar.audio", qos: .userInitiated))
    }

    // The supplied execution context must be serial, like the production queue.
    init(queue: DispatchQueue) {
        self.queue = queue
        queue.setSpecific(key: queueKey, value: 1)
        let state = state
        queue.async { [queue] in state.startTimer(on: queue) }
    }

    deinit { closeSynchronously() }

    public func open(_ url: URL) async throws -> PlaybackSnapshot {
        try await perform { state in
            try Self.open(url, on: state)
        }
    }

    public func open(_ url: URL, outputDeviceID: UInt32?) async throws -> PlaybackSnapshot {
        try await perform { state in
            state.deviceID = outputDeviceID
            return try Self.open(url, on: state)
        }
    }

    public func open(_ url: URL, outputDeviceID: UInt32?, crossfade: Bool) async throws -> PlaybackSnapshot {
        try await perform { state in
            state.deviceID = outputDeviceID
            state.processed = crossfade
            return try Self.open(url, on: state)
        }
    }

    private static func open(_ url: URL, on state: EngineState) throws -> PlaybackSnapshot {
        state.closeSession()
        do {
            state.session = try OutputSession(decoder: DecoderFactory.open(url: url), url: url, deviceID: state.deviceID, exclusive: state.exclusiveOutput, processed: state.processed)
            state.url = url
            state.error = nil; state.needsRecovery = false
            return state.snapshot()
        } catch {
            state.closeSession()
            throw error
        }
    }

    public func togglePlayback() async throws -> PlaybackSnapshot {
        try await perform { state in
            guard let session = state.session else { throw AudioFailure("Open an audio file first.") }
            do {
                if session.isPlaying { try session.pause() }
                else { try session.play() }
                state.error = nil; state.needsRecovery = false
                return state.snapshot()
            } catch {
                try? session.pause()
                state.error = error.localizedDescription
                state.needsRecovery = error is OutputRecoveryFailure
                throw error
            }
        }
    }

    public func seek(to seconds: Double) async throws -> PlaybackSnapshot {
        try await perform { state in
            guard seconds.isFinite, let session = state.session else { throw AudioFailure("No seekable file is open.") }
            do {
                try session.seek(seconds)
                state.error = nil; state.needsRecovery = false
                return state.snapshot()
            } catch {
                try? session.pause()
                state.error = error.localizedDescription
                state.needsRecovery = error is OutputRecoveryFailure
                throw error
            }
        }
    }

    public func seek(to seconds: Double, resume: Bool) async throws -> PlaybackSnapshot {
        try await perform { state in
            guard seconds.isFinite, let session = state.session else { throw AudioFailure("No seekable file is open.") }
            do {
                try session.seek(seconds, resume: resume)
                state.error = nil; state.needsRecovery = false
                return state.snapshot()
            } catch {
                try? session.pause()
                state.error = error.localizedDescription
                state.needsRecovery = error is OutputRecoveryFailure
                throw error
            }
        }
    }

    public func selectOutput(_ deviceID: UInt32?, pause: Bool = false, exclusive: Bool = false) async throws -> PlaybackSnapshot {
        try await switchOutput(deviceID, pause: pause, force: false, resumeOverride: nil, exclusive: exclusive)
    }

    public func recoverOutput(_ deviceID: UInt32?, resume: Bool, exclusive: Bool = false) async throws -> PlaybackSnapshot {
        try await switchOutput(deviceID, pause: !resume, force: true, resumeOverride: resume, exclusive: exclusive)
    }

    public func suspendOutput() async -> PlaybackSnapshot {
        (try? await perform { state in
            if let session = state.session { try? session.pause() }
            let saved = state.snapshot()
            let recovery = state.session.map { session in
                let audible = session.pcm.audible
                return (url: audible.segment.url, position: audible.position,
                        entryID: audible.segment.entryID, token: audible.segment.token)
            } ?? state.routeRecovery
            state.closeSession()
            state.routeRecovery = recovery
            return PlaybackSnapshot(source: saved.source, duration: saved.duration, position: saved.position,
                playbackToken: saved.playbackToken, continuationID: saved.continuationID)
        }) ?? PlaybackSnapshot()
    }

    private func switchOutput(_ deviceID: UInt32?, pause: Bool, force: Bool, resumeOverride: Bool?, exclusive: Bool = false) async throws -> PlaybackSnapshot {
        try await perform { state in
            _ = state.snapshot()
            guard let session = state.session else {
                state.deviceID = deviceID
                if let recovery = state.routeRecovery {
                    do {
                        let replacement = try OutputSession(decoder: DecoderFactory.open(url: recovery.url), url: recovery.url, deviceID: deviceID, entryID: recovery.entryID, token: recovery.token, exclusive: exclusive, processed: state.processed)
                        state.session = replacement; state.url = recovery.url
                        try replacement.seek(recovery.position)
                        if resumeOverride == true { try replacement.play() }
                        state.routeRecovery = nil; state.error = nil; state.needsRecovery = false
                        state.exclusiveOutput = exclusive
                    } catch {
                        state.closeSession(); state.routeRecovery = recovery; state.needsRecovery = true
                        throw error
                    }
                }
                state.exclusiveOutput = exclusive
                return state.snapshot()
            }
            if !force, state.exclusiveOutput == exclusive, session.device.id == deviceID, session.outputStatus.error == nil, state.error == nil {
                state.error = nil; state.needsRecovery = false
                if pause { try session.pause() }
                state.deviceID = deviceID
                return state.snapshot()
            }
            let previous = state.deviceID
            let resume = (resumeOverride ?? session.isPlaying) && !pause
            // A vanished driver can reject Stop; disposal must still allow rebuilding.
            try? session.pause()
            let audible = session.pcm.audible
            let url = audible.segment.url
            let playbackToken = audible.segment.token
            let entryID = audible.segment.entryID
            let position = audible.position
            state.closeSession()
            do {
                let replacement = try OutputSession(decoder: DecoderFactory.open(url: url), url: url, deviceID: deviceID, entryID: entryID, token: playbackToken, exclusive: exclusive, processed: state.processed)
                state.session = replacement; state.url = url
                try replacement.seek(position)
                if resume { try replacement.play() }
                state.deviceID = deviceID
                state.exclusiveOutput = exclusive
                return state.snapshot()
            } catch {
                let failure = error
                state.closeSession()
                // Best-effort rollback retains the song and position on an incompatible output.
                do {
                    guard !force else { throw failure }
                    let old = try OutputSession(decoder: DecoderFactory.open(url: url), url: url, deviceID: previous, entryID: entryID, token: playbackToken, exclusive: state.exclusiveOutput, processed: state.processed)
                    state.session = old; state.url = url
                    try old.seek(position)
                    if resume { try old.play() }
                } catch { state.closeSession() }
                if state.session == nil {
                    state.routeRecovery = (url, position, entryID, playbackToken)
                    state.error = failure.localizedDescription
                    state.needsRecovery = true
                }
                throw failure
            }
        }
    }

    public func prepareNext(_ next: PlaybackContinuation?, after token: UUID) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        let shouldPrepare = (try? await perform { state -> Bool in
            guard let session = state.session, session.pcm.current.token == token else { return false }
            if session.pcm.hasAudibleCrossfade { return false }
            if session.pcm.requestedID == next?.id, session.pcm.requestedToken == token { return false }
            state.preparation = request
            state.preparer.invalidate(request)
            if session.pcm.hasQueuedBoundary { try session.seek(session.position) }
            guard session.pcm.current.token == token else { return false }
            session.pcm.request(next?.id, after: token)
            return next != nil
        }) ?? false
        guard shouldPrepare, let next, !Task.isCancelled else { return }
        let rate = try? await perform { state in state.session.flatMap { $0.processed ? $0.decoder.pcmFormat.mSampleRate : nil } }
        let prepared = await state.preparer.prepare(next, request: request, outputRate: rate ?? nil)
        guard !Task.isCancelled, let prepared else { return }
        _ = try? await perform { state in
            guard state.preparation == request, let session = state.session,
                  session.pcm.current.token == token else { return }
            _ = session.pcm.install(prepared)
        }
    }

    public func prepareCrossfade(_ next: PlaybackContinuation, currentRoot: URL, overlap: Double, after token: UUID) async {
        guard !Task.isCancelled else { return }
        let context = try? await perform { state -> (PlaybackContinuation, Double, UUID)? in
            guard let session = state.session, session.processed, session.pcm.current.token == token,
                  session.pcm.requestedID == next.id, !session.pcm.hasQueuedBoundary else { return nil }
            return (PlaybackContinuation(id: token, url: session.pcm.current.url, accessRoot: currentRoot),
                    session.decoder.pcmFormat.mSampleRate, state.preparation)
        }
        guard let context = context ?? nil else { return }
        let pair = await state.preparer.prepareCrossfade(current: context.0, next: next,
            overlap: overlap, rate: context.1, request: context.2)
        guard !Task.isCancelled, let pair else { return }
        _ = try? await perform { state in
            guard state.preparation == context.2, let session = state.session,
                  session.pcm.current.token == token else { return }
            _ = session.pcm.install(pair)
        }
    }

    public func snapshot() async -> PlaybackSnapshot {
        await withCheckedContinuation { continuation in
            let state = state
            queue.async { continuation.resume(returning: state.snapshot()) }
        }
    }

    /// For application termination: stop/dispose the unit before releasing file access.
    public func shutdown() { closeSynchronously() }

    private func closeSynchronously() {
        let state = state
        // Drain pending work before releasing decoder/device resources. The last
        // owner can also release the engine on its own queue; syncing there
        // would deadlock. Neither branch queues deferred teardown or captures self.
        if DispatchQueue.getSpecific(key: queueKey) != nil { state.close() }
        else { queue.sync { state.close() } }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (EngineState) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let state = state
            queue.async {
                defer { state.updateTimer() }
                continuation.resume(with: Result { try operation(state) })
            }
        }
    }
}

private final class EngineState: @unchecked Sendable {
    // Every field is accessed only on AudioPlaybackEngine.queue.
    var session: OutputSession?
    let preparer = ContinuationPreparer()
    var preparation = UUID()
    var deviceID: UInt32?
    var exclusiveOutput = false
    var processed = false
    var url: URL?
    var routeRecovery: (url: URL, position: Double, entryID: UUID?, token: UUID)?
    var error: String?
    var needsRecovery = false
    private var timer: DispatchSourceTimer?
    private var pumping = false

    func startTimer(on queue: DispatchQueue) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in
            guard let self, let session, session.isPlaying else { return }
            defer { self.updateTimer() }
            do { try session.pump() }
            catch {
                try? session.pause()
                self.error = error.localizedDescription
                self.needsRecovery = error is OutputRecoveryFailure
                engineLog.error("Playback stopped: \(error.localizedDescription, privacy: .public)")
            }
        }
        self.timer = timer
        timer.resume()
    }

    func updateTimer() {
        let shouldPump = session?.isPlaying == true
        guard pumping != shouldPump else { return }
        pumping = shouldPump
        if shouldPump {
            timer?.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .milliseconds(10))
        } else {
            // Keep the source balanced and reusable, without waking while idle.
            timer?.schedule(deadline: .distantFuture)
        }
    }

    func snapshot() -> PlaybackSnapshot {
        defer { updateTimer() }
        let audible = session?.pcm.audible
        if let audible { url = audible.segment.url }
        return PlaybackSnapshot(source: audible.map { ($0.segment.decoder as? ConvertedPCMDecoder)?.originalSource ?? $0.segment.decoder.source },
                                output: session?.outputStatus.output,
                                clientPCM: audible.map { value in
                                    let pcm = value.segment.decoder.pcmFormat
                                    let containerBits = Int(pcm.mBytesPerFrame) * 8 / max(1, Int(pcm.mChannelsPerFrame))
                                    return PlaybackPCMFormat(
                                        sampleRate: pcm.mSampleRate,
                                        validBits: Int(pcm.mBitsPerChannel),
                                        containerBits: containerBits,
                                        channels: Int(pcm.mChannelsPerFrame),
                                        isFloat: pcm.mFormatFlags & kAudioFormatFlagIsFloat != 0)
                                },
                                duration: audible?.duration ?? 0, position: audible?.position ?? 0,
                                isPlaying: session?.isPlaying ?? false,
                                underrunFrames: session.flatMap { $0.ring.map(swar_ring_underruns) } ?? 0,
                                error: error, didFinish: session?.didFinish ?? false,
                                playbackToken: audible?.segment.token, continuationID: audible?.segment.entryID,
                                needsOutputRecovery: needsRecovery || session?.outputStatus.error != nil,
                                isExclusive: session?.exclusive ?? false)
    }

    func closeSession() { preparer.invalidate(); preparation = UUID(); session?.close(); session = nil; url = nil; routeRecovery = nil; error = nil; needsRecovery = false }
    func close() { timer?.cancel(); timer = nil; pumping = false; closeSession() }
}

private final class OutputSession {
    let pcm: GaplessPCM
    let processed: Bool
    var decoder: any AudioDecoding { pcm.current.decoder }
    let device: OutputDevice
    private var deviceMonitor: OutputDeviceMonitor?
    var outputStatus: OutputDeviceStatus { deviceMonitor?.status ?? OutputDeviceStatus() }
    private var unit: AudioUnit?
    var ring: OpaquePointer? { closed ? nil : pcm.ring }
    private(set) var didFinish = false
    private(set) var isPlaying = false
    private var closed = false
    var duration: Double { pcm.duration }
    var position: Double { pcm.position }

    let exclusive: Bool

    init(decoder: any AudioDecoding, url: URL, deviceID: UInt32? = nil, entryID: UUID? = nil, token: UUID? = nil, exclusive: Bool = false, processed: Bool = false) throws {
        self.exclusive = exclusive; self.processed = processed
        let decoder: any AudioDecoding = try processed ? ConvertedPCMDecoder(decoder: decoder, sampleRate: decoder.pcmFormat.mSampleRate) : decoder
        pcm = try GaplessPCM(decoder: decoder, url: url, entryID: entryID, token: token, processed: processed)
        device = try OutputDevice(id: deviceID)
        do {
            if exclusive { try device.setHogged(true) }
            try device.configure(for: decoder.source, pcmFormat: decoder.pcmFormat)
            let buffer = self.pcm.ring
            var componentDescription = AudioComponentDescription(componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &componentDescription) else { throw AudioFailure("AUHAL is unavailable.") }
            var created: AudioUnit?
            try checkAudio(AudioComponentInstanceNew(component, &created), "Create AUHAL")
            guard let created else { throw AudioFailure("AUHAL did not create an output unit.") }
            unit = created
            var disabled: UInt32 = 0
            var enabled: UInt32 = 1
            try checkAudio(AudioUnitSetProperty(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disabled, 4), "Disable audio input")
            try checkAudio(AudioUnitSetProperty(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, 4), "Enable audio output")
            var deviceID = device.id
            try checkAudio(AudioUnitSetProperty(created, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, 4), "Select output device")
            var pcm = decoder.pcmFormat
            try checkAudio(AudioUnitSetProperty(created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &pcm, UInt32(MemoryLayout.size(ofValue: pcm))), "Set AUHAL client format")
            try checkAudio(swar_install_render_callback(created, buffer), "Install PCM render callback")
            try checkAudio(AudioUnitInitialize(created), "Initialize AUHAL")
            try prime()
            deviceMonitor = device.makeMonitor(rate: decoder.source.sampleRate)
            engineLog.info("Opened \(decoder.source.description, privacy: .public)")
        } catch { close(); throw error }
    }

    deinit { close() }

    private func resumeDevice() throws {
        guard let unit, !closed else { throw AudioFailure("The output session is closed.") }
        try prime()
        didFinish = false
        do { try checkAudio(AudioOutputUnitStart(unit), "Start AUHAL") }
        catch { throw OutputRecoveryFailure(message: error.localizedDescription) }
        isPlaying = true
        deviceMonitor?.setActive(true)
    }

    func play() throws {
        guard let unit, !closed else { throw AudioFailure("The output session is closed.") }
        try device.validate(rate: decoder.source.sampleRate)
        // Explicit start may configure/query HAL. Periodic snapshots never do.
        deviceMonitor?.reset(output: try? device.description())
        if position >= duration { try seek(0, resume: false) }
        try resumeDevice()
    }

    func pause() throws {
        guard let unit else { return }
        do { try checkAudio(AudioOutputUnitStop(unit), "Pause AUHAL") }
        catch { throw OutputRecoveryFailure(message: error.localizedDescription) }
        isPlaying = false
        deviceMonitor?.setActive(false)
    }

    func seek(_ seconds: Double, resume: Bool? = nil) throws {
        let shouldResume = resume ?? isPlaying
        if isPlaying { try pause() }
        let target = Int64(max(0, min(seconds, duration)) * decoder.source.sampleRate)
        try pcm.seek(seconds)
        didFinish = false
        // A paused scrub preview needs neither decoded lead-in nor a device
        // restart; the release seek primes and starts once.
        guard shouldResume else { return }
        if target < decoder.frameCount { try resumeDevice() }
        else if target == decoder.frameCount { didFinish = true }
    }

    func pump() throws {
        if let error = outputStatus.error { throw OutputRecoveryFailure(message: error) }
        try pcm.fill()
        if let failure = pcm.failure { throw AudioFailure(failure) }
        if pcm.eof, let ring, swar_ring_readable(ring) == 0 {
            try pause()
            didFinish = true
        }
    }

    private func prime() throws {
        // Start with 200 ms, then let the 10 ms producer timer fill the one-second ring.
        // Capacity is unchanged; only synchronous decode work before start/seek is bounded.
        try pcm.fill(upTo: UInt32(ceil(decoder.source.sampleRate * 0.2)))
    }

    func close() {
        guard !closed else { return }
        closed = true
        deviceMonitor?.setActive(false)
        deviceMonitor = nil
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        isPlaying = false
        device.restore()
        try? device.releaseHog()
    }
}
