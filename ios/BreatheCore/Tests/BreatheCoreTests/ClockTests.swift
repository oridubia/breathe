@testable import BreatheCore
import Testing

/// 4 in / 6 out / 0.5 hold: an 11 s period, inhale ticks at 0, 11, 22...,
/// exhale ticks at 4.5, 15.5, 26.5...
private let standard = BreathPattern.standard

@Suite("The clock")
struct ClockTests {
    @Test("4 in / 6 out / 0.5 hold walks in, hold, out, hold", arguments: [
        (0.0, BreathPhase.inhale), (3.9, .inhale),
        (4.2, .holdIn),
        (4.6, .exhale), (10.4, .exhale),
        (10.6, .holdOut), (10.9, .holdOut),
    ])
    func walksThePhases(elapsed: Double, expected: BreathPhase) {
        #expect(standard.phase(at: elapsed).phase == expected)
    }

    @Test func cycleIndexAdvancesWithThePeriod() {
        #expect(standard.period == 11)
        #expect(standard.phase(at: 0).cycle == 0)
        #expect(standard.phase(at: 11 - 0.01).cycle == 0)
        #expect(standard.phase(at: 11 + 0.01).cycle == 1)
        #expect(standard.phase(at: 11 * 7 + 0.01).cycle == 7)
    }

    @Test(arguments: [0.0, 1.0, 3.99, 5.0, 9.0])
    func progressAndTimeLeftAgree(elapsed: Double) {
        let state = standard.phase(at: elapsed)
        let length = state.phase == .inhale ? 4.0 : 6.0
        #expect(abs(state.progress - (1 - state.remaining / length)) < 1e-12)
        #expect((0...1).contains(state.progress))
        #expect(state.remaining > 0)
    }

    @Test func withoutAHoldThereIsOnlyInAndOut() throws {
        let pattern = try #require(BreathPattern(inhale: 4, exhale: 6, hold: 0))
        for step in 0..<200 {
            let phase = pattern.phase(at: Double(step) * 0.05).phase
            #expect(phase == .inhale || phase == .exhale)
        }
    }

    @Test("Stateless, so a stall cannot drift: any sampling order agrees")
    func statelessSoAStallCannotDrift() {
        let times = (0..<300).map { Double($0) * 0.1 }
        let forwards = times.map(standard.phase(at:))
        let backwards = times.reversed().map(standard.phase(at:))
        #expect(forwards == Array(backwards.reversed()))
    }

    @Test(arguments: [
        (0.0, 6.0, 0.5), (4.0, 0.0, 0.5), (-1.0, 6.0, 0.5), (4.0, 6.0, -0.1),
        (.nan, 6.0, 0.5), (4.0, .infinity, 0.5), (4.0, 6.0, .nan),
    ])
    func patternsThatCannotBePacedAreRejected(inhale: Double, exhale: Double, hold: Double) {
        #expect(BreathPattern(inhale: inhale, exhale: exhale, hold: hold) == nil)
    }

    @Test func breathsPerMinuteFollowThePeriod() {
        #expect(abs(standard.breathsPerMinute - 60.0 / 11.0) < 1e-12)
    }
}

@Suite("The count")
struct CountTests {
    @Test func startsAtZeroAndTurnsOverEachWholeSecond() {
        let seen = [0.0, 0.9, 1.0, 1.1, 2.5, 3.99].map { standard.count(.inhale, remaining: 4 - $0) }
        #expect(seen == [0, 0, 1, 1, 2, 3])
    }

    @Test("The first second is watched ticking away, not skipped")
    func showsZeroForTheWholeFirstSecond() {
        for t in [0.0, 0.25, 0.5, 0.75, 0.999] {
            #expect(standard.count(.inhale, remaining: 4 - t) == 0)
        }
        #expect(standard.count(.exhale, remaining: 6 - 0.999) == 0)
    }

    @Test func neverExceedsThePhaseLength() {
        for step in 0..<600 {
            #expect((0...6).contains(standard.count(.exhale, remaining: 6 - Double(step) / 100)))
        }
    }

    @Test func aHoldKeepsTheLastNumberOfThePhaseItFollows() {
        #expect(standard.count(.holdIn, remaining: 0.2) == 4)
        #expect(standard.count(.holdOut, remaining: 0.2) == 6)
    }

    @Test func topsOutAtTheCeilingForFractionalPhases() throws {
        let pattern = try #require(BreathPattern(inhale: 5.5, exhale: 6, hold: 0.5))
        #expect(pattern.count(.holdIn, remaining: 0.1) == 6)
        #expect(pattern.count(.inhale, remaining: 0.01) == 5)
    }

    @Test func walksTheWholeCycleWithoutSkippingANumber() {
        var seen: [Int] = []
        for step in 0..<460 {
            let reading = standard.reading(at: Double(step) * 0.025)
            if seen.last != reading.count {
                seen.append(reading.count)
            }
        }
        #expect(seen == [0, 1, 2, 3, 4, 0, 1, 2, 3, 4, 5, 6, 0])
    }
}

@Suite("A frame's reading")
struct ReadingTests {
    @Test func theLeadInShowsEmptyLungsAndNoBeat() {
        let reading = standard.reading(at: -0.2)
        #expect(reading.fullness == 0)
        #expect(reading.count == 0)
        #expect(reading.beat == -1)
    }

    @Test("The beat changes exactly where a tick fires, and nowhere else")
    func beatChangesExactlyOnTheOnsets() {
        var onsets: [Double] = []
        standard.forEachOnset(from: 0, to: 40) { onset, _ in onsets.append(onset) }
        var changes: [Double] = []
        var previous = standard.reading(at: -0.001).beat
        for step in 0...40_000 {
            let t = Double(step) * 0.001
            let beat = standard.reading(at: t).beat
            if beat != previous {
                #expect(beat == previous + 1)
                changes.append(t)
                previous = beat
            }
        }
        #expect(changes.count == onsets.count)
        for (change, onset) in zip(changes, onsets) {
            #expect(abs(change - onset) < 0.0015)
        }
    }

    @Test func cyclesCompletedCountsWholeCycles() {
        #expect(standard.cyclesCompleted(after: -1) == 0)
        #expect(standard.cyclesCompleted(after: 10.9) == 0)
        #expect(standard.cyclesCompleted(after: 11.01) == 1)
        #expect(standard.cyclesCompleted(after: 600) == 54)
    }

    @Test("A session that is a whole number of cycles long does not count the inhale due at its end")
    func cyclesCompletedLeavesOutAnInhaleDueExactlyAtTheEnd() throws {
        // breathe.py's loop stops before it would see that inhale, and the
        // mixer plays no tick at the limit: ten minutes of 5 in / 5 out is 59.
        let pattern = try #require(BreathPattern(inhale: 5, exhale: 5, hold: 0))
        #expect(pattern.cyclesCompleted(after: 600) == 59)
        #expect(pattern.cyclesCompleted(after: 600.01) == 60)
        #expect(pattern.cyclesCompleted(after: 10) == 0)
        #expect(pattern.cyclesCompleted(after: 0.01) == 0)
    }
}

@Suite("The session clock")
struct SessionClockTests {
    @Test func runsFromItsStart() {
        let clock = SessionClock(start: 100)
        #expect(clock.elapsed(at: 99.5) == -0.5)
        #expect(clock.elapsed(at: 112.25) == 12.25)
    }

    @Test func pausingFreezesItAndResumingCarriesOnFromTheSameInstant() {
        var clock = SessionClock(start: 100)
        clock.pause(at: 105)
        #expect(clock.isPaused)
        #expect(clock.elapsed(at: 105) == 5)
        #expect(clock.elapsed(at: 150) == 5)
        clock.resume(at: 160)
        #expect(!clock.isPaused)
        #expect(clock.elapsed(at: 160) == 5)
        #expect(clock.elapsed(at: 161) == 6)
    }

    @Test func pausesAccumulateAndRepeatsChangeNothing() {
        var clock = SessionClock(start: 0)
        clock.pause(at: 10)
        clock.pause(at: 12)
        clock.resume(at: 20)
        clock.resume(at: 25)
        clock.pause(at: 30)
        clock.resume(at: 35)
        #expect(clock.pausedTotal == 15)
        #expect(clock.elapsed(at: 40) == 25)
    }
}

@Suite("Tick onsets")
struct OnsetTests {
    private func onsets(_ pattern: BreathPattern, from: Double, to: Double, before limit: Double? = nil) -> [Onset] {
        var found: [Onset] = []
        pattern.forEachOnset(from: from, to: to, before: limit) { found.append(Onset(time: $0, tick: $1)) }
        return found
    }

    @Test func standardPatternTicksOnEachInhaleAndExhale() {
        #expect(onsets(standard, from: 0, to: 22) == [
            Onset(time: 0, tick: .inhale), Onset(time: 4.5, tick: .exhale),
            Onset(time: 11, tick: .inhale), Onset(time: 15.5, tick: .exhale),
        ])
    }

    @Test func theFirstInhaleIsIncludedFromBeforeTheStartButNotBeforeItIsDue() {
        #expect(onsets(standard, from: -1, to: 0.001).map(\.time) == [0])
        #expect(onsets(standard, from: -1, to: 0).isEmpty)
    }

    @Test func noTickAtOrAfterTheLimit() {
        #expect(onsets(standard, from: 0, to: 30, before: 15.5).map(\.time) == [0, 4.5, 11])
    }

    @Test("Any way of cutting time into windows yields the same onsets, once each")
    func windowsPartitionTheOnsets() throws {
        let pattern = try #require(BreathPattern(inhale: 3.7, exhale: 5.3, hold: 0.25))
        let whole = onsets(pattern, from: 0, to: 120)
        var generator = SplitMix(seed: 7)
        for _ in 0..<20 {
            var pieces: [Onset] = []
            var from = -0.5
            while from < 120 {
                let to = min(120, from + generator.next(in: 0.001...3))
                pieces += onsets(pattern, from: from, to: to)
                from = to
            }
            #expect(pieces == whole)
        }
    }

    @Test("Each onset is where the clock says that phase begins")
    func onsetsAgreeWithTheClock() {
        standard.forEachOnset(from: 0, to: 60) { onset, tick in
            let after = standard.phase(at: onset + 1e-9)
            #expect(after.phase == (tick == .inhale ? .inhale : .exhale))
            #expect(after.progress < 1e-6)
            #expect(standard.phase(at: onset - 1e-6).phase != after.phase)
        }
    }
}

struct Onset: Equatable {
    let time: Double
    let tick: TickKind
}

/// A small seeded generator, so property-style tests are reproducible.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        let unit = Double(z >> 11) * 0x1.0p-53
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

@Suite("The readout")
struct ReadoutTests {
    @Test(arguments: [
        (0.0, "0:00"), (65.0, "1:05"), (600.0, "10:00"),
        (59.9, "0:59"), (4500.0, "75:00"), (-3.0, "0:00"),
    ])
    func clockFormatsAsMinutesAndSeconds(seconds: Double, expected: String) {
        #expect(Readout.clock(seconds) == expected)
    }
}
