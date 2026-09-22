// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Combine
import CoreLocation
import MapKit
import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// App-wide mode: plan on a continent-scale map, then flip to a time-sensitive
/// zoomed turn-by-turn view once a route is chosen (see NavigationEngine for
/// the zoom policy).
enum AppMode: Equatable {
    case planning            // browse map, search, enter route endpoints
    case choosing            // alternates returned, user picks one
    case navigating          // turn-by-turn against GPS + speed
}

@MainActor
final class AppModel: ObservableObject {
    /// The live model, for App Intents (Siri buttons) — set in init; the app
    /// has exactly one AppModel for its lifetime.
    static weak var shared: AppModel?

    @Published var mode: AppMode = .planning
    @Published var routeChoices: [PlannedRoute] = []
    /// The selected public-transit itinerary (walk → ride → walk), drawn on the
    /// map and stepped in-app. Cleared whenever drive routes are (re)presented.
    @Published var transitItinerary: TransitItinerary?
    /// Transit planning state on the CHOICES screen: which rail/bus/plane
    /// toggles are on and each mode's computed option card. On the model, not
    /// view @State — rotating the phone flips the size class, which rebuilds
    /// the chrome tree and was forgetting the driver's toggles and cards
    /// right before a journey started. Cleared with each fresh plan.
    @Published var transitOptions: [TransitMode: TransitOption] = [:]
    @Published var activeTransitModes: Set<TransitMode> = []
    /// In-flight per-mode transit computations (cancel targets, not UI state).
    var transitTasks: [TransitMode: Task<Void, Never>] = [:]
    /// Walking mode's walk + paid-ride offer, and the plan it was computed
    /// (or dismissed) for — the key stops a rotation from recomputing an
    /// offer the walker already closed.
    @Published var hybridOption: HybridOption?
    var hybridOptionKey = ""
    /// Route emphasized on the map while choosing (tap a card to change);
    /// alternates draw gray underneath, Apple/Google Maps style.
    @Published var highlightedRouteID: UUID? {
        didSet {
            // Tourist filter follows the highlight: attractions re-search along
            // the newly-highlighted route so the map pins ITS stops. (Each
            // card's count comes from its own sweep: touristCounts.)
            if routeFilters.contains(.tourist), mode == .choosing,
               oldValue != highlightedRouteID {
                refreshTouristSpots()
            }
        }
    }

    /// The driver tapped the highlighted card. Until then the highlight is
    /// the app's own pick and follows the top card when the list changes —
    /// it stayed on a route a filter had picked after that filter went off,
    /// under a different top card. A tapped route stays while it is listed.
    private var highlightIsDriverChoice = false

    /// A card tap: highlight that route and keep it (ensureHighlightValid).
    func highlightChosen(_ id: UUID) {
        highlightIsDriverChoice = true
        highlightedRouteID = id
    }

    /// (Re)pin attractions along the highlighted route (tourist filter).
    func refreshTouristSpots() {
        guard let route = routeChoices.first(where: { $0.id == highlightedRouteID })
            ?? routeChoices.first else { return }
        poi.beginCorridorSearch(along: route)
        let origin = lastPlanEndpoints?.from
        Task { await poi.request(.tourist, aheadOf: origin) }
    }

    /// Each route's own count of attractions near ITS road, from a sweep
    /// along that route (POIService.touristCount) — what the tourist order
    /// and the cards' counts read. Counting the pins, which follow the
    /// highlight, gave the tapped card the most and moved it to the top.
    @Published private(set) var touristCounts: [UUID: Int] = [:]
    private var touristCountTask: Task<Void, Never>?

    /// Count the routes that have no count yet, one at a time, then let an
    /// untapped highlight follow the top card the new order may bring.
    func refreshTouristCounts() {
        touristCountTask?.cancel()
        let pending = routeChoices.filter { touristCounts[$0.id] == nil }
        guard !pending.isEmpty else { return }
        touristCountTask = Task { [weak self] in
            for route in pending {
                // A plan left for Edit or GO needs no more counts.
                guard let self, self.mode == .choosing else { return }
                let count = await self.poi.touristCount(along: route)
                guard !Task.isCancelled else { return }
                self.touristCounts[route.id] = count
            }
            guard let self, self.mode == .choosing else { return }
            self.ensureHighlightValid()
        }
    }

    let location = LocationService()
    let router = RouteService()
    /// Recently planned destinations — one tap re-plans, works offline.
    let recents = RecentDestinations()
    let poi = POIService()
    let alerts = WeatherAlertService()
    /// Offline lifeline: GPS breadcrumb trail + network-path monitor.
    let breadcrumbs = BreadcrumbTrail()
    /// The other half of the offline lifeline: the ROAD AHEAD for trips
    /// between towns, saved to disk so losing signal (or force-quitting in
    /// the middle of nowhere) still leaves the way home on screen.
    let corridors = OfflineCorridorStore()
    /// Learns how much longer drives REALLY take by time of day and weather,
    /// from this device's own completed trips (TrafficLearning).
    let trafficModel = TrafficDelayModel()
    /// Learns what this vehicle really gets on the roads this driver really
    /// drives (RoadEfficiencyLearning) — feeds range, fuel timing, routes.
    let roadEfficiency = RoadEfficiencyModel()
    let riskField = RiskFieldService()
    let favorites = FavoritesStore()
    let vehicle = VehicleStore()
    let radio = TruckerRadio()
    /// AM/FM station search (radio-browser.info community directory) —
    /// plays through the same TruckerRadio AVPlayer path, so CarPlay, the
    /// lock screen and Siri all drive one player. Station SELECTION —
    /// which genre, which of them are actually local — is BroadcastRadio.
    let radioBrowser = RadioBrowser()
    /// Dispatch traffic transcribed ON THIS DEVICE into temporary map pins.
    /// Off unless the operator supplied a feed list — see ScannerListener.
    let scanner = ScannerListener()
    let crash = CrashDetectionService()
    /// Prior long-trip share recipients (on-device only) — suggestion ranking.
    let shareHistory = ShareHistoryStore()
    let vehicleLink = VehicleLink()
    let smartcar = SmartcarLink()
    let watch = WatchLink()
    let navigation: NavigationEngine

    /// Cost-tier country (US/CA/MX), switched automatically by GPS.
    var costCountry: RatingsAndCost.Country {
        guard let c = location.coordinate else { return .us }
        return RatingsAndCost.Country.forCoordinate(latitude: c.latitude,
                                                    longitude: c.longitude)
    }

    /// Trucker radio follows the vehicle: auto-retune to the nearest
    /// station as you cross states (toggleable).
    @Published var radioAutoSwitch: Bool =
        UserDefaults.standard.object(forKey: "flows.radioAutoSwitch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(radioAutoSwitch, forKey: "flows.radioAutoSwitch") }
    }
    private var lastRadioState: String?
    /// Two-letter state the vehicle is currently in (reverse-geocoded on
    /// corridor updates) — drives radio nearest-station defaults.
    @Published private(set) var currentStateCode: String? {
        didSet {
            // Pin the home/current state's offline-places shard (never evicted).
            if let code = currentStateCode, code.count == 2 {
                PlacesStore.shared.pinnedState = code.uppercased()
            }
        }
    }

    /// Called on corridor updates: retune to the nearest station when the
    /// vehicle's state changes (auto-switch on + a weather station on the
    /// air that isn't paused or picked by hand — TruckerRadio.followsTheDrive).
    func retuneRadioIfNeeded(stateCode: String?) {
        guard radioAutoSwitch, radio.followsTheDrive,
              let stateCode, stateCode != lastRadioState else { return }
        lastRadioState = stateCode
        // GPS-precise retune when a position exists; state match is the fallback.
        if let pos = effectivePosition {
            retuneRadioIfNeeded(at: pos)
            return
        }
        if let nearest = radio.nearestChannel(stateCode: stateCode),
           nearest.id != radio.playingChannelID {
            radio.play(nearest)
        }
    }

    // MARK: dark mode by the sun, not by the clock

    /// True while it is dark out WHERE THE DRIVER IS. Drives the whole app's
    /// appearance: a white card is painful in a dark cab and a dark one is
    /// unreadable in daylight, and the hour that divides them is different
    /// in Miami in June than in Fairbanks in December.
    @Published private(set) var isNight = false
    /// Honor an explicit choice over the sun. nil = follow the daylight.
    @Published var appearanceOverride: Bool? =
        UserDefaults.standard.object(forKey: "flows.darkOverride") as? Bool {
        didSet {
            UserDefaults.standard.set(appearanceOverride, forKey: "flows.darkOverride")
            refreshDaylight()
        }
    }
    private var daylightTimer: Timer?

    deinit {
        // The daylight timer reschedules itself; without this it sits in the
        // run loop until its next fire even though nothing is left to tell.
        daylightTimer?.invalidate()
    }

    /// The appearance the window should use, or nil to follow the system
    /// when there is no position to compute dusk from yet.
    var resolvedColorScheme: ColorScheme? {
        if let appearanceOverride { return appearanceOverride ? .dark : .light }
        guard effectivePosition != nil else { return nil }
        return isNight ? .dark : .light
    }

    /// Recompute now, and schedule the next look for the exact moment of the
    /// next dawn or dusk — so the switch lands ON the boundary instead of up
    /// to a poll-interval late. Capped at an hour so a long drive west (or a
    /// crossed time zone) still gets rechecked.
    func refreshDaylight() {
        guard let pos = effectivePosition else {
            // No fix yet. Don't give up — look again shortly, or the app sits
            // in daylight colors for the first seconds of a night launch and
            // then snaps dark once a fix lands.
            daylightTimer?.invalidate()
            daylightTimer = Timer.scheduledTimer(withTimeInterval: 3,
                                                 repeats: false) { [weak self] _ in
                Task { @MainActor in self?.refreshDaylight() }
            }
            return
        }
        let night = DaylightClock.isNight(at: pos)
        if night != isNight { isNight = night }
        daylightTimer?.invalidate()
        let next = DaylightClock.nextChange(at: pos)
        let delay = min(max(next.timeIntervalSinceNow, 1), 3_600)
        daylightTimer = Timer.scheduledTimer(withTimeInterval: delay,
                                             repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshDaylight() }
        }
    }

    /// The transmitter closest to where the vehicle is NOW, whether or not
    /// the radio is playing. Published so the radio card's picker follows
    /// the drive instead of standing on the station that was closest when
    /// the card first opened.
    @Published private(set) var nearestStationID: String?

    /// Auto-switch to the CLOSEST NOAA transmitter as the driver moves, with
    /// hysteresis: only retune when the new station is meaningfully (20%)
    /// closer than the one playing, so the tuner doesn't flap on the boundary
    /// between two coverage circles.
    func retuneRadioIfNeeded(at position: CLLocationCoordinate2D) {
        // Track the nearest station even when nothing is playing — the card
        // reads this to keep its default honest. The app still never starts
        // audio by itself.
        let closest = radio.nearestChannel(to: position)?.channel.id
        if closest != nearestStationID { nearestStationID = closest }
        guard radioAutoSwitch, let next = radio.retuneTarget(for: position)
        else { return }
        radio.play(next)
    }

    /// TomTom key (free tier: developer.tomtom.com) → live station fuel
    /// prices where licensed; state estimates otherwise. A key is a
    /// credential, so it lives in the Keychain like the Spotify token —
    /// moved out of the plaintext preferences on first launch.
    @Published var tomtomAPIKey: String =
        SecureStore.migrateFromDefaults(key: "tomtom.key", defaultsKey: "flows.tomtomKey") {
        didSet {
            SecureStore.set(tomtomAPIKey, for: "tomtom.key")
            let key = tomtomAPIKey
            Task { await TomTomFuel.shared.setKey(key) }
        }
    }

    /// Route planning mode: driving or walking (Apple's pedestrian network —
    /// sidewalks/crossings where mapped, real walking pace).
    @Published var walkingMode = false {
        didSet {
            // didSet runs on every assignment, and Edit writes false each
            // time: re-running the off branch took away a No highways the
            // driver had chosen.
            guard walkingMode != oldValue else { return }
            // People must not walk on highways; buses may use them. Walking
            // takes back only the filter it added.
            if walkingMode {
                let forced = RouteFilter.forcing([.noHighways], onto: routeFilters)
                walkingAddedFilters = forced.added
                routeFilters = forced.filters
            } else {
                routeFilters.subtract(walkingAddedFilters)
                walkingAddedFilters = []
            }
        }
    }
    /// The filters walking switched on itself — the only ones it switches
    /// off again (towing keeps its own in `towingFilterHold`).
    private var walkingAddedFilters: Set<RouteFilter> = []
    /// Corridor risk display floor: pedestrians are exposed — walking mode
    /// raises weather sensitivity (lower floor = lighter weather shows).
    /// Score floor for the LOUD map layers (badges + striped ZCTA areas).
    /// Keyed to the app's own clear/green boundary: the clear band is by
    /// definition "normal for here, right now" and stays quiet — a humid July
    /// night's rain-chance predictors noisy-OR to ~0.3 across whole states,
    /// and at the old 0.25 floor that painted stripes and badges everywhere
    /// ("is something exaggerated in the equations?" — no, the FLOOR was
    /// below the app's own definition of quiet). Sub-floor weather still
    /// shows as the faint grid tint, so the driver sees conditions without
    /// the map shouting. Walking mode keeps a lower floor — pedestrians are
    /// exposed to weather a car shrugs off.
    var riskDisplayFloor: Double { walkingMode ? 0.30 : FlowsCore.riskGreenMin }

    /// Yelp Fusion key (free: yelp.com/developers) → stars + $ tiers.
    /// Google Places API (New) key — the alternate ratings source (free
    /// monthly quota; Yelp Fusion went paid). Either key lights up stars/$.
    /// Both are credentials: Keychain, migrated like the TomTom key.
    @Published var googlePlacesAPIKey: String =
        SecureStore.migrateFromDefaults(key: "googlePlaces.key", defaultsKey: "flows.googlePlacesKey") {
        didSet {
            SecureStore.set(googlePlacesAPIKey, for: "googlePlaces.key")
            let key = googlePlacesAPIKey
            Task { await GooglePlacesLink.shared.setKey(key) }
        }
    }

    @Published var yelpAPIKey: String =
        SecureStore.migrateFromDefaults(key: "yelp.key", defaultsKey: "flows.yelpKey") {
        didSet {
            SecureStore.set(yelpAPIKey, for: "yelp.key")
            let key = yelpAPIKey
            Task { await YelpLink.shared.setKey(key) }
        }
    }

    // MARK: towing mode

    /// Towing ON auto-applies the safety filters (grades, low bridges,
    /// bridge weight, high winds) and switches fuel prediction to the
    /// towing pattern.
    @Published var towingActive: Bool =
        UserDefaults.standard.bool(forKey: "flows.towingActive") {
        didSet {
            UserDefaults.standard.set(towingActive, forKey: "flows.towingActive")
            vehicle.towingActive = towingActive
            // Only on a real change, and taking back only what towing added:
            // a No low bridges picked before towing (or by hand since)
            // outlives it.
            if towingActive != oldValue {
                if towingActive {
                    towingFilterHold.towingOn(&routeFilters)
                } else {
                    towingFilterHold.towingOff(&routeFilters)
                }
            }
            applyVehicleMaxGradeDefault()   // towing lowers the grade default
            rebuildTripNeeds()   // fuel stops follow the towing range mid-trip
        }
    }
    /// The towing filters towing itself turned on (see TowingFilterHold).
    private var towingFilterHold = TowingFilterHold()
    @Published var showTowingCard = false
    /// Re-center buttons, the drive bar's and the planning map's
    /// (ContentView consumes + resets).
    @Published var recenterRequested = false
    /// Live state-DOT work zones (WZDx) near the corridor ahead.
    @Published private(set) var workZonesAhead = 0
    @Published private(set) var workZoneRoad: String?
    @Published var towVehicleWeightLbs: Double =
        UserDefaults.standard.object(forKey: "flows.towVehicleLbs") as? Double ?? 0 {
        didSet { UserDefaults.standard.set(towVehicleWeightLbs, forKey: "flows.towVehicleLbs") }
    }
    @Published var towTrailerWeightLbs: Double =
        UserDefaults.standard.object(forKey: "flows.towTrailerLbs") as? Double ?? 0 {
        didSet {
            UserDefaults.standard.set(towTrailerWeightLbs, forKey: "flows.towTrailerLbs")
            // Entering a trailer weight IS declaring you're towing.
            if towTrailerWeightLbs > 0, !towingActive { towingActive = true }
            applyVehicleMaxGradeDefault()   // a heavier trailer lowers it further
        }
    }
    /// The vehicle's manufacturer ratings (from the spec table entry).
    var towingRatings: TowingLimits.Ratings {
        guard let v = vehicle.profile else {
            return TowingLimits.Ratings(gvwrLbs: nil, towCapacityLbs: nil, gcwrLbs: nil)
        }
        // Profile-carried ratings first (works for EPA-path vehicles too);
        // curated-table lookup as the fallback for older saved profiles.
        if v.gvwrLbs != nil || v.towCapacityLbs != nil {
            return TowingLimits.Ratings(gvwrLbs: v.gvwrLbs,
                                        towCapacityLbs: v.towCapacityLbs,
                                        gcwrLbs: v.gcwrLbs)
        }
        // Curated table, else CLASS-TYPICAL estimates from the vehicle's shape
        // (EPA-path vehicles have economy but no published weights) — the card
        // labels estimates as such; "No published rating" never blanks the
        // submenu numbers again.
        return VehicleSpecs.spec(make: v.make, model: v.model)?.towingRatings
            ?? TowingLimits.estimatedRatings(heightFeet: vehicleHeightFeet,
                                             fuelType: v.fuelType)
    }
    var towingViolations: [TowingLimits.Violation] {
        TowingLimits.check(vehicleWeightLbs: towVehicleWeightLbs,
                           towedWeightLbs: towTrailerWeightLbs,
                           ratings: towingRatings)
    }

    /// Whether the refuel gauge should ask (learning under its 80% floor).
    @Published var refuelCheckInsEnabled: Bool =
        UserDefaults.standard.object(forKey: "flows.refuelCheckIns") as? Bool ?? true {
        didSet { UserDefaults.standard.set(refuelCheckInsEnabled, forKey: "flows.refuelCheckIns") }
    }

    /// DEMO: inject a synthetic AMBER red alert (with vehicle + child
    /// entities and a reach circle) so the card and map symbol can be seen
    /// without a live emergency. Auto-clears with the X press, like a real one.
    func demoRedAlert(near coordinate: CLLocationCoordinate2D) {
        let headline = "AMBER Alert: suspect vehicle is a red Toyota pickup truck, "
            + "last seen 25 minutes ago near the marked location"
        let detail = "The child is a 7-year-old girl wearing a blue jacket. "
            + "Vehicle traveling northbound. If seen, call 911 — do not approach."
        let demoEvent = "Child Abduction Emergency (DEMO)"
        let describesEntity = AlertEntityParser.describesAnEntity(event: demoEvent)
        imminentWarning = ImminentWarning(
            alertID: "demo-amber",
            event: demoEvent,
            headline: headline,
            detail: detail,
            sourceURL: URL(string: "https://www.missingkids.org/amber"),
            action: .lookout,
            etaSeconds: 300,
            vehicleEntity: describesEntity
                ? AlertEntityParser.vehicle(in: headline + " " + detail) : nil,
            personEntity: describesEntity
                ? AlertEntityParser.person(in: detail) : nil,
            incidentCoordinate: coordinate,
            onset: Date().addingTimeInterval(-25 * 60),
            reachSpeedMph: 55)
    }

    // MARK: notification toggles (gear settings) — every alert type is
    // individually switchable.
    // Switched off mid-trip, a type's message already on screen goes with
    // it: the switches only gated the next update, so a banner stayed up
    // until X or End.
    @Published var notifyImminent = UserDefaults.standard.object(forKey: "flows.notifyImminent") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notifyImminent, forKey: "flows.notifyImminent")
            // Red stays: a red card leaves only when the driver presses it.
            if !notifyImminent, imminentWarning?.action.isRed == false { imminentWarning = nil }
        }
    }
    @Published var notifyEscalation = UserDefaults.standard.object(forKey: "flows.notifyEscalation") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notifyEscalation, forKey: "flows.notifyEscalation")
            if !notifyEscalation { escalation = nil }
        }
    }
    /// The traffic chip, the offer on it and the work-zone chip. FLOWS
    /// weighs a jam whatever this says, and takes a faster road that adds
    /// no risk on its own (owner item 9); only an offer needs the chip.
    @Published var notifyTraffic = UserDefaults.standard.object(forKey: "flows.notifyTraffic") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notifyTraffic, forKey: "flows.notifyTraffic")
            // The chip hides at once (the HUD reads this); its offer, the
            // spoken ask and the yes it waits for, is withdrawn with it.
            if !notifyTraffic {
                VoiceAnnouncer.shared.cancel(topic: SpeechTopic.trafficOffer)
                if case .fasterRoute? = pendingVoiceOffer { pendingVoiceOffer = nil }
            }
        }
    }

    /// Speak faster-route offers and corridor warnings out loud — the
    /// hands-free loop: FLOWS announces, then listens for the plain yes/no
    /// (and "go ahead in FLOWS" works via Siri). Off = screen-only.
    @Published var voiceAlerts =
        UserDefaults.standard.object(forKey: "flows.voiceAlerts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(voiceAlerts, forKey: "flows.voiceAlerts") }
    }

    /// Turn-by-turn voice directions — its own switch, separate from the
    /// alert voice: plenty of drivers want turns spoken but a quiet map,
    /// or the reverse.
    @Published var speakTurns =
        UserDefaults.standard.object(forKey: "flows.speakTurns") as? Bool ?? true {
        didSet { UserDefaults.standard.set(speakTurns, forKey: "flows.speakTurns") }
    }

    /// First launch shows ONE welcome card naming every permission and why
    /// (location now; the rest only when their feature is first used) —
    /// instead of a stack of unexplained system dialogs.
    @Published var onboarded = UserDefaults.standard.bool(forKey: "flows.onboarded")

    /// Get-started press: remember it, then run the ONE up-front system
    /// prompt (location — it powers navigation and the risk map).
    func completeOnboarding() {
        onboarded = true
        UserDefaults.standard.set(true, forKey: "flows.onboarded")
        location.requestAuthorization()
    }

    /// Word-finding help (on-device Apple Intelligence): when a spoken
    /// dialogue reply can't be matched exactly, the phone's own model maps
    /// it to the offered choices. Default ON — it only rescues replies
    /// that would otherwise dead-end, and nothing leaves the phone.
    @Published var wordFindingHelp =
        UserDefaults.standard.object(forKey: "flows.wordFindingHelp") as? Bool ?? true {
        didSet { UserDefaults.standard.set(wordFindingHelp, forKey: "flows.wordFindingHelp") }
    }

    /// Speak FLOWS's announcements in the user's own Personal Voice
    /// (Settings → Accessibility → Personal Voice). Default OFF — using
    /// someone's voice is their call, and the system asks permission once.
    @Published var personalVoiceAnnouncements =
        UserDefaults.standard.bool(forKey: "flows.personalVoice") {
        didSet {
            UserDefaults.standard.set(personalVoiceAnnouncements, forKey: "flows.personalVoice")
            VoiceAnnouncer.shared.setPersonalVoiceEnabled(personalVoiceAnnouncements)
        }
    }

    /// Felt tap with every spoken alert/offer — the hearing-parity channel.
    /// Default ON; a deaf driver relies on it, everyone else barely
    /// notices it under road vibration.
    @Published var hapticAlerts =
        UserDefaults.standard.object(forKey: "flows.hapticAlerts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hapticAlerts, forKey: "flows.hapticAlerts") }
    }

    /// In-app text size (Settings slider): −1 follows the phone's setting;
    /// otherwise an index into TextScale.steps. Both paths are clamped to
    /// what the current screen holds (textSizeMaxIndex).
    @Published var textSizeIndex: Int =
        UserDefaults.standard.object(forKey: "flows.textSizeIndex") as? Int ?? -1 {
        didSet { UserDefaults.standard.set(textSizeIndex, forKey: "flows.textSizeIndex") }
    }
    /// Highest slider step the current window width can hold — measured at
    /// the app root, read by the Settings slider for its range.
    @Published var textSizeMaxIndex: Int = TextScale.steps.count - 1

    /// Guidance state for the spoken turns: last step announced, and
    /// whether its close-in reminder has fired.
    private var lastSpokenTurnStep = -1
    /// Last valid course sent to the watch. GPS reports -1 when it has no
    /// course (stopped, or a poor fix); clamping that to 0 pointed the
    /// watch's arrow due north at every red light.
    private var lastWatchHeading: Double = 0
    private var turnNearSpoken = false

    /// Speak each maneuver twice: once when its step becomes current
    /// ("In a quarter mile, turn left…"), once close in (the instruction
    /// alone). Guidance updates at 1 Hz; everything else is deduped away.
    private func speakTurn(_ guidance: NavigationEngine.Guidance) {
        guard speakTurns, mode == .navigating, !guidance.isOffRoute,
              !guidance.instruction.isEmpty else { return }
        if guidance.stepIndex != lastSpokenTurnStep {
            lastSpokenTurnStep = guidance.stepIndex
            turnNearSpoken = guidance.distanceToManeuver < 150
            VoiceAnnouncer.shared.announce(
                turnNearSpoken
                    ? guidance.instruction
                    : SiriSummaries.spokenTurnDistance(meters: guidance.distanceToManeuver)
                        + ", " + guidance.instruction)
        } else if !turnNearSpoken, guidance.distanceToManeuver < 150 {
            turnNearSpoken = true
            VoiceAnnouncer.shared.announce(guidance.instruction)
        }
    }
    @Published var notifyFuel = UserDefaults.standard.object(forKey: "flows.notifyFuel") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyFuel, forKey: "flows.notifyFuel") }
    }
    @Published var crashDetectionEnabled = UserDefaults.standard.object(forKey: "flows.crashDetection") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(crashDetectionEnabled, forKey: "flows.crashDetection")
            guard CrashDetectionService.isAvailable else { return }
            // Switched on is its first use: the check-in's speech and
            // microphone are asked now, never after an impact.
            if crashDetectionEnabled {
                Task { await CrashDetectionService.askReplyPermissionsIfNeeded() }
            }
            // Mid-trip the switch works now, not at the next GO: on starts
            // watching for an impact, off stops watching (and a check-in
            // question with it; a help card already asked for stays up).
            guard mode == .navigating else { return }
            if crashDetectionEnabled {
                crash.begin()
            } else {
                crash.stopWatching()
            }
        }
    }

    /// Emergency contact + medical notes for the crash flow (Medical ID is
    /// not readable by apps — these live here instead).
    @Published var emergencyContactName = UserDefaults.standard.string(forKey: "flows.iceName") ?? "" {
        didSet { UserDefaults.standard.set(emergencyContactName, forKey: "flows.iceName") }
    }
    @Published var emergencyContactPhone = UserDefaults.standard.string(forKey: "flows.icePhone") ?? "" {
        didSet { UserDefaults.standard.set(emergencyContactPhone, forKey: "flows.icePhone") }
    }
    // Health data -> Keychain, not plaintext UserDefaults (backed up, readable).
    @Published var medicalNotes =
        SecureStore.migrateFromDefaults(key: "medicalNotes", defaultsKey: "flows.medicalNotes") {
        didSet { SecureStore.set(medicalNotes, for: "medicalNotes") }
    }
    private var serviceSubscriptions: Set<AnyCancellable> = []

    /// Map Filter state — the web app's primary-map selector.
    @Published var overlayFamily = "environmental"
    @Published var showRiskField = true

    /// Driver-tunable filter limits (right-hand sliders; persisted).
    @Published var vehicleHeightFeet: Double =
        UserDefaults.standard.object(forKey: "flows.vehicleHeightFeet") as? Double ?? 13.5 {
        didSet {
            UserDefaults.standard.set(vehicleHeightFeet, forKey: "flows.vehicleHeightFeet")
            applyVehicleMaxGradeDefault()   // height feeds the size-class fallback
        }
    }
    /// Grade limit in DEGREES — the unit a driver towing heavy thinks in
    /// (14° ≈ 25% grade). Converted to percent for the elevation-profile
    /// comparison in FilterLimits. Until the driver moves the slider, the
    /// value TRACKS the vehicle (`vehicleDefaultMaxGradeDegrees`); a manual
    /// move persists the choice and stops the tracking.
    @Published var maxGradeDegrees: Double =
        UserDefaults.standard.object(forKey: "flows.maxGradeDegrees") as? Double ?? 8.0 {
        didSet {
            guard !applyingDerivedMaxGrade else { return }
            maxGradeIsCustom = true
            UserDefaults.standard.set(maxGradeDegrees, forKey: "flows.maxGradeDegrees")
        }
    }
    /// True once the driver has set the grade slider themselves — the stored
    /// key only ever comes from a manual move, so its presence IS the flag.
    private var maxGradeIsCustom =
        UserDefaults.standard.object(forKey: "flows.maxGradeDegrees") != nil
    /// Set while the model itself writes the derived default, so didSet can
    /// tell a vehicle-driven update from the driver grabbing the slider.
    private var applyingDerivedMaxGrade = false

    /// The vehicle's own grade ceiling — "the grade where a parking brake is
    /// highly encouraged": maker guidance when the spec table has it, else
    /// the weight/height/towing heuristic (documented in FilterLimits).
    var vehicleDefaultMaxGradeDegrees: Double {
        let spec = vehicle.profile.flatMap {
            VehicleSpecs.spec(make: $0.make, model: $0.model)
        }
        let ratings = towingRatings
        return FilterLimits.vehicleDefaultMaxGradeDegrees(
            publishedMaxGradePercent: spec?.publishedMaxGradePercent,
            gvwrLbs: ratings.gvwrLbs,
            towCapacityLbs: ratings.towCapacityLbs,
            heightFeet: vehicleHeightFeet,
            towing: towingActive || towTrailerWeightLbs > 0,
            trailerWeightLbs: towTrailerWeightLbs)
    }

    /// Keep the grade slider on the vehicle's default until the driver moves
    /// it. `force` clears a manual override ("use my vehicle's number").
    func applyVehicleMaxGradeDefault(force: Bool = false) {
        if force {
            maxGradeIsCustom = false
            UserDefaults.standard.removeObject(forKey: "flows.maxGradeDegrees")
        }
        guard !maxGradeIsCustom else { return }
        let derived = vehicleDefaultMaxGradeDegrees
        guard abs(derived - maxGradeDegrees) > 0.01 else { return }
        applyingDerivedMaxGrade = true
        maxGradeDegrees = derived
        applyingDerivedMaxGrade = false
    }
    var filterLimits: FilterLimits {
        // Bridge-weight check compares posted limits against the whole rig:
        // the towing card's vehicle weight + towed weight. 0 = not entered
        // → nil, and the filter never excludes on a weight nobody gave it.
        // A trailer entered without the vehicle counts the vehicle at its
        // max rating: the trailer alone passed a 10,000 lb bridge for a
        // 13,000 lb rig.
        let rig = FilterLimits.rigVehicleLbs(entered: towVehicleWeightLbs,
                                             towedLbs: towTrailerWeightLbs,
                                             ratedMaxLbs: towingRatings.gvwrLbs)
            + towTrailerWeightLbs
        return FilterLimits(vehicleHeightMeters: vehicleHeightFeet * 0.3048,
                            maxGradePercent: FilterLimits.degreesToPercent(maxGradeDegrees),
                            rigWeightLbs: rig > 0 ? rig : nil)
    }
    /// Independent weather layer: snow/rain/storm blotches by type.
    @Published var showWeatherLayer = true
    /// Active route filters on the choices screen. Avoid-traffic defaults ON.
    @Published var routeFilters: Set<RouteFilter> = [.avoidTraffic] {
        didSet {
            // Touching the filters brings back a slider card a map click hid.
            if oldValue != routeFilters { filterCardsHidden = false }
        }
    }
    /// Click-off state for the height/grade slider card: a click on the map
    /// hides it; changing any filter shows it again.
    @Published var filterCardsHidden = false

    /// Menus tucked into the top-right icon tray (double-tap a menu's grab
    /// bar). On the model so rotation can't forget them; cleared when the
    /// screen changes underneath them (new plan, GO, trip end).
    ///
    /// ORDERED, like a stack of pancakes under the gear: closing a panel
    /// puts its icon at the BOTTOM of the pile, below the ones closed
    /// earlier; opening one takes its icon out of the pile. The gear always
    /// holds the first position. This used to be a Set rendered in a fixed
    /// list order, so the column never reflected what the driver had
    /// actually just put away.
    @Published var collapsedPanels = PanelStack(
        UserDefaults.standard.stringArray(forKey: "flows.collapsedPanels") ?? []) {
        didSet {
            // A driver who tucked something away meant it — remember across
            // sessions rather than springing it back on the next launch.
            UserDefaults.standard.set(collapsedPanels.order,
                                      forKey: "flows.collapsedPanels")
        }
    }

    // MARK: music provider

    /// The mini player's service. Apple Music plays in place
    /// (MPMusicPlayerController on iOS/CarPlay; Music.app on macOS). Every
    /// other service opens its own app — in-app control there needs that
    /// service's SDK.
    /// Defaults to the radio already in the dash: it needs no account and no
    /// subscription, so a driver who has told us nothing still gets audio.
    /// The first play press asks which service they'd rather use.
    @Published var musicProvider: MusicProvider = MusicProvider(
        rawValue: UserDefaults.standard.string(forKey: "flows.musicProvider") ?? ""
    ) ?? .radio {
        didSet {
            // The offline handoff and its restore assign this too. Those are
            // the app moving playback, not the driver picking a service —
            // counting them silenced the "which service?" question forever
            // after the first tunnel, and saving them made a handoff the
            // pick the next launch came back with. A pick of the driver's
            // own (the Settings picker binds here directly) also ends any
            // pending switch-back.
            if !settingProviderProgrammatically {
                UserDefaults.standard.set(musicProvider.rawValue, forKey: "flows.musicProvider")
                musicProviderChosen = true
                cancelOfflineHandoff()
            }
            MusicController.shared.provider = musicProvider
        }
    }
    /// False until the driver picks a service (Settings picker, or the ask
    /// that appears on the first play press).
    @Published var musicProviderChosen: Bool =
        UserDefaults.standard.string(forKey: "flows.musicProvider") != nil
    /// First play press: the "what do you play music with?" card.
    @Published var showMusicProviderPrompt = false

    /// OPTIONAL Spotify Web API token (Settings → Keys for extra info) —
    /// in-app play/pause/skip for Spotify on iOS. A bearer token is a
    /// credential, so it lives in the Keychain (SecureStore), never
    /// UserDefaults.
    @Published var spotifyWebToken: String =
        SecureStore.get(SpotifyRemote.keychainKey) ?? "" {
        didSet { SpotifyRemote.shared.setToken(spotifyWebToken) }
    }

    /// Can the transport buttons drive the picked service IN PLACE?
    /// Delegates to the controller's gate so the HUD, Siri, and CarPlay
    /// all read the SAME truth table (Apple Music always; Spotify on
    /// macOS, or on iOS with a user token; nothing else — no other
    /// service publishes a control API).
    var musicControllable: Bool { MusicController.shared.controlsInPlace }

    /// One spoken/typed music ask, routed by the picked provider — the
    /// in-app mic and Siri share this: Apple Music tries the FULL catalog
    /// (MusicKit) then the library; token-linked Spotify searches and
    /// starts the best playlist remotely; every no-API service opens at
    /// its own search. The spoken confirmation says which of those
    /// actually happened.
    /// What the driver last asked to hear ("rock") — the offline handoff
    /// matches radio to it, and it survives a provider switch.
    private(set) var lastMusicAsk: String?

    /// Radio AS the music service: a genre ask becomes a station QUEUE —
    /// the first station plays, next/previous walk the rest, exactly like
    /// a playlist. No subscription, no account. Returns the station now on
    /// (nil when nothing matched); `announce: false` leaves the speaking to
    /// the caller — Siri's reply, which would otherwise talk over FLOWS.
    @discardableResult
    func playGenreRadio(_ genre: String, spokenPrefix: String? = nil,
                        announce: Bool = true) async -> String? {
        // A named kind gets the filed search (tag hits re-checked against
        // BroadcastRadio's match order, nearest first); anything else the
        // driver says falls back to free text.
        if let kind = MusicController.genreKinds.first(where: {
            $0.title.caseInsensitiveCompare(genre) == .orderedSame
        }) {
            await radioBrowser.searchGenre(kind, near: effectivePosition)
        } else {
            await radioBrowser.search(text: genre)
        }
        let channels = radioBrowser.stations.map(\.channel)
        guard !channels.isEmpty else {
            if announce {
                VoiceAnnouncer.shared.announce(
                    "No \(genre) stations found right now.")
            }
            return nil
        }
        radio.playQueue(channels, label: genre)
        let name = radio.lastPlayed?.name ?? "a station"
        if announce {
            VoiceAnnouncer.shared.announce(
                (spokenPrefix.map { $0 + " " } ?? "") + "Playing \(genre) — \(name). "
                + "Say next for another \(genre) station.")
        }
        return name
    }

    /// Siri's "play something" with the radio as the service: the same
    /// station queue as the in-app ask, quiet, so Siri's reply is the one
    /// spoken line. Returns the station now on, nil when nothing matched.
    func playRadioMusicAsk(_ term: String) async -> String? {
        cancelOfflineHandoff()   // a driver's ask outranks a pending switch-back
        lastMusicAsk = term
        return await playGenreRadio(term, announce: false)
    }

    /// `announce`: say what is playing. A driver's own ask always does; the
    /// switch-back after a lost signal passes the voice setting — an
    /// unasked-for line.
    func playMusicAsk(_ term: String, announce: Bool = true) {
        // A driver-initiated ask outranks any pending switch-back. (The
        // restore clears that state before calling here, so its own call
        // is a no-op.)
        cancelOfflineHandoff()
        lastMusicAsk = term
        let say: (String) -> Void = { if announce { VoiceAnnouncer.shared.announce($0) } }
        // No streaming service: free public radio IS the music service.
        if musicProvider == .radio {
            Task { await playGenreRadio(term, announce: announce) }
            return
        }
        if musicProvider == .appleMusic {
            MusicController.shared.playSearchOrGenre(term)
            say("Playing \(term).")
            return
        }
        if musicProvider == .spotify, SpotifyRemote.shared.linked {
            Task { [weak self] in
                if await SpotifyRemote.shared.playSearch(term) {
                    say("Playing \(term) on Spotify.")
                } else if let self {
                    self.musicProvider.openSearch(query: term)
                    say("Opening Spotify's search for \(term).")
                }
            }
            return
        }
        musicProvider.openSearch(query: term)
        say("Opening \(musicProvider.displayName) — \(term).")
    }

    /// One spoken radio ask: "weather" tunes the nearest NOAA relay;
    /// anything else searches the AM/FM directory and plays the top hit.
    func playRadioAsk(_ term: String) {
        if VoiceCommands.wantsWeatherRadio(term) {
            let channel = effectivePosition
                .flatMap { radio.nearestChannel(to: $0)?.channel }
                ?? radio.nearestChannel(stateCode: currentStateCode)
            if let channel {
                radio.play(channel)
                VoiceAnnouncer.shared.announce("Playing \(channel.name).")
            }
            return
        }
        // Everything else becomes a station QUEUE (a callsign, a genre) so
        // next/previous walk the results like a playlist.
        Task { [weak self] in
            guard let self else { return }
            await self.radioBrowser.search(text: term)
            let channels = self.radioBrowser.stations.map(\.channel)
            if channels.isEmpty {
                VoiceAnnouncer.shared.announce("No station found for \(term).")
            } else {
                self.radio.playQueue(channels, label: term)
                VoiceAnnouncer.shared.announce(
                    "Playing \(self.radio.lastPlayed?.name ?? term).")
            }
        }
    }

    /// True while playback was moved by an offline handoff — the signal
    /// returning switches back only from this state.
    private var handedOffOffline = false
    /// The service the driver was on before the handoff, restored when
    /// the connection holds. The handoff also SWITCHES the provider to
    /// match what it started playing — otherwise the transport buttons
    /// would keep routing to a service that isn't making the sound.
    private var preHandoffProvider: MusicProvider?
    /// True while the handoff/restore path assigns musicProvider itself.
    private var settingProviderProgrammatically = false
    /// Pending switch-back, cancelled by another drop or a driver choice.
    private var restoreTask: Task<Void, Never>?

    /// A choice of the driver's outranks any pending restore — once they
    /// pick something themselves, FLOWS stops trying to switch back.
    func cancelOfflineHandoff() {
        guard handedOffOffline else { return }
        handedOffOffline = false
        preHandoffProvider = nil
        restoreTask?.cancel()
        restoreTask = nil
        MusicController.shared.cancelTrackBoundaryAction()
    }

    /// Signal held long enough: return to the service they were on,
    /// resuming what they last asked for.
    private func restoreAfterSignalReturn() {
        guard let previous = preHandoffProvider else { return }
        handedOffOffline = false
        preHandoffProvider = nil
        restoreTask = nil
        settingProviderProgrammatically = true
        musicProvider = previous
        settingProviderProgrammatically = false
        // A service FLOWS can drive resumes in place. A deep-linked one
        // must NOT be force-opened mid-drive — throwing the driver into
        // another app's UI at 70 mph is worse than a moment of quiet, so
        // say it's available and let them choose.
        FlowsDiag.log(.info, "audio",
                      "signal held — returning to \(previous.rawValue) "
                      + "(controllable=\(musicControllable))")
        // Unasked-for lines, so the voice switch decides: off = screen-only.
        guard musicControllable else {
            if voiceAlerts {
                VoiceAnnouncer.shared.announce(
                    "Signal's back — \(previous.displayName) is ready when you are.")
            }
            return
        }
        if voiceAlerts {
            VoiceAnnouncer.shared.announce(
                PlaybackFallback.restoreLine(service: previous.displayName))
        }
        if let ask = lastMusicAsk {
            playMusicAsk(ask, announce: voiceAlerts)   // unasked-for, like the line above
        } else {
            MusicController.shared.resumeRecent()
        }
    }

    /// Pending handoff while buffered audio is still playing.
    private var handoffGraceTask: Task<Void, Never>?
    /// Captured when the wait BEGINS: network-fed audio was playing. By
    /// the time the buffer drains the player may already read as stopped,
    /// and re-reading it then would cancel the very handoff it needs.
    private var bufferedAudioWasPlaying = false
    /// When the link dropped, and which service was playing — the two
    /// halves of a learning sample (loss → silence, per service).
    private var connectionLostAt: Date?
    private var graceService: String?
    private var graceRadioTechnology: String?
    /// Stations fetched while signal remained, so a handoff can start
    /// playing instantly instead of searching into the silence.
    private var preStagedStations: [TruckerRadio.Channel] = []
    private var preStagedLabel = ""
    private var preStageTask: Task<Void, Never>?
    private var lastBufferReading: Double?

    /// Learn from this outage: how long the audio really lasted after the
    /// link died, filed under the service that was playing.
    private func recordBufferSample() {
        guard let lostAt = connectionLostAt, let service = graceService else { return }
        let delay = Date().timeIntervalSince(lostAt)
        let tech = graceRadioTechnology
        BufferMemory.shared.record(seconds: delay, service: service,
                                   radioTechnology: tech)
        // The whole point of a trip log: this is the sample that teaches
        // FLOWS the real buffer depth, and the line that lets a human
        // check the learning afterwards.
        FlowsDiag.log(.info, "audio",
                      String(format: "buffer sample %.1fs service=%@ radio=%@ "
                             + "samples=%d usable=%@",
                             delay, service, tech ?? "unknown",
                             BufferMemory.shared.sampleCount(
                                service: service, radioTechnology: tech),
                             BufferLearning.isUsable(sample: delay) ? "yes" : "no"))
        connectionLostAt = nil
    }

    /// Signal is failing but hasn't died: fetch the fallback's stations
    /// NOW, while there's still a link to fetch them with. This is what
    /// makes the eventual switch instant rather than a search into silence.
    private func preStageFallback() {
        // preStageTask == nil FIRST: this runs on every GPS fix, and the
        // search takes seconds on the weak link that triggers it. Without
        // the guard, fixes 2..N each spawned another directory query before
        // the first landed — a pile of concurrent fetches through a 2-3
        // permit gate, starving everything else that needed the network.
        //
        // A nil-check, deliberately, not the cancel-and-restart used for
        // camera lookups: under a 1 Hz retrigger a restart would cancel the
        // search before it ever finished, and the fallback would never be
        // staged at all.
        guard preStageTask == nil,
              preStagedStations.isEmpty,
              !MusicController.shared.hasLocalMusic,
              let genre = lastMusicAsk
                ?? (radio.queueLabel.isEmpty ? nil : radio.queueLabel) else { return }
        preStagedLabel = genre
        preStageTask = Task { [weak self] in
            guard let self else { return }
            await self.radioBrowser.search(text: genre)
            self.preStagedStations = self.radioBrowser.stations.map(\.channel)
            self.preStageTask = nil   // the next fix may try again
        }
    }

    /// The path dropped — but the music didn't. Every player is holding
    /// buffered audio, so wait it out instead of cutting off sound that
    /// was going to play fine (a short tunnel then becomes a non-event).
    /// Whichever comes first ends the wait: the audio actually stopping,
    /// or the buffer running out.
    private func beginHandoffGrace() {
        guard handoffGraceTask == nil, !handedOffOffline else { return }
        let music = MusicController.shared
        let radioPlaying = radio.playingChannelID != nil
        // Any OTHER app making sound (a deep-linked service playing in
        // its own app) counts as music that's about to be in trouble.
        let otherAppAudio = !radioPlaying && AudioActivity.isOtherAudioPlaying
        guard radioPlaying || music.isPlaying || otherAppAudio,
              radioPlaying || otherAppAudio
                || music.currentPlaybackNeedsNetwork else { return }
        bufferedAudioWasPlaying = true
        let source: PlaybackGrace.Source
        if radioPlaying {
            source = .radio
        } else if music.isPlaying, musicProvider == .appleMusic {
            source = .appleMusicCloud
        } else if musicProvider == .spotify {
            source = .spotify
        } else {
            source = .otherApp
        }
        // Radio is OUR player, so its remaining audio is measured; for
        // everything else this starts as a documented prior — and gets
        // REPLACED by what this driver's phone has actually shown for
        // this service once enough outages have been observed.
        let prior = PlaybackGrace.graceSeconds(
            for: source,
            measuredBuffer: radioPlaying ? radio.bufferedSecondsAhead : nil)
        graceService = musicProvider.rawValue
        graceRadioTechnology = CellularRadio.currentTechnology
        // The radio's own measurement is ground truth; never override it.
        let grace = radioPlaying
            ? prior
            : BufferMemory.shared.waitSeconds(prior: prior,
                                              service: musicProvider.rawValue,
                                              radioTechnology: graceRadioTechnology)
        FlowsDiag.log(.warn, "audio",
                      String(format: "signal lost while playing — source=%@ "
                             + "wait=%.1fs (prior %.1fs%@) radio=%@",
                             "\(source)", grace, prior,
                             grace == prior ? "" : ", LEARNED",
                             graceRadioTechnology ?? "unknown"))
        radio.onStall = { [weak self] in self?.applyOfflineHandoff() }
        music.onPlaybackStopped = { [weak self] in self?.applyOfflineHandoff() }
        handoffGraceTask = Task { [weak self] in
            if radioPlaying {
                // Our own measured buffer is authoritative.
                try? await Task.sleep(for: .seconds(grace))
                guard !Task.isCancelled else { return }
            } else {
                // Every other player: no published buffer figure exists,
                // so watch the AUDIO ITSELF and act when it goes quiet.
                var waited = 0.0
                var wentQuiet = false
                while waited < grace {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    waited += 1
                    if !AudioActivity.isOtherAudioPlaying {
                        wentQuiet = true
                        break
                    }
                }
                // Still making sound at the ceiling? Its buffer runs
                // deeper than expected — leave it alone rather than talk
                // over music that's playing perfectly well.
                guard wentQuiet else {
                    self?.endHandoffGrace()
                    return
                }
            }
            self?.applyOfflineHandoff()
        }
    }

    /// Stop waiting — either the buffer carried the music through the
    /// outage, or the handoff already happened.
    private func endHandoffGrace() {
        handoffGraceTask?.cancel()
        handoffGraceTask = nil
        radio.onStall = nil
        MusicController.shared.onPlaybackStopped = nil
    }

    /// The buffer is spent and the link is still down: move playback to
    /// whatever survives.
    private func applyOfflineHandoff() {
        guard breadcrumbs.isOffline, !handedOffOffline else {
            endHandoffGrace()
            return
        }
        endHandoffGrace()
        recordBufferSample()   // the audio just died: that delay is the lesson
        handleOfflineNow()
    }

    /// The network path changed. On loss, hand playback to whatever still
    /// works; on a return that HOLDS, switch back at a song boundary.
    private func handleConnectivity(offline: Bool) {
        guard offline else {
            // Signal back: whatever was buffered carried the music
            // through, so a pending handoff is simply cancelled — the
            // driver never hears a thing.
            endHandoffGrace()
            guard handedOffOffline else { return }
            // Wait out the hold window before trusting the connection: a
            // flapping link would otherwise ping-pong the driver. Each new
            // drop cancels this, so only a steady signal switches back.
            restoreTask?.cancel()
            restoreTask = Task { [weak self] in
                try? await Task.sleep(
                    for: .seconds(PlaybackFallback.restoreHoldSeconds))
                guard !Task.isCancelled, let self else { return }
                guard PlaybackFallback.shouldRestore(
                    handedOff: self.handedOffOffline,
                    connectionHeld: !self.breadcrumbs.isOffline,
                    driverChoseSince: self.preHandoffProvider == nil) else { return }
                // Land the switch BETWEEN songs when local music is
                // playing — cutting one off mid-chorus isn't seamless.
                MusicController.shared.atNextTrackBoundary { [weak self] in
                    self?.restoreAfterSignalReturn()
                }
            }
            return
        }
        // Signal dropped (again): any pending switch-back is void, and
        // the buffer wait begins — nothing changes until it's spent.
        restoreTask?.cancel()
        restoreTask = nil
        MusicController.shared.cancelTrackBoundaryAction()   // the armed switch-back is void
        connectionLostAt = Date()
        beginHandoffGrace()
    }

    /// Called on each corridor tick while music plays: watch the link's
    /// health and stage the fallback BEFORE the audio dies.
    func checkPlaybackSignalHealth() {
        guard !breadcrumbs.isOffline, handoffGraceTask == nil,
              MusicController.shared.isPlaying || radio.playingChannelID != nil
        else { return }
        let buffer = radio.bufferedSecondsAhead
        let draining = SignalQuality.isDraining(previous: lastBufferReading,
                                                current: buffer)
        lastBufferReading = buffer
        let tier = SignalQuality.tier(
            radioTechnology: CellularRadio.currentTechnology,
            onWiFi: false, offline: false)
        if SignalQuality.shouldPreStage(tier: tier, bufferDraining: draining,
                                        recentStalls: 0) {
            let hadStaged = !preStagedStations.isEmpty
            preStageFallback()
            if !hadStaged {
                FlowsDiag.logThrottled(
                    key: "audio.prestage", interval: 120, .info, "audio",
                    "pre-staging fallback: tier=\(tier.rawValue) "
                    + "draining=\(draining) radio=\(CellularRadio.currentTechnology ?? "n/a")")
            }
        }
    }

    /// The handoff itself, run only once the buffered audio is gone.
    private func handleOfflineNow() {
        let music = MusicController.shared
        let genre = lastMusicAsk
            ?? (radio.queueLabel.isEmpty ? nil : radio.queueLabel)
        // Both facts were established when the wait began (a station is a
        // stream too, so radio always counts as network-fed) — the player
        // may have gone quiet since, which is exactly why we're here.
        let source = PlaybackFallback.onConnectionLost(
            isPlaying: bufferedAudioWasPlaying,
            needsNetwork: bufferedAudioWasPlaying,
            hasLocalMusic: music.hasLocalMusic,
            lastGenre: genre)
        FlowsDiag.log(.warn, "audio",
                      "offline handoff: \(source.logName) (was \(musicProvider.rawValue), "
                      + "localMusic=\(music.hasLocalMusic), "
                      + "preStaged=\(preStagedStations.count) stations)")
        // Nobody asked for this line: the voice switch decides.
        if voiceAlerts, let line = PlaybackFallback.spokenLine(for: source) {
            VoiceAnnouncer.shared.announce(line)
        }
        switch source {
        case .localLibrary:
            handedOffOffline = true
            preHandoffProvider = musicProvider
            radio.stop()                      // a stalling stream helps nobody
            // The provider must MATCH what's now making the sound, or the
            // transport buttons would keep routing to the service that
            // just went dark.
            settingProviderProgrammatically = true
            musicProvider = .appleMusic
            settingProviderProgrammatically = false
            music.playLocalLibrary()
        case .radio(let genre):
            handedOffOffline = true
            preHandoffProvider = musicProvider
            settingProviderProgrammatically = true
            musicProvider = .radio
            settingProviderProgrammatically = false
            // Pre-staged while signal remained: play instantly instead of
            // searching into the silence (the search would fail anyway —
            // the directory needs the very link that just died).
            if !preStagedStations.isEmpty {
                radio.playQueue(preStagedStations,
                                label: preStagedLabel.isEmpty ? genre : preStagedLabel)
                preStagedStations = []
            } else {
                // Unasked-for: the voice setting decides whether it's said.
                let say = voiceAlerts
                Task { await playGenreRadio(genre, announce: say) }
            }
        case .nothingAvailable, .keepPlaying:
            break
        }
    }

    /// Press play with radio as the service and no history: the stations
    /// around here, as a queue.
    /// Forward/back on the mini player when the radio is the service.
    ///
    /// The transport walks a QUEUE, and the queue is empty until something
    /// loads one — so before any station had been picked, the arrows had
    /// nothing to step through and appeared dead. Pressing one now starts
    /// the local dial and plays, which is what the driver meant by it.
    func radioStep(forward: Bool) {
        guard radio.queue.isEmpty else {
            _ = forward ? radio.nextStation() : radio.previousStation()
            return
        }
        playLocalStationsRadio()
    }

    func playLocalStationsRadio() {
        let code = currentStateCode
        Task { [weak self] in
            guard let self else { return }
            await self.radioBrowser.searchNearby(
                near: self.effectivePosition, stateCode: code)
            let channels = self.radioBrowser.stations.map(\.channel)
            guard !channels.isEmpty else {
                VoiceAnnouncer.shared.announce("No stations found nearby yet.")
                return
            }
            self.radio.playQueue(channels, label: "stations near you")
            VoiceAnnouncer.shared.announce(
                "Playing \(self.radio.lastPlayed?.name ?? "a nearby station").")
        }
    }

    /// Play pressed: gate on the one-time provider ask, then play through
    /// the chosen service (Apple Music in-app; other services open their app).
    func playMusic() {
        // The radio needs no ask. It is FLOWS's own player — no account, no
        // subscription, no other app — so pressing play on it plays, and
        // pressing pause on a station that is audibly on the air pauses it.
        //
        // Asking here is what made this button look broken: the provider
        // question fires while nothing has been explicitly PICKED, and the
        // radio is a default rather than a pick. So a driver whose station
        // was already playing (the arrows start one) pressed pause and got
        // a "what do you play music with?" card instead — every time.
        if musicProvider == .radio {
            if radio.playingChannelID == nil, radio.lastPlayed == nil {
                playLocalStationsRadio()   // nothing tuned yet
            } else {
                MusicController.shared.playPause()
            }
            return
        }
        // Every other service opens an app or needs an account, so the
        // one-time ask still earns its place there.
        guard musicProviderChosen else {
            showMusicProviderPrompt = true
            return
        }
        if musicControllable {
            MusicController.shared.playPause()
        } else {
            musicProvider.openApp()
        }
    }

    /// Set when something (the play button, the provider picker) wants the
    /// EMERGENCY radio card open; the HUD consumes and clears it.
    @Published var showRadioCardRequested = false

    /// First-play choice: remember it, then do what play was about to do.
    func chooseMusicProvider(_ provider: MusicProvider) {
        cancelOfflineHandoff()   // their pick outranks a pending switch-back
        musicProvider = provider
        showMusicProviderPrompt = false
        if musicControllable {
            MusicController.shared.playPause()
        } else {
            provider.openApp()
        }
    }

    /// Menus tied to the CURRENT trip: these come back when the screen
    /// changes under them. Instruments the driver chose to tuck away (the
    /// gauge cluster, the map key) are deliberately NOT here — a preference
    /// set once should survive the next plan, and the next launch.
    private static let transientPanels = ["planner", "routes", "sliders", "stops"]

    /// The minimized-panel pile. Same call surface as the Set it replaced
    /// (contains / insert / remove / subtract) so no caller changed; the
    /// difference is that ORDER is kept, newest-closed last.
    struct PanelStack: Equatable {
        private(set) var order: [String] = []
        init(_ ids: [String] = []) { ids.forEach { _ = insert($0) } }
        var isEmpty: Bool { order.isEmpty }
        func contains(_ id: String) -> Bool { order.contains(id) }
        /// Close a panel: its icon goes to the bottom of the pile.
        @discardableResult
        mutating func insert(_ id: String) -> (inserted: Bool, memberAfterInsert: String) {
            if order.contains(id) { return (false, id) }
            order.append(id)
            return (true, id)
        }
        /// Open a panel: its icon leaves the pile.
        @discardableResult
        mutating func remove(_ id: String) -> String? {
            guard let i = order.firstIndex(of: id) else { return nil }
            return order.remove(at: i)
        }
        mutating func subtract<S: Sequence>(_ ids: S) where S.Element == String {
            let gone = Set(ids)
            order.removeAll { gone.contains($0) }
        }
    }

    private func restoreTransientPanels() {
        collapsedPanels.subtract(Self.transientPanels)
    }

    /// Close every floating panel or menu a map click can sit under —
    /// settings, the category pickers, the slider card, the towing card, and
    /// the music ask. POI RESULTS are deliberately left alone: the Tourist
    /// filter's stars, per-route attraction counts, and scenic ordering all
    /// read poi.results, and clearing them on a stray map tap erased the
    /// stars until the filter was toggled. Closing the stop list stays an
    /// explicit act (its X button). Route cards and map pins handle their
    /// own taps first, so those still work.
    func dismissFloatingPanels() {
        showSettings = false
        showTowingCard = false
        showMusicProviderPrompt = false
        poi.pendingFoodChoice = false
        poi.pendingFuelChoice = false
        poi.pendingStoreChoice = false
        filterCardsHidden = true
    }

    /// TRUCKER MODE (top-left toggle, persisted): trucker-specific UI —
    /// showers / legal truck parking / truck-friendly motels / diesel-by-cost
    /// buttons and the radio card. (The Trucker route is designated for
    /// everyone — `truckerRouteID` — so it is not part of this mode.)
    @Published var truckerUI: Bool =
        UserDefaults.standard.bool(forKey: "flows.truckerUI") {
        didSet {
            UserDefaults.standard.set(truckerUI, forKey: "flows.truckerUI")
            poi.truckerMode = truckerUI
        }
    }

    // MARK: navigation camera (auto vs. hand-set zoom)

    /// How the driving camera picks its height. `auto` follows the distance
    /// between intersections (CameraZoom); the others let a driver pin the
    /// view themselves — including previewing the walking and flight rules
    /// on the ground, which is otherwise only reachable by walking a route
    /// or boarding a plane.
    enum CameraZoomMode: String, CaseIterable, Identifiable, Codable {
        case auto = "Automatic"
        case manual = "Set by hand"
        case walking = "Always close (walking)"
        case flight = "Always far (flying)"
        var id: String { rawValue }
    }

    @Published var cameraZoomMode: CameraZoomMode = CameraZoomMode(
        rawValue: UserDefaults.standard.string(forKey: "flows.cameraZoomMode") ?? ""
    ) ?? .auto {
        didSet { UserDefaults.standard.set(cameraZoomMode.rawValue,
                                           forKey: "flows.cameraZoomMode") }
    }
    /// Hand-set camera height in meters (the Set-by-hand slider).
    @Published var manualZoomMeters: Double =
        UserDefaults.standard.object(forKey: "flows.manualZoomMeters") as? Double ?? 900 {
        didSet { UserDefaults.standard.set(manualZoomMeters,
                                           forKey: "flows.manualZoomMeters") }
    }

    /// The height the camera should actually use, given what the engine
    /// computed for this moment. Auto passes it through; the rest override.
    func cameraAltitude(auto: Double) -> Double {
        switch cameraZoomMode {
        case .auto: return auto
        case .manual: return manualZoomMeters
        case .walking: return CameraZoom.walkingAltitude
        case .flight: return CameraZoom.cruiseAltitude
        }
    }

    /// 3D terrain: MapKit's realistic elevation rendering (its own DEM tiles;
    /// our EPQS/gradient data stays a risk input) + a deeper nav-camera pitch.
    @Published var show3DMap: Bool =
        UserDefaults.standard.bool(forKey: "flows.show3DMap") {
        didSet { UserDefaults.standard.set(show3DMap, forKey: "flows.show3DMap") }
    }

    /// The DEDICATED trucker route: ALWAYS designated — the option that
    /// best accommodates a truck (highways, clearances above 13'6",
    /// gentle grades, low wind exposure), ETA breaking ties.
    var truckerRouteID: UUID? {
        let semi = FilterLimits(vehicleHeightMeters: 13.5 * 0.3048,
                                maxGradePercent: FilterLimits.degreesToPercent(6))
        // A KNOWN low bridge DISQUALIFIES a route from the trucker badge — it
        // is not a 3-point penalty to be outweighed by highways and gentle
        // grades. Review finding: a route failing a 13'6" clearance check
        // scored 6 (highways + grade + wind) and could tie or beat a
        // clearance-PASSING route, i.e. the badge could point a semi at a
        // bridge it cannot clear. Unknown clearance data still passes (the
        // app-wide "unknown never excludes" rule), so on corridors without
        // OSM height tags — the common case — every candidate remains
        // eligible and the badge behaves as before.
        // The rule itself is TruckerDesignation (Core, tested); this only
        // reads each route's facts into a candidate.
        func candidate(_ r: PlannedRoute) -> TruckerDesignation.Candidate {
            TruckerDesignation.Candidate(
                id: r.id,
                clearsBridges: semi.passesClearances(r.clearancesMeters),
                hasHighways: r.hasHighways,
                avoidsHighways: r.planKind == .avoidHighways,
                gradeOK: semi.passesGrade(r.maxGradePercent),
                windOK: (r.familyPeaks["wind"] ?? 0) < FlowsCore.riskYellowMin,
                eta: r.eta)
        }
        // Designate from the FILTERED list so the badge follows the routes
        // the driver can actually see (it used to vanish when a filter
        // removed the previously-designated route). filteredChoices is bound
        // once (the `.isEmpty ? … : …` form evaluated the whole filter pass
        // twice), and no sort: designation only needs the single best
        // (score, eta) — score() scans the route's full clearance list, so
        // the comparator re-running it 4× per comparison was the cost.
        let filtered = filteredChoices
        let pool = filtered.isEmpty ? routeChoices : filtered
        // Disqualify known-impassable routes BEFORE scoring. If every
        // candidate has a known low bridge, no route earns the badge —
        // silence is honest; badging an impassable route is not.
        let candidates = pool.map(candidate)
        let picked = TruckerDesignation.pick(candidates)
        if picked == nil, !pool.isEmpty {
            FlowsDiag.logThrottled(
                key: "trucker.noClearance", .warn, "routing",
                "no candidate clears 13'6\" — trucker badge withheld")
        }
        return picked
    }

    /// Planner fields live on the model so editing a trip round-trips
    /// (choosing → Edit → planning) without losing what was typed.
    @Published var plannerSource = ""
    @Published var plannerDestination = ""
    /// The rows each field was filled from, when they carry their own place
    /// (PlannerPick) — kept here with the text so Edit round-trips them too.
    var plannerSourcePick: PlannerPick?
    var plannerDestinationPick: PlannerPick?

    /// Set when the final destination is reached; HUD shows the arrived
    /// banner until the driver dismisses it.
    @Published var arrivedAt: String?

    /// The continuation leg after an added stop (stop → final destination),
    /// planned up front so the map shows the FULL appended route — the leg
    /// being driven in risk colors, the continuation dashed behind it.
    @Published private(set) var upcomingLeg: PlannedRoute?

    /// Settings sheet (fuel type, …) — the gear.
    @Published var showSettings = false

    /// Corridor bounds of the selected route — the camera's overview target
    /// when navigation ends.
    private(set) var lastRouteRect: MKMapRect?

    /// Live traffic: minutes of delay vs the guidance baseline, refreshed
    /// every ~5 min from MKDirections ETA (real-time traffic). HUD shows a
    /// chip with a faster-route option when it grows meaningful.
    @Published var trafficDelayMinutes: Int? {
        didSet {
            // The chip went away (taken, jam cleared, new leg, trip over):
            // its spoken offer goes with it.
            if oldValue != nil, trafficDelayMinutes == nil {
                VoiceAnnouncer.shared.cancel(topic: SpeechTopic.trafficOffer)
            }
        }
    }
    private var trafficWatchTask: Task<Void, Never>?
    /// Minutes a faster route FLOWS took on its own saves: the HUD's "Took a
    /// faster route" chip, shown for a few seconds.
    @Published var fasterRouteSavedMinutes: Int?
    /// The traffic offer on screen is for a road with more risk (the driver
    /// is asked instead of FLOWS switching on its own).
    @Published var trafficOfferRiskier = false
    /// FLOWS looked and there is nothing to take: the only faster road runs
    /// through red, none saves enough or keeps the driver's road choices, or
    /// the car is past the turn-off. The chip shows the delay with no button,
    /// and each traffic check looks again.
    @Published var trafficOfferBlocked = false
    /// The faster road FLOWS weighed and offered, for a yes to take: to the
    /// end of this leg, with the driver's road choices, its line and where it
    /// leaves the current road (a yes checks the car can still reach it), the
    /// spacing its detour was checked at and the risk it was offered at (a
    /// yes scores it again and compares).
    private struct StagedFasterRoute {
        let legID: UUID
        let route: PlannedRoute
        let line: [CLLocationCoordinate2D]
        let divergeAlong: CLLocationDistance?
        let checkSpacing: CLLocationDistance
        let offeredRisk: Double
        let stagedAt: Date
    }
    private var stagedFasterRoute: StagedFasterRoute?
    /// How long a weighed road stays good for a yes, and before the next
    /// check weighs the jam again. Older, its saving is stale (traffic is
    /// checked every 4 minutes at rush hour, every 12 otherwise), and a yes
    /// plans afresh.
    private static let stagedFasterRouteMaxAge: TimeInterval = 600
    /// The offer on screen has nothing weighed behind it (a safety prompt was
    /// up, the plan failed, or the road's score didn't finish): each check
    /// weighs the jam again, so FLOWS can still take a faster road on its own.
    private var trafficOfferNeedsWeigh = false
    /// The driver said no to the offer: the jam isn't weighed again, and
    /// nothing is switched on their behalf until it clears.
    private var trafficOfferDeclined = false
    /// A reroute the driver asked for (Reroute on a rising-risk prompt, a yes
    /// to the traffic offer) is being planned: FLOWS doesn't swap legs under
    /// it. A count, so overlapping requests don't clear it early.
    private var driverReroutesInFlight = 0
    /// Reroute on a rising-risk prompt is being planned: the old road's
    /// watch raises no prompt meanwhile. One raised there was spoken over
    /// the reroute and outlived the swap, sitting over the new road. Its
    /// own count: a traffic yes must never mute a safety prompt.
    private var escalationReroutesInFlight = 0

    /// The traffic offer is over: its risk label, its block, its staged road,
    /// the pending spoken yes, and the driver's no.
    private func clearTrafficOffer() {
        trafficOfferRiskier = false
        trafficOfferBlocked = false
        trafficOfferNeedsWeigh = false
        trafficOfferDeclined = false
        stagedFasterRoute = nil
        if case .fasterRoute? = pendingVoiceOffer { pendingVoiceOffer = nil }
    }

    /// The live-monitoring window: how far AHEAD to watch scales with speed
    /// (≈30 min of travel — walking watches ~5 km, highway driving watches
    /// up to 150 km), and the refresh cadence tightens as speed rises.
    /// Everything outside this route-buffer window is deliberately NOT
    /// processed while navigating.
    private func watchWindow() -> (along: Double, lookahead: Double, cadence: Double) {
        let along = navigation.guidance?.alongMeters ?? 0
        let speed = location.speed
        let lookahead = min(max(speed * 1800, 5_000), 150_000)
        let cadence: Double = speed > 20 ? 120 : (speed > 3 ? 180 : 300)
        return (along, lookahead, cadence)
    }

    /// Escalating-risk prompt during navigation, awaiting driver approval.
    struct Escalation: Equatable {
        let newRisk: Double
        let headline: String
        /// Which hazard raised this, so dismissing it silences THAT hazard
        /// rather than every hazard of the same severity.
        var alertID: String? = nil
    }
    @Published var escalation: Escalation? {
        didSet {
            // Continue, Reroute, a new trip or End: the prompt's spoken line
            // goes with it.
            if oldValue != nil, escalation == nil {
                VoiceAnnouncer.shared.cancel(topic: SpeechTopic.escalation)
            }
        }
    }
    /// Baseline, dismissed risk and dismissed hazard identities — the whole
    /// decision lives in EscalationPolicy (Core, tested); this is its state.
    private var escalationState = EscalationPolicy.State.fresh(baseline: nil)
    /// Worst realized corridor risk encountered on the ACTIVE trip — recorded
    /// as the "observed" against the plan-time prediction on arrival, so the
    /// on-device seasonal model learns predicted-vs-actual over time.
    private var tripObservedPeak: Double = 0

    // MARK: imminent hazard (10 minutes ahead at current speed)

    /// Weather the driver is about to ENCOUNTER: official summary, link to
    /// the issuing source, and the reaction FLOWS already took (shelter list
    /// opened / rest-area wait recommended).
    struct ImminentWarning: Equatable {
        let alertID: String
        let event: String
        let headline: String
        let detail: String?
        let sourceURL: URL?
        let action: ImminentAlerts.Action
        let etaSeconds: Double
        /// `ImminentAlerts.threatRank` at creation, so a graver warning is
        /// never displaced by a lesser one while both are live.
        var threatRank: Int = 1
        /// Parsed from the official description: "red Toyota truck" → a red
        /// truck silhouette + TOYOTA badge; person descriptions → colored
        /// adult/child silhouette (AMBER/Blue/Silver alert cards).
        var vehicleEntity: AlertEntityParser.VehicleEntity? = nil
        var personEntity: AlertEntityParser.PersonEntity? = nil
        /// Where the incident is (alert geometry centroid / nearest risky
        /// sample) — anchors the map symbol + reach circle.
        var incidentCoordinate: CLLocationCoordinate2D? = nil
        /// When it began — the reach circle's clock.
        var onset: Date? = nil
        /// Plausible escape speed from roads near the incident (OSM
        /// maxspeed; blended default until the probe returns).
        var reachSpeedMph: Double = PursuitReach.defaultSpeedMph
        /// When the official alert stops being in force. The shelter timer
        /// runs to this, because "how long do I wait" is exactly "how long
        /// is this dangerous".
        var expires: Date? = nil
        /// 0…1 severity — decides whether an ordinary open building is
        /// enough shelter or the hazard needs a solid one.
        var severityScore: Double = 0.5

        // CLLocationCoordinate2D isn't Equatable — compare by value.
        static func == (lhs: ImminentWarning, rhs: ImminentWarning) -> Bool {
            lhs.alertID == rhs.alertID && lhs.action == rhs.action
                && lhs.headline == rhs.headline
                && lhs.event == rhs.event
                && lhs.detail == rhs.detail
                && lhs.sourceURL == rhs.sourceURL
                && lhs.expires == rhs.expires
                && lhs.onset == rhs.onset
                && lhs.etaSeconds == rhs.etaSeconds
                && lhs.reachSpeedMph == rhs.reachSpeedMph
                && lhs.incidentCoordinate?.latitude == rhs.incidentCoordinate?.latitude
                && lhs.incidentCoordinate?.longitude == rhs.incidentCoordinate?.longitude
        }
    }
    @Published var imminentWarning: ImminentWarning? {
        didSet {
            // Announce each NEW warning once (never re-announce the same
            // alert as its distance/reach fields refresh) — the hands-free
            // half of the imminent banner, AMBER alerts included. The
            // haptic fires regardless of the voice toggle: it's the
            // hearing-parity channel, not a companion to the voice.
            // The warning closed or gave way to another (the X, Shelter, it
            // cleared, a graver one, a new trip, End): stop reading it out.
            // Dismissing used to leave the whole message being read.
            if let old = oldValue, old.alertID != imminentWarning?.alertID {
                VoiceAnnouncer.shared.cancel(topic: SpeechTopic.imminent(old.alertID))
            }
            guard let warning = imminentWarning,
                  warning.alertID != oldValue?.alertID else { return }
            if hapticAlerts { Haptics.warning() }
            let spoken = SiriSummaries.emergencyAnnouncement(
                event: warning.event, headline: warning.headline,
                action: warning.action)
            Self.noticeIfAway(id: "imminent." + warning.alertID,
                              title: warning.event, body: spoken)
            guard voiceAlerts else { return }
            VoiceAnnouncer.shared.announce(spoken, topic: SpeechTopic.imminent(warning.alertID))
        }
    }

    // MARK: lock-screen notices

    /// A warning raised while FLOWS is not on screen (the phone locked in
    /// its mount, another app in front) also goes to the lock screen. The
    /// banner cannot be seen then, the haptic cannot fire from the
    /// background, and with voice off the driver got nothing at all. The
    /// Settings → Notifications switches decide which warnings exist in the
    /// first place; this only carries them where the driver can see them.
    /// Nothing is posted while FLOWS is in front: the banner is there.
    private static func noticeIfAway(id: String, title: String, body: String) {
        #if os(macOS)
        guard !NSApplication.shared.isActive else { return }
        #else
        guard UIApplication.shared.applicationState != .active else { return }
        #endif
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "flows.warnings"
        // One notice per warning: the same id replaces, never piles up.
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "flows." + id, content: content, trigger: nil))
    }

    /// A finished trip's warnings describe a road no longer driven: they
    /// leave the lock screen with it.
    private static func clearNotices() {
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications()
                .map(\.request.identifier).filter { $0.hasPrefix("flows.") }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// Asked once, the first time a trip starts with a warning switch on —
    /// not at launch, when the question has no context. Then, one dialog at
    /// a time, the crash check-in's speech and microphone while crash
    /// detection is on: asked only after an impact, the system's dialogs
    /// covered "Do you need assistance?".
    private func askForTripPermissionsIfNeeded() {
        let notices = notifyImminent || notifyEscalation
        let crashReply = crashDetectionEnabled && CrashDetectionService.isAvailable
        guard notices || crashReply else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            if notices,
               await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            if crashReply { await CrashDetectionService.askReplyPermissionsIfNeeded() }
        }
    }

    /// What FLOWS last offered OUT LOUD and is waiting on a spoken yes
    /// for — "go ahead in FLOWS" (GoAheadIntent) consumes it.
    enum VoiceOffer {
        case trip(route: PlannedRoute, name: String)   // voice trip-start staged
        case fasterRoute                                // traffic reroute offer
    }
    var pendingVoiceOffer: VoiceOffer?
    /// Warnings the driver dismissed — never re-raised for the same alert.
    private var dismissedImminentIDs = Set<String>()
    /// Cached OSM escape speeds per alert (one Overpass probe each).
    private var reachSpeeds: [String: Double] = [:]
    /// Alerts that already auto-opened the shelter list (once per alert).
    private var shelteredImminentIDs = Set<String>()

    /// Unplanned stopped time (e.g. sheltering from a storm) — folded into
    /// every displayed ETA. The scenario's "+1 hour sheltering" adjustment.
    @Published var stopDelaySeconds: Double = 0
    /// Shelter time that has already ELAPSED. The ETA must not carry it
    /// (that wait is behind the driver now), the trip-duration learner
    /// must (it was real stopped time, not driving). Keeping it apart from
    /// stopDelaySeconds is what lets one number serve the screen and the
    /// other the model. Cleared with the trip.
    private var shelteredSecondsBanked: Double = 0
    func addStopDelay(seconds: Double = 3600) { stopDelaySeconds += seconds }

    // MARK: the week-away blind spot

    private static let lastUseKey = "flows.lastUsed"

    /// Called at launch: ask once if the app has been away a week or more,
    /// then stamp the visit.
    func checkStaleFuelGauge(now: Date = Date()) {
        let last = UserDefaults.standard.object(forKey: Self.lastUseKey) as? Date
        UserDefaults.standard.set(now, forKey: Self.lastUseKey)
        guard vehicle.profile != nil,
              vehicle.telemetry().fuelFraction == nil,
              refuelCheckInsEnabled, notifyFuel,
              StaleGauge.wentStale(lastUsed: last, now: now) else { return }
        refuelPrompt = true
    }

    /// Scanner pins worth drawing: still live, and near the driver or the
    /// route corridor. Everything else has either expired or is somebody
    /// else's town.
    var visibleScannerIncidents: [ScannerIncidents.Incident] {
        // Read on every ContentView render; with no incidents (the common
        // case — the scanner ships off) there is nothing to sample the
        // route polyline for.
        if scanner.incidents.isEmpty { return [] }
        return ScannerIncidents.visible(scanner.incidents,
                                 near: effectivePosition,
                                 corridor: navigation.route.map {
                                     RouteService.samplePoints(of: $0.route.polyline,
                                                               everyMeters: 15_000)
                                 } ?? [])
    }

    // MARK: how the vehicle is drawn on the map

    /// Body shape for the map marker. Defaults to the driver's own vehicle —
    /// an 18 wheeler shouldn't be drawn as a hatchback — and is overridable
    /// in Settings.
    @Published var vehicleShapeOverride: VehicleShape? = UserDefaults.standard
        .string(forKey: "flows.vehicleShape").flatMap(VehicleShape.init(rawValue:)) {
        didSet {
            UserDefaults.standard.set(vehicleShapeOverride?.rawValue,
                                      forKey: "flows.vehicleShape")
        }
    }

    /// Marker colour, as an SF-friendly name so the choice survives as a
    /// word rather than a packed number.
    @Published var vehicleColorName: String = UserDefaults.standard
        .string(forKey: "flows.vehicleColor") ?? "blue" {
        didSet { UserDefaults.standard.set(vehicleColorName, forKey: "flows.vehicleColor") }
    }

    static let vehicleColorChoices = ["blue", "red", "green", "orange",
                                      "purple", "yellow", "gray", "black"]

    /// The shape actually drawn: the override when set, otherwise whatever
    /// matches the vehicle on file.
    var vehicleShape: VehicleShape {
        vehicleShapeOverride
            ?? VehicleShape.matching(make: vehicle.profile?.make,
                                     model: vehicle.profile?.model,
                                     gvwrLbs: vehicle.profile?.gvwrLbs,
                                     isTrucker: truckerUI)
    }

    // MARK: sheltering in place

    /// An active "wait here until this passes" session.
    struct ShelterSession: Equatable {
        let event: String
        let until: Date
        let sourceURL: URL?
        let kind: ShelterPolicy.Kind
        /// What was added to the ETA when it started, so ending early can
        /// take exactly that back out.
        let addedSeconds: Double

        var remaining: TimeInterval { max(0, until.timeIntervalSinceNow) }
        var isOver: Bool { remaining <= 0 }
    }

    /// Set while the driver has chosen to sit out a hazard. The directions
    /// window shows its countdown.
    @Published private(set) var shelterSession: ShelterSession?

    /// Start sheltering, and CLOSE the warning.
    ///
    /// The old button added an hour to the ETA every time it was pressed and
    /// left the card up, so acknowledging the alert made the trip longer and
    /// the banner stayed. Pressing it now means "I've read this and I'm
    /// stopping": the card goes away, the wait is the alert's own remaining
    /// life rather than a flat hour, and the ETA is adjusted exactly once.
    func beginShelter(for warning: ImminentWarning) {
        let wait = ShelterPolicy.waitSeconds(expires: warning.expires)
        // Replace any previous session rather than stacking onto it.
        if let old = shelterSession {
            stopDelaySeconds -= old.addedSeconds
            shelteredSecondsBanked += old.addedSeconds - old.remaining   // the part already sat out
        }
        stopDelaySeconds += wait
        shelterSession = ShelterSession(
            event: warning.event,
            until: Date().addingTimeInterval(wait),
            sourceURL: warning.sourceURL,
            kind: ShelterPolicy.kind(forEvent: warning.event,
                                     severityScore: warning.severityScore),
            addedSeconds: wait)
        dismissImminentWarning()
    }

    /// Driver chose to move on before the timer ran out — give back the time
    /// that was added for waiting.
    func endShelter() {
        guard let session = shelterSession else { return }
        stopDelaySeconds = max(0, stopDelaySeconds - session.addedSeconds)
        shelteredSecondsBanked += session.addedSeconds - session.remaining
        shelterSession = nil
    }

    /// Drop a finished session so the countdown doesn't sit at zero — and
    /// take its wait OUT of the ETA. It used to stay in: a driver who sat
    /// out a 40-minute warning then drove on saw "+40 min" on the ETA for
    /// the rest of the trip, for a wait that was already over.
    func clearFinishedShelter() {
        guard let session = shelterSession, session.isOver else { return }
        stopDelaySeconds = max(0, stopDelaySeconds - session.addedSeconds)
        shelteredSecondsBanked += session.addedSeconds
        shelterSession = nil
    }
    /// The ETA the HUD shows: guidance baseline + unplanned stop time.
    func adjustedRemainingTime(_ baseline: Double) -> Double {
        // Unplanned stopped time, then what this device has LEARNED about
        // this hour in this weather (TrafficLearning) — the model returns
        // 1.0 until it has seen enough trips to be worth listening to, so a
        // fresh install shows the router's own number unchanged.
        let learned = baseline * trafficModel.factor(
            area: location.coordinate.map(TrafficArea.init) ?? .pooled,
            roadClass: currentRoadClass, weather: currentTrafficWeather)
        return TripNeeds.adjustedRemainingSeconds(
            baseline: learned, stopDelaySeconds: stopDelayAheadSeconds)
    }

    /// The stopped time the ETA carries: only the part of a live shelter
    /// wait still AHEAD counts; the minutes already sat out are behind the
    /// driver. The HUD's "+N min" chip shows this, not the whole wait.
    var stopDelayAheadSeconds: Double {
        let elapsedInLiveSession = shelterSession.map { $0.addedSeconds - $0.remaining } ?? 0
        return max(0, stopDelaySeconds - elapsedInLiveSession)
    }

    /// The learned travel time for a route being CHOSEN — so the delay this
    /// device has actually measured steers which route looks fastest, not
    /// only the number shown once driving.
    func learnedETA(for route: PlannedRoute) -> Double {
        let worst = RiskEquations.peakFamily(route.familyPeaks, floor: FlowsCore.riskGreenMin)
        // Judge the route by the roads it's actually made of: a highway run
        // reads the pooled highway learning, a cross-town errand reads this
        // neighbourhood's own.
        let avgMph = route.eta > 0
            ? (route.distanceMeters / 1609.344) / (route.eta / 3600) : 30
        return route.eta * trafficModel.factor(
            area: location.coordinate.map(TrafficArea.init) ?? .pooled,
            roadClass: RoadClass.from(averageMph: avgMph),
            weather: TrafficWeather.from(family: worst))
    }

    // MARK: trip needs (recurring fuel/food/rest cadences)

    /// Trip-needs cadences — VEHICLE-specific fuel + HUMAN-needs defaults
    /// from published guidance, all editable under Settings → Trip needs:
    ///   * fuel: refuel at ~75% of the vehicle's habit-adjusted range
    ///     (keeps the 40 mi reserve with margin); manual override available;
    ///   * rest: NHTSA/AAA drowsy-driving guidance — take a break every
    ///     ~2 hours or 100 miles (default 120 min);
    ///   * food: FMCSA hours-of-service requires a 30-min break by hour 8 —
    ///     a meal cadence of ~3.5 h keeps drivers ahead of it.
    @Published var tripNeedsEnabled: Bool =
        UserDefaults.standard.object(forKey: "flows.tripNeedsEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(tripNeedsEnabled, forKey: "flows.tripNeedsEnabled")
            rebuildTripNeeds()
        }
    }
    @Published var tripRestMinutes: Double =
        UserDefaults.standard.object(forKey: "flows.tripRestMinutes") as? Double ?? 120 {
        didSet {
            UserDefaults.standard.set(tripRestMinutes, forKey: "flows.tripRestMinutes")
            rebuildTripNeeds()
        }
    }
    @Published var tripFoodMinutes: Double =
        UserDefaults.standard.object(forKey: "flows.tripFoodMinutes") as? Double ?? 210 {
        didSet {
            UserDefaults.standard.set(tripFoodMinutes, forKey: "flows.tripFoodMinutes")
            rebuildTripNeeds()
        }
    }
    /// Manual fuel-interval override (miles); nil = derive from the vehicle.
    /// Persisted like rest and food ("all sliders, all persisted").
    @Published var tripFuelMilesOverride: Double? =
        UserDefaults.standard.object(forKey: "flows.tripFuelMilesOverride") as? Double {
        didSet {
            if let miles = tripFuelMilesOverride {
                UserDefaults.standard.set(miles, forKey: "flows.tripFuelMilesOverride")
            } else {
                UserDefaults.standard.removeObject(forKey: "flows.tripFuelMilesOverride")
            }
            rebuildTripNeeds()
        }
    }
    @Published private(set) var tripNeedSchedule: [TripNeeds.Event] = []
    /// Miles driven since the last stop before the current leg began: the
    /// schedule runs from the stop, not from each rerouted leg's start.
    private var tripNeedsMilesBeforeLeg: Double = 0
    /// The food draw's seed, fixed at the stop so the cuisines don't
    /// reshuffle when a reroute changes the leg's length.
    private var tripNeedsSeed: UInt64 = 0
    /// The pace the time cadences turn into miles at, fixed at the stop.
    private var tripNeedsAvgMph: Double = 55

    /// Fuel cadence from the vehicle: 75% of habit-adjusted range (of the
    /// towing range while towing).
    var derivedFuelIntervalMiles: Double? {
        tripFuelMilesOverride
            ?? vehicle.profile.map { p in
                TripNeeds.fuelIntervalMiles(
                    ratedRangeMiles: p.ratedRangeMiles,
                    efficiencyFactor: VehicleProfile.efficiencyFactor(
                        averageSpeedMph: vehicle.averageSpeedMph,
                        idleFraction: vehicle.idleFraction),
                    towing: towingActive)
            }
    }

    private func rebuildTripNeeds() {
        guard tripNeedsEnabled, let route = navigation.route else {
            tripNeedSchedule = []
            return
        }
        // Time cadences → miles at the average speed of the leg driven from
        // the last stop: a reroute's slower road must not move a rest stop
        // that was 20 miles ahead to behind the car.
        let avgMph = tripNeedsAvgMph
        var intervals = TripNeeds.Intervals(
            foodMiles: max(tripFoodMinutes / 60 * avgMph, 20),
            restMiles: max(tripRestMinutes / 60 * avgMph, 20))
        if let fuelMiles = derivedFuelIntervalMiles {
            switch vehicle.profile?.fuelType {
            case .electric: intervals.electricMiles = fuelMiles
            case .diesel: intervals.dieselMiles = fuelMiles
            default: intervals.gasMiles = fuelMiles
            }
        }
        // Seeded by trip length so the "random" food cuisines are stable for
        // the trip but differ between trips. Miles count from the last stop.
        tripNeedSchedule = TripNeeds.schedule(
            totalMiles: tripNeedsMilesBeforeLeg + route.distanceMeters / 1609.344,
            intervals: intervals,
            seed: tripNeedsSeed)
    }

    /// Miles driven since the last stop — the odometer the needs schedule
    /// and its chip count on.
    var tripNeedsMile: Double {
        tripNeedsMilesBeforeLeg + (navigation.guidance?.alongMeters ?? 0) / 1609.344
    }

    /// The next scheduled stop ahead of the vehicle's along-route odometer.
    var nextTripNeed: TripNeeds.Event? {
        guard !tripNeedSchedule.isEmpty else { return nil }
        return TripNeeds.next(after: tripNeedsMile, in: tripNeedSchedule)
    }

    /// Trip-needs chip tapped: run the POI search that need calls for.
    func requestTripNeed(_ event: TripNeeds.Event) async {
        collapsedPanels.remove("stops")   // a fresh search reopens the list
        switch event.need {
        case .food(let category):
            poi.activeKind = .food
            await poi.chooseFood(category, aheadOf: effectivePosition)
        case .fuel(let type):
            poi.activeKind = .gas
            await poi.chooseFuel(type, aheadOf: effectivePosition)
        case .rest:
            await poi.request(.rest, aheadOf: effectivePosition)
        }
    }

    /// The trip's final destination — survives added stops so leg 2 can
    /// resume automatically after a POI stop.
    private var finalDestination: (coordinate: CLLocationCoordinate2D, name: String)?
    /// Read by the Siri add-a-stop intent to confirm the add actually took
    /// (leg planning can fail) — write stays private to the chaining logic.
    private(set) var pendingStopName: String?
    private var pendingStopKind: POIService.Kind?

    /// Choices surviving the active filters (cards render from this).
    /// Computed fresh per call — the routes panel reads it ONCE per render
    /// and passes the array down (reading it per card multiplied the filter
    /// pass and its ARC traffic ~50× per render).
    var filteredChoices: [PlannedRoute] {
        var out = RouteFilter.listed(routeChoices, judged: judgingFilters, limits: filterLimits)
        // Tourist filter CHANGES the ordering: the route with more attractions
        // within reach leads (ties fall back to ETA) — scenic beats fast while
        // the driver is explicitly asking for tourist stops. Only once every
        // card has its own count: half-counted routes can't be compared.
        if routeFilters.contains(.tourist) {
            let counts = out.compactMap { touristCounts[$0.id] }
            if counts.count == out.count, counts.contains(where: { $0 > 0 }) {
                out.sort {
                    let (a, b) = (touristCounts[$0.id] ?? 0, touristCounts[$1.id] ?? 0)
                    if a != b { return a > b }
                    return $0.eta < $1.eta
                }
            }
        }
        return out
    }

    /// The filters that judge the cards right now (RouteFilter.judging).
    var judgingFilters: Set<RouteFilter> {
        RouteFilter.judging(routeFilters, walking: walkingMode)
    }

    /// Filter toggles route through here so request-level filters can
    /// replan: activating "No tolls" fires a toll-free MKDirections request
    /// (tollPreference = .avoid) — merely discarding tolled candidates
    /// collapsed the list to the local-roads route, which was wrong.
    func toggleFilter(_ filter: RouteFilter) {
        towingFilterHold.driverChose(filter)   // towing-off no longer takes it back
        if routeFilters.contains(filter) {
            routeFilters.remove(filter)
            if filter == .tourist {
                poi.clearResults()
                touristCountTask?.cancel()
            }
        } else {
            routeFilters.insert(filter)
            // Tourist stops: pin parks/monuments/museums along the corridor
            // the moment the filter lights up — the map immediately shows what
            // the trip could include (Mammoth Cave on a Louisville→Nashville
            // run), and cards gain per-route attraction counts.
            if filter == .tourist, mode == .choosing {
                refreshTouristSpots()
                refreshTouristCounts()
            }
            if filter == .noTolls, mode == .choosing,
               !routeChoices.contains(where: { !$0.hasTolls && $0.planKind != .avoidHighways }),
               let ep = lastPlanEndpoints {
                Task { await supplementTollFree(ep) }
            }
            // If the active combination just emptied the list, try to
            // FORMULATE a route with those options considered (combined
            // request-level preferences + more alternates).
            if filteredChoices.isEmpty, mode == .choosing, let ep = lastPlanEndpoints {
                Task { await formulateConstrainedRoute(ep) }
            }
        }
        ensureHighlightValid()
    }

    /// How many active filters a route violates — powers the "closest match"
    /// fallback card when nothing satisfies everything.
    func violationCount(_ route: PlannedRoute) -> Int {
        brokenFilters(route).count
    }

    /// The active filters a route breaks, in chip order: the closest-match
    /// card names them above its GO — a count alone hid a low bridge.
    func brokenFilters(_ route: PlannedRoute) -> [RouteFilter] {
        let limits = filterLimits
        let judged = judgingFilters
        let peers = RouteFilter.trafficPeers(routeChoices, judged: judged, limits: limits)
        return RouteFilter.allCases.filter {
            judged.contains($0) && !$0.passes(route, limits: limits, among: peers)
        }
    }

    /// Searches for a route that fits the filters now in flight
    /// (formulateConstrainedRoute, supplementTollFree): the empty-list text
    /// says "looking" only while one runs.
    @Published private(set) var routeSearchesInFlight = 0

    /// Nothing passes → replan with every request-level preference the
    /// active filters imply, hydrate, and let the relative filters resolve.
    private func formulateConstrainedRoute(
        _ ep: (from: CLLocationCoordinate2D, fromName: String,
               to: CLLocationCoordinate2D, toName: String)
    ) async {
        routeSearchesInFlight += 1
        defer { routeSearchesInFlight -= 1 }
        guard let raw = try? await router.planRoutes(
            from: ep.from, fromName: ep.fromName, to: ep.to, toName: ep.toName,
            includeTollFree: routeFilters.contains(.noTolls)) else { return }
        // Scale the fresh plan the SAME way present() scaled the cards
        // already on screen. Without this the dedupe compared a raw router
        // ETA against a pace-corrected one: for a driver whose learned
        // multiplier is 1.15, the identical road came back 9 minutes
        // "faster", cleared the 45-second sameness window, and appeared as a
        // second card that then outranked its honest twin.
        let planned = RouteService.applyPersonalPace(
            raw, multiplier: DrivingProfileStore.shared.etaMultiplier)
        let fresh = planned.filter { candidate in
            !routeChoices.contains {
                abs($0.eta - candidate.eta) < 45
                    && abs($0.distanceMeters - candidate.distanceMeters) < 400
            }
        }
        guard !fresh.isEmpty, mode == .choosing else { return }
        routeChoices.append(contentsOf: fresh)
        // Through the tracked task, cancelling the previous loop: an
        // untracked Task here stacked a second retry ladder that present()
        // could not cancel, re-scoring every route against NWS again.
        restartRiskHydration()
        if routeFilters.contains(.tourist) { refreshTouristCounts() }   // new cards need theirs
    }

    private func supplementTollFree(
        _ ep: (from: CLLocationCoordinate2D, fromName: String,
               to: CLLocationCoordinate2D, toName: String)
    ) async {
        routeSearchesInFlight += 1
        defer { routeSearchesInFlight -= 1 }
        guard let raw = try? await router.planRoutes(
            from: ep.from, fromName: ep.fromName, to: ep.to, toName: ep.toName,
            includeTollFree: true) else { return }
        // Scale the fresh plan the SAME way present() scaled the cards
        // already on screen. Without this the dedupe compared a raw router
        // ETA against a pace-corrected one: for a driver whose learned
        // multiplier is 1.15, the identical road came back 9 minutes
        // "faster", cleared the 45-second sameness window, and appeared as a
        // second card that then outranked its honest twin.
        let planned = RouteService.applyPersonalPace(
            raw, multiplier: DrivingProfileStore.shared.etaMultiplier)
        let fresh = planned.filter { candidate in
            !candidate.hasTolls && !routeChoices.contains {
                abs($0.eta - candidate.eta) < 45 && abs($0.distanceMeters - candidate.distanceMeters) < 400
            }
        }
        guard !fresh.isEmpty, mode == .choosing else { return }
        routeChoices.append(contentsOf: fresh)
        // Through the tracked task, cancelling the previous loop: an
        // untracked Task here stacked a second retry ladder that present()
        // could not cancel, re-scoring every route against NWS again.
        restartRiskHydration()
        if routeFilters.contains(.tourist) { refreshTouristCounts() }   // new cards need theirs
    }

    /// Endpoints of the last plan — lets filter toggles replan variants.
    private var lastPlanEndpoints: (from: CLLocationCoordinate2D, fromName: String,
                                    to: CLLocationCoordinate2D, toName: String)?
    var lastPlanEndpointsPublic: (from: CLLocationCoordinate2D, fromName: String,
                                  to: CLLocationCoordinate2D, toName: String)? {
        lastPlanEndpoints
    }

    /// Planning entry point used by the planner UI: remembers endpoints and
    /// includes a toll-free variant up front when that filter is already on.
    /// Journals its phases: a planning freeze on a Mac was reported and the
    /// window exposes nothing to drive by script, so the journal has to say
    /// which step never returned.
    func plan(from: CLLocationCoordinate2D, fromName: String,
              to: CLLocationCoordinate2D, toName: String) async throws -> [PlannedRoute] {
        // Cache warmer at the ONE choke point every planning path passes
        // through — planner submit, favorite tap, the walk↔drive replan, and
        // any future entry point — fired before the MKDirections await, so
        // short/medium corridors have most of their alert cells cached before
        // scoring starts (WeatherAlertService.prefetchCells gates away
        // corridors too long for the straight line to predict the roads).
        // Wiring it per-call-site left the mode replan unprimed.
        alerts.prefetchCorridor(from: from, to: to)
        // Commit lastPlanEndpoints only when a plan actually lands (below).
        // Setting it up front meant a throw/empty result left the app still
        // showing the OLD A→B routes while lastPlanEndpoints pointed at the
        // NEW destination — a later filter toggle then appended routes to the
        // wrong destination into the visible list.
        let routes = try await router.planRoutes(
            from: from, fromName: fromName, to: to, toName: toName,
            includeTollFree: routeFilters.contains(.noTolls),
            walking: walkingMode)
        // Apple's pedestrian router refuses long walks — but "too far to walk"
        // is not an answer. Route along LOCAL ROADS (avoid-highways: walkers
        // can't use freeways) and compute the ETA at real walking pace, clearly
        // labeled an estimate. The walker still gets distance, geometry, and
        // turn-by-turn road names.
        if routes.isEmpty && walkingMode {
            let roadRoutes = try await router.planRoutes(
                from: from, fromName: fromName, to: to, toName: toName,
                includeTollFree: false, walking: false)
            // Walkers can NEVER be sent onto a freeway. Prefer routes with no
            // highways at all; if every candidate uses some highway, keep the
            // avoid-highways one (least freeway) and the notice warns to verify.
            let noHighway = roadRoutes.filter { !$0.hasHighways }
            let avoidHwy = roadRoutes.filter { $0.planKind == .avoidHighways }
            let base = !noHighway.isEmpty ? noHighway
                     : !avoidHwy.isEmpty ? avoidHwy
                     : roadRoutes
            let anyHighway = base.contains { $0.hasHighways }
            let estimates = base.map { r -> PlannedRoute in
                var w = r
                w.isWalkingEstimate = true
                w.etaOverride = PlannedRoute.walkingEstimateSeconds(meters: r.distanceMeters)
                return w
            }
            // The notice describes the estimates; with none, it described
            // nothing and still shouted at the driver.
            if estimates.isEmpty {
                plannerNotice = "No walking route found here."
            } else {
                plannerNotice = anyHighway
                    ? "Too far for walking directions — this is a walking guess at "
                        + "3.1 mph. No route here stays off highways the whole way; part "
                        + "may follow one. Make sure there is a safe, legal path before you go."
                    : "Too far for walking directions — this is a walking guess along "
                        + "local roads at 3.1 mph. Check for sidewalks or shoulders "
                        + "before you go."
                lastPlanEndpoints = (from, fromName, to, toName)
                recents.record(name: toName, coordinate: to)
            }
            return estimates
        }
        plannerNotice = nil
        if !routes.isEmpty {
            lastPlanEndpoints = (from, fromName, to, toName)
            recents.record(name: toName, coordinate: to)
        }
        return routes
    }

    /// One-line planner banner (e.g. the walking→driving fallback) shown atop
    /// the route choices; cleared on the next successful plan in-mode.
    @Published var plannerNotice: String?

    // MARK: rolling walking-path refinement (long-walk estimates)

    /// Accurate Apple `.walking` geometry for the stretch immediately ahead of
    /// a walker on a long WALKING ESTIMATE — drawn ON TOP of the big-picture
    /// road route so the traveler follows real sidewalks/crossings locally
    /// while the overall direction stays the (relatively accurate) road path.
    @Published var walkingRefinedPath: [CLLocationCoordinate2D] = []
    private var walkRefineAnchor: CLLocationCoordinate2D?
    private var walkRefineTask: Task<Void, Never>?

    /// The local window the pedestrian router refreshes (Apple happily walks a
    /// few km even when it refused the whole cross-town trip).
    private static let walkRefineWindowMeters: CLLocationDistance = 2_500
    /// Re-fetch once the walker has advanced this far past the last anchor.
    private static let walkRefineStepMeters: CLLocationDistance = 400

    /// Refresh the near-path with real pedestrian routing when the walker has
    /// moved enough. Only for an active walking ESTIMATE (a normal short
    /// walking route is already exact; driving/transit don't apply).
    func refineWalkingPathIfNeeded(from here: CLLocationCoordinate2D) {
        guard navigation.route?.isWalkingEstimate == true else {
            if !walkingRefinedPath.isEmpty { walkingRefinedPath = [] }
            walkRefineAnchor = nil
            return
        }
        if let anchor = walkRefineAnchor,
           POIRanking.meters(anchor, here) < Self.walkRefineStepMeters,
           !walkingRefinedPath.isEmpty {
            return   // still on the last refined stretch
        }
        walkRefineAnchor = here
        // Target = a point ~window-meters ahead ALONG the estimate route, so the
        // pedestrian router hugs the intended corridor instead of shortcutting.
        let target = navigation.coordinateAhead(meters: Self.walkRefineWindowMeters) ?? here
        let routeID = navigation.route?.id
        walkRefineTask?.cancel()
        // Background geometry refinement — not latency-critical; keep it off
        // the P-core/userInteractive band the MainActor would grant it.
        // Task.detached, not Task: a plain Task inherits the MainActor this
        // method runs on, so the "background" refinement — the request and
        // the polyline copy — ran on the main actor at utility priority.
        // Only the write hops back.
        walkRefineTask = Task.detached(priority: .utility) { [weak self] in
            let req = MKDirections.Request()
            req.source = MKMapItem(placemark: MKPlacemark(coordinate: here))
            req.destination = MKMapItem(placemark: MKPlacemark(coordinate: target))
            req.transportType = .walking
            guard let route = (try? await MKDirections(request: req).calculate())?
                .routes.first, !Task.isCancelled else { return }
            let poly = route.polyline
            let n = poly.pointCount
            guard n > 1 else { return }
            var coords = [CLLocationCoordinate2D](
                repeating: kCLLocationCoordinate2DInvalid, count: n)
            poly.getCoordinates(&coords, range: NSRange(location: 0, length: n))
            let refined = coords   // a value crosses the actor hop, not the captured var
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled, self.navigation.route?.id == routeID,
                      self.navigation.route?.isWalkingEstimate == true else { return }
                self.walkingRefinedPath = refined
            }
        }
    }

    init() {
        navigation = NavigationEngine(location: location)
        // SwiftUI does NOT observe nested ObservableObjects: a change to
        // e.g. riskField.loaded or poi.isSearching would never re-render a
        // view that only holds `model`. Forward every service's
        // objectWillChange so views observing AppModel see them all.
        // (Found live: the Map Filter pill never appeared because `loaded`
        // flipped invisibly.)
        // Warning-aware shelters: the shelter search matches the SPECIFIC
        // hazard bearing down — an imminent warning names it directly;
        // otherwise fall back to whatever is active near the corridor.
        // Shelter that matches the THREAT: ordinary open buildings for
        // weather you wait out indoors, a solid building when the wind is
        // the story, an official shelter only for an evacuation — and the
        // vehicle itself when the danger is to driving rather than to
        // buildings. See ShelterPolicy.
        poi.shelterQueries = { [weak self] in
            guard let self else { return ShelterPolicy.Kind.anyBuilding.searchQueries }
            if let w = self.imminentWarning {
                return ShelterPolicy.kind(forEvent: w.event,
                                          severityScore: w.severityScore).searchQueries
            }
            // No imminent card up: fall back to whatever is active near the
            // corridor, scored from the risk band the route carries.
            let events = self.alerts.activeHeadlines
                + (self.navigation.route?.alertEvents ?? [])
            if let worst = events.first {
                return ShelterPolicy.kind(
                    forEvent: worst,
                    severityScore: self.navigation.route?.weatherRisk ?? 0.6).searchQueries
            }
            return ShelterPolicy.Kind.anyBuilding.searchQueries
        }
        navigation.onReroute = { [weak self] leg in self?.startRerouteLeg(leg) ?? false }
        // `location` publishes once a second and is forwarded to the whole
        // model. Reviewed and KEPT: 34 view sites across ContentView,
        // PlannerPanel, the HUD, the banners and CarPlay read position,
        // speed and course through `model`, and would each need their own
        // observation of LocationService to drop it here. The per-fix
        // publishes that used to ride along with it (camera warning, text
        // scale, posted limit, wind, work zones) now publish only on change,
        // which is where the wasted invalidation actually was.
        let children: [any ObservableObject] = [
            location, router, poi, alerts, riskField, navigation, favorites,
            vehicle, radio, radioBrowser, scanner, vehicleLink, smartcar, crash,
            breadcrumbs, corridors, trafficModel, roadEfficiency,
        ]
        for child in children {
            (child.objectWillChange as? ObservableObjectPublisher)?
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &serviceSubscriptions)
        }
        poi.truckerMode = truckerUI   // didSet doesn't fire for the initial value
        scanner.listen(near: location.coordinate)   // don't wait for the first fix
        MusicController.shared.provider = musicProvider   // same didSet gap
        if personalVoiceAnnouncements {                   // same didSet gap
            VoiceAnnouncer.shared.setPersonalVoiceEnabled(true)
        }
        vehicle.towingActive = towingActive
        // …and the FILTERS towing implies. didSet does not fire for the value
        // restored from UserDefaults, so a driver who quit while towing came
        // back with towing "on" and every towing route-safety filter off —
        // routed under a low bridge by an app that knew it was towing.
        if towingActive {
            towingFilterHold.towingOn(&routeFilters)
            applyVehicleMaxGradeDefault()
        }
        checkTowingSignal()   // and at app start
        // Grade slider default follows the vehicle until the driver moves the
        // slider — seed it now and re-derive whenever the vehicle changes.
        // (receive(on:) defers past @Published's willSet so the new profile
        // is actually in place when the default is recomputed.)
        applyVehicleMaxGradeDefault()
        vehicle.$profile
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyVehicleMaxGradeDefault() }
            .store(in: &serviceSubscriptions)
        // Spoken turn-by-turn rides the guidance stream (1 Hz while
        // navigating); speakTurn dedupes per step.
        navigation.$guidance
            .compactMap { $0 }
            .sink { [weak self] guidance in self?.speakTurn(guidance) }
            .store(in: &serviceSubscriptions)
        // Radio state feeds the mini player, Siri, and CarPlay when radio
        // IS the picked service.
        MusicController.shared.radioService = radio
        radio.objectWillChange
            .sink { _ in
                Task { @MainActor in MusicController.shared.syncFromRadio() }
            }
            .store(in: &serviceSubscriptions)
        // Watch the link's health while music plays, so a failing signal
        // stages the fallback before the audio dies (1 Hz is plenty —
        // buffers drain over seconds, not milliseconds).
        location.$latest
            .compactMap { $0 }
            .sink { [weak self] _ in self?.checkPlaybackSignalHealth() }
            .store(in: &serviceSubscriptions)
        // Offline handoff: the network path dropping must not end the
        // music — hand off to what still plays (see PlaybackFallback).
        breadcrumbs.$isOffline
            .removeDuplicates()
            .sink { [weak self] offline in
                Task { @MainActor in self?.handleConnectivity(offline: offline) }
            }
            .store(in: &serviceSubscriptions)
        // Location: on onboarded launches, request right away (a no-op once
        // granted). First launch waits for the welcome card's Get started.
        if onboarded { location.requestAuthorization() }
        // Bluetooth vehicle link: OFF until the driver turns it on in
        // Settings — creating the scanner at launch fired the Bluetooth
        // permission dialog on first open, before any explanation.
        vehicleLink.scanning =
            UserDefaults.standard.bool(forKey: "flows.vehicleLinkScanning")
        // Populate the price column with state-average ESTIMATES (labeled
        // "est."); a licensed station feed replaces this same hook.
        poi.priceProvider = { item, fuel in
            if item.placemark.isoCountryCode == "MX" {
                return FuelPrices.mexicoEstimate(fuel: fuel)
            }
            return FuelPrices.estimate(fuel: fuel, state: item.placemark.administrativeArea)
        }
        // Live station prices layer on top when a TomTom key is set
        // (async — rows update as prices land).
        poi.livePriceProvider = { coord, fuel in
            // Ladder: Mexico's CRE feed first (the government-mandated
            // publication of every station's posted prices, MXN/liter,
            // keyless) → TomTom → nil (state estimate rides as a caption).
            if RatingsAndCost.Country.forCoordinate(
                latitude: coord.latitude, longitude: coord.longitude) == .mexico,
               let mx = await MexicoFuelPrices.shared.price(near: coord, fuel: fuel) {
                // CRE is MXN/L — convert to the model's USD/gal so ranking
                // and the price column compare like with like.
                return FuelPrices.usdPerGallon(mxnPerLiter: mx)
            }
            return await TomTomFuel.shared.price(near: coord, fuel: fuel)
        }
        let tomtomKey = tomtomAPIKey
        Task { await TomTomFuel.shared.setKey(tomtomKey) }
        // Resume the learned driving shape (speed/idle) from the encrypted
        // profile — these feed range and refuel prediction.
        let learned = DrivingProfileStore.shared.profile
        vehicle.restoreDriving(averageSpeedMph: learned.averageSpeedMph,
                               idleFraction: learned.idleFraction)
        // Driving-habit + tank-odometer tracking: every navigation GPS fix
        // feeds the vehicle range model (speed/idling shape efficiency),
        // the FMCSA hours-of-service clock, the refuel-dwell detector, and
        // the steep-grade lookahead.
        location.$latest
            .compactMap { $0 }
            .sink { [weak self] fix in
                guard let self else { return }
                defer { self.lastHabitFix = fix }
                // Breadcrumbs record in EVERY mode — the offline way-back
                // trail must exist before you realize you need it.
                self.breadcrumbs.record(fix.coordinate)
                // Speed history feeds the crash decision — kept in every
                // mode so an impact right at GO still has "before" speed.
                self.recordSpeed(fix)
                // Follow the closest NOAA transmitter in EVERY mode: parked
                // at home the emergency-radio card should already name the
                // local station, not one from wherever the app last ran.
                self.retuneRadioIfNeeded(at: fix.coordinate)
                // Dusk and dawn move with the vehicle as well as the clock —
                // a day's drive north or west shifts them by real minutes.
                // Ten kilometres shifts them by seconds, so that is the step;
                // the scheduled timer handles the clock in between. (This
                // rebuilt the timer and re-ran the solar terms every fix.)
                if self.daylightEvaluatedAt.map({ POIRanking.meters($0, fix.coordinate) > 10_000 }) ?? true {
                    self.daylightEvaluatedAt = fix.coordinate
                    self.refreshDaylight()
                }
                // Follow the dispatch feed covering wherever we are now.
                self.scanner.listen(near: fix.coordinate)
                guard self.mode == .navigating else { return }
                let delta = self.lastHabitFix.map { fix.distance(from: $0) } ?? 0
                // A walk teaches nothing about the vehicle: it burned no fuel,
                // and its pace dragged the speed and idle shape (and so the
                // next drive's range and fuel stops) toward walking.
                if self.navigation.route?.isWalk != true {
                    self.vehicle.recordFix(speedMps: max(fix.speed, 0),
                                           deltaMeters: min(delta, 500))   // GPS jump guard
                    // Persist the speed/idle shape (coalesced to ~1/min inside
                    // the store): these EWMAs drive range and refuel prediction
                    // and used to reset to a 55 mph stranger on every launch.
                    DrivingProfileStore.shared.updateDriving(
                        averageSpeedMph: self.vehicle.averageSpeedMph,
                        idleFraction: self.vehicle.idleFraction)
                    self.recordRoadEfficiency(deltaMeters: min(delta, 500), fix: fix)
                    self.recordDailyDriving(deltaMeters: min(delta, 500))
                }
                self.maybeOfferTripShare()   // a long DAY can cross 200 mi mid-leg
                self.refreshCloudFuelIfDue()
                self.updateFuelRecommendation()
                self.updateFuelWarning()   // last-chance matching-fuel stops
                self.updatePostedSpeedLimit(fix)   // the HUD speed sign
                self.updateUpcomingLanes()         // lane row at the maneuver
                self.updateCorridorWind(near: fix.coordinate)
                // Saved corridors age out as they stop being useful:
                // arrived, left far behind, or simply stale. Every 500 m —
                // the prune re-decodes every saved polyline, and "far
                // behind" does not change between one fix and the next.
                if self.lastPruneAt.map({ POIRanking.meters($0, fix.coordinate) > 500 }) ?? true {
                    self.lastPruneAt = fix.coordinate
                    self.corridors.prune(position: fix.coordinate)
                }
                self.updateDrivingClocks(fix: fix)
                self.updateSteepGrade()
                // Fixed speed and red-light cameras on the road ahead — the
                // only enforcement data any app may lawfully carry.
                self.updateEnforcementCameras(fix)
                // Towing is live during the trip, not a trip-start snapshot:
                // re-poll telemetry (a trailer hitched mid-trip auto-toggles
                // towing mode) and surface limit violations as a warning once.
                self.checkTowingSignal()
                self.updateTowingWarning()
                // A long WALKING ESTIMATE keeps its big-picture road geometry
                // for direction, but the stretch right in front of the walker
                // is refreshed with Apple's real pedestrian network as they go.
                self.refineWalkingPathIfNeeded(from: fix.coordinate)
                // Stream guidance to the Apple Watch (map + wrist taps).
                if let g = self.navigation.guidance {
                    let miles = g.distanceToManeuver / 1609.344
                    let text = miles < 0.19
                        ? "\(Int((g.distanceToManeuver / 0.3048 / 50).rounded() * 50)) ft"
                        : String(format: miles < 10 ? "%.1f mi" : "%.0f mi", miles)
                    // The fix this sink was handed, not location.coordinate:
                    // this runs inside $latest's willSet, when the published
                    // value is still the PREVIOUS fix.
                    if fix.course >= 0 { self.lastWatchHeading = fix.course }
                    self.watch.sendGuidance(
                        instruction: g.instruction,
                        distanceText: text,
                        distanceToManeuver: g.distanceToManeuver,
                        coordinate: fix.coordinate,
                        heading: self.lastWatchHeading)
                }
            }
            .store(in: &serviceSubscriptions)
        crash.context = { [weak self] in
            (self?.location.coordinate,
             self?.vehicle.profile,
             self?.medicalNotes.isEmpty == false ? self?.medicalNotes : nil)
        }
        // The motion half of the crash decision: a rollercoaster pulls the
        // g's of a collision, so the check-in also needs a road-speed
        // vehicle ON A ROAD coming to a sudden stop (CrashLogic.isCrash).
        crash.motionEvidence = { [weak self] in
            guard let self else { return (0, 0, nil) }
            // A fix with no speed (-1: Wi-Fi or cell, GPS reacquiring) is
            // unknown, not stopped — `location.speed` clamps it to 0, which
            // read as a dead stop at full speed.
            let after = self.location.latest.map {
                $0.speed >= 0 && $0.speedAccuracy >= 0 ? $0.speed : .nan
            } ?? .nan
            return (self.recentPeakSpeedMps, after, self.navigation.metersFromCorridor)
        }
        crash.hasEmergencyContact = { [weak self] in
            self?.emergencyContactPhone.isEmpty == false
        }
        // Each time the crash question is asked it also lands as a tap: for
        // a driver who can't hear it, the tap is the question (Haptics).
        crash.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self, self.hapticAlerts, case .checkingIn = state else { return }
                Haptics.warning()
            }
            .store(in: &serviceSubscriptions)
        // Spoken lines hand the audio session back when FLOWS falls quiet
        // (VoiceAnnouncer.releaseSessionWhenQuiet), never from under the
        // crash check-in or FLOWS's own sound.
        VoiceAnnouncer.shared.checkInHoldsSession = { [weak self] in
            self.map { $0.crash.state != .idle || $0.crash.isSpeaking } ?? false
        }
        VoiceAnnouncer.shared.ownAudioPlaying = { [weak self] in
            guard let self else { return false }
            return (self.radio.playingChannelID != nil && !self.radio.isPaused)
                || self.scanner.isListening
        }
        // Telemetry ladder: OEM cloud (Smartcar) → Bluetooth (OBD adapter /
        // TPMS caps) → nothing (odometer model carries on). Real fuel data
        // silences the gauge check-ins automatically — while it is current:
        // the fresher of the two readings, and neither once it has aged out.
        vehicle.telemetry = { [weak self] in
            guard let self else { return (nil, nil) }
            let fuel = FuelReading.freshest(
                [self.smartcar.fuelReading, self.vehicleLink.obdFuelReading])?.fraction
            var tires = self.smartcar.tirePressuresPsi
            for (k, v) in self.vehicleLink.tirePressuresPsi { tires[k] = v }
            return (fuel, tires.isEmpty ? nil : tires.values.sorted())
        }
        let key = yelpAPIKey
        Task { await YelpLink.shared.setKey(key) }
        let gKey = googlePlacesAPIKey
        Task { await GooglePlacesLink.shared.setKey(gKey) }
        Task { await self.smartcar.refreshData() }   // reconnects silently if tokens exist
        Self.shared = self
    }

    /// Seamless towing auto-detect: poll the telemetry ladder each GPS tick;
    /// the first source reporting a trailer flips towing mode ON (with a
    /// visible chip) — one line for any future FordPass/OBD/MFi source.
    @Published private(set) var towingAutoDetected = false
    func checkTowingSignal() {
        guard let detected = vehicle.telemetryTowingDetected() else { return }
        if detected && !towingActive {
            towingActive = true
            towingAutoDetected = true
        } else if !detected && towingAutoDetected && towingActive {
            towingActive = false
            towingAutoDetected = false
        }
    }

    /// One-shot towing-limit warning during navigation: the moment the active
    /// weights exceed a manufacturer rating (or towing auto-detects mid-trip
    /// already over a limit), the worst violation surfaces once — not a
    /// per-tick nag; clears when the violation clears so a later new one warns.
    @Published var towingWarning: String?
    private var warnedTowingViolation = false
    func updateTowingWarning() {
        guard towingActive, mode == .navigating else {
            if towingWarning != nil { towingWarning = nil }
            warnedTowingViolation = false
            return
        }
        guard let worst = towingViolations.first else {
            warnedTowingViolation = false
            if towingWarning != nil { towingWarning = nil }
            return
        }
        guard !warnedTowingViolation else { return }
        warnedTowingViolation = true
        if towingWarning != worst.title { towingWarning = worst.title }
    }

    /// Low-tire warning (BLE TPMS caps or OEM cloud): worst offender named.
    var lowTireWarning: String? {
        let all = smartcar.tirePressuresPsi.merging(
            vehicleLink.tirePressuresPsi, uniquingKeysWith: { _, ble in ble })
        let low = all.filter { $0.value < VehicleLink.lowPressurePsi }
        guard let worst = low.min(by: { $0.value < $1.value }) else { return nil }
        return String(format: "%@ low: %.0f psi", worst.key, worst.value)
    }

    // MARK: driving clocks — FMCSA hours of service + refuel dwell

    /// Cumulative driving time since the last 30-minute break (HOS timer).
    @Published private(set) var drivingSeconds: Double = 0
    /// Prompt shown after a fuel-stop-length dwell: "did you fill up?"
    @Published var refuelPrompt = false
    private var lastClockFix: Date?
    private var stoppedSince: Date?
    private var refuelPromptShownAt: Date?

    var hosStatus: HOSRules.Status { HOSRules.status(drivingSeconds: drivingSeconds) }

    private func updateDrivingClocks(fix: CLLocation) {
        let now = fix.timestamp
        defer { lastClockFix = now }
        let dt = lastClockFix.map { min(now.timeIntervalSince($0), 30) } ?? 0
        if fix.speed > 3 {
            drivingSeconds += max(dt, 0)
            // Rolling again: a completed fuel-length stop while the prompt
            // was up implies the answer arrived (or wasn't needed).
            if let stopStart = stoppedSince,
               now.timeIntervalSince(stopStart) >= HOSRules.breakResetSeconds {
                drivingSeconds = 0   // 30-min stop resets the 8 h break clock
            }
            stoppedSince = nil
        } else if fix.speed <= 1 {   // includes -1 = invalid/stationary fixes
            if stoppedSince == nil { stoppedSince = now }
            // GPS-based refuel detection: a 4+ minute dwell mid-trip looks
            // like a fuel stop → ask ONCE per dwell. (CarPlay does not
            // expose the vehicle's real fuel level to third-party nav apps —
            // when Apple opens that API this becomes automatic.)
            // Not on a walk: a walker stopping by a station filled no tank.
            if let stopStart = stoppedSince, let profile = vehicle.profile,
               navigation.route?.isWalk != true,
               vehicle.telemetry().fuelFraction == nil,   // real data = no need to ask
               now.timeIntervalSince(stopStart) >= 240,
               refuelPromptShownAt.map({ $0 < stopStart }) ?? true,
               vehicle.refuelLearning.shouldPrompt(checkInsEnabled: refuelCheckInsEnabled && notifyFuel) {
                // Only ask where fuel actually IS. A four-minute dwell is
                // lunch as often as it is a fill-up, and a question that is
                // usually wrong gets dismissed unread. The prompt waits for
                // the station lookup rather than firing hopefully.
                refuelPromptShownAt = now
                let here = fix.coordinate
                let electric = profile.fuelType == .electric
                let diesel = profile.fuelType == .diesel
                Task { [weak self] in
                    let atPump = await LiveHazardFeedFetcher.shared.isAtFuelStation(
                        near: here, electric: electric, diesel: diesel)
                    guard let self, atPump, self.stoppedSince == stopStart else { return }
                    self.refuelPrompt = true
                }
            }
        }
    }

    /// Gauge answered: `fractionBefore` = where the needle sat pre-fill
    /// (nil = dismissed without answering → assume a full refuel, which
    /// never hurts the accuracy stat).
    func answerRefuelPrompt(didFill: Bool, fractionBefore: Double? = nil) {
        if didFill {
            if let fractionBefore {
                vehicle.recordRefuel(reportedFractionBefore: fractionBefore)
            } else {
                vehicle.filledUp()
            }
        }
        refuelPrompt = false
    }

    // MARK: long-trip share — "tell someone where you're going"

    /// Banner up? One nudge per trip (see maybeOfferTripShare); any button
    /// press clears it and the latch keeps it from returning this trip.
    @Published var tripSharePrompt = false
    private var tripShareOffered = false

    /// Meters driven today (while navigating), persisted so an app relaunch
    /// mid-day keeps the total. Feeds the 200-mile daily trigger.
    private var dailyDrive: DailyDriveLog = {
        if let data = UserDefaults.standard.data(forKey: "flows.dailyDrive"),
           let saved = try? JSONDecoder().decode(DailyDriveLog.self, from: data) {
            return saved
        }
        return DailyDriveLog.empty()
    }()
    private var dailyDrivePersistedMeters = 0.0

    private func recordDailyDriving(deltaMeters: Double) {
        dailyDrive.add(meters: deltaMeters)
        // Persist every ~500 m, not every 1 Hz fix — losing half a kilometer
        // of day-total to a crash is harmless; the trigger tolerance is miles.
        if abs(dailyDrive.meters - dailyDrivePersistedMeters) >= 500 {
            dailyDrivePersistedMeters = dailyDrive.meters
            if let data = try? JSONEncoder().encode(dailyDrive) {
                UserDefaults.standard.set(data, forKey: "flows.dailyDrive")
            }
        }
    }

    // MARK: erase — "Erase everything FLOWS has learned"

    /// Every store the Settings button reaches, in ONE place, the key last.
    ///
    /// The list lived in the button and was missed each time a store was
    /// added: the share history (who, and when), the shower reports (stops
    /// the driver stood in) and today's mile count survived it, and the
    /// vehicle's in-memory speed and idle copies wrote the erased driving
    /// profile straight back on the next fix. A new store goes here.
    func eraseEverythingLearned() async {
        SeasonalRiskModel.shared.eraseLearnedHistory()
        EverydayPlaces.shared.erase()
        recents.erase()
        ChoiceLogStore.shared.erase()
        vehicle.resetDrivingHabits()   // before the profile they were loaded from
        DrivingProfileStore.shared.erase()
        // Where the driver has actually BEEN: the breadcrumb trail, the
        // saved offline corridors and the two learned road models.
        breadcrumbs.erase()
        corridors.erase()
        trafficModel.erase()
        roadEfficiency.erase()
        shareHistory.erase()
        ShowerAvailability.eraseReports()
        dailyDrive = DailyDriveLog.empty()
        dailyDrivePersistedMeters = 0
        UserDefaults.standard.removeObject(forKey: "flows.dailyDrive")
        // A trip under way began before the erase: its arrival must not
        // teach it back (where it started, the route, the pace, the time
        // in traffic). A leg started after this learns only itself.
        tripPredictedSeconds = nil
        tripStartedAt = nil
        tripStartArea = nil
        tripDistanceMeters = 0
        legStartedAt = nil
        legPredictedSeconds = 0
        tripLearningErased = mode == .navigating
        // Last: drop the key. Each store shreds its own file above, but
        // until the key goes with it an escaped ciphertext is still
        // readable — and the button promises the app is "back to knowing
        // nothing".
        SecureBehaviorStore.destroyKey()
        await FlowsDiag.shared.clear(
            leaving: "journal cleared: the driver erased what FLOWS had learned")
    }

    /// One banner per trip, the moment either trigger is true: at GO for a
    /// long plotted route, or mid-drive when the day's total crosses the
    /// line. The latch (not the banner flag) is what makes it once-per-trip —
    /// dismissing the banner must not re-arm it.
    private func maybeOfferTripShare() {
        guard mode == .navigating, !tripShareOffered,
              let route = navigation.route else { return }
        // The trip's full plotted length: the leg being driven plus the
        // continuation leg behind an added stop (both are on the map).
        let routeMeters = route.distanceMeters + (upcomingLeg?.distanceMeters ?? 0)
        // TODAY's miles: at GO no fix has rolled the log over yet.
        guard TripShareLogic.shouldOffer(routeMeters: routeMeters,
                                         drivenTodayMeters: dailyDrive.metersDriven(on: Date()))
        else { return }
        tripShareOffered = true
        tripSharePrompt = true
    }

    /// Time and distance left to the trip's final destination: the leg being
    /// driven plus, behind an added stop, the way on from it, with stopped
    /// time and learned traffic folded into the time. The leg alone used to
    /// be read as the whole trip. `toStop`: the way on isn't planned yet, so
    /// the numbers end at the stop. nil with no leg.
    var tripRemaining: (seconds: Double, meters: Double, toStop: Bool)? {
        let legSeconds = navigation.guidance?.remainingTime ?? navigation.route?.eta
        let legMeters = navigation.guidance?.remainingDistance ?? navigation.route?.distanceMeters
        guard let legSeconds, let legMeters else { return nil }
        let onward = upcomingLeg
        return (adjustedRemainingTime(legSeconds + (onward?.eta ?? 0)),
                legMeters + (onward?.distanceMeters ?? 0),
                onward == nil && pendingStopName != nil)
    }

    /// The prefilled text for the CURRENT trip: true endpoint (not an added
    /// stop), live arrival estimate (shelter delay and the way on from an
    /// added stop included), map link. Until the way on is planned, the stop
    /// is the one arrival FLOWS can stand behind, so the time is given for
    /// the stop and the text says so.
    func tripShareBody() -> String {
        let remaining = tripRemaining
        let legEnd = navigation.route.flatMap { Self.lastCoordinate(of: $0) }
        let destination = finalDestination?.name ?? navigation.route?.destinationName ?? "my stop"
        let coordinate = finalDestination?.coordinate ?? legEnd
        return TripShareLogic.shareMessage(
            destination: destination,
            arrival: Date().addingTimeInterval(remaining?.seconds ?? adjustedRemainingTime(0)),
            latitude: coordinate?.latitude, longitude: coordinate?.longitude,
            firstStop: remaining?.toStop == true ? pendingStopName : nil)
    }

    /// Messages URL for this trip to `phone` — the view opens it (openURL
    /// works on both platforms; the model stays UIKit-free). nil when the
    /// number has no digits.
    func tripShareURL(phone: String) -> URL? {
        TripShareLogic.smsURLString(number: phone, body: tripShareBody())
            .flatMap { URL(string: $0) }
    }

    /// Who to offer, best first: the emergency contact when set (the
    /// default), then prior recipients by frequency + recency, deduped.
    func tripShareCandidates() -> [(name: String, phone: String)] {
        var out: [(name: String, phone: String)] = []
        var seen: Set<String> = []
        if !emergencyContactPhone.isEmpty {
            out.append((emergencyContactName.isEmpty ? "Emergency contact"
                            : emergencyContactName,
                        emergencyContactPhone))
            seen.insert(ShareHistoryStore.normalized(emergencyContactPhone))
        }
        for r in shareHistory.suggestions() {
            let key = ShareHistoryStore.normalized(r.phone)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append((r.name.isEmpty ? r.phone : r.name, r.phone))
        }
        return out
    }

    // MARK: steep-grade lookahead (the localized grade table, applied)

    /// Next steep segment ahead from the route's grade table — HUD chip.
    @Published private(set) var upcomingSteepGrade: GradeSegment?

    private func updateSteepGrade() {
        guard let route = navigation.route, !route.gradeProfile.isEmpty else {
            upcomingSteepGrade = nil
            return
        }
        let mile = (navigation.guidance?.alongMeters ?? 0) / 1609.344
        let next = GradeProfile.nextSteep(after: mile, in: route.gradeProfile)
        if upcomingSteepGrade != next { upcomingSteepGrade = next }   // once per fix otherwise
    }

    // MARK: vehicle range + fuel recommendations

    /// First-launch prompt: no vehicle on file and not dismissed.
    @Published var vehicleOnboardingDismissed: Bool =
        UserDefaults.standard.bool(forKey: "flows.vehiclePromptDismissed") {
        didSet {
            UserDefaults.standard.set(vehicleOnboardingDismissed,
                                      forKey: "flows.vehiclePromptDismissed")
        }
    }
    @Published var showVehicleEditor = false
    var needsVehicleOnboarding: Bool {
        vehicle.profile == nil && !vehicleOnboardingDismissed
    }

    /// Set while range is low enough to plan a fuel stop NOW (HUD chip).
    @Published var fuelRecommendation: String?
    private var lastHabitFix: CLLocation?

    // MARK: posted speed limit (the HUD's live speed pair)

    /// The limit posted on the road being driven (mph), when OSM has one.
    @Published private(set) var postedSpeedLimitMph: Double?
    private var limitLookupTask: Task<Void, Never>?
    private var lastLimitLookup = Date.distantPast
    private var lastLimitPoint: CLLocationCoordinate2D?
    /// The maneuver step the last lookup belonged to — a new step re-checks.
    private var lastLimitStep: Int?
    /// When a REAL posted limit last landed. A limit is carried across
    /// untagged stretches so the sign does not flicker — but carried
    /// indefinitely it followed the car off a 65 mph highway onto a 25 mph
    /// side street with no tag, kept the red line at 65, and gated the
    /// speed-camera warning against a limit that no longer applied.
    private var postedLimitSetAt: Date?
    /// DOT road closures fetched for the corridor at plan time, kept for
    /// the trip. The live corridor watch used to score each sample with
    /// closureScore = 0 — it could see a tornado warning appear ahead but
    /// not a road the state had physically closed, so a plan-time Red
    /// primary went invisible the moment the driver pressed GO.
    private var tripClosures: [(lat: Double, lon: Double)] = []
    /// The live hazard feeds for the trip's corridor, clipped, taken at plan
    /// time and refreshed while driving (the fetcher caches by TTL, so a
    /// refresh is cheap). The live watch scores every sample against it.
    private var tripLive = LiveHazardSnapshot.empty
    private var tripLiveFetched = Date.distantPast
    private var tripLiveBox: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)?
    /// The reverse-geocode + work-zone lookup a corridor update spawns.
    /// Untracked, it outlived the trip and wrote a stale work-zone count
    /// over the reset on the planning screen.
    private var corridorContextTask: Task<Void, Never>?
    /// The last reverse-geocode, reused while the vehicle stays within
    /// 20 km of it: a state does not change every corridor update.
    private var lastGeocode: (position: CLLocationCoordinate2D, state: String)?
    /// Gates the per-fix corridor prune and daylight re-evaluation to real
    /// movement — both ran once a second for work that changes by the mile.
    private var lastPruneAt: CLLocationCoordinate2D?
    private var daylightEvaluatedAt: CLLocationCoordinate2D?

    /// True while the traveler is a PASSENGER (plane, bus, train) rather
    /// than driving — no speed sign for them.
    var isPassengerTransit: Bool {
        guard let mode = transitItinerary?.mode else { return false }
        return mode != "Walk + ride"
    }

    /// Refresh the posted limit as the vehicle moves onto new road. Cheap:
    /// only while driving, only every ~15 s, and only once the vehicle has
    /// actually covered ground since the last lookup.
    private func updatePostedSpeedLimit(_ fix: CLLocation) {
        guard SpeedSign.shouldShow(isNavigating: mode == .navigating,
                                   isWalking: walkingMode
                                       || navigation.route?.isWalkingEstimate == true,
                                   isPassengerTransit: isPassengerTransit) else {
            if postedSpeedLimitMph != nil { postedSpeedLimitMph = nil }
            return
        }
        // Responsive enough that the yellow and red lines are already there
        // as the driver turns onto a new road: a short block is ~80 m, so
        // waiting 150 m and 15 s meant driving a whole street unmarked.
        // Responsive when it matters, quiet when it doesn't: with NO limit
        // known, or a maneuver just taken, ask within 60 m / 8 s so a new
        // street is marked before the driver is down it. With a limit
        // already on the sign and no maneuver, the road is the same road —
        // ask again only every 400 m / 30 s. This was 60 m / 8 s always,
        // which on a highway sent ~450 queries an hour to public mirrors
        // to be told the same number.
        let settled = postedSpeedLimitMph != nil
        let moved = lastLimitPoint.map {
            POIRanking.meters($0, fix.coordinate) > (settled ? 400 : 60)
        } ?? true
        let stale = Date().timeIntervalSince(lastLimitLookup) > (settled ? 30 : 8)
        // A brand-new maneuver means a new road is imminent — look again
        // even if the vehicle has barely moved since the last check.
        let newStep = navigation.guidance?.stepIndex != lastLimitStep
        guard (moved && stale) || newStep else { return }
        lastLimitStep = navigation.guidance?.stepIndex
        lastLimitLookup = Date()
        lastLimitPoint = fix.coordinate
        let point = fix.coordinate
        let stepChanged = newStep
        limitLookupTask?.cancel()
        limitLookupTask = Task { [weak self] in
            let limit = await LiveHazardFeedFetcher.shared.postedLimitMph(at: point)
            guard let self, !Task.isCancelled, self.mode == .navigating else { return }
            if let limit {
                if self.postedSpeedLimitMph != limit { self.postedSpeedLimitMph = limit }
                self.postedLimitSetAt = Date()
                return
            }
            // No tag here. Keep the last known limit across a short unmapped
            // block so the sign does not flicker — but not past a maneuver
            // onto a new road, and not past 90 s: by then it is a different
            // road's number.
            let carriedTooLong = self.postedLimitSetAt.map {
                Date().timeIntervalSince($0) > 90 } ?? true
            if stepChanged || carriedTooLong {
                self.postedSpeedLimitMph = nil
                self.postedLimitSetAt = nil
            }
        }
    }

    // MARK: fixed enforcement cameras on the road ahead

    /// Automated speed and red-light cameras near the vehicle — drawn on the
    /// map, and called out on the approach.
    @Published private(set) var enforcementCameras: [EnforcementCameras.Camera] = []
    /// The one to warn about right now, with how far off it is.
    @Published private(set) var cameraWarning: String?
    private var cameraLookupTask: Task<Void, Never>?
    private var lastCameraLookup: CLLocationCoordinate2D?
    /// Cameras already spoken for, so a slow approach isn't announced twice.
    /// Bounded: a cross-country drive passes hundreds, and a set that only
    /// ever grows is a slow leak. Cameras are fixed, so the oldest entries
    /// are also the furthest behind and the safest to forget.
    private var announcedCameras: [String] = []
    private static let announcedCameraMemory = 200

    /// Refresh the camera list as the vehicle moves into new ground, and
    /// keep the live warning in step with every fix.
    private func updateEnforcementCameras(_ fix: CLLocation) {
        guard mode == .navigating, !walkingMode, !isPassengerTransit else {
            if !enforcementCameras.isEmpty { enforcementCameras = [] }
            if cameraWarning != nil { cameraWarning = nil }
            return
        }
        // A 4 km fetch re-run every 2 km always has ground ahead of it.
        let moved = lastCameraLookup.map {
            POIRanking.meters($0, fix.coordinate) > 2_000
        } ?? true
        if moved {
            lastCameraLookup = fix.coordinate
            let point = fix.coordinate
            cameraLookupTask?.cancel()
            cameraLookupTask = Task { [weak self] in
                let found = await LiveHazardFeedFetcher.shared
                    .enforcementCameras(near: point)
                guard let self, !Task.isCancelled, self.mode == .navigating,
                      let found else { return }
                if self.enforcementCameras != found { self.enforcementCameras = found }
            }
        }
        let heading = fix.course >= 0 ? fix.course : nil
        guard let next = EnforcementCameras.imminent(among: enforcementCameras,
                                                     at: fix.coordinate,
                                                     headingDegrees: heading) else {
            if cameraWarning != nil { cameraWarning = nil }
            return
        }
        let mph = max(fix.speed, 0) * 2.236936
        let text = EnforcementCameras.warning(
            for: next.camera, meters: next.meters,
            speedMph: mph, postedLimitMph: postedSpeedLimitMph)
        if text != cameraWarning { cameraWarning = text }   // not a 1 Hz publish
        // Say it once per camera, and only when the driver is actually over
        // the limit it enforces — a camera you are already legal for is a
        // map icon, not an interruption.
        let limit = next.camera.limitMph ?? postedSpeedLimitMph
        if let limit, mph > limit + SpeedLaw.stateToleranceMph,
           !announcedCameras.contains(next.camera.id) {
            announcedCameras.append(next.camera.id)
            if announcedCameras.count > Self.announcedCameraMemory {
                announcedCameras.removeFirst(
                    announcedCameras.count - Self.announcedCameraMemory)
            }
            // The tap is the hearing-parity half, voice or not; the voice
            // follows its own switch (off = the chip alone).
            if hapticAlerts { Haptics.warning() }
            // Forced: every camera is a fresh trigger (announcedCameras keeps
            // it to once each), and the repeat guard left the second speed
            // camera of a trip unspoken.
            if voiceAlerts {
                DriveVoice.shared.speak(next.camera.kind.title + " ahead", force: true)
            }
        }
    }

    // MARK: lane-level guidance for the upcoming maneuver

    /// The tagged lanes on the approach to the next maneuver, left to right
    /// (OSM turn:lanes via Overpass). Empty when the road isn't tagged.
    @Published private(set) var upcomingLanes: [LaneData.Lane] = []
    private var laneLookupTask: Task<Void, Never>?
    private var laneLookupStep = -1
    /// The maneuver a lane query is already out for, so the 1 Hz tick does
    /// not fire a second one at the same turn.
    private var laneLookupStepInFlight = -1

    /// Fetch lanes once per maneuver, and only when one is close enough to
    /// matter — lane guidance three miles out is noise, and the tagging is
    /// per-approach anyway.
    private func updateUpcomingLanes() {
        guard mode == .navigating, !walkingMode, !isPassengerTransit,
              let g = navigation.guidance else {
            if !upcomingLanes.isEmpty { upcomingLanes = [] }
            laneLookupStep = -1
            laneLookupStepInFlight = -1
            return
        }
        // A new maneuver resets the row; the same one isn't re-fetched.
        if g.stepIndex != laneLookupStep {
            laneLookupStep = g.stepIndex
            if !upcomingLanes.isEmpty { upcomingLanes = [] }
        }
        // One lookup per maneuver. This ran on EVERY fix while the row was
        // still empty, cancelling the previous query and starting another —
        // and at 60 mph the Overpass round trip never fit inside a second,
        // so the lookup was killed and restarted the whole way in, and lane
        // guidance never appeared at all.
        guard upcomingLanes.isEmpty, g.stepIndex != laneLookupStepInFlight,
              g.distanceToManeuver < 1_600,
              let point = navigation.coordinateAhead(meters: g.distanceToManeuver)
        else { return }
        let step = g.stepIndex
        laneLookupStepInFlight = step
        laneLookupTask = Task { [weak self] in
            let lanes = await LiveHazardFeedFetcher.shared.turnLanes(at: point)
            guard let self, !Task.isCancelled, self.mode == .navigating,
                  self.navigation.guidance?.stepIndex == step else { return }
            if self.upcomingLanes != lanes { self.upcomingLanes = lanes }
        }
    }

    // MARK: recent speed (crash corroboration)

    /// Speeds from the last ~10 s of fixes (m/s) — the "was this vehicle
    /// actually traveling before the bang?" half of the crash decision.
    private var recentSpeeds: [(time: Date, mps: Double)] = []
    /// Fastest the vehicle went in that window.
    var recentPeakSpeedMps: Double {
        recentSpeeds.map(\.mps).max() ?? 0
    }

    private func recordSpeed(_ fix: CLLocation) {
        let now = fix.timestamp
        recentSpeeds.append((now, max(fix.speed, 0)))
        recentSpeeds.removeAll { now.timeIntervalSince($0.time) > 10 }
    }
    private var fuelRecommendationDismissedAtRange: Double = 0

    /// Cloud fuel was read at launch and on the Refresh button only, so on
    /// the road it aged out (FuelReading.maxAgeSeconds). Every 5 minutes
    /// while navigating keeps it current, with one missed read to spare.
    private var lastCloudFuelRefresh = Date.distantPast
    private func refreshCloudFuelIfDue(now: Date = Date()) {
        guard smartcar.connected, now.timeIntervalSince(lastCloudFuelRefresh) >= 300 else { return }
        lastCloudFuelRefresh = now
        let car = smartcar
        Task { await car.refreshData() }
    }

    private func updateFuelRecommendation() {
        guard mode == .navigating, vehicle.profile != nil, notifyFuel,
              let range = vehicle.expectedRangeMiles else {
            fuelRecommendation = nil
            return
        }
        // "Next station" assumption without a live search: rural interstates
        // run ~25 mi between exits with fuel.
        let recommend = VehicleProfile.shouldRecommendFuel(
            rangeRemainingMiles: range, milesToNextStation: 25)
        if recommend, range < fuelRecommendationDismissedAtRange - 20 || fuelRecommendationDismissedAtRange == 0 {
            fuelRecommendation = String(
                format: "≈%.0f mi of range left — plan a fuel stop", range)
        } else if !recommend {
            fuelRecommendation = nil
            fuelRecommendationDismissedAtRange = 0
        }
    }

    /// Driver dismissed the fuel chip — don't nag until range drops 20 mi more.
    func dismissFuelRecommendation() {
        fuelRecommendationDismissedAtRange = vehicle.expectedRangeMiles ?? 0
        fuelRecommendation = nil
    }

    // MARK: last-chance fuel warning (reachable matching stations)

    /// The live "you are about to drive past your last fuel" state: the
    /// warning level, the cheapest reachable station selling THIS vehicle's
    /// fuel, and the text on screen. Drives the blinking gauge + the spoken
    /// advisory (FuelWarning).
    @Published private(set) var fuelWarningLevel: FuelWarning.Level = .none
    @Published private(set) var fuelWarningStation: FuelWarning.Station?
    @Published private(set) var fuelWarningText: String?
    /// The MapKit item behind `fuelWarningStation`, so "Add to route" can
    /// route to the exact place that was recommended.
    private var fuelWarningItem: MKMapItem?
    private var fuelScanTask: Task<Void, Never>?
    private var lastFuelScan = Date.distantPast
    /// Cleared when the driver dismisses; re-armed when the level worsens.
    private var dismissedFuelWarningLevel: FuelWarning.Level = .none
    /// The level the driver closed the banner at, while it stays closed —
    /// kept apart from the level last spoken above. Without it the next
    /// scan, 3 minutes on, put the same banner straight back.
    private var fuelBannerClosedAt: FuelWarning.Level?

    /// True while the driver is NEAR the line where too few stations selling
    /// their fuel remain reachable — one step before the last-chance banner.
    /// Drives the slow red tank pulse on the instrument line.
    var fuelReachabilityTight: Bool {
        if fuelWarningLevel != .none { return true }
        guard let range = vehicle.expectedRangeMiles else { return false }
        // Approaching the reserve is the same condition the reachable-station
        // count is about to collapse under.
        return range <= VehicleProfile.reserveMiles * 2
    }

    /// True while the tank is low enough that the gauge should blink red.
    var fuelGaugeAlarming: Bool {
        guard let fraction = vehicle.displayedFuelFraction else { return false }
        return FuelWarning.band(fraction: fraction) == .red
            || fuelWarningLevel != .none
    }

    /// Scan for stations selling the vehicle's fuel ahead on the route and
    /// decide whether the driver is running out of chances to stop. Runs on
    /// a slow cadence, and only once range is low enough to matter — a full
    /// tank never needs this search.
    private func updateFuelWarning() {
        guard mode == .navigating, notifyFuel,
              let profile = vehicle.profile,
              let range = vehicle.expectedRangeMiles else {
            if fuelWarningLevel != .none { clearFuelWarning() }
            return
        }
        // Only worth searching once the reachable set could plausibly be
        // thinning: within ~2.5 reserves of empty.
        let watchFrom = VehicleProfile.reserveMiles * 2.5
        guard range <= watchFrom else {
            if fuelWarningLevel != .none { clearFuelWarning() }
            return
        }
        guard Date().timeIntervalSince(lastFuelScan) > 180 else { return }
        lastFuelScan = Date()
        let fuel = profile.fuelType
        fuelScanTask?.cancel()
        fuelScanTask = Task { [weak self] in
            guard let self,
                  let found = await self.scanFuelStationsAhead(fuel: fuel, rangeMiles: range),
                  !Task.isCancelled, self.mode == .navigating else { return }
            let level = FuelWarning.level(stationsAhead: found.stations, rangeMiles: range)
            let cheapest = FuelWarning.cheapest(stationsAhead: found.stations,
                                                rangeMiles: range)
            if self.fuelWarningLevel != level { self.fuelWarningLevel = level }
            if self.fuelWarningStation != cheapest { self.fuelWarningStation = cheapest }
            self.fuelWarningItem = cheapest.flatMap { found.items[$0.name] }
            let text = FuelWarning.bannerText(
                fuel: fuel, level: level, station: cheapest)
            // A closed banner stays closed while the spot is the one it was
            // closed on; a change brings it back, as it brings the voice
            // back below (the spoken advice asks to add the stop, and the
            // banner holds the button).
            if self.fuelBannerClosedAt != level {
                self.fuelBannerClosedAt = nil
                if self.fuelWarningText != text { self.fuelWarningText = text }
            }
            // Say it once per level change — a driver shouldn't be told the
            // same thing every mile, but a worsening situation speaks again.
            if level != .none, level != self.dismissedFuelWarningLevel,
               let spoken = FuelWarning.spokenAdvice(
                   fuel: fuel, level: level, station: cheapest, rangeMiles: range) {
                // The tap lands voice or not; the voice follows its switch
                // (off = the red banner alone).
                if self.hapticAlerts { Haptics.warning() }
                if self.voiceAlerts {
                    DriveVoice.shared.speak(spoken, topic: SpeechTopic.fuelLastChance)
                }
                self.dismissedFuelWarningLevel = level
            }
        }
    }

    private func clearFuelWarning() {
        fuelScanTask?.cancel()
        fuelWarningLevel = .none
        fuelWarningStation = nil
        fuelWarningItem = nil
        fuelWarningText = nil
        dismissedFuelWarningLevel = .none
        fuelBannerClosedAt = nil
        DriveVoice.shared.cancel(topic: SpeechTopic.fuelLastChance)
        DriveVoice.shared.reset()
    }

    /// Stations ahead that sell `fuel`, with along-route distance and price
    /// where a source has one. Keyed by name so the warning can hand back
    /// the exact MKMapItem for "Add to route".
    private func scanFuelStationsAhead(fuel: FuelType, rangeMiles: Double)
        async -> (stations: [FuelWarning.Station], items: [String: MKMapItem])? {
        guard let here = effectivePosition else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = fuel.searchQuery
        // Search the span the remaining fuel can actually cover.
        let meters = max(rangeMiles, 10) * 1609.344
        request.region = MKCoordinateRegion(center: here,
                                            latitudinalMeters: meters * 2,
                                            longitudinalMeters: meters * 2)
        guard let items = (try? await MKLocalSearch(request: request).start())?.mapItems
        else { return nil }
        var stations: [FuelWarning.Station] = []
        var byName: [String: MKMapItem] = [:]
        // The road still to be driven, sampled — ahead-ness is measured
        // against this when a route exists. `ahead` used to be a plain radius
        // around the vehicle, which counted stations BEHIND it as reachable
        // and kept the last-chance warning quiet while the driver ran dry.
        let routeAhead = navigation.route.map {
            RouteService.samplePoints(of: $0.route.polyline, everyMeters: 4_000)
        } ?? []
        let course = location.course
        // Filter first, price second. This priced EVERY search hit in
        // series — a feed round-trip each — before checking whether the
        // station was even reachable, and never noticed being cancelled.
        // The warning needs the nearest few real options, not a price on
        // every pump in the county.
        let reachable = items.compactMap { item -> (item: MKMapItem, ahead: Double)? in
            let coord = item.placemark.coordinate
            let ahead = POIRanking.meters(here, coord) / 1609.344
            guard ahead <= rangeMiles,
                  FuelWarning.isReachable(station: coord, from: here,
                                          courseDegrees: course,
                                          routeAhead: routeAhead) else { return nil }
            return (item, ahead)
        }
        .sorted { $0.ahead < $1.ahead }
        .prefix(8)
        for (item, ahead) in reachable {
            if Task.isCancelled { break }
            let name = item.name ?? fuel.rawValue
            // Live station price when a feed has one, else the state
            // estimate — the same ladder the stop list uses.
            let price = await poi.livePriceProvider(item.placemark.coordinate, fuel)
                ?? poi.priceProvider(item, fuel)
            stations.append(FuelWarning.Station(name: name, milesAhead: ahead,
                                                pricePerUnit: price))
            byName[name] = item
        }
        return (stations, byName)
    }

    /// "Add it to the route" — the action the spoken advisory offers.
    func addRecommendedFuelStop() async {
        guard let item = fuelWarningItem else { return }
        await addStop(item)
        clearFuelWarning()
    }

    /// Driver dismissed the last-chance warning: stay quiet until the
    /// situation actually worsens.
    func dismissFuelWarning() {
        dismissedFuelWarningLevel = fuelWarningLevel
        fuelBannerClosedAt = fuelWarningLevel
        fuelWarningText = nil
        DriveVoice.shared.cancel(topic: SpeechTopic.fuelLastChance)
    }

    // MARK: favorites (star button → one-press route planning)

    /// One press on a favorite: plan from the current GPS fix to it and show
    /// the choices. Returns the planned routes so the caller can frame the
    /// camera (nil when planning failed or there's no position).
    /// No fix → the same start the planner falls back to (Home, or the
    /// usual area): a Mac without location showed "From: Home (no GPS)"
    /// and still refused every favorite chip.
    @discardableResult
    func planToFavorite(_ fav: FavoriteAddress) async -> [PlannedRoute]? {
        guard let start = effectivePosition.map({ (coordinate: $0, label: "Current location") })
                ?? bestKnownPosition else { return nil }
        plannerDestination = fav.name
        // Edit and plan again goes back to the saved point, not a lookup.
        plannerDestinationPick = PlannerPick(text: fav.name, coordinate: fav.coordinate,
                                             name: fav.name)
        guard let planned = try? await plan(
            from: start.coordinate, fromName: start.label,
            to: fav.coordinate, toName: fav.name), !planned.isEmpty else { return nil }
        present(routes: planned)
        return planned
    }

    /// Show freshly planned routes NOW and hydrate their weather badges in the
    /// background. Perceived planning latency is MKDirections-only (~2 s even
    /// cross-country); the corridor risk scores land a few seconds later and
    /// re-rank the list (a red corridor never outranks a clear one at ~equal
    /// ETA — same philosophy as the web app).
    private var riskHydrationTask: Task<Void, Never>?

    func present(routes: [PlannedRoute]) {
        FlowsDiag.log(.info, "plan", "presenting \(routes.count) route(s)")
        // Apply the driver's learned pace to every ETA before anything reads
        // them — so the correction reaches the cards, the cost estimates
        // derived from ETA, the ranking, AND the arrival-time reasoning that
        // decides whether a hazard will still be active on arrival. Walking
        // estimates already carry their own override and are left alone.
        routeChoices = RouteService.applyPersonalPace(
            routes, multiplier: DrivingProfileStore.shared.etaMultiplier)
        heldChoiceFeeds = [:]
        // A trip planned while another is being driven (Siri's Start a trip,
        // CarPlay's Where to) must not take the drive screen down. Choosing
        // hid the directions and the End button, and the warnings, rising-
        // risk prompts and spoken turns of the trip still being driven all
        // wait on .navigating. The choices are weather-checked behind the
        // drive screen and wait for a yes (acceptTripOffer); select() swaps
        // the trip. The transit state belongs to the trip being driven.
        if tripUnderway {
            pendingVoiceOffer = nil
            riskHydrationTask?.cancel()
            riskHydrationTask = Task { await hydrateRouteRisk() }
            return
        }
        transitItinerary = nil   // drive routes replace any transit overlay
        // A fresh plan resets the transit pickers: cancel in-flight
        // computations, drop stale option cards, untoggle rail/bus/plane.
        transitTasks.values.forEach { $0.cancel() }
        transitTasks = [:]
        transitOptions = [:]
        activeTransitModes = []
        hybridOption = nil
        touristCountTask?.cancel()   // counts belong to the routes they swept
        touristCounts = [:]
        restoreTransientPanels()   // fresh choices bring the trip menus back
        // mode BEFORE the highlight: highlightedRouteID's didSet re-searches
        // tourist stops only while .choosing, and it used to run one line
        // too early, while mode was still .planning.
        mode = .choosing
        highlightIsDriverChoice = false
        // The first route the filters leave on the list — at rush hour the
        // fastest often fails Avoid traffic, and highlighting it framed and
        // coloured a route no card showed. Nothing passing keeps the old
        // first pick until scoring settles the list.
        highlightedRouteID = filteredChoices.first?.id ?? routeChoices.first?.id
        if routeFilters.contains(.tourist) { refreshTouristCounts() }
        filterCardsHidden = false   // fresh choices bring the slider card back
        // A fresh plan invalidates any staged spoken yes. Without this, a
        // driver who asks Siri for one destination, dislikes it and plans
        // another on screen still has the FIRST offer staged — and "go
        // ahead" starts the trip they just rejected.
        pendingVoiceOffer = nil
        // Supersede any prior hydration: its retry loop reads the LIVE
        // routeChoices, so a replan while still .choosing would otherwise
        // stack a second (then third…) loop re-scoring the same routes —
        // multiplied NWS rounds against the polite-API doctrine.
        restartRiskHydration()
    }

    /// Land a finished score on its (possibly re-sorted) card. If the user
    /// already picked a route (choices cleared), the index lookup fails and
    /// the late score is dropped harmlessly. The card keeps its attributes,
    /// and an incomplete score its provisional picture — the retry pass
    /// refreshes it (PlannedRoute.landing). A cancelled pass lands nothing:
    /// the pass that superseded it scores these cards, and its cut-short
    /// fetches could land after that pass's verdict and lock GO again.
    private func landScore(_ done: PlannedRoute) {
        guard !Task.isCancelled,
              let i = routeChoices.firstIndex(where: { $0.id == done.id }) else { return }
        routeChoices[i] = done.landing(on: routeChoices[i])
    }

    /// Progress sink for one route CARD: patches the choices entry's
    /// provisional fields as alert cells land. Built by the HYDRATION layer,
    /// not by `scored` — scoring stays presentation-agnostic, and scorings
    /// with no card behind them (leg swaps, reroutes) pass no sink and skip
    /// the per-batch provisional work entirely.
    private func cardProgressSink(routeID: UUID) -> @MainActor (Double, [RiskSample?]) -> Void {
        { [weak self] fraction, partial in
            guard let self, let i = self.routeChoices.firstIndex(where: { $0.id == routeID })
            else { return }
            // Incremental across ticks: cells only ever ADD during one
            // scoring pass, so samples blended on an earlier tick keep their
            // value — only the newly landed ones run the realized-risk
            // equation (each drags a nearest-ZIP field lookup with it). This
            // sink fires per fetch batch on the main actor; re-blending the
            // whole corridor every tick was the single hottest main-thread
            // cost of a plan.
            let prior = self.routeChoices[i].provisionalSamples
            self.routeChoices[i].provisionalSamples = partial.enumerated().map { j, s in
                guard let s else { return nil }
                if j < prior.count, let done = prior[j] { return done }
                return RiskSample(
                    coordinate: s.coordinate,
                    risk: self.sampleRealizedRisk(
                        at: s.coordinate, alertEvent: s.worstEvent, alertSeverity: s.risk),
                    worstEvent: s.worstEvent, alertID: s.alertID)
            }
            self.routeChoices[i].scoringProgress = fraction
        }
    }

    /// A trip is being driven: started, not arrived, not ended.
    var tripUnderway: Bool { mode == .navigating && arrivedAt == nil }

    /// Route choices wait for a yes: on screen, or held behind the drive
    /// screen for a trip planned while another is driven.
    private var choicesOnOffer: Bool {
        mode == .choosing || (tripUnderway && !routeChoices.isEmpty)
    }

    /// Corridor feeds of choices held behind the drive screen, by route: the
    /// trip still being driven keeps scoring with its own until select()
    /// hands the chosen one's over.
    private var heldChoiceFeeds: [UUID: CorridorFeeds] = [:]

    /// A choice's weather score for its card. Held behind the drive screen
    /// there is no card to fill in as cells land, and the choice's feeds are
    /// kept for it: taking them over (as a card's scoring does) left the
    /// trip still being driven watched with another corridor's closures
    /// and fires.
    private func scoredChoice(_ route: PlannedRoute) async -> PlannedRoute {
        guard tripUnderway else {
            return await scored(route, onProgress: cardProgressSink(routeID: route.id))
        }
        let (done, feeds) = await scoredWithFeeds(route)
        heldChoiceFeeds[route.id] = feeds
        return done
    }

    /// What a yes to a voice-planned trip came to.
    enum TripOfferAnswer {
        /// On the way (GO pressed by voice).
        case started(name: String)
        /// Its weather check hasn't finished: GO waits for it, so a yes does.
        case stillChecking
        /// It no longer fits the driver's filters (its weather check can fail
        /// one the plan couldn't): this one is offered instead, not started.
        case changed(to: PlannedRoute)
        /// Nothing was offered.
        case nothing
    }

    /// The route a spoken yes should take: the one the choices list leads
    /// with (the first to pass every filter), else its closest match — a
    /// route the driver could have picked on screen. Judged as the cards are:
    /// on foot the raw filters picked a walk other than the list's.
    private var tripOfferPick: PlannedRoute? {
        filteredChoices.first
            ?? RouteFilter.closestMatch(in: routeChoices, filters: judgingFilters,
                                        limits: filterLimits)
    }

    /// Stage the planned trip for a spoken yes (Siri's Start a trip,
    /// CarPlay's Where to) and hand back the route staged. It used to be the
    /// fastest route whatever the filters: a towing driver's yes started a
    /// route the list hid.
    @discardableResult
    func stageTripOffer(name: String) -> PlannedRoute? {
        guard let pick = tripOfferPick else { return nil }
        pendingVoiceOffer = .trip(route: pick, name: name)
        return pick
    }

    /// A yes to the staged trip ("go ahead", CarPlay's Go). Re-resolved
    /// against the live list: the staged copy is a snapshot taken before
    /// scoring finished. The spoken yes honours the GO button's gate (the
    /// weather checked) and the list's filters; a route that no longer fits
    /// is swapped for the one that does, offered and not started. Nothing
    /// starts once its list is gone (Edit, or a trip taken on screen): the
    /// snapshot is a plan the driver left, made from where they were then.
    func acceptTripOffer() -> TripOfferAnswer {
        guard case .trip(let staged, let name)? = pendingVoiceOffer else { return .nothing }
        guard let live = routeChoices.first(where: { $0.id == staged.id }) else {
            pendingVoiceOffer = nil
            return .nothing
        }
        guard live.weatherScored else {
            // A check that gave up is started again, so "ask me again in a
            // moment" has a check running to wait on; mid-drive nothing
            // else would ever score it, and every yes said Still checking.
            if weatherCheckGaveUp.contains(live.id) { retryWeatherCheck() }
            return .stillChecking
        }
        if let pick = tripOfferPick, pick.id != live.id,
           !filteredChoices.contains(where: { $0.id == live.id }) {
            pendingVoiceOffer = .trip(route: pick, name: name)
            return .changed(to: pick)
        }
        pendingVoiceOffer = nil
        select(route: live)
        return .started(name: name)
    }

    /// A no to the staged trip: nothing waits for a yes, and choices held
    /// behind the drive screen go.
    func declineTripOffer() {
        if case .trip? = pendingVoiceOffer { pendingVoiceOffer = nil }
        guard tripUnderway else { return }
        weatherRetryTask?.cancel()
        riskHydrationTask?.cancel()
        routeChoices = []
        heldChoiceFeeds = [:]
    }

    /// Weather checks the retry ladder gave up on: those cards say so and
    /// offer Try again instead of a spinner that never stops (GO stays
    /// locked). Cleared whenever a scoring pass starts.
    @Published private(set) var weatherCheckGaveUp: Set<UUID> = []

    /// A card's Try again: re-score only the routes still unchecked — a
    /// re-score of a checked one on a bad connection could take its
    /// verdict away — with a fresh retry ladder. In its own task, weather
    /// only: the button shows just as riskHydrationTask starts the bridge
    /// and hill checks, and cancelling them there landed every route's as
    /// "no map data", marked done and never fetched again.
    func retryWeatherCheck() {
        weatherRetryTask?.cancel()
        weatherRetryTask = Task { await scoreRouteWeather(onlyUnscored: true) }
    }
    private var weatherRetryTask: Task<Void, Never>?

    /// A fresh scoring pass over every card, superseding the one still
    /// running and any Try again.
    private func restartRiskHydration() {
        weatherRetryTask?.cancel()
        riskHydrationTask?.cancel()
        riskHydrationTask = Task { await hydrateRouteRisk() }
    }

    private func hydrateRouteRisk() async {
        await scoreRouteWeather(onlyUnscored: false)
        // PHASE 2 — physical attributes (grades / clearances / FEMA / EV
        // gaps): slow public fetches that hydrate AFTER the safety verdict.
        // Runs even if the driver already hit GO — the finished attributes
        // patch the live leg instead of the (cleared) choice cards.
        let pending = routeChoices.isEmpty
            ? [navigation.route].compactMap { $0 } : routeChoices
        await withTaskGroup(of: Void.self) { group in
            for r in pending {
                group.addTask { await self.hydrateAttributes(r) }
            }
        }
    }

    /// PHASE 1 — the weather verdict GO waits on, then the retry ladder for
    /// the routes whose fetches came back incomplete.
    private func scoreRouteWeather(onlyUnscored: Bool) async {
        weatherCheckGaveUp = []
        // The driver just asked for these routes and is watching the cards —
        // the whole phase-1 pass rides the planning-burst lane (elevated
        // in-flight ceiling, same bounded request set).
        await RequestGate.shared.withPlanningBurst {
            let targets = onlyUnscored
                ? self.routeChoices.filter { !$0.weatherScored } : self.routeChoices
            // FASTEST ROUTE FIRST: routeChoices arrive ETA-sorted, so the top
            // card — the one most drivers take — gets the entire burst lane to
            // itself and its GO unlocks in a few seconds; the alternates then
            // score concurrently, and cheaper than they look (they share most
            // of their corridor cells with the leader through the TTL cache).
            // scoredChoice: a card fills in as its cells land; choices held
            // behind the drive screen keep their feeds for themselves.
            let leadID = targets.first?.id
            if let lead = targets.first {
                self.landScore(await self.scoredChoice(lead))
            }
            await withTaskGroup(of: PlannedRoute.self) { group in
                for r in targets where r.id != leadID {
                    group.addTask { await self.scoredChoice(r) }
                }
                for await done in group { self.landScore(done) }
            }
        }
        if choicesOnOffer {
            routeChoices.sort {
                // Near-equal ETA → prefer the lower balanced risk (band + identified
                // ZIP exposure), not the band alone.
                // Rank on the LEARNED time, not the router's raw estimate:
                // a corridor this device has repeatedly found slow at this
                // hour should stop winning on paper. Near-equal is
                // PROPORTIONAL to the trip (RouteService.etaTieTolerance) —
                // a flat five minutes meant safety could never win a short
                // trip and almost always won a long one.
                let (a, b) = (self.learnedETA(for: $0), self.learnedETA(for: $1))
                let tolerance = RouteService.etaTieTolerance(
                    shorterETA: Swift.min(a, b))
                if abs(a - b) < tolerance { return $0.rankingRisk < $1.rankingRisk }
                return a < b
            }
            ensureHighlightValid()
            // Retry routes whose weather fetches came back incomplete (NWS
            // hiccup) so GO can unlock with real data instead of a false
            // green. Persistent with backoff — a single 6 s retry died inside
            // the host breaker's 120 s cooldown and left cards spinning
            // forever; this outlives one full breaker window.
            for delay in [6.0, 15, 15, 30, 30, 60] {
                let incomplete = routeChoices.filter { !$0.weatherScored }
                guard !incomplete.isEmpty, choicesOnOffer, !Task.isCancelled else { break }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { break }
                // Burst only around the re-scoring itself, never across the
                // backoff sleeps — the elevated ceiling is for active,
                // user-blocking work.
                await RequestGate.shared.withPlanningBurst {
                    for r in incomplete where self.choicesOnOffer {
                        self.landScore(await self.scoredChoice(r))
                    }
                }
                // A late score can hide the highlighted route (No flood
                // risk, say): the map must not keep drawing a hidden card.
                if choicesOnOffer { ensureHighlightValid() }
            }
            // The ladder is spent: the cards still unchecked say so, and
            // choices held behind the drive screen remember it for the next
            // yes (acceptTripOffer), which has no card to press Try again on.
            if choicesOnOffer, !Task.isCancelled {
                weatherCheckGaveUp = Set(routeChoices.filter { !$0.weatherScored }.map(\.id))
            }
        }
    }

    /// Ids with an attribute pass currently in flight — startLeg and the
    /// phase-2 hydration can race to hydrate the same route; first one wins.
    private var attributeHydrationInFlight: Set<UUID> = []

    /// Attribute-hydrate one route (grades / clearances / FEMA / EV gaps)
    /// and land the result wherever the route now lives: its choice card,
    /// or the active leg if the driver already hit GO.
    private func hydrateAttributes(_ leg: PlannedRoute) async {
        guard !leg.attributesScored,
              attributeHydrationInFlight.insert(leg.id).inserted else { return }
        defer { attributeHydrationInFlight.remove(leg.id) }
        let done = await attributeScored(leg)
        if let i = routeChoices.firstIndex(where: { $0.id == done.id }) {
            // Only the attributes here too: a Try again may have landed the
            // card's weather since `leg` was copied.
            routeChoices[i].takeAttributes(from: done)
            // A low bridge or a steep grade found now can hide the
            // highlighted card: the highlight moves to one still listed.
            ensureHighlightValid()
        } else if var live = navigation.route, live.id == done.id {
            // Only the attributes: the live leg may have been scored (the
            // off-route replan) or repainted by the corridor watch since
            // `leg` was copied, and writing `done` whole put that back.
            live.takeAttributes(from: done)
            navigation.updateRouteMetadata(live)
        }
    }

    /// Keep the map's highlighted route consistent with the (filtered) list:
    /// a route the driver tapped stays while it is listed; otherwise the
    /// highlight is the top card.
    func ensureHighlightValid() {
        let visible = filteredChoices
        if highlightIsDriverChoice, let hl = highlightedRouteID,
           visible.contains(where: { $0.id == hl }) { return }
        highlightIsDriverChoice = false
        if highlightedRouteID != visible.first?.id { highlightedRouteID = visible.first?.id }
    }

    /// Full FLOWS scoring for ONE route — alerts, field blend, segments,
    /// summary numbers. Used by the choices hydration AND by every leg swap
    /// (added stop, escalation reroute, resume-to-destination) so the nav map
    /// never loses its risk coloring.
    /// One corridor sample's REALIZED risk, computed exactly like the map's
    /// per-point band (`RiskEquations.realizedRisk`): the modeled ZIP field and
    /// the on-device forecast are PREDICTORS (never proof); an in-progress-danger
    /// NWS alert (classified by `alertFamily`) is the realized primary that can
    /// reach Red. Watches / advisories / condition warnings stay capped
    /// predictors — so a Winter Storm Warning can't red-out a route any more than
    /// it can the map. Shared by route planning and live corridor monitoring so
    /// every surface bands identically.
    private func sampleRealizedRisk(
        at c: CLLocationCoordinate2D, alertEvent: String?, alertSeverity: Double,
        onDevice: [String: Double] = [:], floodMultiplier: Double = 1,
        closureScore: Double = 0,
        live: [String: Double] = [:],
        fieldRow: [Double]? = nil
    ) -> Double {
        // ONE nearest-ZIP resolution for all families at this coordinate —
        // per-family score() calls redid the same neighborhood scan 8×. A
        // caller that has already resolved the row (the plan-time blend
        // loop does, for its own purposes) passes it in.
        let row = fieldRow ?? riskField.scoreRow(at: c)
        func field(_ fam: String) -> Double {
            guard let row, let fi = riskField.familyIndex(fam), fi < row.count else { return 0 }
            return row[fi]
        }
        // The assembly itself is RiskEquations.bandInput — Core, tested.
        return RiskEquations.realizedRisk(RiskEquations.bandInput(
            field: field, onDevice: onDevice,
            alertEvent: alertEvent, alertSeverity: alertSeverity,
            floodMultiplier: floodMultiplier, closureScore: closureScore, live: live))
    }

    /// ON-DEVICE R equations, CONUS-wide: NWS gridpoint forecasts at every
    /// other corridor sample (capped), scored with the EXACT ported equations
    /// (RiskEquations ← R/scoring.R + R/forecast.R). Where the richer WI
    /// engine export exists, the max of the two applies — so coverage is no
    /// longer Wisconsin-only. Conditions AND elevation per sample: the
    /// latitude-band profile can shift ±1 band on elevation (contiguous
    /// rule), so mountain samples normalize against their climatically-
    /// correct band. Keyed by SAMPLE INDEX into `samples`. Split from
    /// `scored` so these fetches overlap the alert-cell pass. At most 15, at
    /// every other sample of the first 30: a road weighed with closer check
    /// points keeps to 30 of them (Rust `DETOUR_CHECK_POINTS_MAX`) so each
    /// stays within reach of one.
    nonisolated private static func corridorForecasts(
        at samples: [CLLocationCoordinate2D]
    ) async -> [Int: (ForecastConditions, Double?)] {
        let idx = Array(stride(from: 0, to: samples.count, by: 2).prefix(15))
        // Elevations ride ONE batched request for all forecast samples,
        // concurrent with the per-point conditions fetches.
        async let elevsF = RouteAttributeFetcher.shared.elevations(at: idx.map { samples[$0] })
        let conditions: [Int: ForecastConditions] = await withTaskGroup(
            of: (Int, ForecastConditions?).self
        ) { group in
            for i in idx {
                let pt = samples[i]
                group.addTask { (i, await NWSForecastFetcher.shared.conditions(at: pt)) }
            }
            var out: [Int: ForecastConditions] = [:]
            for await (i, c) in group { if let c { out[i] = c } }
            return out
        }
        let elevs = await elevsF
        var out: [Int: (ForecastConditions, Double?)] = [:]
        for (k, i) in idx.enumerated() {
            if let c = conditions[i] { out[i] = (c, elevs[k]) }
        }
        return out
    }

    /// `scored` on the planning-burst lane: for the single-route scorings a
    /// driver actively waits on (escalation/traffic reroutes, resuming after
    /// a stop). Background scorings (the continuation leg planned while the
    /// driver is still en route to a stop) call `scored` directly and stay at
    /// the background ceiling. No progress sink: these routes have no card.
    private func scoredBurst(_ input: PlannedRoute,
                             adoptTripFeeds: Bool = true) async -> PlannedRoute {
        await RequestGate.shared.withPlanningBurst {
            await self.scored(input, adoptTripFeeds: adoptTripFeeds)
        }
    }

    /// `onProgress` (optional): per-batch provisional updates, supplied by
    /// the hydration layer for routes with a visible card. Progressive
    /// display: as alert cells land, the card colors the resolved share of
    /// the corridor instead of spinning until the last cell — each landed
    /// sample runs through the SAME realized-risk equation as the final pass
    /// (field predictors + capped alert), so the provisional band can't
    /// red-out on a watch the final pass would cap. GO still waits for the
    /// complete verdict.
    ///
    /// `adoptTripFeeds`: whether this corridor's closures and live feeds
    /// become the TRIP's (what the live watch scores with). False for a
    /// scoring that must not take them over — the off-route replan to an
    /// added stop, whose small box would otherwise replace the continuation
    /// leg's for the rest of the trip.
    private func scored(
        _ input: PlannedRoute,
        adoptTripFeeds: Bool = true,
        onProgress: (@MainActor (Double, [RiskSample?]) -> Void)? = nil
    ) async -> PlannedRoute {
        let (route, feeds) = await scoredWithFeeds(input, onProgress: onProgress)
        if adoptTripFeeds { adoptCorridorFeeds(feeds) }
        return route
    }

    /// A corridor's road closures and live feeds, fetched by a scoring pass.
    private struct CorridorFeeds {
        let closures: [(lat: Double, lon: Double)]
        let live: LiveHazardSnapshot
        let box: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)
    }

    /// Make a scored corridor's feeds the trip's: what the live watch scores
    /// the road ahead with.
    private func adoptCorridorFeeds(_ feeds: CorridorFeeds) {
        tripClosures = feeds.closures
        tripLive = feeds.live
        tripLiveFetched = Date()
        tripLiveBox = feeds.box
    }

    /// `scored`, handing back the corridor's feeds instead of adopting them:
    /// a road that may not be taken (a faster road FLOWS is weighing) must
    /// not replace the trip's.
    ///
    /// `everyMeters`: the check-point spacing. A road only weighed (a detour
    /// FLOWS compares) may be scored closer; a road that is driven keeps the
    /// usual 40 km, which the corridor watch and the attribute pass index by.
    private func scoredWithFeeds(
        _ input: PlannedRoute,
        everyMeters: CLLocationDistance = FasterRoutePolicy.corridorCheckMeters,
        onProgress: (@MainActor (Double, [RiskSample?]) -> Void)? = nil
    ) async -> (route: PlannedRoute, feeds: CorridorFeeds) {
        var r = input
        // Partition once: boundaries feed the weather scorer, the
        // between-boundary runs become map-drawable segments.
        let part = RouteService.corridorPartition(of: r.route.polyline, everyMeters: everyMeters)

        // Corridor bbox for the flood-evidence fetches.
        let sampleLats = part.samples.map(\.latitude)
        let sampleLons = part.samples.map(\.longitude)
        let bbox = (minLat: (sampleLats.min() ?? 0) - 0.05, minLon: (sampleLons.min() ?? 0) - 0.05,
                    maxLat: (sampleLats.max() ?? 0) + 0.05, maxLon: (sampleLons.max() ?? 0) + 0.05)

        // The alert-cell pass, the forecast/elevation pairs, and the
        // closure/gauge feeds are independent — they need only the sample
        // coordinates — so they run CONCURRENTLY through the gate. Running
        // them back-to-back serialized the two biggest request phases and
        // roughly doubled the time to the card's verdict on cellular.
        // Time-aware: sample i is reached ~(eta * i / n) after departure —
        // alerts that expire before then don't count there.
        let eta = r.eta
        // Check points closer than an alert cell each look their alerts up at
        // their own point: a detour a few km off the road shares the road's
        // cells, and the cell's lookup point sits on the road.
        async let scoreF = alerts.corridorRisk(
            at: part.samples,
            arrivalOffsets: RiskTiming.arrivalOffsets(
                sampleCount: part.samples.count, totalTravelSeconds: eta),
            perSample: everyMeters < FasterRoutePolicy.corridorCheckMeters,
            onProgress: onProgress)
        async let onDeviceF = Self.corridorForecasts(at: part.samples)
        // DOT closures along the corridor (WZDx): realized blocked-road proof.
        async let closuresF = LiveHazardFeedFetcher.shared.roadClosures(
            minLat: bbox.minLat, minLon: bbox.minLon, maxLat: bbox.maxLat, maxLon: bbox.maxLon)
        // FLOOD SUPPORTING EVIDENCE — the topographic analysis the waterline
        // model gates on (a road between local min and max floods only WITH
        // evidence): live river GAUGES at/above flood stage (was map-only; now
        // scored on the route), and USGS NHD RIVER/LAKE proximity (the rivers &
        // lakes piece that was missing). FEMA A/V zones remain the route filter.
        async let gaugesF = LiveHazardFeedFetcher.shared.floodGauges(
            minLat: bbox.minLat, minLon: bbox.minLon, maxLat: bbox.maxLat, maxLon: bbox.maxLon)
        // The same live feeds the map sweep scores with, clipped to the route.
        async let liveF = LiveHazardFeedFetcher.shared.liveSnapshot(
            minLat: bbox.minLat, minLon: bbox.minLon, maxLat: bbox.maxLat, maxLon: bbox.maxLon)

        let score = await scoreF
        let onDevice = await onDeviceF

        // Blend alert severity with the R engine's continuous ZIP
        // environmental field (noisy-OR, per sample) — this is what makes the
        // route colored PHYSICALLY where the risk is, even where no alert
        // polygon is active. Track per-family peaks along the way
        // (wind/flood/… power the route filters).
        var peaks: [String: Double] = [:]
        let filterFamilies = ["wind", "qpf_flood", "winter", "convective"]
        func nearestOnDevice(_ i: Int) -> (ForecastConditions, Double?)? {
            // Nearest fetched sample (they're every other one).
            let candidates = [i, i - 1, i + 1, i - 2, i + 2].filter { onDevice[$0] != nil }
            return candidates.first.flatMap { onDevice[$0] }
        }
        func onDevicePredictors(near i: Int) -> [String: Double] {
            let candidates = [i, i - 1, i + 1, i - 2, i + 2].filter { onDevice[$0] != nil }
            guard let j = candidates.first, let (c, elev) = onDevice[j] else { return [:] }
            let coord = score.samples[j].coordinate
            return c.predictorFamilies(latitude: coord.latitude, longitude: coord.longitude,
                                       elevationMeters: elev)
        }

        // Rain-gate: water-proximity evidence only matters when the corridor
        // has forecast rain (the multiplier ignores evidence at qpf 0) — a dry
        // day skips the NHD queries entirely.
        let anyRain = onDevice.values.contains { ($0.0.qpfInches ?? 0) > 0 }
        let waterProbe = anyRain
            ? stride(from: 0, to: score.samples.count,
                     by: max(score.samples.count / 12, 1))
                .map { score.samples[$0].coordinate }
            : []
        async let waterF = LiveHazardFeedFetcher.shared.waterProximity(near: waterProbe)
        let corridorClosures = await closuresF
        let corridorLive = await liveF
        // The live watch reads these once the caller adopts them.
        let feeds = CorridorFeeds(closures: corridorClosures, live: corridorLive, box: bbox)
        let corridorGauges = await gaugesF
        let corridorWater = await waterF

        // WINDOWED local minimum elevation: the nearby pooling low, NOT the
        // corridor-global low (which on a long/mountain route sits hundreds of
        // km away and breaks "local minimum waterline"). Min over the fetched
        // elevations within ±4 samples of the query point.
        let elevBySample: [Int: Double?] = onDevice.mapValues(\.1)
        func localMinElevation(near i: Int) -> Double? {
            var lo: Double?
            for j in max(i - 4, 0)...min(i + 4, max(score.samples.count - 1, 0)) {
                if let e = elevBySample[j] ?? nil { lo = lo.map { Swift.min($0, e) } ?? e }
            }
            return lo
        }

        // Family indices are loop-invariant — resolve once, not per sample.
        let envIdx = riskField.familyIndex("environmental")
        let filterIdx = filterFamilies.map { ($0, riskField.familyIndex($0)) }
        var identifiedSum = 0.0
        // The gauges, mapped water and closures are the same at every sample:
        // lay them out for the Rust scorers once per route, not per sample.
        let preparedGauges = HazardFeedScores.PreparedGauges(corridorGauges)
        let preparedWater = HazardFeedScores.PreparedPoints(corridorWater)
        let preparedClosures = HazardFeedScores.PreparedPoints(corridorClosures)
        // This loop is synchronous on the main actor — the journal says how
        // long, so a planning stall can be attributed or ruled out.
        let blendStart = Date()
        let blended = score.samples.enumerated().map { i, s -> RiskSample in
            let c = s.coordinate
            let dev = onDevicePredictors(near: i)
            let near = nearestOnDevice(i)
            // One nearest-ZIP row per sample, shared by the filter peaks and
            // the identified-exposure accumulation below (score(family:at:)
            // per family redid the same neighborhood scan).
            let row = riskField.scoreRow(at: c)
            func rowScore(_ fi: Int?) -> Double {
                guard let row, let fi, fi < row.count else { return 0 }
                return row[fi]
            }
            identifiedSum += rowScore(envIdx)
            // Evidence gate = noisy-OR of a gauge in flood and mapped water near.
            let gaugeEvid = HazardFeedScores.floodGaugeScore(prepared: preparedGauges, at: c)
            let waterEvid = HazardFeedScores.waterProximityScore(prepared: preparedWater, at: c)
            let floodEvidence = 1 - (1 - gaugeEvid) * (1 - waterEvid)
            let floodMult = RiskEquations.floodElevationMultiplier(
                sampleElevation: near?.1, localMinElevation: localMinElevation(near: i),
                qpfInches: near?.0.qpfInches, supportingEvidence: floodEvidence)
            // Route filters track per-family peaks (display): worse of the ZIP
            // export and the on-device forecast decomposition.
            for (fam, fi) in filterIdx {
                let deviceKey = fam == "qpf_flood" ? "precip" : fam
                let v = max(rowScore(fi), dev[deviceKey] ?? 0)
                if v > (peaks[fam] ?? 0) { peaks[fam] = v }
            }
            // SAME logic as the map: field + forecast are PREDICTORS (never
            // proof); the only realized primary the route has today is an
            // in-progress-danger ALERT (classified by RiskEquations.alertFamily).
            // Live feeds: a fire perimeter or a fresh epicentre on the route
            // is a realized primary here exactly as it is on the map, and its
            // peak reaches the route card so the card can name it.
            let live = HazardFeedScores.live(at: c, snapshot: corridorLive).bandInputContribution
            for (fam, v) in live where v > (peaks[fam] ?? 0) { peaks[fam] = v }
            return RiskSample(
                coordinate: c,
                risk: sampleRealizedRisk(
                    at: c, alertEvent: s.worstEvent, alertSeverity: s.risk,
                    onDevice: dev, floodMultiplier: floodMult,
                    closureScore: HazardFeedScores.closureScore(
                        prepared: preparedClosures, at: c),
                    live: live,
                    fieldRow: row),   // resolved above; not a second ZIP scan
                worstEvent: s.worstEvent, alertID: s.alertID)
        }
        FlowsDiag.log(.info, "plan", String(format: "scored %d samples in %.0f ms",
                                            score.samples.count,
                                            Date().timeIntervalSince(blendStart) * 1000))
        r.familyPeaks = peaks
        r.alertCoverage = score.coverage
        r.alertHeadlines = score.headlines
        r.alertEvents = score.events
        r.alertPolygons = score.alertPolygons
        r.riskSamples = blended

        // Segment i spans samples i → i+1; stroke it as the worse end.
        var milesPerBand: [RiskBand: Double] = [:]
        r.riskSegments = part.segments.enumerated().map { j, coords in
            let a = blended.indices.contains(j) ? blended[j].risk : 0
            let b = blended.indices.contains(j + 1) ? blended[j + 1].risk : 0
            let risk = max(a, b)
            let meters = Self.pathLength(coords)
            milesPerBand[FlowsCore.riskBand(score: risk), default: 0] += meters / 1609.344
            return RiskSegment(coordinates: coords, risk: risk, lengthMeters: meters)
        }

        // R-parity summary numbers (build_route_summary): peak, avg,
        // exposure miles per band, normalized route risk.
        let risks = blended.map(\.risk)
        let peak = risks.max() ?? 0
        let avg = risks.isEmpty ? 0 : risks.reduce(0, +) / Double(risks.count)
        r.peakRisk = peak
        r.avgRisk = avg
        r.milesByBand = [RiskBand.red, .yellow, .green].compactMap {
            guard let m = milesPerBand[$0], m >= 0.5 else { return nil }
            return ($0, m)
        }
        // Route-level DISPLAY band is DISTANCE-WEIGHTED: what fraction of the
        // miles you drive sits at what risk. The old peak⊕avg blend painted a
        // route "overall yellow" when yellow was a minority stretch — the
        // worst SECTION is real information, but it lives in peakRisk (risk
        // strip + key points + escalation), not in the whole-route label.
        let totalLen = r.riskSegments.reduce(0.0) { $0 + $1.lengthMeters }
        let weighted = totalLen > 0
            ? r.riskSegments.reduce(0.0) { $0 + $1.risk * $1.lengthMeters } / totalLen
            : avg
        // …except that a RED peak is a floor, not something to average away.
        // See RouteRiskBand: a tornado warning across the corridor is the
        // same hazard whether you drive it or walk it, and averaging let the
        // two modes disagree about the same ground.
        r.weatherRisk = RouteRiskBand.displayed(weighted: weighted, peak: peak)

        // Second truth for RANKING (not the display band): sustained exposure to
        // the ZIP's IDENTIFIED risk — the R engine's modeled field, later refined
        // by the on-device seasonal prior. A ZIP can carry known risk before any
        // alert, and an alert can fire without prior ZIP risk; both are evidence.
        // (Accumulated in the blended pass above — same row lookup.)
        r.zipExposure = score.samples.isEmpty ? 0 : identifiedSum / Double(score.samples.count)
        // On-device seasonal prior for THIS origin→dest at this week-of-year —
        // the learned "third truth" that takes over from the modeled field as it
        // accrues confidence on the driver's frequent routes.
        var prior: (risk: Double, confidence: Double) = (0, 0)
        if let o = score.samples.first?.coordinate, let d = score.samples.last?.coordinate {
            prior = SeasonalRiskModel.shared.priorForRanking(origin: o, dest: d)
        }
        r.rankingRisk = RiskEquations.rankingRisk(
            band: r.weatherRisk, zipExposure: r.zipExposure,
            seasonalPrior: prior.risk, priorConfidence: prior.confidence)

        // The web app's summary_reason analog: hazard descriptions of the
        // riskiest ZIPs the corridor crosses (top 2, worst first).
        var summaries: [String] = []
        for s in blended.sorted(by: { $0.risk > $1.risk })
        where s.risk >= FlowsCore.riskGreenMin && summaries.count < 2 {
            if let t = riskField.summary(at: s.coordinate), !summaries.contains(t) {
                summaries.append(t)
            }
        }
        r.hazardSummaries = summaries
        // GO is gated on this flag: a corridor whose NWS fetches FAILED must
        // not present as confidently clear (score.complete's documented
        // contract). Incomplete routes keep "Checking weather…" and hydrate retries.
        r.weatherScored = score.complete
        return (r, feeds)
    }

    /// Second hydration pass: physical attributes from public data (EPQS
    /// grades / OSM low bridges / FEMA flood zones / EV charging gaps) —
    /// best-effort concurrent fetches; nil = unknown. Split from `scored(_:)`
    /// because Overpass and EPQS on a long corridor take 30 s+ and the GO
    /// gate keys on the SAFETY verdict — the weather band must not wait for
    /// bridge heights.
    private func attributeScored(_ input: PlannedRoute) async -> PlannedRoute {
        var r = input
        // The weather pass already partitioned this polyline at the same
        // 40 km spacing and its riskSamples sit ON those boundaries — reuse
        // them instead of re-walking every polyline vertex (~30k on a long
        // route). Unscored input (rare: direct attribute hydration) still
        // partitions.
        let corridorSamples = input.riskSamples.isEmpty
            ? RouteService.corridorPartition(of: r.route.polyline, everyMeters: 40_000).samples
            : input.riskSamples.map(\.coordinate)
        let routeLength = r.distanceMeters
        let gradeSpacing = max(10_000.0, routeLength / 60)
        let gradeSamples = RouteService.samplePoints(of: r.route.polyline, everyMeters: gradeSpacing)
        let femaSamples = corridorSamples.enumerated()
            .filter { $0.offset % 2 == 0 }.map(\.element)   // every ~80 km
            .prefix(25)
        let boxes = Self.corridorBoxes(corridorSamples)

        // One batched request for the whole coarse profile (was one EPQS
        // request per sample).
        async let elevations = RouteAttributeFetcher.shared.elevations(at: gradeSamples)
        async let femaHits: [Bool?] = withTaskGroup(of: Bool?.self) { group in
            for pt in femaSamples {
                group.addTask { await RouteAttributeFetcher.shared.highRiskFloodZone(at: pt) }
            }
            var out: [Bool?] = []
            for await v in group { out.append(v) }
            return out
        }
        async let restrictionList = RouteAttributeFetcher.shared.postedRestrictions(inBoxes: boxes)

        // COARSE grade first (10 km spacing) — that alone smooths mountain
        // switchbacks into near-zero ("Appalachian routes showed null
        // grade"). Refine: the steepest coarse segments get re-sampled at
        // ~1.2 km, which is where real 6-9% climbs become visible.
        let coarseElevs = await elevations
        let coarse = RouteAttributes.maxGradePercent(
            elevations: coarseElevs, spacingMeters: gradeSpacing)
        r.maxGradePercent = coarse
        // The grade TABLE: coarse segments as the baseline, fine (~1.2 km)
        // segments spliced in where the terrain has real relief.
        var table = GradeProfile.segments(elevations: coarseElevs, spacingMeters: gradeSpacing)
        let refined = await Self.refineGrade(
            polyline: r.route.polyline, coarseElevations: coarseElevs,
            spacing: gradeSpacing)
        if let refined {
            r.maxGradePercent = max(coarse ?? 0, refined.maxPercent)
            table.append(contentsOf: refined.segments)
            table.sort { $0.startMile < $1.startMile }
        }
        r.gradeProfile = table
        // Resolve the 3D grade overlay's draw geometry here, once — the map
        // used to slice the full polyline per segment per frame.
        (r.gradeRibbonSlices, r.steepMarkers) = RouteService.gradeDisplayGeometry(
            of: r.route.polyline, profile: table)
        let fema = (await femaHits).compactMap { $0 }
        r.femaFloodFraction = fema.isEmpty ? nil
            : Double(fema.filter { $0 }.count) / Double(fema.count)
        if let found = await restrictionList {
            // ON-ROUTE only: a posted limit restricts the route when it sits
            // on a public road the route drives along. Garages, driveways and
            // roads crossing under or over it don't count — the old rule
            // (within 60 m of a point every 250 m) read a 6 ft garage bar as
            // I-65's clearance and failed every route into downtown Milwaukee.
            let line = FasterRoutePolicy.coordinates(of: r.route.polyline)
            r.clearancesMeters = zip(found.clearances,
                                     RouteAttributes.onRoute(found.clearances, route: line))
                .filter(\.1).map(\.0.value)
            r.weightLimitsLbs = zip(found.weights,
                                    RouteAttributes.onRoute(found.weights, route: line))
                .filter(\.1).map(\.0.value)
        } else {
            r.clearanceDataUnavailable = true   // every endpoint failed
        }
        // EV VIABILITY: before offering an electric driver this route as
        // drivable, verify chargers exist within range along it. Sample at
        // 60% of usable range; a sample with no charger within 25 km marks
        // a charging gap on the card.
        if vehicle.profile?.fuelType == .electric,
           let range = vehicle.profile?.ratedRangeMiles, range > 0 {
            let intervalMeters = max(range * 0.6 * 1609.344, 40_000)
            let checkpoints = RouteService.samplePoints(
                of: r.route.polyline, everyMeters: intervalMeters)
            var gapAtMile: Double?
            for (i, pt) in checkpoints.enumerated().dropFirst() {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = "EV charging station"
                request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.evCharger])
                request.region = MKCoordinateRegion(center: pt,
                                                    latitudinalMeters: 50_000,
                                                    longitudinalMeters: 50_000)
                let found = (try? await MKLocalSearch(request: request).start())?
                    .mapItems.isEmpty == false
                if !found {
                    gapAtMile = Double(i) * intervalMeters / 1609.344
                    break
                }
            }
            r.evChargingGapMiles = gapAtMile
        }
        r.attributesScored = true
        return r
    }

    /// Second-pass grade refinement: find the coarse segments with the
    /// biggest |Δelevation| and re-sample each at 8 subdivisions (~1.2 km at
    /// 10 km spacing). Capped at 3 segments × 9 points = 27 extra EPQS calls.
    private static func refineGrade(
        polyline: MKPolyline, coarseElevations: [Double?], spacing: Double
    ) async -> (maxPercent: Double, segments: [GradeSegment])? {
        var deltas: [(idx: Int, delta: Double)] = []
        for i in 1..<coarseElevations.count {
            if let a = coarseElevations[i - 1], let b = coarseElevations[i] {
                deltas.append((i - 1, abs(b - a)))
            }
        }
        // Only refine where the coarse pass saw real relief (>60 m over a
        // segment — flat corridors skip the extra requests entirely).
        let worst = deltas.filter { $0.delta > 40 }
            .sorted { $0.delta > $1.delta }.prefix(5)
        guard !worst.isEmpty else { return nil }
        let fine = RouteService.samplePoints(of: polyline, everyMeters: spacing / 8)
        // Gather every refined stretch's points into ONE batched elevation
        // request (was one EPQS request per fine point, ~45 per route).
        var combined: [CLLocationCoordinate2D] = []
        var stretches: [(seg: (idx: Int, delta: Double), lo: Int, range: Range<Int>)] = []
        for seg in worst {
            let lo = seg.idx * 8
            let hi = min(lo + 8, fine.count - 1)
            guard lo < hi else { continue }
            let pts = Array(fine[lo...hi])
            stretches.append((seg, lo, combined.count..<(combined.count + pts.count)))
            combined.append(contentsOf: pts)
        }
        let allElevs = await RouteAttributeFetcher.shared.elevations(at: combined)
        var best: Double = 0
        var fineSegments: [GradeSegment] = []
        for (_, lo, range) in stretches {
            let elevs = Array(allElevs[range])
            let startMile = Double(lo) * (spacing / 8) / 1609.344
            let segs = GradeProfile.segments(
                elevations: elevs, spacingMeters: spacing / 8, startMile: startMile)
            fineSegments.append(contentsOf: segs)
            if let g = RouteAttributes.maxGradePercent(elevations: elevs,
                                                       spacingMeters: spacing / 8) {
                best = max(best, g)
            }
        }
        guard best > 0 || !fineSegments.isEmpty else { return nil }
        return (best, fineSegments)
    }

    /// Corridor bounding boxes (~5 chunks, ±0.03° padding) for the Overpass
    /// low-clearance sweep.
    private static func corridorBoxes(
        _ samples: [CLLocationCoordinate2D]
    ) -> [(s: Double, w: Double, n: Double, e: Double)] {
        guard !samples.isEmpty else { return [] }
        let chunkSize = max(samples.count / 5, 1)
        var boxes: [(s: Double, w: Double, n: Double, e: Double)] = []
        var i = 0
        while i < samples.count {
            let chunk = samples[i..<min(i + chunkSize + 1, samples.count)]
            let lats = chunk.map(\.latitude), lons = chunk.map(\.longitude)
            boxes.append((s: lats.min()! - 0.03, w: lons.min()! - 0.03,
                          n: lats.max()! + 0.03, e: lons.max()! + 0.03))
            i += chunkSize
        }
        return boxes
    }

    private static func pathLength(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count > 1 else { return 0 }
        var total = 0.0
        // Summed across all of a route's segments this re-walks every vertex
        // of the polyline — allocation-free hops, not CLLocation pairs.
        for i in 1..<coords.count {
            total += POIRanking.meters(coords[i - 1], coords[i])
        }
        return total
    }

    /// Route selection is the mode flip: planning is continent-wide and lazy,
    /// navigation is local and eager (camera follows GPS, updates every fix).
    func select(route: PlannedRoute) {
        // The strongest preference signal the app can observe: the driver saw
        // N ranked options with ETAs, risk bands, and costs, and picked one.
        // This method used to clear `routeChoices` on the next line and keep
        // nothing — the comparison set, and with it the ability to learn any
        // time-versus-risk exchange rate, was thrown away every trip.
        if routeChoices.count > 1 {
            let fastest = routeChoices.map(\.eta).min() ?? route.eta
            ChoiceLogStore.shared.record(
                kind: "route",
                options: routeChoices.enumerated().map { i, r in
                    ChoiceLog.Option(
                        aheadMiles: r.distanceMeters / 1609.344,
                        // For a route, "detour" is the time it costs against
                        // the fastest option — the quantity the driver is
                        // actually trading risk against.
                        detourMiles: (r.eta - fastest) / 60,
                        price: r.weatherRisk,
                        rating: r.rankingRisk,
                        costTier: nil,
                        shownRank: i,
                        chosen: r.id == route.id)
                })
        }
        // A trip switched to mid-drive (a yes to one planned while driving)
        // starts with its own corridor's feeds, held for it while the old
        // trip was still being watched, and keeps the needs clock running:
        // no stop was made.
        let drivingOn = tripUnderway
        if let feeds = heldChoiceFeeds[route.id] { adoptCorridorFeeds(feeds) }
        heldChoiceFeeds = [:]
        routeChoices = []
        pendingVoiceOffer = nil
        tripGeneration += 1
        // Remember the trip's true endpoint so added stops can chain back.
        //
        // Unconditionally. This was `if finalDestination == nil`, which is
        // only false when a PREVIOUS trip's endpoint is still live — so the
        // guard's entire effect was to keep the abandoned destination. A
        // driver who changed their mind mid-drive ("start a trip to
        // Cheyenne" while heading to Denver) got guidance to Cheyenne, but
        // every reroute — the traffic offer, the storm escalation, the
        // continuation leg behind an added stop — planned back to Denver.
        if let end = Self.lastCoordinate(of: route) {
            finalDestination = (end, route.destinationName)
        } else {
            finalDestination = nil
        }
        // The abandoned trip's stop chain goes with it. Without this, a stop
        // added to the old trip still fires on arrival at the new one.
        upcomingLeg = nil
        pendingStopName = nil
        pendingStopKind = nil
        // …and so does its transit overlay. present() cancels these; select()
        // did not, so a rail itinerary still computing when the driver hit GO
        // could land mid-drive and flip an active drive into passenger mode,
        // blanking the speed sign and the camera list.
        transitItinerary = nil
        transitTasks.values.forEach { $0.cancel() }
        transitTasks = [:]
        transitOptions = [:]
        activeTransitModes = []
        hybridOption = nil
        // Review finding: selecting before hydration finishes captured a
        // baseline of 0 (unscored routes), so the first corridor update on any
        // yellow corridor fired a spurious escalation. Sentinel −1 defers the
        // capture to the first corridor score instead.
        escalationState = .fresh(baseline: route.weatherScored ? route.weatherRisk : nil)
        tripObservedPeak = route.weatherRisk   // seed with the plan-time estimate
        escalation = nil
        arrivedAt = nil
        continuationFailure = nil
        imminentWarning = nil
        dismissedImminentIDs = []
        shelteredImminentIDs = []
        reachSpeeds = [:]   // per-trip state like its two siblings above
        stopDelaySeconds = 0
        shelteredSecondsBanked = 0
        shelterSession = nil   // a countdown must not outlive its trip
        tripShareOffered = false   // new trip → the share banner may show once
        tripSharePrompt = false
        restoreTransientPanels()   // the drive starts with its menus in reach
        // Carry the road ahead offline for trips between towns: if signal
        // drops (or the app is reopened out in the country), the way onward
        // is already on disk. Short in-town hops aren't stored.
        recordOfflineCorridor(for: route)
        // Start the delay model's training pair: what we promised, and when.
        // Not for a walk: it would file a 3 mph trip as a crawling drive.
        tripPredictedSeconds = route.isWalk ? nil : route.eta
        tripStartedAt = Date()
        tripStartArea = location.coordinate.map(TrafficArea.init)
        tripDistanceMeters = route.distanceMeters
        tripLearningErased = false
        mode = .navigating
        startLeg(route, resetsNeeds: !drivingOn)
        askForTripPermissionsIfNeeded()   // lock-screen warnings + crash reply, at the first GO
        maybeOfferTripShare()   // a 200+ mile route triggers right at GO
        checkTowingSignal()   // trailer signal checked at trip start, not per tick
        if crashDetectionEnabled, CrashDetectionService.isAvailable {
            // The report's address is looked up at the crash site, when an
            // impact is confirmed (CrashDetectionService.impactDetected).
            crash.begin()
        }
    }

    /// Save the driven route's geometry for offline use when the trip is a
    /// real between-towns run (CorridorRetention decides). A corridor to the
    /// same destination replaces the previous one rather than stacking.
    private func recordOfflineCorridor(for route: PlannedRoute) {
        let poly = route.route.polyline
        let n = poly.pointCount
        guard n > 1 else { return }
        var coords = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid, count: n)
        poly.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        corridors.record(coordinates: coords,
                         destinationName: route.destinationName,
                         tripMeters: route.distanceMeters)
    }

    func endNavigation() {
        // FIRST, before anything is torn down. This used to sit near the end
        // of the teardown, below `navigation.stop()` (which nils the route,
        // so the trip's weather read back as "clear") and below
        // `stopDelaySeconds = 0` (so an hour spent sheltering from a tornado
        // was billed as an hour of driving). The model then learned that
        // this road takes 1.5x as long in CLEAR weather, and inflated every
        // future estimate for it.
        learnTripDuration()   // teach the delay model what this drive cost
        tripGeneration += 1
        Self.clearNotices()   // the trip's lock-screen warnings go with it
        tripClosures = []
        // The towing card belongs to the drive; left open, it came back over
        // the planner once the trip ended.
        showTowingCard = false
        tripLive = .empty
        tripLiveBox = nil
        corridorContextTask?.cancel()
        windLookupTask?.cancel()
        lastWindLookup = .distantPast
        corridorWindMph = 0
        corridorWindFromDegrees = nil
        trafficWatchTask?.cancel()
        trafficDelayMinutes = nil
        clearTrafficOffer()
        fasterRouteSavedMinutes = nil
        pendingVoiceOffer = nil
        walkRefineTask?.cancel()
        walkingRefinedPath = []
        walkRefineAnchor = nil
        navigation.stop()
        // Review finding: the corridor watch loop outlived navigation (its
        // Task kept polling NWS on the planning screen) — stop it here.
        alerts.endCorridorWatch()
        crash.end()
        poi.reset()
        escalation = nil
        arrivedAt = nil
        continuationFailure = nil
        imminentWarning = nil
        stopDelaySeconds = 0
        shelteredSecondsBanked = 0
        shelterSession = nil   // a countdown must not outlive its trip
        tripNeedSchedule = []
        finalDestination = nil
        pendingStopName = nil
        pendingStopKind = nil
        upcomingLeg = nil
        // Drive-time advisories are only recomputed inside the navigating GPS
        // sink — clear them here or they freeze on screen into planning mode
        // and the start of the next trip (a stale refuel prompt answered
        // post-trip would even feed vehicle.filledUp()).
        towingWarning = nil
        fuelRecommendation = nil
        clearFuelWarning()
        limitLookupTask?.cancel()
        laneLookupTask?.cancel()
        upcomingLanes = []
        laneLookupStep = -1
        laneLookupStepInFlight = -1
        postedSpeedLimitMph = nil
        lastLimitPoint = nil
        lastLimitStep = nil
        postedLimitSetAt = nil
        // Enforcement cameras belong to the trip too: leaving them up drops
        // a stale chip into planning mode, and keeping the spoken-for list
        // would silence a camera the next trip drives past again.
        cameraLookupTask?.cancel()
        enforcementCameras = []
        cameraWarning = nil
        lastCameraLookup = nil
        announcedCameras.removeAll()
        refuelPrompt = false
        refuelPromptShownAt = nil
        upcomingSteepGrade = nil
        workZonesAhead = 0
        workZoneRoad = nil
        // Start the off-duty clock rather than clearing it. This was
        // `stoppedSince = nil`, which threw away the break a trucker takes
        // BETWEEN trips: they would drive 7h45m, end navigation, rest 90
        // minutes, start a new trip — and be told a break was due 15
        // minutes later, because nothing had recorded the rest. If a stop
        // was already running, keep its original start so credit earned is
        // not lost; if they are still rolling, leave it nil.
        if stoppedSince == nil, (location.latest?.speed ?? -1) <= 1 {
            stoppedSince = Date()
        }
        lastClockFix = nil
        tripSharePrompt = false
        tripShareOffered = false
        restoreTransientPanels()   // back to planning with the trip menus out
        corridors.prune(position: location.coordinate)   // arrived → let it go
        roadEfficiency.flush()   // bank the last measured stretch
        mode = .planning
        watch.sendEnded()
    }

    // MARK: escalating-risk reroute (driver-approved)

    /// Corridor re-scores arrive every ~4 min while driving. If risk jumps
    /// meaningfully past yellow relative to what the driver accepted at
    /// selection, surface a flashing prompt — never reroute silently.
    /// Re-take the trip's live snapshot every 15 minutes while driving, off
    /// the update path: fires spread and quakes happen mid-trip. The fetcher's
    /// own TTLs make this a network call only when a feed has actually aged.
    private func refreshTripLiveIfStale() {
        guard let box = tripLiveBox,
              Date().timeIntervalSince(tripLiveFetched) > 900 else { return }
        tripLiveFetched = Date()   // claim the slot; a failed fetch retries next time
        let gen = tripGeneration
        Task { [weak self] in
            let snap = await LiveHazardFeedFetcher.shared.liveSnapshot(
                minLat: box.minLat, minLon: box.minLon, maxLat: box.maxLat, maxLon: box.maxLon)
            await MainActor.run {
                guard let self, self.tripGeneration == gen else { return }
                self.tripLive = snap
            }
        }
    }

    private func handleCorridorUpdate(_ score: WeatherAlertService.CorridorScore) {
        refreshTripLiveIfStale()
        guard mode == .navigating else { return }
        // LIKE-FOR-LIKE with the baseline the driver accepted: the route band
        // is DISTANCE-WEIGHTED, and the watch window's samples are uniformly
        // spaced, so the comparable live number is the plain sample MEAN — the
        // old peak⊕avg blend sat above the weighted baseline by construction
        // and manufactured escalations on quiet routes.
        let closures = HazardFeedScores.PreparedPoints(tripClosures)
        let sampleRisks = score.samples.map {
            sampleRealizedRisk(at: $0.coordinate, alertEvent: $0.worstEvent,
                               alertSeverity: $0.risk,
                               closureScore: HazardFeedScores.closureScore(
                                   prepared: closures, at: $0.coordinate),
                               live: HazardFeedScores.live(
                                   at: $0.coordinate, snapshot: tripLive).bandInputContribution)
        }
        let peakR = sampleRisks.max() ?? 0
        // The DRIVEN route's samples, segments and alert shapes used to be
        // fixed at plan time: a tornado warning issued an hour into the trip
        // escalated and bannered, but the route line stayed the colour it
        // was at GO and the polygon never appeared on the map. Fold each
        // complete window score back into the route's own metadata — the
        // same segment rule as plan time (a stretch takes the worse of its
        // two endpoint samples) — and bump the version the map keys on.
        // A leg with no check points yet (the way to an added stop, a replan
        // before its score lands) takes the window's alerts and shapes all
        // the same: it took neither, and "how's the road ahead" answered
        // all-clear under a live warning whose outline was never drawn.
        if score.complete, var live = navigation.route {
            // Every alert in the window, for "how's the road ahead": the
            // check points keep only their worst.
            var changed = live.watchedAlertEvents != score.events
            live.watchedAlertEvents = score.events
            if !live.riskSamples.isEmpty {
                var samples = live.riskSamples
                var repainted = false
                for (w, r) in zip(score.samples, sampleRisks) {
                    var bi = -1
                    var bd = 600.0   // a window sample belongs to the route sample within 600 m
                    for (i, s) in samples.enumerated() {
                        let d = POIRanking.meters(s.coordinate, w.coordinate)
                        if d < bd { bd = d; bi = i }
                    }
                    guard bi >= 0 else { continue }
                    let old = samples[bi]
                    if abs(old.risk - r) > 0.02 || old.worstEvent != w.worstEvent
                        || old.alertID != w.alertID {
                        samples[bi] = RiskSample(coordinate: old.coordinate, risk: r,
                                                 worstEvent: w.worstEvent, alertID: w.alertID)
                        repainted = true
                    }
                }
                if repainted {
                    live.riskSamples = samples
                    let last = samples.count - 1
                    live.riskSegments = live.riskSegments.enumerated().map { j, seg in
                        RiskSegment(coordinates: seg.coordinates, risk: max(samples[min(j, last)].risk, samples[min(j + 1, last)].risk), lengthMeters: seg.lengthMeters)
                    }
                    changed = true
                }
            }
            // Every pass, so a warning that ends leaves the map on time.
            let polygons = WeatherAlertService.mergedPolygons(
                live.alertPolygons, live: score.alertPolygons, now: Date())
            if polygons.map(\.id) != live.alertPolygons.map(\.id) {
                live.alertPolygons = polygons
                changed = true
            }
            if changed {
                navigation.updateRouteMetadata(live)
                routeMetadataVersion &+= 1
            }
        }
        let peakAlertID = zip(score.samples, sampleRisks)
            .max { $0.1 < $1.1 }?.0.alertID
        let risk = sampleRisks.isEmpty ? 0 : sampleRisks.reduce(0, +) / Double(sampleRisks.count)
        // The worst actually ENCOUNTERED is the peak sample, not the blend —
        // it feeds the seasonal model's predicted-vs-observed record.
        tripObservedPeak = max(tripObservedPeak, peakR)
        if notifyImminent { updateImminentWarning(from: score) }
        // Reverse-geocode the current state on corridor updates — the
        // trucker radio retune AND the DOT work-zone feed both key off it.
        if let pos = effectivePosition {
            let corridorSamples = score.samples.map(\.coordinate)
            corridorContextTask?.cancel()
            corridorContextTask = Task { [weak self] in
                let state: String?
                if let last = self?.lastGeocode, POIRanking.meters(last.position, pos) < 20_000 {
                    state = last.state   // same state as 20 km ago; skip the geocode
                } else {
                    let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
                        CLLocation(latitude: pos.latitude, longitude: pos.longitude))
                    state = placemarks?.first?.administrativeArea
                    if let state { self?.lastGeocode = (pos, state) }
                }
                await MainActor.run {
                    self?.currentStateCode = state
                    if self?.truckerUI == true {
                        self?.retuneRadioIfNeeded(stateCode: state)
                    }
                }
                // Keyless live fuel: refresh AAA's state average for wherever
                // the driver is (12-h cache inside; polite single fetch).
                if let state, state.count == 2 {
                    await AAAFuelPrices.shared.refresh(stateCode: state)
                }
                // Roadwork ahead, straight from the state DOT's WZDx feed:
                // zones within 3 km of the scored corridor samples.
                guard let raw = state?.trimmingCharacters(in: .whitespaces),
                      !raw.isEmpty else { return }
                let stateName = FuelPrices.stateNameToCode[raw.lowercased()] != nil
                    ? raw.lowercased()
                    : FuelPrices.stateNameToCode.first { $0.value == raw.uppercased() }?.key
                guard let stateName else { return }
                let zones = await WorkZones.shared.zones(stateName: stateName)
                let nearby = zones.filter { z in
                    corridorSamples.contains { POIRanking.meters($0, z.coordinate) < 3_000 }
                }
                await MainActor.run {
                    guard let self, self.mode == .navigating, !Task.isCancelled else { return }
                    if self.workZonesAhead != nearby.count { self.workZonesAhead = nearby.count }
                    if self.workZoneRoad != nearby.first?.road { self.workZoneRoad = nearby.first?.road }
                }
            }
        }
        // The decision itself — deferred baseline, incomplete-score guard,
        // sustained vs acute triggers, identity-aware dismissal — is
        // EscalationPolicy, in Core, pinned by FLOWSTests. It sat inline here
        // and was changed twice in a month with no test able to see it.
        let (next, trigger) = EscalationPolicy.evaluate(
            .init(complete: score.complete, mean: risk, peak: peakR, peakAlertID: peakAlertID),
            state: escalationState)
        escalationState = next
        // Not while the driver's Reroute is planning: a failed plan puts the
        // prompt back, and the next pass raises whatever is current.
        if let trigger, notifyEscalation, escalationReroutesInFlight == 0 {
            let raised = Escalation(
                newRisk: trigger.risk,
                headline: score.headlines.first ?? "Conditions worsening along this route",
                alertID: trigger.alertID)
            let previous = escalation
            escalation = raised
            // The policy raises the same prompt on every corridor pass until
            // the driver answers it, and a driver can't answer at speed: the
            // lock screen hears about a prompt once, and again only for a
            // different hazard or a clearly worse one — not every 2 minutes.
            let isNew = previous == nil
                || previous?.alertID != raised.alertID
                || raised.newRisk > (previous?.newRisk ?? 0) + EscalationPolicy.dismissMargin
            if isNew {
                // The prompt was silent: a driver watching the road got no
                // cue at all while a lesser faster-route offer was spoken
                // and felt. Felt once per prompt, like the lock-screen notice.
                if hapticAlerts { Haptics.warning() }
                // No cause in the title: a road closure, a fire or an
                // evacuation raises this as surely as a storm.
                Self.noticeIfAway(
                    id: "escalation",
                    title: "Your route is getting riskier",
                    body: raised.headline + ". Open FLOWS to find a safer way or keep going.")
                if voiceAlerts {
                    // A prompt it replaces stops being read.
                    VoiceAnnouncer.shared.cancel(topic: SpeechTopic.escalation)
                    VoiceAnnouncer.shared.announce(
                        SiriSummaries.escalationPrompt(headline: raised.headline),
                        topic: SpeechTopic.escalation)
                }
            }
        }
    }

    /// Weather within 10 MINUTES at current speed gets the loud on-screen
    /// treatment: official summary + source link, and FLOWS reacts —
    /// life-safety warnings auto-open the matching shelter list; short-lived
    /// upper-yellow risk recommends waiting it out at a rest area.
    private func updateImminentWarning(from score: WeatherAlertService.CorridorScore) {
        guard let fix = effectivePosition else { return }
        let speed = max(location.speed, 0)
        // Nearest risky sample per alert, by distance from the vehicle.
        var nearest: [String: Double] = [:]
        for s in score.samples where s.risk >= FlowsCore.riskGreenMin {
            guard let id = s.alertID else { continue }
            let d = POIRanking.meters(fix, s.coordinate)
            if d < nearest[id, default: .greatestFiniteMagnitude] { nearest[id] = d }
        }
        let candidates = nearest.compactMap { id, dist -> ImminentAlerts.Candidate? in
            guard !dismissedImminentIDs.contains(id),
                  let alert = score.alertsByID[id] else { return nil }
            return ImminentAlerts.Candidate(
                alertID: id, distanceMeters: dist, severityScore: alert.severityScore,
                threatRank: ImminentAlerts.threatRank(
                    event: alert.event, severityScore: alert.severityScore))
        }
        guard let hit = ImminentAlerts.firstImminent(candidates, speedMps: speed),
              let alert = score.alertsByID[hit.alertID] else {
            // Nothing imminent anymore — clear a stale banner, EXCEPT red
            // alerts (shelter AND lookout: both stay until the driver
            // physically presses them) and EXCEPT incomplete scores: a
            // transient NWS failure zeroes the samples, and "no data" must
            // never read as "all clear".
            //
            // Lookout was missing here. An AMBER alert's banner is keyed on
            // a sample inside the look-ahead window, and that window shrinks
            // with speed — so slowing into town silently erased a live child
            // abduction alert, and speeding up announced it again.
            if score.complete,
               imminentWarning?.action != .shelter,
               imminentWarning?.action != .lookout { imminentWarning = nil }
            return
        }
        let action = ImminentAlerts.classify(
            event: alert.event, severityScore: alert.severityScore, expires: alert.expires)
        let fullText = [alert.headline, alert.detail ?? ""].joined(separator: " ")
        // Incident anchor: the alert polygon's weighted middle, else the
        // nearest risky sample carrying this alert.
        let incident = alert.polygon.map { ring -> CLLocationCoordinate2D in
            let lat = ring.map(\.latitude).reduce(0, +) / Double(max(ring.count, 1))
            let lon = ring.map(\.longitude).reduce(0, +) / Double(max(ring.count, 1))
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        } ?? score.samples.first { $0.alertID == alert.id }?.coordinate
        // A suspect vehicle or person is only described by the AMBER family
        // and law-enforcement alerts — never by weather.
        let describesEntity = AlertEntityParser.describesAnEntity(event: alert.event)
        var warning = ImminentWarning(
            alertID: alert.id, event: alert.event, headline: alert.headline,
            detail: alert.detail, sourceURL: alert.sourceURL, action: action,
            etaSeconds: ImminentAlerts.secondsToReach(
                distanceMeters: hit.distanceMeters, speedMps: speed),
            vehicleEntity: describesEntity
                ? AlertEntityParser.vehicle(in: fullText) : nil,
            personEntity: describesEntity
                ? AlertEntityParser.person(in: fullText) : nil,
            incidentCoordinate: incident,
            onset: alert.onset,
            expires: alert.expires,
            severityScore: alert.severityScore)
        warning.threatRank = hit.threatRank
        if let cached = reachSpeeds[alert.id] {
            warning.reachSpeedMph = cached
        } else if action == .shelter, let incident {
            // Probe the roads near the incident once, then update in place.
            let id = alert.id
            Task { [weak self] in
                let mph = await LiveHazardFeedFetcher.shared.maxSpeedMph(near: incident)
                await MainActor.run {
                    guard let self else { return }
                    self.reachSpeeds[id] = mph
                    if self.imminentWarning?.alertID == id {
                        self.imminentWarning?.reachSpeedMph = mph
                    }
                }
            }
        }
        // A displayed RED alert holds the banner until pressed — a lower
        // alert never replaces it silently.
        // No spam, and life first: while a warning is showing, a different
        // alert replaces it only if it ranks HIGHER (a tornado displaces a
        // flood advisory; a flood advisory never displaces a tornado, and a
        // lookout displaces nothing). The same alert refreshes freely; the
        // voice and haptics fire only when the alert ID changes.
        if let current = imminentWarning, current.alertID != warning.alertID,
           warning.threatRank <= current.threatRank,
           !dismissedImminentIDs.contains(current.alertID) { return }
        if imminentWarning != warning { imminentWarning = warning }
        // Red alert → the shelter list for THIS hazard opens itself, once.
        if action == .shelter, !shelteredImminentIDs.contains(alert.id) {
            shelteredImminentIDs.insert(alert.id)
            collapsedPanels.remove("stops")   // a tucked stop list comes back out for it
            Task { await poi.request(.shelter, aheadOf: effectivePosition) }
        }
    }

    /// Driver dismissed the imminent banner — don't re-raise this alert.
    func dismissImminentWarning() {
        if let w = imminentWarning { dismissedImminentIDs.insert(w.alertID) }
        imminentWarning = nil
    }

    /// Driver tapped "Continue" — accept the new risk level, stop flashing,
    /// don't nag again unless it climbs further.
    func dismissEscalation() {
        if let e = escalation {
            let trigger: EscalationPolicy.Trigger = e.alertID == nil
                ? .sustained(mean: e.newRisk)
                : .acute(peak: e.newRisk, alertID: e.alertID)
            escalationState = EscalationPolicy.dismissed(trigger, state: escalationState)
        }
        escalation = nil
    }

    /// Driver tapped "Reroute" — replan from the current fix, pick the
    /// lowest-alert-risk alternative, and swap the active route.
    ///
    /// Planned the way the leg being driven was (`routes(like:)`), so a
    /// walker gets a walk. The pick escapes the risk first and then keeps
    /// the driver's filters and road choices, a rig's bridges, weights and
    /// grades loaded first (`FasterRoutePolicy.swapPick`). This used to plan
    /// a car route with no filters: a walker got roads for cars and a
    /// trailer could be sent under a low bridge.
    func approveEscalationReroute() async {
        guard let fix = location.coordinate, let dest = finalDestination,
              let leg = navigation.route else {
            escalation = nil
            return
        }
        let previous = escalation
        let gen = tripGeneration
        let stop = pendingStopName
        // The prompt clears before the planning awaits: count the reroute so
        // no automatic faster-route switch lands in the middle of it.
        driverReroutesInFlight += 1
        escalationReroutesInFlight += 1
        defer {
            driverReroutesInFlight -= 1
            escalationReroutesInFlight -= 1
        }
        escalation = nil
        let planned = await routes(like: leg, from: fix, fromName: "Current location",
                                   to: dest.coordinate, toName: dest.name)
        guard !planned.isEmpty else {
            // Tapping Reroute used to make the banner vanish and nothing
            // else happen when the router failed — read as "done" by a
            // driver heading into the storm. Put the prompt back and say so.
            if mode == .navigating { escalation = previous }
            if voiceAlerts {
                VoiceAnnouncer.shared.announce("Couldn't find another route yet. Still on this one.",
                                               topic: SpeechTopic.escalation)
            }
            return
        }
        // Fully score every candidate (cached cells make this fast) and swap
        // to the calmest — hydrated, so the nav map keeps its risk coloring.
        // Only the road taken hands its feeds to the trip.
        let scored = await RequestGate.shared.withPlanningBurst {
            var out: [(route: PlannedRoute, feeds: CorridorFeeds)] = []
            for candidate in planned { out.append(await self.scoredWithFeeds(candidate)) }
            return out
        }
        let checked = await withAttributesIfFiltered(scored.map(\.route))
        guard var best = FasterRoutePolicy.swapPick(checked, leg: leg, filters: routeFilters,
                                                    limits: filterLimits, calmest: true)
        else { return }
        // The driver may have ended navigation or arrived during the awaits
        // above — don't resurrect a dead trip by restarting nav + corridor/
        // traffic watches over a route they no longer want.
        guard mode == .navigating, gen == tripGeneration, arrivedAt == nil else { return }
        // A stop added meanwhile (a shelter picked off the list) is the
        // driver's newer choice: it stays, and the prompt comes back rather
        // than the tap vanishing. A stop reached meanwhile changes nothing.
        if let added = pendingStopName, added != stop {
            if escalation == nil { escalation = previous }
            return
        }
        best.planKind = leg.planKind   // later replans keep the driver's choice
        // Reroute goes DIRECT to the final destination — drop the pending stop
        // entirely (name AND kind), or a later final arrival would be mishandled
        // as a stop arrival: a phantom vehicle.filledUp() corrupting the range
        // model and the trip record silently skipped. (startLeg rebaselines.)
        // Skipping a stop inside the storm is what Reroute is for.
        upcomingLeg = nil
        pendingStopName = nil
        pendingStopKind = nil
        if let feeds = scored.first(where: { $0.route.id == best.id })?.feeds {
            adoptCorridorFeeds(feeds)
        }
        startLeg(best)
    }

    /// Routes from `from` to `to` planned the way `leg` was, for a leg FLOWS
    /// swaps in mid-trip (a reroute, the way to an added stop, the way on
    /// from it); `FasterRoutePolicy.swapPick` chooses among them. A walk is
    /// planned as a walk — past the pedestrian router's reach, along local
    /// roads at walking pace and never a freeway when a road avoids one, as
    /// plan() does. A drive also asks for a toll-free plan when the driver
    /// avoids tolls or the leg has none, so a road keeping that choice can
    /// come back, and carries the driver's learned pace. Empty when nothing
    /// came back.
    private func routes(like leg: PlannedRoute, from: CLLocationCoordinate2D, fromName: String,
                        to: CLLocationCoordinate2D, toName: String) async -> [PlannedRoute] {
        if leg.route.transportType == .walking || leg.isWalkingEstimate {
            let walks = (try? await router.planRoutes(
                from: from, fromName: fromName, to: to, toName: toName, walking: true)) ?? []
            if !walks.isEmpty { return walks }
            let roads = (try? await router.planRoutes(
                from: from, fromName: fromName, to: to, toName: toName)) ?? []
            let noHighway = roads.filter { !$0.hasHighways }
            let local = roads.filter { $0.planKind == .avoidHighways }
            let base = !noHighway.isEmpty ? noHighway : !local.isEmpty ? local : roads
            return base.map { r in
                var w = r
                w.isWalkingEstimate = true
                w.etaOverride = PlannedRoute.walkingEstimateSeconds(meters: r.distanceMeters)
                return w
            }
        }
        guard let raw = try? await router.planRoutes(
            from: from, fromName: fromName, to: to, toName: toName,
            includeTollFree: leg.planKind == .tollFree || !leg.hasTolls
                || routeFilters.contains(.noTolls)) else { return [] }
        return RouteService.applyPersonalPace(
            raw, multiplier: DrivingProfileStore.shared.etaMultiplier)
    }

    /// `candidates` with their physical attributes loaded when the driver
    /// filters on them (a rig's bridges, weights and grades; flood zones on
    /// a scored road) and there is a choice to make. Unknown never excludes,
    /// so a fresh road would otherwise pass those filters unchecked — the
    /// reason a faster road FLOWS finds is asked about, never taken.
    private func withAttributesIfFiltered(_ candidates: [PlannedRoute]) async -> [PlannedRoute] {
        var loadable: Set<RouteFilter> = [.lowBridges, .bridgeWeight, .mountainGrades]
        if candidates.allSatisfy(\.weatherScored) { loadable.insert(.noFloodRisk) }
        guard candidates.count > 1, !routeFilters.isDisjoint(with: loadable) else { return candidates }
        let loaded = await withTaskGroup(of: PlannedRoute.self) { group in
            for c in candidates { group.addTask { await self.attributeScored(c) } }
            var out: [UUID: PlannedRoute] = [:]
            for await r in group { out[r.id] = r }
            return out
        }
        return candidates.map { loaded[$0.id] ?? $0 }
    }

    /// Common leg-swap: hydrated route into the engine + fresh corridor
    /// services, arrival chaining preserved. (Also the tail of select() —
    /// the two had drifted into near-identical copies.)
    /// When the current leg began and what it was predicted to take — the
    /// two halves of the personal ETA correction (DrivingProfile).
    private var legStartedAt: Date?
    private var legPredictedSeconds: TimeInterval = 0
    /// Bumped by select() and endNavigation(). Every background replan
    /// captures it before its first await and checks it after: "mode is
    /// still .navigating" is not enough, because the driver can end one
    /// trip and start another while the plan is in flight, and the stale
    /// plan would then startLeg() on the wrong trip.
    private var tripGeneration = 0

    private func startLeg(_ leg: PlannedRoute, resetsNeeds: Bool = false) {
        // The recurring food/rest/fuel needs count from the last real stop:
        // only a trip start or a stop (`resetsNeeds`) restarts them
        // (TripNeeds.milesSinceStop). Read before the engine takes the leg.
        let stopped = resetsNeeds || navigation.route == nil
        tripNeedsMilesBeforeLeg = TripNeeds.milesSinceStop(
            beforeLeg: tripNeedsMilesBeforeLeg,
            drivenOnLastLegMeters: navigation.guidance?.alongMeters ?? 0, stopped: stopped)
        if stopped {
            tripNeedsSeed = UInt64(leg.distanceMeters.rounded())
            tripNeedsAvgMph = leg.eta > 0
                ? (leg.distanceMeters / 1609.344) / (leg.eta / 3600) : 55
        }
        lastRouteRect = leg.route.polyline.boundingMapRect
        legStartedAt = Date()
        // The learner corrects the router's time; it must be trained on the
        // router's time, not on its own last correction — otherwise every
        // arrival compounds the multiplier that produced the prediction.
        legPredictedSeconds = leg.isWalkingEstimate ? leg.eta : leg.route.expectedTravelTime
        // A fresh leg has no spoken turns yet.
        lastSpokenTurnStep = -1
        turnNearSpoken = false
        // Rebaseline escalation on every leg swap — and ALWAYS defer to the
        // first complete corridor score (sentinel -1) rather than seeding from
        // leg.weatherRisk: the plan-time number blends forecast predictors,
        // the flood elevation multiplier, and closure scores that the live
        // watch mean (sampleRealizedRisk with live-only inputs) never sees, so
        // a plan-time baseline sits systematically HIGH and suppressed real
        // escalations. Deferring makes baseline and live means like-for-like
        // by construction.
        escalationState = .fresh(baseline: nil)
        // The sidewalk overlay belongs to the leg it was refined for: kept
        // across a swap it drew the path along the road just left, for up to
        // 400 m, and a refine still in flight could write it back.
        walkRefineTask?.cancel()
        walkRefineTask = nil
        walkingRefinedPath = []
        walkRefineAnchor = nil
        navigation.start(route: leg, onArrival: { [weak self] in self?.handleArrival() })
        // Legs swapped in mid-drive (reroute, added stop, arrival chaining)
        // arrive weather-scored but attribute-pending — hydrate grades /
        // clearances into the live leg without blocking guidance.
        if !leg.attributesScored {
            Task { [weak self] in await self?.hydrateAttributes(leg) }
        }
        // Recurring-needs schedule, from the last stop through this leg.
        rebuildTripNeeds()
        watch.sendRoute(leg)
        // Warm what matters for the next few minutes of driving, nothing more:
        // POIs and weather alerts along the corridor ahead, not the continent.
        poi.beginCorridorSearch(along: leg)
        alerts.beginCorridorWatch(along: leg, window: { [weak self] in
            self?.watchWindow() ?? (0, .greatestFiniteMagnitude, 240)
        }) { [weak self] score in
            self?.handleCorridorUpdate(score)
        }
        beginTrafficWatch()
    }

    /// Real-time traffic along the active leg: compare a live traffic-aware
    /// ETA to the guidance baseline every 5 min.
    private func beginTrafficWatch() {
        trafficWatchTask?.cancel()
        trafficDelayMinutes = nil
        clearTrafficOffer()   // the old leg's offer goes with its chip, pending yes and all
        fasterRouteSavedMinutes = nil
        trafficWatchTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                // Hybrid cadence: tighter during commute/school/meal windows
                // in the vehicle's LOCAL time (longitude-derived — crossing
                // a time zone adjusts automatically).
                let lon = await MainActor.run { self?.location.coordinate?.longitude }
                try? await Task.sleep(for: .seconds(
                    TrafficCadence.intervalSeconds(now: Date(), longitude: lon ?? -90)))
                // Task.sleep swallows the CancellationError under try? — a
                // leg swap that cancelled this task mid-sleep must not run one
                // more stale iteration (duplicate ETA probe, spurious chip).
                if Task.isCancelled { return }
                // Review finding: this compared an ETA to the FINAL
                // destination against the remaining time of the CURRENT leg —
                // with an added stop those differ by the whole second leg, so
                // the "delay" chip fired spuriously. Both sides now measure
                // the current leg.
                guard let self else { return }   // model gone — stop, don't spin
                guard self.mode == .navigating,
                      let fix = self.location.coordinate,
                      let leg = self.navigation.route,
                      let baseline = self.navigation.guidance?.remainingTime,
                      let remaining = self.navigation.guidance?.remainingDistance
                else { continue }
                // Scope: only the next ≤100 miles of THIS route — no wasted
                // computation on the far end of a cross-country trip.
                let horizon = min(remaining, 160_934.0)
                let target = TrafficCadence.pointAlong(
                    polyline: leg.route.polyline,
                    from: self.navigation.guidance?.alongMeters ?? 0,
                    meters: horizon) ?? Self.lastCoordinate(of: leg) ?? fix
                let scaledBaseline = remaining > 0 ? baseline * horizon / remaining : baseline
                let request = MKDirections.Request()
                request.source = MKMapItem(placemark: MKPlacemark(coordinate: fix))
                request.destination = MKMapItem(placemark: MKPlacemark(coordinate: target))
                request.transportType = .automobile
                request.departureDate = Date()
                guard let eta = try? await MKDirections(request: request).calculateETA() else { continue }
                // The probe doesn't stop for cancellation: a leg swap, a stop
                // or the end of the trip while it was out leaves this watch
                // measuring a leg that is gone. The new leg runs its own.
                if Task.isCancelled { return }
                let liveDelay = (eta.expectedTravelTime - scaledBaseline) / 60
                // The live probe sees traffic that exists NOW; the learned
                // model knows what this hour in this weather usually costs.
                // Take the worse of the two, so a corridor that reliably
                // backs up at 5pm warns before the queue has formed.
                let learned = Double(self.trafficModel.predictedDelayMinutes(
                    routerSeconds: scaledBaseline,
                    area: TrafficArea(fix),
                    roadClass: self.currentRoadClass,
                    weather: self.currentTrafficWeather))
                let delay = max(liveDelay, learned)
                // Weighed whatever the traffic switch says: it hides the
                // chip and its offer, not the faster road FLOWS takes on its
                // own (owner item 9). Gating it here left a driver who hid
                // the chips sitting in a jam with an equally safe way round.
                let newDelay = delay >= 8 ? Int(delay.rounded()) : nil
                // A FRESH jam is weighed once (not every re-measure of the
                // same jam): a faster road is taken, offered or refused, and
                // an offer is spoken once. A jam with nothing to take, an
                // offer with nothing weighed behind it, or a weighed road gone
                // stale is weighed again each check, quietly — unless the
                // driver said no.
                let staleStaged = self.stagedFasterRoute.map {
                    Date().timeIntervalSince($0.stagedAt) >= Self.stagedFasterRouteMaxAge
                } ?? false
                let weighAgain = !self.trafficOfferDeclined
                    && (self.trafficOfferBlocked || self.trafficOfferNeedsWeigh || staleStaged)
                if let minutes = newDelay, self.trafficDelayMinutes == nil || weighAgain {
                    let outcome = await self.weighFasterRoute(
                        leg: leg, minutes: minutes, fresh: self.trafficDelayMinutes == nil)
                    if outcome == .leftLeg { return }   // a new leg runs its own watch
                }
                if newDelay == nil { self.clearTrafficOffer() }
                self.trafficDelayMinutes = newDelay
            }
        }
    }

    /// Measure what this stretch of road actually cost: the fuel burned
    /// covering it at the economy the vehicle was achieving. Filed by
    /// neighbourhood and road class (RoadEfficiencyLearning).
    private func recordRoadEfficiency(deltaMeters: Double, fix: CLLocation) {
        guard let profile = vehicle.profile, deltaMeters > 0 else { return }
        let miles = deltaMeters / 1609.344
        let mph = max(fix.speed, 0) * 2.236936
        // The vehicle's speed-aware curve is the best per-instant estimate of
        // burn rate available without an OBD fuel-flow reading; measuring
        // against it is what surfaces the road's OWN penalty (hills, lights,
        // this driver's habits) rather than re-deriving the curve.
        let instantMPU = profile.milesPerUnit(atSpeedMph: mph)
        guard instantMPU > 0 else { return }
        roadEfficiency.record(deltaMiles: miles,
                              unitsBurned: miles / instantMPU,
                              area: TrafficArea(fix.coordinate),
                              roadClass: RoadClass.from(averageMph: mph))
    }

    /// The economy to PLAN with here: measured where this device has driven
    /// enough to know, the vehicle's rated curve everywhere else.
    var plannedEconomyMPU: Double? {
        guard let profile = vehicle.profile else { return nil }
        return roadEfficiency.economy(
            ratedMilesPerUnit: profile.ratedMilesPerUnit,
            area: location.coordinate.map(TrafficArea.init) ?? .pooled,
            roadClass: currentRoadClass)
    }

    /// Live wind on the corridor, from the forecast the risk engine already
    /// fetched — speed and the direction it blows FROM. Feeds the efficiency
    /// score, where a headwind is air the vehicle has to push.
    @Published private(set) var corridorWindMph: Double = 0
    @Published private(set) var corridorWindFromDegrees: Double?

    private var windLookupTask: Task<Void, Never>?
    private var lastWindLookup = Date.distantPast

    /// Refresh the wind on this stretch — slow cadence, since wind is a
    /// weather-scale quantity, and it only feeds the efficiency icon.
    private func updateCorridorWind(near point: CLLocationCoordinate2D) {
        guard mode == .navigating,
              Date().timeIntervalSince(lastWindLookup) > 300 else { return }
        lastWindLookup = Date()
        windLookupTask?.cancel()
        windLookupTask = Task { [weak self] in
            guard let c = await NWSForecastFetcher.shared.conditions(at: point),
                  let self, !Task.isCancelled else { return }
            guard self.mode == .navigating else { return }   // landed after End
            let mph = c.windMph ?? 0
            if self.corridorWindMph != mph { self.corridorWindMph = mph }
            if self.corridorWindFromDegrees != c.windFromDegrees {
                self.corridorWindFromDegrees = c.windFromDegrees
            }
        }
    }

    /// The coarse weather bucket the delay model learns on, from the risk
    /// engine's own corridor scoring — no new data source.
    var currentTrafficWeather: TrafficWeather {
        let worst = navigation.route.flatMap {
            RiskEquations.peakFamily($0.familyPeaks, floor: FlowsCore.riskGreenMin)
        }
        return TrafficWeather.from(family: worst)
    }

    /// What this route was predicted to take when the driver accepted it —
    /// the "predicted" half of the delay model's training pair.
    private var tripPredictedSeconds: Double?
    private var tripStartedAt: Date?
    /// Where the trip began — which neighbourhood's learning it belongs to.
    private var tripStartArea: TrafficArea?
    private var tripDistanceMeters: Double = 0
    /// The driver erased what FLOWS learned during this trip: its arrival
    /// records nothing about it (cleared at the next GO).
    private var tripLearningErased = false

    /// The kind of road being driven right now, from the vehicle's own
    /// rolling average speed.
    var currentRoadClass: RoadClass {
        RoadClass.from(averageMph: vehicle.averageSpeedMph)
    }

    /// Fold the finished trip into the learned model: what the router
    /// promised vs. what the clock actually showed.
    private func learnTripDuration() {
        defer {
            tripPredictedSeconds = nil; tripStartedAt = nil
            tripStartArea = nil; tripDistanceMeters = 0
        }
        guard let predicted = tripPredictedSeconds, let started = tripStartedAt else { return }
        // Only a trip that actually ARRIVED knows what the drive took. This
        // ran on every End press, so a drive abandoned halfway — or a driver
        // who parked at the destination and pressed End an hour later —
        // taught the model a duration that was never a drive.
        guard arrivedAt != nil else { return }
        let actual = Date().timeIntervalSince(started) - stopDelaySeconds - shelteredSecondsBanked
        // Only whole trips teach anything: a drive abandoned after two
        // minutes says nothing about how long the route takes.
        guard actual > 300, actual < predicted * 4 else { return }
        // Classify by the trip's own average pace, and file local roads
        // under the neighbourhood they were driven in.
        let miles = tripDistanceMeters / 1609.344
        let avgMph = actual > 0 ? miles / (actual / 3600) : 0
        trafficModel.record(predictedSeconds: predicted, actualSeconds: actual,
                            area: tripStartArea ?? .pooled,
                            roadClass: RoadClass.from(averageMph: avgMph),
                            weather: currentTrafficWeather)
    }

    /// Whether FLOWS may weigh taking a faster road on its own right now: a
    /// driving leg, on route, nothing being replanned or added, the trip not
    /// over, and no safety prompt on screen (a warning, a rising-risk prompt
    /// or a crash check-in comes first).
    private func fasterRouteEligible(_ leg: PlannedRoute) -> Bool {
        leg.route.transportType == .automobile && !leg.isWalkingEstimate
            && !walkingMode && !isPassengerTransit
            && navigation.guidance?.isOffRoute != true && !navigation.isRerouting
            && !addingStop && arrivedAt == nil && driverReroutesInFlight == 0
            && escalation == nil && imminentWarning == nil && crash.state == .idle
    }

    /// A faster road FLOWS weighed: its verdict, the road to drive (scored at
    /// the usual spacing) and its feeds (nil when nothing was scored), the
    /// minutes it saves, the risk it was weighed at, and its line with the
    /// point where it leaves the current road.
    private struct FasterRouteCheck {
        var verdict: FasterRoutePolicy.Verdict
        var route: PlannedRoute? = nil
        var feeds: CorridorFeeds? = nil
        /// Against the current road's own time from the router; nil when the
        /// router didn't hand that road back, and the saving can't be told.
        var savedMinutes: Int? = nil
        /// The candidate's risk from the car forward, its detour checked;
        /// nil when its score didn't finish.
        var candidateRisk: Double? = nil
        /// Red somewhere ahead on it: never taken, never offered.
        var candidateRed = false
        /// Its band is above the current road's, both scored the same way:
        /// the offer says so.
        var moreRisk = false
        var line: [CLLocationCoordinate2D] = []
        var divergeAlong: CLLocationDistance? = nil
        /// The check-point spacing its detour was weighed at.
        var checkSpacing = FasterRoutePolicy.corridorCheckMeters
    }

    /// `scoredWithFeeds`'s road alone, for a road that is only compared
    /// with (its feeds are not kept); nil in, nil out.
    private func scoredForComparison(_ route: PlannedRoute?,
                                     everyMeters: CLLocationDistance) async -> PlannedRoute? {
        guard let route else { return nil }
        return await scoredWithFeeds(route, everyMeters: everyMeters).route
    }

    /// Weigh a faster road for the current leg (owner item 9). It plans to
    /// the end of THIS leg, so an added stop is never dropped; keeps the
    /// driver's road choices; must save FLOWS's "same time" tolerance against
    /// the current road's own time; is scored without taking over the trip's
    /// feeds; and is compared with the current road scored the same way at
    /// the same moment, both from the car forward, with check points on the
    /// stretches where they differ. nil when no plan came back.
    private func evaluateFasterRoute(leg: PlannedRoute) async -> FasterRouteCheck? {
        guard let fix = location.coordinate, let end = Self.lastCoordinate(of: leg),
              let raw = try? await router.planRoutes(
                  from: fix, fromName: "Current location", to: end, toName: leg.destinationName,
                  includeTollFree: leg.planKind == .tollFree || !leg.hasTolls
                      || routeFilters.contains(.noTolls)),
              !raw.isEmpty else { return nil }
        let planned = RouteService.applyPersonalPace(
            raw, multiplier: DrivingProfileStore.shared.etaMultiplier)
        // The current road is the plan that never leaves the leg's line; the
        // rest are where each one leaves it and comes back.
        let legLine = FasterRoutePolicy.coordinates(of: leg.route.polyline)
        let lines = planned.map { FasterRoutePolicy.coordinates(of: $0.route.polyline) }
        let spans = lines.map { FasterRoutePolicy.offLineSpans(candidate: $0, road: legLine) }
        let sameRoad = planned.indices.first { spans[$0].isEmpty }.map { planned[$0] }
        guard let c = planned.indices.first(where: {
            !spans[$0].isEmpty && FasterRoutePolicy.keepsRoadChoice(planned[$0], leg: leg,
                                                                    filters: routeFilters)
        }) else { return FasterRouteCheck(verdict: .notFaster) }
        let candidate = planned[c]
        // The saving is told only against the router's own time for the
        // current road. The traffic probe times MapKit's best path to a point
        // ahead, which may be the detour itself: set against it, a real
        // detour read as no faster.
        if let current = sameRoad,
           !FasterRoutePolicy.savesEnough(currentSeconds: current.eta, candidateSeconds: candidate.eta) {
            return FasterRouteCheck(verdict: .notFaster)
        }
        // Check points every 40 km miss a 10 km detour: the roads would be
        // compared on the points they share. Both are weighed closer; the road
        // to drive keeps the usual spacing, which the corridor watch indexes.
        // Sized to the longer road: the current one is scored at the same
        // spacing, and a check point past the cap would miss its forecast.
        let spacing = FasterRoutePolicy.checkSpacing(
            spans: spans[c],
            candidateMeters: max(candidate.distanceMeters, sameRoad?.distanceMeters ?? 0))
        let closer = spacing < FasterRoutePolicy.corridorCheckMeters
        let (driven, weighedCandidate, weighedCurrent) = await RequestGate.shared.withPlanningBurst {
            async let drivenF = self.scoredWithFeeds(candidate)
            async let candidateF = self.scoredForComparison(closer ? candidate : nil, everyMeters: spacing)
            async let currentF = self.scoredForComparison(sameRoad, everyMeters: spacing)
            return (await drivenF, await candidateF, await currentF)
        }
        let (scored, feeds) = driven
        let weighed = weighedCandidate ?? scored
        // From the car forward on both: the check point at the car is where
        // the car already is, whichever road it takes (1 m in counts only the
        // first stretch's forward end, like the leg's point just behind).
        let candidateRisk = FasterRoutePolicy.aheadRisk(of: weighed, alongMeters: 1)
        var ahead = weighedCurrent.flatMap { FasterRoutePolicy.aheadRisk(of: $0, alongMeters: 1) }
        let sameMoment = ahead != nil
        if !sameMoment {
            // The router didn't hand back the current road (or its score
            // didn't finish): the live leg's own score, read after the awaits.
            let live = navigation.route?.id == leg.id ? navigation.route : nil
            ahead = live.flatMap {
                FasterRoutePolicy.aheadRisk(of: $0, alongMeters: navigation.guidance?.alongMeters ?? 0)
            }
        }
        // What the driver filters on that the new road can't be checked for
        // before it starts: a rig's bridges, weights and grades, and flood
        // zones (FEMA loads with the leg). FLOWS asks instead.
        let limitsUnchecked = towingActive || truckerUI
            || !routeFilters.isDisjoint(with: [.lowBridges, .bridgeWeight, .mountainGrades,
                                               .noFloodRisk])
        var verdict = FasterRoutePolicy.riskVerdict(
            candidateRisk: candidateRisk, aheadRisk: ahead, limitsUnchecked: limitsUnchecked)
        let bandsRiskier = FasterRoutePolicy.riskVerdict(
            candidateRisk: candidateRisk, aheadRisk: ahead, limitsUnchecked: false) == .riskier
        if !sameMoment, let candidateRisk,
           [.yellow, .red].contains(FlowsCore.riskBand(score: candidateRisk)) {
            // The live leg isn't scored the way a fresh plan is: against it,
            // only a Clear or Green road is taken without asking, and a
            // higher band isn't called "more risk".
            verdict = .unknown
        }
        // Without the current road's own time, the saving can't be told.
        if sameRoad == nil, verdict == .switchNow { verdict = .unknown }
        // Nor can the risk when a stretch where the roads differ has no check
        // point on it.
        if verdict == .switchNow, !FasterRoutePolicy.detourChecked(spans: spans[c], on: weighed) {
            verdict = .unknown
        }
        // High winds, set against the current road: a road the driver's No
        // high winds filter refuses is riskier for them only when it is
        // windier than the one they're on (the car's own cell counts on both).
        if verdict != .riskier, routeFilters.contains(.noHighWinds),
           !RouteFilter.noHighWinds.passes(weighed) {
            if sameMoment, let current = weighedCurrent {
                if RouteFilter.noHighWinds.passes(current)
                    || FasterRoutePolicy.riskVerdict(candidateRisk: weighed.familyPeaks["wind"],
                                                     aheadRisk: current.familyPeaks["wind"],
                                                     limitsUnchecked: false) == .riskier {
                    verdict = .riskier
                }
            } else if verdict == .switchNow {
                verdict = .unknown
            }
        }
        var switched = scored
        switched.planKind = leg.planKind   // later replans keep the driver's choice
        let saved = sameRoad.map { max(Int((($0.eta - scored.eta) / 60).rounded()), 1) }
        // An unfinished score that already shows red is red, on either score.
        let red = [candidateRisk ?? weighed.weatherRisk,
                   FasterRoutePolicy.aheadRisk(of: scored, alongMeters: 1) ?? scored.weatherRisk]
            .contains { FlowsCore.riskBand(score: $0) == .red }
        FlowsDiag.log(.info, "traffic",
                      "faster route: \(verdict) saves \(saved.map { "\($0)" } ?? "?") min "
                      + "same-moment \(sameMoment) spacing \(Int(spacing)) m")
        return FasterRouteCheck(
            verdict: verdict, route: switched, feeds: feeds, savedMinutes: saved,
            candidateRisk: candidateRisk, candidateRed: red,
            moreRisk: verdict == .riskier || (sameMoment && bandsRiskier),
            line: lines[c], divergeAlong: spans[c].first?.from, checkSpacing: spacing)
    }

    /// What weighing a jam came to: FLOWS moved to a new leg (or the trip
    /// moved on under it), or the watch carries on.
    private enum FasterRouteOutcome { case leftLeg, settled }

    /// Weigh a faster road for this jam and act on it (owner item 9): take
    /// it, offer it, or say there's none worth taking and look again next
    /// check. `fresh`: the jam is new; a jam weighed before with nothing to
    /// take, or offered with nothing weighed, is weighed again quietly.
    private func weighFasterRoute(leg: PlannedRoute, minutes: Int,
                                  fresh: Bool) async -> FasterRouteOutcome {
        // A watch cancelled while its probe was out must not act on the new
        // leg: it runs its own watch.
        guard !Task.isCancelled, navigation.route?.id == leg.id else { return .leftLeg }
        guard fasterRouteEligible(leg) else {
            // A safety prompt, a replan or a walk comes first: the plain
            // offer, as before, weighed again next check.
            if fresh { offerPlainFasterRoute(minutes: minutes) }
            return .settled
        }
        let gen = tripGeneration
        let check = await evaluateFasterRoute(leg: leg)
        // A leg swap or a new trip restarted the watch.
        guard !Task.isCancelled, mode == .navigating, gen == tripGeneration,
              navigation.route?.id == leg.id else { return .leftLeg }
        guard let check else {
            // No plan came back: the plain offer, weighed again next check.
            if fresh { offerPlainFasterRoute(minutes: minutes) }
            return .settled
        }
        // The "nothing to take" line speaks for the chip: none with the
        // chips off.
        let saysWhy = fresh && notifyTraffic
        guard let route = check.route else {
            blockFasterRoute(saying: saysWhy ? SiriSummaries.trafficNoFasterRoute(minutes: minutes) : nil)
            return .settled
        }
        if check.candidateRed {
            // A yes could never be carried out: say so instead of asking.
            blockFasterRoute(saying: saysWhy ? SiriSummaries.fasterRouteRefusedRed(minutes: minutes) : nil)
            return .settled
        }
        // The road was planned from where the car was before it was scored:
        // past its turn-off, it is no faster road at all.
        guard let here = location.coordinate,
              FasterRoutePolicy.canStillTake(candidate: check.line,
                                             divergeAlong: check.divergeAlong,
                                             position: here, speedMps: location.speed)
        else {
            blockFasterRoute(saying: saysWhy ? SiriSummaries.trafficNoFasterRoute(minutes: minutes) : nil)
            return .settled
        }
        if check.verdict == .switchNow, let saved = check.savedMinutes,
           fasterRouteEligible(leg) {   // nothing came up meanwhile
            takeFasterRoute(route, feeds: check.feeds, automaticSaving: saved)
            return .leftLeg   // startLeg started the new leg's watch
        }
        let wasBlocked = trafficOfferBlocked
        guard let candidateRisk = check.candidateRisk else {
            // Its score didn't finish: the plain offer, weighed again next
            // check; a yes meanwhile plans and scores afresh (refusing red).
            stagedFasterRoute = nil
            if fresh || wasBlocked { offerPlainFasterRoute(minutes: minutes) }
            trafficOfferNeedsWeigh = true
            return .settled
        }
        // A yes takes the road that was weighed: to the end of this leg,
        // with the driver's road choices.
        stagedFasterRoute = StagedFasterRoute(
            legID: leg.id, route: route, line: check.line, divergeAlong: check.divergeAlong,
            checkSpacing: check.checkSpacing, offeredRisk: candidateRisk, stagedAt: Date())
        trafficOfferNeedsWeigh = false
        if fresh || wasBlocked || (check.moreRisk && !trafficOfferRiskier) {
            // Said aloud when new, when it follows "no faster road", or when
            // the road on offer now has more risk than the driver was told.
            offerFasterRoute(minutes: minutes, riskier: check.moreRisk)
        } else {
            trafficOfferRiskier = check.moreRisk
        }
        return .settled
    }

    /// Nothing to take for this jam: the chip keeps the delay with no
    /// button, no yes is listened for, and each check looks again. `saying`:
    /// the line spoken, once per jam.
    private func blockFasterRoute(saying line: String?) {
        trafficOfferBlocked = true
        trafficOfferRiskier = false
        trafficOfferNeedsWeigh = false
        stagedFasterRoute = nil
        if case .fasterRoute? = pendingVoiceOffer { pendingVoiceOffer = nil }
        if let line, voiceAlerts {
            VoiceAnnouncer.shared.announce(line, topic: SpeechTopic.trafficOffer)
        }
    }

    /// The offer as before item 9, with nothing weighed: a yes plans afresh.
    /// Each check weighs it again until there's a road to stage or take.
    private func offerPlainFasterRoute(minutes: Int) {
        stagedFasterRoute = nil
        offerFasterRoute(minutes: minutes, riskier: false)
        trafficOfferNeedsWeigh = true
    }

    /// Put the faster-route offer up: the chip's button, a haptic, the spoken
    /// ask, and a listen for the plain yes or no right after it. No clear
    /// answer = the chip stays on screen; nothing is guessed. A no stands for
    /// the jam: FLOWS stops weighing it and never switches on its own. The
    /// offer lives on the traffic chip, so with the chips off FLOWS makes
    /// none of its own; `driverAsked`: a yes the driver gave that has to be
    /// asked again, answered either way.
    private func offerFasterRoute(minutes: Int, riskier: Bool, driverAsked: Bool = false) {
        trafficOfferBlocked = false
        trafficOfferRiskier = riskier
        guard notifyTraffic || driverAsked else { return }
        if hapticAlerts { Haptics.offer() }   // chip just appeared
        // A trip planned mid-drive is waiting for its spoken yes: "go ahead"
        // stays that trip's, and the faster road is offered on the chip only.
        if case .trip? = pendingVoiceOffer { return }
        pendingVoiceOffer = .fasterRoute
        guard voiceAlerts else { return }
        VoiceAnnouncer.shared.announce(
            SiriSummaries.fasterRouteOffer(minutes: minutes, riskier: riskier),
            topic: SpeechTopic.trafficOffer)
        VoiceReply.shared.listenAfterSpeech { [weak self] answer in
            guard let self, case .fasterRoute? = self.pendingVoiceOffer else { return }
            if answer == true {
                Task { await self.rerouteForTraffic() }
            } else if answer == false {
                self.pendingVoiceOffer = nil
                self.trafficOfferDeclined = true
            }
        }
    }

    /// Take a faster road FLOWS weighed. Like a missed turn, the escalation
    /// state carries across (the driver's Continue still stands); like the
    /// manual traffic reroute, the leg starts afresh. `automaticSaving`: the
    /// minutes saved when FLOWS took it on its own (no more risk), said and
    /// shown; nil for a road the driver said yes to, which needs neither.
    private func takeFasterRoute(_ route: PlannedRoute, feeds: CorridorFeeds?,
                                 automaticSaving savedMinutes: Int?) {
        let toFinal = upcomingLeg == nil && pendingStopName == nil
        let accepted = escalationState
        startLeg(route)
        escalationState = accepted
        // A leg to an added stop must not hand its box to the trip.
        if toFinal, let feeds { adoptCorridorFeeds(feeds) }
        guard let savedMinutes else { return }
        if hapticAlerts { Haptics.offer() }
        if voiceAlerts {
            VoiceAnnouncer.shared.announce(SiriSummaries.fasterRouteTaken(minutes: savedMinutes))
        }
        // After startLeg, which clears it with the old leg's traffic state.
        fasterRouteSavedMinutes = savedMinutes
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            if self?.fasterRouteSavedMinutes == savedMinutes { self?.fasterRouteSavedMinutes = nil }
        }
    }

    /// What a yes to the traffic offer came to, so Siri's reply matches what
    /// FLOWS did (and said).
    enum TrafficRerouteOutcome {
        /// On the faster road.
        case taken
        /// Staying: the road turned red, its turn-off passed, or nothing was
        /// on offer. FLOWS has said why.
        case stayed
        /// Its risk rose since the offer: FLOWS asked again.
        case askedAgain
        /// Nothing came of it: no plan, or the trip moved on.
        case nothing
    }

    /// A yes to the road FLOWS weighed and offered. Alerts change in
    /// minutes, so it is scored again first: refused when it has turned red
    /// or the car has passed its turn-off meanwhile, asked again when its
    /// level has risen since the offer, else taken. `minutes`: the delay the
    /// chip showed, put back when FLOWS stays.
    private func takeStagedFasterRoute(_ staged: StagedFasterRoute,
                                       minutes: Int) async -> TrafficRerouteOutcome {
        let gen = tripGeneration
        let closer = staged.checkSpacing < FasterRoutePolicy.corridorCheckMeters
        let (driven, weighedAgain) = await RequestGate.shared.withPlanningBurst {
            async let drivenF = self.scoredWithFeeds(staged.route)
            async let weighedF = self.scoredForComparison(closer ? staged.route : nil,
                                                          everyMeters: staged.checkSpacing)
            return (await drivenF, await weighedF)
        }
        guard mode == .navigating, gen == tripGeneration,
              navigation.route?.id == staged.legID else { return .nothing }
        let (scored, feeds) = driven
        let weighed = weighedAgain ?? scored
        let risk = FasterRoutePolicy.aheadRisk(of: weighed, alongMeters: 1) ?? weighed.weatherRisk
        let drivenRisk = FasterRoutePolicy.aheadRisk(of: scored, alongMeters: 1) ?? scored.weatherRisk
        let stay: String?
        if [risk, drivenRisk].contains(where: { FlowsCore.riskBand(score: $0) == .red }) {
            stay = SiriSummaries.fasterRouteNowRed
        } else if let here = location.coordinate,
                  FasterRoutePolicy.canStillTake(candidate: staged.line,
                                                 divergeAlong: staged.divergeAlong,
                                                 position: here, speedMps: location.speed) {
            stay = nil
        } else {
            stay = SiriSummaries.fasterRoutePassed
        }
        if let stay {
            trafficDelayMinutes = minutes   // the jam is still there
            blockFasterRoute(saying: stay)
            return .stayed
        }
        var route = scored
        route.planKind = staged.route.planKind
        if FasterRoutePolicy.riskVerdict(candidateRisk: risk, aheadRisk: staged.offeredRisk,
                                         limitsUnchecked: false) == .riskier {
            // The yes was to less risk than this: ask again, saying so.
            trafficDelayMinutes = minutes
            stagedFasterRoute = StagedFasterRoute(
                legID: staged.legID, route: route, line: staged.line,
                divergeAlong: staged.divergeAlong, checkSpacing: staged.checkSpacing,
                offeredRisk: risk, stagedAt: Date())
            offerFasterRoute(minutes: minutes, riskier: true, driverAsked: true)
            return .askedAgain
        }
        takeFasterRoute(route, feeds: feeds, automaticSaving: nil)
        return .taken
    }

    /// Traffic chip's action: take the faster road FLOWS weighed, or plan one.
    @discardableResult
    func rerouteForTraffic() async -> TrafficRerouteOutcome {
        guard let fix = location.coordinate else { return .nothing }
        // Nothing on offer: the only faster road is red, or none is faster.
        guard !trafficOfferBlocked else { return .stayed }
        driverReroutesInFlight += 1
        defer { driverReroutesInFlight -= 1 }
        let staged = stagedFasterRoute
        let minutes = trafficDelayMinutes
        trafficDelayMinutes = nil
        clearTrafficOffer()   // drops the traffic yes; a trip waiting for its yes keeps it
        // The yes is to the road FLOWS weighed and offered: that one (to the
        // end of this leg, a stop kept, the driver's road choices kept), while
        // it is fresh and the car can still reach its turn-off.
        if let staged, let minutes, staged.legID == navigation.route?.id, mode == .navigating,
           Date().timeIntervalSince(staged.stagedAt) < Self.stagedFasterRouteMaxAge,
           FasterRoutePolicy.canStillTake(candidate: staged.line,
                                          divergeAlong: staged.divergeAlong,
                                          position: fix, speedMps: location.speed) {
            return await takeStagedFasterRoute(staged, minutes: minutes)
        }
        // Nothing weighed to take (the offer went up while a safety prompt
        // was on screen, its plan failed or its score didn't finish), or the
        // road weighed went stale or its turn-off passed: weigh one now, as
        // the watch does — to the end of THIS leg (a stop kept) with the
        // driver's road choices — and answer the yes as a yes to a weighed
        // road is answered. This used to plan a car route to the final
        // destination (dropping an added stop), cleared the chip for good on
        // a no-go, and spoke its red refusal with the voice off.
        guard let minutes, mode == .navigating, let leg = navigation.route else { return .nothing }
        guard leg.route.transportType == .automobile, !leg.isWalkingEstimate else {
            // A walk has no faster road for cars to take: the delay stays
            // on show with nothing to press.
            trafficDelayMinutes = minutes
            blockFasterRoute(saying: nil)
            return .stayed
        }
        let gen = tripGeneration
        let stop = pendingStopName
        let check = await evaluateFasterRoute(leg: leg)
        // A new trip, a leg swap or the stop reached meanwhile: the new leg
        // runs its own watch.
        guard mode == .navigating, gen == tripGeneration, arrivedAt == nil,
              pendingStopName == stop, navigation.route?.id == leg.id else { return .nothing }
        guard let check else {
            // No plan came back: the jam is still there, and the next check
            // weighs it again.
            trafficDelayMinutes = minutes
            blockFasterRoute(saying: SiriSummaries.trafficNoFasterRoute(minutes: minutes))
            return .nothing
        }
        let stay: String?
        if check.route == nil {
            stay = SiriSummaries.trafficNoFasterRoute(minutes: minutes)
        } else if check.candidateRed {
            // The yes was to a saving, never to a red road.
            stay = SiriSummaries.fasterRouteNowRed
        } else if let here = location.coordinate,
                  FasterRoutePolicy.canStillTake(candidate: check.line,
                                                 divergeAlong: check.divergeAlong,
                                                 position: here, speedMps: location.speed) {
            stay = nil
        } else {
            stay = SiriSummaries.fasterRoutePassed
        }
        guard stay == nil, let route = check.route else {
            trafficDelayMinutes = minutes   // the jam is still there
            blockFasterRoute(saying: stay)
            return .stayed
        }
        // Asked again when the road has more risk than the yes was to: than
        // the road offered, when one was weighed (as a yes to a weighed road
        // is asked), else than the plain offer, which named none.
        let offered = staged.flatMap { $0.legID == leg.id ? $0.offeredRisk : nil }
        let riskier: Bool
        if let offered, let candidateRisk = check.candidateRisk {
            riskier = FasterRoutePolicy.riskVerdict(candidateRisk: candidateRisk, aheadRisk: offered,
                                                    limitsUnchecked: false) == .riskier
        } else {
            riskier = check.moreRisk
        }
        if riskier {
            trafficDelayMinutes = minutes
            stagedFasterRoute = StagedFasterRoute(
                legID: leg.id, route: route, line: check.line, divergeAlong: check.divergeAlong,
                checkSpacing: check.checkSpacing,
                offeredRisk: check.candidateRisk ?? route.weatherRisk, stagedAt: Date())
            // Every caller is the driver's yes: asked again with the chips
            // off too, as a weighed road's yes is.
            offerFasterRoute(minutes: minutes, riskier: true, driverAsked: true)
            return .askedAgain
        }
        takeFasterRoute(route, feeds: check.feeds, automaticSaving: nil)
        return .taken
    }

    /// The off-route replan (NavigationEngine.onReroute). It used to swap
    /// in place: the line lost its risk colours for the rest of the trip,
    /// and the corridor watch, the stops search and the Watch stayed on the
    /// road the driver had left. It now starts as a leg like any other.
    /// Guidance moves to the new road at once — a lost driver can't wait on
    /// scoring — so the score lands afterwards and is folded into the live
    /// leg. Any stop still pending stays: the replan runs to the end of this
    /// leg, not the trip.
    ///
    /// A missed turn is not a new choice, so two things carry across the
    /// swap that a chosen leg resets: the escalation state (the driver's
    /// Continue on an alert still stands, and the risk they accepted is still
    /// the yardstick — a replan onto a worse road must not quietly become the
    /// new normal) and the pace learner's leg clock (the stop and shelter
    /// time subtracted at arrival counts from the leg's start, not the
    /// replan's). Answers false when there is no trip to replan.
    private func startRerouteLeg(_ replanned: PlannedRoute) -> Bool {
        guard mode == .navigating, arrivedAt == nil else { return false }
        var leg = RouteService.applyPersonalPace(
            [replanned], multiplier: DrivingProfileStore.shared.etaMultiplier)[0]
        // Until the new road is scored it carries the old road's verdict.
        if let old = navigation.route {
            leg.weatherRisk = old.weatherRisk
            leg.alertHeadlines = old.alertHeadlines
        }
        let accepted = escalationState
        let started = legStartedAt, predicted = legPredictedSeconds
        startLeg(leg)
        escalationState = accepted
        legStartedAt = started
        legPredictedSeconds = predicted
        let gen = tripGeneration
        // A replan to an added stop must not hand its small box's closures
        // and live feeds to the trip: the continuation leg scored them for
        // the rest of the drive.
        let toFinal = upcomingLeg == nil && pendingStopName == nil
        Task { [weak self] in
            // Retried with backoff while a weather fetch keeps failing, as the
            // route cards are: nothing else re-scores a leg once it is driven.
            for delay in [0.0, 6, 15, 30, 60] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard let self, self.mode == .navigating, gen == self.tripGeneration,
                      self.navigation.route?.id == leg.id else { return }
                let scored = await self.scoredBurst(leg, adoptTripFeeds: toFinal)
                guard self.mode == .navigating, gen == self.tripGeneration,
                      var live = self.navigation.route, live.id == leg.id else { return }
                let carried = (risk: live.weatherRisk, headlines: live.alertHeadlines)
                live.takeScore(from: scored)
                if !scored.weatherScored {
                    // A failed cell scores 0, and unknown is never clear: an
                    // incomplete score may raise the carried verdict, never
                    // lower it.
                    live.weatherRisk = max(live.weatherRisk, carried.risk)
                    for h in carried.headlines where !live.alertHeadlines.contains(h) {
                        live.alertHeadlines.append(h)
                    }
                }
                self.navigation.updateRouteMetadata(live)
                self.routeMetadataVersion &+= 1
                if scored.weatherScored { return }
            }
        }
        return true
    }

    // MARK: POI stop chaining

    /// Add the nearest POI as the NEXT stop: navigate there now; on arrival
    /// automatically replan to the original destination.
    /// True while an added stop's legs are being planned — the HUD shows a
    /// progress banner (a silent multi-second wait read as a freeze).
    @Published var addingStop = false
    /// The stop was reached but no way on to the destination could be
    /// planned. Its own banner: this used to be written into arrivedAt, so
    /// the HUD said "Arrived" over a truncated sentence about a "leg".
    @Published var continuationFailure: String?
    /// Bumped when the DRIVEN route's samples/segments/polygons are refreshed
    /// from a live corridor score, so the map's `.task(id:)` rebuilds the
    /// hazard shapes — the route id alone does not change.
    @Published var routeMetadataVersion = 0

    /// Where the vehicle effectively is: the GPS fix, or the route start
    /// when previewing without one (macOS without location access). Keeps
    /// POI search and add-stop working instead of silently no-op'ing.
    var effectivePosition: CLLocationCoordinate2D? {
        location.coordinate ?? navigation.route.flatMap { Self.firstCoordinate(of: $0) }
    }

    /// The best guess at where the driver is, for a starting point and a
    /// map centre: the GPS fix; else the saved Home; else the centre of the
    /// learned everyday area. A Mac usually has no fix at all, and before
    /// this it framed the whole continent and refused to plan without a
    /// typed start.
    var bestKnownPosition: (coordinate: CLLocationCoordinate2D, label: String)? {
        if let fix = location.coordinate { return (fix, "Current location") }
        if let home = favorites.favorites.first(where: { $0.symbol == .home }) {
            return (home.coordinate, "Home")
        }
        if let anchor = EverydayPlaces.shared.homeAnchor { return (anchor, "Your usual area") }
        return nil
    }

    /// Append a stop to the CURRENT route: plan both legs immediately —
    /// (here → stop) to drive now and (stop → final destination) to continue
    /// with — so the map shows the whole amended trip, and arrival at the
    /// stop seamlessly rolls into the continuation.
    /// Returns whether the first leg actually started. Siri used to infer
    /// success by comparing pendingStopName against a name it had derived
    /// separately — two different fallbacks for a nil place name, so the
    /// check could fail on a stop that had in fact been added.
    @discardableResult
    func addStop(_ item: MKMapItem) async -> Bool {
        // The old guard returned SILENTLY without a GPS fix — on a Mac in
        // preview mode that read as "add stop freezes". Fall back to the
        // route-start position and always show progress.
        guard let fix = effectivePosition, let dest = finalDestination,
              let leg = navigation.route else { return false }
        let name = item.name ?? "Stop"
        pendingStopName = name
        // Classify the ITEM, not the browse mode. This read poi.activeKind
        // — a global "which stop button is lit" flag that survives closing
        // the results card. So a driver who checked fuel prices, decided to
        // wait, and later added a coffee stop had that coffee stop recorded
        // as a fill-up: arriving reset the tank odometer, range jumped from
        // 55 miles to 450, the low-fuel warning cleared, and the app stopped
        // warning about an empty tank.
        //
        // The else-branch is the safe direction: a missed reset only leaves
        // the range pessimistic, which the at-pump prompt and "Mark tank
        // full" both recover. A false reset hides a real empty tank.
        let addedFuel = item.pointOfInterestCategory == .gasStation
            || item.pointOfInterestCategory == .evCharger
            || (poi.activeKind == .gas && poi.results.contains { $0.item === item })
        pendingStopKind = addedFuel ? .gas : nil
        poi.clearResults()
        addingStop = true
        defer { addingStop = false }
        // Only the SHORT hop (here → stop) blocks the UI — one directions
        // call, unscored. The continuation leg and all risk scoring happen
        // while the driver is already moving (the long-pause fix: the main
        // route is never re-derived up front). Both legs are planned the way
        // the leg being driven was and keep the driver's road choices and
        // filters (a rig's bridges and weights load first when there's a
        // choice): they used to be the router's first car route, so a walker
        // was sent down roads for cars and No tolls was forgotten.
        let gen = tripGeneration
        let hop = await withAttributesIfFiltered(await routes(
            like: leg, from: fix, fromName: "Current location",
            to: item.placemark.coordinate, toName: name))
        guard var leg1 = FasterRoutePolicy.swapPick(hop, leg: leg, filters: routeFilters,
                                                    limits: filterLimits, calmest: false)
        else { pendingStopName = nil; return false }
        // Driver may have ended/finished the trip while leg1 planned.
        guard mode == .navigating, gen == tripGeneration else { pendingStopName = nil; return false }
        leg1.planKind = leg.planKind   // later replans keep the driver's choice
        startLeg(leg1)
        Task { [weak self] in
            guard let self else { return }
            let onward = await self.withAttributesIfFiltered(await self.routes(
                like: leg, from: item.placemark.coordinate, fromName: name,
                to: dest.coordinate, toName: dest.name))
            guard var leg2 = FasterRoutePolicy.swapPick(onward, leg: leg, filters: self.routeFilters,
                                                        limits: self.filterLimits, calmest: false)
            else { return }
            leg2.planKind = leg.planKind
            let scored = await self.scored(leg2)
            // Don't reattach a phantom continuation leg after the user arrived
            // or ended navigation during this background plan+score.
            guard self.mode == .navigating, self.pendingStopName == name,
                  gen == self.tripGeneration else { return }
            self.upcomingLeg = scored
        }
        return true
    }

    /// Arrival at an added stop rolls into the pre-planned continuation leg;
    /// arrival at the final destination shows the arrived banner.
    private func handleArrival() {
        if let next = upcomingLeg {
            // Arriving at an added GAS stop = a fill-up: reset the tank
            // odometer feeding the range model.
            if pendingStopKind == .gas { vehicle.filledUp() }
            pendingStopKind = nil
            upcomingLeg = nil
            pendingStopName = nil
            startLeg(next, resetsNeeds: true)   // a stop: the food/rest clocks restart
            return
        }
        // Arrived at an ADDED STOP whose continuation leg isn't ready (the
        // background plan failed or hasn't landed) — this is NOT the final
        // destination: no arrived banner, no trip record. Replan the
        // continuation from here, the way the leg just driven was planned;
        // only a second failure surfaces honestly. (The engine arrives only
        // on a leg it has.)
        if let stopName = pendingStopName, let dest = finalDestination,
           let arrivedLeg = navigation.route {
            if pendingStopKind == .gas { vehicle.filledUp() }
            pendingStopKind = nil
            pendingStopName = nil
            // The leg to the stop is done: a faster-route check still in
            // flight for it must not start a new leg to the stop just reached
            // (its arrival would read as the final one). The continuation's
            // startLeg starts the next watch.
            trafficWatchTask?.cancel()
            trafficDelayMinutes = nil
            clearTrafficOffer()
            let gen = tripGeneration
            Task { [weak self] in
                guard let self else { return }
                let from = self.effectivePosition ?? dest.coordinate
                let onward = await self.withAttributesIfFiltered(await self.routes(
                    like: arrivedLeg, from: from, fromName: stopName,
                    to: dest.coordinate, toName: dest.name))
                if var leg = FasterRoutePolicy.swapPick(onward, leg: arrivedLeg,
                                                        filters: self.routeFilters,
                                                        limits: self.filterLimits, calmest: false) {
                    guard self.mode == .navigating, gen == self.tripGeneration else { return }
                    leg.planKind = arrivedLeg.planKind
                    let scored = await self.scoredBurst(leg)
                    guard self.mode == .navigating, gen == self.tripGeneration else { return }
                    self.startLeg(scored, resetsNeeds: true)
                } else if self.mode == .navigating {
                    // Honest state: at the stop, continuation unavailable.
                    // (Mode guard: if the driver ended navigation during the
                    // replan, don't post an arrival banner over planning.)
                    self.continuationFailure =
                        "Can't find a way on to \(dest.name) from here. Plan again."
                }
            }
            return
        }
        arrivedAt = finalDestination?.name ?? navigation.route?.destinationName
        // Learn from the completed trip: the plan-time prediction vs. the worst
        // risk actually encountered → the on-device seasonal model (frequency-
        // gated, decaying, bucketed by week-of-year). Final destination only,
        // and not a trip that began before an erase.
        if !tripLearningErased, let route = navigation.route,
           let origin = Self.firstCoordinate(of: route),
           let dest = finalDestination?.coordinate ?? Self.lastCoordinate(of: route) {
            let hubs = RouteService.corridorPartition(
                of: route.route.polyline, everyMeters: 3000).samples
            SeasonalRiskModel.shared.recordTrip(
                origin: origin, dest: dest,
                predicted: route.rankingRisk, observed: tripObservedPeak,
                distanceKm: route.distanceMeters / 1000, hubPath: hubs)
            // The everyday-radius cache learns the same trip (straight-line
            // start→end miles) — AFTER the seasonal record above, so the home
            // anchor it refreshes from already includes this trip.
            EverydayPlaces.shared.recordTrip(origin: origin, dest: dest)
            // Refit the route-risk head on this driver's own history when
            // enough new trips have accrued (warm-started from the shipped
            // baseline and anchored to it — see RouteHeadTrainer).
            SeasonalRiskModel.shared.fineTuneHeadIfDue()
        }
        // PERSONAL ETA CORRECTION: what the app promised vs what the drive
        // actually took, with chosen stops discounted. The app knew both
        // numbers and compared them nowhere. A walk teaches nothing about
        // how this person drives.
        if let started = legStartedAt, legPredictedSeconds > 0,
           navigation.route?.isWalk != true {
            DrivingProfileStore.shared.recordArrival(
                predicted: legPredictedSeconds,
                actual: Date().timeIntervalSince(started),
                stoppedSeconds: stopDelaySeconds + shelteredSecondsBanked)
        }
        legStartedAt = nil
        legPredictedSeconds = 0
        // Final destination reached: stop the background polling loops (corridor
        // NWS + traffic MKDirections) so a completed trip doesn't keep them
        // running — and draining battery/data — until the driver manually ends
        // navigation. Nav state stays up for the arrived banner; endNavigation()
        // does the full reset when they dismiss it.
        trafficWatchTask?.cancel()
        trafficDelayMinutes = nil
        clearTrafficOffer()
        fasterRouteSavedMinutes = nil
        alerts.endCorridorWatch()
        watch.sendArrived()
    }

    private static func lastCoordinate(of route: PlannedRoute) -> CLLocationCoordinate2D? {
        let poly = route.route.polyline
        let n = poly.pointCount
        guard n > 0 else { return nil }
        var last = CLLocationCoordinate2D()
        poly.getCoordinates(&last, range: NSRange(location: n - 1, length: 1))
        return last
    }

    private static func firstCoordinate(of route: PlannedRoute) -> CLLocationCoordinate2D? {
        let poly = route.route.polyline
        guard poly.pointCount > 0 else { return nil }
        var c = CLLocationCoordinate2D()
        poly.getCoordinates(&c, range: NSRange(location: 0, length: 1))
        return c
    }
}

@main
struct FLOWSApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Before anything reads the Keychain (AppModel is built after this).
        FreshInstall.clearLeftoversIfFresh()
        #if os(macOS)
        // Every text input in FLOWS is a place name, ZIP, or vehicle spec —
        // macOS inline predictions only ever "correct" those, and the gray
        // prediction sits as MARKED text: the click that dismisses it never
        // reaches its real target (the field-to-field / Plan-button click
        // swallow). SwiftUI exposes no per-field switch on macOS, so opt the
        // app out via AppKit's documented defaults keys.
        UserDefaults.standard.register(defaults: [
            "NSAutomaticTextCompletionEnabled": false,
            "NSAutomaticInlinePredictionEnabled": false,
        ])
        // AppKit CONSUMES the mouseDown that ends a text-field editing
        // session — a button under that click never fires ("the first Plan
        // click does nothing"), and SwiftUI's FocusState immediately
        // restores the editor, so the next click is eaten too. End the
        // session BEFORE dispatch when the click lands outside the editing
        // field; the same click then reaches its real target. App-wide: any
        // control next to any field gets first-click behavior.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard let window = event.window,
                  let editor = window.firstResponder as? NSTextView,
                  editor.isFieldEditor,
                  let content = window.contentView else { return event }
            let point = content.superview?.convert(event.locationInWindow, from: nil)
                ?? event.locationInWindow
            var view = content.hitTest(point)
            while let v = view {
                if v === editor { return event }   // click stays in the field
                view = v.superview
            }
            window.makeFirstResponder(nil)
            return event
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            // Text size is applied (and CLAMPED) at the root: the window's
            // width caps how large type may grow, so a giant system
            // accessibility size can't wrap cards into a smear on a phone;
            // the Settings slider picks a size inside the same cap.
            GeometryReader { geometry in
                ContentView()
                    .environmentObject(model)
                    .overlay {
                        // First launch: the one-message permission explainer;
                        // Get started fires the single up-front prompt.
                        if !model.onboarded {
                            WelcomeCard().environmentObject(model)
                        }
                    }
                    .dynamicTypeSize(TextScale.range(
                        chosenIndex: model.textSizeIndex,
                        maxIndex: model.textSizeMaxIndex))
                    .onAppear {
                        let idx = TextScale.maxStepIndex(forWidthPoints: geometry.size.width)
                        if idx != model.textSizeMaxIndex { model.textSizeMaxIndex = idx }
                    }
                    .onChange(of: geometry.size.width) { _, width in
                        // Every width change (keyboard, rotation, split view)
                        // republished the whole model even when the step
                        // index had not moved.
                        let idx = TextScale.maxStepIndex(forWidthPoints: width)
                        if idx != model.textSizeMaxIndex { model.textSizeMaxIndex = idx }
                    }
                    .onOpenURL { url in
                        // flows://smartcar?code=… — the OAuth callback.
                        if url.host == "smartcar" || url.absoluteString.contains("smartcar") {
                            Task { await model.smartcar.handleCallback(url: url) }
                        }
                    }
            }
            #if os(macOS)
            // On the reader itself: a GeometryReader reports no minimum of
            // its own, so a minimum set inside it never reached the window
            // and the window could still be dragged smaller than this.
            .frame(minWidth: 900, minHeight: 620)
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        // Below the content's minimum the Mac layout cannot keep its menus
        // apart: the settings panel alone needs 340 x 480 pt beside the map's
        // own chrome.
        .windowResizability(.contentMinSize)
        #endif
    }
}
