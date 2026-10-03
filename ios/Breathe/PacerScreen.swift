import BreatheCore
import QuartzCore
import SwiftUI
import UIKit

/// The one screen: the orb, a quiet clock and the few controls a session
/// needs. A tap anywhere starts, pauses and resumes, like breathe.py's space bar.
struct PacerScreen: View {
    @Environment(PacerModel.self) private var pacer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingSettings = false
    private var settings = StoredSettings()

    var body: some View {
        ZStack {
            Color("PacerBackground")
                .ignoresSafeArea()
            TimelineView(.animation(paused: pacer.status != .running)) { timeline in
                let frame = pacer.frame(at: Self.hostTime(of: timeline.date), stillHalo: reduceMotion)
                ZStack {
                    OrbCanvas(orb: frame.orb, label: frame.label)
                        .ignoresSafeArea()
                        .accessibilityElement()
                        .accessibilityLabel("Breathing pacer")
                        .accessibilityValue(accessibilityValue(frame))
                        .accessibilityHint(accessibilityHint)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { primaryAction() }
                    VStack {
                        topBar(frame)
                        Spacer()
                        bottomPanel
                    }
                    .padding()
                }
                .sensoryFeedback(trigger: frame.hapticBeat) { old, new in
                    Self.feedback(from: old, to: new)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: primaryAction)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onChange(of: pacer.status, initial: true) { _, status in
            // Keep the screen awake while the orb is being followed.
            UIApplication.shared.isIdleTimerDisabled = status == .running
        }
    }

    private func topBar(_ frame: PacerFrame) -> some View {
        ZStack {
            if pacer.status != .idle {
                Text(clockText(frame))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if pacer.status == .idle {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title3)
                            .padding(8)
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            if let issue = pacer.soundIssue {
                Label(issue, systemImage: "speaker.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            switch pacer.status {
            case .idle:
                idlePanel
            case .running:
                EmptyView()
            case .paused:
                pausedPanel
            }
        }
        .multilineTextAlignment(.center)
    }

    private var idlePanel: some View {
        VStack(spacing: 6) {
            if let summary = pacer.summary {
                Text("Done. \(Readout.clock(summary.duration)), ^[\(summary.cycles) cycle](inflect: true).")
                    .font(.subheadline)
            }
            Text("Tap to begin")
                .font(.headline)
            Text(Self.describe(settings.value))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var pausedPanel: some View {
        VStack(spacing: 12) {
            Text("Paused")
                .font(.headline)
            HStack(spacing: 16) {
                Button("End", role: .destructive) {
                    pacer.stop()
                }
                .buttonStyle(.bordered)
                Button("Resume") {
                    pacer.resume()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func primaryAction() {
        switch pacer.status {
        case .idle: pacer.start(settings.value)
        case .running: pacer.pause()
        case .paused: pacer.resume()
        }
    }

    /// Time left when the session has a length, time elapsed when it does not,
    /// as breathe.py's terminal shows it.
    private func clockText(_ frame: PacerFrame) -> String {
        if let remaining = frame.remaining {
            return "\(Readout.clock(remaining)) left"
        }
        return Readout.clock(frame.elapsed)
    }

    private func accessibilityValue(_ frame: PacerFrame) -> String {
        switch pacer.status {
        case .idle:
            return "Ready"
        case .paused:
            return "Paused"
        case .running:
            guard let reading = frame.reading, reading.beat >= 0 else { return "Starting" }
            let phase = switch reading.state.phase {
            case .inhale: "Breathe in"
            case .exhale: "Breathe out"
            case .holdIn, .holdOut: "Hold"
            }
            return "\(phase), \(reading.count)"
        }
    }

    private var accessibilityHint: String {
        switch pacer.status {
        case .idle: "Starts a session"
        case .running: "Pauses the session"
        case .paused: "Resumes the session"
        }
    }

    /// "4 s in · 6 s out · 0.5 s hold · no time limit"
    private static func describe(_ settings: PacerSettings) -> String {
        let pattern = settings.pattern
        var parts = ["\(pattern.inhale.secondsText) in", "\(pattern.exhale.secondsText) out"]
        if pattern.hold > 0 {
            parts.append("\(pattern.hold.secondsText) hold")
        }
        parts.append(settings.minutes > 0 ? "\(settings.minutes) min" : "no time limit")
        return parts.joined(separator: " · ")
    }

    /// One tap per tick: firmer on the inhale, lighter on the exhale. Only for
    /// the very next tick, so nothing buzzes when haptics come on mid-breath
    /// or when the app comes back from the background several ticks later.
    private static func feedback(from old: Int?, to new: Int?) -> SensoryFeedback? {
        guard let old, let new, new == old + 1 else { return nil }
        return new.isMultiple(of: 2)
            ? .impact(weight: .medium, intensity: 0.9)
            : .impact(weight: .light, intensity: 0.7)
    }

    /// A timeline date on the host clock the session runs on.
    private static func hostTime(of date: Date) -> Double {
        CACurrentMediaTime() + date.timeIntervalSinceNow
    }
}
