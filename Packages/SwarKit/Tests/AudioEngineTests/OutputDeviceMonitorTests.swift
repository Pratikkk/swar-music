import Decoding
import Foundation
import Testing
import os
@testable import AudioEngine

struct OutputDeviceMonitorTests {
    private func output(rate: Double) -> OutputDescription {
        OutputDescription(id: 42, name: "Test Output", sampleRate: rate, bitDepth: 24,
            isFloat: false, channels: 2, transport: .local)
    }

    @Test func cacheReadsDoNotWaitForBlockedDeviceProbe() {
        let queue = DispatchQueue(label: "test.device-monitor.blocked")
        let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let old = output(rate: 44_100), fresh = output(rate: 96_000)
        let firstRead = OSAllocatedUnfairLock(initialState: true)
        let monitor = OutputDeviceMonitor(initial: old, queue: queue) {
            if firstRead.withLock({ let first = $0; $0 = false; return first }) {
                started.signal(); finish.wait()
            }
            return fresh
        }
        monitor.setActive(true)
        #expect(started.wait(timeout: .now() + 2) == .success)
        let status = OSAllocatedUnfairLock<OutputDeviceStatus?>(initialState: nil)
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let value = monitor.status
            status.withLock { $0 = value }
            read.signal()
        }
        #expect(read.wait(timeout: .now() + 1) == .success)
        finish.signal()
        queue.sync { }
        #expect(status.withLock { $0?.output } == old)
        #expect(monitor.status.output == fresh)
        monitor.setActive(false)
    }

    @Test func stoppedProbeCannotOverwriteNewPlaybackStatus() {
        let queue = DispatchQueue(label: "test.device-monitor.stale")
        let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let old = output(rate: 44_100), fresh = output(rate: 96_000)
        let monitor = OutputDeviceMonitor(initial: old, queue: queue) {
            started.signal(); finish.wait()
            throw AudioFailure("Old device disconnected")
        }
        monitor.setActive(true)
        #expect(started.wait(timeout: .now() + 2) == .success)
        monitor.setActive(false)
        monitor.reset(output: fresh)
        finish.signal()
        queue.sync { }
        #expect(monitor.status.output == fresh)
        #expect(monitor.status.error == nil)
    }

    @Test func inactiveSnapshotsDoNotProbeAndFailuresClearOutput() {
        let queue = DispatchQueue(label: "test.device-monitor.failure")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let read = DispatchSemaphore(value: 0)
        let initial = output(rate: 44_100)
        let monitor = OutputDeviceMonitor(initial: initial, queue: queue) {
            calls.withLock { $0 += 1 }
            read.signal()
            throw AudioFailure("The output sample rate changed outside Swar.")
        }
        for _ in 0..<100 { #expect(monitor.status.output == initial) }
        #expect(calls.withLock { $0 } == 0)
        monitor.setActive(true)
        #expect(read.wait(timeout: .now() + 2) == .success)
        queue.sync { }
        #expect(monitor.status.output == nil)
        #expect(monitor.status.error == "The output sample rate changed outside Swar.")
        monitor.setActive(false)
        monitor.reset(output: initial)
        #expect(monitor.status.error == nil)
        #expect(monitor.status.output == initial)
    }
}
