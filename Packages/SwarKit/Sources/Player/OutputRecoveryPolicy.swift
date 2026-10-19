import Foundation

/// Limits driver reopen attempts, including a driver that briefly recovers then fails again.
struct OutputRecoveryPolicy {
    private(set) var attempts = 0
    private var failures = 0
    private var windowStart = -Double.infinity
    private var nextAttempt = -Double.infinity
    var exhausted: Bool { attempts >= 5 }

    mutating func allowsAttempt(at time: Double) -> Bool {
        if time - windowStart >= 60 { self = Self(); windowStart = time }
        return !exhausted && time >= nextAttempt
    }
    mutating func attempted() { attempts += 1 }
    mutating func succeeded() { failures = 0; nextAttempt = -Double.infinity }
    mutating func failed(at time: Double) {
        failures += 1
        nextAttempt = time + min(8, pow(2, Double(failures - 1)))
    }
}
