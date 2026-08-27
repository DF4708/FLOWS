// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Where the speed bar's warning lines sit, and what they actually mean.
///
/// HONEST FOOTING, because this is a legal claim shown to a driver:
///
///  * There is NO general federal speed limit in the United States. The
///    national 55/65 mph cap (the NMSL) was repealed in 1995; since then
///    every posted limit is set by STATE law. So the first line — the one
///    that turns the bar yellow — is the posted limit itself: passing it is
///    a state traffic violation, which is what a speeding ticket is.
///
///  * Speeding becomes a FEDERAL matter in two real ways, both of which sit
///    well above the posted limit rather than at it: on federal land and in
///    federal enclaves (national parks, military bases, federal highways in
///    them) the Assimilative Crimes Act, 18 U.S.C. § 13, adopts the state's
///    limit and prosecutes the violation in federal court; and for
///    commercial vehicles the FMCSA (49 C.F.R. § 392.6) forbids operating on
///    a schedule that requires exceeding posted limits. Both escalate at
///    gross excess, not at 1 mph over — and gross excess is also where every
///    state's reckless-driving statute takes over from a plain citation.
///
/// So the red line is drawn at the excess-speed threshold, not at a
/// nonexistent federal number, and `federalNote` says so in plain words.
enum SpeedLaw {
    /// A few mph of slack before the yellow line: speedometers read high,
    /// and enforcement practice allows for it.
    static let stateToleranceMph = 5.0
    /// Gross excess over the posted limit — where a citation becomes a
    /// reckless/excessive-speed charge, and where a federal-enclave stop
    /// stops being routine. Most states put reckless at 15–25 over.
    static let excessOverLimitMph = 20.0
    /// …and an absolute floor for the same idea on slow roads: 20 over a
    /// 25 mph street is 45, which is already excessive by any measure.
    static let excessAbsoluteMph = 85.0

    /// The speed at which the bar turns yellow: over the posted limit
    /// (plus tolerance) is a state violation.
    static func stateThresholdMph(postedLimitMph: Double?) -> Double? {
        guard let postedLimitMph, postedLimitMph > 0 else { return nil }
        return postedLimitMph + stateToleranceMph
    }

    /// The speed at which the bar turns red: gross excess, where the offense
    /// escalates beyond an ordinary citation (and is charged federally on
    /// federal land).
    static func federalThresholdMph(postedLimitMph: Double?) -> Double? {
        guard let postedLimitMph, postedLimitMph > 0 else { return nil }
        return min(postedLimitMph + excessOverLimitMph, excessAbsoluteMph)
    }

    /// What the driver is doing right now, legally speaking.
    enum Standing: Equatable {
        case legal
        /// Over the posted limit — a state traffic violation.
        case stateViolation
        /// Gross excess — reckless/excessive speed, federal on federal land.
        case federalViolation
    }

    static func standing(speedMph: Double, postedLimitMph: Double?) -> Standing {
        guard let fed = federalThresholdMph(postedLimitMph: postedLimitMph),
              let state = stateThresholdMph(postedLimitMph: postedLimitMph) else {
            return .legal   // nothing posted → nothing to violate
        }
        if speedMph >= fed { return .federalViolation }
        if speedMph >= state { return .stateViolation }
        return .legal
    }

    /// The top of the speed bar: the vehicle's own maximum where known,
    /// otherwise a sane ceiling that still leaves the posted limit readable.
    static let defaultTopSpeedMph = 120.0

    static func barTopMph(vehicleTopSpeedMph: Double?) -> Double {
        guard let v = vehicleTopSpeedMph, v > 20 else { return defaultTopSpeedMph }
        return v
    }

    /// Headroom above anything that must stay visible, so a line or the
    /// fill never sits jammed against the right end.
    static let headroom = 1.15

    /// The top of the bar. It STARTS at the vehicle's own maximum (or 120
    /// when nothing is known) and only ever ZOOMS OUT from there — if the
    /// driver passes the red line, or a road's thresholds land beyond the
    /// vehicle's rated top, the scale widens to keep the current speed and
    /// BOTH legal lines inside the bar. It never narrows below the default,
    /// so the scale a driver learns to read stays put.
    static func dynamicTopMph(speedMph: Double,
                              postedLimitMph: Double?,
                              vehicleTopSpeedMph: Double?) -> Double {
        let base = barTopMph(vehicleTopSpeedMph: vehicleTopSpeedMph)
        let mustShow = max(speedMph,
                           stateThresholdMph(postedLimitMph: postedLimitMph) ?? 0,
                           federalThresholdMph(postedLimitMph: postedLimitMph) ?? 0)
        guard mustShow * headroom > base else { return base }
        // Widen in clean tens so the number doesn't flicker mid-acceleration.
        return (mustShow * headroom / 10).rounded(.up) * 10
    }

    /// Where a threshold sits along the bar, 0…1 — nil when it's off the end.
    static func barFraction(_ mph: Double?, topMph: Double) -> Double? {
        guard let mph, topMph > 0, mph <= topMph else { return nil }
        return min(max(mph / topMph, 0), 1)
    }

    /// Plain-words footnote for the red line, so the app never implies a
    /// federal speed limit exists.
    static let federalNote =
        "Limits are set by state law. The red line marks excessive speed — "
        + "a reckless-driving charge, and a federal case on federal land."
}

/// The compass reading under the banner needle: degrees and the 16-point
/// cardinal name a driver actually says out loud.
enum CompassReading {
    static let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                         "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    /// Normalize any heading (including the -1 CoreLocation reports when it
    /// has no course) into 0..<360.
    static func normalized(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    static func cardinal(_ degrees: Double) -> String {
        let d = normalized(degrees)
        let idx = Int((d / 22.5).rounded()) % points.count
        return points[idx]
    }

    /// "312° NW" — the whole reading, ready to draw.
    static func label(_ degrees: Double) -> String {
        let d = normalized(degrees)
        return String(format: "%.0f° %@", d, cardinal(d))
    }
}
