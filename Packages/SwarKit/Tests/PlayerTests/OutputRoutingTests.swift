import AudioEngine
import Foundation
import Player
import Testing

@MainActor
struct OutputRoutingTests {
    private let speakers = AudioOutputDevice(id: 1, uid: "speakers", name: "Speakers")
    private let dac = AudioOutputDevice(id: 2, uid: "dac", name: "USB DAC")
    private func preferences() -> UserDefaults { UserDefaults(suiteName: "OutputRoutingTests." + UUID().uuidString)! }

    @Test func selectionPersistsUIDAndDefaultClearsPreferenceWithoutChangingSong() async {
        let prefs = preferences(), engine = RoutingEngine()
        let reader = RoutingOutputs(AudioOutputs(devices: [speakers, dac], defaultID: 1))
        let player = Player(engine: engine, outputsReader: reader, outputPreferences: prefs)
        await player.open(URL(fileURLWithPath: "/test/song.wav"))
        await player.seek(to: 42)
        await player.togglePlayback()
        await player.selectOutput(uid: "dac")
        #expect(player.preferredOutputUID == "dac")
        #expect(prefs.string(forKey: "preferredOutputUID") == "dac")
        #expect(player.position == 42 && player.isPlaying)
        #expect(player.currentURL?.lastPathComponent == "song.wav")
        #expect(await engine.selected == [2])
        await player.selectOutput(uid: nil)
        #expect(prefs.string(forKey: "preferredOutputUID") == nil)
        #expect(await engine.selected == [2, 1])
        #expect(player.position == 42 && player.isPlaying)
    }

    @Test func savedUIDResolvesNewHardwareIDOnLaunchAndSurvivesDisconnect() async {
        let prefs = preferences(); prefs.set("dac", forKey: "preferredOutputUID")
        let engine = RoutingEngine()
        let reconnected = AudioOutputDevice(id: 99, uid: "dac", name: "USB DAC")
        let reader = RoutingOutputs(AudioOutputs(devices: [speakers, reconnected], defaultID: 1))
        let player = Player(engine: engine, outputsReader: reader, outputPreferences: prefs)
        await player.open(URL(fileURLWithPath: "/test/song.wav"))
        #expect(await engine.openedOutput == 99)
        await player.togglePlayback()
        await reader.change(AudioOutputs(devices: [speakers], defaultID: 1))
        await player.refreshOutputs(force: true)
        #expect(await engine.selected.last == 1)
        #expect(!player.isPlaying)
        #expect(player.preferredOutputUnavailable)
        #expect(prefs.string(forKey: "preferredOutputUID") == "dac")
        await reader.change(AudioOutputs(devices: [speakers, reconnected], defaultID: 1))
        await player.refreshOutputs(force: true)
        #expect(await engine.selected.last == 99)
        #expect(!player.isPlaying)
        #expect(!player.preferredOutputUnavailable)
    }

    @Test func unavailableOrFailedSelectionDoesNotReplaceSavedPreference() async {
        let prefs = preferences(), engine = RoutingEngine()
        let reader = RoutingOutputs(AudioOutputs(devices: [speakers, dac], defaultID: 1))
        let player = Player(engine: engine, outputsReader: reader, outputPreferences: prefs)
        await player.refreshOutputs(force: true)
        await player.selectOutput(uid: "gone")
        #expect(player.outputNotice != nil)
        #expect(player.preferredOutputUID == nil)
        await engine.fail(true)
        await player.selectOutput(uid: "dac")
        #expect(player.outputNotice != nil)
        #expect(prefs.string(forKey: "preferredOutputUID") == nil)
        await engine.fail(false)
        await player.selectOutput(uid: "dac")
        #expect(player.outputNotice == nil)
        #expect(player.preferredOutputUID == "dac")
    }

    @Test func followsDefaultChangesAndPausesWhenAllOutputsDisappear() async {
        let engine = RoutingEngine(), reader = RoutingOutputs(AudioOutputs(devices: [speakers, dac], defaultID: 1))
        let player = Player(engine: engine, outputsReader: reader, outputPreferences: preferences())
        await player.open(URL(fileURLWithPath: "/test/song.wav"))
        await player.togglePlayback()
        await reader.change(AudioOutputs(devices: [speakers, dac], defaultID: 2))
        await player.refreshOutputs(force: true)
        #expect(await engine.selected.last == 2)
        #expect(player.isPlaying)
        await reader.change(AudioOutputs())
        await player.refreshOutputs(force: true)
        #expect(!player.isPlaying)
        #expect(player.outputNotice != nil)
    }

    @Test func failedRollbackKeepsSongSeekPositionAndAllowsAnotherOutput() async {
        let engine = RoutingEngine(), reader = RoutingOutputs(AudioOutputs(devices: [speakers, dac], defaultID: 1))
        let player = Player(engine: engine, outputsReader: reader, outputPreferences: preferences())
        await player.open(URL(fileURLWithPath: "/test/song.wav"))
        await player.seek(to: 42)
        await player.togglePlayback()
        await engine.fail(true, dropSession: true)
        await player.selectOutput(uid: "dac")
        #expect(player.duration == 180 && player.position == 42)
        #expect(!player.isPlaying && player.currentURL != nil)
        #expect(player.outputNotice != nil)
        await engine.fail(false)
        await player.selectOutput(uid: "speakers")
        #expect(player.duration == 180 && player.position == 42)
        #expect(player.outputNotice == nil)
        #expect(!player.isPlaying)
    }

    @Test func missingSavedOutputOnLaunchFallsBackWithoutForgettingIt() async {
        let prefs = preferences(); prefs.set("missing-dac", forKey: "preferredOutputUID")
        let engine = RoutingEngine(), reader = RoutingOutputs(AudioOutputs(devices: [speakers], defaultID: 1))
        let player = Player(engine: engine, outputsReader: reader, outputPreferences: prefs)
        await player.open(URL(fileURLWithPath: "/test/song.wav"))
        #expect(await engine.openedOutput == 1)
        #expect(player.preferredOutputUnavailable)
        #expect(player.preferredOutputUID == "missing-dac")
    }

    @Test func catalogFailureDoesNotPreventOpeningPlayableFiles() async {
        let engine = RoutingEngine(), reader = RoutingOutputs(AudioOutputs())
        await reader.fail()
        let player = Player(engine: engine, outputsReader: reader, outputPreferences: preferences())
        await player.open(URL(fileURLWithPath: "/test/song.wav"))
        #expect(player.duration == 180)
        #expect(player.errorMessage == nil)
    }
}

private actor RoutingOutputs: AudioOutputsReading {
    var value: AudioOutputs
    var failing = false
    init(_ value: AudioOutputs) { self.value = value }
    func change(_ value: AudioOutputs) { self.value = value }
    func fail() { failing = true }
    func snapshot() throws -> AudioOutputs {
        if failing { throw CocoaError(.fileReadUnknown) }
        return value
    }
}

private actor RoutingEngine: PlaybackDriving {
    var position: Double = 0
    var playing = false
    var opened = false
    var failing = false
    var dropSession = false
    private(set) var selected: [UInt32] = []
    private(set) var openedOutput: UInt32?
    func fail(_ value: Bool, dropSession: Bool = false) { failing = value; if value { self.dropSession = dropSession } }
    func open(_ url: URL) -> PlaybackSnapshot { opened = true; return value() }
    func open(_ url: URL, outputDeviceID: UInt32?) -> PlaybackSnapshot { openedOutput = outputDeviceID; return open(url) }
    func togglePlayback() -> PlaybackSnapshot { playing.toggle(); return value() }
    func seek(to seconds: Double) -> PlaybackSnapshot { position = seconds; return value() }
    func selectOutput(_ id: UInt32?, pause: Bool, exclusive: Bool) throws -> PlaybackSnapshot {
        if failing {
            if dropSession { opened = false; playing = false }
            throw CocoaError(.featureUnsupported)
        }
        if dropSession { opened = true }
        if let id { selected.append(id) }
        if pause { playing = false }
        return value()
    }
    func snapshot() -> PlaybackSnapshot { value() }
    private func value() -> PlaybackSnapshot { PlaybackSnapshot(duration: opened ? 180 : 0, position: position, isPlaying: playing) }
    nonisolated func shutdown() {}
}
