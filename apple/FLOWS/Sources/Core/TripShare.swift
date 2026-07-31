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
    static let longTripMiles = 200.0
    static let metersPerMile = 1609.344

    /// Offer the share when the plotted route is over 200 miles OR the day's
    /// cumulative driving has passed 200 miles. Strictly over — a route of
    /// exactly 200.0 miles is not "over 200". The daily term re-evaluates as
    /// the day's meters grow, so a short leg late in a long driving day still
    /// triggers mid-drive.
    static func shouldOffer(routeMeters: Double, drivenTodayMeters: Double) -> Bool {
        let limit = longTripMiles * metersPerMile
        return routeMeters > limit || drivenTodayMeters > limit
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
        struct Scored {
            let recipient: ShareRecipient
            let score: Double
            let latest: Date
        }
        let scored: [Scored] = recipients.map { r in
            var total = 0.0
            for date in r.shareDates {
                let ageDays: Double = max(now.timeIntervalSince(date), 0) / 86_400
                total += pow(0.5, ageDays / 30)
            }
            return Scored(recipient: r, score: total,
                          latest: r.shareDates.max() ?? .distantPast)
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.latest > $1.latest }
            .map(\.recipient)
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
        let today = calendar.startOfDay(for: date)
        if today != day {
            day = today
            meters = 0
        }
        meters += max(delta, 0)   // a GPS glitch must never drive the total down
    }
}

/// One person the driver has shared a route with, and when.
struct ShareRecipient: Codable, Equatable {
    var name: String
    var phone: String
    var shareDates: [Date]
}

/// Prior share recipients (UserDefaults JSON, injectable for tests — same
/// shape as FavoritesStore). PRIVACY: this history never leaves the device.
/// It is a small suggestion list, not a message log — both dimensions are
/// capped so it stays a preference-sized blob.
@MainActor
final class ShareHistoryStore: ObservableObject {
    @Published private(set) var recipients: [ShareRecipient] = []

    private let defaults: UserDefaults
    private static let key = "flows.shareHistory"
    static let maxRecipients = 12
    static let maxDatesPerRecipient = 10

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([ShareRecipient].self, from: data) {
            recipients = saved
        }
    }

    /// Digits-only matching so "+1 (555) 010-2030" and "15550102030" stay
    /// one person. (The same number typed with and without a country code
    /// still makes two entries — acceptable for a suggestion list.)
    static func normalized(_ phone: String) -> String {
        phone.filter(\.isNumber)
    }

    func recordShare(name: String, phone: String, at date: Date = Date()) {
        let key = Self.normalized(phone)
        guard !key.isEmpty else { return }
        if let i = recipients.firstIndex(where: { Self.normalized($0.phone) == key }) {
            if !name.isEmpty { recipients[i].name = name }
            recipients[i].shareDates.append(date)
            let overflow = recipients[i].shareDates.count - Self.maxDatesPerRecipient
            if overflow > 0 { recipients[i].shareDates.removeFirst(overflow) }
        } else {
            recipients.append(ShareRecipient(name: name, phone: phone, shareDates: [date]))
        }
        if recipients.count > Self.maxRecipients {
            // Evict the WEAKEST suggestion, not the oldest entry — the list
            // exists to rank, so the ranking decides who stays.
            recipients = Array(TripShareLogic.ranked(recipients, now: date)
                .prefix(Self.maxRecipients))
        }
        persist()
    }

    /// Best-first recipient suggestions (see TripShareLogic.ranked).
    func suggestions(now: Date = Date()) -> [ShareRecipient] {
        TripShareLogic.ranked(recipients, now: now)
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(recipients), forKey: Self.key)
        } catch {
            print("[TripShare] persist failed: \(error)")
        }
    }
}
