/// How full the lungs look. Easing is visual only: ticks and the count stay
/// exactly on the clock (breathe.py's sixth invariant).
public enum Breath {
    /// Symmetric: slow at both turnarounds, quick through the middle.
    ///
    /// A little linear keeps it from ever looking frozen; smootherstep does the
    /// long, log-like arrival at each end.
    public static func ease(_ progress: Double) -> Double {
        let p = min(1, max(0, progress))
        let smoothstep = p * p * (3 - 2 * p)
        let smootherstep = p * p * p * (p * (p * 6 - 15) + 10)
        return 0.08 * p + 0.30 * smoothstep + 0.62 * smootherstep
    }

    /// 0 = empty lungs, 1 = full.
    public static func fullness(_ phase: BreathPhase, progress: Double) -> Double {
        switch phase {
        case .inhale: ease(progress)
        case .holdIn: 1
        case .exhale: 1 - ease(progress)
        case .holdOut: 0
        }
    }
}

/// Everything one frame of the pacer shows, read off the clock.
public struct PacerReading: Sendable, Equatable {
    /// Session time in seconds; negative during the lead-in before the first tick.
    public let elapsed: Double
    public let state: PhaseState
    /// 0 = empty lungs, 1 = full.
    public let fullness: Double
    /// The number in the tab.
    public let count: Int
    /// -1 until the first tick, then the index of the latest one: even on an
    /// inhale, odd on an exhale. It changes exactly when a tick fires, so it is
    /// the trigger for anything that should land on the tick.
    public let beat: Int
}

extension BreathPattern {
    public func reading(at elapsed: Double) -> PacerReading {
        guard elapsed >= 0 else {
            // The lead-in that gives the audio time to reach the speaker before
            // the first tick is due: lungs empty, nothing counted yet.
            return PacerReading(elapsed: elapsed, state: phase(at: 0), fullness: 0, count: 0, beat: -1)
        }
        let state = phase(at: elapsed)
        return PacerReading(
            elapsed: elapsed,
            state: state,
            fullness: Breath.fullness(state.phase, progress: state.progress),
            count: count(state.phase, remaining: state.remaining),
            beat: state.cycle * 2 + (state.phase.isInhaleHalf ? 0 : 1)
        )
    }

    /// Full cycles completed after `elapsed` seconds: the "54 cycles" in
    /// breathe.py's closing line.
    public func cyclesCompleted(after elapsed: Double) -> Int {
        elapsed > 0 ? Int((elapsed / period).rounded(.down)) : 0
    }
}
