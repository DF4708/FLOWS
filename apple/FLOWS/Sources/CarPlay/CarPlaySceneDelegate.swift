// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

// CarPlay surface: CPMapTemplate for navigation plus transport controls for
// the driver's PICKED music service. Activates ONLY when Apple has granted
// the app the com.apple.developer.carplay-maps entitlement (applied for via
// developer.apple.com/carplay — see docs/APPLE_APP.md §CarPlay). Without the
// entitlement iOS simply never connects this scene; the phone/iPad app is
// unaffected.

#if canImport(CarPlay)
import CarPlay
import Combine
import CoreLocation
import UIKit

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var mapTemplate: CPMapTemplate?
    /// Follows the music pick (and a Spotify token coming or going) while
    /// the car is connected, so the buttons always match the service.
    private var musicGate: AnyCancellable?
    /// Whether the buttons on screen drive music in place; nil before any.
    private var shownMusicInPlace: Bool?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController

        let map = CPMapTemplate()
        map.automaticallyHidesNavigationBar = true

        // WHERE TO — the predicted-destination list. This is the surface
        // where knowing the driver pays off most: at the wheel, typing is
        // impossible and every tap is expensive, so offering the two or
        // three places they actually go at this hour turns a whole
        // interaction into one press. Rows carry their own reason ("You
        // usually go here about now"), and the list falls back to recent
        // destinations when there isn't enough evidence to predict.
        let whereTo = CPBarButton(title: "Where to") { [weak self] _ in
            self?.presentDestinations()
        }
        map.leadingNavigationBarButtons = [whereTo]

        self.mapTemplate = map
        showTrailingButtons(musicInPlace: MusicController.shared.controlsInPlace)
        // The pick can change while the car is connected (Settings, the
        // offline handoff, a Spotify token). @Published announces before it
        // stores, so the gate is read a hop later.
        musicGate = MusicController.shared.$provider
            .combineLatest(SpotifyRemote.shared.$linked)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.showTrailingButtons(musicInPlace: MusicController.shared.controlsInPlace)
            }
        interfaceController.setRootTemplate(map, animated: true, completion: nil)
    }

    /// Transport controls for the PICKED service, through the same
    /// MusicController as the phone HUD (Apple Music always; radio
    /// always; Spotify with the user's token). A service FLOWS can't
    /// drive gets NO buttons here — CarPlay can't open another app, and
    /// buttons that silently played Apple Music over the driver's pick
    /// were the dishonest-controls bug, for every streaming option alike.
    @MainActor
    private func showTrailingButtons(musicInPlace: Bool) {
        guard musicInPlace != shownMusicInPlace, let mapTemplate else { return }
        shownMusicInPlace = musicInPlace
        var buttons: [CPBarButton] = []
        if musicInPlace {
            // The radio plays, pauses and steps the way the drive bar's
            // buttons do, starting the stations around here when nothing
            // is tuned or queued yet; the bare transport would do nothing.
            // The gate is checked again at the press: the pick may have
            // changed a moment before these buttons were redrawn.
            buttons.append(CPBarButton(title: "⏯") { _ in
                Task { @MainActor in
                    let music = MusicController.shared
                    guard music.controlsInPlace else { return }
                    if music.radioActive {
                        AppModel.shared?.playMusic()
                    } else {
                        music.playPause()
                    }
                }
            })
            buttons.append(CPBarButton(title: "⏭") { _ in
                Task { @MainActor in
                    let music = MusicController.shared
                    guard music.controlsInPlace else { return }
                    if music.radioActive {
                        AppModel.shared?.radioStep(forward: true)
                    } else {
                        music.skip()
                    }
                }
            })
        }
        // Weather radio on the car screen: tunes the nearest NOAA relay,
        // press again to stop. Audio already routes through the car (the
        // app's background-audio session); this button is the control.
        // Only a weather station on the air counts as "again": AM/FM music
        // or a cab channel playing is swapped for the forecast, not stopped.
        buttons.append(CPBarButton(title: "WX") { _ in
            Task { @MainActor in
                guard let model = AppModel.shared else { return }
                if model.radio.isWeatherStation(model.radio.playingChannelID) {
                    model.radio.stop()
                } else if let channel = model.effectivePosition
                    .flatMap({ model.radio.nearestChannel(to: $0)?.channel })
                    ?? model.radio.nearestChannel(stateCode: model.currentStateCode) {
                    model.radio.play(channel)
                }
            }
        })
        mapTemplate.trailingNavigationBarButtons = buttons
    }

    /// Predicted destinations first, then recent ones — each row one tap
    /// from a planned route. Everything here is resolved on-device from
    /// encrypted history; no typing, no network round trip to show the list.
    @MainActor
    private func presentDestinations() {
        guard let interfaceController else { return }
        let model = AppModel.shared
        let here = model?.effectivePosition ?? model?.location.coordinate
        var items: [CPListItem] = []

        for p in EverydayPlaces.shared.predictions(from: here, limit: 3) {
            let item = CPListItem(text: p.name, detailText: p.reason)
            item.handler = { [weak self] _, completion in
                self?.plan(to: p.coordinate, named: p.name)
                completion()
            }
            items.append(item)
        }
        for r in (model?.recents.matching("", limit: 5) ?? [])
        where !items.contains(where: { $0.text == r.name }) {
            let item = CPListItem(text: r.name, detailText: "Recent")
            item.handler = { [weak self] _, completion in
                self?.plan(to: r.coordinate, named: r.name)
                completion()
            }
            items.append(item)
        }
        // Nothing learned yet: say so, instead of a button that does nothing.
        if items.isEmpty {
            let item = CPListItem(text: "No places yet",
                                  detailText: "Places you drive to show up here")
            item.handler = { _, completion in completion() }
            items.append(item)
        }
        let list = CPListTemplate(title: "Where to",
                                  sections: [CPListSection(items: items)])
        interfaceController.pushTemplate(list, animated: true, completion: nil)
    }

    @MainActor
    private func plan(to coordinate: CLLocationCoordinate2D, named name: String) {
        guard let model = AppModel.shared,
              let here = model.effectivePosition ?? model.location.coordinate else {
            showNotice(["FLOWS needs your location first."])
            return
        }
        interfaceController?.popToRootTemplate(animated: true, completion: nil)
        Task { [weak self] in
            guard let routes = try? await model.plan(
                from: here, fromName: "Current location",
                to: coordinate, toName: name), !routes.isEmpty else {
                self?.showNotice(["No route found to \(name)."])
                return
            }
            model.present(routes: routes)
            // The car screen has no GO button of its own: ask for the trip
            // here, where the driver is looking. Go takes it the way "go
            // ahead" does (weather checked, the driver's filters kept). Mid-
            // drive the drive screen stays up (AppModel.present) and Not now
            // keeps the trip being driven; planning used to take the drive
            // screen and its warnings down on the phone.
            guard let staged = model.stageTripOffer(name: name) else {
                self?.showNotice(["No route found to \(name)."])
                return
            }
            self?.offerTrip(staged, named: name, lead: nil)
        }
    }

    /// Ask to take a trip planned from the car screen: Go takes it the way
    /// "go ahead" does (weather checked, the filters kept); Not now leaves
    /// it (mid-drive, the trip being driven carries on).
    @MainActor
    private func offerTrip(_ route: PlannedRoute, named name: String, lead: String?) {
        let title = SiriSummaries.tripRoute(name: name, meters: route.distanceMeters,
                                            seconds: route.eta)
        let alert = CPAlertTemplate(
            titleVariants: [lead.map { $0 + " " + title } ?? title],
            actions: [
                CPAlertAction(title: "Go", style: .default) { [weak self] _ in
                    Task { @MainActor in self?.answerTripOffer(named: name) }
                },
                CPAlertAction(title: "Not now", style: .cancel) { [weak self] _ in
                    Task { @MainActor in
                        AppModel.shared?.declineTripOffer()
                        self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
                    }
                },
            ])
        presentReplacing(alert)
    }

    @MainActor
    private func answerTripOffer(named name: String) {
        guard let model = AppModel.shared else { return }
        interfaceController?.dismissTemplate(animated: true) { [weak self] _, _ in
            Task { @MainActor in
                switch model.acceptTripOffer() {
                case .started, .nothing:
                    break
                case .stillChecking:
                    guard case .trip(let staged, _)? = model.pendingVoiceOffer else { return }
                    self?.offerTrip(staged, named: name,
                                    lead: "Still checking the weather on that route.")
                case .changed(let pick):
                    self?.offerTrip(pick, named: name,
                                    lead: "That route no longer fits your filters.")
                }
            }
        }
    }

    /// A one-line notice on the car screen, longest wording first (CarPlay
    /// shows the longest that fits). A newer notice replaces one still up.
    @MainActor
    private func showNotice(_ titleVariants: [String]) {
        let ok = CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        presentReplacing(CPAlertTemplate(titleVariants: titleVariants, actions: [ok]))
    }

    /// Show an alert on the car screen, replacing one still up: CarPlay
    /// presents one template at a time and quietly drops a second.
    @MainActor
    private func presentReplacing(_ alert: CPAlertTemplate) {
        guard let interfaceController else { return }
        guard interfaceController.presentedTemplate != nil else {
            interfaceController.presentTemplate(alert, animated: true, completion: nil)
            return
        }
        interfaceController.dismissTemplate(animated: false) { _, _ in
            interfaceController.presentTemplate(alert, animated: true, completion: nil)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        musicGate = nil
        shownMusicInPlace = nil
        self.interfaceController = nil
        self.mapTemplate = nil
    }
}
#endif
