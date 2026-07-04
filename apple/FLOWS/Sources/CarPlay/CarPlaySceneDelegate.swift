// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
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

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        self.mapTemplate = nil
    }
}
#endif
