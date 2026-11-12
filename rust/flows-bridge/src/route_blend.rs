// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::route_blend`: a whole road scored in one
//! call, [`flows_route_blend`], behind Swift's `RouteBlend.blend`.
//!
//! The ZIP field and the live snapshot cross as the handles Swift already
//! holds ([`crate::risk_field::FlowsRiskField`],
//! [`crate::hazard_feeds::FlowsHazardSnapshot`]); a caller with no field
//! passes an empty one (it scores 0 everywhere, as no field did) and one
//! with no snapshot says so with `has_snapshot`. Check points cross as one
//! flat list of (latitude, longitude, alert severity); their alert events as
//! a joined text column with lengths and presence; forecasts as two marks
//! each (the check point's index, then a bit per value that is there:
//! 1 temperature, 2 wind, 4 chance of rain, 8 rain amount, 16 elevation)
//! and five values each in that order; gauges, mapped water and closures as
//! the columns Swift lays out once. swift-bridge must never see an empty
//! buffer, so an empty column is a one-element placeholder and its count
//! says it holds nothing.
//!
//! The answer is one list: a risk per check point, then the identified sum,
//! then 1 when a point's live score could not be worked out (else 0), then
//! the eleven family peaks in `PEAK_FAMILY_NAMES` order with NaN for a
//! family nothing registered in. An EMPTY list means the call failed —
//! columns that do not line up, or a panic inside — and the facade treats
//! the road as unchecked, never as clear.

#![allow(clippy::too_many_arguments)] // flattened Swift signatures

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        #[swift_bridge(already_declared)]
        type FlowsRiskField;
        #[swift_bridge(already_declared)]
        type FlowsHazardSnapshot;
    }

    extern "Rust" {
        fn flows_route_blend(
            field: &FlowsRiskField,
            snapshot: &FlowsHazardSnapshot,
            has_snapshot: bool,
            samples: &[f64],
            sample_count: i64,
            events_joined: &str,
            event_lens: &[i64],
            event_present: &[u8],
            forecast_marks: &[i64],
            forecast_values: &[f64],
            forecast_count: i64,
            gauge_lats: &[f64],
            gauge_lons: &[f64],
            gauge_categories_joined: &str,
            gauge_count: i64,
            water_lats: &[f64],
            water_lons: &[f64],
            water_count: i64,
            closure_lats: &[f64],
            closure_lons: &[f64],
            closure_count: i64,
        ) -> Vec<f64>;
    }
}

use crate::contain;
use crate::hazard_feeds::FlowsHazardSnapshot;
use crate::risk_field::FlowsRiskField;
use flows_core::forecast::Conditions;
use flows_core::hazard_feeds as hf;
use flows_core::hazard_feeds::Point;
use flows_core::route_blend::{blend, Feeds, Forecast, Sample};

/// The first `count` values of a column; `None` when it holds fewer.
fn first<T>(column: &[T], count: i64) -> Option<&[T]> {
    column.get(..usize::try_from(count).ok()?)
}

/// The forecasts from their marks and values; `None` when they do not line
/// up or an index is negative.
fn forecasts(marks: &[i64], values: &[f64], count: i64) -> Option<Vec<Forecast>> {
    let count = usize::try_from(count).ok()?;
    let marks = marks.get(..count.checked_mul(2)?)?;
    let values = values.get(..count.checked_mul(5)?)?;
    marks
        .chunks_exact(2)
        .zip(values.chunks_exact(5))
        .map(|(m, v)| {
            let sample = usize::try_from(*m.first()?).ok()?;
            let there = *m.get(1)?;
            let value = |bit: usize| -> Option<f64> {
                if there & (1 << bit) == 0 {
                    None
                } else {
                    v.get(bit).copied()
                }
            };
            Some(Forecast {
                sample,
                conditions: Conditions {
                    temperature_f: value(0),
                    wind_mph: value(1),
                    pop_percent: value(2),
                },
                qpf_inches: value(3),
                elevation_meters: value(4),
            })
        })
        .collect()
}

/// `RouteBlend.blend` (see the module notes for the layout). An empty list
/// is the failure answer.
pub fn flows_route_blend(
    field: &FlowsRiskField,
    snapshot: &FlowsHazardSnapshot,
    has_snapshot: bool,
    samples: &[f64],
    sample_count: i64,
    events_joined: &str,
    event_lens: &[i64],
    event_present: &[u8],
    forecast_marks: &[i64],
    forecast_values: &[f64],
    forecast_count: i64,
    gauge_lats: &[f64],
    gauge_lons: &[f64],
    gauge_categories_joined: &str,
    gauge_count: i64,
    water_lats: &[f64],
    water_lons: &[f64],
    water_count: i64,
    closure_lats: &[f64],
    closure_lons: &[f64],
    closure_count: i64,
) -> Vec<f64> {
    contain(Vec::new(), || {
        let made = || -> Option<Vec<f64>> {
            let n = usize::try_from(sample_count).ok()?;
            let columns = samples.get(..n.checked_mul(3)?)?;
            let events = crate::split_texts(events_joined, event_lens, n)?;
            let present = event_present.get(..n)?;
            let road: Vec<Sample<'_>> = columns
                .chunks_exact(3)
                .zip(events.iter().zip(present))
                .filter_map(|(c, (event, there))| {
                    Some(Sample {
                        lat: *c.first()?,
                        lon: *c.get(1)?,
                        severity: *c.get(2)?,
                        event: (*there != 0).then_some(*event),
                    })
                })
                .collect();
            if road.len() != n {
                return None;
            }
            let fetched = forecasts(forecast_marks, forecast_values, forecast_count)?;
            let gauges = if gauge_count > 0 {
                let g = crate::hazard_feeds::named(
                    first(gauge_lats, gauge_count)?,
                    first(gauge_lons, gauge_count)?,
                    gauge_categories_joined,
                );
                if g.len() != usize::try_from(gauge_count).ok()? {
                    return None;
                }
                g
            } else {
                Vec::new()
            };
            let feeds = Feeds {
                gauges: &gauges,
                water_lats: first(water_lats, water_count)?,
                water_lons: first(water_lons, water_count)?,
                closure_lats: first(closure_lats, closure_count)?,
                closure_lons: first(closure_lons, closure_count)?,
            };
            let s = &snapshot.0;
            // A point whose live score panics is "not checked", and the rest
            // of the road is still scored.
            let mut scorer = |p: Point| {
                contain(None, || {
                    let boxes = snapshot.1.get_or_init(|| hf::ring_boxes(&s.perimeters));
                    Some(hf::live_boxed(p, s, boxes))
                })
            };
            let answer = if has_snapshot {
                blend(&road, &fetched, Some(&field.0), &feeds, Some(&mut scorer))
            } else {
                blend(&road, &fetched, Some(&field.0), &feeds, None)
            };
            let mut out = answer.risks;
            out.push(answer.identified_sum);
            out.push(if answer.live_unchecked { 1.0 } else { 0.0 });
            out.extend(answer.peaks.iter().map(|p| p.unwrap_or(f64::NAN)));
            Some(out)
        };
        made().unwrap_or_default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hazard_feeds::flows_hazard_snapshot_new;
    use crate::risk_field::flows_risk_field_empty;

    fn call(samples: &[f64], n: i64, marks: &[i64], values: &[f64], fc: i64) -> Vec<f64> {
        let field = flows_risk_field_empty("", "", &[0], 0);
        let snap = flows_hazard_snapshot_new();
        flows_route_blend(
            &field,
            &snap,
            true,
            samples,
            n,
            "",
            &vec![0; usize::try_from(n).unwrap_or(0).max(1)],
            &vec![0; usize::try_from(n).unwrap_or(0).max(1)],
            marks,
            values,
            fc,
            &[0.0],
            &[0.0],
            "",
            0,
            &[0.0],
            &[0.0],
            0,
            &[0.0],
            &[0.0],
            0,
        )
    }

    #[test]
    fn the_answer_is_risks_then_sum_flag_and_eleven_peaks() {
        let out = call(
            &[43.07, -89.4, 0.0, 43.08, -89.41, 0.0],
            2,
            &[0, 0],
            &[0.0; 5],
            0,
        );
        assert_eq!(out.len(), 2 + 2 + 11);
        assert_eq!(out.get(3).copied(), Some(0.0), "live was checked");
    }

    #[test]
    fn columns_that_do_not_line_up_answer_nothing() {
        // Two check points named, one sent.
        assert!(call(&[43.07, -89.4, 0.0], 2, &[0, 0], &[0.0; 5], 0).is_empty());
        // A forecast named, its values short.
        assert!(call(&[43.07, -89.4, 0.0], 1, &[0, 1], &[60.0], 1).is_empty());
        // A negative forecast index.
        assert!(call(&[43.07, -89.4, 0.0], 1, &[-1, 1], &[0.0; 5], 1).is_empty());
        assert!(call(&[43.07, -89.4, 0.0], -1, &[0, 0], &[0.0; 5], 0).is_empty());
    }

    #[test]
    fn a_forecast_value_counts_only_when_its_bit_is_set() {
        let road = [43.07, -89.4, 0.0];
        let windy = call(&road, 1, &[0, 0b00111], &[60.0, 70.0, 0.0, 0.0, 0.0], 1);
        let unmarked = call(&road, 1, &[0, 0b00101], &[60.0, 70.0, 0.0, 0.0, 0.0], 1);
        assert!(windy.get(3).is_some_and(|w| *w > 0.0), "wind peak");
        assert_ne!(
            windy.get(3).map(|w| w.to_bits()),
            unmarked.get(3).map(|w| w.to_bits())
        );
    }
}
