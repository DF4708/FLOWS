// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Learns how long the music ACTUALLY keeps playing after the connection
/// drops — **per streaming service**, because every service buffers
/// differently and none of them publish the figure (see DATA_FEEDS §13).
///
/// Every outage hands FLOWS a free labeled sample: the connection died at
/// T, the audio went silent at T+d. `d` is the real buffer depth for that
/// service on this driver's phone, at that moment. Enough of those and the
/// documented guess can be retired in favour of measurement.
///
/// The estimator is a decaying-weight mean, matching `SeasonalRiskModel`'s
/// house style: newest observations dominate, and a context only starts
/// influencing behaviour once it has accrued enough samples to mean
/// something. That is deliberately NOT a neural model — with a handful of
/// outages per driver per service, an exponentially-weighted mean IS the
/// statistically appropriate estimator, and it stays explainable when a
/// driver asks why the music switched when it did.
///
/// Context is (service × radio technology): the same service behaves very
/// differently on 5G and on EDGE, so LTE samples must not pollute the
/// weak-signal estimate.
enum BufferLearning {
    /// Weight on the newest sample. High enough to adapt within a drive
    /// (services change their behaviour with app updates and plan tiers),
    /// low enough that one weird outage doesn't rewrite the estimate.
    static let alpha = 0.35
    /// Below this, the documented prior still leads: two samples is an
    /// anecdote, not a measurement.
    static let minSamplesToTrust = 3
    /// Beyond these, a "sample" is telling us about something other than a
    /// buffer: sub-second means the driver hit stop as the signal died;
    /// minutes means the audio was local, or signal returned unnoticed.
    static let plausibleSeconds: ClosedRange<Double> = 1...180

    /// Storage key for one learned context. Service leads — it is the
    /// dimension that actually differs.
    static func contextKey(service: String, radioTechnology: String?) -> String {
        "\(service)|\(radioTechnology ?? "unknown")"
    }

    /// Fold one observation into the running mean. Returns the unchanged
    /// mean for an implausible sample (it is discarded, not clamped —
    /// clamping would drag the estimate toward a value never observed).
    static func updated(mean: Double?, sample: Double) -> Double? {
        guard sample.isFinite, plausibleSeconds.contains(sample) else { return mean }
        guard let mean else { return sample }
        return mean * (1 - alpha) + sample * alpha
    }

    /// Whether a sample counts toward the trust gate.
    static func isUsable(sample: Double) -> Bool {
        sample.isFinite && plausibleSeconds.contains(sample)
    }

    /// How long to wait: the learned mean once the context is trusted,
    /// the documented prior until then.
    static func waitSeconds(prior: Double, learnedMean: Double?,
                            samples: Int) -> Double {
        guard let learnedMean, samples >= minSamplesToTrust else { return prior }
        return learnedMean
    }
}

/// On-disk memory for the learned per-service buffer depths. Small enough
/// for UserDefaults (a handful of contexts, two numbers each) and cheap to
/// write, so a battery death mid-drive never loses much.
@MainActor
final class BufferMemory {
    static let shared = BufferMemory()

    private struct Stat: Codable {
        var mean: Double
        var samples: Int
    }

    private static let key = "flows.bufferLearning"
    private var stats: [String: Stat]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: Stat].self, from: data) {
            stats = decoded
        } else {
            stats = [:]
        }
    }

    /// The wait to use for this context, given its documented prior.
    func waitSeconds(prior: Double, service: String,
                     radioTechnology: String?) -> Double {
        let key = BufferLearning.contextKey(service: service,
                                            radioTechnology: radioTechnology)
        let stat = stats[key]
        return BufferLearning.waitSeconds(prior: prior,
                                          learnedMean: stat?.mean,
                                          samples: stat?.samples ?? 0)
    }

    /// Record how long the audio really lasted after the link dropped.
    func record(seconds: Double, service: String, radioTechnology: String?) {
        guard BufferLearning.isUsable(sample: seconds) else { return }
        let key = BufferLearning.contextKey(service: service,
                                            radioTechnology: radioTechnology)
        let existing = stats[key]
        guard let mean = BufferLearning.updated(mean: existing?.mean,
                                                sample: seconds) else { return }
        stats[key] = Stat(mean: mean, samples: (existing?.samples ?? 0) + 1)
        if let data = try? JSONEncoder().encode(stats) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Samples held for a context — surfaced so the UI can say whether
    /// FLOWS is still using the documented guess or its own measurement.
    func sampleCount(service: String, radioTechnology: String?) -> Int {
        stats[BufferLearning.contextKey(service: service,
                                        radioTechnology: radioTechnology)]?.samples ?? 0
    }
}
