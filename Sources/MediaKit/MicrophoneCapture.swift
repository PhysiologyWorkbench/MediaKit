import AVFoundation
import Foundation
import Observation

/// Explicitly armed microphone capture. Nothing captures as a side effect:
/// `arm()` is the only way the microphone opens, and `state` is `.armed`
/// exactly while it is open.
@MainActor @Observable
public final class MicrophoneCapture {
    public enum State: Equatable, Sendable {
        case idle
        case requestingPermission
        case armed
        case denied
        case failed(String)
    }

    public enum CaptureError: Error {
        case permissionDenied
        case alreadyArmed
    }

    public private(set) var state: State = .idle

    /// Peak magnitude of the most recent buffer, 0…1, and 0 while idle. The
    /// operator's evidence that the microphone is hearing something — which is
    /// a smaller claim than a word having been recognised, and arrives sooner.
    public private(set) var level: Float = 0

    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var activity: NSObjectProtocol?

    public init() {}

    /// Requests microphone permission if needed, starts an input tap, and
    /// returns the chunk stream. The stream finishes on `disarm()`; if the
    /// consumer stops iterating, capture disarms itself — a hot microphone
    /// with no consumer is never left behind.
    public func arm() async throws -> AsyncStream<AudioChunk> {
        guard engine == nil else { throw CaptureError.alreadyArmed }

        state = .requestingPermission
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            state = .denied
            throw CaptureError.permissionDenied
        }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        #endif

        let engine = AVAudioEngine()
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .bufferingNewest(16))
        let relay = TapRelay(continuation: continuation) { [weak self] level in
            Task { @MainActor in self?.level = level }
        }
        // `@Sendable` keeps the tap out of this actor's isolation. Without it the
        // literal inherits `@MainActor` from `arm()`, and AVFAudio's realtime
        // messenger queue trips the executor check on the first buffer.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { @Sendable buffer, when in
            relay.relay(buffer: buffer, when: when)
        }
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            continuation.finish()
            state = .failed(error.localizedDescription)
            throw error
        }

        self.engine = engine
        self.continuation = continuation
        // A throttled host stalls the consumer and the drop-oldest buffers
        // shed chunks. The microphone is hardware-clocked, so only that
        // visible class is at stake here — but the library asserts for the
        // extent of its own capture rather than leaving it to every host.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "MediaKit microphone capture")
        state = .armed
        continuation.onTermination = { _ in
            Task { @MainActor in self.disarm() }
        }
        return stream
    }

    public func disarm() {
        guard let engine else { return }
        self.engine = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        level = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        state = .idle
    }
}

/// Bridges the realtime tap thread to the chunk stream. `@unchecked Sendable`:
/// `anchor` is touched only from the tap's serial callbacks.
private final class TapRelay: @unchecked Sendable {
    private let continuation: AsyncStream<AudioChunk>.Continuation
    private let onLevel: @Sendable (Float) -> Void
    private var anchor: AudioClockAnchor?

    init(continuation: AsyncStream<AudioChunk>.Continuation,
         onLevel: @escaping @Sendable (Float) -> Void) {
        self.continuation = continuation
        self.onLevel = onLevel
    }

    func relay(buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        let start: Date
        if when.isSampleTimeValid {
            let anchor = self.anchor
                ?? AudioClockAnchor(sampleTime: when.sampleTime,
                                    sampleRate: when.sampleRate,
                                    hostDate: Date())
            self.anchor = anchor
            start = anchor.date(forSampleTime: when.sampleTime)
        } else {
            start = Date()
        }
        onLevel(peakMagnitude(of: buffer))
        continuation.yield(AudioChunk(buffer: buffer, start: start))
    }
}

/// Largest absolute sample across every channel, or 0 for a buffer that is not
/// float PCM. Called on the tap thread, so it allocates nothing.
func peakMagnitude(of buffer: AVAudioPCMBuffer) -> Float {
    guard let channels = buffer.floatChannelData else { return 0 }
    let stride = buffer.stride
    var peak: Float = 0
    for channel in 0..<Int(buffer.format.channelCount) {
        let samples = channels[channel]
        for frame in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(samples[frame * stride]))
        }
    }
    return peak
}
