// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import AppIntents
import Foundation

/// Siri control for hands-free driving: the music buttons and the POI quick
/// actions become App Intents — "Hey Siri, skip track in FLOWS", "find diesel
/// in FLOWS", "find a rest area in FLOWS" — no eyes off the road.

// MARK: music

struct PlayPauseMusicIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or pause music"
    static let description = IntentDescription("Toggles music playback while navigating.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        MusicController.shared.playPause()
        return .result(dialog: MusicController.shared.isPlaying ? "Playing." : "Paused.")
    }
}

struct SkipTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip track"
    static let description = IntentDescription("Skips to the next song.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        MusicController.shared.skip()
        return .result(dialog: "Skipped.")
    }
}

struct ToggleShuffleIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle shuffle"
    static let description = IntentDescription("Turns music shuffle on or off.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        MusicController.shared.toggleShuffle()
        return .result(dialog: MusicController.shared.shuffleOn ? "Shuffle on." : "Shuffle off.")
    }
}

// MARK: POI quick actions ("other app buttons")

enum StopKindOption: String, AppEnum {
    case fuel = "Fuel"
    case food = "Food"
    case rest = "Rest area"
    case medical = "Medical"
    case shelter = "Shelter"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Stop kind")
    static let caseDisplayRepresentations: [StopKindOption: DisplayRepresentation] = [
        .fuel: "Fuel", .food: "Food", .rest: "Rest area",
        .medical: "Medical", .shelter: "Shelter",
    ]

    var poiKind: POIService.Kind {
        switch self {
        case .fuel: return .gas
        case .food: return .food
        case .rest: return .rest
        case .medical: return .medical
        case .shelter: return .shelter
        }
    }
}

struct FindStopIntent: AppIntent {
    static let title: LocalizedStringResource = "Find a stop ahead"
    static let description = IntentDescription(
        "Searches for fuel, food, rest areas, medical help, or shelters ahead on the route.")
    static let openAppWhenRun = true

    @Parameter(title: "Kind of stop")
    var kind: StopKindOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared else {
            return .result(dialog: "Open FLOWS first.")
        }
        await model.poi.request(kind.poiKind, aheadOf: model.effectivePosition)
        let count = model.poi.results.count
        return .result(dialog: count > 0
            ? "Found \(count) \(kind.rawValue.lowercased()) options ahead."
            : "Nothing found ahead on this route.")
    }
}

struct FLOWSShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayPauseMusicIntent(),
            phrases: ["Play music in \(.applicationName)",
                      "Pause music in \(.applicationName)"],
            shortTitle: "Play/Pause",
            systemImageName: "playpause.fill")
        AppShortcut(
            intent: SkipTrackIntent(),
            phrases: ["Skip track in \(.applicationName)",
                      "Next song in \(.applicationName)"],
            shortTitle: "Skip",
            systemImageName: "forward.fill")
        AppShortcut(
            intent: ToggleShuffleIntent(),
            phrases: ["Toggle shuffle in \(.applicationName)"],
            shortTitle: "Shuffle",
            systemImageName: "shuffle")
        AppShortcut(
            intent: FindStopIntent(),
            phrases: ["Find a stop in \(.applicationName)",
                      "Find fuel in \(.applicationName)",
                      "Find food in \(.applicationName)"],
            shortTitle: "Find a stop",
            systemImageName: "fuelpump.fill")
    }
}
