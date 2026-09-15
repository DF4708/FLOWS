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
    private static let constants = Array(flows_long_trips_corridor_constants())
    private static let limits = Array(flows_long_trips_corridor_limits())
    static let maxAge: TimeInterval = constants[0]
    /// Within this of the destination counts as arrived.
    static let arrivedMeters: CLLocationDistance = constants[1]
    /// Further than this from EVERY point of the corridor means the stretch
    /// is behind (or beside) the vehicle — it is no longer the road ahead.
    static let passedMeters: CLLocationDistance = constants[2]
    /// Corridors worth keeping at once: the one being driven plus a little
    /// history for the way back.
    static let maxStored = Int(limits[0])

    /// Should this corridor stay on the device?
    static func keep(_ corridor: SavedCorridor,
                     now: Date,
                     position: CLLocationCoordinate2D?) -> Bool {
        // One-week degradation regardless of anything else; with no fix,
        // keep what we have; otherwise drop it once the destination is
        // reached or nothing on the stretch is near the vehicle
        // (rust/flows-core long_trips.rs).
        let geometry = CorridorGeometry([corridor])
        return geometry.call { _, lats, lons, counts in
            flows_long_trips_keep_corridor(
                corridor.savedAt.timeIntervalSinceReferenceDate, lats, lons, Int64(counts[0]),
                now.timeIntervalSinceReferenceDate,
                position?.latitude ?? 0, position?.longitude ?? 0, position != nil)
        }
    }

    /// Prune a stored set: drop what no longer helps, newest first, capped.
    /// A brand-new corridor for the next leg pushes the oldest out.
    static func prune(_ corridors: [SavedCorridor],
                      now: Date,
                      position: CLLocationCoordinate2D?) -> [SavedCorridor] {
        let order = CorridorGeometry(corridors).call { saved, lats, lons, counts in
            Array(flows_long_trips_prune_corridors(
                saved, lats, lons, counts, Int64(corridors.count),
                now.timeIntervalSinceReferenceDate,
                position?.latitude ?? 0, position?.longitude ?? 0, position != nil))
        }
        return order.map { corridors[Int($0)] }
    }

    // MARK: what is worth saving in the first place

    /// Short hops inside one town are not worth storing: signal is good, the
    /// roads are dense, and a driver who loses the app can see where they
    /// are. Corridors earn their place on the open road between places.
    static let minTripMeters: CLLocationDistance = constants[3]
    static func worthSaving(tripMeters: CLLocationDistance) -> Bool {
        flows_long_trips_worth_saving(tripMeters)
    }

    /// A newer corridor covering the same road supersedes an older one — the
    /// next city coming into range replaces the stretch just driven.
    static func supersedes(_ new: SavedCorridor, _ old: SavedCorridor) -> Bool {
        let (a, b) = (new.destination, old.destination)
        return flows_long_trips_supersedes(a?.latitude ?? 0, a?.longitude ?? 0, a != nil,
                                           b?.latitude ?? 0, b?.longitude ?? 0, b != nil)
    }

    /// The stored list once `corridor` is recorded: the corridors it does
    /// not supersede, then it, pruned with no position — so a corridor to
    /// the same destination replaces the old one rather than stacking
    /// (rust/flows-core long_trips.rs).
    static func recorded(_ corridor: SavedCorridor, into corridors: [SavedCorridor],
                         now: Date) -> [SavedCorridor] {
        let ends = corridors.map(\.destination)
        let saved = corridors.isEmpty ? [0] : corridors.map(\.savedAt.timeIntervalSinceReferenceDate)
        let endLats = corridors.isEmpty ? [0] : ends.map { $0?.latitude ?? 0 }
        let endLons = corridors.isEmpty ? [0] : ends.map { $0?.longitude ?? 0 }
        let hasEnd: [UInt8] = corridors.isEmpty ? [0] : ends.map { $0 == nil ? 0 : 1 }
        let end = corridor.destination
        let order = saved.withUnsafeBufferPointer { s in
            endLats.withUnsafeBufferPointer { la in
                endLons.withUnsafeBufferPointer { lo in
                    hasEnd.withUnsafeBufferPointer { h in
                        Array(flows_long_trips_record_corridor(
                            s, la, lo, h, Int64(corridors.count),
                            end?.latitude ?? 0, end?.longitude ?? 0, end != nil,
                            now.timeIntervalSinceReferenceDate))
                    }
                }
            }
        }
        return order.map { Int($0) < corridors.count ? corridors[Int($0)] : corridor }
    }

    /// Thin a route's geometry for storage: one point per `stepMeters`, so a
    /// cross-country route costs kilobytes, not megabytes, and still draws
    /// as a followable line.
    static let decimateStepMeters: CLLocationDistance = constants[4]
    static let decimateLimit = Int(limits[1])
    static func decimate(_ coords: [CLLocationCoordinate2D],
                         stepMeters: CLLocationDistance = decimateStepMeters,
                         limit: Int = decimateLimit) -> [CLLocationCoordinate2D] {
        // Always keeps the true destination, even if the last step was short;
        // too long even decimated, it keeps an even sample across the whole
        // run (rust/flows-core long_trips.rs).
        let lats = coords.isEmpty ? [0] : coords.map(\.latitude)
        let lons = coords.isEmpty ? [0] : coords.map(\.longitude)
        let kept = lats.withUnsafeBufferPointer { la in
            lons.withUnsafeBufferPointer { lo in
                Array(flows_long_trips_decimate(la, lo, Int64(coords.count), stepMeters, Int64(limit)))
            }
        }
        return kept.map { coords[Int($0)] }
    }
}

/// Saved corridors as the bridge reads them: the save times, every decoded
/// point in order and each corridor's point count — with placeholders
/// behind a zero count for an empty list.
struct CorridorGeometry {
    let saved: [Double]
    let lats: [Double]
    let lons: [Double]
    let counts: [Int64]

    init(_ corridors: [SavedCorridor]) {
        let coordinates = corridors.map(\.coordinates)
        let flat = coordinates.flatMap { $0 }
        saved = corridors.isEmpty ? [0] : corridors.map(\.savedAt.timeIntervalSinceReferenceDate)
        lats = flat.isEmpty ? [0] : flat.map(\.latitude)
        lons = flat.isEmpty ? [0] : flat.map(\.longitude)
        counts = corridors.isEmpty ? [0] : coordinates.map { Int64($0.count) }
    }

    func call<R>(_ body: (UnsafeBufferPointer<Double>, UnsafeBufferPointer<Double>,
                          UnsafeBufferPointer<Double>, UnsafeBufferPointer<Int64>) -> R) -> R {
        saved.withUnsafeBufferPointer { s in
            lats.withUnsafeBufferPointer { la in
                lons.withUnsafeBufferPointer { lo in
                    counts.withUnsafeBufferPointer { c in body(s, la, lo, c) }
                }
            }
        }
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
        if let data = SecureBehaviorStore.readMigrating(url),
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
        corridors = CorridorRetention.recorded(corridor, into: corridors, now: now)
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
        let index = geometry().call { _, lats, lons, counts in
            flows_geo_corridor_nearest(lats, lons, counts, Int64(corridors.count),
                                       position.latitude, position.longitude)
        }
        return index >= 0 ? corridors[Int(index)] : nil
    }

    /// Decoded geometry of the stored list, cached by its ids.
    /// `SavedCorridor.coordinates` rebuilds the array from `[[Double]]` on
    /// every access, and the map asks for the nearest corridor on every frame
    /// while offline — a decode of every saved polyline per render. A
    /// corridor is immutable, so the cache goes stale only when the list
    /// itself changes.
    private var geometryIDs: [UUID] = []
    private var geometryCache = CorridorGeometry([])
    private func geometry() -> CorridorGeometry {
        let ids = corridors.map(\.id)
        if ids != geometryIDs {
            geometryIDs = ids
            geometryCache = CorridorGeometry(corridors)
        }
        return geometryCache
    }

    private func persist() {
        _ = SecureBehaviorStore.save(corridors, to: url)
    }

    /// "Erase everything FLOWS has learned" reaches this too.
    ///
    /// It did not used to. This file was written as PLAINTEXT JSON and had no
    /// eraser at all, so a record of where the driver has been outlived the
    /// button that promises the app is "back to knowing nothing" — and
    /// destroying the encryption key did nothing for it, because it was never
    /// encrypted in the first place.
    func erase() {
        corridors = []
        SecureBehaviorStore.shred(url)
    }
}
