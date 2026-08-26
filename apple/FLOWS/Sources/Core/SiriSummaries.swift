// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// The sentences Siri speaks back for the route intents — pure string
/// builders so FLOWSTests pins the exact wording (spoken text is UI: the
/// plain-words rule applies, and a regression here is invisible in a
/// simulator).
enum SiriSummaries {
    /// Miles, spoken: whole numbers read naturally ("12 miles"), close-in
    /// stops keep one decimal ("0.4 miles"), and 1 mile isn't plural.
    static func spokenMiles(meters: Double) -> String {
        let miles = meters / 1609.344
        if miles < 10 {
            let rounded = (miles * 10).rounded() / 10
            if rounded == 1 { return "1 mile" }
            // Drop a trailing ".0" — "5 miles", not "5.0 miles".
            return rounded == rounded.rounded()
                ? "\(Int(rounded)) miles"
                : String(format: "%.1f miles", rounded)
        }
        return "\(Int(miles.rounded())) miles"
    }

    /// Time, spoken: "2 hours 5 minutes" / "45 minutes" / "under a minute".
    static func spokenTime(seconds: Double) -> String {
        let mins = Int((seconds / 60).rounded())
        if mins < 1 { return "under a minute" }
        if mins < 60 { return "\(mins) minute\(mins == 1 ? "" : "s")" }
        let h = mins / 60
        let m = mins % 60
        let hours = "\(h) hour\(h == 1 ? "" : "s")"
        return m == 0 ? hours : "\(hours) \(m) minute\(m == 1 ? "" : "s")"
    }

    /// Reply after a stop was added to the live route.
    static func addedStop(name: String, meters: Double?) -> String {
        guard let meters else { return "Added \(name) to the route. Directions updated." }
        return "Added \(name), about \(spokenMiles(meters: meters)) ahead. Directions updated."
    }

    /// Clip long official text at a sentence edge for speech — CAP
    /// headlines can run paragraphs, and a spoken wall of text is
    /// unusable at 70 mph.
    static func spokenClip(_ text: String, limit: Int = 220) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let head = String(trimmed.prefix(limit))
        if let sentence = head.range(of: ". ", options: .backwards) {
            return String(head[..<sentence.lowerBound]) + "."
        }
        if let space = head.range(of: " ", options: .backwards) {
            return String(head[..<space.lowerBound])
        }
        return head
    }

    /// Spoken offer when traffic opens a faster route — ends by naming the
    /// exact phrase that accepts it, so approval stays fully hands-free.
    static func fasterRouteOffer(minutes: Int) -> String {
        "Traffic ahead adds about \(minutes) minute\(minutes == 1 ? "" : "s"). "
            + "A faster route is ready — say: go ahead in FLOWS."
    }

    /// Spoken emergency announcement when a warning enters the corridor.
    /// Child-abduction (AMBER) alerts get the emergency framing and the
    /// call-911 line; weather warnings get the action FLOWS already took.
    static func emergencyAnnouncement(event: String, headline: String?,
                                      action: ImminentAlerts.Action) -> String {
        let isAbduction = event.localizedCaseInsensitiveContains("child abduction")
            || event.localizedCaseInsensitiveContains("amber")
        var out = (isAbduction ? "Emergency alert: " : "Weather alert on your route: ")
            + event + "."
        if let headline, !headline.isEmpty {
            let clipped = spokenClip(headline)
            out += " " + clipped + (clipped.hasSuffix(".") ? "" : ".")
        }
        if isAbduction {
            out += " If you see them, call 911 — do not approach."
        } else {
            switch action {
            case .shelter: out += " FLOWS is showing shelter options."
            case .restArea: out += " Consider waiting it out at a rest area."
            case .monitor: out += " Check the FLOWS screen when it's safe."
            }
        }
        return out
    }

    /// Hours-of-service line for the road-ahead reply (trucker mode):
    /// nil while the clock is fine, one plain sentence once it isn't.
    static func hosLine(_ status: HOSRules.Status) -> String? {
        switch status {
        case .ok:
            return nil
        case .breakSoon(let secondsUntilDue):
            return "Heads up: your 30-minute break is due in "
                + "\(spokenTime(seconds: secondsUntilDue))."
        case .breakDue:
            return "Your 30-minute break is due now."
        case .limitReached:
            return "You've hit the 11-hour driving limit — time to stop."
        }
    }

    /// Reply for "how's the road ahead": distance + time left, then the
    /// weather alerts crossing the route — or an all-clear.
    static func roadAhead(remainingMeters: Double, remainingSeconds: Double,
                          alertEvents: [String]) -> String {
        var out = "About \(spokenMiles(meters: remainingMeters)) and "
            + "\(spokenTime(seconds: remainingSeconds)) to go."
        // One alert reads naturally; several get counted then named.
        let unique = alertEvents.reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        if unique.isEmpty {
            out += " No weather alerts on the route."
        } else if unique.count == 1 {
            out += " One weather alert ahead: \(unique[0])."
        } else {
            out += " \(unique.count) weather alerts ahead: "
                + unique.prefix(3).joined(separator: ", ") + "."
        }
        return out
    }
}
