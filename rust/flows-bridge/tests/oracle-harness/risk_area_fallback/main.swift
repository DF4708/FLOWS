import CoreLocation
import Foundation

// Frozen oracle: every output below comes from the ORIGINAL Swift `RiskAreaFallback` (RiskAreaFallback.swift),
// compiled with the test target's own Core sources at the base commit. Doubles are IEEE-754 bit patterns in hex;
// a point is "lat:lon"; a list is its items joined by ",", "" when empty.
//
// Kinds:
//   z   lat, lon, inZIPBox, then blobWaits for (lookupsDone, placedBefore) = 00, 01, 10, 11
//   l   centerLat, centerLon, spanLat, spanLon, perSide, lattice
//   c   lat, lon, radiusMeters, points, circleRing (points "d" is the default argument)
//   r   ring, centroid, iconAnchor, interiorSamples for each limit in LIMITS joined by "|" (the default
//       argument last), the probe points, contains for each probe as "0"/"1"
//
// A lattice the original never finishes (a bound that is infinite, or a multiple of the step too big for a
// step of one to move it) is never asked for: `latticeEnds` says which, the same arithmetic as the original.

func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func pt(_ c: CLLocationCoordinate2D) -> String { hx(c.latitude) + ":" + hx(c.longitude) }
func pts(_ a: [CLLocationCoordinate2D]) -> String { a.map(pt).joined(separator: ",") }
func b01(_ b: Bool) -> String { b ? "1" : "0" }
func C(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

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
    /// Log-uniform in [a, b], a > 0.
    mutating func logRange(_ a: Double, _ b: Double) -> Double { exp(range(log(a), log(b))) }
}

let SPECIAL: [Double] = [
    .nan, .infinity, -.infinity, 0, -0.0, 1e300, -1e300, .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
    .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e-300, 90, -90, 180, -180,
]
let LIMITS = [-1, 0, 1, 2, 3, 5, 9, 16, 17]

func sweep(_ v: Double, _ n: Int) -> [Double] {
    var up = v
    var down = v
    var out = [v]
    for _ in 0..<n {
        up = up.nextUp
        down = down.nextDown
        out += [up, down]
    }
    return out
}

/// Whether the original's lattice loops end, and how many points they make if they do.
func latticeEnds(_ cLat: Double, _ cLon: Double, _ sLat: Double, _ sLon: Double, _ perSide: Int) -> Bool {
    let across = Double(max(perSide, 1))
    func rung(_ wanted: Double) -> Double {
        guard wanted.isFinite, wanted > 0 else { return 1 }
        return pow(2, (2 * log2(wanted)).rounded(.up) / 2)
    }
    func axis(_ c: Double, _ s: Double) -> Double? {
        let step = rung(s / across)
        let a = c - s / 2
        let b = c + s / 2
        if a.isNaN || b.isNaN || step.isInfinite { return 0 }
        if a.isInfinite || b.isInfinite { return nil }
        let i0 = (a / step).rounded(.up)
        let i1 = (b / step).rounded(.down)
        if abs(i0) >= 4e15 || abs(i1) >= 4e15 { return nil }
        return max(0, i1 - i0 + 2)
    }
    guard let nLat = axis(cLat, sLat), let nLon = axis(cLon, sLon) else { return false }
    return nLat * nLon < 400_000
}

@main
@MainActor
enum Oracle {
    static var rng = SM(s: 0x5249_534B_4152_4541)  // "RISKAREA"
    static var out = ""
    static var skipped = 0
    static func emit(_ f: [String]) { out += f.joined(separator: "\t") + "\n" }

    static func box(_ lat: Double, _ lon: Double) {
        let c = C(lat, lon)
        var f = ["z", hx(lat), hx(lon), b01(RiskAreaFallback.inZIPBox(c))]
        for done in [false, true] {
            for placed in [false, true] {
                f.append(b01(RiskAreaFallback.blobWaits(at: c, lookupsDone: done, placedBefore: placed)))
            }
        }
        emit(f)
    }

    static func lattice(_ cLat: Double, _ cLon: Double, _ sLat: Double, _ sLon: Double, _ perSide: Int) {
        guard latticeEnds(cLat, cLon, sLat, sLon, perSide) else {
            skipped += 1
            return
        }
        let l = RiskAreaFallback.lattice(
            centerLatitude: cLat, centerLongitude: cLon, spanLatitude: sLat, spanLongitude: sLon, perSide: perSide)
        emit(["l", hx(cLat), hx(cLon), hx(sLat), hx(sLon), String(perSide), pts(l)])
    }

    static func circle(_ lat: Double, _ lon: Double, _ r: Double, _ points: Int?) {
        let ring =
            points.map { RiskAreaFallback.circleRing(center: C(lat, lon), radiusMeters: r, points: $0) }
            ?? RiskAreaFallback.circleRing(center: C(lat, lon), radiusMeters: r)
        emit(["c", hx(lat), hx(lon), hx(r), points.map(String.init) ?? "d", pts(ring)])
    }

    /// Points worth asking `contains` about: every vertex, every edge's middle and ends nudged, the centroid,
    /// a grid over the box and past it, points at a vertex's latitude, and random ones.
    static func probes(_ ring: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var p: [CLLocationCoordinate2D] = []
        let n = ring.count
        let finite = ring.filter { $0.latitude.isFinite && $0.longitude.isFinite }
        for (k, v) in ring.enumerated() where k < 8 {
            p.append(v)
            let w = ring[(k + 1) % n]
            p.append(C((v.latitude + w.latitude) / 2, (v.longitude + w.longitude) / 2))
            p.append(C(v.latitude, v.longitude.nextUp))
            p.append(C(v.latitude.nextDown, v.longitude))
        }
        p.append(RiskAreaFallback.centroid(of: ring))
        p.append(C(0, 0))
        p.append(C(.nan, 0))
        if let la0 = finite.map(\.latitude).min(), let la1 = finite.map(\.latitude).max(),
            let lo0 = finite.map(\.longitude).min(), let lo1 = finite.map(\.longitude).max()
        {
            for i in 0..<5 {
                for j in 0..<5 {
                    p.append(C(la0 + (la1 - la0) * Double(i - 1) / 2.5, lo0 + (lo1 - lo0) * Double(j - 1) / 2.5))
                }
            }
            for _ in 0..<10 {
                p.append(C(rng.range(la0, la1), rng.range(lo0, lo1)))
            }
            if let v = finite.randomElement(using: &rng) {
                for _ in 0..<4 { p.append(C(v.latitude, rng.range(lo0, lo1))) }
            }
        }
        return p
    }

    static func ring(_ ring: [CLLocationCoordinate2D]) {
        let samples = LIMITS.map { pts(RiskAreaFallback.interiorSamples(of: ring, limit: $0)) }
            + [pts(RiskAreaFallback.interiorSamples(of: ring))]
        let probe = probes(ring)
        emit([
            "r", pts(ring), pt(RiskAreaFallback.centroid(of: ring)), pt(RiskAreaFallback.iconAnchor(of: ring)),
            samples.joined(separator: "|"), pts(probe),
            probe.map { b01(RiskAreaFallback.contains(ring, $0)) }.joined(),
        ])
    }

    // ---- ring makers ----------------------------------------------------------------------------------------

    static func usCenter() -> (Double, Double) { (rng.range(25, 49), rng.range(-124, -67)) }

    /// A star around a center: random radius per vertex, angles in order (either way round).
    static func star(_ n: Int, _ size: Double) -> [CLLocationCoordinate2D] {
        let (la, lo) = usCenter()
        let dir = rng.chance(2) ? 1.0 : -1.0
        let start = rng.range(0, 2 * .pi)
        return (0..<n).map { k in
            let a = start + dir * 2 * .pi * Double(k) / Double(n)
            let r = size * rng.range(0.2, 1)
            return C(la + r * sin(a), lo + r * 1.3 * cos(a))
        }
    }

    /// A crescent: an outer arc out and an inner arc back, so the centroid often falls outside.
    static func crescent(_ n: Int, _ size: Double) -> [CLLocationCoordinate2D] {
        let (la, lo) = usCenter()
        let sweepAngle = rng.range(.pi * 0.8, .pi * 1.9)
        let turn = rng.range(0, 2 * .pi)
        let inner = size * rng.range(0.3, 0.9)
        let shift = size * rng.range(0, 0.4)
        var r: [CLLocationCoordinate2D] = []
        for k in 0...n {
            let a = turn + sweepAngle * Double(k) / Double(n)
            r.append(C(la + size * sin(a), lo + size * cos(a)))
        }
        for k in stride(from: n, through: 0, by: -1) {
            let a = turn + sweepAngle * Double(k) / Double(n)
            r.append(C(la + shift * sin(turn) + inner * sin(a), lo + shift * cos(turn) + inner * cos(a)))
        }
        return r
    }

    /// A comb: a thin base and `teeth` long teeth, so a line across it meets many edges.
    static func comb(_ teeth: Int, _ size: Double) -> [CLLocationCoordinate2D] {
        let (la, lo) = usCenter()
        let w = size / Double(2 * teeth)
        let base = size * rng.range(0.02, 0.3)
        var r = [C(la, lo)]
        for t in 0..<teeth {
            let x = lo + Double(2 * t) * w
            r.append(C(la + base + size, x))
            r.append(C(la + base + size, x + w))
            r.append(C(la + base, x + w))
            r.append(C(la + base, x + 2 * w))
        }
        r.append(C(la, lo + size))
        return rng.chance(2) ? r : r.reversed()
    }

    static func randomPoints(_ n: Int, _ size: Double) -> [CLLocationCoordinate2D] {
        let (la, lo) = usCenter()
        return (0..<n).map { _ in C(la + rng.range(-size, size), lo + rng.range(-size, size)) }
    }

    static func rect(_ la0: Double, _ lo0: Double, _ la1: Double, _ lo1: Double) -> [CLLocationCoordinate2D] {
        [C(la0, lo0), C(la0, lo1), C(la1, lo1), C(la1, lo0)]
    }

    static func main() {
        let args = CommandLine.arguments

        // The ZIP box: its edges and the floats beside them, the specials, and random points.
        let latEdge = sweep(24, 2) + sweep(50, 2) + [37, 0, -24, 24.5, 49.99]
        let lonEdge = sweep(-125, 2) + sweep(-66, 2) + [-95, 0, 125, 66, -124.9]
        for la in latEdge + SPECIAL {
            for lo in lonEdge + SPECIAL { box(la, lo) }
        }
        for _ in 0..<600 { box(rng.range(10, 60), rng.range(-140, -50)) }

        // The lattice: map views as the app makes them, then the edges.
        let perSides = [-3, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12]
        for _ in 0..<400 {
            let (la, lo) = rng.chance(5) ? (rng.range(-89, 89), rng.range(-179, 179)) : usCenter()
            let sLat = rng.logRange(0.001, 60)
            let sLon = rng.chance(3) ? sLat * rng.range(0.5, 3) : rng.logRange(0.001, 120)
            lattice(la, lo, sLat, sLon, rng.pick(perSides))
        }
        // Spans on a rung exactly, and beside it: the ceiling and whole multiples decide.
        for k in -12...10 {
            let w = pow(2, Double(k) / 2)
            for s in sweep(w, 1) {
                for per in [1, 3, 8] {
                    lattice(37.0, -95.0, s * Double(per), s * Double(per), per)
                    lattice(rng.range(25, 49), rng.range(-124, -67), s * Double(per), s * Double(per) * 2, per)
                }
            }
        }
        // Centers and spans that put a bound on a multiple, zero and negative spans, and the specials.
        for (la, lo) in [(0.0, 0.0), (-0.0, -0.0), (45, -90), (44.5, -89.5), (0.25, -0.25), (-30, 150), (89.9, 179.9)] {
            for s in [0.0, -0.0, -1, -10, 0.5, 1, 2, 1.5, 4, 90, 180, 360] {
                for per in [0, 1, 2, 5, 8] {
                    lattice(la, lo, s, s, per)
                    lattice(la, lo, s, 1, per)
                }
            }
        }
        for v in SPECIAL {
            for per in [0, 1, 8] {
                lattice(v, -95, 1, 1, per)
                lattice(37, v, 1, 1, per)
                lattice(37, -95, v, 2, per)
                lattice(37, -95, 2, v, per)
                lattice(v, v, v, v, per)
            }
        }

        // The circle: the app's radii and point counts, the poles, and the specials.
        let counts: [Int?] = [nil, -5, 0, 1, 2, 3, 4, 5, 8, 31, 32, 33, 64, 100]
        for _ in 0..<250 {
            let (la, lo) = rng.chance(4) ? (rng.range(-90, 90), rng.range(-180, 180)) : usCenter()
            circle(la, lo, rng.logRange(1, 300_000), rng.pick(counts))
        }
        for la in [0.0, -0.0, 45, 60, 89, 89.99999, 90, -90, 90.0.nextUp, 179, 180, 270, -45] {
            for r in [0.0, -0.0, 1, 5_000, 80_000, -1_000] {
                for n in [nil, 3, 4, 7] as [Int?] { circle(la, -100, r, n) }
            }
        }
        for v in SPECIAL {
            circle(v, -95, 5_000, nil)
            circle(37, v, 5_000, 6)
            circle(37, -95, v, 5)
            circle(v, v, v, 3)
        }

        // Rings: shapes of every kind, then the degenerate and the non-finite.
        for _ in 0..<80 { ring(star(3 + rng.below(60), rng.logRange(0.001, 3))) }
        for _ in 0..<90 { ring(crescent(3 + rng.below(30), rng.logRange(0.005, 2))) }
        for _ in 0..<50 { ring(comb(2 + rng.below(29), rng.logRange(0.01, 2))) }
        for _ in 0..<60 { ring(randomPoints(3 + rng.below(20), rng.logRange(0.001, 2))) }
        for _ in 0..<50 {
            // Closed the GeoJSON way: the first vertex again at the end.
            let r = rng.chance(2) ? star(3 + rng.below(25), rng.logRange(0.01, 1)) : crescent(4 + rng.below(12), 0.5)
            ring(r + [r[0]])
        }
        for _ in 0..<40 {
            // Repeated vertices.
            var r = star(4 + rng.below(12), rng.logRange(0.01, 1))
            for _ in 0..<(1 + rng.below(4)) {
                let k = rng.below(r.count)
                r.insert(r[k], at: k)
            }
            ring(r)
        }
        // Rectangles, whose grid points and probes fall on edges and on whole numbers.
        for (a, b, c, d) in [
            (0.0, 0.0, 1.0, 1.0), (40, -100, 41, -99), (40, -100, 40.5, -98), (-1, -1, 1, 1), (24, -125, 50, -66),
            (30, -90, 30.25, -89.75), (0, 0, 4, 4), (10, 10, 10, 11), (10, 10, 11, 10),
        ] as [(Double, Double, Double, Double)] {
            ring(rect(a, b, c, d))
            ring(rect(a, b, c, d).reversed())
            ring(rect(c, d, a, b))
        }
        // Few vertices, collinear, all one point, tiny area about the 1e-12 line.
        ring([])
        ring([C(40, -100)])
        ring([C(40, -100), C(41, -99)])
        ring([C(40, -100), C(40, -100), C(40, -100)])
        ring([C(40, -100), C(41, -99), C(42, -98)])
        ring([C(40, -100), C(40, -99), C(40, -98)])
        ring([C(40, -100), C(41, -100), C(42, -100), C(43, -100)])
        ring([C(0, 0), C(0, 0), C(-0.0, -0.0)])
        ring([C(-0.0, -0.0), C(-0.0, -0.0), C(-0.0, -0.0)])
        ring([C(-0.0, 0), C(0, -0.0), C(-0.0, -0.0), C(0, 0)])
        for e in [1e-5, 1e-6, 1.4e-6, 1.5e-6, 2e-6, 1e-7, 3e-6] {
            ring([C(0, 0), C(e, 0), C(0, e)])
            ring([C(40, -100), C(40 + e, -100), C(40, -100 + e)])
            ring([C(40, -100), C(40, -100 + e), C(40 + e, -100)])
        }
        for _ in 0..<60 {
            let k = 3 + rng.below(8)
            let e = rng.logRange(1e-8, 1e-5)
            ring((0..<k).map { _ in C(rng.range(0, e), rng.range(0, e)) })
            let (la, lo) = usCenter()
            ring((0..<k).map { i in C(la + Double(i) * e, lo + Double(i) * e * 2) })
        }
        // Non-finite and huge coordinates in every place.
        for v in SPECIAL {
            for at in 0..<4 {
                var r = rect(40, -100, 41, -99)
                r[at] = rng.chance(2) ? C(v, r[at].longitude) : C(r[at].latitude, v)
                ring(r)
            }
            ring(rect(v, v, 41, -99))
            ring(star(5, 0.5) + [C(v, v)])
            ring([C(v, -100), C(41, v), C(v, v)])
        }
        for _ in 0..<60 {
            var r = comb(11 + rng.below(15), 1)
            for _ in 0..<(1 + rng.below(3)) {
                let k = rng.below(r.count)
                r[k] = rng.chance(2) ? C(rng.pick(SPECIAL), r[k].longitude) : C(r[k].latitude, rng.pick(SPECIAL))
            }
            ring(r)
        }
        // A ring that crosses itself so the even-odd rule matters: a bow tie and a pentagram.
        ring([C(0, 0), C(1, 1), C(1, 0), C(0, 1)])
        ring((0..<5).map { k in
            let a = Double(k * 2) * 2 * .pi / 5
            return C(40 + sin(a), -100 + cos(a))
        })
        ring((0..<7).map { k in
            let a = Double(k * 3) * 2 * .pi / 7
            return C(40 + sin(a), -100 + cos(a))
        })

        FileHandle.standardError.write(Data("skipped lattices: \(skipped)\n".utf8))
        FileManager.default.createFile(atPath: args[1], contents: Data(out.utf8))
    }
}

extension SM: RandomNumberGenerator {}
