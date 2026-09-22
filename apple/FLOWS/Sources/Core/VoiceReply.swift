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

/// A word list the Rust core owns (yes and no words, back-words, directory
/// genres, mirror countries, a radio kind's tags), read once: its texts come
/// back joined, with each text's UTF-8 length.
enum RustWordList {
    static func words(_ list: UInt16) -> [String] {
        let bytes = Array(flows_tags_list_text(list).text.utf8)
        var at = 0
        return Array(flows_tags_list_lengths(list)).map { length in
            let end = min(at + Int(length), bytes.count)
            defer { at = end }
            return String(decoding: bytes[at..<end], as: UTF8.self)
        }
    }
}

/// Plain spoken YES/NO, interpreted — for FLOWS's own prompted questions
/// ("A faster route is ready — say yes to take it"). Separate from the
/// crash check-in's vocabulary on purpose: there "okay" means "I'm okay,
/// stand down"; here "okay" is an agreement.
enum YesNoWords {
    /// nil = neither (say nothing / unintelligible — never guessed).
    static func interpret(_ transcript: String) -> Bool? {
        // "No" wins a mixed reply: "yeah, no" and "no thanks" are refusals.
        // A phrase matches anywhere, a single word only as a whole word
        // (rust/flows-core tags_and_replies.rs).
        switch flows_tags_interpret_yes_no(transcript) {
        case 1: return true
        case 0: return false
        default: return nil
        }
    }

    static let yesWords = RustWordList.words(0)
    static let noWords = RustWordList.words(1)
}

/// Routing words for the in-app mic (no "Hey Siri" needed) — pure so the
/// radio mic's weather branch is pinned by tests.
enum VoiceCommands {
    /// "the weather radio", "NOAA", "weather channel" → the NOAA relay
    /// path instead of an AM/FM directory search.
    static func wantsWeatherRadio(_ transcript: String) -> Bool {
        flows_tags_wants_weather_radio(transcript)
    }
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
        // Longest name wins so "fast food" can't lose to a shorter overlap.
        let outcome = RustTextColumn(options).with { joined, lengths, _ in
            flows_tags_choose(reply, joined, lengths, Int64(options.count))
        }
        switch (outcome.code, outcome.index) {
        case (0, let i): return .picked(Int(i))
        case (3, _): return .declined
        default: return .unclear
        }
    }

    /// Words that mean "back up a step" mid-dialogue ("go back", "start
    /// over", "something different") — checked as whole words/phrases.
    static let backWords = RustWordList.words(2)

    /// The place-offer step of the stop dialogue, which can also hear a
    /// CHANGE OF MIND: naming one of the offered places picks it, naming a
    /// cuisine switches the earlier answer outright ("actually, Mexican"),
    /// back-words return to the cuisine question, yes takes the first
    /// offer, no ends the dialogue with the list on screen.
    enum PlaceOutcome: Equatable {
        case picked(Int)          // index into the offered places
        case switchCuisine(Int)   // index into the cuisine list
        case backToCuisine
        case declined
        case unclear
    }

    static func placeReply(_ reply: String, places: [String],
                           cuisines: [String]) -> PlaceOutcome {
        // A named cuisine is the clearest change-of-mind signal — "actually
        // I want Mexican" needs no back-word (rust/flows-core tags_and_replies.rs).
        let outcome = RustTextColumn(places).with { placeText, placeLengths, _ in
            RustTextColumn(cuisines).with { cuisineText, cuisineLengths, _ in
                flows_tags_place_reply(reply, placeText, placeLengths, Int64(places.count),
                                       cuisineText, cuisineLengths, Int64(cuisines.count))
            }
        }
        switch (outcome.code, outcome.index) {
        case (0, let i): return .picked(Int(i))
        case (1, let i): return .switchCuisine(Int(i))
        case (2, _): return .backToCuisine
        case (3, _): return .declined
        default: return .unclear
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
    /// Dictation mode (the in-app mic): capture the words instead of
    /// interpreting yes/no; the transcript is delivered at window end.
    private var onTranscript: ((String?) -> Void)?
    private var lastHeard = ""
    /// Listens asked for whose microphone hasn't opened yet (waiting on
    /// permission, or on FLOWS's own question to end).
    private var waitingToListen = 0

    /// From the ask until the microphone closes. The spoken lines don't
    /// hand the audio session back meanwhile: the music would come up
    /// between the question and the listening.
    var isListening: Bool { waitingToListen > 0 || audioEngine != nil }

    /// Wait for the announcement to finish, then listen ~`seconds` for a
    /// yes/no. Calls back exactly once on the main actor; nil = no clear
    /// answer (the on-screen chip stays, nothing is guessed).
    func listenAfterSpeech(seconds: Double = 6.0,
                           onAnswer: @escaping (Bool?) -> Void) {
        waitingToListen += 1
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in
                guard let self else { return }
                guard auth == .authorized else {
                    self.waitingToListen -= 1
                    onAnswer(nil)
                    return
                }
                var waited = 0
                while VoiceAnnouncer.shared.isSpeaking, waited < 100 {
                    try? await Task.sleep(for: .milliseconds(100)); waited += 1
                }
                self.waitingToListen -= 1
                self.begin(seconds: seconds, onAnswer: onAnswer)
            }
        }
    }

    /// The in-app mic (music ask, station ask): listen ~`seconds` and hand
    /// back what was SAID — final transcript, or the last partial when the
    /// window closes first. nil = permission refused or nothing heard.
    func listenForDictation(seconds: Double = 5.0,
                            onTranscript: @escaping (String?) -> Void) {
        waitingToListen += 1
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in
                guard let self else { return }
                self.waitingToListen -= 1
                guard auth == .authorized else { onTranscript(nil); return }
                self.begin(seconds: seconds, onAnswer: nil,
                           onTranscript: onTranscript)
            }
        }
    }

    private func begin(seconds: Double, onAnswer: ((Bool?) -> Void)?,
                       onTranscript: ((String?) -> Void)? = nil) {
        guard let recognizer, recognizer.isAvailable else {
            onAnswer?(nil)
            onTranscript?(nil)
            return
        }
        teardown()
        self.onAnswer = onAnswer
        self.onTranscript = onTranscript
        lastHeard = ""
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
        // A "yes"/"no", or "I'm okay" after a crash, is recognized on the
        // device whenever the device can. Without this line every reply
        // went to Apple's server recognizer by default — audio from inside
        // the car, at the worst moment, for a one-word answer. Server
        // recognition remains the fallback only where on-device is not
        // supported for the locale.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
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
            let isFinal = result.isFinal
            Task { @MainActor in
                guard let self, !self.answered else { return }
                if self.onTranscript != nil {
                    // Dictation: keep the best-so-far; a FINAL result ends
                    // the window early with the settled words.
                    self.lastHeard = transcript
                    if isFinal { self.finish(with: nil) }
                } else if let answer = YesNoWords.interpret(transcript) {
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
        let yesNo = onAnswer
        let dictation = onTranscript
        let heard = lastHeard.trimmingCharacters(in: .whitespacesAndNewlines)
        onAnswer = nil
        onTranscript = nil
        teardown()
        yesNo?(answer)
        dictation?(heard.isEmpty ? nil : heard)
        // After the answer is acted on, so music it just started (a music
        // ask) comes up from under the listening session too.
        VoiceAnnouncer.shared.releaseSessionWhenQuiet()
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
    func listenForDictation(seconds: Double = 5.0,
                            onTranscript: @escaping (String?) -> Void) {
        onTranscript(nil)
    }
}
#endif
