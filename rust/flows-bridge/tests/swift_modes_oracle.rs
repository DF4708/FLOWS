// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the media, device and travel-mode decisions:
//! the records produced by the ORIGINAL `SignalQuality`, `AdaptiveTuning`,
//! `PlaybackFallback`, `PlaybackGrace`, `RadioTuning`, `AmtrakStations`,
//! `BreadcrumbTrail`, `AirTravel`, `Mobility` and `HybridWalk` at commit
//! bea472d, linked against the bridge, before that code moved to
//! `flows_core::media_policy` and `flows_core::travel_modes`. Every number is
//! compared bit for bit, every choice and order exactly.

use flows_core::media_policy as mp;
use flows_core::swift_text as st;
use flows_core::travel_modes as tm;
use std::collections::BTreeMap;

const ORIGINAL_COMMIT: &str = "bea472d";
const FS: char = '\u{1F}';
const RS: char = '\u{1E}';

type Point = (f64, f64);

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn od(f: &str) -> Option<f64> {
    (f != "-").then(|| d(f))
}
fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}
fn text(field: &str) -> String {
    let body = field
        .strip_prefix("t:")
        .unwrap_or_else(|| panic!("bad text {field}"));
    let bytes = body.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut k = 0;
    while k < bytes.len() {
        if bytes[k] == b'\\' {
            let hex = std::str::from_utf8(&bytes[k + 1..k + 3]).expect("escape");
            out.push(u8::from_str_radix(hex, 16).expect("escape byte"));
            k += 3;
        } else {
            out.push(bytes[k]);
            k += 1;
        }
    }
    String::from_utf8(out).expect("Swift strings are UTF-8")
}
fn otext(f: &str) -> Option<String> {
    (f != "-").then(|| text(f))
}
fn ht(s: &str) -> String {
    let mut out = String::from("t:");
    for b in s.bytes() {
        if (0x20..=0x7E).contains(&b) && b != b'\\' {
            out.push(b as char);
        } else {
            out.push_str(&format!("\\{b:02x}"));
        }
    }
    out
}
fn hto(s: Option<&str>) -> String {
    s.map_or_else(|| "-".to_string(), ht)
}
fn b(v: bool) -> String {
    (if v { "1" } else { "0" }).to_string()
}
fn flag(f: &str) -> bool {
    f == "1"
}
fn pt(f: &str) -> Point {
    let (a, c) = f.split_once('/').unwrap_or_else(|| panic!("bad point {f}"));
    (d(a), d(c))
}
fn pt_out(p: Point) -> String {
    format!("{}/{}", hx(p.0), hx(p.1))
}
fn pts(f: &str) -> Vec<Point> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split(';').map(pt).collect()
}
fn pts_out(p: &[Point]) -> String {
    p.iter().map(|&q| pt_out(q)).collect::<Vec<_>>().join(";")
}
fn items(f: &str) -> Vec<Vec<&str>> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split(RS).map(|it| it.split(FS).collect()).collect()
}
fn tier_name(code: u8) -> &'static str {
    match code {
        mp::tier::STRONG => "strong",
        mp::tier::FAIR => "fair",
        mp::tier::WEAK => "weak",
        _ => "offline",
    }
}
fn tier_code(name: &str) -> u8 {
    match name {
        "strong" => mp::tier::STRONG,
        "fair" => mp::tier::FAIR,
        "weak" => mp::tier::WEAK,
        _ => mp::tier::OFFLINE,
    }
}
fn same_double(a: f64, c: f64) -> bool {
    a == c
}

#[test]
fn rust_matches_the_frozen_swift_modes_oracle() {
    let fixture = include_str!("fixtures/swift_modes_oracle.tsv");
    assert!(
        fixture.contains(ORIGINAL_COMMIT),
        "fixture names its commit"
    );
    let claimed: usize = fixture
        .lines()
        .nth(2)
        .and_then(|l| l.strip_prefix("# "))
        .and_then(|l| l.split(' ').next())
        .and_then(|n| n.parse().ok())
        .expect("record count in the header");
    let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
    let mut mismatches: Vec<String> = Vec::new();
    let mut total = 0;
    for line in fixture
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        total += 1;
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0]).or_default() += 1;
        let (want, got): (String, String) = match f[0] {
            "sq-tier" => (
                f[4].to_string(),
                tier_name(mp::signal_tier(
                    otext(f[1]).as_deref(),
                    flag(f[2]),
                    flag(f[3]),
                ))
                .to_string(),
            ),
            "sq-prestage" => (
                f[4].to_string(),
                b(mp::should_pre_stage(
                    tier_code(f[1]),
                    flag(f[2]),
                    f[3].parse().expect("stalls"),
                )),
            ),
            "sq-drain" => (f[3].to_string(), b(mp::is_draining(od(f[1]), od(f[2])))),
            "at-base" => (
                f[3].to_string(),
                mp::device_tier(f[1].parse().expect("cores"), d(f[2])).to_string(),
            ),
            "at-settings" => {
                let s = mp::tuning_settings(
                    f[1].parse().expect("tier"),
                    f[2].parse().expect("thermal"),
                    flag(f[3]),
                );
                (
                    f[4].to_string(),
                    format!(
                        "{}/{}/{}/{}/{}",
                        s.max_in_flight,
                        s.planning_max_in_flight,
                        s.viewport_grid_span,
                        hx(s.ttl_multiplier),
                        hx(s.debounce_seconds)
                    ),
                )
            }
            "pf-lost" => {
                let (code, genre) = mp::on_connection_lost(
                    flag(f[1]),
                    flag(f[2]),
                    flag(f[3]),
                    otext(f[4]).as_deref(),
                );
                let got = match code {
                    mp::fallback::LOCAL_LIBRARY => "local".to_string(),
                    mp::fallback::RADIO => format!("radio{FS}{}", ht(&genre)),
                    mp::fallback::NOTHING_AVAILABLE => "nothing".to_string(),
                    _ => "keep".to_string(),
                };
                (f[5].to_string(), got)
            }
            "pf-restore" => (
                f[4].to_string(),
                b(mp::should_restore(flag(f[1]), flag(f[2]), flag(f[3]))),
            ),
            "pf-consts" => (f[1].to_string(), hx(mp::RESTORE_HOLD_SECONDS)),
            "pg-grace" => {
                let source = match f[1] {
                    "radio" => mp::player::RADIO,
                    "apple" => mp::player::APPLE_MUSIC_CLOUD,
                    "spotify" => mp::player::SPOTIFY,
                    _ => mp::player::OTHER_APP,
                };
                let buffer = if f[2] == "default" { None } else { od(f[2]) };
                (f[3].to_string(), hx(mp::grace_seconds(source, buffer)))
            }
            "pg-consts" => (
                f[1].to_string(),
                [
                    mp::RADIO_FLOOR_SECONDS,
                    mp::RADIO_CAP_SECONDS,
                    mp::APPLE_MUSIC_CAP_SECONDS,
                    mp::SPOTIFY_CAP_SECONDS,
                    mp::OTHER_APP_WATCH_SECONDS,
                ]
                .map(hx)
                .join("/"),
            ),
            "rt-nearest" => {
                let st_items = items(f[2]);
                let stations: Vec<(String, Point, bool)> = st_items
                    .iter()
                    .map(|it| (text(it[0]), pt(it[1]), flag(it[2])))
                    .collect();
                let located: Vec<(Point, bool)> = stations.iter().map(|s| (s.1, s.2)).collect();
                // The harness located the answer with `firstIndex(of:)`: a
                // station holding a NaN coordinate equals nothing.
                let got = mp::nearest_station(pt(f[1]), &located).map_or_else(
                    || "-".to_string(),
                    |(i, m)| {
                        let s = &stations[i];
                        stations
                            .iter()
                            .position(|o| {
                                st::eq(&o.0, &s.0)
                                    && o.2 == s.2
                                    && same_double(o.1 .0, s.1 .0)
                                    && same_double(o.1 .1, s.1 .1)
                            })
                            .map_or_else(|| "-".to_string(), |j| format!("{j}/{}", hx(m)))
                    },
                );
                (f[3].to_string(), got)
            }
            "rt-retarget" => {
                let st_items = items(f[4]);
                let stations: Vec<(String, Point, bool)> = st_items
                    .iter()
                    .map(|it| (text(it[0]), pt(it[1]), flag(it[2])))
                    .collect();
                let refs: Vec<(&str, Point, bool)> =
                    stations.iter().map(|s| (s.0.as_str(), s.1, s.2)).collect();
                let playing = otext(f[1]);
                let coord = (f[2] != "-").then(|| pt(f[2]));
                let got = mp::retarget(playing.as_deref(), coord, pt(f[3]), &refs)
                    .map(|i| stations[i].0.as_str());
                (f[5].to_string(), hto(got))
            }
            "rt-consts" => (f[1].to_string(), hx(mp::SWITCH_MARGIN)),
            "am-nearest" => {
                let st_items = items(f[3]);
                let stations: Vec<(String, String, f64, f64)> = st_items
                    .iter()
                    .map(|it| (text(it[0]), text(it[1]), d(it[2]), d(it[3])))
                    .collect();
                let coords: Vec<Point> = stations.iter().map(|s| (s.2, s.3)).collect();
                let got = tm::nearest_within(pt(f[1]), d(f[2]), &coords).and_then(|i| {
                    let s = &stations[i];
                    stations.iter().position(|o| {
                        st::eq(&o.0, &s.0)
                            && st::eq(&o.1, &s.1)
                            && same_double(o.2, s.2)
                            && same_double(o.3, s.3)
                    })
                });
                (
                    f[4].to_string(),
                    got.map_or_else(|| "-".to_string(), |i| i.to_string()),
                )
            }
            "bc-should" => (
                f[3].to_string(),
                b(tm::should_record(pt(f[1]), (f[2] != "-").then(|| pt(f[2])))),
            ),
            "bc-consts" => (
                format!("{}\t{}", f[1], f[2]),
                format!("{}\t{}", hx(tm::MIN_STEP_METERS), tm::MAX_POINTS),
            ),
            "bc-trail" => {
                let fed = if f[2] == "long" { pts(f[7]) } else { pts(f[2]) };
                let mut trail: Vec<Point> = Vec::new();
                for q in fed {
                    if tm::should_record(q, trail.last().copied()) {
                        trail.push(q);
                        if trail.len() > tm::MAX_POINTS {
                            let excess = trail.len() - tm::MAX_POINTS;
                            trail.drain(..excess);
                        }
                    }
                }
                let got = [
                    trail.len().to_string(),
                    hx(tm::way_back_meters(&trail)),
                    trail.last().map_or_else(|| "-".to_string(), |&p| pt_out(p)),
                    trail
                        .first()
                        .map_or_else(|| "-".to_string(), |&p| pt_out(p)),
                ]
                .join("\t");
                (f[3..7].join("\t"), got)
            }
            "air-miles" => {
                let m = d(f[1]);
                (
                    f[2..6].join("\t"),
                    [
                        b(tm::worth_flying(m)),
                        hx(tm::flight_seconds(m)),
                        hx(tm::door_seconds(m)),
                        hx(tm::fare_estimate(m)),
                    ]
                    .join("\t"),
                )
            }
            "air-score" => (
                f[2].to_string(),
                tm::airport_score(&text(f[1])).map_or_else(|| "-".to_string(), |s| s.to_string()),
            ),
            "air-pick" => {
                let cands: Vec<(String, f64)> = items(f[1])
                    .iter()
                    .map(|it| (text(it[0]), d(it[1])))
                    .collect();
                let refs: Vec<(&str, f64)> = cands.iter().map(|c| (c.0.as_str(), c.1)).collect();
                (
                    f[3].to_string(),
                    tm::pick_airport(&refs, d(f[2]))
                        .map_or_else(|| "-".to_string(), |i| i.to_string()),
                )
            }
            "air-consts" => (
                f[1].to_string(),
                [
                    tm::MIN_TRIP_MILES,
                    tm::MIN_AIRPORT_GAP_MILES,
                    tm::BOARD_BUFFER_SECONDS,
                    tm::ALIGHT_BUFFER_SECONDS,
                ]
                .map(hx)
                .join("/"),
            ),
            "tc-peak" => (
                f[2].to_string(),
                b(tm::is_peak(f[1].parse().expect("minutes"))),
            ),
            "tc-local" => {
                let (r, lon) = (d(f[1]), d(f[2]));
                let got = format!(
                    "{}\t{}",
                    tm::local_minutes(r, lon).map_or_else(|| "-".to_string(), |m| m.to_string()),
                    tm::traffic_interval_seconds(r, lon).map_or_else(|| "-".to_string(), hx)
                );
                (format!("{}\t{}", f[3], f[4]), got)
            }
            "tc-consts" => (
                format!("{}\t{}", f[1], f[2]),
                format!("{}\t{}", hx(tm::PEAK_SECONDS), hx(tm::OFF_PEAK_SECONDS)),
            ),
            "blob-clusters" => {
                let points = pts(f[1]);
                let got: Vec<String> = tm::risk_clusters(&points, d(f[2]))
                    .iter()
                    .map(|c| pts_out(&c.iter().map(|&i| points[i]).collect::<Vec<_>>()))
                    .collect();
                (f[3].to_string(), got.join("|"))
            }
            "blob-hull" => (
                f[3].to_string(),
                pts_out(&tm::risk_hull(&pts(f[1]), d(f[2]))),
            ),
            "fares" => {
                let m = d(f[1]);
                (
                    format!("{}\t{}", f[2], f[3]),
                    format!("{}\t{}", hx(tm::amtrak_fare(m)), hx(tm::greyhound_fare(m))),
                )
            }
            "fares-flat" => (
                format!("{}\t{}", f[1], f[2]),
                format!("{}\t{}", hx(tm::LOCAL_BUS_FARE), hx(tm::LOCAL_RAIL_FARE)),
            ),
            "hw-cost" => (f[2].to_string(), hx(tm::ride_cost(d(f[1])))),
            "hw-consts" => (
                f[1].to_string(),
                [
                    tm::BASE_FARE_USD,
                    tm::PER_MILE_USD,
                    tm::COST_CAP_USD,
                    tm::MIN_SAVED_FRACTION,
                    tm::MIN_SAVED_SECONDS,
                    tm::MIN_WALK_ALONE_SECONDS,
                    tm::max_affordable_ride_miles(),
                ]
                .map(hx)
                .join("/"),
            ),
            "hw-bar" => (
                f[4].to_string(),
                b(tm::meets_bar(d(f[1]), d(f[2]), d(f[3]))),
            ),
            "hw-eval" => (
                f[4].to_string(),
                tm::evaluate_ride(d(f[1]), d(f[2]), d(f[3])).map_or_else(
                    || "-".to_string(),
                    |o| {
                        [
                            o.ride_miles,
                            o.ride_seconds,
                            o.walk_seconds,
                            o.cost_usd,
                            o.ride_seconds + o.walk_seconds,
                        ]
                        .map(hx)
                        .join("/")
                    },
                ),
            ),
            "hw-prefix" => (
                f[3].to_string(),
                pts_out(&tm::prefix_coordinates(&pts(f[1]), d(f[2]))),
            ),
            other => panic!("unknown record kind {other}"),
        };
        if want != got {
            mismatches.push(format!(
                "{}\n  want {}\n  got  {}",
                line.chars().take(240).collect::<String>(),
                want.chars().take(300).collect::<String>(),
                got.chars().take(300).collect::<String>()
            ));
        }
    }
    println!("modes oracle: {total} records, {counts:?}");
    assert_eq!(total, claimed, "every record was read");
    let by_kind = mismatches
        .iter()
        .fold(BTreeMap::<String, usize>::new(), |mut m, l| {
            *m.entry(l.split('\t').next().unwrap_or("").to_string())
                .or_default() += 1;
            m
        });
    assert!(
        mismatches.is_empty(),
        "{} of {total} records differ {by_kind:?}; first:\n{}",
        mismatches.len(),
        mismatches
            .iter()
            .take(6)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
