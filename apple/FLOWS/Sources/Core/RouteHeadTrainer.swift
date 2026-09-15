// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// ON-DEVICE fine-tuning of the route-risk head.
///
/// Why this exists at all: the head is trained by `rust/flows-train`, which
/// reads and writes the macOS user's Application Support directory — while
/// the driving, and therefore the data, happens inside the iOS app's sandbox
/// container. Those are different filesystems on different devices, so the
/// learning loop could never close on the device that actually drives. And
/// now that trip history is sealed with a device-only Keychain key
/// (SecureBehaviorStore), no external process CAN read it, by design.
///
/// So training moves here. The model is tiny — 8 → 16 → 1, the same
/// contract `RouteFeatures` and the Rust trainer share — and a fine-tune
/// over a few hundred rows is milliseconds of scalar arithmetic off the
/// main actor.
///
/// WARM START, NOT FROM SCRATCH. Training begins from the shipped baseline
/// (20 years of NOAA Storm Events) and nudges it toward what this driver
/// actually encountered, with an ANCHOR term pulling weights back toward
/// the baseline. A dozen trips can refine the national model; they cannot
/// overwrite it. That is what makes "refine, not replace" true in the
/// weights themselves, instead of a comment describing an intent the code
/// did not implement — and it retires the old `rows`-count head selection,
/// which could never pick a device head against a 1,164,376-row baseline.
///
/// The gradient descent itself is computed in rust/flows-core (seasonal.rs)
/// and called through rust/flows-bridge; heads cross flat and rows as
/// sixteen numbers each (a value and a presence flag per column). Pinned bit
/// for bit to the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_seasonal_oracle.tsv.
enum RouteHeadTrainer {
    /// The bridge's row form: each of the eight columns as its value and a
    /// presence flag, because a present NaN and an absent column mean
    /// different things.
    private static let columns = ["oLat", "oLon", "dLat", "dLon", "week", "target", "weight", "crossCountry"]
    private static func flatRows(_ rows: [[String: Double]]) -> [Double] {
        rows.flatMap { r in columns.flatMap { [r[$0] ?? 0, r[$0] == nil ? 0 : 1] } }
    }


    /// Fine-tune `base` on the driver's rows. Pure and deterministic — same
    /// inputs, same weights out — so it is unit-testable without a device.
    ///
    /// - Parameters:
    ///   - rows: `trainingRows` dictionaries (oLat/oLon/dLat/dLon/week/
    ///     target/weight/crossCountry), already decrypted in memory.
    ///   - epochs: full passes; 60 is ample for a warm start.
    ///   - learningRate: deliberately small — this is a nudge.
    ///   - anchor: pull-back strength toward `base` (elastic anchoring).
    ///     0 would allow catastrophic forgetting from a handful of trips.
    static func fineTune(
        base: LearnedHead,
        rows: [[String: Double]],
        epochs: Int = Int(flows_seasonal_tune_epochs()),
        learningRate: Double = flows_seasonal_tune_learning_rate(),
        anchor: Double = flows_seasonal_tune_anchor()
    ) -> LearnedHead? {
        // No rows is no tune (and an empty buffer never crosses).
        guard !rows.isEmpty else { return nil }
        let head = base.bridgeFlat, flat = flatRows(rows)
        // The tuned head comes back flat with the sample count in front;
        // empty for "no tune" (a stale width, no finite target, a result
        // that is not finite).
        let out = head.withUnsafeBufferPointer { h in
            flat.withUnsafeBufferPointer { r in flows_seasonal_fine_tune(h, r, Int64(epochs), learningRate, anchor) }
        }
        let values = Array(out)
        guard let samples = values.first.flatMap({ Int(exactly: $0) }),
              let w = LearnedHead.weights(fromBridgeFlat: values.dropFirst()) else { return nil }
        var tuned = LearnedHead(w1: w.w1, b1: w.b1, w2: w.w2, b2: w.b2, version: base.version)
        tuned.rows = Int(flows_seasonal_tuned_rows(Int64(base.rows ?? 0), base.rows != nil, Int64(samples)))
        tuned.tunedOnDevice = true
        return tuned
    }

    /// Mean squared error of a head over rows — used to REJECT a fine-tune
    /// that made things worse on the driver's own data (a guard against a
    /// pathological batch), and reportable in the health log.
    static func meanSquaredError(_ head: LearnedHead, rows: [[String: Double]]) -> Double? {
        guard !rows.isEmpty else { return nil }
        let h = head.bridgeFlat, flat = flatRows(rows)
        let r = h.withUnsafeBufferPointer { hp in flat.withUnsafeBufferPointer { rp in flows_seasonal_mean_squared_error(hp, rp) } }
        return r.is_some == 1 ? r.value : nil
    }
}
