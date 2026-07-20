// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// North-America-wide latitude band profiles — the generalization of the
/// R server's Wisconsin band system (data/wi_latitude_band_profiles.csv +
/// R/forecast.R assign_lat_band):
///
///   * Wisconsin carries 10 equal bands (pitch 0.4767636°) whose temperature
///     norms step exactly −1°F per band northward. The SAME pitch and
///     gradient extend north through Canada and south through Mexico —
///     one Wisconsin-height north is bands 11–20, and the 14°N…70°N
///     continental span holds bands −59…+59 (119 bands).
///   * A location's EFFECTIVE band may shift from its latitude default by AT
///     MOST ±1 band (the contiguous rule) driven by elevation: high terrain
///     is climatically "one band north". The Rockies therefore squeeze
///     toward their poleward neighbors without ever jumping bands — the
///     clamp IS the upper/lower limit the rule demands.
///   * Inside Wisconsin the values are the R server's EXACT rows
///     (R-anchored vectors in FLOWSTests); beyond, the linear gradient is
///     clamped to physical extremes so a 59-band extrapolation can't invent
///     impossible climates.
enum LatitudeBands {
    // Exact anchors from the R server (sf::st_bbox of the WI ZCTAs).
    static let southAnchor = 42.312985
    static let northAnchor = 47.080621
    /// Computed exactly as R does ((north − south) / n_bands) — a truncated
    /// literal here shifted right-closed band boundaries by one (caught by
    /// the R-anchored vectors).
    static let pitchDegrees = (northAnchor - southAnchor) / 10

    /// Continental clamps (southern Mexico … arctic Canada).
    static let minLatitude = 14.0
    static let maxLatitude = 70.0

    /// Elevation → band shift: one band's 1°F step at the standard lapse
    /// rate (6.5°C/km ≈ 0.0117°F/m) is ~85.5 m; profiles assume ~300 m
    /// (Wisconsin's mean). Clamped to ±1 — the contiguous rule.
    static let referenceElevationMeters = 300.0
    static let metersPerBandStep = 85.47

    struct Profile: Equatable {
        var band: Int
        var comfortLowF: Double
        var comfortHighF: Double
        var recordLowF: Double
        var recordHighF: Double
        // Wind/PoP thresholds are constant across the WI CSV; carried on the
        // profile so regional refinement has a seat when data arrives.
        var windLow = 15.0, windMedium = 28.0, windHigh = 45.0
        var popLow = 25.0, popMedium = 50.0, popHigh = 75.0
    }

    /// R semantics (cut(..., include.lowest=TRUE)): band 1 starts AT the
    /// south anchor; each band is (lo, hi]. Extended to any latitude —
    /// negative and >10 indices are the continental extension.
    static func bandIndex(latitude: Double) -> Int {
        let lat = min(max(latitude, minLatitude), maxLatitude)
        if lat <= southAnchor {
            // Southward: band 0 is the first band below WI, then negative.
            return Int(((lat - southAnchor) / pitchDegrees).rounded(.down)) + 1
        }
        // Right-closed bands (R cut() semantics): a latitude exactly ON a
        // boundary belongs to the band BELOW it; the epsilon absorbs the
        // floating-point residue of the division at exact boundaries.
        return Int((((lat - southAnchor) / pitchDegrees) - 1e-9).rounded(.up))
    }

    /// Elevation-driven shift, clamped to ±1 (contiguous rule).
    static func elevationBandShift(elevationMeters: Double?) -> Int {
        guard let elev = elevationMeters, elev.isFinite else { return 0 }
        let raw = ((elev - referenceElevationMeters) / metersPerBandStep).rounded()
        return Int(min(max(raw, -1), 1))
    }

    /// The band profile for a location. Inside WI (bands 1–10) these equal
    /// the R server's CSV rows exactly; beyond, the −1°F/band gradient
    /// extends with physical clamps.
    static func profile(latitude: Double, elevationMeters: Double? = nil) -> Profile {
        var band = bandIndex(latitude: latitude)
            + elevationBandShift(elevationMeters: elevationMeters)
        // Keep the shifted band inside the continental system.
        let maxBand = bandIndex(latitude: maxLatitude)
        let minBand = bandIndex(latitude: minLatitude)
        band = min(max(band, minBand), maxBand)

        let step = Double(band - 1)   // WI band 1 is the anchor row
        var p = Profile(
            band: band,
            comfortLowF: 60 - step,
            comfortHighF: 76 - step,
            recordLowF: -28 - step,
            recordHighF: 108 - step)
        // Physical clamps for the long extrapolation (tropics / arctic).
        p.comfortLowF = min(max(p.comfortLowF, -10), 72)
        p.comfortHighF = min(max(p.comfortHighF, p.comfortLowF + 10), 92)
        p.recordLowF = min(max(p.recordLowF, -80), 45)
        p.recordHighF = min(max(p.recordHighF, p.comfortHighF + 10), 125)
        return p
    }
}
