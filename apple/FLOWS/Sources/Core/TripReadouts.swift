// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// The numbers behind the trip's distance and time readouts, in one place:
/// the driving screen's turn distance and time left, the route card's time
/// and miles, the planner's miles, what Siri says, the share of a route in
/// alert areas, minutes saved by a faster road, and the grade under the
/// vehicle. They sat inline in the views, where no test could see them.
enum TripReadouts {
    static func miles(_ meters: Double) -> Double { meters / 1609.344 }

    // MARK: distance

    /// Feet to show for a turn this close, to the nearest 50 and never below
    /// 50 (the turn is here, not nowhere); nil from 0.19 miles out, where the
    /// readout is in miles.
    static func turnFeet(_ meters: Double) -> Int? {
        guard miles(meters) < 0.19 else { return nil }
        return max(50, Int((meters / 0.3048 / 50).rounded() * 50))
    }

    /// Digits after the point for a distance in miles: tenths below ten
    /// miles (a half-mile walk read "0 mi"), whole miles from there. 9.95 to
    /// 9.99 miles rounds to "10 mi", not "10.0 mi".
    static func milePlaces(_ meters: Double) -> Int { miles(meters) < 9.95 ? 1 : 0 }

    /// The planner's rule: tenths under ten miles, whole miles beyond.
    static func plannerMilePlaces(_ meters: Double) -> Int { miles(meters) < 10 ? 1 : 0 }

    /// "450 ft" close to the turn, "2.4 mi" or "12 mi" further out.
    static func turnDistanceText(_ meters: Double) -> String {
        if let feet = turnFeet(meters) { return "\(feet) ft" }
        return milesText(meters)
    }

    /// "0.4 mi", "12 mi".
    static func milesText(_ meters: Double) -> String {
        "\(miles(meters).fixed(milePlaces(meters))) mi"
    }

    /// The planner's "0.4 mi", "12 mi".
    static func plannerMilesText(_ meters: Double) -> String {
        "\(miles(meters).fixed(plannerMilePlaces(meters))) mi"
    }

    /// How Siri says a distance.
    enum SpokenMiles: Equatable {
        /// "1 mile"
        case one
        /// "12 miles"
        case whole(Int)
        /// "0.4 miles"
        case tenths(Double)
    }

    /// Whole numbers read naturally, close-in stops keep one decimal, and
    /// 1 mile is not plural.
    static func spokenMiles(meters: Double) -> SpokenMiles {
        let miles = miles(meters)
        if miles < 10 {
            let rounded = (miles * 10).rounded() / 10
            if rounded == 1 { return .one }
            // Drop a trailing ".0": "5 miles", not "5.0 miles".
            return rounded == rounded.rounded() ? .whole(Int(rounded)) : .tenths(rounded)
        }
        return .whole(Int(miles.rounded()))
    }

    // MARK: time

    /// Whole minutes in a time of seconds, rounded.
    static func minutes(_ seconds: Double) -> Int { Int((seconds / 60).rounded()) }

    /// How a time reads.
    enum Clock: Equatable {
        /// "45 min"
        case minutes(Int)
        /// "2 h 05 min"
        case hours(Int, minutes: Int)
        /// "10.8 days"
        case days(Double)
    }

    /// Minutes up to 89, hours and minutes from 90. With `days`, a time of
    /// two days or more reads in days (a multi-day walk is not "260 h").
    static func clock(seconds: Double, days: Bool) -> Clock {
        let mins = minutes(seconds)
        if days, mins >= 48 * 60 { return .days(seconds / 86_400) }
        return mins >= 90 ? .hours(mins / 60, minutes: mins % 60) : .minutes(mins)
    }

    /// "45 min", "2 h 05 min", "10.8 days".
    static func clockText(seconds: Double, days: Bool) -> String {
        switch clock(seconds: seconds, days: days) {
        case .minutes(let m): return "\(m) min"
        case .hours(let h, let m): return "\(h) h \(m.padded(2)) min"
        case .days(let d): return "\(d.fixed(1)) days"
        }
    }

    /// Whole minutes a faster road saves, at least 1.
    static func minutesSaved(from eta: Double, to faster: Double) -> Int {
        max(Int(((eta - faster) / 60).rounded()), 1)
    }

    // MARK: alert areas

    /// The share of the route inside alert areas, as a whole percent.
    static func exposurePercent(coverage: Double) -> Int { Int((coverage * 100).rounded()) }

    /// Whole miles of the route inside alert areas.
    static func exposureMiles(meters: Double, coverage: Double) -> Int {
        Int((miles(meters) * coverage).rounded())
    }

    // MARK: grade

    /// The grade of the road at this mile: the first measured stretch that
    /// holds it, level road where none does.
    static func grade(atMile mile: Double, in profile: [GradeSegment]) -> Double {
        profile.first { mile >= $0.startMile && mile <= $0.endMile }?.gradePercent ?? 0
    }
}
