import CoreLocation
import Foundation
// Names the files mention that the oracle never exercises: the network, the diagnostics journal, the caches and the
// player. No record touches them, and the stubs never reach the network or the owner's data.
enum ThrottledNet {
    static func fetch(_ url: URL) async throws -> (Data, URLResponse) { throw URLError(.notConnectedToInternet) }
}
enum TruckerRadio {
    struct Channel { let name: String; let detail: String; let url: String }
}
enum FlowsDiag {
    enum Level { case info, warn, error }
    static func logThrottled(key: String, _ level: Level, _ tag: String, _ message: @autoclosure () -> String) {}
}
enum CacheEviction {
    static func dropHalf<K, V>(_ cache: inout [K: V]) {}
    static func dropOldestHalf<V>(_ cache: inout [String: V], date: (V) -> Date) {}
}
final class AdaptiveTuning: @unchecked Sendable {
    static let shared = AdaptiveTuning()
    func ttl(_ seconds: TimeInterval) -> TimeInterval { seconds }
}
enum LiveHazardFeedFetcher {
    static func overpassElements(post query: String) async -> [[String: Any]]? { nil }
}
