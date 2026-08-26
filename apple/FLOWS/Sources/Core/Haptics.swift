// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation
#if os(iOS)
import UIKit
#endif

/// Hearing-parity channel: everything FLOWS announces OUT LOUD also lands
/// as a felt tap, so a deaf or hard-of-hearing driver gets the same
/// "look at the screen now" signal the voice gives everyone else. The
/// banner carries the words; the buzz carries the urgency. Always on —
/// it fires even with the voice toggles off, because it IS the
/// alternative to the voice.
enum Haptics {
    /// A warning entered the corridor (imminent banner, AMBER included).
    @MainActor
    static func warning() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    /// FLOWS is offering something and waiting on the driver (faster
    /// route ready).
    @MainActor
    static func offer() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}
