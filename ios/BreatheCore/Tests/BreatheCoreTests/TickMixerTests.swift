@testable import BreatheCore
import Testing

private let sampleRate = 48_000.0
/// Host time of the first inhale tick in these tests.
private let start = 10.0

private func session(
    _ id: UInt64 = 1,
    pattern: BreathPattern = .standard,
    clock: SessionClock = SessionClock(start: start),
    limit: Double? = nil,
    gain: Float = 0.5
) -> AudioTimeline {
    AudioTimeline(session: id, pattern: pattern, clock: clock, limit: limit, gain: gain)
}

private func tick(_ kind: TickKind) -> [Float] {
    TickSynth.samples(frequency: kind.frequency, sampleRate: sampleRate)
}

/// Renders `seconds` of contiguous buffers heard from host time `heardFrom`.
private func render(
    _ mixer: TickMixer,
    _ timeline: AudioTimeline,
    heardFrom heard: Double,
    seconds: Double,
    frames: Int = 256
) -> [Float] {
    let buffers = Int((seconds * sampleRate / Double(frames)).rounded(.up))
    var output: [Float] = []
    output.reserveCapacity(buffers * frames)
    var buffer = [Float](repeating: 0, count: frames)
    for index in 0..<buffers {
        let bufferHeard = heard + Double(index * frames) / sampleRate
        buffer.withUnsafeMutableBufferPointer { mixer.render(into: $0, heardAt: bufferHeard, timeline: timeline) }
        output += buffer
    }
    return output
}

@Suite("The tick mixer")
struct TickMixerTests {
    @Test("The first inhale tick lands on its exact sample")
    func firstTickLandsOnTheExactSample() {
        let mixer = TickMixer(sampleRate: sampleRate, current: .silent)
        let output = render(mixer, session(), heardFrom: start - 0.1, seconds: 0.5)
        let onset = Int(0.1 * sampleRate)
        let inhale = tick(.inhale)
        #expect(output[..<onset].allSatisfy { $0 == 0 })
        #expect(zip(output[onset...], inhale).allSatisfy { abs($0 - $1 * 0.5) < 1e-7 })
        #expect(mixer.ticksStarted == 1)
    }

    @Test("Contiguous buffers of any size never play a tick twice or skip one")
    func contiguousBuffersNeitherDoubleNorDrop() {
        let mixer = TickMixer(sampleRate: sampleRate, current: .silent)
        let timeline = session()
        var generator = SplitMix(seed: 3)
        var frame = 0
        var heard = start - 1
        var buffer = [Float](repeating: 0, count: 1024)
        while heard < start + 61 {
            let frames = Int(generator.next(in: 64...1024))
            // Host timestamps wobble by microseconds against the sample clock.
            let jitter = generator.next(in: -20e-6...20e-6)
            buffer.withUnsafeMutableBufferPointer { whole in
                let slice = UnsafeMutableBufferPointer(rebasing: whole[0..<frames])
                mixer.render(into: slice, heardAt: heard + jitter, timeline: timeline)
            }
            frame += frames
            heard = start - 1 + Double(frame) / sampleRate
        }
        // 0, 4.5, 11, 15.5, ... 55, 59.5: two ticks in each of six cycles.
        #expect(mixer.ticksStarted == 12)
    }

    @Test("Output does not depend on how the stream is cut into buffers")
    func outputIsIndependentOfBufferSize() {
        let small = render(TickMixer(sampleRate: sampleRate, current: .silent), session(),
                           heardFrom: start - 1, seconds: 13, frames: 256)
        let large = render(TickMixer(sampleRate: sampleRate, current: .silent), session(),
                           heardFrom: start - 1, seconds: 13, frames: 1000)
        let length = min(small.count, large.count)
        let firstDifference = (0..<length).first { small[$0] != large[$0] }
        #expect(firstDifference == nil)
        #expect(small.contains { $0 != 0 })
    }

    @Test("A gap drops the ticks inside it rather than playing them late")
    func aGapDropsTicksInsteadOfPlayingThemLate() {
        let mixer = TickMixer(sampleRate: sampleRate, current: .silent)
        let timeline = session()
        _ = render(mixer, timeline, heardFrom: start - 0.1, seconds: 1)
        #expect(mixer.ticksStarted == 1)

        // An interruption: the next buffer is heard at elapsed 12 s, past the
        // exhale at 4.5 and the inhale at 11. Neither may sound now.
        let resumed = render(mixer, timeline, heardFrom: start + 12, seconds: 0.1)
        #expect(mixer.ticksStarted == 1)
        #expect(resumed.allSatisfy { $0 == 0 })

        // The schedule simply carries on: the exhale at 15.5 plays on time.
        _ = render(mixer, timeline, heardFrom: start + 12.1, seconds: 4)
        #expect(mixer.ticksStarted == 2)
    }

    @Test("A hiccup shorter than the tolerance still plays the tick it straddles")
    func aSmallGapStillPlaysTheTickInIt() {
        let mixer = TickMixer(sampleRate: sampleRate, current: .silent)
        let timeline = session()
        _ = render(mixer, timeline, heardFrom: start + 4.4, seconds: 0.09, frames: 480)
        #expect(mixer.ticksStarted == 0)
        _ = render(mixer, timeline, heardFrom: start + 4.505, seconds: 0.1, frames: 480)
        #expect(mixer.ticksStarted == 1)
    }

    @Test("Pausing stops new ticks but lets a ringing one finish")
    func pausingLetsARingingTickFinish() {
        let mixer = TickMixer(sampleRate: sampleRate, current: .silent)
        var timeline = session()
        _ = render(mixer, timeline, heardFrom: start - 0.1, seconds: 0.2, frames: 480)
        timeline.clock.pause(at: start + 0.1)
        let paused = render(mixer, timeline, heardFrom: start + 0.1, seconds: 6, frames: 480)
        #expect(mixer.ticksStarted == 1)
        let tail = Int(0.19 * sampleRate)
        #expect(paused[..<tail].contains { $0 != 0 })
        #expect(paused[Int(0.21 * sampleRate)...].allSatisfy { $0 == 0 })
    }

    @Test("Resuming never repeats a tick that was already rendered")
    func resumingNeverRepeatsATick() {
        let mixer = TickMixer(sampleRate: sampleRate, current: .silent)
        var timeline = session()
        // Audio runs ahead of the listener: the exhale at 4.5 is already
        // rendered when the pause lands at 4.45.
        _ = render(mixer, timeline, heardFrom: start - 0.1, seconds: 4.7)
        #expect(mixer.ticksStarted == 2)
        timeline.clock.pause(at: start + 4.45)
        _ = render(mixer, timeline, heardFrom: start + 4.6, seconds: 1)
        timeline.clock.resume(at: start + 20)
        _ = render(mixer, timeline, heardFrom: start + 20, seconds: 1)
        #expect(mixer.ticksStarted == 2)
        // ...and the next inhale, at elapsed 11 (host 36.55), still plays.
        _ = render(mixer, timeline, heardFrom: start + 21, seconds: 6)
        #expect(mixer.ticksStarted == 3)
    }

    @Test("Pausing where the audio has rendered to plays the next tick once, after the resume")
    func pausingAtTheRenderedPointPlaysTheNextTickOnceAfterResuming() {
        let mixer = TickMixer(sampleRate: sampleRate, current: .silent)
        var timeline = session()
        // 10 ms buffers, rendered up to elapsed 4.49: one buffer short of the
        // exhale at 4.5. The app pauses the clock there, where the sound it
        // has committed to stops, rather than at the earlier tap.
        let frames = 480
        _ = render(mixer, timeline, heardFrom: start - 0.01, seconds: 4.5, frames: frames)
        #expect(mixer.ticksStarted == 1)
        timeline.clock.pause(at: start + 4.49)
        let paused = render(mixer, timeline, heardFrom: start + 4.49, seconds: 1, frames: frames)
        #expect(mixer.ticksStarted == 1)
        #expect(paused.allSatisfy { $0 == 0 })

        // The exhale lands on the first frame of the second resumed buffer:
        // elapsed 4.49 to 4.5, neither skipped nor repeated.
        timeline.clock.resume(at: start + 20)
        let resumed = render(mixer, timeline, heardFrom: start + 20, seconds: 1, frames: frames)
        #expect(mixer.ticksStarted == 2)
        #expect(resumed[..<frames].allSatisfy { $0 == 0 })
        #expect(zip(resumed[frames...], tick(.exhale)).allSatisfy { abs($0 - $1 * 0.5) < 1e-7 })
        // Nothing more until the inhale at elapsed 11 (host 36.51).
        _ = render(mixer, timeline, heardFrom: start + 21, seconds: 5, frames: frames)
        #expect(mixer.ticksStarted == 2)
    }

    @Test func noTickAtOrAfterTheLimit() {
        let mixer = TickMixer(sampleRate: sampleRate, current: .silent)
        _ = render(mixer, session(limit: 11), heardFrom: start - 0.1, seconds: 12)
        #expect(mixer.ticksStarted == 2)
    }

    @Test func noSessionIsSilence() {
        let mixer = TickMixer(sampleRate: sampleRate, current: .silent)
        var timeline = session()
        timeline.session = 0
        let output = render(mixer, timeline, heardFrom: start - 0.1, seconds: 5)
        #expect(output.allSatisfy { $0 == 0 })
        #expect(mixer.ticksStarted == 0)
    }

    @Test("A new session starts from its own first tick")
    func aNewSessionStartsClean() {
        let mixer = TickMixer(sampleRate: sampleRate, current: .silent)
        _ = render(mixer, session(1), heardFrom: start - 0.1, seconds: 6)
        #expect(mixer.ticksStarted == 2)
        let next = session(2, clock: SessionClock(start: start + 6.2))
        _ = render(mixer, next, heardFrom: start + 6, seconds: 1)
        #expect(mixer.ticksStarted == 3)
    }

    @Test("A preview plays once, from the start of the next buffer")
    func previewPlaysOnce() {
        let mixer = TickMixer(sampleRate: sampleRate, current: .silent)
        var timeline = AudioTimeline.silent
        timeline.gain = 0.5
        timeline.previewSerial = 1
        timeline.previewKind = .exhale
        let output = render(mixer, timeline, heardFrom: 0, seconds: 1)
        #expect(mixer.ticksStarted == 1)
        #expect(zip(output, tick(.exhale)).allSatisfy { abs($0 - $1 * 0.5) < 1e-7 })
        #expect(output[tick(.exhale).count...].allSatisfy { $0 == 0 })
    }

    @Test("A mixer rebuilt mid-session replays neither a preview nor missed ticks")
    func aRebuiltMixerDoesNotReplayThePast() {
        var timeline = session()
        timeline.previewSerial = 3
        let mixer = TickMixer(sampleRate: sampleRate, current: timeline)
        _ = render(mixer, timeline, heardFrom: start + 5, seconds: 5)
        #expect(mixer.ticksStarted == 0)
        _ = render(mixer, timeline, heardFrom: start + 10, seconds: 2)
        #expect(mixer.ticksStarted == 1)
    }

    @Test("Volume is a gain on the same waveform")
    func volumeIsAGain() {
        let quiet = render(TickMixer(sampleRate: sampleRate, current: .silent), session(gain: 0.25),
                           heardFrom: start - 0.1, seconds: 0.5)
        let loud = render(TickMixer(sampleRate: sampleRate, current: .silent), session(gain: 0.5),
                          heardFrom: start - 0.1, seconds: 0.5)
        #expect(zip(quiet, loud).allSatisfy { abs($0 * 2 - $1) < 1e-7 })
    }

    @Test("The mix is clipped, so a pile-up cannot crack")
    func pileUpsAreClipped() throws {
        let frantic = try #require(BreathPattern(inhale: 0.01, exhale: 0.01, hold: 0))
        let mixer = TickMixer(sampleRate: sampleRate, current: .silent)
        let output = render(mixer, session(pattern: frantic, limit: 1, gain: 1), heardFrom: start, seconds: 1.5)
        #expect(output.allSatisfy { abs($0) <= 1 })
        #expect(output.contains { abs($0) == 1 })
        #expect(mixer.ticksStarted == 100)
    }
}
