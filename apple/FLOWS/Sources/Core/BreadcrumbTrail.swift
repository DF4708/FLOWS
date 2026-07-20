// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation
import Network

/// The offline lifeline: a continuous GPS breadcrumb trail recorded whenever
/// the app runs, persisted to disk, and drawable with ZERO network — so a
/// driver (or hiker) who loses service in the woods can always retrace the way
/// they came. Apple's router needs the internet; your own footprints don't.
@MainActor
final class BreadcrumbTrail: ObservableObject {
    /// Recorded positions, oldest → newest, decimated to ≥ `minStepMeters`.
    @Published private(set) var points: [CLLocationCoordinate2D] = []
    /// True when the system reports no usable network path — surfaces the
    /// offline banner + the "Find my way back" affordance.
    @Published private(set) var isOffline = false
    /// The driver toggled the trail onto the map.
    @Published var showTrail = false

    nonisolated static let minStepMeters: CLLocationDistance = 25
    static let maxPoints = 6_000            // ≈150 km of 25 m steps
    private static let saveEvery = 40       // persist once per km, not per fix

    private let url: URL
    private var sinceSave = 0
    private let monitor = NWPathMonitor()

    init() {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = dir.appendingPathComponent("flows_breadcrumbs.json")
        if let data = try? Data(contentsOf: url),
           let raw = try? JSONDecoder().decode([[Double]].self, from: data) {
            points = raw.compactMap {
                $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil
            }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isOffline = path.status != .satisfied }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    /// Record a fix: kept only when it moves ≥ minStep from the last crumb
    /// (pure decision in `shouldRecord` for testability).
    func record(_ c: CLLocationCoordinate2D) {
        guard Self.shouldRecord(c, after: points.last) else { return }
        points.append(c)
        if points.count > Self.maxPoints {
            points.removeFirst(points.count - Self.maxPoints)
        }
        sinceSave += 1
        if sinceSave >= Self.saveEvery { persist() }
    }

    nonisolated static func shouldRecord(
        _ c: CLLocationCoordinate2D, after last: CLLocationCoordinate2D?) -> Bool {
        guard c.latitude.isFinite, c.longitude.isFinite,
              abs(c.latitude) > 0.0001 || abs(c.longitude) > 0.0001 else { return false }
        guard let last else { return true }
        return POIRanking.meters(last, c) >= minStepMeters
    }

    /// The way back: the recorded trail NEWEST-FIRST from the current position
    /// — follow the line to walk out the way you came. Total meters included.
    func wayBack() -> (path: [CLLocationCoordinate2D], meters: CLLocationDistance) {
        let reversed = Array(points.reversed())
        var meters: CLLocationDistance = 0
        for i in 1..<max(reversed.count, 1) {
            meters += POIRanking.meters(reversed[i - 1], reversed[i])
        }
        return (reversed, meters)
    }

    private func persist() {
        sinceSave = 0
        let raw = points.map { [$0.latitude, $0.longitude] }
        if let data = try? JSONEncoder().encode(raw) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
