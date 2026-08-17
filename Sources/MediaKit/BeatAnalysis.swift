import Accelerate
import Foundation

/// Tempo of an onset envelope by mean-removed autocorrelation, folded into
/// 1–3 Hz (60–180 BPM): each in-band lag is scored together with its double,
/// so a 240 BPM ride pattern is felt — and reported — at 120. The winning lag
/// is refined by parabolic interpolation. Returns `nil` when the envelope is
/// too short, too flat, or the best correlation is too weak to trust: silence
/// refuses rather than invents.
public func estimateTempo(envelope: [Float], frameRate: Double)
    -> (bpm: Double, confidence: Double)?
{
    let minLag = Int((frameRate * 60 / 180).rounded())
    let maxLag = Int((frameRate * 60 / 60).rounded())
    let count = envelope.count
    guard minLag > 1, count > 2 * maxLag + 2 else { return nil }

    var mean: Float = 0
    vDSP_meanv(envelope, 1, &mean, vDSP_Length(count))
    var centred = [Float](repeating: 0, count: count)
    var negativeMean = -mean
    vDSP_vsadd(envelope, 1, &negativeMean, &centred, 1, vDSP_Length(count))

    func correlation(_ lag: Int) -> Float {
        var dot: Float = 0
        centred.withUnsafeBufferPointer { buffer in
            vDSP_dotpr(buffer.baseAddress!, 1, buffer.baseAddress! + lag, 1,
                       &dot, vDSP_Length(count - lag))
        }
        return dot / Float(count - lag)
    }

    let variance = correlation(0)
    guard variance > .ulpOfOne else { return nil }

    let lags = minLag...(2 * maxLag + 1)
    var normalised = [Float](repeating: 0, count: 2 * maxLag + 2)
    for lag in lags { normalised[lag] = correlation(lag) / variance }

    // Log-Gaussian weighting centred on 120 BPM (Ellis 2007, σ 0.9 octaves):
    // between octave-related folds with comparable comb energy — a bassline
    // striking alternate beats makes the half-tempo lag genuinely stronger —
    // prefer the danceable one. A bias, not a rule: clear evidence outvotes it.
    func weight(_ lag: Int) -> Float {
        let octaves = log2(2 * Double(lag) / frameRate)
        return Float(exp(-0.5 * pow(octaves / 0.9, 2)))
    }
    func score(_ lag: Int) -> Float {
        weight(lag) * (normalised[lag] + 0.5 * normalised[2 * lag])
    }

    var bestLag = minLag
    for lag in minLag...maxLag where score(lag) > score(bestLag) { bestLag = lag }
    let confidence = Double(max(0, min(1, normalised[bestLag])))
    guard confidence >= 0.15 else { return nil }

    // Parabolic refinement over the three scores around the peak.
    var lag = Double(bestLag)
    if bestLag > minLag && bestLag < maxLag {
        let left = Double(score(bestLag - 1))
        let centre = Double(score(bestLag))
        let right = Double(score(bestLag + 1))
        let denominator = left - 2 * centre + right
        if abs(denominator) > .ulpOfOne {
            lag += 0.5 * (left - right) / denominator
        }
    }
    return (bpm: 60 * frameRate / lag, confidence: confidence)
}

/// Offline beat grid over a complete onset envelope by dynamic programming,
/// ported from the publication: D. P. W. Ellis, "Beat Tracking by Dynamic
/// Programming", Journal of New Music Research 36(1), 2007. Each frame's
/// cumulative score is its onset strength plus the best predecessor score
/// one period back, penalised by the squared log deviation from the period;
/// the grid is read off by backtracking from the strongest ending.
///
/// Returned times are envelope-frame times (`index / frameRate`); add the
/// envelope's `timeOffset` for source-stream time.
public func beatTimesDP(envelope: [Float], frameRate: Double, bpm: Double)
    -> [TimeInterval]
{
    let period = frameRate * 60 / bpm
    let count = envelope.count
    guard period > 1, count > Int(2 * period) else { return [] }

    var deviation: Float = 0
    var mean: Float = 0
    vDSP_normalize(envelope, 1, nil, 1, &mean, &deviation, vDSP_Length(count))
    guard deviation > .ulpOfOne else { return [] }
    let strength = envelope.map { ($0 - mean) / deviation }

    let tightness: Float = 100
    var score = strength
    var backlink = [Int](repeating: -1, count: count)
    for index in 0..<count {
        let earliest = max(0, index - Int((2 * period).rounded()))
        let latest = index - Int((period / 2).rounded())
        guard latest >= earliest else { continue }
        var best = -Float.infinity
        var bestPrevious = -1
        for previous in earliest...latest {
            let interval = Float(index - previous)
            let penalty = -tightness * pow(log(interval / Float(period)), 2)
            let candidate = score[previous] + penalty
            if candidate > best {
                best = candidate
                bestPrevious = previous
            }
        }
        if best > 0 {
            score[index] = strength[index] + best
            backlink[index] = bestPrevious
        }
    }

    // Backtrack from the best score in the final period.
    let tail = max(0, count - Int(period.rounded()))
    var cursor = tail
    for index in tail..<count where score[index] > score[cursor] { cursor = index }
    var beats: [Int] = []
    while cursor >= 0 {
        beats.append(cursor)
        cursor = backlink[cursor]
    }
    // A chain of one is the argmax of noise, not a grid.
    guard beats.count > 1 else { return [] }
    return beats.reversed().map { Double($0) / frameRate }
}
