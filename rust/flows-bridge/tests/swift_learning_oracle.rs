// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the learned models: 10,673 records produced by
//! the ORIGINAL Swift (EverydayRadius, TrafficLearning,
//! RoadEfficiencyLearning, BufferLearning, RefuelLearning, DrivingProfile,
//! DestinationPrediction) at commit a007de0, before that math moved to
//! `flows_core::learning`. Every number is compared bit for bit; every
//! decision exactly.
//!
//! The Swift store methods (`record`, `decay`, `remember`'s eviction, the
//! trip and error windows) are pure pieces in Rust; this test recomposes them
//! the way the Swift did, over the snapshot each record carries.

use flows_core::learning as lr;
use flows_core::learning::{
    DelayCell, DestinationReason, EfficiencyCell, EtaState, Evidence, TrafficWeather,
};
use std::collections::BTreeMap;

const BASE_COMMIT: &str = "a007de042d12e736fdd86398e1ea54ca31aadc1f";

/// Records where the port deliberately differs from the Swift, keyed by kind
/// and the NFC-names field, with the Swift answer. Each must be consumed
/// exactly once, or the test fails.
///
/// Swift's `String <` is not a consistent order for canonically equivalent
/// names in different encodings: for "öz" and "o\u{308}" it returns false in
/// both directions (they sort as equal, so input order stands), and it puts
/// "가 " before the jamo spelling of "가" although the precomposed prefix is
/// shorter. The port orders NFC bytes (the Swift facade normalises the names),
/// which is what Swift itself does once both names are NFC; every record whose
/// names are already NFC agrees.
const KNOWN_DIVERGENCES: &[(&str, &str, &str)] = &[
    ("rank", "L2:s:c3b67a,s:c3b6", "L2:0,1"),
    ("rank", "L2:s:eab080,s:eab08020", "L2:1,0"),
];

// ---- decoding the harness's encodings ----

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn i(t: &str) -> i64 {
    t.parse().unwrap_or_else(|_| panic!("bad int {t}"))
}
fn b(t: &str) -> bool {
    match t {
        "1" => true,
        "0" => false,
        _ => panic!("bad bool {t}"),
    }
}
fn optd(t: &str) -> Option<f64> {
    (t != "-").then(|| d(t))
}
fn s(h: &str) -> String {
    let hex = h
        .strip_prefix("s:")
        .unwrap_or_else(|| panic!("bad string {h}"));
    let bytes: Vec<u8> = (0..hex.len())
        .step_by(2)
        .map(|k| u8::from_str_radix(&hex[k..k + 2], 16).expect("hex byte"))
        .collect();
    String::from_utf8(bytes).expect("utf-8")
}
fn list(f: &str) -> Vec<&str> {
    let (head, body) = f.split_once(':').unwrap_or_else(|| panic!("bad list {f}"));
    let n: usize = head.trim_start_matches('L').parse().expect("list count");
    if n == 0 {
        return Vec::new();
    }
    let v: Vec<&str> = body.split(',').collect();
    assert_eq!(v.len(), n, "list count in {f}");
    v
}
fn dl(f: &str) -> Vec<f64> {
    list(f).into_iter().map(d).collect()
}
fn il(f: &str) -> Vec<i64> {
    list(f).into_iter().map(i).collect()
}
fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}
fn ohx(x: Option<f64>) -> String {
    x.map(hx).unwrap_or_else(|| "-".into())
}
fn bo(v: bool) -> String {
    u8::from(v).to_string()
}
fn lst(items: &[String]) -> String {
    format!("L{}:{}", items.len(), items.join(","))
}
fn dl_out(v: &[f64]) -> String {
    lst(&v.iter().map(|x| hx(*x)).collect::<Vec<_>>())
}
fn il_out(v: &[i64]) -> String {
    lst(&v.iter().map(ToString::to_string).collect::<Vec<_>>())
}
fn hs_out(t: &str) -> String {
    format!(
        "s:{}",
        t.bytes().map(|c| format!("{c:02x}")).collect::<String>()
    )
}

/// The plain words Swift attached to each reason (DestinationPrediction.reason).
fn reason_words(r: DestinationReason) -> &'static str {
    match r {
        DestinationReason::UsuallyNow => "You usually go here about now",
        DestinationReason::CameAtThisTime => "You've come here at this time",
        DestinationReason::RegularAtThisHour => "A regular stop at this hour",
        DestinationReason::RegularPlace => "One of your regular places",
        DestinationReason::Recent => "You've been here recently",
    }
}
fn weather_name(w: TrafficWeather) -> &'static str {
    lr::TRAFFIC_WEATHER_NAMES[w as usize]
}

/// A store's `decay(to:)` over parallel (weightedSum, weight) lists.
fn decayed(
    ws: &[f64],
    w: &[f64],
    last: f64,
    now: f64,
    half_life: f64,
) -> (Vec<f64>, Vec<f64>, f64) {
    let plan = lr::decay_plan(last, now, half_life);
    if plan.apply {
        (
            lr::scale_all(ws, plan.factor),
            lr::scale_all(w, plan.factor),
            plan.last_decay,
        )
    } else {
        (ws.to_vec(), w.to_vec(), plan.last_decay)
    }
}

fn f64_const(name: &str) -> f64 {
    match name {
        "everydayDefaultMiles" => lr::EVERYDAY_DEFAULT_MILES,
        "everydayFloorMiles" => lr::EVERYDAY_FLOOR_MILES,
        "everydayHardCapMiles" => lr::EVERYDAY_HARD_CAP_MILES,
        "trafficHalfLifeSeconds" => lr::TRAFFIC_HALF_LIFE_SECONDS,
        "trafficMaxFactor" => lr::TRAFFIC_MAX_FACTOR,
        "trafficMinFactor" => lr::TRAFFIC_MIN_FACTOR,
        "efficiencyHalfLifeSeconds" => lr::EFFICIENCY_HALF_LIFE_SECONDS,
        "efficiencyConfidentMiles" => lr::EFFICIENCY_CONFIDENT_MILES,
        "efficiencyMinRatio" => lr::EFFICIENCY_MIN_RATIO,
        "efficiencyMaxRatio" => lr::EFFICIENCY_MAX_RATIO,
        "bufferAlpha" => lr::BUFFER_ALPHA,
        "bufferPlausibleLow" => lr::BUFFER_PLAUSIBLE_LOW,
        "bufferPlausibleHigh" => lr::BUFFER_PLAUSIBLE_HIGH,
        "refuelAccuracyFloor" => lr::REFUEL_ACCURACY_FLOOR,
        "staleGaugeGap" => lr::STALE_GAUGE_GAP_SECONDS,
        "etaMinPlausibleRatio" => lr::ETA_MIN_PLAUSIBLE_RATIO,
        "etaMaxPlausibleRatio" => lr::ETA_MAX_PLAUSIBLE_RATIO,
        "etaMinMeaningfulDeviation" => lr::ETA_MIN_MEANINGFUL_DEVIATION,
        "etaClampLow" => lr::ETA_CLAMP_LOW,
        "etaClampHigh" => lr::ETA_CLAMP_HIGH,
        "destinationRecencyHalfLifeDays" => lr::DESTINATION_RECENCY_HALF_LIFE_DAYS,
        "destinationContextWeight" => lr::DESTINATION_CONTEXT_WEIGHT,
        "destinationTimeWeight" => lr::DESTINATION_TIME_WEIGHT,
        "destinationBaseWeight" => lr::DESTINATION_BASE_WEIGHT,
        other => panic!("unknown const {other}"),
    }
}
fn i64_const(name: &str) -> i64 {
    match name {
        "everydayMinTripsForRadius" => lr::EVERYDAY_MIN_TRIPS_FOR_RADIUS,
        "everydayTripWindow" => lr::EVERYDAY_TRIP_WINDOW,
        "everydayMaxPlacesPerCategory" => lr::EVERYDAY_MAX_PLACES_PER_CATEGORY,
        "everydayFeatureIndexSpace" => lr::EVERYDAY_FEATURE_INDEX_SPACE,
        "everydayFeatureCount" => lr::EVERYDAY_FEATURE_COUNT,
        "trafficConfidentAfter" => lr::TRAFFIC_CONFIDENT_AFTER,
        "bufferMinSamplesToTrust" => lr::BUFFER_MIN_SAMPLES_TO_TRUST,
        "refuelWindow" => lr::REFUEL_WINDOW,
        "etaMinSamplesToApply" => lr::ETA_MIN_SAMPLES_TO_APPLY,
        other => panic!("unknown iconst {other}"),
    }
}

fn cell(ws: &str, w: &str, c: &str) -> DelayCell {
    DelayCell {
        weighted_sum: d(ws),
        weight: d(w),
        count: i(c),
    }
}
fn ecell(ws: &str, w: &str, m: &str) -> EfficiencyCell {
    EfficiencyCell {
        weighted_sum: d(ws),
        weight: d(w),
        miles: d(m),
    }
}

#[test]
fn rust_reproduces_the_original_swift_learned_models_bit_for_bit() {
    let text = include_str!("fixtures/swift_learning_oracle.tsv");
    let header = text.lines().next().unwrap_or_default();
    assert!(
        header.contains(BASE_COMMIT),
        "fixture header must name the base commit"
    );
    let mut failures: Vec<String> = Vec::new();
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut consumed = vec![0_usize; KNOWN_DIVERGENCES.len()];
    let mut check = |kind: &str, line: &str, got: String, want: &str| {
        if got != want {
            failures.push(format!(
                "{kind}\t{}\n    got  {got}\n    want {want}",
                line.chars().take(400).collect::<String>()
            ));
        }
    };
    for line in text
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0].to_string()).or_default() += 1;
        match f[0] {
            "const" => check("const", line, hx(f64_const(f[1])), f[2]),
            "iconst" => check("iconst", line, i64_const(f[1]).to_string(), f[2]),
            "table" => {
                assert_eq!(f[1], "trafficWeather");
                let got = lst(&lr::TRAFFIC_WEATHER_NAMES
                    .iter()
                    .map(|n| hs_out(n))
                    .collect::<Vec<_>>());
                check("table", line, got, f[2]);
            }
            "fidx" => {
                let got =
                    lr::everyday_feature_index(&s(f[1])).map_or("-".to_string(), |k| k.to_string());
                check("fidx", line, got, f[2]);
            }
            // ---- everyday radius ----
            "q" => check(
                "q",
                line,
                ohx(lr::everyday_quantile(&dl(f[1]), d(f[2]))),
                f[3],
            ),
            "rad" => check("rad", line, hx(lr::everyday_radius_miles(&dl(f[1]))), f[2]),
            "mean" => check(
                "mean",
                line,
                ohx(lr::everyday_mean_trip_miles(&dl(f[1]))),
                f[2],
            ),
            "sd" => check("sd", line, ohx(lr::everyday_trip_miles_sd(&dl(f[1]))), f[2]),
            "tripok" => check("tripok", line, bo(lr::everyday_accepts_trip(d(f[1]))), f[2]),
            "twin" => {
                // recordTrip(miles: Double(i)) for i in 0..<n: every trip is accepted;
                // the window keeps the most recent tripWindow.
                let n = usize::try_from(i(f[1])).expect("count");
                let all: Vec<f64> = (0..n)
                    .filter(|k| lr::everyday_accepts_trip(*k as f64))
                    .map(|k| k as f64)
                    .collect();
                let start = all
                    .len()
                    .saturating_sub(usize::try_from(lr::EVERYDAY_TRIP_WINDOW).expect("window"));
                check("twin", line, dl_out(&all[start..]), f[2]);
            }
            "hb" => check(
                "hb",
                line,
                lr::everyday_hour_bucket(i(f[1])).to_string(),
                f[2],
            ),
            "fv" => {
                let cat = s(f[7]);
                let index =
                    lr::everyday_feature_index(&cat).unwrap_or_else(|| panic!("category {cat}"));
                let v = lr::everyday_features(
                    i(f[1]),
                    b(f[2]),
                    d(f[3]),
                    d(f[4]),
                    d(f[5]),
                    d(f[6]),
                    index,
                );
                check("fv", line, dl_out(&v), f[8]);
            }
            "rank" => {
                let (uses, seen, last) = (il(f[1]), il(f[2]), dl(f[3]));
                let names: Vec<String> = list(f[5]).into_iter().map(s).collect();
                let refs: Vec<&str> = names.iter().map(String::as_str).collect();
                let order =
                    lr::everyday_ranked_order(&uses, &seen, &last, &refs).expect("parallel lists");
                let got = il_out(&order.iter().map(|k| *k as i64).collect::<Vec<_>>());
                if let Some(k) = KNOWN_DIVERGENCES.iter().position(|(kind, names, swift)| {
                    *kind == "rank" && *names == f[5] && *swift == f[6]
                }) {
                    assert_ne!(got, f[6], "a known divergence stopped diverging: {line}");
                    consumed[k] += 1;
                } else {
                    check("rank", line, got, f[6]);
                }
            }
            "evict" => {
                // remember(): the new place is appended (uses 0, seen 1, never
                // tapped), then exactly one place — the first minimum — leaves.
                let got = lr::everyday_evict_index(&il(f[1]), &il(f[2]), &dl(f[3]))
                    .map_or(-1, |k| k as i64);
                check("evict", line, got.to_string(), f[4]);
            }
            // ---- traffic delay ----
            "tw" => {
                let family = (f[1] != "-").then(|| s(f[1]));
                let got = hs_out(weather_name(lr::traffic_weather_from_family(
                    family.as_deref(),
                )));
                check("tw", line, got, f[2]);
            }
            "rc" => check("rc", line, bo(lr::road_class_is_highway(d(f[1]))), f[2]),
            "tmean" => check("tmean", line, hx(cell(f[1], f[2], "0").mean()), f[3]),
            "emean" => check("emean", line, hx(ecell(f[1], f[2], "0").mean()), f[3]),
            "tdecay" | "edecay" => {
                let half_life = if f[0] == "tdecay" {
                    lr::TRAFFIC_HALF_LIFE_SECONDS
                } else {
                    lr::EFFICIENCY_HALF_LIFE_SECONDS
                };
                let (ws, w, last) = decayed(&dl(f[1]), &dl(f[2]), d(f[3]), d(f[4]), half_life);
                check(
                    f[0],
                    line,
                    format!("{}\t{}\t{}", hx(last), dl_out(&ws), dl_out(&w)),
                    &f[5..8].join("\t"),
                );
            }
            "trec" => {
                let (p, a, last, now) = (d(f[1]), d(f[2]), d(f[3]), d(f[4]));
                let has_target = b(f[5]);
                let target = cell(f[6], f[7], f[8]);
                let (ows, ow, oc) = (dl(f[9]), dl(f[10]), il(f[11]));
                let (t, ows2, ow2, last2) = if lr::traffic_accepts(p, a) {
                    let plan = lr::decay_plan(last, now, lr::TRAFFIC_HALF_LIFE_SECONDS);
                    let sc = |x: f64| if plan.apply { x * plan.factor } else { x };
                    let before = if has_target {
                        DelayCell {
                            weighted_sum: sc(target.weighted_sum),
                            weight: sc(target.weight),
                            count: target.count,
                        }
                    } else {
                        DelayCell {
                            weighted_sum: 0.0,
                            weight: 0.0,
                            count: 0,
                        }
                    };
                    // None here is where Swift trapped (count overflow); the fixture cannot hold it.
                    (
                        lr::traffic_add(before, p, a),
                        ows.iter().map(|x| sc(*x)).collect(),
                        ow.iter().map(|x| sc(*x)).collect(),
                        now,
                    )
                } else {
                    (has_target.then_some(target), ows.clone(), ow.clone(), last)
                };
                let got = format!(
                    "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                    bo(t.is_some()),
                    hx(t.map_or(0.0, |c| c.weighted_sum)),
                    hx(t.map_or(0.0, |c| c.weight)),
                    t.map_or(0, |c| c.count),
                    dl_out(&ows2),
                    dl_out(&ow2),
                    il_out(&oc),
                    hx(last2)
                );
                check("trec", line, got, &f[12..20].join("\t"));
            }
            "tfac" => {
                let is_highway = b(f[1]);
                let local = b(f[2]).then(|| cell(f[3], f[4], f[5]));
                let pooled = b(f[6]).then(|| cell(f[7], f[8], f[9]));
                let r = d(f[10]);
                let keyed = if is_highway { pooled } else { local };
                let got = format!(
                    "{}\t{}\t{}\t{}",
                    hx(lr::traffic_factor(is_highway, local, pooled)),
                    hx(lr::traffic_adjusted_seconds(r, is_highway, local, pooled)),
                    lr::traffic_delay_minutes(r, is_highway, local, pooled)
                        .map_or("-".to_string(), |m| m.to_string()),
                    bo(lr::traffic_is_confident(keyed.map_or(0, |c| c.count)))
                );
                check("tfac", line, got, &f[11..15].join("\t"));
            }
            // ---- road efficiency ----
            "erec" => {
                let (mi, un, last, now) = (d(f[1]), d(f[2]), d(f[3]), d(f[4]));
                let has_target = b(f[5]);
                let target = ecell(f[6], f[7], f[8]);
                let (ows, ow, om) = (dl(f[9]), dl(f[10]), dl(f[11]));
                let (t, ows2, ow2, last2) = if lr::efficiency_accepts(mi, un) {
                    let plan = lr::decay_plan(last, now, lr::EFFICIENCY_HALF_LIFE_SECONDS);
                    let sc = |x: f64| if plan.apply { x * plan.factor } else { x };
                    let before = if has_target {
                        EfficiencyCell {
                            weighted_sum: sc(target.weighted_sum),
                            weight: sc(target.weight),
                            miles: target.miles,
                        }
                    } else {
                        EfficiencyCell {
                            weighted_sum: 0.0,
                            weight: 0.0,
                            miles: 0.0,
                        }
                    };
                    (
                        Some(lr::efficiency_add(before, mi, un)),
                        ows.iter().map(|x| sc(*x)).collect(),
                        ow.iter().map(|x| sc(*x)).collect(),
                        now,
                    )
                } else {
                    (has_target.then_some(target), ows.clone(), ow.clone(), last)
                };
                let got = format!(
                    "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                    bo(t.is_some()),
                    hx(t.map_or(0.0, |c| c.weighted_sum)),
                    hx(t.map_or(0.0, |c| c.weight)),
                    hx(t.map_or(0.0, |c| c.miles)),
                    dl_out(&ows2),
                    dl_out(&ow2),
                    dl_out(&om),
                    hx(last2)
                );
                check("erec", line, got, &f[12..20].join("\t"));
            }
            "eeco" => {
                let rated = d(f[1]);
                let is_highway = b(f[2]);
                let local = b(f[3]).then(|| ecell(f[4], f[5], f[6]));
                let pooled = b(f[7]).then(|| ecell(f[8], f[9], f[10]));
                let keyed = if is_highway { pooled } else { local };
                let got = format!(
                    "{}\t{}",
                    hx(lr::efficiency_economy(rated, is_highway, local, pooled)),
                    bo(lr::efficiency_is_confident(keyed.map_or(0.0, |c| c.miles)))
                );
                check("eeco", line, got, &f[11..13].join("\t"));
            }
            // ---- buffer learning ----
            "bu" => check(
                "bu",
                line,
                ohx(lr::buffer_updated(optd(f[1]), d(f[2]))),
                f[3],
            ),
            "bus" => check("bus", line, bo(lr::buffer_is_usable(d(f[1]))), f[2]),
            "bw" => check(
                "bw",
                line,
                hx(lr::buffer_wait_seconds(d(f[1]), optd(f[2]), i(f[3]))),
                f[4],
            ),
            // ---- refuel learning and the stale gauge ----
            "ra" => check("ra", line, hx(lr::refuel_accuracy(&dl(f[1]))), f[2]),
            "rsp" => {
                let got = bo(lr::refuel_should_prompt(
                    b(f[2]),
                    lr::refuel_accuracy(&dl(f[1])),
                ));
                check("rsp", line, got, f[3]);
            }
            "rerr" => check("rerr", line, hx(lr::refuel_error(d(f[1]), d(f[2]))), f[3]),
            "rcap" => {
                // record(predicted: Double(i % 11) / 10, reported: 0) n times; the
                // store keeps the most recent 50 errors.
                let n = usize::try_from(i(f[1])).expect("count");
                let errors: Vec<f64> = (0..n)
                    .map(|k| lr::refuel_error((k % 11) as f64 / 10.0, 0.0))
                    .collect();
                let start = errors
                    .len()
                    .saturating_sub(usize::try_from(lr::REFUEL_RETAINED).expect("retained"));
                check("rcap", line, dl_out(&errors[start..]), f[2]);
            }
            "sg" => check(
                "sg",
                line,
                bo(lr::gauge_went_stale(optd(f[1]), d(f[2]))),
                f[3],
            ),
            // ---- the personal ETA correction ----
            "em" => check("em", line, hx(lr::eta_multiplier(d(f[1]), i(f[2]))), f[3]),
            "er" => {
                let state = EtaState {
                    log_ratio: d(f[1]),
                    samples: i(f[2]),
                };
                let got = match lr::eta_record(state, d(f[3]), d(f[4]), d(f[5])) {
                    Some(next) => format!("{}\t{}\t1", hx(next.log_ratio), next.samples),
                    None => format!("{}\t{}\t0", hx(state.log_ratio), state.samples),
                };
                check("er", line, got, &f[6..9].join("\t"));
            }
            // ---- destination prediction ----
            "dr" => {
                let (ctx, time, total, last) = (il(f[1]), il(f[2]), il(f[3]), dl(f[4]));
                let evidence: Vec<Evidence> = (0..ctx.len())
                    .map(|k| Evidence {
                        context_hits: ctx[k],
                        time_hits: time[k],
                        total_hits: total[k],
                        last_used: last[k],
                    })
                    .collect();
                let ranked = lr::destination_rank(&evidence, d(f[5]), i(f[6]));
                let got = format!(
                    "{}\t{}\t{}",
                    il_out(&ranked.iter().map(|r| r.index as i64).collect::<Vec<_>>()),
                    dl_out(&ranked.iter().map(|r| r.score).collect::<Vec<_>>()),
                    lst(&ranked
                        .iter()
                        .map(|r| hs_out(reason_words(r.reason)))
                        .collect::<Vec<_>>())
                );
                check("dr", line, got, &f[7..10].join("\t"));
            }
            "dreason" => {
                let got = hs_out(reason_words(lr::destination_reason(
                    i(f[1]),
                    i(f[2]),
                    i(f[3]),
                )));
                check("dreason", line, got, f[4]);
            }
            "dconf" => {
                let scores = dl(f[1]);
                check(
                    "dconf",
                    line,
                    bo(lr::destination_is_confident(
                        scores.first().copied(),
                        i(f[2]),
                    )),
                    f[3],
                );
            }
            other => panic!("unknown record kind {other}"),
        }
    }
    let total: usize = counts.values().sum();
    assert!(total >= 10_600, "fixture truncated: {total}");
    assert!(
        consumed.iter().all(|c| *c == 1),
        "every known divergence must appear exactly once: {consumed:?}"
    );
    assert_eq!(counts.len(), 37, "record kinds: {counts:?}");
    assert!(
        failures.is_empty(),
        "{} of {total} oracle records differ from the original Swift:\n{}",
        failures.len(),
        failures
            .iter()
            .take(30)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
