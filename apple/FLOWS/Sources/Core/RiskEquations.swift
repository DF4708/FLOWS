// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// The app's doorway to the risk equations. There is no arithmetic here: each
/// member calls rust/flows-core (families.rs, scoring.rs) through
/// rust/flows-bridge, and the tables are read from Rust once (`RustTables`),
/// so Swift holds no copy of a weight, a threshold or a family list.
///
/// Still locked to the R-computed vectors in FLOWSTests
/// (RiskEquationVectors.swift), and — bit for bit, NaN and signed zero
/// included — to the Swift implementation this replaced, by the frozen oracle
/// in rust/flows-bridge/tests/fixtures/swift_risk_oracle.tsv.
enum RiskEquations {

    // MARK: R/scoring.R piecewise_score (line 244)

    /// 0 below `low`; linear GREEN_MIN→YELLOW_MIN across [low, medium];
    /// YELLOW_MIN→RED_MIN across (medium, high]; RED_MIN→1 above, slope
    /// (value−high)/high, capped at 1.
    static func piecewiseScore(_ value: Double, low: Double, medium: Double, high: Double) -> Double {
        flows_piecewise_score(value, low, medium, high)
    }

    // MARK: R/scoring.R temperature_risk (line 279)

    /// 0 inside the comfort band; linear toward the record extremes, capped.
    static func temperatureRisk(
        tempF: Double, comfortLowF: Double, comfortHighF: Double,
        recordLowF: Double, recordHighF: Double
    ) -> Double {
        flows_temperature_risk(tempF, comfortLowF, comfortHighF, recordLowF, recordHighF)
    }

    /// Is a temperature an UNUSUAL deviation for this climate — outside one
    /// standard deviation of local norms? The climate envelope gives comfort
    /// and record bounds; with the record ≈ the tail of the local distribution,
    /// σ ≈ (record − comfort)/3 per side. Used to GATE MAP PRESENTATION only
    /// (heat/cold badges and tints): a mildly-warm day scores small risk but
    /// isn't noteworthy enough to draw. The risk equations themselves are
    /// unchanged (R parity).
    static func temperatureAnomalous(
        tempF: Double, comfortLowF: Double, comfortHighF: Double,
        recordLowF: Double, recordHighF: Double
    ) -> Bool {
        flows_temperature_anomalous(tempF, comfortLowF, comfortHighF, recordLowF, recordHighF)
    }

    // MARK: R/forecast.R:226–228 — the canonical forecast thresholds/weights

    static func windRisk(mph: Double) -> Double { flows_wind_risk(mph) }
    static func popRisk(pct: Double) -> Double { flows_pop_risk(pct) }

    /// forecast_score = min(1, 0.45·temp + 0.30·wind + 0.25·pop)  (R exact)
    static func forecastComposite(temp: Double, wind: Double, pop: Double) -> Double {
        flows_forecast_composite(temp, wind, pop)
    }

    // MARK: R/families.R environmental_family_weights (line 471) — exact

    static let familyWeights: [String: Double] = RustTables.weights

    // MARK: R/families.R noisy_or_combine (line 497) — exact shape

    /// 1 − Π(1 − wᵢ·clamp(sᵢ)) over (family, score) pairs.
    ///
    /// The product is taken in ARRAY order; the caller owns that order and,
    /// if two callers must agree bit for bit, should sort by family name
    /// first (the canonical order `realizedRisk` uses).
    static func noisyOr(_ scores: [(family: String, score: Double)]) -> Double {
        // An empty list has an empty answer; nothing to send across.
        guard !scores.isEmpty else { return 0 }
        let names = scores.map(\.family).joined(separator: "\u{1F}")
        return scores.map(\.score).withUnsafeBufferPointer { flows_noisy_or_named(names, $0) }
    }

    // MARK: primary vs. secondary realization model

    /// Families that are directly life-threatening WHILE DRIVING and backed by
    /// PROOF — an OBSERVED event/detection or a reported road closure, never a
    /// forecast. Only a realized one can drive the band to Red. The test is
    /// TRAVEL SAFETY: the road is impassable (water over the road, a gauge in
    /// flood, the ground moved, a closure) or the driver is in direct danger
    /// passing through (in the fire — smoke/oxygen deprivation, heat, fallen
    /// trees; a tsunami you can't outrun; an erupting volcano). Every
    /// forecast/outlook/warning lives in `secondaryFamilies`.
    /// `storm` = a REALIZED severe/tornadic storm (an NWS Tornado / Severe
    /// Thunderstorm WARNING — happening/imminent-confirmed), distinct from the
    /// SPC `convective` OUTLOOK (a probability), which stays a predictor.
    /// `closure` = a DOT-reported road closure (WZDx all-lanes-closed) — the
    /// literal "proof of blocked road" primary: uncleared snow, washouts, and
    /// slides band Red the moment the state DOT reports the closure.
    ///
    /// Read from rust/flows-core, sorted by name; the Set below derives from it.
    static let primaryOrder: [String] = RustTables.primary
    static let primaryFamilies: Set<String> = Set(primaryOrder)

    /// PREDICTOR / amplifier families — conditions or FORECASTS that raise the
    /// likelihood or severity of a realized primary but are NOT proof of a
    /// blocked road or an in-progress danger: high wind, heat, cold, haze/smoke,
    /// UV/space radiation, precipitation PROBABILITY, a FORECAST of winter (snow
    /// predicted, not a blocked road), the SPC severe-weather OUTLOOK
    /// (`convective` — a probability, not a tornado on the road), and the
    /// avalanche DANGER RATING (`avalanche` — a forecast, not an avalanche).
    /// They spike a realized primary; alone they only advise (capped below Red).
    /// Each realized form (a Tornado/Flash-Flood/Tsunami Warning, an avalanche or
    /// snow road closure) becomes a primary the moment that proof feed is wired.
    ///
    /// Read from rust/flows-core, sorted by name — see `primaryOrder`.
    static let secondaryOrder: [String] = RustTables.secondary
    static let secondaryFamilies: Set<String> = Set(secondaryOrder)

    /// Upper-Yellow ceiling for a secondary-only situation: a pile of
    /// predictors (extreme fire-weather with no fire, high UV, haze, a windy
    /// clear day) can warn strongly but never reads life-threatening without a
    /// realized primary. Structurally below RISK_RED_MIN (0.8751).
    static let secondaryCeiling = flows_secondary_ceiling()

    /// Compounded, REALIZED risk from a family→score map — the total the
    /// Green/Yellow/Red band cuts are meant to sit on, honoring the
    /// primary/secondary structure:
    ///   • primaries combine by unweighted noisy-OR, so a realized primary
    ///     keeps its full severity and two independent primaries compound;
    ///   • secondaries (weighted noisy-OR = the R engine's combine) AMPLIFY the
    ///     realized primary — scaled by how realized it is, so no primary ⇒ no
    ///     amplification;
    ///   • secondaries alone yield only a capped advisory (never Red);
    ///   • total = max(amplified primary, capped secondary advisory).
    /// So several small or overlapping risks can never sum to a life-threatening
    /// total — Red requires a realized primary. Families outside both sets
    /// (e.g. the derived `environmental` composite) are ignored to avoid
    /// double-counting the temp/wind/pop signals their constituents already hold.
    /// Assemble the two-tier band input for one point: the modeled field
    /// and the on-device forecast as PREDICTORS, an in-progress-danger
    /// alert as the realized primary, unmapped life-safety orders and DOT
    /// closures filed as the closure primary. Lived inline in AppModel for
    /// a year with no test; every surface that bands a point calls this.
    ///
    /// - field: the modeled ZIP field's score for a family, 0 when absent.
    /// - onDevice: the on-device forecast's per-family predictors.
    static func bandInput(field: (String) -> Double,
                          onDevice: [String: Double],
                          alertEvent: String?, alertSeverity: Double,
                          floodMultiplier: Double = 1,
                          closureScore: Double = 0,
                          live: [String: Double] = [:]) -> [String: Double] {
        func predictor(_ fam: String, _ deviceKey: String) -> Double {
            max(field(fam), onDevice[deviceKey] ?? 0)
        }
        var out: [String: Double] = [
            "wind": predictor("wind", "wind"),
            "heat": predictor("heat", "heat"),
            "cold": predictor("cold", "cold"),
            "air": field("air"),
            "radiation": field("radiation"),
            "winter": predictor("winter", "winter"),
            "convective": predictor("convective", "convective"),
            // modeled flood risk + forecast rain = a flood PREDICTOR, not
            // proof. The relative-elevation multiplier (rain inches × how low
            // this sample sits in the LOCAL terrain) amplifies it — a valley
            // floor in heavy rain reads riskier than the ridge beside it;
            // still capped as a secondary, never Red alone.
            "precip": min(1, predictor("qpf_flood", "precip") * floodMultiplier),
        ]
        // Live-feed evidence — fire perimeters and hotspots, earthquakes,
        // volcanoes, tropical storms, tsunami events (realized primaries) and
        // the avalanche rating, space weather and the SPC outlook
        // (predictors) — scored per point by HazardFeedScores.live. Merged by
        // max per family, so the dictionary's order cannot reach a product,
        // and a route sees exactly what the map sweep sees.
        for (fam, v) in live where v > 0 {
            out[fam] = max(out[fam] ?? 0, v)
        }
        if let ev = alertEvent, let fam = alertFamily(ev) {
            out[fam] = max(out[fam] ?? 0, alertSeverity)
        } else if let ev = alertEvent, ImminentAlerts.isLifeSafetyEvent(ev),
                  !ImminentAlerts.isLookoutEvent(ev) {
            // Radiological, hazmat, shelter-in-place, civil danger,
            // evacuation: no WEATHER family maps them. For routing they are
            // what a closure is — proof the road should not be driven.
            out["closure"] = max(out["closure"] ?? 0, alertSeverity)
        }
        // DOT-reported closure: PROOF the road is blocked — realized primary.
        if closureScore > 0 { out["closure"] = max(out["closure"] ?? 0, closureScore) }
        return out
    }

    static func realizedRisk(_ families: [String: Double]) -> Double {
        // Dense encoding shared with Rust: one slot per family it knows, NaN
        // for absent. Each score lands in its fixed slot, so the order this
        // Dictionary iterates in can never reach the product. Stack storage;
        // this runs per corridor sample per route.
        let slots = RustTables.dense.count
        return withUnsafeTemporaryAllocation(of: Double.self, capacity: slots) { buf in
            buf.initialize(repeating: .nan)
            for (family, score) in families {
                if let i = RustTables.denseIndex[family] { buf[i] = score }
            }
            return flows_realized_risk_dense(UnsafeBufferPointer(buf))
        }
    }

    /// WATERLINE-THRESHOLD flood amplifier (multiplier ≥ 1 on the precip
    /// PREDICTOR — never proof; the realized primary stays the gauge/warning/
    /// closure). Water pools toward the LOCAL minimum and rises by the rain
    /// depth, so the physics is a threshold, not a linear ramp:
    ///
    ///   waterline = localMin + rainDepth   (rain accumulates at the low point)
    ///   headroom  = roadElevation − localMin   (how far the road sits above it)
    ///
    /// • headroom ≤ rainDepth → the risen waterline REACHES the road: a physical
    ///   flood crossing, amplified regardless of other evidence (1.6…2.0×).
    /// • headroom > rainDepth → the road is above the pooling water. Between the
    ///   local min and the road there is NO guarantee of flooding — the user's
    ///   rule — so it gets a bump ONLY with SUPPORTING EVIDENCE that water
    ///   reaches it (a FEMA A/V flood zone, a river gauge at/above flood stage,
    ///   or a mapped river/lake nearby), tapered by how close the waterline
    ///   comes. No evidence → 1.0 (no elevation-driven flood bump).
    ///
    /// Units: `qpfInches` is inches, elevations are meters → rain is converted
    /// (× 0.0254) so the inch-vs-meter comparison is real, not dodged.
    /// `localMinElevation` MUST be a WINDOWED local minimum (the nearby pooling
    /// low), not the whole corridor's global low hundreds of km away.
    static func floodElevationMultiplier(
        sampleElevation: Double?, localMinElevation: Double?,
        qpfInches: Double?, supportingEvidence: Double = 0
    ) -> Double {
        flows_flood_elevation_multiplier(
            sampleElevation ?? 0, sampleElevation != nil,
            localMinElevation ?? 0, localMinElevation != nil,
            qpfInches ?? 0, qpfInches != nil,
            supportingEvidence)
    }

    /// Balance the two truths for ROUTE ORDERING (never the display band): the
    /// realized-risk `band` (alerts + current conditions) and the IDENTIFIED ZIP
    /// exposure (the modeled field, then the on-device seasonal prior). A ZIP can
    /// carry known risk before any alert, and an alert can fire without prior ZIP
    /// risk — both are evidence. Identified risk is discounted (×0.6) relative to
    /// a realized hazard, so a realized Red still dominates; but between two
    /// same-band routes the one through lower-identified-risk ZIPs ranks safer.
    /// As the seasonal prior for THIS route/week accrues `priorConfidence`, it
    /// takes over from the static field. Noisy-OR so neither truth is erased.
    static func rankingRisk(band: Double, zipExposure: Double,
                            seasonalPrior: Double = 0, priorConfidence: Double = 0) -> Double {
        flows_ranking_risk(band, zipExposure, seasonalPrior, priorConfidence)
    }

    /// Classify an NWS alert EVENT name into the `realizedRisk` family it feeds.
    /// The family's set membership (primary vs secondary) then decides whether it
    /// can reach Red: an in-progress-danger WARNING maps to a PRIMARY family
    /// (`storm`/`qpf_flood`/`tsunami`/`tropical`/`volcanic`), while a watch,
    /// advisory, or condition warning (Winter Storm, High Wind, Red Flag, Flood
    /// Watch, SPC-style thunderstorm watch) maps to a PREDICTOR family — capped,
    /// never Red on a forecast alone. Returns nil for events with no mapping.
    /// Order matters: the specific realized phrases are tested before the generic
    /// family words they contain. Shared by the route scorer and live corridor
    /// monitor so they band alerts exactly as the map does.
    static func alertFamily(_ event: String) -> String? {
        let i = Int(flows_alert_family_index(event))
        return RustTables.dense.indices.contains(i) ? RustTables.dense[i] : nil
    }
}


extension RiskEquations {
    /// The single worst family at or above `floor` — a plain maximum with no
    /// acute nudge, for callers that want the dominant READING rather than
    /// the name to draw (the traffic-delay weather bucket, the learned-ETA
    /// road class). Exact ties go to the lower name, so two launches agree.
    /// `nil` when nothing clears the floor.
    static func peakFamily(_ families: [String: Double], floor: Double) -> String? {
        let pairs = Array(families)
        guard !pairs.isEmpty else { return nil }
        let names = pairs.map(\.key).joined(separator: "\u{1F}")
        let i = Int(pairs.map(\.value).withUnsafeBufferPointer {
            flows_peak_family_position(names, $0, floor)
        })
        return pairs.indices.contains(i) ? pairs[i].key : nil
    }
}

/// How a whole route's risk band is decided from its pieces.
enum RouteRiskBand {
    /// The band to LABEL a route with.
    ///
    /// Normally this is the distance-weighted average: what fraction of the
    /// miles you actually travel sit at what risk. A minority yellow stretch
    /// should not paint an otherwise clear trip yellow.
    ///
    /// A RED peak is different, and is a floor rather than an average. You
    /// cannot average your way out of a tornado warning: two miles of it in
    /// the middle of a twenty-mile trip is not a green trip, and diluting it
    /// is how the same corridor came out full red for driving and half green
    /// for walking — the two modes sample the same ground at different
    /// densities, so any average disagrees with itself between them. A
    /// life-safety hazard on the path is the same hazard whichever way you
    /// are travelling.
    static func displayed(weighted: Double, peak: Double) -> Double {
        flows_displayed_band(weighted, peak)
    }
}


/// Which hazard gets to NAME an area on the map.
enum HazardRanking {
    /// Hazards that are a DISTINCT named danger rather than a reading on a
    /// dial — the thing a driver most needs called by its name when scores
    /// are close. They get a nudge, not a veto.
    static let acuteFamilies: Set<String> = Set(RustTables.acute)

    /// How much an acute hazard is favoured when scores are close. Small on
    /// purpose: enough to win a tie, nowhere near enough to beat a hazard
    /// that is materially worse.
    static let acuteNudge = flows_acute_nudge()

    /// The family that should NAME an area, comparing every hazard on the
    /// same footing.
    ///
    /// This used to be a hard priority tier: any "acute" family at 0.45 took
    /// the icon, and `convective` and `qpf_flood` weren't in the list at all
    /// — so storms and flooding could never name an area no matter how bad
    /// they were. A Georgia ZIP with a middling fire-weather reading and
    /// severe storms and flooding around it came out labelled FIRE. The same
    /// bug applied to every hazard on that list, not just fire: a 0.45 air
    /// or tropical reading equally outranked a 0.9 storm.
    ///
    /// Now the highest score wins, with acute hazards carrying a small
    /// nudge for ties. Returns nil when nothing is elevated enough to name.
    ///
    /// Exact ties go to the LOWER family name, so the answer depends on the
    /// input set and not on the order a Dictionary happens to yield it in
    /// (which changes between launches). Same rule as rust/flows-core.
    static func dominantFamily(_ families: [String: Double],
                               floor: Double = 0.45) -> String? {
        let pairs = Array(families)
        guard !pairs.isEmpty else { return nil }
        let names = pairs.map(\.key).joined(separator: "\u{1F}")
        let i = Int(pairs.map(\.value).withUnsafeBufferPointer {
            flows_dominant_family_position(names, $0, floor)
        })
        return pairs.indices.contains(i) ? pairs[i].key : nil
    }


}

/// Tables read once from rust/flows-core, so Swift holds no copy of them.
enum RustTables {
    private static func strings(_ v: RustVec<RustString>) -> [String] {
        v.map { $0.as_str().toString() }
    }
    static let primary: [String] = strings(flows_primary_families())
    static let secondary: [String] = strings(flows_secondary_families())
    static let acute: [String] = strings(flows_acute_families())
    /// The dense family encoding the combine crosses with: every primary, then
    /// every secondary — the same slot order as flows_core::families::dense_family.
    static let dense: [String] = primary + secondary
    static let denseIndex: [String: Int] =
        Dictionary(dense.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    static let weights: [String: Double] = {
        let names = strings(flows_weighted_family_names())
        let values = flows_weighted_family_values()
        var out: [String: Double] = [:]
        for (i, name) in names.enumerated() where i < values.len() { out[name] = values[i] }
        return out
    }()
}
