// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The corridor blend: every check point of a road scored in one call with
//! the two-tier equation the map uses — `RouteBlend.blend` at commit
//! 91798be, which was the loop inside `AppModel.scoredWithFeeds` and its
//! copy in the live corridor watch, with `RiskEquations.bandInput`.
//!
//! Per check point: the modeled ZIP field's row and the nearest forecast's
//! families are PREDICTORS; forecast rain is amplified where the road sits
//! at the local low or flood evidence (a gauge in flood, mapped water) is
//! near; the live feeds, an in-progress-danger alert and a reported closure
//! are what can reach Red. Along the way it keeps the worst reading per
//! family (the route filters and the route card read them) and the sum of
//! the field's "environmental" score.
//!
//! The Swift kept its families in dictionaries; here each is a fixed slot
//! ([`crate::families::dense_family_index`]) with its own "is it there"
//! mark, because the Swift's `max(out[fam] ?? 0, v)` reads a missing family
//! as 0 and a present NaN as NaN. Every `max`/`min` is the Swift's
//! ([`crate::fcmp`]). Pinned by
//! `flows-bridge/tests/fixtures/swift_route_blend_oracle.tsv`.

use crate::alerts::{is_life_safety, is_lookout};
use crate::families::{
    alert_family_scored, dense_family_index, flood_elevation_multiplier, realized_risk_dense,
    DENSE_FAMILY_COUNT,
};
use crate::fcmp::{smax, smin};
use crate::forecast::{predictor_families, Conditions};
use crate::hazard_feeds::{
    closure_score_cols, flood_gauge_score, water_proximity_score_cols, LiveFamilies, Point,
    LIVE_FAMILY_NAMES,
};
use crate::risk_field::RiskField;

/// One check point of the road.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Sample<'a> {
    /// Latitude, degrees.
    pub lat: f64,
    /// Longitude, degrees.
    pub lon: f64,
    /// The severity of the worst alert covering the point (0 with none).
    pub severity: f64,
    /// That alert's event name, when there is one.
    pub event: Option<&'a str>,
}

/// The forecast fetched at one check point.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Forecast {
    /// The check point it was fetched at (an index into the samples).
    pub sample: usize,
    /// Temperature, wind and chance of rain.
    pub conditions: Conditions,
    /// Rain amount for the coming hours, inches.
    pub qpf_inches: Option<f64>,
    /// Ground elevation at the point, metres.
    pub elevation_meters: Option<f64>,
}

/// What is the same at every check point: the flood evidence and the closed
/// roads. An empty list scores 0, as a caller without that feed did.
#[derive(Clone, Copy, Debug, Default)]
pub struct Feeds<'a> {
    /// River gauges as (latitude, longitude, flood category).
    pub gauges: &'a [(f64, f64, String)],
    /// Mapped water, latitudes.
    pub water_lats: &'a [f64],
    /// Mapped water, longitudes.
    pub water_lons: &'a [f64],
    /// Closed-road points, latitudes.
    pub closure_lats: &'a [f64],
    /// Closed-road points, longitudes.
    pub closure_lons: &'a [f64],
}

/// The families whose worst reading along the road is kept, in
/// [`Answer::peaks`] order: the four route filters, then the live feeds
/// (their "convective" shares the filter's slot, as it shared its key).
pub const PEAK_FAMILY_NAMES: [&str; 11] = [
    "wind",
    "qpf_flood",
    "winter",
    "convective",
    "fire",
    "seismic",
    "radiation",
    "volcanic",
    "avalanche",
    "tropical",
    "tsunami",
];

/// The route filters: (peak slot = position, forecast family position in
/// [`crate::forecast::PREDICTOR_FAMILY_NAMES`]). The flood filter reads the
/// forecast's "precip".
const FILTER_FORECAST: [usize; 4] = [0, 1, 4, 5];
/// The peak slot of each live family, in [`LIVE_FAMILY_NAMES`] order.
const LIVE_PEAK_SLOT: [usize; 8] = [4, 5, 6, 7, 8, 9, 10, 3];
/// Whose forecast a check point borrows: its own, else the nearest fetched
/// neighbour's, in this order (the planner fetches every other point).
const NEIGHBOURS: [isize; 5] = [0, -1, 1, -2, 2];
/// The local low is the lowest fetched elevation within this many check
/// points either side.
const LOCAL_LOW_WINDOW: usize = 4;

/// What [`blend`] answers.
#[derive(Clone, Debug, PartialEq)]
pub struct Answer {
    /// One realized risk per check point, in order.
    pub risks: Vec<f64>,
    /// The worst reading per [`PEAK_FAMILY_NAMES`] family; `None` where
    /// nothing above 0 was read.
    pub peaks: [Option<f64>; 11],
    /// The sum of the field's "environmental" score over the check points.
    pub identified_sum: f64,
    /// A check point the live scorer could not answer: not a clear point.
    pub live_unchecked: bool,
}

/// The band input's fixed slots, found once per road.
struct Slots {
    wind: Option<usize>,
    heat: Option<usize>,
    cold: Option<usize>,
    air: Option<usize>,
    radiation: Option<usize>,
    winter: Option<usize>,
    convective: Option<usize>,
    precip: Option<usize>,
    closure: Option<usize>,
    live: [Option<usize>; 8],
}

/// The field's columns the blend reads, found once per road.
struct Columns {
    environmental: Option<usize>,
    wind: Option<usize>,
    qpf_flood: Option<usize>,
    winter: Option<usize>,
    convective: Option<usize>,
    heat: Option<usize>,
    cold: Option<usize>,
    air: Option<usize>,
    radiation: Option<usize>,
}

/// `out[fam] = max(out[fam] ?? 0, v)`.
fn raise(out: &mut [Option<f64>; DENSE_FAMILY_COUNT], slot: Option<usize>, v: f64) {
    if let Some(cell) = slot.and_then(|i| out.get_mut(i)) {
        *cell = Some(smax(cell.unwrap_or(0.0), v));
    }
}

/// `out[fam] = v`.
fn put(out: &mut [Option<f64>; DENSE_FAMILY_COUNT], slot: Option<usize>, v: f64) {
    if let Some(cell) = slot.and_then(|i| out.get_mut(i)) {
        *cell = Some(v);
    }
}

/// `RouteBlend.blend`: score every check point.
///
/// `forecasts` name the check point each was fetched at; one naming a point
/// past the end is ignored, and of two naming the same point the first
/// counts (the Swift held them in a dictionary, one per point). `live`
/// scores one point against the live feeds — `None` from it means the scorer
/// gave no answer, which marks the road unchecked and adds nothing; with no
/// `live` at all there are no live feeds and nothing to leave unchecked.
///
/// Deterministic; allocates the answer and two per-road tables; panics: none.
#[must_use]
pub fn blend(
    samples: &[Sample<'_>],
    forecasts: &[Forecast],
    field: Option<&RiskField>,
    feeds: &Feeds<'_>,
    mut live: Option<&mut dyn FnMut(Point) -> Option<LiveFamilies>>,
) -> Answer {
    let n = samples.len();
    // Which forecast was fetched at each check point.
    let mut fetched: Vec<Option<usize>> = vec![None; n];
    for (k, f) in forecasts.iter().enumerate() {
        if let Some(cell) = fetched.get_mut(f.sample) {
            if cell.is_none() {
                *cell = Some(k);
            }
        }
    }
    // A point with no forecast of its own borrows its neighbour's, so each
    // forecast's families are worked out once.
    let mut families_of: Vec<Option<[f64; 6]>> = vec![None; forecasts.len()];
    let nearest_forecast = |i: usize| -> Option<usize> {
        NEIGHBOURS.iter().find_map(|&step| {
            let j = i.checked_add_signed(step)?;
            fetched.get(j).copied().flatten()
        })
    };

    let column = |name: &str| field.and_then(|f| f.family_index(name));
    let columns = Columns {
        environmental: column("environmental"),
        wind: column("wind"),
        qpf_flood: column("qpf_flood"),
        winter: column("winter"),
        convective: column("convective"),
        heat: column("heat"),
        cold: column("cold"),
        air: column("air"),
        radiation: column("radiation"),
    };
    let filter_columns = [
        columns.wind,
        columns.qpf_flood,
        columns.winter,
        columns.convective,
    ];
    let slots = Slots {
        wind: dense_family_index("wind"),
        heat: dense_family_index("heat"),
        cold: dense_family_index("cold"),
        air: dense_family_index("air"),
        radiation: dense_family_index("radiation"),
        winter: dense_family_index("winter"),
        convective: dense_family_index("convective"),
        precip: dense_family_index("precip"),
        closure: dense_family_index("closure"),
        live: LIVE_FAMILY_NAMES.map(dense_family_index),
    };

    let mut peaks: [Option<f64>; 11] = [None; 11];
    let mut identified_sum = 0.0;
    let mut live_unchecked = false;
    let mut risks = Vec::with_capacity(n);
    for (i, s) in samples.iter().enumerate() {
        let p: Point = (s.lat, s.lon);
        let near = nearest_forecast(i).and_then(|k| forecasts.get(k).map(|f| (k, f)));
        let dev: Option<[f64; 6]> = near.and_then(|(k, f)| {
            if let Some(done) = families_of.get(k).copied().flatten() {
                return Some(done);
            }
            // The families are the FETCHED point's, not the borrower's.
            let at = samples.get(f.sample)?;
            let made = predictor_families(&f.conditions, at.lat, at.lon, f.elevation_meters);
            if let Some(cell) = families_of.get_mut(k) {
                *cell = Some(made);
            }
            Some(made)
        });
        let device = |position: usize| dev.and_then(|d| d.get(position).copied()).unwrap_or(0.0);

        // One nearest-ZIP row per check point.
        let row: Option<&[f64]> = field.and_then(|f| {
            f.nearest(s.lat, s.lon)
                .and_then(|at| f.entries().get(at))
                .map(|e| e.scores.as_slice())
        });
        let row_score = |col: Option<usize>| -> f64 {
            match (row, col) {
                (Some(r), Some(c)) => r.get(c).copied().unwrap_or(0.0),
                _ => 0.0,
            }
        };
        identified_sum += row_score(columns.environmental);

        // The local low: the lowest fetched elevation near this point.
        let mut local_low: Option<f64> = None;
        if n > 0 {
            let last = (i + LOCAL_LOW_WINDOW).min(n - 1);
            for j in i.saturating_sub(LOCAL_LOW_WINDOW)..=last {
                let elevation = fetched
                    .get(j)
                    .copied()
                    .flatten()
                    .and_then(|k| forecasts.get(k))
                    .and_then(|f| f.elevation_meters);
                if let Some(e) = elevation {
                    local_low = Some(local_low.map_or(e, |lo| smin(lo, e)));
                }
            }
        }
        // Flood evidence: a gauge in flood or mapped water near (noisy-OR).
        let gauge = flood_gauge_score(feeds.gauges, p);
        let water = water_proximity_score_cols(feeds.water_lats, feeds.water_lons, p);
        let evidence = 1.0 - (1.0 - gauge) * (1.0 - water);
        let flood_multiplier = flood_elevation_multiplier(
            near.and_then(|(_, f)| f.elevation_meters),
            local_low,
            near.and_then(|(_, f)| f.qpf_inches),
            evidence,
        );

        // The route filters: the worse of the field and the forecast.
        for (slot, (col, position)) in filter_columns.iter().zip(FILTER_FORECAST).enumerate() {
            let v = smax(row_score(*col), device(position));
            if let Some(peak) = peaks.get_mut(slot) {
                if v > peak.unwrap_or(0.0) {
                    *peak = Some(v);
                }
            }
        }

        // The live feeds: only families that registered (> 0) count.
        let mut live_values: Option<[f64; 8]> = None;
        if let Some(score) = live.as_mut() {
            match score(p) {
                Some(answer) => live_values = Some(answer.values()),
                None => live_unchecked = true,
            }
        }
        if let Some(values) = live_values {
            for (v, slot) in values.iter().zip(LIVE_PEAK_SLOT) {
                if *v > 0.0 {
                    if let Some(peak) = peaks.get_mut(slot) {
                        if *v > peak.unwrap_or(0.0) {
                            *peak = Some(*v);
                        }
                    }
                }
            }
        }

        // RiskEquations.bandInput.
        let mut out: [Option<f64>; DENSE_FAMILY_COUNT] = [None; DENSE_FAMILY_COUNT];
        put(
            &mut out,
            slots.wind,
            smax(row_score(columns.wind), device(0)),
        );
        put(
            &mut out,
            slots.heat,
            smax(row_score(columns.heat), device(2)),
        );
        put(
            &mut out,
            slots.cold,
            smax(row_score(columns.cold), device(3)),
        );
        put(&mut out, slots.air, row_score(columns.air));
        put(&mut out, slots.radiation, row_score(columns.radiation));
        put(
            &mut out,
            slots.winter,
            smax(row_score(columns.winter), device(4)),
        );
        put(
            &mut out,
            slots.convective,
            smax(row_score(columns.convective), device(5)),
        );
        put(
            &mut out,
            slots.precip,
            smin(
                1.0,
                smax(row_score(columns.qpf_flood), device(1)) * flood_multiplier,
            ),
        );
        if let Some(values) = live_values {
            for (v, slot) in values.iter().zip(slots.live) {
                if *v > 0.0 {
                    raise(&mut out, slot, *v);
                }
            }
        }
        if let Some(event) = s.event {
            // An alert no weather family maps — radiological, hazmat,
            // shelter-in-place, civil danger, evacuation — is for routing
            // what a closure is: proof the road should not be driven.
            if let Some(slot) = alert_family_scored(event).and_then(dense_family_index) {
                raise(&mut out, Some(slot), s.severity);
            } else if is_life_safety(event) && !is_lookout(event) {
                raise(&mut out, slots.closure, s.severity);
            }
        }
        let closure = closure_score_cols(feeds.closure_lats, feeds.closure_lons, p);
        if closure > 0.0 {
            raise(&mut out, slots.closure, closure);
        }
        let dense = out.map(|v| v.unwrap_or(f64::NAN));
        risks.push(realized_risk_dense(&dense).unwrap_or(f64::NAN));
    }
    Answer {
        risks,
        peaks,
        identified_sum,
        live_unchecked,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::risk_field::Entry;

    fn sample(lat: f64, lon: f64) -> Sample<'static> {
        Sample {
            lat,
            lon,
            severity: 0.0,
            event: None,
        }
    }

    fn quiet() -> LiveFamilies {
        LiveFamilies {
            fire: 0.0,
            seismic: 0.0,
            space_radiation: 0.0,
            volcanic: 0.0,
            avalanche: 0.0,
            tropical: 0.0,
            tsunami: 0.0,
            convective: 0.0,
        }
    }

    #[test]
    fn the_peak_names_line_up_with_the_live_families() {
        for (name, slot) in LIVE_FAMILY_NAMES.iter().zip(LIVE_PEAK_SLOT) {
            assert_eq!(PEAK_FAMILY_NAMES.get(slot), Some(name));
        }
        // Every family the blend writes has a dense slot.
        for name in [
            "wind",
            "heat",
            "cold",
            "air",
            "radiation",
            "winter",
            "convective",
            "precip",
            "closure",
        ] {
            assert!(dense_family_index(name).is_some(), "{name}");
        }
        for name in LIVE_FAMILY_NAMES {
            assert!(dense_family_index(name).is_some(), "{name}");
        }
    }

    #[test]
    fn no_check_points_is_an_empty_answer() {
        let a = blend(&[], &[], None, &Feeds::default(), None);
        assert!(a.risks.is_empty());
        assert_eq!(a.peaks, [None; 11]);
        assert_eq!(a.identified_sum.to_bits(), 0.0_f64.to_bits());
        assert!(!a.live_unchecked);
    }

    #[test]
    fn a_live_scorer_with_no_answer_marks_the_road_unchecked() {
        let road = [sample(43.07, -89.4), sample(43.08, -89.41)];
        let mut calls = 0;
        let mut scorer = |_: Point| {
            calls += 1;
            if calls == 2 {
                None
            } else {
                Some(quiet())
            }
        };
        let a = blend(&road, &[], None, &Feeds::default(), Some(&mut scorer));
        assert!(a.live_unchecked);
        assert_eq!(a.risks.len(), 2);
        // Without a scorer there is nothing to leave unchecked.
        let b = blend(&road, &[], None, &Feeds::default(), None);
        assert!(!b.live_unchecked);
    }

    #[test]
    fn a_live_fire_reaches_the_peaks_and_the_risk() {
        let road = [sample(43.07, -89.4)];
        let mut scorer = |_: Point| {
            Some(LiveFamilies {
                fire: 0.9,
                ..quiet()
            })
        };
        let a = blend(&road, &[], None, &Feeds::default(), Some(&mut scorer));
        assert_eq!(a.peaks.get(4).copied().flatten(), Some(0.9));
        let clear = blend(&road, &[], None, &Feeds::default(), None);
        assert!(a.risks.first() > clear.risks.first());
    }

    #[test]
    fn the_field_feeds_the_sum_and_the_filter_peaks() {
        let field = RiskField::from_entries(
            String::new(),
            vec!["environmental".to_string(), "wind".to_string()],
            vec![Entry {
                zip: "53703".to_string(),
                lat: 43.07,
                lon: -89.4,
                scores: vec![0.25, 0.5],
                summary: None,
                ring: None,
            }],
        );
        let road = [sample(43.07, -89.4), sample(43.071, -89.401)];
        let a = blend(&road, &[], Some(&field), &Feeds::default(), None);
        assert_eq!(a.identified_sum, 0.5);
        assert_eq!(a.peaks.first().copied().flatten(), Some(0.5));
    }

    #[test]
    fn a_forecast_past_the_end_is_ignored_and_the_first_of_two_counts() {
        let road = [sample(43.07, -89.4)];
        let windy = Forecast {
            sample: 0,
            conditions: Conditions {
                temperature_f: Some(60.0),
                wind_mph: Some(70.0),
                pop_percent: Some(0.0),
            },
            qpf_inches: None,
            elevation_meters: None,
        };
        let calm = Forecast {
            conditions: Conditions {
                temperature_f: Some(60.0),
                wind_mph: Some(0.0),
                pop_percent: Some(0.0),
            },
            ..windy
        };
        let stray = Forecast { sample: 9, ..windy };
        let first = blend(&road, &[windy, calm], None, &Feeds::default(), None);
        let only = blend(&road, &[windy], None, &Feeds::default(), None);
        assert_eq!(first, only);
        let none = blend(&road, &[stray], None, &Feeds::default(), None);
        assert_eq!(none, blend(&road, &[], None, &Feeds::default(), None));
        assert!(only.peaks.first().copied().flatten().is_some());
    }
}
