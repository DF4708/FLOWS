// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation
import os

/// Instruments-visible intervals for the known-heavy phases (bundle parse,
/// 33k-zip rescore + grid build, shard parse, badge sweep). With these,
/// launch and pan cost attribute by phase in Instruments instead of by
/// guesswork. Zero behavior change; ~free when no tool is attached.
let flowsSignposter = OSSignposter(subsystem: "com.flows.app", category: "perf")

/// The single source of truth for how hard FLOWS may work the network and CPU,
/// scaled to the device AND its live thermal/power state. This app has to run
/// well on an iPhone 7 (A10, 2 cores, 2 GB) and an M-series iPad alike: weak,
/// hot, or Low-Power devices get a smaller hazard grid, fewer concurrent
/// requests, and longer cache lifetimes; capable, cool devices get the full
/// experience. The snapshot is recomputed when thermal state or Low Power Mode
/// changes, so a device that heats up on a long drive backs off automatically.
///
/// The tier→settings mapping is pure (`settings(...)`) and pinned by FLOWSTests.
final class AdaptiveTuning: @unchecked Sendable {
    static let shared = AdaptiveTuning()

    enum Tier: Int, Sendable { case low = 0, standard = 1, high = 2 }

    struct Settings: Sendable, Equatable {
        /// App-wide cap on concurrent network requests (the FlowsHTTP gate).
        let maxInFlight: Int
        /// Elevated in-flight ceiling for USER-INITIATED planning bursts (the
        /// driver just asked for routes and is watching a spinner until GO
        /// unlocks). A 950-mile plan is ~300 short fetches; at the background
        /// ceiling on cellular round-trips that is 30–70 s of waiting. The
        /// burst lane clears the same bounded request set sooner — total
        /// request COUNT is unchanged and the ceiling stays a hard cap, so
        /// the polite-API doctrine holds. Background sweeps and the corridor
        /// watch never use this lane.
        let planningMaxInFlight: Int
        /// N×N grid the viewport hazard sweep samples (fewer points = fewer
        /// requests AND less CPU per refresh).
        let viewportGridSpan: Int
        /// Cache lifetimes are multiplied by this — weak/hot/saving devices
        /// refresh less often.
        let ttlMultiplier: Double
        /// Debounce before a moved map triggers a new hazard sweep.
        let debounceSeconds: Double
    }

    private let baseTier: Tier
    private let lock = NSLock()
    private var current: Settings

    private init() {
        let info = ProcessInfo.processInfo
        baseTier = Self.baseTier(cores: info.activeProcessorCount,
                                 memoryGB: Double(info.physicalMemory) / 1_073_741_824)
        current = Self.settings(tier: baseTier, thermal: info.thermalState,
                                lowPower: info.isLowPowerModeEnabled)
        NotificationCenter.default.addObserver(
            self, selector: #selector(recompute),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(recompute),
            name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)
    }

    @objc private func recompute() {
        let info = ProcessInfo.processInfo
        let s = Self.settings(tier: baseTier, thermal: info.thermalState,
                              lowPower: info.isLowPowerModeEnabled)
        lock.lock(); current = s; lock.unlock()
    }

    var settings: Settings { lock.lock(); defer { lock.unlock() }; return current }
    var maxInFlight: Int { settings.maxInFlight }
    var viewportGridSpan: Int { settings.viewportGridSpan }
    var debounceSeconds: Double { settings.debounceSeconds }

    /// A base TTL, stretched for the current device/thermal/power state.
    func ttl(_ base: TimeInterval) -> TimeInterval { base * settings.ttlMultiplier }

    // MARK: pure mapping (tested; rust/flows-core media_policy.rs)

    /// Hardware tier from core count + RAM. iPhone 7 (A10): 2 cores / 2 GB →
    /// low. iPhone 11–12 (6 cores / 4 GB) → standard. Pro / M-series → high.
    static func baseTier(cores: Int, memoryGB: Double) -> Tier {
        Tier(rawValue: Int(flows_modes_device_tier(Int64(cores), memoryGB))) ?? .high
    }

    /// The tier's base settings backed off for the thermal state (from .fair
    /// on) and Low Power Mode, with the planning burst bounded by the headroom
    /// the state allows — a critical device gets no boost at all. Pinned to
    /// the original by rust/flows-bridge/tests/fixtures/swift_modes_oracle.tsv.
    static func settings(tier: Tier, thermal: ProcessInfo.ThermalState,
                         lowPower: Bool) -> Settings {
        let s = flows_modes_tuning_settings(UInt8(tier.rawValue), Int64(thermal.rawValue), lowPower)
        return Settings(maxInFlight: Int(s.max_in_flight),
                        planningMaxInFlight: Int(s.planning_max_in_flight),
                        viewportGridSpan: Int(s.viewport_grid_span),
                        ttlMultiplier: s.ttl_multiplier, debounceSeconds: s.debounce_seconds)
    }
}
