// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Turns a timetable's stored seconds into the time a rider reads on a
/// platform clock.
///
/// The transit engine deliberately knows no clock: a shard stores seconds from
/// the service day's start, and the conversion needs a timezone database that
/// Rust does not carry and Foundation does. So the whole conversion lives here,
/// and it has exactly two rules that are easy to get wrong.
///
/// **1. The times are the agency's, not the station's.** GTFS measures every
/// time in `stop_times.txt` from the *agency's* zone, wherever the stop happens
/// to be. Amtrak keeps Eastern time for the whole network, so the Coast
/// Starlight's Seattle departure is stored as `12:55:00` and belongs on screen
/// as 9:55 AM. Anchor in the agency's zone; render in the station's.
///
/// **2. The day starts at noon minus twelve hours, not at midnight.** They are
/// the same on 363 days a year. On the two days the clocks change they differ
/// by an hour, in opposite directions — anchoring at midnight puts every time
/// on the spring-forward day an hour late and every time on the fall-back day
/// an hour early. Both are a missed train.
enum TransitClock {
    /// When a service day begins, as an absolute instant: noon in the agency's
    /// zone, minus twelve hours. `nil` for an unknown zone or a date that is
    /// not a real calendar day.
    static func dayStart(serviceDate: Int, agencyZone: String) -> Date? {
        guard let tz = TimeZone(identifier: agencyZone) else { return nil }
        let (y, m, d) = (serviceDate / 10000, (serviceDate / 100) % 100, serviceDate % 100)
        guard y >= 1900, y <= 2100, (1...12).contains(m), (1...31).contains(d) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var parts = DateComponents()
        parts.year = y
        parts.month = m
        parts.day = d
        parts.hour = 12
        guard let noon = cal.date(from: parts) else { return nil }
        // Verify the calendar gave us the day we asked for: DateComponents
        // rolls February 31st forward rather than refusing it.
        let back = cal.dateComponents([.year, .month, .day], from: noon)
        guard back.year == y, back.month == m, back.day == d else { return nil }
        return noon.addingTimeInterval(-12 * 3600)
    }

    /// The instant a stored time happens. `seconds` may exceed 24 hours — GTFS
    /// uses `25:30:00` for a train that leaves after midnight, and that is a
    /// real departure on this service day, not the next one's.
    static func instant(serviceDate: Int, agencyZone: String, seconds: Int) -> Date? {
        guard seconds >= 0, seconds <= 60 * 3600 else { return nil }
        return dayStart(serviceDate: serviceDate, agencyZone: agencyZone)?
            .addingTimeInterval(TimeInterval(seconds))
    }

    /// Where `now` falls in a service day, as the seconds a query wants.
    /// Negative when the day has not started; `nil` when the day is already
    /// over, which is the caller's cue to build tomorrow's shard rather than
    /// show yesterday's trains.
    static func seconds(at now: Date, serviceDate: Int, agencyZone: String) -> Int? {
        guard let start = dayStart(serviceDate: serviceDate, agencyZone: agencyZone) else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed < 30 * 3600 else { return nil }
        return Int(elapsed.rounded(.down))
    }

    /// The clock face at a station: "6:15 AM", in that station's own zone.
    /// `locale` is injectable only so a test can pin a clock format; the app
    /// always takes the rider's own, which decides 12- vs 24-hour.
    static func clock(_ moment: Date, zone: String, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: zone) ?? .current
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: moment)
    }

    /// A plain word for a zone — "Central", "Pacific" — for the one place it
    /// is needed: a trip that crosses zones, where "arrive 2:50 PM" alone
    /// silently loses an hour. Foundation says "Central Daylight Time"; riders
    /// say "Central time", so the seasonal half is dropped.
    static func zoneWord(_ zone: String, locale: Locale = .current) -> String {
        guard let tz = TimeZone(identifier: zone) else { return "" }
        let name = tz.localizedName(for: .generic, locale: locale)
            ?? tz.localizedName(for: .standard, locale: locale)
            ?? ""
        if name.isEmpty {
            // "America/Los_Angeles" -> "Los Angeles"
            return zone.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? ""
        }
        for tail in [" Daylight Time", " Standard Time", " Time"] where name.hasSuffix(tail) {
            return String(name.dropLast(tail.count))
        }
        return name
    }

    /// Two stations' times, said the way a rider needs to hear them: the zone
    /// is named only when the trip crosses one, because that is the only time
    /// it changes what the numbers mean.
    static func span(
        board: Date, boardZone: String, alight: Date, alightZone: String,
        locale: Locale = .current
    ) -> String {
        let a = clock(board, zone: boardZone, locale: locale)
        let b = clock(alight, zone: alightZone, locale: locale)
        guard boardZone != alightZone,
              TimeZone(identifier: boardZone)?.secondsFromGMT(for: board)
                != TimeZone(identifier: alightZone)?.secondsFromGMT(for: alight)
        else { return "\(a) – \(b)" }
        let word = zoneWord(alightZone, locale: locale)
        return word.isEmpty ? "\(a) – \(b)" : "\(a) – \(b) \(word) time"
    }

    /// "Times as of Sep 22" — how old the schedule is, for the rider deciding
    /// whether to trust it. Empty when the feed did not say.
    static func publishedNote(_ yyyymmdd: Int) -> String {
        guard yyyymmdd > 0,
              let day = dayStart(serviceDate: yyyymmdd, agencyZone: TimeZone.current.identifier)
        else { return "" }
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return "Times as of \(f.string(from: day))"
    }
}
