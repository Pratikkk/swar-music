import Foundation
import os

struct OutputDeviceStatus: Sendable {
    var output: OutputDescription?
    var error: String?
}

/// HAL reads are isolated from the PCM producer. Only the small value cache is
/// locked; neither a driver query nor a queue wait runs under that lock.
final class OutputDeviceMonitor: @unchecked Sendable {
    private struct State {
        var status: OutputDeviceStatus
        var active = false
        var generation: UInt64 = 0
    }
    private let cache: OSAllocatedUnfairLock<State>
    private let queue: DispatchQueue
    private let timer: DispatchSourceTimer
    private let read: @Sendable () throws -> OutputDescription

    init(initial: OutputDescription?, queue: DispatchQueue = DispatchQueue(label: "catto.swar.device-monitor", qos: .utility),
         read: @escaping @Sendable () throws -> OutputDescription) {
        cache = OSAllocatedUnfairLock(initialState: State(status: OutputDeviceStatus(output: initial)))
        self.queue = queue
        self.read = read
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
    }

    deinit { timer.cancel() }

    var status: OutputDeviceStatus { cache.withLock { $0.status } }

    func reset(output: OutputDescription?) {
        cache.withLock { $0.generation &+= 1; $0.status = OutputDeviceStatus(output: output) }
    }

    func setActive(_ active: Bool) {
        let changed = cache.withLock {
            guard $0.active != active else { return false }
            $0.active = active; $0.generation &+= 1
            return true
        }
        guard changed else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if self.cache.withLock({ $0.active }) {
                self.timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(50))
            } else { self.timer.schedule(deadline: .distantFuture) }
        }
    }

    private func refresh() {
        guard let generation = cache.withLock({ $0.active ? $0.generation : nil }) else { return }
        let result: OutputDeviceStatus
        do { result = OutputDeviceStatus(output: try read()) }
        catch { result = OutputDeviceStatus(error: error.localizedDescription) }
        cache.withLock {
            guard $0.active, $0.generation == generation else { return }
            $0.status = result
        }
    }
}
