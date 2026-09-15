// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::climate`: latitude bands, climate types and
//! seasonal norms, the daylight clock, the FLHH harmonic-climatology table and
//! risk timing. Implementations live in `flows-core`; this file only crosses.
//!
//! Boundary encodings, chosen so nothing Swift sends can be misread:
//! - an instant is `Date.timeIntervalSinceReferenceDate`, and comes back the
//!   same way;
//! - an optional argument is a value plus a `has_` flag, never NaN;
//! - a band profile carries `has` (1 or 0): 0 where the Swift trapped (a NaN
//!   latitude); an optional number is [`ffi::FlowsClimateOptional`], because
//!   a present harmonic score can itself be NaN;
//! - a climate type is its code, the Swift `allCases` order;
//! - the harmonic table is an opaque Rust value Swift holds by handle: the
//!   file is parsed once and never copied out. A score by row and family
//!   answers NaN where the Swift trapped (a row or family past the table);
//! - a refused arrival-offset count answers the empty list.
//!
//! Every function is a pure transform, safe from any thread; the table handle
//! is read-only after parsing.

use crate::contain;
use ffi::{
    FlowsClimateCell, FlowsClimateNorms, FlowsClimateOptional, FlowsClimateProfile,
    FlowsClimateSolarTerms, FlowsClimateTwilight, FlowsClimateWeekTrig,
};
use flows_core::climate as cl;

#[swift_bridge::bridge]
mod ffi {
    // (swift-bridge 0.1.59 rejects doc attributes on shared structs, so these
    // are plain comments.)
    //
    // A band or climate-type profile; `has` is 0 where the Swift trapped.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsClimateProfile {
        has: f64,
        band: i64,
        comfort_low_f: f64,
        comfort_high_f: f64,
        record_low_f: f64,
        record_high_f: f64,
        wind_low: f64,
        wind_medium: f64,
        wind_high: f64,
        pop_low: f64,
        pop_medium: f64,
        pop_high: f64,
    }
    // Seasonal norms for a place and week.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsClimateNorms {
        week_low_f: f64,
        week_high_f: f64,
        wind_mean_mph: f64,
        wind_sigma_mph: f64,
    }
    // The sun's declination (degrees) and equation of time (minutes).
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsClimateSolarTerms {
        declination: f64,
        equation_of_time: f64,
    }
    // Dawn and dusk, reference seconds; `has` 0 in the polar day or night.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsClimateTwilight {
        has: f64,
        dawn: f64,
        dusk: f64,
    }
    // The four trig factors of a week of year.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsClimateWeekTrig {
        cos_t: f64,
        sin_t: f64,
        cos_2t: f64,
        sin_2t: f64,
    }
    // An optional number: `value` is meaningful only when `is_some` is 1.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsClimateOptional {
        is_some: f64,
        value: f64,
    }
    // A precise-normals cell key: `key` is meaningful only when `has` is true.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsClimateCell {
        has: bool,
        key: i64,
    }

    extern "Rust" {
        fn flows_climate_south_anchor() -> f64;
        fn flows_climate_north_anchor() -> f64;
        fn flows_climate_pitch_degrees() -> f64;
        fn flows_climate_min_latitude() -> f64;
        fn flows_climate_max_latitude() -> f64;
        fn flows_climate_reference_elevation_meters() -> f64;
        fn flows_climate_meters_per_band_step() -> f64;
        fn flows_climate_band_index(latitude: f64) -> FlowsClimateOptional;
        fn flows_climate_elevation_band_shift(elevation_meters: f64, has_elevation: bool) -> i64;
        fn flows_climate_band_profile(
            latitude: f64,
            elevation_meters: f64,
            has_elevation: bool,
        ) -> FlowsClimateProfile;

        fn flows_climate_type_names() -> Vec<String>;
        fn flows_climate_type_profile(code: u8) -> FlowsClimateProfile;
        fn flows_climate_classify(
            latitude: f64,
            longitude: f64,
            elevation_meters: f64,
            has_elevation: bool,
        ) -> u8;
        fn flows_climate_temp_sigma_f() -> f64;
        fn flows_climate_seasonal_norms(
            week: i64,
            latitude: f64,
            longitude: f64,
            elevation_meters: f64,
            has_elevation: bool,
        ) -> FlowsClimateNorms;
        fn flows_climate_temperature_beyond_normal(
            temp_f: f64,
            week_low_f: f64,
            week_high_f: f64,
            wind_mean_mph: f64,
            wind_sigma_mph: f64,
        ) -> bool;
        fn flows_climate_wind_beyond_normal(
            wind_mph: f64,
            week_low_f: f64,
            week_high_f: f64,
            wind_mean_mph: f64,
            wind_sigma_mph: f64,
        ) -> bool;
        fn flows_climate_profile(
            latitude: f64,
            longitude: f64,
            elevation_meters: f64,
            has_elevation: bool,
        ) -> FlowsClimateProfile;
        fn flows_climate_precise_cell(latitude: f64, longitude: f64) -> FlowsClimateCell;
        fn flows_climate_precise_cell_near_home(
            key: i64,
            home_latitude: f64,
            home_longitude: f64,
        ) -> bool;

        fn flows_climate_civil_twilight_degrees() -> f64;
        fn flows_climate_julian_day(now: f64) -> f64;
        fn flows_climate_midnight_jd(jd: f64) -> f64;
        fn flows_climate_solar_terms(jd: f64) -> FlowsClimateSolarTerms;
        fn flows_climate_hour_angle_minutes(latitude: f64, declination: f64, angle: f64) -> f64;
        fn flows_climate_twilight(
            latitude: f64,
            longitude: f64,
            now: f64,
            angle: f64,
        ) -> FlowsClimateTwilight;
        fn flows_climate_is_night(latitude: f64, longitude: f64, now: f64) -> bool;
        fn flows_climate_solar_elevation(latitude: f64, longitude: f64, now: f64) -> f64;
        fn flows_climate_next_change(latitude: f64, longitude: f64, now: f64) -> f64;

        fn flows_climate_score_max() -> f64;
        fn flows_climate_week_trig(week: i64) -> FlowsClimateWeekTrig;

        fn flows_climate_is_active(
            expires: f64,
            has_expires: bool,
            arrival_offset: f64,
            now: f64,
        ) -> bool;
        fn flows_climate_max_arrival_samples() -> i64;
        fn flows_climate_arrival_offsets(sample_count: i64, total_travel_seconds: f64) -> Vec<f64>;
    }

    extern "Rust" {
        type FlowsHarmonicTable;
        fn flows_climate_parse_flhh(data: &[u8]) -> Option<FlowsHarmonicTable>;
        fn families(self: &FlowsHarmonicTable) -> Vec<String>;
        fn zips(self: &FlowsHarmonicTable) -> Vec<String>;
        fn family_count(self: &FlowsHarmonicTable) -> u32;
        fn zip_index(self: &FlowsHarmonicTable, zip: &str) -> i32;
        fn score_named(
            self: &FlowsHarmonicTable,
            zip: &str,
            family: &str,
            week: i64,
        ) -> FlowsClimateOptional;
        fn score_row(
            self: &FlowsHarmonicTable,
            zip_index: i64,
            family_index: i64,
            cos_t: f64,
            sin_t: f64,
            cos_2t: f64,
            sin_2t: f64,
        ) -> f64;
    }
}

const NO_PROFILE: FlowsClimateProfile = FlowsClimateProfile {
    has: 0.0,
    band: 0,
    comfort_low_f: f64::NAN,
    comfort_high_f: f64::NAN,
    record_low_f: f64::NAN,
    record_high_f: f64::NAN,
    wind_low: f64::NAN,
    wind_medium: f64::NAN,
    wind_high: f64::NAN,
    pop_low: f64::NAN,
    pop_medium: f64::NAN,
    pop_high: f64::NAN,
};
const NONE: FlowsClimateOptional = FlowsClimateOptional {
    is_some: 0.0,
    value: f64::NAN,
};
const NO_TWILIGHT: FlowsClimateTwilight = FlowsClimateTwilight {
    has: 0.0,
    dawn: f64::NAN,
    dusk: f64::NAN,
};

fn profile(p: Option<cl::Profile>) -> FlowsClimateProfile {
    match p {
        Some(p) => FlowsClimateProfile {
            has: 1.0,
            band: p.band,
            comfort_low_f: p.comfort_low_f,
            comfort_high_f: p.comfort_high_f,
            record_low_f: p.record_low_f,
            record_high_f: p.record_high_f,
            wind_low: p.wind_low,
            wind_medium: p.wind_medium,
            wind_high: p.wind_high,
            pop_low: p.pop_low,
            pop_medium: p.pop_medium,
            pop_high: p.pop_high,
        },
        None => NO_PROFILE,
    }
}
fn optional(v: Option<f64>) -> FlowsClimateOptional {
    match v {
        Some(value) => FlowsClimateOptional {
            is_some: 1.0,
            value,
        },
        None => NONE,
    }
}
fn elevation(value: f64, has: bool) -> Option<f64> {
    has.then_some(value)
}
fn norms(n: cl::SeasonalNorms) -> FlowsClimateNorms {
    FlowsClimateNorms {
        week_low_f: n.week_low_f,
        week_high_f: n.week_high_f,
        wind_mean_mph: n.wind_mean_mph,
        wind_sigma_mph: n.wind_sigma_mph,
    }
}
fn norms_in(
    week_low_f: f64,
    week_high_f: f64,
    wind_mean_mph: f64,
    wind_sigma_mph: f64,
) -> cl::SeasonalNorms {
    cl::SeasonalNorms {
        week_low_f,
        week_high_f,
        wind_mean_mph,
        wind_sigma_mph,
    }
}

// ---- LatitudeBands ----

pub fn flows_climate_south_anchor() -> f64 {
    cl::SOUTH_ANCHOR
}
pub fn flows_climate_north_anchor() -> f64 {
    cl::NORTH_ANCHOR
}
pub fn flows_climate_pitch_degrees() -> f64 {
    cl::PITCH_DEGREES
}
pub fn flows_climate_min_latitude() -> f64 {
    cl::MIN_LATITUDE
}
pub fn flows_climate_max_latitude() -> f64 {
    cl::MAX_LATITUDE
}
pub fn flows_climate_reference_elevation_meters() -> f64 {
    cl::REFERENCE_ELEVATION_METERS
}
pub fn flows_climate_meters_per_band_step() -> f64 {
    cl::METERS_PER_BAND_STEP
}
/// The band index; absent where the Swift trapped (a NaN latitude).
pub fn flows_climate_band_index(latitude: f64) -> FlowsClimateOptional {
    contain(NONE, || {
        optional(cl::band_index(latitude).map(|b| b as f64))
    })
}
pub fn flows_climate_elevation_band_shift(elevation_meters: f64, has_elevation: bool) -> i64 {
    contain(0, || {
        cl::elevation_band_shift(elevation(elevation_meters, has_elevation))
    })
}
pub fn flows_climate_band_profile(
    latitude: f64,
    elevation_meters: f64,
    has_elevation: bool,
) -> FlowsClimateProfile {
    contain(NO_PROFILE, || {
        profile(cl::band_profile(
            latitude,
            elevation(elevation_meters, has_elevation),
        ))
    })
}

// ---- ClimateProfiles ----

pub fn flows_climate_type_names() -> Vec<String> {
    contain(Vec::new(), || {
        cl::CLIMATE_TYPE_NAMES
            .iter()
            .map(|n| n.to_string())
            .collect()
    })
}
/// The climate type's envelope; `has` 0 for a code that is not a type.
pub fn flows_climate_type_profile(code: u8) -> FlowsClimateProfile {
    contain(NO_PROFILE, || {
        profile(
            cl::CLIMATE_TYPES
                .get(usize::from(code))
                .map(|t| t.profile()),
        )
    })
}
/// Fallback: subarctic, the Swift's own answer for a NaN coordinate.
pub fn flows_climate_classify(
    latitude: f64,
    longitude: f64,
    elevation_meters: f64,
    has_elevation: bool,
) -> u8 {
    contain(cl::ClimateType::Subarctic as u8, || {
        cl::classify(
            latitude,
            longitude,
            elevation(elevation_meters, has_elevation),
        ) as u8
    })
}
pub fn flows_climate_temp_sigma_f() -> f64 {
    cl::TEMP_SIGMA_F
}
pub fn flows_climate_seasonal_norms(
    week: i64,
    latitude: f64,
    longitude: f64,
    elevation_meters: f64,
    has_elevation: bool,
) -> FlowsClimateNorms {
    contain(norms_in(f64::NAN, f64::NAN, f64::NAN, f64::NAN), || {
        cl::seasonal_norms(
            week,
            latitude,
            longitude,
            elevation(elevation_meters, has_elevation),
        )
    })
    .pipe(norms)
}
pub fn flows_climate_temperature_beyond_normal(
    temp_f: f64,
    week_low_f: f64,
    week_high_f: f64,
    wind_mean_mph: f64,
    wind_sigma_mph: f64,
) -> bool {
    contain(false, || {
        cl::temperature_beyond_normal(
            temp_f,
            &norms_in(week_low_f, week_high_f, wind_mean_mph, wind_sigma_mph),
        )
    })
}
pub fn flows_climate_wind_beyond_normal(
    wind_mph: f64,
    week_low_f: f64,
    week_high_f: f64,
    wind_mean_mph: f64,
    wind_sigma_mph: f64,
) -> bool {
    contain(false, || {
        cl::wind_beyond_normal(
            wind_mph,
            &norms_in(week_low_f, week_high_f, wind_mean_mph, wind_sigma_mph),
        )
    })
}
pub fn flows_climate_profile(
    latitude: f64,
    longitude: f64,
    elevation_meters: f64,
    has_elevation: bool,
) -> FlowsClimateProfile {
    contain(NO_PROFILE, || {
        profile(Some(cl::climate_profile(
            latitude,
            longitude,
            elevation(elevation_meters, has_elevation),
        )))
    })
}

// ---- the precise per-ZIP cells: a coordinate that cannot be placed has no
// cell, and a home that cannot be placed keeps every cell (the Swift crashed
// on both) ----

const NO_CELL: FlowsClimateCell = FlowsClimateCell { has: false, key: 0 };

pub fn flows_climate_precise_cell(latitude: f64, longitude: f64) -> FlowsClimateCell {
    contain(NO_CELL, || match cl::precise_cell(latitude, longitude) {
        Some(key) => FlowsClimateCell { has: true, key },
        None => NO_CELL,
    })
}
pub fn flows_climate_precise_cell_near_home(
    key: i64,
    home_latitude: f64,
    home_longitude: f64,
) -> bool {
    contain(true, || {
        cl::precise_cell_near_home(key, home_latitude, home_longitude).unwrap_or(true)
    })
}

// ---- DaylightClock: fallbacks NaN / no twilight / not night ----

pub fn flows_climate_civil_twilight_degrees() -> f64 {
    cl::CIVIL_TWILIGHT_DEGREES
}
pub fn flows_climate_julian_day(now: f64) -> f64 {
    contain(f64::NAN, || cl::julian_day(now))
}
pub fn flows_climate_midnight_jd(jd: f64) -> f64 {
    contain(f64::NAN, || cl::midnight_jd(jd))
}
pub fn flows_climate_solar_terms(jd: f64) -> FlowsClimateSolarTerms {
    contain(
        FlowsClimateSolarTerms {
            declination: f64::NAN,
            equation_of_time: f64::NAN,
        },
        || {
            let t = cl::solar_terms(jd);
            FlowsClimateSolarTerms {
                declination: t.declination,
                equation_of_time: t.equation_of_time,
            }
        },
    )
}
/// NaN where there is no crossing (a present answer is never NaN).
pub fn flows_climate_hour_angle_minutes(latitude: f64, declination: f64, angle: f64) -> f64 {
    contain(f64::NAN, || {
        cl::hour_angle_minutes(latitude, declination, angle).unwrap_or(f64::NAN)
    })
}
pub fn flows_climate_twilight(
    latitude: f64,
    longitude: f64,
    now: f64,
    angle: f64,
) -> FlowsClimateTwilight {
    contain(NO_TWILIGHT, || {
        match cl::twilight(latitude, longitude, now, angle) {
            Some(t) => FlowsClimateTwilight {
                has: 1.0,
                dawn: t.dawn,
                dusk: t.dusk,
            },
            None => NO_TWILIGHT,
        }
    })
}
pub fn flows_climate_is_night(latitude: f64, longitude: f64, now: f64) -> bool {
    contain(false, || cl::is_night(latitude, longitude, now))
}
pub fn flows_climate_solar_elevation(latitude: f64, longitude: f64, now: f64) -> f64 {
    contain(f64::NAN, || cl::solar_elevation(latitude, longitude, now))
}
/// Fallback: an hour out, the Swift's own answer where there is no boundary.
pub fn flows_climate_next_change(latitude: f64, longitude: f64, now: f64) -> f64 {
    contain(now + 3_600.0, || cl::next_change(latitude, longitude, now))
}

// ---- HarmonicClimatology ----

/// A parsed FLHH table, held by Swift as a handle.
pub struct FlowsHarmonicTable(cl::HarmonicTable);

impl FlowsHarmonicTable {
    /// The table itself, for the other bridge modules that read it.
    pub(crate) fn inner(&self) -> &cl::HarmonicTable {
        &self.0
    }
}

pub fn flows_climate_score_max() -> f64 {
    cl::SCORE_MAX
}
pub fn flows_climate_week_trig(week: i64) -> FlowsClimateWeekTrig {
    contain(
        FlowsClimateWeekTrig {
            cos_t: f64::NAN,
            sin_t: f64::NAN,
            cos_2t: f64::NAN,
            sin_2t: f64::NAN,
        },
        || {
            let t = cl::WeekTrig::new(week);
            FlowsClimateWeekTrig {
                cos_t: t.cos_t,
                sin_t: t.sin_t,
                cos_2t: t.cos_2t,
                sin_2t: t.sin_2t,
            }
        },
    )
}
/// `None` on any structural mismatch, as the Swift's failable initialiser.
pub fn flows_climate_parse_flhh(data: &[u8]) -> Option<FlowsHarmonicTable> {
    contain(None, || cl::parse_flhh(data).map(FlowsHarmonicTable))
}
impl FlowsHarmonicTable {
    pub fn families(&self) -> Vec<String> {
        contain(Vec::new(), || self.0.families().to_vec())
    }
    pub fn zips(&self) -> Vec<String> {
        contain(Vec::new(), || self.0.zips().to_vec())
    }
    pub fn family_count(&self) -> u32 {
        contain(0, || {
            u32::try_from(self.0.family_count()).unwrap_or(u32::MAX)
        })
    }
    /// The row of a ZIP, -1 for none.
    pub fn zip_index(&self, zip: &str) -> i32 {
        contain(-1, || {
            self.0
                .zip_index(zip)
                .and_then(|i| i32::try_from(i).ok())
                .unwrap_or(-1)
        })
    }
    pub fn score_named(&self, zip: &str, family: &str, week: i64) -> FlowsClimateOptional {
        contain(NONE, || optional(self.0.score_named(zip, family, week)))
    }
    /// The score for a row and family with the week's trig factors; NaN where
    /// the Swift trapped (a row or family past the table).
    #[allow(clippy::too_many_arguments)]
    pub fn score_row(
        &self,
        zip_index: i64,
        family_index: i64,
        cos_t: f64,
        sin_t: f64,
        cos_2t: f64,
        sin_2t: f64,
    ) -> f64 {
        contain(f64::NAN, || {
            let trig = cl::WeekTrig {
                cos_t,
                sin_t,
                cos_2t,
                sin_2t,
            };
            self.0
                .score(zip_index, family_index, &trig)
                .unwrap_or(f64::NAN)
        })
    }
}

// ---- RiskTiming ----

/// Fallback true: an alert whose timing cannot be judged is never discounted.
pub fn flows_climate_is_active(
    expires: f64,
    has_expires: bool,
    arrival_offset: f64,
    now: f64,
) -> bool {
    contain(true, || {
        cl::is_active(has_expires.then_some(expires), arrival_offset, now)
    })
}
pub fn flows_climate_max_arrival_samples() -> i64 {
    cl::MAX_ARRIVAL_SAMPLES
}
/// Empty for a refused count (above the maximum), as for none.
pub fn flows_climate_arrival_offsets(sample_count: i64, total_travel_seconds: f64) -> Vec<f64> {
    contain(Vec::new(), || {
        cl::arrival_offsets(sample_count, total_travel_seconds).unwrap_or_default()
    })
}

/// A small pipe so a contained value can be re-encoded in one expression.
trait Pipe: Sized {
    fn pipe<U>(self, f: impl FnOnce(Self) -> U) -> U {
        f(self)
    }
}
impl<T> Pipe for T {}
