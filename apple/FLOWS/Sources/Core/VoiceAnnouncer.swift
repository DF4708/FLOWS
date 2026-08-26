// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import AVFoundation
import Foundation

/// The app's own spoken voice for hands-free driving — how FLOWS speaks
/// FIRST (a faster route appeared, a warning entered the corridor). Siri
/// cannot start a conversation on its own; FLOWS announces through the
/// car speakers (Bluetooth/CarPlay route), and the driver answers through
/// the Siri phrases ("go ahead in FLOWS", "take the faster route in
/// FLOWS"). Music and radio duck under an announcement, then come back.
///
/// Distinct from CrashDetectionService's prompt voice: that one opens the
/// microphone for a spoken reply (.playAndRecord); announcements never
/// listen, so they stay on plain .playback and can't touch mic permissions.
@MainActor
final class VoiceAnnouncer {
    static let shared = VoiceAnnouncer()

    private let synthesizer = AVSpeechSynthesizer()

    /// The reply listener waits for this before opening the microphone —
    /// otherwise it would transcribe FLOWS's own question.
    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Speak one announcement (utterances queue). Callers gate on their own
    /// Settings toggle — alerts and turn-by-turn are separate switches.
    func announce(_ text: String) {
        guard !text.isEmpty else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
