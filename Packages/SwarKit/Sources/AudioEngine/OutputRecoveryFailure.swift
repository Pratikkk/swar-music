import Foundation

/// Distinguishes recoverable output/driver failures from corrupt audio or decoder errors.
struct OutputRecoveryFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
