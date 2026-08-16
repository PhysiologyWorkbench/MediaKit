import Accelerate
import Foundation

/// Streaming low-band onset envelope: spectral flux restricted to the
/// 40–150 Hz kick-drum band, so hi-hats and vocals don't vote. Feed mono
/// samples in capture order; get envelope frames out at `frameRate`.
///
/// Per frame: Hann-windowed 4096-point FFT every 512 samples, log-compressed
/// band magnitudes, half-wave-rectified frame-to-frame increase summed over
/// the band, lightly smoothed. The first frame is emitted once 4096 samples
/// have arrived, then one per 512.
public final class OnsetEnvelope {
    public let sampleRate: Double

    /// Envelope frames per second: `sampleRate / 512`.
    public let frameRate: Double

    /// Frames are stamped at window centre: envelope frame `i` sits at
    /// `timeOffset + Double(i) / frameRate` seconds into the source stream.
    public let timeOffset: TimeInterval

    private static let fftSize = 4096
    private static let hop = 512
    private static let log2n = vDSP_Length(12)

    private let setup: FFTSetup
    private let window: [Float]
    private let band: Range<Int>
    private var pending: [Float] = []
    private var previousBand: [Float]
    private var smoothed: Float = 0
    private var primed = false

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        frameRate = sampleRate / Double(Self.hop)
        timeOffset = Double(Self.fftSize) / 2 / sampleRate
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        var window = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        self.window = window
        let binWidth = sampleRate / Double(Self.fftSize)
        let lower = max(1, Int((40 / binWidth).rounded(.up)))
        let upper = Int((150 / binWidth).rounded(.down))
        band = lower..<(upper + 1)
        previousBand = [Float](repeating: 0, count: band.count)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Consumes samples and returns the envelope frames they completed.
    public func process(_ samples: [Float]) -> [Float] {
        pending.append(contentsOf: samples)
        var frames: [Float] = []
        while pending.count >= Self.fftSize {
            frames.append(step())
            pending.removeFirst(Self.hop)
        }
        return frames
    }

    private func step() -> Float {
        let half = Self.fftSize / 2
        var windowed = [Float](repeating: 0, count: Self.fftSize)
        vDSP_vmul(pending, 1, window, 1, &windowed, 1, vDSP_Length(Self.fftSize))

        var bandMagnitudes = [Float](repeating: 0, count: band.count)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPtr in
            imaginary.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!,
                                            imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { source in
                    source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                for (slot, bin) in band.enumerated() {
                    let magnitude = (realPtr[bin] * realPtr[bin]
                        + imagPtr[bin] * imagPtr[bin]).squareRoot()
                    bandMagnitudes[slot] = log(1 + magnitude)
                }
            }
        }

        var flux: Float = 0
        if primed {
            for slot in 0..<band.count {
                flux += max(0, bandMagnitudes[slot] - previousBand[slot])
            }
        }
        primed = true
        previousBand = bandMagnitudes
        smoothed = 0.5 * smoothed + 0.5 * flux
        return smoothed
    }
}
