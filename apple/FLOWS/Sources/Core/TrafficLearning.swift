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
///
/// The buckets' arithmetic, the decay, the fold, the factor ladder and the
/// confidence bar are computed in rust/flows-core (learning.rs) and called
/// through rust/flows-bridge; the cell keys, the dictionary and the disk
/// wrapper stay here. Pinned bit for bit to the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_learning_oracle.tsv.

/// The weather families that actually change how fast traffic moves.
enum TrafficWeather: String, Codable, CaseIterable {
    case clear, rain, snow, ice, fog, wind

    /// Map a hazard family name (the risk engine's vocabulary) to the
    /// coarse bucket the delay model learns on.
    static func from(family: String?) -> TrafficWeather {
        // The bridge's code is the position in `allCases`.
        let code = Int(flows_learning_traffic_weather_from_family(family ?? "", family != nil))
        return code < allCases.count ? allCases[code] : .clear
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
        flows_learning_road_class_is_highway(averageMph) ? .highway : .local
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

    var mean: Double { flows_learning_delay_cell_mean(weightedSum, weight) }
}

/// The learned model itself.
struct TrafficDelayStore: Codable, Equatable {
    /// Cells keyed "<hourBucket>|<weather>".
    var cells: [String: DelayCell] = [:]
    /// Last time decay was applied, epoch seconds.
    var lastDecay: Double = 0

    /// Observations halve in influence after this long — a corridor that was
    /// torn up for construction last spring shouldn't steer this spring.
    static let halfLifeSeconds: Double = flows_learning_traffic_half_life_seconds()
    /// Trips in a cell before it is allowed to move an ETA. Below this the
    /// model still records, but predicts 1.0 (no adjustment) — one bad
    /// Tuesday is an anecdote, not a pattern.
    static let confidentAfter = Int(flows_learning_traffic_confident_after())
    /// Never let the learned factor run away, however lopsided the samples.
    static let maxFactor = flows_learning_traffic_max_factor()
    static let minFactor = flows_learning_traffic_min_factor()

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
        guard flows_learning_traffic_accepts(predictedSeconds, actualSeconds) else { return }
        decay(to: now)
        let k = Self.key(area: area, roadClass: roadClass,
                         weekday: weekday, hour: hour, weather: weather)
        let cell = cells[k] ?? DelayCell()
        // `has` 0: the count is at Int.max (the Swift this replaced crashed);
        // the observation is dropped.
        let next = flows_learning_traffic_add(cell.weightedSum, cell.weight, Int64(cell.count),
                                              predictedSeconds, actualSeconds)
        if next.has == 1 {
            cells[k] = DelayCell(weightedSum: next.weighted_sum, weight: next.weight, count: Int(next.count))
        }
        lastDecay = now
    }

    /// Age every cell toward zero influence.
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

    /// The learned multiplier for a departure: 1.0 means "no reason to think
    /// this differs from the router's estimate".
    /// The learned multiplier, preferring the most specific evidence that has
    /// earned confidence: this neighbourhood's own local roads first, then
    /// the pooled highway learning (which is what carries a local driver's
    /// experience onto a long trip), then no adjustment at all.
    func factor(area: TrafficArea, roadClass: RoadClass,
                weekday: Int, hour: Int, weather: TrafficWeather) -> Double {
        let (local, hasLocal) = crossing(cells[Self.key(area: area, roadClass: .local, weekday: weekday, hour: hour, weather: weather)])
        let (pooled, hasPooled) = crossing(cells[Self.key(area: .pooled, roadClass: .highway, weekday: weekday, hour: hour, weather: weather)])
        return flows_learning_traffic_factor(roadClass == .highway, local, hasLocal, pooled, hasPooled)
    }

    /// The ETA this model expects, and the delay it implies.
    func adjustedSeconds(routerSeconds: Double, area: TrafficArea,
                         roadClass: RoadClass,
                         weekday: Int, hour: Int, weather: TrafficWeather) -> Double {
        let (local, hasLocal) = crossing(cells[Self.key(area: area, roadClass: .local, weekday: weekday, hour: hour, weather: weather)])
        let (pooled, hasPooled) = crossing(cells[Self.key(area: .pooled, roadClass: .highway, weekday: weekday, hour: hour, weather: weather)])
        return flows_learning_traffic_adjusted_seconds(routerSeconds, roadClass == .highway, local, hasLocal, pooled, hasPooled)
    }

    /// Extra minutes over the router's estimate — what the driver is shown.
    func predictedDelayMinutes(routerSeconds: Double, area: TrafficArea,
                               roadClass: RoadClass, weekday: Int, hour: Int,
                               weather: TrafficWeather) -> Int {
        let (local, hasLocal) = crossing(cells[Self.key(area: area, roadClass: .local, weekday: weekday, hour: hour, weather: weather)])
        let (pooled, hasPooled) = crossing(cells[Self.key(area: .pooled, roadClass: .highway, weekday: weekday, hour: hour, weather: weather)])
        // Absent where the minutes are not a number (the Swift this replaced
        // crashed): no delay to report.
        let minutes = flows_learning_traffic_delay_minutes(routerSeconds, roadClass == .highway, local, hasLocal, pooled, hasPooled)
        return minutes.is_some == 1 ? Int(minutes.value) : 0
    }

    /// How many trips back this cell — the UI only speaks up once the model
    /// has earned it.
    func isConfident(area: TrafficArea, roadClass: RoadClass,
                     weekday: Int, hour: Int, weather: TrafficWeather) -> Bool {
        let count = cells[Self.key(area: area, roadClass: roadClass, weekday: weekday,
                                   hour: hour, weather: weather)]?.count ?? 0
        return flows_learning_traffic_is_confident(Int64(count))
    }
}

/// Disk-backed wrapper: same pattern as SeasonalRiskModel.
// MARK: - Crossing a learned cell

/// A cell as the bridge takes it: its fields plus whether it exists.
private func crossing(_ cell: DelayCell?) -> (FlowsLearningCell, Bool) {
    (FlowsLearningCell(weighted_sum: cell?.weightedSum ?? 0, weight: cell?.weight ?? 0,
                       count: Double(cell?.count ?? 0)), cell != nil)
}

@MainActor
final class TrafficDelayModel: ObservableObject {
    @Published private(set) var store = TrafficDelayStore()

    private let url: URL

    init() {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = dir.appendingPathComponent("flows_traffic_delay.json")
        if let data = SecureBehaviorStore.readMigrating(url),
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
        store = TrafficDelayStore()
        SecureBehaviorStore.shred(url)
    }
}
