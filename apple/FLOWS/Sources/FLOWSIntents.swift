// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import AppIntents
import Foundation
import MapKit

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

/// One music intent, four spoken actions — App Shortcuts are capped at 10
/// per app, and the route/radio/voice-approval intents need the slots.
enum MusicActionOption: String, AppEnum {
    case play = "Play"
    case pause = "Pause"
    case skip = "Skip"
    case shuffle = "Shuffle"
    // Full-sentence cases ride the bare "\(action) in FLOWS" phrase:
    // "Play the next song in FLOWS", "Play the last song in FLOWS".
    case nextSong = "Play the next song"
    case lastSong = "Play the last song"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Music action")
    static let caseDisplayRepresentations: [MusicActionOption: DisplayRepresentation] = [
        .play: "Play", .pause: "Pause", .skip: "Skip", .shuffle: "Shuffle",
        .nextSong: "Play the next song", .lastSong: "Play the last song",
    ]
}

struct MusicControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Control music"
    static let description = IntentDescription(
        "Plays, pauses, skips, or shuffles music while navigating.")

    @Parameter(title: "Action")
    var action: MusicActionOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let music = MusicController.shared
        guard music.controlsInPlace else {
            return .result(dialog: musicHandsOffDialog())
        }
        switch action {
        case .play:
            if !music.isPlaying { music.playPause() }
            return .result(dialog: "Playing.")
        case .pause:
            if music.isPlaying { music.playPause() }
            return .result(dialog: "Paused.")
        case .skip, .nextSong:
            music.skip()
            return .result(dialog: "Next song.")
        case .lastSong:
            music.back()
            return .result(dialog: "Back a song.")
        case .shuffle:
            music.toggleShuffle()
            return .result(dialog: music.shuffleOn ? "Shuffle on." : "Shuffle off.")
        }
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
        "Searches for fuel, food, rest areas, hotels, parking, showers, medical help, or shelters ahead — then offers the best options by name.")
    static let openAppWhenRun = true

    @Parameter(title: "Kind of stop")
    var kind: StopKindOption

    /// Spoken follow-ups (never surfaced as up-front Siri questions —
    /// asked mid-dialogue only when the step is reached).
    @Parameter(title: "Food type")
    var cuisine: String?

    @Parameter(title: "Place")
    var choice: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared else {
            return .result(dialog: "Open FLOWS first.")
        }
        let position = model.effectivePosition

        // FOOD gets the extra step the picker gives on screen: "do you
        // prefer Mexican, Greek, or fast food?" — the reply can name a
        // cuisine in any sentence ("I want Mexican").
        let categories = FoodCategory.allCases
        let cuisineNames = categories.map(\.rawValue)
        if kind == .food {
            var cuisineReply = cuisine ?? ""
            if cuisineReply.isEmpty {
                let asked: String? = try await $cuisine.requestValue(
                    "Yes — what sounds good: fast food, pizza, American, Mexican, Italian, Chinese, Greek, coffee, or breakfast?")
                cuisineReply = asked ?? ""
            }
            // Deterministic match first; when it can't read the reply, the
            // ON-DEVICE model gets one shot at mapping it ("the spicy one
            // with tortillas" → Mexican) before the on-screen fallback —
            // the finding-the-right-words accessibility path.
            var cuisineOutcome = VoicePick.choose(reply: cuisineReply,
                                                  options: cuisineNames)
            if case .picked = cuisineOutcome {} else if let idx =
                await IntentClarifier.pick(reply: cuisineReply, options: cuisineNames) {
                cuisineOutcome = .picked(idx)
            }
            guard case .picked(let index) = cuisineOutcome else {
                await model.poi.request(.food, aheadOf: position)
                return .result(dialog: "Okay — the food picker is on screen.")
            }
            await model.poi.chooseFood(categories[index], aheadOf: position)
        } else {
            await model.poi.request(kind.poiKind, aheadOf: position)
            // Stores (and first-run fuel) divert into their category
            // pickers — no results yet, and "nothing found" would be a lie.
            if model.poi.pendingFuelChoice || model.poi.pendingStoreChoice {
                return .result(dialog: "Opening FLOWS — pick the exact type there.")
            }
        }

        // The place-offer step loops so a CHANGE OF MIND works mid-dialogue:
        // naming another cuisine ("actually, Mexican") or saying "go back"
        // re-runs the food search; three rounds bound the conversation.
        for round in 0..<3 {
            let ranked = Array(model.poi.results.prefix(3))
            guard !ranked.isEmpty else {
                return .result(dialog: "Nothing found ahead on this route.")
            }
            // Not navigating: nothing to add a stop TO — the list on screen
            // is the deliverable.
            guard model.mode == .navigating else {
                return .result(dialog: IntentDialog(
                    "Found \(model.poi.results.count) options — they're on screen."))
            }
            // Offer the top names and take the answer in ANY form: naming
            // one picks it ("let's go to Taco Bell"), a bare yes takes the
            // first, a no leaves the on-screen list.
            let names = ranked.map { $0.item.name ?? "Unnamed stop" }
            var reply = round == 0 ? (choice ?? "") : ""
            if reply.isEmpty {
                let question = names.count == 1
                    ? "Does \(names[0]) work for you?"
                    : "Does \(names.dropLast().joined(separator: ", ")) or \(names.last ?? "") work for you?"
                let asked: String? = try await $choice.requestValue(IntentDialog("\(question)"))
                reply = asked ?? ""
            }
            let onlyFoodCuisines = kind == .food ? cuisineNames : []
            var outcome = VoicePick.placeReply(reply, places: names,
                                               cuisines: onlyFoodCuisines)
            // Same on-device rescue as the cuisine step: "the one with the
            // tacos" should reach Taco Bell, not dead-end at the list.
            if outcome == .unclear,
               let idx = await IntentClarifier.pick(reply: reply, options: names) {
                outcome = .picked(idx)
            }
            switch outcome {
            case .picked(let index):
                let pick = ranked[index]
                let name = pick.item.name ?? names[index]
                let meters = position.map {
                    POIRanking.meters($0, pick.item.placemark.coordinate)
                }
                await model.addStop(pick.item)
                guard model.pendingStopName == name else {
                    return .result(dialog: IntentDialog(
                        "Couldn't route to \(name) right now. Try again in a moment."))
                }
                return .result(dialog: IntentDialog(
                    "\(SiriSummaries.addedStop(name: name, meters: meters))"))
            case .switchCuisine(let index):
                await model.poi.chooseFood(categories[index], aheadOf: position)
                continue
            case .backToCuisine:
                guard kind == .food else {
                    return .result(dialog: "Okay — the list is on screen.")
                }
                let asked: String? = try await $cuisine.requestValue(
                    "What sounds good instead: fast food, pizza, American, Mexican, Italian, Chinese, Greek, coffee, or breakfast?")
                guard case .picked(let index) = VoicePick.choose(
                    reply: asked ?? "", options: cuisineNames) else {
                    return .result(dialog: "Okay — the list is on screen.")
                }
                await model.poi.chooseFood(categories[index], aheadOf: position)
                continue
            case .declined, .unclear:
                return .result(dialog: "Okay — the list is on screen.")
            }
        }
        return .result(dialog: "Okay — the list is on screen.")
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

/// One radio intent, three spoken actions — each case's display text IS
/// the natural phrase ("Play the weather radio in FLOWS", "Stop the radio
/// in FLOWS") via the parameterized shortcut phrase.
enum RadioActionOption: String, AppEnum {
    case weatherRadio = "Play the weather radio"
    case station = "Play a radio station"
    case off = "Stop the radio"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Radio action")
    static let caseDisplayRepresentations: [RadioActionOption: DisplayRepresentation] = [
        .weatherRadio: "Play the weather radio",
        .station: "Play a radio station",
        .off: "Stop the radio",
    ]
}

struct RadioControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Control the radio"
    static let description = IntentDescription(
        "Tunes the nearest NOAA weather radio, plays an AM/FM stream by name or genre, or stops the radio.")

    @Parameter(title: "Action")
    var action: RadioActionOption

    @Parameter(title: "Station or genre",
               requestValueDialog: "What station or kind of music?")
    var station: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared else {
            return .result(dialog: "Open FLOWS first.")
        }
        switch action {
        case .weatherRadio:
            let channel = model.effectivePosition
                .flatMap { model.radio.nearestChannel(to: $0)?.channel }
                ?? model.radio.nearestChannel(stateCode: model.currentStateCode)
            guard let channel else {
                return .result(dialog: "No weather stations loaded yet. Try again in a moment.")
            }
            model.radio.play(channel)
            return .result(dialog: IntentDialog("Playing \(channel.name)."))
        case .station:
            var term = station ?? ""
            if term.isEmpty {
                let asked: String? = try await $station.requestValue(
                    "What station or kind of music?")
                term = asked ?? ""
            }
            guard !term.isEmpty else {
                return .result(dialog: "Tell me a station name or a kind of music.")
            }
            await model.radioBrowser.search(text: term)
            guard let top = model.radioBrowser.stations.first else {
                return .result(dialog: IntentDialog("No station found for \(term)."))
            }
            model.radio.play(top.channel)
            return .result(dialog: IntentDialog("Playing \(top.name)."))
        case .off:
            model.radio.stop()
            return .result(dialog: "Radio stopped.")
        }
    }
}

// MARK: voice approval ("go ahead") + faster route + trip start

struct TakeFasterRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "Take the faster route"
    static let description = IntentDescription(
        "Accepts the faster route FLOWS offered around traffic.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared else {
            return .result(dialog: "Open FLOWS first.")
        }
        guard model.mode == .navigating else {
            return .result(dialog: "Start a route first.")
        }
        guard model.trafficDelayMinutes != nil else {
            return .result(dialog:
                "No faster route on offer right now — I'll speak up when one appears.")
        }
        await model.rerouteForTraffic()
        return .result(dialog: "Rerouting around the traffic.")
    }
}

/// The universal spoken YES: whatever FLOWS last offered out loud — a
/// faster route, a voice-planned trip — "go ahead in FLOWS" accepts it.
struct GoAheadIntent: AppIntent {
    static let title: LocalizedStringResource = "Go ahead"
    static let description = IntentDescription(
        "Accepts what FLOWS just offered — a faster route or a planned trip.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared else {
            return .result(dialog: "Open FLOWS first.")
        }
        switch model.pendingVoiceOffer {
        case .trip(let route, let name):
            model.select(route: route)
            return .result(dialog: IntentDialog("Starting to \(name)."))
        case .fasterRoute:
            model.pendingVoiceOffer = nil
            await model.rerouteForTraffic()
            return .result(dialog: "Rerouting around the traffic.")
        case nil:
            return .result(dialog: "Nothing is waiting for a yes right now.")
        }
    }
}

struct StartTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a trip"
    static let description = IntentDescription(
        "Plans a route to a spoken destination; say go ahead to start driving it.")
    static let openAppWhenRun = true

    @Parameter(title: "Destination", requestValueDialog: "Where to?")
    var destination: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared else {
            return .result(dialog: "Open FLOWS first.")
        }
        guard let from = model.effectivePosition else {
            return .result(dialog: "I need a location fix first — open FLOWS.")
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = destination
        request.region = MKCoordinateRegion(
            center: from,
            latitudinalMeters: 400_000, longitudinalMeters: 400_000)
        let hits = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        guard let place = hits.first else {
            return .result(dialog: IntentDialog("Couldn't find \(destination)."))
        }
        let name = place.name ?? destination
        guard let routes = try? await model.plan(
                from: from, fromName: "Current location",
                to: place.placemark.coordinate, toName: name),
              let best = routes.first else {
            return .result(dialog: IntentDialog("No route found to \(name)."))
        }
        // The route CHOICES show on screen (risk colors and all); the spoken
        // yes starts the first one. Nothing drives until the driver approves.
        model.routeChoices = routes
        model.pendingVoiceOffer = .trip(route: best, name: name)
        let summary = "Route to \(name): about "
            + SiriSummaries.spokenMiles(meters: best.distanceMeters) + " and "
            + SiriSummaries.spokenTime(seconds: best.eta)
            + ". Say: go ahead in FLOWS — or pick a route on screen."
        return .result(dialog: IntentDialog("\(summary)"))
    }
}

// MARK: emergency readout ("read the alert")

struct ReadAlertIntent: AppIntent {
    static let title: LocalizedStringResource = "Read the emergency alert"
    static let description = IntentDescription(
        "Reads the emergency or weather alert on your route out loud.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared else {
            return .result(dialog: "Open FLOWS first.")
        }
        if let warning = model.imminentWarning {
            var text = SiriSummaries.emergencyAnnouncement(
                event: warning.event, headline: warning.headline,
                action: warning.action)
            if let detail = warning.detail, !detail.isEmpty {
                let clipped = SiriSummaries.spokenClip(detail, limit: 300)
                text += " " + clipped + (clipped.hasSuffix(".") ? "" : ".")
            }
            return .result(dialog: IntentDialog("\(text)"))
        }
        let headlines = model.alerts.activeHeadlines
        guard !headlines.isEmpty else {
            return .result(dialog: "No emergency alerts on your route right now.")
        }
        let spoken = headlines.prefix(2)
            .map { SiriSummaries.spokenClip($0) }
            .joined(separator: ". ")
        return .result(dialog: IntentDialog("On your route: \(spoken)."))
    }
}

struct FLOWSShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Apple caps App Shortcuts at 10 per app — every slot below earns
        // its place, and music/radio ride ONE parameterized slot each.
        AppShortcut(
            intent: MusicControlIntent(),
            phrases: ["\(\.$action) music in \(.applicationName)",
                      "\(\.$action) the music in \(.applicationName)",
                      "\(\.$action) in \(.applicationName)"],
            shortTitle: "Music",
            systemImageName: "playpause.fill")
        // Case display text IS the phrase: "Play the weather radio in
        // FLOWS", "Play a radio station in FLOWS", "Stop the radio in FLOWS".
        AppShortcut(
            intent: RadioControlIntent(),
            phrases: ["\(\.$action) in \(.applicationName)"],
            shortTitle: "Radio",
            systemImageName: "radio.fill")
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
            intent: TakeFasterRouteIntent(),
            phrases: ["Take the faster route in \(.applicationName)",
                      "Take the fast route in \(.applicationName)",
                      "Yes take the faster route in \(.applicationName)"],
            shortTitle: "Faster route",
            systemImageName: "arrow.triangle.swap")
        AppShortcut(
            intent: GoAheadIntent(),
            phrases: ["Go ahead in \(.applicationName)",
                      "Yes go ahead in \(.applicationName)",
                      "Do it in \(.applicationName)"],
            shortTitle: "Go ahead",
            systemImageName: "checkmark.circle.fill")
        AppShortcut(
            intent: StartTripIntent(),
            phrases: ["Start a trip in \(.applicationName)",
                      "Navigate in \(.applicationName)",
                      "Plan a route in \(.applicationName)",
                      "Take me somewhere in \(.applicationName)"],
            shortTitle: "Start a trip",
            systemImageName: "map.fill")
        AppShortcut(
            intent: ReadAlertIntent(),
            phrases: ["Read the alert in \(.applicationName)",
                      "Read the emergency alert in \(.applicationName)",
                      "What's the alert in \(.applicationName)"],
            shortTitle: "Read the alert",
            systemImageName: "exclamationmark.triangle.fill")
    }
}
