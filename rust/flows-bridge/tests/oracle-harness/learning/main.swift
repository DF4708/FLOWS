import CoreLocation
import Foundation
// Frozen oracle: every output below comes from the ORIGINAL Swift learned-model
// code (EverydayRadius, TrafficLearning, RoadEfficiencyLearning, BufferLearning,
// RefuelLearning, DrivingProfile, DestinationPrediction), before it is replaced
// by calls into Rust. Doubles are IEEE-754 bit patterns in hex; strings are
// "s:" + UTF-8 hex; Ints are decimal; nil is "-"; lists are "L<n>:" + items.
//
// The same file compiles unchanged against the Swift facades that call Rust;
// its output must then equal the fixture, record for record.
//
// Rules: a seeded SplitMix64; no Dictionary or Set is ever iterated to choose
// inputs or to order outputs; no input that makes the original trap (it would
// have no output to record) — those cases are pinned in Rust unit tests.
func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func hs(_ s: String) -> String { "s:" + s.utf8.map { String(format: "%02x", $0) }.joined() }
func lst(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: ",") }
func opt(_ d: Double?) -> String { d.map(hx) ?? "-" }
func bo(_ v: Bool) -> String { v ? "1" : "0" }
func dl(_ a: [Double]) -> String { lst(a.map(hx)) }
func il(_ a: [Int]) -> String { lst(a.map { String($0) }) }
var out = ""
func emit(_ f: String...) { out += f.joined(separator: "\t") + "\n" }

struct SM { var s: UInt64
  mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
  mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
  mutating func pick<T>(_ a: [T]) -> T { a[below(a.count)] }
  mutating func int() -> Int { Int(truncatingIfNeeded: next()) } }
var rng = SM(s: 0x4C4541524E)   // "LEARN"

let SPECIAL: [Double] = [.nan, .infinity, -.infinity, 0.0, -0.0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
  .leastNormalMagnitude, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e-300, -1e-300, 1, -1,
  (1.0).nextUp, (1.0).nextDown, 0.5, 2, 1e300, -1e300]
let INTS: [Int] = [0, 1, -1, 2, 3, 4, 5, 6, Int.max, Int.min, Int.max - 1, Int.min + 1, 1 << 53, (1 << 53) + 1,
  -(1 << 53) - 1, 1_000_000]
let MIN_INT_DOUBLE = -9223372036854777856.0   // Int(x) traps unless MIN_INT_DOUBLE < x < 2^63
let TWO63 = 9223372036854775808.0
func fitsInt(_ x: Double) -> Bool { x > MIN_INT_DOUBLE && x < TWO63 }

// MARK: constants and tables
emit("const", "everydayDefaultMiles", hx(EverydayStore.defaultMiles))
emit("const", "everydayFloorMiles", hx(EverydayStore.floorMiles))
emit("const", "everydayHardCapMiles", hx(EverydayStore.hardCapMiles))
emit("iconst", "everydayMinTripsForRadius", String(EverydayStore.minTripsForRadius))
emit("iconst", "everydayTripWindow", String(EverydayStore.tripWindow))
emit("iconst", "everydayMaxPlacesPerCategory", String(EverydayStore.maxPlacesPerCategory))
emit("iconst", "everydayFeatureIndexSpace", String(EverydayCategory.featureIndexSpace))
emit("iconst", "everydayFeatureCount", String(EverydayFeatures.count))
emit("const", "trafficHalfLifeSeconds", hx(TrafficDelayStore.halfLifeSeconds))
emit("iconst", "trafficConfidentAfter", String(TrafficDelayStore.confidentAfter))
emit("const", "trafficMaxFactor", hx(TrafficDelayStore.maxFactor))
emit("const", "trafficMinFactor", hx(TrafficDelayStore.minFactor))
emit("const", "efficiencyHalfLifeSeconds", hx(RoadEfficiencyStore.halfLifeSeconds))
emit("const", "efficiencyConfidentMiles", hx(RoadEfficiencyStore.confidentMiles))
emit("const", "efficiencyMinRatio", hx(RoadEfficiencyStore.minRatio))
emit("const", "efficiencyMaxRatio", hx(RoadEfficiencyStore.maxRatio))
emit("const", "bufferAlpha", hx(BufferLearning.alpha))
emit("iconst", "bufferMinSamplesToTrust", String(BufferLearning.minSamplesToTrust))
emit("const", "bufferPlausibleLow", hx(BufferLearning.plausibleSeconds.lowerBound))
emit("const", "bufferPlausibleHigh", hx(BufferLearning.plausibleSeconds.upperBound))
emit("const", "refuelAccuracyFloor", hx(RefuelLearning.accuracyFloor))
emit("iconst", "refuelWindow", String(RefuelLearning.window))
emit("const", "staleGaugeGap", hx(StaleGauge.gap))
emit("const", "etaMinPlausibleRatio", hx(DrivingProfile.minPlausibleRatio))
emit("const", "etaMaxPlausibleRatio", hx(DrivingProfile.maxPlausibleRatio))
emit("iconst", "etaMinSamplesToApply", String(DrivingProfile.minSamplesToApply))
emit("const", "etaMinMeaningfulDeviation", hx(DrivingProfile.minMeaningfulDeviation))
emit("const", "etaClampLow", hx(DrivingProfile.clampLow))
emit("const", "etaClampHigh", hx(DrivingProfile.clampHigh))
emit("const", "destinationRecencyHalfLifeDays", hx(DestinationPrediction.recencyHalfLifeDays))
emit("const", "destinationContextWeight", hx(DestinationPrediction.contextWeight))
emit("const", "destinationTimeWeight", hx(DestinationPrediction.timeWeight))
emit("const", "destinationBaseWeight", hx(DestinationPrediction.baseWeight))
emit("table", "trafficWeather", lst(TrafficWeather.allCases.map { hs($0.rawValue) }))
for cat in EverydayCategory.allCases { emit("fidx", hs(cat.rawValue), String(cat.featureIndex)) }

// MARK: EverydayStore statistics
func milesValue() -> Double {
  switch rng.below(7) {
  case 0: return rng.pick(SPECIAL)
  case 1: return Double(rng.below(5))
  case 2: return -Double(rng.below(3))          // includes -0.0
  case 3: return rng.pick([3.0, (3.0).nextUp, (3.0).nextDown, 150, (150.0).nextUp, (150.0).nextDown, 20])
  default: return rng.unit() * 200
  } }
let pinnedLists: [[Double]] = [[], [1, 2, 3, 4, 5], [.nan, -3, 4, 4], [0.0, -0.0], [-0.0, 0.0], [-0.0], [7], [.infinity, 1],
  Array(repeating: 4.0, count: 29), Array(repeating: 4.0, count: 30), Array(repeating: 35.0, count: 40),
  Array(repeating: 400.0, count: 40), Array(repeating: 0.2, count: 40), Array(repeating: -0.0, count: 70),
  (0..<70).map { $0 % 2 == 0 ? 0.0 : -0.0 }, (0..<70).map { $0 % 2 == 0 ? -0.0 : 0.0 },
  Array(repeating: .nan, count: 30), (0..<30).map { 5.0 + Double($0 % 3) * 0.5 },
  Array(repeating: 3.0, count: 10) + Array(repeating: 5.0, count: 10) + Array(repeating: 7.0, count: 10),
  Array(repeating: 38.0, count: 20) + Array(repeating: 52.0, count: 15), [.greatestFiniteMagnitude, .greatestFiniteMagnitude]]
var lists = pinnedLists
for n in [0, 1, 2, 3, 4, 5, 8, 16, 29, 30, 31, 32, 62, 63, 64, 65, 66, 100, 127, 128, 129, 199, 200, 201, 256, 300] {
  for _ in 0..<3 { lists.append((0..<n).map { _ in milesValue() }) }
}
let qs: [Double] = [0, -0.0, 0.25, 0.5, 0.85, (0.85).nextUp, (0.85).nextDown, 1, (1.0).nextDown, (1.0).nextUp, -1, 2,
  .infinity, -.infinity, 1e-300, .leastNonzeroMagnitude, .nan]
for v in lists {
  let cleanEmpty = !v.contains { $0.isFinite && $0 >= 0 }
  for q in qs + [rng.unit(), rng.unit()] where !q.isNaN || cleanEmpty {
    emit("q", dl(v), hx(q), opt(EverydayStore.quantile(v, q)))
  }
  var s = EverydayStore(); s.tripMiles = v
  emit("rad", dl(v), hx(s.radiusMiles))
  emit("mean", dl(v), opt(s.meanTripMiles))
  emit("sd", dl(v), opt(s.tripMilesSD))
}
for m in SPECIAL + [3, 150, 20, 0.2, -3] + (0..<20).map({ _ in milesValue() }) {
  var s = EverydayStore(); s.recordTrip(miles: m)
  emit("tripok", hx(m), bo(s.tripCount == 1))
}
for n in [0, 1, 199, 200, 201, 225, 450] {
  var s = EverydayStore()
  for i in 0..<n { s.recordTrip(miles: Double(i)) }
  emit("twin", String(n), dl(s.tripMiles))
}

// MARK: hour bucket and the feature vector
var hours = INTS + Array(-50...50) + [47, 48, 49, 95, 96, -95, -96, -97]
for _ in 0..<60 { hours.append(rng.int()) }
for h in hours { emit("hb", String(h), String(EverydayStore.hourBucket(h))) }
let coordVals: [Double] = SPECIAL + [43.0, -89.4, 90, -90, 180, -180, 43.1, -89.3]
for cat in EverydayCategory.allCases {
  for hb in [0, 1, 2, 3, 4, 5, 6, 7, 12, -1, Int.max, Int.min] {
    for we in [false, true] {
      let c = (0..<4).map { _ in rng.below(3) == 0 ? rng.pick(coordVals) : rng.unit() * 360 - 180 }
      let v = EverydayFeatures.vector(hourBucket: hb, weekend: we, startLat: c[0], startLon: c[1],
                                      placeLat: c[2], placeLon: c[3], category: cat)
      emit("fv", String(hb), bo(we), hx(c[0]), hx(c[1]), hx(c[2]), hx(c[3]), hs(cat.rawValue), dl(v))
    }
  }
}

// MARK: ranking and eviction of remembered places
let nfcNames = ["", "a", "b", "A", "Z", "z", " ", "Cafe", "Caf\u{e9}", "Caf\u{e9} Bar", "\u{0}", "a\u{0}", "\u{1f}",
  "a\u{1f}b", "\u{1f600}", "\u{ac00}", "\u{4e2d}\u{6587}", "\u{5d0}", "Stop 1", "Stop 10", "Stop 2", "stop 1",
  "\u{fb01}", "fi", "\u{130}", "\u{131}", "\u{fffd}", "\u{10ffff}", "\u{e000}", "Diner", "Diner "]
for n in nfcNames { precondition(n.precomposedStringWithCanonicalMapping.utf8.elementsEqual(n.utf8), "pool must be NFC") }
func countValue() -> Int { rng.below(6) == 0 ? rng.pick(INTS) : rng.below(4) }
func lastValue() -> Double {
  rng.below(4) == 0 ? rng.pick([0, -0.0, 1, 2, 1.7e9, (1.7e9).nextUp, .nan, .infinity, -.infinity, -1]) : Double(rng.below(3)) }
func placesStore(_ uses: [Int], _ seen: [Int], _ last: [Double], _ names: [String]) -> EverydayStore {
  var s = EverydayStore()
  s.categories[EverydayCategory.food.rawValue] = uses.indices.map { i in
    EverydayPlace(id: "p\(i)", name: names[i], latitude: 0, longitude: 0, street: "", city: "",
                  uses: uses[i], seen: seen[i], lastUsedT: last[i]) }
  return s
}
func emitRank(_ uses: [Int], _ seen: [Int], _ last: [Double], _ names: [String]) {
  let s = placesStore(uses, seen, last, names)
  let perm = s.ranked(in: .food).map { Int($0.id.dropFirst())! }
  emit("rank", il(uses), il(seen), dl(last), lst(names.map(hs)),
       lst(names.map { hs($0.precomposedStringWithCanonicalMapping) }), il(perm))
}
for n in [0, 1, 2, 3, 5, 10, 20, 49, 50, 51, 63, 64, 65, 100, 130] {
  for trial in 0..<(n > 64 ? 4 : 10) {
    let noNaN = trial % 2 == 0
    let last = (0..<n).map { _ -> Double in let l = lastValue(); return noNaN && l.isNaN ? 3 : l }
    emitRank((0..<n).map { _ in countValue() }, (0..<n).map { _ in countValue() }, last,
             (0..<n).map { _ in rng.pick(nfcNames) })
  }
}
// Canonically-equivalent but differently-encoded names, all counts tied, so the name decides.
let nonNFC: [[String]] = [["o\u{308}", "\u{f6}z"], ["\u{f6}z", "o\u{308}"], ["\u{1100}\u{1161}", "\u{ac00} "],
  ["e\u{301}", "\u{e9}"], ["\u{e9}", "e\u{301}"], ["Cafe\u{301}", "Caf\u{e9}", "Cafe"], ["A\u{30a}", "\u{c5}", "\u{212b}", "B"],
  ["d\u{323}\u{307}", "d\u{307}\u{323}", "\u{1e0d}\u{307}"], ["Cafe\u{301} Bar", "Caf\u{e9}"]]
for names in nonNFC {
  emitRank(Array(repeating: 1, count: names.count), Array(repeating: 2, count: names.count),
           Array(repeating: 5, count: names.count), names)
}
for n in [50, 50, 50, 50, 51, 52, 60, 63, 64, 65, 100] {
  for _ in 0..<6 {
    let u = (0..<n).map { _ in countValue() }, sn = (0..<n).map { _ in countValue() }, l = (0..<n).map { _ in lastValue() }
    var s = placesStore(u, sn, l, Array(repeating: "x", count: n))
    s.setHome(lat: 0, lon: 0)
    let newID = EverydayPlace.attributeID(name: "new", latitude: 0, longitude: 0)
    let before = s.categories[EverydayCategory.food.rawValue]!.map(\.id) + [newID]
    s.remember(name: "new", lat: 0, lon: 0, street: "", city: "", in: .food)
    let after = s.categories[EverydayCategory.food.rawValue]!.map(\.id)
    let removed = before.indices.first { $0 >= after.count || before[$0] != after[$0] } ?? -1
    emit("evict", il(u + [0]), il(sn + [1]), dl(l + [0]), String(removed))
  }
}

// MARK: traffic delay
let families: [String?] = [nil, "qpf_flood", "precip", "tropical", "winter", "ice", "fog", "haze", "wind", "clear", "rain",
  "snow", "heat", "cold", "air", "radiation", "convective", "storm", "fire", "flood", "closure", "seismic", "tsunami",
  "volcanic", "avalanche", "environmental", "", "Wind", "WIND", " wind", "wind ", "wind\u{0}", "w\u{ed}nd",
  "qpf_flood\u{301}", "\u{212a}", "ice\u{1f}", "fog\u{0}", "Ice", "HAZE"]
for f in families { emit("tw", f.map(hs) ?? "-", hs(TrafficWeather.from(family: f).rawValue)) }
for m in SPECIAL + [45, (45.0).nextUp, (45.0).nextDown, 44.9, 62, 22, 30] + (0..<20).map({ _ in rng.unit() * 90 }) {
  emit("rc", hx(m), bo(RoadClass.from(averageMph: m) == .highway))
}
func cellValue() -> Double {
  rng.below(4) == 0 ? rng.pick(SPECIAL + [0.7, 2.5, (0.7).nextDown, (2.5).nextUp]) : rng.unit() * 20 }
for _ in 0..<150 {
  let ws = cellValue(), w = rng.below(5) == 0 ? rng.pick([0, -0.0, -1, .nan, .leastNonzeroMagnitude]) : cellValue()
  emit("tmean", hx(ws), hx(w), hx(DelayCell(weightedSum: ws, weight: w, count: 0).mean))
  emit("emean", hx(ws), hx(w), hx(RoadEfficiencyStore.Cell(weightedSum: ws, weight: w, miles: 0).mean))
}
/// The smallest elapsed interval whose decay factor falls below 0.999, and its neighbours.
func decayBoundary(_ halfLife: Double) -> [Double] {
  var lo = 0.0, hi = halfLife
  for _ in 0..<2000 {
    let mid = lo + (hi - lo) / 2
    if mid == lo || mid == hi { break }
    if pow(0.5, mid / halfLife) < 0.999 { hi = mid } else { lo = mid }
  }
  return [lo, hi, lo.nextDown, hi.nextUp]
}
func decayTimes(_ halfLife: Double) -> (Double, Double) {
  let lasts: [Double] = [0, -0.0, -5, 1, 1.7e9, .nan, .infinity, -.infinity, .leastNonzeroMagnitude, 1e300]
  let deltas: [Double] = [0, -1, 1, 3600, 86_400, 365 * 86_400, 1e12, .infinity, -.infinity, .nan] + decayBoundary(halfLife)
  let last = rng.below(3) == 0 ? rng.pick(lasts) : 1.7e9
  let now = rng.below(6) == 0 ? rng.pick(lasts) : last + rng.pick(deltas)
  return (last, now)
}
let trafficWeathers = TrafficWeather.allCases
func randomArea() -> TrafficArea {
  TrafficArea(CLLocationCoordinate2D(latitude: rng.unit() * 180 - 90, longitude: rng.unit() * 360 - 180)) }
for _ in 0..<250 {
  let (last, now) = decayTimes(TrafficDelayStore.halfLifeSeconds)
  let n = rng.pick([0, 1, 2, 3, 7])
  let ws = (0..<n).map { _ in cellValue() }, w = (0..<n).map { _ in cellValue() }
  var s = TrafficDelayStore(); s.lastDecay = last
  for i in 0..<n { s.cells["k\(i)"] = DelayCell(weightedSum: ws[i], weight: w[i], count: i) }
  s.decay(to: now)
  emit("tdecay", dl(ws), dl(w), hx(last), hx(now), hx(s.lastDecay),
       dl((0..<n).map { s.cells["k\($0)"]!.weightedSum }), dl((0..<n).map { s.cells["k\($0)"]!.weight }))
}
let seconds: [Double] = [60, (60.0).nextUp, 61, 1800, 3600, 0, -1, .nan, .infinity, -.infinity, -0.0,
  .leastNonzeroMagnitude, 1e300, 900, 2700, 36_000]
for trial in 0..<500 {
  let (last, now) = decayTimes(TrafficDelayStore.halfLifeSeconds)
  let area = randomArea(), cls: RoadClass = rng.below(2) == 0 ? .local : .highway
  let wd = rng.below(9) - 1, hr = rng.below(30) - 3, weather = rng.pick(trafficWeathers)
  let p = rng.below(3) == 0 ? rng.pick(seconds) : 60 + rng.unit() * 7200
  var a = rng.below(3) == 0 ? rng.pick(seconds) : p * (rng.unit() * 4)
  if trial % 7 == 0 { a = p * rng.pick([0.5, (0.5).nextUp, (0.5).nextDown, 3.0, (3.0).nextUp, (3.0).nextDown]) }
  let key = TrafficDelayStore.key(area: area, roadClass: cls, weekday: wd, hour: hr, weather: weather)
  var s = TrafficDelayStore(); s.lastDecay = last
  let hasTarget = rng.below(3) != 0
  let tws = cellValue(), tw = cellValue()
  var tc = countValue()
  if p > 60 && a > 0 && tc == Int.max { tc = Int.max - 1 }   // the original traps on count overflow
  if hasTarget { s.cells[key] = DelayCell(weightedSum: tws, weight: tw, count: tc) }
  let m = rng.below(4)
  let ows = (0..<m).map { _ in cellValue() }, ow = (0..<m).map { _ in cellValue() }, oc = (0..<m).map { _ in countValue() }
  for j in 0..<m { s.cells["o\(j)"] = DelayCell(weightedSum: ows[j], weight: ow[j], count: oc[j]) }
  s.record(predictedSeconds: p, actualSeconds: a, area: area, roadClass: cls, weekday: wd, hour: hr,
           weather: weather, now: now)
  let t = s.cells[key]
  let others = (0..<m).map { s.cells["o\($0)"]! }
  emit("trec", hx(p), hx(a), hx(last), hx(now), bo(hasTarget), hx(tws), hx(tw), String(tc), dl(ows), dl(ow), il(oc),
       bo(t != nil), hx(t?.weightedSum ?? 0), hx(t?.weight ?? 0), String(t?.count ?? 0),
       dl(others.map(\.weightedSum)), dl(others.map(\.weight)), il(others.map(\.count)), hx(s.lastDecay))
}
let routers: [Double] = [0, -0.0, 1800, 3600, .nan, .infinity, -.infinity, 1e300, -1e300, 60, 29.999, 30, 90,
  TWO63 * 40, (TWO63 * 40).nextDown, (TWO63 * 40).nextUp, TWO63 * 400, -TWO63 * 40]
for _ in 0..<700 {
  let area = randomArea(), wd = rng.below(9) - 1, hr = rng.below(30) - 3, weather = rng.pick(trafficWeathers)
  let isHighway = rng.below(2) == 0
  let lp = rng.below(3) != 0, pp = rng.below(3) != 0
  let lws = cellValue(), lw = cellValue(), lc = rng.pick([0, 1, 3, 4, 5, 100, Int.max, Int.min, -1])
  let pws = cellValue(), pw = cellValue(), pc = rng.pick([0, 1, 3, 4, 5, 100, Int.max, Int.min, -1])
  var s = TrafficDelayStore()
  if lp { s.cells[TrafficDelayStore.key(area: area, roadClass: .local, weekday: wd, hour: hr, weather: weather)] =
    DelayCell(weightedSum: lws, weight: lw, count: lc) }
  if pp { s.cells[TrafficDelayStore.key(area: .pooled, roadClass: .highway, weekday: wd, hour: hr, weather: weather)] =
    DelayCell(weightedSum: pws, weight: pw, count: pc) }
  let cls: RoadClass = isHighway ? .highway : .local
  let r = rng.below(3) == 0 ? rng.pick(routers) : rng.unit() * 7200
  let f = s.factor(area: area, roadClass: cls, weekday: wd, hour: hr, weather: weather)
  let adj = s.adjustedSeconds(routerSeconds: r, area: area, roadClass: cls, weekday: wd, hour: hr, weather: weather)
  let minutes = ((adj - r) / 60).rounded()
  let dm = fitsInt(minutes)
    ? String(s.predictedDelayMinutes(routerSeconds: r, area: area, roadClass: cls, weekday: wd, hour: hr, weather: weather))
    : "-"
  let conf = s.isConfident(area: area, roadClass: cls, weekday: wd, hour: hr, weather: weather)
  emit("tfac", bo(isHighway), bo(lp), hx(lws), hx(lw), String(lc), bo(pp), hx(pws), hx(pw), String(pc), hx(r),
       hx(f), hx(adj), dm, bo(conf))
}

// MARK: road efficiency
for _ in 0..<250 {
  let (last, now) = decayTimes(RoadEfficiencyStore.halfLifeSeconds)
  let n = rng.pick([0, 1, 2, 3, 7])
  let ws = (0..<n).map { _ in cellValue() }, w = (0..<n).map { _ in cellValue() }
  var s = RoadEfficiencyStore(); s.lastDecay = last
  for i in 0..<n { s.cells["k\(i)"] = RoadEfficiencyStore.Cell(weightedSum: ws[i], weight: w[i], miles: Double(i)) }
  s.decay(to: now)
  emit("edecay", dl(ws), dl(w), hx(last), hx(now), hx(s.lastDecay),
       dl((0..<n).map { s.cells["k\($0)"]!.weightedSum }), dl((0..<n).map { s.cells["k\($0)"]!.weight }))
}
let milesPool: [Double] = [0.5, (0.5).nextUp, (0.5).nextDown, 0.001, (0.001).nextUp, .nan, .infinity, -.infinity, 0, -1,
  10, 2, 60, 1e300, .leastNonzeroMagnitude, 1e-300, -0.0, 0.05, 0.4]
for _ in 0..<500 {
  let (last, now) = decayTimes(RoadEfficiencyStore.halfLifeSeconds)
  let area = randomArea(), cls: RoadClass = rng.below(2) == 0 ? .local : .highway
  let mi = rng.below(3) == 0 ? rng.pick(milesPool) : rng.unit() * 40
  let un = rng.below(3) == 0 ? rng.pick(milesPool) : rng.unit() * 2
  let key = RoadEfficiencyStore.key(area: area, roadClass: cls)
  var s = RoadEfficiencyStore(); s.lastDecay = last
  let hasTarget = rng.below(3) != 0
  let tws = cellValue(), tw = cellValue(), tm = cellValue()
  if hasTarget { s.cells[key] = RoadEfficiencyStore.Cell(weightedSum: tws, weight: tw, miles: tm) }
  let m = rng.below(4)
  let ows = (0..<m).map { _ in cellValue() }, ow = (0..<m).map { _ in cellValue() }, om = (0..<m).map { _ in cellValue() }
  for j in 0..<m { s.cells["o\(j)"] = RoadEfficiencyStore.Cell(weightedSum: ows[j], weight: ow[j], miles: om[j]) }
  s.record(milesDriven: mi, unitsBurned: un, area: area, roadClass: cls, now: now)
  let t = s.cells[key]
  let others = (0..<m).map { s.cells["o\($0)"]! }
  emit("erec", hx(mi), hx(un), hx(last), hx(now), bo(hasTarget), hx(tws), hx(tw), hx(tm), dl(ows), dl(ow), dl(om),
       bo(t != nil), hx(t?.weightedSum ?? 0), hx(t?.weight ?? 0), hx(t?.miles ?? 0),
       dl(others.map(\.weightedSum)), dl(others.map(\.weight)), dl(others.map(\.miles)), hx(s.lastDecay))
}
for _ in 0..<700 {
  let area = randomArea(), isHighway = rng.below(2) == 0
  let lp = rng.below(3) != 0, pp = rng.below(3) != 0
  let milesChoice: [Double] = [25, (25.0).nextDown, (25.0).nextUp, 0, 100, .nan, .infinity, -1]
  let lws = cellValue() * 10, lw = cellValue(), lm = rng.below(2) == 0 ? rng.pick(milesChoice) : rng.unit() * 60
  let pws = cellValue() * 10, pw = cellValue(), pm = rng.below(2) == 0 ? rng.pick(milesChoice) : rng.unit() * 60
  var s = RoadEfficiencyStore()
  if lp { s.cells[RoadEfficiencyStore.key(area: area, roadClass: .local)] =
    RoadEfficiencyStore.Cell(weightedSum: lws, weight: lw, miles: lm) }
  if pp { s.cells[RoadEfficiencyStore.key(area: .pooled, roadClass: .highway)] =
    RoadEfficiencyStore.Cell(weightedSum: pws, weight: pw, miles: pm) }
  let cls: RoadClass = isHighway ? .highway : .local
  let rated = rng.below(3) == 0 ? rng.pick(SPECIAL + [30, 20]) : rng.unit() * 60
  emit("eeco", hx(rated), bo(isHighway), bo(lp), hx(lws), hx(lw), hx(lm), bo(pp), hx(pws), hx(pw), hx(pm),
       hx(s.economy(ratedMilesPerUnit: rated, area: area, roadClass: cls)), bo(s.isConfident(area: area, roadClass: cls)))
}

// MARK: buffer learning
let samples: [Double] = [1, (1.0).nextDown, (1.0).nextUp, 180, (180.0).nextUp, (180.0).nextDown, 0.2, 600, .nan, .infinity,
  -.infinity, 12, 30, -0.0, 0, 20, 10, 9]
let means: [Double?] = [nil, 20, 10, 40, .nan, .infinity, -.infinity, -0.0, 0, 1e300, -5]
for _ in 0..<400 {
  let mean = rng.pick(means)
  let sample = rng.below(2) == 0 ? rng.pick(samples) : rng.unit() * 200
  emit("bu", opt(mean), hx(sample), opt(BufferLearning.updated(mean: mean, sample: sample)))
}
for sample in samples + (0..<40).map({ _ in rng.unit() * 200 - 10 }) {
  emit("bus", hx(sample), bo(BufferLearning.isUsable(sample: sample)))
}
for _ in 0..<250 {
  let prior = rng.pick(SPECIAL + [30, 9]), mean = rng.pick(means), n = rng.pick(INTS)
  emit("bw", hx(prior), opt(mean), String(n), hx(BufferLearning.waitSeconds(prior: prior, learnedMean: mean, samples: n)))
}

// MARK: refuel learning and the stale gauge
func fraction() -> Double {
  rng.below(3) == 0 ? rng.pick([.nan, .infinity, -.infinity, -0.0, 0, 1, (1.0).nextUp, 0.4, 0.45, 0.2, 0.7, -0.5, 1.5,
                                .leastNonzeroMagnitude]) : rng.unit() }
for _ in 0..<220 {
  var l = RefuelLearning()
  let n = rng.pick([0, 1, 2, 9, 10, 11, 20, 49, 50, 51, 60])
  for _ in 0..<n { l.record(predictedFraction: fraction(), reportedFraction: fraction()) }
  emit("ra", dl(l.errors), hx(l.accuracy))
  emit("rsp", dl(l.errors), "1", bo(l.shouldPrompt(checkInsEnabled: true)))
  emit("rsp", dl(l.errors), "0", bo(l.shouldPrompt(checkInsEnabled: false)))
}
for _ in 0..<120 {
  let n = rng.pick([1, 2, 5, 10, 11, 30])
  let errs = (0..<n).map { _ in
    rng.below(3) == 0 ? rng.pick([0, -0.0, 1, -1, 2, 0.2, 1e300, -1e300, 5e-324, 1e308]) : rng.unit() * 2 - 0.5 }
  let json = "{\"errors\":[" + errs.map { "\($0)" }.joined(separator: ",") + "]}"
  guard let l = try? JSONDecoder().decode(RefuelLearning.self, from: Data(json.utf8)) else { continue }
  emit("ra", dl(l.errors), hx(l.accuracy))
  emit("rsp", dl(l.errors), "1", bo(l.shouldPrompt(checkInsEnabled: true)))
}
for _ in 0..<300 {
  let p = fraction(), r = fraction()
  var l = RefuelLearning(); l.record(predictedFraction: p, reportedFraction: r)
  emit("rerr", hx(p), hx(r), hx(l.errors.last!))
}
for n in [0, 1, 49, 50, 51, 100, 120] {
  var l = RefuelLearning()
  for i in 0..<n { l.record(predictedFraction: Double(i % 11) / 10, reportedFraction: 0) }
  emit("rcap", String(n), dl(l.errors))
}
let gap = StaleGauge.gap
let refTimes: [Double] = [0, -0.0, 1e9, 7.8e8, .nan, .infinity, -.infinity, -1e9, 1e20, 5e15]
for _ in 0..<300 {
  let last: Double? = rng.below(8) == 0 ? nil : rng.pick(refTimes)
  let base = last ?? rng.pick(refTimes)
  let now = rng.below(5) == 0 ? rng.pick(refTimes)
    : base + rng.pick([gap, gap.nextDown, gap.nextUp, 0, -gap, 2 * 86_400, 8 * 86_400, .nan, .infinity])
  emit("sg", opt(last), hx(now), bo(StaleGauge.wentStale(
    lastUsed: last.map { Date(timeIntervalSinceReferenceDate: $0) }, now: Date(timeIntervalSinceReferenceDate: now))))
}

// MARK: driving profile — the personal ETA correction
let lnBounds: [Double] = [log(1.03), log(0.97), log(0.75), log(1.4)]
let logRatios: [Double] = [0, -0.0, .nan, .infinity, -.infinity, 1, -1, 0.1823, -5, 5]
  + lnBounds.flatMap { [$0, $0.nextUp, $0.nextDown] }
for _ in 0..<400 {
  let lr = rng.below(2) == 0 ? rng.pick(logRatios) : rng.unit() * 2 - 1
  let n = rng.pick([4, 5, 6, 0, -1, Int.max, Int.min, 100])
  var p = DrivingProfile(); p.etaLogRatio = lr; p.etaSamples = n
  emit("em", hx(lr), String(n), hx(p.etaMultiplier))
}
let durations: [Double] = [60, (60.0).nextUp, 61, 3600, 4320, 6300, 7200, 36_000, 0, -1, .nan, .infinity, -.infinity, -0.0]
for trial in 0..<600 {
  let lr = rng.below(2) == 0 ? rng.pick(logRatios) : rng.unit() - 0.5
  var n = rng.pick([0, 1, 4, 5, 12, 100, -1, -2, Int.max, Int.min, Int.max - 1])
  let pr = rng.below(3) == 0 ? rng.pick(durations) : 60 + rng.unit() * 7200
  var ac = rng.below(3) == 0 ? rng.pick(durations) : pr * (0.4 + rng.unit() * 1.6)
  let st = rng.below(3) == 0 ? rng.pick([0, -0.0, -5, 3600, .nan, .infinity, -.infinity, 60]) : rng.unit() * 100
  if trial % 9 == 0 {
    ac = pr * rng.pick([0.6, (0.6).nextUp, (0.6).nextDown, 1.8, (1.8).nextUp, (1.8).nextDown]) + max(st, 0)
  }
  let driving = ac - max(st, 0)
  let ratio = driving / pr
  let accepted = pr > 60 && driving > 60 && pr.isFinite && driving.isFinite && ratio >= 0.6 && ratio <= 1.8
  if accepted && n == Int.max { n = Int.max - 1 }   // the original traps on sample overflow
  var p = DrivingProfile(); p.etaLogRatio = lr; p.etaSamples = n
  p.recordArrival(predicted: pr, actual: ac, stoppedSeconds: st, now: 777)
  emit("er", hx(lr), String(n), hx(pr), hx(ac), hx(st), hx(p.etaLogRatio), String(p.etaSamples), bo(p.updatedAt == 777))
}

// MARK: destination prediction
func evidenceList(_ n: Int, now: Double) -> [DestinationPrediction.Evidence] {
  (0..<n).map { i in
    var e = DestinationPrediction.Evidence(id: "e\(i)", name: "n\(i)",
                                           coordinate: CLLocationCoordinate2D(latitude: 43, longitude: -89))
    e.contextHits = rng.below(5) == 0 ? rng.pick(INTS) : rng.below(4)
    e.timeHits = rng.below(5) == 0 ? rng.pick(INTS) : rng.below(4)
    e.totalHits = rng.below(5) == 0 ? rng.pick(INTS) : rng.below(8)
    e.lastUsed = rng.below(4) == 0
      ? rng.pick([0, -0.0, -1, .nan, .infinity, -.infinity, now, now + 86_400, .leastNonzeroMagnitude])
      : now - Double(rng.below(60)) * 86_400
    return e
  }
}
let nows: [Double] = [1.7e9, .nan, .infinity, -.infinity, 0, -0.0]
for n in [0, 1, 2, 3, 4, 5, 10, 30, 63, 64, 65, 100, 300, 600] {
  for trial in 0..<(n >= 300 ? 2 : (n > 64 ? 6 : 14)) {
    let now = trial % 3 == 0 ? rng.pick(nows) : 1.7e9 + rng.unit() * 1e6
    let ev = evidenceList(n, now: now)
    let limit = rng.pick([0, 1, 3, 4, 5, 100, Int.max])
    let ranked = DestinationPrediction.rank(ev, now: now, limit: limit)
    emit("dr", il(ev.map(\.contextHits)), il(ev.map(\.timeHits)), il(ev.map(\.totalHits)), dl(ev.map(\.lastUsed)),
         hx(now), String(limit), il(ranked.map { Int($0.id.dropFirst())! }), dl(ranked.map(\.score)),
         lst(ranked.map { hs($0.reason) }))
  }
}
for n in [0, 1, 5] {   // a negative limit is only reachable without trapping when nothing scores
  var ev = evidenceList(n, now: 1.7e9)
  for i in ev.indices { ev[i].contextHits = 0; ev[i].timeHits = 0; ev[i].totalHits = 0 }
  let ranked = DestinationPrediction.rank(ev, now: 1.7e9, limit: -1)
  emit("dr", il(ev.map(\.contextHits)), il(ev.map(\.timeHits)), il(ev.map(\.totalHits)), dl(ev.map(\.lastUsed)),
       hx(1.7e9), "-1", il(ranked.map { Int($0.id.dropFirst())! }), dl(ranked.map(\.score)), lst(ranked.map { hs($0.reason) }))
}
let hitValues = [Int.min, -1, 0, 1, 2, 3, 4, 5, 6, Int.max]
for c in hitValues { for t in hitValues { for tot in hitValues {
  var e = DestinationPrediction.Evidence(id: "x", name: "x", coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0))
  e.contextHits = c; e.timeHits = t; e.totalHits = tot
  emit("dreason", String(c), String(t), String(tot), hs(DestinationPrediction.reason(for: e)))
} } }
for _ in 0..<200 {
  let n = rng.pick([0, 1, 2, 3])
  let scores = (0..<n).map { _ in rng.pick([0.5, (0.5).nextDown, (0.5).nextUp, 1, 0, .nan, .infinity, -1, 0.49, 0.51]) }
  let cands = scores.map { DestinationPrediction.Candidate(id: "c", name: "c", coordinate:
    CLLocationCoordinate2D(latitude: 0, longitude: 0), score: $0, reason: "") }
  let minimum = rng.pick(INTS + [2, 3, 4])
  emit("dconf", dl(scores), String(minimum), bo(DestinationPrediction.isConfident(cands, minimumEvidence: minimum)))
}

FileHandle.standardOutput.write(out.data(using: .utf8)!)
