// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// The rotating diagnostic journal and the redundancy parsers: the Open-Meteo
/// forecast rung (the NWS forecast backup), the IEM storm-based-warning
/// mirror (the NWS alert backup), and the tier-anchored hotel estimate.
final class DiagAndRedundancyTests: XCTestCase {

    // MARK: FlowsDiag — ring, rotation, throttle

    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flows-diag-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testJournalRingCapAndOrder() async {
        let diag = FlowsDiag(directory: tempDir(), ringCap: 5, fileCap: 1 << 20)
        for i in 0..<12 { await diag.append(.info, "test", "line \(i)") }
        let recent = await diag.recent(10)
        XCTAssertEqual(recent.count, 5)                       // ring capped
        XCTAssertTrue(recent.last!.hasSuffix("line 11"))      // newest last
        XCTAssertTrue(recent.first!.hasSuffix("line 7"))
        XCTAssertTrue(recent.allSatisfy { $0.contains("INFO [test]") })
    }

    func testJournalRotatesAtFileCap() async {
        let dir = tempDir()
        // Tiny cap: a handful of lines forces a rotation.
        let diag = FlowsDiag(directory: dir, ringCap: 100, fileCap: 200)
        for i in 0..<20 { await diag.append(.warn, "rot", "event number \(i)") }
        _ = await diag.recent(1)   // barrier: all appends applied
        let current = dir.appendingPathComponent("flows_diag.log")
        let rolled = dir.appendingPathComponent("flows_diag.1.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rolled.path))
        let currentSize = (try? FileManager.default
            .attributesOfItem(atPath: current.path)[.size] as? Int).flatMap { $0 } ?? 0
        // Rotation keeps the live file bounded near the cap, never unbounded.
        XCTAssertLessThan(currentSize, 400)
    }

    func testJournalThrottleCollapsesRepeats() async {
        let diag = FlowsDiag(directory: tempDir(), ringCap: 50, fileCap: 1 << 20)
        for _ in 0..<5 {
            await diag.appendThrottled(key: "same", interval: 600, .warn, "net", "provider down")
        }
        await diag.appendThrottled(key: "other", interval: 600, .warn, "net", "different thing")
        let recent = await diag.recent(10)
        XCTAssertEqual(recent.count, 2)   // one per key inside the interval
    }

    // MARK: Open-Meteo forecast parsing (NWS forecast redundancy)

    func testOpenMeteoConditionsParsing() {
        let json: [String: Any] = ["hourly": [
            "temperature_2m": [60.0, 62.0, 64.5, 66.0],
            "wind_speed_10m": [5.0, 8.0, 12.5, 15.0],
            "precipitation_probability": [10.0, 20.0, 55.0, 80.0],
            "precipitation": [0.0, 0.05, 0.10, 0.25],
        ]]
        let c = NWSForecastFetcher.parseOpenMeteoConditions(json, hourUTC: 2)
        XCTAssertEqual(c?.temperatureF ?? 0, 64.5, accuracy: 1e-9)
        XCTAssertEqual(c?.windMph ?? 0, 12.5, accuracy: 1e-9)
        XCTAssertEqual(c?.popPercent ?? 0, 55.0, accuracy: 1e-9)
        // QPF sums the coming hours from the index (0.10 + 0.25).
        XCTAssertEqual(c?.qpfInches ?? 0, 0.35, accuracy: 1e-9)
        // Hour past the series clamps to the last entry.
        XCTAssertEqual(NWSForecastFetcher.parseOpenMeteoConditions(json, hourUTC: 30)?
            .temperatureF ?? 0, 66.0, accuracy: 1e-9)
        // Nulls in a series (NSNull) skip that field, never crash.
        var gappy = json
        gappy["hourly"] = [
            "temperature_2m": [60.0, NSNull(), 64.5],
            "wind_speed_10m": [NSNull(), NSNull(), NSNull()],
        ] as [String: Any]
        let g = NWSForecastFetcher.parseOpenMeteoConditions(gappy, hourUTC: 1)
        XCTAssertNil(g?.temperatureF)
        XCTAssertNil(g?.windMph)
        // No usable signal at all → nil, so the chain moves on.
        XCTAssertNil(NWSForecastFetcher.parseOpenMeteoConditions([:], hourUTC: 0))
    }

    // MARK: IEM storm-based-warning parsing (NWS alert redundancy)

    func testBackupWarningParsing() {
        let features: [[String: Any]] = [
            ["properties": ["ps": "Tornado Warning", "phenomena": "TO",
                            "significance": "W", "wfo": "MKX", "eventid": 41,
                            "product_id": "202608261555-KMKX-A",
                            "expire_utc": "2026-08-26T20:00:00Z"],
             "geometry": ["type": "Polygon",
                          "coordinates": [[[-89.5, 42.9], [-89.5, 43.1], [-89.3, 43.1],
                                           [-89.3, 42.9], [-89.5, 42.9]]]]],
            // No geometry → unplaceable → dropped (polygon feed contract).
            ["properties": ["ps": "Flood Warning", "phenomena": "FL",
                            "significance": "W"], "geometry": NSNull()],
        ]
        let parsed = BackupWarningsCache.parse(features)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].event, "Tornado Warning")
        XCTAssertEqual(parsed[0].id, "202608261555-KMKX-A")
        XCTAssertEqual(parsed[0].severityScore, 0.95, accuracy: 1e-9)
        XCTAssertNotNil(parsed[0].expires)
        XCTAssertEqual(parsed[0].polygon?.count, 5)
        // The event wording matches NWS, so the realized-primary classifier
        // treats backup warnings exactly like the primary feed's.
        XCTAssertEqual(RiskEquations.alertFamily("Tornado Warning") != nil, true)
        // Severity table: tornado above the rest of the class, marine lowest.
        XCTAssertEqual(BackupWarningsCache.severity(phenomena: "SV"), 0.88)
        XCTAssertEqual(BackupWarningsCache.severity(phenomena: "MA"), 0.72)
    }

    // MARK: tier-anchored hotel nightly (no blank prices)

    func testEstimatedNightlyCoversEveryTier() {
        for tier in [nil, 1, 2, 3, 4, 5, 9] {
            XCTAssertGreaterThan(RatingsAndCost.estimatedNightly(costTier: tier), 0)
        }
        // Monotone with tier — a nicer class never estimates cheaper.
        let ordered = [1, 2, 3, 4, 5].map { RatingsAndCost.estimatedNightly(costTier: $0) }
        XCTAssertEqual(ordered, ordered.sorted())
    }
}
