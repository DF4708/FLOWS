// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import SwiftUI

/// Shared design language across macOS / iOS / iPadOS — tokens carried over
/// from the retired web app's styles.css (this file is now their sole home):
/// pill controls (border-radius 999px), near-black CTA (#111), floating white
/// cards at 95% opacity, and the FLOWS risk palette.
enum Theme {
    /// A color that changes with the light. One definition, two values —
    /// the platform resolves whichever the current appearance calls for, so
    /// every card and chip using these tokens turns over at dusk without
    /// each view having to ask what time it is.
    static func adaptive(light: Color, dark: Color) -> Color {
        #if os(iOS) || os(tvOS)
        return Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(dark) : UIColor(light) })
        #elseif os(macOS)
        return Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark) : NSColor(light)
        })
        #else
        return light
        #endif
    }

    // styles.css: .search-button / .route-button { background:#111 }.
    // After dark the near-black pill would vanish into a near-black card,
    // so it flips to near-white with dark lettering — same weight on the
    // screen, opposite ink.
    static let cta = adaptive(
        light: Color(red: 0x11 / 255.0, green: 0x11 / 255.0, blue: 0x11 / 255.0),
        dark: Color(red: 0xEC / 255.0, green: 0xED / 255.0, blue: 0xEF / 255.0))
    /// Lettering ON a CTA pill — the inverse of whatever the pill is.
    static let onCTA = adaptive(light: .white,
                                dark: Color(red: 0x0B / 255.0, green: 0x0E / 255.0,
                                            blue: 0x12 / 255.0))
    // styles.css: rgba(255,255,255,0.95) floating cards. At night the same
    // card is near-black at the same opacity, so the map still reads through
    // it and the text on it is light-on-dark rather than a white slab in a
    // dark car.
    static let cardBackground = adaptive(
        light: Color.white.opacity(0.95),
        dark: Color(red: 0x14 / 255.0, green: 0x17 / 255.0,
                    blue: 0x1C / 255.0).opacity(0.95))
    static let cardShadow = adaptive(light: Color.black.opacity(0.14),
                                     dark: Color.black.opacity(0.5))

    /// The faint wash behind a chip, a row, or a bar track. It must be a
    /// TINT OF THE OPPOSITE ink: black at 6% is invisible on a dark card,
    /// which is how a dark mode ends up as a field of unmarked rectangles.
    static func fill(_ level: Double) -> Color {
        adaptive(light: Color.black.opacity(level),
                 dark: Color.white.opacity(min(level * 2.2, 0.5)))
    }

    /// A surface that is deliberately dark in BOTH appearances — the
    /// maneuver banner, map badges — and the lettering that goes on it.
    static let onDark = Color.white
    /// …and its opposite: lettering on a surface that stays WHITE in both
    /// appearances, such as a pill sitting on a saturated alert banner.
    /// Fixed on purpose — an adaptive ink here turns white-on-white at dusk.
    static let onLight = Color(red: 0x11 / 255.0, green: 0x11 / 255.0,
                               blue: 0x11 / 255.0)
    // R/risk_constants.R + rust risk.rs palette
    static let riskGreen = Color(red: 0x2e / 255.0, green: 0xcc / 255.0, blue: 0x71 / 255.0)
    static let riskYellow = Color(red: 0xf1 / 255.0, green: 0xc4 / 255.0, blue: 0x0f / 255.0)
    static let riskRed = Color(red: 0xdc / 255.0, green: 0x35 / 255.0, blue: 0x45 / 255.0)
    // ui.R theme-color meta
    static let chrome = Color(red: 0x0b / 255.0, green: 0x0e / 255.0, blue: 0x12 / 255.0)

    static let cardRadius: CGFloat = 16
    static let tapMinimum: CGFloat = 44   // Apple HIG minimum hit target
    /// The golden ratio — every window-proportional size below derives from
    /// it, so chrome keeps the same visual proportions on any screen, shape,
    /// or orientation.
    static let phi: CGFloat = 1.61803398875
}

/// Window-proportional metrics: each token is a golden-ratio step of the
/// LIVE window size (set by ContentView from its geometry), so panels,
/// icons, and clearances are ratios of the screen — they scale to any
/// size, shape, and orientation instead of being tuned to one device.
/// Interactive icon sizes clamp to Apple's hit-target floor (and a sane
/// ceiling) so accessibility never loses to proportion.
struct GoldenScale: Equatable {
    var size = CGSize(width: 393, height: 852)   // phone-portrait default

    var short: CGFloat { min(size.width, size.height) }
    var long: CGFloat { max(size.width, size.height) }
    /// `n` golden steps down from the short side (÷φ per step).
    func step(_ n: Int) -> CGFloat { GoldenScale.stepped(short, n) }

    private static func stepped(_ base: CGFloat, _ n: Int) -> CGFloat {
        base / pow(Theme.phi, CGFloat(n))
    }

    /// Edge padding (short/φ⁸ ≈ 8 pt on a phone, ≈ 17 pt on a desktop map).
    var pad: CGFloat { step(8) }
    /// Card interior padding (short/φ⁷ ≈ 13 pt on a phone).
    var padCard: CGFloat { step(7) }
    /// Clearance under the top chrome — gear, pills (short/φ⁴ ≈ 57 pt).
    var topClear: CGFloat { step(4) }
    /// Clearance above the bottom bars (short/φ³ ≈ 93 pt).
    var bottomClear: CGFloat { step(3) }
    /// Circular chrome buttons (gear, radio, towing, re-center, tray icons).
    var iconCircle: CGFloat { min(max(step(5), 36), 56) }
    /// Small round toggles (rail/bus/plane on the Routes card).
    var iconSmall: CGFloat { min(max(step(6), 26), 40) }
    /// The legend block (short/φ² — reads at a glance, never dominates).
    var legendWidth: CGFloat { step(2) }
    /// Side panel on regular layouts (window width/φ²).
    var sidePanel: CGFloat { size.width / (Theme.phi * Theme.phi) }
    /// Narrow side column on regular layouts (window width/φ³).
    var sideColumn: CGFloat { size.width / pow(Theme.phi, 3) }
    /// Floating-card width cap on regular layouts (long side/φ).
    var cardMax: CGFloat { long / Theme.phi }
    /// Tallest a stacked panel may grow (height/φ²) — the map keeps the
    /// majority of the window.
    var panelMaxHeight: CGFloat { size.height / (Theme.phi * Theme.phi) }
    /// The choices panel's share of the window: enough for the trip pill,
    /// the filter grid and a whole route card, and no more — the map below
    /// still has to show the route being chosen. Cards snap to their own
    /// edges inside it, so the panel never slices one in half.
    var choicesPanelHeight: CGFloat { min(max(size.height * 0.46, 300), 520) }
    /// The same share as a FRACTION, for framing the route clear of it.
    var choicesPanelFraction: Double {
        size.height > 0 ? Double(choicesPanelHeight / size.height) : 0.46
    }
    /// List scroll cap inside HUD cards (height/φ³).
    var listMaxHeight: CGFloat { size.height / pow(Theme.phi, 3) }
}

private struct GoldenScaleKey: EnvironmentKey {
    static let defaultValue = GoldenScale()
}

extension EnvironmentValues {
    var golden: GoldenScale {
        get { self[GoldenScaleKey.self] }
        set { self[GoldenScaleKey.self] = newValue }
    }
}

/// The web app's pill CTA (Search / Plan route buttons) as a ButtonStyle.
struct PillCTAStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .frame(maxWidth: .infinity, minHeight: Theme.tapMinimum)
            .background(Theme.cta.opacity(configuration.isPressed ? 0.75 : 1.0))
            .foregroundStyle(Theme.onCTA)
            .clipShape(Capsule())
    }
}

/// Floating card container matching .route-card / .notice-card.
struct FloatingCard: ViewModifier {
    @Environment(\.golden) private var golden

    func body(content: Content) -> some View {
        content
            .padding(golden.padCard)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .shadow(color: Theme.cardShadow, radius: 14, y: 5)
    }
}

extension View {
    /// Carry the app's day/night appearance into a SHEET.
    ///
    /// `preferredColorScheme` set on the content that presents a sheet does
    /// not reach the sheet: it is presented into its own environment root.
    /// Without this, settings and the vehicle editor open bright white at
    /// two in the morning while everything behind them is dark.
    func presentationColorScheme(_ scheme: ColorScheme?) -> some View {
        preferredColorScheme(scheme)
    }

    func floatingCard() -> some View { modifier(FloatingCard()) }
    /// A menu that minimizes instead of vanishing: its X button tucks it
    /// into a small round icon at the window's top right (CollapsedPanelTray
    /// restores it). This modifier just hides the menu while it's tucked.
    func collapsibleMenu(_ id: String) -> some View {
        modifier(CollapsiblePanel(id: id))
    }
}

/// Visibility half of minimize-to-icon: menus hidden while their id sits in
/// AppModel.collapsedPanels (set by each menu's X button, shown again by the
/// top-right tray). On the model so rotation can't forget it.
struct CollapsiblePanel: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let id: String

    func body(content: Content) -> some View {
        if !model.collapsedPanels.contains(id) {
            content
        }
    }
}

/// Text with a SOLID outline — eight offset copies drawn behind the glyphs,
/// not a shadow. Yellow is the app's least legible color on a light card, and
/// a soft glow only smears it; a hard edge is what makes it read.
///
/// This is a view rather than a modifier on purpose: a modifier receives an
/// already-styled view, and re-coloring it can't override a `foregroundStyle`
/// already applied inside — which produced eight YELLOW copies and a smudge.
/// Taking the string and both colors keeps the layering unambiguous.
struct OutlinedText: View {
    let text: String
    var color: Color
    var outline: Color = .black
    var font: Font = .body
    var width: CGFloat = 1

    private static let offsets: [(CGFloat, CGFloat)] = [
        (-1, 0), (1, 0), (0, -1), (0, 1),
        (-1, -1), (1, -1), (-1, 1), (1, 1),
    ]

    var body: some View {
        ZStack {
            ForEach(Array(Self.offsets.enumerated()), id: \.offset) { _, o in
                Text(text)
                    .font(font)
                    .foregroundStyle(outline)
                    .offset(x: o.0 * width, y: o.1 * width)
            }
            Text(text)
                .font(font)
                .foregroundStyle(color)
        }
        .monospacedDigit()
    }
}

/// The middle rung of the efficiency ladder, drawn as literally half of
/// each neighbour: the leaf's corner above a diagonal, the exhaust's corner
/// below it. A generic "average" glyph said nothing about which two states
/// it sits between; this one shows them.
///
/// The whole thing carries a solid black outline (eight offset copies), so
/// the yellow-green and red read against a light card at instrument size.
struct MixedEfficiencyIcon: View {
    var size: CGFloat = 20

    /// Upper-left of the diagonal — the leaf's corner.
    private struct UpperLeft: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: r.minX, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                p.closeSubpath()
            }
        }
    }

    /// Lower-right of the diagonal — the exhaust's corner.
    private struct LowerRight: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: r.maxX, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                p.closeSubpath()
            }
        }
    }

    private static let offsets: [(CGFloat, CGFloat)] = [
        (-1, 0), (1, 0), (0, -1), (0, 1),
        (-1, -1), (1, -1), (-1, 1), (1, 1),
    ]

    private var halves: some View {
        ZStack {
            Image(systemName: "leaf.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(Theme.riskGreen)
                .clipShape(UpperLeft())
            Image(systemName: "smoke.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(Theme.riskRed)
                .clipShape(LowerRight())
        }
    }

    var body: some View {
        ZStack {
            // Solid outline: the same eight-offset trick the yellow numbers
            // use, since a thin two-color glyph needs an edge to read.
            ForEach(Array(Self.offsets.enumerated()), id: \.offset) { _, o in
                halves
                    .foregroundStyle(.black)
                    .colorMultiply(.black)
                    .offset(x: o.0, y: o.1)
            }
            halves
            // The dividing slash itself, bottom-left to top-right.
            GeometryReader { geo in
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height))
                    p.addLine(to: CGPoint(x: geo.size.width, y: 0))
                }
                .stroke(Color.black, lineWidth: 1.6)
            }
        }
        .frame(width: size * 1.15, height: size * 1.15)
    }
}

/// Scrolls only when the content is too tall for the space offered — tall
/// cards keep their natural size when there's room and become scrollable in
/// short windows (a phone on its side) instead of being clipped.
struct ScrollWhenTight<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView(showsIndicators: false) { content }
        }
    }
}

/// A fixed point size that STILL grows with the text-size setting.
///
/// `.font(.system(size: 14))` is frozen: it ignores Dynamic Type and the
/// in-app text-size slider entirely. That silently broke the promise the
/// slider makes — nearly half the app's type never moved. `@ScaledMetric`
/// scales the point size the same way body text scales, so the HUD keeps
/// its exact tuned proportions at the default size and actually enlarges
/// for a driver who needs it. The root `.dynamicTypeSize(...)` clamp still
/// caps how far it can go, so text can't outgrow its card.
private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design,
         relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// Drop-in replacement for `.font(.system(size:weight:))` that scales.
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular,
                    design: Font.Design = .default,
                    relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design,
                            relativeTo: style))
    }
}

/// THE band→color mapping — review finding: three drifting copies existed,
/// one of which used `== .blue` as a "clear band" sentinel.
extension RiskBand {
    var color: Color {
        switch self {
        case .clear: return .blue
        case .green: return Theme.riskGreen
        case .yellow: return Theme.riskYellow
        case .red: return Theme.riskRed
        }
    }
}
