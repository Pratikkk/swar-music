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

    private let engine = AudioPlaybackEngine()
    private var scopedAccess: ScopedFileAccess?
    private var generation = 0

    public init() {}

    deinit {
        engine.shutdown()
    }

    public func open(_ url: URL, accessRoot: URL? = nil, displayTitle: String? = nil) async {
        guard !isBusy else { return }
        isBusy = true
        generation += 1
        defer { isBusy = false }
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
    }

    public func reportImportError(_ error: any Error) { errorMessage = error.localizedDescription }

    public func shutdown() {
        generation += 1
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
