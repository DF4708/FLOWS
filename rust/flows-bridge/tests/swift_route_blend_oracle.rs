// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the corridor blend: 900 roads scored by the
//! ORIGINAL `RouteBlend.blend` at commit 91798be — the Swift loop the
//! planner, the live corridor watch and the route card shared — before it
//! moved to `flows_core::route_blend`. Every risk, every family peak and the
//! identified sum are compared bit for bit.

use flows_core::forecast::Conditions;
use flows_core::hazard_feeds as hf;
use flows_core::hazard_feeds::{Point, Snapshot};
use flows_core::risk_field::{Entry, RiskField};
use flows_core::route_blend::{blend, Feeds, Forecast, Sample, PEAK_FAMILY_NAMES};

const ORIGINAL_COMMIT: &str = "91798be";
const RECORDS: usize = 900;
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
fn opt(t: &str) -> Option<f64> {
    (t != "-").then(|| d(t))
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
fn pt(f: &str) -> Point {
    let (a, b) = f.split_once('/').unwrap_or_else(|| panic!("bad point {f}"));
    (d(a), d(b))
}
fn pts(f: &str) -> Vec<Point> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split(';').map(pt).collect()
}
fn rings(f: &str) -> Vec<Vec<Point>> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split('|').map(pts).collect()
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
fn named(f: &str) -> Vec<(f64, f64, String)> {
    items(f)
        .into_iter()
        .map(|it| {
            let v = fields(it);
            (d(v[0]), d(v[1]), text(v[2]))
        })
        .collect()
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
fn zones_d(f: &str) -> Vec<(Vec<Vec<Point>>, f64)> {
    items(f)
        .into_iter()
        .map(|it| {
            let v = fields(it);
            (rings(v[0]), d(v[1]))
        })
        .collect()
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

#[test]
fn rust_reproduces_the_original_swift_corridor_blend() {
    let content = include_str!("fixtures/swift_route_blend_oracle.tsv");
    assert!(
        content
            .lines()
            .next()
            .unwrap_or_default()
            .contains(ORIGINAL_COMMIT),
        "fixture header must name the original commit"
    );
    let mut failures: Vec<String> = Vec::new();
    let mut records = 0_usize;
    for line in content
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        assert_eq!(f[0], "rb", "record kind");
        assert_eq!(f.len(), 22, "record fields");
        records += 1;

        let field: Option<RiskField> = (f[1] != "-").then(|| {
            let names = f[1].strip_suffix(FS).expect("families end with FS");
            let families: Vec<String> = items(names).into_iter().map(text).collect();
            let entries: Vec<Entry> = items(f[2])
                .into_iter()
                .map(|it| {
                    let v = fields(it);
                    Entry {
                        zip: text(v[0]),
                        lat: d(v[1]),
                        lon: d(v[2]),
                        scores: if v[3].is_empty() {
                            Vec::new()
                        } else {
                            v[3].split(',').map(d).collect()
                        },
                        summary: None,
                        ring: None,
                    }
                })
                .collect();
            RiskField::from_entries(String::new(), families, entries)
        });
        let events: Vec<Option<String>> = items(f[3])
            .into_iter()
            .map(|it| {
                let v = fields(it);
                (v[2] != "-").then(|| text(v[2]))
            })
            .collect();
        let samples: Vec<Sample<'_>> = items(f[3])
            .into_iter()
            .zip(&events)
            .map(|(it, event)| {
                let v = fields(it);
                let p = pt(v[0]);
                Sample {
                    lat: p.0,
                    lon: p.1,
                    severity: d(v[1]),
                    event: event.as_deref(),
                }
            })
            .collect();
        let forecasts: Vec<Forecast> = items(f[4])
            .into_iter()
            .map(|it| {
                let v = fields(it);
                Forecast {
                    sample: usize::try_from(i(v[0])).expect("forecast index"),
                    conditions: Conditions {
                        temperature_f: opt(v[1]),
                        wind_mph: opt(v[2]),
                        pop_percent: opt(v[4]),
                    },
                    qpf_inches: opt(v[5]),
                    elevation_meters: opt(v[6]),
                }
            })
            .collect();
        let gauges: Vec<(f64, f64, String)> = f[5].strip_prefix('g').map(named).unwrap_or_default();
        let water: Vec<Point> = f[6].strip_prefix('p').map(pts).unwrap_or_default();
        let closures: Vec<Point> = f[7].strip_prefix('p').map(pts).unwrap_or_default();
        let (water_lats, water_lons): (Vec<f64>, Vec<f64>) = water.into_iter().unzip();
        let (closure_lats, closure_lons): (Vec<f64>, Vec<f64>) = closures.into_iter().unzip();
        let feeds = Feeds {
            gauges: &gauges,
            water_lats: &water_lats,
            water_lons: &water_lons,
            closure_lats: &closure_lats,
            closure_lons: &closure_lons,
        };
        let snap: Snapshot = snapshot(&f[9..18]);
        let boxes = hf::ring_boxes(&snap.perimeters);
        let mut scorer = |p: Point| Some(hf::live_boxed(p, &snap, &boxes));
        let answer = if f[8] == "1" {
            blend(
                &samples,
                &forecasts,
                field.as_ref(),
                &feeds,
                Some(&mut scorer),
            )
        } else {
            blend(&samples, &forecasts, field.as_ref(), &feeds, None)
        };

        let risks: Vec<String> = answer.risks.iter().map(|&r| hx(r)).collect();
        let mut peaks: Vec<String> = PEAK_FAMILY_NAMES
            .iter()
            .zip(answer.peaks)
            .filter_map(|(name, v)| v.map(|v| format!("{name}={}", hx(v))))
            .collect();
        peaks.sort();
        let got = [
            format!("L{}:{}", risks.len(), risks.join(",")),
            peaks.join(","),
            hx(answer.identified_sum),
            if answer.live_unchecked { "1" } else { "0" }.to_string(),
        ]
        .join("\t");
        let want = f[18..22].join("\t");
        if got != want {
            failures.push(format!(
                "record {records}\n    got  {}\n    want {}",
                got.chars().take(400).collect::<String>(),
                want.chars().take(400).collect::<String>()
            ));
        }
    }
    assert_eq!(records, RECORDS, "record count");
    assert!(
        failures.is_empty(),
        "{} of {RECORDS} records differ:\n{}",
        failures.len(),
        failures
            .iter()
            .take(10)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
