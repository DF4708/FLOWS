// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
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
enum ClimateProfiles {

    /// Köppen-style types relevant to North American driving climates. Each maps
    /// to a temperature envelope (comfort band = zero temp-risk; ramps to the
    /// record extremes). Wind/precip thresholds stay the universal defaults.
    enum ClimateType: String, CaseIterable {
        case marineWestCoast, mediterranean, hotDesert, coldSteppe,
             humidSubtropical, humidContinentalWarm, humidContinentalCool,
             subarctic, tropical, tundra, highland, temperateOceanic

        /// (comfortLowF, comfortHighF, recordLowF, recordHighF).
        private var temps: (Double, Double, Double, Double) {
            switch self {
            case .marineWestCoast:      return (45, 72, 12, 106)
            case .mediterranean:        return (48, 82, 25, 116)
            case .hotDesert:            return (55, 98, 25, 125)
            case .coldSteppe:           return (35, 85, -25, 110)
            case .humidSubtropical:     return (45, 90, 5, 112)
            case .humidContinentalWarm: return (35, 82, -20, 108)
            case .humidContinentalCool: return (28, 78, -35, 104)
            case .subarctic:            return (20, 72, -55, 98)
            case .tropical:             return (68, 90, 40, 106)
            case .tundra:               return (10, 58, -65, 86)
            case .highland:             return (28, 74, -40, 100)
            case .temperateOceanic:     return (42, 74, 5, 102)
            }
        }

        var profile: LatitudeBands.Profile {
            let (cl, ch, rl, rh) = temps
            return LatitudeBands.Profile(
                band: 0, comfortLowF: cl, comfortHighF: ch, recordLowF: rl, recordHighF: rh)
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
    /// Coarse but captures the major divisions latitude bands miss (coast vs.
    /// interior, desert, subtropical). Ordered most-specific first.
    static func classify(latitude lat: Double, longitude lon: Double,
                         elevationMeters elev: Double?) -> ClimateType {
        let e = elev ?? 0
        if lat >= 66 { return .tundra }
        if e >= 2000 { return .highland }              // Rockies / Sierra spine
        // Tropics + the South-Florida peninsula tip (Miami/Naples/Keys).
        if lat < 25 || (lat < 27 && lon > -83) { return .tropical }
        // Western North America (Pacific-influenced), west of the continental interior.
        if lon <= -117 {
            if lat >= 42 { return .marineWestCoast }    // WA/OR coast, BC (Seattle, Portland)
            return .mediterranean                       // CA (LA, SF, Sacramento)
        }
        // Interior West: deserts (low, hot/dry) vs. high steppe.
        if lon > -117 && lon <= -102 {
            if e >= 1000 { return .coldSteppe }         // Denver, high plains, Great Basin rim
            if lat < 37 { return .hotDesert }           // Phoenix, Vegas, Tucson
            return .coldSteppe
        }
        // Eastern North America, split by latitude into the continental gradient.
        if lat < 37 { return .humidSubtropical }        // Atlanta, Houston, Dallas, Charlotte
        if lat < 43 { return .humidContinentalWarm }    // Chicago, KC, NYC, DC, St Louis
        if lat < 50 { return .humidContinentalCool }    // Minneapolis, Detroit, Boston, Toronto
        return .subarctic                               // most of Canada's interior
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
        static let tempSigmaF = 12.0
    }

    /// Winter (week 0) and summer (week 26) anchor temps + wind norms per
    /// climate type — NOAA 1991–2020 normals for representative cities of each
    /// Köppen type. Weeks in between blend sinusoidally.
    private static func anchors(_ t: ClimateType)
        -> (wLo: Double, wHi: Double, sLo: Double, sHi: Double, wind: Double, sigma: Double) {
        switch t {
        case .marineWestCoast:      return (38, 50, 58, 72, 8, 3)
        case .mediterranean:        return (45, 58, 65, 82, 7, 2.5)
        case .hotDesert:            return (38, 62, 72, 98, 9, 4)
        case .coldSteppe:           return (15, 35, 55, 85, 11, 5)
        case .humidSubtropical:     return (38, 58, 68, 90, 8, 3.5)
        case .humidContinentalWarm: return (22, 38, 62, 82, 9, 4)
        case .humidContinentalCool: return (12, 28, 58, 78, 10, 4.5)
        case .subarctic:            return (0, 20, 50, 72, 12, 5.5)
        case .tropical:             return (68, 84, 76, 90, 11, 4)
        case .tundra:               return (-15, 10, 35, 58, 13, 6)
        case .highland:             return (18, 35, 50, 74, 11, 5)
        case .temperateOceanic:     return (35, 48, 55, 74, 9, 3.5)
        }
    }

    /// Seasonal norms for a location at a week-of-year (0…51): sinusoidal
    /// blend between the climate type's winter and summer anchors (southern-
    /// hemisphere phase isn't handled — FLOWS is North-America scoped).
    static func seasonalNorms(week: Int, latitude: Double, longitude: Double,
                              elevationMeters: Double? = nil) -> SeasonalNorms {
        let t = classify(latitude: latitude, longitude: longitude,
                         elevationMeters: elevationMeters)
        let a = anchors(t)
        // 0 at week 0 (mid-winter) → 1 at week 26 (mid-summer) → 0 at week 52.
        let phase = (1 - cos(2 * Double.pi * Double(((week % 52) + 52) % 52) / 52)) / 2
        return SeasonalNorms(
            weekLowF: a.wLo + (a.sLo - a.wLo) * phase,
            weekHighF: a.wHi + (a.sHi - a.wHi) * phase,
            windMeanMph: a.wind, windSigmaMph: a.sigma)
    }

    /// Presentation gates: a condition draws on the map ONLY when it exceeds
    /// the regional+seasonal normal window by at least one standard deviation.
    /// Between the seasonal average min and max (±σ) is "normal" — no notice.
    static func temperatureBeyondNormal(tempF: Double, norms: SeasonalNorms) -> Bool {
        guard tempF.isFinite else { return false }
        return tempF > norms.weekHighF + SeasonalNorms.tempSigmaF
            || tempF < norms.weekLowF - SeasonalNorms.tempSigmaF
    }

    static func windBeyondNormal(windMph: Double, norms: SeasonalNorms) -> Bool {
        guard windMph.isFinite else { return false }
        // Normal peak gusts run ~mean+σ; notice begins another σ beyond that.
        return windMph > norms.windMeanMph + 2 * norms.windSigmaMph
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
        return classify(latitude: lat, longitude: lon, elevationMeters: elev).profile
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
