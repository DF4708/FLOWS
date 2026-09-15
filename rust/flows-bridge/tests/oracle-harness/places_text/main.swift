import CoreLocation
import Foundation
// Frozen oracle: every output below comes from the ORIGINAL Swift of BrandKnowledge,
// RatingsAndCost, FuelPrices, LaneData and EnforcementCameras (plus the Swift runtime's
// own text primitives they stand on), before it is replaced by calls into Rust.
// Doubles are IEEE-754 bit patterns in hex; text is "t:" + UTF-8 with every byte outside
// 0x20...0x7E, and the backslash, written as \xx; nil is "-"; lists are "L<n>:" + items.

// ---- stubs: names the original files mention that the oracle never exercises ----
// The one fetch the oracle drives is AAA's state page. It answers from `aaaPages`, so
// AAAFuelPrices.refresh runs its real parse and cache code with no network.
enum ThrottledNet {
    static func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        let s = url.absoluteString
        guard let r = s.range(of: "state="), let page = aaaPageFor(String(s[r.upperBound...])) else {
            throw URLError(.fileDoesNotExist)
        }
        return (Data(page.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}
enum CacheEviction { static func dropHalf<K, V>(_ cache: inout [K: V]) {} }
/// FuelPrices only switches on these three cases.
enum FuelType { case gas, diesel, electric }
/// EnforcementCameras.imminent is not part of this oracle (it waits for the geo port).
enum POIRanking { static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double { .nan } }

// ---- encoding ----
func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func ht(_ s: String) -> String {
    var o = "t:"
    for b in s.utf8 {
        if b >= 0x20, b <= 0x7E, b != 0x5C { o.unicodeScalars.append(Unicode.Scalar(b)) }
        else { o += "\\" + String(format: "%02x", b) }
    }
    return o
}
func hto(_ s: String?) -> String { s.map(ht) ?? "-" }
func lst(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: ",") }
func tri(_ b: Bool?) -> String { b.map { $0 ? "1" : "0" } ?? "-" }
func u32(_ v: UInt32) -> String { String(v, radix: 16) }
var out = ""
func emit(_ f: String...) { out += f.joined(separator: "\t") + "\n" }

struct SM { var s: UInt64
  mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
  mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) } }
var rng = SM(s: 0x504C414345535458)   // "PLACESTX"
func pick<T>(_ a: [T]) -> T { a[rng.below(a.count)] }
func chance(_ n: Int) -> Bool { rng.below(n) == 0 }

emit("#", "base", "a007de042d12e736fdd86398e1ea54ca31aadc1f")

// =====================================================================================
// 1. The Swift text primitives the original code stands on, per scalar.
// =====================================================================================
let allScalars: [Unicode.Scalar] = (UInt32(0)...0x10FFFF).compactMap { (0xD800...0xDFFF).contains($0) ? nil : Unicode.Scalar($0) }
func ranges(_ name: String, _ f: (Unicode.Scalar) -> String) {
    var start: UInt32 = 0, last: UInt32 = 0
    var cur: String? = nil
    for s in allScalars {
        let k = f(s)
        if let c = cur, k == c, s.value == last + 1 { last = s.value; continue }
        if let c = cur, c != "" { emit(name, u32(start), u32(last), c) }
        cur = k; start = s.value; last = s.value
    }
    if let c = cur, c != "" { emit(name, u32(start), u32(last), c) }
}
// Character.isLetter || isNumber (the word-run test), Character.isNumber, CharacterSet.whitespaces.
ranges("u-word") { s in let c = Character(s); return (c.isLetter || c.isNumber) ? "1" : "" }
ranges("u-num") { s in Character(s).isNumber ? "1" : "" }
ranges("u-ws") { s in CharacterSet.whitespaces.contains(s) ? "1" : "" }
for s in allScalars {
    let l = s.properties.lowercaseMapping.unicodeScalars.map { $0.value }
    if l != [s.value] { emit("u-lower", u32(s.value), l.map(u32).joined(separator: ",")) }
    let up = s.properties.uppercaseMapping.unicodeScalars.map { $0.value }
    if up != [s.value] { emit("u-upper", u32(s.value), up.map(u32).joined(separator: ",")) }
}
// Non-ASCII scalars canonically equivalent to ASCII (String == treats them as equal).
for s in allScalars where s.value >= 0x80 {
    let d = String(s).decomposedStringWithCanonicalMapping.unicodeScalars
    if d.allSatisfy({ $0.isASCII }) { emit("u-canon", u32(s.value), d.map { u32($0.value) }.joined(separator: ",")) }
}
// Grapheme probes: bit i is whether probe i, with the scalar spliced in, is ONE Character.
let probes: [(String, String)] = [("", "\u{301}"), ("a", ""), ("", "a"), ("\u{1F600}", "\u{200D}\u{1F600}"),
  ("\u{1F600}\u{200D}", ""), ("", "\u{1F1E6}"), ("", "\u{1100}"), ("\u{1100}", ""), ("", "\u{1161}"), ("\u{AC00}", ""),
  ("", "\u{11A8}"), ("\u{915}\u{94D}", ""), ("\u{915}", "\u{915}"), ("\u{915}", "\u{94D}\u{915}"), ("\u{915}\u{94D}", "\u{915}"),
  ("\u{D}", ""), ("", "\u{A}")]
ranges("u-gcb") { s in
    let c = String(s)
    return probes.map { p in (p.0 + c + p.1).count == 1 ? "1" : "0" }.joined()
}
// Random scalar sequences over every grapheme class: the size of each Character, in scalars.
let segPool: [UInt32] = [0x61, 0x24, 0x2E, 0x33, 0x20, 0x27, 0x2019, 0x212A, 0x37E, 0x7C, 0x3B, 0x65,
  0x0, 0xAD, 0x200B, 0x2028, 0xFEFF, 0xE0000, 0xD, 0xA,
  0x301, 0x308, 0xFE0F, 0x1F3FB, 0xE0020, 0x93C, 0x941, 0x20E3, 0x200C, 0x200D,
  0x903, 0x93E, 0x93F, 0x600, 0xD4E, 0x110BD,
  0x1100, 0x1161, 0x11A8, 0xAC00, 0xAC01, 0xD7A3, 0x1F1E6, 0x1F1FA, 0x1F1F8,
  0x1F600, 0x2764, 0x2139, 0xA9, 0x1F468, 0x915, 0x937, 0x995, 0x924, 0x94D, 0x9CD, 0xBCD, 0xE3A, 0xB95]
for i in 0..<2500 {
    let n = 1 + rng.below(i < 1200 ? 5 : 10)
    var s = ""
    var sc: [UInt32] = []
    for _ in 0..<n { let v = pick(segPool); sc.append(v); s.unicodeScalars.append(Unicode.Scalar(v)!) }
    let fwd = s.map { $0.unicodeScalars.count }
    let bwd = Array(s.reversed().map { $0.unicodeScalars.count }.reversed())
    precondition(fwd == bwd, "forward and backward Character iteration disagree")
    emit("u-seg", sc.map(u32).joined(separator: ","), fwd.map(String.init).joined(separator: ","))
}

// =====================================================================================
// Shared adversarial text.
// =====================================================================================
let marks = ["\u{301}", "\u{308}", "\u{20DD}", "\u{FE0F}", "\u{200D}", "\u{200C}", "\u{93C}", "\u{94D}", "\u{1F3FB}", "\u{E0020}", "\u{903}"]
let junk = ["\u{0}", "\u{AD}", "\u{200B}", "\u{2028}", "\u{FEFF}", "\u{600}", "\u{D4E}", "\u{1F1FA}\u{1F1F8}", "\u{1F1FA}",
  "\u{1F600}", "\u{1F468}\u{200D}\u{1F469}", "\u{2139}", "\u{24C2}", "\u{1F170}", "\u{AC00}", "\u{1100}\u{1161}\u{11A8}",
  "\u{915}\u{94D}\u{937}", "\u{E9}", "e\u{301}", "\u{130}", "\u{131}", "\u{212A}", "\u{37E}", "\u{1FEF}", "\u{FF28}", "\u{FF10}",
  "\u{663}", "\u{BD}", "\u{2155}", "\u{4E00}", "\u{F882}", "\u{3A3}", "\u{DF}", "\u{1E9E}", "\u{FB01}", "\r\n", "\r", "\n", "\t",
  "\u{A0}", "\u{3000}", "\u{1680}", "\u{85}", "\u{202F}", "\u{2007}", "\u{1F}", "\u{7F}", "$", "'", "\u{2019}", "|", ";"]
func decorate(_ w: String) -> String {
    switch rng.below(14) {
    case 0: return w.uppercased()
    case 1: return w.lowercased()
    case 2: return w + pick(marks)
    case 3: return pick(junk) + w
    case 4: return w + pick(junk)
    case 5:
        guard let f = w.first else { return w }
        return String(f) + pick(marks) + String(w.dropFirst())
    case 6: return w.replacingOccurrences(of: "k", with: "\u{212A}").replacingOccurrences(of: "K", with: "\u{212A}")
    case 7: return w.replacingOccurrences(of: "i", with: "\u{130}")
    case 8: return w.replacingOccurrences(of: "'", with: pick(["\u{2019}", "\u{2018}", "\u{2BC}", "`", "\u{B4}", "'\u{301}", "\u{2019}\u{301}", "", "''"]))
    case 9:
        let cut = rng.below(w.count + 1)
        return String(w.prefix(cut)) + pick(junk) + String(w.dropFirst(cut))
    case 10: return w.replacingOccurrences(of: " ", with: pick(["\u{A0}", "\t", "  ", "", "-", "\u{2011}", "\u{200B}"]))
    default: return w
    }
}

// =====================================================================================
// 2. BrandKnowledge
// =====================================================================================
let brandTokens = ["Wendy's", "McDonald's", "Subway", "Taco Bell", "Burger King", "KFC", "Chick-fil-A", "Waffle House",
  "Arby's", "Dairy Queen", "Popeyes", "Dunkin", "Sonic Drive-In", "Hardee's", "Carl's Jr", "Chili's", "Applebee's",
  "Olive Garden", "Cracker Barrel", "Denny's", "IHOP", "Panera Bread", "Panera", "Starbucks", "Outback Steakhouse", "Outback",
  "Texas Roadhouse", "LongHorn Steakhouse", "Red Lobster", "Walmart", "Dollar General", "Aldi", "Dollar Tree", "Family Dollar",
  "Lidl", "Target", "Kroger", "Publix", "Walgreens", "CVS", "Safeway", "Meijer", "Whole Foods", "Best Buy", "Motel 6", "Super 8",
  "Econo Lodge", "Red Roof Inn", "Days Inn", "La Quinta", "Comfort Inn", "Quality Inn", "Best Western", "Holiday Inn",
  "Hampton Inn", "Hilton Garden Inn", "Embassy Suites", "DoubleTree", "Courtyard by Marriott", "Courtyard Marriott",
  "Fairfield Inn", "Hilton", "Marriott", "Hyatt", "Sheraton", "Westin", "Ritz-Carlton", "Four Seasons", "Waldorf Astoria",
  "Waldorf", "Planet Fitness", "LA Fitness", "Gold's Gym", "Anytime Fitness", "Crunch Fitness", "Crunch", "24 Hour Fitness",
  "YMCA", "YWCA", "Life Time", "Equinox", "Curves", "LAZ", "LAZ Parking", "SP+", "SP Plus", "Impark", "Diamond Parking",
  "ABM Parking", "Ace Parking", "Premium Parking"]
let keyWords = ["free", "rest area", "park and ride", "park ride", "welcome center", "paid", "garage", "valet", "pay",
  "metered", "tornado", "storm", "flood", "tsunami", "high ground", "cooling", "warming", "animal", "pet", "pets", "humane",
  "spca", "wildlife", "kennel", "veterinary", "homeless", "thrift", "$5", "$", "Free", "PAID", "Garage"]
let noiseWords = ["The", "Inn", "Hotel", "Suites", "&", "by", "Express", "Downtown", "#4302", "Nashville", "Diner", "Cafe",
  "Hiltonia", "Hiltons", "Targeted", "Kfcx", "Parking", "Lot", "Center", "Shelter", "Emergency", "Club", "Gym", "Fitness",
  "Co", "Station", "Travel", "Stop", "Mc", "Donald", "s", "Chick", "fil", "A", "24", "Hour", "6", "8", "Plus", "SP",
  "Crunchy", "Granola", "Freeport", "Payless", "Caf\u{E9}", "Cafe\u{301}", "Montr\u{E9}al", "Stra\u{DF}e", "\u{130}stanbul",
  "\u{65E5}\u{672C}", "\u{D55C}\u{AD6D}", "\u{928}\u{92E}\u{938}\u{94D}\u{924}\u{947}", "\u{645}\u{631}\u{62D}\u{628}\u{627}",
  "\u{39F}\u{394}\u{39F}\u{3A3}", "\u{41C}\u{43E}\u{441}\u{43A}\u{432}\u{430}", "\u{1F354}", "\u{1F1FA}\u{1F1F8}",
  "\u{FF11}\u{FF12}\u{FF13}", "\u{BD}", "\u{216B}", "\u{663}", "Pet\u{301}", "Storm\u{20DD}", "Hilton\u{0}", "Motel\u{A0}6"]
let seps = [" ", "  ", " ", " ", "-", "'", "\u{2019}", "\u{2018}", "\u{2BC}", ",", ", ", ".", "/", " & ", "+", "\t", "\n",
  "\r\n", "\u{0}", "\u{A0}", "\u{200B}", "\u{3000}", "_", " (", ") ", "!", "#", "|", ";", "\u{37E}", "\u{2014}", "\u{2010}",
  "\u{FF0D}", "", "\u{AD}", "\u{200D}", "\u{301}", "\u{600}", "$"]
func namePart() -> String {
    switch rng.below(10) {
    case 0...3: return pick(brandTokens)
    case 4...5: return pick(keyWords)
    case 6...8: return pick(noiseWords)
    default: return pick(junk)
    }
}
func randName() -> String {
    var s = chance(8) ? pick(junk) : ""
    for i in 0..<(1 + rng.below(5)) {
        if i > 0 { s += pick(seps) }
        let p = namePart()
        s += chance(3) ? decorate(p) : p
    }
    if chance(8) { s += pick(junk) }
    return s
}
var bkNames = ["McDonald's", "McDonalds #4302", "WENDY'S", "Chick-Fil-A", "Waffle House", "Olive Garden Italian Restaurant",
  "Cracker Barrel Old Country Store", "Texas Roadhouse", "Outback Steakhouse", "Walmart Supercenter", "Dollar General",
  "Target", "CVS Pharmacy", "Whole Foods Market", "Motel 6 Nashville", "Days Inn by Wyndham", "Holiday Inn Express & Suites",
  "Hilton Nashville Downtown", "The Ritz-Carlton, Atlanta", "Four Seasons Hotel", "Waldorf Astoria Chicago",
  "Mel's Roadside Diner", "", "Hiltonia Cafe", "Grand Hiltons Banquet Hall", "Chisholm Trail BBQ", "Targeted Staffing Inc",
  "Kfcx Logistics", "Hampton Inn & Suites by Hilton", "Hilton Garden Inn Memphis", "Motel 6 Amarillo", "Hampton Inn by Hilton",
  "Joe's Motor Lodge", "Planet Fitness", "LA Fitness", "Gold's Gym", "Anytime Fitness", "Crunch Fitness", "24 Hour Fitness",
  "YMCA", "Life Time", "Equinox", "Curves", "Bob's Barbell Club", "Crunchy Granola Co", "LAZ Parking", "SP+ Parking",
  "Impark Lot 22", "Main Street Garage", "$5 Event Parking", "Paid Public Lot", "Free City Lot", "Free Parking Garage",
  "I-40 Rest Area", "Park & Ride North", "Elm Street Lot", "Freeport Municipal Lot", "Happy Paws Animal Shelter",
  "County Humane Society", "SPCA Adoption Center", "Homeless Services Office", "Petersburg Civic Center",
  "Community Storm Shelter", "Red Cross Emergency Shelter",
  // exact ties on (word count, letter count): the first in table order must win
  "Motel 6 Super 8", "Super 8 Motel 6", "Aldi IHOP", "IHOP Aldi", "CVS KFC", "Target Subway", "Hilton Westin", "Westin Hilton",
  "Hampton Inn Holiday Inn", "Holiday Inn Hampton Inn", "Four Seasons Best Western", "Best Western Four Seasons",
  "Crunch Curves", "Curves Crunch", "YMCA YWCA", "Crunch Fitness Curves", "Hyatt Aldi", "Kroger Hilton Publix",
  "Comfort Inn Econo Lodge Quality Inn", "Courtyard by Marriott Hilton Garden Inn", "Waldorf Astoria Ritz-Carlton",
  "Life Time Equinox", "Gold's Gym Planet Fitness", "Free LAZ", "LAZ Free", "Rest Area Garage", "Welcome Center Valet",
  "Park Ride", "park and ride", "Pay", "Payless", "Metered", "Valet", "$", "\u{FF04}5 lot", "$\u{301}5 lot", "\u{600}$ lot",
  "McDonald\u{2019}s", "McDonald\u{2018}s", "McDonald\u{2BC}s", "McDonald`s", "McDonald'\u{301}s", "M\u{301}cDonald's",
  "Hilton\u{301}", "H\u{301}ilton", "\u{600}Hilton", "Hilton\u{200D}", "Hilton\u{FE0F}", "HILTON", "hilton", "Hi\u{130}ton",
  "\u{212A}FC", "\u{FF2B}\u{FF26}\u{FF23}", "Chick\u{2011}fil\u{2011}A", "Chick\u{AD}fil\u{AD}A", "Motel\u{A0}6",
  "Motel\u{200B}6", "Motel6", "Super\u{0}8", "Ritz\u{2014}Carlton", "Waldorf\u{1F600}Astoria", "Waldorf\u{200D}\u{1F600}Astoria",
  "\u{1F1FA}\u{1F1F8}Walmart\u{1F1FA}\u{1F1F8}", "Walmart\r\nSupercenter", "\u{915}\u{94D}Walmart", "Walmart\u{94D}\u{915}",
  "Tornado", "tornado\u{301}", "High Ground", "High\u{A0}Ground", "HighGround", "Cooling\u{0}Center", "\u{D55C}\u{AD6D} Pet",
  "Pet\u{301} Shelter", "pets", "PETS", "Veterinary Clinic", "Thrift Store", "Wildlife Rescue", "Kennel Club"]
for _ in 0..<700 { bkNames.append(randName()) }
for name in bkNames {
    emit("bk", ht(name), BrandKnowledge.costTier(name: name).map(String.init) ?? "-",
         hto(BrandKnowledge.website(name: name)?.absoluteString), tri(BrandKnowledge.gymHasShowers(name: name)),
         tri(BrandKnowledge.parkingFee(name: name)), BrandKnowledge.isShelterNoise(name: name) ? "1" : "0")
}
let shelterQueries = ["", "storm shelter", "Tornado Shelter", "flood", "FLOOD SHELTER", "cooling center", "warming center",
  "high ground", "High\u{A0}Ground", "emergency shelter", "tsunami evacuation", "storm\u{301}", "stormy", "heat relief",
  "public shelter", "Warming\u{0}Center", "\u{600}cooling"]
var shelterNames = ["Smithville Tornado Shelter", "County Storm Shelter #3", "High Ground Evacuation Site",
  "Cooling Center at Main Library", "Downtown Warming Center", "Lincoln High School Gymnasium", "Community Center",
  "Civic Center", "Flood Tornado Cooling", "Warming Cooling", "Cooling Warming", "Tsunami", "Storm\u{301} Shelter"]
for _ in 0..<500 { shelterNames.append(randName()) }
for name in shelterNames {
    let q = chance(2) ? pick(shelterQueries) : randName()
    emit("bk-shelter", ht(name), ht(q), ht(BrandKnowledge.shelterType(name: name, query: q)))
}
var askedPairs: [(String, String)] = [("Starbucks", "Starbucks Coffee"), ("Buc-ee's", "Buc-ee's #34"),
  ("Yellowstone", "Yellowstone National Park"), ("McDonald's", "McDonalds"), ("Star", "Starbucks"),
  ("Starbucks", "Joe's Coffee"), ("", "Starbucks"), ("Starbucks", ""), ("", ""), ("Taco Bell", "yes, let's go to Taco Bell"),
  ("fast food", "fast food please"), ("Mexican", "actually, Mexican"), ("Stra\u{DF}e", "STRASSE"),
  ("\u{39F}\u{394}\u{39F}\u{3A3}", "\u{3BF}\u{3B4}\u{3BF}\u{3C2}"), ("\u{130}stanbul Cafe", "i\u{307}stanbul cafe"),
  ("\u{FF21}", "a"), ("Kwik Trip", "\u{212A}wik Trip"), ("one two", "one\u{0}two"), ("one two", "one\u{200D}two"),
  ("new york", "New\u{A0}York"), ("taco", "taco\u{301}"), ("taco\u{301}", "taco\u{301} bell")]
for _ in 0..<900 {
    let name = randName()
    let asked: String
    switch rng.below(6) {
    case 0: asked = pick(brandTokens)
    case 1: asked = decorate(pick(brandTokens))
    case 2: asked = randName()
    case 3: asked = String(name.prefix(rng.below(name.count + 1)))
    case 4: asked = pick(noiseWords)
    default: asked = pick(["", " ", "'", pick(junk)])
    }
    askedPairs.append((asked, name))
}
for (asked, name) in askedPairs {
    emit("bk-asked", ht(asked), ht(name), BrandKnowledge.askedName(asked, matches: name) ? "1" : "0")
}

// =====================================================================================
// 3. RatingsAndCost
// =====================================================================================
var coords: [(Double, Double)] = [(43.07, -89.40), (43.65, -79.38), (25.67, -100.31), (49.28, -123.12), (25.76, -80.19),
  (29.76, -95.37), (29.42, -98.49), (32.22, -110.97), (32.72, -117.16), (31.76, -106.49), (25.9, -97.1)]
func around(_ x: Double) -> [Double] { [x.nextDown, x, x.nextUp] }
for la in [25.9, 32.5, 31.3, 49.0, 44.8, 43.4, 31.75, 0.0, -0.0, 90.0].flatMap(around) {
    for lo in [-120.0, -117.0, -115.0, -110.0, -100.0, -90.0, -85.0, -82.0, -79.0, -60.0, -50.0] { coords.append((la, lo)) }
}
for lo in [-118.0, -114.7, -106.4, -97.1, -86.0, -83.6, -81.8, -76.3, -52.0, 0.0, -0.0].flatMap(around) {
    for la in [20.0, 25.9, 30.0, 31.3, 32.0, 32.5, 40.0, 43.5, 45.0, 49.0, 50.0] { coords.append((la, lo)) }
}
for _ in 0..<150 {
    let lo = -106.4 + rng.unit() * 9.3
    let b = 31.75 - 0.63 * (lo + 106.4)
    for la in around(b) { coords.append((la, lo)) }
}
for s in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .leastNonzeroMagnitude] {
    coords.append((s, -100)); coords.append((30, s)); coords.append((s, s)); coords.append((50, s)); coords.append((s, -70))
}
for _ in 0..<200 { coords.append((rng.unit() * 70 + 10, rng.unit() * -120 - 50)) }
for (la, lo) in coords {
    emit("rc-country", hx(la), hx(lo), RatingsAndCost.Country.forCoordinate(latitude: la, longitude: lo).rawValue)
}
for c in RatingsAndCost.Country.allCases { emit("rc-bp", c.rawValue, lst(c.checkBreakpoints.map(hx))) }
var checks: [Double] = [.nan, .infinity, -.infinity, 0, -0.0, -1, 1e300, .leastNonzeroMagnitude, 9, 25, 45, 100, 200, 300, 2000]
for c in RatingsAndCost.Country.allCases { for e in c.checkBreakpoints { checks += around(e) } }
for _ in 0..<60 { checks.append(rng.unit() * 2000 - 100) }
for c in RatingsAndCost.Country.allCases {
    for x in checks { emit("rc-tier", hx(x), c.rawValue, String(RatingsAndCost.costTier(averageCheck: x, country: c))) }
}
for x in checks { emit("rc-tier-usd", hx(x), String(RatingsAndCost.costTier(averageCheckUSD: x))) }
let nightlyTiers: [Int?] = [nil, .min, -1, 0, 1, 2, 3, 4, 5, 6, 7, 100, .max, Int(Int32.max), Int(Int32.max) + 1,
  Int(Int32.min) - 1, 4294967297, 4294967298]
for t in nightlyTiers { emit("rc-nightly", t.map(String.init) ?? "-", hx(RatingsAndCost.estimatedNightly(costTier: t))) }
var yelpPrices = ["", "$", "$$", "$$$", "$$$$", "$$$$$", String(repeating: "$", count: 40), "\u{FF04}",
  "\u{FF04}\u{FF04}\u{FF04}\u{FF04}", "$\u{301}", "$\u{301}$$$$", "a$b$", "US$", "\u{20AC}\u{20AC}\u{20AC}", "\u{600}$$$$",
  "$\u{0}$", "$\r\n$$$", "$$$$\u{200D}", "\u{1F4B2}", "\u{1F4B2}\u{1F4B2}", " $ $ $ $ ", "$\u{FE0F}$$$", "\u{1F1FA}$$$$",
  "$$$$\u{AD}", "$$$\u{94D}$", "$$$$\u{903}"]
for _ in 0..<60 { yelpPrices.append((0..<rng.below(7)).map { _ in pick(["$", "$", "$", pick(marks), pick(junk)]) }.joined()) }
let yelpRatings: [Double?] = [nil, .nan, 0, -0.0, 4.4, (4.5).nextDown, 4.5, (4.5).nextUp, 5, .infinity, -.infinity, -4.5]
for p in yelpPrices {
    for r in yelpRatings { emit("rc-yelp", ht(p), r.map(hx) ?? "-", String(RatingsAndCost.costTier(yelpPrice: p, rating: r))) }
}

// ShowerAvailability: brand defaults, the resolution ladder, and the location table.
let showerBrands = ["love's", "loves travel", "pilot", "flying j", "ta travel", "travelcenters of america", "petro stopping",
  "sapp bros", "kwik trip", "road ranger", "ambest", "roady", "buc-ee", "bucee", "casey's", "caseys", "speedway", "circle k",
  "7-eleven", "kum & go", "quiktrip", "wawa", "sheetz"]
var shNames: [String?] = [nil, "", "Love's Travel Stop #312", "Pilot Travel Center", "Flying J #605", "TA Travel Center",
  "Buc-ee's", "Casey's General Store", "Kwik Trip #900", "Joe's Gas", "LOVE'S", "Love\u{2019}s", "Loves Travel Stops",
  "Lovesick Diner", "Loveland", "Vista Travel", "Pilot\u{301}", "Pilo\u{301}t", "Sapp Bros.", "Kum & Go", "Kum &amp; Go",
  "7-Eleven", "7\u{2011}Eleven", "Circle K", "Circle \u{212A}", "CIRCLE K", "Circle\u{A0}K", "QuikTrip", "Wawa", "Sheetz",
  "Speedway", "Road Ranger", "AmBest", "Roady's", "TravelCenters of America", "Petro Stopping Center", "Petro",
  "\u{600}pilot", "pilot\u{0}", "p\u{0}ilot", "Bucee's", "BUC-EE'S", "Casey\u{2019}s", "Love's\u{301}", "pilot\u{94D}\u{915}",
  "\u{1F1FA}pilot", "Flying\u{A0}J", "Flying J\u{301}", "ROADY\u{130}", "Kwik\u{200D} Trip"]
for b in showerBrands { shNames.append(b); shNames.append(decorate(b)); shNames.append(decorate(b.uppercased())) }
for _ in 0..<150 { shNames.append(chance(2) ? decorate(pick(showerBrands)) + pick(seps) + randName() : randName()) }
for n in shNames { emit("sh-name", hto(n), ht(ShowerAvailability.forStop(named: n).rawValue)) }

precondition(UserDefaults.standard.object(forKey: "flows.showersDisproved") == nil,
             "this process's defaults must not already hold driver shower reports")
let here = (lat: 41.111, lon: -95.222)
let hereKey = ShowerAvailability.locationKey(lat: here.lat, lon: here.lon)
let ladderTags = ["no", "yes", "No", "no ", "", "limited", "no\u{301}", "\u{FF4E}\u{FF4F}", "NO", "n\u{0}o"]
typealias ShowerEntry = ShowerAvailability.LocationTable.Entry
for _ in 0..<700 {
    let name = pick(shNames)
    let loc = rng.below(4)          // 0 lat and lon, 1 lat only, 2 lon only, 3 neither
    let disproved = chance(2)
    let tableState = rng.below(8)   // 0 no table, 1 empty table, 2 no entry nearby, 3 entry without a tag, 4+ tagged entry
    let tag = pick(ladderTags)
    UserDefaults.standard.register(defaults: ["flows.showersDisproved": disproved ? [hereKey] : [String]()])
    let table: ShowerAvailability.LocationTable?
    switch tableState {
    case 0: table = nil
    case 1: table = .init(entries: [])
    case 2: table = .init(entries: [ShowerEntry(lat: here.lat + 1, lon: here.lon, brand: "x", shower: "no")])
    case 3: table = .init(entries: [ShowerEntry(lat: here.lat, lon: here.lon, brand: "x", shower: nil)])
    default: table = .init(entries: [ShowerEntry(lat: here.lat, lon: here.lon, brand: "x", shower: tag)])
    }
    let r = ShowerAvailability.forStop(named: name, lat: loc == 0 || loc == 1 ? here.lat : nil,
                                       lon: loc == 0 || loc == 2 ? here.lon : nil, table: table)
    emit("sh-ladder", hto(name), String(loc), disproved ? "1" : "0", tableState >= 4 ? ht(tag) : "-", ht(r.rawValue))
}
UserDefaults.standard.register(defaults: ["flows.showersDisproved": [String]()])

let tableBases: [(Double, Double, Int)] = [(41.0, -95.0, 0), (-33.5, 151.2, 1), (0.0, 0.0, 6), (49.99, -123.0, 40),
  (25.005, -80.005, 150), (-0.005, 0.005, 60), (89.99, -179.99, 30), (12.345, -45.678, 80)]
for (tid, base) in tableBases.enumerated() {
    var pts: [(Double, Double)] = []
    if tid == 2 { pts = [(0.005, 0.0), (0.0, 0.005), (-0.005, 0.0), (0.0, -0.005), (0.005, 0.0), (0.0, 0.0)] }
    while pts.count < base.2 {
        switch rng.below(5) {
        case 0: pts.append((base.0 + Double(rng.below(9) - 4) * 0.01, base.1 + Double(rng.below(9) - 4) * 0.01))
        case 1: if let p = pts.last { pts.append(p) }
        case 2:
            let la = base.0 + Double(rng.below(7) - 3) * 0.01, lo = base.1 + Double(rng.below(7) - 3) * 0.01
            pts.append((chance(2) ? la.nextUp : la.nextDown, chance(2) ? lo.nextUp : lo.nextDown))
        default: pts.append((base.0 + (rng.unit() - 0.5) * 0.06, base.1 + (rng.unit() - 0.5) * 0.06))
        }
    }
    let table = ShowerAvailability.LocationTable(entries: pts.enumerated().map {
        ShowerEntry(lat: $0.element.0, lon: $0.element.1, brand: String($0.offset), shower: nil) })
    emit("sh-table", String(tid), lst(pts.flatMap { [hx($0.0), hx($0.1)] }))
    var queries: [(Double, Double)] = [(base.0, base.1), (base.0 + 1, base.1), (-base.0, -base.1)]
    for p in pts.prefix(25) {
        queries.append(p)
        for d in [0.01, -0.01, (0.01).nextDown, -(0.01).nextDown, 0.0099999, 0.005] {
            queries.append((p.0 + d, p.1)); queries.append((p.0, p.1 + d)); queries.append((p.0 + d, p.1 - d))
        }
    }
    for _ in 0..<40 { queries.append((base.0 + (rng.unit() - 0.5) * 0.08, base.1 + (rng.unit() - 0.5) * 0.08)) }
    for (la, lo) in queries {
        emit("sh-entry", String(tid), hx(la), hx(lo), table.entry(nearLat: la, lon: lo)?.brand ?? "-")
    }
}

// =====================================================================================
// 4. FuelPrices and the AAA state-page parser
// =====================================================================================
emit("fp-const", "nationalGas", hx(FuelPrices.nationalGas))
emit("fp-const", "nationalDiesel", hx(FuelPrices.nationalDiesel))
emit("fp-const", "nationalKWh", hx(FuelPrices.nationalKWh))
emit("fp-const", "mxnPerUSD", hx(FuelPrices.mxnPerUSD))
emit("fp-const", "litersPerGallon", hx(FuelPrices.litersPerGallon))
for k in FuelPrices.stateFactor.keys.sorted() { emit("fp-factor", ht(k), hx(FuelPrices.stateFactor[k]!)) }
for k in FuelPrices.stateNameToCode.keys.sorted() { emit("fp-name", ht(k), ht(FuelPrices.stateNameToCode[k]!)) }
var mxn: [Double] = [.nan, .infinity, -.infinity, 0, -0.0, 1, 17, 23.7, 25.4, -5, 1e308, .leastNonzeroMagnitude, 3.78541]
for _ in 0..<80 { mxn.append(rng.unit() * 40) }
for m in mxn { emit("fp-mxn", hx(m), hx(FuelPrices.usdPerGallon(mxnPerLiter: m))) }
let fuels: [(FuelType, String)] = [(.gas, "gas"), (.diesel, "diesel"), (.electric, "electric")]
for (f, n) in fuels { emit("fp-mex", n, hx(FuelPrices.mexicoEstimate(fuel: f))) }

func aaaPage(_ p: [String]) -> String {
    "<thead><th>Regular</th><th>Mid</th><th>Premium</th><th>Diesel</th></thead>\n<tbody><tr><td>Current Avg.</td>\n"
        + p.map { "<td>$\($0)</td>" }.joined() + "</tr>\n<tr><td>Yesterday Avg.</td><td>$3.5950</td></tr>"
}
// The live cache, filled through AAAFuelPrices.refresh and the stub transport above.
let liveCodes: [(String, [String])] = [("WI", ["3.459", "3.7", "4.0", "3.899"]), ("TX", ["2.845", "3.1", "3.4", "3.555"]),
  ("CA", ["5.005", "5.3", "5.5", "5.995"]), ("ZZ", ["3.125", "3.2", "3.3", "3.875"]), ("ON", ["1.005", "2", "3", "11.995"]),
  ("KS", ["3.335", "3.4", "3.5", "4.015"]), ("NY", ["3.6840", "4.2100", "4.8310", "4.5810"]), ("DC", ["1.0001", "2", "3", "11.9999"]),
  ("HI", ["4.4449999", "5", "6", "5.1250001"]), ("SS", ["2.675", "2", "3", "3.015"]), ("MX", ["0.99", "2", "3", "4"]),
  ("QC", ["2", "3", "4"])]
func aaaPageFor(_ code: String) -> String? {
    for (c, p) in liveCodes where c == code { return aaaPage(p) }
    return nil
}
for (code, _) in liveCodes {
    await AAAFuelPrices.shared.refresh(stateCode: code)
    let live = AAAFuelPrices.shared.cached(code)
    emit("fp-live", ht(code), live.map { hx($0.gas) } ?? "-", live.map { hx($0.diesel) } ?? "-")
}
var stateInputs: [String?] = [nil, "", " ", "WI", "wi", "Wi", "wI", " WI", "WI ", "\tWI\t", "\u{A0}WI\u{3000}", "\u{200B}WI",
  "\nWI", "WI\n", "W I", "Wisconsin", "WISCONSIN", " wisconsin ", "New York", "new  york", "new york", "NY", "ny",
  "\u{212A}S", "\u{212A}ansas", "k\u{212A}", "Ontario", "ON", "on", "QC", "ZZ", "zz", "W\u{301}I", "\u{1E9E}", "\u{DF}x",
  "\u{DF}", "\u{1C6}", "\u{130}", "\u{1F1FA}\u{1F1F8}", "\u{1F1FA}\u{1F1F8}\u{1F1E8}\u{1F1E6}", "\r\nX", "\r\n", "D.C.",
  "district of columbia", "District Of Columbia", "\u{0}", "WI\u{0}", "\u{0}WI", "T\u{0}", "tx", "TX", "Texas", "texas\u{301}",
  "Tex\u{0}as", "ca", "California", "CALIFORNIA\u{A0}", "hi", "Hawaii", "dc", "ss", "SS", "Ss", "mx", "MX", "Mexico",
  "\u{FF37}\u{FF29}", "w\u{130}", "\u{915}\u{94D}\u{937}", "\u{915}\u{94D}\u{937}x", "\u{600}WI", "WI\u{301}", "\u{85}WI",
  "\u{2028}WI", "\u{1680}WI\u{202F}"]
for k in FuelPrices.stateFactor.keys.sorted() { stateInputs.append(k); stateInputs.append(k.lowercased()); stateInputs.append(decorate(k)) }
for k in FuelPrices.stateNameToCode.keys.sorted() { stateInputs.append(k); stateInputs.append(k.uppercased()); stateInputs.append(decorate(k)) }
for _ in 0..<40 { stateInputs.append(pick([" ", "", "\t", "\u{A0}"]) + pick(liveCodes).0 + pick(["", " ", pick(junk)])) }
for s in stateInputs {
    for (f, n) in fuels { emit("fp-est", n, hto(s), hx(FuelPrices.estimate(fuel: f, state: s))) }
}

var htmls: [String] = [
    "<thead><th>Regular</th><th>Mid</th><th>Premium</th><th>Diesel</th></thead>\n<tbody><tr><td>Current Avg.</td>\n<td>$3.6840</td><td>$4.2100</td><td>$4.8310</td><td>$4.5810</td></tr>\n<tr><td>Yesterday Avg.</td><td>$3.5950</td></tr>",
    "<html>no table here</html>", "Current Avg. $3.10 only-one-price", "", "Current Avg.", "Current Avg.$1.5$2$3$4",
    "Current Avg. $1 $2 $3 $4", "Current Avg. $1.0000001 $2 $3 $11.9999999", "Current Avg. $12 $2 $3 $4",
    "Current Avg. $2 $2 $3 $12.0", "Current Avg. $0.999 $2 $3 $4", "Current Avg. $abc $3.45 $3.5 $3.6 $3.7",
    "Current Avg. $ 3.45 $3.5 $3.6 $3.7 $3.8", "Current Avg. $. $.. $3.4.5 $3.45abc $2 $3 $4 $5",
    "Current Avg. $\u{663}.45 $\u{FF13}.45 $\u{BD} $3\u{301}.45 $3.4\u{301}5 $2 $3 $4 $5",
    "Current Avg. $\u{0}3.45 $3.45\u{0} $2 $3 $4", "Current Avg. $123456789 $2 $3 $4", "Current Avg. $1.234567890 $2 $3 $4",
    "Current Avg. $.5 $5. $0003.45 $3.45\r\n$4\r\n", "Current Avg. $\r\n3.45 $2 $3 $4 $5", "Current Avg. $$3.45 $3.5 $3.6 $3.7",
    "Current Avg. \u{600}$3.45 $\u{301}3.45 \u{FF04}3.45 $2 $3 $4 $5", "current avg. $2 $3 $4 $5", "Current Avg $2 $3 $4 $5",
    "Current Avg.\u{301} $2 $3 $4 $5", "Current\u{A0}Avg. $2 $3 $4 $5", "Current  Avg. $2 $3 $4 $5", "\u{600}Current Avg. $2 $3 $4 $5",
    "Current Avg.. $2 $3 $4 $5", "x Current Avg. $2 $3 $4 Current Avg. $5 $6 $7 $8", "Current Avg. $2 $3 $4",
    "Current Avg. $2.1 $3.1 $4.1 Yesterday Avg. $5.1", "Current Avg. $1e1 $2 $3 $4 $5", "Current Avg. $0x3 $2 $3 $4 $5",
    "Current Avg. $inf $nan $2 $3 $4 $5", "Current Avg. $3.459\u{94D}\u{915} $2 $3 $4", "C\u{301}urrent Avg. $2 $3 $4 $5",
    "Current Avg.\u{200D} $2 $3 $4 $5", "Current Avg.\u{AD} $2 $3 $4 $5", "Current Avg.\r\n$2\r\n$3\r\n$4\r\n$5",
    "Current Avg. $2 $3 $4 $5$", "Current Avg. $2 $3 $4 $5 $6", "Current Avg. $11.99999999 $2 $3 $4",
    "Current Avg. $1.00000001 $2 $3 $4", "Current Avg. $99 $2 $3 $4", "Current Avg. $3.45$3.46$3.47$3.48"]
// Window edge: the fourth "$" at Character offsets 596...603 past the anchor, with fillers of one-Character clusters
// built from several scalars, so a scalar or byte count lands on the wrong side.
let fillers = ["x", "e\u{301}", "\r\n", "\u{1F1FA}\u{1F1F8}", "\u{915}\u{94D}\u{937}", "\u{1F468}\u{200D}\u{1F469}", "\u{AC00}\u{11A8}", "\u{600}x"]
for f in fillers {
    for off in 590...603 {
        let head = " $2 $3 $4 "
        let pad = String(repeating: f, count: off - head.count)
        htmls.append("Current Avg." + head + pad + "$5.5 tail")
        htmls.append("Current Avg." + head + pad.dropLast(0) + "$" + String(repeating: "9", count: 3))
    }
}
let htmlFrags = ["<td>", "</td>", "$", "$", "3.45", "2", "11.9", "12", "0.5", "Current Avg.", "Yesterday Avg.", " ", "\n", ".",
  "9", "$\u{301}", "\u{600}", "\r\n", "abc", "\u{663}", "\u{0}"]
for _ in 0..<150 {
    var h = chance(3) ? "" : "Current Avg."
    for _ in 0..<rng.below(30) { h += chance(6) ? pick(junk) : pick(htmlFrags) }
    htmls.append(h)
}
for h in htmls {
    let r = AAAFuelPrices.parseCurrentAvg(h)
    emit("fp-aaa", ht(h), r.map { hx($0.gas) } ?? "-", r.map { hx($0.diesel) } ?? "-")
}

// =====================================================================================
// 5. LaneData.parse(turnLanes:)
// =====================================================================================
let laneTokens = ["left", "through", "right", "slight_left", "slight_right", "sharp_left", "sharp_right", "merge_to_left",
  "merge_to_right", "reverse", "none", "", "LEFT", "Left", " left ", "\tleft", "left\n", "u_turn", "straight", "slight left",
  "left\u{301}", "none\u{0}", "\u{A0}right\u{3000}", "\u{200B}left", "\u{85}left", "RIGHT\u{200B}", "\u{130}", "reverse\u{AD}",
  "\u{FF4C}eft", "sharp_\u{212A}", "through\u{2028}", "Merge_To_Right", "through\u{202F}"]
let laneSeps = ["|", "|", "|", "\u{FF5C}", "|\u{301}", "\u{600}|", "||"]
let turnSeps = [";", ";", ";", "\u{37E}", ";\u{301}", ",", "; "]
var laneInputs = ["left|through|through;right", "||right", "sharp_left|slight_left|through|merge_to_right|reverse", "", "   ",
  "|", "||", ";", ";;|;", " | ", "none", "left|left;through|through|right", "left|through|slight_right", "through;right",
  "left|through|through;right|right", "through|through|through", "\u{A0}left|right\u{3000}", "\tleft|right\t",
  "\nleft|right", "left|right\n", "\u{200B}left", "left\u{37E}right", "left;\u{301}right", "left|\u{301}right",
  String(repeating: "through|", count: 16) + "right", "LEFT|Through|RiGhT"]
for _ in 0..<420 {
    var s = chance(6) ? pick([" ", "\t", "\u{A0}", "\n", "\u{200B}"]) : ""
    for l in 0..<(1 + rng.below(6)) {
        if l > 0 { s += pick(laneSeps) }
        for t in 0..<rng.below(4) {
            if t > 0 { s += pick(turnSeps) }
            s += chance(5) ? decorate(pick(laneTokens)) : pick(laneTokens)
        }
    }
    if chance(6) { s += pick([" ", "\t", "\u{3000}", "\n", "\u{301}"]) }
    laneInputs.append(s)
}
for s in laneInputs {
    let lanes = LaneData.parse(turnLanes: s)
    emit("ld-parse", ht(s), ht(lanes.map { $0.turns.map(\.rawValue).joined(separator: ",") }.joined(separator: "|")))
}

// =====================================================================================
// 6. EnforcementCameras tag interpretation
// =====================================================================================
let highways: [String?] = [nil, "", "speed_camera", "Speed_camera", "speed_camera ", "traffic_signals", "speed_camera\u{301}",
  "\u{600}speed_camera", "speed_camera\u{0}", "speed\u{AD}_camera", "xspeed_camera"]
let enforcements: [String?] = [nil, "", "maxspeed", "average_speed", "traffic_signals", "maxspeed;traffic_signals", "MAXSPEED",
  "maxspeed\u{301}", "xmaxspeedx", "traffic_signals\u{0}", "check", "average_speed\u{200D}", "\u{600}traffic_signals",
  "mindistance;maxspeed", "traffic_signal", "maxspeed\u{94D}\u{915}"]
let signalTags: [String?] = [nil, "", "camera", "Camera", "cameras", "camera\u{301}", "signal", "no_camera", "\u{600}camera"]
let rlcTags: [String?] = [nil, "", "yes", "Yes", "yes ", "no", "yes\u{301}", "yes\u{0}", "\u{FF59}es"]
var kindInputs: [(String?, String?, String?, String?)] = [("speed_camera", nil, nil, nil), (nil, "traffic_signals", nil, nil),
  (nil, nil, "camera", nil), ("speed_camera", "traffic_signals", nil, nil), ("traffic_signals", nil, nil, nil), (nil, nil, nil, nil),
  (nil, nil, nil, "yes"), ("speed_camera", nil, nil, "yes")]
for _ in 0..<600 { kindInputs.append((pick(highways), pick(enforcements), pick(signalTags), pick(rlcTags))) }
for (h, e, s, r) in kindInputs {
    var tags: [String: String] = ["amenity": "parking"]
    if let h { tags["highway"] = h }
    if let e { tags["enforcement"] = e }
    if let s { tags["traffic_signals"] = s }
    if let r { tags["red_light_camera"] = r }
    emit("ec-kind", hto(h), hto(e), hto(s), hto(r), EnforcementCameras.kind(fromTags: tags)?.rawValue ?? "-")
}
var maxspeeds: [String?] = [nil, "", "50", "45 mph", "45mph", " 45 MPH ", "45 mph mph", "mph", "mphmph", "mph45", "RU:urban",
  "none", "signals", "walk", "0x1e", "nan", "inf", "-inf", "infinity", "1e999", "1e-400", "nan(0x12)", "snan", "-snan",
  "50\u{0}abc", "\u{0}50", "50;60", "50,5", "50.5", ".5", "5.", "+50", "-50", "0", "-0", "0x1p-1074", "\u{665}\u{660}",
  "\u{FF15}\u{FF10}", "50\u{301}", "45 mph\u{301}", "45 m\u{301}ph", "\t45 mph\t", "\n45", "45\n", "45 mph\u{A0}",
  "\u{200B}45", "45\u{200B}mph", "45 mphx", "4\u{0}5 mph", "NaN(18)", "nan(012)", "nan(0xfffffffffffff)",
  "nan(99999999999999999999)", "nan(1a)", "nan()", "nan(", "snan(5)", "INF", "0X1P3", "1.5e3", "1e", "1e+", "0x", "00x1",
  "179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497792",
  "2.4703282292062328e-324", "2.4703282292062327e-324", "0x1.00000000000008p0", "0x1.00000000000018p0",
  "0x1.fffffffffffff8p1023", "0x.00000000000000000000000000001p120", "0x1p-1075", "0x3p-1076", "1e99999999999999999999",
  "0x1p99999999999999999999", "0.000000000000000000000000000000000000000000000000000000000000000000000001e72",
  "123456789012345678901234567890", "45 \u{212A}", "mph 45", "45 mp", "45 MPh", "  mph  ", "30 knots", "25 mph;35 mph",
  "nan(1)x", "infx", "-nan(5)", "+snan", "0x1.8p+1", "5.e1", "\u{130}nf", "\u{131}nf", "1_000", "1 000"]
for _ in 0..<150 {
    let d = pick([rng.unit() * 200, Double(rng.below(130)), rng.unit() * 1e-300, rng.unit() * 1e300, -rng.unit() * 50])
    var s = chance(2) ? "\(d)" : String(format: pick(["%g", "%.3f", "%e", "%a", "%.0f"]), d)
    if chance(3) { s += pick([" mph", "mph", " MPH", " km/h", " kmh", pick(junk)]) }
    if chance(5) { s = pick(junk) + s }
    maxspeeds.append(s)
}
for m in maxspeeds {
    let tags: [String: String] = m.map { ["maxspeed": $0, "highway": "speed_camera"] } ?? ["highway": "speed_camera"]
    emit("ec-limit", hto(m), EnforcementCameras.limitMph(fromTags: tags).map(hx) ?? "-")
}

FileHandle.standardOutput.write(out.data(using: .utf8)!)
