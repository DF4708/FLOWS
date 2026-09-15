// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the seasonal risk model and the route-head
//! trainer: 3,163 records produced by the ORIGINAL Swift (SeasonalRiskModel,
//! RouteHeadTrainer) before it was replaced by `flows_core::seasonal`. Every
//! number is compared bit for bit; every decision exactly.
//!
//! The Swift store methods (record, recordOrigin, recordEdges, learnedHome,
//! trainingRows) are decomposed into pure functions in Rust; this test
//! recomposes them the way the Swift did, over the snapshot the record
//! carries, in the sorted order the harness wrote (the harness chose inputs
//! whose answers do not depend on dictionary order — see its README).

use flows_core::seasonal as sea;
use flows_core::seasonal::{
    EdgeKey, Head, HeadChoice, HeadMeta, Home, OriginEntry, OriginStat, RowInput, TrainingCell,
    WeekStat,
};
use std::collections::BTreeMap;

const BASE_COMMIT: &str = "a007de042d12e736fdd86398e1ea54ca31aadc1f";

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
fn opti(t: &str) -> Option<i64> {
    (t != "-").then(|| i(t))
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
fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}
fn ohx(x: Option<f64>) -> String {
    x.map(hx).unwrap_or_else(|| "-".into())
}
/// "wSum/wObserved/wSqErr/lastT/count"
fn wsf(t: &str) -> WeekStat {
    let p: Vec<&str> = t.split('/').collect();
    assert_eq!(p.len(), 5, "week stat {t}");
    WeekStat {
        w_sum: d(p[0]),
        w_observed: d(p[1]),
        w_sq_err: d(p[2]),
        last_t: d(p[3]),
        count: i(p[4]),
    }
}
fn wsf_out(w: WeekStat) -> String {
    format!(
        "{}/{}/{}/{}/{}",
        hx(w.w_sum),
        hx(w.w_observed),
        hx(w.w_sq_err),
        hx(w.last_t),
        w.count
    )
}
/// "weighted/lastSeen/firstSeen/trips"
fn osf(t: &str) -> OriginStat {
    let p: Vec<&str> = t.split('/').collect();
    assert_eq!(p.len(), 4, "origin stat {t}");
    OriginStat {
        weighted: d(p[0]),
        last_seen: d(p[1]),
        first_seen: d(p[2]),
        trips: i(p[3]),
    }
}
fn osf_out(o: OriginStat) -> String {
    format!(
        "{}/{}/{}/{}",
        hx(o.weighted),
        hx(o.last_seen),
        hx(o.first_seen),
        o.trips
    )
}
/// "L<n>:week/wsf,..." -> (week -> stat), sorted
fn weeks_field(f: &str) -> BTreeMap<i64, WeekStat> {
    list(f)
        .into_iter()
        .map(|item| {
            let (wk, rest) = item.split_once('/').expect("week/stat");
            (i(wk), wsf(rest))
        })
        .collect()
}
/// "L<n>:s:key=osf,..." -> (key -> stat), sorted by key
fn origins_field(f: &str) -> BTreeMap<String, OriginStat> {
    list(f)
        .into_iter()
        .map(|item| {
            let (k, v) = item.split_once('=').expect("key=stat");
            (s(k), osf(v))
        })
        .collect()
}
fn hs_out(t: &str) -> String {
    format!(
        "s:{}",
        t.bytes().map(|c| format!("{c:02x}")).collect::<String>()
    )
}
fn origins_out(o: &BTreeMap<String, OriginStat>) -> String {
    format!(
        "L{}:{}",
        o.len(),
        o.iter()
            .map(|(k, v)| format!("{}={}", hs_out(k), osf_out(*v)))
            .collect::<Vec<_>>()
            .join(",")
    )
}
/// "L<n>:s:key=<n>;week/wsf;...,..."
fn edges_field(f: &str) -> BTreeMap<String, BTreeMap<i64, WeekStat>> {
    list(f)
        .into_iter()
        .map(|item| {
            let (k, v) = item.split_once('=').expect("key=weeks");
            let mut parts = v.split(';');
            let n: usize = parts.next().expect("count").parse().expect("count");
            let weeks: BTreeMap<i64, WeekStat> = parts
                .map(|w| {
                    let (wk, rest) = w.split_once('/').expect("week/stat");
                    (i(wk), wsf(rest))
                })
                .collect();
            assert_eq!(weeks.len(), n);
            (s(k), weeks)
        })
        .collect()
}
fn edges_out(e: &BTreeMap<String, BTreeMap<i64, WeekStat>>) -> String {
    let items: Vec<String> = e
        .iter()
        .map(|(k, w)| {
            format!(
                "{}={}{}",
                hs_out(k),
                w.len(),
                w.iter()
                    .map(|(wk, st)| format!(";{wk}/{}", wsf_out(*st)))
                    .collect::<String>()
            )
        })
        .collect();
    format!("L{}:{}", e.len(), items.join(","))
}
#[derive(Clone, Debug, PartialEq)]
struct RouteRec {
    trip_count: i64,
    cross: bool,
    weeks: BTreeMap<i64, WeekStat>,
}
type RouteKey = (i64, i64, i64, i64);
/// "L<n>:oLat/oLon/dLat/dLon/tripCount/cross=<n>;week/wsf;...,..."
fn routes_field(f: &str) -> BTreeMap<RouteKey, RouteRec> {
    list(f)
        .into_iter()
        .map(|item| {
            let (k, v) = item.split_once('=').expect("key=rec");
            let kp: Vec<&str> = k.split('/').collect();
            assert_eq!(kp.len(), 6);
            let mut parts = v.split(';');
            let n: usize = parts.next().expect("count").parse().expect("count");
            let weeks: BTreeMap<i64, WeekStat> = parts
                .map(|w| {
                    let (wk, rest) = w.split_once('/').expect("week/stat");
                    (i(wk), wsf(rest))
                })
                .collect();
            assert_eq!(weeks.len(), n);
            (
                (i(kp[0]), i(kp[1]), i(kp[2]), i(kp[3])),
                RouteRec {
                    trip_count: i(kp[4]),
                    cross: b(kp[5]),
                    weeks,
                },
            )
        })
        .collect()
}
fn routes_out(r: &BTreeMap<RouteKey, RouteRec>) -> String {
    let items: Vec<String> = r
        .iter()
        .map(|((a, bb, c, dd), rec)| {
            format!(
                "{a}/{bb}/{c}/{dd}/{}/{}={}{}",
                rec.trip_count,
                u8::from(rec.cross),
                rec.weeks.len(),
                rec.weeks
                    .iter()
                    .map(|(wk, st)| format!(";{wk}/{}", wsf_out(*st)))
                    .collect::<String>()
            )
        })
        .collect();
    format!("L{}:{}", r.len(), items.join(","))
}
/// "<n>:hx:hx..."
fn vec_field(t: &str) -> Vec<f64> {
    let mut parts = t.split(':');
    let n: usize = parts.next().expect("n").parse().expect("n");
    let v: Vec<f64> = parts.map(d).collect();
    assert_eq!(v.len(), n, "vec {t}");
    v
}
fn vec_out(v: &[f64]) -> String {
    format!(
        "{}{}",
        v.len(),
        v.iter().map(|x| format!(":{}", hx(*x))).collect::<String>()
    )
}
/// "b2/b1/w2/w1" where w1 = "<rows>;vec;vec…"
fn head_field(t: &str) -> Head {
    let p: Vec<&str> = t.split('/').collect();
    assert_eq!(p.len(), 4, "head {t}");
    let mut w1p = p[3].split(';');
    let rows: usize = w1p.next().expect("rows").parse().expect("rows");
    let w1: Vec<Vec<f64>> = w1p.map(vec_field).collect();
    assert_eq!(w1.len(), rows);
    Head {
        w1,
        b1: vec_field(p[1]),
        w2: vec_field(p[2]),
        b2: d(p[0]),
    }
}
fn head_out(h: &Head) -> String {
    format!(
        "{}/{}/{}/{}{}",
        hx(h.b2),
        vec_out(&h.b1),
        vec_out(&h.w2),
        h.w1.len(),
        h.w1.iter()
            .map(|r| format!(";{}", vec_out(r)))
            .collect::<String>()
    )
}
/// "version/rows|-/tuned|-"
fn meta_field(t: &str) -> (i64, Option<i64>, Option<bool>) {
    let p: Vec<&str> = t.split('/').collect();
    assert_eq!(p.len(), 3, "meta {t}");
    (i(p[0]), opti(p[1]), (p[2] != "-").then(|| b(p[2])))
}
const COLS: usize = 8;
/// "<n>;col:col:...;..." with "-" for a missing column
fn rows_field(t: &str) -> Vec<RowInput> {
    let mut parts = t.split(';');
    let n: usize = parts.next().expect("n").parse().expect("n");
    let rows: Vec<RowInput> = parts
        .map(|r| {
            let c: Vec<Option<f64>> = r.split(':').map(optd).collect();
            assert_eq!(c.len(), COLS, "row {r}");
            RowInput {
                o_lat: c[0],
                o_lon: c[1],
                d_lat: c[2],
                d_lon: c[3],
                week: c[4],
                target: c[5],
                weight: c[6],
                cross_country: c[7],
            }
        })
        .collect();
    assert_eq!(rows.len(), n);
    rows
}
fn home_out(h: Option<Home>) -> String {
    h.map(|h| format!("{}/{}/{}", hx(h.lat), hx(h.lon), h.trips))
        .unwrap_or_else(|| "-".into())
}

// ---- the Swift store methods, recomposed from the Rust pieces ----

fn record_origin(origins: &mut BTreeMap<String, OriginStat>, lat: i64, lon: i64, t: f64) {
    let key = sea::origin_key(lat, lon);
    let prior = origins.get(&key).copied().unwrap_or(OriginStat {
        first_seen: t,
        ..OriginStat::default()
    });
    origins.insert(key, sea::origin_after_trip(prior, t));
    if sea::origins_over_cap(origins.len()) {
        let keys: Vec<String> = origins.keys().cloned().collect();
        let stats: Vec<(f64, f64)> = keys
            .iter()
            .map(|k| (origins[k].weighted, origins[k].last_seen))
            .collect();
        for idx in sea::origin_evictions(&stats, t) {
            origins.remove(&keys[idx]);
        }
    }
}

fn record_edges(
    edges: &mut BTreeMap<String, BTreeMap<i64, WeekStat>>,
    order: &mut Vec<String>,
    hubs: &[(f64, f64)],
    week: i64,
    observed: f64,
    t: f64,
) {
    if hubs.len() < 2 {
        return;
    }
    let keys = sea::path_edge_keys(hubs).expect("harness coordinates fit the cells");
    for k in keys {
        let rec = edges.entry(k.clone()).or_default();
        if !order.contains(&k) {
            order.push(k.clone());
        }
        let ws = rec.get(&week).copied().unwrap_or_default();
        rec.insert(
            week,
            ws.added(observed, observed, t, sea::DECAY_HALF_LIFE_WEEKS),
        );
    }
    if sea::edges_over_cap(edges.len()) {
        let fresh: Vec<f64> = order
            .iter()
            .map(|k| {
                let last: Vec<f64> = edges[k].values().map(|w| w.last_t).collect();
                sea::edge_freshness(&last)
            })
            .collect();
        let doomed = sea::edge_evictions(&fresh);
        let mut gone: Vec<String> = doomed.iter().map(|&idx| order[idx].clone()).collect();
        for k in gone.drain(..) {
            edges.remove(&k);
            order.retain(|o| *o != k);
        }
    }
}

#[test]
fn rust_reproduces_the_original_swift_seasonal_model_bit_for_bit() {
    let text = include_str!("fixtures/swift_seasonal_oracle.tsv");
    let header = text.lines().next().unwrap_or_default();
    assert!(
        header.contains(BASE_COMMIT),
        "fixture header must name the base commit"
    );
    let mut failures: Vec<String> = Vec::new();
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut check = |kind: &str, line: &str, got: String, want: &str| {
        if got != want {
            failures.push(format!(
                "{kind}\t{}\n    got  {got}\n    want {want}",
                line.chars().take(140).collect::<String>()
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
            "const" => {
                let got = match f[1] {
                    "crossCountryKm" => hx(sea::CROSS_COUNTRY_KM),
                    "localTripThreshold" => sea::LOCAL_TRIP_THRESHOLD.to_string(),
                    "crossCountryTripThreshold" => sea::CROSS_COUNTRY_TRIP_THRESHOLD.to_string(),
                    "minWeekSamplesForConfidence" => hx(sea::MIN_WEEK_SAMPLES_FOR_CONFIDENCE),
                    "decayHalfLifeWeeks" => hx(sea::DECAY_HALF_LIFE_WEEKS),
                    "homeMinTrips" => sea::HOME_MIN_TRIPS.to_string(),
                    "maxEdges" => sea::MAX_EDGES.to_string(),
                    "originHalfLifeDays" => hx(sea::ORIGIN_HALF_LIFE_DAYS),
                    "relocationMargin" => hx(sea::RELOCATION_MARGIN),
                    "relocationMinDays" => hx(sea::RELOCATION_MIN_DAYS),
                    "featureCount" => sea::ROUTE_FEATURE_COUNT.to_string(),
                    other => panic!("unknown const {other}"),
                };
                check("const", line, got, f[2]);
            }
            "wd" => check(
                "wd",
                line,
                wsf_out(wsf(f[1]).decayed(d(f[2]), d(f[3]))),
                f[4],
            ),
            "wa" => check(
                "wa",
                line,
                wsf_out(wsf(f[1]).added(d(f[2]), d(f[3]), d(f[4]), d(f[5]))),
                f[6],
            ),
            "wm" => check("wm", line, hx(sea::mean_observed(d(f[1]), d(f[2]))), f[3]),
            "im" => check(
                "im",
                line,
                u8::from(sea::is_modeled(i(f[1]), b(f[2]))).to_string(),
                f[3],
            ),
            "rk" => {
                let got = [d(f[1]), d(f[2]), d(f[3]), d(f[4])]
                    .iter()
                    .map(|x| sea::route_cell(*x).map_or("trap".to_string(), |c| c.to_string()))
                    .collect::<Vec<_>>()
                    .join("\t");
                check("rk", line, got, &f[5..9].join("\t"));
            }
            "ek" => {
                let got = sea::edge_key(d(f[1]), d(f[2]), d(f[3]), d(f[4])).map_or(
                    "trap".to_string(),
                    |EdgeKey {
                         a_lat,
                         a_lon,
                         b_lat,
                         b_lon,
                     }| format!("{a_lat}\t{a_lon}\t{b_lat}\t{b_lon}"),
                );
                check("ek", line, got, &f[5..9].join("\t"));
            }
            "es" => {
                let got = sea::edge_key(d(f[1]), d(f[2]), d(f[3]), d(f[4]))
                    .map(sea::edge_key_string)
                    .unwrap_or_else(|| "trap".into());
                check("es", line, got, &s(f[5]));
            }
            "ok" => check("ok", line, sea::origin_key(i(f[1]), i(f[2])), &s(f[3])),
            "sp" => {
                let weeks = weeks_field(f[5]);
                let week = i(f[3]);
                let got = match sea::prior_week_keys(week) {
                    None => None,
                    Some(keys) => {
                        let cells = [
                            weeks.get(&keys[0]).copied(),
                            weeks.get(&keys[1]).copied(),
                            weeks.get(&keys[2]).copied(),
                        ];
                        sea::seasonal_prior(i(f[1]), b(f[2]), week, cells, d(f[4]))
                    }
                };
                check(
                    "sp",
                    line,
                    got.map(|(r, c)| format!("{}/{}", hx(r), hx(c)))
                        .unwrap_or_else(|| "-".into()),
                    f[6],
                );
            }
            "ac" => {
                let weeks: Vec<WeekStat> = weeks_field(f[3]).into_values().collect();
                check(
                    "ac",
                    line,
                    ohx(sea::accuracy(i(f[1]), &weeks, d(f[2]))),
                    f[4],
                );
            }
            "ou" => {
                let mut origins: BTreeMap<String, OriginStat> = BTreeMap::new();
                let key = sea::origin_key(i(f[1]), i(f[2]));
                if f[3] != "-" {
                    origins.insert(key.clone(), osf(f[3]));
                }
                record_origin(&mut origins, i(f[1]), i(f[2]), d(f[4]));
                check(
                    "ou",
                    line,
                    format!("{}\t{}", key, osf_out(origins[&key])),
                    &format!("{}\t{}", s(f[5]), f[6]),
                );
            }
            "oe" => {
                let mut origins = origins_field(f[4]);
                record_origin(&mut origins, i(f[2]), i(f[3]), d(f[1]));
                check("oe", line, origins_out(&origins), f[5]);
            }
            "re" => {
                let mut edges = edges_field(f[5]);
                let mut order: Vec<String> = edges.keys().cloned().collect();
                let hubs: Vec<(f64, f64)> = list(f[1])
                    .into_iter()
                    .map(|p| {
                        let (la, lo) = p.split_once('/').expect("lat/lon");
                        (d(la), d(lo))
                    })
                    .collect();
                record_edges(&mut edges, &mut order, &hubs, i(f[2]), d(f[3]), d(f[4]));
                check("re", line, edges_out(&edges), f[6]);
            }
            "ee" => {
                let hubs: Vec<(f64, f64)> = list(f[1])
                    .into_iter()
                    .map(|p| {
                        let (la, lo) = p.split_once('/').expect("lat/lon");
                        (d(la), d(lo))
                    })
                    .collect();
                let layout = list(f[5]);
                let mut edges: BTreeMap<String, BTreeMap<i64, WeekStat>> = BTreeMap::new();
                let mut order: Vec<String> = Vec::new();
                for (j, offs) in layout.iter().enumerate() {
                    let mut weeks = BTreeMap::new();
                    if !offs.is_empty() {
                        for (q, off) in offs.split(':').enumerate() {
                            weeks.insert(
                                q as i64,
                                WeekStat {
                                    w_sum: 1.0,
                                    w_observed: 0.5,
                                    w_sq_err: 0.0,
                                    last_t: 1e6 + i(off) as f64,
                                    count: 1,
                                },
                            );
                        }
                    }
                    edges.insert(j.to_string(), weeks);
                    order.push(j.to_string());
                }
                record_edges(&mut edges, &mut order, &hubs, i(f[2]), d(f[3]), d(f[4]));
                let mut survivors: Vec<i64> = edges.keys().filter_map(|k| k.parse().ok()).collect();
                survivors.sort_unstable();
                let mut added: Vec<String> = edges
                    .iter()
                    .filter(|(k, _)| k.parse::<i64>().is_err())
                    .map(|(k, w)| format!("{}={}", hs_out(k), wsf_out(w[&7])))
                    .collect();
                added.sort();
                let got = format!(
                    "L{}:{}\tL{}:{}",
                    survivors.len(),
                    survivors
                        .iter()
                        .map(ToString::to_string)
                        .collect::<Vec<_>>()
                        .join(","),
                    added.len(),
                    added.join(",")
                );
                check("ee", line, got, &format!("{}\t{}", f[6], f[7]));
            }
            "rc" => {
                let key: RouteKey = (i(f[1]), i(f[2]), i(f[3]), i(f[4]));
                let (week, predicted, observed, dist, t) =
                    (i(f[5]), d(f[6]), d(f[7]), d(f[8]), d(f[9]));
                let mut routes = routes_field(f[10]);
                let mut origins = origins_field(f[11]);
                let rec = routes.entry(key).or_insert(RouteRec {
                    trip_count: 0,
                    cross: false,
                    weeks: BTreeMap::new(),
                });
                rec.trip_count = sea::next_count(rec.trip_count);
                rec.cross = sea::is_cross_country(dist);
                let ws = rec.weeks.get(&week).copied().unwrap_or_default();
                rec.weeks.insert(
                    week,
                    ws.added(observed, predicted, t, sea::DECAY_HALF_LIFE_WEEKS),
                );
                record_origin(&mut origins, key.0, key.1, t);
                check(
                    "rc",
                    line,
                    format!("{}\t{}", routes_out(&routes), origins_out(&origins)),
                    &format!("{}\t{}", f[12], f[13]),
                );
            }
            "lh" => {
                let origins = origins_field(f[3]);
                let entries: Vec<OriginEntry> = origins
                    .iter()
                    .map(|(k, st)| OriginEntry {
                        cell: sea::parse_origin_key(k),
                        stat: *st,
                    })
                    .collect();
                let current = (f[2] != "-").then(|| {
                    let (la, lo) = f[2].split_once('/').expect("lat/lon");
                    (i(la), i(lo))
                });
                check(
                    "lh",
                    line,
                    home_out(sea::learned_home(&entries, d(f[1]), current)),
                    f[4],
                );
            }
            "lg" => {
                let routes = routes_field(f[1]);
                let list: Vec<(i64, i64, i64)> = routes
                    .iter()
                    .map(|((a, bb, _, _), r)| (*a, *bb, r.trip_count))
                    .collect();
                check("lg", line, home_out(sea::legacy_home(&list)), f[2]);
            }
            "tr" => {
                let routes = routes_field(f[2]);
                let cells: Vec<TrainingCell> = routes
                    .iter()
                    .flat_map(|(k, r)| {
                        r.weeks.iter().map(move |(wk, st)| TrainingCell {
                            o_lat: k.0,
                            o_lon: k.1,
                            d_lat: k.2,
                            d_lon: k.3,
                            week: *wk,
                            cross_country: r.cross,
                            stat: *st,
                        })
                    })
                    .collect();
                let mut rows = sea::training_rows(&cells, d(f[1]));
                rows.sort_by(|a, bb| {
                    a[..5]
                        .iter()
                        .zip(&bb[..5])
                        .map(|(x, y)| x.total_cmp(y))
                        .find(|o| o.is_ne())
                        .unwrap_or(std::cmp::Ordering::Equal)
                });
                let got = format!(
                    "L{}:{}",
                    rows.len(),
                    rows.iter()
                        .map(|r| r.iter().map(|x| hx(*x)).collect::<Vec<_>>().join("/"))
                        .collect::<Vec<_>>()
                        .join(",")
                );
                check("tr", line, got, f[3]);
            }
            "rf" => check(
                "rf",
                line,
                vec_out(&sea::route_features(
                    d(f[1]),
                    d(f[2]),
                    d(f[3]),
                    d(f[4]),
                    i(f[5]),
                    b(f[6]),
                )),
                f[7],
            ),
            "hp" => check(
                "hp",
                line,
                hx(sea::head_predict(&head_field(f[1]), &vec_field(f[2]))),
                f[3],
            ),
            "ft" => {
                let base = head_field(f[1]);
                let (version, base_rows, _) = meta_field(f[2]);
                let rows = rows_field(f[3]);
                let (epochs, lr, anchor) = if f[4] == "d" {
                    (sea::TUNE_EPOCHS, sea::TUNE_LEARNING_RATE, sea::TUNE_ANCHOR)
                } else {
                    (i(f[4]), d(f[5]), d(f[6]))
                };
                let tuned = sea::fine_tune(&base, &rows, epochs, lr, anchor);
                let got_head = tuned
                    .as_ref()
                    .map(|t| head_out(&t.head))
                    .unwrap_or_else(|| "-".into());
                let got_meta = tuned
                    .as_ref()
                    .map(|t| {
                        format!(
                            "{version}/{}/1",
                            sea::tuned_rows(base_rows, t.samples as i64)
                        )
                    })
                    .unwrap_or_else(|| "-".into());
                let got_mse = ohx(sea::mean_squared_error(&base, &rows));
                let got_tuned_mse = tuned
                    .as_ref()
                    .map(|t| ohx(sea::mean_squared_error(&t.head, &rows)))
                    .unwrap_or_else(|| "-".into());
                check(
                    "ft",
                    line,
                    format!("{got_head}\t{got_meta}\t{got_mse}\t{got_tuned_mse}"),
                    &format!("{}\t{}\t{}\t{}", f[7], f[8], f[9], f[10]),
                );
            }
            "me" => check(
                "me",
                line,
                ohx(sea::mean_squared_error(
                    &head_field(f[1]),
                    &rows_field(f[2]),
                )),
                f[3],
            ),
            "wk" => check(
                "wk",
                line,
                sea::week_of_year(Some(i(f[1]))).to_string(),
                f[2],
            ),
            "copied-blend" => {
                let got = format!(
                    "{}\t{}",
                    hx(sea::blend_prior(d(f[1]), d(f[2]), d(f[3]))),
                    f[3]
                );
                check("copied-blend", line, got, &format!("{}\t{}", f[4], f[5]));
            }
            "copied-choose" => {
                let local = b(f[1]).then(|| HeadMeta {
                    rows: opti(f[3]),
                    tuned_on_device: (f[2] != "-").then(|| b(f[2])),
                });
                let bundled = b(f[4]).then(|| HeadMeta {
                    rows: opti(f[5]),
                    tuned_on_device: None,
                });
                let got = match sea::choose_head(local, bundled) {
                    HeadChoice::None => 0,
                    HeadChoice::Local => 1,
                    HeadChoice::Bundled => 2,
                };
                check("copied-choose", line, got.to_string(), f[6]);
            }
            "copied-due" => {
                let gap = b(f[2]).then(|| d(f[3]));
                check(
                    "copied-due",
                    line,
                    u8::from(sea::tune_due(i(f[1]), gap, i(f[4]))).to_string(),
                    f[5],
                );
            }
            "copied-accept" => check(
                "copied-accept",
                line,
                u8::from(sea::accept_tune(d(f[1]), d(f[2]))).to_string(),
                f[3],
            ),
            "copied-mean" => {
                let errors: Vec<f64> = list(f[1]).into_iter().map(d).collect();
                check("copied-mean", line, ohx(sea::mean_in_order(&errors)), f[2]);
            }
            other => panic!("unknown record kind {other}"),
        }
    }
    let total: usize = counts.values().sum();
    assert!(total >= 3100, "fixture truncated: {total}");
    assert_eq!(counts.len(), 29, "record kinds: {counts:?}");
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
