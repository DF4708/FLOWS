import Foundation

// Frozen oracle: every output below comes from the ORIGINAL Swift `ViewportPointRules`
// (ViewportPointRules.swift), compiled with the test target's own Core sources at the base commit. Doubles are
// IEEE-754 bit patterns in hex; nil is "-". A family list is "name=hex" joined by ";", inputs in the order
// they were drawn, outputs in name order.
//
// Kinds:
//   df score, forecast, fire, seismic, volcanic, avalanche, tropical, tsunami, convective, space radiation,
//      gauge flood, air, uv | families that show, or "-" when the point does not show
//   pt shown, gauge flood, convective, precip risk, alert family, alert severity, closure |
//      families, band input, icon ("f:<family>", "rain", "forecast", "alert", "closure")

func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }

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

let SP: [Double] = [.nan, .infinity, -.infinity, -0.0, -0.3, 1e300, .leastNonzeroMagnitude, 2]
/// A value and its two neighbours, so a floor is met on, just under and just over.
func around(_ v: Double) -> [Double] { [v.nextDown, v, v.nextUp] }
// On and beside every floor: show (0.25), name (0.45), alert (0.6), Yellow (0.699), closure (0.8), and the
// acute nudge's reach (0.05 either side of a tie).
let FLOORS: [Double] = [0.25, 0.45, 0.6, 0.699, 0.8].flatMap(around)
let STEPS: [Double] = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.55, 0.65, 0.7, 0.75, 0.85, 0.9, 0.95, 1]
// Every family the rules name, the two no rule names, and two the tables do not hold.
let FAMILIES = [
    "air", "avalanche", "closure", "cold", "convective", "environmental", "fire", "flood", "heat", "precip",
    "qpf_flood", "radiation", "seismic", "storm", "tropical", "tsunami", "volcanic", "wind", "winter", "smoke",
    "Fire",
]
let ALERTS = [
    "closure", "fire", "flood", "qpf_flood", "seismic", "storm", "tropical", "tsunami", "volcanic", "air",
    "avalanche", "cold", "convective", "heat", "precip", "radiation", "wind", "winter", "smoke",
]

@main
@MainActor
enum Oracle {
    static var rng = SM(s: 0x5649_4557_5054_5253)  // "VIEWPTRS"
    static var out = ""
    static func emit(_ f: [String]) { out += f.joined(separator: "\t") + "\n" }

    /// A score: on a floor, on a step (so families tie), anywhere, or a number that is not one.
    static func score(special n: Int = 14) -> Double {
        if rng.chance(n) { return rng.pick(SP) }
        switch rng.below(4) {
        case 0: return rng.pick(FLOORS)
        case 1, 2: return rng.pick(STEPS)
        default: return rng.unit()
        }
    }
    /// A live reading: quiet most of the time.
    static func reading() -> Double { rng.chance(2) ? 0 : score() }

    /// Up to `most` families, each name once, in drawn order.
    static func families(most: Int) -> [(String, Double)] {
        var names: [String] = []
        for _ in 0..<rng.below(most + 1) {
            let name = rng.pick(FAMILIES)
            if !names.contains(name) { names.append(name) }
        }
        return names.map { ($0, score()) }
    }
    static func list(_ pairs: [(String, Double)]) -> String {
        pairs.map { "\($0.0)=\(hx($0.1))" }.joined(separator: ";")
    }
    static func sorted(_ d: [String: Double]) -> String {
        list(d.keys.sorted().map { ($0, d[$0] ?? .nan) })
    }

    static func display() {
        let forecast = families(most: 6)
        // A low blended score most of the time, so the families decide whether the point shows.
        let s = rng.chance(3) ? score() : rng.pick([0, 0.1, 0.2, 0.2, 0.24] + around(0.25))
        // Quiet families too, so a point with nothing at 0.25 is met.
        let quiet = rng.chance(3)
        let pairs = quiet ? forecast.map { ($0.0, rng.chance(8) ? rng.pick(around(0.25)) : rng.pick([0, 0.1, 0.2, 0.24])) } : forecast
        func live() -> Double { quiet ? rng.pick([0, 0, 0, 0, 0, 0, 0.1, 0.24, (0.25).nextDown, 0.25]) : reading() }
        let l = ViewportPointRules.Live(
            fire: live(), seismic: live(), volcanic: live(), avalanche: live(), tropical: live(), tsunami: live(),
            convective: live(), spaceRadiation: live(), floodRealized: live(),
            air: rng.chance(3) ? nil : live(), uv: live())
        let shown = ViewportPointRules.displayFamilies(
            score: s, forecast: Dictionary(uniqueKeysWithValues: pairs), live: l)
        emit([
            "df", hx(s), list(pairs), hx(l.fire), hx(l.seismic), hx(l.volcanic), hx(l.avalanche), hx(l.tropical),
            hx(l.tsunami), hx(l.convective), hx(l.spaceRadiation), hx(l.floodRealized), l.air.map(hx) ?? "-",
            hx(l.uv), shown.map(sorted) ?? "-",
        ])
    }

    static func point() {
        var shown = families(most: 7)
        var flood = reading()
        // The flood family in front, with the gauges on and beside the floor that tells a flood from rain chance.
        if rng.chance(6) {
            shown.removeAll { $0.0 == "qpf_flood" }
            shown.append(("qpf_flood", rng.pick([0.9, 0.95, 1])))
            flood = rng.pick(around(0.45) + [0.3, 0.47, 0.5])
        }
        // The blended composite in front: it never names the badge.
        if rng.chance(8) {
            shown.removeAll { $0.0 == "environmental" }
            shown.append(("environmental", 1))
        }
        let storms = reading()
        let precip = reading()
        let alert: String? = rng.chance(2) ? nil : rng.pick(ALERTS)
        let severity = alert == nil && !rng.chance(4) ? 0 : score()
        let closed = rng.chance(2) ? 0 : score()
        let p = ViewportPointRules.point(
            families: Dictionary(uniqueKeysWithValues: shown),
            live: ViewportPointRules.Live(convective: storms, floodRealized: flood),
            precipRisk: precip, alertFamily: alert, alertSeverity: severity, closed: closed)
        let icon: String
        switch p.icon {
        case .family(let f): icon = "f:\(f)"
        case .rainChance: icon = "rain"
        case .forecast: icon = "forecast"
        case .alert: icon = "alert"
        case .closure: icon = "closure"
        }
        emit([
            "pt", list(shown), hx(flood), hx(storms), hx(precip), alert ?? "-", hx(severity), hx(closed),
            sorted(p.families), sorted(p.bandInput), icon,
        ])
    }

    static func main() {
        for _ in 0..<1200 { display() }
        for _ in 0..<2400 { point() }
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/stdout"
        FileManager.default.createFile(atPath: path, contents: Data(out.utf8))
    }
}
