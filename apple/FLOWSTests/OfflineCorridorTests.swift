// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// Saved road corridors for the stretches between towns: kept while they can
/// still get a driver home with no signal, dropped the moment they can't.
final class OfflineCorridorTests: XCTestCase {

    /// A corridor running east from Madison toward Milwaukee.
    private func corridor(savedAt: Date = Date(),
                          from: (Double, Double) = (43.07, -89.40),
                          to: (Double, Double) = (43.04, -87.91)) -> SavedCorridor {
        var pts: [[Double]] = []
        for i in 0...20 {
            let f = Double(i) / 20
            pts.append([from.0 + (to.0 - from.0) * f, from.1 + (to.1 - from.1) * f])
        }
        return SavedCorridor(id: UUID(), savedAt: savedAt,
                             destinationName: "Milwaukee", points: pts)
    }

    private func at(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: what earns a place on the device

    func testOnlyIntercityTripsAreWorthCarrying() {
        // A cross-town errand: good signal, dense roads, no need.
        XCTAssertFalse(CorridorRetention.worthSaving(tripMeters: 6_000))
        // The open road between towns is exactly the case this exists for.
        XCTAssertTrue(CorridorRetention.worthSaving(tripMeters: 130_000))
    }

    func testGeometryIsThinnedButStillEndsWhereTheRouteEnds() {
        var dense: [CLLocationCoordinate2D] = []
        for i in 0...5_000 {
            dense.append(at(43.0 + Double(i) * 0.0001, -89.0))
        }
        let thin = CorridorRetention.decimate(dense)
        XCTAssertLessThan(thin.count, dense.count / 5, "must actually thin")
        XCTAssertGreaterThanOrEqual(thin.count, 2)
        // The destination survives decimation — that's the point of the line.
        XCTAssertEqual(thin.last!.latitude, dense.last!.latitude, accuracy: 0.0001)
    }

    // MARK: when it goes

    func testKeptWhileTheRoadIsStillAhead() {
        let c = corridor()
        // Sitting at the start of the corridor.
        XCTAssertTrue(CorridorRetention.keep(c, now: Date(), position: at(43.07, -89.40)))
        // Partway along it.
        XCTAssertTrue(CorridorRetention.keep(c, now: Date(), position: at(43.05, -88.60)))
    }

    func testDroppedOnceTheDestinationIsReached() {
        let c = corridor()
        XCTAssertFalse(CorridorRetention.keep(c, now: Date(), position: at(43.04, -87.91)),
                       "arrived — the corridor did its job")
    }

    func testDroppedOnceTheWholeStretchIsBehindYou() {
        let c = corridor()
        // Far north — nothing on the corridor is near.
        XCTAssertFalse(CorridorRetention.keep(c, now: Date(), position: at(45.5, -89.0)))
    }

    func testDegradesAfterOneWeek() {
        let stale = corridor(savedAt: Date().addingTimeInterval(-8 * 24 * 3600))
        XCTAssertFalse(CorridorRetention.keep(stale, now: Date(), position: at(43.07, -89.40)),
                       "a week-old corridor is a stale map, not a lifeline")
        let fresh = corridor(savedAt: Date().addingTimeInterval(-6 * 24 * 3600))
        XCTAssertTrue(CorridorRetention.keep(fresh, now: Date(), position: at(43.07, -89.40)))
    }

    func testExpiryAppliesEvenWithNoPositionToJudgeBy() {
        let stale = corridor(savedAt: Date().addingTimeInterval(-30 * 24 * 3600))
        XCTAssertFalse(CorridorRetention.keep(stale, now: Date(), position: nil))
        // …but a fresh one with no fix is kept: losing GPS must not erase
        // the very thing that helps when GPS is all you have.
        XCTAssertTrue(CorridorRetention.keep(corridor(), now: Date(), position: nil))
    }

    // MARK: the stored set

    func testNewerCorridorForTheSameRoadReplacesTheOlder() {
        let old = corridor(savedAt: Date().addingTimeInterval(-3_600))
        let new = corridor()
        XCTAssertTrue(CorridorRetention.supersedes(new, old))
        // A corridor to somewhere else does not.
        let elsewhere = corridor(to: (41.88, -87.63))   // Chicago
        XCTAssertFalse(CorridorRetention.supersedes(elsewhere, old))
    }

    func testPruneKeepsNewestAndCaps() {
        let many = (0..<8).map {
            corridor(savedAt: Date().addingTimeInterval(-Double($0) * 60),
                     to: (43.04, -87.91 - Double($0)))
        }
        let kept = CorridorRetention.prune(many, now: Date(), position: at(43.07, -89.40))
        XCTAssertLessThanOrEqual(kept.count, CorridorRetention.maxStored)
        // Newest first.
        XCTAssertEqual(kept.first?.savedAt, many.first?.savedAt)
    }

    func testPruneClearsEverythingStale() {
        let old = (0..<3).map { _ in
            corridor(savedAt: Date().addingTimeInterval(-10 * 24 * 3600))
        }
        XCTAssertTrue(CorridorRetention.prune(old, now: Date(),
                                              position: at(43.07, -89.40)).isEmpty)
    }
}
