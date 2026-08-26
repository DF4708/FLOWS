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
        if offline { return .offline }
        if onWiFi { return .strong }
        guard let tech = radioTechnology?.lowercased() else { return .fair }
        if tech.contains("nr") || tech.contains("lte") { return .strong }
        if tech.contains("edge") || tech.contains("gprs")
            || tech.contains("1x") { return .weak }
        if tech.contains("wcdma") || tech.contains("hs")
            || tech.contains("cdma") { return .fair }
        return .fair
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
    static func shouldPreStage(tier: Tier, bufferDraining: Bool,
                               recentStalls: Int) -> Bool {
        if tier == .offline { return false }   // too late to fetch anything
        return tier == .weak || bufferDraining || recentStalls > 0
    }

    /// A buffer that shrank meaningfully between two samples is being
    /// consumed faster than it refills — the stream is losing.
    static func isDraining(previous: Double?, current: Double?) -> Bool {
        guard let previous, let current, previous.isFinite, current.isFinite
        else { return false }
        return current < previous - 1.0
    }
}

/// The phone's current radio access technology, or nil off-cellular.
enum CellularRadio {
    static var currentTechnology: String? {
        #if os(iOS)
        let info = CTTelephonyNetworkInfo()
        // Multi-SIM phones report per-service; any active data radio will
        // do, and they are near-always the same technology in practice.
        return info.serviceCurrentRadioAccessTechnology?.values.first
        #else
        return nil
        #endif
    }
}
