import CoreLocation
import Foundation

// Frozen oracle: every output below comes from the ORIGINAL Swift `CorridorWatchRules` (the live corridor
// watch's rules as they left AppModel and WeatherAlertService), compiled with the test target's own Core
// sources at the base commit. Doubles are IEEE-754 bit patterns in hex; text is "t:" + UTF-8 with bytes
// outside 0x20...0x7E, and the backslash, as \xx; nil is "-"; lists are "L<n>:" + comma-joined items; a check
// point is hx(lat)/hx(lon)/hx(risk)/event/id, and check points join with ";".
//
// Kinds: win speed, lookahead, cadence | spm eta, distance, pace | mph distance, eta, speed |
// sl count, spacing, along, lookahead, pace, ranged, lo, hi ("-" when not ranged), offsets | rd risks, mean, peak, peak index |
// fd route, window, sources (one per route check point, "-" for none).

typealias C = CLLocationCoordinate2D
func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func ht(_ s: String) -> String {
    let digits = Array("0123456789abcdef".unicodeScalars)
    var o = "t:"
    for b in s.utf8 {
        if b >= 0x20, b <= 0x7E, b != 0x5C, b != 0x2F, b != 0x3B, b != 0x2C {
            o.unicodeScalars.append(Unicode.Scalar(b))
        } else {
            o += "\\"
            o.unicodeScalars.append(digits[Int(b >> 4)])
            o.unicodeScalars.append(digits[Int(b & 15)])
        }
    }
    return o
}
func hto(_ s: String?) -> String { s.map(ht) ?? "-" }
func lst(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: ",") }

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
}

let SP: [Double] = [
    .nan, .infinity, -.infinity, 0, -0.0, 1e300, -1e300, .leastNonzeroMagnitude, .greatestFiniteMagnitude, -1, 2,
]
let SPEEDS: [Double] = [0, 1.4, 2.999, 3, 3.0001, 5, 13.4, 19.99, 20, 20.01, 29, 33.5, 83.3, 83.4, 84, 200, 2.77, 2.78]
let RISKS: [Double] = [0, 0, 0.02, 0.02, 0.04, 0.04, 0.1, 0.25, 0.26, 0.27, 0.2701, 0.29, 0.5, 0.52, 0.5200001, 0.75, 0.95, 1, 0.33, 0.35]
let EVENTS: [String?] = [nil, nil, "", "Tornado Warning", "Flood Warning", "Winter Storm Warning", "tornado warning"]
let IDS: [String?] = [nil, nil, "", "urn:oid:2.49.0.1.840.0.a", "urn:oid:2.49.0.1.840.0.b", "x"]
let centers: [C] = [
    C(latitude: 43.07, longitude: -89.4), C(latitude: 34.05, longitude: -118.24),
    C(latitude: 61.22, longitude: -149.9), C(latitude: 25.76, longitude: -80.19),
    C(latitude: 0, longitude: 0), C(latitude: -33.9, longitude: 151.2),
]

@main
@MainActor
enum Oracle {
    static var rng = SM(s: 0x434F_5252_5741_5443)  // "CORRWATC"
    static var out = ""
    static func emit(_ f: [String]) { out += f.joined(separator: "\t") + "\n" }
    static func special(_ v: Double, _ n: Int = 12) -> Double { rng.chance(n) ? rng.pick(SP) : v }

    static func window() {
        let speed = rng.chance(3) ? rng.pick(SPEEDS) : special(rng.unit() * 90 - 2)
        let w = CorridorWatchRules.window(speed: speed)
        emit(["win", hx(speed), hx(w.lookahead), hx(w.cadence)])
    }

    static func pace() {
        let eta = special(rng.unit() * 40_000)
        let distance = special(rng.chance(6) ? rng.unit() * 2 : rng.unit() * 900_000)
        emit(["spm", hx(eta), hx(distance), hx(CorridorWatchRules.secondsPerMeter(eta: eta, distanceMeters: distance))])
        emit(["mph", hx(distance), hx(eta), hx(CorridorWatchRules.averageMph(distanceMeters: distance, eta: eta))])
    }

    /// The original traps where a check-point index is not a number or the route has none; those inputs are
    /// not in the fixture (the Rust answers them as "every check point", pinned by its own tests).
    static func slice() {
        let count = rng.chance(8) ? 1 : 1 + rng.below(60)
        let spacing = rng.chance(15) ? rng.pick([1.0, 0.5, 39_999.5, 1e-9, 1e12, -40_000.0]) : 40_000.0
        let length = Double(count) * 40_000
        var along = rng.unit() * length * 1.2 - length * 0.05
        if rng.chance(10) { along = rng.pick([0, -0.0, -1, 1e300, -1e300, .infinity, -.infinity, 40_000, 80_000]) }
        var lookahead = rng.chance(3) ? rng.pick([5_000.0, 150_000, 54_000]) : rng.unit() * 160_000
        if rng.chance(8) {
            lookahead = rng.pick([.greatestFiniteMagnitude, 0, -1, -100_000, .infinity, 1e300, -1e300])
        }
        let pace = special(rng.unit() * 0.08, 15)
        let a = along / spacing
        let b = (along + lookahead) / spacing + 1
        if a.isNaN || b.isNaN { return }
        let s = CorridorWatchRules.slice(
            count: count, spacing: spacing, along: along, lookahead: lookahead, secondsPerMeter: pace)
        emit([
            "sl", String(count), hx(spacing), hx(along), hx(lookahead), hx(pace),
            s.ranged ? "1" : "0", s.ranged ? String(s.lo) : "-", s.ranged ? String(s.hi) : "-", lst(s.offsets.map(hx)),
        ])
    }

    static func reading() {
        let n = rng.chance(10) ? 0 : rng.below(30)
        let risks = (0..<n).map { _ in rng.chance(4) ? special(rng.pick(RISKS), 6) : rng.unit() }
        let r = CorridorWatchRules.reading(risks)
        emit(["rd", lst(risks.map(hx)), hx(r.mean), hx(r.peak), r.peakIndex.map(String.init) ?? "-"])
    }

    static func mark(_ c: C) -> CorridorWatchRules.Mark {
        CorridorWatchRules.Mark(
            coordinate: c, risk: rng.chance(3) ? special(rng.pick(RISKS), 15) : rng.unit(),
            worstEvent: rng.pick(EVENTS), alertID: rng.pick(IDS))
    }
    static func enc(_ m: [CorridorWatchRules.Mark]) -> String {
        m.map {
            [hx($0.coordinate.latitude), hx($0.coordinate.longitude), hx($0.risk), hto($0.worstEvent), hto($0.alertID)]
                .joined(separator: "/")
        }.joined(separator: ";")
    }

    static func fold() {
        let start = rng.pick(centers)
        let heading = rng.unit() * 2 * Double.pi
        // Route check points about 40 km apart, now and then two at one place or a few hundred meters apart.
        let n = rng.chance(12) ? 0 : 1 + rng.below(14)
        var route: [CorridorWatchRules.Mark] = []
        var at = start
        for _ in 0..<n {
            route.append(mark(at))
            let step = rng.chance(8) ? rng.pick([0.0, 0.002, 0.004, 0.0054, 0.0108]) : 0.36
            at = C(
                latitude: at.latitude + step * cos(heading),
                longitude: at.longitude + step * sin(heading) * 1.3)
        }
        // Window check points: mostly on a stretch of the route, nudged from 0 to about 900 m, some far off.
        var window: [CorridorWatchRules.Mark] = []
        let m = rng.chance(12) ? 0 : rng.below(10)
        for _ in 0..<m {
            if route.isEmpty || rng.chance(7) {
                window.append(mark(C(latitude: start.latitude + rng.unit() * 3, longitude: start.longitude + rng.unit() * 3)))
                continue
            }
            let near = route[rng.below(route.count)]
            let nudge = rng.pick([0.0, 0.0, 0.001, 0.003, 0.005, 0.00538, 0.00539, 0.0054, 0.006, 0.008])
            let c = C(
                latitude: near.coordinate.latitude + nudge * (rng.chance(2) ? 1 : -1),
                longitude: near.coordinate.longitude + (rng.chance(3) ? nudge : 0))
            // Often the route's own reading back again, or one a hair off it.
            if rng.chance(2) {
                window.append(
                    CorridorWatchRules.Mark(
                        coordinate: c, risk: near.risk + rng.pick([0, 0.01, 0.02, 0.0200001, 0.03, -0.02, -0.021]),
                        worstEvent: rng.chance(5) ? rng.pick(EVENTS) : near.worstEvent,
                        alertID: rng.chance(5) ? rng.pick(IDS) : near.alertID))
            } else {
                window.append(mark(c))
            }
        }
        if rng.chance(20) { window.append(mark(C(latitude: .nan, longitude: start.longitude))) }
        let sources = CorridorWatchRules.fold(route: route, window: window)
        emit(["fd", enc(route), enc(window), lst(sources.map { $0.map(String.init) ?? "-" })])
    }

    static func main() {
        for _ in 0..<200 { window() }
        for _ in 0..<150 { pace() }
        for _ in 0..<400 { slice() }
        for _ in 0..<200 { reading() }
        for _ in 0..<400 { fold() }
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/stdout"
        FileManager.default.createFile(atPath: path, contents: Data(out.utf8))
    }
}
