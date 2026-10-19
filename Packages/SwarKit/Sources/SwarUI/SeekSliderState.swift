import Foundation

/// The pointer remains authoritative until the final coalesced seek has settled.
struct SeekSliderState {
    struct Request: Equatable, Sendable {
        let id: UInt64
        let url: URL
        let position: Double
    }
    private(set) var value = 0.0
    private(set) var dragging = false
    private var url: URL?
    private var duration = 0.0
    private var revision: UInt64 = 0
    private var pending: Request?
    private var submitted = false

    func displayedPosition(_ actual: Double) -> Double {
        bounded(dragging || pending != nil ? value : actual)
    }

    mutating func synchronize(position: Double, duration: Double, url: URL?) {
        if self.url != url || !duration.isFinite || duration <= 0 {
            cancel(position: position, duration: duration, url: url)
        } else {
            self.duration = duration
            if !dragging && pending == nil { value = bounded(position) }
        }
    }

    mutating func begin() {
        dragging = true
        pending = nil; submitted = false
    }

    mutating func change(to position: Double) {
        guard position.isFinite else { return }
        value = bounded(position)
    }

    mutating func end() -> Request? {
        guard dragging else { return nil }
        dragging = false
        return request()
    }

    mutating func request() -> Request? {
        guard let url, duration > 0 else { return nil }
        revision &+= 1
        let request = Request(id: revision, url: url, position: value)
        pending = request; submitted = false
        return request
    }

    mutating func submit(_ request: Request) -> Bool {
        guard pending == request, request.url == url else { return false }
        submitted = true
        return true
    }

    mutating func finish(_ request: Request, position: Double, seeking: Bool) {
        guard pending == request else { return }
        settle(position: position, seeking: seeking)
    }

    mutating func settle(position: Double, seeking: Bool) {
        guard !dragging, pending != nil, submitted, !seeking else { return }
        pending = nil; submitted = false
        value = bounded(position)
    }

    mutating func cancel(position: Double, duration: Double, url: URL?) {
        self.url = url
        self.duration = duration.isFinite ? max(0, duration) : 0
        dragging = false; pending = nil; submitted = false
        value = bounded(position)
    }

    private func bounded(_ position: Double) -> Double {
        position.isFinite ? max(0, min(position, duration)) : 0
    }
}
