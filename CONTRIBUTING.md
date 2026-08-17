# Contributing

Issues and pull requests are welcome. This is a small package maintained
alongside the rest of the Physiology Workbench family, so responses may be
slow.

## Building

```sh
swift build
swift test        # 38 tests, all synthetic — no hardware, no capture consent
```

CI runs the same on macOS and additionally builds for the iOS simulator;
both platforms are hard requirements. Swift 6 language mode, strict
concurrency.

## House rules

The ones a patch is most likely to trip over. The reasoning behind them is
in [ARCHITECTURE.md](ARCHITECTURE.md) and [LESSONS.md](LESSONS.md).

- **Port from papers, not from GPL code.** Own algorithms carry their
  citation in the source doc comment (see `BeatAnalysis.swift`); GPL
  reference implementations (BTrack, aubio, pyVHR, …) must not be read,
  let alone ported. [BEAT-TRACKING.md](BEAT-TRACKING.md) records which
  oracles are clean.
- **Nothing captures as a side effect.** No capture starts because a view
  appeared or an object initialised; arm/disarm is explicit, and capture
  publishes its input level while armed.
- **Drop, never queue.** Buffer fan-out is drop-oldest
  (`.bufferingNewest`); adding a queue is a latency debt, not a fix.
- **Plain data across the boundary.** Runs of `Double`s and
  `(time, label, confidence)` events out; no app channel names, nothing
  that couldn't cross to another language.
- **Reducers replay.** A reducer consumes a stream it does not own, so a
  recorded sidecar replays through it exactly as live capture ran.
- **Test the loop, not just the parts.** The beat stack's real defects
  lived between components that each passed their own tests; changes to a
  reducer chain need a loop-level test (see `BeatTrackerLoopTests`).
- **Empirical constants are provenance-pinned.** The beat stack's constants
  are inventoried in BEAT-TRACKING.md with their origin (paper, bench,
  guess); a patch changing one updates that table in the same commit.
