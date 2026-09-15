import CoreLocation
import Foundation
import MapKit
import os
/// Names the feed files mention that the oracle never exercises: the network,
/// its caches and gates, the diagnostics log, the tuning knobs, the route
/// sample type, and the alert and maneuver helpers other facades own.
enum ThrottledNet {
    static func fetch(_ url: URL) async throws -> (Data, URLResponse) { throw URLError(.notConnectedToInternet) }
    static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.notConnectedToInternet) }
}
enum CacheEviction {
    static func dropHalf<K, V>(_ cache: inout [K: V]) {}
    static func dropOldestHalf<V>(_ cache: inout [String: V], date: (V) -> Date) {}
}
final class AdaptiveTuning: @unchecked Sendable {
    struct Settings { var maxInFlight = 4; var ttlMultiplier = 1.0 }
    static let shared = AdaptiveTuning()
    var settings: Settings { Settings() }
    var maxInFlight: Int { 4 }
    func ttl(_ base: TimeInterval) -> TimeInterval { base }
}
enum FlowsDiag {
    enum Level: String, Sendable { case info = "INFO", warn = "WARN", error = "ERROR" }
    nonisolated static func logThrottled(key: String, interval: TimeInterval = 600,
                                         _ level: Level = .warn, _ area: String, _ message: String) {}
}
actor RequestGate {
    static let shared = RequestGate()
    func withPlanningBurst<T: Sendable>(_ body: @Sendable () async -> T) async -> T { await body() }
}
struct RiskSample: Sendable {
    let coordinate: CLLocationCoordinate2D
    let risk: Double
    var worstEvent: String? = nil
    var alertID: String? = nil
}
enum ImminentAlerts {
    static func isLookoutEvent(_ event: String) -> Bool { false }
    static func isLifeSafetyEvent(_ event: String) -> Bool { false }
}
enum ManeuverSymbol { enum Side { case left, right, none } }
let flowsSignposter = OSSignposter(subsystem: "oracle", category: "perf")
/// The planned route the corridor watch walks; the oracle never starts a watch.
struct PlannedRoute {
    struct Route { var polyline: MKPolyline }
    var route: Route
    var riskSamples: [RiskSample] = []
    var eta: Double = 0
    var distanceMeters: Double = 0
}
enum RouteService {
    nonisolated static func samplePoints(of polyline: MKPolyline, everyMeters: Double) -> [CLLocationCoordinate2D] { [] }
}
