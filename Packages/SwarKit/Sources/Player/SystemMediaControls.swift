import Foundation
import Observation

enum MediaCommand: Sendable {
    case play, pause, toggle, next, previous
    case seek(Double)
}

struct MediaPresentation: Equatable, Sendable {
    let url: URL?
    let title: String
    let artist: String
    let album: String?
    let artworkURL: URL?
    let duration: Double
    let isPlaying: Bool
}

struct MediaState: Equatable, Sendable {
    let presentation: MediaPresentation
    let position: Double
    let busy: Bool
    let canPlay: Bool
    let canNext: Bool
    let canPrevious: Bool

    @MainActor init(_ player: Player) {
        let entry = player.currentMediaEntry
        presentation = MediaPresentation(url: player.currentURL, title: player.title,
            artist: entry?.artist ?? player.subtitle, album: entry?.album,
            artworkURL: player.artworkURL, duration: player.duration, isPlaying: player.isPlaying)
        position = player.position
        busy = player.isBusy
        canPlay = player.canTogglePlayback
        canNext = player.canGoNext
        canPrevious = player.canGoPrevious
    }
}

@MainActor protocol NowPlayingOutput: AnyObject {
    func start(handler: @escaping @MainActor (MediaCommand) async -> Bool)
    func update(_ state: MediaState, forceTimeline: Bool)
    func stop()
}

/// Observation keeps system controls synchronized without another polling timer.
@MainActor final class SystemMediaControls {
    private weak var player: Player?
    private let output: any NowPlayingOutput
    private var active = false

    init(player: Player, output: any NowPlayingOutput) {
        self.player = player
        self.output = output
    }

    func start() {
        guard !active else { return }
        active = true
        output.start { [weak self] command in await self?.handle(command) ?? false }
        observe()
    }

    func stop() {
        guard active else { return }
        active = false
        output.stop()
    }

    private func observe() {
        guard active, let player else { return }
        withObservationTracking {
            output.update(MediaState(player), forceTimeline: false)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    @discardableResult func handle(_ command: MediaCommand) async -> Bool {
        guard active, let player else { return false }
        switch command {
        case .seek(let position):
            guard position.isFinite, player.duration > 0, !player.isBusy || player.isSeeking else { return false }
            await player.seek(to: position)
        default:
            guard !player.isBusy else { return false }
            switch command {
            case .play:
                guard player.canTogglePlayback else { return false }
                if !player.isPlaying { await player.togglePlayback() }
            case .pause:
                guard player.canTogglePlayback else { return false }
                if player.isPlaying { await player.togglePlayback() }
            case .toggle:
                guard player.canTogglePlayback else { return false }
                await player.togglePlayback()
            case .next:
                guard player.canGoNext else { return false }
                await player.next()
            case .previous:
                guard player.canGoPrevious else { return false }
                await player.previous()
            case .seek: break
            }
        }
        guard active else { return false }
        output.update(MediaState(player), forceTimeline: true)
        return player.errorMessage == nil
    }
}
