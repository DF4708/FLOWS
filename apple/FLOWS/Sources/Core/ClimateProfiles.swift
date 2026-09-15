// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// Per-location CLIMATE TYPE — a 2-D replacement for the 1-D latitude bands when
/// normalizing "abnormal heat/cold for here". Latitude bands vary only N–S, so
/// they call Portland OR and Minneapolis (same latitude) identical despite a
/// ~25 °F winter gap. A climate type folds in longitude, coast, aridity, and
/// elevation, so 95 °F reads as dangerous in marine Seattle (comfort high ~72)
/// but normal in Phoenix (comfort high ~98).
///
/// This classifier is COMPUTED from geography — no data download — so every ZIP
/// has a climate-aware profile immediately. The precise per-ZIP NOAA normals are
/// a later, on-demand refinement that drops into `precise[…]` for the route
/// corridor (and a cached home radius); until then the computed type serves.
///
/// The classifier, the envelopes, the seasonal anchors and the gates are
/// computed in rust/flows-core (climate.rs) and called through
/// rust/flows-bridge; the labels and the `precise` snapshot stay here. Pinned
/// to the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_climate_oracle.tsv.
enum ClimateProfiles {
    /// Köppen-style types relevant to North American driving climates, in the
    /// bridge's code order.
    enum ClimateType: String, CaseIterable {
        case marineWestCoast, mediterranean, hotDesert, coldSteppe,
             humidSubtropical, humidContinentalWarm, humidContinentalCool,
             subarctic, tropical, tundra, highland, temperateOceanic

        /// The bridge's code: position in `allCases`.
        var rustCode: UInt8 { UInt8(ClimateType.allCases.firstIndex(of: self) ?? 0) }

        init(rustCode code: UInt8) {
            let all = ClimateType.allCases
            self = Int(code) < all.count ? all[Int(code)] : .subarctic
        }

        /// The type's temperature envelope (comfort band = zero temp-risk;
        /// ramps to the record extremes) as a band-0 profile.
        var profile: LatitudeBands.Profile {
            let p = flows_climate_type_profile(rustCode)
            return p.has == 1 ? LatitudeBands.Profile(bridge: p) : LatitudeBands.anchorProfile
        }

        var label: String {
            switch self {
            case .marineWestCoast:      return "Marine west coast"
            case .mediterranean:        return "Mediterranean"
            case .hotDesert:            return "Hot desert"
            case .coldSteppe:           return "Cold steppe"
            case .humidSubtropical:     return "Humid subtropical"
            case .humidContinentalWarm: return "Humid continental (warm)"
            case .humidContinentalCool: return "Humid continental (cool)"
            case .subarctic:            return "Subarctic"
            case .tropical:             return "Tropical"
            case .tundra:               return "Tundra"
            case .highland:             return "Highland"
            case .temperateOceanic:     return "Temperate oceanic"
            }
        }
    }

    /// Classify a coordinate into its North-American climate type from geography.
    static func classify(latitude lat: Double, longitude lon: Double,
                         elevationMeters elev: Double?) -> ClimateType {
        ClimateType(rustCode: flows_climate_classify(lat, lon, elev ?? 0, elev != nil))
    }

    // MARK: seasonal norms — "normal for HERE at THIS time of year"

    /// The expected weekly climate window for a region: typical daily low/high
    /// temperature and typical wind mean ± σ. BETWEEN the seasonal average min
    /// and max is "normal" — normal conditions never draw on the map; only
    /// deviations beyond the window plus one standard deviation warrant notice.
    struct SeasonalNorms {
        var weekLowF: Double
        var weekHighF: Double
        var windMeanMph: Double
        var windSigmaMph: Double
        /// Daily temperature variability around the seasonal norm (NOAA daily
        /// anomaly σ runs ~8–15 °F; 12 is the continental mid).
        static let tempSigmaF = flows_climate_temp_sigma_f()
    }

    /// Seasonal norms for a location at a week-of-year (0…51): sinusoidal
    /// blend between the climate type's winter and summer anchors.
    static func seasonalNorms(week: Int, latitude: Double, longitude: Double,
                              elevationMeters: Double? = nil) -> SeasonalNorms {
        let n = flows_climate_seasonal_norms(Int64(week), latitude, longitude,
                                             elevationMeters ?? 0, elevationMeters != nil)
        return SeasonalNorms(weekLowF: n.week_low_f, weekHighF: n.week_high_f,
                             windMeanMph: n.wind_mean_mph, windSigmaMph: n.wind_sigma_mph)
    }

    /// Presentation gates: a condition draws on the map ONLY when it exceeds
    /// the regional+seasonal normal window by at least one standard deviation.
    static func temperatureBeyondNormal(tempF: Double, norms: SeasonalNorms) -> Bool {
        flows_climate_temperature_beyond_normal(
            tempF, norms.weekLowF, norms.weekHighF, norms.windMeanMph, norms.windSigmaMph)
    }

    static func windBeyondNormal(windMph: Double, norms: SeasonalNorms) -> Bool {
        flows_climate_wind_beyond_normal(
            windMph, norms.weekLowF, norms.weekHighF, norms.windMeanMph, norms.windSigmaMph)
    }

    // MARK: precise per-ZIP normals (on-demand refinement)

    /// Precise per-ZIP temperature normals, keyed by ~11 km cell. Populated on
    /// demand for a route corridor (and a cached home radius) once the NOAA
    /// Climate-Normals tiles ship; EMPTY until then, so the computed climate
    /// type serves everywhere. Read on the hot forecast path, so a snapshot is
    /// swapped atomically rather than mutated in place (no locks on reads).
    // `nonisolated(unsafe)`: read on the nonisolated forecast path, written only
    // by `loadPrecise` (main-actor, infrequent) via whole-snapshot replacement.
    // Empty this build (no on-demand loader yet); add a lock when it ships.
    nonisolated(unsafe) private static var precise: [Int: LatitudeBands.Profile] = [:]
    private static let cellDeg = 0.1
    private static func cell(_ lat: Double, _ lon: Double) -> Int {
        // Offset-encode so the DECODE in loadPrecise is exact for negative
        // longitudes (plain y*100000+x made x%100000 wrong for all of NA).
        let x = Int((lon / cellDeg).rounded(.down)) + 50_000
        let y = Int((lat / cellDeg).rounded(.down)) + 50_000
        return y &* 100_000 &+ x
    }

    /// The temperature/comfort profile for a location: the precise per-ZIP
    /// normal if it has been loaded for this cell, else the computed climate
    /// type. This is the seam every risk equation reads (via NWSForecastService).
    static func profile(latitude lat: Double, longitude lon: Double,
                        elevationMeters elev: Double? = nil) -> LatitudeBands.Profile {
        if let p = precise[cell(lat, lon)] { return p }
        let p = flows_climate_profile(lat, lon, elev ?? 0, elev != nil)
        return p.has == 1 ? LatitudeBands.Profile(bridge: p) : LatitudeBands.anchorProfile
    }

    /// Merge freshly-loaded precise normals (on-demand corridor / home-radius
    /// tiles) into the snapshot. `keepingHomeRadius` retains home-area cells when
    /// trimming, since local driving reuses them constantly.
    static func loadPrecise(_ entries: [(lat: Double, lon: Double, profile: LatitudeBands.Profile)],
                            home: CLLocationCoordinate2D?, maxCells: Int = 20_000) {
        var next = precise
        for e in entries { next[cell(e.lat, e.lon)] = e.profile }
        if next.count > maxCells, let home {
            let hx = Int((home.longitude / cellDeg).rounded(.down))
            let hy = Int((home.latitude / cellDeg).rounded(.down))
            let ring = 25   // ~25 cells ≈ home radius always kept
            next = next.filter { key, _ in
                let x = key % 100_000 - 50_000, y = key / 100_000 - 50_000
                return abs(x - hx) <= ring && abs(y - hy) <= ring
            }
            for e in entries { next[cell(e.lat, e.lon)] = e.profile }  // never evict the just-loaded corridor
        }
        precise = next
    }
}
