// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import SwiftUI

/// A cuisine's flag as its button's background (owner, 2026-10-01: "Chinese"
/// or "Greek" in their flag's pattern and colours). Drawn, not pictured —
/// stripes, a canton, a star — so it is crisp at any size; the button puts
/// its word on a dark pill over it so the word always reads.
///
/// A cuisine with no country wears a small drawn scene in the same flat
/// style instead (owner, 2026-11-05: "a vectorized coffee on a table for a
/// coffee button"): a field of colour edge to edge like a flag's, and the
/// food itself at the two ends, where the word's pill leaves room. Every
/// measure is a share of the button's height, so the pictures hold their
/// shape at any text size.
struct CuisineFlag: View {
    let category: FoodCategory

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func rect(_ x: CGFloat, _ y: CGFloat, _ rw: CGFloat, _ rh: CGFloat, _ hex: UInt32) {
                ctx.fill(Path(CGRect(x: x, y: y, width: rw, height: rh)), with: .color(Self.color(hex)))
            }
            switch category {
            case .american:
                for i in 0..<13 {
                    rect(0, h * CGFloat(i) / 13, w, h / 13 + 0.5, i % 2 == 0 ? 0xB22234 : 0xFFFFFF)
                }
                let cw = w * 0.4, ch = h * 7 / 13
                rect(0, 0, cw, ch, 0x3C3B6E)
                for row in 0..<3 {
                    for col in 0..<4 {
                        let r = min(cw, ch) * 0.06
                        let x = cw * (CGFloat(col) + 0.5) / 4, y = ch * (CGFloat(row) + 0.5) / 3
                        ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                                 with: .color(.white))
                    }
                }
            case .mexican:
                rect(0, 0, w / 3, h, 0x006847)
                rect(w / 3, 0, w / 3 + 0.5, h, 0xFFFFFF)
                rect(2 * w / 3, 0, w / 3, h, 0xCE1126)
                let r = h * 0.16
                ctx.fill(Path(ellipseIn: CGRect(x: w / 2 - r, y: h / 2 - r, width: 2 * r, height: 2 * r)),
                         with: .color(Self.color(0x8C6239)))
            case .italian:
                rect(0, 0, w / 3, h, 0x009246)
                rect(w / 3, 0, w / 3 + 0.5, h, 0xFFFFFF)
                rect(2 * w / 3, 0, w / 3, h, 0xCE2B37)
            case .chinese:
                rect(0, 0, w, h, 0xDE2910)
                let gold = Self.color(0xFFDE00)
                ctx.fill(Self.star(center: CGPoint(x: h * 0.42, y: h * 0.38), radius: h * 0.24),
                         with: .color(gold))
                for (dx, dy) in [(0.82, 0.14), (1.0, 0.32), (1.0, 0.58), (0.82, 0.76)] {
                    ctx.fill(Self.star(center: CGPoint(x: h * dx, y: h * dy), radius: h * 0.08),
                             with: .color(gold))
                }
            case .greek:
                for i in 0..<9 {
                    rect(0, h * CGFloat(i) / 9, w, h / 9 + 0.5, i % 2 == 0 ? 0x0D5EAF : 0xFFFFFF)
                }
                let side = h * 5 / 9
                rect(0, 0, side, side, 0x0D5EAF)
                rect(side * 0.4, 0, side * 0.2, side, 0xFFFFFF)
                rect(0, side * 0.4, side, side * 0.2, 0xFFFFFF)
            case .fastFood: Self.drawFastFood(ctx, w, h)
            case .pizza: Self.drawPizza(ctx, w, h)
            case .coffee: Self.drawCoffee(ctx, w, h)
            case .breakfast: Self.drawBreakfast(ctx, w, h)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: scenes for the cuisines with no country

    /// A burger and a box of fries on a red wall, a mustard counter under them.
    /// "Fast food" is a long word, so its pill leaves about half a button's
    /// height at each end: both sit inside that, clear of the rounded corners.
    private static func drawFastFood(_ ctx: GraphicsContext, _ w: CGFloat, _ h: CGFloat) {
        box(ctx, 0, 0, w, h, 0xD52B1E)
        box(ctx, 0, h * 0.78, w, h * 0.22, 0xFFC72C)
        // Left: the burger, top bun down to bottom bun, standing on the counter.
        let cx = h * 0.34
        oval(ctx, cx, h * 0.47, h * 0.2, h * 0.18, 0xE0A04A)
        for (dx, dy) in [(-0.08, 0.38), (0.0, 0.34), (0.08, 0.38)] {
            oval(ctx, cx + h * dx, h * dy, h * 0.026, h * 0.016, 0xFFF3D6)
        }
        box(ctx, cx - h * 0.22, h * 0.47, h * 0.44, h * 0.07, 0x4CAF50, corner: h * 0.03)
        box(ctx, cx - h * 0.2, h * 0.52, h * 0.4, h * 0.045, 0xFFD23F)
        box(ctx, cx - h * 0.2, h * 0.555, h * 0.4, h * 0.11, 0x5D2E0C, corner: h * 0.04)
        box(ctx, cx - h * 0.2, h * 0.655, h * 0.4, h * 0.125, 0xE0A04A, corner: h * 0.05)
        // Right: fries standing in their box.
        let fx = w - h * 0.34
        let tops: [CGFloat] = [0.26, 0.17, 0.22, 0.15, 0.28]
        for (i, top) in tops.enumerated() {
            let x = fx + (CGFloat(i) - 2) * h * 0.065 - h * 0.025
            box(ctx, x, h * top, h * 0.05, h * (0.56 - top), 0xFFD23F, corner: h * 0.02)
        }
        shape(ctx, [CGPoint(x: fx - h * 0.18, y: h * 0.47), CGPoint(x: fx + h * 0.18, y: h * 0.47),
                    CGPoint(x: fx + h * 0.13, y: h * 0.82), CGPoint(x: fx - h * 0.13, y: h * 0.82)], 0xFFFFFF)
        shape(ctx, [CGPoint(x: fx - h * 0.165, y: h * 0.57), CGPoint(x: fx + h * 0.165, y: h * 0.57),
                    CGPoint(x: fx + h * 0.15, y: h * 0.68), CGPoint(x: fx - h * 0.15, y: h * 0.68)], 0xD52B1E)
    }

    /// A whole pie and a slice on a pizzeria's red-checked tablecloth.
    private static func drawPizza(_ ctx: GraphicsContext, _ w: CGFloat, _ h: CGFloat) {
        box(ctx, 0, 0, w, h, 0xFFFFFF)
        let side = h / 4
        var col = 0
        while CGFloat(col) * side < w {
            for row in 0..<4 where (row + col) % 2 == 0 {
                box(ctx, CGFloat(col) * side, CGFloat(row) * side, side, side, 0xD7263D)
            }
            col += 1
        }
        // Left: the pie from above — crust, cheese, pepperoni.
        let cx = h * 0.66, cy = h * 0.5
        oval(ctx, cx, cy, h * 0.44, h * 0.44, 0xB9772C)
        oval(ctx, cx, cy, h * 0.35, h * 0.35, 0xF7CE5B)
        for (dx, dy) in [(-0.15, -0.13), (0.15, -0.14), (0.0, 0.03), (-0.15, 0.17), (0.17, 0.15)] {
            oval(ctx, cx + h * dx, cy + h * dy, h * 0.065, h * 0.065, 0xB3261E)
        }
        // Right: one slice, point down.
        let sx = w - h * 0.66
        shape(ctx, [CGPoint(x: sx - h * 0.28, y: h * 0.22), CGPoint(x: sx + h * 0.28, y: h * 0.22),
                    CGPoint(x: sx, y: h * 0.92)], 0xF7CE5B)
        box(ctx, sx - h * 0.32, h * 0.10, h * 0.64, h * 0.16, 0xB9772C, corner: h * 0.08)
        for (dx, dy) in [(-0.10, 0.37), (0.10, 0.42), (0.0, 0.62)] {
            oval(ctx, sx + h * dx, h * dy, h * 0.06, h * 0.06, 0xB3261E)
        }
    }

    /// A steaming cup on its saucer and a cup to go, both on a café table.
    private static func drawCoffee(_ ctx: GraphicsContext, _ w: CGFloat, _ h: CGFloat) {
        box(ctx, 0, 0, w, h, 0xC58B55)
        box(ctx, 0, h * 0.72, w, h * 0.28, 0x5A3418)
        box(ctx, 0, h * 0.72, w, h * 0.045, 0x7A4A24)
        // Left: the cup — handle, saucer, body, the coffee in it, the steam.
        let cx = h * 0.5
        ctx.stroke(Path(ellipseIn: CGRect(x: cx + h * 0.11, y: h * 0.40, width: h * 0.2, height: h * 0.2)),
                   with: .color(.white), lineWidth: h * 0.05)
        oval(ctx, cx, h * 0.72, h * 0.33, h * 0.05, 0xFFFFFF)
        box(ctx, cx - h * 0.2, h * 0.36, h * 0.4, h * 0.33, 0xFFFFFF, corner: h * 0.1)
        oval(ctx, cx, h * 0.37, h * 0.2, h * 0.055, 0xFFFFFF)
        oval(ctx, cx, h * 0.37, h * 0.16, h * 0.035, 0x3B2212)
        for dx in [-0.08, 0.08] {
            let x = cx + h * dx
            var steam = Path()
            steam.move(to: CGPoint(x: x, y: h * 0.27))
            steam.addCurve(to: CGPoint(x: x, y: h * 0.06),
                           control1: CGPoint(x: x - h * 0.1, y: h * 0.2),
                           control2: CGPoint(x: x + h * 0.1, y: h * 0.13))
            ctx.stroke(steam, with: .color(.white.opacity(0.85)),
                       style: StrokeStyle(lineWidth: h * 0.045, lineCap: .round))
        }
        // Right: the paper cup — its body, sleeve and lid.
        let tx = w - h * 0.58
        shape(ctx, [CGPoint(x: tx - h * 0.18, y: h * 0.28), CGPoint(x: tx + h * 0.18, y: h * 0.28),
                    CGPoint(x: tx + h * 0.13, y: h * 0.74), CGPoint(x: tx - h * 0.13, y: h * 0.74)], 0xFFFFFF)
        shape(ctx, [CGPoint(x: tx - h * 0.165, y: h * 0.42), CGPoint(x: tx + h * 0.165, y: h * 0.42),
                    CGPoint(x: tx + h * 0.145, y: h * 0.6), CGPoint(x: tx - h * 0.145, y: h * 0.6)], 0x8B5A2B)
        box(ctx, tx - h * 0.21, h * 0.21, h * 0.42, h * 0.09, 0x3B2212, corner: h * 0.03)
    }

    /// A fried egg and a stack of pancakes under a morning-blue sky. The
    /// longest word of the nine: the yolk and the stack keep to the half
    /// button-height its pill leaves at each end.
    private static func drawBreakfast(_ ctx: GraphicsContext, _ w: CGFloat, _ h: CGFloat) {
        box(ctx, 0, 0, w, h, 0x4A90D9)
        // Left: the egg, sunny side up. The white may run under the pill; the
        // yolk stays in the open.
        let cx = h * 0.34
        oval(ctx, cx + h * 0.02, h * 0.5, h * 0.26, h * 0.3, 0xFFFFFF)
        oval(ctx, cx + h * 0.16, h * 0.62, h * 0.2, h * 0.2, 0xFFFFFF)
        oval(ctx, cx + h * 0.12, h * 0.34, h * 0.18, h * 0.16, 0xFFFFFF)
        oval(ctx, cx, h * 0.5, h * 0.14, h * 0.14, 0xFFB300)
        oval(ctx, cx - h * 0.045, h * 0.45, h * 0.035, h * 0.035, 0xFFE082)
        // Right: pancakes on a plate, syrup running down, butter on top.
        let px = w - h * 0.34
        oval(ctx, px, h * 0.8, h * 0.25, h * 0.05, 0xFFFFFF)
        box(ctx, px - h * 0.2, h * 0.66, h * 0.4, h * 0.12, 0xD9953D, corner: h * 0.06)
        box(ctx, px - h * 0.19, h * 0.54, h * 0.38, h * 0.12, 0xE9B45C, corner: h * 0.06)
        box(ctx, px - h * 0.2, h * 0.42, h * 0.4, h * 0.12, 0xD9953D, corner: h * 0.06)
        box(ctx, px - h * 0.2, h * 0.4, h * 0.4, h * 0.065, 0x7B3F00, corner: h * 0.03)
        box(ctx, px - h * 0.14, h * 0.43, h * 0.06, h * 0.15, 0x7B3F00, corner: h * 0.03)
        box(ctx, px + h * 0.07, h * 0.43, h * 0.06, h * 0.22, 0x7B3F00, corner: h * 0.03)
        box(ctx, px - h * 0.06, h * 0.31, h * 0.12, h * 0.1, 0xFFE066, corner: h * 0.02)
    }

    // MARK: drawing helpers

    private static func box(_ ctx: GraphicsContext, _ x: CGFloat, _ y: CGFloat,
                            _ width: CGFloat, _ height: CGFloat, _ hex: UInt32, corner: CGFloat = 0) {
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let path = corner > 0
            ? Path(roundedRect: frame, cornerRadius: corner)
            : Path(frame)
        ctx.fill(path, with: .color(color(hex)))
    }

    /// An ellipse by its centre and its two radii.
    private static func oval(_ ctx: GraphicsContext, _ cx: CGFloat, _ cy: CGFloat,
                             _ rx: CGFloat, _ ry: CGFloat, _ hex: UInt32) {
        ctx.fill(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry)),
                 with: .color(color(hex)))
    }

    /// A closed, straight-sided shape through the given corners.
    private static func shape(_ ctx: GraphicsContext, _ corners: [CGPoint], _ hex: UInt32) {
        var path = Path()
        path.addLines(corners)
        path.closeSubpath()
        ctx.fill(path, with: .color(color(hex)))
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    /// A five-pointed star, point up.
    private static func star(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for i in 0..<10 {
            let r = i % 2 == 0 ? radius : radius * 0.4
            let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let p = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}
