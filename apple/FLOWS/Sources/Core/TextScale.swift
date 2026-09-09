// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import SwiftUI

/// The in-app text-size slider's math (Settings → Text size), pure and
/// pinned by FLOWSTests. Two rules:
///   1. The driver can set a size directly — but only within what the
///      CURRENT screen can hold, so words never wrap into a smear or fall
///      off a card edge. The cap comes from the window's width in points.
///   2. Until the slider is touched (index −1), FLOWS follows the phone's
///      own text-size setting — still clamped to the same screen cap.
enum TextScale {
    /// Slider steps, readable-small → largest accessibility size. .xSmall
    /// is deliberately absent: tiny text in a moving vehicle is a hazard,
    /// not a preference.
    static let steps: [DynamicTypeSize] = [
        .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
        .accessibility1, .accessibility2, .accessibility3,
        .accessibility4, .accessibility5,
    ]

    /// Highest step index the current screen width can hold: phone-width
    /// windows stop before the accessibility tiers (their cards are already
    /// edge-to-edge), mid widths take the small accessibility sizes, and
    /// only tablet/desktop widths offer the largest.
    static func maxStepIndex(forWidthPoints width: Double) -> Int {
        if width < 380 { return steps.firstIndex(of: .xxxLarge) ?? 0 }
        if width < 700 { return steps.firstIndex(of: .accessibility2) ?? 0 }
        return steps.count - 1
    }

    /// The range handed to `.dynamicTypeSize(_:)` at the app root.
    /// chosenIndex −1 = follow the system setting (clamped); anything else
    /// pins the picked step (also clamped).
    static func range(chosenIndex: Int, maxIndex: Int) -> ClosedRange<DynamicTypeSize> {
        let bounded = max(0, min(maxIndex, steps.count - 1))
        guard chosenIndex >= 0 else { return .xSmall...steps[bounded] }
        let pinned = steps[max(0, min(chosenIndex, bounded))]
        return pinned...pinned
    }

    /// How much larger than the default each step draws — Apple's body
    /// text point sizes over the default 17. macOS has no Dynamic Type, so
    /// `@ScaledMetric` never moves there; ScaledFont applies this by hand.
    static func factor(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: return 14 / 17
        case .small: return 15 / 17
        case .medium: return 16 / 17
        case .large: return 1
        case .xLarge: return 19 / 17
        case .xxLarge: return 21 / 17
        case .xxxLarge: return 23 / 17
        case .accessibility1: return 28 / 17
        case .accessibility2: return 33 / 17
        case .accessibility3: return 40 / 17
        case .accessibility4: return 47 / 17
        case .accessibility5: return 53 / 17
        @unknown default: return 1
        }
    }

    /// The default point size of each semantic style, so `.caption` and
    /// friends can go through the same scaling as a fixed size.
    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
    }

    /// Where the system's current size sits on the slider (seed value when
    /// the driver first touches it).
    static func index(of size: DynamicTypeSize) -> Int {
        steps.firstIndex(of: size) ?? (steps.firstIndex(of: .large) ?? 0)
    }
}
