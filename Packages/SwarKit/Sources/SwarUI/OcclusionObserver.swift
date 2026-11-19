import SwiftUI
import Combine

/// Observable object that tracks app/window occlusion state.
/// When occluded (hidden, minimized, or fully covered), pauses UI timers and animations.
@MainActor
final class OcclusionObserver: ObservableObject {
    static let shared = OcclusionObserver()

    @Published private(set) var isOccluded = false
    @Published private(set) var isBackgrounded = false

    var shouldPauseAnimations: Bool { isOccluded || isBackgrounded }

    private var cancellables = Set<AnyCancellable>()
    private var windowObservation: NSKeyValueObservation?

    private init() {
        setupNotifications()
        // Initial state
        updateOcclusionState()
    }

    private func setupNotifications() {
        let nc = NotificationCenter.default

        // App lifecycle
        nc.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.updateBackgrounded(true) }
            .store(in: &cancellables)

        nc.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.updateBackgrounded(false) }
            .store(in: &cancellables)

        // Window occlusion (macOS 12+)
        nc.publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .sink { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                self?.updateOcclusionState(window: window)
            }
            .store(in: &cancellables)

        // Window minimize/restore
        nc.publisher(for: NSWindow.didMiniaturizeNotification)
            .sink { [weak self] _ in self?.updateOcclusionState() }
            .store(in: &cancellables)

        nc.publisher(for: NSWindow.didDeminiaturizeNotification)
            .sink { [weak self] _ in self?.updateOcclusionState() }
            .store(in: &cancellables)
    }

    private func updateBackgrounded(_ backgrounded: Bool) {
        Task { @MainActor in
            self.isBackgrounded = backgrounded
            self.updateOcclusionState()
        }
    }

    private func updateOcclusionState(window: NSWindow? = nil) {
        Task { @MainActor in
            let windows = NSApp.windows.filter { $0.isVisible && !$0.isMiniaturized }
            let targetWindow = window ?? windows.first(where: { $0.isKeyWindow }) ?? windows.first
            let occluded = targetWindow?.occlusionState.contains(.visible) == false
            self.isOccluded = occluded || self.isBackgrounded
        }
    }
}

/// View modifier to pause a TimelineView when occluded
struct PauseWhenOccluded: ViewModifier {
    @StateObject private var observer = OcclusionObserver.shared

    func body(content: Content) -> some View {
        if observer.shouldPauseAnimations {
            content.id("occluded") // Force view recreation when occlusion changes
        } else {
            content.id("visible")
        }
    }
}

extension View {
    func pauseWhenOccluded() -> some View {
        modifier(PauseWhenOccluded())
    }
}