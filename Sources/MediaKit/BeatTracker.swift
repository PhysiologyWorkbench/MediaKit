import Accelerate
import AVFoundation
import Foundation
import Observation

/// Turns a chunk stream into predicted beats: mono mixdown → `OnsetEnvelope`
/// → `estimateTempo` about once a second over a rolling eight-second window
/// → `BeatPhasePredictor`. Consuming an `AsyncStream<AudioChunk>` rather than
/// owning a device keeps replay ≡ live: a recorded sidecar runs through this
/// exactly as capture does.
///
/// Times assume the stream is gapless after its first chunk; chunks dropped
/// by the capture side put the envelope clock behind the wall clock.
@MainActor @Observable
public final class BeatTracker {
    private let tempoPrior: Double?
    private var frames: [Float] = []
    private var frameRate: Double = 0
    private var start: Date?

    /// - Parameter tempoPrior: BPM believed before any audio arrives — a
    ///   cached grid's tempo, for instance — letting phase lock on the first
    ///   strong onset instead of waiting out a fresh tempo estimate.
    public init(tempoPrior: Double? = nil) {
        self.tempoPrior = tempoPrior
    }

    /// Predicted beats for the given chunk stream. The returned stream
    /// finishes when the chunk stream does; a consumer that stops iterating
    /// cancels the analysis.
    public func events(from chunks: AsyncStream<AudioChunk>) -> AsyncStream<BeatEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: BeatEvent.self)
        let task = Task { @MainActor [weak self] in
            guard let self else {
                continuation.finish()
                return
            }
            await self.run(chunks: chunks, emitting: continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// The accumulated envelope: frames, their rate, and the host date of
    /// frame 0. Everything `beatTimesDP(envelope:frameRate:bpm:)` needs to
    /// compute a full-track grid whose times are offsets from `start`.
    public func envelopeSnapshot() -> (frames: [Float], frameRate: Double, start: Date)? {
        guard let start, frameRate > 0, !frames.isEmpty else { return nil }
        return (frames, frameRate, start)
    }

    private func run(chunks: AsyncStream<AudioChunk>,
                     emitting out: AsyncStream<BeatEvent>.Continuation) async {
        var detector: OnsetEnvelope?
        var predictor = BeatPhasePredictor(bpm: tempoPrior)
        var streamStart: Date?
        var lastRetune = 0
        for await chunk in chunks {
            if Task.isCancelled { return }
            let envelope: OnsetEnvelope
            if let detector {
                envelope = detector
            } else {
                envelope = OnsetEnvelope(sampleRate: chunk.buffer.format.sampleRate)
                detector = envelope
                streamStart = chunk.start
                frames = []
                frameRate = envelope.frameRate
                start = chunk.start.addingTimeInterval(envelope.timeOffset)
            }
            for value in envelope.process(monoSamples(of: chunk.buffer)) {
                let time = envelope.timeOffset + Double(frames.count) / envelope.frameRate
                frames.append(value)
                if let beat = predictor.step(value: value, time: time) {
                    out.yield(BeatEvent(time: streamStart!.addingTimeInterval(beat.time),
                                        period: beat.period,
                                        confidence: beat.confidence))
                }
            }
            // A window under ~4 s is not evidence: it octave-folds confidently
            // or refuses outright, and either would wrongly displace a prior.
            if frames.count - lastRetune >= Int(envelope.frameRate),
               frames.count >= Int(envelope.frameRate * 4) {
                lastRetune = frames.count
                let window = Array(frames.suffix(Int(envelope.frameRate * 8)))
                predictor.retune(estimateTempo(envelope: window, frameRate: envelope.frameRate))
            }
        }
    }
}

/// Average of all channels, or empty for a buffer that is not float PCM.
func monoSamples(of buffer: AVAudioPCMBuffer) -> [Float] {
    guard let channels = buffer.floatChannelData else { return [] }
    let channelCount = Int(buffer.format.channelCount)
    let frameCount = Int(buffer.frameLength)
    let stride = buffer.stride
    var mono = [Float](repeating: 0, count: frameCount)
    for channel in 0..<channelCount {
        let samples = channels[channel]
        for frame in 0..<frameCount {
            mono[frame] += samples[frame * stride]
        }
    }
    if channelCount > 1 {
        var divisor = Float(channelCount)
        vDSP_vsdiv(mono, 1, &divisor, &mono, 1, vDSP_Length(frameCount))
    }
    return mono
}
