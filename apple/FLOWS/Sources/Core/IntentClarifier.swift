// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional on-device language help for drivers who struggle to find the
/// right words — a speech impediment, aphasia, or just "the one with the
/// tacos": when the deterministic matchers read a dialogue reply as
/// unclear, Apple's ON-DEVICE foundation model (Apple Intelligence,
/// iOS 26+) is asked to map the utterance onto ONE of the offered options
/// — or onto nothing. Private by construction (the model runs on the
/// phone; nothing leaves the device), keyless, and zero dependencies (a
/// system framework, availability-checked at runtime).
///
/// The model NEVER overrides a clear deterministic match and is never
/// asked yes/no safety questions — it only rescues replies that would
/// otherwise dead-end at "the list is on screen". On devices without
/// Apple Intelligence the dialogue simply behaves as before.
enum IntentClarifier {
    /// Map a spoken reply onto one offered option; nil = no confident
    /// match (or no on-device model on this hardware).
    static func pick(reply: String, options: [String]) async -> Int? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { return nil }
        guard !reply.isEmpty, !options.isEmpty,
              case .available = SystemLanguageModel.default.availability
        else { return nil }
        let list = options.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let session = LanguageModelSession(instructions:
            "You match a driver's spoken reply to one of the numbered options. "
            + "Answer with ONLY the option's number. If no option clearly "
            + "matches, answer 0.")
        let prompt = "Options:\n\(list)\n\nDriver said: \"\(reply)\"\n\nNumber:"
        guard let text = try? await session.respond(to: prompt).content
        else { return nil }
        return optionIndex(fromModelText: text, optionCount: options.count)
        #else
        return nil
        #endif
    }

    /// The model's reply → a safe index: the FIRST number in the text,
    /// in range, minus one ("2" → 1; "0", chatter, or out-of-range → nil).
    /// Pure — pinned by FLOWSTests.
    static func optionIndex(fromModelText text: String, optionCount: Int) -> Int? {
        let firstRun = text.drop { !$0.isNumber }.prefix { $0.isNumber }
        guard let value = Int(firstRun), value >= 1, value <= optionCount
        else { return nil }
        return value - 1
    }
}
