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

    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AudioChunk>.Continuation?

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
        let relay = TapRelay(continuation: continuation)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, when in
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
    private var anchor: AudioClockAnchor?

    init(continuation: AsyncStream<AudioChunk>.Continuation) {
        self.continuation = continuation
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
        continuation.yield(AudioChunk(buffer: buffer, start: start))
    }
}
