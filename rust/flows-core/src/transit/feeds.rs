// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Which city's own timetable to fetch for the last leg of a trip.
//!
//! The table ([`super::feeds_table::CITY_FEEDS`]) is every static GTFS feed
//! in the US, Canada and Mexico downloadable without an API key, compiled in
//! from MobilityData's Mobility Database catalog by `flows-train`'s
//! `feeds-table`. The owner's rule (2026-09-29): API-key-free feeds are on by
//! default. The only ones left out are the few whose own licence forbids
//! commercial use without written permission — FLOWS earns referral fees —
//! and they stay in the table, marked, for the day permission is on file.
//!
//! A feed's box is where its SERVICE ENDS UP, not where it runs: El Paso's
//! box reaches across the river into Ciudad Juárez, which its buses do not.
//! A box is a cheap, honest first cut — the timetable itself then decides,
//! because a feed whose stops are nowhere near the trip simply produces no
//! connection.

use super::feeds_table::CITY_FEEDS;

/// One city's timetable, as the catalog describes it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CityFeed {
    /// The catalog's id — "mdb-2127", "tld-764". Unique, and safe as a file name.
    pub id: &'static str,
    pub country: &'static str,
    pub region: &'static str,
    pub city: &'static str,
    /// Who publishes it. Sometimes a list: one feed can carry many agencies.
    pub provider: &'static str,
    pub name: &'static str,
    /// Where to download it: the publisher's link, or the catalog's mirror.
    pub url: &'static str,
    /// The catalog's mirror of the latest copy (may be empty).
    pub mirror: &'static str,
    /// The publisher's terms, when the catalog links them (may be empty).
    pub licence: &'static str,
    pub official: bool,
    /// The licence forbids commercial use without written permission.
    pub needs_permission: bool,
    /// Actively maintained in the catalog. Inactive ones are kept, ranked last.
    pub active: bool,
    pub min_lat: f64,
    pub max_lat: f64,
    pub min_lon: f64,
    pub max_lon: f64,
}

impl CityFeed {
    /// Whether the feed's box holds a point.
    #[must_use]
    pub fn covers(&self, lat: f64, lon: f64) -> bool {
        (self.min_lat..=self.max_lat).contains(&lat) && (self.min_lon..=self.max_lon).contains(&lon)
    }

    /// Box size in square degrees — only ever compared with another's.
    #[must_use]
    pub fn area(&self) -> f64 {
        (self.max_lat - self.min_lat) * (self.max_lon - self.min_lon)
    }
}

/// Every feed in the table, for tests and tools.
#[must_use]
pub fn all() -> &'static [CityFeed] {
    CITY_FEEDS
}

/// The usable feeds whose box holds a point, best first, at most `limit`.
///
/// Best means: official before unofficial, actively maintained before
/// inactive, then the SMALLEST box — the city's own buses before a statewide
/// aggregate that happens to include the city. Feeds needing permission are
/// never returned.
#[must_use]
pub fn covering(lat: f64, lon: f64, limit: usize) -> Vec<&'static CityFeed> {
    if !lat.is_finite() || !lon.is_finite() || limit == 0 {
        return Vec::new();
    }
    let mut hits: Vec<&'static CityFeed> = CITY_FEEDS
        .iter()
        .filter(|f| !f.needs_permission && f.covers(lat, lon))
        .collect();
    hits.sort_by(|a, b| {
        b.official
            .cmp(&a.official)
            .then(b.active.cmp(&a.active))
            .then(a.area().total_cmp(&b.area()))
            .then(a.id.cmp(b.id))
    });
    hits.truncate(limit);
    hits
}

/// What a rider calls the operator, short enough for a credit line.
///
/// Catalog providers run long: "Southeastern Pennsylvania Transportation
/// Authority (SEPTA)", or a list of nine agencies for one Mexico City feed.
/// A trailing abbreviation in brackets is what people actually say, so it
/// wins; otherwise the first agency named, with "and others" when a feed
/// carries several.
#[must_use]
pub fn operator_name(provider: &str) -> String {
    let provider = provider.trim();
    let first = provider.split(", ").next().unwrap_or(provider).trim();
    let several = first.len() < provider.len();
    let short = match (first.rfind('('), first.ends_with(')')) {
        (Some(open), true) => {
            let inside = first[open + 1..first.len() - 1].trim();
            let before = first[..open].trim();
            let capitals = inside
                .chars()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '&');
            if capitals && (3..=8).contains(&inside.len()) {
                inside // "(SEPTA)": what riders say
            } else if capitals && inside.len() == 2 && !before.is_empty() {
                before // "(WI)": a state tag, not a name
            } else {
                first
            }
        }
        _ => first,
    };
    if several {
        format!("{short} and others")
    } else {
        short.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_table_is_the_key_free_north_american_set() {
        let all = all();
        assert!(all.len() > 1000, "{} feeds", all.len());
        assert!(all.iter().all(|f| matches!(f.country, "US" | "CA" | "MX")));
        assert!(all.iter().all(|f| f.url.starts_with("http")));
        assert!(all
            .iter()
            .all(|f| f.min_lat < f.max_lat && f.min_lon < f.max_lon));
        let mut ids: Vec<&str> = all.iter().map(|f| f.id).collect();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(
            ids.len(),
            all.len(),
            "ids are unique — they name cache files"
        );
        assert!(ids.iter().all(|id| id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')));
    }

    #[test]
    fn a_trip_to_milwaukee_finds_milwaukees_buses() {
        let hits = covering(43.0389, -87.9065, 3);
        assert!(!hits.is_empty(), "Milwaukee has an API-key-free feed");
        assert!(
            hits.iter().any(|f| f.provider.contains("Milwaukee")),
            "got {:?}",
            hits.iter().map(|f| f.provider).collect::<Vec<_>>()
        );
    }

    #[test]
    fn the_citys_own_feed_comes_before_a_statewide_one() {
        // Everything covering downtown Los Angeles, ranked: the first must
        // have a smaller box than any official, active feed after it.
        let hits = covering(34.0522, -118.2437, 10);
        assert!(hits.len() >= 2);
        for pair in hits.windows(2) {
            let (a, b) = (pair[0], pair[1]);
            if a.official == b.official && a.active == b.active {
                assert!(a.area() <= b.area(), "{} before {}", a.id, b.id);
            }
        }
    }

    #[test]
    fn feeds_needing_permission_are_never_offered() {
        let marked: Vec<&CityFeed> = all().iter().filter(|f| f.needs_permission).collect();
        assert!(!marked.is_empty(), "the hand-read licences are marked");
        for f in marked {
            let (lat, lon) = ((f.min_lat + f.max_lat) / 2.0, (f.min_lon + f.max_lon) / 2.0);
            assert!(
                covering(lat, lon, 50).iter().all(|g| g.id != f.id),
                "{} offered",
                f.id
            );
        }
    }

    #[test]
    fn open_ocean_and_nonsense_find_nothing() {
        assert!(covering(35.0, -40.0, 5).is_empty(), "mid-Atlantic");
        assert!(covering(f64::NAN, -87.9, 5).is_empty());
        assert!(covering(43.0, -87.9, 0).is_empty());
    }

    #[test]
    fn operators_are_named_the_way_riders_say_them() {
        assert_eq!(
            operator_name("Southeastern Pennsylvania Transportation Authority (SEPTA)"),
            "SEPTA"
        );
        assert_eq!(
            operator_name("Metro Transit - City of Madison"),
            "Metro Transit - City of Madison"
        );
        assert_eq!(
            operator_name(
                "Pumabús, Corredores Concesionados, Sistema de Transporte Colectivo Metro"
            ),
            "Pumabús and others"
        );
        assert_eq!(
            operator_name("Valley Transit (WI)"),
            "Valley Transit",
            "a state tag is dropped"
        );
        assert_eq!(
            operator_name("Regional Transportation Commission (RTC)"),
            "RTC"
        );
        assert_eq!(
            operator_name("Ville de Saint-Hyacinthe"),
            "Ville de Saint-Hyacinthe"
        );
        assert_eq!(
            operator_name("Transit (Downtown Circulator Service)"),
            "Transit (Downtown Circulator Service)",
            "a bracket of words is part of the name"
        );
    }
}
