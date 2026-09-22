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
///
/// Lines go to the synthesizer one at a time through a SpeechLineQueue, each
/// tagged with its message (SpeechTopic), so closing a message stops its own
/// line and nothing else: dismissing a warning used to leave it being read
/// out to the end, and stopping the synthesizer outright would also have
/// cut the turn directions queued behind it.
@MainActor
final class VoiceAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceAnnouncer()

    private let synthesizer = AVSpeechSynthesizer()
    private var queue = SpeechLineQueue<String>()
    /// The line the synthesizer holds, its place in the queue, and when it
    /// was handed over.
    private var playing: (serial: Int, utterance: AVSpeechUtterance, since: ContinuousClock.Instant)?

    /// `isSpeaking` turns true only some milliseconds after `speak()` (12 to
    /// over 100 measured), so a line just handed over is not a lost one:
    /// only a line this old that the synthesizer isn't saying lost its
    /// report.
    static let lostLineGrace: Duration = .seconds(2)

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    #if os(iOS)
    /// The user's own Personal Voice (Settings → Accessibility), used for
    /// FLOWS's speech when the toggle is on and the system granted access.
    /// nil = the default system voice. DriveVoice's advisories read it too.
    private(set) var personalVoice: AVSpeechSynthesisVoice?
    /// A pending hand-back of the audio session (releaseSessionWhenQuiet).
    private var releaseTask: Task<Void, Never>?
    #endif

    /// Set by AppModel: the crash check-in holds the audio session — it
    /// speaks, then listens, and hands the session back itself.
    var checkInHoldsSession: () -> Bool = { false }
    /// Set by AppModel: FLOWS's own sound is playing (a station on the air,
    /// the dispatch feed). Handing the session back would stop it.
    var ownAudioPlaying: () -> Bool = { false }

    /// The reply listener waits for this before opening the microphone —
    /// otherwise it would transcribe FLOWS's own question. Lines still
    /// queued count: the gap between two lines is not quiet.
    var isSpeaking: Bool { synthesizer.isSpeaking || queue.isBusy }

    /// Toggle from Settings: speak with the user's Personal Voice. The
    /// system shows its own one-time permission alert; if none is granted
    /// (or no Personal Voice exists), the default voice keeps speaking.
    func setPersonalVoiceEnabled(_ enabled: Bool) {
        #if os(iOS)
        guard enabled else {
            personalVoice = nil
            return
        }
        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { [weak self] status in
            Task { @MainActor in
                guard status == .authorized else { return }
                self?.personalVoice = AVSpeechSynthesisVoice.speechVoices()
                    .first { $0.voiceTraits.contains(.isPersonalVoice) }
            }
        }
        #endif
    }

    /// Speak one announcement (lines queue). Callers gate on their own
    /// Settings toggle — alerts and turn-by-turn are separate switches.
    /// `topic` names the message the line reads out (SpeechTopic), so
    /// closing the message can take the line back; leave it nil for a line
    /// no close should cut (a turn direction, a music reply).
    func announce(_ text: String, topic: String? = nil) {
        guard !text.isEmpty else { return }
        // The crash check-in's session and a reply being listened for are
        // left alone, as DriveVoice leaves them: switching either to
        // playback shuts its microphone, and a turn line landing in the
        // listen lost the driver's yes (or their "I need help"). Both
        // sessions play out loud, so the line is still heard.
        #if os(iOS)
        let listening = checkInHoldsSession() || VoiceReply.shared.isListening
        #else
        let listening = checkInHoldsSession()
        #endif
        if !listening { activateSpokenSession() }
        // A line whose finish report never came must not hold up every
        // later one, turn directions included.
        if queue.isBusy, !synthesizer.isSpeaking,
           playing.map({ ContinuousClock.now - $0.since > Self.lostLineGrace }) ?? true {
            playing = nil
            if let next = queue.abandonCurrent() { start(next) }
        }
        if let now = queue.enqueue(text, topic: topic) { start(now) }
    }

    /// Take back a message's lines: the one being read stops mid-sentence,
    /// queued ones never start. Other lines carry on.
    func cancel(topic: String) {
        let result = queue.cancel(topic: topic)
        if result.stopCurrent {
            // The synthesizer holds only this line; its cancel report starts
            // the next one.
            synthesizer.stopSpeaking(at: .immediate)
        }
        if result.stopCurrent || result.removed > 0 {
            FlowsDiag.log(.info, "voice", "cancel \(topic): playing=\(result.stopCurrent) "
                          + "queued=\(result.removed)")
        }
    }

    func stop() {
        queue.cancelAll()
        playing = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// The session every spoken line plays in: plain playback (lines never
    /// listen), with the driver's music and radio ducked under it.
    func activateSpokenSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    /// Hand the audio session back once FLOWS has nothing left to say or
    /// hear, so music ducked under a line comes back up. Nothing did: the
    /// driver's music stayed ducked for the rest of the drive after the
    /// first turn direction (the crash voice learned this first). Not from
    /// under FLOWS's own sound or the crash check-in, which still need it.
    func releaseSessionWhenQuiet() {
        #if os(iOS)
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            // A beat for the synthesizer to let go of the output, and for a
            // line queued right behind this one to start.
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, !self.isSpeaking,
                  !DriveVoice.shared.isSpeaking, !VoiceReply.shared.isListening,
                  !self.checkInHoldsSession(), !self.ownAudioPlaying() else { return }
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    private func start(_ entry: SpeechLineQueue<String>.Entry) {
        let utterance = AVSpeechUtterance(string: entry.line)
        utterance.rate = 0.5
        #if os(iOS)
        if let personalVoice { utterance.voice = personalVoice }
        #endif
        playing = (entry.serial, utterance, .now)
        synthesizer.speak(utterance)
    }

    /// A line finished or was stopped: the next one starts. Only the line's
    /// identity crosses to the main actor.
    private func lineEnded(_ id: ObjectIdentifier) {
        guard let current = playing, ObjectIdentifier(current.utterance) == id else { return }
        playing = nil
        if let next = queue.finished(serial: current.serial) {
            start(next)
        } else {
            releaseSessionWhenQuiet()
        }
    }

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
