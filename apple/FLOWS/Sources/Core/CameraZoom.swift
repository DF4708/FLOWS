// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation
import MapKit

/// The navigation camera's zoom policy — how far the map floats above the
/// traveler. Pure math, pinned by FLOWSTests.
///
/// The distance shown follows the DISTANCE BETWEEN INTERSECTIONS: city
/// blocks a few hundred meters apart keep the view close, a highway with
/// miles between off-ramps floats out far enough to see the road ahead, and
/// an imminent turn tightens onto the intersection. Walking pace never needs
/// distance, so walking pins to the close-in view. A flight is phased: on
/// the ground at either airport it reads like walking, cruise reads like a
/// continent, and climb-out/approach glide between the two.
enum CameraZoom {
    /// Walking pace — always the close-in view.
    static let walkingAltitude: Double = 260
    /// Tight zoom onto an imminent intersection.
    static let intersectionAltitude: Double = 350
    /// Dense city blocks hold this floor.
    static let cityAltitude: Double = 500
    /// An empty highway window relaxes to this ceiling (before the
    /// speed stretch).
    static let highwayAltitude: Double = 2_400
    /// Cruise — zoomed out until the destination airport approaches.
    static let cruiseAltitude: Double = 150_000

    /// Driving altitude from the spacing between intersections (the road
    /// between the maneuver behind and the one ahead). ~300 m city blocks
    /// hold the city floor; ~6 km between off-ramps reaches the highway
    /// ceiling, stretched a little with speed so faster travel sees
    /// proportionally farther. The view also starts tightening on the way
    /// INTO a turn — the shown distance never exceeds ~2× the road left
    /// before the maneuver — and pins to the intersection inside 250 m.
    static func drivingAltitude(intersectionSpacingMeters: Double,
                                distanceToManeuverMeters: Double,
                                speedMps: Double) -> Double {
        if distanceToManeuverMeters < 250 { return intersectionAltitude }
        let effective = min(max(intersectionSpacingMeters, 0),
                            max(distanceToManeuverMeters, 250) * 2.2)
        let t = min(max((effective - 300) / 5_700, 0), 1)
        let base = cityAltitude + (highwayAltitude - cityAltitude) * t
        let speedStretch = min(max(speedMps / 31.0, 1.0), 1.5)   // 31 m/s ≈ 70 mph
        return base * (t > 0.5 ? speedStretch : 1.0)
    }

    // MARK: framing a route around the chrome

    /// How much of the window the choices panel covers — the trip pill, the
    /// filter grid, and the route list (itself capped at height/φ²).
    static let choicesPanelFraction = 0.5

    /// A route rect worth pointing a camera at, or nil.
    ///
    /// `MKPolyline.boundingMapRect` on an EMPTY polyline is null — and a
    /// null rect fed to the camera reads as latitude 0, longitude 0, which
    /// is in the Atlantic off West Africa. That is the "why is it showing me
    /// Africa and Europe" jump: a route whose geometry hadn't arrived yet
    /// (or a transit leg with no drawn line) got framed at the null island.
    /// A degenerate speck is rejected for the same reason — there is nothing
    /// there to look at.
    static func usableRect(_ rect: MKMapRect) -> MKMapRect? {
        guard !rect.isNull, !rect.isEmpty,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width > 1, rect.size.height > 1 else { return nil }
        return rect
    }

    /// Frame a route so it lands in the map the driver can actually SEE,
    /// rather than behind the choices panel.
    ///
    /// This SHIFTS the camera rather than growing the rect. Growing doesn't
    /// work: MapKit fits a rect by its constraining dimension, and a typical
    /// route (wide east-west, thin north-south) is width-constrained — extra
    /// height changes nothing until it dwarfs the width, which would zoom the
    /// route into uselessness. Shifting the rect's center by a slice of the
    /// FITTED span keeps the zoom exactly as it was and simply slides the
    /// route out from under the panel: north for a top panel (MKMapRect y
    /// runs southward, so north is a smaller origin.y), west for a side one.
    static func framedRect(_ rect: MKMapRect,
                           panelOnTop: Bool,
                           windowAspect: Double,
                           panelFraction: Double = choicesPanelFraction) -> MKMapRect {
        var fit = rect.insetBy(dx: -rect.width * 0.2, dy: -rect.height * 0.2)
        guard windowAspect > 0, panelFraction > 0 else { return fit }
        if panelOnTop {
            // The north-south span actually on screen once fitted.
            let visibleHeight = max(fit.size.height, fit.size.width * windowAspect)
            fit.origin.y -= visibleHeight * panelFraction / 2
        } else {
            let visibleWidth = max(fit.size.width, fit.size.height / windowAspect)
            fit.origin.x -= visibleWidth * panelFraction / 2
        }
        // Whatever the shift does, the WHOLE route must remain inside the
        // framed rect — selecting a card should always show the entire
        // route, zooming out if that is what it takes.
        return fit.union(rect)
    }

    /// Where to point the camera so the VEHICLE lands in the middle of the
    /// band of map the driver can actually see.
    ///
    /// The map runs full-bleed under the chrome: the directions banner and
    /// the instrument cluster cover the top, the drive bar covers the
    /// bottom. Centering on the vehicle therefore puts it in the middle of
    /// the WHOLE map, which is behind the banner — the driver ends up
    /// looking at their own position through a card. Shifting the camera's
    /// target along the heading slides the vehicle down into the open band
    /// without touching the zoom, which is the part that must not change.
    ///
    /// `topCover` and `bottomCover` are the fractions of the window the
    /// chrome occupies. Returns the vehicle itself when nothing is covered.
    static func chaseCenter(vehicle: CLLocationCoordinate2D,
                            headingDegrees: Double,
                            distanceMeters: Double,
                            topCover: Double,
                            bottomCover: Double) -> CLLocationCoordinate2D {
        let top = min(max(topCover, 0), 0.45)
        let bottom = min(max(bottomCover, 0), 0.45)
        // Middle of the open band, as a fraction down the window.
        let visibleMiddle = (top + (1 - bottom)) / 2
        let shiftFraction = visibleMiddle - 0.5
        guard abs(shiftFraction) > 0.001, distanceMeters > 0 else { return vehicle }
        // The camera's vertical span is on the order of its distance; a
        // fraction of that is how far to move the aim point. Pushing the aim
        // FORWARD along the heading drops the vehicle further down-screen.
        let meters = shiftFraction * distanceMeters
        return offset(vehicle, metersAlong: headingDegrees, meters: meters)
    }

    /// A coordinate `meters` away from `from` along a compass bearing.
    static func offset(_ from: CLLocationCoordinate2D,
                       metersAlong bearingDegrees: Double,
                       meters: Double) -> CLLocationCoordinate2D {
        let rad = Double.pi / 180
        let north = cos(bearingDegrees * rad) * meters
        let east = sin(bearingDegrees * rad) * meters
        let dLat = north / 111_320
        let dLon = east / (111_320 * max(cos(from.latitude * rad), 0.01))
        return CLLocationCoordinate2D(latitude: from.latitude + dLat,
                                      longitude: from.longitude + dLon)
    }

    /// Flight altitude by phase, from the distance to the NEAREST of the two
    /// airports: inside the airport radius (before takeoff, after landing,
    /// final approach) the view reads like walking; past the climb-out
    /// window it's cruise; between the two it glides linearly, so leaving
    /// one airport zooms out and nearing the other zooms back in.
    static func flightAltitude(metersToNearestAirport: Double) -> Double {
        let airportRadius = 2_500.0
        let cruiseBeyond = 40_000.0
        if metersToNearestAirport <= airportRadius { return walkingAltitude }
        if metersToNearestAirport >= cruiseBeyond { return cruiseAltitude }
        let t = (metersToNearestAirport - airportRadius)
            / (cruiseBeyond - airportRadius)
        return walkingAltitude + (cruiseAltitude - walkingAltitude) * t
    }
}
