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
///
/// The thresholds, the impact and crash decisions and the reply vocabulary
/// live in rust/flows-core (trip_vehicle.rs) and are called through
/// rust/flows-bridge; Swift holds no copy of a threshold or a word. The
/// emergency message and the check-in cadence are presentation and stay
/// here. Pinned bit for bit to the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_trip_vehicle_oracle.tsv.
enum CrashLogic {

    /// Moderate-impact threshold. Normal driving (potholes, hard braking) stays
    /// under ~2.5 g at the phone; crash pulses exceed 5 g. A 5–8 g spike must be
    /// CONFIRMED (see `isImpact(window:)`) to avoid a one-off phone drop firing
    /// the check-in.
    static let impactGForce = flows_trip_vehicle_impact_g_force()
    /// Unambiguous hard impact: no real crash this violent waits for
    /// window corroboration (it still needs the motion evidence below).
    static let hardImpactGForce = flows_trip_vehicle_hard_impact_g_force()
    /// Corroboration threshold: how high a *follow-up* sample must be to count as
    /// "the disturbance continued" rather than a spike that settled to rest.
    static let confirmImpactGForce = flows_trip_vehicle_confirm_impact_g_force()

    // MARK: motion corroboration — what separates a crash from a fun ride
    //
    // G force alone is not a crash. A rollercoaster pulls 4–6 g through a
    // loop, a dropped phone spikes past 8 g, and neither is an emergency.
    // What makes a crash a crash is that a vehicle TRAVELING AT ROAD SPEED
    // ON A ROAD suddenly stops. All three must agree.

    /// The vehicle must have been moving at real road speed just before the
    /// impact (≈20 mph). Below this, an "impact" is someone handling the
    /// phone, not a collision worth summoning help for.
    static let minPreImpactSpeedMps = flows_trip_vehicle_min_pre_impact_speed_mps()
    /// …and must be at or near a standstill just after (≈10 mph). A ride
    /// pulling high g mid-track keeps its speed; a crashed car does not.
    static let crashStopSpeedMps = flows_trip_vehicle_crash_stop_speed_mps()
    /// …losing most of its speed in the process.
    static let minSpeedDropFraction = flows_trip_vehicle_min_speed_drop_fraction()
    /// On a ROAD: within this far of the road corridor being driven. A
    /// rollercoaster, a bike park, a boat — none are on the road, so their
    /// g-loads never reach the check-in. `nil` distance (corridor unknown)
    /// is treated as unknown-but-allowed, since the speed evidence still has
    /// to hold and refusing to detect crashes off-route would be worse.
    static let maxMetersFromRoad = flows_trip_vehicle_max_meters_from_road()

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
        // No samples is no impact (and an empty buffer never crosses).
        guard !evidence.window.isEmpty else { return false }
        return evidence.window.withUnsafeBufferPointer {
            flows_trip_vehicle_is_crash(
                $0, evidence.speedBeforeMps, evidence.speedAfterMps,
                evidence.metersFromRoad ?? 0, evidence.metersFromRoad != nil)
        }
    }

    /// How long after a hard jolt to watch the GPS for the stop. A fix is
    /// about a second old at the moment of impact and still reads the speed
    /// before it, and Core Location's smoothing can take a couple more fixes
    /// to read a crashed car as stopped. The wait is kept short on purpose:
    /// the longer it is, the more often a phone knocked off its mount just
    /// before an ordinary stop at a light (from under ~35 mph, normal braking
    /// gets below the stop speed inside 5 s) asks "Are you OK?". A missed
    /// crash costs more than that question, so it is not shorter still.
    static let stopSettleSeconds: TimeInterval = 5

    /// Re-ask cadence: after a crash the driver may be unconscious — keep
    /// asking until they answer or PHYSICALLY dismiss, never stop after one
    /// attempt.
    static let checkInRepeatSeconds: TimeInterval = 20

    /// Words that count as "yes, I need help" from the voice check-in —
    /// broad on purpose: a hurt driver won't pick canonical phrasing.
    static let assistWords: [String] = flows_trip_vehicle_assist_words().map { $0.as_str().toString() }
    /// Words that stand down the check-in loop. Checked FIRST so "no, I
    /// don't need help" never reads as an assist request.
    static let okWords: [String] = flows_trip_vehicle_ok_words().map { $0.as_str().toString() }

    static func isImpact(accelerationG: Double) -> Bool {
        flows_trip_vehicle_is_impact_acceleration(accelerationG)
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
        // No samples is no impact (and an empty buffer never crosses).
        guard !window.isEmpty else { return false }
        return window.withUnsafeBufferPointer { flows_trip_vehicle_is_impact_window($0) }
    }

    /// Interpret a voice reply: true = wants help, false = stand down,
    /// nil = unclear (keep asking). Single words match on WORD BOUNDARIES
    /// ("know" is not "no", "yesterday" is not "yes"); phrases match as
    /// substrings. Stand-down phrases win so "no, I don't need help" never
    /// dials.
    static func interpretReply(_ transcript: String) -> Bool? {
        // 1 wants help, 0 stands down, anything else is unclear.
        switch flows_trip_vehicle_interpret_reply(transcript) {
        case 1: return true
        case 0: return false
        default: return nil
        }
    }

    /// The templated report: nature, GPS, street address, time, vehicle,
    /// medical notes — sent as a prefilled text to the emergency contact and
    /// spoken aloud for relaying to 911.
    /// Pin POSIX/en_US so the crash time is always "3:07 PM" — not a
    /// device-locale form (24-hour, or missing AM/PM) a 911 dispatcher
    /// relaying the report could misread. Built once: the crash card
    /// renders this report on every frame while it is up.
    private static let crashTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()

    static func emergencyMessage(
        latitude: Double?, longitude: Double?, address: String?,
        time: Date, vehicle: VehicleProfile?, medicalNotes: String?
    ) -> String {
        let formatter = Self.crashTimeFormatter
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
/// driving stops at 11 hours within the 14-hour window. The checkpoints and
/// the status are read from rust/flows-core through rust/flows-bridge.
enum HOSRules {
    static let breakDueSeconds: TimeInterval = flows_trip_vehicle_hos_break_due_seconds()
    static let warnBeforeBreakSeconds: TimeInterval = flows_trip_vehicle_hos_warn_before_break_seconds()
    static let dailyDrivingLimitSeconds: TimeInterval = flows_trip_vehicle_hos_daily_driving_limit_seconds()
    /// A stop this long resets the 30-minute-break clock.
    static let breakResetSeconds: TimeInterval = flows_trip_vehicle_hos_break_reset_seconds()

    enum Status: Equatable {
        case ok
        case breakSoon(secondsUntilDue: TimeInterval)   // inside the warning window
        case breakDue                                    // 8 h reached
        case limitReached                                // 11 h reached
    }

    static func status(drivingSeconds: TimeInterval) -> Status {
        // 0 ok, 1 break soon (with the seconds until due), 2 break due, 3 limit.
        let status = flows_trip_vehicle_hos_status(drivingSeconds)
        switch status.code {
        case 3: return .limitReached
        case 2: return .breakDue
        case 1: return .breakSoon(secondsUntilDue: status.seconds_until_due)
        default: return .ok
        }
    }
}
