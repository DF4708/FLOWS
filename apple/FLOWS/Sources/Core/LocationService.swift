// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// GPS + speed source. Two cadences, matching the app's two modes:
///   planning   — reduced accuracy is fine, occasional fixes (cheap);
///   navigating — best accuracy, every fix delivered, because turn-by-turn is
///                time-sensitive and locally relevant.
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var latest: CLLocation?
    @Published private(set) var authorized = false

    /// Speed in m/s, clamped to >= 0 (CoreLocation reports -1 when unknown).
    var speed: Double { max(latest?.speed ?? 0, 0) }
    var coordinate: CLLocationCoordinate2D? { latest?.coordinate }
    var course: Double { latest?.course ?? 0 }

    private let manager = CLLocationManager()

    // No permission request at init: the welcome card explains ALL of
    // FLOWS's permissions in one message first, and AppModel triggers the
    // location prompt when the driver taps Get started (immediately on
    // later launches). A fresh install must never open with a stack of
    // unexplained system dialogs.
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestAuthorization() {
        #if os(macOS)
        manager.requestAlwaysAuthorization()
        #else
        manager.requestWhenInUseAuthorization()
        #endif
    }

    /// Planning cadence: coarse, battery-friendly.
    func beginPlanningUpdates() {
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
        manager.startUpdatingLocation()
    }

    /// Navigation cadence: every fix, best-for-navigation accuracy — the map
    /// camera and instruction state advance on each one.
    func beginNavigationUpdates() {
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = true
        manager.activityType = .automotiveNavigation
        #endif
        manager.startUpdatingLocation()
    }

    func endNavigationUpdates() {
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = false
        #endif
        beginPlanningUpdates()
    }

    // MARK: CLLocationManagerDelegate (delegate calls arrive on main queue by
    // default for a manager created on the main thread)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.latest = loc }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            #if os(macOS)
            self.authorized = status == .authorizedAlways
            #else
            self.authorized = status == .authorizedWhenInUse || status == .authorizedAlways
            #endif
            if self.authorized { self.beginPlanningUpdates() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Non-fatal: keep last fix; UI shows planning UI without user dot.
    }
}
