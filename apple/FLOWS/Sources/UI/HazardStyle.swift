// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
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
        if e.contains("flood") { return flood }
        if e.contains("blizzard") || e.contains("snow") || e.contains("winter") { return snow }
        if e.contains("ice") || e.contains("freezing") || e.contains("frost") { return ice }
        if e.contains("thunder") || e.contains("severe") || e.contains("storm") { return storm }
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

    // MARK: striped fill

    /// Tiled diagonal-stripe ShapeStyle: transparent + colored stripes, so
    /// overlapping hazard polygons visually combine. Cached per kind.
    static func stripes(_ kind: HazardKind) -> ImagePaint {
        ImagePaint(image: stripeTile(for: kind), scale: 1)
    }

    private static var tileCache: [HazardKind: Image] = [:]

    private static func stripeTile(for kind: HazardKind) -> Image {
        if let cached = tileCache[kind] { return cached }
        let size = CGSize(width: 14, height: 14)
        #if os(macOS)
        let ns = NSImage(size: size, flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            NSColor(kind.color).withAlphaComponent(0.5).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 4
            // Two diagonals give a seamless 45° stripe tile.
            path.move(to: CGPoint(x: -4, y: 10)); path.line(to: CGPoint(x: 10, y: -4))
            path.move(to: CGPoint(x: 3, y: 17));  path.line(to: CGPoint(x: 17, y: 3))
            path.stroke()
            return true
        }
        let image = Image(nsImage: ns)
        #else
        let renderer = UIGraphicsImageRenderer(size: size)
        let ui = renderer.image { ctx in
            let c = ctx.cgContext
            c.setStrokeColor(UIColor(kind.color).withAlphaComponent(0.5).cgColor)
            c.setLineWidth(4)
            c.move(to: CGPoint(x: -4, y: 10)); c.addLine(to: CGPoint(x: 10, y: -4))
            c.move(to: CGPoint(x: 3, y: 17));  c.addLine(to: CGPoint(x: 17, y: 3))
            c.strokePath()
        }
        let image = Image(uiImage: ui)
        #endif
        tileCache[kind] = image
        return image
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
