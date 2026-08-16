# tap-probe

Bench harness for `ProcessTapCapture` + `BeatTracker` against the Spotify
desktop client. Spotify-specific code lives here, not in MediaKit — the
library stays player-agnostic.

## Usage

```sh
swift run tap-probe [--click] [--csv] [--grids <dir>] [--bundle <id>] \
                    [--measure-position]
```

- `--click` — play a system click at each predicted beat (the by-ear check).
- `--csv` — on segment end, dump `<uri>.envelope.csv` and `<uri>.beats.csv`
  beside the grid for plotting.
- `--grids <dir>` — grid cache directory (default `.tap-probe-grids/`).
- `--bundle <id>` — process to tap (default `com.spotify.client`).
- `--measure-position` — poll the AppleScript `player position` for 10 s and
  report its precision, latency and jitter, then exit. Tactus ROADMAP Phase 3
  wants these numbers.

Start Spotify, play something, run the probe. One line per predicted beat
(track time, BPM, confidence, lead), a capture-health line every 2 s
(buffers/s, level, frame gaps). At track end / pause / track change the
accumulated envelope is analysed offline (Ellis DP) and the beat grid saved
as JSON keyed by track URI; replaying the same track logs a grid hit and
feeds the cached BPM as a prior. A seek restarts the tracker without saving.
Segments under 30 s are discarded. Quit with Ctrl-C — the current segment's
grid is *not* saved then; let the track end first.

## TCC (system-audio recording permission)

The first `AudioHardwareCreateProcessTap` call ever made by a binary triggers
the "System Audio Recording" consent prompt; there is no pre-flight API. For
a bare SwiftPM executable the prompt should attribute to the parent terminal.
If no prompt appears and arming fails as denied:

1. Check System Settings → Privacy & Security → Screen & System Audio
   Recording; add or enable the terminal there.
2. Failing that, embed an `Info.plist` in the binary — add to the target:
   `linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker",
   "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "path/to/Info.plist"])]`
   with `NSAudioCaptureUsageDescription` set.
3. Last resort: wrap the binary in a minimal `.app` bundle.

Record at the bench which of these was needed, and whether the denial really
surfaces as `kAudioHardwareIllegalOperationError` (the mapping in
`ProcessTapCapture` assumes so).

## Bench protocol

See the plan: metronome track at 120 BPM, a drum-forward electronic track, a
funk track, and something rubato that should fail silently. Acceptance:
≥ 5 min capture with zero frame gaps; ±2 BPM lock within ~10 s on steady
tracks; `--click` audibly on the beat; rubato refuses rather than invents;
grid saved and grid-hit logged on replay; position precision measured;
analysis unaffected by output volume.
