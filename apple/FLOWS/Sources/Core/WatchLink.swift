// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation
import MapKit
#if os(iOS)
import WatchConnectivity
#endif

/// iPhone → Apple Watch guidance stream: route geometry once per leg, then
/// throttled position/instruction updates, plus the near-turn haptic flag
/// (fired once per maneuver as the countdown crosses ~250 m). Third-party
/// watch brands have no generic phone API — this path is Apple Watch;
/// others would need their vendor SDKs.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    #if os(iOS)
    static let isAvailable = true
    private var lastSent = Date.distantPast
    private var hapticFiredForManeuver = false

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// New leg: ship the (simplified) route geometry.
    func sendRoute(_ route: PlannedRoute) {
        let pts = RouteService.samplePoints(of: route.route.polyline, everyMeters: 400)
        let capped = pts.count > 120
            ? stride(from: 0, to: pts.count, by: pts.count / 120 + 1).map { pts[$0] }
            : pts
        push([
            "navigating": true,
            "routeLat": capped.map(\.latitude),
            "routeLon": capped.map(\.longitude),
        ], urgent: true)
        hapticFiredForManeuver = false
    }

    /// Guidance tick (throttled to ~1/2 s): position + instruction +
    /// distance countdown; the haptic flag rides the crossing into 250 m.
    func sendGuidance(instruction: String, distanceText: String,
                      distanceToManeuver: Double,
                      coordinate: CLLocationCoordinate2D?, heading: Double) {
        var payload: [String: Any] = [
            "navigating": true,
            "instruction": instruction,
            "distance": distanceText,
            "heading": heading,
        ]
        if let c = coordinate {
            payload["lat"] = c.latitude
            payload["lon"] = c.longitude
        }
        if distanceToManeuver < 250, !hapticFiredForManeuver {
            payload["nearTurn"] = true          // the wrist tap
            hapticFiredForManeuver = true
        } else if distanceToManeuver > 400 {
            hapticFiredForManeuver = false      // re-arm for the next turn
        }
        guard Date().timeIntervalSince(lastSent) > 2 || payload["nearTurn"] != nil else { return }
        lastSent = Date()
        push(payload, urgent: payload["nearTurn"] != nil)
    }

    func sendArrived() {
        push(["navigating": false, "arrived": true, "instruction": "Arrived",
              "distance": ""], urgent: true)
    }

    func sendEnded() {
        push(["navigating": false, "instruction": "Trip ended", "distance": ""],
             urgent: false)
    }

    private func push(_ payload: [String: Any], urgent: Bool) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if urgent, session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            try? session.updateApplicationContext(payload)
        }
    }
    #else
    static let isAvailable = false
    func sendRoute(_ route: PlannedRoute) {}
    func sendGuidance(instruction: String, distanceText: String,
                      distanceToManeuver: Double,
                      coordinate: CLLocationCoordinate2D?, heading: Double) {}
    func sendArrived() {}
    func sendEnded() {}
    #endif
}

#if os(iOS)
extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
#endif
