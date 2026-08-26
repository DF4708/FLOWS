// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// The address-search upgrades: pasted-coordinate parsing, the recents
/// store's ranking/merge, and the suggestion blend that pins local rows
/// above Apple's completions.
final class AddressSearchTests: XCTestCase {

    // MARK: coordinate input

    func testCoordinateParseAcceptedForms() {
        func check(_ text: String, _ lat: Double, _ lon: Double,
                   file: StaticString = #filePath, line: UInt = #line) {
            let c = CoordinateInput.parse(text)
            XCTAssertNotNil(c, "failed to parse \(text)", file: file, line: line)
            XCTAssertEqual(c?.latitude ?? 0, lat, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(c?.longitude ?? 0, lon, accuracy: 1e-9, file: file, line: line)
        }
        check("43.0731, -89.4012", 43.0731, -89.4012)
        check("43.0731 -89.4012", 43.0731, -89.4012)
        check("43.0731;-89.4012", 43.0731, -89.4012)
        check("43.0731N 89.4012W", 43.0731, -89.4012)
        check("N 43.0731 W 89.4012", 43.0731, -89.4012)
        check("43.0731 N 89.4012 W", 43.0731, -89.4012)
        check("89.4012W 43.0731N", 43.0731, -89.4012)   // labeled: order-free
        check("33.8688S 151.2093E", -33.8688, 151.2093) // southern hemisphere
        check("  43.0731 , -89.4012  ", 43.0731, -89.4012)
    }

    func testCoordinateParseRejections() {
        for text in [
            "Madison", "Madison WI", "43.0731",              // not two numbers
            "1600 Pennsylvania Ave",                          // street number + words
            "43.0731, -89.4012, 10",                          // three numbers
            "91.0, -89.4",                                    // latitude out of range
            "43.0, -181.0",                                   // longitude out of range
            "43.0731N 89.4012N",                              // two latitudes
            "N43W 89.4",                                      // mangled hemispheres
            "", "  ",
        ] {
            XCTAssertNil(CoordinateInput.parse(text), "should reject: \(text)")
        }
    }

    func testCoordinateDisplayNameIsPlain() {
        let name = CoordinateInput.displayName(
            CLLocationCoordinate2D(latitude: 43.0731, longitude: -89.4012))
        XCTAssertEqual(name, "Map point 43.0731, -89.4012")
    }

    // MARK: recents ranking + merge

    private func entry(_ name: String, uses: Int, daysAgo: Double,
                       now: Date) -> RecentDestinations.Entry {
        RecentDestinations.Entry(
            name: name, latitude: 43, longitude: -89,
            lastUsed: now.addingTimeInterval(-daysAgo * 86_400), uses: uses)
    }

    func testRecentsMergeDedupesAndAccumulates() {
        let now = Date()
        let list = [entry("Milwaukee", uses: 2, daysAgo: 3, now: now)]
        let merged = RecentDestinations.merged(
            list, adding: entry("MILWAUKEE", uses: 1, daysAgo: 0, now: now), now: now)
        XCTAssertEqual(merged.count, 1)               // case-insensitive dedupe
        XCTAssertEqual(merged[0].uses, 3)             // visits accumulate
        XCTAssertEqual(merged[0].name, "MILWAUKEE")   // newest spelling wins
    }

    func testRecentsRankingFavorsFrequencyWithRecencyDecay() {
        let now = Date()
        // Daily coffee run (8 uses, 2 days old) outranks yesterday's one-off.
        let coffee = entry("Coffee", uses: 8, daysAgo: 2, now: now)
        let oneOff = entry("One-off", uses: 1, daysAgo: 1, now: now)
        XCTAssertGreaterThan(RecentDestinations.score(coffee, now: now),
                             RecentDestinations.score(oneOff, now: now))
        // But a month-old habit decays below a fresh place.
        let stale = entry("Stale", uses: 4, daysAgo: 45, now: now)
        XCTAssertLessThan(RecentDestinations.score(stale, now: now),
                          RecentDestinations.score(oneOff, now: now))
        // Merge caps the list at the lowest-ranked entries.
        var list: [RecentDestinations.Entry] = []
        for i in 0..<30 {
            list = RecentDestinations.merged(
                list, adding: entry("Place \(i)", uses: 1, daysAgo: 0, now: now), now: now)
        }
        XCTAssertEqual(list.count, RecentDestinations.cap)
    }

    // MARK: suggestion blend

    func testBlendPinsLocalRowsAndDedupes() {
        typealias S = DestinationSearch.Suggestion
        let pinned = [
            S(title: "Map point 43.0731, -89.4012", subtitle: "Exact map point",
              kind: .coordinate),
            S(title: "Milwaukee", subtitle: "Recent", kind: .recent),
        ]
        let completions = [
            S(title: "Milwaukee", subtitle: "WI, United States"),   // dup of a recent
            S(title: "Milwaukee Ave", subtitle: "Chicago, IL"),
            S(title: "Milwaukee Tool", subtitle: "Brookfield, WI"),
        ]
        let out = DestinationSearch.blend(pinned: pinned, completions: completions, cap: 4)
        XCTAssertEqual(out.map(\.title), [
            "Map point 43.0731, -89.4012", "Milwaukee", "Milwaukee Ave", "Milwaukee Tool",
        ])
        XCTAssertEqual(out[1].kind, .recent)   // the pinned row won the dup
        // Cap trims completions, never the pinned local rows.
        let capped = DestinationSearch.blend(pinned: pinned, completions: completions, cap: 3)
        XCTAssertEqual(capped.count, 3)
        XCTAssertEqual(capped[0].kind, .coordinate)
        XCTAssertEqual(capped[1].kind, .recent)
    }
}
