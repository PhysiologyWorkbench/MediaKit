#if os(macOS)
import Foundation

/// One playback state change, from either channel.
struct PlaybackEvent: Sendable {
    enum State: String, Sendable {
        case playing = "Playing"
        case paused = "Paused"
        case stopped = "Stopped"
    }

    let state: State
    let trackURI: String?
    let name: String?
    let artist: String?
    let duration: TimeInterval?
    let position: TimeInterval?
    let date: Date
}

/// Push channel: the Spotify desktop client posts
/// `com.spotify.client.PlaybackStateChanged` on the distributed notification
/// center with track identity, state and position. Unofficial but stable for
/// over a decade; `SpotifyScripting` is the supported fallback.
@MainActor
final class SpotifyNowPlaying {
    let events: AsyncStream<PlaybackEvent>
    nonisolated(unsafe) private let observer: any NSObjectProtocol

    /// Touched only on the observer's delivery queue (`.main`).
    private final class OnceFlag: @unchecked Sendable { var logged = false }

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self)
        events = stream
        let flag = OnceFlag()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { notification in
            guard let info = notification.userInfo else { return }
            if !flag.logged {
                flag.logged = true
                print("notification payload (first event, verbatim): \(info)")
            }
            guard let event = PlaybackEvent(userInfo: info) else { return }
            continuation.yield(event)
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(observer)
    }
}

extension PlaybackEvent {
    init?(userInfo: [AnyHashable: Any]) {
        guard let stateName = userInfo["Player State"] as? String,
              let state = State(rawValue: stateName) else { return nil }
        self.state = state
        trackURI = userInfo["Track ID"] as? String
        name = userInfo["Name"] as? String
        artist = userInfo["Artist"] as? String
        // Observed in milliseconds in some client versions, seconds in others.
        if let raw = userInfo["Duration"] as? Double {
            duration = raw > 10_000 ? raw / 1000 : raw
        } else {
            duration = nil
        }
        position = userInfo["Playback Position"] as? Double
        date = Date()
    }
}

/// Pull channel: the officially supported scripting dictionary, via
/// `osascript`. Used for the startup snapshot and the position-precision
/// measurement; the notification channel drives everything else.
enum SpotifyScripting {
    private static func run(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func playerPosition() -> Double? {
        run(#"tell application "Spotify" to player position"#)
            .flatMap(Double.init)
    }

    /// Startup snapshot for a track that was already playing before the
    /// probe launched and will therefore never announce itself.
    static func snapshot() -> PlaybackEvent? {
        let script = """
        tell application "Spotify"
            set sep to character id 31
            player state as text & sep & id of current track & sep & \
        name of current track & sep & artist of current track & sep & \
        (duration of current track) & sep & player position
        end tell
        """
        guard let output = run(script) else { return nil }
        let fields = output.components(separatedBy: "\u{1F}")
        guard fields.count == 6,
              let state = PlaybackEvent.State(rawValue: fields[0].capitalized)
        else { return nil }
        return PlaybackEvent(
            state: state,
            trackURI: fields[1],
            name: fields[2],
            artist: fields[3],
            duration: Double(fields[4]).map { $0 > 10_000 ? $0 / 1000 : $0 },
            position: Double(fields[5]),
            date: Date())
    }
}
#endif
