// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// BrandKnowledge — the offline chain-facts table that prefills POI rows
/// when no live ratings provider is keyed: "$" tiers, hotel sites, gym
/// showers, parking fees, and shelter typing.
final class PoiAndCostTests: XCTestCase {

    // Seed tiers across the three tables, case-insensitive, with store
    // numbers and punctuation variants along for the ride.
    func testBrandCostTiers() {
        XCTAssertEqual(BrandKnowledge.costTier(name: "McDonald's"), 1)
        XCTAssertEqual(BrandKnowledge.costTier(name: "McDonalds #4302"), 1)
        XCTAssertEqual(BrandKnowledge.costTier(name: "WENDY'S"), 1)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Chick-Fil-A"), 1)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Waffle House"), 1)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Olive Garden Italian Restaurant"), 2)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Cracker Barrel Old Country Store"), 2)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Texas Roadhouse"), 3)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Outback Steakhouse"), 3)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Walmart Supercenter"), 1)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Dollar General"), 1)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Target"), 2)
        XCTAssertEqual(BrandKnowledge.costTier(name: "CVS Pharmacy"), 2)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Whole Foods Market"), 3)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Motel 6 Nashville"), 1)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Days Inn by Wyndham"), 2)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Holiday Inn Express & Suites"), 3)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Hilton Nashville Downtown"), 4)
        XCTAssertEqual(BrandKnowledge.costTier(name: "The Ritz-Carlton, Atlanta"), 5)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Four Seasons Hotel"), 5)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Waldorf Astoria Chicago"), 5)
        XCTAssertNil(BrandKnowledge.costTier(name: "Mel's Roadside Diner"))
        XCTAssertNil(BrandKnowledge.costTier(name: ""))
    }

    // Precision guards: a brand token counts only as a standalone word run —
    // a longer word that merely starts with the brand never matches — and
    // the LONGEST matching brand wins over any shorter one inside it.
    func testBrandMatchingWordBoundary() {
        XCTAssertNil(BrandKnowledge.costTier(name: "Hiltonia Cafe"))
        XCTAssertNil(BrandKnowledge.costTier(name: "Grand Hiltons Banquet Hall"))
        XCTAssertNil(BrandKnowledge.costTier(name: "Chisholm Trail BBQ"))
        XCTAssertNil(BrandKnowledge.costTier(name: "Targeted Staffing Inc"))
        XCTAssertNil(BrandKnowledge.costTier(name: "Kfcx Logistics"))
        // Longest match wins: the Hampton Inn tier, not the Hilton tier.
        XCTAssertEqual(BrandKnowledge.costTier(name: "Hampton Inn & Suites by Hilton"), 3)
        XCTAssertEqual(BrandKnowledge.costTier(name: "Hilton Garden Inn Memphis"), 3)
    }

    // Hotel chains carry their brand site; non-hotels and non-brands do not.
    func testHotelWebsites() {
        XCTAssertEqual(BrandKnowledge.website(name: "Hilton Nashville Downtown")?.host,
                       "www.hilton.com")
        XCTAssertEqual(BrandKnowledge.website(name: "Motel 6 Amarillo")?.host,
                       "www.motel6.com")
        XCTAssertEqual(BrandKnowledge.website(name: "Waldorf Astoria Chicago")?.host,
                       "www.waldorfastoria.com")
        XCTAssertEqual(BrandKnowledge.website(name: "Hampton Inn by Hilton")?.host,
                       "www.hilton.com")
        XCTAssertNil(BrandKnowledge.website(name: "Hiltonia Cafe"))
        XCTAssertNil(BrandKnowledge.website(name: "McDonald's"))
        XCTAssertNil(BrandKnowledge.website(name: "Joe's Motor Lodge"))
    }

    // Gym shower table: the national chains where showers are the brand
    // standard say yes; a known no-shower format says no; unknown says nil.
    func testGymShowerTable() {
        for gym in ["Planet Fitness", "LA Fitness", "Gold's Gym Downtown",
                    "Anytime Fitness", "Crunch Fitness", "24 Hour Fitness",
                    "YMCA of Middle Tennessee"] {
            XCTAssertEqual(BrandKnowledge.gymHasShowers(name: gym), true, gym)
        }
        XCTAssertEqual(BrandKnowledge.gymHasShowers(name: "Curves"), false)
        XCTAssertNil(BrandKnowledge.gymHasShowers(name: "Bob's Barbell Club"))
        // Word boundary: a brand fragment inside a longer word is no match.
        XCTAssertNil(BrandKnowledge.gymHasShowers(name: "Crunchy Granola Co"))
    }

    // Parking fee: paid operators and structure words say paid; explicit
    // "free" (and rest areas) says free — and beats structure words; a bare
    // street lot says unknown.
    func testParkingFeeHeuristic() {
        XCTAssertEqual(BrandKnowledge.parkingFee(name: "LAZ Parking"), true)
        XCTAssertEqual(BrandKnowledge.parkingFee(name: "SP+ Parking"), true)
        XCTAssertEqual(BrandKnowledge.parkingFee(name: "Impark Lot 22"), true)
        XCTAssertEqual(BrandKnowledge.parkingFee(name: "Main Street Garage"), true)
        XCTAssertEqual(BrandKnowledge.parkingFee(name: "$5 Event Parking"), true)
        XCTAssertEqual(BrandKnowledge.parkingFee(name: "Paid Public Lot"), true)
        XCTAssertEqual(BrandKnowledge.parkingFee(name: "Free City Lot"), false)
        XCTAssertEqual(BrandKnowledge.parkingFee(name: "Free Parking Garage"), false)
        XCTAssertEqual(BrandKnowledge.parkingFee(name: "I-40 Rest Area"), false)
        XCTAssertEqual(BrandKnowledge.parkingFee(name: "Park & Ride North"), false)
        XCTAssertNil(BrandKnowledge.parkingFee(name: "Elm Street Lot"))
        // Word boundary: "Freeport" is not "free".
        XCTAssertNil(BrandKnowledge.parkingFee(name: "Freeport Municipal Lot"))
    }

    // Shelter typing: the name decides first, the query second, and the
    // general case falls back to "Emergency shelter".
    func testShelterTypeInference() {
        XCTAssertEqual(BrandKnowledge.shelterType(name: "Smithville Tornado Shelter"),
                       "Storm shelter")
        XCTAssertEqual(BrandKnowledge.shelterType(name: "County Storm Shelter #3"),
                       "Storm shelter")
        XCTAssertEqual(BrandKnowledge.shelterType(name: "High Ground Evacuation Site"),
                       "Flood shelter")
        XCTAssertEqual(BrandKnowledge.shelterType(name: "Cooling Center at Main Library"),
                       "Cooling center")
        XCTAssertEqual(BrandKnowledge.shelterType(name: "Downtown Warming Center"),
                       "Warming center")
        XCTAssertEqual(BrandKnowledge.shelterType(name: "Lincoln High School Gymnasium"),
                       "Emergency shelter")
        // Query fallback: a plain-named civic center under a tornado search.
        XCTAssertEqual(BrandKnowledge.shelterType(name: "Community Center",
                                                  query: "tornado shelter storm shelter"),
                       "Storm shelter")
        XCTAssertEqual(BrandKnowledge.shelterType(name: "Civic Center",
                                                  query: "emergency shelter"),
                       "Emergency shelter")
    }

    // Shelter noise filter: private/animal/service listings are not public
    // refuge; civic buildings pass even when a word merely contains a
    // noise fragment ("Petersburg").
    func testShelterNoiseFilter() {
        XCTAssertTrue(BrandKnowledge.isShelterNoise(name: "Happy Paws Animal Shelter"))
        XCTAssertTrue(BrandKnowledge.isShelterNoise(name: "County Humane Society"))
        XCTAssertTrue(BrandKnowledge.isShelterNoise(name: "SPCA Adoption Center"))
        XCTAssertTrue(BrandKnowledge.isShelterNoise(name: "Homeless Services Office"))
        XCTAssertFalse(BrandKnowledge.isShelterNoise(name: "Petersburg Civic Center"))
        XCTAssertFalse(BrandKnowledge.isShelterNoise(name: "Community Storm Shelter"))
        XCTAssertFalse(BrandKnowledge.isShelterNoise(name: "Red Cross Emergency Shelter"))
    }
}
