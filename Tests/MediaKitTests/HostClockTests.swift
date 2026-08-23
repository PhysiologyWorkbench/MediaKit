import Foundation
import Testing
@testable import MediaKit

struct HostClockTests {
    @Test func mapsHostTicksBothWaysFromTheReference() {
        let reference = Date(timeIntervalSince1970: 5_000)
        let clock = HostClock(referenceTicks: 1_000_000,
                              referenceDate: reference,
                              ticksPerSecond: 1_000_000)
        #expect(clock.date(forHostTime: 1_000_000) == reference)
        #expect(clock.date(forHostTime: 2_000_000) == reference.addingTimeInterval(1))
        #expect(clock.date(forHostTime: 500_000) == reference.addingTimeInterval(-0.5))
    }

    @Test func readsAPlausibleRateFromTheMachTimebase() {
        // Whatever the timebase, the host clock is at least megahertz-fast;
        // a numer/denom inversion would land far below this.
        #expect(HostClock().ticksPerSecond > 1e6)
    }

    @Test func agreeingClocksHaveNoSkew() {
        #expect(clockSkewPPM(audioSeconds: 10, hostSeconds: 10) == 0)
    }

    /// The 2026-08-16 App Nap corruption: click phase drifting ~68 ms/min with
    /// sample time unbroken. The sample clock lags, so the skew is negative.
    @Test func recoversTheBenchedCorruption() {
        let ppm = clockSkewPPM(audioSeconds: 60, hostSeconds: 60.068)
        #expect(ppm < -1_100 && ppm > -1_150)
    }
}
