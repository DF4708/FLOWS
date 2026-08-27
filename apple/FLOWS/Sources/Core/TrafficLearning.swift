// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
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

/// The kind of road a trip mostly ran on. They are learned differently on
/// purpose: LOCAL roads are what daily driving is made of, and their delays
/// are intensely place-specific (this town's lights, this street's school
/// run), so they are learned per neighbourhood. HIGHWAY delay behaves far
/// more alike everywhere — rush hour on an interstate is rush hour — so
/// highways pool into ONE nationwide cell, which is what lets a lifetime of
/// local commuting inform an occasional cross-country drive.
enum RoadClass: String, Codable, CaseIterable {
    case local, highway

    /// A trip is "highway" when it averaged highway speed — the honest
    /// signal available without map-matching every leg.
    static func from(averageMph: Double) -> RoadClass {
        averageMph >= 45 ? .highway : .local
    }
}

/// Which neighbourhood a local trip belongs to: ~11 km cells, the same
/// quantization RouteKey uses, so "the drive I always take" groups together.
/// Highways deliberately share one key (`pooled`) regardless of where they
/// are, so their learning transfers to roads this device has never driven.
struct TrafficArea: Hashable, Codable {
    let lat: Int, lon: Int

    init(_ c: CLLocationCoordinate2D) {
        func q(_ v: Double) -> Int { Int((v * 10).rounded()) }
        lat = q(c.latitude); lon = q(c.longitude)
    }

    private init(lat: Int, lon: Int) { self.lat = lat; self.lon = lon }

    /// The shared cell every highway trip lands in.
    static let pooled = TrafficArea(lat: 9_999, lon: 9_999)

    var key: String { self == Self.pooled ? "any" : "\(lat)_\(lon)" }
}

/// One (area × road class × hour-of-week × weather) cell of learned delay.
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

    static func key(area: TrafficArea, roadClass: RoadClass,
                    weekday: Int, hour: Int, weather: TrafficWeather) -> String {
        // Highways pool nationwide; local roads stay in their own area.
        let a = roadClass == .highway ? TrafficArea.pooled : area
        return "\(a.key)|\(roadClass.rawValue)|"
            + "\(bucket(weekday: weekday, hour: hour))|\(weather.rawValue)"
    }

    /// Fold one completed trip in: how long it really took vs. the estimate.
    mutating func record(predictedSeconds: Double, actualSeconds: Double,
                         area: TrafficArea, roadClass: RoadClass,
                         weekday: Int, hour: Int, weather: TrafficWeather,
                         now: Double) {
        guard predictedSeconds > 60, actualSeconds > 0 else { return }
        decay(to: now)
        let ratio = min(max(actualSeconds / predictedSeconds, 0.5), 3.0)
        let k = Self.key(area: area, roadClass: roadClass,
                         weekday: weekday, hour: hour, weather: weather)
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
    /// The learned multiplier, preferring the most specific evidence that has
    /// earned confidence: this neighbourhood's own local roads first, then
    /// the pooled highway learning (which is what carries a local driver's
    /// experience onto a long trip), then no adjustment at all.
    func factor(area: TrafficArea, roadClass: RoadClass,
                weekday: Int, hour: Int, weather: TrafficWeather) -> Double {
        let ladder: [(TrafficArea, RoadClass)] = roadClass == .highway
            ? [(TrafficArea.pooled, .highway)]
            : [(area, .local), (TrafficArea.pooled, .highway)]
        for (a, c) in ladder {
            let k = Self.key(area: a, roadClass: c, weekday: weekday,
                             hour: hour, weather: weather)
            if let cell = cells[k], cell.count >= Self.confidentAfter {
                return min(max(cell.mean, Self.minFactor), Self.maxFactor)
            }
        }
        return 1.0
    }

    /// The ETA this model expects, and the delay it implies.
    func adjustedSeconds(routerSeconds: Double, area: TrafficArea,
                         roadClass: RoadClass,
                         weekday: Int, hour: Int, weather: TrafficWeather) -> Double {
        routerSeconds * factor(area: area, roadClass: roadClass,
                               weekday: weekday, hour: hour, weather: weather)
    }

    /// Extra minutes over the router's estimate — what the driver is shown.
    func predictedDelayMinutes(routerSeconds: Double, area: TrafficArea,
                               roadClass: RoadClass, weekday: Int, hour: Int,
                               weather: TrafficWeather) -> Int {
        let extra = adjustedSeconds(routerSeconds: routerSeconds, area: area,
                                    roadClass: roadClass, weekday: weekday,
                                    hour: hour, weather: weather) - routerSeconds
        return Int((extra / 60).rounded())
    }

    /// How many trips back this cell — the UI only speaks up once the model
    /// has earned it.
    func isConfident(area: TrafficArea, roadClass: RoadClass,
                     weekday: Int, hour: Int, weather: TrafficWeather) -> Bool {
        (cells[Self.key(area: area, roadClass: roadClass, weekday: weekday,
                        hour: hour, weather: weather)]?.count ?? 0)
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
                area: TrafficArea, roadClass: RoadClass,
                weather: TrafficWeather, at date: Date = Date()) {
        let cal = Calendar.current
        store.record(predictedSeconds: predictedSeconds, actualSeconds: actualSeconds,
                     area: area, roadClass: roadClass,
                     weekday: cal.component(.weekday, from: date),
                     hour: cal.component(.hour, from: date),
                     weather: weather, now: date.timeIntervalSince1970)
        persist()
    }

    /// The learned multiplier for driving HERE, on this kind of road, now.
    func factor(area: TrafficArea, roadClass: RoadClass,
                weather: TrafficWeather, at date: Date = Date()) -> Double {
        let cal = Calendar.current
        return store.factor(area: area, roadClass: roadClass,
                            weekday: cal.component(.weekday, from: date),
                            hour: cal.component(.hour, from: date), weather: weather)
    }

    /// Minutes of delay this model expects on top of the router's ETA.
    func predictedDelayMinutes(routerSeconds: Double, area: TrafficArea,
                               roadClass: RoadClass, weather: TrafficWeather,
                               at date: Date = Date()) -> Int {
        let cal = Calendar.current
        return store.predictedDelayMinutes(
            routerSeconds: routerSeconds, area: area, roadClass: roadClass,
            weekday: cal.component(.weekday, from: date),
            hour: cal.component(.hour, from: date), weather: weather)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
