// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import MapKit
import XCTest

/// Owner item 9 (2026-09-21): "Faster route navigation should automatically
/// be approved unless it increases the route risk level" — Clear and Green
/// counted as one low level.
final class FasterRoutePolicyTests: XCTestCase {
    /// A route with check points `samples` and stretches `lengths` between
    /// them (one fewer).
    private func route(risk: Double, scored: Bool = true,
                       samples: [Double] = [], lengths: [Double] = []) -> PlannedRoute {
        var r = PlannedRoute(route: MKRoute(), sourceName: "A", destinationName: "B")
        r.weatherRisk = risk
        r.weatherScored = scored
        r.riskSamples = samples.map {
            RiskSample(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), risk: $0)
        }
        r.riskSegments = lengths.map { RiskSegment(coordinates: [], risk: 0, lengthMeters: $0) }
        return r
    }

    func testTheRoadAheadIsWhatAFasterRoadReplaces() {
        // A red check point at the start, calm after; 10 km then 30 km.
        let leg = route(risk: 0.95, samples: [0.95, 0.2, 0.2], lengths: [10_000, 30_000])
        XCTAssertEqual(FasterRoutePolicy.aheadRisk(of: leg, alongMeters: 15_000) ?? -1,
                       0.2, accuracy: 1e-12)
        XCTAssertEqual(FasterRoutePolicy.aheadRisk(of: leg, alongMeters: 0) ?? -1,
                       0.95, accuracy: 1e-12)
        // Just past the red check point, inside the first stretch: calm ahead.
        // (A red point behind must not make a riskier road look no worse.)
        XCTAssertEqual(FasterRoutePolicy.aheadRisk(of: leg, alongMeters: 9_000) ?? -1,
                       0.2, accuracy: 1e-12)
        // Unscored, or nothing to read: not known.
        XCTAssertNil(FasterRoutePolicy.aheadRisk(
            of: route(risk: 0.2, scored: false, samples: [0.2, 0.2], lengths: [1_000]),
            alongMeters: 0))
        XCTAssertNil(FasterRoutePolicy.aheadRisk(of: route(risk: 0.2), alongMeters: 0))
    }

    func testClearAndGreenAreOneLevel() {
        // Green road over a clear road ahead: taken.
        XCTAssertEqual(FasterRoutePolicy.riskVerdict(
            candidateRisk: 0.5, aheadRisk: 0.1, limitsUnchecked: false), .switchNow)
        // Yellow over Green: asked.
        XCTAssertEqual(FasterRoutePolicy.riskVerdict(
            candidateRisk: 0.75, aheadRisk: 0.5, limitsUnchecked: false), .riskier)
        // Red is always asked.
        XCTAssertEqual(FasterRoutePolicy.riskVerdict(
            candidateRisk: 0.95, aheadRisk: 0.95, limitsUnchecked: false), .riskier)
    }

    func testAnythingUnknownIsAskedNeverSwitched() {
        // A score that didn't finish, or an unknown road ahead.
        XCTAssertEqual(FasterRoutePolicy.riskVerdict(
            candidateRisk: nil, aheadRisk: 0.1, limitsUnchecked: false), .unknown)
        XCTAssertEqual(FasterRoutePolicy.riskVerdict(
            candidateRisk: 0.1, aheadRisk: nil, limitsUnchecked: false), .unknown)
        // Towing, or a flood-zone filter: the new road can't be checked yet.
        XCTAssertEqual(FasterRoutePolicy.riskVerdict(
            candidateRisk: 0.1, aheadRisk: 0.1, limitsUnchecked: true), .unknown)
    }

    func testTheCandidateIsMeasuredFromTheCarForward() {
        // The candidate starts at the car: a Yellow cell the car sits in is
        // where it already is, on either road, so 1 m in reads only the
        // first stretch's forward end.
        let candidate = route(risk: 0.75, samples: [0.75, 0.2, 0.2], lengths: [40_000, 10_000])
        XCTAssertEqual(FasterRoutePolicy.aheadRisk(of: candidate, alongMeters: 1) ?? -1,
                       0.2, accuracy: 1e-12)
    }

    func testASwitchMustSaveFLOWSsSameTimeTolerance() {
        // An hour's drive: the tolerance is 8% of the shorter time (4.8 min).
        XCTAssertTrue(FasterRoutePolicy.savesEnough(currentSeconds: 3_600, candidateSeconds: 3_000))
        XCTAssertFalse(FasterRoutePolicy.savesEnough(currentSeconds: 3_600, candidateSeconds: 3_400))
        // A short trip still needs the 2-minute floor.
        XCTAssertFalse(FasterRoutePolicy.savesEnough(currentSeconds: 600, candidateSeconds: 520))
        XCTAssertTrue(FasterRoutePolicy.savesEnough(currentSeconds: 600, candidateSeconds: 470))
    }

    func testADetourGetsCheckPointsOfItsOwn() {
        // The road runs 25 km north; the candidate follows it 5 km, runs
        // 10 km beside it 1 km east, and comes back.
        let road = line(from: 43.0, count: 251)
        let side = -89.4 + 1_000.0 / 81_400.0
        let candidate = line(from: 43.0, count: 51)
            + line(from: 43.0 + 5_000.0 / 111_320.0, count: 101, longitude: side)
            + line(from: 43.0 + 15_000.0 / 111_320.0, count: 101)
        let spans = FasterRoutePolicy.offLineSpans(candidate: candidate, road: road)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.from ?? -1, 5_000, accuracy: 5)
        XCTAssertEqual(spans.first?.to ?? -1, 17_000, accuracy: 20)
        XCTAssertTrue(FasterRoutePolicy.offLineSpans(candidate: road, road: road).isEmpty)
        // 12 km off the road: every 4 km, not every 40.
        let spacing = FasterRoutePolicy.checkSpacing(spans: spans, candidateMeters: 27_000)
        XCTAssertEqual(spacing, 4_000, accuracy: 10)
        XCTAssertEqual(FasterRoutePolicy.checkSpacing(spans: [], candidateMeters: 27_000),
                       FasterRoutePolicy.corridorCheckMeters)

        // Check points only at the car and the end (the 40 km spacing on a
        // 27 km road): the detour was never looked at.
        let coarse = route(risk: 0.2, samples: [0.2, 0.2], lengths: [27_000])
        XCTAssertFalse(FasterRoutePolicy.detourChecked(spans: spans, on: coarse))
        // One at 8 km, on the detour: it was.
        let close = route(risk: 0.2, samples: [0.2, 0.2, 0.2], lengths: [8_000, 19_000])
        XCTAssertEqual(FasterRoutePolicy.checkAlongs(of: close), [0, 8_000, 27_000])
        XCTAssertTrue(FasterRoutePolicy.detourChecked(spans: spans, on: close))
        XCTAssertTrue(FasterRoutePolicy.detourChecked(spans: [], on: coarse))
        XCTAssertFalse(FasterRoutePolicy.detourChecked(spans: spans, on: route(risk: 0.2)))
    }

    func testTheDriversRoadChoicesAreKept() {
        // Whatever a bare MKRoute reports for tolls and highways, the rule
        // refuses exactly those; the Rust tests cover every combination.
        let r = route(risk: 0.1)
        XCTAssertEqual(FasterRoutePolicy.keepsRoadChoice(r, leg: r, filters: [.noTolls]),
                       !r.hasTolls)
        XCTAssertEqual(FasterRoutePolicy.keepsRoadChoice(r, leg: r, filters: [.noHighways]),
                       !r.hasHighways)
        // A leg is its own road: it keeps its own choices.
        XCTAssertTrue(FasterRoutePolicy.keepsRoadChoice(r, leg: r, filters: []))
    }

    /// A straight line of points, 100 m apart, heading north from `start`.
    private func line(from start: Double, count: Int,
                      longitude: Double = -89.4) -> [CLLocationCoordinate2D] {
        let step = 100.0 / 111_320.0
        return (0..<count).map {
            CLLocationCoordinate2D(latitude: start + Double($0) * step, longitude: longitude)
        }
    }

    func testWhereTheFasterRoadLeavesTheCurrentOne() {
        // The current road runs 5 km north; the candidate follows it 2 km,
        // then bends 1 km east.
        let road = line(from: 43.0, count: 51)
        let shared = line(from: 43.0, count: 21)
        let east = (1...10).map {
            CLLocationCoordinate2D(latitude: shared.last!.latitude,
                                   longitude: -89.4 + Double($0) * 100.0 / 81_400.0)
        }
        let candidate = shared + east
        let diverge = FasterRoutePolicy.divergeAlong(candidate: candidate, road: road)
        XCTAssertNotNil(diverge)
        XCTAssertGreaterThan(diverge ?? 0, 1_950)
        XCTAssertLessThan(diverge ?? .infinity, 2_050)
        // The same road never leaves; a line too short to compare says nothing.
        XCTAssertNil(FasterRoutePolicy.divergeAlong(candidate: road, road: road))
        XCTAssertNil(FasterRoutePolicy.divergeAlong(candidate: [shared[0]], road: road))
        XCTAssertNil(FasterRoutePolicy.divergeAlong(candidate: candidate, road: []))

        // A car 500 m in can still take it; one 1.9 km in at highway speed
        // (margin 300 m) can't; one already off the candidate can't.
        XCTAssertTrue(FasterRoutePolicy.canStillTake(
            candidate: candidate, divergeAlong: diverge, position: shared[5], speedMps: 30))
        XCTAssertFalse(FasterRoutePolicy.canStillTake(
            candidate: candidate, divergeAlong: diverge, position: shared[19], speedMps: 30))
        let pastTheTurn = road[30]   // 3 km north, off the bent candidate
        XCTAssertFalse(FasterRoutePolicy.canStillTake(
            candidate: candidate, divergeAlong: diverge, position: pastTheTurn, speedMps: 30))
        // Between two vertices on the line (not near either) is on it.
        let between = CLLocationCoordinate2D(
            latitude: (shared[3].latitude + shared[4].latitude) / 2, longitude: -89.4)
        XCTAssertTrue(FasterRoutePolicy.canStillTake(
            candidate: candidate, divergeAlong: diverge, position: between, speedMps: 30))
        XCTAssertFalse(FasterRoutePolicy.canStillTake(
            candidate: [], divergeAlong: nil, position: between, speedMps: 30))
    }

    func testAParallelRoadOfTheSameLengthIsNotTheCurrentRoad() {
        // 2 km north, against a road 200 m to the east of it: same length,
        // never on the current road's line, so it leaves at once.
        let road = line(from: 43.0, count: 21)
        let parallel = line(from: 43.0, count: 21, longitude: -89.4 + 200.0 / 81_400.0)
        XCTAssertEqual(FasterRoutePolicy.divergeAlong(candidate: parallel, road: road), 0)
        // An exit ramp 20 m beside the mainline is off it (a 60 m test let
        // a switch through after the exit).
        let ramp = line(from: 43.0, count: 21, longitude: -89.4 + 20.0 / 81_400.0)
        XCTAssertEqual(FasterRoutePolicy.divergeAlong(candidate: ramp, road: road), 0)
    }

    func testWhatFLOWSSays() {
        XCTAssertEqual(SiriSummaries.fasterRouteOffer(minutes: 12, riskier: true),
                       "Traffic ahead adds about 12 minutes. A faster route is ready, "
                       + "but it has more risk. Say yes to take it.")
        XCTAssertEqual(SiriSummaries.fasterRouteTaken(minutes: 9),
                       "Heads up, there's traffic ahead, so I switched you to a faster route. "
                       + "It saves about 9 minutes, with no more risk.")
        XCTAssertTrue(SiriSummaries.fasterRouteTaken(minutes: 1).contains("about 1 minute,"))
        XCTAssertEqual(SiriSummaries.fasterRouteRefusedRed(minutes: 12),
                       "Traffic ahead adds about 12 minutes. The faster road runs through "
                       + "a red weather zone, so I'm staying on this one.")
        XCTAssertEqual(SiriSummaries.trafficNoFasterRoute(minutes: 10),
                       "Traffic ahead adds about 10 minutes. There's no faster road "
                       + "right now, so I'm staying on this one.")
        XCTAssertEqual(SiriSummaries.fasterRouteNowRed,
                       "The faster road now runs through a red weather zone, so I'm staying "
                       + "on this one.")
        XCTAssertEqual(SiriSummaries.fasterRoutePassed,
                       "The turn for the faster road is behind us, so I'm staying on this one.")
    }
}
