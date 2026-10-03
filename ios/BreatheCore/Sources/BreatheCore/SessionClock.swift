/// Session time on a monotonic host clock, with the pauses taken out.
///
/// breathe.py's start / pause_at / offset trio as a value: elapsed time is
/// `(pausedAt ?? now) - start - pausedTotal`, so it freezes while paused and
/// carries on from the same instant afterwards. The screen and the audio
/// thread each hold a copy and evaluate it against the same clock, which is
/// what keeps them in step.
public struct SessionClock: Sendable, Equatable {
    /// Host time at which elapsed time is zero, i.e. the first inhale tick.
    public let start: Double
    /// Host time the session was paused at, while it is paused.
    public private(set) var pausedAt: Double?
    /// Seconds spent paused before the current pause, if any.
    public private(set) var pausedTotal: Double = 0

    public init(start: Double) {
        precondition(start.isFinite, "start must be finite")
        self.start = start
    }

    public var isPaused: Bool { pausedAt != nil }

    public func elapsed(at now: Double) -> Double {
        (pausedAt ?? now) - start - pausedTotal
    }

    /// Freezes elapsed time at `now`. Pausing a paused clock changes nothing.
    public mutating func pause(at now: Double) {
        guard pausedAt == nil else { return }
        pausedAt = now
    }

    /// Carries on from where `pause(at:)` froze it. Resuming a running clock
    /// changes nothing.
    public mutating func resume(at now: Double) {
        guard let pausedAt else { return }
        pausedTotal += now - pausedAt
        self.pausedAt = nil
    }
}
