// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// What FLOWS learns about HOW THIS DRIVER DRIVES, persisted and encrypted.
///
/// Two things live here, both fed by signals the app already had and threw
/// away:
///
///  1. **The GPS speed/idle profile.** `VehicleStore.recordFix` maintains
///     exponential moving averages of speed and idle fraction that feed range
///     and refuel prediction — but they were in-memory only, so every launch
///     reset a well-learned driver to a 55 mph stranger. Persisted here.
///
///  2. **A personal ETA correction.** Nothing compared the ETA the app
///     promised against the time the drive actually took, even though the
///     app knew both. Driving style is strongly personal and highly
///     repeatable: some drivers beat the routing engine's estimate on every
///     interstate run, others never do. One learned multiplier improves every
///     ETA shown, every fuel-cost estimate derived from it, and the
///     arrival-time reasoning that decides whether a storm will still be
///     there when the driver arrives.
///
/// The correction's rails, its multiplier and its update are computed in
/// rust/flows-core (learning.rs) and called through rust/flows-bridge; the
/// persisted fields, the words and the store stay here. Pinned bit for bit to
/// the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_learning_oracle.tsv.
struct DrivingProfile: Codable, Equatable {
    /// Speed/idle EWMAs (the range model's inputs).
    var averageSpeedMph: Double = 55
    var idleFraction: Double = 0

    /// EWMA of ln(actual ÷ predicted) travel time. Log space so that "20%
    /// slower" and "20% faster" are symmetric, and so the correction can
    /// never go negative.
    var etaLogRatio: Double = 0
    var etaSamples: Int = 0
    var updatedAt: Double = 0

    /// Ratios outside this band are not driving style — they are an
    /// unplanned stop, a closure, or a trip abandoned mid-route. Recording
    /// them would teach the model that this driver takes 3× as long as the
    /// router says, and every ETA in the app would inflate.
    static let minPlausibleRatio = flows_learning_eta_min_plausible_ratio()
    static let maxPlausibleRatio = flows_learning_eta_max_plausible_ratio()
    /// Samples before the correction is trusted enough to move a number the
    /// driver reads.
    static let minSamplesToApply = Int(flows_learning_eta_min_samples_to_apply())
    /// Below this the correction is noise; applying it would make ETAs
    /// jitter for no benefit.
    static let minMeaningfulDeviation = flows_learning_eta_min_meaningful_deviation()
    /// Even a well-established correction stays within this band — the
    /// routing engine's traffic model is still the primary estimate.
    static let clampLow = flows_learning_eta_clamp_low()
    static let clampHigh = flows_learning_eta_clamp_high()

    /// The multiplier to apply to a routing ETA, or 1 when not yet earned.
    var etaMultiplier: Double {
        flows_learning_eta_multiplier(etaLogRatio, Int64(etaSamples))
    }

    /// Fold one completed trip into the correction.
    /// - Parameters:
    ///   - predicted: the ETA promised when the leg started.
    ///   - actual: wall-clock time the leg actually took.
    ///   - stoppedSeconds: time attributable to stops the driver chose
    ///     (added stops, breaks) — removed before comparing, since a lunch
    ///     stop is not evidence about driving pace.
    mutating func recordArrival(
        predicted: TimeInterval, actual: TimeInterval,
        stoppedSeconds: TimeInterval = 0, now: Double = Date().timeIntervalSince1970
    ) {
        // `has` 0: the arrival was rejected (not driving style), the profile
        // is unchanged.
        let next = flows_learning_eta_record(etaLogRatio, Int64(etaSamples), predicted, actual, stoppedSeconds)
        guard next.has == 1 else { return }
        etaLogRatio = next.log_ratio
        etaSamples = Int(next.samples)
        updatedAt = now
    }

    /// Plain-words summary for the health/settings view.
    var etaDescription: String {
        let m = etaMultiplier
        if m == 1 {
            return etaSamples < Self.minSamplesToApply
                ? "Learning your pace (\(etaSamples) of \(Self.minSamplesToApply) trips)"
                : "Your pace matches the routing estimate"
        }
        let pct = Int(((m - 1) * 100).rounded())
        return pct > 0
            ? "You typically take \(pct)% longer than the estimate"
            : "You typically arrive \(-pct)% sooner than the estimate"
    }
}

/// Owner + encrypted persistence for the driving profile. Writes are
/// coalesced: the speed EWMA updates at GPS rate (1 Hz) and must not seal a
/// file every second.
@MainActor
final class DrivingProfileStore: ObservableObject {
    static let shared = DrivingProfileStore()

    @Published private(set) var profile = DrivingProfile()
    private let url: URL
    private var lastPersist = Date.distantPast
    /// Shared with every other behaviour store so the erase button's key
    /// deletion cannot overtake a seal that is still queued.
    private var persistQueue: DispatchQueue { SecureBehaviorStore.persistQueue }

    init(directory: URL? = nil) {
        let dir = directory
            ?? (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = dir.appendingPathComponent("flows_driving_profile.json")
        if let loaded = SecureBehaviorStore.readMigrating(url).flatMap({
            try? JSONDecoder().decode(DrivingProfile.self, from: $0)
        }) {
            profile = loaded
        }
    }

    /// Live speed/idle from the navigation loop. Persisted at most once a
    /// minute — the value is an hour-scale average, so a lost final minute
    /// costs nothing, while sealing per fix would be absurd.
    func updateDriving(averageSpeedMph: Double, idleFraction: Double) {
        profile.averageSpeedMph = averageSpeedMph
        profile.idleFraction = idleFraction
        if Date().timeIntervalSince(lastPersist) > 60 { persist() }
    }

    func recordArrival(predicted: TimeInterval, actual: TimeInterval,
                       stoppedSeconds: TimeInterval = 0) {
        let before = profile.etaMultiplier
        profile.recordArrival(predicted: predicted, actual: actual,
                              stoppedSeconds: stoppedSeconds)
        persist()
        let after = profile.etaMultiplier
        if abs(after - before) > 0.001 {
            FlowsDiag.log(.info, "learning", String(
                format: "personal ETA correction now %.3f after %d trips",
                after, profile.etaSamples))
        }
    }

    /// The correction to apply to a routing ETA (1 until earned).
    var etaMultiplier: Double { profile.etaMultiplier }

    func erase() {
        profile = DrivingProfile()
        SecureBehaviorStore.shred(url)
    }

    private func persist() {
        lastPersist = Date()
        let snapshot = profile
        let url = self.url
        persistQueue.async { SecureBehaviorStore.save(snapshot, to: url) }
    }
}
