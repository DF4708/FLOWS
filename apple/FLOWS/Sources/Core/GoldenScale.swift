// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreGraphics
import Foundation

/// The golden ratio — every window-proportional size derives from it, so
/// chrome keeps the same visual proportions on any screen, shape, or
/// orientation.
public let goldenRatio: CGFloat = 1.61803398875

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
        base / pow(goldenRatio, CGFloat(n))
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
    /// Room to the LEFT of a centred bottom panel, inside the padding.
    ///
    /// The map key sits bottom-left and the planner sits bottom-centre. On a
    /// wide layout those are different columns, but on a narrow-regular
    /// window — an 11-inch iPad in portrait — the key's natural width is
    /// larger than the gap beside the panel, and the two overlapped.
    var leftGutter: CGFloat { max((size.width - sidePanel) / 2 - pad * 2, 0) }
    /// CONTENT width for the key: its natural size, capped so that the
    /// content PLUS the card's own padding fits the gutter.
    ///
    /// Capping the content alone was not enough — `padCard` is added outside
    /// that frame on both sides, which on an 11-inch iPad put 62 pt of card
    /// back under the panel. The budget has to include the padding.
    var legendDrawWidth: CGFloat {
        min(legendWidth * 1.1, max(leftGutter - padCard * 2, 0))
    }
    /// What the key's card actually occupies, padding included.
    var legendOuterWidth: CGFloat { legendDrawWidth + padCard * 2 }
    /// Narrower than this and the key is unreadable — better to hide it than
    /// to show a squeezed column of clipped words.
    var legendFits: Bool { legendDrawWidth >= 150 }
    /// Side panel on regular layouts (window width/φ²).
    var sidePanel: CGFloat { size.width / (goldenRatio * goldenRatio) }
    /// Narrow side column on regular layouts (window width/φ³).
    var sideColumn: CGFloat { size.width / pow(goldenRatio, 3) }
    /// Floating-card width cap on regular layouts (long side/φ).
    var cardMax: CGFloat { long / goldenRatio }
    /// Tallest a stacked panel may grow (height/φ²) — the map keeps the
    /// majority of the window.
    var panelMaxHeight: CGFloat { size.height / (goldenRatio * goldenRatio) }
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
    var listMaxHeight: CGFloat { size.height / pow(goldenRatio, 3) }
}

// MARK: - Chrome layout: nothing covers anything else

/// One piece of floating chrome — a menu, card, banner, icon column or
/// instrument window — and where it sits in the window.
struct ChromeFrame: Equatable {
    let id: String
    let rect: CGRect
}

/// How much of the window the driving chrome covers, as fractions of the
/// window's full height (safe areas included); nil where none is on screen.
struct ChromeCover: Equatable {
    var top: Double?
    var bottom: Double?
}

/// The layout rule every floating element keeps: nothing covers anything
/// else. Pure, pinned by FLOWSTests; ContentView feeds it the frames the
/// chrome reports through `chromeRegion`.
enum ChromeLayout {
    /// Shadows touching and rows that share an edge are not one element
    /// covering another: an overlap must be wider AND taller than this.
    static let tolerance: CGFloat = 1

    /// Every pair of frames that overlap, as (first id, second id, shared
    /// rectangle), ids in sorted order. A collapsed (zero-size) element
    /// never overlaps anything.
    static func overlaps(_ frames: [ChromeFrame]) -> [(String, String, CGRect)] {
        let sorted = frames.sorted { $0.id < $1.id }
        var found: [(String, String, CGRect)] = []
        for i in sorted.indices {
            for j in sorted.indices where j > i {
                let shared = sorted[i].rect.intersection(sorted[j].rect)
                if !shared.isNull, shared.width > tolerance, shared.height > tolerance {
                    found.append((sorted[i].id, sorted[j].id, shared))
                }
            }
        }
        return found
    }

    /// The chrome's cover: the lowest bottom edge among the `top` frames and
    /// the highest top edge among the `bottom` frames, in a window `height`
    /// tall whose safe areas add `insetTop` and `insetBottom` beyond it.
    /// Collapsed (zero-size) frames are ignored.
    static func cover(top: [CGRect], bottom: [CGRect], height: CGFloat,
                      insetTop: CGFloat, insetBottom: CGFloat) -> ChromeCover {
        let full = height + insetTop + insetBottom
        guard full > 0 else { return ChromeCover() }
        let real = { (r: CGRect) in r.width > 0 && r.height > 0 }
        let fraction = { (x: CGFloat) in Double(min(max(x / full, 0), 1)) }
        return ChromeCover(
            top: top.filter(real).map(\.maxY).max().map { fraction(insetTop + $0) },
            bottom: bottom.filter(real).map(\.minY).min().map { fraction(insetBottom + height - $0) })
    }
}

/// The screen a tucked-menu icon would show on.
enum ChromeScreen: Equatable {
    case planning, choosing, driving
}

/// Which tucked menus come back on which screen: the rule the tucked-menu
/// tray shows its icons by (pure, so it is tested).
enum TuckedMenus {
    /// Whether a tucked menu comes back on this screen: the planner while
    /// planning, the route list and the limits card while choosing, the
    /// instruments and a stop list that still has stops while driving, and
    /// the map key where the screen has room for it (never while driving).
    /// An icon for a menu the screen does not have used to sit in the column
    /// doing nothing (the route list's after Edit went back to planning, the
    /// stop list's after its stops were cleared), and every extra icon made
    /// the column longer. The pile itself is unchanged: a hidden icon shows
    /// again where its menu lives.
    static func comesBack(_ id: String, on screen: ChromeScreen, hasStops: Bool,
                          mapKeyComesBack: Bool) -> Bool {
        switch id {
        case "planner": return screen == .planning
        case "routes", "sliders": return screen == .choosing
        case "fuel": return screen == .driving
        case "stops": return screen == .driving && hasStops
        case "legend": return mapKeyComesBack
        default: return true
        }
    }
}
