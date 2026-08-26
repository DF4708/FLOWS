// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

// CarPlay surface: CPMapTemplate for navigation plus Apple Music transport
// controls. Activates ONLY when Apple has granted the app the
// com.apple.developer.carplay-maps entitlement (applied for via
// developer.apple.com/carplay — see docs/APPLE_APP.md §CarPlay). Without the
// entitlement iOS simply never connects this scene; the phone/iPad app is
// unaffected.

#if canImport(CarPlay)
import CarPlay
import CoreLocation
import MediaPlayer
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

        // Apple Music transport controls, right on the map template. Playback
        // uses the system music player so whatever the driver had going in
        // Music keeps playing — FLOWS just surfaces the controls.
        let player = MPMusicPlayerController.systemMusicPlayer
        let playPause = CPBarButton(title: "⏯") { _ in
            if player.playbackState == .playing { player.pause() } else { player.play() }
        }
        let next = CPBarButton(title: "⏭") { _ in
            player.skipToNextItem()
        }
        map.trailingNavigationBarButtons = [playPause, next]

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
