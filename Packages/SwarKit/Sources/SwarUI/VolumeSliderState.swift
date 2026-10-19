/// Local presentation stays authoritative through a drag and its asynchronous
/// write. Hardware updates take over only when the latest write has settled.
struct VolumeSliderState {
    struct Request: Equatable, Sendable {
        let id: UInt64
        let deviceID: UInt32
        let level: Double
    }
    private(set) var value = 0.0
    private(set) var dragging = false
    private var deviceID: UInt32 = 0
    private var available = false
    private var revision: UInt64 = 0
    private var pending: Request?
    private var submitted = false

    mutating func synchronize(level: Double?, deviceID: UInt32, available: Bool) {
        if self.deviceID != deviceID || !available {
            cancel(level: level, deviceID: deviceID, available: available)
        } else if !dragging && pending == nil {
            value = bounded(level)
        }
        self.available = available
    }

    mutating func begin() {
        guard available else { return }
        // Native controls can update the binding before reporting editing began.
        // Preserve that value and invalidate any not-yet-submitted keyboard write.
        pending = nil; submitted = false; dragging = true
    }

    mutating func change(to level: Double) {
        guard available, level.isFinite else { return }
        value = bounded(level)
    }

    mutating func end() -> Request? {
        guard dragging else { return nil }
        dragging = false
        return request()
    }

    mutating func request() -> Request? {
        guard available else { return nil }
        revision &+= 1
        let request = Request(id: revision, deviceID: deviceID, level: value)
        pending = request; submitted = false
        return request
    }

    mutating func submit(_ request: Request) -> Bool {
        guard available, pending == request else { return false }
        submitted = true
        return true
    }

    mutating func finish(_ request: Request, level: Double?, deviceID: UInt32, available: Bool, writing: Bool) {
        guard pending == request else { return }
        settle(level: level, deviceID: deviceID, available: available, writing: writing)
    }

    mutating func settle(level: Double?, deviceID: UInt32, available: Bool, writing: Bool) {
        guard self.deviceID == deviceID, available else {
            cancel(level: level, deviceID: deviceID, available: available)
            return
        }
        guard !dragging, pending != nil, submitted, !writing else { return }
        pending = nil; submitted = false
        value = bounded(level)
    }

    mutating func cancel(level: Double?, deviceID: UInt32, available: Bool) {
        dragging = false; pending = nil; submitted = false
        self.deviceID = deviceID; self.available = available
        value = bounded(level)
    }

    private func bounded(_ level: Double?) -> Double {
        guard let level, level.isFinite else { return 0 }
        return max(0, min(1, level))
    }
}
