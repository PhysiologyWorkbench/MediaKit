# BEAT-TRACKING — study, implementation, and lessons

Background for a potential re-implementation of the beat stack, written
2026-08-17 at the close of the Spotify spike. The spike's decision record and
bench numbers are in [SPOTIFY-BEAT.md](SPOTIFY-BEAT.md); this file is what a
rewrite would want to know before touching anything: what was studied, what
was built and why it is shaped that way, and which parts are load-bearing
versus merely first-attempt.

## What was studied

### Routes to Spotify audio

- **Spotify Web API audio-analysis** (per-track beat grids): closed to new
  applications since November 2024. Dead.
- **Offline downloads**: DRM-sealed against sample access. Dead.
- **AppleScript** (`tell application "Spotify"`): track identity, play state,
  `player position`. Measured 2026-08-17: position tracks wall clock within
  68 ms worst-case over 50 polls, but each `osascript` round trip costs
  ~217 ms with spikes to 837 ms. Verdict: metadata and a ±100 ms anchor, never
  a beat-phase source.
- **Core Audio process taps** (macOS 14.4+) — the route that works. Decoded
  PCM of one process's output, pre-system-volume, player-agnostic. Chain:
  `NSRunningApplication` → pid → `kAudioHardwarePropertyTranslatePIDToProcessObject`
  → `CATapDescription(stereoMixdownOfProcesses:)` (private, unmuted) →
  `AudioHardwareCreateProcessTap` → private aggregate device with
  `kAudioAggregateDeviceTapListKey` and tap-auto-start →
  `AudioDeviceCreateIOProcIDWithBlock`. Teardown strictly in reverse: stop
  device, destroy IOProc, aggregate, tap. One TCC consent ("System Audio
  Recording"), no pre-flight API; a bare SwiftPM CLI got the prompt attributed
  to the terminal without friction. ScreenCaptureKit audio (macOS 13+) is the
  fallback API for the same capability; it was not needed.

### Track recognition channels

- `DistributedNotificationCenter`, `com.spotify.client.PlaybackStateChanged`:
  exact track URI, name, artist, state, position. Unofficial, decade-stable.
  Traps: `Duration` is **milliseconds**; **repeat-one posts nothing** at the
  loop boundary.
- ShazamKit `SHCustomCatalog` fingerprinting is the future player-agnostic
  recognition route — documented, deliberately not built.

### Algorithms, ported from papers (never GPL code — house rule)

- **D. P. W. Ellis, "Beat Tracking by Dynamic Programming", Journal of New
  Music Research 36(1), 2007.** Source of `beatTimesDP` (offline exact grid:
  cumulative score with squared-log period penalty, backtrack from the
  strongest ending) and of the log-Gaussian tempo weighting (centred 120 BPM,
  σ 0.9 octaves) later adopted into `estimateTempo`'s octave-fold scoring.
- **M. Stark, M. E. P. Davies, M. D. Plumbley, "Real-Time Beat-Synchronous
  Analysis of Musical Audio", DAFx 2009.** Concepts for `BeatPhasePredictor`
  (causal phase-locked prediction, onset-nudged grid). Their reference
  implementation, BTrack, is GPL-3 and was **not consulted**.
- **Onset detection** is textbook band-limited spectral flux; no single paper
  was ported. A re-implementer wanting the survey should start from Bello et
  al., "A Tutorial on Onset Detection in Music Signals" (IEEE TSAP 13(5),
  2005). The band restriction to 40–150 Hz (kick drum; hi-hats and vocals
  don't vote) comes from Tactus SCOPE.md Leg 2.
- **Alternatives, surveyed and not adopted**, with the licence facts that
  gate them: BTrack (GPL-3), aubio (GPL-3), madmom (custom BSD-style,
  non-commercial clause), Essentia (AGPL-3) — all porting-tainted; usable as
  *validation oracles only*, per the family rule. librosa (ISC) is the clean
  oracle: `librosa.beat.beat_track` is itself Ellis 2007, so it cross-checks
  `beatTimesDP` directly. A probabilistic rewrite (tempo–phase state space,
  HMM or particle filter, cf. Krebs & Böck's downbeat work) would also have
  to be paper-ported; madmom's implementations are off limits as source.

## What was built

The realtime-only constraint (audio arrives at 1×) drove the central design:
**analyse once, cache the grid**. Live playback runs a causal tracker; at
segment end the *whole accumulated envelope* is re-analysed offline
(`beatTimesDP`) and saved per track URI, so the head of the track gets its
beats post-facto in the record even though no click sounded there. On replay
the cached grid supplies a **tempo prior only** — phase always comes from
live onsets, which keeps the loose track-start anchor (notification date −
reported position) out of the beat path entirely.

| Piece | File | One line |
| --- | --- | --- |
| `ProcessTapCapture` | `Sources/MediaKit/ProcessTapCapture.swift` | arm/disarm tap on one process, drop-oldest `AsyncStream<AudioChunk>` (`.bufferingNewest(16)`), published peak level, `@available(macOS 14.4, *)` |
| `OnsetEnvelope` | `Sources/MediaKit/OnsetEnvelope.swift` | streaming Hann + vDSP FFT 4096, hop 512 (≈94 Hz at 48 k), 40–150 Hz log-compressed half-wave flux, one-pole smoothing |
| `estimateTempo` | `Sources/MediaKit/BeatAnalysis.swift` | mean-removed autocorrelation, octave-folded 60–180 BPM, 120-centred log-Gaussian fold scoring, parabolic refinement, refuses below confidence 0.15 |
| `beatTimesDP` | `Sources/MediaKit/BeatAnalysis.swift` | Ellis 2007 offline grid |
| `BeatPhasePredictor` | `Sources/MediaKit/BeatPhasePredictor.swift` | causal predictor: adaptive onset threshold, grid nudged 0.25 of the error, emits `horizon` (300 ms) early, goes silent below confidence 0.25 |
| `BeatTracker` | `Sources/MediaKit/BeatTracker.swift` | the reducer: chunks in, `BeatEvent (time, period, confidence)` out, retune ≥ 1 s cadence over an 8 s window once ≥ 4 s exists, `envelopeSnapshot()` for offline analysis |
| `tap-probe` | `Sources/tap-probe/` | bench harness; **all** Spotify-specific code lives here — notification channel, AppleScript fallback, JSON grid store, `--click`, `--csv`, `--measure-position`, gap-restart > 250 ms, grid only from segments ≥ 30 s |

Tests: 38, no hardware — synthetic click tracks, per-component tests, and
two **loop-level** tests (five-minute phase lock; warm-start survival) that
exist because both of their bugs were invisible at unit level.

## What we learned

The bench records live in SPOTIFY-BEAT.md (2026-08-16 metronome,
2026-08-17 real music). Distilled for a re-implementer:

1. **The tap route is solid.** 94 buf/s sustained, gap-free for minutes at a
   stretch; TCC friction zero. Capture is pre-system-volume; the player's own
   slider changes amplitude but log-compressed flux plus normalised
   autocorrelation kept lock even near-muted.
2. **App Nap is the nastiest trap in the whole stack.** A throttled process
   receives stretched/dropped audio with *continuous sample time* — invisible
   to gap detection; the only symptoms were tempo biased ~0.1 BPM low and
   phase drifting ~68 ms/min. Any host of the tap must hold
   `ProcessInfo.beginActivity([.userInitiated, .latencyCritical])` or be a
   foreground app.
3. **The composition breaks where the components don't.** All three defects
   found on real music lived *between* correct units: (a) retunes from a
   too-short window (nil, or octave-folded at confidence 0.97) destroyed the
   warm-start prior — fixed by refusing to retune before 4 s of envelope;
   (b) an alternate-beat bassline makes the half-tempo comb *genuinely
   stronger*, so pure comb energy octave-flips mid-track — fixed by the
   Ellis tempo weighting, applied to the fold *score* while confidence stays
   the raw correlation; (c) rubato piano leaked weak wandering estimates
   through the emission floor — fixed by calibrating the floor into the
   measured gap (leaks peaked at 0.23; the weakest real groove tested never
   dipped below 0.28). Test the loop, not just the parts.
4. **By-ear verification fails on real music** (owner's own assessment).
   The method that works: compare live emitted beats against the hindsight
   DP grid on the same envelope clock — no ear, no wall clock, no anchor
   involved. Numbers achieved: 152/152 beats within 28 ms on steady
   electronic; 93 % within ±70 ms on funk with the outliers at the breaks.
5. **Synthetic tests have a quantisation trap.** At 93.75 fps a 121 BPM
   period (46.49 frames) smears its autocorrelation across two lags (~0.41
   each) while its half tempo (~93.0 frames) scores 1.0 — a synthetic
   octave test at that rate fails for a reason no real envelope reproduces.
   Use a frame rate that puts both folds on integer lags.
6. **Refusal over invention holds all the way up.** `estimateTempo` returns
   nil on weak evidence, the predictor goes silent below the floor, the grid
   store refuses segments under 30 s and segments that never locked. Chopin
   op. 9/2 produced zero clicks and no grid — correct behaviour, achieved
   only after calibration (point 3c).

### The hand-tuned constants — the fragility list

Every one of these is empirical. A rewrite inherits the *reasons*, not the
values; anything marked *bench* was calibrated against exactly one bench and
would need re-calibration in a new design.

| Constant | Value | Where | Provenance |
| --- | --- | --- | --- |
| FFT / hop | 4096 / 512 | OnsetEnvelope | standard; ≈94 Hz envelope at 48 k |
| Flux band | 40–150 Hz | OnsetEnvelope | Tactus SCOPE Leg 2 (kick band) |
| Envelope smoothing | one-pole, 0.5 | OnsetEnvelope | guess, unexamined |
| Tempo band | 60–180 BPM | estimateTempo | design (hip-rate band) |
| Fold weighting | centre 120 BPM, σ 0.9 oct | estimateTempo | Ellis 2007; σ re-checked at bench |
| Tempo refusal floor | 0.15 | estimateTempo | guess, survived bench |
| Retune cadence / window / minimum | 1 s / 8 s / 4 s | BeatTracker | cadence+window guess; minimum **bench** (warm-start defect) |
| Onset threshold | mean + 2.5·dev, EMA α 0.02 | BeatPhasePredictor | guess, survived bench |
| Phase nudge / gate | 0.25 of error / 0.3 period | BeatPhasePredictor | Stark et al. flavour, values guess |
| Support decay grace | 1.5 periods | BeatPhasePredictor | guess |
| Emission floor | 0.25 | BeatPhasePredictor | **bench** (0.23 leak vs 0.28 groove) |
| Prior confidence | 0.40 | BeatPhasePredictor | guess; sustains emission with onset support |
| DP tightness | 100 | beatTimesDP | Ellis 2007 |
| Gap restart | > 250 ms | tap-probe | guess, survived bench |
| Grid minimum segment | 30 s | tap-probe | guess |
| Capture buffering | newest 16 | ProcessTapCapture | family drop-oldest rule |

## If rewriting

Keep the boundary and the invariants; they are the part that proved right:

- `BeatEvent (time, period, confidence)` plain data out; app-domain names
  stay out of the library; all player-specific code stays in the probe/app.
- Explicit arm/disarm, published level, drop-oldest — the family rules.
- Replay ≡ live: the reducer consumes a chunk stream it does not own.
- Refusal over invention, at every layer.
- Analyse-once-cache-the-grid, grid as tempo prior only, phase from live
  onsets — this decoupling is what made the loose Spotify anchor harmless.
- The verification method (live vs hindsight grid) and the bench protocol in
  SPOTIFY-BEAT.md as the acceptance suite; the loop-level tests and the
  bench-derived regression tests carry the three defect classes forward.

Where the current implementation is weakest, and what a rewrite would
change: the tempo path is a single autocorrelation estimate re-taken every
second with no memory — every robustness problem was patched with another
hand constant (the fragility list above). The literature answer is a
probabilistic tracker: a joint tempo–phase state space with transition
priors, which gets tempo continuity, octave hysteresis and graceful rubato
degradation from one mechanism instead of three thresholds. Port it from
papers (Krebs, Böck et al. on HMM beat/downbeat tracking); validate against
librosa as the clean oracle; expect the emission-floor calibration to be
replaced by a posterior-probability threshold with actual semantics.
