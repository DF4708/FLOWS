// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// What the map's sweep makes of one point: which hazard families show
/// there, what the risk band is fed, and what names the badge. The rules sat
/// inline in the map view's sweep, where no test could see them.
enum ViewportPointRules {
    /// A point shows on the map from this score up, on the blended forecast
    /// or on any one family.
    static let showFloor = 0.25
    /// A flood family below this on the gauges alone is only "it may rain".
    static let floodNameFloor = 0.45
    /// An alert names the badge from this severity up.
    static let alertNameFloor = 0.6
    /// A closure names the badge from this score up.
    static let closureNameFloor = 0.8

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

    /// The families that show at a point: the forecast's own, with the live
    /// readings laid over them. Nil when nothing registers there: neither
    /// the blended forecast `score` nor any one family reaches `showFloor`.
    /// The family overlay needs a point even when the blended score is quiet.
    static func displayFamilies(score: Double, forecast: [String: Double], live: Live) -> [String: Double]? {
        var families = forecast
        families["fire"] = live.fire
        families["seismic"] = live.seismic
        families["qpf_flood"] = max(families["qpf_flood"] ?? 0, live.floodRealized)
        if let air = live.air { families["air"] = air }
        // Space weather and UV share a family.
        let radiation = max(live.spaceRadiation, live.uv)
        if radiation > 0 { families["radiation"] = radiation }
        if live.volcanic > 0 { families["volcanic"] = live.volcanic }
        if live.avalanche > 0 { families["avalanche"] = live.avalanche }
        if live.tropical > 0 { families["tropical"] = live.tropical }
        if live.tsunami > 0 { families["tsunami"] = live.tsunami }
        if live.convective > 0 {
            families["convective"] = max(families["convective"] ?? 0, live.convective)
        }
        guard score >= showFloor || families.values.contains(where: { $0 >= showFloor }) else { return nil }
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
        var families = shown
        var icon: Icon
        var iconFamily: String? = nil
        if let top = HazardRanking.dominantFamily(families.filter { $0.key != "environmental" }) {
            icon = top == "qpf_flood" && live.floodRealized < floodNameFloor ? .rainChance : .family(top)
            iconFamily = top
        } else {
            icon = .forecast
        }
        var namedByAlert = false
        if let alertFamily, alertSeverity >= alertNameFloor, RiskEquations.primaryFamilies.contains(alertFamily) {
            icon = .alert
            namedByAlert = true
        }
        var bandInput: [String: Double] = [
            "fire": families["fire"] ?? 0,
            "qpf_flood": live.floodRealized,
            "convective": live.convective,
            "seismic": families["seismic"] ?? 0,
            "tropical": families["tropical"] ?? 0,
            "tsunami": families["tsunami"] ?? 0,
            "volcanic": families["volcanic"] ?? 0,
            "avalanche": families["avalanche"] ?? 0,
            "wind": families["wind"] ?? 0,
            "heat": families["heat"] ?? 0,
            "cold": families["cold"] ?? 0,
            "air": families["air"] ?? 0,
            "radiation": families["radiation"] ?? 0,
            "precip": precipRisk,
            "winter": families["winter"] ?? 0,
        ]
        // A realized alert at this point: a warning is a realized primary,
        // a watch or advisory classifies to a predictor.
        if let alertFamily {
            bandInput[alertFamily] = max(bandInput[alertFamily] ?? 0, alertSeverity)
        }
        if closed > 0 {
            bandInput["closure"] = closed
            families["closure"] = closed
            if closed >= closureNameFloor, !namedByAlert { icon = .closure }
        }
        let iconIsPrimary = iconFamily.map { RiskEquations.primaryFamilies.contains($0) } ?? false
        let worstPrimary =
            bandInput
            .filter { RiskEquations.primaryFamilies.contains($0.key) }
            .sorted { $0.key < $1.key }
            .max { $0.value < $1.value }
        if !namedByAlert, closed < closureNameFloor, !iconIsPrimary, let worst = worstPrimary,
            worst.value >= FlowsCore.riskYellowMin
        {
            icon = .family(worst.key)
        }
        return Point(families: families, bandInput: bandInput, icon: icon)
    }
}
