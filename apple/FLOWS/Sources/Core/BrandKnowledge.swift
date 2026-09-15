// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Built-in facts about national chains — cost tiers, brand sites, gym
/// showers, paid-parking operators — plus name-based shelter typing. Fills
/// POI rows when no live ratings provider (Google Places / Yelp) key is
/// configured: a brand fact beats an empty "$" column, and the table works
/// offline. A provider answer always wins; this only fills gaps.
///
/// The tables and the matching live in rust/flows-core (places_text.rs),
/// called through rust/flows-bridge. Matching is case-insensitive on
/// standalone word runs, longest match wins: "Hilton Garden Inn" hits
/// "hilton garden inn" (not the shorter "hilton"); "Hiltonia Cafe" hits
/// nothing. Swift's own text rules — a character is a grapheme cluster, and
/// two spellings compare as one when they are canonically equivalent — are
/// reproduced in Rust and pinned to the original by
/// rust/flows-bridge/tests/fixtures/swift_places_text_oracle.tsv.
enum BrandKnowledge {

    /// The spoken-request matcher (Siri add-a-stop): true when the asked-for
    /// words appear contiguously, as standalone words, inside the place's
    /// name — "Starbucks" in "Starbucks Coffee", never "Star" in "Starbucks".
    static func askedName(_ asked: String, matches name: String) -> Bool {
        flows_places_text_asked_name_matches(asked, name)
    }

    /// Cost tier 1…5 ("$"…"$$$$$") for a known national brand; nil when the
    /// name matches no brand as a standalone word run.
    static func costTier(name: String) -> Int? {
        let tier = flows_places_text_cost_tier(name)
        return tier == 0 ? nil : Int(tier)
    }

    /// The brand's own site — hotel chains only, for the row's link slot.
    static func website(name: String) -> URL? {
        let site = flows_places_text_website(name).text
        return site.isEmpty ? nil : URL(string: site)
    }

    /// true = the chain provides showers; false = it does not; nil = brand
    /// unknown (say nothing rather than guess).
    static func gymHasShowers(name: String) -> Bool? {
        tri(flows_places_text_gym_has_showers(name))
    }

    /// true = costs money, false = free, nil = the name says neither.
    /// An explicit "free" wins over structure words — a lot named "Free
    /// Parking Garage" is advertising the price.
    static func parkingFee(name: String) -> Bool? {
        tri(flows_places_text_parking_fee(name))
    }

    /// Shelter type in plain words — from the result name first, the search
    /// query second. Anything else is the general case: a public building
    /// pressed into service is an "Emergency shelter".
    static func shelterType(name: String, query: String = "") -> String {
        let code = Int(flows_places_text_shelter_type(name, query))
        return shelterTypeNames.indices.contains(code) ? shelterTypeNames[code] : shelterTypeNames[4]
    }

    /// Private listings the shelter queries surface but a driver under a
    /// warning cannot use: animal/pet shelters and service offices.
    static func isShelterNoise(name: String) -> Bool {
        flows_places_text_is_shelter_noise(name)
    }

    /// The bridge's three-valued answer: -1 unknown, 0 no, 1 yes.
    private static func tri(_ v: Int32) -> Bool? { v < 0 ? nil : v == 1 }

    /// Shelter types by the bridge's code, the general case last.
    private static let shelterTypeNames = [
        "Storm shelter", "Flood shelter", "Cooling center", "Warming center", "Emergency shelter",
    ]
}

extension RustStringRef {
    /// The string, with the empty case answered here. An empty Rust string
    /// crosses with no storage behind it, and Foundation's decoder answers nil
    /// for that rather than "" — so every facade reads Rust text through this.
    var text: String { len() == 0 ? "" : as_str().toString() }
}
