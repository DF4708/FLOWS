// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::alerts`: the one alert classifier, as the
//! display table, the shelter policy and the imminent-alert policy call it.
//!
//! Enum values cross as small integers documented on each function; Swift
//! maps them to its own enums and treats anything out of range as the
//! containment fallback. Names cross once, as a table.

use crate::contain;
use flows_core::alerts;

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_alerts_display_kind_names() -> Vec<String>;
        fn flows_alerts_display_kind(event: &str) -> i32;
        fn flows_alerts_display_kind_for_family(family: &str) -> i32;
        fn flows_alerts_shelter_kind(event: &str, severity_score: f64) -> i32;
        fn flows_alerts_is_life_safety(event: &str) -> bool;
        fn flows_alerts_is_lookout(event: &str) -> bool;
        fn flows_alerts_action(
            event: &str,
            severity_score: f64,
            has_expiry: bool,
            seconds_until_expiry: f64,
        ) -> i32;
        fn flows_alerts_threat_rank(event: &str, severity_score: f64) -> i32;
    }
}

/// `HazardKind` names indexed by the value [`flows_alerts_display_kind`] returns.
pub fn flows_alerts_display_kind_names() -> Vec<String> {
    contain(Vec::new(), || {
        alerts::DISPLAY_KIND_NAMES
            .iter()
            .map(|s| (*s).to_string())
            .collect()
    })
}

/// Index into [`flows_alerts_display_kind_names`]; 0 (the generic hazard) on containment.
pub fn flows_alerts_display_kind(event: &str) -> i32 {
    contain(0, || alerts::display_kind(event) as i32)
}

/// Index into [`flows_alerts_display_kind_names`] for a band family; 0 on containment.
pub fn flows_alerts_display_kind_for_family(family: &str) -> i32 {
    contain(0, || alerts::display_kind_for_family(family) as i32)
}

/// 0 in vehicle, 1 any building, 2 sturdy building, 3 official shelter; -1 on containment.
pub fn flows_alerts_shelter_kind(event: &str, severity_score: f64) -> i32 {
    contain(-1, || alerts::shelter_kind(event, severity_score) as i32)
}

pub fn flows_alerts_is_life_safety(event: &str) -> bool {
    contain(false, || alerts::is_life_safety(event))
}

pub fn flows_alerts_is_lookout(event: &str) -> bool {
    contain(false, || alerts::is_lookout(event))
}

/// 0 monitor, 1 rest area, 2 shelter, 3 lookout; -1 on containment.
pub fn flows_alerts_action(
    event: &str,
    severity_score: f64,
    has_expiry: bool,
    seconds_until_expiry: f64,
) -> i32 {
    contain(-1, || {
        alerts::action(
            event,
            severity_score,
            has_expiry.then_some(seconds_until_expiry),
        ) as i32
    })
}

/// 0..=3, see `flows_core::alerts::threat_rank`; 0 on containment.
pub fn flows_alerts_threat_rank(event: &str, severity_score: f64) -> i32 {
    contain(0, || i32::from(alerts::threat_rank(event, severity_score)))
}
