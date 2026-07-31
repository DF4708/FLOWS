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
/// MATCHING is case-insensitive on standalone word runs, longest match wins.
/// Precision over recall: the brand token must appear as its own word(s) —
/// "Hilton Garden Inn" hits "hilton garden inn" (not the shorter "hilton");
/// "Hiltonia Cafe" hits nothing. Names that legitimately contain a brand
/// word ("Hilton Head Diner") still match — no name-only rule can separate
/// those, and a wrong "$" tier on a rare collision costs less than dropping
/// every real chain hit.
enum BrandKnowledge {

    // MARK: - Word matching

    /// Lowercased word runs. Apostrophes vanish so "McDonald's" and
    /// "McDonalds" are the same word; every other non-alphanumeric splits
    /// ("Chick-fil-A" → chick·fil·a).
    private static func words(_ s: String) -> [String] {
        s.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// True when the brand's word run appears contiguously — as standalone
    /// words — inside the name's word run.
    private static func contains(_ brand: [String], in nameWords: [String]) -> Bool {
        guard !brand.isEmpty, brand.count <= nameWords.count else { return false }
        for start in 0...(nameWords.count - brand.count)
        where Array(nameWords[start..<start + brand.count]) == brand {
            return true
        }
        return false
    }

    private struct Brand {
        let words: [String]
        let tier: Int
        let site: String?
        init(_ token: String, _ tier: Int, site: String? = nil) {
            self.words = BrandKnowledge.words(token)
            self.tier = tier
            self.site = site
        }
    }

    /// Longest matching brand: more words beat fewer, then more letters —
    /// "Hampton Inn by Hilton" resolves to Hampton Inn, not Hilton.
    private static func best(_ nameWords: [String], in table: [Brand]) -> Brand? {
        table.filter { contains($0.words, in: nameWords) }
            .max { a, b in
                (a.words.count, a.words.joined().count)
                    < (b.words.count, b.words.joined().count)
            }
    }

    // MARK: - Brand tables

    /// Tiers follow RatingsAndCost's income-anchored "$" scale: 1 fits a
    /// minimum-wage budget … 5 is top-percentile territory.
    private static let dining: [Brand] = [
        // Fast food — a full meal on a minimum-wage budget.
        Brand("Wendy's", 1), Brand("McDonald's", 1), Brand("Subway", 1),
        Brand("Taco Bell", 1), Brand("Burger King", 1), Brand("KFC", 1),
        Brand("Chick-fil-A", 1), Brand("Waffle House", 1), Brand("Arby's", 1),
        Brand("Dairy Queen", 1), Brand("Popeyes", 1), Brand("Dunkin", 1),
        Brand("Sonic Drive-In", 1), Brand("Hardee's", 1), Brand("Carl's Jr", 1),
        // Casual sit-down.
        Brand("Chili's", 2), Brand("Applebee's", 2), Brand("Olive Garden", 2),
        Brand("Cracker Barrel", 2), Brand("Denny's", 2), Brand("IHOP", 2),
        Brand("Panera Bread", 2), Brand("Panera", 2), Brand("Starbucks", 2),
        // Steakhouse-and-up occasion dining.
        Brand("Outback Steakhouse", 3), Brand("Outback", 3),
        Brand("Texas Roadhouse", 3), Brand("LongHorn Steakhouse", 3),
        Brand("Red Lobster", 3),
    ]

    private static let stores: [Brand] = [
        Brand("Walmart", 1), Brand("Dollar General", 1), Brand("Aldi", 1),
        Brand("Dollar Tree", 1), Brand("Family Dollar", 1), Brand("Lidl", 1),
        Brand("Target", 2), Brand("Kroger", 2), Brand("Publix", 2),
        Brand("Walgreens", 2), Brand("CVS", 2), Brand("Safeway", 2),
        Brand("Meijer", 2),
        Brand("Whole Foods", 3), Brand("Best Buy", 3),
    ]

    /// Hotel chains carry the brand's own booking site — attached to a
    /// result only when MapKit supplies no URL of its own.
    private static let hotels: [Brand] = [
        Brand("Motel 6", 1, site: "https://www.motel6.com"),
        Brand("Super 8", 1, site: "https://www.wyndhamhotels.com/super-8"),
        Brand("Econo Lodge", 1, site: "https://www.choicehotels.com/econo-lodge"),
        Brand("Red Roof Inn", 1, site: "https://www.redroof.com"),
        Brand("Days Inn", 2, site: "https://www.wyndhamhotels.com/days-inn"),
        Brand("La Quinta", 2, site: "https://www.wyndhamhotels.com/laquinta"),
        Brand("Comfort Inn", 2, site: "https://www.choicehotels.com/comfort-inn"),
        Brand("Quality Inn", 2, site: "https://www.choicehotels.com/quality-inn"),
        Brand("Best Western", 2, site: "https://www.bestwestern.com"),
        Brand("Holiday Inn", 3, site: "https://www.ihg.com/holidayinn"),
        Brand("Hampton Inn", 3, site: "https://www.hilton.com/en/hampton"),
        Brand("Hilton Garden Inn", 3, site: "https://www.hilton.com"),
        Brand("Embassy Suites", 3, site: "https://www.hilton.com"),
        Brand("DoubleTree", 3, site: "https://www.hilton.com"),
        Brand("Courtyard by Marriott", 3, site: "https://www.marriott.com/courtyard"),
        Brand("Courtyard Marriott", 3, site: "https://www.marriott.com/courtyard"),
        Brand("Fairfield Inn", 2, site: "https://www.marriott.com/fairfield"),
        Brand("Hilton", 4, site: "https://www.hilton.com"),
        Brand("Marriott", 4, site: "https://www.marriott.com"),
        Brand("Hyatt", 4, site: "https://www.hyatt.com"),
        Brand("Sheraton", 4, site: "https://www.marriott.com/sheraton"),
        Brand("Westin", 4, site: "https://www.marriott.com/westin"),
        Brand("Ritz-Carlton", 5, site: "https://www.ritzcarlton.com"),
        Brand("Four Seasons", 5, site: "https://www.fourseasons.com"),
        Brand("Waldorf Astoria", 5, site: "https://www.waldorfastoria.com"),
        Brand("Waldorf", 5, site: "https://www.waldorfastoria.com"),
    ]

    private static let allBrands: [Brand] = dining + stores + hotels

    // MARK: - Public lookups

    /// Cost tier 1…5 ("$"…"$$$$$") for a known national brand; nil when the
    /// name matches no brand as a standalone word run.
    static func costTier(name: String) -> Int? {
        best(words(name), in: allBrands)?.tier
    }

    /// The brand's own site — hotel chains only, for the row's link slot.
    static func website(name: String) -> URL? {
        best(words(name), in: hotels)?.site.flatMap { URL(string: $0) }
    }

    // MARK: - Gym showers

    /// Chains where member showers are the brand standard (true), or where
    /// the format famously omits them (false).
    private static let gymShowers: [(words: [String], showers: Bool)] = [
        (words("Planet Fitness"), true), (words("LA Fitness"), true),
        (words("Gold's Gym"), true), (words("Anytime Fitness"), true),
        (words("Crunch Fitness"), true), (words("Crunch"), true),
        (words("24 Hour Fitness"), true), (words("YMCA"), true),
        (words("YWCA"), true), (words("Life Time"), true),
        (words("Equinox"), true),
        (words("Curves"), false),
    ]

    /// true = the chain provides showers; false = it does not; nil = brand
    /// unknown (say nothing rather than guess).
    static func gymHasShowers(name: String) -> Bool? {
        let nw = words(name)
        return gymShowers.filter { contains($0.words, in: nw) }
            .max { a, b in
                (a.words.count, a.words.joined().count)
                    < (b.words.count, b.words.joined().count)
            }?.showers
    }

    // MARK: - Parking fee

    /// Commercial operators that only run paid facilities.
    private static let paidParkingOperators: [[String]] = [
        words("LAZ"), words("LAZ Parking"), words("SP+"), words("SP Plus"),
        words("Impark"), words("Diamond Parking"), words("ABM Parking"),
        words("Ace Parking"), words("Premium Parking"),
    ]

    /// true = costs money, false = free, nil = the name says neither.
    /// An explicit "free" wins over structure words — a lot named "Free
    /// Parking Garage" is advertising the price.
    static func parkingFee(name: String) -> Bool? {
        let nw = words(name)
        if paidParkingOperators.contains(where: { contains($0, in: nw) }) {
            return true
        }
        if nw.contains("free") || contains(words("rest area"), in: nw)
            || contains(words("park and ride"), in: nw)
            || contains(words("park ride"), in: nw)
            || contains(words("welcome center"), in: nw) {
            return false
        }
        if name.contains("$") || nw.contains("paid") || nw.contains("garage")
            || nw.contains("valet") || nw.contains("pay")
            || nw.contains("metered") {
            return true
        }
        return nil
    }

    // MARK: - Shelters

    /// Shelter type in plain words — from the result name first, the search
    /// query second. Anything else is the general case: a public building
    /// pressed into service is an "Emergency shelter".
    static func shelterType(name: String, query: String = "") -> String {
        func classify(_ ws: [String]) -> String? {
            if ws.contains("tornado") || ws.contains("storm") { return "Storm shelter" }
            if ws.contains("flood") || ws.contains("tsunami")
                || contains(words("high ground"), in: ws) { return "Flood shelter" }
            if ws.contains("cooling") { return "Cooling center" }
            if ws.contains("warming") { return "Warming center" }
            return nil
        }
        return classify(words(name)) ?? classify(words(query)) ?? "Emergency shelter"
    }

    /// Private listings the shelter queries surface but a driver under a
    /// warning cannot use: animal/pet shelters and service offices.
    static func isShelterNoise(name: String) -> Bool {
        let ws = words(name)
        for noise in ["animal", "pet", "pets", "humane", "spca", "wildlife",
                      "kennel", "veterinary", "homeless", "thrift"]
        where ws.contains(noise) {
            return true
        }
        return false
    }
}
