// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for places: the records produced by the ORIGINAL
//! `POIRanking`, `PlacesShard`, `PlacesStore`, `POIService` members,
//! `FuelType` costs and `EverydayPlace.attributeID` at commit 0f8894b —
//! compiled with the facades they already called and linked against the
//! bridge — before that code moved to `flows_core::places`. Every number is
//! compared bit for bit, every order and decoded field exactly. The `ps-real`
//! records query the tool-built Wisconsin shard and are checked when this
//! machine has that exact file (by size and stored hash); `u-prefix` pins
//! `String.hasPrefix` as the runtime answers it.

use flows_core::hazard_feeds::states_containing;
use flows_core::places::{self as pl, Candidate, Place, PlacesIndex, Point, RoutePath};
use flows_core::swift_text as st;
use std::collections::{BTreeMap, HashMap};

const ORIGINAL_COMMIT: &str = "0f8894b";
const FS: char = '\u{1F}';
const RS: char = '\u{1E}';

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
fn pts(f: &str) -> Vec<Point> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split(';').map(pt).collect()
}
fn items(f: &str) -> Vec<&str> {
    if f.is_empty() {
        Vec::new()
    } else {
        f.split(RS).collect()
    }
}
fn opt_column(f: &str) -> Vec<Option<f64>> {
    if f.is_empty() {
        Vec::new()
    } else {
        f.split(',').map(od).collect()
    }
}
fn hex_bytes(h: &str) -> Vec<u8> {
    (0..h.len() / 2)
        .map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).expect("hex byte"))
        .collect()
}
fn cands(f: &str) -> Vec<Candidate> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split(',')
        .map(|c| {
            let v: Vec<&str> = c.split('/').collect();
            Candidate {
                ahead_meters: d(v[0]),
                detour_meters: d(v[1]),
                price_per_unit: od(v[2]),
                rating: od(v[3]),
            }
        })
        .collect()
}
fn order_out(o: &[usize]) -> String {
    lst(&o.iter().map(usize::to_string).collect::<Vec<_>>())
}
fn place_out(p: &Place) -> String {
    format!(
        "{}/{}{FS}{}{FS}{}{FS}{}{FS}{}{FS}{}{FS}{}{FS}{}",
        hx(p.lat),
        hx(p.lon),
        p.group,
        ht(&p.name),
        ht(&p.street),
        ht(&p.city),
        ht(&p.website),
        ht(&p.tel),
        p.postcode
    )
}
fn places_out(ps: &[Place]) -> String {
    ps.iter()
        .map(place_out)
        .collect::<Vec<_>>()
        .join(&RS.to_string())
}
fn groups(f: &str) -> Vec<u8> {
    list(f).iter().map(|g| g.parse().expect("group")).collect()
}
/// A service item: its name (`None` for nil) and its point.
fn service_items(f: &str) -> Vec<(Option<String>, Point)> {
    items(f)
        .into_iter()
        .map(|it| {
            let v: Vec<&str> = it.split(FS).collect();
            (otext(v[0]), pt(v[1]))
        })
        .collect()
}
fn row_key(item: &(Option<String>, Point)) -> String {
    pl::attribute_id(item.0.as_deref().unwrap_or("?"), item.1 .0, item.1 .1)
}
fn query(index: &PlacesIndex, data: &[u8], f: &[&str]) -> Vec<Place> {
    index
        .places_near(
            data,
            pt(f[0]),
            &groups(f[1]),
            d(f[2]),
            f[3].parse().expect("limit"),
        )
        .into_iter()
        .map(|(r, _)| index.place(data, r).expect("a record the query found"))
        .collect()
}

/// The tool-built Wisconsin shard and its tag (size/stored hash), when present.
fn real_shard() -> Option<(String, Vec<u8>)> {
    let path = std::env::var("FLOWS_PLACES_WI").unwrap_or_else(|_| {
        format!(
            "{}/Documents/Coding_Files/FLOWS/data/places/WI.fps",
            std::env::var("HOME").unwrap_or_default()
        )
    });
    let data = std::fs::read(path).ok()?;
    let stored = u64::from_le_bytes(data.get(20..28)?.try_into().ok()?);
    Some((format!("{}/{:x}", data.len(), stored), data))
}

#[test]
fn rust_places_match_the_frozen_swift_oracle() {
    let fixture = include_str!("fixtures/swift_places_oracle.tsv");
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
    let mut routes: HashMap<String, (Vec<Point>, RoutePath)> = HashMap::new();
    let mut shards: HashMap<String, Vec<u8>> = HashMap::new();
    let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
    let mut mismatches: Vec<String> = Vec::new();
    let real = real_shard();
    let real_index = real.as_ref().and_then(|(_, data)| PlacesIndex::parse(data));
    let mut real_checked = 0;
    let mut total = 0;
    for line in fixture
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        total += 1;
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0]).or_default() += 1;
        let (want, got): (String, String) = match f[0] {
            "rp-route" => {
                let coords = pts(f[2]);
                let path = RoutePath::new(coords.clone());
                let got = lst(&path.cumulative().iter().map(|&x| hx(x)).collect::<Vec<_>>());
                routes.insert(f[1].to_string(), (coords, path));
                (f[3].to_string(), got)
            }
            "rp-near" => {
                let got = routes[f[1]]
                    .1
                    .nearest(pt(f[2]))
                    .map_or_else(|| "-".to_string(), |(i, off)| format!("{i}/{}", hx(off)));
                (f[3].to_string(), got)
            }
            "rk-annot" => {
                let got = pl::annotate(&routes[f[1]].1, pt(f[2]), d(f[3]), od(f[4]), od(f[5]))
                    .map_or_else(
                        || "-".to_string(),
                        |c| {
                            [
                                hx(c.ahead_meters),
                                hx(c.detour_meters),
                                hdo(c.price_per_unit),
                                hdo(c.rating),
                            ]
                            .join("/")
                        },
                    );
                (f[6].to_string(), got)
            }
            "rk-food" => (
                f[3].to_string(),
                order_out(&pl::rank_food(&cands(f[1]), d(f[2]))),
            ),
            "rk-fuel" => (
                f[5].to_string(),
                order_out(&pl::rank_fuel(&cands(f[1]), d(f[2]), d(f[3]), d(f[4]))),
            ),
            "rk-hotels" => (
                f[4].to_string(),
                order_out(&pl::rank_hotels(&cands(f[1]), d(f[2]), d(f[3]))),
            ),
            "rk-parking" => {
                let tiers: Vec<i64> = list(f[2])
                    .iter()
                    .map(|t| t.parse().expect("tier"))
                    .collect();
                (
                    f[4].to_string(),
                    order_out(&pl::rank_parking(&cands(f[1]), &tiers, d(f[3]))),
                )
            }
            "rk-stores" => {
                let names: Vec<Option<String>> = items(f[2]).into_iter().map(otext).collect();
                let ranks: Vec<usize> = names
                    .iter()
                    .map(|n| pl::store_market_share_rank(n.as_deref()))
                    .collect();
                (
                    f[4].to_string(),
                    order_out(&pl::rank_stores(&cands(f[1]), &ranks, d(f[3]))),
                )
            }
            "pk-tier" => (
                f[2].to_string(),
                pl::parking_cost_tier(otext(f[1]).as_deref()).to_string(),
            ),
            "ms-rank" => (
                f[2].to_string(),
                pl::store_market_share_rank(otext(f[1]).as_deref()).to_string(),
            ),
            "ms-order" => (
                f[1].to_string(),
                lst(&pl::STORE_MARKET_SHARE_ORDER
                    .iter()
                    .map(|b| ht(b))
                    .collect::<Vec<_>>()),
            ),
            "rk-consts" => (
                f[1..].join("\t"),
                [
                    pl::BACKTRACK_TOLERANCE_METERS,
                    pl::MAX_DETOUR_METERS,
                    pl::DETOUR_SPEED_MPS,
                    pl::DOLLARS_PER_HOUR,
                    pl::AVERAGE_NIGHTLY_PRICE,
                ]
                .map(hx)
                .join("\t"),
            ),
            "fuel" => {
                let code: u8 = f[1].parse().expect("fuel code");
                let got = pl::fuel_costs(code)
                    .map_or_else(|| "-".to_string(), |(a, b)| format!("{}\t{}", hx(a), hx(b)));
                (format!("{}\t{}", f[3], f[4]), got)
            }
            "ps-shard" => {
                shards.insert(f[1].to_string(), hex_bytes(f[2]));
                continue;
            }
            "ps-parse" => (
                f[2].to_string(),
                if PlacesIndex::parse(&shards[f[1]]).is_some() {
                    "ok"
                } else {
                    "-"
                }
                .to_string(),
            ),
            "ps-near" => {
                let data = &shards[f[1]];
                let index = PlacesIndex::parse(data).expect("a shard the Swift parsed");
                (f[6].to_string(), places_out(&query(&index, data, &f[2..6])))
            }
            "ps-key" => {
                let got = pl::cell_key(f[1].parse().expect("lat5"), f[2].parse().expect("lon5"))
                    .map_or_else(|| "-".to_string(), |k| k.to_string());
                (f[3].to_string(), got)
            }
            "ps-real" => match (&real, &real_index) {
                (Some((tag, data)), Some(index)) if tag == f[1] => {
                    real_checked += 1;
                    (f[6].to_string(), places_out(&query(index, data, &f[2..6])))
                }
                _ => continue,
            },
            "st-states" => (
                f[2].to_string(),
                lst(&states_containing(pt(f[1]))
                    .iter()
                    .map(|s| ht(s))
                    .collect::<Vec<_>>()),
            ),
            "store-q" => {
                let center = pt(f[1]);
                let wanted_groups = groups(f[2]);
                let limit: i64 = f[4].parse().expect("limit");
                let mut found: Vec<Place> = Vec::new();
                if !wanted_groups.is_empty() {
                    for state in states_containing(center) {
                        let Some(data) = shards.get(&format!("store-{state}")) else {
                            continue;
                        };
                        let Some(index) = PlacesIndex::parse(data) else {
                            continue;
                        };
                        found.extend(query(&index, data, &f[1..5]));
                    }
                }
                let points: Vec<Point> = found.iter().map(|p| (p.lat, p.lon)).collect();
                let merged: Vec<Place> = pl::rank_by_distance(&points, center, limit)
                    .into_iter()
                    .map(|(i, _)| found[i].clone())
                    .collect();
                (f[5].to_string(), places_out(&merged))
            }
            "svc-groups" => {
                let got = pl::shard_groups(f[1].parse().expect("kind")).map_or_else(
                    || "-".to_string(),
                    |g| lst(&g.iter().map(u8::to_string).collect::<Vec<_>>()),
                );
                (f[3].to_string(), got)
            }
            "svc-rank" => {
                let k: u8 = f[1].parse().expect("kind");
                let fuel: Option<u8> = (f[2] != "-").then(|| f[2].parse().expect("fuel"));
                let position = (f[4] != "-").then(|| pt(f[4]));
                let its = service_items(f[6]);
                let points: Vec<Point> = its.iter().map(|i| i.1).collect();
                let rows: Vec<String> = if f[5] == "-" {
                    position.map_or_else(Vec::new, |p| {
                        pl::rank_by_distance(&points, p, pl::RANKED_ROWS as i64)
                            .into_iter()
                            .map(|(i, dist)| format!("{i}/{}/{}/-/-", hx(dist), hx(0.0)))
                            .collect()
                    })
                } else {
                    let names: Vec<Option<&str>> = its.iter().map(|i| i.0.as_deref()).collect();
                    pl::rank_along(
                        &routes[f[5]].1,
                        k,
                        fuel,
                        f[3] == "1",
                        position,
                        &points,
                        &opt_column(f[7]),
                        &opt_column(f[8]),
                        &names,
                    )
                    .into_iter()
                    .map(|r| {
                        format!(
                            "{}/{}/{}/{}/{}",
                            r.item,
                            hx(r.ahead_meters),
                            hx(r.detour_meters),
                            hdo(r.price_per_unit),
                            hdo(r.rating)
                        )
                    })
                    .collect()
                };
                (f[9].to_string(), rows.join(","))
            }
            "svc-merged" => {
                let ev: Vec<String> = service_items(f[1]).iter().map(row_key).collect();
                let net: Vec<String> = service_items(f[2]).iter().map(row_key).collect();
                let ev_refs: Vec<&str> = ev.iter().map(String::as_str).collect();
                let net_refs: Vec<&str> = net.iter().map(String::as_str).collect();
                let got: Vec<String> = pl::merge_everyday_first(&ev_refs, &net_refs)
                    .into_iter()
                    .map(|(source, i)| format!("{}{i}", if source == 0 { 'e' } else { 'n' }))
                    .collect();
                (f[3].to_string(), lst(&got))
            }
            "svc-rowkey" => (f[2].to_string(), ht(&row_key(&service_items(f[1])[0]))),
            "svc-corridor" => {
                let coords = &routes[f[1]].0;
                let start = if f[2] == "-" {
                    0
                } else {
                    pl::first_nearest(coords, pt(f[2])).unwrap_or(0)
                };
                (f[3].to_string(), start.to_string())
            }
            "ev-attr" => (
                f[4].to_string(),
                ht(&pl::attribute_id(&text(f[1]), d(f[2]), d(f[3]))),
            ),
            "u-prefix" => (
                f[3].to_string(),
                if st::has_prefix(&text(f[1]), &text(f[2])) {
                    "1"
                } else {
                    "0"
                }
                .to_string(),
            ),
            other => panic!("unknown record kind {other}"),
        };
        if want != got {
            mismatches.push(format!(
                "{}\n  want {}\n  got  {}",
                line.chars().take(240).collect::<String>(),
                want.chars().take(400).collect::<String>(),
                got.chars().take(400).collect::<String>()
            ));
        }
    }
    println!(
        "places oracle: {total} records, {counts:?}; real-shard records checked: {real_checked}"
    );
    assert_eq!(total, claimed, "every record was read");
    for kind in [
        "rp-near",
        "rk-food",
        "rk-fuel",
        "rk-hotels",
        "rk-parking",
        "rk-stores",
        "ps-near",
        "store-q",
        "svc-rank",
        "svc-merged",
        "u-prefix",
    ] {
        assert!(
            counts.get(kind).copied().unwrap_or(0) > 0,
            "no {kind} records"
        );
    }
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
