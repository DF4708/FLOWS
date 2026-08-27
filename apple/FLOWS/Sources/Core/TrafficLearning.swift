// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// On-device learned traffic delay: how much longer a drive ACTUALLY takes
/// than the router promised, as a function of when you set out and what the
/// weather was doing. Pure and `Codable`, pinned by FLOWSTests; the disk
/// wrapper and wiring live in TrafficDelayModel below.
///
/// This is deliberately a small, inspectable model rather than an opaque net:
/// every prediction can be traced to the observations behind it, it trains
/// from data FLOWS already collects (planned ETA vs. real arrival, plus the
/// corridor weather it already scored), and it needs no server. It shares the
/// shape of SeasonalRiskModel — decaying weights, a confidence bar before it
/// influences anything — so both can feed the same Core ML/ANE model later.
///
/// The features are the two the driver named: TIME OF DAY (rush hours are a
/// property of the clock) and WEATHER KIND (rain slows a corridor; snow slows
/// it far more). Buckets are coarse on purpose — a model with thousands of
/// cells and one trip each would be memorising, not learning.

/// The weather families that actually change how fast traffic moves.
enum TrafficWeather: String, Codable, CaseIterable {
    case clear, rain, snow, ice, fog, wind

    /// Map a hazard family name (the risk engine's vocabulary) to the
    /// coarse bucket the delay model learns on.
    static func from(family: String?) -> TrafficWeather {
        switch family {
        case "qpf_flood", "precip", "tropical": return .rain
        case "winter": return .snow
        case "ice": return .ice
        case "fog", "haze": return .fog
        case "wind": return .wind
        default: return .clear
        }
    }
}

/// One (hour-of-week bucket × weather) cell of learned delay.
struct DelayCell: Codable, Equatable {
    /// Decaying sum of observed delay RATIOS (actual ÷ predicted).
    var weightedSum = 0.0
    /// Decaying total weight.
    var weight = 0.0
    /// Raw trips seen — the confidence bar reads this, undecayed.
    var count = 0

    var mean: Double { weight > 0 ? weightedSum / weight : 1.0 }
}

/// The learned model itself.
struct TrafficDelayStore: Codable, Equatable {
    /// Cells keyed "<hourBucket>|<weather>".
    var cells: [String: DelayCell] = [:]
    /// Last time decay was applied, epoch seconds.
    var lastDecay: Double = 0

    /// Observations halve in influence after this long — a corridor that was
    /// torn up for construction last spring shouldn't steer this spring.
    static let halfLifeSeconds: Double = 120 * 24 * 3600
    /// Trips in a cell before it is allowed to move an ETA. Below this the
    /// model still records, but predicts 1.0 (no adjustment) — one bad
    /// Tuesday is an anecdote, not a pattern.
    static let confidentAfter = 4
    /// Never let the learned factor run away, however lopsided the samples.
    static let maxFactor = 2.5
    static let minFactor = 0.7

    /// Hour-of-week bucket: keeps weekday rush hours separate from Sunday
    /// morning without exploding into 168 sparse cells — weekday/weekend ×
    /// six four-hour blocks = 12 buckets.
    static func bucket(weekday: Int, hour: Int) -> String {
        let weekend = (weekday == 1 || weekday == 7)   // Calendar: 1 = Sunday
        let block = min(max(hour, 0), 23) / 4
        return "\(weekend ? "we" : "wd")\(block)"
    }

    static func key(weekday: Int, hour: Int, weather: TrafficWeather) -> String {
        "\(bucket(weekday: weekday, hour: hour))|\(weather.rawValue)"
    }

    /// Fold one completed trip in: how long it really took vs. the estimate.
    mutating func record(predictedSeconds: Double, actualSeconds: Double,
                         weekday: Int, hour: Int, weather: TrafficWeather,
                         now: Double) {
        guard predictedSeconds > 60, actualSeconds > 0 else { return }
        decay(to: now)
        let ratio = min(max(actualSeconds / predictedSeconds, 0.5), 3.0)
        let k = Self.key(weekday: weekday, hour: hour, weather: weather)
        var cell = cells[k] ?? DelayCell()
        cell.weightedSum += ratio
        cell.weight += 1
        cell.count += 1
        cells[k] = cell
        lastDecay = now
    }

    /// Age every cell toward zero influence.
    mutating func decay(to now: Double) {
        guard lastDecay > 0, now > lastDecay else {
            if lastDecay == 0 { lastDecay = now }
            return
        }
        let factor = pow(0.5, (now - lastDecay) / Self.halfLifeSeconds)
        guard factor < 0.999 else { return }
        for k in cells.keys {
            cells[k]?.weightedSum *= factor
            cells[k]?.weight *= factor
        }
        lastDecay = now
    }

    /// The learned multiplier for a departure: 1.0 means "no reason to think
    /// this differs from the router's estimate".
    func factor(weekday: Int, hour: Int, weather: TrafficWeather) -> Double {
        let k = Self.key(weekday: weekday, hour: hour, weather: weather)
        guard let cell = cells[k], cell.count >= Self.confidentAfter else { return 1.0 }
        return min(max(cell.mean, Self.minFactor), Self.maxFactor)
    }

    /// The ETA this model expects, and the delay it implies.
    func adjustedSeconds(routerSeconds: Double,
                         weekday: Int, hour: Int, weather: TrafficWeather) -> Double {
        routerSeconds * factor(weekday: weekday, hour: hour, weather: weather)
    }

    /// Extra minutes over the router's estimate — what the driver is shown.
    func predictedDelayMinutes(routerSeconds: Double,
                               weekday: Int, hour: Int,
                               weather: TrafficWeather) -> Int {
        let extra = adjustedSeconds(routerSeconds: routerSeconds, weekday: weekday,
                                    hour: hour, weather: weather) - routerSeconds
        return Int((extra / 60).rounded())
    }

    /// How many trips back this cell — the UI only speaks up once the model
    /// has earned it.
    func isConfident(weekday: Int, hour: Int, weather: TrafficWeather) -> Bool {
        (cells[Self.key(weekday: weekday, hour: hour, weather: weather)]?.count ?? 0)
            >= Self.confidentAfter
    }
}

/// Disk-backed wrapper: same pattern as SeasonalRiskModel.
@MainActor
final class TrafficDelayModel: ObservableObject {
    @Published private(set) var store = TrafficDelayStore()

    private let url: URL

    init() {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = dir.appendingPathComponent("flows_traffic_delay.json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(TrafficDelayStore.self, from: data) {
            store = saved
        }
    }

    /// Learn from a finished trip.
    func record(predictedSeconds: Double, actualSeconds: Double,
                weather: TrafficWeather, at date: Date = Date()) {
        let cal = Calendar.current
        store.record(predictedSeconds: predictedSeconds, actualSeconds: actualSeconds,
                     weekday: cal.component(.weekday, from: date),
                     hour: cal.component(.hour, from: date),
                     weather: weather, now: date.timeIntervalSince1970)
        persist()
    }

    /// The learned multiplier for leaving now in this weather.
    func factor(weather: TrafficWeather, at date: Date = Date()) -> Double {
        let cal = Calendar.current
        return store.factor(weekday: cal.component(.weekday, from: date),
                            hour: cal.component(.hour, from: date), weather: weather)
    }

    /// Minutes of delay this model expects on top of the router's ETA.
    func predictedDelayMinutes(routerSeconds: Double, weather: TrafficWeather,
                               at date: Date = Date()) -> Int {
        let cal = Calendar.current
        return store.predictedDelayMinutes(
            routerSeconds: routerSeconds,
            weekday: cal.component(.weekday, from: date),
            hour: cal.component(.hour, from: date), weather: weather)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
