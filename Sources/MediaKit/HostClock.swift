import Foundation

/// Maps the mach host clock — Core Audio's `mHostTime` — onto the wall clock.
/// Established once, when a capture arms, and applied to every timestamp
/// after it: one mapping, so timestamps stay mutually consistent even though
/// `Date` is steppable and the host clock is not.
///
/// Host time is preferred over sample time as a capture's time base because
/// the two disagree exactly when the capture is being throttled, and only the
/// host clock keeps running (CAPTURE-INTEGRITY.md).
struct HostClock: Sendable, Equatable {
    let ticksPerSecond: Double
    let referenceTicks: UInt64
    let referenceDate: Date

    init(referenceTicks: UInt64, referenceDate: Date, ticksPerSecond: Double) {
        self.ticksPerSecond = ticksPerSecond
        self.referenceTicks = referenceTicks
        self.referenceDate = referenceDate
    }

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        self.init(referenceTicks: mach_absolute_time(),
                  referenceDate: Date(),
                  ticksPerSecond: 1e9 * Double(timebase.denom) / Double(timebase.numer))
    }

    func date(forHostTime ticks: UInt64) -> Date {
        referenceDate.addingTimeInterval(seconds(from: referenceTicks, to: ticks))
    }

    func seconds(from: UInt64, to: UInt64) -> TimeInterval {
        (Double(to) - Double(from)) / ticksPerSecond
    }
}

/// Parts per million by which an audio sample clock ran ahead of (positive) or
/// behind (negative) the host clock across a window.
///
/// Genuine clocks sit within a few ppm of each other. A process tap's clock is
/// synthesised by the capturing process, so throttling stretches it while the
/// host clock keeps true: the 2026-08-16 App Nap corruption measured ~1100 ppm
/// with no gap in sample time to show for it.
func clockSkewPPM(audioSeconds: Double, hostSeconds: Double) -> Double {
    guard hostSeconds > 0 else { return 0 }
    return (audioSeconds / hostSeconds - 1) * 1e6
}
