// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// What counts as shelter from THIS hazard, and for how long.
///
/// The old rule asked for "tornado shelter storm shelter" no matter what was
/// coming, which is why a driver in an ordinary thunderstorm was told there
/// was no shelter on the route while passing a row of open restaurants. Two
/// things were wrong with that: the search named a facility type that barely
/// exists as a mapped place, and it made no distinction between weather you
/// wait out indoors and weather that needs a reinforced building.
///
/// So shelter is chosen by what the hazard can actually do:
///
///   * Some hazards are a DRIVING problem, not a building problem. Heavy
///     rain, fog and hail hurt because of visibility and hydroplaning; the
///     right answer is to get off the road, and a parked vehicle is shelter.
///   * Most severe weather is survivable inside any ordinary occupied
///     building — that is what "seek shelter indoors" means on the radio.
///   * A few hazards are not: a tornado on the ground, a hurricane eyewall,
///     a fire evacuation. Those need a real shelter or a substantial
///     building, and a strip-mall restaurant is not one.
///
/// Pure policy, pinned by FLOWSTests.
enum ShelterPolicy {
    /// What the driver should be looking for.
    enum Kind: String, Equatable {
        /// Get off the road and stay in the vehicle — the hazard is about
        /// driving conditions, not structural danger.
        case inVehicle
        /// Any ordinary occupied building: a restaurant, a shop, a library.
        case anyBuilding
        /// A substantial building — masonry, a public interior, somewhere
        /// with an interior room away from windows.
        case sturdyBuilding
        /// A designated shelter or evacuation centre.
        case officialShelter

        /// Plain words for the banner. Fifth-grade vocabulary on purpose.
        var advice: String {
            switch self {
            case .inVehicle:
                return "Pull over somewhere safe and wait in your vehicle."
            case .anyBuilding:
                return "Get inside any open building and wait it out."
            case .sturdyBuilding:
                return "Get inside a solid building, away from windows."
            case .officialShelter:
                return "Go to an official shelter now."
            }
        }

        /// What to actually search for. These are ORDINARY places, because
        /// those are the ones that exist on a map and are open at 3 pm on a
        /// Tuesday — a "storm shelter" search returns nothing across most of
        /// the country.
        var searchQueries: [String] {
            switch self {
            case .inVehicle:
                return ["rest area", "truck stop", "parking lot", "gas station"]
            case .anyBuilding:
                return ["restaurant", "cafe", "supermarket", "shopping mall",
                        "library", "gas station"]
            case .sturdyBuilding:
                return ["public library", "shopping mall", "hospital",
                        "community center", "school", "supermarket"]
            case .officialShelter:
                return ["emergency shelter", "evacuation center",
                        "community center", "school", "fire station"]
            }
        }

        /// Is a plain building good enough? Used to decide whether an
        /// ordinary open place can be offered at all.
        var acceptsOrdinaryBuildings: Bool {
            self == .anyBuilding || self == .sturdyBuilding
        }
    }

    /// The shelter a given alert calls for.
    ///
    /// Severity matters as much as the name: a severe thunderstorm WARNING
    /// with 70 mph gusts is a different problem from a thunderstorm watch,
    /// and the score carries that.
    static func kind(forEvent event: String, severityScore: Double) -> Kind {
        // The tables live in rust/flows-core alerts.rs, beside the display
        // and imminent-alert rules for the same event names.
        switch flows_alerts_shelter_kind(event, severityScore) {
        case 0: return .inVehicle
        case 1: return .anyBuilding
        case 3: return .officialShelter
        default: return .sturdyBuilding   // 2, and the containment fallback
        }
    }

    /// How long to stay put: as long as the hazard is actually there.
    ///
    /// The old card offered a flat hour and ADDED another every press, which
    /// is the opposite of useful — pressing it again meant "I've read this",
    /// not "keep me here longer". The wait is the alert's own remaining life,
    /// clamped to something a person will actually sit through.
    static let minimumWait: TimeInterval = 5 * 60
    static let maximumWait: TimeInterval = 3 * 3600
    /// With no expiry published, most severe-weather warnings run under an
    /// hour; half of that is an honest default rather than a guess upward.
    static let unknownExpiryWait: TimeInterval = 30 * 60

    static func waitSeconds(expires: Date?, now: Date = Date()) -> TimeInterval {
        guard let expires else { return unknownExpiryWait }
        let remaining = expires.timeIntervalSince(now)
        guard remaining > 0 else { return minimumWait }
        return min(max(remaining, minimumWait), maximumWait)
    }

    /// "12 min" / "1 h 05 min" — the countdown in the directions window.
    static func countdownText(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d h %02d min", h, m) }
        if m > 0 { return String(format: "%d:%02d", m, sec) }
        return String(format: "0:%02d", sec)
    }
}
