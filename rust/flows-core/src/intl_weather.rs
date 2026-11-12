// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The international weather providers' rules: Swift's `IntlWeatherParsing`
//! before its rules moved here. Canada's SWOB observations name their
//! anemometer fields by station, so which field speaks for the wind, and in
//! which unit, is a rule; so is Mexico's daily row standing in for current
//! conditions. Fetching, the gzip body and the JSON stay in Swift, which
//! reads each field as a number its own way (`as? Double`, else a `String`
//! through `Double(_:)`) and hands over the numbers.
//!
//! Text follows Swift's own rules through [`crate::swift_text`]. A key
//! arrives in its NFC spelling, so ordering its UTF-8 bytes is Swift's `<`
//! (where Swift's `<` gives an order at all: for "wnd_spd_o\u{308}" and
//! "wnd_spd_\u{F6}z" it says neither is less, so the original's pick there
//! followed the dictionary's run-to-run order; here the bytes decide).
//! Pinned by `flows-bridge/tests/fixtures/swift_intl_weather_oracle.tsv`.

use crate::swift_text;

/// Degrees Fahrenheit for degrees Celsius, in the Swift's operation order.
#[must_use]
pub fn celsius_to_f(c: f64) -> f64 {
    c * 9.0 / 5.0 + 32.0
}

/// Miles an hour for kilometres an hour.
#[must_use]
pub fn kmh_to_mph(kmh: f64) -> f64 {
    kmh / 1.609_344
}

/// Miles an hour for metres a second.
#[must_use]
pub fn ms_to_mph(ms: f64) -> f64 {
    ms * 2.236_936_292_054_4
}

/// `ecccAirTempF`: the first air-temperature field that reads as a number,
/// in Fahrenheit. `candidates` are the station's fields in the order Swift
/// asks for them (`air_temp`, `air_temp_1`, `avg_air_temp_pst1hr`); a field
/// that read as a number counts even when it is not finite.
#[must_use]
pub fn air_temp_f(candidates: &[Option<f64>]) -> Option<f64> {
    candidates.iter().find_map(|c| *c).map(celsius_to_f)
}

/// One field of a SWOB observation, as the wind rule sees it.
#[derive(Debug, Clone, Copy)]
pub struct WindField<'a> {
    /// The field's name, in NFC.
    pub key: &'a str,
    /// The field's value read as a number; `None` when it did not read.
    pub speed: Option<f64>,
    /// The field's sibling `<key>-uom` when that is text.
    pub unit: Option<&'a str>,
}

/// Whether a field names a wind speed: its lowercased name holds `wnd_spd`,
/// and the name itself holds none of `-uom`, `-qa` and `flag`.
#[must_use]
pub fn is_wind_key(key: &str) -> bool {
    swift_text::contains(&swift_text::lowercased(key), "wnd_spd")
        && !swift_text::contains(key, "-uom")
        && !swift_text::contains(key, "-qa")
        && !swift_text::contains(key, "flag")
}

/// `ecccWindMph`: the wind in miles an hour from the first wind field, 10 m
/// tower sensors before the rest and then by name, that holds a speed of at
/// least zero. Its unit is metres a second when the lowercased unit holds
/// `m/s`, otherwise kilometres an hour (also when there is no unit).
#[must_use]
pub fn wind_mph(fields: &[WindField<'_>]) -> Option<f64> {
    let mut wind: Vec<(bool, &WindField<'_>)> = fields
        .iter()
        .filter(|f| is_wind_key(f.key))
        .map(|f| (swift_text::contains(f.key, "10m"), f))
        .collect();
    // Tower sensors first (true before false), then by name.
    wind.sort_by(|(a_ten, a), (b_ten, b)| {
        b_ten
            .cmp(a_ten)
            .then_with(|| a.key.as_bytes().cmp(b.key.as_bytes()))
    });
    wind.into_iter().find_map(|(_, f)| {
        let v = f.speed.filter(|v| *v >= 0.0)?;
        let metres = f
            .unit
            .is_some_and(|u| swift_text::contains(&swift_text::lowercased(u), "m/s"));
        Some(if metres { ms_to_mph(v) } else { kmh_to_mph(v) })
    })
}

/// `conditions(from:)`'s numbers for an SMN daily row: the temperature in
/// Fahrenheit (the midpoint of the high and the low, or whichever is there)
/// and the wind in miles an hour.
#[must_use]
pub fn smn_conditions(
    high_c: Option<f64>,
    low_c: Option<f64>,
    wind_kmh: Option<f64>,
) -> (Option<f64>, Option<f64>) {
    let temperature = match (high_c, low_c) {
        (Some(hi), Some(lo)) => Some(celsius_to_f((hi + lo) / 2.0)),
        (Some(hi), None) => Some(celsius_to_f(hi)),
        (None, Some(lo)) => Some(celsius_to_f(lo)),
        (None, None) => None,
    };
    (temperature, wind_kmh.map(kmh_to_mph))
}
