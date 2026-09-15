import CoreLocation
import Foundation
/// The bridge text helper POIRanking reads (a verbatim copy of BrandKnowledge.swift's).
extension RustStringRef {
    var text: String { len() == 0 ? "" : as_str().toString() }
}
