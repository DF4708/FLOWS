// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// Expert-recommended actions for a tapped risk symbol, SCALED to the band —
/// mild elevation gets proportionate advice (no "heavy coats" for a slightly
/// cool day in that latitude band). Sources: NWS safety guidance
/// (weather.gov/safety), CDC extreme-temperature guidance, FEMA/Ready.gov.
/// Pure and pinned by FLOWSTests.
enum RiskAdvice {

    /// Advice lines for a hazard kind name ("Cold", "Heat", "Flood"…) at a
    /// band. `.clear` returns nothing — no risk, no advice.
    static func actions(kindName: String, band: RiskBand) -> [String] {
        guard band != .clear else { return [] }
        switch kindName.lowercased() {
        case "cold":
            switch band {
            case .green:
                return ["Cooler than typical for this area — a light jacket or "
                        + "layers is plenty."]
            case .yellow:
                return ["Coat, hat, and gloves for time outside.",
                        "Keep fuel above half a tank; batteries weaken in cold."]
            default:
                return ["Dangerous cold: limit exposed skin — frostbite risk in "
                        + "minutes (NWS wind-chill guidance).",
                        "Carry blankets, food, water in the vehicle; tell someone "
                        + "your route.",
                        "If stranded, stay with the vehicle and run the engine "
                        + "briefly with a cracked window."]
            }
        case "heat":
            switch band {
            case .green:
                return ["Warmer than typical — hydrate normally, use AC as needed."]
            case .yellow:
                return ["Hydrate before you're thirsty; never leave people or "
                        + "pets in a parked vehicle (CDC).",
                        "Take breaks in shade or AC on long drives."]
            default:
                return ["Extreme heat: limit outdoor exertion; heat stroke is a "
                        + "911 emergency (confusion, no sweating).",
                        "Check coolant and tire pressures — blowouts spike in "
                        + "extreme heat."]
            }
        case "flood":
            switch band {
            case .green:
                return ["Ponding possible in low spots — slow through standing "
                        + "water."]
            case .yellow:
                return ["Turn Around, Don't Drown: never cross flooded roads — "
                        + "12 inches of moving water floats most cars (NWS).",
                        "Avoid underpasses and low crossings."]
            default:
                return ["Flash-flood conditions: leave low-lying routes NOW.",
                        "If water surrounds the vehicle, abandon it and move to "
                        + "high ground (FEMA)."]
            }
        case "wind":
            switch band {
            case .green:
                return ["Breezy — expect light buffeting, keep both hands on "
                        + "the wheel."]
            case .yellow:
                return ["Gusts can push high-profile vehicles across lanes — "
                        + "slow down, grip firm, give trucks room.",
                        "Secure loose cargo and trailers."]
            default:
                return ["Damaging winds: high-profile vehicles and towing should "
                        + "delay travel or use sheltered routes.",
                        "Watch for downed lines and debris; treat dead signals "
                        + "as four-way stops."]
            }
        case "snow", "ice":
            switch band {
            case .green:
                return ["Light accumulation possible — increase following "
                        + "distance."]
            case .yellow:
                return ["Slow well below the limit; brake gently and early.",
                        "Carry chains where required; bridges freeze first."]
            default:
                return ["Whiteout/ice-storm conditions: delay travel if possible "
                        + "(NWS winter guidance).",
                        "If you must drive: full tank, blankets, charged phone; "
                        + "if stranded stay with the vehicle."]
            }
        case "storm", "tornado":
            switch band {
            case .green:
                return ["Thunderstorms possible — expect brief heavy rain."]
            case .yellow:
                return ["When thunder roars, go indoors — a vehicle beats open "
                        + "ground (NWS lightning).",
                        "Hail-prone: covered parking if available."]
            default:
                return ["Seek sturdy shelter NOW — a vehicle is NOT safe in a "
                        + "tornado; a ditch beats staying inside it (NWS).",
                        "Never shelter under an overpass."]
            }
        case "fire":
            switch band {
            case .green:
                return ["Elevated fire weather — obey burn bans; don't park hot "
                        + "exhausts over dry grass."]
            case .yellow:
                return ["Smoke can drop visibility fast — headlights on, windows "
                        + "up, recirculated air."]
            default:
                return ["Active fire area: follow evacuation orders immediately; "
                        + "never drive through smoke you can't see through "
                        + "(Ready.gov wildfire)."]
            }
        case "dust storm":
            // Both hazards at once: the road you cannot see and the air you
            // should not breathe (NWS "Pull Aside, Stay Alive"; EPA AQI).
            switch band {
            case .green:
                return ["Blowing dust ahead: slow down, headlights on, windows up "
                        + "and cabin air on recirculate."]
            case .yellow:
                return ["Visibility is dropping: pull fully off the road, stop, "
                        + "lights OFF, foot off the brake so no one follows your "
                        + "lights.", "Windows up, recirculate; N95 if you must step out."]
            default:
                return ["Zero visibility: pull off the road NOW, stop, all lights "
                        + "off, foot off the brake, seat belt on, wait it out.",
                        "Keep the cabin sealed and recirculating."]
            }
        case "air/smoke":
            switch band {
            case .green:
                return ["Slightly degraded air — sensitive groups limit heavy "
                        + "exertion (EPA AQI)."]
            case .yellow:
                return ["Unhealthy air: windows up, recirculate cabin air, limit "
                        + "time outside."]
            default:
                return ["Hazardous air: N95 if you must be outside; keep cabin "
                        + "sealed and recirculating."]
            }
        case "radiation/uv":
            switch band {
            case .green:
                return ["Moderate UV — sunscreen for long exposure through "
                        + "windows."]
            case .yellow:
                return ["High UV: SPF 30+, sunglasses, hat — burn time under "
                        + "30 minutes (WHO)."]
            default:
                return ["Extreme UV: minimize midday exposure; skin damage in "
                        + "minutes."]
            }
        case "seismic":
            return ["Recent earthquake activity: if shaking starts while "
                    + "driving, pull over away from bridges/overpasses and stay "
                    + "in the vehicle (USGS).",
                    "Expect aftershocks; check for road damage."]
        case "tropical":
            switch band {
            case .green:
                return ["Distant tropical system — expect building wind and "
                        + "rain bands; top off fuel."]
            case .yellow:
                return ["Tropical storm conditions: expect flooding rain and "
                        + "gusts that shove high-profile vehicles (NHC).",
                        "Avoid coastal and low routes; do not drive through "
                        + "storm surge or flooded roads."]
            default:
                return ["Hurricane-force conditions: do NOT travel — follow "
                        + "evacuation orders and shelter away from the coast "
                        + "(NHC / Ready.gov).",
                        "Storm surge kills; never drive onto a flooded or "
                        + "washed-out road."]
            }
        case "volcanic":
            switch band {
            case .green, .yellow:
                return ["Elevated volcano nearby: ashfall can drop visibility "
                        + "and clog engines — headlights on, windows up, "
                        + "recirculate air, avoid hard braking on ash (USGS).",
                        "Carry water and an N95; ash is abrasive and irritating."]
            default:
                return ["Volcanic warning: avoid the area and downwind ashfall "
                        + "zones; heavy ash makes roads impassable and damages "
                        + "engines (USGS Volcano Hazards).",
                        "Follow evacuation and lahar (mudflow) guidance near "
                        + "valleys and river drainages."]
            }
        case "avalanche":
            switch band {
            case .green:
                return ["Low avalanche danger — natural slides unlikely, but "
                        + "watch steep road cuts after new snow."]
            case .yellow:
                return ["Considerable avalanche danger on the mountain pass: "
                        + "avoid stopping in slide paths; check the pass status "
                        + "before committing (avalanche center)."]
            default:
                return ["High/Extreme avalanche danger: delay mountain-pass "
                        + "travel — roads through slide terrain can be closed "
                        + "or buried (avalanche.org / Avalanche Canada).",
                        "Never stop or park under a loaded slope."]
            }
        case "tsunami":
            switch band {
            case .green, .yellow:
                return ["Tsunami watch/advisory for the coast: stay off "
                        + "beaches and low coastal roads; be ready to move "
                        + "inland and uphill (NWS Tsunami)."]
            default:
                return ["TSUNAMI WARNING: leave the coast NOW — drive inland "
                        + "and to high ground, on foot if roads jam. Do not "
                        + "wait to see the wave (tsunami.gov).",
                        "A receding shoreline means a wave is imminent."]
            }
        default:
            switch band {
            case .yellow:
                return ["Elevated conditions — drive to conditions and monitor "
                        + "official alerts."]
            case .red:
                return ["Dangerous conditions in this area — check the official "
                        + "warning before proceeding."]
            default:
                return ["Mildly elevated conditions for this area."]
            }
        }
    }

    /// The official page for a location's active hazards: the NWS point
    /// page (US), ECCC (Canada), SMN (Mexico) — always resolvable, always
    /// the issuing agency. US is the default; a location routes to a foreign
    /// agency only when it is unambiguously across the border.
    static func officialURL(latitude: Double, longitude: Double) -> URL? {
        if isNorthOfTheBorder(latitude: latitude, longitude: longitude) {
            return URL(string: "https://weather.gc.ca/en/location/index.html"
                       + String(format: "?coords=%.3f,%.3f", latitude, longitude))
        }
        // Mexico, in two segments because the border is diagonal and the Gulf
        // separates Mexico's east coast from Florida (a flat latitude box sent
        // Houston, Miami, and the whole Gulf Coast to SMN):
        //   WEST/border — Pacific coast through the Rio Grande, south of the
        //   piecewise border latitude for this longitude.
        if longitude >= -117.2, longitude <= -97.4, latitude > 14,
           latitude < usSouthernBorderLat(longitude: longitude) {
            return URL(string: "https://smn.conagua.gob.mx/es/pronosticos/avisos")
        }
        //   GULF/Yucatán — Mexican east coast, west of the -86.5 line so the
        //   Florida peninsula (US, but below 26°N) is excluded.
        if longitude >= -98.0, longitude <= -86.5, latitude > 14, latitude < 25.5 {
            return URL(string: "https://smn.conagua.gob.mx/es/pronosticos/avisos")
        }
        return URL(string: String(format:
            "https://forecast.weather.gov/MapClick.php?lat=%.4f&lon=%.4f",
            latitude, longitude))
    }

    /// Maine's land (north of 44.8°N), drawn along the Quebec and New
    /// Brunswick border as (latitude, longitude): the 45th parallel's end at
    /// -71.5, Coburn Gore, Armstrong, the highlands to Estcourt Station, the
    /// St. John River to Hamlin, the -67.78 monument line, then the St. Croix.
    private static let maine: [CLLocationCoordinate2D] = [
        (44.6, -71.5), (45.01, -71.5), (45.30, -71.08), (45.40, -70.80), (45.77, -70.39),
        (46.40, -70.05), (47.10, -70.0), (47.46, -69.23), (47.36, -68.33), (47.07, -67.78),
        (45.93, -67.78), (45.57, -67.43), (45.18, -67.28), (44.6, -66.9),
    ].map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }

    /// Is the point on the Canadian side of the border? West to east, the
    /// border as the bands the Weather Service and Environment Canada split
    /// it by: the 49th parallel, the Rainy River and Superior, Huron's
    /// Michigan shore, Lake Ontario, the St. Lawrence, the 45th parallel,
    /// Maine's outline, and the Maritimes beyond it. Alaska (US) is read
    /// first, ahead of its high latitude. Border towns within ~0.05° are
    /// inherently ambiguous at this resolution.
    static func isNorthOfTheBorder(latitude lat: Double, longitude lon: Double) -> Bool {
        if lat > 51 && lon < -130.5 { return false }               // Alaska
        if lon <= -95.15 { return lat > 49.0 }                     // the 49th parallel
        if lon <= -89.6 {                                          // Rainy River → Pigeon River
            let knots: [(lon: Double, lat: Double)] = [
                (-95.15, 49.0), (-94.6, 48.8), (-93.4, 48.6), (-92.0, 48.3), (-89.6, 48.0)]
            guard let i = knots.indices.dropLast().first(where: { lon <= knots[$0 + 1].lon })
            else { return lat > 48.0 }
            let a = knots[i], b = knots[i + 1]
            let t = (lon - a.lon) / (b.lon - a.lon)
            return lat > a.lat + t * (b.lat - a.lat) + 0.02
        }
        if lon <= -83.6 { return lat > 47.8 }                      // Superior's Canadian shore
        if lon <= -82.0 { return lat > 45.5 }                      // Michigan ends below 45.5
        if lon <= -78.0 { return lat > 43.4 }                      // Ontario's south shore
        if lon <= -76.35 { return lat > 43.75 }                    // Lake Ontario's east end
        if lon <= -74.75 {                                         // the St. Lawrence
            return lat > 44.12 + (lon + 76.35) / 1.6 * 0.88
        }
        if lon <= -71.5 { return lat > 45.03 }                     // the 45th parallel
        if lon <= -66.9 {
            return lat > 44.8
                && !HazardFeedScores.pointInPolygon(
                    CLLocationCoordinate2D(latitude: lat, longitude: lon), maine)
        }
        return lon < -52 && lat > 43.0                             // the Maritimes
    }

    /// The latitude of the US–Mexico border for the WESTERN segment
    /// (longitude in [-117.2, -97.4]): the Californias line, the Sonora/AZ and
    /// NM lines, then the Rio Grande's diagonal from El Paso to Brownsville. A
    /// point south of this (within the longitude band) is Mexico. Border towns
    /// within ~0.1° are inherently ambiguous at this resolution.
    static func usSouthernBorderLat(longitude lon: Double) -> Double {
        if lon <= -114.7 { return 32.5 }    // CA / Baja
        if lon <= -108.2 { return 31.33 }   // AZ / Sonora
        // NM + El Paso corner down to Brownsville, kept just south of El Paso
        // city (31.76) so the US side of the Rio Grande routes to NWS.
        let t = (lon + 106.5) / (-97.4 + 106.5)   // 0 at El Paso, 1 at Brownsville
        return 31.74 + max(0, t) * (25.9 - 31.74)
    }
}
