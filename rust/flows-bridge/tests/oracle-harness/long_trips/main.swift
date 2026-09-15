import CoreLocation
import Foundation
// Frozen oracle: every output below comes from the ORIGINAL FuelWarning, TripShare (TripShareLogic, DailyDriveLog,
// ShareHistoryStore) and OfflineCorridors (CorridorRetention, OfflineCorridorStore) before their facade switch,
// linked against the Rust bridge for the facades they already call (VehicleProfile.reserveMiles). Doubles are
// IEEE-754 bit patterns in hex; a Date is its timeIntervalSinceReferenceDate; text is "t:" + UTF-8 with bytes outside
// 0x20...0x7E, and the backslash, as \xx; nil is "-"; index lists are "L<n>:" + comma-joined; a point is
// hx(lat)/hx(lon), points join with ";"; stored rows join their fields with U+001F and each other with U+001E.

func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func ht(_ s: String) -> String {
    var o = "t:"
    for b in s.utf8 {
        if b >= 0x20, b <= 0x7E, b != 0x5C { o.unicodeScalars.append(Unicode.Scalar(b)) }
        else { o += "\\" + String(format: "%02x", b) }
    }
    return o
}
func hdo(_ d: Double?) -> String { d.map(hx) ?? "-" }
func lst(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: ",") }
func b(_ v: Bool) -> String { v ? "1" : "0" }
let FS = "\u{1F}", RS = "\u{1E}"
typealias C = CLLocationCoordinate2D
func pt(_ c: C) -> String { hx(c.latitude) + "/" + hx(c.longitude) }
func pts(_ a: [C]) -> String { a.map(pt).joined(separator: ";") }
func tisr(_ d: Date) -> String { hx(d.timeIntervalSinceReferenceDate) }
func at(_ t: Double) -> Date { Date(timeIntervalSinceReferenceDate: t) }
var out = ""
func emit(_ f: String...) { out += f.joined(separator: "\t") + "\n" }

struct SM { var s: UInt64
  mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
  mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
  mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + unit() * (hi - lo) }
  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
  mutating func pick<T>(_ a: [T]) -> T { a[below(a.count)] }
  mutating func chance(_ n: Int) -> Bool { below(n) == 0 } }
var rng = SM(s: 0x4C4F4E4754524950)   // "LONGTRIP"
let SPECIAL: [Double] = [.nan, .infinity, -.infinity, -0.0, 0, .greatestFiniteMagnitude, .leastNonzeroMagnitude]
func dv(_ lo: Double, _ hi: Double, _ extra: [Double] = []) -> Double {
    if rng.chance(8) { return rng.pick(SPECIAL + extra) }
    if !extra.isEmpty, rng.chance(4) { return rng.pick(extra) }
    return rng.range(lo, hi)
}
let centers: [C] = [C(latitude: 43.07, longitude: -89.40), C(latitude: 39.74, longitude: -104.99),
                    C(latitude: 64.84, longitude: -147.72), C(latitude: 0.0, longitude: 179.95),
                    C(latitude: -33.87, longitude: 151.21), C(latitude: 89.9, longitude: 0)]
func near(_ c: C, _ spread: Double) -> C {
    C(latitude: c.latitude + rng.range(-spread, spread), longitude: c.longitude + rng.range(-spread, spread))
}
func index(_ name: String) -> String { String(Int(name.dropFirst())!) }

// ===================================================================== FuelWarning
func bandCode(_ band: FuelWarning.Band) -> String {
    switch band { case .green: return "g"; case .yellow: return "y"; case .red: return "r" }
}
func levelCode(_ level: FuelWarning.Level) -> String {
    switch level { case .none: return "n"; case .lastChances(let r): return "c\(r)"; case .unreachable: return "u" }
}
var fractions: [Double] = SPECIAL + [1, 0.75, 0.5, 0.35, 0.3, 0.25, 0.18, 0.14, 0.13, 0.10, 0, -0.5, 1.5, 2, -1]
for edge in [1 - pow(0.65, 1.0 / 3), 1 - pow(0.35, 1.0 / 3)] {
    var x = edge
    for _ in 0..<8 { x = x.nextDown }
    for _ in 0..<17 { fractions.append(x); x = x.nextUp }
}
for _ in 0..<400 { fractions.append(rng.range(-0.2, 1.2)) }
for f in fractions {
    emit("fw-band", hx(f), hx(FuelWarning.severity(fraction: f)), bandCode(FuelWarning.band(fraction: f)))
}
emit("fw-consts", hx(FuelWarning.aheadConeDegrees), String(FuelWarning.warnAtReachableCount), hx(VehicleProfile.reserveMiles))

func stationsOut(_ s: [FuelWarning.Station]) -> String {
    "N\(s.count):" + s.map { hx($0.milesAhead) + "/" + hdo($0.pricePerUnit) }.joined(separator: ";")
}
for k in 0..<1_125 {
    let n = k < 25 ? 70 : rng.pick([0, 1, 2, 3, 4, 5, 8, 12])
    var st: [FuelWarning.Station] = []
    for i in 0..<n {
        var miles = rng.chance(10) ? rng.pick(SPECIAL + [10, 20, 40]) : rng.pick([rng.range(0, 300), Double(rng.below(40)) * 5])
        if rng.chance(6), !st.isEmpty { miles = rng.pick(st).milesAhead }
        var price: Double? = rng.chance(3) ? nil : rng.pick([rng.range(2.5, 5), 3.19, 3.1905, 3.191, 3.1899, 3.2, 3.49])
        if rng.chance(12) { price = rng.pick(SPECIAL) }
        if rng.chance(6), !st.isEmpty { price = rng.pick(st).pricePerUnit }
        st.append(FuelWarning.Station(name: "S\(i)", milesAhead: miles, pricePerUnit: price))
    }
    let range = rng.chance(8) ? rng.pick(SPECIAL) : rng.pick([rng.range(0, 400), 40, 50, 100, 140, 200])
    let useDefault = rng.chance(2)
    let reserve = useDefault ? VehicleProfile.reserveMiles : rng.pick([0, 40, 10, -5, .nan, .infinity, rng.range(0, 60)])
    let reach = useDefault ? FuelWarning.reachable(stationsAhead: st, rangeMiles: range)
        : FuelWarning.reachable(stationsAhead: st, rangeMiles: range, reserveMiles: reserve)
    let level = useDefault ? FuelWarning.level(stationsAhead: st, rangeMiles: range)
        : FuelWarning.level(stationsAhead: st, rangeMiles: range, reserveMiles: reserve)
    let cheap = useDefault ? FuelWarning.cheapest(stationsAhead: st, rangeMiles: range)
        : FuelWarning.cheapest(stationsAhead: st, rangeMiles: range, reserveMiles: reserve)
    emit("fw-level", stationsOut(st), hx(range), useDefault ? "-" : hx(reserve),
         lst(reach.map { index($0.name) }), levelCode(level), cheap.map { index($0.name) } ?? "-")
}

for k in 0..<700 {
    let c = rng.pick(centers)
    let here = rng.chance(15) ? C(latitude: .nan, longitude: c.longitude) : near(c, 0.5)
    let station = near(c, rng.pick([0.05, 0.3, 1]))
    var course = rng.chance(6) ? rng.pick(SPECIAL + [-1, 0, 360, 720, 100, 260]) : rng.range(0, 360)
    var route: [C] = rng.chance(2) ? [] : (0..<rng.pick([1, 2, 5, 12])).map { _ in near(c, rng.pick([0.05, 0.3])) }
    if k < 200 {
        // On the cone's edge, where only the trig tolerance decides.
        route = []
        let brg = FuelWarning.bearingDegrees(from: here, to: station)
        course = rng.pick([brg + 100, brg - 100, brg + 100 - 360, (brg + 100).nextUp, (brg - 100).nextDown, brg + 260, brg - 260])
    }
    if rng.chance(15), !route.isEmpty { route[rng.below(route.count)] = C(latitude: .nan, longitude: 0) }
    let useDefault = rng.chance(2)
    let corridor = rng.pick([0, 8_000, 500, .nan, .infinity, -1, 20_000])
    let reachable = useDefault
        ? FuelWarning.isReachable(station: station, from: here, courseDegrees: course, routeAhead: route)
        : FuelWarning.isReachable(station: station, from: here, courseDegrees: course, routeAhead: route, corridorMeters: corridor)
    emit("fw-isreach", pt(station), pt(here), hx(course), pts(route), useDefault ? "-" : hx(corridor), b(reachable))
}

// ===================================================================== TripShare
emit("ts-consts", hx(TripShareLogic.longTripMiles), hx(TripShareLogic.metersPerMile),
     String(ShareHistoryStore.maxRecipients), String(ShareHistoryStore.maxDatesPerRecipient))
let limit = TripShareLogic.longTripMiles * TripShareLogic.metersPerMile
var lengths: [Double] = SPECIAL + [1, 200 * 1609.344, 199 * 1609.344, 201 * 1609.344, limit.nextUp, limit.nextDown, limit, -limit]
for _ in 0..<40 { lengths.append(rng.range(0, 700_000)) }
for r in lengths {
    for _ in 0..<5 {
        let d = rng.pick(lengths)
        emit("ts-offer", hx(r), hx(d), b(TripShareLogic.shouldOffer(routeMeters: r, drivenTodayMeters: d)))
    }
}

var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
for _ in 0..<80 {
    var log = DailyDriveLog(day: at(rng.pick([.nan, 0, 8e8, -86_400, rng.range(-1e9, 1e9)])),
                            meters: rng.pick(SPECIAL + [500, rng.range(0, 1e6)]))
    var t = rng.chance(3) ? log.day.timeIntervalSinceReferenceDate.isNaN ? 0 : log.day.timeIntervalSinceReferenceDate : rng.range(-1e9, 1e9)
    for _ in 0..<rng.pick([1, 3, 10]) {
        t += rng.pick([0, 60, 3_600, 86_400, 43_200, -3_600, rng.range(0, 200_000)])
        let when = at(t)
        let today = utc.startOfDay(for: when)
        let delta = dv(-100, 5_000, [0, -0.0, -50])
        let before = log
        log.add(meters: delta, at: when, calendar: utc)
        emit("ts-daily", tisr(before.day), hx(before.meters), tisr(today), hx(delta), tisr(log.day), hx(log.meters))
    }
}

func datesOut(_ d: [Date]) -> String { d.map(tisr).joined(separator: ",") }
for k in 0..<415 {
    let now = rng.pick([0, 8e8, rng.range(-1e9, 1e9)])
    let n = k < 15 ? 70 : rng.pick([0, 1, 2, 3, 5, 12, 13])
    var rs: [ShareRecipient] = []
    for i in 0..<n {
        var dates: [Double]
        if rng.chance(5), !rs.isEmpty {
            dates = rng.pick(rs).shareDates.map(\.timeIntervalSinceReferenceDate)
        } else {
            dates = (0..<rng.pick([0, 1, 2, 3, 5, 10])).map { _ in
                now - rng.pick([0, 86_400, 30 * 86_400, rng.range(-5 * 86_400, 400 * 86_400)])
            }
        }
        if rng.chance(25), !dates.isEmpty { dates[rng.below(dates.count)] = rng.pick([.nan, .infinity, -.infinity, now]) }
        rs.append(ShareRecipient(name: "R\(i)", phone: "555\(i)", shareDates: dates.map(at)))
    }
    let order = TripShareLogic.ranked(rs, now: at(now))
    emit("ts-rank", hx(now), "N\(n):" + rs.map { datesOut($0.shareDates) }.joined(separator: ";"), lst(order.map { index($0.name) }))
}

let phonePool = ["", " ", "+1 (555) 010-2030", "15550102030", "n/a", "555-0100 ext. 12", "\u{FF11}\u{FF12}", "\u{B2}\u{B3}", "\u{BD}",
                 "\u{216B}", "\u{4E09}\u{56DB}", "\u{661}\u{662}\u{663}", "\u{967}\u{968}", "\u{1D7D9}\u{1D7DA}", "1\u{301}2",
                 "1\u{FE0F}\u{20E3}", "\r\n5", "5\r\n", "a1b2", "+44 20 7946 0958", "0", "\u{66B}", "\u{104A0}", "\u{1F51F}",
                 "\u{2466}", "\u{0}9", "e\u{301}7", "7\u{200D}8", "\u{2167}\u{301}", "\u{663}\u{651}\u{64B}", "\u{663}\u{64B}\u{651}",
                 "+", "++1", "9\u{308}", "\u{1100}\u{1161}3", "\u{1F1FA}\u{1F1F8}4"]
func phone() -> String {
    if rng.chance(3) { return rng.pick(phonePool) }
    var s = ""
    for _ in 0..<rng.pick([1, 2, 3, 5]) { s += rng.chance(2) ? rng.pick(phonePool) : String(rng.below(10_000)) }
    return s
}
for p in phonePool { emit("ts-norm", ht(p), ht(ShareHistoryStore.normalized(p))) }
for _ in 0..<300 { let p = phone(); emit("ts-norm", ht(p), ht(ShareHistoryStore.normalized(p))) }

/// UserDefaults that never reads or writes anything: the store's plist path, with no plist.
final class VolatileDefaults: UserDefaults {
    override func data(forKey defaultName: String) -> Data? { nil }
    override func object(forKey defaultName: String) -> Any? { nil }
    override func set(_ value: Any?, forKey defaultName: String) {}
    override func removeObject(forKey defaultName: String) {}
}
func recipientsOut(_ rs: [ShareRecipient]) -> String {
    "N\(rs.count):" + rs.map { [ht($0.name), ht($0.phone), datesOut($0.shareDates)].joined(separator: FS) }.joined(separator: RS)
}
@MainActor func shareStores() {
    for k in 0..<40 {
        let store = ShareHistoryStore(defaults: VolatileDefaults(suiteName: "flows.oracle.volatile")!)
        var t = rng.range(7e8, 9e8)
        var known: [String] = []
        let steps = k < 4 ? 60 : rng.pick([1, 4, 12, 30])
        for step in 0..<steps {
            let name = rng.chance(6) ? "" : rng.pick(["Dana", "Lee", "Sam", "Stranger \(step)", "Ana\u{301}", "An\u{E1}"])
            var number: String
            if rng.chance(2), !known.isEmpty {
                let base = rng.pick(known)
                number = rng.pick([base, ShareHistoryStore.normalized(base), "+" + base, base + " ", "(" + base + ")"])
            } else {
                number = rng.chance(3) ? "555000\(step)" : phone()
                known.append(number)
            }
            if k < 4, rng.chance(3) { number = "555000\(rng.below(20))" }
            t += rng.pick([1, 60, 3_600, 86_400, -3_600, 30 * 86_400, 0])
            store.recordShare(name: name, phone: number, at: at(t))
            // The stored list after every fifth share and the last ("~" between): the Rust replays every share.
            emit("ts-store", String(k), ht(name), ht(number), hx(t),
                 step % 5 == 4 || step == steps - 1 ? recipientsOut(store.recipients) : "~")
        }
        let later = t + rng.pick([0, 86_400, 90 * 86_400])
        let suggested = store.suggestions(now: at(later))
        emit("ts-suggest", String(k), hx(later), lst(suggested.map { s in String(store.recipients.firstIndex(of: s)!) }))
    }
}
await shareStores()

// ===================================================================== OfflineCorridors
emit("oc-consts", hx(CorridorRetention.maxAge), hx(CorridorRetention.arrivedMeters), hx(CorridorRetention.passedMeters),
     String(CorridorRetention.maxStored), hx(CorridorRetention.minTripMeters))
for m in SPECIAL + [6_000, 24_999.999, 25_000, (25_000.0).nextUp, (25_000.0).nextDown, 130_000, -25_000] {
    emit("oc-worth", hx(m), b(CorridorRetention.worthSaving(tripMeters: m)))
}
for _ in 0..<30 {
    let m = rng.range(0, 60_000)
    emit("oc-worth", hx(m), b(CorridorRetention.worthSaving(tripMeters: m)))
}

func line(from a: C, to z: C, n: Int) -> [[Double]] {
    (0..<n).map { i in
        let f = n == 1 ? 1 : Double(i) / Double(n - 1)
        return [a.latitude + (z.latitude - a.latitude) * f, a.longitude + (z.longitude - a.longitude) * f]
    }
}
func damage(_ p: [[Double]]) -> [[Double]] {
    var p = p
    if rng.chance(8), !p.isEmpty { p[rng.below(p.count)] = rng.pick([[], [1.0], [43.0, -89.0, 7.0], [.nan, 0], [0, .nan]]) }
    if rng.chance(12) { p.append(rng.pick([[], [2.0]])) }
    return p
}
func pointsOut(_ p: [[Double]]) -> String {
    "N\(p.count):" + p.map { "\($0.count):" + $0.map(hx).joined(separator: ",") }.joined(separator: ";")
}
func corridorsOut(_ cs: [SavedCorridor]) -> String {
    "N\(cs.count):" + cs.map { [tisr($0.savedAt), ht($0.destinationName), pointsOut($0.points)].joined(separator: FS) }.joined(separator: RS)
}
func corridor(_ saved: Double, _ points: [[Double]], _ name: String = "C") -> SavedCorridor {
    SavedCorridor(id: UUID(), savedAt: at(saved), destinationName: name, points: points)
}

for _ in 0..<1_000 {
    let c = rng.pick(centers)
    let saved = rng.chance(10) ? rng.pick([.nan, .infinity, -.infinity, 0]) : rng.range(7e8, 9e8)
    let age = rng.pick([0, 60, 86_400, 6 * 86_400, 604_800, 604_799.999999, 604_800.000001, 8 * 86_400, -60, .nan, .infinity])
    let points = rng.chance(10) ? rng.pick([[], [[1.0]], [[.nan, 0]], [[]]]) : damage(line(from: near(c, 0.3), to: near(c, rng.pick([0.1, 1, 3])), n: rng.pick([1, 2, 6, 12])))
    let cor = corridor(saved, points)
    let coords = cor.coordinates
    var position: C?
    switch rng.below(6) {
    case 0: position = nil
    case 1: position = coords.last.map { near($0, rng.pick([0.005, 0.0135, 0.014, 0.02])) } ?? near(c, 0.1)
    case 2: position = coords.isEmpty ? near(c, 0.1) : near(rng.pick(coords), rng.pick([0.001, 0.1, 0.27, 0.3]))
    case 3: position = C(latitude: .nan, longitude: 0)
    default: position = near(c, rng.pick([0.5, 2, 5]))
    }
    let now = saved + age
    emit("oc-keep", hx(saved), pointsOut(points), hx(now), position.map(pt) ?? "-",
         b(CorridorRetention.keep(cor, now: at(now), position: position)))
}

for k in 0..<320 {
    let c = rng.pick(centers)
    let n = k < 20 ? 70 : rng.pick([0, 1, 2, 3, 4, 6, 8])
    var cs: [SavedCorridor] = []
    let base = rng.range(7e8, 9e8)
    for _ in 0..<n {
        let saved = rng.chance(5) && !cs.isEmpty ? rng.pick(cs).savedAt.timeIntervalSinceReferenceDate
            : base - rng.pick([0, 60, 3_600, 86_400, 7 * 86_400, 10 * 86_400, rng.range(0, 9 * 86_400)])
        let count = k < 20 ? rng.pick([0, 1, 2]) : rng.pick([0, 1, 2, 6])
        cs.append(corridor(saved, damage(line(from: near(c, 0.3), to: near(c, rng.pick([0.2, 1, 3])), n: count))))
    }
    let now = base + rng.pick([0, 3_600, 86_400])
    let position: C? = rng.chance(4) ? nil : near(c, rng.pick([0.05, 0.5, 2, 6]))
    let kept = CorridorRetention.prune(cs, now: at(now), position: position)
    emit("oc-prune", corridorsOut(cs), hx(now), position.map(pt) ?? "-",
         lst(kept.map { k in String(cs.firstIndex { $0.id == k.id }!) }))
}

for _ in 0..<400 {
    let c = rng.pick(centers)
    let e1 = near(c, 1)
    let e2 = rng.chance(2) ? near(e1, rng.pick([0.001, 0.0135, 0.014, 0.05])) : near(c, 1)
    func one(_ end: C) -> SavedCorridor {
        corridor(8e8, rng.chance(8) ? rng.pick([[], [[1.0]], [[.nan, 0]]]) : damage(line(from: near(c, 0.5), to: end, n: rng.pick([1, 2, 5]))))
    }
    let newer = one(e1), older = one(e2)
    emit("oc-super", newer.destination.map(pt) ?? "-", older.destination.map(pt) ?? "-",
         b(CorridorRetention.supersedes(newer, older)))
}

/// Where each thinned point sits in the input, earliest first. The thinned line is an ordered subsequence of the
/// input, so the earliest bit-identical match always exists; a repeated point may match an earlier copy of itself,
/// which carries the same bits.
func subsequenceIndices(_ part: [C], of whole: [C]) -> [String] {
    var j = 0
    var found: [String] = []
    for q in part {
        while j < whole.count, !(whole[j].latitude.bitPattern == q.latitude.bitPattern
                                 && whole[j].longitude.bitPattern == q.longitude.bitPattern) { j += 1 }
        precondition(j < whole.count, "decimate output is not a subsequence of its input")
        found.append(String(j))
        j += 1
    }
    return found
}
for k in 0..<200 {
    let c = rng.pick(centers)
    var p = c
    var road: [C] = []
    let n = k == 0 ? 1_600 : rng.pick([0, 1, 2, 3, 8, 40, 120])
    let stepDegrees = k == 0 ? 0.0045 : rng.pick([0.0001, 0.001, 0.004, 0.01])
    for _ in 0..<n {
        if rng.chance(10), !road.isEmpty { road.append(road.last!) }
        else {
            p = C(latitude: p.latitude + rng.range(0, stepDegrees), longitude: p.longitude + rng.range(-stepDegrees, stepDegrees) / 4)
            road.append(p)
        }
    }
    if rng.chance(12), !road.isEmpty { road[rng.below(road.count)] = C(latitude: .nan, longitude: 0) }
    let explicit = k > 0 && rng.chance(3)
    let step = rng.pick([400, 0, -1, 50, 1_000, .nan, .infinity])
    let cap = rng.pick([0, 2, 3, 5, 50, 1_200])
    let thin = explicit ? CorridorRetention.decimate(road, stepMeters: step, limit: cap) : CorridorRetention.decimate(road)
    emit("oc-decimate", pts(road), explicit ? hx(step) : "-", explicit ? String(cap) : "-", lst(subsequenceIndices(thin, of: road)))
}

@MainActor func corridorStores() {
    let names = ["Milwaukee", "Home", "", "Caf\u{E9}"]
    for k in 0..<40 {
        let store = OfflineCorridorStore()
        var now = rng.range(7e8, 9e8)
        let c = rng.pick(centers)
        let ends = (0..<3).map { _ in near(c, 1.5) }
        for _ in 0..<(k < 4 ? 40 : rng.pick([1, 4, 10, 25])) {
            now += rng.pick([60, 3_600, 86_400, 3 * 86_400, 8 * 86_400, -3_600])
            switch rng.below(3) {
            case 0:
                let end = rng.chance(2) ? rng.pick(ends) : near(c, 1.5)
                let target = rng.chance(4) ? near(end, 0.01) : end
                let from = near(c, 0.5)
                let road = line(from: from, to: target, n: rng.pick([0, 1, 2, 5, 20])).map { C(latitude: $0[0], longitude: $0[1]) }
                let trip = rng.pick([0, 24_999, 25_000, 130_000, .nan])
                let name = rng.pick(names)
                store.record(coordinates: road, destinationName: name, tripMeters: trip, now: at(now))
                emit("oc-store-record", String(k), pts(road), ht(name), hx(trip), hx(now), corridorsOut(store.corridors))
            case 1:
                let position: C? = rng.chance(4) ? nil : (rng.chance(3) ? rng.pick(ends) : near(c, rng.pick([0.2, 1, 4])))
                store.prune(position: position, now: at(now))
                emit("oc-store-prune", String(k), position.map(pt) ?? "-", hx(now), corridorsOut(store.corridors))
            default:
                let position = rng.chance(10) ? C(latitude: .nan, longitude: 0) : near(c, rng.pick([0.2, 1, 4]))
                let got = store.nearest(to: position)
                emit("oc-store-nearest", String(k), pt(position), corridorsOut(store.corridors),
                     got.flatMap { g in store.corridors.firstIndex { $0.id == g.id } }.map(String.init) ?? "-")
            }
        }
    }
}
await corridorStores()

if CommandLine.arguments.count > 1 {
    FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: out.data(using: .utf8)!)
} else {
    FileHandle.standardOutput.write(out.data(using: .utf8)!)
}
