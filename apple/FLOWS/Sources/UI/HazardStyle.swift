// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The hazard visual language: each weather/risk type gets a color, an SF
/// Symbol, and a semi-transparent STRIPED fill so overlapping hazard shapes
/// visibly stack into combined risk (solid fills just mush together).
struct HazardKind: Hashable {
    /// The key into RiskAdvice and the Rust classifier's tables; what a
    /// driver reads is `title`.
    let name: String
    let symbol: String
    let color: Color

    /// The plain name on the map key and the tap card: "Earthquake", not
    /// "Seismic".
    var title: String {
        switch name {
        case "Tropical": return "Hurricane"
        case "Seismic": return "Earthquake"
        case "Volcanic": return "Volcano"
        case "Air/Smoke": return "Bad air"
        case "Radiation/UV": return "Strong sun"
        default: return name
        }
    }

    /// The tap card's heading: "Flood risk", but a name that is already a
    /// condition stands alone ("Road closed", not "Road closed risk").
    var cardTitle: String {
        switch name {
        case "Rain chance", "Road closed", "Air/Smoke", "Radiation/UV", "Hazard":
            return title
        default:
            return "\(title) risk"
        }
    }
}

enum HazardStyle {
    // MARK: hazard taxonomy

    static let tornado = HazardKind(name: "Tornado", symbol: "tornado", color: .red)
    static let storm = HazardKind(name: "Storm", symbol: "cloud.bolt.rain.fill", color: .purple)
    static let flood = HazardKind(name: "Flood", symbol: "water.waves", color: .blue)
    /// Rain PROBABILITY (forecast PoP) — a predictor, NOT flooding. Gets its
    /// own icon so a 60% summer thunderstorm chance never wears the flood
    /// costume ("I have many flood warnings between Augusta and Columbia" —
    /// no, those were rain-chance badges drawn with the flood wave).
    static let rain = HazardKind(name: "Rain chance", symbol: "cloud.rain.fill",
                                 color: Color(red: 0.3, green: 0.55, blue: 0.75))
    static let snow = HazardKind(name: "Snow", symbol: "snowflake", color: .cyan)
    static let ice = HazardKind(name: "Ice", symbol: "thermometer.snowflake", color: .teal)
    static let heat = HazardKind(name: "Heat", symbol: "thermometer.sun.fill", color: .orange)
    static let cold = HazardKind(name: "Cold", symbol: "thermometer.low", color: .indigo)
    static let wind = HazardKind(name: "Wind", symbol: "wind", color: Color(red: 0.35, green: 0.5, blue: 0.65))
    static let fire = HazardKind(name: "Fire", symbol: "flame.fill", color: Color(red: 0.85, green: 0.35, blue: 0.1))
    static let hurricane = HazardKind(name: "Tropical", symbol: "hurricane", color: Color(red: 0.6, green: 0.1, blue: 0.4))
    static let fog = HazardKind(name: "Fog", symbol: "cloud.fog.fill", color: .gray)
    /// A dust storm is two hazards at once — zero visibility on the road AND
    /// air you should not breathe — so it gets its own kind instead of the
    /// air-quality icon it used to borrow. The band treats a Dust Storm
    /// Warning as a realized storm (Red-capable); the advice covers both.
    static let dust = HazardKind(name: "Dust storm", symbol: "sun.dust.fill",
                                 color: Color(red: 0.72, green: 0.52, blue: 0.2))
    static let air = HazardKind(name: "Air/Smoke", symbol: "aqi.medium", color: .brown)
    static let radiation = HazardKind(name: "Radiation/UV", symbol: "sun.max.trianglebadge.exclamationmark", color: .yellow)
    static let seismic = HazardKind(name: "Seismic", symbol: "waveform.path.ecg", color: Color(red: 0.5, green: 0.35, blue: 0.2))
    static let volcanic = HazardKind(name: "Volcanic", symbol: "mountain.2.fill", color: Color(red: 0.55, green: 0.15, blue: 0.05))
    static let avalanche = HazardKind(name: "Avalanche", symbol: "snowflake.circle.fill", color: Color(red: 0.2, green: 0.55, blue: 0.8))
    static let tsunami = HazardKind(name: "Tsunami", symbol: "water.waves.and.arrow.up", color: Color(red: 0.0, green: 0.35, blue: 0.55))
    /// A neutral graphite, outside the band palette: this kind names risk no
    /// single hazard explains, and in the Yellow band's own colour its areas
    /// and badges claimed Yellow whatever their band.
    static let generic = HazardKind(name: "Hazard", symbol: "exclamationmark.triangle.fill",
                                    color: Color(red: 0.33, green: 0.35, blue: 0.40))
    static let closure = HazardKind(name: "Road closed", symbol: "road.lanes.curved.right", color: Color(red: 0.8, green: 0.15, blue: 0.15))

    /// The kinds the map key explains: the everyday ones, with rain chance
    /// (the most common badge) and road closures among them.
    static let legendKinds: [HazardKind] = [
        tornado, storm, flood, rain, snow, ice, wind, heat, cold, fire, fog, dust, air, radiation,
        closure,
    ]

    /// Classify an NWS event name ("Tornado Warning", "Winter Storm Watch"…).
    static func kind(forEvent event: String) -> HazardKind {
        // One classifier (rust/flows-core alerts.rs) names the icon; this
        // table only turns the name into a HazardKind.
        kind(named: AlertTables.name(at: Int(flows_alerts_display_kind(event))))
    }

    /// Classify a FLOWS field family key.
    static func kind(forFamily family: String) -> HazardKind {
        kind(named: AlertTables.name(at: Int(flows_alerts_display_kind_for_family(family))))
    }

    /// The HazardKind for a display name the classifier returns. Every name
    /// in `flows_alerts_display_kind_names` must map here; a test checks.
    static func kind(named name: String) -> HazardKind {
        switch name {
        case "Tornado": return tornado
        case "Storm": return storm
        case "Flood": return flood
        case "Snow": return snow
        case "Ice": return ice
        case "Heat": return heat
        case "Cold": return cold
        case "Wind": return wind
        case "Fire": return fire
        case "Tropical": return hurricane
        case "Fog": return fog
        case "Dust storm": return dust
        case "Air/Smoke": return air
        case "Volcanic": return volcanic
        case "Avalanche": return avalanche
        case "Tsunami": return tsunami
        case "Rain chance": return rain
        case "Road closed": return closure
        case "Radiation/UV": return radiation
        case "Seismic": return seismic
        default: return generic
        }
    }

    // MARK: which hazard names an area

    /// The family that should NAME an area — see `HazardRanking`, which
    /// holds the rule itself so it can be tested without SwiftUI.
    static func dominantFamily(_ families: [String: Double],
                               floor: Double = 0.45) -> String? {
        HazardRanking.dominantFamily(families, floor: floor)
    }


    // MARK: risk-level color

    /// The RISK-LEVEL fill color (green→yellow→red) used under the hazard-type
    /// stripes for a ZIP area. The sub-green "clear" band reads as GREEN here —
    /// the area is elevated enough to be drawn, i.e. "low risk" — NOT the
    /// choropleth's clear→blue (which would collide with flood-blue stripes).
    static func riskLevelColor(_ band: RiskBand) -> Color {
        switch band {
        case .clear, .green: return Theme.riskGreen
        case .yellow: return Theme.riskYellow
        case .red: return Theme.riskRed
        }
    }
}

/// A dispatch call heard on the local feed: a small circular pin the size
/// of the vehicle marker, with a slow glow pulsing around its edge in the
/// call's own colour.
///
/// Deliberately quiet. These are transcribed from radio traffic, so they
/// carry less certainty than an official alert and must not shout over one
/// — no banner, no sound, no ETA change. They appear, they fade, they go.
struct ScannerIncidentPin: View {
    let incident: ScannerIncidents.Incident
    @State private var glow = false

    private var color: Color {
        switch incident.kind.colorName {
        case "red": return Theme.riskRed
        case "orange": return .orange
        case "green": return Theme.riskGreen
        case "yellow": return Theme.riskYellow
        case "purple": return .purple
        default: return .blue
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(glow ? 0.75 : 0.15), lineWidth: glow ? 6 : 2)
                .frame(width: 26, height: 26)
                .blur(radius: 3)
            Circle()
                .fill(color)
                .frame(width: 22, height: 22)
            // Fixed: a glyph that grew with the text size spilled out of
            // this fixed disc.
            Image(systemName: incident.kind.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.onDark)
        }
        .overlay(Circle().stroke(.white, lineWidth: 1.5).frame(width: 22, height: 22))
        .shadow(radius: 2)
        // Scoped to THIS view — a repeatForever driven through withAnimation
        // catches every view in the transaction, not just the pulsing one.
        .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true),
                   value: glow)
        .onAppear { glow = true }
        .help("\(incident.kind.title) — heard on the local feed near \(incident.placeText)")
        .accessibilityLabel("\(incident.kind.title) reported near \(incident.placeText)")
    }
}

/// Names read from the Rust classifier once.
enum AlertTables {
    static let displayKindNames: [String] = flows_alerts_display_kind_names().map { $0.as_str().toString() }
    /// The name at a classifier index, or the generic hazard for anything out
    /// of range (which includes the bridge's containment fallback).
    static func name(at index: Int) -> String {
        displayKindNames.indices.contains(index) ? displayKindNames[index] : "Hazard"
    }
}
