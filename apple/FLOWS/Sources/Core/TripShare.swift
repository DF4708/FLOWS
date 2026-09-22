// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Combine
import Foundation

/// Long-trip route sharing: the trigger, the prefilled text, and the small
/// on-device history that powers recipient suggestions — pure and pinned by
/// FLOWSTests. The banner itself lives in NavigationHUD.
///
/// PLATFORM LIMIT, stated plainly: iOS has no API that lets an app start a
/// Find My live-location share on the user's behalf — only Messages and
/// Find My themselves can do that. The honest version an app CAN build is
/// this one: a prefilled text (destination, arrival time, map link) that the
/// driver sends with one tap, using the same `sms:` recipe as the crash flow
/// (CrashDetectionService.messageContact).
enum TripShareLogic {

    /// The long-trip line, in miles. Applies to BOTH triggers: a plotted
    /// route over this long, or a driving day that has passed it.
    private static let constants = Array(flows_long_trips_share_constants())
    static let longTripMiles = constants[0]
    static let metersPerMile = constants[1]

    /// Offer the share when the plotted route is over 200 miles OR the day's
    /// cumulative driving has passed 200 miles. Strictly over — a route of
    /// exactly 200.0 miles is not "over 200". The daily term re-evaluates as
    /// the day's meters grow, so a short leg late in a long driving day still
    /// triggers mid-drive.
    static func shouldOffer(routeMeters: Double, drivenTodayMeters: Double) -> Bool {
        flows_long_trips_should_offer_share(routeMeters, drivenTodayMeters)
    }

    /// The prefilled text: where, when, and a map link. Plain words. Arrival
    /// is pinned to POSIX/en_US "h:mm a" — same reasoning as the crash
    /// report: the RECIPIENT's clock format is unknown, and "5:40 PM" reads
    /// unambiguously everywhere. The map link opens Apple Maps on Apple
    /// devices and a browser map elsewhere; a missing destination coordinate
    /// simply drops the line rather than pointing at 0,0 in the Atlantic.
    static func shareMessage(destination: String, arrival: Date,
                             latitude: Double?, longitude: Double?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        var lines = [
            "On my way to \(destination).",
            "I should get there around \(formatter.string(from: arrival)).",
        ]
        if let latitude, let longitude {
            lines.append(String(format: "Map: https://maps.apple.com/?daddr=%.5f,%.5f",
                                latitude, longitude))
        }
        return lines.joined(separator: "\n")
    }

    /// The Messages URL, byte-for-byte the crash flow's recipe: digits-only
    /// number, RFC 5724 `?&body=` (the form iOS reliably prefills across
    /// versions — see CrashDetectionService.messageContact for the history).
    /// nil when the number has no digits — nothing useful could open.
    static func smsURLString(number: String, body: String) -> String? {
        let digits = number.filter { "0123456789+".contains($0) }
        guard !digits.isEmpty,
              let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return "sms:\(digits)?&body=\(encoded)"
    }

    /// Suggestion order: frequency AND recency in one number. Every past
    /// share is worth one point that fades with a 30-day half-life, so the
    /// person texted five times last month outranks the person texted once
    /// yesterday, but a pile of year-old shares loses to anyone current.
    /// Ties break on the most recent share (Swift's sort isn't stable).
    static func ranked(_ recipients: [ShareRecipient], now: Date) -> [ShareRecipient] {
        let order = ShareColumns(recipients).withDates { dates, counts, count in
            Array(flows_long_trips_ranked_recipients(dates, counts, count,
                                                     now.timeIntervalSinceReferenceDate))
        }
        return order.map { recipients[Int($0)] }
    }
}

/// Recipients as the bridge reads them: every share date in one list
/// (seconds since the reference date), each recipient's date count, and the
/// phones joined by UTF-8 length — with placeholders behind a zero count for
/// an empty list.
struct ShareColumns {
    let dates: [Double]
    let counts: [Int64]
    let phones: RustTextColumn
    let count: Int64

    init(_ recipients: [ShareRecipient]) {
        let flat = recipients.flatMap { $0.shareDates.map(\.timeIntervalSinceReferenceDate) }
        dates = flat.isEmpty ? [0] : flat
        counts = recipients.isEmpty ? [0] : recipients.map { Int64($0.shareDates.count) }
        phones = RustTextColumn(recipients.map(\.phone))
        count = Int64(recipients.count)
    }

    func withDates<R>(_ body: (UnsafeBufferPointer<Double>, UnsafeBufferPointer<Int64>, Int64) -> R) -> R {
        dates.withUnsafeBufferPointer { d in counts.withUnsafeBufferPointer { c in body(d, c, count) } }
    }
}

/// The day-total odometer behind the second trigger. One calendar day, one
/// meter count; the first movement of a new day starts the count over.
struct DailyDriveLog: Codable, Equatable {
    /// Start of the calendar day the meters belong to.
    var day: Date
    var meters: Double

    static func empty(on date: Date = Date(),
                      calendar: Calendar = .current) -> DailyDriveLog {
        DailyDriveLog(day: calendar.startOfDay(for: date), meters: 0)
    }

    mutating func add(meters delta: Double, at date: Date = Date(),
                      calendar: Calendar = .current) {
        // A new calendar day starts the count over, and a GPS glitch must
        // never drive the total down (rust/flows-core long_trips.rs). The
        // calendar's start of day stays here.
        let next = flows_long_trips_daily_drive_add(
            day.timeIntervalSinceReferenceDate, meters,
            calendar.startOfDay(for: date).timeIntervalSinceReferenceDate, delta)
        day = Date(timeIntervalSinceReferenceDate: next.day)
        meters = next.meters
    }

    /// Meters driven on `date`'s calendar day. The log only rolls over when
    /// a fix is added, so read on its own it still held yesterday's miles
    /// at GO — and a 200-mile Monday offered a share on Tuesday's errand.
    func metersDriven(on date: Date = Date(), calendar: Calendar = .current) -> Double {
        calendar.startOfDay(for: date) == day ? meters : 0
    }
}

/// One person the driver has shared a route with, and when.
struct ShareRecipient: Codable, Equatable {
    var name: String
    var phone: String
    var shareDates: [Date]
}

/// Prior share recipients. PRIVACY: contact names + phone numbers live in
/// the KEYCHAIN (SecureStore — same doctrine that moved medical notes out of
/// UserDefaults: an unencrypted plist rides device backups). Tests inject a
/// UserDefaults instance and stay plist-backed; only the app's standard
/// instance uses the Keychain, migrating and scrubbing any earlier plist
/// copy. It is a small suggestion list, not a message log — both dimensions
/// are capped so it stays a preference-sized blob.
@MainActor
final class ShareHistoryStore: ObservableObject {
    @Published private(set) var recipients: [ShareRecipient] = []

    private let defaults: UserDefaults
    private let useKeychain: Bool
    private static let key = "flows.shareHistory"
    private static let keychainKey = "shareHistory"
    private static let caps = Array(flows_long_trips_share_caps())
    static let maxRecipients = Int(caps[0])
    static let maxDatesPerRecipient = Int(caps[1])

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        useKeychain = defaults === UserDefaults.standard
        if useKeychain {
            var json = SecureStore.get(Self.keychainKey) ?? ""
            // Migrate an earlier plist copy (stored as Data, so the string
            // helper can't see it) and scrub the plaintext.
            if json.isEmpty, let legacy = defaults.data(forKey: Self.key) {
                json = String(decoding: legacy, as: UTF8.self)
                SecureStore.set(json, for: Self.keychainKey)
                defaults.removeObject(forKey: Self.key)
            }
            if let saved = try? JSONDecoder().decode(
                [ShareRecipient].self, from: Data(json.utf8)) {
                recipients = saved
            }
        } else if let data = defaults.data(forKey: Self.key),
                  let saved = try? JSONDecoder().decode([ShareRecipient].self, from: data) {
            recipients = saved
        }
    }

    /// Digits-only matching so "+1 (555) 010-2030" and "15550102030" stay
    /// one person. (The same number typed with and without a country code
    /// still makes two entries — acceptable for a suggestion list.)
    static func normalized(_ phone: String) -> String {
        flows_long_trips_normalized_phone(phone).text
    }

    func recordShare(name: String, phone: String, at date: Date = Date()) {
        // The plan comes from rust/flows-core long_trips.rs: [matched index
        // or -1, renames, dropped dates, order length or -1, order…], empty
        // when the number has no digits and nothing is recorded.
        let columns = ShareColumns(recipients)
        let plan: [Int64] = columns.phones.with { joined, lengths, _ in
            columns.withDates { dates, counts, count in
                Array(flows_long_trips_record_share(joined, lengths, dates, counts, count,
                                                    name, phone, date.timeIntervalSinceReferenceDate))
            }
        }
        guard plan.count >= 4 else { return }
        let matched = Int(plan[0])
        if matched >= 0 {
            if plan[1] != 0 { recipients[matched].name = name }
            recipients[matched].shareDates.append(date)
            recipients[matched].shareDates.removeFirst(Int(plan[2]))
        } else {
            recipients.append(ShareRecipient(name: name, phone: phone, shareDates: [date]))
        }
        if plan[3] >= 0 {
            // Evict the WEAKEST suggestion, not the oldest entry — the list
            // exists to rank, so the ranking decides who stays.
            let current = recipients
            recipients = plan[4...].map { current[Int($0)] }
        }
        persist()
    }

    /// Best-first recipient suggestions (see TripShareLogic.ranked).
    func suggestions(now: Date = Date()) -> [ShareRecipient] {
        TripShareLogic.ranked(recipients, now: now)
    }

    /// "Erase everything FLOWS has learned" reaches this too: who the driver
    /// shared trips with, and when, is what the ranking learned from.
    func erase() {
        recipients = []
        defaults.removeObject(forKey: Self.key)
        if useKeychain { SecureStore.set(nil, for: Self.keychainKey) }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(recipients)
            if useKeychain {
                SecureStore.set(String(decoding: data, as: UTF8.self),
                                for: Self.keychainKey)
            } else {
                defaults.set(data, forKey: Self.key)
            }
        } catch {
            print("[TripShare] persist failed: \(error)")
        }
    }
}
