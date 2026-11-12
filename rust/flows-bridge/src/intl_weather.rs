// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::intl_weather`, behind Swift's
//! `IntlWeatherParsing`. Implementations live in `flows-core`; this file
//! only crosses.
//!
//! - A number that may be missing crosses as a value and a flag (`1` for
//!   present); an answer that may be missing comes back as `[has, value]`,
//!   `has` 1 or 0, and the SMN row's as `[has, °F, has, mph]`.
//! - A station's fields cross as columns of one count: the names (NFC) and
//!   the units joined by their UTF-8 lengths, the speeds, and a flag each
//!   for a speed and a unit that is there.
//!
//! A count the columns do not hold, or a panic inside, answers "no
//! reading". swift-bridge must never see an empty buffer, so Swift answers
//! a station with no fields itself and never crosses with one.

#![allow(clippy::too_many_arguments)] // flattened Swift signatures

use crate::{contain, split_texts};
use flows_core::intl_weather as iw;

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_intl_celsius_to_f(c: f64) -> f64;
        fn flows_intl_kmh_to_mph(kmh: f64) -> f64;
        fn flows_intl_ms_to_mph(ms: f64) -> f64;
        fn flows_intl_air_temp_f(values: &[f64], present: &[u8], count: i64) -> Vec<f64>;
        fn flows_intl_wind_mph(
            keys_joined: &str,
            key_lens: &[i64],
            speeds: &[f64],
            speed_present: &[u8],
            units_joined: &str,
            unit_lens: &[i64],
            unit_present: &[u8],
            count: i64,
        ) -> Vec<f64>;
        fn flows_intl_smn_conditions(
            high_c: f64,
            has_high: bool,
            low_c: f64,
            has_low: bool,
            wind_kmh: f64,
            has_wind: bool,
        ) -> Vec<f64>;
    }
}

const NO_READING: [f64; 2] = [0.0, 0.0];

fn answer(v: Option<f64>) -> Vec<f64> {
    v.map_or_else(|| NO_READING.to_vec(), |v| vec![1.0, v])
}

fn present(flags: &[u8], i: usize) -> bool {
    flags.get(i).is_some_and(|f| *f != 0)
}

/// The first `count` entries, when every column holds them.
fn count_in(count: i64, lens: &[usize]) -> Option<usize> {
    let n = usize::try_from(count).ok()?;
    lens.iter().all(|l| *l >= n).then_some(n)
}

pub fn flows_intl_celsius_to_f(c: f64) -> f64 {
    iw::celsius_to_f(c)
}

pub fn flows_intl_kmh_to_mph(kmh: f64) -> f64 {
    iw::kmh_to_mph(kmh)
}

pub fn flows_intl_ms_to_mph(ms: f64) -> f64 {
    iw::ms_to_mph(ms)
}

pub fn flows_intl_air_temp_f(values: &[f64], present_flags: &[u8], count: i64) -> Vec<f64> {
    contain(NO_READING.to_vec(), || {
        let Some(n) = count_in(count, &[values.len(), present_flags.len()]) else {
            return NO_READING.to_vec();
        };
        let candidates: Vec<Option<f64>> = (0..n)
            .map(|i| present(present_flags, i).then_some(values[i]))
            .collect();
        answer(iw::air_temp_f(&candidates))
    })
}

pub fn flows_intl_wind_mph(
    keys_joined: &str,
    key_lens: &[i64],
    speeds: &[f64],
    speed_present: &[u8],
    units_joined: &str,
    unit_lens: &[i64],
    unit_present: &[u8],
    count: i64,
) -> Vec<f64> {
    contain(NO_READING.to_vec(), || {
        let Some(n) = count_in(
            count,
            &[
                key_lens.len(),
                speeds.len(),
                speed_present.len(),
                unit_lens.len(),
                unit_present.len(),
            ],
        ) else {
            return NO_READING.to_vec();
        };
        let (Some(keys), Some(units)) = (
            split_texts(keys_joined, key_lens, n),
            split_texts(units_joined, unit_lens, n),
        ) else {
            return NO_READING.to_vec();
        };
        let fields: Vec<iw::WindField<'_>> = (0..n)
            .map(|i| iw::WindField {
                key: keys[i],
                speed: present(speed_present, i).then_some(speeds[i]),
                unit: present(unit_present, i).then_some(units[i]),
            })
            .collect();
        answer(iw::wind_mph(&fields))
    })
}

pub fn flows_intl_smn_conditions(
    high_c: f64,
    has_high: bool,
    low_c: f64,
    has_low: bool,
    wind_kmh: f64,
    has_wind: bool,
) -> Vec<f64> {
    contain(vec![0.0; 4], || {
        let (t, w) = iw::smn_conditions(
            has_high.then_some(high_c),
            has_low.then_some(low_c),
            has_wind.then_some(wind_kmh),
        );
        let mut out = answer(t);
        out.extend(answer(w));
        out
    })
}
