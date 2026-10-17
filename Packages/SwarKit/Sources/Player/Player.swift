import AudioEngine
import Decoding
import Foundation
import FormatInfo
import Library
import Observation

@MainActor @Observable
public final class Player {
    public private(set) var title = "No file open"
    public private(set) var subtitle = ""
    public private(set) var artworkURL: URL?
    public private(set) var currentURL: URL?
    public private(set) var sourceDescription: String?
    public private(set) var outputDescription: String?
    public private(set) var duration: Double = 0
    public private(set) var position: Double = 0
    public private(set) var isPlaying = false
    public private(set) var isBusy = false
    public private(set) var isSeeking = false
    private var pendingSeek: Double?
    public private(set) var errorMessage: String?
    public private(set) var underrunFrames: UInt64 = 0
    public private(set) var formatInfo: FormatChipInfo?
    public private(set) var isRestoredSession = false
    public private(set) var sessionNotice: String?
    public private(set) var outputVolume = OutputVolume()
    public private(set) var volumeError: String?
    private var settingVolume = false
    private var pendingVolume: (Double, UInt32)?
    private var volumeDeviceID: UInt32?
    private var describedSource: SourceFormat?
    private var describedOutput: OutputDescription?
    @ObservationIgnored private var mediaControls: SystemMediaControls?

    public func enableSystemMediaControls() {
        guard mediaControls == nil, !isShutDown else { return }
        let controls = SystemMediaControls(player: self, output: MacNowPlayingOutput())
        mediaControls = controls
        controls.start()
    }

    var currentMediaEntry: QueueEntry? {
        guard let currentURL else { return nil }
        return queue.first { $0.url == currentURL } ?? (standaloneEntry?.url == currentURL ? standaloneEntry : nil)
    }
    public var currentArtist: String? { currentMediaEntry?.artist }
    public var currentAlbum: String? { currentMediaEntry?.album }

    public var canSetOutputVolume: Bool {
        !isBusy && !isShutDown && outputVolume.canSet && (volumeDeviceID == nil || volumeDeviceID == outputVolume.deviceID)
    }

    public private(set) var queue: [QueueEntry] = []
    public private(set) var currentEntryID: UUID?
    public private(set) var shuffleEnabled = false
    public private(set) var repeatMode: RepeatMode = .off
    private var unshuffledOrder: [UUID] = []
    public var currentQueueIndex: Int? { queue.firstIndex { $0.id == currentEntryID } }
    public var canGoNext: Bool { currentQueueIndex.map { $0 + 1 < queue.count || (repeatMode == .all && !queue.isEmpty) } ?? !queue.isEmpty }
    public var canTogglePlayback: Bool { duration > 0 || isRestoredSession || (currentEntryID == nil && !queue.isEmpty) }
    public var canGoPrevious: Bool { currentQueueIndex.map { $0 > 0 || position > 0 } ?? false }
    public var upcomingEntries: [QueueEntry] {
        guard let index = currentQueueIndex else { return queue }
        return Array(queue.dropFirst(index + 1))
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

    public init(engine: any PlaybackDriving = AudioPlaybackEngine(), sessionStore: PlaybackSessionStore? = nil, volumeController: any OutputVolumeControlling = HardwareVolumeController(), sleepTimer: SleepTimer? = nil) {
        self.engine = engine
        self.sessionStore = sessionStore
        self.volumeController = volumeController
        self.sleepTimer = sleepTimer ?? SleepTimer()
        self.sleepTimer.onExpire = { [weak self] in await self?.pauseForSleepTimer() }
    }

    private func pauseForSleepTimer() async {
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
        guard !isShutDown, !settingVolume else { return }
        let revision = generation
        let volume = await volumeController.snapshot(deviceID: volumeDeviceID)
        guard !isShutDown, !settingVolume, revision == generation else { return }
        if outputVolume.deviceID != volume.deviceID || !volume.canSet { volumeError = nil }
        if outputVolume != volume { outputVolume = volume }
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
                errorMessage = entry.error
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
        engine.shutdown()
    }

    public func open(_ url: URL, accessRoot: URL? = nil, displayTitle: String? = nil) async {
        guard !isBusy, !isShutDown else { return }
        isBusy = true
        defer { isBusy = false }
        queue = []
        unshuffledOrder = []
        currentEntryID = nil
        standaloneEntry = QueueEntry(url: url, accessRoot: accessRoot, title: displayTitle)
        await load(url, accessRoot: accessRoot, displayTitle: displayTitle)
    }

    @discardableResult
    private func load(_ url: URL, accessRoot: URL?, displayTitle: String?, entry: QueueEntry? = nil,
                      startPlayback: Bool = false) async -> Bool {
        generation += 1
        let revision = generation
        completionHandled = false
        isRestoredSession = false
        // Keep the displayed song intact while opening. Clearing its identity
        // here makes album highlights and format chips disappear until open ends.
        volumeDeviceID = nil
        let oldAccess = scopedAccess
        scopedAccess = ScopedFileAccess(accessRoot ?? url)
        defer { withExtendedLifetime(oldAccess) {} }
        do {
            var snapshot = try await engine.open(url)
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
            artworkURL = entry?.artworkURL ?? presentation?.artworkURL
            currentURL = url
            if entry == nil {
                standaloneEntry = QueueEntry(url: url, accessRoot: accessRoot, title: title, subtitle: subtitle,
                                            artworkURL: artworkURL, artist: presentation?.artist, album: presentation?.album)
            }
            errorMessage = playbackError
            apply(snapshot)
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
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func togglePlayback() async {
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
                    apply(try await engine.togglePlayback())
                    queue[index].error = nil
                } catch { errorMessage = error.localizedDescription }
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
    }

    public func seek(to seconds: Double) async {
        guard !isShutDown, seconds.isFinite, duration > 0 else { return }
        if isRestoredSession {
            guard !isBusy else { return }
            position = max(0, min(seconds, duration))
            return
        }
        guard !isBusy || isSeeking else { return }
        let target = max(0, min(seconds, duration))
        pendingSeek = target
        position = target
        guard !isSeeking else { return }
        generation += 1
        isSeeking = true
        isBusy = true
        defer { isSeeking = false; isBusy = false }
        // One decoder operation at a time; intermediate drag/key requests are superseded.
        while let target = pendingSeek, !isShutDown {
            pendingSeek = nil
            do {
                let snapshot = try await engine.seek(to: target)
                guard !isShutDown else { return }
                errorMessage = nil
                if !snapshot.didFinish { completionHandled = false }
                if pendingSeek == nil { apply(snapshot) }
            } catch {
                pendingSeek = nil
                let snapshot = await engine.snapshot()
                guard !isShutDown else { return }
                apply(snapshot)
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    public func refresh() async {
        guard !isBusy, !isShutDown, !isRestoredSession else { return }
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
        guard !isBusy, !isShutDown, entries.indices.contains(index) else { return }
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
        guard !isBusy, !isShutDown else { return }
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
        guard !isBusy, !isShutDown else { return }
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
        guard !isBusy, !isShutDown else { return }
        repeatMode = mode
    }

    public func toggleShuffle() {
        guard !isBusy, !isShutDown else { return }
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
        queue.removeAll { $0.id == id }
        unshuffledOrder.removeAll { $0 == id }
    }

    public func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        guard !isBusy, !isShutDown else { return }
        let start = currentQueueIndex.map { $0 + 1 } ?? 0
        var upcoming = Array(queue.dropFirst(start))
        guard destination >= 0, destination <= upcoming.count,
              offsets.allSatisfy({ upcoming.indices.contains($0) }) else { return }
        let moving = offsets.sorted().map { upcoming[$0] }
        for index in offsets.sorted().reversed() { upcoming.remove(at: index) }
        let insertion = destination - offsets.filter { $0 < destination }.count
        upcoming.insert(contentsOf: moving, at: insertion)
        queue = Array(queue.prefix(start)) + upcoming
        unshuffledOrder = queue.map(\.id)
    }

    public func clearUpcoming() {
        guard !isBusy, !isShutDown else { return }
        if let index = currentQueueIndex { queue = Array(queue.prefix(index + 1)) }
        else { queue = [] }
        let retained = Set(queue.map(\.id))
        unshuffledOrder.removeAll { !retained.contains($0) }
    }

    private var standaloneEntry: QueueEntry?

    private func playFrom(_ start: Int, wrapping: Bool = false) async {
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

    public func reportImportError(_ error: any Error) { errorMessage = error.localizedDescription }

    public func shutdown() {
        guard !isShutDown else { return }
        mediaControls?.stop()
        mediaControls = nil
        sleepTimer.cancel()
        isShutDown = true
        pendingVolume = nil
        pendingSeek = nil
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
            errorMessage = nil
            apply(snapshot)
        }
        catch {
            apply(await engine.snapshot())
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ snapshot: PlaybackSnapshot) {
        if volumeDeviceID != snapshot.output?.id { pendingVolume = nil }
        volumeDeviceID = snapshot.output?.id
        updateFormat(snapshot)
        if duration != snapshot.duration { duration = snapshot.duration }
        if position != snapshot.position { position = snapshot.position }
        if isPlaying != snapshot.isPlaying { isPlaying = snapshot.isPlaying }
        if underrunFrames != snapshot.underrunFrames { underrunFrames = snapshot.underrunFrames }
        // Import/open errors are owned by Player. Routine polling must not erase them.
        if let error = snapshot.error, errorMessage != error { errorMessage = error }
    }

    private func updateFormat(_ snapshot: PlaybackSnapshot) {
        guard describedSource != snapshot.source || describedOutput != snapshot.output ||
                (formatInfo == nil && snapshot.source != nil) else { return }
        describedSource = snapshot.source
        describedOutput = snapshot.output
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
            // Device metadata supplies transport; sample integrity and volume remain unverified.
            return FormatClassifier.describe(source: source, path: SignalPath(output: output, transport: transport))
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
