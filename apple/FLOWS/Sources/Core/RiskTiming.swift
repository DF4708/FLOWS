// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Time-aware risk: a hazard only counts if it will still be there WHEN THE
/// DRIVER ARRIVES. A 10-hour route with an alert at the far end that expires
/// in 1 hour carries no real risk — the storm is long gone by the time the
/// vehicle reaches that stretch. Pure functions, pinned by FLOWSTests, and
/// computed in rust/flows-core (climate.rs) through rust/flows-bridge.
enum RiskTiming {
    /// Will an alert still be active when the driver reaches its stretch of
    /// road `arrivalOffset` seconds from now? Unknown expiry → assume active
    /// (never silently discount a hazard we can't time).
    static func isActive(expires: Date?, arrivalOffset: TimeInterval, now: Date = Date()) -> Bool {
        flows_climate_is_active(
            expires?.timeIntervalSinceReferenceDate ?? 0, expires != nil,
            arrivalOffset, now.timeIntervalSinceReferenceDate)
    }

    /// When an alert that gives no end time is taken to end (owner,
    /// 2026-11-11): as long as its kind of event usually runs, longer when
    /// it is severe, covers many `zones` (counties or forecast zones) or is
    /// seen rather than expected (`certainty`, the CAP word), counted from
    /// its `onset`, and never less than a quarter of that past `message`,
    /// when the message itself lapses. The equation and its table are
    /// `unknown_end_hours` in rust/flows-core (alerts.rs). `learned` is what
    /// this device has seen of the kind (AlertLengthMemory): how many
    /// events, and the mean logarithm of their lengths; a count of 0 is the
    /// measured table alone.
    static func unknownEnd(
        event: String, severityScore: Double, zones: Int,
        certainty: String?, onset: Date?, message: Date,
        learned: (count: Int, meanLn: Double) = (0, 0)
    ) -> Date {
        let word = certainty ?? ""
        let end = flows_alerts_unknown_end(
            event.isEmpty ? "Alert" : event, severityScore, Int64(max(zones, 1)),
            word.isEmpty ? "Unknown" : word, onset != nil,
            onset?.timeIntervalSinceReferenceDate ?? 0,
            message.timeIntervalSinceReferenceDate,
            Int64(max(learned.count, 0)), learned.meanLn.isFinite ? learned.meanLn : 0)
        // Never before the message lapses, whatever came back.
        guard end.isFinite else { return message.addingTimeInterval(12 * 3600) }
        return max(Date(timeIntervalSinceReferenceDate: end), message)
    }

    /// Seconds from departure to each of `sampleCount` uniformly spaced
    /// corridor samples on a route that takes `totalTravelSeconds` end to end.
    /// A count past the bridge's maximum (2^20) answers no samples — the
    /// Swift this replaced allocated until memory ran out.
    static func arrivalOffsets(sampleCount: Int, totalTravelSeconds: TimeInterval) -> [TimeInterval] {
        Array(flows_climate_arrival_offsets(Int64(sampleCount), totalTravelSeconds))
    }
}
