import Foundation
enum ThrottledNet {
    static func fetch(_ url: URL) async throws -> (Data, URLResponse) { throw URLError(.notConnectedToInternet) }
    static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.notConnectedToInternet) }
}
enum CacheEviction { static func dropHalf<K, V>(_ cache: inout [K: V]) {} }
enum ImminentAlerts {
    static func isLookoutEvent(_ event: String) -> Bool { false }
    static func isLifeSafetyEvent(_ event: String) -> Bool { false }
}
final class AdaptiveTuning: @unchecked Sendable {
    static let shared = AdaptiveTuning()
    func ttl(_ base: TimeInterval) -> TimeInterval { base }
}
extension CacheEviction {
    static func dropOldestHalf<K, V>(_ cache: inout [K: V], stamp: (V) -> Date) {}
}
enum FlowsDiag {
    enum Level: String, Sendable { case info = "INFO", warn = "WARN", error = "ERROR" }
    nonisolated static func logThrottled(key: String, interval: TimeInterval = 600,
                                         _ level: Level = .warn, _ area: String, _ message: String) {}
}
