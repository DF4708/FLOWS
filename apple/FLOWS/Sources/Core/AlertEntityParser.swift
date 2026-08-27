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
/// Pure string parsing — pinned by FLOWSTests.
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
    static let colorNames = [
        "dark blue", "light blue", "dark green", "light green", "dark gray",
        "light gray", "red", "blue", "green", "black", "white", "silver",
        "gray", "grey", "yellow", "orange", "purple", "brown", "tan", "gold",
        "maroon", "beige", "pink",
    ]

    static let brands = [
        "Toyota", "Ford", "Chevrolet", "Chevy", "Honda", "Nissan", "Dodge",
        "Ram", "GMC", "Jeep", "Hyundai", "Kia", "Subaru", "Mazda", "Tesla",
        "Volkswagen", "BMW", "Mercedes", "Audi", "Lexus", "Buick",
        "Cadillac", "Chrysler", "Volvo", "Acura", "Infiniti", "Lincoln",
        "Mitsubishi", "Pontiac", "Saturn", "Freightliner", "Peterbilt",
        "Kenworth",
    ]

    private static let vehicleWords: [(String, VehicleKind)] = [
        ("pickup truck", .truck), ("pickup", .truck), ("truck", .truck),
        ("suv", .suv), ("sport utility", .suv),
        ("minivan", .van), ("van", .van),
        ("sedan", .sedan), ("coupe", .sedan), ("hatchback", .sedan),
        ("motorcycle", .motorcycle),
        ("bus", .bus),
        ("car", .sedan),   // last: generic
    ]

    /// First vehicle mentioned in the text, with the color/brand that appear
    /// NEAR it (same ~10-word window, so a red shirt elsewhere in the alert
    /// doesn't repaint the car).
    /// Alerts that actually DESCRIBE a suspect vehicle or person: the
    /// AMBER family and law-enforcement emergencies.
    ///
    /// Weather text is full of words this parser will happily read as a
    /// description — a severe thunderstorm warning naming a bus route drew a
    /// BUS on the banner, and a flood warning drew a CAR. Nothing in a
    /// weather alert is a suspect vehicle, so the parser is not run on one.
    static func describesAnEntity(event: String) -> Bool {
        let lower = event.lowercased()
        return ["amber", "child abduction", "blue alert", "silver alert",
                "endangered", "missing", "law enforcement", "civil emergency"]
            .contains { lower.contains($0) }
    }

    static func vehicle(in text: String) -> VehicleEntity? {
        let lower = text.lowercased()
        guard let (word, kind) = vehicleWords.first(where: { lower.contains($0.0) }),
              let range = lower.range(of: word) else { return nil }
        let window = contextWindow(lower, around: range)
        let color = colorNames.first { window.contains($0) }
        let brand = brands.first { window.localizedCaseInsensitiveContains($0) }
            .map { $0 == "Chevy" ? "Chevrolet" : $0 }
        return VehicleEntity(colorName: color, kind: kind, brand: brand)
    }

    /// First person mentioned (child words win over adult words when both
    /// appear — an AMBER alert's subject is the child).
    static func person(in text: String) -> PersonEntity? {
        let lower = text.lowercased()
        let childWords = ["child", "boy", "girl", "infant", "toddler",
                          "juvenile", "-year-old", "year old"]
        let adultWords = ["man", "woman", "male", "female", "adult", "suspect"]
        let isChild = childWords.first { lower.contains($0) } != nil
        let isAdult = adultWords.first { lower.contains($0) } != nil
        guard isChild || isAdult else { return nil }
        // Clothing color: nearest color to a wearing/clothing word, else the
        // first color that is NOT the vehicle's window.
        var color: String?
        for clothing in ["wearing", "shirt", "jacket", "hoodie", "dress",
                         "pants", "clothing", "hair"] {
            if let r = lower.range(of: clothing) {
                let window = contextWindow(lower, around: r)
                if let c = colorNames.first(where: { window.contains($0) }) {
                    color = c
                    break
                }
            }
        }
        return PersonEntity(isChild: isChild && !lowerHasOnlyAdultSubject(lower),
                            colorName: color)
    }

    private static func lowerHasOnlyAdultSubject(_ lower: String) -> Bool {
        false   // child words present → child silhouette (AMBER convention)
    }

    /// ~60 characters either side of a match — the "same breath" window.
    private static func contextWindow(
        _ text: String, around range: Range<String.Index>
    ) -> String {
        let start = text.index(range.lowerBound, offsetBy: -60,
                               limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 60,
                             limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }
}
