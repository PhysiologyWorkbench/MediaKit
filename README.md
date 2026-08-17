# MediaKit

The media plane of the Physiology Workbench family: capture of OS-mediated
sensors — camera, microphone, motion, other apps' audio — fan-out of the
high-volume buffers to reducers, and the reducers that turn them into
low-volume plain-data streams: pose skeletons, breath and vocal features,
recognised labels, beat events, heart rate from face video.

A library **beside** DeviceCore (the family's device-I/O layer), not above
it: DeviceCore owns the radios the family drives itself over CoreBluetooth;
this repo owns the sensors the OS has already terminated and hands over as
buffers.

## What works today

Two capture → reducer paths, both validated on real hardware or real audio:

- **Microphone → word spotting.** `MicrophoneCapture` (explicit arm/disarm,
  drop-oldest chunk stream, published input level) feeding `WordSpotter`
  (SpeechTranscriber, word-onset timestamps; gated macOS 26 / iOS 26), with
  the pure pieces under them testable at the platform floor.
- **System audio → beat tracking** (macOS 14.4+). `ProcessTapCapture` taps
  one process's decoded output via a Core Audio process tap — pre-system-
  volume, player-agnostic. The DSP cores (`OnsetEnvelope`, `estimateTempo`,
  `beatTimesDP`, `BeatPhasePredictor` — ported from Ellis 2007 and Stark,
  Davies & Plumbley 2009, from the papers, never from GPL code) feed the
  `BeatTracker` reducer: plain `(time, period, confidence)` beat events,
  each predicted ~300 ms before it lands. Bench record in
  [SPOTIFY-BEAT.md](SPOTIFY-BEAT.md); design, references and constants in
  [BEAT-TRACKING.md](BEAT-TRACKING.md).

Try the beat path against whatever is playing (macOS):

```sh
swift run tap-probe --click   # taps Spotify by default, clicks on predicted beats
```

## Using the package

```swift
.package(url: "https://github.com/PhysiologyWorkbench/MediaKit", from: "0.1.0")
```

Platform floors macOS 14 / iOS 17, Swift 6 language mode, strict concurrency.
The library builds on both platforms; capture sources that need more are
availability-gated (`ProcessTapCapture` macOS 14.4, `WordSpotter`
macOS 26 / iOS 26) and everything under them compiles and tests at the floor:

```sh
swift build && swift test   # no hardware, no OS 26 needed
```

## Rules this library enforces

- **Nothing captures as a side effect.** Capture is armed explicitly, and a
  live input level is published while armed — a hot microphone is legible as
  movement, not as a label claiming it is on.
- **Drop, never queue.** Backpressure on buffer fan-out is drop-oldest; a
  reducer that cannot keep up loses frames, not currency.
- **Plain data out.** Runs of `Double`s and `(time, label, confidence)`
  events; no app vocabulary, no framework types across the boundary.
- **Reducers replay.** Every reducer runs over a recorded sidecar exactly as
  over live capture.
- **Port from papers, not from GPL code.** Every own algorithm carries its
  citation; GPL reference implementations are never consulted.

## Records

[ARCHITECTURE.md](ARCHITECTURE.md) — the design and the reducer survey.
[BEAT-TRACKING.md](BEAT-TRACKING.md) — the beat stack's study and lessons.
[LESSONS.md](LESSONS.md) — dated lessons.
Contributor and agent orientation in [CLAUDE.md](CLAUDE.md);
contribution basics in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
