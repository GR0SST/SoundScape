import Foundation

/// Watches hardware callbacks, not signal volume: a silent microphone is healthy.
/// Each hardware input owns one instance so another source cannot hide a stall.
final class AudioCallbackWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var lastCallback: TimeInterval?

    func arm(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        lastCallback = now
        lock.unlock()
    }

    func recordCallback(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        arm(now: now)
    }

    func isStalled(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastCallback else { return false }
        return now - lastCallback > 5
    }
}
