// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the live hazard feeds and the alert service:
//! 6,670 records produced by the ORIGINAL `HazardFeedScores`,
//! `LiveHazardSnapshot`, `WeatherAlertService` statics,
//! `BackupWarningsCache.severity` and `MexicoFuelParsing` at commit
//! f36ee9e — compiled with the original `POIRanking.meters` and linked
//! against the bridge for the facades they called — before that code moved
//! to `flows_core::hazard_feeds`. Every number is compared bit for bit,
//! every decision and order exactly; the `u-wsnl` records pin the
//! whitespace-and-newline set the CRE scan trims with, over every scalar.

use flows_core::hazard_feeds as hf;
use flows_core::hazard_feeds::{Alert, Point, Snapshot};
use flows_core::swift_text as st;
use std::collections::BTreeMap;

const ORIGINAL_COMMIT: &str = "f36ee9e";
const FS: char = '\u{1F}';
const RS: char = '\u{1E}';

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}
fn i(t: &str) -> i64 {
    t.parse().unwrap_or_else(|_| panic!("bad int {t}"))
}
fn u(h: &str) -> u32 {
    u32::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex scalar {h}"))
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
fn hto(s: Option<&str>) -> String {
    s.map_or_else(|| "-".to_string(), ht)
}
fn lst(items: &[String]) -> String {
    format!("L{}:{}", items.len(), items.join(","))
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
fn pt(f: &str) -> Point {
    let (a, b) = f.split_once('/').unwrap_or_else(|| panic!("bad point {f}"));
    (d(a), d(b))
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
fn rings(f: &str) -> Vec<Vec<Point>> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split('|').map(pts).collect()
}
fn rings_out(r: &[Vec<Point>]) -> String {
    r.iter()
        .map(|ring| pts_out(ring))
        .collect::<Vec<_>>()
        .join("|")
}
fn items(f: &str) -> Vec<&str> {
    if f.is_empty() {
        Vec::new()
    } else {
        f.split(RS).collect()
    }
}
fn fields(item: &str) -> Vec<&str> {
    item.split(FS).collect()
}
fn triples(f: &str) -> Vec<(f64, f64, f64)> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split(',')
        .map(|t| {
            let v: Vec<f64> = t.split('/').map(d).collect();
            (v[0], v[1], v[2])
        })
        .collect()
}
fn triples_out(v: &[(f64, f64, f64)]) -> String {
    v.iter()
        .map(|t| format!("{}/{}/{}", hx(t.0), hx(t.1), hx(t.2)))
        .collect::<Vec<_>>()
        .join(",")
}
fn quads(f: &str) -> Vec<(f64, f64, f64, f64)> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split(',')
        .map(|t| {
            let v: Vec<f64> = t.split('/').map(d).collect();
            (v[0], v[1], v[2], v[3])
        })
        .collect()
}
fn quads_out(v: &[(f64, f64, f64, f64)]) -> String {
    v.iter()
        .map(|t| format!("{}/{}/{}/{}", hx(t.0), hx(t.1), hx(t.2), hx(t.3)))
        .collect::<Vec<_>>()
        .join(",")
}
fn named(f: &str) -> Vec<(f64, f64, String)> {
    items(f)
        .into_iter()
        .map(|it| {
            let v = fields(it);
            (d(v[0]), d(v[1]), text(v[2]))
        })
        .collect()
}
fn named_out(v: &[(f64, f64, String)]) -> String {
    v.iter()
        .map(|t| format!("{}{FS}{}{FS}{}", hx(t.0), hx(t.1), ht(&t.2)))
        .collect::<Vec<_>>()
        .join(&RS.to_string())
}
fn zones_i(f: &str) -> Vec<(Vec<Vec<Point>>, i64)> {
    items(f)
        .into_iter()
        .map(|it| {
            let v = fields(it);
            (rings(v[0]), i(v[1]))
        })
        .collect()
}
fn zones_i_out(v: &[(Vec<Vec<Point>>, i64)]) -> String {
    v.iter()
        .map(|z| format!("{}{FS}{}", rings_out(&z.0), z.1))
        .collect::<Vec<_>>()
        .join(&RS.to_string())
}
fn zones_d(f: &str) -> Vec<(Vec<Vec<Point>>, f64)> {
    items(f)
        .into_iter()
        .map(|it| {
            let v = fields(it);
            (rings(v[0]), d(v[1]))
        })
        .collect()
}
fn zones_d_out(v: &[(Vec<Vec<Point>>, f64)]) -> String {
    v.iter()
        .map(|z| format!("{}{FS}{}", rings_out(&z.0), hx(z.1)))
        .collect::<Vec<_>>()
        .join(&RS.to_string())
}
fn space(f: &str) -> (i64, i64, i64) {
    let v: Vec<i64> = f.split('/').map(i).collect();
    (v[0], v[1], v[2])
}
/// The nine snapshot fields the harness writes, from `f[at..at + 9]`.
fn snapshot(f: &[&str]) -> Snapshot {
    Snapshot {
        hotspots: triples(f[0]),
        perimeters: rings(f[1]),
        quakes: quads(f[2]),
        space: space(f[3]),
        volcanoes: named(f[4]),
        avalanche_zones: zones_i(f[5]),
        storms: triples(f[6]),
        tsunamis: named(f[7]),
        spc_zones: zones_d(f[8]),
    }
}
fn snapshot_out(s: &Snapshot) -> String {
    [
        triples_out(&s.hotspots),
        rings_out(&s.perimeters),
        quads_out(&s.quakes),
        format!("{}/{}/{}", s.space.0, s.space.1, s.space.2),
        named_out(&s.volcanoes),
        zones_i_out(&s.avalanche_zones),
        triples_out(&s.storms),
        named_out(&s.tsunamis),
        zones_d_out(&s.spc_zones),
    ]
    .join("\t")
}
/// An alert as `wa-cover`/`wa-prov` write it.
fn alert(item: &str) -> Alert {
    let v = fields(item);
    Alert {
        id: text(v[0]),
        event: text(v[1]),
        severity_score: d(v[2]),
        polygon: (v[3] != "-").then(|| pts(v[3])),
        extra_rings: if v[4] == "-" { Vec::new() } else { rings(v[4]) },
        expires: (v[5] != "-").then(|| d(v[5])),
        affected_zones: if v[6].is_empty() {
            Vec::new()
        } else {
            v[6].split(',').map(text).collect()
        },
    }
}

/// The harness's price map with its places in id byte order and each
/// place's pairs in type byte order.
fn byte_ordered_prices(field: &str) -> String {
    let mut places: Vec<(String, String)> = items(field)
        .into_iter()
        .map(|it| {
            let v = fields(it);
            let mut pairs: Vec<(String, &str)> = if v[1].is_empty() {
                Vec::new()
            } else {
                v[1].split(',')
                    .map(|p| {
                        let (t, rest) = p.rsplit_once('=').expect("pair");
                        (text(t), rest)
                    })
                    .collect()
            };
            pairs.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
            let joined: Vec<String> = pairs
                .iter()
                .map(|(t, bits)| format!("{}={bits}", ht(t)))
                .collect();
            (text(v[0]), format!("{}{FS}{}", v[0], joined.join(",")))
        })
        .collect();
    places.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
    places
        .into_iter()
        .map(|(_, s)| s)
        .collect::<Vec<_>>()
        .join(&RS.to_string())
}
fn byte_ordered_places(field: &str) -> String {
    let mut places: Vec<(String, &str)> = items(field)
        .into_iter()
        .map(|it| (text(fields(it)[0]), it))
        .collect();
    places.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
    places
        .into_iter()
        .map(|(_, s)| s.to_string())
        .collect::<Vec<_>>()
        .join(&RS.to_string())
}

#[test]
fn rust_reproduces_the_original_swift_hazard_feeds_and_alert_rules() {
    let content = include_str!("fixtures/swift_hazard_feeds_oracle.tsv");
    assert!(
        content
            .lines()
            .next()
            .unwrap_or_default()
            .contains(ORIGINAL_COMMIT),
        "fixture header must name the original commit"
    );
    let mut failures: Vec<String> = Vec::new();
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut wsnl: Vec<(u32, u32)> = Vec::new();
    let mut check = |kind: &str, line: &str, got: String, want: &str| {
        if got != want {
            failures.push(format!(
                "{kind}\t{}\n    got  {}\n    want {}",
                line.chars().take(200).collect::<String>(),
                got.chars().take(300).collect::<String>(),
                want.chars().take(300).collect::<String>()
            ));
        }
    };
    for line in content
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0].to_string()).or_default() += 1;
        match f[0] {
            "u-wsnl" => wsnl.push((u(f[1]), u(f[2]))),
            // ---- scalar tables ----
            "hf-air" => check("hf-air", line, hx(hf::air_score(d(f[1]))), f[2]),
            "hf-uv" => check("hf-uv", line, hx(hf::uv_score(d(f[1]))), f[2]),
            "hf-tropint" => check(
                "hf-tropint",
                line,
                hx(hf::tropical_intensity_score(d(f[1]))),
                f[2],
            ),
            "hf-space" => check("hf-space", line, hx(hf::space_weather_score(i(f[1]))), f[2]),
            "hf-avrating" => check(
                "hf-avrating",
                line,
                hx(hf::avalanche_rating_score(i(f[1]))),
                f[2],
            ),
            "hf-spc" => check("hf-spc", line, hx(hf::spc_categorical_score(i(f[1]))), f[2]),
            "hf-rad" => check(
                "hf-rad",
                line,
                hx(hf::radiation_space_weather_score(i(f[1]), i(f[2]), d(f[3]))),
                f[4],
            ),
            "hf-floodcat" => check(
                "hf-floodcat",
                line,
                hx(hf::flood_category_score(&text(f[1]))),
                f[2],
            ),
            "hf-volcanolvl" => check(
                "hf-volcanolvl",
                line,
                hx(hf::volcano_alert_score(&text(f[1]))),
                f[2],
            ),
            "hf-tsulevel" => check(
                "hf-tsulevel",
                line,
                hx(hf::tsunami_level_score(&text(f[1]))),
                f[2],
            ),
            "wa-sev" => check("wa-sev", line, hx(hf::severity_score(&text(f[1]))), f[2]),
            "wa-backup" => check(
                "wa-backup",
                line,
                hx(hf::backup_severity(&text(f[1]))),
                f[2],
            ),
            // ---- geometry ----
            "hf-pip" => {
                let ring = rings(f[1]).into_iter().next().unwrap_or_default();
                check(
                    "hf-pip",
                    line,
                    u8::from(hf::point_in_polygon(pt(f[2]), &ring)).to_string(),
                    f[3],
                );
            }
            "hf-fire" => check(
                "hf-fire",
                line,
                hx(hf::fire_score(&triples(f[1]), pt(f[2]))),
                f[3],
            ),
            "hf-seis" => check(
                "hf-seis",
                line,
                hx(hf::seismic_score(&quads(f[1]), pt(f[2]))),
                f[3],
            ),
            "hf-perim" => check(
                "hf-perim",
                line,
                hx(hf::fire_perimeter_score(&rings(f[1]), pt(f[2]))),
                f[3],
            ),
            "hf-gauge" => check(
                "hf-gauge",
                line,
                hx(hf::flood_gauge_score(&named(f[1]), pt(f[2]))),
                f[3],
            ),
            "hf-water" => check(
                "hf-water",
                line,
                hx(hf::water_proximity_score(&pts(f[1]), pt(f[2]))),
                f[3],
            ),
            "hf-volc" => check(
                "hf-volc",
                line,
                hx(hf::volcanic_score(&named(f[1]), pt(f[2]))),
                f[3],
            ),
            "hf-aval" => check(
                "hf-aval",
                line,
                hx(hf::avalanche_score(&zones_i(f[1]), pt(f[2]))),
                f[3],
            ),
            "hf-trop" => check(
                "hf-trop",
                line,
                hx(hf::tropical_score(&triples(f[1]), pt(f[2]))),
                f[3],
            ),
            "hf-tsu" => check(
                "hf-tsu",
                line,
                hx(hf::tsunami_score(&named(f[1]), pt(f[2]))),
                f[3],
            ),
            "hf-outlook" => check(
                "hf-outlook",
                line,
                hx(hf::outlook_score(&zones_d(f[1]), pt(f[2]))),
                f[3],
            ),
            "hf-closure" => {
                // Closures are written as "lat/lon" points joined by commas.
                let closures: Vec<Point> = if f[1].is_empty() {
                    Vec::new()
                } else {
                    f[1].split(',').map(pt).collect()
                };
                check(
                    "hf-closure",
                    line,
                    hx(hf::closure_score(&closures, pt(f[2]))),
                    f[3],
                );
            }
            // ---- the live snapshot ----
            "hf-live" => {
                let s = snapshot(&f[1..10]);
                let fam = hf::live(pt(f[10]), &s);
                let values: Vec<String> = fam.values().iter().map(|&v| hx(v)).collect();
                let names: Vec<&str> = fam
                    .band_input_contribution()
                    .iter()
                    .map(|(n, _)| *n)
                    .collect();
                check(
                    "hf-live",
                    line,
                    format!("{}\t{}", lst(&values), names.join(",")),
                    &f[11..13].join("\t"),
                );
            }
            "hf-clip" => {
                let s = snapshot(&f[1..10]);
                let got = snapshot_out(&s.clipped(d(f[10]), d(f[11]), d(f[12]), d(f[13])));
                check("hf-clip", line, got, &f[14..23].join("\t"));
            }
            // ---- the alert service ----
            "wa-cell" => check(
                "wa-cell",
                line,
                hto(hf::cell_key(pt(f[1])).as_deref()),
                f[2],
            ),
            "wa-states" => {
                let mut got = hf::states_containing(pt(f[1]));
                got.sort_unstable();
                check("wa-states", line, got.join(","), f[2]);
            }
            "wa-marine" => check(
                "wa-marine",
                line,
                hf::marine_regions_containing(pt(f[1])).join(","),
                f[2],
            ),
            "wa-cover" => {
                let alerts: Vec<Alert> = items(f[2]).into_iter().map(alert).collect();
                let mut zone_rings: BTreeMap<String, Vec<Vec<Point>>> = BTreeMap::new();
                for it in items(f[3]) {
                    let v = fields(it);
                    zone_rings.insert(text(v[0]), rings(v[1]));
                }
                let got: Vec<String> = hf::alerts_covering(pt(f[1]), &alerts, &zone_rings)
                    .iter()
                    .map(|k| k.to_string())
                    .collect();
                check("wa-cover", line, got.join(","), f[4]);
            }
            "wa-prov" => {
                let samples = pts(f[1]);
                let alerts: Vec<Alert> = items(f[2]).into_iter().map(alert).collect();
                let mut cells: BTreeMap<String, Vec<Alert>> = BTreeMap::new();
                for it in items(f[3]) {
                    let v = fields(it);
                    let hits: Vec<Alert> = if v[1].is_empty() {
                        Vec::new()
                    } else {
                        v[1].split(',')
                            .map(|k| alerts[k.parse::<usize>().expect("index")].clone())
                            .collect()
                    };
                    cells.insert(text(v[0]), hits);
                }
                let offsets: Option<Vec<f64>> =
                    (f[4] != "-").then(|| list(f[4]).into_iter().map(d).collect());
                let got: Vec<String> =
                    hf::provisional_samples(&samples, &cells, offsets.as_deref(), d(f[5]))
                        .iter()
                        .map(|s| {
                            s.as_ref().map_or_else(
                                || "-".to_string(),
                                |s| {
                                    format!(
                                        "{}{FS}{}{FS}{}",
                                        hx(s.risk),
                                        hto(s.worst_event.as_deref()),
                                        hto(s.alert_id.as_deref())
                                    )
                                },
                            )
                        })
                        .collect();
                check("wa-prov", line, got.join(&RS.to_string()), f[6]);
            }
            "wa-rings" => {
                let raws: Vec<Vec<Vec<f64>>> = if f[1].is_empty() {
                    Vec::new()
                } else {
                    f[1].split('|')
                        .map(|ring| {
                            if ring.is_empty() {
                                Vec::new()
                            } else {
                                ring.split(';')
                                    .map(|c| {
                                        if c.is_empty() {
                                            Vec::new()
                                        } else {
                                            c.split('/').map(d).collect()
                                        }
                                    })
                                    .collect()
                            }
                        })
                        .collect()
                };
                let got = hf::all_rings(&raws, usize::try_from(i(f[2])).unwrap_or(0));
                check("wa-rings", line, rings_out(&got), f[3]);
            }
            // ---- the CRE files ----
            // The harness sorted ids and types with Swift's `<`, which orders
            // canonically (a Kelvin sign sorts as K); the port's maps order by
            // bytes. Both sides are put in byte order here before comparing.
            "mx-prices" => {
                let got = hf::parse_fuel_prices(&text(f[1]));
                let out: Vec<String> = got
                    .iter()
                    .map(|(id, prices)| {
                        let pairs: Vec<String> = prices
                            .iter()
                            .map(|(t, v)| format!("{}={}", ht(t), hx(*v)))
                            .collect();
                        format!("{}{FS}{}", ht(id), pairs.join(","))
                    })
                    .collect();
                check(
                    "mx-prices",
                    line,
                    out.join(&RS.to_string()),
                    &byte_ordered_prices(f[2]),
                );
            }
            "mx-places" => {
                let got = hf::parse_fuel_places(&text(f[1]));
                let out: Vec<String> = got
                    .iter()
                    .map(|(id, p)| format!("{}{FS}{}{FS}{}", ht(id), hx(p.0), hx(p.1)))
                    .collect();
                check(
                    "mx-places",
                    line,
                    out.join(&RS.to_string()),
                    &byte_ordered_places(f[2]),
                );
            }
            other => panic!("unknown record kind {other}"),
        }
    }
    // The whitespace-and-newline set over every scalar.
    let in_ranges = |v: u32| wsnl.iter().any(|&(lo, hi)| lo <= v && v <= hi);
    let mut bad = 0;
    for c in (0..=0x10FFFF).filter_map(char::from_u32) {
        if st::is_whitespace_or_newline(c) != in_ranges(c as u32) {
            bad += 1;
        }
    }
    assert_eq!(
        bad, 0,
        "whitespace-and-newline set disagrees with the runtime on {bad} scalars"
    );

    let total: usize = counts.values().sum();
    assert!(total >= 6_500, "fixture truncated: {total}");
    assert_eq!(counts.len(), 35, "record kinds: {counts:?}");
    assert!(
        failures.is_empty(),
        "{} of {total} oracle records differ from the original Swift:\n{}",
        failures.len(),
        failures
            .iter()
            .take(40)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
