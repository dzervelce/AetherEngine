import Foundation

/// Single-slot cross-thread seek mailbox: the main actor posts the LATEST
/// scrub target, a detached reader loop drains it. Rapid scrubs coalesce —
/// only the newest target matters for re-aiming the subtitle side demuxer.
final class SeekRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var target: Double?

    func request(_ seconds: Double) {
        lock.lock()
        target = seconds
        lock.unlock()
    }

    /// Atomically read-and-clear the pending target.
    func take() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        let t = target
        target = nil
        return t
    }

    /// Non-consuming peek, used to break out of wait loops promptly.
    var hasRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return target != nil
    }
}
