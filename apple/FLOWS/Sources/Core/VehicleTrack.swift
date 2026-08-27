// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// How to DRAW the vehicle between GPS fixes.
///
/// Fixes land about once a second, so a marker pinned straight to them
/// hops — an accurate position teleporting 20 m every tick, which reads as
/// a stutter even though the data is fine. The marker instead SLIDES from
/// the last fix to the new one over roughly the gap between them.
///
/// Sliding between two known points, rather than dead-reckoning past the
/// newest one, is the deliberate choice. Running ahead of the data draws a
/// car sailing through an intersection it is actually stopping at — the
/// "next ping includes turns which could cause a full stop" case. The
/// marker trails by about one fix instead, and never invents a metre of
/// travel that didn't happen.
///
/// Pure math, pinned by FLOWSTests.
enum VehicleTrack {
    /// Below this the vehicle is stopped: GPS course is noise at a
    /// standstill, and a parked car must not drift or spin.
    static let stoppedMps: Double = 0.6
    /// A jump further than this is the GPS correcting itself — usually on
    /// leaving a tunnel or a street canyon. Sliding across it would draw the
    /// vehicle driving through buildings, so the marker snaps instead.
    static let teleportMeters: Double = 120
    /// Slide time is the real gap between fixes, held inside sane bounds: a
    /// burst of fixes shouldn't animate in 10 ms, and a long gap shouldn't
    /// leave the marker crawling for half a minute.
    static let minSlide: TimeInterval = 0.25
    static let maxSlide: TimeInterval = 2.5

    /// Should the marker SLIDE to this fix, or jump straight to it?
    static func shouldAnimate(from: CLLocationCoordinate2D,
                              to: CLLocationCoordinate2D) -> Bool {
        POIRanking.meters(from, to) <= teleportMeters
    }

    /// How long the slide should take, from the gap between the two fixes.
    static func slideSeconds(gap: TimeInterval) -> TimeInterval {
        min(max(gap, minSlide), maxSlide)
    }

    /// The direction to point the marker: the reported course while moving,
    /// the last known one while stopped. Never a guess.
    static func heading(courseDegrees: Double, speedMps: Double,
                        previous: Double?) -> Double? {
        guard speedMps > stoppedMps, courseDegrees >= 0 else { return previous }
        return courseDegrees
    }

    /// Ease a heading toward a new one the short way round, so a marker
    /// crossing north turns 10° rather than spinning 350°.
    static func easedHeading(from current: Double, to target: Double,
                             fraction: Double) -> Double {
        var delta = (target - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        let next = current + delta * min(max(fraction, 0), 1)
        return (next.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
    }
}

/// Which way the vehicle art faces, given where the camera is looking from.
///
/// The marker is not a 3D model — it is a set of flat drawings, one per
/// viewing angle, swapped as the camera pitches and turns. Flat on the map
/// you are looking straight down, so the top view is right; pitched forward
/// behind the car you see its back; a camera swung round to face the car
/// shows its front.
enum VehicleAspect: String, CaseIterable {
    case top, rear, front, side

    /// Pick the aspect from the camera's pitch and how far its heading
    /// differs from the vehicle's.
    ///
    /// `relativeBearing` is the camera heading minus the vehicle heading.
    static func forCamera(pitchDegrees: Double,
                          relativeBearing: Double) -> VehicleAspect {
        // Looking nearly straight down: the roof, whatever the bearing.
        if pitchDegrees < 25 { return .top }
        var delta = relativeBearing.truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        let a = abs(delta)
        if a <= 45 { return .rear }      // camera behind, following
        if a >= 135 { return .front }    // camera ahead, facing the car
        return .side
    }
}

/// What the vehicle marker looks like: a body shape and a colour.
///
/// The shape defaults to whatever the driver's own vehicle is — an 18
/// wheeler should not be drawn as a hatchback — and either can be changed
/// in Settings. Both are plain enums so the choice persists as a word
/// rather than an index that shifts when the list grows.
enum VehicleShape: String, CaseIterable, Identifiable, Codable {
    case car, suv, pickup, van, box, semi, motorcycle, bus

    var id: String { rawValue }

    /// Plain words, fifth-grade vocabulary.
    var title: String {
        switch self {
        case .car: return "Car"
        case .suv: return "SUV"
        case .pickup: return "Pickup"
        case .van: return "Van"
        case .box: return "Box truck"
        case .semi: return "18 wheeler"
        case .motorcycle: return "Motorcycle"
        case .bus: return "Bus"
        }
    }

    /// The drawing for one viewing angle.
    ///
    /// Flat SF Symbols swapped as the camera moves — looking down you see
    /// the roof, following behind you see the back. That is what makes a 2D
    /// marker read as having a direction without being a 3D model.
    ///
    /// Every name here was checked against the installed symbol set: SF
    /// ships no van at any angle, so a van borrows the box truck's shape,
    /// and only the car family has a full set of four views. Naming a symbol
    /// that doesn't exist draws an empty box on the map.
    func symbol(_ aspect: VehicleAspect) -> String {
        switch self {
        case .motorcycle: return "motorcycle.fill"
        case .bus: return "bus.fill"
        case .semi, .box, .van: return "truck.box.fill"
        case .pickup: return "truck.pickup.side.fill"
        case .suv:
            switch aspect {
            case .top: return "car.top.door.front.left.open.fill"
            case .rear: return "car.rear.fill"
            case .front: return "car.front.waves.up.fill"
            case .side: return "suv.side.fill"
            }
        case .car:
            switch aspect {
            case .top: return "car.top.door.front.left.open.fill"
            case .rear: return "car.rear.fill"
            case .front: return "car.front.waves.up.fill"
            case .side: return "car.side.fill"
            }
        }
    }

    /// The shape that matches the vehicle on file, so a driver who already
    /// entered their truck doesn't have to pick a truck here too.
    ///
    /// Weight decides first, because it is a fact rather than a guess: past
    /// 26,000 lb GVWR you are in a rig that needs a CDL, and past 10,000 lb
    /// you are in something box-shaped. Below that the model name is the
    /// only signal there is, so the common US body names are matched
    /// directly and anything unrecognized stays a car.
    static func matching(make: String?, model: String?,
                         gvwrLbs: Double?, isTrucker: Bool) -> VehicleShape {
        if let gvwr = gvwrLbs {
            if gvwr >= 26_000 { return .semi }
            if gvwr >= 10_000 { return .box }
        }
        let name = "\(make ?? "") \(model ?? "")".lowercased()
        func has(_ words: [String]) -> Bool { words.contains { name.contains($0) } }
        if has(["motorcycle", "harley", "ducati", "kawasaki ninja"]) { return .motorcycle }
        if has(["bus", "coach"]) { return .bus }
        if has(["silverado", "f-150", "f150", "f-250", "f-350", "ram 1500",
                "sierra", "tacoma", "tundra", "colorado", "ranger",
                "ridgeline", "frontier", "titan", "canyon"]) { return .pickup }
        if has(["odyssey", "sienna", "pacifica", "transit", "sprinter",
                "promaster", "carnival", "metris", "express van"]) { return .van }
        if has(["explorer", "tahoe", "suburban", "highlander", "rav4",
                "cr-v", "crv", "pilot", "4runner", "wrangler", "bronco",
                "escape", "equinox", "rogue", "outback", "telluride",
                "palisade", "expedition", "durango", "grand cherokee",
                "model y", "model x"]) { return .suv }
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return .car }
        return isTrucker ? .semi : .car
    }
}
