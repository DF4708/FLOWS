// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the map's hazard badges: records from the
//! ORIGINAL `BadgeClustering` at commit ORIGINAL_COMMIT, before the rules
//! moved to `flows_core::badges`. Every answer must be the same bits and the
//! same picks.

use flows_core::badges::{
    cluster, declutter, is_warning, labels, near_same_kind, same_hazard, unshown, Item, Point,
};
use flows_core::geo::meters;
use std::collections::HashMap;

const ORIGINAL_COMMIT: &str = "6343007";
const RECORDS: [(&str, usize); 6] = [
    ("k", 587),
    ("d", 587),
    ("b", 500),
    ("w", 108),
    ("s", 490),
    ("u", 700),
];

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}

fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}

fn item_str(i: &Item) -> String {
    format!("{}:{}:{}:{}", hx(i.lat), hx(i.lon), i.kind, hx(i.score))
}

fn items_str<'a>(a: impl IntoIterator<Item = &'a Item>) -> String {
    a.into_iter().map(item_str).collect::<Vec<_>>().join(",")
}

fn parse_items(f: &str) -> Vec<Item> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split(',')
        .map(|p| {
            let v: Vec<&str> = p.split(':').collect();
            Item {
                lat: d(v[0]),
                lon: d(v[1]),
                kind: v[2].parse().expect("kind"),
                score: d(v[3]),
            }
        })
        .collect()
}

fn parse_areas(f: &str) -> Vec<Vec<Point>> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split('|')
        .map(|r| {
            if r.is_empty() {
                return Vec::new();
            }
            r.split(';')
                .map(|p| {
                    let (a, b) = p.split_once(':').expect("lat:lon");
                    (d(a), d(b))
                })
                .collect()
        })
        .collect()
}

fn text(f: &str) -> Option<String> {
    if f == "-" {
        return None;
    }
    let bytes: Vec<u8> = (0..f.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&f[i..i + 2], 16).expect("hex byte"))
        .collect();
    Some(String::from_utf8(bytes).expect("utf-8"))
}

fn b01(b: bool) -> &'static str {
    if b {
        "1"
    } else {
        "0"
    }
}

#[test]
fn rust_matches_the_frozen_swift_badge_clustering_oracle() {
    let fixture = include_str!("fixtures/swift_badge_clustering_oracle.tsv");
    assert!(
        fixture.contains(ORIGINAL_COMMIT),
        "the header names the original commit"
    );
    let mut counts: HashMap<&str, usize> = HashMap::new();
    let mut bad = Vec::new();
    for line in fixture.lines().filter(|l| !l.starts_with('#')) {
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0]).or_default() += 1;
        let got = match f[0] {
            "k" => {
                let items = parse_items(f[2]);
                let badges: Vec<Item> = cluster(&items, d(f[1]))
                    .iter()
                    .map(|b| Item {
                        lat: b.lat,
                        lon: b.lon,
                        ..items[b.seed]
                    })
                    .collect();
                items_str(&badges)
            }
            "d" => {
                let items = parse_items(f[2]);
                items_str(declutter(&items, d(f[1])).iter().map(|&i| &items[i]))
            }
            "b" => {
                let badges = parse_items(f[2]);
                let labelled = parse_items(f[3]);
                labels(&badges, &labelled, d(f[1]))
                    .iter()
                    .map(|l| l.map_or("-".to_owned(), |i| format!("L{i}")))
                    .collect::<Vec<_>>()
                    .join(",")
            }
            "w" => b01(is_warning(&text(f[1]).expect("event"))).to_owned(),
            "s" => {
                let (b, s) = (text(f[1]), text(f[2]));
                b01(same_hazard(b.as_deref(), s.as_deref())).to_owned()
            }
            "u" => {
                let badges = parse_items(f[3]);
                let shown = parse_items(f[4]);
                let areas = parse_areas(f[5]);
                let default_same = f[2] == "d";
                let kept = unshown(
                    &badges,
                    &shown,
                    &areas,
                    d(f[1]),
                    |b| badges[b].score.to_bits() & 1 == 1,
                    |b, s| {
                        default_same
                            || (badges[b].score.to_bits() ^ shown[s].score.to_bits()) & 2 == 0
                    },
                );
                items_str(kept.iter().map(|&i| &badges[i]))
            }
            other => panic!("unknown record kind {other}"),
        };
        if got != *f.last().expect("answer") {
            bad.push(format!("{line}\n  rust: {got}"));
        }
    }
    for (k, n) in RECORDS {
        assert_eq!(counts.get(k).copied().unwrap_or(0), n, "{k} records");
    }
    let total: usize = RECORDS.iter().map(|(_, n)| n).sum();
    assert!(
        bad.is_empty(),
        "{} of {total} records differ:\n{}",
        bad.len(),
        bad.iter()
            .take(6)
            .map(|b| b.chars().take(1200).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n")
    );
}

fn at(lat: f64, lon: f64, kind: i64, score: f64) -> Item {
    Item {
        lat,
        lon,
        kind,
        score,
    }
}

fn apart(a: &Item, b: &Item) -> f64 {
    meters(a.lat, a.lon, b.lat, b.lon)
}

/// An item exactly the spacing from a seed is not close enough to join it,
/// in the linear scan and in the grid alike (the oracle cannot place a
/// point at exactly the spacing on the grid's path). One double more and it
/// joins.
#[test]
fn an_item_exactly_the_spacing_away_seeds_its_own_badge() {
    let seed = at(40.0, -100.0, 0, 2.0);
    let other = at(40.01, -99.93, 0, 1.0);
    let sep = apart(&seed, &other);
    for fillers in [0usize, 62, 100] {
        let mut items = vec![seed, other];
        for k in 0..fillers {
            let k = i64::try_from(k).expect("small");
            items.push(at(40.0, 10.0 + k as f64, k + 1, 0.5));
        }
        let n = items.len();
        assert_eq!(cluster(&items, sep).len(), n, "{fillers} fillers");
        assert_eq!(
            cluster(&items, sep.next_up()).len(),
            n - 1,
            "{fillers} fillers"
        );
    }
}

/// A labelled point exactly as near to two badges of its kind joins the
/// first of them.
#[test]
fn a_tie_for_the_nearest_badge_goes_to_the_first() {
    let badges = [at(0.0, -1.0, 3, 1.0), at(0.0, 1.0, 3, 1.0)];
    let point = at(0.0, 0.0, 3, 1.0);
    assert_eq!(
        apart(&badges[0], &point).to_bits(),
        apart(&badges[1], &point).to_bits()
    );
    assert_eq!(labels(&badges, &[point], 1e9), vec![Some(0), None]);
    let flipped = [badges[1], badges[0]];
    assert_eq!(labels(&flipped, &[point], 1e9), vec![Some(0), None]);
}

/// `near_same_kind` names exactly the pairs `unshown` asks its `same` rule
/// about, so a caller that answers only those pairs answers every question;
/// a shown badge exactly `merge` away is not near.
#[test]
fn near_same_kind_names_exactly_the_pairs_unshown_asks_about() {
    let badges = [
        at(40.0, -100.0, 0, 1.0),
        at(40.2, -100.1, 1, 2.0),
        at(41.0, -99.0, 0, 3.0),
    ];
    let shown = [
        at(40.01, -99.93, 0, 1.0),
        at(40.0, -100.0, 1, 1.0),
        at(40.2, -100.1, 1, 1.0),
        at(40.0, -100.05, 0, 1.0),
        at(41.0, -99.0, 2, 1.0),
    ];
    let exact = apart(&badges[0], &shown[0]);
    for merge in [
        exact,
        exact.next_up(),
        0.0,
        1e3,
        3e4,
        2e5,
        f64::INFINITY,
        f64::NAN,
    ] {
        let mut asked = Vec::new();
        let _ = unshown(
            &badges,
            &shown,
            &[],
            merge,
            |_| true,
            |b, s| {
                asked.push((b, s));
                false
            },
        );
        assert_eq!(
            near_same_kind(&badges, &shown, merge),
            asked,
            "merge {merge}"
        );
    }
    assert!(!near_same_kind(&badges, &shown, exact).contains(&(0, 0)));
    assert!(near_same_kind(&badges, &shown, exact.next_up()).contains(&(0, 0)));
}
