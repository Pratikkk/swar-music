import Foundation
import Testing
import os
@testable import AudioEngine

struct EngineLifetimeTests {
    @Test func deinitWaitsForPendingAudioQueueWork() {
        let queue = DispatchQueue(label: "test.swar.lifetime.pending")
        let owner = OSAllocatedUnfairLock(initialState: Optional(AudioPlaybackEngine(queue: queue)))
        let entered = DispatchSemaphore(value: 0)
        let unblock = DispatchSemaphore(value: 0)
        let releasing = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        queue.async { entered.signal(); unblock.wait() }
        #expect(entered.wait(timeout: .now() + 2) == .success)
        // A global dispatch worker can be starved by the deliberately blocked
        // queues in other tests on small CI runners. Give the releasing owner
        // its own thread so that we test teardown, not helper scheduling.
        Thread.detachNewThread {
            releasing.signal()
            owner.withLock { $0 = nil }
            released.signal()
        }
        #expect(releasing.wait(timeout: .now() + 2) == .success)
        // A deferred close returns here while the worker is still blocked.
        #expect(released.wait(timeout: .now() + 0.1) == .timedOut)
        unblock.signal()
        #expect(released.wait(timeout: .now() + 2) == .success)
    }

    @Test func deinitAndRepeatedShutdownOnAudioQueueDoNotDeadlock() {
        let queue = DispatchQueue(label: "test.swar.lifetime.reentrant")
        let owner = OSAllocatedUnfairLock(initialState: Optional(AudioPlaybackEngine(queue: queue)))
        let released = DispatchSemaphore(value: 0)
        queue.async {
            owner.withLock {
                $0?.shutdown()
                $0?.shutdown()
                $0 = nil
            }
            released.signal()
        }
        #expect(released.wait(timeout: .now() + 2) == .success)
    }

    @Test func suspendingAndRecoveringWithoutASourceDoesNotStartAudio() async throws {
        let engine = AudioPlaybackEngine()
        let suspended = await engine.suspendOutput()
        let recovered = try await engine.recoverOutput(nil, resume: true)
        #expect(suspended.source == nil && !suspended.isPlaying)
        #expect(recovered.source == nil && !recovered.isPlaying && recovered.duration == 0)
        engine.shutdown()
    }

    @Test func explicitShutdownRemainsIdempotentOffQueue() async {
        let engine = AudioPlaybackEngine()
        engine.shutdown()
        engine.shutdown()
        let snapshot = await engine.snapshot()
        #expect(snapshot.source == nil)
        #expect(snapshot.output == nil)
        #expect(!snapshot.isPlaying)
    }
}
