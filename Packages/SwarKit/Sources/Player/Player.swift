import AudioEngine
import Decoding
import Foundation
import FormatInfo
import Observation

@MainActor @Observable
public final class Player {
    public private(set) var title = "No file open"
    public private(set) var sourceDescription: String?
    public private(set) var outputDescription: String?
    public private(set) var duration: Double = 0
    public private(set) var position: Double = 0
    public private(set) var isPlaying = false
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?
    public private(set) var underrunFrames: UInt64 = 0
    public private(set) var formatInfo: FormatChipInfo?

    public private(set) var queue: [QueueEntry] = []
    public private(set) var currentEntryID: UUID?
    public var currentQueueIndex: Int? { queue.firstIndex { $0.id == currentEntryID } }
    public var canGoNext: Bool { currentQueueIndex.map { $0 + 1 < queue.count } ?? !queue.isEmpty }
    public var canGoPrevious: Bool { currentQueueIndex.map { $0 > 0 || position > 0 } ?? false }
    public var upcomingEntries: [QueueEntry] {
        guard let index = currentQueueIndex else { return queue }
        return Array(queue.dropFirst(index + 1))
    }

    private let engine: any PlaybackDriving
    private var completionHandled = false
    private var scopedAccess: ScopedFileAccess?
    private var generation = 0

    public init(engine: any PlaybackDriving = AudioPlaybackEngine()) { self.engine = engine }

    deinit {
        engine.shutdown()
    }

    public func open(_ url: URL, accessRoot: URL? = nil, displayTitle: String? = nil) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        queue = []
        currentEntryID = nil
        standaloneEntry = QueueEntry(url: url, accessRoot: accessRoot, title: displayTitle)
        await load(url, accessRoot: accessRoot, displayTitle: displayTitle)
    }

    private func load(_ url: URL, accessRoot: URL?, displayTitle: String?) async {
        generation += 1
        completionHandled = false
        let oldAccess = scopedAccess
        scopedAccess = ScopedFileAccess(accessRoot ?? url)
        defer { withExtendedLifetime(oldAccess) {} }
        do {
            let snapshot = try await engine.open(url)
            title = displayTitle ?? url.deletingPathExtension().lastPathComponent
            apply(snapshot)
            errorMessage = nil
        } catch {
            title = "No file open"
            sourceDescription = nil
            outputDescription = nil
            formatInfo = nil
            duration = 0; position = 0; isPlaying = false; underrunFrames = 0
            scopedAccess = nil
            errorMessage = error.localizedDescription
        }
    }

    public func togglePlayback() async {
        await control { try await self.engine.togglePlayback() }
    }

    public func seek(to seconds: Double) async {
        await control { try await self.engine.seek(to: seconds) }
    }

    public func refresh() async {
        guard !isBusy else { return }
        let revision = generation
        let snapshot = await engine.snapshot()
        guard generation == revision, !isBusy else { return }
        apply(snapshot)
        if let error = snapshot.error, let index = currentQueueIndex { queue[index].error = error }
        if snapshot.didFinish, snapshot.error == nil, !completionHandled {
            completionHandled = true
            await next()
        }
    }

    /// Replaces the queue and starts at the selected entry.
    public func play(_ entries: [QueueEntry], startingAt index: Int = 0) async {
        guard !isBusy, entries.indices.contains(index) else { return }
        queue = entries
        await playFrom(index)
    }

    public func enqueue(_ entry: QueueEntry, playNext: Bool = false) {
        guard !isBusy else { return }
        // Include a standalone file in the queue before adding its successor.
        if queue.isEmpty, let standaloneEntry, duration > 0 {
            queue = [standaloneEntry]; currentEntryID = standaloneEntry.id
        }
        if playNext { queue.insert(entry, at: (currentQueueIndex.map { $0 + 1 }) ?? 0) }
        else { queue.append(entry) }
    }

    public func next() async {
        guard !isBusy else { return }
        let index = currentQueueIndex.map { $0 + 1 } ?? 0
        guard queue.indices.contains(index) else { return }
        await playFrom(index)
    }

    public func previous() async {
        guard !isBusy, let index = currentQueueIndex else { return }
        if position > 3 || index == 0 { await seek(to: 0) }
        else { await playFrom(index - 1) }
    }

    public func playEntry(_ id: UUID) async {
        guard !isBusy, let index = queue.firstIndex(where: { $0.id == id }) else { return }
        await playFrom(index)
    }

    public func removeUpcoming(_ id: UUID) {
        guard !isBusy, upcomingEntries.contains(where: { $0.id == id }) else { return }
        queue.removeAll { $0.id == id }
    }

    public func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        guard !isBusy else { return }
        let start = currentQueueIndex.map { $0 + 1 } ?? 0
        var upcoming = Array(queue.dropFirst(start))
        guard destination >= 0, destination <= upcoming.count,
              offsets.allSatisfy({ upcoming.indices.contains($0) }) else { return }
        let moving = offsets.sorted().map { upcoming[$0] }
        for index in offsets.sorted().reversed() { upcoming.remove(at: index) }
        let insertion = destination - offsets.filter { $0 < destination }.count
        upcoming.insert(contentsOf: moving, at: insertion)
        queue = Array(queue.prefix(start)) + upcoming
    }

    public func clearUpcoming() {
        guard !isBusy else { return }
        if let index = currentQueueIndex { queue = Array(queue.prefix(index + 1)) }
        else { queue = [] }
    }

    private var standaloneEntry: QueueEntry?

    private func playFrom(_ start: Int) async {
        isBusy = true
        defer { isBusy = false }
        // A bounded forward pass skips broken files without looping forever.
        for index in start..<queue.count {
            let entry = queue[index]
            currentEntryID = entry.id
            await load(entry.url, accessRoot: entry.accessRoot, displayTitle: entry.title)
            if errorMessage == nil {
                queue[index].error = nil
                do {
                    apply(try await engine.togglePlayback())
                } catch {
                    apply(await engine.snapshot())
                    errorMessage = error.localizedDescription
                    queue[index].error = errorMessage
                }
                return
            }
            queue[index].error = errorMessage
        }
    }

    public func reportImportError(_ error: any Error) { errorMessage = error.localizedDescription }

    public func shutdown() {
        generation += 1
        completionHandled = true
        engine.shutdown()
        scopedAccess = nil
        isPlaying = false
        sourceDescription = nil
        outputDescription = nil
        formatInfo = nil
        duration = 0
        position = 0
    }

    private func control(_ action: () async throws -> PlaybackSnapshot) async {
        guard !isBusy, duration > 0 else { return }
        generation += 1
        isBusy = true
        defer { isBusy = false }
        do {
            let snapshot = try await action()
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
        duration = snapshot.duration
        position = snapshot.position
        isPlaying = snapshot.isPlaying
        underrunFrames = snapshot.underrunFrames
        // Import/open errors are owned by Player. Routine engine polling must not erase them.
        if let error = snapshot.error { errorMessage = error }
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
