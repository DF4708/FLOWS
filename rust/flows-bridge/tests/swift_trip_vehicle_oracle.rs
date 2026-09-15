// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for trip and vehicle: every line of the fixture is
//! an input and the output the ORIGINAL Swift produced for it (commit
//! a007de0), before the Swift was replaced by calls into Rust. Every function
//! is called through the bridge exactly as its Swift facade calls it, and
//! compared BIT FOR BIT.
//!
//! The fixture is never regenerated from Rust. To extend it, check out the
//! commit named in its header and rerun the harness in
//! `oracle-harness/trip_vehicle`.

use flows_bridge::trip_vehicle::*;
use flows_core::trip_vehicle as tv;
use std::collections::HashMap;

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn u(h: &str) -> u64 {
    u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex u64 {h}"))
}
fn opt(h: &str) -> Option<f64> {
    (h != "-").then(|| d(h))
}
fn s(h: &str) -> String {
    let hex = h
        .strip_prefix("s:")
        .unwrap_or_else(|| panic!("bad string field {h}"));
    let bytes: Vec<u8> = (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).expect("hex byte"))
        .collect();
    String::from_utf8(bytes).expect("oracle strings are UTF-8")
}
fn list(f: &str) -> Vec<&str> {
    let (head, body) = f.split_once(':').expect("list header");
    let n: usize = head.trim_start_matches('L').parse().expect("list count");
    if n == 0 {
        return Vec::new();
    }
    let v: Vec<&str> = body.split(',').collect();
    assert_eq!(v.len(), n, "list count mismatch");
    v
}
fn bits(x: f64) -> String {
    format!("{:x}", x.to_bits())
}
fn obits(x: Option<f64>) -> String {
    x.map_or_else(|| "-".to_string(), bits)
}
fn bit(b: bool) -> &'static str {
    if b {
        "1"
    } else {
        "0"
    }
}
fn same(got: f64, want: &str) -> bool {
    got.to_bits() == d(want).to_bits()
}
fn same_opt(got: Option<f64>, want: &str) -> bool {
    got.map(f64::to_bits) == opt(want).map(f64::to_bits)
}
fn decode_optional(r: &impl OptionalLike) -> Option<f64> {
    r.get()
}
trait OptionalLike {
    fn get(&self) -> Option<f64>;
}
impl OptionalLike for TripVehicleOptionalView {
    fn get(&self) -> Option<f64> {
        (self.0 != 0.0).then_some(self.1)
    }
}
struct TripVehicleOptionalView(f64, f64);

fn fuel_cost(m: f64, mpu: f64, p: f64) -> Option<f64> {
    let r = flows_trip_vehicle_drive_fuel_cost_usd(m, mpu, p);
    decode_optional(&TripVehicleOptionalView(r.is_some, r.value))
}
fn co2_mile(code: u8, mpu: f64) -> Option<f64> {
    let r = flows_trip_vehicle_drive_grams_co2_per_mile(code, mpu);
    decode_optional(&TripVehicleOptionalView(r.is_some, r.value))
}

/// A saved profile as the Swift facade passes it: values plus presence flags.
#[derive(Clone, Copy)]
struct Profile {
    tank: f64,
    rated: f64,
    city: Option<f64>,
    highway: Option<f64>,
}
impl Profile {
    fn args(&self) -> (f64, f64, f64, bool, f64, bool) {
        (
            self.tank,
            self.rated,
            self.city.unwrap_or(0.0),
            self.city.is_some(),
            self.highway.unwrap_or(0.0),
            self.highway.is_some(),
        )
    }
}

fn ranges_contain(ranges: &[(u32, u32)], v: u32) -> bool {
    ranges.iter().any(|&(a, b)| a <= v && v <= b)
}
fn parse_ranges(f: &str) -> Vec<(u32, u32)> {
    list(f)
        .into_iter()
        .map(|r| {
            let (a, b) = r.split_once('-').expect("range");
            (
                u32::try_from(u(a)).expect("scalar"),
                u32::try_from(u(b)).expect("scalar"),
            )
        })
        .collect()
}
/// Scalars where a Rust predicate disagrees with the Swift sweep.
fn sweep_diffs(f: &str, pred: impl Fn(char) -> bool) -> Vec<u32> {
    let r = parse_ranges(f);
    (0..=0x10_FFFFu32)
        .filter_map(char::from_u32)
        .filter(|&c| pred(c) != ranges_contain(&r, u32::from(c)))
        .map(u32::from)
        .collect()
}

/// Records where Rust deliberately does not reproduce the Swift original,
/// each with its reason. Every entry must still diverge: a fixed divergence
/// fails the test until its entry is removed, so this list cannot rot.
///
/// All four are the crash check-in's word split (`CrashLogic.interpretReply`)
/// on a grapheme join the port does not model, each glued to an English
/// vocabulary word with no space or punctuation. A speech transcript does not
/// produce them. Phrase matching and the EPA class ladder have no divergence.
const GRAPHEME_JOIN_NOT_MODELLED: &str =
    "Swift segments Characters with every grapheme-break rule; the port models the \
     ones that can touch an ASCII word (Extend, ZWJ, SpacingMark, Prepend, Control) \
     but not GB6-8 (Hangul syllables), GB9c (Indic conjuncts) or GB11 (emoji ZWJ \
     sequences). Those joins only change a word when they pull a letter into a \
     cluster that starts with a non-letter (or the reverse), which needs a Prepend \
     scalar or a letter-like pictograph (U+2139, U+24C2) directly before the word. \
     Exact parity needs Unicode-version-dependent InCB and Extended_Pictographic \
     tables. Pinned in trip_vehicle.rs's module docs.";
const KNOWN_DIVERGENCES: &[(&str, &str)] = &[
    // "ℹ\u{200D}©no": Swift joins ℹ ZWJ © into one letter cluster (GB11), so the
    // word is "ℹ‍©no" and nothing matches; the port splits at ©, finds "no".
    (
        "reply\ts:e284b9e2808dc2a96e6f\t-",
        GRAPHEME_JOIN_NOT_MODELLED,
    ),
    // "©\u{200D}ℹno": Swift's cluster starts with ©, a separator that swallows ℹ,
    // so "no" matches; the port keeps ℹ as a letter and reads "ℹno".
    (
        "reply\ts:c2a9e2808de284b96e6f\t0",
        GRAPHEME_JOIN_NOT_MODELLED,
    ),
    // "\u{600}\u{1100}\u{1161}no": U+0600 prepends to the Hangul L, and Swift
    // also joins the V (GB7), so the separator swallows both; the port keeps V.
    (
        "reply\ts:d880e18480e185a16e6f\t0",
        GRAPHEME_JOIN_NOT_MODELLED,
    ),
    // "\u{600}\u{915}\u{94D}\u{937}no": the same, with the conjunct's second
    // consonant joined by GB9c.
    (
        "reply\ts:d880e0a495e0a58de0a4b76e6f\t0",
        GRAPHEME_JOIN_NOT_MODELLED,
    ),
];

#[test]
fn rust_reproduces_the_original_swift_bit_for_bit() {
    let text = include_str!("fixtures/swift_trip_vehicle_oracle.tsv");
    let lines: Vec<&str> = text
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
        .collect();
    let towing_factor = lines
        .iter()
        .find_map(|l| l.strip_prefix("towingEconomyFactor\t"))
        .map(d)
        .expect("the fixture records TowingLimits.towingEconomyFactor");

    let mut failures: Vec<(String, String)> = Vec::new();
    let mut fail = |line: &str, got: String, want: String| {
        failures.push((
            line.to_string(),
            format!("\n    got  {got}\n    want {want}"),
        ));
    };
    let mut checked = 0usize;
    let mut spec_rows = 0usize;
    let spec_makes = flows_trip_vehicle_spec_makes();
    let spec_models = flows_trip_vehicle_spec_models();
    let spec_numbers = flows_trip_vehicle_spec_numbers();
    let slots = flows_trip_vehicle_spec_number_slots() as usize;
    let mut last_schedule: Vec<f64> = Vec::new();
    let mut windows: HashMap<usize, Vec<f64>> = HashMap::new();
    let mut profiles: HashMap<usize, Profile> = HashMap::new();
    let mut seq_profile: Option<Profile> = None;
    let mut habits = (0.0f64, 0.0f64, 0.0f64);

    for &line in &lines {
        let f: Vec<&str> = line.split('\t').collect();
        checked += 1;
        match f[0] {
            "table" => {
                let got: Vec<String> = match f[1] {
                    "fuelTypes" => flows_trip_vehicle_fuel_type_names(),
                    "foodCategories" => flows_trip_vehicle_food_category_names(),
                    "assistWords" => flows_trip_vehicle_assist_words(),
                    "okWords" => flows_trip_vehicle_ok_words(),
                    "needLabels" => {
                        for item in list(f[2]) {
                            let (code, label) = item.split_once('=').expect("code=label");
                            let code: u8 = code.parse().expect("need code");
                            let got = flows_trip_vehicle_need_label(code);
                            if got != s(label) {
                                fail(line, format!("{code}: {got:?}"), s(label));
                            }
                        }
                        continue;
                    }
                    other => panic!("unknown table {other}"),
                };
                let want: Vec<String> = list(f[2]).into_iter().map(s).collect();
                if got != want {
                    fail(line, format!("{got:?}"), format!("{want:?}"));
                }
            }
            "const" => {
                let got = match f[1] {
                    "impactGForce" => flows_trip_vehicle_impact_g_force(),
                    "hardImpactGForce" => flows_trip_vehicle_hard_impact_g_force(),
                    "confirmImpactGForce" => flows_trip_vehicle_confirm_impact_g_force(),
                    "minPreImpactSpeedMps" => flows_trip_vehicle_min_pre_impact_speed_mps(),
                    "crashStopSpeedMps" => flows_trip_vehicle_crash_stop_speed_mps(),
                    "minSpeedDropFraction" => flows_trip_vehicle_min_speed_drop_fraction(),
                    "maxMetersFromRoad" => flows_trip_vehicle_max_meters_from_road(),
                    "breakDueSeconds" => flows_trip_vehicle_hos_break_due_seconds(),
                    "warnBeforeBreakSeconds" => flows_trip_vehicle_hos_warn_before_break_seconds(),
                    "dailyDrivingLimitSeconds" => {
                        flows_trip_vehicle_hos_daily_driving_limit_seconds()
                    }
                    "breakResetSeconds" => flows_trip_vehicle_hos_break_reset_seconds(),
                    "reserveMiles" => flows_trip_vehicle_reserve_miles(),
                    "defaultMilesPerUnit" => flows_trip_vehicle_default_miles_per_unit(),
                    "minimumHeightFeet" => flows_trip_vehicle_minimum_height_feet(),
                    other => panic!("unknown const {other}"),
                };
                if !same(got, f[2]) {
                    fail(line, bits(got), f[2].into());
                }
            }
            "defaultFuel" => {
                let got = flows_trip_vehicle_default_fuel_code();
                if got.to_string() != f[1] {
                    fail(line, got.to_string(), f[1].into());
                }
            }
            "towingEconomyFactor" => {}
            "spec" => {
                spec_rows += 1;
                let i: usize = f[1].parse().expect("row");
                let row_numbers = spec_numbers.get(i * slots..(i + 1) * slots);
                let want_numbers: Vec<Option<f64>> =
                    std::iter::once(Some(f64::from(f[4].parse::<u8>().expect("fuel code"))))
                        .chain(f[5..9].iter().map(|h| Some(d(h))))
                        .chain(f[9..14].iter().map(|h| opt(h)))
                        .collect();
                let got_numbers: Option<Vec<Option<f64>>> =
                    row_numbers.map(|r| r.iter().map(|&x| (!x.is_nan()).then_some(x)).collect());
                let numbers_ok = got_numbers.as_ref().is_some_and(|g| {
                    g.iter()
                        .zip(&want_numbers)
                        .all(|(a, b)| a.map(f64::to_bits) == b.map(f64::to_bits))
                });
                let names_ok = spec_makes.get(i).map(String::as_str) == Some(s(f[2]).as_str())
                    && spec_models.get(i).map(String::as_str) == Some(s(f[3]).as_str());
                let (city, hwy) = (d(f[5]), d(f[6]));
                let combined = flows_trip_vehicle_combined_miles_per_unit(city, hwy);
                let rated = flows_trip_vehicle_rated_miles_per_unit(city, hwy);
                if !(numbers_ok && names_ok && same(combined, f[14]) && same(rated, f[15])) {
                    fail(
                        line,
                        format!(
                            "{:?} {:?} {got_numbers:?} {} {}",
                            spec_makes.get(i),
                            spec_models.get(i),
                            bits(combined),
                            bits(rated)
                        ),
                        format!("{want_numbers:?}"),
                    );
                }
            }
            "makes" => {
                let want: Vec<String> = list(f[1]).into_iter().map(s).collect();
                let got = flows_trip_vehicle_distinct_makes();
                if got != want {
                    fail(line, format!("{got:?}"), format!("{want:?}"));
                }
            }
            "models" => {
                let want: Vec<String> = list(f[2]).into_iter().map(String::from).collect();
                let got: Vec<String> = flows_trip_vehicle_spec_rows_for_make(&s(f[1]))
                    .iter()
                    .map(|x| format!("{x}"))
                    .collect();
                if got != want {
                    fail(line, format!("{got:?}"), format!("{want:?}"));
                }
            }
            "lookup" => {
                let got = flows_trip_vehicle_spec_index(&s(f[1]), &s(f[2]));
                let got = if got < 0 {
                    "-".to_string()
                } else {
                    got.to_string()
                };
                if got != f[3] {
                    fail(line, got, f[3].into());
                }
            }
            "combined" => {
                let (c, h) = (d(f[1]), d(f[2]));
                let combined = flows_trip_vehicle_combined_miles_per_unit(c, h);
                let rated = flows_trip_vehicle_rated_miles_per_unit(c, h);
                if !(same(combined, f[3]) && same(rated, f[4])) {
                    fail(
                        line,
                        format!("{} {}", bits(combined), bits(rated)),
                        format!("{} {}", f[3], f[4]),
                    );
                }
            }
            "co2unit" => {
                let g = flows_trip_vehicle_grams_co2_per_unit(f[1].parse().expect("code"));
                if !same(g, f[2]) {
                    fail(line, bits(g), f[2].into());
                }
            }
            "transit" => {
                let g = flows_trip_vehicle_transit_grams_co2_per_mile(f[1] == "1", f[2] == "1");
                if !same(g, f[3]) {
                    fail(line, bits(g), f[3].into());
                }
            }
            "fuelcost" => {
                let g = fuel_cost(d(f[1]), d(f[2]), d(f[3]));
                if !same_opt(g, f[4]) {
                    fail(line, obits(g), f[4].into());
                }
            }
            "co2mile" => {
                let g = co2_mile(f[1].parse().expect("code"), d(f[2]));
                if !same_opt(g, f[3]) {
                    fail(line, obits(g), f[3].into());
                }
            }
            "smix" => {
                let mut state = flows_trip_vehicle_splitmix64_initial_state(u(f[1]));
                let got: Vec<String> = (0..list(f[2]).len())
                    .map(|_| {
                        state = flows_trip_vehicle_splitmix64_advance(state);
                        format!("{:x}", flows_trip_vehicle_splitmix64_mix(state))
                    })
                    .collect();
                let want: Vec<String> = list(f[2]).into_iter().map(String::from).collect();
                if got != want {
                    fail(line, format!("{got:?}"), format!("{want:?}"));
                }
            }
            "sched" => {
                // The facade's encoding: nil cadence is NaN.
                let intervals: Vec<f64> = list(f[2])
                    .into_iter()
                    .map(|h| opt(h).unwrap_or(f64::NAN))
                    .collect();
                let flat = flows_trip_vehicle_schedule(d(f[1]), &intervals, u(f[3]));
                let want_miles: Vec<u64> = list(f[4]).into_iter().map(|h| d(h).to_bits()).collect();
                let want_codes: Vec<String> = list(f[5]).into_iter().map(String::from).collect();
                let got_miles: Vec<u64> = flat.chunks(2).map(|c| c[0].to_bits()).collect();
                let got_codes: Vec<String> = flat.chunks(2).map(|c| format!("{}", c[1])).collect();
                if got_miles != want_miles || got_codes != want_codes {
                    fail(
                        line,
                        format!("{} stops {got_codes:?}", got_miles.len()),
                        format!("{} stops {want_codes:?}", want_miles.len()),
                    );
                }
                last_schedule = flat.chunks(2).map(|c| c[0]).collect();
            }
            "next" => {
                // The facade answers nil for an empty schedule without crossing.
                let got = if last_schedule.is_empty() {
                    -1
                } else {
                    flows_trip_vehicle_next_need_index(d(f[1]), &last_schedule)
                };
                let got = if got < 0 {
                    "-".to_string()
                } else {
                    got.to_string()
                };
                if got != f[2] {
                    fail(line, got, f[2].into());
                }
            }
            "adj" => {
                let g = flows_trip_vehicle_adjusted_remaining_seconds(d(f[1]), d(f[2]));
                if !same(g, f[3]) {
                    fail(line, bits(g), f[3].into());
                }
            }
            "impg" => {
                let g = flows_trip_vehicle_is_impact_acceleration(d(f[1]));
                if bit(g) != f[2] {
                    fail(line, bit(g).into(), f[2].into());
                }
            }
            "win" => {
                windows.insert(
                    f[1].parse().expect("window id"),
                    list(f[2]).into_iter().map(d).collect(),
                );
            }
            "impw" => {
                let w = &windows[&f[1].parse::<usize>().expect("window id")];
                let g = !w.is_empty() && flows_trip_vehicle_is_impact_window(w);
                if bit(g) != f[2] {
                    fail(line, bit(g).into(), f[2].into());
                }
            }
            "crash" => {
                let w = &windows[&f[1].parse::<usize>().expect("window id")];
                let m = opt(f[4]);
                let g = !w.is_empty()
                    && flows_trip_vehicle_is_crash(
                        w,
                        d(f[2]),
                        d(f[3]),
                        m.unwrap_or(0.0),
                        m.is_some(),
                    );
                if bit(g) != f[5] {
                    fail(line, bit(g).into(), f[5].into());
                }
            }
            "reply" => {
                let g = match flows_trip_vehicle_interpret_reply(&s(f[1])) {
                    1 => "1",
                    0 => "0",
                    _ => "-",
                };
                if g != f[2] {
                    fail(line, format!("{g} for {:?}", s(f[1])), f[2].into());
                }
            }
            "hos" => {
                let r = flows_trip_vehicle_hos_status(d(f[1]));
                let code = format!("{}", r.code);
                let seconds_ok = f[2] != "1" || same(r.seconds_until_due, f[3]);
                if code != f[2] || !seconds_ok {
                    fail(
                        line,
                        format!("{code} {}", bits(r.seconds_until_due)),
                        format!("{} {}", f[2], f[3]),
                    );
                }
            }
            "eff" => {
                let g = flows_trip_vehicle_efficiency_factor(d(f[1]), d(f[2]));
                if !same(g, f[3]) {
                    fail(line, bits(g), f[3].into());
                }
            }
            "vprof" => {
                profiles.insert(
                    f[1].parse().expect("profile id"),
                    Profile {
                        tank: d(f[2]),
                        rated: d(f[3]),
                        city: opt(f[4]),
                        highway: opt(f[5]),
                    },
                );
            }
            "rrange" | "mpu" | "erange" | "frac" | "xrange" => {
                let p = profiles[&f[1].parse::<usize>().expect("profile id")];
                let (t, r, c, hc, h, hh) = p.args();
                let (g, want) = match f[0] {
                    "rrange" => (flows_trip_vehicle_rated_range_miles(t, r), f[2]),
                    "mpu" => (
                        flows_trip_vehicle_miles_per_unit_at_speed(t, r, c, hc, h, hh, d(f[2])),
                        f[3],
                    ),
                    "erange" => (
                        flows_trip_vehicle_effective_range_miles(
                            t,
                            r,
                            c,
                            hc,
                            h,
                            hh,
                            d(f[2]),
                            d(f[3]),
                        ),
                        f[4],
                    ),
                    "frac" => (
                        flows_trip_vehicle_fuel_fraction_after(
                            t,
                            r,
                            c,
                            hc,
                            h,
                            hh,
                            d(f[2]),
                            d(f[3]),
                            d(f[4]),
                        ),
                        f[5],
                    ),
                    _ => (
                        flows_trip_vehicle_expected_range_miles(
                            t,
                            r,
                            c,
                            hc,
                            h,
                            hh,
                            d(f[2]),
                            d(f[3]),
                            d(f[4]),
                        ),
                        f[5],
                    ),
                };
                if !same(g, want) {
                    fail(line, bits(g), want.into());
                }
            }
            "recfuel" => {
                // "-" is Swift's default argument, VehicleProfile.reserveMiles.
                let reserve = opt(f[3]).unwrap_or_else(flows_trip_vehicle_reserve_miles);
                let g = flows_trip_vehicle_should_recommend_fuel(d(f[1]), d(f[2]), reserve);
                if bit(g) != f[4] {
                    fail(line, bit(g).into(), f[4].into());
                }
            }
            "restore" => {
                // VehicleStore starts at 55 mph and no idling (Swift keeps those).
                let (a, i) = (d(f[1]), d(f[2]));
                let (avg, idle) = if flows_trip_vehicle_restore_driving_accepts(a, i) {
                    (a, flows_trip_vehicle_restore_driving_idle(i))
                } else {
                    (55.0, 0.0)
                };
                if !(same(avg, f[3]) && same(idle, f[4])) {
                    fail(
                        line,
                        format!("{} {}", bits(avg), bits(idle)),
                        format!("{} {}", f[3], f[4]),
                    );
                }
            }
            "fseq" => {
                seq_profile =
                    opt(f[2]).map(|_| profiles[&f[2].parse::<usize>().expect("profile id")]);
                habits = (0.0, d(f[3]), d(f[4]));
            }
            "fix" => {
                let towing = f[4] == "1";
                let r = flows_trip_vehicle_record_fix(
                    habits.0,
                    habits.1,
                    habits.2,
                    d(f[2]),
                    d(f[3]),
                    towing,
                    towing_factor,
                );
                habits = (r.miles_since_fill, r.average_speed_mph, r.idle_fraction);
                let tele = opt(f[5]);
                let (xr, pf) = match seq_profile {
                    None => (None, None),
                    Some(p) => {
                        let (t, rt, c, hc, h, hh) = p.args();
                        (
                            Some(flows_trip_vehicle_store_expected_range_miles(
                                t,
                                rt,
                                c,
                                hc,
                                h,
                                hh,
                                habits.0,
                                habits.1,
                                habits.2,
                                tele.unwrap_or(0.0),
                                tele.is_some(),
                                towing,
                                towing_factor,
                            )),
                            Some(flows_trip_vehicle_fuel_fraction_after(
                                t, rt, c, hc, h, hh, habits.0, habits.1, habits.2,
                            )),
                        )
                    }
                };
                let ok = same(habits.0, f[6])
                    && same(habits.1, f[7])
                    && same(habits.2, f[8])
                    && same_opt(xr, f[9])
                    && same_opt(pf, f[10]);
                if !ok {
                    fail(
                        line,
                        format!(
                            "{} {} {} {} {}",
                            bits(habits.0),
                            bits(habits.1),
                            bits(habits.2),
                            obits(xr),
                            obits(pf)
                        ),
                        f[6..].join(" "),
                    );
                }
            }
            "phys" => {
                let p = flows_trip_vehicle_epa_class_physical(&s(f[1]));
                let nil = |x: f64| (!x.is_nan()).then_some(x);
                if !(same(p.tank, f[2])
                    && same(p.height, f[3])
                    && same_opt(nil(p.gvwr), f[4])
                    && same_opt(nil(p.tow_capacity), f[5]))
                {
                    fail(
                        line,
                        format!(
                            "{} {} {} {}",
                            bits(p.tank),
                            bits(p.height),
                            bits(p.gvwr),
                            bits(p.tow_capacity)
                        ),
                        f[2..].join(" "),
                    );
                }
            }
            "vtank" => {
                let g = flows_trip_vehicle_epa_validated_tank(d(f[1]), d(f[2]));
                if !same(g, f[3]) {
                    fail(line, bits(g), f[3].into());
                }
            }
            "epafuel" => {
                let g = flows_trip_vehicle_epa_fuel_type_code(&s(f[1]));
                if g.to_string() != f[2] {
                    fail(line, g.to_string(), f[2].into());
                }
            }
            "ualpha" | "uattach" | "uprepend" | "ucontrol" => {
                let pred: fn(char) -> bool = match f[0] {
                    "ualpha" => tv::swift_is_letter,
                    "uattach" => tv::grapheme_attaches_to_previous,
                    "uprepend" => tv::grapheme_prepends,
                    _ => tv::grapheme_breaks_both_sides,
                };
                let diffs = sweep_diffs(f[1], pred);
                if !diffs.is_empty() {
                    fail(
                        f[0],
                        format!(
                            "{} scalars differ, first {:x?}",
                            diffs.len(),
                            &diffs[..diffs.len().min(12)]
                        ),
                        "none".into(),
                    );
                }
            }
            "ulower" => {
                let mut swift: HashMap<u32, String> = HashMap::new();
                for e in list(f[1]) {
                    let (from, to) = e.split_once('>').expect("mapping");
                    let mapped: String = to
                        .split('+')
                        .map(|x| {
                            char::from_u32(u32::try_from(u(x)).expect("scalar")).expect("scalar")
                        })
                        .collect();
                    swift.insert(u32::try_from(u(from)).expect("scalar"), mapped);
                }
                let diffs: Vec<u32> = (0..=0x10_FFFFu32)
                    .filter_map(char::from_u32)
                    .filter(|&c| {
                        let want = swift
                            .get(&u32::from(c))
                            .cloned()
                            .unwrap_or_else(|| c.to_string());
                        tv::swift_lowercased(&c.to_string()) != want
                    })
                    .map(u32::from)
                    .collect();
                if !diffs.is_empty() {
                    fail(
                        "ulower",
                        format!(
                            "{} scalars differ, first {:x?}",
                            diffs.len(),
                            &diffs[..diffs.len().min(12)]
                        ),
                        "none".into(),
                    );
                }
            }
            other => panic!("unknown oracle record {other}"),
        }
    }
    assert!(checked >= 8_700, "fixture truncated: {checked} records");
    assert_eq!(
        spec_rows,
        spec_makes.len(),
        "the Rust table has rows the oracle does not"
    );
    assert_eq!(spec_makes.len(), spec_models.len());
    assert_eq!(spec_numbers.len(), spec_makes.len() * slots);

    let (known, unknown): (Vec<_>, Vec<_>) = failures
        .into_iter()
        .partition(|(line, _)| KNOWN_DIVERGENCES.iter().any(|(k, _)| k == line));
    if !unknown.is_empty() {
        let shown: Vec<String> = unknown
            .iter()
            .take(40)
            .map(|(l, m)| format!("{}{m}", l.chars().take(200).collect::<String>()))
            .collect();
        panic!(
            "{} of {checked} oracle records differ from the original Swift:\n{}",
            unknown.len(),
            shown.join("\n")
        );
    }
    assert_eq!(
        known.len(),
        KNOWN_DIVERGENCES.len(),
        "an allow-listed divergence no longer diverges; remove its KNOWN_DIVERGENCES entry"
    );
}
