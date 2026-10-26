import AudioEngine
import Decoding
import Foundation
import FormatInfo
import Library
import Observation

@MainActor @Observable
public final class Player {
    public var crossfadeEnabled = false {
        didSet {
            outputPreferences.set(crossfadeEnabled, forKey: "smartCrossfade")
            gaplessPlan = nil
            scheduleGapless()
        }
    }
    public var crossfadeLength: CrossfadeLength = .balanced {
        didSet {
            guard oldValue != crossfadeLength else { return }
            outputPreferences.set(crossfadeLength.rawValue, forKey: "smartCrossfadeLength")
            gaplessPlan = nil
            scheduleGapless()
        }
    }
    public private(set) var isCrossfadeProcessing = false
    public private(set) var title = "No file open"
    public private(set) var subtitle = ""
    public private(set) var artworkURL: URL?
    public private(set) var sourceRevision: UInt64 = 0
    public private(set) var currentURL: URL?
    public private(set) var sourceDescription: String?
    public private(set) var outputDescription: String?
    public private(set) var duration: Double = 0
    public private(set) var position: Double = 0 {
        didSet {
            let progressed = position > 0
            if hasPlaybackProgress != progressed { hasPlaybackProgress = progressed }
        }
    }
    // Command/transport availability changes at zero, not on every clock tick.
    private var hasPlaybackProgress = false
    public private(set) var isPlaying = false
    public private(set) var isBusy = false { didSet { if !isBusy { scheduleGapless() } } }
    public private(set) var isSeeking = false
    private var pendingSeek: Double?
    private var pendingSeekResume = false
    public private(set) var isScrubbing = false
    private var scrubWasPlaying = false
    private var scrubURL: URL?
    /// Set when a scrub ends (cancel/teardown) while a seek is already running.
    /// The running seek loop consumes it so playback still resumes exactly once.
    private var pendingScrubResume = false
    public private(set) var errorMessage: String?
    @ObservationIgnored private var errorIsFromPlayback = false
    public private(set) var underrunFrames: UInt64 = 0
    public private(set) var formatInfo: FormatChipInfo?
    public private(set) var isRestoredSession = false
    public private(set) var sessionNotice: String?
    public private(set) var outputVolume = OutputVolume()
    public private(set) var volumeError: String?
    public private(set) var audioOutputs = AudioOutputs()
    public private(set) var preferredOutputUID: String?
    public private(set) var outputNotice: String?
    public private(set) var exclusiveOutput = false
    public var canSetExclusiveOutput: Bool { !isBusy && !isSystemSleeping && !isShutDown && currentURL != nil }
    public private(set) var isSystemSleeping = false
    public var canRetryOutput: Bool { !isBusy && !isSystemSleeping && !isShutDown && currentURL != nil }
    private var outputRecoveryNeeded = false
    @ObservationIgnored private var recoverySeekPosition: Double?
    @ObservationIgnored private var recoveryPolicy = OutputRecoveryPolicy()
    @ObservationIgnored private var playbackIntent = false
    @ObservationIgnored private var sleepWasPlaying = false
    @ObservationIgnored private var sleepOutputUID: String?
    @ObservationIgnored private var wakeRecoveryPending = false
    @ObservationIgnored private var hadSessionBeforeSleep = false
    @ObservationIgnored private var lifecycle: SystemPlaybackLifecycle?
    @ObservationIgnored var recoveryTime: () -> Double = { ProcessInfo.processInfo.systemUptime }

    @ObservationIgnored private let outputsReader: any AudioOutputsReading
    @ObservationIgnored private let outputPreferences: UserDefaults
    @ObservationIgnored private var lastOutputCheck = -Double.infinity
    @ObservationIgnored private var checkingOutputs = false
    @ObservationIgnored private var routedOutputID: UInt32?
    @ObservationIgnored private var routedOutputUID: String?
    @ObservationIgnored private var failedAutomaticRoute: UInt32?
    public var preferredOutputUnavailable: Bool {
        preferredOutputUID.map { uid in !audioOutputs.devices.contains { $0.uid == uid } } ?? false
    }
    public var selectedOutputName: String {
        audioOutputs.resolve(preferredOutputUID)?.name ?? "No Output"
    }

    private var settingVolume = false
    private var pendingVolume: (Double, UInt32)?
    private var volumeDeviceID: UInt32?
    private var describedSource: SourceFormat?
    private var describedOutput: OutputDescription?
    private var describedExclusive: Bool = false
    @ObservationIgnored private var mediaControls: SystemMediaControls?

    @ObservationIgnored public var onQualifiedListen: ((URL, Date) -> Void)?
    @ObservationIgnored private var listenCounter = ListenCounter()
    @ObservationIgnored var listeningTime: () -> Double = { ProcessInfo.processInfo.systemUptime }

    @ObservationIgnored private var activeArtworkChange: LibraryArtworkChange?

    public func updateLibraryArtwork(_ changes: [LibraryArtworkChange]) {
        let updates = Dictionary(changes.map { ($0.fileURL.standardizedFileURL, $0) }, uniquingKeysWith: { _, last in last })
        var updatedQueue = queue
        for index in updatedQueue.indices {
            if let change = updates[updatedQueue[index].url.standardizedFileURL] { updatedQueue[index].artworkURL = change.artworkURL }
        }
        if updatedQueue != queue { queue = updatedQueue }
        if let entry = standaloneEntry, let change = updates[entry.url.standardizedFileURL] {
            standaloneEntry?.artworkURL = change.artworkURL
            activeArtworkChange = change
        }
        if let currentURL, let change = updates[currentURL.standardizedFileURL] {
            artworkURL = change.artworkURL
            activeArtworkChange = change
        }
    }

    public func enableSystemMediaControls() {
        guard mediaControls == nil, !isShutDown else { return }
        let controls = SystemMediaControls(player: self, output: MacNowPlayingOutput())
        mediaControls = controls
        controls.start()
        let lifecycle = SystemPlaybackLifecycle(player: self)
        self.lifecycle = lifecycle
        lifecycle.start()
    }

    var currentMediaEntry: QueueEntry? {
        guard let currentURL else { return nil }
        return queue.first { $0.url == currentURL } ?? (standaloneEntry?.url == currentURL ? standaloneEntry : nil)
    }
    public var currentArtist: String? { currentMediaEntry?.artist }
    public var currentAlbum: String? { currentMediaEntry?.album }
    public var currentAccessRoot: URL? { currentMediaEntry?.accessRoot }

    /// Remains true until the hardware queue has drained coalesced requests.
    public var isSettingOutputVolume: Bool { settingVolume }

    public var canSetOutputVolume: Bool {
        !isBusy && !isShutDown && !isSystemSleeping && !outputRecoveryNeeded && outputVolume.canSet && (volumeDeviceID == nil || volumeDeviceID == outputVolume.deviceID)
    }

    public private(set) var queue: [QueueEntry] = [] { didSet { scheduleGapless() } }
    public private(set) var currentEntryID: UUID? { didSet { scheduleGapless() } }
    public private(set) var shuffleEnabled = false
    public private(set) var repeatMode: RepeatMode = .off { didSet { scheduleGapless() } }
    private var unshuffledOrder: [UUID] = []
    private struct QueueRemoval {
        let entries: [QueueEntry]
        let order: [UUID]
        let originalOrder: [UUID]
        let cleared: Bool
    }
    private var queueRemovals: [QueueRemoval] = []
    public var canUndoQueueRemoval: Bool { !queueRemovals.isEmpty && !isBusy && !isShutDown }
    public var queueUndoTitle: String { queueRemovals.last?.cleared == true ? "Undo Clear" : "Undo Remove" }

    private func rememberRemoval(_ entries: [QueueEntry], cleared: Bool = false) {
        guard !entries.isEmpty else { return }
        queueRemovals.append(QueueRemoval(entries: entries, order: queue.map(\.id), originalOrder: unshuffledOrder, cleared: cleared))
        if queueRemovals.count > 20 { queueRemovals.removeFirst() }
    }

    public func undoQueueRemoval() {
        guard canUndoQueueRemoval, let removal = queueRemovals.popLast() else { return }
        let entries = Dictionary((removal.entries + queue).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let removedIDs = Set(removal.entries.map(\.id))
        queue = Self.restoring(removedIDs, in: queue.map(\.id), accordingTo: removal.order).compactMap { entries[$0] }
        unshuffledOrder = Self.restoring(removedIDs, in: unshuffledOrder, accordingTo: removal.originalOrder)
    }

    /// Linear merge keeps new insertions intact and restores duplicate songs by entry identity.
    private static func restoring(_ removed: Set<UUID>, in current: [UUID], accordingTo original: [UUID]) -> [UUID] {
        let existing = Set(current)
        var before: [UUID: [UUID]] = [:]
        var pending: [UUID] = []
        var lastAnchor: UUID?
        for id in original {
            if existing.contains(id) {
                if !pending.isEmpty { before[id] = pending; pending = [] }
                lastAnchor = id
            } else if removed.contains(id) { pending.append(id) }
        }
        var result: [UUID] = []
        for id in current {
            result.append(contentsOf: before[id] ?? [])
            result.append(id)
            if id == lastAnchor { result.append(contentsOf: pending) }
        }
        if lastAnchor == nil { return pending + result }
        return result
    }

    public var currentQueueIndex: Int? { queue.firstIndex { $0.id == currentEntryID } }
    public var canGoNext: Bool { currentQueueIndex.map { $0 + 1 < queue.count || (repeatMode == .all && !queue.isEmpty) } ?? !queue.isEmpty }
    public var canTogglePlayback: Bool { !isSystemSleeping && (duration > 0 || isRestoredSession || (currentEntryID == nil && !queue.isEmpty)) }
    public var canGoPrevious: Bool { currentQueueIndex.map { $0 > 0 || hasPlaybackProgress } ?? false }
    public var upcomingEntries: [QueueEntry] {
        guard let index = currentQueueIndex else { return queue }
        return Array(queue.dropFirst(index + 1))
    }

    /// The actual automatic successor, including Repeat One and Repeat All wrapping.
    public var nextTransitionEntry: QueueEntry? {
        guard let next = nextContinuation() else { return nil }
        return queue.first { $0.id == next.id } ?? (standaloneEntry?.id == next.id ? standaloneEntry : nil)
    }

    public func preservesGaplessTransition(to next: QueueEntry) -> Bool {
        let current = currentEntryID.flatMap { id in queue.first { $0.id == id } } ?? currentMediaEntry
        guard let current else { return true }
        return Self.preservesGaplessTransition(from: current, to: next)
    }

    private static func preservesGaplessTransition(from current: QueueEntry, to next: QueueEntry) -> Bool {
        current.url == next.url || (current.album?.isEmpty == false && current.album == next.album)
    }

    private struct GaplessPlan: Equatable {
        let token: UUID
        let next: PlaybackContinuation?
        let crossfade: Bool
        let length: CrossfadeLength
    }
    @ObservationIgnored private var playbackToken: UUID?
    @ObservationIgnored private var gaplessPlan: GaplessPlan?
    @ObservationIgnored private var gaplessTask: Task<Void, Never>?
    @ObservationIgnored private var stagedGaplessEntries: [UUID: QueueEntry] = [:]

    private func nextContinuation() -> PlaybackContinuation? {
        guard let index = currentQueueIndex else {
            if queue.isEmpty, repeatMode != .off, let entry = standaloneEntry {
                return PlaybackContinuation(id: entry.id, url: entry.url, accessRoot: entry.accessRoot)
            }
            return nil
        }
        let next: QueueEntry?
        if repeatMode == .one { next = queue[index] }
        else if queue.indices.contains(index + 1) { next = queue[index + 1] }
        else { next = repeatMode == .all ? queue.first : nil }
        return next.map { PlaybackContinuation(id: $0.id, url: $0.url, accessRoot: $0.accessRoot) }
    }

    private func scheduleGapless() {
        guard !isBusy, !isRestoredSession, !isShutDown, !isSystemSleeping, !outputRecoveryNeeded, let playbackToken else { return }
        let plan = GaplessPlan(token: playbackToken, next: nextContinuation(), crossfade: crossfadeEnabled && isCrossfadeProcessing, length: crossfadeLength)
        guard gaplessPlan != plan else { return }
        gaplessPlan = plan
        if let id = plan.next?.id, let entry = queue.first(where: { $0.id == id }) ?? (standaloneEntry?.id == id ? standaloneEntry : nil) {
            if stagedGaplessEntries.count > 4 { stagedGaplessEntries = [:] }
            stagedGaplessEntries[id] = entry
        }
        gaplessTask?.cancel()
        let engine = engine
        let current = currentEntryID.flatMap { id in queue.first { $0.id == id } } ?? currentMediaEntry
        let nextEntry = plan.next.flatMap { next in queue.first { $0.id == next.id } ?? (standaloneEntry?.id == next.id ? standaloneEntry : nil) }
        gaplessTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await engine.prepareNext(plan.next, after: plan.token)
            guard plan.crossfade, !Task.isCancelled, let next = plan.next, let current,
                  current.url != next.url else { return }
            // Conservatively preserve all adjacent tracks from the same album.
            if let nextEntry, Self.preservesGaplessTransition(from: current, to: nextEntry) { return }
            do {
                let outgoing = try await RhythmStore.shared.profile(url: current.url, accessRoot: current.accessRoot)
                let incoming = try await RhythmStore.shared.profile(url: next.url, accessRoot: next.accessRoot)
                guard !Task.isCancelled, let self, self.playbackToken == plan.token,
                      !self.isShutDown, !self.outputRecoveryNeeded else { return }
                let transition = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                    outgoingDuration: outgoing.duration, incomingDuration: incoming.duration, notBefore: self.position, preferredBeats: plan.length.beats)
                guard transition.mode != .gapless else { return }
                await engine.prepareCrossfade(next, currentRoot: current.accessRoot, overlap: transition.duration, after: plan.token)
            } catch { /* Analysis is optional: the already-prepared gapless successor remains valid. */ }
        }
    }

    private func adoptContinuation(_ snapshot: PlaybackSnapshot) {
        guard snapshot.playbackToken != playbackToken else { return }
        playbackToken = snapshot.playbackToken
        if let id = snapshot.continuationID, let entry = queue.first(where: { $0.id == id }) ?? stagedGaplessEntries[id] {
            // An edit can race the audible boundary. Once already audible, keep
            // that entry as the current song rather than showing stale metadata.
            if !queue.contains(where: { $0.id == id }) {
                let index = currentQueueIndex.map { $0 + 1 } ?? 0
                queue.insert(entry, at: min(index, queue.count)); unshuffledOrder.append(id)
            }
            listenCounter = ListenCounter()
            completionHandled = false
            queueRemovals = []
            currentEntryID = id
            scopedAccess = ScopedFileAccess(entry.accessRoot)
            currentURL = entry.url
            title = entry.title; subtitle = entry.subtitle; artworkURL = entry.artworkURL
            sourceRevision &+= 1
        }
        scheduleGapless()
    }

    public let sleepTimer: SleepTimer
    private let engine: any PlaybackDriving
    private let volumeController: any OutputVolumeControlling
    private let sessionStore: PlaybackSessionStore?
    private var didAttemptRestore = false
    private var isShutDown = false
    private var lastSavedSession: PlaybackSession?
    private var completionHandled = false
    private var scopedAccess: ScopedFileAccess?
    private var generation = 0

    public init(engine: any PlaybackDriving = AudioPlaybackEngine(), sessionStore: PlaybackSessionStore? = nil, volumeController: any OutputVolumeControlling = HardwareVolumeController(), sleepTimer: SleepTimer? = nil, outputsReader: any AudioOutputsReading = SystemAudioOutputs(), outputPreferences: UserDefaults = .standard) {
        self.engine = engine
        self.outputsReader = outputsReader
        self.outputPreferences = outputPreferences
        self.crossfadeEnabled = outputPreferences.bool(forKey: "smartCrossfade")
        self.crossfadeLength = CrossfadeLength(rawValue: outputPreferences.string(forKey: "smartCrossfadeLength") ?? "") ?? .balanced
        self.preferredOutputUID = outputPreferences.string(forKey: "preferredOutputUID")
        self.sessionStore = sessionStore
        self.volumeController = volumeController
        self.sleepTimer = sleepTimer ?? SleepTimer()
        self.sleepTimer.onExpire = { [weak self] in await self?.pauseForSleepTimer() }
    }

    private func pauseForSleepTimer() async {
        playbackIntent = false; sleepWasPlaying = false
        // A deadline may arrive during an open or seek. Wait for that operation,
        // allowing cancellation/replacement to withdraw the pending pause.
        while isBusy && !isShutDown {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
        }
        guard !Task.isCancelled, !isShutDown, isPlaying else { return }
        await control {
            let snapshot = await self.engine.snapshot()
            guard !Task.isCancelled, snapshot.isPlaying else { return snapshot }
            return try await self.engine.togglePlayback()
        }
        // A finish snapshot racing this deadline must not trigger Repeat/Next.
        if !Task.isCancelled { completionHandled = true }
    }

    public func refreshVolume() async {
        guard !isShutDown, !settingVolume, !isSystemSleeping else { return }
        await refreshOutputs()
        guard !isShutDown, !isBusy else { return }
        let revision = generation
        let volume = await volumeController.snapshot(deviceID: volumeDeviceID ?? audioOutputs.resolve(preferredOutputUID)?.id)
        guard !isShutDown, !settingVolume, revision == generation else { return }
        if outputVolume.deviceID != volume.deviceID || !volume.canSet { volumeError = nil }
        if outputVolume != volume { outputVolume = volume }
    }

    public func refreshOutputs(force: Bool = false) async {
        guard !isShutDown, !isSystemSleeping, !checkingOutputs,
              force || recoveryTime() - lastOutputCheck >= 2 else { return }
        checkingOutputs = true
        defer { checkingOutputs = false }
        lastOutputCheck = recoveryTime()
        do {
            let outputs = try await outputsReader.snapshot()
            guard !isShutDown, !isSystemSleeping else { return }
            if audioOutputs != outputs {
                audioOutputs = outputs; failedAutomaticRoute = nil
                recoveryPolicy = OutputRecoveryPolicy()
            }
            guard !isBusy else { return }
            let lostActive = routedOutputID.map { id in
                !outputs.devices.contains { $0.id == id && (routedOutputUID == nil || $0.uid == routedOutputUID) }
            } ?? false
            guard let target = outputs.resolve(preferredOutputUID) else {
                if lostActive, !outputRecoveryNeeded || isPlaying {
                    playbackIntent = false
                    isBusy = true
                    let saved = await engine.suspendOutput()
                    if !isShutDown {
                        if saved.duration > 0 { apply(saved) } else { isPlaying = false }
                        outputRecoveryNeeded = currentURL != nil && !isRestoredSession
                    }
                    isBusy = false
                }
                outputNotice = "No audio output is available."
                return
            }
            if lostActive && !wakeRecoveryPending { playbackIntent = false }
            if lostActive, target.id == routedOutputID { outputRecoveryNeeded = true }
            if wakeRecoveryPending {
                playbackIntent = playbackIntent && target.uid == sleepOutputUID
            }
            if outputRecoveryNeeded {
                guard recoveryPolicy.allowsAttempt(at: recoveryTime()) else {
                    if recoveryPolicy.exhausted {
                        playbackIntent = false
                        outputNotice = "Output keeps failing. Choose an output or try again."
                    }
                    return
                }
                await routeOutput(target.id, pause: !playbackIntent, recover: true)
                if lostActive, !outputRecoveryNeeded, !isPlaying, outputNotice == nil {
                    outputNotice = "Output disconnected. Playback paused."
                }
            } else if target.id != routedOutputID, target.id != failedAutomaticRoute {
                await routeOutput(target.id, pause: lostActive)
                if outputNotice != nil { failedAutomaticRoute = target.id }
                else if lostActive { outputNotice = "Output disconnected. Playback paused." }
            } else if outputNotice == "No audio output is available." || outputNotice?.hasPrefix("Couldn’t list audio outputs:") == true {
                outputNotice = nil
            }
        } catch { outputNotice = "Couldn’t list audio outputs: " + error.localizedDescription }
    }

    public func retryOutputRecovery() async {
        guard canRetryOutput else { return }
        outputRecoveryNeeded = true; recoveryPolicy = OutputRecoveryPolicy()
        failedAutomaticRoute = nil
        playbackIntent = isPlaying
        await refreshOutputs(force: true)
    }

    public func systemWillSleep() async {
        guard !isShutDown, !isSystemSleeping else { return }
        isSystemSleeping = true
        gaplessTask?.cancel(); gaplessPlan = nil
        while isBusy && !isShutDown {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
        }
        guard !Task.isCancelled, !isShutDown else { return }
        sleepWasPlaying = isPlaying || (outputRecoveryNeeded && playbackIntent)
        sleepOutputUID = routedOutputUID
        hadSessionBeforeSleep = currentURL != nil && !isRestoredSession
        isBusy = true; generation += 1; pendingVolume = nil; listenCounter.interrupt()
        let saved = await engine.suspendOutput()
        if !isShutDown {
            if saved.duration > 0, !isRestoredSession { apply(saved) }
            isPlaying = false
            outputRecoveryNeeded = hadSessionBeforeSleep
        }
        isBusy = false
        await saveSessionIfNeeded()
    }

    public func systemDidWake() async {
        guard !isShutDown, isSystemSleeping else { return }
        isSystemSleeping = false
        guard hadSessionBeforeSleep else { await refreshOutputs(force: true); return }
        wakeRecoveryPending = true
        playbackIntent = sleepWasPlaying && (sleepTimer.deadline.map { $0 > Date() } ?? true)
        outputRecoveryNeeded = true; recoveryPolicy = OutputRecoveryPolicy()
        failedAutomaticRoute = nil
        await refreshOutputs(force: true)
    }

    public func selectOutput(uid: String?) async {
        guard !isBusy, !isShutDown, !isSystemSleeping else { return }
        playbackIntent = isPlaying; wakeRecoveryPending = false
        recoveryPolicy = OutputRecoveryPolicy()
        do {
            let outputs = try await outputsReader.snapshot()
            guard !isBusy, !isShutDown, !isSystemSleeping else { return }
            if audioOutputs != outputs { audioOutputs = outputs }
        } catch { outputNotice = "Couldn’t list audio outputs: " + error.localizedDescription; return }
        guard uid == nil || audioOutputs.devices.contains(where: { $0.uid == uid }) else {
            outputNotice = "This output is no longer available."; return
        }
        guard let target = audioOutputs.resolve(uid) else { outputNotice = "No audio output is available."; return }
        await routeOutput(target.id, pause: false, recover: outputRecoveryNeeded)
        guard outputNotice == nil, !isShutDown else { return }
        preferredOutputUID = uid
        outputPreferences.set(uid, forKey: "preferredOutputUID")
        failedAutomaticRoute = nil
    }

    public func setExclusiveOutput(_ enabled: Bool) async {
        guard canSetExclusiveOutput, exclusiveOutput != enabled else { return }
        guard let target = routedOutputID else {
            outputNotice = "No output is open for exclusive mode."
            return
        }
        await routeOutput(target, pause: false, exclusive: enabled)
    }

    private func routeOutput(_ id: UInt32, pause: Bool, recover: Bool = false, exclusive requestedExclusive: Bool? = nil) async {
        let exclusive = requestedExclusive ?? exclusiveOutput
        guard !isBusy, !isShutDown, !isSystemSleeping else { return }
        isBusy = true; generation += 1
        pendingVolume = nil
        listenCounter.interrupt()
        let requestedUID = audioOutputs.devices.first { $0.id == id }?.uid
        if recover { recoveryPolicy.attempted() }
        defer { gaplessPlan = nil; isBusy = false }
        do {
            var snapshot: PlaybackSnapshot
            var resumeWasCancelled = false
            if recover {
                // Rebuild paused, then recheck intent and identity before starting audio.
                snapshot = try await engine.recoverOutput(id, resume: false, exclusive: exclusive)
                if let target = recoverySeekPosition, snapshot.duration > 0 {
                    snapshot = try await engine.seek(to: target)
                    recoverySeekPosition = nil
                }
                if playbackIntent, !pause, !isShutDown, !isSystemSleeping, snapshot.duration > 0 {
                    let latest = try? await outputsReader.snapshot()
                    let sameDevice = latest?.devices.contains { $0.id == id && $0.uid == requestedUID } == true
                    if sameDevice, playbackIntent, !isShutDown, !isSystemSleeping,
                       sleepTimer.deadline.map({ $0 > Date() }) ?? true {
                        snapshot = try await engine.togglePlayback()
                    } else { playbackIntent = false; resumeWasCancelled = true }
                }
            } else { snapshot = try await engine.selectOutput(id, pause: pause, exclusive: exclusive) }
            guard !isShutDown else { return }
            exclusiveOutput = exclusive
            routedOutputID = id; routedOutputUID = audioOutputs.devices.first { $0.id == id }?.uid
            outputNotice = resumeWasCancelled ? "Output changed. Playback paused." : nil
            outputRecoveryNeeded = false; wakeRecoveryPending = false; recoveryPolicy.succeeded()
            if !isRestoredSession, currentURL != nil { apply(snapshot) }
            volumeDeviceID = id
            outputVolume = await volumeController.snapshot(deviceID: id)
        } catch {
            guard !isShutDown else { return }
            if !isRestoredSession, currentURL != nil {
                let snapshot = await engine.snapshot()
                if snapshot.needsOutputRecovery { outputRecoveryNeeded = true }
                if snapshot.duration > 0 { apply(snapshot) }
                else { isPlaying = false } // Retain song/position for output recovery.
            }
            if recover {
                outputRecoveryNeeded = true
                recoveryPolicy.failed(at: recoveryTime())
                if recoveryPolicy.exhausted { playbackIntent = false }
                outputNotice = recoveryPolicy.exhausted ? "Couldn’t reconnect. Choose an output or try again." : "Reconnecting output… " + error.localizedDescription
            } else { outputNotice = error.localizedDescription }
        }
    }

    public func setVolume(to level: Double) async {
        guard !isShutDown, level.isFinite, canSetOutputVolume else { return }
        pendingVolume = (max(0, min(level, 1)), outputVolume.deviceID)
        guard !settingVolume else { return }
        settingVolume = true
        defer { settingVolume = false }
        while let (value, device) = pendingVolume {
            pendingVolume = nil
            do {
                let volume = try await volumeController.setLevel(value, deviceID: device)
                guard !isShutDown else { return }
                if outputVolume.deviceID == device { outputVolume = volume }
                volumeError = nil
            } catch {
                volumeError = error.localizedDescription
                pendingVolume = nil
            }
        }
    }

    public func restoreSession() async {
        guard !didAttemptRestore, !isBusy, !isShutDown else { return }
        didAttemptRestore = true
        guard queue.isEmpty, currentURL == nil else { return }
        lastSavedSession = sessionSnapshot()
        guard let sessionStore else { return }
        isBusy = true
        generation += 1
        let revision = generation
        defer { isBusy = false }
        do {
            guard let saved = try await sessionStore.load(), generation == revision, !isShutDown else { return }
            queue = saved.entries; currentEntryID = saved.currentID
            unshuffledOrder = saved.originalOrder
            shuffleEnabled = saved.shuffle; repeatMode = saved.repeatMode
            if let entry = queue.first(where: { $0.id == saved.currentID }) {
                title = entry.title; subtitle = entry.subtitle; artworkURL = entry.artworkURL
                currentURL = entry.url; duration = saved.duration; position = saved.position
                isRestoredSession = true
                setError(entry.error)
            }
            lastSavedSession = sessionSnapshot()
        } catch { sessionNotice = "Couldn’t restore the previous session: " + error.localizedDescription }
    }

    public func saveSessionIfNeeded() async {
        guard didAttemptRestore, !isBusy, !isShutDown, let sessionStore else { return }
        let session = sessionSnapshot()
        guard session != lastSavedSession else { return }
        do {
            try await sessionStore.save(session)
            lastSavedSession = session
            sessionNotice = nil
        } catch { sessionNotice = "Couldn’t save your listening session: " + error.localizedDescription }
    }

    public func dismissSessionNotice() { sessionNotice = nil }

    private func sessionSnapshot() -> PlaybackSession {
        let standalone = queue.isEmpty && duration > 0 ? standaloneEntry : nil
        let entries = standalone.map { [$0] } ?? queue
        return PlaybackSession(entries: entries, currentID: standalone?.id ?? currentEntryID,
            position: position, duration: duration, shuffle: shuffleEnabled, repeatMode: repeatMode,
            originalOrder: standalone.map { [$0.id] } ?? unshuffledOrder)
    }

    deinit {
        gaplessTask?.cancel()
        engine.shutdown()
    }

    public func open(_ url: URL, accessRoot: URL? = nil, displayTitle: String? = nil) async {
        guard !isBusy, !isShutDown, !isSystemSleeping else { return }
        isBusy = true
        defer { isBusy = false }
        queueRemovals = []
        queue = []
        unshuffledOrder = []
        currentEntryID = nil
        activeArtworkChange = nil
        standaloneEntry = QueueEntry(url: url, accessRoot: accessRoot, title: displayTitle)
        await load(url, accessRoot: accessRoot, displayTitle: displayTitle)
    }

    @discardableResult
    private func load(_ url: URL, accessRoot: URL?, displayTitle: String?, entry: QueueEntry? = nil,
                      startPlayback: Bool = false) async -> Bool {
        gaplessTask?.cancel(); gaplessPlan = nil; playbackToken = nil
        isScrubbing = false; scrubWasPlaying = false; scrubURL = nil; pendingSeekResume = false
        outputRecoveryNeeded = false; wakeRecoveryPending = false; recoveryPolicy = OutputRecoveryPolicy()
        playbackIntent = startPlayback; recoverySeekPosition = nil
        generation += 1
        let revision = generation
        completionHandled = false
        listenCounter = ListenCounter()
        isRestoredSession = false
        // Keep the displayed song intact while opening. Clearing its identity
        // here makes album highlights and format chips disappear until open ends.
        volumeDeviceID = nil
        let oldAccess = scopedAccess
        scopedAccess = ScopedFileAccess(accessRoot ?? url)
        defer { withExtendedLifetime(oldAccess) {} }
        do {
            // A missing catalogue must never turn a playable song into an import/open error.
            if let outputs = try? await outputsReader.snapshot(), audioOutputs != outputs { audioOutputs = outputs }
            let target = audioOutputs.resolve(preferredOutputUID)?.id
            isCrossfadeProcessing = crossfadeEnabled
            var snapshot = try await engine.open(url, outputDeviceID: target, crossfade: isCrossfadeProcessing)
            routedOutputID = snapshot.output?.id ?? target
            routedOutputUID = audioOutputs.devices.first { $0.id == routedOutputID }?.uid
            guard generation == revision, !isShutDown else { return false }
            let presentation = entry == nil && snapshot.source != nil
                ? await Task.detached(priority: .utility) { TrackPresentation.read(url: url) }.value : nil
            guard generation == revision, !isShutDown else { return false }
            // Publish the new song and its playing snapshot together. An open
            // snapshot is paused, which would briefly flash the Play icon and
            // reset the seek bar before the following start completes.
            var playbackError: String?
            if startPlayback {
                do { snapshot = try await engine.togglePlayback() }
                catch {
                    snapshot = await engine.snapshot()
                    playbackError = error.localizedDescription
                }
                guard generation == revision, !isShutDown else { return false }
            }
            title = displayTitle ?? presentation?.title ?? url.deletingPathExtension().lastPathComponent
            subtitle = entry?.subtitle ?? presentation?.subtitle ?? ""
            if let updated = entry.flatMap({ entry in queue.first { $0.id == entry.id } }) {
                artworkURL = updated.artworkURL
            } else if let change = activeArtworkChange, change.fileURL.standardizedFileURL == url.standardizedFileURL {
                artworkURL = change.artworkURL
            } else { artworkURL = entry?.artworkURL ?? presentation?.artworkURL }
            currentURL = url
            outputNotice = nil
            sourceRevision &+= 1
            if entry == nil {
                standaloneEntry = QueueEntry(url: url, accessRoot: accessRoot, title: title, subtitle: subtitle,
                                            artworkURL: artworkURL, artist: presentation?.artist, album: presentation?.album)
            }
            setError(nil)
            apply(snapshot)
            if let playbackError { setError(playbackError, fromPlayback: true) }
            return true
        } catch {
            guard generation == revision, !isShutDown else { return false }
            currentURL = nil
            artworkURL = nil
            subtitle = ""
            title = "No file open"
            sourceDescription = nil
            outputDescription = nil
            formatInfo = nil
            duration = 0; position = 0; isPlaying = false; underrunFrames = 0
            scopedAccess = nil
            setError(error.localizedDescription)
            return false
        }
    }

    public func togglePlayback() async {
        guard !isSystemSleeping, !isBusy, !isShutDown else { return }
        playbackIntent = !isPlaying; wakeRecoveryPending = false
        if outputRecoveryNeeded, !isPlaying, !isRestoredSession {
            recoveryPolicy = OutputRecoveryPolicy()
            await refreshOutputs(force: true)
            return
        }
        if !isBusy, !isShutDown, duration == 0, currentEntryID == nil, !queue.isEmpty {
            await next()
            return
        }
        if isRestoredSession {
            guard !isBusy, !isShutDown, let index = currentQueueIndex else { return }
            isBusy = true
            defer { isBusy = false }
            let target = position
            let cachedDuration = duration
            let entry = queue[index]
            await load(entry.url, accessRoot: entry.accessRoot, displayTitle: entry.title, entry: entry)
            guard !isShutDown else { return }
            if errorMessage == nil {
                do {
                    apply(try await engine.seek(to: min(target, duration)))
                    playbackIntent = true
                    apply(try await engine.togglePlayback())
                    queue[index].error = nil
                } catch { setError(error.localizedDescription) }
            }
            if let errorMessage {
                queue[index].error = errorMessage
                isRestoredSession = true
                title = entry.title; subtitle = entry.subtitle; artworkURL = entry.artworkURL
                currentURL = entry.url; duration = cachedDuration; position = target
                isPlaying = false
                sourceDescription = nil; outputDescription = nil; formatInfo = nil
            }
            return
        }
        await control { try await self.engine.togglePlayback() }
        if isPlaying { outputNotice = nil }
    }

    /// Capture playback intent for a scrub gesture. Intermediate scrub seeks
    /// stay paused; only the release seek resumes the device.
    public func beginScrubbing() {
        guard !isShutDown, !isSystemSleeping, !isRestoredSession, duration > 0 else { return }
        guard !isScrubbing else { return }
        isScrubbing = true
        scrubWasPlaying = isPlaying
        scrubURL = currentURL
    }

    public func scrub(to seconds: Double) async {
        guard isScrubbing else { await seek(to: seconds); return }
        await performSeek(seconds, resume: false)
    }

    public func endScrubbing(at seconds: Double) async {
        guard isScrubbing else { await seek(to: seconds); return }
        let resume = finishScrub()
        await performSeek(seconds, resume: resume)
    }

    /// Abandon a scrub without seeking (view teardown, track change or sleep).
    ///
    /// Intermediate scrub seeks pause the device, so ending a gesture must
    /// always decide whether playback resumes. Previously the resume request was
    /// dropped whenever the player happened to be busy, which left audio paused
    /// permanently; the decision is now recorded and honoured by whichever seek
    /// is currently running.
    public func cancelScrubbing() {
        guard isScrubbing else { return }
        let resume = finishScrub()
        guard resume else { return }
        // A running seek loop owns the device right now; hand it the resume.
        if isSeeking {
            pendingScrubResume = true
            pendingSeekResume = true
            return
        }
        guard !isShutDown, !isBusy, !isPlaying, duration > 0 else { return }
        Task { await performSeek(position, resume: true) }
    }

    /// Clears scrub state and returns whether playback should resume. Single
    /// exit point so track changes, recovery, sleep and teardown cannot diverge.
    private func finishScrub() -> Bool {
        let resume = scrubWasPlaying && !isShutDown && scrubURL == currentURL
        isScrubbing = false
        scrubWasPlaying = false
        scrubURL = nil
        return resume
    }

    public func seek(to seconds: Double) async {
        await performSeek(seconds, resume: isPlaying)
    }

    private func performSeek(_ seconds: Double, resume: Bool) async {
        guard !isShutDown, !isSystemSleeping, seconds.isFinite, duration > 0 else { return }
        playbackIntent = resume; wakeRecoveryPending = false
        if outputRecoveryNeeded, !isPlaying {
            let target = max(0, min(seconds, duration))
            position = target; recoverySeekPosition = target
            return
        }
        if isRestoredSession {
            guard !isBusy else { return }
            position = max(0, min(seconds, duration))
            return
        }
        guard !isBusy || isSeeking else { return }
        listenCounter.interrupt()
        let target = max(0, min(seconds, duration))
        pendingSeek = target
        pendingSeekResume = pendingSeekResume || resume
        position = target
        guard !isSeeking else { return }
        var finished = false
        generation += 1
        isSeeking = true
        isBusy = true
        defer {
            gaplessPlan = nil; isSeeking = false; isBusy = false
            pendingSeekResume = false
            pendingScrubResume = false
        }
        // One decoder operation at a time; intermediate drag/key requests are superseded.
        while let target = pendingSeek, !isShutDown {
            // A scrub that was cancelled while this loop owned the device must
            // still resume, even though its gesture state is already cleared.
            let shouldResume = pendingSeekResume || pendingScrubResume
            pendingSeek = nil
            pendingSeekResume = false
            pendingScrubResume = false
            do {
                var snapshot = try await engine.seek(to: target, resume: shouldResume)
                guard !isShutDown else { return }
                // A superseded seek may have stopped exactly at EOF. Preserve
                // playback intent if the latest request moves back into the song.
                if pendingSeek == nil, shouldResume, !snapshot.isPlaying, !snapshot.didFinish, snapshot.error == nil {
                    snapshot = try await engine.togglePlayback()
                    guard !isShutDown else { return }
                }
                setError(nil)
                if !snapshot.didFinish { completionHandled = false }
                if pendingSeek == nil {
                    apply(snapshot)
                    finished = snapshot.didFinish && snapshot.error == nil
                }
            } catch {
                pendingSeek = nil
                pendingSeekResume = false
                let snapshot = await engine.snapshot()
                guard !isShutDown else { return }
                apply(snapshot)
                setError(error.localizedDescription, fromPlayback: true)
                return
            }
        }
        // A scrub cancelled while the loop owned the device was already paused by
        // its preview seek and queued no replacement target, so there is nothing
        // left to iterate over. Resume here instead of leaving audio stopped.
        if pendingScrubResume, !isShutDown, !isPlaying, !finished, !isRestoredSession {
            pendingScrubResume = false
            do {
                let snapshot = try await engine.togglePlayback()
                guard !isShutDown else { return }
                setError(nil)
                if !snapshot.didFinish { completionHandled = false }
                apply(snapshot)
            } catch {
                let snapshot = await engine.snapshot()
                guard !isShutDown else { return }
                apply(snapshot)
                setError(error.localizedDescription, fromPlayback: true)
            }
        }
        if finished, !isShutDown, !completionHandled, !isScrubbing {
            // Completion cannot depend on the playing-only UI polling task:
            // an EOF seek has already stopped it. Release the seek lock first.
            isSeeking = false; isBusy = false
            completionHandled = true
            await advanceAfterCompletion()
        }
    }

    public func refresh() async {
        guard !isBusy, !isShutDown, !isRestoredSession, !isSystemSleeping else { return }
        let revision = generation
        let snapshot = await engine.snapshot()
        guard generation == revision, !isBusy else { return }
        apply(snapshot)
        if let error = snapshot.error, let index = currentQueueIndex { queue[index].error = error }
        if snapshot.didFinish, snapshot.error == nil, !completionHandled {
            completionHandled = true
            await advanceAfterCompletion()
        }
    }

    /// Replaces the queue and starts at the selected entry.
    public func play(_ entries: [QueueEntry], startingAt index: Int = 0, shuffle: Bool? = nil) async {
        guard !isBusy, !isShutDown, !isSystemSleeping, entries.indices.contains(index) else { return }
        queueRemovals = []
        queue = entries
        unshuffledOrder = entries.map(\.id)
        if let shuffle { shuffleEnabled = shuffle }
        if shuffle == true {
            // An explicit album shuffle includes every song, including the first selection.
            queue.shuffle()
            await playFrom(0)
        } else {
            if shuffleEnabled { shuffleUpcoming(after: index) }
            await playFrom(index)
        }
    }

    public func enqueue(_ entry: QueueEntry, playNext: Bool = false) {
        guard !isBusy, !isShutDown, !isSystemSleeping else { return }
        // Include a standalone file in the queue before adding its successor.
        if queue.isEmpty, let standaloneEntry, duration > 0 {
            queue = [standaloneEntry]; currentEntryID = standaloneEntry.id
            unshuffledOrder = [standaloneEntry.id]
        }
        if playNext {
            queue.insert(entry, at: (currentQueueIndex.map { $0 + 1 }) ?? 0)
            let originalIndex = currentEntryID.flatMap { unshuffledOrder.firstIndex(of: $0) }
            unshuffledOrder.insert(entry.id, at: originalIndex.map { $0 + 1 } ?? 0)
        } else {
            queue.append(entry)
            unshuffledOrder.append(entry.id)
        }
    }

    public func next() async {
        guard !isBusy, !isShutDown, !isSystemSleeping else { return }
        let index = currentQueueIndex.map { $0 + 1 } ?? 0
        if queue.indices.contains(index) { await playFrom(index, wrapping: repeatMode == .all) }
        else if repeatMode == .all, !queue.isEmpty { await playFrom(0) }
    }

    private func advanceAfterCompletion() async {
        if queue.isEmpty, let standaloneEntry, duration > 0, repeatMode != .off {
            queue = [standaloneEntry]
            unshuffledOrder = [standaloneEntry.id]
            currentEntryID = standaloneEntry.id
        }
        if repeatMode == .one, let index = currentQueueIndex { await playFrom(index) }
        else { await next() }
    }

    public func setRepeatMode(_ mode: RepeatMode) {
        guard !isBusy, !isShutDown, !isSystemSleeping else { return }
        repeatMode = mode
    }

    public func toggleShuffle() {
        guard !isBusy, !isShutDown, !isSystemSleeping else { return }
        queueRemovals = []
        shuffleEnabled.toggle()
        let start = currentQueueIndex.map { $0 + 1 } ?? 0
        if shuffleEnabled { shuffleUpcoming(after: start - 1) }
        else {
            let ranks = Dictionary(uniqueKeysWithValues: unshuffledOrder.enumerated().map { ($1, $0) })
            queue = Array(queue.prefix(start)) + queue.dropFirst(start).sorted {
                (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max)
            }
        }
    }

    private func shuffleUpcoming(after index: Int) {
        let start = index + 1
        queue = Array(queue.prefix(start)) + queue.dropFirst(start).shuffled()
    }

    public func previous() async {
        guard !isBusy, !isShutDown, let index = currentQueueIndex else { return }
        if position > 3 || index == 0 { await seek(to: 0) }
        else { await playFrom(index - 1) }
    }

    public func playEntry(_ id: UUID) async {
        guard !isBusy, !isShutDown, let index = queue.firstIndex(where: { $0.id == id }) else { return }
        await playFrom(index)
    }

    public func removeUpcoming(_ id: UUID) {
        guard !isBusy, !isShutDown, upcomingEntries.contains(where: { $0.id == id }) else { return }
        rememberRemoval(queue.filter { $0.id == id })
        queue.removeAll { $0.id == id }
        unshuffledOrder.removeAll { $0 == id }
    }

    public func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        guard !isBusy, !isShutDown, !isSystemSleeping else { return }
        let start = currentQueueIndex.map { $0 + 1 } ?? 0
        var upcoming = Array(queue.dropFirst(start))
        guard destination >= 0, destination <= upcoming.count,
              offsets.allSatisfy({ upcoming.indices.contains($0) }) else { return }
        guard !offsets.isEmpty else { return }
        queueRemovals = []
        let moving = offsets.sorted().map { upcoming[$0] }
        for index in offsets.sorted().reversed() { upcoming.remove(at: index) }
        let insertion = destination - offsets.filter { $0 < destination }.count
        upcoming.insert(contentsOf: moving, at: insertion)
        queue = Array(queue.prefix(start)) + upcoming
        unshuffledOrder = queue.map(\.id)
    }

    public func clearUpcoming() {
        guard !isBusy, !isShutDown, !isSystemSleeping else { return }
        rememberRemoval(upcomingEntries, cleared: true)
        if let index = currentQueueIndex { queue = Array(queue.prefix(index + 1)) }
        else { queue = [] }
        let retained = Set(queue.map(\.id))
        unshuffledOrder.removeAll { !retained.contains($0) }
    }

    private var standaloneEntry: QueueEntry?

    private func playFrom(_ start: Int, wrapping: Bool = false) async {
        queueRemovals = []
        isBusy = true
        defer { isBusy = false }
        // A bounded forward pass skips broken files without looping forever.
        let indices = Array(start..<queue.count) + (wrapping ? Array(0..<start) : [])
        for index in indices {
            let entry = queue[index]
            currentEntryID = entry.id
            let opened = await load(entry.url, accessRoot: entry.accessRoot, displayTitle: entry.title,
                                    entry: entry, startPlayback: true)
            guard !isShutDown else { return }
            queue[index].error = errorMessage
            if opened { return }
        }
    }

    public func reportImportError(_ error: any Error) { setError(error.localizedDescription) }

    public func shutdown() {
        guard !isShutDown else { return }
        mediaControls?.stop()
        mediaControls = nil
        lifecycle?.stop(); lifecycle = nil
        playbackIntent = false
        sleepTimer.cancel()
        queueRemovals = []
        isShutDown = true
        gaplessTask?.cancel(); gaplessTask = nil
        pendingVolume = nil
        pendingSeek = nil
        pendingSeekResume = false
        isScrubbing = false; scrubWasPlaying = false; scrubURL = nil
        if didAttemptRestore, !isBusy, let sessionStore {
            do {
                let session = sessionSnapshot()
                if session != lastSavedSession { try sessionStore.saveSynchronously(session) }
            }
            catch { sessionNotice = "Couldn’t save your listening session: " + error.localizedDescription }
        }
        generation += 1
        completionHandled = true
        engine.shutdown()
        scopedAccess = nil
        artworkURL = nil
        subtitle = ""
        currentURL = nil
        isRestoredSession = false
        isPlaying = false
        sourceDescription = nil
        outputDescription = nil
        formatInfo = nil
        duration = 0
        position = 0
    }

    private func control(_ action: () async throws -> PlaybackSnapshot) async {
        guard !isBusy, !isShutDown, duration > 0 else { return }
        generation += 1
        let revision = generation
        isBusy = true
        defer { isBusy = false }
        do {
            let snapshot = try await action()
            guard generation == revision, !isShutDown else { return }
            if !snapshot.didFinish { completionHandled = false }
            setError(nil)
            apply(snapshot)
        }
        catch {
            let snapshot = await engine.snapshot()
            if snapshot.duration > 0 { apply(snapshot) }
            else { isPlaying = false }
            setError(error.localizedDescription, fromPlayback: true)
        }
    }

    private func apply(_ snapshot: PlaybackSnapshot) {
        adoptContinuation(snapshot)
        if snapshot.needsOutputRecovery {
            outputRecoveryNeeded = true
        } else if snapshot.error != nil { playbackIntent = false }
        if snapshot.didFinish { playbackIntent = false }
        if snapshot.error != nil { listenCounter.interrupt() }
        if listenCounter.sample(time: listeningTime(), position: snapshot.position,
                                duration: snapshot.duration, playing: snapshot.isPlaying && snapshot.error == nil),
           let currentURL {
            onQualifiedListen?(currentURL, Date())
        }
        if volumeDeviceID != snapshot.output?.id { pendingVolume = nil }
        volumeDeviceID = snapshot.output?.id
        updateFormat(snapshot)
        if duration != snapshot.duration { duration = snapshot.duration }
        if position != snapshot.position { position = snapshot.position }
        if isPlaying != snapshot.isPlaying { isPlaying = snapshot.isPlaying }
        if underrunFrames != snapshot.underrunFrames { underrunFrames = snapshot.underrunFrames }
        // Healthy engine state clears playback failures, while file-picker/open
        // failures remain visible until a successful user operation replaces them.
        if let error = snapshot.error { setError(error, fromPlayback: true) }
        else if errorIsFromPlayback { setError(nil) }
    }

    private func setError(_ message: String?, fromPlayback: Bool = false) {
        errorIsFromPlayback = message != nil && fromPlayback
        if errorMessage != message { errorMessage = message }
    }

    private func updateFormat(_ snapshot: PlaybackSnapshot) {
        guard describedSource != snapshot.source || describedOutput != snapshot.output ||
                describedExclusive != snapshot.isExclusive ||
                (formatInfo != nil && formatInfo?.underrunFrames != snapshot.underrunFrames) ||
                formatInfo?.clientPCM?.sampleRate != snapshot.clientPCM?.sampleRate ||
                (formatInfo == nil && snapshot.source != nil) else { return }
        describedSource = snapshot.source
        describedOutput = snapshot.output
        describedExclusive = snapshot.isExclusive
        sourceDescription = snapshot.source?.description
        outputDescription = snapshot.output?.text
        let nextInfo = snapshot.source.map { source in
            let output = snapshot.output.map {
                SignalOutput(name: $0.name, sampleRate: $0.sampleRate,
                             bitDepth: $0.bitDepth > 0 ? Int($0.bitDepth) : nil,
                             channels: $0.channels > 0 ? Int($0.channels) : nil, isFloat: $0.isFloat)
            }
            let transport: OutputTransport
            switch snapshot.output?.transport {
            case .local: transport = .local
            case .bluetooth: transport = .bluetooth
            case .airPlay: transport = .airPlay
            default: transport = .unknown
            }
            let client = snapshot.clientPCM.map {
                SignalPCM(sampleRate: $0.sampleRate, validBits: $0.validBits,
                          containerBits: $0.containerBits, channels: $0.channels,
                          isFloat: $0.isFloat)
            }
            return FormatClassifier.describe(source: source, path: SignalPath(
                output: output, clientPCM: client,
                underrunFrames: snapshot.underrunFrames,
                isExclusive: snapshot.isExclusive, transport: transport))
        }
        if formatInfo != nextInfo { formatInfo = nextInfo }
    }
}

/// Immutable lifetime token: access is released only after the engine closes the file.
private final class ScopedFileAccess: Sendable {
    let url: URL
    let acquired: Bool
    init(_ url: URL) {
        self.url = url
        acquired = url.startAccessingSecurityScopedResource()
    }
    deinit { if acquired { url.stopAccessingSecurityScopedResource() } }
}
