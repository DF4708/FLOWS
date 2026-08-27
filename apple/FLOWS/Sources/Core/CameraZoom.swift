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
