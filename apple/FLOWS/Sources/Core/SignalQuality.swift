// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation
#if os(iOS)
import CoreTelephony
#endif

/// Reading the link's health BEFORE the music dies, so the switch can be
/// staged instead of scrambled.
///
/// **What iOS will and won't tell you.** There is no public signal-strength
/// API — bars live behind private API, and reaching for them is an App
/// Store rejection. What IS public and permission-free is the radio
/// ACCESS TECHNOLOGY (`CTTelephonyNetworkInfo`): whether the phone is on
/// 5G, LTE, HSPA, or has fallen back to EDGE. A fallback to EDGE on a
/// rural highway is the single most predictive thing available, because
/// it happens *before* the throughput collapse that starves a buffer.
///
/// FLOWS blends that with signals it owns and can trust completely: its
/// own stream stalling, and its own buffer draining rather than filling.
/// A draining buffer is a leading indicator no external API can beat —
/// it is the actual mechanism by which the music will stop.
///
/// The decisions live in rust/flows-core (media_policy.rs) behind
/// rust/flows-bridge; this enum keeps their Swift names. Pinned to the
/// original by rust/flows-bridge/tests/fixtures/swift_modes_oracle.tsv.
enum SignalQuality {
    enum Tier: String, Equatable {
        case strong    // 5G / LTE / Wi-Fi
        case fair      // 3G-class
        case weak      // EDGE / GPRS — the classic dead-zone approach
        case offline
    }

    /// Radio access technology string → tier. The constants are matched by
    /// suffix so a new `CTRadioAccessTechnology…` name doesn't silently
    /// read as unknown.
    static func tier(radioTechnology: String?, onWiFi: Bool,
                     offline: Bool) -> Tier {
        Tier(rustCode: flows_modes_signal_tier(radioTechnology ?? "", radioTechnology != nil,
                                               onWiFi, offline))
    }

    /// Should FLOWS get the fallback ready NOW, while there's still signal
    /// to fetch with? Pre-staging is cheap (one station search) and buys
    /// the seamless switch: without it, the handoff can only start
    /// searching once the music has already gone quiet.
    ///
    /// Two independent triggers, either sufficient:
    ///   * the link has dropped to a technology that rarely sustains a
    ///     stream, or
    ///   * our own buffer is draining / the stream has already stuttered —
    ///     the mechanism of failure, actually observed.
    /// Never when already offline: too late to fetch anything.
    static func shouldPreStage(tier: Tier, bufferDraining: Bool,
                               recentStalls: Int) -> Bool {
        flows_modes_should_pre_stage(tier.rustCode, bufferDraining, Int64(recentStalls))
    }

    /// A buffer that shrank meaningfully between two samples is being
    /// consumed faster than it refills — the stream is losing.
    static func isDraining(previous: Double?, current: Double?) -> Bool {
        flows_modes_is_draining(previous ?? 0, previous != nil, current ?? 0, current != nil)
    }
}

extension SignalQuality.Tier {
    /// The tier's declaration position, the code media_policy.rs uses.
    var rustCode: UInt8 {
        switch self {
        case .strong: return 0
        case .fair: return 1
        case .weak: return 2
        case .offline: return 3
        }
    }

    init(rustCode code: UInt8) {
        switch code {
        case 0: self = .strong
        case 2: self = .weak
        case 3: self = .offline
        default: self = .fair
        }
    }
}

/// The phone's current radio access technology, or nil off-cellular.
enum CellularRadio {
    #if os(iOS)
    /// One handle for the process. This was allocated on every GPS fix
    /// while audio played; the object is documented as safe to read from
    /// any thread and there is no reason to make a new one.
    private static let info = CTTelephonyNetworkInfo()
    #endif

    static var currentTechnology: String? {
        #if os(iOS)
        // Multi-SIM phones report per-service; any active data radio will
        // do, and they are near-always the same technology in practice.
        return info.serviceCurrentRadioAccessTechnology?.values.first
        #else
        return nil
        #endif
    }
}
