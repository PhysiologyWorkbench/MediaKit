# CLAUDE.md — MediaKit

## What this is

The media plane for the Physiology Workbench family: capture of OS-mediated
sensors (camera, microphone, motion), fan-out of the high-volume buffers to
reducers, and the reducers that turn them into low-volume plain-data streams —
pose skeletons, breath and vocal features, recognised labels, heart rate from
face video.

It is a library **beside `DeviceCore`**, never above or below it. DeviceCore
owns the radios this family drives itself over CoreBluetooth; this repo owns
the sensors the OS has already terminated — a standard BLE microphone never
reaches CoreBluetooth (LE Audio is terminated by the OS and surfaces as an
audio input device), and external cameras and glasses arrive the same way.
That fact is why this repo exists instead of a DeviceCore extension.

## Status

**Design record only — no code, no Package.swift yet.** The design was settled
by argument on 2026-08-12 and is in [ARCHITECTURE.md](ARCHITECTURE.md); the
build order was not, so there is no ROADMAP. The first act of code here should
also settle the package's platform floors (SpeechAnalyzer wants macOS/iOS 26;
everything else reaches back years).

## Constraints

- **macOS and iOS are both hard requirements**, as everywhere in the family.
- Swift 6 language mode, strict concurrency, when code arrives.
- **Outputs are plain data** — runs of `Double`s and `(time, label,
  confidence)` events. App-domain channel names never appear here; nothing in
  this family depends on the app.

## Dependencies

None in the family, by design: this repo ends at plain data, and the adapters
into the app's channel vocabulary are the app's.

OS frameworks carry the load: AVFoundation, Vision, Speech, SoundAnalysis,
CoreMotion, Accelerate. Third-party only by exception, each argued in
ARCHITECTURE.md: WhisperKit (MIT) if Apple's speech stack fails on Sanskrit
vocabulary; MediaPipe Pose (Apache-2.0, CocoaPods friction) only if Vision's
19 keypoints demonstrably fail an asana that matters.

Sibling repos, all directly under the same parent: `DeviceCore`, `LovenseKit`,
`PolarKit`, `SatisfyerKit`, `PhysioKit`, `Hdf5Store`, `SwiftLSL`, `PWB`. **The
directory names are load-bearing** — SwiftPM derives a path dependency's
package identity from the directory basename, not from the manifest's `name:`.
When the app consumes this repo it will be by path pre-publication, and this
repo is a leaf in the family's C2 path→URL switch (see the PWB repo's
CLAUDE.md): tag `0.1.0` first, then dependents move to
`.package(url: "https://github.com/PhysiologyWorkbench/MediaKit", from: "0.1.0")`.

## Rules this repo enforces

- **Nothing captures as a side effect.** Opening a view never starts a camera
  or a microphone; capture is armed explicitly and is visible while armed. The
  mirror image of the family's "nothing actuates as a side effect".
- **Drop, never queue.** Backpressure on the buffer fan-out is drop-oldest; a
  reducer that cannot keep up loses frames, not currency.
- **Raw media never lands in HDF5.** Derived streams do; raw AV is a sidecar,
  armed separately, default off. Raw audio/video of a session is categorically
  more sensitive than anything else this family records.
- **Reducers replay.** Every reducer must run over a recorded sidecar exactly
  as over live capture — that is this plane's replay ≡ live, and how a better
  model re-runs over an old session.
- **Port from papers, not from GPL code.** rPPG (POS, CHROM) is ported from
  the publications with provenance pinned, PhysioKit-style; the Python research
  toolboxes are validation oracles only.

## Design record

[ARCHITECTURE.md](ARCHITECTURE.md) — the two-plane design, the reducer survey
with engine choices, and the open questions (feature order first among them).
[LESSONS.md](LESSONS.md) — dated lessons; none yet.
The system-wide picture is in the **PWB** repo's ARCHITECTURE.md; the device
I/O layer this repo sits beside is in **DeviceCore**'s.
