// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Crash-detection decision logic + the emergency message template — pure,
/// pinned by FLOWSTests. The iOS service (CrashDetectionService) feeds it
/// accelerometer magnitudes and drives the voice check-in loop.
///
/// PLATFORM LIMITS, stated plainly (the flow is designed around them):
///   * iOS apps cannot silently place phone calls — `tel:` always presents
///     the system's call confirmation, and 911 additionally uses the
///     system's emergency UI. FLOWS gets the driver ONE TAP from connected.
///   * Apps cannot inject synthesized speech into a phone call, so "Siri
///     reads the report to 911" is not possible; instead the templated
///     report goes to the EMERGENCY CONTACT as a prefilled text message and
///     is spoken aloud locally so the driver can relay it.
///   * Health app Medical ID is not readable by third-party apps — medical
///     notes live in the FLOWS emergency-contact settings instead.
///   * Apple's own hardware Crash Detection (iPhone 14+) independently
///     auto-dials 911; FLOWS complements it, never replaces it.
enum CrashLogic {

    /// Moderate-impact threshold. Normal driving (potholes, hard braking) stays
    /// under ~2.5 g at the phone; crash pulses exceed 4 g. A 4–6 g spike must be
    /// CONFIRMED (see `isImpact(window:)`) to avoid a one-off phone drop firing
    /// the check-in.
    static let impactGForce = 4.0
    /// Unambiguous hard impact: fires immediately, even from a single sample —
    /// no real crash this violent should ever wait for confirmation.
    static let hardImpactGForce = 6.0
    /// Corroboration threshold: how high a *follow-up* sample must be to count as
    /// "the disturbance continued" rather than a spike that settled to rest.
    static let confirmImpactGForce = 2.5

    /// Re-ask cadence: after a crash the driver may be unconscious — keep
    /// asking until they answer or PHYSICALLY dismiss, never stop after one
    /// attempt.
    static let checkInRepeatSeconds: TimeInterval = 20

    /// Words that count as "yes, I need help" from the voice check-in —
    /// broad on purpose: a hurt driver won't pick canonical phrasing.
    static let assistWords = [
        "yes", "yeah", "yep", "yup", "please", "help", "hurt",
        "injured", "bleeding", "trapped", "stuck", "can't move", "cant move",
        "call 911", "call nine one one", "call an ambulance", "ambulance",
        "i need help", "need help", "get help", "send help", "emergency",
        "sos", "mayday", "affirmative", "do it", "go ahead", "hurry",
    ]
    /// Words that stand down the check-in loop. Checked FIRST so "no, I
    /// don't need help" never reads as an assist request.
    static let okWords = [
        "no", "nope", "nah", "negative", "i'm ok", "im ok", "i am ok",
        "i'm okay", "im okay", "i am okay", "we're ok", "were ok",
        "we're fine", "i'm fine", "im fine", "i am fine", "all good",
        "it's fine", "its fine", "i'm good", "im good", "i am good",
        "false alarm", "cancel", "stop asking", "dismiss", "never mind",
        "nevermind", "no thanks", "don't call", "dont call", "stand down",
    ]

    static func isImpact(accelerationG: Double) -> Bool {
        accelerationG >= impactGForce
    }

    /// Impact decision over a short rolling window of |acceleration| magnitudes
    /// in g (newest last, ~0.5 s at 50 Hz). Fires if EITHER the peak is an
    /// unambiguous hard impact (>= `hardImpactGForce`, so a violent crash is
    /// never suppressed), OR a moderate impact (>= `impactGForce`) is corroborated
    /// by continued disturbance — at least 3 samples above `confirmImpactGForce`,
    /// which a real crash's tumble/skid/secondary motion produces but a phone
    /// dropped into a cupholder (one spike, then rest at ~1 g) does not.
    ///
    /// NOTE: this is a heuristic. Robust crash detection wants sensor fusion
    /// (accel + gyro + speed + barometer) and field-tuned thresholds; these
    /// values are conservative starting points, deliberately biased so a real
    /// crash is never missed at the cost of the occasional cancelable check-in.
    static func isImpact(window: [Double]) -> Bool {
        guard let peak = window.max() else { return false }
        if peak >= hardImpactGForce { return true }
        guard peak >= impactGForce else { return false }
        return window.filter { $0 >= confirmImpactGForce }.count >= 3
    }

    /// Interpret a voice reply: true = wants help, false = stand down,
    /// nil = unclear (keep asking). Single words match on WORD BOUNDARIES
    /// ("know" is not "no", "yesterday" is not "yes"); phrases match as
    /// substrings. Stand-down phrases win so "no, I don't need help" never
    /// dials.
    static func interpretReply(_ transcript: String) -> Bool? {
        let lower = transcript.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init))
        func matches(_ vocab: [String]) -> Bool {
            vocab.contains { entry in
                entry.contains(" ") ? lower.contains(entry) : words.contains(entry)
            }
        }
        if matches(okWords) { return false }
        if matches(assistWords) { return true }
        return nil
    }

    /// The templated report: nature, GPS, street address, time, vehicle,
    /// medical notes — sent as a prefilled text to the emergency contact and
    /// spoken aloud for relaying to 911.
    static func emergencyMessage(
        latitude: Double?, longitude: Double?, address: String?,
        time: Date, vehicle: VehicleProfile?, medicalNotes: String?
    ) -> String {
        let formatter = DateFormatter()
        // Pin POSIX/en_US so the crash time is always "3:07 PM" — not a
        // device-locale form (24-hour, or missing AM/PM) a 911 dispatcher
        // relaying the report could misread.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        var lines = [
            "AUTOMATED CRASH REPORT (FLOWS)",
            "Possible vehicle crash at \(formatter.string(from: time)).",
        ]
        // Only state a location we actually have. A missing fix must NOT
        // become "GPS: 0.00000, 0.00000" — that is a real point in the
        // Atlantic Ocean off Africa and would misdirect responders.
        if let latitude, let longitude {
            lines.append(String(format: "GPS: %.5f, %.5f", latitude, longitude))
        } else {
            lines.append("GPS: unavailable at time of report.")
        }
        if let address { lines.append("Near: \(address)") }
        if let vehicle {
            lines.append("Vehicle: \(vehicle.displayName) (\(vehicle.fuelType.rawValue))")
        }
        if let medicalNotes, !medicalNotes.isEmpty {
            lines.append("Medical: \(medicalNotes)")
        }
        lines.append("Driver may need assistance — please check on them.")
        return lines.joined(separator: "\n")
    }
}

/// FMCSA §395.3 hours-of-service checkpoints for the trucker HUD timer:
/// a 30-minute break is required after 8 cumulative driving hours, and
/// driving stops at 11 hours within the 14-hour window.
enum HOSRules {
    static let breakDueSeconds: TimeInterval = 8 * 3600
    static let warnBeforeBreakSeconds: TimeInterval = 30 * 60
    static let dailyDrivingLimitSeconds: TimeInterval = 11 * 3600
    /// A stop this long resets the 30-minute-break clock.
    static let breakResetSeconds: TimeInterval = 30 * 60

    enum Status: Equatable {
        case ok
        case breakSoon(secondsUntilDue: TimeInterval)   // inside the warning window
        case breakDue                                    // 8 h reached
        case limitReached                                // 11 h reached
    }

    static func status(drivingSeconds: TimeInterval) -> Status {
        if drivingSeconds >= dailyDrivingLimitSeconds { return .limitReached }
        if drivingSeconds >= breakDueSeconds { return .breakDue }
        let untilDue = breakDueSeconds - drivingSeconds
        if untilDue <= warnBeforeBreakSeconds { return .breakSoon(secondsUntilDue: untilDue) }
        return .ok
    }
}
