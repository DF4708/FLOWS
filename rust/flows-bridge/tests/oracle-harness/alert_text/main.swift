import CoreLocation
import Foundation
// Frozen oracle: every output below comes from the ORIGINAL EscalationPolicy, AlertEntityParser and ScannerIncidents
// (last changed long before their facade switch), compiled with the facades they call (FlowsCore's risk band,
// POIRanking.meters) and linked against the Rust bridge, plus the Swift runtime rules the parsers read: Foundation's
// case folding per scalar, localizedCaseInsensitiveContains, split(separator:) and Int(String). Doubles are IEEE-754 bit
// patterns in hex; text is "t:" + UTF-8 with bytes outside 0x20...0x7E, and the backslash, as \xx; nil is "-"; lists
// are "L<n>:" + comma-joined items; a point is hx(lat)/hx(lon); fields join with U+001F and items with U+001E.

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
func b(_ v: Bool) -> String { v ? "1" : "0" }
let FS = "\u{1F}", RS = "\u{1E}"
typealias C = CLLocationCoordinate2D
func pt(_ c: C) -> String { hx(c.latitude) + "/" + hx(c.longitude) }
var out = ""
func emit(_ f: String...) { out += f.joined(separator: "\t") + "\n" }
func byteSorted(_ a: [String]) -> [String] { a.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) } }

struct SM { var s: UInt64
  mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
  mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
  mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + unit() * (hi - lo) }
  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
  mutating func pick<T>(_ a: [T]) -> T { a[below(a.count)] }
  mutating func chance(_ n: Int) -> Bool { below(n) == 0 } }
var rng = SM(s: 0x414C455254545854)   // "ALERTTXT"

// ===================================================================== runtime rules
emit("u-locale", ht(Locale.current.identifier))
do {
    for v in UInt32(0)...0x10FFFF {
        guard let sc = Unicode.Scalar(v) else { continue }
        let f = String(sc).folding(options: [.caseInsensitive], locale: Locale.current)
        let fs = Array(f.unicodeScalars)
        if fs.count != 1 || fs[0] != sc {
            emit("u-fold", String(v, radix: 16), fs.map { String($0.value, radix: 16) }.joined(separator: " "))
        }
    }
}
let tricky = ["\u{DF}", "ss", "SS", "\u{1E9E}", "\u{FB02}", "fl", "FL", "\u{17F}", "s", "S", "\u{212A}", "k", "K", "\u{3A3}", "\u{3C3}",
  "\u{3C2}", "\u{130}", "i\u{307}", "I", "i", "\u{131}", "e\u{301}", "\u{E9}", "\u{C9}", "\u{FF34}", "\u{1D5B3}", "\u{0}", "\u{301}",
  "\u{200D}", "\u{1F697}", "-", " ", "\u{A0}", "\u{1F0}", "J\u{30C}", "\u{149}", "\u{FB00}", "ff", "\u{FB03}", "ffi", "\r\n", "\n", "\u{2126}",
  "\u{3C9}", "\u{1F1FA}\u{1F1F8}", "\u{CE}", "\u{1FB3}", "\u{3B1}\u{345}", "\u{587}", "\u{565}\u{582}", "\u{1E9A}", "a\u{2BE}"]
let words = ["red", "blue", "Toyota", "ford", "FORD", "Chevy", "truck", "pickup", "SUV", "sedan", "car", "van", "minivan", "bus",
  "motorcycle", "child", "girl", "boy", "man", "woman", "suspect", "wearing", "shirt", "jacket", "hoodie", "hair", "dark blue", "light gray",
  "grey", "silver", "Honda", "Nissan", "Mercedes", "Mitsubishi", "Infiniti", "Lexus", "Kia", "Tesla", "GMC", "Ram", "street", "st", "road",
  "and", "at", "Highway", "hwy", "51", "2100", "crash", "wreck", "structure fire", "shots fired", "medic", "officer", "subject", "10-50",
  "ten fifty", "swift water", "gas leak", "power line down", "Main", "Washington", "Belair", "Columbia", "on", "the", "in", "a", "of",
  "heading", "west", "last", "seen", "AMBER", "Alert", "year old", "-year-old", "infant", "adult", "male", "female", "gold", "maroon", "tan"]
func soup(_ n: Int) -> String {
    (0..<n).map { _ in rng.chance(4) ? rng.pick(tricky) : rng.pick(words) }.joined(separator: rng.pick([" ", " ", "", ", ", ". "]))
}
func mixCase(_ s: String) -> String {
    String(s.map { ch -> String in rng.chance(3) ? String(ch).uppercased() : (rng.chance(3) ? String(ch).lowercased() : String(ch)) }.joined())
}
// The case-insensitive search the brand badge uses, for ASCII needles: which scalars block a match when they
// follow it (inclusive ranges over every scalar), and which of Foundation's per-scalar folds the search itself
// applies (a scalar whose fold the search does not match is listed).
do {
    var after: [(UInt32, UInt32)] = []
    for v in UInt32(0)...0x10FFFF {
        guard let sc = Unicode.Scalar(v) else { continue }
        if !("ab" + String(sc)).localizedCaseInsensitiveContains("ab") {
            if let last = after.last, last.1 &+ 1 == v { after[after.count - 1].1 = v } else { after.append((v, v)) }
        }
    }
    for r in after { emit("u-ci-after", String(r.0, radix: 16), String(r.1, radix: 16)) }
    for v in UInt32(0)...0x10FFFF {
        guard let sc = Unicode.Scalar(v) else { continue }
        let x = String(sc)
        let f = x.folding(options: [.caseInsensitive], locale: Locale.current)
        if Array(f.unicodeScalars) != [sc] {
            emit("u-ci-fold", String(v, radix: 16), b(x.localizedCaseInsensitiveContains(f)), b(f.localizedCaseInsensitiveContains(x)))
        }
    }
}
let injected = ["\u{200D}", "\u{200C}", "\u{AD}", "\u{34F}", "\u{FE0F}", "\u{2060}", "\u{FEFF}", "\u{200B}", "\u{E0001}", "\u{180B}",
  "\u{301}", "\u{307}", "\u{345}", "\u{20DD}", "\u{903}", "\u{600}", "\u{110BD}", "\u{1F3FB}", "\u{1F1FA}", "\u{DF}", "\u{1E9E}", "\u{17F}",
  "\u{212A}", "\u{FB00}", "\u{FB01}", "\u{FB02}", "\u{FB05}", "\u{FB06}", "\u{130}", "\u{131}", "\u{1F0}", "\u{149}", "\u{FF46}", "\r", "\n",
  "\r\n", "\u{1100}", "\u{1161}", "\u{11A8}", " ", "-", "\u{0}", "\u{7F}", "\u{85}", "\u{2028}", "\u{E9}", "e\u{301}", "\u{1F697}", "\u{FFFD}"]
func asciiNeedle() -> String {
    if rng.chance(2) { return rng.pick(AlertEntityParser.brands) }
    let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ -")
    return String((0..<(1 + rng.below(6))).map { _ in rng.pick(letters) })
}
for _ in 0..<6_000 {
    let needle = asciiNeedle()
    var base = Array(rng.chance(3) ? soup(rng.pick([1, 3])) + mixCase(needle) + soup(rng.pick([0, 2])) : mixCase(needle))
        .map { String($0) }
    for _ in 0..<rng.pick([0, 1, 1, 2, 4]) {
        let at = rng.below(base.count + 1)
        let piece = rng.chance(12) ? String(Unicode.Scalar(UInt32(rng.below(0x3000))) ?? "x") : rng.pick(injected)
        base.insert(piece, at: at)
    }
    if rng.chance(6) {
        let pairs = [("ss", "\u{DF}"), ("s", "\u{17F}"), ("k", "\u{212A}"), ("fl", "\u{FB02}"), ("fi", "\u{FB01}"), ("ff", "\u{FB00}"), ("st", "\u{FB06}")]
        let (from, to) = rng.pick(pairs)
        base = [base.joined().replacingOccurrences(of: from, with: to)]
    }
    var hay = base.joined()
    if rng.chance(3) { hay = hay.lowercased() }
    emit("u-cic", ht(hay), ht(needle), b(hay.localizedCaseInsensitiveContains(needle)))
}
func transcript() -> String {
    var parts: [String] = []
    for _ in 0..<rng.pick([1, 3, 6, 12, 20]) {
        switch rng.below(9) {
        case 0: parts.append(String(rng.pick([0, 1, 51, 2100, 99_999, 100_000, 123456789012345678901 as Double == 0 ? 7 : 12])))
        case 1: parts.append(rng.pick(["+5", "-3", "05", "\u{663}", "1_000", "51,", "2100.", "99999999999999999999", "0x10", "\u{FF15}"]))
        case 2: parts.append(rng.pick(ScannerIncidents.roadWords) + rng.pick(["", ".", ",", ";", "!", "?", ":"]))
        case 3: parts.append(rng.pick(["and", "at", "And", "AT", "and\u{301}", "at,"]))
        case 4: parts.append(rng.pick(ScannerIncidents.Kind.allCases).phrases.randomElementSeeded())
        case 5: parts.append(rng.pick(tricky))
        default: parts.append(rng.pick(words))
        }
    }
    return parts.joined(separator: rng.pick([" ", " ", "  ", " \u{301}", "\u{A0}", "\t", ", "]))
}
extension Array where Element == String {
    func randomElementSeeded() -> String { self[rng.below(count)] }
}
var transcripts: [String] = ["two vehicle crash on Highway 51", "51", "respond to 2100", "2100 Washington Road", "Belair Road and Columbia Road",
  "structure fire at 12 Main Street.", "shots fired, 400 block of Elm St", "medic responding to 99999 Oak Lane", "crash at Main St and 5th Ave",
  "", " ", "and", "a and b", "road and road", "st and st st", "100000 main street", "0 main street", "+5 main st", "-5 main st"]
for _ in 0..<1_500 { transcripts.append(transcript()) }
for t in transcripts {
    emit("u-split", ht(t), t.split(separator: " ").map { ht(String($0)) }.joined(separator: RS))
    emit("sc-kind", ht(t), hto(ScannerIncidents.kind(inTranscript: t)?.rawValue))
    emit("sc-place", ht(t), hto(ScannerIncidents.placePhrase(inTranscript: t)))
}
for w in ["5", "+5", "-5", " 5", "5 ", "05", "\u{663}", "99999999999999999999", "9223372036854775807", "9223372036854775808",
          "-9223372036854775808", "-9223372036854775809", "", "+", "-", "1_000", "0x10", "\u{FF15}", "00", "+0", "-0", "1\u{301}", "12a"] {
    emit("u-int", ht(w), Int(w).map(String.init) ?? "-")
}

// ===================================================================== AlertEntityParser
emit("ae-colors", AlertEntityParser.colorNames.map(ht).joined(separator: RS))
emit("ae-brands", AlertEntityParser.brands.map(ht).joined(separator: RS))
emit("ae-kinds", AlertEntityParser.VehicleKind.allCases.map { $0.rawValue }.joined(separator: RS))
let events = ["AMBER Alert", "Child Abduction Emergency", "Blue Alert", "Silver Alert", "Endangered Person", "Missing Person",
  "Law Enforcement Warning", "Civil Emergency Message", "Tornado Warning", "Severe Thunderstorm Warning", "amber", "AMBE\u{301}R", "\u{130}ssing",
  "", "Flood Warning", "civil emergency", "Missing\u{200D}", "\u{1F6A8} Amber"]
for e in events + (0..<200).map({ _ in soup(rng.pick([1, 2, 3])) }) {
    emit("ae-describes", ht(e), b(AlertEntityParser.describesAnEntity(event: e)))
}
func alertText() -> String {
    let filler = (0..<rng.pick([0, 3, 12, 30])).map { _ in rng.pick(["the", "area", "near", "county", "police", "call", "911", "if", "seen",
                                                                        "\u{1F697}", "e\u{301}", "\u{DF}", "\r\n"]) }.joined(separator: " ")
    let pieces = [rng.chance(2) ? filler : "", rng.pick(["AMBER Alert:", "Blue Alert", "Missing:", ""]),
                  rng.chance(2) ? rng.pick(["child", "girl", "boy", "man", "woman", "suspect", "5-year-old", "adult male"]) : "",
                  rng.chance(2) ? "wearing \(rng.pick(AlertEntityParser.colorNames)) \(rng.pick(["shirt", "jacket", "hoodie", "dress", "pants"]))" : "",
                  rng.chance(3) ? filler : "",
                  rng.chance(2) ? "in a \(rng.pick(AlertEntityParser.colorNames)) \(mixCase(rng.pick(AlertEntityParser.brands))) \(rng.pick(["pickup truck", "truck", "suv", "sport utility", "minivan", "van", "sedan", "coupe", "hatchback", "motorcycle", "bus", "car", "SUV", "Truck"]))" : "",
                  rng.chance(2) ? filler : "", rng.chance(3) ? soup(rng.pick([2, 6])) : ""]
    return pieces.filter { !$0.isEmpty }.joined(separator: rng.pick([" ", ". ", ", "]))
}
for _ in 0..<2_500 {
    let t = alertText()
    let v = AlertEntityParser.vehicle(in: t)
    emit("ae-vehicle", ht(t), v.map { [hto($0.colorName), $0.kind.rawValue, hto($0.brand)].joined(separator: FS) } ?? "-")
    let p = AlertEntityParser.person(in: t)
    emit("ae-person", ht(t), p.map { [b($0.isChild), hto($0.colorName)].joined(separator: FS) } ?? "-")
}

// ===================================================================== ScannerIncidents: pins
let kinds = ScannerIncidents.Kind.allCases
for k in kinds { emit("sc-lifetime", k.rawValue, hx(ScannerIncidents.lifetime(for: k)), k.phrases.map(ht).joined(separator: RS)) }
emit("sc-order", ScannerIncidents.matchOrder.map { $0.rawValue }.joined(separator: RS))
emit("sc-roads", ScannerIncidents.roadWords.map(ht).joined(separator: RS))
emit("sc-consts", hx(ScannerIncidents.relevantMeters), hx(ScannerIncidents.duplicateMeters))
let centers: [C] = [C(latitude: 43.07, longitude: -89.4), C(latitude: 41.88, longitude: -87.63), C(latitude: 0, longitude: 179.99)]
func near(_ c: C, _ s: Double) -> C { C(latitude: c.latitude + rng.range(-s, s), longitude: c.longitude + rng.range(-s, s)) }
func incidentOut(_ i: ScannerIncidents.Incident) -> String {
    [ht(i.id), i.kind.rawValue, pt(i.coordinate), ht(i.placeText), hx(i.heardAt.timeIntervalSinceReferenceDate)].joined(separator: FS)
}
var serial = 0
func incident(_ c: C) -> ScannerIncidents.Incident {
    serial += 1
    let coord = rng.chance(20) ? C(latitude: .nan, longitude: c.longitude) : near(c, rng.pick([0.001, 0.003, 0.2, 0.4]))
    return ScannerIncidents.Incident(id: "i\(serial)", kind: rng.pick(kinds), coordinate: coord, placeText: "p",
                                     heardAt: Date(timeIntervalSinceReferenceDate: 8e8 + rng.range(-7_200, 0)))
}
for _ in 0..<600 {
    let c = rng.pick(centers)
    let list = (0..<rng.pick([0, 1, 3, 8, 20])).map { _ in incident(c) }
    let now = Date(timeIntervalSinceReferenceDate: 8e8 + rng.pick([0, 60, -60, 720, 3_600]))
    if let first = list.first {
        emit("sc-expired", incidentOut(first), hx(now.timeIntervalSinceReferenceDate), b(ScannerIncidents.isExpired(first, now: now)))
    }
    let position: C? = rng.chance(4) ? nil : near(c, rng.pick([0.05, 0.3]))
    let corridor = (0..<rng.pick([0, 0, 2, 6])).map { _ in near(c, rng.pick([0.1, 0.5])) }
    let vis = ScannerIncidents.visible(list, near: position, corridor: corridor, now: now)
    emit("sc-visible", list.map(incidentOut).joined(separator: RS), position.map(pt) ?? "-", corridor.map(pt).joined(separator: ";"),
         hx(now.timeIntervalSinceReferenceDate), vis.map { ht($0.id) }.joined(separator: RS))
    let new = incident(c)
    emit("sc-merged", list.map(incidentOut).joined(separator: RS), incidentOut(new),
         ScannerIncidents.merged(list, adding: new).map { ht($0.id) }.joined(separator: RS))
}

// ===================================================================== EscalationPolicy
func stateOut(_ s: EscalationPolicy.State) -> String {
    [hx(s.baseline), hx(s.dismissedRisk), byteSorted(Array(s.dismissedAlertIDs)).map(ht).joined(separator: RS)].joined(separator: FS)
}
func triggerOut(_ t: EscalationPolicy.Trigger?) -> String {
    switch t {
    case nil: return "-"
    case .sustained(let m)?: return "s" + FS + hx(m)
    case .acute(let p, let id)?: return "a" + FS + hx(p) + FS + hto(id)
    }
}
emit("ep-consts", hx(EscalationPolicy.sustainedRise), hx(EscalationPolicy.dismissMargin), hx(EscalationPolicy.State.deferred),
     hx(FlowsCore.riskYellowMin))
let ids: [String?] = [nil, "A", "B", "C", "caf\u{E9}", "cafe\u{301}", "", "\u{212A}"]
let edge = [FlowsCore.riskYellowMin, FlowsCore.riskGreenMin, 0.0, 1.0, 0.95, 0.7, 0.75, 0.8, .nan, .infinity, -1]
for drive in 0..<120 {
    var state = EscalationPolicy.State.fresh(baseline: rng.chance(3) ? nil : rng.pick([0.1, 0.3, FlowsCore.riskYellowMin, .nan, rng.unit()]))
    for _ in 0..<40 {
        let r = EscalationPolicy.Reading(complete: !rng.chance(8),
                                         mean: rng.chance(5) ? rng.pick(edge) : rng.unit(),
                                         peak: rng.chance(5) ? rng.pick(edge) : rng.unit(),
                                         peakAlertID: rng.pick(ids))
        let before = state
        let (next, trigger) = EscalationPolicy.evaluate(r, state: before)
        emit("ep-eval", String(drive), stateOut(before),
             [b(r.complete), hx(r.mean), hx(r.peak), hto(r.peakAlertID)].joined(separator: FS), stateOut(next), triggerOut(trigger))
        state = next
        if let trigger, rng.chance(2) {
            let after = EscalationPolicy.dismissed(trigger, state: state)
            emit("ep-dismiss", stateOut(state), triggerOut(trigger), stateOut(after))
            state = after
        }
    }
}

if CommandLine.arguments.count > 1 {
    FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: out.data(using: .utf8)!)
} else {
    FileHandle.standardOutput.write(out.data(using: .utf8)!)
}
