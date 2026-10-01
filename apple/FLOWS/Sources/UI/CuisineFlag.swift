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
/// its word on a dark pill over it so the word always reads. Cuisines with no
/// country (fast food, pizza, coffee, breakfast) have none.
struct CuisineFlag: View {
    let category: FoodCategory

    static func has(_ category: FoodCategory) -> Bool {
        [.american, .mexican, .italian, .chinese, .greek].contains(category)
    }

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
            default:
                break
            }
        }
        .accessibilityHidden(true)
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
