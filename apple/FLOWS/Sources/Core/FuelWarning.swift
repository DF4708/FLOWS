// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// The fuel gauge's color curve and the "stop for fuel NOW" decision — pure,
/// pinned by FLOWSTests.
///
/// The warning exists to beat one specific failure: driving past the last
/// station that sells YOUR fuel and into a stretch with none. So it does not
/// key off a fixed percentage — it counts how many matching stations are
/// still REACHABLE on the fuel left. When that count falls to the last few,
/// the driver still has a choice; one stretch later they do not.
enum FuelWarning {

    // MARK: gauge color — exponential, so only near-empty shouts

    /// How alarming the tank level is, 0 (full) … 1 (empty), on an
    /// exponential curve: a tank drifting down from full barely moves the
    /// needle's color, and the last stretch before empty climbs fast. Keeps
    /// the gauge green through the ordinary middle of a tank.
    static func severity(fraction: Double) -> Double {
        flows_long_trips_fuel_severity(fraction)
    }

    /// Gauge band from the severity curve. Green holds until roughly the
    /// last third (~29% of tank), yellow warns, and red is the final ~14% —
    /// where the range left is genuinely a planning problem.
    enum Band: Equatable { case green, yellow, red }

    static func band(fraction: Double) -> Band {
        // Red from severity 0.65 (≲14% of tank), yellow from 0.35 (≲29%):
        // rust/flows-core long_trips.rs.
        switch flows_long_trips_fuel_band(fraction) {
        case 2: return .red
        case 1: return .yellow
        default: return .green
        }
    }

    // MARK: reachable-station warning

    /// A refuel candidate ahead on the route that sells the vehicle's fuel.
    struct Station: Equatable {
        let name: String
        /// Distance ahead along the route, in miles.
        let milesAhead: Double
        /// $/gal, $/kWh… when a price source supplied one.
        var pricePerUnit: Double?
    }

    /// The warning fires while this many (or fewer) matching stations are
    /// still reachable — enough that the driver can pick one, few enough
    /// that the next stretch could strand them.
    /// How wide a cone counts as "on the road ahead" when there is no route
    /// to measure along — the same 100° either side the camera warning uses.
    /// Wide enough to keep a station just off a bend, narrow enough to
    /// exclude one the driver has already passed.
    static let aheadConeDegrees = flows_geo_ahead_cone_degrees()

    /// Is this station somewhere the driver can still REACH, or one they
    /// have already driven past?
    ///
    /// This exists because the scan used to keep any station within a
    /// straight-line radius and call the result "ahead". A station five
    /// miles BEHIND passed that test exactly like one five miles in front,
    /// so the last-chance warning counted unreachable pumps toward "you
    /// still have options" and stayed silent — the precise failure the
    /// warning exists to prevent.
    ///
    /// With a route, ahead-ness is measured against the road actually being
    /// driven: the station must be near a sample the vehicle has not reached
    /// yet. Without one, it falls back to the direction of travel. With
    /// neither — parked, no course, no route — nothing can be ruled out, so
    /// everything is kept rather than silently dropping real options.
    static func isReachable(station: CLLocationCoordinate2D,
                            from here: CLLocationCoordinate2D,
                            courseDegrees: Double,
                            routeAhead: [CLLocationCoordinate2D],
                            corridorMeters: Double = flows_geo_fuel_corridor_meters()) -> Bool {
        // rust/flows-core geo.rs. With no route the columns hold a
        // placeholder behind a zero count: the bridge never sees an empty
        // buffer.
        let lats = routeAhead.isEmpty ? [0] : routeAhead.map(\.latitude)
        let lons = routeAhead.isEmpty ? [0] : routeAhead.map(\.longitude)
        return lats.withUnsafeBufferPointer { la in
            lons.withUnsafeBufferPointer { lo in
                flows_geo_fuel_station_is_reachable(
                    station.latitude, station.longitude, here.latitude, here.longitude,
                    courseDegrees, la, lo, Int64(routeAhead.count), corridorMeters)
            }
        }
    }

    /// Compass bearing from one point to another, 0..<360.
    static func bearingDegrees(from a: CLLocationCoordinate2D,
                               to b: CLLocationCoordinate2D) -> Double {
        flows_geo_bearing_degrees(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    static let warnAtReachableCount = Int(flows_long_trips_warn_at_reachable_count())

    enum Level: Equatable {
        case none
        /// Only these few matching stations are still in range.
        case lastChances(remaining: Int)
        /// Nothing that sells this fuel is reachable on what's left.
        case unreachable
    }

    /// Stations reachable on the fuel remaining, keeping the reserve intact
    /// (never route a driver to arrive on fumes), nearest first.
    static func reachable(stationsAhead: [Station], rangeMiles: Double,
                          reserveMiles: Double = VehicleProfile.reserveMiles) -> [Station] {
        let order = StationColumns(stationsAhead).call { miles, prices, priced, count in
            Array(flows_long_trips_reachable_stations(miles, prices, priced, count,
                                                      rangeMiles, reserveMiles))
        }
        return order.map { stationsAhead[Int($0)] }
    }

    /// The warning level for this range and this list of matching stations.
    /// `stationsAhead` must already be filtered to the vehicle's fuel type —
    /// a diesel truck is not helped by knowing about gas pumps.
    static func level(stationsAhead: [Station], rangeMiles: Double,
                      reserveMiles: Double = VehicleProfile.reserveMiles) -> Level {
        // Nothing reachable is .unreachable even when the search found
        // nothing at all — silence is the failure mode this whole feature
        // exists to prevent (rust/flows-core long_trips.rs).
        let code = StationColumns(stationsAhead).call { miles, prices, priced, count in
            flows_long_trips_fuel_level(miles, prices, priced, count, rangeMiles, reserveMiles)
        }
        switch code {
        case 0: return .none
        case let remaining where remaining > 0: return .lastChances(remaining: Int(remaining))
        default: return .unreachable
        }
    }

    /// Cheapest of the reachable stations (ties → nearest). Stations with no
    /// known price rank behind priced ones, since "cheapest" should mean a
    /// price we can actually stand behind.
    static func cheapest(stationsAhead: [Station], rangeMiles: Double,
                         reserveMiles: Double = VehicleProfile.reserveMiles) -> Station? {
        let index = StationColumns(stationsAhead).call { miles, prices, priced, count in
            flows_long_trips_cheapest_station(miles, prices, priced, count, rangeMiles, reserveMiles)
        }
        return index >= 0 ? stationsAhead[Int(index)] : nil
    }

    /// The stations as the bridge reads them: distance, price and whether a
    /// price is known, with a placeholder behind a zero count for an empty
    /// list.
    private struct StationColumns {
        let miles: [Double]
        let prices: [Double]
        let priced: [UInt8]
        let count: Int64

        init(_ stations: [Station]) {
            miles = stations.isEmpty ? [0] : stations.map(\.milesAhead)
            prices = stations.isEmpty ? [0] : stations.map { $0.pricePerUnit ?? 0 }
            priced = stations.isEmpty ? [0] : stations.map { $0.pricePerUnit == nil ? 0 : 1 }
            count = Int64(stations.count)
        }

        func call<R>(_ body: (UnsafeBufferPointer<Double>, UnsafeBufferPointer<Double>,
                              UnsafeBufferPointer<UInt8>, Int64) -> R) -> R {
            miles.withUnsafeBufferPointer { m in
                prices.withUnsafeBufferPointer { p in
                    priced.withUnsafeBufferPointer { f in body(m, p, f, count) }
                }
            }
        }
    }

    /// What the app SAYS out loud. Plain words, one breath, names the fuel,
    /// the place, and how far — a driver hears this without looking.
    static func spokenAdvice(fuel: FuelType, level: Level, station: Station?,
                             rangeMiles: Double) -> String? {
        let unitWord = fuel == .electric ? "charging" : fuel.rawValue.lowercased()
        switch level {
        case .none:
            return nil
        case .lastChances(let remaining):
            guard let station else { return nil }
            let count = remaining == 1
                ? "This is the last \(unitWord) stop in range"
                : "Only \(remaining) \(unitWord) stops left in range"
            return "\(count). \(station.name) is "
                + "\(Int(station.milesAhead.rounded())) miles ahead"
                + pricePhrase(station, fuel: fuel)
                + ". Add it to the route?"
        case .unreachable:
            return "No \(unitWord) stop is within your remaining "
                + "\(Int(rangeMiles.rounded())) miles. Turn back or find fuel now."
        }
    }

    /// The same message on screen — short enough for a glance.
    static func bannerText(fuel: FuelType, level: Level, station: Station?) -> String? {
        let unitWord = fuel == .electric ? "charging" : fuel.rawValue.lowercased()
        switch level {
        case .none:
            return nil
        case .lastChances(let remaining):
            guard let station else { return nil }
            let lead = remaining == 1 ? "Last \(unitWord) stop in range"
                                      : "\(remaining) \(unitWord) stops left in range"
            return "\(lead) — \(station.name), "
                + "\(Int(station.milesAhead.rounded())) mi"
                + pricePhrase(station, fuel: fuel)
        case .unreachable:
            return "No \(unitWord) stop within range — find fuel now"
        }
    }

    private static func pricePhrase(_ station: Station, fuel: FuelType) -> String {
        guard let price = station.pricePerUnit else { return "" }
        let unit = fuel == .electric ? "kilowatt hour" : "gallon"
        return String(format: " at $%.2f a %@", price, unit)
    }
}
