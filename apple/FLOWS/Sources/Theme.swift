// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import SwiftUI

/// Shared design language across macOS / iOS / iPadOS — the same tokens as the
/// web app's styles.css so both frontends read as one product:
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
    static let pillRadius: CGFloat = 999
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
