// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

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
    let isCompact: Bool
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
    /// The AM/FM kind currently on the dial, so its chip reads as chosen.
    @State private var radioGenre: BroadcastRadio.Kind?
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
            if let arrived = model.arrivedAt {
                arrivedBanner(arrived)
            } else {
                instructionBanner
            }
            // Compact layouts flow the fuel cluster under the banner (the
            // banner spans the full width there, so a corner overlay would
            // cover its text); regular layouts pin it to the true corner.
            // In a SHORT window an open floating card takes the cluster's
            // room — the driver just asked for that card, and the gauge
            // returns the moment it closes.
            if isCompact, showsFuelCluster, !(isShort && floatingCardOpen) {
                HStack {
                    Spacer()
                    fuelCluster
                }
            }
            if let warning = model.imminentWarning {
                imminentBanner(warning)
            }
            if let escalation = model.escalation {
                escalationBanner(escalation)
            } else if model.imminentWarning == nil, !model.alerts.activeHeadlines.isEmpty {
                alertStrip
            }
            if model.tripSharePrompt {
                tripShareBanner
            }
            if model.stopDelaySeconds > 0 {
                shelterDelayChip
            }
            if let need = model.nextTripNeed {
                tripNeedChip(need)
            }
            if let lastChance = model.fuelWarningText {
                lastChanceFuelBanner(lastChance)
            }
            if let fuelNote = model.fuelRecommendation {
                fuelRecommendationChip(fuelNote)
            }
            if model.refuelPrompt {
                refuelGauge
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
                      : "\(model.workZonesAhead) work zones ahead (state DOT)",
                      systemImage: "cone.fill")
                    .font(.footnote.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.92))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .shadow(color: Theme.cardShadow, radius: 8, y: 3)
            }
            if model.towingActive, let worst = model.towingViolations.first {
                Button { model.showTowingCard = true } label: {
                    Label(worst.title, systemImage: "exclamationmark.octagon.fill")
                        .font(.footnote.weight(.heavy))
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
                    .font(.footnote.weight(.bold))
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
                        .font(.footnote.weight(.bold))
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
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.cardBackground)
                    .clipShape(Capsule())
                    .shadow(color: Theme.cardShadow, radius: 8, y: 3)
            }
            if let delay = model.trafficDelayMinutes {
                HStack(spacing: 8) {
                    Image(systemName: "car.rear.waves.up.fill")
                    Text("Traffic ahead — +\(delay) min")
                        .font(.footnote.weight(.bold))
                    Button("Faster route") {
                        Task { await model.rerouteForTraffic() }
                    }
                    .font(.footnote.weight(.heavy))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(Color.white)
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
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
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.cardBackground)
                .clipShape(Capsule())
                .shadow(color: Theme.cardShadow, radius: 8, y: 3)
            }
            Spacer()
            // The floating cards share one scrolls-when-tight region: with
            // several open in a short (landscape) window they must squeeze
            // and scroll HERE — never push the maneuver banner or the bottom
            // bar off the screen. All of these cards keep their state on the
            // model or the HUD, so the fits/scrolls swap loses nothing.
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
                }
            }
            bottomBar
        }
        .overlay(alignment: .topTrailing) {
            if !isCompact, showsFuelCluster {
                fuelCluster
            }
        }
        .padding(golden.pad)
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

    /// Gauge, economy and range on ONE line in ONE type size, divided
    /// rather than stacked — three readings, one glance — with the live
    /// speed bar riding directly beneath them.
    private var fuelCluster: some View {
        let vehicle = model.vehicle
        let fraction = min(max(vehicle.predictedFuelFraction ?? 0.5, 0), 1)
        let electric = vehicle.profile?.fuelType == .electric
        return VStack(spacing: 6) {
            // The readouts share the width EVENLY and span the same span as
            // the speed bar beneath them — four instruments on one line,
            // each with the same room, rather than a cluster hugging itself
            // at the left end of a wide card.
            HStack(alignment: .top, spacing: 0) {
                GaugeDial(fraction: .constant(fraction),
                          alarming: model.fuelGaugeAlarming,
                          showsQuartileLabels: false)
                    .frame(width: golden.step(3) * 0.8, height: golden.step(3) * 0.5)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                if let economy = averageEconomy {
                    Divider().frame(height: instrumentColumnHeight)
                    titled("Average") {
                        Text(electric
                             ? String(format: "%.1f mi/kWh", economy)
                             : String(format: "%.0f MPG", economy))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                if let range = vehicle.expectedRangeMiles {
                    Divider().frame(height: instrumentColumnHeight)
                    titled("Fuel Tank") {
                        Text(String(format: "%.0f mi left", range))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                if showsSpeedSign {
                    Divider().frame(height: instrumentColumnHeight)
                    titled("Efficiency") { efficiencyIcon }
                }
                if model.fuelReachabilityTight {
                    Divider().frame(height: instrumentColumnHeight)
                    Image(systemName: "fuelpump.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.riskRed.opacity(tankPulse ? 1 : 0.15))
                        .frame(maxWidth: .infinity)
                        .help("Few fuel stops left within your range")
                }
            }
            if showsSpeedSign {
                speedBar
                // The scale's ends and both legal speeds, each positioned
                // UNDER ITS OWN LINE rather than spread evenly — a number
                // that doesn't sit beneath its mark is worse than none.
                // "mph" lives out in the readout column, under the current
                // speed, so it can never crowd the scale's top number.
                HStack(spacing: 8) {
                    GeometryReader { geo in
                        let w = geo.size.width
                        let top = barTopMph
                        ZStack(alignment: .leading) {
                            Text("0")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let state = SpeedLaw.stateThresholdMph(
                                postedLimitMph: lawLimitMph),
                               let f = SpeedLaw.barFraction(state, topMph: top) {
                                let label = String(format: "%.0f", state)
                                OutlinedText(text: label,
                                             color: Theme.riskYellow,
                                             font: .system(size: 11, weight: .bold))
                                    .fixedSize()
                                    .offset(x: centered(
                                        w * f, width: w,
                                        labelWidth: labelWidth(label, outlined: true)))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if let fed = SpeedLaw.federalThresholdMph(
                                postedLimitMph: lawLimitMph),
                               let f = SpeedLaw.barFraction(fed, topMph: top) {
                                let label = String(format: "%.0f", fed)
                                Text(label)
                                    .font(.system(size: 11, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.riskRed)
                                    .fixedSize()
                                    .offset(x: centered(w * f, width: w,
                                                        labelWidth: labelWidth(label)))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            // The scale's top, under the END of the bar —
                            // yielding only if a legal number lands on it.
                            if !crowdsTheEnd(SpeedLaw.federalThresholdMph(
                                    postedLimitMph: lawLimitMph),
                                    top: top) {
                                Text("\(Int(top))")
                                    .font(.system(size: 11, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                    .frame(height: 14)
                    Text("mph")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 8, y: 3)
        .overlay(alignment: .topTrailing) {
            minimizeButton("fuel", help: "Tuck the driving instruments away")
                .padding(3)
        }
        .animation(model.fuelReachabilityTight
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

    /// One instrument readout under its own underlined title, so each
    /// number says what it is without a driver having to infer it.
    /// How tall one instrument column is — the same height as the separator
    /// bars between them, so every column ends on the same line.
    private var instrumentColumnHeight: CGFloat { golden.step(3) * 0.52 }

    private func titled<Content: View>(_ title: String,
                                       @ViewBuilder content: () -> Content)
        -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(maxWidth: .infinity)   // centered over its own column
            Rectangle()
                .fill(Color.secondary.opacity(0.45))
                .frame(height: 1)
            // The reading sits in the MIDDLE of the space left between its
            // own underline and the foot of the separator bars. Three
            // readings of different natural heights — two lines of text and
            // an icon — otherwise hang from the rule at three heights.
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: instrumentColumnHeight)
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
            fuelFraction: model.vehicle.predictedFuelFraction))
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

    /// The live speed bar: 0 on the left, the vehicle's top speed on the
    /// right, ticked like a real gauge — a black half-height mark every
    /// 10 mph and a shorter one every 5. A thick yellow line marks where
    /// state law is broken and a thick red one excessive speed; the fill
    /// takes the color of whichever has been passed, and passing red sets
    /// the bar breathing. The efficiency icon rides ON TOP of the fill,
    /// travelling with the speed it describes.
    private var speedBar: some View {
        let top = barTopMph
        let fill = min(max(liveMph / max(top, 1), 0), 1)
        let stateMph = SpeedLaw.stateThresholdMph(postedLimitMph: lawLimitMph)
        let fedMph = SpeedLaw.federalThresholdMph(postedLimitMph: lawLimitMph)
        let stateFrac = SpeedLaw.barFraction(stateMph, topMph: top)
        let fedFrac = SpeedLaw.barFraction(fedMph, topMph: top)
        let over = speedStanding == .federalViolation
        return HStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fill(0.07))
                    Capsule()
                        .fill(speedBarColor)
                        .frame(width: w * fill)
                    // Ticks ride OVER the fill — a scale you can still read
                    // once the bar has run past it.
                    ticks(width: w, topMph: top)
                    if let stateFrac {
                        legalMarker(at: w * stateFrac, color: Theme.riskYellow,
                                    passed: liveMph >= (stateMph ?? .infinity))
                    }
                    if let fedFrac {
                        legalMarker(at: w * fedFrac, color: Theme.riskRed,
                                    passed: over)
                    }
                }
                .animation(.easeOut(duration: 0.35), value: fill)
                .animation(.easeInOut(duration: 0.5), value: top)
            }
            .frame(height: 14)
            // Outlined only while yellow — the other two read on their own,
            // and an outline everywhere would just thicken them.
            Group {
                if speedStanding == .stateViolation {
                    OutlinedText(text: String(format: "%.0f", max(liveMph, 0)),
                                 color: Theme.riskYellow,
                                 font: .system(size: 15, weight: .heavy,
                                               design: .rounded))
                } else {
                    Text(String(format: "%.0f", max(liveMph, 0)))
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(speedBarColor)
                }
            }
            .frame(minWidth: 28, alignment: .trailing)
        }
        .shadow(color: over ? Theme.riskRed.opacity(overGlow ? 0.9 : 0.15) : .clear,
                radius: over ? (overGlow ? 12 : 3) : 0)
        // The pulse is animated ON THIS VIEW ONLY. Driving a repeatForever
        // through withAnimation put every view updated in that transaction
        // into the same repeating animation — which is why unrelated menus
        // (the music picker's green rows) were seen blinking.
        .animation(over ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .default,
                   value: overGlow)
        .onChange(of: over, initial: true) { _, isOver in
            overGlow = isOver
        }
        .help(SpeedLaw.federalNote)
    }

    /// The speed a legal line stands for, printed under its tick.
    private func limitLabel(_ text: String, at x: CGFloat,
                            width: CGFloat, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .heavy))
            .monospacedDigit()
            .foregroundStyle(color)
            .fixedSize()
            .offset(x: min(max(x - 8, 0), max(width - 16, 0)), y: 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Would a threshold's label sit on top of the scale's end label?
    private func crowdsTheEnd(_ mph: Double?, top: Double) -> Bool {
        guard let mph, top > 0 else { return false }
        return mph / top > 0.82
    }

    /// How wide a scale label actually is.
    ///
    /// The scale numbers are monospaced digits at a known size, so one
    /// advance per character is exact rather than a guess — and a guess is
    /// what left every number sitting a few points to the LEFT of the line
    /// it belongs to. SF Pro's monospaced digit advance is about 0.6 em; the
    /// outlined (yellow) labels carry a point of edge on each side.
    private func labelWidth(_ text: String, outlined: Bool = false) -> CGFloat {
        CGFloat(text.count) * 11 * 0.6 + (outlined ? 2 : 0)
    }

    /// Center a label on its line, kept inside the bar's own width so a
    /// threshold near either end still reads.
    private func centered(_ x: CGFloat, width: CGFloat, labelWidth: CGFloat)
        -> CGFloat {
        min(max(x - labelWidth / 2, 0), max(width - labelWidth, 0))
    }

    /// Speedometer ticks: half-height every 10 mph, quarter-height every 5.
    private func ticks(width: CGFloat, topMph: Double) -> some View {
        let stops = Array(stride(from: 5.0, to: topMph, by: 5.0))
        return ZStack(alignment: .leading) {
            ForEach(Array(stops.enumerated()), id: \.offset) { _, mph in
                let major = mph.truncatingRemainder(dividingBy: 10) == 0
                Rectangle()
                    .fill(Color.black.opacity(major ? 0.7 : 0.45))
                    .frame(width: major ? 1.5 : 1, height: major ? 7 : 4)
                    .offset(x: width * (mph / topMph))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// A legal threshold: full-height and thick, so it reads over the fill.
    ///
    /// Once the bar runs PAST a line the fill takes that line's own color
    /// and the mark disappears into it — red on red. A line the driver has
    /// just crossed is the one they most need to see, so a crossed mark
    /// gets a solid white surround rather than the hairline edge.
    private func legalMarker(at x: CGFloat, color: Color,
                             passed: Bool = false) -> some View {
        // The white is a BORDER, not the mark: the color still has to be
        // the thing you see, so the core stays wider than the two edges.
        let core: CGFloat = passed ? 6 : 3
        let outer: CGFloat = passed ? core + 4 : core
        return ZStack {
            if passed {
                Rectangle()
                    .fill(.white)
                    .frame(width: outer, height: 18)
            }
            Rectangle()
                .fill(color)
                .frame(width: core, height: 14)
                .overlay(passed ? nil
                         : Rectangle().stroke(Color.white.opacity(0.6), lineWidth: 0.5))
        }
        .frame(width: outer, height: 18)
        .offset(x: max(x - outer / 2, 0))
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.riskGreen)
                .frame(width: 24)
                .contentTransition(.symbolEffect(.replace))
                .help(efficiencyHelp)
        case .wasteful:
            // A bare cloud reads as weather; the CO2 glyph reads as exhaust.
            Image(systemName: "carbon.dioxide.cloud.fill")
                .font(.system(size: 17, weight: .bold))
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(FoodCategory.allCases) { category in
                    Button {
                        Task {
                            await model.poi.chooseFood(category, aheadOf: model.effectivePosition)
                        }
                    } label: {
                        Text(category.rawValue)
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)],
                      alignment: .leading, spacing: 6) {
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
            HStack(spacing: 8) {
                ForEach(FuelType.allCases) { fuel in
                    Button {
                        Task {
                            await model.poi.chooseFuel(fuel, aheadOf: model.effectivePosition)
                        }
                    } label: {
                        Label(fuel.rawValue, systemImage: fuel.symbol)
                            .scaledFont(size: 14, weight: .semibold)
                            .frame(maxWidth: .infinity, minHeight: Theme.tapMinimum)
                            .background(Theme.fill(0.05))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Remembered for future Gas requests — change it anytime under ⚙ Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .floatingCard()
        .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
    }

    // MARK: ranked results list — ahead-only, ordered per kind

    private var poiListCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(listTitle)
                    .scaledFont(size: 15, weight: .bold)
                Spacer()
                // X = minimize into the round list icon at the top right —
                // the results (and their map pins) stay; pressing the active
                // stop button below clears the search for real.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        _ = model.collapsedPanels.insert("stops")
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Tuck the stop list away")
            }
            if model.yelpAPIKey.isEmpty,
               model.poi.activeKind == .food || model.poi.activeKind == .hotel {
                HStack(spacing: 6) {
                    Text("Stars, $ tiers, and hours need a free Yelp key:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("get one →", destination: URL(string: "https://www.yelp.com/developers")!)
                        .font(.caption.weight(.bold))
                    Button("paste in ⚙") { model.showSettings = true }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.blue)
                }
            }
            // Reader: tapping a pin on the MAP selects its row here — scroll
            // that row into view, the same way tapping a route card brings
            // its route forward on the map.
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.poi.results) { ranked in
                            poiRow(ranked)
                                .id(ranked.id)
                        }
                    }
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
        .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
    }

    private var listTitle: String {
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

    private func poiRow(_ ranked: POIService.RankedPOI) -> some View {
        let isSelected = ranked.id == model.poi.selected?.id
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(ranked.item.name ?? "Stop")
                    .scaledFont(size: 14, weight: .semibold)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(String(format: "in %.0f mi", max(ranked.aheadMeters, 0) / 1609.344))
                    Text(String(format: "· +%.0f min detour",
                                2 * ranked.detourMeters / POIRanking.detourSpeedMps / 60))
                    if let open = ranked.isOpenNow {
                        Text(open ? "· Open" : "· Closed")
                            .foregroundStyle(open ? Theme.riskGreen : Theme.riskRed)
                            .fontWeight(.semibold)
                    }
                    if ranked.showers == .standard || ranked.showers == .likely {
                        Label(ranked.showers.rawValue, systemImage: "shower.fill")
                            .font(.caption2.weight(.semibold))
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
                                .font(.caption2)
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
                .font(.caption)
                .foregroundStyle(.secondary)
                if ranked.rating != nil || ranked.costTier != nil {
                    StarsAndBucks(stars: ranked.rating, costTier: ranked.costTier,
                                  currency: model.costCountry.currencySymbol)
                }
            }
            Spacer()
            // PRICE: the big slot shows LIVE station prices only (TomTom
            // key) — a state average isn't a price, so it rides as a small
            // caption instead of masquerading as one.
            if model.poi.activeKind == .gas || model.poi.activeKind == .hotel {
                VStack(alignment: .trailing, spacing: 0) {
                    if model.costCountry == .mexico, model.poi.activeKind == .gas,
                       ranked.isLivePrice, let mx = ranked.pricePerUnit {
                        // CRE feed: this station's real posted price, MXN/L.
                        Text(String(format: "MX$%.2f", mx))
                            .scaledFont(size: 19, weight: .heavy, design: .rounded)
                            .monospacedDigit()
                            .foregroundStyle(Theme.cta)
                        Text("/L · official (CRE)")
                            .scaledFont(size: 9, weight: .semibold)
                            .foregroundStyle(.secondary)
                    } else if model.poi.activeKind == .gas, !ranked.isLivePrice {
                        Text(ranked.pricePerUnit.map {
                            String(format: "~$%.2f est.", $0) }
                            ?? (model.tomtomAPIKey.isEmpty ? "add TomTom key" : "$ —"))
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(.secondary)
                    } else if model.poi.activeKind == .hotel, ranked.pricePerUnit == nil {
                        // No live nightly: a tier-anchored typical rate,
                        // clearly an estimate — never a blank "$ —".
                        Text(String(format: "~$%.0f est.",
                                    RatingsAndCost.estimatedNightly(costTier: ranked.costTier)))
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(.secondary)
                        Text("per night")
                            .scaledFont(size: 9, weight: .semibold)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(ranked.pricePerUnit.map { String(format: "$%.2f", $0) } ?? "$ —")
                            .scaledFont(size: 19, weight: .heavy, design: .rounded)
                            .monospacedDigit()
                            .foregroundStyle(ranked.pricePerUnit == nil ? Color.secondary : Theme.cta)
                        Text(model.poi.activeKind == .gas
                             ? (model.poi.fuelType == .electric ? "/kWh" : "/gal")
                             : "per night")
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
            Button("Done") { model.endNavigation() }
                .scaledFont(size: 15, weight: .heavy)
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .frame(minHeight: Theme.tapMinimum)
                .background(Color.white)
                .foregroundStyle(Theme.riskGreen)
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
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            }
            Text("Send a text with where you're going, when you'll get there, and a map.")
                .font(.footnote)
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
                    .font(.footnote)
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
            onDismiss: { model.dismissImminentWarning() },
            onShelterDelay: warning.action == .shelter ? {
                model.beginShelter(for: warning)
                // Only look for a place when a place is the answer — for a
                // visibility or hydroplaning hazard the vehicle IS shelter.
                if ShelterPolicy.kind(forEvent: warning.event,
                                      severityScore: warning.severityScore)
                    != .inVehicle {
                    Task { await model.poi.request(.shelter,
                                                   aheadOf: model.effectivePosition) }
                }
            } : nil,
            onFindRest: warning.action == .restArea ? {
                Task { await model.poi.request(.rest, aheadOf: model.effectivePosition) }
            } : nil)
    }

    /// Sheltering time already added to the ETA — visible so the driver
    /// knows the arrival time includes it.
    private var shelterDelayChip: some View {
        Label(String(format: "+%.0f min stopped time in ETA", model.stopDelaySeconds / 60),
              systemImage: "clock.badge.exclamationmark")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.cardBackground)
            .clipShape(Capsule())
            .shadow(color: Theme.cardShadow, radius: 8, y: 3)
    }

    /// Next scheduled trip need (fuel/food/rest cadence) with its countdown;
    /// tapping runs that need's POI search.
    private func tripNeedChip(_ event: TripNeeds.Event) -> some View {
        let currentMile = (model.navigation.guidance?.alongMeters ?? 0) / 1609.344
        return Button {
            Task { await model.requestTripNeed(event) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: event.need.symbol)
                Text("\(event.need.label) in \(Int(max(event.mile - currentMile, 0).rounded())) mi")
            }
            .font(.footnote.weight(.semibold))
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
            // The arrow that MATCHES the words (ManeuverSymbol) — a right
            // turn drawn beside "turn left" is worse than no icon.
            Image(systemName: ManeuverSymbol.symbol(for: instruction))
                .scaledFont(size: live ? 34 : 28, weight: .bold)
                .frame(width: live ? 40 : 34)
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
                // Lane guidance: real tagged lanes when OSM has them,
                // otherwise whatever the instruction itself states.
                if !model.upcomingLanes.isEmpty {
                    taggedLaneStrip(model.upcomingLanes, instruction: instruction)
                } else if let advice = LaneGuidance.advice(for: instruction) {
                    laneStrip(advice)
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
            bannerCompass
        }
        .padding(14)
        .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
        .background(Theme.chrome.opacity(0.92))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 14, y: 5)
    }

    /// The REAL lane row: one arrow per tagged lane, each drawn as the
    /// movement that lane actually serves (OSM turn:lanes), with the lanes
    /// that serve THIS maneuver filled green. Lanes are left-to-right in the
    /// direction of travel, so the row reads like the road ahead.
    private func taggedLaneStrip(_ lanes: [LaneData.Lane],
                                 instruction: String) -> some View {
        let side = ManeuverSymbol.side(of: instruction)
        let lit = LaneData.recommended(lanes: lanes, maneuver: side)
        let summary = LaneData.summary(lanes: lanes, recommended: lit)
        return HStack(spacing: 4) {
            ForEach(Array(lanes.enumerated()), id: \.offset) { i, lane in
                Image(systemName: lane.symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(lit.contains(i)
                                     ? Theme.riskGreen : Color.white.opacity(0.32))
            }
            if let summary {
                Text(summary)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.riskGreen)
                    .lineLimit(1)
                    .padding(.leading, 2)
            }
        }
        .padding(.top, 2)
    }

    /// The lanes to be in, drawn as arrows with the recommended ones filled
    /// green — the multi-lane case (a five-lane interchange) where knowing
    /// the turn isn't enough. Only ever drawn from what the instruction
    /// actually says; MapKit publishes no lane data to invent it from.
    private func laneStrip(_ advice: LaneGuidance.Advice) -> some View {
        let total = max(advice.laneCount + 2, 3)
        let lit = LaneGuidance.highlighted(advice: advice, total: total)
        return HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { i in
                Image(systemName: lit.contains(i)
                      ? ManeuverSymbol.symbol(for: advice.text) : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(lit.contains(i)
                                     ? Theme.riskGreen : Color.white.opacity(0.3))
            }
            Text(advice.text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.riskGreen)
                .lineLimit(1)
                .padding(.leading, 2)
        }
        .padding(.top, 2)
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
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.riskRed)
                    .rotationEffect(.degrees(-heading))
                Text("N")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .offset(y: -13)
                    .rotationEffect(.degrees(-heading))
            }
            .frame(width: golden.iconCircle * 0.82, height: golden.iconCircle * 0.82)
            // The reading in words and degrees — the part a driver can use
            // without interpreting a needle.
            Text(CompassReading.label(heading))
                .font(.system(size: 10, weight: .bold))
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
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.riskYellow.opacity(0.92))
            .foregroundStyle(.black)
            .clipShape(Capsule())
    }

    // MARK: bottom bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            // Trip stats + global controls. ETAs fold in unplanned stopped
            // time (sheltering). Compact keeps ONE row when the window is
            // wide enough (phone on its side) and stacks two rows on a
            // portrait phone — the single row overflowed there and clipped
            // End off the edge.
            if isCompact {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        tripStats
                        Spacer()
                        recenterButton
                        Spacer()
                        if MusicController.isAvailable {
                            musicControls
                        }
                        towingButton
                        radioButton
                        SettingsGear()
                        endButton
                    }
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            tripStats
                            Spacer()
                            recenterButton
                            endButton
                        }
                        HStack(spacing: 10) {
                            if MusicController.isAvailable {
                                musicControls
                            }
                            Spacer()
                            towingButton
                            radioButton
                            SettingsGear()
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    tripStats
                    Spacer()
                    recenterButton
                    Spacer()
                    if MusicController.isAvailable {
                        musicControls
                    }
                    towingButton
                    radioButton
                    SettingsGear()
                    endButton
                }
                // Row 1 keeps its comfortable cap; row 2 below may run wider.
                .frame(maxWidth: golden.cardMax)
            }
            // Row 2 — the stop buttons: the row widens past row 1's cap
            // (still centered) as long as the buttons fit the window; the
            // labels drop first, and a scroll strip is the LAST resort,
            // only when even the icon-only row can't fit.
            ViewThatFits(in: .horizontal) {
                poiButtonRow(iconOnly: false)
                poiButtonRow(iconOnly: true)
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

    /// Time and distance left, side by side in one type size under a single
    /// "Total" header whose rule spans both — one reading, not two chips.
    /// The tank's remaining range is NOT repeated here; the gauge cluster
    /// above already carries it.
    @ViewBuilder
    private var tripStats: some View {
        let time = model.navigation.guidance.map {
            model.adjustedRemainingTime($0.remainingTime)
        } ?? model.navigation.route.map { model.adjustedRemainingTime($0.eta) }
        let meters = model.navigation.guidance?.remainingDistance
            ?? model.navigation.route?.distanceMeters
        if let time, let meters {
            VStack(alignment: .leading, spacing: 1) {
                Text("Total remaining to destination")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(height: 1)
                HStack(spacing: 8) {
                    Text(etaText(time))
                    Divider().frame(height: 16)
                    Text(distanceText(meters))
                }
                .font(.system(size: 17, weight: .bold))
                .monospacedDigit()
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var recenterButton: some View {
        if model.mode == .navigating {
            Button {
                model.recenterRequested = true
            } label: {
                Image(systemName: "location.fill")
                    .scaledFont(size: 14, weight: .semibold)
                    .frame(width: golden.iconCircle, height: golden.iconCircle)
                    .background(Theme.fill(0.06))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Re-center on the vehicle")
        }
    }

    private var towingButton: some View {
        Button {
            model.showTowingCard.toggle()
        } label: {
            Image(systemName: "link.circle.fill")
                .scaledFont(size: 14, weight: .semibold)
                .frame(width: golden.iconCircle, height: golden.iconCircle)
                .background(model.towingActive ? Color.brown : Theme.fill(0.06))
                .foregroundStyle(model.towingActive ? .white : .primary)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Towing mode: weights vs GVWR/tow capacity/GCWR")
    }

    private var radioButton: some View {
        Button {
            // Show/hide only — the card is the radio's home and its stop
            // buttons end playback; hiding the card never cuts the audio.
            showRadio.toggle()
        } label: {
            Image(systemName: "radio.fill")
                .scaledFont(size: 14, weight: .semibold)
                .frame(width: golden.iconCircle, height: golden.iconCircle)
                .background(showRadio ? Color.brown : Theme.fill(0.06))
                .foregroundStyle(showRadio ? .white : .primary)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(model.truckerUI ? "Trucker radio" : "Emergency radio")
    }

    private var endButton: some View {
        Button("End") { model.endNavigation() }
            .buttonStyle(PillCTAStyle())
            .frame(width: 74)
    }

    private func poiButtonRow(iconOnly: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(model.truckerUI ? POIService.Kind.truckerKinds
                                    : POIService.Kind.standardKinds) { kind in
                let selected = model.poi.activeKind == kind
                Button {
                    // A fresh search brings a tucked stop list back out.
                    model.collapsedPanels.remove("stops")
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
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .frame(minHeight: 46)
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
                .font(.footnote.weight(.bold))
                .lineLimit(2)
            Spacer(minLength: 4)
            if model.fuelWarningStation != nil {
                Button("Add stop") {
                    Task { await model.addRecommendedFuelStop() }
                }
                .font(.footnote.weight(.heavy))
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
        .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true),
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
                .font(.system(size: 13, weight: .bold))
            Text(note)
                .font(.footnote.weight(.bold))
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
                .font(.footnote.weight(.bold))
            Button("Find fuel") {
                model.collapsedPanels.remove("stops")
                Task { await model.poi.request(.gas, aheadOf: model.effectivePosition) }
            }
            .font(.footnote.weight(.heavy))
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
    /// While something is playing the picker must name the station actually
    /// on the air — auto-tune moves that as the drive crosses into the next
    /// coverage area, and a picker left on the old name would be a lie.
    /// While nothing is playing it simply tracks the nearest transmitter, so
    /// the default is right for wherever the vehicle IS, not for wherever it
    /// was when the card first opened.
    private func preselectNearestStation() {
        if let playing = model.radio.playingChannelID {
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

    /// Radio: internet relays of highway-relevant broadcasts (trucker radio
    /// in trucker mode, emergency radio for everyone else — same relays),
    /// plus the frequency guide for a physical radio. (The HUD's shared
    /// card region scrolls this when the window is short.)
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
            // NOAA Weather Radio: ONE dynamically-tuned relay — defaults to the
            // transmitter closest to the GPS position and auto-switches as you
            // drive (20% hysteresis). The picker stays for manual override.
            HStack(spacing: 8) {
                Picker("Station", selection: $radioChannelID) {
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
                Button {
                    if model.radio.playingChannelID != nil {
                        model.radio.stop()
                    } else if let channel = model.radio.channels.first(where: { $0.id == radioChannelID })
                        ?? model.effectivePosition.flatMap({ model.radio.nearestChannel(to: $0)?.channel })
                        ?? model.radio.nearestChannel(stateCode: model.currentStateCode) {
                        radioChannelID = channel.id
                        model.radio.play(channel)
                    }
                } label: {
                    Image(systemName: model.radio.playingChannelID != nil
                          ? "stop.circle.fill" : "play.circle.fill")
                        .scaledFont(size: 28)
                        .foregroundStyle(Color.brown)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.radio.playingChannelID != nil
                    ? "Stop the radio" : "Play the weather radio")
            }
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Only worth a line when it says something the title doesn't —
            // "Playing <station>" under a heading already naming the station
            // is noise.
            if let status = model.radio.status,
               !status.hasPrefix("Playing ") {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("On device radio:").font(.caption.weight(.bold))
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
                HStack(alignment: .center, spacing: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(channel).font(.caption2.weight(.semibold))
                        Text(what).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let stream = model.radio.cabStream(for: channel) {
                        Button {
                            if model.radio.playingChannelID == stream.id {
                                model.radio.stop()
                            } else {
                                model.radio.play(stream)
                            }
                        } label: {
                            Image(systemName: model.radio.playingChannelID == stream.id
                                  ? "stop.circle.fill" : "play.circle.fill")
                                .scaledFont(size: 20)
                                .foregroundStyle(Color.brown)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.radio.playingChannelID == stream.id
                            ? "Stop \(channel)" : "Play \(channel)")
                    } else {
                        Image(systemName: "play.slash")
                            .scaledFont(size: 13)
                            .foregroundStyle(.tertiary)
                            .help("No internet relay exists for this channel — tune it on a car radio")
                    }
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Divider()
            // AM/FM: the community radio-browser.info directory, searched by
            // the state the vehicle is in (or any word). Streams are https
            // internet relays and play through the same player as NOAA.
            Text("AM/FM stations")
                .font(.caption.weight(.bold))
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
                        let on = radioGenre == kind
                        Button { playGenre(kind) } label: {
                            Label(kind.title, systemImage: kind.symbol)
                                .scaledFont(size: 11, weight: .semibold)
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(on ? Theme.cta : Theme.fill(0.06))
                                .foregroundStyle(on ? Theme.onCTA : Color.primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play \(kind.title) radio")
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("Search by name or genre", text: $stationSearch)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit {
                        let query = stationSearch
                        radioGenre = nil
                        Task { await model.radioBrowser.search(text: query) }
                    }
                Button("Near me") {
                    stationSearch = ""
                    radioGenre = nil
                    let code = model.currentStateCode
                    Task {
                        await model.radioBrowser.searchNearby(
                            near: model.effectivePosition, stateCode: code)
                    }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.bold))
                .foregroundStyle(.blue)
                // Spoken station pick: "weather radio", "KMFA", "bluegrass".
                Button {
                    guard !radioMicListening else { return }
                    radioMicListening = true
                    VoiceReply.shared.listenForDictation { transcript in
                        radioMicListening = false
                        guard let transcript else { return }
                        stationSearch = transcript
                        model.playRadioAsk(transcript)
                    }
                } label: {
                    Image(systemName: radioMicListening ? "waveform" : "mic.fill")
                        .scaledFont(size: 14, weight: .semibold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .accessibilityLabel(radioMicListening
                    ? "Listening" : "Say a station or genre")
            }
            if let note = model.radioBrowser.status {
                Text(note).font(.caption2).foregroundStyle(.secondary)
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
                .frame(maxHeight: isCompact ? 132 : 168)
                Text("Station list: radio-browser.info, a community "
                     + "directory. Stations play as internet streams.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Divider()
            // Scanner: Broadcastify allows no keyless in-app streams, so
            // this links OUT to their own web player (feeds near the
            // driver, located by the browser).
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Scanner — police, fire, EMS")
                        .font(.caption.weight(.bold))
                    Text("Opens Broadcastify's own web player with feeds near you.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // "Near me" asks the browser for location once; the state
                // list is the no-prompt alternative (tap your county there).
                if let code = model.currentStateCode,
                   let stateURL = ScannerLinks.stateFeedsURL(stateCode: code) {
                    Button {
                        openURL(stateURL)
                    } label: {
                        Text("\(code) list")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
                Button {
                    openURL(ScannerLinks.broadcastifyNearMe)
                } label: {
                    Label("Near me", systemImage: "arrow.up.forward.app")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            HStack(alignment: .center, spacing: 6) {
                Text("Recordings (a few minutes behind): OpenMHz, a "
                     + "volunteer archive of dispatch radio.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    openURL(ScannerLinks.openMHz)
                } label: {
                    Text("Open")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            Text("Scanner listening rules differ by state — where it isn't "
                 + "allowed while driving, listen only when parked.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .floatingCard()
        .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
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
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(station.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                // Dial position first when the name carries one — "105.7
                // FM" is what a driver would say — then the genre words.
                let detail = [station.dialLabel, station.genre.isEmpty ? nil : station.genre]
                    .compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                if model.radio.playingChannelID == station.channel.id {
                    model.radio.stop()
                } else {
                    // The visible list IS the queue — next/previous (and
                    // the mini player's skip button) walk these stations.
                    let channels = model.radioBrowser.stations.map(\.channel)
                    let start = channels.firstIndex { $0.id == station.channel.id } ?? 0
                    model.radio.playQueue(
                        channels,
                        label: stationSearch.isEmpty ? "these stations" : stationSearch,
                        startAt: start)
                }
            } label: {
                Image(systemName: model.radio.playingChannelID == station.channel.id
                      ? "stop.circle.fill" : "play.circle.fill")
                    .scaledFont(size: 20)
                    .foregroundStyle(Color.brown)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.radio.playingChannelID == station.channel.id
                ? "Stop \(station.name)" : "Play \(station.name)")
        }
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
            .font(.footnote.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.riskYellow.opacity(0.92))
            .foregroundStyle(.black)
            .clipShape(Capsule())
            .shadow(color: Theme.cardShadow, radius: 8, y: 3)
    }

    /// FMCSA §395.3 hours-of-service checkpoints (trucker mode).
    private var hosChip: some View {
        let text: String
        switch model.hosStatus {
        case .breakSoon(let until):
            text = String(format: "HOS: 30-min break due in %.0f min (FMCSA)", until / 60)
        case .breakDue:
            text = "HOS: 8 h driving — 30-min break REQUIRED (FMCSA)"
        case .limitReached:
            text = "HOS: 11 h limit reached — stop driving (FMCSA)"
        case .ok:
            text = ""
        }
        return Label(text, systemImage: "clock.badge.exclamationmark.fill")
            .font(.footnote.weight(.bold))
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
            // do (in-place transport, or deep links into its own app).
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
            if model.musicProvider.controllable {
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
                    .font(.caption.weight(.semibold))
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
        .padding(.horizontal, 4)
        .background(Theme.fill(0.06))
        .clipShape(Capsule())
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
                        Text("Genre, artist, or mood — through \(model.musicProvider.displayName)")
                            .font(.caption2)
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
                         + "Next plays another one.")
                        .font(.caption2)
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
                    Text(note).font(.caption).foregroundStyle(.secondary)
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
                Text("Genres").font(.caption.weight(.bold)).foregroundStyle(.secondary)
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let tip = model.musicProvider.siriPlaybackTip {
                Text("Voice tip: \"\(tip)\"")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .floatingCard()
        .frame(maxWidth: isCompact ? .infinity : golden.sideColumn)
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 6)],
                      alignment: .leading, spacing: 6) {
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
                 + "on iPhone add a Spotify token (⚙ Settings → Data "
                 + "sources). No other music service lets outside apps "
                 + "control it, so the rest open in their own app. Change "
                 + "your pick anytime under ⚙ Settings.")
                .font(.caption)
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
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
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
