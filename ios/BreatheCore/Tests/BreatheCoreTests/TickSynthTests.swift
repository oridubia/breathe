@testable import BreatheCore
import Foundation
import Testing

/// breathe.py synthesises at 44.1 kHz; iPhones mostly run their output at 48.
private let rates = [44_100.0, 48_000.0]

@Suite("The tick")
struct TickSynthTests {
    @Test("Rings rather than clicks: long and loud enough to be unmissable", arguments: rates)
    func ringsRatherThanClicks(sampleRate: Double) {
        let tick = TickSynth.samples(frequency: TickKind.inhale.frequency, sampleRate: sampleRate, peak: 0.5)
        let peak = tick.map { abs(Double($0)) }.max() ?? 0
        let threshold = peak * pow(10, -25 / 20)
        let audible = tick.indices.filter { abs(Double(tick[$0])) > threshold }
        let audibleMilliseconds = Double(audible.last! - audible.first!) / sampleRate * 1000
        #expect(audibleMilliseconds > 150)

        let meanSquare = tick.reduce(0) { $0 + Double($1) * Double($1) } / Double(tick.count)
        #expect(10 * log10(meanSquare) > -21)
    }

    @Test("Never rings over the top of the next tick")
    func fitsBetweenTwoTicks() {
        let tightestGap = min(BreathPattern.standard.inhale, BreathPattern.standard.exhale) / 2
        #expect(TickSynth.duration < tightestGap)
    }

    @Test(arguments: rates)
    func isTheRequestedLengthAndPeak(sampleRate: Double) {
        let tick = TickSynth.samples(frequency: 740, sampleRate: sampleRate, duration: 0.09, peak: 0.4)
        #expect(tick.count == Int(sampleRate * 0.09))
        let peak = tick.map { abs($0) }.max() ?? 0
        #expect(abs(peak - 0.4) < 1e-3)
    }

    @Test(arguments: rates)
    func fadesInAndOutSoItCannotClick(sampleRate: Double) {
        let tick = TickSynth.samples(frequency: 740, sampleRate: sampleRate, peak: 0.4)
        #expect(abs(tick[0]) < 1e-3)
        #expect(abs(tick[tick.count - 1]) < 1e-3)
    }

    @Test func isDeterministic() {
        #expect(TickSynth.samples(frequency: 659, sampleRate: 48_000) == TickSynth.samples(frequency: 659, sampleRate: 48_000))
    }

    @Test func inhaleAndExhaleTicksAreDistinguishable() {
        let inhale = TickSynth.samples(frequency: TickKind.inhale.frequency, sampleRate: 48_000)
        let exhale = TickSynth.samples(frequency: TickKind.exhale.frequency, sampleRate: 48_000)
        #expect(inhale != exhale)
        #expect(TickKind.exhale.frequency < TickKind.inhale.frequency)
    }

    @Test("Both ticks clear the small-speaker roll-off", arguments: TickKind.allCases)
    func bothTicksClearTheSpeakerRolloff(tick kind: TickKind) {
        // A laptop or phone speaker rolls off steeply under ~600 Hz. The old
        // 494 Hz exhale tick put 48% of its energy under 500 Hz and went
        // inaudible; neither tick may sit on that cliff again.
        let sampleRate = 44_100.0
        let tick = TickSynth.samples(frequency: kind.frequency, sampleRate: sampleRate, peak: 0.25).map(Double.init)
        #expect(energyFractionBelow(500, in: tick, sampleRate: sampleRate) < 0.05)
        #expect(kind.frequency > 600)
    }

    @Test("The two ticks are equally loud")
    func ticksAreEquallyLoud() {
        let inhale = TickSynth.samples(frequency: TickKind.inhale.frequency, sampleRate: 48_000, peak: 0.25)
        let exhale = TickSynth.samples(frequency: TickKind.exhale.frequency, sampleRate: 48_000, peak: 0.25)
        let inhalePeak = inhale.map { abs($0) }.max() ?? 0
        let exhalePeak = exhale.map { abs($0) }.max() ?? 0
        #expect(abs(inhalePeak - exhalePeak) < 1e-6)
    }

    @Test("Same pitch at any output rate", arguments: TickKind.allCases)
    func pitchDoesNotDependOnTheSampleRate(tick kind: TickKind) {
        for sampleRate in rates {
            let tick = TickSynth.samples(frequency: kind.frequency, sampleRate: sampleRate)
            #expect(abs(dominantFrequency(of: tick, sampleRate: sampleRate) - kind.frequency) < kind.frequency * 0.02)
        }
    }

    @Test("The lowpass is breathe.py's 0.32 at 44.1 kHz")
    func lowpassMatchesBreathePy() {
        #expect(abs(TickSynth.lowpassCoefficient(sampleRate: 44_100) - 0.32) < 1e-12)
        #expect(TickSynth.lowpassCoefficient(sampleRate: 48_000) < 0.32)
    }

    @Test func noiseIsStandardNormalAndRepeatable() {
        var first = GaussianNoise(seed: 0)
        var second = GaussianNoise(seed: 0)
        let draws = (0..<20_000).map { _ in first.next() }
        #expect(draws == (0..<20_000).map { _ in second.next() })
        let mean = draws.reduce(0, +) / Double(draws.count)
        let variance = draws.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(draws.count)
        #expect(abs(mean) < 0.03)
        #expect(abs(variance - 1) < 0.05)
    }
}

/// Share of the one-sided spectrum's power below `cutoff`, as numpy's
/// `power[freq < cutoff].sum() / power.sum()` over `rfft` bins computes it.
/// Only the low bins are evaluated directly; the total comes from Parseval.
private func energyFractionBelow(_ cutoff: Double, in signal: [Double], sampleRate: Double) -> Double {
    let count = signal.count
    func power(bin: Int) -> Double {
        var real = 0.0
        var imaginary = 0.0
        for (index, sample) in signal.enumerated() {
            let angle = -2 * Double.pi * Double(bin) * Double(index) / Double(count)
            real += sample * cos(angle)
            imaginary += sample * sin(angle)
        }
        return real * real + imaginary * imaginary
    }
    let binWidth = sampleRate / Double(count)
    let below = (0..<count / 2 + 1).prefix { Double($0) * binWidth < cutoff }.reduce(0) { $0 + power(bin: $1) }
    // Parseval: the full two-sided spectrum sums to N times the signal energy;
    // the one-sided spectrum counts every bin once, so add back DC (and the
    // Nyquist bin for even N) before halving.
    let twoSided = Double(count) * signal.reduce(0) { $0 + $1 * $1 }
    let nyquist = count.isMultiple(of: 2) ? power(bin: count / 2) : 0
    let oneSided = (twoSided + power(bin: 0) + nyquist) / 2
    return below / oneSided
}

/// Frequency of the strongest component, from zero crossings past the attack.
private func dominantFrequency(of tick: [Float], sampleRate: Double) -> Double {
    let start = Int(sampleRate * 0.02)
    let end = Int(sampleRate * 0.12)
    var crossings = 0
    for index in start..<end where (tick[index - 1] < 0) != (tick[index] < 0) {
        crossings += 1
    }
    return Double(crossings) / 2 / ((Double(end - start)) / sampleRate)
}
