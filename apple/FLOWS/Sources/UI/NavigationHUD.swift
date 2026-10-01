// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Combine
import MapKit
import SwiftUI

/// Turn-by-turn chrome: instruction banner up top, trip stats + gas/food/
/// medical/shelter quick actions + end-navigation controls at the bottom;
/// flashing escalation prompts (driver-approved reroute) when corridor risk
/// rises mid-drive. Same floating-card language as the planning UI so the
/// mode flip still feels like one app.
struct NavigationHUD: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.golden) private var golden
    @Environment(\.mapKeyComesBack) private var mapKeyComesBack
    let isCompact: Bool
    /// The open detail cards from ContentView (a tapped hazard, a tourist
    /// stop, the towing limits, the crash check-in): they join this HUD's own
    /// card column above the drive bar.
    let detailCards: AnyView?
    /// Short window (phone held sideways): the floating cards get the room
    /// the inline fuel cluster would take.
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isShort: Bool { verticalSizeClass == .compact }
    #else
    private let isShort = false
    #endif
    @State private var escalationPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.openURL) private var openURL
    @StateObject private var music = MusicController.shared
    /// Spotify Web API remote (token-gated) — observed here for the plain-
    /// words status line in the music menu.
    @StateObject private var spotify = SpotifyRemote.shared
    /// Radio card visibility (trucker radio in trucker mode, emergency
    /// radio otherwise — same card, same relays).
    @State private var showRadio = false
    /// Tapping the shelter countdown opens its two-way out.
    @State private var showShelterSheet = false
    /// Ticks once a second while sheltering so the countdown moves.
    @State private var shelterTick = Date()
    /// AM/FM search field text (radio-browser.info directory).
    @State private var stationSearch = ""
    /// Streaming search field text (a song, an artist, an album).
    @State private var streamSearch = ""
    /// Scanner search field text (a city).
    @State private var scannerSearch = ""
    /// The radio card's search field holding the keyboard, if any (see
    /// searchingInShortWindow).
    enum RadioSearch: Hashable { case station, streaming, scanner }
    @FocusState private var radioSearchFocus: RadioSearch?
    /// The AM/FM kind currently on the dial, so its chip reads as chosen.
    @State private var radioGenre: BroadcastRadio.Kind?
    /// The genre last asked of the streaming service, so its chip reads as
    /// chosen.
    @State private var streamGenre: BroadcastRadio.Kind?
    /// Long-trip share banner: recipient list expanded / contacts sheet up.
    @State private var showShareChooser = false
    @State private var showShareContactPicker = false
    /// Persisted station choice (67 bundled NOAA relays).
    @AppStorage("flows.radioChannel") private var radioChannelID = ""
    /// Quick music menu (resume / station / genres) visibility.
    @State private var showMusicMenu = false
    /// In-app mic states (music ask / radio ask) — "Listening…" feedback.
    @State private var musicMicListening = false
    @State private var radioMicListening = false
    @State private var scannerMicListening = false
    /// Live-economy inputs, fed by GPS fixes: current speed and a lightly
    /// smoothed acceleration (single-fix speed noise would flicker the bar).
    @State private var liveMph: Double = 0
    @State private var accelMphPerSec: Double = 0
    @State private var lastFixTime: Date?
    @State private var lastFixMph: Double = 0
    /// Breathing phase for the over-the-red-line speed glow.
    @State private var overGlow = false
    /// Slow phase for the low-reachable-fuel tank.
    @State private var tankPulse = false


    var body: some View {
        VStack {
            // Typing a station search in a short window leaves only the
            // strip above the keyboard: the directions window and the drive
            // bar step aside for the card until the keyboard goes away.
            if !searchingInShortWindow, !checkInInShortWindow {
                Group {
                    if let arrived = model.arrivedAt {
                        arrivedBanner(arrived)
                    } else if let failure = model.continuationFailure {
                        continuationBanner(failure)
                    } else {
                        instructionBanner
                    }
                }
                .chromeRegion("top.directions")
            }
            // Under the directions window: the alerts, offers and chips
            // centred across the screen (owner, 2026-10-01: "Rest in X
            // minutes" and "Recalculating route…" sat off to one side), and
            // the top-right corner — the settings gear in the corner itself,
            // the icons of menus tucked away (the instruments' gauge among
            // them) stacked under it. The chips keep clear of that column on
            // both sides, so they stay centred and never run under it.
            ZStack(alignment: .topTrailing) {
                topChips
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, showsCornerRow ? golden.iconCircle + golden.pad : 0)
                if showsCornerRow {
                    VStack(alignment: .trailing, spacing: golden.pad) {
                        SettingsGear()
                            .chromeRegion("top.gear")
                        CollapsedPanelTray(axis: .vertical)
                    }
                }
            }
            // The map between the corner and the drive bar: the cards down
            // the middle, the instruments on the right wall, centred top to
            // bottom. In a SHORT window an open floating card
            // takes the instruments' room: the driver just asked for that
            // card, and the instruments return when it closes.
            HStack(alignment: .center, spacing: golden.pad) {
                // Wide layouts balance the column with the same room on the
                // left, so the alerts and cards stay centred on the map.
                if instrumentsFit, !isCompact {
                    Color.clear.frame(width: instrumentWidth, height: 1)
                }
                VStack {
                    // Empty map takes only what the rows leave: with an equal share
                    // it left alerts and cards scrolling beside open map.
                    Spacer(minLength: 0)
                        .layoutPriority(-1)
                    // The floating cards share one scrolls-when-tight region: with
                    // several open in a short (landscape) window they must squeeze
                    // and scroll HERE — never push the maneuver banner or the bottom
                    // bar off the screen.
                    #if os(macOS)
                    // Settings opens from the gear in the drive bar, so it opens here,
                    // above the cards and the bar, scrolling on its own: nested in the
                    // cards' scroll it was a small window inside a small window.
                    if model.showSettings {
                        SettingsPanelCard()
                            .chromeRegion("bottom.settings")
                    }
                    #endif
                    ScrollWhenTight {
                        VStack(spacing: 8) {
                            if showShelterSheet {
                                shelterSheet
                            }
                            if showRadio {
                                radioCard
                            }
                            if showMusicMenu {
                                musicMenuCard
                            }
                            if model.showMusicProviderPrompt {
                                musicProviderCard
                            }
                            if model.poi.pendingFoodChoice {
                                foodCategoryCard
                            } else if model.poi.pendingStoreChoice {
                                storeCategoryCard
                            } else if model.poi.pendingFuelChoice {
                                fuelTypeCard
                            } else if !model.poi.results.isEmpty {
                                poiListCard
                            }
                            // The detail cards (hazard, tourist stop, towing, crash
                            // check-in) join this column, the most urgent nearest the
                            // bar. They used to float in a separate slot at a guessed
                            // height, on top of these cards and the bar.
                            if let detailCards {
                                detailCards
                            }
                        }
                    }
                    .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
                    // Opaque cards: the radio card's station names once read
                    // straight through a towing card that slid over it.
                    .environment(\.solidCards, true)
                    // One region: a card scrolled out of view covers nothing.
                    .chromeRegion("bottom.cards")
                }
                .frame(maxWidth: .infinity)
                if instrumentsFit {
                    instrumentColumn
                        .chromeRegion("side.instruments")
                }
            }
            // The crash check-in is never below the fold of the cards'
            // scroll: it waits for the driver's answer, so it sits right
            // above the bar in a row of its own. Its buttons never scroll;
            // its words scroll within a quarter of the window, so its first
            // claim on the height, ahead of the chips and the cards, is
            // bounded.
            if model.crash.state != .idle {
                CrashCheckInCard()
                    .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
                    .layoutPriority(1)
                    .chromeRegion("bottom.crash-check-in")
            }
            if !searchingInShortWindow {
                bottomBar
                    .chromeRegion("bottom.drive-bar")
            }
        }
        .padding(golden.pad)
        // A short window (a phone held sideways) cannot fit the directions
        // window, the instruments and the drive bar at the largest text
        // sizes, so the HUD's type stops growing a step earlier there.
        .dynamicTypeSize(isShort
                         ? DynamicTypeSize.xSmall...DynamicTypeSize.accessibility1
                         : DynamicTypeSize.xSmall...DynamicTypeSize.accessibility5)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            // Only while sheltering — a per-second tick on an idle HUD would
            // redraw the whole thing for nothing.
            guard model.shelterSession != nil else { return }
            shelterTick = now
            model.clearFinishedShelter()
            if model.shelterSession == nil { showShelterSheet = false }
        }
        .onChange(of: model.showRadioCardRequested) { _, wants in
            guard wants else { return }
            showRadio = true
            model.showRadioCardRequested = false
        }
        .onReceive(model.location.$latest) { fix in
            guard let fix else { return }
            let mph = max(fix.speed, 0) * 2.236936
            if let last = lastFixTime {
                let dt = fix.timestamp.timeIntervalSince(last)
                if dt > 0.2 {
                    accelMphPerSec = accelMphPerSec * 0.7
                        + ((mph - lastFixMph) / dt) * 0.3
                }
            }
            lastFixTime = fix.timestamp
            lastFixMph = mph
            liveMph = mph
        }
    }

    // MARK: fuel cluster — gauge + economy readouts while driving

    /// The cluster is a driving instrument: motor routes only (walking has
    /// no tank), and only once a vehicle profile exists to read from.
    /// The cluster is a CAR instrument. A walker has no tank and no
    /// speedometer, and neither does a passenger on a plane, bus or train —
    /// SpeedSign.shouldShow already draws that line for the speed bar, so
    /// the gauge and the economy readouts follow it rather than testing only
    /// for a walking route.
    private var showsFuelCluster: Bool {
        model.vehicle.profile != nil
            && !model.walkingMode
            && model.navigation.route?.isWalkingEstimate != true
            && !model.isPassengerTransit
            && !model.collapsedPanels.contains("fuel")
    }

    /// Any floating card open above the bottom bar (radio, music, pickers,
    /// the stop list) — these get the fuel cluster's room in short windows.
    private var floatingCardOpen: Bool {
        showRadio || showMusicMenu || model.showMusicProviderPrompt
            || model.poi.pendingFoodChoice || model.poi.pendingStoreChoice
            || model.poi.pendingFuelChoice || !model.poi.results.isEmpty
            || detailCards != nil
    }

    /// On a phone or in a short window an emergency message (a red or yellow
    /// alert, the crash check-in) takes the instruments' place until it is
    /// answered. They come back afterwards unless the driver tucked them away.
    private var emergencyTakesInstrumentsPlace: Bool {
        (isCompact || isShort) && (model.imminentWarning != nil || model.crash.state != .idle)
    }

    /// A prompt waiting at the top for the driver's answer: a reroute offer,
    /// the long-trip share, the last-chance fuel banner or the refuel gauge.
    private var topPromptOpen: Bool {
        model.escalation != nil || model.tripSharePrompt
            || model.fuelWarningText != nil || model.refuelPrompt
    }

    /// The station search has the keyboard in a short window.
    private var searchingInShortWindow: Bool {
        isShort && radioSearchFocus != nil
    }

    /// A crash check-in is up in a short window (a phone on its side). The
    /// car has stopped: the directions window and the instrument row step
    /// aside so the check-in, the alerts and the drive bar all fit.
    private var checkInInShortWindow: Bool {
        isShort && model.crash.state != .idle
    }

    /// Everything that arrives at the top — the offline pill, alerts,
    /// offers, prompts and chips — centred under the directions window.
    @ViewBuilder
    private var topChips: some View {
        VStack {
            if OfflinePill.shows(model.breadcrumbs) {
                OfflinePill()
                    .chromeRegion("top.offline-pill")
            }
            // Everything else that arrives at the top — alerts, offers,
            // prompts, chips — scrolls in its own region when there are
            // too many for the window, instead of pushing the drive bar
            // off the bottom of it. The banners that hold state (a chooser
            // opened, a needle dragged, a pulse running) scroll in ONE
            // copy; the plain chips under them lie flat while they fit, so
            // the map beside a chip still pans.
            ScrollWhenTight(maxHeight: golden.size.height / 3) {
                VStack {
                    if let warning = model.imminentWarning, !model.imminentWarningTucked {
                        imminentBanner(warning)
                    }
                    if let escalation = model.escalation {
                        escalationBanner(escalation)
                    }
                    if model.tripSharePrompt {
                        tripShareBanner
                    }
                    if let lastChance = model.fuelWarningText {
                        lastChanceFuelBanner(lastChance)
                    }
                    if model.refuelPrompt {
                        refuelGauge
                    }
                }
            }
            .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
            // An emergency is sized before the chips and the cards, up to a
            // third of the window: an open radio or hazard card scrolls
            // rather than squeeze it. Everything else shares what is left.
            .layoutPriority(1)
            .chromeRegion("top.alerts")
            ScrollWhenTight(holdsNoState: true) {
                // Chips hug the leading edge instead of floating down the
                // middle of the map: "Rest in 87 mi" sat centred over the
                // road on every long trip, which is exactly where the driver
                // is looking.
                VStack(alignment: .leading, spacing: 6) {
                    // The one-line weather strip holds no state: it lies flat
                    // with the chips, so the map beside it still pans.
                    if model.escalation == nil, model.imminentWarning == nil,
                       !model.alerts.activeHeadlines.isEmpty {
                        alertStrip
                    }
                    if model.stopDelayAheadSeconds > 0 {
                        shelterDelayChip
                    }
                    if let need = model.nextTripNeed {
                        tripNeedChip(need)
                    }
                    if let fuelNote = model.fuelRecommendation {
                        fuelRecommendationChip(fuelNote)
                    }
                    if let camera = model.cameraWarning {
                        cameraChip(camera)
                    }
                    if let steep = model.upcomingSteepGrade {
                        steepGradeChip(steep)
                    }
                    if model.truckerUI, model.hosStatus != .ok {
                        hosChip
                    }
                    if model.notifyTraffic, model.workZonesAhead > 0 {
                        Label(model.workZonesAhead == 1
                              ? "Work zone ahead"
                                + (model.workZoneRoad.map { " · \($0)" } ?? "")
                              : "\(model.workZonesAhead) work zones ahead",
                              systemImage: "cone.fill")
                            .scaledFont(.footnote, weight: .bold)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.orange.opacity(0.92))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                            .shadow(color: Theme.cardShadow, radius: 8, y: 3)
                    }
                    // While the one-shot warning below is up it carries the
                    // same words — one red chip, not two.
                    if model.towingActive, model.towingWarning == nil,
                       let worst = model.towingViolations.first {
                        Button { model.showTowingCard = true } label: {
                            Label(worst.title, systemImage: "exclamationmark.octagon.fill")
                                .scaledFont(.footnote, weight: .heavy)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Theme.riskRed.opacity(0.95))
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                                .shadow(color: Theme.cardShadow, radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                    }
                    if let lowTire = model.lowTireWarning {
                        Label(lowTire, systemImage: "exclamationmark.tirepressure")
                            .scaledFont(.footnote, weight: .bold)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.riskYellow.opacity(0.92))
                            .foregroundStyle(.black)
                            .clipShape(Capsule())
                            .shadow(color: Theme.cardShadow, radius: 8, y: 3)
                    }
                    // Live towing-limit violation: red banner the moment active weights
                    // exceed a manufacturer rating; tap to dismiss (the TowingCard's
                    // sliders/badges stay live in the submenu).
                    if let towWarn = model.towingWarning {
                        Button { model.towingWarning = nil } label: {
                            Label(towWarn, systemImage: "exclamationmark.triangle.fill")
                                .scaledFont(.footnote, weight: .bold)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Theme.riskRed.opacity(0.94))
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                                .shadow(color: Theme.cardShadow, radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                    }
                    if let message = model.poi.emptyResultMessage {
                        Text(message)
                            .scaledFont(.footnote, weight: .semibold)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.cardBackground)
                            .clipShape(Capsule())
                            .shadow(color: Theme.cardShadow, radius: 8, y: 3)
                    }
                    if let saved = model.fasterRouteSavedMinutes {
                        // FLOWS took a faster road on its own (owner item 9):
                        // nothing to answer, gone in a few seconds.
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.branch")
                            Text("Took a faster route — saves \(saved) min")
                                .scaledFont(.footnote, weight: .bold)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.riskGreen.opacity(0.92))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .shadow(color: Theme.cardShadow, radius: 8, y: 3)
                    }
                    // The traffic switch hides the chip at once; FLOWS still
                    // weighs the jam and takes a road that adds no risk.
                    if model.notifyTraffic, let delay = model.trafficDelayMinutes {
                        HStack(spacing: 8) {
                            Image(systemName: "car.rear.waves.up.fill")
                            Text("Traffic ahead — +\(delay) min")
                                .scaledFont(.footnote, weight: .bold)
                            // Nothing to take: red, no faster road, or past the turn.
                            if !model.trafficOfferBlocked {
                                Button(model.trafficOfferRiskier ? "Faster, more risk" : "Faster route") {
                                    Task { await model.rerouteForTraffic() }
                                }
                                .scaledFont(.footnote, weight: .heavy)
                                .buttonStyle(.plain)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 32)
                                .background(Color.white)
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.92))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .shadow(color: Theme.cardShadow, radius: 8, y: 3)
                    }
                    if model.addingStop {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Adding stop — replanning route…")
                        }
                        .scaledFont(.footnote, weight: .semibold)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.cardBackground)
                        .clipShape(Capsule())
                        .shadow(color: Theme.cardShadow, radius: 8, y: 3)
                    }
                }
            }
            .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
            .chromeRegion("top.chips")
        }
    }

    /// The instruments show on the right wall: a car with a vehicle on file,
    /// not tucked away, not a short window whose room an open card or a
    /// waiting prompt is using, and not giving their place to an emergency.
    private var instrumentsFit: Bool {
        showsFuelCluster && !(isShort && (floatingCardOpen || topPromptOpen))
            && !emergencyTakesInstrumentsPlace
    }

    /// The top-right corner under the directions window: the settings gear
    /// and the tucked-menu icons beside it (the instruments' own icon among
    /// them when they are tucked away).
    private var showsCornerRow: Bool {
        !searchingInShortWindow && !checkInInShortWindow
    }

    /// Average economy from the vehicle's habit-learned figures (rolling
    /// speed + idle history); the plain rated number before any history.
    private var averageEconomy: Double? {
        guard let profile = model.vehicle.profile else { return nil }
        guard profile.tankCapacityUnits > 0 else { return profile.ratedMilesPerUnit }
        return profile.effectiveRangeMiles(
            averageSpeedMph: model.vehicle.averageSpeedMph,
            idleFraction: model.vehicle.idleFraction) / profile.tankCapacityUnits
    }

    /// How wide the instrument column on the right wall is.
    private let instrumentWidth: CGFloat = 96

    /// The driving instruments, stacked down the right wall of the map
    /// (owner, 2026-10-01: "vertical instead of horizontal so that they sit
    /// on the center-right wall"): the fuel gauge, average economy, the
    /// range left, how thriftily you are driving, and the live speed bar
    /// standing upright — 0 at the foot, the scale's top at the head.
    private var instrumentColumn: some View {
        let vehicle = model.vehicle
        // Real fuel data when current — the same source as "mi left" below it.
        let fraction = min(max(vehicle.displayedFuelFraction ?? 0.5, 0), 1)
        let electric = vehicle.profile?.fuelType == .electric
        return VStack(spacing: 8) {
            GaugeDial(fraction: .constant(fraction),
                      alarming: model.fuelGaugeAlarming,
                      showsQuartileLabels: false)
                .frame(width: instrumentWidth - 20, height: (instrumentWidth - 20) * 0.6)
                .allowsHitTesting(false)
            if model.fuelReachabilityTight {
                Image(systemName: "fuelpump.fill")
                    .scaledFont(size: 16, weight: .bold)
                    .foregroundStyle(Theme.riskRed.opacity(tankPulse ? 1 : 0.15))
                    .help("Few fuel stops left within your range")
            }
            if let economy = averageEconomy {
                readout("Average") {
                    Text(electric ? String(format: "%.1f mi/kWh", economy)
                                  : String(format: "%.0f MPG", economy))
                }
            }
            if let range = vehicle.expectedRangeMiles {
                readout("Fuel Tank") {
                    Text(String(format: "%.0f mi left", range))
                }
            }
            if showsSpeedSign {
                readout("Efficiency") { efficiencyIcon }
                verticalSpeedBar
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: instrumentWidth)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 8, y: 3)
        .overlay(alignment: .topTrailing) {
            minimizeButton("fuel", help: "Tuck the driving instruments away")
                .padding(3)
        }
        // Reduce Motion holds the tank at full strength instead.
        .animation(model.fuelReachabilityTight && !reduceMotion
                   ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                   : .default,
                   value: tankPulse)
        .onChange(of: model.fuelReachabilityTight, initial: true) { _, tight in
            tankPulse = tight
        }
    }

    /// The shared X that tucks a driving instrument into the top-right tray.
    private func minimizeButton(_ id: String, help: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                _ = model.collapsedPanels.insert(id)
            }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .scaledFont(size: 15)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// One instrument reading under its own underlined title, so each
    /// number says what it is without a driver having to infer it.
    private func readout<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .scaledFont(size: 9, weight: .bold)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle()
                .fill(Color.secondary.opacity(0.45))
                .frame(height: 1)
            content()
                .scaledFont(size: 12, weight: .semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: live speed bar — how fast, how legal, how thriftily

    /// A driving instrument: hidden for a walker and for a passenger on a
    /// plane, bus, or train (SpeedSign.shouldShow).
    private var showsSpeedSign: Bool {
        SpeedSign.shouldShow(
            isNavigating: model.mode == .navigating,
            isWalking: model.walkingMode
                || model.navigation.route?.isWalkingEstimate == true,
            isPassengerTransit: model.isPassengerTransit)
    }

    /// The grade of the road underfoot, for the efficiency verdict — the
    /// route's own measured elevation profile at the current mile.
    private var currentGradePercent: Double {
        guard let route = model.navigation.route else { return 0 }
        let mile = (model.navigation.guidance?.alongMeters ?? 0) / 1609.344
        return route.gradeProfile.first {
            mile >= $0.startMile && mile <= $0.endMile
        }?.gradePercent ?? 0
    }

    /// Green leaf / half-and-half / red pump, from throttle, drag and hill
    /// (DriveEfficiency).
    private var efficiencyVerdict: DriveEfficiency.Verdict {
        let profile = model.vehicle.profile
        let ratings = model.towingRatings
        return DriveEfficiency.verdict(DriveEfficiency.Inputs(
            speedMph: liveMph,
            accelMphPerSec: accelMphPerSec,
            gradePercent: currentGradePercent,
            // Wind along the direction of travel: a headwind is air the
            // vehicle has to push, a tailwind is help.
            windMph: model.corridorWindMph,
            windFromDegrees: model.corridorWindFromDegrees,
            headingDegrees: model.location.course >= 0 ? model.location.course : nil,
            efficientCruiseMph: DriveEfficiency.efficientCruiseMph(
                city: profile?.cityMilesPerUnit, highway: profile?.highwayMilesPerUnit),
            cityMPU: profile?.cityMilesPerUnit,
            highwayMPU: profile?.highwayMilesPerUnit,
            loadedWeightLbs: model.towVehicleWeightLbs + model.towTrailerWeightLbs > 0
                ? model.towVehicleWeightLbs + model.towTrailerWeightLbs : nil,
            vehicleWeightLbs: model.towVehicleWeightLbs > 0
                ? model.towVehicleWeightLbs : ratings.gvwrLbs,
            towing: model.towingActive,
            fuelFraction: model.vehicle.displayedFuelFraction))
    }

    /// The limit the yellow and red lines are drawn from. The posted one
    /// wherever the road is tagged; otherwise the ordinary limit for the
    /// kind of road being driven, so BOTH LINES ARE ALWAYS ON THE BAR. A bar
    /// with no lines teaches a driver nothing, and unmapped stretches are
    /// common enough that the lines were blinking out mid-drive.
    private var lawLimitMph: Double {
        SpeedLaw.effectiveLimitMph(postedLimitMph: model.postedSpeedLimitMph,
                                   speedMph: liveMph)
    }

    /// The top of the bar, which FOLLOWS the driving: it grows to keep the
    /// current speed and both legal lines in view and shrinks back when they
    /// fall away, so a 30 mph street doesn't leave most of the bar empty.
    private var barTopMph: Double {
        SpeedLaw.dynamicTopMph(speedMph: liveMph,
                               postedLimitMph: lawLimitMph,
                               vehicleTopSpeedMph: model.vehicle.profile?.topSpeedMph)
    }

    private var speedStanding: SpeedLaw.Standing {
        SpeedLaw.standing(speedMph: liveMph, postedLimitMph: lawLimitMph)
    }

    /// The fill color follows the law: normal below the posted limit, yellow
    /// once past it (a state violation), red at gross excess.
    private var speedBarColor: Color {
        switch speedStanding {
        case .legal: return Theme.riskGreen
        case .stateViolation: return Theme.riskYellow
        case .federalViolation: return Theme.riskRed
        }
    }

    /// How tall the upright speed bar stands: a fifth of the window, kept
    /// between a readable floor and a ceiling that leaves the cards room.
    private var speedBarHeight: CGFloat {
        min(max(golden.size.height * 0.2, 110), 200)
    }

    /// The live speed bar, upright: 0 at the foot, the scale's top at the
    /// head, ticked like a real gauge — a mark every 10 mph and a shorter
    /// one every 5. A thick yellow line marks where state law is broken and a
    /// thick red one excessive speed, each with its number beside it; the
    /// fill takes the color of whichever has been passed, and passing red
    /// sets the bar breathing. The current speed reads under the bar.
    private var verticalSpeedBar: some View {
        let top = barTopMph
        let fill = min(max(liveMph / max(top, 1), 0), 1)
        let stateMph = SpeedLaw.stateThresholdMph(postedLimitMph: lawLimitMph)
        let fedMph = SpeedLaw.federalThresholdMph(postedLimitMph: lawLimitMph)
        let stateFrac = SpeedLaw.barFraction(stateMph, topMph: top)
        let fedFrac = SpeedLaw.barFraction(fedMph, topMph: top)
        let over = speedStanding == .federalViolation
        return VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                // The scale's numbers, each beside its own line.
                GeometryReader { geo in
                    let h = geo.size.height
                    let w = geo.size.width
                    ZStack(alignment: .topLeading) {
                        // The top, unless a legal number lands on it.
                        if !crowdsTheTop(fedFrac) {
                            Text("\(Int(top))")
                                .scaledFont(size: 10, weight: .bold)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .position(x: w / 2, y: 6)
                        }
                        if let stateMph, let stateFrac {
                            OutlinedText(text: String(format: "%.0f", stateMph),
                                         color: Theme.riskYellow,
                                         font: .system(size: 10, weight: .bold))
                                .fixedSize()
                                .position(x: w / 2, y: clampY(h * (1 - stateFrac), h))
                        }
                        if let fedMph, let fedFrac {
                            Text(String(format: "%.0f", fedMph))
                                .scaledFont(size: 10, weight: .bold)
                                .monospacedDigit()
                                .foregroundStyle(Theme.riskRed)
                                .position(x: w / 2, y: clampY(h * (1 - fedFrac), h))
                        }
                        Text("0")
                            .scaledFont(size: 10, weight: .bold)
                            .foregroundStyle(.secondary)
                            .position(x: w / 2, y: h - 6)
                    }
                }
                .frame(width: 26)
                GeometryReader { geo in
                    let h = geo.size.height
                    ZStack(alignment: .bottom) {
                        Capsule().fill(Theme.fill(0.07))
                        Capsule()
                            .fill(speedBarColor)
                            .frame(height: h * fill)
                        // Ticks ride OVER the fill — a scale you can still
                        // read once the bar has run past it.
                        verticalTicks(height: h, topMph: top)
                        if let stateFrac {
                            legalMarker(at: h * stateFrac, color: Theme.riskYellow,
                                        passed: liveMph >= (stateMph ?? .infinity))
                        }
                        if let fedFrac {
                            legalMarker(at: h * fedFrac, color: Theme.riskRed, passed: over)
                        }
                    }
                    .animation(.easeOut(duration: 0.35), value: fill)
                    .animation(.easeInOut(duration: 0.5), value: top)
                }
                .frame(width: 16)
            }
            .frame(height: speedBarHeight)
            // Outlined only while yellow — the other two read on their own.
            Group {
                if speedStanding == .stateViolation {
                    OutlinedText(text: String(format: "%.0f", max(liveMph, 0)),
                                 color: Theme.riskYellow,
                                 font: .system(size: 18, weight: .heavy, design: .rounded))
                } else {
                    Text(String(format: "%.0f", max(liveMph, 0)))
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(speedBarColor)
                }
            }
            Text("mph")
                .scaledFont(size: 10, weight: .bold)
                .foregroundStyle(.secondary)
        }
        .shadow(color: over ? Theme.riskRed.opacity(overGlow ? 0.9 : 0.15) : .clear,
                radius: over ? (overGlow ? 12 : 3) : 0)
        // The pulse is animated ON THIS VIEW ONLY. Driving a repeatForever
        // through withAnimation put every view updated in that transaction
        // into the same repeating animation — which is why unrelated menus
        // (the music picker's green rows) were seen blinking. Reduce Motion
        // holds the glow at full strength instead.
        .animation(over && !reduceMotion
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .default,
                   value: overGlow)
        .onChange(of: over, initial: true) { _, isOver in
            overGlow = isOver
        }
        .help(SpeedLaw.federalNote)
    }

    /// Would the red line's number sit on the scale's top number?
    private func crowdsTheTop(_ fraction: Double?) -> Bool {
        (fraction ?? 0) > 0.88
    }

    /// A label's centre kept inside the bar's own height.
    private func clampY(_ y: CGFloat, _ height: CGFloat) -> CGFloat {
        min(max(y, 6), height - 6)
    }

    /// Speedometer ticks across the upright bar: wider every 10 mph,
    /// narrower every 5.
    private func verticalTicks(height: CGFloat, topMph: Double) -> some View {
        let stops = Array(stride(from: 5.0, to: topMph, by: 5.0))
        return ZStack(alignment: .bottom) {
            ForEach(Array(stops.enumerated()), id: \.offset) { _, mph in
                let major = mph.truncatingRemainder(dividingBy: 10) == 0
                Rectangle()
                    .fill(Color.black.opacity(major ? 0.7 : 0.45))
                    .frame(width: major ? 8 : 5, height: major ? 1.5 : 1)
                    .offset(y: -height * (mph / topMph))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    /// A legal threshold across the upright bar: thick, so it reads over the
    /// fill. Once the fill runs PAST a line it takes that line's colour and
    /// the mark would disappear into it — red on red — so a crossed mark
    /// gets a solid white surround: the line just crossed is the one the
    /// driver most needs to see.
    private func legalMarker(at y: CGFloat, color: Color, passed: Bool = false) -> some View {
        let core: CGFloat = passed ? 6 : 3
        let outer: CGFloat = passed ? core + 4 : core
        return ZStack {
            if passed {
                Rectangle()
                    .fill(.white)
                    .frame(width: 22, height: outer)
            }
            Rectangle()
                .fill(color)
                .frame(width: 18, height: core)
                .overlay(passed ? nil
                         : Rectangle().stroke(Color.white.opacity(0.6), lineWidth: 0.5))
        }
        .frame(height: outer)
        .offset(y: -max(y - outer / 2, 0))
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    /// How thriftily the vehicle is being driven right now. Green leaf when
    /// it's efficient; an exhaust cloud in red when it isn't — the waste
    /// itself, rather than a fuel pump, which is where you FIX the problem
    /// rather than what the problem is. The middle is literally between the
    /// two: the leaf's top corner and the exhaust's bottom corner, split by
    /// a diagonal.
    @ViewBuilder
    private var efficiencyIcon: some View {
        switch efficiencyVerdict {
        case .efficient:
            Image(systemName: "leaf.fill")
                .scaledFont(size: 18, weight: .bold)
                .foregroundStyle(Theme.riskGreen)
                .frame(width: 24)
                .contentTransition(.symbolEffect(.replace))
                .help(efficiencyHelp)
        case .wasteful:
            // A bare cloud reads as weather; the CO2 glyph reads as exhaust.
            Image(systemName: "carbon.dioxide.cloud.fill")
                .scaledFont(size: 17, weight: .bold)
                .foregroundStyle(Theme.riskRed)
                .frame(width: 24)
                .contentTransition(.symbolEffect(.replace))
                .help(efficiencyHelp)
        case .fair:
            MixedEfficiencyIcon(size: 20)
                .frame(width: 24)
                .help(efficiencyHelp)
        }
    }

    private var efficiencyHelp: String {
        switch efficiencyVerdict {
        case .efficient: return "Driving efficiently for this vehicle"
        case .fair: return "Middling — some speed, throttle or hill cost"
        case .wasteful: return "Burning fuel hard right now (throttle, speed or grade)"
        }
    }

    // MARK: food category picker — shown when Food is tapped

    private var foodCategoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What kind of food?")
                    .scaledFont(size: 15, weight: .bold)
                Spacer()
                Button { model.poi.clearResults() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // Even rows, never one button alone on the last (BalancedRows);
            // a cuisine with a country wears its flag.
            BalancedRowsLayout(minItemWidth: 96, spacing: 6) {
                ForEach(FoodCategory.allCases) { category in
                    let flag = CuisineFlag.has(category)
                    Button {
                        Task {
                            await model.poi.chooseFood(category, aheadOf: model.effectivePosition)
                        }
                    } label: {
                        Text(category.rawValue)
                            .scaledFont(size: 13, weight: .semibold)
                            .lineLimit(1)
                            .padding(.horizontal, flag ? 8 : 0)
                            .padding(.vertical, flag ? 2 : 0)
                            .background {
                                if flag { Capsule().fill(Color.black.opacity(0.6)) }
                            }
                            .foregroundStyle(flag ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background {
                                if flag { CuisineFlag(category: category) } else { Theme.fill(0.05) }
                            }
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Theme.fill(0.12), lineWidth: flag ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .floatingCard()
        .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
    }

    // MARK: store category picker — shown when Stores is tapped

    private var storeCategoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What kind of store?")
                    .scaledFont(size: 15, weight: .bold)
                Spacer()
                Button { model.poi.clearResults() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            BalancedRowsLayout(minItemWidth: 96, spacing: 6) {
                ForEach(StoreCategory.allCases) { category in
                    Button {
                        Task {
                            await model.poi.chooseStore(category, aheadOf: model.effectivePosition)
                        }
                    } label: {
                        Label(category.rawValue, systemImage: category.symbol)
                            .scaledFont(size: 13, weight: .semibold)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(Theme.fill(0.05))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .floatingCard()
        .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
    }

    // MARK: fuel type picker — first Gas press only; remembered afterwards

    private var fuelTypeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What does this vehicle take?")
                    .scaledFont(size: 15, weight: .bold)
                Spacer()
                Button { model.poi.clearResults() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // One row when the words fit whole; stacked when the card is
            // narrow (the instruments share the middle) — never a word
            // broken across two lines.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { fuelChoices }
                VStack(spacing: 8) { fuelChoices }
            }
            Text("Remembered for future Gas requests — change it anytime under ⚙ Settings.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        .floatingCard()
        .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
    }

    private var fuelChoices: some View {
        ForEach(FuelType.allCases) { fuel in
            Button {
                Task {
                    await model.poi.chooseFuel(fuel, aheadOf: model.effectivePosition)
                }
            } label: {
                Label(fuel.rawValue, systemImage: fuel.symbol)
                    .scaledFont(size: 14, weight: .semibold)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: Theme.tapMinimum)
                    .background(Theme.fill(0.05))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: ranked results list — ahead-only, ordered per kind

    private var poiListCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(listTitle)
                    .scaledFont(size: 15, weight: .bold)
                Spacer()
                // X = tuck the list back into its own button on the drive
                // bar — no second icon up in the corner. The results (and
                // their map pins) stay: the lit button brings the list back,
                // and pressing it again clears the search for real.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        _ = model.collapsedPanels.insert("stops")
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Tuck the stop list away — its button below brings it back")
            }
            // Either key supplies stars (Google is asked first), so the
            // hint is for a driver with neither. Yelp is no longer free,
            // and its old developer page moved; Settings says where to go.
            if model.yelpAPIKey.isEmpty, model.googlePlacesAPIKey.isEmpty,
               model.poi.activeKind == .food || model.poi.activeKind == .hotel {
                HStack(spacing: 6) {
                    Text("Stars and hours need a Google Places or Yelp key:")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                    // Named the way Settings heads the key fields.
                    Button("add in ⚙ → Keys for extra info") { model.showSettings = true }
                        .buttonStyle(.plain)
                        .scaledFont(.caption, weight: .bold)
                        .foregroundStyle(.blue)
                }
            }
            // Reader: tapping a pin on the MAP selects its row here — scroll
            // that row into view, the same way tapping a route card brings
            // its route forward on the map.
            ScrollViewReader { scroller in
                ScrollView {
                    // Every row as wide as the longest one, and no wider: the
                    // card hugs its rows instead of leaving a gap between a
                    // row's name and its price (owner, 2026-10-01).
                    // Local businesses' tiles, picked across the whole list
                    // so no two share both initials and colour.
                    let results = model.poi.results
                    let locals = LocalMarks.assign(results.map { $0.item.name ?? "" })
                    VStack(spacing: 4) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, ranked in
                            poiRow(ranked, local: locals[i])
                                .frame(maxWidth: .infinity)
                                .id(ranked.id)
                        }
                    }
                    .fixedSize(horizontal: !isCompact, vertical: false)
                }
                .frame(maxHeight: golden.listMaxHeight)
                .onChange(of: model.poi.selected?.id) { _, id in
                    guard let id else { return }
                    withAnimation { scroller.scrollTo(id, anchor: .center) }
                }
            }
        }
        .collapsibleMenu("stops")
        .floatingCard()
        // On a wide window the card is as wide as its longest row; on a
        // phone it spans the screen.
        .fixedSize(horizontal: !isCompact, vertical: false)
        .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
    }

    private var listTitle: String {
        // Nothing ranked on the route: the rows are the nearest ones around
        // it, and the title must not call them "ahead".
        let results = model.poi.results
        if !results.isEmpty, results.allSatisfy({ $0.placement == .offRoute }) {
            return "None on your route — the nearest ones near it"
        }
        if let category = model.poi.activeFoodCategory {
            return "\(category.rawValue) ahead — soonest first"
        }
        if let category = model.poi.activeStoreCategory {
            return "\(category.rawValue) stores — top-rated first"
        }
        if model.poi.activeKind == .gas, let fuel = model.poi.fuelType {
            return "\(fuel.rawValue) ahead — best price + detour first"
        }
        return "\(model.poi.activeKind?.rawValue ?? "Stops") ahead"
    }

    private func poiRow(_ ranked: POIService.RankedPOI, local: LocalMarks.Mark) -> some View {
        let isSelected = ranked.id == model.poi.selected?.id
        return HStack(spacing: 8) {
            // The tile left of the name: a major chain's official logo, else
            // its initials in its own colours, else the local business's own
            // initials and colour.
            brandTile(ranked, local: local)
            VStack(alignment: .leading, spacing: 1) {
                // The brand as it writes itself: the map says "bp".
                Text(BrandMark.displayName(ranked.item.name ?? "Stop"))
                    .scaledFont(size: 14, weight: .semibold)
                    .lineLimit(1)
                    .frame(maxWidth: 240, alignment: .leading)
                HStack(spacing: 6) {
                    // Only a stop ranked along the route has miles AHEAD and a
                    // detour; the rest are a straight line from the vehicle.
                    let miles = max(ranked.aheadMeters, 0) / 1609.344
                    switch ranked.placement {
                    case .onRoute:
                        // One text, so a narrow card wraps it between words
                        // instead of stacking "in 2" over "mi".
                        Text(String(format: "in %.0f mi · +%.0f min detour", miles,
                                    2 * ranked.detourMeters / POIRanking.detourSpeedMps / 60))
                    case .straightLine:
                        Text(String(format: "%.0f mi away", miles))
                    case .offRoute:
                        Text(String(format: "%.0f mi away · not on your route", miles))
                    }
                    if let open = ranked.isOpenNow {
                        Text(open ? "· Open" : "· Closed")
                            .foregroundStyle(open ? Theme.riskGreen : Theme.riskRed)
                            .fontWeight(.semibold)
                    }
                    if ranked.showers == .standard || ranked.showers == .likely {
                        Label(ranked.showers.rawValue, systemImage: "shower.fill")
                            .scaledFont(.caption2, weight: .semibold)
                            .foregroundStyle(.blue)
                        // Driver correction. The shower claim here is a brand
                        // assumption ("Love's has showers"), and a trucker who
                        // detours for one and finds none has earned the right
                        // to say so — `ShowerAvailability.disprove` has been
                        // implemented and persisted all along with nothing
                        // able to call it, so the top rung of the resolution
                        // ladder (.disproven) was unreachable.
                        Button {
                            let c = ranked.item.placemark.coordinate
                            ShowerAvailability.disprove(lat: c.latitude, lon: c.longitude)
                            model.poi.refreshShowerResolution()
                        } label: {
                            Text("· no showers?")
                                .scaledFont(.caption2)
                                .foregroundStyle(.secondary)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .help("Report that this stop has no showers — FLOWS will stop claiming it does")
                    }
                    if let fee = ranked.parkingFee {
                        Text(fee ? "· Paid" : "· Free")
                            .fontWeight(.semibold)
                            .foregroundStyle(fee ? Color.secondary : Theme.riskGreen)
                    }
                    if let type = ranked.shelterType {
                        Text("· \(type)").fontWeight(.semibold)
                    }
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                if ranked.rating != nil || ranked.costTier != nil {
                    StarsAndBucks(stars: ranked.rating, costTier: ranked.costTier,
                                  currency: model.costCountry.currencySymbol,
                                  url: ranked.businessURL,
                                  credit: ranked.ratingCredit)
                }
                // A phone's card is too narrow for a price column: the price
                // rides under the name as one line.
                if isCompact, let price = priceWords(ranked) {
                    Text(price.unit.map { "\(price.figure) \($0)" } ?? price.figure)
                        .scaledFont(.caption, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(price.posted ? Theme.cta : Color.secondary)
                }
            }
            // Only as much room as the longest row needs (the card sizes to
            // that row), so the price sits close to the name.
            Spacer(minLength: 8)
            if !isCompact, let price = priceWords(ranked) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(price.figure)
                        .scaledFont(size: price.big ? 19 : 10,
                                    weight: price.big ? .heavy : .semibold,
                                    design: price.big ? .rounded : .default)
                        .monospacedDigit()
                        .foregroundStyle(price.posted ? Theme.cta : Color.secondary)
                    if let unit = price.unit {
                        Text(unit)
                            .scaledFont(size: 9, weight: .semibold)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.trailing, 2)
            }
            Button("Add stop") {
                Task { await model.addStop(ranked.item) }
            }
            .scaledFont(size: 13, weight: .heavy)
            .lineLimit(1)
            .fixedSize()
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Theme.cta)
            .foregroundStyle(Theme.onCTA)
            .clipShape(Capsule())
        }
        .padding(8)
        .background(Color.black.opacity(isSelected ? 0.08 : 0.02))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { model.poi.choose(ranked) }
    }

    /// A stop's price, in words. PRICE: the big slot shows LIVE station
    /// prices only (TomTom key, or Mexico's CRE feed) — a state average
    /// isn't a price, so it rides small and grey instead of masquerading as
    /// one. Gas and hotels only.
    private func priceWords(_ ranked: POIService.RankedPOI)
        -> (figure: String, unit: String?, big: Bool, posted: Bool)? {
        let kind = model.poi.activeKind
        guard kind == .gas || kind == .hotel else { return nil }
        if model.costCountry == .mexico, kind == .gas,
           ranked.isLivePrice, let mx = ranked.pricePerUnit {
            // CRE feed: this station's real posted price, MXN/L.
            return (String(format: "MX$%.2f", mx), "/L · official (CRE)", true, true)
        }
        if kind == .gas, !ranked.isLivePrice {
            return (ranked.pricePerUnit.map { String(format: "~$%.2f est.", $0) } ?? "$ —",
                    nil, false, false)
        }
        if kind == .hotel, ranked.pricePerUnit == nil {
            // No live nightly: a tier-anchored typical rate, clearly an
            // estimate — never a blank "$ —".
            return (String(format: "~$%.0f est.",
                           RatingsAndCost.estimatedNightly(costTier: ranked.costTier)),
                    "per night", false, false)
        }
        let unit = kind == .gas
            ? (model.poi.fuelType == .electric ? "/kWh" : "/gal")
            : "per night"
        return (ranked.pricePerUnit.map { String(format: "$%.2f", $0) } ?? "$ —",
                unit, true, ranked.pricePerUnit != nil)
    }

    /// A stop's tile (owner, 2026-10-01): a major chain's official logo
    /// (BrandMark.logoURL — Brandfetch, once the app carries its client ID),
    /// shown over the chain's own initials and colours (BrandMark) while it
    /// loads or when there is none; a local business gets its own initials
    /// and colour, unique in the list (LocalMarks).
    private func brandTile(_ ranked: POIService.RankedPOI, local: LocalMarks.Mark) -> some View {
        let name = ranked.item.name ?? ""
        let mark = BrandMark.mark(for: name)
        let initials = mark?.initials ?? local.initials
        let background = mark?.background ?? local.background
        let ink = mark?.ink ?? local.ink
        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(red: background.r, green: background.g, blue: background.b))
            Text(initials)
                .font(.system(size: initials.count > 2 ? 10 : 13, weight: .heavy,
                              design: .rounded))
                .foregroundStyle(Color(red: ink.r, green: ink.g, blue: ink.b))
                .minimumScaleFactor(0.6)
            if let url = BrandMark.logoURL(for: name) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                            .padding(3)
                            .frame(width: 32, height: 32)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }

    /// At the stop, but the way on could not be planned. Plain words, and
    /// NOT the arrival banner: nothing has been arrived at.
    private func continuationBanner(_ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 26)
            Text(text)
                .scaledFont(size: 16, weight: .semibold)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer()
            Button("Done") { model.endNavigation() }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Arrival confirmation — navigation doesn't just vanish.
    private func arrivedBanner(_ name: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Arrived")
                    .scaledFont(size: 15, weight: .semibold)
                    .opacity(0.85)
                Text(name)
                    .scaledFont(size: 19, weight: .bold)
                    .lineLimit(1)
            }
            Spacer()
            // A round trip: the way back, planned the way the trip there was.
            if model.roundTripHome != nil {
                Button(model.headingBack ? "Planning…" : "Head back") {
                    Task { await model.headBack() }
                }
                .scaledFont(size: 15, weight: .heavy)
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .frame(minHeight: Theme.tapMinimum)
                .background(Color.white)
                .foregroundStyle(Theme.riskGreen)
                .clipShape(Capsule())
                .disabled(model.headingBack)
            }
            Button("Done") { model.endNavigation() }
                .scaledFont(size: 15, weight: .heavy)
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .frame(minHeight: Theme.tapMinimum)
                .background(model.roundTripHome != nil ? Color.white.opacity(0.25) : Color.white)
                .foregroundStyle(model.roundTripHome != nil ? Color.white : Theme.riskGreen)
                .clipShape(Capsule())
        }
        .padding(14)
        .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
        .background(Theme.riskGreen.opacity(0.95))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 14, y: 5)
    }

    // MARK: long-trip share — one nudge per trip (200+ mile route or day)

    /// "Tell someone where you're going." iOS cannot start a Find My live
    /// share for the user (no API — only Messages/Find My can), so this is
    /// the honest version: a prefilled text the driver sends with one tap.
    /// Trigger + message live in TripShareLogic; the one-per-trip latch in
    /// AppModel.maybeOfferTripShare.
    private var tripShareBanner: some View {
        shareBannerBody
            // The picker rides the BANNER (always rendered while the offer is
            // up) — mounted on the fuel cluster it never appeared for walking
            // routes or drivers with no saved vehicle.
            #if os(iOS)
            .sheet(isPresented: $showShareContactPicker) {
                ContactPicker { name, phone in
                    sendShare(name: name, phone: phone)
                }
            }
            // A sheet is presented into its own environment root and does
            // NOT inherit the presenter's appearance — say it again here or
            // settings opens bright white in a dark cab.
            .presentationColorScheme(model.resolvedColorScheme)
            #endif
    }

    @State private var shareErrorText: String?

    private var shareBannerBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Long trip — share your route with someone?",
                  systemImage: "paperplane.fill")
                .scaledFont(size: 15, weight: .bold)
            if let shareErrorText {
                Text(shareErrorText)
                    .scaledFont(.footnote, weight: .semibold)
                    .foregroundStyle(.red)
            }
            Text("Send a text with where you're going, when you'll get there, and a map.")
                .scaledFont(.footnote)
            if showShareChooser {
                shareChooserRows
            } else {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Not now") { model.tripSharePrompt = false }
                        .scaledFont(size: 15, weight: .bold)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .frame(minHeight: Theme.tapMinimum)   // HIG driving target
                        .background(Color.white.opacity(0.25))
                        .clipShape(Capsule())
                    Button("Share") { startShare() }
                        .scaledFont(size: 15, weight: .heavy)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 18)
                        .frame(minHeight: Theme.tapMinimum)
                        .background(Color.white)
                        .foregroundStyle(Theme.onLight)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(12)
        .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
        .background(Theme.cta.opacity(0.95))
        .foregroundStyle(Theme.onCTA)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 14, y: 5)
        .onDisappear { showShareChooser = false }
    }

    /// Share pressed: one obvious candidate → straight to Messages (the
    /// emergency contact is the default). Several → pick from a short list,
    /// best first. None → the contacts picker (iOS; macOS opens settings,
    /// where the emergency contact fields live — it has no CNContactPicker).
    private func startShare() {
        let candidates = model.tripShareCandidates()
        if candidates.count == 1 {
            sendShare(name: candidates[0].name, phone: candidates[0].phone)
        } else if candidates.isEmpty {
            #if os(iOS)
            showShareContactPicker = true
            #else
            model.showSettings = true
            #endif
        } else {
            showShareChooser = true
        }
    }

    /// Suggested people, best first: emergency contact, then the people
    /// actually texted before (frequency + recency, from on-device history).
    private var shareChooserRows: some View {
        VStack(spacing: 6) {
            ForEach(Array(model.tripShareCandidates().prefix(4).enumerated()),
                    id: \.offset) { index, person in
                Button { sendShare(name: person.name, phone: person.phone) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: index == 0 ? "star.fill" : "person.fill")
                            .scaledFont(size: 13)
                        Text(person.name)
                            .scaledFont(size: 14, weight: .semibold)
                            .lineLimit(1)
                        Spacer()
                        Text("Text")
                            .scaledFont(size: 13, weight: .heavy)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                            .background(Color.white)
                            .foregroundStyle(Theme.onLight)
                            .clipShape(Capsule())
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: Theme.tapMinimum)
                    .background(Color.white.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            #if os(iOS)
            Button("Someone else") { showShareContactPicker = true }
                .scaledFont(size: 14, weight: .bold)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Color.white.opacity(0.25))
                .clipShape(Capsule())
            #endif
        }
    }

    /// Open Messages prefilled (driver still taps send — apps cannot send a
    /// text silently) and remember the recipient for future suggestions.
    private func sendShare(name: String, phone: String) {
        guard let url = model.tripShareURL(phone: phone) else {
            // No usable number (a contact card with no phone) — keep the
            // banner up and say why, or the one-per-trip offer would vanish
            // with no message sent and never come back.
            shareErrorText = "That contact has no phone number. Pick someone else."
            return
        }
        openURL(url)
        model.shareHistory.recordShare(name: name, phone: phone)
        shareErrorText = nil
        showShareChooser = false
        model.tripSharePrompt = false
    }

    // MARK: escalating-risk prompt — flashing, driver-approved reroute

    private func escalationBanner(_ escalation: AppModel.Escalation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(escalation.headline)
                    .scaledFont(size: 15, weight: .bold)
                    .lineLimit(2)
            } icon: {
                Image(systemName: "exclamationmark.octagon.fill")
                    .scaledFont(size: 20)
            }
            HStack(spacing: 8) {
                Text("Risk on this route has risen to \(FlowsCore.riskBand(score: escalation.newRisk).rawValue).")
                    .scaledFont(.footnote)
                Spacer()
                Button("Continue") { model.dismissEscalation() }
                    .scaledFont(size: 15, weight: .bold)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .frame(minHeight: Theme.tapMinimum)   // HIG driving target
                    .background(Color.white.opacity(0.25))
                    .clipShape(Capsule())
                Button("Reroute") {
                    Task { await model.approveEscalationReroute() }
                }
                .scaledFont(size: 15, weight: .heavy)
                .buttonStyle(.plain)
                .padding(.horizontal, 18)
                .frame(minHeight: Theme.tapMinimum)
                .background(Color.white)
                .foregroundStyle(Theme.riskRed)
                .clipShape(Capsule())
            }
        }
        .padding(12)
        .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
        .background(
            (FlowsCore.riskBand(score: escalation.newRisk) == .red
             ? Theme.riskRed : Theme.riskYellow)
                .opacity(escalationPulse ? 0.95 : 0.65))
        .foregroundStyle(FlowsCore.riskBand(score: escalation.newRisk) == .red ? .white : .black)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 14, y: 5)
        // Scoped to THIS view. A repeatForever driven through withAnimation
        // puts every view updated in the same transaction into the repeating
        // animation — which is how a hazard pulse ended up blinking the
        // music menu's rows. Reduce Motion (and photosensitivity) holds the
        // banner at its strong opacity instead of breathing it.
        .animation(reduceMotion ? nil
                   : .easeInOut(duration: 0.55).repeatForever(autoreverses: true),
                   value: escalationPulse)
        .onAppear { escalationPulse = true }
        .onDisappear { escalationPulse = false }
    }

    // MARK: imminent hazard — shared banner (also shown while planning)

    private func imminentBanner(_ warning: AppModel.ImminentWarning) -> some View {
        ImminentBannerView(
            warning: warning, isCompact: isCompact,
            // Its X tucks it into the tray with the other icons; the warning
            // is still in force and a tap brings it back.
            onDismiss: { model.tuckImminentWarning() },
            onShelterDelay: warning.action == .shelter ? {
                model.beginShelter(for: warning)
                // Only look for a place when a place is the answer — for a
                // visibility or hydroplaning hazard the vehicle IS shelter.
                if ShelterPolicy.kind(forEvent: warning.event,
                                      severityScore: warning.severityScore)
                    != .inVehicle {
                    // A fresh search brings a tucked stop list back out.
                    model.collapsedPanels.remove("stops")
                    Task { await model.poi.request(.shelter,
                                                   aheadOf: model.effectivePosition) }
                }
            } : nil,
            onFindRest: warning.action == .restArea ? {
                model.collapsedPanels.remove("stops")
                Task { await model.poi.request(.rest, aheadOf: model.effectivePosition) }
            } : nil)
    }

    /// Sheltering time already added to the ETA — visible so the driver
    /// knows the arrival time includes it. Only the wait still ahead: it
    /// counts down with the shelter timer, as the ETA does (a part-minute
    /// reads as a whole one, never "+0 min").
    private var shelterDelayChip: some View {
        Label(String(format: "+%.0f min stopped time in ETA",
                     (model.stopDelayAheadSeconds / 60).rounded(.up)),
              systemImage: "clock.badge.exclamationmark")
            .scaledFont(.footnote, weight: .semibold)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.cardBackground)
            .clipShape(Capsule())
            .shadow(color: Theme.cardShadow, radius: 8, y: 3)
    }

    /// Next scheduled trip need (fuel/food/rest cadence) with its countdown;
    /// tapping runs that need's POI search.
    private func tripNeedChip(_ event: TripNeeds.Event) -> some View {
        let currentMile = model.tripNeedsMile
        return Button {
            Task { await model.requestTripNeed(event) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: event.need.symbol)
                Text("\(event.need.label) in \(Int(max(event.mile - currentMile, 0).rounded())) mi")
            }
            .scaledFont(.footnote, weight: .semibold)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.cardBackground)
            .clipShape(Capsule())
            .shadow(color: Theme.cardShadow, radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    // MARK: instruction banner

    /// Top-center, built for a half-second glance: the DISTANCE COUNTDOWN is
    /// the biggest thing on screen (monospaced digits so it ticks in place),
    /// with the maneuver text right under it.
    @ViewBuilder
    private var instructionBanner: some View {
        if let g = model.navigation.guidance {
            banner(distance: distanceText(g.distanceToManeuver),
                   instruction: g.instruction,
                   rerouting: model.navigation.isRerouting,
                   live: true)
        } else if let route = model.navigation.route {
            // No GPS fix yet: route preview instead of an empty HUD — first
            // real instruction plus a "waiting" chip so the state is obvious.
            banner(distance: "Waiting for GPS — previewing route",
                   instruction: firstInstruction(of: route),
                   rerouting: false,
                   live: false)
        }
    }

    /// How much longer to sit out the hazard, live, in the directions
    /// window. Tapping it reopens the alert with a way out.
    @ViewBuilder
    private var shelterCountdown: some View {
        if let session = model.shelterSession {
            Button { showShelterSheet = true } label: {
                VStack(spacing: 0) {
                    Image(systemName: session.kind == .inVehicle
                          ? "car.fill" : "house.fill")
                        .scaledFont(size: 13, weight: .bold)
                    Text(ShelterPolicy.countdownText(
                        session.until.timeIntervalSince(shelterTick)))
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("shelter")
                        .scaledFont(size: 9, weight: .semibold)
                        .opacity(0.75)
                }
                .foregroundStyle(Theme.riskYellow)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Sheltering — tap to leave early or read the official alert")
        }
    }

    /// Tapping the countdown: the two things a sheltering driver might
    /// actually want — go anyway, or read the official word.
    @ViewBuilder
    private var shelterSheet: some View {
        if let session = model.shelterSession {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(session.event, systemImage: "clock.badge.exclamationmark")
                        .scaledFont(size: 15, weight: .bold)
                        .lineLimit(2)
                    Spacer()
                    Button { showShelterSheet = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(session.kind.advice)
                    .scaledFont(size: 13)
                    .foregroundStyle(.secondary)
                Text("\(ShelterPolicy.countdownText(session.until.timeIntervalSince(shelterTick))) left")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                HStack(spacing: 8) {
                    Button {
                        model.endShelter()
                        showShelterSheet = false
                    } label: {
                        Text("Stop timer and drive on")
                            .scaledFont(size: 14, weight: .heavy)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: Theme.tapMinimum)
                            .background(Theme.cta)
                            .foregroundStyle(Theme.onCTA)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    if let url = session.sourceURL {
                        Link(destination: url) {
                            Text("Official report")
                                .scaledFont(size: 14, weight: .heavy)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: Theme.tapMinimum)
                                .background(Theme.fill(0.08))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .floatingCard()
            .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
        }
    }

    private func banner(distance: String, instruction: String,
                        rerouting: Bool, live: Bool) -> some View {
        HStack(spacing: 14) {
            // The lane box IS the arrow beside the directions (owner,
            // 2026-10-01): one arrow per lane, each the movement its lane
            // serves, the lanes to be in green — one green arrow when the
            // lanes aren't known. It MATCHES the words (ManeuverSymbol): a
            // right turn drawn beside "turn left" is worse than no icon.
            laneBox(instruction: instruction, live: live)
            VStack(alignment: .leading, spacing: 1) {
                Text(distance)
                    .font(live
                          ? .system(size: 30, weight: .heavy, design: .rounded)
                          : .system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .opacity(live ? 1 : 0.75)
                Text(instruction)
                    .scaledFont(size: live ? 16 : 19, weight: live ? .semibold : .bold)
                    .opacity(live ? 0.9 : 1)
                    .minimumScaleFactor(0.7)
                    .lineLimit(2)
                // The lanes in words, under the directions.
                if let lanesSaid = laneWords(instruction: instruction) {
                    Text(lanesSaid)
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(Theme.riskGreen)
                        .lineLimit(1)
                }
            }
            // Take the room between the icon and the compass instead of
            // leaving it empty.
            .frame(maxWidth: .infinity, alignment: .leading)
            if rerouting {
                ProgressView()
            }
            if model.shelterSession != nil {
                shelterCountdown
            }
            // On the highway, the exit to take in big numbers, left of the
            // compass (owner, 2026-10-01) — as the green sign shows it.
            if let exit = ManeuverSymbol.exitNumber(in: instruction) {
                exitSign(exit)
            }
            bannerCompass
        }
        .padding(14)
        .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
        .background(Theme.chrome.opacity(0.92))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 14, y: 5)
    }

    /// The lane box: one arrow per lane (LaneBox), lit green where to be.
    /// Arrival keeps its pin; a single arrow is drawn large, many smaller so
    /// a five-lane interchange still fits the window.
    @ViewBuilder
    private func laneBox(instruction: String, live: Bool) -> some View {
        let lanes = model.upcomingLanes
        let arrows = LaneBox.arrows(
            lanes: lanes,
            recommended: LaneData.recommended(lanes: lanes,
                                              maneuver: ManeuverSymbol.side(of: instruction)),
            instruction: instruction)
        let arriving = ManeuverSymbol.symbol(for: instruction) == "mappin.circle.fill"
        let single: CGFloat = live ? 32 : 26
        let size = arrows.count <= 1 ? single : max(14, single - 4 - CGFloat(arrows.count - 1) * 3)
        HStack(spacing: arrows.count > 1 ? 4 : 0) {
            if arriving {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: single, weight: .bold))
                    .foregroundStyle(Theme.riskGreen)
            } else {
                ForEach(Array(arrows.enumerated()), id: \.offset) { _, arrow in
                    LaneArrowGlyph(arrow: arrow, size: size)
                }
            }
        }
        .padding(6)
        .frame(minWidth: live ? 46 : 40, minHeight: live ? 46 : 40)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(laneWords(instruction: instruction) ?? instruction)
    }

    /// The lanes in words ("Use the 2 right lanes"), from the tagged lanes or
    /// what the instruction says; nil when there is nothing to say.
    private func laneWords(instruction: String) -> String? {
        let lanes = model.upcomingLanes
        if !lanes.isEmpty {
            let lit = LaneData.recommended(lanes: lanes,
                                           maneuver: ManeuverSymbol.side(of: instruction))
            return LaneData.summary(lanes: lanes, recommended: lit)
        }
        return LaneGuidance.advice(for: instruction)?.text
    }

    /// The exit's number as the green highway sign gives it.
    private func exitSign(_ number: String) -> some View {
        VStack(spacing: 0) {
            Text("EXIT")
                .font(.system(size: 9, weight: .heavy))
            Text(number)
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(.white)
        .background(Color(red: 0, green: 0.42, blue: 0.25),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color.white, lineWidth: 1.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Exit \(number)")
    }

    /// A compass rose on the banner's right: the needle points north while
    /// the map turns with the road, so a glance answers "which way am I
    /// actually headed?" without hunting for a floating control.
    private var bannerCompass: some View {
        let heading = CompassReading.normalized(max(model.location.course, 0))
        return VStack(spacing: 2) {
            ZStack {
                // A lighter face with a rim: on the near-black banner an
                // unrimmed circle simply disappeared.
                Circle().fill(Color.white.opacity(0.16))
                Circle().stroke(Color.white.opacity(0.45), lineWidth: 1)
                Image(systemName: "location.north.fill")
                    .scaledFont(size: 13, weight: .bold)
                    .foregroundStyle(Theme.riskRed)
                    .rotationEffect(.degrees(-heading))
                Text("N")
                    .scaledFont(size: 8, weight: .heavy)
                    .foregroundStyle(.white)
                    .offset(y: -13)
                    .rotationEffect(.degrees(-heading))
            }
            .frame(width: golden.iconCircle * 0.82, height: golden.iconCircle * 0.82)
            // The reading in words and degrees — the part a driver can use
            // without interpreting a needle.
            Text(CompassReading.label(heading))
                .scaledFont(size: 10, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize()
        }
        .animation(.easeOut(duration: 0.3), value: heading)
        .help("Heading")
    }

    private func firstInstruction(of route: PlannedRoute) -> String {
        route.route.steps.first(where: { !$0.instructions.isEmpty })?.instructions
            ?? "Head toward \(route.destinationName)"
    }

    private var alertStrip: some View {
        Label(model.alerts.activeHeadlines[0], systemImage: "exclamationmark.triangle.fill")
            .scaledFont(.footnote, weight: .semibold)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.riskYellow.opacity(0.92))
            .foregroundStyle(.black)
            .clipShape(Capsule())
    }

    // MARK: bottom bar

    /// Every button on the drive bar stands this tall — the controls in the
    /// first row and the stop buttons in the second alike (owner,
    /// 2026-10-01: the two rows' buttons were different sizes).
    private let barButtonHeight: CGFloat = 46

    private var bottomBar: some View {
        // The controls over the stop buttons, the two rows ONE width — the
        // wider of them — so a wide window never shows a first row spread
        // across it over a second row bunched in the middle (the Mac, owner
        // 2026-10-01): the trip total and End move in to meet the stop
        // buttons. One row of controls when it fits, two or three when it
        // doesn't; the stop buttons drop their words before they scroll.
        ViewThatFits(in: .horizontal) {
            barLayout(iconOnlyStops: false) { controlsRow }
            barLayout(iconOnlyStops: true) { controlsRow }
            barLayout(iconOnlyStops: true) { controlsTwoRows }
            // A phone held upright: two rows of controls, and the stop
            // buttons scroll sideways rather than push the controls into a
            // third row.
            VStack(spacing: 8) {
                controlsTwoRows
                ScrollView(.horizontal, showsIndicators: false) {
                    poiButtonRow(iconOnly: false)
                }
            }
            VStack(spacing: 8) {
                controlsThreeRows
                ScrollView(.horizontal, showsIndicators: false) {
                    poiButtonRow(iconOnly: false)
                }
            }
        }
        .floatingCard()
        // The bar hugs its content instead of stretching across the whole
        // window bottom; it stays centered and only goes edge-to-edge on
        // compact (phone-width) layouts.
        .frame(maxWidth: isCompact ? .infinity : nil)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// The controls over the stop buttons. On a wide window the pair takes
    /// the wider row's own width and the other row stretches to it; on a
    /// phone both fill the bar.
    private func barLayout<Controls: View>(iconOnlyStops: Bool,
                                           @ViewBuilder controls: () -> Controls)
        -> some View {
        VStack(spacing: 8) {
            controls()
            poiButtonRow(iconOnly: iconOnlyStops)
        }
        .fixedSize(horizontal: !isCompact, vertical: false)
    }

    /// Trip total, the controls, End — one row.
    private var controlsRow: some View {
        HStack(spacing: 10) {
            tripStats
            Spacer(minLength: 12)
            recenterButton
            if MusicController.isAvailable {
                musicControls
            }
            towingButton
            radioButton
            Spacer(minLength: 12)
            endButton
        }
    }

    /// The same in two rows, for a window too narrow for one.
    private var controlsTwoRows: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                tripStats
                Spacer(minLength: 8)
                recenterButton
                endButton
            }
            HStack(spacing: 10) {
                if MusicController.isAvailable {
                    musicControls
                }
                Spacer(minLength: 8)
                towingButton
                radioButton
            }
        }
    }

    /// Three rows when even two cannot hold the trip total beside the vehicle
    /// view and End (the largest text sizes): the total gets a row of its
    /// own, so End never runs off the bar.
    private var controlsThreeRows: some View {
        VStack(spacing: 8) {
            HStack {
                tripStats
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                recenterButton
                Spacer()
                endButton
            }
            HStack(spacing: 10) {
                if MusicController.isAvailable {
                    musicControls
                }
                Spacer()
                towingButton
                radioButton
            }
        }
    }

    /// Time and distance left, side by side in one type size under a single
    /// "Total" header whose rule spans both — one reading, not two chips.
    /// The tank's remaining range is NOT repeated here; the gauge cluster
    /// above already carries it.
    @ViewBuilder
    private var tripStats: some View {
        // To the final destination, the way on from an added stop included
        // (it used to be this leg alone, under this same header).
        if let remaining = model.tripRemaining {
            VStack(alignment: .leading, spacing: 1) {
                Text(remaining.toStop ? "Remaining to next stop" : "Total remaining to destination")
                    .scaledFont(size: 9, weight: .bold)
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(height: 1)
                HStack(spacing: 8) {
                    Text(etaText(remaining.seconds))
                    Divider().frame(height: 16)
                    Text(distanceText(remaining.meters))
                }
                .scaledFont(size: 17, weight: .bold)
                .monospacedDigit()
            }
            .fixedSize()
        }
    }

    /// Back to the vehicle: a car under a magnifying glass (owner,
    /// 2026-10-01) — it zooms the map back onto the vehicle.
    @ViewBuilder
    private var recenterButton: some View {
        if model.mode == .navigating {
            Button {
                model.recenterRequested = true
            } label: {
                VehicleZoomIcon(size: barButtonHeight * 0.5)
                    .frame(width: barButtonHeight, height: barButtonHeight)
                    .background(Theme.fill(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Zoom back to the vehicle")
            .accessibilityLabel("Zoom back to the vehicle")
        }
    }

    /// Towing: a truck pulling a box trailer, the kind you rent to move.
    private var towingButton: some View {
        Button {
            model.showTowingCard.toggle()
        } label: {
            TowingIcon(size: barButtonHeight * 0.36)
                .frame(width: barButtonHeight, height: barButtonHeight)
                .background(model.towingActive ? Color.brown : Theme.fill(0.06))
                .foregroundStyle(model.towingActive ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Towing: check your weights against your vehicle's limits")
        .accessibilityLabel("Towing")
    }

    private var radioButton: some View {
        Button {
            // Show/hide only — the card is the radio's home and its stop
            // buttons end playback; hiding the card never cuts the audio.
            showRadio.toggle()
        } label: {
            Image(systemName: "radio.fill")
                .scaledFont(size: 15, weight: .semibold)
                .frame(width: barButtonHeight, height: barButtonHeight)
                .background(showRadio ? Color.brown : Theme.fill(0.06))
                .foregroundStyle(showRadio ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(model.truckerUI ? "Trucker radio" : "Emergency radio")
    }

    private var endButton: some View {
        Button("End") { model.endNavigation() }
            .buttonStyle(PillCTAStyle())
            .frame(width: 74, height: barButtonHeight)
    }

    /// The stop buttons, every one as wide as the widest ("Parking" no
    /// longer wider than "Rest") and as tall as the controls above.
    private func poiButtonRow(iconOnly: Bool) -> some View {
        EqualWidthHStack(spacing: 6) {
            ForEach(model.truckerUI ? POIService.Kind.truckerKinds
                                    : POIService.Kind.standardKinds) { kind in
                let selected = model.poi.activeKind == kind
                Button {
                    // The lit button is its stop list's own icon: pressed
                    // while the list is tucked away it brings the list back;
                    // pressed again it clears the search.
                    let reopening = selected && model.collapsedPanels.contains("stops")
                    model.collapsedPanels.remove("stops")
                    guard !reopening else { return }
                    Task {
                        if model.poi.activeKind == kind {
                            model.poi.clearResults()
                        } else {
                            await model.poi.request(kind, aheadOf: model.effectivePosition)
                        }
                    }
                } label: {
                    // Wording above, icon at the bottom; the outer
                    // ViewThatFits swaps in the icon-only variant when the
                    // labeled row can't fit the window.
                    Group {
                        if iconOnly {
                            icon(for: kind)
                        } else {
                            VStack(spacing: 3) {
                                Text(kind.rawValue)
                                    .scaledFont(size: 10, weight: .bold)
                                    .lineLimit(1)
                                    .fixedSize()
                                icon(for: kind)
                            }
                        }
                    }
                    // The icon-only variant loses its text — VoiceOver
                    // must not lose the button's name with it.
                    .accessibilityLabel("Find \(kind.rawValue)")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, minHeight: barButtonHeight)
                    .background(selected ? Theme.cta : Theme.fill(0.06))
                    // The pressed-in chip is the CTA fill, so its contents
                    // take the CTA's ink — which inverts at dusk along with
                    // the fill. A fixed light gray here is white-on-white
                    // after dark and black-on-black before it.
                    .foregroundStyle(selected ? Theme.onCTA : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// LAST CHANCE: only a few stations selling this vehicle's fuel are
    /// still reachable on what's in the tank (FuelWarning). Blinks red, and
    /// the same advice was spoken aloud — one tap adds the cheapest
    /// reachable stop to the route.
    private func lastChanceFuelBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "fuelpump.exclamationmark.fill")
                .scaledFont(size: 18, weight: .bold)
            Text(text)
                .scaledFont(.footnote, weight: .bold)
                .lineLimit(2)
            Spacer(minLength: 4)
            if model.fuelWarningStation != nil {
                Button("Add stop") {
                    Task { await model.addRecommendedFuelStop() }
                }
                .scaledFont(.footnote, weight: .heavy)
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .frame(minHeight: Theme.tapMinimum)
                .background(Color.white)
                .foregroundStyle(Theme.riskRed)
                .clipShape(Capsule())
            }
            Button { model.dismissFuelWarning() } label: {
                Image(systemName: "xmark.circle.fill").opacity(0.8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
        .background(Theme.riskRed.opacity(escalationPulse ? 0.95 : 0.6))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 10, y: 4)
        // Reduce Motion holds it at its strong red, like the escalation card.
        .animation(reduceMotion ? nil
                   : .easeInOut(duration: 0.55).repeatForever(autoreverses: true),
                   value: escalationPulse)
        .onAppear { escalationPulse = true }
    }

    /// Range is getting tight — plan a fuel stop now (vehicle range model).
    /// A fixed enforcement camera coming up. Quiet by design — it states
    /// the distance and gets out of the way, with no button to press,
    /// because the only useful response is to slow down.
    private func cameraChip(_ note: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "camera.fill")
                .scaledFont(size: 13, weight: .bold)
            Text(note)
                .scaledFont(.footnote, weight: .bold)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.85))
        .foregroundStyle(Theme.onDark)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.riskYellow, lineWidth: 1.5))
        .shadow(color: Theme.cardShadow, radius: 8, y: 3)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: note)
    }

    private func fuelRecommendationChip(_ note: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "fuelpump.exclamationmark.fill")
            Text(note)
                .scaledFont(.footnote, weight: .bold)
            Button("Find fuel") {
                model.collapsedPanels.remove("stops")
                Task { await model.poi.request(.gas, aheadOf: model.effectivePosition) }
            }
            .scaledFont(.footnote, weight: .heavy)
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Color.white)
            .foregroundStyle(.orange)
            .clipShape(Capsule())
            Button { model.dismissFuelRecommendation() } label: {
                Image(systemName: "xmark.circle.fill").opacity(0.8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.92))
        .foregroundStyle(.white)
        .clipShape(Capsule())
        .shadow(color: Theme.cardShadow, radius: 8, y: 3)
    }

    /// Straight-line miles from the vehicle to the station the picker is
    /// showing — nil when neither is placeable.
    private var nearestStationMiles: Double? {
        guard let pos = model.effectivePosition,
              let channel = model.radio.channels.first(where: { $0.id == radioChannelID }),
              let p = TruckerRadio.position(of: channel) else { return nil }
        return POIRanking.meters(p.coordinate, pos) / 1609.344
    }

    /// Point the picker at the closest available station.
    ///
    /// While a station from its list is playing the picker must name the
    /// station actually on the air — auto-tune moves that as the drive
    /// crosses into the next coverage area, and a picker left on the old
    /// name would be a lie. An AM/FM stream isn't in the list (naming it
    /// left the picker blank), so then, as while nothing is playing, it
    /// simply tracks the nearest transmitter, so the default is right for
    /// wherever the vehicle IS, not for wherever it was when the card first
    /// opened.
    private func preselectNearestStation() {
        if let playing = model.radio.playingChannelID,
           model.radio.channels.contains(where: { $0.id == playing }) {
            radioChannelID = playing
            return
        }
        if let pos = model.effectivePosition,
           let nearest = model.radio.nearestChannel(to: pos) {
            radioChannelID = nearest.channel.id
        } else if let nearest = model.radio.nearestChannel(stateCode: model.currentStateCode) {
            radioChannelID = nearest.id
        }
    }

    /// The driver chose a station in the picker. While a station from its
    /// list is on the air the picker names it, so the new pick is tuned at
    /// once instead of the name and the sound parting ways.
    private func pickStation(_ id: String) {
        radioChannelID = id
        guard let playing = model.radio.playingChannelID, playing != id,
              model.radio.channels.contains(where: { $0.id == playing }),
              let channel = model.radio.channels.first(where: { $0.id == id })
        else { return }
        playStation(channel)
    }

    /// Back or forward one weather relay from the one on the air, in the
    /// picker's order (wrapping), pinned as a hand pick.
    private func stepWeatherRadio(by delta: Int) {
        let channels = model.radio.channels
        guard !channels.isEmpty else { return }
        let at = channels.firstIndex { $0.id == (model.radio.playingChannelID ?? radioChannelID) } ?? 0
        playStation(channels[(at + delta + channels.count) % channels.count])
    }

    /// Play a station from the card. One chosen over the nearest transmitter
    /// is pinned, or auto-tune would move it back on the next fix.
    private func playStation(_ channel: TruckerRadio.Channel) {
        radioChannelID = channel.id
        model.radio.play(channel, pinned: RadioTuning.isHandPick(
            channel.id, nearestID: model.nearestStationID))
    }

    /// Radio: everything FLOWS can play or point to, in the owner's order
    /// (2026-10-01) — AM/FM stations first, then the streaming services that
    /// work inside FLOWS (in the same row format), the police and fire
    /// scanner, the emergency weather radio, and last the guide for tuning a
    /// car's own radio. Trucker radio in trucker mode, emergency radio for
    /// everyone else — same card. (The HUD's shared card region scrolls it
    /// when the window is short.)
    private var radioCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(model.truckerUI ? "Trucker radio" : "Emergency radio",
                      systemImage: "radio.fill")
                    .scaledFont(size: 15, weight: .bold)
                Spacer()
                // X = minimize back into the bar's radio button — playback
                // keeps going; the stop buttons in the card end it.
                Button {
                    showRadio = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close the radio")
                .help("Tuck the radio card away")
            }
            amfmSection
            Divider()
            streamingSection
            Divider()
            scannerSection
            Divider()
            weatherRadioSection
            Divider()
            onDeviceSection
        }
        .floatingCard()
        .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
    }

    /// A section's name, in the same weight everywhere on the card.
    private func radioSectionTitle(_ title: String) -> some View {
        Text(title).scaledFont(.caption, weight: .bold)
    }

    /// One row in the card's station format: a name, a line under it, and the
    /// row's controls at the end — shared by every section so they read as
    /// one list.
    private func stationRow(_ name: String, detail: String?, playing: Bool = false,
                            symbol: String = "play.fill",
                            play: @escaping () -> Void,
                            pause: @escaping () -> Void = {},
                            back: (() -> Void)? = nil,
                            forward: (() -> Void)? = nil) -> some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .scaledFont(.caption2, weight: .semibold)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            rowTransport(playing: playing, name: name, symbol: symbol,
                         play: play, pause: pause, back: back, forward: forward)
        }
        // Clear of a list's scroll bar, which runs down the right edge
        // (owner, 2026-10-01: the play buttons sat under it).
        .padding(.trailing, 12)
    }

    /// A row's controls, the same in every section: a wide play button when
    /// the row isn't playing; back, pause and forward while it is — back and
    /// forward walk the section's list (owner, 2026-10-01: wider, easier to
    /// press, with back and forward either side).
    private func rowTransport(playing: Bool, name: String, symbol: String,
                              play: @escaping () -> Void, pause: @escaping () -> Void,
                              back: (() -> Void)?, forward: (() -> Void)?) -> some View {
        HStack(spacing: 6) {
            if playing, let back {
                transportButton("backward.fill", label: "Previous", action: back)
            }
            Button(action: playing ? pause : play) {
                Image(systemName: playing ? "pause.fill" : symbol)
                    .scaledFont(size: 15, weight: .bold)
                    .frame(width: 58, height: 34)
                    .background(playing ? Theme.cta : Color.brown)
                    .foregroundStyle(playing ? Theme.onCTA : Color.white)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? "Pause \(name)" : "Play \(name)")
            if playing, let forward {
                transportButton("forward.fill", label: "Next", action: forward)
            }
        }
    }

    private func transportButton(_ symbol: String, label: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(size: 12, weight: .bold)
                .frame(width: 34, height: 34)
                .background(Theme.fill(0.08))
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// One chip in a section's row of kinds, the same in every section.
    private func radioChip(_ title: String, symbol: String, on: Bool, label: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .scaledFont(size: 11, weight: .semibold)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(on ? Theme.cta : Theme.fill(0.06))
                .foregroundStyle(on ? Theme.onCTA : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// A section's search line, the same in every section: the field, a
    /// "Near me" when the section has one, and a mic.
    private func radioSearchLine(_ prompt: String, text: Binding<String>, focus: RadioSearch,
                                 nearMe: (() -> Void)?, listening: Bool,
                                 micLabel: String, onSubmit: @escaping () -> Void,
                                 onMic: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .focused($radioSearchFocus, equals: focus)
                .scaledFont(.caption)
                .onSubmit(onSubmit)
            if let nearMe {
                Button("Near me", action: nearMe)
                    .buttonStyle(.plain)
                    .scaledFont(.caption, weight: .bold)
                    .foregroundStyle(.blue)
            }
            Button(action: onMic) {
                Image(systemName: listening ? "waveform" : "mic.fill")
                    .scaledFont(size: 14, weight: .semibold)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .accessibilityLabel(listening ? "Listening" : micLabel)
        }
    }

    /// AM/FM: the community radio-browser.info directory, searched by the
    /// state the vehicle is in (or any word). Streams are https internet
    /// relays and play through the same player as the weather radio.
    private var amfmSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            radioSectionTitle("AM/FM stations")
                .onAppear {
                    guard model.radioBrowser.stations.isEmpty else { return }
                    let code = model.currentStateCode
                    Task {
                        await model.radioBrowser.searchNearby(
                            near: model.effectivePosition, stateCode: code)
                    }
                }
            // Pick a KIND and it plays. Nobody knows the call letters in a
            // town they're passing through, and picking a genre that then
            // sits there waiting for a second tap is a step for nothing —
            // so choosing one tunes its nearest station straight away and
            // loads the rest as the queue. The player arrows then walk that
            // list, wrapping from the last back to the first.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(BroadcastRadio.Kind.allCases) { kind in
                        radioChip(kind.title, symbol: kind.symbol, on: radioGenre == kind,
                                  label: "Play \(kind.title) radio") { playGenre(kind) }
                    }
                }
            }
            // Spoken station pick: "weather radio", "KMFA", "bluegrass".
            radioSearchLine("Search by name or genre", text: $stationSearch, focus: .station,
                            nearMe: {
                                stationSearch = ""
                                radioGenre = nil
                                let code = model.currentStateCode
                                Task {
                                    await model.radioBrowser.searchNearby(
                                        near: model.effectivePosition, stateCode: code)
                                }
                            },
                            listening: radioMicListening,
                            micLabel: "Say a station or genre",
                            onSubmit: {
                                let query = stationSearch
                                radioGenre = nil
                                Task { await model.radioBrowser.search(text: query) }
                            },
                            onMic: {
                                guard !radioMicListening else { return }
                                radioMicListening = true
                                VoiceReply.shared.listenForDictation { transcript in
                                    radioMicListening = false
                                    guard let transcript else { return }
                                    stationSearch = transcript
                                    model.playRadioAsk(transcript)
                                }
                            })
            if let note = model.radioBrowser.status {
                Text(note).scaledFont(.caption2).foregroundStyle(.secondary)
            }
            if !model.radioBrowser.stations.isEmpty {
                // Bounded list: the card floats over the map with no outer
                // scroll, so the stations scroll INSIDE their own strip.
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.radioBrowser.stations.prefix(30)) { station in
                            amfmStationRow(station)
                        }
                    }
                }
                .frame(maxHeight: isCompact ? 150 : 190)
                Text("Station list: radio-browser.info, a community "
                     + "directory. Stations play as internet streams.")
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The service the streaming chips and search play on: the picked one
    /// when it plays here, else Apple Music.
    private var streamingTarget: MusicProvider {
        let picked = model.musicProvider
        return MusicProvider.streamingInFLOWS.contains(picked)
            && picked.controllable(onMac: Self.onMac, spotifyLinked: spotify.linked)
            ? picked : .appleMusic
    }

    /// A genre or a search, played on the streaming service — the same ask
    /// Siri and the mini player's mic make.
    private func playStreaming(_ term: String) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let target = streamingTarget
        // Picked without the play/pause chooseMusicProvider does — the ask
        // itself starts the music.
        if model.musicProvider != target { model.musicProvider = target }
        model.playMusicAsk(term)
    }

    /// The streaming services that play INSIDE FLOWS, laid out like AM/FM
    /// (owner, 2026-10-01): kinds to play, a search with a mic, then the
    /// services. Apple Music, and Spotify where it can be driven from here (a
    /// Mac, or an iPhone with a Spotify token); no other service lets an app
    /// control it, so the rest are not listed as if they played here.
    private var streamingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            radioSectionTitle("Streaming — \(streamingTarget.displayName)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MusicController.genreKinds) { kind in
                        radioChip(kind.title, symbol: kind.symbol, on: streamGenre == kind,
                                  label: "Play \(kind.title) on \(streamingTarget.displayName)") {
                            streamGenre = kind
                            playStreaming(kind.title)
                        }
                    }
                }
            }
            radioSearchLine("Search a song, artist or album", text: $streamSearch,
                            focus: .streaming, nearMe: nil,
                            listening: musicMicListening,
                            micLabel: "Say a song, artist or album",
                            onSubmit: {
                                streamGenre = nil
                                playStreaming(streamSearch)
                            },
                            onMic: {
                                guard !musicMicListening else { return }
                                musicMicListening = true
                                VoiceReply.shared.listenForDictation { transcript in
                                    musicMicListening = false
                                    guard let transcript else { return }
                                    streamSearch = transcript
                                    streamGenre = nil
                                    playStreaming(transcript)
                                }
                            })
            ForEach(MusicProvider.streamingInFLOWS, id: \.self) { provider in
                let works = provider.controllable(onMac: Self.onMac,
                                                  spotifyLinked: spotify.linked)
                let playing = model.musicProvider == provider && music.isPlaying && works
                stationRow(provider.displayName,
                           detail: works ? "Plays right here in FLOWS"
                                         : "Add a Spotify token (⚙ Settings → Keys for "
                                           + "extra info) to play it here",
                           playing: playing,
                           symbol: works ? "play.fill" : "arrow.up.forward.app",
                           play: {
                               if model.musicProvider == provider, works {
                                   MusicController.shared.playPause()
                               } else {
                                   model.chooseMusicProvider(provider)
                               }
                           },
                           pause: { MusicController.shared.playPause() },
                           back: { MusicController.shared.back() },
                           forward: { MusicController.shared.skip() })
            }
        }
    }

    /// Whether this is the Mac (Spotify answers to the Mac app directly).
    private static var onMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// The city 911 lists the scanner card offers, nearest first, narrowed
    /// by the search.
    private var scannerFeeds: [OpenDispatch.Feed] {
        let all = OpenDispatch.byDistance(from: model.effectivePosition)
        let q = scannerSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.city.lowercased().contains(q) || $0.what.lowercased().contains(q) }
    }

    /// The city list being read right now, if any.
    private var scannerPlayingID: String? {
        guard model.scanner.enabled else { return nil }
        return model.openDispatch.watchedFeedID
            ?? model.openDispatch.activeFeeds.first?.id
    }

    /// Read one city's list (and switch the calls on).
    private func watchScannerFeed(_ feed: OpenDispatch.Feed) {
        model.openDispatch.watchedFeedID = feed.id
        if !model.scanner.enabled { model.scanner.enabled = true }
    }

    /// Scanner: police, fire and EMS, laid out like AM/FM (owner,
    /// 2026-10-01). The chips pick which calls show on the map; the list is
    /// the cities that publish their 911 calls as free public data, nearest
    /// first — play reads one, pins its calls and says a threat near you out
    /// loud. Broadcastify's own player is offered below: its terms let no app
    /// play or transcribe its streams without a licence.
    private var scannerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            radioSectionTitle("Scanner — police, fire, EMS")
            HStack(spacing: 6) {
                ForEach(AppModel.ScannerGroup.allCases) { group in
                    let on = model.scannerGroups.contains(group)
                    radioChip(group.rawValue, symbol: group.symbol, on: on,
                              label: on ? "Hide \(group.rawValue) calls"
                                        : "Show \(group.rawValue) calls") {
                        if on { model.scannerGroups.remove(group) } else { model.scannerGroups.insert(group) }
                        if !model.scanner.enabled { model.scanner.enabled = true }
                    }
                }
            }
            radioSearchLine("Search a city", text: $scannerSearch, focus: .scanner,
                            nearMe: {
                                scannerSearch = ""
                                model.openDispatch.watchedFeedID = nil
                                if !model.scanner.enabled { model.scanner.enabled = true }
                            },
                            listening: scannerMicListening, micLabel: "Say a city",
                            onSubmit: {},
                            onMic: {
                                guard !scannerMicListening else { return }
                                scannerMicListening = true
                                VoiceReply.shared.listenForDictation { transcript in
                                    scannerMicListening = false
                                    guard let transcript else { return }
                                    scannerSearch = transcript
                                    if let feed = scannerFeeds.first { watchScannerFeed(feed) }
                                }
                            })
            let feeds = scannerFeeds
            ForEach(feeds) { feed in
                let playing = scannerPlayingID == feed.id
                let index = feeds.firstIndex { $0.id == feed.id } ?? 0
                stationRow("\(feed.city) — \(feed.what)",
                           detail: "City 911 list, \(feed.delay)",
                           playing: playing,
                           play: { watchScannerFeed(feed) },
                           pause: {
                               model.openDispatch.watchedFeedID = nil
                               model.scanner.enabled = false
                           },
                           back: { watchScannerFeed(feeds[(index - 1 + feeds.count) % feeds.count]) },
                           forward: { watchScannerFeed(feeds[(index + 1) % feeds.count]) })
            }
            if let status = model.openDispatch.status, model.scanner.enabled {
                Text(status).scaledFont(.caption2).foregroundStyle(.secondary)
            }
            stationRow("Live scanner audio near you",
                       detail: "Broadcastify's own player, at the feeds closest to you",
                       symbol: "arrow.up.forward.app",
                       play: { openURL(ScannerLinks.broadcastifyNearMe) })
            if let code = model.currentStateCode,
               let stateURL = ScannerLinks.stateFeedsURL(stateCode: code) {
                stationRow("Every \(code) scanner feed",
                           detail: "Pick your county on Broadcastify",
                           symbol: "list.bullet",
                           play: { openURL(stateURL) })
            }
            stationRow("Recordings (a few minutes behind)",
                       detail: "OpenMHz, a volunteer archive of dispatch radio",
                       symbol: "clock.arrow.circlepath",
                       play: { openURL(ScannerLinks.openMHz) })
            Text("Scanner listening rules differ by state — where it isn't "
                 + "allowed while driving, listen only when parked.")
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Whether the weather radio itself is on the air — not any station:
    /// with an AM/FM station playing, its button showed Stop too.
    private var weatherRadioPlaying: Bool {
        guard let playing = model.radio.playingChannelID else { return false }
        return model.radio.channels.contains { $0.id == playing }
    }

    /// NOAA Weather Radio: ONE dynamically-tuned relay — defaults to the
    /// transmitter closest to the GPS position and auto-switches as you
    /// drive (20% hysteresis). The picker stays for manual override.
    private var weatherRadioSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            radioSectionTitle("Emergency weather radio")
            HStack(spacing: 8) {
                Picker("Station", selection: Binding(
                    get: { radioChannelID },
                    set: { pickStation($0) })) {
                    ForEach(model.radio.channels) { channel in
                        Text(channel.name).tag(channel.id)
                    }
                }
                .labelsHidden()
                // One line, and allowed to SHRINK rather than being forced
                // to its intrinsic width: fixedSize in a narrow card pushed
                // "NOAA WX IL-Dixon: KZZ55" past the edge and the label came
                // out crushed together and unreadable.
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The same controls as every row: back and forward step
                // through the relays while one is on the air.
                rowTransport(playing: weatherRadioPlaying, name: "the weather radio",
                             symbol: "play.fill",
                             play: {
                                 if let channel = model.radio.channels.first(where: { $0.id == radioChannelID })
                                     ?? model.effectivePosition.flatMap({ model.radio.nearestChannel(to: $0)?.channel })
                                     ?? model.radio.nearestChannel(stateCode: model.currentStateCode) {
                                     playStation(channel)
                                 }
                             },
                             pause: { model.radio.stop() },
                             back: { stepWeatherRadio(by: -1) },
                             forward: { stepWeatherRadio(by: 1) })
            }
            .padding(.trailing, 12)
            .onAppear { preselectNearestStation() }
            .onChange(of: model.currentStateCode) { _, _ in preselectNearestStation() }
            // The two ways the right station changes mid-drive: the vehicle
            // moves nearer a different transmitter, or auto-tune has already
            // switched the one playing.
            .onChange(of: model.nearestStationID) { _, _ in preselectNearestStation() }
            .onChange(of: model.radio.playingChannelID) { _, _ in preselectNearestStation() }
            // How far off the relay actually is. NOAA runs about a thousand
            // transmitters; only ~68 of them are relayed over the internet
            // at all, so the closest one you can LISTEN to is often a long
            // way from the windshield. Saying the distance is the honest
            // thing — the alerts on a relay two states over are for two
            // states over.
            if let miles = nearestStationMiles {
                Text(miles < 60
                     ? String(format: "Closest relay — %.0f mi away", miles)
                     : String(format: "Closest relay — %.0f mi away. It covers "
                              + "its own area, not yours; your local "
                              + "transmitter isn't relayed online.", miles))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Only worth a line when it says something the title doesn't —
            // "Playing <station>" under a heading already naming the station
            // is noise.
            if let status = model.radio.status,
               !status.hasPrefix("Playing ") {
                Text(status).scaledFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Last: what a car's own radio can tune — the channels with no internet
    /// relay, and the cab channels that have one.
    private var onDeviceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            radioSectionTitle("On device radio")
            // Each cab channel gets its own row + play button. CB (27 MHz) and
            // Highway Advisory AM are LOCAL two-way/low-power broadcasts with
            // no licensed internet relays — those play buttons stay disabled
            // with the frequency to tune on the physical radio; any entry that
            // gains a stream URL (trucker_radio.json) lights up.
            // Playable stations lead; channels with no internet relay
            // collapse into one line below instead of a wall of grayed rows.
            ForEach(TruckerRadio.frequencyGuide.filter {
                model.radio.cabStream(for: $0.0) != nil
            }, id: \.0) { channel, what in
                if let stream = model.radio.cabStream(for: channel) {
                    stationRow(channel, detail: what,
                               playing: model.radio.playingChannelID == stream.id,
                               play: { model.radio.play(stream) },
                               pause: { model.radio.stop() })
                }
            }
            // No law-enforcement row. There is no lawful, keyless feed to
            // offer, and a paragraph explaining WHY a thing is missing takes
            // more of the card than the thing would have — so it is simply
            // absent, the way an unavailable channel should be.
            let overAir = TruckerRadio.frequencyGuide.filter {
                model.radio.cabStream(for: $0.0) == nil
            }
            // One tight line per channel: what to tune and what it reports.
            // Trucker mode lists every cab channel (CB needs a CB set);
            // everyone else sees only what a normal car radio can tune —
            // the band, the dial position, and what that station reports.
            let tunable: [String] = model.truckerUI
                ? overAir.map { "\($0.0) — \(TruckerRadio.shortPurpose($0.0))" }
                : overAir.compactMap { entry in
                    TruckerRadio.carBandLabel(entry.0).map {
                        "\($0) — \(TruckerRadio.shortPurpose(entry.0))"
                    }
                }
            if !tunable.isEmpty {
                Text((model.truckerUI ? "Car radio only: " : "Car radio: ")
                     + tunable.joined(separator: " · "))
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One AM/FM search result: name + genre words, and the same brown
    /// play/stop control as the relay rows.
    /// Choosing a genre: fetch its stations near here, then start the first
    /// one and hand the whole list to the player as the queue.
    private func playGenre(_ kind: BroadcastRadio.Kind) {
        radioGenre = kind
        stationSearch = ""
        Task {
            await model.radioBrowser.searchGenre(kind, near: model.effectivePosition)
            let channels = model.radioBrowser.stations.map(\.channel)
            guard !channels.isEmpty else { return }
            model.radio.playQueue(channels, label: kind.title)
        }
    }

    private func amfmStationRow(_ station: RadioBrowser.Station) -> some View {
        // Dial position first when the name carries one — "105.7 FM" is what
        // a driver would say — then the genre words.
        let detail = [station.dialLabel, station.genre.isEmpty ? nil : station.genre]
            .compactMap { $0 }.joined(separator: " · ")
        let current = model.radio.playingChannelID == station.channel.id
        return stationRow(station.name, detail: detail,
                          playing: current && !model.radio.isPaused,
                          play: {
                              if current {
                                  model.radio.pauseOrResume()   // back on the air
                              } else {
                                  // The visible list IS the queue — back and
                                  // forward (and the mini player's skip) walk
                                  // these stations.
                                  let channels = model.radioBrowser.stations.map(\.channel)
                                  let start = channels.firstIndex { $0.id == station.channel.id } ?? 0
                                  model.radio.playQueue(
                                      channels,
                                      label: stationSearch.isEmpty ? "these stations" : stationSearch,
                                      startAt: start)
                              }
                          },
                          pause: { model.radio.pauseOrResume() },
                          back: { _ = model.radio.previousStation() },
                          forward: { _ = model.radio.nextStation() })
    }

    @ViewBuilder
    private func icon(for kind: POIService.Kind) -> some View {
        if model.poi.isSearching && model.poi.activeKind == kind {
            // The spinner only ever appears on the PRESSED button, whose
            // fill is the CTA — near-black by day and near-white by night.
            // Untinted, or tinted a fixed light gray, it vanishes into one
            // of the two.
            ProgressView().controlSize(.small).tint(Theme.onCTA)
        } else if kind == .rest {
            BenchIcon(size: 16)   // the actual park bench
        } else {
            Image(systemName: kind.symbol)
                .scaledFont(size: 15, weight: .semibold)
        }
    }

    /// GPS saw a fuel-stop-length dwell → the analog gauge asks where the
    /// needle was BEFORE the fill (trains the refuel prediction toward its
    /// 80% accuracy floor). Dismissing assumes a full refuel.
    private var refuelGauge: some View {
        GasGaugeCard(
            predictedFraction: model.vehicle.predictedFuelFraction ?? 0.5,
            accuracy: model.vehicle.refuelLearning.accuracy,
            onConfirm: { fraction in
                model.answerRefuelPrompt(didFill: true, fractionBefore: fraction)
            },
            onNoRefuel: { model.answerRefuelPrompt(didFill: false) },
            onDismiss: { model.answerRefuelPrompt(didFill: true) })
    }

    /// The grade table applied: "7.2% grade in 1.4 mi".
    private func steepGradeChip(_ seg: GradeSegment) -> some View {
        let currentMile = (model.navigation.guidance?.alongMeters ?? 0) / 1609.344
        let inMiles = max(seg.startMile - currentMile, 0)
        return Label(
            String(format: "%.1f%% (%.1f°) grade in %.1f mi",
                   abs(seg.gradePercent), abs(seg.gradeDegrees), inMiles),
            systemImage: seg.gradePercent >= 0 ? "arrow.up.right" : "arrow.down.right")
            .scaledFont(.footnote, weight: .bold)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.riskYellow.opacity(0.92))
            .foregroundStyle(.black)
            .clipShape(Capsule())
            .shadow(color: Theme.cardShadow, radius: 8, y: 3)
    }

    /// FMCSA §395.3 hours-of-service checkpoints (trucker mode), in plain
    /// words on the chip.
    private var hosChip: some View {
        let text: String
        switch model.hosStatus {
        case .breakSoon(let until):
            text = String(format: "Driving hours: 30-min break due in %.0f min", until / 60)
        case .breakDue:
            text = "Driving hours: 8 h driven — take your 30-min break now"
        case .limitReached:
            text = "Driving hours: 11 h limit reached — stop driving"
        case .ok:
            text = ""
        }
        return Label(text, systemImage: "clock.badge.exclamationmark.fill")
            .scaledFont(.footnote, weight: .bold)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(model.hosStatus == .limitReached
                        ? Theme.riskRed.opacity(0.92) : Theme.riskYellow.opacity(0.92))
            .foregroundStyle(model.hosStatus == .limitReached ? .white : .black)
            .clipShape(Capsule())
            .shadow(color: Theme.cardShadow, radius: 8, y: 3)
    }


    /// Hands-free music: play/pause, skip, shuffle — mirrored as Siri App
    /// Intents ("skip track in FLOWS") so nothing needs a tap while driving.
    private var musicControls: some View {
        HStack(spacing: 4) {
            // Album art (real artwork on iOS; placeholder tile on macOS,
            // track name in the tooltip). Tapping opens the quick music
            // menu — its rows match what the picked service can actually
            // do (in-place transport, or deep links into its own app). Not
            // for the radio: everything radio lives in the radio card now,
            // and its "FM" tile beside the arrows was a second door to it
            // (owner, 2026-10-01).
            if model.musicProvider != .radio {
            Button {
                showMusicMenu.toggle()
            } label: {
                Group {
                    if model.musicControllable, let art = music.artwork {
                        Image(decorative: art, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        // The active SERVICE, visibly: a brand-colored
                        // monogram (logos need each service's asset license).
                        Text(model.musicProvider.monogram)
                            .scaledFont(size: 14, weight: .heavy)
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 30, height: 30)
                .background(model.musicControllable && music.artwork != nil
                            ? Color.black.opacity(0.08)
                            : model.musicProvider.badgeColor)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(music.trackName.isEmpty
                  ? model.musicProvider.displayName : music.trackName)
            }
            // The token-aware gate, like the skip button below: a linked
            // Spotify on iPhone gets back and play/pause, not "Open Spotify".
            if model.musicControllable {
            Button {
                // Radio walks its own station queue, and starts one when
                // there isn't one yet — the arrows are never dead.
                if model.musicProvider == .radio {
                    model.radioStep(forward: false)
                } else {
                    music.back()
                }
            } label: {
                Image(systemName: "backward.fill")
                    .frame(width: 30, height: Theme.tapMinimum)
            }
            .buttonStyle(.plain)
            .help(model.musicProvider == .radio ? "Previous station" : "Previous track")
            .accessibilityLabel(model.musicProvider == .radio
                                ? "Previous station" : "Previous track")
            // Shows PAUSE while playing (press to stop), PLAY while paused.
            Button { model.playMusic() } label: {
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 30, height: Theme.tapMinimum)
            }
            .buttonStyle(.plain)
            .help(music.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(music.isPlaying ? "Pause" : "Play")
            } else {
            // HONEST CONTROLS: this service can't be driven from inside
            // FLOWS on this platform (it needs the service's own kit and
            // key) — one clear "open the app" beats skip buttons that
            // secretly just launch it. AM/FM is the exception: FLOWS plays
            // that itself, so it says what it is rather than "open" it, and
            // it names the station once one is on.
            let onAir = model.radio.lastPlayed?.name
            let isDial = model.musicProvider == .radio
            Button { model.playMusic() } label: {
                Label(isDial ? (onAir ?? "AM/FM radio")
                             : "Open \(model.musicProvider.displayName)",
                      systemImage: isDial ? "dot.radiowaves.left.and.right"
                                          : "arrow.up.forward.app")
                    .scaledFont(.caption, weight: .semibold)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: Theme.tapMinimum)
            }
            .buttonStyle(.plain)
            .help(isDial ? "Open the dial"
                         : "Playback controls live in \(model.musicProvider.displayName)")
            }
            if model.musicControllable {
            Button {
                if model.musicProvider == .radio {
                    model.radioStep(forward: true)
                } else {
                    music.skip()
                }
            } label: {
                Image(systemName: "forward.fill")
                    .frame(width: 30, height: Theme.tapMinimum)
            }
            .buttonStyle(.plain)
            .help(model.musicProvider == .radio ? "Next station" : "Next track")
            .accessibilityLabel(model.musicProvider == .radio
                                ? "Next station" : "Next track")
            // Cycles shuffle → in order → loop. Live radio has no play
            // order, so the button doesn't appear for it.
            if model.musicProvider != .radio {
            Button { music.cyclePlayOrder() } label: {
                Image(systemName: music.playOrder.symbol)
                    .frame(width: 30, height: Theme.tapMinimum)
                    .foregroundStyle(music.playOrder == .ordered ? Color.primary : Color.blue)
            }
            .buttonStyle(.plain)
            .help("Play order: \(music.playOrder.rawValue)")
            .accessibilityLabel("Play order: \(music.playOrder.rawValue)")
            }
            }
        }
        .scaledFont(size: 14, weight: .semibold)
        .padding(.horizontal, 6)
        // As tall as the bar's other buttons, and the same rounded square.
        .frame(height: barButtonHeight)
        .background(Theme.fill(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Quick music actions — the same floating-card pattern as the fuel
    /// and radio menus, opened from the album-art tile.
    private var musicMenuCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Music", systemImage: "music.note")
                    .scaledFont(size: 15, weight: .bold)
                Spacer()
                Button { showMusicMenu = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // FLOWS's own mic — no "Hey Siri" needed: say a genre, artist,
            // or mood and it routes through the picked service (catalog
            // play, Spotify remote, or the service's own search).
            Button {
                guard !musicMicListening else { return }
                musicMicListening = true
                VoiceReply.shared.listenForDictation { transcript in
                    musicMicListening = false
                    guard let transcript else { return }
                    model.playMusicAsk(transcript)
                    showMusicMenu = false
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: musicMicListening ? "waveform" : "mic.fill")
                        .scaledFont(size: 14, weight: .semibold)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(musicMicListening ? "Listening…" : "Say what to play")
                            .scaledFont(size: 13, weight: .semibold)
                        Text(sayWhatToPlayHint)
                            .scaledFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 38)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(musicMicListening ? "Listening" : "Say what to play")
            // Per-service rows — what THIS provider can actually do.
            if model.musicProvider == .radio {
                musicMenuRow("Stations near you",
                             symbol: "antenna.radiowaves.left.and.right",
                             detail: "What's on the air around here") {
                    model.playMusic()
                }
                if !model.radio.queueLabel.isEmpty, model.radio.queue.count > 1 {
                    Text("\(model.radio.queueLabel.capitalized) — station "
                         + "\(model.radio.queueIndex + 1) of \(model.radio.queue.count). "
                         + "The ⏭ button, or \u{201C}Hey Siri, skip in FLOWS\u{201D}, plays another one.")
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if !model.musicControllable {
                // No control API exists for this service — one honest row
                // into its own app (the genre chips below deep-link there).
                musicMenuRow("Open \(model.musicProvider.displayName)",
                             symbol: "arrow.up.forward.app",
                             detail: "Playback controls live there") {
                    model.musicProvider.openApp()
                }
            } else if model.musicProvider == .spotify {
                // Spotify's remote has no library/genre queries — one
                // honest resume row, plus its plain-words status line.
                if let note = spotify.status {
                    Text(note).scaledFont(.caption).foregroundStyle(.secondary)
                }
                musicMenuRow("Keep playing", symbol: "clock.arrow.circlepath",
                             detail: "Pick up where Spotify left off") {
                    music.resumeRecent()
                }
            } else {
                musicMenuRow("Recently played", symbol: "clock.arrow.circlepath",
                             detail: "Keep playing your last songs") {
                    music.resumeRecent()
                }
                musicMenuRow("My station", symbol: "dot.radiowaves.left.and.right",
                             detail: "Your own song mix") {
                    music.playMyStation()
                }
            }
            // Genres, for EVERY provider — one router decides what a genre
            // MEANS for the picked service: radio tunes a station of that
            // kind, Apple Music plays it, a linked Spotify searches and
            // starts it, and a no-API service opens at its own search.
            VStack(alignment: .leading, spacing: 4) {
                Text("Genres").scaledFont(.caption, weight: .bold).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(MusicController.genreRows, id: \.self) { genre in
                        Button {
                            model.playMusicAsk(genre)
                            showMusicMenu = false
                        } label: {
                            Text(genre)
                                .scaledFont(size: 12, weight: .semibold)
                                .padding(.horizontal, 10)
                                .frame(minHeight: 30)
                                .background(Theme.fill(0.05))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "Play \(genre) on \(model.musicProvider.displayName)")
                    }
                }
                Text(genreDestinationNote)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let tip = model.musicProvider.siriPlaybackTip {
                Text("Voice tip: \"\(tip)\"")
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .floatingCard()
        .frame(maxWidth: isCompact ? .infinity : golden.sideColumn)
    }

    /// What to say into the mic, for what the picked service can really do
    /// with it: the radio finds stations by kind or by name (an artist means
    /// nothing to a station list), Apple Music and a linked Spotify play a
    /// song, artist or genre, and the rest open their own search.
    private var sayWhatToPlayHint: String {
        switch model.musicProvider {
        case .radio:
            return "A kind of music or a station's name — like \u{201C}country\u{201D}, "
                + "\u{201C}news\u{201D} or \u{201C}WGN\u{201D}"
        case .appleMusic:
            return "A song, an artist or a kind of music — like \u{201C}Taylor Swift\u{201D} "
                + "or \u{201C}jazz\u{201D}"
        case .spotify where model.musicControllable:
            return "A song, an artist or a kind of music — Spotify plays it"
        default:
            return "What to look for — \(model.musicProvider.displayName) opens to it"
        }
    }

    /// Where a genre chip actually takes the driver, in plain words.
    private var genreDestinationNote: String {
        switch model.musicProvider {
        case .radio:
            return "A genre tunes a station of that kind — next moves to another."
        case .appleMusic:
            return "A genre plays from Apple Music."
        case .spotify where model.musicControllable:
            return "A genre searches Spotify and starts it."
        default:
            return "A genre opens \(model.musicProvider.displayName)'s own search."
        }
    }

    /// First play press: ask which service the driver uses, once. The pick
    /// is stored (changeable in ⚙ Settings) and play continues right away —
    /// Apple Music plays here; anything else opens its own app.
    private var musicProviderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What do you play music with?")
                    .scaledFont(size: 15, weight: .bold)
                Spacer()
                Button { model.showMusicProviderPrompt = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            BalancedRowsLayout(minItemWidth: 118, spacing: 6) {
                ForEach(MusicProvider.allCases) { provider in
                    Button {
                        model.chooseMusicProvider(provider)
                    } label: {
                        Label(provider.displayName, systemImage: provider.symbol)
                            .scaledFont(size: 12, weight: .semibold)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            // Highlight what is ACTUALLY picked. This was
                            // hard-wired to Apple Music, so the card told a
                            // driver on AM/FM that Apple Music was their
                            // service.
                            .background(provider == model.musicProvider
                                        ? Theme.riskGreen.opacity(0.18)
                                        : Theme.fill(0.05))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Apple Music plays right here in FLOWS. Spotify can too — "
                 + "on iPhone add a Spotify token (⚙ Settings → Keys "
                 + "for extra info). No other music service lets outside apps "
                 + "control it, so the rest open in their own app. Change "
                 + "your pick anytime under ⚙ Settings.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        .floatingCard()
        .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
    }

    private func musicMenuRow(_ title: String, symbol: String, detail: String,
                              action: @escaping () -> Void) -> some View {
        Button {
            action()
            showMusicMenu = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .scaledFont(size: 14, weight: .semibold)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).scaledFont(size: 13, weight: .semibold)
                    Text(detail).scaledFont(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 38)
            .frame(maxWidth: .infinity)
            .background(Theme.fill(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: formatting

    private func distanceText(_ meters: Double) -> String {
        let miles = meters / 1609.344
        if miles < 0.19 { return "\(Int((meters / 0.3048 / 50).rounded() * 50)) ft" }
        return String(format: miles < 10 ? "%.1f mi" : "%.0f mi", miles)
    }

    private func etaText(_ seconds: Double) -> String {
        let mins = Int((seconds / 60).rounded())
        return mins >= 90 ? String(format: "%d h %02d min", mins / 60, mins % 60) : "\(mins) min"
    }
}
