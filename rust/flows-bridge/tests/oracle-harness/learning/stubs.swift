// Stand-ins for the app's sealed store and logger, which the harness never
// exercises (SeasonalRiskModel's persistence is not under test).
import Foundation
enum SecureBehaviorStore {
  static let persistQueue = DispatchQueue(label: "stub")
  static func readMigrating(_ url: URL) -> Data? { nil }
  static func save<T: Encodable>(_ value: T, to url: URL) {}
  static func shred(_ url: URL) {}
  static func write(_ data: Data, to url: URL) {}
}
enum FlowsDiag {
  enum Level { case info }
  static func log(_ level: Level, _ tag: String, _ message: String) {}
}
