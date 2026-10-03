/// What the audio thread needs to know about the session at one instant.
///
/// Plain values only, so the real-time thread can copy it out of a lock
/// without retaining or releasing anything.
public struct AudioTimeline: Sendable, Equatable {
    /// Identifies the session; 0 means there is none and no ticks are due.
    public var session: UInt64
    public var pattern: BreathPattern
    public var clock: SessionClock
    /// Elapsed seconds at which the session ends: no tick at or after it.
    public var limit: Double?
    /// Tick volume, 0...1: the tick's peak level, like breathe.py's --volume.
    public var gain: Float
    /// Bump to play one `previewKind` tick at the start of the next buffer.
    public var previewSerial: UInt64
    public var previewKind: TickKind

    public init(
        session: UInt64,
        pattern: BreathPattern,
        clock: SessionClock,
        limit: Double?,
        gain: Float,
        previewSerial: UInt64 = 0,
        previewKind: TickKind = .inhale
    ) {
        self.session = session
        self.pattern = pattern
        self.clock = clock
        self.limit = limit
        self.gain = gain
        self.previewSerial = previewSerial
        self.previewKind = previewKind
    }

    /// No session, no preview: nothing to play.
    public static let silent = AudioTimeline(
        session: 0, pattern: .standard, clock: SessionClock(start: 0), limit: nil, gain: 0
    )
}

/// Renders the ticks for the audio thread, sample-accurately, off the clock.
///
/// Each buffer asks the pattern which onsets fall inside the stretch of session
/// time it covers and starts a voice on the exact frame. A buffer picks up
/// where the previous one ended, so no onset is played twice or skipped at a
/// buffer boundary. But a buffer starting well past the previous one (an
/// interruption, a route change, a stall) drops the onsets in the gap instead
/// of playing them late: a pacing cue that arrives late is worse than one that
/// never arrives, and replaying a backlog is how breathe.py once summed eight
/// queued ticks into one clipped blast.
///
/// `render` neither allocates nor locks, so it is safe on the real-time audio
/// thread. The mixer itself is not thread-safe: exactly one thread renders.
public final class TickMixer {
    /// Ticks that may sound at once before the oldest is cut short.
    public static let voiceCapacity = 4
    /// How far past the end of the previous buffer a buffer may start and
    /// still count as continuing it.
    public static let gapTolerance = 0.05

    public let sampleRate: Double
    /// Ticks started so far, onsets and previews alike. For diagnostics.
    public private(set) var ticksStarted = 0

    private let inhaleTick: UnsafeMutableBufferPointer<Float>
    private let exhaleTick: UnsafeMutableBufferPointer<Float>
    private let voices: UnsafeMutableBufferPointer<Voice>
    private var session: UInt64
    private var renderedUntil: Double?
    private var previewSerial: UInt64

    private struct Voice {
        var tick: TickKind?
        var position = 0
    }

    /// `current` is the timeline in force when the mixer is made, so that a
    /// mixer built mid-session (after a route change, say) neither replays an
    /// earlier preview nor catches up on onsets it was not around for.
    public init(sampleRate: Double, current: AudioTimeline) {
        precondition(sampleRate > 0, "sample rate must be positive")
        self.sampleRate = sampleRate
        inhaleTick = Self.copy(TickSynth.samples(frequency: TickKind.inhale.frequency, sampleRate: sampleRate))
        exhaleTick = Self.copy(TickSynth.samples(frequency: TickKind.exhale.frequency, sampleRate: sampleRate))
        voices = .allocate(capacity: Self.voiceCapacity)
        voices.initialize(repeating: Voice())
        session = current.session
        previewSerial = current.previewSerial
    }

    deinit {
        inhaleTick.deallocate()
        exhaleTick.deallocate()
        voices.deallocate()
    }

    /// Fills `output` with the ticks heard from `heardAt` (host seconds, when
    /// the buffer's first frame reaches the listener) onwards.
    public func render(into output: UnsafeMutableBufferPointer<Float>, heardAt now: Double, timeline: AudioTimeline) {
        guard let out = output.baseAddress, output.count > 0 else { return }
        let frames = output.count
        out.update(repeating: 0, count: frames)

        // Ticks already ringing carry on, paused or not, as breathe.py's did.
        for index in voices.indices {
            guard let tick = voices[index].tick else { continue }
            let position = mix(tick, from: voices[index].position, into: out, at: 0, frames: frames, gain: timeline.gain)
            voices[index] = position < samples(tick).count ? Voice(tick: tick, position: position) : Voice()
        }

        if timeline.previewSerial != previewSerial {
            previewSerial = timeline.previewSerial
            start(timeline.previewKind, at: 0, into: out, frames: frames, gain: timeline.gain)
        }

        startOnsets(of: timeline, heardAt: now, into: out, frames: frames)

        // Voices sum, so a coincidence can exceed full scale. Clip rather than
        // let it wrap into a crack.
        for index in 0..<frames {
            out[index] = min(max(out[index], -1), 1)
        }
    }

    private func startOnsets(of timeline: AudioTimeline, heardAt now: Double, into out: UnsafeMutablePointer<Float>, frames: Int) {
        guard timeline.session != 0 else {
            session = 0
            renderedUntil = nil
            return
        }
        if timeline.session != session {
            session = timeline.session
            renderedUntil = nil
        }

        let windowStart = timeline.clock.elapsed(at: now)
        // The onsets this buffer owns are those that round to one of its
        // frames, so its window stops half a sample short of its end. An onset
        // past that rounds to the next buffer's first frame, and the next
        // window starts exactly here; clamping it onto this buffer's last
        // frame instead would play it a sample early.
        let windowEnd = timeline.clock.isPaused
            ? windowStart
            : windowStart + (Double(frames) - 0.5) / sampleRate
        var from = windowStart
        if let renderedUntil, windowStart - renderedUntil <= Self.gapTolerance {
            from = renderedUntil
        }
        if from < windowEnd {
            timeline.pattern.forEachOnset(from: from, to: windowEnd, before: timeline.limit) { onset, tick in
                let frame = Int(((onset - windowStart) * sampleRate).rounded())
                start(tick, at: min(max(frame, 0), frames - 1), into: out, frames: frames, gain: timeline.gain)
            }
        }
        renderedUntil = max(renderedUntil ?? windowEnd, windowEnd)
    }

    private func start(_ tick: TickKind, at frame: Int, into out: UnsafeMutablePointer<Float>, frames: Int, gain: Float) {
        ticksStarted += 1
        let position = mix(tick, from: 0, into: out, at: frame, frames: frames, gain: gain)
        guard position < samples(tick).count else { return }
        voices[freeVoice() ?? oldestVoice()] = Voice(tick: tick, position: position)
    }

    /// Adds `tick` from `position` into `out` from `frame` on, and returns the
    /// position it got to.
    private func mix(_ tick: TickKind, from position: Int, into out: UnsafeMutablePointer<Float>, at frame: Int, frames: Int, gain: Float) -> Int {
        let source = samples(tick)
        let count = min(source.count - position, frames - frame)
        guard count > 0 else { return position }
        for offset in 0..<count {
            out[frame + offset] += source[position + offset] * gain
        }
        return position + count
    }

    private func samples(_ tick: TickKind) -> UnsafeMutableBufferPointer<Float> {
        switch tick {
        case .inhale: inhaleTick
        case .exhale: exhaleTick
        }
    }

    private func freeVoice() -> Int? {
        voices.indices.first { voices[$0].tick == nil }
    }

    private func oldestVoice() -> Int {
        var oldest = voices.startIndex
        for index in voices.indices where voices[index].position > voices[oldest].position {
            oldest = index
        }
        return oldest
    }

    private static func copy(_ samples: [Float]) -> UnsafeMutableBufferPointer<Float> {
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: samples.count)
        _ = buffer.initialize(fromContentsOf: samples)
        return buffer
    }
}
