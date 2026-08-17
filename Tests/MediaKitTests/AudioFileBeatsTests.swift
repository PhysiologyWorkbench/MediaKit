import AVFoundation
import Foundation
import Testing
@testable import MediaKit

struct AudioFileBeatsTests {
    /// Writes samples as a mono (or interleaved stereo) WAV in the temporary
    /// directory and returns its URL.
    private func writeWAV(_ channels: [[Float]], sampleRate: Double,
                          name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                   channels: AVAudioChannelCount(channels.count))!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels.count,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let count = channels[0].count
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(count))!
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer {
                buffer.floatChannelData![index].update(from: $0.baseAddress!,
                                                       count: count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        try file.write(from: buffer)
        return url
    }

    @Test func aClickTrackYieldsItsGrid() throws {
        let url = try writeWAV([clickTrack(bpm: 120, seconds: 30)],
                               sampleRate: 48_000, name: "click120.wav")
        let result = try analyseAudioFile(at: url)
        #expect(result != nil)
        guard let result else { return }
        #expect(abs(result.bpm - 120) < 0.5)
        #expect(abs(result.duration - 30) < 0.1)

        // Every beat within half an envelope frame of the 0.5 s grid, once
        // the DP grid's own phase is anchored on the first beat.
        let period = 60.0 / 120
        let phase = result.beats[0]
            .truncatingRemainder(dividingBy: period)
        for beat in result.beats {
            let offset = (beat - phase).truncatingRemainder(dividingBy: period)
            let error = min(offset, period - offset)
            #expect(error < 0.012)
        }
        #expect(result.beats.count > 55)

        // Beats sit on thumps: every strength near the strongest one.
        #expect(result.strengths.allSatisfy { $0 > 0.5 })
    }

    /// The kick hard-panned to one channel must survive the mono mixdown.
    @Test func stereoMixesToMono() throws {
        let click = clickTrack(bpm: 100, seconds: 20)
        let silence = [Float](repeating: 0, count: click.count)
        let url = try writeWAV([click, silence], sampleRate: 48_000,
                               name: "clickStereo.wav")
        let result = try analyseAudioFile(at: url)
        #expect(result != nil)
        #expect(abs(result!.bpm - 100) < 1)
    }

    /// Rubato: beats present but the period wanders beat to beat, smearing
    /// the autocorrelation below the emission floor. The whole file must
    /// refuse — on the real Chopin op. 9/2 the estimator alone said 123 BPM
    /// at 0.18, which is why `analyseAudioFile` carries the 0.25 floor.
    @Test func wanderingTempoRefuses() throws {
        let sampleRate = 48_000.0
        let seconds = 30.0
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        let wander = deterministicNoise(count: 128)
        var beat = 0.0
        var count = 0
        while beat < seconds {
            let start = Int(beat * sampleRate)
            for offset in 0..<Int(0.1 * sampleRate) {
                let index = start + offset
                guard index < samples.count else { break }
                let time = Double(offset) / sampleRate
                samples[index] += Float(sin(2 * .pi * 60 * time) * exp(-time / 0.03))
            }
            beat += 0.5 * (0.7 + 0.6 * Double(wander[count]))
            count += 1
        }
        let url = try writeWAV([samples], sampleRate: sampleRate,
                               name: "rubato.wav")
        #expect(try analyseAudioFile(at: url) == nil)
    }

    @Test func noiseRefusesRatherThanInvents() throws {
        let url = try writeWAV([deterministicNoise(count: 20 * 48_000)],
                               sampleRate: 48_000, name: "noise.wav")
        #expect(try analyseAudioFile(at: url) == nil)
    }

    @Test func aMissingFileThrows() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-file.wav")
        #expect(throws: (any Error).self) { try analyseAudioFile(at: url) }
    }
}
