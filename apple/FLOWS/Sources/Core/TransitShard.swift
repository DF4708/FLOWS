// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// Real published departure times, read from a timetable the device built
/// itself out of the operator's own schedule feed.
///
/// The routing runs in rust/flows-core (`transit::shard` — a RAPTOR query over
/// a `.ftt`/`.fts` pair); this is the Swift side of that boundary: it parses
/// the bridge's tagged rows into values, and hands every stored time to
/// `TransitClock`, which is the only thing here that knows what a clock is.
enum TransitShard {
    /// One ride: board a train at a station, get off at another.
    struct Ride: Equatable {
        let boardName: String
        let boardCode: String
        let boardZone: String
        let alightName: String
        let alightCode: String
        let alightZone: String
        /// What the operator calls the service — "Hiawatha Service".
        let routeName: String
        /// The engine's mode byte: 0 rail, 1 subway, 2 bus, 3 coach, 4 commuter.
        let mode: Int
        /// Seconds from the service day's start, in the AGENCY's zone.
        let departSeconds: Int
        let arriveSeconds: Int
    }

    /// One whole itinerary the rider could take.
    struct Departure: Equatable {
        let rides: [Ride]
        let departSeconds: Int
        let arriveSeconds: Int
        let transfers: Int
        let walkSeconds: Int
    }

    /// Which stations the trip actually uses, and how far they are from where
    /// the rider asked to start and finish.
    struct Ends: Equatable {
        let boardName: String
        let boardCode: String
        let boardZone: String
        let boardMeters: Double
        let alightName: String
        let alightCode: String
        let alightZone: String
        let alightMeters: Double
    }

    /// A timetable's provenance: which day it describes, when it was published,
    /// and the zone its times are measured from.
    struct Stamp: Equatable {
        let serviceDate: Int
        let published: Int
        let agencyZone: String
    }

    struct Answer: Equatable {
        let stamp: Stamp
        let ends: Ends
        let departures: [Departure]
    }

    /// Why an answer could not be given — shown to the rider as written, so it
    /// says what happened in plain words rather than naming a file.
    enum Failure: Error, Equatable {
        case noneNearby
        case noRide
        case notBuilt(String)

        var plainText: String {
            switch self {
            case .noneNearby: return "No train station close enough to either end of this trip."
            case .noRide: return "No train runs between those stations today."
            case .notBuilt: return "Train times aren't ready yet."
            }
        }
    }

    // -- Building -------------------------------------------------------------

    /// The zone a feed keeps its times in, from `agency.txt` alone. Asked
    /// before building, because "what day is it?" has to be answered in the
    /// operator's zone: at 9pm in Honolulu, Amtrak is already on tomorrow.
    static func agencyZone(feedDirectory: String) -> String {
        flows_transit_agency_zone(feedDirectory).toString()
    }

    /// Build the shard pair for a service date from an unzipped feed.
    @discardableResult
    static func build(feedDirectory: String, prefix: String, serviceDate: Int) throws -> Stamp {
        let rows = decode(flows_transit_build(feedDirectory, prefix, Int64(serviceDate)))
        if let message = firstError(rows) { throw Failure.notBuilt(message) }
        guard let stamp = stamp(rows) else { throw Failure.notBuilt("the feed produced no timetable") }
        return stamp
    }

    /// What a built shard says about itself, or nil when there is none.
    static func stamp(prefix: String) -> Stamp? {
        stamp(decode(flows_transit_info(prefix)))
    }

    // -- Asking ---------------------------------------------------------------

    /// What leaves after `departing` on the trip's own service day.
    static func departures(
        prefix: String,
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        departing: Date,
        stamp known: Stamp,
        maxStationMeters: Double = 40_000,
        limit: Int = 4
    ) throws -> Answer {
        guard let seconds = TransitClock.seconds(
            at: departing, serviceDate: known.serviceDate, agencyZone: known.agencyZone
        ) else { throw Failure.notBuilt("these times are for a different day") }

        let rows = decode(flows_transit_departures(
            prefix, from.latitude, from.longitude, to.latitude, to.longitude,
            maxStationMeters, Int64(max(0, seconds)), Int64(limit)
        ))
        if let message = firstError(rows) {
            if message.contains("no station near") { throw Failure.noneNearby }
            if message.contains("no ride") { throw Failure.noRide }
            throw Failure.notBuilt(message)
        }
        guard let stamp = stamp(rows), let ends = ends(rows) else { throw Failure.noRide }
        let found = departures(rows)
        guard !found.isEmpty else { throw Failure.noRide }
        return Answer(stamp: stamp, ends: ends, departures: found)
    }

    /// The instant a stored time happens, on this shard's service day.
    static func moment(_ seconds: Int, _ stamp: Stamp) -> Date? {
        TransitClock.instant(
            serviceDate: stamp.serviceDate, agencyZone: stamp.agencyZone, seconds: seconds
        )
    }

    // -- Row decoding ---------------------------------------------------------

    private static func decode(_ rows: RustVec<RustString>) -> [[String]] {
        var out: [[String]] = []
        for row in rows {
            let text: String = row.as_str().toString()
            out.append(
                text.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            )
        }
        return out
    }

    private static func firstError(_ rows: [[String]]) -> String? {
        for row in rows where row.first == "err" {
            return row.count > 1 ? row[1] : "unknown"
        }
        return rows.isEmpty ? "no answer" : nil
    }

    private static func stamp(_ rows: [[String]]) -> Stamp? {
        for row in rows where row.first == "info" && row.count >= 4 {
            return Stamp(
                serviceDate: Int(row[1]) ?? 0, published: Int(row[2]) ?? 0, agencyZone: row[3]
            )
        }
        return nil
    }

    private static func ends(_ rows: [[String]]) -> Ends? {
        for row in rows where row.first == "od" && row.count >= 9 {
            return Ends(
                boardName: row[1], boardCode: row[2], boardZone: row[3],
                boardMeters: Double(row[4]) ?? 0,
                alightName: row[5], alightCode: row[6], alightZone: row[7],
                alightMeters: Double(row[8]) ?? 0
            )
        }
        return nil
    }

    private static func departures(_ rows: [[String]]) -> [Departure] {
        var out: [Departure] = []
        var pending: (dep: Int, arr: Int, transfers: Int, walk: Int, legs: Int)?
        var rides: [Ride] = []

        func flush() {
            guard let p = pending, !rides.isEmpty else { return }
            out.append(Departure(
                rides: rides, departSeconds: p.dep, arriveSeconds: p.arr,
                transfers: p.transfers, walkSeconds: p.walk
            ))
        }

        for row in rows {
            switch row.first {
            case "dep":
                flush()
                rides = []
                pending = row.count >= 6
                    ? (Int(row[1]) ?? 0, Int(row[2]) ?? 0, Int(row[3]) ?? 0, Int(row[4]) ?? 0,
                       Int(row[5]) ?? 0)
                    : nil
            case "leg":
                guard row.count >= 11 else { continue }
                rides.append(Ride(
                    boardName: row[1], boardCode: row[2], boardZone: row[3],
                    alightName: row[4], alightCode: row[5], alightZone: row[6],
                    routeName: row[7], mode: Int(row[8]) ?? 0,
                    departSeconds: Int(row[9]) ?? 0, arriveSeconds: Int(row[10]) ?? 0
                ))
            default:
                continue
            }
        }
        flush()
        return out
    }
}

extension TransitShard {
    /// Turn an answer into what a card says. Separate from the query so the
    /// wording is testable without a timetable, and so the one place that
    /// decides how a time is phrased is not inside a view.
    ///
    /// The first departure is the one the card leads with; the rest become
    /// "Then 8:15 AM, 10:15 AM", because the useful question after "when does
    /// it leave" is "and when is the next one".
    static func schedule(
        from answer: Answer, credit: String, laterCount: Int = 2, locale: Locale = .current
    ) -> TransitSchedule? {
        guard let first = answer.departures.first,
              let ride = first.rides.first,
              let board = moment(first.departSeconds, answer.stamp),
              let arrive = moment(first.arriveSeconds, answer.stamp)
        else { return nil }

        let endZone = first.rides.last?.alightZone ?? ride.alightZone
        let later: [String] = answer.departures.dropFirst().prefix(laterCount).compactMap {
            moment($0.departSeconds, answer.stamp).map {
                TransitClock.clock($0, zone: ride.boardZone, locale: locale)
            }
        }
        // One ride means one train and its name is worth saying. Several means
        // a change, and naming only the first would mislead.
        let route = first.rides.count == 1
            ? ride.routeName
            : (first.transfers == 1 ? "1 change" : "\(first.transfers) changes")

        return TransitSchedule(
            boardName: ride.boardName,
            alightName: first.rides.last?.alightName ?? ride.alightName,
            routeName: route,
            clockSpan: TransitClock.span(
                board: board, boardZone: ride.boardZone,
                alight: arrive, alightZone: endZone, locale: locale
            ),
            rideSeconds: TimeInterval(first.arriveSeconds - first.departSeconds),
            laterClocks: later,
            credit: credit,
            asOf: TransitClock.publishedNote(answer.stamp.published)
        )
    }
}
