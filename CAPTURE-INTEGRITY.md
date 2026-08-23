# CAPTURE-INTEGRITY — App Nap, clocks, and the Apple-guideline audit

Written 2026-08-17, after the spike closed: what the capture path should
change in its handling of throttling-induced gaps, and the verdict of an
audit against Apple's real-time AV guidance. Items 1–5 landed 2026-08-19
(last section); the deviations below are recorded as they stood, since the
reasoning is what outlives them. Bench evidence is in
[SPOTIFY-BEAT.md](SPOTIFY-BEAT.md); the lesson entry is LESSONS.md
2026-08-16.

## The problem, restated as two classes

1. **Visible gaps.** The consumer stalls, the drop-oldest buffers shed
   chunks, `chunk.start` deltas fire; the probe restarts the tracker on a
   gap > 250 ms. Detected and recovered today — but only in the probe.
2. **Invisible corruption.** A napped process receives stretched/dropped
   audio with *continuous sample time*: no gap fires; the only symptoms
   were tempo ~0.1 BPM low and click phase drifting ~68 ms/min (≈ 1100 ppm
   of clock skew, against the ppm-level drift of genuine clocks).

Why the second class can exist at all: the aggregate device is created by
and hosted in the capturing process, so throttling the process throttles
the device's IO machinery itself, and the sample clock it synthesises
stays continuous while real time runs ahead. A hardware-clocked device
cannot do this — which is why the microphone path (AVAudioEngine over a
real input device) is exposed only to class 1, while the process tap is
exposed to both. (Mechanism inferred from the symptoms, not documented by
Apple.)

## Verdict against Apple guidance

Conforms:

- **The capture route.** Core Audio process taps (macOS 14.4+) are Apple's
  documented system-audio-capture API; the chain and the strict-reverse
  teardown in `ProcessTapCapture` follow it. ScreenCaptureKit audio is the
  older alternative and buys nothing here.
- **The App Nap countermeasure.**
  `ProcessInfo.beginActivity([.userInitiated, .latencyCritical])` is
  exactly the mechanism the Energy Efficiency Guide for Mac Apps
  prescribes; `.latencyCritical` is documented for audio/video work and is
  meant to be paired with a user-initiated option. The probe's usage —
  held for the capture's lifetime — matches.
- **Real-time rules.** The IO block runs on a private dispatch queue
  (`AudioDeviceCreateIOProcIDWithBlock`), not the HAL real-time thread, so
  the relay's per-callback allocation and copy are legitimate. If the
  relay ever moves to the function-pointer IOProc on the real-time thread,
  it must be rewritten allocation-free.

Deviations, in order of consequence:

1. **`mHostTime` is discarded.** The relay reads `mSampleTime` only and
   anchors to a first-callback `Date()` (`AudioClockAnchor`). Core Audio's
   canonical timestamp is the *(sampleTime, hostTime)* pair; host time is
   the monotonic mach clock Apple's AV-sync guidance keys to. The skew
   between the two clocks is the **only observable signature of class 2**,
   arrives at every callback, and is currently thrown away. Secondary
   costs of the current anchor: `Date()` is a steppable wall clock, and
   the anchor absorbs the scheduling latency of whichever callback happens
   to be first.
2. **Assertion placement.** The exemption is a documented convention on
   hosts (ARCHITECTURE.md); Apple's guidance is to assert around the work,
   and the library knows the work's extent exactly — `arm()` to
   `disarm()`. A convention is a trap for every future host, and the
   realistic Tactus host runs *occluded behind the player*, so "be a
   foreground app" is not the common case. Scoping the assertion to armed
   capture keeps the no-side-effect rule intact: armed capture is already
   explicit and visible.
3. **IO queue QoS unspecified.** The tap's queue is created with default
   QoS; Apple's QoS guidance gives audio-adjacent queues explicit
   `.userInteractive` to resist throttling and priority inversion.
4. **Gap policy lives only in the probe.** `BeatTracker` documents
   "assumes gapless" but nothing enforces it; the > 250 ms restart is
   homework every host must repeat, though chunks already carry the start
   dates needed to detect the discontinuity in the library.

## Alternatives considered

Prevention:

- `beginActivity` for the capture's lifetime — **keep**; move into
  `ProcessTapCapture.arm()`/`disarm()` (deviation 2). Also correct for
  `MicrophoneCapture` when hosted by a background process, though only
  class 1 is at stake there.
- `NSAppSleepDisabled` (Info.plist / defaults) — app-wide, user-overridable,
  not a library's call. Rejected.
- A `caffeinate` wrapper — external, CLI-only. Rejected.

Detection:

- `chunk.start` delta (current, probe) — catches class 1 only.
- **Clock-skew detector** — the missing piece. Keep the per-callback
  *(mSampleTime, mHostTime)* pair; over a window of ~10 s compare the
  implied rates; skew beyond a few hundred ppm is a capture-integrity
  fault (the bench case was ~1100 ppm). Catches class 2 and subsumes any
  heartbeat watchdog.
- Heartbeat watchdog (samples delivered vs host-clock elapsed) — same
  information, coarser; subsumed by the above.

Recovery:

- Segment restart with the tempo prior (current, probe) — cheap,
  bench-proven; the grid store's ≥ 30 s rule already handles the
  fragmented-segment consequence.
- Envelope re-anchor preserving accumulated frames — would keep grid
  eligibility across a gap; more state, worth it only if gaps prove common
  in app use. Deferred.
- Silence infill — invents data; violates refusal-over-invention. Rejected.

## Rewrite?

No. The capture chain is Apple's documented route and the deviations are
local, additive fixes. The beat-stack rewrite direction recorded in
[BEAT-TRACKING.md](BEAT-TRACKING.md) §If rewriting is a separate matter;
every fix below sits under that boundary and survives it.

## The work — items 1–5 done, 2026-08-19

Landed ahead of Tactus Phase 3, which is the first host to depend on it.

1. **Host time is the tap's time base.** `HostClock` maps mach host ticks to
   the wall clock through one mapping established at `arm()`, and
   `chunk.start` comes from `mHostTime`. The first-callback
   `AudioClockAnchor` is gone from the tap path — with it the steppable
   `Date` base and the scheduling latency of whichever callback was first.
   (`AudioClockAnchor` remains the microphone relay's; that path is
   hardware-clocked and exposed to class 1 only.)
2. **Clock-skew detection.** The relay keeps the *(mSampleTime, mHostTime)*
   pair and closes a 10 s window at a time, publishing
   `ProcessTapCapture.integrity` — the skew in ppm and a count of windows
   past `skewThresholdPPM` (300; the benched corruption ran at ~1100).
   Detection only: recovery stays the host's.
3. **The activity assertion is the library's.** Held from `arm()` to
   `disarm()` in both `ProcessTapCapture` and `MicrophoneCapture`;
   `tap-probe` no longer takes its own, and the ARCHITECTURE.md host rule is
   now a note that the captures assert for themselves.
4. **IO queue QoS.** The tap's queue is `.userInteractive`.
5. **Gap detection is `BeatTracker`'s.** It sees `chunk.start`, so it is the
   thing that checks its own gapless assumption: `gapCount` and `lastGap`
   report every discrepancy past `gapTolerance` (2 ms). The probe keeps only
   the policy — restart the segment past 250 ms — and reads the detection
   instead of repeating it.

Regression tests: `HostClockTests` (mapping both ways, timebase sanity, and
the benched ~1100 ppm recovered from the skew arithmetic) and
`BeatTrackerGapTests` (continuous stream, shed buffer, sub-tolerance jitter).
50 tests pass.

One consequence worth naming, because it changes what a gap means: with
`chunk.start` derived from host time and the envelope clock still counting
frames, sustained class-2 skew now leaks into chunk-start deltas as well.
It leaks slowly — 1100 ppm across a 21 ms chunk is 0.023 ms, far under the
2 ms tolerance, and `expectedNextStart` re-bases every chunk so it never
accumulates. The 10 s skew window remains the only detector that sees it.
Which leaves:

6. Re-run the App Nap leg of the bench protocol (SPOTIFY-BEAT.md,
   2026-08-16) with the assertion *removed*, to confirm the skew detector
   fires where gap detection went blind. Owner-bench, MediaKit's own; not a
   Tactus Phase 3 prerequisite, since with the assertion in place class 2
   should not arise and item 2 makes it visible in the run log if it does.
