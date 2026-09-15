// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// When the sun sets and rises WHERE THE DRIVER IS — the app's dark mode
/// runs off this, not off a fixed clock time. Pure math, pinned by
/// FLOWSTests.
///
/// Dusk in Miami in June and dusk in Fairbanks in December are six hours
/// apart; a screen that dims "at 8 pm" is wrong for most of the country most
/// of the year. This is the standard NOAA solar-position algorithm, accurate
/// to about a minute, which is far better than the eye can judge.
///
/// The boundary used is CIVIL twilight (sun 6° below the horizon), not the
/// moment the disc touches the horizon: that is when headlights go on and
/// when a bright screen starts to hurt, which is the thing being decided.
///
/// The astronomy is computed in rust/flows-core (climate.rs) and called
/// through rust/flows-bridge; instants cross as
/// `timeIntervalSinceReferenceDate`. Pinned to the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_climate_oracle.tsv (to a stated
/// tolerance where trigonometry is involved; every instant there is exact).
enum DaylightClock {
    /// Sun angle that counts as dark. Civil twilight — enough light to see
    /// by is gone.
    static let civilTwilightDegrees = flows_climate_civil_twilight_degrees()

    /// The Julian day number for an instant.
    static func julianDay(_ date: Date) -> Double {
        flows_climate_julian_day(date.timeIntervalSinceReferenceDate)
    }

    /// The Julian day of the MIDNIGHT that begins the UTC day containing
    /// `jd` (a floor, not a round: Julian days tick over at noon).
    static func midnightJD(_ jd: Double) -> Double {
        flows_climate_midnight_jd(jd)
    }

    /// The sun's declination and the equation of time (minutes) for a day.
    static func solarTerms(julianDay jd: Double) -> (declination: Double, equationOfTime: Double) {
        let t = flows_climate_solar_terms(jd)
        return (t.declination, t.equation_of_time)
    }

    /// Minutes from local solar noon to the sun reaching `angle`. nil inside
    /// the polar day or polar night, where the sun never crosses it at all.
    static func hourAngleMinutes(latitude: Double, declination: Double, angle: Double) -> Double? {
        // NaN crosses back for "no crossing"; a real hour angle never is NaN.
        let minutes = flows_climate_hour_angle_minutes(latitude, declination, angle)
        return minutes.isNaN ? nil : minutes
    }

    /// Sunrise and sunset (civil twilight by default) for a place and day,
    /// as instants. nil in the polar day/night, where there is no crossing.
    /// The day is chosen LOCALLY, by longitude, not in UTC.
    static func twilight(at coordinate: CLLocationCoordinate2D, on date: Date,
                         angle: Double = civilTwilightDegrees) -> (dawn: Date, dusk: Date)? {
        let t = flows_climate_twilight(coordinate.latitude, coordinate.longitude,
                                       date.timeIntervalSinceReferenceDate, angle)
        guard t.has == 1 else { return nil }
        return (dawn: Date(timeIntervalSinceReferenceDate: t.dawn),
                dusk: Date(timeIntervalSinceReferenceDate: t.dusk))
    }

    /// Is it dark out, here, now? Above the polar circles, where there may be
    /// no dawn or dusk to compare against, the sun's actual height decides.
    static func isNight(at coordinate: CLLocationCoordinate2D, now: Date = Date()) -> Bool {
        flows_climate_is_night(coordinate.latitude, coordinate.longitude, now.timeIntervalSinceReferenceDate)
    }

    /// The sun's height above the horizon in degrees — the polar fallback,
    /// and useful on its own.
    static func solarElevation(at coordinate: CLLocationCoordinate2D, now: Date = Date()) -> Double {
        flows_climate_solar_elevation(coordinate.latitude, coordinate.longitude, now.timeIntervalSinceReferenceDate)
    }

    /// When the app should look again — the next dawn or dusk, whichever is
    /// next, so the switch happens ON the boundary rather than up to an hour
    /// late. Falls back to an hour out where there is no boundary today.
    static func nextChange(at coordinate: CLLocationCoordinate2D, now: Date = Date()) -> Date {
        Date(timeIntervalSinceReferenceDate: flows_climate_next_change(
            coordinate.latitude, coordinate.longitude, now.timeIntervalSinceReferenceDate))
    }
}
