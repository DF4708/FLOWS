// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// One voice installed on the device, as the Settings list and the rules
/// below see it (VoiceAnnouncer reads them from the system).
struct VoiceChoice: Equatable, Identifiable, Sendable {
    /// How natural the voice sounds, in the system's own three steps. The
    /// basic ones ship with the device and sound mechanical; the other two
    /// are free downloads in the device's own Settings.
    enum Quality: Int, Comparable, Sendable {
        case basic, enhanced, premium
        static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }

    /// The system's identifier for the voice — what is saved as the pick.
    let id: String
    let name: String
    /// "en-US", "en-GB".
    let language: String
    let quality: Quality
}

/// Which voice FLOWS speaks with, and how fast. Until the driver picks one,
/// FLOWS takes the most natural voice installed; the plain default voice
/// only speaks when nothing better is on the device.
enum SpeechVoiceRules {
    /// The saved pick that means "the best one here".
    static let automaticID = ""

    /// FLOWS's lines are English, so its voices are too: the device's own
    /// English when it is set to one ("en-GB"), American otherwise.
    static func spokenLanguage(device: String) -> String {
        device.hasPrefix("en-") ? device : "en-US"
    }

    private static func languageCode(_ language: String) -> Substring {
        language.split(separator: "-").first ?? Substring(language)
    }

    /// The voices offered in Settings: every one in the spoken language, the
    /// most natural first, the device's own accent ahead of the others.
    static func choices(among all: [VoiceChoice], language: String) -> [VoiceChoice] {
        let code = languageCode(language)
        return all.filter { languageCode($0.language) == code }.sorted { a, b in
            if a.quality != b.quality { return a.quality > b.quality }
            let aHome = a.language == language, bHome = b.language == language
            if aHome != bHome { return aHome }
            if a.name != b.name { return a.name < b.name }
            return a.id < b.id
        }
    }

    /// The voice to speak with: the driver's pick while it is still
    /// installed, else the most natural one. nil = the system's default
    /// voice — nothing better than a basic voice is on the device, and the
    /// default is the basic voice the system itself would choose.
    static func voice(picked: String, among all: [VoiceChoice], language: String) -> VoiceChoice? {
        let offered = choices(among: all, language: language)
        if picked != automaticID, let mine = offered.first(where: { $0.id == picked }) {
            return mine
        }
        guard let best = offered.first, best.quality > .basic else { return nil }
        return best
    }

    /// The Settings row for a voice: "Ava · US · Premium". The system adds
    /// "(Premium)" to some names itself; it is said once.
    static func label(_ choice: VoiceChoice, region: String) -> String {
        var name = choice.name
        for suffix in [" (Premium)", " (Enhanced)"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        var parts = [name]
        if !region.isEmpty { parts.append(region) }
        switch choice.quality {
        case .premium: parts.append("Premium")
        case .enhanced: parts.append("Enhanced")
        case .basic: break
        }
        return parts.joined(separator: " · ")
    }

    /// Short region names for the accents English comes in; anything else
    /// shows its region code.
    static func region(of language: String) -> String {
        let parts = language.split(separator: "-")
        guard parts.count > 1, let code = parts.last else { return "" }
        switch code {
        case "US": return "US"
        case "GB": return "UK"
        case "AU": return "Australia"
        case "IE": return "Ireland"
        case "IN": return "India"
        case "ZA": return "South Africa"
        case "CA": return "Canada"
        case "NZ": return "New Zealand"
        default: return String(code)
        }
    }

    /// The speeds the Settings slider steps through, as the speech system's
    /// rate. The middle is the rate FLOWS has always spoken at.
    static let speeds: [Float] = [0.40, 0.45, 0.50, 0.55, 0.60]
    static let normalSpeedStep = 2

    static func rate(step: Int) -> Float {
        speeds[min(max(step, 0), speeds.count - 1)]
    }

    /// Whether a line handed to the synthesizer has lost its finish report
    /// (the next line must not wait on it forever). A quiet synthesizer
    /// `grace` after the hand-over means lost — except for a picked voice
    /// that has not begun: a natural voice is loaded before its first word,
    /// and a line still loading is not a lost one. It gets `loadGrace`.
    static func lineIsLost(speaking: Bool, age: Duration, pickedVoice: Bool, began: Bool,
                           grace: Duration, loadGrace: Duration) -> Bool {
        guard !speaking else { return false }
        return age > (pickedVoice && !began ? loadGrace : grace)
    }
}
