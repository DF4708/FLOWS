// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the long-drive rules: the records produced by
//! the ORIGINAL `FuelWarning`, `TripShare` (`TripShareLogic`, `DailyDriveLog`,
//! `ShareHistoryStore`) and `OfflineCorridors` (`CorridorRetention`,
//! `OfflineCorridorStore`) at commit d1197b5, linked against the bridge,
//! before that code moved to `flows_core::long_trips`. Every number is
//! compared bit for bit, every choice and order exactly, and both stores are
//! replayed share by share and step by step against the lists the real
//! stores held.
//!
//! One allowance, the geo oracle's: with no route, reachability is a bearing
//! against the course, and the app's Release build fuses that bearing's sine
//! and cosine. An answer may differ only where the bearing lies within a
//! nanodegree of the cone's edge, recomputed per record.

use flows_core::geo;
use flows_core::long_trips as lt;
use flows_core::trip_vehicle as tv;
use std::collections::BTreeMap;

const ORIGINAL_COMMIT: &str = "d1197b5";
const FS: char = '\u{1F}';
const RS: char = '\u{1E}';

/// A yes/no answer derived from a bearing may differ from the app's only
/// when that bearing lies this close, in degrees, to the cone's edge.
const CONE_EDGE_TOLERANCE_DEGREES: f64 = 1e-9;
/// The harness places this many reachability records on the cone's edge.
const EDGE_RECORDS: usize = 200;

const KINDS: &[(&str, usize)] = &[
    ("fw-band", 456),
    ("fw-consts", 1),
    ("fw-isreach", 700),
    ("fw-level", 1_125),
    ("oc-consts", 1),
    ("oc-decimate", 200),
    ("oc-keep", 1_000),
    ("oc-prune", 320),
    ("oc-store-nearest", 149),
    ("oc-store-prune", 160),
    ("oc-store-record", 166),
    ("oc-super", 400),
    ("oc-worth", 44),
    ("ts-consts", 1),
    ("ts-daily", 392),
    ("ts-norm", 336),
    ("ts-offer", 275),
    ("ts-rank", 415),
    ("ts-store", 634),
    ("ts-suggest", 40),
];

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
fn b(v: bool) -> &'static str {
    if v {
        "1"
    } else {
        "0"
    }
}
fn pt(f: &str) -> Point {
    let (a, c) = f.split_once('/').unwrap_or_else(|| panic!("bad point {f}"));
    (d(a), d(c))
}
fn opt_pt(f: &str) -> Option<Point> {
    (f != "-").then(|| pt(f))
}
fn pts(f: &str) -> Vec<Point> {
    if f.is_empty() {
        Vec::new()
    } else {
        f.split(';').map(pt).collect()
    }
}
fn columns(p: &[Point]) -> (Vec<f64>, Vec<f64>) {
    p.iter().copied().unzip()
}
fn same_point(a: Point, c: Point) -> bool {
    a.0.to_bits() == c.0.to_bits() && a.1.to_bits() == c.1.to_bits()
}
fn index_list(f: &str) -> Vec<usize> {
    let (_, body) = f.split_once(':').unwrap_or_else(|| panic!("bad list {f}"));
    if body.is_empty() {
        Vec::new()
    } else {
        body.split(',').map(|s| s.parse().expect("index")).collect()
    }
}
fn lst(v: &[usize]) -> String {
    let items: Vec<String> = v.iter().map(ToString::to_string).collect();
    format!("L{}:{}", v.len(), items.join(","))
}
/// `"N<n>:" + body`, as `(n, body)`.
fn counted(f: &str) -> (usize, &str) {
    let (n, body) = f
        .strip_prefix('N')
        .and_then(|rest| rest.split_once(':'))
        .unwrap_or_else(|| panic!("bad counted list {f}"));
    (n.parse().expect("count"), body)
}
/// `SavedCorridor.points`, entry by entry.
fn raw_points(f: &str) -> Vec<Vec<f64>> {
    let (n, body) = counted(f);
    if n == 0 {
        return Vec::new();
    }
    body.split(';')
        .map(|entry| {
            let (k, values) = entry.split_once(':').expect("entry");
            if k == "0" {
                Vec::new()
            } else {
                values.split(',').map(d).collect()
            }
        })
        .collect()
}
/// `SavedCorridor.coordinates`: the entries with at least two values.
fn decoded(raw: &[Vec<f64>]) -> Vec<Point> {
    raw.iter()
        .filter(|e| e.len() >= 2)
        .map(|e| (e[0], e[1]))
        .collect()
}
fn check(got: String, want: &str) -> Option<String> {
    (got != want).then(|| format!("got {got}"))
}

#[derive(Clone, Debug)]
struct Recipient {
    name: String,
    phone: String,
    dates: Vec<f64>,
}

fn recipients_out(rs: &[Recipient]) -> String {
    let rows: Vec<String> = rs
        .iter()
        .map(|r| {
            let dates: Vec<String> = r.dates.iter().map(|&x| hx(x)).collect();
            [ht(&r.name), ht(&r.phone), dates.join(",")].join(&FS.to_string())
        })
        .collect();
    format!("N{}:{}", rs.len(), rows.join(&RS.to_string()))
}

#[derive(Clone, Debug)]
struct Saved {
    saved_at: f64,
    name: String,
    points: Vec<Point>,
}

fn points_out(p: &[Point]) -> String {
    let entries: Vec<String> = p
        .iter()
        .map(|&(lat, lon)| format!("2:{},{}", hx(lat), hx(lon)))
        .collect();
    format!("N{}:{}", p.len(), entries.join(";"))
}

fn corridors_out(cs: &[Saved]) -> String {
    let rows: Vec<String> = cs
        .iter()
        .map(|c| [hx(c.saved_at), ht(&c.name), points_out(&c.points)].join(&FS.to_string()))
        .collect();
    format!("N{}:{}", cs.len(), rows.join(&RS.to_string()))
}

fn stations(f: &str) -> Vec<lt::Station> {
    let (n, body) = counted(f);
    if n == 0 {
        return Vec::new();
    }
    body.split(';')
        .map(|s| {
            let (miles, price) = s.split_once('/').expect("station");
            lt::Station {
                miles_ahead: d(miles),
                price: od(price),
            }
        })
        .collect()
}

fn date_lists(f: &str) -> Vec<Vec<f64>> {
    let (n, body) = counted(f);
    if n == 0 {
        return Vec::new();
    }
    body.split(';')
        .map(|s| {
            if s.is_empty() {
                Vec::new()
            } else {
                s.split(',').map(d).collect()
            }
        })
        .collect()
}

fn level_code(level: lt::FuelLevel) -> String {
    match level {
        lt::FuelLevel::None => "n".to_string(),
        lt::FuelLevel::LastChances(n) => format!("c{n}"),
        lt::FuelLevel::Unreachable => "u".to_string(),
    }
}

fn band_code(band: lt::FuelBand) -> &'static str {
    match band {
        lt::FuelBand::Green => "g",
        lt::FuelBand::Yellow => "y",
        lt::FuelBand::Red => "r",
    }
}

#[derive(Default)]
struct Replay {
    shares: BTreeMap<String, Vec<Recipient>>,
    corridors: BTreeMap<String, Vec<Saved>>,
    cone_edge_flips: usize,
}

impl Replay {
    fn record(&mut self, f: &[&str]) -> Option<String> {
        match f[0] {
            "fw-band" => {
                let x = d(f[1]);
                check(
                    format!(
                        "{}\t{}",
                        hx(lt::fuel_severity(x)),
                        band_code(lt::fuel_band(x))
                    ),
                    &format!("{}\t{}", f[2], f[3]),
                )
            }
            "fw-consts" => check(
                format!(
                    "{}\t{}\t{}",
                    hx(geo::AHEAD_CONE_DEGREES),
                    lt::WARN_AT_REACHABLE_COUNT,
                    hx(tv::RESERVE_MILES)
                ),
                &f[1..4].join("\t"),
            ),
            "fw-level" => {
                let s = stations(f[1]);
                let range = d(f[2]);
                let reserve = od(f[3]).unwrap_or(tv::RESERVE_MILES);
                let got = format!(
                    "{}\t{}\t{}",
                    lst(&lt::reachable_stations(&s, range, reserve)),
                    level_code(lt::fuel_level(&s, range, reserve)),
                    lt::cheapest_station(&s, range, reserve)
                        .map_or("-".to_string(), |i| i.to_string())
                );
                check(got, &f[4..7].join("\t"))
            }
            "fw-isreach" => {
                let (station, here, course) = (pt(f[1]), pt(f[2]), d(f[3]));
                let route = pts(f[4]);
                let corridor = od(f[5]).unwrap_or(geo::FUEL_CORRIDOR_METERS);
                let (lats, lons) = columns(&route);
                let got = geo::fuel_station_is_reachable(
                    station.0, station.1, here.0, here.1, course, &lats, &lons, corridor,
                );
                let mismatch = check(b(got).to_string(), f[6]);
                if mismatch.is_some() && route.is_empty() && course >= 0.0 {
                    let bearing = geo::bearing_degrees(here.0, here.1, station.0, station.1);
                    let edge = (geo::heading_delta_degrees(bearing, course).abs()
                        - geo::AHEAD_CONE_DEGREES)
                        .abs();
                    if edge <= CONE_EDGE_TOLERANCE_DEGREES {
                        self.cone_edge_flips += 1;
                        return None;
                    }
                }
                mismatch
            }
            "ts-consts" => check(
                format!(
                    "{}\t{}\t{}\t{}",
                    hx(lt::LONG_TRIP_MILES),
                    hx(lt::METERS_PER_MILE),
                    lt::MAX_RECIPIENTS,
                    lt::MAX_DATES_PER_RECIPIENT
                ),
                &f[1..5].join("\t"),
            ),
            "ts-offer" => check(
                b(lt::should_offer_share(d(f[1]), d(f[2]))).to_string(),
                f[3],
            ),
            "ts-daily" => {
                let (day, meters) = lt::daily_drive_add(d(f[1]), d(f[2]), d(f[3]), d(f[4]));
                check(format!("{}\t{}", hx(day), hx(meters)), &f[5..7].join("\t"))
            }
            "ts-rank" => {
                let lists = date_lists(f[2]);
                let views: Vec<&[f64]> = lists.iter().map(Vec::as_slice).collect();
                check(lst(&lt::ranked_recipients(&views, d(f[1]))), f[3])
            }
            "ts-norm" => check(ht(&lt::normalized_phone(&text(f[1]))), f[2]),
            "ts-store" => {
                let state = self.shares.entry(f[1].to_string()).or_default();
                let (name, phone, date) = (text(f[2]), text(f[3]), d(f[4]));
                let phones: Vec<&str> = state.iter().map(|r| r.phone.as_str()).collect();
                let dates: Vec<&[f64]> = state.iter().map(|r| r.dates.as_slice()).collect();
                if let Some(plan) = lt::record_share(&phones, &dates, &name, &phone, date) {
                    match plan.matched {
                        Some(i) => {
                            if plan.renames {
                                state[i].name.clone_from(&name);
                            }
                            state[i].dates.push(date);
                            state[i].dates.drain(..plan.dropped_dates);
                        }
                        None => state.push(Recipient {
                            name,
                            phone,
                            dates: vec![date],
                        }),
                    }
                    if let Some(order) = plan.order {
                        let next: Vec<Recipient> =
                            order.iter().map(|&i| state[i].clone()).collect();
                        *state = next;
                    }
                }
                if f[5] == "~" {
                    None
                } else {
                    check(recipients_out(state), f[5])
                }
            }
            "ts-suggest" => {
                let state = self.shares.entry(f[1].to_string()).or_default();
                let views: Vec<&[f64]> = state.iter().map(|r| r.dates.as_slice()).collect();
                check(lst(&lt::ranked_recipients(&views, d(f[2]))), f[3])
            }
            "oc-consts" => check(
                format!(
                    "{}\t{}\t{}\t{}\t{}",
                    hx(lt::MAX_AGE_SECONDS),
                    hx(lt::ARRIVED_METERS),
                    hx(lt::PASSED_METERS),
                    lt::MAX_STORED,
                    hx(lt::MIN_TRIP_METERS)
                ),
                &f[1..6].join("\t"),
            ),
            "oc-worth" => check(b(lt::worth_saving(d(f[1]))).to_string(), f[2]),
            "oc-keep" => {
                let coords = decoded(&raw_points(f[2]));
                let (lats, lons) = columns(&coords);
                let corridor = lt::Corridor {
                    saved_at: d(f[1]),
                    lats: &lats,
                    lons: &lons,
                };
                check(
                    b(lt::keep_corridor(corridor, d(f[3]), opt_pt(f[4]))).to_string(),
                    f[5],
                )
            }
            "oc-prune" => {
                let (n, body) = counted(f[1]);
                let rows: Vec<(f64, Vec<f64>, Vec<f64>)> = if n == 0 {
                    Vec::new()
                } else {
                    body.split(RS)
                        .map(|row| {
                            let g: Vec<&str> = row.split(FS).collect();
                            let (lats, lons) = columns(&decoded(&raw_points(g[2])));
                            (d(g[0]), lats, lons)
                        })
                        .collect()
                };
                let views: Vec<lt::Corridor<'_>> = rows
                    .iter()
                    .map(|(saved_at, lats, lons)| lt::Corridor {
                        saved_at: *saved_at,
                        lats,
                        lons,
                    })
                    .collect();
                check(
                    lst(&lt::prune_corridors(&views, d(f[2]), opt_pt(f[3]))),
                    f[4],
                )
            }
            "oc-super" => check(
                b(lt::supersedes(opt_pt(f[1]), opt_pt(f[2]))).to_string(),
                f[3],
            ),
            "oc-decimate" => {
                let road = pts(f[1]);
                let step = od(f[2]).unwrap_or(lt::DECIMATE_STEP_METERS);
                let limit = if f[3] == "-" {
                    lt::DECIMATE_LIMIT
                } else {
                    f[3].parse().expect("limit")
                };
                let (lats, lons) = columns(&road);
                let got = lt::decimate(&lats, &lons, step, limit);
                let want = index_list(f[4]);
                // Compared as points: a repeated input point may sit at either copy's index.
                let same = got.len() == want.len()
                    && got
                        .iter()
                        .zip(&want)
                        .all(|(&g, &w)| same_point(road[g], road[w]));
                (!same).then(|| format!("got {}", lst(&got)))
            }
            "oc-store-record" => {
                let state = self.corridors.entry(f[1].to_string()).or_default();
                let road = pts(f[2]);
                let (name, trip, now) = (text(f[3]), d(f[4]), d(f[5]));
                if lt::worth_saving(trip) {
                    let (lats, lons) = columns(&road);
                    let thin: Vec<Point> =
                        lt::decimate(&lats, &lons, lt::DECIMATE_STEP_METERS, lt::DECIMATE_LIMIT)
                            .into_iter()
                            .map(|i| road[i])
                            .collect();
                    if thin.len() >= 2 {
                        let saved: Vec<f64> = state.iter().map(|c| c.saved_at).collect();
                        let ends: Vec<Option<Point>> =
                            state.iter().map(|c| c.points.last().copied()).collect();
                        let order = lt::record_corridor(&saved, &ends, thin.last().copied(), now);
                        let fresh = Saved {
                            saved_at: now,
                            name,
                            points: thin,
                        };
                        let next: Vec<Saved> = order
                            .iter()
                            .map(|&i| state.get(i).cloned().unwrap_or_else(|| fresh.clone()))
                            .collect();
                        *state = next;
                    }
                }
                check(corridors_out(state), f[6])
            }
            "oc-store-prune" => {
                let state = self.corridors.entry(f[1].to_string()).or_default();
                let cols: Vec<(Vec<f64>, Vec<f64>)> =
                    state.iter().map(|c| columns(&c.points)).collect();
                let views: Vec<lt::Corridor<'_>> = state
                    .iter()
                    .zip(&cols)
                    .map(|(c, (lats, lons))| lt::Corridor {
                        saved_at: c.saved_at,
                        lats,
                        lons,
                    })
                    .collect();
                let order = lt::prune_corridors(&views, d(f[3]), opt_pt(f[2]));
                if order.len() != state.len() {
                    let next: Vec<Saved> = order.iter().map(|&i| state[i].clone()).collect();
                    *state = next;
                }
                check(corridors_out(state), f[4])
            }
            "oc-store-nearest" => {
                let state = self.corridors.entry(f[1].to_string()).or_default();
                let here = pt(f[2]);
                let mut lats = Vec::new();
                let mut lons = Vec::new();
                let mut counts = Vec::new();
                for c in state.iter() {
                    lats.extend(c.points.iter().map(|p| p.0));
                    lons.extend(c.points.iter().map(|p| p.1));
                    counts.push(c.points.len());
                }
                let got = geo::corridor_nearest(&lats, &lons, &counts, here.0, here.1);
                check(
                    format!(
                        "{}\t{}",
                        corridors_out(state),
                        got.map_or("-".to_string(), |i| i.to_string())
                    ),
                    &f[3..5].join("\t"),
                )
            }
            other => Some(format!("unknown record kind {other}")),
        }
    }
}

#[test]
fn rust_reproduces_the_original_swift_long_trip_rules_bit_for_bit() {
    let fixture = include_str!("fixtures/swift_long_trips_oracle.tsv");
    let header = fixture.lines().next().unwrap_or_default();
    assert!(
        header.starts_with("# FROZEN SWIFT ORACLE") && header.contains(ORIGINAL_COMMIT),
        "the fixture header must name the original commit: {header}"
    );
    let mut replay = Replay::default();
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut failures: Vec<String> = Vec::new();
    for line in fixture
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0].to_string()).or_default() += 1;
        if let Some(got) = replay.record(&f) {
            let shown: String = line.chars().take(240).collect();
            failures.push(format!(
                "{shown}\n    {}",
                got.chars().take(240).collect::<String>()
            ));
        }
    }
    let expected: BTreeMap<String, usize> =
        KINDS.iter().map(|&(k, n)| (k.to_string(), n)).collect();
    assert_eq!(counts, expected, "record kinds and counts");
    let total: usize = counts.values().sum();
    println!(
        "long-trip oracle: {total} records, {} mismatches, {} cone-edge flips",
        failures.len(),
        replay.cone_edge_flips
    );
    assert!(
        failures.is_empty(),
        "{} of {total} records differ from the Swift original; first:\n{}",
        failures.len(),
        failures
            .iter()
            .take(12)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
    assert!(
        replay.cone_edge_flips <= EDGE_RECORDS,
        "too many cone-edge flips: {}",
        replay.cone_edge_flips
    );
}
