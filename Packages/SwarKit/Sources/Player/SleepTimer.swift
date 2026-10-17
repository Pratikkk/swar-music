import Foundation
import Observation

/// A session-only timer with one suspended task and no periodic polling.
@MainActor @Observable
public final class SleepTimer {
    public private(set) var deadline: Date?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private let wait: @Sendable (Duration) async throws -> Void
    @ObservationIgnored var onExpire: (@MainActor @Sendable () async -> Void)?

    public convenience init() {
        self.init(wait: { try await Task.sleep(for: $0) })
    }

    init(wait: @escaping @Sendable (Duration) async throws -> Void) {
        self.wait = wait
    }

    deinit { task?.cancel() }

    public func start(minutes: Int) {
        guard (1...720).contains(minutes) else { return }
        cancel()
        let token = revision
        deadline = Date().addingTimeInterval(Double(minutes * 60))
        let wait = wait
        task = Task { [weak self] in
            do { try await wait(.seconds(minutes * 60)) } catch { return }
            guard let self, !Task.isCancelled, self.revision == token else { return }
            await self.onExpire?()
            guard !Task.isCancelled, self.revision == token else { return }
            self.deadline = nil
            self.task = nil
        }
    }

    public func cancel() {
        revision = UUID()
        task?.cancel()
        task = nil
        deadline = nil
    }
}
