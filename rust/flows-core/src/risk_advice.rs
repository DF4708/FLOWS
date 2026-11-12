// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The advice for a tapped risk symbol and the border lines that pick the
//! official weather page: Swift's `RiskAdvice` before its rules moved here.
//!
//! The advice is scaled to the band (no "heavy coats" for a slightly cool
//! day), from NWS safety guidance, CDC extreme-temperature guidance and
//! FEMA/Ready.gov. The kind's name is read the way Swift's `switch` on
//! `kindName.lowercased()` read it, through [`crate::swift_text`]: the
//! standard library's `lowercased()` and `==` (canonical equivalence, so a
//! Kelvin sign is a K).
//!
//! The border is the bands the Weather Service and Environment Canada split
//! it by, with Maine, Southeast Alaska, southern Ontario and Vancouver
//! Island drawn as rings, and the Rio Grande followed point to point. The
//! arithmetic is the original's, in the original's order.
//!
//! Pinned by `flows-bridge/tests/fixtures/swift_risk_advice_oracle.tsv`.

use crate::hazard_feeds::point_in_polygon;
use crate::swift_text;

/// `(latitude, longitude)`.
pub type Point = (f64, f64);

/// The four bands, as the bridge numbers them.
pub const CLEAR: u8 = 0;
pub const GREEN: u8 = 1;
pub const YELLOW: u8 = 2;
pub const RED: u8 = 3;

// ------------------------------------------------------------ the advice

/// One kind's lines: green, yellow, and red (any other band).
struct Advice {
    names: &'static [&'static str],
    green: &'static [&'static str],
    yellow: &'static [&'static str],
    red: &'static [&'static str],
}

const STORM_GREEN: &[&str] = &["Thunderstorms possible — expect brief heavy rain."];
const STORM_YELLOW: &[&str] = &[
    "When thunder roars, go indoors — a vehicle beats open ground (NWS lightning).",
    "Hail-prone: covered parking if available.",
];
const SEISMIC: &[&str] = &[
    "Recent earthquake activity: if shaking starts while driving, pull over away from \
     bridges/overpasses and stay in the vehicle (USGS).",
    "Expect aftershocks; check for road damage.",
];
const VOLCANIC_WATCH: &[&str] = &[
    "Elevated volcano nearby: ashfall can drop visibility and clog engines — headlights on, \
     windows up, recirculate air, avoid hard braking on ash (USGS).",
    "Carry water and an N95; ash is abrasive and irritating.",
];
const TSUNAMI_WATCH: &[&str] = &[
    "Tsunami watch/advisory for the coast: stay off beaches and \
     low coastal roads; be ready to move inland and uphill (NWS Tsunami).",
];

/// The kinds in the order the original's `switch` tried them.
const ADVICE: [Advice; 16] = [
    Advice {
        names: &["cold"],
        green: &["Cooler than typical for this area — a light jacket or layers is plenty."],
        yellow: &[
            "Coat, hat, and gloves for time outside.",
            "Keep fuel above half a tank; batteries weaken in cold.",
        ],
        red: &[
            "Dangerous cold: limit exposed skin — frostbite risk in minutes (NWS wind-chill \
             guidance).",
            "Carry blankets, food, water in the vehicle; tell someone your route.",
            "If stranded, stay with the vehicle and run the engine briefly with a cracked window.",
        ],
    },
    Advice {
        names: &["heat"],
        green: &["Warmer than typical — hydrate normally, use AC as needed."],
        yellow: &[
            "Hydrate before you're thirsty; never leave people or pets in a parked vehicle (CDC).",
            "Take breaks in shade or AC on long drives.",
        ],
        red: &[
            "Extreme heat: limit outdoor exertion; heat stroke is a 911 emergency (confusion, no \
             sweating).",
            "Check coolant and tire pressures — blowouts spike in extreme heat.",
        ],
    },
    Advice {
        names: &["flood"],
        green: &["Ponding possible in low spots — slow through standing water."],
        yellow: &[
            "Turn Around, Don't Drown: never cross flooded roads — 12 inches of moving water \
             floats most cars (NWS).",
            "Avoid underpasses and low crossings.",
        ],
        red: &[
            "Flash-flood conditions: leave low-lying routes NOW.",
            "If water surrounds the vehicle, abandon it and move to high ground (FEMA).",
        ],
    },
    Advice {
        names: &["wind"],
        green: &["Breezy — expect light buffeting, keep both hands on the wheel."],
        yellow: &[
            "Gusts can push high-profile vehicles across lanes — slow down, grip firm, give \
             trucks room.",
            "Secure loose cargo and trailers.",
        ],
        red: &[
            "Damaging winds: high-profile vehicles and towing should delay travel or use \
             sheltered routes.",
            "Watch for downed lines and debris; treat dead signals as four-way stops.",
        ],
    },
    Advice {
        names: &["snow", "ice"],
        green: &["Light accumulation possible — increase following distance."],
        yellow: &[
            "Slow well below the limit; brake gently and early.",
            "Carry chains where required; bridges freeze first.",
        ],
        red: &[
            "Whiteout/ice-storm conditions: delay travel if possible (NWS winter guidance).",
            "If you must drive: full tank, blankets, charged phone; if stranded stay with the \
             vehicle.",
        ],
    },
    // A severe thunderstorm is not a tornado: for lightning and hail the car
    // is the safer place, and the tornado line told the driver to leave it.
    Advice {
        names: &["storm"],
        green: STORM_GREEN,
        yellow: STORM_YELLOW,
        red: &[
            "Severe storm: get inside a sturdy building if you can. A hard-top vehicle beats \
             open ground (NWS).",
            "In hail or blinding rain, pull off the road, away from trees and power lines.",
        ],
    },
    Advice {
        names: &["tornado"],
        green: STORM_GREEN,
        yellow: STORM_YELLOW,
        red: &[
            "Seek sturdy shelter NOW — a vehicle is NOT safe in a tornado; a ditch beats \
             staying inside it (NWS).",
            "Never shelter under an overpass.",
        ],
    },
    Advice {
        names: &["fire"],
        green: &[
            "Elevated fire weather — obey burn bans; don't park hot exhausts over dry \
                  grass.",
        ],
        yellow: &["Smoke can drop visibility fast — headlights on, windows up, recirculated air."],
        red: &[
            "Active fire area: follow evacuation orders immediately; never drive through \
                smoke you can't see through (Ready.gov wildfire).",
        ],
    },
    // Both hazards at once: the road you cannot see and the air you should
    // not breathe (NWS "Pull Aside, Stay Alive"; EPA AQI).
    Advice {
        names: &["dust storm"],
        green: &[
            "Blowing dust ahead: slow down, headlights on, windows up and cabin air on \
                  recirculate.",
        ],
        yellow: &[
            "Visibility is dropping: pull fully off the road, stop, lights OFF, foot off the \
             brake so no one follows your lights.",
            "Windows up, recirculate; N95 if you must step out.",
        ],
        red: &[
            "Zero visibility: pull off the road NOW, stop, all lights off, foot off the brake, \
             seat belt on, wait it out.",
            "Keep the cabin sealed and recirculating.",
        ],
    },
    Advice {
        names: &["air/smoke"],
        green: &["Slightly degraded air — sensitive groups limit heavy exertion (EPA AQI)."],
        yellow: &["Unhealthy air: windows up, recirculate cabin air, limit time outside."],
        red: &["Hazardous air: N95 if you must be outside; keep cabin sealed and recirculating."],
    },
    Advice {
        names: &["radiation/uv"],
        green: &["Moderate UV — sunscreen for long exposure through windows."],
        yellow: &["High UV: SPF 30+, sunglasses, hat — burn time under 30 minutes (WHO)."],
        red: &["Extreme UV: minimize midday exposure; skin damage in minutes."],
    },
    Advice {
        names: &["seismic"],
        green: SEISMIC,
        yellow: SEISMIC,
        red: SEISMIC,
    },
    Advice {
        names: &["tropical"],
        green: &["Distant tropical system — expect building wind and rain bands; top off fuel."],
        yellow: &[
            "Tropical storm conditions: expect flooding rain and gusts that shove high-profile \
             vehicles (NHC).",
            "Avoid coastal and low routes; do not drive through storm surge or flooded roads.",
        ],
        red: &[
            "Hurricane-force conditions: do NOT travel — follow evacuation orders and shelter \
             away from the coast (NHC / Ready.gov).",
            "Storm surge kills; never drive onto a flooded or washed-out road.",
        ],
    },
    Advice {
        names: &["volcanic"],
        green: VOLCANIC_WATCH,
        yellow: VOLCANIC_WATCH,
        red: &[
            "Volcanic warning: avoid the area and downwind ashfall zones; heavy ash makes roads \
             impassable and damages engines (USGS Volcano Hazards).",
            "Follow evacuation and lahar (mudflow) guidance near valleys and river drainages.",
        ],
    },
    Advice {
        names: &["avalanche"],
        green: &[
            "Low avalanche danger — natural slides unlikely, but watch steep road cuts \
                  after new snow.",
        ],
        yellow: &[
            "Considerable avalanche danger on the mountain pass: avoid stopping in slide \
                   paths; check the pass status before committing (avalanche center).",
        ],
        red: &[
            "High/Extreme avalanche danger: delay mountain-pass travel — roads through slide \
             terrain can be closed or buried (avalanche.org / Avalanche Canada).",
            "Never stop or park under a loaded slope.",
        ],
    },
    Advice {
        names: &["tsunami"],
        green: TSUNAMI_WATCH,
        yellow: TSUNAMI_WATCH,
        red: &[
            "TSUNAMI WARNING: leave the coast NOW — drive inland and to high ground, on foot if \
             roads jam. Do not wait to see the wave (tsunami.gov).",
            "A receding shoreline means a wave is imminent.",
        ],
    },
];

/// A kind the table does not name. Its order differs from the others: the
/// original's `default` here was green (and any band but yellow and red).
const OTHER_YELLOW: &[&str] =
    &["Elevated conditions — drive to conditions and monitor official alerts."];
const OTHER_RED: &[&str] =
    &["Dangerous conditions in this area — check the official warning before proceeding."];
const OTHER_MILD: &[&str] = &["Mildly elevated conditions for this area."];

/// `actions(kindName:band:)`: the advice lines for a hazard kind's name at
/// a band (0 clear, 1 green, 2 yellow, 3 red). Clear answers nothing.
#[must_use]
pub fn actions(kind_name: &str, band: u8) -> &'static [&'static str] {
    if band == CLEAR {
        return &[];
    }
    let name = swift_text::lowercased(kind_name);
    let kind = ADVICE
        .iter()
        .find(|a| a.names.iter().any(|n| swift_text::eq(&name, n)));
    match kind {
        Some(a) => match band {
            GREEN => a.green,
            YELLOW => a.yellow,
            _ => a.red,
        },
        None => match band {
            YELLOW => OTHER_YELLOW,
            RED => OTHER_RED,
            _ => OTHER_MILD,
        },
    }
}

/// The lines a band gives when the kind is unknown (the bridge's answer if
/// the reading fails).
#[must_use]
pub fn default_actions(band: u8) -> &'static [&'static str] {
    match band {
        CLEAR => &[],
        YELLOW => OTHER_YELLOW,
        RED => OTHER_RED,
        _ => OTHER_MILD,
    }
}

// ------------------------------------------------------------ the border

/// Maine's land (north of 44.8°N), drawn along the Quebec and New Brunswick
/// border: the 45th parallel's end at -71.5, Coburn Gore, Armstrong, the
/// highlands to Estcourt Station, the St. John River to Hamlin, the -67.78
/// monument line, then the St. Croix.
const MAINE: [Point; 16] = [
    (44.6, -71.5),
    (45.01, -71.5),
    (45.30, -71.08),
    (45.40, -70.80),
    (45.77, -70.39),
    (46.40, -70.05),
    (47.10, -70.0),
    (47.46, -69.23),
    (47.36, -68.33),
    (47.35, -68.14),
    (47.20, -67.92),
    (47.07, -67.78),
    (45.93, -67.78),
    (45.57, -67.43),
    (45.18, -67.28),
    (44.6, -66.9),
];

/// Southeast Alaska: Dixon Entrance, up the Portland Canal, the Coast
/// Mountains to the White Pass, the Haines road's border, Mount
/// Fairweather, Mount St. Elias, and the sea back along 141°W.
const ALASKA_PANHANDLE: [Point; 16] = [
    (54.66, -141.0),
    (54.66, -130.6),
    (55.0, -130.2),
    (55.85, -130.0),
    (55.95, -130.0),
    (56.1, -130.1),
    (56.7, -131.9),
    (58.0, -133.1),
    (58.9, -133.8),
    (59.7, -135.0),
    (59.8, -135.5),
    (59.45, -136.4),
    (58.9, -137.5),
    (59.7, -138.6),
    (60.3, -139.1),
    (60.3, -141.0),
];

/// Ontario south and west of the bands, along the water the border runs
/// in: Whitefish Bay, the St. Marys River, Lake Huron, the St. Clair River,
/// Lake St. Clair, the Detroit River, Lake Erie, the Niagara River, and
/// back across Ontario.
const ONTARIO_BELOW_THE_BANDS: [Point; 54] = [
    (47.85, -84.95),
    (46.90, -84.95),
    (46.60, -84.78),
    (46.505, -84.62),
    (46.49, -84.45),
    (46.508, -84.36),
    (46.505, -84.30),
    (46.515, -84.27),
    (46.54, -84.20),
    (46.52, -84.12),
    (46.45, -84.09),
    (46.28, -84.11),
    (46.09, -83.98),
    (46.11, -83.60),
    (45.95, -83.45),
    (45.33, -82.52),
    (43.60, -82.12),
    (43.0, -82.42),
    (42.97, -82.416),
    (42.82, -82.478),
    (42.715, -82.485),
    (42.62, -82.52),
    (42.53, -82.62),
    (42.36, -82.925),
    (42.331, -82.975),
    (42.3237, -83.0417),
    (42.312, -83.074),
    (42.285, -83.10),
    (42.20, -83.13),
    (42.05, -83.13),
    (41.83, -83.07),
    (41.75, -82.78),
    (41.676, -82.68),
    (41.85, -82.0),
    (42.2, -81.25),
    (42.36, -80.0),
    (42.6, -79.5),
    (42.83, -78.95),
    (42.906, -78.906),
    (42.94, -78.925),
    (42.965, -78.975),
    (43.0, -79.012),
    (43.045, -79.005),
    (43.065, -78.995),
    (43.074, -79.02),
    (43.076, -79.06),
    (43.0773, -79.0745),
    (43.0902, -79.0677),
    (43.12, -79.062),
    (43.165, -79.045),
    (43.26, -79.06),
    (43.45, -79.06),
    (45.6, -82.0),
    (47.85, -83.5),
];

/// Vancouver Island and the Gulf Islands below the 49th parallel: the
/// Strait of Juan de Fuca, Haro Strait and Boundary Pass.
const VANCOUVER_ISLAND_BELOW_49: [Point; 12] = [
    (49.0, -123.32),
    (48.83, -123.0),
    (48.77, -123.01),
    (48.69, -123.27),
    (48.55, -123.22),
    (48.42, -123.115),
    (48.28, -123.25),
    (48.25, -123.55),
    (48.3, -124.0),
    (48.5, -124.75),
    (48.6, -125.6),
    (49.0, -126.5),
];

/// The Rainy River to the Pigeon River as `(longitude, latitude)`.
const RAINY_RIVER: [(f64, f64); 5] = [
    (-95.15, 49.0),
    (-94.6, 48.8),
    (-93.4, 48.6),
    (-92.0, 48.3),
    (-89.6, 48.0),
];

/// The Rio Grande from El Paso to the Gulf as `(longitude, latitude)`, each
/// point a little south of the river so its US bank reads as US: El Paso,
/// Fort Hancock, Candelaria, Presidio, Lajitas, the Big Bend's tip,
/// Boquillas, La Linda, Langtry, Del Rio, Eagle Pass, Laredo, El Cenizo, San
/// Ygnacio, Zapata, Roma, Rio Grande City, Hidalgo, Progreso, Brownsville.
const RIO_GRANDE: [(f64, f64); 20] = [
    (-106.5, 31.74),
    (-105.85, 31.20),
    (-104.68, 30.09),
    (-104.37, 29.50),
    (-103.77, 29.21),
    (-103.15, 28.92),
    (-102.95, 29.13),
    (-102.82, 29.40),
    (-101.56, 29.75),
    (-100.93, 29.28),
    (-100.51, 28.65),
    (-99.51, 27.45),
    (-99.505, 27.28),
    (-99.44, 27.00),
    (-99.30, 26.82),
    (-99.02, 26.35),
    (-98.82, 26.335),
    (-98.26, 26.08),
    (-97.95, 26.01),
    (-97.4, 25.84),
];

/// The first segment `i` of a `(longitude, latitude)` line whose far end is
/// at or east of `lon`, as Swift's `indices.dropLast().first(where:)`.
fn segment(line: &[(f64, f64)], lon: f64) -> Option<usize> {
    (0..line.len() - 1).find(|&i| lon <= line[i + 1].0)
}

/// `isNorthOfTheBorder`: is the point on the Canadian side? West to east:
/// Alaska first, the 49th parallel, the Northwest Angle, the Rainy River,
/// Superior, Huron's Michigan shore, Lake Ontario, the St. Lawrence, the
/// 45th parallel, Maine, and the Maritimes beyond it.
#[must_use]
pub fn is_north_of_the_border(lat: f64, lon: f64) -> bool {
    if lat > 51.0 && lon < -141.0 {
        return false; // Alaska, and the Aleutians
    }
    if lat > 54.66
        && lat < 60.3
        && lon > -141.0
        && lon < -129.9
        && point_in_polygon((lat, lon), &ALASKA_PANHANDLE)
    {
        return false; // Southeast Alaska
    }
    if lon <= -95.15 {
        return lat > 49.0;
    }
    // Minnesota's Northwest Angle, the one piece of the lower 48 above it.
    if lat < 49.39 && lon < -95.0 {
        return false;
    }
    if lon <= -89.6 {
        let Some(i) = segment(&RAINY_RIVER, lon) else {
            return lat > 48.0;
        };
        let (a, b) = (RAINY_RIVER[i], RAINY_RIVER[i + 1]);
        let t = (lon - a.0) / (b.0 - a.0);
        return lat > a.1 + t * (b.1 - a.1) + 0.02;
    }
    if lon <= -83.6 {
        return lat > 47.8; // Superior's Canadian shore
    }
    if lon <= -82.0 {
        return lat > 45.5; // Michigan ends below 45.5
    }
    if lon <= -78.0 {
        return lat > 43.4; // Ontario's south shore
    }
    if lon <= -76.35 {
        return lat > 43.75; // Lake Ontario's east end
    }
    if lon <= -74.75 {
        return lat > 44.12 + (lon + 76.35) / 1.6 * 0.88; // the St. Lawrence
    }
    if lon <= -71.5 {
        return lat > 45.03; // the 45th parallel
    }
    if lon <= -66.9 {
        return lat > 44.8 && !point_in_polygon((lat, lon), &MAINE);
    }
    lon < -52.0 && lat > 43.0 // the Maritimes
}

/// `isCanadaBelowTheBands`: southern Ontario and Vancouver Island, which the
/// bands leave on the US side.
#[must_use]
pub fn is_canada_below_the_bands(lat: f64, lon: f64) -> bool {
    if (-85.0..=-78.9).contains(&lon) && (41.6..=47.9).contains(&lat) {
        return point_in_polygon((lat, lon), &ONTARIO_BELOW_THE_BANDS);
    }
    if (-126.5..=-123.0).contains(&lon) && (48.2..=49.0).contains(&lat) {
        return point_in_polygon((lat, lon), &VANCOUVER_ISLAND_BELOW_49);
    }
    false
}

/// `usSouthernBorderLat`: the US–Mexico border's latitude for a longitude
/// in the western segment: the Californias line, the Sonora lines, New
/// Mexico, then the Rio Grande point to point.
#[must_use]
pub fn us_southern_border_lat(lon: f64) -> f64 {
    if lon <= -114.82 {
        return 32.528 + (lon + 117.2) / 2.38 * 0.183;
    }
    if lon <= -111.075 {
        return 32.484 + (lon + 114.82) / 3.745 * (31.33 - 32.484);
    }
    if lon <= -108.2 {
        return 31.33;
    }
    if lon <= RIO_GRANDE[0].0 {
        return RIO_GRANDE[0].1;
    }
    let Some(i) = segment(&RIO_GRANDE, lon) else {
        return RIO_GRANDE[RIO_GRANDE.len() - 1].1;
    };
    let (a, b) = (RIO_GRANDE[i], RIO_GRANDE[i + 1]);
    a.1 + (lon - a.0) / (b.0 - a.0) * (b.1 - a.1)
}

/// Mexico's western segment: south of the border line, Pacific to Gulf.
fn in_mexico_west(lat: f64, lon: f64) -> bool {
    (-117.2..=-97.4).contains(&lon) && lat > 14.0 && lat < us_southern_border_lat(lon)
}

/// Mexico's Gulf and Yucatán segment, west of -86.5 so Florida stays US.
fn in_mexico_gulf(lat: f64, lon: f64) -> bool {
    (-98.0..=-86.5).contains(&lon) && lat > 14.0 && lat < 25.5
}

/// `isAcrossTheBorder`: plainly in Canada or Mexico, by the lines the
/// official page is picked by.
#[must_use]
pub fn is_across_the_border(lat: f64, lon: f64) -> bool {
    is_north_of_the_border(lat, lon) || in_mexico_west(lat, lon) || in_mexico_gulf(lat, lon)
}

/// `mayBeAcrossTheBorder`: could the point be in Canada or Mexico? Wide on
/// purpose: across the line, within a quarter degree of it, or in the two
/// places the bands leave out (Ontario between Detroit and Niagara, and
/// Vancouver Island).
#[must_use]
pub fn may_be_across_the_border(lat: f64, lon: f64) -> bool {
    let margin = 0.25;
    if is_across_the_border(lat, lon)
        || is_north_of_the_border(lat + margin, lon)
        || is_across_the_border(lat - margin, lon)
    {
        return true;
    }
    if (-83.2..=-78.9).contains(&lon) && (41.9..=45.5).contains(&lat) {
        return true;
    }
    (-125.5..=-123.1).contains(&lon) && (48.25..=49.0).contains(&lat)
}

/// The agency whose page answers for a point.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Agency {
    /// The Weather Service, the default.
    Us,
    /// Environment and Climate Change Canada.
    Canada,
    /// Mexico's Servicio Meteorológico Nacional.
    Mexico,
}

/// Which agency `officialURL` sends a point to. A point goes abroad only
/// when it is plainly across the border.
#[must_use]
pub fn official_agency(lat: f64, lon: f64) -> Agency {
    if is_north_of_the_border(lat, lon) || is_canada_below_the_bands(lat, lon) {
        Agency::Canada
    } else if in_mexico_west(lat, lon) || in_mexico_gulf(lat, lon) {
        Agency::Mexico
    } else {
        Agency::Us
    }
}

/// `officialURL`'s text: the ECCC location page, SMN's warnings, or the NWS
/// point page.
#[must_use]
pub fn official_url(lat: f64, lon: f64) -> String {
    match official_agency(lat, lon) {
        Agency::Canada => format!(
            "https://weather.gc.ca/en/location/index.html?coords={},{}",
            swift_text::fixed(lat, 3),
            swift_text::fixed(lon, 3)
        ),
        Agency::Mexico => "https://smn.conagua.gob.mx/es/pronosticos/avisos".to_string(),
        Agency::Us => format!(
            "https://forecast.weather.gov/MapClick.php?lat={}&lon={}",
            swift_text::fixed(lat, 4),
            swift_text::fixed(lon, 4)
        ),
    }
}
