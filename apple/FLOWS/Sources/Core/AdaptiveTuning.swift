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

    // MARK: pure mapping (tested)

    /// Hardware tier from core count + RAM. iPhone 7 (A10): 2 cores / 2 GB →
    /// low. iPhone 11–12 (6 cores / 4 GB) → standard. Pro / M-series → high.
    static func baseTier(cores: Int, memoryGB: Double) -> Tier {
        if cores <= 2 || memoryGB < 3 { return .low }
        if cores <= 4 || memoryGB < 4.5 { return .standard }
        return .high
    }

    static func settings(tier: Tier, thermal: ProcessInfo.ThermalState,
                         lowPower: Bool) -> Settings {
        var maxInFlight: Int
        var grid: Int
        var debounce: Double
        switch tier {
        case .low:      maxInFlight = 3;  grid = 3; debounce = 1.0
        case .standard: maxInFlight = 6;  grid = 4; debounce = 0.6
        case .high:     maxInFlight = 10; grid = 5; debounce = 0.4
        }
        var ttlMul = 1.0
        switch thermal {
        case .fair:     ttlMul = 1.3
                        // Begin backing off at .fair, not only at .serious: one
                        // fewer concurrent request + a slightly longer debounce so
                        // a warming weak device eases off BEFORE it climbs to
                        // .serious. Grid density is left alone (more disruptive —
                        // reserved for .serious).
                        maxInFlight = max(2, maxInFlight - 1)
                        debounce = max(debounce, tier == .low ? 1.0 : 0.8)
        case .serious:  ttlMul = 2.0; maxInFlight = max(2, maxInFlight / 2)
                        grid = max(3, grid - 1); debounce = max(debounce, 1.0)
        case .critical: ttlMul = 3.0; maxInFlight = 2
                        grid = 3; debounce = max(debounce, 1.5)
        default:        break   // .nominal
        }
        if lowPower {
            ttlMul = max(ttlMul, 2.0)
            maxInFlight = max(2, min(maxInFlight, tier == .high ? 5 : 3))
            grid = max(3, min(grid, 4))
            debounce = max(debounce, 1.0)
        }
        // Planning burst = double the background ceiling, bounded by how much
        // headroom the device state allows: a cool device may briefly run 2×,
        // a warming one less, and a critical/Low-Power device barely more than
        // background (critical allows NO boost — the ceiling equals the
        // background one, so a hot device never spikes for a burst).
        var burstCap: Int
        switch thermal {
        case .fair:     burstCap = 12
        case .serious:  burstCap = 6
        case .critical: burstCap = 2
        default:        burstCap = 16   // .nominal
        }
        if lowPower { burstCap = min(burstCap, 8) }
        let planningMax = max(maxInFlight, min(burstCap, maxInFlight * 2))
        return Settings(maxInFlight: maxInFlight, planningMaxInFlight: planningMax,
                        viewportGridSpan: grid,
                        ttlMultiplier: ttlMul, debounceSeconds: debounce)
    }
}
