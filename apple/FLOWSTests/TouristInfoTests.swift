// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// The tourist stop card's pure facts: entry-fee notes, plain-words kinds,
/// and the Monday-first hours index.
final class TouristInfoTests: XCTestCase {
    private let table = TouristInfo.FeeTable(notes: [
        "yellowstone": "$35 for each car",
        "glacier": "$35 for each car",
        "glacier bay": "Free to enter",
        "great smoky mountains": "Free to enter (parking tags cost extra)",
    ])

    func testNationalParkFeeFromTable() {
        XCTAssertEqual(TouristInfo.feeNote(name: "Yellowstone National Park", table: table),
                       "$35 for each car")
        XCTAssertEqual(TouristInfo.feeNote(name: "Great Smoky Mountains National Park",
                                           table: table),
                       "Free to enter (parking tags cost extra)")
    }

    // Longest key wins: Glacier Bay must never read as Glacier.
    func testLongestParkKeyWins() {
        XCTAssertEqual(TouristInfo.feeNote(name: "Glacier Bay National Park", table: table),
                       "Free to enter")
        XCTAssertEqual(TouristInfo.feeNote(name: "Glacier National Park", table: table),
                       "$35 for each car")
    }

    func testUnknownParkGetsHonestDefault() {
        XCTAssertEqual(TouristInfo.feeNote(name: "Imaginary National Park", table: table),
                       "Free at most park spots. Big parks often charge for each car.")
    }

    func testOtherNPSSitesAndEverythingElse() {
        XCTAssertEqual(TouristInfo.feeNote(name: "Devils Tower National Monument",
                                           table: table),
                       "Free at most sites like this. Some charge a small fee.")
        XCTAssertEqual(TouristInfo.feeNote(name: "City Science Museum", table: table),
                       "Prices vary — check before you go.")
        XCTAssertEqual(TouristInfo.feeNote(name: nil, table: table),
                       "Prices vary — check before you go.")
    }

    // Diacritics and long dashes fold away so NPS names match table keys.
    func testNameNormalization() {
        XCTAssertEqual(TouristInfo.normalized("Haleakalā"), "haleakala")
        XCTAssertEqual(TouristInfo.normalized("Wrangell–St. Elias"), "wrangell-st. elias")
    }

    func testPlainKind() {
        XCTAssertEqual(TouristInfo.plainKind(name: "Anything",
                                             categoryRaw: "MKPOICategoryNationalPark"),
                       "National park")
        XCTAssertEqual(TouristInfo.plainKind(name: "Anything",
                                             categoryRaw: "MKPOICategoryAmusementPark"),
                       "Theme park")
        XCTAssertEqual(TouristInfo.plainKind(name: "Field Museum", categoryRaw: nil),
                       "Museum")
        XCTAssertEqual(TouristInfo.plainKind(name: "Ruby Falls", categoryRaw: nil),
                       "Waterfall")
        XCTAssertEqual(TouristInfo.plainKind(name: "Mystery Spot", categoryRaw: nil),
                       "Place worth a stop")
    }

    // Calendar weekday (1 = Sunday … 7 = Saturday) → Monday-first index.
    func testMondayFirstIndex() {
        XCTAssertEqual(TouristInfo.mondayFirstIndex(weekday: 2), 0)   // Monday
        XCTAssertEqual(TouristInfo.mondayFirstIndex(weekday: 1), 6)   // Sunday
        XCTAssertEqual(TouristInfo.mondayFirstIndex(weekday: 7), 5)   // Saturday
        XCTAssertEqual(TouristInfo.mondayFirstIndex(weekday: 4), 2)   // Wednesday
    }
}
