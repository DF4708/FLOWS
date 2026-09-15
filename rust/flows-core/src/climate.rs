// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Climate and astronomy: latitude bands, climate types with their seasonal
//! norms, the FLHH harmonic-climatology reader, the daylight clock and risk
//! timing.
//!
//! This is the port of the app's Swift, function by function:
//!
//! | here | Swift (commit a007de0) |
//! |---|---|
//! | [`band_index`], [`elevation_band_shift`], [`band_profile`] | `LatitudeBands` |
//! | [`ClimateType`], [`classify`], [`seasonal_norms`], [`temperature_beyond_normal`], [`wind_beyond_normal`], [`climate_profile`] | `ClimateProfiles` |
//! | [`julian_day`], [`midnight_jd`], [`solar_terms`], [`hour_angle_minutes`], [`twilight`], [`is_night`], [`solar_elevation`], [`next_change`] | `DaylightClock` |
//! | [`parse_flhh`], [`HarmonicTable`], [`WeekTrig`] | `HarmonicClimatology` |
//! | [`is_active`], [`arrival_offsets`] | `RiskTiming` |
//!
//! # Instants
//!
//! Foundation's `Date` is a double: seconds since 2001-01-01T00:00:00Z, the
//! reference date. Every instant here is that same double, so a Swift facade
//! passes `timeIntervalSinceReferenceDate` straight through and reads the
//! answer back with `Date(timeIntervalSinceReferenceDate:)`. Unix seconds are
//! the reference seconds plus [`REFERENCE_DATE_UNIX_SECONDS`], the way
//! `Date.timeIntervalSince1970` computes them; comparisons are the plain
//! IEEE comparisons `Date` uses, so a NaN instant is never before, after or
//! equal to anything.
//!
//! # Fidelity
//!
//! Every function reproduces the Swift it replaced, pinned by the frozen
//! oracle `flows-bridge/tests/fixtures/swift_climate_oracle.tsv`: exactly
//! where no trigonometry is involved, and to the physical tolerances the
//! oracle states where it is (the app's Release build fuses `sin`/`cos`
//! pairs, see [`crate::fmath`]). Swift's `min`/`max` come from
//! [`crate::fcmp`]; `Int(Double)` is [`crate::fcmp::swift_int`]; every
//! expression keeps the Swift's operand order.
//!
//! Where the Swift TRAPPED (`Int(NaN)` in the band index, an index or
//! overflow in the harmonic score) the functions return `None`. Where it did
//! not trap but should have — `arrivalOffsets` with an absurd sample count
//! allocates until the machine runs out of memory — the port refuses with
//! `None` above [`MAX_ARRIVAL_SAMPLES`].
//!
//! Text in an FLHH file is decoded as Foundation decodes it: invalid UTF-8
//! fails the file, one leading byte-order mark is dropped, and keys compare
//! by bytes — the writer (`flows-train`) emits ASCII digits and ASCII family
//! names, and on canonically equivalent non-ASCII spellings, which the Swift
//! compared as equal, the port answers by bytes (a divergence the oracle
//! names and counts).
//!
//! State stays in Swift: `ClimateProfiles.precise` (empty in this build) and
//! the FLHH file's loading. Every function here is a pure transform of its
//! arguments; nothing reads a clock. Panics: none.

use crate::fcmp::{smax, smin, swift_int};
use crate::fmath;
use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::f64::consts::PI;

// ============================================================ LatitudeBands

/// Southern edge of the Wisconsin band system (the R server's bbox).
pub const SOUTH_ANCHOR: f64 = 42.312985;
/// Northern edge of the Wisconsin band system.
pub const NORTH_ANCHOR: f64 = 47.080621;
/// One band's height in degrees, computed as R computes it.
pub const PITCH_DEGREES: f64 = (NORTH_ANCHOR - SOUTH_ANCHOR) / 10.0;
/// Continental clamp, south (southern Mexico).
pub const MIN_LATITUDE: f64 = 14.0;
/// Continental clamp, north (arctic Canada).
pub const MAX_LATITUDE: f64 = 70.0;
/// Elevation the band profiles assume, metres (Wisconsin's mean).
pub const REFERENCE_ELEVATION_METERS: f64 = 300.0;
/// Metres of elevation per one-band (1 °F) step at the standard lapse rate.
pub const METERS_PER_BAND_STEP: f64 = 85.47;
/// Wind thresholds carried on every profile, mph.
pub const WIND_LOW: f64 = 15.0;
/// See [`WIND_LOW`].
pub const WIND_MEDIUM: f64 = 28.0;
/// See [`WIND_LOW`].
pub const WIND_HIGH: f64 = 45.0;
/// Probability-of-precipitation thresholds carried on every profile, percent.
pub const POP_LOW: f64 = 25.0;
/// See [`POP_LOW`].
pub const POP_MEDIUM: f64 = 50.0;
/// See [`POP_LOW`].
pub const POP_HIGH: f64 = 75.0;

/// A location's climate envelope: the band it sits in, its comfort and record
/// temperatures (°F), and the wind and precipitation thresholds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Profile {
    /// Band index (0 for a climate-type profile).
    pub band: i64,
    /// Lower edge of the comfort band, °F.
    pub comfort_low_f: f64,
    /// Upper edge of the comfort band, °F.
    pub comfort_high_f: f64,
    /// Record low, °F.
    pub record_low_f: f64,
    /// Record high, °F.
    pub record_high_f: f64,
    /// Wind threshold, low, mph.
    pub wind_low: f64,
    /// Wind threshold, medium, mph.
    pub wind_medium: f64,
    /// Wind threshold, high, mph.
    pub wind_high: f64,
    /// Precipitation-probability threshold, low, percent.
    pub pop_low: f64,
    /// Precipitation-probability threshold, medium, percent.
    pub pop_medium: f64,
    /// Precipitation-probability threshold, high, percent.
    pub pop_high: f64,
}

impl Profile {
    /// A profile with the given temperatures and the standard wind and
    /// precipitation thresholds.
    #[must_use]
    pub const fn with_temps(
        band: i64,
        comfort_low_f: f64,
        comfort_high_f: f64,
        record_low_f: f64,
        record_high_f: f64,
    ) -> Profile {
        Profile {
            band,
            comfort_low_f,
            comfort_high_f,
            record_low_f,
            record_high_f,
            wind_low: WIND_LOW,
            wind_medium: WIND_MEDIUM,
            wind_high: WIND_HIGH,
            pop_low: POP_LOW,
            pop_medium: POP_MEDIUM,
            pop_high: POP_HIGH,
        }
    }
}

/// The band a latitude falls in (R's `cut(..., include.lowest = TRUE)`:
/// band 1 starts at the south anchor, each band is `(lo, hi]`), extended
/// north and south of Wisconsin. The latitude is clamped to the continental
/// span first. `None` for a NaN latitude, where Swift trapped on `Int`.
#[must_use]
pub fn band_index(latitude: f64) -> Option<i64> {
    let lat = smin(smax(latitude, MIN_LATITUDE), MAX_LATITUDE);
    if lat <= SOUTH_ANCHOR {
        // Southward: band 0 is the first band below Wisconsin, then negative.
        return swift_int(((lat - SOUTH_ANCHOR) / PITCH_DEGREES).floor()).map(|i| i + 1);
    }
    // Right-closed bands: a latitude exactly on a boundary belongs to the band
    // below it; the epsilon absorbs the residue of the division there.
    swift_int((((lat - SOUTH_ANCHOR) / PITCH_DEGREES) - 1e-9).ceil())
}

/// The elevation-driven band shift, clamped to ±1 (the contiguous rule).
/// 0 without an elevation or for a non-finite one.
#[must_use]
pub fn elevation_band_shift(elevation_meters: Option<f64>) -> i64 {
    let Some(elev) = elevation_meters else {
        return 0;
    };
    if !elev.is_finite() {
        return 0;
    }
    let raw = ((elev - REFERENCE_ELEVATION_METERS) / METERS_PER_BAND_STEP).round();
    // Held in [-1, 1], so the conversion is exact.
    smin(smax(raw, -1.0), 1.0) as i64
}

/// The band profile for a location: inside Wisconsin the R server's rows
/// exactly; beyond, the −1 °F-per-band gradient with physical clamps.
/// `None` where [`band_index`] is.
#[must_use]
pub fn band_profile(latitude: f64, elevation_meters: Option<f64>) -> Option<Profile> {
    let mut band = band_index(latitude)? + elevation_band_shift(elevation_meters);
    let max_band = band_index(MAX_LATITUDE)?;
    let min_band = band_index(MIN_LATITUDE)?;
    band = band.max(min_band).min(max_band);
    let step = (band - 1) as f64;
    let mut p = Profile::with_temps(band, 60.0 - step, 76.0 - step, -28.0 - step, 108.0 - step);
    p.comfort_low_f = smin(smax(p.comfort_low_f, -10.0), 72.0);
    p.comfort_high_f = smin(smax(p.comfort_high_f, p.comfort_low_f + 10.0), 92.0);
    p.record_low_f = smin(smax(p.record_low_f, -80.0), 45.0);
    p.record_high_f = smin(smax(p.record_high_f, p.comfort_high_f + 10.0), 125.0);
    Some(p)
}

// ============================================================ ClimateProfiles

/// Köppen-style climate types for North American driving, in the Swift
/// `allCases` order; the discriminant is the bridge code.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClimateType {
    MarineWestCoast = 0,
    Mediterranean = 1,
    HotDesert = 2,
    ColdSteppe = 3,
    HumidSubtropical = 4,
    HumidContinentalWarm = 5,
    HumidContinentalCool = 6,
    Subarctic = 7,
    Tropical = 8,
    Tundra = 9,
    Highland = 10,
    TemperateOceanic = 11,
}

/// Every climate type, by code.
pub const CLIMATE_TYPES: [ClimateType; 12] = [
    ClimateType::MarineWestCoast,
    ClimateType::Mediterranean,
    ClimateType::HotDesert,
    ClimateType::ColdSteppe,
    ClimateType::HumidSubtropical,
    ClimateType::HumidContinentalWarm,
    ClimateType::HumidContinentalCool,
    ClimateType::Subarctic,
    ClimateType::Tropical,
    ClimateType::Tundra,
    ClimateType::Highland,
    ClimateType::TemperateOceanic,
];

/// The persisted raw value of each type, by code.
pub const CLIMATE_TYPE_NAMES: [&str; 12] = [
    "marineWestCoast",
    "mediterranean",
    "hotDesert",
    "coldSteppe",
    "humidSubtropical",
    "humidContinentalWarm",
    "humidContinentalCool",
    "subarctic",
    "tropical",
    "tundra",
    "highland",
    "temperateOceanic",
];

/// Winter (week 0) and summer (week 26) anchor temperatures and wind norms.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Anchors {
    winter_low: f64,
    winter_high: f64,
    summer_low: f64,
    summer_high: f64,
    wind: f64,
    sigma: f64,
}

impl ClimateType {
    /// The raw value.
    #[must_use]
    pub fn name(self) -> &'static str {
        CLIMATE_TYPE_NAMES[self as usize]
    }

    /// (comfort low, comfort high, record low, record high), °F.
    #[must_use]
    pub fn temps(self) -> (f64, f64, f64, f64) {
        match self {
            ClimateType::MarineWestCoast => (45.0, 72.0, 12.0, 106.0),
            ClimateType::Mediterranean => (48.0, 82.0, 25.0, 116.0),
            ClimateType::HotDesert => (55.0, 98.0, 25.0, 125.0),
            ClimateType::ColdSteppe => (35.0, 85.0, -25.0, 110.0),
            ClimateType::HumidSubtropical => (45.0, 90.0, 5.0, 112.0),
            ClimateType::HumidContinentalWarm => (35.0, 82.0, -20.0, 108.0),
            ClimateType::HumidContinentalCool => (28.0, 78.0, -35.0, 104.0),
            ClimateType::Subarctic => (20.0, 72.0, -55.0, 98.0),
            ClimateType::Tropical => (68.0, 90.0, 40.0, 106.0),
            ClimateType::Tundra => (10.0, 58.0, -65.0, 86.0),
            ClimateType::Highland => (28.0, 74.0, -40.0, 100.0),
            ClimateType::TemperateOceanic => (42.0, 74.0, 5.0, 102.0),
        }
    }

    /// The type's temperature envelope as a band-0 profile.
    #[must_use]
    pub fn profile(self) -> Profile {
        let (cl, ch, rl, rh) = self.temps();
        Profile::with_temps(0, cl, ch, rl, rh)
    }

    fn anchors(self) -> Anchors {
        let (winter_low, winter_high, summer_low, summer_high, wind, sigma) = match self {
            ClimateType::MarineWestCoast => (38.0, 50.0, 58.0, 72.0, 8.0, 3.0),
            ClimateType::Mediterranean => (45.0, 58.0, 65.0, 82.0, 7.0, 2.5),
            ClimateType::HotDesert => (38.0, 62.0, 72.0, 98.0, 9.0, 4.0),
            ClimateType::ColdSteppe => (15.0, 35.0, 55.0, 85.0, 11.0, 5.0),
            ClimateType::HumidSubtropical => (38.0, 58.0, 68.0, 90.0, 8.0, 3.5),
            ClimateType::HumidContinentalWarm => (22.0, 38.0, 62.0, 82.0, 9.0, 4.0),
            ClimateType::HumidContinentalCool => (12.0, 28.0, 58.0, 78.0, 10.0, 4.5),
            ClimateType::Subarctic => (0.0, 20.0, 50.0, 72.0, 12.0, 5.5),
            ClimateType::Tropical => (68.0, 84.0, 76.0, 90.0, 11.0, 4.0),
            ClimateType::Tundra => (-15.0, 10.0, 35.0, 58.0, 13.0, 6.0),
            ClimateType::Highland => (18.0, 35.0, 50.0, 74.0, 11.0, 5.0),
            ClimateType::TemperateOceanic => (35.0, 48.0, 55.0, 74.0, 9.0, 3.5),
        };
        Anchors {
            winter_low,
            winter_high,
            summer_low,
            summer_high,
            wind,
            sigma,
        }
    }
}

/// Classify a coordinate into its climate type from geography alone, most
/// specific rule first. A NaN coordinate fails every comparison and lands
/// where the Swift landed it: subarctic.
#[must_use]
pub fn classify(latitude: f64, longitude: f64, elevation_meters: Option<f64>) -> ClimateType {
    let (lat, lon) = (latitude, longitude);
    let e = elevation_meters.unwrap_or(0.0);
    if lat >= 66.0 {
        return ClimateType::Tundra;
    }
    if e >= 2000.0 {
        return ClimateType::Highland;
    }
    // Tropics, and the South-Florida peninsula tip.
    if lat < 25.0 || (lat < 27.0 && lon > -83.0) {
        return ClimateType::Tropical;
    }
    // Western North America, Pacific-influenced.
    if lon <= -117.0 {
        if lat >= 42.0 {
            return ClimateType::MarineWestCoast;
        }
        return ClimateType::Mediterranean;
    }
    // Interior West: deserts against high steppe.
    if lon > -117.0 && lon <= -102.0 {
        if e >= 1000.0 {
            return ClimateType::ColdSteppe;
        }
        if lat < 37.0 {
            return ClimateType::HotDesert;
        }
        return ClimateType::ColdSteppe;
    }
    // Eastern North America, by latitude.
    if lat < 37.0 {
        return ClimateType::HumidSubtropical;
    }
    if lat < 43.0 {
        return ClimateType::HumidContinentalWarm;
    }
    if lat < 50.0 {
        return ClimateType::HumidContinentalCool;
    }
    ClimateType::Subarctic
}

/// Daily temperature variability around the seasonal norm, °F.
pub const TEMP_SIGMA_F: f64 = 12.0;

/// The expected weekly window for a region: typical daily low and high and
/// the typical wind mean and spread.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SeasonalNorms {
    /// Typical daily low, °F.
    pub week_low_f: f64,
    /// Typical daily high, °F.
    pub week_high_f: f64,
    /// Typical wind, mph.
    pub wind_mean_mph: f64,
    /// Wind spread, mph.
    pub wind_sigma_mph: f64,
}

/// Seasonal norms for a location at a week of year: a sinusoidal blend from
/// the type's winter anchors (week 0) to its summer anchors (week 26). The
/// week is wrapped into 0…51 first, as Swift's `((week % 52) + 52) % 52`.
#[must_use]
pub fn seasonal_norms(
    week: i64,
    latitude: f64,
    longitude: f64,
    elevation_meters: Option<f64>,
) -> SeasonalNorms {
    let a = classify(latitude, longitude, elevation_meters).anchors();
    let wrapped = week.rem_euclid(52); // Swift's ((week % 52) + 52) % 52
    let phase = (1.0 - fmath::cos(2.0 * PI * wrapped as f64 / 52.0)) / 2.0;
    SeasonalNorms {
        week_low_f: a.winter_low + (a.summer_low - a.winter_low) * phase,
        week_high_f: a.winter_high + (a.summer_high - a.winter_high) * phase,
        wind_mean_mph: a.wind,
        wind_sigma_mph: a.sigma,
    }
}

/// Does a temperature stand more than one σ outside the seasonal window?
/// A non-finite temperature never does.
#[must_use]
pub fn temperature_beyond_normal(temp_f: f64, norms: &SeasonalNorms) -> bool {
    if !temp_f.is_finite() {
        return false;
    }
    temp_f > norms.week_high_f + TEMP_SIGMA_F || temp_f < norms.week_low_f - TEMP_SIGMA_F
}

/// Does a wind stand more than two σ above the seasonal mean? A non-finite
/// wind never does.
#[must_use]
pub fn wind_beyond_normal(wind_mph: f64, norms: &SeasonalNorms) -> bool {
    if !wind_mph.is_finite() {
        return false;
    }
    wind_mph > norms.wind_mean_mph + 2.0 * norms.wind_sigma_mph
}

/// The temperature profile every risk equation reads for a location: the
/// climate type's envelope. (The Swift consulted a per-ZIP precise map first;
/// it is empty in this build and stays in Swift.)
#[must_use]
pub fn climate_profile(latitude: f64, longitude: f64, elevation_meters: Option<f64>) -> Profile {
    classify(latitude, longitude, elevation_meters).profile()
}

// ============================================================ instants

/// Seconds from 1970-01-01T00:00:00Z to Foundation's reference date,
/// 2001-01-01T00:00:00Z.
pub const REFERENCE_DATE_UNIX_SECONDS: f64 = 978_307_200.0;

/// `Date.timeIntervalSince1970` for an instant given in reference seconds.
#[must_use]
pub fn unix_seconds(reference_seconds: f64) -> f64 {
    reference_seconds + REFERENCE_DATE_UNIX_SECONDS
}

/// `Date(timeIntervalSince1970:).timeIntervalSinceReferenceDate`.
#[must_use]
pub fn reference_seconds(unix_seconds: f64) -> f64 {
    unix_seconds - REFERENCE_DATE_UNIX_SECONDS
}

// ============================================================ DaylightClock

/// Sun angle (degrees) that counts as dark: civil twilight.
pub const CIVIL_TWILIGHT_DEGREES: f64 = -6.0;
/// Degrees to radians, as the Swift's `Double.pi / 180`.
const RAD: f64 = PI / 180.0;

/// The Julian day number of an instant (reference seconds).
#[must_use]
pub fn julian_day(now: f64) -> f64 {
    unix_seconds(now) / 86_400.0 + 2440587.5
}

/// The Julian day of the midnight beginning the UTC day containing `jd`
/// (a floor, since Julian days tick over at noon).
#[must_use]
pub fn midnight_jd(jd: f64) -> f64 {
    (jd - 0.5).floor() + 0.5
}

/// The sun's declination (degrees) and the equation of time (minutes).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SolarTerms {
    /// Declination, degrees.
    pub declination: f64,
    /// Equation of time, minutes.
    pub equation_of_time: f64,
}

/// The NOAA solar-position terms for a Julian day, computed together as the
/// Swift computes them and in its operand order. `pow(tan x, 2)` is written
/// as the product the optimiser makes of it.
#[must_use]
pub fn solar_terms(jd: f64) -> SolarTerms {
    let t = (jd - 2451545.0) / 36525.0; // Julian centuries
    let mean_long = (280.46646 + t * (36000.76983 + t * 0.0003032)) % 360.0;
    let mean_anom = 357.52911 + t * (35999.05029 - 0.0001537 * t);
    let eccent = 0.016708634 - t * (0.000042037 + 0.0000001267 * t);
    let center = fmath::sin(mean_anom * RAD) * (1.914602 - t * (0.004817 + 0.000014 * t))
        + fmath::sin(2.0 * mean_anom * RAD) * (0.019993 - 0.000101 * t)
        + fmath::sin(3.0 * mean_anom * RAD) * 0.000289;
    let true_long = mean_long + center;
    let omega = 125.04 - 1934.136 * t;
    let apparent_long = true_long - 0.00569 - 0.00478 * fmath::sin(omega * RAD);
    let mean_obliq =
        23.0 + (26.0 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60.0) / 60.0;
    let obliq = mean_obliq + 0.00256 * fmath::cos(omega * RAD);
    let declination = fmath::asin(fmath::sin(obliq * RAD) * fmath::sin(apparent_long * RAD)) / RAD;
    let half_tan = fmath::tan(obliq * RAD / 2.0);
    let y = half_tan * half_tan;
    let equation_of_time = 4.0
        * (y * fmath::sin(2.0 * mean_long * RAD) - 2.0 * eccent * fmath::sin(mean_anom * RAD)
            + 4.0 * eccent * y * fmath::sin(mean_anom * RAD) * fmath::cos(2.0 * mean_long * RAD)
            - 0.5 * y * y * fmath::sin(4.0 * mean_long * RAD)
            - 1.25 * eccent * eccent * fmath::sin(2.0 * mean_anom * RAD))
        / RAD;
    SolarTerms {
        declination,
        equation_of_time,
    }
}

/// The cosine of the hour angle at which the sun reaches `angle` (degrees);
/// outside [-1, 1] there is no such moment. Exposed so the oracle can tell a
/// polar edge case (a cosine within a hair of ±1) from a real disagreement.
#[must_use]
pub fn hour_angle_cosine(latitude: f64, declination: f64, angle: f64) -> f64 {
    (fmath::cos((90.0 - angle) * RAD) - fmath::sin(latitude * RAD) * fmath::sin(declination * RAD))
        / (fmath::cos(latitude * RAD) * fmath::cos(declination * RAD))
}

/// Minutes from local solar noon to the sun reaching `angle` (degrees).
/// `None` inside the polar day or night, where it never does — and for a
/// NaN, which fails the same guard.
#[must_use]
pub fn hour_angle_minutes(latitude: f64, declination: f64, angle: f64) -> Option<f64> {
    let cos_h = hour_angle_cosine(latitude, declination, angle);
    if !(-1.0..=1.0).contains(&cos_h) {
        return None;
    }
    Some(fmath::acos(cos_h) / RAD * 4.0) // 4 minutes per degree of rotation
}

/// Dawn and dusk as instants (reference seconds).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Twilight {
    /// Dawn.
    pub dawn: f64,
    /// Dusk.
    pub dusk: f64,
}

/// Dawn and dusk at `angle` for the solar day the driver is in at `now`
/// (the day is chosen by longitude, not in UTC). `None` in the polar day or
/// night.
#[must_use]
pub fn twilight(latitude: f64, longitude: f64, now: f64, angle: f64) -> Option<Twilight> {
    let jd = midnight_jd(julian_day(now) + longitude / 360.0);
    let terms = solar_terms(jd);
    let ha = hour_angle_minutes(latitude, terms.declination, angle)?;
    // Solar noon in minutes past midnight UTC at this longitude.
    let noon_utc = 720.0 - 4.0 * longitude - terms.equation_of_time;
    let midnight = reference_seconds((jd - 2440587.5) * 86_400.0);
    Some(Twilight {
        dawn: midnight + (noon_utc - ha) * 60.0,
        dusk: midnight + (noon_utc + ha) * 60.0,
    })
}

/// The sun's height above the horizon, degrees.
#[must_use]
pub fn solar_elevation(latitude: f64, longitude: f64, now: f64) -> f64 {
    let jd = julian_day(now);
    let terms = solar_terms(jd);
    let minutes_utc = (jd - midnight_jd(jd)) * 1_440.0;
    // Degrees the earth has turned past this longitude's solar noon.
    let true_solar_minutes = minutes_utc + terms.equation_of_time + 4.0 * longitude;
    let hour_angle = true_solar_minutes / 4.0 - 180.0;
    let zenith = fmath::acos(
        fmath::sin(latitude * RAD) * fmath::sin(terms.declination * RAD)
            + fmath::cos(latitude * RAD)
                * fmath::cos(terms.declination * RAD)
                * fmath::cos(hour_angle * RAD),
    ) / RAD;
    90.0 - zenith
}

/// Is it dark here, now (civil twilight)? Where there is no dawn or dusk
/// today, the sun's actual height decides.
#[must_use]
pub fn is_night(latitude: f64, longitude: f64, now: f64) -> bool {
    match twilight(latitude, longitude, now, CIVIL_TWILIGHT_DEGREES) {
        None => solar_elevation(latitude, longitude, now) < CIVIL_TWILIGHT_DEGREES,
        // `Date`'s `>=` is Comparable's `!(lhs < rhs)`, so a NaN instant is night.
        Some(t) => now < t.dawn || now.partial_cmp(&t.dusk) != Some(Ordering::Less),
    }
}

/// When to look again: the next dawn or dusk, or an hour out where there is
/// no boundary today or tomorrow.
#[must_use]
pub fn next_change(latitude: f64, longitude: f64, now: f64) -> f64 {
    let Some(today) = twilight(latitude, longitude, now, CIVIL_TWILIGHT_DEGREES) else {
        return now + 3_600.0;
    };
    if now < today.dawn {
        return today.dawn;
    }
    if now < today.dusk {
        return today.dusk;
    }
    match twilight(latitude, longitude, now + 86_400.0, CIVIL_TWILIGHT_DEGREES) {
        Some(tomorrow) => tomorrow.dawn,
        None => now + 3_600.0,
    }
}

// ============================================================ HarmonicClimatology

/// Largest reconstructed score.
pub const SCORE_MAX: f64 = 0.6;
/// The FLHH header's bound on the ZIP count (exclusive).
pub const FLHH_MAX_ZIPS: usize = 100_000;
/// The FLHH header's bound on the family count (inclusive).
pub const FLHH_MAX_FAMILIES: usize = 32;
/// Coefficients per ZIP and family: mean, a1, b1, a2, b2.
pub const FLHH_COEFFICIENTS: usize = 5;

/// A decoded `history_harmonic.bin`: five Fourier coefficients per ZIP and
/// hazard family.
#[derive(Clone, Debug, PartialEq)]
pub struct HarmonicTable {
    families: Vec<String>,
    zips: Vec<String>,
    coeffs: Vec<f32>,
    n_families: usize,
}

/// Parse an FLHH file. `None` on any structural mismatch, as the Swift's
/// failable initialiser: wrong magic or version, a ZIP count outside
/// `1 ..< 100_000`, a family count outside `1 ... 32`, a name or ZIP that is
/// not UTF-8, or a body that is not exactly `nZips × nFamilies × 5` floats.
#[must_use]
pub fn parse_flhh(data: &[u8]) -> Option<HarmonicTable> {
    let mut off = 0usize;
    let mut read = |n: usize| -> Option<&[u8]> {
        let end = off.checked_add(n)?;
        let slice = data.get(off..end)?;
        off = end;
        Some(slice)
    };
    let u32_at = |b: &[u8]| -> Option<u32> { b.try_into().ok().map(u32::from_le_bytes) };
    if read(4)? != b"FLHH" {
        return None;
    }
    if u32_at(read(4)?)? != 1 {
        return None;
    }
    let n_zips = usize::try_from(u32_at(read(4)?)?).ok()?;
    if n_zips == 0 || n_zips >= FLHH_MAX_ZIPS {
        return None;
    }
    let n_fams = usize::try_from(u32_at(read(4)?)?).ok()?;
    if n_fams == 0 || n_fams > FLHH_MAX_FAMILIES {
        return None;
    }
    let mut families = Vec::with_capacity(n_fams);
    for _ in 0..n_fams {
        let len = usize::from(*read(1)?.first()?);
        families.push(foundation_utf8(read(len)?)?);
    }
    let zip_bytes = read(5usize.checked_mul(n_zips)?)?;
    let mut zips = Vec::with_capacity(n_zips);
    for chunk in zip_bytes.chunks_exact(5) {
        zips.push(foundation_utf8(chunk)?);
    }
    let count = n_zips.checked_mul(n_fams)?.checked_mul(FLHH_COEFFICIENTS)?;
    let want = count.checked_mul(4)?;
    if off.checked_add(want)? != data.len() {
        return None;
    }
    let body = data.get(off..off + want)?;
    let coeffs: Vec<f32> = body
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();
    Some(HarmonicTable {
        families,
        zips,
        coeffs,
        n_families: n_fams,
    })
}

/// Foundation's `String(bytes:encoding: .utf8)`: `None` for invalid UTF-8, and
/// one leading byte-order mark (U+FEFF) dropped — a lone mark decodes to the
/// empty string, a doubled one to a single mark. Everything else, a NUL
/// included, is kept as written. Pinned by the oracle's odd-UTF-8 tables.
fn foundation_utf8(bytes: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(bytes).ok()?;
    Some(text.strip_prefix('\u{FEFF}').unwrap_or(text).to_string())
}

/// The four trig factors for a week, computed once.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WeekTrig {
    /// cos t.
    pub cos_t: f64,
    /// sin t.
    pub sin_t: f64,
    /// cos 2t.
    pub cos_2t: f64,
    /// sin 2t.
    pub sin_2t: f64,
}

impl WeekTrig {
    /// The factors for `week`, wrapped into 0…51: `t = 2πw/52`.
    #[must_use]
    pub fn new(week: i64) -> WeekTrig {
        // Swift's ((week % 52) + 52) % 52.
        let t = 2.0 * PI * week.rem_euclid(52) as f64 / 52.0;
        WeekTrig {
            cos_t: fmath::cos(t),
            sin_t: fmath::sin(t),
            cos_2t: fmath::cos(2.0 * t),
            sin_2t: fmath::sin(2.0 * t),
        }
    }
}

impl HarmonicTable {
    /// Family names, in file order.
    #[must_use]
    pub fn families(&self) -> &[String] {
        &self.families
    }

    /// ZIP codes, in file order (sorted ascending when the file is sound).
    #[must_use]
    pub fn zips(&self) -> &[String] {
        &self.zips
    }

    /// The coefficient body, `nZips × nFamilies × 5`.
    #[must_use]
    pub fn coefficients(&self) -> &[f32] {
        &self.coeffs
    }

    /// The family count.
    #[must_use]
    pub fn family_count(&self) -> usize {
        self.n_families
    }

    /// The row of a ZIP by binary search over the file order, comparing
    /// bytes (the Swift compared `String`s; for the ASCII digits every FLHH
    /// file holds that is the same order). A file that is unsorted or holds
    /// duplicates answers as the search happens to land, as it did in Swift.
    #[must_use]
    pub fn zip_index(&self, zip: &str) -> Option<usize> {
        let mut lo: i64 = 0;
        let mut hi: i64 = i64::try_from(self.zips.len()).ok()? - 1;
        while lo <= hi {
            let mid = (lo + hi) / 2;
            let entry = self.zips.get(usize::try_from(mid).ok()?)?.as_str();
            if entry == zip {
                return usize::try_from(mid).ok();
            }
            if entry < zip {
                lo = mid + 1;
            } else {
                hi = mid - 1;
            }
        }
        None
    }

    /// ZIP → row for bulk consumers; a duplicated ZIP keeps its first row.
    #[must_use]
    pub fn zip_index_map(&self) -> BTreeMap<String, usize> {
        let mut map = BTreeMap::new();
        for (i, z) in self.zips.iter().enumerate() {
            map.entry(z.clone()).or_insert(i);
        }
        map
    }

    /// The reconstructed score for a row and family with precomputed trig:
    /// `clamp(mean + a1 cos t + b1 sin t + a2 cos 2t + b2 sin 2t, 0, 0.6)`.
    /// `None` where Swift trapped: an index overflow or a row or family past
    /// the table.
    #[must_use]
    pub fn score(&self, zip_index: i64, family_index: i64, trig: &WeekTrig) -> Option<f64> {
        let n_families = i64::try_from(self.n_families).ok()?;
        let base = zip_index
            .checked_mul(n_families)?
            .checked_add(family_index)?
            .checked_mul(5)?;
        let base = usize::try_from(base).ok()?;
        let c = self
            .coeffs
            .get(base..base.checked_add(FLHH_COEFFICIENTS)?)?;
        let v = f64::from(c[0])
            + f64::from(c[1]) * trig.cos_t
            + f64::from(c[2]) * trig.sin_t
            + f64::from(c[3]) * trig.cos_2t
            + f64::from(c[4]) * trig.sin_2t;
        Some(smin(smax(v, 0.0), SCORE_MAX))
    }

    /// [`Self::score`] for a week of year.
    #[must_use]
    pub fn score_week(&self, zip_index: i64, family_index: i64, week: i64) -> Option<f64> {
        self.score(zip_index, family_index, &WeekTrig::new(week))
    }

    /// The score for a ZIP and family by name; `None` when either is not in
    /// the table (and where the row lookup trapped in Swift).
    #[must_use]
    pub fn score_named(&self, zip: &str, family: &str, week: i64) -> Option<f64> {
        let fi = self.families.iter().position(|f| f == family)?;
        let zi = self.zip_index(zip)?;
        self.score_week(i64::try_from(zi).ok()?, i64::try_from(fi).ok()?, week)
    }
}

// ============================================================ RiskTiming

/// Will an alert still be active when the driver reaches its stretch,
/// `arrival_offset` seconds from `now`? An unknown expiry counts as active.
/// Instants are reference seconds; a negative offset counts as 0.
#[must_use]
pub fn is_active(expires: Option<f64>, arrival_offset: f64, now: f64) -> bool {
    match expires {
        None => true,
        Some(e) => e > now + smax(arrival_offset, 0.0),
    }
}

/// The most corridor samples [`arrival_offsets`] will lay out. The Swift
/// accepted any count and, asked for an absurd one, allocated until the
/// machine ran out of memory; a route has never needed more than a few
/// hundred.
pub const MAX_ARRIVAL_SAMPLES: i64 = 1 << 20;

/// Seconds from departure to each of `sample_count` evenly spaced corridor
/// samples on a route taking `total_travel_seconds` (negative counts as 0).
/// Empty below one sample, `[0]` for one; `None` above
/// [`MAX_ARRIVAL_SAMPLES`].
#[must_use]
pub fn arrival_offsets(sample_count: i64, total_travel_seconds: f64) -> Option<Vec<f64>> {
    if sample_count > MAX_ARRIVAL_SAMPLES {
        return None;
    }
    if sample_count <= 0 {
        return Some(Vec::new());
    }
    if sample_count == 1 {
        return Some(vec![0.0]);
    }
    let total = smax(total_travel_seconds, 0.0);
    let last = (sample_count - 1) as f64;
    Some((0..sample_count).map(|i| total * i as f64 / last).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wisconsin_bands_are_the_r_servers_rows() {
        assert_eq!(band_index(SOUTH_ANCHOR), Some(1));
        assert_eq!(
            band_index(SOUTH_ANCHOR + PITCH_DEGREES),
            Some(1),
            "a boundary belongs to the band below"
        );
        assert_eq!(band_index(SOUTH_ANCHOR + 1.5 * PITCH_DEGREES), Some(2));
        assert_eq!(band_index(NORTH_ANCHOR), Some(10));
        assert_eq!(band_index(f64::NAN), None, "Swift trapped on Int(NaN)");
        let p = band_profile(43.07, None).expect("Madison");
        assert_eq!(p.band, 2);
        assert_eq!(p.comfort_low_f, 59.0);
    }

    #[test]
    fn elevation_shifts_at_most_one_band() {
        assert_eq!(elevation_band_shift(None), 0);
        assert_eq!(elevation_band_shift(Some(f64::NAN)), 0);
        assert_eq!(elevation_band_shift(Some(1609.0)), 1);
        assert_eq!(elevation_band_shift(Some(-80.0)), -1);
        assert_eq!(elevation_band_shift(Some(310.0)), 0);
    }

    #[test]
    fn the_classifier_knows_its_cities() {
        assert_eq!(classify(47.61, -122.33, None), ClimateType::MarineWestCoast);
        assert_eq!(classify(33.45, -112.07, None), ClimateType::HotDesert);
        assert_eq!(
            classify(39.74, -104.99, Some(1609.0)),
            ClimateType::ColdSteppe
        );
        assert_eq!(classify(25.76, -80.19, None), ClimateType::Tropical);
        assert_eq!(classify(71.29, -156.79, None), ClimateType::Tundra);
        assert_eq!(classify(f64::NAN, f64::NAN, None), ClimateType::Subarctic);
        assert_eq!(
            CLIMATE_TYPES[ClimateType::Highland as usize].name(),
            "highland"
        );
    }

    #[test]
    fn norms_blend_winter_to_summer_and_gates_ignore_non_finite() {
        let winter = seasonal_norms(0, 44.98, -93.27, None);
        let summer = seasonal_norms(26, 44.98, -93.27, None);
        assert_eq!(winter.week_low_f, 12.0);
        assert_eq!(summer.week_high_f, 78.0);
        assert_eq!(seasonal_norms(52, 44.98, -93.27, None), winter);
        assert!(temperature_beyond_normal(100.0, &summer));
        assert!(!temperature_beyond_normal(f64::INFINITY, &summer));
        assert!(wind_beyond_normal(25.0, &summer));
        assert!(!wind_beyond_normal(f64::NAN, &summer));
    }

    #[test]
    fn madison_has_a_dawn_and_a_dusk_and_the_far_north_has_none_in_june() {
        // 2026-06-21 18:00Z, in reference seconds.
        let june = reference_seconds(1_782_064_800.0);
        let t =
            twilight(43.07, -89.40, june, CIVIL_TWILIGHT_DEGREES).expect("a June day in Madison");
        assert!(t.dawn < t.dusk);
        assert!(
            !is_night(43.07, -89.40, june),
            "1 pm local in June is daylight"
        );
        // 66°N on the June solstice: the sun never drops 6° below the horizon.
        assert_eq!(
            twilight(66.0, -150.0, june, CIVIL_TWILIGHT_DEGREES),
            None,
            "no civil dusk"
        );
        assert!(
            !is_night(66.0, -150.0, june),
            "the sun's height decides where there is no boundary"
        );
        let december = reference_seconds(1_797_894_000.0); // 2026-12-21 23:00Z
        assert!(
            is_night(43.07, -89.40, december),
            "5 pm local on the December solstice is past civil dusk"
        );
        assert!(
            !is_night(43.07, -89.40, f64::NAN),
            "a NaN instant has no twilight and no height: not night"
        );
        assert!(next_change(43.07, -89.40, june) > june);
    }

    #[test]
    fn julian_day_and_midnight_floor() {
        // 2000-01-01T12:00Z is J2000.0.
        let j2000 = reference_seconds(946_728_000.0);
        assert_eq!(julian_day(j2000), 2451545.0);
        assert_eq!(midnight_jd(2451545.0), 2_451_544.5);
        assert_eq!(
            midnight_jd(2_451_545.4),
            2_451_544.5,
            "an afternoon floors to the same midnight"
        );
    }

    fn table_bytes() -> Vec<u8> {
        let mut b = b"FLHH".to_vec();
        b.extend_from_slice(&1u32.to_le_bytes());
        b.extend_from_slice(&2u32.to_le_bytes());
        b.extend_from_slice(&2u32.to_le_bytes());
        for f in ["winter", "heat"] {
            b.push(f.len() as u8);
            b.extend_from_slice(f.as_bytes());
        }
        b.extend_from_slice(b"5370385004");
        let coeffs: [f32; 20] = [
            0.3, 0.25, 0.0, 0.0, 0.0, 0.05, 0.0, 0.0, 0.0, 0.0, 0.02, 0.0, 0.0, 0.0, 0.0, 0.3,
            -0.25, 0.0, 0.0, 0.0,
        ];
        for c in coeffs {
            b.extend_from_slice(&c.to_le_bytes());
        }
        b
    }

    #[test]
    fn flhh_parses_scores_and_refuses_a_bad_length() {
        let bytes = table_bytes();
        let t = parse_flhh(&bytes).expect("a sound table");
        assert_eq!(t.families(), ["winter", "heat"]);
        assert_eq!(t.zip_index("85004"), Some(1));
        assert_eq!(t.zip_index("60601"), None);
        let winter_week0 = t.score_named("53703", "winter", 0).expect("present");
        assert_eq!(
            winter_week0,
            f64::from(0.3_f32) + f64::from(0.25_f32),
            "mean + a1 at cos 0 = 1, as f32 coefficients"
        );
        assert_eq!(
            t.score_named("85004", "heat", 0),
            Some(f64::from(0.3_f32) + f64::from(-0.25_f32))
        );
        assert_eq!(
            t.score(2, 0, &WeekTrig::new(0)),
            None,
            "a row past the table trapped in Swift"
        );
        assert_eq!(
            t.score(i64::MAX, 0, &WeekTrig::new(0)),
            None,
            "an index overflow trapped in Swift"
        );
        let mut short = bytes.clone();
        short.pop();
        assert_eq!(parse_flhh(&short), None);
        let mut long = bytes;
        long.push(0);
        assert_eq!(parse_flhh(&long), None);
        assert_eq!(parse_flhh(b"XXXX"), None);
    }

    #[test]
    fn arrivals_are_evenly_spaced_and_absurd_counts_are_refused() {
        assert_eq!(arrival_offsets(0, 3600.0), Some(Vec::new()));
        assert_eq!(arrival_offsets(1, 3600.0), Some(vec![0.0]));
        assert_eq!(arrival_offsets(3, 3600.0), Some(vec![0.0, 1800.0, 3600.0]));
        assert_eq!(arrival_offsets(3, -5.0), Some(vec![0.0, 0.0, 0.0]));
        assert_eq!(arrival_offsets(i64::MAX, 3600.0), None);
        assert!(is_active(None, 1e9, 0.0));
        assert!(is_active(Some(100.0), 50.0, 0.0));
        assert!(
            !is_active(Some(100.0), 100.0, 0.0),
            "expiring as the driver arrives is not active"
        );
        assert!(
            is_active(Some(100.0), -1e9, 0.0),
            "a negative offset counts as now"
        );
    }
}
