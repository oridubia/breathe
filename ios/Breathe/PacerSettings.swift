import BreatheCore
import SwiftUI

/// The user's choices. Values are clamped to the ranges the settings screen
/// offers before they are used, so whatever is in UserDefaults always makes
/// a session that can be paced.
struct PacerSettings: Equatable {
    var inhale: Double
    var exhale: Double
    var hold: Double
    /// Session length in minutes; 0 runs until stopped (breathe.py's default).
    var minutes: Int
    /// Tick volume: the tick's peak level, like breathe.py's --volume.
    var volume: Double
    var sound: Bool
    var haptics: Bool

    static let standard = PacerSettings(
        inhale: BreathPattern.standard.inhale,
        exhale: BreathPattern.standard.exhale,
        hold: BreathPattern.standard.hold,
        minutes: 0,
        volume: 0.5,
        sound: true,
        haptics: true
    )

    static let breathRange: ClosedRange<Double> = 1...12
    static let breathStep = 0.5
    static let holdRange: ClosedRange<Double> = 0...3
    static let holdStep = 0.25
    static let volumeRange: ClosedRange<Double> = 0.1...1
    static let lengths = [0, 1, 3, 5, 10, 15, 20, 30, 45, 60]

    var pattern: BreathPattern {
        guard let pattern = BreathPattern(
            inhale: inhale.clamped(to: Self.breathRange),
            exhale: exhale.clamped(to: Self.breathRange),
            hold: hold.clamped(to: Self.holdRange)
        ) else {
            preconditionFailure("the clamped ranges always make a valid pattern")
        }
        return pattern
    }

    /// Elapsed seconds at which the session ends, or nil to run until stopped.
    var limit: Double? {
        minutes > 0 ? Double(minutes) * 60 : nil
    }

    var gain: Float {
        Float(volume.clamped(to: Self.volumeRange))
    }
}

/// The settings as stored in UserDefaults, as one SwiftUI dynamic property.
struct StoredSettings: DynamicProperty {
    @AppStorage("pattern.inhale") var inhale = PacerSettings.standard.inhale
    @AppStorage("pattern.exhale") var exhale = PacerSettings.standard.exhale
    @AppStorage("pattern.hold") var hold = PacerSettings.standard.hold
    @AppStorage("session.minutes") var minutes = PacerSettings.standard.minutes
    @AppStorage("feedback.volume") var volume = PacerSettings.standard.volume
    @AppStorage("feedback.sound") var sound = PacerSettings.standard.sound
    @AppStorage("feedback.haptics") var haptics = PacerSettings.standard.haptics

    var value: PacerSettings {
        PacerSettings(
            inhale: inhale, exhale: exhale, hold: hold, minutes: minutes,
            volume: volume, sound: sound, haptics: haptics
        )
    }

    func restoreDefaults() {
        let standard = PacerSettings.standard
        inhale = standard.inhale
        exhale = standard.exhale
        hold = standard.hold
        minutes = standard.minutes
        volume = standard.volume
        sound = standard.sound
        haptics = standard.haptics
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Double {
    /// "4 s", "5.5 s", "0.25 s", in the user's number format.
    var secondsText: String {
        "\(formatted(.number.precision(.fractionLength(0...2)))) s"
    }
}
