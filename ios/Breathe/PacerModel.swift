import BreatheCore
import Foundation
import Observation
import QuartzCore

/// The session: idle, then running and paused in turn, then idle again.
///
/// It owns the session clock and hands the audio a copy on every change; the
/// screen reads the same clock on every frame. Nothing here runs per frame or
/// per tick, so a slow frame cannot delay a tick and a tick cannot drop a frame.
@MainActor
@Observable
final class PacerModel {
    enum Status: Equatable {
        case idle
        case running
        case paused
    }

    /// A session under way.
    struct Session {
        let id: UInt64
        let pattern: BreathPattern
        var clock: SessionClock
        let limit: Double?
        let haptics: Bool
    }

    /// How the last session went, shown once it is over.
    struct Summary: Equatable {
        let duration: Double
        let cycles: Int
    }

    private(set) var status = Status.idle
    private(set) var session: Session?
    private(set) var summary: Summary?
    /// Why the current session or preview is silent, when it is.
    private(set) var soundIssue: String?

    private let ticks = TickEngine()
    @ObservationIgnored private var timeline = AudioTimeline.silent
    @ObservationIgnored private var sessionCount: UInt64 = 0
    @ObservationIgnored private var soundOn = false
    @ObservationIgnored private var sessionEnd: Task<Void, Never>?
    @ObservationIgnored private var preview: Task<Void, Never>?

    /// Time for the first buffer to reach the listener before the first tick
    /// is due, on top of the output's own latency.
    private static let leadIn = 0.15

    init() {
        ticks.onSoundLost = { [weak self] in self?.pause() }
    }

    func start(_ settings: PacerSettings) {
        guard status == .idle else { return }
        preview?.cancel()
        summary = nil
        soundIssue = nil
        soundOn = false
        var lead = Self.leadIn
        if settings.sound {
            do {
                try ticks.start()
                soundOn = true
                lead += ticks.outputLatency
            } catch {
                // breathe.py carries on with the visual alone; so does this.
                soundIssue = Self.describe(error)
            }
        }
        if !soundOn {
            // A preview under way would have handed the engine back when it
            // ended; cancelled, it no longer will, and nothing else wants it.
            ticks.stopAfterTail()
        }
        sessionCount += 1
        let session = Session(
            id: sessionCount,
            pattern: settings.pattern,
            clock: SessionClock(start: CACurrentMediaTime() + lead),
            limit: settings.limit,
            haptics: settings.haptics
        )
        self.session = session
        status = .running
        timeline.session = session.id
        timeline.pattern = session.pattern
        timeline.clock = session.clock
        timeline.limit = session.limit
        timeline.gain = settings.gain
        publish()
        scheduleEnd()
    }

    func pause() {
        guard status == .running, var session else { return }
        // The audio thread renders a little ahead of now, so a tick due in
        // that stretch rings out anyway. Freeze the clock where the sound
        // stops, and the pause screen and the resume agree with what was heard.
        let frozenAt = CACurrentMediaTime() + (soundOn ? ticks.lookAhead : 0)
        session.clock.pause(at: frozenAt)
        self.session = session
        status = .paused
        sessionEnd?.cancel()
        timeline.clock = session.clock
        publish()
        if soundOn {
            // Hand the audio back while paused: an engine left running would
            // keep the app awake in the background, playing silence.
            ticks.stopAfterTail()
        }
    }

    func resume() {
        guard status == .paused, var session else { return }
        if soundOn {
            // The engine was stopped when the session paused.
            do {
                try ticks.start()
                soundIssue = nil
            } catch {
                // Still a sounding session: the next resume tries again, once
                // whatever has the output (a call, say) has let go of it.
                soundIssue = Self.describe(error)
            }
        }
        // The first new buffer is heard a look-ahead after now. Pick the
        // session up where it froze at that moment, so the screen holds
        // still for that instant and no tick due in it is skipped.
        session.clock.resume(at: CACurrentMediaTime() + (soundOn ? ticks.lookAhead : 0))
        self.session = session
        status = .running
        timeline.clock = session.clock
        publish()
        scheduleEnd()
    }

    func stop() {
        finish(at: CACurrentMediaTime())
    }

    /// Plays the inhale tick and then the exhale tick at `volume`, between
    /// sessions, so the volume can be set by ear.
    func previewTicks(volume: Double) {
        guard status == .idle else { return }
        preview?.cancel()
        soundIssue = nil
        do {
            try ticks.start()
        } catch {
            soundIssue = Self.describe(error)
            ticks.stopAfterTail()
            return
        }
        timeline.gain = Float(volume)
        preview = Task { [weak self] in
            self?.playPreview(.inhale)
            do {
                try await Task.sleep(for: .milliseconds(700))
            } catch {
                return
            }
            self?.playPreview(.exhale)
            if self?.status == .idle {
                self?.ticks.stopAfterTail()
            }
        }
    }

    /// What the screen shows at host time `now`. `stillHalo` holds the halo's
    /// drift for Reduce Motion; the orb itself still breathes, since that is
    /// the pacing.
    func frame(at now: Double, stillHalo: Bool) -> PacerFrame {
        guard let session else {
            return PacerFrame(
                orb: OrbStyle.frame(fullness: 0, paused: false, drift: 0),
                label: .start, reading: nil, elapsed: 0, remaining: nil, hapticBeat: nil
            )
        }
        var elapsed = session.clock.elapsed(at: now)
        var atLimit = false
        if let limit = session.limit, elapsed >= limit {
            // Until the end-of-session task gets its turn. No tick sounds at
            // or past the limit, so no haptic lands there either.
            elapsed = limit
            atLimit = true
        }
        let reading = session.pattern.reading(at: elapsed)
        let shown = max(0, elapsed)
        return PacerFrame(
            orb: OrbStyle.frame(fullness: reading.fullness, paused: session.clock.isPaused, drift: stillHalo ? 0 : shown),
            label: .count(reading.count),
            reading: reading,
            elapsed: shown,
            remaining: session.limit.map { max(0, $0 - shown) },
            hapticBeat: session.haptics && !session.clock.isPaused && !atLimit ? reading.beat : nil
        )
    }

    private func playPreview(_ tick: TickKind) {
        guard status == .idle else { return }
        timeline.previewSerial &+= 1
        timeline.previewKind = tick
        ticks.publish(timeline)
    }

    private func finish(at now: Double) {
        guard let session else { return }
        let elapsed = min(max(0, session.clock.elapsed(at: now)), session.limit ?? .infinity)
        summary = Summary(duration: elapsed, cycles: session.pattern.cyclesCompleted(after: elapsed))
        self.session = nil
        status = .idle
        sessionEnd?.cancel()
        timeline.session = 0
        publish()
        if soundOn {
            ticks.stopAfterTail()
        }
        soundOn = false
    }

    private func publish() {
        if soundOn {
            ticks.publish(timeline)
        }
    }

    /// Ends the session on time even with the screen locked: the audio keeps
    /// the app running, and this does not depend on frames being drawn. It
    /// sleeps on the suspending clock, which stands still while the device
    /// sleeps just as the session clock does.
    private func scheduleEnd() {
        sessionEnd?.cancel()
        guard let session, let limit = session.limit else { return }
        let remaining = limit - session.clock.elapsed(at: CACurrentMediaTime())
        sessionEnd = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, remaining)), clock: .suspending)
            } catch {
                return
            }
            self?.finish(at: CACurrentMediaTime())
        }
    }

    private static func describe(_ error: Error) -> String {
        "No sound: \(error.localizedDescription)"
    }
}

/// What goes in the white tab under the orb.
enum TabLabel: Equatable {
    case count(Int)
    case start
}

/// One frame of the screen, read off the model's clock.
struct PacerFrame {
    let orb: OrbFrame
    let label: TabLabel
    let reading: PacerReading?
    /// Seconds into the session, from 0.
    let elapsed: Double
    /// Seconds left, when the session has a length.
    let remaining: Double?
    /// Changes exactly when a tick fires; nil while haptics should stay quiet.
    let hapticBeat: Int?
}
