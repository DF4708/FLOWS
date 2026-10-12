// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Spoken advisories for a driver whose eyes belong on the road (the fuel
/// warning, the camera ahead). Deliberately NOT the crash check-in's voice:
/// that flow owns its own synthesizer and audio session because it must keep
/// talking and then listen for a reply — an advisory must never interrupt it.
///
/// Its lines are spoken by VoiceAnnouncer, in the one queue every FLOWS line
/// shares. It had a synthesizer of its own, and two voices spoke at once: a
/// "red light camera ahead" over an imminent warning garbled both. What it
/// keeps is its repeat guard; closing a message (its topic) still takes its
/// line back without cutting anything else.
@MainActor
final class DriveVoice {
    static let shared = DriveVoice()

    /// The last thing said, so a repeating condition doesn't repeat itself
    /// out loud every time the range ticks down another mile.
    private var lastSpoken: String?

    private init() {}

    /// Say it once. `force` re-says an identical line (a fresh trigger for
    /// the same text), otherwise repeats are swallowed. `topic` names the
    /// message the line reads out (SpeechTopic), so closing it can take the
    /// line back.
    func speak(_ text: String, force: Bool = false, topic: String? = nil) {
        guard !text.isEmpty else { return }
        guard force || text != lastSpoken else { return }
        lastSpoken = text
        VoiceAnnouncer.shared.announce(text, topic: topic)
    }

    /// Take back a message's lines: the one being read stops, queued ones
    /// never start.
    func cancel(topic: String) {
        VoiceAnnouncer.shared.cancel(topic: topic)
    }

    /// Clear the repeat guard (trip end, or the condition cleared) so the
    /// same advisory can be spoken again on a later trip.
    func reset() { lastSpoken = nil }

    /// A FLOWS line is playing or queued.
    var isSpeaking: Bool { VoiceAnnouncer.shared.isSpeaking }
}
