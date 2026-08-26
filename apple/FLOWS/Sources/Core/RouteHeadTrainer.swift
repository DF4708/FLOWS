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
enum RouteHeadTrainer {

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
        epochs: Int = 60,
        learningRate: Double = 0.01,
        anchor: Double = 0.02
    ) -> LearnedHead? {
        let width = base.inputWidth
        guard width == RouteFeatures.count, base.b1.count == base.w1.count,
              base.w2.count == base.w1.count, !rows.isEmpty else { return nil }

        // Materialize (x, y, weight) once — parsing dictionaries inside the
        // epoch loop would dominate the arithmetic.
        var samples: [(x: [Double], y: Double, w: Double)] = []
        samples.reserveCapacity(rows.count)
        for r in rows {
            guard let target = r["target"], target.isFinite else { continue }
            let x = RouteFeatures.vector(
                oLat: r["oLat"] ?? 0, oLon: r["oLon"] ?? 0,
                dLat: r["dLat"] ?? 0, dLon: r["dLon"] ?? 0,
                week: Int(r["week"] ?? 0), crossCountry: (r["crossCountry"] ?? 0) > 0.5)
            guard x.count == width else { continue }
            samples.append((x, min(max(target, 0), 1), max(r["weight"] ?? 1, 0)))
        }
        guard !samples.isEmpty else { return nil }

        let baseW1 = base.w1, baseB1 = base.b1, baseW2 = base.w2, baseB2 = base.b2
        var w1 = baseW1, b1 = baseB1, w2 = baseW2, b2 = baseB2
        let hidden = w1.count

        for _ in 0..<epochs {
            // Full-batch gradients: the row count is small and full batch is
            // deterministic (no shuffle seed to carry).
            var gw1 = [[Double]](repeating: [Double](repeating: 0, count: width), count: hidden)
            var gb1 = [Double](repeating: 0, count: hidden)
            var gw2 = [Double](repeating: 0, count: hidden)
            var gb2 = 0.0
            var totalWeight = 0.0

            for s in samples {
                // Forward: ReLU hidden, sigmoid output (the Rust contract).
                var h = [Double](repeating: 0, count: hidden)
                var preOut = b2
                for j in 0..<hidden {
                    var acc = b1[j]
                    let row = w1[j]
                    for k in 0..<width { acc += row[k] * s.x[k] }
                    h[j] = max(acc, 0)
                    preOut += w2[j] * h[j]
                }
                let out = 1 / (1 + exp(-preOut))
                // dMSE/dPreOut for sigmoid + squared error.
                let dOut = (out - s.y) * out * (1 - out) * s.w
                totalWeight += s.w
                gb2 += dOut
                for j in 0..<hidden {
                    gw2[j] += dOut * h[j]
                    guard h[j] > 0 else { continue }   // ReLU gate
                    let dHidden = dOut * w2[j]
                    gb1[j] += dHidden
                    for k in 0..<width { gw1[j][k] += dHidden * s.x[k] }
                }
            }

            let scale = learningRate / max(totalWeight, 1)
            b2 -= scale * gb2 + anchor * (b2 - baseB2)
            for j in 0..<hidden {
                w2[j] -= scale * gw2[j] + anchor * (w2[j] - baseW2[j])
                b1[j] -= scale * gb1[j] + anchor * (b1[j] - baseB1[j])
                for k in 0..<width {
                    w1[j][k] -= scale * gw1[j][k] + anchor * (w1[j][k] - baseW1[j][k])
                }
            }
        }

        // A numerically broken fine-tune must never replace a good baseline.
        guard w1.allSatisfy({ $0.allSatisfy(\.isFinite) }), b1.allSatisfy(\.isFinite),
              w2.allSatisfy(\.isFinite), b2.isFinite else { return nil }

        var tuned = LearnedHead(w1: w1, b1: b1, w2: w2, b2: b2, version: base.version)
        tuned.rows = (base.rows ?? 0) + samples.count
        tuned.tunedOnDevice = true
        return tuned
    }

    /// Mean squared error of a head over rows — used to REJECT a fine-tune
    /// that made things worse on the driver's own data (a guard against a
    /// pathological batch), and reportable in the health log.
    static func meanSquaredError(_ head: LearnedHead, rows: [[String: Double]]) -> Double? {
        var total = 0.0
        var n = 0.0
        for r in rows {
            guard let target = r["target"], target.isFinite else { continue }
            let x = RouteFeatures.vector(
                oLat: r["oLat"] ?? 0, oLon: r["oLon"] ?? 0,
                dLat: r["dLat"] ?? 0, dLon: r["dLon"] ?? 0,
                week: Int(r["week"] ?? 0), crossCountry: (r["crossCountry"] ?? 0) > 0.5)
            let d = head.predict(x) - min(max(target, 0), 1)
            total += d * d
            n += 1
        }
        return n > 0 ? total / n : nil
    }
}
