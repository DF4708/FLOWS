// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation
#if os(iOS)
import AVFoundation
import CoreMotion
import Speech
import UIKit
#endif

/// Inertial crash detection with a PERSISTENT voice check-in.
///
/// While navigating, the accelerometer watches for a sustained impact
/// (CrashLogic.impactGForce). On a hit, FLOWS speaks "Do you need
/// assistance?" and LISTENS for a spoken reply — and keeps re-asking every
/// 20 s until the driver answers or physically dismisses the card, because
/// an injured driver may not respond on the first attempt.
///
/// On "yes" (spoken or tapped), the assisted flow runs — within iOS's hard
/// platform rules (see CrashLogic's header): one-tap 911 call via the
/// system's emergency UI, a PREFILLED text report to the emergency contact
/// (GPS, address, time, vehicle, medical notes), the report spoken aloud
/// for relaying to the 911 operator, then a one-tap call to the contact.
@MainActor
final class CrashDetectionService: ObservableObject {
    enum State: Equatable {
        case idle
        /// Impact sensed — check-in loop running (spoken prompt repeating).
        case checkingIn(attempt: Int)
        /// Driver asked for help — the assisted-call card is up.
        case assisting
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var impactTime: Date?

    /// DEMO (FLOWS_DEMO=drive): show the check-in card with no impact, no
    /// spoken loop and no timer, so the layout check can see where it sits.
    /// "I'm OK" clears it as usual.
    func showCheckInForLayoutDemo() {
        state = .checkingIn(attempt: 1)
    }

    /// Set by AppModel: where we are + what we drive + medical notes.
    var context: () -> (coordinate: CLLocationCoordinate2D?,
                        vehicle: VehicleProfile?,
                        medicalNotes: String?) = { (nil, nil, nil) }

    /// Set by AppModel: whether an emergency contact's number is saved — the
    /// card offers "Text report" and "Call contact" only then, so the voice
    /// may only mention them then.
    var hasEmergencyContact: () -> Bool = { false }

    /// Set by AppModel: the MOTION evidence that separates a crash from a
    /// thrill ride — how fast the vehicle was going just before, how fast it
    /// is now (NaN when the latest fix has no speed: unknown is not
    /// stopped), and how far it is from the road corridor being driven
    /// (nil when unknown). See CrashLogic.isCrash.
    var motionEvidence: () -> (speedBeforeMps: Double,
                               speedAfterMps: Double,
                               metersFromRoad: Double?) = { (0, 0, nil) }

    #if os(iOS)
    private let motion = CMMotionManager()
    private let synthesizer = AVSpeechSynthesizer()
    private var checkInTask: Task<Void, Never>?
    private var recognizer: SFSpeechRecognizer? = SFSpeechRecognizer()
    private var audioEngine: AVAudioEngine?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private static let accelWindowSize = 25
    /// Bumped every begin(); an impact hop carries the generation it was
    /// enqueued under and drops itself if end() (or a new begin()) has since
    /// moved on. Moving samples off the main queue removed the mutual
    /// exclusion end() used to have — a sample detected on motionQueue can
    /// enqueue a MainActor Task that would otherwise run AFTER end() and fire
    /// a spurious post-trip crash check-in (state == .idle can't tell
    /// "never started" from "just torn down").
    private var monitorGeneration = 0

    /// 50 Hz samples land HERE, not on the main queue — a multi-hour drive
    /// is hours of per-sample main-thread wakeups otherwise. Serial, utility
    /// QoS; only a detected impact (rare) hops to the MainActor.
    private static let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    static let isAvailable = true

    func begin() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        monitorGeneration += 1
        let generation = monitorGeneration
        motion.accelerometerUpdateInterval = 1.0 / 50.0
        // Rolling ~0.5 s (25 samples @ 50 Hz) of |acceleration| magnitudes, so
        // an impact is judged over a window (hard spike, or a corroborated
        // moderate one) rather than a single trigger-happy sample — see
        // CrashLogic.isImpact. Confined to the serial motionQueue: the
        // MainActor never sees per-sample traffic.
        var window: [Double] = []
        motion.startAccelerometerUpdates(to: Self.motionQueue) { [weak self] data, _ in
            guard self != nil, let data else { return }
            let g = sqrt(data.acceleration.x * data.acceleration.x
                         + data.acceleration.y * data.acceleration.y
                         + data.acceleration.z * data.acceleration.z)
            window.append(g)
            if window.count > Self.accelWindowSize {
                window.removeFirst(window.count - Self.accelWindowSize)
            }
            if CrashLogic.isImpact(window: window) {
                let snapshot = window
                window.removeAll(keepingCapacity: true) // consume — don't re-fire this event
                Task { @MainActor [weak self] in
                    // Drop a hop enqueued before end()/a new begin(): its
                    // generation is stale, so it can't fire a check-in after
                    // the trip it belonged to has ended.
                    guard let self, self.monitorGeneration == generation,
                          self.state == .idle else { return }
                    await self.confirmCrash(window: snapshot, generation: generation)
                }
            }
        }
    }

    func end() {
        motion.stopAccelerometerUpdates()
        monitorGeneration += 1   // invalidate any impact hop still in flight
        addressLookup += 1       // and any address lookup
        reverseGeocodedAddress = nil
        stopCheckIn()
        synthesizer.stopSpeaking(at: .immediate)   // the trip is over: so is the check-in's voice
        state = .idle
        releaseAudioSessionWhenQuiet()
    }

    /// The Settings switch went off mid-trip: no new impact is sensed, and
    /// a check-in question stops with it. A help card the driver already
    /// asked for stays up until they close it. Only a check-in goes through
    /// end(): between crashes there is no crash voice to stop, and end()'s
    /// hand-back of the audio session cut a station on the air or a line
    /// being read.
    func stopWatching() {
        if case .checkingIn = state { end(); return }
        motion.stopAccelerometerUpdates()
        monitorGeneration += 1   // an impact hop still in flight is dropped
    }

    /// Speech and microphone for the spoken reply, asked ahead of any crash:
    /// AppModel calls this at the first GO with crash detection on. Asked
    /// only after an impact, the system's two dialogs landed on top of "Do
    /// you need assistance?". Each is asked only while still undecided.
    static func askReplyPermissionsIfNeeded() async {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in done.resume() }
            }
        }
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
    }

    /// The g-force only opened the question. A crash also means a road-speed
    /// vehicle ON A ROAD suddenly stopped (CrashLogic.isCrash), and GPS cannot
    /// say "stopped" at the instant of the bang: its latest fix is up to a
    /// second old and still reads the speed before the hit. Judged at the
    /// impact itself, a real crash failed the stop test. So the speed before
    /// the hit and the road check are taken now, and the stop is looked for in
    /// the fixes of the next few seconds (CrashLogic.stopSettleSeconds). A
    /// pothole at speed never loses its speed, so it still never trips it —
    /// and a fix with no speed (Wi-Fi or cell, GPS reacquiring) reads NaN,
    /// which isCrash never takes for a stop. The price: a crash whose every
    /// fix in the window lacks a speed goes unasked.
    private func confirmCrash(window: [Double], generation: Int) async {
        let atImpact = motionEvidence()
        let deadline = Date().addingTimeInterval(CrashLogic.stopSettleSeconds)
        while Date() < deadline {
            guard monitorGeneration == generation, state == .idle else { return }
            if CrashLogic.isCrash(CrashLogic.ImpactEvidence(
                window: window,
                speedBeforeMps: atImpact.speedBeforeMps,
                speedAfterMps: motionEvidence().speedAfterMps,
                metersFromRoad: atImpact.metersFromRoad)) {
                impactDetected()
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func impactDetected() {
        impactTime = Date()
        // Where the crash happened, not where the drive began: the address
        // was resolved once at trip start, and the report sent the driver's
        // contact to the start of the trip.
        reverseGeocodedAddress = nil
        resolveAddress()
        state = .checkingIn(attempt: 1)
        // Re-ask FOREVER until answered or physically dismissed — a
        // concussed driver may surface minutes later.
        checkInTask = Task { [weak self] in
            var attempt = 1
            while !Task.isCancelled {
                guard let self, case .checkingIn = self.state else { return }
                self.state = .checkingIn(attempt: attempt)
                self.speak("FLOWS detected a possible crash. Do you need assistance? "
                           + "Say yes to get help, or say I'm okay.")
                self.listenForReply(seconds: 10)
                try? await Task.sleep(for: .seconds(CrashLogic.checkInRepeatSeconds))
                attempt += 1
            }
        }
    }

    /// Driver (or a spoken "yes") asked for help.
    func requestAssistance() {
        stopCheckIn()
        state = .assisting
        let report = emergencyReport()
        // Apps cannot place a call on their own: the driver taps Call 911 on
        // the card, and iOS dials. The voice used to say "Calling 9 1 1" while
        // nothing was being called, and promised a report for a contact the
        // driver may never have saved (the card then has no send button).
        let contact = hasEmergencyContact()
            ? "A report is ready to send to your emergency contact. " : ""
        speak("Tap Call 9 1 1 on the screen to call for help. " + contact
              + "The report reads: " + report)
    }

    /// Physical dismissal or a spoken "I'm okay" — stand down.
    func standDown() {
        stopCheckIn()
        // "I'm OK" or Done cuts the question or the report being read; only
        // the short reply follows. The stop stays out of stopCheckIn():
        // "Get help" runs it too, and the report must never be lost.
        synthesizer.stopSpeaking(at: .immediate)
        state = .idle
        impactTime = nil
        speak("Okay. Glad you're safe.")
        releaseAudioSessionWhenQuiet()
    }

    /// After the last utterance, hand the audio session back — the check-in
    /// activates it with .duckOthers, and without an explicit deactivation
    /// the driver's music stays ducked for the rest of the drive.
    private func releaseAudioSessionWhenQuiet() {
        Task { @MainActor [weak self] in
            var waited = 0
            while self?.synthesizer.isSpeaking == true, waited < 100 {
                try? await Task.sleep(for: .milliseconds(100)); waited += 1
            }
            guard let self, self.state == .idle, self.audioEngine == nil else { return }
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
        }
    }

    /// The templated report (also prefilled into the contact text).
    func emergencyReport() -> String {
        let ctx = context()
        return CrashLogic.emergencyMessage(
            latitude: ctx.coordinate?.latitude,
            longitude: ctx.coordinate?.longitude,
            address: reverseGeocodedAddress,
            time: impactTime ?? Date(),
            vehicle: ctx.vehicle,
            medicalNotes: ctx.medicalNotes)
    }

    private(set) var reverseGeocodedAddress: String?
    /// Bumped by every lookup (and at trip end): only the newest may write.
    /// A slow lookup from an earlier check-in could otherwise land after a
    /// later crash and put the wrong place in its report.
    private var addressLookup = 0

    func resolveAddress() {
        addressLookup += 1
        let lookup = addressLookup
        guard let coord = context().coordinate else { return }
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            Task { @MainActor in
                guard let self, self.addressLookup == lookup,
                      let pm = placemarks?.first else { return }
                self.reverseGeocodedAddress = [pm.name, pm.locality, pm.administrativeArea]
                    .compactMap { $0 }.joined(separator: ", ")
            }
        }
    }

    /// One-tap 911: iOS presents its own emergency call UI — apps cannot
    /// silently dial, this is as close as the platform allows.
    func call911() {
        if let url = URL(string: "tel://911") { UIApplication.shared.open(url) }
    }

    func callContact(number: String) {
        let digits = number.filter { "0123456789+".contains($0) }
        if let url = URL(string: "tel://\(digits)") { UIApplication.shared.open(url) }
    }

    /// Prefilled text to the emergency contact (driver taps send — apps
    /// cannot send SMS silently).
    func messageContact(number: String) {
        let digits = number.filter { "0123456789+".contains($0) }
        let body = emergencyReport()
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        // RFC 5724: the body param must sit in a query — `?&body=` is the form
        // iOS reliably prefills across versions. The prior `sms:NUMBER&body=` had
        // no `?`, so Messages opened an EMPTY thread and the crash report was lost.
        if let url = URL(string: "sms:\(digits)?&body=\(body)") {
            UIApplication.shared.open(url)
        }
    }

    private func speak(_ text: String) {
        // .playAndRecord (NOT .playback): the check-in immediately opens the
        // mic to listen for the reply, and an input tap under a record-
        // incapable .playback session gets a 0 Hz format and raises an
        // UNCATCHABLE NSException — the app would crash seconds after a real
        // impact. .duckOthers keeps music down; .defaultToSpeaker + Bluetooth
        // route the prompt out loud in the car.
        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .voiceChat,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        synthesizer.speak(utterance)
    }

    /// Listen for a spoken reply for a few seconds (best-effort: requires
    /// mic + speech permissions; without them the on-screen buttons remain).
    /// Starts ONLY after the prompt finishes speaking — otherwise the mic
    /// records the phone's own "…say yes to get help…" and could self-trigger.
    private func listenForReply(seconds: Double) {
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            guard auth == .authorized else { return }
            Task { @MainActor in
                guard let self else { return }
                // Wait out the utterance (bounded) so we don't transcribe it.
                var waited = 0
                while self.synthesizer.isSpeaking, waited < 60 {
                    try? await Task.sleep(for: .milliseconds(100)); waited += 1
                }
                // Answered, dismissed or ended while the question played: the
                // microphone stays shut (it used to open mid-report, where a
                // heard word could restart or stand down the help flow).
                guard case .checkingIn = self.state else { return }
                self.startRecognition(seconds: seconds)
            }
        }
    }

    private func startRecognition(seconds: Double) {
        guard let recognizer, recognizer.isAvailable else { return }
        stopRecognition()
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
        // Defensive: if the session still isn't record-capable (0 Hz), do NOT
        // installTap — it would NSException. Degrade to the on-screen buttons.
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try? engine.start()
        audioEngine = engine
        recognitionRequest = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            let transcript = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            Task { @MainActor in
                switch CrashLogic.interpretReply(transcript) {
                // "I need help" → act on the earliest partial (erring toward help
                // is always safe). "I'm okay" → only stand down on the FINAL
                // transcript, so an early "no…" in "no wait, I need help" can't
                // cancel the check-in before the request is fully spoken.
                case .some(true): self.requestAssistance()
                case .some(false) where isFinal: self.standDown()
                default: break
                }
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await MainActor.run { self?.finishListenWindow() }
        }
    }

    /// Close the listen window in a way that lets a stand-down land: stop
    /// feeding audio and call endAudio() so the recognizer delivers its FINAL
    /// transcript — a live buffer request never finalizes on its own, so
    /// without this "I'm okay" (final-only, see above) could NEVER stand the
    /// check-in down by voice. A short grace period lets that result arrive
    /// before the task is torn down.
    private func finishListenWindow() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionRequest?.endAudio()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { self?.stopRecognition() }
        }
    }

    private func stopRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
    }

    private func stopCheckIn() {
        checkInTask?.cancel()
        checkInTask = nil
        stopRecognition()
    }

    #else
    // macOS: no accelerometer — crash detection is an iPhone/CarPlay feature.
    static let isAvailable = false
    static func askReplyPermissionsIfNeeded() async {}
    func begin() {}
    func end() {}
    func stopWatching() {}
    func requestAssistance() {}
    func standDown() {}
    func resolveAddress() {}
    func emergencyReport() -> String { "" }
    #endif
}
