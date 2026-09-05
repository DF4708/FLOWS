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
    let name: String
    let symbol: String
    let color: Color
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
    static let air = HazardKind(name: "Air/Smoke", symbol: "aqi.medium", color: .brown)
    static let radiation = HazardKind(name: "Radiation/UV", symbol: "sun.max.trianglebadge.exclamationmark", color: .yellow)
    static let seismic = HazardKind(name: "Seismic", symbol: "waveform.path.ecg", color: Color(red: 0.5, green: 0.35, blue: 0.2))
    static let volcanic = HazardKind(name: "Volcanic", symbol: "mountain.2.fill", color: Color(red: 0.55, green: 0.15, blue: 0.05))
    static let avalanche = HazardKind(name: "Avalanche", symbol: "snowflake.circle.fill", color: Color(red: 0.2, green: 0.55, blue: 0.8))
    static let tsunami = HazardKind(name: "Tsunami", symbol: "water.waves.and.arrow.up", color: Color(red: 0.0, green: 0.35, blue: 0.55))
    static let generic = HazardKind(name: "Hazard", symbol: "exclamationmark.triangle.fill", color: Theme.riskYellow)
    static let closure = HazardKind(name: "Road closed", symbol: "road.lanes.curved.right", color: Color(red: 0.8, green: 0.15, blue: 0.15))

    static let legendKinds: [HazardKind] = [
        tornado, storm, flood, snow, ice, wind, heat, cold, fire, fog, air, radiation,
    ]

    /// Classify an NWS event name ("Tornado Warning", "Winter Storm Watch"…).
    static func kind(forEvent event: String) -> HazardKind {
        let e = event.lowercased()
        if e.contains("tornado") { return tornado }
        if e.contains("hurricane") || e.contains("tropical") { return hurricane }
        // Specific products BEFORE the generic words that would swallow
        // them: a Storm Surge Warning is a tropical-system flood, not a
        // thunderstorm; a Dust Storm Warning is airborne dust, not a storm;
        // an Extreme Wind Warning is hurricane-force wind, not a breeze.
        if e.contains("surge") { return hurricane }
        if e.contains("dust") { return air }
        if e.contains("extreme wind") { return hurricane }
        if e.contains("flood") { return flood }
        if e.contains("blizzard") || e.contains("snow") || e.contains("winter") { return snow }
        if e.contains("ice") || e.contains("freezing") || e.contains("frost") { return ice }
        if e.contains("thunder") || e.contains("severe") || e.contains("storm") { return storm }
        // A Special Weather Statement is NWS's short-fused sub-severe
        // convective product — name it a storm, not a mystery triangle.
        if e.contains("special weather") { return storm }
        if e.contains("heat") { return heat }
        if e.contains("chill") || e.contains("cold") { return cold }
        if e.contains("wind") { return wind }
        if e.contains("fire") || e.contains("red flag") { return fire }
        if e.contains("fog") { return fog }
        if e.contains("smoke") || e.contains("air quality") || e.contains("dust") { return air }
        if e.contains("volcan") || e.contains("ashfall") || e.contains("ash advisory") { return volcanic }
        if e.contains("avalanche") { return avalanche }
        if e.contains("tsunami") { return tsunami }
        return generic
    }

    /// Classify a FLOWS field family key.
    static func kind(forFamily family: String) -> HazardKind {
        switch family {
        case "winter": return snow
        case "qpf_flood": return flood
        case "convective": return storm
        case "fire": return fire
        case "heat": return heat
        case "cold": return cold
        case "wind": return wind
        case "air": return air
        case "radiation": return radiation
        case "seismic": return seismic
        case "tropical": return hurricane
        case "volcanic": return volcanic
        case "avalanche": return avalanche
        case "tsunami": return tsunami
        case "closure": return closure
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
