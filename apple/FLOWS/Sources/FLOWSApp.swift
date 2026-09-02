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
#if os(macOS)
import AppKit
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
            // the newly-highlighted route so each card's pins/counts are ITS own.
            if routeFilters.contains(.tourist), mode == .choosing,
               oldValue != highlightedRouteID {
                refreshTouristSpots()
            }
        }
    }

    /// (Re)pin attractions along the highlighted route (tourist filter).
    func refreshTouristSpots() {
        guard let route = routeChoices.first(where: { $0.id == highlightedRouteID })
            ?? routeChoices.first else { return }
        poi.beginCorridorSearch(along: route)
        let origin = lastPlanEndpoints?.from
        Task { await poi.request(.tourist, aheadOf: origin) }
    }

    /// Attractions within a worthwhile detour of THIS route's corridor.
    func touristCount(for route: PlannedRoute) -> Int {
        guard !poi.results.isEmpty, !route.riskSamples.isEmpty else { return 0 }
        return poi.results.filter { r in
            route.riskSamples.contains {
                POIRanking.meters($0.coordinate, r.item.placemark.coordinate) < 40_000
            }
        }.count
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
    /// vehicle's state changes (auto-switch on + something already playing).
    func retuneRadioIfNeeded(stateCode: String?) {
        guard radioAutoSwitch, radio.playingChannelID != nil,
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
    /// prices where licensed; state estimates otherwise.
    @Published var tomtomAPIKey: String =
        UserDefaults.standard.string(forKey: "flows.tomtomKey") ?? "" {
        didSet {
            UserDefaults.standard.set(tomtomAPIKey, forKey: "flows.tomtomKey")
            let key = tomtomAPIKey
            Task { await TomTomFuel.shared.setKey(key) }
        }
    }

    /// Route planning mode: driving or walking (Apple's pedestrian network —
    /// sidewalks/crossings where mapped, real walking pace).
    @Published var walkingMode = false {
        didSet {
            // People must not walk on highways; buses may use them.
            if walkingMode {
                routeFilters.insert(.noHighways)
            } else {
                routeFilters.remove(.noHighways)
            }
        }
    }
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
    @Published var googlePlacesAPIKey: String =
        UserDefaults.standard.string(forKey: "flows.googlePlacesKey") ?? "" {
        didSet {
            UserDefaults.standard.set(googlePlacesAPIKey, forKey: "flows.googlePlacesKey")
            let key = googlePlacesAPIKey
            Task { await GooglePlacesLink.shared.setKey(key) }
        }
    }

    @Published var yelpAPIKey: String =
        UserDefaults.standard.string(forKey: "flows.yelpKey") ?? "" {
        didSet {
            UserDefaults.standard.set(yelpAPIKey, forKey: "flows.yelpKey")
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
            let safety = RouteFilter.towingSafety
            if towingActive {
                routeFilters.formUnion(safety)
            } else {
                routeFilters.subtract(safety)
            }
            applyVehicleMaxGradeDefault()   // towing lowers the grade default
        }
    }
    @Published var showTowingCard = false
    /// Bottom-bar re-center button (ContentView consumes + resets).
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
    @Published var notifyImminent = UserDefaults.standard.object(forKey: "flows.notifyImminent") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyImminent, forKey: "flows.notifyImminent") }
    }
    @Published var notifyEscalation = UserDefaults.standard.object(forKey: "flows.notifyEscalation") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyEscalation, forKey: "flows.notifyEscalation") }
    }
    @Published var notifyTraffic = UserDefaults.standard.object(forKey: "flows.notifyTraffic") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyTraffic, forKey: "flows.notifyTraffic") }
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
        didSet { UserDefaults.standard.set(crashDetectionEnabled, forKey: "flows.crashDetection") }
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
        let rig = towVehicleWeightLbs + towTrailerWeightLbs
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
    @Published var collapsedPanels: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "flows.collapsedPanels") ?? []) {
        didSet {
            // A driver who tucked something away meant it — remember across
            // sessions rather than springing it back on the next launch.
            UserDefaults.standard.set(Array(collapsedPanels),
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
            UserDefaults.standard.set(musicProvider.rawValue, forKey: "flows.musicProvider")
            musicProviderChosen = true
            MusicController.shared.provider = musicProvider
        }
    }
    /// False until the driver picks a service (Settings picker, or the ask
    /// that appears on the first play press).
    @Published var musicProviderChosen: Bool =
        UserDefaults.standard.string(forKey: "flows.musicProvider") != nil
    /// First play press: the "what do you play music with?" card.
    @Published var showMusicProviderPrompt = false

    /// OPTIONAL Spotify Web API token (Settings → Data sources) — in-app
    /// play/pause/skip for Spotify on iOS. A bearer token is a credential,
    /// so it lives in the Keychain (SecureStore), never UserDefaults.
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
    /// a playlist. No subscription, no account.
    func playGenreRadio(_ genre: String, spokenPrefix: String? = nil) async {
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
            VoiceAnnouncer.shared.announce(
                "No \(genre) stations found right now.")
            return
        }
        radio.playQueue(channels, label: genre)
        let name = radio.lastPlayed?.name ?? "a station"
        VoiceAnnouncer.shared.announce(
            (spokenPrefix.map { $0 + " " } ?? "") + "Playing \(genre) — \(name). "
            + "Say next for another \(genre) station.")
    }

    func playMusicAsk(_ term: String) {
        // A driver-initiated ask outranks any pending switch-back. (The
        // restore clears that state before calling here, so its own call
        // is a no-op.)
        cancelOfflineHandoff()
        lastMusicAsk = term
        // No streaming service: free public radio IS the music service.
        if musicProvider == .radio {
            Task { await playGenreRadio(term) }
            return
        }
        if musicProvider == .appleMusic {
            MusicController.shared.playSearchOrGenre(term)
            VoiceAnnouncer.shared.announce("Playing \(term).")
            return
        }
        if musicProvider == .spotify, SpotifyRemote.shared.linked {
            Task { [weak self] in
                if await SpotifyRemote.shared.playSearch(term) {
                    VoiceAnnouncer.shared.announce("Playing \(term) on Spotify.")
                } else if let self {
                    self.musicProvider.openSearch(query: term)
                    VoiceAnnouncer.shared.announce(
                        "Opening Spotify's search for \(term).")
                }
            }
            return
        }
        musicProvider.openSearch(query: term)
        VoiceAnnouncer.shared.announce(
            "Opening \(musicProvider.displayName) — \(term).")
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
    }

    /// Signal held long enough: return to the service they were on,
    /// resuming what they last asked for.
    private func restoreAfterSignalReturn() {
        guard let previous = preHandoffProvider else { return }
        handedOffOffline = false
        preHandoffProvider = nil
        restoreTask = nil
        musicProvider = previous
        // A service FLOWS can drive resumes in place. A deep-linked one
        // must NOT be force-opened mid-drive — throwing the driver into
        // another app's UI at 70 mph is worse than a moment of quiet, so
        // say it's available and let them choose.
        FlowsDiag.log(.info, "audio",
                      "signal held — returning to \(previous.rawValue) "
                      + "(controllable=\(musicControllable))")
        guard musicControllable else {
            VoiceAnnouncer.shared.announce(
                "Signal's back — \(previous.displayName) is ready when you are.")
            return
        }
        VoiceAnnouncer.shared.announce(
            PlaybackFallback.restoreLine(service: previous.displayName))
        if let ask = lastMusicAsk {
            playMusicAsk(ask)
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
        guard preStagedStations.isEmpty,
              !MusicController.shared.hasLocalMusic,
              let genre = lastMusicAsk
                ?? (radio.queueLabel.isEmpty ? nil : radio.queueLabel) else { return }
        preStagedLabel = genre
        Task { [weak self] in
            guard let self else { return }
            await self.radioBrowser.search(text: genre)
            self.preStagedStations = self.radioBrowser.stations.map(\.channel)
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
                      "offline handoff: \(source) (was \(musicProvider.rawValue), "
                      + "localMusic=\(music.hasLocalMusic), "
                      + "preStaged=\(preStagedStations.count) stations)")
        if let line = PlaybackFallback.spokenLine(for: source) {
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
            musicProvider = .appleMusic
            music.playLocalLibrary()
        case .radio(let genre):
            handedOffOffline = true
            preHandoffProvider = musicProvider
            musicProvider = .radio
            // Pre-staged while signal remained: play instantly instead of
            // searching into the silence (the search would fail anyway —
            // the directory needs the very link that just died).
            if !preStagedStations.isEmpty {
                radio.playQueue(preStagedStations,
                                label: preStagedLabel.isEmpty ? genre : preStagedLabel)
                preStagedStations = []
            } else {
                Task { await playGenreRadio(genre) }
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
    /// buttons, the radio card, and the dedicated Trucker route designation.
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
        func clears(_ r: PlannedRoute) -> Bool { semi.passesClearances(r.clearancesMeters) }
        func score(_ r: PlannedRoute) -> Double {
            var s = 0.0
            if r.hasHighways && r.planKind != .avoidHighways { s += 3 }
            if semi.passesGrade(r.maxGradePercent) { s += 2 }
            if (r.familyPeaks["wind"] ?? 0) < FlowsCore.riskYellowMin { s += 1 }
            return s
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
        let eligible = pool.filter(clears)
        if eligible.isEmpty, !pool.isEmpty {
            FlowsDiag.logThrottled(
                key: "trucker.noClearance", .warn, "routing",
                "no candidate clears 13'6\" — trucker badge withheld")
        }
        return eligible
            .map { (id: $0.id, score: score($0), eta: $0.eta) }
            .min { $0.score != $1.score ? $0.score > $1.score : $0.eta < $1.eta }?
            .id
    }

    /// Planner fields live on the model so editing a trip round-trips
    /// (choosing → Edit → planning) without losing what was typed.
    @Published var plannerSource = ""
    @Published var plannerDestination = ""

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
    @Published var trafficDelayMinutes: Int?
    private var trafficWatchTask: Task<Void, Never>?

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
    }
    @Published var escalation: Escalation?
    private var escalationBaseline: Double = 0
    private var dismissedEscalationRisk: Double = 0
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
            guard let warning = imminentWarning,
                  warning.alertID != oldValue?.alertID else { return }
            if hapticAlerts { Haptics.warning() }
            guard voiceAlerts else { return }
            VoiceAnnouncer.shared.announce(SiriSummaries.emergencyAnnouncement(
                event: warning.event, headline: warning.headline,
                action: warning.action))
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
        ScannerIncidents.visible(scanner.incidents,
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
        if let old = shelterSession { stopDelaySeconds -= old.addedSeconds }
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
        stopDelaySeconds = max(0, stopDelaySeconds - session.remaining)
        shelterSession = nil
    }

    /// Drop a finished session so the countdown doesn't sit at zero.
    func clearFinishedShelter() {
        if shelterSession?.isOver == true { shelterSession = nil }
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
        return TripNeeds.adjustedRemainingSeconds(baseline: learned,
                                                  stopDelaySeconds: stopDelaySeconds)
    }

    /// The learned travel time for a route being CHOSEN — so the delay this
    /// device has actually measured steers which route looks fastest, not
    /// only the number shown once driving.
    func learnedETA(for route: PlannedRoute) -> Double {
        let worst = route.familyPeaks
            .filter { $0.value >= FlowsCore.riskGreenMin }
            .max(by: { $0.value < $1.value })?.key
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
    @Published var tripFuelMilesOverride: Double? {
        didSet { rebuildTripNeeds() }
    }
    @Published private(set) var tripNeedSchedule: [TripNeeds.Event] = []

    /// Fuel cadence from the vehicle: 75% of habit-adjusted range.
    var derivedFuelIntervalMiles: Double? {
        tripFuelMilesOverride
            ?? vehicle.profile.map { p in
                0.75 * p.ratedRangeMiles * VehicleProfile.efficiencyFactor(
                    averageSpeedMph: vehicle.averageSpeedMph,
                    idleFraction: vehicle.idleFraction)
            }
    }

    private func rebuildTripNeeds() {
        guard tripNeedsEnabled, let route = navigation.route else {
            tripNeedSchedule = []
            return
        }
        // Time cadences → miles at THIS route's average speed.
        let avgMph = route.eta > 0
            ? (route.distanceMeters / 1609.344) / (route.eta / 3600) : 55
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
        // the trip but differ between trips.
        tripNeedSchedule = TripNeeds.schedule(
            totalMiles: route.distanceMeters / 1609.344,
            intervals: intervals,
            seed: UInt64(route.distanceMeters.rounded()))
    }

    /// The next scheduled stop ahead of the vehicle's along-route odometer.
    var nextTripNeed: TripNeeds.Event? {
        guard !tripNeedSchedule.isEmpty else { return nil }
        let mile = (navigation.guidance?.alongMeters ?? 0) / 1609.344
        return TripNeeds.next(after: mile, in: tripNeedSchedule)
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
        let limits = filterLimits
        var out = routeChoices.filter { r in
            routeFilters.allSatisfy { $0.passes(r, limits: limits) }
        }
        // Tourist filter CHANGES the ordering: the route with more attractions
        // within reach leads (ties fall back to ETA) — scenic beats fast while
        // the driver is explicitly asking for tourist stops. Counts are
        // decorated ONCE before the sort: touristCount is an O(POIs × samples)
        // distance scan, and running it inside the comparator repeated it 4×
        // per comparison.
        if routeFilters.contains(.tourist), !poi.results.isEmpty {
            let counts = Dictionary(uniqueKeysWithValues: out.map { ($0.id, touristCount(for: $0)) })
            out.sort {
                let (a, b) = (counts[$0.id] ?? 0, counts[$1.id] ?? 0)
                if a != b { return a > b }
                return $0.eta < $1.eta
            }
        }
        return out
    }

    /// Filter toggles route through here so request-level filters can
    /// replan: activating "No tolls" fires a toll-free MKDirections request
    /// (tollPreference = .avoid) — merely discarding tolled candidates
    /// collapsed the list to the local-roads route, which was wrong.
    func toggleFilter(_ filter: RouteFilter) {
        if routeFilters.contains(filter) {
            routeFilters.remove(filter)
            if filter == .tourist { poi.clearResults() }
        } else {
            routeFilters.insert(filter)
            // Tourist stops: pin parks/monuments/museums along the corridor
            // the moment the filter lights up — the map immediately shows what
            // the trip could include (Mammoth Cave on a Louisville→Nashville
            // run), and cards gain per-route attraction counts.
            if filter == .tourist, mode == .choosing { refreshTouristSpots() }
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
        let limits = filterLimits
        return routeFilters.filter { !$0.passes(route, limits: limits) }.count
    }

    /// Nothing passes → replan with every request-level preference the
    /// active filters imply, hydrate, and let the relative filters resolve.
    private func formulateConstrainedRoute(
        _ ep: (from: CLLocationCoordinate2D, fromName: String,
               to: CLLocationCoordinate2D, toName: String)
    ) async {
        guard let planned = try? await router.planRoutes(
            from: ep.from, fromName: ep.fromName, to: ep.to, toName: ep.toName,
            includeTollFree: routeFilters.contains(.noTolls)) else { return }
        let fresh = planned.filter { candidate in
            !routeChoices.contains {
                abs($0.eta - candidate.eta) < 45
                    && abs($0.distanceMeters - candidate.distanceMeters) < 400
            }
        }
        guard !fresh.isEmpty, mode == .choosing else { return }
        routeChoices.append(contentsOf: fresh)
        Task { await hydrateRouteRisk() }
    }

    private func supplementTollFree(
        _ ep: (from: CLLocationCoordinate2D, fromName: String,
               to: CLLocationCoordinate2D, toName: String)
    ) async {
        guard let planned = try? await router.planRoutes(
            from: ep.from, fromName: ep.fromName, to: ep.to, toName: ep.toName,
            includeTollFree: true) else { return }
        let fresh = planned.filter { candidate in
            !candidate.hasTolls && !routeChoices.contains {
                abs($0.eta - candidate.eta) < 45 && abs($0.distanceMeters - candidate.distanceMeters) < 400
            }
        }
        guard !fresh.isEmpty, mode == .choosing else { return }
        routeChoices.append(contentsOf: fresh)
        Task { await hydrateRouteRisk() }
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
                // 3.1 mph sustained pace + 10% rest overhead.
                w.etaOverride = r.distanceMeters / 1.39 * 1.10
                return w
            }
            plannerNotice = anyHighway
                ? "Beyond the pedestrian router's range — WALKING ESTIMATE at "
                    + "3.1 mph. No fully highway-free route exists here; a segment "
                    + "may follow a highway — verify a legal walking path before setting out."
                : "Beyond the pedestrian router's range — WALKING ESTIMATE along "
                    + "LOCAL ROADS only (3.1 mph pace): verify sidewalk/shoulder "
                    + "availability before setting out."
            if !estimates.isEmpty {
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
        walkRefineTask?.cancel()
        // Background geometry refinement — not latency-critical; keep it off
        // the P-core/userInteractive band the MainActor would grant it.
        walkRefineTask = Task(priority: .utility) { [weak self] in
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
            await MainActor.run { [weak self] in
                guard let self, self.navigation.route?.isWalkingEstimate == true else { return }
                self.walkingRefinedPath = coords
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
            routeFilters.formUnion(RouteFilter.towingSafety)
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
                self.refreshDaylight()
                // Follow the dispatch feed covering wherever we are now.
                self.scanner.listen(near: fix.coordinate)
                guard self.mode == .navigating else { return }
                let delta = self.lastHabitFix.map { fix.distance(from: $0) } ?? 0
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
                self.maybeOfferTripShare()   // a long DAY can cross 200 mi mid-leg
                self.updateFuelRecommendation()
                self.updateFuelWarning()   // last-chance matching-fuel stops
                self.updatePostedSpeedLimit(fix)   // the HUD speed sign
                self.updateUpcomingLanes()         // lane row at the maneuver
                self.updateCorridorWind(near: fix.coordinate)
                // Saved corridors age out as they stop being useful:
                // arrived, left far behind, or simply stale.
                self.corridors.prune(position: fix.coordinate)
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
                    self.watch.sendGuidance(
                        instruction: g.instruction,
                        distanceText: text,
                        distanceToManeuver: g.distanceToManeuver,
                        coordinate: self.location.coordinate,
                        heading: max(self.location.course, 0))
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
            return (self.recentPeakSpeedMps,
                    max(self.location.speed, 0),
                    self.navigation.metersFromCorridor)
        }
        // Telemetry ladder: OEM cloud (Smartcar) → Bluetooth (OBD adapter /
        // TPMS caps) → nothing (odometer model carries on). Real fuel data
        // silences the gauge check-ins automatically.
        vehicle.telemetry = { [weak self] in
            guard let self else { return (nil, nil) }
            let fuel = self.smartcar.fuelFraction ?? self.vehicleLink.obdFuelFraction
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
        towingWarning = worst.title
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
            if let stopStart = stoppedSince, let profile = vehicle.profile,
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
        guard TripShareLogic.shouldOffer(routeMeters: routeMeters,
                                         drivenTodayMeters: dailyDrive.meters) else { return }
        tripShareOffered = true
        tripSharePrompt = true
    }

    /// The prefilled text for the CURRENT trip: true endpoint (not an added
    /// stop), live arrival estimate (shelter delay included), map link.
    func tripShareBody() -> String {
        let destination = finalDestination?.name
            ?? navigation.route?.destinationName ?? "my stop"
        let coordinate = finalDestination?.coordinate
            ?? navigation.route.flatMap { Self.lastCoordinate(of: $0) }
        let remaining = navigation.guidance?.remainingTime
            ?? navigation.route?.eta ?? 0
        return TripShareLogic.shareMessage(
            destination: destination,
            arrival: Date().addingTimeInterval(adjustedRemainingTime(remaining)),
            latitude: coordinate?.latitude, longitude: coordinate?.longitude)
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
        upcomingSteepGrade = GradeProfile.nextSteep(after: mile, in: route.gradeProfile)
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
        let moved = lastLimitPoint.map {
            POIRanking.meters($0, fix.coordinate) > 60
        } ?? true
        let stale = Date().timeIntervalSince(lastLimitLookup) > 8
        // A brand-new maneuver means a new road is imminent — look again
        // even if the vehicle has barely moved since the last check.
        let newStep = navigation.guidance?.stepIndex != lastLimitStep
        guard (moved && stale) || newStep else { return }
        lastLimitStep = navigation.guidance?.stepIndex
        lastLimitLookup = Date()
        lastLimitPoint = fix.coordinate
        let point = fix.coordinate
        limitLookupTask?.cancel()
        limitLookupTask = Task { [weak self] in
            let limit = await LiveHazardFeedFetcher.shared.postedLimitMph(at: point)
            guard let self, !Task.isCancelled, self.mode == .navigating else { return }
            // Keep the last known limit when this stretch has no tag —
            // blanking the sign every unmapped block would flicker.
            if limit != nil { self.postedSpeedLimitMph = limit }
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
                self.enforcementCameras = found
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
        cameraWarning = EnforcementCameras.warning(
            for: next.camera, meters: next.meters,
            speedMph: mph, postedLimitMph: postedSpeedLimitMph)
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
            DriveVoice.shared.speak(next.camera.kind.title + " ahead")
        }
    }

    // MARK: lane-level guidance for the upcoming maneuver

    /// The tagged lanes on the approach to the next maneuver, left to right
    /// (OSM turn:lanes via Overpass). Empty when the road isn't tagged.
    @Published private(set) var upcomingLanes: [LaneData.Lane] = []
    private var laneLookupTask: Task<Void, Never>?
    private var laneLookupStep = -1

    /// Fetch lanes once per maneuver, and only when one is close enough to
    /// matter — lane guidance three miles out is noise, and the tagging is
    /// per-approach anyway.
    private func updateUpcomingLanes() {
        guard mode == .navigating, !walkingMode, !isPassengerTransit,
              let g = navigation.guidance else {
            if !upcomingLanes.isEmpty { upcomingLanes = [] }
            laneLookupStep = -1
            return
        }
        // A new maneuver resets the row; the same one isn't re-fetched.
        if g.stepIndex != laneLookupStep {
            laneLookupStep = g.stepIndex
            upcomingLanes = []
        }
        guard upcomingLanes.isEmpty, g.distanceToManeuver < 1_600,
              let point = navigation.coordinateAhead(meters: g.distanceToManeuver)
        else { return }
        let step = g.stepIndex
        laneLookupTask?.cancel()
        laneLookupTask = Task { [weak self] in
            let lanes = await LiveHazardFeedFetcher.shared.turnLanes(at: point)
            guard let self, !Task.isCancelled, self.mode == .navigating,
                  self.navigation.guidance?.stepIndex == step else { return }
            self.upcomingLanes = lanes
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
        guard let fraction = vehicle.predictedFuelFraction else { return false }
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
            self.fuelWarningLevel = level
            self.fuelWarningStation = cheapest
            self.fuelWarningItem = cheapest.flatMap { found.items[$0.name] }
            self.fuelWarningText = FuelWarning.bannerText(
                fuel: fuel, level: level, station: cheapest)
            // Say it once per level change — a driver shouldn't be told the
            // same thing every mile, but a worsening situation speaks again.
            if level != .none, level != self.dismissedFuelWarningLevel,
               let spoken = FuelWarning.spokenAdvice(
                   fuel: fuel, level: level, station: cheapest, rangeMiles: range) {
                DriveVoice.shared.speak(spoken)
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
        for item in items {
            let name = item.name ?? fuel.rawValue
            let coord = item.placemark.coordinate
            let ahead = POIRanking.meters(here, coord) / 1609.344
            guard ahead <= rangeMiles else { continue }
            guard FuelWarning.isReachable(station: coord, from: here,
                                          courseDegrees: course,
                                          routeAhead: routeAhead) else { continue }
            // Live station price when a feed has one, else the state
            // estimate — the same ladder the stop list uses.
            let price = await poi.livePriceProvider(coord, fuel)
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
        fuelWarningText = nil
    }

    // MARK: favorites (star button → one-press route planning)

    /// One press on a favorite: plan from the current GPS fix to it and show
    /// the choices. Returns the planned routes so the caller can frame the
    /// camera (nil when planning failed or there's no position).
    @discardableResult
    func planToFavorite(_ fav: FavoriteAddress) async -> [PlannedRoute]? {
        guard let here = effectivePosition ?? location.coordinate else { return nil }
        plannerDestination = fav.name
        guard let planned = try? await plan(
            from: here, fromName: "Current location",
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
        // Apply the driver's learned pace to every ETA before anything reads
        // them — so the correction reaches the cards, the cost estimates
        // derived from ETA, the ranking, AND the arrival-time reasoning that
        // decides whether a hazard will still be active on arrival. Walking
        // estimates already carry their own override and are left alone.
        routeChoices = RouteService.applyPersonalPace(
            routes, multiplier: DrivingProfileStore.shared.etaMultiplier)
        transitItinerary = nil   // drive routes replace any transit overlay
        // A fresh plan resets the transit pickers: cancel in-flight
        // computations, drop stale option cards, untoggle rail/bus/plane.
        transitTasks.values.forEach { $0.cancel() }
        transitTasks = [:]
        transitOptions = [:]
        activeTransitModes = []
        hybridOption = nil
        restoreTransientPanels()   // fresh choices bring the trip menus back
        highlightedRouteID = routes.first?.id
        mode = .choosing
        filterCardsHidden = false   // fresh choices bring the slider card back
        // Supersede any prior hydration: its retry loop reads the LIVE
        // routeChoices, so a replan while still .choosing would otherwise
        // stack a second (then third…) loop re-scoring the same routes —
        // multiplied NWS rounds against the polite-API doctrine.
        riskHydrationTask?.cancel()
        riskHydrationTask = Task { await hydrateRouteRisk() }
    }

    /// Land a finished score on its (possibly re-sorted) card. If the user
    /// already picked a route (choices cleared), the index lookup fails and
    /// the late score is dropped harmlessly. An INCOMPLETE score keeps the
    /// provisional picture the card already shows — the retry pass refreshes
    /// it — instead of blanking back to a bare spinner.
    private func landScore(_ done: PlannedRoute) {
        guard let i = routeChoices.firstIndex(where: { $0.id == done.id }) else { return }
        var done = done
        if !done.weatherScored {
            done.scoringProgress = routeChoices[i].scoringProgress
            done.provisionalSamples = routeChoices[i].provisionalSamples
        }
        routeChoices[i] = done
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

    private func hydrateRouteRisk() async {
        // The driver just asked for these routes and is watching the cards —
        // the whole phase-1 pass rides the planning-burst lane (elevated
        // in-flight ceiling, same bounded request set).
        await RequestGate.shared.withPlanningBurst {
            // FASTEST ROUTE FIRST: routeChoices arrive ETA-sorted, so the top
            // card — the one most drivers take — gets the entire burst lane to
            // itself and its GO unlocks in a few seconds; the alternates then
            // score concurrently, and cheaper than they look (they share most
            // of their corridor cells with the leader through the TTL cache).
            let leadID = self.routeChoices.first?.id
            if let lead = self.routeChoices.first {
                self.landScore(await self.scored(
                    lead, onProgress: self.cardProgressSink(routeID: lead.id)))
            }
            await withTaskGroup(of: PlannedRoute.self) { group in
                for r in self.routeChoices where r.id != leadID {
                    let sink = self.cardProgressSink(routeID: r.id)
                    group.addTask { await self.scored(r, onProgress: sink) }
                }
                for await done in group { self.landScore(done) }
            }
        }
        if mode == .choosing {
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
                guard !incomplete.isEmpty, mode == .choosing, !Task.isCancelled else { break }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { break }
                // Burst only around the re-scoring itself, never across the
                // backoff sleeps — the elevated ceiling is for active,
                // user-blocking work.
                await RequestGate.shared.withPlanningBurst {
                    for r in incomplete where self.mode == .choosing {
                        self.landScore(await self.scored(
                            r, onProgress: self.cardProgressSink(routeID: r.id)))
                    }
                }
            }
        }
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
            routeChoices[i] = done
        } else {
            navigation.updateRouteMetadata(done)
        }
    }

    /// Keep the map's highlighted route consistent with the (filtered) list.
    func ensureHighlightValid() {
        let visible = filteredChoices
        if let hl = highlightedRouteID, visible.contains(where: { $0.id == hl }) { return }
        highlightedRouteID = visible.first?.id
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
        closureScore: Double = 0
    ) -> Double {
        // ONE nearest-ZIP resolution for all families at this coordinate —
        // per-family score() calls redid the same neighborhood scan 8×.
        let row = riskField.scoreRow(at: c)
        func field(_ fam: String) -> Double {
            guard let row, let fi = riskField.familyIndex(fam), fi < row.count else { return 0 }
            return row[fi]
        }
        func predictor(_ fam: String, _ deviceKey: String) -> Double {
            max(field(fam), onDevice[deviceKey] ?? 0)
        }
        var bandInput: [String: Double] = [
            "wind": predictor("wind", "wind"),
            "heat": predictor("heat", "heat"),
            "cold": predictor("cold", "cold"),
            "air": field("air"),
            "radiation": field("radiation"),
            "winter": predictor("winter", "winter"),
            "convective": predictor("convective", "convective"),
            // modeled flood risk + forecast rain = a flood PREDICTOR, not proof.
            // The relative-elevation multiplier (rain inches × how low this
            // sample sits in the LOCAL terrain) amplifies the predictor — a
            // valley-floor road in heavy rain reads riskier than the ridge
            // beside it; still capped as a secondary, never Red alone.
            "precip": min(1, predictor("qpf_flood", "precip") * floodMultiplier),
        ]
        if let ev = alertEvent, let fam = RiskEquations.alertFamily(ev) {
            bandInput[fam] = max(bandInput[fam] ?? 0, alertSeverity)
        }
        // DOT-reported closure: PROOF the road is blocked — realized primary.
        if closureScore > 0 { bandInput["closure"] = closureScore }
        return RiskEquations.realizedRisk(bandInput)
    }

    /// ON-DEVICE R equations, CONUS-wide: NWS gridpoint forecasts at every
    /// other corridor sample (capped), scored with the EXACT ported equations
    /// (RiskEquations ← R/scoring.R + R/forecast.R). Where the richer WI
    /// engine export exists, the max of the two applies — so coverage is no
    /// longer Wisconsin-only. Conditions AND elevation per sample: the
    /// latitude-band profile can shift ±1 band on elevation (contiguous
    /// rule), so mountain samples normalize against their climatically-
    /// correct band. Keyed by SAMPLE INDEX into `samples`. Split from
    /// `scored` so these fetches overlap the alert-cell pass.
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
    private func scoredBurst(_ input: PlannedRoute) async -> PlannedRoute {
        await RequestGate.shared.withPlanningBurst { await self.scored(input) }
    }

    /// `onProgress` (optional): per-batch provisional updates, supplied by
    /// the hydration layer for routes with a visible card. Progressive
    /// display: as alert cells land, the card colors the resolved share of
    /// the corridor instead of spinning until the last cell — each landed
    /// sample runs through the SAME realized-risk equation as the final pass
    /// (field predictors + capped alert), so the provisional band can't
    /// red-out on a watch the final pass would cap. GO still waits for the
    /// complete verdict.
    private func scored(
        _ input: PlannedRoute,
        onProgress: (@MainActor (Double, [RiskSample?]) -> Void)? = nil
    ) async -> PlannedRoute {
        var r = input
        // Partition once: boundaries feed the weather scorer, the
        // between-boundary runs become map-drawable segments.
        let part = RouteService.corridorPartition(of: r.route.polyline, everyMeters: 40_000)

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
        async let scoreF = alerts.corridorRisk(
            at: part.samples,
            arrivalOffsets: RiskTiming.arrivalOffsets(
                sampleCount: part.samples.count, totalTravelSeconds: eta),
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
            let gaugeEvid = HazardFeedScores.floodGaugeScore(gauges: corridorGauges, at: c)
            let waterEvid = HazardFeedScores.waterProximityScore(waterPoints: corridorWater, at: c)
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
            return RiskSample(
                coordinate: c,
                risk: sampleRealizedRisk(
                    at: c, alertEvent: s.worstEvent, alertSeverity: s.risk,
                    onDevice: dev, floodMultiplier: floodMult,
                    closureScore: HazardFeedScores.closureScore(
                        closures: corridorClosures, at: c)),
                worstEvent: s.worstEvent, alertID: s.alertID)
        }
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
        // contract). Incomplete routes keep "Scoring…" and hydrate retries.
        r.weatherScored = score.complete
        return r
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
            // ON-ROUTE only: a posted limit must sit within ~60 m of the
            // route geometry to restrict it (garages/side streets don't
            // count — the old any-post-in-the-box rule read a 6 ft garage
            // bar as I-65's clearance).
            let path = POIRanking.RoutePath(
                coords: RouteService.samplePoints(of: r.route.polyline, everyMeters: 250))
            func onRoute(_ lat: Double, _ lon: Double) -> Bool {
                let pt = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                return (path.nearest(to: pt)?.offRoute ?? .infinity) < 60
            }
            r.clearancesMeters = found.clearances
                .filter { onRoute($0.lat, $0.lon) }.map(\.meters)
            r.weightLimitsLbs = found.weights
                .filter { onRoute($0.lat, $0.lon) }.map(\.lbs)
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
        routeChoices = []
        pendingVoiceOffer = nil
        // Remember the trip's true endpoint so added stops can chain back.
        if finalDestination == nil, let end = Self.lastCoordinate(of: route) {
            finalDestination = (end, route.destinationName)
        }
        // Review finding: selecting before hydration finishes captured a
        // baseline of 0 (unscored routes), so the first corridor update on any
        // yellow corridor fired a spurious escalation. Sentinel −1 defers the
        // capture to the first corridor score instead.
        escalationBaseline = route.weatherScored ? route.weatherRisk : -1
        dismissedEscalationRisk = 0
        tripObservedPeak = route.weatherRisk   // seed with the plan-time estimate
        escalation = nil
        arrivedAt = nil
        imminentWarning = nil
        dismissedImminentIDs = []
        shelteredImminentIDs = []
        reachSpeeds = [:]   // per-trip state like its two siblings above
        stopDelaySeconds = 0
        tripShareOffered = false   // new trip → the share banner may show once
        tripSharePrompt = false
        restoreTransientPanels()   // the drive starts with its menus in reach
        // Carry the road ahead offline for trips between towns: if signal
        // drops (or the app is reopened out in the country), the way onward
        // is already on disk. Short in-town hops aren't stored.
        recordOfflineCorridor(for: route)
        // Start the delay model's training pair: what we promised, and when.
        tripPredictedSeconds = route.eta
        tripStartedAt = Date()
        tripStartArea = location.coordinate.map(TrafficArea.init)
        tripDistanceMeters = route.distanceMeters
        mode = .navigating
        startLeg(route)
        maybeOfferTripShare()   // a 200+ mile route triggers right at GO
        checkTowingSignal()   // trailer signal checked at trip start, not per tick
        if crashDetectionEnabled, CrashDetectionService.isAvailable {
            crash.begin()
            crash.resolveAddress()
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
        trafficWatchTask?.cancel()
        trafficDelayMinutes = nil
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
        imminentWarning = nil
        stopDelaySeconds = 0
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
        postedSpeedLimitMph = nil
        lastLimitPoint = nil
        lastLimitStep = nil
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
        stoppedSince = nil
        lastClockFix = nil
        tripSharePrompt = false
        tripShareOffered = false
        restoreTransientPanels()   // back to planning with the trip menus out
        corridors.prune(position: location.coordinate)   // arrived → let it go
        learnTripDuration()   // teach the delay model what this drive cost
        roadEfficiency.flush()   // bank the last measured stretch
        mode = .planning
        watch.sendEnded()
    }

    // MARK: escalating-risk reroute (driver-approved)

    /// Corridor re-scores arrive every ~4 min while driving. If risk jumps
    /// meaningfully past yellow relative to what the driver accepted at
    /// selection, surface a flashing prompt — never reroute silently.
    private func handleCorridorUpdate(_ score: WeatherAlertService.CorridorScore) {
        guard mode == .navigating else { return }
        // LIKE-FOR-LIKE with the baseline the driver accepted: the route band
        // is DISTANCE-WEIGHTED, and the watch window's samples are uniformly
        // spaced, so the comparable live number is the plain sample MEAN — the
        // old peak⊕avg blend sat above the weighted baseline by construction
        // and manufactured escalations on quiet routes.
        let sampleRisks = score.samples.map {
            sampleRealizedRisk(at: $0.coordinate, alertEvent: $0.worstEvent,
                               alertSeverity: $0.risk)
        }
        let peakR = sampleRisks.max() ?? 0
        let risk = sampleRisks.isEmpty ? 0 : sampleRisks.reduce(0, +) / Double(sampleRisks.count)
        // The worst actually ENCOUNTERED is the peak sample, not the blend —
        // it feeds the seasonal model's predicted-vs-observed record.
        tripObservedPeak = max(tripObservedPeak, peakR)
        if notifyImminent { updateImminentWarning(from: score) }
        // Reverse-geocode the current state on corridor updates — the
        // trucker radio retune AND the DOT work-zone feed both key off it.
        if let pos = effectivePosition {
            let corridorSamples = score.samples.map(\.coordinate)
            Task { [weak self] in
                let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
                    CLLocation(latitude: pos.latitude, longitude: pos.longitude))
                let state = placemarks?.first?.administrativeArea
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
                    self?.workZonesAhead = nearby.count
                    self?.workZoneRoad = nearby.first?.road
                }
            }
        }
        // Deferred baseline (route selected before hydration): the first
        // complete corridor score IS what the driver implicitly accepted.
        if escalationBaseline < 0 {
            if score.complete { escalationBaseline = risk }
            return
        }
        // Incomplete score (a cell fetch failed): the zeroed samples make the
        // mean meaningless — don't evaluate escalation against it; the next
        // complete cycle catches up. (Banners were preserved above.)
        guard score.complete else { return }
        // Two triggers: sustained worsening (mean up 0.12+ into yellow) OR a
        // realized RED anywhere in the window — a tornado warning on one
        // stretch must escalate even when the rest of the window is quiet.
        let sustained = risk >= FlowsCore.riskYellowMin
            && risk > escalationBaseline + 0.12
            && risk > dismissedEscalationRisk + 0.05
        let acuteRed = peakR > 0.8751 && peakR > dismissedEscalationRisk + 0.05
        let escalated = sustained || acuteRed
        if escalated, notifyEscalation {
            escalation = Escalation(
                newRisk: acuteRed ? peakR : risk,
                headline: score.headlines.first ?? "Conditions worsening along this route")
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
                alertID: id, distanceMeters: dist, severityScore: alert.severityScore)
        }
        guard let hit = ImminentAlerts.firstImminent(candidates, speedMps: speed),
              let alert = score.alertsByID[hit.alertID] else {
            // Nothing imminent anymore — clear a stale banner, EXCEPT red
            // alerts (those stay until the driver physically presses them)
            // and EXCEPT incomplete scores: a transient NWS failure zeroes
            // the samples, and "no data" must never read as "all clear".
            if score.complete, imminentWarning?.action != .shelter { imminentWarning = nil }
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
        if imminentWarning?.action == .shelter || imminentWarning?.action == .lookout,
           imminentWarning?.alertID != warning.alertID,
           action != .shelter { return }
        if imminentWarning != warning { imminentWarning = warning }
        // Red alert → the shelter list for THIS hazard opens itself, once.
        if action == .shelter, !shelteredImminentIDs.contains(alert.id) {
            shelteredImminentIDs.insert(alert.id)
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
        if let e = escalation { dismissedEscalationRisk = e.newRisk }
        escalation = nil
    }

    /// Driver tapped "Reroute" — replan from the current fix, pick the
    /// lowest-alert-risk alternative, and swap the active route.
    func approveEscalationReroute() async {
        guard let fix = location.coordinate, let dest = finalDestination else {
            escalation = nil
            return
        }
        escalation = nil
        guard let planned = try? await router.planRoutes(
            from: fix, fromName: "Current location",
            to: dest.coordinate, toName: dest.name), !planned.isEmpty
        else { return }
        // Fully score every candidate (cached cells make this fast) and swap
        // to the calmest — hydrated, so the nav map keeps its risk coloring.
        var best: PlannedRoute?
        for candidate in planned {
            let s = await scoredBurst(candidate)
            if s.weatherRisk < (best?.weatherRisk ?? .infinity) { best = s }
        }
        guard let best else { return }
        // The driver may have ended navigation or arrived during the awaits above
        // — don't resurrect a dead trip by restarting nav + corridor/traffic
        // watches over a route they no longer want.
        guard mode == .navigating else { return }
        // Reroute goes DIRECT to the final destination — drop the pending stop
        // entirely (name AND kind), or a later final arrival would be mishandled
        // as a stop arrival: a phantom vehicle.filledUp() corrupting the range
        // model and the trip record silently skipped. (startLeg rebaselines.)
        upcomingLeg = nil
        pendingStopName = nil
        pendingStopKind = nil
        startLeg(best)
    }

    /// Common leg-swap: hydrated route into the engine + fresh corridor
    /// services, arrival chaining preserved. (Also the tail of select() —
    /// the two had drifted into near-identical copies.)
    /// When the current leg began and what it was predicted to take — the
    /// two halves of the personal ETA correction (DrivingProfile).
    private var legStartedAt: Date?
    private var legPredictedSeconds: TimeInterval = 0

    private func startLeg(_ leg: PlannedRoute) {
        lastRouteRect = leg.route.polyline.boundingMapRect
        legStartedAt = Date()
        legPredictedSeconds = leg.eta
        // Rebaseline escalation on every leg swap — and ALWAYS defer to the
        // first complete corridor score (sentinel -1) rather than seeding from
        // leg.weatherRisk: the plan-time number blends forecast predictors,
        // the flood elevation multiplier, and closure scores that the live
        // watch mean (sampleRealizedRisk with live-only inputs) never sees, so
        // a plan-time baseline sits systematically HIGH and suppressed real
        // escalations. Deferring makes baseline and live means like-for-like
        // by construction.
        escalationBaseline = -1
        dismissedEscalationRisk = 0
        navigation.start(route: leg, onArrival: { [weak self] in self?.handleArrival() })
        // Legs swapped in mid-drive (reroute, added stop, arrival chaining)
        // arrive weather-scored but attribute-pending — hydrate grades /
        // clearances into the live leg without blocking guidance.
        if !leg.attributesScored {
            Task { [weak self] in await self?.hydrateAttributes(leg) }
        }
        // Recurring-needs schedule rebases per leg (a stop resets the
        // food/rest clocks — you just stopped).
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
                let newDelay = (delay >= 8 && self.notifyTraffic)
                    ? Int(delay.rounded()) : nil
                // Announce a FRESH offer once (not every re-measure of the
                // same jam), stage it for the spoken "go ahead" yes, and
                // LISTEN for the plain yes/no right after asking. No clear
                // answer = the chip stays on screen; nothing is guessed.
                if let minutes = newDelay, self.trafficDelayMinutes == nil {
                    self.pendingVoiceOffer = .fasterRoute
                    if self.hapticAlerts { Haptics.offer() }   // chip just appeared
                    if self.voiceAlerts {
                        VoiceAnnouncer.shared.announce(
                            SiriSummaries.fasterRouteOffer(minutes: minutes))
                        VoiceReply.shared.listenAfterSpeech { [weak self] answer in
                            guard let self,
                                  case .fasterRoute? = self.pendingVoiceOffer
                            else { return }
                            if answer == true {
                                Task { await self.rerouteForTraffic() }
                            } else if answer == false {
                                self.pendingVoiceOffer = nil
                            }
                        }
                    }
                } else if newDelay == nil,
                          case .fasterRoute? = self.pendingVoiceOffer {
                    self.pendingVoiceOffer = nil   // jam cleared on its own
                }
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
            self.corridorWindMph = c.windMph ?? 0
            self.corridorWindFromDegrees = c.windFromDegrees
        }
    }

    /// The coarse weather bucket the delay model learns on, from the risk
    /// engine's own corridor scoring — no new data source.
    var currentTrafficWeather: TrafficWeather {
        let worst = navigation.route?.familyPeaks
            .filter { $0.value >= FlowsCore.riskGreenMin }
            .max(by: { $0.value < $1.value })?.key
        return TrafficWeather.from(family: worst)
    }

    /// What this route was predicted to take when the driver accepted it —
    /// the "predicted" half of the delay model's training pair.
    private var tripPredictedSeconds: Double?
    private var tripStartedAt: Date?
    /// Where the trip began — which neighbourhood's learning it belongs to.
    private var tripStartArea: TrafficArea?
    private var tripDistanceMeters: Double = 0

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
        let actual = Date().timeIntervalSince(started) - stopDelaySeconds
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

    /// Traffic chip's action: swap to the currently-fastest hydrated route.
    func rerouteForTraffic() async {
        guard let fix = location.coordinate, let dest = finalDestination else { return }
        trafficDelayMinutes = nil
        pendingVoiceOffer = nil
        guard let planned = try? await router.planRoutes(
            from: fix, fromName: "Current location",
            to: dest.coordinate, toName: dest.name),
            let fastest = planned.first else { return }
        let route = await scoredBurst(fastest)
        // Don't restart a trip the driver ended/finished during the awaits above.
        guard mode == .navigating else { return }
        // Direct reroute: drop any pending stop (name + kind), same as the
        // escalation reroute, so the final arrival isn't taken for a stop.
        upcomingLeg = nil
        pendingStopName = nil
        pendingStopKind = nil
        startLeg(route)
    }

    // MARK: POI stop chaining

    /// Add the nearest POI as the NEXT stop: navigate there now; on arrival
    /// automatically replan to the original destination.
    /// True while an added stop's legs are being planned — the HUD shows a
    /// progress banner (a silent multi-second wait read as a freeze).
    @Published var addingStop = false

    /// Where the vehicle effectively is: the GPS fix, or the route start
    /// when previewing without one (macOS without location access). Keeps
    /// POI search and add-stop working instead of silently no-op'ing.
    var effectivePosition: CLLocationCoordinate2D? {
        location.coordinate ?? navigation.route.flatMap { Self.firstCoordinate(of: $0) }
    }

    /// Append a stop to the CURRENT route: plan both legs immediately —
    /// (here → stop) to drive now and (stop → final destination) to continue
    /// with — so the map shows the whole amended trip, and arrival at the
    /// stop seamlessly rolls into the continuation.
    func addStop(_ item: MKMapItem) async {
        // The old guard returned SILENTLY without a GPS fix — on a Mac in
        // preview mode that read as "add stop freezes". Fall back to the
        // route-start position and always show progress.
        guard let fix = effectivePosition, let dest = finalDestination else { return }
        let name = item.name ?? "Stop"
        pendingStopName = name
        pendingStopKind = poi.activeKind
        poi.clearResults()
        addingStop = true
        defer { addingStop = false }
        // Only the SHORT hop (here → stop) blocks the UI — one directions
        // call, unscored. The continuation leg and all risk scoring happen
        // while the driver is already moving (the long-pause fix: the main
        // route is never re-derived up front).
        guard let leg1 = (try? await router.planRoutes(
            from: fix, fromName: "Current location",
            to: item.placemark.coordinate, toName: name))?.first
        else { pendingStopName = nil; return }
        // Driver may have ended/finished the trip while leg1 planned.
        guard mode == .navigating else { pendingStopName = nil; return }
        startLeg(leg1)
        Task { [weak self] in
            guard let self else { return }
            let leg2 = (try? await self.router.planRoutes(
                from: item.placemark.coordinate, fromName: name,
                to: dest.coordinate, toName: dest.name))?.first
            guard let leg2 else { return }
            let scored = await self.scored(leg2)
            // Don't reattach a phantom continuation leg after the user arrived
            // or ended navigation during this background plan+score.
            guard self.mode == .navigating, self.pendingStopName == name else { return }
            self.upcomingLeg = scored
        }
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
            startLeg(next)
            return
        }
        // Arrived at an ADDED STOP whose continuation leg isn't ready (the
        // background plan failed or hasn't landed) — this is NOT the final
        // destination: no arrived banner, no trip record. Replan the
        // continuation from here; only a second failure surfaces honestly.
        if let stopName = pendingStopName, let dest = finalDestination {
            if pendingStopKind == .gas { vehicle.filledUp() }
            pendingStopKind = nil
            pendingStopName = nil
            Task { [weak self] in
                guard let self else { return }
                let from = self.effectivePosition ?? dest.coordinate
                if let leg = (try? await self.router.planRoutes(
                    from: from, fromName: stopName,
                    to: dest.coordinate, toName: dest.name))?.first {
                    guard self.mode == .navigating else { return }
                    let scored = await self.scoredBurst(leg)
                    guard self.mode == .navigating else { return }
                    self.startLeg(scored)
                } else if self.mode == .navigating {
                    // Honest state: at the stop, continuation unavailable.
                    // (Mode guard: if the driver ended navigation during the
                    // replan, don't post an arrival banner over planning.)
                    self.arrivedAt = "\(stopName) — couldn't plan the leg to "
                        + "\(dest.name); plan again from here"
                }
            }
            return
        }
        arrivedAt = finalDestination?.name ?? navigation.route?.destinationName
        // Learn from the completed trip: the plan-time prediction vs. the worst
        // risk actually encountered → the on-device seasonal model (frequency-
        // gated, decaying, bucketed by week-of-year). Final destination only.
        if let route = navigation.route,
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
        // numbers and compared them nowhere.
        if let started = legStartedAt, legPredictedSeconds > 0 {
            DrivingProfileStore.shared.recordArrival(
                predicted: legPredictedSeconds,
                actual: Date().timeIntervalSince(started),
                stoppedSeconds: stopDelaySeconds)
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
        alerts.endCorridorWatch()
        watch.sendArrived()
    }

    private static func lastCoordinate(of route: PlannedRoute) -> CLLocationCoordinate2D? {
        let poly = route.route.polyline
        let n = poly.pointCount
        guard n > 0 else { return nil }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: n)
        poly.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        return coords.last
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
                        model.textSizeMaxIndex = TextScale.maxStepIndex(
                            forWidthPoints: geometry.size.width)
                    }
                    .onChange(of: geometry.size.width) { _, width in
                        model.textSizeMaxIndex = TextScale.maxStepIndex(
                            forWidthPoints: width)
                    }
                    .onOpenURL { url in
                        // flows://smartcar?code=… — the OAuth callback.
                        if url.host == "smartcar" || url.absoluteString.contains("smartcar") {
                            Task { await model.smartcar.handleCallback(url: url) }
                        }
                    }
            }
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        #endif
    }
}
