import CoreLocation
import Foundation
import MapKit
// Names the long-tail files mention that the oracle never exercises. The trail's store is a stub on purpose:
// the real one reads the user's Application Support file and keychain.
enum SecureBehaviorStore {
    static func readMigrating(_ url: URL) -> Data? { nil }
    @discardableResult static func save<T: Encodable>(_ value: T, to url: URL) -> Bool { true }
    static func shred(_ url: URL) {}
}
enum TransitPlanning { static func durationPhrase(_ s: TimeInterval?) -> String { "" } }
enum RouteService {
    nonisolated static func samplePoints(of polyline: MKPolyline, everyMeters: Double) -> [CLLocationCoordinate2D] { [] }
}
/// The bridge text helper POIRanking reads (a verbatim copy of BrandKnowledge.swift's).
extension RustStringRef {
    var text: String { len() == 0 ? "" : as_str().toString() }
}
