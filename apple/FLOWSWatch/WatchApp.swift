// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import MapKit
import SwiftUI
import WatchConnectivity
import WatchKit

/// FLOWS on the wrist — Apple-Maps-style watch navigation: a small live map
/// with the route line, the next turn + distance countdown up top, and a
/// WRIST TAP as you near each maneuver. The paired iPhone streams guidance
/// over WatchConnectivity; the watch renders and vibrates.
@main
struct FLOWSWatchApp: App {
    @StateObject private var link = WatchGuidance.shared

    var body: some Scene {
        WindowGroup {
            WatchNavView()
                .environmentObject(link)
        }
    }
}

/// Receives guidance from the phone.
final class WatchGuidance: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchGuidance()

    @Published var instruction = "Waiting for FLOWS on iPhone…"
    @Published var distanceText = ""
    @Published var vehicle: CLLocationCoordinate2D?
    @Published var heading: Double = 0
    @Published var routeCoords: [CLLocationCoordinate2D] = []
    @Published var navigating = false

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// A picture the phone stamped more than 15 minutes ago is an old one,
    /// not a live trip. A drive refreshes the stamp every couple of seconds,
    /// so only a trip the phone never ended (quit, crash, dead battery)
    /// leaves one — and the system keeps it, and hands it over late.
    private static func isStale(_ context: [String: Any]) -> Bool {
        guard let at = context["at"] as? Double else { return false }
        return Date().timeIntervalSince1970 - at >= 15 * 60
    }

    /// A context that arrived while this app was closed waits here: show it
    /// at once instead of "Waiting for FLOWS" until the next change, while
    /// it is fresh. One without a stamp (an older phone build) is never
    /// replayed.
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        let waiting = session.receivedApplicationContext
        guard state == .activated, waiting["at"] is Double, !Self.isStale(waiting) else { return }
        apply(waiting)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        apply(message)
    }

    /// A context delivered late (the app was closed or asleep when it came)
    /// is checked the same way. An old one clears the face rather than being
    /// skipped: the face may still hold an even older trip.
    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard !Self.isStale(context) else {
            DispatchQueue.main.async {
                self.navigating = false
                self.instruction = "Waiting for FLOWS on iPhone…"
                self.distanceText = ""
                self.routeCoords = []
                self.vehicle = nil
            }
            return
        }
        apply(context)
    }

    private func apply(_ payload: [String: Any]) {
        DispatchQueue.main.async {
            self.navigating = payload["navigating"] as? Bool ?? self.navigating
            if let text = payload["instruction"] as? String { self.instruction = text }
            if let d = payload["distance"] as? String { self.distanceText = d }
            if let lat = payload["lat"] as? Double, let lon = payload["lon"] as? Double {
                self.vehicle = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            if let h = payload["heading"] as? Double { self.heading = h }
            if let flat = payload["routeLat"] as? [Double],
               let flon = payload["routeLon"] as? [Double], flat.count == flon.count {
                self.routeCoords = zip(flat, flon).map {
                    CLLocationCoordinate2D(latitude: $0, longitude: $1)
                }
            }
            // The wrist tap: fires when the phone says a turn is near.
            if payload["nearTurn"] as? Bool == true {
                WKInterfaceDevice.current().play(.directionUp)
            }
            if payload["arrived"] as? Bool == true {
                WKInterfaceDevice.current().play(.success)
            }
        }
    }
}

struct WatchNavView: View {
    @EnvironmentObject private var link: WatchGuidance
    @State private var camera: MapCameraPosition = .automatic
    /// How much of the face the instruction card covers, measured, so the
    /// camera keeps the vehicle in the middle of the map left below it.
    @State private var cardCover: Double = 0

    var body: some View {
        GeometryReader { face in
            ZStack(alignment: .top) {
                Map(position: $camera) {
                    if link.routeCoords.count > 1 {
                        MapPolyline(coordinates: link.routeCoords)
                            .stroke(.blue, lineWidth: 4)
                    }
                    if let v = link.vehicle {
                        Annotation("", coordinate: v) {
                            Image(systemName: "location.north.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white, .blue)
                                .rotationEffect(.degrees(link.heading))
                        }
                    }
                }
                .ignoresSafeArea()
                // Next turn + countdown, Apple-Maps-on-watch style.
                VStack(spacing: 1) {
                    if !link.distanceText.isEmpty {
                        Text(link.distanceText)
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                    }
                    Text(link.instruction)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                // Inset from the BEZEL, not just from the clock. A watch face is
                // heavily rounded, so a card run edge-to-edge has its corners
                // clipped by the glass and the text sits right against it. The
                // top padding keeps it clear of the system clock.
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .background(GeometryReader { card in
                    Color.clear
                        .onAppear { cardCover = Self.cover(card: card, face: face) }
                        .onChange(of: card.size.height) { _, _ in
                            cardCover = Self.cover(card: card, face: face)
                        }
                })
            }
        }
        .onChange(of: link.vehicle?.latitude) { _, _ in
            guard let v = link.vehicle else { return }
            withAnimation(.easeInOut(duration: 0.6)) {
                camera = .camera(MapCamera(
                    centerCoordinate: Self.aimPoint(vehicle: v, headingDegrees: link.heading,
                                                    distanceMeters: 800, cover: cardCover),
                    distance: 800, heading: link.heading, pitch: 0))
            }
        }
    }

    /// The share of the whole face, safe areas included, above the card's
    /// bottom edge.
    private static func cover(card: GeometryProxy, face: GeometryProxy) -> Double {
        let full = face.size.height + face.safeAreaInsets.top + face.safeAreaInsets.bottom
        guard full > 0 else { return 0 }
        return Double(min(max(card.frame(in: .global).maxY / full, 0), 0.9))
    }

    /// The camera centre that puts the vehicle in the middle of the map below
    /// the card: ahead of it along the heading by half the covered share of
    /// the view. The map's height tracks the camera distance, the same
    /// approximation the phone's chase camera makes.
    static func aimPoint(vehicle: CLLocationCoordinate2D, headingDegrees: Double,
                         distanceMeters: Double, cover: Double) -> CLLocationCoordinate2D {
        let ahead = distanceMeters * cover / 2
        let radians = headingDegrees * .pi / 180
        let metersPerDegree = 111_320.0
        let latitude = vehicle.latitude + ahead * cos(radians) / metersPerDegree
        let longitude = vehicle.longitude + ahead * sin(radians)
            / (metersPerDegree * max(cos(vehicle.latitude * .pi / 180), 0.01))
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
