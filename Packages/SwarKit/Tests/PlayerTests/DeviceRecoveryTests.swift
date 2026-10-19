import AppKit
import AudioEngine
import Foundation
import Testing
@testable import Player

@MainActor
struct DeviceRecoveryTests {
    private let speakers = AudioOutputDevice(id: 1, uid: "speakers", name: "Speakers")
    private let dac = AudioOutputDevice(id: 2, uid: "dac", name: "DAC")
    private func preferences() -> UserDefaults { UserDefaults(suiteName: "DeviceRecoveryTests." + UUID().uuidString)! }
    private func makePlayer(_ engine: RecoveryEngine, _ reader: RecoveryOutputs) -> Player {
        Player(engine: engine, outputsReader: reader, outputPreferences: preferences())
    }
    private func start(_ player: Player) async {
        await player.play([QueueEntry(url: URL(fileURLWithPath: "/test/song.wav"), title: "Song")])
        await player.seek(to: 42)
    }

    @Test func sameIDDriverFailureRecoversPositionAndPlayingState() async {
        let engine = RecoveryEngine(), reader = RecoveryOutputs(AudioOutputs(devices: [dac], defaultID: 2))
        let player = makePlayer(engine, reader)
        await start(player)
        let revision = player.sourceRevision, entry = player.currentEntryID
        await engine.breakOutput()
        await player.refresh()
        #expect(!player.isPlaying && player.errorMessage != nil)
        await player.refreshOutputs(force: true)
        #expect(player.isPlaying && player.position == 42)
        #expect(player.errorMessage == nil && player.outputNotice == nil)
        #expect(player.currentEntryID == entry && player.sourceRevision == revision)
        #expect(await engine.recoveries == [false])
        player.shutdown()
    }

    @Test func decoderFailuresDoNotRestartAudioDevices() async {
        let engine = RecoveryEngine(), reader = RecoveryOutputs(AudioOutputs(devices: [dac], defaultID: 2))
        let player = makePlayer(engine, reader)
        await start(player)
        await engine.breakDecoder()
        await player.refresh()
        await player.refreshOutputs(force: true)
        #expect(await engine.recoveries.isEmpty)
        #expect(!player.isPlaying && player.errorMessage == "Bad audio")
        player.shutdown()
    }

    @Test(arguments: [true, false]) func sleepWakeRebuildsOutputAndRespectsPriorPlayState(playing: Bool) async {
        let engine = RecoveryEngine(), reader = RecoveryOutputs(AudioOutputs(devices: [dac], defaultID: 2))
        let player = makePlayer(engine, reader)
        await start(player)
        if !playing { await player.togglePlayback() }
        let id = player.currentEntryID
        await player.systemWillSleep()
        #expect(player.isSystemSleeping && !player.isPlaying && player.position == 42)
        #expect(!player.canTogglePlayback)
        await player.refreshOutputs(force: true)
        #expect(await engine.recoveries.isEmpty)
        await player.systemDidWake()
        #expect(!player.isSystemSleeping && player.isPlaying == playing)
        #expect(player.position == 42 && player.currentEntryID == id)
        #expect(await engine.recoveries == [false])
        #expect(await engine.suspensions == 1)
        player.shutdown()
    }

    @Test func healthyPausedSnapshotDoesNotReviveOldPlaybackIntentOnWake() async {
        let engine = RecoveryEngine(), reader = RecoveryOutputs(AudioOutputs(devices: [dac], defaultID: 2))
        let player = makePlayer(engine, reader)
        await start(player)
        await engine.pauseWithoutFailure(); await player.refresh()
        #expect(!player.isPlaying)
        await player.systemWillSleep(); await player.systemDidWake()
        #expect(!player.isPlaying && player.position == 42)
        #expect(await engine.starts == 1)
        player.shutdown()
    }

    @Test func missingHeadphonesOnWakeNeverResumeOnFallbackSpeakers() async {
        let prefs = preferences(); prefs.set("dac", forKey: "preferredOutputUID")
        let engine = RecoveryEngine(), reader = RecoveryOutputs(AudioOutputs(devices: [dac, speakers], defaultID: 1))
        let player = Player(engine: engine, outputsReader: reader, outputPreferences: prefs)
        await start(player)
        await player.systemWillSleep()
        await reader.change(AudioOutputs(devices: [speakers], defaultID: 1))
        await player.systemDidWake()
        #expect(!player.isPlaying && player.position == 42)
        #expect(await engine.recoveries == [false])
        #expect(player.preferredOutputUID == "dac")
        await reader.change(AudioOutputs(devices: [speakers, dac], defaultID: 1))
        await player.refreshOutputs(force: true)
        #expect(!player.isPlaying)
        player.shutdown()
    }

    @Test func pausedDeviceRemovalClosesSessionAndSameIDReplugRecoversPaused() async {
        let engine = RecoveryEngine(), reader = RecoveryOutputs(AudioOutputs(devices: [dac], defaultID: 2))
        let player = makePlayer(engine, reader)
        await start(player); await player.togglePlayback()
        await reader.change(AudioOutputs())
        await player.refreshOutputs(force: true)
        #expect(await engine.suspensions == 1)
        #expect(player.position == 42 && player.duration == 180)
        await player.seek(to: 73)
        #expect(player.position == 73)
        await reader.change(AudioOutputs(devices: [dac], defaultID: 2))
        await player.refreshOutputs(force: true)
        #expect(await engine.recoveries == [false])
        #expect(!player.isPlaying && player.errorMessage == nil && player.position == 73)
        player.shutdown()
    }

    @Test func reusedNumericDeviceIDNeverResumesOnADifferentDevice() async {
        let engine = RecoveryEngine(), reader = RecoveryOutputs(AudioOutputs(devices: [dac], defaultID: 2))
        let player = makePlayer(engine, reader)
        await start(player)
        let replacement = AudioOutputDevice(id: 2, uid: "different-device", name: "Speakers")
        await reader.change(AudioOutputs(devices: [replacement], defaultID: 2))
        await player.refreshOutputs(force: true)
        #expect(await engine.recoveries == [false])
        #expect(!player.isPlaying && player.position == 42)
        player.shutdown()
    }

    @Test func failedRecoveryBacksOffAndManualRetryDoesNotLoseSong() async {
        let engine = RecoveryEngine(), reader = RecoveryOutputs(AudioOutputs(devices: [dac], defaultID: 2))
        let player = makePlayer(engine, reader)
        var now = 0.0; player.recoveryTime = { now }
        await start(player)
        await engine.breakOutput(); await engine.failRecoveries(true)
        await player.refresh()
        for _ in 0..<5 {
            await player.refreshOutputs(force: true)
            now += 9
        }
        #expect(await engine.recoveries.count == 5)
        await player.refreshOutputs(force: true)
        #expect(await engine.recoveries.count == 5)
        #expect(player.position == 42 && player.duration == 180 && player.currentURL != nil)
        await engine.failRecoveries(false)
        await player.retryOutputRecovery()
        #expect(await engine.recoveries.count == 6)
        #expect(!player.isPlaying && player.outputNotice == nil)
        #expect(player.position == 42)
        player.shutdown()
    }

    @Test func rapidWorkspaceSleepWakeEventsAreSerializedAndStopUnregisters() async {
        let engine = RecoveryEngine(), reader = RecoveryOutputs(AudioOutputs(devices: [dac], defaultID: 2))
        let player = makePlayer(engine, reader)
        await start(player)
        let center = NotificationCenter()
        let observer = SystemPlaybackLifecycle(player: player, center: center)
        observer.start(); observer.start()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await observer.drain()
        #expect(await engine.events == ["suspend", "recover"])
        #expect(player.isPlaying && player.position == 42)
        observer.stop()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await observer.drain()
        #expect(await engine.suspensions == 1)
        player.shutdown()
    }

    @Test func expiredSleepTimerPreventsWakeAutoplay() async {
        let engine = RecoveryEngine(), reader = RecoveryOutputs(AudioOutputs(devices: [dac], defaultID: 2))
        let timer = SleepTimer(wait: { _ in })
        let player = Player(engine: engine, sleepTimer: timer, outputsReader: reader, outputPreferences: preferences())
        await start(player); await player.systemWillSleep()
        timer.start(minutes: 1)
        for _ in 0..<1000 where timer.deadline != nil { await Task.yield() }
        #expect(timer.deadline == nil)
        await player.systemDidWake()
        #expect(!player.isPlaying)
        #expect(await engine.recoveries == [false])
        player.shutdown()
    }

    @Test func deviceChangeDuringWakeRebuildCancelsResume() async {
        let engine = RecoveryEngine(), reader = RecoveryOutputs(AudioOutputs(devices: [dac], defaultID: 2))
        let player = makePlayer(engine, reader)
        await start(player); await player.systemWillSleep()
        await engine.gateRecovery()
        let waking = Task { await player.systemDidWake() }
        await engine.waitUntilRecovering()
        await reader.change(AudioOutputs(devices: [AudioOutputDevice(id: 2, uid: "other", name: "Speakers")], defaultID: 2))
        await engine.releaseRecovery(); await waking.value
        #expect(!player.isPlaying && player.position == 42)
        #expect(await engine.starts == 1)
        player.shutdown()
    }

    @Test func shutdownDuringWakeRebuildNeverRestartsAudio() async {
        let engine = RecoveryEngine(), reader = RecoveryOutputs(AudioOutputs(devices: [dac], defaultID: 2))
        let player = makePlayer(engine, reader)
        await start(player); await player.systemWillSleep()
        await engine.gateRecovery()
        let waking = Task { await player.systemDidWake() }
        await engine.waitUntilRecovering()
        player.shutdown()
        await engine.releaseRecovery(); await waking.value
        #expect(!player.isPlaying && player.currentURL == nil)
        #expect(await engine.starts == 1)
    }

    @Test func shutdownPreventsWakeOrRetryFromReopeningOutput() async {
        let engine = RecoveryEngine(), reader = RecoveryOutputs(AudioOutputs(devices: [dac], defaultID: 2))
        let player = makePlayer(engine, reader)
        await start(player); await player.systemWillSleep(); player.shutdown()
        await player.systemDidWake(); await player.retryOutputRecovery()
        #expect(await engine.recoveries.isEmpty)
        #expect(player.currentURL == nil)
    }
}

struct OutputRecoveryPolicyTests {
    @Test func boundsFailedAndRepeatedSuccessfulReopens() {
        var policy = OutputRecoveryPolicy()
        let initial = policy.allowsAttempt(at: 0)
        #expect(initial); policy.attempted(); policy.failed(at: 0)
        let early = policy.allowsAttempt(at: 0.5), ready = policy.allowsAttempt(at: 1)
        #expect(!early && ready)
        for time in [1.0, 3, 7, 15] {
            let allowed = policy.allowsAttempt(at: time)
            #expect(allowed); policy.attempted(); policy.succeeded()
        }
        let exhausted = policy.allowsAttempt(at: 30)
        #expect(!exhausted && policy.exhausted)
        let renewed = policy.allowsAttempt(at: 60)
        #expect(renewed && !policy.exhausted)
    }

}

private actor RecoveryOutputs: AudioOutputsReading {
    var value: AudioOutputs
    init(_ value: AudioOutputs) { self.value = value }
    func change(_ value: AudioOutputs) { self.value = value }
    func snapshot() -> AudioOutputs { value }
}

private actor RecoveryEngine: PlaybackDriving {
    var playing = false
    var position: Double = 0
    var token = UUID()
    var outputFailure = false
    var error: String?
    var failing = false
    private(set) var recoveries: [Bool] = []
    private(set) var suspensions = 0
    private(set) var events: [String] = []
    private(set) var starts = 0
    private var gated = false
    private var entered = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    func gateRecovery() { gated = true }
    func waitUntilRecovering() async {
        if entered { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func releaseRecovery() { held?.resume(); held = nil }
    func open(_ url: URL) -> PlaybackSnapshot { playing = false; token = UUID(); return value() }
    func togglePlayback() -> PlaybackSnapshot { if !playing { starts += 1 }; playing.toggle(); return value() }
    func seek(to seconds: Double) -> PlaybackSnapshot { position = seconds; return value() }
    func snapshot() -> PlaybackSnapshot { value() }
    func pauseWithoutFailure() { playing = false }
    func breakOutput() { playing = false; outputFailure = true; error = "Driver changed" }
    func breakDecoder() { playing = false; outputFailure = false; error = "Bad audio" }
    func failRecoveries(_ value: Bool) { failing = value }
    func suspendOutput() -> PlaybackSnapshot { suspensions += 1; events.append("suspend"); playing = false; return value() }
    func selectOutput(_ id: UInt32?, pause: Bool) -> PlaybackSnapshot { if pause { playing = false }; return value() }
    func recoverOutput(_ id: UInt32?, resume: Bool) async throws -> PlaybackSnapshot {
        recoveries.append(resume); events.append("recover")
        if gated {
            gated = false; entered = true; waiting?.resume(); waiting = nil
            await withCheckedContinuation { held = $0 }
        }
        if failing { throw CocoaError(.featureUnsupported) }
        outputFailure = false; error = nil; playing = resume; return value()
    }
    private func value() -> PlaybackSnapshot {
        PlaybackSnapshot(duration: 180, position: position, isPlaying: playing, error: error,
            playbackToken: token, needsOutputRecovery: outputFailure)
    }
    nonisolated func shutdown() {}
}
