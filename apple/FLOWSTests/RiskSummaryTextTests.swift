// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// A ZIP's risk summary reaches the route card and the map's tap card in
/// plain words: the shipped bundle's "Seasonal baseline: elevated convective
/// risk (climatology)" never does.
final class RiskSummaryTextTests: XCTestCase {

    /// Words no driver should have to read on a summary line.
    private let jargon = ["baseline", "climatology", "convective", "elevated", "qpf"]

    func testEveryOldLineTheShippedBundleCarriesReadsPlainly() {
        let cases = [
            ("Seasonal baseline: elevated convective risk (climatology)",
             "Storms are common here in some seasons."),
            ("Seasonal baseline: elevated heat risk (climatology)",
             "Very hot days are common here in some seasons."),
            ("Historical baseline: elevated convective risk (20-yr storm climatology)",
             "Storms have been common here over the last 20 years."),
            ("Historical baseline: elevated flood risk (20-yr storm climatology)",
             "Flooding has been common here over the last 20 years."),
            ("Historical baseline: elevated heat risk (20-yr storm climatology)",
             "Very hot days have been common here over the last 20 years."),
            ("Historical baseline: elevated wind risk (20-yr storm climatology)",
             "Strong winds have been common here over the last 20 years."),
            ("Historical baseline: elevated fire risk (20-yr storm climatology)",
             "Wildfires have been common here over the last 20 years."),
            ("Historical baseline: elevated air risk (20-yr storm climatology)",
             "Very dry weather has been common here over the last 20 years."),
        ]
        for (old, plain) in cases {
            XCTAssertEqual(RiskSummaryText.plain(old), plain, old)
        }
    }

    func testOtherTextIsShownAsWrittenAndNoTextIsNoLine() {
        XCTAssertEqual(RiskSummaryText.plain("windy"), "windy")
        XCTAssertEqual(RiskSummaryText.plain("Flooding is likely near the river."),
                       "Flooding is likely near the river.")
        XCTAssertNil(RiskSummaryText.plain(""))
        // Reading a plain line again changes nothing.
        let once = RiskSummaryText.plain("Seasonal baseline: elevated wind risk (climatology)")
        XCTAssertEqual(once.flatMap(RiskSummaryText.plain), once)
    }

    func testAnOldLineWithAnUnreadableFamilyStillNeverShows() throws {
        for old in ["Seasonal baseline: elevated risk (climatology)",
                    "Historical baseline: something else"] {
            let line = try XCTUnwrap(RiskSummaryText.plain(old), old).lowercased()
            for word in jargon {
                XCTAssertFalse(line.contains(word), "\(old) → \(line)")
            }
        }
    }

    /// The field's own readers: the nearest-ZIP lookup behind the route card
    /// and the tap card, and the entries.
    func testTheFieldReadsItsSummariesInPlainWords() throws {
        let madison = CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40)
        let milwaukee = CLLocationCoordinate2D(latitude: 43.04, longitude: -87.91)
        let fargo = CLLocationCoordinate2D(latitude: 46.88, longitude: -96.79)
        let entries = [
            RiskFieldService.ZipEntry(
                zip: "53703", centroid: madison, scores: [0.4],
                summary: "Seasonal baseline: elevated convective risk (climatology)", ring: nil),
            RiskFieldService.ZipEntry(
                zip: "53202", centroid: milwaukee, scores: [0.5],
                summary: "Historical baseline: elevated flood risk (20-yr storm climatology)",
                ring: nil),
            RiskFieldService.ZipEntry(
                zip: "58102", centroid: fargo, scores: [0.1], summary: nil, ring: nil),
        ]
        let field = try XCTUnwrap(RiskField(generated: "2026-07-04T11:39:45Z",
                                            families: ["convective"], entries: entries))
        let near = { (c: CLLocationCoordinate2D) in field.nearest(c).flatMap(field.summary(at:)) }
        XCTAssertEqual(near(madison), "Storms are common here in some seasons.")
        XCTAssertEqual(near(milwaukee), "Flooding has been common here over the last 20 years.")
        XCTAssertNil(near(fargo), "no summary stays no summary")
        for entry in field.entries {
            let line = entry.summary?.lowercased() ?? ""
            for word in jargon {
                XCTAssertFalse(line.contains(word), "\(entry.zip): \(line)")
            }
        }
    }
}
