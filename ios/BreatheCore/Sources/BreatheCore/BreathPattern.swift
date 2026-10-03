/// One breath as breathe.py paces it: inhale, a still hold at the top, exhale,
/// and the same still hold at the bottom.
///
/// The holds are a pause at each turnaround; ticks only fire at the start of
/// the inhale and at the start of the exhale.
public struct BreathPattern: Sendable, Hashable {
    /// Seconds breathing in.
    public let inhale: Double
    /// Seconds breathing out.
    public let exhale: Double
    /// Seconds held still at each turnaround, so twice per cycle.
    public let hold: Double

    /// `nil` unless inhale and exhale are positive and hold is zero or more,
    /// all of them finite: anything else is not a breath that can be paced.
    public init?(inhale: Double, exhale: Double, hold: Double = 0) {
        guard inhale.isFinite, exhale.isFinite, hold.isFinite,
              inhale > 0, exhale > 0, hold >= 0
        else { return nil }
        self.init(checkedInhale: inhale, exhale: exhale, hold: hold)
    }

    private init(checkedInhale inhale: Double, exhale: Double, hold: Double) {
        self.inhale = inhale
        self.exhale = exhale
        self.hold = hold
    }

    /// breathe.py's defaults: 4 s in, 6 s out, half a second at each turnaround.
    public static let standard = BreathPattern(checkedInhale: 4, exhale: 6, hold: 0.5)

    /// Length of one full cycle.
    public var period: Double { inhale + exhale + hold * 2 }

    public var breathsPerMinute: Double { 60 / period }

    /// Where the exhale tick falls within a cycle.
    var exhaleOffset: Double { inhale + hold }
}

/// The four stretches of a cycle, in order.
public enum BreathPhase: Sendable, Hashable, CaseIterable {
    case inhale
    case holdIn
    case exhale
    case holdOut

    /// The still pauses at the turnarounds.
    public var isHold: Bool { self == .holdIn || self == .holdOut }

    /// The top half of the cycle: the inhale and the hold that follows it.
    public var isInhaleHalf: Bool { self == .inhale || self == .holdIn }
}

/// Where the breath is at one instant.
public struct PhaseState: Sendable, Equatable {
    /// Index of the current cycle; negative before the session starts.
    public let cycle: Int
    public let phase: BreathPhase
    /// 0 at the start of the phase, approaching 1 at its end.
    public let progress: Double
    /// Seconds until the phase ends.
    public let remaining: Double
}

extension BreathPattern {
    /// The single source of truth for where we are in the breath.
    ///
    /// Stateless on purpose (breathe.py's first invariant, ONE CLOCK): the
    /// screen and the audio thread both ask it about the same clock, so they
    /// cannot drift apart however long either of them stalls. Never pace
    /// anything with a running total of phase lengths instead: that drifts
    /// for good after a stall and then fires catch-up bursts.
    public func phase(at elapsed: Double) -> PhaseState {
        precondition(elapsed.isFinite, "elapsed time must be finite")
        let cycle = Int((elapsed / period).rounded(.down))
        var t = max(0, elapsed - Double(cycle) * period)
        if t < inhale {
            return state(cycle, .inhale, t, of: inhale)
        }
        t -= inhale
        if t < hold {
            return state(cycle, .holdIn, t, of: hold)
        }
        t -= hold
        if t < exhale {
            return state(cycle, .exhale, t, of: exhale)
        }
        return state(cycle, .holdOut, t - exhale, of: hold)
    }

    private func state(_ cycle: Int, _ phase: BreathPhase, _ t: Double, of length: Double) -> PhaseState {
        PhaseState(
            cycle: cycle,
            phase: phase,
            progress: length > 0 ? min(1, t / length) : 1,
            remaining: max(0, length - t)
        )
    }

    /// The number in the tab: seconds elapsed inside the phase, read like a
    /// stopwatch.
    ///
    /// It starts at 0 and turns over on each whole second, so the first second
    /// is the one you watch tick away rather than one you have already missed.
    /// A hold shows the phase length, the number the count was climbing
    /// toward: 0, 1, 2, 3 through a 4 s inhale, then 4 while it is held.
    public func count(_ phase: BreathPhase, remaining: Double) -> Int {
        let length = phase.isInhaleHalf ? inhale : exhale
        let top = Int(length.rounded(.up))
        if phase.isHold {
            return top
        }
        return max(0, min(top, Int(length - remaining)))
    }

    /// Calls `body` with every tick onset in `from ..< to`, in order: the
    /// start of each inhale and of each exhale, counting from the first inhale
    /// at 0 and stopping short of `limit` when there is one.
    ///
    /// Onsets come from the cycle index, never from an accumulator, so any way
    /// of cutting a stretch of time into windows yields the same onsets.
    /// Allocation-free, so the audio thread can call it.
    public func forEachOnset(
        from: Double,
        to: Double,
        before limit: Double? = nil,
        _ body: (Double, TickKind) -> Void
    ) {
        precondition(from.isFinite && to.isFinite, "onset window must be finite")
        let end = min(to, limit ?? to)
        guard end > from, end > 0 else { return }
        let first = from > 0 ? Int((from / period).rounded(.down)) : 0
        let last = Int((end / period).rounded(.down))
        guard first <= last else { return }
        for cycle in first...last {
            let inhaleOnset = Double(cycle) * period
            if inhaleOnset >= from, inhaleOnset < end {
                body(inhaleOnset, .inhale)
            }
            let exhaleOnset = inhaleOnset + exhaleOffset
            if exhaleOnset >= from, exhaleOnset < end {
                body(exhaleOnset, .exhale)
            }
        }
    }
}
