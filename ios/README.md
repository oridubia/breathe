# Breathe for iOS

The pacer from `breathe.py` as an iPhone and iPad app. It keeps the same breath
(4 s in, 6 s out, half a second still at each turn by default), the same two
ringing ticks, the same orb growing toward its ring with the drifting halo, and
the same stopwatch count in the white tab.

## What it does

- Tap anywhere to start, pause and resume, like the space bar in `--gui`. End a
  session from the pause screen; it closes with breathe.py's line,
  "Done. 10:00, 54 cycles."
- The ticks keep coming with the screen locked, play over music instead of
  stopping it, and sound even with the silent switch on. A call, an alarm, Siri
  or unplugging headphones pauses the session; tap to carry on.
- A haptic tap lands on each tick while the screen is on: firmer on the inhale,
  lighter on the exhale.
- Settings: inhale and exhale (1 to 12 s), hold (0 to 3 s), session length (no
  limit, or 1 to 60 minutes), tick volume with a preview, sound and haptics on
  or off. Changes apply from the next session.
- The screen stays awake during a session. With Reduce Motion on, the halo
  stops drifting; the orb still breathes, because that is the pacing.

Not carried over: the terminal bar, the `--interval` metronome mode,
`--debug-audio` and the desktop audio back-ends. iOS has a single audio path.

## Requirements

- Xcode 16 or newer: the project uses Xcode 16's format and Swift 6 language mode.
- iOS or iPadOS 17 or newer.

## Running it

### With a Mac

1. Open `ios/Breathe.xcodeproj`.
2. For the simulator, pick an iPhone and press Run.
3. For your own iPhone, go to the Breathe target's *Signing & Capabilities* tab
   and set *Team* to your Apple ID; a free Personal Team works. If Xcode says
   the bundle identifier is taken, change `io.github.oridubia.breathe` to
   something unique to you. Apps installed with a free team stop launching
   after 7 days; run them from Xcode again to renew.

### Without a Mac

Each run of the iOS workflow uploads an unsigned build as the
`Breathe-unsigned-ipa` artifact. iOS will not install an unsigned app as it
is. A sideloading tool for Windows such as Sideloadly or AltStore re-signs it
with your Apple ID. These are third-party tools that ask for your Apple ID
credentials, so decide whether you trust them first. With a free Apple ID the
install also lasts 7 days. TestFlight and the App Store need the paid Apple
Developer Program, and neither is set up here.

## Tests

```sh
swift test --package-path ios/BreatheCore
```

This runs on macOS or Linux with Swift 6. You can also open
`ios/BreatheCore/Package.swift` in Xcode and press Cmd-U. The suite covers the
clock, the count, the easing, the orb and halo geometry, the tick waveform and
the tick mixer, and mirrors `test_breathe.py` where the two overlap. The app
layer (SwiftUI views, AVAudioEngine wiring) has no automated tests. CI compiles
it for the simulator and for devices.

## How it is built

- `BreatheCore/` is a Swift package with no Apple-only frameworks. It decides
  what to show and when to tick: ports of `phase_at`, `ease`, `fullness_at`,
  `orb_radius`, `phase_count`, `make_tick` and the halo maths, plus the
  sample-accurate `TickMixer` the audio thread runs.
- `Breathe/` is the SwiftUI app. `PacerModel` is the session state machine,
  `TickEngine` owns AVAudioEngine and its interruptions, `PacerScreen` and
  `OrbCanvas` draw, and `SettingsView` edits the settings.
- `Tools/make_app_icon.py` renders the app icon from breathe.py's own
  constants. Re-run it if the look changes.

### Invariants

These are breathe.py's invariants, translated to iOS. Do not break them.

1. **One clock.** `BreathPattern.phase(at:)` is the single source of truth. A
   session is a `SessionClock` value on the host clock (`CACurrentMediaTime`,
   which is `mach_absolute_time`). The screen evaluates it each frame and the
   audio thread each buffer, against that same clock. Onsets come from the
   cycle index, never from a running total.
2. **Audio.** The ticks are synthesised once per output sample rate. They use
   the same partials, decays, transient, swell, lowpass and fade as
   `make_tick`, with the lowpass cutoff held fixed across sample rates.
   `TickMixer` places each one on the sample where the clock says it will be
   heard, output latency included, so Bluetooth stays on the beat. A buffer
   continues the previous one; a gap (an interruption, a route change) drops
   the ticks inside it instead of playing them late. No catch-up bursts and no
   stale queue.
3. **Real-time safety.** The render block does not allocate, block or message
   Objective-C. It reads the session through a try-lock and, if the main
   thread holds the lock, reuses the previous snapshot for one buffer. It is
   built in a nonisolated function, because a closure that Swift 6 considers
   main-actor code traps when the audio thread calls it.
4. **Easing is visual only.** The ticks and the count stay exactly on the
   clock.
5. **Haptics** come from the frame loop, keyed on `PacerReading.beat`, which
   changes exactly at the onsets. They fire only for the next beat in
   sequence and only while the scene is active, so nothing buzzes on
   returning from the background, and none lands at a session's limit,
   where no tick plays.
6. **Pausing** freezes the clock where the audio has already rendered to
   (now plus the output's look-ahead), and resuming picks it up when the
   first new sound is heard, so no tick plays during a pause and none is
   skipped or repeated after it.
