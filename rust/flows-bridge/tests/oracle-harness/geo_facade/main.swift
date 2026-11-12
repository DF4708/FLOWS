import CoreLocation
import Foundation

// Facade parity for the geo facade: reads the frozen geo oracle
// (`swift_geo_oracle.tsv`), feeds the inputs of its `m`, `brg` and `ahead`
// records to the app's facades (`POIRanking.meters`,
// `EnforcementCameras.bearingDegrees`, `FuelWarning.bearingDegrees`,
// `EnforcementCameras.isAhead`), and writes each record again with the
// facades' answers in the same format. The other kinds are left out.
//
// It also counts the records whose answer is not the frozen one, prints the
// counts and fails on any difference the Rust oracle (`swift_geo_oracle.rs`)
// does not allow, by the same measures: `meters` must match every record; a
// bearing may move its target by at most a micrometre on the ground (error
// in radians times the separation); an ahead answer may flip only where the
// bearing lies within a nanodegree of the cone's edge. The original Swift,
// built for Release, fuses its sine and cosine.

func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func dx(_ s: Substring) -> Double { Double(bitPattern: UInt64(s, radix: 16)!) }
func C(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

@main
enum GeoFacadeParity {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            print("usage: oracle <swift_geo_oracle.tsv> <out.tsv>")
            exit(2)
        }
        let fixture = try String(contentsOfFile: args[1], encoding: .utf8)
        var out = ""
        var records = [String: Int]()
        var differ = [String: Int]()
        var largestLateral = 0.0, largestEdge = 0.0
        var outside = 0
        for line in fixture.split(separator: "\n", omittingEmptySubsequences: false) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let kind = f.first, ["m", "brg", "ahead"].contains(kind) else { continue }
            let a = C(dx(f[1]), dx(f[2]))
            let b = C(dx(f[3]), dx(f[4]))
            var answer: [String]
            switch kind {
            case "m":
                answer = [hx(POIRanking.meters(a, b))]
            case "brg":
                answer = [
                    hx(EnforcementCameras.bearingDegrees(from: a, to: b)),
                    hx(FuelWarning.bearingDegrees(from: a, to: b)),
                ]
                for (got, want) in zip(answer, f[5...6]) {
                    let g = dx(Substring(got)), w = dx(want)
                    guard g.bitPattern != w.bitPattern else { continue }
                    let lateral = abs(g - w) * .pi / 180 * POIRanking.meters(a, b)
                    largestLateral = max(largestLateral, lateral)
                    if !(lateral <= 1e-6) { outside += 1 }
                }
            default:
                let heading: Double? = f[5] == "-" ? nil : dx(f[5])
                answer = [EnforcementCameras.isAhead(a, from: b, headingDegrees: heading) ? "1" : "0"]
                if answer[0] != f[6] {
                    // How far the bearing from the vehicle to the camera lies from the cone's edge.
                    let bearing = EnforcementCameras.bearingDegrees(from: b, to: a)
                    var delta = (bearing - (heading ?? .nan)).truncatingRemainder(dividingBy: 360)
                    if delta > 180 { delta -= 360 }
                    if delta < -180 { delta += 360 }
                    let edge = abs(abs(delta) - 100)
                    largestEdge = max(largestEdge, edge)
                    if !(edge <= 1e-9) { outside += 1 }
                }
            }
            let fields = kind == "ahead" ? Array(f[0...5]) : Array(f[0...4])
            let record = (fields.map(String.init) + answer).joined(separator: "\t")
            out += record + "\n"
            records[String(kind), default: 0] += 1
            if record != String(line) {
                differ[String(kind), default: 0] += 1
                if kind == "m" { outside += 1 }
            }
        }
        try out.write(toFile: args[2], atomically: true, encoding: .utf8)
        for kind in ["m", "brg", "ahead"] {
            print("\(kind)\t\(records[kind, default: 0]) records\t\(differ[kind, default: 0]) differ")
        }
        print("largest bearing gap on the ground\t\(largestLateral) m")
        print("largest distance from the cone's edge where ahead flips\t\(largestEdge) degrees")
        print("outside what the Rust oracle allows\t\(outside)")
        if outside > 0 { exit(1) }
    }
}
