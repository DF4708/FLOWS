import Foundation

// Frozen oracle: every output below comes from the ORIGINAL Swift `SafestRoute`, `CheapestRoute`,
// `EfficientRoute`, `TruckerDesignation` and `FastestRoute` (RouteService.swift), compiled with the test
// target's own Core sources at the base commit. Doubles are IEEE-754 bit patterns in hex; flags are 0 or 1;
// nil is "-"; lists are "L<n>:" + comma-joined items; a pick is the winning candidate's index.
//
// Kinds: sf risks, scored, pick | ch routes (fuel/tolls/walk joined by ";"), pick | ef meters, walk, pick |
// tr routes (clears/highways/avoids/grade/wind/walk/eta joined by ";"), scores, pick | fe etas, fastest |
// cm eta, fastest, chip minutes | kp eta, fastest, key point minutes.

func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func fl(_ b: Bool) -> String { b ? "1" : "0" }
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
let RISKS: [Double] = [0, 0, 0.1, 0.25, 0.25, 0.26, 0.5, 0.5, 0.75, 1]
// Fuel costs a cent, half a cent and the $5 toll allowance apart.
let FUELS: [Double] = [10, 10.005, 10.01, 10.0100001, 10.02, 12, 14.99, 15, 15.0000001, 15.01, 16, 0, 0.4, 31.5]
// Exactly a cent and exactly the allowance apart (0.01 - 0 and 5 - 0 are exact; 10.01 - 10 is not).
let TIGHT: [Double] = [0, 0.01, 0.02, 5, 5.01, 10, 15]
let METERS: [Double] = [0, 1_000, 1_000, 52_300, 52_300.5, 160_934.4, 804_672]
let ETAS: [Double] = [0, 600, 600, 629, 630, 659.9, 660, 660.1, 689.9, 690, 720, 3_600, 3_660, 86_400]

@main
@MainActor
enum Oracle {
    static var rng = SM(s: 0x524F_5554_4544_4553)  // "ROUTEDES"
    static var out = ""
    static func emit(_ f: [String]) { out += f.joined(separator: "\t") + "\n" }
    static func special(_ v: Double, _ n: Int = 12) -> Double { rng.chance(n) ? rng.pick(SP) : v }
    static func count() -> Int { rng.chance(10) ? 0 : rng.chance(6) ? 1 : 2 + rng.below(6) }
    static func at(_ ids: [UUID], _ pick: UUID?) -> String {
        pick.flatMap { ids.firstIndex(of: $0) }.map(String.init) ?? "-"
    }

    static func safest() {
        let n = count()
        // Mostly all scored, as on a finished list; a narrow set of risks so ties are common.
        let allScored = !rng.chance(5)
        let c = (0..<n).map { _ in
            SafestRoute.Candidate(
                id: UUID(), risk: rng.chance(3) ? special(rng.unit(), 8) : rng.pick(RISKS),
                scored: allScored || !rng.chance(3))
        }
        emit(["sf", lst(c.map { hx($0.risk) }), lst(c.map { fl($0.scored) }), at(c.map(\.id), SafestRoute.pick(c))])
    }

    static func cheapest() {
        let n = count()
        let walks = rng.chance(10)
        let tight = rng.chance(3)
        let c = (0..<n).map { _ in
            CheapestRoute.Candidate(
                id: UUID(),
                fuelUSD: tight ? rng.pick(TIGHT) : rng.chance(4) ? special(rng.unit() * 40, 6) : rng.pick(FUELS),
                hasTolls: rng.chance(2), isWalk: walks && rng.chance(2))
        }
        emit([
            "ch", c.map { "\(hx($0.fuelUSD))/\(fl($0.hasTolls))/\(fl($0.isWalk))" }.joined(separator: ";"),
            at(c.map(\.id), CheapestRoute.pick(c)),
        ])
    }

    static func efficient() {
        let n = count()
        let walks = rng.chance(10)
        let c = (0..<n).map { _ in
            EfficientRoute.Candidate(
                id: UUID(), meters: rng.chance(3) ? special(rng.unit() * 900_000, 6) : rng.pick(METERS),
                isWalk: walks && rng.chance(2))
        }
        emit(["ef", lst(c.map { hx($0.meters) }), lst(c.map { fl($0.isWalk) }), at(c.map(\.id), EfficientRoute.pick(c))])
    }

    static func trucker() {
        let n = count()
        let c = (0..<n).map { _ in
            TruckerDesignation.Candidate(
                id: UUID(), clearsBridges: !rng.chance(4), hasHighways: rng.chance(2),
                avoidsHighways: rng.chance(4), gradeOK: !rng.chance(3), windOK: !rng.chance(3),
                eta: rng.chance(3) ? special(rng.unit() * 40_000, 6) : rng.pick(ETAS), isWalk: rng.chance(8))
        }
        emit([
            "tr",
            c.map {
                [
                    fl($0.clearsBridges), fl($0.hasHighways), fl($0.avoidsHighways), fl($0.gradeOK), fl($0.windOK),
                    fl($0.isWalk), hx($0.eta),
                ].joined(separator: "/")
            }.joined(separator: ";"),
            lst(c.map { hx(TruckerDesignation.score($0)) }),
            at(c.map(\.id), TruckerDesignation.pick(c)),
        ])
    }

    static func fastest() {
        let n = count()
        let etas = (0..<n).map { _ in rng.chance(3) ? special(rng.unit() * 40_000, 6) : rng.pick(ETAS) }
        emit(["fe", lst(etas.map(hx)), FastestRoute.eta(etas).map(hx) ?? "-"])
    }

    /// The original traps where the gap is too large for an integer; those inputs are not in the fixture
    /// (the Rust answers them with the largest integer, pinned by its own tests).
    static func behind() {
        let fastest = rng.chance(2) ? rng.pick(ETAS) : special(rng.unit() * 40_000)
        var eta = rng.chance(2) ? rng.pick(ETAS) : special(fastest + rng.unit() * 4_000 - 200)
        if rng.chance(5) { eta = fastest + rng.pick([0, 1, 29, 29.999, 30, 30.001, 59.999, 60, 60.001, 89.999, 90, 120]) }
        let gap = (eta - fastest) / 60
        if eta > fastest, !(gap.isFinite && gap < 9e18) { return }
        emit(["cm", hx(eta), hx(fastest), FastestRoute.chipMinutes(eta: eta, fastest: fastest).map(String.init) ?? "-"])
        emit([
            "kp", hx(eta), hx(fastest),
            FastestRoute.keyPointMinutes(eta: eta, fastest: fastest).map(String.init) ?? "-",
        ])
    }

    static func main() {
        for _ in 0..<300 { safest() }
        for _ in 0..<400 { cheapest() }
        for _ in 0..<200 { efficient() }
        for _ in 0..<400 { trucker() }
        for _ in 0..<150 { fastest() }
        for _ in 0..<300 { behind() }
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/stdout"
        FileManager.default.createFile(atPath: path, contents: Data(out.utf8))
    }
}
