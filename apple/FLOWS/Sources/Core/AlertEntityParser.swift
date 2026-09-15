// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Pulls VEHICLE and PERSON descriptions out of red-alert text (AMBER /
/// Blue / Silver alerts, civil emergencies) so the app can render a generic
/// colored silhouette + brand badge instead of storing an image of every
/// vehicle: "red Toyota truck" → truck silhouette filled red, TOYOTA badge.
/// Pure string parsing, computed in rust/flows-core (alert_text.rs) on Swift's
/// own text rules, pinned by FLOWSTests and by
/// rust/flows-bridge/tests/fixtures/swift_alert_text_oracle.tsv.
enum AlertEntityParser {

    struct VehicleEntity: Equatable {
        /// Named color from the description (nil = unknown → neutral fill).
        var colorName: String?
        /// Vehicle class → SF Symbol silhouette.
        var kind: VehicleKind
        /// Brand name for the text badge (rendered as TEXT — bundling
        /// trademarked logo artwork isn't something we can ship).
        var brand: String?
    }

    enum VehicleKind: String, CaseIterable {
        case truck, suv, van, sedan, motorcycle, bus

        var symbol: String {
            switch self {
            case .truck: return "truck.pickup.side.fill"
            case .suv: return "suv.side.fill"
            case .van: return "bus.fill"
            case .sedan: return "car.side.fill"
            case .motorcycle: return "figure.outdoor.cycle"
            case .bus: return "bus.doubledecker.fill"
            }
        }
    }

    struct PersonEntity: Equatable {
        var isChild: Bool
        /// Clothing/appearance color when stated (nil → neutral fill).
        var colorName: String?

        var symbol: String { isChild ? "figure.child" : "figure.stand" }
    }

    /// Recognized color vocabulary (order matters: multi-word first).
    static let colorNames: [String] = flows_alert_text_color_names().map { $0.text }

    static let brands: [String] = flows_alert_text_brands().map { $0.text }

    /// Alerts that actually DESCRIBE a suspect vehicle or person: the
    /// AMBER family and law-enforcement emergencies.
    ///
    /// Weather text is full of words this parser will happily read as a
    /// description — a severe thunderstorm warning naming a bus route drew a
    /// BUS on the banner, and a flood warning drew a CAR. Nothing in a
    /// weather alert is a suspect vehicle, so the parser is not run on one.
    static func describesAnEntity(event: String) -> Bool {
        flows_alert_text_describes_an_entity(event)
    }

    /// First vehicle mentioned in the text, with the color/brand that appear
    /// NEAR it (same ~60-character window, so a red shirt elsewhere in the
    /// alert doesn't repaint the car).
    static func vehicle(in text: String) -> VehicleEntity? {
        let v = flows_alert_text_vehicle(text)
        guard v.has, Int(v.kind) < VehicleKind.allCases.count else { return nil }
        return VehicleEntity(colorName: v.has_color ? colorNames[Int(v.color_index)] : nil,
                             kind: VehicleKind.allCases[Int(v.kind)],
                             brand: v.has_brand ? brands[Int(v.brand_index)] : nil)
    }

    /// First person mentioned (child words win over adult words when both
    /// appear — an AMBER alert's subject is the child).
    static func person(in text: String) -> PersonEntity? {
        let p = flows_alert_text_person(text)
        guard p.has else { return nil }
        return PersonEntity(isChild: p.is_child,
                            colorName: p.has_color ? colorNames[Int(p.color_index)] : nil)
    }
}
