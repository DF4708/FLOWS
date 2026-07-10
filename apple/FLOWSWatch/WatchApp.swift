// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
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

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {}

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        apply(message)
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
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

    var body: some View {
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
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 2)
        }
        .onChange(of: link.vehicle?.latitude) { _, _ in
            guard let v = link.vehicle else { return }
            withAnimation(.easeInOut(duration: 0.6)) {
                camera = .camera(MapCamera(centerCoordinate: v, distance: 800,
                                           heading: link.heading, pitch: 0))
            }
        }
    }
}
