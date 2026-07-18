// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// One symbol per contiguous risk area: same-kind neighbors merge to the
/// worst member; different kinds may overlap (combined risk by design).
final class BadgeClusteringTests: XCTestCase {

    private func item(_ kind: String, lat: Double, lon: Double, score: Double)
        -> BadgeClustering.Item<String> {
        .init(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
              kind: kind, score: score)
    }

    func testDozenSameKindNeighborsCollapseToOne() {
        // 12 heat cells ~10 km apart along a line — one badge, at the worst.
        let items = (0..<12).map {
            item("heat", lat: 43.0, lon: -89.0 + Double($0) * 0.12,
                 score: $0 == 6 ? 0.9 : 0.5)
        }
        let kept = BadgeClustering.cluster(items, minSeparationMeters: 200_000)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].score, 0.9, "cluster centers on its worst member")
    }

    func testDifferentKindsMayOverlap() {
        let items = [
            item("tornado", lat: 43.0, lon: -89.0, score: 0.95),
            item("flood", lat: 43.01, lon: -89.01, score: 0.8),
        ]
        XCTAssertEqual(BadgeClustering.cluster(items, minSeparationMeters: 100_000).count, 2,
                       "a tornado symbol and a flood symbol may share an area")
    }

    func testWellSeparatedSameKindBothSurvive() {
        let items = [
            item("snow", lat: 43.0, lon: -89.0, score: 0.7),
            item("snow", lat: 46.0, lon: -95.0, score: 0.6),   // ~550 km away
        ]
        XCTAssertEqual(BadgeClustering.cluster(items, minSeparationMeters: 100_000).count, 2)
    }
}
