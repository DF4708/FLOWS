// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import FlowsBridge
import Foundation

/// What the map's sweep makes of one point: which hazard families show
/// there, what the risk band is fed, and what names the badge. The rules sat
/// inline in the map view's sweep, where no test could see them.
///
/// The rules are computed in rust/flows-core (viewport_point.rs) and called
/// through rust/flows-bridge; pinned bit for bit to the Swift they replaced
/// by rust/flows-bridge/tests/fixtures/swift_viewport_point_oracle.tsv. The
/// floors live there: a point shows from 0.25 on the blended forecast or on
/// any one family, a family names the badge from 0.45, an alert from 0.6, a
/// closure from 0.8, and a realized primary takes the name from a predictor
/// at Yellow.
enum ViewportPointRules {
    /// The live readings at one point, each already scored 0 to 1.
    struct Live: Equatable {
        var fire = 0.0
        var seismic = 0.0
        var volcanic = 0.0
        var avalanche = 0.0
        var tropical = 0.0
        var tsunami = 0.0
        /// The severe-storm outlook.
        var convective = 0.0
        var spaceRadiation = 0.0
        /// The river gauges alone.
        var floodRealized = 0.0
        /// Air quality; nil when there is no reading.
        var air: Double?
        var uv = 0.0
    }

    private static let separator = "\u{1F}"
    /// The families a live reading can add to the forecast's own.
    private static let liveNames = [
        "fire", "seismic", "qpf_flood", "air", "radiation", "volcanic", "avalanche", "tropical", "tsunami",
        "convective",
    ]
    /// The band's own families, in the order Rust returns their scores.
    private static let bandNames: [String] = flows_viewport_band_names().text
        .split(separator: "\u{1F}").map(String.init)

    /// The families that show at a point: the forecast's own, with the live
    /// readings laid over them. Nil when nothing registers there: neither
    /// the blended forecast `score` nor any one family reaches the show
    /// floor. The family overlay needs a point even when the blended score
    /// is quiet.
    static func displayFamilies(score: Double, forecast: [String: Double], live: Live) -> [String: Double]? {
        // Every name the answer could hold: the forecast's first, then the
        // live families it does not already have. Never empty.
        let pairs = Array(forecast)
        var names = pairs.map(\.key)
        var scores = pairs.map(\.value)
        for name in liveNames where forecast[name] == nil {
            names.append(name)
            scores.append(0)
        }
        let readings = [
            live.fire, live.seismic, live.volcanic, live.avalanche, live.tropical, live.tsunami, live.convective,
            live.spaceRadiation, live.floodRealized, live.air ?? 0, live.uv,
        ]
        let joined = names.joined(separator: separator)
        let out = Array(
            scores.lent { s in
                readings.lent { r in
                    flows_viewport_display(
                        score, joined, s, Int64(names.count), Int64(pairs.count), r, live.air != nil)
                }
            })
        // No answer: show the point on the forecast rather than hide it.
        guard out.count == 1 + 2 * names.count else { return forecast }
        guard out[0] == 1 else { return nil }
        var families: [String: Double] = [:]
        for (i, name) in names.enumerated() where out[1 + 2 * i] == 1 {
            families[name] = out[2 + 2 * i]
        }
        return families
    }

    /// What names the badge.
    enum Icon: Equatable {
        /// This family.
        case family(String)
        /// The flood family won on rain chance alone: "it may rain".
        case rainChance
        /// No family is elevated: the forecast names it (heat, cold, wind, rain).
        case forecast
        /// The alert in force here.
        case alert
        /// The road is closed.
        case closure
    }

    struct Point: Equatable {
        /// The display families, with a closure added.
        var families: [String: Double]
        /// What the risk band is fed.
        var bandInput: [String: Double]
        var icon: Icon
    }

    /// The band's input and the badge's name for a point that shows.
    ///
    /// The WORST hazard names the area, every family on the same footing
    /// (`HazardRanking.dominantFamily`); the blended "environmental"
    /// composite is not a hazard and never names it. An in-progress-danger
    /// warning names it over that. A closure is proof the road is blocked,
    /// but a Tornado Warning at the same point is the greater danger: the
    /// alert keeps the icon. Last, when the name came from a predictor and a
    /// realized primary (fire perimeter, gauge flood, quake) is what makes
    /// the area serious, the primary names it. Equal primaries go to the
    /// lower family name, so the name does not change between launches.
    ///
    /// The band's input is the driving-safety split, separate from the
    /// display families (which merge rain PROBABILITY into the Flood and
    /// Storm map filters): realized primaries can reach Red, predictors
    /// only amplify one.
    static func point(
        families shown: [String: Double], live: Live, precipRisk: Double,
        alertFamily: String?, alertSeverity: Double, closed: Double
    ) -> Point {
        let pairs = Array(shown)
        // An empty list never crosses: one score and a count of zero.
        let joined = pairs.isEmpty ? "-" : pairs.map(\.key).joined(separator: separator)
        let scores = pairs.isEmpty ? [0] : pairs.map(\.value)
        let out = Array(
            scores.lent {
                flows_viewport_point(
                    joined, $0, Int64(pairs.count), live.floodRealized, live.convective, precipRisk,
                    alertFamily ?? "-", alertFamily != nil, alertSeverity, closed)
            })
        // No answer: keep what shows, feed the band all of it (the careful
        // side), and leave the name to the forecast.
        guard out.count == 9 + bandNames.count else {
            return Point(families: shown, bandInput: shown, icon: .forecast)
        }
        var families = shown
        if out[3] == 1 { families["closure"] = out[4] }
        var bandInput: [String: Double] = [:]
        for (i, name) in bandNames.enumerated() { bandInput[name] = out[9 + i] }
        if let alertFamily, out[7] == 1 { bandInput[alertFamily] = out[8] }
        if out[5] == 1 { bandInput["closure"] = out[6] }
        let icon: Icon
        switch out[0] {
        case 0:
            let i = Int(out[2])
            switch out[1] {
            case 0 where pairs.indices.contains(i): icon = .family(pairs[i].key)
            case 1 where bandNames.indices.contains(i): icon = .family(bandNames[i])
            case 2: icon = alertFamily.map { .family($0) } ?? .forecast
            case 3: icon = .family("closure")
            default: icon = .forecast
            }
        case 1: icon = .rainChance
        case 3: icon = .alert
        case 4: icon = .closure
        default: icon = .forecast
        }
        return Point(families: families, bandInput: bandInput, icon: icon)
    }
}
