// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Long-haul trip-needs engine: recurring stops the driver must make at fixed
/// mileage cadences (fuel per powertrain, food, rest), scheduled up front for
/// the whole trip and surfaced one at a time while driving.
///
/// Pure functions — the canonical scenario (Mexico → Canada hybrid van:
/// diesel every 350 mi, electric charge every 500 mi, food every 100 mi with
/// a random cuisine, rest every 200 mi) is pinned by FLOWSTests.
enum TripNeeds {

    /// One recurring need with its mileage cadence.
    enum Need: Equatable, Hashable {
        case fuel(FuelType)
        case food(FoodCategory)
        case rest
        // (The Need → POIService.Kind mapping lives in POIService.swift so
        // this file stays UI-framework-free for the headless test target.)

        var label: String {
            switch self {
            case .fuel(let type): return type.rawValue
            case .food(let category): return "Food · \(category.rawValue)"
            case .rest: return "Rest"
            }
        }

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
        guard totalMiles > 0 else { return [] }
        var events: [Event] = []
        func unroll(every interval: Double?, _ need: (Int) -> Need) {
            guard let interval, interval > 0 else { return }
            var mile = interval
            var n = 0
            while mile < totalMiles {
                events.append(Event(mile: mile, need: need(n)))
                mile += interval
                n += 1
            }
        }
        unroll(every: intervals.gasMiles) { _ in .fuel(.gas) }
        unroll(every: intervals.dieselMiles) { _ in .fuel(.diesel) }
        unroll(every: intervals.electricMiles) { _ in .fuel(.electric) }
        var rng = SplitMix64(seed: seed)
        unroll(every: intervals.foodMiles) { _ in
            .food(FoodCategory.allCases[Int(rng.next() % UInt64(FoodCategory.allCases.count))])
        }
        unroll(every: intervals.restMiles) { _ in .rest }
        return events.sorted {
            $0.mile != $1.mile ? $0.mile < $1.mile : $0.need.label < $1.need.label
        }
    }

    /// The next scheduled stop strictly ahead of the given odometer mile.
    static func next(after mile: Double, in schedule: [Event]) -> Event? {
        schedule.first { $0.mile > mile }
    }

    /// ETA with unplanned stopped time folded in — e.g. sheltering from a
    /// storm for an hour pushes arrival out by that hour.
    static func adjustedRemainingSeconds(baseline: Double, stopDelaySeconds: Double) -> Double {
        baseline + max(stopDelaySeconds, 0)
    }

    /// Deterministic 64-bit generator (SplitMix64) — no Foundation RNG so the
    /// food-category draw replays identically for a given trip seed.
    struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
