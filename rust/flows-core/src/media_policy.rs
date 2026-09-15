// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Media and device policy: how healthy the data link looks, how hard the
//! device may work, what plays when the signal drops, how long to wait before
//! switching, and which NOAA transmitter to follow — `SignalQuality.swift`,
//! `AdaptiveTuning.swift`, `PlaybackFallback.swift`, `PlaybackGrace.swift` and
//! `RadioTuning.swift` at commit bea472d, the last before their facade switch.
//!
//! | here | Swift |
//! |---|---|
//! | [`signal_tier`], [`should_pre_stage`], [`is_draining`] | `SignalQuality.tier`, `.shouldPreStage`, `.isDraining` |
//! | [`device_tier`], [`tuning_settings`] | `AdaptiveTuning.baseTier`, `.settings` |
//! | [`on_connection_lost`], [`should_restore`], [`RESTORE_HOLD_SECONDS`] | `PlaybackFallback` |
//! | [`grace_seconds`] and the caps | `PlaybackGrace.graceSeconds` |
//! | [`nearest_station`], [`retarget`], [`SWITCH_MARGIN`] | `RadioTuning.nearest`, `.retarget` |
//!
//! # Fidelity
//!
//! Pinned by `flows-bridge/tests/fixtures/swift_modes_oracle.tsv`. Text is
//! matched with Swift's own rules ([`crate::swift_text`]); `min`/`max` are
//! Swift's ([`crate::fcmp`]); the nearest transmitter is `min(by:)`'s first
//! winner under the Swift comparator, so a NaN distance and a tie resolve as
//! they did. Spoken sentences and the platform reads (radio technology, other
//! apps' audio, thermal state) stay in Swift. Nothing here performs I/O.

use crate::fcmp::{smax, smin};
use crate::geo::meters;
use crate::swift_text as st;

/// A point as (latitude, longitude), degrees.
pub type Point = (f64, f64);

// ============================================================ SignalQuality

/// Link tiers, in `SignalQuality.Tier` declaration order.
pub mod tier {
    /// 5G, LTE or Wi-Fi.
    pub const STRONG: u8 = 0;
    /// 3G-class.
    pub const FAIR: u8 = 1;
    /// EDGE or GPRS: the classic dead-zone approach.
    pub const WEAK: u8 = 2;
    /// No link.
    pub const OFFLINE: u8 = 3;
}

/// `SignalQuality.tier`: offline and Wi-Fi first, then the radio access
/// technology's name, lowercased and matched by substring; an unknown or
/// absent name is fair.
#[must_use]
pub fn signal_tier(radio_technology: Option<&str>, on_wifi: bool, offline: bool) -> u8 {
    if offline {
        return tier::OFFLINE;
    }
    if on_wifi {
        return tier::STRONG;
    }
    let Some(name) = radio_technology else {
        return tier::FAIR;
    };
    let tech = st::lowercased(name);
    let has = |w: &str| st::contains(&tech, w);
    if has("nr") || has("lte") {
        return tier::STRONG;
    }
    if has("edge") || has("gprs") || has("1x") {
        return tier::WEAK;
    }
    tier::FAIR
}

/// `SignalQuality.shouldPreStage`: never offline (too late to fetch); a weak
/// link, a draining buffer or any stall is enough.
#[must_use]
pub fn should_pre_stage(link_tier: u8, buffer_draining: bool, recent_stalls: i64) -> bool {
    if link_tier == tier::OFFLINE {
        return false;
    }
    link_tier == tier::WEAK || buffer_draining || recent_stalls > 0
}

/// `SignalQuality.isDraining`: both readings present and finite, and the
/// buffer shrank by more than a second.
#[must_use]
pub fn is_draining(previous: Option<f64>, current: Option<f64>) -> bool {
    let (Some(p), Some(c)) = (previous, current) else {
        return false;
    };
    p.is_finite() && c.is_finite() && c < p - 1.0
}

// ============================================================ AdaptiveTuning

/// Device tiers, in `AdaptiveTuning.Tier` raw-value order.
pub mod device {
    /// Two cores or under 3 GB.
    pub const LOW: u8 = 0;
    /// Up to four cores or under 4.5 GB.
    pub const STANDARD: u8 = 1;
    /// Everything else.
    pub const HIGH: u8 = 2;
}

/// `AdaptiveTuning.baseTier`: the hardware tier from core count and memory.
#[must_use]
pub fn device_tier(cores: i64, memory_gb: f64) -> u8 {
    if cores <= 2 || memory_gb < 3.0 {
        return device::LOW;
    }
    if cores <= 4 || memory_gb < 4.5 {
        return device::STANDARD;
    }
    device::HIGH
}

/// How hard the app may work the network and CPU.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TuningSettings {
    /// App-wide cap on concurrent network requests.
    pub max_in_flight: i64,
    /// The ceiling for a user-initiated planning burst.
    pub planning_max_in_flight: i64,
    /// The N of the viewport hazard sweep's N×N grid.
    pub viewport_grid_span: i64,
    /// Cache lifetimes are multiplied by this.
    pub ttl_multiplier: f64,
    /// Debounce before a moved map sweeps again, seconds.
    pub debounce_seconds: f64,
}

/// `AdaptiveTuning.settings`: the tier's base, backed off for the thermal
/// state (`ProcessInfo.ThermalState` raw values: 1 fair, 2 serious,
/// 3 critical; anything else nominal) and for Low Power Mode, with the
/// planning burst bounded by the headroom the state allows. A tier code past
/// the tiers reads as high, the Swift switch's last case.
#[must_use]
pub fn tuning_settings(device_tier: u8, thermal: i64, low_power: bool) -> TuningSettings {
    let (mut max_in_flight, mut grid, mut debounce): (i64, i64, f64) = match device_tier {
        device::LOW => (3, 3, 1.0),
        device::STANDARD => (6, 4, 0.6),
        _ => (10, 5, 0.4),
    };
    let mut ttl = 1.0;
    match thermal {
        1 => {
            ttl = 1.3;
            max_in_flight = (max_in_flight - 1).max(2);
            debounce = smax(debounce, if device_tier == device::LOW { 1.0 } else { 0.8 });
        }
        2 => {
            ttl = 2.0;
            max_in_flight = (max_in_flight / 2).max(2);
            grid = (grid - 1).max(3);
            debounce = smax(debounce, 1.0);
        }
        3 => {
            ttl = 3.0;
            max_in_flight = 2;
            grid = 3;
            debounce = smax(debounce, 1.5);
        }
        _ => {}
    }
    if low_power {
        ttl = smax(ttl, 2.0);
        max_in_flight = max_in_flight
            .min(if device_tier == device::HIGH { 5 } else { 3 })
            .max(2);
        grid = grid.clamp(3, 4);
        debounce = smax(debounce, 1.0);
    }
    let mut burst_cap: i64 = match thermal {
        1 => 12,
        2 => 6,
        3 => 2,
        _ => 16,
    };
    if low_power {
        burst_cap = burst_cap.min(8);
    }
    TuningSettings {
        max_in_flight,
        planning_max_in_flight: max_in_flight.max(burst_cap.min(max_in_flight * 2)),
        viewport_grid_span: grid,
        ttl_multiplier: ttl,
        debounce_seconds: debounce,
    }
}

// ============================================================ PlaybackFallback

/// Fallback sources, in `PlaybackFallback.Source` declaration order.
pub mod fallback {
    /// Shuffle what's downloaded on the device.
    pub const LOCAL_LIBRARY: u8 = 0;
    /// Tune stations of the genre.
    pub const RADIO: u8 = 1;
    /// No offline music and no genre.
    pub const NOTHING_AVAILABLE: u8 = 2;
    /// Leave playback alone.
    pub const KEEP_PLAYING: u8 = 3;
}

/// How long the connection must hold before switching back, seconds.
pub const RESTORE_HOLD_SECONDS: f64 = 25.0;

/// `PlaybackFallback.onConnectionLost`: keep what doesn't need the network,
/// then music on the phone, then radio of the genre (trimmed of whitespace
/// and newlines), then nothing. The genre comes back only for radio.
#[must_use]
pub fn on_connection_lost(
    is_playing: bool,
    needs_network: bool,
    has_local_music: bool,
    last_genre: Option<&str>,
) -> (u8, String) {
    if !(is_playing && needs_network) {
        return (fallback::KEEP_PLAYING, String::new());
    }
    if has_local_music {
        return (fallback::LOCAL_LIBRARY, String::new());
    }
    let genre = st::trim_whitespace_newlines(last_genre.unwrap_or(""));
    if genre.is_empty() {
        (fallback::NOTHING_AVAILABLE, String::new())
    } else {
        (fallback::RADIO, genre.to_string())
    }
}

/// `PlaybackFallback.shouldRestore`.
#[must_use]
pub fn should_restore(handed_off: bool, connection_held: bool, driver_chose_since: bool) -> bool {
    handed_off && connection_held && !driver_chose_since
}

// ============================================================ PlaybackGrace

/// Players, in `PlaybackGrace.Source` declaration order.
pub mod player {
    /// FLOWS's own radio player.
    pub const RADIO: u8 = 0;
    /// A cloud track on the system music player.
    pub const APPLE_MUSIC_CLOUD: u8 = 1;
    /// Spotify on its own device.
    pub const SPOTIFY: u8 = 2;
    /// Any other app.
    pub const OTHER_APP: u8 = 3;
}

/// The radio buffer's floor, seconds.
pub const RADIO_FLOOR_SECONDS: f64 = 4.0;
/// The radio buffer's cap, seconds.
pub const RADIO_CAP_SECONDS: f64 = 45.0;
/// Apple Music's conservative cap, seconds.
pub const APPLE_MUSIC_CAP_SECONDS: f64 = 30.0;
/// Spotify's cap, seconds.
pub const SPOTIFY_CAP_SECONDS: f64 = 40.0;
/// How long another app's audio is watched, seconds.
pub const OTHER_APP_WATCH_SECONDS: f64 = 90.0;

/// `PlaybackGrace.graceSeconds`: the radio's measured buffer held between its
/// floor and cap (the floor when unmeasured or not finite); every other
/// player's fixed cap. A player code past the players reads as another app.
#[must_use]
pub fn grace_seconds(source: u8, measured_buffer: Option<f64>) -> f64 {
    match source {
        player::RADIO => match measured_buffer {
            Some(b) if b.is_finite() => smin(smax(b, RADIO_FLOOR_SECONDS), RADIO_CAP_SECONDS),
            _ => RADIO_FLOOR_SECONDS,
        },
        player::APPLE_MUSIC_CLOUD => APPLE_MUSIC_CAP_SECONDS,
        player::SPOTIFY => SPOTIFY_CAP_SECONDS,
        _ => OTHER_APP_WATCH_SECONDS,
    }
}

// ============================================================ RadioTuning

/// How much closer the next transmitter must be before the tuner moves.
pub const SWITCH_MARGIN: f64 = 0.8;

/// `RadioTuning.nearest`: the station nearest `position` and its meters, by
/// `min(by:)` under "equal meters: an exact listing beats a fallback;
/// otherwise fewer meters" — the first station no later one beats.
/// `stations` are (coordinate, is exact). `None` for no stations.
#[must_use]
pub fn nearest_station(position: Point, stations: &[(Point, bool)]) -> Option<(usize, f64)> {
    let mut best: Option<(usize, f64, bool)> = None;
    for (i, &(c, exact)) in stations.iter().enumerate() {
        let m = meters(c.0, c.1, position.0, position.1);
        let replaces = match best {
            None => true,
            Some((_, bm, bexact)) => {
                if m == bm {
                    exact && !bexact
                } else {
                    m < bm
                }
            }
        };
        if replaces {
            best = Some((i, m, exact));
        }
    }
    best.map(|(i, m, _)| (i, m))
}

/// `RadioTuning.retarget`: the index of the station to switch to, or `None`
/// to stay. Nothing playing means nothing to retune; the nearest station
/// already playing (ids compared as Swift strings) means stay; a playing
/// station with no known position yields to any located one; otherwise the
/// nearest must be closer than 80% of the playing one's distance.
#[must_use]
pub fn retarget(
    playing_id: Option<&str>,
    playing_coordinate: Option<Point>,
    position: Point,
    stations: &[(&str, Point, bool)],
) -> Option<usize> {
    let playing_id = playing_id?;
    let located: Vec<(Point, bool)> = stations.iter().map(|&(_, c, e)| (c, e)).collect();
    let (best, best_meters) = nearest_station(position, &located)?;
    if st::eq(stations[best].0, playing_id) {
        return None;
    }
    let Some(pc) = playing_coordinate else {
        return Some(best);
    };
    let current = meters(pc.0, pc.1, position.0, position.1);
    (best_meters < current * SWITCH_MARGIN).then_some(best)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_link_tiers_and_triggers() {
        assert_eq!(
            signal_tier(Some("CTRadioAccessTechnologyLTE"), false, false),
            tier::STRONG
        );
        assert_eq!(
            signal_tier(Some("CTRadioAccessTechnologyEdge"), false, false),
            tier::WEAK
        );
        assert_eq!(
            signal_tier(Some("CTRadioAccessTechnologyWCDMA"), false, false),
            tier::FAIR
        );
        assert_eq!(signal_tier(None, false, false), tier::FAIR);
        assert_eq!(signal_tier(Some("lte"), true, true), tier::OFFLINE);
        assert!(should_pre_stage(tier::WEAK, false, 0));
        assert!(!should_pre_stage(tier::OFFLINE, true, 3));
        assert!(is_draining(Some(10.0), Some(8.5)));
        assert!(!is_draining(Some(10.0), Some(9.0)));
        assert!(!is_draining(Some(f64::NAN), Some(1.0)));
    }

    #[test]
    fn the_device_settings() {
        assert_eq!(device_tier(2, 8.0), device::LOW);
        assert_eq!(device_tier(6, 4.0), device::STANDARD);
        assert_eq!(device_tier(8, f64::NAN), device::HIGH);
        let s = tuning_settings(device::HIGH, 0, false);
        assert_eq!(
            (
                s.max_in_flight,
                s.planning_max_in_flight,
                s.viewport_grid_span
            ),
            (10, 16, 5)
        );
        let hot = tuning_settings(device::HIGH, 3, true);
        assert_eq!(
            (
                hot.max_in_flight,
                hot.planning_max_in_flight,
                hot.viewport_grid_span
            ),
            (2, 2, 3)
        );
        assert_eq!((hot.ttl_multiplier, hot.debounce_seconds), (3.0, 1.5));
    }

    #[test]
    fn playback_fallback_and_grace() {
        assert_eq!(
            on_connection_lost(true, true, false, Some(" rock\n")),
            (fallback::RADIO, "rock".to_string())
        );
        assert_eq!(
            on_connection_lost(true, true, true, None).0,
            fallback::LOCAL_LIBRARY
        );
        assert_eq!(
            on_connection_lost(true, false, false, None).0,
            fallback::KEEP_PLAYING
        );
        assert_eq!(
            on_connection_lost(true, true, false, Some("\u{a0}")).0,
            fallback::NOTHING_AVAILABLE
        );
        assert!(should_restore(true, true, false));
        assert_eq!(grace_seconds(player::RADIO, Some(60.0)), 45.0);
        assert_eq!(grace_seconds(player::RADIO, Some(f64::NAN)), 4.0);
        assert_eq!(grace_seconds(player::SPOTIFY, None), 40.0);
    }

    #[test]
    fn transmitters_follow_the_closest_without_flapping() {
        let a = (43.0, -89.0);
        let b = (43.5, -89.0);
        let stations = [("A", a, true), ("B", b, true)];
        assert_eq!(
            nearest_station((43.4, -89.0), &[(a, true), (b, true)]).map(|h| h.0),
            Some(1)
        );
        assert_eq!(
            retarget(Some("A"), Some(a), (43.4, -89.0), &stations),
            Some(1)
        );
        assert_eq!(
            retarget(Some("A"), Some(a), (43.26, -89.0), &stations),
            None,
            "within the margin"
        );
        assert_eq!(retarget(None, None, (43.4, -89.0), &stations), None);
        assert_eq!(
            nearest_station((43.0, -89.0), &[(a, false), (a, true)]).map(|h| h.0),
            Some(1),
            "exact wins a tie"
        );
    }
}
