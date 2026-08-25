// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
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

/// The picked service can't be driven from FLOWS — no music service except
/// Apple Music and Spotify publishes a way in (MusicProvider.controllable).
/// Siri says so in plain words instead of silently driving Apple Music
/// over whatever the driver actually picked.
@MainActor
private func musicHandsOffDialog() -> IntentDialog {
    let provider = MusicController.shared.provider
    if provider == .spotify {
        return IntentDialog(
            "Add a Spotify token in FLOWS Settings — then Siri can control Spotify here.")
    }
    return IntentDialog(
        "\(provider.displayName) can only be controlled in its own app.")
}

struct PlayPauseMusicIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or pause music"
    static let description = IntentDescription("Toggles music playback while navigating.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let music = MusicController.shared
        guard music.controlsInPlace else {
            return .result(dialog: musicHandsOffDialog())
        }
        music.playPause()
        return .result(dialog: music.isPlaying ? "Playing." : "Paused.")
    }
}

struct SkipTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip track"
    static let description = IntentDescription("Skips to the next song.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let music = MusicController.shared
        guard music.controlsInPlace else {
            return .result(dialog: musicHandsOffDialog())
        }
        music.skip()
        return .result(dialog: "Skipped.")
    }
}

struct ToggleShuffleIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle shuffle"
    static let description = IntentDescription("Turns music shuffle on or off.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let music = MusicController.shared
        guard music.controlsInPlace else {
            return .result(dialog: musicHandsOffDialog())
        }
        music.toggleShuffle()
        return .result(dialog: music.shuffleOn ? "Shuffle on." : "Shuffle off.")
    }
}

// MARK: POI quick actions ("other app buttons")

enum StopKindOption: String, AppEnum {
    case fuel = "Fuel"
    case food = "Food"
    case rest = "Rest area"
    case hotel = "Hotel"
    case parking = "Parking"
    case medical = "Medical"
    case shelter = "Shelter"
    case showers = "Showers"
    case truckParking = "Truck parking"
    case weighStation = "Weigh station"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Stop kind")
    static let caseDisplayRepresentations: [StopKindOption: DisplayRepresentation] = [
        .fuel: "Fuel", .food: "Food", .rest: "Rest area", .hotel: "Hotel",
        .parking: "Parking", .medical: "Medical", .shelter: "Shelter",
        .showers: "Showers", .truckParking: "Truck parking",
        .weighStation: "Weigh station",
    ]

    var poiKind: POIService.Kind {
        switch self {
        case .fuel: return .gas
        case .food: return .food
        case .rest: return .rest
        case .hotel: return .hotel
        case .parking: return .parking
        case .medical: return .medical
        case .shelter: return .shelter
        case .showers: return .shower
        case .truckParking: return .truckParking
        case .weighStation: return .weighStation
        }
    }
}

struct FindStopIntent: AppIntent {
    static let title: LocalizedStringResource = "Find a stop ahead"
    static let description = IntentDescription(
        "Searches for fuel, food, rest areas, hotels, parking, showers, medical help, or shelters ahead on the route.")
    static let openAppWhenRun = true

    @Parameter(title: "Kind of stop")
    var kind: StopKindOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared else {
            return .result(dialog: "Open FLOWS first.")
        }
        await model.poi.request(kind.poiKind, aheadOf: model.effectivePosition)
        // Food/stores (and first-run fuel) divert into their category
        // pickers — no results yet, and "nothing found" would be a lie.
        if model.poi.pendingFoodChoice || model.poi.pendingFuelChoice
            || model.poi.pendingStoreChoice {
            return .result(dialog: "Opening FLOWS — pick the exact type there.")
        }
        let count = model.poi.results.count
        return .result(dialog: count > 0
            ? IntentDialog("Found \(count) \(kind.rawValue.lowercased()) options ahead.")
            : IntentDialog("Nothing found ahead on this route."))
    }
}

// MARK: add a stop to the live route ("add a Starbucks to our route")

/// The chains a driver asks for by name — Siri's spoken vocabulary for
/// add-a-stop. Raw values double as the display form AND the map-search
/// term. Free-form places ride AddPlaceStopIntent instead.
enum ChainOption: String, AppEnum {
    case starbucks = "Starbucks"
    case dunkin = "Dunkin'"
    case mcdonalds = "McDonald's"
    case burgerKing = "Burger King"
    case wendys = "Wendy's"
    case tacoBell = "Taco Bell"
    case chickFilA = "Chick-fil-A"
    case subway = "Subway"
    case chipotle = "Chipotle"
    case kfc = "KFC"
    case popeyes = "Popeyes"
    case arbys = "Arby's"
    case sonic = "Sonic Drive-In"
    case dairyQueen = "Dairy Queen"
    case culvers = "Culver's"
    case whataburger = "Whataburger"
    case inNOut = "In-N-Out Burger"
    case fiveGuys = "Five Guys"
    case pandaExpress = "Panda Express"
    case waffleHouse = "Waffle House"
    case crackerBarrel = "Cracker Barrel"
    case dennys = "Denny's"
    case ihop = "IHOP"
    case panera = "Panera Bread"
    case loves = "Love's"
    case pilotFlyingJ = "Pilot Flying J"
    case taPetro = "TA Travel Center"
    case buccees = "Buc-ee's"
    case caseys = "Casey's"
    case wawa = "Wawa"
    case sheetz = "Sheetz"
    case quikTrip = "QuikTrip"
    case circleK = "Circle K"
    case sevenEleven = "7-Eleven"
    case walmart = "Walmart"
    case target = "Target"
    case costco = "Costco"
    case cvs = "CVS"
    case walgreens = "Walgreens"
    case dollarGeneral = "Dollar General"
    case homeDepot = "Home Depot"
    case autoZone = "AutoZone"
    case planetFitness = "Planet Fitness"
    case bassProShops = "Bass Pro Shops"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Chain")
    static let caseDisplayRepresentations: [ChainOption: DisplayRepresentation] = [
        .starbucks: "Starbucks", .dunkin: "Dunkin'", .mcdonalds: "McDonald's",
        .burgerKing: "Burger King", .wendys: "Wendy's", .tacoBell: "Taco Bell",
        .chickFilA: "Chick-fil-A", .subway: "Subway", .chipotle: "Chipotle",
        .kfc: "KFC", .popeyes: "Popeyes", .arbys: "Arby's",
        .sonic: "Sonic Drive-In", .dairyQueen: "Dairy Queen",
        .culvers: "Culver's", .whataburger: "Whataburger",
        .inNOut: "In-N-Out Burger", .fiveGuys: "Five Guys",
        .pandaExpress: "Panda Express", .waffleHouse: "Waffle House",
        .crackerBarrel: "Cracker Barrel", .dennys: "Denny's", .ihop: "IHOP",
        .panera: "Panera Bread", .loves: "Love's",
        .pilotFlyingJ: "Pilot Flying J", .taPetro: "TA Travel Center",
        .buccees: "Buc-ee's", .caseys: "Casey's", .wawa: "Wawa",
        .sheetz: "Sheetz", .quikTrip: "QuikTrip", .circleK: "Circle K",
        .sevenEleven: "7-Eleven", .walmart: "Walmart", .target: "Target",
        .costco: "Costco", .cvs: "CVS", .walgreens: "Walgreens",
        .dollarGeneral: "Dollar General", .homeDepot: "Home Depot",
        .autoZone: "AutoZone", .planetFitness: "Planet Fitness",
        .bassProShops: "Bass Pro Shops",
    ]
}

/// Find the named place ahead on the LIVE route and chain it in as the
/// next stop (AppModel.addStop plans both legs). Every failure names the
/// one thing to do instead — and "Added" is only spoken after the add
/// actually took (leg planning can fail).
@MainActor
private func addRouteStop(named term: String) async -> IntentDialog {
    guard let model = AppModel.shared else {
        return IntentDialog("Open FLOWS first.")
    }
    guard model.mode == .navigating, let position = model.effectivePosition else {
        return IntentDialog("Start a route first — then I can add \(term) to it.")
    }
    guard let best = await model.poi.namedStops(term, aheadOf: position).first else {
        return IntentDialog("No \(term) found ahead on this route.")
    }
    let name = best.name ?? term
    let meters = POIRanking.meters(position, best.placemark.coordinate)
    await model.addStop(best)
    guard model.pendingStopName == name else {
        return IntentDialog("Couldn't route to \(name) right now. Try again in a moment.")
    }
    return IntentDialog("\(SiriSummaries.addedStop(name: name, meters: meters))")
}

struct AddChainStopIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a chain stop to the route"
    static let description = IntentDescription(
        "Finds the named chain ahead on the current route and adds it as the next stop.")
    static let openAppWhenRun = true

    @Parameter(title: "Chain")
    var chain: ChainOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await addRouteStop(named: chain.rawValue))
    }
}

struct AddPlaceStopIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a stop to the route"
    static let description = IntentDescription(
        "Finds a named place ahead on the current route and adds it as the next stop.")
    static let openAppWhenRun = true

    @Parameter(title: "Place", requestValueDialog: "What place should I add?")
    var place: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await addRouteStop(named: place))
    }
}

// MARK: road ahead ("how's the road ahead?")

struct RouteAheadIntent: AppIntent {
    static let title: LocalizedStringResource = "How's the road ahead"
    static let description = IntentDescription(
        "Says how far is left on the route and any weather alerts crossing it.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared,
              let guidance = model.navigation.guidance else {
            return .result(dialog: "Start a route first.")
        }
        var summary = SiriSummaries.roadAhead(
            remainingMeters: guidance.remainingDistance,
            remainingSeconds: guidance.remainingTime,
            alertEvents: model.navigation.route?.alertEvents ?? [])
        // Trucker mode: the FMCSA break clock rides along once it matters.
        if model.truckerUI, let hos = SiriSummaries.hosLine(model.hosStatus) {
            summary += " " + hos
        }
        return .result(dialog: IntentDialog("\(summary)"))
    }
}

// MARK: radio ("play the weather radio")

struct PlayWeatherRadioIntent: AppIntent {
    static let title: LocalizedStringResource = "Play the weather radio"
    static let description = IntentDescription(
        "Tunes the NOAA weather radio station closest to you.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared else {
            return .result(dialog: "Open FLOWS first.")
        }
        let channel = model.effectivePosition
            .flatMap { model.radio.nearestChannel(to: $0)?.channel }
            ?? model.radio.nearestChannel(stateCode: model.currentStateCode)
        guard let channel else {
            return .result(dialog: "No weather stations loaded yet. Try again in a moment.")
        }
        model.radio.play(channel)
        return .result(dialog: IntentDialog("Playing \(channel.name)."))
    }
}

struct PlayStationIntent: AppIntent {
    static let title: LocalizedStringResource = "Play a radio station"
    static let description = IntentDescription(
        "Finds an AM/FM internet stream by name or genre and plays it.")

    @Parameter(title: "Station or genre",
               requestValueDialog: "What station or kind of music?")
    var station: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared else {
            return .result(dialog: "Open FLOWS first.")
        }
        await model.radioBrowser.search(text: station)
        guard let top = model.radioBrowser.stations.first else {
            return .result(dialog: IntentDialog("No station found for \(station)."))
        }
        model.radio.play(top.channel)
        return .result(dialog: IntentDialog("Playing \(top.name)."))
    }
}

struct StopRadioIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop the radio"
    static let description = IntentDescription("Stops radio playback.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared else {
            return .result(dialog: "Open FLOWS first.")
        }
        model.radio.stop()
        return .result(dialog: "Radio stopped.")
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
        // The \(\.$kind) phrases put every stop kind in Siri's vocabulary:
        // "find showers in FLOWS", "find truck parking in FLOWS".
        AppShortcut(
            intent: FindStopIntent(),
            phrases: ["Find a stop in \(.applicationName)",
                      "Find \(\.$kind) in \(.applicationName)",
                      "Find \(\.$kind) ahead in \(.applicationName)",
                      "Find a \(\.$kind) stop in \(.applicationName)"],
            shortTitle: "Find a stop",
            systemImageName: "fuelpump.fill")
        // Chain names become spoken vocabulary via \(\.$chain):
        // "add a Starbucks to our route in FLOWS", "stop at Love's in FLOWS".
        AppShortcut(
            intent: AddChainStopIntent(),
            phrases: ["Add a \(\.$chain) to my route in \(.applicationName)",
                      "Add a \(\.$chain) to our route in \(.applicationName)",
                      "Add a \(\.$chain) to the route in \(.applicationName)",
                      "Add a \(\.$chain) stop in \(.applicationName)",
                      "Stop at \(\.$chain) in \(.applicationName)",
                      "Can you add a \(\.$chain) to our route in \(.applicationName)"],
            shortTitle: "Add a chain stop",
            systemImageName: "plus.circle.fill")
        AppShortcut(
            intent: AddPlaceStopIntent(),
            phrases: ["Add a stop in \(.applicationName)",
                      "Add a stop to my route in \(.applicationName)",
                      "Add a stop to our route in \(.applicationName)",
                      "Add a place to my route in \(.applicationName)"],
            shortTitle: "Add a stop",
            systemImageName: "mappin.circle.fill")
        AppShortcut(
            intent: RouteAheadIntent(),
            phrases: ["How's the road ahead in \(.applicationName)",
                      "What's ahead in \(.applicationName)",
                      "How far to go in \(.applicationName)",
                      "How much longer in \(.applicationName)"],
            shortTitle: "Road ahead",
            systemImageName: "road.lanes")
        AppShortcut(
            intent: PlayWeatherRadioIntent(),
            phrases: ["Play the weather radio in \(.applicationName)",
                      "Play weather radio in \(.applicationName)",
                      "Turn on the weather radio in \(.applicationName)"],
            shortTitle: "Weather radio",
            systemImageName: "radio.fill")
        AppShortcut(
            intent: PlayStationIntent(),
            phrases: ["Play a radio station in \(.applicationName)",
                      "Play some radio in \(.applicationName)",
                      "Play AM FM radio in \(.applicationName)"],
            shortTitle: "Play a station",
            systemImageName: "antenna.radiowaves.left.and.right")
        AppShortcut(
            intent: StopRadioIntent(),
            phrases: ["Stop the radio in \(.applicationName)",
                      "Turn off the radio in \(.applicationName)"],
            shortTitle: "Stop radio",
            systemImageName: "stop.circle")
    }
}
