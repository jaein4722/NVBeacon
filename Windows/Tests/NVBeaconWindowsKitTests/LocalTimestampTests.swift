import Foundation
import Testing
@testable import NVBeaconWindowsKit

@Test func localTimestampShowsLocalTimeWithOffset() {
    let date = Date(timeIntervalSince1970: 1_795_669_387.75)   // 2026-11-26 05:03:07.75 UTC
    #expect(LocalTimestamp.format(date, utcOffsetMinutes: 0) == "2026-11-26 05:03:07 +00:00")
    #expect(LocalTimestamp.format(date, utcOffsetMinutes: 9 * 60) == "2026-11-26 14:03:07 +09:00")
    #expect(LocalTimestamp.format(date, utcOffsetMinutes: 5 * 60 + 45) == "2026-11-26 10:48:07 +05:45")
    #expect(LocalTimestamp.format(date, utcOffsetMinutes: -(3 * 60 + 30)) == "2026-11-26 01:33:07 -03:30")
    #expect(LocalTimestamp.format(date, utcOffsetMinutes: -8 * 60) == "2026-11-25 21:03:07 -08:00")
}
