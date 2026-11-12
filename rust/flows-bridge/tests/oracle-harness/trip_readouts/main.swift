import Foundation

// Frozen oracle: every output below comes from the ORIGINAL Swift `TripReadouts` (TripReadouts.swift), compiled
// with the test target's own Core sources at the base commit. Doubles are IEEE-754 bit patterns in hex; flags are
// 0 or 1; nil is "-".
//
// Kinds: tf meters, feet | mp meters, places, planner places, miles | sm meters, spoken ("one", "w:<n>",
// "t:<hex>") | mn seconds, minutes | ck seconds, days flag, clock ("m:<n>", "h:<h>:<m>", "d:<hex>") |
// ms eta, faster, minutes saved | xp coverage, meters, percent, miles | gr mile, stretches (start/end/grade
// joined by ";"), grade.

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

let MILE = 1609.344
let SP: [Double] = [
    .nan, .infinity, -.infinity, 0, -0.0, 1e300, -1e300, .leastNonzeroMagnitude, .greatestFiniteMagnitude, -1, 2,
]
/// A value and its two neighbours, so a cut-off is met on, just under and just over.
func around(_ v: Double) -> [Double] { [v.nextDown, v, v.nextUp] }
// Miles on and beside every cut-off: feet/miles (0.19), tenths/whole (9.95, 10), "1 mile" (0.95, 1.05), the
// halves that round a tenth.
let MILES: [Double] = [0, 0.05, 0.1, 0.15, 0.18, 0.19, 0.2, 0.25, 0.95, 1, 1.04, 1.05, 2, 2.05, 5, 9.94, 9.95, 9.96, 10, 10.5, 212.4]
let METERS: [Double] = MILES.flatMap { around($0 * MILE) }
// Feet on the halves of the 50-foot step, and the step itself.
let FEET: [Double] = [0, 10, 24, 25, 26, 50, 74, 75, 76, 100, 125, 175, 450, 475, 975, 1000]
let CLOSE: [Double] = FEET.flatMap { around($0 * 0.3048) }
// Seconds on the half minute, at 90 minutes and at two days.
let SECONDS: [Double] = [
    0, 29, 30, 31, 60, 89, 90, 91, 150, 3_600, 5_339, 5_370, 5_399, 5_400, 5_430, 7_500, 86_400, 172_769, 172_770,
    172_771, 172_800, 933_120, -30, -31, -5_400,
].flatMap(around)
let COVER: [Double] = [0, 0.004, 0.005, 0.006, 0.125, 0.345, 0.5, 0.995, 1, 1.5, -0.005]

@main
@MainActor
enum Oracle {
    static var rng = SM(s: 0x5452_4950_5245_4144)  // "TRIPREAD"
    static var out = ""
    static func emit(_ f: [String]) { out += f.joined(separator: "\t") + "\n" }
    static func special(_ v: Double, _ n: Int = 12) -> Double { rng.chance(n) ? rng.pick(SP) : v }
    /// The original traps turning a number like this into an integer.
    static func traps(_ v: Double) -> Bool { !(v.isFinite && abs(v) < 9e18) }
    static func meters() -> Double {
        switch rng.below(4) {
        case 0: return rng.pick(METERS)
        case 1: return rng.pick(CLOSE)
        case 2: return special(rng.unit() * 40_000 - 200)
        default: return special(rng.unit() * 900_000, 20)
        }
    }

    static func turnFeet() {
        let m = meters()
        if m / MILE < 0.19, traps((m / 0.3048 / 50).rounded() * 50) { return }
        emit(["tf", hx(m), TripReadouts.turnFeet(m).map(String.init) ?? "-"])
    }

    static func places() {
        let m = meters()
        emit([
            "mp", hx(m), String(TripReadouts.milePlaces(m)), String(TripReadouts.plannerMilePlaces(m)),
            hx(TripReadouts.miles(m)),
        ])
    }

    static func spoken() {
        let m = meters()
        let miles = m / MILE
        if traps(miles < 10 ? (miles * 10).rounded() / 10 : miles.rounded()) { return }
        let s: String
        switch TripReadouts.spokenMiles(meters: m) {
        case .one: s = "one"
        case .whole(let n): s = "w:\(n)"
        case .tenths(let t): s = "t:\(hx(t))"
        }
        emit(["sm", hx(m), s])
    }

    static func seconds() -> Double {
        rng.chance(2) ? rng.pick(SECONDS) : special(rng.unit() * (rng.chance(4) ? 2_000_000 : 20_000) - 100)
    }

    static func minutes() {
        let s = seconds()
        if traps((s / 60).rounded()) { return }
        emit(["mn", hx(s), String(TripReadouts.minutes(s))])
    }

    static func clock() {
        let s = seconds()
        if traps((s / 60).rounded()) { return }
        let days = rng.chance(2)
        let c: String
        switch TripReadouts.clock(seconds: s, days: days) {
        case .minutes(let m): c = "m:\(m)"
        case .hours(let h, let m): c = "h:\(h):\(m)"
        case .days(let d): c = "d:\(hx(d))"
        }
        emit(["ck", hx(s), days ? "1" : "0", c])
    }

    static func saved() {
        let faster = rng.chance(2) ? rng.pick(SECONDS) : special(rng.unit() * 40_000)
        var eta = special(faster + rng.unit() * 4_000 - 400)
        if rng.chance(3) { eta = faster + rng.pick([0, 29, 30, 31, 89, 90, 91, 149, 150, 151, 600, -90]) }
        if traps(((eta - faster) / 60).rounded()) { return }
        emit(["ms", hx(eta), hx(faster), String(TripReadouts.minutesSaved(from: eta, to: faster))])
    }

    static func exposure() {
        let c = rng.chance(2) ? rng.pick(COVER) : special(rng.unit())
        // Whole miles and a half: 200 miles at 0.125 is 25, 100 at 0.345 is 34.5.
        let m = rng.chance(3) ? rng.pick([100, 200, 3, 1, 0]) * MILE : meters()
        if traps((c * 100).rounded()) || traps((m / MILE * c).rounded()) { return }
        emit([
            "xp", hx(c), hx(m), String(TripReadouts.exposurePercent(coverage: c)),
            String(TripReadouts.exposureMiles(meters: m, coverage: c)),
        ])
    }

    static func grade() {
        // Whole and half miles so a mile sits on a stretch's end, with stretches that touch, overlap, leave
        // gaps and run backwards.
        let marks: [Double] = [0, 0.5, 1, 1.5, 2, 2.5, 3, 4]
        let n = rng.chance(8) ? 0 : 1 + rng.below(5)
        let p = (0..<n).map { _ -> GradeSegment in
            let a = special(rng.pick(marks), 15)
            let b = rng.chance(6) ? a : special(rng.pick(marks), 15)
            return GradeSegment(startMile: a, endMile: b, gradePercent: special(rng.unit() * 16 - 8, 10))
        }
        let mile = rng.chance(4) ? special(rng.unit() * 4.5 - 0.25, 6) : rng.pick(marks)
        emit([
            "gr", hx(mile), p.map { "\(hx($0.startMile))/\(hx($0.endMile))/\(hx($0.gradePercent))" }.joined(separator: ";"),
            hx(TripReadouts.grade(atMile: mile, in: p)),
        ])
    }

    static func main() {
        for _ in 0..<400 { turnFeet() }
        for _ in 0..<300 { places() }
        for _ in 0..<400 { spoken() }
        for _ in 0..<250 { minutes() }
        for _ in 0..<400 { clock() }
        for _ in 0..<250 { saved() }
        for _ in 0..<250 { exposure() }
        for _ in 0..<400 { grade() }
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/stdout"
        FileManager.default.createFile(atPath: path, contents: Data(out.utf8))
    }
}
