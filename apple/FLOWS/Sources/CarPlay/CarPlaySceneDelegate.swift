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
import CoreLocation
import UIKit

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var mapTemplate: CPMapTemplate?

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

        // Transport controls for the PICKED service, through the same
        // MusicController as the phone HUD (Apple Music always; radio
        // always; Spotify with the user's token). A service FLOWS can't
        // drive gets NO buttons here — CarPlay can't open another app, and
        // buttons that silently played Apple Music over the driver's pick
        // were the dishonest-controls bug, for every streaming option alike.
        let music = MusicController.shared
        var buttons: [CPBarButton] = []
        if music.controlsInPlace {
            buttons.append(CPBarButton(title: "⏯") { _ in
                Task { @MainActor in MusicController.shared.playPause() }
            })
            buttons.append(CPBarButton(title: "⏭") { _ in
                Task { @MainActor in MusicController.shared.skip() }
            })
        }
        // Weather radio on the car screen: tunes the nearest NOAA relay,
        // press again to stop. Audio already routes through the car (the
        // app's background-audio session); this button is the control.
        buttons.append(CPBarButton(title: "WX") { _ in
            Task { @MainActor in
                guard let model = AppModel.shared else { return }
                if model.radio.playingChannelID != nil {
                    model.radio.stop()
                } else if let channel = model.effectivePosition
                    .flatMap({ model.radio.nearestChannel(to: $0)?.channel })
                    ?? model.radio.nearestChannel(stateCode: model.currentStateCode) {
                    model.radio.play(channel)
                }
            }
        })
        map.trailingNavigationBarButtons = buttons

        self.mapTemplate = map
        interfaceController.setRootTemplate(map, animated: true, completion: nil)
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
        guard !items.isEmpty else { return }
        let list = CPListTemplate(title: "Where to",
                                  sections: [CPListSection(items: items)])
        interfaceController.pushTemplate(list, animated: true, completion: nil)
    }

    @MainActor
    private func plan(to coordinate: CLLocationCoordinate2D, named name: String) {
        guard let model = AppModel.shared,
              let here = model.effectivePosition ?? model.location.coordinate else { return }
        interfaceController?.popToRootTemplate(animated: true, completion: nil)
        Task {
            guard let routes = try? await model.plan(
                from: here, fromName: "Current location",
                to: coordinate, toName: name), !routes.isEmpty else { return }
            model.present(routes: routes)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        self.mapTemplate = nil
    }
}
#endif
