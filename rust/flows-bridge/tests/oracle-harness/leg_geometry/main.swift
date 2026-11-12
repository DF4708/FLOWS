import CoreLocation
import Foundation

// Frozen oracle: every output below comes from the ORIGINAL Swift `LegGeometry` (LegGeometry.swift), compiled
// with the test target's own Core sources at the base commit. Doubles are IEEE-754 bit patterns in hex; nil is
// "-". A point is "lat,lon"; points are joined by ";" and steps by "|". Lists of numbers are joined by ";".
//
// Kinds (a leg is named by its place in the file, counting `leg` records from 0):
//   leg steps | meters to each point, step ends
//   mt  leg, last match, fix | index, meters off (or "-")
//   pg  leg, matched point, step | step, to the turn, along, left, share left, step length (or "-")
//   ah  leg, point, meters | index (or "-")
//   rw  failures | seconds
//   sm  leg, profile ("start,end,grade" joined by ";") | "index,grade" joined by ";"
//   ct  leg | "w", "a:index" or "b:before:lat:lon"
//   cp  leg, every meters | indices

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

typealias P = CLLocationCoordinate2D
let SP: [Double] = [.nan, .infinity, -.infinity, -0.0, 1e300, .leastNonzeroMagnitude]
func around(_ v: Double) -> [Double] { [v.nextDown, v, v.nextUp] }

/// The double between `lo` and `hi` (both above zero) where `f`, which grows with it, is exactly `target`, if any.
func exactly(_ target: Double, between lo: Double, and hi: Double, _ f: (Double) -> Double) -> Double? {
    var (a, b) = (lo.bitPattern, hi.bitPattern)
    while a < b {
        let mid = a + (b - a) / 2
        if f(Double(bitPattern: mid)) < target { a = mid + 1 } else { b = mid }
    }
    let x = Double(bitPattern: a)
    return f(x) == target ? x : nil
}

@main
@MainActor
enum Oracle {
    static var rng = SM(s: 0x4C45_4747_454F_4D31)  // "LEGGEOM1"
    static var out = ""
    static var legs: [LegGeometry] = []
    static func emit(_ f: [String]) { out += f.joined(separator: "\t") + "\n" }
    static func pt(_ p: P) -> String { "\(hx(p.latitude)),\(hx(p.longitude))" }
    static func ints(_ a: [Int]) -> String { a.map(String.init).joined(separator: ";") }

    /// Cut a run of points into steps, some of them empty.
    static func steps(_ points: [P], most: Int) -> [[P]] {
        var steps: [[P]] = []
        var rest = points[...]
        while !rest.isEmpty {
            if rng.chance(6) { steps.append([]) }
            let take = min(rest.count, 1 + rng.below(most))
            steps.append(Array(rest.prefix(take)))
            rest = rest.dropFirst(take)
        }
        if rng.chance(4) { steps.append([]) }
        return steps
    }

    /// A road: a walk of hops from a few meters to a few hundred, with stretches that stand still, and some
    /// roads that turn round and come back over themselves.
    static func road(_ count: Int) -> [P] {
        var lat = 25 + rng.unit() * 40
        var lon = -120 + rng.unit() * 50
        let scale = rng.pick([0.00002, 0.0002, 0.001, 0.003])
        var dLat = (rng.unit() - 0.3) * scale
        var dLon = (rng.unit() - 0.3) * scale
        var points: [P] = []
        for _ in 0..<count {
            points.append(P(latitude: lat, longitude: lon))
            if rng.chance(9) { continue }  // the next point stands on this one
            if rng.chance(12) {
                dLat = (rng.unit() - 0.3) * scale
                dLon = (rng.unit() - 0.3) * scale
            }
            lat += dLat * (0.5 + rng.unit())
            lon += dLon * (0.5 + rng.unit())
        }
        if rng.chance(3) { points += points.reversed() }
        return points
    }

    /// A short path on a small grid, so hops are equal, points repeat and a half falls exactly on a point.
    static func gridPath() -> [P] {
        let n = rng.below(9)
        let step = rng.pick([0.001, 0.01, 0.5])
        var points: [P] = []
        for _ in 0..<n {
            var p = P(latitude: 40 + Double(rng.below(4)) * step, longitude: -90 + Double(rng.below(3)) * step)
            if rng.chance(25) { p.latitude = rng.pick(SP) }
            if rng.chance(25) { p.longitude = rng.pick(SP) }
            points.append(p)
        }
        return points
    }

    /// Points in a line at equal hops: every cut and tie lands on a point.
    static func ruler() -> [P] {
        let n = 2 + rng.below(9)
        let step = rng.pick([0.001, 0.25])
        let north = rng.chance(2)
        return (0..<n).map {
            P(latitude: 40 + (north ? Double($0) * step : 0), longitude: -90 + (north ? 0 : Double($0) * step))
        }
    }

    static func addLeg(_ s: [[P]]) {
        let leg = LegGeometry(steps: s)
        legs.append(leg)
        emit([
            "leg", s.map { $0.map(pt).joined(separator: ";") }.joined(separator: "|"),
            leg.cumulative.map(hx).joined(separator: ";"), ints(leg.stepEnd),
        ])
    }

    static func anIndex(_ leg: LegGeometry) -> Int {
        let n = leg.points.count
        switch rng.below(10) {
        case 0: return n
        case 1: return n + rng.below(200)
        case 2: return 0
        case 3: return max(n - 1, 0)
        case 4: return leg.stepEnd.isEmpty ? 0 : max(0, rng.pick(leg.stepEnd) + rng.below(3) - 1)
        default: return n == 0 ? 0 : rng.below(n)
        }
    }

    static func match() {
        let id = rng.below(legs.count)
        let leg = legs[id]
        let n = leg.points.count
        var fix = P(latitude: 40, longitude: -90)
        var last = anIndex(leg)
        if n > 0 {
            let at = rng.below(n)
            let p = leg.points[at]
            // Off the road by nothing, a few meters, about the 250 m where the window is lost, or far.
            let off = rng.pick([0, 0.00001, 0.0005, 0.002, 0.00224, 0.00225, 0.0023, 0.004, 0.05, 3])
            fix = P(latitude: p.latitude + off * (rng.chance(2) ? 1 : -1), longitude: p.longitude + off * rng.unit())
            // The last match on and beside the window's two edges around the point.
            if rng.chance(2) {
                last = max(0, at + rng.pick([-81, -80, -79, -78, -40, 0, 5, 11, 12, 13, 14, 60]))
            }
        }
        if rng.chance(30) { fix.latitude = rng.pick(SP) }
        if rng.chance(30) { fix.longitude = rng.pick(SP) }
        let m = leg.match(last: last, fix: fix)
        emit(["mt", String(id), String(last), pt(fix), m.map { String($0.index) } ?? "-", m.map { hx($0.meters) } ?? "-"])
    }

    static func progress() {
        let id = rng.below(legs.count)
        let leg = legs[id]
        let nearest = anIndex(leg)
        let step = rng.chance(5) ? leg.stepEnd.count + rng.below(4) - 1 : rng.below(leg.stepEnd.count + 1)
        let s = max(step, 0)
        guard let p = leg.progress(nearest: nearest, step: s) else {
            emit(["pg", String(id), String(nearest), String(s), "-", "-", "-", "-", "-", "-"])
            return
        }
        emit([
            "pg", String(id), String(nearest), String(s), String(p.step), hx(p.toManeuver), hx(p.along),
            hx(p.remaining), hx(p.fractionLeft), hx(p.stepSpacing),
        ])
    }

    static func ahead() {
        let id = rng.below(legs.count)
        let leg = legs[id]
        let index = anIndex(leg)
        var meters = rng.pick([0, 1, 50, 400, 2_000, 1e7, -30]) * rng.unit()
        // Exactly the meters to a later point: the point itself is far enough.
        if rng.chance(3), index < leg.points.count {
            let later = index + rng.below(leg.points.count - index)
            meters = rng.pick(around(leg.cumulative[later] - leg.cumulative[index]))
        }
        if rng.chance(15) { meters = rng.pick(SP) }
        emit(["ah", String(id), String(index), hx(meters), leg.ahead(from: index, meters: meters).map(String.init) ?? "-"])
    }

    static func steep() {
        let id = rng.below(legs.count)
        let leg = legs[id]
        let miles = (leg.cumulative.last ?? 0) / 1609.344
        var profile: [GradeSegment] = []
        var mile = 0.0
        for _ in 0..<rng.below(rng.chance(6) ? 30 : 8) {
            let length = (miles.isFinite ? miles : 1) * rng.unit() * 0.4 + rng.unit() * 0.01
            var grade = rng.pick([-9, -6.5, 0, 2, 5, 7, 12] + around(6) + around(-6)) + (rng.chance(3) ? rng.unit() : 0)
            if rng.chance(20) { grade = rng.pick(SP) }
            var end = mile + length
            if rng.chance(25) { end = rng.pick(SP) }
            profile.append(GradeSegment(startMile: mile, endMile: end, gradePercent: grade))
            mile += length
        }
        // A stretch standing on one spot whose miles are exactly the meters to a point: the sign stands on that
        // point, not the next.
        if rng.chance(4), leg.points.count > 2 {
            let at = 1 + rng.below(leg.points.count - 1)
            var sum = 0.0
            for i in 1...at { sum += POIRanking.meters(leg.points[i - 1], leg.points[i]) }
            if sum > 0, sum.isFinite, let s = exactly(sum, between: sum / 3_200, and: sum / 800, { $0 * 1609.344 }) {
                profile.insert(GradeSegment(startMile: s, endMile: s, gradePercent: 7), at: 0)
            }
        }
        let marks = LegGeometry.steepMarkerIndices(leg.points, profile: profile)
        emit([
            "sm", String(id),
            profile.map { "\(hx($0.startMile)),\(hx($0.endMile)),\(hx($0.gradePercent))" }.joined(separator: ";"),
            marks.map { "\($0.index),\(hx($0.gradePercent))" }.joined(separator: ";"),
        ])
    }

    static func cut(_ id: Int) {
        let text: String
        switch LegGeometry.cut(legs[id].points) {
        case .whole: text = "w"
        case .at(let i): text = "a:\(i)"
        case .between(let before, let lat, let lon): text = "b:\(before):\(hx(lat)):\(hx(lon))"
        }
        emit(["ct", String(id), text])
    }

    static func checkPoints() {
        let id = rng.below(legs.count)
        let leg = legs[id]
        let total = leg.cumulative.last ?? 0
        var every = (total.isFinite ? total : 1_000) * rng.pick([0.02, 0.1, 0.3, 0.6, 1.2]) * rng.unit()
        // Exactly the meters from the start to a point, added up hop by hop as the rule does.
        if rng.chance(3), leg.points.count > 1 {
            let to = 1 + rng.below(leg.points.count - 1)
            var sum = 0.0
            for i in 1...to { sum += POIRanking.meters(leg.points[i - 1], leg.points[i]) }
            every = rng.pick(around(sum))
        }
        if rng.chance(12) { every = rng.pick(SP + [0, -5]) }
        emit(["cp", String(id), hx(every), ints(LegGeometry.checkPointIndices(leg.points, everyMeters: every))])
    }

    /// A leg going north whose first point is exactly 250 m from a fix due east of it, the farthest the window's
    /// best may be before the whole leg is read, and whose last point is the fix itself: the window's answer
    /// stands.
    static func lostWindowLeg() -> (id: Int, fix: P) {
        for k in 0..<400 {
            let lat = 60 + Double(k) * 0.0137
            let east = { (lon: Double) in POIRanking.meters(P(latitude: lat, longitude: 0), P(latitude: lat, longitude: lon)) }
            guard let lon = exactly(250, between: 0.001, and: 0.02, east) else { continue }
            let fix = P(latitude: lat, longitude: lon)
            addLeg([(0..<120).map { P(latitude: lat + Double($0) * 0.001, longitude: 0) } + [fix]])
            return (legs.count - 1, fix)
        }
        fatalError("no fix exactly 250 m off")
    }

    static func main() {
        addLeg([])
        addLeg([[], []])
        addLeg([[P(latitude: 40, longitude: -90)]])
        addLeg([Array(repeating: P(latitude: 40, longitude: -90), count: 3)])  // a leg standing still
        for _ in 0..<14 { addLeg(steps(road(60 + rng.below(360)), most: 60)) }
        for _ in 0..<30 { addLeg(steps(gridPath(), most: 4)) }
        for _ in 0..<20 { addLeg(steps(ruler(), most: 4)) }
        for _ in 0..<12 { addLeg(steps(road(2 + rng.below(12)), most: 5)) }
        let lost = lostWindowLeg()
        for _ in 0..<1500 { match() }
        let m = legs[lost.id].match(last: 0, fix: lost.fix)
        emit(["mt", String(lost.id), "0", pt(lost.fix), m.map { String($0.index) } ?? "-", m.map { hx($0.meters) } ?? "-"])
        for _ in 0..<1200 { progress() }
        for _ in 0..<700 { ahead() }
        for f in -4..<45 { emit(["rw", String(f), hx(LegGeometry.rerouteWait(failures: f))]) }
        for f in [1_000, 100_000, -100_000] { emit(["rw", String(f), hx(LegGeometry.rerouteWait(failures: f))]) }
        for _ in 0..<500 { steep() }
        for id in legs.indices { cut(id) }
        for _ in 0..<700 { checkPoints() }
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/stdout"
        FileManager.default.createFile(atPath: path, contents: Data(out.utf8))
    }
}
