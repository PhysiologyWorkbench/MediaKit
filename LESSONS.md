# LESSONS — MediaKit

Dated, high-level lessons. Detail and provenance for the beat stack live in
[BEAT-TRACKING.md](BEAT-TRACKING.md) and [SPOTIFY-BEAT.md](SPOTIFY-BEAT.md).

- **2026-08-16 — App Nap corrupts capture invisibly.** A throttled CLI gets
  stretched audio with *continuous sample time*: no gap fires, tempo reads
  ~0.1 BPM low, phase drifts ~68 ms/min. Hold
  `ProcessInfo.beginActivity([.userInitiated, .latencyCritical])` for any
  capture's lifetime, or be a foreground app.
- **2026-08-17 — the composition breaks where the components don't.** Three
  real-music defects (warm-start decay, octave flip on alternate-beat bass,
  rubato click leakage) each lived between units that passed their own tests.
  Write loop-level tests over the full envelope→retune→predictor wiring, not
  only per-component ones. (BEAT-TRACKING.md §What we learned.)
- **2026-08-17 — by-ear verification fails on real music.** Compare live
  emitted beats against the hindsight DP grid on the same envelope clock
  instead; it needs no ear, no wall clock, no anchor.
- **2026-08-17 — synthetic DSP tests must respect lag quantisation.** At
  93.75 fps a 121 BPM period smears across two autocorrelation lags and a
  correct octave test fails for a reason no real envelope reproduces; pick
  frame rates that put the tested periods on integer lags.
- **2026-08-17 — hand-tuned thresholds are the fragility.** Every robustness
  patch to the beat stack became another empirical constant; the fragility
  list in BEAT-TRACKING.md is the inventory, and the rewrite direction (a
  probabilistic tempo–phase tracker) is recorded there.
