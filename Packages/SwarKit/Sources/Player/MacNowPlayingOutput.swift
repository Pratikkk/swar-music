import AppKit
import ImageIO
import MediaPlayer
import Foundation

/// The OS advances elapsed time from playback rate; do not republish every UI tick.
struct MediaTimeline {
    private var presentation: MediaPresentation?
    private var position = 0.0
    private var timestamp = 0.0

    mutating func needsUpdate(_ state: MediaState, at time: Double, force: Bool) -> Bool {
        let expected = position + (presentation?.isPlaying == true ? max(0, time - timestamp) : 0)
        guard force || presentation != state.presentation ||
                abs(state.position - expected) > 0.5 ||
                (!state.presentation.isPlaying && state.position != position) else { return false }
        presentation = state.presentation
        position = state.position
        timestamp = time
        return true
    }
}

@MainActor final class MacNowPlayingOutput: NowPlayingOutput {
    private let center = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private var registrations: [(MPRemoteCommand, Any)] = []
    private var timeline = MediaTimeline()
    private var lastState: MediaState?
    private var ownsPlayback = false
    private var active = false
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    func start(handler: @escaping @MainActor (MediaCommand) async -> Bool) {
        guard !active else { return }
        active = true
        for (command, action) in [
            (commands.playCommand, MediaCommand.play), (commands.pauseCommand, .pause),
            (commands.togglePlayPauseCommand, .toggle), (commands.nextTrackCommand, .next),
            (commands.previousTrackCommand, .previous)
        ] {
            let token = command.addTarget { @Sendable _ in
                Task { @MainActor in _ = await handler(action) }
                return .success
            }
            registrations.append((command, token))
            command.isEnabled = false
        }
        let token = commands.changePlaybackPositionCommand.addTarget { @Sendable event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                  event.positionTime.isFinite else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in _ = await handler(.seek(position)) }
            return .success
        }
        registrations.append((commands.changePlaybackPositionCommand, token))
        commands.changePlaybackPositionCommand.isEnabled = false
    }

    func update(_ state: MediaState, forceTimeline: Bool) {
        guard active else { return }
        lastState = state
        // Restoring an old paused queue must not steal Now Playing from another app.
        ownsPlayback = ownsPlayback || state.presentation.isPlaying
        let available = ownsPlayback && state.presentation.url != nil
        commands.playCommand.isEnabled = available && state.canPlay && !state.busy
        commands.pauseCommand.isEnabled = available && state.presentation.isPlaying && !state.busy
        commands.togglePlayPauseCommand.isEnabled = available && state.canPlay && !state.busy
        commands.nextTrackCommand.isEnabled = available && state.canNext && !state.busy
        commands.previousTrackCommand.isEnabled = available && state.canPrevious && !state.busy
        commands.changePlaybackPositionCommand.isEnabled = available && state.presentation.duration > 0 && !state.busy
        guard ownsPlayback else { return }
        guard available else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            loadArtwork(nil)
            timeline = MediaTimeline()
            return
        }
        loadArtwork(state.presentation.artworkURL)
        guard timeline.needsUpdate(state, at: ProcessInfo.processInfo.systemUptime, force: forceTimeline) else { return }
        let item = state.presentation
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist,
            MPMediaItemPropertyPlaybackDuration: item.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.position,
            MPNowPlayingInfoPropertyPlaybackRate: item.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        if let album = item.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = item.isPlaying ? .playing : .paused
    }

    private func loadArtwork(_ url: URL?) {
        guard artworkURL != url else { return }
        artworkTask?.cancel()
        artworkTask = nil
        artworkURL = url
        artwork = nil
        guard let url else { return }
        artworkTask = Task { [weak self] in
            let decoded = await Task.detached(priority: .utility) { () -> MediaArtworkImage? in
                guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 512,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return nil }
                return MediaArtworkImage(image)
            }.value
            guard !Task.isCancelled, let self, self.active, self.artworkURL == url,
                  let decoded else { return }
            self.artwork = Self.makeArtwork(decoded)
            if let state = self.lastState { self.update(state, forceTimeline: true) }
        }
    }

    // MediaPlayer invokes this provider on its own access queue. An implicitly
    // main-actor-isolated closure traps there under Swift 6 executor checking.
    nonisolated static func makeArtwork(_ decoded: MediaArtworkImage) -> MPMediaItemArtwork {
        let size = NSSize(width: decoded.image.width, height: decoded.image.height)
        return MPMediaItemArtwork(boundsSize: size) { @Sendable _ in
            NSImage(cgImage: decoded.image, size: size)
        }
    }

    func stop() {
        guard active else { return }
        active = false
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
        artworkURL = nil
        for (command, token) in registrations {
            command.removeTarget(token)
            command.isEnabled = false
        }
        registrations.removeAll()
        if ownsPlayback {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }
        ownsPlayback = false
        lastState = nil
        timeline = MediaTimeline()
    }
}

final class MediaArtworkImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
