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
- 36 tests, 9 suites, no hardware needed, including a five-minute synthetic
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

## Still open at the bench

Grid save on pause (≥ 30 s) and replay grid-hit with faster lock; the
drum-forward electronic, funk and rubato tracks (rubato must refuse, not
invent); volume-independence; `swift run tap-probe --measure-position` for the
AppleScript position-precision number Tactus ROADMAP Phase 3 wants. Then the
owner's verdict: good enough → docs step; not → scrap, per the plan.
