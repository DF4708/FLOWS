// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the words FLOWS reads: the records produced by
//! the ORIGINAL `RouteAttributes`, `VehicleLink`, `VoiceReply` (`YesNoWords`,
//! `VoiceCommands`, `VoicePick`), `BroadcastRadio` and `RadioBrowser` at commit
//! b4b8cd1, linked against the bridge, before that code moved to
//! `flows_core::tags_and_replies`. Every number is compared bit for bit, every
//! text byte for byte, every choice and order exactly; the runtime's letter
//! table is checked over every scalar.

use flows_core::swift_text as st;
use flows_core::tags_and_replies as tr;
use std::collections::BTreeMap;

const ORIGINAL_COMMIT: &str = "b4b8cd1";
const FS: char = '\u{1F}';
const RS: char = '\u{1E}';

const KINDS: &[(&str, usize)] = &[
    ("br-dial", 468),
    ("br-kind", 791),
    ("br-kinds", 1),
    ("br-ranked", 500),
    ("ra-clear", 370),
    ("ra-consts", 1),
    ("ra-flood", 111),
    ("ra-grade", 500),
    ("ra-weight", 353),
    ("rb-consts", 1),
    ("rb-genre", 268),
    ("rb-merged", 500),
    ("rb-mirror", 163),
    ("rb-ranked", 300),
    ("rb-rows", 400),
    ("rb-servers", 150),
    ("rb-state", 122),
    ("u-letter", 1),
    ("vl-consts", 1),
    ("vl-fuel", 285),
    ("vl-obd", 81),
    ("vl-tpms", 700),
    ("vp-choose", 900),
    ("vp-place", 900),
    ("yn", 594),
    ("yn-words", 1),
];

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn od(f: &str) -> Option<f64> {
    (f != "-").then(|| d(f))
}
fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}
fn hdo(x: Option<f64>) -> String {
    x.map_or_else(|| "-".to_string(), hx)
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
fn bo(v: Option<bool>) -> &'static str {
    v.map_or("-", b)
}
/// `"N<n>:" + items joined by U+001E`.
fn items(f: &str) -> Vec<&str> {
    let (n, body) = f
        .strip_prefix('N')
        .and_then(|rest| rest.split_once(':'))
        .unwrap_or_else(|| panic!("bad item list {f}"));
    let n: usize = n.parse().expect("count");
    if n == 0 {
        return Vec::new();
    }
    let out: Vec<&str> = body.split(RS).collect();
    assert_eq!(out.len(), n, "item count in {f}");
    out
}
fn texts(f: &str) -> Vec<String> {
    items(f).into_iter().map(text).collect()
}
fn lst(v: &[usize]) -> String {
    let parts: Vec<String> = v.iter().map(ToString::to_string).collect();
    format!("L{}:{}", v.len(), parts.join(","))
}
fn check(got: String, want: &str) -> Option<String> {
    (got != want).then(|| format!("got {got}"))
}
fn refs(v: &[String]) -> Vec<&str> {
    v.iter().map(String::as_str).collect()
}
fn point(f: &str) -> Option<(f64, f64)> {
    (f != "-").then(|| {
        let (a, c) = f.split_once('/').expect("point");
        (d(a), d(c))
    })
}

fn pick_code(o: tr::PickOutcome) -> String {
    match o {
        tr::PickOutcome::Picked(i) => format!("p{i}"),
        tr::PickOutcome::Declined => "d".to_string(),
        tr::PickOutcome::Unclear => "u".to_string(),
    }
}
fn place_code(o: tr::PlaceOutcome) -> String {
    match o {
        tr::PlaceOutcome::Picked(i) => format!("p{i}"),
        tr::PlaceOutcome::SwitchCuisine(i) => format!("s{i}"),
        tr::PlaceOutcome::BackToCuisine => "b".to_string(),
        tr::PlaceOutcome::Declined => "d".to_string(),
        tr::PlaceOutcome::Unclear => "u".to_string(),
    }
}
fn kind_index(k: tr::RadioKind) -> usize {
    tr::RadioKind::ALL
        .iter()
        .position(|&x| x == k)
        .expect("every kind is listed")
}

/// A station row's six fields: name, url, genre (or tags), votes, latitude,
/// longitude.
fn station_fields(item: &str) -> Vec<&str> {
    let f: Vec<&str> = item.split(FS).collect();
    assert_eq!(f.len(), 6, "station fields in {item}");
    f
}

/// Name and URL pairs as the merge reads them.
fn directory_view(list: &Option<Vec<(String, String)>>) -> Option<Vec<tr::DirectoryStation<'_>>> {
    list.as_ref().map(|l| {
        l.iter()
            .map(|(name, url)| tr::DirectoryStation { name, url })
            .collect()
    })
}

fn record(f: &[&str]) -> Option<String> {
    match f[0] {
        "u-letter" => {
            let ranges: Vec<(u32, u32)> = f[2]
                .split(',')
                .map(|r| {
                    let (lo, hi) = r.split_once('-').expect("range");
                    (
                        u32::from_str_radix(lo, 16).expect("lo"),
                        u32::from_str_radix(hi, 16).expect("hi"),
                    )
                })
                .collect();
            assert_eq!(ranges.len(), f[1].parse::<usize>().expect("count"));
            // One walk over the scalars with a cursor into the sorted ranges.
            let mut next = 0usize;
            let wrong: Vec<u32> = (0..=0x10_FFFFu32)
                .filter_map(char::from_u32)
                .filter(|&c| {
                    let v = c as u32;
                    while next < ranges.len() && ranges[next].1 < v {
                        next += 1;
                    }
                    let want = next < ranges.len() && ranges[next].0 <= v;
                    st::is_letter_scalar(c) != want
                })
                .map(|c| c as u32)
                .take(8)
                .collect();
            (!wrong.is_empty()).then(|| format!("letter table differs at {wrong:x?}"))
        }
        "ra-grade" => {
            let (n, body) = f[1]
                .strip_prefix('N')
                .and_then(|r| r.split_once(':'))
                .expect("elevations");
            let elevations: Vec<Option<f64>> = if n == "0" {
                Vec::new()
            } else {
                body.split(',').map(od).collect()
            };
            check(hdo(tr::max_grade_percent(&elevations, d(f[2]))), f[3])
        }
        "ra-clear" => check(hdo(tr::clearance_meters(&text(f[1]))), f[2]),
        "ra-weight" => check(hdo(tr::weight_limit_lbs(&text(f[1]))), f[2]),
        "ra-flood" => check(
            b(tr::is_high_risk_flood_zone(&text(f[1]))).to_string(),
            f[2],
        ),
        "ra-consts" => check(
            format!(
                "{}\t{}",
                hx(tr::LOW_CLEARANCE_THRESHOLD_METERS),
                hx(tr::WEIGHT_LIMIT_CAP_LBS)
            ),
            &f[1..3].join("\t"),
        ),
        "vl-tpms" => {
            let name = otext(f[1]);
            let data: Option<Vec<u8>> = (f[2] != "-").then(|| {
                (0..f[2].len() / 2)
                    .map(|i| u8::from_str_radix(&f[2][2 * i..2 * i + 2], 16).expect("byte"))
                    .collect()
            });
            let got = tr::parse_tpms_advertisement(name.as_deref(), data.as_deref()).map_or_else(
                || "-".to_string(),
                |r| {
                    [
                        ht(&format!("Tire {}", r.position)),
                        hx(r.psi),
                        hx(r.celsius),
                        hx(tr::displayed_psi(r.psi)),
                    ]
                    .join(&FS.to_string())
                },
            );
            check(got, f[3])
        }
        "vl-fuel" => check(hdo(tr::parse_fuel_reply(&text(f[1]))), f[2]),
        "vl-obd" => check(b(tr::looks_like_obd_adapter(&text(f[1]))).to_string(), f[2]),
        "vl-consts" => check(hx(tr::LOW_PRESSURE_PSI), f[1]),
        "yn" => {
            let reply = text(f[1]);
            check(
                format!(
                    "{}\t{}",
                    bo(tr::interpret_yes_no(&reply)),
                    b(tr::wants_weather_radio(&reply))
                ),
                &f[2..4].join("\t"),
            )
        }
        "yn-words" => check(
            [&tr::YES_WORDS[..], &tr::NO_WORDS[..], &tr::BACK_WORDS[..]]
                .iter()
                .map(|w| {
                    format!(
                        "N{}:{}",
                        w.len(),
                        w.iter()
                            .map(|x| ht(x))
                            .collect::<Vec<_>>()
                            .join(&RS.to_string())
                    )
                })
                .collect::<Vec<_>>()
                .join("\t"),
            &f[1..4].join("\t"),
        ),
        "vp-choose" => {
            let options = texts(f[2]);
            check(pick_code(tr::choose(&text(f[1]), &refs(&options))), f[3])
        }
        "vp-place" => {
            let places = texts(f[2]);
            let cuisines = texts(f[3]);
            check(
                place_code(tr::place_reply(
                    &text(f[1]),
                    &refs(&places),
                    &refs(&cuisines),
                )),
                f[4],
            )
        }
        "br-kinds" => {
            let got_kinds: Vec<String> = tr::RadioKind::ALL
                .iter()
                .map(|k| {
                    k.tag_words()
                        .iter()
                        .map(|w| ht(w))
                        .collect::<Vec<_>>()
                        .join(&FS.to_string())
                })
                .collect();
            let want_kinds: Vec<String> = items(f[1])
                .into_iter()
                .map(|item| {
                    item.split_once(FS)
                        .map_or("", |(_, words)| words)
                        .to_string()
                })
                .collect();
            let order: Vec<usize> = tr::RadioKind::MATCH_ORDER
                .iter()
                .map(|&k| kind_index(k))
                .collect();
            check(
                format!("{}\t{}", got_kinds.join("|"), lst(&order)),
                &format!("{}\t{}", want_kinds.join("|"), f[2]),
            )
        }
        "br-kind" => check(
            tr::kind_for_tags(&text(f[1]))
                .map_or_else(|| "-".to_string(), |k| kind_index(k).to_string()),
            f[2],
        ),
        "br-dial" => check(hto(tr::dial_label(&text(f[1])).as_deref()), f[2]),
        "br-ranked" => {
            let stations: Vec<tr::RadioStation> = items(f[1])
                .into_iter()
                .map(|item| {
                    let g: Vec<&str> = item.split(FS).collect();
                    tr::RadioStation {
                        lat: od(g[0]),
                        lon: od(g[1]),
                        bitrate: g[2].parse().expect("bitrate"),
                    }
                })
                .collect();
            check(lst(&tr::ranked_stations(&stations, point(f[2]))), f[3])
        }
        "rb-mirror" => check(b(tr::is_allowed_mirror(&text(f[1]))).to_string(), f[2]),
        "rb-consts" => {
            let genres: Vec<String> = texts(f[2]);
            let countries: Vec<String> = texts(f[3]);
            let same = f[1] == tr::NEARBY_RADIUS_METERS.to_string()
                && refs(&genres) == tr::COMMON_GENRES
                && refs(&countries) == tr::ALLOWED_MIRROR_COUNTRIES;
            (!same).then(|| "constants differ".to_string())
        }
        "rb-genre" => check(ht(&tr::genre_words(&text(f[1]))), f[2]),
        "rb-state" => check(hto(tr::state_name(&text(f[1]))), f[2]),
        "rb-merged" => {
            let parse = |field: &str| -> Option<Vec<(String, String)>> {
                (field != "-").then(|| {
                    items(field)
                        .into_iter()
                        .map(|item| {
                            let (name, url) = item.split_once(FS).expect("station");
                            (text(name), text(url))
                        })
                        .collect()
                })
            };
            let (names, tags) = (parse(f[1]), parse(f[2]));
            let (name_view, tag_view) = (directory_view(&names), directory_view(&tags));
            check(
                tr::merged_stations(name_view.as_deref(), tag_view.as_deref())
                    .map_or_else(|| "-".to_string(), |m| lst(&m)),
                f[3],
            )
        }
        "rb-rows" => {
            let rows: Vec<Vec<String>> = items(f[1])
                .into_iter()
                .map(|item| {
                    station_fields(item)
                        .into_iter()
                        .map(ToString::to_string)
                        .collect()
                })
                .collect();
            let names: Vec<Option<String>> = rows.iter().map(|r| otext(&r[0])).collect();
            let urls: Vec<Option<String>> = rows.iter().map(|r| otext(&r[1])).collect();
            let views: Vec<tr::DirectoryRow<'_>> = names
                .iter()
                .zip(&urls)
                .map(|(name, url)| tr::DirectoryRow {
                    name: name.as_deref(),
                    url: url.as_deref(),
                })
                .collect();
            let kept: Vec<String> = tr::kept_station_rows(&views)
                .into_iter()
                .map(|(i, name)| {
                    [
                        ht(name),
                        rows[i][1].clone(),
                        ht(&tr::genre_words(&text(&rows[i][2]))),
                        rows[i][3].clone(),
                        rows[i][4].clone(),
                        rows[i][5].clone(),
                    ]
                    .join(&FS.to_string())
                })
                .collect();
            check(
                format!("N{}:{}", kept.len(), kept.join(&RS.to_string())),
                f[2],
            )
        }
        "rb-servers" => {
            let names: Vec<Option<String>> = items(f[1]).into_iter().map(otext).collect();
            let views: Vec<Option<&str>> = names.iter().map(Option::as_deref).collect();
            let kept: Vec<String> = tr::unique_server_names(&views)
                .into_iter()
                .map(|i| ht(views[i].expect("kept names are present")))
                .collect();
            check(
                format!("N{}:{}", kept.len(), kept.join(&RS.to_string())),
                f[2],
            )
        }
        "rb-ranked" => {
            let rows: Vec<Vec<&str>> = items(f[1]).into_iter().map(station_fields).collect();
            let urls: Vec<String> = rows.iter().map(|r| text(r[1])).collect();
            let stations: Vec<tr::RadioStation> = rows
                .iter()
                .map(|r| tr::RadioStation {
                    lat: od(r[4]),
                    lon: od(r[5]),
                    bitrate: r[3].parse().expect("votes"),
                })
                .collect();
            let position = point(f[2]).expect("position");
            check(
                lst(&tr::ranked_nearest(&stations, &refs(&urls), position)),
                f[3],
            )
        }
        other => Some(format!("unknown record kind {other}")),
    }
}

#[test]
fn rust_reproduces_the_original_swift_tags_and_replies_bit_for_bit() {
    let fixture = include_str!("fixtures/swift_tags_and_replies_oracle.tsv");
    let header = fixture.lines().next().unwrap_or_default();
    assert!(
        header.starts_with("# FROZEN SWIFT ORACLE") && header.contains(ORIGINAL_COMMIT),
        "the fixture header must name the original commit: {header}"
    );
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut failures: Vec<String> = Vec::new();
    let mut failed_kinds: BTreeMap<String, usize> = BTreeMap::new();
    for line in fixture
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0].to_string()).or_default() += 1;
        if let Some(got) = record(&f) {
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
        "tags-and-replies oracle: {total} records, {} mismatches {failed_kinds:?}",
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
