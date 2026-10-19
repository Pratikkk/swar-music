import AudioToolbox
import Decoding
import Foundation
import RealtimeAudio
import os

public struct PlaybackSnapshot: Sendable {
    public let source: SourceFormat?
    public let output: OutputDescription?
    public let duration: Double
    public let position: Double
    public let isPlaying: Bool
    public let underrunFrames: UInt64
    public let error: String?
    public let didFinish: Bool

    public init(source: SourceFormat? = nil, output: OutputDescription? = nil,
                duration: Double = 0, position: Double = 0, isPlaying: Bool = false,
                underrunFrames: UInt64 = 0, error: String? = nil, didFinish: Bool = false) {
        self.source = source; self.output = output; self.duration = duration
        self.position = position; self.isPlaying = isPlaying
        self.underrunFrames = underrunFrames; self.error = error; self.didFinish = didFinish
    }
}

/// Also allows queue behavior to be tested without touching an audio device.
public protocol PlaybackDriving: Sendable {
    func open(_ url: URL) async throws -> PlaybackSnapshot
    func open(_ url: URL, outputDeviceID: UInt32?) async throws -> PlaybackSnapshot
    func togglePlayback() async throws -> PlaybackSnapshot
    func seek(to seconds: Double) async throws -> PlaybackSnapshot
    func snapshot() async -> PlaybackSnapshot
    func shutdown()
    func selectOutput(_ deviceID: UInt32?, pause: Bool) async throws -> PlaybackSnapshot
}

public extension PlaybackDriving {
    func open(_ url: URL, outputDeviceID: UInt32?) async throws -> PlaybackSnapshot { try await open(url) }
    func selectOutput(_ deviceID: UInt32?, pause: Bool) async throws -> PlaybackSnapshot { await snapshot() }
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

    private static func open(_ url: URL, on state: EngineState) throws -> PlaybackSnapshot {
        state.closeSession()
        do {
            state.session = try OutputSession(decoder: DecoderFactory.open(url: url), deviceID: state.deviceID)
            state.url = url
            state.error = nil
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
                state.error = nil
                return state.snapshot()
            } catch {
                try? session.pause()
                state.error = error.localizedDescription
                throw error
            }
        }
    }

    public func seek(to seconds: Double) async throws -> PlaybackSnapshot {
        try await perform { state in
            guard seconds.isFinite, let session = state.session else { throw AudioFailure("No seekable file is open.") }
            do {
                try session.seek(seconds)
                state.error = nil
                return state.snapshot()
            } catch {
                try? session.pause()
                state.error = error.localizedDescription
                throw error
            }
        }
    }

    public func selectOutput(_ deviceID: UInt32?, pause: Bool = false) async throws -> PlaybackSnapshot {
        try await perform { state in
            guard let session = state.session, let url = state.url else {
                state.deviceID = deviceID
                if let recovery = state.routeRecovery {
                    do {
                        let replacement = try OutputSession(decoder: DecoderFactory.open(url: recovery.url), deviceID: deviceID)
                        state.session = replacement; state.url = recovery.url
                        try replacement.seek(recovery.position)
                        state.routeRecovery = nil; state.error = nil
                    } catch {
                        state.closeSession(); state.routeRecovery = recovery
                        throw error
                    }
                }
                return state.snapshot()
            }
            if session.device.id == deviceID, session.outputStatus.error == nil, state.error == nil {
                state.error = nil
                if pause { try session.pause() }
                state.deviceID = deviceID
                return state.snapshot()
            }
            let previous = state.deviceID
            let position = session.position
            let resume = session.isPlaying && !pause
            state.closeSession()
            do {
                let replacement = try OutputSession(decoder: DecoderFactory.open(url: url), deviceID: deviceID)
                state.session = replacement; state.url = url
                try replacement.seek(position)
                if resume { try replacement.play() }
                state.deviceID = deviceID
                return state.snapshot()
            } catch {
                let failure = error
                state.closeSession()
                // Best-effort rollback retains the song and position on an incompatible output.
                do {
                    let old = try OutputSession(decoder: DecoderFactory.open(url: url), deviceID: previous)
                    state.session = old; state.url = url
                    try old.seek(position)
                    if resume { try old.play() }
                } catch { state.closeSession() }
                if state.session == nil {
                    state.routeRecovery = (url, position)
                    state.error = failure.localizedDescription
                }
                throw failure
            }
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
    var deviceID: UInt32?
    var url: URL?
    var routeRecovery: (url: URL, position: Double)?
    var error: String?
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
            timer?.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        } else {
            // Keep the source balanced and reusable, without waking while idle.
            timer?.schedule(deadline: .distantFuture)
        }
    }

    func snapshot() -> PlaybackSnapshot {
        defer { updateTimer() }
        return PlaybackSnapshot(source: session?.decoder.source,
                                output: session?.outputStatus.output,
                                duration: session?.duration ?? 0, position: session?.position ?? 0,
                                isPlaying: session?.isPlaying ?? false,
                                underrunFrames: session.flatMap { $0.ring.map(swar_ring_underruns) } ?? 0,
                                error: error, didFinish: session?.didFinish ?? false)
    }

    func closeSession() { session?.close(); session = nil; url = nil; routeRecovery = nil; error = nil }
    func close() { timer?.cancel(); timer = nil; pumping = false; closeSession() }
}

private final class OutputSession {
    let decoder: any AudioDecoding
    let device: OutputDevice
    private var deviceMonitor: OutputDeviceMonitor?
    var outputStatus: OutputDeviceStatus { deviceMonitor?.status ?? OutputDeviceStatus() }
    private var unit: AudioUnit?
    private(set) var ring: OpaquePointer?
    private let scratch: UnsafeMutableRawPointer
    private var eof = false
    private(set) var didFinish = false
    private var baseFrame: Int64 = 0
    private(set) var isPlaying = false
    private var closed = false
    var duration: Double { Double(decoder.frameCount) / decoder.source.sampleRate }
    var position: Double {
        min(duration, Double(baseFrame + Int64(ring.map(swar_ring_consumed) ?? 0)) / decoder.source.sampleRate)
    }

    init(decoder: any AudioDecoding, deviceID: UInt32? = nil) throws {
        self.decoder = decoder
        device = try OutputDevice(id: deviceID)
        scratch = .allocate(byteCount: 4096 * Int(decoder.pcmFormat.mBytesPerFrame), alignment: 16)
        do {
            try device.configure(for: decoder.source)
            guard let buffer = swar_ring_create(UInt32(decoder.source.sampleRate), decoder.pcmFormat.mBytesPerFrame) else {
                throw AudioFailure("Could not allocate a lock-free audio buffer.")
            }
            ring = buffer
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

    deinit { close(); scratch.deallocate() }

    func play() throws {
        guard let unit, !closed else { throw AudioFailure("The output session is closed.") }
        try device.validate(rate: decoder.source.sampleRate)
        // Explicit start may configure/query HAL. Periodic snapshots never do.
        deviceMonitor?.reset(output: try? device.description())
        if position >= duration { try seek(0) }
        try prime()
        didFinish = false
        try checkAudio(AudioOutputUnitStart(unit), "Start AUHAL")
        isPlaying = true
        deviceMonitor?.setActive(true)
    }

    func pause() throws {
        guard let unit else { return }
        try checkAudio(AudioOutputUnitStop(unit), "Pause AUHAL")
        isPlaying = false
        deviceMonitor?.setActive(false)
    }

    func seek(_ seconds: Double) throws {
        let resume = isPlaying
        try pause()
        guard let ring else { return }
        let target = Int64(max(0, min(seconds, duration)) * decoder.source.sampleRate)
        try decoder.seek(to: target)
        swar_ring_reset(ring)
        baseFrame = target
        eof = false
        didFinish = false
        try prime()
        if resume && target < decoder.frameCount { try play() }
        else if resume && target == decoder.frameCount { didFinish = true }
    }

    func pump() throws {
        if let error = outputStatus.error { throw AudioFailure(error) }
        try fill()
        if eof, let ring, swar_ring_readable(ring) == 0 {
            try pause()
            didFinish = true
        }
    }

    private func prime() throws {
        // Start with 200 ms, then let the 10 ms producer timer fill the one-second ring.
        // Capacity is unchanged; only synchronous decode work before start/seek is bounded.
        try fill(upTo: UInt32(ceil(decoder.source.sampleRate * 0.2)))
    }

    private func fill(upTo targetFrames: UInt32 = .max) throws {
        guard let ring, !eof else { return }
        while swar_ring_writable(ring) > 0 {
            let readable = swar_ring_readable(ring)
            guard readable < targetFrames else { break }
            let requested = min(4096, swar_ring_writable(ring), targetFrames - readable)
            let count = try decoder.read(into: scratch, frames: requested)
            if count == 0 { eof = true; swar_ring_finish(ring); break }
            guard swar_ring_write(ring, scratch, count) == count else { throw AudioFailure("PCM buffer write failed.") }
        }
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
        if let ring { swar_ring_destroy(ring); self.ring = nil }
        device.restore()
    }
}
