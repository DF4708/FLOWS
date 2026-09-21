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
///
/// Like VoiceAnnouncer, it hands the synthesizer one line at a time from a
/// SpeechLineQueue, so closing the fuel warning takes its line back without
/// cutting anything else.
@MainActor
final class DriveVoice: NSObject {
    static let shared = DriveVoice()

    #if canImport(AVFoundation)
    private let synthesizer = AVSpeechSynthesizer()
    private var playing: (serial: Int, utterance: AVSpeechUtterance, since: ContinuousClock.Instant)?
    #endif
    private var queue = SpeechLineQueue<String>()

    /// The last thing said, so a repeating condition doesn't repeat itself
    /// out loud every time the range ticks down another mile.
    private var lastSpoken: String?

    private override init() {
        super.init()
        #if canImport(AVFoundation)
        synthesizer.delegate = self
        #endif
    }

    /// Say it once. `force` re-says an identical line (a fresh trigger for
    /// the same text), otherwise repeats are swallowed. `topic` names the
    /// message the line reads out (SpeechTopic), so closing it can take the
    /// line back.
    func speak(_ text: String, force: Bool = false, topic: String? = nil) {
        guard !text.isEmpty else { return }
        guard force || text != lastSpoken else { return }
        lastSpoken = text
        #if canImport(AVFoundation)
        // A line whose finish report never came must not hold up the rest —
        // but a line just handed over isn't speaking yet either
        // (VoiceAnnouncer.lostLineGrace).
        if queue.isBusy, !synthesizer.isSpeaking,
           playing.map({ ContinuousClock.now - $0.since > VoiceAnnouncer.lostLineGrace }) ?? true {
            playing = nil
            if let next = queue.abandonCurrent() { start(next) }
        }
        #endif
        if let now = queue.enqueue(text, topic: topic) { start(now) }
    }

    /// Take back a message's lines: the one being read stops, queued ones
    /// never start.
    func cancel(topic: String) {
        let result = queue.cancel(topic: topic)
        #if canImport(AVFoundation)
        if result.stopCurrent { synthesizer.stopSpeaking(at: .immediate) }
        #endif
        if result.stopCurrent || result.removed > 0 {
            FlowsDiag.log(.info, "voice", "cancel \(topic): playing=\(result.stopCurrent) "
                          + "queued=\(result.removed)")
        }
    }

    /// Clear the repeat guard (trip end, or the condition cleared) so the
    /// same advisory can be spoken again on a later trip.
    func reset() { lastSpoken = nil }

    private func start(_ entry: SpeechLineQueue<String>.Entry) {
        #if canImport(AVFoundation)
        // Duck rather than stop: navigation prompts and music share this
        // road, and an advisory should not kill either outright.
        let utterance = AVSpeechUtterance(string: entry.line)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        playing = (entry.serial, utterance, .now)
        synthesizer.speak(utterance)
        #endif
    }

    #if canImport(AVFoundation)
    private func lineEnded(_ id: ObjectIdentifier) {
        guard let current = playing, ObjectIdentifier(current.utterance) == id else { return }
        playing = nil
        if let next = queue.finished(serial: current.serial) { start(next) }
    }
    #endif
}

#if canImport(AVFoundation)
extension DriveVoice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.lineEnded(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.lineEnded(id) }
    }
}
#endif
