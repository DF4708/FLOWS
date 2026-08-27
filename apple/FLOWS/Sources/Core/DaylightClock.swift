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
enum DaylightClock {
    /// Sun angle that counts as dark. Civil twilight — enough light to see
    /// by is gone.
    static let civilTwilightDegrees = -6.0

    private static let rad = Double.pi / 180

    /// The Julian day number for an instant.
    static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5
    }

    /// The Julian day of the MIDNIGHT that begins the UTC day containing
    /// `jd`. Julian days tick over at noon, so midnight is the .5 below —
    /// which is a floor, not a round. Rounding lands on the next day's
    /// midnight for any afternoon instant, and every sunset comes out a day
    /// late.
    static func midnightJD(_ jd: Double) -> Double {
        (jd - 0.5).rounded(.down) + 0.5
    }

    /// The sun's declination and the equation of time (minutes) for a day.
    /// Both come out of the same orbital terms, so they're computed together.
    static func solarTerms(julianDay jd: Double) -> (declination: Double,
                                                     equationOfTime: Double) {
        let t = (jd - 2_451_545.0) / 36_525          // Julian centuries
        let meanLong = (280.46646 + t * (36_000.76983 + t * 0.0003032))
            .truncatingRemainder(dividingBy: 360)
        let meanAnom = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let eccent = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let center = sin(meanAnom * rad) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * meanAnom * rad) * (0.019993 - 0.000101 * t)
            + sin(3 * meanAnom * rad) * 0.000289
        let trueLong = meanLong + center
        let omega = 125.04 - 1_934.136 * t
        let apparentLong = trueLong - 0.00569 - 0.00478 * sin(omega * rad)
        let meanObliq = 23 + (26 + ((21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))))
            / 60) / 60
        let obliq = meanObliq + 0.00256 * cos(omega * rad)
        let declination = asin(sin(obliq * rad) * sin(apparentLong * rad)) / rad

        let y = pow(tan(obliq * rad / 2), 2)
        let eqTime = 4 * (y * sin(2 * meanLong * rad)
            - 2 * eccent * sin(meanAnom * rad)
            + 4 * eccent * y * sin(meanAnom * rad) * cos(2 * meanLong * rad)
            - 0.5 * y * y * sin(4 * meanLong * rad)
            - 1.25 * eccent * eccent * sin(2 * meanAnom * rad)) / rad
        return (declination, eqTime)
    }

    /// Minutes from local solar noon to the sun reaching `angle`. nil inside
    /// the polar day or polar night, where the sun never crosses it at all.
    static func hourAngleMinutes(latitude: Double, declination: Double,
                                 angle: Double) -> Double? {
        let cosH = (cos((90 - angle) * rad)
            - sin(latitude * rad) * sin(declination * rad))
            / (cos(latitude * rad) * cos(declination * rad))
        guard cosH >= -1, cosH <= 1 else { return nil }
        return acos(cosH) / rad * 4      // 4 minutes per degree of rotation
    }

    /// Sunrise and sunset (civil twilight by default) for a place and day,
    /// as instants. nil in the polar day/night, where there is no crossing.
    static func twilight(at coordinate: CLLocationCoordinate2D,
                         on date: Date,
                         angle: Double = civilTwilightDegrees)
        -> (dawn: Date, dusk: Date)? {
        // The day has to be chosen LOCALLY, not in UTC. West of Greenwich a
        // summer evening falls on the following UTC day, so asking for "the
        // UTC day's dusk" at 9 pm in Wisconsin returns tomorrow's — and the
        // screen goes dark in the middle of the afternoon. Shifting by the
        // longitude first picks the solar day the driver is actually in.
        let jd = midnightJD(julianDay(date) + coordinate.longitude / 360)
        let terms = solarTerms(julianDay: jd)
        guard let ha = hourAngleMinutes(latitude: coordinate.latitude,
                                        declination: terms.declination,
                                        angle: angle) else { return nil }
        // Solar noon in minutes past midnight UTC at this longitude.
        let noonUTC = 720 - 4 * coordinate.longitude - terms.equationOfTime
        let midnight = Date(timeIntervalSince1970: (jd - 2_440_587.5) * 86_400)
        return (dawn: midnight.addingTimeInterval((noonUTC - ha) * 60),
                dusk: midnight.addingTimeInterval((noonUTC + ha) * 60))
    }

    /// Is it dark out, here, now?
    ///
    /// Above the Arctic and Antarctic circles the sun can stay up or stay
    /// down for months, and there is no dawn or dusk to compare against; the
    /// answer there falls back to the sun's actual height at this moment.
    static func isNight(at coordinate: CLLocationCoordinate2D,
                        now: Date = Date()) -> Bool {
        guard let t = twilight(at: coordinate, on: now) else {
            return solarElevation(at: coordinate, now: now) < civilTwilightDegrees
        }
        return now < t.dawn || now >= t.dusk
    }

    /// The sun's height above the horizon in degrees — the polar fallback,
    /// and useful on its own.
    static func solarElevation(at coordinate: CLLocationCoordinate2D,
                               now: Date = Date()) -> Double {
        let jd = julianDay(now)
        let terms = solarTerms(julianDay: jd)
        let minutesUTC = (jd - midnightJD(jd)) * 1_440
        // Degrees the earth has turned past this longitude's solar noon.
        let trueSolarMinutes = minutesUTC + terms.equationOfTime
            + 4 * coordinate.longitude
        let hourAngle = trueSolarMinutes / 4 - 180
        let zenith = acos(
            sin(coordinate.latitude * rad) * sin(terms.declination * rad)
            + cos(coordinate.latitude * rad) * cos(terms.declination * rad)
                * cos(hourAngle * rad)) / rad
        return 90 - zenith
    }

    /// When the app should look again — the next dawn or dusk, whichever is
    /// next, so the switch happens ON the boundary rather than up to an hour
    /// late. Falls back to an hour out where there is no boundary today.
    static func nextChange(at coordinate: CLLocationCoordinate2D,
                           now: Date = Date()) -> Date {
        guard let today = twilight(at: coordinate, on: now) else {
            return now.addingTimeInterval(3_600)
        }
        if now < today.dawn { return today.dawn }
        if now < today.dusk { return today.dusk }
        guard let tomorrow = twilight(at: coordinate,
                                      on: now.addingTimeInterval(86_400)) else {
            return now.addingTimeInterval(3_600)
        }
        return tomorrow.dawn
    }
}
