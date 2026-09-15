// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the brand, price and tag text: 23,594 records
//! produced by the ORIGINAL Swift (BrandKnowledge, RatingsAndCost,
//! FuelPrices, LaneData, EnforcementCameras) at commit a007de0, before that
//! code moved to `flows_core::places_text`, plus the Swift runtime's own text
//! tables read out scalar by scalar.
//!
//! Two halves. The `u-*` records pin `flows_core::swift_text`: every scalar's
//! word, number and whitespace class, grapheme-break class and combining
//! class, its lower- and uppercase mappings and its canonical decomposition
//! are compared against the embedded tables over the whole scalar domain,
//! and 2,500 random scalar sequences against the segmenter. The rest pin the
//! ported functions bit for bit and decision for decision over adversarial
//! text. The store's own steps (the live-price cache, the driver's shower
//! reports, the city table's dictionary) are recomposed here the way the
//! Swift did them.

use flows_core::places_text as pt;
use flows_core::swift_text as st;
use flows_core::trip_vehicle::{FUEL_DIESEL, FUEL_ELECTRIC, FUEL_GAS};
use std::collections::BTreeMap;

const BASE_COMMIT: &str = "a007de042d12e736fdd86398e1ea54ca31aadc1f";

// ---- decoding the harness's encodings ----

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}
fn ohx(x: Option<f64>) -> String {
    x.map_or_else(|| "-".to_string(), hx)
}
fn u(h: &str) -> u32 {
    u32::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex scalar {h}"))
}
fn i(t: &str) -> i64 {
    t.parse().unwrap_or_else(|_| panic!("bad int {t}"))
}
/// `t:` + UTF-8 with every byte outside 0x20…0x7E, and the backslash, as `\xx`.
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
    String::from_utf8(out).expect("the harness writes Swift strings, which are UTF-8")
}
fn otext(field: &str) -> Option<String> {
    (field != "-").then(|| text(field))
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
fn scalars(field: &str) -> Vec<u32> {
    field.split(',').map(u).collect()
}
fn bit(v: bool) -> String {
    u8::from(v).to_string()
}
fn tri(v: Option<bool>) -> String {
    v.map_or_else(|| "-".to_string(), bit)
}
fn opt_i(field: &str) -> Option<i64> {
    (field != "-").then(|| i(field))
}
fn all_scalars() -> impl Iterator<Item = char> {
    (0..=0x10FFFF).filter_map(char::from_u32)
}

/// The `u-gcb` probe pattern each class code produces (the generator's table,
/// inverted); `Other` is every probe but the first failing.
fn pattern_for_class(code: u32) -> &'static str {
    match code {
        1 => "00000000000000000",
        2 => "00000000000000001",
        3 => "00000000000000010",
        4 => "11011001010101100",
        5 => "11011001010100000",
        6 => "11001001010100000",
        7 => "10100110101000000",
        8 => "10001000000000000",
        9 => "10000000000100000",
        10 => "11011001010111100",
        11 => "11001001010101100",
        12 => "10000100000000000",
        13 => "10000011100000000",
        14 => "10000001111000000",
        15 => "10000000011000000",
        16 => "10000001101000000",
        17 => "10000001001000000",
        _ => "10000000000000000",
    }
}

fn fuel_code(name: &str) -> u8 {
    match name {
        "gas" => FUEL_GAS,
        "diesel" => FUEL_DIESEL,
        "electric" => FUEL_ELECTRIC,
        other => panic!("unknown fuel {other}"),
    }
}
fn country_code(name: &str) -> u8 {
    pt::COUNTRY_NAMES
        .iter()
        .position(|n| *n == name)
        .unwrap_or_else(|| panic!("unknown country {name}")) as u8
}

/// The AAA state page the harness's stub transport served, from its prices.
fn aaa_page(prices: &[&str]) -> String {
    let cells: String = prices.iter().map(|p| format!("<td>${p}</td>")).collect();
    format!(
        "<thead><th>Regular</th><th>Mid</th><th>Premium</th><th>Diesel</th></thead>\n<tbody><tr><td>Current Avg.</td>\n{cells}</tr>\n<tr><td>Yesterday Avg.</td><td>$3.5950</td></tr>"
    )
}
/// The states the harness refreshed, in order, with the prices its pages carried.
const LIVE_CODES: &[(&str, &[&str])] = &[
    ("WI", &["3.459", "3.7", "4.0", "3.899"]),
    ("TX", &["2.845", "3.1", "3.4", "3.555"]),
    ("CA", &["5.005", "5.3", "5.5", "5.995"]),
    ("ZZ", &["3.125", "3.2", "3.3", "3.875"]),
    ("ON", &["1.005", "2", "3", "11.995"]),
    ("KS", &["3.335", "3.4", "3.5", "4.015"]),
    ("NY", &["3.6840", "4.2100", "4.8310", "4.5810"]),
    ("DC", &["1.0001", "2", "3", "11.9999"]),
    ("HI", &["4.4449999", "5", "6", "5.1250001"]),
    ("SS", &["2.675", "2", "3", "3.015"]),
    ("MX", &["0.99", "2", "3", "4"]),
    ("QC", &["2", "3", "4"]),
];
/// The city table the harness built, with the keys the loader builds.
const CITY_TABLE: &[(&str, i64)] = &[
    ("wi|madison", 4),
    ("tx|el-paso", 0),
    ("tx|el paso", 2),
    ("qc|montr\u{E9}al", 3),
    ("ca|los-angeles", 6),
    ("ny|new-york", 1),
    ("\u{212A}s|salina", 5),
    ("oh|akron\u{301}", 7),
    ("", 9),
    ("|", 8),
];

/// A Swift `[String: V]` lookup: keys compare canonically.
fn dict_get<'a, V>(table: &'a [(impl AsRef<str>, V)], key: &str) -> Option<&'a V> {
    table
        .iter()
        .find(|(k, _)| st::eq(k.as_ref(), key))
        .map(|(_, v)| v)
}

#[test]
fn rust_reproduces_the_original_swift_places_text_and_the_runtime_tables() {
    let content = include_str!("fixtures/swift_places_text_oracle.tsv");
    assert!(
        content
            .lines()
            .next()
            .unwrap_or_default()
            .contains(BASE_COMMIT),
        "fixture header must name the base commit"
    );
    let mut failures: Vec<String> = Vec::new();
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut check = |kind: &str, line: &str, got: String, want: &str| {
        if got != want {
            failures.push(format!(
                "{kind}\t{}\n    got  {got}\n    want {want}",
                line.chars().take(300).collect::<String>()
            ));
        }
    };

    // The runtime tables, gathered first and compared over every scalar after.
    let mut word: Vec<(u32, u32)> = Vec::new();
    let mut num: Vec<(u32, u32)> = Vec::new();
    let mut ws: Vec<(u32, u32)> = Vec::new();
    let mut gcb: Vec<(u32, u32, String)> = Vec::new();
    let mut ccc: Vec<(u32, u32, u32)> = Vec::new();
    let mut lower: BTreeMap<u32, Vec<u32>> = BTreeMap::new();
    let mut upper: BTreeMap<u32, Vec<u32>> = BTreeMap::new();
    let mut nfd: BTreeMap<u32, Vec<u32>> = BTreeMap::new();
    let mut canon: BTreeMap<u32, Vec<u32>> = BTreeMap::new();
    // The shower tables, by id, as flat lat/lon pairs.
    let mut shower_tables: BTreeMap<String, (Vec<f64>, Vec<f64>)> = BTreeMap::new();
    // The live AAA cache the harness filled: code → (gas, diesel).
    let live: Vec<(String, (f64, f64))> = LIVE_CODES
        .iter()
        .filter_map(|(code, prices)| {
            pt::parse_current_avg(&aaa_page(prices)).map(|p| ((*code).to_string(), p))
        })
        .collect();

    for line in content
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0].to_string()).or_default() += 1;
        match f[0] {
            // ---- the runtime's tables ----
            "u-word" => word.push((u(f[1]), u(f[2]))),
            "u-num" => num.push((u(f[1]), u(f[2]))),
            "u-ws" => ws.push((u(f[1]), u(f[2]))),
            "u-gcb" => gcb.push((u(f[1]), u(f[2]), f[3].to_string())),
            "u-ccc" => ccc.push((u(f[1]), u(f[2]), f[3].parse().expect("ccc"))),
            "u-lower" => {
                lower.insert(u(f[1]), scalars(f[2]));
            }
            "u-upper" => {
                upper.insert(u(f[1]), scalars(f[2]));
            }
            "u-nfd" => {
                nfd.insert(u(f[1]), scalars(f[2]));
            }
            "u-canon" => {
                canon.insert(u(f[1]), scalars(f[2]));
            }
            "u-seg" => {
                let s: String = scalars(f[1])
                    .into_iter()
                    .filter_map(char::from_u32)
                    .collect();
                let sizes: Vec<String> = st::graphemes(&s)
                    .map(|g| g.chars().count().to_string())
                    .collect();
                check("u-seg", line, sizes.join(","), f[2]);
            }
            // ---- BrandKnowledge ----
            "bk" => {
                let name = text(f[1]);
                let got = format!(
                    "{}\t{}\t{}\t{}\t{}",
                    pt::cost_tier(&name).map_or_else(|| "-".to_string(), |t| t.to_string()),
                    pt::website(&name).map_or_else(|| "-".to_string(), |s| format!("t:{s}")),
                    tri(pt::gym_has_showers(&name)),
                    tri(pt::parking_fee(&name)),
                    bit(pt::is_shelter_noise(&name)),
                );
                check("bk", line, got, &f[2..7].join("\t"));
            }
            "bk-shelter" => {
                let code = pt::shelter_type(&text(f[1]), &text(f[2]));
                check(
                    "bk-shelter",
                    line,
                    format!("t:{}", pt::SHELTER_TYPE_NAMES[usize::from(code)]),
                    f[3],
                );
            }
            "bk-asked" => check(
                "bk-asked",
                line,
                bit(pt::asked_name_matches(&text(f[1]), &text(f[2]))),
                f[3],
            ),
            // ---- RatingsAndCost ----
            "rc-country" => check(
                "rc-country",
                line,
                pt::COUNTRY_NAMES[usize::from(pt::country_for_coordinate(d(f[1]), d(f[2])))]
                    .to_string(),
                f[3],
            ),
            "rc-bp" => {
                let edges: Vec<String> = pt::check_breakpoints(country_code(f[1]))
                    .iter()
                    .map(|&e| hx(e))
                    .collect();
                check(
                    "rc-bp",
                    line,
                    format!("L{}:{}", edges.len(), edges.join(",")),
                    f[2],
                );
            }
            "rc-tier" => check(
                "rc-tier",
                line,
                pt::cost_tier_for_check(d(f[1]), country_code(f[2])).to_string(),
                f[3],
            ),
            "rc-tier-usd" => check(
                "rc-tier-usd",
                line,
                pt::cost_tier_for_check(d(f[1]), 0).to_string(),
                f[2],
            ),
            "rc-nightly" => check(
                "rc-nightly",
                line,
                hx(pt::estimated_nightly(opt_i(f[1]))),
                f[2],
            ),
            "rc-yelp" => {
                let rating = (f[2] != "-").then(|| d(f[2]));
                check(
                    "rc-yelp",
                    line,
                    pt::yelp_cost_tier(&text(f[1]), rating).to_string(),
                    f[3],
                );
            }
            // ---- ShowerAvailability ----
            "sh-name" => {
                let name = otext(f[1]);
                let code = pt::shower_for_name(name.as_deref());
                check(
                    "sh-name",
                    line,
                    format!("t:{}", pt::SHOWER_NAMES[usize::from(code)]),
                    f[2],
                );
            }
            "sh-ladder" => {
                let name = otext(f[1]);
                let has_position = f[2] == "0";
                let disproved = f[3] == "1";
                let tag = otext(f[4]);
                let code =
                    pt::shower_ladder(name.as_deref(), has_position, disproved, tag.as_deref());
                check(
                    "sh-ladder",
                    line,
                    format!("t:{}", pt::SHOWER_NAMES[usize::from(code)]),
                    f[5],
                );
            }
            "sh-table" => {
                let flat: Vec<f64> = list(f[2]).into_iter().map(d).collect();
                let lats = flat.iter().step_by(2).copied().collect();
                let lons = flat.iter().skip(1).step_by(2).copied().collect();
                shower_tables.insert(f[1].to_string(), (lats, lons));
            }
            "sh-entry" => {
                let (lats, lons) = &shower_tables[f[1]];
                let got = pt::shower_table_entry(lats, lons, d(f[2]), d(f[3]))
                    .map_or_else(|| "-".to_string(), |k| k.to_string());
                check("sh-entry", line, got, f[4]);
            }
            "sh-city" => {
                let got = match (otext(f[1]), otext(f[2])) {
                    (Some(state), Some(city)) => {
                        let (hyphenated, spelled) = pt::city_keys(&state, &city);
                        dict_get(CITY_TABLE, &hyphenated)
                            .or_else(|| dict_get(CITY_TABLE, &spelled))
                            .map_or_else(|| "-".to_string(), |n| n.to_string())
                    }
                    _ => "-".to_string(),
                };
                check("sh-city", line, got, f[3]);
            }
            // ---- FuelPrices ----
            "fp-const" => {
                let got = match f[1] {
                    "nationalGas" => pt::NATIONAL_GAS,
                    "nationalDiesel" => pt::NATIONAL_DIESEL,
                    "nationalKWh" => pt::NATIONAL_KWH,
                    "mxnPerUSD" => pt::MXN_PER_USD,
                    "litersPerGallon" => pt::LITERS_PER_GALLON,
                    other => panic!("unknown constant {other}"),
                };
                check("fp-const", line, hx(got), f[2]);
            }
            "fp-factor" => {
                let code = text(f[1]);
                let got = pt::STATE_FACTORS
                    .iter()
                    .find(|(k, _)| *k == code)
                    .map(|(_, v)| *v);
                check("fp-factor", line, ohx(got), f[2]);
            }
            "fp-name" => {
                let name = text(f[1]);
                let got = pt::STATE_NAMES
                    .iter()
                    .find(|(k, _)| *k == name)
                    .map_or_else(|| "-".to_string(), |(_, v)| format!("t:{v}"));
                check("fp-name", line, got, f[2]);
            }
            "fp-mxn" => check("fp-mxn", line, hx(pt::usd_per_gallon(d(f[1]))), f[2]),
            "fp-mex" => check(
                "fp-mex",
                line,
                hx(pt::mexico_estimate(fuel_code(f[1]))),
                f[2],
            ),
            "fp-live" => {
                let code = text(f[1]);
                let got = live.iter().find(|(k, _)| *k == code).map(|(_, p)| *p);
                check(
                    "fp-live",
                    line,
                    format!("{}\t{}", ohx(got.map(|p| p.0)), ohx(got.map(|p| p.1))),
                    &f[2..4].join("\t"),
                );
            }
            "fp-est" => {
                let state = otext(f[2]);
                let code = pt::fuel_state_code(state.as_deref());
                let cached = code.as_deref().and_then(|c| dict_get(&live, c)).copied();
                check(
                    "fp-est",
                    line,
                    hx(pt::fuel_estimate(fuel_code(f[1]), code.as_deref(), cached)),
                    f[3],
                );
            }
            "fp-aaa" => {
                let got = pt::parse_current_avg(&text(f[1]));
                check(
                    "fp-aaa",
                    line,
                    format!("{}\t{}", ohx(got.map(|p| p.0)), ohx(got.map(|p| p.1))),
                    &f[2..4].join("\t"),
                );
            }
            // ---- LaneData ----
            "ld-parse" => {
                let lanes: Vec<String> = pt::parse_turn_lanes(&text(f[1]))
                    .iter()
                    .map(|lane| {
                        lane.iter()
                            .map(|&t| pt::TURN_NAMES[usize::from(t)])
                            .collect::<Vec<_>>()
                            .join(",")
                    })
                    .collect();
                check("ld-parse", line, format!("t:{}", lanes.join("|")), f[2]);
            }
            // ---- EnforcementCameras ----
            "ec-kind" => {
                let tags: Vec<Option<String>> = f[1..5].iter().map(|x| otext(x)).collect();
                let got = pt::camera_kind(
                    tags[0].as_deref(),
                    tags[1].as_deref(),
                    tags[2].as_deref(),
                    tags[3].as_deref(),
                );
                check(
                    "ec-kind",
                    line,
                    got.map_or_else(
                        || "-".to_string(),
                        |k| pt::CAMERA_KIND_NAMES[usize::from(k)].to_string(),
                    ),
                    f[5],
                );
            }
            "ec-limit" => {
                let maxspeed = otext(f[1]);
                check(
                    "ec-limit",
                    line,
                    ohx(pt::camera_limit_mph(maxspeed.as_deref())),
                    f[2],
                );
            }
            other => panic!("unknown record kind {other}"),
        }
    }

    // ---- every scalar against the embedded tables ----
    let in_ranges =
        |ranges: &[(u32, u32)], v: u32| ranges.iter().any(|&(lo, hi)| lo <= v && v <= hi);
    let mut table_failures: Vec<String> = Vec::new();
    let gcb_of = |v: u32| {
        gcb.iter()
            .find(|&&(lo, hi, _)| lo <= v && v <= hi)
            .map(|(_, _, p)| p.as_str())
            .unwrap_or_else(|| panic!("no grapheme record for {v:x}"))
    };
    let ccc_of = |v: u32| {
        ccc.iter()
            .find(|&&(lo, hi, _)| lo <= v && v <= hi)
            .map_or(0, |&(_, _, c)| c)
    };
    let mut gcb_cursor = 0usize;
    let mut ccc_cursor = 0usize;
    for c in all_scalars() {
        let v = c as u32;
        let one = c.to_string();
        if st::is_word_scalar(c) != in_ranges(&word, v) {
            table_failures.push(format!("word class of {v:x}"));
        }
        if st::is_number_scalar(c) != in_ranges(&num, v) {
            table_failures.push(format!("number class of {v:x}"));
        }
        if st::is_whitespace(c) != in_ranges(&ws, v) {
            table_failures.push(format!("whitespace of {v:x}"));
        }
        // The grapheme and combining records are sorted runs: walk them.
        while gcb_cursor < gcb.len() && gcb[gcb_cursor].1 < v {
            gcb_cursor += 1;
        }
        let want_gcb = if gcb_cursor < gcb.len() && gcb[gcb_cursor].0 <= v {
            gcb[gcb_cursor].2.as_str()
        } else {
            gcb_of(v)
        };
        if pattern_for_class(st::grapheme_class_code(c)) != want_gcb {
            table_failures.push(format!(
                "grapheme class of {v:x}: {} for {want_gcb}",
                st::grapheme_class_code(c)
            ));
        }
        while ccc_cursor < ccc.len() && ccc[ccc_cursor].1 < v {
            ccc_cursor += 1;
        }
        let want_ccc = if ccc_cursor < ccc.len() && ccc[ccc_cursor].0 <= v && v <= ccc[ccc_cursor].1
        {
            ccc[ccc_cursor].2
        } else {
            ccc_of(v)
        };
        if st::combining_class(c) != want_ccc {
            table_failures.push(format!("combining class of {v:x}"));
        }
        let identity = vec![v];
        let got_lower: Vec<u32> = st::lowercased(&one).chars().map(|c| c as u32).collect();
        if got_lower != *lower.get(&v).unwrap_or(&identity) {
            table_failures.push(format!("lowercase of {v:x}"));
        }
        let got_upper: Vec<u32> = st::uppercased(&one).chars().map(|c| c as u32).collect();
        if got_upper != *upper.get(&v).unwrap_or(&identity) {
            table_failures.push(format!("uppercase of {v:x}"));
        }
        let got_nfd: Vec<u32> = st::nfd(&one).iter().map(|&c| c as u32).collect();
        let want_nfd = if (0xAC00..=0xD7A3).contains(&v) {
            // Hangul syllables decompose arithmetically; the harness left them out.
            let index = v - 0xAC00;
            let l = 0x1100 + index / 588;
            let vv = 0x1161 + (index % 588) / 28;
            let t = 0x11A7 + index % 28;
            if t == 0x11A7 {
                vec![l, vv]
            } else {
                vec![l, vv, t]
            }
        } else {
            nfd.get(&v).cloned().unwrap_or(identity.clone())
        };
        if got_nfd != want_nfd {
            table_failures.push(format!("decomposition of {v:x}"));
        }
        if v >= 0x80 {
            let ascii =
                st::ascii_form(&one).map(|s| s.chars().map(|c| c as u32).collect::<Vec<u32>>());
            if ascii != canon.get(&v).cloned() {
                table_failures.push(format!("ASCII equivalence of {v:x}"));
            }
        }
        if table_failures.len() > 40 {
            break;
        }
    }
    assert!(
        table_failures.is_empty(),
        "{} table disagreements with the Swift runtime:\n{}",
        table_failures.len(),
        table_failures.join("\n")
    );

    let total: usize = counts.values().sum();
    assert!(total >= 23_000, "fixture truncated: {total}");
    assert_eq!(counts.len(), 35, "record kinds: {counts:?}");
    assert!(
        failures.is_empty(),
        "{} of {total} oracle records differ from the original Swift:\n{}",
        failures.len(),
        failures
            .iter()
            .take(60)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
