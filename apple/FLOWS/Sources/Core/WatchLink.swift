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
    private var lastManeuverInstruction = ""
    private var lastManeuverDistance = Double.greatestFiniteMagnitude
    /// Everything the Watch should be showing now. The application context
    /// holds ONE dictionary and each update replaces the last, so a guidance
    /// tick queued while the Watch was out of reach replaced the route line
    /// it had not received yet: the Watch showed turns over an empty map.
    /// Every push folds in here and the context always carries all of it; a
    /// live message carries only the change.
    private var shown: [String: Any] = [:]
    /// One-shot cues: a context replayed later must not tap the wrist again.
    private static let cues: Set<String> = ["nearTurn", "arrived"]

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
        // A new trip, not a reroute: nothing of the last one carries over
        // (its "Trip ended", its position and heading).
        if shown["navigating"] as? Bool != true { shown = [:] }
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
        // Re-arm on maneuver CHANGE, not only when the countdown rises above
        // 400 m — downtown turns 200-300 m apart never exceed 400 m, so every
        // turn after the first lost its wrist tap. A new instruction, or the
        // countdown jumping back up (same text, next block), is a new turn.
        if instruction != lastManeuverInstruction
            || distanceToManeuver > lastManeuverDistance + 80 {
            lastManeuverInstruction = instruction
            hapticFiredForManeuver = false
        }
        lastManeuverDistance = distanceToManeuver
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
        // The trip goes whole: its line (kept, it drew the last route under
        // "Trip ended" until the next one), its position and its heading.
        shown = [:]
        push(["navigating": false, "instruction": "Trip ended", "distance": "",
              "routeLat": [Double](), "routeLon": [Double]()],
             urgent: false)
    }

    private func push(_ payload: [String: Any], urgent: Bool) {
        for (key, value) in payload where !Self.cues.contains(key) { shown[key] = value }
        // When the picture was true: the Watch shows a stored one at launch
        // only while it is fresh (WatchApp's activation handler).
        shown["at"] = Date().timeIntervalSince1970
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if urgent, session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
        try? session.updateApplicationContext(shown)
    }

    /// The session came up. Something already sent (a trip started right at
    /// launch was dropped whole) goes to the Watch now. With nothing sent
    /// yet, a trip the last run never ended (the app was quit, crashed or
    /// lost power mid-drive) is ended, so the Watch stops showing its turns.
    fileprivate func sessionActivated() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if !shown.isEmpty {
            try? session.updateApplicationContext(shown)
        } else if session.applicationContext["navigating"] as? Bool == true {
            sendEnded()
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
                             error: Error?) {
        guard state == .activated else { return }
        Task { @MainActor in self.sessionActivated() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
#endif
