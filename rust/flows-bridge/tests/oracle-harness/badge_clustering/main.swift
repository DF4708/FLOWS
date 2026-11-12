import CoreLocation
import Foundation

// Frozen oracle: every output below comes from the ORIGINAL Swift `BadgeClustering` (BadgeClustering.swift),
// compiled with the test target's own Core sources at the base commit. Doubles are IEEE-754 bit patterns in hex.
// An item is "lat:lon:kind:score" (kind a small decimal integer); a list is its entries joined by ",", "" when
// empty.
//
// Kinds:
//   k   minSeparationMeters, items, cluster
//   d   minSeparationMeters, items, declutter
//   b   radiusMeters, badges, labelled items (label i is "L<i>"), the labels joined by "," ("-" for none)
//   w   event (hex of its UTF-8 bytes), isWarning
//   s   badgeEvent, shownEvent (hex of UTF-8, "-" for nil), sameHazard
//   u   mergeMeters, mode, badges, shown, areas (a ring's points "lat:lon" joined by ";", rings by "|"), unshown
//
// The `u` closures are rules of the items' own bits, which the Rust test repeats:
//   minor(b)          b.score's bit pattern is odd
//   sameHazard(b, s)  mode "d": the default argument (always true); mode "x": bit 1 of
//                     b.score.bitPattern ^ s.score.bitPattern is clear
//
// A cluster call the original would trap on (its grid path converting a NaN, infinite or too-large cell to
// Int, or stepping past Int.min) is never asked for: `gridTraps` says which, the same arithmetic as the
// original.

typealias Item = BadgeClustering.Item<Int>

func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func it(_ i: Item) -> String { "\(hx(i.coordinate.latitude)):\(hx(i.coordinate.longitude)):\(i.kind):\(hx(i.score))" }
func its(_ a: [Item]) -> String { a.map(it).joined(separator: ",") }
func b01(_ b: Bool) -> String { b ? "1" : "0" }
func C(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
func I(_ lat: Double, _ lon: Double, _ kind: Int, _ score: Double) -> Item {
    Item(coordinate: C(lat, lon), kind: kind, score: score)
}
func utf8hex(_ s: String) -> String { s.utf8.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined() }
func ringStr(_ r: [CLLocationCoordinate2D]) -> String {
    r.map { "\(hx($0.latitude)):\(hx($0.longitude))" }.joined(separator: ";")
}

struct SM {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func pick<T>(_ a: [T]) -> T { a[below(a.count)] }
    mutating func chance(_ n: Int) -> Bool { below(n) == 0 }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
}

let SPECIAL: [Double] = [
    .nan, .infinity, -.infinity, 0, -0.0, 1e300, -1e300, .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
    .greatestFiniteMagnitude, 1e-300, 90, -90, 180, -180,
]
let SEPS: [Double] = [0, -1, .nan, .infinity, 1, 500, 5_000, 50_000, 500_000, .leastNonzeroMagnitude, 1e300]

/// Whether the original's grid path would trap on these items: it converts each cell to Int and steps one
/// cell either way.
func gridTraps(_ items: [Item], _ minSep: Double) -> Bool {
    guard items.count >= 64 && minSep > 0 else { return false }
    let maxAbsLat = items.reduce(0.0) { max($0, abs($1.coordinate.latitude)) }
    let cosMin = max(cos(maxAbsLat * .pi / 180), 1e-6)
    let latCell = minSep / 111_320.0
    let lonCell = minSep / (111_320.0 * cosMin)
    func bad(_ x: Double) -> Bool {
        let f = x.rounded(.down)
        return !(f > -9223372036854775808.0 && f < 9223372036854775808.0)
    }
    return items.contains { bad($0.coordinate.longitude / lonCell) || bad($0.coordinate.latitude / latCell) }
}

func score(_ r: inout SM) -> Double {
    switch r.below(12) {
    case 0: return r.pick([0, -0.0, 1e-5, 1e-4, 1e-4.nextUp, 1e-4.nextDown, -1, 1, 0.5])
    case 1: return r.pick(SPECIAL)
    case 2: return Double(r.below(4)) / 4  // ties
    default: return r.unit()
    }
}

func randomItems(_ r: inout SM, n: Int, lat: Double, lon: Double, spread: Double, kinds: Int, special: Bool) -> [Item] {
    (0..<n).map { _ in
        var a = lat + r.range(-spread, spread)
        var o = lon + r.range(-spread, spread)
        if special && r.chance(8) { a = r.pick(SPECIAL) }
        if special && r.chance(8) { o = r.pick(SPECIAL) }
        return I(a, o, r.below(kinds), score(&r))
    }
}

func ring(_ r: inout SM, lat: Double, lon: Double, size: Double) -> [CLLocationCoordinate2D] {
    switch r.below(8) {
    case 0: return []
    case 1: return [C(lat, lon), C(lat + size, lon)]
    case 2:
        return [C(lat - size, lon - size), C(lat - size, lon + size), C(lat + size, lon + size),
                C(lat + size, lon - size)]
    case 3:
        var pts = (0..<6).map { k in C(lat + size * cos(Double(k)), lon + size * sin(Double(k))) }
        pts[r.below(6)] = C(r.pick(SPECIAL), r.pick(SPECIAL))
        return pts
    default:
        let n = 3 + r.below(9)
        return (0..<n).map { k in
            let a = Double(k) / Double(n) * 2 * .pi
            let rr = size * r.range(0.3, 1.2)
            return C(lat + rr * cos(a), lon + rr * sin(a))
        }
    }
}

func minorRule(_ b: Item) -> Bool { b.score.bitPattern & 1 == 1 }
func sameRule(_ b: Item, _ s: Item) -> Bool { (b.score.bitPattern ^ s.score.bitPattern) & 2 == 0 }

@main
@MainActor
enum Oracle {
    static var rng = SM(s: 0x4241_4447_4553)  // "BADGES"
    static var out = ""
    static var skipped = 0
    static func emit(_ f: [String]) { out += f.joined(separator: "\t") + "\n" }

    static func clusterAndDeclutter(_ set: [Item], _ sep: Double) {
        if gridTraps(set, sep) {
            skipped += 1
            return
        }
        emit(["k", hx(sep), its(set), its(BadgeClustering.cluster(set, minSeparationMeters: sep))])
        emit(["d", hx(sep), its(set), its(BadgeClustering.declutter(set, minSeparationMeters: sep))])
    }

    static func main() {
        let args = CommandLine.arguments

        // Cluster and declutter: hand-made sets with every separation, then random sets with a few.
        var sets: [[Item]] = [[], [I(40, -100, 0, 1)], [I(40, -100, 0, 1), I(40, -100, 0, 1)]]
        // Two kinds overlapping; a corridor; poles; one point many times; NaN scores either side of 64 items;
        // a column of latitudes; latitudes past 90.
        sets.append([I(35, -97, 0, 0.9), I(35.01, -97, 1, 0.8), I(35.02, -97.01, 0, 0.7), I(35.5, -97, 0, 0.95)])
        sets.append((0..<80).map { I(39 + Double($0) * 0.05, -100 + Double($0) * 0.07, 0, 0.5 + Double($0 % 7) / 20) })
        sets.append((0..<70).map { I(89.9 - Double($0) * 0.001, Double($0) * 3, $0 % 2, 0.5) })
        sets.append((0..<70).map { I(-89.95, -179 + Double($0) * 5, 0, Double($0 % 3)) })
        sets.append((0..<66).map { _ in I(40, -100, 0, 1) })
        sets.append((0..<64).map { I(10, Double($0) * 1e-3, 0, $0 % 5 == 0 ? .nan : Double($0)) })
        sets.append((0..<63).map { I(10, Double($0) * 1e-3, 0, $0 % 5 == 0 ? .nan : Double($0)) })
        sets.append((0..<100).map { I(Double($0) * 1.5 - 75, 0, $0 % 3, Double(100 - $0)) })
        sets.append((0..<90).map { I(95 + Double($0), Double($0), 0, 1) })
        // A grid on cell edges: points exactly on multiples of the cell for a 5 km separation at the equator.
        let cell = 5_000 / 111_320.0
        sets.append((0..<81).map { I(Double($0 / 9) * cell, Double($0 % 9) * cell, $0 % 2, Double($0 % 4)) })
        for set in sets {
            for sep in SEPS { clusterAndDeclutter(set, sep) }
        }
        for _ in 0..<170 {
            let n = rng.pick([1, 2, 3, 5, 8, 13, 20, 40, 63, 64, 65, 100, 130])
            let spread = rng.pick([0.001, 0.05, 0.5, 2, 10, 60])
            let set = randomItems(&rng, n: n, lat: rng.range(-60, 70), lon: rng.range(-170, 170), spread: spread,
                                  kinds: rng.pick([1, 2, 4]), special: rng.chance(4))
            for _ in 0..<3 {
                let sep = rng.chance(4) ? rng.pick(SEPS) : spread * 111_320 * rng.range(0.02, 0.8)
                clusterAndDeclutter(set, sep)
            }
        }

        // Labels.
        for _ in 0..<500 {
            let lat = rng.range(-50, 60)
            let lon = rng.range(-150, 150)
            let spread = rng.pick([0.01, 0.2, 1, 5])
            let kinds = rng.pick([1, 2, 3])
            let badges = randomItems(&rng, n: rng.below(9), lat: lat, lon: lon, spread: spread, kinds: kinds,
                                     special: rng.chance(5))
            var labelled = randomItems(&rng, n: rng.below(14), lat: lat, lon: lon, spread: spread, kinds: kinds,
                                       special: rng.chance(5))
            if !badges.isEmpty && rng.chance(3) {
                // A labelled point exactly on a badge, and two at the same distance from it with its score.
                let b = rng.pick(badges)
                labelled.append(b)
                labelled.append(I(b.coordinate.latitude + 0.01, b.coordinate.longitude, b.kind, b.score))
                labelled.append(I(b.coordinate.latitude - 0.01, b.coordinate.longitude, b.kind, b.score))
            }
            let radius = rng.pick([0, -1, .nan, .infinity, 100, 2_000, 20_000, 200_000, 2_000_000])
            let got = BadgeClustering.labels(
                for: badges, from: labelled.enumerated().map { (item: $0.element, label: "L\($0.offset)") },
                radiusMeters: radius)
            emit(["b", hx(radius), its(badges), its(labelled), got.map { $0 ?? "-" }.joined(separator: ",")])
        }

        // isWarning and sameHazard.
        var events: [String] = [
            "", "Tornado Warning", "Tornado Watch", "WARNING", "warning", "Warnings", "Emergency", "EMERGENCY",
            "Civil Emergency Message", "Flood Advisory", "Special Weather Statement", "Extreme Heat Warning",
            "Red Flag Warning", "Winter Storm Watch", "warn ing", "WARN", "emergenc", "Emergencies",
            "warning\u{301}", "warnin\u{301}g", "\u{301}warning", "w\u{301}arning", "Warning\u{20DD}",
            "WARN\u{130}NG", "WARN\u{131}NG", "\u{212A}WARNING", "\u{FF37}arning", "\u{1F6}Warning",
            "WARNING\u{1F32A}", "Storm \u{1F32A} Warning", "\u{0}warning", "Warning\r\n", "\r\nWarning",
            "\u{1F1FA}\u{1F1F8} Emergency", "EMERGENCY\u{345}", "\u{3A3}WARNING", "\u{FB00}warning",
            "Caf\u{E9} Warning", "Cafe\u{301} Warning", "Hurricane Force Wind Warning", "Evacuation Immediate",
            "Shelter In Place Warning", "Blue Alert", "Tsunami Warning", "Avalanche Warning", "WARNING\u{200D}",
            "EMERGENC\u{178}", "emergency\u{308}",
        ]
        for _ in 0..<60 {
            let a = rng.pick(events)
            let b = rng.pick(events)
            events.append(rng.chance(2) ? a + b : String(a.reversed()) + " " + b.uppercased())
        }
        for e in events { emit(["w", utf8hex(e), b01(BadgeClustering.isWarning(e))]) }
        let shownEvents: [String?] = [
            nil, "", "Tornado Warning", "Tornado Watch", "TORNADO WARNING", "Cafe\u{301} Warning",
            "Caf\u{E9} Warning", "Extreme Heat Warning", "Emergency", "warning\u{301}",
        ]
        let badgeEvents: [String?] = [nil] + events.prefix(48).map { Optional($0) }
        for b in badgeEvents {
            for s in shownEvents {
                emit(["s", b.map(utf8hex) ?? "-", s.map(utf8hex) ?? "-",
                      b01(BadgeClustering.sameHazard(badgeEvent: b, shownEvent: s))])
            }
        }

        // Unshown.
        for _ in 0..<700 {
            let lat = rng.range(-50, 60)
            let lon = rng.range(-150, 150)
            let spread = rng.pick([0.01, 0.1, 0.5, 3])
            let kinds = rng.pick([1, 2, 3])
            let badges = randomItems(&rng, n: rng.below(10), lat: lat, lon: lon, spread: spread, kinds: kinds,
                                     special: rng.chance(6))
            var shown = randomItems(&rng, n: rng.below(10), lat: lat, lon: lon, spread: spread, kinds: kinds,
                                    special: rng.chance(6))
            if !badges.isEmpty && rng.chance(3) { shown.append(rng.pick(badges)) }
            var areas: [[CLLocationCoordinate2D]] = []
            for _ in 0..<rng.below(5) {
                let la = lat + rng.range(-spread, spread)
                let lo = lon + rng.range(-spread, spread)
                let size = spread * rng.range(0.1, 1.5)
                areas.append(ring(&rng, lat: la, lon: lo, size: size))
            }
            if !badges.isEmpty && rng.chance(4) {
                // A ring whose box edge passes exactly through a badge.
                let c = rng.pick(badges).coordinate
                areas.append([C(c.latitude, c.longitude - spread), C(c.latitude, c.longitude + spread),
                              C(c.latitude + spread, c.longitude)])
            }
            let merge = rng.pick([0, -1, .nan, .infinity, 50, 1_000, 10_000, 100_000])
            let mode = rng.chance(3) ? "d" : "x"
            let got =
                mode == "d"
                ? BadgeClustering.unshown(badges, shown: shown, areas: areas, mergeMeters: merge, minor: minorRule)
                : BadgeClustering.unshown(badges, shown: shown, areas: areas, mergeMeters: merge, minor: minorRule,
                                          sameHazard: sameRule)
            emit(["u", hx(merge), mode, its(badges), its(shown), areas.map(ringStr).joined(separator: "|"),
                  its(got)])
        }

        FileHandle.standardError.write(Data("skipped clusters: \(skipped)\n".utf8))
        FileManager.default.createFile(atPath: args[1], contents: Data(out.utf8))
    }
}
