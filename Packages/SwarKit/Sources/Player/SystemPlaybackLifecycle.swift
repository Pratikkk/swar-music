import AppKit
import Foundation

/// Workspace events are serialized so a fast wake cannot overtake suspension.
@MainActor final class SystemPlaybackLifecycle {
    private weak var player: Player?
    private let center: NotificationCenter
    private var registration: WorkspaceRegistration?
    private var task: Task<Void, Never>?

    init(player: Player, center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.player = player; self.center = center
    }

    func start() {
        guard registration == nil else { return }
        let sleeping = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enqueue(sleeping: true) }
        }
        let waking = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enqueue(sleeping: false) }
        }
        registration = WorkspaceRegistration(center: center, tokens: [sleeping, waking])
    }

    func stop() { registration = nil; task?.cancel(); task = nil }
    deinit { task?.cancel() }

    private func enqueue(sleeping: Bool) {
        let previous = task
        task = Task { [weak player] in
            await previous?.value
            guard !Task.isCancelled, let player else { return }
            if sleeping { await player.systemWillSleep() }
            else { await player.systemDidWake() }
        }
    }

    func drain() async { await task?.value }
}

/// Removing observers is thread safe; the tokens never leave this lifetime owner.
private final class WorkspaceRegistration: @unchecked Sendable {
    let center: NotificationCenter
    let tokens: [NSObjectProtocol]
    init(center: NotificationCenter, tokens: [NSObjectProtocol]) { self.center = center; self.tokens = tokens }
    deinit { tokens.forEach(center.removeObserver) }
}
