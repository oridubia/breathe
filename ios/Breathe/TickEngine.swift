import AVFoundation
import BreatheCore
import os

/// Plays the ticks.
///
/// One `AVAudioEngine` with one source node, whose render block asks a
/// `TickMixer` for every buffer. The block works out from the buffer's host
/// timestamp which stretch of session time the listener will hear, so each
/// tick is placed on its exact sample from the same clock the screen reads,
/// and keeps coming with the screen locked (the app declares background audio).
///
/// The render block runs on the real-time audio thread, so it never
/// allocates, never waits on a lock and never calls into Objective-C. It is
/// built in a nonisolated function: a closure Swift considers main-actor code
/// traps on Swift 6's isolation check when the audio thread calls it.
@MainActor
final class TickEngine {
    /// Called when sound stops for a reason outside the app: an interruption
    /// (a call, an alarm, Siri) or the output going away (headphones pulled
    /// out). The session should pause rather than carry on in silence or,
    /// worse, out of the phone's speaker.
    var onSoundLost: (@MainActor () -> Void)?

    private var engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var timeline = AudioTimeline.silent
    /// True from `start()` until `stopAfterTail()`: a session or preview wants sound.
    private var wantsSound = false
    /// True while the audio session is ours to hand back.
    private var sessionActive = false
    private var idleStop: Task<Void, Never>?
    private var sessionObservers: [NSObjectProtocol] = []
    private var configurationObserver: NSObjectProtocol?
    private let inputs = RenderInputs()
    private let log = Logger(subsystem: "io.github.oridubia.breathe", category: "audio")

    init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        sessionObservers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                MainActor.assumeIsolated { self?.interrupted(type) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                MainActor.assumeIsolated { self?.routeChanged(reason) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mediaServicesReset() }
            },
        ]
        observeConfiguration()
    }

    /// Seconds between a buffer leaving the engine and the listener hearing
    /// it: a few milliseconds on the speaker, a fifth of a second or more over
    /// Bluetooth.
    var outputLatency: Double {
        AVAudioSession.sharedInstance().outputLatency
    }

    /// Seconds of sound the audio thread has already committed to at this
    /// instant: the IO buffer it is filling, then the output latency before
    /// that buffer is heard. Zero while the engine is not running.
    var lookAhead: Double {
        guard engine.isRunning else { return 0 }
        let session = AVAudioSession.sharedInstance()
        return session.ioBufferDuration + session.outputLatency
    }

    /// Activates the audio session and starts the engine, if not already running.
    func start() throws {
        idleStop?.cancel()
        idleStop = nil
        if !engine.isRunning {
            let session = AVAudioSession.sharedInstance()
            // Playback: the ticks sound with the silent switch on and keep
            // going with the screen locked. Mixing: they play over music
            // instead of stopping it, as they would on a desktop.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            sessionActive = true
            // A stopped engine's source may hold a tick frozen mid-ring,
            // which would play out on starting. A fresh one, told what is
            // already under way, replays nothing.
            detachSource()
            try attachSource()
            engine.prepare()
            try engine.start()
        }
        wantsSound = true
        publishSnapshot()
    }

    /// Hands the audio thread a new timeline.
    func publish(_ timeline: AudioTimeline) {
        self.timeline = timeline
        publishSnapshot()
    }

    /// Lets a ringing tick finish, then stops the engine and hands the audio
    /// session back to whatever else was playing.
    func stopAfterTail() {
        wantsSound = false
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(TickSynth.duration + 0.2))
            } catch {
                return
            }
            self?.shutDown()
        }
    }

    private func shutDown() {
        guard !wantsSound else { return }
        engine.stop()
        // Nothing to hand back when no start activated the session.
        guard sessionActive else { return }
        sessionActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            log.error("Releasing the audio session failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func publishSnapshot() {
        inputs.publish(RenderInputs.Snapshot(timeline: timeline, latency: outputLatency))
    }

    private func attachSource() throws {
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw TickEngineError.noOutput
        }
        let context = RenderContext(mixer: TickMixer(sampleRate: sampleRate, current: timeline), inputs: inputs)
        let node = AVAudioSourceNode(format: format, renderBlock: Self.renderBlock(for: context))
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
        log.info("Tick source attached at \(sampleRate, privacy: .public) Hz")
    }

    private func detachSource() {
        guard let source else { return }
        engine.detach(source)
        self.source = nil
    }

    nonisolated private static func renderBlock(for context: RenderContext) -> AVAudioSourceNodeRenderBlock {
        { _, timestamp, frameCount, bufferList in
            context.render(at: timestamp, frames: Int(frameCount), into: bufferList)
            return noErr
        }
    }

    // MARK: - Things that happen to the audio

    private func observeConfiguration() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
    }

    /// The hardware format changed (a new route, a new sample rate) and the
    /// engine stopped itself. Rebuild the source for the new format and carry
    /// on if sound is still wanted; the mixer it gets is told what is already
    /// under way, so nothing is replayed.
    private func configurationChanged() {
        detachSource()
        restartIfWanted(after: "an audio configuration change")
    }

    /// The audio daemon restarted: every audio object is dead. Start over.
    private func mediaServicesReset() {
        source = nil
        sessionActive = false
        engine = AVAudioEngine()
        observeConfiguration()
        restartIfWanted(after: "a media services reset")
    }

    private func restartIfWanted(after event: String) {
        guard wantsSound else { return }
        do {
            try start()
        } catch {
            log.error("Restarting after \(event, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            onSoundLost?()
        }
    }

    private func interrupted(_ type: AVAudioSession.InterruptionType?) {
        guard type == .began, wantsSound else { return }
        onSoundLost?()
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        // A new route has a new latency; ticks must still land on the beat.
        publishSnapshot()
        if reason == .oldDeviceUnavailable, wantsSound {
            onSoundLost?()
        }
    }
}

enum TickEngineError: LocalizedError {
    case noOutput

    var errorDescription: String? {
        switch self {
        case .noOutput: "There is no audio output to play the ticks on."
        }
    }
}

/// The hand-off from the main thread to the audio thread. The main thread
/// publishes a snapshot whenever something changes; the audio thread reads
/// one per buffer and never waits for it.
private final class RenderInputs: @unchecked Sendable {
    struct Snapshot: Sendable {
        var timeline: AudioTimeline
        /// Seconds from a buffer's host timestamp to the listener hearing it.
        var latency: Double
    }

    private let current = OSAllocatedUnfairLock(initialState: Snapshot(timeline: .silent, latency: 0))
    /// The audio thread's last read. Only the audio thread touches it, which
    /// is what makes the unchecked Sendable above sound.
    private var lastRead = Snapshot(timeline: .silent, latency: 0)

    /// Main thread.
    func publish(_ snapshot: Snapshot) {
        current.withLock { $0 = snapshot }
    }

    /// Audio thread. If the main thread holds the lock at this very moment,
    /// the previous snapshot stands for one more buffer.
    func read() -> Snapshot {
        if let snapshot = current.withLockIfAvailable({ $0 }) {
            lastRead = snapshot
        }
        return lastRead
    }
}

/// Everything the render block touches. After construction only the audio
/// thread uses the mixer, and `RenderInputs` does its own locking, which is
/// what makes the unchecked Sendable sound.
private final class RenderContext: @unchecked Sendable {
    private let mixer: TickMixer
    private let inputs: RenderInputs
    private let secondsPerHostTick: Double

    init(mixer: TickMixer, inputs: RenderInputs) {
        self.mixer = mixer
        self.inputs = inputs
        var timebase = mach_timebase_info_data_t()
        let status = mach_timebase_info(&timebase)
        precondition(status == KERN_SUCCESS && timebase.denom != 0, "no host timebase")
        secondsPerHostTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// Audio thread only.
    func render(at timestamp: UnsafePointer<AudioTimeStamp>, frames: Int, into bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let snapshot = inputs.read()
        let stamp = timestamp.pointee
        // The same host clock as CACurrentMediaTime(), which the session clock runs on.
        let hostTime = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : mach_absolute_time()
        let heardAt = Double(hostTime) * secondsPerHostTick + snapshot.latency

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        mixer.render(into: UnsafeMutableBufferPointer(start: first, count: frames), heardAt: heardAt, timeline: snapshot.timeline)
        for buffer in buffers.dropFirst() {
            buffer.mData?.copyMemory(from: first, byteCount: frames * MemoryLayout<Float>.stride)
        }
    }
}
