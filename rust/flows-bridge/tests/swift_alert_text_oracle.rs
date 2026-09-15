// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for alert text and dispatch audio: the records
//! produced by the ORIGINAL `EscalationPolicy`, `AlertEntityParser` and
//! `ScannerIncidents` (identical from bea472d through 49492c9), linked against
//! the bridge, plus the Swift runtime rules they read, before that code moved
//! to `flows_core::alert_text`. Every decision, text and number is compared
//! exactly. The fold table and the match-end blockers are also checked over
//! every scalar, so a runtime with newer Unicode tables fails here, not
//! silently. `ep-dismiss` records pin the dismissal bookkeeping, which stays in
//! Swift; they are read and not compared.

use flows_core::alert_text as at;
use flows_core::swift_text as st;
use std::collections::{BTreeMap, HashMap};

const ORIGINAL_COMMIT: &str = "bea472d";
const FS: char = '\u{1F}';
const RS: char = '\u{1E}';

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
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
fn pt(f: &str) -> (f64, f64) {
    let (a, c) = f.split_once('/').unwrap_or_else(|| panic!("bad point {f}"));
    (d(a), d(c))
}
fn hex_scalar(h: &str) -> u32 {
    u32::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad scalar {h}"))
}
const CALL_KINDS: [&str; 6] = ["police", "medical", "fire", "rescue", "traffic", "hazard"];
const VEHICLE_KINDS: [&str; 6] = ["truck", "suv", "van", "sedan", "motorcycle", "bus"];
fn call_code(name: &str) -> u8 {
    CALL_KINDS
        .iter()
        .position(|x| *x == name)
        .unwrap_or_else(|| panic!("bad call kind {name}")) as u8
}
struct Incident {
    id: String,
    kind: u8,
    point: (f64, f64),
    heard: f64,
}
fn incident(f: &str) -> Incident {
    let v: Vec<&str> = f.split(FS).collect();
    Incident {
        id: text(v[0]),
        kind: call_code(v[1]),
        point: pt(v[2]),
        heard: d(v[4]),
    }
}
fn incidents(f: &str) -> Vec<Incident> {
    if f.is_empty() {
        Vec::new()
    } else {
        f.split(RS).map(incident).collect()
    }
}
fn joined(items: impl Iterator<Item = String>) -> String {
    items.collect::<Vec<_>>().join(&RS.to_string())
}

#[test]
fn rust_matches_the_frozen_swift_alert_text_oracle() {
    let fixture = include_str!("fixtures/swift_alert_text_oracle.tsv");
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
    let mut folding: HashMap<u32, Vec<u32>> = HashMap::new();
    let mut search_folds: HashMap<u32, Vec<u32>> = HashMap::new();
    let mut blockers: Vec<(u32, u32)> = Vec::new();
    let mut total = 0;
    for line in fixture
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        total += 1;
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0]).or_default() += 1;
        let (want, got): (String, String) = match f[0] {
            "u-locale" => (f[1].to_string(), ht("en_US")),
            "u-fold" => {
                let mapping = if f[2].is_empty() {
                    Vec::new()
                } else {
                    f[2].split(' ').map(hex_scalar).collect()
                };
                folding.insert(hex_scalar(f[1]), mapping);
                continue;
            }
            "u-ci-fold" => {
                let v = hex_scalar(f[1]);
                if f[2] == "1" {
                    search_folds.insert(v, folding[&v].clone());
                }
                continue;
            }
            "u-ci-after" => {
                blockers.push((hex_scalar(f[1]), hex_scalar(f[2])));
                continue;
            }
            "u-cic" => (
                f[3].to_string(),
                b(st::contains_case_insensitive(&text(f[1]), &text(f[2]))),
            ),
            "u-split" => (
                f[2].to_string(),
                joined(st::split_spaces(&text(f[1])).iter().map(|p| ht(p))),
            ),
            "u-int" => (
                f[2].to_string(),
                st::parse_swift_int(&text(f[1])).map_or_else(|| "-".to_string(), |v| v.to_string()),
            ),
            "ae-colors" => (
                f[1].to_string(),
                joined(at::COLOR_NAMES.iter().map(|c| ht(c))),
            ),
            "ae-brands" => (f[1].to_string(), joined(at::BRANDS.iter().map(|c| ht(c)))),
            "ae-kinds" => (f[1].to_string(), VEHICLE_KINDS.join(&RS.to_string())),
            "ae-describes" => (f[2].to_string(), b(at::describes_an_entity(&text(f[1])))),
            "ae-vehicle" => (
                f[2].to_string(),
                at::vehicle(&text(f[1])).map_or_else(
                    || "-".to_string(),
                    |v| {
                        format!(
                            "{}{FS}{}{FS}{}",
                            hto(v.color),
                            VEHICLE_KINDS[v.kind as usize],
                            hto(v.brand)
                        )
                    },
                ),
            ),
            "ae-person" => (
                f[2].to_string(),
                at::person(&text(f[1])).map_or_else(
                    || "-".to_string(),
                    |(child, color)| format!("{}{FS}{}", b(child), hto(color)),
                ),
            ),
            "sc-kind" => (
                f[2].to_string(),
                hto(at::kind_in_transcript(&text(f[1])).map(|k| CALL_KINDS[k as usize])),
            ),
            "sc-place" => (
                f[2].to_string(),
                hto(at::place_phrase(&text(f[1])).as_deref()),
            ),
            "sc-lifetime" => {
                let k = call_code(f[1]);
                (
                    format!("{}\t{}", f[2], f[3]),
                    format!(
                        "{}\t{}",
                        hx(at::lifetime_seconds(k)),
                        joined(at::phrases(k).iter().map(|p| ht(p)))
                    ),
                )
            }
            "sc-order" => (
                f[1].to_string(),
                at::MATCH_ORDER
                    .iter()
                    .map(|&k| CALL_KINDS[k as usize])
                    .collect::<Vec<_>>()
                    .join(&RS.to_string()),
            ),
            "sc-roads" => (
                f[1].to_string(),
                joined(at::ROAD_WORDS.iter().map(|r| ht(r))),
            ),
            "sc-consts" => (
                format!("{}\t{}", f[1], f[2]),
                format!("{}\t{}", hx(at::RELEVANT_METERS), hx(at::DUPLICATE_METERS)),
            ),
            "sc-expired" => {
                let i = incident(f[1]);
                (
                    f[3].to_string(),
                    b(at::is_expired(i.kind, i.heard, d(f[2]))),
                )
            }
            "sc-visible" => {
                let list = incidents(f[1]);
                let position = (f[2] != "-").then(|| pt(f[2]));
                let corridor: Vec<(f64, f64)> = if f[3].is_empty() {
                    Vec::new()
                } else {
                    f[3].split(';').map(pt).collect()
                };
                let rows: Vec<(u8, (f64, f64), f64)> =
                    list.iter().map(|i| (i.kind, i.point, i.heard)).collect();
                (
                    f[5].to_string(),
                    joined(
                        at::visible(&rows, position, &corridor, d(f[4]))
                            .into_iter()
                            .map(|k| ht(&list[k].id)),
                    ),
                )
            }
            "sc-merged" => {
                let list = incidents(f[1]);
                let new = incident(f[2]);
                let rows: Vec<(u8, (f64, f64))> = list.iter().map(|i| (i.kind, i.point)).collect();
                let mut ids: Vec<String> = at::merged_keep(&rows, new.kind, new.point)
                    .into_iter()
                    .map(|k| ht(&list[k].id))
                    .collect();
                ids.push(ht(&new.id));
                (f[3].to_string(), ids.join(&RS.to_string()))
            }
            "ep-consts" => (
                f[1..5].join("\t"),
                [
                    at::SUSTAINED_RISE,
                    at::DISMISS_MARGIN,
                    at::DEFERRED_BASELINE,
                    flows_core::risk::RISK_YELLOW_MIN,
                ]
                .map(hx)
                .join("\t"),
            ),
            "ep-eval" => {
                let before: Vec<&str> = f[2].split(FS).collect();
                let ids: Vec<String> = if before[2].is_empty() {
                    Vec::new()
                } else {
                    before[2].split(RS).map(text).collect()
                };
                let id_refs: Vec<&str> = ids.iter().map(String::as_str).collect();
                let r: Vec<&str> = f[3].split(FS).collect();
                let peak_id = otext(r[3]);
                let (baseline, trigger) = at::evaluate_escalation(
                    r[0] == "1",
                    d(r[1]),
                    d(r[2]),
                    peak_id.as_deref(),
                    d(before[0]),
                    d(before[1]),
                    &id_refs,
                );
                let prompt = match trigger {
                    None => "-".to_string(),
                    Some((kind, risk)) if kind == at::trigger::SUSTAINED => {
                        format!("s{FS}{}", hx(risk))
                    }
                    Some((_, risk)) => format!("a{FS}{}{FS}{}", hx(risk), hto(peak_id.as_deref())),
                };
                (
                    format!("{}\t{}", f[4], f[5]),
                    format!(
                        "{}{FS}{}{FS}{}\t{prompt}",
                        hx(baseline),
                        before[1],
                        before[2]
                    ),
                )
            }
            "ep-dismiss" => continue,
            other => panic!("unknown record kind {other}"),
        };
        if want != got {
            mismatches.push(format!(
                "{}\n  want {}\n  got  {}",
                line.chars().take(200).collect::<String>(),
                want.chars().take(200).collect::<String>(),
                got.chars().take(200).collect::<String>()
            ));
        }
    }
    // The tables over every scalar: the search's folds, and the match-end blockers.
    let mut table_mismatches = 0;
    for v in 0..=0x10_FFFF_u32 {
        let Some(c) = char::from_u32(v) else {
            continue;
        };
        let mut folded = Vec::new();
        st::fold_scalar(c, &mut folded);
        let folded: Vec<u32> = folded.into_iter().map(|x| x as u32).collect();
        let expected = search_folds.get(&v).cloned().unwrap_or_else(|| vec![v]);
        let blocked = blockers.iter().any(|&(lo, hi)| (lo..=hi).contains(&v));
        if folded != expected || st::blocks_match_end(c) != blocked {
            table_mismatches += 1;
        }
    }
    println!(
        "alert text oracle: {total} records, {counts:?}; table mismatches: {table_mismatches}"
    );
    assert_eq!(total, claimed, "every record was read");
    assert_eq!(
        table_mismatches, 0,
        "the fold and blocker tables disagree with the runtime over the scalar domain"
    );
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
