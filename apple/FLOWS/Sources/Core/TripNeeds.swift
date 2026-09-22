// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Long-haul trip-needs engine: recurring stops the driver must make at fixed
/// mileage cadences (fuel per powertrain, food, rest), scheduled up front for
/// the whole trip and surfaced one at a time while driving.
///
/// The schedule, the next-stop search and the ETA adjustment are computed in
/// rust/flows-core (trip_vehicle.rs) and called through rust/flows-bridge,
/// pinned bit for bit — seeded food draws included — to the Swift this
/// replaced by rust/flows-bridge/tests/fixtures/swift_trip_vehicle_oracle.tsv.
/// The canonical scenario (Mexico → Canada hybrid van: diesel every 350 mi,
/// electric charge every 500 mi, food every 100 mi with a random cuisine, rest
/// every 200 mi) is pinned by FLOWSTests.
enum TripNeeds {
    /// One recurring need with its mileage cadence.
    enum Need: Equatable, Hashable {
        case fuel(FuelType)
        case food(FoodCategory)
        case rest
        // (The Need → POIService.Kind mapping lives in POIService.swift so
        // this file stays UI-framework-free for the headless test target.)

        /// The bridge's need code: a fuel code, 10 + food category, 20 for rest.
        var rustCode: UInt8 {
            switch self {
            case .fuel(let type): return type.rustCode
            case .food(let category): return 10 + category.rustCode
            case .rest: return 20
            }
        }

        init?(rustCode code: UInt8) {
            if code == 20 {
                self = .rest
            } else if code >= 10 {
                guard let category = FoodCategory(rustCode: code - 10) else { return nil }
                self = .food(category)
            } else {
                guard let type = FuelType(rustCode: code) else { return nil }
                self = .fuel(type)
            }
        }

        /// The stop's label, as the schedule orders it.
        var label: String { flows_trip_vehicle_need_label(rustCode).toString() }

        var symbol: String {
            switch self {
            case .fuel(let type): return type.symbol
            case .food: return "fork.knife"
            case .rest: return "bed.double.fill"
            }
        }
    }

    /// Mileage cadences. A hybrid sets BOTH fuel intervals; nil disables one.
    struct Intervals: Equatable {
        var gasMiles: Double? = nil
        var dieselMiles: Double? = nil
        var electricMiles: Double? = nil
        var foodMiles: Double? = nil
        var restMiles: Double? = nil

        /// The canonical hybrid-van cadence from the scenario.
        static let hybridVan = Intervals(
            dieselMiles: 350, electricMiles: 500, foodMiles: 100, restMiles: 200)
    }

    struct Event: Equatable {
        let mile: Double
        let need: Need
    }

    /// The full stop schedule for a trip: every cadence unrolled across the
    /// distance, merged and ordered by mile. Food picks a category per stop
    /// from a SEEDED generator so the "random category" requirement stays
    /// deterministic under test (and per planned trip).
    static func schedule(totalMiles: Double, intervals: Intervals, seed: UInt64 = 0) -> [Event] {
        // Cadences cross in the bridge's order — gas, diesel, electric, food,
        // rest — with NaN for a nil cadence (Swift skipped nil and NaN alike).
        let cadences: [Double] = [
            intervals.gasMiles ?? .nan, intervals.dieselMiles ?? .nan, intervals.electricMiles ?? .nan,
            intervals.foodMiles ?? .nan, intervals.restMiles ?? .nan,
        ]
        // [mile, code, mile, code, …]
        let flat = cadences.withUnsafeBufferPointer { flows_trip_vehicle_schedule(totalMiles, $0, seed) }
        var events: [Event] = []
        events.reserveCapacity(flat.len() / 2)
        var i = 0
        while i + 1 < flat.len() {
            if let code = UInt8(exactly: flat[i + 1]), let need = Need(rustCode: code) {
                events.append(Event(mile: flat[i], need: need))
            }
            i += 2
        }
        return events
    }

    /// The next scheduled stop strictly ahead of the given odometer mile.
    static func next(after mile: Double, in schedule: [Event]) -> Event? {
        // Nothing scheduled: nothing to find (and an empty buffer never crosses).
        guard !schedule.isEmpty else { return nil }
        let miles = schedule.map(\.mile)
        let position = miles.withUnsafeBufferPointer { flows_trip_vehicle_next_need_index(mile, $0) }
        guard position >= 0, Int(position) < schedule.count else { return nil }
        return schedule[Int(position)]
    }

    /// Where the needs clock stands as a new leg starts: the miles driven
    /// since the last stop before it. A stop (or a trip's start) restarts
    /// the clock — you just stopped; any other swap (a reroute, a faster
    /// road, the way to an added stop) carries it on by the miles driven on
    /// the leg it replaces. Every replan used to restart it, so repeated
    /// reroutes could put the rest reminder off for good.
    static func milesSinceStop(beforeLeg previous: Double, drivenOnLastLegMeters meters: Double,
                               stopped: Bool) -> Double {
        stopped ? 0 : previous + max(meters, 0) / 1609.344
    }

    /// ETA with unplanned stopped time folded in — e.g. sheltering from a
    /// storm for an hour pushes arrival out by that hour.
    static func adjustedRemainingSeconds(baseline: Double, stopDelaySeconds: Double) -> Double {
        flows_trip_vehicle_adjusted_remaining_seconds(baseline, stopDelaySeconds)
    }

    /// Deterministic 64-bit generator (SplitMix64) — the food-category draw
    /// replays identically for a given trip seed. The steps are Rust's.
    struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { state = flows_trip_vehicle_splitmix64_initial_state(seed) }
        mutating func next() -> UInt64 {
            state = flows_trip_vehicle_splitmix64_advance(state)
            return flows_trip_vehicle_splitmix64_mix(state)
        }
    }
}
