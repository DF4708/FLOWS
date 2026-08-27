// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// Fixed automated speed and red-light enforcement on the road ahead.
///
/// WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT.
///
/// A parked officer with a radar gun is not in any dataset FLOWS can
/// lawfully use. Waze has that data but its feed is for public agencies who
/// sign terms promising never to republish it; Apple takes speed-check
/// reports in Maps and exposes no API to read them; Waymo publishes only
/// research datasets whose licence forbids production use. So mobile
/// enforcement is out, and no amount of wanting it changes that.
///
/// FIXED enforcement is a different thing entirely. Automated speed cameras
/// and red-light cameras are permanent, publicly announced installations —
/// most jurisdictions are required by law to sign them — and about 77,000 of
/// them are mapped in OpenStreetMap, the same source this app already uses
/// for posted limits and lane guidance. Those are the ones drawn on the map
/// and warned about here.
///
/// The warning exists to slow a driver down before the line, which is what
/// the cameras are for. Pure math, pinned by FLOWSTests.
enum EnforcementCameras {
    /// A camera on the road.
    struct Camera: Identifiable, Equatable, Hashable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        /// What it catches: speed, the light, or both.
        let kind: Kind
        /// The limit it enforces, when the mapper recorded one.
        let limitMph: Double?

        static func == (a: Camera, b: Camera) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    enum Kind: String, Equatable {
        case speed, redLight, both

        /// Plain words — a driver reads this at a glance, at speed.
        var title: String {
            switch self {
            case .speed: return "Speed camera"
            case .redLight: return "Red light camera"
            case .both: return "Speed and red light camera"
            }
        }

        var symbol: String {
            switch self {
            case .speed: return "camera.fill"
            case .redLight: return "light.beacon.max.fill"
            case .both: return "camera.badge.ellipsis"
            }
        }
    }

    /// How far ahead a camera is called out. About twenty seconds at highway
    /// speed — long enough to come off the accelerator and coast down, short
    /// enough that it's still clearly about THIS camera.
    static let warnMeters = 600.0
    /// Past this, the camera is behind you and the warning drops.
    static let clearMeters = 60.0

    /// Which OSM tags mean a camera, and which kind.
    ///
    /// `highway=speed_camera` is the common node. Red-light devices are
    /// tagged as an enforcement of `traffic_signals` or by
    /// `highway=traffic_signals` + `traffic_signals=camera`; a device
    /// enforcing both carries both markers.
    static func kind(fromTags tags: [String: String]) -> Kind? {
        let highway = tags["highway"] ?? ""
        let enforcement = tags["enforcement"] ?? ""
        let signals = tags["traffic_signals"] ?? ""
        let isSpeed = highway == "speed_camera"
            || enforcement.contains("maxspeed")
            || enforcement.contains("average_speed")
        let isLight = enforcement.contains("traffic_signals")
            || signals.contains("camera")
            || tags["red_light_camera"] == "yes"
        switch (isSpeed, isLight) {
        case (true, true): return .both
        case (true, false): return .speed
        case (false, true): return .redLight
        default: return nil
        }
    }

    /// The limit a camera enforces, from `maxspeed` on the device itself.
    /// Bare numbers in OSM are km/h; "45 mph" is already what it says.
    static func limitMph(fromTags tags: [String: String]) -> Double? {
        guard let raw = tags["maxspeed"]?.lowercased()
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.hasSuffix("mph") {
            return Double(raw.replacingOccurrences(of: "mph", with: "")
                .trimmingCharacters(in: .whitespaces))
        }
        guard let kph = Double(raw) else { return nil }
        return kph * 0.621371
    }

    /// The camera to warn about right now: the nearest one AHEAD, inside the
    /// warning distance and not already passed. nil when there's nothing to
    /// say — silence is the normal state of this feature.
    ///
    /// "Ahead" is decided by heading, not distance alone. A camera fifty
    /// metres behind on the other carriageway is closer than one four
    /// hundred metres up the road, and warning about the wrong one teaches
    /// the driver to ignore the warning.
    static func imminent(among cameras: [Camera],
                         at position: CLLocationCoordinate2D,
                         headingDegrees: Double?) -> (camera: Camera,
                                                      meters: Double)? {
        cameras
            .map { (camera: $0, meters: POIRanking.meters($0.coordinate, position)) }
            .filter { $0.meters <= warnMeters && $0.meters >= clearMeters }
            .filter { isAhead($0.camera.coordinate, from: position,
                              headingDegrees: headingDegrees) }
            .min { $0.meters < $1.meters }
    }

    /// Is a point in front of the vehicle? Within a 100° cone either side of
    /// the direction of travel. With no heading — stopped, or a fix with no
    /// course — everything counts, because there is nothing better to say.
    static func isAhead(_ target: CLLocationCoordinate2D,
                        from position: CLLocationCoordinate2D,
                        headingDegrees: Double?) -> Bool {
        guard let heading = headingDegrees, heading >= 0 else { return true }
        let bearing = bearingDegrees(from: position, to: target)
        var delta = (bearing - heading).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return abs(delta) <= 100
    }

    /// Compass bearing from one point to another, 0..<360.
    static func bearingDegrees(from a: CLLocationCoordinate2D,
                               to b: CLLocationCoordinate2D) -> Double {
        let rad = Double.pi / 180
        let dLon = (b.longitude - a.longitude) * rad
        let y = sin(dLon) * cos(b.latitude * rad)
        let x = cos(a.latitude * rad) * sin(b.latitude * rad)
            - sin(a.latitude * rad) * cos(b.latitude * rad) * cos(dLon)
        let deg = atan2(y, x) / rad
        return deg < 0 ? deg + 360 : deg
    }

    /// What to say. The camera's own limit wins over the road's when the
    /// mapper recorded one, and the line only mentions speed when the driver
    /// is actually over it — a red-light camera has nothing to do with how
    /// fast a law-abiding driver is going.
    static func warning(for camera: Camera, meters: Double,
                        speedMph: Double, postedLimitMph: Double?) -> String {
        let feet = Int((meters * 3.28084 / 50).rounded() * 50)
        let limit = camera.limitMph ?? postedLimitMph
        var line = "\(camera.kind.title) in \(feet) feet"
        if let limit, speedMph > limit + 1 {
            line += " — limit \(Int(limit.rounded()))"
        }
        return line
    }
}
