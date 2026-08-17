# SPOTIFY-BEAT — system-audio capture and beat tracking, a spike

Tactus needs beat-phase-accurate rhythm from music the owner plays in Spotify.
Offline downloads are DRM-closed and the Web API's audio-analysis endpoints
died in November 2024; the surviving route is a **Core Audio process tap**
(macOS 14.4+) on the player process, which delivers decoded PCM
player-agnostically. Audio arrives at 1×, so the design is analyse-once,
cache-the-grid: recognise the track via the Spotify metadata channel, persist
the derived beat grid, use it as a tempo prior on later plays.

This is a spike with a kill switch. Docs (ARCHITECTURE.md, Tactus SCOPE.md and
ROADMAP.md) are updated only after the owner judges the bench results good
enough. Plan of record: `~/.claude/plans/lively-dancing-key.md`.

## What exists

- `ProcessTapCapture` — arm/disarm capture of one process's audio via
  `CATapDescription` → private tap → private aggregate device. macOS-only,
  gated `@available(macOS 14.4, *)`; package floor unchanged.
- DSP cores, Accelerate-only, ported from papers (never GPL code):
  `OnsetEnvelope` (40–150 Hz flux, ~94 Hz at 48 k), `estimateTempo`
  (autocorrelation, octave-folded 60–180 BPM, refuses on weak evidence),
  `beatTimesDP` (Ellis, J. New Music Research 2007), `BeatPhasePredictor`
  (causal, 300 ms horizon; concepts from Stark, Davies & Plumbley, DAFx 2009).
- `BeatTracker` — the reducer: chunk stream in, `BeatEvent` out,
  `envelopeSnapshot()` for offline grid computation. Replay ≡ live.
- `Sources/tap-probe/` — bench harness; all Spotify-specific code lives there
  (notification channel, AppleScript fallback, JSON grid store, `--click`,
  `--csv`, `--measure-position`). See its README.
- 38 tests, 9 suites, no hardware needed, including a five-minute synthetic
  phase-lock regression over the full envelope→retune→predictor loop.

## Bench record, 2026-08-16 (120 BPM metronome track)

- Tap armed without TCC friction; no fallback rung from the probe README was
  needed. Sustained capture 94 buf/s, five minutes with zero frame gaps.
- Tempo lock 119.9–120.1 BPM at confidence 0.99–1.00 within seconds; clicks
  judged on-beat by ear; no drift after the fixes below.
- The notification payload's `Duration` is **milliseconds** (598500 for the
  598.5 s track); the probe's >10 000 heuristic is right.
- **App Nap lesson.** Un-asserted, a background CLI gets throttled and the tap
  silently drops/stretches audio with *continuous sample time* — invisible to
  gap detection. Symptoms: tempo biased to ~119.86, click phase drifting
  ~68 ms/min. Fix: hold
  `ProcessInfo.beginActivity([.userInitiated, .latencyCritical])` for the
  capture's lifetime. Any host of `ProcessTapCapture` needs this or must be a
  foreground app. Bigger stalls (App-switch burst, ~4 s lost) additionally
  need the probe's gap-restart: a frame gap > 250 ms re-anchors the tracker.
- **Repeat-one posts no notification** at the loop boundary; the predictor
  re-locks within seconds, but a grid must come from a segment ended by pause
  or track change, never one spanning a loop.

## Bench record, 2026-08-17 (real music; every protocol leg run)

Three library defects found and fixed, each with a regression test:

- **Warm start died.** After a grid hit the prior (conf 0.40) emitted 2 beats,
  then retunes from a 1–2.4 s window — nil, or octave-folded at conf 0.97 —
  displaced it and the track went silent. Fix: no retune until the envelope
  holds ≥ 4 s. Retest: first click 0.6 s after play versus 3.6 s cold.
- **Alternate-beat bass flips the octave.** "Around the World" locked 121.3,
  then the bassline (alternate beats) made the half-tempo comb genuinely
  stronger: 60.6 BPM, wrong grid saved. Fix: log-Gaussian lag weighting
  centred on 120 BPM, σ 0.9 octaves (Ellis 2007), in the fold scoring only —
  confidence stays the raw correlation. Retest: 121.4 for 78 s, bass present
  throughout.
- **Rubato leaked clicks.** Chopin Nocturne op. 9/2: offline refusal correct,
  but wandering live estimates at conf 0.15–0.23 crested the 0.15 emission
  floor in bursts. Fix: floor raised to 0.25 — measured gap: rubato leaks
  peaked at 0.23, the weakest legitimate groove tested (Superstition, conf
  0.28–0.85, tempo breathing 96.8–102.6) never dipped below 0.28. Retest:
  zero clicks through the whole Nocturne, refusal message at pause.

Verification is log-based, not by-ear (owner's ear low-confidence on real
music): live emitted beats against the hindsight DP grid on the same envelope
clock — Around the World 152/152 beats within 28 ms (median −14 ms);
Superstition 93% within ±70 ms, outliers at the breaks.

Other legs: grid save/hit on the metronome (119.9 BPM, conf 0.99; warm lock
0.6 s). Volume independence: system output volume invisible to the tap (peak
flat while swept); Spotify's own slider swept to zero and back moved peak
0.00–0.12 while lock held at conf ≥ 0.59, no beat interval above 0.52 s.
AppleScript `player position`: worst position-vs-wall jitter 68 ms over 50
polls, mean `osascript` round trip 217 ms (spikes to 837 ms) — treat a polled
position as ±100 ms and never poll on the beat path.

## Still open

The owner's verdict: good enough → docs step (MediaKit ARCHITECTURE/CLAUDE,
Tactus SCOPE/ROADMAP, board card) — not → scrap, per the plan.
