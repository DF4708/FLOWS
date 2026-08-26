// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import AVFoundation
import Foundation
#if os(iOS)
import Speech
#endif

/// Plain spoken YES/NO, interpreted — for FLOWS's own prompted questions
/// ("A faster route is ready — say yes to take it"). Separate from the
/// crash check-in's vocabulary on purpose: there "okay" means "I'm okay,
/// stand down"; here "okay" is an agreement.
enum YesNoWords {
    /// nil = neither (say nothing / unintelligible — never guessed).
    static func interpret(_ transcript: String) -> Bool? {
        let lower = transcript.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init))
        func matches(_ vocab: [String]) -> Bool {
            vocab.contains { entry in
                entry.contains(" ") ? lower.contains(entry) : words.contains(entry)
            }
        }
        // "No" wins a mixed reply: "yeah, no" and "no thanks" are refusals.
        if matches(noWords) { return false }
        if matches(yesWords) { return true }
        return nil
    }

    static let yesWords = ["yes", "yeah", "yep", "yup", "sure", "okay", "ok",
                           "go ahead", "take it", "do it", "please", "affirmative"]
    static let noWords = ["no", "nope", "nah", "cancel", "don't", "negative",
                          "stay", "keep this route", "not now", "never mind"]
}

/// Match a spoken reply against the options FLOWS just offered out loud
/// ("Does Taco Bell or El Rays work for you?"): naming an option picks it
/// (the name's words must appear as standalone words in the reply — "yes,
/// let's go to Taco Bell" picks Taco Bell), a bare yes takes the FIRST
/// offer, a no declines, anything else reads as unclear — never guessed.
enum VoicePick {
    enum Outcome: Equatable {
        case picked(Int)   // index into the offered options
        case declined
        case unclear
    }

    static func choose(reply: String, options: [String]) -> Outcome {
        let named = options.enumerated().filter {
            BrandKnowledge.askedName($0.element, matches: reply)
        }
        // Longest name wins so "fast food" can't lose to a shorter overlap.
        if let best = named.max(by: { $0.element.count < $1.element.count }) {
            return .picked(best.offset)
        }
        switch YesNoWords.interpret(reply) {
        case true?: return .picked(0)
        case false?: return .declined
        case nil: return .unclear
        }
    }
}

#if os(iOS)
/// One-shot listener for a short spoken answer AFTER FLOWS asks a question
/// out loud — the same guarded microphone pattern as the crash check-in
/// (wait out our own utterance, refuse a record-incapable session, bounded
/// window, one callback). Used for reroute offers; the crash flow keeps
/// its own listener and vocabulary.
@MainActor
final class VoiceReply {
    static let shared = VoiceReply()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var onAnswer: ((Bool?) -> Void)?
    private var answered = false

    /// Wait for the announcement to finish, then listen ~`seconds` for a
    /// yes/no. Calls back exactly once on the main actor; nil = no clear
    /// answer (the on-screen chip stays, nothing is guessed).
    func listenAfterSpeech(seconds: Double = 6.0,
                           onAnswer: @escaping (Bool?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in
                guard let self else { return }
                guard auth == .authorized else { onAnswer(nil); return }
                var waited = 0
                while VoiceAnnouncer.shared.isSpeaking, waited < 100 {
                    try? await Task.sleep(for: .milliseconds(100)); waited += 1
                }
                self.begin(seconds: seconds, onAnswer: onAnswer)
            }
        }
    }

    private func begin(seconds: Double, onAnswer: @escaping (Bool?) -> Void) {
        guard let recognizer, recognizer.isAvailable else { onAnswer(nil); return }
        teardown()
        self.onAnswer = onAnswer
        answered = false
        // Record-capable session for the tap; the radio/music session is
        // re-established by whichever playback starts next.
        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .voiceChat,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try? AVAudioSession.sharedInstance().setActive(true)
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Defensive: a record-incapable (0 Hz) session must not installTap —
        // it raises an uncatchable NSException (the crash-service lesson).
        guard format.sampleRate > 0, format.channelCount > 0 else {
            finish(with: nil)
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try? engine.start()
        audioEngine = engine
        recognitionRequest = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let result else { return }
            let transcript = result.bestTranscription.formattedString
            Task { @MainActor in
                guard let self, !self.answered else { return }
                if let answer = YesNoWords.interpret(transcript) {
                    self.finish(with: answer)
                }
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await MainActor.run { self?.finish(with: nil) }
        }
    }

    private func finish(with answer: Bool?) {
        guard !answered else { return }
        answered = true
        let callback = onAnswer
        onAnswer = nil
        teardown()
        callback?(answer)
    }

    private func teardown() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }
}
#else
/// macOS: prompts stay on screen — no microphone reply loop.
@MainActor
final class VoiceReply {
    static let shared = VoiceReply()
    func listenAfterSpeech(seconds: Double = 6.0,
                           onAnswer: @escaping (Bool?) -> Void) {
        onAnswer(nil)
    }
}
#endif
