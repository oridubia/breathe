import Foundation

/// Which of the two ticks an onset plays.
public enum TickKind: Sendable, Hashable, CaseIterable {
    case inhale
    case exhale

    /// Inhale high, exhale a fifth below it, both clear of the ~600 Hz cliff
    /// under which small speakers throw the fundamental away. (The old pair
    /// was 740/494 Hz, and the exhale tick went inaudible on laptops.)
    public var frequency: Double {
        switch self {
        case .inhale: 988
        case .exhale: 659
        }
    }
}

/// breathe.py's tick: a soft bell with a fast attack and no click.
///
/// It has to RING, not click. A 78 ms blip near the threshold of hearing reads
/// as "it randomly misses ticks", because catching it depends on the room and
/// on where your attention is, not on whether it played. At 300 ms the tick
/// stays within 25 dB of its peak for about 264 ms.
public enum TickSynth {
    public static let duration = 0.30

    /// The tick for `frequency` at `sampleRate`, normalised to `peak`.
    ///
    /// The app renders both ticks once per output sample rate at a peak of 1
    /// and applies the volume as a gain while mixing.
    public static func samples(
        frequency: Double,
        sampleRate: Double,
        duration: Double = duration,
        peak: Double = 1
    ) -> [Float] {
        precondition(frequency > 0 && sampleRate > 0 && duration > 0 && peak >= 0,
                     "tick parameters must be positive")
        let count = Int(sampleRate * duration)
        let decay = 8.0
        let filter = lowpassCoefficient(sampleRate: sampleRate)
        var noise = GaussianNoise(seed: 0)
        var shaped = [Double](repeating: 0, count: count)
        var level = 0.0
        var top = 0.0
        for index in 0..<count {
            let t = Double(index) / sampleRate
            // Each partial gets its OWN decay, and the upper ones die away
            // several times faster than the fundamental. That is the whole
            // difference between a bell and a buzzer: the brightness is only
            // in the attack, and what is left is a soft tone.
            var body = 0.0
            for partial in partials {
                body += partial.amplitude
                    * sin(2 * Double.pi * frequency * partial.multiple * t)
                    * exp(-t * decay * partial.decayScale)
            }
            // Just enough transient to give it an edge to land on.
            let transient = noise.next() * exp(-t * 1400) * 0.05
            // 8 ms rather than 2.5 ms, so it swells instead of snapping.
            let swell = min(t / 0.008, 1)
            level += filter * ((body + transient) * swell - level)
            shaped[index] = level
            top = max(top, abs(level))
        }

        let scale = peak / (top + 1e-9)
        let fade = Int(sampleRate * 0.005)
        return shaped.indices.map { index in
            var sample = shaped[index] * scale
            let fromEnd = count - 1 - index
            if fade > 1, fromEnd < fade {
                sample *= Double(fromEnd) / Double(fade - 1)
            }
            return Float(sample)
        }
    }

    /// The one-pole lowpass coefficient. breathe.py uses 0.32 at 44.1 kHz;
    /// holding the cutoff fixed rather than the coefficient keeps the timbre
    /// the same at whatever rate the output runs.
    static func lowpassCoefficient(sampleRate: Double) -> Double {
        1 - pow(1 - 0.32, 44_100 / sampleRate)
    }

    private static let partials: [(multiple: Double, amplitude: Double, decayScale: Double)] = [
        (1, 1.00, 1.0),
        (2, 0.16, 2.8),
        (3, 0.05, 4.5),
    ]
}

/// Deterministic standard-normal noise (SplitMix64 and Box-Muller), so a tick
/// comes out the same every time it is made.
struct GaussianNoise {
    private var state: UInt64
    private var spare: Double?

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> Double {
        if let spare {
            self.spare = nil
            return spare
        }
        let radius = (-2 * log(1 - uniform())).squareRoot()
        let angle = 2 * Double.pi * uniform()
        spare = radius * sin(angle)
        return radius * cos(angle)
    }

    /// Uniform in [0, 1).
    private mutating func uniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) * 0x1.0p-53
    }
}
