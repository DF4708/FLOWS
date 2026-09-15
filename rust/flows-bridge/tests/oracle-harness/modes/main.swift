import CoreLocation
import Foundation
// Frozen oracle: every output below comes from the ORIGINAL SignalQuality, AdaptiveTuning, PlaybackFallback,
// PlaybackGrace, RadioTuning, AmtrakStations, BreadcrumbTrail, AirTravel, Mobility (TrafficCadence, RiskBlob,
// TransitFares) and HybridWalk at commit bea472d, the last before their facade switch, linked against the Rust
// bridge for the facades they already call (POIRanking.meters stays Swift). Doubles are IEEE-754 bit patterns in
// hex; text is "t:" + UTF-8 with bytes outside 0x20...0x7E, and the backslash, as \xx; nil is "-"; lists are
// "L<n>:" + comma-joined items; a point is hx(lat)/hx(lon), points join with ";"; items carrying text join their
// fields with U+001F and each other with U+001E.

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
func hdo(_ d: Double?) -> String { d.map(hx) ?? "-" }
func lst(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: ",") }
func b(_ v: Bool) -> String { v ? "1" : "0" }
let FS = "\u{1F}", RS = "\u{1E}"
typealias C = CLLocationCoordinate2D
func pt(_ c: C) -> String { hx(c.latitude) + "/" + hx(c.longitude) }
func pts(_ a: [C]) -> String { a.map(pt).joined(separator: ";") }
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
var rng = SM(s: 0x4D4F44455354524C)   // "MODESTRL"
let SPECIAL: [Double] = [.nan, .infinity, -.infinity, -0.0, 0, .greatestFiniteMagnitude, .leastNonzeroMagnitude]
func dv(_ lo: Double, _ hi: Double, _ extra: [Double] = []) -> Double {
    if rng.chance(8) { return rng.pick(SPECIAL + extra) }
    if !extra.isEmpty, rng.chance(4) { return rng.pick(extra) }
    return rng.range(lo, hi)
}
func odv(_ lo: Double, _ hi: Double, _ extra: [Double] = []) -> Double? { rng.chance(5) ? nil : dv(lo, hi, extra) }
let textPool = ["", " ", "\n", "rock", " rock ", "\u{A0}jazz\u{3000}", "hip hop\n", "\u{2028}", "classic\u{301}", "country",
  "CTRadioAccessTechnologyLTE", "CTRadioAccessTechnologyNRNSA", "CTRadioAccessTechnologyNR", "CTRadioAccessTechnologyEdge",
  "CTRadioAccessTechnologyGPRS", "CTRadioAccessTechnologyCDMA1x", "CTRadioAccessTechnologyWCDMA", "CTRadioAccessTechnologyHSDPA",
  "CTRadioAccessTechnologyHSUPA", "CTRadioAccessTechnologyCDMAEVDORev0", "CTRadioAccessTechnologyeHRPD", "LTE", "nr", "N\u{301}R",
  "\u{212A}", "edge\u{200B}", "e\u{301}dge", "HS", "hs", "1X", "\u{130}", "ED\u{0}GE", "wi-fi", "5G", "unknown",
  "Heliport", "International Airport", "O'Hare International", "Mitchell Airport", "Dane County Regional Airport",
  "Truax Field AFB", "Naval Air Station", "Army Airfield", "Seaplane Base", "Lake Airpark", "Air Park Estates",
  "INTERNATIONAL", "Internationa\u{301}l Airport", "airport", "Balloonport", "Air Force Base", "Afb", "helipad", "Army", "\u{1F6EB} Airport"]
func text() -> String {
    if rng.chance(4) { return [rng.pick(textPool), rng.pick(textPool)].joined(separator: rng.pick(["", " ", "-"])) }
    return rng.pick(textPool)
}

// ===================================================================== SignalQuality
let tiers: [SignalQuality.Tier] = [.strong, .fair, .weak, .offline]
var techs: [String?] = [nil] + textPool
for _ in 0..<150 { techs.append(rng.chance(6) ? nil : text()) }
for t in techs { for wifi in [false, true] { for off in [false, true] {
    emit("sq-tier", hto(t), b(wifi), b(off), SignalQuality.tier(radioTechnology: t, onWiFi: wifi, offline: off).rawValue)
} } }
for t in tiers { for d in [false, true] { for s in [Int.min, -1, 0, 1, 2, Int.max] {
    emit("sq-prestage", t.rawValue, b(d), String(s), b(SignalQuality.shouldPreStage(tier: t, bufferDraining: d, recentStalls: s)))
} } }
for _ in 0..<300 {
    let p = odv(-5, 60, [1, 2, 3.5]), c = odv(-5, 60, [0, 1, 2.5])
    emit("sq-drain", hdo(p), hdo(c), b(SignalQuality.isDraining(previous: p, current: c)))
}

// ===================================================================== AdaptiveTuning
for cores in [Int.min, -1, 0, 1, 2, 3, 4, 5, 6, 8, 10, 64, Int.max] {
    for mem in [Double.nan, .infinity, -.infinity, -1, 0, 2, 2.99, 3, 3.5, 4.49, 4.5, 6, 8, 64, 1e300] {
        emit("at-base", String(cores), hx(mem), String(AdaptiveTuning.baseTier(cores: cores, memoryGB: mem).rawValue))
    }
}
for tier in [AdaptiveTuning.Tier.low, .standard, .high] { for raw in [0, 1, 2, 3, 7] { for lp in [false, true] {
    let s = AdaptiveTuning.settings(tier: tier, thermal: ProcessInfo.ThermalState(rawValue: raw)!, lowPower: lp)
    emit("at-settings", String(tier.rawValue), String(raw), b(lp),
         [String(s.maxInFlight), String(s.planningMaxInFlight), String(s.viewportGridSpan), hx(s.ttlMultiplier), hx(s.debounceSeconds)].joined(separator: "/"))
} } }

// ===================================================================== PlaybackFallback / PlaybackGrace
func sourceOut(_ s: PlaybackFallback.Source) -> String {
    switch s {
    case .localLibrary: return "local"
    case .radio(let g): return "radio" + FS + ht(g)
    case .nothingAvailable: return "nothing"
    case .keepPlaying: return "keep"
    }
}
for _ in 0..<400 {
    let playing = rng.chance(4) ? false : true, net = rng.chance(4) ? false : true, local = rng.chance(2)
    let genre: String? = rng.chance(5) ? nil : text()
    emit("pf-lost", b(playing), b(net), b(local), hto(genre),
         sourceOut(PlaybackFallback.onConnectionLost(isPlaying: playing, needsNetwork: net, hasLocalMusic: local, lastGenre: genre)))
}
for h in [false, true] { for c in [false, true] { for d in [false, true] {
    emit("pf-restore", b(h), b(c), b(d), b(PlaybackFallback.shouldRestore(handedOff: h, connectionHeld: c, driverChoseSince: d)))
} } }
emit("pf-consts", hx(PlaybackFallback.restoreHoldSeconds))
let graceSources: [(String, PlaybackGrace.Source)] = [("radio", .radio), ("apple", .appleMusicCloud), ("spotify", .spotify), ("other", .otherApp)]
for (name, src) in graceSources {
    for buf in [nil, Double.nan, .infinity, -.infinity, -1, 0, 3.99, 4, 4.01, 20, 44.9, 45, 46, 1e9, -0.0] as [Double?] {
        emit("pg-grace", name, hdo(buf), hx(PlaybackGrace.graceSeconds(for: src, measuredBuffer: buf)))
    }
    emit("pg-grace", name, "default", hx(PlaybackGrace.graceSeconds(for: src)))
}
emit("pg-consts", [PlaybackGrace.radioFloorSeconds, PlaybackGrace.radioCapSeconds, PlaybackGrace.appleMusicCapSeconds,
                   PlaybackGrace.spotifyCapSeconds, PlaybackGrace.otherAppWatchSeconds].map(hx).joined(separator: "/"))

// ===================================================================== RadioTuning / AmtrakStations
let centers: [C] = [C(latitude: 43.07, longitude: -89.4), C(latitude: 41.88, longitude: -87.63), C(latitude: 61.2, longitude: -149.9),
                    C(latitude: 0, longitude: 179.99), C(latitude: -33.9, longitude: 151.2)]
func near(_ c: C, _ s: Double) -> C { C(latitude: c.latitude + rng.range(-s, s), longitude: c.longitude + rng.range(-s, s) * 1.3) }
func stationsOut(_ st: [RadioTuning.Station]) -> String {
    st.map { [ht($0.id), pt($0.coordinate), b($0.isExact)].joined(separator: FS) }.joined(separator: RS)
}
for _ in 0..<500 {
    let c = rng.pick(centers)
    let n = rng.pick([0, 1, 2, 3, 6, 15])
    var st: [RadioTuning.Station] = []
    for i in 0..<n {
        let coord = rng.chance(6) && !st.isEmpty ? rng.pick(st).coordinate : (rng.chance(15) ? C(latitude: .nan, longitude: 0) : near(c, rng.pick([0.2, 1.5, 6])))
        st.append(RadioTuning.Station(id: rng.chance(8) && !st.isEmpty ? rng.pick(st).id : "K\(i)", coordinate: coord, isExact: !rng.chance(3)))
    }
    let position = rng.chance(12) ? C(latitude: .nan, longitude: .nan) : near(c, rng.pick([0.1, 1, 4]))
    let got = RadioTuning.nearest(to: position, in: st)
    let idx = got.flatMap { g in st.firstIndex(of: g.station) }
    emit("rt-nearest", pt(position), stationsOut(st), idx.map { "\($0)/" + hx(got!.meters) } ?? "-")
    let playing: String? = rng.chance(5) ? nil : (st.isEmpty || rng.chance(4) ? "K99" : rng.pick(st).id)
    let playingCoord: C? = rng.chance(4) ? nil : (st.isEmpty ? near(c, 2) : rng.pick(st).coordinate)
    emit("rt-retarget", hto(playing), playingCoord.map(pt) ?? "-", pt(position), stationsOut(st),
         hto(RadioTuning.retarget(playingID: playing, playingCoordinate: playingCoord, position: position, stations: st)))
}
emit("rt-consts", hx(RadioTuning.switchMargin))
for _ in 0..<400 {
    let c = rng.pick(centers)
    var st: [AmtrakStation] = []
    for i in 0..<rng.pick([0, 1, 2, 5, 20]) {
        let q = rng.chance(6) && !st.isEmpty ? rng.pick(st).coordinate : near(c, rng.pick([0.3, 2, 8]))
        st.append(AmtrakStation(code: "S\(i % 7)", name: "Station \(i % 5)", lat: rng.chance(20) ? .nan : q.latitude, lon: q.longitude))
    }
    let p = near(c, rng.pick([0.2, 1, 5]))
    let maxM = rng.pick([0.0, 1_000, 25_000, 240_000, .infinity, .nan, -1])
    let got = AmtrakStations.nearest(to: p, within: maxM, in: st)
    emit("am-nearest", pt(p), hx(maxM), st.map { [ht($0.code), ht($0.name), hx($0.lat), hx($0.lon)].joined(separator: FS) }.joined(separator: RS),
         got.flatMap { g in st.firstIndex(of: g) }.map(String.init) ?? "-")
}

// ===================================================================== BreadcrumbTrail
for _ in 0..<400 {
    let c = rng.pick(centers)
    let p = rng.chance(10) ? C(latitude: rng.pick(SPECIAL + [0.00005, -0.0001, 0.0001, 0.00011]), longitude: rng.pick(SPECIAL + [0.0001, -0.00009])) : near(c, 0.001)
    let last: C? = rng.chance(5) ? nil : (rng.chance(10) ? C(latitude: .nan, longitude: 0) : near(p.latitude.isFinite ? p : c, rng.pick([0.0001, 0.0002, 0.0003, 0.01])))
    emit("bc-should", pt(p), last.map(pt) ?? "-", b(BreadcrumbTrail.shouldRecord(p, after: last)))
}
emit("bc-consts", hx(BreadcrumbTrail.minStepMeters), String(BreadcrumbTrail.maxPoints))
@MainActor func trails() {
    for k in 0..<12 {
        let trail = BreadcrumbTrail()
        var p = rng.pick(centers)
        let steps = k == 11 ? 6_300 : rng.pick([0, 1, 2, 10, 80, 300])
        var fed: [C] = []
        for _ in 0..<steps {
            p = C(latitude: p.latitude + rng.range(-0.0006, 0.0006), longitude: p.longitude + rng.range(-0.0006, 0.0006))
            let q = rng.chance(30) ? C(latitude: .nan, longitude: p.longitude) : p
            fed.append(q)
            trail.record(q)
        }
        let back = trail.wayBack()
        emit("bc-trail", String(k), k == 11 ? "long" : pts(fed), String(trail.points.count), hx(back.meters),
             back.path.first.map(pt) ?? "-", back.path.last.map(pt) ?? "-", k == 11 ? pts(fed) : "")
    }
}
await trails()

// ===================================================================== AirTravel
let miles: [Double] = SPECIAL + [-1, 0, 1, 59.9, 60, 99.99, 100, 100.01, 181, 450, 1_000, 2_700, 1e7]
for m in miles + (0..<80).map({ _ in rng.range(0, 3_000) }) {
    emit("air-miles", hx(m), b(AirTravel.worthFlying(tripMiles: m)), hx(AirTravel.flightSeconds(airportMiles: m)),
         hx(AirTravel.doorSeconds(airportMiles: m)), hx(AirTravel.fareEstimate(airportMiles: m)))
}
var airNames = textPool
for _ in 0..<150 { airNames.append(text()) }
for n in airNames { emit("air-score", ht(n), AirTravel.airportScore(name: n).map(String.init) ?? "-") }
for _ in 0..<400 {
    let cands = (0..<rng.pick([0, 1, 2, 4, 9])).map { _ in AirTravel.Candidate(name: rng.chance(3) ? rng.pick(airNames) : text(), meters: rng.chance(10) ? rng.pick(SPECIAL) : rng.pick([10_000, 20_000, rng.range(0, 150_000)])) }
    let maxM = rng.pick([0.0, 50_000, 80_000, 160_000, .infinity, .nan])
    emit("air-pick", cands.map { ht($0.name) + FS + hx($0.meters) }.joined(separator: RS), hx(maxM),
         AirTravel.pickIndex(cands, maxMeters: maxM).map(String.init) ?? "-")
}
emit("air-consts", [AirTravel.minTripMiles, AirTravel.minAirportGapMiles, AirTravel.boardBufferSeconds, AirTravel.alightBufferSeconds].map(hx).joined(separator: "/"))

// ===================================================================== Mobility: TrafficCadence, RiskBlob, TransitFares
for m in [Int.min, -1, 0, 419, 420, 539, 540, 689, 690, 779, 780, 869, 870, 959, 960, 989, 990, 1109, 1110, 1439, 1440, Int.max] {
    emit("tc-peak", String(m), b(TrafficCadence.isPeak(localMinutes: m)))
}
for _ in 0..<500 {
    let ref = rng.pick([0.0, -978_307_200, 1e9, -1e9, 8.1e8, rng.range(-3e9, 3e9), 86_399.999, -0.0])
    let lon = rng.chance(8) ? rng.pick([-180.0, 180, 0, -0.0, 1e6, -1e6, 179.999]) : rng.range(-180, 180)
    let now = Date(timeIntervalSinceReferenceDate: ref)
    emit("tc-local", hx(ref), hx(lon), String(TrafficCadence.localMinutes(now: now, longitude: lon)),
         hx(TrafficCadence.intervalSeconds(now: now, longitude: lon)))
}
emit("tc-consts", hx(TrafficCadence.peakSeconds), hx(TrafficCadence.offPeakSeconds))
for _ in 0..<250 {
    let c = rng.pick(centers)
    let n = rng.pick([0, 1, 2, 3, 5, 12, 30])
    var ps: [C] = []
    for _ in 0..<n { ps.append(rng.chance(6) && !ps.isEmpty ? rng.pick(ps) : near(c, rng.pick([0.05, 0.3, 2]))) }
    if rng.chance(15), n > 0 { ps[rng.below(n)] = C(latitude: .nan, longitude: c.longitude) }
    let adj = rng.pick([0.0, 5_000, 30_000, 80_000, .infinity, .nan])
    let clusters = RiskBlob.clusters(ps, adjacencyMeters: adj)
    emit("blob-clusters", pts(ps), hx(adj), clusters.map(pts).joined(separator: "|"))
    let pad = rng.pick([0.0, 2_000, 12_000, -500, .nan])
    for cl in clusters.prefix(3) { emit("blob-hull", pts(cl), hx(pad), pts(RiskBlob.hull(cl, padMeters: pad))) }
    emit("blob-hull", pts(ps), hx(pad), pts(RiskBlob.hull(ps, padMeters: pad)))
}
emit("blob-hull", "", hx(1_000), pts(RiskBlob.hull([], padMeters: 1_000)))
for m in miles { emit("fares", hx(m), hx(TransitFares.amtrak(miles: m)), hx(TransitFares.greyhound(miles: m))) }
emit("fares-flat", hx(TransitFares.localBus()), hx(TransitFares.localRail()))

// ===================================================================== HybridWalk
for m in miles { emit("hw-cost", hx(m), hx(HybridWalk.rideCostUSD(miles: m))) }
emit("hw-consts", [HybridWalk.baseFareUSD, HybridWalk.perMileUSD, HybridWalk.costCapUSD, HybridWalk.minSavedFraction,
                   HybridWalk.minSavedSeconds, HybridWalk.minWalkAloneSeconds, HybridWalk.maxAffordableRideMiles].map(hx).joined(separator: "/"))
for _ in 0..<500 {
    let walk = dv(0, 20_000, [1_800, 1_799, 3_600, 900]), total = dv(0, 20_000, [900, 2_000]), cost = dv(0, 60, [25, 25.0000001])
    emit("hw-bar", hx(walk), hx(total), hx(cost), b(HybridWalk.meetsBar(walkAloneSeconds: walk, totalSeconds: total, costUSD: cost)))
    let drive = dv(0, 4_000, [0, 600]), trip = dv(0, 40, [0, 20, 20.0001, 19.99])
    let offer = HybridWalk.evaluate(walkAloneSeconds: walk, driveSeconds: drive, tripMiles: trip)
    emit("hw-eval", hx(walk), hx(drive), hx(trip),
         offer.map { [hx($0.rideMiles), hx($0.rideSeconds), hx($0.walkSeconds), hx($0.costUSD), hx($0.totalSeconds)].joined(separator: "/") } ?? "-")
}
for _ in 0..<250 {
    let c = rng.pick(centers)
    var line: [C] = []
    var p = c
    for _ in 0..<rng.pick([0, 1, 2, 3, 10, 60]) {
        if rng.chance(8), !line.isEmpty { line.append(line.last!) } else { p = near(p, 0.01); line.append(p) }
    }
    if rng.chance(15), !line.isEmpty { line[rng.below(line.count)] = C(latitude: .nan, longitude: 0) }
    let m = rng.pick([0.0, -1, 50, 800, 5_000, 1e9, .nan, .infinity, rng.range(0, 20_000)])
    emit("hw-prefix", pts(line), hx(m), pts(HybridWalk.prefixCoordinates(line, meters: m)))
}

if CommandLine.arguments.count > 1 {
    FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: out.data(using: .utf8)!)
} else {
    FileHandle.standardOutput.write(out.data(using: .utf8)!)
}
