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
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .shadow(color: Theme.cardShadow, radius: 14, y: 5)
    }
}

extension View {
    func floatingCard() -> some View { modifier(FloatingCard()) }
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
