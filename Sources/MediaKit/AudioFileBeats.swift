import AVFoundation
import Foundation

/// Offline beat analysis of a complete audio file: tempo, the exact DP beat
/// grid, and per-beat onset strength. Plain data out — the caller maps
/// strength to whatever its domain does with it.
public struct AudioFileBeats: Sendable {
    public let bpm: Double
    public let confidence: Double

    /// Beat times in file time — seconds from the first sample.
    public let beats: [TimeInterval]

    /// Onset-envelope strength at each beat, normalised so the strongest
    /// beat is 1. Parallel to `beats`.
    public let strengths: [Float]

    public let duration: TimeInterval
}

/// Decodes an audio file (anything CoreAudio opens), mixes to mono, and runs
/// the offline chain: `OnsetEnvelope` → `estimateTempo` → `beatTimesDP`.
/// Returns `nil` when the tempo estimator refuses — silence, speech and
/// rubato yield no grid rather than a wrong one.
///
/// Faster than real time; the file's own sample rate is used throughout.
public func analyseAudioFile(at url: URL) throws -> AudioFileBeats? {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let envelope = OnsetEnvelope(sampleRate: format.sampleRate)

    var frames: [Float] = []
    let capacity: AVAudioFrameCount = 1 << 16
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
    while file.framePosition < file.length {
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { break }
        frames.append(contentsOf: envelope.process(monoMix(of: buffer)))
    }

    // The estimator's own 0.15 floor is not enough here: rubato piano
    // autocorrelates at ~0.18 over a whole file (Chopin op. 9/2, 2026-08-17)
    // and would get an invented grid. Reuse the live path's bench-calibrated
    // emission floor — leaks peaked at 0.23, the weakest legitimate groove
    // tested never dipped below 0.28.
    guard let tempo = estimateTempo(envelope: frames,
                                    frameRate: envelope.frameRate),
        tempo.confidence >= 0.25
    else { return nil }

    let gridTimes = beatTimesDP(envelope: frames,
                                frameRate: envelope.frameRate,
                                bpm: tempo.bpm)
    guard !gridTimes.isEmpty else { return nil }

    var strengths = gridTimes.map { time in
        frames[min(frames.count - 1, Int((time * envelope.frameRate).rounded()))]
    }
    let top = strengths.max()!
    if top > 0 { strengths = strengths.map { $0 / top } }

    return AudioFileBeats(bpm: tempo.bpm,
                          confidence: tempo.confidence,
                          beats: gridTimes.map { $0 + envelope.timeOffset },
                          strengths: strengths,
                          duration: Double(file.length) / format.sampleRate)
}

/// Average of all channels, so a hard-panned kick still votes.
private func monoMix(of buffer: AVAudioPCMBuffer) -> [Float] {
    let channels = Int(buffer.format.channelCount)
    let count = Int(buffer.frameLength)
    let data = buffer.floatChannelData!
    guard channels > 1 else { return Array(UnsafeBufferPointer(start: data[0], count: count)) }
    var mixed = [Float](repeating: 0, count: count)
    for channel in 0..<channels {
        let samples = data[channel]
        for index in 0..<count { mixed[index] += samples[index] }
    }
    let scale = 1 / Float(channels)
    return mixed.map { $0 * scale }
}
