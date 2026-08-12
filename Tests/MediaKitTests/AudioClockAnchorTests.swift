import Foundation
import Testing
@testable import MediaKit

struct AudioClockAnchorTests {
    @Test func mapsSampleTimeForward() {
        let host = Date(timeIntervalSince1970: 1_000_000)
        let anchor = AudioClockAnchor(sampleTime: 48_000, sampleRate: 48_000, hostDate: host)
        #expect(anchor.date(forSampleTime: 48_000) == host)
        #expect(anchor.date(forSampleTime: 96_000) == host.addingTimeInterval(1))
        #expect(anchor.date(forSampleTime: 0) == host.addingTimeInterval(-1))
    }

    @Test func mapsOffsetsFromAnchor() {
        let host = Date(timeIntervalSince1970: 2_000_000)
        let anchor = AudioClockAnchor(sampleTime: 0, sampleRate: 1, hostDate: host)
        #expect(anchor.date(atOffset: 0) == host)
        #expect(anchor.date(atOffset: 2.5) == host.addingTimeInterval(2.5))
    }

    @Test func roundTripsAt48kHz() {
        let host = Date(timeIntervalSince1970: 3_000_000)
        let anchor = AudioClockAnchor(sampleTime: 1_234_567, sampleRate: 48_000, hostDate: host)
        let later = anchor.date(forSampleTime: 1_234_567 + 24_000)
        #expect(abs(later.timeIntervalSince(host) - 0.5) < 1e-9)
    }
}
