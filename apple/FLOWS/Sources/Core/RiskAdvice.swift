// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

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
    /// the issuing agency.
    static func officialURL(latitude: Double, longitude: Double) -> URL? {
        if latitude > 49 || (latitude > 44.8 && longitude > -83.6 && longitude < -52)
            || (latitude > 43.4 && longitude > -81.8 && longitude < -76.3) {
            return URL(string: "https://weather.gc.ca/en/location/index.html"
                       + String(format: "?coords=%.3f,%.3f", latitude, longitude))
        }
        if latitude < 32.72 && longitude > -118 && longitude < -86 {
            return URL(string: "https://smn.conagua.gob.mx/es/pronosticos/avisos")
        }
        return URL(string: String(format:
            "https://forecast.weather.gov/MapClick.php?lat=%.4f&lon=%.4f",
            latitude, longitude))
    }
}
