import Foundation

// Owner: core agent. Output and input timestamps for the activity state machine (SPEC "Activity and attention").

/// Written from the pty IO thread (output) and the main thread (input), read by the session's main-thread timer.
final class ActivityTracker: @unchecked Sendable {
    /// Output this soon after user input is echo.
    static let echoWindow: TimeInterval = 0.25
    /// Quiet this long ends a streak, and output this recent counts as live.
    static let quietGap: TimeInterval = 1.5
    /// A streak must last this long before the session counts as busy.
    static let minimumBusyStreak: TimeInterval = 0.5

    struct Reading: Equatable {
        /// Counted output is under `quietGap` old and its streak is at least `minimumBusyStreak` long.
        var busy: Bool
        /// Length of the current or last streak.
        var streakLength: TimeInterval
        /// Counted output arrived since the previous reading.
        var countedOutput: Bool
    }

    private let lock = NSLock()
    private var lastInput = -TimeInterval.infinity
    private var lastOutput = -TimeInterval.infinity
    private var streakStart = -TimeInterval.infinity
    private var countedSinceRead = false

    /// Monotonic seconds. Does not advance while the Mac sleeps, which is fine for these short windows.
    static func now() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    func noteInput(at time: TimeInterval = ActivityTracker.now()) {
        lock.lock()
        lastInput = max(lastInput, time)
        lock.unlock()
    }

    func noteOutput(at time: TimeInterval = ActivityTracker.now()) {
        lock.lock()
        defer { lock.unlock() }
        guard time - lastInput >= Self.echoWindow else { return }
        if time - lastOutput >= Self.quietGap {
            streakStart = time
        }
        lastOutput = time
        countedSinceRead = true
    }

    /// Reads the state and resets `countedOutput`.
    func read(at time: TimeInterval = ActivityTracker.now()) -> Reading {
        lock.lock()
        defer { lock.unlock() }
        let counted = countedSinceRead
        countedSinceRead = false
        guard lastOutput.isFinite else {
            return Reading(busy: false, streakLength: 0, countedOutput: counted)
        }
        let streak = lastOutput - streakStart
        let busy = time - lastOutput < Self.quietGap && streak >= Self.minimumBusyStreak
        return Reading(busy: busy, streakLength: streak, countedOutput: counted)
    }
}
