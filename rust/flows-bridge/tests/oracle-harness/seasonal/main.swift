import CoreLocation
import Foundation

// Frozen oracle for the seasonal risk model and the route-head trainer: every
// output below comes from the ORIGINAL Swift (SeasonalRiskModel.swift and
// RouteHeadTrainer.swift) before it was replaced by calls into Rust.
//
// Encodings: doubles are IEEE-754 bit patterns in hex; ints are decimal;
// strings are "s:" + UTF-8 hex; nil is "-"; a list is "L<n>:" + items joined
// by ","; a WeekStat is "wSum/wObserved/wSqErr/lastT/count"; an OriginStat is
// "weighted/lastSeen/firstSeen/trips"; a head is "b2/b1/w2/w1" where a vector
// is "<n>" + ":v" per value and w1 is "<rows>" + ";" + vector per row.
//
// Determinism: a seeded SplitMix64 chooses every input; no Dictionary or Set is
// ever iterated to choose inputs or order outputs (snapshots are sorted). The
// store methods that fold over a Dictionary are given inputs whose answer does
// not depend on iteration order (see README.md); that dependence is a finding.
//
// Records tagged "copied" exercise expressions that live inside the
// @MainActor SeasonalRiskModel class, which cannot be instantiated here (its
// init reads and migrates the user's sealed store and Keychain key). Those
// expressions are copied VERBATIM from the base commit, with line numbers.

func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func hs(_ s: String) -> String { "s:" + s.utf8.map { String(format: "%02x", $0) }.joined() }
func lst(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: ",") }
func bl(_ v: Bool) -> String { v ? "1" : "0" }
func it(_ v: Int) -> String { String(v) }
func opt(_ d: Double?) -> String { d.map(hx) ?? "-" }
func vec(_ v: [Double]) -> String { "\(v.count)" + v.map { ":" + hx($0) }.joined() }
func wsf(_ w: WeekStat) -> String {
  [hx(w.wSum), hx(w.wObserved), hx(w.wSqErr), hx(w.lastT), it(w.count)].joined(separator: "/")
}
func osf(_ o: SeasonalStore.OriginStat) -> String {
  [hx(o.weighted), hx(o.lastSeen), hx(o.firstSeen), it(o.trips)].joined(separator: "/")
}
func headf(_ h: LearnedHead) -> String {
  [hx(h.b2), vec(h.b1), vec(h.w2), "\(h.w1.count)" + h.w1.map { ";" + vec($0) }.joined()]
    .joined(separator: "/")
}
func headMeta(_ h: LearnedHead) -> String {
  [it(h.version), h.rows.map(it) ?? "-", h.tunedOnDevice.map(bl) ?? "-"].joined(separator: "/")
}
var out = ""
func emit(_ f: String...) { out += f.joined(separator: "\t") + "\n" }

struct SM {
  var s: UInt64
  mutating func next() -> UInt64 {
    s &+= 0x9E37_79B9_7F4A_7C15; var z = s
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9; z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}
var rng = SM(s: 0x5345_4153_4F4E)  // "SEASON"
func coin(_ n: Int) -> Bool { rng.below(n) == 0 }
func pick<T>(_ a: [T]) -> T { a[rng.below(a.count)] }
func shuffled(_ n: Int) -> [Int] {
  var a = Array(0..<n)
  if n > 1 { for i in stride(from: n - 1, to: 0, by: -1) { a.swapAt(i, rng.below(i + 1)) } }
  return a
}
func cl(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
  CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

let SP: [Double] = [
  .nan, .infinity, -.infinity, 0.0, -0.0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude, 1e-300, 1e-9,
  0.25, 0.5, (1.0).nextDown, 1, (1.0).nextUp, 1.5, 2, (5.0).nextDown, 5, (5.0).nextUp, 12, 30, 52,
  (300.0).nextDown, 300, (300.0).nextUp, 1e300, .greatestFiniteMagnitude, -1, -1e300, 4000, 86_400,
]
func unitish() -> Double { coin(4) ? pick(SP) : rng.unit() * 1.4 - 0.2 }
let T0 = 1_700_000_000.0
let WEEK = 7.0 * 24 * 3600
let DAY = 86_400.0
func epoch() -> Double { T0 + rng.unit() * 2e8 }
let HL: [Double] = [0, -0.0, .leastNonzeroMagnitude, 1, .infinity, .nan, -1, 1e-300, 1e300, 0.5, 52]
func near(_ last: Double) -> Double {
  switch rng.below(9) {
  case 0: return last
  case 1: return last.nextUp
  case 2: return last.nextDown
  case 3: return pick(SP)
  case 4: return last - rng.unit() * WEEK * 10
  case 5: return last + WEEK * Double(rng.below(200))
  default: return last + rng.unit() * WEEK * 200
  }
}
let COUNTS: [Int] = [0, -1, Int.min, 1 << 53, (1 << 53) + 1, 1, 2, Int.max - 1]
func randStat(allowMax: Bool) -> WeekStat {
  let lastT = coin(6) ? pick(SP) : epoch()
  var c = coin(5) ? pick(COUNTS) : rng.below(40)
  if allowMax, coin(20) { c = Int.max }
  return WeekStat(
    wSum: coin(5) ? pick(SP) : rng.unit() * 30, wObserved: coin(5) ? pick(SP) : rng.unit() * 20,
    wSqErr: coin(5) ? pick(SP) : rng.unit() * 5, lastT: lastT, count: c)
}

// ---- constants (the Swift statics) ----
emit("const", "crossCountryKm", hx(SeasonalStore.crossCountryKm))
emit("const", "localTripThreshold", it(SeasonalStore.localTripThreshold))
emit("const", "crossCountryTripThreshold", it(SeasonalStore.crossCountryTripThreshold))
emit("const", "minWeekSamplesForConfidence", hx(SeasonalStore.minWeekSamplesForConfidence))
emit("const", "decayHalfLifeWeeks", hx(SeasonalStore.decayHalfLifeWeeks))
emit("const", "homeMinTrips", it(SeasonalStore.homeMinTrips))
emit("const", "maxEdges", it(SeasonalStore.maxEdges))
emit("const", "originHalfLifeDays", hx(SeasonalStore.originHalfLifeDays))
emit("const", "relocationMargin", hx(SeasonalStore.relocationMargin))
emit("const", "relocationMinDays", hx(SeasonalStore.relocationMinDays))
emit("const", "featureCount", it(RouteFeatures.count))

// ---- WeekStat.decay / add / mean ----
for _ in 0..<260 {
  let s = randStat(allowMax: true)
  let t = near(s.lastT)
  let hl = coin(3) ? pick(HL) : 52
  var w = s
  w.decay(to: t, halfLifeWeeks: hl)
  emit("wd", wsf(s), hx(t), hx(hl), wsf(w))
}
for _ in 0..<260 {
  let s = randStat(allowMax: false)
  let t = near(s.lastT)
  let hl = coin(4) ? pick(HL) : 52
  let o = unitish(), p = unitish()
  var w = s
  w.add(observed: o, predicted: p, t: t, halfLifeWeeks: hl)
  emit("wa", wsf(s), hx(o), hx(p), hx(t), hx(hl), wsf(w))
}
for a in [Double.nan, 0, -0.0, .leastNonzeroMagnitude, 1, .infinity, -1] {
  for b in [Double.nan, 0, -0.0, 1, .infinity, -1, 3] {
    emit("wm", hx(a), hx(b), hx(WeekStat(wSum: a, wObserved: b).mean))
  }
}
for _ in 0..<60 { let s = randStat(allowMax: true); emit("wm", hx(s.wSum), hx(s.wObserved), hx(s.mean)) }

// ---- isModeled (the frequency gate) ----
for n in [Int.min, -1, 0, 1, 2, 3, 5, 6, 7, 100, Int.max] {
  for c in [false, true] {
    var st = SeasonalStore()
    let k = RouteKey(origin: cl(1, 2), dest: cl(3, 4))
    st.routes[k] = RouteRecord(tripCount: n, crossCountry: c)
    emit("im", it(n), bl(c), bl(st.isModeled(k)))
  }
}

// ---- RouteKey (x10) and EdgeKey (x100) quantization ----
let CQ: [Double] = [
  0, -0.0, 0.05, -0.05, 0.049999999999999996, 0.15, -0.15, 0.25, -0.25, 0.35, 0.45, 0.005, -0.005,
  0.015, 0.125, -0.125, 43.07, -89.40, 89.99, -180, 180, 179.95, -179.95, 90, -90, 1e15, -1e15,
  .leastNonzeroMagnitude, -.leastNonzeroMagnitude, 1e-300, 0.1, 0.2, 0.3, 2.5, -2.5, 0.65, 1.005,
  9.223372036854775e17, -9.223372036854775e17, 9.2233720368547758e17, -9.2233720368547758e17,
  9.223372036854775e16, -9.223372036854775e16, 9.2233720368547758e16, -9.2233720368547758e16,
  (9.2233720368547758e17).nextDown, (-9.2233720368547758e17).nextUp, 4503599627370495.5,
]
let I63 = 9.223372036854775808e18
func fits(_ v: Double, _ m: Double) -> Bool { let r = (v * m).rounded(); return r >= -I63 && r < I63 }
func qcoord(_ m: Double) -> Double {
  var v = coin(3) ? pick(CQ) : (coin(2) ? rng.unit() * 360 - 180 : Double(rng.below(4001) - 2000) / m)
  if !fits(v, m) { v = rng.unit() * 180 - 90 }
  return v
}
for _ in 0..<170 {
  let a = qcoord(10), b = qcoord(10), c = qcoord(10), d = qcoord(10)
  let k = RouteKey(origin: cl(a, b), dest: cl(c, d))
  emit("rk", hx(a), hx(b), hx(c), hx(d), it(k.oLat), it(k.oLon), it(k.dLat), it(k.dLon))
}
let small: [Double] = [40.0, 40.004, 40.005, 40.006, 39.995, -83.0, -83.005, -82.995]
for _ in 0..<170 {
  let pool = coin(2)
  let a = pool ? pick(small) : qcoord(100), b = pool ? pick(small) : qcoord(100)
  let c = pool ? pick(small) : qcoord(100), d = pool ? pick(small) : qcoord(100)
  let e = EdgeKey(cl(a, b), cl(c, d))
  emit("ek", hx(a), hx(b), hx(c), hx(d), it(e.aLat), it(e.aLon), it(e.bLat), it(e.bLon))
}
for _ in 0..<60 {
  let a = qcoord(100), b = qcoord(100), c = qcoord(100), d = qcoord(100)
  var st = SeasonalStore()
  st.recordEdges(hubPath: [cl(a, b), cl(c, d)], week: 0, observed: 0.5, t: 1)
  emit("es", hx(a), hx(b), hx(c), hx(d), hs(st.edges.keys.first!))
}
let extremes = [(Int.min, Int.max), (Int.max, Int.min), (0, 0), (-1, 1), (430, -894), (-0, 5), (Int.min, -1)]
for (la, lo) in extremes + (0..<30).map({ _ in (rng.below(1801) - 900, rng.below(3601) - 1800) }) {
  var st = SeasonalStore()
  st.recordOrigin(lat: la, lon: lo, t: 1)
  emit("ok", it(la), it(lo), hs(st.origins.keys.first!))
}

// ---- seasonalPrior ----
func wrap(_ x: Int) -> Int { ((x % 52) + 52) % 52 }
func weeksField(_ w: [Int: WeekStat]) -> String {
  lst(w.keys.sorted().map { it($0) + "/" + wsf(w[$0]!) })
}
let WEEKS: [Int] = [0, 1, 25, 50, 51, 52, 53, -1, -2, -51, -52, -53, 103, 104, -104, 1_000_000,
                    Int.min + 1, Int.max - 1]
for _ in 0..<190 {
  let k = RouteKey(origin: cl(40, -90), dest: cl(41, -91))
  var rec = RouteRecord()
  rec.tripCount = coin(4) ? pick([0, 1, 2, 5, 6, 7, Int.min, Int.max, -3]) : rng.below(12)
  rec.crossCountry = coin(2)
  let week = coin(3) ? pick(WEEKS) : rng.below(52)
  let now = coin(6) ? pick(SP) : epoch()
  let base = week % 52
  for dw in [-2, -1, 0, 1, 2] where !coin(4) {
    var s = randStat(allowMax: true)
    if !coin(5) { s.lastT = now - rng.unit() * WEEK * 60 }
    if coin(3) { s.wSum = rng.unit() * 9; s.count = 1 + rng.below(9) }
    rec.weeks[wrap(base + dw)] = s
  }
  if coin(4) { rec.weeks[pick([52, -1, 104, -53, week])] = randStat(allowMax: true) }
  var st = SeasonalStore()
  st.routes[k] = rec
  let r = st.seasonalPrior(for: k, week: week, now: now)
  emit("sp", it(rec.tripCount), bl(rec.crossCountry), it(week), hx(now), weeksField(rec.weeks),
       r.map { hx($0.risk) + "/" + hx($0.confidence) } ?? "-")
}
for week in [Int.max, Int.min] {  // not modeled: nil before the week arithmetic
  let k = RouteKey(origin: cl(40, -90), dest: cl(41, -91))
  var st = SeasonalStore()
  st.routes[k] = RouteRecord(tripCount: 1, crossCountry: false, weeks: [0: WeekStat(wSum: 1, count: 1)])
  emit("sp", "1", "0", it(week), hx(T0), weeksField(st.routes[k]!.weeks),
       st.seasonalPrior(for: k, week: week, now: T0).map { hx($0.risk) } ?? "-")
}

// ---- accuracy (order-independent inputs: <=2 weeks, or exact dyadic sums without decay) ----
for _ in 0..<90 {
  let k = RouteKey(origin: cl(35, -100), dest: cl(36, -101))
  var rec = RouteRecord()
  rec.tripCount = coin(5) ? pick([0, -1, Int.min, Int.max]) : 1 + rng.below(20)
  let now = coin(8) ? pick(SP) : epoch()
  if coin(3) {
    for wk in 0..<(3 + rng.below(20)) {
      rec.weeks[wk * 2] = WeekStat(
        wSum: Double(1 + rng.below(9)), wObserved: Double(rng.below(64)) / 64,
        wSqErr: Double(rng.below(1024)) / 1024, lastT: now + Double(rng.below(1000)), count: 1 + rng.below(9))
    }
  } else {
    for _ in 0..<(1 + rng.below(2)) {
      var s = randStat(allowMax: true)
      if !coin(4) { s.lastT = now - rng.unit() * WEEK * 100 }
      rec.weeks[rng.below(52)] = s
    }
  }
  var st = SeasonalStore()
  st.routes[k] = rec
  emit("ac", it(rec.tripCount), hx(now), weeksField(rec.weeks), opt(st.accuracy(for: k, now: now)))
}

// ---- recordOrigin: the update, the key, and the 200-cell eviction ----
for _ in 0..<170 {
  var st = SeasonalStore()
  let la = rng.below(1801) - 900, lo = rng.below(3601) - 1800
  let t = coin(5) ? pick(SP) : epoch()
  var prior: SeasonalStore.OriginStat? = nil
  if !coin(4) {
    st.recordOrigin(lat: la, lon: lo, t: 1)
    let key = st.origins.keys.first!
    let p = SeasonalStore.OriginStat(
      weighted: coin(5) ? pick(SP) : rng.unit() * 40,
      lastSeen: coin(4) ? pick([0, -0.0, .nan, .infinity, t, t.nextUp, 1]) : t - rng.unit() * DAY * 200,
      firstSeen: coin(3) ? pick([0, -0.0, .nan, 5, t]) : t - rng.unit() * DAY * 900,
      trips: coin(6) ? pick([0, -1, Int.min, Int.max - 1]) : rng.below(500))
    st.origins[key] = p
    prior = p
  }
  st.recordOrigin(lat: la, lon: lo, t: t)
  let key = st.origins.keys.first!
  emit("ou", it(la), it(lo), prior.map(osf) ?? "-", hx(t), hs(key), osf(st.origins[key]!))
}
func originsField(_ o: [String: SeasonalStore.OriginStat]) -> String {
  lst(o.keys.sorted().map { hs($0) + "=" + osf(o[$0]!) })
}
for mode in 0..<4 {
  var st = SeasonalStore()
  let t = T0 + 5e7
  let n = mode == 3 ? 240 : 200
  let tieGroup = mode == 1 ? 100 : 0
  for j in 0..<n {
    let tied = j < tieGroup
    st.origins["\(j)|\(-j)"] = SeasonalStore.OriginStat(
      weighted: tied ? 0.5 : 1 + rng.unit() * 40,
      lastSeen: tied ? t - 1e7 : t - rng.unit() * 1e6,
      firstSeen: 1, trips: 1 + rng.below(50))
  }
  if mode == 2 {  // survivors tied with each other
    for j in 150..<200 {
      st.origins["\(j)|\(-j)"] = SeasonalStore.OriginStat(weighted: 60, lastSeen: t, firstSeen: 1, trips: 3)
    }
  }
  let before = originsField(st.origins)
  let (la, lo) = mode == 3 ? (3, -3) : (5000, 5000)
  st.recordOrigin(lat: la, lon: lo, t: t)
  emit("oe", hx(t), it(la), it(lo), before, originsField(st.origins))
}

// ---- recordEdges: keys, sequential adds, and the 4000-edge eviction ----
func edgesField(_ e: [String: EdgeRecord]) -> String {
  lst(e.keys.sorted().map { key in
    let w = e[key]!.weeks
    return hs(key) + "=" + "\(w.count)" + w.keys.sorted().map { ";" + it($0) + "/" + wsf(w[$0]!) }.joined()
  })
}
let grid: [Double] = [40.00, 40.01, 40.02, 40.005, 40.015, 39.995]
for _ in 0..<50 {
  var st = SeasonalStore()
  func path(_ n: Int) -> [CLLocationCoordinate2D] {
    (0..<n).map { _ in coin(4) ? cl(qcoord(100), qcoord(100)) : cl(pick(grid), pick([-83.0, -83.01, -82.995])) }
  }
  for _ in 0..<rng.below(3) {
    st.recordEdges(hubPath: path(rng.below(6)), week: rng.below(3), observed: unitish(), t: epoch())
  }
  let before = edgesField(st.edges)
  let p = path(rng.below(8))
  let week = coin(5) ? pick([-1, 52, Int.min, Int.max]) : rng.below(3)
  let observed = unitish()
  let t = coin(5) ? pick(SP) : epoch()
  st.recordEdges(hubPath: p, week: week, observed: observed, t: t)
  emit("re", lst(p.map { hx($0.latitude) + "/" + hx($0.longitude) }), it(week), hx(observed), hx(t),
       before, edgesField(st.edges))
}
for mode in 0..<3 {
  var st = SeasonalStore()
  let n = 4000
  let perm = shuffled(n)
  var layout: [String] = []
  for j in 0..<n {
    var er = EdgeRecord()
    var offs: [String] = []
    let empty = mode == 1 && j < 2001
    let tiedHigh = mode == 2 && j >= 3000
    if !empty {
      let nw = 1 + rng.below(2)
      for q in 0..<nw {
        let off = tiedHigh ? 40_000 : perm[j] * 8 + q
        er.weeks[q] = WeekStat(wSum: 1, wObserved: 0.5, wSqErr: 0, lastT: 1e6 + Double(off), count: 1)
        offs.append(it(off))
      }
    }
    st.edges["\(j)"] = er
    layout.append(offs.joined(separator: ":"))
  }
  let p = [cl(40.0, -83.0), cl(40.03, -83.0)]
  st.recordEdges(hubPath: p, week: 7, observed: 0.3, t: 2e6)
  let survivors = st.edges.keys.compactMap { Int($0) }.sorted()
  let added = st.edges.keys.filter { Int($0) == nil }.sorted()
  emit("ee", lst(p.map { hx($0.latitude) + "/" + hx($0.longitude) }), "7", hx(0.3), hx(2e6),
       lst(layout), lst(survivors.map(it)),
       lst(added.map { hs($0) + "=" + wsf(st.edges[$0]!.weeks[7]!) }))
}

// ---- record(_:) end to end on one store ----
func routesField(_ r: [RouteKey: RouteRecord]) -> String {
  lst(r.keys.sorted { ($0.oLat, $0.oLon, $0.dLat, $0.dLon) < ($1.oLat, $1.oLon, $1.dLat, $1.dLon) }.map { k in
    let rec = r[k]!
    return [it(k.oLat), it(k.oLon), it(k.dLat), it(k.dLon), it(rec.tripCount), bl(rec.crossCountry)]
      .joined(separator: "/") + "=" + "\(rec.weeks.count)"
      + rec.weeks.keys.sorted().map { ";" + it($0) + "/" + wsf(rec.weeks[$0]!) }.joined()
  })
}
let KM: [Double] = [0, 12, (300.0).nextDown, 300, (300.0).nextUp, 2000, .nan, .infinity, -.infinity, -5, -0.0]
for _ in 0..<60 {
  var st = SeasonalStore()
  let o = cl(40 + Double(rng.below(3)) * 0.1, -90), d = cl(41, -91 + Double(rng.below(2)) * 0.1)
  for _ in 0..<rng.below(4) {
    let k = RouteKey(origin: coin(2) ? o : cl(40.1, -90), dest: coin(2) ? d : cl(41, -91))
    st.record(TripObservation(key: k, week: rng.below(4), predicted: unitish(), observed: unitish(),
                              distanceKm: pick(KM), t: epoch()))
  }
  let k = RouteKey(origin: o, dest: d)
  if coin(4), var rec = st.routes[k] {
    rec.tripCount = pick([Int.max - 1, -1, Int.min, 0])
    st.routes[k] = rec
  }
  let obs = TripObservation(
    key: k, week: coin(5) ? pick([-1, 52, 1000, Int.min, Int.max]) : rng.below(4),
    predicted: unitish(), observed: unitish(), distanceKm: coin(2) ? pick(KM) : rng.unit() * 900,
    t: coin(5) ? pick(SP) : epoch())
  let beforeR = routesField(st.routes), beforeO = originsField(st.origins)
  st.record(obs)
  emit("rc", it(k.oLat), it(k.oLon), it(k.dLat), it(k.dLon), it(obs.week), hx(obs.predicted),
       hx(obs.observed), hx(obs.distanceKm), hx(obs.t), beforeR, beforeO,
       routesField(st.routes), originsField(st.origins))
}

// ---- learnedHome (order-independent inputs: no weight ties at the top, no duplicate cells) ----
let TAMPER = ["430", "430|", "|430", "430|-894|1", "a|b", "\u{FF14}\u{FF13}|1", "430|-894\u{301}", "430\u{0}|1",
              "", "|", "||", "430||-894", "|431|-895", "432|-896|", " 433|1", "0x1A|2",
              "99999999999999999999|1", "-9223372036854775808|9223372036854775807", "+5|-0", "--5|1",
              "5|+-1", "\u{663}|1", "434|-894\n", "\u{600}|435|-894", "436|\u{301}-894", "437\u{301}|1"]
func homeCase(_ st: SeasonalStore, now: Double, current: (lat: Int, lon: Int)?) {
  let r = st.learnedHome(now: now, currentHome: current)
  emit("lh", hx(now), current.map { it($0.lat) + "/" + it($0.lon) } ?? "-", originsField(st.origins),
       r.map { hx($0.lat) + "/" + hx($0.lon) + "/" + it($0.trips) } ?? "-")
}
for c in 0..<130 {
  var st = SeasonalStore()
  let now = epoch()
  let m = 1 + rng.below(7)
  var cells: [(Int, Int)] = []
  let special = m == 1 && coin(2)
  for j in 0..<m {
    let cell = (100 + c * 10 + j, -200 - j)
    cells.append(cell)
    st.origins["\(cell.0)|\(cell.1)"] = SeasonalStore.OriginStat(
      weighted: special ? pick(SP) : rng.unit() * 40,
      lastSeen: special && coin(2) ? pick(SP) : now - rng.unit() * DAY * 90,
      firstSeen: coin(6) ? pick([0, .nan, now, -.infinity]) : now - rng.unit() * DAY * 70,
      trips: coin(8) ? pick([0, -40, 100]) : 1 + rng.below(8))
  }
  // A NaN or equal weight at the top makes max(by:) depend on iteration
  // order, so special weights and clocks only appear with one valid cell.
  let tamper = !special && coin(3)
  if tamper {
    st.origins[pick(TAMPER)] = SeasonalStore.OriginStat(weighted: 1000, lastSeen: now, firstSeen: 1, trips: rng.below(30))
  }
  var current: (lat: Int, lon: Int)? = nil
  if !coin(3) {
    if coin(5) { current = (lat: 7, lon: 7) } else { let x = pick(cells); current = (lat: x.0, lon: x.1) }
  }
  homeCase(st, now: m == 1 && !tamper && coin(4) ? pick(SP) : now, current: current)
}
for k in TAMPER {  // each tamper key alone with a healthy trip count
  var st = SeasonalStore()
  st.origins[k] = SeasonalStore.OriginStat(weighted: 2, lastSeen: T0, firstSeen: 1, trips: 20)
  homeCase(st, now: T0, current: nil)
  homeCase(st, now: T0, current: (430, -894))
}
// (2, 2) is a tie that includes the incumbent, which resolves the same in any
// order; a (0, 0) tie would not, so it is left out (a finding).
for (bw, iw, first) in [(3.0, 2.0, T0 - 30 * DAY), ((3.0).nextDown, 2.0, T0 - 30 * DAY),
                        (3.0, 2.0, (T0 - 30 * DAY).nextUp), (2.0, 2.0, 0), (Double.infinity, 1, 0)] {
  var st = SeasonalStore()
  st.origins["1|1"] = SeasonalStore.OriginStat(weighted: bw, lastSeen: T0, firstSeen: first, trips: 10)
  st.origins["2|2"] = SeasonalStore.OriginStat(weighted: iw, lastSeen: T0, firstSeen: 1, trips: 9)
  homeCase(st, now: T0, current: (2, 2))
  homeCase(st, now: T0, current: (1, 1))
}
for _ in 0..<50 {  // legacy: no origins, routes only; distinct per-cell totals
  var st = SeasonalStore()
  let n = 1 + rng.below(6)
  let counts = shuffled(40).prefix(n)
  for (j, tc) in counts.enumerated() {
    let k = RouteKey(origin: cl(Double(j) * 0.3 - 1, 2 + Double(j)), dest: cl(Double(rng.below(3)), 5))
    st.routes[k] = RouteRecord(tripCount: tc, crossCountry: coin(2))
  }
  if coin(3) {  // two routes share an origin cell: powers of two keep totals distinct
    let k1 = RouteKey(origin: cl(9, 9), dest: cl(1, 1)), k2 = RouteKey(origin: cl(9, 9), dest: cl(2, 2))
    st.routes[k1] = RouteRecord(tripCount: 64, crossCountry: false)
    st.routes[k2] = RouteRecord(tripCount: 128, crossCountry: true)
  }
  let r = st.learnedHome(now: T0, currentHome: coin(2) ? nil : (90, 90))
  emit("lg", routesField(st.routes), r.map { hx($0.lat) + "/" + hx($0.lon) + "/" + it($0.trips) } ?? "-")
}

// ---- trainingRows ----
for _ in 0..<45 {
  var st = SeasonalStore()
  let now = coin(8) ? pick(SP) : epoch()
  for _ in 0..<rng.below(4) {
    let k = RouteKey(origin: cl(rng.unit() * 50, -rng.unit() * 120), dest: cl(rng.unit() * 50, -rng.unit() * 120))
    var rec = RouteRecord(tripCount: rng.below(9), crossCountry: coin(2))
    for _ in 0..<rng.below(5) {
      var s = randStat(allowMax: true)
      if !coin(4) { s.lastT = now - rng.unit() * WEEK * 80 }
      if coin(2) { s.wSum = rng.unit() * 9; s.wObserved = rng.unit() * s.wSum }
      rec.weeks[coin(8) ? pick([-1, 52, Int.max]) : rng.below(52)] = s
    }
    st.routes[k] = rec
  }
  let rows = st.trainingRows(now: now)
  let cols = ["oLat", "oLon", "dLat", "dLon", "week", "target", "weight", "crossCountry"]
  let sortedRows = rows.sorted { a, b in
    (a["oLat"]!, a["oLon"]!, a["dLat"]!, a["dLon"]!, a["week"]!) < (b["oLat"]!, b["oLon"]!, b["dLat"]!, b["dLon"]!, b["week"]!)
  }
  emit("tr", hx(now), routesField(st.routes),
       lst(sortedRows.map { r in cols.map { hx(r[$0]!) }.joined(separator: "/") }))
}

// ---- RouteFeatures.vector ----
let RFW: [Int] = [0, 1, 13, 26, 39, 51, 52, -1, -52, 1000, Int.max, Int.min]
for _ in 0..<220 {
  func c(_ span: Double) -> Double { coin(6) ? pick(SP + [90, -90, 180, -180, 45]) : rng.unit() * 2 * span - span }
  let (a, b, cc, d) = coin(8) ? (10.0, 20.0, -10.0, -160.0) : (c(90), c(180), c(90), c(180))
  let week = coin(3) ? pick(RFW) : rng.below(52)
  let cross = coin(2)
  let v = RouteFeatures.vector(oLat: a, oLon: b, dLat: cc, dLon: d, week: week, crossCountry: cross)
  emit("rf", hx(a), hx(b), hx(cc), hx(d), it(week), bl(cross), vec(v))
}

// ---- LearnedHead.predict (tolerant shapes) ----
func wv() -> Double { coin(12) ? pick(SP) : rng.unit() * 1.6 - 0.8 }
func randHead(hidden: Int, width: Int, ragged: Bool, mismatch: Bool, rowsMeta: Int?) -> LearnedHead {
  let w1 = (0..<hidden).map { j in (0..<(ragged && j > 0 ? rng.below(width + 3) : width)).map { _ in wv() } }
  let nb1 = mismatch ? rng.below(hidden + 2) : hidden, nw2 = mismatch ? rng.below(hidden + 2) : hidden
  return LearnedHead(w1: w1, b1: (0..<nb1).map { _ in wv() }, w2: (0..<nw2).map { _ in wv() }, b2: wv(),
                     version: rng.below(9), rows: rowsMeta)
}
for _ in 0..<70 {
  let h = randHead(hidden: rng.below(6), width: pick([8, 8, 6, 9, 0]), ragged: coin(3), mismatch: coin(3), rowsMeta: nil)
  let x = (0..<pick([8, 8, 0, 3, 11])).map { _ in coin(10) ? pick(SP) : rng.unit() * 2 - 1 }
  emit("hp", headf(h), vec(x), hx(h.predict(x)))
}

// ---- RouteHeadTrainer.fineTune and meanSquaredError ----
let COLS = ["oLat", "oLon", "dLat", "dLon", "week", "target", "weight", "crossCountry"]
func rowsField(_ rows: [[String: Double]]) -> String {
  "\(rows.count)" + rows.map { r in ";" + COLS.map { r[$0].map(hx) ?? "-" }.joined(separator: ":") }.joined()
}
func randRows(_ n: Int, realistic: Bool) -> [[String: Double]] {
  (0..<n).map { _ in
    var r: [String: Double] = [:]
    let target: Double? = realistic ? rng.unit() : (coin(8) ? nil : (coin(5) ? pick(SP) : rng.unit() * 1.2 - 0.1))
    let finite = target?.isFinite ?? false
    let present = { (p: Int) -> Bool in realistic || !coin(p) }
    if present(9) { r["oLat"] = realistic ? Double(rng.below(500)) / 10 : (coin(8) ? pick(SP) : rng.unit() * 120 - 60) }
    if present(9) { r["oLon"] = realistic ? -Double(rng.below(1200)) / 10 : rng.unit() * 360 - 180 }
    if present(9) { r["dLat"] = realistic ? Double(rng.below(500)) / 10 : rng.unit() * 120 - 60 }
    if present(9) { r["dLon"] = realistic ? -Double(rng.below(1200)) / 10 : (coin(8) ? pick(SP) : rng.unit() * 360 - 180) }
    if present(9) {
      r["week"] = realistic ? Double(rng.below(52))
        : (finite ? pick([0, 12, 51, 52, -3, 3.7, -3.7, 9.2e18, -9.2e18, 1e10]) : pick([Double.nan, .infinity, 1e300, 5]))
    }
    if let target { r["target"] = target }
    if present(9) { r["weight"] = realistic ? rng.unit() * 6 : (coin(5) ? pick(SP) : rng.unit() * 3) }
    if present(9) { r["crossCountry"] = realistic ? Double(rng.below(2)) : pick([0, 1, 0.5, (0.5).nextUp, .nan, -1]) }
    return r
  }
}
for c in 0..<40 {
  let width = coin(7) ? pick([7, 9, 0]) : 8
  let hidden = 1 + rng.below(4)
  var base = randHead(hidden: hidden, width: width, ragged: false, mismatch: coin(10), rowsMeta: coin(3) ? nil : pick([0, 1_164_376, 7]))
  if coin(4) { base.tunedOnDevice = coin(2) }
  let rows = randRows(rng.below(11), realistic: false)
  var epochs = pick([0, 1, 2, 3, 7, 60])
  let hasSample = rows.contains { $0["target"]?.isFinite ?? false }
  if !hasSample, coin(3) { epochs = -1 }  // Range precondition not reached: nil before the loop
  let useDefaults = c % 5 == 0
  if epochs == 0, !useDefaults, hidden > 1, coin(2) {  // a longer or shorter later row is legal with no epochs
    var w1 = base.w1; w1[1] = w1[1] + [0.25]; if hidden > 2 { w1[2] = Array(w1[2].prefix(3)) }
    base = LearnedHead(w1: w1, b1: base.b1, w2: base.w2, b2: base.b2, version: base.version, rows: base.rows)
  } else if hidden > 1, coin(4) {
    var w1 = base.w1; w1[hidden - 1] = w1[hidden - 1] + [0.5, -0.5]
    base = LearnedHead(w1: w1, b1: base.b1, w2: base.w2, b2: base.b2, version: base.version, rows: base.rows)
  }
  let lr = coin(3) ? pick([0.01, 0, -0.01, 1, 50, .nan]) : rng.unit() * 0.1
  let anchor = coin(3) ? pick([0.02, 0, 1, 2, .infinity]) : rng.unit() * 0.1
  let tuned = useDefaults ? RouteHeadTrainer.fineTune(base: base, rows: rows)
    : RouteHeadTrainer.fineTune(base: base, rows: rows, epochs: epochs, learningRate: lr, anchor: anchor)
  // The two meanSquaredError calls fineTuneHeadIfDue makes ride on the same
  // record, so the rows are written once.
  emit("ft", headf(base), headMeta(base), rowsField(rows), useDefaults ? "d" : it(epochs),
       useDefaults ? "d" : hx(lr), useDefaults ? "d" : hx(anchor),
       tuned.map(headf) ?? "-", tuned.map(headMeta) ?? "-",
       opt(RouteHeadTrainer.meanSquaredError(base, rows: rows)),
       tuned.map { opt(RouteHeadTrainer.meanSquaredError($0, rows: rows)) } ?? "-")
}
for _ in 0..<20 {
  let h = randHead(hidden: rng.below(5), width: pick([8, 8, 5, 10]), ragged: coin(2), mismatch: coin(2), rowsMeta: nil)
  let rows = randRows(rng.below(9), realistic: false)
  emit("me", headf(h), rowsField(rows), opt(RouteHeadTrainer.meanSquaredError(h, rows: rows)))
}
// The shipped baseline, fine-tuned on realistic rows with the app's defaults.
if CommandLine.arguments.count > 1,
   let data = FileManager.default.contents(atPath: CommandLine.arguments[1]),
   let baseline = try? JSONDecoder().decode(LearnedHead.self, from: data) {
  for n in [1, 40, 150] {
    let rows = randRows(n, realistic: true)
    let tuned = RouteHeadTrainer.fineTune(base: baseline, rows: rows)
    emit("ft", headf(baseline), headMeta(baseline), rowsField(rows), "d", "d", "d",
         tuned.map(headf) ?? "-", tuned.map(headMeta) ?? "-",
         opt(RouteHeadTrainer.meanSquaredError(baseline, rows: rows)),
         tuned.map { opt(RouteHeadTrainer.meanSquaredError($0, rows: rows)) } ?? "-")
  }
} else {
  FileHandle.standardError.write("usage: oracle <path to baseline_route_head.json>\n".data(using: .utf8)!)
  exit(2)
}

// ---- week(): day-of-year to week ----
let gregorian = Calendar(identifier: .gregorian)
for d in 0..<366 {
  let date = Date(timeIntervalSince1970: 1_704_110_400 + Double(d) * DAY)  // 2024-01-01T12:00Z, a leap year
  emit("wk", it(gregorian.ordinality(of: .day, in: .year, for: date)!), it(SeasonalRiskModel.week(date)))
}

// ---- copied: expressions inside the @MainActor class ----
// SeasonalRiskModel.swift:538-540 (priorForRanking), verbatim.
func copiedBlend(_ head: LearnedHead, _ x: [Double], _ stat: (risk: Double, confidence: Double)) -> (risk: Double, confidence: Double) {
  let modeled = head.predict(x)
  let c = min(max(stat.confidence, 0), 1)
  return (modeled * (1 - c) + stat.risk * c, stat.confidence)
}
let flat = LearnedHead(w1: [], b1: [], w2: [], b2: 0, version: 0)
for _ in 0..<150 {
  let b2 = coin(6) ? pick(SP) : rng.unit() * 8 - 4
  let risk = unitish(), conf = unitish()
  let h = LearnedHead(w1: flat.w1, b1: flat.b1, w2: flat.w2, b2: b2, version: 0)
  let r = copiedBlend(h, [], (risk, conf))
  emit("copied-blend", hx(h.predict([])), hx(risk), hx(conf), hx(r.risk), hx(r.confidence))
}
// SeasonalRiskModel.swift:490-496 (applyHead), verbatim; version identifies the choice.
func copiedChoose(local: LearnedHead?, bundled: LearnedHead?) -> Int {
  var head: LearnedHead?
  switch (local, bundled) {
  case let (l?, b?):
    head = (l.tunedOnDevice ?? false) ? l : ((l.rows ?? 0) >= (b.rows ?? 0) ? l : b)
  case let (l?, nil): head = l
  case let (nil, b?): head = b
  default: head = nil
  }
  return head?.version ?? 0
}
let ROWS: [Int?] = [nil, 0, -1, 5, 1_164_376, Int.max, Int.min]
for lp in [false, true] { for bp in [false, true] { for lt in [nil, false, true] as [Bool?] {
  for _ in 0..<(lp && bp ? 12 : 1) {
    let lr = pick(ROWS), br = pick(ROWS)
    let l = lp ? LearnedHead(w1: [], b1: [], w2: [], b2: 0, version: 1, rows: lr, tunedOnDevice: lt) : nil
    let b = bp ? LearnedHead(w1: [], b1: [], w2: [], b2: 0, version: 2, rows: br) : nil
    emit("copied-choose", bl(lp), lt.map(bl) ?? "-", lr.map(it) ?? "-", bl(bp), br.map(it) ?? "-",
         it(copiedChoose(local: l, bundled: b)))
  }
} } }
// SeasonalRiskModel.swift:549-553 (fineTuneHeadIfDue gates), verbatim up to the first mutation.
func copiedDue(trips: Int, lastTunedAt: Date?, now: Date, tunedAtTripCount: Int) -> Bool {
  guard trips >= 12 else { return false }   // too little to learn from
  if let last = lastTunedAt, now.timeIntervalSince(last) < 86_400 { return false }
  guard trips - tunedAtTripCount >= 5 else { return false }
  return true
}
for _ in 0..<160 {
  let trips = coin(4) ? pick([11, 12, 13, 16, 17, 0, -5]) : rng.below(60)
  let tuned = coin(4) ? pick([0, trips - 5, trips - 4, trips, trips + 1]) : rng.below(60)
  let now = Date(timeIntervalSinceReferenceDate: 7e8 + rng.unit() * 1e7)
  let gap = pick([86_400, (86_400.0).nextDown, (86_400.0).nextUp, 0, -1, 1e6, rng.unit() * 2e5, .nan, .infinity])
  let last: Date? = coin(3) ? nil : now.addingTimeInterval(-gap)
  emit("copied-due", it(trips), bl(last != nil), last.map { hx(now.timeIntervalSince($0)) } ?? "-", it(tuned),
       bl(copiedDue(trips: trips, lastTunedAt: last, now: now, tunedAtTripCount: tuned)))
}
// SeasonalRiskModel.swift:562 (accept the tune), verbatim.
for a in SP.prefix(12) { for b in [Double.nan, 0, -0.0, 0.25, .leastNonzeroMagnitude, 1, .infinity] {
  let tunedError = a, baseError = b
  emit("copied-accept", hx(a), hx(b), bl(tunedError <= baseError))
} }
// SeasonalRiskModel.swift:585-586 (learningSummary calibration mean), verbatim over a given order.
for _ in 0..<50 {
  let errors = (0..<rng.below(9)).map { _ in coin(8) ? pick(SP) : rng.unit() * 0.7 }
  let mean = errors.isEmpty ? nil : errors.reduce(0, +) / Double(errors.count)
  emit("copied-mean", lst(errors.map(hx)), opt(mean))
}

FileHandle.standardOutput.write(out.data(using: .utf8)!)
