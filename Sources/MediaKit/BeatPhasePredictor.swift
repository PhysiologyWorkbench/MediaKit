import Foundation

/// Causal phase-locked beat predictor over an onset envelope: the tempo comes
/// from periodic `retune(_:)` calls (autocorrelation over a rolling window),
/// the phase from onsets observed near predicted grid points, each nudging
/// the grid by a fraction of its error. Beats are emitted `horizon` seconds
/// before they land — prediction, never reaction.
///
/// Concepts follow M. Stark, M. E. P. Davies and M. D. Plumbley, "Real-Time
/// Beat-Synchronous Analysis of Musical Audio" (DAFx 2009), ported from the
/// paper — the reference implementation is GPL and was not consulted.
///
/// Smoothing constants assume an envelope frame rate near 100 Hz.
public struct BeatPhasePredictor {
    /// Seconds of warning each emitted beat carries.
    public let horizon: TimeInterval

    /// Current beat period, `nil` before any tempo evidence.
    public private(set) var period: TimeInterval?

    /// 0…1: tempo evidence times recent onset support. Below the emission
    /// floor the predictor goes silent rather than inventing beats.
    public private(set) var confidence: Double = 0

    private var tempoConfidence: Double = 0
    private var nextBeat: TimeInterval?
    private var lastSupport: TimeInterval?
    private var mean: Double = 0
    private var deviation: Double = 0
    private var previousValue: Float = 0

    // Calibrated at the Spotify bench (2026-08-17): rubato piano leaks weak
    // wandering estimates up to ~0.23; the weakest legitimate groove tested
    // (Superstition) never dipped below 0.28.
    private static let emissionFloor = 0.25

    public init(horizon: TimeInterval = 0.3, bpm: Double? = nil) {
        self.horizon = horizon
        if let bpm {
            period = 60 / bpm
            tempoConfidence = 0.4 // usable prior, unconfirmed by this audio
        }
    }

    /// Adopts a fresh tempo estimate, or decays toward silence on `nil`.
    /// Phase survives a retune; only the period changes.
    public mutating func retune(_ estimate: (bpm: Double, confidence: Double)?) {
        if let estimate {
            period = 60 / estimate.bpm
            tempoConfidence = estimate.confidence
        } else {
            tempoConfidence *= 0.5
            if tempoConfidence < 0.05 {
                tempoConfidence = 0
                nextBeat = nil
            }
        }
    }

    /// Feeds one envelope frame; returns a beat prediction when one is due.
    public mutating func step(value: Float, time: TimeInterval)
        -> (time: TimeInterval, period: TimeInterval, confidence: Double)?
    {
        // Adaptive onset threshold: slow EMAs of the envelope and its spread.
        let alpha = 0.02
        mean += alpha * (Double(value) - mean)
        deviation += alpha * (abs(Double(value) - mean) - deviation)
        let threshold = Float(mean + 2.5 * deviation)
        let rose = value > threshold && previousValue <= threshold
        previousValue = value

        if rose, let period, tempoConfidence > 0 {
            if let anchor = nextBeat {
                // Nudge the whole grid a quarter of the way toward an onset
                // that lands near any grid point; ignore off-grid onsets.
                let beats = ((time - anchor) / period).rounded()
                let error = time - (anchor + beats * period)
                if abs(error) < 0.3 * period {
                    nextBeat = anchor + 0.25 * error
                    lastSupport = time
                }
            } else {
                nextBeat = time + period
                lastSupport = time
            }
        }

        guard let period, var beat = nextBeat else {
            confidence = 0
            return nil
        }

        // Beats already past cannot be predicted; keep the phase, skip them.
        while beat < time { beat += period }
        nextBeat = beat

        // Support holds while onsets keep landing on the grid, then decays.
        let support: Double
        if let lastSupport {
            support = exp(-max(0, (time - lastSupport) - 1.5 * period))
        } else {
            support = 0
        }
        confidence = tempoConfidence * support

        guard time >= beat - horizon, confidence >= Self.emissionFloor else { return nil }
        nextBeat = beat + period
        return (time: beat, period: period, confidence: confidence)
    }
}
