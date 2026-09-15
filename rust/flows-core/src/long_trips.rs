// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Long drives: the fuel gauge's colour and the last-chance fuel warning, the
//! long-trip share (its trigger, the day's odometer, who to suggest and the
//! share history's rules), and the road corridors saved for the stretches
//! between towns — `FuelWarning.swift`, `TripShare.swift` and
//! `OfflineCorridors.swift` at commit d1197b5, the last before their facade
//! switch.
//!
//! | here | Swift |
//! |---|---|
//! | [`fuel_severity`], [`fuel_band`] | `FuelWarning.severity`, `band` |
//! | [`reachable_stations`], [`fuel_level`], [`cheapest_station`] | `FuelWarning.reachable`, `level`, `cheapest` |
//! | [`crate::geo::fuel_station_is_reachable`], [`crate::geo::bearing_degrees`] | `FuelWarning.isReachable`, `bearingDegrees` |
//! | [`should_offer_share`] | `TripShareLogic.shouldOffer` |
//! | [`daily_drive_add`] | `DailyDriveLog.add` (the calendar day comes from Swift) |
//! | [`share_score`], [`latest_share`], [`ranked_recipients`] | `TripShareLogic.ranked` |
//! | [`normalized_phone`], [`record_share`] | `ShareHistoryStore.normalized`, `recordShare` |
//! | [`keep_corridor`], [`prune_corridors`], [`worth_saving`], [`supersedes`], [`decimate`] | `CorridorRetention` |
//! | [`record_corridor`], [`crate::geo::corridor_nearest`] | `OfflineCorridorStore.record`, `nearest` |
//!
//! # Fidelity
//!
//! Pinned by `flows-bridge/tests/fixtures/swift_long_trips_oracle.tsv`.
//! `min` and `max` are Swift's ([`smin`], [`smax`]); every sort is Swift's
//! own ([`swift_sort_by`]); every `min(by:)` and `max(by:)` keeps its first
//! winner; distances are the geo kernel's [`meters`] in the Swift's argument
//! order; a date is its seconds since the reference date, compared as Swift
//! compares `Date`. The share score's half-life decay is written
//! `(t / -half_life).exp2()`, the form Swift's Release build compiles
//! `pow(0.5, x)` to. Phone digits follow Swift's `Character.isNumber` and
//! compare by canonical equivalence ([`st`]).
//!
//! What stays in Swift: the spoken and on-screen fuel sentences, the share
//! message with its clock time and map link, the `sms:` link, the calendar's
//! start of day, the stores' files and keychain entries, and applying a plan
//! these functions return to the stored lists.

use crate::fcmp::{smax, smin};
use crate::geo::{meters, min_meters_to_point};
use crate::learning::swift_sort_by;
use crate::swift_text as st;

/// A point as (latitude, longitude), degrees.
pub type Point = (f64, f64);

// ================================================================ FuelWarning

/// `FuelWarning.warnAtReachableCount`: the warning fires while this many
/// matching stations, or fewer, are still reachable.
pub const WARN_AT_REACHABLE_COUNT: usize = 3;

/// Severity at or above which the gauge is red.
const RED_SEVERITY: f64 = 0.65;
/// Severity at or above which the gauge is yellow.
const YELLOW_SEVERITY: f64 = 0.35;

/// `FuelWarning.Band`, in declaration order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FuelBand {
    /// The ordinary middle of a tank.
    Green,
    /// Roughly the last third.
    Yellow,
    /// The final stretch.
    Red,
}

/// `FuelWarning.Level`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FuelLevel {
    /// Plenty of matching stations are reachable.
    None,
    /// Only this many matching stations are still reachable (1 to
    /// [`WARN_AT_REACHABLE_COUNT`]).
    LastChances(usize),
    /// Nothing that sells this fuel is reachable.
    Unreachable,
}

/// `FuelWarning.Station` without its name: where it is and what it charges.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Station {
    /// Distance ahead along the route, in miles.
    pub miles_ahead: f64,
    /// Price per unit, when a price source supplied one.
    pub price: Option<f64>,
}

/// `FuelWarning.severity(fraction:)`: `min(max(1 - fraction, 0), 1)` cubed
/// with `pow`. A NaN fraction gives NaN.
///
/// Deterministic; panics: none.
#[must_use]
pub fn fuel_severity(fraction: f64) -> f64 {
    let empty = smin(smax(1.0 - fraction, 0.0), 1.0);
    empty.powf(3.0)
}

/// `FuelWarning.band(fraction:)`: red at severity 0.65 or more, yellow at
/// 0.35 or more, green otherwise (a NaN severity is green).
///
/// Deterministic; panics: none.
#[must_use]
pub fn fuel_band(fraction: f64) -> FuelBand {
    let s = fuel_severity(fraction);
    if s >= RED_SEVERITY {
        FuelBand::Red
    } else if s >= YELLOW_SEVERITY {
        FuelBand::Yellow
    } else {
        FuelBand::Green
    }
}

/// `FuelWarning.reachable(stationsAhead:rangeMiles:reserveMiles:)`: the
/// indices of the stations no further ahead than `range_miles -
/// reserve_miles` (inclusive), nearest first by Swift's sort, ties in input
/// order. A NaN distance or usable range keeps nothing.
///
/// Deterministic; panics: none.
#[must_use]
pub fn reachable_stations(
    stations: &[Station],
    range_miles: f64,
    reserve_miles: f64,
) -> Vec<usize> {
    let usable = range_miles - reserve_miles;
    let mut kept: Vec<usize> = (0..stations.len())
        .filter(|&i| stations[i].miles_ahead <= usable)
        .collect();
    swift_sort_by(&mut kept, |a, b| {
        stations[a].miles_ahead < stations[b].miles_ahead
    });
    kept
}

/// `FuelWarning.level(stationsAhead:rangeMiles:reserveMiles:)`: unreachable
/// when no station is reachable, last chances while at most
/// [`WARN_AT_REACHABLE_COUNT`] are, none otherwise.
///
/// Deterministic; panics: none.
#[must_use]
pub fn fuel_level(stations: &[Station], range_miles: f64, reserve_miles: f64) -> FuelLevel {
    match reachable_stations(stations, range_miles, reserve_miles).len() {
        0 => FuelLevel::Unreachable,
        n if n <= WARN_AT_REACHABLE_COUNT => FuelLevel::LastChances(n),
        _ => FuelLevel::None,
    }
}

/// `FuelWarning.cheapest(stationsAhead:rangeMiles:reserveMiles:)`: among the
/// reachable stations with a price, the first winner of `min(by:)` under
/// "prices more than 0.001 apart compare by price, otherwise by distance";
/// with no priced station, the nearest reachable one; `None` when nothing
/// is reachable.
///
/// The comparison is not an order (a price within 0.001 of two others that
/// are not within 0.001 of each other), so the scan runs in reachable order
/// and replaces its winner only when the next station compares strictly
/// better, exactly as `min(by:)` does.
///
/// Deterministic; panics: none.
#[must_use]
pub fn cheapest_station(
    stations: &[Station],
    range_miles: f64,
    reserve_miles: f64,
) -> Option<usize> {
    let in_range = reachable_stations(stations, range_miles, reserve_miles);
    let mut priced = in_range
        .iter()
        .copied()
        .filter(|&i| stations[i].price.is_some());
    let Some(mut best) = priced.next() else {
        return in_range.first().copied();
    };
    for e in priced {
        if cheaper(stations[e], stations[best]) {
            best = e;
        }
    }
    Some(best)
}

/// The `cheapest` comparator: `abs(a - b) > 0.001 ? a < b : miles < miles`,
/// with a missing price as infinity.
fn cheaper(a: Station, b: Station) -> bool {
    let pa = a.price.unwrap_or(f64::INFINITY);
    let pb = b.price.unwrap_or(f64::INFINITY);
    if (pa - pb).abs() > 0.001 {
        return pa < pb;
    }
    a.miles_ahead < b.miles_ahead
}

// ================================================================ TripShare

/// `TripShareLogic.longTripMiles`: the long-trip line, for both triggers.
pub const LONG_TRIP_MILES: f64 = 200.0;
/// `TripShareLogic.metersPerMile`.
pub const METERS_PER_MILE: f64 = 1609.344;
/// `ShareHistoryStore.maxRecipients`.
pub const MAX_RECIPIENTS: usize = 12;
/// `ShareHistoryStore.maxDatesPerRecipient`.
pub const MAX_DATES_PER_RECIPIENT: usize = 10;
/// `Date.distantPast`, in seconds since the reference date: the latest share
/// of a recipient with none.
pub const DISTANT_PAST: f64 = -63_114_076_800.0;

/// A past share's weight halves every this many days.
const SHARE_HALF_LIFE_DAYS: f64 = 30.0;
const SECONDS_PER_DAY: f64 = 86_400.0;

/// `TripShareLogic.shouldOffer(routeMeters:drivenTodayMeters:)`: either
/// length strictly over [`LONG_TRIP_MILES`] in meters.
///
/// Deterministic; panics: none.
#[must_use]
pub fn should_offer_share(route_meters: f64, driven_today_meters: f64) -> bool {
    let limit = LONG_TRIP_MILES * METERS_PER_MILE;
    route_meters > limit || driven_today_meters > limit
}

/// `DailyDriveLog.add(meters:at:calendar:)`: the log's `(day, meters)` after
/// driving `delta` meters on the calendar day starting at `today`.
///
/// A `today` that is not equal to `day` (NaN included) starts the count over
/// on `today`; then `max(delta, 0)` is added, so a negative reading never
/// drives the total down. Days are seconds since the reference date.
///
/// Deterministic; panics: none.
#[must_use]
pub fn daily_drive_add(day: f64, meters_driven: f64, today: f64, delta: f64) -> (f64, f64) {
    let (day, total) = if today == day {
        (day, meters_driven)
    } else {
        (today, 0.0)
    };
    (day, total + smax(delta, 0.0))
}

/// A recipient's suggestion score at `now`: each share is worth one point
/// halving every 30 days of age, a share dated after `now` counting as new.
/// Dates are seconds since the reference date, summed in order.
///
/// Deterministic; panics: none.
#[must_use]
pub fn share_score(dates: &[f64], now: f64) -> f64 {
    let mut total = 0.0;
    for &date in dates {
        let age_days = smax(now - date, 0.0) / SECONDS_PER_DAY;
        // Swift's Release build compiles pow(0.5, x) as exp2(x / -1); written out with the sign on the divisor so every build agrees (module doc).
        total += (age_days / -SHARE_HALF_LIFE_DAYS).exp2();
    }
    total
}

/// `shareDates.max() ?? .distantPast`: the first latest date (a NaN first
/// date is never displaced, a later NaN never taken), or [`DISTANT_PAST`].
///
/// Deterministic; panics: none.
#[must_use]
pub fn latest_share(dates: &[f64]) -> f64 {
    let mut rest = dates.iter().copied();
    let Some(mut best) = rest.next() else {
        return DISTANT_PAST;
    };
    for d in rest {
        if best < d {
            best = d;
        }
    }
    best
}

/// `TripShareLogic.ranked(_:now:)`: recipient indices, best suggestion first
/// — higher [`share_score`] first, equal scores by later [`latest_share`] —
/// by Swift's sort, so a NaN score or date orders exactly as the app did.
///
/// Deterministic; panics: none.
#[must_use]
pub fn ranked_recipients(recipients: &[&[f64]], now: f64) -> Vec<usize> {
    let mut scored: Vec<(usize, f64, f64)> = recipients
        .iter()
        .enumerate()
        .map(|(i, dates)| (i, share_score(dates, now), latest_share(dates)))
        .collect();
    swift_sort_by(
        &mut scored,
        |a, b| {
            if a.1 != b.1 {
                a.1 > b.1
            } else {
                a.2 > b.2
            }
        },
    );
    scored.into_iter().map(|(i, _, _)| i).collect()
}

/// `ShareHistoryStore.normalized(_:)`: the characters of `phone` whose first
/// scalar is a number (`Character.isNumber`), whole clusters kept, in order.
///
/// Deterministic; panics: none.
#[must_use]
pub fn normalized_phone(phone: &str) -> String {
    st::graphemes(phone)
        .filter(|cluster| st::is_number_start(cluster))
        .collect()
}

/// What `ShareHistoryStore.recordShare` does to the stored list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShareRecord {
    /// The recipient the share joins, or `None` when a new recipient (the
    /// given name, phone and one date) is appended.
    pub matched: Option<usize>,
    /// Whether the matched recipient's name becomes the given name.
    pub renames: bool,
    /// How many of the matched recipient's oldest dates are removed after
    /// the new date is appended.
    pub dropped_dates: usize,
    /// When the list overflows: the recipients to keep, best first, as
    /// indices into the list after the share (a new recipient is the last
    /// index). `None` keeps the list in its order.
    pub order: Option<Vec<usize>>,
}

/// `ShareHistoryStore.recordShare(name:phone:at:)` as a plan over the stored
/// recipients' phones and dates; `None` when the phone has no digits and
/// nothing is recorded.
///
/// The share joins the first recipient whose normalized phone is canonically
/// equivalent to the new one's, renaming them unless `name` is empty and
/// keeping their newest [`MAX_DATES_PER_RECIPIENT`] dates; otherwise it adds
/// a recipient. Over [`MAX_RECIPIENTS`], the list becomes the best
/// [`MAX_RECIPIENTS`] of [`ranked_recipients`] at the share's date. Only the
/// first `min(phones.len(), dates.len())` recipients are read.
///
/// Deterministic; panics: none.
#[must_use]
pub fn record_share(
    phones: &[&str],
    dates: &[&[f64]],
    name: &str,
    phone: &str,
    date: f64,
) -> Option<ShareRecord> {
    let key = normalized_phone(phone);
    if key.is_empty() {
        return None;
    }
    let n = phones.len().min(dates.len());
    let matched = phones[..n]
        .iter()
        .position(|p| st::eq(&normalized_phone(p), &key));
    let mut lists: Vec<Vec<f64>> = dates[..n].iter().map(|d| d.to_vec()).collect();
    let (renames, dropped_dates) = match matched {
        Some(i) => {
            lists[i].push(date);
            let overflow = lists[i].len().saturating_sub(MAX_DATES_PER_RECIPIENT);
            lists[i].drain(..overflow);
            (!name.is_empty(), overflow)
        }
        None => {
            lists.push(vec![date]);
            (false, 0)
        }
    };
    let order = (lists.len() > MAX_RECIPIENTS).then(|| {
        let views: Vec<&[f64]> = lists.iter().map(Vec::as_slice).collect();
        let mut best = ranked_recipients(&views, date);
        best.truncate(MAX_RECIPIENTS);
        best
    });
    Some(ShareRecord {
        matched,
        renames,
        dropped_dates,
        order,
    })
}

// ================================================================ OfflineCorridors

/// `CorridorRetention.maxAge`: a saved corridor is stale after a week.
pub const MAX_AGE_SECONDS: f64 = 604_800.0;
/// `CorridorRetention.arrivedMeters`.
pub const ARRIVED_METERS: f64 = 1_500.0;
/// `CorridorRetention.passedMeters`.
pub const PASSED_METERS: f64 = 30_000.0;
/// `CorridorRetention.maxStored`.
pub const MAX_STORED: usize = 3;
/// `CorridorRetention.minTripMeters`.
pub const MIN_TRIP_METERS: f64 = 25_000.0;
/// `CorridorRetention.decimate`'s default step.
pub const DECIMATE_STEP_METERS: f64 = 400.0;
/// `CorridorRetention.decimate`'s default point limit.
pub const DECIMATE_LIMIT: i64 = 1_200;

/// A saved corridor as the retention rules read it: when it was saved
/// (seconds since the reference date) and its decoded points.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Corridor<'a> {
    /// `SavedCorridor.savedAt`.
    pub saved_at: f64,
    /// Latitudes of `SavedCorridor.coordinates`.
    pub lats: &'a [f64],
    /// Longitudes of `SavedCorridor.coordinates`.
    pub lons: &'a [f64],
}

/// `CorridorRetention.keep(_:now:position:)`.
///
/// False once `now - saved_at < MAX_AGE_SECONDS` fails (NaN included); true
/// with no position; false with no points; false within [`ARRIVED_METERS`]
/// of the last point; otherwise true while the first-minimum distance from
/// the points to the position is within [`PASSED_METERS`]. Only the first
/// `min(lats.len(), lons.len())` points are read.
///
/// Deterministic; panics: none.
#[must_use]
pub fn keep_corridor(corridor: Corridor<'_>, now: f64, position: Option<Point>) -> bool {
    // Swift's guard: `now.timeIntervalSince(savedAt) < maxAge`, so a NaN age drops the corridor.
    let fresh = now - corridor.saved_at < MAX_AGE_SECONDS;
    if !fresh {
        return false;
    }
    let Some((lat, lon)) = position else {
        return true;
    };
    let n = corridor.lats.len().min(corridor.lons.len());
    if n == 0 {
        return false;
    }
    let (lats, lons) = (&corridor.lats[..n], &corridor.lons[..n]);
    if meters(lats[n - 1], lons[n - 1], lat, lon) <= ARRIVED_METERS {
        return false;
    }
    min_meters_to_point(lats, lons, lat, lon) <= PASSED_METERS
}

/// `CorridorRetention.prune(_:now:position:)`: the indices of the corridors
/// [`keep_corridor`] keeps, newest first by Swift's sort (ties in input
/// order), at most [`MAX_STORED`].
///
/// Deterministic; panics: none.
#[must_use]
pub fn prune_corridors(
    corridors: &[Corridor<'_>],
    now: f64,
    position: Option<Point>,
) -> Vec<usize> {
    let mut kept: Vec<usize> = (0..corridors.len())
        .filter(|&i| keep_corridor(corridors[i], now, position))
        .collect();
    swift_sort_by(&mut kept, |a, b| {
        corridors[a].saved_at > corridors[b].saved_at
    });
    kept.truncate(MAX_STORED);
    kept
}

/// `CorridorRetention.worthSaving(tripMeters:)`: at least
/// [`MIN_TRIP_METERS`].
///
/// Deterministic; panics: none.
#[must_use]
pub fn worth_saving(trip_meters: f64) -> bool {
    trip_meters >= MIN_TRIP_METERS
}

/// `CorridorRetention.supersedes(_:_:)` on the two corridors' destinations
/// (their last decoded points): both present and within
/// [`ARRIVED_METERS`], measured from the newer to the older.
///
/// Deterministic; panics: none.
#[must_use]
pub fn supersedes(newer_end: Option<Point>, older_end: Option<Point>) -> bool {
    match (newer_end, older_end) {
        (Some(a), Some(b)) => meters(a.0, a.1, b.0, b.1) <= ARRIVED_METERS,
        _ => false,
    }
}

/// `CorridorRetention.decimate(_:stepMeters:limit:)` as indices into the
/// input.
///
/// The first point is kept, then each point at least `step_meters` from the
/// last kept one, then the true last point when it lies more than a meter
/// from the last kept one. When more than `limit` points remain, `limit`
/// of them are sampled evenly, the k-th at the kept position
/// `round(k * (kept - 1) / (limit - 1))` (half away from zero). Only the
/// first `min(lats.len(), lons.len())` points are read.
///
/// Where the Swift trapped because more points remained than a limit below 2
/// allows, the answer is empty for a negative limit and the first point for
/// a limit of 1; a limit of 0 answers empty, as the Swift did.
///
/// Deterministic; panics: none.
#[must_use]
pub fn decimate(lats: &[f64], lons: &[f64], step_meters: f64, limit: i64) -> Vec<usize> {
    let n = lats.len().min(lons.len());
    if n == 0 {
        return Vec::new();
    }
    let mut out = vec![0usize];
    let mut last = 0usize;
    for i in 1..n {
        if meters(lats[last], lons[last], lats[i], lons[i]) >= step_meters {
            out.push(i);
            last = i;
        }
    }
    if meters(lats[last], lons[last], lats[n - 1], lons[n - 1]) > 1.0 {
        out.push(n - 1);
    }
    let kept = out.len();
    match usize::try_from(limit) {
        Ok(cap) if kept <= cap => out,
        Ok(0) | Err(_) => Vec::new(),
        Ok(1) => vec![out[0]],
        Ok(cap) => {
            let stride = (kept - 1) as f64 / (cap - 1) as f64;
            (0..cap)
                .map(|k| {
                    // In range by construction: k * stride <= kept - 1 up to rounding; the clamp only guards float error.
                    let at = ((k as f64) * stride).round() as usize;
                    out[at.min(kept - 1)]
                })
                .collect()
        }
    }
}

/// `OfflineCorridorStore.record`'s new list, once the trip is worth saving
/// and its thinned line has at least two points: the stored corridors the
/// new one does not supersede, then the new one, pruned with no position.
///
/// `saved_at` and `ends` describe the stored corridors (a missing end is a
/// corridor with no decoded points); the answer indexes them, with
/// `saved_at.len()` standing for the new corridor, saved at `now`. Only the
/// first `min(saved_at.len(), ends.len())` corridors are read.
///
/// Deterministic; panics: none.
#[must_use]
pub fn record_corridor(
    saved_at: &[f64],
    ends: &[Option<Point>],
    new_end: Option<Point>,
    now: f64,
) -> Vec<usize> {
    let n = saved_at.len().min(ends.len());
    let mut sources: Vec<usize> = (0..n).filter(|&i| !supersedes(new_end, ends[i])).collect();
    sources.push(saved_at.len());
    // With no position, keep reads only the save time: no points are needed.
    let views: Vec<Corridor<'_>> = sources
        .iter()
        .map(|&i| Corridor {
            saved_at: if i < n { saved_at[i] } else { now },
            lats: &[],
            lons: &[],
        })
        .collect();
    prune_corridors(&views, now, None)
        .into_iter()
        .map(|k| sources[k])
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn station(miles: f64, price: Option<f64>) -> Station {
        Station {
            miles_ahead: miles,
            price,
        }
    }

    #[test]
    fn the_gauge_stays_green_through_the_middle_and_goes_red_near_empty() {
        assert_eq!(fuel_band(1.0), FuelBand::Green);
        assert_eq!(fuel_band(0.35), FuelBand::Green);
        assert_eq!(fuel_band(0.25), FuelBand::Yellow);
        assert_eq!(fuel_band(0.10), FuelBand::Red);
        assert_eq!(fuel_band(f64::NAN), FuelBand::Green);
        assert!(fuel_severity(f64::NAN).is_nan());
    }

    #[test]
    fn the_warning_counts_reachable_stations_and_keeps_the_reserve() {
        let owner = [
            station(4.0, None),
            station(8.0, None),
            station(40.0, None),
            station(120.0, None),
        ];
        assert_eq!(fuel_level(&owner, 50.0, 40.0), FuelLevel::LastChances(2));
        assert_eq!(
            fuel_level(&[station(100.0, None)], 100.0, 40.0),
            FuelLevel::Unreachable
        );
        assert_eq!(fuel_level(&[], 60.0, 40.0), FuelLevel::Unreachable);
        let plenty: Vec<Station> = (1..=8)
            .map(|i| station(f64::from(i) * 10.0, None))
            .collect();
        assert_eq!(fuel_level(&plenty, 200.0, 40.0), FuelLevel::None);
    }

    #[test]
    fn the_cheapest_reachable_priced_station_wins_and_unpriced_ones_rank_behind() {
        let s = [
            station(5.0, Some(4.59)),
            station(8.0, Some(3.19)),
            station(400.0, Some(2.99)),
        ];
        assert_eq!(cheapest_station(&s, 60.0, 40.0), Some(1));
        let unpriced = [station(3.0, None), station(9.0, Some(3.99))];
        assert_eq!(cheapest_station(&unpriced, 60.0, 40.0), Some(1));
        let none_priced = [station(9.0, None), station(3.0, None)];
        assert_eq!(cheapest_station(&none_priced, 60.0, 40.0), Some(1));
        // Within a tenth of a cent, the nearer station wins.
        let close = [station(9.0, Some(3.1905)), station(4.0, Some(3.19))];
        assert_eq!(cheapest_station(&close, 60.0, 40.0), Some(1));
    }

    #[test]
    fn the_share_is_offered_strictly_over_two_hundred_miles() {
        let mile = METERS_PER_MILE;
        assert!(should_offer_share(201.0 * mile, 0.0));
        assert!(!should_offer_share(200.0 * mile, 0.0));
        assert!(should_offer_share(15.0 * mile, 201.0 * mile));
        assert!(!should_offer_share(f64::NAN, f64::NAN));
    }

    #[test]
    fn the_day_odometer_resets_on_a_new_day_and_never_runs_down() {
        assert_eq!(daily_drive_add(0.0, 500.0, 0.0, 250.0), (0.0, 750.0));
        assert_eq!(
            daily_drive_add(0.0, 750.0, 86_400.0, 100.0),
            (86_400.0, 100.0)
        );
        assert_eq!(
            daily_drive_add(86_400.0, 100.0, 86_400.0, -50.0),
            (86_400.0, 100.0)
        );
        let (day, total) = daily_drive_add(f64::NAN, 9.0, f64::NAN, 1.0);
        assert!(day.is_nan());
        assert_eq!(total, 1.0);
    }

    #[test]
    fn frequent_recent_recipients_rank_first_and_stale_piles_decay() {
        let now = 1_000.0 * 86_400.0;
        let often = [now - 86_400.0, now - 3.0 * 86_400.0, now - 8.0 * 86_400.0];
        let once = [now - 2.0 * 86_400.0];
        assert_eq!(ranked_recipients(&[&once, &often], now), vec![1, 0]);
        let stale: Vec<f64> = (300..305).map(|d| now - f64::from(d) * 86_400.0).collect();
        let current = [now, now - 86_400.0];
        assert_eq!(ranked_recipients(&[&stale, &current], now), vec![1, 0]);
        // No shares at all: score 0, latest the distant past.
        assert_eq!(latest_share(&[]), DISTANT_PAST);
    }

    #[test]
    fn phones_normalize_to_their_number_characters() {
        assert_eq!(normalized_phone("+1 (555) 010-2030"), "15550102030");
        assert_eq!(normalized_phone("n/a"), "");
        // A keycap keeps its whole cluster; a fullwidth digit is a number.
        assert_eq!(normalized_phone("1\u{FE0F}\u{20E3}x"), "1\u{FE0F}\u{20E3}");
        assert_eq!(normalized_phone("\u{FF11}"), "\u{FF11}");
    }

    #[test]
    fn a_share_joins_the_same_number_typed_two_ways_and_caps_its_dates() {
        let d: Vec<f64> = (0..10).map(f64::from).collect();
        let plan = record_share(&["+1 (555) 010-2030"], &[&d], "Dana", "15550102030", 99.0)
            .expect("digits");
        assert_eq!(plan.matched, Some(0));
        assert!(plan.renames);
        assert_eq!(plan.dropped_dates, 1);
        assert_eq!(plan.order, None);
        assert_eq!(record_share(&[], &[], "Dana", "n/a", 1.0), None);
        let unnamed = record_share(&["5"], &[&[1.0]], "", "5", 2.0).expect("digits");
        assert!(!unnamed.renames);
    }

    #[test]
    fn a_thirteenth_recipient_evicts_the_weakest() {
        let phones: Vec<String> = (0..12).map(|i| format!("555{i}")).collect();
        let phone_refs: Vec<&str> = phones.iter().map(String::as_str).collect();
        let heavy: Vec<f64> = (0..10).map(|k| 1_000.0 - f64::from(k)).collect();
        let light = [0.0];
        let mut dates: Vec<&[f64]> = vec![&light; 12];
        dates[3] = &heavy;
        let plan = record_share(&phone_refs, &dates, "New", "999", 1_000.0).expect("digits");
        assert_eq!(plan.matched, None);
        let order = plan.order.expect("overflow");
        assert_eq!(order.len(), MAX_RECIPIENTS);
        assert_eq!(order[0], 3);
        assert_eq!(order[1], 12, "the new share is the next strongest");
    }

    #[test]
    fn corridors_go_when_stale_arrived_or_passed_and_stay_with_no_fix() {
        let lats: Vec<f64> = (0..=20)
            .map(|i| 43.07 + (43.04 - 43.07) * f64::from(i) / 20.0)
            .collect();
        let lons: Vec<f64> = (0..=20)
            .map(|i| -89.40 + (-87.91 + 89.40) * f64::from(i) / 20.0)
            .collect();
        let c = Corridor {
            saved_at: 0.0,
            lats: &lats,
            lons: &lons,
        };
        assert!(keep_corridor(c, 0.0, Some((43.07, -89.40))));
        assert!(!keep_corridor(c, 0.0, Some((43.04, -87.91))), "arrived");
        assert!(!keep_corridor(c, 0.0, Some((45.5, -89.0))), "passed");
        assert!(!keep_corridor(c, 8.0 * 86_400.0, None), "stale");
        assert!(keep_corridor(c, 6.0 * 86_400.0, None));
        assert!(!keep_corridor(c, f64::NAN, None));
        let empty = Corridor {
            saved_at: 0.0,
            lats: &[],
            lons: &[],
        };
        assert!(!keep_corridor(empty, 0.0, Some((43.0, -89.0))));
    }

    #[test]
    fn pruning_keeps_the_newest_three_and_recording_replaces_the_same_destination() {
        let views: Vec<Corridor<'_>> = (0..8)
            .map(|i| Corridor {
                saved_at: -f64::from(i) * 60.0,
                lats: &[],
                lons: &[],
            })
            .collect();
        assert_eq!(prune_corridors(&views, 0.0, None), vec![0, 1, 2]);
        let ends = [Some((43.04, -87.91)), Some((41.88, -87.63)), None];
        assert_eq!(
            record_corridor(&[0.0, 10.0, 20.0], &ends, Some((43.04, -87.91)), 30.0),
            vec![3, 2, 1]
        );
        assert!(worth_saving(25_000.0));
        assert!(!worth_saving(24_999.0));
        assert!(!supersedes(None, Some((0.0, 0.0))));
    }

    #[test]
    fn decimation_thins_keeps_the_destination_and_samples_long_lines_evenly() {
        let lats: Vec<f64> = (0..=5_000).map(|i| 43.0 + f64::from(i) * 0.0001).collect();
        let lons = vec![-89.0; lats.len()];
        let thin = decimate(&lats, &lons, DECIMATE_STEP_METERS, DECIMATE_LIMIT);
        assert!(thin.len() < lats.len() / 5);
        assert_eq!(*thin.last().expect("points"), 5_000);
        let sampled = decimate(&lats, &lons, 0.0, 3);
        assert_eq!(sampled, vec![0, 2_500, 5_000]);
        assert_eq!(decimate(&lats, &lons, 0.0, 0), Vec::<usize>::new());
        assert_eq!(decimate(&lats, &lons, 0.0, 1), vec![0]);
        assert_eq!(decimate(&lats, &lons, 0.0, -4), Vec::<usize>::new());
        assert_eq!(decimate(&[], &[], 400.0, 1_200), Vec::<usize>::new());
    }
}
