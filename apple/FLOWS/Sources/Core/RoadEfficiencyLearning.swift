// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// What this vehicle ACTUALLY gets on the roads this driver actually drives.
///
/// The rated economy on a window sticker is a laboratory number. The road to
/// work has hills, lights, and a driver's own habits on it, and the honest
/// figure for it can only be measured. This learns that per road segment in
/// the local area — the same ~11 km cells the traffic model uses, split by
/// road class — from the distance covered and the fuel burned while covering
/// it, and hands the result to range prediction, fuel-stop timing, and route
/// comparison. Pure and `Codable`; pinned by FLOWSTests.
///
/// Local roads are what fill this: they are driven daily and their economy is
/// place-specific. Highway efficiency pools nationwide for the same reason it
/// does in TrafficLearning — a long haul at 65 mph behaves alike everywhere,
/// which is what lets local measurement inform an unfamiliar trip.
///
/// The gate, the decay, the distance-weighted fold, the economy ladder and
/// the confidence bar are computed in rust/flows-core (learning.rs) and
/// called through rust/flows-bridge; the cell keys, the dictionary and the
/// model class stay here. Pinned bit for bit to the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_learning_oracle.tsv.
struct RoadEfficiencyStore: Codable, Equatable {

    /// Decaying accumulators of measured economy for one road cell.
    struct Cell: Codable, Equatable {
        /// Decaying sum of measured mi/unit, weighted by miles driven.
        var weightedSum = 0.0
        /// Decaying total weight (miles).
        var weight = 0.0
        /// Miles actually measured — the confidence bar, undecayed.
        var miles = 0.0

        var mean: Double { flows_learning_efficiency_cell_mean(weightedSum, weight) }
    }

    var cells: [String: Cell] = [:]
    var lastDecay: Double = 0

    /// Habits and seasons drift; a year-old measurement should not outweigh
    /// last week's.
    static let halfLifeSeconds: Double = flows_learning_efficiency_half_life_seconds()
    /// Measured miles in a cell before it may override the rated figure.
    /// Below this the vehicle's own curve stands.
    static let confidentMiles = flows_learning_efficiency_confident_miles()
    /// Never let a bad stretch of measurement claim an absurd economy.
    static let minRatio = flows_learning_efficiency_min_ratio()
    static let maxRatio = flows_learning_efficiency_max_ratio()

    static func key(area: TrafficArea, roadClass: RoadClass) -> String {
        let a = roadClass == .highway ? TrafficArea.pooled : area
        return "\(a.key)|\(roadClass.rawValue)"
    }

    /// Fold in a measured stretch: miles covered for units burned.
    mutating func record(milesDriven: Double, unitsBurned: Double,
                         area: TrafficArea, roadClass: RoadClass, now: Double) {
        guard flows_learning_efficiency_accepts(milesDriven, unitsBurned) else { return }
        decay(to: now)
        let k = Self.key(area: area, roadClass: roadClass)
        let cell = cells[k] ?? Cell()
        // Weight by distance: a 40-mile stretch says more than a 2-mile one.
        let next = flows_learning_efficiency_add(cell.weightedSum, cell.weight, cell.miles, milesDriven, unitsBurned)
        cells[k] = Cell(weightedSum: next.weighted_sum, weight: next.weight, miles: next.count)
        lastDecay = now
    }

    mutating func decay(to now: Double) {
        let plan = flows_learning_decay_plan(lastDecay, now, Self.halfLifeSeconds)
        if plan.apply == 1 {
            for k in cells.keys {
                cells[k]?.weightedSum *= plan.factor
                cells[k]?.weight *= plan.factor
            }
        }
        lastDecay = plan.last_decay
    }

    /// The economy to actually plan with: the measured figure for this road
    /// once enough of it has been driven, else the vehicle's own rated
    /// number. Clamped so one strange stretch can't rewrite the vehicle.
    func economy(ratedMilesPerUnit: Double, area: TrafficArea,
                 roadClass: RoadClass) -> Double {
        let (local, hasLocal) = crossing(cells[Self.key(area: area, roadClass: .local)])
        let (pooled, hasPooled) = crossing(cells[Self.key(area: .pooled, roadClass: .highway)])
        return flows_learning_efficiency_economy(ratedMilesPerUnit, roadClass == .highway, local, hasLocal, pooled, hasPooled)
    }

    /// True once this road has been measured enough to speak for itself.
    func isConfident(area: TrafficArea, roadClass: RoadClass) -> Bool {
        flows_learning_efficiency_is_confident(cells[Self.key(area: area, roadClass: roadClass)]?.miles ?? 0)
    }
}

/// Disk-backed wrapper, and the live accumulator that measures a stretch as
/// it is driven.
// MARK: - Crossing a learned cell

/// A cell as the bridge takes it: its fields (miles in the third slot) plus
/// whether it exists.
private func crossing(_ cell: RoadEfficiencyStore.Cell?) -> (FlowsLearningCell, Bool) {
    (FlowsLearningCell(weighted_sum: cell?.weightedSum ?? 0, weight: cell?.weight ?? 0,
                       count: cell?.miles ?? 0), cell != nil)
}

@MainActor
final class RoadEfficiencyModel: ObservableObject {
    @Published private(set) var store = RoadEfficiencyStore()

    private let url: URL
    /// Miles and fuel accumulated since the last commit, plus where they
    /// were accumulated — committed per cell so a trip that crosses from
    /// town onto the interstate files each part where it belongs.
    private var pendingMiles = 0.0
    private var pendingUnits = 0.0
    private var pendingArea: TrafficArea?
    private var pendingClass: RoadClass?

    /// Commit a stretch once it is long enough to mean something.
    private static let commitMiles = 2.0

    init() {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = dir.appendingPathComponent("flows_road_efficiency.json")
        if let data = SecureBehaviorStore.readMigrating(url),
           let saved = try? JSONDecoder().decode(RoadEfficiencyStore.self, from: data) {
            store = saved
        }
    }

    /// Feed one GPS step: how far the vehicle moved and how much fuel that
    /// cost at the economy it was achieving.
    func record(deltaMiles: Double, unitsBurned: Double,
                area: TrafficArea, roadClass: RoadClass) {
        guard deltaMiles > 0, unitsBurned > 0 else { return }
        // Road class or neighbourhood changed → bank what we have first.
        if let pc = pendingClass, let pa = pendingArea,
           pc != roadClass || pa != area {
            commit(area: pa, roadClass: pc)
        }
        pendingArea = area
        pendingClass = roadClass
        pendingMiles += deltaMiles
        pendingUnits += unitsBurned
        if pendingMiles >= Self.commitMiles {
            commit(area: area, roadClass: roadClass)
        }
    }

    private func commit(area: TrafficArea, roadClass: RoadClass) {
        defer { pendingMiles = 0; pendingUnits = 0 }
        guard pendingMiles > 0, pendingUnits > 0 else { return }
        store.record(milesDriven: pendingMiles, unitsBurned: pendingUnits,
                     area: area, roadClass: roadClass,
                     now: Date().timeIntervalSince1970)
        persist()
    }

    /// Bank whatever is pending (trip end).
    func flush() {
        guard let a = pendingArea, let c = pendingClass else { return }
        commit(area: a, roadClass: c)
        pendingArea = nil
        pendingClass = nil
    }

    /// The economy to plan with on this road.
    func economy(ratedMilesPerUnit: Double, area: TrafficArea,
                 roadClass: RoadClass) -> Double {
        store.economy(ratedMilesPerUnit: ratedMilesPerUnit, area: area,
                      roadClass: roadClass)
    }

    private func persist() {
        _ = SecureBehaviorStore.save(store, to: url)
    }

    /// "Erase everything FLOWS has learned" reaches this too.
    ///
    /// It did not used to. This file was written as PLAINTEXT JSON and had no
    /// eraser at all, so a record of where the driver has been outlived the
    /// button that promises the app is "back to knowing nothing" — and
    /// destroying the encryption key did nothing for it, because it was never
    /// encrypted in the first place.
    func erase() {
        store = RoadEfficiencyStore()
        // A stretch driven before the erase must not be committed after it.
        pendingMiles = 0
        pendingUnits = 0
        pendingArea = nil
        pendingClass = nil
        SecureBehaviorStore.shred(url)
    }
}
