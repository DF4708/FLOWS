import CoreLocation
import Foundation
// Names the long-trip files mention that the oracle never exercises. Both secure stores are stubs on purpose:
// the real ones read the user's Application Support files and keychain.
enum SecureBehaviorStore {
    static func readMigrating(_ url: URL) -> Data? { nil }
    @discardableResult static func save<T: Encodable>(_ value: T, to url: URL) -> Bool { true }
    static func shred(_ url: URL) {}
}
enum SecureStore {
    static func set(_ value: String?, for key: String) {}
    static func get(_ key: String) -> String? { nil }
}
/// The bridge text helper POIRanking reads (a verbatim copy of BrandKnowledge.swift's).
extension RustStringRef {
    var text: String { len() == 0 ? "" : as_str().toString() }
}
