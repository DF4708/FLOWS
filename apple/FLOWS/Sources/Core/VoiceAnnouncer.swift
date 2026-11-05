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
    /// The line the synthesizer holds, its place in the queue, when it was
    /// handed over, and whether its first word has been reported.
    private var playing: (serial: Int, utterance: AVSpeechUtterance,
                          since: ContinuousClock.Instant, began: Bool)?

    /// `isSpeaking` turns true only some milliseconds after `speak()` (12 to
    /// over 100 measured), so a line just handed over is not a lost one:
    /// only a line this old that the synthesizer isn't saying lost its
    /// report.
    static let lostLineGrace: Duration = .seconds(2)
    /// A picked voice is loaded before its first word, so its line gets this
    /// long to begin (SpeechVoiceRules.lineIsLost). The default voice keeps
    /// `lostLineGrace`.
    static let voiceLoadGrace: Duration = .seconds(6)

    /// The voice lines are spoken with — the driver's pick in Settings, or
    /// the most natural one installed (SpeechVoiceRules.voice). nil = the
    /// system's default voice.
    private(set) var spokenVoice: AVSpeechSynthesisVoice?
    private var spokenRate = SpeechVoiceRules.rate(step: SpeechVoiceRules.normalSpeedStep)

    /// Set by AppModel, at launch and when the pick or the installed voices
    /// change. An identifier the system no longer knows leaves the default.
    func setVoice(id: String?) {
        spokenVoice = id.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
    }

    func setSpeed(step: Int) {
        spokenRate = SpeechVoiceRules.rate(step: step)
    }

    /// Every voice on the device FLOWS could speak with. Joke voices are
    /// left out, and the Personal Voice has its own switch. The system's
    /// list is slow to read the first time, so this is called off the main
    /// thread.
    nonisolated static func installedVoices() -> [VoiceChoice] {
        AVSpeechSynthesisVoice.speechVoices().compactMap { voice in
            guard !voice.voiceTraits.contains(.isNoveltyVoice),
                  !voice.voiceTraits.contains(.isPersonalVoice) else { return nil }
            let quality: VoiceChoice.Quality
            switch voice.quality {
            case .premium: quality = .premium
            case .enhanced: quality = .enhanced
            default: quality = .basic
            }
            return VoiceChoice(id: voice.identifier, name: voice.name,
                               language: voice.language, quality: quality)
        }
    }

    /// The language FLOWS's voices are picked in (its lines are English).
    nonisolated static var spokenLanguage: String {
        SpeechVoiceRules.spokenLanguage(device: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    /// Posted by the system when a voice is downloaded or removed.
    nonisolated static var voicesChanged: Notification.Name {
        AVSpeechSynthesizer.availableVoicesDidChangeNotification
    }

    private func isLost(_ line: (serial: Int, utterance: AVSpeechUtterance,
                                 since: ContinuousClock.Instant, began: Bool)) -> Bool {
        SpeechVoiceRules.lineIsLost(
            speaking: synthesizer.isSpeaking, age: ContinuousClock.now - line.since,
            pickedVoice: line.utterance.voice != nil, began: line.began,
            grace: Self.lostLineGrace, loadGrace: Self.voiceLoadGrace)
    }

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    #if os(iOS)
    /// The user's own Personal Voice (Settings → Accessibility), used for
    /// FLOWS's speech when the toggle is on and the system granted access.
    /// nil = the default system voice. DriveVoice's advisories are spoken here too.
    private(set) var personalVoice: AVSpeechSynthesisVoice?
    /// A pending hand-back of the audio session (releaseSessionWhenQuiet).
    private var releaseTask: Task<Void, Never>?
    #endif

    /// Set by AppModel: the crash check-in holds the audio session — it
    /// speaks, then listens, and hands the session back itself.
    var checkInHoldsSession: () -> Bool = { false }
    /// Set by AppModel: the crash check-in is ASKING (its question, then its
    /// microphone) or reading its report. Nothing else speaks meanwhile: a
    /// turn line or a warning over the question buried it, and over the
    /// listen window it was heard as the driver's reply. Warnings wait in
    /// `held`; other lines are let go.
    var checkInOwnsVoice: () -> Bool = { false }
    private var held = HeldWarnings()
    private var heldWatch: Task<Void, Never>?

    /// Say the held warnings once the check-in has been quiet for a moment
    /// (its own "Okay. Glad you're safe." included).
    private func sayHeldWhenQuiet() {
        guard heldWatch == nil else { return }
        heldWatch = Task { [weak self] in
            var quiet = 0
            while !Task.isCancelled, quiet < 2 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                quiet = self.checkInOwnsVoice() ? 0 : quiet + 1
            }
            guard let self, !Task.isCancelled else { return }
            self.heldWatch = nil
            for line in self.held.drain() { self.announce(line.text, topic: line.topic) }
        }
    }
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
        if checkInOwnsVoice() {
            // A warning waits for the check-in to fall quiet; it used to be
            // dropped, and a warning is only said once.
            if held.hold(text, topic: topic) { sayHeldWhenQuiet() }
            return
        }
        // The crash check-in's session and a reply being listened for are
        // left alone: switching either to
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
        if queue.isBusy, !synthesizer.isSpeaking, playing.map(isLost) ?? true {
            playing = nil
            if let next = queue.abandonCurrent() { start(next) }
        }
        // A newer turn direction makes any still waiting stale.
        if topic == SpeechTopic.turn { _ = queue.cancel(topic: SpeechTopic.turn) }
        if SpeechTopic.isUrgent(topic) {
            if let now = queue.enqueueFirst(text, topic: topic) {
                start(now)
            } else if let current = queue.current, !SpeechTopic.isUrgent(current.topic) {
                // Over any other line: it stops, and its cancel report
                // starts the warning (first in line); it is said again
                // after, unless it was a turn direction.
                queue.requeueCurrentBehindWarnings()
                synthesizer.stopSpeaking(at: .immediate)
            }
            return
        }
        if let now = queue.enqueue(text, topic: topic) { start(now) }
    }

    /// Set by AppModel: turn FLOWS's own radio down while a line plays, up
    /// after. `.duckOthers` lowers only other apps; the station is FLOWS's
    /// own player, and a warning was read at the radio's full volume.
    var duckOwnAudio: (Bool) -> Void = { _ in }

    /// Take back a message's lines: the one being read stops mid-sentence,
    /// queued ones never start. Other lines carry on.
    func cancel(topic: String) {
        held.cancel(topic: topic)
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
        lostLineWatch?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        duckOwnAudio(false)
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
                  !VoiceReply.shared.isListening,
                  !self.checkInHoldsSession(), !self.ownAudioPlaying() else { return }
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    private func start(_ entry: SpeechLineQueue<String>.Entry) {
        let utterance = AVSpeechUtterance(string: entry.line)
        utterance.rate = spokenRate
        utterance.voice = spokenVoice
        #if os(iOS)
        if let personalVoice { utterance.voice = personalVoice }
        #endif
        playing = (entry.serial, utterance, .now, false)
        duckOwnAudio(true)
        synthesizer.speak(utterance)
        watchForLostReport(serial: entry.serial)
    }

    /// Watches the line just handed over: one whose finish report never
    /// comes is let go once the synthesizer is quiet. The radio came back up
    /// only on a report, so a lost one left the station at a quarter volume
    /// until FLOWS next spoke — off a trip, possibly for good.
    private var lostLineWatch: Task<Void, Never>?
    private func watchForLostReport(serial: Int) {
        lostLineWatch?.cancel()
        lostLineWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.lostLineGrace)
                guard let self, !Task.isCancelled,
                      let current = self.playing, current.serial == serial else { return }
                if self.isLost(current) {
                    self.lineEnded(ObjectIdentifier(current.utterance))
                    return
                }
            }
        }
    }

    /// A line finished or was stopped: the next one starts. Only the line's
    /// identity crosses to the main actor.
    private func lineEnded(_ id: ObjectIdentifier) {
        guard let current = playing, ObjectIdentifier(current.utterance) == id else { return }
        playing = nil
        if let next = queue.finished(serial: current.serial) {
            start(next)
        } else {
            duckOwnAudio(false)
            releaseSessionWhenQuiet()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            if let current = self.playing, ObjectIdentifier(current.utterance) == id {
                self.playing?.began = true
            }
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
