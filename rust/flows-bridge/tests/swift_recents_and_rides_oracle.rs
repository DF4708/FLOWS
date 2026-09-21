// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for recent places, pasted coordinates, the
//! suggestion blend, ride estimates, rental counters and the emergency
//! radio's station rules: the records produced by the ORIGINAL
//! `DestinationSearch.swift` (`CoordinateInput`, `RecentDestinations`,
//! `DestinationSearch.blend`), `TransitItinerary.swift` (`TransitPlanning`,
//! `RentalCars`) and `TruckerRadio.swift`'s static rules at commit c206b98,
//! linked against the bridge, before that code moved to
//! `flows_core::recents_and_rides` and `flows_core::travel_modes`. Every
//! number is compared bit for bit, every text byte for byte, every order
//! exactly — except rental offices whose order Swift left to its hash seed,
//! which are compared as a group (see [`canonical`]).

use flows_core::recents_and_rides as rr;
use flows_core::travel_modes as tm;
use std::collections::BTreeMap;

const ORIGINAL_COMMIT: &str = "c206b98";
const FS: char = '\u{1F}';
const RS: char = '\u{1E}';

const KINDS: &[(&str, usize)] = &[
    ("ci-parse", 3675),
    ("ds-blend", 900),
    ("rc-consts", 1),
    ("rc-rank", 446),
    ("rc-recommend", 900),
    ("rd-consts", 1),
    ("rd-match", 480),
    ("rd-merged", 700),
    ("rd-score", 600),
    ("rd-store", 989),
    ("tp-ride", 700),
    ("tr-advance", 1872),
    ("tr-guide", 1),
    ("tr-purpose", 25),
    ("tr-state", 792),
];

/// The radio purposes' words, as the Swift facade says them, by
/// [`rr::radio_purpose`] code.
const PURPOSES: [&str; 5] = [
    "traffic",
    "west-coast traffic",
    "emergency help",
    "weather alerts",
    "road work alerts",
];
/// The dial position a car radio tunes for the highway advisory band.
const CAR_BAND: &str = "AM 530 or 1610 kHz";

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
fn b(v: bool) -> &'static str {
    if v {
        "1"
    } else {
        "0"
    }
}
/// `"L<n>:" + rows joined by U+001E`.
fn rows(f: &str) -> Vec<&str> {
    let (n, body) = f
        .strip_prefix('L')
        .and_then(|rest| rest.split_once(':'))
        .unwrap_or_else(|| panic!("bad row list {f}"));
    let n: usize = n.parse().expect("count");
    if n == 0 {
        return Vec::new();
    }
    let out: Vec<&str> = body.split(RS).collect();
    assert_eq!(out.len(), n, "row count in {f}");
    out
}
fn row_text(v: &[String]) -> String {
    format!("L{}:{}", v.len(), v.join(&RS.to_string()))
}
fn check(got: String, want: &str) -> Option<String> {
    (got != want).then(|| format!("got {got}"))
}
fn refs(v: &[String]) -> Vec<&str> {
    v.iter().map(String::as_str).collect()
}

/// A stored recent place: name, latitude, longitude, last use, uses.
fn entry(item: &str) -> rr::Recent {
    let f: Vec<&str> = item.split(FS).collect();
    assert_eq!(f.len(), 5, "entry fields in {item}");
    rr::Recent {
        name: text(f[0]),
        latitude: d(f[1]),
        longitude: d(f[2]),
        last_used: d(f[3]),
        uses: f[4].parse().expect("uses"),
    }
}
fn entry_out(e: &rr::Recent) -> String {
    [
        ht(&e.name),
        hx(e.latitude),
        hx(e.longitude),
        hx(e.last_used),
        e.uses.to_string(),
    ]
    .join(&FS.to_string())
}

fn office_out(name: &str, miles: f64) -> String {
    format!("{}{FS}{}", ht(name), hx(miles))
}

/// The harness's form of a list of rental picks. Within one brand rank,
/// Swift's order is fixed only when every pair of miles orders strictly;
/// any other group came out in Dictionary order, which moves with the hash
/// seed, so it is written sorted by bytes (name, then miles). Returns the
/// rows and the index ranges of those groups.
fn canonical(
    names: &[String],
    miles: &[f64],
    picks: &[usize],
) -> (Vec<String>, Vec<(usize, usize)>) {
    let mut out = Vec::new();
    let mut tied = Vec::new();
    let mut i = 0;
    while i < picks.len() {
        let rank = rr::rental_brand_rank(Some(&names[picks[i]]));
        let mut j = i;
        while j < picks.len() && rr::rental_brand_rank(Some(&names[picks[j]])) == rank {
            j += 1;
        }
        let group = &picks[i..j];
        let strict = group.iter().enumerate().all(|(x, &a)| {
            group[x + 1..]
                .iter()
                .all(|&c| miles[a] < miles[c] || miles[c] < miles[a])
        });
        let mut part: Vec<String> = group
            .iter()
            .map(|&k| office_out(&names[k], miles[k]))
            .collect();
        if !strict {
            part.sort();
            tied.push((i, j));
        }
        out.extend(part);
        i = j;
    }
    (out, tied)
}

/// The recents stores replayed so far, by store number.
type Stores = BTreeMap<usize, Vec<rr::Recent>>;

fn record(f: &[&str], stores: &mut Stores) -> Option<String> {
    match f[0] {
        "ci-parse" => check(
            rr::parse_coordinate(&text(f[1]))
                .map_or_else(|| "-".to_string(), |(a, c)| format!("{}/{}", hx(a), hx(c))),
            f[2],
        ),
        "rd-consts" => check(rr::RECENTS_CAP.to_string(), f[1]),
        "rd-score" => check(
            hx(rr::recent_score(
                f[1].parse().expect("uses"),
                d(f[2]),
                d(f[3]),
            )),
            f[4],
        ),
        "rd-merged" => {
            let list: Vec<rr::Recent> = rows(f[1]).into_iter().map(entry).collect();
            let merged = rr::merged_recents(&list, &entry(f[2]), d(f[3]));
            check(
                row_text(&merged.iter().map(entry_out).collect::<Vec<_>>()),
                f[4],
            )
        }
        "rd-store" => {
            let store: usize = f[1].parse().expect("store");
            let step: usize = f[2].parse().expect("step");
            let list = stores.entry(store).or_default();
            if step == 0 {
                list.clear();
            }
            let name = text(f[3]);
            // A real store records through its own guard and merge.
            if let Some(trimmed) = rr::recordable_name(&name) {
                let new = rr::Recent {
                    name: trimmed.to_string(),
                    latitude: d(f[4]),
                    longitude: d(f[5]),
                    last_used: d(f[6]),
                    uses: 1,
                };
                *list = rr::merged_recents(list, &new, d(f[6]));
            }
            if f[7] == "~" {
                None
            } else {
                check(
                    row_text(&list.iter().map(entry_out).collect::<Vec<_>>()),
                    f[7],
                )
            }
        }
        "rd-match" => {
            let store: usize = f[1].parse().expect("store");
            let list = stores.get(&store).map(Vec::as_slice).unwrap_or_default();
            let names: Vec<&str> = list.iter().map(|e| e.name.as_str()).collect();
            let picks = rr::matching_recents(&names, &text(f[2]), f[3].parse().expect("limit"));
            check(
                row_text(
                    &picks
                        .iter()
                        .map(|&i| entry_out(&list[i]))
                        .collect::<Vec<_>>(),
                ),
                f[4],
            )
        }
        "ds-blend" => {
            let pinned: Vec<String> = rows(f[1]).into_iter().map(text).collect();
            let completions: Vec<String> = rows(f[2]).into_iter().map(text).collect();
            let blended = rr::blend_suggestions(
                &refs(&pinned),
                &refs(&completions),
                f[3].parse().expect("cap"),
            );
            let origin: Vec<String> = blended
                .iter()
                .map(|o| match o {
                    rr::Blended::Pinned(i) => format!("p{i}"),
                    rr::Blended::Completion(i) => format!("c{i}"),
                })
                .collect();
            check(row_text(&origin), f[4])
        }
        "tp-ride" => {
            let mode = text(f[1]);
            check(
                format!(
                    "{}\t{}\t{}",
                    hx(tm::ride_multiplier(&mode)),
                    hx(tm::fallback_mph(&mode)),
                    hx(tm::ride_duration(&mode, od(f[2]), d(f[3])))
                ),
                &f[4..7].join("\t"),
            )
        }
        "rc-consts" => check(
            row_text(&rr::RENTAL_BRANDS.iter().map(|b| ht(b)).collect::<Vec<_>>()),
            f[1],
        ),
        "rc-rank" => {
            let name = otext(f[1]);
            check(
                format!(
                    "{}\t{}",
                    rr::rental_brand_rank(name.as_deref()),
                    rr::rental_booking_site(name.as_deref()).map_or_else(|| "-".to_string(), ht)
                ),
                &f[2..4].join("\t"),
            )
        }
        "rc-recommend" => {
            let offices: Vec<(String, f64)> = rows(f[1])
                .into_iter()
                .map(|item| {
                    let (name, miles) = item.split_once(FS).expect("office");
                    (text(name), d(miles))
                })
                .collect();
            let names: Vec<String> = offices.iter().map(|o| o.0.clone()).collect();
            let miles: Vec<f64> = offices.iter().map(|o| o.1).collect();
            let limit: usize = f[2].parse().expect("limit");
            let full = rr::recommend_rentals(&refs(&names), &miles, usize::MAX);
            let limited = rr::recommend_rentals(&refs(&names), &miles, limit);
            if let Some(problem) = check(row_text(&canonical(&names, &miles, &full).0), f[3]) {
                return Some(format!("full order: {problem}"));
            }
            if limited[..] != full[..limited.len()] {
                return Some("the limited list is not the head of the full one".to_string());
            }
            match f[4].strip_prefix('X') {
                // The limit cut a group Swift ordered by hash seed: only
                // the count is pinned.
                Some(n) => check(limited.len().to_string(), n),
                None => check(row_text(&canonical(&names, &miles, &limited).0), f[4]),
            }
        }
        "tr-guide" => None,
        "tr-purpose" => {
            let name = text(f[1]);
            check(
                format!(
                    "{}\t{}",
                    ht(PURPOSES[usize::from(rr::radio_purpose(&name))]),
                    if rr::radio_is_car_band(&name) {
                        ht(CAR_BAND)
                    } else {
                        "-".to_string()
                    }
                ),
                &f[2..4].join("\t"),
            )
        }
        "tr-advance" => {
            let n = |k: usize| f[k].parse::<i64>().expect("integer");
            check(rr::radio_advance(n(1), n(2), n(3)).to_string(), f[4])
        }
        "tr-state" => {
            let name = text(f[1]);
            let code = rr::radio_state_code(&name);
            let position = rr::radio_position(&name, od(f[2]), od(f[3])).map_or_else(
                || "-".to_string(),
                |(a, c, exact)| format!("{}/{}/{}", hx(a), hx(c), b(exact)),
            );
            check(
                format!("{}\t{position}", hto(code.as_deref())),
                &f[4..6].join("\t"),
            )
        }
        other => Some(format!("unknown record kind {other}")),
    }
}

#[test]
fn rust_reproduces_the_original_swift_recents_and_rides_bit_for_bit() {
    let fixture = include_str!("fixtures/swift_recents_and_rides_oracle.tsv");
    let header = fixture.lines().next().unwrap_or_default();
    assert!(
        header.starts_with("# FROZEN SWIFT ORACLE") && header.contains(ORIGINAL_COMMIT),
        "the fixture header must name the original commit: {header}"
    );
    let mut stores = Stores::new();
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut failures: Vec<String> = Vec::new();
    let mut failed_kinds: BTreeMap<String, usize> = BTreeMap::new();
    for line in fixture
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0].to_string()).or_default() += 1;
        if let Some(got) = record(&f, &mut stores) {
            *failed_kinds.entry(f[0].to_string()).or_default() += 1;
            let shown: String = line.chars().take(200).collect();
            failures.push(format!(
                "{shown}\n    {}",
                got.chars().take(200).collect::<String>()
            ));
        }
    }
    let expected: BTreeMap<String, usize> =
        KINDS.iter().map(|&(k, n)| (k.to_string(), n)).collect();
    assert_eq!(counts, expected, "record kinds and counts");
    let total: usize = counts.values().sum();
    println!(
        "recents-and-rides oracle: {total} records, {} mismatches {failed_kinds:?}",
        failures.len()
    );
    assert!(
        failures.is_empty(),
        "{} of {total} records differ from the Swift original ({failed_kinds:?}); first:\n{}",
        failures.len(),
        failures
            .iter()
            .take(16)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
