import Foundation
import WinSDK

/// Console time stamps in the PC's time zone with the UTC offset, e.g. `2026-11-26 14:03:07 +09:00`.
public enum LocalTimestamp {
    public static func now() -> String {
        let date = Date()
        return format(date, utcOffsetMinutes: utcOffsetMinutes(at: date))
    }

    public static func format(_ date: Date, utcOffsetMinutes: Int) -> String {
        let zone = TimeZone(secondsFromGMT: utcOffsetMinutes * 60) ?? .gmt
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = zone.secondsFromGMT(for: date) / 60
        let stamp = String(format: "%04d-%02d-%02d %02d:%02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                           parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        return stamp + (offset < 0 ? " -" : " +") + String(format: "%02d:%02d", abs(offset) / 60, abs(offset) % 60)
    }

    /// From Windows: Foundation's time zone resolves to UTC in this toolchain.
    public static func utcOffsetMinutes(at date: Date) -> Int {
        // Whole seconds, in 100 ns intervals since 1601, so the difference below is exact.
        let ticks = (Int64(date.timeIntervalSince1970.rounded(.down)) + 11_644_473_600) * 10_000_000
        var utcFileTime = FILETIME(dwLowDateTime: DWORD(truncatingIfNeeded: ticks),
                                   dwHighDateTime: DWORD(truncatingIfNeeded: ticks >> 32))
        var utc = SYSTEMTIME()
        var local = SYSTEMTIME()
        var localFileTime = FILETIME()
        guard FileTimeToSystemTime(&utcFileTime, &utc), SystemTimeToTzSpecificLocalTime(nil, &utc, &local),
              SystemTimeToFileTime(&local, &localFileTime) else { return 0 }
        let localTicks = Int64(localFileTime.dwHighDateTime) << 32 | Int64(localFileTime.dwLowDateTime)
        return Int((localTicks - ticks) / 600_000_000)
    }
}
