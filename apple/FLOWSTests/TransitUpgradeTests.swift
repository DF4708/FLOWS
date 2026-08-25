// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// The three transit upgrades' pure logic: Amtrak station nearest-selection
/// over the bundled list, the plane option's airport pick + honest timing,
/// and the walk-hybrid ride's significance rule.
final class TransitUpgradeTests: XCTestCase {

    // MARK: - Amtrak stations

    private let chicago = AmtrakStation(code: "CHI", name: "Chicago Union Station",
                                        lat: 41.87864, lon: -87.63920)
    private let milwaukee = AmtrakStation(code: "MKE", name: "Milwaukee Intermodal Station",
                                          lat: 43.03448, lon: -87.91700)
    private let stLouis = AmtrakStation(code: "STL", name: "St. Louis Gateway Station",
                                        lat: 38.62230, lon: -90.19400)

    // Madison WI is ~75 mi from Milwaukee, ~130 mi from Chicago: the nearest
    // station must win, not the biggest.
    func testNearestStationPicksClosest() {
        let madison = CLLocationCoordinate2D(latitude: 43.0731, longitude: -89.4012)
        let hit = AmtrakStations.nearest(to: madison, within: 240_000,
                                         in: [chicago, milwaukee, stLouis])
        XCTAssertEqual(hit?.code, "MKE")
    }

    // The radius is a hard cap: a point farther than every station gets nil
    // (the caller falls back to the network search), never a wrong-city
    // "nearest".
    func testNearestStationRespectsRadius() {
        let denver = CLLocationCoordinate2D(latitude: 39.7392, longitude: -104.9903)
        XCTAssertNil(AmtrakStations.nearest(to: denver, within: 120_000,
                                            in: [chicago, milwaukee, stLouis]))
        XCTAssertNil(AmtrakStations.nearest(to: denver, within: 120_000, in: []))
    }

    // The station's amtrak.com page is derived from its code, lowercased.
    func testStationURL() {
        XCTAssertEqual(chicago.url?.absoluteString,
                       "https://www.amtrak.com/stations/chi")
    }

    // The SHIPPING resource must parse and actually cover the network — big
    // hubs present, coordinates in range. Loaded from the test bundle copy of
    // the same file the app bundles.
    func testBundledStationListParsesAndCoversHubs() throws {
        let url = try XCTUnwrap(Bundle(for: TransitUpgradeTests.self)
            .url(forResource: "amtrak_stations", withExtension: "json"))
        let stations = AmtrakStations.load(from: url)
        XCTAssertGreaterThan(stations.count, 400, "national list, not a sample")
        for code in ["NYP", "CHI", "LAX", "SEA", "WAS", "NOL", "DEN"] {
            XCTAssertTrue(stations.contains { $0.code == code }, "missing \(code)")
        }
        for s in stations {
            XCTAssertTrue((17...61).contains(s.lat), "\(s.code) lat \(s.lat)")
            XCTAssertTrue((-159 ... -66).contains(s.lon), "\(s.code) lon \(s.lon)")
        }
        // New York Penn must resolve as the nearest station to midtown.
        let midtown = CLLocationCoordinate2D(latitude: 40.7549, longitude: -73.9840)
        XCTAssertEqual(AmtrakStations.nearest(to: midtown, within: 120_000,
                                              in: stations)?.code, "NYP")
    }

    func testStationListDecodesEnvelope() {
        let json = """
        {"source": "doc", "retrieved": "2026-07-30", "stations":
         [{"code": "ABC", "name": "Test Station", "lat": 40.0, "lon": -75.0}]}
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amtrak_test_\(UUID().uuidString).json")
        try? json.data(using: .utf8)?.write(to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stations = AmtrakStations.load(from: dir)
        XCTAssertEqual(stations, [AmtrakStation(code: "ABC", name: "Test Station",
                                                lat: 40.0, lon: -75.0)])
        XCTAssertEqual(AmtrakStations.load(from: nil), [])
    }

    // MARK: - Plane option

    func testWorthFlyingThreshold() {
        XCTAssertFalse(AirTravel.worthFlying(tripMiles: 60))
        XCTAssertFalse(AirTravel.worthFlying(tripMiles: 99.9))
        XCTAssertTrue(AirTravel.worthFlying(tripMiles: 100))
        XCTAssertTrue(AirTravel.worthFlying(tripMiles: 2500))
    }

    // Door time = 90 min early + flight + 30 min bags; the flight itself is
    // taxi/climb overhead + cruise. A 460-mile hop cruises one hour.
    func testFlightTimingHonest() {
        let taxiAndCruise: TimeInterval = 45 * 60 + 3600
        let withBuffers: TimeInterval = taxiAndCruise + 90 * 60 + 30 * 60
        XCTAssertEqual(AirTravel.flightSeconds(airportMiles: 460),
                       taxiAndCruise, accuracy: 1)
        XCTAssertEqual(AirTravel.doorSeconds(airportMiles: 460),
                       withBuffers, accuracy: 1)
        // Monotonic: longer hops never get shorter estimates.
        XCTAssertLessThan(AirTravel.doorSeconds(airportMiles: 300),
                          AirTravel.doorSeconds(airportMiles: 1200))
    }

    func testFareEstimateFloorsAndScales() {
        XCTAssertEqual(AirTravel.fareEstimate(airportMiles: 80), 59)   // floor
        XCTAssertEqual(AirTravel.fareEstimate(airportMiles: 1000),
                       39 + 110, accuracy: 0.01)
    }

    // Commercial preference: internationals first, plain airports next;
    // heliports, seaplane bases, and military fields never board a flight.
    func testAirportPickPrefersCommercial() {
        let cands = [
            AirTravel.Candidate(name: "Downtown Heliport", meters: 2_000),
            AirTravel.Candidate(name: "Fulton County Airport", meters: 12_000),
            AirTravel.Candidate(name: "Hartsfield-Jackson Atlanta International Airport",
                                meters: 18_000),
            AirTravel.Candidate(name: "Dobbins Air Force Base", meters: 9_000),
        ]
        XCTAssertEqual(AirTravel.pickIndex(cands, maxMeters: 150_000), 2,
                       "international outranks nearer GA field and rejects")
        // Distance breaks ties inside a tier.
        let two = [
            AirTravel.Candidate(name: "Far International Airport", meters: 90_000),
            AirTravel.Candidate(name: "Near International Airport", meters: 30_000),
        ]
        XCTAssertEqual(AirTravel.pickIndex(two, maxMeters: 150_000), 1)
        // The radius cap is hard; all-rejects → nil.
        XCTAssertNil(AirTravel.pickIndex(two, maxMeters: 10_000))
        XCTAssertNil(AirTravel.pickIndex(
            [AirTravel.Candidate(name: "City Heliport", meters: 500)],
            maxMeters: 150_000))
    }

    func testFlightTicketLinkKeyless() throws {
        let own = URL(string: "https://www.flylax.com")
        XCTAssertEqual(AirTravel.ticket(board: "LAX", alight: "JFK",
                                        airportURL: own).url, own)
        let neutral = AirTravel.ticket(board: "Austin-Bergstrom International Airport",
                                       alight: "Denver International Airport",
                                       airportURL: nil)
        XCTAssertEqual(neutral.label,
                       "Find flights: Austin-Bergstrom International Airport → Denver International Airport")
        let url = try XCTUnwrap(neutral.url)
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertTrue(url.path.hasPrefix("/travel/flights"))
        XCTAssertFalse(url.absoluteString.contains("key"), "keyless by design")
    }

    // MARK: - Walk + paid ride

    func testRideCostModel() {
        XCTAssertEqual(HybridWalk.rideCostUSD(miles: 0), 3.0, accuracy: 0.001)
        XCTAssertEqual(HybridWalk.rideCostUSD(miles: 10), 14.0, accuracy: 0.001)
        XCTAssertEqual(HybridWalk.maxAffordableRideMiles, 20.0, accuracy: 0.001)
    }

    // 6-mile trip: two-hour walk vs a 15-minute, ~$9.60 ride — clears the bar
    // (87% saved, under the cap) and rides the whole way.
    func testFullRideOfferedWhenSignificant() {
        let offer = HybridWalk.evaluate(walkAloneSeconds: 7200,
                                        driveSeconds: 900, tripMiles: 6)
        XCTAssertNotNil(offer)
        XCTAssertEqual(offer?.rideMiles ?? 0, 6, accuracy: 0.001)
        XCTAssertEqual(offer?.walkSeconds, 0)
        XCTAssertEqual(offer?.costUSD ?? 0, 3 + 6.6, accuracy: 0.001)
    }

    // The walker didn't want to spend money: a short stroll (under 30 min)
    // never gets a ride pitch, no matter how fast a car would be.
    func testShortWalkNeverOffered() {
        XCTAssertNil(HybridWalk.evaluate(walkAloneSeconds: 20 * 60,
                                         driveSeconds: 180, tripMiles: 1.0))
    }

    // Significance is BOTH relative and absolute: 40% of the time AND at
    // least 15 minutes.
    func testSignificanceBar() {
        // 35% saved — under the fraction bar.
        XCTAssertFalse(HybridWalk.meetsBar(walkAloneSeconds: 3600,
                                           totalSeconds: 2340, costUSD: 10))
        // Exactly 40% and 24 min saved — passes.
        XCTAssertTrue(HybridWalk.meetsBar(walkAloneSeconds: 3600,
                                          totalSeconds: 2160, costUSD: 10))
        // 50% saved but only 12.5 minutes — absolute floor fails it.
        XCTAssertFalse(HybridWalk.meetsBar(walkAloneSeconds: 1500,
                                           totalSeconds: 750, costUSD: 5))
        // Over the wallet cap — never offered.
        XCTAssertFalse(HybridWalk.meetsBar(walkAloneSeconds: 36_000,
                                           totalSeconds: 3600, costUSD: 25.01))
        XCTAssertTrue(HybridWalk.meetsBar(walkAloneSeconds: 36_000,
                                          totalSeconds: 3600, costUSD: 25.0))
    }

    // 40-mile trek: the whole ride would cost $47 — over the cap — so the
    // offer rides the affordable 20 miles and walks the rest, still saving
    // half the day.
    func testPartialRideWhenCapBinds() {
        let walkAlone: TimeInterval = 13 * 3600
        let offer = HybridWalk.evaluate(walkAloneSeconds: walkAlone,
                                        driveSeconds: 3600, tripMiles: 40)
        XCTAssertNotNil(offer)
        XCTAssertEqual(offer?.rideMiles ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(offer?.costUSD ?? 0, 25, accuracy: 0.001)
        XCTAssertEqual(offer?.rideSeconds ?? 0, 1800, accuracy: 1)     // half the drive
        XCTAssertEqual(offer?.walkSeconds ?? 0, walkAlone / 2, accuracy: 1)
        if let offer {
            XCTAssertTrue(HybridWalk.meetsBar(walkAloneSeconds: walkAlone,
                                              totalSeconds: offer.totalSeconds,
                                              costUSD: offer.costUSD))
        }
    }

    // Drop-off interpolation: on a straight 4-point line, the 1.5-segment
    // mark lands halfway down the second segment; past-the-end returns the
    // whole path.
    func testPrefixCoordinates() {
        let line = [
            CLLocationCoordinate2D(latitude: 40.0, longitude: -75.0),
            CLLocationCoordinate2D(latitude: 40.1, longitude: -75.0),
            CLLocationCoordinate2D(latitude: 40.2, longitude: -75.0),
            CLLocationCoordinate2D(latitude: 40.3, longitude: -75.0),
        ]
        let segment = POIRanking.meters(line[0], line[1])
        let prefix = HybridWalk.prefixCoordinates(line, meters: segment * 1.5)
        XCTAssertEqual(prefix.count, 3)
        XCTAssertEqual(prefix.last?.latitude ?? 0, 40.15, accuracy: 0.0005)
        XCTAssertEqual(prefix.last?.longitude ?? 0, -75.0, accuracy: 0.0005)
        XCTAssertEqual(HybridWalk.prefixCoordinates(line, meters: segment * 99).count,
                       line.count, "past the end → the whole path")
        XCTAssertTrue(HybridWalk.prefixCoordinates([], meters: 100).isEmpty)
    }

    // Both hail links are keyless universal links carrying pickup + drop-off.
    func testHailDeepLinks() throws {
        let pickup = CLLocationCoordinate2D(latitude: 40.75490, longitude: -73.98400)
        let drop = CLLocationCoordinate2D(latitude: 40.64130, longitude: -73.77810)
        let uber = try XCTUnwrap(HybridWalk.uberURL(
            pickup: pickup, pickupName: "Midtown", drop: drop, dropName: "JFK"))
        XCTAssertEqual(uber.host, "m.uber.com")
        let uberQ = uber.absoluteString
        XCTAssertTrue(uberQ.contains("action=setPickup"))
        XCTAssertTrue(uberQ.contains("40.75490") && uberQ.contains("-73.77810"))
        let lyft = try XCTUnwrap(HybridWalk.lyftURL(pickup: pickup, drop: drop))
        XCTAssertEqual(lyft.host, "lyft.com")
        XCTAssertTrue(lyft.absoluteString.contains("40.64130"))
        for url in [uber, lyft] {
            XCTAssertFalse(url.absoluteString.lowercased().contains("client_id"),
                           "keyless by design")
        }
    }
}
