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

        // Transport controls for the PICKED service, through the same
        // MusicController as the phone HUD (Apple Music always; Spotify
        // with the user's token). A service FLOWS can't drive gets NO
        // buttons here — CarPlay can't open another app, and buttons that
        // silently played Apple Music over the driver's pick were the
        // dishonest-controls bug, for every streaming option alike.
        let music = MusicController.shared
        if music.controlsInPlace {
            let playPause = CPBarButton(title: "⏯") { _ in
                Task { @MainActor in MusicController.shared.playPause() }
            }
            let next = CPBarButton(title: "⏭") { _ in
                Task { @MainActor in MusicController.shared.skip() }
            }
            map.trailingNavigationBarButtons = [playPause, next]
        }

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
