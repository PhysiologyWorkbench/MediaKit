# Architecture — MediaKit

The media plane of the Physiology Workbench family: capture of OS-mediated
sensors, fan-out of high-volume buffers to reducers, and the reducers that turn
those buffers into low-volume plain-data streams. The signal plane — the app's
`SampleSource` → `Pipeline` substrate — is unchanged by this repo's existence;
everything here ends where plain data begins.

This document is the durable design of **this library**, written before any of
it was code — deliberately, because the shape was settled by argument
(2026-08-12) and the build order was not. The first code (same date) is the
microphone-capture → word-spotter path serving PWB's voice annotations; the
rest remains design. The system-wide picture is in the **PWB** repo's
ARCHITECTURE.md. There is no ROADMAP yet; the feature order is an open
question below, not an accident.

## Where this sits

```
┌────────────────────────────────────────────────────────────┐
│ Apps  (SwiftUI, macOS + iOS)                               │
│   thin adapters: MediaKit plain data → app channel names   │
├────────────────────────────────────────────────────────────┤
│ MediaKit — the media plane                                 │
│   capture (camera / mic / motion)                          │
│     → buffer fan-out (shared, refcounted, drop-oldest)     │
│       → reducers (pose, speech, sound, envelope, rPPG, …)  │
│         → plain data out: runs of Doubles, label events    │
├────────────────────────────────────────────────────────────┤
│ AVFoundation · Vision · Speech · SoundAnalysis ·           │
│ CoreMotion · Accelerate                                    │
└────────────────────────────────────────────────────────────┘
```

Beside DeviceCore, never above or below it. The cut between the two:

- **Radios this family drives itself** — CoreBluetooth, vendor kits,
  `DeviceSession` — are DeviceCore's.
- **Sensors the OS has already terminated** are this repo's. A standard BLE
  microphone never reaches CoreBluetooth on Apple platforms: LE Audio is
  terminated by the OS and surfaces as an ordinary audio input device. The same
  holds for external and Continuity cameras, and for whatever AV glasses ship.
  Built-in versus external is **not** the cut — an LE Audio mic, a UVC webcam
  and the built-in camera all go through identical AVFoundation code, and
  CoreMotion mediates the IMU the same way.

If a bespoke GATT device ever streams audio, it is a vendor kit over DeviceCore
like any other, feeding this plane's reducers from the far side. The cut holds.

## Two planes, deliberately different economics

The family's scalar pipeline is synchronous, ordered, MainActor, lossless —
correct at physiology rates, and wrong for buffers three orders of magnitude
denser. This plane inverts every one of those properties:

- **Fan-out shares, never copies.** Reducers hold refcounted buffers
  (`CMSampleBuffer`, PCM); each runs on its own queue at its own cadence.
- **Backpressure is drop-oldest, full stop.** A reducer that cannot keep up
  drops frames rather than queues them. Real-time capture has no other honest
  policy; a queue here is a latency debt that only grows.
- **Each plane has its own raw format and its own replay.** Signals: HDF5,
  replayed through the pipeline. Media: an optional AV sidecar (`.mov`/`.m4a`
  plus a frame-timestamp companion stream in the HDF5), replayed through *the
  reducers* — which is how a better pose model re-runs over last year's
  session, exactly as a better R-peak detector re-runs over an old recording.
- **Latency stratifies by consumer.** A calibration envelope is milliseconds;
  pose is a frame; a speech label is seconds late and correctly so. The
  family's rule — a derived value carries its age — covers all of them; each
  consumer sets its own freshness limit.

## The plain-data boundary

This library's outputs are plain data and nothing else:

- **runs** — evenly-sampled `Double` channels (a pose skeleton is a
  multi-channel run at frame rate; an audio envelope is a one-channel run);
- **label events** — `(time, label, confidence)`, the shape of a recognised
  asana, a spotted word, a sound class. Structurally a machine annotation.

App-domain channel names never appear here — the app owns its channel
vocabulary, and nothing in this family depends on the app. The adapters that
map these outputs onto `PhysiologicalSample` / `RegularRun` channels are the
app's, and they are thin by construction.

## Reducers, and whose code they are

The engines were surveyed (2026-08-12); the conclusion is that the reducers
were never going to be our code, with one small exception:

| Stream | Engine | Kind |
| --- | --- | --- |
| Skeleton | Vision body pose (2D/3D requests) | OS |
| Asana label | Create ML action classifier over skeletons, trained on own labelled video | OS tooling, own data |
| Speech → labels | SpeechAnalyzer (macOS/iOS 26+) **or** WhisperKit (MIT) — trial both on Sanskrit vocabulary. The word spotter (built) uses SpeechTranscriber; the Sanskrit trial remains open | OS / OSS |
| Sound classes | SoundAnalysis, plus Create ML custom classifiers | OS |
| Calibration envelope | vDSP band energy / envelope | OS, ~a page |
| rPPG | POS (Wang et al. 2016) and CHROM (de Haan 2013), ported **from the papers**, provenance-pinned | ours, small |
| Steps / cadence | CoreMotion (`CMPedometer`) | OS |

Notes that are decisions, not trivia:

- **rPPG has no adoptable on-device component.** The one Swift SDK is a cloud
  API client — disqualified on privacy before latency. The Python research
  toolboxes are validation oracles only: pyVHR is GPL-3, so porting from its
  code taints; porting from the papers is clean and is the family's PhysioKit
  pattern anyway. The reduction rPPG needs (face ROI → per-frame RGB means) is
  Vision's job; the arithmetic on 30 Hz RGB means is squarely plain-data.
- **MediaPipe Pose (33 landmarks, Apache-2.0) is the fallback**, not the
  default: CocoaPods-only against this family's SwiftPM/XcodeGen setup, and
  converted models run slower than Vision's ANE path. Adopt only if Vision's
  19 keypoints demonstrably fail an asana that matters.
- **A glasses camera sees the world, not the body.** Egocentric step counting
  from video is a research project, not a component. Steps come from the IMU
  via CoreMotion; budget zero code here.

## Capture authority and privacy

The actuation side of this family holds that nothing actuates as a side
effect. This plane's mirror image, held just as hard:

- **Nothing captures as a side effect.** Opening a view never starts a camera
  or a microphone; capture is armed explicitly and is visible while armed.
  Visible means *live*, not merely stated: capture publishes the input level of
  every buffer it takes, so a hot microphone is legible as movement on screen
  rather than as a label claiming it is on. The level is peak magnitude, the
  cheapest honest answer, computed on the tap thread without allocating.
- **Raw media never lands in HDF5.** Derived, low-volume streams do. Raw AV is
  a sidecar, armed separately from the sensor being live, **default off** —
  raw audio and video of a session are categorically more sensitive than any
  RR interval this family records.

## Timebase

`CMSampleBuffer` presentation timestamps and host arrival are the same clock
family, so Hdf5Store's device-clock/arrival fit degenerates pleasantly — this
plane is *easier* to place on the session timebase than BLE, not harder. And it
closes a residual the system record names: cross-device alignment needs a
physical event two sensors both observe. A clap is that event — simultaneous in
audio, ACC and video. Mic plus camera are the alignment oracle the family
currently lacks.

## Open questions

- **Feature order.** Still no ROADMAP. The first consumer turned out to be
  **voice annotations** (2026-08-12) — spoken vocabulary words as subjective
  marks for PWB — not the actuator-calibration mic path the earlier guess
  named; that path remains a likely early follower. What comes after is
  deliberately unset.
- **Platform floors — resolved (2026-08-12).** The package floor is macOS 14 /
  iOS 17: the app's floor, and the family's highest package floor (siblings
  sit at 13/16). Only the speech reducer is gated
  `@available(macOS 26.0, iOS 26.0, *)`; everything else compiles at the floor.
- **Where non-physiology plain-data algorithms live.** Asana classification
  over joint angles is not physiology; whether PhysioKit broadens or a sibling
  appears is a naming question deferred until the code exists.
- **Label events in the family vocabulary — resolved (2026-08-12).**
  `LabelEvent` `(time, label, confidence)` is **this library's** public output
  type; the app's thin adapter maps it onto an app channel (PWB:
  `.voiceAnnotation` → the `voice_annotations` text stream). No family repo
  gained a shared type; nothing here depends on the app.
- **Raw audio's resting place.** A 48 kHz mono regular stream in HDF5 is
  feasible (~350 MB/h at 16-bit) and would make audio fully replay-≡-live; a
  compressed sidecar is smaller and matches video. Undecided, and it can stay
  per-session. Note the consequence already shipped: v1 voice annotations
  record **no raw audio**, so the `voice_annotations` stream is not
  re-derivable — the app replays it from disk like any subjective mark.
