import CoreLocation
import Foundation

// Frozen oracle: every output below comes from the ORIGINAL Swift `RiskAdvice` (RiskAdvice.swift), compiled
// with the test target's own Core sources at the base commit. Text is its UTF-8 in hex ("-" for nil, "" for empty),
// doubles are IEEE-754 bit patterns in hex, booleans 0/1.
//
// Kinds:
//   a   kindName, band (0 clear, 1 green, 2 yellow, 3 red), actions (each line in hex, joined by ",")
//   g   lat, lon, isNorthOfTheBorder, isCanadaBelowTheBands, isAcrossTheBorder, mayBeAcrossTheBorder,
//       officialURL's absoluteString as it is (ASCII; "-" for nil), usSouthernBorderLat(longitude: lon)

func th(_ s: String) -> String { s.utf8.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined() }
func ot(_ s: String?) -> String { s.map(th) ?? "-" }
func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func b01(_ b: Bool) -> String { b ? "1" : "0" }

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
}

let BANDS: [RiskBand] = [.clear, .green, .yellow, .red]

let NAMES = [
    "cold", "heat", "flood", "wind", "snow", "ice", "storm", "tornado", "fire", "dust storm", "air/smoke",
    "radiation/uv", "seismic", "tropical", "volcanic", "avalanche", "tsunami",
]
// Names that are near a case name, or the same name another way.
let NEAR = [
    "", " ", "unknown", "Fog", "Rain", "Hail", "Smoke", "Air", "UV", "Dust", "Storms", "Snow/Ice", "snow ice",
    " cold", "cold ", "co ld", "cold\u{301}", "c\u{301}old", "\u{301}cold", "cold\u{200D}", "cold\u{0}", "\u{FEFF}cold",
    "COLD", "Cold", "cOLD", "\u{FF23}old", "Dust Storm", "dust  storm", "dust\tstorm", "dust\u{A0}storm",
    "duststorm", "dust-storm", "AIR/SMOKE", "Air/Smoke", "air / smoke", "air/smo\u{212A}e", "AIR/SMO\u{212A}E",
    "air\u{2044}smoke", "air\u{FF0F}smoke", "Radiation/UV", "RADIATION/UV", "radiation/uv\u{301}", "\u{130}ce",
    "\u{131}ce", "ICE", "Ice", "\u{FB01}re", "FIRE", "F\u{130}RE", "f\u{131}re", "Seismic", "SEISMIC", "Tsunami",
    "TSUNAMI", "Volcanic", "Tropical", "Avalanche", "AVALANCHE", "Tornado", "TORNADO", "Heat", "HEAT", "Flood",
    "Wind", "WIND", "Storm", "STORM", "Thunderstorm", "Snow", "SNOW", "\u{1F525}", "fire\u{1F525}", "storm\r\n",
    "storm\n", "ℌeat", "\u{2163}", "ſnow", "\u{17F}eismic", "Ωind", "w\u{130}nd", "tsu\u{301}nami", "cold\u{E0001}",
    "\u{E0001}cold", "cold\u{FE0F}", "heat\u{20E3}", "Clear", "Green", "Yellow", "Red", "none", "-", "?",
]

@main @MainActor
struct Oracle {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 2 else { print("usage: oracle out.tsv"); exit(2) }
        var out = "# frozen Swift RiskAdvice oracle at commit \(ProcessInfo.processInfo.environment["BASE"] ?? "?")\n"
        func emit(_ f: [String]) { out += f.joined(separator: "\t") + "\n" }
        var rng = SM(s: 0x5249_534B_4144_5649)

        // a: the advice lines.
        func act(_ name: String) {
            for (i, b) in BANDS.enumerated() {
                emit(["a", th(name), String(i), RiskAdvice.actions(kindName: name, band: b).map(th).joined(separator: ",")])
            }
        }
        for n in NAMES { act(n) }
        for n in NEAR { act(n) }
        for _ in 0..<300 {
            var n = String(rng.pick(NAMES).map { c in rng.chance(2) ? Character(c.uppercased()) : c })
            if rng.chance(5) { n = rng.pick(["", " ", "\u{301}", "\u{FEFF}"]) + n }
            if rng.chance(5) { n += rng.pick(["", " ", "\u{301}", "s", "\u{200D}"]) }
            act(n)
        }

        // g: the border lines.
        func feed(_ lat: Double, _ lon: Double) {
            emit([
                "g", hx(lat), hx(lon),
                b01(RiskAdvice.isNorthOfTheBorder(latitude: lat, longitude: lon)),
                b01(RiskAdvice.isCanadaBelowTheBands(latitude: lat, longitude: lon)),
                b01(RiskAdvice.isAcrossTheBorder(latitude: lat, longitude: lon)),
                b01(RiskAdvice.mayBeAcrossTheBorder(latitude: lat, longitude: lon)),
                RiskAdvice.officialURL(latitude: lat, longitude: lon)?.absoluteString ?? "-",
                hx(RiskAdvice.usSouthernBorderLat(longitude: lon)),
            ])
        }
        func feed3(_ lat: Double, _ lon: Double) {
            feed(lat, lon); feed(lat.nextUp, lon); feed(lat.nextDown, lon)
            feed(lat, lon.nextUp); feed(lat, lon.nextDown)
        }
        // Every band edge and box edge, against every threshold latitude, each a hair either side, and a
        // quarter degree either side (the margin `mayBeAcrossTheBorder` reads by).
        let lons: [Double] = [
            -170, -141, -139.1, -135, -130.6, -130.5, -130.2, -130, -129.9, -126.5, -125.6, -125.5, -124.75, -124,
            -123.55, -123.32, -123.27, -123.1, -123.0, -122.7, -120, -117.2, -116, -114.82, -113, -111.075, -110,
            -108.2, -107, -106.5, -98.0, -97.4, -95.15, -95.0, -94.6, -93.4, -92.0, -89.6, -86.5, -85.0, -84.95,
            -83.6, -83.5, -83.2, -82.0, -79.06, -78.95, -78.9, -78.0, -77, -76.35, -75.5, -74.75, -73, -71.5, -70,
            -67.78, -66.9, -60, -52, -50,
        ]
        let lats: [Double] = [
            14, 20, 25.5, 25.84, 29.5, 31.33, 31.74, 32.484, 32.528, 32.711, 41.6, 41.9, 42.5, 43.0, 43.4, 43.75,
            44.12, 44.6, 44.8, 45.0, 45.03, 45.5, 47.8, 47.9, 48.0, 48.2, 48.25, 48.3, 48.6, 48.8, 49.0, 49.39, 51,
            54.66, 56, 58, 60.3, 65,
        ]
        for lo in lons {
            for la in lats {
                feed3(la, lo)
                for m in [0.25, -0.25] { feed(la + m, lo); feed((la + m).nextUp, lo); feed((la + m).nextDown, lo) }
            }
        }
        // The sloped lines: the US-Mexico border (the original's own threshold), the Rainy River and the St.
        // Lawrence, in small steps, each on the line, a hair either side, a tenth either side, and a quarter
        // degree either side.
        func line(_ l: Double, _ lo: Double) {
            for d in [0.0, 0.1, -0.1, 0.25, -0.25] {
                let v = l + d
                feed(v, lo); feed(v.nextUp, lo); feed(v.nextDown, lo)
            }
        }
        for lo in stride(from: -117.3, through: -97.3, by: 0.05) { line(RiskAdvice.usSouthernBorderLat(longitude: lo), lo) }
        let knots: [(lon: Double, lat: Double)] = [(-95.15, 49.0), (-94.6, 48.8), (-93.4, 48.6), (-92.0, 48.3), (-89.6, 48.0)]
        for lo in stride(from: -95.2, through: -89.55, by: 0.05) {
            if let i = knots.indices.dropLast().first(where: { lo <= knots[$0 + 1].lon }) {
                let a = knots[i], b = knots[i + 1]
                let t = (lo - a.lon) / (b.lon - a.lon)
                line(a.lat + t * (b.lat - a.lat) + 0.02, lo)
            }
        }
        for k in knots { feed3(k.lat, k.lon); feed3(k.lat + 0.02, k.lon) }
        for lo in stride(from: -76.4, through: -74.7, by: 0.025) { line(44.12 + (lo + 76.35) / 1.6 * 0.88, lo) }

        // The four outlines: every vertex, every edge's middle, and random points in each one's box.
        let maine: [(Double, Double)] = [
            (44.6, -71.5), (45.01, -71.5), (45.30, -71.08), (45.40, -70.80), (45.77, -70.39),
            (46.40, -70.05), (47.10, -70.0), (47.46, -69.23), (47.36, -68.33),
            (47.35, -68.14), (47.20, -67.92), (47.07, -67.78),
            (45.93, -67.78), (45.57, -67.43), (45.18, -67.28), (44.6, -66.9),
        ]
        let panhandle: [(Double, Double)] = [
            (54.66, -141.0), (54.66, -130.6), (55.0, -130.2), (55.85, -130.0), (55.95, -130.0),
            (56.1, -130.1), (56.7, -131.9), (58.0, -133.1), (58.9, -133.8), (59.7, -135.0),
            (59.8, -135.5), (59.45, -136.4), (58.9, -137.5), (59.7, -138.6), (60.3, -139.1),
            (60.3, -141.0),
        ]
        let ontario: [(Double, Double)] = [
            (47.85, -84.95), (46.90, -84.95), (46.60, -84.78), (46.505, -84.62), (46.49, -84.45),
            (46.508, -84.36), (46.505, -84.30), (46.515, -84.27), (46.54, -84.20), (46.52, -84.12),
            (46.45, -84.09), (46.28, -84.11), (46.09, -83.98), (46.11, -83.60), (45.95, -83.45),
            (45.33, -82.52), (43.60, -82.12), (43.0, -82.42), (42.97, -82.416), (42.82, -82.478),
            (42.715, -82.485), (42.62, -82.52), (42.53, -82.62), (42.36, -82.925), (42.331, -82.975),
            (42.3237, -83.0417), (42.312, -83.074), (42.285, -83.10), (42.20, -83.13), (42.05, -83.13),
            (41.83, -83.07), (41.75, -82.78), (41.676, -82.68), (41.85, -82.0), (42.2, -81.25),
            (42.36, -80.0), (42.6, -79.5), (42.83, -78.95), (42.906, -78.906), (42.94, -78.925),
            (42.965, -78.975), (43.0, -79.012), (43.045, -79.005), (43.065, -78.995), (43.074, -79.02),
            (43.076, -79.06), (43.0773, -79.0745), (43.0902, -79.0677), (43.12, -79.062),
            (43.165, -79.045), (43.26, -79.06), (43.45, -79.06), (45.6, -82.0), (47.85, -83.5),
        ]
        let vancouver: [(Double, Double)] = [
            (49.0, -123.32), (48.83, -123.0), (48.77, -123.01), (48.69, -123.27), (48.55, -123.22),
            (48.42, -123.115), (48.28, -123.25), (48.25, -123.55), (48.3, -124.0), (48.5, -124.75),
            (48.6, -125.6), (49.0, -126.5),
        ]
        for ring in [maine, panhandle, ontario, vancouver] {
            for (i, v) in ring.enumerated() {
                feed3(v.0, v.1)
                let w = ring[(i + 1) % ring.count]
                let mid = ((v.0 + w.0) / 2, (v.1 + w.1) / 2)
                feed(mid.0, mid.1)
                for d in [0.003, -0.003] { feed(mid.0 + d, mid.1); feed(mid.0, mid.1 + d) }
            }
            let la0 = ring.map(\.0).min()! - 0.3, la1 = ring.map(\.0).max()! + 0.3
            let lo0 = ring.map(\.1).min()! - 0.3, lo1 = ring.map(\.1).max()! + 0.3
            for _ in 0..<400 { feed(rng.range(la0, la1), rng.range(lo0, lo1)) }
        }

        // Odd numbers.
        for v in [Double.nan, .infinity, -.infinity, 0, -0.0, 1e300, -1e300, .ulpOfOne, .leastNonzeroMagnitude] {
            feed(v, -100); feed(45, v); feed(v, v); feed(30, v); feed(v, -80); feed(60, v); feed(v, -135)
        }

        // Real places by the borders, on both sides.
        let places: [(Double, Double)] = [
            (42.3149, -83.0364), (42.3314, -83.0458), (43.6532, -79.3832), (42.8864, -78.8784), (43.0896, -79.0849),
            (43.0962, -79.0377), (46.5219, -84.3461), (46.4953, -84.3453), (48.4284, -123.3656), (47.6062, -122.3321),
            (49.2827, -123.1207), (48.9936, -122.7471), (48.9850, -123.0700), (49.3500, -95.0700), (55.9120, -130.0200),
            (55.9383, -129.9875), (59.4583, -135.3139), (60.7212, -135.0568), (58.3019, -134.4197), (59.2358, -135.4450),
            (59.5778, -133.6890), (54.3150, -130.3208), (45.1845, -67.2770), (45.1914, -67.2794), (47.3550, -68.3270),
            (47.3730, -68.3250), (46.1259, -67.8403), (46.1500, -67.5800), (45.0080, -72.0970), (45.0730, -72.0010),
            (44.9281, -74.8919), (45.0213, -74.7303), (44.6942, -75.4863), (44.7120, -75.5130), (44.2312, -76.4860),
            (43.9748, -75.9108), (48.3809, -89.2477), (48.6011, -93.4107), (48.6100, -93.4000), (47.9630, -89.6850),
            (32.5149, -117.0382), (32.7157, -117.1611), (32.6245, -115.4523), (32.6789, -115.4989), (32.6927, -114.6277),
            (32.4867, -114.7822), (32.4900, -114.7700), (31.3404, -110.9343), (31.3086, -110.9422), (31.3445, -109.5453),
            (31.3270, -109.5490), (31.8273, -107.6400), (31.7700, -107.6300), (31.7619, -106.4850), (31.6904, -106.4245),
            (29.5600, -104.3720), (29.5640, -104.4150), (29.3709, -100.8959), (29.3240, -100.9320), (28.7091, -100.4995),
            (28.7000, -100.5230), (27.5306, -99.4803), (27.4762, -99.5164), (27.3500, -99.5000), (26.9073, -99.2714),
            (26.4062, -99.0187), (26.2034, -98.2300), (26.0920, -98.2770), (25.9017, -97.4975), (25.8690, -97.5027),
            (29.7604, -95.3698), (25.7617, -80.1918), (24.5551, -81.7800), (20.9674, -89.5926), (21.1619, -86.8515),
            (23.1136, -82.3666), (17.5046, -88.1962), (14.6349, -90.5069), (21.3069, -157.8583), (61.2181, -149.9003),
            (51.8800, -176.6581), (47.5615, -52.7126), (44.6488, -63.5752), (32.2949, -64.7814), (64.1814, -51.6941),
            (46.7811, -56.1764), (45.5017, -73.5673), (46.8139, -71.2080), (45.4215, -75.6972), (64.8378, -147.7164),
            (19.4326, -99.1332), (25.6866, -100.3161), (43.0731, -89.4012), (41.4993, -81.6944), (41.6528, -83.5379),
            (41.7700, -82.6800), (41.6600, -82.8200), (42.0500, -82.6000), (45.9500, -83.4000), (46.0000, -83.0000),
        ]
        for (la, lo) in places { feed(la, lo) }

        // Random points across North America, and denser where the lines are.
        for _ in 0..<2500 { feed(rng.range(10, 72), rng.range(-170, -50)) }
        for _ in 0..<1200 { feed(rng.range(41, 50), rng.range(-96, -66)) }
        for _ in 0..<800 { feed(rng.range(24, 34), rng.range(-118, -96)) }
        for _ in 0..<400 { feed(rng.range(47.5, 49.5), rng.range(-127, -122)) }

        FileManager.default.createFile(atPath: args[1], contents: Data(out.utf8))
    }
}
