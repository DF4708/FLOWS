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

/// How a chain's name is written and the colours of its sign, for the stop
/// list's brand tile: the chain's initials in its own colours, never its
/// logo — logos are trademarked artwork FLOWS has no licence to copy, and a
/// coloured monogram tells the brands apart at a glance just the same. A
/// stop of no known brand gets a plain placeholder tile.
enum BrandMark {
    struct RGB: Equatable {
        let r: Double, g: Double, b: Double
        init(_ hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }
    }

    struct Mark: Equatable {
        /// The brand as it writes its own name ("BP", "CITGO", "Kwik Trip").
        let name: String
        /// What the tile says.
        let initials: String
        let background: RGB
        let ink: RGB
        /// What a gallon usually costs at this brand against the others, 1
        /// (warehouse clubs, discounters) to 5 — for a fuel row with no live
        /// price to compare. nil for a brand that sells no fuel.
        let fuelTier: Int?
    }

    /// Known chains, matched at the start of a name, longest key first.
    private static let marks: [(key: String, mark: Mark)] = [
        ("bp", Mark(name: "BP", initials: "BP", background: RGB(0x009B3A), ink: RGB(0xFFE600), fuelTier: 4)),
        ("shell", Mark(name: "Shell", initials: "S", background: RGB(0xFBCE07), ink: RGB(0xDD1D21), fuelTier: 4)),
        ("exxon", Mark(name: "Exxon", initials: "E", background: RGB(0xED1B2D), ink: RGB(0xFFFFFF), fuelTier: 4)),
        ("mobil", Mark(name: "Mobil", initials: "M", background: RGB(0x0A4595), ink: RGB(0xFFFFFF), fuelTier: 4)),
        ("chevron", Mark(name: "Chevron", initials: "C", background: RGB(0x0054A4), ink: RGB(0xFFFFFF), fuelTier: 4)),
        ("texaco", Mark(name: "Texaco", initials: "T", background: RGB(0xE51937), ink: RGB(0xFFFFFF), fuelTier: 4)),
        ("marathon", Mark(name: "Marathon", initials: "M", background: RGB(0xE31837), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("speedway", Mark(name: "Speedway", initials: "S", background: RGB(0xE21E26), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("citgo", Mark(name: "CITGO", initials: "C", background: RGB(0xD71920), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("sunoco", Mark(name: "Sunoco", initials: "S", background: RGB(0x003DA5), ink: RGB(0xFFD100), fuelTier: 3)),
        ("phillips 66", Mark(name: "Phillips 66", initials: "66", background: RGB(0xED1C24), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("76", Mark(name: "76", initials: "76", background: RGB(0xF58220), ink: RGB(0x003DA5), fuelTier: 4)),
        ("conoco", Mark(name: "Conoco", initials: "C", background: RGB(0xE31B23), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("valero", Mark(name: "Valero", initials: "V", background: RGB(0x0072BC), ink: RGB(0xFFD200), fuelTier: 3)),
        ("arco", Mark(name: "ARCO", initials: "A", background: RGB(0x0060A9), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("sinclair", Mark(name: "Sinclair", initials: "S", background: RGB(0x00843D), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("casey's", Mark(name: "Casey's", initials: "C", background: RGB(0xD71921), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("caseys", Mark(name: "Casey's", initials: "C", background: RGB(0xD71921), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("kwik trip", Mark(name: "Kwik Trip", initials: "KT", background: RGB(0xD2202F), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("kwik star", Mark(name: "Kwik Star", initials: "KS", background: RGB(0xD2202F), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("holiday", Mark(name: "Holiday", initials: "H", background: RGB(0x00529B), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("quiktrip", Mark(name: "QuikTrip", initials: "QT", background: RGB(0xDA291C), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("wawa", Mark(name: "Wawa", initials: "W", background: RGB(0xDA291C), ink: RGB(0xFFD100), fuelTier: 2)),
        ("sheetz", Mark(name: "Sheetz", initials: "S", background: RGB(0xDA291C), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("circle k", Mark(name: "Circle K", initials: "K", background: RGB(0xEE2E24), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("kum & go", Mark(name: "Kum & Go", initials: "KG", background: RGB(0x00843D), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("love's", Mark(name: "Love's", initials: "L", background: RGB(0xE31837), ink: RGB(0xFFD200), fuelTier: 3)),
        ("loves", Mark(name: "Love's", initials: "L", background: RGB(0xE31837), ink: RGB(0xFFD200), fuelTier: 3)),
        ("pilot", Mark(name: "Pilot", initials: "P", background: RGB(0xE21836), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("flying j", Mark(name: "Flying J", initials: "FJ", background: RGB(0xE21836), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("travelcenters of america", Mark(name: "TA", initials: "TA", background: RGB(0x003B71), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("ta ", Mark(name: "TA", initials: "TA", background: RGB(0x003B71), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("petro", Mark(name: "Petro", initials: "P", background: RGB(0x00467F), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("murphy usa", Mark(name: "Murphy USA", initials: "M", background: RGB(0x003DA5), ink: RGB(0xFFFFFF), fuelTier: 1)),
        ("costco", Mark(name: "Costco", initials: "C", background: RGB(0xE31837), ink: RGB(0xFFFFFF), fuelTier: 1)),
        ("sam's club", Mark(name: "Sam's Club", initials: "S", background: RGB(0x0067A0), ink: RGB(0xFFFFFF), fuelTier: 1)),
        ("bj's", Mark(name: "BJ's", initials: "BJ", background: RGB(0xD71920), ink: RGB(0xFFFFFF), fuelTier: 1)),
        ("kroger", Mark(name: "Kroger", initials: "K", background: RGB(0x0F4C98), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("meijer", Mark(name: "Meijer", initials: "M", background: RGB(0xE31837), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("starbucks", Mark(name: "Starbucks", initials: "S", background: RGB(0x00704A), ink: RGB(0xFFFFFF), fuelTier: nil)),
        ("mcdonald's", Mark(name: "McDonald's", initials: "M", background: RGB(0xDA291C), ink: RGB(0xFFC72C), fuelTier: nil)),
        ("mcdonalds", Mark(name: "McDonald's", initials: "M", background: RGB(0xDA291C), ink: RGB(0xFFC72C), fuelTier: nil)),
        ("dunkin", Mark(name: "Dunkin'", initials: "D", background: RGB(0xFF671F), ink: RGB(0xFFFFFF), fuelTier: nil)),
        ("subway", Mark(name: "Subway", initials: "S", background: RGB(0x008C15), ink: RGB(0xFFC20E), fuelTier: nil)),
        ("taco bell", Mark(name: "Taco Bell", initials: "TB", background: RGB(0x702082), ink: RGB(0xFFFFFF), fuelTier: nil)),
        ("wendy's", Mark(name: "Wendy's", initials: "W", background: RGB(0xE2203D), ink: RGB(0xFFFFFF), fuelTier: nil)),
        ("burger king", Mark(name: "Burger King", initials: "BK", background: RGB(0xD62300), ink: RGB(0xF5EBDC), fuelTier: nil)),
        ("culver's", Mark(name: "Culver's", initials: "C", background: RGB(0x005696), ink: RGB(0xFFFFFF), fuelTier: nil)),
        ("chick-fil-a", Mark(name: "Chick-fil-A", initials: "C", background: RGB(0xE51636), ink: RGB(0xFFFFFF), fuelTier: nil)),
    ].sorted { $0.key.count > $1.key.count }

    /// The known chain a place's name starts with, nil for any other.
    static func mark(for name: String) -> Mark? { match(name)?.mark }

    /// The name as the chain writes it: the map gives some in lower case
    /// ("bp") — the brand's own spelling replaces that leading word.
    static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let (key, mark) = match(trimmed) else { return name }
        return mark.name + trimmed.dropFirst(key.count)
    }

    /// The chain and the key that named it: the key must start the name as
    /// a whole word — "bp" names "bp", "bp Gas" and "BP #2231", never
    /// "Bpm Cafe".
    private static func match(_ name: String) -> (key: String, mark: Mark)? {
        let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        for entry in marks {
            let key = entry.key.trimmingCharacters(in: .whitespaces)
            guard lower.hasPrefix(key) else { continue }
            let rest = lower.dropFirst(key.count)
            if rest.isEmpty || !(rest.first?.isLetter ?? false) { return (key, entry.mark) }
        }
        return nil
    }

    /// Price tiers 1–5 by where each live price sits between the cheapest
    /// and dearest in the list — nil for a row without a live price, and for
    /// all of them when the prices don't differ.
    static func comparativeTiers(_ prices: [Double?]) -> [Int?] {
        let known = prices.compactMap { $0 }
        guard let lo = known.min(), let hi = known.max(), hi - lo >= 0.01 else {
            return prices.map { _ in nil }
        }
        return prices.map { p in p.map { 1 + Int((($0 - lo) / (hi - lo) * 4).rounded()) } }
    }
}
