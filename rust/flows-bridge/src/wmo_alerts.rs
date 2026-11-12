// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::wmo_alerts`, behind Swift's
//! `WMOAlertParsing`. Implementations live in `flows-core`; this file only
//! crosses. The diacritic folding stays in Swift: the risk-word rules take
//! the folded text as Swift's `folding` gives it.
//!
//! - The feed code comes back as text, empty for none; a panic answers
//!   none (unknown, never the wrong country's "no alerts").
//! - Belize's side comes back as 0 Belize, 1 Mexico, 2 unsure; a panic
//!   answers unsure. Beside Costa Rica: a panic answers yes (unknown).
//! - The list items come back flat, five texts each: link, event,
//!   severity, expires, published. A panic answers no items.
//! - A ring comes back flat as latitude, longitude pairs; a panic answers
//!   no ring.
//! - A CAP file comes back as `["0"]` when it is not an alert file, else
//!   `["1", event, severity, flags, area, expires, effective, web,
//!   description, identifier, references...]`, where `flags` is six
//!   presence marks (`1` present, `0` absent, in the order of the six
//!   optional texts) and then the live mark. A panic answers `["0"]`
//!   (unreadable). Its rings come back as `[count, lengths..., latitude,
//!   longitude, ...]`; a panic answers no rings, which the caller rejects.
//! - The risk words: a panic answers the event as written (unscored, never
//!   a made-up name). Heavy rain: a panic answers yes (a flood notice).

use crate::contain;
use flows_core::wmo_alerts as wa;

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_wmo_feed_code(lat: f64, lon: f64) -> String;
        fn flows_wmo_south_of_mexico(lat: f64, lon: f64) -> bool;
        fn flows_wmo_beside_belize(lat: f64, lon: f64) -> i64;
        fn flows_wmo_beside_costa_rica(lat: f64, lon: f64) -> bool;
        fn flows_wmo_rss_items(xml: &str) -> Vec<String>;
        fn flows_wmo_polygon(raw: &str) -> Vec<f64>;
        fn flows_wmo_cap(raw: &str) -> Vec<String>;
        fn flows_wmo_cap_rings(raw: &str) -> Vec<f64>;
        fn flows_wmo_event_in_risk_words(
            event: &str,
            folded_event: &str,
            severity: &str,
            folded_rain_text: &str,
        ) -> String;
        fn flows_wmo_names_heavy_rain(folded: &str) -> bool;
    }
}

const UNSURE: i64 = 2;

pub fn flows_wmo_feed_code(lat: f64, lon: f64) -> String {
    contain(String::new(), || {
        wa::feed_code(lat, lon).unwrap_or_default().to_string()
    })
}

pub fn flows_wmo_south_of_mexico(lat: f64, lon: f64) -> bool {
    contain(true, || wa::south_of_mexico(lat, lon))
}

pub fn flows_wmo_beside_belize(lat: f64, lon: f64) -> i64 {
    contain(UNSURE, || match wa::beside_belize(lat, lon) {
        wa::BelizeSide::Belize => 0,
        wa::BelizeSide::Mexico => 1,
        wa::BelizeSide::Unsure => UNSURE,
    })
}

pub fn flows_wmo_beside_costa_rica(lat: f64, lon: f64) -> bool {
    contain(true, || wa::beside_costa_rica(lat, lon))
}

pub fn flows_wmo_rss_items(xml: &str) -> Vec<String> {
    contain(Vec::new(), || {
        wa::parse_rss_items(xml)
            .into_iter()
            .flat_map(|i| [i.link, i.event, i.severity, i.expires, i.published])
            .collect()
    })
}

fn flat_ring(ring: &[wa::Point]) -> impl Iterator<Item = f64> + '_ {
    ring.iter().flat_map(|&(lat, lon)| [lat, lon])
}

pub fn flows_wmo_polygon(raw: &str) -> Vec<f64> {
    contain(Vec::new(), || flat_ring(&wa::polygon_coords(raw)).collect())
}

fn mark(b: bool) -> char {
    if b {
        '1'
    } else {
        '0'
    }
}

pub fn flows_wmo_cap(raw: &str) -> Vec<String> {
    contain(vec!["0".to_string()], || {
        let Some(c) = wa::parse_cap(raw) else {
            return vec!["0".to_string()];
        };
        let optional = [
            c.area_desc,
            c.expires,
            c.effective,
            c.web,
            c.description,
            c.identifier,
        ];
        let mut flags: String = optional.iter().map(|o| mark(o.is_some())).collect();
        flags.push(mark(c.is_live));
        let mut out = vec!["1".to_string(), c.event, c.severity, flags];
        out.extend(optional.into_iter().map(Option::unwrap_or_default));
        out.extend(c.references);
        out
    })
}

pub fn flows_wmo_cap_rings(raw: &str) -> Vec<f64> {
    contain(Vec::new(), || {
        let rings = wa::cap_polygons(raw).unwrap_or_default();
        // Counts and lengths are far below 2^53: exact as doubles.
        #[allow(clippy::cast_precision_loss)]
        let mut out: Vec<f64> = std::iter::once(rings.len() as f64)
            .chain(rings.iter().map(|r| r.len() as f64))
            .collect();
        for r in &rings {
            out.extend(flat_ring(r));
        }
        out
    })
}

pub fn flows_wmo_event_in_risk_words(
    event: &str,
    folded_event: &str,
    severity: &str,
    folded_rain_text: &str,
) -> String {
    contain(event.to_string(), || {
        wa::event_in_risk_words(event, folded_event, severity, folded_rain_text)
    })
}

pub fn flows_wmo_names_heavy_rain(folded: &str) -> bool {
    contain(true, || wa::names_heavy_rain(folded))
}
