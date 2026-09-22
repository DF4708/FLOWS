// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// How much road one risky check point paints. The corridor is checked every
/// 40 km; a span used to take the worse of its two ends, so one red check
/// point reddened up to 80 km and a short trip went red end to end.
final class RouteRiskPaintingTests: XCTestCase {

    private func meters(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count > 1 else { return 0 }
        return (1..<coords.count).reduce(0.0) {
            $0 + POIRanking.meters(coords[$1 - 1], coords[$1])
        }
    }

    func testAPathIsCutAtItsOwnHalfwayPoint() {
        // A straight run of five points, 10 km apart in longitude at 43°N.
        let path = (0..<5).map {
            CLLocationCoordinate2D(latitude: 43, longitude: -89 + Double($0) * 0.1234)
        }
        let (first, second) = RouteService.halves(path)
        XCTAssertEqual(meters(first), meters(second), accuracy: meters(path) * 0.001,
                       "each half carries half the length")
        XCTAssertEqual(first.last?.latitude, second.first?.latitude)
        XCTAssertEqual(first.last?.longitude, second.first?.longitude)
        XCTAssertEqual(first.first?.longitude, path.first?.longitude, "starts where the path did")
        XCTAssertEqual(second.last?.longitude, path.last?.longitude, "ends where the path did")
        XCTAssertEqual(meters(first) + meters(second), meters(path),
                       accuracy: meters(path) * 0.001, "nothing is lost in the cut")
    }

    func testTwoPointsSplitAtTheirMidpoint() {
        let a = CLLocationCoordinate2D(latitude: 43, longitude: -89)
        let b = CLLocationCoordinate2D(latitude: 43, longitude: -88)
        let (first, second) = RouteService.halves([a, b])
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(first.last?.longitude ?? 0, -88.5, accuracy: 0.01)
    }

    func testAPathThatStandsStillStillSplits() {
        let here = CLLocationCoordinate2D(latitude: 43, longitude: -89)
        let (first, second) = RouteService.halves([here, here, here, here])
        XCTAssertFalse(first.isEmpty)
        XCTAssertFalse(second.isEmpty)
    }

    /// The painting rule itself: a span between a green and a red check point
    /// is half green, half red — not red throughout.
    func testEachHalfTakesTheCheckPointItIsNearer() {
        let calm = 0.2, red = 0.95
        let span = (0..<9).map {
            CLLocationCoordinate2D(latitude: 43, longitude: -89 + Double($0) * 0.05)
        }
        let (first, second) = RouteService.halves(span)
        let pieces = [RiskSegment(coordinates: first, risk: calm,
                                  lengthMeters: meters(first), sampleIndex: 0),
                      RiskSegment(coordinates: second, risk: red,
                                  lengthMeters: meters(second), sampleIndex: 1)]
        XCTAssertEqual(pieces.filter { FlowsCore.riskBand(score: $0.risk) == .red }
                        .reduce(0) { $0 + $1.lengthMeters },
                       meters(span) / 2, accuracy: meters(span) * 0.01,
                       "only the half next to the red check point is red")
        XCTAssertEqual(pieces.map(\.sampleIndex), [0, 1],
                       "each piece remembers its check point, so the live watch repaints it")
    }
}
