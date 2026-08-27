// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// Saved road corridors for the stretches where help is furthest away: the
/// open road BETWEEN towns, outside city limits. Apple's router needs the
/// internet; a corridor already on disk does not — so a driver who loses
/// signal, or force-quits and reopens the app in the middle of nowhere, can
/// still see the way onward to the destination and the way back home.
///
/// This is the planned-route companion to BreadcrumbTrail: crumbs are where
/// you HAVE been, a corridor is where the road GOES.
struct SavedCorridor: Codable, Identifiable, Equatable {
    let id: UUID
    /// When this corridor was stored — starts the one-week clock.
    let savedAt: Date
    /// Where this corridor leads, in the driver's words.
    let destinationName: String
    /// Decimated route geometry (lat, lon pairs), start → destination.
    let points: [[Double]]

    var coordinates: [CLLocationCoordinate2D] {
        points.compactMap {
            $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil
        }
    }

    /// The far end — what the driver is heading for.
    var destination: CLLocationCoordinate2D? { coordinates.last }
}

/// When a saved corridor has earned its keep and when it should go. Pure,
/// pinned by FLOWSTests.
///
/// A corridor is dropped as soon as it can no longer help: the destination
/// is reached, the whole stretch is behind the vehicle, a newer corridor has
/// taken its place, or it has simply gone stale. Nothing lives on the device
/// forever "just in case".
enum CorridorRetention {
    /// Saved routing degrades after a week even if nothing else clears it —
    /// a corridor from last month is a stale map, not a lifeline.
    static let maxAge: TimeInterval = 7 * 24 * 3600
    /// Within this of the destination counts as arrived.
    static let arrivedMeters: CLLocationDistance = 1_500
    /// Further than this from EVERY point of the corridor means the stretch
    /// is behind (or beside) the vehicle — it is no longer the road ahead.
    static let passedMeters: CLLocationDistance = 30_000
    /// Corridors worth keeping at once: the one being driven plus a little
    /// history for the way back.
    static let maxStored = 3

    /// Should this corridor stay on the device?
    static func keep(_ corridor: SavedCorridor,
                     now: Date,
                     position: CLLocationCoordinate2D?) -> Bool {
        // One-week degradation, regardless of anything else.
        guard now.timeIntervalSince(corridor.savedAt) < maxAge else { return false }
        guard let position else { return true }   // no fix: keep what we have
        let coords = corridor.coordinates
        guard !coords.isEmpty else { return false }
        // Destination reached — the corridor did its job.
        if let end = coords.last, POIRanking.meters(end, position) <= arrivedMeters {
            return false
        }
        // The whole stretch is far behind: nothing on it is near the vehicle.
        let nearest = coords.map { POIRanking.meters($0, position) }.min() ?? .infinity
        return nearest <= passedMeters
    }

    /// Prune a stored set: drop what no longer helps, newest first, capped.
    /// A brand-new corridor for the next leg pushes the oldest out.
    static func prune(_ corridors: [SavedCorridor],
                      now: Date,
                      position: CLLocationCoordinate2D?) -> [SavedCorridor] {
        corridors
            .filter { keep($0, now: now, position: position) }
            .sorted { $0.savedAt > $1.savedAt }
            .prefix(maxStored)
            .map { $0 }
    }

    // MARK: what is worth saving in the first place

    /// Short hops inside one town are not worth storing: signal is good, the
    /// roads are dense, and a driver who loses the app can see where they
    /// are. Corridors earn their place on the open road between places.
    static let minTripMeters: CLLocationDistance = 25_000
    /// How far from a town's center still counts as "in town" — the part of
    /// a trip we do NOT need to carry offline.
    static let cityRadiusMeters: CLLocationDistance = 12_000

    static func worthSaving(tripMeters: CLLocationDistance) -> Bool {
        tripMeters >= minTripMeters
    }

    /// A newer corridor covering the same road supersedes an older one — the
    /// next city coming into range replaces the stretch just driven.
    static func supersedes(_ new: SavedCorridor, _ old: SavedCorridor) -> Bool {
        guard let newEnd = new.destination, let oldEnd = old.destination else {
            return false
        }
        return POIRanking.meters(newEnd, oldEnd) <= arrivedMeters
    }

    /// Thin a route's geometry for storage: one point per `stepMeters`, so a
    /// cross-country route costs kilobytes, not megabytes, and still draws
    /// as a followable line.
    static func decimate(_ coords: [CLLocationCoordinate2D],
                         stepMeters: CLLocationDistance = 400,
                         limit: Int = 1_200) -> [CLLocationCoordinate2D] {
        guard let first = coords.first else { return [] }
        var out = [first]
        for c in coords.dropFirst() {
            if POIRanking.meters(out[out.count - 1], c) >= stepMeters { out.append(c) }
        }
        // Always keep the true destination, even if the last step was short.
        if let last = coords.last, out.last.map({ POIRanking.meters($0, last) > 1 }) == true {
            out.append(last)
        }
        guard out.count > limit else { return out }
        // Too long even decimated: keep an even sample across the whole run.
        let stride = Double(out.count - 1) / Double(limit - 1)
        return (0..<limit).map { out[Int((Double($0) * stride).rounded())] }
    }
}

/// Disk-backed set of saved corridors.
@MainActor
final class OfflineCorridorStore: ObservableObject {
    @Published private(set) var corridors: [SavedCorridor] = []

    private let url: URL

    init() {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = dir.appendingPathComponent("flows_corridors.json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([SavedCorridor].self, from: data) {
            // Age out on load too — a phone left in a drawer for a month
            // should come back with nothing stale on it.
            corridors = CorridorRetention.prune(saved, now: Date(), position: nil)
        }
    }

    /// Store the road ahead for a trip worth carrying offline. A corridor to
    /// the same destination replaces the old one rather than stacking.
    func record(coordinates: [CLLocationCoordinate2D],
                destinationName: String,
                tripMeters: CLLocationDistance,
                now: Date = Date()) {
        guard CorridorRetention.worthSaving(tripMeters: tripMeters) else { return }
        let thinned = CorridorRetention.decimate(coordinates)
        guard thinned.count >= 2 else { return }
        let corridor = SavedCorridor(
            id: UUID(), savedAt: now, destinationName: destinationName,
            points: thinned.map { [$0.latitude, $0.longitude] })
        var next = corridors.filter { !CorridorRetention.supersedes(corridor, $0) }
        next.append(corridor)
        corridors = CorridorRetention.prune(next, now: now, position: nil)
        persist()
    }

    /// Drop what no longer helps (arrived, passed, stale). Called as the trip
    /// moves and when it ends.
    func prune(position: CLLocationCoordinate2D?, now: Date = Date()) {
        let next = CorridorRetention.prune(corridors, now: now, position: position)
        guard next.count != corridors.count else { return }
        corridors = next
        persist()
    }

    /// The corridor most useful from here: the one whose road passes nearest.
    func nearest(to position: CLLocationCoordinate2D) -> SavedCorridor? {
        corridors.min { a, b in
            let da = a.coordinates.map { POIRanking.meters($0, position) }.min() ?? .infinity
            let db = b.coordinates.map { POIRanking.meters($0, position) }.min() ?? .infinity
            return da < db
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(corridors) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
