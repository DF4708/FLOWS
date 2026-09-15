import Foundation
// Frozen oracle: every output below comes from the ORIGINAL Swift trip and
// vehicle code, before it is replaced by calls into Rust. Doubles are IEEE-754
// bit patterns in hex; UInt64 values are plain hex; strings are "s:" + UTF-8
// hex; nil is "-"; lists are "L<n>:" + comma-separated items.
//
// Inputs come from a seeded SplitMix64 and fixed tables. No Dictionary or Set
// is ever iterated here.

// The one dependency of the original sources the oracle does not compile:
// EPAVehicleDatabase.swift's networking actor calls ThrottledNet, which pulls
// in the app's adaptive tuning and diagnostics. Nothing here fetches, so this
// stand-in only satisfies the type checker. Every original file is compiled
// byte for byte.
enum ThrottledNet {
    static func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

/// VehicleStore persists through UserDefaults. An in-memory stand-in keeps the
/// oracle off the user's preferences; it is read and written by key only.
final class MemDefaults: UserDefaults {
    private var doubles: [String: Double] = [:]
    private var objects: [String: Any] = [:]
    init() { super.init(suiteName: "flows.oracle.tripvehicle.memory")! }
    override func double(forKey defaultName: String) -> Double { doubles[defaultName] ?? 0 }
    override func set(_ value: Double, forKey defaultName: String) { doubles[defaultName] = value }
    override func data(forKey defaultName: String) -> Data? { objects[defaultName] as? Data }
    override func set(_ value: Any?, forKey defaultName: String) { objects[defaultName] = value }
    override func removeObject(forKey defaultName: String) { objects[defaultName] = nil }
}

func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func hu(_ u: UInt64) -> String { String(u, radix: 16) }
func hs(_ s: String) -> String { "s:" + s.utf8.map { String(format: "%02x", $0) }.joined() }
func lst(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: ",") }
func opt(_ d: Double?) -> String { d.map(hx) ?? "-" }
func bit(_ b: Bool) -> String { b ? "1" : "0" }
var out = ""
func emit(_ f: String...) { out += f.joined(separator: "\t") + "\n" }

struct SM {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15; var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func pick<T>(_ a: [T]) -> T { a[below(a.count)] }
    mutating func chance(_ n: Int) -> Bool { below(n) == 0 }
}
var rng = SM(s: 0x5452_4950_5645_4821)   // "TRIPVEH!"

func around(_ x: Double) -> [Double] { [x.nextDown, x, x.nextUp] }
let G: [Double] = [.nan, -Double.nan, .signalingNaN, .infinity, -.infinity, 0.0, -0.0,
                   .leastNonzeroMagnitude, -.leastNonzeroMagnitude, .greatestFiniteMagnitude,
                   -.greatestFiniteMagnitude, 1e-9, 1, -1]
let G8: [Double] = [.nan, .infinity, -.infinity, 0.0, -0.0, .leastNonzeroMagnitude, -1, .greatestFiniteMagnitude]

func fuelCode(_ f: FuelType) -> Int { FuelType.allCases.firstIndex(of: f)! }
func needCode(_ n: TripNeeds.Need) -> Int {
    switch n {
    case .fuel(let f): return fuelCode(f)
    case .food(let c): return 10 + FoodCategory.allCases.firstIndex(of: c)!
    case .rest: return 20
    }
}

// ---------------------------------------------------------------- tables
emit("table", "fuelTypes", lst(FuelType.allCases.map { hs($0.rawValue) }))
emit("table", "foodCategories", lst(FoodCategory.allCases.map { hs($0.rawValue) }))
let allNeeds: [TripNeeds.Need] = FuelType.allCases.map { .fuel($0) }
    + FoodCategory.allCases.map { .food($0) } + [.rest]
emit("table", "needLabels", lst(allNeeds.map { "\(needCode($0))=" + hs($0.label) }))
emit("table", "assistWords", lst(CrashLogic.assistWords.map(hs)))
emit("table", "okWords", lst(CrashLogic.okWords.map(hs)))

emit("const", "impactGForce", hx(CrashLogic.impactGForce))
emit("const", "hardImpactGForce", hx(CrashLogic.hardImpactGForce))
emit("const", "confirmImpactGForce", hx(CrashLogic.confirmImpactGForce))
emit("const", "minPreImpactSpeedMps", hx(CrashLogic.minPreImpactSpeedMps))
emit("const", "crashStopSpeedMps", hx(CrashLogic.crashStopSpeedMps))
emit("const", "minSpeedDropFraction", hx(CrashLogic.minSpeedDropFraction))
emit("const", "maxMetersFromRoad", hx(CrashLogic.maxMetersFromRoad))
emit("const", "breakDueSeconds", hx(HOSRules.breakDueSeconds))
emit("const", "warnBeforeBreakSeconds", hx(HOSRules.warnBeforeBreakSeconds))
emit("const", "dailyDrivingLimitSeconds", hx(HOSRules.dailyDrivingLimitSeconds))
emit("const", "breakResetSeconds", hx(HOSRules.breakResetSeconds))
emit("const", "reserveMiles", hx(VehicleProfile.reserveMiles))
emit("const", "defaultMilesPerUnit", hx(TripCosts.defaultMilesPerUnit))
emit("const", "minimumHeightFeet", hx(VehicleSpecs.minimumHeightFeet))
emit("defaultFuel", String(fuelCode(TripCosts.defaultFuel)))

// ---------------------------------------------------------------- vehicle spec table
for (i, s) in VehicleSpecs.all.enumerated() {
    emit("spec", String(i), hs(s.make), hs(s.model), String(fuelCode(s.fuelType)),
         hx(s.cityMPU), hx(s.highwayMPU), hx(s.tankUnits), hx(s.heightFeet),
         opt(s.gvwrLbs), opt(s.towCapacityLbs), opt(s.gcwrLbs),
         opt(s.publishedMaxGradePercent), opt(s.topSpeedMph),
         hx(s.combinedMPU), hx(s.profile.ratedMilesPerUnit))
}
emit("makes", lst(VehicleSpecs.makes.map(hs)))
func rowIndex(_ s: VehicleSpec) -> String { String(VehicleSpecs.all.firstIndex(of: s)!) }
let oddNames = ["", "toyota", "TOYOTA", "Toyota ", " Toyota", "Toyota\u{0}", "To\u{301}yota",
                "\u{212A}enworth", "Kenworth", "kenworth", "Mercedes\u{2010}Benz", "Mercedes-Benz",
                "Generic", "RV", "Box truck", "Tesla", "Ram", "Rivian", "Nope", "Ford\u{200D}", "\u{600}Ford"]
for m in VehicleSpecs.makes + oddNames {
    emit("models", hs(m), lst(VehicleSpecs.models(make: m).map(rowIndex)))
}
var lookups: [(String, String)] = VehicleSpecs.all.map { ($0.make, $0.model) }
lookups += [("Toyota", "camry"), ("toyota", "Camry"), ("Toyota", "Camry "), ("Toyota", ""), ("", "Camry"),
            ("\u{212A}enworth", "T680 (semi)"), ("Kenworth", "T680 (semi)"), ("Kenworth", "T680 (semi)\u{0}"),
            ("Ford", "F-150"), ("Ford", "F\u{2011}150"), ("Ford", "F-150\u{301}"), ("Ford", "Transit"),
            ("Tesla", "Model 3"), ("Tesla", "Model\u{00A0}3"), ("RV", "Class C motorhome"),
            ("Mercedes-Benz", "Sprinter (high roof, diesel)"), ("Generic", "Bus"), ("Custom", "vehicle"),
            ("Peterbilt", "579 (semi)"), ("Ram", "1500"), ("Ram", "1500\u{FE0F}")]
for (make, model) in lookups {
    emit("lookup", hs(make), hs(model), VehicleSpecs.spec(make: make, model: model).map(rowIndex) ?? "-")
}
// combinedMPU and the rated rounding over arbitrary city/highway pairs.
let cityPool: [Double] = G8 + [4.4, 28, 32, 57, 6.0, 0.55, 1e-300] + around(25)
let hwyPool: [Double] = G8 + [4.0, 39, 41, 56, 7.5, 0.45] + around(25)
for c in cityPool { for h in hwyPool {
    let s = VehicleSpec(make: "x", model: "y", fuelType: .gas, cityMPU: c, highwayMPU: h, tankUnits: 1, heightFeet: 1)
    emit("combined", hx(c), hx(h), hx(s.combinedMPU), hx(s.profile.ratedMilesPerUnit))
} }
for _ in 0..<200 {
    let c = rng.unit() * 60 + 1, h = rng.unit() * 60 + 1
    let s = VehicleSpec(make: "x", model: "y", fuelType: .gas, cityMPU: c, highwayMPU: h, tankUnits: 1, heightFeet: 1)
    emit("combined", hx(c), hx(h), hx(s.combinedMPU), hx(s.profile.ratedMilesPerUnit))
}

// ---------------------------------------------------------------- trip costs
for f in FuelType.allCases { emit("co2unit", String(fuelCode(f)), hx(TripCosts.gramsCO2PerUnit(f))) }
for rail in [false, true] { for long in [false, true] {
    emit("transit", bit(rail), bit(long), hx(TripCosts.transitGramsCO2PerMile(rail: rail, longHaul: long)))
} }
let milesPool = G8 + [12.3, 300]
let mpuPool = G8 + [4, 30]
let pricePool: [Double] = [.nan, .infinity, 0.0, -0.0, 3.2, .leastNonzeroMagnitude]
for m in milesPool { for u in mpuPool { for p in pricePool {
    emit("fuelcost", hx(m), hx(u), hx(p), opt(TripCosts.driveFuelCostUSD(miles: m, milesPerUnit: u, pricePerUnit: p)))
} } }
for _ in 0..<150 {
    let m = rng.unit() * 3000, u = rng.unit() * 60, p = rng.unit() * 6
    emit("fuelcost", hx(m), hx(u), hx(p), opt(TripCosts.driveFuelCostUSD(miles: m, milesPerUnit: u, pricePerUnit: p)))
}
for f in FuelType.allCases {
    for u in G + [4, 3.5, 25, 30] + (0..<10).map({ _ in rng.unit() * 60 }) {
        emit("co2mile", String(fuelCode(f)), hx(u), opt(TripCosts.driveGramsCO2PerMile(fuel: f, milesPerUnit: u)))
    }
}

// ---------------------------------------------------------------- trip needs
for seed: UInt64 in [0, 1, 42, 43, UInt64.max, 0x9E37_79B9_7F4A_7C15, 0x6A09_E667_F3BC_C909] + (0..<5).map({ _ in rng.next() }) {
    var g = TripNeeds.SplitMix64(seed: seed)
    emit("smix", hu(seed), lst((0..<6).map { _ in hu(g.next()) }))
}

func intervals(_ v: [Double?]) -> TripNeeds.Intervals {
    TripNeeds.Intervals(gasMiles: v[0], dieselMiles: v[1], electricMiles: v[2], foodMiles: v[3], restMiles: v[4])
}
let hybrid: [Double?] = [nil, 350, 500, 100, 200]
var schedules: [(Double, [Double?], UInt64)] = [
    (2000, hybrid, 42), (2000, hybrid, 0), (2000, hybrid, 1), (2000, hybrid, 43),
    (700, [300, nil, nil, nil, nil], 0), (1000, [nil, 350, nil, nil, nil], 0),
    (1000, [100, 100, 100, 100, 100], 7), (600, [150, 300, 150, 50, 300], UInt64.max),
    (3, [0.1, nil, nil, 0.3, 0.2], 9), (1.0000000000000002, [0.1, 0.1, nil, 0.1, nil], 3),
    (700, [350, (350.0).nextUp, (350.0).nextDown, 700, (700.0).nextDown], 5),
    (0, hybrid, 0), (-0.0, hybrid, 0), (.nan, hybrid, 0), (-5, hybrid, 0), (.leastNonzeroMagnitude, hybrid, 0),
    (.infinity, [nil, nil, nil, nil, nil], 0), (.infinity, [.infinity, .infinity, nil, .infinity, nil], 11),
    (.greatestFiniteMagnitude, [.greatestFiniteMagnitude, nil, nil, nil, .infinity], 2),
    (700, [0, -1, .nan, -.infinity, 350], 0), (700, [-0.0, 0, nil, .nan, nil], 4),
    (50, [nil, nil, nil, 20, 20], 12), (20.000000000000004, [nil, nil, nil, 20, 20], 12),
    (1e-300, [1e-302, nil, nil, nil, nil], 6), (5000, [7.5, nil, nil, 20, 20], 99),
]
let tieSteps: [Double] = [50, 100, 150, 200, 300, 350, 500]
for _ in 0..<80 {
    let total = rng.chance(10) ? rng.pick([0.0, -1, .nan, 1, 2500]) : rng.unit() * 2500
    var iv: [Double?] = []
    for _ in 0..<5 {
        switch rng.below(6) {
        case 0, 1: iv.append(nil)
        case 2: iv.append(rng.pick(tieSteps))
        case 3: iv.append(rng.pick([0.0, -5, .nan, .infinity, -0.0, 2500]))
        default: iv.append(rng.unit() * 700 + 6)
        }
    }
    schedules.append((total, iv, rng.next()))
}
for (total, iv, seed) in schedules {
    let events = TripNeeds.schedule(totalMiles: total, intervals: intervals(iv), seed: seed)
    emit("sched", hx(total), lst(iv.map(opt)), hu(seed),
         lst(events.map { hx($0.mile) }), lst(events.map { String(needCode($0.need)) }))
    var queries: [Double] = [.nan, -.infinity, -0.0, 0, total, .infinity]
    if let first = events.first { queries += around(first.mile) }
    if events.count > 2 { queries += around(events[events.count / 2].mile) }
    if let last = events.last { queries += around(last.mile) }
    for q in queries {
        let hit = TripNeeds.next(after: q, in: events)
        let idx = hit.flatMap { h in events.firstIndex(of: h) }
        emit("next", hx(q), idx.map { String($0) } ?? "-")
    }
}
// The Swift default seed argument is 0.
do {
    let events = TripNeeds.schedule(totalMiles: 1234, intervals: intervals([nil, nil, nil, 100, 300]))
    emit("sched", hx(1234), lst([nil, nil, nil, 100, 300].map(opt)), hu(0),
         lst(events.map { hx($0.mile) }), lst(events.map { String(needCode($0.need)) }))
}
let adjPool: [Double] = G + [3600, 21600, 1234, -50] + around(0)
for b in adjPool { for d in adjPool {
    emit("adj", hx(b), hx(d), hx(TripNeeds.adjustedRemainingSeconds(baseline: b, stopDelaySeconds: d)))
} }

// ---------------------------------------------------------------- crash logic
let accelPool: [Double] = G + around(2.5) + around(5) + around(8) + [9, 4, 1]
for a in accelPool { emit("impg", hx(a), bit(CrashLogic.isImpact(accelerationG: a))) }

let rest24 = [Double](repeating: 1.0, count: 24)
var windows: [[Double]] = [
    [], [1.0], [8], [(8.0).nextDown], [5], [(5.0).nextDown], [.nan], [.nan, 9], [9, .nan], [1, .nan, 9],
    [1, .nan, 0.5], [.infinity], [-.infinity], [5, 2.5, 2.5], [5, 2.5, (2.5).nextDown], [5, 3, 3, 1], [5, 3],
    [5, 5, 5], [2.5, 2.5, 2.5], [2.5, 2.5, 2.5, (5.0).nextDown], [-0.0, 0.0], [.nan, .nan, .nan],
    [5, .nan, 3, 3], [.nan, 8, 8, 8], [7.9, 2.6, 2.6, 2.6], [.infinity, .nan],
    rest24 + [8.5], rest24 + [5.5], [1.0, 1.2, 5.5, 3.1, 2.8, 2.6, 1.5] + [Double](repeating: 1.0, count: 18), rest24,
]
for _ in 0..<60 {
    var w = (0..<25).map { _ in 1 + (rng.unit() - 0.5) * 0.6 }
    if rng.chance(2) {
        let at = rng.below(25); w[at] = rng.unit() * 6 + 4
        for k in 1..<(1 + rng.below(5)) where at + k < 25 { w[at + k] = rng.unit() * 2.5 + 1.5 }
    }
    windows.append(w)
}
for _ in 0..<80 {
    windows.append((0..<(1 + rng.below(8))).map { _ in rng.chance(3) ? rng.pick(accelPool) : rng.unit() * 10 })
}
for (i, w) in windows.enumerated() {
    emit("win", String(i), lst(w.map(hx)))
    emit("impw", String(i), bit(CrashLogic.isImpact(window: w)))
}
let impacting = windows.indices.filter { CrashLogic.isImpact(window: windows[$0]) }
let beforePool: [Double] = [.nan, -.infinity, 0, 1.5, 10, 25, 29, 30, .infinity, 0.001, -0.0, .greatestFiniteMagnitude] + around(8.9)
let afterPool: [Double] = [.nan, -0.0, 0, 20, 22, .infinity, -1, 4.005, -.infinity] + around(4.5)
let metersPool: [Double?] = [nil, .nan, -.infinity, 0, 5, 900, .infinity, -0.0] + around(60).map { Optional($0) }
func crashRecord(_ wi: Int, _ b: Double, _ a: Double, _ m: Double?) {
    let e = CrashLogic.ImpactEvidence(window: windows[wi], speedBeforeMps: b, speedAfterMps: a, metersFromRoad: m)
    emit("crash", String(wi), hx(b), hx(a), opt(m), bit(CrashLogic.isCrash(e)))
}
for (b, a) in [(10.0, 4.5), (10.0, (4.5).nextUp), ((10.0).nextDown, 4.5), (8.9, 4.005), (8.9, (4.005).nextUp), (8.9, (4.005).nextDown)] {
    for m in metersPool { crashRecord(impacting[0], b, a, m) }
}
for _ in 0..<700 {
    let wi = rng.chance(4) ? rng.below(windows.count) : rng.pick(impacting)
    let b = rng.chance(2) ? rng.pick(beforePool) : rng.unit() * 40
    let a = rng.chance(2) ? rng.pick(afterPool) : rng.unit() * 12
    crashRecord(wi, b, a, rng.pick(metersPool))
}

var replies: [String] = [
    "Yes I need help", "call 911", "no I'm fine", "I'm OK really", "uh what happened",
    "yeah please hurry", "I'm bleeding", "send help now", "yep", "call an ambulance", "mayday mayday",
    "nah all good", "false alarm sorry", "we're fine thanks", "nope", "stop asking", "never mind, don't call",
    "I don't know what happened", "it was fine yesterday", "", " ", "YES", "No", "NO!", "no.", "yes?",
    "i\u{2019}m ok", "I\u{2019}m fine", "don\u{2019}t call", "no\u{301}", "yes\u{301}", "n\u{301}o", "\u{301}no",
    "no\u{200D}", "yes\u{1F3FD}", "\u{600}no", "\u{600} no", "no\u{600}", "help\u{0}", "\u{0}help", "he\u{0}lp",
    "no\r\n", "\r\nyes", "yes\u{2028}", "sos\u{FE0F}", "SOS\u{1F198}", "\u{212A}", "NEGATIVE", "İ am ok",
    "i'm okay", "im okay", "i am okay", "i'm ok\u{301}", "i'm ok\u{200D}", "\u{600}i'm ok", "xi'm ok", "i'm okey",
    "call nine one one", "call 911 now", "call 9111", "call 91\u{301}1", "CALL 911", "call  911", "call\t911",
    "can't move", "cant move", "can\u{2019}t move", "can't\u{301} move", "cannot move", "i can't move",
    "yes no", "no yes", "help no", "nevermind", "never mind", "nevermind\u{301}", "don't", "dont call", "don'tcall",
    "'no'", "''no''", "no'", "'yes", "yes'\u{301}", "no'\u{301}", "yes-no", "yes_no", "yes1", "1yes", "yesterday",
    "Noah", "nobody", "know", "helper", "hurting", "emergency!", "Emergency room", "mayday\u{00A0}", "ΟΔΟΣ no",
    "こんにちは no", "no한국", "한국no", "noĳ", "nó", "cafe\u{301} yes", "\u{2139}\u{200D}\u{00A9}no",
    "\u{00A9}\u{200D}\u{2139}no", "\u{24C2}\u{200D}\u{00A9} yes", "\u{1F1FA}\u{1F1F8}yes", "\u{1100}\u{1161}no",
    "\u{600}\u{1100}\u{1161}no", "\u{0915}\u{094D}\u{0937}no", "\u{600}\u{0915}\u{094D}\u{0937}no",
    "no\u{0903}", "no\u{0E33}", "yes\u{E0020}", "ye\u{E0100}s", "\u{D4E}yes", "\u{D4E}\nyes", "no\u{D4E}\nyes",
    "go ahead", "go  ahead", "goahead", "do it", "doit", "affirmative", "hurt", "i am hurt", "trapped", "stuck",
    "get help", "i need help", "need help", "please", "we're ok", "were ok", "it's fine", "its fine",
    "i'm good", "im good", "i am good", "all good", "cancel", "dismiss", "stand down", "no thanks",
    "INJURED", "Bleeding", "hElP", "ﬁne", "\u{FB01}ne", "K\u{212A}", "yes\u{0345}", "no\u{0345}",
]
let tokenPool = CrashLogic.assistWords + CrashLogic.okWords + ["the", "uh", "um", "I", "car", "know", "yesterday",
    "No", "YES", "Help", "don't", "ok", "fine", "\u{301}", "\u{2019}", "911", "nine", "one", "é", "ß", "Σ"]
let sepPool = [" ", "  ", ", ", ". ", "!", "?", "-", "'", "\n", "\u{00A0}", "", "\u{200D}", "\u{301}", "\t", "_", "\u{2019}"]
for _ in 0..<320 {
    var s = ""
    for k in 0..<(1 + rng.below(5)) {
        if k > 0 { s += rng.pick(sepPool) }
        var t = rng.pick(tokenPool)
        if rng.chance(6) { t = t.uppercased() }
        s += t
    }
    replies.append(s)
}
for r in replies {
    emit("reply", hs(r), CrashLogic.interpretReply(r).map(bit) ?? "-")
}

let hosPool: [Double] = G + around(28800) + around(39600) + around(27000) + [0, 3600, 10800, 27060, 27001, 1e6]
for d in hosPool + (0..<150).map({ _ in rng.unit() * 45000 }) {
    let st = HOSRules.status(drivingSeconds: d)
    switch st {
    case .ok: emit("hos", hx(d), "0", "-")
    case .breakSoon(let s): emit("hos", hx(d), "1", hx(s))
    case .breakDue: emit("hos", hx(d), "2", "-")
    case .limitReached: emit("hos", hx(d), "3", "-")
    }
}

// ---------------------------------------------------------------- vehicle profile math
let avgPool: [Double] = [.nan, -.infinity, .infinity, -0.0, 0, 40, 50, 75, 120, 1e308] + around(55) + around(65)
let idlePool: [Double] = [.nan, -.infinity, .infinity, -0.0, 0, 0.2, 0.8, 1, -1, 1.5] + around(1)
for a in avgPool { for i in idlePool {
    emit("eff", hx(a), hx(i), hx(VehicleProfile.efficiencyFactor(averageSpeedMph: a, idleFraction: i)))
} }
for _ in 0..<150 {
    let a = rng.unit() * 100, i = rng.unit()
    emit("eff", hx(a), hx(i), hx(VehicleProfile.efficiencyFactor(averageSpeedMph: a, idleFraction: i)))
}

var profiles: [VehicleProfile] = VehicleSpecs.all.map(\.profile)
let tableProfileCount = profiles.count
func synth(_ t: Double, _ r: Double, _ c: Double?, _ h: Double?) -> VehicleProfile {
    VehicleProfile(make: "Custom", model: "v", fuelType: .gas, tankCapacityUnits: t, ratedMilesPerUnit: r,
                   cityMilesPerUnit: c, highwayMilesPerUnit: h)
}
profiles += [
    synth(25, 20, nil, nil), synth(15.8, 32, 28, 39), synth(20, 25, nil, nil), synth(15, 30, 28, nil),
    synth(15, 30, nil, 39), synth(.nan, 20, nil, nil), synth(20, .infinity, nil, nil), synth(0, 20, nil, nil),
    synth(-0.0, 20, 18, 22), synth(10, 20, -5, 30), synth(10, 20, .nan, 30), synth(10, 20, 20, .infinity),
    synth(10, 20, .infinity, 30), synth(.infinity, 0, 0, 0), synth(-10, 20, 18, 22), synth(10, -20, nil, nil),
    synth(10, 20, 30, 20), synth(.greatestFiniteMagnitude, 2, nil, nil), synth(1e-300, 1e-10, 1e-300, 1e-300),
    synth(10, .nan, nil, .nan),
]
let mphPool: [Double] = [.nan, -.infinity, .infinity, -0.0, 0, 42.5, 60, 75, 120, 1e308, 98.33333333333333, -10]
    + around(30) + around(55) + around(65)
let rangeHabits: [(Double, Double)] = [(50, 0), (75, 0), (50, 0.2), (120, 0.8), (.nan, 0), (55, .nan),
    (.infinity, 0), (-.infinity, 1), ((55.0).nextUp, -0.0), (40, 1.5), (65, 0.5), (0, -1), (20, 0.3), (30, 1)]
let msfPool: [Double] = [0, 250, .nan, -0.0, .infinity, 1e3, -40, 130]
for (pi, p) in profiles.enumerated() {
    emit("vprof", String(pi), hx(p.tankCapacityUnits), hx(p.ratedMilesPerUnit), opt(p.cityMilesPerUnit), opt(p.highwayMilesPerUnit))
    emit("rrange", String(pi), hx(p.ratedRangeMiles))
    let table = pi < tableProfileCount
    let mphs = table ? [20, 30, 42.5, 60, 75, 110] : mphPool
    for m in mphs { emit("mpu", String(pi), hx(m), hx(p.milesPerUnit(atSpeedMph: m))) }
    let habits = table ? [rangeHabits[0], rangeHabits[1], rangeHabits[11]] : rangeHabits
    for (a, i) in habits {
        emit("erange", String(pi), hx(a), hx(i), hx(p.effectiveRangeMiles(averageSpeedMph: a, idleFraction: i)))
    }
    let msfs = table ? [0.0, 250] : msfPool
    for (k, msf) in msfs.enumerated() {
        let (a, i) = habits[k % habits.count]
        emit("frac", String(pi), hx(msf), hx(a), hx(i), hx(p.fuelFractionAfter(milesSinceFill: msf, averageSpeedMph: a, idleFraction: i)))
        emit("xrange", String(pi), hx(msf), hx(a), hx(i), hx(p.expectedRangeMiles(milesSinceFill: msf, averageSpeedMph: a, idleFraction: i)))
    }
}
let rfRange: [Double] = [60, 65, (65.0).nextDown, 130, .nan, .infinity, -.infinity, 0]
let rfNext: [Double] = [25, (25.0).nextUp, .nan, .infinity, 0, -0.0]
let rfReserve: [Double] = [40, 0, .nan, .infinity, -40]
for r in rfRange { for n in rfNext {
    emit("recfuel", hx(r), hx(n), "-", bit(VehicleProfile.shouldRecommendFuel(rangeRemainingMiles: r, milesToNextStation: n)))
    for res in rfReserve {
        emit("recfuel", hx(r), hx(n), hx(res), bit(VehicleProfile.shouldRecommendFuel(rangeRemainingMiles: r, milesToNextStation: n, reserveMiles: res)))
    }
} }

// ---------------------------------------------------------------- vehicle store (habits, odometer, range)
let restoreAvg: [Double] = [55, 30, .nan, 0, -0.0, -5, .infinity, 0.001, 80]
let restoreIdle: [Double] = [0, 0.3, 1, 1.5, -0.2, .nan, .infinity, -0.0]
MainActor.assumeIsolated {
    for a in restoreAvg { for i in restoreIdle {
        let s = VehicleStore(defaults: MemDefaults())
        s.restoreDriving(averageSpeedMph: a, idleFraction: i)
        emit("restore", hx(a), hx(i), hx(s.averageSpeedMph), hx(s.idleFraction))
    } }
    let speedPool: [Double] = [.nan, -1, 0, 0.44704, 0.447, 0.4471, .infinity, -0.0, 33.5]
    let deltaPool: [Double] = [.nan, -3, .infinity, 0, -0.0, 500, 100]
    let telePool: [Double?] = [nil, nil, nil, 0.5, .nan, -0.2, 1.3, 0, 1]
    for seq in 0..<30 {
        let store = VehicleStore(defaults: MemDefaults())
        let pi: Int? = rng.chance(5) ? nil : rng.below(profiles.count)
        store.profile = pi.map { profiles[$0] }
        let ra = rng.pick(restoreAvg), ri = rng.pick(restoreIdle)
        store.restoreDriving(averageSpeedMph: ra, idleFraction: ri)
        emit("fseq", String(seq), pi.map { String($0) } ?? "-", hx(store.averageSpeedMph), hx(store.idleFraction))
        for _ in 0..<12 {
            let speed = rng.chance(4) ? rng.pick(speedPool) : rng.unit() * 40
            let delta = rng.chance(5) ? rng.pick(deltaPool) : rng.unit() * 500
            let towing = rng.chance(3)
            let tele: Double? = rng.chance(2) ? rng.pick(telePool) : nil
            store.towingActive = towing
            store.telemetry = { (tele, nil) }
            store.recordFix(speedMps: speed, deltaMeters: delta)
            emit("fix", String(seq), hx(speed), hx(delta), bit(towing), opt(tele),
                 hx(store.milesSinceFill), hx(store.averageSpeedMph), hx(store.idleFraction),
                 opt(store.expectedRangeMiles), opt(store.predictedFuelFraction))
        }
    }
    emit("towingEconomyFactor", hx(TowingLimits.towingEconomyFactor))
}

// ---------------------------------------------------------------- EPA class specs
let vclasses = [
    "Two Seaters", "Minicompact Cars", "Subcompact Cars", "Compact Cars", "Midsize Cars", "Large Cars",
    "Small Station Wagons", "Midsize Station Wagons", "Large Station Wagons", "Midsize-Large Station Wagons",
    "Small Pickup Trucks 2WD", "Small Pickup Trucks 4WD", "Standard Pickup Trucks 2WD", "Standard Pickup Trucks 4WD",
    "Standard Pickup Trucks/2wd", "Small Pickup Trucks", "Standard Pickup Trucks", "Vans, Cargo Type",
    "Vans, Passenger Type", "Vans", "Vans Passenger", "Minivan - 2WD", "Minivan - 4WD",
    "Special Purpose Vehicle 2WD", "Special Purpose Vehicles", "Special Purpose Vehicles/2wd",
    "Sport Utility Vehicle - 2WD", "Sport Utility Vehicle - 4WD", "Small Sport Utility Vehicle 2WD",
    "Standard Sport Utility Vehicle 4WD", "", "SUV", "suv", "PICKUP", "Pick-up", "Pickup\u{301}", "Van\u{301}",
    "Vans\u{301}", "\u{600}van", "van\u{200D}", "VAN\u{0}", "Mini\u{301}van", "mini van", "MINIVAN", "Wagon",
    "wagon\u{1F3FD}", "Compact\u{0903}", "Largé", "Large\u{301}", "LARGE", "Sport\u{00A0}Utility", "sport  utility",
    "Two\u{00A0}Seater", "two seater", "TWO SEATERS", "Subcompact", "passenger van", "Passenger\u{301} Van",
    "İ van", "\u{212A}", "Mini", "mini\u{0}", "Midsize", "Truck", "Cargo Van", "\u{0915}\u{094D}van", "\u{D4E}van",
    "x\u{200D}van", "\u{2139}\u{200D}van", "vanpassenger", "suvs", "SUV\u{E0020}", "compact\u{E0100}",
]
for v in vclasses {
    let p = EPAClassSpecs.physical(forVClass: v)
    emit("phys", hs(v), hx(p.tank), hx(p.height), opt(p.gvwr), opt(p.towCap))
}
let tankPool: [Double] = [.nan, .infinity, -.infinity, 0, -0.0, 25, 14.5, 12.5, 1e308]
let cmpuPool: [Double] = [.nan, .infinity, -.infinity, 0, -0.0, 26, (26.0).nextUp, (26.0).nextDown, 30, 100, 1e-300, .leastNonzeroMagnitude]
for t in tankPool { for m in cmpuPool {
    emit("vtank", hx(t), hx(m), hx(EPAClassSpecs.validatedTank(t, combinedMPU: m)))
} }
for _ in 0..<150 {
    let t = rng.unit() * 40, m = rng.unit() * 120 + 1
    emit("vtank", hx(t), hx(m), hx(EPAClassSpecs.validatedTank(t, combinedMPU: m)))
}
let epaFuels = ["Regular Gasoline", "Premium Gasoline", "Midgrade Gasoline", "Diesel", "Electricity", "Natural Gas",
    "Hydrogen", "Premium and Electricity", "Regular Gas and Electricity", "Premium Gas or Electricity",
    "Gasoline or E85", "DIESEL", "electricity\u{301}", "Electricity\u{200D}", "diesel\u{0}", "", "Dieseł",
    "Biodiesel", "ELECTRICITY", "\u{600}diesel", "diesel\u{0903}", "electric", "Electr\u{0130}city", "D\u{0130}ESEL",
    "Diesel\u{301}", "diesel-electricity", "\u{212A}diesel"]
for f in epaFuels { emit("epafuel", hs(f), String(fuelCode(EPAClassSpecs.fuelType(forEPA: f)))) }

// ---------------------------------------------------------------- the Unicode behaviour the text rules rest on
// Swept over every scalar, so the Rust tables are checked against this Swift
// runtime rather than assumed.
func ranges(_ pred: (Unicode.Scalar) -> Bool) -> [String] {
    var out: [String] = []
    var start: UInt32? = nil
    var prev: UInt32 = 0
    for v in UInt32(0)...0x10FFFF {
        guard let sc = Unicode.Scalar(v) else {
            if let s = start { out.append(hu(UInt64(s)) + "-" + hu(UInt64(prev))); start = nil }
            continue
        }
        if pred(sc) {
            if start == nil { start = v }
        } else if let s = start {
            out.append(hu(UInt64(s)) + "-" + hu(UInt64(prev))); start = nil
        }
        prev = v
    }
    if let s = start { out.append(hu(UInt64(s)) + "-" + hu(UInt64(prev))) }
    return out
}
func glue(_ a: String, _ b: Unicode.Scalar) -> String { var s = a; s.unicodeScalars.append(b); return s }
emit("ualpha", lst(ranges { Character($0).isLetter }))
emit("uattach", lst(ranges { glue("a", $0).count == 1 }))
emit("uprepend", lst(ranges { var s = ""; s.unicodeScalars.append($0); s.unicodeScalars.append("a"); return s.count == 1 }))
emit("ucontrol", lst(ranges { glue("\u{600}", $0).count == 2 }))
var lowers: [String] = []
for v in UInt32(0)...0x10FFFF {
    guard let sc = Unicode.Scalar(v) else { continue }
    let s = String(Character(sc))
    let l = Array(s.lowercased().unicodeScalars)
    if l != [sc] { lowers.append(hu(UInt64(v)) + ">" + l.map { hu(UInt64($0.value)) }.joined(separator: "+")) }
}
emit("ulower", lst(lowers))

FileHandle.standardOutput.write(out.data(using: .utf8)!)
