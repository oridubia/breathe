import BreatheCore
import SwiftUI

/// The pattern, the session length and the feedback. breathe.py's command-line
/// options, as a form; changes apply from the next session.
struct SettingsView: View {
    @Environment(PacerModel.self) private var pacer
    @Environment(\.dismiss) private var dismiss
    private var settings = StoredSettings()

    var body: some View {
        NavigationStack {
            Form {
                patternSection
                Section("Session") {
                    Picker("Length", selection: settings.$minutes) {
                        ForEach(PacerSettings.lengths, id: \.self) { minutes in
                            Text(minutes > 0 ? "\(minutes) min" : "No limit").tag(minutes)
                        }
                    }
                }
                feedbackSection
                Section {
                    Button("Restore Defaults", role: .destructive) {
                        settings.restoreDefaults()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var patternSection: some View {
        Section {
            SecondsStepper("Breathe in", value: settings.$inhale,
                           in: PacerSettings.breathRange, step: PacerSettings.breathStep)
            SecondsStepper("Breathe out", value: settings.$exhale,
                           in: PacerSettings.breathRange, step: PacerSettings.breathStep)
            SecondsStepper("Hold at each turn", value: settings.$hold,
                           in: PacerSettings.holdRange, step: PacerSettings.holdStep)
        } header: {
            Text("Pattern")
        } footer: {
            Text(rateDescription)
        }
    }

    private var feedbackSection: some View {
        Section {
            Toggle("Tick Sound", isOn: settings.$sound)
            if settings.sound {
                LabeledContent("Volume") {
                    Slider(value: settings.$volume, in: PacerSettings.volumeRange, onEditingChanged: { editing in
                        if !editing {
                            pacer.previewTicks(volume: settings.volume)
                        }
                    })
                }
                Button("Play Both Ticks") {
                    pacer.previewTicks(volume: settings.volume)
                }
            }
            Toggle("Haptics", isOn: settings.$haptics)
        } header: {
            Text("Feedback")
        } footer: {
            if let issue = pacer.soundIssue {
                Text(issue)
            } else {
                Text("Ticks play over other audio and keep going with the screen locked.")
            }
        }
    }

    /// "5.5 breaths a minute, one every 11 s."
    private var rateDescription: String {
        let pattern = settings.value.pattern
        let rate = pattern.breathsPerMinute.formatted(.number.precision(.fractionLength(0...1)))
        return "\(rate) breaths a minute, one every \(pattern.period.secondsText)."
    }
}

/// A row that steps a number of seconds and shows it.
private struct SecondsStepper: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    init(_ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>, step: Double) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            LabeledContent(title, value: value.secondsText)
        }
    }
}
