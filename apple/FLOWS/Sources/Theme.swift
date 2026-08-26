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
    // styles.css: .search-button / .route-button { background:#111 }
    static let cta = Color(red: 0x11 / 255.0, green: 0x11 / 255.0, blue: 0x11 / 255.0)
    // styles.css: rgba(255,255,255,0.95) floating cards
    static let cardBackground = Color.white.opacity(0.95)
    static let cardShadow = Color.black.opacity(0.14)
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
            .foregroundStyle(.white)
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
