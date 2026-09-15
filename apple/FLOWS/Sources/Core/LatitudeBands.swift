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
///     is climatically "one band north".
///   * Inside Wisconsin the values are the R server's EXACT rows
///     (R-anchored vectors in FLOWSTests); beyond, the linear gradient is
///     clamped to physical extremes.
///
/// The anchors, the band arithmetic and the profile rows are computed in
/// rust/flows-core (climate.rs) and called through rust/flows-bridge; Swift
/// holds no copy of a number. Pinned to the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_climate_oracle.tsv.
enum LatitudeBands {
    // Exact anchors from the R server (sf::st_bbox of the WI ZCTAs).
    static let southAnchor = flows_climate_south_anchor()
    static let northAnchor = flows_climate_north_anchor()
    /// Computed exactly as R does ((north − south) / n_bands).
    static let pitchDegrees = flows_climate_pitch_degrees()
    /// Continental clamps (southern Mexico … arctic Canada).
    static let minLatitude = flows_climate_min_latitude()
    static let maxLatitude = flows_climate_max_latitude()
    /// Elevation → band shift: one band's 1°F step at the standard lapse
    /// rate is ~85.5 m; profiles assume ~300 m (Wisconsin's mean).
    static let referenceElevationMeters = flows_climate_reference_elevation_meters()
    static let metersPerBandStep = flows_climate_meters_per_band_step()

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

        /// A profile as the bridge answers it (`has` is checked by the caller).
        init(bridge p: FlowsClimateProfile) {
            band = Int(p.band)
            comfortLowF = p.comfort_low_f
            comfortHighF = p.comfort_high_f
            recordLowF = p.record_low_f
            recordHighF = p.record_high_f
            windLow = p.wind_low
            windMedium = p.wind_medium
            windHigh = p.wind_high
            popLow = p.pop_low
            popMedium = p.pop_medium
            popHigh = p.pop_high
        }

        init(band: Int, comfortLowF: Double, comfortHighF: Double, recordLowF: Double, recordHighF: Double) {
            self.band = band
            self.comfortLowF = comfortLowF
            self.comfortHighF = comfortHighF
            self.recordLowF = recordLowF
            self.recordHighF = recordHighF
        }
    }

    /// The Wisconsin anchor row (band 1): the answer for a latitude that is
    /// not a number, where the Swift this replaced crashed. A forecast for a
    /// point with no latitude has no band; the anchor keeps it finite.
    static let anchorProfile = Profile(band: 1, comfortLowF: 60, comfortHighF: 76, recordLowF: -28, recordHighF: 108)

    /// R semantics (cut(..., include.lowest=TRUE)): band 1 starts AT the
    /// south anchor; each band is (lo, hi]. Extended to any latitude —
    /// negative and >10 indices are the continental extension. A NaN
    /// latitude answers the anchor band (1), where the Swift crashed.
    static func bandIndex(latitude: Double) -> Int {
        let band = flows_climate_band_index(latitude)
        return band.is_some == 1 ? Int(band.value) : 1
    }

    /// Elevation-driven shift, clamped to ±1 (contiguous rule).
    static func elevationBandShift(elevationMeters: Double?) -> Int {
        Int(flows_climate_elevation_band_shift(elevationMeters ?? 0, elevationMeters != nil))
    }

    /// The band profile for a location. Inside WI (bands 1–10) these equal
    /// the R server's CSV rows exactly; beyond, the −1°F/band gradient
    /// extends with physical clamps.
    static func profile(latitude: Double, elevationMeters: Double? = nil) -> Profile {
        let p = flows_climate_band_profile(latitude, elevationMeters ?? 0, elevationMeters != nil)
        return p.has == 1 ? Profile(bridge: p) : anchorProfile
    }
}
