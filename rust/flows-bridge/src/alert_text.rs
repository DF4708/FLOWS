// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::alert_text`: the reroute prompt's
//! decision, the vehicle and person descriptions in red-alert text, and the
//! dispatch parser and map-pin rules. Functions are named
//! `flows_alert_text_…`.
//!
//! Boundary encodings, chosen so nothing Swift sends can be misread:
//! - a call kind and a vehicle kind are their `allCases` codes; a colour or
//!   a brand is its index in the list [`flows_alert_text_color_names`] or
//!   [`flows_alert_text_brands`] answers, with a `has_` flag;
//! - incidents cross as parallel columns (kind codes as bytes, instants as
//!   seconds since the reference date); the corridor as coordinate columns
//!   with a count, because an empty corridor crosses as one placeholder
//!   point;
//! - dismissed alert ids cross as one joined string plus each id's UTF-8
//!   length and a count;
//! - a place phrase that is not found is the empty string (a found phrase
//!   always holds two words or more).
//!
//! Every function is a thin forwarder through [`contain`], so a panic inside
//! the core becomes the documented fallback instead of crossing into Swift.

use crate::contain;
use ffi::{FlowsAlertEscalation, FlowsAlertPerson, FlowsAlertVehicle};
use flows_core::alert_text as at;

#[swift_bridge::bridge]
mod ffi {
    // (swift-bridge 0.1.59 rejects doc attributes on shared structs, so these
    // are plain comments.)
    //
    // A vehicle description; the indices mean something only with their flags.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsAlertVehicle {
        has: bool,
        kind: u8,
        has_color: bool,
        color_index: i64,
        has_brand: bool,
        brand_index: i64,
    }
    // A person description.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsAlertPerson {
        has: bool,
        is_child: bool,
        has_color: bool,
        color_index: i64,
    }
    // One escalation step: the baseline to keep and the prompt, if any
    // (`trigger_kind` 0 sustained, 1 acute; `risk` its number).
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsAlertEscalation {
        baseline: f64,
        has_trigger: bool,
        trigger_kind: u8,
        risk: f64,
    }

    extern "Rust" {
        // ---- the reroute prompt ----
        fn flows_alert_text_evaluate_escalation(
            complete: bool,
            mean: f64,
            peak: f64,
            peak_alert_id: &str,
            has_peak_alert_id: bool,
            baseline: f64,
            dismissed_risk: f64,
            dismissed_joined: &str,
            dismissed_lens: &[i64],
            dismissed_count: i64,
        ) -> FlowsAlertEscalation;
        fn flows_alert_text_escalation_constants() -> Vec<f64>;

        // ---- red-alert descriptions ----
        fn flows_alert_text_color_names() -> Vec<String>;
        fn flows_alert_text_brands() -> Vec<String>;
        fn flows_alert_text_describes_an_entity(event: &str) -> bool;
        fn flows_alert_text_vehicle(text: &str) -> FlowsAlertVehicle;
        fn flows_alert_text_person(text: &str) -> FlowsAlertPerson;

        // ---- dispatch audio ----
        fn flows_alert_text_phrases(kind: u8) -> Vec<String>;
        fn flows_alert_text_match_order() -> Vec<u8>;
        fn flows_alert_text_road_words() -> Vec<String>;
        fn flows_alert_text_call_kind(transcript: &str) -> i64;
        fn flows_alert_text_place_phrase(transcript: &str) -> String;
        fn flows_alert_text_lifetime_seconds(kind: u8) -> f64;
        fn flows_alert_text_is_expired(kind: u8, heard_at: f64, now: f64) -> bool;
        fn flows_alert_text_pin_constants() -> Vec<f64>;
        fn flows_alert_text_visible(
            kinds: &[u8],
            lats: &[f64],
            lons: &[f64],
            heard_at: &[f64],
            has_position: bool,
            lat: f64,
            lon: f64,
            corridor_lats: &[f64],
            corridor_lons: &[f64],
            corridor_count: i64,
            now: f64,
        ) -> Vec<i64>;
        fn flows_alert_text_merged_keep(
            kinds: &[u8],
            lats: &[f64],
            lons: &[f64],
            new_kind: u8,
            new_lat: f64,
            new_lon: f64,
        ) -> Vec<i64>;
    }
}

type Point = (f64, f64);

fn as_i64(n: usize) -> i64 {
    i64::try_from(n).unwrap_or(-1)
}

fn index_of(list: &[&str], item: &str) -> Option<i64> {
    list.iter().position(|x| *x == item).map(as_i64)
}

#[allow(clippy::too_many_arguments)]
pub fn flows_alert_text_evaluate_escalation(
    complete: bool,
    mean: f64,
    peak: f64,
    peak_alert_id: &str,
    has_peak_alert_id: bool,
    baseline: f64,
    dismissed_risk: f64,
    dismissed_joined: &str,
    dismissed_lens: &[i64],
    dismissed_count: i64,
) -> FlowsAlertEscalation {
    let unchanged = FlowsAlertEscalation {
        baseline,
        has_trigger: false,
        trigger_kind: 0,
        risk: 0.0,
    };
    contain(unchanged, || {
        let count = usize::try_from(dismissed_count).unwrap_or(0);
        let Some(dismissed) = crate::split_texts(dismissed_joined, dismissed_lens, count) else {
            return FlowsAlertEscalation {
                baseline,
                has_trigger: false,
                trigger_kind: 0,
                risk: 0.0,
            };
        };
        let (next, trigger) = at::evaluate_escalation(
            complete,
            mean,
            peak,
            has_peak_alert_id.then_some(peak_alert_id),
            baseline,
            dismissed_risk,
            &dismissed,
        );
        match trigger {
            Some((kind, risk)) => FlowsAlertEscalation {
                baseline: next,
                has_trigger: true,
                trigger_kind: kind,
                risk,
            },
            None => FlowsAlertEscalation {
                baseline: next,
                has_trigger: false,
                trigger_kind: 0,
                risk: 0.0,
            },
        }
    })
}

/// `[sustained rise, dismiss margin, deferred baseline]`.
pub fn flows_alert_text_escalation_constants() -> Vec<f64> {
    vec![
        at::SUSTAINED_RISE,
        at::DISMISS_MARGIN,
        at::DEFERRED_BASELINE,
    ]
}

pub fn flows_alert_text_color_names() -> Vec<String> {
    at::COLOR_NAMES.iter().map(|c| (*c).to_string()).collect()
}

pub fn flows_alert_text_brands() -> Vec<String> {
    at::BRANDS.iter().map(|b| (*b).to_string()).collect()
}

pub fn flows_alert_text_describes_an_entity(event: &str) -> bool {
    contain(false, || at::describes_an_entity(event))
}

pub fn flows_alert_text_vehicle(text: &str) -> FlowsAlertVehicle {
    let none = FlowsAlertVehicle {
        has: false,
        kind: 0,
        has_color: false,
        color_index: -1,
        has_brand: false,
        brand_index: -1,
    };
    contain(none, || match at::vehicle(text) {
        Some(v) => {
            let color = v.color.and_then(|c| index_of(at::COLOR_NAMES, c));
            let brand = v.brand.and_then(|b| index_of(at::BRANDS, b));
            FlowsAlertVehicle {
                has: true,
                kind: v.kind,
                has_color: color.is_some(),
                color_index: color.unwrap_or(-1),
                has_brand: brand.is_some(),
                brand_index: brand.unwrap_or(-1),
            }
        }
        None => FlowsAlertVehicle {
            has: false,
            kind: 0,
            has_color: false,
            color_index: -1,
            has_brand: false,
            brand_index: -1,
        },
    })
}

pub fn flows_alert_text_person(text: &str) -> FlowsAlertPerson {
    let none = FlowsAlertPerson {
        has: false,
        is_child: false,
        has_color: false,
        color_index: -1,
    };
    contain(none, || match at::person(text) {
        Some((is_child, color)) => {
            let color = color.and_then(|c| index_of(at::COLOR_NAMES, c));
            FlowsAlertPerson {
                has: true,
                is_child,
                has_color: color.is_some(),
                color_index: color.unwrap_or(-1),
            }
        }
        None => FlowsAlertPerson {
            has: false,
            is_child: false,
            has_color: false,
            color_index: -1,
        },
    })
}

pub fn flows_alert_text_phrases(kind: u8) -> Vec<String> {
    at::phrases(kind).iter().map(|p| (*p).to_string()).collect()
}

pub fn flows_alert_text_match_order() -> Vec<u8> {
    at::MATCH_ORDER.to_vec()
}

pub fn flows_alert_text_road_words() -> Vec<String> {
    at::ROAD_WORDS.iter().map(|r| (*r).to_string()).collect()
}

/// The call kind code, or -1 when nothing in the transcript is recognizable.
pub fn flows_alert_text_call_kind(transcript: &str) -> i64 {
    contain(-1, || {
        at::kind_in_transcript(transcript).map_or(-1, i64::from)
    })
}

/// The place phrase, or the empty string when there is none.
pub fn flows_alert_text_place_phrase(transcript: &str) -> String {
    contain(String::new(), || {
        at::place_phrase(transcript).unwrap_or_default()
    })
}

pub fn flows_alert_text_lifetime_seconds(kind: u8) -> f64 {
    at::lifetime_seconds(kind)
}

pub fn flows_alert_text_is_expired(kind: u8, heard_at: f64, now: f64) -> bool {
    at::is_expired(kind, heard_at, now)
}

/// `[relevant meters, duplicate meters]`.
pub fn flows_alert_text_pin_constants() -> Vec<f64> {
    vec![at::RELEVANT_METERS, at::DUPLICATE_METERS]
}

/// The indices of incidents to draw.
#[allow(clippy::too_many_arguments)]
pub fn flows_alert_text_visible(
    kinds: &[u8],
    lats: &[f64],
    lons: &[f64],
    heard_at: &[f64],
    has_position: bool,
    lat: f64,
    lon: f64,
    corridor_lats: &[f64],
    corridor_lons: &[f64],
    corridor_count: i64,
    now: f64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        let incidents: Vec<(u8, Point, f64)> = kinds
            .iter()
            .zip(lats.iter().zip(lons))
            .zip(heard_at)
            .map(|((&k, (&a, &b)), &h)| (k, (a, b), h))
            .collect();
        let n = usize::try_from(corridor_count).unwrap_or(0);
        let corridor: Vec<Point> = corridor_lats
            .iter()
            .zip(corridor_lons)
            .take(n)
            .map(|(&a, &b)| (a, b))
            .collect();
        at::visible(
            &incidents,
            has_position.then_some((lat, lon)),
            &corridor,
            now,
        )
        .into_iter()
        .map(as_i64)
        .collect()
    })
}

/// The indices of existing incidents that survive a new report.
pub fn flows_alert_text_merged_keep(
    kinds: &[u8],
    lats: &[f64],
    lons: &[f64],
    new_kind: u8,
    new_lat: f64,
    new_lon: f64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        let existing: Vec<(u8, Point)> = kinds
            .iter()
            .zip(lats.iter().zip(lons))
            .map(|(&k, (&a, &b))| (k, (a, b)))
            .collect();
        at::merged_keep(&existing, new_kind, (new_lat, new_lon))
            .into_iter()
            .map(as_i64)
            .collect()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptions_and_calls_cross_whole() {
        let v = flows_alert_text_vehicle("AMBER Alert: red Chevy pickup truck heading west");
        assert!(v.has && v.has_color && v.has_brand);
        assert_eq!(
            flows_alert_text_brands()[v.brand_index as usize],
            "Chevrolet"
        );
        assert_eq!(
            flows_alert_text_call_kind("two vehicle crash on Highway 51"),
            4
        );
        assert_eq!(flows_alert_text_place_phrase("respond to 2100"), "");
        assert_eq!(
            flows_alert_text_place_phrase("2100 Washington Road"),
            "2100 washington road"
        );
        let deferred =
            flows_alert_text_evaluate_escalation(true, 0.2, 0.3, "", false, -1.0, 0.0, "", &[0], 0);
        assert_eq!(deferred.baseline, 0.2);
        assert!(!deferred.has_trigger);
    }
}
