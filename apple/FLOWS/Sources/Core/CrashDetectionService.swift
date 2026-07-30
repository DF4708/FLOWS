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
    @Published private(set) var lastTranscript: String?

    /// Set by AppModel: where we are + what we drive + medical notes.
    var context: () -> (coordinate: CLLocationCoordinate2D?,
                        vehicle: VehicleProfile?,
                        medicalNotes: String?) = { (nil, nil, nil) }

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
                window.removeAll(keepingCapacity: true) // consume — don't re-fire this event
                Task { @MainActor [weak self] in
                    // Drop a hop enqueued before end()/a new begin(): its
                    // generation is stale, so it can't fire a check-in after
                    // the trip it belonged to has ended.
                    guard let self, self.monitorGeneration == generation,
                          self.state == .idle else { return }
                    self.impactDetected()
                }
            }
        }
    }

    func end() {
        motion.stopAccelerometerUpdates()
        monitorGeneration += 1   // invalidate any impact hop still in flight
        stopCheckIn()
        state = .idle
        releaseAudioSessionWhenQuiet()
    }

    private func impactDetected() {
        impactTime = Date()
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
        speak("Calling 9 1 1. After the call, a report is ready to send to "
              + "your emergency contact. The report reads: " + report)
    }

    /// Physical dismissal or a spoken "I'm okay" — stand down.
    func standDown() {
        stopCheckIn()
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

    func resolveAddress() {
        guard let coord = context().coordinate else { return }
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            Task { @MainActor in
                if let pm = placemarks?.first {
                    self?.reverseGeocodedAddress = [pm.name, pm.locality, pm.administrativeArea]
                        .compactMap { $0 }.joined(separator: ", ")
                }
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
            options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
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
                self.lastTranscript = transcript
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
    func begin() {}
    func end() {}
    func requestAssistance() {}
    func standDown() {}
    func resolveAddress() {}
    func emergencyReport() -> String { "" }
    #endif
}
