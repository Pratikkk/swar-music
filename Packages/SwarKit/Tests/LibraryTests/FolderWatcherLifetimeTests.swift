import Foundation
import Testing
@testable import Library

struct FolderWatcherLifetimeTests {
    @Test func releasingWatcherWhileCallbackIsBlockedKeepsActionAlive() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = CallbackObservations()
        var watcher: FolderWatcher?
        defer { state.release.signal(); watcher = nil }
        do {
            let lifetime = ActionLifetime(state)
            let candidate: FolderWatcher? = FolderWatcher(url: root) {
                state.enter()
                _ = state.release.wait(timeout: .now() + 6)
                state.finish()
                withExtendedLifetime(lifetime) { }
            }
            watcher = candidate
            try #require(watcher != nil)
        }
        try Data("event".utf8).write(to: root.appendingPathComponent("first.wav"))
        try await wait { state.entered }
        watcher = nil
        #expect(!state.finished, "Watcher teardown must not wait for the client action")
        #expect(!state.released, "The in-flight action must retain its captured state")
        state.release.signal()
        try await wait { state.finished && state.released }
        try Data("late event".utf8).write(to: root.appendingPathComponent("second.wav"))
        try await Task.sleep(for: .milliseconds(1300))
        #expect(state.calls == 1, "Cancelled watchers must not start another action")
    }

    @Test func watcherCanBeReleasedFromItsOwnCallback() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = WatcherOwner()
        defer { owner.clear() }
        let state = CallbackObservations()
        do {
            let lifetime = ActionLifetime(state)
            let candidate: FolderWatcher? = FolderWatcher(url: root) { [weak owner] in
                state.enter()
                owner?.clear()
                state.finish()
                withExtendedLifetime(lifetime) { }
            }
            owner.install(try #require(candidate))
        }
        try Data("event".utf8).write(to: root.appendingPathComponent("first.wav"))
        try await wait { state.finished && state.released }
        #expect(owner.isEmpty)
        #expect(state.calls == 1)
    }

    @Test func watcherReleasesActionCapturesWithoutReceivingAnEvent() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = CallbackObservations()
        var watcher: FolderWatcher?
        do {
            let lifetime = ActionLifetime(state)
            let candidate: FolderWatcher? = FolderWatcher(url: root) { withExtendedLifetime(lifetime) { } }
            watcher = candidate
            try #require(watcher != nil)
        }
        #expect(watcher != nil && !state.released)
        watcher = nil
        #expect(state.released)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func wait(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Timed out waiting for a watcher lifecycle event")
    }
}

private final class CallbackObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var didFinish = false
    private var didRelease = false
    let release = DispatchSemaphore(value: 0)
    var calls: Int { lock.withLock { count } }
    var entered: Bool { calls > 0 }
    var finished: Bool { lock.withLock { didFinish } }
    var released: Bool { lock.withLock { didRelease } }
    func enter() { lock.withLock { count += 1 } }
    func finish() { lock.withLock { didFinish = true } }
    func recordRelease() { lock.withLock { didRelease = true } }
}

private final class ActionLifetime: @unchecked Sendable {
    let state: CallbackObservations
    init(_ state: CallbackObservations) { self.state = state }
    deinit { state.recordRelease() }
}

private final class WatcherOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var watcher: FolderWatcher?
    var isEmpty: Bool { lock.withLock { watcher == nil } }
    func install(_ watcher: FolderWatcher) { lock.withLock { self.watcher = watcher } }
    func clear() {
        let discarded = lock.withLock {
            let discarded = watcher
            watcher = nil
            return discarded
        }
        withExtendedLifetime(discarded) { }
    }
}
