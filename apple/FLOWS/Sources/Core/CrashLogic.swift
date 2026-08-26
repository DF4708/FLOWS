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
    /// under ~2.5 g at the phone; crash pulses exceed 5 g. A 5–8 g spike must be
    /// CONFIRMED (see `isImpact(window:)`) to avoid a one-off phone drop firing
    /// the check-in.
    static let impactGForce = 5.0
    /// Unambiguous hard impact: no real crash this violent waits for
    /// window corroboration (it still needs the motion evidence below).
    static let hardImpactGForce = 8.0
    /// Corroboration threshold: how high a *follow-up* sample must be to count as
    /// "the disturbance continued" rather than a spike that settled to rest.
    static let confirmImpactGForce = 2.5

    // MARK: motion corroboration — what separates a crash from a fun ride
    //
    // G force alone is not a crash. A rollercoaster pulls 4–6 g through a
    // loop, a dropped phone spikes past 8 g, and neither is an emergency.
    // What makes a crash a crash is that a vehicle TRAVELING AT ROAD SPEED
    // ON A ROAD suddenly stops. All three must agree.

    /// The vehicle must have been moving at real road speed just before the
    /// impact (≈20 mph). Below this, an "impact" is someone handling the
    /// phone, not a collision worth summoning help for.
    static let minPreImpactSpeedMps = 8.9
    /// …and must be at or near a standstill just after (≈10 mph). A ride
    /// pulling high g mid-track keeps its speed; a crashed car does not.
    static let crashStopSpeedMps = 4.5
    /// …losing most of its speed in the process.
    static let minSpeedDropFraction = 0.55
    /// On a ROAD: within this far of the road corridor being driven. A
    /// rollercoaster, a bike park, a boat — none are on the road, so their
    /// g-loads never reach the check-in. `nil` distance (corridor unknown)
    /// is treated as unknown-but-allowed, since the speed evidence still has
    /// to hold and refusing to detect crashes off-route would be worse.
    static let maxMetersFromRoad = 60.0

    /// Everything the crash decision needs, gathered at the moment of impact.
    struct ImpactEvidence {
        /// Rolling |acceleration| magnitudes in g (newest last).
        var window: [Double]
        /// Fastest the vehicle was traveling in the seconds before impact.
        var speedBeforeMps: Double
        /// Speed right after the impact.
        var speedAfterMps: Double
        /// Distance from the road corridor being driven; nil when unknown.
        var metersFromRoad: Double?
    }

    /// THE crash decision: a strong enough impact AND a road-speed vehicle
    /// suddenly stopping AND being on a road. Splitting these out is what
    /// keeps the amusement park quiet — a loop pulls the g's but never the
    /// sudden stop, and it is nowhere near the corridor.
    static func isCrash(_ evidence: ImpactEvidence) -> Bool {
        guard isImpact(window: evidence.window) else { return false }
        guard evidence.speedBeforeMps >= minPreImpactSpeedMps else { return false }
        guard evidence.speedAfterMps <= crashStopSpeedMps else { return false }
        let drop = (evidence.speedBeforeMps - evidence.speedAfterMps)
            / max(evidence.speedBeforeMps, 0.001)
        guard drop >= minSpeedDropFraction else { return false }
        if let meters = evidence.metersFromRoad, meters > maxMetersFromRoad {
            return false
        }
        return true
    }

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
