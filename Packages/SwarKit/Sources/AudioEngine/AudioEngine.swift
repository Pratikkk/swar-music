import AudioToolbox
import Decoding
import Foundation
import RealtimeAudio
import os

// MARK: - Logging
private let engineLog = Logger(subsystem: "catto.swar", category: "AudioEngine")
private let sessionLog = Logger(subsystem: "catto.swar", category: "AudioSession")
private let timerLog = Logger(subsystem: "catto.swar", category: "AudioTimer")
private let errorLog = Logger(subsystem: "catto.swar", category: "AudioError")

// Notification name for occlusion state changes
public extension Notification.Name {
    static let swarOcclusionStateChanged = Notification.Name("swarOcclusionStateChanged")
}

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
    /// Incoming queue entry only while its overlap is being consumed by the output.
    public let crossfadeID: UUID?

    public init(source: SourceFormat? = nil, output: OutputDescription? = nil, clientPCM: PlaybackPCMFormat? = nil,
                duration: Double = 0, position: Double = 0, isPlaying: Bool = false,
                underrunFrames: UInt64 = 0, error: String? = nil, didFinish: Bool = false, playbackToken: UUID? = nil, continuationID: UUID? = nil, needsOutputRecovery: Bool = false, isExclusive: Bool = false, crossfadeID: UUID? = nil) {
        self.source = source; self.output = output; self.clientPCM = clientPCM; self.duration = duration
        self.position = position; self.isPlaying = isPlaying
        self.underrunFrames = underrunFrames; self.error = error; self.didFinish = didFinish
        self.playbackToken = playbackToken; self.continuationID = continuationID
        self.needsOutputRecovery = needsOutputRecovery
        self.isExclusive = isExclusive
        self.crossfadeID = crossfadeID
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

/// The @unchecked boundary is limited to state owned by a single serial queue.
/// The C callback only sees a ring pointer with atomic counters, never this object.
public final class AudioPlaybackEngine: PlaybackDriving, @unchecked Sendable {
    // Two serial queues: control queue for UI operations, producer queue for decoding/PCM filling
    private let controlQueue: DispatchQueue
    private let producerQueue: DispatchQueue
    private let controlQueueKey = DispatchSpecificKey<UInt8>()
    private let producerQueueKey = DispatchSpecificKey<UInt8>()
    private let state = EngineState()

    public convenience init() {
        self.init(controlQueue: DispatchQueue(label: "catto.swar.audio.control", qos: .userInitiated),
                  producerQueue: DispatchQueue(label: "catto.swar.audio.producer", qos: .userInitiated))
    }

    init(controlQueue: DispatchQueue, producerQueue: DispatchQueue) {
        self.controlQueue = controlQueue
        self.producerQueue = producerQueue
        controlQueue.setSpecific(key: controlQueueKey, value: 1)
        producerQueue.setSpecific(key: producerQueueKey, value: 1)
        let state = state
        // Start the producer timer on the producer queue
        producerQueue.async { [producerQueue] in state.startProducerTimer(on: producerQueue) }
    }

    deinit { closeSynchronously() }

    public func open(_ url: URL) async throws -> PlaybackSnapshot {
        logOperation("open", url: url)
        do {
            let result = try await performOnControl { state in
                try Self.open(url, on: state)
            }
            engineLog.debug("open SUCCESS: \(url.path)")
            return result
        } catch {
            logError("open", error: error, url: url)
            throw error
        }
    }

    public func open(_ url: URL, outputDeviceID: UInt32?) async throws -> PlaybackSnapshot {
        logOperation("open", url: url, details: "deviceID=\(outputDeviceID?.description ?? "nil")")
        do {
            let result = try await performOnControl { state in
                state.deviceID = outputDeviceID
                return try Self.open(url, on: state)
            }
            engineLog.debug("open SUCCESS: \(url.path)")
            return result
        } catch {
            logError("open", error: error, url: url)
            throw error
        }
    }

    public func open(_ url: URL, outputDeviceID: UInt32?, crossfade: Bool) async throws -> PlaybackSnapshot {
        logOperation("open", url: url, details: "deviceID=\(outputDeviceID?.description ?? "nil") crossfade=\(crossfade)")
        do {
            let result = try await performOnControl { state in
                state.deviceID = outputDeviceID
                state.processed = crossfade
                return try Self.open(url, on: state)
            }
            engineLog.debug("open SUCCESS: \(url.path)")
            return result
        } catch {
            logError("open", error: error, url: url)
            throw error
        }
    }

    private static func open(_ url: URL, on state: EngineState) throws -> PlaybackSnapshot {
        engineLog.debug("EngineState.open: \(url.path)")
        state.closeSession()
        do {
            state.session = try OutputSession(decoder: DecoderFactory.open(url: url), url: url, deviceID: state.deviceID, exclusive: state.exclusiveOutput, processed: state.processed)
            state.url = url
            state.error = nil; state.needsRecovery = false
            engineLog.debug("EngineState.open SUCCESS: \(url.path)")
            return state.snapshot()
        } catch {
            state.closeSession()
            engineLog.error("EngineState.open FAILED: \(url.path) error=\(error.localizedDescription)")
            throw error
        }
    }

    public func togglePlayback() async throws -> PlaybackSnapshot {
        logOperation("togglePlayback")
        do {
            let result = try await performOnControl { state in
                guard let session = state.session else { throw AudioFailure("Open an audio file first.") }
                do {
                    if session.isPlaying { try session.pause() }
                    else { try session.play() }
                    state.error = nil; state.needsRecovery = false
                    state.scheduleProducerTimerUpdate()
                    return state.snapshot()
                } catch {
                    try? session.pause()
                    state.error = error.localizedDescription
                    state.needsRecovery = error is OutputRecoveryFailure
                    throw error
                }
            }
            engineLog.debug("togglePlayback SUCCESS")
            return result
        } catch {
            logError("togglePlayback", error: error)
            throw error
        }
    }

    public func seek(to seconds: Double) async throws -> PlaybackSnapshot {
        logOperation("seek", details: "seconds=\(seconds)")
        do {
            let result = try await performOnControl { state in
                guard seconds.isFinite, let session = state.session else { throw AudioFailure("No seekable file is open.") }
                do {
                    try session.seek(seconds)
                    state.error = nil; state.needsRecovery = false
                    state.scheduleProducerTimerUpdate()
                    return state.snapshot()
                } catch {
                    try? session.pause()
                    state.error = error.localizedDescription
                    state.needsRecovery = error is OutputRecoveryFailure
                    throw error
                }
            }
            engineLog.debug("seek SUCCESS: seconds=\(seconds)")
            return result
        } catch {
            logError("seek", error: error, details: "seconds=\(seconds)")
            throw error
        }
    }

    public func seek(to seconds: Double, resume: Bool) async throws -> PlaybackSnapshot {
        logOperation("seek", details: "seconds=\(seconds) resume=\(resume)")
        do {
            let result = try await performOnControl { state in
                guard seconds.isFinite, let session = state.session else { throw AudioFailure("No seekable file is open.") }
                do {
                    try session.seek(seconds, resume: resume)
                    state.error = nil; state.needsRecovery = false
                    state.scheduleProducerTimerUpdate()
                    return state.snapshot()
                } catch {
                    try? session.pause()
                    state.error = error.localizedDescription
                    state.needsRecovery = error is OutputRecoveryFailure
                    throw error
                }
            }
            engineLog.debug("seek SUCCESS: seconds=\(seconds) resume=\(resume)")
            return result
        } catch {
            logError("seek", error: error, details: "seconds=\(seconds) resume=\(resume)")
            throw error
        }
    }

    public func selectOutput(_ deviceID: UInt32?, pause: Bool = false, exclusive: Bool = false) async throws -> PlaybackSnapshot {
        logOperation("selectOutput", details: "deviceID=\(deviceID?.description ?? "nil") pause=\(pause) exclusive=\(exclusive)")
        do {
            let result = try await performOnControl { state in
                let snapshot = try Self.switchOutput(deviceID, pause: pause, force: false, resumeOverride: nil, exclusive: exclusive, state: state)
                state.scheduleProducerTimerUpdate()
                return snapshot
            }
            engineLog.debug("selectOutput SUCCESS: deviceID=\(deviceID?.description ?? "nil")")
            return result
        } catch {
            logError("selectOutput", error: error, details: "deviceID=\(deviceID?.description ?? "nil")")
            throw error
        }
    }

    public func recoverOutput(_ deviceID: UInt32?, resume: Bool, exclusive: Bool = false) async throws -> PlaybackSnapshot {
        logOperation("recoverOutput", details: "deviceID=\(deviceID?.description ?? "nil") resume=\(resume) exclusive=\(exclusive)")
        do {
            let result = try await performOnControl { state in
                let snapshot = try Self.switchOutput(deviceID, pause: !resume, force: true, resumeOverride: resume, exclusive: exclusive, state: state)
                state.scheduleProducerTimerUpdate()
                return snapshot
            }
            engineLog.debug("recoverOutput SUCCESS: deviceID=\(deviceID?.description ?? "nil")")
            return result
        } catch {
            logError("recoverOutput", error: error, details: "deviceID=\(deviceID?.description ?? "nil")")
            throw error
        }
    }

    public func suspendOutput() async -> PlaybackSnapshot {
        logOperation("suspendOutput")
        let result = (try? await performOnControl { state in
            if let session = state.session { try? session.pause() }
            let saved = state.snapshot()
            let recovery = state.session.map { session in
                let audible = session.pcm.audible
                return (url: audible.segment.url, position: audible.position,
                        entryID: audible.segment.entryID, token: audible.segment.token)
            } ?? state.routeRecovery
            state.closeSession()
            state.routeRecovery = recovery
            state.scheduleProducerTimerUpdate()
            return PlaybackSnapshot(source: saved.source, duration: saved.duration, position: saved.position,
                playbackToken: saved.playbackToken, continuationID: saved.continuationID)
        }) ?? PlaybackSnapshot()
        engineLog.debug("suspendOutput result: \(result.isPlaying ? "playing" : "paused")")
        return result
    }

    private func performOnControl<T: Sendable>(_ operation: @escaping @Sendable (EngineState) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let state = state
            controlQueue.async {
                continuation.resume(with: Result { try operation(state) })
            }
        }
    }

    private func logOperation(_ name: String, url: URL? = nil, details: String = "") {
        let urlStr = url?.path ?? "nil"
        engineLog.debug("\(name): url=\(urlStr) \(details)")
    }

    private func logError(_ name: String, error: Error, url: URL? = nil, details: String = "") {
        let urlStr = url?.path ?? "nil"
        errorLog.error("\(name) FAILED: url=\(urlStr) \(details) error=\(error.localizedDescription)")
    }

    /// For producer queue operations that need to be scheduled from control queue context
    private func scheduleOnProducer(_ operation: @escaping @Sendable (EngineState) -> Void) {
        producerQueue.async { operation(self.state) }
    }

    public func prepareNext(_ next: PlaybackContinuation?, after token: UUID) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        let shouldPrepare = (try? await performOnControl { state -> Bool in
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
        let format = try? await performOnControl { state -> (Double, Int)? in
            guard let session = state.session, session.processed else { return nil }
            return (session.decoder.pcmFormat.mSampleRate, Int(session.decoder.pcmFormat.mChannelsPerFrame))
        }
        let prepared = await state.preparer.prepare(next, request: request,
            outputRate: format?.0, outputChannels: format?.1)
        guard !Task.isCancelled, let prepared else { return }
        _ = try? await performOnControl { state in
            guard state.preparation == request, let session = state.session,
                  session.pcm.current.token == token else { return }
            _ = session.pcm.install(prepared)
        }
    }

    public func prepareCrossfade(_ next: PlaybackContinuation, currentRoot: URL, overlap: Double, after token: UUID) async {
        guard !Task.isCancelled else { return }
        let context = try? await performOnControl { state -> (PlaybackContinuation, Double, UUID, Int)? in
            guard let session = state.session, session.processed, session.pcm.current.token == token,
                  session.pcm.requestedID == next.id, !session.pcm.hasQueuedBoundary else { return nil }
            return (PlaybackContinuation(id: token, url: session.pcm.current.url, accessRoot: currentRoot, duration: Double(session.pcm.current.decoder.frameCount) / session.pcm.current.decoder.pcmFormat.mSampleRate),
                    session.decoder.pcmFormat.mSampleRate, state.preparation, Int(session.decoder.pcmFormat.mChannelsPerFrame))
        }
        guard let context = context ?? nil else { return }
        let pair = await state.preparer.prepareCrossfade(current: context.0, next: next,
            overlap: overlap, rate: context.1, channels: context.3, request: context.2)
        guard !Task.isCancelled, let pair else { return }
        _ = try? await performOnControl { state in
            guard state.preparation == context.2, let session = state.session,
                  session.pcm.current.token == token else { return }
            _ = session.pcm.install(pair)
        }
    }

    public func snapshot() async -> PlaybackSnapshot {
        await withCheckedContinuation { continuation in
            let state = state
            controlQueue.async { continuation.resume(returning: state.snapshot()) }
        }
    }

    /// For application termination: stop/dispose the unit before releasing file access.
    public func shutdown() { closeSynchronously() }

    /// Pause the producer timer when app is occluded/backgrounded to save CPU/battery.
    public func setOccluded(_ occluded: Bool) {
        controlQueue.async { [state] in
            if occluded {
                state.pauseProducerTimer()
            } else {
                state.resumeProducerTimer()
            }
        }
        NotificationCenter.default.post(name: .swarOcclusionStateChanged, object: nil, userInfo: ["occluded": occluded])
    }

    private func closeSynchronously() {
        let state = state
        // Drain pending work on both queues before releasing decoder/device resources.
        if DispatchQueue.getSpecific(key: producerQueueKey) == nil {
            producerQueue.sync { state.closeProducer() }
        } else {
            state.closeProducer()
        }
        if DispatchQueue.getSpecific(key: controlQueueKey) == nil {
            controlQueue.sync { state.closeControl() }
        } else {
            state.closeControl()
        }
    }

    private static func switchOutput(_ deviceID: UInt32?, pause: Bool, force: Bool, resumeOverride: Bool?, exclusive: Bool, state: EngineState) throws -> PlaybackSnapshot {
        engineLog.debug("switchOutput: deviceID=\(deviceID?.description ?? "nil") pause=\(pause) force=\(force) exclusive=\(exclusive)")
        _ = state.snapshot()
        // Handle nil session (recovery case) - early return
        if state.session == nil {
            engineLog.debug("switchOutput: no session, recovery=\(state.routeRecovery != nil)")
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
                state.exclusiveOutput = exclusive
                state.scheduleProducerTimerUpdate()
                return state.snapshot()
            }
            // No session and no recovery - nothing to switch
            state.scheduleProducerTimerUpdate()
            return state.snapshot()
        }
        
        // Session exists - continue with normal switching logic
        let session = state.session!
        if !force, state.exclusiveOutput == exclusive, session.device.id == deviceID, session.outputStatus.error == nil, state.error == nil {
            engineLog.debug("switchOutput: same device, no switch needed")
            state.error = nil; state.needsRecovery = false
            if pause { try session.pause() }
            state.deviceID = deviceID
            state.scheduleProducerTimerUpdate()
            return state.snapshot()
        }
        let previous = state.deviceID
        let resume = (resumeOverride ?? session.isPlaying) && !pause
        engineLog.debug("switchOutput: switching device, previous=\(previous as NSObject?) new=\(deviceID?.description ?? "nil") resume=\(resume) pause=\(pause)")
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
            state.scheduleProducerTimerUpdate()
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

private final class EngineState: @unchecked Sendable {
    // Fields accessed from BOTH queues (protected by queue-specific access patterns):
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
    
    // Lock to protect session/pcm access across control and producer queues
    private let sessionLock = OSAllocatedUnfairLock()
    
    // Producer queue only:
    private var producerTimer: DispatchSourceTimer?
    private var isProducerPaused = false
    private weak var producerQueue: DispatchQueue?
    private var lastTimerInterval: DispatchTimeInterval?

    func scheduleProducerTimerUpdate() {
        // Called on control queue - schedule timer update on producer queue
        // Must hop to producer queue to modify the timer
        producerQueue?.async { [weak self] in
            self?.updateProducerTimerOnProducerQueue()
        }
    }

    private func updateProducerTimerOnProducerQueue() {
        let shouldPump = session?.isPlaying == true && !isProducerPaused
        let interval: DispatchTimeInterval = shouldPump ? .milliseconds(150) : .milliseconds(0)
        // Use distantFuture to stop instead of a zero repeating interval
        let stop = !shouldPump
        if !stop, lastTimerInterval == interval { return }
        lastTimerInterval = stop ? nil : interval
        if stop {
            producerTimer?.schedule(deadline: .distantFuture)
        } else {
            producerTimer?.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(10))
        }
    }

    func startProducerTimer(on queue: DispatchQueue) {
        self.producerQueue = queue
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Initial schedule - will be updated by scheduleProducerTimerUpdate when playback starts
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Use lock to safely access session and pump
            self.sessionLock.lock()
            let session = self.session
            let isPlaying = session?.isPlaying ?? false
            let isPaused = self.isProducerPaused
            self.sessionLock.unlock()
             guard let session, isPlaying, !isPaused else { return }

             do { try session.pump() }
            catch {
                self.sessionLock.lock()
                try? session.pause()
                self.error = error.localizedDescription
                self.needsRecovery = error is OutputRecoveryFailure
                self.sessionLock.unlock()
                engineLog.error("Playback stopped: \(error.localizedDescription, privacy: .public)")
            }
        }
        self.producerTimer = timer
        timer.resume()
    }

    /// Pause the producer timer when app is occluded/backgrounded to save CPU/battery.
    func pauseProducerTimer() {
        isProducerPaused = true
        producerQueue?.async { [weak self] in
            self?.updateProducerTimerOnProducerQueue()
        }
    }
    
    /// Resume the producer timer when app becomes visible again.
    func resumeProducerTimer() {
        isProducerPaused = false
        producerQueue?.async { [weak self] in
            self?.updateProducerTimerOnProducerQueue()
        }
    }

    func snapshot() -> PlaybackSnapshot {
        sessionLock.lock()
        defer { sessionLock.unlock() }
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
                                isExclusive: session?.exclusive ?? false, crossfadeID: audible?.crossfadeID)
    }

    func closeSession() { 
        sessionLock.lock()
        defer { sessionLock.unlock() }
        preparer.invalidate(); preparation = UUID(); session?.close(); session = nil; url = nil; routeRecovery = nil; error = nil; needsRecovery = false 
    }

    func closeControl() {
        // Called on control queue
    }

    func closeProducer() {
        // Called on producer queue
        producerTimer?.cancel()
        producerTimer = nil
        closeSession()
    }
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
    private var _isPlaying = false
    private var closed = false
    var duration: Double { pcm.duration }
    var position: Double { pcm.position }

    let exclusive: Bool
    
    // Lock to protect session state across control and producer queues
    // NSRecursiveLock allows re-entrant calls (play->seek->pause, pump->pause) from the same thread
    private let lock = NSRecursiveLock()
    
    var isPlaying: Bool {
        lock.lock()
        let playing = _isPlaying
        lock.unlock()
        return playing
    }
    
    private func setPlaying(_ playing: Bool) {
        lock.lock()
        _isPlaying = playing
        lock.unlock()
    }

    init(decoder: any AudioDecoding, url: URL, deviceID: UInt32? = nil, entryID: UUID? = nil, token: UUID? = nil, exclusive: Bool = false, processed: Bool = false) throws {
        self.exclusive = exclusive; self.processed = processed
        let decoder: any AudioDecoding = try processed ? ConvertedPCMDecoder(decoder: decoder, sampleRate: decoder.pcmFormat.mSampleRate,
            channels: decoder.pcmFormat.mChannelsPerFrame == 1 ? 2 : nil) : decoder
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
        _isPlaying = true
        deviceMonitor?.setActive(true)
        sessionLog.debug("resumeDevice SUCCESS")
    }

    func play() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let unit, !closed else { throw AudioFailure("The output session is closed.") }
        try device.validate(rate: decoder.source.sampleRate)
        // Explicit start may configure/query HAL. Periodic snapshots never do.
        deviceMonitor?.reset(output: try? device.description())
        if position >= duration { try seek(0, resume: false) }
        try resumeDevice()
        _isPlaying = true
        sessionLog.debug("play SUCCESS")
    }

    func pause() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let unit else { return }
        do { try checkAudio(AudioOutputUnitStop(unit), "Pause AUHAL") }
        catch { throw OutputRecoveryFailure(message: error.localizedDescription) }
        _isPlaying = false
        deviceMonitor?.setActive(false)
        sessionLog.debug("pause SUCCESS")
    }

    func seek(_ seconds: Double, resume: Bool? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        let shouldResume = resume ?? _isPlaying
        sessionLog.debug("seek: seconds=\(seconds) resume=\(resume?.description ?? "auto")")
        if _isPlaying { try pause() }
        let target = Int64(max(0, min(seconds, duration) * Double(decoder.source.sampleRate)))
        try pcm.seek(seconds)
        didFinish = false
        // A paused scrub preview needs neither decoded lead-in nor a device
        // restart; the release seek primes and starts once.
        guard shouldResume else { return }
        if target < decoder.frameCount { try resumeDevice() }
        else if target == decoder.frameCount { didFinish = true }
        sessionLog.debug("seek SUCCESS: target=\(target)")
    }

    func pump() throws {
        lock.lock()
        defer { lock.unlock() }
        if let error = outputStatus.error { throw OutputRecoveryFailure(message: error) }
        try pcm.fill()
        if let failure = pcm.failure { throw AudioFailure(failure) }
        if pcm.eof, let ring, swar_ring_readable(ring) == 0 {
            try pause()
            didFinish = true
        }
        // pump is called frequently, only log at debug level periodically if needed
    }

    private func prime() throws {
        // Start with 200 ms, then let the 10 ms producer timer fill the one-second ring.
        // Capacity is unchanged; only synchronous decode work before start/seek is bounded.
        try pcm.fill(upTo: UInt32(ceil(decoder.source.sampleRate * 0.2)))
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
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
        _isPlaying = false
        device.restore()
        try? device.releaseHog()
        sessionLog.debug("close SUCCESS")
    }
}
}
