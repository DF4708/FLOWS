// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Spoken advisories for a driver whose eyes belong on the road (the fuel
/// warning today). Deliberately NOT the crash check-in's voice: that flow
/// owns its own synthesizer and audio session because it must keep talking
/// and then listen for a reply — an advisory must never interrupt it.
@MainActor
final class DriveVoice {
    static let shared = DriveVoice()

    #if canImport(AVFoundation) && !os(macOS)
    private let synthesizer = AVSpeechSynthesizer()
    #elseif canImport(AVFoundation)
    private let synthesizer = AVSpeechSynthesizer()
    #endif

    /// The last thing said, so a repeating condition doesn't repeat itself
    /// out loud every time the range ticks down another mile.
    private var lastSpoken: String?

    private init() {}

    /// Say it once. `force` re-says an identical line (a fresh trigger for
    /// the same text), otherwise repeats are swallowed.
    func speak(_ text: String, force: Bool = false) {
        guard !text.isEmpty else { return }
        guard force || text != lastSpoken else { return }
        lastSpoken = text
        #if canImport(AVFoundation)
        // Duck rather than stop: navigation prompts and music share this
        // road, and an advisory should not kill either outright.
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        #endif
    }

    /// Clear the repeat guard (trip end, or the condition cleared) so the
    /// same advisory can be spoken again on a later trip.
    func reset() { lastSpoken = nil }
}
