// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::risk_field`: the ZIP-level risk field as
//! one opaque Rust type, [`FlowsRiskField`], parsed once from the FRB1 bundle
//! (or built from the JSON path's columns) and queried in place. Functions
//! are named `flows_risk_field_…`; the type's methods are Swift methods.
//!
//! Columns cross as parallel lists; names and summaries joined by U+001F
//! (an absent summary is an empty piece, so `has_summary` tells them
//! apart); rings as a per-entry point count, a presence flag and one flat
//! (lat, lon) list — the flag because an entry may carry an empty ring.
//! swift-bridge must never see an empty buffer, so the facade passes a
//! one-element placeholder for a column that would be empty and the counts
//! say it holds nothing. Optional answers are `-1` for no index and the
//! empty string for no text. The rescore takes the harmonic table's own
//! handle ([`crate::climate::FlowsHarmonicTable`]).
//!
//! Every function is a thin forwarder through [`contain`], so a panic inside
//! the core becomes the documented fallback instead of crossing into Swift.

// The glue swift-bridge generates for a `&mut self` method on an opaque
// type casts a pointer to its own type; the lint is about that generated
// code, not ours.
#![allow(clippy::unnecessary_cast)]

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        #[swift_bridge(already_declared)]
        type FlowsHarmonicTable;
    }

    extern "Rust" {
        type FlowsRiskField;
        fn flows_risk_field_parse_frb1(data: &[u8]) -> Option<FlowsRiskField>;
        fn flows_risk_field_empty(generated: &str, families_joined: &str) -> FlowsRiskField;
        fn flows_risk_field_from_columns(
            generated: &str,
            families_joined: &str,
            zips_joined: &str,
            lats: &[f64],
            lons: &[f64],
            score_counts: &[i64],
            scores: &[f64],
            summaries_joined: &str,
            has_summary: &[i64],
            ring_counts: &[i64],
            has_ring: &[i64],
            ring_points: &[f64],
        ) -> Option<FlowsRiskField>;
        fn generated(self: &FlowsRiskField) -> String;
        fn families(self: &FlowsRiskField) -> Vec<String>;
        fn family_index(self: &FlowsRiskField, family: &str) -> i64;
        fn count(self: &FlowsRiskField) -> i64;
        fn zip(self: &FlowsRiskField, index: i64) -> String;
        fn latitude(self: &FlowsRiskField, index: i64) -> f64;
        fn longitude(self: &FlowsRiskField, index: i64) -> f64;
        fn scores(self: &FlowsRiskField, index: i64) -> Vec<f64>;
        fn has_summary(self: &FlowsRiskField, index: i64) -> bool;
        fn summary(self: &FlowsRiskField, index: i64) -> String;
        fn has_ring(self: &FlowsRiskField, index: i64) -> bool;
        fn ring(self: &FlowsRiskField, index: i64) -> Vec<f64>;
        fn nearest(self: &FlowsRiskField, latitude: f64, longitude: f64) -> i64;
        fn select(
            self: &FlowsRiskField,
            lat_min: f64,
            lat_max: f64,
            lon_min: f64,
            lon_max: f64,
            family_index: i64,
            limit: i64,
        ) -> Vec<i64>;
        fn harmonic_rescore(
            self: &mut FlowsRiskField,
            table: &FlowsHarmonicTable,
            week: i64,
        ) -> i64;
    }
}

use crate::climate::FlowsHarmonicTable;
use crate::contain;
use flows_core::climate::WeekTrig;
use flows_core::risk_field::{Entry, RiskField};

/// The field behind Swift's `RiskFieldService`.
pub struct FlowsRiskField(RiskField);

const JOIN: char = '\u{1F}';

fn split_joined(joined: &str) -> Vec<String> {
    if joined.is_empty() {
        return Vec::new();
    }
    joined.split(JOIN).map(str::to_string).collect()
}

fn index(i: i64) -> Option<usize> {
    usize::try_from(i).ok()
}

fn as_i64(n: usize) -> i64 {
    i64::try_from(n).unwrap_or(-1)
}

pub fn flows_risk_field_parse_frb1(data: &[u8]) -> Option<FlowsRiskField> {
    contain(None, || RiskField::parse_frb1(data).map(FlowsRiskField))
}

pub fn flows_risk_field_empty(generated: &str, families_joined: &str) -> FlowsRiskField {
    FlowsRiskField(RiskField::from_entries(
        generated.to_string(),
        split_joined(families_joined),
        Vec::new(),
    ))
}

/// The JSON path's entries as columns; `None` when the columns disagree in
/// length or a count runs past its list.
#[allow(clippy::too_many_arguments)]
pub fn flows_risk_field_from_columns(
    generated: &str,
    families_joined: &str,
    zips_joined: &str,
    lats: &[f64],
    lons: &[f64],
    score_counts: &[i64],
    scores: &[f64],
    summaries_joined: &str,
    has_summary: &[i64],
    ring_counts: &[i64],
    has_ring: &[i64],
    ring_points: &[f64],
) -> Option<FlowsRiskField> {
    contain(None, || {
        let zips = split_joined(zips_joined);
        let summaries = split_joined(summaries_joined);
        let n = zips.len();
        if lats.len() != n
            || lons.len() != n
            || score_counts.len() != n
            || summaries.len() != n
            || has_summary.len() != n
            || ring_counts.len() != n
            || has_ring.len() != n
        {
            return None;
        }
        let mut score_at = 0usize;
        let mut point_at = 0usize;
        let mut entries = Vec::with_capacity(n);
        for i in 0..n {
            let count = index(score_counts[i])?;
            let row = scores.get(score_at..score_at.checked_add(count)?)?.to_vec();
            score_at += count;
            let points = index(ring_counts[i])?;
            let flat = ring_points.get(point_at..point_at.checked_add(points.checked_mul(2)?)?)?;
            point_at += points * 2;
            // The caller already applied the JSON path's three-point rule; a
            // ring here is whatever the entry carried, empty included.
            let ring = (has_ring[i] != 0).then(|| flat.chunks(2).map(|p| (p[0], p[1])).collect());
            entries.push(Entry {
                zip: zips[i].clone(),
                lat: lats[i],
                lon: lons[i],
                scores: row,
                summary: (has_summary[i] != 0).then(|| summaries[i].clone()),
                ring,
            });
        }
        Some(FlowsRiskField(RiskField::from_entries(
            generated.to_string(),
            split_joined(families_joined),
            entries,
        )))
    })
}

impl FlowsRiskField {
    fn entry(&self, index: i64) -> Option<&Entry> {
        self.0.entries().get(usize::try_from(index).ok()?)
    }
    pub fn generated(&self) -> String {
        self.0.generated().to_string()
    }
    pub fn families(&self) -> Vec<String> {
        self.0.families().to_vec()
    }
    pub fn family_index(&self, family: &str) -> i64 {
        contain(-1, || self.0.family_index(family).map_or(-1, as_i64))
    }
    pub fn count(&self) -> i64 {
        as_i64(self.0.entries().len())
    }
    pub fn zip(&self, index: i64) -> String {
        self.entry(index).map(|e| e.zip.clone()).unwrap_or_default()
    }
    pub fn latitude(&self, index: i64) -> f64 {
        self.entry(index).map_or(f64::NAN, |e| e.lat)
    }
    pub fn longitude(&self, index: i64) -> f64 {
        self.entry(index).map_or(f64::NAN, |e| e.lon)
    }
    pub fn scores(&self, index: i64) -> Vec<f64> {
        self.entry(index)
            .map(|e| e.scores.clone())
            .unwrap_or_default()
    }
    pub fn has_summary(&self, index: i64) -> bool {
        self.entry(index).is_some_and(|e| e.summary.is_some())
    }
    pub fn summary(&self, index: i64) -> String {
        self.entry(index)
            .and_then(|e| e.summary.clone())
            .unwrap_or_default()
    }
    pub fn has_ring(&self, index: i64) -> bool {
        self.entry(index).is_some_and(|e| e.ring.is_some())
    }
    /// The ring as (lat, lon) pairs, flat.
    pub fn ring(&self, index: i64) -> Vec<f64> {
        self.entry(index)
            .and_then(|e| e.ring.as_ref())
            .map(|r| r.iter().flat_map(|&(lat, lon)| [lat, lon]).collect())
            .unwrap_or_default()
    }
    pub fn nearest(&self, latitude: f64, longitude: f64) -> i64 {
        contain(-1, || {
            self.0.nearest(latitude, longitude).map_or(-1, as_i64)
        })
    }
    pub fn select(
        &self,
        lat_min: f64,
        lat_max: f64,
        lon_min: f64,
        lon_max: f64,
        family_index: i64,
        limit: i64,
    ) -> Vec<i64> {
        contain(Vec::new(), || {
            self.0
                .select(lat_min, lat_max, lon_min, lon_max, family_index, limit)
                .into_iter()
                .map(as_i64)
                .collect()
        })
    }
    /// The week-correct rescore against the harmonic table; the rebuilt count.
    pub fn harmonic_rescore(&mut self, table: &FlowsHarmonicTable, week: i64) -> i64 {
        let pairs = self.0.family_pairs(table.inner());
        let trig = WeekTrig::new(week);
        let field = &mut self.0;
        contain(0, || {
            as_i64(field.harmonic_rescore(table.inner(), &trig, &pairs))
        })
    }
}
