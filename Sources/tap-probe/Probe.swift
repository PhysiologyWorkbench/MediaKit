#if os(macOS)
import AppKit
import Foundation
import MediaKit

struct Options {
    var click = false
    var csv = false
    var gridsDirectory = URL(filePath: ".tap-probe-grids")
    var bundleIdentifier = "com.spotify.client"
    var measurePosition = false

    static func parse(_ arguments: ArraySlice<String>) -> Options {
        var options = Options()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--click": options.click = true
            case "--csv": options.csv = true
            case "--measure-position": options.measurePosition = true
            case "--grids":
                guard let path = iterator.next() else { usage() }
                options.gridsDirectory = URL(filePath: path)
            case "--bundle":
                guard let id = iterator.next() else { usage() }
                options.bundleIdentifier = id
            default:
                usage()
            }
        }
        return options
    }

    private static func usage() -> Never {
        print("""
        usage: tap-probe [--click] [--csv] [--grids <dir>] [--bundle <id>] \
        [--measure-position]
        """)
        exit(2)
    }
}

@main
struct Probe {
    @MainActor
    static func main() async {
        let options = Options.parse(CommandLine.arguments.dropFirst())
        if options.measurePosition {
            await measurePositionPrecision()
            return
        }
        guard #available(macOS 14.4, *) else {
            print("tap-probe needs macOS 14.4 for Core Audio process taps.")
            exit(1)
        }
        await ProbeSession(options: options).run()
    }

    /// Tactus ROADMAP Phase 3 wants this number: the actual precision of the
    /// AppleScript `player position` channel.
    @MainActor
    private static func measurePositionPrecision() async {
        print("polling `player position` every 200 ms, 50 samples…")
        var samples: [(wall: Date, position: Double, latency: TimeInterval)] = []
        for _ in 0..<50 {
            let before = Date()
            if let position = SpotifyScripting.playerPosition() {
                let after = Date()
                samples.append((after, position, after.timeIntervalSince(before)))
                print(String(format: "  %.6f  (call took %.0f ms)",
                             position, samples.last!.latency * 1000))
            } else {
                print("  no reading — is Spotify running?")
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard samples.count > 2 else { return }
        let increments = zip(samples.dropFirst(), samples)
            .map { $0.position - $1.position }
            .filter { $0 > 0 }
        let jitters = zip(samples.dropFirst(), samples).map {
            abs(($0.position - $1.position) - $0.wall.timeIntervalSince($1.wall))
        }
        let meanLatency = samples.map(\.latency).reduce(0, +) / Double(samples.count)
        print(String(format: """
        distinct increments: smallest %.6f s of %d positive
        worst position-vs-wall-clock jitter: %.1f ms
        mean osascript round trip: %.0f ms
        """, increments.min() ?? 0, increments.count,
        (jitters.max() ?? 0) * 1000, meanLatency * 1000))
    }
}

/// One armed tap on the player, one `BeatTracker` per playback segment. The
/// capture stream is single-consumer and its termination would disarm the
/// tap, so the session iterates it once and forwards chunks into a fresh
/// per-segment stream — trackers come and go, the tap stays armed.
@available(macOS 14.4, *)
@MainActor
final class ProbeSession {
    private let options: Options
    private let store: GridStore
    private let capture = ProcessTapCapture()
    private let clickSound = NSSound(named: "Tink")

    private struct Segment {
        let uri: String
        let name: String
        let artist: String
        let duration: TimeInterval?
        /// Host date of the track's 0:00, from the event's reported position.
        let trackStart: Date
        let tracker: BeatTracker
        let continuation: AsyncStream<AudioChunk>.Continuation
        let beatTask: Task<Void, Never>
    }

    private var segment: Segment?

    // Capture health.
    private var buffers = 0
    private var gaps = 0
    private var peakLevel: Float = 0
    private var lastActedGap: BeatTracker.StreamGap?
    private var lastHealthReport = Date()

    init(options: Options) {
        self.options = options
        store = GridStore(directory: options.gridsDirectory)
    }

    func run() async {
        let chunks: AsyncStream<AudioChunk>
        do {
            chunks = try capture.arm(bundleIdentifier: options.bundleIdentifier)
        } catch ProcessTapCapture.CaptureError.processNotFound(let bundle) {
            print("\(bundle) is not running — start it, play something, retry.")
            exit(1)
        } catch ProcessTapCapture.CaptureError.permissionDenied {
            print("""
            System-audio recording permission denied. Grant it under
            System Settings → Privacy & Security → Screen & System Audio
            Recording, then retry. See Sources/tap-probe/README.md if no
            prompt ever appeared.
            """)
            exit(1)
        } catch {
            print("capture failed: \(error)")
            exit(1)
        }
        print("tap armed on \(options.bundleIdentifier); waiting for playback…")

        let nowPlaying = SpotifyNowPlaying()
        if let snapshot = SpotifyScripting.snapshot(), snapshot.state == .playing {
            await handle(event: snapshot)
        }

        let chunkTask = Task { @MainActor in
            for await chunk in chunks { await self.handle(chunk: chunk) }
        }
        let eventTask = Task { @MainActor in
            for await event in nowPlaying.events { await self.handle(event: event) }
        }
        await chunkTask.value
        await eventTask.value
    }

    // MARK: - Audio path

    private func handle(chunk: AudioChunk) async {
        buffers += 1
        segment?.continuation.yield(chunk)
        await actOnGaps()
        // Peak since the last report — the instantaneous level almost always
        // samples the silence between metronome clicks.
        peakLevel = max(peakLevel, capture.level)

        let now = Date()
        if now.timeIntervalSince(lastHealthReport) >= 2 {
            let rate = Double(buffers) / now.timeIntervalSince(lastHealthReport)
            var tracked = "-"
            if let snapshot = segment?.tracker.envelopeSnapshot() {
                // Shadow of BeatTracker's own retune input, for bench debugging.
                let window = Array(snapshot.frames.suffix(Int(snapshot.frameRate * 8)))
                let estimate = estimateTempo(envelope: window, frameRate: snapshot.frameRate)
                tracked = String(format: "%.1f s  tempo %@",
                                 Double(snapshot.frames.count) / snapshot.frameRate,
                                 estimate.map { String(format: "%.1f/%.2f", $0.bpm, $0.confidence) } ?? "nil")
            }
            print(String(format: "capture  %.0f buf/s  peak %.2f  gaps %d  skew %.0f ppm  env %@",
                         rate, peakLevel, gaps, capture.integrity.skewPPM, tracked))
            buffers = 0
            peakLevel = 0
            lastHealthReport = now
        }
    }

    /// The tracker detects discontinuities; the policy of what to do about
    /// one is the host's, and this is it. Reported a chunk or two after the
    /// fact, since the segment's tracker consumes the forwarded stream
    /// asynchronously — immaterial to a restart that discards the tracker.
    private func actOnGaps() async {
        guard let current = segment, let gap = current.tracker.lastGap,
              gap != lastActedGap
        else { return }
        lastActedGap = gap
        gaps += 1
        print(String(format: "⚠ frame gap: %.1f ms", gap.seconds * 1000))
        // Lost audio skews the tracker's frame-count clock for good; re-anchor
        // by restarting the segment. trackStart is host-clock and the track
        // kept playing, so it survives the restart.
        if abs(gap.seconds) > 0.25 {
            print("  restarting tracker after capture gap")
            await endSegment(analyse: false)
            beginSegment(uri: current.uri, name: current.name,
                         artist: current.artist, duration: current.duration,
                         trackStart: current.trackStart)
        }
    }

    // MARK: - Playback events

    private func handle(event: PlaybackEvent) async {
        switch event.state {
        case .paused, .stopped:
            if segment != nil {
                print("⏸ \(event.state.rawValue.lowercased()) — closing segment")
                await endSegment(analyse: true)
            }
        case .playing:
            guard let uri = event.trackURI else { return }
            if let current = segment {
                if current.uri != uri {
                    await endSegment(analyse: true)
                } else if let position = event.position {
                    // Same track: a seek breaks the envelope's gapless-clock
                    // assumption, so the segment restarts; a mere metadata
                    // refresh does not.
                    let expected = event.date.timeIntervalSince(current.trackStart)
                    guard abs(position - expected) > 1 else { return }
                    print(String(format: "↷ seek to %.1f s — restarting tracker", position))
                    await endSegment(analyse: false)
                } else {
                    return
                }
            }
            beginSegment(event: event, uri: uri)
        }
    }

    private func beginSegment(event: PlaybackEvent, uri: String) {
        let position = event.position ?? 0
        beginSegment(uri: uri, name: event.name ?? "?", artist: event.artist ?? "?",
                     duration: event.duration,
                     trackStart: event.date.addingTimeInterval(-position))
    }

    private func beginSegment(uri: String, name: String, artist: String,
                              duration: TimeInterval?, trackStart: Date) {
        print(String(format: "▶ %@ — %@ (%@) at +%.1f s",
                     name, artist, uri, Date().timeIntervalSince(trackStart)))

        var prior: Double?
        if let grid = store.load(uri: uri) {
            prior = grid.bpm
            print(String(format: "  grid hit: %.1f BPM, %d beats, analysed %@",
                         grid.bpm, grid.beats.count,
                         grid.analysedAt.formatted(date: .abbreviated, time: .shortened)))
        }

        let tracker = BeatTracker(tempoPrior: prior)
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .bufferingNewest(16))
        let click = options.click ? clickSound : nil
        let beatTask = Task { @MainActor in
            for await beat in tracker.events(from: stream) {
                let t = beat.time.timeIntervalSince(trackStart)
                let lead = beat.time.timeIntervalSinceNow
                print(String(format: "beat  t=+%.2f s  %.1f BPM  conf %.2f  lead %.0f ms",
                             t, 60 / beat.period, beat.confidence, lead * 1000))
                // A stale prediction (well in the past) is worse silent than late.
                if let click, lead > -0.1 {
                    Task { @MainActor in
                        if lead > 0 { try? await Task.sleep(for: .seconds(lead)) }
                        click.stop()
                        click.play()
                    }
                }
            }
        }
        segment = Segment(uri: uri, name: name, artist: artist,
                          duration: duration, trackStart: trackStart,
                          tracker: tracker, continuation: continuation,
                          beatTask: beatTask)
    }

    private func endSegment(analyse: Bool) async {
        guard let segment else { return }
        self.segment = nil
        segment.continuation.finish()
        await segment.beatTask.value

        guard analyse,
              let snapshot = segment.tracker.envelopeSnapshot(),
              Double(snapshot.frames.count) / snapshot.frameRate >= 30
        else {
            if analyse { print("  segment too short to analyse — no grid saved") }
            return
        }
        guard let tempo = estimateTempo(envelope: snapshot.frames,
                                        frameRate: snapshot.frameRate) else {
            print("  tempo estimation refused (rubato or silence) — no grid saved")
            return
        }
        let frameTimes = beatTimesDP(envelope: snapshot.frames,
                                     frameRate: snapshot.frameRate, bpm: tempo.bpm)
        // Envelope frame 0 sits at `snapshot.start`; shift onto track time.
        let offset = snapshot.start.timeIntervalSince(segment.trackStart)
        let beats = frameTimes.map { $0 + offset }
        let grid = BeatGrid(uri: segment.uri, name: segment.name,
                            artist: segment.artist, bpm: tempo.bpm,
                            confidence: tempo.confidence, analysedAt: Date(),
                            frameRate: snapshot.frameRate, beats: beats,
                            duration: segment.duration)
        do {
            try store.save(grid)
            print(String(format: "  grid saved: %.1f BPM, %d beats, conf %.2f",
                         tempo.bpm, beats.count, tempo.confidence))
        } catch {
            print("  grid save failed: \(error)")
        }
        if options.csv { writeCSV(snapshot: snapshot, beats: beats, offset: offset,
                                  uri: segment.uri) }
    }

    private func writeCSV(snapshot: (frames: [Float], frameRate: Double, start: Date),
                          beats: [Double], offset: TimeInterval, uri: String) {
        let envelope = "time,value\n" + snapshot.frames.enumerated()
            .map { String(format: "%.4f,%.6f", Double($0.offset) / snapshot.frameRate + offset, $0.element) }
            .joined(separator: "\n")
        let beatList = "time\n" + beats.map { String(format: "%.4f", $0) }
            .joined(separator: "\n")
        do {
            try envelope.write(to: store.sidecarURL(uri: uri, suffix: "envelope.csv"),
                               atomically: true, encoding: .utf8)
            try beatList.write(to: store.sidecarURL(uri: uri, suffix: "beats.csv"),
                               atomically: true, encoding: .utf8)
            print("  csv written to \(store.directory.path)")
        } catch {
            print("  csv write failed: \(error)")
        }
    }
}

#else

@main
struct Probe {
    static func main() {
        print("tap-probe is macOS-only.")
    }
}

#endif
